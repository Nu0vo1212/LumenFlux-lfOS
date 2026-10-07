#!/usr/bin/env bash
# ============================================================================
#  lfOS 后台构建启动器
#  用法： bash /opt/lfOS/scripts/run-bg.sh <脚本路径> [参数...]
#  作用： 用 setsid 完全脱离当前 shell 运行，输出写入 $LFS_LOGS/<名字>.out
#         即使 Windows 侧的 wsl.exe 调用结束，构建也继续跑。
#  查看： tail -f /opt/lfOS/build/logs/<名字>.out
# ============================================================================
set -uo pipefail

SCRIPT="${1:?用法: run-bg.sh <脚本路径> [参数...]}"
shift || true

LFOS="${LFOS:-/opt/lfOS}"
LFS_LOGS="${LFS_LOGS:-$LFOS/build/logs}"
mkdir -p "$LFS_LOGS"

NAME=$(basename "$SCRIPT" .sh)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$LFS_LOGS/${NAME}.out"
PIDF="$LFS_LOGS/${NAME}.pid"

# 归档上一轮输出，便于对比
[ -s "$OUT" ] && mv -f "$OUT" "$LFS_LOGS/${NAME}.${STAMP}.out"

cd "$LFOS" || exit 1
setsid nohup bash -c "
  source /opt/lfOS/scripts/buildenv.sh
  echo \"########## lfOS bg job start \$(date -u +%Y-%m-%dT%H:%M:%SZ) ##########\"
  echo \"script : $SCRIPT \$*\"
  echo \"jobs   : \$MAKEFLAGS (heavy \$LFOS_JOBS_HEAVY)\"
  echo \"cpu    : \$(nproc)  mem: \$(awk '/MemTotal/{printf \"%.1fGB\", \$2/1024/1024}' /proc/meminfo)\"
  echo
  bash '$SCRIPT' $*
  rc=\$?
  echo
  echo \"########## exited rc=\$rc \$(date -u +%Y-%m-%dT%H:%M:%SZ) ##########\"
" > "$OUT" 2>&1 < /dev/null &

sleep 1
# 记录实际进程号（setsid 后的 bash 子进程）
pgrep -f "bash '$SCRIPT'" | head -1 > "$PIDF" 2>/dev/null || true

echo "已启动后台构建: $SCRIPT $*"
echo "  输出日志: $OUT"
echo "  PID 文件: $PIDF"
echo "  查看进度: tail -f $OUT"
sleep 2
echo
echo "--- 当前日志开头 ---"
head -20 "$OUT" 2>/dev/null
