#!/bin/bash
# Convenience wrapper: submit NANOGEN for the SMEFT truncation-study gridpacks (the 5
# LHCHWG-2026-006 benchmarks x {lin,quad} = 10 points, built by
# gridpack/submit_truncation.sh). Thin front-end over submit_nanogen.sh --grid trunc, so
# it reuses the SAME condor/CRAB backend, collision-free seed scheme, --report and
# --only-missing logic as the main production -- only the defaults differ (all 10 tags,
# 13.6 TeV, the paper energy).
#
#   ./submit_nanogen_trunc.sh                 # submit all 10 (condor), 50k evts/point
#   ./submit_nanogen_trunc.sh --report        # TEST IF ALL DONE: per-tag NANOGEN status
#   ./submit_nanogen_trunc.sh --only-missing  # resubmit only not-yet-done jobs
#   ./submit_nanogen_trunc.sh --dry-run       # build fragments + joblist, submit nothing
#   ./submit_nanogen_trunc.sh --backend crab  # CRAB backend (one PrivateMC task per tag)
#   ./submit_nanogen_trunc.sh --test          # 1-job x 100-evt smoke test on the first tag
# Any extra flags are passed straight through to submit_nanogen.sh (e.g. --njobs,
# --total-events, --hard-only, --flavour, --job-offset).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

# Nanogen can't run until a gridpack exists, so a friendly heads-up if none are there yet.
GPDIR=root://eosuser.cern.ch//eos/user/a/acarvalh/gghh_smeft_truncation_gridpacks_13p6TeV
export X509_USER_PROXY=${X509_USER_PROXY:-$HOME/private/x509up}
nready=$(xrdfs eosuser.cern.ch ls "${GPDIR#root://eosuser.cern.ch/}" 2>/dev/null | grep -c '_gridpack\.tar\.gz$' || true)
echo ">> truncation gridpacks ready on EOS: ${nready:-0}/10  ($GPDIR)"
[ "${nready:-0}" -eq 0 ] && echo ">> NOTE: no gridpacks yet -- nanogen jobs only queue for tags whose gridpack exists (cluster 11597076 is still building)."

# --grid trunc + all-10 default (no --start/--end/--ncards); forward every other flag.
exec "$HERE/submit_nanogen.sh" --grid trunc --ecm 13.6 "$@"
