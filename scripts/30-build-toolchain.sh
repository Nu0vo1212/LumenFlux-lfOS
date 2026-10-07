#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 1 - Cross Toolchain (LFS standard sequence)
#  Binutils -> GCC(pass1) -> Linux API Headers -> glibc -> libstdc++ -> GCC(pass2)
#  Usage : bash /opt/lfOS/scripts/30-build-toolchain.sh [stage]
#          stage = all | binutils | gcc1 | headers | glibc | libstdc | gcc2
#  Output: $LFS_TOOLS  (isolated toolchain, mirrors LFS $LFS/tools)
#  Gate  : $LFS_TGT-gcc can build & run a static hello
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS_TOOLS="${LFS_TOOLS:-$LFOS/build/tools}"
LFS_SOURCES="${LFS_SOURCES:-$LFOS/src}"
LFS_LOGS="${LFS_LOGS:-$LFOS/build/logs}"
LFS="${LFS:-$LFOS/build/rootfs}"
JOBS="${LFOS_JOBS:-$(nproc)}"
# 低占用模式：内存密集步骤（glibc / libstdc++ / gcc 终版）用一半并行度，
# 避免 cc1plus/cc1 峰值内存叠加触发 OOM
HEAVY="${LFOS_JOBS_HEAVY:-$(( JOBS > 2 ? JOBS / 2 : 1 ))}"

LFS_TGT="${LFS_TGT:-x86_64-lfos-linux-gnu}"
BINUTILS_VERSION="${BINUTILS_VERSION:-2.44}"
GCC_VERSION="${GCC_VERSION:-14.3.0}"
GLIBC_VERSION="${GLIBC_VERSION:-2.41}"
LINUX_VERSION="${LINUX_VERSION:-6.15.4}"
MPC_VERSION="${MPC_VERSION:-1.4.1}"
MPFR_VERSION="${MPFR_VERSION:-4.2.1}"
GMP_VERSION="${GMP_VERSION:-6.3.0}"

mkdir -p "$LFS_TOOLS" "$LFS_LOGS" "$LFS" "$LFS_SOURCES"
ln -sfn "$LFS_TOOLS" /tools 2>/dev/null || true

export LC_ALL=POSIX
export PATH="$LFS_TOOLS/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset CONFIG_SITE 2>/dev/null || true
unset LD_LIBRARY_PATH 2>/dev/null || true

STEPS_RUN=0
step_start=$(date +%s)

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

extract() { # extract <tarball> -> cd into <name>
  local tb="$1" name="$2"
  [ -s "$LFS_SOURCES/$tb" ] || die "missing source: $LFS_SOURCES/$tb"
  # 幂等：源码已解压过则复用，但仍清理旧的构建目录，保证是干净构建
  if [ -f "$LFS_SOURCES/$name/configure" ] || [ -f "$LFS_SOURCES/$name/Makefile" ]; then
    log "源码已解压，复用: $name"
  else
    tar -xf "$LFS_SOURCES/$tb" -C "$LFS_SOURCES" || die "extract failed: $tb"
    [ -d "$LFS_SOURCES/$name" ] || die "expected dir missing: $LFS_SOURCES/$name"
  fi
  rm -rf "$LFS_SOURCES/$name/build"
  cd "$LFS_SOURCES/$name" || die "cd failed"
}

record_versions() {
  {
    echo "# lfOS Phase 1 cross toolchain - generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "target=$LFS_TGT"
    for t in "$LFS_TGT-gcc" "$LFS_TGT-ld" "$LFS_TGT-as" "$LFS_TGT-strip"; do
      [ -x "$LFS_TOOLS/bin/$t" ] && printf '%s=%s\n' "$t" "$($LFS_TOOLS/bin/$t --version 2>/dev/null | head -1)"
    done
    [ -x "$LFS_TOOLS/bin/$LFS_TGT-gcc" ] && \
      printf 'gcc-dumpversion=%s\n' "$($LFS_TOOLS/bin/$LFS_TGT-gcc -dumpversion)"
    printf 'glibc=%s\n' "$GLIBC_VERSION"
    printf 'tools-size=%s\n' "$(du -sh "$LFS_TOOLS" 2>/dev/null | cut -f1)"
  } > "$LFOS/build/toolchain.versions"
  log "versions recorded -> $LFOS/build/toolchain.versions"
}

# ---------------------------------------------------------------------------
stage_binutils() {
  hr "Stage 1/6  Binutils ${BINUTILS_VERSION} (pass 1)"
  extract "binutils-${BINUTILS_VERSION}.tar.xz" "binutils-${BINUTILS_VERSION}"
  mkdir -v build && cd build
  log "configure"
  ../configure --prefix="$LFS_TOOLS" \
      --with-sysroot="$LFS" --target="$LFS_TGT" \
      --disable-nls --enable-shared --enable-gprofng=no \
      --disable-werror --enable-64-bit-bfd --enable-new-dtags \
      --enable-default-hash-style=gnu \
      > "$LFS_LOGS/binutils-configure.log" 2>&1 || die "binutils configure"
  log "make -j$JOBS"
  make -j"$JOBS" > "$LFS_LOGS/binutils-make.log" 2>&1 || die "binutils make"
  make install > "$LFS_LOGS/binutils-install.log" 2>&1 || die "binutils install"
  log "done: $($LFS_TOOLS/bin/$LFS_TGT-ld --version | head -1)"
  cd "$LFS_SOURCES" && rm -rf "binutils-${BINUTILS_VERSION}"
  STEPS_RUN=$((STEPS_RUN+1))
}

stage_gcc1() {
  hr "Stage 2/6  GCC ${GCC_VERSION} pass 1 (C only)"
  extract "gcc-${GCC_VERSION}.tar.xz" "gcc-${GCC_VERSION}"
  # ---------------------------------------------------------------------
  # GCC 需要 gmp / mpfr / mpc（+可选 isl）。官方做法是 contrib/download_prerequisites，
  # 但它从 gcc.gnu.org 拉取，国内网络会长时间卡住/超时。
  # 策略：优先复用宿主已安装的 -dev 库（等价且更快），仅在国内镜像可用时才下载。
  # ---------------------------------------------------------------------
  local need_prereq=0
  for h in /usr/include/gmp.h /usr/include/x86_64-linux-gnu/gmp.h \
           /usr/include/mpfr.h /usr/include/mpc.h; do
    [ -f "$h" ] || need_prereq=1
  done
  if [ "$need_prereq" -eq 0 ] && [ -d /usr/include/x86_64-linux-gnu ] ; then
    log "检测到宿主已提供 gmp/mpfr/mpc 开发库，跳过 download_prerequisites（避免访问 gcc.gnu.org 卡死）"
    echo "system gmp/mpfr/mpc used; download_prerequisites skipped" > "$LFS_LOGS/gcc-prereq.log"
  else
    log "宿主缺少 gmp/mpfr/mpc 头文件，尝试 download_prerequisites（最多 180 秒）"
    if timeout 180 ./contrib/download_prerequisites > "$LFS_LOGS/gcc-prereq.log" 2>&1; then
      log "download_prerequisites 成功"
    else
      log "download_prerequisites 失败/超时 —— 回退使用系统库"
      echo "download_prerequisites failed; falling back to distro gmp/mpfr/mpc" >> "$LFS_LOGS/gcc-prereq.log"
    fi
  fi
  # 清理半成品下载（避免干扰）
  rm -f "$LFS_SOURCES/gcc-${GCC_VERSION}"/{gmp,mpfr,mpc,isl}-*.tar.* 2>/dev/null || true
  mkdir -p build && cd build
  log "configure"
  ../configure --prefix="$LFS_TOOLS" --with-glibc-version="$GLIBC_VERSION" \
      --with-sysroot="$LFS" --target="$LFS_TGT" --with-newlib \
      --without-headers --enable-initfini-array --disable-nls \
      --disable-shared --disable-multilib --disable-decimal-float \
      --disable-threads --disable-libatomic --disable-libgomp \
      --disable-libquadmath --disable-libssp --disable-libvtv \
      --disable-libstdcxx --enable-languages=c,c++ \
      > "$LFS_LOGS/gcc1-configure.log" 2>&1 || die "gcc1 configure"
  log "make -j$JOBS"
  make -j"$JOBS" > "$LFS_LOGS/gcc1-make.log" 2>&1 || die "gcc1 make"
  make install > "$LFS_LOGS/gcc1-install.log" 2>&1 || die "gcc1 install"
  log "fix limits.h（LFS：把 GCC 的 limits.h 置为固定版本，避免读到宿主头文件）"
  # 注意：必须用文件到文件的重定向；`cat limits.h >> x` 会去读 stdin，
  # 在后台任务里 stdin 指向 /dev/null 会报 "No data available" 并以非零退出。
  local ghdr="$LFS_TOOLS/lib/gcc/$LFS_TGT/${GCC_VERSION}/include"
  if [ -f "$ghdr/limits.h" ]; then
    cp -f "$ghdr/limits.h" "$ghdr/limits.h.orig"
    cp -f "$ghdr/limits.h" "$ghdr/fixed-limits.h"
    cat "$ghdr/limits.h.orig" >> "$ghdr/fixed-limits.h"
    log "limits.h / fixed-limits.h 已生成"
  else
    log "（提示）未找到 $ghdr/limits.h，跳过"
  fi
  cd "$LFS_SOURCES" || true
  cd "$LFS_SOURCES" && rm -rf "gcc-${GCC_VERSION}"
  STEPS_RUN=$((STEPS_RUN+1))
}

stage_headers() {
  hr "Stage 3/6  Linux ${LINUX_VERSION} API Headers"
  extract "linux-${LINUX_VERSION}.tar.xz" "linux-${LINUX_VERSION}"
  log "make headers_install"
  make mrproper > "$LFS_LOGS/headers-mrproper.log" 2>&1
  make headers > "$LFS_LOGS/headers.log" 2>&1 || die "headers_install"
  find usr/include -type f ! -name '*.h' -delete
  mkdir -pv "$LFS/usr"
  cp -rv usr/include "$LFS/usr" >> "$LFS_LOGS/headers.log" 2>&1 || die "copy headers"
  log "done: $(find "$LFS/usr/include" -name '*.h' | wc -l) headers installed"
  cd "$LFS_SOURCES" && rm -rf "linux-${LINUX_VERSION}"
  STEPS_RUN=$((STEPS_RUN+1))
}

stage_glibc() {
  hr "Stage 4/6  glibc ${GLIBC_VERSION}"
  extract "glibc-${GLIBC_VERSION}.tar.xz" "glibc-${GLIBC_VERSION}"
  log "patch / create stub files"
  ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64" 2>/dev/null || true
  ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64/ld-lsb-x86-64.so.3" 2>/dev/null || true
  mkdir -pv build && cd build
  echo "rootsbindir=/usr/sbin" > configparms
  log "configure"
  ../configure --prefix=/usr --host="$LFS_TGT" --build="$(../scripts/config.guess)" \
      --enable-kernel=4.19 --with-headers="$LFS/usr/include" \
      --disable-nscd --disable-werror libc_cv_slibdir=/usr/lib \
      > "$LFS_LOGS/glibc-configure.log" 2>&1 || die "glibc configure"
  log "make -j$JOBS"
  make -j"$HEAVY" > "$LFS_LOGS/glibc-make.log" 2>&1 || die "glibc make"
  log "make install DESTDIR=$LFS"
  make DESTDIR="$LFS" install > "$LFS_LOGS/glibc-install.log" 2>&1 || die "glibc install"
  log "fix loader paths"
  sed -e '/RTLDLIST=/s@/usr@@g' -i "$LFS/usr/bin/ldd"
  log "done: $(ls "$LFS/usr/lib/libc.so.6" 2>/dev/null && echo libc.so.6 OK)"
  cd "$LFS_SOURCES" && rm -rf "glibc-${GLIBC_VERSION}"
  STEPS_RUN=$((STEPS_RUN+1))
}

stage_libstdcxx() {
  hr "Stage 5/6  libstdc++ from GCC ${GCC_VERSION}"
  extract "gcc-${GCC_VERSION}.tar.xz" "gcc-${GCC_VERSION}"
  mkdir -v build && cd build
  log "configure"
  ../libstdc++-v3/configure --host="$LFS_TGT" --build="$(../config.guess)" \
      --prefix=/usr --disable-multilib --disable-nls \
      --disable-libstdcxx-pch \
      --with-gxx-include-dir="/usr/include/c++/${GCC_VERSION%.*}" \
      > "$LFS_LOGS/libstdcxx-configure.log" 2>&1 || die "libstdc++ configure"
  log "make -j$JOBS"
  make -j"$HEAVY" > "$LFS_LOGS/libstdcxx-make.log" 2>&1 || die "libstdc++ make"
  make DESTDIR="$LFS" install > "$LFS_LOGS/libstdcxx-install.log" 2>&1 || die "libstdc++ install"
  cd "$LFS_SOURCES" && rm -rf "gcc-${GCC_VERSION}"
  STEPS_RUN=$((STEPS_RUN+1))
}

stage_gcc2() {
  hr "Stage 6/6  GCC ${GCC_VERSION} pass 2 (full)"
  extract "gcc-${GCC_VERSION}.tar.xz" "gcc-${GCC_VERSION}"
  mkdir -v build && cd build
  log "configure"
  ../configure --prefix="$LFS_TOOLS" --with-sysroot="$LFS" \
      --target="$LFS_TGT" --with-build-sysroot="$LFS" \
      --enable-default-pie --enable-default-ssp \
      --enable-host-pie --enable-cet=auto \
      --disable-nls --disable-multilib --disable-libatomic \
      --disable-libgomp --disable-libquadmath --disable-libsanitizer \
      --disable-libssp --disable-libvtv --enable-languages=c,c++ \
      LDFLAGS_FOR_TARGET="-Wl,-z,now -Wl,-z,relro" \
      > "$LFS_LOGS/gcc2-configure.log" 2>&1 || die "gcc2 configure"
  log "make -j$JOBS"
  make -j"$HEAVY" > "$LFS_LOGS/gcc2-make.log" 2>&1 || die "gcc2 make"
  make install > "$LFS_LOGS/gcc2-install.log" 2>&1 || die "gcc2 install"
  log "done: $($LFS_TOOLS/bin/$LFS_TGT-gcc --version | head -1)"
  cd "$LFS_SOURCES" && rm -rf "gcc-${GCC_VERSION}"
  STEPS_RUN=$((STEPS_RUN+1))
}

gate_phase1() {
  hr "Phase 1 GATE - cross compiler self test"
  local tmpd
  tmpd=$(mktemp -d)
  cat > "$tmpd/hello.c" <<'EOF'
#include <stdio.h>
int main(void){ printf("lfOS cross toolchain OK\n"); return 0; }
EOF
  if "$LFS_TOOLS/bin/$LFS_TGT-gcc" -O2 -o "$tmpd/hello-static" "$tmpd/hello.c" -static \
       > "$LFS_LOGS/gate1-cc.log" 2>&1; then
    if file "$tmpd/hello-static" | grep -qE 'ELF 64-bit.*x86-64'; then
      echo "  [PASS] cross gcc produced an x86-64 ELF (static)"
    else
      echo "  [FAIL] unexpected binary format"; file "$tmpd/hello-static"
    fi
    if command -v qemu-x86_64-static >/dev/null 2>&1; then
      qemu-x86_64-static "$tmpd/hello-static" && echo "  [PASS] runs under qemu-user"
    elif [ "$(uname -m)" = "x86_64" ]; then
      # same-arch host: the static binary should just run
      "$tmpd/hello-static" && echo "  [PASS] static binary runs natively (host arch == target arch)"
    fi
    echo "  [INFO] static hello size: $(stat -c%s "$tmpd/hello-static") bytes"
  else
    echo "  [FAIL] cross gcc failed to compile hello"; tail -20 "$LFS_LOGS/gate1-cc.log"
  fi
  rm -rf "$tmpd"
  echo
  echo "  toolchain size : $(du -sh "$LFS_TOOLS" | cut -f1)"
  echo "  rootfs size    : $(du -sh "$LFS" | cut -f1)"
  echo "  logs           : $LFS_LOGS"
}

# ---------------------------------------------------------------------------
STAGE="${1:-all}"
case "$STAGE" in
  binutils) stage_binutils ;;
  gcc1)     stage_gcc1 ;;
  headers)  stage_headers ;;
  glibc)    stage_glibc ;;
  libstdc)  stage_libstdcxx ;;
  gcc2)     stage_gcc2 ;;
  gate)     gate_phase1 ;;
  all)
    hr "lfOS Phase 1 toolchain build - target $LFS_TGT - jobs $JOBS (heavy steps -j$HEAVY)"
    echo "  tools   : $LFS_TOOLS"
    echo "  sysroot : $LFS"
    echo "  sources : $LFS_SOURCES"
    echo "  低占用模式: 并行度 $JOBS，内存密集步骤 $HEAVY"
    stage_binutils
    stage_gcc1
    stage_headers
    stage_glibc
    stage_libstdcxx
    stage_gcc2
    record_versions
    gate_phase1
    ;;
  *) die "unknown stage: $STAGE (use all|binutils|gcc1|headers|glibc|libstdc|gcc2|gate)" ;;
esac

if [ "$STAGE" != "all" ] && [ "$STAGE" != "gate" ]; then
  record_versions
fi

elapsed=$(( $(date +%s) - step_start ))
printf '\n\033[1;32mPhase 1 step "%s" finished in %dm%02ds\033[0m\n' "$STAGE" $((elapsed/60)) $((elapsed%60))
exit 0
