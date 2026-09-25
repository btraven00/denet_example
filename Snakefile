configfile: "config.yaml"

import os
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


def wrap(cmd, step):
    if use_denet:
        # one JSONL per benchmark repeat: denet -o overwrites, and Snakemake doesn't
        # expose the repeat index, so a nanosecond timestamp orders the repeats
        out = f"{outdir}/denet_metrics/{step}.$(date +%s%N).jsonl"
        return "\n".join([
            f"mkdir -p {outdir}/denet_metrics",
            f"( {cmd} ) &",
            "_denet_pid=$!",
            f"denet -o {out} -i 50 -m 500 -q attach $_denet_pid || true",
            "wait $_denet_pid",
        ])
    return cmd


onstart:
    # ponytail: wipes every step's traces, assumes whole-workflow runs (--forceall, as
    # in the Makefile and CI); scope it to the scheduled jobs if partial reruns matter
    if use_denet:
        shutil.rmtree(f"{outdir}/denet_metrics", ignore_errors=True)
    if use_denet_native:
        shutil.rmtree(f"{outdir}/denet_native", ignore_errors=True)
    if markdup_phase_log and os.path.exists(f"{outdir}/logs/markdup.phases.tsv"):
        os.remove(f"{outdir}/logs/markdup.phases.tsv")


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
_markdup_group = {
    "sort": "samtools sort -n -@ {threads} {input.bam}",
    "collate": f"samtools collate -O -u -@ {{threads}} -T {outdir}/results/markdup_collate {{input.bam}}",
    "collate_fast": "samtools collate -O -u -f -@ {threads} {input.bam}",
}[config.get("markdup_group", "sort")]

_markdup_stages = [
    ("group", _markdup_group),
    ("fixmate", "samtools fixmate -m -@ {threads} - -"),
    ("sort", "samtools sort -@ {threads} -"),
    ("markdup", "samtools markdup -@ {threads} - {output.bam}"),
]

# markdup_phase_log: each pipe stage appends epoch-ms start/end lines and its
# timestamped stderr (e.g. samtools' spill-merge messages) to params.phases, so
# the phases can be aligned with denet's ts_ms. Off by default: it adds a bash
# function and a date call per stderr line to the measured rule.
_ph_raw = config.get("markdup_phase_log", False)
markdup_phase_log = _ph_raw if isinstance(_ph_raw, bool) else str(_ph_raw).lower() in ("true", "1", "yes")

if markdup_phase_log:
    _markdup_cmd = (
        "ph() {{ local n=$1 rc; shift; "
        "printf '%s\\tstart\\t%s\\n' \"$(date +%s%3N)\" \"$n\" >> {params.phases}; "
        "\"$@\" 2> >(while IFS= read -r l; do printf '%s\\t%s\\t%s\\n' \"$(date +%s%3N)\" \"$n\" \"$l\"; done >> {params.phases}) && rc=0 || rc=$?; "
        "printf '%s\\tend\\t%s\\n' \"$(date +%s%3N)\" \"$n\" >> {params.phases}; return $rc; }}; "
        + "( " + " | ".join(f"ph {n} {c}" for n, c in _markdup_stages) + " ) 2> {log}"
    )
else:
    _markdup_cmd = "( " + " | ".join(c for _, c in _markdup_stages) + " ) 2> {log}"


rule all:
    input:
        f"{outdir}/results/aligned.bam.bai",
        f"{outdir}/results/variants.vcf.gz",
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
    shell:
        wrap(
            """(
                wgsim -N {params.n_reads} -1 150 -2 150 -e 0.01 -r 0.001 \
                    {input.fa} {params.reads_prefix}_1.fq {params.reads_prefix}_2.fq &&
                gzip -f {params.reads_prefix}_1.fq {params.reads_prefix}_2.fq &&
                if awk 'BEGIN {{ exit !({params.dup_fraction} > 0) }}'; then
                    python scripts/inject_duplicates.py \
                        {output.r1} {output.r2} --fraction {params.dup_fraction}
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
