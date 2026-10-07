#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 4 - BusyBox 用户态 + initramfs
#  产出：$LFOS/build/initramfs/（目录树）与 initramfs-lfos.cpio.gz（可启动）
#
#  设计（低占用 + 高安全）：
#   - BusyBox 用 lfOS 交叉工具链静态编译（-Os，strip），不依赖宿主 glibc
#   - initramfs 仅含必需的 /init、/bin/busybox 与少量配置，目标 < 1.5MB
#   - /init 以 PID 1 运行：挂载伪文件系统 → 打印自检 → 启动 shell
#   - 提供 ttyS0（串口）与 tty1（VBox 图形控制台）双路 shell，便于无头调试
#
#  用法：
#    bash /opt/lfOS/scripts/60-build-initramfs.sh all     # busybox + initramfs + gate
#    bash ... busybox | initramfs | gate
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
SRC="${LFS_SOURCES:-$LFOS/src}"
LOGS="${LFS_LOGS:-$LFOS/build/logs}"
OUT="$LFOS/build"
IRD="$OUT/initramfs"
BB_VER="${BUSYBOX_VERSION:-1.37.0}"
BB_TB="busybox-${BB_VER}.tar.bz2"
BBDIR="$SRC/busybox-${BB_VER}"
CROSS="$LFOS/build/tools/bin/x86_64-lfos-linux-gnu"
TGT=x86_64-lfos-linux-gnu
JOBS="${LFOS_JOBS:-$(nproc)}"

export LC_ALL=C
# 关键：脚本必须自带 PATH。make CROSS_COMPILE=<前缀> 是按「名字」查找
# $CROSS-gcc 的，若工具链目录不在 PATH 中会报 "command not found"(127)，
# 即使对应的绝对路径存在也没用。不能依赖调用方先 source buildenv.sh。
export PATH="$LFOS/build/tools/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$LOGS"

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

# 交叉工具链自检：缺失就直接给出可执行的修复提示，而不是让 make 抛 127
if ! command -v "${TGT}-gcc" >/dev/null 2>&1; then
  die "交叉编译器 ${TGT}-gcc 不在 PATH。
       期望位置: $LFOS/build/tools/bin/
       请确认 Phase 1 工具链完整，或直接执行：
         export PATH=$LFOS/build/tools/bin:\$PATH"
fi

# ---------------------------------------------------------------------------
# 阶段 1：静态编译 BusyBox
# ---------------------------------------------------------------------------
do_busybox() {
  hr "静态编译 BusyBox $BB_VER"
  [ -s "$SRC/$BB_TB" ] || die "缺少 $SRC/$BB_TB"
  [ -x "$CROSS-gcc" ] || die "交叉工具链缺失: $CROSS-gcc"

  if [ ! -f "$BBDIR/Makefile" ]; then
    log "解压 BusyBox"
    rm -rf "$BBDIR"
    tar -xf "$SRC/$BB_TB" -C "$SRC" || die "解压失败"
  fi
  cd "$BBDIR" || die "cd $BBDIR 失败"

  log "生成默认配置并调整为 lfOS 需求"
  make defconfig > "$LOGS/busybox-defconfig.log" 2>&1 || die "defconfig 失败"

  # 关键配置调整
  #   STATIC       : 静态链接，initramfs 里不需要动态库
  #   LFS 兼容     : 关闭与真实 coreutils 冲突的安装行为（保留 symlink 方式）
  #   精简         : 关掉服务器用不到的大件，控制体积
  local kcfg=(
    "CONFIG_STATIC=y"
    "CONFIG_INSTALL_APPLET_SYMLINKS=y"
    # 低占用优先：按体积优化（BusyBox 默认按速度优化，静态二进制会明显偏大）
    "CONFIG_OPTIMIZE_FOR_SIZE=y"
    # 注：FEATURE_SYSTEMD / FEATURE_HAVE_RPC 在 BusyBox 1.37 中已不存在，
    #     写入会触发 "assign nonexistent symbol" 告警，故不再设置。
    "CONFIG_FEATURE_MOUNT_NFS=n"
    "CONFIG_FEATURE_MOUNT_CIFS=n"
    "CONFIG_FEATURE_MOUNT_LOOP=n"
    "CONFIG_FEATURE_INETD_RPC=n"
    "CONFIG_FEATURE_TAB_COMPLETION=y"
    "CONFIG_FEATURE_EDITING=y"
    "CONFIG_FEATURE_EDITING_MAX_LEN=1024"
    "CONFIG_FEATURE_EDITING_HISTORY=64"
    # 保留实用工具（服务器最小集）
    "CONFIG_IP=y"
    "CONFIG_UDHCPC=y"
    "CONFIG_PING=y"
    "CONFIG_TELNET=n"
    "CONFIG_HTTPD=n"
    "CONFIG_FTPD=n"
    "CONFIG_TFTPD=n"
    "CONFIG_DNSD=n"
    # tc：BusyBox 1.37 的 networking/tc.c 引用 struct tc_cbq_ovl 等类型，
    # 而这些 CBQ 结构在 Linux 6.15 的 UAPI 头文件中已被删除（旧调度器移除），
    # 用 6.15 头文件编译必然失败。最小系统不需要流量整形，关闭之。
    "CONFIG_TC=n"
    "CONFIG_CROND=y"
    "CONFIG_SYSLOGD=y"
    "CONFIG_TOP=y"
    "CONFIG_FREE=y"
    "CONFIG_DMESG=y"
    "CONFIG_UNAME=y"
    "CONFIG_VI=y"
    "CONFIG_MOUNT=y"
    "CONFIG_UMOUNT=y"
    "CONFIG_POWEROFF=y"
    "CONFIG_REBOOT=y"
    "CONFIG_MDEV=y"
    "CONFIG_SWITCH_ROOT=y"
    "CONFIG_ASH=y"
    "CONFIG_ASH_INTERNAL_GLOB=y"
    "CONFIG_ASH_BASH_COMPAT=y"
    "CONFIG_ASH_JOB_CONTROL=y"
    "CONFIG_ASH_ALIAS=y"
    "CONFIG_ASH_CMDCMD=y"
  )
  for kv in "${kcfg[@]}"; do
    local key="${kv%%=*}" val="${kv#*=}"
    # busybox 的 .config 是 Kconfig 格式：n 要写成 "# KEY is not set"
    if [ "$val" = "n" ]; then
      sed -i "s/^${key}=.*/# ${key} is not set/" .config
      grep -q "^# ${key} is not set" .config || echo "# ${key} is not set" >> .config
    else
      sed -i "s/^# *${key} is not set/${key}=${val}/" .config
      if grep -q "^${key}=" .config; then
        sed -i "s/^${key}=.*/${key}=${val}/" .config
      else
        grep -q "^# ${key} is not set" .config || echo "${key}=${val}" >> .config
      fi
    fi
  done

  # ---------------------------------------------------------------------
  # 低占用：关闭服务器最小系统用不到的 applet（体积优化）
  # 原则：宁可保留常用工具，只删「服务端组件 / 重复功能 / 桌面相关」三类。
  #       每一项都注明理由，便于后续按需恢复。
  # ---------------------------------------------------------------------
  log "裁剪非必需 applet（低占用）"
  local unwanted=(
    # --- 网络服务端：服务器应只做客户端/被访问方，不内置这些守护进程 ---
    HTTPD UDHCPD DNSD TFTPD FTPD FTPGET TFTP TELNETD TELNET
    # --- 重复的压缩格式：只保留 gzip + xz，其余删掉 ---
    BZIP2 BUNZIP2 BZCAT LZMA UNLZMA LZCAT ZSTD ZCAT_UNZIP
    # --- 文件系统格式化/mkfs：最小系统不做磁盘管理 ---
    MKFS_EXT2 MKFS_MINIX MKFS_VFAT MKE2FS MKDOSFS FSCK_MINIX
    # --- 桌面/终端相关 ---
    CHVT DEALLOCVT OPENVT SETCONSOLE SETFONT SETKEYCODES LOADFONT
    DUMPKMAP LOADKMAP KBD_MODE RESET SHOWKEY FBSIZE
    # --- 开发/调试用工具 ---
    DEVFSD DEVKMEM DMESG_  # 保留 dmesg 本体，这里只占位说明
    # --- 其他服务器不需要的 ---
    ARP IFENSLAVE NAMEIF VCONFIG RAIDAUTORUN SULOGIN LOGIN
    CROND CRONTAB WATCHDOG BEEP DOS2UNIX UNIX2DOS
  )
  local n_off=0
  for app in "${unwanted[@]}"; do
    # 跳过占位项
    [ "$app" = "DMESG_" ] && continue
    if grep -q "^CONFIG_${app}=y" .config; then
      sed -i "s/^CONFIG_${app}=y/# CONFIG_${app} is not set/" .config
      n_off=$((n_off + 1))
    fi
  done
  log "已关闭 $n_off 个 applet 配置项"

  # 数值型选项单独处理（避免上面的引号/格式问题）
  sed -i 's/^CONFIG_FEATURE_EDITING_MAX_LEN=.*/CONFIG_FEATURE_EDITING_MAX_LEN=1024/' .config
  sed -i 's/^# CONFIG_FEATURE_EDITING_MAX_LEN is not set/CONFIG_FEATURE_EDITING_MAX_LEN=1024/' .config

  log "olddefconfig 收敛依赖（用默认值填充新增项，不交互）"
  make olddefconfig > "$LOGS/busybox-oldconfig.log" 2>&1 || true

  # 复核关键项真的生效了（配置写进去 ≠ 生效）
  for k in CONFIG_STATIC CONFIG_TC; do
    printf '       %-24s %s\n' "$k" "$(grep -E "^${k}=|^# ${k} is not set" .config | head -1)"
  done

  # 静态链接是 initramfs 的硬要求，若未生效必须中止
  grep -q '^CONFIG_STATIC=y' .config || die "CONFIG_STATIC 未生效，无法构建静态 busybox"
  # tc 若仍为 y 会编译失败，提前拦截并给出明确原因
  if grep -q '^CONFIG_TC=y' .config; then
    log "CONFIG_TC 仍为 y，强制关闭（Linux 6.15 已移除 CBQ 头文件结构）"
    sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
    make olddefconfig > /dev/null 2>&1 || true
  fi
  grep -q '^CONFIG_TC=y' .config && die "无法关闭 CONFIG_TC，请在脚本中调整"

  log "编译（CROSS_COMPILE=$TGT-, -j$JOBS, -Os + section GC）"
  # 体积优化：
  #   -Os                          按体积优化
  #   -ffunction-sections/-fdata-sections + --gc-sections
  #                                让链接器丢弃未被引用的函数/数据 —— 静态链接
  #                                glibc 时会带入大量用不到的代码，GC 后收益明显
  #   -Wl,--as-needed / -z noexecstack / -z relro / -z now
  #                                标准加固链接选项
  local BB_CFLAGS="-Os -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables"
  local BB_LDFLAGS="-Wl,--gc-sections -Wl,--as-needed -Wl,-z,noexecstack -Wl,-z,relro -Wl,-z,now"
  if ! make -j"$JOBS" CROSS_COMPILE="$TGT-" \
        EXTRA_CFLAGS="$BB_CFLAGS" \
        EXTRA_LDFLAGS="$BB_LDFLAGS" \
        > "$LOGS/busybox-build.log" 2>&1; then
    log "带体积优化编译失败，回退为普通编译模式"
    if ! make -j"$JOBS" CROSS_COMPILE="$TGT-" \
          > "$LOGS/busybox-build.log" 2>&1; then
      grep -nE 'error:|Error [0-9]' "$LOGS/busybox-build.log" | head -15
      die "BusyBox 编译失败（日志 $LOGS/busybox-build.log）"
    fi
  fi

  [ -f busybox ] || die "未生成 busybox 二进制"
  log "编译产物: $(du -h busybox | cut -f1)"

  log "strip"
  "$CROSS-strip" --strip-all busybox 2>/dev/null || true
  log "strip 后: $(du -h busybox | cut -f1)"

  # 静态性验证
  if file busybox | grep -q 'statically linked'; then
    log "确认：静态链接 ✓"
  else
    log "警告：可能不是静态链接 —— $(file -b busybox)"
  fi

  cp -f busybox "$OUT/busybox"
}

# ---------------------------------------------------------------------------
# 阶段 2：构建 initramfs 目录树
# ---------------------------------------------------------------------------
do_initramfs() {
  hr "构建 initramfs"
  [ -f "$OUT/busybox" ] || die "缺少 $OUT/busybox，请先执行 busybox 阶段"

  log "清理并建立目录骨架"
  rm -rf "$IRD"
  mkdir -p "$IRD"/{bin,sbin,etc/init.d,dev,proc,sys,tmp,run,mnt,root,usr/bin,usr/sbin,var/log}
  chmod 1777 "$IRD/tmp"
  chmod 700  "$IRD/root"

  log "安装 BusyBox 与 applet 链接"
  cp -f "$OUT/busybox" "$IRD/bin/busybox"
  chmod 755 "$IRD/bin/busybox"

  # ---------------------------------------------------------------------
  # applet 链接必须指向「目标系统内的 /bin/busybox」。
  #
  # 踩过的坑：`busybox --install -s ./bin` 会写入构建机的绝对路径，例如
  #     /opt/lfOS/build/initramfs/bin/busybox
  # 该路径在启动后的 lfOS 中并不存在，于是每个 applet 都是断链，
  # 调用 mount/setsid 等一律返回 127；一旦 exec 失败，PID 1 退出，
  # 内核报 "Attempted to kill init!" 并 panic。
  #
  # 正确做法：遍历 applet 清单，建立指向 /bin/busybox 的绝对链接。
  # ---------------------------------------------------------------------
  local app n_app=0
  while read -r app; do
    [ -n "$app" ] || continue
    [ "$app" = "busybox" ] && continue
    ln -sf /bin/busybox "$IRD/bin/$app"
    n_app=$((n_app + 1))
  done < <("$IRD/bin/busybox" --list 2>/dev/null)
  log "生成 $n_app 个 applet 链接（目标 /bin/busybox）"
  [ "$n_app" -gt 50 ] || die "applet 链接生成过少（$n_app），busybox --list 可能失败"

  # sbin 下常用的系统管理命令也建一份链接
  for app in poweroff reboot halt shutdown; do
    "$IRD/bin/busybox" --list 2>/dev/null | grep -qx "$app" && ln -sf /bin/busybox "$IRD/sbin/$app"
  done
  # 统计
  # ---------------------------------------------------------------
  # /init —— PID 1
  # ---------------------------------------------------------------
  log "写入 /init"
  cat > "$IRD/init" <<'INITEOF'
#!/bin/busybox sh
# =============================================================================
#  lfOS (LumenFluxOS / 流光OS) initramfs init —— PID 1
#  阶段一：最小可启动系统（initramfs 即最终根，不做 switch_root）
# =============================================================================
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# --- 挂载伪文件系统 ---
mount -t proc     proc     /proc  2>/dev/null
mount -t sysfs    sysfs    /sys   2>/dev/null
mount -t devtmpfs devtmpfs /dev   2>/dev/null
mount -t tmpfs    tmpfs    /run   2>/dev/null
mkdir -p /dev/pts
mount -t devpts   devpts   /dev/pts 2>/dev/null
# 内核命令行里的参数可直接用于关闭/开启行为
mount -t tmpfs tmpfs /tmp 2>/dev/null

# --- 基本设备节点兜底（devtmpfs 不可用时） ---
[ -c /dev/console ] || mknod -m 600 /dev/console c 5 1 2>/dev/null
[ -c /dev/null ]    || mknod -m 666 /dev/null    c 1 3 2>/dev/null
[ -c /dev/tty ]     || mknod -m 666 /dev/tty     c 5 0 2>/dev/null
[ -c /dev/ttyS0 ]   || mknod -m 660 /dev/ttyS0   c 4 64 2>/dev/null
[ -c /dev/tty1 ]    || mknod -m 660 /dev/tty1    c 4 1  2>/dev/null
[ -c /dev/zero ]    || mknod -m 666 /dev/zero    c 1 5 2>/dev/null
[ -c /dev/random ]  || mknod -m 666 /dev/random  c 1 8 2>/dev/null
[ -c /dev/urandom ] || mknod -m 666 /dev/urandom c 1 9 2>/dev/null

hostname lfos 2>/dev/null

# -----------------------------------------------------------------------------
#  控制台输出
#
#  lfOS 的 cmdline 是 `console=tty0 console=ttyS0,115200`。内核规则：
#  「最后一个 console= 作为 /dev/console 的映射目标」，因此 /dev/console
#  实际就指向 ttyS0 —— 无头模式下串口天然能收到用户态输出，图形控制台
#  仍能收到内核日志。**所以只需要写 /dev/console 这一个设备。**
#
#  踩过的两个坑（都源于「多写一份」的执念）：
#   1) `banner | tee /dev/ttyS0`：tee 写串口设备时可能阻塞/提前退出，
#      管道中断使横幅只打一半，其后的 shell 启动代码被跳过。
#   2) 在 /dev/console 与 /dev/ttyS0 上「双写」：两者在 BIOS 引导下指向
#      同一控制台，导致横幅重复输出、相互交错，且向已关闭的一端写入会阻塞
#      （实测表现为横幅打印两遍后卡死，shell 起不来）。
#
#  结论：单点输出 + 先落盘再写，最稳。
# -----------------------------------------------------------------------------
CONSOLE_DEV=/dev/console
[ -c "$CONSOLE_DEV" ] || CONSOLE_DEV=/dev/ttyS0

# out <文本>：输出到主控制台（同时保留 stdout，便于内核 console= 兜底）
out() {
  printf '%s\n' "$*" > "$CONSOLE_DEV" 2>/dev/null
  printf '%s\n' "$*"
}

# out_cmd <命令...>：执行命令，输出落盘后一次性写主控制台
# 「先落盘」是为了让命令本身不受控制台写入影响（避免阻塞命令执行流）。
out_cmd() {
  local tmp=/tmp/.lfos_out
  "$@" > "$tmp" 2>&1
  cat "$tmp" > "$CONSOLE_DEV" 2>/dev/null
  cat "$tmp" 2>/dev/null
  rm -f "$tmp"
}

# 兼容旧调用名
both() { out "$@"; }

# --- 系统自检横幅：一屏看清三宗旨落地情况 ---
banner() {
  local kver mem_kb mem_mb nproc ir_size
  kver=$(uname -r)
  mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  mem_mb=$((mem_kb / 1024))
  nproc=$(grep -c ^processor /proc/cpuinfo)

  echo ""
  echo "=============================================================="
  echo "   lfOS  (LumenFluxOS / 流光OS)"
  echo "   高性能 · 高安全 · 低占用  ——  从零构建"
  echo "=============================================================="
  echo "  内核版本   : $kver"
  echo "  CPU 核心   : $nproc"
  echo "  物理内存   : ${mem_mb} MB"
  echo "  系统时间   : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "--------------------------------------------------------------"

  # --- 安全加固自检（KSPP 重点项，运行时可见证据） ---
  echo "  [安全加固] KSPP 关键项:"
  chk() { # chk <标签> <命令> <期望>
    local v
    v=$(eval "$2" 2>/dev/null)
    if [ "$v" = "$3" ]; then printf '    \033[32m✓\033[0m %-34s %s\n' "$1" "$v"
    else printf '    \033[33m?\033[0m %-34s %s (期望 %s)\n' "$1" "$v" "$3"; fi
  }
  chk "KASLR 地址随机化"   "cat /proc/sys/kernel/randomize_va_space" "2"
  chk "dmesg 限制"         "cat /proc/sys/kernel/dmesg_restrict" "1"
  chk "kptr 指针隐藏"      "cat /proc/sys/kernel/kptr_restrict" "1"
  chk "perf 事件限制"      "cat /proc/sys/kernel/perf_event_paranoid" "3"
  if [ -r /sys/kernel/security/lsm ]; then
    printf '    \033[32m✓\033[0m %-34s %s\n' "启用的 LSM" "$(cat /sys/kernel/security/lsm)"
  fi
  if [ -r /sys/devices/system/cpu/vulnerabilities/meltdown ]; then
    printf '    \033[32m✓\033[0m %-34s %s\n' "Meltdown 缓解" \
      "$(cat /sys/devices/system/cpu/vulnerabilities/meltdown)"
  fi

  # --- 低占用自检 ---
  echo "--------------------------------------------------------------"
  echo "  [低占用] 资源占用:"
  printf '    %-34s %s\n' "已用内存" "$(free -m 2>/dev/null | awk '/^Mem:/{print $3" MB / "$2" MB"}')"
  printf '    %-34s %s\n' "运行进程数" "$(ps 2>/dev/null | wc -l)"
  printf '    %-34s %s\n' "加载的内核模块" "0 (单体内核，无模块支持)"

  # --- 高性能自检 ---
  echo "--------------------------------------------------------------"
  echo "  [高性能] 关键路径:"
  printf '    %-34s %s\n' "TCP 拥塞控制" "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
  printf '    %-34s %s\n' "默认 qdisc" "$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
  printf '    %-34s %s\n' "IO 调度器" "$(cat /sys/block/*/queue/scheduler 2>/dev/null | head -1)"
  # THP：sysfs 内容形如 "always [madvise] never"，方括号内为当前生效值。
  # 注意：该节点在启动极早期可能尚未初始化完成，因此这里做重试读取。
  thp_raw=""
  for _try in 1 2 3 4 5; do
    [ -r /sys/kernel/mm/transparent_hugepage/enabled ] && \
      thp_raw=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
    case "$thp_raw" in
      *"[always]"*|*"[madvise]"*|*"[never]"*) break ;;
    esac
    sleep 1
  done
  thp_now=$(echo "$thp_raw" | sed -n 's/.*\[\([a-z]*\)\].*/\1/p')
  printf '    %-34s %s\n' "透明大页(THP)" "${thp_now:-未知}"
  printf '    %-34s %s\n' "  └ 原始值" "${thp_raw:-不可读}"
  echo "=============================================================="
  echo "  输入 help 查看可用命令；poweroff -f 关机；reboot -f 重启"
  echo "=============================================================="
  echo ""
}

# -----------------------------------------------------------------------------
#  应用运行时内核参数（安全收紧 + 性能调优）
#  必须在 /proc 与 /sys 挂载之后、自检之前执行。
# -----------------------------------------------------------------------------
apply_sysctl() {
  if [ -f /etc/sysctl.d/99-lfos.conf ]; then
    if sysctl -p /etc/sysctl.d/99-lfos.conf > /tmp/sysctl.log 2>&1; then
      both "[lfOS] 已应用运行时内核参数: /etc/sysctl.d/99-lfos.conf"
    else
      # 部分参数在最小内核下可能不存在，只提示不阻塞启动
      both "[lfOS] 运行时参数部分应用（$(grep -c '^[a-z]' /tmp/sysctl.log 2>/dev/null || echo 0) 项失败，属正常）"
    fi
  fi

  # ---------------------------------------------------------------------------
  # 透明大页（THP）显式开启
  #
  # 背景：内核已配置 CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y，但实测运行时
  #       /sys/kernel/mm/transparent_hugepage/enabled 显示
  #       "always madvise [never]" —— 编译期默认未在运行期生效。
  #       为确保「高性能」宗旨真正落地，这里在用户态显式设定，
  #       不依赖编译期默认值。
  # ---------------------------------------------------------------------------
  if [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
    if echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; then
      both "[lfOS] 透明大页(THP) 已设为 always"
    fi
  fi
  # defrag 用 madvise，避免 khugepaged 后台过度整理影响尾延迟
  if [ -w /sys/kernel/mm/transparent_hugepage/defrag ]; then
    echo madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
  fi
}

apply_sysctl

# 横幅同时送到串口与图形控制台（无头模式靠串口取日志）
out_cmd banner

# --- 首阶段结束：等待真正 rootfs 的阶段二再实现 switch_root ---
if [ -d /mnt/root ] && [ -x /mnt/root/sbin/init ]; then
  out "[lfOS] 检测到 /mnt/root/sbin/init，执行 switch_root"
  exec switch_root /mnt/root /sbin/init
fi

# =============================================================================
#  启动交互式 shell
#
#  PID 1 的铁律：init 进程绝不能退出，否则内核直接 panic
#  （"Attempted to kill init!"）。因此：
#    1) 不用 exec 替换自己（exec 一旦失败，进程就没了）
#    2) 用 while 兜底，shell 退出后自动重开
#
#  只起「一个」前台 shell，挂在 /dev/console 上。
#  踩过的坑：曾在 /dev/ttyS0 上额外起一个后台 shell 做「双控制台」。
#  但 cmdline 里 console=ttyS0 已让 /dev/console 指向串口，两个 shell
#  抢同一终端 → 横幅重复输出、彼此交错，实测会卡死导致 shell 起不来。
# =============================================================================
out "[lfOS] 启动交互式 shell（PID 1 常驻，shell 退出会自动重开）"
export PS1='lfos:\w# '
export HOME=/root
cd /root || cd /

while : ; do
  if [ -c /dev/console ]; then
    PS1='lfos:\w# ' sh -i < /dev/console > /dev/console 2>&1
  else
    PS1='lfos:\w# ' sh -i
  fi
  rc=$?
  out ""
  out "[lfOS] shell 已退出（rc=$rc），2 秒后自动重开；输入 poweroff -f 关机"
  sleep 2
done
INITEOF
  chmod 755 "$IRD/init"

  # ---------------------------------------------------------------
  # 基本配置
  # ---------------------------------------------------------------
  log "写入 /etc 配置"
  cat > "$IRD/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
  cat > "$IRD/etc/group" <<'EOF'
root:x:0:
EOF
  cat > "$IRD/etc/hostname" <<'EOF'
lfos
EOF
  cat > "$IRD/etc/hosts" <<'EOF'
127.0.0.1 localhost
::1       localhost
127.0.1.1 lfos
EOF
  cat > "$IRD/etc/fstab" <<'EOF'
# lfOS initramfs 阶段：伪文件系统由 /init 挂载
proc     /proc  proc     defaults                    0 0
sysfs    /sys   sysfs    defaults                    0 0
devtmpfs /dev   devtmpfs mode=0755,nosuid            0 0
tmpfs    /run   tmpfs    mode=0755,nosuid,nodev      0 0
tmpfs    /tmp   tmpfs    mode=1777,nosuid,nodev      0 0
EOF
  # 低占用：不装 inittab（PID 1 是我们的脚本），保留说明性文件
  cat > "$IRD/etc/lfos-release" <<'EOF'
lfOS (LumenFluxOS / 流光OS)
高性能 / 高安全 / 低占用 服务器 Linux 系统
构建自 Linux From Scratch 流程 + KSPP 加固内核
EOF

  # 运行时内核参数（安全收紧 + 性能调优），由 /init 通过 sysctl -p 应用
  mkdir -p "$IRD/etc/sysctl.d"
  if [ -f /mnt/d/lfOS/config/sysctl-lfos.conf ]; then
    cp -f /mnt/d/lfOS/config/sysctl-lfos.conf "$IRD/etc/sysctl.d/99-lfos.conf"
    log "已装入 sysctl 配置: /etc/sysctl.d/99-lfos.conf ($(grep -cvE '^\s*#|^\s*$' "$IRD/etc/sysctl.d/99-lfos.conf") 条生效参数)"
  else
    log "警告：未找到 config/sysctl-lfos.conf，跳过运行时参数"
  fi

  # 内核参数说明（便于运维查看）
  cat > "$IRD/etc/lfos-kernel-hardening.txt" <<'EOF'
lfOS 内核加固要点（编译期已固化，运行时不可关闭）
-------------------------------------------------------------------
栈保护      CONFIG_STACKPROTECTOR_STRONG
编译期检查  CONFIG_FORTIFY_SOURCE
用户拷贝    CONFIG_HARDENED_USERCOPY
地址随机化  CONFIG_RANDOMIZE_BASE / RANDOMIZE_MEMORY
页表隔离    CONFIG_MITIGATION_PAGE_TABLE_ISOLATION
内存只读    CONFIG_STRICT_KERNEL_RWX
分配器加固  CONFIG_SLAB_FREELIST_RANDOM / _HARDENED
            CONFIG_RANDOM_KMALLOC_CACHES / SHUFFLE_PAGE_ALLOCATOR
内存清零    CONFIG_INIT_ON_ALLOC_DEFAULT_ON
系统调用    CONFIG_SECCOMP / SECCOMP_FILTER
访问控制    CONFIG_SECURITY_SELINUX
信息限制    CONFIG_SECURITY_DMESG_RESTRICT
遗留接口    CONFIG_LEGACY_VSYSCALL_NONE（已关闭）
用户态助手  CONFIG_STATIC_USERMODEHELPER（已禁用）
无模块      CONFIG_MODULES 未启用（单体内核）
EOF

  log "initramfs 目录树完成"
}

# ---------------------------------------------------------------------------
# 阶段 3：打包 + 门禁
# ---------------------------------------------------------------------------
do_pack() {
  hr "打包 initramfs (cpio + gzip)"
  [ -f "$IRD/init" ] || die "缺少 $IRD/init"
  cd "$IRD" || die "cd $IRD 失败"

  local out_file="$OUT/initramfs-lfos.cpio.gz"
  # -n 不保存 uid/gid 映射（可复现）；排序保证构建可复现
  find . -print0 | LC_ALL=C sort -z | \
    cpio --null -o --format=newc --owner=0:0 --reproducible \
    > "$OUT/initramfs-lfos.cpio" 2>"$LOGS/initramfs-cpio.log" || die "cpio 打包失败"

  gzip -9 -f -n "$OUT/initramfs-lfos.cpio" || die "gzip 失败"
  mv -f "$OUT/initramfs-lfos.cpio.gz" "$out_file" 2>/dev/null || true

  [ -f "$out_file" ] || die "未生成 $out_file"
  log "打包完成: $(du -h "$out_file" | cut -f1)"
}

do_gate() {
  hr "Phase 4 initramfs 门禁"
  local pass=0 fail=0
  local ird="$OUT/initramfs-lfos.cpio.gz"

  chk() {
    # 临时关闭 pipefail：检查表达式里的 `... | grep -q` 会让上游命令
    # 收到 SIGPIPE（退出码 141），pipefail 会把这次「正常提前退出」误判为失败。
    local rc
    set +o pipefail
    eval "$2" >/dev/null 2>&1
    rc=$?
    set -o pipefail
    if [ "$rc" -eq 0 ]; then
      printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else
      printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1))
    fi
  }

  chk "initramfs 已生成"                "[ -f '$ird' ]"
  chk "/init 存在且可执行"              "[ -x '$IRD/init' ]"
  chk "busybox 已安装"                  "[ -x '$IRD/bin/busybox' ]"
  chk "busybox 为静态链接"              "file '$IRD/bin/busybox' | grep -q 'statically linked'"
  chk "applet 链接数量 > 100"           "[ \$(find '$IRD/bin' -type l | wc -l) -gt 100 ]"
  chk "/etc/passwd 存在"                "[ -f '$IRD/etc/passwd' ]"
  chk "/etc/hosts 存在"                 "[ -f '$IRD/etc/hosts' ]"

  # ------------------------------------------------------------------
  # 关键回归检查：applet 链接必须指向目标系统内的 /bin/busybox。
  # 若指向宿主绝对路径（如 /opt/lfOS/build/initramfs/bin/busybox），
  # 启动后全部变成断链，任何命令都返回 127，PID 1 随即退出并 panic。
  # 这个 bug 曾真实导致 VirtualBox 启动失败，故固化为门禁。
  # ------------------------------------------------------------------
  local bad_links
  bad_links=$(find "$IRD/bin" -type l ! -lname '/bin/busybox' 2>/dev/null | wc -l)
  chk "applet 链接目标全为 /bin/busybox" "[ '$bad_links' -eq 0 ]"
  if [ "$bad_links" -ne 0 ]; then
    printf '        错误示例（前 5 个）:\n'
    find "$IRD/bin" -type l ! -lname '/bin/busybox' 2>/dev/null | head -5 | \
      while read -r l; do printf '          %s -> %s\n' "$l" "$(readlink "$l")"; done
  fi
  # 模拟目标环境解析：链接去掉 $IRD 前缀后应能在树内找到对应文件
  chk "链接在目标树内可解析（抽样 mount/sh）" \
      "[ -e '$IRD/bin/busybox' ] && [ \$(readlink '$IRD/bin/mount') = '/bin/busybox' ] && [ \$(readlink '$IRD/bin/sh') = '/bin/busybox' ]"
  # /init 不得使用不带兜底的 exec（exec 失败会让 PID 1 直接消失）
  chk "/init 含 while 兜底（PID 1 不会退出）" "grep -q 'while : ; do' '$IRD/init'"

  # 体积门禁：低占用目标
  if [ -f "$ird" ]; then
    local kb; kb=$(du -k "$ird" | cut -f1)
    local app; app=$(find "$IRD/bin" -type l | wc -l)
    local bb; bb=$([ -f "$OUT/busybox" ] && du -k "$OUT/busybox" | cut -f1 || echo 0)
    echo
    echo "  体积明细:"
    printf '    %-26s %6d KB\n' "initramfs (gzip -9)" "$kb"
    printf '    %-26s %6d KB\n' "  └ busybox (strip 后)" "$bb"
    printf '    %-26s %6d\n'    "  └ applet 数量" "$app"
    printf '    %-26s %6d KB\n' "未压缩估算" "$(du -sk "$IRD" | cut -f1)"
    if [ "$kb" -le 2048 ]; then
      printf '  \033[32m[PASS]\033[0m initramfs ≤ 2MB（低占用目标）\n'; pass=$((pass+1))
    else
      printf '  \033[33m[WARN]\033[0m initramfs %dKB 偏大\n' "$kb"; fail=$((fail+1))
    fi
  fi

  echo
  echo "============================================================"
  printf '  initramfs 门禁: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ Phase 4 initramfs 就绪\033[0m\n' \
                    || printf '  \033[1;31m✗ 存在问题\033[0m\n'
  echo "============================================================"
  return "$fail"
}

# ---------------------------------------------------------------------------
case "${1:-all}" in
  busybox)   do_busybox ;;
  initramfs) do_initramfs ;;
  pack)      do_pack ;;
  gate)      do_gate ;;
  all)
    do_busybox
    do_initramfs
    do_pack
    do_gate
    ;;
  *) die "未知参数: $1（可用 all|busybox|initramfs|pack|gate）" ;;
esac
