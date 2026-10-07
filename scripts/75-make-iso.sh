#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 4c - 可引导 ISO 镜像制作（BIOS + UEFI 双引导）
#
#  产物：
#    $LFOS/build/img/lfos.iso          混合 ISO（光驱可用，也可 dd 到 U 盘）
#    $LFOS/build/img/efi.img           UEFI 引导软盘镜像（内嵌于 ISO）
#    $LFOS/build/img/lfos-iso.manifest 清单（体积/校验和/内容）
#
#  双引导设计：
#    - BIOS：isolinux.bin（Syslinux 家族）+ isohdpfx.bin 混合 MBR
#    - UEFI：FAT16 软盘镜像 efiboot.img，内含 syslinux.efi → BOOTX64.EFI
#    这样无论 VirtualBox 用 BIOS 还是 EFI 固件都能启动；
#    混合 MBR 还让同一份 ISO 能直接写入 U 盘启动。
#
#  用法： bash /opt/lfOS/scripts/75-make-iso.sh [all|tree|efi|iso|gate]
#  说明： 不需要 root（xorriso/mtools 均可在用户态操作镜像文件）
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
OUT="$LFOS/build"
IMG="$OUT/img"
KOUT="$OUT/kernel"
LOGS="$OUT/logs"
ISO_ROOT="$OUT/iso-root"
ISO="$IMG/lfos.iso"
EFI_IMG="$IMG/efi.img"
VOLID="${LFOS_ISO_VOLID:-LFOS}"

mkdir -p "$IMG" "$LOGS"

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

# syslinux 资源路径（Ubuntu 包布局）
ISOLINUX_BIN=/usr/lib/ISOLINUX/isolinux.bin
ISOHDPFX=/usr/lib/ISOLINUX/isohdpfx.bin
SYSLINUX_MOD_BIOS=/usr/lib/syslinux/modules/bios
SYSLINUX_MOD_EFI64=/usr/lib/syslinux/modules/efi64

# ---------------------------------------------------------------------------
# 阶段 1：搭建 ISO 目录树
#
#  本版本（Full 系统）ISO 布局：
#     /boot/bzImage                 加固内核（含 EFI stub + 内置 cmdline）
#     /boot/rootfs.squashfs         完整基础系统（squashfs 只读根，含 overlay）
#     /boot/initramfs-lfos.cpio.gz  引导 initramfs（负责挂载 squashfs + switch_root）
#     /boot/initramfs-min.cpio.gz   最小 initramfs（Phase 4 版，救援备用）
#
#  与 Phase 4 最小 ISO 的区别：那个只启动到 BusyBox shell；
#  本版启动到完整系统（bash/coreutils/util-linux/openssh/nftables）。
# ---------------------------------------------------------------------------
do_tree() {
  hr "搭建 ISO 目录树"
  [ -f "$KOUT/bzImage" ] || die "缺少内核 $KOUT/bzImage"
  [ -f "$ISOLINUX_BIN" ] || die "缺少 isolinux.bin（apt install isolinux）"
  [ -f "$ISOHDPFX" ]     || die "缺少 isohdpfx.bin"

  # 优先用引导 initramfs + squashfs 完整系统；缺失则回退到最小 initramfs
  local BOOT_IRD="" SQFS=""
  if [ -f "$OUT/boot-initramfs.cpio.gz" ] && [ -f "$IMG/rootfs.squashfs" ]; then
    BOOT_IRD="$OUT/boot-initramfs.cpio.gz"
    SQFS="$IMG/rootfs.squashfs"
    log "使用完整系统模式（引导 initramfs + squashfs 根）"
  elif [ -f "$OUT/initramfs-lfos.cpio.gz" ]; then
    BOOT_IRD="$OUT/initramfs-lfos.cpio.gz"
    log "回退到最小系统模式（仅 BusyBox shell）"
  else
    die "既无引导 initramfs 也无最小 initramfs"
  fi

  log "清理旧目录"
  rm -rf "$ISO_ROOT"
  mkdir -p "$ISO_ROOT/isolinux" "$ISO_ROOT/boot" "$ISO_ROOT/etc" "$ISO_ROOT/EFI/BOOT"

  log "复制内核"
  cp -f "$KOUT/bzImage" "$ISO_ROOT/boot/bzImage"

  log "复制根文件系统与 initramfs"
  cp -f "$BOOT_IRD" "$ISO_ROOT/boot/initramfs-lfos.cpio.gz"
  if [ -n "$SQFS" ]; then
    cp -f "$SQFS" "$ISO_ROOT/boot/rootfs.squashfs"
    log "  squashfs 根: $(du -h "$ISO_ROOT/boot/rootfs.squashfs" | cut -f1)"
    # ISO 根目录也放一份：initramfs 会扫描块设备找 squashfs，
    # 放在 ISO 根便于某些固件/挂载方式下的识别
    cp -f "$SQFS" "$ISO_ROOT/rootfs.squashfs" 2>/dev/null || true
  fi
  # 若存在最小 initramfs，也带上作为救援选项
  if [ -f "$OUT/initramfs-lfos.cpio.gz" ] && \
     [ "$OUT/initramfs-lfos.cpio.gz" != "$BOOT_IRD" ]; then
    cp -f "$OUT/initramfs-lfos.cpio.gz" "$ISO_ROOT/boot/initramfs-min.cpio.gz"
  fi

  log "复制 isolinux 引导文件"
  cp -f "$ISOLINUX_BIN" "$ISO_ROOT/isolinux/"
  # 必需模块：ldlinux.c32 是核心；menu/libutil 供图形菜单；reboot/poweroff 供菜单项
  local m
  for m in ldlinux.c32 libutil.c32 menu.c32 reboot.c32 poweroff.c32 chain.c32; do
    [ -f "$SYSLINUX_MOD_BIOS/$m" ] && cp -f "$SYSLINUX_MOD_BIOS/$m" "$ISO_ROOT/isolinux/"
  done

  log "写入 isolinux 配置"
  cat > "$ISO_ROOT/isolinux/isolinux.cfg" <<'EOF'
# ============================================================================
#  lfOS (LumenFluxOS / 流光OS) BIOS 引导配置
# ============================================================================
SERIAL 0 115200
PROMPT 0
TIMEOUT 100
DEFAULT lfos
MENU TITLE  lfOS (LumenFluxOS) - 高性能 / 高安全 / 低占用

LABEL lfos
    MENU LABEL ^1) lfOS 完整系统 (加固内核 + squashfs 只读根)
    MENU DEFAULT
    KERNEL /boot/bzImage
    INITRD /boot/initramfs-lfos.cpio.gz
    # 不传 APPEND：直接复用内核编译期内置的命令行（CONFIG_CMDLINE）。
    #
    # 理由：未启用 CMDLINE_OVERRIDE 时，引导器参数是「追加」而非「覆盖」，
    #       两边都写会导致 cmdline 里出现重复的 initrd=/console= 等，
    #       日志里表现为一条超长的拼接命令行，难以排查。
    #       统一由内核内置，BIOS 与 UEFI 两条路径行为完全一致。
    #
    # 需要临时改参数时，可在此处加 APPEND（会被追加到内置参数之后，
    # 内核按「后者优先」解析同名参数，因此可用于覆盖）。

LABEL lfos-quiet
    MENU LABEL ^2) lfOS 静默启动
    KERNEL /boot/bzImage
    INITRD /boot/initramfs-lfos.cpio.gz
    APPEND quiet

LABEL lfos-debug
    MENU LABEL ^3) lfOS 调试模式 (详细日志 + 串口早期输出)
    KERNEL /boot/bzImage
    INITRD /boot/initramfs-lfos.cpio.gz
    APPEND loglevel=8 debug earlyprintk=serial,ttyS0,115200

LABEL lfos-rescue
    MENU LABEL ^4) lfOS 救援 shell (最小 initramfs，仅 BusyBox)
    KERNEL /boot/bzImage
    INITRD /boot/initramfs-min.cpio.gz
    APPEND initrd=\initramfs-min.cpio.gz rescue

LABEL reboot
    MENU LABEL ^R) 重启
    COM32 reboot.c32
EOF

  # EFI 侧配置（内容与 BIOS 版一致，放在 EFI 分区里）
  cp -f "$ISO_ROOT/isolinux/isolinux.cfg" "$ISO_ROOT/isolinux/syslinux.cfg"

  log "写入发行信息"
  cat > "$ISO_ROOT/etc/lfos-release" <<'EOF'
lfOS (LumenFluxOS / 流光OS)
高性能 / 高安全 / 低占用 服务器 Linux 系统
从零构建：LFS 流程 + KSPP 加固内核 + BusyBox 用户态
EOF
  # 内核加固说明随盘分发，便于运维查阅
  [ -f "$KOUT/config-report.txt" ] && \
    cp -f "$KOUT/config-report.txt" "$ISO_ROOT/boot/kernel-hardening-report.txt"
  [ -f "$KOUT/.config" ] && \
    cp -f "$KOUT/.config" "$ISO_ROOT/boot/kernel.config"

  cat > "$ISO_ROOT/README.txt" <<'EOF'
lfOS (LumenFluxOS / 流光OS) 可引导 ISO
======================================

启动方式
  BIOS : 从光盘/镜像启动，isolinux 菜单
  UEFI : 自动识别 efiboot.img 中的 EFI 引导器

串口日志
  内核参数已将 ttyS0 设为主控制台，配合虚拟机串口重定向
  （VirtualBox: --uart1 0x3F8 4 --uartmode1 file <文件>）可采集完整启动日志。

写入 U 盘
  本 ISO 为混合镜像，可直接写入 U 盘：
    Linux :  dd if=lfos.iso of=/dev/sdX bs=4M status=progress oflag=sync
    Windows: 用 Rufus（选择 DD 模式写入）

内含
  /boot/bzImage                 加固内核 (Linux 6.15.4-lfos)
  /boot/initramfs-lfos.cpio.gz  最小根文件系统
  /boot/kernel.config           内核配置全文
  /boot/kernel-hardening-report.txt  安全检查报告
EOF

  log "ISO 目录树完成: $(du -sh "$ISO_ROOT" | cut -f1)"
  find "$ISO_ROOT" -maxdepth 2 | sed "s|$ISO_ROOT|  |" | sort | head -25
}

# ---------------------------------------------------------------------------
# 阶段 2：制作 UEFI 引导软盘镜像
# ---------------------------------------------------------------------------
do_efi() {
  hr "制作 UEFI 引导镜像（内核 EFI stub，零引导器）"
  # -----------------------------------------------------------------------
  #  方案：直接用 Linux 内核自带的 EFI stub 作为 UEFI 引导器。
  #
  #  为什么不用 syslinux.efi / GRUB：
  #    - syslinux 6.04 的 EFI 引导器在 VirtualBox 7.2 EFI 固件下直接抛
  #      "X64 Exception Type - 06(#UD - Invalid Opcode)"，无法启动；
  #    - GRUB 可用但要额外 3~5MB 模块，扩大引导链攻击面。
  #
  #  内核 EFI stub 的优势（契合三宗旨）：
  #    - 零引导器：内核即引导器，消除引导器这一独立攻击面
  #    - 体积最小：不增加任何引导代码
  #    - 可 Secure Boot：直接对内核签名即可（Phase 5 落地）
  #
  #  ⚠ 关键约束（踩过的坑）：
  #    内核命令行必须「编译期内置」（CONFIG_CMDLINE_BOOL + CONFIG_CMDLINE）。
  #    不要试图用 `objcopy --add-section .cmdline=...` 事后附加 ——
  #    bzImage 是自解压格式，其头部记录了压缩段的偏移，objcopy 加段会破坏
  #    该布局，固件加载后报：
  #        EFI stub: ERROR: Failed to decompress kernel
  #        BdsDxe: ... Load Error
  #    故这里直接使用原始 bzImage，不做任何后处理。
  # -----------------------------------------------------------------------
  [ -f "$KOUT/bzImage" ] || die "缺少内核 $KOUT/bzImage"

  # 校验内核确实带 EFI stub（PE 头以 MZ 开头）
  if [ "$(xxd -l 2 -p "$KOUT/bzImage")" != "4d5a" ]; then
    die "bzImage 缺少 PE/MZ 头 —— 内核未启用 CONFIG_EFI_STUB，无法直接 EFI 引导"
  fi
  log "内核含 EFI stub（PE 头校验通过）"

  # 校验内置 cmdline 已编译进内核（EFI 引导时无引导器传参，必须内置）
  if [ -f "$KOUT/.config" ] && grep -q '^CONFIG_CMDLINE_BOOL=y' "$KOUT/.config"; then
    log "内核已内置命令行: $(grep '^CONFIG_CMDLINE=' "$KOUT/.config" | head -1 | cut -c1-100)…"
  else
    log "警告：内核未启用 CONFIG_CMDLINE_BOOL，EFI 引导时可能缺少 root=/initrd= 参数"
  fi

  # UEFI 固件固定查找 /EFI/BOOT/BOOTX64.EFI —— 直接放内核
  local EFI_BOOTX64="$IMG/BOOTX64.EFI"
  cp -f "$KOUT/bzImage" "$EFI_BOOTX64"
  log "BOOTX64.EFI = 内核本体: $(du -h "$EFI_BOOTX64" | cut -f1)"
  [ "$(xxd -l 2 -p "$EFI_BOOTX64")" = "4d5a" ] || die "BOOTX64.EFI 丢失 PE 头"

  # --- 制作 EFI 系统分区镜像（ESP）---
  # 需容纳：内核(~9.4MB) + 引导 initramfs(1.2MB) + squashfs 根(~31MB)
  # 因此 ESP 从 16MiB 扩到 64MiB。若 squashfs 更大则按需再放大。
  local esp_mb=64
  local need_mb=0
  [ -f "$KOUT/bzImage" ] && need_mb=$((need_mb + $(du -m "$KOUT/bzImage" | cut -f1)))
  [ -f "$ISO_ROOT/boot/initramfs-lfos.cpio.gz" ] && \
    need_mb=$((need_mb + $(du -m "$ISO_ROOT/boot/initramfs-lfos.cpio.gz" | cut -f1)))
  [ -f "$ISO_ROOT/boot/rootfs.squashfs" ] && \
    need_mb=$((need_mb + $(du -m "$ISO_ROOT/boot/rootfs.squashfs" | cut -f1)))
  # 预留 4MB 余量并向上取整到 16 的倍数
  need_mb=$((need_mb + 4))
  esp_mb=$(( (need_mb / 16 + 1) * 16 ))
  [ "$esp_mb" -lt 32 ] && esp_mb=32

  rm -f "$EFI_IMG"
  log "创建 ${esp_mb}MiB FAT16 EFI 系统分区（内容约需 ${need_mb}MiB）"
  dd if=/dev/zero of="$EFI_IMG" bs=1M count="$esp_mb" status=none || die "创建 EFI 镜像失败"
  if mkfs.vfat -F 16 -n LFOSEFI "$EFI_IMG" > "$LOGS/iso-mkfs-efi.log" 2>&1; then
    log "FAT16 格式化成功"
  else
    # 注：mkfs.fat 对 FAT16 有最小簇数约束，过小会被拒（"too small or too large"）
    log "FAT16 失败，回退 FAT12（8MiB）"
    rm -f "$EFI_IMG"
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=8 status=none || die "创建 EFI 镜像失败"
    mkfs.vfat -n LFOSEFI "$EFI_IMG" >> "$LOGS/iso-mkfs-efi.log" 2>&1 \
      || { cat "$LOGS/iso-mkfs-efi.log"; die "mkfs.vfat 失败"; }
    log "FAT12 格式化成功"
  fi

  # ESP 结构（UEFI 固件固定查找 /EFI/BOOT/BOOTX64.EFI）：
  #   /EFI/BOOT/BOOTX64.EFI           内核（含内置 cmdline）
  #   /initramfs-lfos.cpio.gz         initrd（路径与内置 cmdline 的 initrd= 对应）
  #   /rootfs.squashfs                完整根文件系统（若为完整系统模式）
  mmd -i "$EFI_IMG" ::/EFI ::/EFI/BOOT 2>>"$LOGS/iso-mtools.log" || die "mmd 失败"
  mcopy -i "$EFI_IMG" "$EFI_BOOTX64" ::/EFI/BOOT/BOOTX64.EFI 2>>"$LOGS/iso-mtools.log" \
    || die "写入 BOOTX64.EFI 失败"
  mcopy -i "$EFI_IMG" "$ISO_ROOT/boot/initramfs-lfos.cpio.gz" ::/initramfs-lfos.cpio.gz 2>>"$LOGS/iso-mtools.log" \
    || die "写入 initramfs 失败"
  if [ -f "$ISO_ROOT/boot/rootfs.squashfs" ]; then
    log "写入 squashfs 根到 ESP（$(du -h "$ISO_ROOT/boot/rootfs.squashfs" | cut -f1)）"
    mcopy -i "$EFI_IMG" "$ISO_ROOT/boot/rootfs.squashfs" ::/rootfs.squashfs 2>>"$LOGS/iso-mtools.log" \
      || die "写入 squashfs 失败"
  fi

  log "EFI 分区内容:"
  mdir -i "$EFI_IMG" ::/ 2>/dev/null | sed 's/^/       /' | head -8
  mdir -i "$EFI_IMG" ::/EFI/BOOT/ 2>/dev/null | sed 's/^/       /' | head -8

  log "EFI 镜像完成: $(du -h "$EFI_IMG" | cut -f1)"

  # 同时放置到 ISO 树 /EFI/BOOT/：部分固件直接扫描 ISO9660 的该路径
  if [ -d "$ISO_ROOT/EFI/BOOT" ]; then
    cp -f "$EFI_BOOTX64" "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI"
    # initramfs 用 ISO 树里那份（引导 initramfs）
    if [ -f "$ISO_ROOT/boot/initramfs-lfos.cpio.gz" ]; then
      cp -f "$ISO_ROOT/boot/initramfs-lfos.cpio.gz" "$ISO_ROOT/initramfs-lfos.cpio.gz"
    fi
    log "已放置到 ISO 树 /EFI/BOOT/ 与 /initramfs-lfos.cpio.gz"
  fi

  # EFI 分区镜像需内嵌进 ISO 树（xorriso 以 el torito 方式引用）
  cp -f "$EFI_IMG" "$ISO_ROOT/boot/efi.img"
}

# ---------------------------------------------------------------------------
# 阶段 3：生成 ISO
# ---------------------------------------------------------------------------
do_iso() {
  hr "生成可引导 ISO"
  [ -d "$ISO_ROOT/isolinux" ] || die "ISO 目录树不存在，请先执行 tree"
  [ -f "$ISO_ROOT/boot/efi.img" ] || die "缺少 EFI 镜像，请先执行 efi"

  rm -f "$ISO"

  # xorriso 的 mkisofs 兼容模式：
  #   -b isolinux.bin  指定 BIOS 引导映像（el torito no-emulation）
  #   -isohybrid-mbr   写入混合 MBR，使 ISO 可 dd 到 U 盘后从 U 盘启动
  #   -eltorito-alt-boot -e boot/efi.img  追加 UEFI 引导项
  #   -isohybrid-gpt-basdat  生成 GPT 分区项，兼顾 UEFI 的 U 盘启动
  if xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "$VOLID" \
        -publisher "lfOS (LumenFluxOS) Project" \
        -preparer "lfOS build system" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "$ISOHDPFX" \
        -eltorito-alt-boot \
        -e boot/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -o "$ISO" \
        "$ISO_ROOT" > "$LOGS/iso-xorriso.log" 2>&1; then
    log "ISO 生成成功: $(du -h "$ISO" | cut -f1)"
  else
    tail -20 "$LOGS/iso-xorriso.log"
    die "xorriso 失败（日志 $LOGS/iso-xorriso.log）"
  fi
}

# ---------------------------------------------------------------------------
# 阶段 4：门禁
# ---------------------------------------------------------------------------
do_gate() {
  hr "ISO 门禁"
  local pass=0 fail=0
  chk() {
    # 临时关闭 pipefail：检查表达式里的 `... | grep -q` 会让上游命令
    # 收到 SIGPIPE（退出码 141），pipefail 会把这次「正常提前退出」误判为失败。
    local rc
    set +o pipefail
    eval "$2" >/dev/null 2>&1
    rc=$?
    set -o pipefail
    if [ "$rc" -eq 0 ]; then
      printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else
      printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1))
    fi
  }

  chk "ISO 文件已生成"                "[ -f '$ISO' ]"
  chk "EFI 引导镜像已生成"            "[ -f '$EFI_IMG' ]"
  chk "ISO 体积 > 5MB（内容完整）"    "[ \$(stat -c%s '$ISO' 2>/dev/null || echo 0) -gt 5242880 ]"

  # El Torito 引导记录：0x8000 偏移处应能找到引导目录（xorriso -report_el_torito）
  chk "BIOS El Torito 引导记录存在"   "xorriso -indev '$ISO' -report_el_torito plain 2>&1 | grep -qi 'El Torito'"
  chk "含 UEFI 引导项 (efi.img)"       "xorriso -indev '$ISO' -report_el_torito plain 2>&1 | grep -qi 'efi.img\|platform id.*efi\|0xef'"
  chk "混合 MBR 分区表存在 (isohybrid)" "xorriso -indev '$ISO' -report_system_area plain 2>&1 | grep -qi 'MBR\|isohybrid'"

  echo
  echo "  ISO 内容清单:"
  xorriso -indev "$ISO" -find / -type f -exec lsdl -- 2>/dev/null | \
    awk '{printf "    %-46s %s\n", $NF, $(NF-3)}' | head -20

  echo
  echo "  El Torito 引导项:"
  xorriso -indev "$ISO" -report_el_torito plain 2>/dev/null | sed 's/^/    /' | head -12

  echo
  echo "  体积:"
  printf '    %-32s %s\n' "ISO" "$(du -h "$ISO" 2>/dev/null | cut -f1)"
  printf '    %-32s %s\n' "  └ bzImage" "$(du -h "$ISO_ROOT/boot/bzImage" 2>/dev/null | cut -f1)"
  printf '    %-32s %s\n' "  └ initramfs" "$(du -h "$ISO_ROOT/boot/initramfs-lfos.cpio.gz" 2>/dev/null | cut -f1)"
  printf '    %-32s %s\n' "  └ efi.img" "$(du -h "$EFI_IMG" 2>/dev/null | cut -f1)"

  # 清单
  {
    echo "lfOS ISO manifest"
    echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "iso: $ISO  size=$(stat -c%s "$ISO" 2>/dev/null) bytes"
    echo "sha256(iso): $(sha256sum "$ISO" 2>/dev/null | cut -d' ' -f1)"
    echo "efi_img: $EFI_IMG  size=$(stat -c%s "$EFI_IMG" 2>/dev/null) bytes"
    echo "boot: BIOS(isolinux) + UEFI(kernel EFI stub, no bootloader)"
    echo "hybrid: yes (dd-able to USB stick)"
    echo "volid: $VOLID"
  } > "$IMG/lfos-iso.manifest"
  printf '  \033[32m[PASS]\033[0m 清单已写入 %s\n' "$IMG/lfos-iso.manifest"; pass=$((pass+1))

  echo
  echo "============================================================"
  printf '  ISO 门禁: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ 可引导 ISO 就绪\033[0m\n' \
                    || printf '  \033[1;31m✗ 存在问题\033[0m\n'
  echo "============================================================"
  return "$fail"
}

case "${1:-all}" in
  tree) do_tree ;;
  efi)  do_efi ;;
  iso)  do_iso ;;
  gate) do_gate ;;
  all)  do_tree; do_efi; do_iso; do_gate ;;
  *) die "未知参数: $1（可用 all|tree|efi|iso|gate）" ;;
esac
