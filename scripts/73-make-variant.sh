#!/usr/bin/env bash
# ============================================================================
#  lfOS 双变体构建 —— server（无 UI） / desktop（Windows 10 风格桌面）
#
#  为什么分两版：
#    服务器版追求最小体积与最小攻击面，不需要 Xorg/XFCE 那一整套（约 400MB）；
#    桌面版需要图形栈。两者内核共用（内核里编了 uvesafb，服务器版不传
#    video= 参数即无影响），差异只在 rootfs 与引导参数。
#
#  产物：
#    lfos-server.iso    ~270MB  命令行 + SSH，无图形
#    lfos-desktop.iso   ~700MB  XFCE + Windows 10 主题
#
#  用法：
#    bash 73-make-variant.sh server           # 只构建服务器版
#    bash 73-make-variant.sh desktop          # 只构建桌面版
#    bash 73-make-variant.sh all              # 两个都构建
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
BASE_ROOTFS="$LFOS/build/rootfs"              # 基础（无 UI）
DESK_ROOTFS="$LFOS/build/rootfs-desktop"      # 桌面版
KERNEL="$LFOS/build/kernel/bzImage"
LOGS="$LFOS/build/logs"
IMGDIR="$LFOS/build/img"
WINDIR=/mnt/d/lfOS/build/img
THEMES=/mnt/d/lfOS/build/themes

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[警告]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

mount_pseudo() {
  mkdir -p "$1/proc" "$1/sys" "$1/dev" "$1/dev/pts" 2>/dev/null
  for m in proc sys dev dev/pts; do
    mountpoint -q "$1/$m" 2>/dev/null || mount --bind "/$m" "$1/$m" 2>/dev/null
  done
}
umount_pseudo() {
  for m in dev/pts dev proc sys; do
    mountpoint -q "$1/$m" 2>/dev/null && umount "$1/$m" 2>/dev/null
  done
}
trap 'umount_pseudo "$DESK_ROOTFS"; umount_pseudo "$BASE_ROOTFS"' EXIT

# ---------------------------------------------------------------------------
#  桌面版 rootfs：复制基础版 + 装图形栈
# ---------------------------------------------------------------------------
build_desktop_rootfs() {
  hr "构建桌面版 rootfs"

  if [ ! -d "$BASE_ROOTFS" ]; then
    die "基础 rootfs 不存在: $BASE_ROOTFS"
  fi

  if [ -d "$DESK_ROOTFS" ]; then
    log "桌面版 rootfs 已存在，仅补装缺失组件"
  else
    log "从基础 rootfs 复制（保留属主与硬链接）"
    rm -rf "$DESK_ROOTFS"
    cp -a "$BASE_ROOTFS" "$DESK_ROOTFS" || die "复制失败"
    ok "复制完成: $(du -sh "$DESK_ROOTFS" | cut -f1)"
  fi

  mount_pseudo "$DESK_ROOTFS"

  # --- 换阿里云源（deb.debian.org 实测仅 ~19 kB/s）---
  log "配置 apt 源为阿里云镜像"
  cat > "$DESK_ROOTFS/etc/apt/sources.list" <<'EOF'
deb https://mirrors.aliyun.com/debian trixie main
deb https://mirrors.aliyun.com/debian trixie-updates main
deb https://mirrors.aliyun.com/debian-security trixie-security main
EOF

  log "apt update"
  chroot "$DESK_ROOTFS" apt-get update > "$LOGS/desktop-apt-update.log" 2>&1 || warn "apt update 有告警"

  # --- 装图形栈 ---
  # 说明：分两批装，先 X 基础再 XFCE，便于失败时定位
  log "装 Xorg 基础（约 90MB）"
  chroot "$DESK_ROOTFS" apt-get install -y --no-install-recommends \
    xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-input-evdev \
    xserver-xorg-video-fbdev xserver-xorg-video-vesa \
    xinit xterm x11-utils x11-xserver-utils \
    dbus dbus-x11 fontconfig fontconfig-config fonts-dejavu fonts-dejavu-core \
    > "$LOGS/desktop-apt-x.log" 2>&1
  if [ $? -ne 0 ]; then
    warn "X 基础安装有错误，末尾日志："
    grep -E '^(E:|dpkg: error)' "$LOGS/desktop-apt-x.log" | head -8 | sed 's/^/      /'
  else
    ok "Xorg 基础安装完成"
  fi

  log "装 XFCE 桌面（约 110MB）"
  chroot "$DESK_ROOTFS" apt-get install -y --no-install-recommends \
    xfce4 xfce4-whiskermenu-plugin xfce4-taskmanager xfce4-notifyd \
    xfce4-screenshooter xfce4-terminal thunar thunar-archive-plugin \
    xfce4-panel xfwm4 xfdesktop4 xfce4-session xfce4-settings \
    picom fonts-noto-cjk fonts-liberation \
    accountsservice xdg-utils desktop-file-utils \
    > "$LOGS/desktop-apt-xfce.log" 2>&1
  if [ $? -ne 0 ]; then
    warn "XFCE 安装有错误，末尾日志："
    grep -E '^(E:|dpkg: error)' "$LOGS/desktop-apt-xfce.log" | head -8 | sed 's/^/      /'
  else
    ok "XFCE 安装完成"
  fi

  # --- 装 Windows 10 主题 ---
  log "安装 Windows 10 主题"
  if [ -f "$THEMES/windows10-themes.tar.gz" ]; then
    rm -rf /tmp/lfos-w10 && mkdir -p /tmp/lfos-w10
    tar xzf "$THEMES/windows10-themes.tar.gz" -C /tmp/lfos-w10 2>/dev/null

    # GTK 主题
    if [ -d /tmp/lfos-w10/Windows-10 ]; then
      rm -rf "$DESK_ROOTFS/usr/share/themes/Windows-10"
      cp -a /tmp/lfos-w10/Windows-10 "$DESK_ROOTFS/usr/share/themes/" 2>/dev/null
      ok "GTK 主题 Windows-10"
    fi
    # 图标
    if [ -d /tmp/lfos-w10/Windows-10-Icons ]; then
      rm -rf "$DESK_ROOTFS/usr/share/icons/Windows-10-Icons"
      cp -a /tmp/lfos-w10/Windows-10-Icons "$DESK_ROOTFS/usr/share/icons/" 2>/dev/null
      ok "图标主题 Windows-10-Icons"
    fi
  else
    warn "主题包不存在: $THEMES/windows10-themes.tar.gz（跳过，用系统默认主题）"
  fi

  # --- 桌面配置（面板 / picom / 启动器）---
  log "写入桌面配置"
  DCFG="$DESK_ROOTFS/root/.config/xfce4/xfconf/xfce-perchannel-xml"
  mkdir -p "$DCFG" "$DESK_ROOTFS/root/.config/picom" "$DESK_ROOTFS/etc/X11/xorg.conf.d" \
           "$DESK_ROOTFS/usr/local/bin" "$DESK_ROOTFS/usr/share/backgrounds/lfos"

  # 复用 VM 里已经调好的配置（若存在），否则写一份默认的
  if [ -f /tmp/lfos-desktop-cfg.tar.gz ]; then
    tar xzf /tmp/lfos-desktop-cfg.tar.gz -C "$DESK_ROOTFS" 2>/dev/null
    ok "从已调好的配置导入"
  else
    cat > "$DCFG/xfce4-panel.xml" <<'PEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="40"/>
      <property name="background-style" type="uint" value="1"/>
      <property name="background-rgba" type="array">
        <value type="double" value="0.117647"/>
        <value type="double" value="0.117647"/>
        <value type="double" value="0.117647"/>
        <value type="double" value="0.960000"/>
      </property>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/><value type="int" value="2"/>
        <value type="int" value="3"/><value type="int" value="4"/>
        <value type="int" value="5"/><value type="int" value="6"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu">
      <property name="show-button-title" type="bool" value="false"/>
    </property>
    <property name="plugin-2" type="string" value="tasklist">
      <property name="grouping" type="uint" value="1"/>
      <property name="show-labels" type="bool" value="false"/>
      <property name="flat-buttons" type="bool" value="true"/>
    </property>
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
    </property>
    <property name="plugin-4" type="string" value="systray"/>
    <property name="plugin-5" type="string" value="clock">
      <property name="digital-layout" type="uint" value="3"/>
      <property name="digital-time-format" type="string" value="%H:%M"/>
      <property name="digital-date-format" type="string" value="%Y/%m/%d"/>
    </property>
    <property name="plugin-6" type="string" value="showdesktop"/>
  </property>
</channel>
PEOF
  fi

  # picom（动画）
  cat > "$DESK_ROOTFS/root/.config/picom/picom.conf" <<'PEOF'
# lfOS picom —— Windows 10 风格动画
# VirtualBox 无 Guest Additions 时没有 GL，必须用 xrender 后端
backend = "xrender";
vsync = false;
shadow = true;
shadow-radius = 8;
shadow-opacity = 0.35;
shadow-offset-x = -6;
shadow-offset-y = -6;
shadow-exclude = [ "name = 'xfce4-panel'", "argb = true" ];
fading = true;
fade-in-step = 0.06;
fade-out-step = 0.06;
fade-delta = 8;
corner-radius = 0;
inactive-opacity = 1.0;
active-opacity = 1.0;
blur-background = false;
use-damage = true;
refresh-rate = 0;
dbe = false;
log-level = "warn";
PEOF

  # Xorg 配置：uvesafb + ShadowFB
  # 说明：内核用 video=uvesafb:1024x768-24@60 启动后，uvesafb 支持模式设置，
  # Xorg 的 fbdev 驱动即可正常初始化（这是与 vesafb 的关键差别）
  cat > "$DESK_ROOTFS/etc/X11/xorg.conf.d/20-uvfb.conf" <<'XEOF'
Section "Device"
    Identifier  "lfos-fb"
    Driver      "fbdev"
    Option      "fbdev" "/dev/fb0"
    Option      "ShadowFB" "true"
EndSection
Section "Screen"
    Identifier  "lfos-screen"
    Device      "lfos-fb"
    DefaultDepth 24
EndSection
Section "ServerLayout"
    Identifier  "lfos-layout"
    Screen 0    "lfos-screen"
EndSection
XEOF

  # 桌面启动器
  cat > "$DESK_ROOTFS/usr/local/bin/lfos-desktop" <<'DEOF'
#!/bin/bash
# lfOS 桌面启动器
# 要点：
#  1) lfOS 无 systemd、无 display manager，从 init 直接拉起；
#  2) 必须 setsid 脱离终端，否则会话结束会把 X 一起带走；
#  3) 不要加 -novtswitch，否则 X 不切 VT，屏幕停在文本控制台；
#  4) picom 用 xrender（无 GL）。
LOG=/var/log/lfos-desktop.log
exec >> "$LOG" 2>&1
echo "=== $(date) 启动 lfOS 桌面 ==="
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null; chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-launch >/dev/null 2>&1; then
    eval "$(dbus-launch --sh-syntax)"; export DBUS_SESSION_BUS_ADDRESS
fi
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null
mkdir -p /tmp/.X11-unix; chmod 1777 /tmp/.X11-unix
/usr/bin/Xorg :0 -nolisten tcp -keeptty -logfile /var/log/Xorg.0.log &
XPID=$!
sleep 4
kill -0 "$XPID" 2>/dev/null || { echo "Xorg 启动失败"; exit 1; }
for i in $(seq 1 20); do [ -S /tmp/.X11-unix/X0 ] && break; sleep 0.5; done
command -v picom >/dev/null 2>&1 && picom --config /root/.config/picom/picom.conf >/dev/null 2>&1 &
exec /usr/bin/xfce4-session
DEOF
  chmod 0755 "$DESK_ROOTFS/usr/local/bin/lfos-desktop"

  # 集成到 init
  if [ -f "$DESK_ROOTFS/sbin/init" ] && ! grep -q 'lfos-desktop' "$DESK_ROOTFS/sbin/init" 2>/dev/null; then
    if grep -q '9/9' "$DESK_ROOTFS/sbin/init" 2>/dev/null; then
      sed -i 's|^\(step "9/9 启动交互 shell"\)|# 图形桌面（Windows 10 风格）\n[ -x /usr/local/bin/lfos-desktop ] \&\& setsid /usr/local/bin/lfos-desktop >/dev/null 2>\&1 \&\nsleep 2\n\n\1|' "$DESK_ROOTFS/sbin/init"
      ok "已接入 /sbin/init"
    fi
  fi
  if [ -f "$DESK_ROOTFS/etc/rc.local" ] && ! grep -q 'lfos-desktop' "$DESK_ROOTFS/etc/rc.local" 2>/dev/null; then
    sed -i '/^exit 0/i pgrep -x Xorg >/dev/null 2>\&1 || { [ -x /usr/local/bin/lfos-desktop ] \&\& setsid /usr/local/bin/lfos-desktop >/dev/null 2>\&1 \& }' "$DESK_ROOTFS/etc/rc.local"
  fi

  # --- 收尾：属主归位 + 拍平 squashfs 权限（复用 58 脚本的 owner 逻辑）---
  log "属主归位"
  LFS="$DESK_ROOTFS" bash "$LFOS/scripts/58-finalize.sh" owner >/dev/null 2>&1 || warn "属主归位有告警"

  umount_pseudo "$DESK_ROOTFS"
  ok "桌面版 rootfs 就绪: $(du -sh "$DESK_ROOTFS" | cut -f1)"
}

# ---------------------------------------------------------------------------
#  打包变体 ISO
# ---------------------------------------------------------------------------
pack_variant() {
  local variant="$1"
  local rootfs iso_name append_extra squash

  if [ "$variant" = "server" ]; then
    rootfs="$BASE_ROOTFS"
    iso_name="lfos-server.iso"
    append_extra=""                       # 服务器版不需要图形参数
  else
    rootfs="$DESK_ROOTFS"
    iso_name="lfos-desktop.iso"
    # uvesafb 支持真正的模式设置，Xorg 的 fbdev 驱动才能初始化
    append_extra="video=uvesafb:1024x768-24@60"
  fi

  [ -d "$rootfs" ] || die "rootfs 不存在: $rootfs"
  [ -f "$KERNEL" ] || die "内核不存在: $KERNEL"

  hr "打包 $variant 版"

  # squashfs
  squash="$IMGDIR/rootfs-$variant.squashfs"
  rm -f "$squash"
  log "mksquashfs → $(basename "$squash")"
  mksquashfs "$rootfs" "$squash" \
    -comp gzip -b 128K -all-root -noappend -no-progress \
    -e 'boot/*' 'proc/*' 'sys/*' 'dev/*' 'tmp/*' 'run/*' \
    > "$LOGS/pack-$variant.log" 2>&1 || die "mksquashfs 失败"
  ok "squashfs: $(du -h "$squash" | cut -f1)"

  # ISO 目录结构
  local work="$LFOS/build/iso-$variant"
  rm -rf "$work" && mkdir -p "$work/boot" "$work/isolinux" "$work/EFI/BOOT"

  cp -f "$KERNEL" "$work/boot/bzImage"
  cp -f "$squash" "$work/boot/rootfs.squashfs"
  cp -f "$LFOS/build/boot-initramfs.cpio.gz" "$work/boot/initramfs-lfos.cpio.gz" 2>/dev/null

  # isolinux 配置（BIOS）
  local title="lfOS $variant"
  [ "$variant" = "desktop" ] && title="lfOS Desktop (Windows 10 风格)"
  [ "$variant" = "server" ] && title="lfOS Server"
  cat > "$work/isolinux/isolinux.cfg" <<EOF
DEFAULT lfos
PROMPT 0
TIMEOUT 50
LABEL lfos
    MENU LABEL $title
    LINUX /boot/bzImage
    INITRD /boot/initramfs-lfos.cpio.gz
    APPEND root=/dev/ram0 rw console=tty0 console=ttyS0,115200 $append_extra
EOF

  # 引导文件
  for f in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32 vesamenu.c32; do
    [ -f "/usr/lib/ISOLINUX/$f" ] && cp -f "/usr/lib/ISOLINUX/$f" "$work/isolinux/" 2>/dev/null
  done
  [ -f /usr/lib/syslinux/modules/bios/ldlinux.c32 ] && \
    cp -f /usr/lib/syslinux/modules/bios/*.c32 "$work/isolinux/" 2>/dev/null

  # UEFI
  local efi_img="$LFOS/build/efi-$variant.img"
  if [ -f /usr/lib/grub/x86_64-efi/moddep.lst ] || command -v grub-mkstandalone >/dev/null 2>&1; then
    rm -f "$efi_img"
    dd if=/dev/zero of="$efi_img" bs=1M count=8 status=none 2>/dev/null
    mkfs.vfat "$efi_img" >/dev/null 2>&1
    mmd -i "$efi_img" ::/EFI ::/EFI/BOOT 2>/dev/null
    # 用 GRUB standalone 生成 BOOTX64.EFI
    if command -v grub-mkstandalone >/dev/null 2>&1; then
      local grubcfg=/tmp/grub-$variant.cfg
      cat > "$grubcfg" <<GEOF
set timeout=5
set default=0
menuentry "$title" {
  linux /boot/bzImage root=/dev/ram0 rw console=tty0 $append_extra
  initrd /boot/initramfs-lfos.cpio.gz
}
GEOF
      grub-mkstandalone -O x86_64-efi -o "$work/EFI/BOOT/BOOTX64.EFI" \
        --modules="part_gpt part_msdos fat iso9660 normal linux search search_label" \
        "boot/grub/grub.cfg=$grubcfg" >/dev/null 2>&1
    fi
  fi
  # 若没有 EFI 镜像，跳过（BIOS 仍可用）
  [ -f "$work/EFI/BOOT/BOOTX64.EFI" ] || rmdir "$work/EFI/BOOT" "$work/EFI" 2>/dev/null

  # 生成 ISO
  local iso="$IMGDIR/$iso_name"
  rm -f "$iso"
  local xorriso_args=(-as mkisofs -o "$iso" -V "LFOS_$(echo "$variant" | tr a-z A-Z)" -J -R
                      -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot
                      -boot-load-size 4 -boot-info-table)
  [ -f "$work/EFI/BOOT/BOOTX64.EFI" ] && xorriso_args+=(-eltorito-alt-boot -e EFI/BOOT/BOOTX64.EFI -no-emul-boot)

  if xorriso "${xorriso_args[@]}" "$work" > "$LOGS/iso-$variant.log" 2>&1; then
    ok "$iso_name: $(du -h "$iso" | cut -f1)"
    # 混合 MBR
    isohybrid "$iso" >/dev/null 2>&1 && ok "已写入混合 MBR（可 dd 到 U 盘）"
  else
    warn "xorriso 失败，日志末尾："
    tail -8 "$LOGS/iso-$variant.log" | sed 's/^/      /'
    return 1
  fi

  # 同步到 Windows 侧
  cp -f "$iso" "$WINDIR/$iso_name" 2>/dev/null && chown lfos:lfos "$WINDIR/$iso_name" 2>/dev/null
  local a b
  a=$(stat -c%s "$iso" 2>/dev/null || echo 0)
  b=$(stat -c%s "$WINDIR/$iso_name" 2>/dev/null || echo 0)
  [ "$a" = "$b" ] && ok "已同步到 Windows: $iso_name ($a 字节)" || warn "同步不一致 WSL=$a Win=$b"
}

# ---------------------------------------------------------------------------
case "${1:-all}" in
  server)  pack_variant server ;;
  desktop) build_desktop_rootfs; pack_variant desktop ;;
  desktop-only) pack_variant desktop ;;
  all)     pack_variant server; build_desktop_rootfs; pack_variant desktop ;;
  *) echo "用法: $0 {server|desktop|desktop-only|all}"; exit 1 ;;
esac

hr "汇总"
ls -lh "$IMGDIR"/lfos-*.iso 2>/dev/null | awk '{print "  "$5"  "$9}'
