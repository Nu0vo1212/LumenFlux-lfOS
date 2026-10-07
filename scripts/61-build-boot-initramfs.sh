#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 4e - 生成引导 initramfs（squashfs + overlay + switch_root）
#
#  职责：找到真正的根文件系统 → 挂载 → switch_root 过去
#
#  支持的根形态（按探测顺序）：
#    1) 内核参数 root=/dev/xxx                 显式指定，优先级最高
#    2) ISO9660 内的 rootfs.squashfs           Live 启动（只读根 + 可写层）
#    3) 裸 squashfs 设备（整设备即 squashfs）   U 盘安装盘
#    4) ext4 且含 /sbin/init 或 /usr/bin/bash   磁盘安装（可写根）
#
#  踩过的两个坑（务必记住）：
#    a) 早期版本直接扫描块设备找 squashfs magic("hsqs")。但 ISO 启动时
#       /dev/sr0 是 ISO9660 文件系统，squashfs 是「ISO 里的一个文件」，
#       不是整个设备 → magic 永远匹配不上 → 直接落到救援 shell。
#       正确做法：先把设备挂成 iso9660，再在挂载点内找 *.squashfs 文件，
#       以 loop 方式挂载该文件。
#    b) 内核必须启用 CONFIG_SQUASHFS。x86_64_defconfig 默认是关闭的，
#       而裁剪 defconfig 时若只写「不要什么」很容易漏掉它；
#       漏了的后果是「挂载静默失败」，日志里没有任何直白提示。
#
#  用法： bash /opt/lfOS/scripts/61-build-boot-initramfs.sh [all|tree|pack|gate]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
OUT="$LFOS/build"
LOGS="$OUT/logs"
IRD="$OUT/boot-initramfs"

export PATH="$LFOS/build/tools/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$LOGS"

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

do_tree() {
  hr "构建引导 initramfs"
  [ -f "$OUT/busybox" ] || die "缺少 $OUT/busybox"

  rm -rf "$IRD"
  mkdir -p "$IRD/bin" "$IRD/sbin" "$IRD/etc" "$IRD/dev" "$IRD/proc" \
           "$IRD/sys" "$IRD/tmp" "$IRD/run" "$IRD/mnt/ro" "$IRD/mnt/rw" \
           "$IRD/mnt/iso" "$IRD/mnt/root" "$IRD/newroot"

  log "安装 BusyBox"
  cp -f "$OUT/busybox" "$IRD/bin/busybox"
  chmod 755 "$IRD/bin/busybox"
  local app n=0
  while read -r app; do
    [ -n "$app" ] || continue
    [ "$app" = "busybox" ] && continue
    ln -sf /bin/busybox "$IRD/bin/$app"; n=$((n+1))
  done < <("$IRD/bin/busybox" --list 2>/dev/null)
  log "applet 链接: $n 个"

  log "写入 /init"
  cat > "$IRD/init" <<'INITEOF'
#!/bin/busybox sh
# =============================================================================
#  lfOS 引导 init —— PID 1
# =============================================================================
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc     proc     /proc 2>/dev/null
mount -t sysfs    sysfs    /sys  2>/dev/null
mount -t devtmpfs devtmpfs /dev  2>/dev/null
mount -t tmpfs    tmpfs    /run  2>/dev/null
mount -t tmpfs    tmpfs    /tmp  2>/dev/null
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts 2>/dev/null

[ -c /dev/console ] || mknod -m 600 /dev/console c 5 1 2>/dev/null
[ -c /dev/null ]    || mknod -m 666 /dev/null    c 1 3 2>/dev/null
[ -c /dev/ttyS0 ]   || mknod -m 660 /dev/ttyS0   c 4 64 2>/dev/null

CONSOLE=/dev/console
[ -c "$CONSOLE" ] || CONSOLE=/dev/ttyS0
# 输出策略：**只写一次，优先写 /dev/console**。
#
# 这里踩过两个方向相反的坑，都值得记下来：
#   A) 最初写成「双写」：既写 /dev/console 又写 stdout。
#      后果：每行日志出现两遍；输出量大时还可能填满 tty 缓冲造成阻塞。
#   B) 随后改成「只写 stdout」，理由是内核已把 PID 1 的 stdout 指向 console。
#      后果：switch_root 之前一切正常，switch_root 之后**完全没有输出**——
#      证明切换根之后 stdout 不保证还能送达控制台。这次的表现极具误导性：
#      日志干干净净停在「切换到新根」，既无 panic 也无报错，看着像内核挂起，
#      实际只是打印丢了，系统很可能已经在跑。
#
# 结论：显式写控制台设备最可靠，且只写一次以避免重复与阻塞。
say() { printf '%s\n' "$*" > "$CONSOLE" 2>/dev/null || printf '%s\n' "$*"; }

say ""
say "=============================================================="
say "  lfOS (LumenFluxOS / 流光OS) 引导中"
say "=============================================================="

KCMD=$(cat /proc/cmdline 2>/dev/null)
say "[lfOS] cmdline: $KCMD"
# 取内核命令行参数的值。
# 用 tail -1 而不是 head -1：cmdline 里同名参数可能出现多次（内置 cmdline
# 与引导器 APPEND 追加的会并存），内核的语义是「后者覆盖前者」。
# 实测踩到：内置的 root=/dev/ram0 排在前面，引导器追加的 root=/dev/sda1
# 在后面；若取第一个就会拿到 ram0，与内核实际采用的根不一致。
get_param() { printf '%s' "$KCMD" | tr ' ' '\n' | grep "^$1=" | tail -1 | cut -d= -f2-; }

RO_DIR=""
RW_DIR=""

# ---------------------------------------------------------------------------
#  用 losetup 手动挂载 squashfs 文件
#
#  踩过的坑：BusyBox 的 mount **不支持 `-o loop` 自动关联**！
#  那是 util-linux mount 的功能。BusyBox 只会把 "loop" 当作普通挂载参数
#  原样传给文件系统，于是内核报：
#      squashfs: Unknown parameter 'loop'
#  表现就是「找到了 squashfs 文件却挂不上」，日志还误导人以为内核不支持 squashfs。
#
#  正确做法：两步走
#      losetup <空闲设备> <文件>       # 先关联
#      mount -t squashfs -o ro <设备> <挂载点>
# ---------------------------------------------------------------------------
mount_squashfs_file() {
  local img="$1" target="$2" loopdev
  [ -f "$img" ] || { say "[lfOS] 文件不存在: $img"; return 1; }

  loopdev=$(losetup -f 2>/dev/null)
  if [ -z "$loopdev" ]; then
    say "[lfOS] 无空闲 loop 设备（检查 /dev/loop* 是否存在）"
    return 1
  fi
  say "[lfOS] 关联 loop: $loopdev <- $img"
  if ! losetup "$loopdev" "$img" 2>/dev/null; then
    say "[lfOS] losetup 关联失败: $img"
    return 1
  fi
  say "[lfOS] losetup 成功，开始挂载 squashfs…"
  if mount -t squashfs -o ro "$loopdev" "$target" 2>/dev/null; then
    say "[lfOS] squashfs 已挂载: $loopdev -> $target"
    return 0
  fi
  say "[lfOS] squashfs 挂载失败（$loopdev）"
  losetup -d "$loopdev" 2>/dev/null
  return 1
}

# ---------------------------------------------------------------------------
#  根类型标记
#    ext4     → 磁盘安装的系统盘，可直接可写挂载，改动持久
#    squashfs → Live 只读根，需要 overlay 提供可写层
#    dir      → 目录形式的根（少见）
# ---------------------------------------------------------------------------
RO_TYPE=""

# 目录看起来是不是一个可用的 lfOS 根
is_lfos_root() {
  [ -x "$1/sbin/init" ] || [ -x "$1/usr/bin/bash" ]
}

# ---------------------------------------------------------------------------
#  尝试把设备当作「持久系统盘」：ext4 + 可写挂载
#
#  这是磁盘安装模式。与 Live 模式的关键区别是**可写**：
#  挂载时不带 -o ro，switch_root 后根可直接写，改动得以保留。
# ---------------------------------------------------------------------------
try_ext4_root() {
  local dev="$1" cand
  mount -t ext4 "$dev" /mnt/root 2>/dev/null || return 1

  if is_lfos_root /mnt/root; then
    say "[lfOS] $dev 是 ext4 系统盘 → 可写持久根"
    RO_DIR=/mnt/root
    RO_TYPE=ext4
    return 0
  fi

  # 不是根文件系统，但可能内含 squashfs 镜像
  for cand in /mnt/root/rootfs.squashfs /mnt/root/boot/rootfs.squashfs; do
    if mount_squashfs_file "$cand" /mnt/ro; then
      say "[lfOS] 从 ext4 内挂载 squashfs: $cand"
      RO_DIR=/mnt/ro
      RO_TYPE=squashfs
      return 0
    fi
  done

  umount /mnt/root 2>/dev/null
  return 1
}

# ---------------------------------------------------------------------------
#  尝试把设备当作「Live 只读根」：ISO9660 内的 squashfs，或裸 squashfs 设备
# ---------------------------------------------------------------------------
try_live_root() {
  local dev="$1" cand magic

  # --- ISO9660：在挂载点内查找 squashfs 文件 ---
  if mount -t iso9660 -o ro "$dev" /mnt/iso 2>/dev/null; then
    say "[lfOS] $dev 挂载为 ISO9660"
    for cand in /mnt/iso/rootfs.squashfs /mnt/iso/boot/rootfs.squashfs \
                /mnt/iso/live/rootfs.squashfs; do
      if [ -f "$cand" ]; then
        say "[lfOS] 找到 squashfs: $cand"
        if mount_squashfs_file "$cand" /mnt/ro; then
          RO_DIR=/mnt/ro
          RO_TYPE=squashfs
          return 0
        fi
      fi
    done
    if is_lfos_root /mnt/iso; then
      say "[lfOS] ISO 内为目录形式根"
      RO_DIR=/mnt/iso
      RO_TYPE=dir
      return 0
    fi
    say "[lfOS] ISO 内容一览："
    ls /mnt/iso 2>/dev/null | head -20 | while read -r l; do say "    $l"; done
    umount /mnt/iso 2>/dev/null
  fi

  # --- 裸 squashfs 设备 ---
  magic=$(dd if="$dev" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$magic" = "68737173" ]; then
    say "[lfOS] $dev 是裸 squashfs 设备"
    if mount -t squashfs -o ro "$dev" /mnt/ro 2>/dev/null; then
      RO_DIR=/mnt/ro
      RO_TYPE=squashfs
      return 0
    fi
  fi

  return 1
}

# ---------------------------------------------------------------------------
#  1) 内核参数显式指定 root=
# ---------------------------------------------------------------------------
RP=$(get_param root)
case "$RP" in
  # /dev/ram0 是 initramfs 场景的习惯写法（本系统用 switch_root），跳过
  /dev/ram*) : ;;
  /dev/*)
    say "[lfOS] 内核参数指定根: $RP"
    try_ext4_root "$RP" || try_live_root "$RP" || say "[lfOS] $RP 上没有找到根"
    ;;
esac

# ---------------------------------------------------------------------------
#  2) 第一轮：优先寻找「持久系统盘」（ext4 + 含 init）
#
#  为什么 ext4 优先于 ISO 内的 squashfs：
#    当虚拟机/物理机既有安装好的系统盘、又插着安装 ISO 时，用户期望的是
#    启动那个**已安装的系统**（改动可保存），而不是回到 Live 环境。
#    早期实现按设备名顺序扫描（/dev/sr0 在前），结果永远进 Live 模式，
#    安装好的系统反而起不来 —— 这就是分两轮探测的原因。
# ---------------------------------------------------------------------------
if [ -z "$RO_DIR" ]; then
  for d in /dev/sda1 /dev/sda2 /dev/sda3 /dev/sda \
           /dev/sdb1 /dev/sdb \
           /dev/vda1 /dev/vda \
           /dev/nvme0n1p1 /dev/nvme0n1; do
    [ -b "$d" ] || continue
    if try_ext4_root "$d"; then
      say "[lfOS] 在 $d 上找到持久系统盘"
      break
    fi
  done
fi

# ---------------------------------------------------------------------------
#  3) 第二轮：寻找 Live 根（ISO 光盘 / 裸 squashfs 设备）
# ---------------------------------------------------------------------------
if [ -z "$RO_DIR" ]; then
  say "[lfOS] 未发现系统盘，进入 Live 模式查找…"
  for d in /dev/sr0 /dev/sda1 /dev/sda /dev/sdb1 /dev/sdb \
           /dev/vda1 /dev/vda /dev/nvme0n1p1 /dev/nvme0n1; do
    [ -b "$d" ] || continue
    if try_live_root "$d"; then
      say "[lfOS] 在 $d 上找到 Live 根"
      break
    fi
  done
fi

if [ -z "$RO_DIR" ]; then
  say ""
  say "=============================================================="
  say "  [错误] 未找到可用的根文件系统"
  say ""
  say "  排查建议："
  say "    1) 内核文件系统支持： zcat /proc/config.gz | grep SQUASHFS"
  say "    2) 手动挂载光盘：     mount -t iso9660 -o ro /dev/sr0 /mnt/iso"
  say "    3) 查看光盘内容：     ls /mnt/iso"
  say "    4) 手动挂 squashfs（BusyBox 不支持 -o loop，需两步）："
  say "         losetup /dev/loop0 /mnt/iso/rootfs.squashfs"
  say "         mount -t squashfs -o ro /dev/loop0 /mnt/ro"
  say "=============================================================="
else
  # -------------------------------------------------------------------------
  # -------------------------------------------------------------------------
  #  3) 决定最终根：ext4 直接可写；只读根则叠加 overlay
  # -------------------------------------------------------------------------
  if [ "$RO_TYPE" = "ext4" ]; then
    # 磁盘安装模式：根本身就是可写的 ext4，直接使用。
    # 不再叠加 overlay —— 那会把改动导向内存层，反而失去持久性。
    say "[lfOS] 使用可写系统盘（改动将被保留）"
    RW_DIR="$RO_DIR"
  else
  #  以下为 Live 模式：只读根 + 可写层
  #
  #  踩过的坑（关键）：可写层必须放在 tmpfs 上，不能直接用 initramfs 的根。
  #
  #  原因：initramfs 解压后的根是 rootfs（ramfs 类型）。ramfs 是极简内存
  #  文件系统，不支持 overlayfs 所需的目录项类型（d_type）与扩展属性语义。
  #  早期实现只 `mkdir /mnt/rw/upper` 而未挂载 tmpfs，于是 overlay 挂载时
  #  内核在准备 upper 层的过程中卡住（mount 系统调用不返回），
  #  表现为日志停在「内存可写层」这一行之后再也没有输出，极难定位。
  #
  #  正确做法：显式 mount -t tmpfs 到 upper 所在目录。
  # -------------------------------------------------------------------------
  UPPER=""
  # 先找磁盘上的持久分区（若有则改动可保留）
  for p in /dev/sda3 /dev/vda3 /dev/nvme0n1p3 /dev/sdb3; do
    [ -b "$p" ] || continue
    if mount -t ext4 "$p" /mnt/rw 2>/dev/null; then
      mkdir -p /mnt/rw/upper /mnt/rw/work 2>/dev/null
      if [ -d /mnt/rw/upper ]; then
        UPPER=/mnt/rw
        say "[lfOS] 持久可写层: $p（改动将被保留）"
        break
      fi
      umount /mnt/rw 2>/dev/null
    fi
  done

  # 没有持久分区则用 tmpfs 作内存可写层
  if [ -z "$UPPER" ]; then
    mkdir -p /mnt/rw 2>/dev/null
    if mount -t tmpfs -o mode=0755 tmpfs /mnt/rw 2>/dev/null; then
      mkdir -p /mnt/rw/upper /mnt/rw/work 2>/dev/null
      UPPER=/mnt/rw
      say "[lfOS] 内存可写层（tmpfs，Live 模式：重启后还原）"
    else
      say "[lfOS] tmpfs 挂载失败，无法提供可写层"
    fi
  fi

  mkdir -p /newroot
  if [ -n "$UPPER" ]; then
    # 注意这里不加 2>/dev/null：overlay 失败原因必须可见，
    # 否则只会看到「卡住」而拿不到任何线索。
    if mount -t overlay overlay \
         -o "lowerdir=$RO_DIR,upperdir=$UPPER/upper,workdir=$UPPER/work" \
         /newroot; then
      say "[lfOS] overlayfs 已挂载（只读根 + 可写层）"
      RW_DIR=/newroot
    else
      say "[lfOS] overlayfs 挂载失败，回退为只读根"
      RW_DIR="$RO_DIR"
    fi
  else
    say "[lfOS] 无可写层，使用只读根"
    RW_DIR="$RO_DIR"
  fi
  fi
fi

# ---------------------------------------------------------------------------
#  4) switch_root
# ---------------------------------------------------------------------------
if [ -n "$RW_DIR" ]; then
  if [ -x "$RW_DIR/sbin/init" ] || [ -x "$RW_DIR/init" ]; then
    INITP=/sbin/init
    [ -x "$RW_DIR/sbin/init" ] || INITP=/init
    say "[lfOS] 切换到新根: $RW_DIR  (init: $INITP)"

    mkdir -p "$RW_DIR/dev" "$RW_DIR/proc" "$RW_DIR/sys" "$RW_DIR/run" 2>/dev/null
    for m in dev proc sys run; do
      if mount --move "/$m" "$RW_DIR/$m" 2>/dev/null; then
        say "[lfOS]   已迁移 /$m"
      else
        say "[lfOS]   /$m 迁移失败（将继续，但新根可能缺设备节点）"
      fi
    done

    # -----------------------------------------------------------------------
    #  切换前的体检：把「新根是否真的能启动」变成可观测事实。
    #
    #  此前两次失败都表现为「日志停在切换到新根，无 panic 无报错」，
    #  完全无法区分是 switch_root 失败、新根 init 缺失、还是仅仅打印丢失。
    #  与其猜，不如在切换前把关键条件逐条打出来。
    # -----------------------------------------------------------------------
    say "[lfOS] 切换前体检："
    say "[lfOS]   init 可执行 : $([ -x "$RW_DIR$INITP" ] && echo 是 || echo 否)"
    say "[lfOS]   /dev/console: $([ -c "$RW_DIR/dev/console" ] && echo 存在 || echo 缺失)"
    say "[lfOS]   /dev/null   : $([ -c "$RW_DIR/dev/null" ] && echo 存在 || echo 缺失)"
    say "[lfOS]   bash        : $([ -x "$RW_DIR/usr/bin/bash" ] && echo 存在 || echo 缺失)"
    # 真正在当前新根里跑一条命令，验证「能执行」
    if [ -x "$RW_DIR/usr/bin/bash" ]; then
      BASHOUT=$(chroot "$RW_DIR" /usr/bin/bash -c 'echo BASH_OK; echo -n "  rootfs_fstype="; stat -f -c %T /' 2>&1)
      say "[lfOS]   chroot 测试: $BASHOUT"
    fi
    # 试运行新根的 init 前几行（只做语法检查，不真正执行）
    if [ -x "$RW_DIR/usr/bin/bash" ] && [ -f "$RW_DIR$INITP" ]; then
      if chroot "$RW_DIR" /usr/bin/bash -n "$INITP" >/dev/null 2>&1; then
        say "[lfOS]   init 语法   : OK"
      else
        say "[lfOS]   init 语法   : 有错误！"
      fi
    fi

    exec switch_root "$RW_DIR" "$INITP"
    say "[lfOS] switch_root 返回了（异常）：$?"
  else
    say "[lfOS] 根 $RW_DIR 内缺 init（无 /sbin/init 也无 /init）"
    say "[lfOS] 根内容："
    ls "$RW_DIR" 2>/dev/null | head -15 | while read -r l; do say "    $l"; done
  fi
fi

# ---------------------------------------------------------------------------
#  5) 救援 shell（PID 1 常驻）
# ---------------------------------------------------------------------------
say ""
say "[lfOS] 进入救援 shell"
say "    mount -t iso9660 -o ro /dev/sr0 /mnt/iso"
say "    losetup /dev/loop0 /mnt/iso/rootfs.squashfs   # BusyBox 不支持 -o loop"
say "    mount -t squashfs -o ro /dev/loop0 /mnt/ro"
say "    switch_root /mnt/ro /sbin/init"
say ""
export PS1='lfos-rescue:\w# '
export HOME=/root
cd / 2>/dev/null

while : ; do
  if [ -c /dev/console ]; then
    PS1='lfos-rescue:\w# ' sh -i < /dev/console > /dev/console 2>&1
  else
    PS1='lfos-rescue:\w# ' sh -i
  fi
  say ""
  say "[lfOS] shell 退出，2 秒后重开；poweroff -f 关机"
  sleep 2
done
INITEOF
  chmod 755 "$IRD/init"

  printf 'root:x:0:0:root:/root:/bin/sh\n' > "$IRD/etc/passwd"
  printf 'root:x:0:\n' > "$IRD/etc/group"
  printf 'lfos\n' > "$IRD/etc/hostname"
  printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 lfos\n' > "$IRD/etc/hosts"

  log "引导 initramfs 目录树完成"
}

do_pack() {
  hr "打包引导 initramfs"
  [ -f "$IRD/init" ] || die "缺少 $IRD/init"
  [ -x "$IRD/bin/busybox" ] || die "缺少 busybox"
  cd "$IRD" || die "cd 失败"
  local out="$OUT/boot-initramfs.cpio.gz"
  find . -print0 | LC_ALL=C sort -z | \
    cpio --null -o --format=newc --owner=0:0 --reproducible \
    > "$OUT/boot-initramfs.cpio" 2>"$LOGS/boot-initramfs-cpio.log" || die "cpio 失败"
  gzip -9 -f -n "$OUT/boot-initramfs.cpio" || die "gzip 失败"
  mv -f "$OUT/boot-initramfs.cpio.gz" "$out" 2>/dev/null || true
  log "打包完成: $(du -h "$out" | cut -f1)"
  cd "$LFOS"
}

do_gate() {
  hr "引导 initramfs 门禁"
  local pass=0 fail=0
  ck() {
    if eval "$2" >/dev/null 2>&1; then
      printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else
      printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1))
    fi
  }
  local cpio="$OUT/boot-initramfs.cpio.gz"
  ck "引导 initramfs 已生成"          "[ -f '$cpio' ]"
  ck "/init 含 switch_root"            "grep -q 'switch_root' '$IRD/init'"
  ck "/init 含 overlayfs 支持"         "grep -q 'overlay' '$IRD/init'"
  ck "/init 含 ISO9660 挂载探测"       "grep -q 'mount -t iso9660' '$IRD/init'"
  ck "/init 含 squashfs 文件查找"      "grep -q 'rootfs.squashfs' '$IRD/init'"
  ck "/init 含裸 squashfs magic 检测"  "grep -q '68737173' '$IRD/init'"
  ck "/init 含 ext4 根支持"            "grep -q 'mount -t ext4' '$IRD/init'"
  ck "/init 含 PID1 兜底循环"          "grep -q 'while : ; do' '$IRD/init'"
  ck "applet 链接目标正确"             "[ \$(find '$IRD/bin' -type l ! -lname '/bin/busybox' | wc -l) -eq 0 ]"
  # 回归检查：必须用 losetup 两步挂载，而非 BusyBox 不支持的 `mount -o loop`
  ck "使用 losetup 挂载 squashfs"      "grep -q 'losetup' '$IRD/init'"
  ck "未误用 mount -o loop"            "! grep -q 'squashfs -o loop' '$IRD/init'"
  # 关键：检查**生成出来的 /init** 的语法，而不只是生成脚本本身。
  # 踩过的坑：/init 是 heredoc 内容，`bash -n 61-build-boot-initramfs.sh`
  # 只校验外层脚本，heredoc 里的语法错误（例如漏写一个 fi）完全检不出来。
  # 结果是打好的 initramfs 一启动就 panic：
  #     /init: line N: syntax error: unexpected end of file (expecting "fi")
  #     Kernel panic - not syncing: Attempted to kill init!
  # 所以必须在门禁里对生成物单独做语法检查。
  ck "/init 语法正确"                  "bash -n '$IRD/init'"
  ck "if/fi 配对平衡"                  "[ \$(grep -cE '^[[:space:]]*if ' '$IRD/init') -eq \$(grep -cE '^[[:space:]]*fi[[:space:]]*$' '$IRD/init') ]"
  echo
  printf '    体积: %s\n' "$([ -f "$cpio" ] && du -h "$cpio" | cut -f1 || echo '-')"
  echo
  echo "============================================================"
  printf '  引导 initramfs 门禁: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ 就绪\033[0m\n' || printf '  \033[1;31m✗ 存在问题\033[0m\n'
  echo "============================================================"
  return "$fail"
}

case "${1:-all}" in
  tree) do_tree ;;
  pack) do_pack ;;
  gate) do_gate ;;
  all)  do_tree; do_pack; do_gate ;;
  *) die "未知参数: $1（可用 all|tree|pack|gate）" ;;
esac
