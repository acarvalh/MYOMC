#!/bin/bash
# Driver: build ggHH gridpacks for the HEFT anomalous-coupling BENCHMARK basis
# (gghh_heft_basis.csv), one Condor job per benchmark point. BASIS-ONLY -- this is
# a self-contained production intended to extract the per-benchmark cross sections
# (default 14 TeV).
#
# SEPARATE from the SMEFT production (submit_smeft.sh): its own card generator
# (makeHEFTCards.py) + template (powheg-2-heft.input, usesmeft 0) + EOS output +
# logs. It REUSES the shared per-job executable (run_smeft_gridpack.sh, card-
# agnostic) and the shared submit file (submit_smeft.sub). NO SMEFT->HEFT mapping
# is done anywhere; the CSV's kappa_lambda/kappa_t/c2/cg/c2g go straight into the
# HEFT card's chhh/ct/ctt/cggh/cgghh.
#
# The 23 basis points come from the CSV; 5 VALIDATION points (validation_points.csv:
# VAL_SM plus single-coupling VAL_kl5, VAL_kl2p45, VAL_c2_3, VAL_c2g_1 -- each one
# coupling off-SM, rest SM) are appended by default. --no-validation drops them.
#
# Examples:
#   ./submit_heft.sh                          # 23 basis + 5 validation = 28 pts, 14 TeV
#   ./submit_heft.sh --no-validation          # the 23 basis points only
#   ./submit_heft.sh --points BM1,VAL_kl5     # a named subset (basis and/or validation)
#   ./submit_heft.sh --ncards 3               # first 3 benchmarks (test)
#   ./submit_heft.sh --dry-run                # build cards + cards.list, submit nothing
#   ./submit_heft.sh --test                   # coarse smoke build of the FIRST benchmark
#   ./submit_heft.sh --report                 # only report which gridpacks are done
#   ./submit_heft.sh --only-missing           # (re)submit only not-yet-done benchmarks
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GEN_DIR=${GEN_DIR:-$HERE}

# -------- defaults (override via flags) --------
CSV=${CSV:-$GEN_DIR/gghh_heft_basis.csv}   # in-repo copy of the benchmark basis (self-contained; no private path)
VALIDATION_CSV=$GEN_DIR/validation_points.csv  # 4 single-coupling validation points appended by default
USE_VALIDATION=1                             # 0 => basis only (no validation points)
NCARDS=0                                     # 0 = all benchmarks in the CSV
POINTS=""                                    # comma list of benchmark NAMES (e.g. BM1,BM7); empty = all
ECM=14                                       # basis-only cross sections at 14 TeV
PDF=""                                       # LHAID for lhans1/lhans2; empty => template default (90400)
CARDDIR=""                                   # empty => $GEN_DIR/cards_heft<ECM_TAG>
OUTBASE=root://eosuser.cern.ch//eos/user/a/acarvalh/gghh_heft_basis_gridpacks
OUTPUT_DIR=""                                # empty => $OUTBASE<ECM_TAG>; --outdir overrides
PROCESS_TARBALL=${PROCESS_TARBALL:-root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_keep_stage1/ggHH_SMEFT_run.tar.gz}
NCORES=4
REQUEST_MEM=3000
NXGRID=1
INCLUDE_BINARY=1
LCG_VIEW=/cvmfs/sft.cern.ch/lcg/views/LCG_107/x86_64-el9-gcc11-opt/setup.sh
FLAVOUR=testmatch
DRYRUN=0
REPORT=0
ONLY_MISSING=0
TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --csv)     CSV=$2; shift 2;;
    --validation-csv) VALIDATION_CSV=$2; shift 2;;
    --no-validation)  USE_VALIDATION=0; shift;;
    --ncards)  NCARDS=$2; shift 2;;
    --points)  POINTS=$2; shift 2;;
    --ecm)     ECM=$2; shift 2;;
    --pdf)     PDF=$2; shift 2;;
    --carddir) CARDDIR=$2; shift 2;;
    --outdir)  OUTPUT_DIR=$2; shift 2;;
    --process-tarball) PROCESS_TARBALL=$2; shift 2;;
    --ncores)  NCORES=$2; shift 2;;
    --mem)     REQUEST_MEM=$2; shift 2;;
    --nxgrid)  NXGRID=$2; shift 2;;
    --flavour) FLAVOUR=$2; shift 2;;
    --no-binary|--exclude-binary) INCLUDE_BINARY=0; shift;;
    --dry-run) DRYRUN=1; shift;;
    --report|--status) REPORT=1; shift;;
    --only-missing|--resubmit-missing) ONLY_MISSING=1; shift;;
    --test|--smoke) TEST=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

# Energy tag: keep outputs/logs/cards per-energy so reruns at another energy never
# collide. 14 TeV (the basis-only extraction energy) -> _14TeV.
case "$ECM" in
  13|13.0)   ECM_TAG=_13TeV;;
  13.6)      ECM_TAG=_13p6TeV;;
  14|14.0)   ECM_TAG=_14TeV;;
  100|100.0) ECM_TAG=_100TeV; [ -n "$PDF" ] || PDF=93300;;
  *) echo "--ecm must be 13, 13.6, 14 or 100 (TeV); got '$ECM'" >&2; exit 1;;
esac
[ -n "$OUTPUT_DIR" ] || OUTPUT_DIR=$OUTBASE$ECM_TAG
[ -n "$CARDDIR" ]    || CARDDIR=$GEN_DIR/cards_heft$ECM_TAG
[ -f "$CSV" ] || { echo "ERROR: HEFT basis CSV not found: $CSV" >&2; exit 1; }
echo ">> HEFT basis | csv=$(basename "$CSV") ecm=${ECM}TeV pdf=${PDF:-90400(template)} cards=$CARDDIR gridpacks=$OUTPUT_DIR"

TESTMODE=0
if [ "$TEST" = "1" ]; then
  TESTMODE=1; INCLUDE_BINARY=1; FLAVOUR=workday
  echo ">> TEST MODE: coarse smoke build of the FIRST selected benchmark (short queue, degraded stats)"
fi

list_completed_gridpacks() {
  case "$OUTPUT_DIR" in
    root://*)
      local rest=${OUTPUT_DIR#root://}; local host=${rest%%/*}; local path=${rest#"$host"}
      xrdfs "$host" ls "$path" 2>/dev/null | sed 's#.*/##' ;;
    *) ls -1 "$OUTPUT_DIR" 2>/dev/null ;;
  esac | grep '_gridpack\.tar\.gz$' || true
}

cd "$HERE"
mkdir -p "logs_heft$ECM_TAG" "$CARDDIR"

# 1) Generate the HEFT cards (+ manifest.json) for the requested benchmarks. By
#    default the 4 single-coupling validation points (validation_points.csv) are
#    appended to the 23-point basis; --no-validation drops them.
EXTRA_ARG=()
if [ "$USE_VALIDATION" = "1" ]; then
  [ -f "$VALIDATION_CSV" ] || { echo "ERROR: validation CSV not found: $VALIDATION_CSV (use --no-validation)" >&2; exit 1; }
  EXTRA_ARG=(--extra "$VALIDATION_CSV")
fi
echo ">> generating HEFT cards into $CARDDIR${USE_VALIDATION:+ (+validation)}"
python3 "$GEN_DIR/makeHEFTCards.py" --csv "$CSV" --outdir "$CARDDIR" --ecm "$ECM" \
        "${EXTRA_ARG[@]}" ${PDF:+--pdf "$PDF"} ${POINTS:+--points "$POINTS"} ${NCARDS:+--nmax "$NCARDS"}

mapfile -t RUN_TAGS < <(python3 -c \
  "import json,sys; [print(m['name']) for m in json.load(open(sys.argv[1]))]" \
  "$CARDDIR/manifest.json")

# 2) Completion check on EOS.
echo ">> checking completed gridpacks in $OUTPUT_DIR"
declare -A DONE=()
while IFS= read -r f; do [ -n "$f" ] && DONE["$f"]=1; done < <(list_completed_gridpacks)

# 3) Build cards.list (tag, /abs/path/card.input), skipping completed as configured.
: > cards.list
n_done=0; n_missing=0
for tag in "${RUN_TAGS[@]}"; do
  c="$CARDDIR/$tag.input"
  if [ -n "${DONE[${tag}_gridpack.tar.gz]:-}" ]; then
    n_done=$((n_done + 1))
    [ "$REPORT" = "1" ] && echo "   [done]    $tag"
    if [ "$REPORT" != "1" ] && [ "$ONLY_MISSING" != "1" ]; then
      printf '%s, %s\n' "$tag" "$c" >> cards.list
    fi
  else
    n_missing=$((n_missing + 1))
    [ "$REPORT" = "1" ] && echo "   [missing] $tag"
    [ "$REPORT" != "1" ] && printf '%s, %s\n' "$tag" "$c" >> cards.list
  fi
  if [ "$TEST" = "1" ] && [ "$REPORT" != "1" ] && [ -s cards.list ]; then
    echo ">> TEST MODE: using first selected benchmark $tag"; break
  fi
done
n_total=$((n_done + n_missing))
echo ">> gridpacks in selection: $n_done/$n_total completed, $n_missing missing"

if [ "$REPORT" = "1" ]; then echo ">> --report: nothing submitted."; exit 0; fi

NJOBS=$(wc -l < cards.list)
if [ "$NJOBS" -eq 0 ]; then echo ">> nothing to submit — all selected gridpacks already completed."; exit 0; fi
echo ">> $NJOBS job(s) queued"

# 3c) Process tarball: hosted URL is staged on the worker; only a missing LOCAL path rebuilds.
case "$PROCESS_TARBALL" in
  root://*|/eos/*) echo ">> PROCESS_TARBALL is hosted ($PROCESS_TARBALL) — staged on the worker node" ;;
  *) if [ ! -f "$PROCESS_TARBALL" ]; then echo ">> process tarball missing — building it"; \
       OUT_TARBALL="$PROCESS_TARBALL" "$HERE/make_process_tarball.sh"; fi ;;
esac

# 3b) Ensure the EOS output dir exists (jobs only copy, not mkdir parents).
case "$OUTPUT_DIR" in
  root://eosuser.cern.ch//eos/*)
    EOSPATH=${OUTPUT_DIR#root://eosuser.cern.ch/}
    echo ">> ensuring EOS dir $EOSPATH"
    eos mkdir -p "$EOSPATH" 2>/dev/null || mkdir -p "$EOSPATH" 2>/dev/null || \
      echo "   (could not pre-create; create it manually: eos mkdir -p $EOSPATH)";;
  /eos/*|*) mkdir -p "$OUTPUT_DIR" 2>/dev/null || true;;
esac

# 4) Submit (or dry-run). Reuse the shared submit_smeft.sub + run_smeft_gridpack.sh.
SUBMIT_ARGS=(
  -append "LOGDIR=logs_heft$ECM_TAG"
  -append "PROCESS_TARBALL=$PROCESS_TARBALL"
  -append "OUTPUT_DIR=$OUTPUT_DIR"
  -append "NCORES=$NCORES"
  -append "NXGRID=$NXGRID"
  -append "INCLUDE_BINARY=$INCLUDE_BINARY"
  -append "TESTMODE=$TESTMODE"
  -append "LCG_VIEW=$LCG_VIEW"
  -append "request_cpus=$NCORES"
  -append "request_memory=${REQUEST_MEM}M"
  -append "+JobFlavour=\"$FLAVOUR\""
)
if [ "$DRYRUN" = "1" ]; then
  echo ">> DRY RUN — would submit with:"; printf '   %s\n' "${SUBMIT_ARGS[@]}"
  echo ">> cards.list:"; cat cards.list
else
  echo ">> submitting to HTCondor"
  condor_submit "${SUBMIT_ARGS[@]}" submit_smeft.sub
fi
