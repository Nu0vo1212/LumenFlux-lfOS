#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 2c - 网络工具链构建（nftables 及其依赖）
#
#  目标：让设计方案 Phase 5 的防火墙规则真正生效。
#  此前内核侧（CONFIG_NF_TABLES=y）与规则文件（/etc/nftables.conf）都已就绪，
#  只缺用户态工具，本脚本补齐：
#      libmnl    →  netlink 最小封装库（libnftnl 的依赖）
#      libnftnl  →  nftables 内核接口的库封装
#      nftables  →  nft 命令本体
#
#  版本关系（实测查证，非推测）：
#      nftables 1.1.1 的 configure.ac 要求 libnftnl >= 1.2.8
#      而 netfilter.org 的发行目录最高只到 libnftnl 1.2.4
#      → 改用 Debian 源的 libnftnl 1.2.9（上游源码，发布滞后所致）
#
#  用法： bash /opt/lfOS/scripts/42-build-net.sh [all|libmnl|libnftnl|nftables|gate]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
TOOLS="$LFOS/build/tools"
SRC="${LFS_SOURCES:-$LFOS/src}"
LOGS="$LFOS/build/logs"
TGT="${LFS_TGT:-x86_64-lfos-linux-gnu}"
JOBS="${LFOS_JOBS:-$(nproc)}"

export LC_ALL=C
export PATH="$TOOLS/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CC="$TGT-gcc" CXX="$TGT-g++" AR="$TGT-ar" RANLIB="$TGT-ranlib"
export STRIP="$TGT-strip" NM="$TGT-nm" LD="$TGT-ld"
export CFLAGS="-O2 -pipe"
export LDFLAGS="-Wl,-O1 -Wl,--as-needed"
# pkg-config 必须只在 sysroot 内查找，否则会误用宿主机的 .pc 导致链接到宿主的库
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$LFS/usr/lib/pkgconfig:$LFS/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$LFS"

mkdir -p "$LOGS"
hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }

extract() { # extract <目录名> <tarball...>
  local dir="$1"; shift
  if [ -d "$SRC/$dir" ] && [ -f "$SRC/$dir/configure" ]; then
    log "复用已解压 $dir"; return 0
  fi
  local t
  for t in "$@"; do
    if [ -f "$SRC/$t" ]; then
      rm -rf "$SRC/$dir"
      tar -xf "$SRC/$t" -C "$SRC" || die "解压 $t 失败"
      log "解压 $t → $dir"
      return 0
    fi
  done
  die "缺少源码包（候选: $*）"
}

build_pkg() { # build_pkg <名> <目录> <额外 configure 参数...>
  local name="$1" dir="$2"; shift 2
  hr "构建 $name"
  cd "$SRC/$dir" || die "cd 失败"
  log "configure"
  if ! ./configure --prefix=/usr --host="$TGT" --build="$(gcc -dumpmachine)" \
        --disable-static --with-sysroot="$LFS" "$@" \
        > "$LOGS/net-$name-configure.log" 2>&1; then
    tail -25 "$LOGS/net-$name-configure.log"
    die "$name configure 失败"
  fi
  log "make -j$JOBS"
  if ! make -j"$JOBS" > "$LOGS/net-$name-make.log" 2>&1; then
    grep -nE 'error:|Error [0-9]' "$LOGS/net-$name-make.log" | head -12
    die "$name make 失败"
  fi
  log "install"
  local FK=""
  command -v fakeroot >/dev/null 2>&1 && FK="fakeroot"
  if ! $FK make DESTDIR="$LFS" install >> "$LOGS/net-$name-make.log" 2>&1; then
    tail -15 "$LOGS/net-$name-make.log"; die "$name install 失败"
  fi
  ok "$name 构建完成"
  cd "$SRC"
}

pkg_libmnl() {
  extract libmnl-1.0.5 libmnl-1.0.5.tar.bz2
  build_pkg libmnl libmnl-1.0.5
}

pkg_libnftnl() {
  extract libnftnl-1.2.9 libnftnl_1.2.9.orig.tar.xz libnftnl-1.2.9.tar.bz2
  build_pkg libnftnl libnftnl-1.2.9
}

pkg_nftables() {
  extract nftables-1.1.1 nftables-1.1.1.tar.xz
  # 选项说明（均来自实测 ./configure --help 与实际报错）：
  #   --disable-man-doc 不生成 man 手册 —— 避免引入 docbook/xmlto 文档工具链
  #   --with-mini-gmp   使用内置 mini-gmp，避免依赖 libgmp
  #   --without-cli     禁用交互式 CLI
  #
  #  为什么必须加 --without-cli（实测踩到）：
  #    nftables 1.1.1 的交互 CLI 依赖 **libedit**，而不是 readline。
  #    系统里有 readline 但它不认，configure 因此直接失败：
  #        checking for readline in -ledit... no
  #        configure: error: No suitable version of libedit found
  #    所谓交互式 CLI 指的是直接敲 `nft` 进入的那个 shell 界面；
  #    服务器场景下规则都由脚本加载（nft -f）或单条命令（nft add ...），
  #    用不到该界面，禁用它是合理取舍（也少引一个库）。
  #    将来若确需交互模式，补上 libedit 并去掉此选项即可。
  build_pkg nftables nftables-1.1.1 --disable-man-doc --with-mini-gmp --without-cli
}

do_gate() {
  hr "网络工具链门禁"
  local pass=0 fail=0
  chk() {
    local rc
    set +o pipefail
    eval "$2" >/dev/null 2>&1
    rc=$?
    set -o pipefail
    if [ "$rc" -eq 0 ]; then printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); fi
  }

  chk "libmnl.so 已安装"     "ls '$LFS'/usr/lib/libmnl.so* 2>/dev/null | head -1"
  chk "libnftnl.so 已安装"   "ls '$LFS'/usr/lib/libnftnl.so* 2>/dev/null | head -1"
  chk "nft 命令已安装"       "[ -x '$LFS/usr/sbin/nft' ]"
  chk "nft 依赖可解析"       "$TOOLS/bin/$TGT-readelf -d '$LFS/usr/sbin/nft' 2>/dev/null | grep -q NEEDED"
  chk "防火墙规则文件存在"   "[ -f '$LFS/etc/nftables.conf' ]"

  echo
  echo "  体积:"
  for f in usr/lib/libmnl.so.0.2.0 usr/lib/libnftnl.so.11.6.0 usr/sbin/nft; do
    [ -f "$LFS/$f" ] && printf '    %-34s %s\n' "$f" "$(du -h "$LFS/$f" | cut -f1)"
  done

  echo
  echo "============================================================"
  printf '  网络工具链门禁: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ nftables 工具链就绪\033[0m\n' || printf '  \033[1;31m✗ 存在问题\033[0m\n'
  echo "============================================================"
  return "$fail"
}

case "${1:-all}" in
  libmnl)   pkg_libmnl ;;
  libnftnl) pkg_libnftnl ;;
  nftables) pkg_nftables ;;
  gate)     do_gate ;;
  all)
    hr "lfOS 网络工具链全量构建"
    pkg_libmnl
    pkg_libnftnl
    pkg_nftables
    do_gate
    ;;
  *) die "未知参数: $1（可用 all|libmnl|libnftnl|nftables|gate）" ;;
esac
