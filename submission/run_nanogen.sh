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
# Fix-files transferred into the job scratch (basenames) for gridpack self-heal.
CREATEGRID_PY=${CREATEGRID_PY:-creategrid.py}
FIXED_RUNCMSGRID=${FIXED_RUNCMSGRID:-runcmsgrid.sh}

echo "==== $(date) | point=$POINT | job=$JOBIDX | host=$(hostname) | nevt=$NEVENTS ===="

# Condor drops the transferred files in the scratch root (our cwd). Resolve to
# absolute paths now; run.sh will cd around while building CMSSW.
FRAGMENT=$(readlink -f "$FRAGMENT")
RUN_SH=$(readlink -f "$RUN_SH")
TOPDIR=$PWD
GP="${POINT}_gridpack.tar.gz"

# cmsset_default.sh (via SITECONF cmsset_local.sh) references unset vars like
# CVS_RSH internally; under `set -u` that aborts the job in seconds ("CVS_RSH:
# unbound variable"). Relax nounset just while sourcing, then restore it.
set +u
source /cvmfs/cms.cern.ch/cmsset_default.sh
set -u

# 1) Fetch this point's gridpack from EOS into the job scratch.
case "$GRIDPACK_DIR" in
    root://*) xrdcp -f "$GRIDPACK_DIR/$GP" "$TOPDIR/$GP" ;;
    /eos/*)   xrdcp -f "root://eosuser.cern.ch/$GRIDPACK_DIR/$GP" "$TOPDIR/$GP" ;;
    *)        cp "$GRIDPACK_DIR/$GP" "$TOPDIR/$GP" ;;
esac
GP_ABS=$(readlink -f "$TOPDIR/$GP")
echo "Gridpack staged at $GP_ABS ($(du -h "$GP_ABS" | cut -f1))"

# 1b) Self-heal the staged gridpack IN PLACE (local scratch copy only; EOS is
#     never touched). Older gridpacks were assembled without creategrid.py and
#     with an unpatched runcmsgrid.sh (dies before pwhg_main -> 0 events). Inject
#     the shipped fix-files only if missing/stale, then re-tar the SAME local
#     file. Both are generic + physics-neutral (creategrid.py's combinegrids()
#     short-circuits on the already-combined grid; runcmsgrid.sh only changes env
#     setup), so this is idempotent and a no-op on an already-correct gridpack.
CREATEGRID_PY=$(readlink -f "$CREATEGRID_PY" 2>/dev/null || echo "$CREATEGRID_PY")
FIXED_RUNCMSGRID=$(readlink -f "$FIXED_RUNCMSGRID" 2>/dev/null || echo "$FIXED_RUNCMSGRID")
if [ -f "$CREATEGRID_PY" ] && [ -f "$FIXED_RUNCMSGRID" ]; then
    # Decide whether a rewrite is actually needed BEFORE paying for untar/retar,
    # so an already-correct gridpack costs only a cheap listing + one small diff
    # (no rewrite) -> zero measurable overhead when we run thousands in parallel.
    # One listing serves both probes: a .tar.gz is not seekable, so every extra
    # `tar` pass re-inflates the whole 112 MB payload.
    NEED_CG=0; NEED_RUN=0
    GP_LIST=$(tar tzf "$GP_ABS" 2>/dev/null)
    echo "$GP_LIST" | grep -qE '(^|/)creategrid\.py$' || NEED_CG=1
    # Resolve the member NAME from the listing instead of hardcoding a prefix:
    # submit_smeft.sh tars bare names (`runcmsgrid.sh`) while a self-healed repack
    # below writes `./runcmsgrid.sh`, so no single literal probe matches both. The
    # old `./runcmsgrid.sh` probe never matched the EOS layout -> NEED_RUN was
    # always 1 -> every job untarred+retarred 112 MB even when nothing needed
    # fixing, which is pure I/O to glitch on at scale.
    RUN_MEMBER=$(echo "$GP_LIST" | grep -E '(^|/)runcmsgrid\.sh$' | head -1)
    if [ -z "$RUN_MEMBER" ] ||
       ! tar xzOf "$GP_ABS" "$RUN_MEMBER" 2>/dev/null | cmp -s - "$FIXED_RUNCMSGRID"; then NEED_RUN=1; fi
    if [ $NEED_CG = 1 ] || [ $NEED_RUN = 1 ]; then
        PATCHDIR="$TOPDIR/gp_patch"
        rm -rf "$PATCHDIR"; mkdir -p "$PATCHDIR"
        ( cd "$PATCHDIR" && tar xzf "$GP_ABS" )
        cp -f "$CREATEGRID_PY"    "$PATCHDIR/creategrid.py"
        cp -f "$FIXED_RUNCMSGRID" "$PATCHDIR/runcmsgrid.sh"
        chmod +x "$PATCHDIR/runcmsgrid.sh"
        # gzip -1: the payload is mostly incompressible grids + a binary, so fast
        # compression is ~as small but much cheaper CPU at scale.
        ( cd "$PATCHDIR" && tar -I 'gzip -1' -cf "$GP_ABS" . )  # '.' preserves layout + dotfiles
        rm -rf "$PATCHDIR"
        echo "Gridpack self-healed in place (creategrid.py fixed=$NEED_CG, runcmsgrid.sh fixed=$NEED_RUN). New size: $(du -h "$GP_ABS" | cut -f1)"
    else
        echo "Gridpack already correct (creategrid.py present, runcmsgrid.sh up-to-date) — no repack."
    fi
else
    echo "WARNING: fix-files not found (CREATEGRID_PY=$CREATEGRID_PY FIXED_RUNCMSGRID=$FIXED_RUNCMSGRID); skipping self-heal." >&2
fi

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
# The campaign run.sh is NOT written for strict mode but we source it, so it
# inherits our `set -euo pipefail`. It references unset vars (CMSSW env setup;
# also a latent `$NAME_$JOBINDEX` where `$NAME_` parses as an unset variable),
# which abort instantly under `set -u`. Relax -e/-u across the source; our own
# post-check below (exit 42 if no *NANOGEN*.root) still catches a real failure.
set +eu
source "$RUN_SH" "$NAME" "$LOCAL_FRAG" "$NEVENTS" "$JOBIDX" "$NTHREADS"
set -eu
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
# Deliver into a PER-POINT subfolder so each point owns a directory holding its 5
# job files (NANOGEN_<point>_1.root .. _5.root), instead of ~12500 files flat in one
# EOS dir. Final layout: $OUTPUT_DIR/<point>/NANOGEN_<point>_<jobidx>.root
DEST="${POINT}/NANOGEN_${POINT}_${JOBIDX}.root"
echo "NANOGEN output: $SRC -> $DEST"

# 3b) Guard against a 0-event file. cmsRun still writes a valid (~60 KB) NANOAOD
#     skeleton when ExternalLHEProducer's child (the gridpack) fails, so the
#     exit-42 "no root" check above passes on an EMPTY result. Count the Events
#     tree (PyROOT from the active CMSSW runtime) and fail hard if it's empty.
NEV=$(python3 - "$SRC" <<'PY'
import sys
try:
    import ROOT
    f = ROOT.TFile.Open(sys.argv[1])
    t = f.Get("Events") if f else None
    print(int(t.GetEntries()) if t else 0)
except Exception:
    print(-1)
PY
)
echo "NANOGEN event count: $NEV"
if [ "${NEV:-0}" -lt 1 ]; then
    echo "ERROR: $DEST has $NEV events -> LHE/GEN produced nothing (gridpack failed). Not delivering." >&2
    exit 44
fi

# 4) Deliver to the output area. `xrdcp -p` creates the missing per-point parent
#    directory on EOS; for a local path we mkdir it ourselves.
echo "Delivering $DEST -> $OUTPUT_DIR"
case "$OUTPUT_DIR" in
    root://*) xrdcp -f -p "$SRC" "$OUTPUT_DIR/$DEST" ;;
    /eos/*)   xrdcp -f -p "$SRC" "root://eosuser.cern.ch/$OUTPUT_DIR/$DEST" ;;
    *)        mkdir -p "$OUTPUT_DIR/$POINT"; cp "$SRC" "$OUTPUT_DIR/$DEST" ;;
esac
echo "==== $(date) | DONE $POINT job $JOBIDX ===="
