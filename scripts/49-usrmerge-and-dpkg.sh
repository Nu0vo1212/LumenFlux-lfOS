#!/usr/bin/env bash
# ============================================================================
#  lfOS - 转换为 merged-usr 布局，并重建 dpkg（启用 update-alternatives）
#
#  为什么必须做（实测得出，非推测）：
#   1) Debian 从 bookworm 起要求 merged-usr 布局，apt 会告警：
#        W: /bin resolved to a different inode than /usr/bin
#        W: Unmerged usr is no longer supported, use usrmerge
#      部分包的 postinst 也依赖该布局。
#   2) Debian 包的 postinst 普遍调用 update-alternatives 注册命令别名，
#      而当前 dpkg 是带 --disable-update-alternatives 编译的，导致：
#        /var/lib/dpkg/info/figlet.postinst: update-alternatives: command not found
#        dpkg: error processing package figlet (--configure)
#
#  merged-usr 是 Debian/Ubuntu/Fedora/Arch 的现行标准，转换是安全的常规操作。
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

echo "════ 1) 转换前：把 /sbin 与 /lib 的真实文件并入 /usr ════"
shopt -s nullglob
moved=0
for f in "$LFS"/sbin/*; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  b=$(basename "$f")
  mv -f "$f" "$LFS/usr/sbin/$b" && moved=$((moved+1))
done
log "/sbin → /usr/sbin 移动 $moved 个文件"

moved=0
for f in "$LFS"/lib/*; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  if [ -L "$f" ]; then
    # 本就是指向 /usr/lib 的兼容链接，转换后不再需要
    rm -f "$f"
  else
    cp -a "$f" "$LFS/usr/lib/$b" 2>/dev/null && rm -f "$f" && moved=$((moved+1))
  fi
done
log "/lib → /usr/lib 移动 $moved 个文件"

# /bin 里全是符号链接，直接删掉（内容都在 /usr/bin）
rm -rf "$LFS/bin" 2>/dev/null

echo
echo "════ 2) 建立 merged-usr 符号链接（相对链接，标准做法）════"
rm -rf "$LFS/sbin" "$LFS/lib" 2>/dev/null
ln -sfn usr/bin  "$LFS/bin"
ln -sfn usr/sbin "$LFS/sbin"
ln -sfn usr/lib  "$LFS/lib"
# /lib64 与 /usr/lib64：x86_64 惯例
ln -sfn usr/lib64 "$LFS/lib64" 2>/dev/null || true
for d in bin sbin lib lib64; do
  printf '  /%-6s → %s\n' "$d" "$(readlink "$LFS/$d" 2>/dev/null || echo '（未创建）')"
done

echo
echo "════ 3) 更新链接器缓存 ════"
chroot "$LFS" /usr/sbin/ldconfig 2>/dev/null && ok "ldconfig 完成"

echo
echo "════ 4) 验证转换后系统仍可用 ════"
for t in /bin/bash /bin/ls /usr/bin/dpkg /usr/sbin/sshd /sbin/e2fsck; do
  if chroot "$LFS" test -x "$t" 2>/dev/null; then printf '  \033[32m[可执行]\033[0m %s\n' "$t"
  else printf '  \033[31m[不可用]\033[0m %s\n' "$t"; fi
done
echo "  bash 实际运行:"
chroot "$LFS" /bin/bash -c 'echo "    bash OK: $(uname -m)"' 2>&1 | sed 's/^/  /'

echo
echo "════ 5) 重建 dpkg（启用 update-alternatives 与 start-stop-daemon）════"
cd "$LFOS/src/dpkg-1.22.22" || die "缺少 dpkg 源码"
make distclean >/dev/null 2>&1 || true

export PATH="$LFOS/build/tools/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CC=x86_64-lfos-linux-gnu-gcc AR=x86_64-lfos-linux-gnu-ar RANLIB=x86_64-lfos-linux-gnu-ranlib
export PKG_CONFIG_PATH="" PKG_CONFIG_LIBDIR="$LFS/usr/lib/pkgconfig:$LFS/usr/share/pkgconfig" \
       PKG_CONFIG_SYSROOT_DIR="$LFS"

log "configure（这次不禁用 update-alternatives）"
if ./configure --prefix=/usr --host=x86_64-lfos-linux-gnu \
      --build="$(gcc -dumpmachine)" --sysconfdir=/etc --localstatedir=/var \
      --disable-nls --disable-dselect --without-selinux \
      > "$LFOS/build/logs/pkg-dpkg-reconfigure.log" 2>&1; then
  grep -E 'update-alternatives|start-stop-daemon|dselect|libmd|libselinux' \
    "$LFOS/build/logs/pkg-dpkg-reconfigure.log" | tail -6 | sed 's/^/    /'
else
  tail -12 "$LFOS/build/logs/pkg-dpkg-reconfigure.log" | sed 's/^/    /'
  die "dpkg 重新配置失败"
fi

log "make"
make -j"$(nproc)" > "$LFOS/build/logs/pkg-dpkg-remake.log" 2>&1 \
  || { grep -nE 'error:|Error [0-9]' "$LFOS/build/logs/pkg-dpkg-remake.log" | head -8; die "dpkg 重建失败"; }
command -v fakeroot >/dev/null && FK=fakeroot || FK=""
$FK make DESTDIR="$LFS" install >> "$LFOS/build/logs/pkg-dpkg-remake.log" 2>&1 \
  || die "dpkg 安装失败"
ok "dpkg 已重建"

echo
echo "════ 6) 验证 update-alternatives ════"
if chroot "$LFS" /usr/bin/update-alternatives --version 2>&1 | head -2 | sed 's/^/  /'; then
  ok "update-alternatives 可用"
fi
