#!/usr/bin/env bash
# 构建两个变体 ISO：
#   lfos-server.iso   服务器版（无 UI）—— 用构建树里的精简 rootfs
#   lfos-desktop.iso  桌面版（XFCE + Win10 主题）—— 用 VM 磁盘里已装好的 rootfs
#
# 为什么桌面版从 VM 磁盘提取：
#   在构建机上重装 200MB 依赖需要十几分钟，而 VM 磁盘里那套是已经装好、
#   主题和配置都已就位、并且人工验证过各组件齐全的，直接提取更可靠。
set -uo pipefail

LFOS=/opt/lfOS
IMGDIR="$LFOS/build/img"
WINDIR=/mnt/d/lfOS/build/img
LOGS="$LFOS/build/logs"
KERNEL="$LFOS/build/kernel/bzImage"
INITRD="$LFOS/build/boot-initramfs.cpio.gz"

hr(){ printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
ok(){ printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[警告]\033[0m %s\n' "$*"; }
die(){ printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 打包 ISO 的公共函数
#   $1=变体名  $2=rootfs 目录  $3=额外引导参数
# ---------------------------------------------------------------------------
pack_iso() {
  local variant="$1" rootfs="$2" extra="$3"
  local title
  case "$variant" in
    server)  title="lfOS Server (LumenFluxOS) - 无图形界面" ;;
    desktop) title="lfOS Desktop (Windows 10 风格) - XFCE" ;;
  esac

  hr "打包 $variant"

  local squash="$IMGDIR/rootfs-$variant.squashfs"
  rm -f "$squash"
  echo "  rootfs: $rootfs ($(du -sh "$rootfs" 2>/dev/null | cut -f1))"
  mksquashfs "$rootfs" "$squash" -comp gzip -b 128K -all-root -noappend -no-progress \
    -e 'boot/*' 'proc/*' 'sys/*' 'dev/*' 'tmp/*' 'run/*' 'var/cache/apt/*' \
    > "$LOGS/sq-$variant.log" 2>&1 || die "mksquashfs 失败"
  ok "squashfs: $(du -h "$squash" | cut -f1)"

  local work="$LFOS/build/iso-$variant"
  rm -rf "$work"; mkdir -p "$work/boot" "$work/isolinux"
  cp -f "$KERNEL" "$work/boot/bzImage"
  cp -f "$squash" "$work/boot/rootfs.squashfs"
  [ -f "$INITRD" ] && cp -f "$INITRD" "$work/boot/initramfs-lfos.cpio.gz"

  cat > "$work/isolinux/isolinux.cfg" <<EOF
DEFAULT lfos
PROMPT 0
TIMEOUT 50
LABEL lfos
    MENU LABEL $title
    LINUX /boot/bzImage
    INITRD /boot/initramfs-lfos.cpio.gz
    APPEND root=/dev/ram0 rw console=tty0 console=ttyS0,115200 $extra
EOF

  # 引导文件：从系统里找 isolinux/syslinux 的模块
  local found=0
  for d in /usr/lib/ISOLINUX /usr/lib/syslinux/modules/bios /usr/share/syslinux; do
    [ -d "$d" ] || continue
    for f in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32 vesamenu.c32; do
      [ -f "$d/$f" ] && { cp -f "$d/$f" "$work/isolinux/" 2>/dev/null; found=1; }
    done
  done
  [ "$found" = "0" ] && warn "找不到 isolinux 引导文件，ISO 可能无法引导"

  ls "$work/isolinux/" | sed 's/^/    /'

  local iso="$IMGDIR/lfos-$variant.iso"
  rm -f "$iso"
  if xorriso -as mkisofs -o "$iso" -V "LFOS_$(echo "$variant"|tr a-z A-Z)" -J -R \
      -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot \
      -boot-load-size 4 -boot-info-table "$work" > "$LOGS/iso-$variant.log" 2>&1; then
    ok "ISO: $(du -h "$iso" | cut -f1)"
    isohybrid "$iso" >/dev/null 2>&1 && ok "已写混合 MBR"
  else
    warn "xorriso 失败:"; tail -5 "$LOGS/iso-$variant.log" | sed 's/^/      /'
    return 1
  fi

  cp -f "$iso" "$WINDIR/lfos-$variant.iso" 2>/dev/null
  chown lfos:lfos "$WINDIR/lfos-$variant.iso" 2>/dev/null
  local a b
  a=$(stat -c%s "$iso" 2>/dev/null || echo 0); b=$(stat -c%s "$WINDIR/lfos-$variant.iso" 2>/dev/null || echo 0)
  [ "$a" = "$b" ] && ok "已同步 Windows 侧 ($a 字节)" || warn "同步不一致"
}

# ---------------------------------------------------------------------------
# 桌面版 rootfs：从 VM 磁盘提取
# ---------------------------------------------------------------------------
extract_desktop_rootfs() {
  hr "提取桌面版 rootfs（从 VM 磁盘）"
  local vdi=/mnt/d/lfOS/build/img/lfos-disk.vdi
  local mnt=/mnt/lfos-vdi
  local out="$LFOS/build/rootfs-desktop"

  [ -f "$vdi" ] || die "找不到 VM 磁盘: $vdi"

  # 已提取过就直接用
  if [ -d "$out/usr/bin/xfce4-session" ] || [ -x "$out/usr/bin/xfce4-session" ]; then
    ok "桌面版 rootfs 已存在，跳过提取"
    return 0
  fi

  mkdir -p "$mnt"
  umount "$mnt" 2>/dev/null
  echo "  挂载 VDI（只读，通过 qemu-nbd 或 loop 分区）"
  # VDI 不能直接 loop 挂载，需要先转成 raw 再用 offset 挂分区
  local raw=/tmp/lfos-disk.raw
  VBoxManage clonemedium disk "$vdi" "$raw" --format RAW > /dev/null 2>&1 || \
    die "VBoxManage 转换 VDI→RAW 失败"

  # 分区 1 的偏移：起始扇区 2048 × 512 = 1048576
  local offset=1048576
  if mount -o loop,ro,offset=$offset "$raw" "$mnt" 2>/dev/null; then
    echo "  已挂载"
    rm -rf "$out"
    echo "  复制文件（保留属主/权限）…"
    # 排除伪文件系统与缓存
    mkdir -p "$out"
    tar -C "$mnt" --exclude=./proc --exclude=./sys --exclude=./dev \
        --exclude=./tmp --exclude=./run --exclude=./var/cache/apt \
        -cf - . 2>/dev/null | tar -C "$out" -xf - 2>/dev/null
    ok "复制完成: $(du -sh "$out" 2>/dev/null | cut -f1)"
    echo "  --- 关键组件核对 ---"
    for c in usr/bin/xfce4-session usr/bin/xfwm4 usr/bin/xfce4-panel usr/bin/picom \
             usr/bin/Xorg usr/lib/xorg/modules/drivers/fbdev_drv.so; do
      [ -e "$out/$c" ] && printf '    [有] %s\n' "$c" || printf '    \033[31m[缺]\033[0m %s\n' "$c"
    done
    printf '    主题: %s\n' "$([ -d "$out/usr/share/themes/Windows-10" ] && echo Windows-10 || echo 缺)"
    printf '    图标: %s\n' "$([ -d "$out/usr/share/icons/Windows-10-Icons" ] && echo Windows-10-Icons || echo 缺)"
    umount "$mnt"
  else
    warn "挂载失败，桌面版 ISO 将跳过"
    rm -f "$raw"
    return 1
  fi
  rm -f "$raw"
  rmdir "$mnt" 2>/dev/null
}

case "${1:-all}" in
  server)  pack_iso server "$LFOS/build/rootfs" "" ;;
  desktop) extract_desktop_rootfs && pack_iso desktop "$LFOS/build/rootfs-desktop" "nomodeset video=uvesafb:1024x768-24@60" ;;
  all)
    pack_iso server "$LFOS/build/rootfs" ""
    if extract_desktop_rootfs; then
      pack_iso desktop "$LFOS/build/rootfs-desktop" "nomodeset video=uvesafb:1024x768-24@60"
    fi
    ;;
  *) echo "用法: $0 {server|desktop|all}"; exit 1 ;;
esac

hr "产物"
ls -lh "$IMGDIR"/lfos-*.iso 2>/dev/null | awk '{print "  "$5"  "$9}'
