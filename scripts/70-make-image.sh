#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 4b - 可引导磁盘镜像制作（VirtualBox 可直接使用）
#
#  产物：
#    $LFOS/build/img/lfos-boot.raw   原始磁盘镜像（MBR + ext4 + extlinux）
#    $LFOS/build/img/lfos-boot.vdi   VirtualBox 磁盘（qemu-img 转换）
#    $LFOS/build/img/manifest.txt    镜像清单（体积/内容/校验和）
#
#  设计（低占用 + 高安全）：
#    - MBR 分区表 + 单个 ext4 活动分区，1MiB 对齐（虚拟盘性能）
#    - extlinux 作为引导器：极简、无 GRUB 的庞大模块树，攻击面小
#    - 内核参数固化加固开关（slab_nomerge / init_on_alloc / page_alloc.shuffle）
#    - 双控制台：ttyS0（串口→VBox 日志文件）与 tty0（图形窗口）
#
#  用法： bash /opt/lfOS/scripts/70-make-image.sh [all|raw|vdi|gate]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
OUT="$LFOS/build"
IMG="$OUT/img"
KOUT="$OUT/kernel"
LOGS="$LFOS/build/logs"
SIZE_MB="${LFOS_IMAGE_MB:-64}"

mkdir -p "$IMG" "$LOGS"

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

RAW="$IMG/lfos-boot.raw"
VDI="$IMG/lfos-boot.vdi"
MNT="$IMG/.mnt"

cleanup() {
  sync
  mountpoint -q "$MNT" 2>/dev/null && umount "$MNT" 2>/dev/null
  [ -n "${LOOPDEV:-}" ] && losetup -d "$LOOPDEV" 2>/dev/null
  rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
do_raw() {
  hr "制作可引导磁盘镜像 (${SIZE_MB}MiB)"

  [ -f "$KOUT/bzImage" ] || die "缺少内核 $KOUT/bzImage"
  [ -f "$OUT/initramfs-lfos.cpio.gz" ] || die "缺少 initramfs"
  local MBR=/usr/lib/syslinux/mbr/mbr.bin
  [ -f "$MBR" ] || die "缺少 syslinux mbr.bin（apt install syslinux-common）"

  # --- 1. 创建空镜像 ---
  log "创建 ${SIZE_MB}MiB 镜像"
  rm -f "$RAW"
  dd if=/dev/zero of="$RAW" bs=1M count="$SIZE_MB" status=none || die "创建镜像失败"

  # --- 2. 分区表：单分区，2048 扇区(1MiB) 对齐，bootable ---
  log "写入 MBR 分区表（1MiB 对齐）"
  sfdisk "$RAW" > "$LOGS/image-sfdisk.log" 2>&1 <<EOF || die "sfdisk 失败"
label: dos
label-id: 0x1f050001
unit: sectors

start=2048, size=$(( SIZE_MB * 2048 - 2048 )), type=83, bootable
EOF

  # --- 3. loop 关联（-P 让内核识别分区） ---
  LOOPDEV=$(losetup -f --show -P "$RAW") || die "losetup 失败"
  log "loop 设备: $LOOPDEV"
  partprobe "$LOOPDEV" 2>/dev/null || true
  sleep 1
  local pdev="${LOOPDEV}p1"
  [ -b "$pdev" ] || die "分区设备 $pdev 未出现"

  # --- 4. 格式化 ext4（面向虚拟盘/SSD 的参数） ---
  log "格式化 ext4: $pdev"
  mkfs.ext4 -q -F -L lfos -m 0 \
      -O ^has_journal,^resize_inode,sparse_super,large_file \
      "$pdev" > "$LOGS/image-mkfs.log" 2>&1 || die "mkfs.ext4 失败"
  # 说明：关闭日志(^has_journal)以极致省空间 —— 只读引导盘场景可接受；
  #       若后续要做可写根文件系统，应保留日志（去掉 ^has_journal）。

  # --- 5. 挂载并填充 ---
  log "挂载并填充引导文件"
  mkdir -p "$MNT"
  mount "$pdev" "$MNT" || die "挂载失败"
  mkdir -p "$MNT/boot/extlinux" "$MNT/etc"

  cp -f "$KOUT/bzImage" "$MNT/boot/bzImage"
  cp -f "$OUT/initramfs-lfos.cpio.gz" "$MNT/boot/initramfs-lfos.cpio.gz"

  cp -f "$KOUT/.config" "$MNT/boot/kernel.config" 2>/dev/null || true
  cp -f "$KOUT/config-report.txt" "$MNT/boot/kernel-hardening-report.txt" 2>/dev/null || true

  cat > "$MNT/etc/lfos-release" <<'EOF'
lfOS (LumenFluxOS / 流光OS)
高性能 / 高安全 / 低占用 服务器 Linux
EOF

  # --- 6. extlinux 引导配置 ---
  log "写入 extlinux 配置"
  cat > "$MNT/boot/extlinux/extlinux.conf" <<'EOF'
# ============================================================================
#  lfOS (LumenFluxOS / 流光OS) 引导配置
#  引导器：extlinux（Syslinux 家族，极简、无 GRUB 模块树）
# ============================================================================
SERIAL 0 115200
PROMPT 0
TIMEOUT 20
DEFAULT lfos
MENU TITLE lfOS (LumenFluxOS) Boot Menu

LABEL lfos
    MENU LABEL lfOS (LumenFluxOS) - Hardened Server
    LINUX /boot/bzImage
    INITRD /boot/initramfs-lfos.cpio.gz
    # 控制台顺序很重要：内核把「最后一个 console=」作为 /dev/console 的映射目标。
    # 这里把 ttyS0 放在最后，使用户态 /init 的输出也走串口 —— 无头模式下
    # 才能采到启动横幅与自检信息；图形窗口仍能显示内核日志。
    APPEND console=tty0 console=ttyS0,115200 root=/dev/ram0 rw \
           loglevel=7 ignore_loglevel \
           slab_nomerge init_on_alloc=1 init_on_free=0 \
           page_alloc.shuffle=1 pti=on vsyscall=none \
           random.trust_cpu=off \
           oops=panic panic=0

LABEL lfos-quiet
    MENU LABEL lfOS - Quiet Boot
    LINUX /boot/bzImage
    INITRD /boot/initramfs-lfos.cpio.gz
    APPEND console=tty0 console=ttyS0,115200 root=/dev/ram0 rw quiet \
           slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none
EOF

  # --- 7. 安装 extlinux 到分区 VBR ---
  log "安装 extlinux 引导器"
  extlinux --install "$MNT/boot/extlinux" > "$LOGS/image-extlinux.log" 2>&1 \
    || die "extlinux --install 失败（见 $LOGS/image-extlinux.log）"

  # 复制必需的 c32 模块（extlinux 菜单用）
  for m in ldlinux.c32 libutil.c32 menu.c32; do
    [ -f "/usr/lib/syslinux/modules/bios/$m" ] && \
      cp -f "/usr/lib/syslinux/modules/bios/$m" "$MNT/boot/extlinux/"
  done

  sync
  umount "$MNT" || die "卸载失败"
  rmdir "$MNT" 2>/dev/null

  # --- 8. 写入 MBR 引导码 ---
  log "写入 MBR 引导码"
  dd if="$MBR" of="$LOOPDEV" bs=440 count=1 conv=notrunc status=none \
    || die "写入 MBR 失败"
  # 设置分区活动标志（sfdisk 已写 bootable，这里再确认一次）
  sfdisk --activate "$RAW" 1 > "$LOGS/image-activate.log" 2>&1 || true

  sync
  losetup -d "$LOOPDEV"; LOOPDEV=""
  log "raw 镜像完成: $(du -h "$RAW" | cut -f1)"
}

# ---------------------------------------------------------------------------
do_vdi() {
  hr "转换为 VirtualBox VDI"
  [ -f "$RAW" ] || die "缺少 $RAW"
  rm -f "$VDI"
  qemu-img convert -f raw -O vdi "$RAW" "$VDI" \
    > "$LOGS/image-vdi.log" 2>&1 || die "qemu-img 转换失败"
  log "VDI 完成: $(du -h "$VDI" | cut -f1)"
}

# ---------------------------------------------------------------------------
do_gate() {
  hr "镜像门禁"
  local pass=0 fail=0
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

  chk "raw 镜像已生成"            "[ -f '$RAW' ]"
  chk "VDI 镜像已生成"            "[ -f '$VDI' ]"
  chk "MBR 引导签名 (0x55AA)"     "[ \$(xxd -s 510 -l 2 -p '$RAW' 2>/dev/null) = '55aa' ]"
  chk "分区表含 bootable 标志"    "sfdisk -d '$RAW' 2>/dev/null | grep -q 'bootable'"

  # 挂载校验内容
  # 注意：losetup/mount 需要 root。若非 root 运行，这里会失败但并非镜像有问题，
  #       因此区分「权限不足」与「真实损坏」，前者记为 SKIP 而非 FAIL。
  local LOOP2; LOOP2=$(losetup -f --show -P "$RAW" 2>&1)
  if [ -n "$LOOP2" ] && [ -b "$LOOP2" ]; then
    local m="$IMG/.mnt2"
    mkdir -p "$m"
    if mount "${LOOP2}p1" "$m" 2>/dev/null; then
      chk "分区内 /boot/bzImage 存在"                "[ -f '$m/boot/bzImage' ]"
      chk "分区内 initramfs 存在"                    "[ -f '$m/boot/initramfs-lfos.cpio.gz' ]"
      chk "分区内 extlinux.conf 存在"                "[ -f '$m/boot/extlinux/extlinux.conf' ]"
      chk "分区内 ldlinux.sys (引导器已装)"          "[ -f '$m/boot/extlinux/ldlinux.sys' ]"
      echo
      echo "  镜像内容:"
      find "$m" -type f | sed "s|$m|  |" | sort | head -20
      echo
      printf '    %-40s %s\n' "bzImage"          "$(du -h "$m/boot/bzImage" 2>/dev/null | cut -f1)"
      printf '    %-40s %s\n' "initramfs"        "$(du -h "$m/boot/initramfs-lfos.cpio.gz" 2>/dev/null | cut -f1)"
      printf '    %-40s %s\n' "分区已用空间"      "$(du -sh "$m" 2>/dev/null | cut -f1)"
      umount "$m" 2>/dev/null
    else
      printf '  \033[31m[FAIL]\033[0m 分区存在但无法挂载（镜像可能损坏）\n'; fail=$((fail+1))
    fi
    rmdir "$m" 2>/dev/null
    losetup -d "$LOOP2" 2>/dev/null
  else
    # 典型输出：losetup: ... failed to set up loop device: Permission denied
    if [ "$(id -u)" -ne 0 ]; then
      printf '  \033[33m[SKIP]\033[0m 分区内容校验需 root（当前非 root）\n'
      printf '         如需完整校验： sudo bash %s gate\n' "$0"
      # 退而求其次：用 xorriso/文件层校验代替挂载校验
      chk "raw 镜像内含 bzImage 特征串" \
          "grep -qa 'Linux kernel x86 boot executable' '$RAW' 2>/dev/null || strings -a '$RAW' 2>/dev/null | grep -q 'bzImage'"
    else
      printf '  \033[31m[FAIL]\033[0m 无法关联 loop 设备（root 下仍失败，镜像可能损坏）\n'
      printf '         losetup 输出: %s\n' "$LOOP2"
      fail=$((fail+1))
    fi
  fi

  # 清单（若文件由 root 创建则普通用户写不进去，做容错处理）
  if {
    echo "lfOS boot image manifest"
    echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "raw: $RAW  size=$(stat -c%s "$RAW" 2>/dev/null) bytes"
    echo "vdi: $VDI  size=$(stat -c%s "$VDI" 2>/dev/null) bytes"
    echo "sha256(raw): $(sha256sum "$RAW" 2>/dev/null | cut -d' ' -f1)"
    echo "sha256(vdi): $(sha256sum "$VDI" 2>/dev/null | cut -d' ' -f1)"
    echo "bzImage: $(stat -c%s "$KOUT/bzImage" 2>/dev/null) bytes"
    echo "initramfs: $(stat -c%s "$OUT/initramfs-lfos.cpio.gz" 2>/dev/null) bytes"
  } > "$IMG/manifest.txt" 2>/dev/null; then
    printf '  \033[32m[PASS]\033[0m 清单已写入 %s\n' "$IMG/manifest.txt"; pass=$((pass+1))
  else
    printf '  \033[33m[SKIP]\033[0m 清单写入被拒（%s 属主为 root，用 sudo 重跑可写入）\n' "$IMG/manifest.txt"
  fi

  echo
  echo "============================================================"
  printf '  镜像门禁: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ 可引导镜像就绪，可用于 VirtualBox\033[0m\n' \
                    || printf '  \033[1;31m✗ 存在问题\033[0m\n'
  echo "============================================================"
  return "$fail"
}

case "${1:-all}" in
  raw)  do_raw ;;
  vdi)  do_vdi ;;
  gate) do_gate ;;
  all)  do_raw; do_vdi; do_gate ;;
  *) die "未知参数: $1（可用 all|raw|vdi|gate）" ;;
esac
