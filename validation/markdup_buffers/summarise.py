#!/usr/bin/env python3
"""Summarise run.sh: per memory setting, the tree's peak RSS, each sort's own
peak, and how long both sorts held at least 80% of their peaks at once."""
import glob, json, os, re, statistics as st, sys
from collections import defaultdict

res = defaultdict(list)
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.jsonl"))):
    m = re.search(r"n(\d+)M_c(\d+)M_r\d+", f)
    mn, mc = int(m.group(1)), int(m.group(2))
    recs = [json.loads(l) for l in open(f) if l.strip()]
    tree = [r for r in recs if r.get("kind") == "tree"]
    # the four samtools stages start in pipeline order, so by PID: name sort,
    # fixmate, coordinate sort, markdup
    pids = sorted({c["pid"] for r in tree for c in r["children"] if c.get("command") == "samtools"})
    kind = {pids[0]: "name", pids[2]: "coord"}
    ser = {"name": [], "coord": []}
    for r in tree:
        got = {"name": 0, "coord": 0}
        for c in r["children"]:
            k = kind.get(c["pid"])
            if k:
                got[k] += c["metrics"]["mem_rss_kb"] / 1024
        for k in ser:
            ser[k].append(got[k])
    pk = {k: max(v) for k, v in ser.items()}
    both = sum(1 for a, b in zip(ser["name"], ser["coord"]) if a >= 0.8 * pk["name"] and b >= 0.8 * pk["coord"])
    peak = max(r["aggregated"]["mem_rss_kb"] for r in tree) / 1024
    res[(mn, mc)].append((peak, pk["name"], pk["coord"], both))

print("limit_name_MB\tlimit_coord_MB\ttree_peak_MB\tname_sort_peak_MB\tcoord_sort_peak_MB\tsamples_both_near_peak")
for (mn, mc), rs in sorted(res.items()):
    m = lambda i: st.mean(r[i] for r in rs)
    print(f"{mn}\t{mc}\t{m(0):.0f}\t{m(1):.0f}\t{m(2):.0f}\t{m(3):.0f}")
