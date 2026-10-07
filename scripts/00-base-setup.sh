#!/usr/bin/env bash
# lfOS Phase 0 - 宿主构建环境准备（WSL2 Ubuntu 24.04）
# 在 WSL 内以 root 执行：wsl -d Ubuntu-24.04 -u root -- bash /mnt/d/lfOS/scripts/00-base-setup.sh
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "1/6 创建构建用户 lfos"
if id lfos >/dev/null 2>&1; then
  echo "用户 lfos 已存在"
else
  useradd -m -s /bin/bash -G sudo,adm lfos && echo "已创建 lfos"
fi
printf 'lfos ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-lfos-nopasswd
chmod 440 /etc/sudoers.d/90-lfos-nopasswd

printf '[user]\ndefault=lfos\n[boot]\nsystemd=true\n[interop]\nenabled=true\nappendWindowsPath=true\n' > /etc/wsl.conf
echo "已写入 /etc/wsl.conf"

log "2/6 切换 APT 源到阿里云镜像（加速）"
if [ -f /etc/apt/sources.list.d/ubuntu.sources ] && curl -fsSL --max-time 30 \
     https://mirrors.aliyun.com/ubuntu/ubuntu-noble.sources -o /tmp/ubuntu.sources; then
  sed -i 's|^URIs:.*|URIs: https://mirrors.aliyun.com/ubuntu/|' /tmp/ubuntu.sources
  cp /tmp/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources
  echo "已切换为 aliyun 镜像"
else
  echo "镜像获取失败，保留官方源"
fi

log "3/6 apt update + 升级基础包"
apt-get update -y
apt-get upgrade -y

log "4/6 安装 LFS/BLFS 宿主必需工具链"
PKGS_CORE="binutils gcc g++ make perl python3 tar xz-utils bzip2 gzip wget curl git patch diffutils findutils grep sed gawk m4 bison flex texinfo gettext libtool autoconf automake pkg-config file bc time expect dejagnu"
PKGS_DEV="build-essential zlib1g-dev libssl-dev libncurses-dev libelf-dev libarchive-zip-perl libfile-which-perl libdb-dev libgdbm-dev libexpat1-dev libcap-dev libpam0g-dev uuid-dev libreadline-dev libffi-dev libgmp-dev libmpfr-dev libmpc-dev libisl-dev gperf libtasn1-dev libidn2-dev libunistring-dev libpsl-dev libgnutls28-dev libkrb5-dev libacl1-dev libattr1-dev libblkid-dev libmount-dev libseccomp-dev"
PKGS_SYS="coreutils util-linux procps psmisc kmod cpio rsync vim less htop tree jq unzip zip dos2unix ca-certificates gnupg command-not-found man-db iproute2 net-tools inetutils-ping nftables lynis shellcheck qemu-utils xorriso mtools dosfstools e2fsprogs parted gdisk squashfs-tools cpio rsync pahole dwarves bc"
apt-get install -y --no-install-recommends $PKGS_CORE $PKGS_DEV $PKGS_SYS

log "5/6 安装 Python 构建辅助"
apt-get install -y --no-install-recommends python3-pip python3-venv python3-setuptools python3-yaml

log "6/6 校验版本清单"
{
  echo "# lfOS host toolchain versions"
  echo "# generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for c in gcc g++ ld make perl python3 bash tar xz bison gawk sed grep; do
    if command -v "$c" >/dev/null 2>&1; then
      printf '%s=%s\n' "$c" "$($c --version 2>/dev/null | head -1)"
    else
      printf '%s=MISSING\n' "$c"
    fi
  done
} | tee /root/host-toolchain.versions

echo
echo "===================== 环境准备完成 ====================="
echo "gcc    : $(gcc --version | head -1)"
echo "glibc  : $(ldd --version | head -1)"
echo "内核   : $(uname -r)"
echo "磁盘   : $(df -h / | awk 'NR==2{print $2" 总 / "$4" 可用"}')"
echo "内存   : $(free -h | awk '/^Mem:/{print $2}')"
echo "======================================================="
