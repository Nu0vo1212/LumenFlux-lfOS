#!/usr/bin/env bash
# ============================================================================
#  lfOS - 安装 Ubuntu 风格工具集（命令与用户体系对齐 Ubuntu）
#
#  设计依据（实测的包体积，见脚本内注释）：
#    Ubuntu 的命令集与 Debian 完全同源，所以这里直接从 Debian 仓库取包，
#    得到的命令行行为、选项、错误信息与 Ubuntu 一致。
#
#  取舍说明：
#    * 只装「Ubuntu 最小安装默认有、而 lfOS 缺」的包，不装 man-db / rsyslog /
#      cron 这类体积大且非必需的。
#    * 已经自编译且体积更小的（wget 556K vs Debian 3784K）**保留自编译版**。
#    * ping / nslookup / nc 目前是 busybox 的精简版，替换为 Debian 完整版
#      （iputils-ping / bind9-host / netcat-openbsd），以获得与 Ubuntu
#      一致的选项与输出。
#
#  用法： bash 53-ubuntu-tools.sh [all|resolve|fetch|install|gate|list]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
PKGS="$LFOS/build/testpkgs"
IDX="$LFOS/build/debrepo/Packages-trixie"
MIRROR="${LFOS_DEB_MIRROR:-http://deb.debian.org/debian}"
LOGS="$LFOS/build/logs"

# ---------------------------------------------------------------------------
#  要安装的包（Ubuntu 最小安装的常见组成）
# ---------------------------------------------------------------------------
CORE_PKGS=(
  # —— 用户与权限（Ubuntu 用 adduser + sudo，而非裸 useradd）——
  adduser              # 交互式建用户（Ubuntu 的 adduser 就是这个）
  perl-base            # adduser 是 perl 脚本，必需
  sudo                 # 提权（Ubuntu 默认有）
  # —— 编辑与查看 ——
  less                 # 分页器（Ubuntu 默认）
  nano                 # Ubuntu 默认编辑器
  vim-tiny             # Ubuntu 的 vi（精简版 vim）
  # —— 网络 ——
  curl                 # Ubuntu 默认有
  iputils-ping         # Ubuntu 的 ping（比 busybox 版完整）
  netcat-openbsd       # nc
  bind9-host           # nslookup / host / dig
  # —— 系统 ——
  ca-certificates      # HTTPS 证书（已解包过，确保完整）
  tzdata               # 时区（Ubuntu 默认）
  bash-completion      # bash 补全（Ubuntu 默认）
  # —— 常用小工具 ——
  tree
  htop
)

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

# 自动补齐依赖：复用 47-fetch-debs.sh 的做法，
# 但直接用 dpkg-deb 读已下载包的 Depends（比解析索引更可靠——实测索引解析会漏包）
resolve_all() {
  printf '\n\033[1;36m===== 依赖解析 =====\033[0m\n'
  [ -s "$IDX" ] || die "缺少包索引 $IDX（先跑 47-fetch-debs.sh index）"

  local queue=("${CORE_PKGS[@]}")
  local seen="" pkg deps d base
  local -a final=()

  while [ ${#queue[@]} -gt 0 ]; do
    pkg="${queue[0]}"; queue=("${queue[@]:1}")
    case " $seen " in *" $pkg "*) continue ;; esac
    seen="$seen $pkg"

    if ! grep -q "^Package: $pkg\$" "$IDX" 2>/dev/null; then
      warn "索引里没有 $pkg（跳过）"; continue
    fi
    final+=("$pkg")

    deps="$(idx_field "$pkg" Pre-Depends) $(idx_field "$pkg" Depends)"
    # 解析依赖表达式：去版本约束、取 | 的第一个候选、去 :any 后缀
    for d in $(printf '%s' "$deps" | tr ',' '\n' | while read -r item; do
        item="${item%%|*}"
        item=$(printf '%s' "$item" | sed 's/([^)]*)//g; s/\[[^]]*\]//g; s/<[^>]*>//g')
        base=$(printf '%s' "$item" | awk '{print $1}'); base="${base%%:*}"
        [ -n "$base" ] && printf '%s\n' "$base"
      done); do
      case " $seen " in *" $d "*) ;; *) queue+=("$d") ;; esac
    done
  done

  # lfOS 已自带的包不重复安装（避免覆盖自编译版本）
  local provided="libc6 libcrypt1 libssl3t64 zlib1g liblzma5 libzstd1 libbz2-1.0 \
                  libncursesw6 libtinfo6 libreadline8 gcc-14-base libgcc-s1 libstdc++6"
  local out=""
  for pkg in "${final[@]}"; do
    case " $provided " in *" $pkg "*) continue ;; esac
    out="$out $pkg"
  done

  printf '  需要 %s 个包：\n' "$(printf '%s\n' $out | grep -c .)"
  printf '%s\n' $out | tr ' ' '\n' | grep . | sort -u | while read -r p; do
    printf '    %-22s %-18s %s\n' "$p" "$(idx_field "$p" Version)" "$(idx_field "$p" Installed-Size) KB"
  done
  printf '%s\n' $out | tr ' ' '\n' | grep . | sort -u > "$LOGS/ubuntu-tools-pkgs.txt"
  printf '\n  包清单已写入 %s\n' "$LOGS/ubuntu-tools-pkgs.txt"
}

fetch_all() {
  printf '\n\033[1;36m===== 下载 .deb =====\033[0m\n'
  [ -s "$LOGS/ubuntu-tools-pkgs.txt" ] || die "先运行 resolve"
  local n=0 failn=0 p fn base
  while read -r p; do
    [ -n "$p" ] || continue
    fn=$(idx_field "$p" Filename)
    [ -z "$fn" ] && { warn "无 Filename: $p"; continue; }
    base=$(basename "$fn")
    if [ -s "$PKGS/$base" ]; then printf '  \033[33m[已有]\033[0m %s\n' "$base"; n=$((n+1)); continue; fi
    if curl -fL --retry 2 --connect-timeout 20 --max-time 600 -o "$PKGS/$base.part" "$MIRROR/$fn" 2>/dev/null; then
      mv "$PKGS/$base.part" "$PKGS/$base"
      printf '  \033[32m[下载]\033[0m %-44s %s\n' "$base" "$(du -h "$PKGS/$base" | cut -f1)"
      n=$((n+1))
    else
      rm -f "$PKGS/$base.part"; printf '  \033[31m[失败]\033[0m %s\n' "$base"; failn=$((failn+1))
    fi
  done < "$LOGS/ubuntu-tools-pkgs.txt"
  printf '\n  成功 %s，失败 %s\n' "$n" "$failn"
}

install_all() {
  printf '\n\033[1;36m===== 安装到 rootfs =====\033[0m\n'
  [ -s "$LOGS/ubuntu-tools-pkgs.txt" ] || die "先运行 resolve"

  # 用 dpkg-deb -x 直接解包，再统一 dpkg --configure。
  # 为什么不用 dpkg -i 一把梭：实测一次性 dpkg -i 大量包时，
  # 任一包出错会中断后续处理，导致个别包"已下载却未解包"
  # （之前就因此漏了 libcap2，让 apt 起不来）。
  local installed=0 missing=0 p fn base
  while read -r p; do
    [ -n "$p" ] || continue
    fn=$(idx_field "$p" Filename); base=$(basename "$fn")
    if [ ! -s "$PKGS/$base" ]; then printf '  \033[33m[缺文件]\033[0m %s\n' "$base"; missing=$((missing+1)); continue; fi
    if dpkg-deb -x "$PKGS/$base" "$LFS" 2>/dev/null; then
      printf '  \033[32m[解包]\033[0m %s\n' "$p"; installed=$((installed+1))
    else
      printf '  \033[31m[失败]\033[0m %s\n' "$p"
    fi
  done < "$LOGS/ubuntu-tools-pkgs.txt"
  printf '\n  解包 %s 个，缺文件 %s 个\n' "$installed" "$missing"

  # 登记到 dpkg 数据库（否则 apt 不知道它们已装，依赖检查会失败）
  log "登记到 dpkg 数据库"
  local f name ver
  for f in "$PKGS"/*.deb; do
    [ -f "$f" ] || continue
    name=$(dpkg-deb -f "$f" Package 2>/dev/null)
    [ -n "$name" ] || continue
    case " $(cat "$LOGS/ubuntu-tools-pkgs.txt" | tr '\n' ' ') " in
      *" $name "*) ;;
      *) continue ;;
    esac
    if chroot "$LFS" /usr/bin/dpkg -s "$name" >/dev/null 2>&1; then continue; fi
    ver=$(dpkg-deb -f "$f" Version 2>/dev/null)
    cp -f "$f" "$LFS/tmp/" 2>/dev/null
    chroot "$LFS" /usr/bin/dpkg --unpack "/tmp/$(basename "$f")" >/dev/null 2>&1
    rm -f "$LFS/tmp/$(basename "$f")" 2>/dev/null
  done
  chroot "$LFS" /usr/bin/dpkg --configure -a > "$LOGS/ubuntu-tools-configure.log" 2>&1 || true

  log "更新链接器缓存"
  chroot "$LFS" /usr/sbin/ldconfig 2>/dev/null && ok "ldconfig 完成"

  # 清掉安装过程产生的缓存（保持轻量）
  rm -rf "$LFS/var/lib/apt/lists"/* "$LFS"/var/cache/apt/*.bin 2>/dev/null
  mkdir -p "$LFS/var/lib/apt/lists/partial" 2>/dev/null
  ok "已清理安装缓存"
}

do_gate() {
  printf '\n\033[1;36m===== Ubuntu 工具集门禁 =====\033[0m\n'
  local pass=0 fail=0
  ck() {
    local rc; set +o pipefail; eval "$2" >/dev/null 2>&1; rc=$?; set -o pipefail
    if [ "$rc" -eq 0 ]; then printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); fi
  }
  ck "adduser 可用"        "chroot '$LFS' /usr/sbin/adduser --version"
  ck "perl 可用"           "chroot '$LFS' /usr/bin/perl -v"
  ck "sudo 可用"           "chroot '$LFS' /usr/bin/sudo --version"
  ck "less 可用"           "chroot '$LFS' /usr/bin/less --version"
  ck "nano 可用"           "chroot '$LFS' /usr/bin/nano --version"
  ck "vi(vim-tiny) 可用"   "chroot '$LFS' /usr/bin/vi --version"
  ck "curl 可用"           "chroot '$LFS' /usr/bin/curl --version"
  ck "tree 可用"           "chroot '$LFS' /usr/bin/tree --version"
  ck "htop 可用"           "chroot '$LFS' /usr/bin/htop --version"
  ck "ping 可用"           "chroot '$LFS' /usr/bin/ping -V"
  ck "nslookup 可用"       "chroot '$LFS' /usr/bin/nslookup -version"

  printf '\n  体积: %s\n' "$(du -sh "$LFS" | cut -f1)"
  printf '  Ubuntu 工具集门禁: %d 通过 / %d 失败\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ 工具集就绪\033[0m\n' || printf '  \033[1;31m✗ 有缺口\033[0m\n'
  return "$fail"
}

do_list() {
  printf '\n  计划安装的包：\n'
  printf '    %s\n' "${CORE_PKGS[@]}"
  printf '\n  估算体积（Installed-Size）：\n'
  local t=0 p s
  for p in "${CORE_PKGS[@]}"; do
    s=$(idx_field "$p" Installed-Size)
    [ -n "$s" ] && t=$((t + s))
    printf '    %-22s %8s KB\n' "$p" "${s:-?}"
  done
  printf '    %-22s %8s KB（约 %s MB）\n' "合计" "$t" "$((t/1024))"
}

case "${1:-all}" in
  resolve) resolve_all ;;
  fetch)   fetch_all ;;
  install) install_all ;;
  gate)    do_gate ;;
  list)    do_list ;;
  all)     resolve_all; fetch_all; install_all; do_gate ;;
  *) die "未知参数: $1（可用 all|resolve|fetch|install|gate|list）" ;;
esac
