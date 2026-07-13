#!/bin/bash
# Package the already-built ggHH_SMEFT process into a portable tarball that the
# Condor jobs unpack at runtime. Contains only what is needed to RUN (not rebuild):
# the pwhg_main binary, the Virtual/ grids + helpers, the shell/ helpers and run.sh.
# The 834M obj-gfortran / GoSamlib build tree is excluded.
#
# Run this ONCE (re-run only if the process is recompiled).
set -euo pipefail

HERE_TB=$(cd "$(dirname "$0")" && pwd)
# PROC_DIR = the compiled POWHEG-BOX process (external build; set PROC_DIR or GEN_DIR
# to point at yours). OUT_TARBALL defaults beside this script; upload it to the hosted
# EOS location (see submit_smeft.sh PROCESS_TARBALL) after rebuilding.
GEN_DIR=${GEN_DIR:-/afs/cern.ch/work/a/acarvalh/generation_k4}
PROC_DIR=${PROC_DIR:-$GEN_DIR/POWHEG-BOX/ggHH_SMEFT}
OUT_TARBALL=${OUT_TARBALL:-$HERE_TB/ggHH_SMEFT_run.tar.gz}

if [ ! -x "$PROC_DIR/pwhg_main" ]; then
    echo "ERROR: $PROC_DIR/pwhg_main not found/executable. Build the process first." >&2
    exit 1
fi
# creategrid.py must be in the tarball (run_smeft_gridpack.sh packs it from
# $PROC/Virtual/creategrid.py into every gridpack; without it pwhg_main aborts at
# generation with "Failed to find grid" -> 0 events). It lives in Virtual/ and is
# NOT excluded below, but assert it explicitly so a future missing file fails here
# (seconds) rather than silently producing born-broken gridpacks.
if [ ! -f "$PROC_DIR/Virtual/creategrid.py" ]; then
    echo "ERROR: $PROC_DIR/Virtual/creategrid.py missing — every gridpack built from" >&2
    echo "       this tarball would fail at generation. Restore it before packing." >&2
    exit 1
fi

echo "Packing process from $PROC_DIR -> $OUT_TARBALL"
# Bundle the CMS gridpack entry point so run_smeft_gridpack.sh finds it at
# $PROC/runcmsgrid.sh inside the job. Single source of truth: runcmsgrid.sh lives in
# the committed MYOMC repo beside the nanogen scripts (../submission/), shared with it.
HERE=$(cd "$(dirname "$0")" && pwd)
RUNCMSGRID_SRC="$HERE/../submission/runcmsgrid.sh"
cp "$RUNCMSGRID_SRC" "$PROC_DIR/runcmsgrid.sh"
chmod +x "$PROC_DIR/runcmsgrid.sh"
# Tar with a stable top-level dir name 'ggHH_SMEFT' so the job layout is predictable.
# Write to a temp file then atomically mv into place: gridpack jobs `cp` this path
# at startup, so an in-place `tar -czf` could hand a concurrently-starting job a
# half-written (corrupt) tarball -> `tar xzf` fails -> job dies. The rename is atomic
# on the same filesystem, so a job always sees either the whole old or whole new file.
TMP_TARBALL="$OUT_TARBALL.tmp.$$"
trap 'rm -f "$TMP_TARBALL"' EXIT
tar -C "$(dirname "$PROC_DIR")" \
    --exclude='obj-gfortran' --exclude='mod-gfortran' --exclude='GoSamlib' \
    --exclude='*.o' --exclude='*.a' --exclude='Docs' \
    --exclude='run_point*' --exclude='testrun/pwg*' --exclude='*.lhe' \
    -czf "$TMP_TARBALL" "$(basename "$PROC_DIR")"
mv -f "$TMP_TARBALL" "$OUT_TARBALL"

echo "Done: $(du -h "$OUT_TARBALL" | cut -f1)  $OUT_TARBALL"
