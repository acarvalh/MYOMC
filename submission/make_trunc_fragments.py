#!/usr/bin/env python3
"""Generate NANOGEN fragments for the SMEFT truncation-study gridpacks.

These gridpacks (built by gridpack/submit_truncation.sh) are named by BENCHMARK +
truncation variant -- powheg_ggHH_SMEFT_TRUNC_<BM>_<lin|quad> -- NOT by Wilson
coefficients, and the lin/quad pair share identical couplings. So the standard
make_fragments.py (coefficient-encoded names, which would collide lin vs quad) cannot
name them. This generator instead names each fragment after its gridpack tag, so the
fragment <-> gridpack match (<tag>.py <-> <tag>_gridpack.tar.gz) that run_nanogen.sh /
submit_nanogen.sh rely on still holds.

The fragment BODY is identical to make_fragments.py (same ExternalLHEProducer + Pythia8
template, same __GRIDPACKPATH__ / --gridpack-base handling, same --hard-only block), so
both the condor and CRAB backends work unchanged. The manifest.json carries {name,index}
exactly like make_fragments' so submit_nanogen's collision-free seed windows and
--report/--only-missing logic key on it the same way.

Canonical order (fixes the seed index per tag, stable across subset runs):
    BM1_lin=0, BM1_quad=1, BM2_lin=2, ... (CSV row order x [lin, quad]).

Usage (mirrors make_fragments.py; normally invoked by submit_nanogen.sh --grid trunc):
    ./make_trunc_fragments.py --outdir frags --nevents 10000 --comenergy 13600
    ./make_trunc_fragments.py --points BM1,BM3 --only lin        # a subset
"""
import argparse
import csv
import json
import os

# Reuse the exact fragment template + hard-only block the main production uses.
from make_fragments import FRAGMENT_TEMPLATE, SHOWER_OFF_BLOCK

VARIANTS = ["lin", "quad"]   # order fixes the canonical seed index; keep in sync with
                             # gridpack/makeTruncationCards.py (VARIANTS dict order).


def canonical_tags(csv_path):
    """Return the full ordered list of (tag, benchmark, variant) for the CSV, in the
    canonical order that fixes each tag's seed index. Skips # comments / blank lines."""
    with open(csv_path) as f:
        lines = [ln for ln in f if ln.strip() and not ln.lstrip().startswith("#")]
    out = []
    for row in csv.DictReader(lines):
        bm = (row.get("point") or "").strip()
        if not bm:
            continue
        for v in VARIANTS:
            out.append((f"powheg_ggHH_SMEFT_TRUNC_{bm}_{v}", bm, v))
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default=os.path.join(
        here, "..", "gridpack", "smeft_truncation_bm.csv"))
    ap.add_argument("--outdir", default=os.path.join(here, "fragments_trunc"))
    ap.add_argument("--nevents", type=int, default=10000,
                    help="events per job (ExternalLHEProducer.nEvents)")
    ap.add_argument("--comenergy", type=float, default=13600.0,
                    help="centre-of-mass energy in GeV (13.6 TeV = 13600, the study energy)")
    ap.add_argument("--gridpack-base", default="",
                    help="bake <base>/<tag>_gridpack.tar.gz into the fragment (CRAB); "
                         "else leave the __GRIDPACKPATH__ token run_nanogen.sh substitutes.")
    ap.add_argument("--hard-only", action="store_true",
                    help="Pythia hard-process only (no shower/hadronization)")
    ap.add_argument("--points", default="",
                    help="comma list of benchmark names to keep (e.g. BM1,BM3); empty = all")
    ap.add_argument("--only", choices=VARIANTS, default="",
                    help="keep only this truncation variant (lin|quad); default both")
    # 1-based inclusive slicing over the canonical flat list (parity with make_fragments).
    ap.add_argument("--nmax", type=int, default=0,
                    help="number of tags; 0 = all (ignored if --start/--end given)")
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--end", type=int, default=0)
    args = ap.parse_args()

    full = canonical_tags(args.csv)                 # index = position in this list
    indexed = list(enumerate(full))                 # [(idx, (tag, bm, variant)), ...]

    # Subset filters (do NOT renumber -- the index stays the canonical seed index).
    if args.points:
        want = {p.strip() for p in args.points.split(",") if p.strip()}
        indexed = [t for t in indexed if t[1][1] in want]
    if args.only:
        indexed = [t for t in indexed if t[1][2] == args.only]
    # 1-based inclusive range / nmax over the (already filtered) list.
    if args.start > 0 or args.end > 0:
        lo = (args.start - 1) if args.start > 0 else 0
        hi = args.end if args.end > 0 else len(indexed)
        indexed = indexed[lo:hi]
    elif args.nmax > 0:
        indexed = indexed[:args.nmax]

    if not indexed:
        raise SystemExit("no truncation tags selected")

    shower_off = SHOWER_OFF_BLOCK if args.hard_only else ""
    os.makedirs(args.outdir, exist_ok=True)
    manifest = []
    for idx, (tag, bm, variant) in indexed:
        if args.gridpack_base:
            gridpack = args.gridpack_base.rstrip("/") + "/" + tag + "_gridpack.tar.gz"
            script = "run_generic_tarball_xrootd.sh"
        else:
            gridpack = "__GRIDPACKPATH__"
            script = "run_generic_tarball_cvmfs.sh"
        body = FRAGMENT_TEMPLATE.format(nevents=args.nevents, comenergy=args.comenergy,
                                        gridpack=gridpack, script=script,
                                        shower_off=shower_off)
        with open(os.path.join(args.outdir, tag + ".py"), "w") as wf:
            wf.write(body)
        manifest.append({"index": idx, "name": tag, "benchmark": bm, "truncation": variant,
                         "gridpack": tag + "_gridpack.tar.gz"})

    with open(os.path.join(args.outdir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"Wrote {len(manifest)} truncation fragment(s) to {args.outdir} "
          f"(nevents/job={args.nevents}, comEnergy={args.comenergy})")
    for m in manifest:
        print(f"  [{m['index']}] {m['name']}")


if __name__ == "__main__":
    main()
