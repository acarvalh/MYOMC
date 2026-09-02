#!/usr/bin/env python3
"""Generate POWHEG ggHH_SMEFT cards for the truncation benchmark study.

For each benchmark point in a CSV (default smeft_truncation_bm.csv, the five
LHCHWG-2026-006 Table-3 points) this writes TWO cards -- one LINEAR and one FULL
(quadratic) truncation -- so N points become 2N gridpacks. The linear/quadratic
switch is the POWHEG `SMEFTtruncation` card parameter, whose own template comments
match the report's definitions exactly:

    SMEFTtruncation 0  ->  |A_SM|^2 + 2 Re(A_SM* A_dim6)      = report LINEAR   (Eq. 5-6)
    SMEFTtruncation 1  ->  |A_SM + A_dim6|^2                  = report QUADRATIC (Eq. 9)

Coefficient columns in the CSV use this setup's names (CHbox, CH, CuH, CHG, CtG,
CQt, CQt8); see smeft_truncation_bm.csv for the report<->card mapping. A column that
is absent from the CSV is left at the template value; the four LEADING operators
(CHbox/CH/CuH/CHG) MUST be present (the template ships nonzero example values for
them), which the default CSV guarantees.

Card names: powheg_ggHH_SMEFT_TRUNC_<point>_<lin|quad>, so the 2N gridpacks never
collide (linear and quadratic of the same point share every coupling).

Usage:
    ./makeTruncationCards.py                          # 5 BM x2 = 10 cards, 13.6 TeV
    ./makeTruncationCards.py --points BM1,BM3         # a named subset
    ./makeTruncationCards.py --only lin               # only the linear variant
    ./makeTruncationCards.py --outdir cards_trunc_13p6TeV --ecm 13.6
"""
import argparse
import csv
import json
import os
import re

# Reuse the exact substitution + filename encoders the main SMEFT production uses,
# so these cards are byte-for-byte consistent with the rest of the pipeline.
from makeSMEFTCards import set_param, frmt, LEADING, SUBLEADING, COEFFS

# The two truncation variants: label -> SMEFTtruncation card value.
VARIANTS = {"lin": 0, "quad": 1}


def read_csv_points(path):
    """Read the benchmark CSV, skipping # comments and blank lines. Returns a list
    of (name, {coeff: float}), keeping only recognised coefficient columns."""
    rows = []
    with open(path) as f:
        lines = [ln for ln in f if ln.strip() and not ln.lstrip().startswith("#")]
    reader = csv.DictReader(lines)
    for row in reader:
        name = (row.get("point") or "").strip()
        if not name:
            continue
        coeffs = {}
        for k in COEFFS:
            if k in row and row[k] not in (None, ""):
                coeffs[k] = float(row[k])
        rows.append((name, coeffs))
    return rows


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", default=os.path.join(here, "powheg-2.input"))
    ap.add_argument("--csv", default=os.path.join(here, "smeft_truncation_bm.csv"))
    ap.add_argument("--outdir", default=os.path.join(here, "cards_trunc"))
    ap.add_argument("--ecm", type=float, default=13.6,
                    help="centre-of-mass energy in TeV (default 13.6 = Run 3)")
    ap.add_argument("--pdf", type=int, default=0,
                    help="LHAPDF LHAID for lhans1/lhans2 (0 = keep template value)")
    ap.add_argument("--points", default="",
                    help="comma list of benchmark names to keep (e.g. BM1,BM3); empty = all")
    ap.add_argument("--only", choices=list(VARIANTS), default="",
                    help="build only this truncation variant (default: both)")
    args = ap.parse_args()

    ebeam = args.ecm * 1000.0 / 2.0
    with open(args.template) as f:
        base = f.read()
    for tok in ("NEVENTS", "SEED"):
        if tok not in base:
            raise RuntimeError(f"template {args.template} missing the '{tok}' placeholder")

    points = read_csv_points(args.csv)
    if args.points:
        want = [p.strip() for p in args.points.split(",") if p.strip()]
        by = {n: (n, c) for n, c in points}
        missing = [w for w in want if w not in by]
        if missing:
            raise SystemExit(f"benchmarks not in {args.csv}: {', '.join(missing)}")
        points = [by[w] for w in want]
    variants = [args.only] if args.only else list(VARIANTS)

    os.makedirs(args.outdir, exist_ok=True)
    manifest = []
    for name, coeffs in points:
        # Subleading operators only enter the ME when includesubleading is on; turn it
        # on iff the point uses one (same rule as makeSMEFTCards.py). None of the five
        # default benchmarks do, so it stays 0 -- cheaper.
        use_sub = any(float(coeffs.get(k, 0)) != 0 for k in SUBLEADING)
        for label in variants:
            card = base
            card = set_param(card, "SMEFTtruncation", VARIANTS[label])
            # RGE OFF in both variants: WCscaledependence 0 => muEFT = muren and the
            # running/mixing of the Wilson coefficients is neglected. The report's
            # benchmarks (Sec. 3.2) are defined this way; force it so a template change
            # can never silently turn running on. (1/2 would run the coeffs to a
            # fixed/dynamic scale.)
            card = set_param(card, "WCscaledependence", 0)
            card = set_param(card, "includesubleading", 1 if use_sub else 0)
            for key in COEFFS:
                if key in coeffs:
                    card = set_param(card, key, coeffs[key])
            card = set_param(card, "ebeam1", int(ebeam) if float(ebeam).is_integer() else ebeam)
            card = set_param(card, "ebeam2", int(ebeam) if float(ebeam).is_integer() else ebeam)
            if args.pdf:
                for k in ("lhans1", "lhans2"):
                    pat = re.compile(r"^(\s*" + k + r"\s+)(\S+)(.*)$", re.MULTILINE)
                    card, n = pat.subn(lambda m: m.group(1) + str(int(args.pdf)) + m.group(3), card)
                    if n != 1:
                        raise RuntimeError(f"expected exactly 1 '{k}' line, found {n}")
            tag = f"powheg_ggHH_SMEFT_TRUNC_{name}_{label}"
            with open(os.path.join(args.outdir, tag + ".input"), "w") as wf:
                wf.write(card)
            manifest.append({"name": tag, "benchmark": name, "truncation": label,
                             "SMEFTtruncation": VARIANTS[label],
                             **{k: coeffs[k] for k in COEFFS if k in coeffs}})

    with open(os.path.join(args.outdir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"Wrote {len(manifest)} cards to {args.outdir} "
          f"({len(points)} benchmark(s) x {len(variants)} variant(s), ecm={args.ecm} TeV)")
    for m in manifest:
        cc = ", ".join(f"{k}={m[k]:+g}" for k in COEFFS if k in m) or "SM"
        print(f"  {m['name']}: SMEFTtruncation={m['SMEFTtruncation']} | {cc}")


if __name__ == "__main__":
    main()
