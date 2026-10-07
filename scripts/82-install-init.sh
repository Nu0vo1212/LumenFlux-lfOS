#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 4f - 安装 lfOS 自己的 init 系统
#
#  为什么不用 systemd：
#    - 设计方案 Phase 4 允许 OpenRC/s6/runit 等极简方案
#    - 首版目标是「能跑起来 + 低占用」，systemd 会带入数十 MB 依赖
#    - 一个可审计的 shell init 更契合「从零构建」与「攻击面最小」理念
#
#  安装内容：
#    /sbin/init            极简 PID 1（挂载、配置、起服务、给 shell）
#    /etc/init.d/          服务脚本目录（预留）
#    /etc/rc.local         用户自定义启动钩子
#    /etc/network/interfaces 网络配置（预留）
#
#  用法： bash /opt/lfOS/scripts/82-install-init.sh [all|check]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

[ -x "$LFS/usr/bin/bash" ] || die "rootfs 不完整（缺 bash）"

do_install() {
  hr "安装 lfOS init 系统"

  mkdir -p "$LFS/sbin" "$LFS/etc/init.d" "$LFS/var/log" "$LFS/run" \
           "$LFS/var/lib/sshd" "$LFS/root" 2>/dev/null

  log "写入 /sbin/init"
  cat > "$LFS/sbin/init" <<'INITEOF'
#!/bin/bash
# =============================================================================
#  lfOS (LumenFluxOS / 流光OS) init —— PID 1
#
#  设计（低占用 + 可审计 + 高安全）：
#    - 纯 shell 实现，无 systemd 依赖，代码可通读
#    - PID 1 铁律：主循环永不退出（退出即 kernel panic）
#    - 只读根友好：需要写入的路径指向 tmpfs 或 overlay 可写层
#    - 启动顺序固定：伪文件系统 → sysctl → 网络 → 防火墙 → sshd → shell
# =============================================================================

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 主控制台输出
#
# 只写一次，优先写 /dev/console。这里的取舍是实测踩出来的：
#   - 双写（console + stdout）：日志每行出现两遍，输出多时 tty 缓冲被填满，
#     写入方在缓冲满时阻塞，表现为「横幅打了一半就没了」。
#   - 只写 stdout：switch_root 之后 stdout 不保证还能送达控制台，
#     结果是切换根之后完全没有输出（无 panic、无报错，最容易被误判成挂起）。
# 因此：显式写 /dev/console，写一次；设备不可用时退回 stdout。
CONSOLE=/dev/console
[ -c "$CONSOLE" ] || CONSOLE=/dev/ttyS0
say()  { printf '%s\n' "$*" > "$CONSOLE" 2>/dev/null || printf '%s\n' "$*"; }
step() { say "[init] $*"; }

say ""
say "=============================================================="
say "  lfOS (LumenFluxOS / 流光OS) 系统初始化"
say "  高性能 · 高安全 · 低占用"
say "=============================================================="

# -----------------------------------------------------------------------------
#  1. 伪文件系统
#     switch_root 前 initramfs 已 mount --move 过一次，这里补齐与兜底。
# -----------------------------------------------------------------------------
step "1/9 挂载伪文件系统"
mount -t proc     proc     /proc 2>/dev/null
mount -t sysfs    sysfs    /sys  2>/dev/null
mount -t devtmpfs devtmpfs /dev  2>/dev/null
mkdir -p /dev/pts /dev/shm 2>/dev/null
mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs  tmpfs  /dev/shm 2>/dev/null
mount -t tmpfs  tmpfs  /run  2>/dev/null
mount -t tmpfs  tmpfs  /tmp  2>/dev/null
mkdir -p /run/sshd /run/lock 2>/dev/null

# 只读根场景：确保可变目录可写（overlay 上层或 tmpfs）
# 若 /var/log 不可写，挂一个 tmpfs 上去，避免服务写日志失败
if ! touch /var/log/.wtest 2>/dev/null; then
  mount -t tmpfs tmpfs /var/log 2>/dev/null
  say "[lfOS] /var/log 只读，已挂载 tmpfs（日志重启后不保留）"
else
  rm -f /var/log/.wtest 2>/dev/null
fi
mkdir -p /var/log 2>/dev/null

# -----------------------------------------------------------------------------
#  2. 主机名
# -----------------------------------------------------------------------------
step "2/9 设置主机名"
if [ -r /etc/hostname ]; then
  HN=$(cat /etc/hostname 2>/dev/null | head -1)
  [ -n "$HN" ] && hostname "$HN" 2>/dev/null
fi

# -----------------------------------------------------------------------------
#  3. 运行时内核参数（安全收紧 + 性能调优）
# -----------------------------------------------------------------------------
step "3/9 应用内核参数（安全加固 + 性能调优）"
if [ -f /etc/sysctl.d/99-lfos.conf ] && command -v sysctl >/dev/null 2>&1; then
  if sysctl -p /etc/sysctl.d/99-lfos.conf >/dev/null 2>&1; then
    say "[lfOS] 已应用运行时内核参数（/etc/sysctl.d/99-lfos.conf）"
  fi
fi

# 透明大页显式开启（编译期默认在运行期可能被重算，实测过）
if [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
  echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
fi

# -----------------------------------------------------------------------------
#  4. 网络（尽力而为，失败不阻塞启动）
# -----------------------------------------------------------------------------
step "4/9 配置网络"
NETOK=0
if command -v ip >/dev/null 2>&1; then
  # 回环
  ip link set lo up 2>/dev/null
  # 首个非 lo 网卡尝试 DHCP
  for IF in $(ls /sys/class/net 2>/dev/null | grep -v '^lo$'); do
    ip link set "$IF" up 2>/dev/null
    if command -v udhcpc >/dev/null 2>&1; then
      udhcpc -i "$IF" -q -n -t 3 2>/dev/null && NETOK=1 && break
    fi
  done
  [ "$NETOK" -eq 1 ] && say "[lfOS] 网络已通过 DHCP 配置"
fi

# -----------------------------------------------------------------------------
#  5. 防火墙（默认拒绝入站）
#
#  排查提示：这里**刻意不丢弃 nft 的 stderr**（早期写成 2>/dev/null，
#  结果只看到笼统的「加载失败」，无法判断是内核不支持、规则语法错、
#  还是权限问题）。现在把错误摘要打到控制台，便于定位。
# -----------------------------------------------------------------------------
step "5/9 加载防火墙规则"
if [ -f /etc/nftables.conf ] && command -v nft >/dev/null 2>&1; then
  NFT_ERR=/tmp/nft-load.err
  if nft -f /etc/nftables.conf 2>"$NFT_ERR"; then
    say "[lfOS] 已加载防火墙规则（默认拒绝入站，放行 22）"
    rm -f "$NFT_ERR" 2>/dev/null
  else
    say "[lfOS] 防火墙规则加载失败，错误如下："
    head -4 "$NFT_ERR" 2>/dev/null | while IFS= read -r _l; do say "    $_l"; done
    say "    （nft 二进制：$(command -v nft)）"
  fi
elif [ ! -f /etc/nftables.conf ]; then
  say "[lfOS] 未找到 /etc/nftables.conf，跳过防火墙"
else
  say "[lfOS] 未找到 nft 命令，跳过防火墙"
fi

# -----------------------------------------------------------------------------
#  6. SSH 服务（后台化，绝不阻塞启动）
#
#  踩过的坑：init 在这里卡死，系统永远到不了 shell。
#  原因是 `ssh-keygen -A` 会一次性生成 RSA3072/RSA4096/ECDSA/ED25519 多套密钥，
#  其中 RSA 需要大量随机数；而虚拟机熵源稀缺，加上内核参数
#  `random.trust_cpu=off`（不信任 CPU 的 RDRAND），/dev/random 很快耗尽，
#  ssh-keygen 便阻塞在读取熵上 —— 表现为日志停在「生成 SSH 主机密钥」。
#
#  处理办法（双管齐下）：
#    1) 只生成 ED25519 密钥：现代推荐算法、几乎瞬时完成，不需要大量熵
#    2) 整个 SSH 初始化放到后台子 shell，即使密钥生成较慢也不影响系统
#       进入可用状态（用户可以先拿到 shell，sshd 稍后就绪）
#  注意：这里刻意不改成 random.trust_cpu=on —— 保持「不盲信硬件熵」的安全
#  取向，用工程手段（后台化）而不是放宽安全策略来解决问题。
# -----------------------------------------------------------------------------
if [ -x /usr/sbin/sshd ]; then
  (
    mkdir -p /etc/ssh /run/sshd /var/lib/sshd /var/empty/sshd 2>/dev/null

    # ---------------------------------------------------------------------
    #  privsep 目录的属主与权限必须正确，否则 sshd 直接拒绝启动：
    #      /var/lib/sshd must be owned by root and not group or world-writable.
    #
    #  为什么运行时还要再修一次：squashfs 镜像打包时虽已用 -all-root 统一属主，
    #  但 overlay 的上层（tmpfs）新建目录、以及从旧镜像升级的场景都可能残留
    #  错误属主。运行时（此处是 root）显式纠正最保险。
    # ---------------------------------------------------------------------
    chown root:root /var/lib/sshd /run/sshd /var/empty/sshd 2>/dev/null
    chmod 0700 /var/lib/sshd 2>/dev/null
    chmod 0755 /run/sshd /var/empty/sshd 2>/dev/null

    # ---------------------------------------------------------------------
    #  SSH 主机密钥：缺失、为空、或已损坏时都要重新生成。
    #
    #  踩过的坑：最初只用 `[ ! -f ... ]` 判断文件是否存在。结果是
    #    - 首次启动生成密钥后若遇到强制关机（虚拟机测试常见），ext4 可能
    #      来不及把数据刷盘，磁盘上留下一个 0 字节或残缺的密钥文件；
    #    - 下次启动时 `-f` 为真 → 跳过生成 → sshd 报
    #          no hostkeys available -- exiting.
    #      而且日志里不会出现「已生成」，看起来像是密钥凭空消失。
    #  修法四件套：
    #    1) 用 -s 判断「存在且非空」
    #    2) 用 ssh-keygen -l 校验密钥真的可解析（捕捉残缺内容）
    #    3) 用 timeout 包住 ssh-keygen：它需要内核随机数，若 crng 尚未初始化
    #       （内核日志里缺 "crng init done"），getrandom() 会**永久阻塞** ——
    #       表现为系统看起来启动完成，但 SSH 永远不可用，且日志停在
    #       「SSH 服务正在后台启动」之后毫无输出，极难定位。
    #       内核侧已用 random.trust_cpu=on 解决熵源；这里再加超时兜底。
    #    4) 生成后 sync，确保落盘再继续
    # ---------------------------------------------------------------------
    HK=/etc/ssh/ssh_host_ed25519_key
    if [ ! -s "$HK" ] || ! ssh-keygen -l -f "$HK" >/dev/null 2>&1; then
      [ -e "$HK" ] && say "[init] 主机密钥缺失或损坏，重新生成"
      rm -f "$HK" "$HK.pub" 2>/dev/null
      if timeout 20 ssh-keygen -q -t ed25519 -N '' -f "$HK" >/dev/null 2>&1; then
        sync
        say "[init] SSH 主机密钥已生成（ED25519）"
      else
        say "[init] SSH 主机密钥生成失败或超时（熵池异常，检查 entropy_avail）"
      fi
    fi

    # 先做配置检查，失败时把具体原因打到控制台（比只报「启动失败」有用得多）
    if ! /usr/sbin/sshd -t 2>/tmp/sshd-err; then
      say "[init] sshd 配置检查未通过："
      while read -r l; do say "[init]   $l"; done < /tmp/sshd-err
    fi

    if /usr/sbin/sshd 2>/tmp/sshd-err; then
      say "[init] sshd 已启动（监听 22）"
    else
      say "[init] sshd 启动失败，原因："
      while read -r l; do say "[init]   $l"; done < /tmp/sshd-err
    fi
  ) &
  say "[lfOS] SSH 服务正在后台启动"
fi

# -----------------------------------------------------------------------------
#  7. 用户自定义启动钩子
# -----------------------------------------------------------------------------
step "7/9 执行 /etc/rc.local"
[ -x /etc/rc.local ] && /etc/rc.local 2>/dev/null

# -----------------------------------------------------------------------------
#  8. 系统自检横幅
# -----------------------------------------------------------------------------
step "8/9 系统自检"
MEM=$(free -m 2>/dev/null | awk '/^Mem:/{print $3"/"$2" MB"}')
PROCS=$(ps 2>/dev/null | wc -l)
KVER=$(uname -r)
CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
QD=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)
THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | sed -n 's/.*\[\([a-z]*\)\].*/\1/p')
IPADDR=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127' | head -1)

say ""
say "=============================================================="
say "  lfOS 启动完成"
say "--------------------------------------------------------------"
say "  内核版本   : $KVER"
say "  内存占用   : $MEM    进程数: $PROCS"
say "  TCP 拥塞   : $CC    qdisc: $QD"
say "  透明大页   : $THP"
say "  网络地址   : ${IPADDR:-未配置}"
say "  根文件系统 : $(findmnt -n -o FSTYPE / 2>/dev/null || echo unknown)"
say "--------------------------------------------------------------"
say "  可用命令：harden.sh（加固）/ nft（防火墙）/ ssh（远程）"
say "  关机：poweroff -f    重启：reboot -f"
say "=============================================================="
say ""

# -----------------------------------------------------------------------------
#  9. 交互 shell（PID 1 常驻，绝不退出）
# -----------------------------------------------------------------------------
step "9/9 启动交互 shell"

# 进入交互前把启动阶段的写入落盘。
# 背景：虚拟机测试/意外断电场景下，强制关机可能让 ext4 来不及写回，
# 导致 /etc/ssh 下刚生成的密钥变成 0 字节残缺文件（已在实测中踩到）。
# 显式 sync 一次成本极低，却能显著降低这类「看似随机」的故障概率。
sync 2>/dev/null

export PS1='\n\[\e[1;32mlfos\[\e[0m\]:\w# '
export HOME=/root
cd /root 2>/dev/null || cd /

# locale：必须在这里显式导出。
# 原因：交互式 shell（-i）**不读** /etc/profile（那是 login shell 才读的），
# 所以 /etc/profile 里的 LANG/LC_ALL 对 PID 1 拉起的这个 shell 不生效。
# 实测表现为 `echo $LANG` 为空、`locale` 全显示 POSIX，
# 而 /etc/profile 里明明写了 LANG=C.UTF-8 —— 很容易误判成「locale 没生成」。
# 这里直接导出，与 /etc/profile 保持一致的取值。
# 前提：locale 数据已由 scripts/45-build-locale.sh 生成（否则 setlocale
# 失败会导致 bash 段错误，见 /etc/profile 内的说明）。
if [ -e /usr/lib/locale/locale-archive ]; then
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
fi

# 用普通交互 shell（-i），不用 login shell（-l）。
# 原因：-l 会读取 /etc/profile，一旦其中含无法生效的设置（例如指向不存在的
# locale），故障会直接发生在 PID 1 的 shell 上 —— 实测出现 bash 段错误
# （rc=139 / SIGSEGV），导致 shell 每 2 秒崩溃重启、系统实际不可用。
# 交互 shell 只读 ~/.bashrc，风险面更小；且 ~/.bashrc 内会主动
# source /etc/profile，环境基线依旧生效。
while : ; do
  if [ -c /dev/console ]; then
    PS1=$'lfos:\\w# ' /bin/bash -i < /dev/console > /dev/console 2>&1
  else
    PS1='lfos:\w# ' /bin/bash -i
  fi
  RC=$?
  say ""
  say "[lfOS] shell 已退出（rc=$RC），2 秒后重开；poweroff -f 关机"
  sleep 2
done
INITEOF
  chmod 755 "$LFS/sbin/init"

  # /init 也指向它（某些引导路径会先找 /init）
  ln -sf /sbin/init "$LFS/init" 2>/dev/null || true

  # --- 服务脚本目录与示例 ---
  log "安装服务脚本框架"
  cat > "$LFS/etc/init.d/README" <<'EOF'
lfOS 服务脚本目录

本目录用于放置自定义服务启动脚本。当前 lfOS 使用极简 shell init
（/sbin/init），服务在其固定阶段启动：

  伪文件系统 → sysctl → 网络 → 防火墙 → sshd → 用户钩子(/etc/rc.local) → shell

如需新增服务，推荐两种方式：
  1) 简单服务：直接写入 /etc/rc.local（前台/后台命令均可）
  2) 复杂服务：在本目录写脚本，并从 /etc/rc.local 调用

后续若引入 systemd（Phase 4 可选），本目录可平滑迁移为 unit 文件。
EOF

  # --- 用户自定义钩子 ---
  cat > "$LFS/etc/rc.local" <<'EOF'
#!/bin/bash
# lfOS 用户自定义启动钩子（在 sshd 之后、交互 shell 之前执行）
# 保持幂等：可能因 shell 退出重开而多次执行
exit 0
EOF
  chmod 755 "$LFS/etc/rc.local"

  # --- 网络配置说明（预留）---
  cat > "$LFS/etc/network-interfaces.txt" <<'EOF'
lfOS 网络配置说明

当前版本由 /sbin/init 自动配置：
  - 回环接口 lo 自动启用
  - 首个非 lo 网卡尝试 DHCP（依赖 BusyBox 的 udhcpc）

手工配置静态地址：
  ip addr add 192.168.1.10/24 dev eth0
  ip route add default via 192.168.1.1
  echo 'nameserver 223.5.5.5' > /etc/resolv.conf

后续 Phase 将提供 /etc/network/interfaces 风格或 systemd-networkd 配置。
EOF

  log "init 系统安装完成"
}

do_check() {
  hr "init 系统检查"
  local pass=0 fail=0
  ck() {
    if eval "$2" >/dev/null 2>&1; then
      printf '  \033[32m[✓]\033[0m %s\n' "$1"; pass=$((pass+1))
    else
      printf '  \033[31m[✗]\033[0m %s\n' "$1"; fail=$((fail+1))
    fi
  }
  ck "/sbin/init 存在且可执行"  "[ -x '$LFS/sbin/init' ]"
  ck "/sbin/init 含 PID1 兜底循环" "grep -q 'while : ; do' '$LFS/sbin/init'"
  ck "/sbin/init 含 sysctl 应用"   "grep -q 'sysctl -p' '$LFS/sbin/init'"
  ck "/sbin/init 含 sshd 启动"     "grep -q 'sshd' '$LFS/sbin/init'"
  ck "/sbin/init 含防火墙加载"     "grep -q 'nft -f' '$LFS/sbin/init'"
  ck "/init 链接存在"              "[ -e '$LFS/init' ]"
  ck "/etc/rc.local 可执行"        "[ -x '$LFS/etc/rc.local' ]"
  ck "init 脚本语法正确"           "bash -n '$LFS/sbin/init'"
  echo
  printf '  init 系统: %d 项就位 / %d 项缺失\n' "$pass" "$fail"
}

case "${1:-all}" in
  all)   do_install; do_check ;;
  check) do_check ;;
  *) die "未知参数: $1（可用 all|check）" ;;
esac
