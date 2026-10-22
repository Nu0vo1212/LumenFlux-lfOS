#!/usr/bin/env bash
# 修复关键程序的特殊权限位（setuid/setgid）
#
# 为什么单独一个脚本：打包流程中任何全树 chmod/chown 操作都可能
# 抹掉 setuid/setgid 位，而这些位一旦丢失，系统会出现
# 「普通用户改不了密码、su 不可用、mount 失败」等严重故障，
# 且很难从症状反查到权限上。
#
# 本脚本应在打包前最后执行，并纳入门禁检查。
set -uo pipefail
S="${LFS:-/opt/lfOS/build/rootfs}"

PROGS=(
    "usr/bin/passwd:root:root:4755"
    "usr/bin/chage:root:root:4755"
    "usr/bin/chfn:root:root:4755"
    "usr/bin/chsh:root:root:4755"
    "usr/bin/expiry:root:root:4755"
    "usr/bin/gpasswd:root:root:4755"
    "usr/bin/mount:root:root:4755"
    "usr/bin/umount:root:root:4755"
    "usr/bin/su:root:root:4755"
    "usr/bin/newgrp:root:root:4755"
    "usr/bin/newuidmap:root:root:4755"
    "usr/bin/newgidmap:root:root:4755"
    "usr/bin/sudo:root:root:4755"
    "usr/bin/wall:root:tty:2755"
    "usr/bin/write:root:tty:2755"
    "usr/bin/ssh-agent:root:ssh:2755"
    "usr/lib/openssh/ssh-keysign:root:root:4755"
)

n=0
for entry in "${PROGS[@]}"; do
    IFS=: read -r path u g m <<< "$entry"
    full="$S/$path"
    [ -e "$full" ] || continue
    grep -q "^${g}:" "$S/etc/group" 2>/dev/null || g="root"
    chown "$u:$g" "$full" 2>/dev/null
    chmod "$m" "$full" 2>/dev/null
    n=$((n + 1))
done
echo "  已修复 $n 个程序的特殊权限位"

# 校验
bad=0
for entry in "${PROGS[@]}"; do
    IFS=: read -r path u g m <<< "$entry"
    full="$S/$path"
    [ -e "$full" ] || continue
    cur=$(stat -c '%a' "$full" 2>/dev/null)
    [ "$cur" = "$m" ] || { echo "  ✘ $path 期望 $m 实际 $cur"; bad=$((bad + 1)); }
done
[ "$bad" -eq 0 ] && echo "  ✔ 全部正确" || { echo "  ✘ $bad 个仍有问题"; exit 1; }
