#!/usr/bin/env bash
# 把 lfOS 的防火墙改成 Ubuntu 那样：用 ufw 管理
#
# 背景：原本用自研的 /etc/nftables.conf（默认拒绝入站），
#       但 Debian/Ubuntu 用户习惯的是 ufw 的那套命令：
#           ufw status / ufw allow 80 / ufw deny 3306 / ufw enable …
#       本脚本装上 ufw 并配好默认策略，让 ufw 接管防火墙。
#
# 可行性（已实测内核配置）：
#   CONFIG_NFT_COMPAT=y          → iptables-nft 兼容层可用
#   CONFIG_IP_NF_IPTABLES/FILTER/NAT=y
#   CONFIG_NETFILTER_XTABLES=y + 各 XT 扩展
#   CONFIG_NF_CONNTRACK=y
#   Debian 仓库有 ufw 0.36.2-9，依赖 iptables/procps/ucf/python3/debconf
#
# 注意：ufw 是 Python 程序，必须装 python3（用 -minimal 减少体积）。
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
S=/opt/lfOS/build/rootfs
LOGS=/opt/lfOS/build/logs

ok(){ printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[警告]\033[0m %s\n' "$*"; }
hr(){ printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }

mount_pseudo(){ mkdir -p "$1/proc" "$1/sys" "$1/dev" "$1/dev/pts" 2>/dev/null
  for m in proc sys dev dev/pts; do mountpoint -q "$1/$m" 2>/dev/null || mount --bind "/$m" "$1/$m" 2>/dev/null; done
  [ -e "$1/etc/mtab" ] || ln -sf /proc/self/mounts "$1/etc/mtab" 2>/dev/null; }
umount_pseudo(){ for m in dev/pts dev proc sys; do mountpoint -q "$1/$m" 2>/dev/null && umount "$1/$m" 2>/dev/null; done; }

mount_pseudo "$S"
trap 'umount_pseudo "$S"' EXIT

hr "1. 换阿里云源（deb.debian.org 实测仅 19kB/s）"
cp -f "$S/etc/apt/sources.list" "$S/etc/apt/sources.list.bak" 2>/dev/null
cat > "$S/etc/apt/sources.list" <<'EOF'
deb https://mirrors.aliyun.com/debian trixie main
deb https://mirrors.aliyun.com/debian trixie-updates main
deb https://mirrors.aliyun.com/debian-security trixie-security main
EOF
ok "已切换到阿里云镜像"
chroot "$S" env DEBIAN_FRONTEND=noninteractive apt-get update > "$LOGS/ufw-apt-update.log" 2>&1
grep -E 'Fetched|Err' "$LOGS/ufw-apt-update.log" | tail -2 | sed 's/^/  /'

hr "2. 安装 python3-minimal + ufw 及其依赖"
PKGS="python3-minimal ufw iptables procps ucf debconf iproute2"
chroot "$S" env DEBIAN_FRONTEND=noninteractive \
  apt-get install -y --no-install-recommends \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
  $PKGS > "$LOGS/ufw-install.log" 2>&1
rc=$?
echo "  退出码: $rc"
grep -E 'Fetched|Need to get' "$LOGS/ufw-install.log" | tail -2 | sed 's/^/  /'
if [ "$rc" -ne 0 ]; then
  warn "安装有错误，末尾："
  grep -E '^(E:|dpkg: error| trying to overwrite)' "$LOGS/ufw-install.log" | head -8 | sed 's/^/      /'
else
  ok "安装成功"
fi

hr "3. 验收关键文件"
for c in usr/sbin/ufw usr/sbin/iptables usr/sbin/iptables-nft usr/bin/python3 \
         etc/ufw/ufw.conf etc/default/ufw usr/lib/python3/dist-packages/ufw; do
  [ -e "$S/$c" ] && printf '  \033[32m[有]\033[0m %s\n' "$c" || printf '  \033[31m[缺]\033[0m %s\n' "$c"
done

hr "4. 配置成 Ubuntu 的默认策略"
# Ubuntu 默认：拒绝入站、允许出站、转发拒绝、v6 开启
mkdir -p "$S/etc/ufw" "$S/etc/default"
cat > "$S/etc/default/ufw" <<'EOF'
# lfOS: ufw 默认策略（对齐 Ubuntu）
IPV6=yes
DEFAULT_INPUT_POLICY="DROP"
DEFAULT_OUTPUT_POLICY="ACCEPT"
DEFAULT_FORWARD_POLICY="DROP"
DEFAULT_APPLICATION_POLICY="SKIP"
MANAGE_BUILTINS=no
IPT_SYSCTL=/etc/ufw/sysctl.conf
IPT_MODULES="nf_conntrack_ftp nf_nat_ftp nf_conntrack_netbios_ns"
EOF
ok "/etc/default/ufw"

cat > "$S/etc/ufw/ufw.conf" <<'EOF'
# lfOS: ufw 基本设置
ENABLED=yes
LOGLEVEL=low
EOF
ok "/etc/ufw/ufw.conf（ENABLED=yes）"

# 预置 SSH 放行规则（Ubuntu 装完也是先 ufw allow ssh）
mkdir -p "$S/etc/ufw/applications.d"
cat > "$S/etc/ufw/user.rules" <<'EOF'
### tuple ### allow tcp 22 0.0.0.0/0 any 0.0.0.0/0 in
-A ufw-user-input -p tcp --dport 22 -j ACCEPT
### END RULES ###
EOF
ok "已预置 SSH(22) 放行"

hr "5. 让 init 用 ufw 接管（替代 nft -f）"
INIT=$S/sbin/init
cp -f "$INIT" "$INIT.bak-ufw-$(date +%s)" 2>/dev/null
python3 - "$INIT" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="replace").read()

# 把原先的 nft -f 块替换为 ufw 优先、nft 兜底
old_start = 'step "5/9 加载防火墙规则"'
i = s.find(old_start)
if i < 0:
    print("  未找到防火墙步骤")
    sys.exit(0)
# 找到该 if 块结束（下一处 "\nfi\n" 之后）
j = s.find("\nfi\n", i)
if j < 0:
    print("  未找到块结尾")
    sys.exit(0)
j += len("\nfi\n")

new = '''step "5/9 加载防火墙规则"
# -----------------------------------------------------------------------------
#  防火墙：优先用 ufw（对齐 Ubuntu 的用法），没有 ufw 才退回自研 nftables.conf。
#
#  为什么以 ufw 为主：Debian/Ubuntu 用户习惯的是
#      ufw status / ufw allow 80 / ufw deny 3306 / ufw enable
#  这一套；ufw 底层经 iptables-nft 兼容层落到内核 nftables，
#  与 lfOS 内核的 CONFIG_NFT_COMPAT 正好匹配。
#
#  注意：不要同时用 ufw 和 nft -f /etc/nftables.conf —— 两者都操作 netfilter，
#  会导致规则互相覆盖。这里做了互斥：有 ufw 就不再加载 nftables.conf。
# -----------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  # ufw 在首次 enable 时会自行建立规则集；--force 跳过交互确认
  if ufw --force enable >/tmp/ufw-enable.log 2>&1; then
    say "[lfOS] 已启用 ufw 防火墙（默认拒绝入站，放行 22）"
    rm -f /tmp/ufw-enable.log 2>/dev/null
  else
    say "[lfOS] ufw 启用失败，错误如下："
    head -4 /tmp/ufw-enable.log 2>/dev/null | while IFS= read -r _l; do say "    $_l"; done
  fi
elif [ -f /etc/nftables.conf ] && command -v nft >/dev/null 2>&1; then
  NFT_ERR=/run/nft-load.err
  if nft -f /etc/nftables.conf 2>"$NFT_ERR"; then
    say "[lfOS] 已加载 nftables 规则（默认拒绝入站，放行 22）"
    rm -f "$NFT_ERR" 2>/dev/null
  else
    say "[lfOS] nftables 规则加载失败，错误如下："
    head -4 "$NFT_ERR" 2>/dev/null | while IFS= read -r _l; do say "    $_l"; done
  fi
else
  say "[lfOS] 未找到 ufw 与 nft，跳过防火墙"
fi
'''
s = s[:i] + new + s[j:]
open(p, "w", encoding="utf-8").write(s)
print("  已替换防火墙步骤（ufw 优先，nft 兜底，二者互斥）")
PYEOF

echo
echo "  --- 语法检查 ---"
if bash -n "$INIT" 2>&1 | head -5 | sed 's/^/    /'; then ok "init 语法通过"; else
  warn "语法错误，回滚"; cp -f "$(ls -t "$INIT".bak-ufw-* | head -1)" "$INIT"; bash -n "$INIT" && ok "已回滚"
fi

hr "6. 保留 nftables.conf 但不再自动加载"
if [ -f "$S/etc/nftables.conf" ]; then
  # 顶部加说明，避免后人误以为它还在生效
  if ! head -3 "$S/etc/nftables.conf" | grep -q 'ufw 已接管'; then
    python3 - "$S/etc/nftables.conf" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="replace").read()
note = """# ⚠ lfOS：ufw 已接管防火墙，本文件默认不再被 init 自动加载。
#   想改规则请用： ufw allow 80/tcp   /   ufw status numbered
#   只有在系统里没有 ufw 时，init 才会退回加载本文件。
"""
open(p, "w", encoding="utf-8").write(note + s)
print("  已加说明")
PYEOF
  fi
  ok "nftables.conf 保留为后备"
fi

hr "7. 汇总"
printf '  ufw:      %s\n' "$([ -x "$S/usr/sbin/ufw" ] && echo 就位 || echo 缺)"
printf '  iptables: %s\n' "$([ -x "$S/usr/sbin/iptables" ] && echo 就位 || echo 缺)"
printf '  python3:  %s\n' "$([ -x "$S/usr/bin/python3" ] && echo 就位 || echo 缺)"
printf '  默认策略: %s\n' "$(grep -E '^DEFAULT_INPUT_POLICY' "$S/etc/default/ufw" 2>/dev/null)"
printf '  开机启用: %s\n' "$(grep -E '^ENABLED' "$S/etc/ufw/ufw.conf" 2>/dev/null)"
printf '  rootfs:   %s\n' "$(du -sh "$S" 2>/dev/null | cut -f1)"
echo "DONE-INSTALL-UFW"
