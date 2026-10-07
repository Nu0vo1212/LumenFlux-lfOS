#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 2i - Debian 兼容性收尾（merged-usr + 链接器 + sh + ld.so.conf）
#
#  本脚本把调试 apt 过程中查明的**全部**兼容性修复固化下来。
#  每一项都是实测踩坑得出的，缺任何一项都会导致 Debian 包无法正常工作：
#
#   1) merged-usr 布局（/bin /sbin /lib /lib64 → /usr/...）
#      Debian bookworm+ 要求该布局，apt 会告警，部分 postinst 也依赖它。
#
#   2) /usr/lib64/ld-linux-x86-64.so.2 必须存在
#      所有 ELF 的 interpreter 硬编码为 /lib64/ld-linux-x86-64.so.2；
#      合并后 /lib64 → /usr/lib64，若那里没有链接器则全系统程序无法启动。
#      （实测曾导致 bash/ls/dpkg 全部报 No such file or directory）
#
#   3) /usr/bin/sh → bash 必须存在
#      合并时删掉 /bin 会连带删掉 /bin/sh；而 Debian 所有 postinst 都是
#      #!/bin/sh，缺失会让每个包报
#          dpkg: warning: 'sh' not found in PATH or not executable
#
#   4) /etc/ld.so.conf 必须存在且 include ld.so.conf.d/
#      glibc 的 ldconfig 只读这个文件；缺了它，ld.so.conf.d/ 下的配置全无效。
#      （实测导致 apt 找不到 /usr/lib/x86_64-linux-gnu 下的库）
#
#   5) Debian multiarch 库路径纳入搜索范围
#
#  用法： bash /opt/lfOS/scripts/50-debian-compat.sh [all|usrmerge|linker|sh|ldconf|gate]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

# --- 1. merged-usr ------------------------------------------------------
do_usrmerge() {
  printf '\n\033[1;36m===== merged-usr 布局 =====\033[0m\n'
  shopt -s nullglob
  # 先把实体文件并入 /usr（**不要**直接删目录，那正是踩过的坑）
  local f b n=0
  for f in "$LFS"/sbin/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    b=$(basename "$f"); mv -f "$f" "$LFS/usr/sbin/$b" && n=$((n+1))
  done
  log "/sbin → /usr/sbin: $n 个文件"

  n=0
  for f in "$LFS"/lib/*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    if [ -L "$f" ]; then rm -f "$f"
    else cp -a "$f" "$LFS/usr/lib/$b" 2>/dev/null && rm -f "$f" && n=$((n+1)); fi
  done
  log "/lib → /usr/lib: $n 个文件"

  rm -rf "$LFS/bin" "$LFS/sbin" "$LFS/lib" 2>/dev/null
  ln -sfn usr/bin  "$LFS/bin"
  ln -sfn usr/sbin "$LFS/sbin"
  ln -sfn usr/lib  "$LFS/lib"
  ln -sfn usr/lib64 "$LFS/lib64"
  for d in bin sbin lib lib64; do
    printf '  /%-6s → %s\n' "$d" "$(readlink "$LFS/$d")"
  done
}

# --- 2. 动态链接器 ------------------------------------------------------
do_linker() {
  printf '\n\033[1;36m===== 动态链接器链接 =====\033[0m\n'
  mkdir -p "$LFS/usr/lib64"
  # ELF interpreter 硬编码 /lib64/ld-linux-x86-64.so.2，必须可解析
  if [ -e "$LFS/usr/lib/ld-linux-x86-64.so.2" ]; then
    ln -sfn ../lib/ld-linux-x86-64.so.2 "$LFS/usr/lib64/ld-linux-x86-64.so.2"
    printf '  /usr/lib64/ld-linux-x86-64.so.2 → ../lib/ld-linux-x86-64.so.2\n'
  else
    die "找不到 ld-linux-x86-64.so.2，无法建立链接器路径"
  fi
  [ -e "$LFS/lib64/ld-linux-x86-64.so.2" ] && ok "/lib64/ld-linux-x86-64.so.2 可解析" \
    || die "/lib64/ld-linux-x86-64.so.2 仍不可解析"
}

# --- 3. /bin/sh ---------------------------------------------------------
do_sh() {
  printf '\n\033[1;36m===== /usr/bin/sh =====\033[0m\n'
  # Debian 所有 postinst 都是 #!/bin/sh，必须有
  if [ -e "$LFS/usr/bin/bash" ]; then
    ln -sfn bash "$LFS/usr/bin/sh"
    ok "/usr/bin/sh → bash"
  else
    die "缺少 /usr/bin/bash"
  fi
}

# --- 4/5. ld.so.conf 与 multiarch ---------------------------------------
do_ldconf() {
  printf '\n\033[1;36m===== ld.so.conf 与 multiarch 路径 =====\033[0m\n'
  cat > "$LFS/etc/ld.so.conf" <<'EOF'
# lfOS 动态链接器搜索路径配置
#
# 注意：glibc 的 ldconfig **只读本文件**。若本文件不存在（或不 include
# ld.so.conf.d/），放在 /etc/ld.so.conf.d/ 下的所有配置都不会生效 ——
# 实测踩到过：Debian 包把库装在 /usr/lib/x86_64-linux-gnu/，
# 配置写了指向它，但 ld.so.cache 里该路径条目数为 0，导致 apt 报
#     error while loading shared libraries: libapt-private.so.0.0
include /etc/ld.so.conf.d/*.conf

# lfOS 自身的库目录
/usr/lib
/lib
EOF
  chmod 0644 "$LFS/etc/ld.so.conf"
  ok "/etc/ld.so.conf 已写入"

  mkdir -p "$LFS/etc/ld.so.conf.d"
  cat > "$LFS/etc/ld.so.conf.d/zz-debian-multiarch.conf" <<'EOF'
# Debian 的包把库安装在 multiarch 路径下，而 lfOS 使用 /usr/lib。
# 加入动态链接器搜索路径，否则 Debian 程序会报
#     error while loading shared libraries: libXXX.so: cannot open shared object file
/usr/lib/x86_64-linux-gnu
/lib/x86_64-linux-gnu
EOF
  ok "multiarch 路径已配置"

  chroot "$LFS" /usr/sbin/ldconfig 2>/dev/null && ok "ldconfig 已执行"
  local n; n=$(strings "$LFS/etc/ld.so.cache" 2>/dev/null | grep -c 'x86_64-linux-gnu')
  printf '  ld.so.cache 中 multiarch 条目: %s\n' "$n"
}

do_gate() {
  printf '\n\033[1;36m===== Debian 兼容性门禁 =====\033[0m\n'
  local pass=0 fail=0
  chk() {
    local rc; set +o pipefail; eval "$2" >/dev/null 2>&1; rc=$?; set -o pipefail
    if [ "$rc" -eq 0 ]; then printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); fi
  }
  chk "merged-usr: /bin 是链接"        "[ -L '$LFS/bin' ]"
  chk "merged-usr: /lib 是链接"        "[ -L '$LFS/lib' ]"
  chk "链接器 /lib64/... 可解析"       "[ -e '$LFS/lib64/ld-linux-x86-64.so.2' ]"
  chk "/bin/sh 可执行"                 "chroot '$LFS' /bin/sh -c true"
  chk "/etc/ld.so.conf 存在"           "[ -f '$LFS/etc/ld.so.conf' ]"
  chk "multiarch 缓存已建立"           "strings '$LFS/etc/ld.so.cache' 2>/dev/null | grep -q x86_64-linux-gnu"
  chk "bash 可运行"                    "chroot '$LFS' /bin/bash -c true"
  chk "dpkg 可运行"                    "chroot '$LFS' /usr/bin/dpkg --version"

  printf '\n  Debian 兼容性: %d 通过 / %d 失败\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ Debian 兼容性就绪\033[0m\n' \
                    || printf '  \033[1;31m✗ 存在问题\033[0m\n'
  return "$fail"
}

case "${1:-all}" in
  usrmerge) do_usrmerge ;;
  linker)   do_linker ;;
  sh)       do_sh ;;
  ldconf)   do_ldconf ;;
  gate)     do_gate ;;
  all) hr() { :; }; do_usrmerge; do_linker; do_sh; do_ldconf; do_gate ;;
  *) die "未知参数: $1（可用 all|usrmerge|linker|sh|ldconf|gate）" ;;
esac
