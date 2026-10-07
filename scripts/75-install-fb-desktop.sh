#!/usr/bin/env bash
# 把 framebuffer 桌面装进 rootfs，并设开机自启
#
# 背景：原先的 /usr/local/bin/lfos-desktop 是拉起 X + XFCE 的，
# 但 X 在 VirtualBox 下起不来（详见该脚本内的说明）。
# 现在改成直接运行自绘桌面，绕开整个 X 栈。
set -uo pipefail
LFOS=/opt/lfOS
D=$LFOS/build/rootfs-desktop
SRC=/mnt/d/lfOS/desktop

ok(){ printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[警告]\033[0m %s\n' "$*"; }

echo "════ 1. 检查目标环境 ════"
printf '  python3: %s\n' "$([ -x "$D/usr/bin/python3" ] && echo 有 || echo 缺)"
printf '  版本:    %s\n' "$("$D/usr/bin/python3" --version 2>/dev/null || chroot "$D" /usr/bin/python3 --version 2>/dev/null || echo '?')"
printf '  /usr/local/lib: %s\n' "$([ -d "$D/usr/local/lib" ] && echo 有 || echo 将创建)"

echo
echo "════ 2. 安装桌面程序与字库 ════"
mkdir -p "$D/usr/local/bin" "$D/usr/local/lib/lfos"
cp -f "$SRC/lfos-desktop.py" "$D/usr/local/bin/lfos-desktop.py" && ok "lfos-desktop.py"
cp -f "$SRC/lfos_font.py"    "$D/usr/local/lib/lfos/lfos_font.py" && ok "lfos_font.py"
chmod 0755 "$D/usr/local/bin/lfos-desktop.py"
ln -sf /usr/local/lib/lfos/lfos_font.py "$D/usr/local/bin/lfos_font.py" 2>/dev/null

# 程序用 sys.path.insert(0, dirname(__file__)) 找字库，
# 所以把字库同目录再放一份软链，双保险
ln -sf /usr/local/lib/lfos/lfos_font.py "$D/usr/local/bin/lfos_font.py" 2>/dev/null

echo
echo "════ 3. 重写启动器（不再走 X）════"
cat > "$D/usr/local/bin/lfos-desktop" <<'DESKEOF'
#!/bin/bash
# lfOS 桌面启动器 —— framebuffer 自绘版
#
# 为什么不用 X：
#   VirtualBox 下五条 X 路线全部实测失败（vboxvideo 内核 Oops / vmwgfx
#   unsupported hypervisor / vesafb 只读模式导致 fbdev 驱动初始化失败 /
#   uvesafb 的 VBE 调用返回 err=-3 / Xorg vesa 探测不到设备）。
#   因此本桌面直接操作 /dev/fb0 自绘，绕开整个 X 栈。
#
# 前提：内核需以 nomodeset + vga=792 启动（由 extlinux.conf 提供），
#       这样 vesafb 才会给出 1024x768x24 的 /dev/fb0。
LOG=/var/log/lfos-desktop.log
exec >> "$LOG" 2>&1
echo "=== $(date) 启动 lfOS framebuffer 桌面 ==="

# 等 framebuffer 就绪（内核可能还没建好 /dev/fb0）
for i in $(seq 1 30); do
    [ -e /dev/fb0 ] && break
    sleep 0.2
done
if [ ! -e /dev/fb0 ]; then
    echo "错误：/dev/fb0 不存在 —— 请确认内核用 nomodeset vga=792 启动"
    exit 1
fi

# 关掉光标闪烁，避免和自绘光标冲突
[ -w /sys/class/graphics/fbcon/cursor_blink ] && echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null

# 让控制台安静一点（写入 tty 的文字会盖住我们的画面）
[ -w /proc/sys/kernel/printk ] && echo 3 > /proc/sys/kernel/printk 2>/dev/null

export PYTHONUNBUFFERED=1
exec /usr/bin/python3 /usr/local/bin/lfos-desktop.py
DESKEOF
chmod 0755 "$D/usr/local/bin/lfos-desktop"
ok "/usr/local/bin/lfos-desktop（改为 framebuffer 桌面）"

echo
echo "════ 4. init 里的接入点（保持指向 lfos-desktop）════"
grep -c 'lfos-desktop' "$D/sbin/init" 2>/dev/null | sed 's/^/  init 引用数: /'
grep -n 'lfos-desktop' "$D/sbin/init" 2>/dev/null | head -3 | sed 's/^/  /'

echo
echo "════ 5. 关掉 systemd 残留（之前已改名）════"
printf '  systemd: %s\n' "$([ -e "$D/usr/lib/systemd/systemd" ] && echo 仍在 || echo 已禁用)"

echo
echo "════ 6. 验证文件 ════"
for f in usr/local/bin/lfos-desktop usr/local/bin/lfos-desktop.py \
         usr/local/lib/lfos/lfos_font.py; do
  [ -e "$D/$f" ] && printf '  \033[32m[有]\033[0m %-42s %s 字节\n' "$f" "$(stat -c%s "$D/$f" 2>/dev/null)" \
                 || printf '  \033[31m[缺]\033[0m %s\n' "$f"
done

echo
echo "════ 7. 语法自检（用 rootfs 的 python3 跑）════"
if [ -x "$D/usr/bin/python3" ]; then
  chroot "$D" /usr/bin/python3 -c "
import ast,sys
for p in ['/usr/local/bin/lfos-desktop.py','/usr/local/lib/lfos/lfos_font.py']:
    ast.parse(open(p).read()); print('  OK', p)
" 2>&1 | sed 's/^/  /'
else
  echo "  rootfs 里没有 python3，无法自检"
fi
echo "DONE"
