#!/usr/bin/env python3
"""Check that result directories computed the same outputs.

    check_same_outputs.py DIR [DIR ...]

Reads DIR/results/digest_bam.tsv and digest_vcf.tsv (rules digest_bam and
digest_vcf) and compares every key present in more than one directory. Exits
1 on any mismatch, naming it, so a monitoring mode or a pipeline variant that
changes the results fails the run instead of passing unnoticed.

`duplicate_reads` is reported but does not fail the check: which copy of a
tied duplicate set markdup keeps depends on input order (see rule digest_bam);
the number flagged (`n_duplicates`) and everything else must match."""
import os, sys

INFO_ONLY = {"duplicate_reads"}

def digests(d):
    out = {}
    for name in ("digest_bam.tsv", "digest_vcf.tsv"):
        f = os.path.join(d, "results", name)
        if os.path.exists(f):
            out.update(line.rstrip("\n").split("\t", 1) for line in open(f) if line.strip())
    return out

dirs = sys.argv[1:]
if len(dirs) < 2:
    sys.exit(__doc__)
found = {d: digests(d) for d in dirs}
missing = [d for d, v in found.items() if not v]
if missing:
    sys.exit(f"no digests in: {', '.join(missing)}")
bad = 0
for key in sorted({k for v in found.values() for k in v}):
    vals = {d: v[key] for d, v in found.items() if key in v}
    if len(vals) < 2:
        continue
    same = len(set(vals.values())) == 1
    label = "same" if same else ("differs" if key in INFO_ONLY else "DIFFERENT")
    print(f"{label:9} {key:15} across {len(vals)}: {', '.join(vals)}")
    if not same:
        bad = bad or key not in INFO_ONLY
        for d, h in vals.items():
            print(f"            {h}  {d}")
sys.exit(bad)
