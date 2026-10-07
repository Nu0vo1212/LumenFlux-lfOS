#!/usr/bin/env bash
# ============================================================================
#  lfOS - 开启 root 密码 SSH 登录（仅供测试）
#
#  默认镜像是「高安全」配置：PermitRootLogin no + PasswordAuthentication no
#  + root 账号锁定，只能用 ED25519 密钥登录。这是设计方案的安全宗旨要求的。
#
#  但做实测时需要能直接用 root + 密码 SSH 进去操作，本脚本提供这个开关。
#
#  ⚠ 安全提醒：开启后 root 可被密码爆破，只应在隔离的测试网络（如
#    VirtualBox NAT + 宿主端口转发）中使用，绝不要用于公网暴露的实例。
#
#  用法：
#    bash 51-enable-ssh-password.sh on  [密码]   # 开启（默认密码 lfos）
#    bash 51-enable-ssh-password.sh off          # 关闭，恢复安全基线
#    bash 51-enable-ssh-password.sh status       # 查看当前状态
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
DEFPASS="${LFOS_TEST_PASSWORD:-lfos}"

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[警告]\033[0m %s\n' "$*"; }

SSHD_CONF="$LFS/etc/ssh/sshd_config"

do_on() {
  local pass="${1:-$DEFPASS}"
  printf '\n\033[1;36m===== 开启 root 密码登录（测试模式）=====\033[0m\n'

  # --- 1. 设置 root 密码 ---
  # 用 chroot 里的 chpasswd 设置，密码经 stdin 传入（不落盘到明文文件）
  if printf 'root:%s\n' "$pass" | chroot "$LFS" /usr/sbin/chpasswd 2>/dev/null; then
    ok "root 密码已设置"
  else
    warn "chpasswd 失败，改用 passwd --stdin 尝试"
    printf '%s\n%s\n' "$pass" "$pass" | chroot "$LFS" /usr/bin/passwd --stdin root 2>/dev/null \
      && ok "root 密码已设置（passwd）" || warn "两者都失败，请检查 shadow 是否可用"
  fi

  # 确认 shadow 里不再是锁定的 *
  local hp
  hp=$(grep '^root:' "$LFS/etc/shadow" 2>/dev/null | cut -d: -f2 | cut -c1-3)
  case "$hp" in
    ""|"*"|"!") warn "root 仍处于锁定状态（shadow 第二字段前缀: '$hp'）" ;;
    *) ok "shadow 中 root 已设置密码哈希（前缀 $hp）" ;;
  esac

  # --- 2. 放开 sshd 配置 ---
  # 逐项替换，避免重复行；同时把原安全值注释掉以便对照
  sed -i -E 's/^([[:space:]]*)PermitRootLogin[[:space:]]+.*/\1PermitRootLogin yes/' "$SSHD_CONF"
  sed -i -E 's/^([[:space:]]*)PasswordAuthentication[[:space:]]+.*/\1PasswordAuthentication yes/' "$SSHD_CONF"
  sed -i -E 's/^([[:space:]]*)KbdInteractiveAuthentication[[:space:]]+.*/\1KbdInteractiveAuthentication yes/' "$SSHD_CONF"

  log "sshd_config 关键项现在是："
  grep -nE '^\s*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|PubkeyAuthentication)' \
    "$SSHD_CONF" | sed 's/^/    /'

  # --- 3. 验证配置语法 ---
  if chroot "$LFS" /usr/sbin/sshd -t 2>&1 | head -3 | sed 's/^/    /'; then
    ok "sshd 配置语法通过"
  fi

  printf '\n  \033[1;33m登录信息： root / %s\033[0m\n' "$pass"
  warn "这是测试配置，请勿用于公网"
}

do_off() {
  printf '\n\033[1;36m===== 恢复安全基线 =====\033[0m\n'
  sed -i -E 's/^([[:space:]]*)PermitRootLogin[[:space:]]+.*/\1PermitRootLogin no/' "$SSHD_CONF"
  sed -i -E 's/^([[:space:]]*)PasswordAuthentication[[:space:]]+.*/\1PasswordAuthentication no/' "$SSHD_CONF"
  sed -i -E 's/^([[:space:]]*)KbdInteractiveAuthentication[[:space:]]+.*/\1KbdInteractiveAuthentication no/' "$SSHD_CONF"
  # 重新锁定 root 密码
  chroot "$LFS" /usr/bin/passwd -l root 2>/dev/null && ok "root 密码已锁定"
  grep -nE '^\s*(PermitRootLogin|PasswordAuthentication)' "$SSHD_CONF" | sed 's/^/    /'
}

do_status() {
  printf '\n\033[1;36m===== 当前 SSH 认证状态 =====\033[0m\n'
  grep -nE '^\s*(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|KbdInteractiveAuthentication)' \
    "$SSHD_CONF" 2>/dev/null | sed 's/^/  /'
  local hp
  hp=$(grep '^root:' "$LFS/etc/shadow" 2>/dev/null | cut -d: -f2)
  case "$hp" in
    ""|"*"|"!") printf '  root 账号: \033[33m已锁定\033[0m（不能密码登录）\n' ;;
    *)          printf '  root 账号: \033[32m已设密码\033[0m（哈希前缀 %s）\n' "$(printf '%s' "$hp" | cut -c1-3)" ;;
  esac
}

case "${1:-status}" in
  on)     shift; do_on "$@" ;;
  off)    do_off ;;
  status) do_status ;;
  *) echo "用法: $0 {on [密码]|off|status}"; exit 1 ;;
esac
