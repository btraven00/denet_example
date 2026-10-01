# denet's own memory footprint

How much memory the `denet` process itself adds to a monitored job, and what
Snakemake's benchmark reports of it. `run.sh CAPPED_DENET OUT_DIR` measures
it two ways:

1. **directly**, as the denet process's peak RSS (`VmHWM` in
   `/proc/<pid>/status`) for a plain `denet run`, with `--enable-ebpf` (needs
   the capabilities) and, with `GPU=1`, with `--gpu` (needs NVML and a build with
   the gpu feature);
2. **as Snakemake sees it**: jobs that hold 50 MiB for 3 s, benchmarked bare,
   wrapped in an uncapped `denet run`, and wrapped in a capped one.

`OUT_DIR/env.jsonl` records the host (`denet --write-env`).

## Result (denet 0.10.3, 2026-10-01)

omni (AMD EPYC 7742, kernel 6.8, pinned to NUMA node 3), 3 repeats / 8 jobs:

| | denet's own peak RSS |
|---|---|
| plain `denet run` | 5.7 MB |
| `--enable-ebpf` | 22.2 MB |

| Snakemake `max_rss` of a 50 MiB job | MB |
|---|---|
| bare | 63.1 |
| wrapped, uncapped denet | 68.9 (+5.7) |
| wrapped, capped denet | 63.2 (+0.1) |

Laptop (Ryzen 9 PRO 7940HS, NVIDIA RTX 2000 Ada, kernel 7.1), 3 repeats:
plain 6.7 MB, `--gpu` 25.6 MB. Loading NVIDIA's NVML library adds about 19 MB.

- Wrapping adds denet's own footprint, about 6 MB, and nothing else.
- eBPF and GPU monitoring cost more (about +16 and +19 MB), which is why both
  are opt-in.
- **Capabilities hide denet from Snakemake's sampler.** A binary with file
  capabilities runs non-dumpable: its `/proc/<pid>/smaps` is root-only, psutil's
  `memory_full_info()` is denied, and Snakemake's benchmark skips the process.
  With a capped denet (`make caps`), wrap-mode `max_rss` is the command's alone,
  as in the paper's run; denet's own ~6 MB is measured here instead.
