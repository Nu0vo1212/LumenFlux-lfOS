#!/usr/bin/env bash
# ============================================================================
#  lfOS - 打包前收尾（属主归位 + /dev/fd 固化 + 门禁）
#
#  ══ 为什么需要这个脚本 ══
#
#  ① 文件属主
#     lfOS 用普通用户（lfos，uid 1000）交叉编译并 DESTDIR 安装，构建树里
#     大量文件属主是 uid 1000。两条打包路径行为不同：
#       squashfs（ISO）    : mksquashfs -all-root  → 强制 root:root  ✓
#       ext4（磁盘镜像）    : mkfs.ext4 后手动填充 → **原样保留 uid 1000** ✗
#     虚拟机用的正是 ext4 路径，于是出现：
#       /etc/shadow、/etc/passwd 属主 uid 1000
#       11 个 setuid root 程序（passwd/chage/mount/umount…）属主 uid 1000
#     —— setuid root 程序被普通用户拥有 = 提权后门。
#     本脚本在打包前统一归位，并加门禁防止再次漏出。
#
#  ② /dev/fd
#     Linux 标准里 /dev/fd -> /proc/self/fd。缺失时 bash 的进程替换
#     < <(...) 会报 "/dev/fd/63: No such file or directory"，
#     **所有依赖进程替换的脚本都会失败**（宝塔安装脚本第一句报错就是它）。
#     /dev 是 devtmpfs，重启即丢，所以必须写进 init 里每次开机创建。
#
#  ③ sshd 端口转发
#     AllowTcpForwarding no 会让所有 SSH 隧道/跳板失效（远程访问 VM 内服务
#     时这是最可靠的手段，尤其当 VBox NAT 转发对某些端口不工作时）。
#     改为 local：只允许本地转发，不允许远程转发，安全性与可用性兼顾。
#
#  用法： bash 58-finalize.sh [all|owner|devfd|sshd|gate]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
CFG="$LFOS/config"
LOGS="$LFOS/build/logs"

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[警告]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

[ -d "$LFS" ] || die "rootfs 不存在: $LFS"

# ---------------------------------------------------------------------------
#  1. 属主归位
# ---------------------------------------------------------------------------
do_owner() {
  printf '\n\033[1;36m===== 属主归位（uid/gid 1000 -> root）=====\n\033[0m'

  local before
  before=$(find "$LFS" -xdev \( -uid 1000 -o -gid 1000 \) 2>/dev/null | wc -l)
  printf '  归位前 uid/gid=1000 的文件: %s\n' "$before"

  # 1.1 安全敏感文件单独处理（不能一刀切 root:root）
  #     /etc/shadow 必须是 root:shadow 0640，否则普通用户读不到是小事，
  #     更糟的是若属主错成普通用户，等于密码哈希可被改写。
  # lfOS 的 /etc/group 里没有 shadow 组，gid 42 被 _apt 占了，
  # 导致 /etc/shadow 的属组是 _apt。Debian 标准是 shadow:x:42:。
  # 这里把 _apt 挪到空闲 gid，并补上 shadow 组。
  if ! grep -q '^shadow:' "$LFS/etc/group" 2>/dev/null; then
    if [ "$(awk -F: '$3==42{print $1}' "$LFS/etc/group" 2>/dev/null)" = "_apt" ]; then
      local ng=999
      while awk -F: -v g="$ng" '$3==g{f=1} END{exit !f}' "$LFS/etc/group" 2>/dev/null; do ng=$((ng-1)); done
      sed -i "s|^_apt:x:42:|_apt:x:${ng}:|" "$LFS/etc/group" 2>/dev/null
      [ -f "$LFS/etc/gshadow" ] && sed -i "s|^_apt:!:42:|_apt:!:${ng}:|" "$LFS/etc/gshadow" 2>/dev/null
      sed -i "s|^\\(_apt:[^:]*:[0-9]*:\\)42:|\\1${ng}:|" "$LFS/etc/passwd" 2>/dev/null
    fi
    echo "shadow:x:42:" >> "$LFS/etc/group"
    [ -f "$LFS/etc/gshadow" ] && echo "shadow:!::" >> "$LFS/etc/gshadow"
  fi
  chown root:shadow "$LFS/etc/shadow"  2>/dev/null && chmod 0640 "$LFS/etc/shadow"  2>/dev/null
  chown root:shadow "$LFS/etc/gshadow" 2>/dev/null && chmod 0640 "$LFS/etc/gshadow" 2>/dev/null
  chown root:shadow "$LFS/etc/shadow-"  2>/dev/null; chmod 0640 "$LFS/etc/shadow-"  2>/dev/null
  chown root:shadow "$LFS/etc/gshadow-" 2>/dev/null; chmod 0640 "$LFS/etc/gshadow-" 2>/dev/null
  chown root:root "$LFS/etc/passwd" "$LFS/etc/group" 2>/dev/null
  chmod 0644 "$LFS/etc/passwd" "$LFS/etc/group" 2>/dev/null
  chown root:root "$LFS/etc/passwd-" "$LFS/etc/group-" 2>/dev/null
  chmod 0644 "$LFS/etc/passwd-" "$LFS/etc/group-" 2>/dev/null
  ok "/etc/{shadow,gshadow,passwd,group} 属主与权限已修正"

  # 1.2 关键目录
  local d
  for d in etc var var/lib var/lib/dpkg var/log var/spool var/cache var/tmp \
           root boot srv opt usr/lib/lfos usr/share/lfos run home; do
    [ -e "$LFS/$d" ] && chown root:root "$LFS/$d" 2>/dev/null
  done
  chmod 0700 "$LFS/root" 2>/dev/null
  chmod 1777 "$LFS/tmp" "$LFS/var/tmp" 2>/dev/null
  ok "关键目录属主已归位（/root 0700，/tmp 与 /var/tmp 1777）"

  # 1.3 全量归位
  #     注意：不用管道 + while（子 shell 计数不准），直接 find -exec。
  #     gid=1000 也要处理：uid 可能本来就是对的（如某个系统用户恰好 uid 1000
  #     以外的号码），只把 gid 归 0。
  find "$LFS" -xdev -uid 1000 -exec chown root {} + 2>/dev/null
  find "$LFS" -xdev -gid 1000 -exec chgrp root {} + 2>/dev/null

  # 1.4 /home 下真实用户的家目录要保留其属主（如果有）
  local h u uid gid
  for h in "$LFS"/home/*; do
    [ -d "$h" ] || continue
    u=$(basename "$h")
    [ "$u" = "lost+found" ] && continue
    # 从 rootfs 的 /etc/passwd 读 uid/gid
    local line
    line=$(awk -F: -v n="$u" '$1==n{print $3":"$4}' "$LFS/etc/passwd" 2>/dev/null)
    if [ -n "$line" ]; then
      uid="${line%%:*}"; gid="${line##*:}"
      chown -R "$uid:$gid" "$h" 2>/dev/null
      printf '  保留家目录属主: %s -> %s:%s\n' "$h" "$uid" "$gid"
    fi
  done

  # 1.5 setuid/setgid 程序必须是 root
  local f fixed=0
  while IFS= read -r f; do
    [ "$(stat -c %U "$f" 2>/dev/null)" = "root" ] && continue
    chown root:root "$f" 2>/dev/null && fixed=$((fixed+1))
  done < <(find "$LFS" -xdev -perm -4000 -type f 2>/dev/null)
  [ "$fixed" -gt 0 ] && printf '  修正了 %s 个 setuid 程序的属主\n' "$fixed"

  local after
  after=$(find "$LFS" -xdev \( -uid 1000 -o -gid 1000 \) 2>/dev/null | wc -l)
  printf '  归位后 uid/gid=1000 的文件: %s\n' "$after"
  if [ "$after" -gt 0 ]; then
    warn "仍有残留（多为符号链接，属主在 Linux 上不生效）："
    find "$LFS" -xdev \( -uid 1000 -o -gid 1000 \) 2>/dev/null | head -8 | sed 's/^/      /'
  else
    ok "属主全部归位"
  fi
}

# ---------------------------------------------------------------------------
#  2. /dev/fd 固化（进 init，因为 /dev 是 devtmpfs）
# ---------------------------------------------------------------------------
do_devfd() {
  printf '\n\033[1;36m===== 固化 /dev/fd 等标准符号链接 =====\n\033[0m'

  local init="$LFS/sbin/init"
  local marker='dev/fd'

  if [ -f "$init" ] && grep -q "$marker" "$init" 2>/dev/null; then
    ok "/sbin/init 已包含 /dev/fd 创建逻辑"
  elif [ -f "$init" ]; then
    # 找一个可靠的插入锚点：挂载完伪文件系统之后（/proc 必须已挂上，
    # 因为 /dev/fd -> /proc/self/fd 需要 /proc 存在）
    local anchor=""
    if grep -q '设置主机名' "$init" 2>/dev/null; then
      anchor='设置主机名'
    elif grep -q '挂载伪文件系统' "$init" 2>/dev/null; then
      anchor='挂载伪文件系统'
    fi

    if [ -n "$anchor" ]; then
      # 在包含锚点的那一行之前插入
      python3 - "$init" "$anchor" <<'PYEOF'
import sys, re
path, anchor = sys.argv[1], sys.argv[2]
snippet = '''# 补 /dev/fd 等标准符号链接。
# Linux 标准里 /dev/fd -> /proc/self/fd，缺失时 bash 进程替换 < <(...) 报
#   /dev/fd/63: No such file or directory
# 导致所有依赖进程替换的脚本失败。/dev 是 devtmpfs，重启即丢，故每次开机重建。
for _lfos_dl in fd:/proc/self/fd stdin:/proc/self/fd/0 stdout:/proc/self/fd/1 stderr:/proc/self/fd/2; do
    _lfos_l="/dev/${_lfos_dl%%:*}"; _lfos_t="${_lfos_dl##*:}"
    [ -e "$_lfos_l" ] || [ -L "$_lfos_l" ] || ln -sfn "$_lfos_t" "$_lfos_l" 2>/dev/null
done
unset _lfos_dl _lfos_l _lfos_t
'''
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    lines = fh.readlines()
out, done = [], False
for ln in lines:
    if not done and anchor in ln and ("step" in ln or "echo" in ln or "#" in ln or ln.strip()):
        out.append(snippet)
        done = True
    out.append(ln)
if not done:                      # 锚点没匹配上就插到 shebang 之后
    out = lines[:1] + [snippet] + lines[1:]
with open(path, "w", encoding="utf-8") as fh:
    fh.writelines(out)
print("  inserted" if done else "  inserted-after-shebang")
PYEOF
      ok "已把 /dev/fd 创建逻辑写进 /sbin/init"
    else
      warn "/sbin/init 里找不到插入锚点，改为只挂 rc.local"
    fi
  else
    warn "/sbin/init 不存在"
  fi

  # 兜底：rc.local 也放一份（幂等）
  local rc="$LFS/etc/rc.local"
  if [ -f "$rc" ]; then
    if ! grep -q "$marker" "$rc" 2>/dev/null; then
      sed -i "/^exit 0/i # 补 /dev/fd（devtmpfs 每次开机重建）\nfor _p in fd:/proc/self/fd stdin:/proc/self/fd/0 stdout:/proc/self/fd/1 stderr:/proc/self/fd/2; do\n    _l=\"/dev/\${_p%%:*}\"; _t=\"\${_p##*:}\"\n    [ -e \"\$_l\" ] || [ -L \"\$_l\" ] || ln -sfn \"\$_t\" \"\$_l\" 2>/dev/null\ndone" "$rc" 2>/dev/null \
        && ok "已写入 /etc/rc.local"
    else
      ok "/etc/rc.local 已包含"
    fi
  fi

  # 当前 rootfs 里也直接建一份（这次打包立刻生效）
  mkdir -p "$LFS/dev" 2>/dev/null
  ln -sfn /proc/self/fd   "$LFS/dev/fd"     2>/dev/null
  ln -sfn /proc/self/fd/0 "$LFS/dev/stdin"  2>/dev/null
  ln -sfn /proc/self/fd/1 "$LFS/dev/stdout" 2>/dev/null
  ln -sfn /proc/self/fd/2 "$LFS/dev/stderr" 2>/dev/null
  ok "当前 rootfs 的 /dev/fd 已就位"
}

# ---------------------------------------------------------------------------
#  3. sshd 允许本地端口转发
# ---------------------------------------------------------------------------
do_sshd() {
  printf '\n\033[1;36m===== sshd 端口转发策略 =====\n\033[0m'

  local src="$CFG/sshd_config-lfos"
  local dst="$LFS/etc/ssh/sshd_config"

  for f in "$src" "$dst"; do
    [ -f "$f" ] || continue
    if grep -q '^AllowTcpForwarding' "$f" 2>/dev/null; then
      local cur
      cur=$(grep '^AllowTcpForwarding' "$f" | awk '{print $2}')
      if [ "$cur" = "local" ]; then
        ok "$(basename "$f") 已是 AllowTcpForwarding local"
      else
        sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding local/' "$f"
        # 补一行说明，免得后人又改回去
        grep -q 'lfOS: 允许本地端口转发' "$f" || \
          sed -i 's|^AllowTcpForwarding local|# lfOS: 允许本地端口转发（SSH 隧道），禁止远程转发。\n# 远程访问 VM 内服务时隧道比 VBox NAT 转发可靠（实测某些端口 NAT 转发不通）。\nAllowTcpForwarding local|' "$f"
        ok "$(basename "$f"): $cur -> local"
      fi
    else
      printf '\n# lfOS: 允许本地端口转发（SSH 隧道），禁止远程转发\nAllowTcpForwarding local\n' >> "$f"
      ok "$(basename "$f"): 新增 AllowTcpForwarding local"
    fi
  done
}

# ---------------------------------------------------------------------------
#  4. 门禁
# ---------------------------------------------------------------------------
do_gate() {
  printf '\n\033[1;36m===== 收尾门禁 =====\n\033[0m'
  local pass=0 fail=0
  ck() {
    local rc; set +o pipefail; eval "$2" >/dev/null 2>&1; rc=$?; set -o pipefail
    if [ "$rc" -eq 0 ]; then printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); fi
  }

  # 排除 /home：家目录属主本来就该是用户自己，不算问题
  ck "无 uid=1000 的普通文件"   "[ \$(find '$LFS' -xdev -uid 1000 -type f -not -path '$LFS/home/*' 2>/dev/null | wc -l) -eq 0 ]"
  ck "/etc/shadow 属主 root"    "[ \"\$(stat -c%U '$LFS/etc/shadow' 2>/dev/null)\" = root ]"
  ck "/etc/shadow 权限 640"     "[ \"\$(stat -c%a '$LFS/etc/shadow' 2>/dev/null)\" = 640 ]"
  ck "/etc/passwd 属主 root"    "[ \"\$(stat -c%U '$LFS/etc/passwd' 2>/dev/null)\" = root ]"
  ck "/root 权限 700"           "[ \"\$(stat -c%a '$LFS/root' 2>/dev/null)\" = 700 ]"
  ck "setuid 程序全为 root"     "[ \$(find '$LFS' -xdev -perm -4000 -type f ! -user root 2>/dev/null | wc -l) -eq 0 ]"
  ck "/dev/fd 链接已建立"       "[ -L '$LFS/dev/fd' ] || [ -e '$LFS/dev/fd' ]"
  ck "init 里含 /dev/fd 逻辑"   "grep -q 'dev/fd' '$LFS/sbin/init'"
  # 用 [[:space:]] 兼容行尾空白/CR；原来的精确匹配在模板被 sed 插入过之后会假报错
  ck "sshd 允许本地转发"        "grep -qE '^AllowTcpForwarding[[:space:]]+local' '$LFS/etc/ssh/sshd_config'"

  printf '\n  门禁: %d 通过 / %d 失败\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ 收尾完成，可以打包\033[0m\n' \
                    || printf '  \033[1;31m✗ 仍有 %d 项未过\033[0m\n' "$fail"
  return "$fail"
}

case "${1:-all}" in
  owner)  do_owner ;;
  devfd)  do_devfd ;;
  sshd)   do_sshd ;;
  gate)   do_gate ;;
  all)    do_owner; do_devfd; do_sshd; do_gate ;;
  *) echo "用法: $0 {all|owner|devfd|sshd|gate}"; exit 1 ;;
esac
