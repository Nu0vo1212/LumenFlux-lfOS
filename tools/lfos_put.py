#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lfOS 文件上传工具（SFTP）

为什么单独写一个：lfos_ssh.py 走的是 exec_command，用它传 12MB 的 tar
需要 base64 编码后塞进命令行，又慢又容易踩参数长度限制。
SFTP 是 paramiko 自带的通道，直接传二进制，稳且快。

用法：
    python lfos_put.py <本地文件> <远端路径>
    python lfos_put.py D:\\lfOS\\build\\themes\\x.tar.gz /tmp/x.tar.gz
    python lfos_put.py <本地目录> <远端目录> --dir     # 递归上传目录
    python lfos_put.py --port 2322 <本地> <远端>       # 指定 SSH 端口（默认 2222）
"""

import os
import posixpath
import sys
import time

import paramiko

if sys.platform == "win32":
    for _s in ("stdout", "stderr"):
        try:
            getattr(sys, _s).reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def _arg_value(flag, default):
    """从 argv 里取 --flag value（找不到就用默认）"""
    if flag in sys.argv:
        i = sys.argv.index(flag)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


# 支持命令行/环境变量覆盖：默认对应主 VM 的 2222，
# 测试用的临时 VM 常配在 2322 等端口上。
HOST = _arg_value("--host", os.environ.get("LFOS_HOST", "127.0.0.1"))
PORT = int(_arg_value("--port", os.environ.get("LFOS_PORT", 2222)))
USER = _arg_value("--user", os.environ.get("LFOS_USER", "root"))
PASSWORD = _arg_value("--password", os.environ.get("LFOS_PASSWORD", ""))


def human(n):
    for u in ("B", "KB", "MB", "GB"):
        if abs(n) < 1024:
            return f"{n:,.1f}{u}"
        n /= 1024.0
    return f"{n:.1f}TB"


def progress(name, done, total, t0):
    pct = done / total * 100 if total else 0
    filled = int(30 * (done / total)) if total else 0
    bar = "█" * filled + "░" * (30 - filled)
    el = time.time() - t0
    sp = done / el if el > 0.05 else 0
    sys.stdout.write(f"\r  {name[:28]:<28} |{bar}| {pct:5.1f}%  {human(done)}/{human(total)}  {human(sp)}/s   ")
    sys.stdout.flush()


def put_file(sftp, local, remote, label=None):
    size = os.path.getsize(local)
    name = label or os.path.basename(local)
    t0 = time.time()
    last = [0.0]

    def cb(done, total):
        now = time.time()
        if now - last[0] > 0.15 or done >= total:
            progress(name, done, total, t0)
            last[0] = now

    sftp.put(local, remote, callback=cb)
    progress(name, size, size, t0)
    sys.stdout.write("\n")
    sys.stdout.flush()
    return size


def put_dir(sftp, local_dir, remote_dir):
    total_files = 0
    total_bytes = 0
    for root, _dirs, files in os.walk(local_dir):
        rel = os.path.relpath(root, local_dir).replace("\\", "/")
        rdir = remote_dir if rel == "." else posixpath.join(remote_dir, rel)
        try:
            sftp.stat(rdir)
        except IOError:
            sftp.mkdir(rdir)
        for f in files:
            lp = os.path.join(root, f)
            rp = posixpath.join(rdir, f)
            try:
                put_file(sftp, lp, rp)
                total_files += 1
                total_bytes += os.path.getsize(lp)
            except Exception as exc:  # noqa: BLE001
                print(f"    跳过 {f}: {exc}")
    return total_files, total_bytes


def main():
    # 收集位置参数时，必须跳过 "--flag value" 这种成对出现的选项，
    # 否则 --port 2322 里的 2322 会被当成文件路径。
    OPT_WITH_VALUE = {"--port", "--host", "--user", "--password"}
    args = []
    i = 1
    while i < len(sys.argv):
        a = sys.argv[i]
        if a in OPT_WITH_VALUE:
            i += 2
            continue
        if a.startswith("--"):
            i += 1
            continue
        args.append(a)
        i += 1

    is_dir = "--dir" in sys.argv

    if len(args) < 2:
        print(__doc__)
        return 1

    local, remote = args[0], args[1]
    if not os.path.exists(local):
        print(f"  本地路径不存在: {local}")
        return 1

    print()
    print("  ═══ lfOS SFTP 上传 ═══")
    print(f"  连接 {USER}@{HOST}:{PORT} ...")

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(HOST, PORT, USER, PASSWORD, timeout=15,
                       look_for_keys=False, allow_agent=False)
    except Exception as exc:  # noqa: BLE001
        print(f"  ✘ SSH 连接失败: {exc}")
        return 1

    sftp = client.open_sftp()
    print("  已连接\n")

    t0 = time.time()
    try:
        if is_dir or os.path.isdir(local):
            n, b = put_dir(sftp, local, remote)
            print(f"\n  ✔ 上传完成: {n} 个文件, {human(b)}, 耗时 {time.time()-t0:.1f}s")
        else:
            put_file(sftp, local, remote)
            print(f"  ✔ 上传完成: {remote}, 耗时 {time.time()-t0:.1f}s")
    except Exception as exc:  # noqa: BLE001
        print(f"\n  ✘ 上传失败: {exc}")
        sftp.close()
        client.close()
        return 1

    sftp.close()
    client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
