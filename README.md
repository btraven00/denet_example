Usage example for [denet](https://github.com/btraven00/denet) in bioinformatics.

Runs a simulated short-read alignment workflow with [Snakemake](https://snakemake.readthedocs.io) under two conditions and compares wall-clock time, peak RSS, and per-rule resource timeseries in an HTML report and a PDF figure.

The two conditions are:

- baseline: plain snakemake, no denet
- denet wrap: denet attaches to each rule's subprocess via a shell wrapper and writes a JSONL timeseries per step

## Requirements

- conda or mamba
- snakemake (conda-managed)

denet 0.9.0 comes with the rule environment (`envs/genome_tools.yaml`, locked
in `envs/genome_tools.linux-64.pin.txt`) from the
[almost-conductor](https://prefix.dev/channels/almost-conductor) channel;
`--use-conda` installs it, nothing to set up by hand.

## Configuration

Workflow parameters are set in `config.yaml`. By default the pipeline simulates
a 500 kb genome (5 chromosomes of 100 kb each) and 1 million paired-end reads
of 150 bp, with 3 benchmark repeats per rule. The output directory defaults to
`results/`. The `use_denet` flag selects the condition; it defaults to false (baseline run).

### Pipeline stages

simulate_genome, index_genome, simulate_reads, align (bowtie2, 4 threads),
sort_bam, index_bam, markdup (name-sort, fixmate, coord-sort, `samtools
markdup`), index_markdup, faidx_genome, call_variants (`bcftools mpileup |
bcftools call -mv`).

`dup_fraction` (0 to 1) injects synthetic PCR-like duplicates after wgsim so
markdup has real work to do; at 0, markdup only sees coordinate collisions from
oversampling.

### Paper-figure settings

The defaults in `config.yaml` are small for fast local iteration. The paper
figure uses larger inputs so the resource profiles have visible shape. Expect
roughly 10 minutes per condition on 4 cores;
`call_variants` (`bcftools mpileup` / `bcftools call`, both run with 2 threads)
and `align` dominate. `benchmark_repeats` multiplies every rule's wall time and
is the main knob if you are over budget.

```
snakemake --use-conda --cores 4 --forceall --config use_denet=false outdir=results_baseline n_chromosomes=2 chr_length=5000000 n_reads=1500000 dup_fraction=0.2
snakemake --use-conda --cores 4 --forceall --config use_denet=true outdir=results_denet n_chromosomes=2 chr_length=5000000 n_reads=1500000 dup_fraction=0.2
```

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
