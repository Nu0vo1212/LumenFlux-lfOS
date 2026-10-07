# lfOS 完整系统报告（Phase 2 / 4 / 5）

> **LumenFluxOS (流光OS)** —— 从零构建的高性能 / 高安全 / 低占用 Linux 服务器发行版
>
> 本轮目标：在已可启动的最小系统（Phase 3-4）基础上，补齐**完整基础系统**、
> **持久化根文件系统**与**安全基线**，产出可直接使用的 ISO。

---

## 1. 本轮成果总览

从「只有 BusyBox 的最小 shell」推进到「完整可用的服务器系统」：

| 维度 | 之前 | 现在 |
|------|------|------|
| 用户态工具 | BusyBox applet | bash / coreutils / util-linux / grep / sed / gawk / tar / xz …（完整实现）|
| 加密与远程 | 无 | OpenSSL 3.5 + OpenSSH 10.0（sshd 可用）|
| 文件系统工具 | 无 | e2fsprogs（mke2fs / e2fsck）|
| 网络工具 | BusyBox ip | iproute2 + procps + psmisc |
| 根文件系统 | initramfs（内存，重启即失）| **squashfs 只读根 + overlayfs 可写层** |
| 初始化系统 | `/init` 直接给 shell | **lfOS `/sbin/init`**（9 阶段、服务管理）|
| 安全 | 内核加固 | 内核加固 + sysctl + SSH 加固 + 防火墙 + 一键加固脚本 |
| ISO 体积 | 38 MB（仅 BusyBox）| 172 MB（完整系统，含 43 MB 压缩根）|

**验证结果：BIOS 15/15 + UEFI 15/15 = 30/30 全部通过**（VirtualBox 7.2.20）。

---

## 2. Phase 2：基础系统构建

### 2.1 构建策略：交叉编译 + DESTDIR，而非 chroot

**为什么不用 chroot**：Phase 2 早期 `$LFS` 里还没有 shell，无法 chroot。
交叉编译本来也不需要 —— 用 `--host` 指定目标架构 + `DESTDIR` 安装即可。

```bash
./configure --prefix=/usr \
    --host=x86_64-lfos-linux-gnu \
    --build=$(gcc -dumpmachine) \
    --disable-static --with-sysroot=$LFS
make -j4 && make DESTDIR=$LFS install
```

### 2.2 已构建的包（按依赖顺序）

| 层次 | 包 | 说明 |
|------|-----|------|
| 基础库 | zlib 1.3.1 | 压缩库，众多包依赖 |
| | ncurses 6.5 | 终端库（`--with-termlib` 生成 libtinfo）|
| | readline 8.2 | bash 的行编辑 |
| Shell | bash 5.2.37 | `/bin/sh → bash` |
| 核心工具 | coreutils 9.6 | 完整 POSIX 语义（替代 BusyBox 版）|
| | util-linux 2.41 | mount / umount / lsblk / agetty |
| 文本处理 | grep 3.11 / sed 4.9 / gawk 5.3.1 | |
| 归档压缩 | tar 1.35 / gzip 1.14 / xz 5.8.1 | |
| | findutils 4.10.0 / diffutils 3.11 | |
| 构建 | make 4.4.1 / which 2.21 | |
| 文件系统 | e2fsprogs 1.47.2 | mke2fs / e2fsck（持久化根必需）|
| 进程 | procps-ng 4.0.5 / psmisc 23.7 | ps / top / free / killall |
| 加密 | openssl 3.5.0 | TLS 库 |
| 网络 | iproute2 6.13.0 | ip / ss / tc |
| 远程 | openssh 10.0p1 | ssh / sshd / sftp / scp |
| 用户 | （shadow 未构建，改用静态 passwd/group）| 见 2.4 |
| 下载 | wget 1.25.0 | |

### 2.3 交叉编译的三个关键配置

**(a) fakeroot 承载 chown / setuid**

util-linux 等包的 install hook 会执行 `chown root:root` 与 `chmod u+s`，
普通用户执行必然失败（`Operation not permitted`），使 `make install` 报错退出
（即使文件已复制到位）。解法是标准打包手法 fakeroot：

```bash
make_install() {
  if [ -n "$FAKEROOT_BIN" ]; then
    "$FAKEROOT_BIN" -- make DESTDIR="$LFS" install "$@"
  else
    make DESTDIR="$LFS" install "$@"
  fi
}
```

**(b) ncurses 必须加 `--with-termlib`**

只加 `--enable-widec` 时 terminfo 被打包进 `libncursesw`，不产生独立
`libtinfo`。而 util-linux 的 `ul`/`colcrt`/`rev` 会链接 `-ltinfo`：

```
ld: cannot find -ltinfo: No such file or directory
```

**(c) openssl 不要用 `--cross-compile-prefix`**

openssl 的 target 定义里 `CC` 已含完整三元组：

```
CC=$(CROSS_COMPILE)x86_64-lfos-linux-gnu-gcc
```

再传 `--cross-compile-prefix=x86_64-lfos-linux-gnu-` 就变成重复前缀：

```
x86_64-lfos-linux-gnu-x86_64-lfos-linux-gnu-gcc   ← 不存在
→ make 报 Error 127（command not found）
```

正确做法：只用环境变量给出完整工具名，openssl 原样采用、不做拼接。

### 2.4 系统基础文件（易漏但必需）

这些文件缺失时，故障现象往往完全指不到根因：

| 文件 | 缺失后果 |
|------|---------|
| `/etc/passwd` | sshd 报「Privilege separation user sshd does not exist」|
| `/etc/nsswitch.conf` | glibc `getpwnam()` 行为不确定，程序以「找不到用户」失败 |
| `/etc/services` | 服务按名字解析端口时失败 |
| `/etc/fstab` | 挂载语义缺失 |
| `/usr/sbin/nologin` | 服务账户无法正确禁止登录 |

---

## 3. Phase 4：持久化根文件系统

### 3.1 架构：squashfs 只读根 + overlayfs 可写层

对应设计方案 §1.4 的「不可变服务器」思路（Flatcar / Bottlerocket 同源）：

```
        ┌─────────────────────────────────────────┐
        │  合并视图（/）  ← 进程看到的样子          │
        └───────────────┬─────────────────────────┘
                        │ overlayfs
        ┌───────────────┴───────────┬─────────────┐
        │ 下层 lowerdir（只读）      │ 上层 upperdir │
        │ squashfs 压缩镜像 43 MB    │ tmpfs 或磁盘  │
        │ 不可篡改、高压缩比         │ 运行时可写     │
        └───────────────────────────┴─────────────┘
```

**两种模式**：

| 模式 | 触发条件 | 可写层位置 | 特性 |
|------|---------|-----------|------|
| Live | ISO 启动（无持久分区）| tmpfs（内存）| 重启即还原，防配置漂移 |
| 持久 | 存在 `lfos-persist` 分区 | 磁盘 ext4 | 改动保留 |

### 3.2 完整启动流程

```
UEFI 固件 / isolinux
      │  加载内核（内核内含 EFI stub，UEFI 下零引导器）
      ▼
内核解压 initramfs（1.2 MB）→ 执行 /init
      │
      ├─ 挂载 proc/sys/devtmpfs
      ├─ 扫描块设备
      │    ├─ /dev/sr0 → mount -t iso9660
      │    ├─ 找到 /rootfs.squashfs
      │    ├─ losetup /dev/loop0 rootfs.squashfs
      │    └─ mount -t squashfs /dev/loop0 /mnt/ro
      ├─ mount -t tmpfs tmpfs /mnt/rw          ← 可写层必须在 tmpfs 上
      ├─ mount -t overlay → /newroot
      ├─ 迁移 /dev /proc /sys /run
      ├─ 切换前体检（init 可执行 / 设备节点 / chroot 试运行）
      └─ exec switch_root /newroot /sbin/init
      │
      ▼
lfOS /sbin/init（PID 1，9 阶段）
      1. 挂载伪文件系统      6. 启动 sshd（后台）
      2. 设置主机名          7. 执行 /etc/rc.local
      3. 应用内核参数        8. 系统自检横幅
      4. 配置网络（DHCP）    9. 交互 shell（PID1 常驻）
      5. 加载防火墙
```

### 3.3 lfOS init 设计

**为什么不用 systemd**：首版目标是「能跑起来 + 低占用」，systemd 会带入
数十 MB 依赖；一个可审计的 shell init 更契合「从零构建」与「攻击面最小」。

**PID 1 铁律**：init 退出 = 内核 panic（`Attempted to kill init!`）。因此：

```bash
while : ; do
  PS1=$'lfos:\\w# ' /bin/bash -i < /dev/console > /dev/console 2>&1
  say "[lfOS] shell 已退出（rc=$?），2 秒后重开"
  sleep 2
done
```

---

## 4. Phase 5：安全基线

### 4.1 内核运行时参数（62 条，`/etc/sysctl.d/99-lfos.conf`）

| 类别 | 关键项 |
|------|--------|
| 信息隐藏 | `kptr_restrict=1`、`dmesg_restrict=1`、`perf_event_paranoid=3` |
| 攻击面收敛 | `unprivileged_bpf_disabled=1`、`unprivileged_userns_clone=0`、`sysrq=16` |
| 网络反欺骗 | `rp_filter=1`、`accept_source_route=0`、`accept_redirects=0`、`log_martians=1` |
| DoS 缓解 | `tcp_syncookies=1`、`icmp_echo_ignore_broadcasts=1` |
| 性能 | `tcp_congestion_control=bbr`、`default_qdisc=fq` |

### 4.2 SSH 加固（`/etc/ssh/sshd_config`）

- **禁 root 直登**（`PermitRootLogin no`）—— 消除最常见的暴力破解目标
- **纯密钥认证**（`PasswordAuthentication no`）—— 从根上免疫字典攻击
- **认证限制**：`MaxAuthTries 3`、`LoginGraceTime 30`、`MaxSessions 4`
- **关闭非必要功能**：X11Forwarding / AgentForwarding / TcpForwarding / Tunnel
- **现代加密套件**：Curve25519 密钥交换、ChaCha20-Poly1305 / AES-GCM、SHA-2 ETM
- 主机密钥**首次启动现场生成**（ED25519）

### 4.3 防火墙（`/etc/nftables.conf`）

白名单模型：默认 `drop`，仅放行 22（带 20/minute 速率限制）。
状态跟踪放行已建立连接；无效包计数丢弃；`forward` 链关闭（不做路由器）。

> 注：nftables 用户态工具需 libmnl/libnftnl 依赖，本版尚未构建；
> 内核侧 `CONFIG_NF_TABLES=y` 已就绪，规则文件已安装，装上 nft 即生效。

### 4.4 一键加固脚本（`/usr/local/sbin/harden.sh`）

幂等设计，支持 `--check`（只检查）与 `--apply`（默认应用）两种模式，
覆盖内核参数、文件权限、SSH、模块黑名单、审计日志。

---

## 5. 实测数据（三宗旨验证）

### 5.1 低占用

| 指标 | 实测值 |
|------|--------|
| 内存占用 | **68 MB / 476 MB** |
| 进程数 | 62 |
| 加载的内核模块 | **0**（单体内核，无模块支持）|
| 根文件系统 | squashfs 43 MB（含 bash/coreutils/openssl/openssh…）|
| initramfs | 1.2 MB |
| ISO 总体积 | 172 MB |

> 内存占用从最小系统的 25 MB 增至 68 MB，增量来自 bash、glibc 完整工具链、
> OpenSSL 与 sshd。相对 Debian 最小安装（约 400 MB 内存）仍是数量级优势。

### 5.2 高性能

| 指标 | 实测值 |
|------|--------|
| 启动到 shell | **约 8 秒**（含 squashfs 解压与 overlay 挂载）|
| TCP 拥塞控制 | **bbr** |
| 默认 qdisc | **fq** |
| 透明大页 | **always** |
| squashfs 解压 | 多核并行（`CONFIG_SQUASHFS_DECOMP_MULTI`）|

### 5.3 高安全

| 项 | 状态 |
|----|------|
| KASLR 地址随机化 | ✓ |
| dmesg 限制 | ✓（仅 root）|
| kptr 指针隐藏 | ✓ |
| perf 事件限制 | ✓（level 3）|
| Meltdown 缓解 | ✓（PTI 强制开启）|
| W+X 映射检查 | ✓ `Checked W+X mappings: passed` |
| SSH 禁 root + 禁密码 | ✓ |
| 防火墙默认拒绝 | 规则已装（nft 工具待补）|
| 主机密钥唯一性 | ✓ 每台机器现场生成 |

---

## 6. 踩坑记录（本轮 17 个）

### 6.1 内核与文件系统

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
| 1 | squashfs 怎么都挂不上，日志无明确报错 | **`CONFIG_SQUASHFS` 默认关闭**。裁剪 defconfig 时只写了「不要什么」（btrfs/xfs/ntfs…），漏了显式打开 squashfs | fragment 显式加 `CONFIG_SQUASHFS=y` 及 xz/zlib 解压支持；新增 6 项内核门禁固化 |
| 2 | `squashfs: Unknown parameter 'loop'` | **BusyBox 的 mount 不支持 `-o loop` 自动关联**（那是 util-linux 的功能），它把 `loop` 当普通参数传给文件系统 | 改用两步：`losetup <dev> <file>` + `mount -t squashfs <dev> <dir>`；门禁加「未误用 mount -o loop」回归检查 |
| 3 | 找到 squashfs 但挂载卡住不返回 | **`-comp xz -b 1M`** 的组合在 initramfs 阶段（内存紧张）不稳定 | 改 `-comp gzip -b 128K`，体积增 20% 换取「一定能挂上」；参数做成环境变量可调 |

### 6.2 命名空间与挂载

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
| 4 | overlay 挂载卡住（losetup 成功、容量正确）| 可写层只 `mkdir` 未挂 tmpfs，而 **initramfs 的根是 ramfs**，不支持 overlayfs 所需的 d_type/xattr 语义 | 显式 `mount -t tmpfs tmpfs /mnt/rw` |
| 5 | switch_root 后完全没有输出，无 panic 无报错 | `say()` 改成只写 stdout 后，**switch_root 之后 stdout 不保证送达控制台** | 显式写 `/dev/console`，且只写一次（双写会重复并可能填满 tty 缓冲造成阻塞）|
| 6 | 无法区分「switch_root 失败」与「打印丢失」| 缺少可观测性 | switch_root 前加体检：init 可执行性、`/dev/console` 与 `/dev/null` 存在性、`chroot` 试运行 bash、init 语法检查 |

### 6.3 服务与权限

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
| 7 | init 卡在「生成 SSH 主机密钥」，系统永不到 shell | `ssh-keygen -A` 生成 RSA 等多套密钥需大量随机数；VM 熵源稀缺 + `random.trust_cpu=off`，`/dev/random` 阻塞 | 只生成 ED25519（瞬时完成）+ 整个 SSH 初始化放后台子 shell。刻意不放宽 `random.trust_cpu`，用工程手段而非降低安全策略解决 |
| 8 | `sshd_config: Unsupported option UsePAM` | 编译 openssh 用 `--with-pam=no`，该指令**根本不存在**（设成 `no` 同样报错）| 整行删除该指令 |
| 9 | `/var/lib/sshd must be owned by root` | 构建时非 root，目录属主为构建用户；mksquashfs 默认保留属主 | mksquashfs 加 `-all-root` 统一属主；init 运行时再 `chown root:root` 双保险 |
| 10 | `Unable to load host key: error in libcrypto` | **mksquashfs 静默把无读权限文件打成 0 字节**（私钥 root:root 0600，打包者非 root）| 打包前删除主机密钥（本就不该烘焙进镜像）+ 以 root 打包 + 新增 `verify_squashfs` 关键文件非空校验 |
| 11 | 镜像里烘焙了主机密钥 | 诊断时在 chroot 里生成的测试密钥被一起打包 | 安全原则：**主机密钥必须每台机器现场生成**，绝不可随镜像分发 |

### 6.4 构建工程

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
| 12 | `make install` 在 util-linux 报 `chown: Operation not permitted` | install hook 需 chown + setuid，普通用户无权 | 用 fakeroot 包装 install（LFS/Debian 标准手法）|
| 13 | `ld: cannot find -ltinfo` | ncurses 只加 `--enable-widec` 不产生独立 libtinfo | 加 `--with-termlib`，并建兼容链接双保险 |
| 14 | openssl `make` 报 Error 127（command not found）| `--cross-compile-prefix` 与 target 自带三元组叠加成重复前缀 | 不用该选项，改以环境变量传 `CC`/`AR`/`RANLIB` |
| 15 | 传入 `util-linux` 报「未知包」 | shell 函数名不能含连字符，函数是 `pkg_util_linux` | 加名称规范化（`-` → `_`）|
| 16 | 门禁把 `awk -> gawk` 误报为失败 | 判定逻辑把「符号链接」一律当失败，而指向真实实现的链接是正常的 | 改判「是否指向 `/bin/busybox`」|

### 6.5 测试方法学（最容易被忽视的一类）

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
| 17a | 系统明明起来了，测试却报 5 项失败 | 采集循环一看到「流光OS」就 break，而该字符串在**第 2 秒的引导横幅**里就有；分析的是半截日志 | 等待真正的就绪标志（「启动完成」或 shell 提示符）|
| 17b | SSH 检查出现**假阳性**（BIOS 通过、UEFI 失败，同一 ISO）| sshd 后台启动，采集在「启动完成」即结束，失败消息尚未打印 → 检查项因「没看到失败」而侥幸通过 | 就绪后**再采集 8 秒**，让后台服务结论落盘 |
| 18 | 门禁报 3 项失败，但**同一环境下手工敲同样的命令全部通过** | 脚本顶部有 `set -o pipefail`，而检查写法是 `unsquashfs -l … \| grep -q …`。`grep -q` 命中即退出，上游命令收到 **SIGPIPE**（退出码 141），pipefail 把这次「正常提前退出」当成整个管道失败 | 在 `chk()` 内临时 `set +o pipefail` 执行后恢复；批量加固了 6 个脚本的 gate |
| 19 | 硬盘启动后立即 kernel panic：`/init: syntax error: unexpected end of file (expecting "fi")` | 加 `ext4 可写根` 分支时漏写一个 `fi`。**`bash -n` 只检查生成脚本，heredoc 里的语法错误完全检不出来** | 门禁新增两项：`bash -n <生成的 /init>` 与 `if/fi` 计数配对 |
| 20 | 完整系统里 DHCP 静默失效（「网络地址：未配置」），日志无任何报错 | 完整 lfOS 由真实工具构成、**不含 BusyBox**，而 `udhcpc` 是 BusyBox 专有 applet，没有替代品 | 把 BusyBox 放入 `/usr/lib/lfos/`，**只为系统确实缺失的命令**建链接（不覆盖完整工具），并补齐 `udhcpc` 配置脚本 |
| 21 | SSH 主机密钥时而生成失败、时而「文件存在却损坏」，且无任何错误输出 | 两因叠加：**(a)** 判断只用了 `[ -f ]`，残缺文件也算存在，下次启动跳过生成；**(b)** 强制关机时 ext4 来不及刷盘，留下 0 字节文件 | 改用 `-s` 判非空 + `ssh-keygen -l` 校验可解析 + 生成后 `sync` + 全流程 `timeout` 兜底 |
| 22 | ssh-keygen 永久阻塞，日志停在「SSH 服务正在后台启动」之后毫无输出 | `random.trust_cpu=off`（不信任 CPU 的 RDRAND）+ 虚拟机熵源稀缺 → **`crng init done` 始终不出现**，任何 `getrandom()` 调用永久阻塞 | cmdline 与编译期同时改为信任 CPU 硬件熵（主流发行版默认做法）。修复后 **`crng init done` 在 0.41 秒出现**，SSH 立即正常 |
| 23 | 验证持久化时得出「未生效」的错误结论 | 检查了**错误的文件**：VM 用的是 `D:\lfOS\build\img\lfos-disk.vdi`，而检查的是 WSL 里的构建产物（两者是独立文件，互不影响） | 明确「验证对象必须是运行时实际使用的文件」；改用直接挂载 VM 的 VDI 并核对文件时间戳 |
| 24 | 补装 wget 时交叉编译报 `C compiler cannot create executables` | 打包清理阶段执行了「删除所有 `.a` 静态库」，把 glibc 的 **`libc_nonshared.a`** 一并删除。而 `/usr/lib/libc.so` 实为链接脚本：`GROUP ( libc.so.6 libc_nonshared.a AS_NEEDED ( ld-linux ) )` —— **动态链接也依赖它**（提供 atexit、stack_chk_fail_local 等符号）。删除后 rootfs 作为 sysroot 彻底失效 | 清理规则改为保留 `*.nonshared.a`；重新编译 glibc 只取回缺失的静态库（不执行 make install，避免覆盖运行期文件）|

> **关于 #24 的警示**：「删除静态库以减小体积」是看似无害的优化，
> 但它破坏了**构建环境**与**运行环境**的边界认知 ——
> rootfs 同时充当「目标系统」和「交叉编译 sysroot」两个角色，
> 后者的需求（链接脚本引用的库）与前者（运行期只需 .so）并不相同。
> 优化体积时必须区分这两类角色。

> **关于 #22 的取舍说明**：`random.trust_cpu=off` 在纯安全视角下更严谨（不盲信硬件随机数），
> 但它导致系统处于「SSH 永远不可用」的状态 —— 这本身就是更大的安全问题。
> 可用性是安全的一部分。主流发行版（Debian/Ubuntu/RHEL）默认都是信任 CPU 硬件熵。
>
> **关于 #23 的方法论**：本轮先后三次因为「检查了错误的文件/错误的时机」而得出错误结论
> （raw 与 vdi 混淆、检查构建产物而非 VM 实例、采集窗口过短）。
> **验证的第一原则是：确认你观察的正是被测对象。**

> **这一组教训比技术细节更重要**：
> 测试脚本自身的缺陷会同时制造**假阴性**（明明成功却报失败，让人去修没坏的东西）
> 和**假阳性**（明明失败却报通过，把问题留到生产）。
> 遇到「日志停在某处」时，先怀疑采集是否完整，再怀疑被测系统；
> 遇到「门禁失败但手工能过」时，先怀疑 shell 选项（pipefail）与管道语义。

---

## 7. 产物清单

### 7.1 可启动产物（`D:\lfOS\build\`）

| 文件 | 体积 | 说明 |
|------|------|------|
| `img/lfos.iso` | **172 MB** | **完整系统 ISO，BIOS + UEFI 双引导**，混合镜像可 `dd` 到 U 盘 |
| `img/rootfs.squashfs` | 43 MB | 只读压缩根（gzip / 128K 块）|
| `img/rootfs.ext4` | 149 MB | 可写 ext4 根（供磁盘安装）|
| `img/lfos-boot.vdi` | — | VirtualBox 磁盘 |
| `img/lfos-boot.raw` | — | 原始磁盘镜像 |
| `kernel/bzImage` | 9.5 MB | 加固内核（含 EFI stub + 内置 cmdline）|
| `boot-initramfs.cpio.gz` | 1.2 MB | 引导 initramfs（squashfs + overlay + switch_root）|
| `initramfs-lfos.cpio.gz` | 1.2 MB | 最小 initramfs（救援模式）|

### 7.2 脚本（`D:\lfOS\scripts\`）

| 脚本 | 职责 |
|------|------|
| `21-fetch-base-sources.sh` | Phase 2 源码获取（多镜像回退）|
| `41-build-base.sh` | 基础系统交叉编译（28 包 + 门禁 34 项）|
| `50-build-kernel.sh` | 内核配置/编译/门禁（69 项）|
| `60-build-initramfs.sh` | BusyBox + 最小 initramfs |
| `61-build-boot-initramfs.sh` | 引导 initramfs（switch_root + overlay，门禁 11 项）|
| `72-pack-rootfs.sh` | squashfs / ext4 打包 + **完整性校验** |
| `75-make-iso.sh` | 双引导 ISO（门禁 7 项）|
| `80-apply-hardening.sh` | 安全基线集成（8 项）|
| `81-vbox-iso-test.ps1` | ISO 启动验证（BIOS+UEFI 各 15 项）|
| `82-install-init.sh` | lfOS init 系统（8 项）|
| `83-setup-system.sh` | 系统基础文件（10 项）|

### 7.3 配置（`D:\lfOS\config\`）

| 文件 | 内容 |
|------|------|
| `kernel-lfos-vbox.fragment` | 内核加固与裁剪配置（420+ 行）|
| `sysctl-lfos.conf` | 62 条运行时内核参数 |
| `sshd_config-lfos` | SSH 加固配置 |
| `nftables-lfos.conf` | 防火墙规则 |
| `harden.sh` | 一键加固脚本 |

---

## 7.4 虚拟机（VirtualBox）

已提供一个**开箱即用、持久化**的 lfOS 虚拟机。

### 7.4.1 为什么是「持久化」而不是 Live

| | ISO Live 模式 | 磁盘安装模式（本虚拟机）|
|---|---|---|
| 根文件系统 | squashfs 只读 + tmpfs 可写层 | **ext4 可写** |
| 重启后 | 改动全部丢失 | **改动保留** |
| 适用 | 试用、救援、安装介质 | 日常使用、开发、长期运行 |

虚拟机的系统盘由 `71-make-disk.sh` 制作：MBR + 单 ext4 分区（2 GiB，动态分配），
内含完整 lfOS 与 extlinux 引导器。启动时 initramfs 通过内核参数 `root=/dev/sda1`
找到系统盘，**识别为 ext4 后直接以可写方式挂载**（不叠加 overlay），
因此所有改动都落到磁盘上。

> 探测顺序刻意设计为「ext4 系统盘优先于 ISO 内的 squashfs」：
> 当机器同时插着安装 ISO 时，用户期望启动的是**已安装的系统**，而不是回到 Live 环境。

### 7.4.2 创建与使用

```powershell
# 创建虚拟机（文件放在 D:\lfOS\vbox，不占 C 盘）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\lfOS\scripts\84-create-vm.ps1

# 启动
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm lfOS --type gui
# 或直接打开 VirtualBox 管理器双击 lfOS

# 自动化验证（无头启动 + 串口日志分析 + 自动关机）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\lfOS\scripts\85-test-vm.ps1
```

**虚拟机规格**：2 GB 内存 / 2 核 / SATA 控制器 / NAT 网络 / 串口重定向到日志文件。
系统盘 2 GiB 动态分配（实际占 182 MB，随使用增长）。

### 7.4.3 实测结果

```
第 1 次启动：12/12 通过    第 2 次启动：12/12 通过
  crng init done   0.414s     crng init done   0.411s
  SSH 密钥        已生成       SSH 密钥        未重新生成（复用持久化的）
  sshd            已启动       sshd            已启动
  网络地址        10.0.2.15/24（DHCP）
  根文件系统      ext4（可写）
  内存占用        102 MB / 1985 MB
```

**持久化的硬证据**（直接挂载 VM 的 VDI 核对）：

```
/etc/ssh/ssh_host_ed25519_key   399 字节  权限 600  属主 root:root
SHA256:qrP8DQj0Vb9PcRJ86rfoH6hXq/z0xbtnQybBUoKRyAw root@lfos (ED25519)
```

密钥真实落在磁盘上、权限正确、第二次启动直接复用 —— 持久化确认生效。

---

## 8. 使用说明

### 8.1 VirtualBox 验证

```powershell
# 完整验证（BIOS + UEFI，各 15 项）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\lfOS\scripts\81-vbox-iso-test.ps1 -Firmware both

# 保留 VM 用图形界面观察
powershell -NoProfile -ExecutionPolicy Bypass -File D:\lfOS\scripts\81-vbox-iso-test.ps1 -Firmware uefi -KeepVM -Gui
```

### 8.2 写入 U 盘

```bash
sudo dd if=lfos.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

### 8.3 启动后可用的操作

```bash
harden.sh --check          # 检查安全基线状态
harden.sh --apply          # 应用全部加固
ip addr show               # 查看网络
systemctl ...              # 不适用（lfOS 用 /sbin/init，无 systemd）
cat /etc/lfos-release      # 发行信息
```

### 8.4 重建完整 ISO

```bash
# 1) 基础系统（首次或需要更新时）
bash /opt/lfOS/scripts/41-build-base.sh all

# 2) 系统配置
bash /opt/lfOS/scripts/83-setup-system.sh all
bash /opt/lfOS/scripts/80-apply-hardening.sh all
bash /opt/lfOS/scripts/82-install-init.sh all

# 3) 打包与镜像
LFOS_SQ_COMP=gzip LFOS_SQ_BLOCK=128K bash /opt/lfOS/scripts/72-pack-rootfs.sh squashfs
bash /opt/lfOS/scripts/61-build-boot-initramfs.sh all
bash /opt/lfOS/scripts/75-make-iso.sh all
```

---

## 9. 已知限制与后续路线

### 9.1 已知限制

| 项 | 说明 |
|----|------|
| nftables 用户态 | 未构建（需 libmnl/libnftnl）；内核支持已就绪，规则文件已装 |
| DHCP | 依赖 BusyBox `udhcpc`；静态配置需手工写 `/etc/resolv.conf` |
| shadow | configure 失败，改用静态 passwd/group/shadow 文件 |
| SELinux | 内核已支持，用户态策略未落地 |
| Live 模式持久性 | 默认内存可写层，重启还原（设计如此）；持久化需磁盘分区 |

### 9.2 下一步

1. **libmnl / libnftnl / nftables** —— 让防火墙规则真正生效
2. **磁盘安装程序** —— 把 ISO 装到硬盘（含引导器安装、分区）
3. **持久化分区支持** —— 自动识别 `lfos-persist` 并挂载为 overlay 上层
4. **shadow 修复** —— 完整用户管理（useradd/passwd）
5. **服务管理框架** —— 完善 `/etc/init.d` 或引入 s6/runit
6. **SELinux 策略** —— Phase 5 的强制访问控制
7. **性能基准** —— 与 Debian/Ubuntu 的 sysbench / fio / wrk 对比

---

## 10. 附录：关键设计决策记录

| 决策 | 选择 | 理由 |
|------|------|------|
| 根文件系统形态 | squashfs + overlay 而非纯 ext4 | 不可篡改、高压缩比、契合不可变服务器理念；体积 43 MB vs 149 MB |
| 初始化系统 | 自制 shell init 而非 systemd | 低占用、可审计、攻击面最小；Phase 4 可平滑迁移 |
| C 库 | glibc 而非 musl | 服务器生态兼容性优先 |
| SSH 主机密钥 | 首次启动现场生成 | 安全：保证每台机器身份唯一 |
| 内核模块 | 不启用（单体内核）| 攻击面最小；`0 modules` 实测 |
| `random.trust_cpu` | 保持 `off` | 不盲信硬件熵；用后台化解决启动阻塞而非放宽策略 |
| squashfs 压缩 | gzip + 128K | 兼容性/稳定性优先于体积（xz+1M 实测会导致挂载卡住）|
