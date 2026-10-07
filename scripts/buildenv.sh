#!/usr/bin/env bash
# ============================================================================
#  lfOS (LumenFluxOS / 流光OS) 构建环境变量
#  用法：  source /opt/lfOS/scripts/buildenv.sh
#  说明：  Phase 0 门禁产物之一。为所有后续阶段（工具链 / 内核 / 镜像）
#          提供统一、可复现的环境基线。
# ============================================================================
# shellcheck disable=SC2034

# ---------- 项目根 ----------
export LFOS="${LFOS:-/opt/lfOS}"
# 注：Windows 侧仓库位于 D:\lfOS，WSL 内映射为 /mnt/d/lfOS（源码/脚本/文档）。
#     实际编译产物放在 WSL 原生 ext4（$LFOS）以避免 9p 文件系统性能损失，
#     ext4.vhdx 本身也位于 D 盘（D:\lfOS\wsl\Ubuntu-24.04\ext4.vhdx），不占 C 盘。
export LFOS_SRC="${LFOS_SRC:-/mnt/d/lfOS}"

# ---------- 版本锁定 ----------
# 修改这里即可整体切换版本，保证可复现
export LC_ALL=POSIX
export LFS_TGT=x86_64-lfos-linux-gnu
export LFS_VERSION="12.4"
export BINUTILS_VERSION="2.44"
export GCC_VERSION="14.3.0"
export GLIBC_VERSION="2.41"
export LINUX_VERSION="6.15.4"
export MPC_VERSION="1.4.1"
export MPFR_VERSION="4.2.1"
export GMP_VERSION="6.3.0"

# ---------- LFS 目录布局 ----------
export LFS="$LFOS/build/rootfs"          # 目标根文件系统（Phase 2 产物）
export LFS_TOOLS="$LFOS/build/tools"     # 交叉工具链隔离区（Phase 1 产物）
export LFS_SOURCES="$LFOS/src"           # 源码 tarball 缓存
export LFS_LOGS="$LFOS/build/logs"       # 构建日志（可复现审计用）

# ---------- 构建并行度（按 CPU/内存自动取值，低占用模式） ----------
# 目标：构建期间宿主 Windows 仍可正常使用，不把内存打满触发 OOM/换页。
# 估算依据：单个 gcc 进程峰值约 1.2GB（glibc/gcc 部分文件可达 1.5GB）。
if [ -z "${MAKEFLAGS:-}" ]; then
  _ncpu=$(nproc)
  _mem_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
  # 内存只用到约 85%，单进程按 1.2GB 折算
  _mem_jobs=$(( _mem_gb * 85 / 100 * 10 / 12 ))
  [ "$_mem_jobs" -lt 1 ] && _mem_jobs=1
  # CPU 侧最多占 3/4，留出余量给宿主与 IO
  _cpu_jobs=$(( _ncpu * 3 / 4 ))
  [ "$_cpu_jobs" -lt 1 ] && _cpu_jobs=1
  # 取两者较小值，再压到最多 8（低占用上限）
  _jobs=$(( _cpu_jobs < _mem_jobs ? _cpu_jobs : _mem_jobs ))
  [ "$_jobs" -gt 8 ] && _jobs=8
  # 供记录与排查（必须在 unset 前导出）
  export LFOS_CPU_JOBS="$_cpu_jobs"
  export LFOS_MEM_JOBS="$_mem_jobs"
  export MAKEFLAGS="-j${_jobs}"
  export LFOS_JOBS="$_jobs"
fi
unset _ncpu _cpu_jobs _mem_jobs 2>/dev/null || true
# 内存密集步骤（glibc / gcc 终版）使用更低并行度
export LFOS_JOBS_HEAVY=$(( ${LFOS_JOBS:-2} > 2 ? ${LFOS_JOBS:-2} / 2 : 1 ))

# ---------- 统一的加固编译标志（Phase 1/2/3 共用） ----------
# 来源：Hardened Gentoo / Arch-Hardened 的 flag 模板
export LFOS_CFLAGS="-O2 -pipe -fstack-protector-strong -fstack-clash-protection -fcf-protection=full -D_FORTIFY_SOURCE=3 -fPIE"
export LFOS_LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -pie"

# ---------- 路径 ----------
export PATH="$LFS_TOOLS/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset CONFIG_SITE 2>/dev/null || true

lfos_banner() {
  cat <<EOF
============================================================
  lfOS (流光OS) 构建环境已加载
------------------------------------------------------------
  项目根      : $LFOS
  源码仓库    : $LFOS_SRC
  工具链隔离区: $LFS_TOOLS
  目标根      : $LFS
  源码缓存    : $LFS_SOURCES
  目标三元组  : $LFS_TGT
  并行度      : $MAKEFLAGS （CPU侧上限 $LFOS_CPU_JOBS / 内存侧上限 $LFOS_MEM_JOBS）
  重步骤并行度: $LFOS_JOBS_HEAVY （glibc / gcc 终版）
  编译器      : $(gcc --version 2>/dev/null | head -1)
============================================================
EOF
}
