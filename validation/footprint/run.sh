#!/usr/bin/env bash
# denet's own memory footprint, two ways:
#  1. directly: VmHWM of the denet process from /proc/<pid>/status, which stays
#     readable when the binary has file capabilities, for a plain run and with
#     --enable-ebpf (needs the capabilities);
#  2. as Snakemake's benchmark reports it: 50 MiB jobs bare, wrapped in an
#     uncapped denet, and wrapped in a capped one. Snakemake reads memory through
#     /proc/<pid>/smaps, which a binary with file capabilities makes root-only,
#     so the capped denet is left out of the peak (psutil AccessDenied).
#
#   validation/footprint/run.sh CAPPED_DENET OUT_DIR
#   GPU=1 validation/footprint/run.sh ...   also measure --gpu (needs NVML and a
#                                           build with the gpu feature)
# Needs snakemake on PATH. The uncapped copy is made from CAPPED_DENET.
# OUT_DIR/env.jsonl records the host (denet --write-env).
set -euo pipefail
capped=$1 out=$2
mkdir -p "$out"; rm -rf "$out"/*
plain="$out/denet-uncapped"; cp "$capped" "$plain"   # cp drops file capabilities
"$plain" --version > "$out/denet_version.txt"
"$plain" --write-env -q -o "$out/env.jsonl" run -- true

hwm() { # binary, extra flags... -> VmHWM (kB) of the denet process
    local b=$1; shift
    "$b" "$@" -q -o /dev/null run -- sleep 4 & local p=$!
    sleep 3; awk '/VmHWM/{print $2}' "/proc/$p/status"; wait "$p"
}
{
  echo -e "config\trepeat\tvmhwm_kb"
  for r in 1 2 3; do
    echo -e "plain\t$r\t$(hwm "$plain")"
    echo -e "ebpf\t$r\t$(hwm "$capped" --enable-ebpf)"
    [[ "${GPU:-0}" == 1 ]] && echo -e "gpu\t$r\t$(hwm "$plain" --gpu)"
  done
} > "$out/direct.tsv"

here=$(dirname "$0")
for v in bare uncapped capped; do
  w=""; [[ $v == uncapped ]] && w=$plain; [[ $v == capped ]] && w=$capped
  snakemake -s "$here/footprint.smk" --cores 1 --nolock -q \
    --config outdir="$out/$v" wrap="$w" njobs=8 > "$out/$v.log" 2>&1
done
python3 "$here/summarise.py" "$out"
