"""Per-variant summary of the 2x2 markdup ablation traces (denet JSONL)."""
import glob, json, statistics as st, sys
from collections import defaultdict

d = sys.argv[1] if len(sys.argv) > 1 else "."
res = defaultdict(list)
for f in sorted(glob.glob(f"{d}/*.r*.jsonl")):
    v = f.split("/")[-1].split(".r")[0]
    L = [json.loads(l) for l in open(f) if l.strip()]
    t0 = L[0]["t0_ms"]
    tr = [r for r in L if r["kind"] == "tree"]
    names = {r["pid"]: r["cmd"][1] if r["cmd"][0].endswith("samtools") else None
             for r in L if r["kind"] == "child"}
    wall = (tr[-1]["ts_ms"] - t0) / 1e3
    # CPU-seconds per stage: integrate cpu_usage (% of a core) over sample intervals
    cpu = defaultdict(float)
    for a, b in zip(tr, tr[1:]):
        dt = (b["ts_ms"] - a["ts_ms"]) / 1e3
        for c in b["children"]:
            n = names.get(c["pid"])
            if n:
                cpu[n] += c["metrics"]["cpu_usage"] / 100 * dt
    perf = tr[-1]["aggregated"].get("perf") or {}
    ipc = perf["instructions"] / perf["cycles"] if perf.get("cycles") else None
    sc = ((tr[-1]["aggregated"].get("ebpf") or {}).get("syscalls") or {}).get("total")
    peak = max(r["aggregated"]["mem_rss_kb"] for r in tr) / 1024
    res[v].append(dict(wall=wall, cpu=dict(cpu), ipc=ipc, instr=perf.get("instructions"),
                       syscalls=sc, peak=peak))

for v, runs in res.items():
    m = lambda k: st.mean(r[k] for r in runs if r[k] is not None)
    stages = sorted({s for r in runs for s in r["cpu"]})
    cpu = {s: st.mean(r["cpu"].get(s, 0) for r in runs) for s in stages}
    print(f"{v:16} n={len(runs)} wall {m('wall'):6.1f}s  peak {m('peak'):6.0f}MB  "
          f"IPC {m('ipc'):.2f}  instr {m('instr')/1e9:6.1f}G  syscalls {m('syscalls'):8.0f}  "
          f"CPU-s " + ", ".join(f"{s} {c:.0f}" for s, c in cpu.items()) + f"  (sum {sum(cpu.values()):.0f})")
