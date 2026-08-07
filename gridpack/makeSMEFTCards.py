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
# value (it is not part of the operator grid). The list is grid-agnostic: only the
# coefficients actually PRESENT in a point are substituted / put in its name, so a
# 4D point (leading only), a 5D point (+CtG) and a 9D point (+CtG + the four-fermion
# operators) all keep the same encoding for their shared coefficients.
#   LEADING     : always at Born, enter regardless of includesubleading.
#   SUBLEADING  : CtG (chromomagnetic) + the four four-top operators. They only enter
#                 the ME when includesubleading is on, so it is turned on iff any of
#                 them is non-zero in the point (see below).
LEADING = ["CHbox", "CH", "CuH", "CHG"]
SUBLEADING = ["CtG", "CQt", "CQt8", "CQQtt", "CQQ8"]
COEFFS = LEADING + SUBLEADING


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
    # Centre-of-mass energy (TeV). Sets the POWHEG beam energies ebeam1/ebeam2 =
    # ecm*1000/2 GeV, overriding whatever the template carries. 13 = Run 2, 13.6 =
    # Run 3 (default, current production), 100 = FCC-hh. The grid is beam-energy
    # agnostic (same Wilson-coefficient points), so only the beams change here.
    ap.add_argument("--ecm", type=float, default=13.6,
                    help="centre-of-mass energy in TeV (13 | 13.6 | 100); default 13.6")
    # PDF (LHAPDF LHAID) for both beams, written to lhans1/lhans2. 0 = keep the template's
    # value (90400 = PDF4LHC15_nlo_30_pdfas, the Run-2/3 default). At 100 TeV submit_smeft.sh
    # passes 93300 = PDF4LHC21_40_pdfas, whose grid (XMin~1e-6, QMax 1e6 GeV) covers FCC-hh
    # small-x/high-Q where PDF4LHC15 (XMin 6e-6) would hit its grid edge.
    ap.add_argument("--pdf", type=int, default=0,
                    help="LHAPDF LHAID for lhans1/lhans2 (0 = keep template value)")
    ap.add_argument("--nmax", type=int, default=3,
                    help="number of points to generate; 0 = all (ignored if --start/--end given)")
    ap.add_argument("--start", type=int, default=0,
                    help="first point to generate, 1-based inclusive (0 = from the beginning)")
    ap.add_argument("--end", type=int, default=0,
                    help="last point to generate, 1-based inclusive (0 = to the end)")
    args = ap.parse_args()

    ebeam = args.ecm * 1000.0 / 2.0          # per-beam energy in GeV (ecm split evenly)
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
        # The SUBLEADING operators (CtG + the four four-top operators) only enter
        # the ME when subleading operators are enabled. includesubleading 1 = loop
        # power counting so they enter linearly (option 2 is bornonly-only). Valid
        # with SMEFTtruncation 1. Enabling them costs extra grid integration, so we
        # ONLY turn it on when this point actually uses at least one of them; a point
        # with all subleading == 0 reduces to the leading (4D) physics and we leave
        # subleading off (0) to save CPU.
        use_subleading = any(float(point.get(k, 0)) != 0 for k in SUBLEADING)
        card = set_param(card, "includesubleading", 1 if use_subleading else 0)
        for key in COEFFS:
            if key in point:                     # leave absent coeffs at their template value (0)
                card = set_param(card, key, point[key])
        # Beam energies from --ecm (default 13.6 TeV Run 3 => 6800 each). ebeam is an
        # int for the usual round values (6500/6800/50000) but formatted generally.
        card = set_param(card, "ebeam1", int(ebeam) if float(ebeam).is_integer() else ebeam)
        card = set_param(card, "ebeam2", int(ebeam) if float(ebeam).is_integer() else ebeam)
        if args.pdf:                          # 0 => leave the template's lhans1/lhans2 as-is
            # lhans is an integer LHAID; set_param would write it as 93300.0 (float),
            # so substitute directly to keep the bare-integer form POWHEG expects.
            for k in ("lhans1", "lhans2"):
                pat = re.compile(r"^(\s*" + k + r"\s+)(\S+)(.*)$", re.MULTILINE)
                card, n = pat.subn(lambda m: m.group(1) + str(int(args.pdf)) + m.group(3), card)
                if n != 1:
                    raise RuntimeError(f"expected exactly 1 '{k}' line, found {n}")
        name = "powheg_ggHH_SMEFT_" + "_".join(
            f"{k}_{frmt(point[k])}" for k in COEFFS if k in point)
        path = os.path.join(args.outdir, name + ".input")
        with open(path, "w") as wf:
            wf.write(card)
        manifest.append({"index": i, "name": name,
                         **{k: point[k] for k in COEFFS if k in point}})

    with open(os.path.join(args.outdir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"Wrote {len(points)} cards to {args.outdir}")
    for m in manifest:
        print(f"  {m['name']}: " + ", ".join(
            f"{k}={m[k]:+.6g}" for k in COEFFS if k in m))


if __name__ == "__main__":
    main()
