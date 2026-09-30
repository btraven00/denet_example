# Compressed pipes in duplicate marking: what each instrument shows

Supporting material for round 2 of the paper's case study. The denet traces
(3 repeats of 4 variants, plus the same runs with denet 0.10.2) are in the
Zenodo archive with the paper's run; the flame graphs, their folded stacks and
the scripts are here. The paper
says `fixmate` "ran at 130–280% CPU for light
work: most of it compressed data that the next stage decompressed at once",
and that passing uncompressed records (`-u`) and dropping the grouping step
halved the rule's wall time. That reading came from the per-process CPU trace.
Here it is tested directly, and the same run is read with three instruments:
denet's per-process records, hardware counters, and a `perf` flame graph.

## Setup

- **Input:** the first 2 M read pairs of the paper's `aligned_unsorted.bam`
  (omni run `856c0e9`), 291 MB; mates adjacent, as bowtie2 writes them.
- **Tools:** samtools 1.20, 2 threads per stage, as in the paper.
- **Host:** laptop, AMD Ryzen 9 PRO 7940HS (16 threads), 64 GB, kernel 7.1.5.
  Runs are sequential.
- **Profiler:** denet built from PR #63, released as 0.10.3, `-i 50 -m 500 --enable-ebpf`. It ran as root in a
  `--privileged --pid=host` container, the equivalent of `make caps`.
- **Design:** 2 × 2. Grouping step (`collate -f`, or none) × pipes
  (compressed BGZF, or `-u`). Three repeats of each.
  `scripts/run.sh` runs it; `scripts/stages.py` summarises it.

| variant | pipeline |
|---|---|
| A (round 1) | `collate -f` → `fixmate` → `sort` → `markdup`, compressed pipes |
| B | as A, with `-u` on fixmate and sort |
| C | no grouping: `fixmate` → `sort` → `markdup`, compressed |
| D (round 2) | no grouping, `-u` |

Duplicate calls are identical in every run (668,534 reads flagged).

## Results

### Wall time and CPU (denet, per process)

| variant | wall (s) | fixmate CPU (s) | sort CPU (s) | markdup CPU (s) |
|---|---|---|---|---|
| A | 17.0 ± 0.4 | 11.6 | 17.4 | 11.6 |
| B | 10.7 ± 1.1 | 3.4 | 11.0 | 13.2 |
| C | 16.0 ± 0.6 | 10.4 | 17.3 | 11.6 |
| D | 8.5 ± 0.2 | 3.4 | 9.3 | 12.1 |

- **`-u` does almost all of round 2's work.**
  - On its own it cuts wall time by 37% (A → B).
  - Together with dropping the grouping step it cuts 50% (A → D).
  - Dropping the grouping step on its own gains 6% (A → C).
  - An earlier two-repeat run suggested that C was *slower* than A. That did
    not replicate, so there is no interaction.
- **`fixmate`'s CPU falls from 11.6 to 3.4 s (−71%)** once it stops
  compressing, and `sort`'s from 17.4 to 11.0 s. `markdup` is unchanged: it
  still writes the final, compressed BAM.

### Bytes through the pipes (denet, `/proc/<pid>/io`)

| variant | fixmate writes | sort writes | markdup writes |
|---|---|---|---|
| A | 309 MB | 367 MB | 178 MB |
| B | 1,468 MB | 1,627 MB | 174 MB |
| D | 1,405 MB | 1,655 MB | 177 MB |

- In A, `fixmate` reads 1,380 MB of uncompressed records from `collate` and
  writes 309 MB, a 4.5× compression. The 309 MB go through an in-memory pipe
  to `sort`, which decompresses them at once.
- The bytes saved cost CPU and buy nothing, because a pipe is not a disk.
  `sort`'s own writes also include its temporary spill files, which stay
  compressed in every variant.

### Hardware counters (denet `perf` fields, summed over the run)

| variant | instructions |
|---|---|
| A | 334 G |
| B | 166 G |
| C | 328 G |
| D | 160 G |

Compressed pipes double the instructions the pipeline executes, whichever
grouping step is used.

### Off-CPU time (denet eBPF, per process; needs 0.10.3)

| variant | sort off-CPU (s) | markdup off-CPU (s) |
|---|---|---|
| A | 57.9 | 33.6 |
| B | 32.7 | 10.4 |
| C | 56.2 | 32.8 |
| D | 29.7 | 7.4 |

With uncompressed pipes, the downstream stages spend much less time blocked:
markdup's off-CPU time drops from 33.6 to 10.4 s, consistent with it no longer
waiting on a CPU-bound upstream. Caveat: these are sums over **all threads** of
a process, including idle htslib pool workers, so the absolute values exceed
wall time. Compare them between variants, not with wall time. `collate` is
omitted for that reason: 491 s summed over its many threads.

### Flame graphs (`perf record -g`, user + kernel stacks; `perf/`)

- **Round 1 (A):** 69% of all samtools cycles are inside libdeflate's
  compressor, mostly `deflate_compress_lazy`, and 7% inside the decompressor.
- **B and D:** about 50% compress and 6% decompress. What remains is markdup
  writing the final BAM and sort compressing its spills.
- Open `perf/flame.*.svg` in a browser to explore them interactively.

What the flame graph *cannot* say is which stage spends those cycles.
- Every process is named `samtools`.
- The conda build has no frame pointers, so `perf -g` unwinds no further than
  the leaf: the stacks read `samtools;deflate_compress_lazy`, with nothing
  that identifies fixmate, sort or markdup. The compression also runs in
  htslib's worker threads, which would carry no stage identity even with full
  stacks.
- Attributing the cycles needs PIDs mapped back to the pipeline by hand
  (`perf script -F pid,...`), or `--call-graph dwarf` for deeper stacks, at a
  much larger recording cost.

The flame graph also has nothing to say about memory or I/O over time.

## Reading across instruments

| question | denet (per process) | perf flame graph |
|---|---|---|
| Which stage costs what? | yes, directly (CPU, memory, I/O per child) | no: every process is `samtools`, and stacks are leaf-only without frame pointers |
| What is the CPU doing? | indirectly (CPU vs bytes moved, instructions) | yes, per function: `deflate_compress_lazy` |
| Who waits on whom? | off-CPU per process (eBPF, denet >= 0.10.3) | no (on-CPU only; an off-CPU flame graph needs bcc/BTF) |
| Memory and I/O over time | yes | no |
| Needs root and symbols | eBPF parts only | kernel stacks yes; symbols for readable frames |

The two are complementary. denet located the problem, in the stage and
resource: fixmate burning CPU while moving little work. The flame graph
confirms the mechanism at function level. The 2×2 ablation is the causal
test, and it supports the manuscript's round-2 reading, with one refinement:
the uncompressed pipes, not dropping the grouping step, account for most of
the gain.

## Caveats

- One host, sequential runs, 2 M pairs (a third of the paper's input); three
  repeats per variant.
- The eBPF off-CPU and syscall numbers need denet 0.10.3 (PR #63). With
  0.10.2 they cover only the parent shell (those traces are in the archive for
  comparison).
- The syscall counts (eBPF) rise with `-u` (943 k in A vs 1,175 k in B),
  because moving more bytes takes more `read`/`write` calls. They are
  consistent with the above but weaker evidence than bytes, CPU and
  instructions.
- `perf` is 6.8.12 from Ubuntu's `linux-tools-generic`, run in the container
  against the host kernel 7.1.5. `inferno` produced the flame graphs.

## Possible manuscript refinement

In round 2, "Passing uncompressed records between stages (`-u`), and dropping
the grouping step … cut wall time to 42 s" could credit `-u` with most of the
effect. That would need the same ablation at full scale in the 0.10.3 re-run,
so it is not proposed yet.
