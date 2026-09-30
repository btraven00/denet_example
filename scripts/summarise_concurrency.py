#!/usr/bin/env python3
"""Summarise `make concurrency`: sampler cost under many concurrent jobs.

    summarise_concurrency.py results_concurrency

For each sampler (psutil = Snakemake's own, native = denet), over the repeats:
the makespan of the whole Snakemake run, and how many jobs got a peak RSS in
their benchmark file (each job holds 50 MiB, so a job with none was missed)."""
import csv, glob, os, re, statistics as st, sys

d = sys.argv[1] if len(sys.argv) > 1 else "results_concurrency"
runs = {}
for run in sorted(glob.glob(os.path.join(d, "*.r*"))):
    if not os.path.isdir(run):
        continue
    mode = re.sub(r"\.r\d+$", "", os.path.basename(run))
    t0, t1 = map(float, open(os.path.join(run, "makespan")).read().split())
    rows = [next(csv.DictReader(open(f), delimiter="\t"))
            for f in glob.glob(os.path.join(run, "bench", "*.tsv"))]
    caught = sum(1 for r in rows if r["max_rss"] not in ("", "NA", "-") and float(r["max_rss"]) > 0)
    runs.setdefault(mode, []).append((t1 - t0, caught, len(rows)))

print("sampler\trepeats\tmakespan_s\tjobs_with_peak_rss")
for mode, rs in runs.items():
    span = [r[0] for r in rs]
    sd = st.stdev(span) if len(span) > 1 else 0.0
    caught = ", ".join(f"{c}/{n}" for _, c, n in rs)
    print(f"{mode}\t{len(rs)}\t{st.mean(span):.1f} +/- {sd:.1f}\t{caught}")
