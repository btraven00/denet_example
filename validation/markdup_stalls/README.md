# Spills stall the pipe: testing the second half of the markdup diagnosis

The paper reads the original duplicate-marking trace as: while the coordinate
sort spills a full buffer to disk, it stops reading its input, so `fixmate`
and the name sort upstream block on the full pipe until it resumes. In the
paper's run their CPU drops from over 100% to under 10% during each of the
three spills. This controlled run tests that reading with a second,
independent signal: per-process off-CPU time from denet's eBPF probe.

`run.sh IN.bam OUT_DIR [REPEATS] [SORT_MEM]` runs the original pipeline
(`sort -n | fixmate | sort | markdup`, 2 threads per stage) under
`denet --enable-ebpf` with fixed 50 ms sampling; `analyse.py` splits the
streaming phase (first to last coordinate-sort spill) into samples during a
spill, the 3 samples (150 ms) just after one, and the rest.

## Result

2 M read pairs (the first third of the paper's `aligned_unsorted.bam`), sort
memory 256 MB per thread so that the coordinate sort spills at this size
(9 spills over 3 repeats, median 0.62 s each). samtools 1.20; denet 0.10.3
built with `gpu,ebpf`, run as root in a privileged container; laptop (Ryzen 9
PRO 7940HS, kernel 7.1).

| stage | CPU during spill | CPU just after | CPU other | off-CPU during spill | off-CPU just after | off-CPU other |
|---|---|---|---|---|---|---|
| name sort | **8%** | 118% | 116% | 0.22 s | **0.96 s** | 0.26 s |
| fixmate | **6%** | 123% | 126% | 0.35 s | 0.32 s | 0.22 s |
| coordinate sort | 211% | 14% | 16% | 0.11 s | 0.31 s | 0.30 s |

(off-CPU: seconds credited per 50 ms sample, summed over the stage's threads)

- **CPU.** During every spill the name sort and `fixmate` stop (8% and 6%)
  while the coordinate sort works on both threads (211%), and they resume at
  once afterwards: the stall is exactly as long as the spill.
- **Off-CPU.** denet's probe credits a wait when the thread wakes up, so time
  blocked through a whole spill appears just after it. The name sort's off-CPU
  credit jumps from 0.26 to 0.96 s per sample in the 150 ms after each spill:
  an excess of about (0.96 − 0.26) × 3 ≈ 2.1 s per spill, against 0.62 s of
  spill, so about three to four of its threads were blocked for the whole
  spill. `fixmate`'s off-CPU rises during the spills themselves (0.35 against
  0.22 s), consistent with its threads blocking and waking repeatedly on the
  full pipe.

The two signals agree: the upstream stages are not merely idle during a
spill, they are blocked, and they unblock when the coordinate sort resumes
reading. Which kernel wait they sleep in (a pipe write, rather than disk I/O)
is not in denet 0.10.3's output: the probe captures off-CPU stack IDs, but the
JSONL leaves them out, and it records waits at wake-up rather than in time.
Both are candidates for a later release.
