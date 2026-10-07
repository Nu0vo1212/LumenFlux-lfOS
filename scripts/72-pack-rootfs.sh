#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 4d - rootfs 打包（squashfs 只读根 / ext4 可写根）
#
#  产出：
#    $LFOS/build/img/rootfs.squashfs   只读压缩根（供 ISO Live 启动）
#    $LFOS/build/img/rootfs.ext4       可写 ext4 根镜像（供安装到磁盘）
#
#  两种根的定位（对应设计方案 §1.4 不可变服务器思路）：
#    - squashfs：只读、高压缩比、不可篡改 —— ISO Live 启动用
#               配合 overlayfs 提供内存可写层，重启即还原（防配置漂移）
#    - ext4    ：可写持久 —— 磁盘安装用，适合需要留存状态的服务
#
#  用法： bash /opt/lfOS/scripts/72-pack-rootfs.sh [all|squashfs|ext4|gate]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
OUT="$LFOS/build"
IMG="$OUT/img"
LOGS="$OUT/logs"
SQFS="$IMG/rootfs.squashfs"
EXT4IMG="$IMG/rootfs.ext4"
EXT4_MB="${LFOS_ROOTFS_MB:-512}"

mkdir -p "$IMG" "$LOGS"

hr()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

[ -x "$LFS/usr/bin/bash" ] || die "rootfs 不完整（缺 /usr/bin/bash），请先完成 Phase 2"

# ---------------------------------------------------------------------------
# 打包前清理：删除构建残留与不必要文件（低占用）
# ---------------------------------------------------------------------------
do_cleanup() {
  hr "打包前清理（减小体积）"
  local before after
  before=$(du -sm "$LFS" | cut -f1)

  log "strip 可执行文件与共享库"
  local strip="$LFOS/build/tools/bin/x86_64-lfos-linux-gnu-strip"
  [ -x "$strip" ] || strip="strip"
  find "$LFS"/usr/bin "$LFS"/usr/sbin "$LFS"/bin "$LFS"/sbin \
       -type f -perm -u+x -print0 2>/dev/null \
    | xargs -0 -r "$strip" --strip-all 2>/dev/null || true
  find "$LFS"/usr/lib "$LFS"/lib -name '*.so*' -type f -print0 2>/dev/null \
    | xargs -0 -r "$strip" --strip-unneeded 2>/dev/null || true

  # ---------------------------------------------------------------------------
  #  删除静态库 —— 但必须保留 glibc 的 nonshared 库！
  #
  #  踩过的大坑：这里原本是 `find … -name '*.a' -delete`，把 glibc 的
  #  libc_nonshared.a 一并删掉了。后果不是「少了个可选文件」，而是
  #  **以 rootfs 作为 sysroot 的交叉编译环境彻底失效**：
  #      ld: cannot find /usr/lib/libc_nonshared.a inside <rootfs>
  #  原因是 /usr/lib/libc.so 其实是个链接脚本：
  #      GROUP ( /usr/lib/libc.so.6 /usr/lib/libc_nonshared.a
  #              AS_NEEDED ( /usr/lib/ld-linux-x86-64.so.2 ) )
  #  **动态链接也要用它**（atexit、stack_chk_fail_local 等符号不在共享库里）。
  #  之后想往系统里编译任何程序（例如补装 wget）都会失败，
  #  且错误信息指向「找不到库文件」，很难联想到是打包清理造成的。
  #
  #  结论：*.nonshared.a 属于「链接期必需」，不属于「可有可无的静态库」。
  # ---------------------------------------------------------------------------
  log "删除静态库（保留 glibc 链接必需的 *.nonshared.a）"
  find "$LFS"/usr/lib "$LFS"/lib -name '*.a' \
       ! -name 'libc_nonshared.a' ! -name 'libmvec_nonshared.a' \
       -delete 2>/dev/null || true
  for keep in libc_nonshared.a libmvec_nonshared.a; do
    [ -f "$LFS/usr/lib/$keep" ] && \
      printf '       保留 %s（%s 字节）\n' "$keep" "$(stat -c%s "$LFS/usr/lib/$keep")"
  done

  # ---------------------------------------------------------------------------
  #  删除 SSH 主机密钥 —— 绝不允许把主机密钥打进分发的镜像！
  #
  #  两个理由：
  #    安全：主机密钥是机器身份。若烘焙进镜像，所有部署实例共用同一私钥，
  #          等于没有身份唯一性；私钥还会随镜像一起对外分发。
  #          正确做法是每台机器首次启动时现场生成（见 scripts/82-install-init.sh）。
  #    功能：这些密钥属主为 root、权限 0600。打包者若不是 root，
  #          mksquashfs 读不到内容却仍会“成功”打包出一个 0 字节文件，
  #          运行时报错极具误导性：
  #              Unable to load host key: error in libcrypto
  #          实测正是这个坑 —— 镜像里私钥长度为 0。
  # ---------------------------------------------------------------------------
  if ls "$LFS"/etc/ssh/ssh_host_* >/dev/null 2>&1; then
    log "删除镜像内的 SSH 主机密钥（须由目标机首次启动时生成）"
    rm -f "$LFS"/etc/ssh/ssh_host_* 2>/dev/null || sudo rm -f "$LFS"/etc/ssh/ssh_host_* 2>/dev/null || true
  fi

  log "删除文档 / man / info / locale（保留 en 与 zh）"
  rm -rf "$LFS"/usr/share/doc "$LFS"/usr/share/info "$LFS"/usr/share/man 2>/dev/null || true
  if [ -d "$LFS/usr/share/locale" ]; then
    find "$LFS/usr/share/locale" -mindepth 1 -maxdepth 1 -type d \
      ! -name 'en*' ! -name 'zh*' ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true
  fi

  log "删除 pkgconfig 与头文件（运行期不需要；保留以免影响后续扩展）"
  # 注：这里保留头文件，因为后续可能需要在目标机编译。如需极致精简可取消注释。
  # rm -rf "$LFS"/usr/include "$LFS"/usr/lib/pkgconfig 2>/dev/null || true
  rm -rf "$LFS"/usr/lib/pkgconfig "$LFS"/usr/share/pkgconfig 2>/dev/null || true

  log "删除构建残留"
  rm -rf "$LFS"/tmp/* "$LFS"/var/tmp/* 2>/dev/null || true
  find "$LFS" -name '*.la' -delete 2>/dev/null || true

  after=$(du -sm "$LFS" | cut -f1)
  log "清理完成: ${before}MB → ${after}MB（释放 $((before-after))MB）"
}

# ---------------------------------------------------------------------------
#  打包完整性校验
#
#  动机：mksquashfs 在遇到「当前用户读不到的文件」时会**静默输出 0 字节**
#  并仍以成功退出。实测踩到过：镜像里的 SSH 主机私钥长度为 0，运行时才以
#  「error in libcrypto」这种完全指不到根因的方式暴露。
#  因此在打包后立刻做三项交叉校验，把问题挡在出镜像之前。
# ---------------------------------------------------------------------------
verify_squashfs() {
  # 默认校验当前 SQFS；显式传参可校验其他镜像
  local sqfs="${1:-$SQFS}" problems=0

  # 1) 关键文件必须存在且非空
  local list
  list=$(unsquashfs -ll "$sqfs" 2>/dev/null)
  local f size
  for f in sbin/init usr/bin/bash usr/bin/ls usr/sbin/sshd \
           usr/lib/libcrypto.so.3 etc/passwd etc/nsswitch.conf; do
    size=$(printf '%s\n' "$list" | awk -v p="squashfs-root/$f" '$NF==p {print $3}' | head -1)
    if [ -z "$size" ]; then
      printf '  \033[31m[校验失败]\033[0m %s 不在镜像中\n' "$f"; problems=$((problems+1))
    elif [ "$size" -eq 0 ] 2>/dev/null && [ "$f" != "etc/passwd" ]; then
      printf '  \033[31m[校验失败]\033[0m %s 大小为 0（疑似被静默截断）\n' "$f"; problems=$((problems+1))
    fi
  done

  # 2) 镜像内不应存在 SSH 主机密钥（每台机器须自行生成）
  if printf '%s\n' "$list" | grep -q 'ssh_host_'; then
    printf '  \033[31m[校验失败]\033[0m 镜像内包含 SSH 主机密钥（应删除）\n'; problems=$((problems+1))
  fi

  # 3) 与源目录的文件数量交叉比对（粗筛静默丢失）
  local src_n img_n
  src_n=$(find "$LFS" -type f 2>/dev/null | wc -l)
  img_n=$(printf '%s\n' "$list" | grep -c '^-' 2>/dev/null || echo 0)
  # 镜像侧排除了 boot/proc/sys/dev/tmp/run，数量必然略少，只做大偏差告警
  local diff=$(( src_n - img_n ))
  if [ "$diff" -gt $(( src_n / 10 + 50 )) ]; then
    printf '  \033[33m[校验告警]\033[0m 源 %s 个文件，镜像 %s 个（差 %s，超过 10%%）\n' \
      "$src_n" "$img_n" "$diff"
  fi

  if [ "$problems" -eq 0 ]; then
    printf '  \033[32m[校验通过]\033[0m 关键文件完整、无主机密钥残留\n'
  else
    die "squashfs 校验发现 $problems 处问题（见上）"
  fi
}

# ---------------------------------------------------------------------------
# squashfs：只读压缩根
# ---------------------------------------------------------------------------
do_squashfs() {
  hr "打包 squashfs 只读根"
  command -v mksquashfs >/dev/null 2>&1 || die "缺少 mksquashfs（apt install squashfs-tools）"

  # 压缩配置可通过环境变量调整，便于排查兼容性问题：
  #   LFOS_SQ_COMP=gzip|xz|zstd   （默认 gzip：兼容性最好）
  #   LFOS_SQ_BLOCK=128K|256K|1M  （默认 128K：内核兼容性最稳）
  #
  # 教训：最初用 `-comp xz -b 1M` 追求最小体积，但实测在本内核上
  # loop 挂载后会卡住（losetup 成功、容量正确，但 mount 不返回）。
  # 1MB 块是 squashfs 规范的上限，配合 xz 对内存与 I/O 的要求较高，
  # 而 initramfs 阶段内存紧张（VM 512MB）。改用 gzip + 128K 后恢复稳定。
  # 体积代价约 20%，换来的是「一定能挂上」——这个交换在引导阶段是划算的。
  local comp="${LFOS_SQ_COMP:-gzip}"
  local blk="${LFOS_SQ_BLOCK:-128K}"

  rm -f "$SQFS"
  log "mksquashfs（压缩=$comp, 块大小=$blk）"
  local compargs=""
  case "$comp" in
    xz)   compargs="-comp xz -Xdict-size 100%" ;;
    zstd) compargs="-comp zstd" ;;
    *)    compargs="-comp gzip" ;;
  esac

  # -all-root：把镜像内所有文件的属主强制为 root:root。
  #
  # 为什么必须加：lfOS 以普通用户交叉编译并 DESTDIR 安装（install 阶段用
  # fakeroot 承载 chown/setuid 意图），因此构建树里不少文件属主是构建用户。
  # mksquashfs 默认原样保留属主，打包出来的镜像就会出现「/var/lib/sshd 属主
  # 是 lfos 而非 root」这类问题，运行时 sshd 会直接拒绝启动：
  #     /var/lib/sshd must be owned by root and not group or world-writable.
  # 系统镜像里所有系统文件本就该属于 root，因此 -all-root 是正确且必要的。
  #
  # 为什么尽量以 root 运行 mksquashfs：
  #   非 root 打包时，遇到当前用户读不到的文件（典型是属主 root、权限 0600
  #   的私钥类文件），mksquashfs 会**静默地把它打成 0 字节**并且整体仍报成功。
  #   实测后果：镜像里的 SSH 主机私钥长度为 0，sshd 启动时报
  #       Unable to load host key: error in libcrypto
  #   这种「打包成功但内容损坏」最难排查，所以这里主动用 root 打包，
  #   并在打包后做完整性校验（见 verify_squashfs）。
  local MKSQ=(mksquashfs)
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      MKSQ=(sudo mksquashfs)
      log "以 root 身份打包（避免无读权限文件被静默截断为 0 字节）"
    else
      log "警告：非 root 且无法免密 sudo —— 若有不可读文件会被打包成 0 字节"
    fi
  fi

  if "${MKSQ[@]}" "$LFS" "$SQFS" \
        $compargs -b "$blk" -all-root \
        -noappend -no-progress -wildcards \
        -e 'boot/*' 'proc/*' 'sys/*' 'dev/*' 'tmp/*' 'run/*' \
        > "$LOGS/pack-squashfs.log" 2>&1; then
    log "squashfs 完成: $(du -h "$SQFS" | cut -f1)"
    verify_squashfs "$SQFS"
    # 记录实际参数，便于与内核配置对照排查
    unsquashfs -s "$SQFS" 2>/dev/null | grep -E 'Compression|Block size' | \
      sed 's/^/       /' || true
  else
    tail -15 "$LOGS/pack-squashfs.log"
    die "mksquashfs 失败"
  fi
}

# ---------------------------------------------------------------------------
# ext4：可写根镜像（磁盘安装用）
# ---------------------------------------------------------------------------
do_ext4() {
  hr "制作 ext4 可写根镜像（${EXT4_MB}MiB）"
  rm -f "$EXT4IMG"

  log "创建空镜像"
  dd if=/dev/zero of="$EXT4IMG" bs=1M count="$EXT4_MB" status=none \
    || die "创建镜像失败"

  log "格式化 ext4"
  mkfs.ext4 -q -F -L lfos-root -m 1 \
    -O ^has_journal,^resize_inode,sparse_super,large_file \
    "$EXT4IMG" > "$LOGS/pack-ext4.log" 2>&1 || die "mkfs.ext4 失败"
  # 说明：^has_journal 关闭日志以省空间。若用于生产可写根，建议保留日志
  #       （去掉 ^has_journal）以提升掉电安全性。

  log "挂载并复制 rootfs（需要 root）"
  local mnt=/tmp/.lfos-ext4mnt
  rm -rf "$mnt"; mkdir -p "$mnt"
  if mount -o loop "$EXT4IMG" "$mnt" 2>>"$LOGS/pack-ext4.log"; then
    cp -a "$LFS"/. "$mnt"/ 2>>"$LOGS/pack-ext4.log" || log "复制有告警（多为特殊文件）"
    sync
    local used
    used=$(du -sm "$mnt" 2>/dev/null | cut -f1)
    umount "$mnt" || die "卸载失败"
    rmdir "$mnt" 2>/dev/null
    log "ext4 完成: $(du -h "$EXT4IMG" | cut -f1)（已用 ${used}MB）"
  else
    rmdir "$mnt" 2>/dev/null
    log "无法挂载 loop 设备（需 root）—— 跳过 ext4 制作"
    log "提示： sudo bash $0 ext4"
    rm -f "$EXT4IMG"
    return 0
  fi
}

# ---------------------------------------------------------------------------
do_gate() {
  hr "rootfs 打包门禁"
  local pass=0 fail=0
  # ---------------------------------------------------------------------------
  #  注意：这里必须临时关闭 pipefail！
  #
  #  本脚本顶部有 `set -uo pipefail`。而门禁里大量使用
  #      unsquashfs -l ... | grep -q <模式>
  #  这种写法：grep -q 一找到匹配就立即退出，上游 unsquashfs 随即收到
  #  SIGPIPE 并以 141 退出。pipefail 会把「最后一个非零退出码」作为整个
  #  管道的状态，于是**明明匹配成功却被判定为失败**。
  #
  #  实测表现极具迷惑性：门禁报 3 项失败，而在同一环境下手工敲同样的命令
  #  却全部通过 —— 因为交互式 shell 没有开启 pipefail。
  #
  #  修法：只在这段检查里关掉 pipefail，其余代码不受影响（比改写所有检查
  #  表达式更稳妥，也保留了 `grep -q` 提前退出的性能优势）。
  # ---------------------------------------------------------------------------
  chk() {
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

  chk "squashfs 已生成"     "[ -f '$SQFS' ]"
  chk "squashfs 含 bash"    "unsquashfs -l '$SQFS' 2>/dev/null | grep -q 'usr/bin/bash'"
  chk "squashfs 含 coreutils" "unsquashfs -l '$SQFS' 2>/dev/null | grep -q 'usr/bin/ls'"
  chk "squashfs 含 glibc"   "unsquashfs -l '$SQFS' 2>/dev/null | grep -q 'libc.so.6'"

  echo
  echo "  体积对比:"
  printf '    %-30s %s\n' "原始 rootfs" "$(du -sh "$LFS" 2>/dev/null | cut -f1)"
  printf '    %-30s %s\n' "squashfs (xz)" "$([ -f "$SQFS" ] && du -h "$SQFS" | cut -f1 || echo '-')"
  if [ -f "$SQFS" ]; then
    local raw_kb sq_kb ratio
    raw_kb=$(du -sk "$LFS" | cut -f1)
    sq_kb=$(du -k "$SQFS" | cut -f1)
    ratio=$(( sq_kb * 100 / (raw_kb > 0 ? raw_kb : 1) ))
    printf '    %-30s %d%%\n' "压缩比" "$ratio"
  fi
  [ -f "$EXT4IMG" ] && printf '    %-30s %s\n' "ext4 可写根" "$(du -h "$EXT4IMG" | cut -f1)"

  echo
  echo "============================================================"
  printf '  rootfs 打包门禁: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ rootfs 打包就绪\033[0m\n' || printf '  \033[1;31m✗ 存在问题\033[0m\n'
  echo "============================================================"
  return "$fail"
}

case "${1:-all}" in
  cleanup)  do_cleanup ;;
  squashfs) do_cleanup; do_squashfs ;;
  ext4)     do_ext4 ;;
  gate)     do_gate ;;
  all)      do_cleanup; do_squashfs; do_ext4; do_gate ;;
  *) die "未知参数: $1（可用 all|cleanup|squashfs|ext4|gate）" ;;
esac
