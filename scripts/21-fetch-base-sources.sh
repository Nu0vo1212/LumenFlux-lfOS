#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 2 源码获取 —— 基础系统包
#  用法： bash /opt/lfOS/scripts/21-fetch-base-sources.sh
#  输出： /opt/lfOS/src/*.tar.* + SHA256SUMS.base
#
#  选包原则：服务器必需 + 体积可控，不问「能不能装」只问「该不该有」。
#  已有 BusyBox 提供精简工具集，这里补的是「完整实现」与「关键服务」：
#    - bash        : 脚本兼容性（BusyBox ash 无法覆盖所有 shebang）
#    - coreutils   : 完整 POSIX 语义（busybox 版有细微差异）
#    - util-linux  : mount/agetty/lsblk 等系统管理
#    - 文本三件套  : grep/sed/gawk（busybox 版功能受限）
#    - 归档压缩    : tar/gzip/xz
#    - 加密与网络  : openssl/openssh/iproute2/nftables
#    - 文件系统    : e2fsprogs（fsck/mkfs）
#    - 基础库      : zlib/ncurses/readline
# ============================================================================
set -uo pipefail
SRC=/opt/lfOS/src
mkdir -p "$SRC"; cd "$SRC" || exit 1

GNU_MIRRORS=(
  "https://mirrors.aliyun.com/gnu"
  "https://mirrors.tuna.tsinghua.edu.cn/gnu"
  "https://mirrors.ustc.edu.cn/gnu"
  "https://ftp.gnu.org/gnu"
)
KERNEL_MIRRORS=(
  "https://mirrors.aliyun.com/linux-kernel/v6.x"
  "https://mirrors.tuna.tsinghua.edu.cn/kernel/v6.x"
)
# 非 GNU 项目：按「完整 URL 前缀」直接给出候选，避免路径推断出错
OTHER_SOURCES=(
  # util-linux 在 kernel.org
  "util-linux-2.41.tar.xz|https://mirrors.aliyun.com/linux/utils/util-linux/v2.41/util-linux-2.41.tar.xz|https://mirrors.edge.kernel.org/pub/linux/utils/util-linux/v2.41/util-linux-2.41.tar.xz"
  # 下面这些在各自官网/镜像
  "zlib-1.3.1.tar.gz|https://mirrors.aliyun.com/fossils/zlib-1.3.1.tar.gz|https://zlib.net/fossils/zlib-1.3.1.tar.gz"
  "xz-5.8.1.tar.xz|https://mirrors.aliyun.com/github/tukaani-project/xz/releases/download/v5.8.1/xz-5.8.1.tar.xz|https://github.com/tukaani-project/xz/releases/download/v5.8.1/xz-5.8.1.tar.xz"
  "openssl-3.5.0.tar.gz|https://mirrors.aliyun.com/openssl/source/openssl-3.5.0.tar.gz|https://www.openssl.org/source/openssl-3.5.0.tar.gz"
  "openssh-10.0p1.tar.gz|https://mirrors.aliyun.com/pub/OpenBSD/OpenSSH/portable/openssh-10.0p1.tar.gz|https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.0p1.tar.gz"
  "e2fsprogs-1.47.2.tar.xz|https://mirrors.aliyun.com/linux/kernel/people/tytso/e2fsprogs/v1.47.2/e2fsprogs-1.47.2.tar.xz|https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v1.47.2/e2fsprogs-1.47.2.tar.xz"
  "iproute2-6.13.0.tar.xz|https://mirrors.aliyun.com/linux/utils/net/iproute2/iproute2-6.13.0.tar.xz|https://mirrors.edge.kernel.org/pub/linux/utils/net/iproute2/iproute2-6.13.0.tar.xz"
  "nftables-1.1.1.tar.xz|https://mirrors.aliyun.com/netfilter/nftables/nftables-1.1.1.tar.xz|https://www.netfilter.org/pub/nftables/nftables-1.1.1.tar.xz"
  "kmod-34.tar.xz|https://mirrors.aliyun.com/linux/utils/kernel/kmod/kmod-34.tar.xz|https://mirrors.edge.kernel.org/pub/linux/utils/kernel/kmod/kmod-34.tar.xz"
  "shadow-4.17.3.tar.xz|https://mirrors.aliyun.com/github/shadow-maint/shadow/releases/download/4.17.3/shadow-4.17.3.tar.xz|https://github.com/shadow-maint/shadow/releases/download/4.17.3/shadow-4.17.3.tar.xz"
  "procps-ng-4.0.5.tar.xz|https://mirrors.aliyun.com/github/warmchang/procps/releases/download/v4.0.5/procps-ng-4.0.5.tar.xz|https://sourceforge.net/projects/procps-ng/files/Production/procps-ng-4.0.5.tar.xz"
  "psmisc-23.7.tar.xz|https://mirrors.aliyun.com/github/warmchang/psmisc/releases/download/v23.7/psmisc-23.7.tar.xz|https://sourceforge.net/projects/psmisc/files/psmisc/psmisc-23.7.tar.xz"
)

# GNU 包："文件名|路径|可选备用格式"
GNU_SOURCES=(
  "bash-5.2.37.tar.gz|bash/bash-5.2.37.tar.gz|bash-5.2.tar.gz|bash/bash-5.2.tar.gz"
  "coreutils-9.6.tar.xz|coreutils/coreutils-9.6.tar.xz||"
  "grep-3.11.tar.xz|grep/grep-3.11.tar.xz|grep-3.7.tar.xz|grep/grep-3.7.tar.xz"
  "sed-4.9.tar.xz|sed/sed-4.9.tar.xz||"
  "gawk-5.3.1.tar.xz|gawk/gawk-5.3.1.tar.xz||"
  "tar-1.35.tar.xz|tar/tar-1.35.tar.xz||"
  "gzip-1.14.tar.xz|gzip/gzip-1.14.tar.xz|gzip-1.13.tar.xz|gzip/gzip-1.13.tar.xz"
  "findutils-4.10.0.tar.xz|findutils/findutils-4.10.0.tar.xz||"
  "diffutils-3.11.tar.xz|diffutils/diffutils-3.11.tar.xz|diffutils-3.10.tar.xz|diffutils/diffutils-3.10.tar.xz"
  "make-4.4.1.tar.gz|make/make-4.4.1.tar.gz||"
  "readline-8.2.tar.gz|readline/readline-8.2.tar.gz||"
  "ncurses-6.5.tar.gz|ncurses/ncurses-6.5.tar.gz||"
  "wget-1.25.0.tar.gz|wget/wget-1.25.0.tar.gz||"
  "which-2.21.tar.gz|which/which-2.21.tar.gz||"
)

ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
info() { printf '  \033[36m[..]\033[0m %s\n' "$*"; }

fetch_url() { # fetch_url <文件名> <url1> [url2...]
  local file="$1"; shift
  [ -s "$SRC/$file" ] && { ok "已存在 $file ($(du -h "$SRC/$file" | cut -f1))"; return 0; }
  local u tmp="$SRC/$file.part"
  for u in "$@"; do
    [ -z "$u" ] && continue
    info "尝试 $u"
    if curl -fL --retry 1 --connect-timeout 12 --max-time 600 -o "$tmp" "$u" 2>/dev/null; then
      mv "$tmp" "$SRC/$file"; ok "下载完成 $file ($(du -h "$SRC/$file" | cut -f1))"; return 0
    fi
  done
  rm -f "$tmp"
  bad "$file 全部候选 URL 失败"
  return 1
}

echo "============================================================"
echo "  lfOS Phase 2 基础系统源码获取"
echo "============================================================"

fail=0

echo
echo "--- GNU 包 ---"
for entry in "${GNU_SOURCES[@]}"; do
  IFS='|' read -r file rel fb fbrel <<< "$entry"
  urls=()
  for m in "${GNU_MIRRORS[@]}"; do urls+=("$m/$rel"); done
  [ -n "$fb" ] && for m in "${GNU_MIRRORS[@]}"; do urls+=("$m/$fbrel"); done
  fetch_url "$file" "${urls[@]}" || fail=$((fail+1))
done

echo
echo "--- 第三方包 ---"
for entry in "${OTHER_SOURCES[@]}"; do
  IFS='|' read -r file u1 u2 <<< "$entry"
  fetch_url "$file" "$u1" "$u2" || fail=$((fail+1))
done

echo
echo "--- 生成 SHA256 清单 ---"
sha256sum "$SRC"/*.tar.* 2>/dev/null > "$SRC/SHA256SUMS.all"
printf '  共 %s 个源码包，合计 %s\n' \
  "$(ls -1 "$SRC"/*.tar.* 2>/dev/null | wc -l)" \
  "$(du -sh "$SRC" | cut -f1)"

echo
[ "$fail" -eq 0 ] && echo "✔ Phase 2 源码全部就绪" || echo "✗ 有 $fail 个包失败（需调整版本号或镜像）"
exit "$fail"
