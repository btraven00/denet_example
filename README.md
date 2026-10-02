Usage example for [denet](https://github.com/btraven00/denet) in bioinformatics.

Runs a simulated short-read alignment workflow with
[Snakemake](https://snakemake.readthedocs.io) under several conditions and
compares wall-clock time, peak RSS, and per-rule resource timeseries in an HTML
report and a PDF figure.

The conditions are:

- baseline: plain snakemake, no denet
- denet wrap: each rule's command runs under `denet run`, which writes a JSONL timeseries per step
- denet native: denet's Python API replaces the sampler behind Snakemake's `benchmark:` directive (`scripts/denet_native.py`)
- markdup variants: the duplicate-marking rule as originally written and after each of the two remediation rounds

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

Benchmark runs put the rule environment on `PATH` and skip `--use-conda`,
because starting every job with a ~90 MB `conda` process would dominate the peak
memory of short rules. The Makefile targets do this for you.

### Reproducing the paper's run

Every number in the paper comes from one `make paper`, pinned to a single NUMA
node of a shared AMD EPYC 7742, with an eBPF-enabled `denet` build and the
capabilities it needs. The full recipe, the pinning caveats and the Zenodo
archive contents are in [docs/reproducing-the-paper.md](docs/reproducing-the-paper.md).

## Running locally

```
make baseline      # results in results_baseline/
make denet         # results in results_denet/
make figures       # renders analysis.Rmd to figures/analysis.html and figures/denet_benchmark.pdf
```

`make all` runs `make paper` and then `make figures`.

## Output

- `results_baseline/benchmarks/`: snakemake benchmark TSVs (wall time, peak RSS, CPU time, I/O)
- `results_denet/benchmarks/` and `results_denet/denet_metrics/`: benchmark TSVs and per-step JSONL timeseries
- `figures/analysis.html`: interactive HTML report
- `figures/denet_benchmark.pdf`: figure for the paper

## Reading the output

Each wrap-mode step writes one JSONL file to `results_denet/denet_metrics/`,
one record per sample, plus `child` records naming each process in the tree
(see [denet's data format](https://github.com/btraven00/denet/blob/main/docs/data-format.md)).
To see what the aggregate benchmark hides, compare the two for `markdup`:

```
# what Snakemake reports: one peak for the whole rule
cut -f1,3,8 results_denet/benchmarks/markdup.tsv

# what denet records: resident memory per process over time
jq -r 'select(.children) | [.ts_ms, (.children[] | "\(.command):\(.mem_rss_kb/1024|floor)")] | @tsv' \
  results_denet/denet_metrics/markdup.jsonl | head -40
```

The rule's 3.3 GB peak is not one stage accumulating: the name sort and the
coordinate sort each fill a buffer and hold it at the same time, and the drop
is the name sort exiting. `figures/analysis.html` plots this per process, and
`validation/markdup_buffers/` measures it directly.

## Validation

`validation/` holds the scripts that check the benchmark numbers against ground
truth: CPU and disk writes against kernel accounting and GNU time, per-process
writes against file sizes, short memory spikes against a known allocation, and
behaviour under many concurrent jobs. They explain why Snakemake's psutil-based
`benchmark:` numbers and denet's differ. See `validation/README.md`.

## CI/CD

`.github/workflows/tests.yml` runs on every push and pull request: a DAG
dry-run, the baseline and denet-wrap conditions in parallel, and a report
render from both. CI uses reduced parameters (10k reads, 2 chromosomes of
100 kb, 3 repeats); rule conda environments are cached.

## License

GPLv3

## Contact

ben.uzh at proton.me

izaskun mallona work at gmail com
