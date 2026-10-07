#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 0 门禁：宿主机环境验证
#  来源：设计方案 §4 Phase 0 + §5 度量指标
#  用法： bash /mnt/d/lfOS/scripts/10-gate-phase0.sh
#  退出码：0 = 全部通过；非 0 = 存在失败项
# ============================================================================
set -uo pipefail

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
sec()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }

echo "============================================================"
echo "  lfOS (流光OS) Phase 0 门禁检查    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  主机: $(uname -n)   内核: $(uname -r)   架构: $(uname -m)"
echo "============================================================"

sec "1. 磁盘空间门禁（要求 ≥ 30GB 可用）"
avail_kb=$(df -Pk / | awk 'NR==2{print $4}')
avail_gb=$(( avail_kb / 1024 / 1024 ))
if [ "$avail_gb" -ge 30 ]; then
  ok "构建盘可用空间 ${avail_gb}GB（≥ 30GB）"
else
  bad "构建盘可用空间仅 ${avail_gb}GB（< 30GB）"
fi

sec "2. 内存门禁（要求 ≥ 4GB）"
mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
if [ "$mem_mb" -ge 4096 ]; then
  ok "可用内存 ${mem_mb}MB"
else
  warn "可用内存仅 ${mem_mb}MB，建议在 .wslconfig 中提高 memory 上限"
fi

sec "3. CPU 门禁（并行构建能力）"
cpus=$(nproc)
if [ "$cpus" -ge 2 ]; then
  ok "CPU 逻辑核心 ${cpus}，MAKEFLAGS 建议 -j$((cpus<8?cpus:8))"
else
  warn "CPU 核心仅 ${cpus}，构建会较慢"
fi

sec "4. 宿主工具链完整性（LFS 要求）"
required="gcc g++ make ld as ar ranlib nm strip objdump perl python3 tar xz bzip2 gzip wget curl git patch sed grep gawk m4 bison flex makeinfo gettext autoconf automake libtoolize pkg-config file bc cpio rsync"
missing=""
for t in $required; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -z "$missing" ]; then
  ok "全部 $(( $(echo "$required" | wc -w) )) 个必需工具齐备"
else
  bad "缺失工具:$missing"
fi

sec "5. 关键库开发头文件"
# 注意：多架构发行版把头文件放在 /usr/include/<triplet>/ 下，需两处都查
find_hdr() {
  local h="$1" d
  for d in /usr/include /usr/include/x86_64-linux-gnu; do
    if [ -f "$d/$h" ]; then echo "$d/$h"; return 0; fi
  done
  return 1
}
for lib in zlib.h openssl/ssl.h ncurses.h elf.h gmp.h mpfr.h seccomp.h; do
  if p=$(find_hdr "$lib"); then
    ok "$p"
  else
    bad "缺少开发头文件 $lib（apt install 对应 -dev 包）"
  fi
done

sec "6. 编译器可用性实测（编译 + 运行 + strip 基线）"
tmpd=$(mktemp -d)
cat > "$tmpd/hello.c" <<'EOF'
#include <stdio.h>
int main(void){ printf("lfOS toolchain OK\n"); return 0; }
EOF
if gcc -O2 -o "$tmpd/hello" "$tmpd/hello.c" 2>"$tmpd/cc.log"; then
  if out=$("$tmpd/hello"); then
    ok "编译并运行成功: $out"
  else
    bad "编译产物无法运行"
  fi
  size_before=$(stat -c%s "$tmpd/hello")
  strip --strip-all "$tmpd/hello" 2>/dev/null
  size_after=$(stat -c%s "$tmpd/hello")
  if "$tmpd/hello" >/dev/null 2>&1; then
    ok "strip --strip-all 后仍可运行（${size_before}B → ${size_after}B）"
  else
    bad "strip 后二进制损坏"
  fi
  mkdir -p /opt/lfOS/build/baseline 2>/dev/null
  printf 'hello.bin=%sB\nhello.stripped=%sB\n' "$size_before" "$size_after" \
    | tee /opt/lfOS/build/baseline/phase0-hello-size.txt >/dev/null 2>&1 \
    && ok "体积基线已记录: /opt/lfOS/build/baseline/phase0-hello-size.txt"
else
  bad "gcc 无法编译 hello.c"; sed 's/^/      /' "$tmpd/cc.log"
fi
rm -rf "$tmpd"

sec "7. 加固能力探测（checksec 依赖的编译特性）"
hardening=0
echo 'int main(void){return 0;}' > /tmp/_h.c
if gcc -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=3 -fPIE -pie -Wl,-z,relro,-z,now \
      -fcf-protection=full -o /tmp/_h /tmp/_h.c 2>/dev/null; then
  ok "支持 -fstack-protector-strong / _FORTIFY_SOURCE=3 / PIE / RELRO / CET"
  hardening=1
else
  bad "加固编译标志测试失败"
fi
if readelf -lW /tmp/_h 2>/dev/null | grep -q 'GNU_RELRO'; then
  ok "ELF 含 GNU_RELRO 段"
else
  warn "未检测到 GNU_RELRO 段"
fi
if readelf -hW /tmp/_h 2>/dev/null | grep -q 'DYN'; then
  ok "ELF 为 PIE（DYN）类型"
else
  warn "ELF 非 PIE 类型"
fi
rm -f /tmp/_h /tmp/_h.c

sec "8. 虚拟化与内核接口"
if [ -e /dev/kvm ]; then
  ok "/dev/kvm 可用（可用于本地镜像验证）"
else
  warn "/dev/kvm 不可用（WSL2 内嵌套虚拟化未开启，镜像验证需走 qemu TCG 或回到 Windows 侧）"
fi
[ -d /sys/fs/cgroup ] && ok "cgroup 已挂载" || warn "cgroup 未挂载"
if [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
  ok "PID 1 = systemd（systemd 支持已启用）"
else
  warn "PID 1 = $(ps -p 1 -o comm= 2>/dev/null)，需重启 WSL 使 systemd 生效（wsl --shutdown）"
fi

sec "9. 安全审计工具"
command -v lynis >/dev/null 2>&1 && ok "lynis $(lynis --version 2>/dev/null | tr -d ' \n')" || warn "lynis 未安装"
command -v nft >/dev/null 2>&1 && ok "nftables 已安装" || warn "nftables 未安装"

echo
echo "============================================================"
printf '  结果: \033[32m%d 通过\033[0m / \033[33m%d 警告\033[0m / \033[31m%d 失败\033[0m\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf '  \033[1;32m✔ Phase 0 门禁通过 —— 可以进入 Phase 1（交叉工具链）\033[0m\n'
else
  printf '  \033[1;31m�’ Phase 0 门禁未通过，请先修复上述 FAIL 项\033[0m\n'
fi
echo "============================================================"
exit "$FAIL"
