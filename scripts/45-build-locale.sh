#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 2e - 生成 locale 数据
#
#  背景（实测踩坑记录）：
#    早期在 /etc/profile 里写了 export LANG=C.UTF-8，理由是「以为 C.UTF-8 是
#    glibc 内置的」。这是**错的** —— C.UTF-8 同样需要 locale 数据文件。
#    后果不是「显示乱码」这么轻，而是 bash 直接段错误（rc=139）：
#        bash: warning: setlocale: LC_ALL: cannot change locale (C.UTF-8)
#        Segmentation fault
#    PID 1 的 shell 每 2 秒崩溃重启，系统实际不可用。
#
#  正确顺序：先本脚本生成 locale 数据，再由 80-apply-hardening.sh 设置 LANG。
#
#  实现要点：
#    localedef 是**目标架构**的二进制。lfOS 与构建宿主同为 x86_64，
#    因此可以用 chroot 到 rootfs 直接运行它（rootfs 里已有 bash 与完整 glibc）。
#
#  用法： bash /opt/lfOS/scripts/45-build-locale.sh [all|list|gate]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
LOGS="$LFOS/build/logs"

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }

# 需要 root 才能 chroot
need_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    exec sudo -E bash "$0" "$@"
  fi
  die "需要 root 权限（chroot）。请用 sudo 运行。"
}

# 要生成的 locale：名称|源定义|字符映射
#   C.UTF-8      —— 最小 UTF-8 环境，解决多字节字符显示（本次核心目标）
#   en_US.UTF-8  —— 通用英文环境，很多程序默认回退到此
#   zh_CN.UTF-8  —— 中文环境
LOCALES=(
  "C.UTF-8|C|UTF-8"
  "en_US.UTF-8|en_US|UTF-8"
  "zh_CN.UTF-8|zh_CN|UTF-8"
)

do_build() {
  printf '\n\033[1;36m===== 生成 locale 数据 =====\033[0m\n'
  [ -x "$LFS/usr/bin/localedef" ] || die "rootfs 里没有 localedef"
  [ -d "$LFS/usr/share/i18n/locales" ] || die "缺少 i18n locale 源数据"

  mkdir -p "$LFS/usr/lib/locale"

  # 防止宿主 PATH 干扰 chroot 内的查找
  local entry name src charmap rc
  for entry in "${LOCALES[@]}"; do
    IFS='|' read -r name src charmap <<< "$entry"
    # 源定义文件是否存在（C.UTF-8 用 C 作为源，属于正常做法）
    if [ ! -f "$LFS/usr/share/i18n/locales/$src" ]; then
      printf '  \033[33m[跳过]\033[0m %-14s 源定义 %s 不存在\n' "$name" "$src"
      continue
    fi
    log "localedef -i $src -f $charmap $name"
    if chroot "$LFS" /usr/bin/localedef -i "$src" -f "$charmap" "$name" \
         > "$LOGS/locale-$name.log" 2>&1; then
      ok "$name 已生成"
    else
      rc=$?
      printf '  \033[31m[失败]\033[0m %s（rc=%s）\n' "$name" "$rc"
      tail -5 "$LOGS/locale-$name.log" | sed 's/^/      /'
    fi
  done
}

do_list() {
  printf '\n\033[1;36m===== 已生成的 locale =====\033[0m\n'
  if [ -d "$LFS/usr/lib/locale" ]; then
    ls -1 "$LFS/usr/lib/locale" 2>/dev/null | sed 's/^/  /'
    printf '\n  locale-archive: '
    if [ -f "$LFS/usr/lib/locale/locale-archive" ]; then
      du -h "$LFS/usr/lib/locale/locale-archive" | cut -f1
    else
      echo "（无）"
    fi
  else
    echo "  /usr/lib/locale 不存在"
  fi
}

do_gate() {
  printf '\n\033[1;36m===== locale 门禁 =====\033[0m\n'
  local pass=0 fail=0
  chk() {
    local rc; set +o pipefail; eval "$2" >/dev/null 2>&1; rc=$?; set -o pipefail
    if [ "$rc" -eq 0 ]; then printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); fi
  }
  chk "localedef 可执行"     "[ -x '$LFS/usr/bin/localedef' ]"
  chk "i18n 源数据完整"      "[ -d '$LFS/usr/share/i18n/locales' ]"
  # 注意 locale -a 的命名约定：输出「.utf8」小写后缀，不是「.UTF-8」。
  # 早期按 C.UTF-8 字面匹配造成误报「未生成」，而 setlocale 实测明明可用。
  chk "C.UTF-8 已生成"       "chroot '$LFS' /usr/bin/locale -a 2>/dev/null | grep -qix 'C.utf8'"
  chk "en_US.UTF-8 已生成"   "chroot '$LFS' /usr/bin/locale -a 2>/dev/null | grep -qix 'en_US.utf8'"
  chk "zh_CN.UTF-8 已生成"   "chroot '$LFS' /usr/bin/locale -a 2>/dev/null | grep -qix 'zh_CN.utf8'"

  printf '\n  实际 setlocale 测试（关键：此前会让 bash 段错误）：\n'
  if chroot "$LFS" /usr/bin/env LC_ALL=C.UTF-8 /bin/bash -c 'echo "    LC_ALL=C.UTF-8 生效，中文测试：你好 lfOS"' 2>&1; then
    printf '    \033[32m✓ bash 在 C.UTF-8 下正常运行\033[0m\n'; pass=$((pass+1))
  else
    printf '    \033[31m✗ bash 在 C.UTF-8 下失败\033[0m\n'; fail=$((fail+1))
  fi

  printf '\n  locale 数据: %d 通过 / %d 失败\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ locale 就绪\033[0m\n' || printf '  \033[1;31m✗ 存在问题\033[0m\n'
  return "$fail"
}

case "${1:-all}" in
  all)  need_root "$@"; do_build; do_list; do_gate ;;
  list) do_list ;;
  gate) do_gate ;;
  *) die "未知参数: $1（可用 all|list|gate）" ;;
esac
