#!/bin/bash
# CMS gridpack entry point for ggHH_SMEFT (POWHEG-BOX-V2, full-theory mtdep 3).
#
# This is the standard CMS POWHEG convention: GeneratorInterface/LHEInterface's
# run_generic_tarball_{cvmfs,xrootd}.sh untars the gridpack into the work dir and
# calls
#       ./runcmsgrid.sh <nevents> <rndSeed> <ncpu>
# We then generate <nevents> events reusing the pre-computed integration grids and
# write cmsgrid_final.lhe in the current directory.
#
# The gridpack must contain (assembled by run_smeft_gridpack.sh):
#   pwhg_main                  the built POWHEG binary
#   powheg.input.template      single-run card, NEVENTS/SEED placeholders
#   Virt_full-SMEFT*.grid      combined full-theory virtual grid (this point)
#   events.cdf                 GoSam phase-space cache
#   pwggrids*.dat pwgubound*.dat pwgfullgrid*.dat pwgxgrid.dat   integration grids
set -euo pipefail

nevt=${1:?usage: runcmsgrid.sh <nevents> <seed> <ncpu>}
seed=${2:?usage: runcmsgrid.sh <nevents> <seed> <ncpu>}
ncpu=${3:-1}

# pwhg_main is built against the LCG_107 view (gfortran 11, LHAPDF 6.5.5, PDF
# sets on CVMFS); source it so the binary's runtime libraries + PDFs are present.
# NOTE: this view is x86_64-EL9 — run the generation step in an el9 environment.
LCG_VIEW=${LCG_VIEW:-/cvmfs/sft.cern.ch/lcg/views/LCG_107/x86_64-el9-gcc11-opt/setup.sh}
# When ExternalLHEProducer runs us, the CMSSW_14_1_8 runtime is already active and
# its externals put an OLD libz.so.1 (1.2.8, no ZLIB_1.2.9 symbol) ahead on
# LD_LIBRARY_PATH. The LCG_107 toolchain's libpng16 needs ZLIB_1.2.9, so sourcing
# the view trips a loader error ("version `ZLIB_1.2.9' not found") in a peripheral
# tool. That's harmless to pwhg_main itself (it only needs basic zlib symbols, which
# CMSSW's 1.2.8 provides), BUT under `set -e` the nonzero return aborts runcmsgrid
# right here -> pwhg_main never runs -> empty LHE -> ExternalLHEProducer "Child
# failed exit 1" -> 0 events. Relax -e AND -u across the source so the cosmetic
# failure can't abort us; then put the LCG view's own lib dir first so its newer
# zlib leads for anything else that needs it.
LCG_LIB="$(dirname "$LCG_VIEW")/lib"
set +eu; source "$LCG_VIEW"; set -eu
export LD_LIBRARY_PATH="$LCG_LIB:${LD_LIBRARY_PATH:-}"

# pwhg_main's GoSam virtual-grid loader searches the PYTHON sys.path (not cwd) for
# the shipped Virt_full-SMEFT*.grid / events.cdf / creategrid.py. Sourcing the LCG
# view sets PYTHONPATH to CVMFS-only dirs, so the run dir is NOT searched and the
# load fails with "ERROR: Failed to find grid" -> pwhg_main aborts -> empty LHE ->
# ExternalLHEProducer "Child failed with exit code 1" -> 0 events. Prepend cwd so
# the loader finds the grids sitting next to pwhg_main.
export PYTHONPATH=$PWD:${PYTHONPATH:-}

echo "runcmsgrid: nevents=$nevt seed=$seed ncpu=$ncpu  ($(date))"

# MULTICORE generation. gg->HH is loop-induced (~11 CPU-s/event, one-loop ME per
# event) with ~76 s fixed GoSam init per pwhg_main process. Split the requested
# events across $ncpu parallel manyseeds streams for ~ncpu x wall speedup. Each
# stream reuses the SAME shipped combined grids (parallelstage-4 mode); the seed
# INDEX only selects the pwgseeds.dat line + output name (pwgevents-<idx>.lhe).
NCPU=$ncpu
# Events per stream, rounded UP so the total is >= nevt (slight overshoot is standard
# for CMS multicore gridpacks; the downstream step reads however many events land).
PER=$(( (nevt + NCPU - 1) / NCPU ))
sed -e "s/NEVENTS/$PER/" powheg.input.template > powheg.input

# One distinct RNG seed per stream. $seed is the externalLHEProducer seed, i.e. the
# lower edge (+1) of this (point,job)'s disjoint 1000-wide seed window assigned by
# submit_nanogen.sh (base = index*100000 + gjob*1000; LHE = base+1 = $seed,
# Pythia = base+2). Cores take base+10+i = seed+9+i, staying INSIDE the window (so
# they can't collide with any other job's window) and clear of the LHE/Pythia seeds.
# n=$NCPU cores => offsets +10..+(9+n) << 1000. Positive and < 2^31.
python3 - "$seed" "$NCPU" > pwgseeds.dat <<'PY'
import sys
seed, n = int(sys.argv[1]), int(sys.argv[2])
print("\n".join(str(seed + 9 + i) for i in range(1, n + 1)))
PY

echo "runcmsgrid: launching $NCPU streams x $PER events (seed base $seed)"
pids=()
for i in $(seq 1 "$NCPU"); do echo "$i" | ./pwhg_main > "pwhg-$i.log" 2>&1 & pids+=("$!"); done
rc=0; for p in "${pids[@]}"; do wait "$p" || rc=1; done
if [ "$rc" != 0 ]; then echo "pwhg_main FAILED in >=1 stream"; for i in $(seq 1 "$NCPU"); do echo "--- pwhg-$i.log tail ---"; tail -40 "pwhg-$i.log"; done; exit 1; fi

# Merge the per-stream LHE files into one valid file: take the full header/init from
# the first, append ONLY the <event>...</event> blocks from all, then close. A naive
# `cat` would produce multiple <LesHouchesEvents> roots (invalid LHE).
shopt -s nullglob
LHES=( pwgevents-*.lhe )
[ "${#LHES[@]}" -gt 0 ] || { echo "runcmsgrid: no LHE produced"; for i in $(seq 1 "$NCPU"); do tail -40 "pwhg-$i.log"; done; exit 1; }
# Header + init: everything up to and including the first </init> of stream 1.
sed -n '1,/<\/init>/p' "${LHES[0]}" > cmsgrid_final.lhe
# All <event> blocks from every stream.
for f in "${LHES[@]}"; do sed -n '/<event>/,/<\/event>/p' "$f" >> cmsgrid_final.lhe; done
echo '</LesHouchesEvents>' >> cmsgrid_final.lhe

# Sanitize "--" INSIDE XML comment blocks. POWHEG dumps powheg.input into the LHE
# <header> inside <!-- ... -->, and this card has comment lines like "! -- parallel".
# A bare "--" is ILLEGAL inside an XML comment, so ExternalLHEProducer's XML parser
# aborts ("'--' sequence is illegal in comment") -> 0 events. Replace interior "--"
# with "- -" only between <!-- and --> (delimiters + event data untouched; the header
# is informational, so this is physics-neutral).
awk '
  index($0,"<!--")>0 { incom=1 }
  incom==1 && $0 !~ /<!--/ && $0 !~ /-->/ { while (index($0,"--")>0) sub(/--/,"- -") }
  index($0,"-->")>0 { incom=0 }
  { print }
' cmsgrid_final.lhe > cmsgrid_final.lhe.tmp && mv -f cmsgrid_final.lhe.tmp cmsgrid_final.lhe

nev=$(grep -c '</event>' cmsgrid_final.lhe || true)
echo "runcmsgrid: wrote cmsgrid_final.lhe ($nev events from $NCPU streams)  ($(date))"
