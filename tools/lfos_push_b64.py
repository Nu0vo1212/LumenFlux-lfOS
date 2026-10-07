#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
通过 SSH exec_command 分块传文件（绕过 SFTP —— 精简系统的 sshd 常没配 SFTP 子系统）

用法:
    python lfos_push_b64.py <本地文件> <远端路径> [--port 2322] [--mode 0755]
"""
import base64
import os
import sys

import paramiko

def arg(flag, default):
    if flag in sys.argv:
        i = sys.argv.index(flag)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default

def main():
    opts = {"--port", "--host", "--user", "--password", "--mode"}
    args, i = [], 1
    while i < len(sys.argv):
        a = sys.argv[i]
        if a in opts:
            i += 2
            continue
        if a.startswith("--"):
            i += 1
            continue
        args.append(a)
        i += 1
    if len(args) < 2:
        print(__doc__)
        return 1

    local, remote = args[0], args[1]
    host = arg("--host", "127.0.0.1")
    port = int(arg("--port", 2222))
    user = arg("--user", "root")
    pwd = arg("--password", "lfos")
    mode = arg("--mode", "0644")

    if not os.path.isfile(local):
        print(f"  本地文件不存在: {local}")
        return 1

    data = open(local, "rb").read()
    b64 = base64.b64encode(data).decode()
    print(f"  文件 {len(data)} 字节 → base64 {len(b64)} 字节")

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, port, user, pwd, timeout=15,
              look_for_keys=False, allow_agent=False)
    print(f"  已连接 {user}@{host}:{port}")

    tmp = "/tmp/_push.b64"
    c.exec_command(f"rm -f {tmp}")[1].channel.recv_exit_status()

    CH = 16000
    n = 0
    for k in range(0, len(b64), CH):
        part = b64[k:k + CH]
        _i, o, e = c.exec_command(f"printf '%s' '{part}' >> {tmp}")
        o.channel.recv_exit_status()
        n += 1
    print(f"  分 {n} 块传输完成")

    cmd = (f"base64 -d {tmp} > {remote} && chmod {mode} {remote} && "
           f"wc -c < {remote} && rm -f {tmp}")
    _i, o, e = c.exec_command(cmd)
    o.channel.recv_exit_status()
    size = o.read().decode().strip()
    err = e.read().decode().strip()
    print(f"  远端写入: {size} 字节  {err}")
    c.close()
    return 0

if __name__ == "__main__":
    sys.exit(main())
