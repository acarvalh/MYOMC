#!/bin/bash
# CRAB backend for ggHH_SMEFT NANOGEN: one CRAB *task* per point, PrivateMC +
# EventBased splitting (CRAB itself splits TOTAL_EVENTS into jobs of NEVENTS and
# randomises the per-job seeds). Invoked by submit_nanogen.sh --backend crab,
# but can be run standalone after fragments are generated with --gridpack-base.
#
# INITIAL PRODUCTION ONLY — DO NOT use CRAB to add statistics to a point that
# already ran. CRAB seeds jobs by job-number-within-task (no fixed seed in the cfg),
# so a SECOND task for the same point restarts job numbering at 1 and reuses the
# first task's seed sequence on the SAME gridpack => DUPLICATE events. There is no
# CRAB knob to offset the base seed (hardcoding one would make all jobs in the task
# share a single seed). For collision-free TOP-UPS, use the condor backend instead:
#   ./submit_nanogen.sh ... --job-offset <jobs-already-done> --njobs <extra>
# (condor uses disjoint index-based seed windows; see run.sh / README "Seeds").
# `crab resubmit` (re-running only FAILED jobs of an existing task) is safe.
#
# Env (set by submit_nanogen.sh, or export before calling):
#   FRAGDIR       : dir of self-contained fragments (xrootd gridpack baked in)
#   OUTPUT_LFN    : CRAB Data.outLFNDirBase, e.g. /store/user/acarvalh/smeft_nanogen
#   STORAGE_SITE  : CRAB Site.storageSite, e.g. T3_CH_CERNBOX (for /eos/user) or T2_CH_CERN
#   TOTAL_EVENTS  : events per point (Data.totalUnits)                    [100000]
#   NEVENTS       : events per job   (Data.unitsPerJob)                   [20000]
#   NTHREADS      : cores per job    (JobType.numCores)                   [1]
#   MEM           : memory MB        (JobType.maxMemoryMB)                [4000]
#   RUN_SH        : campaign NANOGEN run.sh (for the CMSSW version + cmsDriver args)
#   DRYRUN        : 1 = build cfgs + crabConfigs but don't `crab submit`  [0]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
FRAGDIR=${FRAGDIR:?set FRAGDIR}
OUTPUT_LFN=${OUTPUT_LFN:?set OUTPUT_LFN}
STORAGE_SITE=${STORAGE_SITE:-T3_CH_CERNBOX}
TOTAL_EVENTS=${TOTAL_EVENTS:-100000}
NEVENTS=${NEVENTS:-20000}
NTHREADS=${NTHREADS:-1}
MEM=${MEM:-4000}
DRYRUN=${DRYRUN:-0}
# GRID drives the CRAB/EOS naming scheme. For 9d the coupling-encoded point name exceeds
# CRAB's 99-char Data.outputPrimaryDataset limit (9 operators, ~54 chars of key labels
# alone before any value), so 9d tasks are named by their 1-based GRID INDEX instead:
# ggHH_SMEFT_9d_00701. 4d/5d names are short (<=83 chars) and keep their coupling names.
# report_batches uses the identical rule (req_for) to count/locate the output.
GRID=${GRID:-}
# el9-native Run 3 release so the el9 gridpack runs natively on the grid WN.
CMSSW_VERSION=${CMSSW_VERSION_NANOGEN:-CMSSW_14_1_8}
SCRAM_ARCH=${SCRAM_ARCH:-el9_amd64_gcc12}
export SCRAM_ARCH

CFGDIR=$HERE/cfgs
CRABDIR=$HERE/crabConfigs
mkdir -p "$CFGDIR" "$CRABDIR"

# 1) CMSSW + CRAB environment (build CMSSW once, reuse). NANOGEN needs an el9 shell.
#    The cmsset_default.sh / scram / crab-setup.sh scripts are NOT written to be
#    sourced under `set -u` (they reference unbound vars) nor `set -e`, so relax
#    strict mode around them — otherwise the first unbound var aborts this whole
#    script SILENTLY (crab-setup's stderr was hidden), leaving no cfgs and no
#    crab_nanogen. Restore strict mode right after.
set +u +e
source /cvmfs/cms.cern.ch/cmsset_default.sh
ENVROOT=$HERE/crab_env
if [ ! -d "$ENVROOT/$CMSSW_VERSION" ]; then
  echo ">> setting up $CMSSW_VERSION (SCRAM_ARCH=$SCRAM_ARCH) in $ENVROOT"
  mkdir -p "$ENVROOT"; ( cd "$ENVROOT" && scram project -n "$CMSSW_VERSION" "$CMSSW_VERSION" )
fi
cd "$ENVROOT/$CMSSW_VERSION/src"
eval "$(scram runtime -sh)"
mkdir -p Configuration/GenProduction/python
cd "$HERE"

# 2) CRAB client. crab-setup.sh is the current path; the crab3/crab.sh fallback is
#    for older releases. Verify `crab` is actually on PATH afterwards.
source /cvmfs/cms.cern.ch/common/crab-setup.sh 2>/dev/null || \
  source /cvmfs/cms.cern.ch/crab3/crab.sh 2>/dev/null || true
set -u -e
command -v crab >/dev/null 2>&1 || {
  echo "ERROR: CRAB client not found after sourcing the CRAB setup. On lxplus try:" >&2
  echo "       source /cvmfs/cms.cern.ch/common/crab-setup.sh" >&2
  exit 1
}

USERNAME=$(whoami)

# A valid grid proxy is required to `crab submit`. Check up front (real runs only)
# so we fail with a clear message instead of erroring on the first submit.
if [ "$DRYRUN" != "1" ]; then
  if ! voms-proxy-info -exists -valid 0:10 >/dev/null 2>&1; then
    echo "ERROR: no valid grid proxy (>=10 min). Run first:" >&2
    echo "       voms-proxy-init --rfc --voms cms -valid 192:00" >&2
    exit 1
  fi
fi

submitted=0; failed=0; namefail=0; otherfail=0; already=0
FAILLOG=$HERE/crab_submit_failures.tsv
: > "$FAILLOG"

# Map each fragment's point name -> its 1-based grid index from the run manifest
# (make_fragments.py writes manifest.json with 0-based "index"; +1 = report_batches' i).
# Only needed for the length-fallback below, but cheap and harmless to always build.
declare -A IDX1=()
if [ -f "$FRAGDIR/manifest.json" ]; then
  while IFS=$'\t' read -r nm ix; do IDX1["$nm"]=$ix; done < <(
    python3 -c 'import json,sys
for m in json.load(open(sys.argv[1])): print(m["name"]+"\t"+str(m["index"]+1))' \
      "$FRAGDIR/manifest.json")
fi

for frag in "$FRAGDIR"/*.py; do
  point=$(basename "$frag" .py)
  # CRAB requestName / Data.outputPrimaryDataset: <=99 chars, must match [A-Za-z0-9_-]*.
  # LENGTH-CONDITIONAL naming: keep the coupling name when it fits (4d/5d, and the
  # mostly-zero 2D-plane 9d points already on EOS), so existing output stays addressable.
  # Only the fully-mixed 9d points (all 9 operators, >99 chars) fall back to an index name
  # ggHH_SMEFT_<grid>_NNNNN. report_batches.req_for() applies the IDENTICAL rule.
  req=${point#powheg_}
  if [ ${#req} -gt 99 ]; then
    ix=${IDX1[$point]:-}
    if [ -z "$ix" ]; then
      echo "!! SKIP $point -- name >99 chars and no manifest index for the fallback" >&2
      printf '%s\t%s\n' "$point" "name >99 chars, no manifest index" >> "$FAILLOG"
      failed=$((failed + 1)); namefail=$((namefail + 1)); continue
    fi
    req=$(printf 'ggHH_SMEFT_%s_%05d' "${GRID:-9d}" "$ix")
  fi

  # IDEMPOTENT RE-RUNS: crab keeps a per-task work area 'crab_nanogen/crab_<req>'.
  # If it already exists this point was already submitted, and `crab submit` would
  # abort with "Working area already exists / Please change the requestName". Skip it
  # up front (also saves the ~minute of cmsDriver below) so re-running a range only
  # submits the genuinely-new points. Use --force-resubmit / delete the work area to
  # re-send one on purpose.
  if [ "$DRYRUN" != "1" ] && [ -d "$HERE/crab_nanogen/crab_${req}" ]; then
    echo ">> skip $point -- already submitted (crab_nanogen/crab_${req} exists)"
    already=$((already + 1)); continue
  fi

  # Thread count is baked into the cfg NAME so a cfg built with a different
  # --nThreads can never be silently reused (CRAB rejects a task whose
  # numCores != the PSet's numberOfThreads). Change NTHREADS => new cfg, no stale
  # reuse, and the crabConfig below points at the matching file.
  cfg="$CFGDIR/NANOGEN_${point}_nt${NTHREADS}_cfg.py"
  crabcfg="$CRABDIR/crabConfig_${point}.py"

  # 2a) Build the cmsRun cfg (cmsDriver). NO fixed RNG seed — CRAB PrivateMC sets
  #     per-job seeds itself. Conditions/era mirror campaigns/NANOGEN/run.sh.
  if [ ! -f "$cfg" ]; then
    cp "$frag" "$ENVROOT/$CMSSW_VERSION/src/Configuration/GenProduction/python/fragment.py"
    ( cd "$ENVROOT/$CMSSW_VERSION/src" && scram b -j4 >/dev/null )
    cmsDriver.py Configuration/GenProduction/python/fragment.py \
        --python_filename "$cfg" \
        --eventcontent NANOAODSIM --datatier NANOGEN \
        --step LHE,GEN,NANO:@GEN \
        --conditions 140X_mcRun3_2024_realistic_v26 \
        --beamspot Realistic25ns13p6TeVEarly2023Collision \
        --era Run3_2024 \
        --customise Configuration/DataProcessing/Utils.addMonitoring \
        --geometry DB:Extended --no_exec --mc --nThreads "$NTHREADS" \
        --customise_commands "process.source.numberEventsInLuminosityBlock=cms.untracked.uint32(${NEVENTS})" \
        -n "$NEVENTS"
  fi

  # 2b) Write the per-point CRAB config (PrivateMC + EventBased).
  cat > "$crabcfg" <<PY
from CRABClient.UserUtilities import config
config = config()

config.General.requestName     = '${req}'
config.General.workArea        = 'crab_nanogen'
config.General.transferOutputs = True
config.General.transferLogs    = True

config.JobType.pluginName  = 'PrivateMC'
config.JobType.psetName    = '${cfg}'
config.JobType.numCores    = ${NTHREADS}
config.JobType.maxMemoryMB = ${MEM}
config.JobType.allowUndistributedCMSSW = True

config.Data.splitting           = 'EventBased'
config.Data.unitsPerJob         = ${NEVENTS}
config.Data.totalUnits          = ${TOTAL_EVENTS}
config.Data.outputPrimaryDataset = '${req}'
config.Data.outLFNDirBase       = '${OUTPUT_LFN}'
config.Data.publication         = False
config.Data.outputDatasetTag    = 'ggHH_SMEFT_NANOGEN'

config.Site.storageSite = '${STORAGE_SITE}'
PY

  if [ "$DRYRUN" = "1" ]; then
    echo "   [dry-run] cfg+crabConfig ready for $point"
    submitted=$((submitted + 1))
  else
    echo ">> crab submit $point"
    # SKIP-ON-ERROR: a failed `crab submit` must NOT abort the whole run (set -e would),
    # so we can push every submittable point and TALLY the rest. The `if` guards set -e.
    if out=$(crab submit -c "$crabcfg" 2>&1); then
      echo "$out" | grep -iE 'Success|Task name|project dir' | head -3 || true
      submitted=$((submitted + 1))
    else
      # Classify the failure. Match on the ACTUAL wording, not a stray field name:
      # CRAB echoes "Please change the requestName" for an already-submitted task and
      # prints the outputPrimaryDataset line in benign context, so grepping bare
      # 'requestName'/'outputPrimaryDataset' mislabels those as length errors (it did:
      # a re-run of an already-done range reported "N too long"). The real length error
      # is literally "should not have more than 99 characters".
      if echo "$out" | grep -qiE 'already exists|change the requestName'; then
        # Not a failure -- the task is already submitted (belt-and-braces; the pre-check
        # above normally catches this before we ever call crab submit).
        echo ">> skip $point -- already submitted (crab reports work area exists)"
        already=$((already + 1)); continue
      elif echo "$out" | grep -qiE 'should not have more than|not have more than 99|match the regular expression'; then
        reason='name too long (>99/100-char CRAB limit)'; namefail=$((namefail + 1))
      else
        reason='crab submit error'; otherfail=$((otherfail + 1))
      fi
      echo "!! SKIP $point -- $reason" >&2
      # keep the last line of crab's own message for context
      echo "$out" | grep -iE 'Invalid|Error|Reason' | tail -1 | sed 's/^/     /' >&2 || true
      printf '%s\t%s\n' "$point" "$reason" >> "$FAILLOG"
      failed=$((failed + 1))
    fi
  fi
done

if [ "$DRYRUN" = "1" ]; then
  cat >&2 <<BANNER

========================================================================
  DRY RUN — NOTHING WAS SUBMITTED TO CRAB.
  Prepared $submitted crabConfig(s) in $CRABDIR
  and cmsRun cfg(s) in $CFGDIR, but did NOT call 'crab submit'.
  The samples will NOT be produced until you submit them.

  To actually send the jobs (needs a valid grid proxy):
    voms-proxy-init --rfc --voms cms -valid 192:00
    for c in $CRABDIR/crabConfig_*.py; do crab submit -c "\$c"; done
      (or just re-run this command WITHOUT --dry-run)

  Then monitor:
    crab status -d crab_nanogen/crab_<requestName>
========================================================================
BANNER
else
  echo ">> CRAB: submitted $submitted task(s). Monitor with:"
  echo "     crab status -d crab_nanogen/crab_<requestName>"
  echo "   Resubmit only failed jobs of a task with: crab resubmit -d crab_nanogen/crab_<requestName>"
  if [ "$already" -gt 0 ]; then
    echo ">> skipped $already point(s) already submitted (work area exists) -- not re-sent."
  fi
  if [ "$failed" -gt 0 ]; then
    echo
    echo "!! SKIPPED $failed point(s) that failed to submit (run continued past them):"
    echo "     $namefail were too long for the 99/100-char CRAB name limit"
    echo "     $otherfail failed for other reasons"
    echo "   Full list: $FAILLOG"
  fi
fi
