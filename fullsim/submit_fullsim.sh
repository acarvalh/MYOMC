#!/bin/bash
# FULL-SIM 2024 driver for selected ggHH_SMEFT points, in three HH decay channels
# (bbgg, 4b, bbtt). Runs the complete Run3Summer24 chain LHE->GEN->SIM->DIGI->HLT->
# RECO->MINIAODSIM->NANOAODSIM via the campaign run.sh, submitted with bin/crun.py.
#
# SEPARATE from the gridpack (submit_smeft.sh) and NANOGEN (submit_nanogen.sh)
# pipelines: its own dir, its own fragments, its own EOS output, its own condor
# jobs. It only READS the SMEFT gridpacks the other pipeline produced.
#
# Points are given with the REQUIRED --points option, as a COMMA-SEPARATED list of
# JSON index NUMBERS (1-based, the same numbering as --start/--end elsewhere in MYOMC).
#
# Examples:
#   ./submit_fullsim.sh --points 12,57,340                    # 3 points, all 3 channels, 500k each
#   ./submit_fullsim.sh --bbgg --points 12,57                 # only bbgg
#   ./submit_fullsim.sh --bbgg --bbtt --points 12,57          # bbgg and bbtt
#   ./submit_fullsim.sh --channels bbgg,4b --points 12,57     # same, via comma list
#   ./submit_fullsim.sh --nevents 200000 --points 12          # 200k events/point/channel
#   ./submit_fullsim.sh --grid 9d --points 4,8,15,16,23       # indices into the 9D grid
#   ./submit_fullsim.sh --dry-run --points 12,57,340          # build fragments + print crun cmds
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
MYOMC=${MYOMC:-$(cd "$HERE/.." && pwd)}
SUBDIR=$MYOMC/submission

# -------- defaults (override via flags) --------
CHANNELS=bbgg,4b,bbtt                         # default set; narrow it with --channels or --bbgg/--4b/--bbtt
CHSEL=()                                      # channels picked via the bare --bbgg/--4b/--bbtt flags
NEVENTS=500000                                # TOTAL events per point per channel (default 500k)
NEVENTS_JOB=2000                              # events per condor job; njobs = ceil(NEVENTS/this)
NJOBS=0                                       # 0 => derive from NEVENTS / NEVENTS_JOB
GRID=5d                                       # 4d | 5d | 9d: which JSON the indices refer to
POINTS=""                                     # explicit points JSON; overrides --grid
GRIDPACK_DIR=""                               # explicit xrootd gridpack base; overrides --grid
CAMPAIGN=Run3Summer24wmLHEGS                  # 2024 full-sim chain (LHE..NANOAODSIM)
OUTEOS=/store/user/acarvalh/smeft_fullsim_2024   # EOS base; per-channel subdir appended
KEEP="MINI,NANO"                              # tiers to keep: any of GS,DR,RECO,MINI,NANO
COMENERGY=13600                               # 2024 = Run 3 13.6 TeV
SEED_OFFSET=0                                 # crun seed offset (for collision-free top-ups)
MEM=7900                                      # request_memory (MB) per job
MAXTHREADS=8                                  # cmsRun threads (= request_cpus)
USE_ENV=1                                     # pass --env to crun (pre-packaged CMSSW tarball)
USE_PILEUP_FILE=1                             # pass --pileup_file (premade premix list)
DRYRUN=0
POINTLIST=""                                  # REQUIRED: --points 12,57,340 (comma-separated 1-based indices)

while [ $# -gt 0 ]; do
  case "$1" in
    --points)      POINTLIST=$2; shift 2;;
    --channels)    CHANNELS=$2; shift 2;;
    --bbgg)        CHSEL+=(bbgg); shift;;
    --4b)          CHSEL+=(4b);   shift;;
    --bbtt)        CHSEL+=(bbtt); shift;;
    --nevents)     NEVENTS=$2; shift 2;;
    --nevents-job) NEVENTS_JOB=$2; shift 2;;
    --njobs)       NJOBS=$2; shift 2;;
    --grid)        GRID=$2; shift 2;;
    --points-json) POINTS=$2; shift 2;;
    --gridpack-dir) GRIDPACK_DIR=$2; shift 2;;
    --campaign)    CAMPAIGN=$2; shift 2;;
    --outeos)      OUTEOS=$2; shift 2;;
    --keep)        KEEP=$2; shift 2;;
    --comenergy)   COMENERGY=$2; shift 2;;
    --seed-offset) SEED_OFFSET=$2; shift 2;;
    --mem)         MEM=$2; shift 2;;
    --max-threads) MAXTHREADS=$2; shift 2;;
    --no-env)      USE_ENV=0; shift;;
    --no-pileup-file) USE_PILEUP_FILE=0; shift;;
    --dry-run|-n)  DRYRUN=1; shift;;
    -h|--help)     sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0;;
    *)             echo "unknown arg: $1 (points go in --points 12,57,340)" >&2; exit 1;;
  esac
done

[ -n "$POINTLIST" ] || { echo "ERROR: give the points with --points 12,57,340 (comma-separated 1-based indices)" >&2; exit 1; }
IFS=',' read -ra POSITIONAL <<< "$POINTLIST"

# Bare --bbgg/--4b/--bbtt flags, if any were given, define the channel set
# (overriding the --channels comma list / its default).
[ "${#CHSEL[@]}" -gt 0 ] && CHANNELS=$(IFS=,; echo "${CHSEL[*]}")

# Resolve --grid into the bundled points JSON + its xrootd gridpack dir (13.6 TeV,
# untagged -> the live Run-3 production, which is what a 2024 sample must use).
case "$GRID" in
  4d) J=$SUBDIR/FINALgrid_for_SMEFT_4D_leadingOnly_updated_PDF.json
      GP=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_keep_stage1;;
  5d) J=$SUBDIR/FINALgrid_for_SMEFT_5D_leading_plus_ctg.json
      GP=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_5param_keep_stage1;;
  9d) J=$SUBDIR/FINALgrid_for_SMEFT_9D_extension_only.json
      GP=root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen_9d/gridpacks;;
  *)  echo "--grid must be 4d, 5d or 9d (got '$GRID')" >&2; exit 1;;
esac
[ -n "$POINTS" ]       || POINTS=$J
[ -n "$GRIDPACK_DIR" ] || GRIDPACK_DIR=$GP
[ -f "$POINTS" ] || { echo "ERROR: points JSON not found: $POINTS" >&2; exit 1; }

# Derive njobs from the total unless the user pinned it.
if [ "$NJOBS" -le 0 ]; then
  NJOBS=$(( (NEVENTS + NEVENTS_JOB - 1) / NEVENTS_JOB ))
fi

# Map --keep tiers to crun flags.
KEEPFLAGS=""
IFS=',' read -ra _t <<< "$KEEP"
for t in "${_t[@]}"; do
  case "$t" in
    GS)   KEEPFLAGS+=" --keepGS";;
    DR)   KEEPFLAGS+=" --keepDR";;
    RECO) KEEPFLAGS+=" --keepRECO";;
    MINI) KEEPFLAGS+=" --keepMINI";;
    NANO) KEEPFLAGS+=" --keepNANO";;
    *)    echo "--keep tier '$t' unknown (GS,DR,RECO,MINI,NANO)" >&2; exit 1;;
  esac
done

: "${MYOMCPATH:?ERROR: \$MYOMCPATH unset — run 'source env.sh' in MYOMC first (crun.py needs it)}"
CRUN=$MYOMC/bin/crun.py
[ -f "$CRUN" ] || { echo "ERROR: crun.py not found at $CRUN" >&2; exit 1; }
FRAGDIR=$HERE/fragments_fullsim
mkdir -p "$FRAGDIR"

IFS=',' read -ra CHLIST <<< "$CHANNELS"
NPOINTS=$(python3 -c "import json;print(len(json.load(open('$POINTS'))))")

echo ">> campaign=$CAMPAIGN  grid=$GRID  comEnergy=${COMENERGY}  gridpacks=$GRIDPACK_DIR"
echo ">> channels=${CHLIST[*]}  events/pt/chan=$NEVENTS  ev/job=$NEVENTS_JOB  njobs=$NJOBS  keep=$KEEP"
echo ">> points (1-based): ${POSITIONAL[*]}   outEOS=$OUTEOS"
[ "$DRYRUN" = 1 ] && echo ">> DRY RUN — building fragments and printing crun commands, submitting nothing"

for idx in "${POSITIONAL[@]}"; do
  case "$idx" in (*[!0-9]*) echo "  skip '$idx': not a positive integer" >&2; continue;; esac
  if [ "$idx" -lt 1 ] || [ "$idx" -gt "$NPOINTS" ]; then
    echo "  skip index $idx: out of range 1..$NPOINTS for grid $GRID" >&2; continue
  fi
  # 1-based index -> the point's coefficient dict (JSON is 0-based).
  COEFFS=$(python3 -c "import json,sys;print(json.dumps(json.load(open('$POINTS'))[$idx-1]))")
  for ch in "${CHLIST[@]}"; do
    FRAG=$FRAGDIR/idx${idx}__${ch}.py
    NAME=$(python3 "$HERE/make_fullsim_fragment.py" --coeffs "$COEFFS" --channel "$ch" \
             --gridpack-base "$GRIDPACK_DIR" --nevents "$NEVENTS_JOB" \
             --comenergy "$COMENERGY" --out "$FRAG")
    JOBNAME=${NAME}__${ch}
    CMD=(python3 "$CRUN" "$JOBNAME" "$FRAG" "$CAMPAIGN"
         --nevents_job "$NEVENTS_JOB" --njobs "$NJOBS"
         --outEOS "$OUTEOS/$ch" --seed_offset "$SEED_OFFSET"
         --mem "$MEM" --max_nthreads "$MAXTHREADS" $KEEPFLAGS)
    [ "$USE_ENV" = 1 ]         && CMD+=(--env)
    [ "$USE_PILEUP_FILE" = 1 ] && CMD+=(--pileup_file)
    echo "-- idx $idx  $ch  ->  $JOBNAME  ($NJOBS x $NEVENTS_JOB ev)"
    if [ "$DRYRUN" = 1 ]; then
      printf '   '; printf '%q ' "${CMD[@]}"; echo
    else
      ( cd "$HERE" && "${CMD[@]}" )
    fi
  done
done

echo ">> done ($([ "$DRYRUN" = 1 ] && echo 'dry run, nothing submitted' || echo 'submitted'))."
