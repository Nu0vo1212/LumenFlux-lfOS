#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lfOS SSH 客户端（测试用，凭据已硬编码）

用途：从宿主机直接连进 VirtualBox 里的 lfOS 虚拟机做实测。

连接路径：
    宿主机 127.0.0.1:2222
        └─ VirtualBox NAT 端口转发（VBoxManage modifyvm lfOS --natpf1 "ssh,tcp,127.0.0.1,2222,,22"）
             └─ lfOS 虚拟机 sshd 监听 22

前置条件（缺一不可）：
    1) 虚拟机的磁盘镜像是用「测试模式」打包的，即执行过
           bash scripts/51-enable-ssh-password.sh on
       该脚本会：给 root 设密码、把 sshd_config 的 PermitRootLogin 与
       PasswordAuthentication 改为 yes。默认镜像出于安全考虑是禁止密码登录的。
    2) 虚拟机已启动（VBoxManage startvm lfOS --type headless）
    3) 端口转发已配置

依赖：
    pip install paramiko

用法：
    python lfos_ssh.py                      # 交互式 shell
    python lfos_ssh.py "uname -a"           # 执行单条命令
    python lfos_ssh.py -f cmds.txt          # 逐行执行文件里的命令
    python lfos_ssh.py -u root -p lfos ...  # 覆盖默认凭据
"""

import argparse
import sys
import time

# ---------------------------------------------------------------------------
# Windows 控制台默认编码是 GBK（cp936），而 lfOS 输出的是 UTF-8，
# 直接打印会让中文全变成乱码（实测「流光OS」显示为「����OS」）。
# 这里把标准流切到 UTF-8。Python 3.7+ 支持 reconfigure()。
# ---------------------------------------------------------------------------
if sys.platform == "win32":
    for _stream in ("stdout", "stderr", "stdin"):
        try:
            getattr(sys, _stream).reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    # 部分终端还需要把控制台代码页也切到 UTF-8；
    # 失败不影响主流程（reconfigure 已能解决大部分情况）。
    try:
        import ctypes
        ctypes.windll.kernel32.SetConsoleOutputCP(65001)
        ctypes.windll.kernel32.SetConsoleCP(65001)
    except Exception:
        pass

try:
    import paramiko
except ImportError:
    sys.stderr.write(
        "缺少 paramiko。请先安装：\n"
        "    pip install paramiko\n"
    )
    sys.exit(2)

# ---------------------------------------------------------------------------
# 硬编码的连接参数（按你的要求写死）
# ---------------------------------------------------------------------------
HOST = "127.0.0.1"      # 宿主机回环；VirtualBox NAT 把 2222 转发到虚拟机的 22
PORT = 2222
USER = "root"
PASSWORD = os.environ.get("LFOS_PASSWORD", "")   # 请通过环境变量提供；示例中不写死凭据
# 目标系统是自建的最小化发行版，握手/响应可能比常规服务器慢，给足超时
CONNECT_TIMEOUT = 15
CMD_TIMEOUT = 120


def connect(host=HOST, port=PORT, user=USER, password=PASSWORD, verbose=True):
    """建立 SSH 连接并返回 client。"""
    client = paramiko.SSHClient()
    # 测试环境：虚拟机每次重建都会重新生成主机密钥，
    # 用 AutoAddPolicy 避免 known_hosts 冲突导致连不上。
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    if verbose:
        print(f"  连接 {user}@{host}:{port} ...")
    t0 = time.time()
    try:
        client.connect(
            hostname=host,
            port=port,
            username=user,
            password=password,
            timeout=CONNECT_TIMEOUT,
            # 目标系统只提供这些算法（sshd_config 里限定了），
            # 若 paramiko 版本较老可能需要在两端协商，这里交给默认协商
            look_for_keys=False,      # 不去翻本地 ~/.ssh 的密钥
            allow_agent=False,        # 不用 ssh-agent
        )
    except paramiko.AuthenticationException:
        sys.stderr.write(
            "认证失败：用户名或密码不对。\n"
            "  请确认镜像里已执行过 scripts/51-enable-ssh-password.sh on\n"
            f"  （默认 root / {PASSWORD}）\n"
        )
        raise SystemExit(3)
    except Exception as exc:
        sys.stderr.write(
            f"连接失败：{exc}\n"
            "  排查顺序：\n"
            "    1) 虚拟机是否在运行  → VBoxManage list runningvms\n"
            "    2) 端口转发是否配置  → VBoxManage showvminfo lfOS | findstr Forwarding\n"
            "    3) 宿主机 2222 是否可连（见 readme 里的测试方法）\n"
        )
        raise SystemExit(4)

    if verbose:
        print(f"  已连接（{time.time() - t0:.2f}s）")
    return client


def run(client, command, timeout=CMD_TIMEOUT, stream=True):
    """执行一条命令，实时打印输出，返回退出码。"""
    chan = client.get_transport().open_session()
    chan.settimeout(timeout)
    chan.exec_command(command)

    if stream:
        # 边收边打，避免 apt 这类长命令的输出堆积在缓冲区里看不到进度
        while True:
            if chan.recv_ready():
                sys.stdout.write(chan.recv(4096).decode("utf-8", "replace"))
                sys.stdout.flush()
            if chan.recv_stderr_ready():
                sys.stderr.write(chan.recv_stderr(4096).decode("utf-8", "replace"))
                sys.stderr.flush()
            if chan.exit_status_ready() and not chan.recv_ready() and not chan.recv_stderr_ready():
                break
            time.sleep(0.05)
        # 收干残留
        while chan.recv_ready():
            sys.stdout.write(chan.recv(4096).decode("utf-8", "replace"))
        while chan.recv_stderr_ready():
            sys.stderr.write(chan.recv_stderr(4096).decode("utf-8", "replace"))
        sys.stdout.flush()
        sys.stderr.flush()

    rc = chan.recv_exit_status()
    chan.close()
    return rc


def interactive(client):
    """交互式 shell（带简单 PTY）。"""
    chan = client.get_transport().open_session()
    # 申请 PTY：这样目标端的 bash 会进入交互模式（有提示符、支持作业控制）
    chan.get_pty(term="xterm", width=120, height=40)
    chan.invoke_shell()
    chan.settimeout(0.2)

    print("\n已进入 lfOS 交互 shell。输入 exit 退出，Ctrl+C 中断当前命令。\n")
    import threading

    stop = threading.Event()

    def reader():
        while not stop.is_set():
            try:
                if chan.recv_ready():
                    sys.stdout.write(chan.recv(4096).decode("utf-8", "replace"))
                    sys.stdout.flush()
            except Exception:
                break
            time.sleep(0.05)

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    try:
        while chan.active:
            line = sys.stdin.readline()
            if not line:
                break
            if line.strip() in ("exit", "logout"):
                break
            chan.send(line)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        time.sleep(0.2)
        chan.close()


def main():
    ap = argparse.ArgumentParser(
        description="lfOS SSH 客户端（凭据已硬编码，供实测使用）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例：\n"
            "  python lfos_ssh.py                        # 交互 shell\n"
            '  python lfos_ssh.py "nft list ruleset"     # 单条命令\n'
            "  python lfos_ssh.py -f cmds.txt            # 批量执行\n"
        ),
    )
    ap.add_argument("command", nargs="?", help="要执行的命令（省略则进入交互 shell）")
    ap.add_argument("-f", "--file", help="从文件逐行读取命令执行（每行一条，不支持 for/if 等多行结构）")
    ap.add_argument("--script", help="把文件整体作为一个脚本执行（支持 for/if/函数等多行结构）")
    ap.add_argument("-u", "--user", default=USER)
    ap.add_argument("-p", "--password", default=PASSWORD)
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--timeout", type=int, default=CMD_TIMEOUT, help="单条命令超时秒数")
    args = ap.parse_args()

    print("=" * 62)
    print("  lfOS SSH 客户端")
    print(f"  目标  {args.user}@{args.host}:{args.port}")
    print("=" * 62)

    client = connect(args.host, args.port, args.user, args.password)

    try:
        if args.script:
            # 整体作为一个脚本执行：支持 for/if/函数等多行结构。
            # 为什么需要这个模式：-f 是逐行发送的，远端的 bash 每行都是
            # 一个独立进程，`for ... do ... done` 这种跨行结构会被
            # 拆散并报 "syntax error near unexpected token"。实测踩到过。
            with open(args.script, encoding="utf-8") as fh:
                body = fh.read()
            print(f"\n  执行脚本 {args.script}（{len(body.splitlines())} 行）\n")
            print("=" * 62)
            rc = run(client, body, timeout=args.timeout)
            print("=" * 62)
            print(f"  脚本退出码 {rc}")
            sys.exit(rc)
        elif args.file:
            with open(args.file, encoding="utf-8") as fh:
                cmds = [ln.rstrip("\n") for ln in fh if ln.strip() and not ln.startswith("#")]
            print(f"\n  从 {args.file} 读取 {len(cmds)} 条命令\n")
            bad = 0
            for i, cmd in enumerate(cmds, 1):
                print(f"\n[{i}/{len(cmds)}] $ {cmd}")
                print("-" * 62)
                rc = run(client, cmd, timeout=args.timeout)
                if rc != 0:
                    bad += 1
                    print(f"  （退出码 {rc}）")
            print("\n" + "=" * 62)
            print(f"  完成：{len(cmds) - bad} 成功 / {bad} 非零退出")
            print("=" * 62)
        elif args.command:
            rc = run(client, args.command, timeout=args.timeout)
            print(f"\n  （退出码 {rc}）")
            sys.exit(rc)
        else:
            interactive(client)
    finally:
        client.close()
        print("\n  连接已关闭")


if __name__ == "__main__":
    main()
