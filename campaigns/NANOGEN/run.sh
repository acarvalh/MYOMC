# Run NANOGEN
# Local example:
# source run.sh MyMCName /path/to/fragment.py 1000
# 
# Batch example:
# python crun.py MyMCName /path/to/fragment.py --outEOS /store/user/myname/somefolder --keepMini --nevents_job 10000 --njobs 100 --env
# See crun.py for full options, especially regarding transfer of outputs.
# Make sure your gridpack is somewhere readable, e.g. EOS or CVMFS.
# Make sure to run setup_env.sh first to create a CMSSW tarball (have to patch the DR step to avoid taking forever to uniqify the list of 300K pileup files)
echo $@

if [ -z "$1" ]; then
    echo "Argument 1 (name of job) is mandatory."
    exit 1
fi
NAME=$1

if [ -z $2 ]; then
    echo "Argument 2 (fragment path) is mandatory."
    exit 1
fi
FRAGMENT=$2
echo "Input arg 2 = $FRAGMENT"
FRAGMENT=$(readlink -e $FRAGMENT)
echo "After readlink fragment = $FRAGMENT"

if [ -z "$3" ]; then
    NEVENTS=100
else
    NEVENTS=$3
fi

if [ -z "$4" ]; then
    JOBINDEX=1
else
    JOBINDEX=$4
fi


if [ -z "$5" ]; then
    MAX_NTHREADS=8
else
    MAX_NTHREADS=$5
fi

# Per-(point,job) seed. PREFERRED: submit_nanogen.sh precomputes RSEED_BASE, the
# lower edge of a disjoint 1000-wide seed window reserved for this exact (point,
# global-job) pair — base = point_index*100000 + gjob*1000, where point_index is
# the UNIQUE JSON index (no hash collisions) and gjob = job_offset + jobidx (so
# top-up batches use fresh windows). Inside the window, seeds never overlap another
# job's: LHE = base+1, Pythia = base+2, POWHEG per-core streams = base+10+i (set in
# runcmsgrid.sh from the LHE seed). Windows are disjoint => globally collision-free,
# including across resubmissions. Max seed (index<9000, gjob<100) stays < 900000000,
# the CMS RandomNumberGeneratorService / Pythia8 ceiling.
#
# FALLBACK (RSEED_BASE unset, e.g. a standalone gridpack run): the old self-contained
# hash layout, RSEED = crc32(point)%8e6 *100 + JOBINDEX*10 + 1, Pythia = RSEED+7.
if [ -n "${RSEED_BASE:-}" ]; then
    RSEED=$(( RSEED_BASE + 1 ))    # externalLHEProducer (POWHEG); runcmsgrid derives cores as +10+i
    PYSEED=$(( RSEED_BASE + 2 ))   # Pythia8 generator
else
    POINT_NAME="${NAME%_*}"
    POINT_SEED=$(python3 -c "import sys,zlib; print(zlib.crc32(sys.argv[1].encode()) % 8000000)" "$POINT_NAME")
    RSEED=$(( POINT_SEED * 100 + JOBINDEX * 10 + 1 ))
    PYSEED=$(( RSEED + 7 ))
fi


echo "Fragment=$FRAGMENT"
echo "Job name=$NAME"
echo "NEvents=$NEVENTS"
echo "Random seed=$RSEED"

TOPDIR=$PWD

# NANOGEN
# Setup CMSSW and merge NANOGEN stuff
# el9-native Run 3 release so the el9 ggHH_SMEFT gridpack (LCG_107 x86_64-el9)
# runs natively under ExternalLHEProducer. CMSSW_10_6 (slc7/el7) could NOT
# execute the el9 pwhg_main; CMSSW_14_1_8 (el9_amd64_gcc12) can.
export SCRAM_ARCH=el9_amd64_gcc12
if [ -r CMSSW_14_1_8 ] ; then
    echo release CMSSW_14_1_8 already exists
    cd CMSSW_14_1_8/src
    eval `scram runtime -sh`
    scram b -j8
    cd $TOPDIR
else
    scram project -n "CMSSW_14_1_8" CMSSW_14_1_8
    cd CMSSW_14_1_8/src
    eval `scram runtime -sh`
    scram b -j8
    cd $TOPDIR
fi

# Setup fragment
mkdir -pv $CMSSW_BASE/src/Configuration/GenProduction/python
cp $FRAGMENT $CMSSW_BASE/src/Configuration/GenProduction/python/fragment.py
if [ ! -f "$CMSSW_BASE/src/Configuration/GenProduction/python/fragment.py" ]; then
    echo "Fragment copy failed"
    exit 1
fi
cd $CMSSW_BASE/src
scram b
cd $TOPDIR

#cat $CMSSW_BASE/src/Configuration/GenProduction/python/fragment.py

# cmsDriver and run
cmsDriver.py Configuration/GenProduction/python/fragment.py \
    --python_filename "NANOGEN_${NAME}_cfg.py" \
    --eventcontent NANOAODSIM \
    --customise Configuration/DataProcessing/Utils.addMonitoring \
    --datatier NANOGEN \
    --fileout "file:NANOGEN_$NAME_$JOBINDEX.root" \
    --conditions 140X_mcRun3_2024_realistic_v26 \
    --beamspot Realistic25ns13p6TeVEarly2023Collision \
    --step LHE,GEN,NANO:@GEN \
    --geometry DB:Extended \
    --era Run3_2024 \
    --no_exec \
    --mc \
    --nThreads $MAX_NTHREADS \
    --customise_commands "process.source.numberEventsInLuminosityBlock=cms.untracked.uint32(1000)\\n\
process.RandomNumberGeneratorService.externalLHEProducer.initialSeed=${RSEED}\\n\
process.RandomNumberGeneratorService.generator.initialSeed=${PYSEED}\\n" \
    -n $NEVENTS

cmsRun "NANOGEN_${NAME}_cfg.py"
if [ ! -f "NANOGEN_$NAME_$JOBINDEX.root" ]; then
    echo "NANOGEN_$NAME_$JOBINDEX.root not found. Exiting."
    return 1
fi
