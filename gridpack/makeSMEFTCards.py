#!/usr/bin/env python3
"""Generate one POWHEG ggHH_SMEFT input card per parameter point.

Reads a base powheg.input template and a JSON list of points (each a dict of
Wilson coefficients) and writes one card per point, substituting the
coefficient values. Coefficient lines are matched token-anchored so that e.g.
'CH' does not clobber 'CHbox'/'CHD'/'CHG'.

Usage:
    ./makeSMEFTCards.py                      # first 3 points (test default)
    ./makeSMEFTCards.py --nmax 0             # all points
    ./makeSMEFTCards.py --nmax 50 --outdir cards_test
"""
import argparse
import json
import os
import re

# Wilson coefficients we substitute from the JSON. CHD is left at its template
# value (it is not part of the leading-operator grid). CtG (chromomagnetic
# operator) is the 5th coupling of the 5D leading+ctg grid.
COEFFS = ["CHbox", "CH", "CuH", "CHG", "CtG"]


def frmt(value):
    """Format a coupling for use in a filename: '.'->'p', leading '-'->'m'.

    e.g. 3.3699425 -> '3p36994', -0.00561542 -> 'm0p00561542' (6 sig figs).
    The exact value still goes into the card; this is only a label.
    """
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
    ap.add_argument("--template", default=os.path.join(here, "powheg-2.input"))
    # Points grid is BUNDLED in this repo (../submission/) so a fresh MYOMC clone
    # needs no reach into EOS. Override with --points for a different grid.
    ap.add_argument("--points", default=os.path.join(
        here, "..", "submission", "FINALgrid_for_SMEFT_5D_leading_plus_ctg.json"))
    ap.add_argument("--outdir", default=os.path.join(here, "cards_test"))
    ap.add_argument("--nmax", type=int, default=3,
                    help="number of points to generate; 0 = all (ignored if --start/--end given)")
    ap.add_argument("--start", type=int, default=0,
                    help="first point to generate, 1-based inclusive (0 = from the beginning)")
    ap.add_argument("--end", type=int, default=0,
                    help="last point to generate, 1-based inclusive (0 = to the end)")
    args = ap.parse_args()

    with open(args.template) as f:
        base = f.read()
    # HEFT convention: numevts/iseed are placeholders filled at build / generation
    # time (run_smeft_gridpack.sh and runcmsgrid.sh), not hard-coded here.
    for tok in ("NEVENTS", "SEED"):
        if tok not in base:
            raise RuntimeError(f"template {args.template} is missing the '{tok}' "
                               f"placeholder (expected 'numevts NEVENTS' / 'iseed SEED')")
    with open(args.points) as f:
        points = json.load(f)

    # Select the slice of points to generate.
    if args.start > 0 or args.end > 0:
        # 1-based inclusive range [start, end]; either bound may be omitted.
        lo = (args.start - 1) if args.start > 0 else 0
        hi = args.end if args.end > 0 else len(points)
        offset = lo
        points = points[lo:hi]
    elif args.nmax > 0:
        offset = 0
        points = points[:args.nmax]
    else:
        offset = 0

    os.makedirs(args.outdir, exist_ok=True)
    manifest = []
    for j, point in enumerate(points):
        i = offset + j  # absolute index into the original JSON
        card = base  # template already sets usesmeft 1 + SMEFTtruncation 1
        # CtG is a SUBLEADING operator: it only enters the ME when subleading
        # operators are enabled. includesubleading 1 = loop power counting so
        # C_tG enters linearly (option 2 is bornonly-only). Valid with
        # SMEFTtruncation 1. But enabling subleading operators costs extra grid
        # integration, so ONLY turn it on when this point actually uses CtG;
        # when CtG == 0 it reduces to the 4D physics and we leave subleading
        # off (0) to save CPU.
        card = set_param(card, "includesubleading", 1 if float(point["CtG"]) != 0 else 0)
        for key in COEFFS:
            card = set_param(card, key, point[key])
        # 13.6 TeV (Run 3) beams
        card = set_param(card, "ebeam1", 6800)
        card = set_param(card, "ebeam2", 6800)
        name = "powheg_ggHH_SMEFT_" + "_".join(f"{k}_{frmt(point[k])}" for k in COEFFS)
        path = os.path.join(args.outdir, name + ".input")
        with open(path, "w") as wf:
            wf.write(card)
        manifest.append({"index": i, "name": name, **{k: point[k] for k in COEFFS}})

    with open(os.path.join(args.outdir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"Wrote {len(points)} cards to {args.outdir}")
    for m in manifest:
        print(f"  {m['name']}: " + ", ".join(f"{k}={m[k]:+.6g}" for k in COEFFS))


if __name__ == "__main__":
    main()
