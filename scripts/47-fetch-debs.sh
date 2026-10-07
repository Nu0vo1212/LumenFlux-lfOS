#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 2g - Debian 包获取与依赖解析
#
#  目标：让 lfOS 具备「从 Debian 仓库安装软件」的能力。
#
#  实现方式：用 Debian 官方 Packages 索引做依赖解析，再下载 .deb，
#  最后交给 lfOS 自带的 dpkg 安装。这样得到的依赖关系与 Debian 完全一致，
#  而不是靠人工猜包名。
#
#  用法：
#    bash 47-fetch-debs.sh index              # 下载/更新 Packages 索引
#    bash 47-fetch-debs.sh deps <包名...>      # 只解析依赖（不下载）
#    bash 47-fetch-debs.sh fetch <包名...>     # 解析依赖并下载全部 .deb
#    bash 47-fetch-debs.sh list <包名>         # 显示包信息
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
OUT="$LFOS/build"
CACHE="$OUT/debrepo"
PKGS="$OUT/testpkgs"
LOGS="$OUT/logs"

# Debian 源与组件。trixie = Debian 13（当前 stable），glibc 2.41 与 lfOS 一致，
# 二进制兼容性最好 —— 这一点已用 hello 包实测验证。
SUITE="${LFOS_DEB_SUITE:-trixie}"
MIRROR="${LFOS_DEB_MIRROR:-https://deb.debian.org/debian}"
# 只取 main 组件：非自由/非官方组件对服务器场景意义不大，且体积更小
COMPONENTS="main"

INDEX_GZ="$CACHE/Packages-$SUITE.gz"
INDEX="$CACHE/Packages-$SUITE"

mkdir -p "$CACHE" "$PKGS" "$LOGS"
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }

do_index() {
  log "下载 Packages 索引（$SUITE / $COMPONENTS）"
  local merged="$CACHE/Packages-merged"
  : > "$merged"
  local comp url tmp
  for comp in $COMPONENTS; do
    url="$MIRROR/dists/$SUITE/$comp/binary-amd64/Packages.gz"
    tmp="$CACHE/Packages-$SUITE-$comp.gz"
    if [ -s "$tmp" ] && [ "${LFOS_FORCE_INDEX:-0}" != "1" ]; then
      log "  复用已有 $comp 索引"
    else
      log "  下载 $url"
      curl -fL --retry 2 --connect-timeout 20 --max-time 900 -o "$tmp.part" "$url" 2>/dev/null \
        || { rm -f "$tmp.part"; die "下载 $comp 索引失败"; }
      mv "$tmp.part" "$tmp"
    fi
    gzip -dc "$tmp" >> "$merged" 2>/dev/null || die "解压 $comp 索引失败"
    printf '\n' >> "$merged"
  done
  mv -f "$merged" "$INDEX"
  local n
  n=$(grep -c '^Package: ' "$INDEX" 2>/dev/null || echo 0)
  ok "索引就绪：$n 个包（$INDEX）"
}

ensure_index() {
  [ -s "$INDEX" ] || do_index
}

# 从索引里取某个字段：pkg_field <包名> <字段名>
#
# awk 段落匹配的写法要点：Debian 的 Packages 索引是「空行分隔的段落」，
# 用 RS='' 进入段落模式后，$1/$2 是段落**第一行**的字段。
# 所以判包名必须写 `$1 == "Package:" && $2 == pkg`。
# 早期写成 `$0 ~ "^Package: pkg$"` 是错的 —— 段落模式下 $0 是整个多行段落，
# 要求它「以包名结尾」永远不成立，导致依赖解析静默返回空结果（只找到包自己）。
pkg_field() {
  local pkg="$1" field="$2"
  awk -v RS='' -v p="$pkg" -v f="$field" '
    $1 == "Package:" && $2 == p {
      n = split($0, lines, "\n")
      for (i = 1; i <= n; i++) {
        if (lines[i] ~ "^" f ": ") { sub("^" f ": ", "", lines[i]); print lines[i]; exit }
      }
    }
  ' "$INDEX"
}

# 取包的 Filename 字段（用于拼下载 URL）
pkg_filename() { pkg_field "$1" "Filename"; }
pkg_version()  { pkg_field "$1" "Version"; }

# 解析依赖表达式，只保留真实包名。
# Debian 的 Depends 形如：
#    libc6 (>= 2.34), libgcc-s1 (>= 3.0) | libgcc1, foo:any [amd64] <!nocheck>
# 需要剥离：版本约束、架构限定、构建配置、以及 "|" 的备选项（取第一个）。
parse_dep_list() {
  local deps="$1" item base
  printf '%s' "$deps" | tr ',' '\n' | while read -r item; do
    item="${item%%|*}"                      # 多个候选只取第一个
    item=$(printf '%s' "$item" | tr -d '()[]<>')  # 去掉版本/架构/配置标记
    base=$(printf '%s' "$item" | awk '{print $1}')
    base="${base%%:*}"                      # 去掉 :any / :amd64 之类
    [ -n "$base" ] && printf '%s\n' "$base"
  done
}

# 递归收集依赖：resolve_deps <包名...>
resolve_deps() {
  local queue=("$@") seen="" pkg deps d
  while [ ${#queue[@]} -gt 0 ]; do
    pkg="${queue[0]}"; queue=("${queue[@]:1}")
    case " $seen " in *" $pkg "*) continue ;; esac
    seen="$seen $pkg"

    if ! grep -q "^Package: $pkg\$" "$INDEX" 2>/dev/null; then
      printf '  \033[33m[未找到]\033[0m %s（可能来自非 main 组件或已改名）\n' "$pkg"
      continue
    fi
    printf '%s\n' "$pkg"

    deps="$(pkg_field "$pkg" "Pre-Depends") $(pkg_field "$pkg" "Depends")"
    for d in $(parse_dep_list "$deps"); do
      case " $seen " in *" $d "*) ;; *) queue+=("$d") ;; esac
    done
  done
}

do_deps() {
  ensure_index
  printf '\n\033[1;36m===== 依赖解析 =====\033[0m\n'
  local all
  all=$(resolve_deps "$@" | sort -u)
  printf '%s\n' "$all" | while read -r p; do
    [ -n "$p" ] && printf '  %-28s %s\n' "$p" "$(pkg_version "$p")"
  done
  printf '\n  合计: %s 个包\n' "$(printf '%s\n' "$all" | grep -c .)"
}

do_fetch() {
  ensure_index
  printf '\n\033[1;36m===== 下载 .deb（含依赖）=====\033[0m\n'
  local pkgs f url n=0 failn=0
  pkgs=$(resolve_deps "$@" | sort -u)
  for f in $pkgs; do
    local fn
    fn=$(pkg_filename "$f")
    if [ -z "$fn" ]; then printf '  \033[33m[跳过]\033[0m %s（索引中无 Filename）\n' "$f"; continue; fi
    if [ -s "$PKGS/$(basename "$fn")" ]; then
      printf '  \033[32m[已有]\033[0m %s\n' "$(basename "$fn")"; n=$((n+1)); continue
    fi
    url="$MIRROR/$fn"
    if curl -fL --retry 2 --connect-timeout 20 --max-time 600 \
         -o "$PKGS/$(basename "$fn").part" "$url" 2>/dev/null; then
      mv "$PKGS/$(basename "$fn").part" "$PKGS/$(basename "$fn")"
      printf '  \033[32m[下载]\033[0m %-42s %s\n' "$(basename "$fn")" "$(du -h "$PKGS/$(basename "$fn")" | cut -f1)"
      n=$((n+1))
    else
      rm -f "$PKGS/$(basename "$fn").part"
      printf '  \033[31m[失败]\033[0m %s\n' "$fn"; failn=$((failn+1))
    fi
  done
  printf '\n  成功 %s 个，失败 %s 个\n' "$n" "$failn"
}

do_list() {
  ensure_index
  local p="$1"
  printf '\n\033[1;36m===== %s =====\033[0m\n' "$p"
  for f in Package Version Architecture Depends Pre-Depends Installed-Size Filename Description; do
    local v; v=$(pkg_field "$p" "$f")
    [ -n "$v" ] && printf '  %-16s %s\n' "$f:" "$v"
  done
}

case "${1:-}" in
  index) do_index ;;
  deps)  shift; do_deps "$@" ;;
  fetch) shift; do_fetch "$@" ;;
  list)  shift; do_list "$1" ;;
  "")    die "用法: $0 {index|deps|fetch|list} [包名...]" ;;
  *)     die "未知命令: $1" ;;
esac
