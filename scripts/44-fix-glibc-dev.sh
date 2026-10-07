#!/usr/bin/env bash
# ============================================================================
#  lfOS - 修复 glibc 开发链接（sysroot 完整性）
#
#  问题（实测确认）：
#    sysroot 里缺少无版本号的开发链接：
#        [缺] libdl.so  [缺] libpthread.so  [缺] librt.so  [缺] libutil.so
#    导致任何 `-ldl` / `-lpthread` / `-lrt` / `-lutil` 的链接失败：
#        ld: cannot find -ldl: No such file or directory
#    实测触发点：shadow 的 libsubid（它用 dlopen 加载插件）。
#
#  为什么会有这个缺口：
#    glibc 2.34+ 把 libdl/libpthread/librt/libutil 的功能并入了 libc，
#    但这些库仍以「兼容空壳 + 链接脚本」形式存在。glibc 的构建目录里
#    确实生成了它们（dlfcn/libdl.so 等），但本项目的 glibc 安装步骤
#    没有把它们完整落到 sysroot 中。
#
#  本脚本从 glibc 构建产物中补齐，并验证链接可用。
#  用法： bash /opt/lfOS/scripts/44-fix-glibc-dev.sh [all|check]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
GB="${GLIBC_BUILD:-$LFOS/src/glibc-2.41/build-restore}"
T="$LFOS/build/tools/bin/x86_64-lfos-linux-gnu"

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

do_fix() {
  printf '\n\033[1;36m===== 补齐 glibc 开发链接 =====\033[0m\n'
  [ -d "$GB" ] || die "缺少 glibc 构建目录: $GB"

  # 源路径 → 目标名（源文件都是 glibc 生成的链接脚本，内容是 GROUP(...) 形式）
  local pairs=(
    "dlfcn/libdl.so:libdl.so"
    "nptl/libpthread.so:libpthread.so"
    "rt/librt.so:librt.so"
    "login/libutil.so:libutil.so"
    "math/libm.so:libm.so"
    "resolv/libresolv.so:libresolv.so"
    "nis/libnsl.so:libnsl.so"
    "dlfcn/libdl.a:libdl.a"
    "nptl/libpthread.a:libpthread.a"
    "rt/librt.a:librt.a"
    "login/libutil.a:libutil.a"
  )
  local n=0 p src dst
  for p in "${pairs[@]}"; do
    src="$GB/${p%%:*}"; dst="$LFS/usr/lib/${p##*:}"
    if [ -e "$src" ]; then
      cp -f "$src" "$dst" && printf '  \033[32m[+]\033[0m %-20s ← %s\n' "${p##*:}" "${p%%:*}" && n=$((n+1))
    fi
  done
  log "补齐 $n 个文件"

  # 链接脚本里的路径是 /usr/lib/... （绝对路径），这与 sysroot 内布局一致，
  # 因为目标系统里它们就在 /usr/lib，交叉链接时 ld 会以 sysroot 为根解析。
  printf '\n  生成的链接脚本内容示例（libdl.so）：\n'
  [ -f "$LFS/usr/lib/libdl.so" ] && sed 's/^/    /' "$LFS/usr/lib/libdl.so"
}

do_check() {
  printf '\n\033[1;36m===== 验证开发链接 =====\033[0m\n'
  local pass=0 fail=0
  for l in libdl libpthread librt libutil libm libc libresolv; do
    if [ -e "$LFS/usr/lib/$l.so" ]; then
      printf '  \033[32m[有]\033[0m %s.so\n' "$l"; pass=$((pass+1))
    else
      printf '  \033[31m[缺]\033[0m %s.so\n' "$l"; fail=$((fail+1))
    fi
  done

  printf '\n  实际链接测试（-ldl -lpthread -lrt -lutil）：\n'
  echo 'int main(void){return 0;}' > /tmp/_devtest.c
  local lib okc=0
  for lib in dl pthread rt util; do
    if "$T-gcc" -o /tmp/_devtest /tmp/_devtest.c --sysroot="$LFS" "-l$lib" 2>/tmp/_devtest.err; then
      printf '    \033[32m✓ -l%s\033[0m\n' "$lib"; okc=$((okc+1))
    else
      printf '    \033[31m✗ -l%s\033[0m  %s\n' "$lib" "$(head -1 /tmp/_devtest.err)"
    fi
  done
  rm -f /tmp/_devtest.c /tmp/_devtest /tmp/_devtest.err

  printf '\n  开发链接: %d 就位 / %d 缺失；链接测试 %d/4 通过\n' "$pass" "$fail" "$okc"
}

case "${1:-all}" in
  all)   do_fix; do_check ;;
  check) do_check ;;
  *) die "未知参数: $1（可用 all|check）" ;;
esac
