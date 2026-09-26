"""Measure every benchmarked job with four instruments at once, all outside
the job's process tree: Snakemake's own psutil timer (fills the TSV), the
denet native sampler, a 10 ms psutil reference for peak tree RSS, and kernel
accounting (this process's RUSAGE_CHILDREN and /proc/self/io write_bytes
deltas across the job).

Caveats, from running it:
- Kernel deltas need jobs to run one at a time (a Snakemake resource, see
  README.md). Even then the CPU delta came out 1.3-2.5x too high on some
  multi-process rules (index_genome, markdup, call_variants), cause unknown;
  GNU time on the same command agreed with the samplers. Use GNU time as CPU
  ground truth for those rules.
- write_bytes is the counter denet itself reads, so agreement shows sampling
  completeness, not the counter's correctness; io_check.sh is the independent
  check.
- The 10 ms reference is a Python loop: on a loaded host it cannot keep its
  schedule and misses short spikes itself (see calib/)."""
import csv, os, resource, sys, threading, time
import psutil
import snakemake.benchmark as smk_benchmark
import denet_native

_orig_timer = smk_benchmark.BenchmarkTimer
_out = None
_lock = threading.Lock()


def _self_write_bytes():
    with open("/proc/self/io") as f:
        return next(int(l.split()[1]) for l in f if l.startswith("write_bytes"))


class _RefSampler(threading.Thread):
    def __init__(self, pid):
        super().__init__(daemon=True)
        self.proc = psutil.Process(pid)
        self.stop = threading.Event()
        self.peak = 0

    def run(self):
        while not self.stop.is_set():
            try:
                tot = 0
                for p in [self.proc] + self.proc.children(recursive=True):
                    try:
                        tot += p.memory_info().rss
                    except psutil.Error:
                        pass
                self.peak = max(self.peak, tot)
            except psutil.Error:
                break
            self.stop.wait(0.01)


class CompareTimer:
    def __init__(self, pid, bench_record, interval=smk_benchmark.BENCHMARK_INTERVAL):
        self.rule = denet_native._calling_rule()
        self.t0 = time.time()
        self.ru0 = resource.getrusage(resource.RUSAGE_CHILDREN)
        self.io0 = _self_write_bytes()
        self.psutil_rec = bench_record
        self.psutil = _orig_timer(pid, bench_record, interval)
        self.native_rec = smk_benchmark.BenchmarkRecord()
        self.native = denet_native.DenetBenchmarkTimer(pid, self.native_rec)
        self.ref = _RefSampler(pid)

    def start(self):
        self.psutil.start(); self.native.start(); self.ref.start()

    def cancel(self):
        self.psutil.cancel(); self.native.cancel(); self.ref.stop.set(); self.ref.join(2)
        ru1 = resource.getrusage(resource.RUSAGE_CHILDREN)
        gt_cpu = (ru1.ru_utime - self.ru0.ru_utime) + (ru1.ru_stime - self.ru0.ru_stime)
        gt_write = (_self_write_bytes() - self.io0) / 2**20
        p, n = self.psutil_rec, self.native_rec
        row = [self.rule, f"{time.time()-self.t0:.2f}",
               f"{gt_cpu:.2f}", f"{p.cpu_time or 0:.2f}", f"{n.cpu_time or 0:.2f}",
               f"{gt_write:.1f}", p.io_out, n.io_out,
               f"{self.ref.peak/2**20:.1f}", p.max_rss, n.max_rss]
        with _lock:
            new = not os.path.exists(_out)
            with open(_out, "a", newline="") as f:
                w = csv.writer(f, delimiter="\t")
                if new:
                    w.writerow(["rule", "wall_s", "cpu_kernel", "cpu_psutil", "cpu_native",
                                "write_kernel_MB", "write_psutil_MB", "write_native_MB",
                                "rss_ref10ms_MB", "rss_psutil_MB", "rss_native_MB"])
                w.writerow(row)


def install(out_tsv, native_outdir):
    global _out
    _out = out_tsv
    denet_native._outdir = native_outdir
    smk_benchmark.BenchmarkTimer = CompareTimer
