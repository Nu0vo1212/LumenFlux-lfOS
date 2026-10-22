#!/usr/bin/env bash
# 内核裁剪：bzImage 9669KB → 目标 <8000KB
#
# 依据（都在上一步实测过）：
#   vmlinux 34MB，gzip 后 10655KB，xz 后 8402KB —— 光换压缩就省 2.2MB
#   体积大户：
#     drivers/gpu  2483 KB  ← 服务器版不需要 DRM（vmwgfx 等一堆）
#     drivers/net  1931 KB
#     drivers/usb  1259 KB  ← 虚拟机用不到 USB 存储/HID
#     drivers/tty   969 KB
#     fs           5.4 MB
#     net          8.5 MB
#   printk 缓冲 LOG_BUF_SHIFT=18 → 256KB，可降到 16 省 192KB
#
# 原则：
#   - 只砍**确认用不到**的（服务器无图形、VirtualBox 无 USB 外设需求）
#   - 砍完必须能启动 —— 每步都留回滚，最后整机验证
set -uo pipefail
FRAG=/mnt/d/lfOS/config/kernel-lfos-vbox.fragment

ok(){ printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
hr(){ printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }

hr "1. 备份 fragment"
cp -f "$FRAG" "$FRAG.bak-trim-$(date +%s)" 2>/dev/null && ok "已备份"

hr "2. 写入裁剪配置"
python3 - "$FRAG" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="replace").read()

block = """
# =============================================================================
#  ���积裁剪（v0.0.3）
#
#  背景：bzImage 一度 9669KB，超出 8MB 目标。实测 vmlinux 34MB，
#        各子系统编译产物体积为 drivers 17.3MB / arch 14.7MB / net 8.5MB /
#        fs 5.4MB / kernel 5.6MB。据此做针对性裁剪。
#
#  取舍原则：只砍「确认用不到」的，不为了数字好看而砍掉可能需要的功能。
# =============================================================================

# --- 压缩算法：gzip → xz ---
# 实测同一 vmlinux：gzip 10655KB / xz 8402KB，省 21%。
# 代价是解压稍慢（约 +100~200ms），但省下 2.2MB 对镜像体积意义更大。
CONFIG_KERNEL_XZ=y
# CONFIG_KERNEL_GZIP is not set

# --- 图形栈整块移除 ---
# 依据：VBOX-OS 是服务器发行版，不含任何图形界面。此前为尝试桌面版编译了
#       DRM/vmwgfx/vboxvideo，实测在 VirtualBox 下全都走不通（vboxvideo 触发
#       内核 Oops，vmwgfx 报 unsupported hypervisor），桌面方案已放弃并清理。
#       这些驱动现在纯占体积：drivers/gpu 共 2483KB，其中 vmwgfx 就占 267KB+。
# 保留 FB_VESA / FB_EFI：控制台仍需要 framebuffer 输出（文本模式）
# CONFIG_DRM is not set
# CONFIG_DRM_VMWGFX is not set
# CONFIG_DRM_VBOXVIDEO is not set
# CONFIG_DRM_TTM is not set
# CONFIG_DRM_KMS_HELPER is not set
# CONFIG_DRM_I915 is not set
# CONFIG_AGP is not set
# CONFIG_FB_UDL is not set

# --- USB 子系统裁剪 ---
# 依据：服务器场景使用虚拟磁盘（SATA/virtio），不接 USB 外设。
#       但保留 USB 核心（部分虚拟化平台需要 USB 控制器枚举）。
#       drivers/usb 共 1259KB。
# CONFIG_USB_STORAGE is not set
# CONFIG_USB_HID is not set
# CONFIG_HID_APPLE is not set
# CONFIG_HID_BELKIN is not set
# CONFIG_HID_CHERRY is not set
# CONFIG_HID_EZKEY is not set
# CONFIG_HID_LOGITECH is not set
# CONFIG_HID_MICROSOFT is not set
# CONFIG_HID_MONTEREY is not set
# CONFIG_HID_PETALYNX is not set
# CONFIG_HID_SAMSUNG is not set
# CONFIG_HID_SONY is not set
# CONFIG_HID_SUNPLUS is not set

# --- 调试与噪音 ---
# ATA_VERBOSE_ERROR：把每个 ATA 错误的详细信息打进日志，服务器不需要这么啰嗦
# CONFIG_ATA_VERBOSE_ERROR is not set
# LOG_BUF_SHIFT 18→16：日志环形缓冲 256KB→64KB。
#   注意：启动日志内容较多时可能被截断，若排查问题需要可临时改回 18。
CONFIG_LOG_BUF_SHIFT=16

# --- 用不到的网络协议与调度器 ---
# 说明：net 子系统 8.5MB 是大头，但大部分是 TCP/IP 核心，
#       能安全移除的是那些服务器不会用的链路层/协议。
# CONFIG_ATM is not set
# CONFIG_X25 is not set
# CONFIG_LAPB is not set
# CONFIG_PHONET is not set
# CONFIG_IEEE802154 is not set
# CONFIG_6LOWPAN is not set
# CONFIG_NFC is not set
# CONFIG_HAMRADIO is not set
# CONFIG_IRDA is not set
# CONFIG_RDS is not set
# CONFIG_TIPC is not set
# CONFIG_CAIF is not set
# CONFIG_QRTR is not set
# CONFIG_MPLS is not set
# CONFIG_NET_SCH_HHF is not set
# CONFIG_NET_SCH_PRIO is not set
# CONFIG_NET_SCH_SFB is not set
# CONFIG_NET_SCH_SFQ is not set
# CONFIG_NET_SCH_TBF is not set
# CONFIG_NET_SCH_NETEM is not set
# CONFIG_NET_SCH_INGRESS is not set

# --- 冷门文件系统（服务器不会用的）---
# 已确认 ext4/squashfs/iso9660/overlayfs 保留
# CONFIG_NTFS3_FS is not set
# CONFIG_NTFS_FS is not set
# CONFIG_VFAT_FS is not set
# CONFIG_EXFAT_FS is not set
# CONFIG_MINIX_FS is not set
# CONFIG_QNX4FS_FS is not set
# CONFIG_QNX6FS_FS is not set
# CONFIG_SYSV_FS is not set
# CONFIG_UFS_FS is not set
# CONFIG_OMFS_FS is not set
# CONFIG_HPFS_FS is not set
# CONFIG_ADFS_FS is not set
# CONFIG_AFFS_FS is not set
# CONFIG_ECRYPT_FS is not set
# CONFIG_9P_FS is not set
# CONFIG_CIFS is not set
# CONFIG_NFS_FS is not set
# CONFIG_NFSD is not set
# CONFIG_CEPH_FS is not set
# CONFIG_CIFS_DEBUG is not set

# --- 加密算法精简 ---
# crypto 子系统总共 0.7MB，保留 TLS/SSH 需要的即可
# CONFIG_CRYPTO_USER is not set
# CONFIG_CRYPTO_CRYPTD is not set
# CONFIG_CRYPTO_CAST5 is not set
# CONFIG_CRYPTO_CAST6 is not set
# CONFIG_CRYPTO_BLOWFISH is not set
# CONFIG_CRYPTO_TWOFISH is not set
# CONFIG_CRYPTO_SERPENT is not set
# CONFIG_CRYPTO_CAMELLIA is not set
# CONFIG_CRYPTO_CAST_COMMON is not set
"""

if "体积裁剪（v0.0.3）" not in s:
    s += block
    open(p, "w", encoding="utf-8").write(s)
    print("  已追加裁剪配置")
else:
    print("  已存在，跳过")
PYEOF

echo
echo "  --- 检查冲突：图形相关到底是 y 还是 is not set ---"
grep -cE '^# CONFIG_DRM is not set' "$FRAG" | sed 's/^/  新块中 DRM 关闭行数: /'
grep -cE '^CONFIG_DRM=y' "$FRAG" | sed 's/^/  旧块中 DRM 启用行数: /'

hr "3. 处理冲突（后出现的生效，但要显式清理旧值）"
python3 - "$FRAG" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().splitlines()

# 找到裁剪块开始位置
cut = None
for i, l in enumerate(lines):
    if "体积裁剪（v0.0.3）" in l:
        cut = i
        break
if cut is None:
    print("  未找到裁剪块")
    sys.exit(0)

before, after = lines[:cut], lines[cut:]
killed = {
    "CONFIG_DRM=y": "# CONFIG_DRM is not set",
    "CONFIG_DRM_VMWGFX=y": "# CONFIG_DRM_VMWGFX is not set",
    "CONFIG_DRM_VBOXVIDEO=y": "# CONFIG_DRM_VBOXVIDEO is not set",
    "CONFIG_DRM_TTM=y": "# CONFIG_DRM_TTM is not set",
    "CONFIG_DRM_KMS_HELPER=y": "# CONFIG_DRM_KMS_HELPER is not set",
    "CONFIG_USB_STORAGE=y": "# CONFIG_USB_STORAGE is not set",
    "CONFIG_USB_HID=y": "# CONFIG_USB_HID is not set",
}
n = 0
out = []
for l in before:
    ls = l.strip()
    if ls in killed:
        out.append(killed[ls])
        n += 1
    else:
        out.append(l)
open(p, "w", encoding="utf-8").write("\n".join(out + after) + "\n")
print(f"  把旧块里 {n} 处 y 改成了 is not set")
PYEOF

echo "  --- 最终确认关键项 ---"
for k in 'CONFIG_KERNEL_XZ=y' '# CONFIG_DRM is not set' '# CONFIG_DRM_VMWGFX is not set' \
         'CONFIG_LOG_BUF_SHIFT=16' '# CONFIG_USB_STORAGE is not set'; do
  n=$(grep -cx "$k" "$FRAG" 2>/dev/null || echo 0)
  printf '    %-38s 出现 %s 次\n' "$k" "$n"
done
echo "DONE"
