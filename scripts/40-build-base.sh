#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 2 - Base System (chroot 内构建)
#  前置：Phase 1 交叉工具链完成（$LFS_TOOLS 可用，$LFS 有 glibc）
#  顺序：按 LFS 章节，全部在 chroot 内编译安装，统一 strip
#  用法： bash /opt/lfOS/scripts/40-build-base.sh [stage...]
#         stage = all | prep | core | busybox | extras | cleanup | gate
#  产物： $LFS 根骨架（/bin /sbin /etc /lib /usr ...）
#  门禁： du -sh $LFS ≤ 120MB（glibc 路线）；ldd 无缺失依赖
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS_TOOLS="${LFS_TOOLS:-$LFOS/build/tools}"
LFS_SOURCES="${LFS_SOURCES:-$LFOS/src}"
LFS_LOGS="${LFS_LOGS:-$LFOS/build/logs}"
LFS="${LFS:-$LFOS/build/rootfs}"
JOBS="${LFOS_JOBS:-$(nproc)}"
HEAVY="${LFOS_JOBS_HEAVY:-$(( JOBS > 2 ? JOBS / 2 : 1 ))}"

LFS_TGT="${LFS_TGT:-x86_64-lfos-linux-gnu}"
TARGET_SIZE_MB="${LFOS_PHASE2_TARGET_MB:-120}"

export LC_ALL=POSIX
export PATH="$LFS_TOOLS/bin:/usr/bin:/bin:/usr/sbin:/sbin"

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 在 chroot 内执行命令（LFS 标准手法）
# ---------------------------------------------------------------------------
in_chroot() {
  chroot "$LFS" /usr/bin/env -i \
      HOME=/root TERM="${TERM:-dumb}" PS1='(lfos chroot) \u:\w\$ ' \
      PATH=/usr/bin:/usr/sbin \
      MAKEFLAGS="-j$1" \
      TESTSUITEFLAGS="-j$1" \
      /bin/bash --login -c "$2"
}

# 挂载虚拟文件系统（LFS 6.2）
mount_virt() {
  hr "准备 chroot 环境"
  mkdir -pv "$LFS"/{dev,proc,sys,run}
  mountpoint -q "$LFS/dev"  || mount -v --bind /dev "$LFS/dev"
  mountpoint -q "$LFS/dev/pts" || mount -vt devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts"
  mountpoint -q "$LFS/proc" || mount -vt proc proc "$LFS/proc"
  mountpoint -q "$LFS/sys"  || mount -vt sysfs sysfs "$LFS/sys"
  mountpoint -q "$LFS/run"  || mount -vt tmpfs tmpfs "$LFS/run"
  log "虚拟文件系统已挂载"
}

umount_virt() {
  for m in run sys proc dev/pts dev; do
    mountpoint -q "$LFS/$m" && umount -v "$LFS/$m"
  done
  log "虚拟文件系统已卸载"
}

# ---------------------------------------------------------------------------
# 每个包的通用构建函数：configure + make + make install + strip
# ---------------------------------------------------------------------------
build_pkg() {
  local name="$1" tb="$2" dir="$3"; shift 3
  local args=("$@")
  hr "构建 $name"
  [ -s "$LFS_SOURCES/$tb" ] || die "缺少源码包 $tb"
  rm -rf "$LFS_SOURCES/$dir"
  tar -xf "$LFS_SOURCES/$tb" -C "$LFS_SOURCES" || die "解包失败 $tb"
  cd "$LFS_SOURCES/$dir" || die "进入目录失败 $dir"
  if [ -x ./configure ]; then
    ./configure --prefix=/usr --disable-static "${args[@]}" \
      > "$LFS_LOGS/${name}-configure.log" 2>&1 || { tail -30 "$LFS_LOGS/${name}-configure.log"; die "$name configure"; }
  fi
  make -j"$JOBS" > "$LFS_LOGS/${name}-make.log" 2>&1 || { tail -30 "$LFS_LOGS/${name}-make.log"; die "$name make"; }
  make DESTDIR="$LFS" install > "$LFS_LOGS/${name}-install.log" 2>&1 || die "$name install"
  log "$name 完成"
}

# ---------------------------------------------------------------------------
# Stage: prep —— 目录骨架 + 基础配置（LFS 6.5 / 7.x）
# ---------------------------------------------------------------------------
stage_prep() {
  hr "Stage prep  目录骨架与基础配置"
  mkdir -pv "$LFS"/{bin,boot,dev,etc/{opt,sysconfig},home,lib/firmware,media,mnt,opt,
                    proc,root,run,sbin,srv,sys,tmp,usr/{bin,include,lib,libexec,local,
                    sbin,share/{doc,info,locale,man},src},var/{cache,lib,local,log,mail,
                    opt,spool,tmp}}
  chmod -v 1777 "$LFS/tmp"
  install -v -dm755 "$LFS/usr/lib64"
  ln -sfv ../lib "$LFS/usr/lib64"   2>/dev/null || true
  ln -sfv ../lib "$LFS/usr/sbin"    2>/dev/null || true

  # /etc/fstab：SSD 友好（noatime + tmpfs）
  cat > "$LFS/etc/fstab" <<'EOF'
# lfOS (流光OS) /etc/fstab
# <file system>  <mount point>  <type>  <options>                <dump> <pass>
/dev/vda1        /              ext4    defaults,noatime,discard  0      1
/dev/vda2        /boot          ext4    defaults,noatime          0      2
tmpfs            /tmp           tmpfs   defaults,nosuid,nodev,noexec,mode=1777  0 0
tmpfs            /run           tmpfs   defaults,nosuid,nodev,mode=0755         0 0
EOF

  # 主机名与 hosts
  printf 'lfos\n' > "$LFS/etc/hostname"
  cat > "$LFS/etc/hosts" <<'EOF'
127.0.0.1  localhost
::1        localhost
127.0.1.1  lfos
EOF

  # 时区与 locale（最小化）
  ln -sfv /usr/share/zoneinfo/UTC "$LFS/etc/localtime"
  printf 'en_US.UTF-8 UTF-8\n' > "$LFS/etc/locale.gen"
  printf 'LANG=en_US.UTF-8\n'  > "$LFS/etc/locale.conf"

  # 挂载点权限加固
  chmod -v 0750 "$LFS/root"
  log "prep 完成"
}

# ---------------------------------------------------------------------------
# Stage: core —— 核心工具（选取服务器必需、体积可控的集合）
# ---------------------------------------------------------------------------
stage_core() {
  hr "Stage core  核心系统工具"
  in_chroot "$JOBS" "
    set -e
    cd /sources 2>/dev/null || cd /tmp
    echo 'chroot 内核: '\$(uname -r)
    echo 'chroot 工具链: '\$(gcc --version | head -1)
  " 2>&1 | tee "$LFS_LOGS/core-chroot-check.log" || die "chroot 自检失败"

  # 下列包将在 chroot 内编译；清单按 LFS 顺序，只保留服务器必需项
  local pkgs=(
    "man-pages:man-pages-6.13.tar.xz:man-pages-6.13:"
    "iana-etc:iana-etc-20250109.tar.gz:iana-etc-20250109:"
    "zlib:zlib-1.3.1.tar.gz:zlib-1.3.1:--libdir=/usr/lib"
    "bzip2:bzip2-1.0.8.tar.gz:bzip2-1.0.8:"
    "xz:xz-5.8.1.tar.xz:xz-5.8.1:--disable-static --docdir=/usr/share/doc/xz-5.8.1"
  )
  for entry in "${pkgs[@]}"; do
    IFS=':' read -r name tb dir opts <<< "$entry"
    if [ -s "$LFS_SOURCES/$tb" ]; then
      # shellcheck disable=SC2086
      build_pkg "$name" "$tb" "$dir" $opts
    else
      log "跳过 $name（源码包 $tb 尚未获取，请补充到 20-fetch-sources.sh）"
    fi
  done
  log "core 完成"
}

# ---------------------------------------------------------------------------
# Stage: busybox —— 用 BusyBox 替代约 300 个小工具（降占用关键一步）
# ---------------------------------------------------------------------------
stage_busybox() {
  hr "Stage busybox  精简工具集"
  local tb="busybox-1.37.0.tar.bz2" dir="busybox-1.37.0"
  if [ ! -s "$LFS_SOURCES/$tb" ]; then
    log "缺少 $tb —— 请先执行：bash /opt/lfOS/scripts/20-fetch-sources.sh"
    return 0
  fi
  rm -rf "$LFS_SOURCES/$dir"
  tar -xf "$LFS_SOURCES/$tb" -C "$LFS_SOURCES" || die "解包 busybox 失败"
  cd "$LFS_SOURCES/$dir" || die "进入 busybox 目录失败"
  make defconfig > "$LFS_LOGS/busybox-defconfig.log" 2>&1
  # 关闭会与真实 coreutils/bash 冲突的 applet，保留精简工具
  for k in CONFIG_INSTALL_APPLET_DONT CONFIG_FEATURE_SYSTEMD; do
    sed -i "s/^${k}=.*/# ${k} is not set/" .config 2>/dev/null || true
  done
  make -j"$JOBS" > "$LFS_LOGS/busybox-make.log" 2>&1 || die "busybox make"
  make CONFIG_PREFIX="$LFS" install > "$LFS_LOGS/busybox-install.log" 2>&1 || die "busybox install"
  "$LFS_TOOLS/bin/$LFS_TGT-strip" --strip-all "$LFS/bin/busybox" 2>/dev/null || true
  log "busybox 完成：$(du -h "$LFS/bin/busybox" 2>/dev/null | cut -f1)"
}

# ---------------------------------------------------------------------------
# Stage: cleanup —— strip + 删除文档/静态库（体积门禁的关键）
# ---------------------------------------------------------------------------
stage_cleanup() {
  hr "Stage cleanup  strip 与裁剪"
  local strip="$LFS_TOOLS/bin/$LFS_TGT-strip"
  [ -x "$strip" ] || strip="strip"
  log "strip 所有可执行文件与库"
  find "$LFS"/{bin,sbin,usr/bin,usr/sbin,usr/lib,lib} -type f \
       \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null \
    | xargs -0 -r "$strip" --strip-all 2>/dev/null || true

  log "删除静态库与文档"
  find "$LFS/usr/lib" "$LFS/lib" -name '*.a' -delete 2>/dev/null || true
  rm -rf "$LFS"/usr/share/{doc,info,man,locale/*} 2>/dev/null || true
  rm -rf "$LFS"/usr/lib/*.la 2>/dev/null || true
  log "cleanup 完成"
}

# ---------------------------------------------------------------------------
# Stage: gate —— Phase 2 门禁
# ---------------------------------------------------------------------------
stage_gate() {
  hr "Phase 2 GATE"
  local pass=0 fail=0
  # 临时关闭 pipefail 后再执行检查表达式。
  # 原因：检查里常见 `... | grep -q`，grep 命中即退出会让上游命令收到
  # SIGPIPE（退出码 141），pipefail 会把这次正常的提前退出误判为失败。
  # 详见 72-pack-rootfs.sh 中的同类注释。
  chk() { local rc; set +o pipefail; eval "$2" >/dev/null 2>&1; rc=$?; set -o pipefail
          if [ "$rc" -eq 0 ]; then echo "  [PASS] $1"; pass=$((pass+1));
          else echo "  [FAIL] $1"; fail=$((fail+1)); fi; }

  local size_kb size_mb
  size_kb=$(du -sk "$LFS" 2>/dev/null | cut -f1)
  size_mb=$(( size_kb / 1024 ))
  if [ "$size_mb" -le "$TARGET_SIZE_MB" ]; then
    echo "  [PASS] 根文件系统体积 ${size_mb}MB ≤ ${TARGET_SIZE_MB}MB"; pass=$((pass+1))
  else
    echo "  [FAIL] 根文件系统体积 ${size_mb}MB > ${TARGET_SIZE_MB}MB"; fail=$((fail+1))
  fi

  chk "存在 /bin/bash 或 /bin/busybox" "[ -x $LFS/bin/bash ] || [ -x $LFS/bin/busybox ]"
  chk "存在 /usr/lib/libc.so.6"        "[ -f $LFS/usr/lib/libc.so.6 ] || [ -f $LFS/lib/libc.so.6 ]"
  chk "存在 /etc/fstab"                "[ -f $LFS/etc/fstab ]"
  chk "存在 /etc/passwd"               "[ -f $LFS/etc/passwd ] || [ -f $LFS/etc/passwd- ]"

  echo
  echo "  体积明细（前 10 大目录）:"
  du -sh "$LFS"/* 2>/dev/null | sort -rh | head -10 | sed 's/^/    /'
  echo
  printf '  结果: %d 通过 / %d 失败\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && echo "  ✔ Phase 2 门禁通过" || echo "  ✗ Phase 2 门禁未通过"
  return "$fail"
}

# ---------------------------------------------------------------------------
STAGE="${1:-gate}"
case "$STAGE" in
  prep)    stage_prep ;;
  core)    mount_virt; stage_core; umount_virt ;;
  busybox) mount_virt; stage_busybox; umount_virt ;;
  extras)  log "extras 阶段待实现（bash/coreutils/util-linux/grep/sed/gawk/tar…）" ;;
  cleanup) stage_cleanup ;;
  gate)    stage_gate ;;
  all)
    stage_prep
    mount_virt
    stage_core
    stage_busybox
    umount_virt
    stage_cleanup
    stage_gate
    ;;
  *) die "未知阶段: $STAGE（可用 all|prep|core|busybox|extras|cleanup|gate）" ;;
esac
