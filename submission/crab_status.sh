#!/bin/bash
# One-shot CRAB status for the NANOGEN tasks. Sets up the full environment (the
# reason a bare `cmsenv` fails with "Unable to find SCRAM version ..." is that
# SCRAM_ARCH + cmsset_default.sh must be sourced BEFORE cmsenv) and then runs
# `crab status`. With no argument it summarises EVERY task in crab_nanogen/;
# give a task dir (or point name) to see one in full.
#
#   ./crab_status.sh                 # one-line status for all crab_nanogen/crab_* tasks
#   ./crab_status.sh --all           # every task in EVERY work area under submission/
#   ./crab_status.sh --clean         # remove local dirs of tasks that are 100% done
#   ./crab_status.sh --clean --all   # ...across every work area
#   ./crab_status.sh --clean --dry-run   # show what WOULD be removed, delete nothing
#   ./crab_status.sh --resubmit      # crab resubmit FAILED jobs of every task with failures
#   ./crab_status.sh --resubmit --all    # ...across every work area
#   ./crab_status.sh --resubmit --dry-run  # show which tasks WOULD be resubmitted
#   ./crab_status.sh <point>         # full status for that task (name or crab_<name> dir)
#   ./crab_status.sh --verbose <pt>  # + --verboseErrors
#   WORKAREA=crab_nanogen_FAILED_... ./crab_status.sh   # a different work area
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORKAREA=${WORKAREA:-$HERE/crab_nanogen}
CMSSW_DIR=${CMSSW_DIR:-$HERE/crab_env/CMSSW_14_1_8}
export SCRAM_ARCH=${SCRAM_ARCH:-el9_amd64_gcc12}

# Flags may appear in any order before an optional single-task target.
VERBOSE=""; ALL=0; CLEAN=0; RESUBMIT=0; DRYRUN=0
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --verbose)  VERBOSE="--verboseErrors"; shift;;
    --all)      ALL=1; shift;;
    --clean)    CLEAN=1; shift;;
    --resubmit) RESUBMIT=1; shift;;
    --dry-run)  DRYRUN=1; shift;;
    *) break;;
  esac
done
TARGET=${1:-}

# --- environment (order matters; this is what fixes the SCRAM_ARCH/cmsenv error).
# The CMS env scripts (cmsset/scram/crab-setup) are NOT set -u clean; under `set -u`
# the first unbound var they touch makes THIS script exit silently. Relax strict
# mode around all the sourcing, then restore it.
export X509_USER_PROXY=${X509_USER_PROXY:-$HOME/private/x509up}
set +u
source /cvmfs/cms.cern.ch/cmsset_default.sh >/dev/null 2>&1
( cd "$CMSSW_DIR/src" ) || { echo "ERROR: no CMSSW at $CMSSW_DIR" >&2; exit 1; }
pushd "$CMSSW_DIR/src" >/dev/null; eval "$(scram runtime -sh)"; popd >/dev/null
source /cvmfs/cms.cern.ch/common/crab-setup.sh >/dev/null 2>&1 || \
  source /cvmfs/cms.cern.ch/crab3/crab.sh >/dev/null 2>&1 || true
set -u
command -v crab >/dev/null || { echo "ERROR: crab client not found" >&2; exit 1; }
if ! voms-proxy-info -exists -valid 0:10 >/dev/null 2>&1; then
  echo "ERROR: no valid grid proxy at $X509_USER_PROXY" >&2
  echo "       voms-proxy-init --rfc --voms cms -valid 192:00" >&2
  exit 1
fi

# resolve a single-task target: accept a dir, a crab_<name> dir, or a bare point
resolve() {
  local t=$1
  [ -d "$t" ] && { echo "$t"; return; }
  [ -d "$WORKAREA/$t" ] && { echo "$WORKAREA/$t"; return; }
  [ -d "$WORKAREA/crab_$t" ] && { echo "$WORKAREA/crab_$t"; return; }
  echo ""; return 1
}

if [ -n "$TARGET" ]; then
  D=$(resolve "$TARGET") || { echo "no such task: $TARGET (looked in $WORKAREA)" >&2; exit 1; }
  exec crab status -d "$D" $VERBOSE
fi

# print a one-line status row per task dir passed as args
summarise() {
  printf '%-58s %-12s %s\n' "TASK" "STATUS" "JOBS"
  for D in "$@"; do
    out=$(crab status -d "$D" 2>/dev/null)
    sched=$(echo "$out" | sed -n 's/^Status on the scheduler:\s*//p' | head -1)
    srv=$(echo "$out"   | sed -n 's/^Status on the CRAB server:\s*//p' | head -1)
    jobs=$(echo "$out"  | grep -oE '(failed|finished|running|idle|transferring)[[:space:]]+[0-9.]+% \([0-9]+/[0-9]+\)' | paste -sd' ' -)
    printf '%-58s %-12s %s\n' "$(basename "$D")" "${sched:-${srv:-?}}" "${jobs:-—}"
  done
}

# true if the task is 100% done: scheduler COMPLETED, or all jobs finished (N/N).
# Only then are all outputs on EOS and the local project dir safe to delete.
task_is_done() {
  local out; out=$(crab status -d "$1" 2>/dev/null)
  echo "$out" | grep -q '^Status on the scheduler:[[:space:]]*COMPLETED' && return 0
  echo "$out" | grep -qE 'finished[[:space:]]+100\.0% \([0-9]+/[0-9]+\)' && return 0
  return 1
}

# remove the local work-area dirs of every 100%-done task in the list
clean_done() {
  local removed=0 kept=0 D
  for D in "$@"; do
    if task_is_done "$D"; then
      if [ "$DRYRUN" = "1" ]; then
        echo "   [would remove] $(basename "$D")"
      else
        rm -rf "$D" && echo "   [removed] $(basename "$D")"
      fi
      removed=$((removed + 1))
    else
      kept=$((kept + 1))
    fi
  done
  local verb="removed"; [ "$DRYRUN" = "1" ] && verb="to remove"
  echo ">> $verb: $removed done task(s); kept $kept not-yet-done."
  echo "   (outputs of done tasks are already on EOS — only the local project dir is deleted.)"
}

# number of FAILED jobs for a task (0 if none / can't tell). CRAB prints e.g.
# "failed  12.0% (12/100)"; we pull the numerator of that fraction.
failed_count() {
  crab status -d "$1" 2>/dev/null \
    | grep -oE 'failed[[:space:]]+[0-9.]+% \([0-9]+/[0-9]+\)' \
    | grep -oE '\([0-9]+/' | tr -dc '0-9' | head -1
}

# crab resubmit the FAILED jobs of every task that has any, across the list.
resubmit_failed() {
  local did=0 skipped=0 D n
  for D in "$@"; do
    n=$(failed_count "$D"); n=${n:-0}
    if [ "$n" -gt 0 ]; then
      if [ "$DRYRUN" = "1" ]; then
        echo "   [would resubmit] $(basename "$D")  ($n failed job(s))"
      else
        echo ">> crab resubmit $(basename "$D")  ($n failed job(s))"
        crab resubmit -d "$D" || echo "   [warn] resubmit failed for $(basename "$D")"
      fi
      did=$((did + 1))
    else
      skipped=$((skipped + 1))
    fi
  done
  local verb="resubmitted"; [ "$DRYRUN" = "1" ] && verb="to resubmit"
  echo ">> $verb: $did task(s) with failed jobs; skipped $skipped with none."
  [ "$DRYRUN" = "1" ] || echo "   (only FAILED jobs are re-run; running/finished jobs are untouched.)"
}

shopt -s nullglob
if [ "$ALL" = "1" ]; then
  # Every task in EVERY work area under submission/ (a task dir is any dir that
  # holds a crab.log). Covers crab_nanogen plus renamed/failed/other areas.
  tasks=()
  for cl in "$HERE"/*/crab_*/crab.log; do tasks+=("$(dirname "$cl")"); done
  [ ${#tasks[@]} -gt 0 ] || { echo "no crab tasks found under $HERE" >&2; exit 1; }
  scope="ALL work areas under $HERE"
else
  tasks=("$WORKAREA"/crab_*)
  [ ${#tasks[@]} -gt 0 ] || { echo "no tasks under $WORKAREA (try --all)" >&2; exit 1; }
  scope="$WORKAREA"
fi

if [ "$RESUBMIT" = "1" ]; then
  tag=""; [ "$DRYRUN" = "1" ] && tag=" [dry-run]"
  echo ">> resubmitting FAILED jobs in $scope (${#tasks[@]} task(s))$tag"
  resubmit_failed "${tasks[@]}"
elif [ "$CLEAN" = "1" ]; then
  tag=""; [ "$DRYRUN" = "1" ] && tag=" [dry-run]"
  echo ">> cleaning 100%-done tasks in $scope (${#tasks[@]} task(s))$tag"
  clean_done "${tasks[@]}"
else
  echo ">> $scope : ${#tasks[@]} task(s)"
  summarise "${tasks[@]}"
fi
