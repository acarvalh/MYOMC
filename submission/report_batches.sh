#!/bin/bash
# Print a per-batch table of how many gridpacks and nanogen files are ready on EOS.
#   ./report_batches.sh [--grid 4d|5d] [--points <json>] [--gpdir <url>]
#                       [--nanodir <url>] [--njobs <n>]
#                       [--batches <file>] [--chunk <n>] [--no-queue]
#                       [--gaps] [--resubmit-gaps [--yes|--dry-run]] [--week|--flavour X]
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
QUEUE=1                                        # read condor_q (--no-queue to skip)
GAPS=0                                         # --gaps: print resubmit commands
RESUBMIT=0                                     # --resubmit-gaps: run them (asks first)
ASSUME_YES=0                                   # --yes: skip the confirmation
DRYRUN=0                                       # --dry-run: pass through to the driver
SUBMITTER=$HERE/../gridpack/submit_smeft.sh    # driver used by --resubmit-gaps
FLAVOUR=""                                     # --flavour X / --week: passed to the driver
CARDDIR=$HERE/../gridpack/cards_prod           # where <point>.input cards live
LOGDIRS="$HERE/../gridpack/logs $HERE/../../condor/logs"   # searched for <point>.*.out
BATCHFILE=""                                   # file of "start stop" lines
CHUNK=""                                       # uniform blocks of N points

usage() { sed -n "2,6p" "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0; }

while [ $# -gt 0 ]; do
  case $1 in
    --grid)    GRID=$2;    shift 2;;
    --gpdir)   GPDIR=$2;   shift 2;;
    --nanodir) NANODIR=$2; shift 2;;
    --points)  POINTS=$2;  shift 2;;
    --njobs)   NJOBS=$2;   shift 2;;
    --batches) BATCHFILE=$2; shift 2;;
    --chunk)   CHUNK=$2;     shift 2;;
    --no-queue) QUEUE=0;     shift 1;;
    --gaps)          GAPS=1;       shift 1;;
    --resubmit-gaps) RESUBMIT=1;   shift 1;;
    --yes|-y)        ASSUME_YES=1; shift 1;;
    --dry-run|-n)    DRYRUN=1;     shift 1;;
    --submitter)     SUBMITTER=$2; shift 2;;
    --flavour|--flavor) FLAVOUR=$2; shift 2;;
    --week)          FLAVOUR=nextweek; shift 1;;   # 7-day wall (168h)
    --carddir)       CARDDIR=$2;  shift 2;;
    --logdir)        LOGDIRS=$2;  shift 2;;
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

# Live queue state, so a missing gridpack can be told apart from a queued one.
# Args carries the point name ("<point>.input"); JobStatus 1=idle 2=run 5=held.
# Only OUR jobs are visible here -- a colleague building the same point shows as
# a gap, not as running. Empty file (no proxy / no schedd) => queue columns read 0.
: > "$TMP/q.txt"
if [ "$QUEUE" = 1 ]; then
  condor_q -constraint 'regexp("run_smeft_gridpack.sh", Cmd)' \
           -af JobStatus Args > "$TMP/q.txt" 2>/dev/null || true
fi

if [ "$GAPS" = 1 ] || [ "$RESUBMIT" = 1 ]; then EMIT_GAPS=1; else EMIT_GAPS=0; fi
export EMIT_GAPS GAPS_OUT="$TMP/gaps.txt" FLAVOUR DRYRUN

# Cards and logs, to say WHY a gap is a gap: no card => never even carded (not
# submitted); card but no log => carded/submitted but the job left no trace.
# NB submit_smeft.sub uses a RELATIVE "logs/..." path, so logs land under whichever
# directory the submit ran from -- hence a list of dirs, and "no" is weak evidence.
ls "$CARDDIR" 2>/dev/null | sed -n 's/\.input$//p' | sort -u > "$TMP/cards.txt" || : > "$TMP/cards.txt"
: > "$TMP/logs.txt"
for d in $LOGDIRS; do
  [ -d "$d" ] && ls "$d" 2>/dev/null | sed -n 's/\.[0-9]*\.[0-9]*\.out$//p'
done | sort -u > "$TMP/logs.txt"
export CARDS_F="$TMP/cards.txt" LOGS_F="$TMP/logs.txt"

python3 - "$POINTS" "$TMP/gp.txt" "$TMP/nano.txt" "$NJOBS" "$GPDIR" "$NANODIR" \
         "$BATCHFILE" "$CHUNK" "$TMP/q.txt" <<'EOF'
import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.environ.get("HERE", "."))
from make_fragments import point_name

points_f, gp_f, nano_f, njobs, gpdir, nanodir, batchfile, chunk, q_f = sys.argv[1:10]
njobs = int(njobs); chunk = int(chunk) if chunk else 0
if chunk < 0: sys.exit("--chunk must be positive")
pts   = json.load(open(points_f))
gp    = {l.strip() for l in open(gp_f)   if l.strip()}
nano  = {l.strip() for l in open(nano_f) if l.strip()}
N     = len(pts)

# point name -> {1:idle, 2:running, 5:held}; a point may hold >1 job (a resubmit)
queue = {}
for line in open(q_f):
    f = line.split()
    if len(f) < 2: continue
    st, arg = f[0], f[1].strip('"')
    if arg.endswith(".input"): arg = arg[:-6]
    try: queue.setdefault(arg, set()).add(int(st))
    except ValueError: pass

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
print(f"nanogen  : {nanodir}   ({njobs} jobs/point)")
print(f"queue    : {len(queue)} points with a gridpack job in MY queue"
      if queue else "queue    : (not read -- --no-queue, or no schedd/proxy)")
print()
cards = {l.strip() for l in open(os.environ["CARDS_F"]) if l.strip()}
logs  = {l.strip() for l in open(os.environ["LOGS_F"])  if l.strip()}

def yesno(have, total):
    """yes / no / part -- over the gap points of a batch; '-' when there are none."""
    if total == 0: return "-"
    if have == total: return "yes"
    if have == 0:     return "no"
    return f"{have}/{total}"

hdr = (f"{'start':>6} {'stop':>6} {'pts':>5} | {'gridpacks':>13} | "
       f"{'run':>4} {'idle':>4} {'held':>4} {'gap':>4} {'card':>5} {'log':>5} | "
       f"{'nanogen files':>15} | {'full':>11}")
print(hdr); print("-"*len(hdr))

def cell(done, total, width):
    """'  99/100  ' right-aligned in `width`, suffixed with * when complete."""
    return f"{done}/{total}".rjust(width) + (" *" if done == total else "  ")

tp=tg=tn=tf=tr=ti=th=tx=0; tgc=tgl=0
for lo,hi in BATCHES:
    n = hi-lo+1
    g = f = nf = r = idle = held = gap = 0
    gap_card = gap_log = 0
    for i in range(lo,hi+1):
        name = point_name(pts[i-1])
        have = name+"_gridpack.tar.gz" in gp
        if have: g += 1
        st = queue.get(name, set())
        # A delivered point may still show a job (a stale resubmit); count queue
        # state only for points we do NOT yet have, so the columns explain the gap.
        if not have:
            if   2 in st: r    += 1
            elif 1 in st: idle += 1
            elif 5 in st: held += 1
            else:
                gap += 1                     # no file, no job: never submitted/lost
                if name in cards: gap_card += 1
                if name in logs:  gap_log  += 1
        c = sum(1 for j in range(1,njobs+1) if f"NANOGEN_{name}_{j}.root" in nano)
        nf += c
        if c == njobs: f += 1
    tp+=n; tg+=g; tn+=nf; tf+=f; tr+=r; ti+=idle; th+=held; tx+=gap
    tgc+=gap_card; tgl+=gap_log
    print(f"{lo:>6} {hi:>6} {n:>5} | {cell(g,n,11)} | "
          f"{r:>4} {idle:>4} {held:>4} {gap:>4} "
          f"{yesno(gap_card,gap):>5} {yesno(gap_log,gap):>5} | "
          f"{cell(nf,n*njobs,13)} | {cell(f,n,9)}")

print("-"*len(hdr))
print(f"{'TOTAL':>13} {tp:>5} | {cell(tg,tp,11)} | "
      f"{tr:>4} {ti:>4} {th:>4} {tx:>4} "
      f"{yesno(tgc,tx):>5} {yesno(tgl,tx):>5} | "
      f"{cell(tn,tp*njobs,13)} | {cell(tf,tp,9)}")
print("\n* = complete.  run/idle/held/gap count points with NO gridpack yet:")
print("  gap = no file and no job of mine -- never submitted, lost, or someone else's.")
print("  held jobs need condor_rm + resubmit; check: condor_q -constraint 'JobStatus==5' -af HoldReason")
print("  card/log = do the GAP points have a card / a condor .out?  yes | no | n/total")
print("    no card          -> never submitted (cards are written at submit time)")
print("    card but no log  -> submitted but left no trace: likely hit the wall / removed")

# --gaps / --resubmit-gaps: collapse the gap indices into contiguous runs and write
# one submit command per run. --only-missing is kept on every line so a point that
# completes between now and the run is dropped at submit time.
if os.environ.get("EMIT_GAPS") == "1":
    gaps = []
    for lo, hi in BATCHES:
        for i in range(lo, hi+1):
            name = point_name(pts[i-1])
            if name+"_gridpack.tar.gz" not in gp and name not in queue:
                gaps.append(i)
    gaps = sorted(set(gaps))
    runs = []
    for i in gaps:
        if runs and i == runs[-1][1] + 1: runs[-1][1] = i
        else: runs.append([i, i])
    flav = os.environ.get("FLAVOUR", "")
    extra = f" --flavour {flav}" if flav else ""
    with open(os.environ["GAPS_OUT"], "w") as fh:
        for a, b in runs:
            fh.write(f"--start {a} --end {b} --only-missing{extra}\n")
    print(f"\ngaps: {len(gaps)} point(s) in {len(runs)} contiguous run(s)")
    if gaps:
        print("  " + ", ".join(f"{a}" if a == b else f"{a}-{b}" for a, b in runs))
EOF

# ---------------------------------------------------------------------------
# --gaps / --resubmit-gaps
# ---------------------------------------------------------------------------
[ "$GAPS" = 1 ] || [ "$RESUBMIT" = 1 ] || exit 0
[ -s "$TMP/gaps.txt" ] || { echo; echo ">> no gaps to resubmit."; exit 0; }

echo
echo ">> resubmit commands (run from $(cd "$(dirname "$SUBMITTER")" && pwd)):"
while read -r a; do echo "   ./$(basename "$SUBMITTER") $a"; done < "$TMP/gaps.txt"

if [ "$DRYRUN" = 1 ]; then
  echo
  echo ">> DRY RUN: would submit $(awk '{n+=$4-$2+1} END{print n+0}' "$TMP/gaps.txt") job(s)" \
       "in $(wc -l < "$TMP/gaps.txt") batch(es). Nothing submitted."
  exit 0
fi

[ "$RESUBMIT" = 1 ] || exit 0     # --gaps prints only

[ -x "$SUBMITTER" ] || { echo "!! not executable: $SUBMITTER" >&2; exit 1; }

# A gap is only "no file and no job of MINE" -- a colleague building the same point
# is indistinguishable, and an expensive build is ~56h on 4 cores. Confirm first.
if [ "$ASSUME_YES" != 1 ]; then
  echo
  echo "!! A gap means no gridpack AND no job of yours -- it does NOT mean nobody"
  echo "!! is building it. If a colleague shares this EOS dir, check with them first."
  printf ">> submit %s job batch(es) now? [y/N] " "$(wc -l < "$TMP/gaps.txt")"
  read -r ans </dev/tty 2>/dev/null || ans=n     # no tty (cron/pipe) => abort
  case $ans in [yY]*) ;; *) echo ">> aborted, nothing submitted."; exit 0;; esac
fi

cd "$(dirname "$SUBMITTER")"
rc=0
while read -r a; do
  echo ">> $(basename "$SUBMITTER") $a"
  # shellcheck disable=SC2086
  "$SUBMITTER" $a || { rc=$?; echo "!! failed (exit $rc): $a" >&2; }
done < "$TMP/gaps.txt"
exit $rc
