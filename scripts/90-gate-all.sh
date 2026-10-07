#!/usr/bin/env bash
# lfOS 全流水线门禁汇总
echo "═══════════════════════════════════════════════════════════════"
echo "  lfOS (LumenFluxOS / 流光OS) 全流水线门禁汇总"
echo "  时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "═══════════════════════════════════════════════════════════════"

run_gate() {
  local name="$1"; shift
  printf '\n▶ %s\n' "$name"
  local out
  out=$("$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
  echo "$out" | grep -E '门禁:|通过|✔|✗|就位' | tail -3 | sed 's/^/    /'
}

run_gate "Phase 2 基础系统"      bash /opt/lfOS/scripts/41-build-base.sh gate
run_gate "Phase 2b 系统基础文件"  bash /opt/lfOS/scripts/83-setup-system.sh check
run_gate "Phase 3 内核"          bash /opt/lfOS/scripts/50-build-kernel.sh gate
run_gate "Phase 4 引导 initramfs" bash /opt/lfOS/scripts/61-build-boot-initramfs.sh gate
run_gate "Phase 4 rootfs 打包"    bash /opt/lfOS/scripts/72-pack-rootfs.sh gate
run_gate "Phase 5 安全基线"       bash /opt/lfOS/scripts/80-apply-hardening.sh check
run_gate "Phase 4 lfOS init"      bash /opt/lfOS/scripts/82-install-init.sh check
run_gate "Phase 4 ISO"            bash /opt/lfOS/scripts/75-make-iso.sh gate

echo
echo "═══════════════════════════════════════════════════════════════"
echo "  产物"
echo "═══════════════════════════════════════════════════════════════"
for f in img/lfos.iso img/rootfs.squashfs img/rootfs.ext4 \
         kernel/bzImage boot-initramfs.cpio.gz initramfs-lfos.cpio.gz; do
  p="/opt/lfOS/build/$f"
  [ -f "$p" ] && printf '  %-32s %s\n' "$f" "$(du -h "$p" | cut -f1)"
done

echo
echo "  ISO 完整性: $(sha256sum /opt/lfOS/build/img/lfos.iso 2>/dev/null | cut -c1-32)…"
