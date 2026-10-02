<!-- Moved out of README.md: operator detail for one specific host. -->

# Reproducing the paper's run

Every number in the paper comes from one `make paper`, run pinned to a single
NUMA node of a shared AMD EPYC 7742 server (4 NUMA nodes; node 3 is CPUs
48–63 and their SMT siblings 112–127):

```
# denet with eBPF: the conda package is built without it
git clone --branch v0.10.3 https://github.com/btraven00/denet.git ~/denet-0.10.3
(cd ~/denet-0.10.3 && cargo build --release --features gpu,ebpf --bin denet)

make driver-env conda-envs
make caps DENET_BIN_DIR=$HOME/denet-0.10.3/target/release   # needs sudo
NUMA_NODE=3 scripts/run_paper.sh DENET_BIN_DIR=$HOME/denet-0.10.3/target/release
```

On a host without `~/miniconda3`, set `CONDA_RUN` (see the top of the
Makefile) to put the driver env and a `conda` executable on `PATH` instead.

`DENET_BIN_DIR` puts that build ahead of the conda package's `denet` for
every step. Without it the conda package is used, which has no eBPF. `make
caps` grants `cap_bpf`, `cap_perfmon` and `cap_dac_read_search` to whichever
`denet` the runs will use: eBPF, hardware counters and the root-only RAPL
energy counters. Without capabilities those fields are left out and the
run still completes. `results_idle/denet.txt` records the binary each run
used: path, version, SHA-256 and capabilities.

`scripts/run_paper.sh` runs `make paper` under `numactl --cpunodebind=3
--membind=3`. It logs the load on that node's CPUs (`load_node.txt`) and on the
whole host (`load_host.txt`) every 10 s, and stamps `START` with the time,
load, node and commit at the start and the exit status at the end.
`numactl` sets the CPU affinity and memory policy of `make`. Every process it
starts inherits them, including Snakemake, each rule and denet, so the whole
run uses one node's cores, L3 caches and local memory. List your host's nodes
with `numactl --hardware`.

Pinning does not reserve those CPUs. Other users' processes can still be
scheduled on them. Keeping them off needs root, e.g. a cgroup cpuset:
`systemctl set-property --runtime user.slice AllowedCPUs=0-47,64-111`.
Without a reservation, the load logs let contention be reported rather than
assumed away.

**Archive.** The measurement outputs of that run are archived on Zenodo
(DOI: TO-BE-ASSIGNED):
- `results_*/benchmarks`, `denet_metrics`, `denet_native` and `logs`;
- `results_calib/`, `results_idle/` (incl. `denet.txt`) and `results_concurrency/`;
- `results_*/results/digest_*.tsv` and `results_same_outputs.txt`;
- `load_node.txt`, `load_host.txt`, `paper.log` and `START`;
- the outputs of the `validation/` experiments cited in the paper
  (`footprint/`, `markdup_buffers/`, `markdup_stalls/`, `markdup_compression/`).

Simulated reads and BAMs are not archived; `make paper` regenerates them.

## Activating the rule environment once

Benchmark runs activate the rule environment once instead of per job:
`--use-conda` starts every job by running a ~90 MB `conda` process for ~0.3 s,
which would dominate the peak memory of short rules. Build the environment,
put it on `PATH`, and run without `--use-conda` (the `conda:` directives are
then ignored). The Makefile targets do this for you.

```
snakemake --use-conda --conda-create-envs-only --cores 1
ENV=$(snakemake --use-conda --list-conda-envs --cores 1 | awk -F'\t' '$1=="envs/genome_tools.yaml"{print $3}')
PATH="$PWD/$ENV/bin:$PATH" snakemake --cores 4 --forceall --config use_denet=false outdir=results_baseline
PATH="$PWD/$ENV/bin:$PATH" snakemake --cores 4 --forceall --config use_denet=true outdir=results_denet
```
