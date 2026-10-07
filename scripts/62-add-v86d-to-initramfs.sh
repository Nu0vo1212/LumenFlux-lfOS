#!/usr/bin/env bash
# 把 v86d 打进 initramfs，让 uvesafb 能真正设置分辨率
#
# 依据（Debian 官方 initramfs-tools/hooks/v86d）：
#   manual_add_modules uvesafb
#   copy_exec /usr/sbin/v86d
# 实测 v86d 是动态链接，依赖 libx86.so.1 + libc.so.6 + /lib64/ld-linux-x86-64.so.2，
# 而 lfOS 的 initramfs 只有静态 busybox，所以这些库必须一并带上。
set -uo pipefail
LFOS=/opt/lfOS
PKGS=$LFOS/build/testpkgs
IDX=$LFOS/build/debrepo/Packages-trixie
MIRROR=https://mirrors.aliyun.com/debian
IRF=$LFOS/build/boot-initramfs.cpio.gz
WORK=/tmp/irf-v86d
LOGS=$LFOS/build/logs

ok(){ printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[警告]\033[0m %s\n' "$*"; }
hr(){ printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }

fetch_pkg(){
  local name="$1"
  local deb
  deb=$(ls "$PKGS/${name}_"*.deb 2>/dev/null | head -1)
  if [ -n "$deb" ]; then echo "$deb"; return 0; fi
  local fn
  fn=$(awk -v RS='' -v p="$name" '$1=="Package:" && $2==p {n=split($0,l,"\n"); for(i=1;i<=n;i++) if (l[i] ~ /^Filename: /) {sub(/^Filename: /,"",l[i]); print l[i]; exit}}' "$IDX" 2>/dev/null)
  if [ -z "$fn" ]; then
    (cd "$PKGS" && apt-get download "$name" > /dev/null 2>&1)
    deb=$(ls "$PKGS/${name}_"*.deb 2>/dev/null | head -1)
    [ -n "$deb" ] && { echo "$deb"; return 0; }
    return 1
  fi
  curl -fL --retry 2 --connect-timeout 20 --max-time 300 -o "$PKGS/$(basename "$fn")" "$MIRROR/$fn" 2>/dev/null
  deb=$(ls "$PKGS/${name}_"*.deb 2>/dev/null | head -1)
  [ -n "$deb" ] && echo "$deb"
}

hr "1. 取 v86d 与 libx86-1"
V86D_DEB=$(fetch_pkg v86d)
LIBX86_DEB=$(fetch_pkg libx86-1)
printf '  v86d:    %s\n' "${V86D_DEB:-未取到}"
printf '  libx86-1: %s\n' "${LIBX86_DEB:-未取到}"
[ -n "$V86D_DEB" ] || { warn "无法获取 v86d"; exit 1; }

hr "2. 解包准备组装"
rm -rf "$WORK"; mkdir -p "$WORK/v86d" "$WORK/libx86"
dpkg-deb -x "$V86D_DEB" "$WORK/v86d" 2>/dev/null
[ -n "$LIBX86_DEB" ] && dpkg-deb -x "$LIBX86_DEB" "$WORK/libx86" 2>/dev/null

V86D_BIN=$(find "$WORK/v86d" -path '*/sbin/v86d' -type f 2>/dev/null | head -1)
V86D_DATA=$(find "$WORK/v86d" -path '*/share/v86d/initramfs' -type f 2>/dev/null | head -1)
LIBX86=$(find "$WORK/libx86" -name 'libx86.so*' 2>/dev/null | head -1)
printf '  v86d 二进制: %s\n' "${V86D_BIN:-缺}"
printf '  v86d 数据:   %s\n' "${V86D_DATA:-缺}"
printf '  libx86:      %s\n' "${LIBX86:-缺}"

hr "3. 解包现有 initramfs"
rm -rf "$WORK/irf"; mkdir -p "$WORK/irf"; cd "$WORK/irf" || exit 1
if ! zcat "$IRF" | cpio -idm 2>/dev/null; then
  warn "解包失败"; exit 1
fi
ok "解包完成，条目 $(find . | wc -l) 个"

hr "4. 放入 v86d 及其依赖"
mkdir -p sbin usr/share/v86d lib/x86_64-linux-gnu lib64
[ -n "$V86D_BIN" ]  && cp -f "$V86D_BIN" sbin/v86d && chmod 0755 sbin/v86d && ok "/sbin/v86d"
[ -n "$V86D_DATA" ] && cp -f "$V86D_DATA" usr/share/v86d/initramfs && ok "/usr/share/v86d/initramfs"

# libx86（从包里）
if [ -n "$LIBX86" ]; then
  cp -fL "$LIBX86" lib/x86_64-linux-gnu/libx86.so.1 2>/dev/null && ok "libx86.so.1（来自包）"
fi

# glibc 与动态链接器（v86d 动态链接，initramfs 里原本没有）
for pair in "/lib/x86_64-linux-gnu/libc.so.6:lib/x86_64-linux-gnu/libc.so.6" \
            "/lib64/ld-linux-x86-64.so.2:lib64/ld-linux-x86-64.so.2"; do
  src="${pair%%:*}"; dst="${pair##*:}"
  if [ -e "$src" ] && [ ! -e "$dst" ]; then
    cp -fL "$src" "$dst" 2>/dev/null && ok "$dst"
  fi
done

# 若 libx86 仍缺，尝试从构建机系统里找
if [ ! -e lib/x86_64-linux-gnu/libx86.so.1 ]; then
  found=$(find / -name 'libx86.so.1*' -not -path '/proc/*' 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    cp -fL "$found" lib/x86_64-linux-gnu/libx86.so.1 && ok "libx86.so.1（来自系统）"
  else
    warn "缺 libx86.so.1 —— v86d 可能无法运行"
  fi
fi

echo "  --- initramfs 中新增的关键文件 ---"
for f in sbin/v86d usr/share/v86d/initramfs lib/x86_64-linux-gnu/libx86.so.1 \
         lib/x86_64-linux-gnu/libc.so.6 lib64/ld-linux-x86-64.so.2; do
  if [ -e "$f" ]; then printf '    \033[32m[有]\033[0m %-40s %s\n' "$f" "$(stat -c%s "$f")"
  else printf '    \033[31m[缺]\033[0m %s\n' "$f"; fi
done

hr "5. 让 /init 在挂载 /proc 后启动 uvesafb（双保险）"
# Debian 的钩子只负责把 v86d 放进去，实际由内核 uvesafb 驱动自己调。
# 但内核调用的时机在 initcall 阶段，若那时 /proc 未就绪可能失败。
# 这里在 /init 里加一段：挂载 /proc 后主动触发一次（用 busybox 无 modprobe，
# 内建驱动无法重复 probe，所以仅在有 /sys/class/graphics 缺失时记录日志）。
if [ -f init ] && ! grep -q 'uvesafb' init 2>/dev/null; then
  # 插在挂载 proc/sys 之后
  python3 - <<'PYEOF'
p = "init"
s = open(p, encoding="utf-8", errors="replace").read()
marker = "mount -t sysfs    sysfs    /sys  2>/dev/null"
snippet = marker + """

# lfOS: uvesafb 需要 v86d（已放入 /sbin/v86d）。内核在 initcall 阶段会自行调用它；
# 这里再确认一次 /dev/fb0 是否就绪，便于排查（缺 v86d 时 uvesafb 会静默失败）。
if [ -x /sbin/v86d ] && [ ! -e /dev/fb0 ]; then
    echo "[lfOS] 提示：/dev/fb0 尚未出现，uvesafb 可能未成功（检查 /sbin/v86d 与 libx86）" > /dev/kmsg 2>/dev/null
fi"""
if marker in s and 'uvesafb' not in s:
    s = s.replace(marker, snippet, 1)
    open(p, "w", encoding="utf-8").write(s)
    print("  已插入探测逻辑")
else:
    print("  锚点未匹配或已存在，跳过")
PYEOF
fi

hr "6. 重新打包 initramfs"
cd "$WORK/irf" || exit 1
# 注意：不要用 --quiet（GNU cpio 2.15 不支持，这正是之前"解包失败"的原因）
if find . -print0 | LC_ALL=C sort -z | \
   cpio --null -o --format=newc --owner=0:0 --reproducible > "$WORK/boot-initramfs.cpio" 2>"$LOGS/irf-repack.log"; then
  gzip -9 -f -n "$WORK/boot-initramfs.cpio"
  cp -f "$IRF" "$IRF.bak-before-v86d" 2>/dev/null
  mv -f "$WORK/boot-initramfs.cpio.gz" "$IRF"
  ok "initramfs 已更新: $(du -h "$IRF" | cut -f1)（原 $(du -h "$IRF.bak-before-v86d" 2>/dev/null | cut -f1)）"
else
  warn "cpio 打包失败:"; tail -3 "$LOGS/irf-repack.log" | sed 's/^/      /'
  exit 1
fi

hr "7. 校验新 initramfs 内容"
rm -rf "$WORK/verify"; mkdir -p "$WORK/verify"; cd "$WORK/verify" || exit 1
zcat "$IRF" | cpio -idm 2>/dev/null
for f in sbin/v86d usr/share/v86d/initramfs lib/x86_64-linux-gnu/libx86.so.1 \
         lib/x86_64-linux-gnu/libc.so.6 lib64/ld-linux-x86-64.so.2 init; do
  if [ -e "$f" ]; then printf '  \033[32m[有]\033[0m %-40s %s 字节\n' "$f" "$(stat -c%s "$f")"
  else printf '  \033[31m[缺]\033[0m %s\n' "$f"; fi
done
printf '  总条目: %s\n' "$(find . | wc -l)"
echo "DONE-IRF-V86D"
