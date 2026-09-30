Usage example for [denet](https://github.com/btraven00/denet) in bioinformatics.

Runs a simulated short-read alignment workflow with [Snakemake](https://snakemake.readthedocs.io) under two conditions and compares wall-clock time, peak RSS, and per-rule resource timeseries in an HTML report and a PDF figure.

The two conditions are:

- baseline: plain snakemake, no denet
- denet wrap: each rule's command runs under `denet run`, which writes a JSONL timeseries per step

## Requirements

- conda or mamba
- snakemake (conda-managed)

denet 0.10.3 comes with the rule environment (`envs/genome_tools.yaml`, locked
in `envs/genome_tools.linux-64.pin.txt`) from the
[almost-conductor](https://prefix.dev/channels/almost-conductor) channel;
`--use-conda` installs it, nothing to set up by hand.

## Configuration

Workflow parameters are set in `config.yaml`, and its defaults are the paper's
settings: a 50 Mb genome (5 chromosomes of 10 Mb each), 5 million paired-end
reads of 150 bp (30x coverage), 20% injected duplicates (`dup_fraction: 0.2`),
and 3 benchmark repeats per rule. The output directory defaults to `results/`.
The `use_denet` flag selects the condition; it defaults to false (baseline run).

### Pipeline stages

simulate_genome, index_genome, simulate_reads, align (bowtie2, 4 threads),
sort_bam, index_bam, markdup (name-sort, fixmate, coord-sort, `samtools
markdup`), index_markdup, faidx_genome, call_variants (`bcftools mpileup |
bcftools call -mv`).

`dup_fraction` (0 to 1) injects synthetic PCR-like duplicates after wgsim so
markdup has real work to do; at 0, markdup only sees coordinate collisions from
oversampling.

### Same inputs, same outputs

`seed` (default 11) seeds both wgsim and the duplicate injection, so every
condition and every run gets identical reads. Two unbenchmarked rules,
`digest_bam` and `digest_vcf`, write content checksums of the outputs to
`results/digest_*.tsv`:
- the reads;
- the duplicate-marked alignments, as sorted records without headers, with
  the duplicate flag masked;
- the number of duplicates flagged;
- the variant records.

`make check-outputs` (part of `make paper`) compares them across baseline,
wrap, native and the three markdup rounds, and fails on any difference, so a
monitoring mode that changed the results could not pass unnoticed.

The one difference it tolerates, and reports, is which reads carry the
duplicate flag. When copies in a duplicate set tie, `samtools markdup` keeps
one by input order, and a name-sorted and a collated input present them
differently. The number flagged, the alignments and the variant calls still
match.

### Paper runs and quick runs

The defaults reproduce the paper and take roughly 1 to 2 hours per condition on
4 cores with 3 repeats (estimated from pilots on an AMD EPYC 7742 and an Opteron
6376). `align`, `simulate_reads` and `markdup` dominate. For a quick run, use
the CI scale, e.g. `--config n_reads=10000 n_chromosomes=2 chr_length=100000
benchmark_repeats=1`.

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

### Reproducing the paper's run

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
- `results_calib/` and `results_idle/` (incl. `denet.txt`);
- `results_*/results/digest_*.tsv` and `results_same_outputs.txt`;
- `load_node.txt`, `load_host.txt`, `paper.log` and `START`.

Simulated reads and BAMs are not archived; `make paper` regenerates them.

## Running locally

```
make baseline      # results in results_baseline/
make denet         # results in results_denet/
make figures       # renders analysis.Rmd to figures/analysis.html and figures/denet_benchmark.pdf
```

`make all` runs all three targets in sequence.

## Output

- `results_baseline/benchmarks/`: snakemake benchmark TSVs (wall time, peak RSS, CPU time, I/O)
- `results_denet/benchmarks/` and `results_denet/denet_metrics/`: benchmark TSVs and per-step JSONL timeseries
- `figures/analysis.html`: interactive HTML report
- `figures/denet_benchmark.pdf`: figure for the paper

## Validation

`validation/` holds the scripts that check the benchmark numbers against ground
truth: CPU and disk writes against kernel accounting and GNU time, per-process
writes against file sizes, short memory spikes against a known allocation, and
behaviour under many concurrent jobs. They explain why Snakemake's psutil-based
`benchmark:` numbers and denet's differ. See `validation/README.md`.

## CI/CD

The workflow in `.github/workflows/tests.yml` runs on every push to `master` and on pull requests. It has five jobs:

- `dry-run`: validates the Snakefile DAG without executing anything.
- `integration-baseline`: runs the baseline condition and uploads logs and benchmarks as artifacts.
- `integration-denet`: runs the denet wrap condition, and uploads logs, benchmarks, and denet metrics as artifacts.
- `render-report`: downloads artifacts from both integration jobs and
  renders the HTML report and PDF figure, uploaded as artifacts on success.

The two integration jobs run in parallel. CI uses reduced parameters (10k
reads, 2 chromosomes, 100 kb each, 3 benchmark repeats) to keep runtime short.
Rule conda environments, including denet, are cached between runs.

## License

GPLv3

## Contact

izaskun mallona work at gmail com
