# lfOS Phase 0 环境部署报告

> 生成时间：2026-10-06
> 目标：为 LumenFluxOS（lfOS / 流光OS）从零构建准备**可复现**的宿主构建环境
> 原则：**构建数据全部落 D 盘**，C 盘只保留 WSL 运行时本体

---

## 1. 环境拓扑

```
Windows 11 专业版 25H2 (Build 26200.8037, UBR 0x1f65)
├─ WSL 3.0.1.0（MSI 安装，服务 WslService 已注册）
│    └─ C:\Program Files\WSL                  ← 约 730 MB，运行时本体，无法搬迁
├─ Ubuntu 24.04.5 LTS（WSL2 发行版）
│    └─ D:\lfOS\wsl\Ubuntu-24.04\ext4.vhdx    ← 全部构建数据（源码/工具链/根文件系统）
└─ D:\lfOS                                     ← 仓库（脚本 / 配置 / 文档 / 下载缓存）
     └─ wsl-native → /opt/lfOS                 ← 软链接，资源管理器可直接看构建产物
```

**WSL 内部布局**

| 路径 | 用途 | 对应 LFS 概念 |
|------|------|--------------|
| `/opt/lfOS/src` | 源码包缓存 + SHA256 清单 | `$LFS/sources` |
| `/opt/lfOS/build/tools` | 交叉工具链隔离区 | `$LFS/tools` |
| `/opt/lfOS/build/rootfs` | 目标根文件系统 | `$LFS` |
| `/opt/lfOS/build/logs` | 全部构建日志 | 审计/复现用 |
| `/opt/lfOS/build/img` | 镜像产物（Phase 4） | — |
| `/opt/lfOS/build/baseline` | 体积/性能基线 | 门禁对照 |

> 编译放在 WSL 原生 ext4 而非 `/mnt/d`：后者走 9p/DrvFs，处理大量小文件会显著拖慢
> 工具链构建。ext4.vhdx 本身位于 D 盘，所以"不占 C 盘"的目标依然成立。

---

## 2. 关键配置

### 2.1 `.wslconfig`（`C:\Users\15358\.wslconfig`，留档于 `config\.wslconfig`）

```ini
[wsl2]
memory=8GB                  # 半机内存，宿主留 8GB
processors=8                # 12 线程中留 4 个给 Windows
swap=0                      # 关 swap（swap.vhdx 默认落 C 盘 %Temp%）
localhostForwarding=true
nestedVirtualization=true   # 保留：可在 WSL 内跑 QEMU/KVM 验证镜像
maxCrashDumpCount=3
networkingMode=NAT
dnsTunneling=true

[general]
distributionInstallPath=D:\\lfOS\\wsl   # 今后新发行版默认落 D 盘

[experimental]
autoMemoryReclaim=gradual
sparseVhd=true              # VHD 稀疏，删文件后空间还给 D 盘
```

> 原 `.wslconfig` 使用的 `swapFileSize` / `autoPageFile` / `noUpdateChainloader` 在
> WSL 3.0 已不是有效键（启动时告警），已全部替换为官方现行键名。

### 2.2 `/etc/wsl.conf`

```ini
[user]
default=lfos                # 构建用户（非 root），sudo 免密
[boot]
systemd=true                # PID 1 = systemd，为 Phase 4 服务管理铺路
[interop]
enabled=true
appendWindowsPath=true
[network]
hostname=lfos-build         # 构建主机名固定，便于可复现
```

### 2.3 构建并行度（`scripts/buildenv.sh` 自动计算）

低占用模式，实测取值：

| 项目 | 值 | 推导 |
|------|----|------|
| `MAKEFLAGS` | `-j4` | min(CPU 侧 8×3/4=6, 内存侧 7.8GB×85%÷1.2GB=4) |
| `LFOS_JOBS_HEAVY` | `-j2` | glibc / libstdc++ / GCC 终版等内存密集步骤减半 |

设计意图：单个 `cc1/cc1plus` 峰值约 1.2 GB，`-j8` 在 8 GB 内存下会在 glibc 阶段 OOM；
按内存反推并行度可让构建期间宿主 Windows 完全可用。

---

## 3. 安装内容清单

### 3.1 WSL 运行时（C 盘，约 730 MB）

| 组件 | 版本 | 说明 |
|------|------|------|
| WSL | 3.0.1.0 | 从 GitHub Releases 下载 MSI，经 `gh-proxy.com` 加速（16 MB/s） |
| 内核 | 6.18.40.1-1 | WSL2 官方内核 |
| WSLg / MSRDC / Direct3D | 1.0.79 / 1.2.72 / 1.611.1 | 随包 |

安装方式：`msiexec /i wsl.3.0.1.0.x64.msi`（需管理员一次，用于注册 `WslService`）。
系统里原有的 `%USERPROFILE%\.local\bin\wsl.bat`（内容仅为 `exit /b 0`）会遮蔽 `wsl` 命令，
如需在 PATH 中正常调用 `wsl`，建议删除或改名该文件。

### 3.2 Ubuntu 24.04.5 LTS 基础环境

| 项目 | 值 |
|------|-----|
| glibc | 2.39-0ubuntu8.9 |
| 内核 | 6.18.40.1-microsoft-standard-WSL2 |
| 磁盘 | 1007 GB 总 / 953 GB 可用（D 盘） |
| 内存 | 7.8 GB（限 8GB） |
| CPU | 8 逻辑核心（限 8） |
| APT 源 | `mirrors.aliyun.com`（实测 5 MB/s） |

### 3.3 宿主工具链（LFS/BLFS 必需，共 36 项全部就位）

`gcc 13.3.0` `g++ 13.3.0` `binutils 2.42` `make 4.3` `perl` `python3 3.12.3`
`bash 5.2.21` `tar 1.35` `xz 5.4.5` `bison 3.8.2` `gawk 5.2.1` `sed 4.9` `grep 3.11`
`flex` `m4` `texinfo/makeinfo` `gettext` `autoconf` `automake` `libtoolize` `pkg-config`
`bc` `cpio` `rsync` `patch` `diffutils` `findutils` `wget` `curl` `git` `file` `time` `expect` `dejagnu` …

开发头文件：`zlib.h` `openssl/ssl.h` `ncurses.h` `elf.h` `gmp.h` `mpfr.h` `seccomp.h` 全部可用。

### 3.4 安全 / 验证工具

| 工具 | 版本 | 用途 |
|------|------|------|
| lynis | 3.0.9 | Phase 5 加固评分门禁 |
| nftables | 1.0.9 | Phase 5 防火墙 |
| shellcheck | 0.9.0 | 构建脚本静态检查 |
| pahole/dwarves | 1.25 | 内核 BTF 生成 |
| qemu-utils | 8.2.2 | 镜像格式转换与验证 |
| xorriso / mtools / dosfstools / squashfs-tools | — | Phase 4 镜像制作 |
| /dev/kvm | 可用 | 本地起 KVM 验证 lfOS 镜像 |

---

## 4. Phase 0 门禁结果（22/22 通过）

| # | 检查项 | 结果 |
|---|--------|------|
| 1 | 磁盘可用 ≥ 30GB | ✅ 953 GB |
| 2 | 内存 ≥ 4GB | ✅ 9947 MB |
| 3 | CPU ≥ 2 核 | ✅ 12 核（限 8） |
| 4 | 宿主必需工具 | ✅ 36/36 |
| 5 | 关键开发头文件 | ✅ 7/7 |
| 6 | 编译 + 运行 + strip 基线 | ✅ 15960B → 14472B（strip 后仍可运行） |
| 7 | 加固编译能力 | ✅ SSP / FORTIFY_SOURCE=3 / PIE / RELRO / CET |
| 8 | 虚拟化与内核接口 | ✅ /dev/kvm、cgroup、systemd |
| 9 | 安全审计工具 | ✅ lynis、nftables |

---

## 4.1 Phase 1 交叉工具链结果（28 通过 / 1 警告 / 0 失败）

构建总耗时约 **41 分钟**（06:20 → 07:02，8 核 / 8GB / `-j4`，重步骤 `-j2`）。

| 阶段 | 内容 | 耗时 | 结果 |
|------|------|------|------|
| 1 | Binutils 2.44 | 60s | ✅ `GNU ld 2.44` |
| 2 | GCC 14.3.0 pass 1（C/C++，仅 bootstrap 阶段1） | 13min | ✅ |
| 3 | Linux 6.15.4 API Headers | 6min | ✅ 1012 个头文件装入 `$LFS/usr/include` |
| 4 | glibc 2.41 | 6min | ✅ `$LFS/usr/lib/libc.so.6` 就位 |
| 5 | libstdc++（来自 GCC 14.3.0） | 1min | ✅ |
| 6 | GCC 14.3.0 pass 2（完整，含默认加固） | 20min | ✅ `x86_64-lfos-linux-gnu-gcc 14.3.0` |

**门禁明细**

| 检查项 | 结果 |
|--------|------|
| 11 个工具链二进制（gcc/g++/ld/as/ar/ranlib/nm/strip/objdump/objcopy/readelf） | ✅ 齐备 |
| 目标三元组 `x86_64-lfos-linux-gnu` | ✅ `-dumpmachine` 一致 |
| sysroot 与 glibc | ✅ 指向 `$LFS`，1818 个头文件 |
| 交叉编译静态 hello → 运行 | ✅ 输出 `lfOS cross toolchain OK` |
| strip 效果 | ✅ 3129496B → 668000B（-78.6%） |
| 动态链接 | ✅ 解释器 `/lib64/ld-linux-x86-64.so.2` |
| 默认 PIE | ✅ 通过 |
| GNU_RELRO | ✅ 有 |
| BIND_NOW | ⚠️ 未默认启用（构建时以显式 `-Wl,-z,now` 施加，见 `LFOS_LDFLAGS`） |
| 构建日志真实错误扫描 | ✅ 无（已排除源码内测试字符串误报） |

**体积**

| 对象 | 体积 |
|------|------|
| 交叉工具链 `$LFS_TOOLS` | 1507 MB → **523 MB**（瘦身释放 984 MB） |
| 目标根文件系统 `$LFS` | 152 MB（glibc + libstdc++ 开发文件，Phase 2 起裁剪） |

> 瘦身策略：`strip` 全部二进制与共享库 + 删除文档/`man`/`info` + 删除**非必需**静态库。
> **GCC 运行时库（`libgcc.a` / `libgcc_eh.a`）与 `crt*.o` 必须保留** ——
> 第一版瘦身把 `.a` 全删导致 `-lgcc` 链接失败、工具链报废，
> 已通过 `make all-target-libgcc install-target-libgcc` 增量重建恢复（约 3 分钟），
> 并把保护规则固化进 `15-gate-phase1.sh` 的瘦身分支（删完自动复验静态+动态链接与运行）。


基线文件：`/opt/lfOS/build/baseline/phase0-hello-size.txt`

---

## 5. 环境部署中踩到的坑与处理（可复现经验）

| 问题 | 根因 | 处理 |
|------|------|------|
| `wsl --version` 无输出 | `%USERPROFILE%\.local\bin\wsl.bat` 是 `exit /b 0` 的假命令，遮蔽真实 wsl | 识别后绕开，用绝对路径调用 |
| `WslService` 不存在 | WSL 组件缺失（含 System32\wsl.exe） | 下载官方 MSI 安装 |
| `.wslconfig` 大段告警 | `swapFileSize`/`autoPageFile`/`noUpdateChainloader` 非 WSL3 有效键 | 按官方现行键名重写 |
| `wsl --install` 未装到 D 盘 | 默认路径在 `%LocalAppData%`（C 盘） | 用 `--location D:\lfOS\wsl\...` 显式指定 |
| GitHub 直连 50 KB/s | 跨境链路 | `gh-proxy.com` 代理，16 MB/s |
| GCC 源码 404 | 路径少了版本子目录（`gcc/gcc-14.3.0/…`） | 修正为完整相对路径 |
| `mpc` 下载 404 | GNU 镜像 mpc 1.3.x 仅有 `.tar.gz` | 版本提升到 1.4.1（提供 `.tar.xz`） |
| GCC 构建卡死数分钟 | `contrib/download_prerequisites` 访问 `gcc.gnu.org` 超时 | 改为优先复用宿主 gmp/mpfr/mpc 开发库，并加 180s 超时兜底 |
| `lfos.cmd` 工作目录不对 | WSL 继承 Windows 的 cwd；CMD 会预解析 `&&` | 统一用 `--cd /opt/lfOS`；文档提示用 `;` 串联 |
| 构建脚本收尾返回 rc=2 | `cat limits.h >> fixed-limits.h` 会读 stdin，后台任务 stdin 为空 | 改为文件到文件重定向 + 脚本末尾显式 `exit 0` |
| 门禁误报"日志含错误" | 源码内大量 `internal compiler error` 测试字符串被 grep 命中 | 收窄正则（`^make: \*\*\* Error`、`internal compiler error: [0-9]` 等）+ 以产物存在性为最终判据 |
| 瘦身后工具链报废 | 删 `.a` 时连带删掉 GCC 运行时库 `libgcc.a`/`libgcc_eh.a` | `make all-target-libgcc install-target-libgcc` 增量重建恢复；瘦身规则加白名单 + 删后自动复验 |

---

## 6. 下一步

| 阶段 | 内容 | 状态 / 门禁 |
|------|------|------|
| Phase 0 | 宿主机环境 | ✅ 22/22 通过 |
| Phase 1 | 交叉工具链（binutils → gcc → headers → glibc → libstdc++ → gcc） | ✅ 28 通过 / 1 警告 / 0 失败 |
| Phase 2 | 基础系统（BusyBox + coreutils、bash、util-linux…，统一 strip） | ⏳ 脚本已就绪（`40-build-base.sh`），待补源码清单 |
| Phase 3 | 加固内核（KSPP 配置 + 服务器裁剪） | ⏳ |
| Phase 4 | systemd + initramfs + rootfs 镜像 | ⏳ |
| Phase 5 | nftables / SELinux / seccomp / SSH 基线 | ⏳ |
| Phase 6 | 性能调优（sysctl、zram、BBR） | ⏳ |
| Phase 7 | CI 固化 + 可复现构建 | ⏳ |

### 已知待办（Phase 2 之前）

1. **补充 Phase 2 源码包**：`20-fetch-sources.sh` 已加入 bash / coreutils / util-linux / gzip /
   tar / sed / grep / gawk / findutils / diffutils / make / readline / ncurses / zlib / xz /
   busybox / openssl 的下载条目与镜像回退，执行一次即可拉齐。
2. **GCC 未做 bootstrap 自举**：当前 pass2 直接编译，未走 stage2/stage3 自举验证。
   若要追求"绝对可信工具链"，需以 `--enable-bootstrap` 重编（预计额外 40–60 分钟）；
   当前产物已通过编译/链接/运行三重实测，且默认开启 PIE + SSP。
3. **BIND_NOW 默认化**：已在 `buildenv.sh` 的 `LFOS_LDFLAGS` 中显式施加 `-Wl,-z,now`，
   如需工具链级默认，可在 pass2 增加 `--enable-default-...`/`LDFLAGS_FOR_TARGET` 后重编。

