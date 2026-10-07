#!/bin/bash
# =============================================================================
#  lfOS (LumenFluxOS / 流光OS) 安全基线加固脚本
#  对应设计方案 Phase 5：最小权限 / 强制访问控制 / 攻击面收敛
#
#  在目标机（lfOS 运行环境）内以 root 执行：
#      harden.sh [--check|--apply]
#    --apply  应用加固（默认）
#    --check  只检查当前状态，不做修改
#
#  设计原则：
#    - 幂等：可重复执行，不产生副作用
#    - 可审计：每步输出「做了什么 / 为什么」
#    - 不破坏可用性：先保证能登录，再收紧
# =============================================================================
set -uo pipefail

MODE="${1:---apply}"
CHANGED=0

c_ok()   { printf '  \033[32m[✓]\033[0m %s\n' "$*"; }
c_warn() { printf '  \033[33m[!]\033[0m %s\n' "$*"; }
c_info() { printf '  \033[36m[·]\033[0m %s\n' "$*"; }
sec()    { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }

# apply <描述> <命令...>：仅 --apply 模式执行
apply() {
  local desc="$1"; shift
  if [ "$MODE" = "--check" ]; then
    c_info "待加固: $desc"
    return 0
  fi
  if "$@" >/dev/null 2>&1; then
    c_ok "$desc"
    CHANGED=$((CHANGED+1))
  else
    c_warn "$desc（执行失败，可能目标不存在）"
  fi
}

# set_sysctl <键> <值>
set_sysctl() {
  local k="$1" v="$2"
  if [ "$MODE" = "--check" ]; then
    local cur; cur=$(sysctl -n "$k" 2>/dev/null || echo "N/A")
    if [ "$cur" = "$v" ]; then c_ok "$k = $v"
    else c_warn "$k = $cur（期望 $v）"; fi
    return 0
  fi
  if sysctl -w "$k=$v" >/dev/null 2>&1; then
    c_ok "$k = $v"
  else
    c_warn "$k（内核不支持，跳过）"
  fi
}

echo "=============================================================="
echo "  lfOS 安全基线加固     模式: $MODE"
echo "  主机: $(hostname 2>/dev/null || echo unknown)"
echo "  内核: $(uname -r)"
echo "  时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=============================================================="

# -----------------------------------------------------------------------------
sec "一、内核运行时参数（信息暴露面收敛）"
# -----------------------------------------------------------------------------
apply "隐藏内核指针（抬高 KASLR 绕过成本）" \
      sh -c 'echo 1 > /proc/sys/kernel/kptr_restrict'
apply "限制 dmesg 仅 root 可读" \
      sh -c 'echo 1 > /proc/sys/kernel/dmesg_restrict'
set_sysctl kernel.perf_event_paranoid 3
set_sysctl kernel.unprivileged_bpf_disabled 1
set_sysctl kernel.kptr_restrict 1
set_sysctl kernel.dmesg_restrict 1
# 限制 SysRq（只留同步与只读挂载，去掉危险功能）
set_sysctl kernel.sysrq 16
# 禁止非特权用户命名空间（容器逃逸常见入口）
set_sysctl kernel.unprivileged_userns_clone 0

# -----------------------------------------------------------------------------
sec "二、网络栈加固（反欺骗 / 反扫描）"
# -----------------------------------------------------------------------------
set_sysctl net.ipv4.conf.all.rp_filter 1
set_sysctl net.ipv4.conf.default.rp_filter 1
set_sysctl net.ipv4.conf.all.accept_source_route 0
set_sysctl net.ipv4.conf.all.accept_redirects 0
set_sysctl net.ipv4.conf.all.secure_redirects 0
set_sysctl net.ipv4.conf.all.send_redirects 0
set_sysctl net.ipv4.icmp_echo_ignore_broadcasts 1
set_sysctl net.ipv4.icmp_ignore_bogus_error_responses 1
set_sysctl net.ipv4.conf.all.log_martians 1
set_sysctl net.ipv4.tcp_syncookies 1
set_sysctl net.ipv6.conf.all.accept_redirects 0
set_sysctl net.ipv6.conf.all.accept_source_route 0
# 服务器不做路由器
set_sysctl net.ipv4.ip_forward 0

# -----------------------------------------------------------------------------
sec "三、文件权限（最小权限）"
# -----------------------------------------------------------------------------
apply "/etc/shadow 仅 root 可读 (400)"      chmod 0400 /etc/shadow
apply "/etc/gshadow 仅 root 可读 (400)"     chmod 0400 /etc/gshadow
apply "/etc/passwd 权限 (644)"              chmod 0644 /etc/passwd
apply "/etc/group 权限 (644)"               chmod 0644 /etc/group
apply "/root 目录权限 (700)"                chmod 0700 /root
apply "/tmp 粘滞位 (1777)"                  chmod 1777 /tmp
apply "/var/tmp 粘滞位 (1777)"              chmod 1777 /var/tmp
apply "sshd 密钥目录权限 (700)"             chmod 0700 /etc/ssh
apply "root SSH 目录权限 (700)"             chmod 0700 /root/.ssh

# -----------------------------------------------------------------------------
sec "四、SSH 服务加固"
# -----------------------------------------------------------------------------
if [ -f /etc/ssh/sshd_config ]; then
  if [ "$MODE" = "--apply" ]; then
    # 逐项确保存在且值正确（追加式，避免覆盖发行版默认）
    ensure_sshd() {
      local k="$1" v="$2"
      if grep -qiE "^\s*${k}\s+" /etc/ssh/sshd_config; then
        sed -i -E "s|^\s*${k}\s+.*|${k} ${v}|I" /etc/ssh/sshd_config
      else
        echo "${k} ${v}" >> /etc/ssh/sshd_config
      fi
    }
    ensure_sshd PermitRootLogin no
    ensure_sshd PasswordAuthentication no
    ensure_sshd PermitEmptyPasswords no
    ensure_sshd X11Forwarding no
    ensure_sshd MaxAuthTries 3
    ensure_sshd LoginGraceTime 30
    c_ok "sshd_config 已加固（禁 root、禁密码、限尝试次数）"
    # 语法校验，避免改坏导致无法登录
    if command -v sshd >/dev/null 2>&1; then
      if sshd -t 2>/dev/null; then c_ok "sshd 配置语法校验通过"
      else c_warn "sshd 配置语法有问题，请手工检查 /etc/ssh/sshd_config"; fi
    fi
  else
    c_info "待加固: sshd 禁 root 登录 / 禁密码认证 / 限尝试次数"
  fi
else
  c_warn "未找到 /etc/ssh/sshd_config（openssh 未安装？）"
fi

# -----------------------------------------------------------------------------
sec "五、内核模块加载限制"
# -----------------------------------------------------------------------------
# 单体内核（CONFIG_MODULES 未启用）下本项无意义，但保留以便将来支持模块时启用
if [ -d /etc/modprobe.d ]; then
  if [ "$MODE" = "--apply" ]; then
    cat > /etc/modprobe.d/lfos-blacklist.conf <<'EOF'
# lfOS 安全基线：屏蔽不必要且高危的内核模块
# 依据：减少可加载的攻击面（DCCP/SCTP/RDS/TIPC 曾多次出现漏洞）
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
install firewire-core /bin/false
install usb-storage /bin/false
EOF
    c_ok "已写入模块黑名单 /etc/modprobe.d/lfos-blacklist.conf"
  else
    c_info "待加固: 屏蔽 dccp/sctp/rds/tipc/firewire/usb-storage"
  fi
fi

# -----------------------------------------------------------------------------
sec "六、审计与日志"
# -----------------------------------------------------------------------------
# 单体内核 + 无 systemd 的 initramfs 环境下，仅做基础目录与权限保障
apply "建立审计日志目录"  mkdir -p /var/log/audit
apply "审计目录权限 (700)" chmod 0700 /var/log/audit

# -----------------------------------------------------------------------------
sec "七、可选：SELinux / AppArmor 状态"
# -----------------------------------------------------------------------------
if [ -f /sys/fs/selinux/enforce ]; then
  c_ok "SELinux 已挂载，当前 enforce=$(cat /sys/fs/selinux/enforce)"
elif [ -d /sys/kernel/security/selinux ]; then
  c_ok "SELinux 已编译进内核（策略未加载）"
else
  c_info "SELinux 未激活（内核已支持 CONFIG_SECURITY_SELINUX，需加载策略）"
fi
if [ -d /sys/kernel/security/apparmor ]; then
  c_ok "AppArmor 可用"
fi

# 已启用的 LSM 列表
if [ -r /sys/kernel/security/lsm ]; then
  c_ok "已启用 LSM: $(cat /sys/kernel/security/lsm)"
fi

# -----------------------------------------------------------------------------
echo
echo "=============================================================="
if [ "$MODE" = "--apply" ]; then
  printf '  加固完成：\033[32m%d\033[0m 项已应用\n' "$CHANGED"
else
  printf '  检查完成（未做修改）\n'
fi
echo "  持久化提示：以上运行时参数重启后失效。"
echo "  lfOS 通过 /etc/sysctl.d/99-lfos.conf 在启动时自动重新应用。"
echo "=============================================================="
