SHELL      := bash
CONDA_RUN  := source ~/miniconda3/bin/activate && conda activate snakemake
SMK        := snakemake --cores 10
SMK_ENVS   := snakemake --use-conda --conda-frontend conda --cores 1
PAPER_DIR  := $(HOME)/src/2025_denet_profiler_appnote

# Benchmarks run with the rule environment activated once, not per job.
# --use-conda activation runs a ~90 MB conda process for ~0.3 s at the start of
# every job; that dominates short rules' peak RSS, and psutil's ~1 s sampling
# only catches it by chance. Without --use-conda the rules' conda: directives
# are ignored and the tools come from PATH.
TOOLS_ENV   = $(shell $(CONDA_RUN) && $(SMK_ENVS) --list-conda-envs 2>/dev/null | awk -F'\t' '$$1=="envs/genome_tools.yaml"{print $$3}')
BENCH       = $(CONDA_RUN) && test -x "$(TOOLS_ENV)/bin/samtools" && PATH="$(CURDIR)/$(TOOLS_ENV)/bin:$$PATH" $(SMK)

.PHONY: all conda-envs baseline denet denet-native markdup-variants setup-r-env figures clean

all: baseline denet denet-native markdup-variants figures

conda-envs:
	$(CONDA_RUN) && \
	$(SMK_ENVS) --config use_denet=false outdir=results_baseline --conda-create-envs-only

baseline: conda-envs
	$(BENCH) --config use_denet=false outdir=results_baseline --forceall

denet: conda-envs
	$(BENCH) --config use_denet=true outdir=results_denet --forceall

# needs the denet Python package next to snakemake: pip install denet
denet-native: conda-envs
	$(BENCH) --config use_denet_native=true outdir=results_denet_native --forceall

# markdup only, per mate-grouping variant, wrap mode with phase logs, on the
# aligned BAM from results_denet; feeds the per-process figure in analysis.Rmd
markdup-variants: conda-envs
	for g in sort collate_fast; do \
	  rm -rf results_markdup_$$g && mkdir -p results_markdup_$$g && \
	  cp -al results_denet/data results_denet/results results_markdup_$$g/ && \
	  rm -f results_markdup_$$g/results/aligned.markdup.bam* && \
	  $(BENCH) --config use_denet=true markdup_group=$$g markdup_phase_log=true outdir=results_markdup_$$g \
	    --allowed-rules markdup -- results_markdup_$$g/results/aligned.markdup.bam || exit 1; \
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
	mkdir -p $(PAPER_DIR)/figures
	cp figures/analysis.html $(PAPER_DIR)/figures/denet_benchmark.html

clean:
	rm -rf results_baseline results_denet results_denet_native results_markdup_sort results_markdup_collate_fast figures __pycache__ .snakemake
