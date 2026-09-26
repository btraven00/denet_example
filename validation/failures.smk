# Check 4: failing, killed and run: jobs under benchmark; native or psutil.
import os, sys, time
sys.path.insert(0, os.path.join(workflow.basedir, "..", "scripts"))
OUT = config["outdir"]
if str(config.get("native", "false")).lower() == "true":
    import denet_native
    denet_native.install(f"{OUT}/denet_native")

rule fails:
    output: f"{OUT}/fails.out"
    benchmark: f"{OUT}/bench/fails.tsv"
    shell: "sleep 1; exit 3"

rule killed:
    output: f"{OUT}/killed.out"
    benchmark: f"{OUT}/bench/killed.tsv"
    shell: "sleep 1; kill -9 $$"

rule pyrun:
    output: f"{OUT}/pyrun.out"
    benchmark: f"{OUT}/bench/pyrun.tsv"
    run:
        x = bytearray(100 * 2**20)
        time.sleep(1.5)
        open(output[0], "w").write("ok\n")
