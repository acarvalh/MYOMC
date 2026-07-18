#!/bin/bash
# Per-job executable: build ONE ggHH_SMEFT gridpack (POWHEG stages 1-4) for one
# SMEFT parameter point, then copy the resulting gridpack tarball to the output area.
#
# Args:  $1 = absolute path to the powheg .input card for this point
# Env (with defaults), set via the .sub file's `environment` or exported:
#   PROCESS_TARBALL : the ggHH_SMEFT_run.tar.gz produced by make_process_tarball.sh
#   OUTPUT_DIR      : where to drop <cardname>_gridpack.tar.gz
#   NCORES          : cores for run.sh (must match request_cpus)         [1]
#   NXGRID          : xgrid iterations at parallelstage 1                 [1]
#   LCG_VIEW        : CVMFS LCG view providing gfortran/LHAPDF/FastJet
#   INCLUDE_BINARY  : 1 to also pack the 104M pwhg_main into the gridpack [0]
set -euo pipefail

CARD=${1:?usage: run_smeft_gridpack.sh <card.input>}
PROCESS_TARBALL=${PROCESS_TARBALL:?set PROCESS_TARBALL}
OUTPUT_DIR=${OUTPUT_DIR:?set OUTPUT_DIR}
NCORES=${NCORES:-1}
NXGRID=${NXGRID:-1}
LCG_VIEW=${LCG_VIEW:-/cvmfs/sft.cern.ch/lcg/views/LCG_107/x86_64-el9-gcc11-opt/setup.sh}
# CMS-runnable gridpacks bundle pwhg_main + runcmsgrid.sh so ExternalLHEProducer
# can run them standalone. INCLUDE_BINARY=0 makes a lightweight (NON-runnable)
# gridpack for testing only.
INCLUDE_BINARY=${INCLUDE_BINARY:-1}
# events POWHEG generates during the gridpack BUILD (stage-4 test sample); the
# card ships NEVENTS as a placeholder for runcmsgrid.sh at generation time.
BUILD_NEVENTS=${BUILD_NEVENTS:-5000}
# TESTMODE=1: coarse-but-fast integration (small ncall/itmx/nubound) so the WHOLE
# pipeline — warmup, parallelstages 1-4, gridpack assembly and EOS delivery — can be
# validated in minutes instead of ~2 days. The gridpack is physics-degraded (coarse
# grids); use it ONLY to prove the plumbing, never for real event generation.
TESTMODE=${TESTMODE:-0}

POINT=$(basename "$CARD" .input)
# Condor transfers the card into the scratch root (our initial cwd); resolve it to an
# absolute path now, before we cd into the per-job work subdir below.
CARD=$(readlink -f "$CARD")
echo "==== $(date) | point=$POINT | host=$(hostname) | cores=$NCORES ===="

# 1) Environment (gfortran / LHAPDF / FastJet / PDF sets from CVMFS)
#    The LCG setup.sh references unset vars internally, so relax nounset while sourcing.
set +u
source "$LCG_VIEW"
set -u

# 2) Node-local scratch (Condor sets _CONDOR_SCRATCH_DIR; fall back to TMPDIR)
WORK=${_CONDOR_SCRATCH_DIR:-${TMPDIR:-/tmp}}/smeft_$POINT.$$
mkdir -p "$WORK"; cd "$WORK"
trap 'rm -rf "$WORK"' EXIT

# 3) Stage the prebuilt process (copy from shared FS, or xrdcp from EOS)
echo "Fetching process tarball: $PROCESS_TARBALL"
case "$PROCESS_TARBALL" in
    root://*|/eos/*) xrdcp -f "$PROCESS_TARBALL" proc.tar.gz ;;
    *)               cp "$PROCESS_TARBALL" proc.tar.gz ;;
esac
tar xzf proc.tar.gz
PROC=$WORK/ggHH_SMEFT

# 3a) Pre-flight: fail FAST (seconds) if the unpacked process is missing pieces the
#     gridpack-assembly step (6) needs. Without this, a stale tarball lets POWHEG run
#     ~41h and only then dies at `cp runcmsgrid.sh` -> exit 1, silently wasting the run.
#     runcmsgrid.sh is the CMS entry point; run.sh runs POWHEG. Both are mandatory.
missing=""
for req in "$PROC/pwhg_main" "$PROC/runcmsgrid.sh" "$PROC/testrun/run.sh" "$PROC/Virtual/creategrid.py"; do
    [ -f "$req" ] || missing="$missing $req"
done
if [ -n "$missing" ]; then
    echo "ERROR: process tarball is incomplete — missing:$missing" >&2
    echo "       rebuild it with condor/make_process_tarball.sh, then resubmit." >&2
    exit 17
fi

# 4) Stage the run directory (mirrors testrun/ layout: run.sh + card + seeds)
RUNDIR=$PROC/run_$POINT
mkdir -p "$RUNDIR"
# Per-point base seed so distinct points don't share the same random sequence.
BASE_SEED=$(python3 -c "import sys,zlib; print(zlib.crc32(sys.argv[1].encode())%900000)" "$POINT")
# The card ships NEVENTS/SEED placeholders (HEFT convention). For the BUILD,
# substitute a concrete event count + the base seed; manyseeds=1 means iseed is
# ignored during the parallel integration anyway.
sed -e "s/NEVENTS/$BUILD_NEVENTS/" -e "s/SEED/$BASE_SEED/" "$CARD" > "$RUNDIR/powheg.input-save"
# TESTMODE: shrink the integration so stages 1-4 finish in minutes. Only the BUILD
# card (powheg.input-save, which run.sh reads for every stage) is coarsened; the
# runtime template reuses the shipped grids so its ncall is irrelevant. NOT physics.
if [ "$TESTMODE" = "1" ]; then
    # Integration cost is ~linear in ncall*itmx, so floor them. The production run
    # is ~52-56h; ncall1500/itmx2 only cut that to ~5h (overshot longlunch). Push
    # ncall/itmx to the floor that still yields a valid grid + a few events so the
    # WHOLE path finishes in ~30-40 min. Floor BOTH the integration AND the stage-4
    # event count -- events, not integration, are what ran two smoke jobs into the
    # queue wall.
    # NB the cost driver is NOT the two-loop virtual (an earlier comment here claimed
    # ~10 CPU-s per phase-space point -- that was WRONG). The virtual is interpolated
    # from the shipped Virt_full-SMEFT1_*.grid: measured `virt time` in
    # pwgcounters-st4 is 13-17 SECONDS out of a ~25000s run (~0.1%). The real cost is
    # the ONE-LOOP REAL RADIATION (GoSam pr2_gghhg/pr3_qghhq/pr9_gghhg/pr10_qghhq),
    # and its per-call cost is dominated by GoSam's QUAD-precision rescue
    # (PSP_check=.true., reduction_interoperation_rescue=QUADNINJA): gdb stack
    # sampling found a CuH!=0,CHG!=0 point spends 92% of wall inside soft-float quad
    # (__multf3, *_qp modules) vs 28% for a CuH=0&CHG=0 point -- which alone explains
    # their 9x cost gap. So event count, not virtual evals, is the knob here.
    echo ">> TESTMODE=1: minimal integration + few events (ncall/itmx/nubound/numevts floored) — smoke test only"
    sed -i -e 's/^ncall1 .*/ncall1   300/'  -e 's/^itmx1 .*/itmx1    1/' \
           -e 's/^ncall2 .*/ncall2   300/'  -e 's/^itmx2 .*/itmx2    1/' \
           -e 's/^nubound .*/nubound  300/'  -e 's/^numevts .*/numevts  50/' \
           "$RUNDIR/powheg.input-save"
fi
# Runtime card for the gridpack. CRITICAL: this must run in parallelstage-4 +
# manyseeds mode so pwhg_main REUSES the numbered grids the parallel build produced
# (pwggrid-000X.dat, pwgfullgrid-*, pwgubound-*, pwggridinfo-*). The old code
# COMMENTED OUT parallelstage/manyseeds, forcing a plain sequential run that looks
# for a combined pwggrids.dat which the parallel build never makes -> use-old-grid
# can't find it -> pwhg_main RE-INTEGRATES from scratch (~hours of two-loop) every
# generation. The working reference (POWHEG-BOX/ggHH_SMEFT/test-pythia8/powheg.input)
# keeps exactly these directives. Force them ON (regardless of card state); replace
# numevts with the NEVENTS placeholder that runcmsgrid.sh fills per job.
sed -e 's/^ *#* *parallelstage.*/parallelstage 4/' \
    -e 's/^ *#* *manyseeds.*/manyseeds 1/' \
    -e 's/^ *#* *xgriditeration.*/xgriditeration 1/' \
    -e 's/^ *#* *maxseeds.*/maxseeds 9999/' \
    -e 's/^ *numevts.*/numevts NEVENTS/' \
    "$CARD" > "$RUNDIR/powheg.input.template"
cp "$PROC/testrun/run.sh" "$RUNDIR/run.sh"
python3 - "$BASE_SEED" > "$RUNDIR/pwgseeds.dat" <<'PY'
import sys
base = int(sys.argv[1])
print("\n".join(str(base + i) for i in range(1, 9999 + 1)))
PY

# 5) Run POWHEG stages 1-4 (run.sh does warmup + parallelstages sequentially)
cd "$RUNDIR"
echo "---- launching run.sh $NCORES $NXGRID ----"
# TESTMODE heartbeat: CERN disabled condor stdout/err streaming (Nov 2025), so a
# wall-killed job returns NO logs. Push the live fulllog to EOS every 2 min so any
# hang is diagnosable (which stage it stalled in) without another blind multi-hour
# round-trip. Best-effort; production (TESTMODE=0) skips it to avoid EOS spam.
HB_PID=""
if [ "$TESTMODE" = "1" ]; then
  ( while :; do sleep 120
      [ -f run_$POINT.fulllog ] && xrdcp -f run_$POINT.fulllog "$OUTPUT_DIR/${POINT}.fulllog.live" 2>/dev/null
    done ) &
  HB_PID=$!
fi
/usr/bin/time -v ./run.sh "$NCORES" "$NXGRID" 2>&1 | tee run_$POINT.fulllog
echo "---- run.sh finished ----"
[ -n "$HB_PID" ] && kill "$HB_PID" 2>/dev/null || true

# Sanity: a successful stage-4 run leaves event file(s)
if ! ls pwgevents*.lhe >/dev/null 2>&1; then
    echo "ERROR: no pwgevents*.lhe produced for $POINT — integration likely failed." >&2
    exit 42
fi

# 6) Assemble a CMS-runnable gridpack (standard POWHEG layout): runcmsgrid.sh +
#    pwhg_main + single-run card + this point's grids, all flat at the tar root so
#    ExternalLHEProducer's run_generic_tarball_*.sh can `./runcmsgrid.sh N seed ncpu`.
GP="${POINT}_gridpack.tar.gz"
shopt -s nullglob
# Bring the binary, entry point and GoSam cache into the run dir (flat layout).
cp "$PROC/runcmsgrid.sh" .              && chmod +x runcmsgrid.sh
# events.cdf usually already exists in the run dir as a SYMLINK into $PROC/Virtual
# (GoSam creates it during the run). Plain `cp -L` then sees source == dest ("are the
# same file") and aborts -> set -e kills the job after the full POWHEG run. Use
# --remove-destination to drop that symlink first, so we pack a real, self-contained
# file into the gridpack instead of a dangling link.
if [ -f "$PROC/Virtual/events.cdf" ]; then
    cp -Lf --remove-destination "$PROC/Virtual/events.cdf" ./events.cdf
fi
# creategrid.py: at generation pwhg_main's GoSam two-loop virtual-grid loader
# imports it to (re)assemble the combined SMEFT grid. combinegrids() short-circuits
# on the already-combined Virt_full-SMEFT*.grid we ship (recomputes nothing), but the
# file MUST be on the path or pwhg_main aborts "ERROR: Failed to find grid" -> empty
# LHE -> ExternalLHEProducer "Child failed exit 1" -> 0 events. Pack it flat next to
# pwhg_main. (Preflight step 3a already guaranteed it exists in $PROC/Virtual.)
cp -Lf --remove-destination "$PROC/Virtual/creategrid.py" ./creategrid.py
if [ "$INCLUDE_BINARY" = "1" ]; then
    cp "$PROC/pwhg_main" .
else
    echo "WARNING: INCLUDE_BINARY=0 — gridpack will NOT be CMS-runnable (no pwhg_main)" >&2
fi
# Integration outputs POWHEG leaves after parallelstages 1-4. Their exact names
# vary by stage/version, so glob EVERYTHING (nullglob drops patterns that match
# nothing). Crucially, every entry here must be a glob, NOT a bare literal: POWHEG-
# BOX-V2 does not emit a standalone `pwgxgrid.dat` for this process (the stage-1
# x-grid lives inside the pwg*grid*.dat files), so a literal `pwgxgrid.dat` made
# `tar` abort with "Cannot stat" -> exit 2 -> set -e killed the job with NO gridpack
# produced, but only AFTER the full ~52h integration. Globbing it makes it optional.
# CRITICAL: parallelstage-4 event generation (manyseeds mode) needs the FULL set of
# stage-1..3 outputs, not just the sampling grids. A validated TESTMODE build leaves:
#   pwggrid-*.dat            stage-1/2 importance-sampling grids
#   pwggridinfo-{btl,rmn}-*  stage-1 xgrid/gridinfo (WITHOUT these pwhg_main aborts
#                            "cannot load xgrid or gridinfo files; cannot perform
#                            stage 2" and re-integrates)
#   pwgfullgrid-*.dat        stage-3 full grids
#   pwgubound-*  pwgbtildeupb-*  pwgremnupb-*   upper bounds (btilde + remnant)
#   pwg-*-stat.dat  pwgcounters-*.dat            stat/counters
# The earlier PACK missed the pwggridinfo/upb/counters globs, so gridpacks could not
# replay and re-integrated every generation. Glob everything (nullglob drops empties).
GRIDS=( pwggrids*.dat pwggrid-*.dat pwggridinfo*.dat pwgubound*.dat
        pwgfullgrid*.dat pwgxgrid*.dat pwgbtildeupb*.dat pwgremnupb*.dat
        pwgcounters*.dat pwg-*-stat.dat )
# Fail LOUDLY here (seconds) rather than shipping a gridpack that can't generate
# events: a usable gridpack must carry at least one integration grid. This also
# guards against a future rename leaving the globs empty and tar'ing an empty set.
if ! ls pwg*grid*.dat >/dev/null 2>&1; then
    echo "ERROR: no integration grids (pwg*grid*.dat) present in $PWD after run.sh —" >&2
    echo "       cannot build a usable gridpack. Directory contents:" >&2
    ls -la >&2
    exit 43
fi
PACK=( runcmsgrid.sh creategrid.py powheg.input.template
       Virt_full-SMEFT*.grid events.cdf
       "${GRIDS[@]}" run_$POINT.fulllog )
[ "$INCLUDE_BINARY" = "1" ] && PACK+=( pwhg_main )
tar czf "$GP" "${PACK[@]}"

# 7) Deliver
echo "Delivering $GP -> $OUTPUT_DIR"
case "$OUTPUT_DIR" in
    root://*|/eos/*) xrdcp -f "$GP" "$OUTPUT_DIR/$GP" ;;
    *)               mkdir -p "$OUTPUT_DIR"; cp "$GP" "$OUTPUT_DIR/$GP" ;;
esac
echo "==== $(date) | DONE $POINT | $(du -h "$GP" | cut -f1) ===="
