import FWCore.ParameterSet.Config as cms

# ggHH_SMEFT gridpack for this parameter point (HH->bb gamma gamma).
# Gridpack (13.6 TeV Run-3 production) staged on the worker by run_generic_tarball_cvmfs.sh.
externalLHEProducer = cms.EDProducer("ExternalLHEProducer",
    args = cms.vstring('root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_5param_keep_stage1/powheg_ggHH_SMEFT_CHbox_0p330434_CH_m17p8378_CuH_m2p27521_CHG_m0p0138154_CtG_0p247974_gridpack.tar.gz'),
    nEvents = cms.untracked.uint32(2000),
    numberOfParameters = cms.uint32(1),
    outputFile = cms.string('cmsgrid_final.lhe'),
    generateConcurrently = cms.untracked.bool(False),
    scriptName = cms.FileInPath('GeneratorInterface/LHEInterface/data/run_generic_tarball_cvmfs.sh')
)

from Configuration.Generator.Pythia8CommonSettings_cfi import *
from Configuration.Generator.MCTunes2017.PythiaCP5Settings_cfi import *
from Configuration.Generator.PSweightsPythia.PythiaPSweightsSettings_cfi import *

# Full parton shower + hadronization; the di-Higgs decay is forced to HH->bb gamma gamma.
generator = cms.EDFilter("Pythia8HadronizerFilter",
    maxEventsToPrint = cms.untracked.int32(1),
    pythiaPylistVerbosity = cms.untracked.int32(1),
    filterEfficiency = cms.untracked.double(0.5),   # ~fraction of showered events the ResonanceDecayFilter keeps for HH->bb gamma gamma
    pythiaHepMCVerbosity = cms.untracked.bool(False),
    comEnergy = cms.double(13600.0),
    PythiaParameters = cms.PSet(
        pythia8CommonSettingsBlock,
        pythia8CP5SettingsBlock,
        pythia8PSweightsSettingsBlock,
        processParameters = cms.vstring(
            'POWHEG:nFinal = 2',                 # gg -> HH: two final-state particles at LHE
            # Replace the Higgs (25) decay table with the channel's legs at EQUAL weight
            # (oneChannel/addChannel, meMode 100): each Higgs then picks a leg ~evenly,
            # so ~half the events are the one-and-one combination the filter keeps.
            '25:oneChannel = 1 0.5 100 5 -5',
            '25:addChannel = 1 0.5 100 22 22',
            'ResonanceDecayFilter:filter = on',
            'ResonanceDecayFilter:exclusive = on',       # require EXACTLY the daughters below
            'ResonanceDecayFilter:eMuAsEquivalent = off',
            'ResonanceDecayFilter:mothers = 25',
            'ResonanceDecayFilter:daughters = 5,5,22,22',
        ),
        parameterSets = cms.vstring('pythia8CommonSettings',
                                    'pythia8CP5Settings',
                                    'pythia8PSweightsSettings',
                                    'processParameters',
                                    )
    )
)

ProductionFilterSequence = cms.Sequence(generator)
