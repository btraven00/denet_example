#!/usr/bin/env python3
"""Reimplementation of Snakemake's benchmark sampling policy, for calibration.

Faithful to snakemake/benchmark.py: every sample resets the accumulator, walks
the monitored process tree, and sums /proc/<pid>/io write_bytes over the
processes that are ALIVE AT THAT MOMENT (benchmark.py:323, 358-360). An exited
child's counters are therefore lost. Interval follows Snakemake's schedule:
0.5 s for the first 15 s, then 30 s.

This is not Snakemake; it is its sampling policy applied to the same workload,
so the two arms of the calibration differ only in sampler.
"""
import os, subprocess, sys, time

def tree(pid):
    out, stack = [], [pid]
    while stack:
        p = stack.pop()
        out.append(p)
        try:
            stack += [int(x) for x in open(f"/proc/{p}/task/{p}/children").read().split()]
        except (FileNotFoundError, ProcessLookupError, ValueError):
            pass
    return out

def write_bytes(pid):
    try:
        for line in open(f"/proc/{pid}/io"):
            if line.startswith("write_bytes:"):
                return int(line.split()[1])
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        pass
    return 0

def interval(elapsed):
    return 0.5 if elapsed < 15 else 30.0

if __name__ == "__main__":
    proc = subprocess.Popen(sys.argv[1:])
    t0, peak, n = time.time(), 0, 0
    while proc.poll() is None:
        total = sum(write_bytes(p) for p in tree(proc.pid))   # alive only
        peak = max(peak, total); n += 1
        time.sleep(interval(time.time() - t0))
    print(f"{peak/1024**2:.0f} {n}")
