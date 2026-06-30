# ggHH_SMEFT NANOGEN submission (default 100k events/point = 5 × 20k)

Drives each per-point POWHEG `ggHH_SMEFT` gridpack through Pythia8 and produces
**NANOGEN** ([twiki](https://twiki.cern.ch/twiki/bin/viewauth/CMS/NanoGen)) on
either **HTCondor** (default) or **CRAB** (`--backend crab`). The total
events/point and the number of jobs are options (`--total-events`, `--njobs`);
the default is **100k events/point in 5 jobs of 20k** (events/job = total ÷ njobs).
Points come from the **same JSON** as the gridpacks
(`FINALgrid_for_SMEFT_4D_leadingOnly_updated_PDF.json`), and fragment names use
the **same coupling encoding** so each fragment pairs with its gridpack:

```
fragments/<point>.py            <->  <point>_gridpack.tar.gz   (on EOS)
<point> = powheg_ggHH_SMEFT_CHbox_..._CH_..._CuH_..._CHG_...
```

## Files
| file | role |
|------|------|
| `make_fragments.py`  | JSON → one Pythia8 NANOGEN fragment per point (+ `manifest.json`) |
| `run_nanogen.sh`     | **condor** per-job: fetch gridpack, run CMSSW `cmsDriver` (LHE,GEN,NANO:@GEN), deliver root |
| `submit_nanogen.sub` | HTCondor submit description (one job per `point,jobidx`) |
| `submit_crab.sh`     | **crab** backend: build a cmsRun cfg per point, write a `PrivateMC` CRAB config, `crab submit` |
| `submit_nanogen.sh`  | driver (both backends): gen fragments → condor `joblist.txt` **or** CRAB tasks |

## Usage
```bash
cd /afs/cern.ch/work/a/acarvalh/generation_k4/MYOMC/submission

# Test: first 3 points (15 jobs), build only — don't submit
./submit_nanogen.sh --ncards 3 --dry-run

# Submit points 4..500 (1-based inclusive) — the requested range
./submit_nanogen.sh --start 4 --end 500

# All points
./submit_nanogen.sh --ncards 0
```
`--start/--end` are **1-based inclusive**, identical to the gridpack driver
`condor/submit_smeft.sh`. Monitor with `condor_q`; logs land in `logs/`.

## Backends: HTCondor (default) vs CRAB
Pick with `--backend condor|crab`. Same fragments, same point selection, same
`--total-events`/`--njobs`; only the submission layer differs.

```bash
# HTCondor (default): one job per (point, jobindex), submitted from lxplus
./submit_nanogen.sh --start 4 --end 500

# CRAB: one PrivateMC task per point; CRAB splits TOTAL_EVENTS into jobs of NEVENTS
./submit_nanogen.sh --start 4 --end 500 --backend crab
./submit_nanogen.sh --start 4 --end 500 --backend crab --dry-run   # build cfgs/configs only
```

| | **condor** | **crab** |
|---|---|---|
| unit of work | one job per `(point, jobidx)` | one CRAB **task** per point |
| splitting | explicit `joblist.txt` (`--njobs`) | `EventBased`: `totalUnits=--total-events`, `unitsPerJob=NEVENTS` |
| gridpack | xrdcp'd into the job at runtime (token in fragment) | xrootd path **baked into the fragment** (CRAB embeds it) |
| output | `xrdcp` to `--outdir` (EOS) | CRAB stageout to `--output-lfn` on `--storage-site` |
| monitor | `condor_q`, `logs/` | `crab status -d crab_nanogen/crab_<point>` |
| wall time | `--flavour` (`testmatch` = 72h) | CRAB default (≈ same per-job budget) |

CRAB-only options:

| flag | default | meaning |
|------|---------|---------|
| `--backend` | `condor` | `condor` or `crab` |
| `--output-lfn` | `/store/user/acarvalh/smeft_nanogen` | CRAB `Data.outLFNDirBase` |
| `--storage-site` | `T3_CH_CERNBOX` | CRAB `Site.storageSite` (`T3_CH_CERNBOX` → personal `/eos/user`; `T2_CH_CERN` → group store) |

The CRAB path needs a CMSSW + CRAB environment (it builds `CMSSW_14_1_8`
once under `crab_env/`, generates `cfgs/NANOGEN_<point>_cfg.py` via `cmsDriver`,
and writes `crabConfigs/crabConfig_<point>.py`). Run it on lxplus (el9) with a
valid grid proxy; CRAB sets per-job RNG seeds itself (the cfg carries **no** fixed
seed). The gridpacks must be reachable via xrootd from grid worker nodes.

### Key options (defaults)
| flag | default | meaning |
|------|---------|---------|
| `--total-events` | `100000` | **total events per point** |
| `--njobs`     | `5`      | jobs per point |
| `--comenergy` | `13600`  | √s in GeV (Run 3) |

Events per job are derived: `events/job = total-events / njobs` (default 100k / 5
= 20k). `--total-events` must be divisible by `--njobs`. E.g. for 200k in 10 jobs:
```bash
./submit_nanogen.sh --start 4 --end 500 --total-events 200000 --njobs 10
```

| `--nthreads`  | `1`      | cmsRun threads (= `request_cpus`) |
| `--mem`       | `4000`   | `request_memory` (MB) |
| `--flavour`   | `testmatch` | **72h** wall-clock queue |
| `--gridpack-dir` | `root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks` | where the gridpacks live |
| `--outdir`    | `root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen` | NANOGEN output |

## Where the NANOGEN files go
The output location depends on the backend.

### HTCondor backend (default)
Each job xrdcp's its file (from `run_nanogen.sh`) to **`--outdir`**, default:
```
root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen/
```
Filename: `NANOGEN_<point>_<jobidx>.root` — i.e. **5 files per point** (one per
job), flat in that directory. E.g.:
```
/eos/user/a/acarvalh/smeft_nanogen/NANOGEN_powheg_ggHH_SMEFT_CHbox_..._CHG_..._5.root
```
Override with `--outdir` (an xrootd URL, an `/eos/...` path, or a local dir).

### CRAB backend
CRAB stages out to **`--output-lfn`** on **`--storage-site`**, defaults:
```
--output-lfn    /store/user/acarvalh/smeft_nanogen
--storage-site  T3_CH_CERNBOX        # -> personal /eos/user (CERNBox)
```
CRAB builds its standard path tree underneath:
```
<output-lfn>/<primaryDataset>/<outputDatasetTag>/<YYMMDD_HHMMSS>/0000/*.root
```
where `<primaryDataset>` = the point name (minus the `powheg_` prefix) and
`<outputDatasetTag>` = `ggHH_SMEFT_NANOGEN`. With `T3_CH_CERNBOX` this resolves
under your CERNBox `/eos/user/a/acarvalh/...`; use `T2_CH_CERN` to write to the
group store instead.

## Design notes
- **el9 container** (`MY.SingularityImage = .../cmssw/el9:x86_64`) — the NANOGEN
  campaign uses `CMSSW_14_1_8` (`el9_amd64_gcc12`, Run 3 2024 conditions). This is
  el9-native so it executes the el9 ggHH_SMEFT gridpack (LCG_107 x86_64-el9
  `pwhg_main`) under `ExternalLHEProducer`. Each job builds CMSSW fresh in scratch
  (a few min) via `../campaigns/NANOGEN/run.sh`.
  The NANOGEN step is `LHE,GEN,NANO:@GEN` with `--eventcontent NANOAODSIM` (the
  Run 3 spelling; the old `LHE,GEN,NANOGEN` / `NANOAODGEN` was 10_6-only).
- **Grid proxy**: the driver ensures a 72h `x509up` proxy (`$HOME/private/x509up`),
  and jobs run with `use_x509userproxy = True`, needed to xrdcp gridpacks from /
  NANOGEN to EOS.
- **Per-job seeds**: `run.sh` derives the RNG seed from the job index, so the 5
  jobs of a point produce statistically independent events.
- A job fails loudly (exit 42) if no `*NANOGEN*.root` is produced, exit 43 if the
  gridpack path token wasn't substituted — resubmit those.
- `max_materialize = 200` throttles concurrency at scale (2485 jobs for 4..500).

## Gridpacks are CMS-runnable
**Both backends** hand the gridpack to CMSSW's `ExternalLHEProducer` (condor via
`run_generic_tarball_cvmfs.sh`, CRAB via `run_generic_tarball_xrootd.sh`), which
runs the `runcmsgrid.sh` entry point in the tarball. As of the latest
`condor/run_smeft_gridpack.sh`, each gridpack **is** a standard CMS-runnable POWHEG
gridpack (`runcmsgrid.sh` + `pwhg_main` + single-run card + grids), so it generates
the requested events on demand — no fixed-size LHE pack.

### Runtime OS: el9 throughout (aligned)
`pwhg_main`/`runcmsgrid.sh` use the LCG_107 **x86_64-el9** view, and this NANOGEN
campaign now uses `CMSSW_14_1_8` (**el9**, `el9_amd64_gcc12`) in the
`cmssw/el9:x86_64` container (`MY.SingularityImage`; `get_campaign_os("NANOGEN")`
returns `el9`). So the el9 gridpack runs natively inside the NANOGEN job — no
OS mismatch. Validate end-to-end on **one** point first:
```bash
./submit_nanogen.sh --ncards 1            # 5 jobs on one point
condor_q ; # then inspect logs/*.err and the EOS output
```
