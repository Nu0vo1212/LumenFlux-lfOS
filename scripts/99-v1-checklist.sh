#!/usr/bin/env bash
# v1.0.0 发布前完整检查（构建产物侧）
set -uo pipefail
S=/opt/lfOS/build/rootfs
K=/opt/lfOS/build/kernel

PASS=0; FAIL=0; WARN=0
ok(){   printf '  \033[32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad(){  printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn(){ printf '  \033[33m[WARN]\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
hr(){   printf '\n\033[1;36m═══ %s ═══\033[0m\n' "$*"; }
ck(){   local d="$1" c="$2"; if eval "$c" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

hr "A. 安全基线"

# root 密码必须锁定
pw=$(awk -F: '$1=="root"{print $2}' "$S/etc/shadow" 2>/dev/null)
if [ "$pw" = "*" ] || [ "$pw" = "!" ] || [ -z "$pw" ]; then
  ok "root 密码已锁定（字段=$pw）"
else
  bad "root 密码未锁定（字段=$pw）"
fi

# 不能有空的密码字段
n=$(awk -F: 'length($2)==0' "$S/etc/shadow" 2>/dev/null | wc -l)
[ "$n" -eq 0 ] && ok "无空密码账号" || bad "存在 $n 个空密码账号"

# SSH 配置
ck "PasswordAuthentication 默认 no" "grep -q '^PasswordAuthentication no' $S/etc/ssh/sshd_config"
ck "PermitRootLogin 为 prohibit-password" "grep -q '^PermitRootLogin prohibit-password' $S/etc/ssh/sshd_config"
ck "PermitEmptyPasswords no" "grep -q '^PermitEmptyPasswords no' $S/etc/ssh/sshd_config"
ck "PubkeyAuthentication yes" "grep -q '^PubkeyAuthentication yes' $S/etc/ssh/sshd_config"
ck "MaxAuthTries 有限制" "grep -qE '^MaxAuthTries [0-9]' $S/etc/ssh/sshd_config"

# 首次启动流程
ck "lfos-firstboot 可执行" "[ -x $S/usr/local/sbin/lfos-firstboot ]"
ck "init 已接入 firstboot" "grep -q 'lfos-firstboot' $S/sbin/init"
ck "/etc/lfos 目录存在" "[ -d $S/etc/lfos ]"

# 属主检查：不能有 uid 1000 泄漏
n=$(find "$S" -uid 1000 2>/dev/null | wc -l)
[ "$n" -eq 0 ] && ok "无 uid 1000 泄漏的文件" || bad "有 $n 个文件属主是 uid 1000"

# setuid 文件必须是 root
n=$(find "$S" -perm -4000 ! -user root 2>/dev/null | wc -l)
[ "$n" -eq 0 ] && ok "所有 setuid 程序属主均为 root" || bad "$n 个 setuid 程序属主异常"

hr "B. 内核"

ck "内核支持 NFT_COMPAT（iptables-nft）" "grep -q '^CONFIG_NFT_COMPAT=y' $K/.config"
ck "内核支持 NF_TABLES" "grep -q '^CONFIG_NF_TABLES=y' $K/.config"
ck "内核支持 ufw 需要的 limit 扩展" "grep -q '^CONFIG_NETFILTER_XT_MATCH_LIMIT=y' $K/.config"
ck "内核支持 IP6_NF_MATCH_RT" "grep -q '^CONFIG_IP6_NF_MATCH_RT=y' $K/.config"
ck "内核无模块单体内核" "grep -q '^# CONFIG_MODULES is not set' $K/.config"
ck "内核无调试符号" "grep -q '^CONFIG_DEBUG_INFO_NONE=y' $K/.config"
ck "内核 KASAN 关闭" "grep -q '^# CONFIG_KASAN is not set' $K/.config"
ck "内核 lockdep 关闭" "grep -q '^# CONFIG_PROVE_LOCKING is not set' $K/.config"
ck "BBR 拥塞控制已启用" "grep -q '^CONFIG_TCP_CONG_BBR=y' $K/.config"
ck "透明大页已启用" "grep -q '^CONFIG_TRANSPARENT_HUGEPAGE=y' $K/.config"
ck "内核用 xz 压缩" "grep -q '^CONFIG_KERNEL_XZ=y' $K/.config"

sz=$(( $(stat -c%s "$K/bzImage" 2>/dev/null || echo 0) / 1024 ))
[ "$sz" -gt 0 ] && [ "$sz" -le 8192 ] && ok "bzImage ≤ 8MB（实际 ${sz}KB）" || bad "bzImage ${sz}KB 超出目标"

# 不存在的符号不能出现在配置里（会静默忽略）
ck "配置里无 NETFILTER_XT_TARGET_REJECT（不存在的符号）" \
   "! grep -q '^CONFIG_NETFILTER_XT_TARGET_REJECT=' $K/.config"
ck "配置里无 NETFILTER_XT_MATCH_RT（不存在的符号）" \
   "! grep -q '^CONFIG_NETFILTER_XT_MATCH_RT=' $K/.config"

hr "C. 系统组件"

for c in bash sshd nft apt dpkg adduser sudo nano curl wget less htop ping dig nc ss ip passwd useradd usermod; do
  ck "命令 $c 存在" "[ -x \"$S/usr/bin/$c\" ] || [ -x \"$S/usr/sbin/$c\" ] || [ -x \"$S/bin/$c\" ] || [ -x \"$S/sbin/$c\" ]"
done

ck "ufw 已安装" "[ -x $S/usr/sbin/ufw ]"
ck "iptables-nft 已安装" "[ -x $S/usr/sbin/iptables-nft ]"
ck "python3 可用（ufw 依赖）" "[ -x $S/usr/bin/python3 ]"
ck "lfos-tune.sh 已安装" "[ -x $S/usr/local/bin/lfos-tune ]"
ck "harden.sh 已安装" "[ -x $S/usr/local/sbin/harden.sh ]"

hr "D. 配置一致性"

ck "sysctl.d 有安全配置" "[ -f $S/etc/sysctl.d/99-lfos.conf ]"
ck "sysctl.d 有性能配置" "[ -f $S/etc/sysctl.d/99-lfos-perf.conf ]"
ck "sysctl.d 无备份文件混入" "[ -z \"$(ls $S/etc/sysctl.d/*.bak* 2>/dev/null)\" ]"
ck "init 遍历加载 sysctl.d" "grep -q 'for _f in /etc/sysctl.d' $S/sbin/init"
ck "init 创建 /tmp（早期）" "grep -q 'mkdir -p /tmp /run /var/tmp' $S/sbin/init"
ck "init 设置磁盘调度器" "grep -q 'queue/scheduler' $S/sbin/init"
ck "fstab 根分区有 noatime" "grep -q 'noatime' $S/etc/fstab"
ck "/etc/profile.d 有 PATH 配置" "[ -f $S/etc/profile.d/lfos-path.sh ]"
ck "sshd SetEnv PATH 已设" "grep -q '^SetEnv PATH=' $S/etc/ssh/sshd_config"

# 不能有冲突的 sysctl 定义
dups=$(grep -h '^[a-z]' "$S"/etc/sysctl.d/*.conf 2>/dev/null | sed 's/[[:space:]]*=.*//' | sort | uniq -d | wc -l)
if [ "$dups" -eq 0 ]; then ok "sysctl 配置无重复定义"
else warn "sysctl 有 $dups 个参数在多个文件里定义（后者覆盖前者，需确认是故意的）"
     grep -h '^[a-z]' "$S"/etc/sysctl.d/*.conf 2>/dev/null | sed 's/[[:space:]]*=.*//' | sort | uniq -d | head -5 | sed 's/^/        /'
fi

hr "E. 清理检查（不能有调试残留）"

ck "无 _ 开头的调试脚本" "[ -z \"$(ls $S/usr/local/bin/_* $S/usr/local/sbin/_* 2>/dev/null)\" ]"
ck "rootfs 无 .bak 文件（配置目录外允许）" "[ $(find $S/etc -name '*.bak*' 2>/dev/null | wc -l) -eq 0 ]"
ck "无 20GB 级测试文件" "[ -z \"$(find $S -size +100M -type f 2>/dev/null | head -1)\" ]"
ck "systemd 已禁用" "[ ! -e $S/usr/lib/systemd/systemd ]"

hr "F. 体积"

printf '  rootfs:  %s\n' "$(du -sh "$S" 2>/dev/null | cut -f1)"
printf '  bzImage: %s KB\n' "$sz"
printf '  ISO:     %s\n' "$(du -h /opt/lfOS/build/img/lfos-server.iso 2>/dev/null | cut -f1)"
printf '  包数量:  %s\n' "$(ls "$S/var/lib/dpkg/info/"*.list 2>/dev/null | wc -l)"

hr "结果"
printf '  \033[32m通过 %s\033[0m / \033[33m警告 %s\033[0m / \033[31m失败 %s\033[0m\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "  ✔ 可以发布" || echo "  ✘ 有失败项，需修复后再发布"
echo "DONE"
