#!/usr/bin/env python3
"""Generate one POWHEG ggHH input card per HEFT benchmark point.

Reads a HEFT-basis CSV (columns: point, kappa_lambda, kappa_t, c2, cg, c2g) and a
base HEFT template (powheg-2-heft.input, usesmeft 0) and writes one card per row,
substituting the five anomalous couplings DIRECTLY -- no SMEFT->HEFT mapping:

    CSV column     ->  POWHEG key
    kappa_lambda   ->  chhh
    kappa_t        ->  ct
    c2             ->  ctt
    cg             ->  cggh
    c2g            ->  cgghh

Cards are named powheg_ggHH_HEFT_<point>.input (e.g. ..._BM1.input), so the built
gridpack is <that>_gridpack.tar.gz -- the same run_smeft_gridpack.sh assembly and
the same submit .sub as the SMEFT production, just a different card set.

Usage:
    ./makeHEFTCards.py                                 # all rows of gghh_heft_basis.csv
    ./makeHEFTCards.py --nmax 3                        # first 3 benchmarks (test)
    ./makeHEFTCards.py --points BM1,BM7,BM12           # a named subset
    ./makeHEFTCards.py --ecm 14 --outdir cards_heft_14TeV
"""
import argparse
import csv
import json
import os
import re

# CSV column -> POWHEG HEFT key. Order fixed so names/cards are reproducible.
COL2KEY = [("kappa_lambda", "chhh"), ("kappa_t", "ct"), ("c2", "ctt"),
           ("cg", "cggh"), ("c2g", "cgghh")]
CSV_COLS = [c for c, _ in COL2KEY]


def frmt(value):
    """Format a coupling for a filename: '.'->'p', leading '-'->'m' (6 sig figs)."""
    return ("%.6g" % float(value)).replace("-", "m").replace(".", "p")


def set_param(card, key, value):
    """Replace the value of POWHEG parameter `key` (token-anchored, comments kept)."""
    pattern = re.compile(r"^(\s*" + re.escape(key) + r"\s+)(\S+)(.*)$", re.MULTILINE)
    new_card, n = pattern.subn(lambda m: m.group(1) + repr(float(value)) + m.group(3), card)
    if n != 1:
        raise RuntimeError(f"expected exactly 1 line for '{key}', found {n}")
    return new_card


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", default=os.path.join(here, "powheg-2-heft.input"))
    ap.add_argument("--csv", default=os.path.join(
        here, "..", "..", "..", "cms_ANs", "report5", "HHMatrix", "scripts",
        "coefficients", "gghh_heft_basis.csv"),
        help="HEFT-basis CSV (point,kappa_lambda,kappa_t,c2,cg,c2g)")
    ap.add_argument("--extra", default="",
                    help="comma list of ADDITIONAL CSVs (same columns) appended to "
                         "--csv, e.g. validation_points.csv")
    ap.add_argument("--outdir", default=os.path.join(here, "cards_heft"))
    # Centre-of-mass energy (TeV): sets ebeam1/ebeam2 = ecm*1000/2 GeV. Basis-only
    # cross-section extraction is being done at 14 TeV.
    ap.add_argument("--ecm", type=float, default=14.0,
                    help="centre-of-mass energy in TeV (default 14)")
    ap.add_argument("--pdf", type=int, default=0,
                    help="LHAPDF LHAID for lhans1/lhans2 (0 = keep template value)")
    ap.add_argument("--points", default="",
                    help="comma list of benchmark names to keep (default: all rows)")
    ap.add_argument("--nmax", type=int, default=0,
                    help="number of rows to generate; 0 = all")
    args = ap.parse_args()

    ebeam = args.ecm * 1000.0 / 2.0
    with open(args.template) as f:
        base = f.read()
    for tok in ("NEVENTS", "SEED"):
        if tok not in base:
            raise RuntimeError(f"template {args.template} is missing the '{tok}' placeholder")

    csv_paths = [args.csv] + [p.strip() for p in args.extra.split(",") if p.strip()]
    rows = []
    seen = set()
    for path in csv_paths:
        with open(path, newline="") as f:
            these = [r for r in csv.DictReader(f)]
        missing = [c for c in ["point"] + CSV_COLS if these and c not in these[0]]
        if missing:
            raise SystemExit(f"CSV {path} is missing column(s): {missing}")
        for r in these:
            bm = r["point"].strip()
            if bm in seen:                    # a later CSV must not silently shadow an earlier point
                raise SystemExit(f"duplicate point '{bm}' (in {path}); names must be unique across CSVs")
            seen.add(bm)
            rows.append(r)

    wanted = set(p.strip() for p in args.points.split(",") if p.strip()) if args.points else None
    if wanted:
        rows = [r for r in rows if r["point"].strip() in wanted]
    if args.nmax > 0:
        rows = rows[:args.nmax]

    os.makedirs(args.outdir, exist_ok=True)
    manifest = []
    for r in rows:
        bm = r["point"].strip()
        card = base
        for col, key in COL2KEY:
            card = set_param(card, key, r[col])
        card = set_param(card, "ebeam1", int(ebeam) if float(ebeam).is_integer() else ebeam)
        card = set_param(card, "ebeam2", int(ebeam) if float(ebeam).is_integer() else ebeam)
        if args.pdf:
            for k in ("lhans1", "lhans2"):
                pat = re.compile(r"^(\s*" + k + r"\s+)(\S+)(.*)$", re.MULTILINE)
                card, n = pat.subn(lambda m: m.group(1) + str(int(args.pdf)) + m.group(3), card)
                if n != 1:
                    raise RuntimeError(f"expected exactly 1 '{k}' line, found {n}")
        name = "powheg_ggHH_HEFT_" + bm
        with open(os.path.join(args.outdir, name + ".input"), "w") as wf:
            wf.write(card)
        manifest.append({"name": name, "point": bm,
                         **{key: float(r[col]) for col, key in COL2KEY}})

    with open(os.path.join(args.outdir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"Wrote {len(manifest)} HEFT cards to {args.outdir} (ecm={args.ecm} TeV)")
    for m in manifest:
        print(f"  {m['name']}: " + ", ".join(
            f"{key}={m[key]:+.6g}" for _, key in COL2KEY))


if __name__ == "__main__":
    main()
