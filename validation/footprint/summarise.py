#!/usr/bin/env python3
"""Summarise validation/footprint/run.sh."""
import csv, glob, os, statistics as st, sys
out = sys.argv[1]
d = list(csv.DictReader(open(os.path.join(out, "direct.tsv")), delimiter="\t"))
print("denet's own peak RSS (VmHWM), 3 repeats:")
for c in ("plain", "ebpf", "gpu"):
    v = [int(r["vmhwm_kb"]) / 1024 for r in d if r["config"] == c]
    if not v:
        continue
    print(f"  {c:6} {st.mean(v):5.1f} MB (range {min(v):.1f}-{max(v):.1f})")
import json
env = next((json.loads(l) for l in open(os.path.join(out, "env.jsonl")) if '"kind":"env"' in l), {})
cpu = (env.get("lscpu") or {})
print(f"host {env.get('host')}, kernel {env.get('kernel')}, {cpu.get('model', '?')}, "
      f"affinity {env.get('affinity_inherited')}, "
      f"{open(os.path.join(out, 'denet_version.txt')).read().strip()}")
print("Snakemake benchmark max_rss of a 50 MiB job, 8 jobs:")
base = None
for v in ("bare", "uncapped", "capped"):
    rss = [float(next(csv.DictReader(open(f), delimiter="\t"))["max_rss"])
           for f in glob.glob(os.path.join(out, v, "bench", "*.tsv"))]
    m = st.mean(rss)
    base = m if v == "bare" else base
    extra = "" if v == "bare" else f"  ({m - base:+.1f} MB vs bare)"
    print(f"  {v:8} {m:6.1f} +/- {st.stdev(rss):.1f} MB{extra}")
