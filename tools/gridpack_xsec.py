#!/usr/bin/env python3
"""Extract the POWHEG cross section from ggHH_SMEFT gridpacks, no re-running.

Every <point>_gridpack.tar.gz carries POWHEG's integration output. The final,
fully-combined NLO cross section is the

    total (btilde+remnants) cross section in pb   <value> +- <err>

line of the pwg-st3-*-stat.dat members (one per POWHEG parallel strand, each an
independent estimate of the SAME total). This tool reads those members straight
out of the tarball (in memory -- nothing is unpacked to disk), combines the
strands by an inverse-variance weighted average, and prints one row per gridpack:

    index, point_name, xsec_pb, err_pb, nstrands

The xsec is INCLUSIVE gg -> HH at the gridpack's build energy (NLO), BEFORE any
HH decay branching ratio.

`index` is the 1-based position of the point in a grid JSON (`--points`), matched
by the SAME point_name encoder as the gridpacks/fragments (submission/make_fragments.py);
it is left blank for gridpacks whose name isn't in that JSON. Without `--points`
the index column is empty and rows come out in directory order.

Usage:
    ./gridpack_xsec.py /eos/user/a/acarvalh/smeft_gridpacks_5param_keep_stage1
    ./gridpack_xsec.py <dir> --points ../submission/FINALgrid_for_SMEFT_5D_leading_plus_ctg.json
    ./gridpack_xsec.py <dir> --csv xsec_5d.csv          # write CSV instead of stdout
    ./gridpack_xsec.py <one_gridpack.tar.gz>            # a single tarball
"""
import argparse
import glob
import math
import os
import re
import sys
import tarfile

# Same point -> name encoding as the gridpacks/fragments, so names map to JSON indices.
_SUBMISSION = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "submission")
sys.path.insert(0, _SUBMISSION)
from make_fragments import point_name  # noqa: E402

_STAT_RE = re.compile(
    r"total \(btilde\+remnants\) cross section in pb\s+"
    r"([-+0-9.EeDd]+)\s*\+-\s*([-+0-9.EeDd]+)")


def _f(tok):
    """Parse a Fortran/scientific float (accepts D exponents)."""
    return float(tok.replace("D", "E").replace("d", "e"))


def strand_xsecs(tar):
    """(value, err) from each pwg-st3-*-stat.dat member of an open tarfile."""
    out = []
    for m in tar.getmembers():
        base = os.path.basename(m.name)
        if not (base.startswith("pwg-st3-") and base.endswith("-stat.dat")):
            continue
        f = tar.extractfile(m)
        if f is None:
            continue
        text = f.read().decode("utf-8", "replace")
        hit = _STAT_RE.search(text)
        if hit:
            out.append((_f(hit.group(1)), _f(hit.group(2))))
    return out


def combine(strands):
    """Inverse-variance weighted average of the per-strand (value, err) estimates."""
    usable = [(v, e) for v, e in strands if e and e > 0]
    if not usable:                      # no errors -> plain mean, err unknown
        if not strands:
            return None, None, 0
        vals = [v for v, _ in strands]
        return sum(vals) / len(vals), 0.0, len(strands)
    wsum = sum(1.0 / e**2 for _, e in usable)
    val = sum(v / e**2 for v, e in usable) / wsum
    err = math.sqrt(1.0 / wsum)
    return val, err, len(usable)


def xsec_of_gridpack(path):
    """(value_pb, err_pb, nstrands) for one gridpack tarball, or (None, None, 0)."""
    try:
        with tarfile.open(path, "r:gz") as tar:
            return combine(strand_xsecs(tar))
    except (tarfile.TarError, OSError) as exc:
        print(f"  ! cannot read {path}: {exc}", file=sys.stderr)
        return None, None, 0


def load_index_map(points_json):
    """point_name -> 1-based index, from a grid JSON (as submit scripts number points)."""
    import json
    with open(points_json) as f:
        points = json.load(f)
    return {point_name(p): i + 1 for i, p in enumerate(points)}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", help="gridpack dir, or a single <point>_gridpack.tar.gz")
    ap.add_argument("--points", default="",
                    help="grid JSON to number points against (adds the index column)")
    ap.add_argument("--csv", default="",
                    help="write CSV to this file instead of stdout")
    ap.add_argument("--sort", choices=["name", "index", "xsec"], default="index",
                    help="row order (default: index, then name)")
    args = ap.parse_args()

    if os.path.isdir(args.path):
        tarballs = sorted(glob.glob(os.path.join(args.path, "*_gridpack.tar.gz")))
    elif os.path.isfile(args.path):
        tarballs = [args.path]
    else:
        raise SystemExit(f"not a dir or file: {args.path}")
    if not tarballs:
        raise SystemExit(f"no *_gridpack.tar.gz under {args.path}")

    idx_map = load_index_map(args.points) if args.points else {}

    rows = []
    for tb in tarballs:
        name = os.path.basename(tb)[:-len("_gridpack.tar.gz")]
        val, err, n = xsec_of_gridpack(tb)
        if val is None:
            continue
        rows.append({"index": idx_map.get(name, ""), "name": name,
                     "xsec_pb": val, "err_pb": err, "nstrands": n})

    def keyf(r):
        if args.sort == "name":
            return (r["name"],)
        if args.sort == "xsec":
            return (r["xsec_pb"],)
        # index: numeric where known, unindexed rows last (by name)
        return (0, r["index"]) if r["index"] != "" else (1, r["name"])
    rows.sort(key=keyf)

    out = open(args.csv, "w") if args.csv else sys.stdout
    out.write("index,point_name,xsec_pb,err_pb,nstrands\n")
    for r in rows:
        out.write(f"{r['index']},{r['name']},{r['xsec_pb']:.8g},"
                  f"{r['err_pb']:.4g},{r['nstrands']}\n")
    if args.csv:
        out.close()
        print(f"Wrote {len(rows)} rows to {args.csv}", file=sys.stderr)
    else:
        print(f"\n{len(rows)} gridpacks read", file=sys.stderr)


if __name__ == "__main__":
    main()
