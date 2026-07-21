#!/bin/bash
# Driver: generate NANOGEN fragments for a range of ggHH_SMEFT points and submit
# one Condor job per (point, jobindex). NJOBS_PER_POINT jobs of NEVENTS each give
# 100k events/point by default (5 x 20k). Point selection (--start/--end) matches
# the gridpack driver submit_smeft.sh.
#
# Two backends (--backend): HTCondor (default) or CRAB.
#
# Examples:
#   ./submit_nanogen.sh --ncards 3                 # test: first 3 points (condor)
#   ./submit_nanogen.sh --start 4 --end 500        # points 4..500 (1-based incl.)
#   ./submit_nanogen.sh --start 4 --end 500 --total-events 200000 --njobs 10
#   ./submit_nanogen.sh --ncards 0                 # all points in the JSON
#   ./submit_nanogen.sh --start 4 --end 500 --backend crab   # one CRAB task/point
#   ./submit_nanogen.sh --ncards 0 --report        # report gridpack/NANOGEN status
#   ./submit_nanogen.sh --ncards 0 --only-missing  # (re)submit only not-done jobs
#   ./submit_nanogen.sh --ncards 3 --hard-only     # no Pythia shower: hard scattering only
#   ./submit_nanogen.sh --ncards 0 --test          # 1 job x 100 evts, first ready gridpack
#
# Gridpack gating: a point's jobs are only queued once <point>_gridpack.tar.gz is
# present in --gridpack-dir (points still waiting for their gridpack are skipped).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GEN_DIR=${GEN_DIR:-/afs/cern.ch/work/a/acarvalh/generation_k4}
MYOMC=${MYOMC:-$(cd "$HERE/.." && pwd)}

# -------- defaults (override via flags) --------
NCARDS=3                                    # how many points (0 = all); ignored if START/END set
START=0                                     # first point, 1-based inclusive (0 = beginning)
END=0                                       # last point, 1-based inclusive (0 = end)
FRAGDIR=$HERE/fragments                      # where generated fragments go
# Grid selection: --grid picks which BUNDLED points JSON drives fragment names AND the
# matching default gridpack set + nanogen output dir. 4d = leading-only (no CtG, names
# omit _CtG_); 5d = leading + CtG; 9d = leading + CtG + the four four-top operators (the
# 9D extension). Fragment names must match the gridpack names, so grid, gridpack dir and
# nanogen output dir are paired. For 9d everything lives under smeft_nanogen_9d/.
GRID=5d                                      # 4d | 5d | 9d
POINTS=""                                    # explicit points JSON; overrides --grid
GPDIR_4D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_keep_stage1
GPDIR_5D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_5param_keep_stage1
GPDIR_9D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen_9d/gridpacks
# Nanogen output dir per grid: 4d/5d share the original smeft_nanogen; 9d is self-contained.
NANO_4D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen
NANO_5D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen
NANO_9D=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen_9d/nanogen
GRIDPACK_DIR=""                              # empty => derive from --grid; --gridpack-dir overrides
OUTPUT_DIR=""                                # empty => derive from --grid; --outdir overrides
RUN_SH=$MYOMC/campaigns/NANOGEN/run.sh
# Fix-files shipped into every job so run_nanogen.sh can self-heal the staged
# gridpack (older assemblies shipped WITHOUT creategrid.py and with an unpatched
# runcmsgrid.sh). Both are generic (point-independent) and physics-neutral, and are
# BUNDLED in this repo (beside this script) so a fresh MYOMC clone is self-contained
# — no reach into the external generation_k4 / POWHEG-BOX tree. Override if needed.
CREATEGRID_PY=${CREATEGRID_PY:-$HERE/creategrid.py}
FIXED_RUNCMSGRID=${FIXED_RUNCMSGRID:-$HERE/runcmsgrid.sh}
TOTAL_EVENTS=50000                           # total events/point (5 jobs x 10k)
NJOBS_PER_POINT=5                            # jobs per point (events/job = total/njobs = 10k)
JOB_OFFSET=0                                  # add to jobidx -> global job number gjob (for COLLISION-FREE
                                              # top-ups: a second batch of N jobs uses --job-offset <already-done>
                                              # so it gets fresh seed windows AND fresh output filenames).
# Seed-window geometry (keep in sync with campaigns/NANOGEN/run.sh + condor/runcmsgrid.sh):
# each (point,gjob) owns a disjoint window [base, base+JOB_STRIDE), base = index*POINT_STRIDE
# + gjob*JOB_STRIDE. index = UNIQUE JSON index (no hash collisions). All seeds inside the
# window (LHE base+1, Pythia base+2, cores base+10+i) => globally collision-free. Ceiling:
# (MAXP-1)*POINT_STRIDE + (JOB_STRIDE geometry) < 900000000 (CMS/Pythia8 RNG limit).
POINT_STRIDE=100000                           # seed span reserved per point (room for up to 99 gjobs)
JOB_STRIDE=1000                               # seed span reserved per (point,gjob) window
MAXP=9000                                     # max supported JSON index (9000*100000 = 9e8 ceiling)
COMENERGY=13600                              # Run 3 centre-of-mass energy (GeV)
# NTHREADS flows through as ncpu to the gridpack's runcmsgrid.sh (via
# run_generic_tarball_cvmfs.sh), which now runs that many parallel POWHEG streams
# (~Nx wall speedup; gg->HH is ~11 CPU-s/event). Also = request_cpus and cmsRun
# --nThreads. 10k events / 4 streams ~= 2500 evt/stream x 11s ~= 7.6h + build.
NTHREADS=4                                   # parallel POWHEG streams == request_cpus
MEM=8000                                     # request_memory (MB); ~4 pwhg_main + cmsRun
FLAVOUR=testmatch                            # 72h queue (condor backend)
BACKEND=condor                               # condor | crab
STORAGE_SITE=T3_CH_CERNBOX                   # CRAB Site.storageSite (T3_CH_CERNBOX = /eos/user)
OUTPUT_LFN=/store/user/acarvalh/smeft_nanogen # CRAB Data.outLFNDirBase
DRYRUN=0
REPORT=0                                     # --report: only print status, no submit
ONLY_MISSING=0                               # --only-missing: submit only not-done jobs
HARD_ONLY=1                                  # DEFAULT: hard scattering only (no Pythia shower). Use --with-shower to enable shower/hadronization.
TEST=0                                        # --test: 1 job x 100 evts on the FIRST ready gridpack

while [ $# -gt 0 ]; do
  case "$1" in
    --ncards)   NCARDS=$2; shift 2;;
    --start)    START=$2; shift 2;;
    --end)      END=$2; shift 2;;
    --fragdir)  FRAGDIR=$2; shift 2;;
    --gridpack-dir) GRIDPACK_DIR=$2; shift 2;;
    --grid)     GRID=$2; shift 2;;
    --points)   POINTS=$2; shift 2;;
    --outdir)   OUTPUT_DIR=$2; shift 2;;
    --njobs)    NJOBS_PER_POINT=$2; shift 2;;
    --job-offset) JOB_OFFSET=$2; shift 2;;
    --total-events) TOTAL_EVENTS=$2; shift 2;;
    --comenergy) COMENERGY=$2; shift 2;;
    --nthreads) NTHREADS=$2; shift 2;;
    --mem)      MEM=$2; shift 2;;
    --flavour)  FLAVOUR=$2; shift 2;;
    --backend)  BACKEND=$2; shift 2;;
    --storage-site) STORAGE_SITE=$2; shift 2;;
    --output-lfn)   OUTPUT_LFN=$2; shift 2;;
    --dry-run)  DRYRUN=1; shift;;
    --report|--status)            REPORT=1; shift;;
    --only-missing|--resubmit-missing) ONLY_MISSING=1; shift;;
    --hard-only|--no-shower)      HARD_ONLY=1; shift;;
    --with-shower|--shower)       HARD_ONLY=0; shift;;   # opt back INTO Pythia shower/hadronization
    --test|--smoke)               TEST=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

case "$BACKEND" in condor|crab) ;; *) echo "--backend must be condor or crab" >&2; exit 1;; esac

# Resolve the grid selection into a bundled points JSON + default gridpack set. An
# explicit --points / --gridpack-dir overrides the derived default. Fragment names are
# built from $POINTS (see make_fragments.py), so $POINTS must match $GRIDPACK_DIR.
case "$GRID" in
  4d) GRID_JSON=$HERE/FINALgrid_for_SMEFT_4D_leadingOnly_updated_PDF.json; GRID_GPDIR=$GPDIR_4D; GRID_NANO=$NANO_4D;;
  5d) GRID_JSON=$HERE/FINALgrid_for_SMEFT_5D_leading_plus_ctg.json;        GRID_GPDIR=$GPDIR_5D; GRID_NANO=$NANO_5D;;
  9d) GRID_JSON=$HERE/FINALgrid_for_SMEFT_9D_extension_only.json;          GRID_GPDIR=$GPDIR_9D; GRID_NANO=$NANO_9D;;
  *)  echo "--grid must be 4d, 5d or 9d" >&2; exit 1;;
esac
[ -n "$POINTS" ]       || POINTS=$GRID_JSON
[ -n "$GRIDPACK_DIR" ] || GRIDPACK_DIR=$GRID_GPDIR
[ -n "$OUTPUT_DIR" ]   || OUTPUT_DIR=$GRID_NANO
[ -f "$POINTS" ] || { echo "ERROR: points JSON not found: $POINTS" >&2; exit 1; }
echo ">> grid=$GRID  points=$(basename "$POINTS")  gridpacks=$GRIDPACK_DIR  nanogen=$OUTPUT_DIR"

# --test: quick single-job smoke test on the FIRST gridpack-ready point in the
# selection. Force 100 events in ONE job, and (below) queue only that one point.
# Condor-only: CRAB's per-point PrivateMC splitting doesn't fit a 1-job probe.
if [ "$TEST" = "1" ]; then
  [ "$BACKEND" = "crab" ] && { echo "--test is HTCondor-only (drop --backend crab)" >&2; exit 1; }
  TOTAL_EVENTS=100
  NJOBS_PER_POINT=1
  echo ">> TEST MODE: 1 job x 100 events on the first ready gridpack in the selection"
fi

# List basenames of files in a dir/URL (EOS via xrootd, or a local path).
list_dir_basenames() {
  local url=$1
  case "$url" in
    root://*)
      local rest=${url#root://}; local host=${rest%%/*}; local path=${rest#"$host"}
      xrdfs "$host" ls "$path" 2>/dev/null | sed 's#.*/##' ;;
    /eos/*)
      ls -1 "$url" 2>/dev/null || xrdfs eosuser.cern.ch ls "$url" 2>/dev/null | sed 's#.*/##' ;;
    *)
      ls -1 "$url" 2>/dev/null ;;
  esac
}

# Events per job = total / njobs (must divide evenly so the per-point total is exact).
if [ "$NJOBS_PER_POINT" -lt 1 ]; then echo "--njobs must be >= 1" >&2; exit 1; fi
if [ $(( TOTAL_EVENTS % NJOBS_PER_POINT )) -ne 0 ]; then
  echo "ERROR: --total-events ($TOTAL_EVENTS) must be divisible by --njobs ($NJOBS_PER_POINT)" >&2
  exit 1
fi
NEVENTS=$(( TOTAL_EVENTS / NJOBS_PER_POINT ))
echo ">> $TOTAL_EVENTS events/point = $NJOBS_PER_POINT jobs x $NEVENTS events"

# Seed-window guards: the highest global job for this batch must fit inside a point's
# reserved POINT_STRIDE, and the reserved cores (base+10+NTHREADS) inside JOB_STRIDE.
MAX_GJOB=$(( JOB_OFFSET + NJOBS_PER_POINT ))
if [ "$JOB_OFFSET" -lt 0 ]; then echo "--job-offset must be >= 0" >&2; exit 1; fi
if [ $(( MAX_GJOB * JOB_STRIDE )) -ge "$POINT_STRIDE" ]; then
  echo "ERROR: job-offset+njobs ($MAX_GJOB) exceeds the per-point window (max $(( POINT_STRIDE / JOB_STRIDE - 1 )) global jobs)." >&2
  exit 1
fi
if [ $(( 10 + NTHREADS )) -ge "$JOB_STRIDE" ]; then
  echo "ERROR: NTHREADS ($NTHREADS) too large for the per-(point,job) seed window (JOB_STRIDE=$JOB_STRIDE)." >&2
  exit 1
fi
[ "$JOB_OFFSET" -gt 0 ] && echo ">> job-offset $JOB_OFFSET: this batch uses global jobs $(( JOB_OFFSET + 1 ))..$MAX_GJOB (fresh seed windows + output names)"

cd "$HERE"
mkdir -p logs "$FRAGDIR"

# 1) Generate the per-point fragments (+ manifest.json). Wipe stale ones first:
#    fragment names encode couplings, so a changed range yields NEW names that
#    would otherwise pile up next to the old ones (-> extra jobs).
#    CRAB embeds the fragment in the cfg, so it needs the xrootd gridpack path
#    baked in (--gridpack-base); condor substitutes a local path at runtime.
GP_BAKE=()
[ "$BACKEND" = "crab" ] && GP_BAKE=(--gridpack-base "$GRIDPACK_DIR")
HARD_BAKE=()
[ "$HARD_ONLY" = "1" ] && { HARD_BAKE=(--hard-only); echo ">> hard-only: Pythia shower/hadronization OFF (hard scattering only)"; }
rm -f "$FRAGDIR"/*.py "$FRAGDIR"/manifest.json
if [ "$START" -gt 0 ] || [ "$END" -gt 0 ]; then
  echo ">> generating fragments (points $START..$END) into $FRAGDIR"
  python3 "$HERE/make_fragments.py" --points "$POINTS" --outdir "$FRAGDIR" --start "$START" --end "$END" \
          --nevents "$NEVENTS" --comenergy "$COMENERGY" "${GP_BAKE[@]}" "${HARD_BAKE[@]}"
else
  echo ">> generating fragments (nmax=$NCARDS) into $FRAGDIR"
  python3 "$HERE/make_fragments.py" --points "$POINTS" --outdir "$FRAGDIR" --nmax "$NCARDS" \
          --nevents "$NEVENTS" --comenergy "$COMENERGY" "${GP_BAKE[@]}" "${HARD_BAKE[@]}"
fi

# ----- CRAB backend: one PrivateMC task per point (CRAB splits total/njobs) -----
if [ "$BACKEND" = "crab" ]; then
  if [ "$REPORT" = "1" ] || [ "$ONLY_MISSING" = "1" ]; then
    echo "NOTE: --report/--only-missing are HTCondor-backend features; with CRAB use" >&2
    echo "      'crab status -d crab_nanogen/crab_<point>' and CRAB resubmit instead." >&2
    exit 1
  fi
  NPOINTS=$(ls -1 "$FRAGDIR"/*.py | wc -l)
  echo ">> CRAB backend: $NPOINTS task(s), $TOTAL_EVENTS evts/point split into jobs of $NEVENTS"
  FRAGDIR="$FRAGDIR" OUTPUT_LFN="$OUTPUT_LFN" STORAGE_SITE="$STORAGE_SITE" \
  TOTAL_EVENTS="$TOTAL_EVENTS" NEVENTS="$NEVENTS" NTHREADS="$NTHREADS" MEM="$MEM" \
  RUN_SH="$RUN_SH" DRYRUN="$DRYRUN" \
    bash "$HERE/submit_crab.sh"
  exit $?
fi

# ----- HTCondor backend (default): one job per (point, jobindex) -----
# Completion inputs: which gridpacks are ready, and which NANOGEN outputs exist.
echo ">> checking gridpacks in $GRIDPACK_DIR"
echo ">>     and NANOGEN outputs in $OUTPUT_DIR"
declare -A GP_READY=()
while IFS= read -r f; do [ -n "$f" ] && GP_READY["$f"]=1; done \
  < <(list_dir_basenames "$GRIDPACK_DIR" | grep '_gridpack\.tar\.gz$' || true)
declare -A NANO_DONE=()
while IFS= read -r f; do [ -n "$f" ] && NANO_DONE["$f"]=1; done \
  < <(list_dir_basenames "$OUTPUT_DIR" | grep '^NANOGEN_.*\.root$' || true)

# Map each point name -> its UNIQUE JSON index (from make_fragments' manifest). This
# index seeds the collision-free windows (base = index*POINT_STRIDE + gjob*JOB_STRIDE),
# so distinct points can never share a seed the way a crc32 hash occasionally could.
declare -A PIDX=()
while IFS=$'\t' read -r nm idx; do [ -n "$nm" ] && PIDX["$nm"]=$idx; done \
  < <(python3 -c "import json,sys
for m in json.load(open(sys.argv[1])): print(m['name']+'\t'+str(m['index']))" "$FRAGDIR/manifest.json")

# 2) Build joblist.txt: one line per (point, gjob) = "point, fragment, gjob, rbase",
#    gated on gridpack readiness and (for --report/--only-missing) NANOGEN completion.
#    gjob = JOB_OFFSET + jobidx (global job number); rbase = precomputed seed-window base.
: > joblist.txt
n_ready=0; n_nogp=0; n_done=0; n_missing=0
for frag in "$FRAGDIR"/*.py; do
  point=$(basename "$frag" .py)
  # Gate: skip the whole point until its gridpack exists on EOS.
  if [ -z "${GP_READY[${point}_gridpack.tar.gz]:-}" ]; then
    n_nogp=$((n_nogp + 1))
    [ "$REPORT" = "1" ] && echo "   [no-gridpack] $point"
    continue
  fi
  n_ready=$((n_ready + 1))
  pdone=0
  pidx=${PIDX[$point]:-}
  if [ -z "$pidx" ]; then echo "ERROR: no JSON index for $point in manifest" >&2; exit 1; fi
  if [ "$pidx" -ge "$MAXP" ]; then echo "ERROR: point index $pidx >= $MAXP (seed ceiling) for $point" >&2; exit 1; fi
  for j in $(seq 1 "$NJOBS_PER_POINT"); do
    gjob=$(( JOB_OFFSET + j ))                              # global job number: seed + output discriminator
    rbase=$(( pidx * POINT_STRIDE + gjob * JOB_STRIDE ))    # lower edge of this (point,gjob) seed window
    if [ -n "${NANO_DONE[NANOGEN_${point}_${gjob}.root]:-}" ]; then
      n_done=$((n_done + 1)); pdone=$((pdone + 1))
      # full resubmit re-queues done jobs; --only-missing / --report drop them
      if [ "$REPORT" != "1" ] && [ "$ONLY_MISSING" != "1" ]; then
        printf '%s, %s, %d, %d\n' "$point" "$frag" "$gjob" "$rbase" >> joblist.txt
      fi
    else
      n_missing=$((n_missing + 1))
      [ "$REPORT" != "1" ] && printf '%s, %s, %d, %d\n' "$point" "$frag" "$gjob" "$rbase" >> joblist.txt
    fi
  done
  [ "$REPORT" = "1" ] && echo "   [ready]       $point — $pdone/$NJOBS_PER_POINT NANOGEN done"
  # --test: stop after the first gridpack-ready point (only its single job is queued).
  [ "$TEST" = "1" ] && { echo ">> TEST MODE: using first ready point $point"; break; }
done
echo ">> points: $n_ready gridpack-ready, $n_nogp waiting for gridpack"
echo ">> NANOGEN jobs in ready points: $n_done done, $n_missing missing"

# 2a) Report-only mode: stop here (no proxy, no submit).
if [ "$REPORT" = "1" ]; then
  echo ">> --report: nothing submitted."
  exit 0
fi

NJOBS=$(wc -l < joblist.txt)
if [ "$NJOBS" -eq 0 ]; then
  if [ "$n_ready" -eq 0 ]; then
    echo ">> nothing to submit — no gridpacks ready yet for the selection."
  else
    echo ">> nothing to submit — all NANOGEN jobs for ready gridpacks are done."
  fi
  exit 0
fi
if [ "$ONLY_MISSING" = "1" ]; then
  echo ">> --only-missing: queuing $NJOBS not-yet-done job(s)"
else
  echo ">> queuing $NJOBS job(s)"
fi

# 3) Ensure the EOS output directory exists (jobs only copy files, not mkdir).
case "$OUTPUT_DIR" in
  root://eosuser.cern.ch//eos/*)
    EOSPATH=${OUTPUT_DIR#root://eosuser.cern.ch/}
    echo ">> ensuring EOS dir $EOSPATH"
    eos mkdir -p "$EOSPATH" 2>/dev/null || mkdir -p "$EOSPATH" 2>/dev/null || \
      echo "   (could not pre-create; create it manually: eos mkdir -p $EOSPATH)";;
  /eos/*|*) mkdir -p "$OUTPUT_DIR" 2>/dev/null || true;;
esac

# 4) Ensure a usable grid proxy (jobs xrdcp gridpacks from / NANOGEN to EOS).
#    Skipped on --dry-run so it never prompts for a VOMS password.
PROXY=${X509_USER_PROXY:-$HOME/private/x509up}
if [ "$DRYRUN" != "1" ]; then
  if ! voms-proxy-info -exists -file "$PROXY" --valid 24:00 2>/dev/null; then
    echo ">> creating a 72h grid proxy at $PROXY"
    mkdir -p "$(dirname "$PROXY")"
    voms-proxy-init -voms cms -out "$PROXY" -valid 72:00
  fi
  export X509_USER_PROXY=$PROXY
fi

# 5) Submit (or dry-run).
# Memory in bare megabytes (no "M" suffix). The macro must NOT be named request_* :
# HTCondor reads any `request_<x>` submit command as a CUSTOM RESOURCE request, so a
# macro called REQUEST_MEM made condor invent a resource "MEM" (RequestMEM=4000) and
# inject `TARGET.MEM >= RequestMEM` into Requirements. No worker advertises MEM, so
# the job matched 0 slots and sat idle forever. NANOGEN_MEM_MB dodges that prefix.
NANOGEN_MEM_MB="${MEM}"
# Preflight: the self-heal fix-files must exist to be shipped into the jobs.
for f in "$CREATEGRID_PY" "$FIXED_RUNCMSGRID"; do
  [ -f "$f" ] || { echo "ERROR: fix-file missing: $f" >&2; exit 1; }
done
SUBMIT_ARGS=(
  -append "GRIDPACK_DIR=$GRIDPACK_DIR"
  -append "OUTPUT_DIR=$OUTPUT_DIR"
  -append "RUN_SH=$RUN_SH"
  -append "CREATEGRID_PY=$CREATEGRID_PY"
  -append "FIXED_RUNCMSGRID=$FIXED_RUNCMSGRID"
  -append "NEVENTS=$NEVENTS"
  -append "NTHREADS=$NTHREADS"
  -append "NANOGEN_MEM_MB=$NANOGEN_MEM_MB"
  -append "request_cpus=$NTHREADS"
  -append "+JobFlavour=\"$FLAVOUR\""
)
if [ "$DRYRUN" = "1" ]; then
  echo ">> DRY RUN — would submit with:"; printf '   %s\n' "${SUBMIT_ARGS[@]}"
  echo ">> joblist.txt head:"; head -6 joblist.txt
else
  echo ">> submitting to HTCondor ($FLAVOUR / 72h)"
  condor_submit "${SUBMIT_ARGS[@]}" submit_nanogen.sub
fi
