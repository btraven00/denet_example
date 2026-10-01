# denet's own footprint as Snakemake's benchmark sees it: each job holds 50 MiB
# for 3 s, either bare or wrapped in `denet run` (WRAP = path to a denet binary)
OUT = config["outdir"]
N = int(config.get("njobs", 8))
WRAP = config.get("wrap", "")
JOB = "python3 -c 'x = bytearray(50 * 2**20); import time; time.sleep(3)'"
CMD = f"{WRAP} -q -o {OUT}/denet_{{wildcards.i}}.jsonl run -- {JOB}" if WRAP else JOB

rule all:
    input: expand(f"{OUT}/j/{{i}}.out", i=range(N))

rule job:
    output: f"{OUT}/j/{{i}}.out"
    benchmark: f"{OUT}/bench/{{i}}.tsv"
    shell: CMD + " && touch {output}"
