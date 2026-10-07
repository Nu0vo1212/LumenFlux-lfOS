#!/usr/bin/env bash
# 修正 fragment 里的 ufw 相关内核项，然后重编
#
# 教训（值得记下来）：
#   我原先写了两行 CONFIG_NETFILTER_XT_TARGET_REJECT=y 与
#   CONFIG_NETFILTER_XT_MATCH_RT=y —— 这两个符号在 Linux 6.15 里**不存在**。
#   kconfig 对未知符号是**静默忽略**的（既不报错也不写进 .config），
#   所以从 .config 里根本看不出问题，只能靠翻 Kconfig/Makefile 才能发现。
#   正确符号是：
#     -j REJECT（iptables）→ CONFIG_IP_NF_TARGET_REJECT / IP6_NF_TARGET_REJECT（已启用）
#     -m rt（IPv6 路由头） → CONFIG_IP6_NF_MATCH_RT（缺，本脚本补上）
set -uo pipefail
FRAG=/mnt/d/lfOS/config/kernel-lfos-vbox.fragment

echo "════ 1. 备份 ════"
cp -f "$FRAG" "$FRAG.bak-fixxt-$(date +%s)" 2>/dev/null && echo "  已备份"

echo
echo "════ 2. 删除不存在的符号，写入正确的符号 ════"
python3 - "$FRAG" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="replace").read()

# 删掉那两个不存在的符号行
for bad in ("CONFIG_NETFILTER_XT_MATCH_RT=y", "CONFIG_NETFILTER_XT_TARGET_REJECT=y"):
    if bad in s:
        s = s.replace(bad + "\n", "")
        print(f"  删除无效符号: {bad}")

# 更新说明段落
old_note_start = "# --- ufw 所需的 netfilter 扩展"
new_block = """# --- ufw 所需的 netfilter 扩展（实测 ufw 官方规则会用到）---
# ufw 的 before.rules / before6.rules / user.rules 用到：
#   -m limit（速率限制）  → CONFIG_NETFILTER_XT_MATCH_LIMIT
#   -m hl（hop-limit/TTL）→ CONFIG_NETFILTER_XT_MATCH_HL
#   -m rt（IPv6 路由头）  → CONFIG_IP6_NF_MATCH_RT
#   -j REJECT             → CONFIG_IP_NF_TARGET_REJECT / IP6_NF_TARGET_REJECT（已启用）
#
# ⚠ 踩坑记录：这两个符号在 Linux 6.15 里**不存在**，
#   kconfig 对未知符号是静默忽略的（不报错、也不写进 .config）：
#       CONFIG_NETFILTER_XT_TARGET_REJECT   ← 不存在，正确名是 IP_NF_TARGET_REJECT
#       CONFIG_NETFILTER_XT_MATCH_RT        ← 不存在，正确名是 IP6_NF_MATCH_RT
CONFIG_NETFILTER_XT_MATCH_LIMIT=y
CONFIG_NETFILTER_XT_MATCH_HL=y
CONFIG_IP6_NF_MATCH_RT=y
"""
i = s.find(old_note_start)
if i >= 0:
    # 找到该注释段落的结尾（下一个空行+非注释行）
    j = s.find("\n\n", s.find("CONFIG_NETFILTER_XT_MATCH_HL=y", i))
    j = j + 1 if j > 0 else len(s)
    s = s[:i] + new_block + s[j:]
    print("  已重写 ufw 段落")
else:
    s += "\n" + new_block
    print("  已追加 ufw 段落")

open(p, "w", encoding="utf-8").write(s)
PYEOF

echo "  --- 修正后 ---"
grep -nE 'XT_MATCH_(LIMIT|HL)|IP6_NF_MATCH_RT|XT_MATCH_RT|XT_TARGET_REJECT' "$FRAG" | sed 's/^/    /'

echo
echo "════ 3. 重编内核 ════"
cd /opt/lfOS || exit 1
bash /opt/lfOS/scripts/50-build-kernel.sh all 2>&1 | tail -12

echo
echo "════ 4. 最终确认 ════"
K=/opt/lfOS/build/kernel
for c in NETFILTER_XT_MATCH_LIMIT NETFILTER_XT_MATCH_HL IP6_NF_MATCH_RT \
         IP_NF_TARGET_REJECT IP6_NF_TARGET_REJECT; do
  v=$(grep -E "^CONFIG_${c}=" "$K/.config" 2>/dev/null | cut -d= -f2)
  printf '  %-30s %s\n' "$c" "${v:-未设置}"
done
echo "  --- vmlinux 符号 ---"
for sym in ip6t_rt_mt xt_limit; do
  n=$(nm "$K/vmlinux" 2>/dev/null | grep -c "$sym")
  printf '    %-14s %s\n' "$sym" "$([ "$n" -gt 0 ] && echo "有($n)" || echo 无)"
done
ls -lh "$K/bzImage" | awk '{print "  bzImage: "$5}'
echo "DONE-KERNEL-FINAL"
