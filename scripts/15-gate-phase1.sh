#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 1 门禁：交叉工具链验证
#  用法： bash /opt/lfOS/scripts/15-gate-phase1.sh
#  检查： 工具齐备性 / 目标三元组 / 编译运行 hello / ELF 属性 /
#         工具链自身的加固水平 / 体积基线
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS_TOOLS="${LFS_TOOLS:-$LFOS/build/tools}"
LFS="${LFS:-$LFOS/build/rootfs}"
LFS_LOGS="${LFS_LOGS:-$LFOS/build/logs}"
LFS_TGT="${LFS_TGT:-x86_64-lfos-linux-gnu}"
BASELINE="$LFOS/build/baseline"

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
sec()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }

mkdir -p "$BASELINE"
echo "============================================================"
echo "  lfOS Phase 1 门禁：交叉工具链    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  目标三元组: $LFS_TGT"
echo "============================================================"

sec "1. 工具链二进制齐备性"
for t in gcc g++ ld as ar ranlib nm strip objdump objcopy readelf; do
  if [ -x "$LFS_TOOLS/bin/$LFS_TGT-$t" ]; then
    ok "$LFS_TGT-$t"
  else
    bad "缺少 $LFS_TOOLS/bin/$LFS_TGT-$t"
  fi
done

sec "2. 目标三元组一致性"
tgt=$("$LFS_TOOLS/bin/$LFS_TGT-gcc" -dumpmachine 2>/dev/null || echo "")
if [ "$tgt" = "$LFS_TGT" ]; then
  ok "gcc -dumpmachine = $tgt"
else
  bad "gcc -dumpmachine = '$tgt'（期望 $LFS_TGT）"
fi
ver=$("$LFS_TOOLS/bin/$LFS_TGT-gcc" -dumpversion 2>/dev/null || echo "")
[ -n "$ver" ] && ok "gcc 版本 $ver" || bad "无法获取 gcc 版本"

sec "3. sysroot 与 glibc 就位"
if [ -f "$LFS/usr/lib/libc.so.6" ] || [ -f "$LFS/lib/libc.so.6" ]; then
  ok "目标根已包含 libc.so.6"
else
  bad "目标根缺少 libc.so.6"
fi
if [ -d "$LFS/usr/include" ] && [ "$(find "$LFS/usr/include" -name '*.h' 2>/dev/null | wc -l)" -gt 100 ]; then
  ok "目标根已安装 Linux API 头文件（$(find "$LFS/usr/include" -name '*.h' | wc -l) 个）"
else
  bad "目标根头文件不足"
fi
if "$LFS_TOOLS/bin/$LFS_TGT-gcc" -print-sysroot 2>/dev/null | grep -q "$LFS"; then
  ok "gcc --sysroot 指向 $LFS"
else
  warn "gcc --sysroot = $("$LFS_TOOLS/bin/$LFS_TGT-gcc" -print-sysroot 2>/dev/null)"
fi

sec "4. 交叉编译 + 运行实测"
tmpd=$(mktemp -d)
cat > "$tmpd/hello.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int main(void){ printf("lfOS cross toolchain OK\n"); return EXIT_SUCCESS; }
EOF

# 4.1 静态链接版本（可直接在同架构宿主上运行）
if "$LFS_TOOLS/bin/$LFS_TGT-gcc" -O2 -static -o "$tmpd/hello-static" "$tmpd/hello.c" \
     > "$LFS_LOGS/gate1-static.log" 2>&1; then
  ok "静态交叉编译成功"
  if file "$tmpd/hello-static" | grep -q 'ELF 64-bit LSB.*x86-64'; then
    ok "产物为 x86-64 ELF：$(file -b "$tmpd/hello-static" | cut -c1-60)"
  else
    bad "产物格式异常：$(file -b "$tmpd/hello-static")"
  fi
  if [ "$(uname -m)" = "x86_64" ]; then
    if out=$("$tmpd/hello-static" 2>&1); then
      ok "静态二进制可直接运行：$out"
    else
      bad "静态二进制无法运行"
    fi
  fi
  s_before=$(stat -c%s "$tmpd/hello-static")
  "$LFS_TOOLS/bin/$LFS_TGT-strip" --strip-all "$tmpd/hello-static" 2>/dev/null
  s_after=$(stat -c%s "$tmpd/hello-static")
  if "$tmpd/hello-static" >/dev/null 2>&1; then
    ok "strip 后仍可运行（${s_before}B → ${s_after}B）"
  else
    bad "strip 后二进制损坏"
  fi
else
  bad "静态交叉编译失败"; tail -15 "$LFS_LOGS/gate1-static.log" | sed 's/^/      /'
fi

# 4.2 动态链接版本（需目标 rootfs 的 loader，用 qemu 或 chroot 才能跑）
if "$LFS_TOOLS/bin/$LFS_TGT-gcc" -O2 -o "$tmpd/hello-dyn" "$tmpd/hello.c" \
     > "$LFS_LOGS/gate1-dynamic.log" 2>&1; then
  ok "动态交叉编译成功"
  if readelf -lW "$tmpd/hello-dyn" 2>/dev/null | grep -q 'interpreter'; then
    interp=$(readelf -lW "$tmpd/hello-dyn" | grep -o '/lib[^]]*ld-linux[^]]*' | head -1)
    ok "动态解释器: ${interp:-未识别}"
  fi
  if command -v ldd >/dev/null 2>&1; then
    if "$LFS_TOOLS/bin/$LFS_TGT-readelf" -d "$tmpd/hello-dyn" 2>/dev/null | grep -q 'NEEDED'; then
      ok "动态依赖检查：使用 readelf -d 列出 NEEDED（宿主 ldd 不适用于交叉产物）"
    fi
  fi
else
  bad "动态交叉编译失败"; tail -15 "$LFS_LOGS/gate1-dynamic.log" | sed 's/^/      /'
fi
rm -rf "$tmpd"

sec "5. ELF 加固属性（默认是否开启 PIE/RELRO）"
tmpd2=$(mktemp -d)
echo 'int main(void){return 0;}' > "$tmpd2/h.c"
if "$LFS_TOOLS/bin/$LFS_TGT-gcc" -O2 -o "$tmpd2/h" "$tmpd2/h.c" 2>/dev/null; then
  readelf -hW "$tmpd2/h" | grep -q 'DYN' && ok "默认生成 PIE（DYN）" || warn "默认非 PIE（Phase 1 pass2 未启用 --enable-default-pie 时属正常）"
  readelf -lW "$tmpd2/h" | grep -q 'GNU_RELRO' && ok "含 GNU_RELRO 段" || warn "无 GNU_RELRO"
  readelf -dW "$tmpd2/h" | grep -q 'BIND_NOW' && ok "启用 BIND_NOW（-z now）" || warn "未启用 BIND_NOW"
fi
rm -rf "$tmpd2"

sec "6. 工具链体积与基线"
tools_size=$(du -sh "$LFS_TOOLS" 2>/dev/null | cut -f1)
rootfs_size=$(du -sh "$LFS" 2>/dev/null | cut -f1)
echo "  工具链隔离区 \$LFS_TOOLS : $tools_size"
echo "  目标根文件系统 \$LFS     : $rootfs_size"
{
  echo "# lfOS Phase 1 baseline - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "target=$LFS_TGT"
  echo "gcc=$ver"
  echo "tools_size=$tools_size"
  echo "rootfs_size=$rootfs_size"
  for t in gcc ld as strip; do
    [ -x "$LFS_TOOLS/bin/$LFS_TGT-$t" ] && \
      printf '%s_size=%sB\n' "$t" "$(stat -c%s "$LFS_TOOLS/bin/$LFS_TGT-$t")"
  done
} | tee "$BASELINE/phase1-toolchain.txt" >/dev/null
ok "基线已写入 $BASELINE/phase1-toolchain.txt"

sec "7. 工具链日志中的真实错误扫描"
# 说明：源码里存在大量 "internal compiler error" 的测试字符串，
#       以及上游构建脚本里的 "make ... Error" 文案，直接 grep 必然误报。
#       这里只匹配真正代表构建失败的形态，并以关键产物存在性作为最终判据。
#
# 注意：只扫描 Phase 1 自己的日志（按前缀白名单），不做全目录扫描 ——
#       全目录扫描会把其他阶段的日志（如 busybox-*、kernel-*）误算进来，
#       造成跨阶段误报。
if [ -d "$LFS_LOGS" ]; then
  patterns='^make(\[[0-9]+\])?: \*\*\* .*Error|^collect2: error|^cc1: error|internal compiler error: [0-9]|No space left on device|virtual memory exhausted'
  # Phase 1 日志前缀白名单
  phase1_logs=""
  for p in binutils gcc1 gcc2 gcc-prereq headers glibc libstdcxx; do
    for f in "$LFS_LOGS/${p}"*.log; do
      [ -f "$f" ] && phase1_logs="$phase1_logs $f"
    done
  done
  hits=""
  if [ -n "$phase1_logs" ]; then
    # shellcheck disable=SC2086
    hits=$(grep -lE "$patterns" $phase1_logs 2>/dev/null || true)
  fi
  if [ -z "$hits" ]; then
    ok "Phase 1 构建日志未发现失败型错误（已排除源码内测试字符串与其他阶段日志）"
  else
    bad "以下 Phase 1 日志含真实错误："
    echo "$hits" | sed 's/^/      /'
    for f in $hits; do
      echo "      ── $(basename "$f") 片段："
      grep -nE "$patterns" "$f" | head -3 | sed 's/^/         /'
    done
  fi
  if [ -x "$LFS_TOOLS/bin/$LFS_TGT-gcc" ] && [ -x "$LFS_TOOLS/bin/$LFS_TGT-g++" ]; then
    ok "关键产物 gcc / g++ 就位（最终判据）"
  else
    bad "gcc / g++ 缺失"
  fi
fi

echo
echo "============================================================"
printf '  结果: \033[32m%d 通过\033[0m / \033[33m%d 警告\033[0m / \033[31m%d 失败\033[0m\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf '  \033[1;32m✔ Phase 1 门禁通过 —— 交叉工具链可用，可进入 Phase 2（基础系统）\033[0m\n'
else
  printf '  \033[1;31m✗ Phase 1 门禁未通过，请检查上述 FAIL 项\033[0m\n'
fi
echo "============================================================"

# ---------------------------------------------------------------------------
# 可选：工具链瘦身（低占用目标）。默认关闭，传 --slim 开启。
# 安全原则：只 strip 二进制、只删「非必需」静态库与文档，
#           永远保留 GCC 运行时库（libgcc/libgcc_eh/libgcc_s）与 crt*.o，
#           删完立刻复验编译+链接+运行，失败即报错退出。
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--slim" ] && [ "$FAIL" -eq 0 ]; then
  sec "8. 工具链瘦身（strip + 选择性删除静态库/文档）"
  before=$(du -sm "$LFS_TOOLS" | cut -f1)
  strip_bin="$LFS_TOOLS/bin/$LFS_TGT-strip"
  [ -x "$strip_bin" ] || strip_bin="strip"
  gcc_libdir="$LFS_TOOLS/lib/gcc/$LFS_TGT"
  log_size() { printf '      %s\n' "$*"; }

  log_size "strip 可执行文件与共享库…"
  find "$LFS_TOOLS" -type f \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null \
    | xargs -0 -r "$strip_bin" --strip-all 2>/dev/null || true

  # 关键：GCC 运行时库必须保留，否则 -lgcc / -lgcc_eh 链接失败（工具链报废）
  log_size "删除静态库（排除 libgcc* 运行时库与 $LFS_TGT/ 目录下的必需库）…"
  find "$LFS_TOOLS" -name '*.a' \
       ! -name 'libgcc.a' ! -name 'libgcc_eh.a' ! -name 'libgcc_s.a' \
       ! -path "*/gcc/$LFS_TGT/*" \
       -print -delete 2>/dev/null | wc -l | sed 's/^/        已删除 /;s/$/ 个 .a 文件/'

  log_size "保留的运行时库："
  ls -1 "$gcc_libdir"/*/libgcc*.a 2>/dev/null | sed 's/^/        /' || echo "        （未找到，稍后复验会报错）"

  log_size "删除文档与 info 手册…"
  rm -rf "$LFS_TOOLS"/share/{doc,info,man,locale} 2>/dev/null || true

  log_size "清理字节码缓存…"
  find "$LFS_TOOLS" -name '*.pyc' -delete 2>/dev/null || true
  find "$LFS_TOOLS" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

  after=$(du -sm "$LFS_TOOLS" | cut -f1)
  echo "  瘦身前: ${before}MB   瘦身后: ${after}MB   释放: $((before-after))MB"

  # 复验：静态 + 动态两种链接都要能过，并实际运行
  tmpc=$(mktemp -d)
  echo 'int main(void){return 0;}' > "$tmpc/s.c"
  link_ok=1
  "$LFS_TOOLS/bin/$LFS_TGT-gcc" -O2 -static -o "$tmpc/s_static" "$tmpc/s.c" 2>"$tmpc/err1" || link_ok=0
  "$LFS_TOOLS/bin/$LFS_TGT-gcc" -O2 -o "$tmpc/s_dyn" "$tmpc/s.c" 2>"$tmpc/err2" || link_ok=0
  if [ "$link_ok" -eq 1 ]; then
    ok "瘦身后静态与动态链接均正常"
  else
    bad "瘦身后链接失败："; sed 's/^/        /' "$tmpc/err1" "$tmpc/err2" 2>/dev/null | head -10
  fi
  # 静态产物在同架构宿主可直接运行（动态产物依赖目标 rootfs 的 loader）
  if [ -x "$tmpc/s_static" ] && [ "$(uname -m)" = "x86_64" ]; then
    "$tmpc/s_static" && ok "静态产物运行正常" || bad "静态产物无法运行"
  fi
  rm -rf "$tmpc"
fi

exit "$FAIL"
