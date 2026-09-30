# Two sort buffers at once: testing the markdup diagnosis

The paper reads the original duplicate-marking rule's 3.3 GB peak as two sort
buffers held at the same time: the name sort's and the coordinate sort's. The
alternative reading, one stage filling and then draining, predicts something
different, so the two can be told apart by setting each sort's memory limit
(`samtools sort -m`, per thread) independently:

- two coexisting buffers: the rule's peak follows the **sum** of the limits;
- one accumulating stage: it follows their **maximum**.

`run.sh IN.bam OUT_DIR [REPEATS]` runs the original pipeline
(`sort -n | fixmate | sort | markdup`, 2 threads per stage) under denet for a
3 × 3 grid of limits; `summarise.py` reports the tree's peak, each sort's own
peak, and how many samples found both sorts at 80% of their peaks at once.

## Result

2 M read pairs (the first third of the paper's `aligned_unsorted.bam`),
samtools 1.20, denet 0.10.3, two repeats, laptop (Ryzen 9 PRO 7940HS). Limits
below the default (768 MB) so that both sorts fill their buffers at this size.

| name-sort limit (MB) | coord-sort limit (MB) | rule peak (MB) | name-sort peak (MB) | coord-sort peak (MB) | samples with both near peak |
|---|---|---|---|---|---|
| 128 | 128 | 616 | 310 | 309 | 14 |
| 128 | 256 | 901 | 310 | 586 | 12 |
| 128 | 512 | 1,413 | 310 | 1,126 | 8 |
| 256 | 128 | 895 | 588 | 309 | 15 |
| 256 | 256 | 1,180 | 588 | 586 | 15 |
| 256 | 512 | 1,692 | 588 | 1,126 | 8 |
| 512 | 128 | 1,435 | 1,154 | 309 | 15 |
| 512 | 256 | 1,720 | 1,154 | 586 | 14 |
| 512 | 512 | 2,232 | 1,154 | 1,126 | 8 |

- Each sort's own peak depends on its own limit only, at about 2.2 × the
  per-thread limit (two threads, plus overhead). The name sort peaks at 310 MB
  whatever the coordinate sort is allowed, and vice versa.
- The rule's peak is the sum of the two, plus up to about 100 MB (the other
  stages and the shell). 128/512 and 512/128 peak alike (1,413 and 1,435 MB),
  where a single accumulating stage would give about 1.1 GB for both.
- Both sorts sit near their peaks at the same time for several samples in
  every run.

So the peak is two buffers held at once, and limiting either sort's memory
addresses only its own share, which is why the paper removes the name sort
rather than limiting it.

Note: in `run` mode these traces carry no per-child command-line records, so
`summarise.py` identifies the sorts by PID order: the four samtools stages
start in pipeline order.
