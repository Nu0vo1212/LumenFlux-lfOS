#!/usr/bin/env bash
# 给内核加 uvesafb 支持并重新编译
#
# 为什么需要：
#   VirtualBox 的 vboxvideo 内核驱动在 X 设置显示模式时触发空指针解引用
#   （Oops at vbox_crtc_set_base_and_mode, CR2=0x68），DRM 这条路彻底不可用。
#   退到 nomodeset + vesafb 后，vesafb 的分辨率是内核固定的、只读，
#   Xorg 的 fbdev 驱动调用 FBIOPUT_VSCREENINFO 会被内核回写不同参数，
#   报 "succeeded but modified mode" 后启动失败。
#   uvesafb 通过用户空间助手 v86d 真正实现模式设置，正好补上这个短板。
#
# 两个变体共用一个内核：服务器版不传 video=uvesafb 参数，行为不变。
set -uo pipefail

FRAG=/mnt/d/lfOS/config/kernel-lfos-vbox.fragment
LOGS=/opt/lfOS/build/logs

echo "════ 1. 备份 fragment 并加入 uvesafb 配置 ════"
cp -f "$FRAG" "$FRAG.bak-$(date +%s)" 2>/dev/null
if grep -q 'CONFIG_FB_UVESA' "$FRAG" 2>/dev/null; then
  echo "  已包含 CONFIG_FB_UVESA，跳过"
else
  # 插在 CONFIG_FB_EFI 之后，保持归组
  python3 - "$FRAG" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="replace").read()
add = """
# --- uvesafb：用户空间 VESA 模式设置 ---
# 为什么加：VirtualBox 的 vboxvideo 内核驱动会让 Xorg 触发内核 Oops
# （vbox_crtc_set_base_and_mode 空指针，CR2=0x68），DRM 路线不可用；
# 退回 vesafb 后其分辨率固定且只读，Xorg 的 fbdev 驱动无法初始化。
# uvesafb 通过 v86d 实现真正的模式设置，Xorg 才能起来。
# 服务器版不传 video=uvesafb 参数，不受影响，两版共用一个内核。
CONFIG_FB_UVESA=y
CONFIG_FB_CFB_FILLRECT=y
CONFIG_FB_CFB_COPYAREA=y
CONFIG_FB_CFB_IMAGEBLIT=y
"""
anchor = "CONFIG_FB_EFI=y"
if anchor in s:
    s = s.replace(anchor, anchor + "\n" + add, 1)
else:
    s += "\n" + add
open(p, "w", encoding="utf-8").write(s)
print("  已插入")
PYEOF
fi
echo "  --- 当前 FB 相关配置 ---"
grep -nE 'CONFIG_FB|CFB' "$FRAG" | sed 's/^/    /'

echo
echo "════ 2. 重新生成内核配置 + 编译（耗时，后台已启动）════"
cd /opt/lfOS || exit 1
bash /opt/lfOS/scripts/50-build-kernel.sh all 2>&1 | tail -40

echo
echo "════ 3. 编译结果 ════"
ls -lh /opt/lfOS/build/kernel/bzImage 2>/dev/null | awk '{print "  bzImage: "$5}'
echo "  --- 确认 uvesafb 编进去了 ---"
if grep -qa 'uvesafb' /opt/lfOS/build/kernel/bzImage 2>/dev/null; then
  echo "  ✔ bzImage 里出现 uvesafb"
else
  echo "  ✘ 仍然没有 uvesafb —— 需要看 config 是否被 kconfig 接受"
  grep -E 'UVESA|CFB' /opt/lfOS/build/kernel/.config 2>/dev/null | sed 's/^/    /'
fi
echo "DONE-KERNEL-UVESA"
