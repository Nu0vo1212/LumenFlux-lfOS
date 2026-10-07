#!/usr/bin/env bash
# ============================================================================
#  lfOS - 系统精简（对齐 Ubuntu 习惯的同时把体积压下来）
#
#  设计原则：Ubuntu 的最小化安装本来就**不带**这些东西，删掉它们
#  不会让系统"变得不像 Ubuntu"，反而更接近 Ubuntu cloud image 的形态。
#
#  各项依据（都是实测测量出来的，不是估计）：
#    1) /var/lib/apt/lists/*      88M   apt 索引。Ubuntu cloud image 同样不含，
#                                      首次 apt update 会重新下载。
#                                      其中 33M 还是 Translation-en（英文翻译），
#                                      在 LANG=C 环境下毫无用处。
#    2) /usr/include              32M   头文件。运行时系统不需要；
#                                      若将来要用 apt 装 -dev 包会自动补回。
#    3) /usr/share/i18n           17M   locale **源数据**。locale 已生成到
#                                      locale-archive，源数据只在「再生成新
#                                      locale」时才需要。
#    4) /usr/lib/gconv           8.2M   字符集转换模块。只保留常用编码，
#                                      删掉几十种冷门编码（IBM/日韩旧标准等）。
#    5) /usr/share/terminfo      7.4M   终端数据库。只保留常用终端类型。
#    6) /usr/lib/locale          5.9M   只保留 C.UTF-8 / en_US / zh_CN。
#    7) /usr/share/locale        3.3M   程序界面翻译。只保留中文。
#    8) 各类残留                  ~2M   figlet 测试数据、gcc 运行时目录、
#                                      aclocal、gdb、lintian 等。
#
#  用法： bash 51-slim.sh [all|apt|headers|i18n|gconv|terminfo|locale|misc|gate|dry]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
DRY=0
[ "${1:-}" = "dry" ] && { DRY=1; shift; }

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
skip(){ printf '  \033[33m[跳过]\033[0m %s\n' "$*"; }

# 删除并报告省下的空间
slim() { # slim <路径> <说明>
  local p="$LFS/$1" desc="$2"
  if [ ! -e "$p" ]; then skip "$1（不存在）"; return 0; fi
  local before after saved
  before=$(du -sk "$LFS" 2>/dev/null | cut -f1)
  if [ "$DRY" -eq 1 ]; then
    printf '  \033[33m[dry]\033[0m %-28s %8s  %s\n' "$1" "$(du -sh "$p" 2>/dev/null | cut -f1)" "$desc"
    return 0
  fi
  rm -rf "$p"
  after=$(du -sk "$LFS" 2>/dev/null | cut -f1)
  saved=$((before - after))
  printf '  \033[32m[删]\033[0m %-28s %6s KB  %s\n' "$1" "$saved" "$desc"
}

# ---------------------------------------------------------------------------
#  1. apt 索引与缓存
# ---------------------------------------------------------------------------
do_apt() {
  printf '\n\033[1;36m===== 清理 apt 索引与缓存 =====\033[0m\n'
  slim "var/lib/apt/lists"            "apt 包索引（首次 apt update 会重新下载）"
  slim "var/cache/apt/archives"       "已下载的 .deb 缓存"
  # 关键：apt 还会把索引编译成二进制缓存 pkgcache.bin / srcpkgcache.bin。
  # 实测这两个文件各 45M（合计 90M）。删掉 lists 后它们已经失效，
  # 但**不会被自动删除** —— 第一次精简就漏了这一步，
  # 结果 lists 清了 /var 却仍有 90M。
  rm -f "$LFS"/var/cache/apt/*.bin 2>/dev/null
  printf '  \033[32m[删]\033[0m %-28s          apt 二进制缓存（pkgcache/srcpkgcache.bin）\n' "var/cache/apt/*.bin"

  # 保留目录结构，否则 apt update 会报错
  if [ "$DRY" -eq 0 ]; then
    mkdir -p "$LFS/var/lib/apt/lists/partial" "$LFS/var/cache/apt/archives/partial"
    chmod 0755 "$LFS/var/lib/apt/lists/partial" "$LFS/var/cache/apt/archives/partial" 2>/dev/null
    # 禁止下载 Translation（英文翻译，约 33M）
    mkdir -p "$LFS/etc/apt/apt.conf.d"
    cat > "$LFS/etc/apt/apt.conf.d/99-no-translation" <<'EOF'
// 不下载包描述的翻译文件。
// 实测 Debian trixie 的 Translation-en 索引有 33MB，而 lfOS 默认 LANG=C，
// 这些翻译永远不会被用到，纯粹浪费磁盘和下载时间。
Acquire::Languages "none";
EOF
    ok "已写入 /etc/apt/apt.conf.d/99-no-translation（Acquire::Languages none）"
  fi
}

# ---------------------------------------------------------------------------
#  2. 开发头文件
# ---------------------------------------------------------------------------
do_headers() {
  printf '\n\033[1;36m===== 移除开发头文件 =====\033[0m\n'
  # 注意：保留 libc_nonshared.a（动态链接必需，曾误删导致整个工具链失效）
  slim "usr/include"                  "C 头文件（运行时不需要；装 -dev 包会补回）"
  if [ "$DRY" -eq 0 ] && [ -f "$LFS/usr/lib/libc_nonshared.a" ]; then
    ok "已确认保留 /usr/lib/libc_nonshared.a（动态链接必需，勿删）"
  fi
}

# ---------------------------------------------------------------------------
#  3. locale 源数据
# ---------------------------------------------------------------------------
do_i18n() {
  printf '\n\033[1;36m===== 移除 locale 源数据 =====\033[0m\n'
  slim "usr/share/i18n"               "locale 源定义与 charmap（已生成到 locale-archive）"
}

# ---------------------------------------------------------------------------
#  4. 字符集转换模块（策略：strip，不删除）
#
#  策略变更记录（重要的方向性修正）：
#    最初写的是「只保留常用编码、删掉冷门编码」，实测证明这是**错误方向**：
#      1) 删除只省 6.8M gconv（8.2M → 1.4M），但 iconv 是基础功能，
#         且 gconv-modules 里引用了 61 个被删模块（各种编码别名条目），
#         删完后别名解析会失败，属于「省得少、伤得深」；
#      2) 我一度把「UTF-8.so / INTERNAL.so 不存在」误判为「被删了」并去
#         "恢复" —— 实际上这两个本来就是 glibc 内置的，根本不产生 .so 文件。
#         真正的问题是我的门禁用了宿主路径做测试（chroot 里看不到宿主的 /tmp）。
#    改为只做 strip：15M → 8.2M，功能零损失。这才是正确的优化方式。
# ---------------------------------------------------------------------------
do_gconv() {
  printf '\n\033[1;36m===== strip gconv 字符集模块 =====\033[0m\n'
  local gc="$LFS/usr/lib/gconv"
  [ -d "$gc" ] || { skip "usr/lib/gconv（不存在）"; return 0; }

  local before after n=0
  before=$(du -sk "$gc" 2>/dev/null | cut -f1)
  if [ "$DRY" -eq 1 ]; then
    printf '  [dry] 将 strip %s 个模块（当前 %s）\n' \
      "$(ls -1 "$gc"/*.so 2>/dev/null | wc -l)" "$(du -sh "$gc" | cut -f1)"
    return 0
  fi

  local T="$LFOS/build/tools/bin/x86_64-lfos-linux-gnu"
  local f
  for f in "$gc"/*.so; do
    [ -f "$f" ] || continue
    "$T-strip" --strip-unneeded "$f" 2>/dev/null && n=$((n+1))
  done
  after=$(du -sk "$gc" 2>/dev/null | cut -f1)
  printf '  \033[32m[OK]\033[0m strip 了 %s 个 gconv 模块：%s KB → %s KB\n' "$n" "$before" "$after"
}

# ---------------------------------------------------------------------------
#  5. terminfo
# ---------------------------------------------------------------------------
do_terminfo() {
  printf '\n\033[1;36m===== 精简 terminfo =====\n'
  local ti="$LFS/usr/share/terminfo"
  [ -d "$ti" ] || { skip "usr/share/terminfo（不存在）"; return 0; }

  # 保留常见终端；其余目录整个删掉
  local keep='^(x|xterm|xterm-256color|xterm-color|linux|vt100|vt220|screen|screen-256color|tmux|tmux-256color|ansi|dumb|cygwin|rxvt|rxvt-unicode)$'
  local n=0
  local d sub
  for d in "$ti"/*; do
    [ -d "$d" ] || continue
    for sub in "$d"/*; do
      [ -e "$sub" ] || continue
      local base; base=$(basename "$sub")
      if printf '%s' "$base" | grep -qE "$keep"; then continue; fi
      if [ "$DRY" -eq 1 ]; then continue; fi
      rm -rf "$sub"; n=$((n+1))
    done
  done
  if [ "$DRY" -eq 0 ]; then
    printf '  \033[32m[删]\033[0m 冷门终端定义 %s 项，terminfo 现为 %s\n' "$n" "$(du -sh "$ti" | cut -f1)"
    printf '  保留示例: '; ls "$ti" 2>/dev/null | head -5 | tr '\n' ' '; echo
  fi
}

# ---------------------------------------------------------------------------
#  6. locale-archive 只留必要语言
# ---------------------------------------------------------------------------
do_locale() {
  printf '\n\033[1;36m===== 精简 locale =====\033[0m\n'

  # ⚠ 幂等性保护（一次事故换来的）：
  #   localedef 需要 /usr/share/i18n 的源数据，而 do_i18n 会把它删掉。
  #   最初没有这个检查，导致**第二次运行本脚本时**：
  #       do_locale 先删掉 locale-archive → localedef 因缺源数据生成 0 个语言
  #       → locale-archive 只剩 4KB，C.UTF-8 与 zh_CN.UTF-8 全部消失。
  #   也就是说脚本重复执行会**破坏已经建好的系统**。这是必须修掉的缺陷。
  #   现在的行为：源数据不在就什么都不做，完好保留现有 locale-archive。
  if [ ! -d "$LFS/usr/share/i18n/locales" ]; then
    if [ -f "$LFS/usr/lib/locale/locale-archive" ]; then
      skip "locale 源数据已精简；保留现有 locale-archive（$(du -h "$LFS/usr/lib/locale/locale-archive" | cut -f1)）"
      printf '  现有语言: %s\n' "$(chroot "$LFS" /usr/bin/locale -a 2>/dev/null | tr '\n' ' ')"
    else
      printf '  \033[31m[警告]\033[0m 既无源数据也无 locale-archive，UTF-8 将不可用！\n'
    fi
    return 0
  fi

  if [ ! -x "$LFS/usr/bin/localedef" ]; then skip "localedef 不存在"; return 0; fi
  if [ "$DRY" -eq 1 ]; then
    printf '  [dry] 将重建 locale-archive（当前 %s）\n' "$(du -sh "$LFS/usr/lib/locale" 2>/dev/null | cut -f1)"
    return 0
  fi

  local before; before=$(du -sk "$LFS/usr/lib/locale" 2>/dev/null | cut -f1)
  rm -f "$LFS/usr/lib/locale/locale-archive" "$LFS/usr/lib/locale/locale-archive.tmpl"

  local okc=0
  for spec in "C:UTF-8:C.UTF-8" "en_US:UTF-8:en_US.UTF-8" "zh_CN:UTF-8:zh_CN.UTF-8"; do
    local src charmap name
    IFS=':' read -r src charmap name <<< "$spec"
    if chroot "$LFS" /usr/bin/localedef -i "$src" -f "$charmap" "$name" \
         > /dev/null 2>&1; then okc=$((okc+1)); fi
  done

  # 生成失败（0 个语言）时立刻告警 —— 这正是上次事故的表征
  if [ "$okc" -eq 0 ]; then
    printf '  \033[31m[严重]\033[0m 一个语言都没生成成功，locale-archive 可能已损坏！\n'
    return 1
  fi

  local after; after=$(du -sk "$LFS/usr/lib/locale" 2>/dev/null | cut -f1)
  printf '  \033[32m[OK]\033[0m 重建 locale-archive（%s 个语言），%s KB → %s KB\n' \
    "$okc" "$before" "$after"
}

# ---------------------------------------------------------------------------
#  7. 杂项残留
# ---------------------------------------------------------------------------
do_misc() {
  printf '\n\033[1;36m===== 清理残留 =====\033[0m\n'
  slim "usr/share/figlet"             "figlet 字体（之前的 apt 测试残留）"
  slim "usr/share/gcc-14.3.0"         "gcc 运行时目录（系统无编译器）"
  slim "usr/share/gcc"                "gcc 共享目录"
  slim "usr/share/aclocal"            "autoconf 宏（无编译器）"
  slim "usr/share/gdb"                "gdb 自动加载脚本（无调试器）"
  slim "usr/share/lintian"            "lintian 数据（打包检查工具）"
  slim "usr/share/gettext"            "gettext 运行时数据"
  slim "usr/share/info"               "info 文档"
  slim "usr/share/doc"                "软件文档"
  slim "usr/share/man"                "手册页（需要时 apt install man-db）"
  slim "usr/lib/pkgconfig"            "pkg-config 元数据（无编译器）"
  slim "usr/share/pkgconfig"          "pkg-config 元数据"
  slim "usr/lib/cmake"                "CMake 配置（无构建系统）"
}

# ---------------------------------------------------------------------------
#  8. 语言翻译文件
# ---------------------------------------------------------------------------
do_share_locale() {
  printf '\n\033[1;36m===== 精简程序翻译 =====\033[0m\n'
  local sl="$LFS/usr/share/locale"
  [ -d "$sl" ] || { skip "usr/share/locale（不存在）"; return 0; }
  local n=0
  local d
  for d in "$sl"/*; do
    [ -d "$d" ] || continue
    local base; base=$(basename "$d")
    case "$base" in
      zh_CN|zh_TW|zh_Hans|zh|en|C|locale.alias) continue ;;
    esac
    if [ "$DRY" -eq 1 ]; then continue; fi
    rm -rf "$d"; n=$((n+1))
  done
  [ "$DRY" -eq 0 ] && printf '  \033[32m[删]\033[0m 非中文翻译 %s 项，现为 %s\n' "$n" "$(du -sh "$sl" | cut -f1)"
}

do_gate() {
  printf '\n\033[1;36m===== 精简门禁（确认系统仍可用）=====\033[0m\n'
  local pass=0 fail=0
  ck() {
    local rc; set +o pipefail; eval "$2" >/dev/null 2>&1; rc=$?; set -o pipefail
    if [ "$rc" -eq 0 ]; then printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); fi
  }
  ck "bash 可用"            "chroot '$LFS' /bin/bash -c true"
  ck "coreutils 可用"       "chroot '$LFS' /bin/ls /"
  ck "dpkg 可用"            "chroot '$LFS' /usr/bin/dpkg --version"
  ck "apt 可用"             "chroot '$LFS' /usr/bin/apt-get --version"
  ck "sh 可用"              "chroot '$LFS' /bin/sh -c true"
  ck "nft 可用"             "chroot '$LFS' /usr/sbin/nft --version"
  ck "useradd 可用"         "chroot '$LFS' /usr/sbin/useradd --help"
  ck "openssl 可用"         "chroot '$LFS' /usr/bin/openssl version"
  ck "C.UTF-8 locale 可用"  "chroot '$LFS' /usr/bin/locale -a 2>/dev/null | grep -qix 'C.utf8'"
  ck "中文 locale 可用"     "chroot '$LFS' /usr/bin/locale -a 2>/dev/null | grep -qix 'zh_CN.utf8'"
  # 注意：测试必须在 chroot **内部**创建文件。
  # 最初写成把宿主 /tmp 的文件传进去，chroot 里看不到，于是永远失败 ——
  # 我据此误判「iconv 坏了」，还去"恢复"了一遍 gconv 模块。
  ck "iconv 转换可用"       "chroot '$LFS' /bin/sh -c 'echo test | iconv -f UTF-8 -t GB18030 | grep -q .'"
  ck "iconv 中文转换"       "chroot '$LFS' /bin/sh -c 'echo 测试 | iconv -f UTF-8 -t GB2312 | iconv -f GB2312 -t UTF-8 | grep -q .'"
  ck "iconv 编码列表"       "chroot '$LFS' /usr/bin/iconv -l 2>/dev/null | grep -q 'UTF-8'"
  ck "libc_nonshared.a 保留" "[ -f '$LFS/usr/lib/libc_nonshared.a' ]"

  printf '\n  当前体积: %s\n' "$(du -sh "$LFS" 2>/dev/null | cut -f1)"
  printf '  --- 顶层分布 ---\n'
  du -sh "$LFS"/* 2>/dev/null | sort -rh | head -6 | sed 's/^/    /'
  printf '\n  精简门禁: %d 通过 / %d 失败\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ 精简后系统完好\033[0m\n' || printf '  \033[1;31m✗ 有功能受损\033[0m\n'
  return "$fail"
}

case "${1:-all}" in
  apt)       do_apt ;;
  headers)   do_headers ;;
  i18n)      do_i18n ;;
  gconv)     do_gconv ;;
  terminfo)  do_terminfo ;;
  locale)    do_locale ;;
  shareloc)  do_share_locale ;;
  misc)      do_misc ;;
  gate)      do_gate ;;
  dry)
    DRY=1
    printf '\033[1;33m===== 预演模式（不实际删除）=====\033[0m\n'
    do_apt; do_headers; do_gconv; do_terminfo; do_locale; do_share_locale; do_misc; do_i18n
    printf '\n  预演完成。当前体积: %s\n' "$(du -sh "$LFS" | cut -f1)"
    ;;
  all)
    # 注意：不能在函数外用 local（bash 会报错），这里用普通变量
    BEFORE_KB=$(du -sk "$LFS" | cut -f1)
    # 顺序很重要：locale 重建需要 i18n 源数据，所以必须在删 i18n 之前
    do_apt
    do_locale
    do_gconv
    do_terminfo
    do_share_locale
    do_headers
    do_misc
    do_i18n
    do_gate
    AFTER_KB=$(du -sk "$LFS" | cut -f1)
    printf '\n\033[1;36m===== 精简汇总 =====\033[0m\n'
    printf '  %s KB → %s KB（省 %s MB）\n' "$BEFORE_KB" "$AFTER_KB" "$(( (BEFORE_KB - AFTER_KB) / 1024 ))"
    ;;
  *) echo "用法: $0 {all|dry|apt|headers|i18n|gconv|terminfo|locale|shareloc|misc|gate}"; exit 1 ;;
esac
