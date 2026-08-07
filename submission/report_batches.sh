#!/bin/bash
# Print a per-batch table of how many gridpacks and nanogen files are ready on EOS.
#   ./report_batches.sh [--grid 4d|5d|9d] [--ecm 13|13.6|100] [--points <json>]
#                       [--gpdir <url>] [--nanodir <url>] [--njobs <n>] [--backend condor|crab]
#                       [--batches <file>] [--chunk <n>] [--no-queue]
#                       [--others u1,u2] [--gaps]
#                       [--resubmit-gaps [--yes|--dry-run]] [--week|--flavour X]
#                       [--resubmit-nano [--yes|--dry-run]]
# --gaps PRINTS nanogen `submit_nanogen.sh ... --only-missing` commands for points with
# missing NANOGEN files. --resubmit-nano RUNS them back-to-back; no drain wait is needed
# because submit_nanogen.sh gives each run its own fragment dir (no shared-wipe race).
# Under --backend crab both instead PRINT per-point `crab resubmit -d <proj>` for tasks
# that exist (never auto-run), and flag ranges with no CRAB task yet as needing an initial
# submit -- CRAB seeds by job number, so a top-up submit would duplicate events.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# --grid selects the JSON *and* its matching gridpack dir, exactly as submit_nanogen.sh
# does; the pair must stay together or the index -> point mapping silently shifts.
GRID=5d
# --ecm {13|13.6|100} TeV: report the matching energy-tagged EOS dirs. 13.6 (default,
# current production) uses the ORIGINAL untagged dirs; 13/100 TeV read the sibling
# "_13TeV"/"_100TeV" dirs. Threaded into the resubmit commands this prints too.
ECM=13.6
JSON_4D=$HERE/FINALgrid_for_SMEFT_4D_leadingOnly_updated_PDF.json
JSON_5D=$HERE/FINALgrid_for_SMEFT_5D_leading_plus_ctg.json
JSON_9D=$HERE/FINALgrid_for_SMEFT_9D_extension_only.json
GPDIR_4D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_keep_stage1
GPDIR_5D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_5param_keep_stage1
GPDIR_9D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen_9d/gridpacks
# nanogen dir per grid: 4d/5d share smeft_nanogen; 9d is self-contained under smeft_nanogen_9d.
NANODIR_4D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen
NANODIR_5D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen
NANODIR_9D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen_9d/nanogen

NANODIR=""                                     # empty => derive from --grid; --nanodir overrides
POINTS=""                                      # explicit JSON; overrides --grid
GPDIR=""                                       # explicit dir;  overrides --grid
NJOBS=5                                        # nanogen jobs/point; must match submit_nanogen.sh
BACKEND=condor                                 # condor | crab. crab: nanogen 'done' is counted by
                                               # walking the CRAB LFN tree (NANODIR/<req>/<tag>/<ts>/000X/*.root)
                                               # instead of the flat NANOGEN_<point>_<gjob>.root layout; the
                                               # condor-only queue columns (run/idle/held) then read 0 (CRAB
                                               # jobs aren't in local condor_q -- use `crab status` for in-flight).
QUEUE=1                                        # read condor_q (--no-queue to skip)
OTHERS=""                                       # --others u1,u2: also count these owners' gridpack jobs
                                               # (pool-wide condor_q -global -allusers). A point they are
                                               # building then shows in an 'oth' column instead of 'gap',
                                               # and is EXCLUDED from --resubmit-gaps so we don't step on it.
GAPS=0                                         # --gaps: print resubmit commands
RESUBMIT=0                                     # --resubmit-gaps: run GRIDPACK resubmits (asks first)
RESUBMIT_NANO=0                                # --resubmit-nano: run NANOGEN --only-missing resubmits
                                               # back-to-back. Safe with no drain wait because
                                               # submit_nanogen.sh now gives each run its own fragment dir.
ASSUME_YES=0                                   # --yes: skip the confirmation
DRYRUN=0                                       # --dry-run: pass through to the driver
SUBMITTER=$HERE/../gridpack/submit_smeft.sh    # driver used by --resubmit-gaps
FLAVOUR=""                                     # --flavour X / --week: passed to the driver
CARDDIR=$HERE/../gridpack/cards_prod           # where <point>.input cards live
LOGDIRS="$HERE/../gridpack/logs $HERE/../../condor/logs"   # searched for <point>.*.out
BATCHFILE=""                                   # file of "start stop" lines
CHUNK=""                                       # uniform blocks of N points

usage() { sed -n "2,11p" "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0; }

while [ $# -gt 0 ]; do
  case $1 in
    --grid)    GRID=$2;    shift 2;;
    --ecm)     ECM=$2;     shift 2;;
    --gpdir)   GPDIR=$2;   shift 2;;
    --nanodir) NANODIR=$2; shift 2;;
    --points)  POINTS=$2;  shift 2;;
    --njobs)   NJOBS=$2;   shift 2;;
    --backend) BACKEND=$2; shift 2;;
    --batches) BATCHFILE=$2; shift 2;;
    --chunk)   CHUNK=$2;     shift 2;;
    --no-queue) QUEUE=0;     shift 1;;
    --others)   OTHERS=$2;   shift 2;;
    --gaps)          GAPS=1;       shift 1;;
    --resubmit-gaps) RESUBMIT=1;   shift 1;;
    --resubmit-nano) RESUBMIT_NANO=1; shift 1;;
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

# Resolve --ecm into the EOS dir tag (empty for the untagged 13.6 TeV production).
case "$ECM" in
  13|13.0)   ECM_TAG=_13TeV;;
  13.6)      ECM_TAG=;;
  100|100.0) ECM_TAG=_100TeV;;
  *) echo "--ecm must be 13, 13.6 or 100 (TeV); got '$ECM'" >&2; exit 1;;
esac
GPDIR_4D=$GPDIR_4D$ECM_TAG; GPDIR_5D=$GPDIR_5D$ECM_TAG; GPDIR_9D=$GPDIR_9D$ECM_TAG
NANODIR_4D=$NANODIR_4D$ECM_TAG; NANODIR_5D=$NANODIR_5D$ECM_TAG; NANODIR_9D=$NANODIR_9D$ECM_TAG

case "$BACKEND" in
  condor|crab) ;;
  *) echo "--backend must be condor or crab (got '$BACKEND')" >&2; exit 1;;
esac
# CRAB top-ups reuse job-number-based seeds -> duplicate events (see submit_crab.sh), so
# report_batches must never run submit_nanogen for CRAB gaps. Instead, under --backend crab,
# a nanogen gap is fixed EITHER by `crab resubmit` on the point's existing task (safe: it
# re-runs only that task's FAILED jobs, no seed reuse) OR, if no task exists yet, by an
# INITIAL submit. So --gaps / --resubmit-nano under crab PRINT the right per-point command:
# `crab resubmit -d <workArea>/crab_<req>` when the CRAB project dir exists, else flag the
# range as "not yet submitted". CRAB workArea (submit_crab.sh sets General.workArea, run
# from this dir) => project dirs live in $HERE/crab_nanogen/crab_<req>. Override with env.
CRAB_WORKAREA=${CRAB_WORKAREA:-$HERE/crab_nanogen}

case $GRID in
  4d) GRID_JSON=$JSON_4D; GRID_GPDIR=$GPDIR_4D; GRID_NANO=$NANODIR_4D;;
  5d) GRID_JSON=$JSON_5D; GRID_GPDIR=$GPDIR_5D; GRID_NANO=$NANODIR_5D;;
  9d) GRID_JSON=$JSON_9D; GRID_GPDIR=$GPDIR_9D; GRID_NANO=$NANODIR_9D;;
  *)  echo "--grid must be 4d, 5d or 9d (got '$GRID')" >&2; exit 1;;
esac
POINTS=${POINTS:-$GRID_JSON}
GPDIR=${GPDIR:-$GRID_GPDIR}
NANODIR=${NANODIR:-$GRID_NANO}
export GRID ECM ECM_TAG
[ -f "$POINTS" ] || { echo "points JSON not found: $POINTS" >&2; exit 1; }
echo ">> grid=$GRID  ecm=${ECM}TeV  gridpacks=$GPDIR  nanogen=$NANODIR" >&2

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

# For --backend crab: emit ONE line per delivered .root file = the CRAB primaryDataset
# dir (<req>) it sits under, so the Python side can count files per point. CRAB writes
# NANODIR/<req>/<outputDatasetTag>/<timestamp>/000X/<file>_<jobid>.root, and <req> =
# "<point without powheg_ prefix>"[:100] (see submit_crab.sh). Walk recursively, keep
# only .root files, strip the NANODIR base, take the first path component (<req>).
list_nano_crab() {
  local url=$1 base paths
  case $url in
    root://*) base="/eos/${url#*//eos/}"
              paths=$(xrdfs "${url%%//eos/*}" ls -R "$base" 2>/dev/null) ;;
    *)        base=$url
              paths=$(find "$url" -type f 2>/dev/null) ;;
  esac
  printf '%s\n' "$paths" | grep -E '\.root$' | grep -v '\.sys' \
    | sed "s#^${base%/}/##" | awk -F/ 'NF>=1{print $1}' || true
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
list_dir "$GPDIR"        > "$TMP/gp.txt"
if [ "$BACKEND" = crab ]; then
  list_nano_crab "$NANODIR" > "$TMP/nano.txt"   # one <req> per delivered .root file
else
  list_dir "$NANODIR" -R   > "$TMP/nano.txt"   # -R: files sit in <point>/ subfolders
fi

# Live queue state, so a missing gridpack can be told apart from a queued one.
# Args carries the point name ("<point>.input"); JobStatus 1=idle 2=run 5=held.
# Only OUR jobs are visible here -- a colleague building the same point shows as
# a gap, not as running. Empty file (no proxy / no schedd) => queue columns read 0.
: > "$TMP/q.txt"
: > "$TMP/nq.txt"
if [ "$QUEUE" = 1 ]; then
  condor_q -constraint 'regexp("run_smeft_gridpack.sh", Cmd)' \
           -af JobStatus Args > "$TMP/q.txt" 2>/dev/null || true
  # NANOGEN jobs: Args is "<point> <gjob>", and the job writes NANOGEN_<point>_<gjob>.root,
  # so (point,gjob) keys the queue exactly like the file it will deliver. CRAB jobs are NOT
  # in the local condor_q, so skip this for --backend crab (nq.txt stays empty => run/idle/
  # held read 0; CRAB in-flight status comes from `crab status`, not this script).
  [ "$BACKEND" = crab ] || condor_q -constraint 'regexp("run_nanogen.sh", Cmd)' \
           -af JobStatus Args > "$TMP/nq.txt" 2>/dev/null || true
fi
export NQ_F="$TMP/nq.txt" BACKEND

# --others u1,u2: also read those owners' gridpack jobs, pool-wide (-global -allusers),
# so a point THEY are building is not miscounted as a gap of mine. Each line of oth.txt is
# "<owner>\t<point>"; any of their job states (idle/run/held) counts as "in progress", and
# the owner drives the 'runner' column.
: > "$TMP/oth.txt"
: > "$TMP/noth.txt"
if [ -n "$OTHERS" ] && [ "$QUEUE" = 1 ]; then
  owner_expr=$(printf '%s' "$OTHERS" | tr ',' '\n' | sed '/^$/d;s/.*/Owner=="&"/' | paste -sd '|' | sed 's/|/ || /g')
  if [ -n "$owner_expr" ]; then
    echo ">> reading colleagues' gridpack + nanogen jobs (pool-wide): $OTHERS"
    condor_q -global -allusers \
      -constraint "regexp(\"run_smeft_gridpack.sh\", Cmd) && ($owner_expr)" \
      -af Owner Args 2>/dev/null | awk 'NF>=2{a=$2; sub(/\.input$/,"",a); print $1"\t"a}' \
      > "$TMP/oth.txt" || true
    # same for nanogen; key is "<point>\t<gjob>" so it lines up with the output file
    condor_q -global -allusers \
      -constraint "regexp(\"run_nanogen.sh\", Cmd) && ($owner_expr)" \
      -af Owner Args 2>/dev/null | awk 'NF>=3{print $1"\t"$2"\t"$3}' \
      > "$TMP/noth.txt" || true
  fi
fi
export OTH_F="$TMP/oth.txt" NOTH_F="$TMP/noth.txt" OTHERS

if [ "$GAPS" = 1 ] || [ "$RESUBMIT" = 1 ] || [ "$RESUBMIT_NANO" = 1 ]; then EMIT_GAPS=1; else EMIT_GAPS=0; fi
export EMIT_GAPS GAPS_OUT="$TMP/gaps.txt" NGAPS_OUT="$TMP/ngaps.txt" FLAVOUR DRYRUN
export CRAB_WORKAREA CRAB_RESUB_OUT="$TMP/crab_resub.txt" CRAB_MISSING_OUT="$TMP/crab_missing.txt"

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

# Backend-dependent "is nanogen file j of this point delivered?" test.
#   condor: nano_f holds basenames -> membership of NANOGEN_<point>_<j>.root.
#   crab:   nano_f holds one CRAB primaryDataset <req> per delivered .root file, so we
#           COUNT files per <req> and treat the first `count` job-slots (1..count) as done.
#           <req> = "<point without powheg_ prefix>"[:100] (matches submit_crab.sh).
from collections import Counter
backend = os.environ.get("BACKEND", "condor")
crab_count = Counter(l.strip() for l in open(nano_f) if l.strip()) if backend == "crab" else Counter()
def req_of(name):
    r = name[len("powheg_"):] if name.startswith("powheg_") else name
    return r[:100]
def delivered(name, j):
    if backend == "crab":
        return j <= crab_count.get(req_of(name), 0)
    return f"NANOGEN_{name}_{j}.root" in nano

# Points other submitters (--others) are building, pool-wide. A point here is treated
# as "in progress elsewhere": counted in the 'oth' column, named in the 'runner' column,
# kept out of 'gap', and never emitted for --resubmit-gaps. owner_of[point] = the owner
# building it (first seen wins if two colleagues race the same point -- rare).
oth_f = os.environ.get("OTH_F", "")
owner_of = {}
if oth_f and os.path.exists(oth_f):
    for l in open(oth_f):
        parts = l.rstrip("\n").split("\t")
        if len(parts) == 2 and parts[1]:
            owner_of.setdefault(parts[1], parts[0])
others = set(owner_of)

# Same for NANOGEN, but keyed per (point, gjob) -- one job per output file.
noth_f = os.environ.get("NOTH_F", "")
nowner_of = {}
if noth_f and os.path.exists(noth_f):
    for l in open(noth_f):
        parts = l.rstrip("\n").split("\t")
        if len(parts) == 3 and parts[1] and parts[2]:
            nowner_of.setdefault((parts[1], parts[2]), parts[0])
nothers = set(nowner_of)

# point name -> {1:idle, 2:running, 5:held}; a point may hold >1 job (a resubmit)
queue = {}
for line in open(q_f):
    f = line.split()
    if len(f) < 2: continue
    st, arg = f[0], f[1].strip('"')
    if arg.endswith(".input"): arg = arg[:-6]
    try: queue.setdefault(arg, set()).add(int(st))
    except ValueError: pass

# (point, gjob) -> {1,2,5} for my NANOGEN jobs. Args = "<point> <gjob>", and the job
# delivers NANOGEN_<point>_<gjob>.root, so this keys 1:1 to the file we look for.
nqueue = {}
nq_f = os.environ.get("NQ_F", "")
if nq_f and os.path.exists(nq_f):
    for line in open(nq_f):
        f = line.split()
        if len(f) < 3: continue
        try: nqueue.setdefault((f[1].strip('"'), f[2].strip('"')), set()).add(int(f[0]))
        except ValueError: pass

# Batch ranges, in order of preference:
#   --batches <file>  "start stop" per line (# comments and blanks ignored)
#   --chunk <n>       uniform blocks of n
#   default           the 5D production layout below; for any other grid size,
#                     fall back to uniform chunks so the table still covers it.
BATCHES_5D_SUBMITTED = [(1701,1800),(1801,1900),(1901,2000),(2001,2050),(2051,2150),
              (2151,2250),(2251,2300),(2301,2400),(2401,2450),(2451,2500),
              (1,100),(101,200),(201,300),(301,400),(401,500),(501,600),
              (601,700),(701,800),(801,900),(901,1000),(1001,1100),(1101,1200),
              (1201,1300),(1301,1400),(1401,1500),(1501,1600),(1601,1696)]

def split(ranges, size):
    """Cut each range into blocks of at most `size`, keeping the original order.
    The last block of a range may be short (e.g. 1601-1696 -> 1601-1650, 1651-1696)."""
    out = []
    for a, b in ranges:
        out += [(s, min(s+size-1, b)) for s in range(a, b+1, size)]
    return out

# Reported in blocks of 50: same submission order, finer granularity, so a half-done
# 100-point batch shows which half is missing.
BATCHES_5D = split(BATCHES_5D_SUBMITTED, 50)

# 9D extension (2000 points): each 2D plane is its OWN batch (points 1..832 -- the four
# four-top operators crossed with the leading operators, CtG, and each other), then the
# fully-mixed 9D region (833..2000, all nine coeffs non-zero) in blocks of 50. Derived
# from the grid structure (see submission/batches_9d.txt for the plane labels); keep the
# two in sync if the JSON changes.
BATCHES_9D = [(1,40),(41,80),(81,120),(121,160),(161,180),(181,220),
              (221,260),(261,300),(301,340),(341,360),(361,400),(401,440),
              (441,480),(481,520),(521,540),(541,580),(581,620),(621,660),
              (661,700),(701,720),(721,744),(745,764),(765,784),(785,800),
              (801,816),(817,832),(833,882),(883,932),(933,982),(983,1032),
              (1033,1082),(1083,1132),(1133,1182),(1183,1232),(1233,1282),(1283,1332),
              (1333,1382),(1383,1432),(1433,1482),(1483,1532),(1533,1582),(1583,1632),
              (1633,1682),(1683,1732),(1733,1782),(1783,1832),(1833,1882),(1883,1932),
              (1933,1982),(1983,2000)]

def uniform(n, size):
    return [(s, min(s+size-1, n)) for s in range(1, n+1, size)]

grid = os.environ.get("GRID", "5d")
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
elif grid == "9d" and max(b for _, b in BATCHES_9D) <= N:
    BATCHES = BATCHES_9D               # 2D planes each in their own batch, then mixed/50
elif grid != "9d" and max(b for _, b in BATCHES_5D) <= N:
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
if nqueue:
    print(f"           {len(nqueue)} nanogen job(s) in MY queue")
print()
cards = {l.strip() for l in open(os.environ["CARDS_F"]) if l.strip()}
logs  = {l.strip() for l in open(os.environ["LOGS_F"])  if l.strip()}

def yesno(have, total):
    """yes / no / part -- over the gap points of a batch; '-' when there are none."""
    if total == 0: return "-"
    if have == total: return "yes"
    if have == 0:     return "no"
    return f"{have}/{total}"

# The 'oth' count + 'runner' name columns (points a colleague is building) only appear
# with --others, so the default table is byte-identical to before.
OTHCOL = bool(others or nothers)
RUNW = 18                                   # width of each 'runner' column
oth_h = f"{'oth':>4} " if OTHCOL else ""
run_h = f" | {'runner':<{RUNW}}" if OTHCOL else ""
# Two job blocks: gridpacks (1 job/point) and nanogen (njobs jobs/point, so its
# run/idle/held/oth/gap count FILES still missing, matching the 'nanogen files' column).
hdr = (f"{'start':>6} {'stop':>6} {'pts':>5} | {'gridpacks':>13} | "
       f"{'run':>4} {'idle':>4} {'held':>4} {oth_h}{'gap':>4} {'card':>5} {'log':>5}{run_h} | "
       f"{'nanogen files':>15} | {'full':>11} | "
       f"{'run':>4} {'idle':>4} {'held':>4} {oth_h}{'gap':>4}{run_h}")
print(hdr); print("-"*len(hdr))

def runner_cell(owners):
    """Comma-joined distinct owners of a batch's 'oth' points, truncated to the column."""
    s = ",".join(sorted(owners))
    if len(s) > RUNW: s = s[:RUNW-1] + "…"
    return f" | {s:<{RUNW}}" if OTHCOL else ""

def cell(done, total, width):
    """'  99/100  ' right-aligned in `width`, suffixed with * when complete."""
    return f"{done}/{total}".rjust(width) + (" *" if done == total else "  ")

tp=tg=tn=tf=tr=ti=th=tx=to=0; tgc=tgl=0
tnr=tni=tnh=tno=tnx=0
all_owners = set(); all_nowners = set()
for lo,hi in BATCHES:
    n = hi-lo+1
    g = f = nf = r = idle = held = gap = oth = 0
    nr = nidle = nheld = ngap = noth = 0
    gap_card = gap_log = 0
    owners = set()                           # colleagues building points IN THIS batch
    nowners = set()                          # ... and running its nanogen jobs
    for i in range(lo,hi+1):
        name = point_name(pts[i-1])
        have = name+"_gridpack.tar.gz" in gp
        if have: g += 1
        st = queue.get(name, set())
        # A delivered point may still show a job (a stale resubmit); count queue
        # state only for points we do NOT yet have, so the columns explain the gap.
        if not have:
            if   2 in st: r    += 1          # my running job
            elif 1 in st: idle += 1          # my idle job
            elif 5 in st: held += 1          # my held job
            elif name in others:             # a colleague (--others) is building it
                oth += 1
                owners.add(owner_of[name])
            else:
                gap += 1                     # no file, no job: never submitted/lost
                if name in cards: gap_card += 1
                if name in logs:  gap_log  += 1
        c = 0
        for j in range(1, njobs+1):
            if delivered(name, j):
                c += 1
                continue
            # file not there yet: explain it the same way as for gridpacks
            nst = nqueue.get((name, str(j)), set())
            if   2 in nst: nr    += 1
            elif 1 in nst: nidle += 1
            elif 5 in nst: nheld += 1
            elif (name, str(j)) in nothers:
                noth += 1
                nowners.add(nowner_of[(name, str(j))])
            else:          ngap  += 1
        nf += c
        if c == njobs: f += 1
    tp+=n; tg+=g; tn+=nf; tf+=f; tr+=r; ti+=idle; th+=held; tx+=gap; to+=oth
    tnr+=nr; tni+=nidle; tnh+=nheld; tno+=noth; tnx+=ngap
    tgc+=gap_card; tgl+=gap_log; all_owners |= owners; all_nowners |= nowners
    oth_c  = f"{oth:>4} "  if OTHCOL else ""
    noth_c = f"{noth:>4} " if OTHCOL else ""
    print(f"{lo:>6} {hi:>6} {n:>5} | {cell(g,n,11)} | "
          f"{r:>4} {idle:>4} {held:>4} {oth_c}{gap:>4} "
          f"{yesno(gap_card,gap):>5} {yesno(gap_log,gap):>5}{runner_cell(owners)} | "
          f"{cell(nf,n*njobs,13)} | {cell(f,n,9)} | "
          f"{nr:>4} {nidle:>4} {nheld:>4} {noth_c}{ngap:>4}{runner_cell(nowners)}")

print("-"*len(hdr))
oth_t  = f"{to:>4} "  if OTHCOL else ""
noth_t = f"{tno:>4} " if OTHCOL else ""
print(f"{'TOTAL':>13} {tp:>5} | {cell(tg,tp,11)} | "
      f"{tr:>4} {ti:>4} {th:>4} {oth_t}{tx:>4} "
      f"{yesno(tgc,tx):>5} {yesno(tgl,tx):>5}{runner_cell(all_owners)} | "
      f"{cell(tn,tp*njobs,13)} | {cell(tf,tp,9)} | "
      f"{tnr:>4} {tni:>4} {tnh:>4} {noth_t}{tnx:>4}{runner_cell(all_nowners)}")
print("\n* = complete.  The FIRST run/idle/held/gap block counts points with NO gridpack yet;")
print("  the block after 'full' counts nanogen FILES still missing (njobs per point).")
if OTHCOL:
    print(f"  oth = a colleague ({os.environ.get('OTHERS','')}) has a job for it "
          "(pool-wide) -- excluded from gap, and from --resubmit-gaps on the gridpack side.")
    print("  gap = no file and NO job of mine OR of the --others owners.")
else:
    print("  gap = no file and no job of mine -- never submitted, lost, or someone else's.")
print("  NB nanogen's submit file sets periodic_remove on JobStatus==5, so its 'held'")
print("     is normally 0: a held nanogen job is removed and shows up as a gap instead.")
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
            if (name+"_gridpack.tar.gz" not in gp
                    and name not in queue and name not in others):
                gaps.append(i)
    gaps = sorted(set(gaps))
    runs = []
    for i in gaps:
        if runs and i == runs[-1][1] + 1: runs[-1][1] = i
        else: runs.append([i, i])
    flav = os.environ.get("FLAVOUR", "")
    extra = f" --flavour {flav}" if flav else ""
    # Carry the grid through so the submitter builds the right cards AND writes to the
    # matching gridpack dir (submit_smeft.sh defaults to 5d otherwise). Carry --ecm too
    # for non-default energies so the resubmit targets the same energy-tagged dirs.
    ecm_arg = f"--ecm {os.environ.get('ECM','')} " if os.environ.get("ECM_TAG") else ""
    gsel = f"--grid {grid} {ecm_arg}"
    with open(os.environ["GAPS_OUT"], "w") as fh:
        for a, b in runs:
            fh.write(f"{gsel}--start {a} --end {b} --only-missing{extra}\n")
    print(f"\ngridpack gaps: {len(gaps)} point(s) in {len(runs)} contiguous run(s)")
    if gaps:
        print("  " + ", ".join(f"{a}" if a == b else f"{a}-{b}" for a, b in runs))

    # NANOGEN resubmit: a point needs --only-missing if its gridpack IS ready (nanogen
    # can't run without it) but at least one of its njobs output files is absent and NOT
    # covered by a LIVE job -- i.e. no idle/running job of mine and no --others job. A
    # HELD job counts as needing resubmit: the submit file's periodic_remove kills it,
    # so it will never deliver. submit_nanogen.sh --only-missing then re-queues exactly
    # the missing (point,gjob) files, skipping any that landed in the meantime, so it is
    # safe to emit at the whole-range level. NB clear held jobs first (condor_rm) or the
    # resubmit runs alongside them until periodic_remove fires.
    ngaps = []
    for lo, hi in BATCHES:
        for i in range(lo, hi+1):
            name = point_name(pts[i-1])
            if name+"_gridpack.tar.gz" not in gp:      # no gridpack: nanogen can't run yet
                continue
            needs = False
            for j in range(1, njobs+1):
                if delivered(name, j):                  # already delivered
                    continue
                nst = nqueue.get((name, str(j)), set())
                if 2 in nst or 1 in nst:                # my live (running/idle) job: leave it
                    continue
                if (name, str(j)) in nothers:           # a colleague is running it
                    continue
                needs = True                            # held or truly absent -> resubmit
                break
            if needs:
                ngaps.append(i)
    ngaps = sorted(set(ngaps))
    nruns = []
    for i in ngaps:
        if nruns and i == nruns[-1][1] + 1: nruns[-1][1] = i
        else: nruns.append([i, i])
    nflav = os.environ.get("FLAVOUR", "")
    nextra = f" --flavour {nflav}" if nflav else ""
    if backend == "crab":
        # CRAB is one TASK per point (no index-based seed windows), so a gap is closed by
        # `crab resubmit` on that point's existing task -- NEVER by submit_nanogen, which
        # would reuse job-number seeds and duplicate events. For each gap point: if its
        # CRAB project dir (<workArea>/crab_<req>) exists we emit a resubmit line; if not,
        # the point was never submitted to CRAB and needs an INITIAL --backend crab submit.
        workarea = os.environ.get("CRAB_WORKAREA", "")
        resub, missing = [], []
        for i in ngaps:
            req = req_of(point_name(pts[i-1]))
            projdir = os.path.join(workarea, "crab_" + req)
            (resub if os.path.isdir(projdir) else missing).append((i, projdir))
        with open(os.environ["CRAB_RESUB_OUT"], "w") as fh:
            for i, projdir in resub:
                fh.write(f"{i}\t{projdir}\n")
        # never-submitted points -> contiguous ranges for an initial crab submit
        mruns = []
        for i, _ in missing:
            if mruns and i == mruns[-1][1] + 1: mruns[-1][1] = i
            else: mruns.append([i, i])
        with open(os.environ["CRAB_MISSING_OUT"], "w") as fh:
            for a, b in mruns:
                fh.write(f"{gsel}--start {a} --end {b} --backend crab\n")
        open(os.environ["NGAPS_OUT"], "w").close()   # skip the condor submit_nanogen path
        print(f"nanogen gaps (crab): {len(ngaps)} point(s) -- "
              f"{len(resub)} with a task to resubmit, {len(missing)} not yet submitted")
        if ngaps:
            print("  " + ", ".join(f"{a}" if a == b else f"{a}-{b}" for a, b in nruns))
    else:
        with open(os.environ["NGAPS_OUT"], "w") as fh:
            for a, b in nruns:
                fh.write(f"{gsel}--start {a} --end {b} --only-missing{nextra}\n")
        print(f"nanogen gaps: {len(ngaps)} point(s) with missing files in {len(nruns)} run(s)")
        if ngaps:
            print("  " + ", ".join(f"{a}" if a == b else f"{a}-{b}" for a, b in nruns))
EOF

# ---------------------------------------------------------------------------
# --gaps / --resubmit-gaps
# ---------------------------------------------------------------------------
[ "$GAPS" = 1 ] || [ "$RESUBMIT" = 1 ] || [ "$RESUBMIT_NANO" = 1 ] || exit 0

# ---------------------------------------------------------------------------
# NANOGEN gap resubmit -- CRAB backend
# ---------------------------------------------------------------------------
# Under --backend crab a gap is closed per-point: `crab resubmit` on the point's existing
# task if its CRAB project dir exists, else an INITIAL submit for a point never sent to
# CRAB. We PRINT the commands (crab resubmit is per-task and needs the crab client; the
# initial submit isn't idempotent) -- report_batches never auto-runs them here.
if [ "$BACKEND" = crab ]; then
  if [ -s "$TMP/crab_resub.txt" ]; then
    echo
    echo ">> CRAB resubmit commands for incomplete tasks (run from $HERE, after"
    echo "   'source /cvmfs/cms.cern.ch/common/crab-setup.sh'):"
    while IFS="$(printf '\t')" read -r idx projdir; do
      echo "   crab resubmit -d $projdir   # point $idx"
    done < "$TMP/crab_resub.txt"
  fi
  if [ -s "$TMP/crab_missing.txt" ]; then
    echo
    echo ">> ranges with NO CRAB task yet -- these need an INITIAL submission (run from $HERE):"
    while read -r a; do echo "   ./submit_nanogen.sh $a"; done < "$TMP/crab_missing.txt"
  fi
  if [ ! -s "$TMP/crab_resub.txt" ] && [ ! -s "$TMP/crab_missing.txt" ]; then
    echo; echo ">> no nanogen gaps (crab): every counted point is complete."
  fi
  if [ "$RESUBMIT_NANO" = 1 ]; then
    echo
    echo ">> --resubmit-nano (crab): the commands above are NOT auto-run. Run the"
    echo "   'crab resubmit' lines yourself; submit_nanogen for a range with no task yet."
  fi
else
# ---------------------------------------------------------------------------
# NANOGEN --only-missing resubmit (condor; printed always, auto-run with --resubmit-nano)
# ---------------------------------------------------------------------------
# submit_nanogen.sh now gives EACH run its OWN per-run fragment dir, so a later range's
# fragment regen can never delete an earlier range's still-needed inputs. That removes the
# old "held on: input file No such file or directory" race, so ranges can be fired
# back-to-back with NO drain wait between them.
NANO_SUBMITTER=$HERE/submit_nanogen.sh
if [ -s "$TMP/ngaps.txt" ]; then
  echo
  echo ">> NANOGEN --only-missing commands (run from $HERE):"
  while read -r a; do echo "   ./$(basename "$NANO_SUBMITTER") $a"; done < "$TMP/ngaps.txt"
fi

if [ "$RESUBMIT_NANO" = 1 ]; then
  if [ ! -s "$TMP/ngaps.txt" ]; then
    echo; echo ">> --resubmit-nano: no nanogen gaps to resubmit."
  else
    NR=$(wc -l < "$TMP/ngaps.txt")
    if [ "$DRYRUN" = 1 ]; then
      echo; echo ">> DRY RUN: would submit $NR nanogen range(s) back-to-back."
      echo "   Nothing submitted; each real run makes its own fragment dir (no wait needed)."
    else
      [ -x "$NANO_SUBMITTER" ] || { echo "!! not executable: $NANO_SUBMITTER" >&2; exit 1; }
      if [ "$ASSUME_YES" != 1 ]; then
        echo
        echo "!! --resubmit-nano will submit $NR nanogen range(s) back-to-back (each in its own"
        echo "!! fragment dir, so no drain wait is needed). --only-missing skips delivered files."
        printf ">> proceed? [y/N] "
        read -r ans </dev/tty 2>/dev/null || ans=n
        case $ans in [yY]*) ;; *) echo ">> aborted, nothing submitted."; exit 0;; esac
      fi
      cd "$HERE"
      i=0; nsub=0; rc=0
      while read -r a; do
        i=$((i + 1))
        echo; echo ">> [$i/$NR] $(basename "$NANO_SUBMITTER") $a"
        # shellcheck disable=SC2086
        out=$("$NANO_SUBMITTER" $a 2>&1) || rc=1; echo "$out"
        cl=$(printf '%s\n' "$out" | grep -oE 'submitted to cluster [0-9]+' | grep -oE '[0-9]+' | tail -1)
        if [ -n "$cl" ]; then nsub=$((nsub + 1)); else
          echo "   (no cluster submitted for this range -- nothing missing, or a skip.)"
        fi
      done < "$TMP/ngaps.txt"
      echo; echo ">> --resubmit-nano finished: $nsub cluster(s) submitted over $i range(s)."
      exit $rc
    fi
  fi
fi
fi   # end BACKEND condor/crab nanogen branch

[ "$GAPS" = 1 ] || [ "$RESUBMIT" = 1 ] || exit 0    # --resubmit-nano only: done above
[ -s "$TMP/gaps.txt" ] || { echo; echo ">> no gridpack gaps to resubmit."; exit 0; }

echo
echo ">> gridpack resubmit commands (run from $(cd "$(dirname "$SUBMITTER")" && pwd)):"
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
