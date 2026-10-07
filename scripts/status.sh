#!/usr/bin/env bash
# ============================================================================
#  lfOS 构建进度速览（一条命令看清状态，输出精简）
#  用法： bash /opt/lfOS/scripts/status.sh
# ============================================================================
LFOS="${LFOS:-/opt/lfOS}"
OUT="$LFOS/build/logs/30-build-toolchain.out"

echo "================ lfOS 构建状态 ================"
echo "时间   : $(date '+%Y-%m-%d %H:%M:%S')"
echo "负载   :$(uptime | sed 's/.*load average/load average/')"
echo "内存   : $(free -h | awk '/^Mem:/{print $3" 已用 / "$2" 总（可用 "$7"）"}')"
echo "并行度 : $(pgrep -c cc1 2>/dev/null || echo 0) 个 cc1 进程在跑"

echo
echo "--- 阶段进度（从日志提取）---"
grep -E '^=====|done:|FATAL|\[FAIL\]|\[PASS\]|exited rc=' "$OUT" 2>/dev/null | tail -12 | sed 's/\x1b\[[0-9;]*m//g'

echo
echo "--- 最近 5 行 ---"
tail -5 "$OUT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'

echo
echo "--- 产物体积 ---"
for d in "$LFOS/build/tools" "$LFOS/build/rootfs" "$LFOS/src"; do
  [ -d "$d" ] && printf '  %-28s %s\n' "$(basename "$d")" "$(du -sh "$d" 2>/dev/null | cut -f1)"
done
echo "  磁盘剩余                     $(df -h "$LFOS" | awk 'NR==2{print $4}')"

echo
echo "--- 日志文件 ---"
ls -lh "$LFOS/build/logs/"*.log 2>/dev/null | awk '{printf "  %-34s %s\n", $9, $5}' | tail -12
echo "=============================================="
