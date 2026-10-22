#!/usr/bin/env bash
# v1.0.0 安全加固：去掉测试凭据，改成首次启动设置密码
#
# 现状（v0.0.x 的测试配置）：
#   - /etc/shadow 里 root 密码是 "lfos"
#   - sshd_config: PermitRootLogin yes, PasswordAuthentication yes
#   这两条放在公网就是分分钟被扫爆的配置。
#
# 目标（v1.0.0）：
#   1) root 账号锁定（密码字段置为 *），无法用任何密码登录
#   2) 首次启动时，init 检测到 root 未设密码 → 在控制台强制设置
#   3) 设置完成后才允许 SSH 密码登录
#   4) 同时保留「公钥登录」路径，方便无人值守部署
#
# 设计原则：
#   - 不能因为「强制设密码」让人进不去系统（控制台始终可用）
#   - 不能把密码写进镜像（那等于没设）
#   - 设置的密码强度要做基本校验
set -uo pipefail
S=/opt/lfOS/build/rootfs

ok(){ printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
hr(){ printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }

hr "1. 锁定 root 密码（镜像里不再有可用密码）"
if [ -f "$S/etc/shadow" ]; then
  cp -f "$S/etc/shadow" "$S/etc/shadow.bak-$(date +%s)" 2>/dev/null
  # 把 root 的密码字段替换成 *（表示已锁定，任何密码都无法匹配）
  python3 - "$S/etc/shadow" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
out, changed = [], False
for ln in lines:
    f = ln.split(":")
    if f and f[0] == "root" and len(f) >= 2:
        if f[1] != "*":
            f[1] = "*"
            ln = ":".join(f)
            changed = True
    out.append(ln)
open(p, "w", encoding="utf-8").write("\n".join(out) + "\n")
print(f"  root 密码字段已置为 * （原值{'已被替换' if changed else '本来就是 *'}）")
PYEOF
  echo "  --- 确认 ---"
  grep '^root:' "$S/etc/shadow" | awk -F: '{printf "  root: 密码字段=[%s] 最后修改=%s\n", $2, $3}'
  ok "root 已锁定，镜像里没有任何可用密码"
fi

hr "2. SSH 默认配置：只允许公钥登录"
SC=$S/etc/ssh/sshd_config
if [ -f "$SC" ]; then
  cp -f "$SC" "$SC.bak-v1-$(date +%s)" 2>/dev/null
  python3 - "$SC" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()

# 需要强制设定的值
settings = {
    "PermitRootLogin": "prohibit-password",   # 允许 root 用公钥，禁用密码
    "PasswordAuthentication": "no",           # 镜像默认禁密码
    "PubkeyAuthentication": "yes",
    "PermitEmptyPasswords": "no",
    "MaxAuthTries": "3",
    "LoginGraceTime": "30",
    "ClientAliveInterval": "300",
    "ClientAliveCountMax": "3",
}

for key, val in settings.items():
    # 先删掉所有已有的该键（含注释掉的）
    s = re.sub(rf'^\s*#?\s*{key}\s+.*$', '', s, flags=re.M)
    # 追加到文件末尾的设置区
    s = s.rstrip() + f"\n{key} {val}\n"

# 补一段说明
note = """
# ─────────────────────────────────────────────────────────────────────────────
#  lfOS v1.0.0 安全默认值
#
#  镜像里 root 密码是锁定的（/etc/shadow 中为 *），因此不可能用密码登录。
#  首次启动时，init 会在控制台要求设置 root 密码；设置完成后，
#  它会自动把 PasswordAuthentication 改成 yes 并重启 sshd。
#
#  如果你想用公钥登录（推荐，也适合无人值守部署）：
#      mkdir -p /root/.ssh && chmod 700 /root/.ssh
#      # 把你的公钥写进 /root/.ssh/authorized_keys，权限 600
#      # 然后无需设置密码即可 SSH 登录
#
#  想把密码登录彻底关掉（设完密码后）：
#      sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
#      /etc/init.d/sshd restart   # 或 pkill sshd && /usr/sbin/sshd
# ─────────────────────────────────────────────────────────────────────────────
"""
if "lfOS v1.0.0 安全默认值" not in s:
    s = s.rstrip() + "\n" + note

open(p, "w", encoding="utf-8").write(s)
print("  已写入安全默认值")
PYEOF
  echo "  --- 关键配置 ---"
  grep -E '^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|PermitEmptyPasswords|MaxAuthTries)' "$SC" | sed 's/^/    /'
  ok "sshd_config 已加固"
fi

hr "3. 写首次启动设置密码的脚本"
cat > "$S/usr/local/sbin/lfos-firstboot" <<'FIRSTBOOT'
#!/bin/bash
# =============================================================================
#  lfOS 首次启动设置
#
#  职责：在控制台上交互式设置 root 密码。只用一次，成功后写标记文件。
#
#  为什么必须在控制台做：镜像里 root 密码是锁定的（/etc/shadow 为 *），
#  SSH 也无法用密码登录，所以第一次进系统只能走控制台 —— 这恰恰是安全的
#  默认行为（物理/虚拟控制台访问本来就等价于最高权限）。
#
#  如果希望完全无人值守（用公钥部署），可以跳过本脚本：
#      touch /etc/lfos/firstboot-done
#  然后在 authorized_keys 里放好公钥即可。
# =============================================================================
set -u

MARK=/etc/lfos/firstboot-done
mkdir -p /etc/lfos 2>/dev/null

[ -f "$MARK" ] && exit 0

# 只在控制台执行（不是通过 SSH 或管道）
if [ ! -c /dev/console ]; then
    exit 0
fi

say() { printf '%s\n' "$*" > /dev/console 2>/dev/null; }
ask() { printf '%s' "$1" > /dev/console 2>/dev/null; }

say ""
say "╔════════════════════════════════════════════════════════════════╗"
say "║                    lfOS 首次启动设置                           ║"
say "╚════════════════════════════════════════════════════════════════╝"
say ""
say "  镜像中的 root 密码是锁定的，需要现在设置一个。"
say "  要求：至少 8 位，不能是纯数字，不能与用户名相同。"
say ""

# 最多尝试 3 次；3 次都失败就跳过，允许之后手动设置
for attempt in 1 2 3; do
    ask "  新 root 密码: "
    read -r pw1 < /dev/console
    say ""

    # 基本校验
    if [ "${#pw1}" -lt 8 ]; then
        say "  ✘ 太短了（至少 8 位），请重试。"
        continue
    fi
    case "$pw1" in
        *[!0-9]*) ;;                    # 含非数字 → 通过
        *) say "  ✘ 不能是纯数字，请重试。"; continue ;;
    esac
    if [ "$pw1" = "root" ] || [ "$pw1" = "lfos" ]; then
        say "  ✘ 不能用用户名或旧默认值，请重试。"
        continue
    fi

    ask "  再输一次确认: "
    read -r pw2 < /dev/console
    say ""

    if [ "$pw1" != "$pw2" ]; then
        say "  ✘ 两次输入不一致，请重试。"
        continue
    fi

    # 设置密码
    if printf '%s\n%s\n' "$pw1" "$pw2" | passwd root >/dev/null 2>&1; then
        say "  ✔ root 密码已设置"

        # 密码设好后，允许 SSH 密码登录（否则远程还是进不来）
        if [ -f /etc/ssh/sshd_config ]; then
            sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
            # 让 root 也能用密码登录（既然用户主动设了密码）
            sed -i 's/^PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
            pkill -HUP sshd 2>/dev/null || {
                pkill sshd 2>/dev/null; sleep 1; /usr/sbin/sshd 2>/dev/null
            }
            say "  ✔ 已允许 SSH 密码登录并重启 sshd"
        fi

        # 写标记
        {
            echo "设置时间: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "说明: root 密码已由首次启动流程设置"
        } > "$MARK"
        chmod 600 "$MARK" 2>/dev/null

        say ""
        say "  ⚠ 安全提示："
        say "    生产环境中建议改用公钥登录，并关闭密码登录："
        say "      sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' \\"
        say "             /etc/ssh/sshd_config && pkill -HUP sshd"
        say ""
        exit 0
    else
        say "  ✘ 设置失败（passwd 报错），请重试。"
    fi
done

say ""
say "  ⚠ 三次都未设置成功。你可以稍后手动执行：  passwd root"
say "    在设置密码前，SSH 密码登录保持禁用状态。"
say ""
exit 1
FIRSTBOOT
chmod 0755 "$S/usr/local/sbin/lfos-firstboot"
ok "/usr/local/sbin/lfos-firstboot"

hr "4. 在 init 的 9 步之间接入"
INIT=$S/sbin/init
cp -f "$INIT" "$INIT.bak-firstboot-$(date +%s)" 2>/dev/null
python3 - "$INIT" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="replace").read()

if "lfos-firstboot" in s:
    print("  已接入，跳过")
    sys.exit(0)

# 插在 "8/9 系统自检" 之后、"9/9 启动交互 shell" 之前
marker = re.search(r'^step "9/9[^\n]*\n', s, re.M)
if not marker:
    print("  ⚠ 找不到 9/9 步骤")
    sys.exit(0)

block = """# -----------------------------------------------------------------------------
#  首次启动：设置 root 密码
#
#  镜像里 root 密码是锁定的（/etc/shadow 中密码字段为 *），
#  所以第一次进系统必须走控制台设置密码 —— 这是有意的安全默认值。
#  脚本内部会检测标记文件，只在首次运行；设完密码后自动放开 SSH 密码登录。
# -----------------------------------------------------------------------------
if [ -x /usr/local/sbin/lfos-firstboot ] && [ ! -f /etc/lfos/firstboot-done ]; then
    /usr/local/sbin/lfos-firstboot
    # 重新应用一遍 sysctl 场景配置（脚本可能重启过相关服务）
    :
fi

"""
s = s[:marker.start()] + block + s[marker.start():]
open(p, "w", encoding="utf-8", errors="replace").write(s)
print("  已接入 init（8/9 之后、9/9 之前）")
PYEOF
bash -n "$INIT" && ok "init 语法通过"

hr "5. 确保 /etc/lfos 目录存在且权限正确"
mkdir -p "$S/etc/lfos"
chmod 0755 "$S/etc/lfos"
ok "/etc/lfos"

hr "6. 顺带检查：还有没有其它测试凭据残留"
echo "  --- 检查 shadow 里是否有弱密码账号 ---"
python3 - "$S/etc/shadow" <<'PYEOF'
import subprocess, sys
p = sys.argv[1]
weak = []
for ln in open(p, encoding="utf-8", errors="replace"):
    f = ln.split(":")
    if len(f) < 2:
        continue
    user, pw = f[0], f[1]
    if not pw or pw in ("", "*", "!", "!!", "x"):
        continue
    weak.append(user)
print(f"  有密码的账号: {weak if weak else '（无，全部锁定）'}")
PYEOF
echo "  --- 检查是否有其他空密码账号 ---"
awk -F: '$2=="" {print "  空密码: "$1}' "$S/etc/shadow" 2>/dev/null || echo "  无空密码账号"

hr "7. 汇总"
printf '  root 密码字段: %s\n' "$(grep '^root:' "$S/etc/shadow" | cut -d: -f2)"
printf '  PermitRootLogin: %s\n' "$(grep -E '^PermitRootLogin' "$SC" | head -1)"
printf '  PasswordAuthentication: %s\n' "$(grep -E '^PasswordAuthentication' "$SC" | head -1)"
printf '  firstboot 脚本: %s\n' "$([ -x "$S/usr/local/sbin/lfos-firstboot" ] && echo 就位 || echo 缺)"
printf '  init 接入: %s 处\n' "$(grep -c 'lfos-firstboot' "$INIT")"
echo "DONE"
