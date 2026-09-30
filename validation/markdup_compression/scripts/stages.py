"""Per-variant, per-stage summary of the 2x2 markdup ablation (fixed denet)."""
import json, glob, sys, statistics as st
from collections import defaultdict
STAGES = ["collate", "fixmate", "sort", "markdup"]
res = defaultdict(list)
for f in sorted(glob.glob(sys.argv[1] + "/*.r*.jsonl")):
    v = f.split("/")[-1].split(".r")[0]
    L = [json.loads(l) for l in open(f) if l.strip()]
    t0 = L[0]["t0_ms"]
    name = {r["pid"]: r["cmd"][1] for r in L if r["kind"] == "child" and r["cmd"][0].endswith("samtools")}
    tr = [r for r in L if r["kind"] == "tree"]
    cpu, wr = defaultdict(float), defaultdict(int)
    for a, b in zip(tr, tr[1:]):
        dt = (b["ts_ms"] - a["ts_ms"]) / 1e3
        for c in b["children"]:
            n = name.get(c["pid"])
            if n:
                cpu[n] += c["metrics"]["cpu_usage"] / 100 * dt
                wr[n] = max(wr[n], c["metrics"].get("syscall_write_bytes", 0))
    e = tr[-1]["aggregated"].get("ebpf") or {}
    off = defaultdict(float)
    for k, s in ((e.get("offcpu") or {}).get("thread_stats") or {}).items():
        n = name.get(int(k.split(":")[0]))
        if n:
            off[n] += s["total_time_ns"] / 1e9
    sc = e.get("syscalls") or {}
    top = {x["name"]: x["count"] for x in sc.get("top_syscalls", [])}
    instr = sum((r["aggregated"].get("perf") or {}).get("instructions", 0) for r in tr)
    res[v].append(dict(wall=(tr[-1]["ts_ms"] - t0) / 1e3, cpu=cpu, off=off, wr=wr, instr=instr,
                       sc=sc.get("total", 0), rd=top.get("read", 0), wrc=top.get("write", 0)))
for v, R in res.items():
    m = lambda f: st.mean(f(r) for r in R)
    sd = lambda f: st.stdev([f(r) for r in R]) if len(R) > 1 else 0
    print(f"\n{v}  n={len(R)}  wall {m(lambda r:r['wall']):.1f}±{sd(lambda r:r['wall']):.1f}s  instr {m(lambda r:r['instr'])/1e9:.0f}G  "
          f"syscalls {m(lambda r:r['sc'])/1e3:.0f}k (read {m(lambda r:r['rd'])/1e3:.0f}k, write {m(lambda r:r['wrc'])/1e3:.0f}k)")
    for s in STAGES:
        if any(s in r["cpu"] for r in R):
            print(f"   {s:8} CPU {m(lambda r:r['cpu'].get(s,0)):5.1f}s  off-CPU {m(lambda r:r['off'].get(s,0)):6.1f}s  wrote {m(lambda r:r['wr'].get(s,0))/1e6:6.0f}MB")
