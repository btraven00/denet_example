#!/usr/bin/env python3
"""Idle, then write a known amount and exit promptly.

/proc/<pid>/io write_bytes is monotonic and a reaped child's accounting is folded
into its parent, so a tree-summing monitor's reported peak is simply its LAST
SAMPLE. Any bytes written after that sample are lost. With Snakemake's schedule
(0.5 s for 15 s, then 30 s) the final sample can precede process exit by up to
30 s -- and a pipeline that writes its output at the end writes exactly there.
"""
import argparse, os, time

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--idle-s", type=float, required=True)
    p.add_argument("--mib", type=int, required=True)
    p.add_argument("--path", required=True)
    a = p.parse_args()
    time.sleep(a.idle_s)
    buf = b"\xa5" * (1024*1024)
    with open(a.path, "wb") as fh:
        for _ in range(a.mib): fh.write(buf)
        fh.flush(); os.fsync(fh.fileno())
    os.unlink(a.path)
