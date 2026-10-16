# lfOS · 流光OS 构建工作区

> **LumenFluxOS（lfOS / 流光OS）** —— 从零构建的高性能 / 高安全 / 低占用 Linux 服务器系统。
> 本目录是 Phase 0（构建环境）落地成果，设计方案见桌面 `LumenFluxOS-设计方案.md`。

---

## 1. 这套环境是什么

在 Windows 11 上用 **WSL2 + Ubuntu 24.04** 搭出的标准 LFS/BLFS 宿主构建机，
所有构建数据落在 **D 盘**，C 盘只保留 WSL 运行时本体。

```
Windows 11 25H2 (Build 26200)
├─ WSL 3.0.1 运行时          C:\Program Files\WSL            ~730 MB（C 盘，无法搬迁）
└─ Ubuntu 24.04.5 LTS        D:\lfOS\wsl\Ubuntu-24.04\ext4.vhdx   ← 全部构建数据在这
   └─ /opt/lfOS              WSL 原生 ext4 构建区（避免 /mnt/d 的 9p 性能损失）
      ├─ src/                源码包缓存 + SHA256 清单
      ├─ build/tools/        Phase 1 交叉工具链隔离区（对应 LFS 的 $LFS/tools）
      ├─ build/rootfs/       Phase 2 目标根文件系统（对应 $LFS）
      ├─ build/logs/         构建日志（可复现审计）
      ├─ build/img/          Phase 4 镜像产物（qcow2 / raw）
      └─ build/baseline/     Phase 0 体积基线
```

Windows 侧 `D:\lfOS\wsl-native` 是指向 `/opt/lfOS` 的软链接，资源管理器里可直接查看构建产物。

## 2. 交付物一览

### 2.1 构建脚本（`scripts/`）

| 文件 | 作用 |
|------|------|
| `00-base-setup.sh` | 宿主依赖安装（LFS/BLFS 全套工具链 + 安全审计工具） |
| `05-wsl-tune.sh` | WSL 调优（关 swap、固定 locale、建立原生构建区） |
| `buildenv.sh` | 环境变量基线：版本锁定、并行度、加固编译标志 |
| `10-gate-phase0.sh` | **Phase 0 门禁**：磁盘/内存/工具链/加固能力 22 项 |
| `20-fetch-sources.sh` | 源码获取（多镜像回退 + SHA256 清单） |
| `30-build-toolchain.sh` | **Phase 1** 交叉工具链（LFS 标准 6 步） |
| `15-gate-phase1.sh` | Phase 1 门禁 + 工具链瘦身（含 libgcc 保护白名单） |
| `40-build-base.sh` | Phase 2 基础系统骨架（待启用） |
| `50-build-kernel.sh` | **Phase 3** 内核配置/编译/门禁（63 项检查） |
| `60-build-initramfs.sh` | **Phase 4** BusyBox 静态编译 + initramfs（11 项门禁） |
| `70-make-image.sh` | **Phase 4** 可引导磁盘镜像 raw + VDI（9 项门禁） |
| `75-make-iso.sh` | **Phase 4** 可引导 ISO，BIOS + UEFI 双引导（7 项门禁） |
| `80-vbox-test.ps1` | VDI 启动自动验证（8 项） |
| `81-vbox-iso-test.ps1` | **ISO 启动自动验证（BIOS + EFI 固件，18 项）** |
| `run-bg.sh` | 后台构建启动器（setsid 脱离，关掉终端也不中断） |
| `status.sh` | 一行命令看清构建进度 / 资源占用 / 产物体积 |
| `watch-build.ps1` | Windows 侧构建监视器 |
| `lfos.cmd` | Windows 侧一键进入构建机 |

### 2.2 配置（`config/`）

| 文件 | 作用 |
|------|------|
| `kernel-lfos-vbox.fragment` | 内核配置片段（KSPP 加固 + VBox 兼容 + 裁剪 + 内置 cmdline）|
| `sysctl-lfos.conf` | 运行时内核参数（62 条：安全收紧 + 性能调优）|
| `.wslconfig` | WSL 全局配置留档（实际生效位置 `%UserProfile%\.wslconfig`） |

### 2.3 文档（`docs/`）

| 文件 | 作用 |
|------|------|
| `PHASE0-环境部署报告.md` | 环境部署完整记录（含踩坑与处理） |
| `PHASE3-4-可启动系统报告.md` | **内核/initramfs/镜像/ISO 构建报告 + 三宗旨实测 + 20 个踩坑记录** |

## 3. 怎么用

### 进入构建机

在 Windows 终端（PowerShell / CMD）里：

```powershell
D:\lfOS\scripts\lfos.cmd                 # 进入交互式 shell
D:\lfOS\scripts\lfos.cmd "uname -a"      # 执行单条命令
```

### 加载构建环境

```bash
source /opt/lfOS/scripts/buildenv.sh     # 加载版本锁定 + MAKEFLAGS + 加固 CFLAGS
lfos_banner                              # 打印环境摘要
```

### 跑门禁

```bash
bash /opt/lfOS/scripts/10-gate-phase0.sh
```

### 取源码（Phase 1 准备）

```bash
bash /opt/lfOS/scripts/20-fetch-sources.sh
```

### 启动 / 监控构建

```bash
# 后台启动（关掉终端也继续跑）
bash /opt/lfOS/scripts/run-bg.sh /opt/lfOS/scripts/30-build-toolchain.sh all

# 随时看进度（推荐）
bash /opt/lfOS/scripts/status.sh

# 实时跟踪日志
tail -f /opt/lfOS/build/logs/30-build-toolchain.out
```

Windows 侧：

```powershell
powershell -NoProfile -File D:\lfOS\scripts\watch-build.ps1 -TimeoutMinutes 150
```

## 4. 版本锁定（`buildenv.sh`）

| 组件 | 版本 | 说明 |
|------|------|------|
| 宿主 gcc | 13.3.0 | Ubuntu 24.04 自带 |
| 宿主 glibc / binutils | 2.39 / 2.42 | 宿主基线 |
| 目标三元组 | `x86_64-lfos-linux-gnu` | lfOS 自有 ABI 命名空间 |
| binutils | 2.44 | Phase 1 |
| gcc | 14.3.0 | Phase 1 |
| glibc | 2.41 | 决策：服务器生态选 **glibc**（非 musl） |
| linux | 6.15.4 | Phase 3（加固内核） |

> 版本集中定义在 `buildenv.sh` 与 `20-fetch-sources.sh`，改一处即可整体切换，
> 这是"bit-for-bit 可复现"的前提（NixOS 理念的最小可用实现）。

## 5. 环境规格（实测）

**低占用模式**：构建时宿主 Windows 仍可正常使用，不抢满 CPU、不打满内存。

| 项目 | 实测值 | 门禁要求 |
|------|--------|---------|
| 构建盘可用 | 953 GB | ≥ 30 GB ✅ |
| 内存 | 7.8 GB（.wslconfig 限 8GB，宿主留 8GB） | ≥ 4 GB ✅ |
| CPU | 8 逻辑核心（12 线程中限 8，留 4 给宿主） | ≥ 2 ✅ |
| 构建并行度 | `-j4`，内存密集步骤 `-j2`（按内存自动反推） | — |
| 宿主必需工具 | 36/36 齐备 | 全部 ✅ |
| 加固编译能力 | SSP/FORTIFY/PIE/RELRO/CET 全支持 | ✅ |
| /dev/kvm | 可用（可本地跑镜像验证） | ✅ |
| systemd | PID 1 = systemd | ✅ |
| 审计工具 | lynis 3.0.9 / nftables 1.0.9 | ✅ |

## 6. 构建路线图

| 阶段 | 内容 | 状态 |
|------|------|------|
| Phase 0 | 宿主环境 + 门禁 | ✅ 22/22 通过 |
| Phase 1 | 交叉工具链（binutils→gcc→headers→glibc→libstdc++→gcc） | ✅ 28 通过 / 0 失败 |
| Phase 3 | 加固内核（KSPP + VirtualBox 兼容 + 服务器裁剪） | ✅ 63/63 通过，bzImage 9.4MB |
| Phase 4 | BusyBox + initramfs + 可引导磁盘镜像 | ✅ 11/11 + 9/9 通过 |
| **Phase 4.5** | **VirtualBox 实测启动（磁盘）** | ✅ **8/8 通过** |
| **Phase 4.6** | **可引导 ISO：BIOS + UEFI 双引导** | ✅ **7/7 + 18/18 通过** |
| Phase 2 | 基础系统（bash/coreutils/util-linux 持久化 rootfs） | ⏳ 下一步 |
| Phase 5 | 安全基线（nftables / SELinux 策略 / SSH 加固） | ⏳ |
| Phase 6 | 性能调优深化（zram / NUMA / 大页细化） | ⏳ 部分已完成 |
| Phase 7 | CI 固化 + 可复现构建 | ⏳ |

### ⭐ 当前成果：完整系统 ISO（BIOS + UEFI 双引导）

**连续 3 轮、每轮 BIOS + UEFI 各 15 项，共 90 次检查全部通过**（VirtualBox 7.2.20）：

| 载体 | 固件 | 引导方式 | 结果 |
|------|------|---------|------|
| ISO 光盘 | BIOS | isolinux | ✅ 15/15 ×3 轮 |
| ISO 光盘 | **UEFI** | **内核 EFI stub（零引导器）** | ✅ 15/15 ×3 轮 |

```
lfOS (LumenFluxOS / 流光OS)  ·  内核 6.15.4-lfos  ·  启动约 8 秒

[低占用]  内存 68 MB / 476 MB  ·  进程 62  ·  内核模块 0  ·  根文件系统 43 MB
[高性能]  TCP bbr  ·  qdisc fq  ·  THP always  ·  squashfs 多核解压
[高安全]  KASLR ✓  KPTI ✓  STRICT_KERNEL_RWX ✓  dmesg/kptr/perf 限制 ✓
          只读根不可篡改 ✓  SSH 禁 root/禁密码 ✓  主机密钥每机唯一 ✓
```

**启动流程**（不可变根架构）：

```
UEFI/isolinux → 内核（EFI stub）→ initramfs
   → 挂载 ISO9660 → losetup 关联 rootfs.squashfs → squashfs 只读根
   → tmpfs 可写层 → overlayfs 合并 → switch_root
   → lfOS /sbin/init（9 阶段）→ 网络 / 防火墙 / sshd → 交互 shell
```

**一键验证**：

```powershell
# ISO 双引导完整验证（BIOS + UEFI，各 15 项）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\lfOS\scripts\81-vbox-iso-test.ps1 -Firmware both

# 创建可持久使用的虚拟机（文件放 D:\lfOS\vbox，不占 C 盘）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\lfOS\scripts\84-create-vm.ps1

# 验证虚拟机（无头启动 + 串口日志分析）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\lfOS\scripts\85-test-vm.ps1
```

### 🖥️ 虚拟机（开箱即用 · 持久化）

已提供一个**装好的 lfOS 虚拟机**，改动会保存到虚拟硬盘：

| 项目 | 值 |
|------|-----|
| 名称 / 位置 | `lfOS` @ `D:\lfOS\vbox\lfOS`（**不占 C 盘**）|
| 规格 | 2 GB 内存 / 2 核 / SATA / NAT 网络 |
| 系统盘 | 2 GiB 动态分配（实占 182 MB）|
| 根文件系统 | **ext4 可写持久**（非 Live）|
| 实测 | 连续 2 次启动各 **12/12 通过** |

```
[lfOS] /dev/sda1 是 ext4 系统盘 → 可写持久根
[lfOS] 使用可写系统盘（改动将被保留）
  crng init done  0.41s    网络 10.0.2.15/24 (DHCP)
  内存 102 MB / 1985 MB    sshd 已启动（监听 22）
```

启动方式：打开 VirtualBox 管理器双击 `lfOS`，或
`VBoxManage startvm lfOS --type gui`。

**产物**（`D:\lfOS\build\`）：

| 文件 | 体积 | 说明 |
|------|------|------|
| `img/lfos.iso` | **172 MB** | **完整系统 ISO，BIOS + UEFI 双引导**，可 `dd` 到 U 盘 |
| `img/rootfs.squashfs` | 43 MB | 只读压缩根（含 bash/coreutils/util-linux/openssl/openssh）|
| `img/rootfs.ext4` | 149 MB | 可写 ext4 根（供磁盘安装）|
| `kernel/bzImage` | 9.5 MB | 加固内核（含 EFI stub + 内置 cmdline）|
| `boot-initramfs.cpio.gz` | 1.2 MB | 引导 initramfs（squashfs + overlay + switch_root）|

> **UEFI 引导采用内核 EFI stub（零引导器）**：内核自带 EFI 引导能力，
> `bzImage` 即 EFI 可执行文件，无需 syslinux.efi / GRUB。
> 好处是消除引导器这一独立攻击面、零体积开销，并为 Secure Boot 铺路。
>
> **只读根 + overlay 可写层**：对应设计方案 §1.4 的不可变服务器思路
> （Flatcar / Bottlerocket 同源）。squashfs 不可篡改，改动落在 tmpfs，
> 重启即还原 —— 天然免疫配置漂移；若检测到 `lfos-persist` 分区则自动持久化。

**基础系统包**（Phase 2，28 个）：bash 5.2.37 · coreutils 9.6 · util-linux 2.41 ·
grep/sed/gawk · tar/gzip/xz · findutils/diffutils · make · zlib/ncurses/readline ·
openssl 3.5.0 · openssh 10.0p1 · e2fsprogs 1.47.2 · iproute2 6.13.0 · procps/psmisc · wget

详见 [docs/PHASE2-5-完整系统报告.md](docs/PHASE2-5-完整系统报告.md)

详见 [docs/PHASE3-4-可启动系统报告.md](docs/PHASE3-4-可启动系统报告.md)

### Phase 1 实测结果

| 阶段 | 内容 | 耗时 | 结果 |
|------|------|------|------|
| 1 | Binutils 2.44 | 60s | ✅ |
| 2 | GCC 14.3.0 pass 1 | 13min | ✅ |
| 3 | Linux 6.15.4 API Headers | 6min | ✅ 1012 个头文件 |
| 4 | glibc 2.41 | 6min | ✅ |
| 5 | libstdc++ | 1min | ✅ |
| 6 | GCC 14.3.0 pass 2 | 20min | ✅ |

- 交叉编译实测：静态 hello 运行输出 `lfOS cross toolchain OK`（3129496B → strip 后 668000B）
- 默认加固：**PIE ✅ / GNU_RELRO ✅**；BIND_NOW 由 `LFOS_LDFLAGS` 显式施加
- 体积：工具链 1507MB → **523MB**（瘦身释放 984MB）；目标根 152MB
- 完整记录见 [docs/PHASE0-环境部署报告.md](docs/PHASE0-环境部署报告.md)

### 日常操作速查

```powershell
D:\lfOS\scripts\lfos.cmd                        # 进入构建机
D:\lfOS\scripts\lfos.cmd "bash /opt/lfOS/scripts/status.sh"   # 看状态
```

```bash
# 进构建机后
source /opt/lfOS/scripts/buildenv.sh            # 加载环境
bash /opt/lfOS/scripts/15-gate-phase1.sh        # 跑 Phase 1 门禁
bash /opt/lfOS/scripts/20-fetch-sources.sh      # 拉取后续阶段源码
bash /opt/lfOS/scripts/run-bg.sh /opt/lfOS/scripts/40-build-base.sh all   # Phase 2
```
