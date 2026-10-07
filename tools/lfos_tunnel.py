#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lfOS 端口隧道 —— 通过 SSH 把 VM 里的服务映射到宿主机本地端口。

为什么需要：VirtualBox 的 NAT 端口转发对 36088 这个 HTTPS 端口失效
（TCP 能连上，但 TLS 握手过不去，宿主机 curl 返回 000，而 VM 内 curl 正常 200）。
SSH 隧道绕开 VBox 的 NAT 实现，直接由 sshd 转发，稳定可靠。

用法：
    python lfos_tunnel.py                 # 默认映射 宝塔面板 36088 -> 本地 13688
    python lfos_tunnel.py 13688 36088     # 自定义 本地端口 远端端口
    python lfos_tunnel.py --list          # 列出常用映射

映射完成后在浏览器打开：
    https://127.0.0.1:13688/5104a479      （宝塔面板，自签证书需点“继续访问”）
"""

import select
import socket
import sys
import threading

try:
    import paramiko
except ImportError:
    print("  需要 paramiko：pip install paramiko")
    sys.exit(1)

if sys.platform == "win32":
    for _s in ("stdout", "stderr"):
        try:
            getattr(sys, _s).reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

VM_HOST = "127.0.0.1"
VM_SSH_PORT = 2222
VM_USER = "root"
VM_PASS = "lfos"

# 常用服务映射：名字 -> (远端端口, 说明)
KNOWN = {
    "bt": (36088, "宝塔面板 (https)"),
    "http": (80, "Web 服务"),
    "https": (443, "Web 服务 (https)"),
    "ssh": (22, "SSH"),
}

_active = 0
_lock = threading.Lock()


def pump(local_conn, chan):
    """在本地连接和 SSH 通道之间双向搬数据。"""
    try:
        while True:
            r, _w, _x = select.select([local_conn, chan], [], [], 60)
            if not r:
                continue
            if local_conn in r:
                data = local_conn.recv(32768)
                if not data:
                    break
                chan.sendall(data)
            if chan in r:
                data = chan.recv(32768)
                if not data:
                    break
                local_conn.sendall(data)
    except Exception:
        pass
    finally:
        try:
            chan.close()
        except Exception:
            pass
        try:
            local_conn.close()
        except Exception:
            pass
        global _active
        with _lock:
            _active -= 1


def handle(local_conn, transport, remote_host, remote_port):
    try:
        chan = transport.open_channel(
            "direct-tcpip", (remote_host, remote_port), local_conn.getpeername()
        )
    except Exception as exc:  # noqa: BLE001
        print(f"  通道打开失败: {exc}")
        local_conn.close()
        return
    pump(local_conn, chan)


def main():
    # 必须声明 global：否则下面的 _active += 1 会让 Python 把 _active 当局部变量，
    # 报 UnboundLocalError: cannot access local variable '_active'
    global _active
    args = [a for a in sys.argv[1:] if not a.startswith("-")]

    if "--list" in sys.argv:
        print("\n  常用映射：")
        for k, (port, desc) in KNOWN.items():
            print(f"    {k:<8} 远端 {port:<6} {desc}")
        print("\n  用法: python lfos_tunnel.py [本地端口] [远端端口]\n")
        return 0

    if len(args) >= 2:
        local_port, remote_port = int(args[0]), int(args[1])
        desc = "自定义"
    else:
        local_port, remote_port, desc = 13688, 36088, "宝塔面板"

    print()
    print("  ═══ lfOS SSH 隧道 ═══")
    print(f"  连接 {VM_USER}@{VM_HOST}:{VM_SSH_PORT} ...")

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(
            VM_HOST, VM_SSH_PORT, VM_USER, VM_PASS,
            timeout=15, banner_timeout=20, auth_timeout=20,
            look_for_keys=False, allow_agent=False,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"  ✘ SSH 连接失败: {exc}")
        print("    排查：VM 是否在运行 / 2222 转发是否配好")
        return 1

    transport = client.get_transport()
    transport.set_keepalive(30)
    print("  已连接")

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(("127.0.0.1", local_port))
    except OSError as exc:
        print(f"  ✘ 本地端口 {local_port} 绑定失败: {exc}")
        print(f"    换一个端口：python lfos_tunnel.py {local_port + 1000} {remote_port}")
        return 1
    server.listen(32)

    print()
    print(f"  ✔ 隧道就绪（{desc}）")
    print(f"     本地 https://127.0.0.1:{local_port}  ->  VM 127.0.0.1:{remote_port}")
    print()
    print("  浏览器访问（自签证书，点“高级 → 继续前往”）：")
    if remote_port == 36088:
        # 直接读宝塔的入口文件（用 paramiko，避免 subprocess 在 Windows 上
        # 默认 GBK 解码导致 UnicodeDecodeError）
        entry = ""
        try:
            _in, _out, _err = client.exec_command(
                "cat /www/server/panel/data/admin_path.pl 2>/dev/null", timeout=15
            )
            entry = (_out.read().decode("utf-8", "replace") or "").strip()
        except Exception:
            entry = ""
        print(f"     https://127.0.0.1:{local_port}{entry or '/<入口>'}")
    else:
        print(f"     http://127.0.0.1:{local_port}")
    print()
    print("  保持这个窗口开着。Ctrl+C 停止隧道。")
    print()

    try:
        while True:
            try:
                conn, addr = server.accept()
            except KeyboardInterrupt:
                raise
            with _lock:
                _active += 1
                n = _active
            sys.stdout.write(f"\r  转发中… 当前连接 {n}   (Ctrl+C 退出)   ")
            sys.stdout.flush()
            threading.Thread(
                target=handle, args=(conn, transport, "127.0.0.1", remote_port), daemon=True
            ).start()
    except KeyboardInterrupt:
        print("\n\n  隧道已停止。")
    finally:
        try:
            server.close()
        except Exception:
            pass
        try:
            client.close()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
