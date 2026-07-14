#!/bin/bash
# Driver: generate cards, ensure the process tarball exists, build cards.list and
# submit one Condor job per ggHH_SMEFT parameter point.
#
# Examples:
#   ./submit_smeft.sh --ncards 3                 # test: first 3 points
#   ./submit_smeft.sh --start 4 --end 500        # points 4..500 (1-based, inclusive)
#   ./submit_smeft.sh --ncards 0                 # all points in the JSON
#   ./submit_smeft.sh --ncards 0 --dry-run       # build everything, don't submit
#   ./submit_smeft.sh --ncards 0 --outdir /eos/user/a/acarvalh/smeft_gridpacks
#   ./submit_smeft.sh --ncards 0 --report        # only report which gridpacks are done
#   ./submit_smeft.sh --ncards 0 --only-missing  # (re)submit only the not-yet-done points
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# Committed copy: the card generator (makeSMEFTCards.py) + template (powheg-2.input)
# live beside this script in MYOMC/gridpack/, so GEN_DIR (card generator root + where
# cards_prod is written) defaults to $HERE. A fresh clone needs no external
# generation_k4 tree for card generation. Override GEN_DIR to relocate.
GEN_DIR=${GEN_DIR:-$HERE}

# -------- defaults (override via flags) --------
NCARDS=3                                   # how many JSON points (0 = all); ignored if START/END set
START=0                                     # first point, 1-based inclusive (0 = beginning)
END=0                                       # last point, 1-based inclusive (0 = end)
CARDDIR=$GEN_DIR/cards_prod                # where generated cards go
# EOS via xrootd: robust on worker nodes where /eos isn't fuse-mounted.
OUTPUT_DIR=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_5param_keep_stage1
# The 55 MB compiled process tarball (pwhg_main binary + Virtual/creategrid.py +
# testrun/run.sh) is NOT committed (binary blob). It is HOSTED on EOS, so a fresh
# clone works out of the box — run_smeft_gridpack.sh xrdcp's this URL on the node.
# Override via env PROCESS_TARBALL=... or --process-tarball (a local path is also fine;
# rebuild one with make_process_tarball.sh if you have the POWHEG-BOX build).
PROCESS_TARBALL=${PROCESS_TARBALL:-root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_keep_stage1/ggHH_SMEFT_run.tar.gz}
NCORES=4                                   # cores/job (== request_cpus); run.sh parallelises stages 1-4
# request_memory is FLAT, not per-core. Measured peak MemoryUsage across every job ever
# run (incl. full 52h 4-stream production) is ~240 MB, 394 MB worst case — POWHEG's
# two-loop virtual is CPU-bound, not memory-bound, and does NOT scale with NCORES. The
# old NCORES*MEM_PER_CORE model over-requested ~8-12 GB, so 4-CPU+el9 slots never matched
# and jobs sat idle. CAVEAT: that 394 MB sample is ALL leading-only (includesubleading 0);
# the CtG!=0 subleading points have NEVER been measured and add chromomagnetic two-loop
# amplitudes that may use more. 3000 MB = ~7.6x the leading peak (big margin for the
# subleading unknown) yet still matches lxplus slots easily. Tighten once a real
# subleading job reports its peak (see README "Timing"/memory notes). Override with --mem.
REQUEST_MEM=3000                           # MB, total per job (override with --mem)
NXGRID=1                                   # xgrid iterations at parstage 1
# Ship pwhg_main inside the gridpack by DEFAULT so every produced gridpack is a complete,
# CMS-runnable POWHEG gridpack (runcmsgrid.sh + pwhg_main + card + grids). Turn off with
# --no-binary only if you deliberately want a grids-only pack (not CMS-runnable).
INCLUDE_BINARY=1
LCG_VIEW=/cvmfs/sft.cern.ch/lcg/views/LCG_107/x86_64-el9-gcc11-opt/setup.sh
# testmatch (72h), NOT nextweek (1w). lxplus workers run a staged drain and their START
# demands (time() + MaxRuntime < ShutdownTime), so a 7-day job only matches a machine with
# 7 clear days before its scheduled shutdown -- ~75 concurrent slots pool-wide, which left
# 708 jobs idle for days. 72h matches ~279 (3.7x) and still clears the ~52h production
# point with ~20h margin. Do NOT raise --ncores to buy wall time: 8-core cuts capacity to
# ~113 slots (nodes with 4-7 free cores drop out), a net throughput LOSS. See README.
FLAVOUR=testmatch
DRYRUN=0
REPORT=0                                    # --report: only print done/missing, no submit
ONLY_MISSING=0                              # --only-missing: submit only not-yet-done points
TEST=0                                      # --test: fast smoke build of the FIRST point only

while [ $# -gt 0 ]; do
  case "$1" in
    --ncards)  NCARDS=$2; shift 2;;
    --start)   START=$2; shift 2;;
    --end)     END=$2; shift 2;;
    --carddir) CARDDIR=$2; shift 2;;
    --outdir)  OUTPUT_DIR=$2; shift 2;;
    --process-tarball) PROCESS_TARBALL=$2; shift 2;;
    --ncores)  NCORES=$2; shift 2;;
    --mem)     REQUEST_MEM=$2; shift 2;;                 # total request_memory (MB), flat
    --mem-per-core) REQUEST_MEM=$(( $2 * NCORES )); shift 2;;  # deprecated: kept for back-compat
    --nxgrid)  NXGRID=$2; shift 2;;
    --flavour) FLAVOUR=$2; shift 2;;
    --include-binary) INCLUDE_BINARY=1; shift;;        # default (kept for back-compat)
    --no-binary|--exclude-binary) INCLUDE_BINARY=0; shift;;  # grids-only pack (NOT CMS-runnable)
    --dry-run) DRYRUN=1; shift;;
    --report|--status)            REPORT=1; shift;;
    --only-missing|--resubmit-missing) ONLY_MISSING=1; shift;;
    --test|--smoke)               TEST=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

# --test: prove the WHOLE pipeline (warmup -> stages 1-4 -> gridpack assembly ->
# EOS delivery) on the FIRST selected point in minutes, with coarse integration
# (TESTMODE) and a short queue. Physics is degraded — validation only. Real grids
# ARE built + packed + a real pwhg_main is shipped, so a successful smoke gridpack
# proves the assembly/tar/xrdcp path that has repeatedly failed after multi-day runs.
TESTMODE=0
if [ "$TEST" = "1" ]; then
  TESTMODE=1
  INCLUDE_BINARY=1                          # ship pwhg_main so the packed gridpack is complete/runnable
  FLAVOUR=workday                           # 8h headroom: the floored integration is ~30-40 min,
                                            # but the site wall-limit killed a 2h longlunch smoke job
  echo ">> TEST MODE: coarse smoke build of the FIRST selected point (short queue, degraded stats)"
fi

# List basenames of gridpacks already present in OUTPUT_DIR (one listing). A point
# counts as completed when "<tag>_gridpack.tar.gz" appears here.
list_completed_gridpacks() {
  case "$OUTPUT_DIR" in
    root://*)
      local rest=${OUTPUT_DIR#root://}      # host//eos/...  (or host/path)
      local host=${rest%%/*}                # eosuser.cern.ch
      local path=${rest#"$host"}            # //eos/...  (xrdfs accepts this form)
      xrdfs "$host" ls "$path" 2>/dev/null | sed 's#.*/##'
      ;;
    *)
      ls -1 "$OUTPUT_DIR" 2>/dev/null
      ;;
  esac | grep '_gridpack\.tar\.gz$' || true
}

cd "$HERE"
mkdir -p logs "$CARDDIR"

# 1) Generate the cards (+ manifest.json) for the requested points.
#    NON-destructive: we only ADD/overwrite cards in $CARDDIR, never wipe it — jobs
#    already queued from earlier submissions transfer their card from this AFS dir
#    at run time, so deleting cards here would orphan them (input-transfer failure
#    -> hold -> removed). makeSMEFTCards.py writes manifest.json listing exactly the
#    points THIS run generated; we build cards.list from that (not a folder glob),
#    so leftover cards from other runs don't leak in as extra jobs.
mkdir -p "$CARDDIR"
if [ "$START" -gt 0 ] || [ "$END" -gt 0 ]; then
  echo ">> generating cards (points $START..$END, 1-based inclusive) into $CARDDIR"
  python3 "$GEN_DIR/makeSMEFTCards.py" --outdir "$CARDDIR" --start "$START" --end "$END"
else
  echo ">> generating cards (nmax=$NCARDS) into $CARDDIR"
  python3 "$GEN_DIR/makeSMEFTCards.py" --outdir "$CARDDIR" --nmax "$NCARDS"
fi

# This run's card tags, from the manifest just written (the selected points only).
mapfile -t RUN_TAGS < <(python3 -c \
  "import json,sys; [print(m['name']) for m in json.load(open(sys.argv[1]))]" \
  "$CARDDIR/manifest.json")

# 2) Completion check: which selected points already have a gridpack on EOS.
#    One listing of OUTPUT_DIR, then classify each generated card.
echo ">> checking completed gridpacks in $OUTPUT_DIR"
declare -A DONE=()
while IFS= read -r f; do [ -n "$f" ] && DONE["$f"]=1; done < <(list_completed_gridpacks)

# 3) Build cards.list as "tag, /abs/path/card.input" (Condor `queue ... from`),
#    skipping completed points unless we are doing a full resubmit.
: > cards.list
n_done=0; n_missing=0
for tag in "${RUN_TAGS[@]}"; do
  c="$CARDDIR/$tag.input"
  if [ -n "${DONE[${tag}_gridpack.tar.gz]:-}" ]; then
    n_done=$((n_done + 1))
    [ "$REPORT" = "1" ] && echo "   [done]    $tag"
    # full resubmit re-queues done points too; --only-missing / --report drop them
    if [ "$REPORT" != "1" ] && [ "$ONLY_MISSING" != "1" ]; then
      printf '%s, %s\n' "$tag" "$c" >> cards.list
    fi
  else
    n_missing=$((n_missing + 1))
    [ "$REPORT" = "1" ] && echo "   [missing] $tag"
    [ "$REPORT" != "1" ] && printf '%s, %s\n' "$tag" "$c" >> cards.list
  fi
  # --test: stop after the first selected point (queue only its single job).
  if [ "$TEST" = "1" ] && [ "$REPORT" != "1" ] && [ -s cards.list ]; then
    echo ">> TEST MODE: using first selected point $tag"; break
  fi
done
n_total=$((n_done + n_missing))
echo ">> gridpacks in selection: $n_done/$n_total completed, $n_missing missing"

# 3a) Report-only mode: stop here (no tarball build, no submit).
if [ "$REPORT" = "1" ]; then
  echo ">> --report: nothing submitted."
  exit 0
fi

NJOBS=$(wc -l < cards.list)
if [ "$NJOBS" -eq 0 ]; then
  echo ">> nothing to submit — all selected gridpacks already completed."
  exit 0
fi
if [ "$ONLY_MISSING" = "1" ]; then
  echo ">> --only-missing: queuing $NJOBS not-yet-done point(s)"
else
  echo ">> $NJOBS jobs queued"
fi

# 3c) Ensure the process tarball is available (needed only when submitting). A hosted
#     URL (root://.../ /eos/...) is staged on the worker by run_smeft_gridpack.sh, so
#     trust it here. Only a MISSING LOCAL path triggers a rebuild (which needs the full
#     POWHEG-BOX build — a cloner without it should pass a hosted --process-tarball).
case "$PROCESS_TARBALL" in
  root://*|/eos/*)
    echo ">> PROCESS_TARBALL is hosted ($PROCESS_TARBALL) — staged on the worker node" ;;
  *)
    if [ ! -f "$PROCESS_TARBALL" ]; then
      echo ">> process tarball missing — building it"
      OUT_TARBALL="$PROCESS_TARBALL" "$HERE/make_process_tarball.sh"
    fi ;;
esac

# 3b) Ensure the output directory exists (jobs only copy files, not mkdir parents).
case "$OUTPUT_DIR" in
  root://eosuser.cern.ch//eos/*)
    EOSPATH=${OUTPUT_DIR#root://eosuser.cern.ch/}
    echo ">> ensuring EOS dir $EOSPATH"
    eos mkdir -p "$EOSPATH" 2>/dev/null || mkdir -p "$EOSPATH" 2>/dev/null || \
      echo "   (could not pre-create; create it manually: eos mkdir -p $EOSPATH)";;
  /eos/*|*) mkdir -p "$OUTPUT_DIR" 2>/dev/null || true;;
esac

# 4) Submit (or dry-run).
SUBMIT_ARGS=(
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
  echo ">> cards.list head:"; head -3 cards.list
else
  echo ">> submitting to HTCondor"
  condor_submit "${SUBMIT_ARGS[@]}" submit_smeft.sub
fi
