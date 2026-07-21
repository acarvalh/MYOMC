#!/usr/bin/env python3
"""Generate one Pythia8 NANOGEN fragment per ggHH_SMEFT parameter point.

Each fragment drives a POWHEG ggHH_SMEFT gridpack (one per point, named by its
Wilson coefficients exactly as makeSMEFTCards.py / run_smeft_gridpack.sh name
them) through ExternalLHEProducer + Pythia8. The gridpack path is left as the
token __GRIDPACKPATH__; run_nanogen.sh xrdcp's the gridpack into the job and
substitutes the absolute local path before cmsRun.

Point selection mirrors makeSMEFTCards.py: --start/--end are 1-based inclusive.

Usage:
    ./make_fragments.py --start 4 --end 500     # points 4..500
    ./make_fragments.py --nmax 3                # first 3 points (test)
    ./make_fragments.py --nmax 0               # all points
"""
import argparse
import json
import os

# Same coefficients and filename encoding as makeSMEFTCards.py, so a fragment's
# name matches its gridpack: <point>.py  <->  <point>_gridpack.tar.gz. point_name()
# below only emits the coefficients actually present in a point, so this longer 9D
# list stays backward compatible with 4D/5D points (which lack the extra keys).
COEFFS = ["CHbox", "CH", "CuH", "CHG", "CtG", "CQt", "CQt8", "CQQtt", "CQQ8"]


def frmt(value):
    """'.'->'p', leading '-'->'m' (6 sig figs) — identical to makeSMEFTCards.py."""
    return ("%.6g" % float(value)).replace("-", "m").replace(".", "p")


def point_name(point):
    # Include only the coefficients present in the point, in COEFFS order: a 4D point
    # (leading only) omits _CtG_ and the four-fermion keys; a 5D point adds _CtG_; a 9D
    # point carries all nine. Absent keys are simply skipped, so the same function names
    # every grid and matches its gridpack filename. Same encoding as makeSMEFTCards.py.
    return "powheg_ggHH_SMEFT_" + "_".join(
        f"{k}_{frmt(point[k])}" for k in COEFFS if k in point)


FRAGMENT_TEMPLATE = '''import FWCore.ParameterSet.Config as cms

# POWHEG ggHH_SMEFT gridpack for this parameter point.
externalLHEProducer = cms.EDProducer("ExternalLHEProducer",
    args = cms.vstring('{gridpack}'),
    nEvents = cms.untracked.uint32({nevents}),
    numberOfParameters = cms.uint32(1),
    outputFile = cms.string('cmsgrid_final.lhe'),
    generateConcurrently = cms.untracked.bool(False),
    scriptName = cms.FileInPath('GeneratorInterface/LHEInterface/data/{script}')
)

from Configuration.Generator.Pythia8CommonSettings_cfi import *
from Configuration.Generator.MCTunes2017.PythiaCP5Settings_cfi import *
from Configuration.Generator.PSweightsPythia.PythiaPSweightsSettings_cfi import *

generator = cms.EDFilter("Pythia8HadronizerFilter",
    maxEventsToPrint = cms.untracked.int32(1),
    pythiaPylistVerbosity = cms.untracked.int32(1),
    filterEfficiency = cms.untracked.double(1.0),
    pythiaHepMCVerbosity = cms.untracked.bool(False),
    comEnergy = cms.double({comenergy}),
    PythiaParameters = cms.PSet(
        pythia8CommonSettingsBlock,
        pythia8CP5SettingsBlock,
        pythia8PSweightsSettingsBlock,
        processParameters = cms.vstring(
            'POWHEG:nFinal = 2',          # gg -> HH: two final-state particles at LHE{shower_off}
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

# Injected into processParameters when --hard-only: disable the parton shower,
# multi-parton interactions, beam remnants and hadronization/decays so Pythia
# only passes the LHE hard process through. The NANOGEN GenPart table then holds
# just the hard-scattering particles (gg -> HH), and LHEPart is filled from the
# gridpack LHE regardless. Saves CPU and shrinks the output.
SHOWER_OFF_BLOCK = """
            'PartonLevel:ISR = off',      # no initial-state radiation
            'PartonLevel:FSR = off',      # no final-state radiation (parton shower)
            'PartonLevel:MPI = off',      # no multi-parton interactions
            'HadronLevel:all = off'       # no hadronization or particle decays"""
# NOTE: do NOT use 'PartonLevel:all = off' — it leaves Pythia8HadronizerFilter with an
# incomplete event record and SEGFAULTS during HepMC conversion. Turning off the shower
# COMPONENTS (ISR/FSR/MPI) + HadronLevel keeps the framework alive and yields the hard
# partons only, which is what we want for a hard-scattering-only NANOGEN sample.


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    # Default points grid is BUNDLED beside this script so a fresh MYOMC clone can
    # generate fragments with no reach into EOS / the external generation_k4 tree.
    ap.add_argument("--points",
                    default=os.path.join(here, "FINALgrid_for_SMEFT_5D_leading_plus_ctg.json"))
    ap.add_argument("--outdir", default=os.path.join(here, "fragments"))
    ap.add_argument("--nevents", type=int, default=20000,
                    help="events per job (ExternalLHEProducer.nEvents)")
    ap.add_argument("--comenergy", type=float, default=13600.0,
                    help="centre-of-mass energy in GeV (Run 3 = 13600)")
    ap.add_argument("--gridpack-base", default="",
                    help="if set, bake <base>/<point>_gridpack.tar.gz into the fragment "
                         "(e.g. an xrootd URL for CRAB); otherwise leave the runtime "
                         "token __GRIDPACKPATH__ that run_nanogen.sh substitutes (condor).")
    ap.add_argument("--nmax", type=int, default=3,
                    help="number of points; 0 = all (ignored if --start/--end given)")
    ap.add_argument("--start", type=int, default=0,
                    help="first point, 1-based inclusive (0 = from the beginning)")
    ap.add_argument("--end", type=int, default=0,
                    help="last point, 1-based inclusive (0 = to the end)")
    ap.add_argument("--hard-only", action="store_true",
                    help="store only the hard scattering: disable the Pythia parton "
                         "shower, MPI and hadronization (PartonLevel/HadronLevel off)")
    args = ap.parse_args()

    shower_off = SHOWER_OFF_BLOCK if args.hard_only else ""

    with open(args.points) as f:
        points = json.load(f)

    if args.start > 0 or args.end > 0:
        lo = (args.start - 1) if args.start > 0 else 0
        hi = args.end if args.end > 0 else len(points)
        offset = lo
        points = points[lo:hi]
    elif args.nmax > 0:
        offset = 0
        points = points[:args.nmax]
    else:
        offset = 0

    os.makedirs(args.outdir, exist_ok=True)
    manifest = []
    for j, point in enumerate(points):
        i = offset + j  # absolute index into the original JSON
        name = point_name(point)
        gp_file = name + "_gridpack.tar.gz"
        if args.gridpack_base:
            # Self-contained fragment (CRAB): full path + xrootd staging script.
            gridpack = args.gridpack_base.rstrip("/") + "/" + gp_file
            script = "run_generic_tarball_xrootd.sh"
        else:
            # Runtime token; run_nanogen.sh substitutes the local path (condor).
            gridpack = "__GRIDPACKPATH__"
            script = "run_generic_tarball_cvmfs.sh"
        body = FRAGMENT_TEMPLATE.format(nevents=args.nevents, comenergy=args.comenergy,
                                        gridpack=gridpack, script=script,
                                        shower_off=shower_off)
        path = os.path.join(args.outdir, name + ".py")
        with open(path, "w") as wf:
            wf.write(body)
        manifest.append({"index": i, "name": name,
                         "gridpack": name + "_gridpack.tar.gz",
                         **{k: point[k] for k in COEFFS if k in point}})

    with open(os.path.join(args.outdir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"Wrote {len(points)} fragments to {args.outdir} "
          f"(nevents/job={args.nevents}, comEnergy={args.comenergy}"
          f"{', hard-scattering only (no shower)' if args.hard_only else ''})")
    for m in manifest[:5]:
        print(f"  {m['name']}")
    if len(manifest) > 5:
        print(f"  ... (+{len(manifest) - 5} more)")


if __name__ == "__main__":
    main()
