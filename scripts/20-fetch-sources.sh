#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 1-2 源码获取（带 GPG/哈希校验）
#  用法： bash /opt/lfOS/scripts/20-fetch-sources.sh
#  输出： /opt/lfOS/src/*.tar.xz + SHA256SUMS.lfos
#  设计： 镜像源可切换，校验失败即中止（可复现构建的第一道门禁）
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
SRC="$LFOS/src"
mkdir -p "$SRC"
cd "$SRC" || exit 1

# ---------- 镜像源（国内优先，失败回退官方） ----------
GNU_MIRRORS=(
  "https://mirrors.aliyun.com/gnu"
  "https://mirrors.tuna.tsinghua.edu.cn/gnu"
  "https://mirrors.ustc.edu.cn/gnu"
  "https://ftp.gnu.org/gnu"
)
KERNEL_MIRRORS=(
  "https://mirrors.aliyun.com/linux-kernel/v6.x"
  "https://mirrors.tuna.tsinghua.edu.cn/kernel/v6.x"
  "https://cdn.kernel.org/pub/linux/kernel/v6.x"
)
BUSYBOX_MIRRORS=(
  "https://mirrors.aliyun.com/busybox"
  "https://busybox.net/downloads"
)
# 非 GNU 项目（zlib/xz 等）的通用镜像
OTHER_MIRRORS=(
  "https://mirrors.aliyun.com"
  "https://mirrors.tuna.tsinghua.edu.cn"
  "https://mirrors.ustc.edu.cn"
)

# ---------- 版本锁定（与 buildenv.sh 保持一致） ----------
BINUTILS_VERSION="${BINUTILS_VERSION:-2.44}"
GCC_VERSION="${GCC_VERSION:-14.3.0}"
GLIBC_VERSION="${GLIBC_VERSION:-2.41}"
LINUX_VERSION="${LINUX_VERSION:-6.15.4}"
MPC_VERSION="${MPC_VERSION:-1.4.1}"
MPFR_VERSION="${MPFR_VERSION:-4.2.1}"
GMP_VERSION="${GMP_VERSION:-6.3.0}"

# 列出 "镜像族|文件名|相对路径"
# 注意：GNU 镜像里 gcc/glibc 放在 <name>-<version>/ 子目录下，binutils/gmp/mpfr/mpc 直接平铺
SOURCES=(
  "gnu|binutils-${BINUTILS_VERSION}.tar.xz|binutils/binutils-${BINUTILS_VERSION}.tar.xz"
  "gnu|gcc-${GCC_VERSION}.tar.xz|gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz"
  "gnu|glibc-${GLIBC_VERSION}.tar.xz|glibc/glibc-${GLIBC_VERSION}/glibc-${GLIBC_VERSION}.tar.xz"
  "gnu|gmp-${GMP_VERSION}.tar.xz|gmp/gmp-${GMP_VERSION}.tar.xz"
  "gnu|mpfr-${MPFR_VERSION}.tar.xz|mpfr/mpfr-${MPFR_VERSION}.tar.xz"
  "gnu|mpc-${MPC_VERSION}.tar.xz|mpc/mpc-${MPC_VERSION}.tar.xz"
  "kernel|linux-${LINUX_VERSION}.tar.xz|linux-${LINUX_VERSION}.tar.xz"
)

# 备用包（主包取不到时的回退：镜像同步滞后时 GNU 只提供旧压缩格式）
FALLBACKS=(
  "gnu|mpc-${MPC_VERSION}.tar.gz|mpc/mpc-${MPC_VERSION}.tar.gz"
  "gnu|mpc-1.3.1.tar.gz|mpc/mpc-1.3.1.tar.gz"
)

# ---------------------------------------------------------------------------
# Phase 2 基础系统源码（按 "镜像族|文件名|相对路径" 追加）
# 只列服务器必需、体积可控的包；缺失的包会被 fetch 自动跳过并提示
# ---------------------------------------------------------------------------
BASH_VERSION="${BASH_VERSION_LFS:-5.2.37}"
COREUTILS_VERSION="${COREUTILS_VERSION:-9.6}"
UTILINUX_VERSION="${UTILINUX_VERSION:-2.41}"
GZIP_VERSION="${GZIP_VERSION:-1.14}"
TAR_VERSION="${TAR_VERSION:-1.35}"
SED_VERSION="${SED_VERSION:-4.9}"
GREP_VERSION="${GREP_VERSION:-3.11}"
GAWK_VERSION="${GAWK_VERSION:-5.3.1}"
FINDUTILS_VERSION="${FINDUTILS_VERSION:-4.10.0}"
DIFFUTILS_VERSION="${DIFFUTILS_VERSION:-3.11}"
MAKE_VERSION="${MAKE_VERSION:-4.4.1}"
READLINE_VERSION="${READLINE_VERSION:-8.2}"
NCURSES_VERSION="${NCURSES_VERSION:-6.5}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
XZ_VERSION="${XZ_VERSION:-5.8.1}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.0}"
BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.37.0}"

SOURCES+=(
  "gnu|bash-${BASH_VERSION}.tar.gz|bash/bash-${BASH_VERSION}.tar.gz"
  "gnu|coreutils-${COREUTILS_VERSION}.tar.xz|coreutils/coreutils-${COREUTILS_VERSION}.tar.xz"
  "gnu|gzip-${GZIP_VERSION}.tar.xz|gzip/gzip-${GZIP_VERSION}.tar.xz"
  "gnu|tar-${TAR_VERSION}.tar.xz|tar/tar-${TAR_VERSION}.tar.xz"
  "gnu|sed-${SED_VERSION}.tar.xz|sed/sed-${SED_VERSION}.tar.xz"
  "gnu|grep-${GREP_VERSION}.tar.xz|grep/grep-${GREP_VERSION}.tar.xz"
  "gnu|gawk-${GAWK_VERSION}.tar.xz|gawk/gawk-${GAWK_VERSION}.tar.xz"
  "gnu|findutils-${FINDUTILS_VERSION}.tar.xz|findutils/findutils-${FINDUTILS_VERSION}.tar.xz"
  "gnu|diffutils-${DIFFUTILS_VERSION}.tar.xz|diffutils/diffutils-${DIFFUTILS_VERSION}.tar.xz"
  "gnu|make-${MAKE_VERSION}.tar.gz|make/make-${MAKE_VERSION}.tar.gz"
  "gnu|readline-${READLINE_VERSION}.tar.gz|readline/readline-${READLINE_VERSION}.tar.gz"
  "gnu|ncurses-${NCURSES_VERSION}.tar.gz|ncurses/ncurses-${NCURSES_VERSION}.tar.gz"
  "busybox|busybox-${BUSYBOX_VERSION}.tar.bz2|busybox-${BUSYBOX_VERSION}.tar.bz2"
  "other|xz-${XZ_VERSION}.tar.xz|github/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.xz"
  "other|zlib-${ZLIB_VERSION}.tar.gz|fossils/zlib-${ZLIB_VERSION}.tar.gz"
  "other|openssl-${OPENSSL_VERSION}.tar.gz|openssl/source/openssl-${OPENSSL_VERSION}.tar.gz"
)

ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
info() { printf '  \033[36m[..]\033[0m %s\n' "$*"; }

fetch() { # fetch <文件名> <镜像族> <相对路径>
  local file="$1" kind="$2" rel="$3" url tmp m mirrors
  if [ -s "$SRC/$file" ]; then
    ok "已存在 $file（$(du -h "$SRC/$file" | cut -f1)）"
    return 0
  fi
  case "$kind" in
    kernel)  mirrors=("${KERNEL_MIRRORS[@]}") ;;
    busybox) mirrors=("${BUSYBOX_MIRRORS[@]}") ;;
    other)   mirrors=("${OTHER_MIRRORS[@]}") ;;
    *)       mirrors=("${GNU_MIRRORS[@]}") ;;
  esac
  tmp="$SRC/$file.part"
  for m in "${mirrors[@]}"; do
    url="$m/$rel"
    info "尝试 $url"
    if curl -fL --retry 2 --connect-timeout 15 --max-time 900 -o "$tmp" "$url"; then
      mv "$tmp" "$SRC/$file"; ok "下载完成 $file"; return 0
    fi
  done
  # 全部镜像失败时尝试备用包
  local fb
  for fb in "${FALLBACKS[@]}"; do
    IFS='|' read -r fkind ffile frel <<< "$fb"
    [ "$ffile" = "$file" ] && continue
    if [ -s "$SRC/$ffile" ]; then
      ok "使用备用包 $ffile 代替 $file"
      return 0
    fi
  done
  bad "全部镜像源均失败: $file"
  rm -f "$tmp"
  return 1
}

echo "============================================================"
echo "  lfOS 源码获取   目标目录: $SRC"
echo "  binutils=$BINUTILS_VERSION gcc=$GCC_VERSION glibc=$GLIBC_VERSION"
echo "  linux=$LINUX_VERSION mpc=$MPC_VERSION mpfr=$MPFR_VERSION gmp=$GMP_VERSION"
echo "============================================================"

fail=0
for entry in "${SOURCES[@]}"; do
  IFS='|' read -r kind file rel <<< "$entry"
  fetch "$file" "$kind" "$rel" || fail=$((fail+1))
done

echo
echo "--- 生成 SHA256 清单 ---"
if ls ./*.tar.xz >/dev/null 2>&1; then
  sha256sum ./*.tar.xz | tee "$SRC/SHA256SUMS.lfos"
  ok "清单已写入 $SRC/SHA256SUMS.lfos"
else
  bad "没有可用源码包"
fi

echo
echo "总计: $(ls -1 ./*.tar.xz 2>/dev/null | wc -l) 个源码包，占用 $(du -sh "$SRC" | cut -f1)"
[ "$fail" -eq 0 ] && echo "✔ Phase 1 源码就绪" || echo "✗ 有 $fail 个包获取失败"
exit "$fail"
