#!/usr/bin/env python3
"""Is the denet/Snakemake disk-total disagreement last-sample truncation?

Reconstructs Snakemake's sampling grid (30 samples at 0.5 s, then every 30 s;
snakemake/benchmark.py) and reads denet's cumulative disk_write_bytes at the
last grid point that fires before the rule exits. If truncation is the cause,
that value should match what Snakemake reported.

Usage: python3 scripts/check_truncation.py [run_dir]
"""
import json, glob, sys, statistics as st

R = sys.argv[1] if len(sys.argv) > 1 else "results/omni_cf505fd"
SHORT_N, SHORT_I, LONG_I = 30, 0.5, 30.0

def grid(wall):
    ts, t = [], 0.0
    for _ in range(SHORT_N):
        ts.append(t); t += SHORT_I
    while t <= wall:
        ts.append(t); t += LONG_I
    return [x for x in ts if x <= wall]

print(f"{'round':13} {'wall':>6} {'last smpl':>10} {'tail':>6}  "
      f"{'denet tot':>10} {'predicted':>10} {'snkmk obs':>10} {'err':>7}")
for rnd in ("sort", "collate_fast", "round2"):
    d = f"{R}/results_markdup_{rnd}"
    io, wall = [], []
    for f in sorted(glob.glob(d + "/benchmarks/*.tsv")):
        for line in open(f).readlines()[1:]:
            c = line.split("\t")
            wall.append(float(c[0])); io.append(float(c[7]))
    if not io:
        print(f"{rnd:13} no benchmark TSVs"); continue
    obs_io, obs_wall = st.mean(io), st.mean(wall)
    preds, tots, ats = [], [], []
    for f in sorted(glob.glob(d + "/denet_metrics/*.jsonl")):
        pts = []
        for line in open(f):
            try: r = json.loads(line)
            except Exception: continue
            a = r.get("aggregated")
            if a and "disk_write_bytes" in a and "ts_ms" in r:
                pts.append((r["ts_ms"], a["disk_write_bytes"]))
        if not pts: continue
        t0 = pts[0][0]
        series = [((t - t0) / 1000.0, b / 1024**2) for t, b in pts]
        last = grid(series[-1][0])[-1]
        preds.append(max([b for t, b in series if t <= last] or [0.0]))
        tots.append(max(b for _, b in series)); ats.append(last)
    if not preds:
        print(f"{rnd:13} no denet trace"); continue
    pred, tot, last = st.mean(preds), st.mean(tots), st.mean(ats)
    print(f"{rnd:13} {obs_wall:6.0f} {last:10.1f} {obs_wall-last:6.1f}  "
          f"{tot:10.0f} {pred:10.0f} {obs_io:10.0f} "
          f"{(pred-obs_io)/max(obs_io,1)*100:+6.0f}%")
print("\nMiB. 'predicted' = denet's cumulative total at Snakemake's last sample.")
