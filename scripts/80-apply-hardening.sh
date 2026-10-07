#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 5 - 安全基线集成
#  把设计方案的加固交付物落进 rootfs：
#    - /etc/nftables.conf          防火墙（默认拒绝入站）
#    - /etc/ssh/sshd_config         SSH 加固
#    - /usr/local/sbin/harden.sh    一键加固脚本
#    - /etc/sysctl.d/99-lfos.conf   运行时内核参数
#    - /etc/systemd/system/*.d/     （预留）systemd 硬化 drop-in
#
#  用法： bash /opt/lfOS/scripts/80-apply-hardening.sh [all|check]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
CFG="/mnt/d/lfOS/config"

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

[ -d "$LFS" ] || die "rootfs 不存在: $LFS"

do_all() {
  hr "集成安全基线"

  # --- 目录准备 ---
  mkdir -p "$LFS/etc/sysctl.d" "$LFS/etc/ssh" "$LFS/usr/local/sbin" \
           "$LFS/etc/nftables" "$LFS/etc/profile.d" \
           "$LFS/etc/systemd/system/sshd.service.d" 2>/dev/null

  # --- 1. 运行时内核参数 ---
  if [ -f "$CFG/sysctl-lfos.conf" ]; then
    cp -f "$CFG/sysctl-lfos.conf" "$LFS/etc/sysctl.d/99-lfos.conf"
    log "已安装 /etc/sysctl.d/99-lfos.conf（$(grep -cvE '^\s*#|^\s*$' "$LFS/etc/sysctl.d/99-lfos.conf") 条）"
  else
    log "警告：未找到 $CFG/sysctl-lfos.conf"
  fi

  # --- 2. 防火墙 ---
  if [ -f "$CFG/nftables-lfos.conf" ]; then
    cp -f "$CFG/nftables-lfos.conf" "$LFS/etc/nftables.conf"
    chmod 600 "$LFS/etc/nftables.conf"
    log "已安装 /etc/nftables.conf（默认拒绝入站，仅放行 22）"
  fi

  # --- 3. SSH 加固 ---
  if [ -f "$CFG/sshd_config-lfos" ]; then
    cp -f "$CFG/sshd_config-lfos" "$LFS/etc/ssh/sshd_config"
    chmod 600 "$LFS/etc/ssh/sshd_config"
    log "已安装 /etc/ssh/sshd_config（禁 root、禁密码、现代套件）"
  fi

  # --- 4. 一键加固脚本 ---
  if [ -f "$CFG/harden.sh" ]; then
    cp -f "$CFG/harden.sh" "$LFS/usr/local/sbin/harden.sh"
    chmod 755 "$LFS/usr/local/sbin/harden.sh"
    log "已安装 /usr/local/sbin/harden.sh"
  fi

  # --- 5. systemd 硬化 drop-in（Phase 4 用 systemd 时生效）---
  cat > "$LFS/etc/systemd/system/sshd.service.d/hardening.conf" <<'EOF'
# lfOS sshd 服务硬化（参考 secureblue / Kicksecure 的 drop-in 写法）
[Service]
# 禁止提权
NoNewPrivileges=yes
# 系统调用白名单：只允许服务类调用
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallErrorNumber=EPERM
# 地址族限制：sshd 只需要 inet/inet6/unix
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
# 文件系统保护
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
# 只允许读 sshd 配置与主机密钥
ReadWritePaths=/var/lib/sshd /run/sshd
EOF
  log "已安装 sshd.service 硬化 drop-in"

  # --- 6. 登录横幅（合规要求：未授权访问警告）---
  cat > "$LFS/etc/issue" <<'EOF'

lfOS (LumenFluxOS / 流光OS) \r  \n  (\l)

  未经授权严禁访问本系统。所有连接与操作均被记录。
  Unauthorized access is prohibited. All activity is monitored.

EOF

  # --- 7. 环境基线 ---
  #
  #  locale 的启用顺序很重要（这是实测踩坑换来的经验）：
  #    必须先由 scripts/45-build-locale.sh 用 localedef 生成 locale 数据，
  #    再在这里设置 LANG/LC_ALL。顺序颠倒会出严重问题：
  #
  #    早期曾直接写 export LANG=C.UTF-8，理由是「以为 C.UTF-8 是 glibc 内置的」。
  #    这个理解是**错的** —— C.UTF-8 同样需要 locale 数据文件。当时数据不存在，
  #    后果不是「显示乱码」这么轻，而是 bash 直接段错误（rc=139 / SIGSEGV）：
  #        bash: warning: setlocale: LC_ALL: cannot change locale (C.UTF-8)
  #        Segmentation fault
  #    PID 1 的 shell 因此每 2 秒崩溃重启，系统实际不可用。
  #
  #    现在 45-build-locale.sh 已生成 C.UTF-8 / en_US.UTF-8 / zh_CN.UTF-8，
  #    因此可以安全启用。若你的构建流程跳过了那一步，请把下面的 LANG/LC_ALL
  #    注释掉，否则会重演段错误。
  cat > "$LFS/etc/profile" <<'EOF'
# lfOS 全局环境基线
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# UTF-8 显示。前提：locale 数据已由 scripts/45-build-locale.sh 生成，
# 否则 setlocale 失败会导致 bash 段错误（详见脚本内注释）。
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export HISTSIZE=1000
export HISTFILESIZE=2000
# 命令历史不记录以空格开头的命令（避免密码等敏感信息入库）
export HISTCONTROL=ignorespace:ignoredups
# 会话超时：10 分钟无操作自动登出（30 * 60 秒）
export TMOUT=600
umask 022
EOF
  chmod 644 "$LFS/etc/profile"
  log "已安装 /etc/profile（PATH/HISTCONTROL/TMOUT；不含 locale）"

  # --- 7b. 发行标识 ---
  # ISO 构建阶段也会写，但磁盘安装的系统同样需要 ——
  # 否则 `cat /etc/lfos-release` 会报 No such file or directory。
  cat > "$LFS/etc/lfos-release" <<'EOF'
NAME="lfOS"
PRETTY_NAME="LumenFluxOS (流光OS)"
ID=lfos
VERSION="0.3.0"
VERSION_CODENAME=lumen
KERNEL_FAMILY="6.15"
DESCRIPTION="从零构建的高性能 / 高安全 / 低占用 Linux 服务器系统"
EOF
  chmod 644 "$LFS/etc/lfos-release"
  cp -f "$LFS/etc/lfos-release" "$LFS/etc/os-release" 2>/dev/null || true
  log "已安装 /etc/lfos-release 与 /etc/os-release"

  # --- 8. root 的 bash 配置 ---
  cat > "$LFS/root/.bashrc" <<'EOF'
# lfOS root shell 配置
export PS1='\[\e[1;31m\]lfos\[\e[0m\]:\w# '
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
EOF
  chmod 600 "$LFS/root/.bashrc" 2>/dev/null || true

  cat > "$LFS/root/.bash_profile" <<'EOF'
[ -f /etc/profile ] && . /etc/profile
[ -f ~/.bashrc ] && . ~/.bashrc
EOF
  chmod 600 "$LFS/root/.bash_profile" 2>/dev/null || true
  log "已配置 root shell"
}

do_check() {
  hr "安全基线安装检查"
  local pass=0 fail=0
  ck() {
    if [ -e "$2" ]; then printf '  \033[32m[✓]\033[0m %-42s %s\n' "$1" "$2"; pass=$((pass+1))
    else printf '  \033[31m[✗]\033[0m %-42s 缺失\n' "$1"; fail=$((fail+1)); fi
  }
  ck "运行时内核参数"   "$LFS/etc/sysctl.d/99-lfos.conf"
  ck "防火墙规则"       "$LFS/etc/nftables.conf"
  ck "SSH 加固配置"     "$LFS/etc/ssh/sshd_config"
  ck "一键加固脚本"     "$LFS/usr/local/sbin/harden.sh"
  ck "sshd 硬化 drop-in" "$LFS/etc/systemd/system/sshd.service.d/hardening.conf"
  ck "登录横幅"         "$LFS/etc/issue"
  ck "全局环境基线"     "$LFS/etc/profile"
  ck "root bashrc"      "$LFS/root/.bashrc"
  echo
  printf '  安全基线: %d 项就位 / %d 项缺失\n' "$pass" "$fail"
}

case "${1:-all}" in
  all)   do_all; do_check ;;
  check) do_check ;;
  *) die "未知参数: $1（可用 all|check）" ;;
esac
