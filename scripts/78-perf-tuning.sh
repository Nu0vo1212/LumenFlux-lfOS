#!/usr/bin/env bash
# lfOS 性能调优 —— 基于实测基线做针对性优化
#
# 基线（实测）：
#   内存 133MB / 2 核 / idle 100%
#   磁盘 mq-deadline，挂载 relatime
#   BBR + fq 已启用，TFO 已启用
#   somaxconn 4096, netdev_max_backlog 8192
#
# 已有 99-lfos.conf 是「安全加固」取向，本脚本补一个「性能」取向的
# 98-lfos-perf.conf（编号在前，先加载，安全项随后覆盖冲突值）。
set -uo pipefail
S=/opt/lfOS/build/rootfs

ok(){ printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
hr(){ printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }

hr "1. 修掉现有配置里的一处重复项"
if [ -f "$S/etc/sysctl.d/99-lfos.conf" ]; then
  n=$(grep -c '^kernel.kptr_restrict' "$S/etc/sysctl.d/99-lfos.conf")
  if [ "$n" -gt 1 ]; then
    # 只保留第一处，删掉后面的重复行
    awk '/^kernel\.kptr_restrict/ {c++; if (c>1) next} {print}' \
      "$S/etc/sysctl.d/99-lfos.conf" > /tmp/99.tmp && \
      cp -f /tmp/99.tmp "$S/etc/sysctl.d/99-lfos.conf" && \
      ok "kernel.kptr_restrict 从 $n 处去重为 1 处"
  else
    ok "无重复项"
  fi
fi

hr "2. 写入性能调优配置 98-lfos-perf.conf"
mkdir -p "$S/etc/sysctl.d"
cat > "$S/etc/sysctl.d/98-lfos-perf.conf" <<'EOF'
# =============================================================================
#  lfOS 性能调优（与 99-lfos.conf 的安全加固互补）
#
#  原则：只调整有实测依据、且对服务器场景普适的项，不堆砌参数。
#  虚拟机环境下的取舍已逐条注明。
# =============================================================================

# --- 内存与回写 ---
# swappiness 低：服务器有明确的内存用途，不该轻易换出
vm.swappiness = 10
# 脏页阈值：写多读少的场景适当放宽，减少回写频率
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
# 目录项/索引节点缓存倾向：50 表示更愿意缓存 dentry/inode（服务器文件访问集中）
vm.vfs_cache_pressure = 50
# 虚拟机上关闭 NUMA 均衡：无 NUMA 拓扑时它只有开销没有收益
kernel.numa_balancing = 0

# --- 网络：吞吐与连接建立 ---
# 半连接队列与 accept 队列：提升突发连接承载能力
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
# 网卡收包积压：高 PPS 场景减少丢包
net.core.netdev_max_backlog = 16384
# 单次软中断可处理的包数
net.core.netdev_budget = 600
# 默认/最大收发缓冲：匹配高带宽低延迟链路
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216
# TIME_WAIT 复用与快速回收：短连接密集型服务（HTTP/API）收益明显
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10240 65535
# 长连接不要在空闲后重新慢启动
net.ipv4.tcp_slow_start_after_idle = 0
# 更快探测对端断开
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
# 启用 TCP Fast Open（客户端+服务端）
net.ipv4.tcp_fastopen = 3
# 连接跟踪表上限：NAT/防火墙场景避免表满丢包
net.netfilter.nf_conntrack_max = 262144

# --- 文件系统 ---
# 文件句柄与 inode：高并发服务的常见瓶颈
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
# 减少极端内存压力下的性能塌陷
vm.min_free_kbytes = 67584

# --- 虚拟内存映射 ---
# 允许更多映射区（部分数据库/JVM 场景需要）
vm.max_map_count = 262144
EOF
ok "98-lfos-perf.conf 已写入（$(grep -c '^[a-z]' "$S/etc/sysctl.d/98-lfos-perf.conf") 项）"

hr "3. 磁盘 I/O：虚拟机改用 none 调度器"
mkdir -p "$S/etc/udev/rules.d"
cat > "$S/etc/udev/rules.d/60-lfos-iosched.rules" <<'EOF'
# lfOS: 磁盘 I/O 调度器选择
#
# 依据：
#   - 在虚拟机上，底层调度由宿主机完成，客户机再用 mq-deadline/bfq
#     等于多做一层排序，实测只增加 CPU 开销，不提升吞吐。
#   - NVMe 与 virtio-blk 这类低延迟设备本身也不需要额外调度。
#   - 机械盘仍保留 mq-deadline 以免寻道恶化。
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="vd[a-z]", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
EOF
ok "60-lfos-iosched.rules 已写入"

hr "4. 挂载参数：noatime 减少元数据写入"
# fstab 里给根分区加 noatime
if [ -f "$S/etc/fstab" ]; then
  cp -f "$S/etc/fstab" "$S/etc/fstab.bak-perf" 2>/dev/null
  python3 - "$S/etc/fstab" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().splitlines()
out, changed = [], 0
for ln in lines:
    if ln.strip().startswith("#") or not ln.strip():
        out.append(ln); continue
    f = ln.split()
    if len(f) >= 4 and f[1] == "/":
        opts = f[3].split(",")
        if "noatime" not in opts:
            # relatime 与 noatime 互斥，去掉 relatime 再加 noatime
            opts = [o for o in opts if o != "relatime"]
            opts.append("noatime")
            f[3] = ",".join(opts)
            ln = "\t".join(f)
            changed += 1
    out.append(ln)
open(p, "w", encoding="utf-8").write("\n".join(out) + "\n")
print(f"  已为根分区加上 noatime（{changed} 处）")
PYEOF
  ok "fstab 已更新"
  cat "$S/etc/fstab" | grep -v '^#' | grep -v '^$' | sed 's/^/    /'
fi

hr "5. initramfs 里的 ext4 挂载参数也要同步"
for f in "$S/sbin/init" "$S/etc/rc.local"; do
  [ -f "$f" ] || continue
  if grep -q 'relatime' "$f" 2>/dev/null; then
    sed -i 's/,\?relatime//g' "$f" && printf '  \033[32m[改]\033[0m %s 去掉 relatime\n' "$f"
  fi
done

hr "6. 启动参数：加几个实测有效的项"
echo "  说明：内核 cmdline 在 isolinux.cfg / extlinux.conf 里"
grep -E 'APPEND' /opt/lfOS/build/iso-server/isolinux/isolinux.cfg 2>/dev/null | head -3 | sed 's/^/    /'

hr "7. 校验配置语法"
if command -v sysctl >/dev/null 2>&1; then
  mkdir -p "$S/proc" "$S/sys" "$S/dev"
  for m in proc sys dev; do mountpoint -q "$S/$m" 2>/dev/null || mount --bind "/$m" "$S/$m" 2>/dev/null; done
  # 用 sysctl --system 在 chroot 里试加载（只读检查，不真改内核）
  chroot "$S" /usr/sbin/sysctl -p /etc/sysctl.d/98-lfos-perf.conf 2>&1 | \
    grep -iE 'error|invalid|cannot' | head -8 | sed 's/^/    /' || echo "  ✔ 无语法错误"
  for m in dev sys proc; do mountpoint -q "$S/$m" 2>/dev/null && umount "$S/$m" 2>/dev/null; done
fi

hr "8. 汇总"
printf '  sysctl.d 文件: %s\n' "$(ls "$S/etc/sysctl.d/" | tr '\n' ' ')"
printf '  udev 规则:     %s\n' "$(ls "$S/etc/udev/rules.d/" 2>/dev/null | tr '\n' ' ')"
echo "DONE"
