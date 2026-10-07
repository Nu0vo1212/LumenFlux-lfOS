#!/usr/bin/env bash
# ============================================================================
#  lfOS Phase 0 - WSL 宿主调优
#  - 关闭 swap（构建机上 swap 无意义且会额外吃 C/D 盘空间）
#  - 固定 locale / 时区（保证构建可复现）
#  - 建立 WSL 原生构建区 /opt/lfOS（避开 /mnt/d 的 9p 性能损失）
#  - 把 Windows 侧仓库（/mnt/d/lfOS）与原生构建区互链，方便两边访问
#  用法： wsl -d Ubuntu-24.04 -u root -- bash /mnt/d/lfOS/scripts/05-wsl-tune.sh
# ============================================================================
set -uo pipefail
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "1/6 关闭 swap"
swapoff -a 2>/dev/null || true
if grep -qE '^\s*[^#].*\sswap\s' /etc/fstab 2>/dev/null; then
  cp /etc/fstab /etc/fstab.lfos-bak
  sed -i -E 's|^\s*([^#].*\sswap\s.*)$|# \1|' /etc/fstab
  echo "已注释 fstab 中的 swap 条目（备份 /etc/fstab.lfos-bak）"
else
  echo "fstab 中无 swap 条目"
fi

log "2/6 固定 locale 与时区（可复现构建要求）"
apt-get install -y --no-install-recommends locales tzdata >/dev/null 2>&1 || true
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null || true
locale-gen >/dev/null 2>&1 || true
printf 'LANG=en_US.UTF-8\nLC_ALL=en_US.UTF-8\n' > /etc/default/locale
ln -snf /usr/share/zoneinfo/UTC /etc/localtime
echo "UTC" > /etc/timezone
echo "locale=en_US.UTF-8  timezone=UTC"

log "3/6 设置构建主机名"
printf 'lfos-build\n' > /etc/hostname
if ! grep -q 'lfos-build' /etc/hosts; then
  printf '127.0.1.1\tlfos-build\n' >> /etc/hosts
fi
hostname lfos-build 2>/dev/null || true
echo "hostname=lfos-build"

log "4/6 建立 WSL 原生构建区 /opt/lfOS"
mkdir -p /opt/lfOS/{src,scripts,build/{tools,rootfs,logs,img,baseline},config,ci}
chown -R lfos:lfos /opt/lfOS

log "5/6 双向软链接（Windows 侧可直观看到构建输出）"
# Windows 仓库 -> 原生构建区
if [ ! -e /mnt/d/lfOS/wsl-native ]; then
  ln -sfn /opt/lfOS /mnt/d/lfOS/wsl-native 2>/dev/null \
    && echo "已创建 /mnt/d/lfOS/wsl-native -> /opt/lfOS" \
    || echo "软链接创建失败（Windows 侧仅作展示用，不影响构建）"
fi
# 原生构建区 -> Windows 仓库脚本/配置（保持单一真源）
rm -rf /opt/lfOS/scripts /opt/lfOS/config 2>/dev/null || true
ln -sfn /mnt/d/lfOS/scripts /opt/lfOS/scripts
ln -sfn /mnt/d/lfOS/config  /opt/lfOS/config
echo "已链接 /opt/lfOS/scripts -> /mnt/d/lfOS/scripts"
echo "已链接 /opt/lfOS/config  -> /mnt/d/lfOS/config"

log "6/6 内核构建前置检查"
if [ -d /usr/src/linux-headers-"$(uname -r)" ]; then
  echo "已存在 WSL 内核头文件目录"
else
  echo "（正常）WSL 内核无发行版头文件，lfOS 将自行下载 ${LINUX_VERSION:-6.15.4} 源码构建"
fi

echo
echo "=================== WSL 调优完成 ==================="
echo "swap    : $(swapon --show 2>/dev/null | wc -l) 个 swap 设备（0 = 已关闭）"
echo "locale  : $(locale 2>/dev/null | head -1)"
echo "hostname: $(hostname)"
echo "构建区  : /opt/lfOS（$(df -h /opt/lfOS | awk 'NR==2{print $4}') 可用）"
echo "===================================================="
