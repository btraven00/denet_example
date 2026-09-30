configfile: "config.yaml"

import os
import shlex
import shutil
import sys

_use_denet_raw = config.get("use_denet", False)
use_denet = _use_denet_raw if isinstance(_use_denet_raw, bool) else str(_use_denet_raw).lower() in ("true", "1", "yes")

outdir = config.get("outdir", "results")

_use_denet_native_raw = config.get("use_denet_native", False)
use_denet_native = _use_denet_native_raw if isinstance(_use_denet_native_raw, bool) else str(_use_denet_native_raw).lower() in ("true", "1", "yes")

if use_denet_native:
    # denet replaces Snakemake's psutil benchmark sampler; rules are unchanged
    sys.path.insert(0, f"{workflow.basedir}/scripts")
    import denet_native

    denet_native.install(f"{outdir}/denet_native")

n_reads = config.get("n_reads", 1_000_000)
n_chromosomes = config.get("n_chromosomes", 3)
chr_length = config.get("chr_length", 1_000_000)
bench_repeats = config.get("benchmark_repeats", 5)
dup_fraction = float(config.get("dup_fraction", 0.0))
# one seed for wgsim and the duplicate injection, so every condition and every
# run gets the same reads and the outputs can be compared (see rule digest_bam)
seed = int(config.get("seed", 11))


def wrap(cmd, step):
    if use_denet:
        # one JSONL per benchmark repeat: denet -o overwrites, and Snakemake doesn't
        # expose the repeat index, so a nanosecond timestamp orders the repeats
        out = f"{outdir}/denet_metrics/{step}.$(date +%s%N).jsonl"
        # denet runs the command itself (not attach): it samples from the first
        # instant, reaps the child so the final disk totals are exact, and exits
        # with the command's status, so a failing rule still fails
        return "\n".join([
            f"mkdir -p {outdir}/denet_metrics",
            f"denet -o {out} -i 50 -m 500 -q run -- bash -euo pipefail -c {shlex.quote(cmd)}",
        ])
    return cmd


onstart:
    # ponytail: wipes every step's traces, assumes whole-workflow runs (--forceall, as
    # in the Makefile and CI); scope it to the scheduled jobs if partial reruns matter
    if use_denet:
        shutil.rmtree(f"{outdir}/denet_metrics", ignore_errors=True)
    if use_denet_native:
        shutil.rmtree(f"{outdir}/denet_native", ignore_errors=True)
    if markdup_phase_log:
        for name in ("markdup", "align_markdup"):
            if os.path.exists(f"{outdir}/logs/{name}.phases.tsv"):
                os.remove(f"{outdir}/logs/{name}.phases.tsv")


_all_steps = [
    "simulate_genome",
    "index_genome",
    "simulate_reads",
    "align",
    "sort_bam",
    "index_bam",
    "markdup",
    "index_markdup",
    "faidx_genome",
    "call_variants",
]


# How markdup groups mates for fixmate. "sort" is a full name sort, which holds
# the whole input in memory while the downstream coordinate sort fills its own
# buffer. "collate" only brings mates together (temp files, small memory);
# "collate_fast" keeps a small in-memory window and needs one alignment per read.
# "none" skips grouping: the aligner's output is already grouped by read name
# (bowtie2 writes GO:query), which is all fixmate needs.
_markdup_group = {
    "sort": "samtools sort -n -@ {threads} {input.bam}",
    "collate": f"samtools collate -O -u -@ {{threads}} -T {outdir}/results/markdup_collate {{input.bam}}",
    "collate_fast": "samtools collate -O -u -f -@ {threads} {input.bam}",
    "none": None,
}[config.get("markdup_group", "sort")]

# coordinate sort inside markdup: threads (default: the rule's) and memory per
# thread (default: samtools' 768M); more of either shortens or avoids spills
_sort_threads = config.get("markdup_sort_threads", "{threads}")
_sort_mem = f" -m {config['markdup_sort_mem']}" if "markdup_sort_mem" in config else ""

def _flag(key):
    v = config.get(key, False)
    return v if isinstance(v, bool) else str(v).lower() in ("true", "1", "yes")


# markdup_uncompressed_pipes: pass uncompressed BAM between the pipe stages;
# otherwise each stage compresses what the next one immediately decompresses
_u = " -u" if _flag("markdup_uncompressed_pipes") else ""

_markdup_stages = [
    ("fixmate", f"samtools fixmate -m{_u} -@ {{threads}} {{input.bam}} -"),
    ("sort", f"samtools sort{_u} -@ {_sort_threads}{_sort_mem} -"),
    ("markdup", "samtools markdup -@ {threads} - {output.bam}"),
]
if _markdup_group:
    _markdup_stages[0] = ("fixmate", f"samtools fixmate -m{_u} -@ {{threads}} - -")
    _markdup_stages.insert(0, ("group", _markdup_group))

# markdup_phase_log: each pipe stage appends epoch-ms start/end lines and its
# timestamped stderr (e.g. samtools' spill-merge messages) to params.phases, so
# the phases can be aligned with denet's ts_ms. Off by default: it adds a bash
# function and a date call per stderr line to the measured rule.
markdup_phase_log = _flag("markdup_phase_log")


def _pipe_cmd(stages):
    if not markdup_phase_log:
        return "( " + " | ".join(c for _, c in stages) + " ) 2> {log}"
    return (
        "ph() {{ local n=$1 rc; shift; "
        "printf '%s\\tstart\\t%s\\n' \"$(date +%s%3N)\" \"$n\" >> {params.phases}; "
        "\"$@\" 2> >(while IFS= read -r l; do printf '%s\\t%s\\t%s\\n' \"$(date +%s%3N)\" \"$n\" \"$l\"; done >> {params.phases}) && rc=0 || rc=$?; "
        "printf '%s\\tend\\t%s\\n' \"$(date +%s%3N)\" \"$n\" >> {params.phases}; return $rc; }}; "
        + "( " + " | ".join(f"ph {n} {c}" for n, c in stages) + " ) 2> {log}"
    )


_markdup_cmd = _pipe_cmd(_markdup_stages)

# pipeline_design=fused: one rule from reads to the duplicate-marked BAM,
# bowtie2 | fixmate -u | sort -u | markdup. No aligned_unsorted.bam written and
# read back, no grouping step (bowtie2's output is already grouped by read
# name), and no second coordinate sort (sort_bam, index_bam).
fused = config.get("pipeline_design", "separate") == "fused"
_fused_stages = [
    ("align", "bowtie2 -x {params.idx_prefix} -1 {input.r1} -2 {input.r2} -p {threads}"),
    ("fixmate", "samtools fixmate -m -u -@ 2 - -"),
    ("sort", f"samtools sort -u -@ 2{_sort_mem} -"),
    ("markdup", "samtools markdup -@ 2 - {output.bam}"),
]
if fused:
    _all_steps = [s for s in _all_steps if s not in ("align", "sort_bam", "index_bam", "markdup")]
    _all_steps.insert(_all_steps.index("index_markdup"), "align_markdup")


rule all:
    input:
        [] if fused else f"{outdir}/results/aligned.bam.bai",
        f"{outdir}/results/variants.vcf.gz",
        f"{outdir}/results/digest_bam.tsv",
        f"{outdir}/results/digest_vcf.tsv",
        expand(
            "{outdir}/benchmarks/{step}.tsv",
            outdir=outdir,
            step=_all_steps,
        ),


rule simulate_genome:
    output:
        fa=f"{outdir}/data/genome.fa",
    log:
        f"{outdir}/logs/simulate_genome.log",
    benchmark:
        repeat(f"{outdir}/benchmarks/simulate_genome.tsv", bench_repeats)
    conda:
        "envs/genome_tools.yaml"
    params:
        n_chromosomes=n_chromosomes,
        chr_length=chr_length,
    shell:
        wrap(
            """python scripts/simulate_genome.py {output.fa} {params.n_chromosomes} {params.chr_length} 2> {log}""",
            "simulate_genome",
        )


rule index_genome:
    input:
        fa=f"{outdir}/data/genome.fa",
    output:
        multiext(
            f"{outdir}/data/genome",
            ".1.bt2",
            ".2.bt2",
            ".3.bt2",
            ".4.bt2",
            ".rev.1.bt2",
            ".rev.2.bt2",
        ),
    log:
        f"{outdir}/logs/index_genome.log",
    benchmark:
        repeat(f"{outdir}/benchmarks/index_genome.tsv", bench_repeats)
    conda:
        "envs/genome_tools.yaml"
    params:
        idx_prefix=f"{outdir}/data/genome",
    shell:
        wrap(
            """bowtie2-build {input.fa} {params.idx_prefix} > {log} 2>&1""",
            "index_genome",
        )


rule simulate_reads:
    input:
        fa=f"{outdir}/data/genome.fa",
    output:
        r1=f"{outdir}/data/reads_1.fq.gz",
        r2=f"{outdir}/data/reads_2.fq.gz",
    log:
        f"{outdir}/logs/simulate_reads.log",
    benchmark:
        repeat(f"{outdir}/benchmarks/simulate_reads.tsv", bench_repeats)
    conda:
        "envs/genome_tools.yaml"
    params:
        n_reads=n_reads,
        reads_prefix=f"{outdir}/data/reads",
        dup_fraction=dup_fraction,
        seed=seed,
    shell:
        wrap(
            """(
                wgsim -S {params.seed} -N {params.n_reads} -1 150 -2 150 -e 0.01 -r 0.001 \
                    {input.fa} {params.reads_prefix}_1.fq {params.reads_prefix}_2.fq &&
                gzip -f {params.reads_prefix}_1.fq {params.reads_prefix}_2.fq &&
                if awk 'BEGIN {{ exit !({params.dup_fraction} > 0) }}'; then
                    python scripts/inject_duplicates.py \
                        {output.r1} {output.r2} --fraction {params.dup_fraction} --seed {params.seed}
                fi
            ) > {log} 2>&1""",
            "simulate_reads",
        )


rule align:
    input:
        r1=f"{outdir}/data/reads_1.fq.gz",
        r2=f"{outdir}/data/reads_2.fq.gz",
        idx=multiext(
            f"{outdir}/data/genome",
            ".1.bt2",
            ".2.bt2",
            ".3.bt2",
            ".4.bt2",
            ".rev.1.bt2",
            ".rev.2.bt2",
        ),
    output:
        bam=f"{outdir}/results/aligned_unsorted.bam",
    log:
        f"{outdir}/logs/align.log",
    benchmark:
        repeat(f"{outdir}/benchmarks/align.tsv", bench_repeats)
    conda:
        "envs/genome_tools.yaml"
    threads: 4
    params:
        idx_prefix=f"{outdir}/data/genome",
    shell:
        wrap(
            """( bowtie2 -x {params.idx_prefix} \
                -1 {input.r1} -2 {input.r2} -p {threads} \
                | samtools view -bS -o {output.bam} ) 2> {log}""",
            "align",
        )


rule sort_bam:
    input:
        bam=f"{outdir}/results/aligned_unsorted.bam",
    output:
        bam=f"{outdir}/results/aligned.bam",
    log:
        f"{outdir}/logs/sort_bam.log",
    benchmark:
        repeat(f"{outdir}/benchmarks/sort_bam.tsv", bench_repeats)
    conda:
        "envs/genome_tools.yaml"
    shell:
        wrap(
            """samtools sort -o {output.bam} {input.bam} 2> {log}""",
            "sort_bam",
        )


rule index_bam:
    input:
        bam=f"{outdir}/results/aligned.bam",
    output:
        bai=f"{outdir}/results/aligned.bam.bai",
    log:
        f"{outdir}/logs/index_bam.log",
    benchmark:
        repeat(f"{outdir}/benchmarks/index_bam.tsv", bench_repeats)
    conda:
        "envs/genome_tools.yaml"
    shell:
        wrap(
            """samtools index {input.bam} 2> {log}""",
            "index_bam",
        )


rule markdup:
    input:
        bam=f"{outdir}/results/aligned_unsorted.bam",
    output:
        bam=f"{outdir}/results/aligned.markdup.bam",
    log:
        f"{outdir}/logs/markdup.log",
    benchmark:
        repeat(f"{outdir}/benchmarks/markdup.tsv", bench_repeats)
    conda:
        "envs/genome_tools.yaml"
    params:
        phases=f"{outdir}/logs/markdup.phases.tsv",
    threads: 2
    shell:
        wrap(_markdup_cmd, "markdup")


if fused:

    ruleorder: align_markdup > markdup

    rule align_markdup:
        input:
            r1=f"{outdir}/data/reads_1.fq.gz",
            r2=f"{outdir}/data/reads_2.fq.gz",
            idx=multiext(
                f"{outdir}/data/genome",
                ".1.bt2",
                ".2.bt2",
                ".3.bt2",
                ".4.bt2",
                ".rev.1.bt2",
                ".rev.2.bt2",
            ),
        output:
            bam=f"{outdir}/results/aligned.markdup.bam",
        log:
            f"{outdir}/logs/align_markdup.log",
        benchmark:
            repeat(f"{outdir}/benchmarks/align_markdup.tsv", bench_repeats)
        conda:
            "envs/genome_tools.yaml"
        threads: 4
        params:
            idx_prefix=f"{outdir}/data/genome",
            phases=f"{outdir}/logs/align_markdup.phases.tsv",
        shell:
            wrap(_pipe_cmd(_fused_stages), "align_markdup")


rule index_markdup:
    input:
        bam=f"{outdir}/results/aligned.markdup.bam",
    output:
        bai=f"{outdir}/results/aligned.markdup.bam.bai",
    log:
        f"{outdir}/logs/index_markdup.log",
    benchmark:
        repeat(f"{outdir}/benchmarks/index_markdup.tsv", bench_repeats)
    conda:
        "envs/genome_tools.yaml"
    shell:
        wrap(
            """samtools index {input.bam} 2> {log}""",
            "index_markdup",
        )


rule faidx_genome:
    input:
        fa=f"{outdir}/data/genome.fa",
    output:
        fai=f"{outdir}/data/genome.fa.fai",
    log:
        f"{outdir}/logs/faidx_genome.log",
    benchmark:
        repeat(f"{outdir}/benchmarks/faidx_genome.tsv", bench_repeats)
    conda:
        "envs/genome_tools.yaml"
    shell:
        wrap(
            """samtools faidx {input.fa} 2> {log}""",
            "faidx_genome",
        )


rule call_variants:
    input:
        bam=f"{outdir}/results/aligned.markdup.bam",
        bai=f"{outdir}/results/aligned.markdup.bam.bai",
        fa=f"{outdir}/data/genome.fa",
        fai=f"{outdir}/data/genome.fa.fai",
    output:
        vcf=f"{outdir}/results/variants.vcf.gz",
    log:
        f"{outdir}/logs/call_variants.log",
    benchmark:
        repeat(f"{outdir}/benchmarks/call_variants.tsv", bench_repeats)
    conda:
        "envs/genome_tools.yaml"
    threads: 2
    shell:
        wrap(
            """( bcftools mpileup --threads {threads} -f {input.fa} {input.bam} \
                | bcftools call --threads {threads} -mv -Oz -o {output.vcf} ) 2> {log}""",
            "call_variants",
        )


# Content digests of the outputs, not benchmarked. Monitoring must not change
# what the workflow computes, and the markdup rounds must flag the same reads;
# scripts/check_same_outputs.py compares these files across result directories.
# Alignments are compared as sorted records (bowtie2 -p writes reads in thread
# order), headers are left out (they carry command lines and dates), and the
# duplicate flag (1024) is masked: when copies in a duplicate set tie, markdup
# keeps one by input order, which a name-sorted and a collated input present
# differently. The number flagged must still match; which reads carry the flag
# is recorded as duplicate_reads, for information.
rule digest_bam:
    input:
        r1=f"{outdir}/data/reads_1.fq.gz",
        r2=f"{outdir}/data/reads_2.fq.gz",
        bam=f"{outdir}/results/aligned.markdup.bam",
    output:
        f"{outdir}/results/digest_bam.tsv",
    conda:
        "envs/genome_tools.yaml"
    shell:
        """
        d() {{ md5sum | cut -d' ' -f1; }}
        {{
          printf 'reads\t%s\n' "$(zcat {input.r1} {input.r2} | d)"
          printf 'alignments\t%s\n' "$(samtools view {input.bam} | awk 'BEGIN{{OFS="\t"}} {{$2 = and($2, compl(1024)); print}}' | cut -f1-11 | LC_ALL=C sort -S 1G | d)"
          printf 'duplicate_reads\t%s\n' "$(samtools view -f 1024 {input.bam} | cut -f1,2 | LC_ALL=C sort -S 1G | d)"
          printf 'n_duplicates\t%s\n' "$(samtools view -c -f 1024 {input.bam})"
        }} > {output}
        """


rule digest_vcf:
    input:
        vcf=f"{outdir}/results/variants.vcf.gz",
    output:
        f"{outdir}/results/digest_vcf.tsv",
    conda:
        "envs/genome_tools.yaml"
    shell:
        """
        printf 'variants\t%s\n' "$(bcftools view -H {input.vcf} | md5sum | cut -d' ' -f1)" > {output}
        """

