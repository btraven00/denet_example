# Validation: how accurate are the benchmark numbers?

Snakemake's `benchmark:` directive samples each job with psutil. These scripts
measure how far those numbers, and denet's, are from ground truth, on the same
job executions. They justify the discrepancies between psutil and denet
reported in the paper.

All commands run from the repository root. Put the rule environment's tools on
`PATH` and run Snakemake without `--use-conda`, as the Makefile's benchmark
targets do (see the main README). The driver environment needs the denet
Python package (`pip install denet`) for native mode.

## What each script shows

| script | question | ground truth |
|---|---|---|
| `compare_timer.py`, `compare.smk` | Per job: CPU time, disk writes and peak RSS from psutil vs denet | kernel accounting of the job tree; a 10 ms reference sampler |
| `calib/` | Does a sampler catch a short memory spike? | a known 256 MiB held for a known time |
| `io_check.sh` | Are per-process disk writes right, including deleted temp files? | file sizes on disk, polled every 50 ms |
| `truncation/` | Are bytes written just before a process exits counted at all? | a known volume written after a known idle period |
| `concurrency.smk` | Does the sampler slow down Snakemake when many jobs run at once? | wall time with psutil vs denet native |
| `failures.smk` | Do failing, killed and `run:` jobs behave the same under denet native? | Snakemake's behaviour with psutil |

### `compare.smk`: four instruments on every job

Every benchmarked job is measured at once by Snakemake's psutil timer (which
fills the TSVs), denet's native sampler (`scripts/denet_native.py`), a psutil
loop at 10 ms, and kernel accounting: Snakemake's own `getrusage(RUSAGE_CHILDREN)`
and `/proc/self/io` `write_bytes` before and after the job. When a child exits
and is reaped, Linux adds its CPU and I/O counters to its parent's, so the
parent's counters after the job cover the whole tree. None of the instruments
is inside the job's process tree.

Jobs must run one at a time for the kernel deltas to be per-job, hence the
resource limit:

```
RULES="simulate_genome index_genome simulate_reads align sort_bam index_bam markdup index_markdup faidx_genome call_variants"
SR=$(for r in $RULES; do printf '%s:gt=1 ' "$r"; done)
snakemake -s validation/compare.smk --cores 16 --resources gt=1 --set-resources $SR \
  --config outdir=validation_out/wf compare_out=validation_out/compare.tsv benchmark_repeats=2 -- all
```

Output: one TSV row per job repeat (`compare.tsv`), and denet JSONLs in
`compare.tsv.denet/`. Add `markdup_group=collate` (or `collate_fast`) and
`--allowed-rules markdup` to compare the markdup variants on an existing BAM.

For CPU on multi-process rules, cross-check with GNU time on the same command,
for example `call_variants`:

```
/usr/bin/time -f "user %U s, sys %S s" bash -c \
  "bcftools mpileup --threads 2 -f genome.fa aligned.markdup.bam | bcftools call --threads 2 -mv -Oz -o out.vcf.gz"
```

### `calib/`: the spike ladder

`hold_memory.py MIB HOLD_S PRE_S` sleeps PRE_S (a random phase), holds MIB of
resident memory for HOLD_S, frees it and idles 0.5 s. The Snakefile runs it for
HOLD_S from 0.05 to 2 s, 8 phases each, under the four instruments above.

```
snakemake -s validation/calib/Snakefile --cores 4 \
  --config outdir=validation_out/ladder compare_out=validation_out/ladder.tsv reps=8
```

Score each instrument as `(peak - interpreter baseline) / 256 MiB`.

### `io_check.sh`: disk writes against the filesystem

samtools sort keeps its temporary spill files until the final merge, so the
largest size of each sort's temp directory is the bytes that sort wrote, even
though the files are deleted afterwards (`du` at the end cannot see them).

```
validation/io_check.sh results_denet/results/aligned_unsorted.bam 2
```

Compare with the per-process `disk_write_bytes` in denet's markdup JSONL. From
denet 0.10, `child` records give each process's full command line.

### `truncation/`: what the last sample misses

Both samplers read cumulative counters and stop when the process exits, so
whatever is written between the final sample and exit is never counted. These
scripts make the loss measurable by writing a known volume at a known time.

`late_writer.py` idles, then writes and exits immediately -- the case that
exposes the truncation. `write_bytes.py` writes a known volume with `fsync`.
`two_writers.py` runs two sequential writers that each exit before the next
begins. `slow_sampler.py` reimplements Snakemake's policy (reset the
accumulator, walk the tree, sum over processes alive at that instant) on its
real schedule, for comparison against denet at a short interval.

```
denet -o late.jsonl -i 50 -m 500 -q run \
  python3 validation/truncation/late_writer.py --idle-s 20 --mib 512 --path /tmp/x.bin
```

512 MiB written after an idle period, then immediate exit:

| idle before write | Snakemake's schedule | denet at 50 ms | truth |
|---|---|---|---|
| 5 s | 0 MB | 170 MB | 512 MB |
| 20 s | 0 MB | 126 MB | 512 MB |
| 40 s | 0 MB | 512 MB | 512 MB |

denet recovers 25-100% depending on where its last sample falls. **Both
samplers truncate; the faster one truncates less.** `two_writers.py` shows the
bytes are not lost to the child exiting: 374 + 542 MiB, each writer gone before
the next started, still totalled 916 MB in both, because a reaped child's I/O
accounting is folded into its parent.

### `concurrency.smk` and `failures.smk`

```
snakemake -s validation/concurrency.smk --cores 32 --config outdir=validation_out/c3 native=false njobs=200
snakemake -s validation/concurrency.smk --cores 32 --config outdir=validation_out/c3n native=true njobs=200
snakemake -s validation/failures.smk --cores 4 --config outdir=validation_out/c4 native=true -- validation_out/c4/fails.out
```

(`fails`, `killed` and `pyrun` are the three targets in `failures.smk`.)

## Results so far

30x, Snakemake 9.27, denet 0.9.1 with the fix released in 0.10.0.
jumpbox: 4 x Opteron 6376, idle. omni: EPYC 7742, shared, load ~30.

| | native (denet) | psutil (Snakemake) | ground truth |
|---|---|---|---|
| CPU, index_genome / markdup / call_variants | +2% / +3% / -1% | +2% / -2% / -3% | GNU time: 76.6 / 590 / 595 s |
| CPU, single-process rules | 0% | -1% to -21% | kernel accounting |
| disk writes, rules with real volume | 0% | -2% to -20% | kernel accounting |
| markdup writes per process | 374.6 / 551.9 / 514.4 MiB | (not per process) | temp dirs 374.2 / 551.5 MiB, output 515.9 MiB |
| spikes of 0.05-0.25 s, idle laptop | 86-100% caught, 8/8 | 25-35%, 2/8 | 256 MiB |
| spikes of 0.05-0.25 s, loaded omni | 80-100%, 7-8/8 | 18-34%, 2-3/8 | 256 MiB |
| spikes of 0.5 s, loaded omni | 100%, 8/8 | 40%, 3/8 | 256 MiB |
| 200 concurrent 1.6 s jobs, `--cores 32` | 19 s, peak RSS for 200/200 | 37-39 s, peak RSS for 0-5/200 | |

Why psutil falls short: Snakemake 9.27 samples each job every 0.5 s for the
first 30 samples (about 15 s), then every 30 s (`BENCHMARK_INTERVAL_SHORT`,
`BENCHMARK_INTERVAL` in `snakemake/benchmark.py`). Early spikes shorter than
0.5 s are caught only by chance, later ones shorter than 30 s likewise. CPU
time and I/O are taken from the last sample, so up to the final 30 s of a
job's work, and short-lived processes, are missed. It also reads each
process's full memory map (USS/PSS) on every sample, inside Snakemake's own
process, which is what slows the scheduler under many concurrent jobs.

## Caveats

- The CPU delta from `getrusage` inside Snakemake came out 1.3-2.5x too high on
  index_genome, markdup and call_variants although jobs ran strictly one at a
  time; the cause is not known. GNU time on the same commands agrees with both
  samplers, so it is the reference used for those rules.
- `write_bytes` is the counter denet reads, so agreement with kernel accounting
  shows that denet's sampling is complete, not that the counter is right;
  `io_check.sh` is the independent check.
- The 10 ms reference is a Python loop. On a loaded host it misses short spikes
  itself (9% at 0.05 s on omni); the ladder's truth is the known allocation, not
  the reference.
- Native mode relies on Snakemake internals (see `scripts/denet_native.py`) and
  has been tested with the local executor only.
