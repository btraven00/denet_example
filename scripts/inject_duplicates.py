#!/usr/bin/env python3
"""Append synthetic PCR-style duplicates to a pair of gzipped FASTQ files.

wgsim samples reads independently from the reference, so it produces no true
duplicates. To give samtools markdup realistic work, we pick a random fraction
of read pairs and append extra copies with modified read names. The sequences
are unchanged, so they align to the same coordinates and are flagged as
duplicates downstream.
"""
import argparse
import gzip
import os
import random
import re
import sys


def iter_fastq(fh):
    while True:
        header = fh.readline()
        if not header:
            return
        seq = fh.readline()
        plus = fh.readline()
        qual = fh.readline()
        if not qual:
            sys.exit("truncated FASTQ record")
        yield header, seq, plus, qual


def dup_name(header, k):
    """Read name for the k-th copy, keeping the mate suffix last: aligners and
    samtools pair mates by stripping a trailing /1 or /2, so "name/1_dup1" and
    "name/2_dup1" would not be recognised as mates ("name_dup1/1" and
    "name_dup1/2" are)."""
    m = re.match(r"(.*?)(/[12])?$", header.rstrip("\n"))
    return f"{m.group(1)}_dup{k}{m.group(2) or ''}"


def append_duplicates(path, indices_to_copies, tmp_path):
    with gzip.open(path, "rt") as src, gzip.open(tmp_path, "wt") as dst:
        for idx, rec in enumerate(iter_fastq(src)):
            dst.write("".join(rec))
            n_copies = indices_to_copies.get(idx, 0)
            if n_copies:
                header, seq, plus, qual = rec
                for k in range(1, n_copies + 1):
                    dst.write(f"{dup_name(header, k)}\n{seq}{plus}{qual}")
    os.replace(tmp_path, path)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("r1", help="gzipped FASTQ, mate 1")
    p.add_argument("r2", help="gzipped FASTQ, mate 2")
    p.add_argument("--fraction", type=float, required=True,
                   help="fraction of read pairs to duplicate (0-1)")
    p.add_argument("--copies", type=int, default=1,
                   help="extra copies per selected pair (default 1)")
    p.add_argument("--seed", type=int, default=42)
    args = p.parse_args()

    if not 0 < args.fraction <= 1:
        sys.exit("fraction must be in (0, 1]")

    with gzip.open(args.r1, "rt") as fh:
        n_pairs = sum(1 for _ in fh) // 4

    rng = random.Random(args.seed)
    n_selected = int(round(n_pairs * args.fraction))
    selected = set(rng.sample(range(n_pairs), n_selected))
    indices_to_copies = {i: args.copies for i in selected}

    append_duplicates(args.r1, indices_to_copies, args.r1 + ".tmp")
    append_duplicates(args.r2, indices_to_copies, args.r2 + ".tmp")

    sys.stderr.write(
        f"duplicated {n_selected}/{n_pairs} pairs "
        f"({args.copies} extra copies each)\n"
    )


if __name__ == "__main__":
    main()
