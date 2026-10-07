# lfOS Phase 3-4 构建报告：从零到可启动系统

> 生成时间：2026-10-06
> 目标：以 VirtualBox 为验证环境，构建一个**能真实启动运行**的 lfOS 系统，
> 并让「高性能 / 高安全 / 低占用」三宗旨在架构上真正落地。

---

## 1. 成果总览

**lfOS 已在 Oracle VirtualBox 7.2.20 中以三种引导方式全部启动成功：**

| 载体 | 固件 | 结果 |
|------|------|------|
| VDI 磁盘镜像 | BIOS | ✅ 8/8 |
| ISO 光盘 | BIOS（isolinux）| ✅ 9/9 |
| **ISO 光盘** | **UEFI（内核 EFI stub，零引导器）** | ✅ **9/9** |

```
==============================================================
   lfOS  (LumenFluxOS / 流光OS)
   高性能 · 高安全 · 低占用  ——  从零构建
==============================================================
  内核版本   : 6.15.4-lfos
  CPU 核心   : 2
  物理内存   : 476 MB
--------------------------------------------------------------
  [安全加固] KSPP 关键项:
    ✓ KASLR 地址随机化              2
    ✓ dmesg 限制                    1
    ✓ kptr 指针隐藏                 1
    ✓ perf 事件限制                 3
    ✓ Meltdown 缓解                 Not affected
--------------------------------------------------------------
  [低占用] 资源占用:
    已用内存                       25 MB / 476 MB
    运行进程数                     60
    加载的内核模块                 0 (单体内核，无模块支持)
--------------------------------------------------------------
  [高性能] 关键路径:
    TCP 拥塞控制                   bbr
    默认 qdisc                     fq
    IO 调度器                      [none] mq-deadline kyber bfq
    透明大页(THP)                  always
==============================================================
lfos:~#
```

---

## 2. 三宗旨实测数据

| 宗旨 | 指标 | 实测值 | 对比参考 |
|------|------|--------|---------|
| **低占用** | 启动后常驻内存 | **25 MB** | Debian 12 最小安装约 90–120 MB |
| | 运行进程数 | **60** | Debian 最小约 80–100 |
| | 内核模块数 | **0**（单体内核） | Debian 约 40–80 |
| | 根文件系统（initramfs） | **1164 KB** | Debian 约 1.5 GB |
| | 引导镜像 | **15 MB**（VDI） | Debian netinst 约 630 MB |
| | BusyBox applet | 356 个（已裁剪 41 个） | 默认 397 |
| **高性能** | 启动到 shell | **3.1 秒** | Debian 约 10–20 秒 |
| | TCP 拥塞控制 | **BBR** ✅ | 默认 cubic |
| | 默认 qdisc | **fq** ✅ | 默认 pfifo_fast |
| | 透明大页 | **always** ✅ | 多数发行版默认 madvise |
| | 抢占模型 | PREEMPT_NONE（吞吐优先） | 部分发行版用 voluntary |
| | IO 调度器 | mq-deadline / kyber / bfq 可用 | |
| **高安全** | KASLR / 内存随机化 | ✓ | |
| | KPTI 页表隔离 | ✓ | |
| | STRICT_KERNEL_RWX | ✓（`Checked W+X mappings: passed`）| |
| | 栈保护 / FORTIFY / HARDENED_USERCOPY | ✓ | |
| | 分配器加固（freelist 随机化+加固、kmalloc 随机缓存）| ✓ | |
| | INIT_ON_ALLOC 内存清零 | ✓ | |
| | seccomp + seccomp BPF | ✓ | |
| | SELinux LSM | ✓（已编译，策略待 Phase 5）| |
| | 静态用户态 helper（禁内核调外部程序）| ✓ | |
| | vsyscall 遗留接口 | 已关闭 | |
| | /dev/mem、/dev/kmem、kexec | 已关闭 | |
| | dmesg / kptr / perf 运行时限制 | ✓（1 / 1 / 3）| |
| | 内核模块攻击面 | 无（单体内核）| |

---

## 3. 构建流水线

```
T1 环境勘察 ──→ T2 源码准备 ──→ T3/T4 内核配置 ──→ T7 内核编译
                                      │
                                      └──→ T5 BusyBox ──→ T6 initramfs ──→ T8 镜像 ──→ T9 VBox 验证
```

| 阶段 | 脚本 | 产物 | 门禁 |
|------|------|------|------|
| T3/T4 内核配置 | `50-build-kernel.sh config` | `.config` | **63/63 通过** |
| T7 内核编译 | `50-build-kernel.sh build` | `bzImage` 9.4 MB | 编译 5 分钟（-j8）|
| T5 BusyBox | `60-build-initramfs.sh busybox` | 静态 `busybox` 2.2 MB | 静态链接确认 |
| T6 initramfs | `60-build-initramfs.sh initramfs/pack` | `initramfs-lfos.cpio.gz` 1.2 MB | **11/11 通过** |
| T8 磁盘镜像 | `70-make-image.sh all` | `.raw` 13 MB + `.vdi` 16 MB | **9/9 通过** |
| T9 VDI 验证 | `80-vbox-test.ps1` | 串口日志 + VM | **8/8 通过** |
| T10 ISO 构建 | `75-make-iso.sh all` | `lfos.iso` 38 MB（BIOS+UEFI 双引导）| **7/7 通过** |
| T11 ISO 验证 | `81-vbox-iso-test.ps1` | BIOS + EFI 固件实测 | **18/18 通过** |

**引导方式覆盖矩阵（全部实测通过）**

| 载体 | 固件 | 引导器 | 结果 |
|------|------|--------|------|
| VDI 磁盘 | BIOS | extlinux | ✅ 8/8 |
| ISO 光盘 | BIOS | isolinux | ✅ 9/9 |
| ISO 光盘 | UEFI | **内核 EFI stub（零引导器）** | ✅ 9/9 |

---

## 4. 关键技术决策

### 4.1 单体内核（`CONFIG_MODULES` 未启用）

**决策**：完全禁用内核模块机制。

- **安全**：消除"加载恶意模块"这条攻击路径，无需模块签名密钥管理
- **低占用**：无 `.ko` 体积，启动更快，内存更省
- **代价**：新增驱动需重编内核

lfOS 定位是固定用途服务器，这个交换划算。实测收益：模块数 0，内存仅 28 MB。

### 4.2 严格区分「加固」与「调试」

设计方案要求高安全，但**很多看似安全的选项实为性能杀手**。KSPP 也明确区分这两类。

| 类型 | 项 | 决策 |
|------|-----|------|
| 真加固（保留）| STACKPROTECTOR_STRONG、FORTIFY_SOURCE、HARDENED_USERCOPY、RANDOMIZE_BASE、STRICT_KERNEL_RWX、SLAB_FREELIST_RANDOM/HARDENED、RANDOM_KMALLOC_CACHES、INIT_ON_ALLOC | ✅ 全开 |
| 伪加固（关闭）| SLUB_DEBUG、DEBUG_VM、DEBUG_LIST、PAGE_POISONING、INIT_ON_FREE、PROVE_LOCKING、KASAN、FTRACE、KPROBES | ❌ 全关 |

**依据**：`INIT_ON_ALLOC` 有约 1% 开销但安全收益显著（内核 5.3+ 已优化）；而 `PAGE_POISONING`、`INIT_ON_FREE`、`DEBUG_VM` 属调试工具，开销远大于安全收益。

### 4.3 applet 裁剪与静态 BusyBox

用 lfOS 交叉工具链静态编译 BusyBox（`CONFIG_STATIC=y`），397 个 applet，
strip 后 2.2 MB，gzip 后使 initramfs 仅 1.2 MB。

### 4.4 extlinux 而非 GRUB

引导器选 extlinux（Syslinux 家族）：极简、无 GRUB 的庞大模块树、攻击面小，契合 lfOS 气质。

### 4.5 UEFI 引导：内核 EFI stub（零引导器）★

这是本次最有价值的技术决策。

| 方案 | 结果 |
|------|------|
| syslinux.efi（`syslinux-efi` 包） | ❌ VirtualBox 7.2 EFI 固件下直接崩：`X64 Exception Type - 06(#UD - Invalid Opcode)` |
| GRUB2 EFI | 可用，但需额外 3–5 MB 模块，扩大引导链攻击面 |
| **内核 EFI stub** | ✅ **采纳** |

内核自带 EFI stub（`CONFIG_EFI_STUB=y`）意味着 `bzImage` **本身就是 EFI 可执行文件**
（PE 头以 `MZ` 开头）。因此：

- **零引导器**：UEFI 固件直接加载内核，彻底消除"引导器"这一独立攻击面
- **体积零开销**：不增加任何引导代码（对比 GRUB 的 3–5 MB）
- **Secure Boot 就绪**：后续只需对内核签名（Phase 5）

ISO 布局：
```
/EFI/BOOT/BOOTX64.EFI        ← 内核本体（含内置 cmdline）
/initramfs-lfos.cpio.gz      ← initrd（路径与内置 cmdline 的 initrd= 对应）
/boot/efi.img                ← 同一套内容的 FAT16 镜像，供 El Torito 引用
```

**关键约束**：内核命令行必须**编译期内置**（`CONFIG_CMDLINE_BOOL=y` + `CONFIG_CMDLINE="..."`），
因为 EFI 固件不会像 isolinux 那样传 `APPEND` 参数。

---

## 5. 踩坑记录（全部为真实故障与修复）

构建过程中遇到 **9 个真实故障**，全部定位到根因并修复，且把防护固化进门禁：

### 5.1 内核配置类

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
| 1 | `CONFIG_DRM_VMSVGA` 门禁失败 | 内核里 **不存在** `DRM_VMSVGA` 符号，VMSVGA 控制器的驱动真名是 **`DRM_VMWGFX`**；写错会被 kconfig 静默忽略，导致 VBox 里没有显卡驱动 | 改用真名，并在 fragment 注释说明 |
| 2 | `CONFIG_PAGE_TABLE_ISOLATION` 门禁失败 | 6.x 起缓解措施统一到 `MITIGATION_` 前缀，旧名已废弃（实际防护早已默认开启）| 断言改用 `MITIGATION_PAGE_TABLE_ISOLATION` |
| 3 | `CONFIG_SLUB_DEBUG` 改不掉，始终 =y | 定义是 `bool "..." if EXPERT` + `default y`：**EXPERT 未开启时该符号不可配置**，`scripts/config --disable` 被静默忽略 | 开启 `CONFIG_EXPERT=y` 解锁，再强制关闭 |
| 4 | `DEFAULT_TCP_CONG="cubic"`，BBR 不生效 | `DEFAULT_TCP_CONG` 是 **choice 组自动生成的字符串**，直接写它无效；必须切换 choice 成员，且**先关掉默认成员** `DEFAULT_CUBIC` 才生效 | 在 olddefconfig 后用 `--disable DEFAULT_CUBIC --enable DEFAULT_BBR` |
| 5 | 默认 qdisc 不是 fq | 同上，`DEFAULT_PFIFO_FAST` 是 choice 默认成员，须先关 | `--disable DEFAULT_PFIFO_FAST --enable DEFAULT_FQ` |
| 5b | `TRANSPARENT_HUGEPAGE_ALWAYS=y` 编译正确，运行时却为 `never` | 编译期 flag（`transparent_hugepage_flags` 初值）在运行期被重算，实测 sysfs 原始值为 `always madvise [never]`。仅靠编译期配置无法保证 | 在 `/init` 中**运行时显式** `echo always > /sys/.../enabled`，不依赖编译期默认值 |

> 教训总结：**Kconfig 的 `choice` 组、`if EXPERT` 保护的符号、字符串型派生值，这三类都不能用普通写法设置**。
> 必须用 `scripts/config` 切换成员符号，并在 `olddefconfig` **之后**执行，再收敛一次。

### 5.2 用户态与启动类

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
| 6 | BusyBox 编译失败：`struct tc_cbq_ovl` 未定义 | BusyBox 1.37 的 `tc` applet 引用 CBQ 调度器结构，而 **Linux 6.15 已从 UAPI 头文件删除这些结构**（旧调度器移除）。新旧版本真实冲突 | 关闭 `CONFIG_TC=n`（最小系统不需要流量整形） |
| 7 | **VirtualBox 启动 panic：`Attempted to kill init! exitcode=0x7f00`** | **最关键的 bug**：`busybox --install -s` 生成的是指向**构建机绝对路径**的软链接（`/opt/lfOS/build/initramfs/bin/busybox`）。启动后该路径不存在，所有 applet 都是**断链** → 任何命令返回 127 → `exec setsid` 失败 → PID 1 退出 → panic | 改为遍历 `busybox --list` 建立指向 **`/bin/busybox`** 的绝对链接；并加门禁校验链接目标 |
| 8 | 串口看不到启动横幅与自检 | 内核把**最后一个 `console=`** 作为 `/dev/console` 映射目标；原 cmdline 是 `console=ttyS0 console=tty0`，导致用户态输出去了图形控制台 | 调整为 `console=tty0 console=ttyS0,115200`（串口放最后）；同时 `/init` 用 `tee` 双写两个控制台 |
| 9 | 脚本 `make CROSS_COMPILE=...` 报 127 | 脚本**依赖外部 `source buildenv.sh`** 提供 PATH，而 `make` 是按「名字」查找 `${CROSS_COMPILE}gcc` 的，绝对路径存在也没用 | 脚本内自带 `export PATH`，并加交叉编译器存在性自检 |

### 5.3 环境与工具类

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
| 10 | PowerShell 脚本中文乱码 + 语法错误 | PowerShell 5.1 读取 `.ps1` 默认按 ANSI，UTF-8 中文（无 BOM）会乱码 | 转存为 **UTF-8 with BOM** |
| 11 | 串口日志中文乱码 | `Get-Content` 未指定编码，按 ANSI 解析 UTF-8 字节流 | 加 `-Encoding UTF8` |
| 12 | VDI 文件"消失"导致挂载失败 | `VBoxManage unregistervm --delete` 会**连带删除磁盘文件**，而我在复制镜像后又执行了它 | 清理 VM 与复制镜像调整顺序；避免误删 |

### 5.4 ISO / UEFI 引导类（第三轮新增）

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
| 13 | `mkfs.vfat -F 16` 在 8MiB 上失败："too small or a too large filesystem" | mkfs.fat 对 FAT16 有**最小簇数约束**，8MiB 不满足 | ESP 改用 16MiB + FAT16（并保留 FAT12 回退分支）|
| 14 | UEFI 测试"通过"但实为假阳性 | `VBoxManage --firmware` 只接受 `bios`/`efi`；传 `uefi` 报 `Invalid --firmware argument` 后**静默退回 BIOS 启动** | 固件列表改用 `'efi'`；此类静默回退必须靠日志核对，不能只看开关 |
| 15 | 内核 cmdline 中出现字面 `\` | isolinux 的 `APPEND` **不支持反斜杠续行**（那是 shell 语法），多行会连 `\` 一起传入内核 | APPEND 改写为单行 |
| 16 | UEFI 下 `X64 Exception Type - 06(#UD - Invalid Opcode)` | syslinux 6.04 的 EFI 引导器与 VirtualBox 7.2 EFI 固件不兼容 | 改用**内核 EFI stub**（见 4.5）|
| 17 | `EFI stub: ERROR: Failed to decompress kernel` | 用 `objcopy --add-section .cmdline=...` 事后给 bzImage 附加段，**破坏了自解压布局**（头部记录的压缩数据偏移失效）| 改用编译期内置 `CONFIG_CMDLINE_BOOL`/`CONFIG_CMDLINE`，不再做任何后处理 |
| 18 | 内置 cmdline 里 `initrd=\...` 的反斜杠丢失 | Kconfig 解析双引号字符串时**处理转义**：写 `\i` 得到 `i` | fragment 中写 `\\i`，并在编译后用 `strings`/`xxd` 核对二进制中确有 `0x5c` |
| 19 | EFI 已能引导但 shell 起不来，横幅只打一半 | `/init` 用 `banner | tee /dev/ttyS0` 双写；**tee 向串口设备写入时提前退出/阻塞**，管道中断导致横幅后的 shell 启动代码被跳过 | 改为「先落盘、后分发」，彻底避开 tee 管道 |
| 20 | BIOS 侧内核 cmdline 出现超长重复拼接 | 未启用 `CMDLINE_OVERRIDE` 时，引导器参数是**追加**而非覆盖 | BIOS 侧不再传 APPEND，统一复用内核内置 cmdline；两条引导路径行为一致 |
| 21 | **间歇性失败**：同一 ISO 有时 shell 起不来，横幅打印两遍后卡死 | cmdline 里 `console=ttyS0` 已使 `/dev/console` 指向串口，而 `/init` 又在 `/dev/ttyS0` 上**额外起了一个后台 shell** —— 两个 shell 抢同一终端，输出交错、写入阻塞 | 改为**只起一个前台 shell**（挂在 `/dev/console`），单点输出 `out()`/`out_cmd()` |
| 22 | `lfos-boot.vdi` 文件凭空消失 | `VBoxManage unregistervm --delete` **会连带删除已挂载的磁盘文件** | 清理 VM 时不用 `--delete`，改用手动删除 VM 目录；并在验证脚本中注明该风险 |

> **关于 #21 的验证方法**：间歇性问题单次通过不能证明修复。修复后**连续跑 3 轮** BIOS+EFI（共 54 项）全绿才判定通过。

> **关于 #22 的教训**：`--delete` 对 `storageattach` 挂载过的 medium 具有破坏性。
> 若磁盘文件被共享引用，务必避免使用该开关。

---

## 6. 产物清单

### 6.1 可启动产物（`D:\lfOS\build\`）

| 文件 | 体积 | 说明 |
|------|------|------|
| `img/lfos.iso` | 38 MB | **可引导 ISO（BIOS + UEFI 双引导，混合镜像可写 U 盘）** |
| `img/lfos-iso.manifest` | — | ISO 清单与 SHA256 |
| `img/lfos-boot.vdi` | 17 MB | **VirtualBox 直接可用**（磁盘引导）|
| `img/lfos-boot.raw` | 64 MB | 原始磁盘镜像（MBR + ext4 + extlinux）|
| `img/manifest.txt` | — | 磁盘镜像清单与 SHA256 |
| `img/efi.img` | 16 MB | UEFI 系统分区镜像（FAT16，ISO 构建中间产物）|
| `img/BOOTX64.EFI` | 9.4 MB | EFI 引导用内核副本（ISO 构建中间产物）|
| `kernel/bzImage` | 9.4 MB | 加固内核（含 EFI stub + 内置 cmdline）|
| `kernel/config-report.txt` | — | 内核门禁逐项报告 |
| `initramfs-lfos.cpio.gz` | 1.2 MB | 最小根文件系统 |
| `busybox` | 2.2 MB | 静态 BusyBox |
| `logs/vbox-*.log` | — | VirtualBox 启动日志（VDI / ISO×BIOS / ISO×EFI）|

> **最终验证结果**：ISO 双引导连续 3 轮全绿（54/54），VDI 磁盘引导 8/8，
> 全流水线门禁 140 项通过 / 0 失败。

### 6.2 构建脚本（`D:\lfOS\scripts\`）

| 脚本 | 作用 | 门禁 |
|------|------|------|
| `50-build-kernel.sh` | 内核配置 + 编译 + 验证 | 63/63 |
| `60-build-initramfs.sh` | BusyBox + initramfs | 11/11 |
| `70-make-image.sh` | 磁盘镜像（raw + VDI）| 9/9 |
| `75-make-iso.sh` | **可引导 ISO（BIOS + UEFI 双引导）** | 7/7 |
| `80-vbox-test.ps1` | VDI 启动自动验证 | 8/8 |
| `81-vbox-iso-test.ps1` | **ISO 启动自动验证（BIOS + EFI 固件）** | 18/18 |

### 6.3 配置（`D:\lfOS\config\`）

| 文件 | 作用 |
|------|------|
| `kernel-lfos-vbox.fragment` | 内核配置片段（加固 + VBox 兼容 + 裁剪）|
| `sysctl-lfos.conf` | 运行时内核参数（62 条：安全收紧 + 性能调优）|

---

## 7. 如何在 VirtualBox 中使用

### 7.1 自动验证（推荐）

**ISO 双引导验证（BIOS + UEFI）**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\lfOS\scripts\81-vbox-iso-test.ps1
# 只测某一种固件：
powershell ... -Firmware bios
powershell ... -Firmware uefi     # 内部会转换为 VBox 的 'efi'
```

**磁盘镜像（VDI）验证**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\lfOS\scripts\80-vbox-test.ps1
```

两个脚本都会自动：创建 VM → 启动 → 采集串口日志 → 逐项分析 → 清理 VM。

### 7.2 使用 ISO

`D:\lfOS\build\img\lfos.iso` 是**混合镜像**，可以：

- **挂到虚拟机光驱**启动（BIOS 显示 isolinux 菜单；UEFI 直接由内核 EFI stub 接管）
- **直接写入 U 盘**启动：
  ```bash
  # Linux
  dd if=lfos.iso of=/dev/sdX bs=4M status=progress oflag=sync
  # Windows 用 Rufus（选 DD 模式）
  ```

### 7.3 手动创建 VM

```powershell
# --- 从 ISO 启动（UEFI）---
$VB = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
& $VB createvm --name lfOS --ostype Linux26_64 --register --basefolder D:\lfOS\vbox
& $VB modifyvm lfOS --memory 512 --cpus 2 --firmware efi --boot1 dvd --nic1 nat --nictype1 82540EM
& $VB modifyvm lfOS --uart1 0x3F8 4 --uartmode1 file D:\lfOS\vbox\serial0.log
& $VB storagectl lfOS --name IDE --add ide --controller PIIX4 --bootable on
& $VB storageattach lfOS --storagectl IDE --port 0 --device 0 --type dvddrive --medium D:\lfOS\build\img\lfos.iso
& $VB startvm lfOS --type gui
```

> 串口重定向是 lfOS 的关键调试通道：内核 cmdline 已把 `ttyS0` 设为主控制台，
> 无头模式下所有启动自检都能从串口文件读到。

### 7.4 手动创建 VM（原 VDI 方式）

```powershell
$VB = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
& $VB createvm --name lfOS --ostype Linux26_64 --register --basefolder D:\lfOS\vbox
& $VB modifyvm lfOS --memory 512 --cpus 2 --firmware bios --nic1 nat --nictype1 82540EM
& $VB modifyvm lfOS --uart1 0x3F8 4 --uartmode1 file D:\lfOS\vbox\serial0.log
& $VB storagectl lfOS --name SATA --add sata --controller IntelAhci --bootable on
& $VB storageattach lfOS --storagectl SATA --port 0 --device 0 --type hdd --medium D:\lfOS\build\img\lfos-boot.vdi
& $VB startvm lfOS --type gui
```

### 7.3 重新构建

```bash
# 进入 WSL 构建机
D:\lfOS\scripts\lfos.cmd

# 内核（改配置后）
bash /opt/lfOS/scripts/50-build-kernel.sh config   # 生成配置 + 门禁
bash /opt/lfOS/scripts/50-build-kernel.sh build    # 编译
bash /opt/lfOS/scripts/50-build-kernel.sh gate     # 验证

# initramfs
bash /opt/lfOS/scripts/60-build-initramfs.sh all

# 镜像（需要 root：losetup/mount）
sudo bash /opt/lfOS/scripts/70-make-image.sh all
```

---

## 8. 已知限制与后续计划

### 8.1 已知限制

| 项 | 现状 | 计划 |
|----|------|------|
| `bzImage` 体积 | 9.4 MB（目标 8 MB）| 继续裁剪驱动（见下）|
| 根文件系统 | initramfs 即在内存中运行，无持久化 | 做系统盘 rootfs + switch_root |
| SELinux | 已编译进内核，无策略 | Phase 5 加载 targeted 策略 |
| `/init` 依赖 BusyBox sh | 尚未用 Phase 2 的 bash/coreutils | Phase 2 完成后替换 |
| 网络配置 | 需手工 `ip`/`udhcpc` | 加入自动网络配置 |

### 8.2 下一步（按优先级）

**A. 体积优化（低占用）**
- 裁剪 BusyBox applet：397 → 约 120，预计二进制 2.3 MB → 0.9 MB
- 内核裁剪：关闭 USB 子系统、ISO9660/VFAT、部分 netfilter 模块，预计 9.4 MB → 7 MB

**B. 系统盘 rootfs（可用性）**
- 制作 ext4 系统盘，放 Phase 2 的 bash/coreutils/util-linux
- `/init` 挂载系统盘并 `switch_root`
- 实现持久化配置与日志

**C. 完整基础系统（Phase 2）**
- 编译 bash / coreutils / util-linux / grep / sed / gawk 等
- 保留 BusyBox 作为精简工具，真实 coreutils 供脚本兼容

**D. 安全基线（Phase 5）**
- nftables 默认 drop 策略（设计方案已给模板）
- SELinux targeted 策略
- sshd 加固配置 + 非 root 运行
- lynis 审计评分

**E. 自动化（Phase 7）**
- 一条命令完整重建
- CI 门禁：checksec / lynis / 体积阈值

---

## 9. 复现性

所有构建步骤已脚本化，关键版本锁定在 `scripts/buildenv.sh`：

| 组件 | 版本 |
|------|------|
| 内核 | 6.15.4（+ `-lfos` 后缀）|
| BusyBox | 1.37.0 |
| 交叉工具链 | GCC 14.3.0 / binutils 2.44 / glibc 2.41 |
| 拓展引导器 | extlinux 6.04 |

内核配置片段是**声明式差异**（相对 `x86_64_defconfig` 改了什么），
配合门禁脚本 63 项逐条校验，保证"改了配置不生效"这类问题不会静默通过。
