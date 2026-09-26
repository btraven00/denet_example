# The example workflow, with every benchmarked job measured by four instruments
# at once (see compare_timer.py). Run from the repository root:
#   snakemake -s validation/compare.smk --cores 16 --resources gt=1 \
#     --set-resources <rule>:gt=1 ... --config compare_out=validation_out/compare.tsv -- all
import os, sys
sys.path.insert(0, os.path.join(workflow.basedir, "..", "scripts"))
sys.path.insert(0, workflow.basedir)
import compare_timer

compare_timer.install(config["compare_out"], config["compare_out"] + ".denet")

include: os.path.join(workflow.basedir, "..", "Snakefile")
