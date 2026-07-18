#!/bin/bash
# Print a per-batch table of how many gridpacks and nanogen files are ready on EOS.
#   ./report_batches.sh [--grid 4d|5d] [--points <json>] [--gpdir <url>]
#                       [--nanodir <url>] [--njobs <n>]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# --grid selects the JSON *and* its matching gridpack dir, exactly as submit_nanogen.sh
# does; the pair must stay together or the index -> point mapping silently shifts.
GRID=5d
JSON_4D=$HERE/FINALgrid_for_SMEFT_4D_leadingOnly_updated_PDF.json
JSON_5D=$HERE/FINALgrid_for_SMEFT_5D_leading_plus_ctg.json
GPDIR_4D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_keep_stage1
GPDIR_5D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_5param_keep_stage1

NANODIR=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen
POINTS=""                                      # explicit JSON; overrides --grid
GPDIR=""                                       # explicit dir;  overrides --grid
NJOBS=5                                        # nanogen jobs/point; must match submit_nanogen.sh

usage() { sed -n '2,4p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0; }

while [ $# -gt 0 ]; do
  case $1 in
    --grid)    GRID=$2;    shift 2;;
    --gpdir)   GPDIR=$2;   shift 2;;
    --nanodir) NANODIR=$2; shift 2;;
    --points)  POINTS=$2;  shift 2;;
    --njobs)   NJOBS=$2;   shift 2;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

case $GRID in
  4d) GRID_JSON=$JSON_4D; GRID_GPDIR=$GPDIR_4D;;
  5d) GRID_JSON=$JSON_5D; GRID_GPDIR=$GPDIR_5D;;
  *)  echo "--grid must be 4d or 5d (got '$GRID')" >&2; exit 1;;
esac
POINTS=${POINTS:-$GRID_JSON}
GPDIR=${GPDIR:-$GRID_GPDIR}
[ -f "$POINTS" ] || { echo "points JSON not found: $POINTS" >&2; exit 1; }

export X509_USER_PROXY=${X509_USER_PROXY:-$HOME/private/x509up}

# EOS keeps versioned shadow copies named ".sys.v#.<name>" that also end in
# _gridpack.tar.gz -- they must be filtered out or the count roughly doubles.
# $2 = "-R" for a recursive listing (nanogen lives in per-point subfolders).
list_dir() {
  case $1 in
    root://*) xrdfs "${1%%//eos/*}" ls ${2:-} "/eos/${1#*//eos/}" 2>/dev/null;;
    *)        [ -n "${2:-}" ] && find "$1" -type f 2>/dev/null || ls "$1" 2>/dev/null;;
  esac | xargs -n1 basename 2>/dev/null | grep -v '^\.sys' || true
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
list_dir "$GPDIR"        > "$TMP/gp.txt"
list_dir "$NANODIR" -R   > "$TMP/nano.txt"   # -R: files sit in <point>/ subfolders

python3 - "$POINTS" "$TMP/gp.txt" "$TMP/nano.txt" "$NJOBS" "$GPDIR" "$NANODIR" \
         "$BATCHFILE" "$CHUNK" <<'EOF'
import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.environ.get("HERE", "."))
from make_fragments import point_name

points_f, gp_f, nano_f, njobs, gpdir, nanodir, batchfile, chunk = sys.argv[1:9]
njobs = int(njobs); chunk = int(chunk)
pts   = json.load(open(points_f))
gp    = {l.strip() for l in open(gp_f)   if l.strip()}
nano  = {l.strip() for l in open(nano_f) if l.strip()}
N     = len(pts)

# Batch ranges, in order of preference:
#   --batches <file>  "start stop" per line (# comments and blanks ignored)
#   --chunk <n>       uniform blocks of n
#   default           the 5D production layout below; for any other grid size,
#                     fall back to uniform chunks so the table still covers it.
BATCHES_5D = [(1701,1800),(1801,1900),(1901,2000),(2001,2050),(2051,2150),
              (2151,2250),(2251,2300),(2301,2400),(2401,2450),(2451,2500),
              (1,100),(101,200),(201,300),(301,400),(401,500),(501,600),
              (601,700),(701,800),(801,900),(901,1000),(1001,1100),(1101,1200),
              (1201,1300),(1301,1400),(1401,1500),(1501,1600),(1601,1696)]

def uniform(n, size):
    return [(s, min(s+size-1, n)) for s in range(1, n+1, size)]

if batchfile:
    BATCHES = []
    for ln, raw in enumerate(open(batchfile), 1):
        line = raw.split("#", 1)[0].split()
        if not line: continue
        if len(line) != 2:
            sys.exit(f"{batchfile}:{ln}: expected 'start stop', got: {raw.strip()!r}")
        a, b = (int(x) for x in line)
        if not (1 <= a <= b):
            sys.exit(f"{batchfile}:{ln}: bad range {a}..{b}")
        BATCHES.append((a, b))
    if not BATCHES: sys.exit(f"{batchfile}: no ranges found")
elif chunk:
    BATCHES = uniform(N, chunk)
elif max(b for _, b in BATCHES_5D) <= N:
    BATCHES = BATCHES_5D
else:
    BATCHES = uniform(N, 100)          # e.g. the 4D grid: default layout overshoots

over = [(a, b) for a, b in BATCHES if b > N]
if over:
    print(f"!! {len(over)} batch(es) run past the end of the grid "
          f"({N} points) and are clamped\n", file=sys.stderr)
    BATCHES = [(a, min(b, N)) for a, b in BATCHES if a <= N]

print(f"gridpacks: {gpdir}")
print(f"nanogen  : {nanodir}   ({njobs} jobs/point)\n")
hdr = (f"{'start':>6} {'stop':>6} {'pts':>5} | {'gridpacks':>13} | "
       f"{'nanogen files':>15} | {'points w/ full nanogen':>24}")
print(hdr); print("-"*len(hdr))

def cell(done, total, width):
    """'  99/100  ' right-aligned in `width`, suffixed with * when complete."""
    return f"{done}/{total}".rjust(width) + (" *" if done == total else "  ")

tp=tg=tn=tf=0
for lo,hi in BATCHES:
    n = hi-lo+1
    g = f = nf = 0
    for i in range(lo,hi+1):
        name = point_name(pts[i-1])
        if name+"_gridpack.tar.gz" in gp: g += 1
        c = sum(1 for j in range(1,njobs+1) if f"NANOGEN_{name}_{j}.root" in nano)
        nf += c
        if c == njobs: f += 1
    tp+=n; tg+=g; tn+=nf; tf+=f
    print(f"{lo:>6} {hi:>6} {n:>5} | {cell(g,n,11)} | {cell(nf,n*njobs,13)} | {cell(f,n,22)}")

print("-"*len(hdr))
print(f"{'TOTAL':>13} {tp:>5} | {cell(tg,tp,11)} | {cell(tn,tp*njobs,13)} | {cell(tf,tp,22)}")
print("\n* = complete")
EOF
