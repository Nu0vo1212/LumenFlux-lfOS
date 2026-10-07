#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 2b - 系统基础配置（用户数据库与 NSS）
#
#  这些文件是「系统可用性」的地基，缺了它们很多服务会以奇怪的方式失败：
#    /etc/passwd        用户数据库（sshd 权限分离必需 sshd 用户）
#    /etc/group         组数据库
#    /etc/shadow        口令影子（root 用 * 表示禁止口令登录）
#    /etc/nsswitch.conf glibc 的名字解析顺序 —— 缺它 getpwnam() 可能直接失败
#    /etc/services      端口名到端口号的映射（sshd/其他服务会查）
#    /etc/fstab         挂载表
#    /etc/resolv.conf   DNS 配置
#
#  踩过的坑：最初只装了工具链就跑 sshd，结果 sshd 报
#  「Privilege separation user sshd does not exist」这类错误；
#  更隐蔽的是缺少 nsswitch.conf 时，错误信息完全指不到根因。
#
#  用法： bash /opt/lfOS/scripts/83-setup-system.sh [all|check]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

[ -d "$LFS" ] || die "rootfs 不存在: $LFS"

do_setup() {
  hr "配置系统基础文件"

  mkdir -p "$LFS/etc" "$LFS/var/empty/sshd" "$LFS/var/log" "$LFS/root" \
           "$LFS/usr/sbin" "$LFS/var/spool/mail" "$LFS/home" \
           "$LFS/usr/lib/lfos" "$LFS/usr/share/udhcpc" 2>/dev/null

  # --- /etc/hostname ---
  # 踩过的坑：漏了这个文件，启动后主机名为空，日志与远程登录都看不出是哪台机器
  log "写入 /etc/hostname"
  printf 'lfos\n' > "$LFS/etc/hostname"

  # --- /etc/hosts ---
  #
  # 踩过的坑（较隐蔽）：这个文件**一直不存在**。后果不是"上不了网"（DNS 由
  # resolv.conf 走网络解析），而是**本机主机名反查失败**，表现为：
  #     sudo: unable to resolve host lfos: Name or service not known
  # 凡是会做主机名解析的程序（sudo、ssh、某些守护进程）都会刷这条警告。
  #
  # 解法与 Debian/Ubuntu 一致：加一行「127.0.1.1 <hostname>」，
  # 把本机主机名也指向回环地址。
  log "写入 /etc/hosts（含 127.0.1.1 本机主机名条目）"
  cat > "$LFS/etc/hosts" <<'HOSTSEOF'
# /etc/hosts —— 静态主机名解析
#
# 127.0.1.1 这一行是 Debian/Ubuntu 的约定：把本机主机名指向回环地址，
# 避免 sudo、ssh 等做主机名反查时报 "unable to resolve host"。
127.0.0.1       localhost
127.0.1.1       lfos

# IPv6
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
HOSTSEOF
  chmod 0644 "$LFS/etc/hosts"

  # --- 补齐 BusyBox 工具（只补系统缺失的 applet，不覆盖完整工具）---
  #
  #  为什么需要：完整 lfOS 由「真实工具」（coreutils/util-linux/iproute2…）
  #  构成，不含 BusyBox。但 DHCP 客户端 udhcpc 属于 BusyBox 专有 applet，
  #  没有对应替代品，于是启动脚本里的网络配置静默失效（表现为
  #  「网络地址：未配置」），而日志里看不出任何错误。
  #  这里把 BusyBox 放进 /usr/lib/lfos/，仅为确实缺失的命令建链接，
  #  避免它的精简版 applet 覆盖功能更完整的系统工具。
  # -------------------------------------------------------------------------
  if [ -f "$LFOS/build/busybox" ]; then
    log "安装 BusyBox 补充工具（/usr/lib/lfos/busybox）"
    install -m755 "$LFOS/build/busybox" "$LFS/usr/lib/lfos/busybox"
    # 同时提供 /usr/bin/busybox 链接。
    #
    # 为什么需要：busybox 实测自带 356 个 applet（top / vi / less / netstat /
    # tree / lsof / httpd / ntpd / sha256sum / adduser 等），但**只有建了这个
    # 链接**才能用 `busybox <命令>` 的调用形式，否则用户只能写完整路径
    # /usr/lib/lfos/busybox top，很容易误以为系统没有这些命令。
    # 实测踩到：SSH 里敲 `busybox top` 报 command not found。
    ln -sf /usr/lib/lfos/busybox "$LFS/usr/bin/busybox"

    # ---------------------------------------------------------------------
    #  只为「系统里确实没有」的命令建链接。
    #
    #  原则：BusyBox 的 applet 是精简实现，功能不如完整工具，所以**绝不覆盖**
    #  已有的系统命令；它在这里的角色是「补齐完整工具链没覆盖到的缺口」。
    #
    #  缺口清单及理由：
    #    udhcpc/udhcpc6  DHCP 客户端，完整工具链中没有替代品（缺了网络起不来）
    #    wget            HTTP 下载（完整 wget 未构建；BusyBox 版不支持 HTTPS）
    #    ping/ping6      连通性测试（iproute2 不含 ping）
    #    nslookup        DNS 诊断
    #    nc              网络调试（端口探测、简易传输）
    #    tftp/ftpget     受限环境下的文件传输
    # ---------------------------------------------------------------------
    local app
    for app in udhcpc udhcpc6 wget ping ping6 nslookup nc tftp ftpget; do
      if [ ! -e "$LFS/usr/sbin/$app" ] && [ ! -e "$LFS/sbin/$app" ] \
         && [ ! -e "$LFS/usr/bin/$app" ] && [ ! -e "$LFS/bin/$app" ]; then
        # 按惯例放：网络服务类进 sbin，用户命令进 bin
        case "$app" in
          udhcpc|udhcpc6) ln -sf /usr/lib/lfos/busybox "$LFS/usr/sbin/$app" ;;
          *)              ln -sf /usr/lib/lfos/busybox "$LFS/usr/bin/$app" ;;
        esac
      fi
    done

    # udhcpc 的配置脚本：租约变化时用 iproute2 配置地址/路由/DNS。
    # BusyBox 的 udhcpc 只会调用脚本，具体动作必须由脚本完成 ——
    # 若不提供这个脚本，udhcpc 拿到租约也不会配置任何东西。
    log "安装 udhcpc 配置脚本"
    cat > "$LFS/usr/share/udhcpc/default.script" <<'EOF'
#!/bin/sh
# lfOS udhcpc 配置脚本（由 BusyBox udhcpc 在租约变化时调用）
# 用 iproute2 完成配置：地址 / 默认路由 / DNS
case "$1" in
  deconfig)
    ip addr flush dev "$interface" 2>/dev/null
    ;;
  bound|renew)
    [ -n "$ip" ] && ip addr add "$ip/${mask:-24}" dev "$interface" 2>/dev/null
    if [ -n "$router" ]; then
      # router 可能是空格分隔的多个网关，取第一个
      ip route add default via "${router%% *}" dev "$interface" 2>/dev/null
    fi
    if [ -n "$dns" ]; then
      : > /etc/resolv.conf
      for d in $dns; do
        echo "nameserver $d" >> /etc/resolv.conf
      done
    fi
    ;;
esac
exit 0
EOF
    chmod 755 "$LFS/usr/share/udhcpc/default.script"
  else
    log "未找到 $LFOS/build/busybox —— 跳过 DHCP 客户端补充（网络需手工配置）"
  fi

  # --- /etc/passwd ---
  # root 的 shell 用 bash（交互体验）；服务账户一律 nologin
  log "写入 /etc/passwd"
  cat > "$LFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/sbin/nologin
daemon:x:6:6:daemon:/dev/null:/usr/sbin/nologin
adm:x:3:4:adm:/var/adm:/usr/sbin/nologin
lp:x:4:7:lp:/var/spool/lpd:/usr/sbin/nologin
mail:x:8:12:mail:/var/spool/mail:/usr/sbin/nologin
operator:x:11:0:operator:/root:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/:/usr/sbin/nologin
sshd:x:74:74:Privilege-separated SSH:/var/empty/sshd:/usr/sbin/nologin
EOF

  # --- /etc/group ---
  log "写入 /etc/group"
  cat > "$LFS/etc/group" <<'EOF'
root:x:0:
bin:x:1:
daemon:x:6:
sys:x:3:
adm:x:4:
tty:x:5:
disk:x:6:
lp:x:7:
mail:x:12:
kmem:x:15:
wheel:x:10:
users:x:100:
utmp:x:13:
nogroup:x:65534:
sshd:x:74:
EOF

  # --- /etc/shadow ---
  # root 口令字段为 "*"：表示该账户不能用口令认证登录（只能靠密钥/控制台）。
  # 这比留空更安全 —— 空口令在某些配置下会被当作「无口令即可登录」。
  log "写入 /etc/shadow（root 禁用口令登录）"
  cat > "$LFS/etc/shadow" <<'EOF'
root:*:19000:0:99999:7:::
bin:*:19000:0:99999:7:::
daemon:*:19000:0:99999:7:::
adm:*:19000:0:99999:7:::
lp:*:19000:0:99999:7:::
mail:*:19000:0:99999:7:::
operator:*:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
sshd:!:19000:0:99999:7:::
EOF

  # --- /etc/gshadow ---
  cat > "$LFS/etc/gshadow" <<'EOF'
root:*::
bin:*::
daemon:*::
sys:*::
adm:*::
tty:*::
disk:*::
lp:*::
mail:*::
wheel:*::
users:*::
nogroup:*::
sshd:*::
EOF

  # --- /etc/nsswitch.conf ---
  # glibc 的名字服务切换。缺这个文件时 getpwnam()/getgrnam() 等调用行为不确定，
  # 很多程序会以「找不到用户」这种迷惑性错误失败。
  log "写入 /etc/nsswitch.conf"
  cat > "$LFS/etc/nsswitch.conf" <<'EOF'
# lfOS 名字服务配置（glibc NSS）
passwd:    files
group:     files
shadow:    files
hosts:     files dns
networks:  files
protocols: files
services:  files
ethers:    files
rpc:       files
netgroup:  files
EOF

  # --- /etc/services（精简但覆盖常见服务）---
  log "写入 /etc/services"
  cat > "$LFS/etc/services" <<'EOF'
# lfOS 精简服务表（端口名 → 端口号）
ftp             21/tcp
ssh             22/tcp
ssh             22/udp
telnet          23/tcp
smtp            25/tcp
domain          53/tcp
domain          53/udp
http            80/tcp
pop3            110/tcp
ntp             123/udp
imap            143/tcp
https           443/tcp
submission      587/tcp
imaps           993/tcp
pop3s           995/tcp
ldap            389/tcp
ldaps           636/tcp
postgresql      5432/tcp
mysql           3306/tcp
redis           6379/tcp
EOF

  # --- /usr/sbin/nologin ---
  log "安装 /usr/sbin/nologin"
  cat > "$LFS/usr/sbin/nologin" <<'EOF'
#!/bin/sh
# lfOS：禁止该账户登录
echo "本账户不允许登录（nologin）。" >&2
exit 1
EOF
  chmod 755 "$LFS/usr/sbin/nologin"
  ln -sf /usr/sbin/nologin "$LFS/sbin/nologin" 2>/dev/null || true

  # --- /etc/fstab ---
  log "写入 /etc/fstab"
  cat > "$LFS/etc/fstab" <<'EOF'
# lfOS 挂载表
# <设备>        <挂载点>  <类型>  <选项>                  <dump> <pass>
proc            /proc     proc    nosuid,noexec,nodev    0      0
sysfs           /sys      sysfs   nosuid,noexec,nodev    0      0
devpts          /dev/pts  devpts  gid=5,mode=620          0      0
tmpfs           /run      tmpfs   defaults,mode=0755      0      0
tmpfs           /tmp      tmpfs   defaults,mode=1777      0      0
tmpfs           /dev/shm  tmpfs   defaults,mode=1777      0      0
EOF

  # --- /etc/resolv.conf（默认使用国内公共 DNS，可按需替换）---
  log "写入 /etc/resolv.conf"
  cat > "$LFS/etc/resolv.conf" <<'EOF'
# lfOS DNS 配置（Live 模式重启后还原）
nameserver 223.5.5.5
nameserver 119.29.29.29
EOF

  # --- /etc/shells ---
  cat > "$LFS/etc/shells" <<'EOF'
/bin/sh
/bin/bash
/usr/bin/bash
/usr/sbin/nologin
EOF

  # --- 权限（安全基线）---
  chmod 0644 "$LFS/etc/passwd" "$LFS/etc/group" "$LFS/etc/nsswitch.conf" \
             "$LFS/etc/services" "$LFS/etc/fstab" "$LFS/etc/resolv.conf" \
             "$LFS/etc/shells" 2>/dev/null || true
  chmod 0400 "$LFS/etc/shadow" "$LFS/etc/gshadow" 2>/dev/null || true
  chmod 0700 "$LFS/var/empty/sshd" 2>/dev/null || true

  log "系统基础配置完成"
}

do_check() {
  hr "系统基础配置检查"
  local pass=0 fail=0
  ck() {
    if eval "$2" >/dev/null 2>&1; then
      printf '  \033[32m[✓]\033[0m %s\n' "$1"; pass=$((pass+1))
    else
      printf '  \033[31m[✗]\033[0m %s\n' "$1"; fail=$((fail+1))
    fi
  }
  ck "/etc/passwd 存在且含 root"    "grep -q '^root:' '$LFS/etc/passwd'"
  ck "/etc/passwd 含 sshd 用户"     "grep -q '^sshd:' '$LFS/etc/passwd'"
  ck "/etc/group 含 sshd 组"        "grep -q '^sshd:' '$LFS/etc/group'"
  ck "/etc/shadow 权限 400"         "[ \$(stat -c%a '$LFS/etc/shadow') = '400' ]"
  ck "/etc/shadow 禁用 root 口令"   "grep -q '^root:\*:' '$LFS/etc/shadow'"
  ck "/etc/nsswitch.conf 存在"      "[ -f '$LFS/etc/nsswitch.conf' ]"
  ck "/etc/services 存在"           "[ -f '$LFS/etc/services' ]"
  ck "/etc/fstab 存在"              "[ -f '$LFS/etc/fstab' ]"
  ck "nologin 可执行"               "[ -x '$LFS/usr/sbin/nologin' ]"
  ck "/var/empty/sshd 权限 700"     "[ \$(stat -c%a '$LFS/var/empty/sshd') = '700' ]"
  echo
  printf '  系统基础配置: %d 项就位 / %d 项缺失\n' "$pass" "$fail"
  return "$fail"
}

case "${1:-all}" in
  all)   do_setup; do_check ;;
  check) do_check ;;
  *) die "未知参数: $1（可用 all|check）" ;;
esac
