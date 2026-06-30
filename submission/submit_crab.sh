#!/bin/bash
# CRAB backend for ggHH_SMEFT NANOGEN: one CRAB *task* per point, PrivateMC +
# EventBased splitting (CRAB itself splits TOTAL_EVENTS into jobs of NEVENTS and
# randomises the per-job seeds). Invoked by submit_nanogen.sh --backend crab,
# but can be run standalone after fragments are generated with --gridpack-base.
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
# el9-native Run 3 release so the el9 gridpack runs natively on the grid WN.
CMSSW_VERSION=${CMSSW_VERSION_NANOGEN:-CMSSW_14_1_8}
SCRAM_ARCH=${SCRAM_ARCH:-el9_amd64_gcc12}
export SCRAM_ARCH

CFGDIR=$HERE/cfgs
CRABDIR=$HERE/crabConfigs
mkdir -p "$CFGDIR" "$CRABDIR"

# 1) CMSSW environment (build once, reuse). NANOGEN needs an el9 shell.
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

# 2) CRAB client.
source /cvmfs/cms.cern.ch/common/crab-setup.sh 2>/dev/null || \
  source /cvmfs/cms.cern.ch/crab3/crab.sh

USERNAME=$(whoami)

submitted=0
for frag in "$FRAGDIR"/*.py; do
  point=$(basename "$frag" .py)
  # CRAB requestName: <=100 chars, [A-Za-z0-9_-] only. Drop the long prefix.
  req=${point#powheg_}
  req=${req:0:100}
  cfg="$CFGDIR/NANOGEN_${point}_cfg.py"
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
        --customise_commands "process.source.numberEventsInLuminosityBlock=cms.untracked.uint32(${NEVENTS})\\nprocess.genParticleTable.variables.mass.precision=cms.untracked.int32(-1)\\nprocess.genJetTable.variables.mass.precision=cms.untracked.int32(-1)" \
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
  else
    echo ">> crab submit $point"
    crab submit -c "$crabcfg"
  fi
  submitted=$((submitted + 1))
done

echo ">> CRAB: prepared $submitted task(s) (dry-run=$DRYRUN). configs in $CRABDIR, cfgs in $CFGDIR"
[ "$DRYRUN" = "1" ] && echo ">> to submit: for c in $CRABDIR/crabConfig_*.py; do crab submit -c \$c; done"
