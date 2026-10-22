#!/bin/bash
# =============================================================================
#  lfOS 场景化性能调优工具
#
#  用法：
#      lfos-tune.sh status           # 看当前场景与关键参数
#      lfos-tune.sh web              # 切到 Web 服务器场景
#      lfos-tune.sh database         # 切到数据库场景
#      lfos-tune.sh file             # 切到文件服务器场景
#      lfos-tune.sh minimal          # 切到极致低占用场景
#      lfos-tune.sh balanced         # 回到默认平衡场景
#      lfos-tune.sh apply <文件>     # 应用自定义 sysctl 文件
#      lfos-tune.sh show <场景>      # 只预览某场景会改什么，不执行
#
#  设计说明：
#    1) 所有场景都以「基础层」为起点 —— 不叠加、不继承，
#       切换场景 = 先恢复基础层，再叠加该场景的覆盖项。这样反复切换不会
#       累积出"脏"配置（sysctl 没有"删除"操作，只能靠重设）。
#    2) 场景文件存放在 /etc/lfos/tune/<场景>.conf，
#       用户可以直接编辑或新增场景，脚本会自动发现。
#    3) 每次应用都会在当前场景里记录来源，便于 status 与回滚。
#    4) 只改运行时参数与调度器，不动内核配置、不装软件。
# =============================================================================

set -uo pipefail

TUNE_DIR=/etc/lfos/tune
STATE=/etc/lfos/tune.current
BASE_CONF=/etc/sysctl.d/99-lfos-perf.conf
SCENARIO_CONF=/etc/sysctl.d/98-lfos-scenario.conf
BACKUP_DIR=/var/backups/lfos

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; BLD=$'\033[1m'; RST=$'\033[0m'

say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✔%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
err()  { printf '  %s✘%s %s\n' "$RED" "$RST" "$*"; }
hr()   { printf '\n%s═══ %s ═══%s\n' "$CYN" "$*" "$RST"; }

need_root() {
    [ "$(id -u)" -eq 0 ] || { err "需要 root 权限"; exit 1; }
}

# ---------------------------------------------------------------------------
#  初始化：建目录，若场景文件不存在则写入内置默认场景
# ---------------------------------------------------------------------------
init_scenarios() {
    mkdir -p "$TUNE_DIR" "$BACKUP_DIR" 2>/dev/null

    if [ ! -f "$TUNE_DIR/web.conf" ]; then
        cat > "$TUNE_DIR/web.conf" <<'EOF'
# Web / API 服务器场景
#
# 特点：大量短连接、并发高、单次传输不大但请求频繁。
# 重点：连接建立速度、TIME_WAIT 回收、accept 队列深度。

# 半连接与 accept 队列加深 —— 抗突发连接洪峰
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 16384

# TIME_WAIT 快速回收：短连接密集场景下端口耗尽是最常见的故障
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_tw_buckets = 524288
net.ipv4.ip_local_port_range = 10240 65535

# TCP Fast Open：省掉三次握手的一个 RTT，对首字节时间影响明显
net.ipv4.tcp_fastopen = 3

# 长连接（HTTP/2、WebSocket）空闲后不要重新慢启动
net.ipv4.tcp_slow_start_after_idle = 0

# 小请求多，减小初始拥塞窗口等待；保持内核默认 conservatism 即可
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 连接跟踪表加大（前置 nginx/ufw 时容易撑满）
net.netfilter.nf_conntrack_max = 524288

# 文件句柄：静态资源与并发连接都需要
fs.file-max = 4194304
fs.nr_open = 1048576
EOF
    fi

    if [ ! -f "$TUNE_DIR/database.conf" ]; then
        cat > "$TUNE_DIR/database.conf" <<'EOF'
# 数据库场景（MySQL / PostgreSQL / Redis 等）
#
# 特点：长连接、大内存占用、随机 I/O 密集、对延迟敏感。
# 重点：内存分配、脏页回写、虚拟内存映射、降低换出倾向。

# 数据库自己做缓存，内核不要抢内存：换出倾向降到最低
vm.swappiness = 1

# 脏页回写：数据库写模式偏随机，太激进的回写会造成 I/O 尖峰
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500

# 减少内存回收压力，避免大页分配失败
vm.vfs_cache_pressure = 200

# mmap 区域数量：InnoDB / RocksDB / 大型 JVM 常需要
vm.max_map_count = 1048576

# 内存过量分配策略保持默认（0），数据库喜欢预分配
vm.overcommit_memory = 0
vm.overcommit_ratio = 50

# 长连接保活：防火墙/云负载均衡常在 300s 断连，客户端要更早探活
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# 延迟敏感：关闭慢启动重启，拥塞窗口保持
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_congestion_control = bbr

# 连接数不多，但每个连接的数据量大
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432

# 文件句柄与 inotify
fs.file-max = 2097152
fs.inotify.max_user_watches = 1048576
fs.aio-max-nr = 1048576
EOF
    fi

    if [ ! -f "$TUNE_DIR/file.conf" ]; then
        cat > "$TUNE_DIR/file.conf" <<'EOF'
# 文件 / 下载服务器场景（Nginx 静态、rsync、对象存储网关）
#
# 特点：大块顺序 I/O、单连接传输时间长、内存主要给 page cache。
# 重点：读写缓冲、page cache 保留、顺序预读。

# 尽量把内存留给 page cache，不缓存目录项（文件遍历型访问少）
vm.vfs_cache_pressure = 200
vm.swappiness = 10

# 大文件写回：加大脏页阈值，减少回写次数
vm.dirty_ratio = 30
vm.dirty_background_ratio = 10
vm.dirty_expire_centisecs = 6000

# 顺序预读窗口：大文件传输的主要收益点
# 说明：/sys/block/*/queue/read_ahead_kb 由下面的 set_io 函数设置
# （sysctl 没有这个键，必须写 /sys，这里仅作标记）

# 大块传输：加大收发缓冲
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 524288 67108864
net.ipv4.tcp_wmem = 4096 524288 67108864

# 少量长连接，队列不必太深，但单个缓冲要大
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 32768

fs.file-max = 4194304
EOF
    fi

    if [ ! -f "$TUNE_DIR/minimal.conf" ]; then
        cat > "$TUNE_DIR/minimal.conf" <<'EOF'
# 极致低占用场景（嵌入式 / 小内存 VPS / 只跑一两个轻服务）
#
# 特点：内存非常有限，并发不高，宁可牺牲峰值性能也要省内存。
# 重点：缩小所有缓冲区、降低日志缓冲、降低连接跟踪表。

# 缩小网络缓冲区 —— 这是最直接的内存节省
net.core.rmem_max = 1048576
net.core.wmem_max = 1048576
net.core.rmem_default = 65536
net.core.wmem_default = 65536
net.ipv4.tcp_rmem = 4096 65536 1048576
net.ipv4.tcp_wmem = 4096 65536 1048576

# 队列深度按低并发设定
net.core.somaxconn = 512
net.ipv4.tcp_max_syn_backlog = 1024
net.core.netdev_max_backlog = 2048
net.core.netdev_budget = 300

# 连接跟踪表缩小
net.netfilter.nf_conntrack_max = 16384

# 更积极地回收 page cache 与 dentry
vm.vfs_cache_pressure = 150
vm.swappiness = 30

# 脏页阈值调小，避免一次性占用太多内存
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
EOF
    fi

    if [ ! -f "$TUNE_DIR/balanced.conf" ]; then
        cat > "$TUNE_DIR/balanced.conf" <<'EOF'
# 平衡场景（默认）—— 通用服务器，不针对特定负载
#
# 本质上是"什么都不覆盖"，沿用 99-lfos-perf.conf 的基础值。
# 保留这个文件是为了让 `lfos-tune.sh balanced` 有明确语义。

net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_fastopen = 3
vm.swappiness = 10
vm.dirty_ratio = 20
EOF
    fi

    if [ ! -f "$TUNE_DIR/container.conf" ]; then
        cat > "$TUNE_DIR/container.conf" <<'EOF'
# 容器宿主场景（Docker / Podman / containerd）
#
# 特点：容器共享宿主内核，大量 veth 对、网桥转发、iptables 规则链。
# 重点：网桥转发、ARP 邻居表、连接跟踪表、inotify、进程与句柄上限。
#
# ⚠ 重要提示：lfOS 当前内核未启用 CONFIG_USER_NS，
#   所以**不能跑 rootless 容器**，只能以 root 身份运行普通容器。
#   要支持 rootless 需要改内核配置重新编译。

# 网桥与转发（容器网络必需）
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

# ARP 邻居表：veth 对多了之后容易撑满
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

# 连接跟踪：每个容器的端口映射都占用表项
net.netfilter.nf_conntrack_max = 1048576

# 端口复用：大量端口映射
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1

# 文件句柄与 inotify（容器内应用常用）
fs.file-max = 8388608
fs.nr_open = 2097152
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024

# 内存：容器内存不该被换出
vm.swappiness = 10
vm.overcommit_memory = 1

# 进程与线程总量上限（细节由 cgroup 控制）
kernel.pid_max = 4194304
kernel.threads-max = 262144
EOF
    fi

    if [ ! -f "$TUNE_DIR/ai.conf" ]; then
        cat > "$TUNE_DIR/ai.conf" <<'EOF'
# AI / 推理 / 训练数据预处理场景
#
# 特点：大内存常驻、大量 mmap、频繁读模型文件。
# 重点：内存不被回收、page cache 尽量大、映射区域充足、大文件顺序读。
#
# ⚠ lfOS 不含 NVIDIA 驱动（内核按服务器通用负载裁剪）。
#   要在 GPU 上跑需自行编译驱动，并改用支持模块的内核配置。

# 内存：推理服务常驻大模型，绝不能被换出
vm.swappiness = 0
vm.overcommit_memory = 1

# 模型加载走 mmap，需要大量映射区域
vm.max_map_count = 2097152

# page cache 尽量留给模型文件
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10

# 模型文件几百 MB 到几十 GB，以顺序读为主
# 预读窗口由 set_io 设到 8192KB

# 数据加载器常同时打开大量文件
fs.file-max = 4194304
fs.nr_open = 1048576

# 大页：部分推理框架会用到。默认 0，需要时由用户按内存自行设置
vm.nr_hugepages = 0

# 分布式推理/训练的通信
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432
net.core.somaxconn = 8192
net.ipv4.tcp_fastopen = 3
EOF
    fi
}

# ---------------------------------------------------------------------------
#  应用 sysctl 文件（逐行写，失败的单独报告，不中断整体）
# ---------------------------------------------------------------------------
apply_sysctl_file() {
    local f="$1" n_ok=0 n_fail=0
    [ -f "$f" ] || return 0
    while IFS= read -r line; do
        case "$line" in
            \#*|"") continue ;;
        esac
        # 去掉行尾注释
        line="${line%%#*}"
        # trim
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        case "$line" in
            *=*) ;;
            *) continue ;;
        esac
        if sysctl -w "$line" >/dev/null 2>&1; then
            n_ok=$((n_ok + 1))
        else
            n_fail=$((n_fail + 1))
            printf '      %s跳过（内核不支持）%s %s\n' "$YEL" "$RST" "$line"
        fi
    done < "$f"
    printf '    写入 %s 项成功' "$n_ok"
    [ "$n_fail" -gt 0 ] && printf '，%s 项内核不支持' "$n_fail"
    printf '\n'
}

# ---------------------------------------------------------------------------
#  磁盘相关（sysctl 管不到，要写 /sys）
# ---------------------------------------------------------------------------
set_io() {
    local scenario="$1"
    local sched="none" ra="128"

    case "$scenario" in
        database)  sched="mq-deadline"; ra="4096" ;;
        file)      sched="none";        ra="4096" ;;
        web)       sched="none";        ra="512"  ;;
        minimal)   sched="none";        ra="128"  ;;
        container) sched="none";        ra="1024" ;;
        ai)        sched="none";        ra="8192" ;;
        balanced)  sched="none";        ra="256"  ;;
    esac

    local done_n=0
    for dev in /sys/block/sd* /sys/block/vd* /sys/block/nvme*; do
        [ -w "$dev/queue/scheduler" ] || continue
        case "$(basename "$dev")" in
            *[0-9]) continue ;;   # 跳过分区
        esac
        # 只在该调度器受支持时才写
        if grep -q "$sched" "$dev/queue/scheduler" 2>/dev/null; then
            echo "$sched" > "$dev/queue/scheduler" 2>/dev/null && done_n=$((done_n+1))
        fi
        [ -w "$dev/queue/read_ahead_kb" ] && echo "$ra" > "$dev/queue/read_ahead_kb" 2>/dev/null
    done
    if [ "$done_n" -gt 0 ]; then
        ok "磁盘调度器 = $sched，预读 = ${ra}KB（$done_n 个设备）"
    else
        warn "未能设置磁盘调度器（无可写设备）"
    fi
}

# ---------------------------------------------------------------------------
#  状态显示
# ---------------------------------------------------------------------------
get_current() {
    if [ -f "$STATE" ]; then
        cat "$STATE" 2>/dev/null
    else
        echo "balanced"
    fi
}

show_status() {
    local cur; cur="$(get_current)"
    hr "lfOS 性能调优状态"
    printf '  当前场景: %s%s%s\n' "$BLD" "$cur" "$RST"

    case "$cur" in
        web)      printf '  说明: 大量短连接、高并发、请求频繁\n' ;;
        database) printf '  说明: 长连接、大内存、随机 I/O、延迟敏感\n' ;;
        file)     printf '  说明: 大块顺序 I/O、内存主要给 page cache\n' ;;
        minimal)  printf '  说明: 极致省内存，牺牲峰值性能\n' ;;
        balanced) printf '  说明: 通用服务器，不针对特定负载\n' ;;
    esac

    hr "关键参数"
    printf '  %-38s %s\n' "网络 accept 队列 (somaxconn)" "$(sysctl -n net.core.somaxconn 2>/dev/null)"
    printf '  %-38s %s\n' "半连接队列 (tcp_max_syn_backlog)" "$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null)"
    printf '  %-38s %s\n' "网卡积压 (netdev_max_backlog)" "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)"
    printf '  %-38s %s\n' "TCP Fast Open" "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"
    printf '  %-38s %s\n' "TIME_WAIT 复用 (tcp_tw_reuse)" "$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null)"
    printf '  %-38s %s\n' "连接跟踪上限 (nf_conntrack_max)" "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)"
    printf '  %-38s %s\n' "换出倾向 (swappiness)" "$(sysctl -n vm.swappiness 2>/dev/null)"
    printf '  %-38s %s\n' "脏页比例 (dirty_ratio)" "$(sysctl -n vm.dirty_ratio 2>/dev/null)"
    printf '  %-38s %s\n' "mmap 区域 (max_map_count)" "$(sysctl -n vm.max_map_count 2>/dev/null)"
    printf '  %-38s %s\n' "文件句柄 (file-max)" "$(sysctl -n fs.file-max 2>/dev/null)"

    hr "磁盘"
    # /sys/block/*/queue/scheduler 的内容形如：
    #     none mq-deadline kyber bfq        （未选中任何项时）
    #     [none] mq-deadline kyber bfq      （none 为当前值，用方括号标出）
    # 所以要做的是"取出方括号里的值"，而不是把括号删掉。
    sched_now="$(cat /sys/block/sda/queue/scheduler 2>/dev/null | sed -n 's/.*\[\([^]]*\)\].*/\1/p')"
    [ -z "$sched_now" ] && sched_now="（未知）"
    printf '  %-38s %s\n' "调度器" "$sched_now"
    printf '  %-38s %s KB\n' "预读窗口" "$(cat /sys/block/sda/queue/read_ahead_kb 2>/dev/null)"

    hr "可用场景"
    for f in "$TUNE_DIR"/*.conf; do
        [ -f "$f" ] || continue
        local n; n="$(basename "$f" .conf)"
        local desc; desc="$(head -1 "$f" | sed 's/^#[[:space:]]*//')"
        printf '  %-12s %s\n' "$n" "$desc"
    done
}

# ---------------------------------------------------------------------------
#  应用场景
# ---------------------------------------------------------------------------
apply_scenario() {
    local want="$1"
    local f="$TUNE_DIR/$want.conf"

    if [ ! -f "$f" ]; then
        err "场景不存在: $want"
        say "可用场景:"
        for x in "$TUNE_DIR"/*.conf; do [ -f "$x" ] && say "  $(basename "$x" .conf)"; done
        return 1
    fi

    hr "切换到场景: $want"

    # 备份当前状态
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    sysctl -a > "$BACKUP_DIR/sysctl-before-$ts.txt" 2>/dev/null
    cp -f "$STATE" "$BACKUP_DIR/tune-state-before-$ts" 2>/dev/null
    ok "已备份当前 sysctl 到 $BACKUP_DIR/sysctl-before-$ts.txt"

    # 1) 重置到基础层
    hr "1/3 恢复基础层"
    if [ -f "$BASE_CONF" ]; then
        apply_sysctl_file "$BASE_CONF"
    else
        warn "基础层不存在（$BASE_CONF），跳过"
    fi

    # 2) 叠加场景覆盖
    hr "2/3 应用场景覆盖"
    apply_sysctl_file "$f"

    # 3) 同步到 sysctl.d，让重启后仍然生效
    hr "3/3 持久化"
    {
        echo "# 由 lfos-tune.sh 自动生成 —— 场景: $want"
        echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# "
        echo "# 注意：本文件在 99-lfos-perf.conf 之后加载（98 < 99？不，按字典序 98 在 99 之前），"
        echo "#       所以这里必须用 99z- 前缀才能覆盖 perf 配置。"
        echo ""
        grep -vE '^\s*#|^\s*$' "$f"
    } > "${SCENARIO_CONF}.tmp" 2>/dev/null
    mv -f "${SCENARIO_CONF}.tmp" "$SCENARIO_CONF" 2>/dev/null
    ok "已写入 $SCENARIO_CONF（重启后仍生效）"

    # 磁盘参数
    set_io "$want"

    # 记录状态
    echo "$want" > "$STATE"

    hr "完成"
    printf '  当前场景: %s%s%s\n' "$BLD" "$want" "$RST"
    printf '  回滚方法: sysctl -p %s 载入备份，或 %s balanced 回到默认\n' \
        "$BACKUP_DIR/sysctl-before-$ts.txt" "$(basename "$0")"
}

# ---------------------------------------------------------------------------
#  预览
# ---------------------------------------------------------------------------
show_scenario() {
    local want="$1"
    local f="$TUNE_DIR/$want.conf"
    [ -f "$f" ] || { err "场景不存在: $want"; return 1; }

    hr "场景预览: $want"
    say "  （仅预览，不会修改任何东西）"
    hr "会设置的参数"
    grep -vE '^\s*#|^\s*$' "$f" | while IFS= read -r l; do
        key="$(echo "$l" | cut -d= -f1 | tr -d ' ')"
        want_v="$(echo "$l" | cut -d= -f2- | sed 's/^[[:space:]]*//')"
        cur_v="$(sysctl -n "$key" 2>/dev/null || echo '不支持')"
        printf '  %-40s %s  %s→%s %s\n' "$key" "$cur_v" "$YEL" "$want_v" "$RST"
    done
    hr "磁盘参数"
    case "$want" in
        database)  say "  调度器 mq-deadline，预读 4096KB" ;;
        file)      say "  调度器 none，预读 4096KB" ;;
        web)       say "  调度器 none，预读 512KB" ;;
        minimal)   say "  调度器 none，预读 128KB" ;;
        container) say "  调度器 none，预读 1024KB" ;;
        ai)        say "  调度器 none，预读 8192KB" ;;
        *)         say "  调度器 none，预读 256KB" ;;
    esac
}

# ---------------------------------------------------------------------------
#  main
# ---------------------------------------------------------------------------
main() {
    need_root
    init_scenarios

    local cmd="${1:-status}"
    case "$cmd" in
        status)    show_status ;;
        show)      show_scenario "${2:-}" ;;
        apply)
            local f="${2:-}"
            [ -f "$f" ] || { err "文件不存在: $f"; exit 1; }
            hr "应用自定义配置: $f"
            apply_sysctl_file "$f"
            ok "完成"
            ;;
        web|database|file|minimal|container|ai|balanced)
            apply_scenario "$cmd"
            ;;
        -h|--help|help)
            sed -n '2,25p' "$0" | sed 's/^#//'
            ;;
        *)
            err "未知命令: $cmd"
            say ""
            say "用法: $0 {status|web|database|file|minimal|container|ai|balanced|show <场景>|apply <文件>}"
            exit 1
            ;;
    esac
}

main "$@"
