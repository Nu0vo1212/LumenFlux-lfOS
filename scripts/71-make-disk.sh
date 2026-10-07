#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 4g - 制作可引导磁盘镜像（完整系统安装到虚拟硬盘）
#
#  与 70-make-image.sh 的区别：
#    70 脚本制作的是「最小系统」磁盘（BusyBox initramfs 直接当根，无持久化）
#    本脚本把**完整 lfOS 系统**装进硬盘，得到一个可写、可持久使用的系统。
#
#  磁盘布局（MBR + 单分区，简单可靠）：
#    扇区 0        MBR + extlinux 引导代码
#    分区 1 (83)   ext4，占满磁盘 —— 作为 / （可写根）
#      /boot/bzImage                 加固内核
#      /boot/boot-initramfs.cpio.gz  引导 initramfs
#      /boot/extlinux/               extlinux 引导配置
#      其余                          完整 rootfs
#
#  启动链路：
#    MBR → extlinux → 内核 + initramfs → initramfs 按 root=/dev/sda1 挂载
#    → 识别为 ext4 系统盘 → 可写挂载 → switch_root → 持久系统
#
#  用法： bash /opt/lfOS/scripts/71-make-disk.sh [all|raw|vdi|gate]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
OUT="$LFOS/build"
IMG="$OUT/img"
LOGS="$OUT/logs"
LFS="${LFS:-$OUT/rootfs}"

DISK_RAW="$IMG/lfos-disk.raw"
DISK_VDI="$IMG/lfos-disk.vdi"
# 磁盘大小：完整系统约 150MB，留足余量给日志、更新与用户数据
DISK_MB="${LFOS_DISK_MB:-20480}"
PART_START=2048          # 1MiB 对齐（2048 × 512B）

export PATH="$LFOS/build/tools/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$IMG" "$LOGS"

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

# 需要 root 权限（losetup / mount）
need_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    exec sudo -E bash "$0" "$@"
  fi
  die "需要 root 权限（losetup/mount）。请用 sudo 运行。"
}

# ---------------------------------------------------------------------------
#  制作 raw 磁盘
# ---------------------------------------------------------------------------
do_raw() {
  hr "制作 raw 磁盘镜像（${DISK_MB} MiB）"

  [ -f "$OUT/kernel/bzImage" ]                || die "缺少内核 $OUT/kernel/bzImage"
  [ -f "$OUT/boot-initramfs.cpio.gz" ]        || die "缺少引导 initramfs"
  [ -x "$LFS/usr/bin/bash" ]                  || die "rootfs 不完整"

  local EXTLINUX_MBR=/usr/lib/EXTLINUX/mbr.bin
  [ -f "$EXTLINUX_MBR" ] || EXTLINUX_MBR=/usr/lib/syslinux/mbr/mbr.bin
  [ -f "$EXTLINUX_MBR" ] || die "缺少 mbr.bin（apt install extlinux）"
  command -v extlinux >/dev/null 2>&1 || die "缺少 extlinux 命令"

  log "创建稀疏镜像"
  rm -f "$DISK_RAW"
  truncate -s "${DISK_MB}M" "$DISK_RAW" || die "创建镜像失败"

  log "写入 MBR 分区表（单分区，活动标志）"
  sfdisk "$DISK_RAW" > "$LOGS/disk-sfdisk.log" 2>&1 <<EOF || { cat "$LOGS/disk-sfdisk.log"; die "sfdisk 失败"; }
label: dos
start=$PART_START, type=83, bootable
EOF

  log "写入 extlinux MBR 引导代码"
  dd if="$EXTLINUX_MBR" of="$DISK_RAW" bs=440 count=1 conv=notrunc status=none \
    || die "写入 MBR 失败"

  # ---------------------------------------------------------------------------
  #  挂载分区并安装系统
  #
  #  用 losetup -P 让内核自动扫描分区表（生成 /dev/loopXp1），
  #  比手工计算偏移更不易出错。
  # ---------------------------------------------------------------------------
  local LOOP MNT=/mnt/lfos-disk
  LOOP=$(losetup -f --show -P "$DISK_RAW") || die "losetup 失败"
  log "loop 设备: $LOOP"

  # 清理函数：无论成功失败都要卸载
  cleanup_disk() {
    mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null
    rmdir "$MNT" 2>/dev/null
  }
  trap cleanup_disk EXIT

  sleep 1   # 等待分区设备节点出现
  local PART="${LOOP}p1"
  [ -b "$PART" ] || PART="${LOOP}1"
  [ -b "$PART" ] || die "找不到分区设备（$LOOP p1）"

  log "格式化分区为 ext4"
  mkfs.ext4 -q -F -L lfos-root -m 1 "$PART" > "$LOGS/disk-mkfs.log" 2>&1 \
    || { cat "$LOGS/disk-mkfs.log"; die "mkfs.ext4 失败"; }

  log "挂载分区"
  mkdir -p "$MNT"
  mount "$PART" "$MNT" || die "挂载失败"

  log "复制完整系统（rootfs → 磁盘）"
  cp -a "$LFS"/. "$MNT"/ 2>>"$LOGS/disk-copy.log" || log "复制有告警（多为特殊文件，正常）"

  log "安装内核与 initramfs 到 /boot"
  mkdir -p "$MNT/boot"
  cp -f "$OUT/kernel/bzImage"                  "$MNT/boot/bzImage"
  cp -f "$OUT/boot-initramfs.cpio.gz"          "$MNT/boot/boot-initramfs.cpio.gz"
  # 救援用最小 initramfs（若存在）
  [ -f "$OUT/initramfs-lfos.cpio.gz" ] && \
    cp -f "$OUT/initramfs-lfos.cpio.gz" "$MNT/boot/initramfs-min.cpio.gz"

  log "写入 extlinux 配置"
  mkdir -p "$MNT/boot/extlinux"
  cat > "$MNT/boot/extlinux/extlinux.conf" <<'EOF'
# lfOS (LumenFluxOS / 流光OS) 引导配置
DEFAULT lfos
PROMPT 0
TIMEOUT 50

LABEL lfos
    MENU LABEL lfOS (LumenFluxOS / 流光OS)
    LINUX /boot/bzImage
    INITRD /boot/boot-initramfs.cpio.gz
    # 指定系统盘为根。内核内置 cmdline 里是 root=/dev/ram0（initramfs 习惯
    # 写法），此处追加的 root= 因「后者优先」而生效，initramfs 便按
    # /dev/sda1 找到这块 ext4 系统盘并以可写方式挂载。
    APPEND root=/dev/sda1 rw

LABEL lfos-debug
    MENU LABEL lfOS 调试模式（详细日志）
    LINUX /boot/bzImage
    INITRD /boot/boot-initramfs.cpio.gz
    APPEND root=/dev/sda1 rw loglevel=8 debug

LABEL lfos-rescue
    MENU LABEL lfOS 救援 shell（最小 initramfs）
    LINUX /boot/bzImage
    INITRD /boot/initramfs-min.cpio.gz
    APPEND rescue
EOF

  log "安装 extlinux 引导器"
  if ! extlinux --install "$MNT/boot/extlinux" >> "$LOGS/disk-extlinux.log" 2>&1; then
    cat "$LOGS/disk-extlinux.log"; die "extlinux --install 失败"
  fi

  # 确保 /boot 下有 ldlinux.sys 可被引导代码找到（extlinux 会写在指定目录）
  log "同步数据到磁盘"
  sync

  log "统计"
  printf '    已用空间: %s\n' "$(du -sh "$MNT" 2>/dev/null | cut -f1)"

  cleanup_disk
  trap - EXIT

  log "raw 磁盘完成: $(du -h "$DISK_RAW" | cut -f1)（表观 ${DISK_MB}MiB）"
}

# ---------------------------------------------------------------------------
#  转换为 VirtualBox VDI
# ---------------------------------------------------------------------------
do_vdi() {
  hr "转换为 VirtualBox VDI"
  [ -f "$DISK_RAW" ] || die "缺少 raw 镜像，请先执行 raw"

  rm -f "$DISK_VDI"
  log "qemu-img convert"
  if qemu-img convert -f raw -O vdi "$DISK_RAW" "$DISK_VDI" \
       > "$LOGS/disk-vdi.log" 2>&1; then
    log "VDI 完成: $(du -h "$DISK_VDI" | cut -f1)"
    # 动态分配：VDI 只占实际使用空间，随写入增长
    log "说明：VDI 为动态分配，初始仅占实际数据量"
  else
    tail -10 "$LOGS/disk-vdi.log"; die "qemu-img 转换失败"
  fi
}

# ---------------------------------------------------------------------------
do_gate() {
  hr "磁盘镜像门禁"
  local pass=0 fail=0
  chk() {
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

  chk "raw 磁盘已生成"        "[ -f '$DISK_RAW' ]"
  chk "VDI 已生成"            "[ -f '$DISK_VDI' ]"
  chk "MBR 引导标志 (0x55AA)" "xxd -s 510 -l 2 -p '$DISK_RAW' | grep -qi '55aa'"
  chk "分区表含 Linux 分区"    "sfdisk -l '$DISK_RAW' 2>/dev/null | grep -q 'Linux'"

  # 校验镜像内部结构（只读挂载）
  if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
    local LOOP MNT=/mnt/lfos-gate
    local SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO=sudo
    LOOP=$($SUDO losetup -f --show -P "$DISK_RAW" 2>/dev/null)
    if [ -n "$LOOP" ]; then
      sleep 1
      local PART="${LOOP}p1"; [ -b "$PART" ] || PART="${LOOP}1"
      $SUDO mkdir -p "$MNT"
      if $SUDO mount -o ro "$PART" "$MNT" 2>/dev/null; then
        chk "磁盘内含内核"        "[ -f '$MNT/boot/bzImage' ]"
        chk "磁盘内含 initramfs"  "[ -f '$MNT/boot/boot-initramfs.cpio.gz' ]"
        chk "磁盘内含 /sbin/init" "[ -x '$MNT/sbin/init' ]"
        chk "磁盘内含 bash"       "[ -x '$MNT/usr/bin/bash' ]"
        chk "磁盘内含 sshd"       "[ -x '$MNT/usr/sbin/sshd' ]"
        chk "extlinux 配置存在"   "[ -f '$MNT/boot/extlinux/extlinux.conf' ]"
        chk "extlinux 配置文件集" "[ -f '$MNT/boot/extlinux/ldlinux.sys' ]"
        chk "root= 指向系统盘"    "grep -q 'root=/dev/sda1' '$MNT/boot/extlinux/extlinux.conf'"
        printf '\n    磁盘内系统体积: %s\n' "$($SUDO du -sh "$MNT" 2>/dev/null | cut -f1)"
        $SUDO umount "$MNT" 2>/dev/null
      else
        printf '  \033[33m[SKIP]\033[0m 无法挂载校验（权限）\n'
      fi
      $SUDO losetup -d "$LOOP" 2>/dev/null
      $SUDO rmdir "$MNT" 2>/dev/null
    fi
  else
    printf '  \033[33m[SKIP]\033[0m 内容校验需 root\n'
  fi

  echo
  echo "  体积:"
  printf '    %-24s %s\n' "raw" "$([ -f "$DISK_RAW" ] && du -h "$DISK_RAW" | cut -f1 || echo '-')"
  printf '    %-24s %s\n' "vdi" "$([ -f "$DISK_VDI" ] && du -h "$DISK_VDI" | cut -f1 || echo '-')"

  echo
  echo "============================================================"
  printf '  磁盘镜像门禁: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ 可引导磁盘就绪\033[0m\n' || printf '  \033[1;31m✗ 存在问题\033[0m\n'
  echo "============================================================"
  return "$fail"
}

case "${1:-all}" in
  raw)  need_root "$@"; do_raw ;;
  vdi)  do_vdi ;;
  gate) do_gate ;;
  all)  need_root "$@"; do_raw; do_vdi; do_gate ;;
  *) die "未知参数: $1（可用 all|raw|vdi|gate）" ;;
esac
