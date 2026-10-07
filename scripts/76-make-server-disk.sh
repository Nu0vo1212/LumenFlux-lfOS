#!/usr/bin/env bash
# 生成服务器版磁盘镜像（extlinux 引导，可持久化写入）
#
# 与 ISO 的区别：ISO 是 Live（overlay，重启还原），磁盘是可持久系统。
# 服务器版不需要图形，因此引导参数保持纯净，不带 nomodeset/vga 等。
set -uo pipefail
LFOS=/opt/lfOS
ROOTFS=$LFOS/build/rootfs
IMGDIR=$LFOS/build/img
WINDIR=/mnt/d/lfOS/build/img
LOGS=$LFOS/build/logs

ok(){ printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[警告]\033[0m %s\n' "$*"; }

RAW=$LFOS/build/server-disk.raw
SIZE_MB=2048

echo "════ 1. 创建磁盘（${SIZE_MB}MB）════"
rm -f "$RAW"
truncate -s "${SIZE_MB}M" "$RAW" || { warn "创建失败"; exit 1; }
ok "raw $(du -h "$RAW" | cut -f1)"

echo
echo "════ 2. 分区 + ext4 ════"
sfdisk "$RAW" > /dev/null 2>&1 <<'EOF'
label: dos
unit: sectors
start=2048, type=83, bootable
EOF
LOOP=$(losetup -f --show -o 1048576 "$RAW" 2>/dev/null)
[ -n "$LOOP" ] || { warn "losetup 失败"; exit 1; }
mkfs.ext4 -q -F -L lfos "$LOOP" > "$LOGS/server-mkfs.log" 2>&1 || { warn "mkfs 失败"; losetup -d "$LOOP"; exit 1; }
ok "ext4 已创建 ($LOOP)"

MNT=/tmp/server-mnt
mkdir -p "$MNT"; umount "$MNT" 2>/dev/null
mount "$LOOP" "$MNT" || { warn "挂载失败"; losetup -d "$LOOP"; exit 1; }

echo
echo "════ 3. 灌入服务器版 rootfs ════"
tar -C "$ROOTFS" --exclude=./proc --exclude=./sys --exclude=./dev \
    --exclude=./tmp --exclude=./run --exclude=./var/cache/apt \
    -cf - . 2>/dev/null | tar -C "$MNT" -xf - 2>/dev/null
sync
ok "灌入完成: $(df -h "$MNT" | tail -1 | awk '{print $3" / "$2}')"

echo
echo "════ 4. 安装 extlinux 引导 ════"
mkdir -p "$MNT/boot/extlinux"
cp -f "$LFOS/build/kernel/bzImage" "$MNT/boot/bzImage"
cp -f "$LFOS/build/boot-initramfs.cpio.gz" "$MNT/boot/boot-initramfs.cpio.gz" 2>/dev/null

cat > "$MNT/boot/extlinux/extlinux.conf" <<'EOF'
# lfOS Server 引导配置
#
# 服务器版不含图形栈，因此引导参数保持纯净。
# （对比：桌面版曾需要 nomodeset + vga=792 才能让 vesafb 提供 framebuffer，
#   那是 Xorg 时代的需求；现在服务器版无需任何显示相关参数。）
DEFAULT lfos
PROMPT 0
TIMEOUT 50

LABEL lfos
    MENU LABEL lfOS Server (LumenFluxOS / 流光OS)
    LINUX /boot/bzImage
    INITRD /boot/boot-initramfs.cpio.gz
    APPEND root=/dev/sda1 rw console=tty0 console=ttyS0,115200 quiet

LABEL lfos-verbose
    MENU LABEL lfOS Server（完整启动日志）
    LINUX /boot/bzImage
    INITRD /boot/boot-initramfs.cpio.gz
    APPEND root=/dev/sda1 rw console=tty0 console=ttyS0,115200 loglevel=7
EOF
ok "extlinux.conf 已写入"

if command -v extlinux >/dev/null 2>&1; then
  extlinux --install "$MNT/boot/extlinux" > "$LOGS/server-extlinux.log" 2>&1 \
    && ok "extlinux 已安装" || warn "extlinux --install 失败"
  MBR=$(find /usr -name 'mbr.bin' 2>/dev/null | head -1)
  [ -n "$MBR" ] && dd if="$MBR" of="$RAW" bs=440 count=1 conv=notrunc status=none 2>/dev/null && ok "MBR 已写入"
fi

echo
echo "════ 5. 卸载并同步到 Windows（保留 RAW，由 Windows 侧转 VDI）════"
umount "$MNT" 2>/dev/null
losetup -d "$LOOP" 2>/dev/null
rmdir "$MNT" 2>/dev/null
cp -f "$RAW" "$WINDIR/lfos-server-disk.raw" 2>/dev/null && ok "已同步 RAW: lfos-server-disk.raw"

echo
echo "════ 6. 校验 ════"
LOOP2=$(losetup -f --show -o 1048576 "$RAW" 2>/dev/null)
if [ -n "$LOOP2" ]; then
  mkdir -p "$MNT"; mount -o ro "$LOOP2" "$MNT" 2>/dev/null
  for f in boot/bzImage boot/extlinux/extlinux.conf boot/extlinux/ldlinux.sys \
           usr/sbin/sshd usr/sbin/nft usr/bin/apt; do
    [ -e "$MNT/$f" ] && printf '  \033[32m[有]\033[0m %s\n' "$f" || printf '  \033[31m[缺]\033[0m %s\n' "$f"
  done
  echo "  --- 确认无 UI ---"
  for c in usr/bin/Xorg usr/bin/xfce4-session; do
    [ -e "$MNT/$c" ] && printf '  \033[33m[有]\033[0m %s（意外）\n' "$c" || printf '  \033[32m[无]\033[0m %s ✓\n' "$c"
  done
  umount "$MNT" 2>/dev/null
  losetup -d "$LOOP2" 2>/dev/null
fi
echo "DONE-SERVER-DISK"
