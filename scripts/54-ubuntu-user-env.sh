#!/usr/bin/env bash
# ============================================================================
#  lfOS - 用户管理体系对齐 Ubuntu
#
#  Ubuntu 的用户体系与裸 Debian/自建系统的差别，主要体现在四件事上：
#    1) /etc/skel —— 建用户时自动复制到家目录的模板文件
#       （.bashrc / .profile / .bash_logout，带彩色提示符、别名、历史设置）
#    2) sudo 组 —— 组成员默认可提权，Ubuntu 装机时创建的用户就在这个组
#    3) /etc/sudoers —— 定义谁能 sudo、secure_path、env_reset 等
#    4) adduser 的交互流程 —— 交互式建用户、自动建同名组、复制 skel
#
#  本脚本把这四项补齐，使 lfOS 的 `adduser` 行为与 Ubuntu 一致。
#
#  用法： bash 54-ubuntu-user-env.sh [all|libedit|skel|sudo|check|gate]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
PKGS="$LFOS/build/testpkgs"
IDX="$LFOS/build/debrepo/Packages-trixie"
MIRROR="${LFOS_DEB_MIRROR:-https://mirrors.aliyun.com/debian}"

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
skip(){ printf '  \033[33m[跳过]\033[0m %s\n' "$*"; }

idx_field() {
  awk -v RS='' -v p="$1" -v f="$2" '
    $1 == "Package:" && $2 == p {
      n = split($0, lines, "\n")
      for (i = 1; i <= n; i++) if (lines[i] ~ "^" f ": ") { sub("^" f ": ", "", lines[i]); print lines[i]; exit }
    }' "$IDX"
}

# ---------------------------------------------------------------------------
#  0. 补 libedit2（nslookup 依赖；也是 nftables 交互 CLI 需要的库）
# ---------------------------------------------------------------------------
do_libedit() {
  printf '\n\033[1;36m===== 补 libedit2 =====\033[0m\n'
  if ls "$LFS"/usr/lib/x86_64-linux-gnu/libedit.so.2 >/dev/null 2>&1 || \
     ls "$LFS"/usr/lib/libedit.so.2 >/dev/null 2>&1; then
    ok "libedit.so.2 已存在"; return 0
  fi
  local fn base
  fn=$(idx_field libedit2 Filename)
  [ -z "$fn" ] && { skip "索引里没有 libedit2"; return 0; }
  base=$(basename "$fn")
  [ -s "$PKGS/$base" ] || curl -fL --retry 2 --connect-timeout 20 --max-time 300 \
      -o "$PKGS/$base" "$MIRROR/$fn" 2>/dev/null
  if [ -s "$PKGS/$base" ]; then
    dpkg-deb -x "$PKGS/$base" "$LFS" 2>/dev/null && ok "已解包 libedit2"
    # 它可能还依赖 libbsd
    if ! ls "$LFS"/usr/lib/x86_64-linux-gnu/libbsd.so.0 >/dev/null 2>&1 && \
       ! ls "$LFS"/usr/lib/libbsd.so.0 >/dev/null 2>&1; then
      local fn2; fn2=$(idx_field libbsd0 Filename)
      if [ -n "$fn2" ]; then
        local b2; b2=$(basename "$fn2")
        [ -s "$PKGS/$b2" ] || curl -fL --retry 2 --connect-timeout 20 --max-time 300 -o "$PKGS/$b2" "$MIRROR/$fn2" 2>/dev/null
        [ -s "$PKGS/$b2" ] && dpkg-deb -x "$PKGS/$b2" "$LFS" 2>/dev/null && ok "已解包 libbsd0"
      fi
    fi
    # 登记进 dpkg
    cp -f "$PKGS/$base" "$LFS/tmp/" 2>/dev/null
    chroot "$LFS" /usr/bin/dpkg --unpack "/tmp/$base" >/dev/null 2>&1
    rm -f "$LFS/tmp/$base" 2>/dev/null
    chroot "$LFS" /usr/sbin/ldconfig 2>/dev/null && ok "ldconfig 完成"
  else
    printf '  \033[31m[失败]\033[0m 下载 libedit2\n'
  fi
}

# ---------------------------------------------------------------------------
#  1. /etc/skel —— 家目录模板（Ubuntu 风格）
# ---------------------------------------------------------------------------
do_skel() {
  printf '\n\033[1;36m===== 建立 /etc/skel 家目录模板 =====\033[0m\n'
  local skel="$LFS/etc/skel"
  mkdir -p "$skel"

  # ---- .bashrc：Ubuntu 默认的 .bashrc 精简版 ----
  # 说明：Ubuntu 的 .bashrc 有 100 多行（含大量注释和 git 提示符等）。
  # 这里保留真正影响体验的部分：历史设置、ls 彩色别名、提示符、
  # bash-completion 加载、以及 PS1 定义。
  cat > "$skel/.bashrc" <<'EOF'
# ~/.bashrc —— lfOS 默认 bash 配置（风格对齐 Ubuntu）

# 非交互式 shell 直接返回（scp/ssh 远程执行命令时不会加载别名）
case $- in
    *i*) ;;
      *) return;;
esac

# 命令历史
HISTCONTROL=ignoreboth          # 忽略重复命令和以空格开头的命令
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s histappend             # 多个会话的历史追加而非覆盖
shopt -s checkwinsize           # 窗口大小变化后更新 LINES/COLUMNS

# ls 彩色输出与常用别名（Ubuntu 默认就有）
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
fi
alias ls='ls --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# bash 补全（若安装了 bash-completion 包）
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# 提示符：绿色 user@host + 蓝色路径（与 Ubuntu 观感一致）
PS1='\[\e[01;32m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\$ '

# 让 ls 等程序输出 UTF-8（lfOS 已生成 C.UTF-8 locale）
export LANG=${LANG:-C.UTF-8}
export LC_ALL=${LC_ALL:-C.UTF-8}
EOF

  # ---- .profile：登录时读取 ----
  cat > "$skel/.profile" <<'EOF'
# ~/.profile —— 登录 shell 读取（风格对齐 Ubuntu）

# 把用户私有的 ~/bin 与 ~/.local/bin 加入 PATH（若存在）
if [ -d "$HOME/bin" ] ; then
    PATH="$HOME/bin:$PATH"
fi
if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi

# 交互式 bash 时加载 .bashrc
if [ -n "$BASH_VERSION" ]; then
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
fi

# 系统级环境基线（PATH / LANG / TMOUT 等）
if [ -f /etc/profile ]; then
    . /etc/profile
fi
EOF

  # ---- .bash_logout：退出时清理 ----
  cat > "$skel/.bash_logout" <<'EOF'
# ~/.bash_logout —— 退出登录 shell 时执行
# 清理屏幕（防止终端内容残留在滚动缓冲区里）
if [ "$SHLVL" = 1 ]; then
    [ -x /usr/bin/clear_console ] && /usr/bin/clear_console -q
fi
EOF

  # ---- .selected_editor：让 select-editor 记住选择（Ubuntu 有）----
  cat > "$skel/.selected_editor" <<'EOF'
# 由 select-editor 生成；默认使用 nano（Ubuntu 默认编辑器）
SELECTED_EDITOR="/usr/bin/nano"
EOF

  chmod 0644 "$skel"/.bashrc "$skel"/.profile "$skel"/.bash_logout "$skel"/.selected_editor
  # /etc/skel 只保留 root 可写（正常权限）
  chmod 0755 "$skel"

  ok "/etc/skel 已建立："
  ls -la "$skel" | tail -n +2 | awk '{printf "      %-22s %s\n", $9, $1}'

  # 已有的 root 家目录也补一份（root 是已存在的用户，adduser 不会重新复制）
  if [ -d "$LFS/root" ]; then
    for f in .bashrc .profile .bash_logout; do
      [ -f "$LFS/root/$f" ] || cp -f "$skel/$f" "$LFS/root/$f" 2>/dev/null
    done
    printf '  已为 /root 补齐缺失的配置文件\n'
  fi
}

# ---------------------------------------------------------------------------
#  2. sudo 组与 /etc/sudoers
# ---------------------------------------------------------------------------
do_sudo() {
  printf '\n\033[1;36m===== 配置 sudo 组与 /etc/sudoers =====\033[0m\n'
  [ -x "$LFS/usr/bin/sudo" ] || { skip "sudo 未安装"; return 0; }

  # ---- 创建 sudo 组（Ubuntu 用这个名字；Debian 传统用 sudo 组也是这个）----
  if grep -q '^sudo:' "$LFS/etc/group" 2>/dev/null; then
    ok "sudo 组已存在"
  else
    # Ubuntu 的 sudo 组 gid 是 27
    if ! grep -q ':27:' "$LFS/etc/group" 2>/dev/null; then
      printf 'sudo:x:27:\n' >> "$LFS/etc/group"
      ok "已创建 sudo 组（gid 27，与 Ubuntu 一致）"
    else
      printf 'sudo:x:1001:\n' >> "$LFS/etc/group"
      ok "已创建 sudo 组（gid 1001，27 已被占用）"
    fi
  fi
  # gshadow 里也补一条（组密码字段）
  if [ -f "$LFS/etc/gshadow" ] && ! grep -q '^sudo:' "$LFS/etc/gshadow" 2>/dev/null; then
    printf 'sudo:!::\n' >> "$LFS/etc/gshadow"
  fi

  # ---- /etc/sudoers ----
  # 结构与 Ubuntu 默认一致：env_reset、secure_path、root 与 %sudo 两条规则
  mkdir -p "$LFS/etc/sudoers.d"
  cat > "$LFS/etc/sudoers" <<'EOF'
# /etc/sudoers —— lfOS 配置（规则结构对齐 Ubuntu 默认）
#
# 本文件只能由 root 编辑，且建议用 visudo 校验语法后保存。
# 不要把本文件设为可写组或其他用户可读。

# 默认行为
Defaults        env_reset
Defaults        mail_badpass
Defaults        secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 主机别名（单机场景保持最简）
# User privilege specification
root    ALL=(ALL:ALL) ALL

# sudo 组成员可以执行任何命令（与 Ubuntu 一致）
%sudo   ALL=(ALL:ALL) ALL

# 允许 sudoers.d 目录下的片段式配置
#includedir /etc/sudoers.d
EOF
  chmod 0440 "$LFS/etc/sudoers"
  chown 0:0 "$LFS/etc/sudoers" 2>/dev/null

  # 放一个说明文件在 sudoers.d 里，并给出常见的免密示例（注释状态）
  cat > "$LFS/etc/sudoers.d/README" <<'EOF'
# 把自定义规则放在这个目录，避免直接改 /etc/sudoers。
# 文件名不要带 . 或 ~，否则 sudo 会忽略它。
#
# 示例：让 sudo 组免密（谨慎使用）
#   %sudo ALL=(ALL:ALL) NOPASSWD: ALL
EOF
  chmod 0440 "$LFS/etc/sudoers.d/README"
  chown 0:0 "$LFS/etc/sudoers.d/README" 2>/dev/null

  # ---- 验证语法 ----
  if chroot "$LFS" /usr/sbin/visudo -c -f /etc/sudoers 2>&1 | head -3 | sed 's/^/      /'; then
    ok "sudoers 语法校验通过"
  else
    printf '  \033[33m[告警]\033[0m sudoers 语法校验有问题\n'
  fi

  ok "sudo 体系就绪：sudo 组 + /etc/sudoers + /etc/sudoers.d"
}

# ---------------------------------------------------------------------------
#  3. adduser 的 Ubuntu 风格默认值
# ---------------------------------------------------------------------------
do_adduser_conf() {
  printf '\n\033[1;36m===== 配置 adduser 默认行为 =====\033[0m\n'
  mkdir -p "$LFS/etc"

  # 直接使用 adduser 包自带的官方配置，而不是自己拼一份。
  #
  # 踩过的坑：最初自己写了一份 adduser.conf，凭印象填了 DHOME_PERMS 之类的项，
  # 结果 adduser 直接报错并拒绝建用户：
  #     warn: Unknown variable `DHOME_PERMS' at `/etc/adduser.conf', line 10.
  #     Insecure $ENV{PATH} while running with -T switch
  #     id: 'alice': no such user
  # adduser 是 perl 脚本且开了污点模式（-T），配置里有未知变量就会中断。
  # 官方包里的 adduser.conf（3981 字节，含完整注释）才是权威版本，直接用即可。
  local f src
  f=$(ls "$PKGS"/adduser_*.deb 2>/dev/null | head -1)
  if [ -n "$f" ]; then
    for pair in "etc/adduser.conf:/etc/adduser.conf" "etc/deluser.conf:/etc/deluser.conf"; do
      src="${pair%%:*}"; dst="${pair##*:}"
      if dpkg-deb --fsys-tarfile "$f" 2>/dev/null | tar -xO "./$src" > /tmp/_conf.$$ 2>/dev/null && [ -s /tmp/_conf.$$ ]; then
        cp -f /tmp/_conf.$$ "$LFS$dst"
        chmod 0644 "$LFS$dst"
        printf '  \033[32m[OK]\033[0m %s（官方版，%s 字节）\n' "$dst" "$(stat -c%s "$LFS$dst")"
      else
        printf '  \033[33m[跳过]\033[0m %s 未能从包中提取\n' "$dst"
      fi
    done
    rm -f /tmp/_conf.$$
  else
    printf '  \033[31m[失败]\033[0m 找不到 adduser 包，无法提取官方配置\n'
    return 1
  fi

  # 确认关键项符合 Ubuntu 习惯（官方默认值本身就已经对齐，这里只做校验）
  printf '  关键项校验：\n'
  grep -E '^(USERGROUPS|DSHELL|DHOME|DSKEL|FIRST_UID|LAST_UID|DIR_MODE)=' "$LFS/etc/adduser.conf" \
    | sed 's/^/      /'
}

do_gate() {
  printf '\n\033[1;36m===== 用户体系门禁 =====\033[0m\n'
  local pass=0 fail=0
  ck() {
    local rc; set +o pipefail; eval "$2" >/dev/null 2>&1; rc=$?; set -o pipefail
    if [ "$rc" -eq 0 ]; then printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); fi
  }
  ck "nslookup 可用"          "chroot '$LFS' /usr/bin/nslookup -version"
  ck "adduser 可用"           "chroot '$LFS' /usr/sbin/adduser --version"
  ck "/etc/skel 存在"         "[ -d '$LFS/etc/skel' ]"
  ck ".bashrc 模板存在"       "[ -f '$LFS/etc/skel/.bashrc' ]"
  ck ".profile 模板存在"      "[ -f '$LFS/etc/skel/.profile' ]"
  ck ".bash_logout 模板存在"  "[ -f '$LFS/etc/skel/.bash_logout' ]"
  ck "sudo 组存在"            "grep -q '^sudo:' '$LFS/etc/group'"
  ck "/etc/sudoers 存在"      "[ -f '$LFS/etc/sudoers' ]"
  ck "sudoers 权限 0440"      "[ \"\$(stat -c%a '$LFS/etc/sudoers')\" = '440' ]"
  ck "sudoers 含 %sudo 规则"  "grep -q '^%sudo' '$LFS/etc/sudoers'"
  ck "/etc/adduser.conf 存在" "[ -f '$LFS/etc/adduser.conf' ]"
  ck "/etc/deluser.conf 存在" "[ -f '$LFS/etc/deluser.conf' ]"

  # 说明：这里刻意**不检查** adduser.conf 里有没有 USERGROUPS=yes / SKEL= 之类的行。
  # Debian/Ubuntu 的官方 adduser.conf 默认**全是注释**（3981 字节全是说明文字），
  # 生效的默认值全部内置在 perl 脚本里。最初按「文件里应该有这一行」写门禁，
  # 结果误报两条 [FAIL] —— 是检查项写错了，不是系统有问题。
  # 改为**实测行为**：真建一个用户，验证同名组与 skel 复制是否发生。
  printf '\n  实测 adduser（建 → 查 → 删）：\n'
  local tn="lfostest"
  chroot "$LFS" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /usr/sbin/adduser --disabled-password --gecos "lfOS Test" "$tn" > /tmp/_au.$$ 2>&1
  if chroot "$LFS" /usr/bin/id "$tn" >/dev/null 2>&1; then
    printf '    \033[32m[PASS]\033[0m adduser 建用户成功：%s\n' "$(chroot "$LFS" /usr/bin/id "$tn" 2>&1)"
    pass=$((pass+1))
  else
    printf '    \033[31m[FAIL]\033[0m adduser 建用户失败\n'
    sed 's/^/        /' /tmp/_au.$$ | head -5
    fail=$((fail+1))
  fi
  ck "同名组已创建（USERGROUPS）" "grep -q '^$tn:' '$LFS/etc/group'"
  ck "skel 已复制到家目录"        "[ -f '$LFS/home/$tn/.bashrc' ]"
  ck "家目录权限 0700"            "[ \"\$(stat -c%a '$LFS/home/$tn')\" = '700' ]"
  chroot "$LFS" /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /usr/sbin/deluser --remove-home "$tn" >/dev/null 2>&1
  printf '    已清理测试用户 %s\n' "$tn"
  rm -f /tmp/_au.$$

  printf '\n  体积: %s\n' "$(du -sh "$LFS" | cut -f1)"
  printf '  用户体系门禁: %d 通过 / %d 失败\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ 用户体系对齐 Ubuntu\033[0m\n' || printf '  \033[1;31m✗ 有缺口\033[0m\n'
  return "$fail"
}

case "${1:-all}" in
  libedit) do_libedit ;;
  skel)    do_skel ;;
  sudo)    do_sudo ;;
  adduser) do_adduser_conf ;;
  gate)    do_gate ;;
  all)     do_libedit; do_skel; do_sudo; do_adduser_conf; do_gate ;;
  *) echo "用法: $0 {all|libedit|skel|sudo|adduser|gate}"; exit 1 ;;
esac
