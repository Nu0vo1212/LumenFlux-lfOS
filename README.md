# LumenFluxOS（lfOS · 流光OS）

**从零构建的高性能 / 高安全 / 低占用的 Linux 服务器发行版**

版本：**v0.0.1（首个可启动测试版）**

---

## 这是什么

lfOS 不是某个发行版的衍生版，而是按 LFS/BLFS 方法从源码构建的独立系统：自建工具链、
自编译内核、自研初始化系统（无 systemd）、自选的软件包集合。目标是做一个**能替代
Debian 跑服务器**的轻量系统。

### 设计取向

| 维度 | 做法 |
|---|---|
| **高性能** | 内核 `PREEMPT_NONE` + BBR 拥塞控制 + 透明大页 + 1000Hz 时钟；无调试符号、无 ftrace/lockdep/KASAN |
| **高安全** | 默认拒绝入站（ufw）、`init_on_alloc`、`slab_nomerge`、`pti=on`、`vsyscall=none`、无模块单体内核 |
| **低占用** | 内存 **~120MB**、磁盘 **~240MB**、ISO **167MB**；无 systemd、无 X、无冗余运行时 |

---

## v0.0.1 实测指标

```
内核     6.15.4-lfos（自编译，x86_64_defconfig + 定制 fragment）
内存     120 MB / 1985 MB
进程     66 个
磁盘     238 MB / 2.0 GB（13%）
启动     /sbin/init（自研 bash 脚本，9 步）→ 约 15 秒
防火墙   ufw 0.36.2（默认拒绝入站 / 允许出站 / 放行 22）
SSH      OpenSSH，ED25519 主机密钥（首次启动生成）
包管理   apt + dpkg（Debian trixie 源，123 个包）
CA 证书  150 张（HTTPS 开箱可用）
```

### 无 systemd 的初始化

`/sbin/init` 是一个 bash 脚本，按固定顺序执行 9 步：

```
1/9 挂载伪文件系统      6/9 （保留）
2/9 设置主机名          7/9 执行 /etc/rc.local
3/9 应用内核参数        8/9 系统自检
4/9 配置网络            9/9 启动交互 shell
5/9 加载防火墙规则（ufw）
```

---

## 快速开始

### 方式一：ISO（Live 模式）

```bash
# 挂载到虚拟机，或写入 U 盘
dd if=lfos-server.iso of=/dev/sdX bs=4M status=progress
```

ISO 已写入混合 MBR，BIOS / UEFI 均可引导。Live 模式使用 overlay，重启还原。

### 方式二：磁盘镜像（可持久化）

```bash
# VirtualBox
VBoxManage convertfromraw lfos-server-disk.raw lfos.vdi --format VDI
# QEMU
qemu-system-x86_64 -m 2048 -hda lfos-server-disk.raw
```

默认凭据（**仅供测试，正式使用前必须更换**）：

```
用户 root   密码 lfos   SSH 端口 22
```

---

## 常用命令

```bash
# 防火墙（Ubuntu 风格）
ufw status verbose
ufw allow 80/tcp
ufw deny 3306
ufw allow from 10.0.2.0/24 to any port 8080 proto tcp
ufw delete allow 80/tcp
ufw app list

# 系统加固
harden.sh

# 查看状态
nft list ruleset
ss -tlnp
```

---

## 仓库结构

```
scripts/    构建脚本（按 Phase 编号，49 个）
  00-*      环境准备与工具链
  10-*      Phase 1 交叉工具链
  50-*      内核构建与门禁
  52-*      精简
  53-*      Ubuntu 工具集
  56-*      CA 证书
  57-*      修复 apt 依赖
  58-*      最终固化
  71-76-*   磁盘与 ISO 打包
config/     内核 fragment、防火墙、sshd、sysctl、加固脚本
docs/       各阶段构建报告
tools/      自研 SSH/SFTP 客户端（paramiko，带进度条）
```

### 构建

```bash
sudo bash scripts/10-build-toolchain.sh     # Phase 1 工具链
sudo bash scripts/50-build-kernel.sh all    # 内核 + 门禁
sudo bash scripts/76-make-server-disk.sh    # 磁盘镜像
```

---

## 这一版踩过并修掉的关键问题

构建过程中定位的真实缺陷（都有实测证据，值得后来的版本避开）：

1. **`su` 归属冲突** —— 自建 `login` 包与 Debian `util-linux` 都声明 `/usr/bin/su`，
   dpkg 事务中断后出现「数据库标记已装、文件未落地」的假象：`dpkg -l` 全部正常，
   但可执行文件根本不存在。

2. **992 个文件属主错误** —— 构建用户 uid 1000 泄漏进镜像，含 `/etc/shadow` 与
   **11 个 setuid root 程序**，是提权漏洞。根因是 ext4 打包未统一属主（squashfs 用了
   `-all-root`，所以没暴露）。修法：`58-finalize.sh` 强制 `uid 1000 → root`。

3. **`shadow` 组缺失，gid 42 被 `_apt` 占用** —— 导致 `/etc/shadow` 属主错误。
   按 `base-passwd/group.master` 校正：`shadow:*:42:`，`_apt` 迁到 999。

4. **`/dev/fd` 缺失** —— 所有使用进程替换 `< <(...)` 的脚本都会失败
   （`/dev/fd/63: No such file or directory`）。

5. **init 早期 `/tmp` 不存在** —— init 多处用 `2>/tmp/xxx` 承接错误输出，缺 `/tmp`
   时 bash 直接报错、命令被判失败，表现为「防火墙规则加载失败」「sshd 配置检查未通过」，
   而且因为错误文件根本写不出来，**连失败原因都看不到**。
   修法：step 1 之后立刻创建 `/tmp` 并挂 tmpfs。

6. **ufw 配置含非 ASCII 会让它崩溃** —— `ufw/util.py` 用
   `os.write(fd, bytes(out, 'ascii'))` 重写配置，中文注释触发 `UnicodeEncodeError`，
   配置被写坏，且 `ufw enable` 时把 SSH 一起挡住（当时只能走串口控制台救回）。
   现在所有 ufw 配置强制纯 ASCII。

7. **内核符号名写错会被静默忽略** —— `CONFIG_NETFILTER_XT_TARGET_REJECT` 与
   `CONFIG_NETFILTER_XT_MATCH_RT` 在 6.15 里**并不存在**，kconfig 对未知符号既不报错
   也不写入 `.config`，只能翻 Kconfig/Makefile 才能发现。正确名是
   `IP_NF_TARGET_REJECT` / `IP6_NF_MATCH_RT`。

8. **`GNU cpio 2.15` 不支持 `--quiet`** —— 曾误判为 initramfs 格式损坏。

---

## 已知限制

- 默认凭据（root/lfos）与 `PermitRootLogin yes` **仅供测试**，公开使用前必须更换
- apt 源默认 `deb.debian.org`（实测仅 ~19 kB/s），建议换 `mirrors.aliyun.com`
- ISO 为 Live 模式（overlay），数据不持久；需持久化请用磁盘镜像
- 内核 9.5 MB，略超 8 MB 目标，仍有裁剪空间
- 未包含图形界面：VirtualBox 下 X 栈五条路线均实测不通（见 docs）

---

## 许可

测试版，暂未选定许可证。
