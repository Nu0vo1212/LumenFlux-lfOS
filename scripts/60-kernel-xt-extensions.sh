#!/usr/bin/env bash
# 给内核补 ufw 需要的 4 个 netfilter 扩展，然后重编
#
# 为什么要补（实测 ufw 官方规则用到的 match/target 与内核对不上）：
#   before.rules   : -m addrtype / -m conntrack / -m limit
#   before6.rules  : -m conntrack / -m hl / -m rt
#   user.rules     : -m conntrack / -m limit / -j REJECT
# 缺的 4 项：
#   CONFIG_NETFILTER_XT_MATCH_LIMIT    ufw 的速率限制规则
#   CONFIG_NETFILTER_XT_MATCH_HL       IPv6 hop-limit 匹配
#   CONFIG_NETFILTER_XT_MATCH_RT       IPv6 路由头匹配
#   CONFIG_NETFILTER_XT_TARGET_REJECT  ufw 默认用 REJECT 拒绝（而非 DROP）
#
# 不补的后果：ufw 能启用，但日志里刷
#   Warning: Extension limit revision 0 not supported, missing kernel module?
# 且对应的规则实际不生效（静默失效，最危险）。
set -uo pipefail
FRAG=/mnt/d/lfOS/config/kernel-lfos-vbox.fragment

echo "════ 1. 备份 fragment ════"
cp -f "$FRAG" "$FRAG.bak-xtext-$(date +%s)" 2>/dev/null && echo "  已备份"

echo
echo "════ 2. 加入 4 个 netfilter 扩展 ════"
python3 - "$FRAG" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="replace").read()

add = """
# --- ufw 所需的 netfilter 扩展（实测 ufw 官方规则会用到）---
# 说明：ufw 的 before.rules / before6.rules / user.rules 里出现了
#   -m limit（速率限制）、-m hl 与 -m rt（IPv6 hop-limit / 路由头）、
#   -j REJECT（ufw 默认用 REJECT 拒绝，而非静默 DROP）。
# 不启用这些时 ufw 仍能跑，但会刷
#   Warning: Extension limit revision 0 not supported, missing kernel module?
# 且相关规则静默失效 —— 这种「看起来生效、实际没拦」最危险，故补齐。
CONFIG_NETFILTER_XT_MATCH_LIMIT=y
CONFIG_NETFILTER_XT_MATCH_HL=y
CONFIG_NETFILTER_XT_MATCH_RT=y
CONFIG_NETFILTER_XT_TARGET_REJECT=y
"""

if "CONFIG_NETFILTER_XT_MATCH_LIMIT=y" in s:
    print("  已存在，跳过")
else:
    # 插到已有的 xt 扩展附近，保持归组
    marker = "CONFIG_NETFILTER_XT_MATCH_STATE=y"
    if marker in s:
        s = s.replace(marker, marker + "\n" + add, 1)
    else:
        s += "\n" + add
    open(p, "w", encoding="utf-8").write(s)
    print("  已插入")
PYEOF

echo "  --- 当前相关配置 ---"
grep -nE 'XT_MATCH_(LIMIT|HL|RT)|XT_TARGET_REJECT' "$FRAG" | sed 's/^/    /'

echo
echo "════ 3. 重编内核（后台，约 10-20 分钟）════"
cd /opt/lfOS || exit 1
bash /opt/lfOS/scripts/50-build-kernel.sh all 2>&1 | tail -30

echo
echo "════ 4. 确认编入 ════"
K=/opt/lfOS/build/kernel
for c in NETFILTER_XT_MATCH_LIMIT NETFILTER_XT_MATCH_HL NETFILTER_XT_MATCH_RT NETFILTER_XT_TARGET_REJECT; do
  v=$(grep -E "^CONFIG_${c}=" "$K/.config" 2>/dev/null | cut -d= -f2)
  printf '  %-34s %s\n' "$c" "${v:-未设置}"
done
echo "  --- vmlinux 符号验证 ---"
for sym in xt_limit xt_reject limit_mt; do
  n=$(nm "$K/vmlinux" 2>/dev/null | grep -c "$sym")
  printf '    %-14s %s\n' "$sym" "$([ "$n" -gt 0 ] && echo "有($n)" || echo 无)"
done
ls -lh "$K/bzImage" | awk '{print "  bzImage: "$5}'
echo "DONE-KERNEL-XT"
