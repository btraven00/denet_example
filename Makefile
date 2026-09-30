SHELL      := bash
# driver env (envs/driver.yaml): snakemake plus the denet Python package, for native mode
SMK_ENV    ?= snakemake
CORES      ?= 16
# extra --config values for every run, e.g. a small-scale check:
#   make paper CONFIG="n_reads=200000 chr_length=1000000 benchmark_repeats=1 reps=1"
CONFIG     ?=
CONDA_RUN  := source ~/miniconda3/bin/activate && conda activate $(SMK_ENV)
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
TOOLS_ENV   = $(shell $(CONDA_RUN) && $(SMK_ENVS) --list-conda-envs 2>/dev/null | awk -F'\t' '$$1=="envs/genome_tools.yaml"{print $$3}')
BENCH       = $(CONDA_RUN) && test -x "$(TOOLS_ENV)/bin/samtools" && PATH="$(CURDIR)/$(TOOLS_ENV)/bin:$$PATH" $(SMK)

.PHONY: all paper driver-env conda-envs caps idle-power baseline denet denet-native markdup-variants calib setup-r-env figures clean

all: paper figures

# every measurement in the paper, in one sequential run (about 5 h on an 8-core laptop)
paper: idle-power baseline denet denet-native markdup-variants calib

driver-env:
	source ~/miniconda3/bin/activate && \
	conda env create -n $(SMK_ENV) -f envs/driver.yaml 2>/dev/null || \
	conda env update -n $(SMK_ENV) -f envs/driver.yaml

conda-envs:
	$(CONDA_RUN) && \
	$(SMK_ENVS) --config use_denet=false outdir=results_baseline --conda-create-envs-only

# optional, once: lets wrap mode record CPU energy (RAPL), whose counters are root-only
caps: conda-envs
	sudo setcap cap_bpf,cap_perfmon,cap_dac_read_search=ep $$(readlink -f $(TOOLS_ENV)/bin/denet)

# idle CPU package power, to subtract from the energy in wrap-mode traces
idle-power: conda-envs
	mkdir -p results_idle && PATH="$(CURDIR)/$(TOOLS_ENV)/bin:$$PATH" denet -q -i 500 -m 500 -o results_idle/idle.jsonl run sleep 60

baseline: conda-envs
	$(BENCH) --config use_denet=false outdir=results_baseline $(CONFIG) --forceall

denet: conda-envs
	$(BENCH) --config use_denet=true outdir=results_denet $(CONFIG) --forceall

# needs the denet Python package next to snakemake: pip install denet
denet-native: conda-envs
	$(BENCH) --config use_denet_native=true outdir=results_denet_native $(CONFIG) --forceall

# markdup only, wrap mode with phase logs, on the aligned BAM from results_denet;
# feeds Figure 1: the current pipeline (name sort), round 1 (collate -f) and
# round 2 (no grouping, uncompressed pipes); duplicate counts must agree
MARKDUP = "sort:markdup_group=sort" "collate_fast:markdup_group=collate_fast" \
          "round2:markdup_group=none markdup_uncompressed_pipes=true"
markdup-variants: conda-envs
	for v in $(MARKDUP); do \
	  o=results_markdup_$${v%%:*} && rm -rf $$o && mkdir -p $$o && \
	  cp -al results_denet/data results_denet/results $$o/ && \
	  rm -f $$o/results/aligned.markdup.bam* && \
	  $(BENCH) --config use_denet=true $${v#*:} markdup_phase_log=true outdir=$$o $(CONFIG) \
	    --allowed-rules markdup -- $$o/results/aligned.markdup.bam || exit 1; \
	  $(TOOLS_ENV)/bin/samtools flagstat $$o/results/aligned.markdup.bam | grep -m1 'duplicates$$' | cut -d' ' -f1 > $$o/duplicates.txt; \
	done
	echo "fixmate -u | sort -u | markdup" > results_markdup_round2/LABEL
	python3 scripts/aggregate_markdup.py results_markdup_sort results_markdup_collate_fast results_markdup_round2 > results_markdup_summary.txt

# peak capture vs spike duration (Table S3): the randomised-phase ladder, a
# fixed-phase arm, and spikes after 15 s, in Snakemake's 30 s sampling regime
CALIB = $(CONDA_RUN) && PATH="$(CURDIR)/$(TOOLS_ENV)/bin:$$PATH" snakemake -s validation/calib/Snakefile --cores 1 --nolock
calib: conda-envs
	rm -rf results_calib && mkdir -p results_calib
	$(CALIB) --config outdir=results_calib/ladder compare_out=results_calib/ladder.tsv $(CONFIG)
	$(CALIB) --config outdir=results_calib/fixed compare_out=results_calib/fixed.tsv pre=1.0,1.0 holds=0.05,0.1,0.25 $(CONFIG)
	$(CALIB) --config outdir=results_calib/long compare_out=results_calib/long.tsv pre=20,50 holds=5,15,60 $(CONFIG)
	for a in ladder fixed long; do \
	  python3 validation/calib/score.py results_calib/$$a.tsv --base-from results_calib/ladder.tsv > results_calib/$$a.scored.tsv; \
	done

setup-r-env:
	source ~/miniconda3/bin/activate && \
	conda env create -f envs/rstats.yaml 2>/dev/null || \
	conda env update --name rstats -f envs/rstats.yaml

figures: setup-r-env
	mkdir -p figures
	source ~/miniconda3/bin/activate && \
	conda run -n rstats Rscript -e \
	  "rmarkdown::render('analysis.Rmd', output_dir='figures')"
	@if [ -n "$(PAPER_DIR)" ]; then \
	  mkdir -p $(PAPER_DIR)/figures && \
	  cp figures/analysis.html $(PAPER_DIR)/figures/denet_benchmark.html && \
	  echo "copied report to $(PAPER_DIR)/figures/"; \
	else echo "PAPER_DIR unset; report left in figures/analysis.html"; fi

clean:
	rm -rf results_baseline results_denet results_denet_native results_markdup_sort results_markdup_collate_fast \
	  results_markdup_round2 results_markdup_summary.txt results_calib results_idle figures __pycache__ .snakemake
