#!/usr/bin/env python3
"""Two writers in sequence, mimicking two pipeline stages that spill and exit.

Child A writes MIB_A and exits; child B then writes MIB_B and exits; the parent
lives throughout. True total is MIB_A + MIB_B, but no single instant has both
children alive, so a monitor that sums /proc/<pid>/io over currently-alive
processes can never observe the sum.
"""
import argparse, os, sys, time

def write(path, mib):
    buf = b"\xa5" * (1024*1024)
    with open(path, "wb") as fh:
        for _ in range(mib): fh.write(buf)
        fh.flush(); os.fsync(fh.fileno())
    n = os.path.getsize(path); os.unlink(path); return n

def spawn(path, mib):
    pid = os.fork()
    if pid == 0:
        os._exit(0 if write(path, mib) == mib*1024*1024 else 1)
    _, st = os.waitpid(pid, 0)
    if os.waitstatus_to_exitcode(st) != 0: sys.exit("writer failed")

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--mib-a", type=int, default=374)
    p.add_argument("--mib-b", type=int, default=542)
    p.add_argument("--dir", required=True)
    p.add_argument("--gap-s", type=float, default=1.0)
    a = p.parse_args()
    spawn(os.path.join(a.dir, "a.tmp"), a.mib_a)
    time.sleep(a.gap_s)
    spawn(os.path.join(a.dir, "b.tmp"), a.mib_b)
    time.sleep(a.gap_s)
