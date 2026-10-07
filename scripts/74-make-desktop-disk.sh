#!/usr/bin/env bash
# 生成「桌面版磁盘镜像」——因为 ISO(isolinux) 拿不到 framebuffer，
# 而磁盘(extlinux) 能通过引导协议正确传递 vga=792，让 vesafb 给出 1024x768。
set -uo pipefail
LFOS=/opt/lfOS
DESK=$LFOS/build/rootfs-desktop
IMGDIR=$LFOS/build/img
WINDIR=/mnt/d/lfOS/build/img
LOGS=$LFOS/build/logs

ok(){ printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[警告]\033[0m %s\n' "$*"; }

RAW=$LFOS/build/desktop-disk.raw
VDI=$IMGDIR/lfos-desktop-disk.vdi
SIZE_MB=4096

echo "════ 1. 创建磁盘镜像（${SIZE_MB}MB）════"
rm -f "$RAW" "$VDI"
truncate -s "${SIZE_MB}M" "$RAW" || { warn "创建失败"; exit 1; }
ok "raw: $(du -h "$RAW" | cut -f1)"

echo
echo "════ 2. 分区 + 文件系统 ════"
# 分区表：1 个分区，起始 2048 扇区（1MiB 对齐），可引导
sfdisk "$RAW" > /dev/null 2>&1 <<'EOF'
label: dos
unit: sectors
start=2048, type=83, bootable
EOF

LOOP=$(losetup -f --show -o 1048576 "$RAW" 2>/dev/null)
[ -n "$LOOP" ] || { warn "losetup 失败"; exit 1; }
ok "loop: $LOOP"

mkfs.ext4 -q -F -L lfos-desk "$LOOP" > "$LOGS/desk-mkfs.log" 2>&1 || { warn "mkfs 失败"; losetup -d "$LOOP"; exit 1; }
ok "ext4 已创建"

MNT=/tmp/desk-mnt
mkdir -p "$MNT"; umount "$MNT" 2>/dev/null
mount "$LOOP" "$MNT" || { warn "挂载失败"; losetup -d "$LOOP"; exit 1; }
ok "已挂载"

echo
echo "════ 3. 灌入桌面 rootfs（排除伪文件系统）════"
tar -C "$DESK" --exclude=./proc --exclude=./sys --exclude=./dev \
    --exclude=./tmp --exclude=./run --exclude=./var/cache/apt \
    -cf - . 2>/dev/null | tar -C "$MNT" -xf - 2>/dev/null
sync
ok "灌入完成: $(df -h "$MNT" | tail -1 | awk '{print $3" / "$2}')"

echo
echo "════ 4. 安装 extlinux 引导（关键：它能正确传 vga=792）════"
mkdir -p "$MNT/boot/extlinux"
cp -f "$LFOS/build/kernel/bzImage" "$MNT/boot/bzImage"
cp -f "$LFOS/build/boot-initramfs.cpio.gz" "$MNT/boot/boot-initramfs.cpio.gz" 2>/dev/null
# 校验和文件（extlinux 要求）
[ -f "$LFOS/build/kernel/bzImage" ] && cp -f "$LFOS/build/kernel/bzImage" "$MNT/boot/bzImage"

cat > "$MNT/boot/extlinux/extlinux.conf" <<'EOF'
# lfOS Desktop 引导配置
#
# 关键：vga=792 = 1024x768x24。
# extlinux 会把它作为引导协议的 vid_mode 传给内核，vesafb 才能拿到模式；
# 换成 isolinux（ISO 引导）时该字段不会被正确传递，内核就退回 80x25 文本模式、
# 连 /dev/fb0 都没有 —— 这是实测结论。
DEFAULT lfos
PROMPT 0
TIMEOUT 50

LABEL lfos
    MENU LABEL lfOS Desktop (Windows 10 style) - XFCE
    LINUX /boot/bzImage
    INITRD /boot/boot-initramfs.cpio.gz
    APPEND root=/dev/sda1 rw nomodeset vga=792

LABEL lfos-debug
    MENU LABEL lfOS Desktop 调试模式
    LINUX /boot/bzImage
    INITRD /boot/boot-initramfs.cpio.gz
    APPEND root=/dev/sda1 rw nomodeset vga=792 loglevel=8 debug

LABEL lfos-server
    MENU LABEL lfOS Desktop（无图形，纯命令行）
    LINUX /boot/bzImage
    INITRD /boot/boot-initramfs.cpio.gz
    APPEND root=/dev/sda1 rw
EOF
ok "extlinux.conf 已写入"

# 安装 extlinux 引导代码
if command -v extlinux >/dev/null 2>&1; then
  extlinux --install "$MNT/boot/extlinux" > "$LOGS/desk-extlinux.log" 2>&1 \
    && ok "extlinux 已安装到 /boot/extlinux" \
    || warn "extlinux --install 失败: $(tail -2 "$LOGS/desk-extlinux.log" | tr '\n' ' ')"
  # 写 MBR 引导代码
  MBR=/usr/lib/syslinux/mbr/mbr.bin
  [ -f "$MBR" ] || MBR=$(find /usr -name 'mbr.bin' 2>/dev/null | head -1)
  if [ -n "$MBR" ] && [ -f "$MBR" ]; then
    dd if="$MBR" of="$RAW" bs=440 count=1 conv=notrunc status=none 2>/dev/null \
      && ok "MBR 引导代码已写入（$(basename "$MBR")）"
  else
    warn "找不到 mbr.bin"
  fi
else
  warn "构建机没有 extlinux 命令（apt install extlinux）"
  # 退而求其次：从已有 rootfs 里拷 syslinux 的 mbr
  for c in /usr/lib/EXTLINUX/extlinux /sbin/extlinux; do
    [ -x "$c" ] && { "$c" --install "$MNT/boot/extlinux" && ok "用 $c 安装成功"; break; }
  done
fi

echo
echo "════ 5. 卸载并转成 VDI ════"
umount "$MNT" 2>/dev/null
losetup -d "$LOOP" 2>/dev/null
if command -v VBoxManage >/dev/null 2>&1; then
  VBoxManage convertfromraw "$RAW" "$VDI" --format VDI > "$LOGS/desk-vdi.log" 2>&1 \
    && ok "VDI: $(du -h "$VDI" | cut -f1)" || warn "转 VDI 失败（VBoxManage 不可用，可能在 WSL 里）"
else
  warn "构建机无 VBoxManage（它是 Windows 程序），保留 RAW"
  cp -f "$RAW" "$WINDIR/lfos-desktop-disk.raw" 2>/dev/null && ok "RAW 已同步到 Windows: lfos-desktop-disk.raw"
fi

echo
echo "════ 6. 校验镜像内容 ════"
LOOP2=$(losetup -f --show -o 1048576 "$RAW" 2>/dev/null)
if [ -n "$LOOP2" ]; then
  mkdir -p "$MNT"; mount -o ro "$LOOP2" "$MNT" 2>/dev/null
  for f in boot/bzImage boot/extlinux/extlinux.conf boot/extlinux/ldlinux.sys \
           usr/bin/Xorg usr/bin/xfce4-session usr/share/themes/Windows-10; do
    [ -e "$MNT/$f" ] && printf '  \033[32m[有]\033[0m %s\n' "$f" || printf '  \033[31m[缺]\033[0m %s\n' "$f"
  done
  printf '  extlinux.conf 的 APPEND: %s\n' "$(grep -m1 APPEND "$MNT/boot/extlinux/extlinux.conf" 2>/dev/null | sed 's/^\s*//')"
  umount "$MNT" 2>/dev/null
  losetup -d "$LOOP2" 2>/dev/null
fi
echo "DONE-DESK-DISK"
