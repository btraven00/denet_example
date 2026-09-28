#!/usr/bin/env python3
"""Aggregate the markdup optimization rounds across benchmark repeats.

Reports mean +/- SD for each round, from two independent sources:
  - Snakemake's benchmark TSV  (wall time, peak RSS, disk out)
  - denet's per-repeat JSONL   (peak tree RSS, cumulative disk write, span)

Usage: aggregate_markdup.py results_markdup_<v> [results_markdup_<v> ...]
"""
import argparse, glob, json, os, re, statistics as st

def load_tsv(d):
    f = os.path.join(d, "benchmarks", "markdup.tsv")
    if not os.path.exists(f): return []
    rows = []
    with open(f) as fh:
        hdr = fh.readline().rstrip("\n").split("\t")
        for line in fh:
            v = line.rstrip("\n").split("\t")
            if len(v) != len(hdr): continue
            r = dict(zip(hdr, v))
            rows.append(dict(wall_s=float(r["s"]), rss_mb=float(r["max_rss"]),
                             io_out_mb=float(r["io_out"]), cpu_s=float(r["cpu_time"])))
    return rows

def load_denet(d):
    out = []
    for f in sorted(glob.glob(os.path.join(d, "denet_metrics", "*.jsonl"))):
        peak = 0.0; dw = 0.0; t0 = t1 = None
        for line in open(f):
            line = line.strip()
            if not line: continue
            o = json.loads(line)
            if o.get("kind") != "tree": continue
            a = o["aggregated"]
            peak = max(peak, a["mem_rss_kb"] / 1024)
            dw = max(dw, a["disk_write_bytes"] / 1024**2)
            t0 = a["ts_ms"] if t0 is None else t0
            t1 = a["ts_ms"]
        if peak:
            out.append(dict(rss_mb=peak, disk_write_mb=dw, span_s=(t1 - t0) / 1000))
    return out

def ms(vals):
    if not vals: return "-"
    if len(vals) == 1: return f"{vals[0]:.0f} (n=1)"
    return f"{st.mean(vals):.0f} +/- {st.stdev(vals):.0f}"

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("dirs", nargs="+"); a = ap.parse_args()
    print(f"{'round':26} {'n':>3} {'wall s':>16} {'peak RSS MB':>16} {'disk out MB':>16} {'CPU s':>16}")
    for d in a.dirs:
        t, dn = load_tsv(d), load_denet(d)
        name = re.sub(r"^results_markdup_", "", os.path.basename(d.rstrip("/")))
        print(f"{name:26} {len(t):>3} {ms([x['wall_s'] for x in t]):>16} "
              f"{ms([x['rss_mb'] for x in t]):>16} {ms([x['io_out_mb'] for x in t]):>16} "
              f"{ms([x['cpu_s'] for x in t]):>16}")
        if dn:
            print(f"{'  (denet per-repeat)':26} {len(dn):>3} {ms([x['span_s'] for x in dn]):>16} "
                  f"{ms([x['rss_mb'] for x in dn]):>16} {ms([x['disk_write_mb'] for x in dn]):>16}")
