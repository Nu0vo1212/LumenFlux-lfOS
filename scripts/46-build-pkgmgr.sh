#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 2f - 包管理系统（libmd / bzip2 / zstd / dpkg）
#
#  dpkg 依赖的实测结论（来自实际 configure 输出，非推测）：
#     checking for po4a >= 0.59... no            ← 缺失但 configure 继续
#     checking for perl >= 5.32.1... /usr/bin/perl ← 用宿主 perl（构建期）
#     checking for md5.h... no
#     configure: error: md5 digest functions not found
#  即：po4a 与 perl **都不是硬依赖**（LFS 的旧 hint 说需要 po4a，那是 2008 年
#  的 dpkg 1.13；现代版本已放宽）。真正的硬依赖只有 libmd。
#
#  另外补充 bzip2 / zstd：dpkg 需要它们才能解压用 bz2/zstd 压缩的 .deb
#  （现代 .deb 多用 xz，liblzma 已有；这两个属于兼容性覆盖）。
#
#  用法： bash /opt/lfOS/scripts/46-build-pkgmgr.sh [all|libmd|bzip2|zstd|dpkg|gate]
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
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$LFS/usr/lib/pkgconfig:$LFS/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$LFS"

mkdir -p "$LOGS"
hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
fake() { command -v fakeroot >/dev/null 2>&1 && echo "fakeroot" || echo ""; }

pkg_libmd() {
  hr "构建 libmd（dpkg 的摘要函数依赖）"
  local d="$SRC/libmd-1.1.0"
  [ -d "$d" ] || { tar -xf "$SRC/libmd-1.1.0.tar.xz" -C "$SRC" 2>/dev/null || die "解压 libmd 失败"; }
  cd "$d" || die "cd 失败"

  if [ ! -f configure ]; then
    log "生成 configure"
    ( ./autogen.sh > "$LOGS/pkg-libmd-autogen.log" 2>&1 ) || true
  fi
  [ -f configure ] || die "libmd 缺少 configure"

  log "configure"
  ./configure --prefix=/usr --host="$TGT" --build="$(gcc -dumpmachine)" \
      --disable-static --sysconfdir=/etc \
      > "$LOGS/pkg-libmd-configure.log" 2>&1 \
    || { tail -20 "$LOGS/pkg-libmd-configure.log"; die "libmd configure 失败"; }

  make -j"$JOBS" > "$LOGS/pkg-libmd-make.log" 2>&1 || {
    grep -nE 'error:|Error [0-9]' "$LOGS/pkg-libmd-make.log" | head -10; die "libmd make 失败"; }
  $(fake) make DESTDIR="$LFS" install >> "$LOGS/pkg-libmd-make.log" 2>&1 \
    || { tail -12 "$LOGS/pkg-libmd-make.log"; die "libmd install 失败"; }
  ok "libmd 构建完成"
  cd "$SRC"
}

pkg_bzip2() {
  hr "构建 bzip2（.deb 的 bz2 压缩支持）"
  local d="$SRC/bzip2-1.0.8"
  [ -d "$d" ] || { tar -xf "$SRC/bzip2-1.0.8.tar.gz" -C "$SRC" 2>/dev/null || die "解压 bzip2 失败"; }
  cd "$d" || die "cd 失败"

  # bzip2 用**手写 Makefile**（非 autotools），因此必须显式传入交叉工具，
  # 否则它会用宿主 gcc 编译出无法在目标机运行的二进制。
  log "编译静态库与共享库（显式指定交叉工具链）"
  make -f Makefile-libbz2_so CC="$CC" AR="$AR" RANLIB="$RANLIB" \
       CFLAGS="-O2 -fPIC -Wall" > "$LOGS/pkg-bzip2-make.log" 2>&1 \
    || { tail -15 "$LOGS/pkg-bzip2-make.log"; die "bzip2 共享库编译失败"; }

  log "安装（手工，bzip2 无 install 目标）"
  mkdir -p "$LFS/usr/lib" "$LFS/usr/bin" "$LFS/usr/include"
  cp -f libbz2.so.1.0.8 "$LFS/usr/lib/" 2>/dev/null || true
  ( cd "$LFS/usr/lib" && ln -sf libbz2.so.1.0.8 libbz2.so.1.0 && ln -sf libbz2.so.1.0 libbz2.so )
  cp -f bzlib.h "$LFS/usr/include/" 2>/dev/null || true
  for b in bzip2 bunzip2 bzcat bzip2recover; do
    [ -f "$b" ] && cp -f "$b" "$LFS/usr/bin/" 2>/dev/null || true
  done
  ( cd "$LFS/usr/bin" && ln -sf bzip2 bunzip2 2>/dev/null; ln -sf bzip2 bzcat 2>/dev/null )
  ok "bzip2 构建完成"
  cd "$SRC"
}

pkg_zstd() {
  hr "构建 zstd（.deb 的 zstd 压缩支持）"
  local d="$SRC/zstd-1.5.6"
  [ -d "$d" ] || { tar -xf "$SRC/zstd-1.5.6.tar.gz" -C "$SRC" 2>/dev/null || die "解压 zstd 失败"; }
  cd "$d" || die "cd 失败"

  # zstd 同样使用手写 Makefile
  log "编译（显式指定交叉工具链）"
  make -j"$JOBS" CC="$CC" AR="$AR" RANLIB="$RANLIB" \
       > "$LOGS/pkg-zstd-make.log" 2>&1 \
    || { grep -nE 'error:|Error [0-9]' "$LOGS/pkg-zstd-make.log" | head -10; die "zstd make 失败"; }

  log "安装"
  make DESTDIR="$LFS" PREFIX=/usr install >> "$LOGS/pkg-zstd-make.log" 2>&1 \
    || { tail -12 "$LOGS/pkg-zstd-make.log"; die "zstd install 失败"; }
  ok "zstd 构建完成"
  cd "$SRC"
}

pkg_dpkg() {
  hr "构建 dpkg（.deb 包管理器）"
  local d="$SRC/dpkg-1.22.22"
  [ -d "$d" ] || { tar -xf "$SRC/dpkg_1.22.22.tar.xz" -C "$SRC" 2>/dev/null || die "解压 dpkg 失败"; }
  cd "$d" || die "cd 失败"

  # 选项依据实测 configure 结果：
  #   --disable-nls          不启用本地化（避开 gettext 依赖）
  #   --disable-dselect      不构建 dselect（无需 ncurses/c++ 界面）
  #   --disable-start-stop-daemon   该程序是 Debian init 脚本用的，lfOS 用自己的 init
  #   --disable-update-alternatives 同上，且需要更多依赖
  #   --without-selinux      lfOS 暂无 SELinux 用户态策略
  # 刻意**不加** --without-libmd 等：libmd/zlib/lzma 已就绪，让它们生效。
  log "configure"
  if ! ./configure --prefix=/usr --host="$TGT" --build="$(gcc -dumpmachine)" \
        --sysconfdir=/etc --localstatedir=/var \
        --disable-nls --disable-dselect \
        --disable-start-stop-daemon --disable-update-alternatives \
        --without-selinux \
        > "$LOGS/pkg-dpkg-configure.log" 2>&1; then
    tail -25 "$LOGS/pkg-dpkg-configure.log"; die "dpkg configure 失败"
  fi

  # 记录实际启用的系统库（便于确认哪些压缩格式可用）
  log "配置摘要（关键能力）"
  grep -E 'libmd|libz|liblzma|libzstd|libbz2|libselinux|nls|dselect' \
    "$LOGS/pkg-dpkg-configure.log" | tail -12 | sed 's/^/       /'

  log "make -j$JOBS"
  if ! make -j"$JOBS" > "$LOGS/pkg-dpkg-make.log" 2>&1; then
    grep -nE 'error:|Error [0-9]|cannot find' "$LOGS/pkg-dpkg-make.log" | head -12
    die "dpkg make 失败"
  fi

  log "install"
  $(fake) make DESTDIR="$LFS" install >> "$LOGS/pkg-dpkg-make.log" 2>&1 \
    || { tail -15 "$LOGS/pkg-dpkg-make.log"; die "dpkg install 失败"; }

  # dpkg 的数据库目录必须存在
  mkdir -p "$LFS/var/lib/dpkg/updates" "$LFS/var/lib/dpkg/info" \
           "$LFS/var/lib/dpkg/triggers" "$LFS/var/lib/dpkg/alternatives" \
           "$LFS/var/log" "$LFS/etc/dpkg/dpkg.cfg.d"
  [ -f "$LFS/var/lib/dpkg/status" ] || : > "$LFS/var/lib/dpkg/status"
  [ -f "$LFS/var/lib/dpkg/available" ] || : > "$LFS/var/lib/dpkg/available"
  ok "dpkg 构建完成"
  cd "$SRC"
}

do_gate() {
  hr "包管理系统门禁"
  local pass=0 fail=0
  chk() {
    local rc; set +o pipefail; eval "$2" >/dev/null 2>&1; rc=$?; set -o pipefail
    if [ "$rc" -eq 0 ]; then printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); fi
  }
  chk "libmd.so 已安装"      "ls '$LFS'/usr/lib/libmd.so* 2>/dev/null | head -1"
  chk "libbz2.so 已安装"     "ls '$LFS'/usr/lib/libbz2.so* 2>/dev/null | head -1"
  chk "libzstd.so 已安装"    "ls '$LFS'/usr/lib/libzstd.so* 2>/dev/null | head -1"
  chk "dpkg 命令可执行"      "[ -x '$LFS/usr/bin/dpkg' ]"
  chk "dpkg-deb 命令可执行"  "[ -x '$LFS/usr/bin/dpkg-deb' ]"
  chk "dpkg 数据库目录存在"  "[ -d '$LFS/var/lib/dpkg' ]"
  chk "status 文件存在"      "[ -f '$LFS/var/lib/dpkg/status' ]"

  echo
  echo "  关键文件:"
  for f in usr/bin/dpkg usr/bin/dpkg-deb usr/bin/dpkg-query usr/bin/dpkg-split \
           usr/lib/libmd.so.0 usr/lib/libbz2.so.1.0 usr/lib/libzstd.so.1; do
    [ -e "$LFS/$f" ] && printf '    %-32s %s\n' "$f" "$(du -h "$LFS/$f" 2>/dev/null | cut -f1)"
  done

  echo
  echo "============================================================"
  printf '  包管理门禁: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ dpkg 就绪\033[0m\n' || printf '  \033[1;31m✗ 存在问题\033[0m\n'
  echo "============================================================"
  return "$fail"
}

case "${1:-all}" in
  libmd)  pkg_libmd ;;
  bzip2)  pkg_bzip2 ;;
  zstd)   pkg_zstd ;;
  dpkg)   pkg_dpkg ;;
  gate)   do_gate ;;
  all) hr "lfOS 包管理系统构建"; pkg_libmd; pkg_bzip2; pkg_zstd; pkg_dpkg; do_gate ;;
  *) die "未知参数: $1（可用 all|libmd|bzip2|zstd|dpkg|gate）" ;;
esac
