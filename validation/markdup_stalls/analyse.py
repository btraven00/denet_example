#!/usr/bin/env python3
"""Summarise run.sh traces: CPU and off-CPU per samtools stage, in the
streaming phase (first to last coordinate-sort spill), split into samples
during a spill, the 3 samples (150 ms) just after one, and the rest.

A spill is a sample where the coordinate sort writes above 20 MB/s. Off-CPU
is denet's eBPF record, summed over a stage's threads and differenced between
samples. The probe credits a wait when the thread wakes up, so a thread
blocked through a whole spill shows its off-CPU time just after the spill."""
import json, sys, statistics as st
from collections import defaultdict

def stage(cmd):
    return "name sort" if "-n" in cmd else ("coord sort" if cmd[1] == "sort" else cmd[1])

CATS = ("during spill", "just after", "other")
res = defaultdict(lambda: defaultdict(list))
spill_s = []
for f in sys.argv[1:]:
    R = [json.loads(l) for l in open(f) if l.strip()]
    name = {r["pid"]: stage(r["cmd"]) for r in R
            if r.get("kind") == "child" and r["cmd"] and r["cmd"][0].endswith("samtools")}
    S, prev = [], None
    for r in (r for r in R if r.get("kind") == "tree"):
        t = r["ts_ms"] / 1e3
        off = defaultdict(float)
        for k, s in (((r["aggregated"].get("ebpf") or {}).get("offcpu") or {}).get("thread_stats") or {}).items():
            n = name.get(int(k.split(":")[0]))
            if n:
                off[n] += s["total_time_ns"] / 1e9
        cpu = {name[c["pid"]]: c["metrics"]["cpu_usage"] for c in r["children"] if c["pid"] in name}
        w = {name[c["pid"]]: c["metrics"]["disk_write_bytes"] for c in r["children"] if c["pid"] in name}
        if prev and "coord sort" in w and "coord sort" in prev[2]:
            dt = t - prev[0]
            spilling = (w["coord sort"] - prev[2]["coord sort"]) / dt > 20e6
            S.append((t, spilling, {n: (cpu[n], off.get(n, 0) - prev[1].get(n, 0)) for n in cpu}))
        prev = (t, off, w)
    idx = [i for i, s in enumerate(S) if s[1]]
    if not idx:
        continue
    after, i = set(), idx[0]
    while i <= idx[-1]:  # spill episodes, and the 3 samples after each
        if S[i][1]:
            j = i
            while j + 1 < len(S) and S[j + 1][1]:
                j += 1
            spill_s.append(S[j][0] - S[i][0] + (S[1][0] - S[0][0]))
            after.update(range(j + 1, min(j + 4, len(S))))
            i = j + 1
        else:
            i += 1
    for i in range(idx[0], min(idx[-1] + 4, len(S))):
        cat = CATS[0] if S[i][1] else (CATS[1] if i in after else CATS[2])
        for n, v in S[i][2].items():
            res[n][cat].append(v)

print(f"{len(sys.argv) - 1} traces; {len(spill_s)} spills, median {st.median(spill_s):.2f} s")
print("stage\t" + "\t".join(f"CPU% {c}" for c in CATS) + "\t" + "\t".join(f"off-CPU s/sample {c}" for c in CATS))
for n in ("name sort", "fixmate", "coord sort"):
    m = lambda c, i: st.mean(v[i] for v in res[n][c]) if res[n][c] else float("nan")
    print(n + "\t" + "\t".join(f"{m(c, 0):.0f}" for c in CATS) + "\t" + "\t".join(f"{m(c, 1):.3f}" for c in CATS))
