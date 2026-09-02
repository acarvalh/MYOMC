#!/bin/bash
# Driver: build ggHH_SMEFT gridpacks for the TRUNCATION STUDY benchmarks, one Condor
# job per (benchmark x truncation). Default = the five LHCHWG-2026-006 Table-3 points
# (smeft_truncation_bm.csv), each built LINEAR and FULL(quadratic) => 10 gridpacks,
# at 13.6 TeV (Run 3).
#
#   linear   -> SMEFTtruncation 0  = |A_SM|^2 + 2Re(A_SM* A_dim6)   (report Eq. 5-6)
#   full     -> SMEFTtruncation 1  = |A_SM + A_dim6|^2              (report Eq. 9)
# RGE effects are OFF in BOTH variants (WCscaledependence 0, forced by
# makeTruncationCards.py): muEFT = muren, no running/mixing of the Wilson coeffs, as
# the report's benchmarks are defined (Sec. 3.2).
# PDF + scale MATCH THE PAPER (Table 1): PDF4LHC21_40 (LHAID 93300, default PDF here) and
# central mu_R=mu_F=m_HH/2 (template default). Lambda=1 TeV, sqrt(s)=13.6 TeV also match.
#
# SEPARATE from submit_smeft.sh / submit_heft.sh: its own CSV + card generator
# (makeTruncationCards.py, which sets SMEFTtruncation per variant) + EOS output + logs.
# REUSES the shared per-job executable (run_smeft_gridpack.sh) and submit file
# (submit_smeft.sub). Card tag <name> -> gridpack <name>_gridpack.tar.gz on EOS.
#
# Examples:
#   ./submit_truncation.sh                    # 5 BM x {lin,full} = 10 gridpacks, 13.6 TeV
#   ./submit_truncation.sh --check            # TEST IF ALL DONE: report + exit 0 iff 10/10
#   ./submit_truncation.sh --points BM1,BM3   # a named subset (both variants)
#   ./submit_truncation.sh --only lin         # only the linear variant (5 gridpacks)
#   ./submit_truncation.sh --only-missing     # (re)submit only not-yet-done gridpacks
#   ./submit_truncation.sh --dry-run          # build cards + cards.list, submit nothing
#   ./submit_truncation.sh --test             # coarse smoke build of the FIRST card
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GEN_DIR=${GEN_DIR:-$HERE}

# -------- defaults (override via flags) --------
CSV=${CSV:-$GEN_DIR/smeft_truncation_bm.csv}   # in-repo benchmark set (self-contained)
POINTS=""                                    # comma list of benchmark NAMES (e.g. BM1,BM3); empty = all
ONLY=""                                      # "" = both variants; lin | quad for one only
ECM=13.6                                     # Run 3 = 13.6 TeV (this study's energy)
# PDF: 93300 = PDF4LHC21_40(_pdfas) -- the set used in LHCHWG-2026-006 Table 1, so this
# study matches the PAPER (NOT our large production's 90400/PDF4LHC15 at 13.6 TeV). The
# central scale mu_R=mu_F=m_HH/2 already matches the paper (template facscfact/renscfact=1,
# muref=m_HH/2). Pass --pdf to override; --pdf 90400 reverts to the large-production PDF.
PDF=93300                                    # LHAID for lhans1/lhans2 (paper PDF4LHC21_40)
CARDDIR=""                                   # empty => $GEN_DIR/cards_trunc<ECM_TAG>
OUTBASE=root://eosuser.cern.ch//eos/user/a/acarvalh/gghh_smeft_truncation_gridpacks
OUTPUT_DIR=""                                # empty => $OUTBASE<ECM_TAG>; --outdir overrides
PROCESS_TARBALL=${PROCESS_TARBALL:-root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_keep_stage1/ggHH_SMEFT_run.tar.gz}
NCORES=4
REQUEST_MEM=3000
NXGRID=1
INCLUDE_BINARY=1
LCG_VIEW=/cvmfs/sft.cern.ch/lcg/views/LCG_107/x86_64-el9-gcc11-opt/setup.sh
FLAVOUR=testmatch
DRYRUN=0
REPORT=0                                     # --report / --check: list status, submit nothing
CHECK=0                                      # --check: also exit non-zero unless ALL are done
ONLY_MISSING=0
TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --csv)     CSV=$2; shift 2;;
    --points)  POINTS=$2; shift 2;;
    --only)    ONLY=$2; shift 2;;
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
    --check|--all-done) REPORT=1; CHECK=1; shift;;   # test-if-all-done: report + strict exit code
    --only-missing|--resubmit-missing) ONLY_MISSING=1; shift;;
    --test|--smoke) TEST=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

case "$ONLY" in ""|lin|quad) ;; *) echo "--only must be lin or quad (got '$ONLY')" >&2; exit 1;; esac

# Energy tag: keep outputs/logs/cards per-energy so reruns at another energy never collide.
case "$ECM" in
  13|13.0)   ECM_TAG=_13TeV;;
  13.6)      ECM_TAG=_13p6TeV;;
  14|14.0)   ECM_TAG=_14TeV;;
  100|100.0) ECM_TAG=_100TeV; [ -n "$PDF" ] || PDF=93300;;
  *) echo "--ecm must be 13, 13.6, 14 or 100 (TeV); got '$ECM'" >&2; exit 1;;
esac
[ -n "$OUTPUT_DIR" ] || OUTPUT_DIR=$OUTBASE$ECM_TAG
[ -n "$CARDDIR" ]    || CARDDIR=$GEN_DIR/cards_trunc$ECM_TAG
[ -f "$CSV" ] || { echo "ERROR: benchmark CSV not found: $CSV" >&2; exit 1; }
echo ">> SMEFT truncation study | csv=$(basename "$CSV") ecm=${ECM}TeV pdf=${PDF:-90400(template)} cards=$CARDDIR gridpacks=$OUTPUT_DIR"

TESTMODE=0
if [ "$TEST" = "1" ]; then
  TESTMODE=1; INCLUDE_BINARY=1; FLAVOUR=workday
  echo ">> TEST MODE: coarse smoke build of the FIRST selected card (short queue, degraded stats)"
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
mkdir -p "logs_trunc$ECM_TAG" "$CARDDIR"

# 1) Generate the truncation cards (+ manifest.json): each benchmark x {lin, full}.
echo ">> generating truncation cards into $CARDDIR"
python3 "$GEN_DIR/makeTruncationCards.py" --csv "$CSV" --outdir "$CARDDIR" --ecm "$ECM" \
        ${PDF:+--pdf "$PDF"} ${POINTS:+--points "$POINTS"} ${ONLY:+--only "$ONLY"}

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
    echo ">> TEST MODE: using first selected card $tag"; break
  fi
done
n_total=$((n_done + n_missing))
echo ">> gridpacks in selection: $n_done/$n_total completed, $n_missing missing"

# --check / --report: test if all done. --check exits 0 ONLY when the whole selection
# is complete (scriptable), non-zero otherwise; plain --report always exits 0.
if [ "$REPORT" = "1" ]; then
  if [ "$CHECK" = "1" ]; then
    if [ "$n_missing" -eq 0 ]; then
      echo ">> ALL DONE: $n_done/$n_total gridpacks present."
      exit 0
    else
      echo ">> NOT DONE: $n_missing/$n_total gridpack(s) still missing."
      exit 1
    fi
  fi
  echo ">> --report: nothing submitted."
  exit 0
fi

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
  -append "LOGDIR=logs_trunc$ECM_TAG"
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
