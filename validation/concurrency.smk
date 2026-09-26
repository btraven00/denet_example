# Check 3: many concurrent benchmarked jobs; native or psutil per config.
import os, sys
sys.path.insert(0, os.path.join(workflow.basedir, "..", "scripts"))
OUT = config["outdir"]
if str(config.get("native", "false")).lower() == "true":
    import denet_native
    denet_native.install(f"{OUT}/denet_native")
N = int(config.get("njobs", 200))

rule all:
    input: expand(f"{OUT}/c/{{i}}.out", i=range(N))

rule job:
    output: f"{OUT}/c/{{i}}.out"
    benchmark: f"{OUT}/bench/{{i}}.tsv"
    shell: "python3 -c 'x = bytearray(50 * 2**20); import time; time.sleep(1.5)'; dd if=/dev/zero of={output} bs=1M count=5 status=none"
