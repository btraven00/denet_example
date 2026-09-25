"""denet as Snakemake's benchmark sampler ("native" mode).

Snakemake's `benchmark:` directive samples each job's process tree with psutil
(snakemake.benchmark.BenchmarkTimer), and Snakemake has no plugin interface for
that sampler. install() swaps the timer class, so benchmark TSVs are filled from
denet samples with no change to the rules, and every job repeat also writes a
denet JSONL timeseries.

This relies on Snakemake internals, checked against 9.27: shell.py imports
snakemake.benchmark.benchmarked when a job runs, and benchmarked() looks up
BenchmarkTimer as a module global. denet has no USS/PSS, so those columns are
NA in native TSVs, which also marks them as denet-sampled.
"""

import json
import os
import sys
import threading
import time

import denet
import snakemake.benchmark as smk_benchmark

_outdir = None


class DenetBenchmarkTimer:
    """Drop-in for snakemake.benchmark.BenchmarkTimer (start/cancel)."""

    def __init__(self, pid, bench_record, interval=None):
        self.record = bench_record
        rule = bench_record.rule_name[0] or _calling_rule()
        os.makedirs(_outdir, exist_ok=True)
        self.monitor = denet.ProcessMonitor.from_pid(
            pid,
            50,
            500,
            since_process_start=True,
            output_file=f"{_outdir}/{rule}.{time.time_ns()}.jsonl",
            quiet=True,
            write_metadata=True,
        )
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._last = None
        self._cpu_pct_s = 0.0

    def start(self):
        self._thread.start()

    def cancel(self):
        self._stop.set()
        self._thread.join(timeout=5)

    def _loop(self):
        # sample_once() rather than run(): run() holds the GIL in denet <= 0.9.0
        interval = 0.05
        while not self._stop.is_set():
            sample = self.monitor.sample_once()
            if sample is None:
                break
            self._update(json.loads(sample))
            self._stop.wait(interval)
            interval = min(interval * 1.5, 0.5)

    def _update(self, sample):
        agg = sample.get("aggregated") or sample.get("parent")
        if not agg:
            return
        now = sample["ts_ms"] / 1000
        if self._last is not None:
            self._cpu_pct_s += agg["cpu_usage"] * (now - self._last)
        self._last = now
        r = self.record
        r.data_collected = True
        r.max_rss = max(r.max_rss or 0, agg["mem_rss_kb"] / 1024)
        r.max_vms = max(r.max_vms or 0, agg["mem_vms_kb"] / 1024)
        r.max_uss = r.max_pss = "NA"
        # Tree I/O is cumulative (exited children fold into their parent), so a
        # drop is a sampling race, e.g. a final sample of a process caught while
        # exiting reads zeros. Keep the maximum.
        r.io_in = max(r.io_in or 0, agg["disk_read_bytes"] / 2**20)
        r.io_out = max(r.io_out or 0, agg["disk_write_bytes"] / 2**20)
        # Snakemake: cpu_usage is percent-seconds (mean_load = cpu_usage / wall),
        # cpu_time is CPU seconds
        r.cpu_usage = self._cpu_pct_s
        r.cpu_time = self._cpu_pct_s / 100


def _calling_rule():
    # BenchmarkRecord() is created without a rule name for shell jobs; the local
    # executor has the rule a few frames up, as `rule` (9.27 release) or
    # `run_args.job_rule` (newer main).
    frame = sys._getframe()
    while frame:
        loc = frame.f_locals
        rule = loc.get("rule") or getattr(loc.get("run_args"), "job_rule", None)
        if isinstance(rule, str):
            return rule
        if getattr(rule, "name", None):
            return rule.name
        frame = frame.f_back
    return "job"


def install(outdir):
    global _outdir
    _outdir = outdir
    smk_benchmark.BenchmarkTimer = DenetBenchmarkTimer
