"""Score a calibration ladder: capture per spike duration and instrument.

    python score.py LADDER.tsv [--base-from MAIN.tsv] [--mib 256]

Capture is the reported peak above the interpreter's baseline, as a percentage
of the spike. The baseline is the lowest peak any job reported (a job whose
spike was missed entirely); pass --base-from to take it from another ladder,
for arms where no spike is ever missed."""
import argparse, csv, statistics

COLS = [("rss_ref10ms_MB", "10 ms reference"), ("rss_native_MB", "denet native"),
        ("rss_psutil_MB", "Snakemake (psutil)")]


def rows(path):
    return list(csv.DictReader(open(path), delimiter="\t"))


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None  # NA: the instrument recorded nothing


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ladder")
    ap.add_argument("--base-from")
    ap.add_argument("--mib", type=float, default=256)
    a = ap.parse_args()
    data = rows(a.ladder)
    base = min(v for r in rows(a.base_from or a.ladder) for c, _ in COLS if (v := num(r[c])) is not None)
    by = {}
    for r in data:
        by.setdefault(float(r["rule"][5:].replace("p", ".")), []).append(r)
    print(f"# baseline {base:.1f} MiB; capture = (peak - baseline) / {a.mib:g} MiB; mean (repeats > 50%)")
    print("\t".join(["hold_s", "n"] + [name for _, name in COLS]))
    for hold in sorted(by):
        out = [f"{hold:g}", str(len(by[hold]))]
        for c, _ in COLS:
            v = [min(100, max(0, (x - base) / a.mib * 100)) for r in by[hold] if (x := num(r[c])) is not None]
            na = len(by[hold]) - len(v)
            out.append(f"{statistics.mean(v):.0f}% ({sum(x > 50 for x in v)}/{len(v)})" + (f" NA={na}" if na else "") if v else "NA")
        print("\t".join(out))


if __name__ == "__main__":
    main()
