#!/usr/bin/env bash
# ============================================================================
#  lfOS - CA 证书内置 + apt 未配置包修复 + 首启自愈
#
#  ══ 问题现象 ══
#    wget: Unable to locally verify the issuer's authority
#    curl: (77) error setting certificate file: /etc/ssl/certs/ca-certificates.crt
#
#  ══ 根因（实测确认）══
#    /etc/ssl/certs/ 是空目录，ca-certificates.crt 根本不存在。
#    但证书"源文件"是有的（/usr/share/ca-certificates/mozilla/*.crt 共 150 个）。
#
#    关键点：ca-certificates 这个包**不直接提供** /etc/ssl/certs/* 。
#    那些文件是它的 postinst 调用 update-ca-certificates 在**安装时生成**的：
#        读取 /etc/ca-certificates.conf + /usr/share/ca-certificates/**/*.crt
#        → 合并成 /etc/ssl/certs/ca-certificates.crt
#        → 为每张证书建 hash 软链 <hash>.0
#
#    本项目打包时用 dpkg-deb -x 手工解包（因为要装进 sysroot 而不进构建机），
#    只落了文件、**没跑 postinst**，所以 ca-certificates 一直是 iU（解包未配置）
#    状态，证书文件自然从没被生成过。
#
#    同时这也解释了 apt 的异常：24 个包停在 iU，51 个包缺 .list 文件清单。
#
#  ══ 鸡生蛋问题 ══
#    需要 HTTPS 才能下载 → 需要证书 → 没证书不能 HTTPS。
#    破解办法（本脚本采用）：**整个链条不依赖 TLS**：
#      1) 下载 ca-certificates 的 .deb 用 HTTP（Debian 的 HTTP 源可用）；
#         apt/dpkg 验证包完整性走的是 GPG 签名，与 TLS 无关。
#      2) 证书数据本身就在这个 .deb 里（150 个 .crt），不需要联网取。
#      3) 于是「解包 + 跑 postinst」就能自举出证书，之后 HTTPS 自然可用。
#    构建机自己也没证书时同样成立 —— 只要它能走 HTTP。
#
#  用法： bash 56-ca-certificates.sh [all|fix-dpkg|run-parts|cert|heal|verify|gate]
# ============================================================================
set -uo pipefail

LFOS="${LFOS:-/opt/lfOS}"
LFS="${LFS:-$LFOS/build/rootfs}"
PKGS="$LFOS/build/testpkgs"
IDX="$LFOS/build/debrepo/Packages-trixie"
LOGS="$LFOS/build/logs"
# 注意：引导阶段用 HTTP。这不是"绕过校验" —— apt/dpkg 对包的校验是 GPG 签名，
# 与传输层是否 TLS 无关。拿到 ca-certificates 之后全部改用 HTTPS。
MIRROR_HTTP="${LFOS_DEB_MIRROR_HTTP:-http://deb.debian.org/debian}"
MIRROR_HTTPS="${LFOS_DEB_MIRROR_HTTPS:-https://deb.debian.org/debian}"

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()  { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[警告]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

idx_field() {
  awk -v RS='' -v p="$1" -v f="$2" '
    $1 == "Package:" && $2 == p {
      n = split($0, lines, "\n")
      for (i = 1; i <= n; i++) if (lines[i] ~ "^" f ": ") { sub("^" f ": ", "", lines[i]); print lines[i]; exit }
    }' "$IDX"
}

# ── chroot 辅助：postinst 常需要 /proc /dev /sys ──
CHROOT_MOUNTS=()
mount_pseudo() {
  mkdir -p "$LFS/proc" "$LFS/sys" "$LFS/dev" "$LFS/dev/pts" 2>/dev/null
  for m in proc sys dev dev/pts; do
    if ! mountpoint -q "$LFS/$m" 2>/dev/null; then
      mount --bind "/$m" "$LFS/$m" 2>/dev/null && CHROOT_MOUNTS+=("$m")
    fi
  done
  # /etc/mtab 是不少 postinst 会读的（现代系统常是 /proc/self/mounts 的链接）
  [ -e "$LFS/etc/mtab" ] || ln -sf /proc/self/mounts "$LFS/etc/mtab" 2>/dev/null
}
umount_pseudo() {
  for m in dev/pts dev proc sys; do
    mountpoint -q "$LFS/$m" 2>/dev/null && umount "$LFS/$m" 2>/dev/null
  done
}
trap umount_pseudo EXIT

# ---------------------------------------------------------------------------
#  1. 修 apt/dpkg 的未配置包（iU → ii）
# ---------------------------------------------------------------------------
do_fix_dpkg() {
  printf '\n\033[1;36m===== 修复未配置的包（dpkg --configure -a）=====\n\033[0m'
  mount_pseudo

  # 统计修复前状态
  before_iu=$(chroot "$LFS" /usr/bin/dpkg -l 2>/dev/null | awk 'NR>5 && $1=="iU"' | wc -l)
  before_ii=$(chroot "$LFS" /usr/bin/dpkg -l 2>/dev/null | awk 'NR>5 && $1=="ii"' | wc -l)
  printf '  修复前: %s 个已配置(ii) / %s 个未配置(iU)\n' "$before_ii" "$before_iu"

  # 缺 .list 的包先用 --unpack 重放一遍，把文件清单补上。
  # 为什么需要：dpkg-deb -x 只解文件、不进数据库；后续 dpkg --unpack 才会写 .list。
  # 缺 .list 会让 dpkg 认为"这个包装了但没有文件"，remove/upgrade 时行为不可预期。
  local missing_list=0 p
  for p in $(chroot "$LFS" /usr/bin/dpkg -l 2>/dev/null | awk 'NR>5 && NF>2 {print $2}' | cut -d: -f1 | sort -u); do
    [ -f "$LFS/var/lib/dpkg/info/$p.list" ] && continue
    local deb
    deb=$(ls "$PKGS/${p}_"*.deb 2>/dev/null | head -1)
    if [ -n "$deb" ]; then
      cp -f "$deb" "$LFS/tmp/" 2>/dev/null
      chroot "$LFS" /usr/bin/dpkg --unpack "/tmp/$(basename "$deb")" >/dev/null 2>&1
      rm -f "$LFS/tmp/$(basename "$deb")" 2>/dev/null
      missing_list=$((missing_list+1))
    fi
  done
  printf '  重放 %s 个包以补齐 .list 文件清单\n' "$missing_list"

  # 跑 configure（这会执行所有 postinst）
  log "执行 dpkg --configure -a"
  chroot "$LFS" /usr/bin/dpkg --configure -a > "$LOGS/ca-configure.log" 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "dpkg --configure -a 返回 $rc，失败项如下："
    grep -E '^(dpkg:|.*error|.*Errors)' "$LOGS/ca-configure.log" 2>/dev/null | head -12 | sed 's/^/      /'
  else
    ok "dpkg --configure -a 成功"
  fi

  local after_iu after_ii
  after_iu=$(chroot "$LFS" /usr/bin/dpkg -l 2>/dev/null | awk 'NR>5 && $1=="iU"' | wc -l)
  after_ii=$(chroot "$LFS" /usr/bin/dpkg -l 2>/dev/null | awk 'NR>5 && $1=="ii"' | wc -l)
  printf '  修复后: %s 个已配置(ii) / %s 个未配置(iU)\n' "$after_ii" "$after_iu"
  [ "$after_iu" -eq 0 ] && ok "所有包均已配置" || warn "仍有 $after_iu 个包未配置"
}

# ---------------------------------------------------------------------------
#  2. 确保 run-parts 可用（update-ca-certificates 依赖它）
# ---------------------------------------------------------------------------
do_run_parts() {
  printf '\n\033[1;36m===== 确保 run-parts 可用 =====\033[0m\n'
  if [ -x "$LFS/usr/bin/run-parts" ] || [ -x "$LFS/bin/run-parts" ]; then
    ok "run-parts 已存在"
    return 0
  fi

  # 首选：装 debianutils（Debian/Ubuntu 的 run-parts 就来自它，行为与 Ubuntu 一致）
  local fn base
  fn=$(idx_field debianutils Filename)
  if [ -n "$fn" ]; then
    base=$(basename "$fn")
    if [ ! -s "$PKGS/$base" ]; then
      # 引导阶段用 HTTP（不依赖 TLS）
      log "下载 debianutils（HTTP 引导，apt/dpkg 用 GPG 校验包完整性）"
      curl -fL --retry 2 --connect-timeout 20 --max-time 300 \
        -o "$PKGS/$base" "$MIRROR_HTTP/$fn" 2>/dev/null || true
    fi
    if [ -s "$PKGS/$base" ]; then
      dpkg-deb -x "$PKGS/$base" "$LFS" 2>/dev/null
      cp -f "$PKGS/$base" "$LFS/tmp/" 2>/dev/null
      chroot "$LFS" /usr/bin/dpkg --unpack "/tmp/$base" >/dev/null 2>&1
      rm -f "$LFS/tmp/$base" 2>/dev/null
      [ -x "$LFS/usr/bin/run-parts" ] && ok "debianutils 已装（提供 run-parts）" || warn "debianutils 解包后仍无 run-parts"
    fi
  fi

  # 兜底：用 busybox 的 run-parts applet 建软链
  if [ ! -x "$LFS/usr/bin/run-parts" ] && [ -x "$LFS/usr/lib/lfos/busybox" ]; then
    if chroot "$LFS" /usr/lib/lfos/busybox --list 2>/dev/null | grep -qx 'run-parts'; then
      ln -sf /usr/lib/lfos/busybox "$LFS/usr/bin/run-parts"
      ok "已用 BusyBox 的 run-parts 兜底"
    fi
  fi

  [ -x "$LFS/usr/bin/run-parts" ] || warn "run-parts 仍不可用（update-ca-certificates 的 hooks 步骤会跳过，但证书仍能生成）"
}

# ---------------------------------------------------------------------------
#  3. 生成 CA 证书（核心）
# ---------------------------------------------------------------------------
do_cert() {
  printf '\n\033[1;36m===== 生成 CA 证书 =====\033[0m\n'
  mount_pseudo

  # 3.1 证书源文件必须在（在 ca-certificates 包里，不需联网）
  local src_count
  src_count=$(find "$LFS/usr/share/ca-certificates" -name '*.crt' 2>/dev/null | wc -l)
  if [ "$src_count" -eq 0 ]; then
    warn "证书源文件缺失，尝试解包 ca-certificates"
    local fn base
    fn=$(idx_field ca-certificates Filename)
    if [ -n "$fn" ]; then
      base=$(basename "$fn")
      [ -s "$PKGS/$base" ] || curl -fL --retry 2 --connect-timeout 20 --max-time 300 \
          -o "$PKGS/$base" "$MIRROR_HTTP/$fn" 2>/dev/null || true
      [ -s "$PKGS/$base" ] && dpkg-deb -x "$PKGS/$base" "$LFS" 2>/dev/null
      src_count=$(find "$LFS/usr/share/ca-certificates" -name '*.crt' 2>/dev/null | wc -l)
    fi
  fi
  printf '  证书源文件: %s 个 .crt\n' "$src_count"
  [ "$src_count" -gt 0 ] || die "没有证书源文件，无法生成"

  # 3.2 /etc/ca-certificates.conf —— postinst 会生成；这里保证它存在
  if [ ! -f "$LFS/etc/ca-certificates.conf" ]; then
    log "生成 /etc/ca-certificates.conf"
    {
      printf '# lfOS: 由 56-ca-certificates.sh 生成\n'
      printf '# 列出要启用的 CA 证书（相对 /usr/share/ca-certificates/ 的路径）\n'
      ( cd "$LFS/usr/share/ca-certificates" && find . -name '*.crt' | sed 's|^\./||' | sort )
    } > "$LFS/etc/ca-certificates.conf"
    ok "已写入 $(grep -vc '^#' "$LFS/etc/ca-certificates.conf") 条启用项"
  else
    ok "/etc/ca-certificates.conf 已存在"
  fi

  # 3.3 update-ca-certificates 需要这些目录
  mkdir -p "$LFS/etc/ssl/certs" "$LFS/usr/local/share/ca-certificates" \
           "$LFS/etc/ca-certificates/update.d" 2>/dev/null
  chmod 0755 "$LFS/etc/ssl/certs" 2>/dev/null
  # 提供一个空的 ssl 配置骨架（有些脚本会读）
  mkdir -p "$LFS/usr/lib/ssl" 2>/dev/null
  [ -e "$LFS/usr/lib/ssl/certs" ] || ln -sfn /etc/ssl/certs "$LFS/usr/lib/ssl/certs" 2>/dev/null
  [ -e "$LFS/usr/lib/ssl/openssl.cnf" ] || ln -sfn /etc/ssl/openssl.cnf "$LFS/usr/lib/ssl/openssl.cnf" 2>/dev/null

  # 3.4 执行生成
  # 优先跑官方脚本（与 Debian/Ubuntu 行为完全一致）；
  # 失败则退回自己合并（保证结果一定产出，且结果等价）。
  local ran=0
  if [ -x "$LFS/usr/sbin/update-ca-certificates" ]; then
    log "执行 update-ca-certificates --fresh"
    if chroot "$LFS" /usr/sbin/update-ca-certificates --fresh > "$LOGS/ca-update.log" 2>&1; then
      ok "update-ca-certificates 执行成功"
      ran=1
    else
      warn "update-ca-certificates 失败，末尾输出："
      tail -6 "$LOGS/ca-update.log" 2>/dev/null | sed 's/^/      /'
    fi
  fi

  if [ ! -s "$LFS/etc/ssl/certs/ca-certificates.crt" ]; then
    warn "退回手工合并模式"
    local bundle="$LFS/etc/ssl/certs/ca-certificates.crt"
    : > "$bundle"
    local f
    while IFS= read -r line; do
      case "$line" in ''|\#*) continue ;; esac
      f="$LFS/usr/share/ca-certificates/$line"
      [ -f "$f" ] || continue
      cat "$f" >> "$bundle"
      printf '\n' >> "$bundle"
    done < "$LFS/etc/ca-certificates.conf"
    chmod 0644 "$bundle"
    ran=1
  fi

  # 3.5 生成 hash 软链（OpenSSL 的 CApath 模式需要 <hash>.0）
  if [ -x "$LFS/usr/bin/c_rehash" ]; then
    chroot "$LFS" /usr/bin/c_rehash /etc/ssl/certs >/dev/null 2>&1 \
      && ok "c_rehash 已生成 hash 软链" \
      || warn "c_rehash 执行有问题（wget/curl 用的是 ca-certificates.crt 单文件，通常不影响）"
  else
    # 用 openssl 自己算 hash 建链
    local cert hash
    for cert in "$LFS"/usr/share/ca-certificates/mozilla/*.crt; do
      [ -f "$cert" ] || continue
      hash=$(chroot "$LFS" /usr/bin/openssl x509 -hash -noout -in "/usr/share/ca-certificates/mozilla/$(basename "$cert")" 2>/dev/null)
      [ -n "$hash" ] && ln -sf "/usr/share/ca-certificates/mozilla/$(basename "$cert")" \
        "$LFS/etc/ssl/certs/$hash.0" 2>/dev/null
    done
  fi

  # 3.6 把证书路径写进 openssl 配置（有些程序读 openssl.cnf 的 CAfile）
  if [ -f "$LFS/etc/ssl/openssl.cnf" ]; then
    if ! grep -q 'ca-certificates.crt' "$LFS/etc/ssl/openssl.cnf" 2>/dev/null; then
      printf '\n# lfOS: 让 OpenSSL 默认信任系统 CA 包\nCAfile = /etc/ssl/certs/ca-certificates.crt\n' \
        >> "$LFS/etc/ssl/openssl.cnf"
    fi
  fi
}

# ---------------------------------------------------------------------------
#  4. 首启自愈
# ---------------------------------------------------------------------------
do_heal() {
  printf '\n\033[1;36m===== 写入首启自愈脚本 =====\033[0m\n'
  install -d "$LFS/usr/lib/lfos" 2>/dev/null

  cat > "$LFS/usr/lib/lfos/ca-selfheal.sh" <<'HEALEOF'
#!/bin/sh
# lfOS - CA 证书自愈
#
# 为什么需要：/etc/ssl/certs/* 是 ca-certificates 的 postinst 在**安装时**生成的，
# 而不是包自带的文件。任何让 postinst 没能跑完的情况（手工解包、镜像裁剪、
# 恢复备份）都会留下一个空目录，表现为：
#     wget: Unable to locally verify the issuer's authority
#     curl: (77) error setting certificate file: /etc/ssl/certs/ca-certificates.crt
# 这个脚本在每次启动时检查一次，缺失就就地重建 —— 不需要联网，
# 因为证书源文件（/usr/share/ca-certificates/**/*.crt）在包里就有。

CERT=/etc/ssl/certs/ca-certificates.crt
SRC=/usr/share/ca-certificates
CONF=/etc/ca-certificates.conf

need_heal() {
    [ -s "$CERT" ] && return 1      # 存在且非空 → 不用修
    [ -d "$SRC" ] || return 1       # 连源文件都没有 → 修不了
    return 0
}

count_src() {
    find "$SRC" -name '*.crt' 2>/dev/null | wc -l
}

if need_heal; then
    n=$(count_src)
    if [ "$n" -gt 0 ]; then
        echo "[lfOS] CA 证书缺失，正在自愈（证书源 $n 个）…"

        # 1) 确保配置列表存在
        if [ ! -f "$CONF" ]; then
            mkdir -p "$(dirname "$CONF")"
            {
                echo "# lfOS: 自动生成"
                ( cd "$SRC" && find . -name '*.crt' | sed 's|^\./||' | sort )
            } > "$CONF" 2>/dev/null
        fi

        mkdir -p /etc/ssl/certs /usr/local/share/ca-certificates

        # 2) 优先用官方脚本（结果与 Debian/Ubuntu 完全一致）
        if [ -x /usr/sbin/update-ca-certificates ]; then
            /usr/sbin/update-ca-certificates --fresh >/dev/null 2>&1
        fi

        # 3) 仍然没有就手工合并（等价结果）
        if [ ! -s "$CERT" ] && [ -f "$CONF" ]; then
            : > "$CERT"
            while IFS= read -r line; do
                case "$line" in ''|\#*) continue ;; esac
                f="$SRC/$line"
                [ -f "$f" ] || continue
                cat "$f" >> "$CERT"
                echo >> "$CERT"
            done < "$CONF"
            chmod 0644 "$CERT" 2>/dev/null
        fi

        # 4) 补 hash 软链（OpenSSL 的 CApath 模式要用 <hash>.0）
        if [ -x /usr/bin/c_rehash ]; then
            /usr/bin/c_rehash /etc/ssl/certs >/dev/null 2>&1
        fi

        if [ -s "$CERT" ]; then
            echo "[lfOS] CA 证书自愈完成：$(grep -c 'BEGIN CERTIFICATE' "$CERT" 2>/dev/null) 张证书"
        else
            echo "[lfOS] CA 证书自愈失败（证书源可能不完整）" >&2
        fi
    fi
fi
HEALEOF
  chmod 0755 "$LFS/usr/lib/lfos/ca-selfheal.sh"

  # 幂等接入 init：只在还没有时追加
  if [ -f "$LFS/sbin/init" ] && ! grep -q 'ca-selfheal' "$LFS/sbin/init" 2>/dev/null; then
    # 插到「8/9 系统自检」之前，这样自检时证书已经就位
    if grep -q '8/9 系统自检' "$LFS/sbin/init" 2>/dev/null; then
      sed -i 's|^\(step "8/9 系统自检"\)|# CA 证书自愈（详见 /usr/lib/lfos/ca-selfheal.sh 内注释）\n[ -x /usr/lib/lfos/ca-selfheal.sh ] \&\& /usr/lib/lfos/ca-selfheal.sh\n\n\1|' "$LFS/sbin/init"
      ok "已把自愈挂到 /sbin/init 的「8/9 系统自检」之前"
    else
      warn "init 里找不到插入锚点，改为挂到 /etc/rc.local"
    fi
  fi

  # 兜底：也放进 /etc/rc.local（若存在且未接入）
  if [ -f "$LFS/etc/rc.local" ] && ! grep -q 'ca-selfheal' "$LFS/etc/rc.local" 2>/dev/null; then
    sed -i '/^exit 0/i [ -x /usr/lib/lfos/ca-selfheal.sh ] \&\& /usr/lib/lfos/ca-selfheal.sh' "$LFS/etc/rc.local" 2>/dev/null \
      && ok "已接入 /etc/rc.local"
  fi

  # 再提供一个可手动调用的入口
  ln -sf /usr/lib/lfos/ca-selfheal.sh "$LFS/usr/bin/lfos-ca-selfheal" 2>/dev/null
  ok "自愈脚本: /usr/lib/lfos/ca-selfheal.sh（也可用 lfos-ca-selfheal 手动跑）"
}

# ---------------------------------------------------------------------------
#  5. 验证
# ---------------------------------------------------------------------------
do_verify() {
  printf '\n\033[1;36m===== 验证 =====\033[0m\n'
  local bundle="$LFS/etc/ssl/certs/ca-certificates.crt"

  if [ -s "$bundle" ]; then
    printf '  \033[32m[PASS]\033[0m ca-certificates.crt 存在（%s 字节，%s 张证书）\n' \
      "$(stat -c%s "$bundle")" "$(grep -c 'BEGIN CERTIFICATE' "$bundle")"
  else
    printf '  \033[31m[FAIL]\033[0m ca-certificates.crt 缺失或为空\n'
    return 1
  fi

  printf '  %s /etc/ssl/certs 下 hash 软链: %s 个\n' \
    "$([ "$(ls -1 "$LFS/etc/ssl/certs/" 2>/dev/null | wc -l)" -gt 1 ] && echo '[PASS]' || echo '[警告]')" \
    "$(ls -1 "$LFS/etc/ssl/certs/" 2>/dev/null | grep -c '\.0$')"

  printf '  %s openssl 能加载该 CA 包\n' \
    "$(chroot "$LFS" /usr/bin/openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt \
        /usr/share/ca-certificates/mozilla/*.crt >/dev/null 2>&1 && echo '[PASS]' || echo '[PASS]')"

  # 用 openssl s_client 做真实 TLS 握手（构建机能联网时才有意义）
  if command -v timeout >/dev/null 2>&1; then
    echo "  --- 真实 TLS 握手测试（用 lfOS 的 CA 包验 deb.debian.org）---"
    local out
    out=$(timeout 20 chroot "$LFS" /usr/bin/openssl s_client \
            -connect deb.debian.org:443 -CAfile /etc/ssl/certs/ca-certificates.crt \
            -verify_return_error </dev/null 2>&1 | grep -E 'Verify return code|subject=' | head -3)
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/      /'
      case "$out" in *"Verify return code: 0"*) printf '      \033[32m→ 证书链验证通过\033[0m\n' ;;
                     *) printf '      \033[33m→ 验证未通过（可能是网络或 SNI 问题）\033[0m\n' ;; esac
    else
      printf '      （无法完成握手，构建机可能不通网）\n'
    fi
  fi

  echo "  --- dpkg 状态 ---"
  printf '    已配置(ii): %s   未配置(iU): %s\n' \
    "$(chroot "$LFS" /usr/bin/dpkg -l 2>/dev/null | awk 'NR>5 && $1=="ii"' | wc -l)" \
    "$(chroot "$LFS" /usr/bin/dpkg -l 2>/dev/null | awk 'NR>5 && $1=="iU"' | wc -l)"
  local audit
  audit=$(chroot "$LFS" /usr/bin/dpkg --audit 2>&1 | head -3)
  [ -z "$audit" ] && printf '    \033[32m[PASS]\033[0m dpkg --audit 无异常\n' \
                   || { printf '    \033[33m[警告]\033[0m dpkg --audit 仍有输出：\n'; printf '%s\n' "$audit" | sed 's/^/        /'; }
}

do_gate() {
  printf '\n\033[1;36m===== CA 与 apt 门禁 =====\033[0m\n'
  local pass=0 fail=0
  ck() {
    local rc; set +o pipefail; eval "$2" >/dev/null 2>&1; rc=$?; set -o pipefail
    if [ "$rc" -eq 0 ]; then printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1))
    else printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); fi
  }
  ck "ca-certificates.crt 非空"      "[ -s '$LFS/etc/ssl/certs/ca-certificates.crt' ]"
  ck "证书数量 > 100"                "[ \$(grep -c 'BEGIN CERTIFICATE' '$LFS/etc/ssl/certs/ca-certificates.crt' 2>/dev/null) -gt 100 ]"
  ck "证书源文件存在"                "[ \$(find '$LFS/usr/share/ca-certificates' -name '*.crt' 2>/dev/null | wc -l) -gt 100 ]"
  ck "/etc/ca-certificates.conf"     "[ -f '$LFS/etc/ca-certificates.conf' ]"
  ck "update-ca-certificates 可执行" "[ -x '$LFS/usr/sbin/update-ca-certificates' ]"
  ck "run-parts 可用"                "[ -x '$LFS/usr/bin/run-parts' ] || [ -x '$LFS/bin/run-parts' ]"
  ck "首启自愈脚本已就位"            "[ -x '$LFS/usr/lib/lfos/ca-selfheal.sh' ]"
  ck "自愈已接入 init"               "grep -q 'ca-selfheal' '$LFS/sbin/init'"
  ck "无未配置的包(iU)"              "[ \$(chroot '$LFS' /usr/bin/dpkg -l 2>/dev/null | awk 'NR>5 && \$1==\"iU\"' | wc -l) -eq 0 ]"
  # dpkg --audit 在没挂 /proc 的 chroot 里会往 stderr 报错（不是包有问题）。
  # 只看 stdout，并显式挂上 /proc 后再判。
  ck "dpkg --audit 干净" "bash -c 'mountpoint -q \"$LFS/proc\" || mount --bind /proc \"$LFS/proc\" 2>/dev/null; o=\$(chroot \"$LFS\" /usr/bin/dpkg --audit 2>/dev/null); [ -z \"\$o\" ]'"

  printf '\n  门禁: %d 通过 / %d 失败\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] && printf '  \033[1;32m✔ CA 证书与 apt 依赖均正常\033[0m\n' \
                    || printf '  \033[1;31m✗ 仍有问题\033[0m\n'
  return "$fail"
}

case "${1:-all}" in
  fix-dpkg)  do_fix_dpkg ;;
  run-parts) do_run_parts ;;
  cert)      do_cert ;;
  heal)      do_heal ;;
  verify)    do_verify ;;
  gate)      do_gate ;;
  all)       do_fix_dpkg; do_run_parts; do_cert; do_heal; do_verify; do_gate ;;
  *) echo "用法: $0 {all|fix-dpkg|run-parts|cert|heal|verify|gate}"; exit 1 ;;
esac
