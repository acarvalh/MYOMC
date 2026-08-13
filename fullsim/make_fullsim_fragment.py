#!/usr/bin/env python3
"""Generate a FULL-SIM Pythia8 hadronizer fragment for one ggHH_SMEFT point and
one HH decay channel (bbgg | 4b | bbtt).

Unlike the NANOGEN fragments (submission/make_fragments.py, hard-scattering only),
these run the FULL parton shower + hadronization and force the di-Higgs decay of
the requested channel with a ResonanceDecayFilter, exactly the CMS convention for
GluGluToHH samples. The gridpack (one per point, 13.6 TeV / Run-3 production) is
baked in as an xrootd path + run_generic_tarball_cvmfs.sh, so the fragment is
self-contained for the campaign chain (Run3Summer24wmLHEGS -> ... -> NANOAODSIM).

The point NAME (and therefore the gridpack filename it pairs with) is produced by
the SAME encoder as the gridpack/nanogen steps (submission/make_fragments.py), so
<point>_gridpack.tar.gz is resolved identically -- imported, never duplicated.

Usage (normally called by submit_fullsim.sh, not by hand):
    ./make_fullsim_fragment.py --coeffs '{"CH":-50,...}' --channel bbgg \\
        --gridpack-base root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_5param_keep_stage1 \\
        --out fragments_fullsim/<point>__bbgg.py
"""
import argparse
import json
import os
import sys

# Single source of truth for the point -> name encoding (must match the gridpacks).
_SUBMISSION = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "submission")
sys.path.insert(0, _SUBMISSION)
from make_fragments import point_name, COEFFS  # noqa: E402

# Per-channel Pythia8 decay configuration. Higgs = 25. The Higgs decay table is
# REPLACED (oneChannel/addChannel, meMode 100) with the channel's legs at EQUAL
# weight, rather than left at natural BRs: for an asymmetric channel that makes each
# Higgs pick bb or the partner mode ~50/50, so ~half the events are the one-and-one
# combination the ResonanceDecayFilter keeps (daughters, exclusive). Natural BRs
# would instead send almost every Higgs to bb, giving a <1% filter efficiency and
# ruinous full-sim CPU. This equal-weight + ResonanceDecayFilter pattern is the
# standard CMS recipe for HH asymmetric decays. The gen filter efficiency is then
# ~0.5 for bbgg/bbtt and ~1 for 4b (recorded in filterEfficiency for bookkeeping).
CHANNELS = {
    # name : (decay-table lines, daughters list, human label, filter efficiency)
    "bbgg": (["'25:oneChannel = 1 0.5 100 5 -5'",
              "'25:addChannel = 1 0.5 100 22 22'"], "5,5,22,22",  "HH->bb gamma gamma", 0.5),
    "4b":   (["'25:oneChannel = 1 1.0 100 5 -5'"],  "5,5,5,5",    "HH->bb bb",          1.0),
    "bbtt": (["'25:oneChannel = 1 0.5 100 5 -5'",
              "'25:addChannel = 1 0.5 100 15 -15'"], "5,5,15,15", "HH->bb tau tau",     0.5),
}

FRAGMENT_TEMPLATE = '''import FWCore.ParameterSet.Config as cms

# ggHH_SMEFT gridpack for this parameter point ({label}).
# Gridpack (13.6 TeV Run-3 production) staged on the worker by run_generic_tarball_cvmfs.sh.
externalLHEProducer = cms.EDProducer("ExternalLHEProducer",
    args = cms.vstring('{gridpack}'),
    nEvents = cms.untracked.uint32({nevents}),
    numberOfParameters = cms.uint32(1),
    outputFile = cms.string('cmsgrid_final.lhe'),
    generateConcurrently = cms.untracked.bool(False),
    scriptName = cms.FileInPath('GeneratorInterface/LHEInterface/data/run_generic_tarball_cvmfs.sh')
)

from Configuration.Generator.Pythia8CommonSettings_cfi import *
from Configuration.Generator.MCTunes2017.PythiaCP5Settings_cfi import *
from Configuration.Generator.PSweightsPythia.PythiaPSweightsSettings_cfi import *

# Full parton shower + hadronization; the di-Higgs decay is forced to {label}.
generator = cms.EDFilter("Pythia8HadronizerFilter",
    maxEventsToPrint = cms.untracked.int32(1),
    pythiaPylistVerbosity = cms.untracked.int32(1),
    filterEfficiency = cms.untracked.double({filtereff}),   # ~fraction of showered events the ResonanceDecayFilter keeps for {label}
    pythiaHepMCVerbosity = cms.untracked.bool(False),
    comEnergy = cms.double({comenergy}),
    PythiaParameters = cms.PSet(
        pythia8CommonSettingsBlock,
        pythia8CP5SettingsBlock,
        pythia8PSweightsSettingsBlock,
        processParameters = cms.vstring(
            'POWHEG:nFinal = 2',                 # gg -> HH: two final-state particles at LHE
            # Replace the Higgs (25) decay table with the channel's legs at EQUAL weight
            # (oneChannel/addChannel, meMode 100): each Higgs then picks a leg ~evenly,
            # so ~half the events are the one-and-one combination the filter keeps.
{decay_lines}
            'ResonanceDecayFilter:filter = on',
            'ResonanceDecayFilter:exclusive = on',       # require EXACTLY the daughters below
            'ResonanceDecayFilter:eMuAsEquivalent = off',
            'ResonanceDecayFilter:mothers = 25',
            'ResonanceDecayFilter:daughters = {daughters}',
        ),
        parameterSets = cms.vstring('pythia8CommonSettings',
                                    'pythia8CP5Settings',
                                    'pythia8PSweightsSettings',
                                    'processParameters',
                                    )
    )
)

ProductionFilterSequence = cms.Sequence(generator)
'''


def build_fragment(coeffs, channel, gridpack_base, nevents, comenergy):
    if channel not in CHANNELS:
        raise SystemExit(f"unknown channel '{channel}' (choose from {list(CHANNELS)})")
    extra, daughters, label, eff = CHANNELS[channel]
    name = point_name(coeffs)
    gridpack = gridpack_base.rstrip("/") + "/" + name + "_gridpack.tar.gz"
    decay_lines = "".join(f"            {line},\n" for line in extra)
    return name, FRAGMENT_TEMPLATE.format(
        label=label, gridpack=gridpack, nevents=nevents, comenergy=comenergy,
        decay_lines=decay_lines.rstrip("\n"), daughters=daughters, filtereff=eff)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--coeffs", required=True, help="JSON dict of Wilson coefficients for the point")
    ap.add_argument("--channel", required=True, choices=list(CHANNELS))
    ap.add_argument("--gridpack-base", required=True, help="xrootd dir holding <point>_gridpack.tar.gz")
    ap.add_argument("--nevents", type=int, default=2000, help="ExternalLHEProducer.nEvents (events/job)")
    ap.add_argument("--comenergy", type=float, default=13600.0, help="sqrt(s) in GeV (2024 = 13600)")
    ap.add_argument("--out", required=True, help="output fragment path")
    args = ap.parse_args()

    coeffs = json.loads(args.coeffs)
    name, body = build_fragment(coeffs, args.channel, args.gridpack_base,
                                args.nevents, args.comenergy)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        f.write(body)
    print(name)


if __name__ == "__main__":
    main()
