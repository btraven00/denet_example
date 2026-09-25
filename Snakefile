configfile: "config.yaml"

import os

_use_denet_raw = config.get("use_denet", False)
use_denet = _use_denet_raw if isinstance(_use_denet_raw, bool) else str(_use_denet_raw).lower() in ("true", "1", "yes")

_use_denet_native_raw = config.get("use_denet_native", False)
use_denet_native = _use_denet_native_raw if isinstance(_use_denet_native_raw, bool) else str(_use_denet_native_raw).lower() in ("true", "1", "yes")

if use_denet_native:
    shell.prefix("export PATH=\"" + os.path.expanduser("~/.cargo/bin") + ":$PATH\"; ")

outdir = config.get("outdir", "results")
n_reads = config.get("n_reads", 1_000_000)
n_chromosomes = config.get("n_chromosomes", 3)
chr_length = config.get("chr_length", 1_000_000)
bench_repeats = config.get("benchmark_repeats", 5)
dup_fraction = float(config.get("dup_fraction", 0.0))


def wrap(cmd, step):
    if use_denet:
        out = f"{outdir}/denet_metrics/{step}.jsonl"
        return "\n".join([
            f"mkdir -p {outdir}/denet_metrics",
            f"( {cmd} ) &",
            "_denet_pid=$!",
            f"denet -o {out} -i 50 -m 500 -q attach $_denet_pid || true",
            "wait $_denet_pid",
        ])
    return cmd


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
    threads: 2
    shell:
        wrap(
            """( samtools sort -n -@ {threads} {input.bam} \
                | samtools fixmate -m -@ {threads} - - \
                | samtools sort -@ {threads} - \
                | samtools markdup -@ {threads} - {output.bam} ) 2> {log}""",
            "markdup",
        )


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
