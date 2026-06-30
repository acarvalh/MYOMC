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
GRIDPACK_DIR=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks
OUTPUT_DIR=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen
RUN_SH=$MYOMC/campaigns/NANOGEN/run.sh
TOTAL_EVENTS=100000                          # total events per point
NJOBS_PER_POINT=5                            # jobs per point (events/job = total/njobs)
COMENERGY=13600                              # Run 3 centre-of-mass energy (GeV)
NTHREADS=1                                   # cmsRun threads (== request_cpus)
MEM=4000                                     # request_memory (MB)
FLAVOUR=testmatch                            # 72h queue (condor backend)
BACKEND=condor                               # condor | crab
STORAGE_SITE=T3_CH_CERNBOX                   # CRAB Site.storageSite (T3_CH_CERNBOX = /eos/user)
OUTPUT_LFN=/store/user/acarvalh/smeft_nanogen # CRAB Data.outLFNDirBase
DRYRUN=0
REPORT=0                                     # --report: only print status, no submit
ONLY_MISSING=0                               # --only-missing: submit only not-done jobs

while [ $# -gt 0 ]; do
  case "$1" in
    --ncards)   NCARDS=$2; shift 2;;
    --start)    START=$2; shift 2;;
    --end)      END=$2; shift 2;;
    --fragdir)  FRAGDIR=$2; shift 2;;
    --gridpack-dir) GRIDPACK_DIR=$2; shift 2;;
    --outdir)   OUTPUT_DIR=$2; shift 2;;
    --njobs)    NJOBS_PER_POINT=$2; shift 2;;
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
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

case "$BACKEND" in condor|crab) ;; *) echo "--backend must be condor or crab" >&2; exit 1;; esac

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

cd "$HERE"
mkdir -p logs "$FRAGDIR"

# 1) Generate the per-point fragments (+ manifest.json). Wipe stale ones first:
#    fragment names encode couplings, so a changed range yields NEW names that
#    would otherwise pile up next to the old ones (-> extra jobs).
#    CRAB embeds the fragment in the cfg, so it needs the xrootd gridpack path
#    baked in (--gridpack-base); condor substitutes a local path at runtime.
GP_BAKE=()
[ "$BACKEND" = "crab" ] && GP_BAKE=(--gridpack-base "$GRIDPACK_DIR")
rm -f "$FRAGDIR"/*.py "$FRAGDIR"/manifest.json
if [ "$START" -gt 0 ] || [ "$END" -gt 0 ]; then
  echo ">> generating fragments (points $START..$END) into $FRAGDIR"
  python3 "$HERE/make_fragments.py" --outdir "$FRAGDIR" --start "$START" --end "$END" \
          --nevents "$NEVENTS" --comenergy "$COMENERGY" "${GP_BAKE[@]}"
else
  echo ">> generating fragments (nmax=$NCARDS) into $FRAGDIR"
  python3 "$HERE/make_fragments.py" --outdir "$FRAGDIR" --nmax "$NCARDS" \
          --nevents "$NEVENTS" --comenergy "$COMENERGY" "${GP_BAKE[@]}"
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

# 2) Build joblist.txt: one line per (point, jobindex), gated on gridpack
#    readiness and (for --report/--only-missing) per-job NANOGEN completion.
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
  for j in $(seq 1 "$NJOBS_PER_POINT"); do
    if [ -n "${NANO_DONE[NANOGEN_${point}_${j}.root]:-}" ]; then
      n_done=$((n_done + 1)); pdone=$((pdone + 1))
      # full resubmit re-queues done jobs; --only-missing / --report drop them
      if [ "$REPORT" != "1" ] && [ "$ONLY_MISSING" != "1" ]; then
        printf '%s, %s, %d\n' "$point" "$frag" "$j" >> joblist.txt
      fi
    else
      n_missing=$((n_missing + 1))
      [ "$REPORT" != "1" ] && printf '%s, %s, %d\n' "$point" "$frag" "$j" >> joblist.txt
    fi
  done
  [ "$REPORT" = "1" ] && echo "   [ready]       $point — $pdone/$NJOBS_PER_POINT NANOGEN done"
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
REQUEST_MEM="${MEM}M"
SUBMIT_ARGS=(
  -append "GRIDPACK_DIR=$GRIDPACK_DIR"
  -append "OUTPUT_DIR=$OUTPUT_DIR"
  -append "RUN_SH=$RUN_SH"
  -append "NEVENTS=$NEVENTS"
  -append "NTHREADS=$NTHREADS"
  -append "REQUEST_MEM=$REQUEST_MEM"
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
