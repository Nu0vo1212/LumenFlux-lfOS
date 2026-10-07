#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 2d - 认证与用户管理（libxcrypt + shadow）
#
#  背景（实测查证，非推测）：
#    shadow 的 configure 报错：
#        checking for crypt in -lcrypt... no
#        configure: error: crypt() not found
#    进一步实测 lfOS 的 glibc：
#        libc.so.6 中的 crypt 符号数: 0
#    即 glibc 2.28 起已把 crypt 系列移出，改由 libxcrypt 提供。
#    因此必须先编译 libxcrypt，shadow 才能构建。
#
#  产出：
#    libcrypt.so.1   → 提供 crypt()/crypt_r()/crypt_gensalt()
#    useradd/userdel/usermod/passwd/chage/groupadd/... → 完整的用户管理
#
#  用法： bash /opt/lfOS/scripts/43-build-auth.sh [all|libxcrypt|shadow|gate]
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

pkg_libxcrypt() {
  hr "构建 libxcrypt（crypt 实现）"
  local d="$SRC/libxcrypt-4.5.1"
  [ -d "$d" ] || die "缺少 libxcrypt 源码（先解压 libxcrypt_4.5.1.orig.tar.xz）"

  # Debian 的 orig.tar.xz 不含生成的 configure，需要 autoreconf。
  # 注意：autoreconf 可能因 libtool 宏问题在最后阶段报错，但 configure
  # 通常已经写出且可用 —— 所以这里不把 autoreconf 的退出码当致命错误，
  # 而是**实际运行 configure 来验证**（以事实为准，不以中间步骤的返回码为准）。
  if [ ! -f "$d/configure" ]; then
    log "生成 configure（autoreconf）"
    ( cd "$d" && ./autogen.sh > "$LOGS/auth-libxcrypt-autogen.log" 2>&1 ) || \
      log "autoreconf 有告警（继续，稍后用 configure 实际验证）"
  fi
  [ -f "$d/configure" ] || die "configure 生成失败"

  cd "$d" || die "cd 失败"
  log "configure（交叉编译）"
  # --disable-werror：避免上游的严格警告策略把构建卡住
  # --enable-hashes=strong,glibc：覆盖常见的强哈希（sha512/yescrypt）与
  #                              glibc 兼容算法，确保 shadow 的默认设置可用
  if ! ./configure --prefix=/usr --host="$TGT" --build="$(gcc -dumpmachine)" \
        --disable-static --disable-werror \
        --enable-hashes=strong,glibc \
        > "$LOGS/auth-libxcrypt-configure.log" 2>&1; then
    tail -25 "$LOGS/auth-libxcrypt-configure.log"; die "libxcrypt configure 失败"
  fi
  log "make -j$JOBS"
  if ! make -j"$JOBS" > "$LOGS/auth-libxcrypt-make.log" 2>&1; then
    grep -nE 'error:|Error [0-9]' "$LOGS/auth-libxcrypt-make.log" | head -12
    die "libxcrypt make 失败"
  fi
  local FK=""; command -v fakeroot >/dev/null 2>&1 && FK="fakeroot"
  $FK make DESTDIR="$LFS" install >> "$LOGS/auth-libxcrypt-make.log" 2>&1 \
    || { tail -15 "$LOGS/auth-libxcrypt-make.log"; die "libxcrypt install 失败"; }
  ok "libxcrypt 构建完成"
  cd "$SRC"
}

pkg_shadow() {
  hr "构建 shadow（用户管理）"
  local d="$SRC/shadow-4.17.3"
  if [ ! -d "$d" ]; then
    tar -xf "$SRC/shadow-4.17.3.tar.xz" -C "$SRC" 2>/dev/null || die "解压 shadow 失败"
  fi
  cd "$d" || die "cd 失败"

  # 先确认 libcrypt 已在 sysroot 中就绪（这是上次失败的直接原因）
  if ! ls "$LFS"/usr/lib/libcrypt.so* >/dev/null 2>&1; then
    die "sysroot 里没有 libcrypt.so —— 请先构建 libxcrypt"
  fi

  log "configure（交叉编译）"
  # 依实测 configure 输出与源码查证确定的选项组合：
  #   --without-libpam       不引入 PAM（保持最小依赖；lfOS 的 sshd 也是 --with-pam=no）
  #   --without-libcrack     不需要 cracklib 口令强度检查
  #   --without-libbsd       使用 shadow 自带的 readpassphrase 实现
  #   --disable-account-tools-setuid  不设 setuid（避免 fakeroot 下的权限语义问题）
  #   --with-group-name-max-length=32 组名上限（与常见发行版一致）
  #
  #  为什么可以 --without-libbsd（读源码查证，非推测）：
  #    shadow 的 configure.ac 逻辑是
  #        if test "$with_libbsd" != "no"; then
  #            AC_SEARCH_LIBS([readpassphrase], [bsd], [], [AC_MSG_ERROR(...)])
  #        else
  #            AC_DEFINE(WITH_LIBBSD, 0, ...)
  #        fi
  #    且源码中自带 lib/readpassphrase.c 与 lib/readpassphrase.h。
  #    也就是说关掉 libbsd 后会编译自带的实现，功能不缺失，
  #    同时少引入一个外部库（符合低占用宗旨）。
  if ! ./configure --prefix=/usr --host="$TGT" --build="$(gcc -dumpmachine)" \
        --sysconfdir=/etc --disable-static \
        --without-libpam --without-libcrack --without-libbsd \
        --disable-account-tools-setuid \
        --with-group-name-max-length=32 \
        > "$LOGS/auth-shadow-configure.log" 2>&1; then
    tail -25 "$LOGS/auth-shadow-configure.log"; die "shadow configure 失败"
  fi
  log "make -j$JOBS"
  if ! make -j"$JOBS" > "$LOGS/auth-shadow-make.log" 2>&1; then
    grep -nE 'error:|Error [0-9]' "$LOGS/auth-shadow-make.log" | head -12
    die "shadow make 失败"
  fi
  local FK=""; command -v fakeroot >/dev/null 2>&1 && FK="fakeroot"
  $FK make DESTDIR="$LFS" exec_prefix=/usr install >> "$LOGS/auth-shadow-make.log" 2>&1 \
    || { tail -15 "$LOGS/auth-shadow-make.log"; die "shadow install 失败"; }
  ok "shadow 构建完成"
  cd "$SRC"
}

do_gate() {
  hr "认证与用户管理门禁"
  local pass=0 fail=0
  chk() {
    local rc; set +o pipefail; eval "$2" >/dev/null 2>&1; rc=$?; set -o pipefail
    if [ "$rc" -eq 0 ]; then printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); fi
  }
  chk "libcrypt.so 已安装"   "ls '$LFS'/usr/lib/libcrypt.so* 2>/dev/null | head -1"
  chk "libcrypt 含 crypt 符号" "$TOOLS/bin/$TGT-nm -D '$LFS'/usr/lib/libcrypt.so.1 2>/dev/null | grep -q ' T crypt'"
  for t in useradd usermod userdel passwd chage groupadd groupmod groupdel; do
    chk "$t 可用" "[ -x '$LFS/usr/sbin/$t' ] || [ -x '$LFS/usr/bin/$t' ]"
  done
  chk "login 程序"           "[ -x '$LFS/usr/bin/login' ] || [ -x '$LFS/bin/login' ]"
  chk "su 程序"              "[ -x '$LFS/usr/bin/su' ] || [ -x '$LFS/bin/su' ]"

  echo
  echo "  关键文件:"
  for f in usr/lib/libcrypt.so.1 usr/sbin/useradd usr/bin/passwd usr/bin/su; do
    [ -e "$LFS/$f" ] && printf '    %-28s %s\n' "$f" "$(du -h "$LFS/$f" 2>/dev/null | cut -f1)"
  done

  echo
  echo "============================================================"
  printf '  认证门禁: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ 用户管理就绪\033[0m\n' || printf '  \033[1;31m✗ 存在问题\033[0m\n'
  echo "============================================================"
  return "$fail"
}

case "${1:-all}" in
  libxcrypt) pkg_libxcrypt ;;
  shadow)    pkg_shadow ;;
  gate)      do_gate ;;
  all) hr "lfOS 认证与用户管理构建"; pkg_libxcrypt; pkg_shadow; do_gate ;;
  *) die "未知参数: $1（可用 all|libxcrypt|shadow|gate）" ;;
esac
