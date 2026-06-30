#!/bin/bash
# Per-job executable: produce ONE NANOGEN file (default 20k events) for one
# ggHH_SMEFT point, from its POWHEG gridpack on EOS, then copy the NANOGEN root
# to the output area. Five jobs per point (jobindex 1..5) give 100k events.
#
# Args:
#   $1 = point name (basename of the fragment, no .py) -> also the gridpack stem
#   $2 = job index within the point (1..NJOBS_PER_POINT) -> seed + output suffix
# Env (set via the .sub `environment` or exported):
#   FRAGMENT      : the per-point fragment .py (transferred into the job)
#   GRIDPACK_DIR  : EOS dir holding <point>_gridpack.tar.gz (xrootd or /eos path)
#   OUTPUT_DIR    : where to drop NANOGEN_<point>_<jobindex>.root
#   RUN_SH        : campaign NANOGEN run.sh (transferred into the job)
#   NEVENTS       : events for this job                                  [20000]
#   NTHREADS      : cmsRun threads (== request_cpus)                     [1]
set -euo pipefail

POINT=${1:?usage: run_nanogen.sh <point> <jobindex>}
JOBIDX=${2:?usage: run_nanogen.sh <point> <jobindex>}
FRAGMENT=${FRAGMENT:?set FRAGMENT}
GRIDPACK_DIR=${GRIDPACK_DIR:?set GRIDPACK_DIR}
OUTPUT_DIR=${OUTPUT_DIR:?set OUTPUT_DIR}
RUN_SH=${RUN_SH:?set RUN_SH}
NEVENTS=${NEVENTS:-20000}
NTHREADS=${NTHREADS:-1}

echo "==== $(date) | point=$POINT | job=$JOBIDX | host=$(hostname) | nevt=$NEVENTS ===="

# Condor drops the transferred files in the scratch root (our cwd). Resolve to
# absolute paths now; run.sh will cd around while building CMSSW.
FRAGMENT=$(readlink -f "$FRAGMENT")
RUN_SH=$(readlink -f "$RUN_SH")
TOPDIR=$PWD
GP="${POINT}_gridpack.tar.gz"

source /cvmfs/cms.cern.ch/cmsset_default.sh

# 1) Fetch this point's gridpack from EOS into the job scratch.
case "$GRIDPACK_DIR" in
    root://*) xrdcp -f "$GRIDPACK_DIR/$GP" "$TOPDIR/$GP" ;;
    /eos/*)   xrdcp -f "root://eosuser.cern.ch/$GRIDPACK_DIR/$GP" "$TOPDIR/$GP" ;;
    *)        cp "$GRIDPACK_DIR/$GP" "$TOPDIR/$GP" ;;
esac
GP_ABS=$(readlink -f "$TOPDIR/$GP")
echo "Gridpack staged at $GP_ABS ($(du -h "$GP_ABS" | cut -f1))"

# 2) Bake the gridpack's absolute path into a local copy of the fragment.
LOCAL_FRAG="$TOPDIR/fragment_${POINT}_${JOBIDX}.py"
sed "s|__GRIDPACKPATH__|${GP_ABS}|g" "$FRAGMENT" > "$LOCAL_FRAG"
if grep -q "__GRIDPACKPATH__" "$LOCAL_FRAG"; then
    echo "ERROR: gridpack path token not substituted in fragment" >&2; exit 43
fi

# 3) Run the campaign NANOGEN driver: builds CMSSW_14_1_8 (el9), runs cmsDriver
#    (LHE,GEN,NANO:@GEN) and cmsRun. Sourced so it shares this shell's cwd=$TOPDIR.
#    run.sh signature: <name> <fragment> <nevents> <jobindex> <nthreads>
NAME="${POINT}_${JOBIDX}"
echo "---- launching NANOGEN run.sh ($NAME) ----"
source "$RUN_SH" "$NAME" "$LOCAL_FRAG" "$NEVENTS" "$JOBIDX" "$NTHREADS"
echo "---- run.sh finished ----"

cd "$TOPDIR"
# run.sh writes NANOGEN_<NAME>_<JOBIDX>.root (its $NAME already includes _$JOBIDX,
# and its filename pattern is NANOGEN_${NAME}_${JOBIDX}); glob to be robust.
shopt -s nullglob
OUTS=( $(find "$CMSSW_BASE" "$TOPDIR" -maxdepth 4 -name '*NANOGEN*.root' 2>/dev/null) )
if [ "${#OUTS[@]}" -eq 0 ]; then
    echo "ERROR: no NANOGEN root produced for $POINT job $JOBIDX." >&2; exit 42
fi
SRC=${OUTS[0]}
DEST="NANOGEN_${POINT}_${JOBIDX}.root"
echo "NANOGEN output: $SRC -> $DEST"

# 4) Deliver to the output area.
echo "Delivering $DEST -> $OUTPUT_DIR"
case "$OUTPUT_DIR" in
    root://*) xrdcp -f "$SRC" "$OUTPUT_DIR/$DEST" ;;
    /eos/*)   xrdcp -f "$SRC" "root://eosuser.cern.ch/$OUTPUT_DIR/$DEST" ;;
    *)        mkdir -p "$OUTPUT_DIR"; cp "$SRC" "$OUTPUT_DIR/$DEST" ;;
esac
echo "==== $(date) | DONE $POINT job $JOBIDX ===="
