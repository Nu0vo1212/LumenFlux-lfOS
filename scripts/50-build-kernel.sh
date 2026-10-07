#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 3 - 加固内核构建
#  Linux 6.15.4 + KSPP 加固 + VirtualBox 兼容 + 服务器裁剪
#
#  用法：
#    bash /opt/lfOS/scripts/50-build-kernel.sh config   # 只生成 .config 并验证
#    bash /opt/lfOS/scripts/50-build-kernel.sh build    # 编译 bzImage
#    bash /opt/lfOS/scripts/50-build-kernel.sh gate     # 只跑门禁
#    bash /opt/lfOS/scripts/50-build-kernel.sh all      # config + build + gate
#
#  产物：$LFOS/build/kernel/{bzImage,System.map,.config,config-report.txt}
#  门禁：加固项 / VBox 驱动项 / 裁剪项 逐项核验；bzImage 体积目标 ≤ 8MB
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
SRC="${LFS_SOURCES:-$LFOS/src}"
LOGS="${LFS_LOGS:-$LFOS/build/logs}"
OUT="$LFOS/build/kernel"
KVER="${LINUX_VERSION:-6.15.4}"
KDIR="$SRC/linux-$KVER"
FRAG="/mnt/d/lfOS/config/kernel-lfos-vbox.fragment"
JOBS="${LFOS_JOBS:-$(nproc)}"

export LC_ALL=C
mkdir -p "$LOGS" "$OUT"

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

[ -f "$KDIR/Makefile" ] || die "内核源码未就绪: $KDIR"
[ -f "$FRAG" ] || die "缺少配置片段: $FRAG"

# ---------------------------------------------------------------------------
# 阶段 1：生成 .config
# ---------------------------------------------------------------------------
do_config() {
  hr "生成内核配置（defconfig + lfOS 加固片段）"
  cd "$KDIR" || die "cd $KDIR 失败"

  log "清理历史配置"
  make mrproper > "$LOGS/kernel-mrproper.log" 2>&1 || true

  log "基线：x86_64_defconfig（服务器精简起点）"
  make x86_64_defconfig > "$LOGS/kernel-defconfig.log" 2>&1 || die "defconfig 失败"

  log "合并 lfOS 片段: $FRAG"
  # 复制片段到内核树内，避免 /mnt/d 路径在 kconfig 里出问题
  cp -f "$FRAG" "$KDIR/lfos.fragment"
  if ! scripts/kconfig/merge_config.sh -m .config lfos.fragment \
        > "$LOGS/kernel-merge.log" 2>&1; then
    log "merge_config 报告了告警，继续用 olddefconfig 收敛依赖"
  fi

  log "olddefconfig：解析依赖并补齐未显式声明的选项"
  make olddefconfig > "$LOGS/kernel-olddefconfig.log" 2>&1 || die "olddefconfig 失败"

  # ---------------------------------------------------------------------
  # 关键一步：olddefconfig 会按 Kconfig 的 default 值回填「未显式设置」的符号，
  # 于是像 SLUB_DEBUG 这种「baseline defconfig 打开了、fragment 只注释掉」的项
  # 会被重新打开。必须在 olddefconfig 之后强制关闭，再收敛一次。
  # ---------------------------------------------------------------------
  log "强制关闭有运行时开销的调试项（否则会被 Kconfig default 回填）"
  local force_off=(
    SLUB_DEBUG SLUB_DEBUG_ON
    DEBUG_VM DEBUG_LIST DEBUG_SG DEBUG_NOTIFIERS DEBUG_CREDENTIALS
    DEBUG_VIRTUAL DEBUG_PAGEALLOC DEBUG_OBJECTS DEBUG_KMEMLEAK
    PAGE_POISONING PAGE_POISONING_NO_SANITY INIT_ON_FREE_DEFAULT_ON
    PROVE_LOCKING LOCK_STAT DEBUG_LOCK_ALLOC PROVE_RCU
    KASAN KCSAN UBSAN DEBUG_ATOMIC_SLEEP DEBUG_MUTEXES DEBUG_SPINLOCK
    FTRACE FUNCTION_TRACER STACK_TRACER KPROBES UPROBES
    BPF_SYSCALL BPF_JIT PROFILING LATENCYTOP SCHED_DEBUG
    DEBUG_INFO GDB_SCRIPTS
  )
  for opt in "${force_off[@]}"; do
    scripts/config --file .config --disable "$opt" 2>/dev/null || true
  done
  make olddefconfig > "$LOGS/kernel-olddefconfig2.log" 2>&1 || true

  # ---------------------------------------------------------------------
  # 强制设置「choice 组」与依赖项。
  #
  # 教训（同一类坑踩了两次）：
  #   1) fragment 里写 CONFIG_DEFAULT_TCP_CONG="bbr" 无效 —— 该字符串是
  #      choice 组自动生成的，不是可写选项；必须切换 choice 的成员符号。
  #   2) choice 组的默认成员（DEFAULT_CUBIC / DEFAULT_PFIFO_FAST）必须先
  #      关掉，否则 olddefconfig 保留默认成员，目标成员开了也不生效。
  # ---------------------------------------------------------------------
  log "切换 choice 组：默认 TCP 拥塞控制 → BBR，默认 qdisc → fq"
  scripts/config --file .config --enable   TCP_CONG_BBR       2>/dev/null || true
  scripts/config --file .config --enable   NET_SCH_FQ         2>/dev/null || true
  scripts/config --file .config --enable   NET_SCH_FQ_CODEL   2>/dev/null || true
  # TCP 拥塞控制 choice：关掉默认成员再选 BBR
  scripts/config --file .config --disable  DEFAULT_CUBIC      2>/dev/null || true
  scripts/config --file .config --enable   DEFAULT_BBR        2>/dev/null || true
  # 默认 qdisc choice：关掉 pfifo_fast 再选 fq（BBR 官方推荐搭配）
  scripts/config --file .config --enable   NET_SCH_DEFAULT    2>/dev/null || true
  scripts/config --file .config --disable  DEFAULT_PFIFO_FAST 2>/dev/null || true
  scripts/config --file .config --enable   DEFAULT_FQ         2>/dev/null || true
  # 透明大页：始终开启（服务器/数据库/JVM 友好）
  scripts/config --file .config --enable   TRANSPARENT_HUGEPAGE          2>/dev/null || true
  scripts/config --file .config --enable   TRANSPARENT_HUGEPAGE_ALWAYS   2>/dev/null || true
  scripts/config --file .config --disable  TRANSPARENT_HUGEPAGE_MADVISE  2>/dev/null || true
  scripts/config --file .config --disable  TRANSPARENT_HUGEPAGE_NEVER    2>/dev/null || true
  make olddefconfig > "$LOGS/kernel-olddefconfig3.log" 2>&1 || true

  # 复核：choice 组特别容易被默认值回滚，逐项打印实际结果
  log "复核关键性能项："
  for k in DEFAULT_BBR DEFAULT_FQ DEFAULT_TCP_CONG DEFAULT_NET_SCH TRANSPARENT_HUGEPAGE_ALWAYS; do
    printf '       %-32s %s\n' "$k" "$(grep -E "^CONFIG_${k}=|^# CONFIG_${k} is not set" .config | head -1)"
  done

  # 关闭编译器警告为错误（避免无关构建中断；加固靠显式选项而非 -Werror）
  scripts/config --file .config --disable WERROR 2>/dev/null || true
  make olddefconfig > /dev/null 2>&1 || true

  cp -f .config "$OUT/.config"
  log "配置已生成: $(grep -c '=y$' .config) 个 =y，$(grep -c ' is not set' .config) 个未选"
}

# ---------------------------------------------------------------------------
# 阶段 2：编译
# ---------------------------------------------------------------------------
do_build() {
  hr "编译内核 bzImage（-j$JOBS）"
  cd "$KDIR" || die "cd $KDIR 失败"

  log "make -j$JOBS bzImage"
  local start; start=$(date +%s)
  if make -j"$JOBS" bzImage > "$LOGS/kernel-build.log" 2>&1; then
    local el=$(( $(date +%s) - start ))
    log "编译成功，用时 $((el/60))m$((el%60))s"
  else
    log "编译失败，错误摘要："
    grep -nE 'error:|Error [0-9]' "$LOGS/kernel-build.log" | head -20
    die "内核编译失败（完整日志 $LOGS/kernel-build.log）"
  fi

  [ -f arch/x86/boot/bzImage ] || die "未找到 arch/x86/boot/bzImage"
  cp -f arch/x86/boot/bzImage "$OUT/bzImage"
  cp -f System.map "$OUT/System.map" 2>/dev/null || true
  cp -f vmlinux "$OUT/vmlinux" 2>/dev/null || true
  log "bzImage: $(du -h "$OUT/bzImage" | cut -f1)"
}

# ---------------------------------------------------------------------------
# 阶段 3：门禁
# ---------------------------------------------------------------------------
do_gate() {
  hr "Phase 3 内核门禁"
  local cfg="$OUT/.config"
  [ -f "$cfg" ] || die "缺少 $OUT/.config，请先执行 config"

  local pass=0 fail=0 warn=0
  REPORT="$OUT/config-report.txt"
  : > "$REPORT"

  # cfgval <选项> -> y / n / m / MISSING
  cfgval() {
    if grep -q "^$1=y$" "$cfg"; then echo "y"
    elif grep -q "^$1=m$" "$cfg"; then echo "m"
    elif grep -q "^# $1 is not set$" "$cfg"; then echo "n"
    else echo "-"; fi
  }

  # req <选项> <说明>：必须 =y
  req() {
    local v; v=$(cfgval "$1")
    if [ "$v" = "y" ]; then
      printf '  \033[32m[PASS]\033[0m %-42s %s\n' "$1" "$2"; pass=$((pass+1))
      printf 'PASS %-42s %s\n' "$1" "$2" >> "$REPORT"
    else
      printf '  \033[31m[FAIL]\033[0m %-42s 实际=%s  %s\n' "$1" "$v" "$2"; fail=$((fail+1))
      printf 'FAIL %-42s 实际=%s %s\n' "$1" "$v" "$2" >> "$REPORT"
    fi
  }

  # off <选项> <说明>：必须未启用（裁剪验证）
  # 说明：值可能是 n（显式关闭），也可能是 -（该符号在当前配置下根本不出现，
  #       例如 SOUND 关闭后 SND 不出现）。两者都表示"没有启用该功能"，均判通过。
  off() {
    local v; v=$(cfgval "$1")
    if [ "$v" = "n" ] || [ "$v" = "-" ]; then
      printf '  \033[32m[PASS]\033[0m %-42s 未启用(%s): %s\n' "$1" "$v" "$2"; pass=$((pass+1))
      printf 'PASS %-42s 未启用(%s) %s\n' "$1" "$v" "$2" >> "$REPORT"
    else
      printf '  \033[31m[FAIL]\033[0m %-42s 实际=%s 未裁剪: %s\n' "$1" "$v" "$2"; fail=$((fail+1))
      printf 'FAIL %-42s 实际=%s 未裁剪 %s\n' "$1" "$v" "$2" >> "$REPORT"
    fi
  }

  printf '\n\033[1;33m▶ A. VirtualBox 兼容性（缺一项就起不来）\033[0m\n'
  req CONFIG_ATA                  "IDE/SATA 基础"
  req CONFIG_ATA_PIIX             "VBox 默认 IDE 控制器"
  req CONFIG_SATA_AHCI            "VBox SATA AHCI 控制器"
  req CONFIG_BLK_DEV_SD           "SCSI/SATA 磁盘"
  req CONFIG_EXT4_FS              "根文件系统"
  req CONFIG_DEVTMPFS             "/dev 动态设备节点"
  req CONFIG_DEVTMPFS_MOUNT       "自动挂载 /dev"
  req CONFIG_DRM_VMWGFX           "VBox VMSVGA 显卡（驱动真名 VMWGFX）"
  req CONFIG_FRAMEBUFFER_CONSOLE  "控制台显示"
  req CONFIG_VT                    "虚拟终端"
  req CONFIG_INPUT_KEYBOARD       "键盘输入"
  req CONFIG_KEYBOARD_ATKBD       "PS/2 键盘"
  req CONFIG_E1000                "Intel PRO/1000 网卡"
  req CONFIG_SERIAL_8250          "8250 串口"
  req CONFIG_SERIAL_8250_CONSOLE  "串口控制台（无头调试）"
  req CONFIG_ACPI                 "ACPI 电源/设备枚举"
  req CONFIG_PCI                  "PCI 总线"
  req CONFIG_BLK_DEV_INITRD       "initramfs 支持"
  req CONFIG_RD_GZIP              "gzip initramfs"

  # -------------------------------------------------------------------------
  #  根文件系统支持
  #  踩过的坑：裁剪文件系统时只写了「关掉 btrfs/xfs/ntfs…」，
  #  却漏掉了显式打开 SQUASHFS —— x86_64_defconfig 默认并不启用它。
  #  后果是 initramfs 挂载 squashfs 静默失败，系统直接落到救援 shell，
  #  而内核日志里没有任何「不支持该文件系统」的直白提示，极难排查。
  #  教训：裁剪型配置必须显式声明「需要什么」，不能只声明「不要什么」。
  # -------------------------------------------------------------------------
  printf '\n\033[1;33m▶ A2. 根文件系统支持（squashfs 只读根 / overlay 可写层）\033[0m\n'
  req CONFIG_SQUASHFS             "squashfs 只读根（Live 镜像核心）"
  req CONFIG_SQUASHFS_XZ          "squashfs xz 解压（与 mksquashfs 压缩格式匹配）"
  req CONFIG_SQUASHFS_ZLIB        "squashfs gzip 解压（兼容后备）"
  req CONFIG_BLK_DEV_LOOP         "loop 设备（loop 挂载 squashfs 镜像必需）"
  req CONFIG_OVERLAY_FS           "overlayfs（只读根 + 可写层）"
  req CONFIG_ISO9660_FS           "ISO9660（从光盘读取 rootfs.squashfs）"

  printf '\n\033[1;33m▶ B. 安全加固（KSPP）\033[0m\n'
  req CONFIG_STACKPROTECTOR_STRONG  "栈溢出检测"
  req CONFIG_FORTIFY_SOURCE         "编译期字符串/内存检查"
  req CONFIG_HARDENED_USERCOPY      "copy_to/from_user 边界检查"
  req CONFIG_RANDOMIZE_BASE         "KASLR 内核地址随机化"
  req CONFIG_RANDOMIZE_MEMORY       "内存映射随机化"
  req CONFIG_MITIGATION_PAGE_TABLE_ISOLATION "KPTI 页表隔离（6.x 新符号名）"
  req CONFIG_STRICT_KERNEL_RWX      "内核代码只读/数据不可执行"
  req CONFIG_SLAB_FREELIST_RANDOM   "空闲链表随机化"
  req CONFIG_SLAB_FREELIST_HARDENED "空闲链表加固"
  req CONFIG_RANDOM_KMALLOC_CACHES  "kmalloc 缓存随机化"
  req CONFIG_SHUFFLE_PAGE_ALLOCATOR "页分配器随机化"
  req CONFIG_SECCOMP                "seccomp"
  req CONFIG_SECCOMP_FILTER         "seccomp BPF 过滤"
  req CONFIG_SECURITY               "LSM 框架"
  req CONFIG_SECURITY_SELINUX       "SELinux"
  req CONFIG_SECURITY_DMESG_RESTRICT "dmesg 限制"
  req CONFIG_LEGACY_VSYSCALL_NONE   "关闭 vsyscall 遗留接口"
  req CONFIG_STATIC_USERMODEHELPER  "禁内核调用用户态 helper"
  req CONFIG_INIT_ON_ALLOC_DEFAULT_ON "新分配内存清零"

  printf '\n\033[1;33m▶ C. 低占用裁剪（关闭项）\033[0m\n'
  off CONFIG_MODULES       "无模块单体内核"
  off CONFIG_SOUND         "声音子系统（SND 随之不出现）"
  off CONFIG_WLAN          "无线网络"
  off CONFIG_BT            "蓝牙"
  off CONFIG_DEBUG_INFO    "调试符号（体积杀手）"
  off CONFIG_BTRFS_FS      "btrfs"
  off CONFIG_XFS_FS        "xfs"
  off CONFIG_KVM           "宿主侧虚拟化"
  off CONFIG_DRM_I915      "Intel 核显驱动"
  # 以下是性能杀手级调试项，必须确认真的关掉了
  off CONFIG_SLUB_DEBUG    "SLUB 调试（性能杀手）"
  off CONFIG_DEBUG_VM      "VM 调试（性能杀手）"
  off CONFIG_PAGE_POISONING "页投毒（性能杀手）"
  off CONFIG_DEBUG_LIST    "链表调试（热点路径）"
  off CONFIG_PROVE_LOCKING "lockdep（极大开销）"
  off CONFIG_KASAN         "KASAN 地址消毒器（数倍开销）"
  off CONFIG_FTRACE        "ftrace 追踪框架"
  off CONFIG_KPROBES       "kprobes（设计方案标注可关）"
  # 正面确认：调试符号策略为"无"，是体积控制的关键
  req CONFIG_DEBUG_INFO_NONE "无调试符号（体积控制关键项）"

  printf '\n\033[1;33m▶ D. 性能取向\033[0m\n'
  req CONFIG_SMP                   "多核"
  req CONFIG_PREEMPT_NONE          "服务器抢占模型（吞吐优先）"
  req CONFIG_TCP_CONG_BBR          "BBR 拥塞控制"
  req CONFIG_TRANSPARENT_HUGEPAGE  "透明大页"
  req CONFIG_HZ_1000               "1000Hz 时钟"
  req CONFIG_NETFILTER             "netfilter 框架"
  req CONFIG_NF_TABLES             "nftables"

  printf '\n\033[1;33m▶ E. 产物体积\033[0m\n'
  if [ -f "$OUT/bzImage" ]; then
    local bz_kb bz_mb
    bz_kb=$(du -k "$OUT/bzImage" | cut -f1); bz_mb=$((bz_kb/1024))
    printf '  bzImage 体积: %s (%d KB)\n' "$(du -h "$OUT/bzImage" | cut -f1)" "$bz_kb"
    if [ "$bz_kb" -le 8192 ]; then
      printf '  \033[32m[PASS]\033[0m bzImage ≤ 8MB 目标达成\n'; pass=$((pass+1))
    else
      printf '  \033[33m[WARN]\033[0m bzImage %dKB 超过 8MB 目标（可继续裁剪）\n' "$bz_kb"; warn=$((warn+1))
    fi
    [ -f "$OUT/vmlinux" ] && printf '  vmlinux 体积: %s\n' "$(du -h "$OUT/vmlinux" | cut -f1)"
  else
    printf '  \033[33m[WARN]\033[0m 尚未编译，无 bzImage 可测\n'; warn=$((warn+1))
  fi

  # 记录加固汇总，便于对照 KSPP
  {
    echo
    echo "=== 加固项汇总 ==="
    for k in STACKPROTECTOR_STRONG FORTIFY_SOURCE HARDENED_USERCOPY RANDOMIZE_BASE \
             RANDOMIZE_MEMORY PAGE_TABLE_ISOLATION STRICT_KERNEL_RWX \
             SLAB_FREELIST_RANDOM SLAB_FREELIST_HARDENED RANDOM_KMALLOC_CACHES \
             SHUFFLE_PAGE_ALLOCATOR SECCOMP SECCOMP_FILTER SECURITY_SELINUX \
             SECURITY_DMESG_RESTRICT LEGACY_VSYSCALL_NONE STATIC_USERMODEHELPER \
             INIT_ON_ALLOC_DEFAULT_ON ZERO_CALL_USED_REGS; do
      printf '%-32s %s\n' "CONFIG_$k" "$(cfgval "CONFIG_$k")"
    done
  } >> "$REPORT"

  echo
  echo "============================================================"
  printf '  内核门禁: \033[32m%d 通过\033[0m / \033[33m%d 警告\033[0m / \033[31m%d 失败\033[0m\n' "$pass" "$warn" "$fail"
  echo "  报告: $REPORT"
  if [ "$fail" -eq 0 ]; then
    printf '  \033[1;32m✔ Phase 3 内核门禁通过\033[0m\n'
  else
    printf '  \033[1;31m✗ 有 %d 项未达标，需调整配置片段后重编\033[0m\n' "$fail"
  fi
  echo "============================================================"
  return "$fail"
}

# ---------------------------------------------------------------------------
case "${1:-all}" in
  config) do_config ;;
  build)  do_build ;;
  gate)   do_gate ;;
  all)
    do_config
    do_build
    do_gate
    ;;
  *) die "未知参数: $1（可用 all|config|build|gate）" ;;
esac
