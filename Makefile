SHELL      := bash
# driver env (envs/driver.yaml): snakemake plus the denet Python package, for native mode
SMK_ENV    ?= snakemake
CORES      ?= 16
# extra --config values for every run, e.g. a small-scale check:
#   make paper CONFIG="n_reads=200000 chr_length=1000000 benchmark_repeats=1 reps=1"
CONFIG     ?=
# How to reach conda, and the driver env. Override on hosts without
# ~/miniconda3 by putting the driver env's bin/ and a conda executable (needed
# by --use-conda) on PATH; $$ is make's escape for $:
#   make paper CONDA_RUN='export PATH=$$HOME/drv/bin:$$HOME/.pixi/bin:$$PATH'
CONDA_ACTIVATE ?= source ~/miniconda3/bin/activate
CONDA_RUN  ?= $(CONDA_ACTIVATE) && conda activate $(SMK_ENV)
SMK        := snakemake --cores $(CORES)
SMK_ENVS   := snakemake --use-conda --conda-frontend conda --cores 1
# Where `make figures` also drops a copy of the rendered report. Unset by
# default so a clean clone writes nothing outside the repository; set it to
# your paper checkout to get the copy:  make figures PAPER_DIR=~/src/paper
PAPER_DIR ?=

# Benchmarks run with the rule environment activated once, not per job.
# --use-conda activation runs a ~90 MB conda process for ~0.3 s at the start of
# every job; that dominates short rules' peak RSS, and psutil's ~1 s sampling
# only catches it by chance. Without --use-conda the rules' conda: directives
# are ignored and the tools come from PATH.
# looked up on first use, then kept (each lookup activates conda and runs snakemake)
TOOLS_ENV   = $(eval TOOLS_ENV := $$(shell $$(CONDA_RUN) && $$(SMK_ENVS) --list-conda-envs 2>/dev/null | awk -F'\t' '$$$$1=="envs/genome_tools.yaml"{print $$$$3}'))$(TOOLS_ENV)
# DENET_BIN_DIR: a directory whose denet is used instead of the conda package's,
# e.g. a cargo build with eBPF, which the slim conda package leaves out:
#   make paper DENET_BIN_DIR=$HOME/denet/target/release
DENET_BIN_DIR ?=
TOOLS_PATH  = $(if $(DENET_BIN_DIR),$(abspath $(DENET_BIN_DIR)):)$(CURDIR)/$(TOOLS_ENV)/bin
BENCH       = $(CONDA_RUN) && test -x "$(TOOLS_ENV)/bin/samtools" && PATH="$(TOOLS_PATH):$$PATH" $(SMK)

.PHONY: all paper driver-env conda-envs caps idle-power baseline denet denet-native markdup-variants check-outputs calib setup-r-env figures clean

all: paper figures

# every measurement in the paper, in one sequential run (about 5 h at CORES=16)
paper: idle-power baseline denet denet-native markdup-variants check-outputs calib

driver-env:
	$(CONDA_ACTIVATE) && \
	conda env create -n $(SMK_ENV) -f envs/driver.yaml 2>/dev/null || \
	conda env update -n $(SMK_ENV) -f envs/driver.yaml

conda-envs:
	$(CONDA_RUN) && \
	$(SMK_ENVS) --config use_denet=false outdir=results_baseline --conda-create-envs-only

# optional, once: lets wrap mode record CPU energy (RAPL, root-only counters),
# hardware counters and, in a build that has it, eBPF. Applies to the denet
# the runs will use (DENET_BIN_DIR's if set)
caps: conda-envs
	sudo setcap cap_bpf,cap_perfmon,cap_dac_read_search=ep $$(readlink -f $$(PATH="$(TOOLS_PATH):$$PATH" command -v denet))

# idle CPU package power, to subtract from the energy in wrap-mode traces; also
# records which denet every step uses: path, version, checksum, capabilities
idle-power: conda-envs
	mkdir -p results_idle
	export PATH="$(TOOLS_PATH):$$PATH"; b=$$(readlink -f $$(command -v denet)); \
	  { echo "$$b"; denet --version; sha256sum "$$b"; getcap "$$b" || true; } > results_idle/denet.txt
	PATH="$(TOOLS_PATH):$$PATH" denet -q -i 500 -m 500 -o results_idle/idle.jsonl run sleep 60

baseline: conda-envs
	$(BENCH) --config use_denet=false outdir=results_baseline $(CONFIG) --forceall

denet: conda-envs
	$(BENCH) --config use_denet=true outdir=results_denet $(CONFIG) --forceall

# needs the denet Python package next to snakemake (envs/driver.yaml has it)
denet-native: conda-envs
	$(BENCH) --config use_denet_native=true outdir=results_denet_native $(CONFIG) --forceall

# markdup only, wrap mode with phase logs, on the aligned BAM from results_denet;
# feeds Figure 1: the current pipeline (name sort), round 1 (collate -f) and
# round 2 (no grouping, uncompressed pipes); check-outputs compares their results
MARKDUP = "sort:markdup_group=sort" "collate_fast:markdup_group=collate_fast" \
          "round2:markdup_group=none markdup_uncompressed_pipes=true"
markdup-variants: conda-envs
	@test -d results_denet/results || { echo "markdup-variants needs results_denet: run 'make denet' first" >&2; exit 1; }
	for v in $(MARKDUP); do \
	  o=results_markdup_$${v%%:*} && rm -rf $$o && mkdir -p $$o && \
	  cp -al results_denet/data results_denet/results $$o/ && \
	  rm -f $$o/results/aligned.markdup.bam* $$o/results/digest_*.tsv && \
	  $(BENCH) --config use_denet=true $${v#*:} markdup_phase_log=true outdir=$$o $(CONFIG) \
	    --allowed-rules markdup digest_bam -- $$o/results/digest_bam.tsv || exit 1; \
	done
	echo "fixmate -u | sort -u | markdup" > results_markdup_round2/LABEL
	python3 scripts/aggregate_markdup.py results_markdup_sort results_markdup_collate_fast results_markdup_round2 > results_markdup_summary.txt

# monitoring must not change what the workflow computes, and the markdup rounds
# must agree on alignments and duplicate count: compare the output digests (rules digest_bam and
# digest_vcf) across every result directory; fails the run on any difference
RESULT_DIRS = results_baseline results_denet results_denet_native \
              results_markdup_sort results_markdup_collate_fast results_markdup_round2
check-outputs:
	python3 scripts/check_same_outputs.py $(wildcard $(RESULT_DIRS)) > results_same_outputs.txt; \
	  s=$$?; cat results_same_outputs.txt; exit $$s

# peak capture vs spike duration (Table S3): the randomised-phase ladder, a
# fixed-phase arm, and spikes after 15 s, in Snakemake's 30 s sampling regime
CALIB = $(CONDA_RUN) && PATH="$(TOOLS_PATH):$$PATH" snakemake -s validation/calib/Snakefile --cores 1 --nolock
calib: conda-envs
	rm -rf results_calib && mkdir -p results_calib
	$(CALIB) --config outdir=results_calib/ladder compare_out=results_calib/ladder.tsv $(CONFIG)
	$(CALIB) --config outdir=results_calib/fixed compare_out=results_calib/fixed.tsv pre=1.0,1.0 holds=0.05,0.1,0.25 $(CONFIG)
	$(CALIB) --config outdir=results_calib/long compare_out=results_calib/long.tsv pre=20,50 holds=5,15,60 $(CONFIG)
	for a in ladder fixed long; do \
	  python3 validation/calib/score.py results_calib/$$a.tsv --base-from results_calib/ladder.tsv > results_calib/$$a.scored.tsv; \
	done

setup-r-env:
	$(CONDA_ACTIVATE) && \
	conda env create -f envs/rstats.yaml 2>/dev/null || \
	conda env update --name rstats -f envs/rstats.yaml

figures: setup-r-env
	mkdir -p figures
	$(CONDA_ACTIVATE) && \
	conda run -n rstats Rscript -e \
	  "rmarkdown::render('analysis.Rmd', output_dir='figures')"
	@if [ -n "$(PAPER_DIR)" ]; then \
	  mkdir -p $(PAPER_DIR)/figures && \
	  cp figures/analysis.html $(PAPER_DIR)/figures/denet_benchmark.html && \
	  echo "copied report to $(PAPER_DIR)/figures/"; \
	else echo "PAPER_DIR unset; report left in figures/analysis.html"; fi

# results and figures only; the conda envs in .snakemake/ are kept (slow to
# rebuild, and a rebuilt denet loses its capabilities): rm -rf .snakemake for those
clean:
	rm -rf results_* figures __pycache__
