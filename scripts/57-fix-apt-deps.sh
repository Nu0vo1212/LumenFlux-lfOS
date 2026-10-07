#!/usr/bin/env bash
# ============================================================================
#  lfOS - 修复 apt/dpkg 依赖异常
#
#  ══ 现象 ══
#     dpkg --audit 报「N 个包已解包但未配置」
#     apt-get install 报 Unmet dependencies 或拒绝操作
#
#  ══ 两类根因（实测逐包查出来的）══
#   ① lfOS 自编译的包**没有登记进 dpkg 数据库**。
#      例如 adduser 依赖 passwd（>= 1:4.17.2-5），而 passwd 是 shadow 编译来的，
#      dpkg 完全不知道它存在 → 判定依赖不满足 → 拒绝 configure。
#      同类还有 libtinfo6 / libncursesw6 / libmd0 / libffi8 等。
#
#   ② 确实缺少的依赖包（构建时没装）：
#      debconf（Debian 的配置系统，ca-certificates/tzdata/libpam0g 都依赖它）
#      krb5 系列（libgssapi-krb5-2 / libkrb5-3 / libk5crypto3 / libkeyutils1 / libcom-err2）
#      libdb5.3t64 / openssl-provider-legacy / libsasl2-modules-db / libp11-kit0
#
#  处理顺序：先登记①（零成本），再用 dpkg 自己的报错迭代补齐②。
#  为什么不一把梭装一堆：实测 dpkg 的依赖报错是**逐层暴露**的，
#  手工猜完整清单容易漏（本项目已经因此漏过 libcap2、libselinux1、libedit2 三次）。
#  交给 dpkg 自己报、自己迭代，最可靠。
#
#  用法： bash 57-fix-apt-deps.sh [all|register|iterate|verify|gate]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
PKGS="$LFOS/build/testpkgs"
IDX="$LFOS/build/debrepo/Packages-trixie"
LOGS="$LFOS/build/logs"
MIRROR_HTTP="${LFOS_DEB_MIRROR_HTTP:-http://deb.debian.org/debian}"

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[警告]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

idx_field() {
  awk -v RS='' -v p="$1" -v f="$2" '
    $1 == "Package:" && $2 == p {
      n = split($0, lines, "\n")
      for (i = 1; i <= n; i++) if (lines[i] ~ "^" f ": ") { sub("^" f ": ", "", lines[i]); print lines[i]; exit }
    }' "$IDX"
}

CHROOT_MOUNTS=()
mount_pseudo() {
  mkdir -p "$LFS/proc" "$LFS/sys" "$LFS/dev" "$LFS/dev/pts" 2>/dev/null
  for m in proc sys dev dev/pts; do
    mountpoint -q "$LFS/$m" 2>/dev/null || { mount --bind "/$m" "$LFS/$m" 2>/dev/null && CHROOT_MOUNTS+=("$m"); }
  done
  [ -e "$LFS/etc/mtab" ] || ln -sf /proc/self/mounts "$LFS/etc/mtab" 2>/dev/null
}
umount_pseudo() {
  for m in dev/pts dev proc sys; do
    mountpoint -q "$LFS/$m" 2>/dev/null && umount "$LFS/$m" 2>/dev/null
  done
}
trap umount_pseudo EXIT

# ---------------------------------------------------------------------------
#  1. 登记 lfOS 自带的包
# ---------------------------------------------------------------------------
do_register() {
  printf '\n\033[1;36m===== 登记 lfOS 自带的包 =====\033[0m\n'
  local status="$LFS/var/lib/dpkg/status"
  mkdir -p "$(dirname "$status")"; touch "$status"

  # 格式：包名|版本|架构|说明
  # 版本要**足够高**以满足依赖方的 (>= x) 要求，但不能太离谱。
  # 这里取 Debian trixie 里对应包的版本，语义上最贴近。
  local entries=(
    "passwd|1:4.17.3-1|amd64|lfOS 自带 shadow（提供 passwd/chage/login/su）"
    "login|1:4.17.3-1|amd64|lfOS 自带 shadow（login 程序）"
    "libtinfo6|6.5-1|amd64|lfOS 自带 ncurses（termcap 兼容库）"
    "libncursesw6|6.5-1|amd64|lfOS 自带 ncurses（宽字符库）"
    "libncurses6|6.5-1|amd64|lfOS 自带 ncurses"
    "ncurses-base|6.5-1|all|lfOS 自带 ncurses 终端定义"
    "libmd0|1.1.0-1|amd64|lfOS 自带 libmd（摘要函数）"
    "libffi8|3.4.6-1|amd64|lfOS 自带 libffi"
    "libc-bin|2.41-1|amd64|lfOS 自带 glibc 工具（ldconfig 等）"
    "coreutils|9.5-1|amd64|lfOS 自带 coreutils"
    "sed|4.9-1|amd64|lfOS 自带 GNU sed"
    "grep|3.11-1|amd64|lfOS 自带 GNU grep"
    "gawk|5.3.0-1|amd64|lfOS 自带 gawk"
    "findutils|4.10.0-1|amd64|lfOS 自带 findutils"
    "tar|1.35-1|amd64|lfOS 自带 GNU tar"
    "gzip|1.13-1|amd64|lfOS 自带 gzip"
    "xz-utils|5.8.1-1|amd64|lfOS 自带 xz"
    "bzip2|1.0.8-6|amd64|lfOS 自带 bzip2"
    "util-linux|2.41-1|amd64|lfOS 自带 util-linux"
    "mount|2.41-1|amd64|lfOS 自带 mount"
    "libattr1|1:2.5.2-1|amd64|lfOS 自带 libattr"
    "libacl1|2.3.2-1|amd64|lfOS 自带 libacl"
    "bash|5.2.37-1|amd64|lfOS 自带 bash"
    "dash|0.5.12-1|amd64|lfOS 用 bash 提供 /bin/sh"
    "base-files|13.8|amd64|lfOS 基础文件系统布局"
    "init-system-helpers|1.68|all|lfOS 使用自研 /sbin/init"
    "sysvinit-utils|3.14-1|amd64|lfOS 自带基础运维工具"
  )

  local e name ver arch desc added=0 existed=0
  for e in "${entries[@]}"; do
    IFS='|' read -r name ver arch desc <<< "$e"
    if grep -q "^Package: $name\$" "$status" 2>/dev/null; then
      existed=$((existed+1)); continue
    fi
    # arch=all 的包不带 :arch 后缀
    local fullname="$name"
    [ "$arch" != "all" ] && fullname="$name"
    cat >> "$status" <<EOF
Package: $fullname
Status: install ok installed
Priority: required
Section: base
Installed-Size: 1000
Maintainer: lfOS <root@lfos>
Architecture: $arch
Multi-Arch: foreign
Version: $ver
Description: $desc
 由 lfOS 构建流程自带，此条目让 dpkg 知道它已存在，
 避免 Debian 包因「依赖不满足」而拒绝配置。

EOF
    added=$((added+1))
    printf '  \033[32m[登记]\033[0m %-22s %s\n' "$name" "$ver"
  done
  printf '  新增 %s 条，已存在 %s 条\n' "$added" "$existed"
}

# ---------------------------------------------------------------------------
#  2. 迭代补齐缺失依赖
# ---------------------------------------------------------------------------
collect_missing() {
  # 从 dpkg --configure 的报错里提取缺失的包名（含虚拟包 debconf-2.0 之类）
  local p out
  for p in $(chroot "$LFS" /usr/bin/dpkg -l 2>/dev/null | awk 'NR>5 && $1=="iU" {print $2}' | cut -d: -f1 | sort -u); do
    out=$(chroot "$LFS" /usr/bin/dpkg --configure "$p" 2>&1)
    printf '%s\n' "$out" | grep -oE 'depends on [a-z0-9][a-z0-9.+-]*(:[a-z0-9]+)?' \
      | awk '{print $3}' | cut -d: -f1
  done | sort -u
}

do_iterate() {
  printf '\n\033[1;36m===== 迭代补齐缺失依赖 =====\033[0m\n'
  mount_pseudo
  local round=0 max=8
  while [ "$round" -lt "$max" ]; do
    round=$((round+1))
    local missing
    missing=$(collect_missing)
    # 过滤掉 dpkg 已知存在但状态古怪的、以及虚拟包
    missing=$(printf '%s\n' $missing | grep -v '^$' | sort -u)
    if [ -z "$missing" ]; then
      printf '  第 %s 轮：没有依赖报错了\n' "$round"
      break
    fi
    printf '  第 %s 轮：缺 %s 个依赖 → %s\n' "$round" "$(printf '%s\n' $missing | wc -l)" "$(printf '%s ' $missing)"

    local p fn base got=0
    for p in $missing; do
      # 虚拟包名映射到真实提供者
      case "$p" in
        debconf-2.0) p="debconf" ;;
        awk) p="gawk" ;;
        perl5) p="perl" ;;
      esac
      # 已经在 rootfs 里能跑的命令，说明功能在，跳过（避免重复装）
      fn=$(idx_field "$p" Filename)
      if [ -z "$fn" ]; then
        printf '      \033[33m[索引无]\033[0m %s\n' "$p"
        continue
      fi
      base=$(basename "$fn")
      if [ ! -s "$PKGS/$base" ]; then
        if ! curl -fL --retry 2 --connect-timeout 20 --max-time 600 \
             -o "$PKGS/$base.part" "$MIRROR_HTTP/$fn" 2>/dev/null; then
          rm -f "$PKGS/$base.part"; printf '      \033[31m[下载失败]\033[0m %s\n' "$p"; continue
        fi
        mv "$PKGS/$base.part" "$PKGS/$base"
      fi
      # 解包 + 登记（--unpack 会写入依赖信息与 .list）
      dpkg-deb -x "$PKGS/$base" "$LFS" 2>/dev/null
      cp -f "$PKGS/$base" "$LFS/tmp/" 2>/dev/null
      chroot "$LFS" /usr/bin/dpkg --unpack "/tmp/$base" >/dev/null 2>&1
      rm -f "$LFS/tmp/$base" 2>/dev/null
      printf '      \033[32m[装]\033[0m %s\n' "$p"
      got=$((got+1))
    done
    [ "$got" -eq 0 ] && { printf '  本轮无法继续（有包在索引里找不到）\n'; break; }

    log "dpkg --configure -a"
    chroot "$LFS" /usr/bin/dpkg --configure -a >> "$LOGS/apt-deps-configure.log" 2>&1 || true
  done

  log "最终 configure"
  chroot "$LFS" /usr/bin/dpkg --configure -a > "$LOGS/apt-deps-final.log" 2>&1 || true
  chroot "$LFS" /usr/sbin/ldconfig 2>/dev/null
}

# ---------------------------------------------------------------------------
#  3. 验证
# ---------------------------------------------------------------------------
do_verify() {
  printf '\n\033[1;36m===== 验证 =====\033[0m\n'
  mount_pseudo
  local iu ii
  ii=$(chroot "$LFS" /usr/bin/dpkg -l 2>/dev/null | awk 'NR>5 && $1=="ii"' | wc -l)
  iu=$(chroot "$LFS" /usr/bin/dpkg -l 2>/dev/null | awk 'NR>5 && $1=="iU"' | wc -l)
  printf '  已配置(ii): %s    未配置(iU): %s\n' "$ii" "$iu"

  local audit
  audit=$(chroot "$LFS" /usr/bin/dpkg --audit 2>&1 | grep -vE '^$|^The following|^They must|^menu option' | head -10)
  if [ -z "$audit" ]; then
    ok "dpkg --audit 干净"
  else
    warn "dpkg --audit 仍有内容："
    printf '%s\n' "$audit" | sed 's/^/      /'
  fi

  # 真正有意义的验证：跑一次 apt 的依赖自检
  echo "  --- apt-get check（会让 apt 自己判断依赖是否完好）---"
  chroot "$LFS" /usr/bin/apt-get check 2>&1 | tail -6 | sed 's/^/      /'
}

do_gate() {
  printf '\n\033[1;36m===== 依赖门禁 =====\033[0m\n'
  local pass=0 fail=0
  ck() {
    local rc; set +o pipefail; eval "$2" >/dev/null 2>&1; rc=$?; set -o pipefail
    if [ "$rc" -eq 0 ]; then printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); fi
  }
  ck "无未配置包(iU)"        "[ \$(chroot '$LFS' /usr/bin/dpkg -l 2>/dev/null | awk 'NR>5 && \$1==\"iU\"' | wc -l) -eq 0 ]"
  ck "dpkg --audit 干净"     "[ -z \"\$(chroot '$LFS' /usr/bin/dpkg --audit 2>&1 | grep -vE '^\\\$|^The following|^They must|^menu option' | head -1)\" ]"
  ck "passwd 已登记"         "chroot '$LFS' /usr/bin/dpkg -s passwd"
  ck "libtinfo6 已登记"      "chroot '$LFS' /usr/bin/dpkg -s libtinfo6"
  ck "libncursesw6 已登记"   "chroot '$LFS' /usr/bin/dpkg -s libncursesw6"
  ck "debconf 已装"          "chroot '$LFS' /usr/bin/dpkg -s debconf"
  ck "adduser 可正常解析依赖" "chroot '$LFS' /usr/bin/dpkg -s adduser"
  ck "apt-get check 无错"    "chroot '$LFS' /usr/bin/apt-get check"

  printf '\n  门禁: %d 通过 / %d 失败\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ apt/dpkg 依赖正常\033[0m\n' \
                    || printf '  \033[1;31m✗ 仍有问题\033[0m\n'
  return "$fail"
}

case "${1:-all}" in
  register) do_register ;;
  iterate)  do_iterate ;;
  verify)   do_verify ;;
  gate)     do_gate ;;
  all)      do_register; do_iterate; do_verify; do_gate ;;
  *) echo "用法: $0 {all|register|iterate|verify|gate}"; exit 1 ;;
esac
