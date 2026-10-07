#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 2 - 基础系统构建（交叉编译，DESTDIR 安装到 $LFS）
#
#  用法：
#    bash /opt/lfOS/scripts/41-build-base.sh list          # 列出包与状态
#    bash /opt/lfOS/scripts/41-build-base.sh <包名> [...]  # 构建指定包
#    bash /opt/lfOS/scripts/41-build-base.sh all           # 按依赖顺序全量构建
#    bash /opt/lfOS/scripts/41-build-base.sh gate          # 基础系统门禁
#
#  为什么不用 chroot：
#    Phase 2 早期 $LFS 里还没有 shell，无法 chroot。交叉编译本来也不需要
#    chroot —— 用 --host 指定目标架构 + DESTDIR 安装即可。等基础系统齐备后
#    （见 42-enter-chroot.sh）再进 chroot 做「目标机自举」构建。
#
#  产物：$LFS/usr/{bin,sbin,lib} + $LFS/etc
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
LFS_TOOLS="${LFS_TOOLS:-$LFOS/build/tools}"
SRC="${LFS_SOURCES:-$LFOS/src}"
LOGS="${LFS_LOGS:-$LFOS/build/logs}"
TGT="${LFS_TGT:-x86_64-lfos-linux-gnu}"
JOBS="${LFOS_JOBS:-$(nproc)}"

export LC_ALL=C
# 交叉编译环境
export PATH="$LFS_TOOLS/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CC="$TGT-gcc"
export CXX="$TGT-g++"
export AR="$TGT-ar"
export AS="$TGT-as"
export LD="$TGT-ld"
export RANLIB="$TGT-ranlib"
export STRIP="$TGT-strip"
export NM="$TGT-nm"
export CPP="$TGT-cpp"
# 目标 sysroot：头文件与库都在这里
export LFOS_CFLAGS="-O2 -pipe -fstack-protector-strong -fstack-clash-protection -D_FORTIFY_SOURCE=3"
export LFOS_LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,-z,relro -Wl,-z,now"
# 用 pkg-config 时需要隔离宿主路径
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$LFS/usr/lib/pkgconfig:$LFS/usr/share/pkgconfig"
export CONFIG_SITE=/dev/null

mkdir -p "$LOGS"

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 通用解压
# ---------------------------------------------------------------------------
extract_pkg() { # extract_pkg <tarball> <dirname>
  local tb="$1" dir="$2"
  if [ -f "$SRC/$dir/configure" ] || [ -f "$SRC/$dir/Makefile" ] || [ -f "$SRC/$dir/meson.build" ]; then
    log "复用已解压源码 $dir"
  else
    [ -s "$SRC/$tb" ] || die "缺少源码包 $tb（先跑 21-fetch-base-sources.sh）"
    rm -rf "$SRC/$dir"
    tar -xf "$SRC/$tb" -C "$SRC" || die "解压失败 $tb"
  fi
  rm -rf "$SRC/$dir/build"
  cd "$SRC/$dir" || die "cd $SRC/$dir 失败"
}

# 标准 configure 参数（交叉编译 + sysroot）
std_configure() {
  ./configure \
    --prefix=/usr \
    --host="$TGT" \
    --build="$(gcc -dumpmachine)" \
    --disable-static \
    --with-sysroot="$LFS" \
    "$@"
}

# ---------------------------------------------------------------------------
#  安装包装：用 fakeroot 承载 chown / setuid
#
#  背景：util-linux 等包的 install hook 会执行
#      chown root:root ...  且  chmod u+s ...
#  这两个操作对普通用户必然失败（"Operation not permitted"），
#  导致 make install 以错误码退出 —— 即使文件其实已经复制到位。
#
#  fakeroot 通过 LD_PRELOAD 拦截这些系统调用，让它们「看似成功」，
#  同时在退出时记录真实的权限意图。这是 LFS / Debian 打包的标准做法。
#  安装到 $LFS（DESTDIR）时不需要真实 root，fakeroot 即可。
# ---------------------------------------------------------------------------
FAKEROOT_BIN="$(command -v fakeroot 2>/dev/null || true)"

make_install() { # make_install <日志文件>
  local logf="$1"; shift
  if [ -n "$FAKEROOT_BIN" ]; then
    "$FAKEROOT_BIN" -- make DESTDIR="$LFS" install "$@" >> "$logf" 2>&1
  else
    make DESTDIR="$LFS" install "$@" >> "$logf" 2>&1
  fi
}

# 通用构建：configure + make + install
build_std() { # build_std <名> <tarball> <目录> [额外 configure 参数...]
  local name="$1" tb="$2" dir="$3"; shift 3
  hr "构建 $name"
  extract_pkg "$tb" "$dir"
  log "configure"
  if ! std_configure "$@" > "$LOGS/base-$name-configure.log" 2>&1; then
    tail -25 "$LOGS/base-$name-configure.log"; die "$name configure 失败"
  fi
  log "make -j$JOBS"
  if ! make -j"$JOBS" > "$LOGS/base-$name-make.log" 2>&1; then
    grep -nE 'error:|Error [0-9]' "$LOGS/base-$name-make.log" | head -15
    die "$name make 失败"
  fi
  log "make install (DESTDIR=$LFS, fakeroot)"
  make_install "$LOGS/base-$name-install.log" \
    || { tail -20 "$LOGS/base-$name-install.log"; die "$name install 失败"; }
  ok "$name 构建完成"
  cd "$SRC"
}

# ---------------------------------------------------------------------------
# 各包构建
# ---------------------------------------------------------------------------
pkg_zlib() {
  hr "构建 zlib（基础压缩库）"
  extract_pkg zlib-1.3.1.tar.gz zlib-1.3.1
  # zlib 不支持 --host 自动探测跨平台，用 CC 环境变量 + 显式变量
  CHOST="$TGT" ./configure --prefix=/usr --libdir=/usr/lib \
    > "$LOGS/base-zlib-configure.log" 2>&1 || die "zlib configure 失败"
  make -j"$JOBS" > "$LOGS/base-zlib-make.log" 2>&1 || die "zlib make 失败"
  make_install "$LOGS/base-zlib-make.log" || die "zlib install 失败"
  # 静态库保留（很多包需要 libz.a）
  ok "zlib 构建完成"
  cd "$SRC"
}

pkg_ncurses() {
  hr "构建 ncurses（终端库，bash/less 等依赖）"
  extract_pkg ncurses-6.5.tar.gz ncurses-6.5
  # 交叉编译 ncurses 需要先在宿主构建 tic 等工具
  log "两阶段构建：先宿主编译 tic"
  mkdir -p build-host && cd build-host || die "cd 失败"
  ../configure --prefix="$LFS_TOOLS" --without-shared --without-debug \
    AWK=gawk > "$LOGS/base-ncurses-host.log" 2>&1 || die "ncurses host configure 失败"
  make -j"$JOBS" -C include >> "$LOGS/base-ncurses-host.log" 2>&1 || die "ncurses host include 失败"
  make -j"$JOBS" -C progs tic >> "$LOGS/base-ncurses-host.log" 2>&1 || die "ncurses host tic 失败"
  install -m755 progs/tic "$LFS_TOOLS/bin/tic" 2>/dev/null || true
  cd "$SRC/ncurses-6.5" || die "cd 失败"

  log "目标版编译"
  mkdir -p build && cd build || die "cd 失败"
  # --with-termlib：额外生成独立的 libtinfo。
  #   踩过的坑：只加 --enable-widec 时，terminfo 功能被打包进 libncursesw，
  #   不产生独立 libtinfo。而 util-linux 的 ul/colcrt/rev 会链接 -ltinfo，
  #   于是报 "ld: cannot find -ltinfo"。加上 --with-termlib 既生成 libtinfo，
  #   又保留 widec 支持（下方兼容链接仍保留，作为双保险）。
  ../configure --prefix=/usr --host="$TGT" --build="$(gcc -dumpmachine)" \
    --mandir=/usr/share/man \
    --with-shared --without-debug --without-normal --without-ada \
    --enable-widec --with-termlib --enable-pc-files \
    --with-pkg-config-libdir=/usr/lib/pkgconfig \
    > "$LOGS/base-ncurses-configure.log" 2>&1 || die "ncurses configure 失败"
  make -j"$JOBS" > "$LOGS/base-ncurses-make.log" 2>&1 || die "ncurses make 失败"
  make_install "$LOGS/base-ncurses-install.log" || die "ncurses install 失败"

  # 为宽字符库建立兼容链接（很多程序按非 widec 名称查找）
  for lib in ncurses ncurses++ form panel menu; do
    for ext in so a; do
      [ -e "$LFS/usr/lib/lib${lib}w.$ext" ] && \
        ln -sfv "lib${lib}w.$ext" "$LFS/usr/lib/lib${lib}.$ext" 2>/dev/null || true
    done
  done
  ok "ncurses 构建完成"
  cd "$SRC"
}

pkg_readline() {
  hr "构建 readline（bash 依赖）"
  extract_pkg readline-8.2.tar.gz readline-8.2
  # 避免安装旧版 readline 静态库覆盖，并禁止 bash 一起装
  sed -i '/MV.*old/d' Makefile.in 2>/dev/null || true
  sed -i '/{OLDSUFF}/c:' support/shlib-install 2>/dev/null || true
  if ! std_configure --disable-static --with-curses \
        --docdir=/usr/share/doc/readline-8.2 > "$LOGS/base-readline-configure.log" 2>&1; then
    tail -20 "$LOGS/base-readline-configure.log"; die "readline configure 失败"
  fi
  # 交叉编译时 SHLIB_LIBS 需显式指定 ncursesw
  make -j"$JOBS" SHLIB_LIBS="-lncursesw" > "$LOGS/base-readline-make.log" 2>&1 \
    || die "readline make 失败"
  make DESTDIR="$LFS" SHLIB_LIBS="-lncursesw" install >> "$LOGS/base-readline-make.log" 2>&1 \
    || die "readline install 失败"
  ok "readline 构建完成"
  cd "$SRC"
}

pkg_bash() {
  hr "构建 bash（交互 shell 与脚本兼容性）"
  extract_pkg bash-5.2.37.tar.gz bash-5.2.37
  if ! std_configure \
        --without-bash-malloc \
        --with-installed-readline \
        --docdir=/usr/share/doc/bash-5.2.37 \
        > "$LOGS/base-bash-configure.log" 2>&1; then
    tail -20 "$LOGS/base-bash-configure.log"; die "bash configure 失败"
  fi
  make -j"$JOBS" > "$LOGS/base-bash-make.log" 2>&1 || die "bash make 失败"
  make_install "$LOGS/base-bash-install.log" || die "bash install 失败"
  # /bin/sh 指向 bash（POSIX 兼容模式），替换 BusyBox 的 sh
  ln -sfv bash "$LFS/bin/sh"
  ok "bash 构建完成（/bin/sh → bash）"
  cd "$SRC"
}

pkg_coreutils() {
  hr "构建 coreutils（完整 POSIX 语义）"
  extract_pkg coreutils-9.6.tar.xz coreutils-9.6
  # 交叉编译时需提供宿主可运行的辅助程序默认值
  if ! std_configure \
        --enable-install-program=hostname \
        --enable-no-install-program=kill,uptime \
        --disable-libcap \
        > "$LOGS/base-coreutils-configure.log" 2>&1; then
    tail -25 "$LOGS/base-coreutils-configure.log"; die "coreutils configure 失败"
  fi
  make -j"$JOBS" > "$LOGS/base-coreutils-make.log" 2>&1 || die "coreutils make 失败"
  make_install "$LOGS/base-coreutils-install.log" \
    || die "coreutils install 失败"
  # 把 /usr/bin 的基础工具链到 /bin（兼容习惯路径），并覆盖 BusyBox 同名链接
  for p in cat chgrp chmod chown cp dd df echo ln ls mkdir mknod mv rm rmdir \
           stty sync touch true false head tail wc sort uniq cut tr sha256sum; do
    if [ -e "$LFS/usr/bin/$p" ]; then
      ln -sfv "/usr/bin/$p" "$LFS/bin/$p" 2>/dev/null || true
    fi
  done
  ok "coreutils 构建完成"
  cd "$SRC"
}

pkg_util_linux() {
  hr "构建 util-linux（mount/agetty/lsblk 等）"
  extract_pkg util-linux-2.41.tar.xz util-linux-2.41
  if ! std_configure \
        --bindir=/usr/bin \
        --sbindir=/usr/sbin \
        --libdir=/usr/lib \
        --disable-chfn-chsh \
        --disable-login \
        --disable-nologin \
        --disable-su \
        --disable-setpriv \
        --disable-runuser \
        --disable-pylibmount \
        --disable-liblastlog2 \
        --disable-static \
        --without-python \
        ADJTIME_PATH=/var/lib/hwclock/adjtime \
        > "$LOGS/base-util-linux-configure.log" 2>&1; then
    tail -25 "$LOGS/base-util-linux-configure.log"; die "util-linux configure 失败"
  fi
  make -j"$JOBS" > "$LOGS/base-util-linux-make.log" 2>&1 || die "util-linux make 失败"
  make_install "$LOGS/base-util-linux-install.log" \
    || die "util-linux install 失败"
  ok "util-linux 构建完成"
  cd "$SRC"
}

pkg_grep() { build_std grep grep-3.11.tar.xz grep-3.11 --disable-perl-regexp; }
pkg_sed()  { build_std sed  sed-4.9.tar.xz  sed-4.9; }
pkg_gawk() { build_std gawk gawk-5.3.1.tar.xz gawk-5.3.1 --disable-extensions; }
pkg_tar()  { build_std tar  tar-1.35.tar.xz  tar-1.35; }
pkg_gzip() { build_std gzip gzip-1.14.tar.xz gzip-1.14; }

pkg_xz() {
  hr "构建 xz（xz 压缩与 liblzma）"
  extract_pkg xz-5.8.1.tar.xz xz-5.8.1
  if ! std_configure --disable-static --docdir=/usr/share/doc/xz-5.8.1 \
        > "$LOGS/base-xz-configure.log" 2>&1; then
    tail -20 "$LOGS/base-xz-configure.log"; die "xz configure 失败"
  fi
  make -j"$JOBS" > "$LOGS/base-xz-make.log" 2>&1 || die "xz make 失败"
  make_install "$LOGS/base-xz-make.log" || die "xz install 失败"
  ok "xz 构建完成"
  cd "$SRC"
}

pkg_findutils() { build_std findutils findutils-4.10.0.tar.xz findutils-4.10.0 --localstatedir=/var/lib/locate; }
pkg_diffutils() { build_std diffutils diffutils-3.11.tar.xz diffutils-3.11; }

pkg_make() {
  hr "构建 make"
  extract_pkg make-4.4.1.tar.gz make-4.4.1
  if ! std_configure --without-guile > "$LOGS/base-make-configure.log" 2>&1; then
    tail -20 "$LOGS/base-make-configure.log"; die "make configure 失败"
  fi
  make -j"$JOBS" > "$LOGS/base-make-make.log" 2>&1 || die "make 构建失败"
  make_install "$LOGS/base-make-make.log" || die "make install 失败"
  ok "make 构建完成"
  cd "$SRC"
}

pkg_openssl() {
  hr "构建 openssl（TLS 库，openssh 依赖）"
  extract_pkg openssl-3.5.0.tar.gz openssl-3.5.0

  # ---------------------------------------------------------------------
  # 关键教训：不要用 --cross-compile-prefix！
  #
  # openssl 的 target 定义（linux-x86_64）里 CC 已经写成
  #     CC=$(CROSS_COMPILE)x86_64-lfos-linux-gnu-gcc   ← 含完整三元组
  # 若再传 --cross-compile-prefix=x86_64-lfos-linux-gnu-，
  # 展开就变成重复前缀：
  #     x86_64-lfos-linux-gnu-x86_64-lfos-linux-gnu-gcc
  # 该命令不存在 → make 报 Error 127（command not found）。
  #
  # 正确做法：只用环境变量给出完整工具名，openssl 原样采用、不做拼接。
  # ---------------------------------------------------------------------
  log "Configure（用 CC/AR/RANLIB 环境变量，不用 --cross-compile-prefix）"
  if ! CC="$TGT-gcc" CXX="$TGT-g++" AR="$TGT-ar" RANLIB="$TGT-ranlib" \
        NM="$TGT-nm" LD="$TGT-ld" \
        ./Configure linux-x86_64 \
        --prefix=/usr --openssldir=/etc/ssl --libdir=lib \
        shared zlib \
        > "$LOGS/base-openssl-configure.log" 2>&1; then
    tail -20 "$LOGS/base-openssl-configure.log"; die "openssl Configure 失败"
  fi

  # 复核生成的 CC 确实是可调用的完整名字（防前缀重复回归）
  local gen_cc
  gen_cc=$(grep -m1 '^CC=' Makefile | cut -d= -f2-)
  log "生成的 CC: $gen_cc"
  case "$gen_cc" in
    *"$TGT-$TGT"*) die "CC 出现重复前缀（$gen_cc）—— Configure 参数需调整" ;;
  esac

  make -j"$JOBS" > "$LOGS/base-openssl-make.log" 2>&1 || {
    grep -nE 'error:|Error [0-9]|not found' "$LOGS/base-openssl-make.log" | head -10
    die "openssl make 失败"
  }
  make_install "$LOGS/base-openssl-install.log" || die "openssl install 失败"
  ok "openssl 构建完成"
  cd "$SRC"
}

pkg_zlib_extra() { :; }   # 占位

pkg_e2fsprogs() {
  hr "构建 e2fsprogs（mkfs/fsck，持久化根文件系统必需）"
  extract_pkg e2fsprogs-1.47.2.tar.xz e2fsprogs-1.47.2
  mkdir -p build && cd build || die "cd 失败"
  if ! ../configure --prefix=/usr --host="$TGT" --build="$(gcc -dumpmachine)" \
        --with-root-prefix="" --enable-elf-shlibs --disable-uuidd \
        --disable-fsck --disable-libblkid --disable-libuuid --disable-static \
        > "$LOGS/base-e2fsprogs-configure.log" 2>&1; then
    tail -25 "$LOGS/base-e2fsprogs-configure.log"; die "e2fsprogs configure 失败"
  fi
  make -j"$JOBS" > "$LOGS/base-e2fsprogs-make.log" 2>&1 || die "e2fsprogs make 失败"
  make_install "$LOGS/base-e2fsprogs-install.log" \
    || die "e2fsprogs install 失败"
  "$FAKEROOT_BIN" -- make DESTDIR="$LFS" install-libs >> "$LOGS/base-e2fsprogs-install.log" 2>&1 || true
  ok "e2fsprogs 构建完成"
  cd "$SRC"
}

pkg_procps() {
  hr "构建 procps-ng（ps/top/free/sysctl）"
  # 源码包名可能是 procps-ng-4.0.5 或 procps-v4.0.5
  local tb dir
  for cand in "procps-ng-4.0.5.tar.xz:procps-ng-4.0.5" "procps-v4.0.5.tar.xz:procps-ng-4.0.5" "procps-4.0.5.tar.xz:procps-4.0.5"; do
    tb="${cand%%:*}"; dir="${cand##*:}"
    [ -s "$SRC/$tb" ] && break
  done
  [ -s "$SRC/$tb" ] || { log "跳过 procps（源码包未就绪，BusyBox 已提供 ps/free/top）"; return 0; }
  extract_pkg "$tb" "$dir"
  if ! std_configure --disable-static --disable-kill \
        --with-systemd=no --without-ncurses \
        > "$LOGS/base-procps-configure.log" 2>&1; then
    tail -20 "$LOGS/base-procps-configure.log"; log "procps configure 失败，保留 BusyBox 版本"; cd "$SRC"; return 0
  fi
  make -j"$JOBS" > "$LOGS/base-procps-make.log" 2>&1 || { log "procps make 失败，跳过"; cd "$SRC"; return 0; }
  make_install "$LOGS/base-procps-make.log" || true
  ok "procps-ng 构建完成"
  cd "$SRC"
}

pkg_psmisc() {
  hr "构建 psmisc（killall/pstree/fuser）"
  local tb dir
  for cand in "psmisc-23.7.tar.xz:psmisc-23.7" "psmisc-23.7.tar.gz:psmisc-23.7"; do
    tb="${cand%%:*}"; dir="${cand##*:}"
    [ -s "$SRC/$tb" ] && break
  done
  [ -s "$SRC/$tb" ] || { log "跳过 psmisc（源码包未就绪）"; return 0; }
  build_std psmisc "$tb" "$dir" --disable-static
}

pkg_iproute2() {
  hr "构建 iproute2（ip/ss/tc 网络工具）"
  extract_pkg iproute2-6.13.0.tar.xz iproute2-6.13.0
  # iproute2 无 autoconf，用 make 变量指定
  sed -i '/^TC_RTAB_PATH\|^PREFIX\|^SBINDIR\|^CONF_USR_DIR/d' Makefile 2>/dev/null || true
  if ! make -j"$JOBS" \
        CC="$TGT-gcc" AR="$TGT-ar" HOSTCC=gcc \
        PREFIX=/usr SBINDIR=/usr/sbin \
        LIBDIR=/usr/lib \
        > "$LOGS/base-iproute2-make.log" 2>&1; then
    grep -nE 'error:|Error [0-9]' "$LOGS/base-iproute2-make.log" | head -12
    log "iproute2 构建失败，BusyBox 的 ip 仍可用"
    cd "$SRC"; return 0
  fi
  make DESTDIR="$LFS" PREFIX=/usr SBINDIR=/usr/sbin LIBDIR=/usr/lib install \
    >> "$LOGS/base-iproute2-make.log" 2>&1 || true
  ok "iproute2 构建完成"
  cd "$SRC"
}

pkg_shadow() {
  hr "构建 shadow（用户/密码管理）"
  local tb dir
  for cand in "shadow-4.17.3.tar.xz:shadow-4.17.3" "shadow-4.17.2.tar.xz:shadow-4.17.2"; do
    tb="${cand%%:*}"; dir="${cand##*:}"
    [ -s "$SRC/$tb" ] && break
  done
  [ -s "$SRC/$tb" ] || { log "跳过 shadow（源码包未就绪）"; return 0; }
  extract_pkg "$tb" "$dir"
  if ! std_configure --sysconfdir=/etc --disable-static \
        --without-libcrack --without-libpam \
        --disable-account-tools-setuid \
        > "$LOGS/base-shadow-configure.log" 2>&1; then
    tail -20 "$LOGS/base-shadow-configure.log"; log "shadow configure 失败，跳过"; cd "$SRC"; return 0
  fi
  make -j"$JOBS" > "$LOGS/base-shadow-make.log" 2>&1 || { log "shadow make 失败，跳过"; cd "$SRC"; return 0; }
  make DESTDIR="$LFS" exec_prefix=/usr install >> "$LOGS/base-shadow-make.log" 2>&1 || true
  ok "shadow 构建完成"
  cd "$SRC"
}

pkg_openssh() {
  hr "构建 openssh（远程管理，服务器核心组件）"
  local tb dir
  for cand in "openssh-10.0p1.tar.gz:openssh-10.0p1"; do
    tb="${cand%%:*}"; dir="${cand##*:}"
    [ -s "$SRC/$tb" ] && break
  done
  [ -s "$SRC/$tb" ] || { log "跳过 openssh（源码包未就绪）"; return 0; }
  extract_pkg "$tb" "$dir"
  # 需要用目标 sysroot 里的 openssl
  if ! ./configure --prefix=/usr --host="$TGT" --build="$(gcc -dumpmachine)" \
        --sysconfdir=/etc/ssh --with-privsep-path=/var/lib/sshd \
        --with-ssl-dir="$LFS/usr" --with-zlib="$LFS/usr" \
        --with-md5-passwords --with-pam=no --disable-strip \
        > "$LOGS/base-openssh-configure.log" 2>&1; then
    tail -25 "$LOGS/base-openssh-configure.log"
    log "openssh configure 失败（多因 openssl 交叉编译产物不完整），跳过"
    cd "$SRC"; return 0
  fi
  make -j"$JOBS" > "$LOGS/base-openssh-make.log" 2>&1 || { log "openssh make 失败，跳过"; cd "$SRC"; return 0; }
  make_install "$LOGS/base-openssh-make.log" || true
  # 目录与权限（设计方案 Phase 5 要求 root 禁登、密钥优先，配置在安全基线里细调）
  install -v -d -m755 "$LFS/etc/ssh"
  install -v -d -m700 "$LFS/var/lib/sshd" 2>/dev/null || true
  install -v -d -m700 "$LFS/root/.ssh" 2>/dev/null || true
  ok "openssh 构建完成"
  cd "$SRC"
}

pkg_which()  { build_std which which-2.21.tar.gz which-2.21; }

pkg_wget() {
  hr "构建 wget"
  local tb=wget-1.25.0.tar.gz dir=wget-1.25.0
  [ -s "$SRC/$tb" ] || { log "跳过 wget（源码包未就绪）"; return 0; }
  # 显式指定 openssl 的位置。
  # 原因：打包清理阶段删除了 /usr/lib/pkgconfig（.pc 文件），
  # 而 wget 的 configure 依赖 pkg-config 探测 openssl，找不到就直接失败：
  #     Alternatively, you may set the environment variables OPENSSL_CFLAGS
  #     and OPENSSL_LIBS to avoid the need to call pkg-config.
  # 按其提示用环境变量直接给出头文件与库路径即可。
  # --without-libpsl：避免引入 libpsl（Public Suffix List）这一额外依赖。
  export OPENSSL_CFLAGS="-I$LFS/usr/include"
  export OPENSSL_LIBS="-L$LFS/usr/lib -lssl -lcrypto"
  build_std wget "$tb" "$dir" --sysconfdir=/etc --with-ssl=openssl --without-libpsl
  unset OPENSSL_CFLAGS OPENSSL_LIBS
}

# ---------------------------------------------------------------------------
# 包清单（按依赖顺序）
# ---------------------------------------------------------------------------
PKG_ORDER=(
  zlib
  ncurses
  readline
  bash
  coreutils
  util-linux
  grep sed gawk tar gzip xz
  findutils diffutils make which
  e2fsprogs
  procps psmisc
  openssl
  iproute2
  shadow
  openssh
  wget
)

list_pkgs() {
  printf '%-14s %s\n' "包名" "状态"
  printf '%-14s %s\n' "----" "----"
  for p in "${PKG_ORDER[@]}"; do
    local marker=""
    case "$p" in
      bash)        [ -x "$LFS/bin/bash" ] && marker="✓ 已安装" ;;
      coreutils)   [ -x "$LFS/usr/bin/ls" ] && marker="✓ 已安装" ;;
      util-linux)  [ -x "$LFS/usr/bin/mount" ] || [ -x "$LFS/usr/sbin/mount" ] && marker="✓ 已安装" ;;
      zlib)        [ -f "$LFS/usr/lib/libz.so" ] && marker="✓ 已安装" ;;
      ncurses)     ls "$LFS"/usr/lib/libncursesw.so* >/dev/null 2>&1 && marker="✓ 已安装" ;;
      readline)    ls "$LFS"/usr/lib/libreadline.so* >/dev/null 2>&1 && marker="✓ 已安装" ;;
      grep)        [ -x "$LFS/usr/bin/grep" ] && marker="✓ 已安装" ;;
      sed)         [ -x "$LFS/usr/bin/sed" ] && marker="✓ 已安装" ;;
      gawk)        [ -x "$LFS/usr/bin/gawk" ] && marker="✓ 已安装" ;;
      tar)         [ -x "$LFS/usr/bin/tar" ] && marker="✓ 已安装" ;;
      gzip)        [ -x "$LFS/usr/bin/gzip" ] && marker="✓ 已安装" ;;
      xz)          [ -x "$LFS/usr/bin/xz" ] && marker="✓ 已安装" ;;
      openssl)     [ -x "$LFS/usr/bin/openssl" ] && marker="✓ 已安装" ;;
      openssh)     [ -x "$LFS/usr/sbin/sshd" ] && marker="✓ 已安装" ;;
      e2fsprogs)   [ -x "$LFS/usr/sbin/mke2fs" ] || [ -x "$LFS/sbin/mke2fs" ] && marker="✓ 已安装" ;;
      *)           : ;;
    esac
    printf '%-14s %s\n' "$p" "$marker"
  done
}

# ---------------------------------------------------------------------------
# 门禁
# ---------------------------------------------------------------------------
do_gate() {
  hr "Phase 2 基础系统门禁"
  local pass=0 fail=0
  chk() {
    # 临时关闭 pipefail：检查表达式里的 `... | grep -q` 会让上游命令
    # 收到 SIGPIPE（退出码 141），pipefail 会把这次「正常提前退出」误判为失败。
    local rc
    set +o pipefail
    eval "$2" >/dev/null 2>&1
    rc=$?
    set -o pipefail
    if [ "$rc" -eq 0 ]; then
      printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else
      printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1))
    fi
  }

  printf '\n\033[1;33m▶ 一、核心工具（完整实现，非 BusyBox 软链）\033[0m\n'
  # 判定标准：存在且「不是指向 /bin/busybox 的链接」。
  # 注意：像 awk -> gawk 这种指向真实实现的链接是正常且推荐的写法，
  #       不能一律把「符号链接」判为失败（早期版本就踩过这个误报）。
  for t in bash ls cat cp mv rm mkdir mount umount ps awk sed grep tar gzip xz; do
    local p=""
    for d in "$LFS/usr/bin" "$LFS/usr/sbin" "$LFS/bin" "$LFS/sbin"; do
      [ -e "$d/$t" ] && { p="$d/$t"; break; }
    done
    if [ -z "$p" ]; then
      printf '  \033[31m[FAIL]\033[0m %-12s 缺失\n' "$t"; fail=$((fail+1)); continue
    fi
    local tgt; tgt=$(readlink "$p" 2>/dev/null || echo "")
    if [ "$tgt" = "/bin/busybox" ]; then
      printf '  \033[31m[FAIL]\033[0m %-12s 仍是 BusyBox 软链（%s）\n' "$t" "$p"; fail=$((fail+1))
    elif [ -x "$p" ]; then
      printf '  \033[32m[PASS]\033[0m %-12s %s%s\n' "$t" "$p" \
        "$([ -n "$tgt" ] && echo "  (-> $tgt)")"
      pass=$((pass+1))
    else
      printf '  \033[31m[FAIL]\033[0m %-12s 不可执行\n' "$t"; fail=$((fail+1))
    fi
  done

  printf '\n\033[1;33m▶ 二、关键库\033[0m\n'
  # 用显式路径查找代替 eval 拼接：库可能位于 /usr/lib 或 /usr/lib64，
  # 且多为 libX.so → libX.so.N 的软链形式，用 find 一次搞定更可靠。
  findlib() { # findlib <库名模式>
    find "$LFS/usr/lib" "$LFS/usr/lib64" "$LFS/lib" "$LFS/lib64" \
         -maxdepth 1 -name "$1" 2>/dev/null | head -1
  }
  for libspec in "libz.so*:libz" "libncursesw.so*:libncursesw" \
                 "libreadline.so*:libreadline" "libssl.so*:libssl" \
                 "libcrypto.so*:libcrypto" "liblzma.so*:liblzma"; do
    pat="${libspec%%:*}"; name="${libspec##*:}"
    found=$(findlib "$pat")
    if [ -n "$found" ]; then
      printf '  \033[32m[PASS]\033[0m %-16s %s\n' "$name" "$found"; pass=$((pass+1))
    else
      printf '  \033[31m[FAIL]\033[0m %-16s 缺失\n' "$name"; fail=$((fail+1))
    fi
  done
  # 可选库：缺失不影响系统运行，仅提示。
  # SELinux 用户态库属 Phase 5 范畴（内核已支持 CONFIG_SECURITY_SELINUX，
  # 但策略尚未落地），此处不作为门禁失败项。
  for libspec in "libselinux.so*:libselinux" "libcap.so*:libcap"; do
    pat="${libspec%%:*}"; name="${libspec##*:}"
    found=$(findlib "$pat")
    if [ -n "$found" ]; then
      printf '  \033[32m[PASS]\033[0m %-16s %s\n' "$name" "$found"; pass=$((pass+1))
    else
      printf '  \033[33m[SKIP]\033[0m %-16s 未构建（可选，不阻塞）\n' "$name"
    fi
  done

  printf '\n\033[1;33m▶ 三、服务组件\033[0m\n'
  chk "sshd 可执行"     "[ -x '$LFS/usr/sbin/sshd' ]"
  chk "ssh 客户端"      "[ -x '$LFS/usr/bin/ssh' ]"
  chk "mke2fs（建文件系统）" "[ -x '$LFS/usr/sbin/mke2fs' ] || [ -x '$LFS/sbin/mke2fs' ]"
  chk "e2fsck"          "[ -x '$LFS/usr/sbin/e2fsck' ] || [ -x '$LFS/sbin/e2fsck' ]"
  chk "mount（util-linux）" "[ -x '$LFS/usr/bin/mount' ]"
  chk "ip（iproute2）"    "[ -x '$LFS/usr/sbin/ip' ] || [ -x '$LFS/sbin/ip' ]"

  # ------------------------------------------------------------------
  # 依赖完整性：用交叉 readelf 解析关键二进制的 NEEDED，
  # 逐个确认在 rootfs 内可解析 —— 这比「文件存在」更能证明系统可运行。
  # ------------------------------------------------------------------
  printf '\n\033[1;33m▶ 四、动态依赖可解析性（关键二进制）\033[0m\n'
  local READELF="$LFS_TOOLS/bin/$TGT-readelf"
  if [ -x "$READELF" ]; then
    for bin in usr/sbin/sshd usr/bin/bash usr/bin/ls usr/bin/openssl; do
      local bp="$LFS/$bin"
      [ -x "$bp" ] || continue
      local missing=""
      while read -r need; do
        [ -n "$need" ] || continue
        if ! find "$LFS/lib" "$LFS/lib64" "$LFS/usr/lib" "$LFS/usr/lib64" \
                -maxdepth 1 -name "$need" 2>/dev/null | grep -q .; then
          missing="$missing $need"
        fi
      done < <("$READELF" -d "$bp" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
      if [ -z "$missing" ]; then
        printf '  \033[32m[PASS]\033[0m %-20s 依赖全部可解析\n' "$bin"; pass=$((pass+1))
      else
        printf '  \033[31m[FAIL]\033[0m %-20s 缺依赖:%s\n' "$bin" "$missing"; fail=$((fail+1))
      fi
    done
  else
    printf '  \033[33m[SKIP]\033[0m 交叉 readelf 不可用\n'
  fi

  printf '\n\033[1;33m▶ 五、体积统计\033[0m\n'
  local usr_kb usr_mb
  usr_kb=$(du -sk "$LFS" 2>/dev/null | cut -f1)
  usr_mb=$((usr_kb/1024))
  printf '  $LFS 总体积: %d MB\n' "$usr_mb"
  echo "  --- 各目录 ---"
  du -sh "$LFS"/usr/bin "$LFS"/usr/sbin "$LFS"/usr/lib "$LFS"/bin "$LFS"/sbin 2>/dev/null | sed 's/^/    /'

  echo
  echo "============================================================"
  printf '  基础系统门禁: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ Phase 2 基础系统就绪\033[0m\n' \
                    || printf '  \033[1;33m⚠ 部分可选组件缺失，核心系统可用\033[0m\n'
  echo "============================================================"
  return 0
}

# ---------------------------------------------------------------------------
# 包名规范化：用户习惯写 util-linux，而 shell 函数名不能含连字符，
# 统一把 '-' 转成 '_' 再查找 pkg_<name>，避免 "未知包" 这类低级错误。
# ---------------------------------------------------------------------------
norm_name() { printf '%s' "${1//-/_}"; }

run_pkg() {
  local p="$1" fn
  fn="pkg_$(norm_name "$p")"
  if declare -f "$fn" >/dev/null; then
    "$fn"
  else
    die "未知包: $p（用 list 查看可用包）"
  fi
}

case "${1:-all}" in
  list) list_pkgs ;;
  gate) do_gate ;;
  all)
    hr "lfOS Phase 2 基础系统全量构建（交叉编译）"
    echo "  目标 sysroot : $LFS"
    echo "  交叉编译器   : $TGT-gcc"
    echo "  并行度       : -j$JOBS"
    for p in "${PKG_ORDER[@]}"; do
      run_pkg "$p" || log "$p 构建遇阻，继续后续包"
    done
    do_gate
    ;;
  *)
    for p in "$@"; do
      run_pkg "$p"
    done
    ;;
esac
