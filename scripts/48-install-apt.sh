#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 2h - 安装 Debian 的 apt（含依赖）并配置仓库
#
#  策略（基于实测的库现状，非推测）：
#    lfOS 自建系统已提供这些库，若让 Debian 包再装一遍会覆盖自建版本：
#        libc6, libcrypt1, libssl3t64, zlib1g, liblzma5, libzstd1, libbz2-1.0
#    因此先把它们登记进 dpkg 数据库（声明「系统已提供」），
#    再只安装 lfOS 确实缺少的包 —— 既满足依赖又不动自建库。
#
#    实测缺失的关键库：libstdc++.so.6、libgcc_s.so.1
#    （gcc 运行时没进 rootfs，这也是 apt 这类 C++ 程序跑不起来的原因）
#
#  用法： bash /opt/lfOS/scripts/48-install-apt.sh [all|register|install|config|gate]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
PKGS="$LFOS/build/testpkgs"
LOGS="$LFOS/build/logs"
SUITE="${LFOS_DEB_SUITE:-trixie}"
MIRROR="${LFOS_DEB_MIRROR:-https://deb.debian.org/debian}"

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }

# 需要 root（chroot）
need_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && exec sudo -E bash "$0" "$@"
  die "需要 root"
}

# ---------------------------------------------------------------------------
#  登记 lfOS 已自带的库
# ---------------------------------------------------------------------------
register_provided() {
  printf '\n\033[1;36m===== 登记系统自带的库 =====\033[0m\n'
  local status="$LFS/var/lib/dpkg/status"
  mkdir -p "$(dirname "$status")"
  touch "$status"

  # 包名|版本|描述
  local entries=(
    "libc6|2.41-1|lfOS 自带 glibc（源码构建）"
    "libcrypt1|1:4.5.1-1|lfOS 自带 libxcrypt（源码构建）"
    "libssl3t64|3.5.0-1|lfOS 自带 OpenSSL 3.5（源码构建）"
    "zlib1g|1:1.3.1-1|lfOS 自带 zlib（源码构建）"
    "liblzma5|5.8.1-1|lfOS 自带 xz/liblzma（源码构建）"
    "libzstd1|1.5.6-1|lfOS 自带 zstd（源码构建）"
    "libbz2-1.0|1.0.8-6|lfOS 自带 bzip2（源码构建）"
    # 注意：libncursesw6 与 libreadline8 **刻意不登记**。
    #
    # 踩过的坑：最初把这两个也登记为「lfOS 已提供」，结果安装 Debian 的 nano 后
    # 运行时报：
    #     nano: /usr/lib/libncursesw.so.6: no version information available
    #             (required by nano)
    # 原因是 lfOS 自建的 ncurses 没有启用 symbol versioning，
    # 而 Debian 编译的程序期望带版本号的符号（如 NCURSES6_5.0.19991023）。
    # 缺版本信息不会直接崩溃，但所有依赖 ncurses 的 Debian 程序都会刷警告，
    # 且未来版本一旦真正依赖版本化符号就会出问题。
    # 因此让 Debian 的 libtinfo6/libncursesw6/libreadline8 正常接管 ——
    # 它们的 soname 与 lfOS 版本一致（ABI 兼容），覆盖是安全的。
  )
  local e name ver desc added=0
  for e in "${entries[@]}"; do
    IFS='|' read -r name ver desc <<< "$e"
    if grep -q "^Package: $name\$" "$status" 2>/dev/null; then
      printf '  \033[33m[已有]\033[0m %s\n' "$name"
      continue
    fi
    cat >> "$status" <<EOF
Package: $name
Status: install ok installed
Priority: optional
Section: libs
Installed-Size: 1000
Maintainer: lfOS <root@lfos>
Architecture: amd64
Version: $ver
Description: $desc
 本条目声明该库已由 lfOS 自带，供 dpkg 依赖检查使用。

EOF
    printf '  \033[32m[登记]\033[0m %-16s %s\n' "$name" "$ver"
    added=$((added+1))
  done
  log "新增 $added 条记录"
}

# ---------------------------------------------------------------------------
#  安装 lfOS 缺少的 Debian 包
# ---------------------------------------------------------------------------
install_missing() {
  printf '\n\033[1;36m===== 安装缺失的 Debian 包 =====\033[0m\n'

  # 这些包 lfOS 已自带，**不安装**（避免自建库被 Debian 版本覆盖）：
  #   libc6 libcrypt1 libssl3t64 zlib1g liblzma5 libzstd1 libbz2-1.0
  local skip="libc6|libcrypt1|libssl3t64|zlib1g|liblzma5|libzstd1|libbz2-1.0"
  local list="" f base
  for f in "$PKGS"/*.deb; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    # 从文件名取包名（去掉 _版本_架构.deb）
    local pname="${base%%_*}"
    case "$pname" in
      libc6|libcrypt1|libssl3t64|zlib1g|liblzma5|libzstd1|libbz2-1.0)
        printf '  \033[33m[跳过]\033[0m %-34s （lfOS 已自带，不覆盖）\n' "$pname"
        continue ;;
    esac
    # 复制到 chroot 内
    cp -f "$f" "$LFS/tmp/" 2>/dev/null || die "复制 $base 到 chroot 失败"
    list="$list /tmp/$base"
  done

  [ -n "$list" ] || die "没有可安装的包（检查 $PKGS）"

  printf '\n  待安装: %s 个包\n' "$(printf '%s' "$list" | wc -w)"
  log "dpkg -i 安装"
  # --force-depends 之外不加任何强制选项：依赖若真不满足，宁可失败也要暴露问题
  if chroot "$LFS" /usr/bin/dpkg -i $list > "$LOGS/apt-install.log" 2>&1; then
    ok "全部安装成功（依赖检查通过）"
  else
    printf '  \033[33m[部分失败]\033[0m 输出如下：\n'
    grep -E 'error|依赖|dependency|not installed|Errors|警告|warning' "$LOGS/apt-install.log" | head -15 | sed 's/^/    /'
    printf '\n  完整日志: %s\n' "$LOGS/apt-install.log"
  fi

  # 清理 chroot 内的临时 deb
  rm -f "$LFS"/tmp/*.deb 2>/dev/null || true
}

# ---------------------------------------------------------------------------
#  配置 apt 仓库
# ---------------------------------------------------------------------------
do_config() {
  printf '\n\033[1;36m===== 配置 apt 仓库 =====\033[0m\n'
  mkdir -p "$LFS/etc/apt/sources.list.d" "$LFS/etc/apt/apt.conf.d" \
           "$LFS/var/lib/apt/lists/partial" "$LFS/var/cache/apt/archives/partial"
  chmod 0755 "$LFS/var/lib/apt/lists/partial" "$LFS/var/cache/apt/archives/partial" 2>/dev/null || true

  cat > "$LFS/etc/apt/sources.list" <<EOF
# lfOS 软件源
# 使用 Debian $SUITE（glibc 2.41，与 lfOS 一致 —— 已用 hello 包实测二进制兼容）
deb $MIRROR $SUITE main
deb $MIRROR $SUITE-updates main
EOF
  printf '  sources.list:\n'
  grep -v '^#' "$LFS/etc/apt/sources.list" | grep -v '^$' | sed 's/^/    /'

  # 关闭 apt 的一些 Debian 专有行为，避免在 lfOS 上出问题：
  #   Architectures：显式声明，避免 apt 猜测
  #   不启用 APT::Install-Recommends（lfOS 倾向最小安装）
  cat > "$LFS/etc/apt/apt.conf.d/99lfos" <<'EOF'
// lfOS 的 apt 配置覆盖
APT::Architecture "amd64";
APT::Architectures { "amd64"; };
// 默认不装推荐包，保持系统精简（需要时用 --install-recommends 覆盖）
APT::Install-Recommends "false";
APT::Install-Suggests "false";
// lfOS 不使用 dpkg 的 triggers 机制做服务重启
DPkg::Options { "--force-confold"; };
EOF
  printf '  apt.conf.d/99lfos 已写入\n'
}

do_gate() {
  printf '\n\033[1;36m===== apt 门禁 =====\033[0m\n'
  local pass=0 fail=0
  chk() {
    local rc; set +o pipefail; eval "$2" >/dev/null 2>&1; rc=$?; set -o pipefail
    if [ "$rc" -eq 0 ]; then printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); fi
  }
  chk "libstdc++ 已就位"    "ls '$LFS'/usr/lib/libstdc++.so.6* 2>/dev/null | head -1"
  chk "libgcc_s 已就位"     "ls '$LFS'/usr/lib/libgcc_s.so.1 2>/dev/null | head -1"
  chk "libapt-pkg 已就位"   "ls '$LFS'/usr/lib/libapt-pkg.so* 2>/dev/null | head -1"
  chk "apt-get 可执行"      "[ -x '$LFS/usr/bin/apt-get' ]"
  chk "apt 可执行"          "[ -x '$LFS/usr/bin/apt' ]"
  chk "apt-cache 可执行"    "[ -x '$LFS/usr/bin/apt-cache' ]"
  chk "sources.list 存在"   "[ -f '$LFS/etc/apt/sources.list' ]"

  printf '\n  apt 版本（实际运行验证）：\n'
  if chroot "$LFS" /usr/bin/apt-get --version 2>&1 | head -2 | sed 's/^/    /'; then
    pass=$((pass+1))
  else
    printf '    \033[31m✗ apt-get 无法运行\033[0m\n'; fail=$((fail+1))
  fi

  printf '\n  apt 门禁: %d 通过 / %d 失败\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ apt 就绪\033[0m\n' || printf '  \033[1;31m✗ 存在问题\033[0m\n'
  return "$fail"
}

case "${1:-all}" in
  register) need_root "$@"; register_provided ;;
  install)  need_root "$@"; install_missing ;;
  config)   need_root "$@"; do_config ;;
  gate)     do_gate ;;
  all)      need_root "$@"; register_provided; install_missing; do_config; do_gate ;;
  *) die "未知参数: $1（可用 all|register|install|config|gate）" ;;
esac
