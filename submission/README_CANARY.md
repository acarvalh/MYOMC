# NANOGEN canary — single 500-event job on a ready 4D gridpack

A minimal end-to-end test for a **third person**: generate one NANOGEN job of **500
events** from **one already-produced 4D gridpack**, via either HTCondor or CRAB. These
are the exact commands — run one; nothing here submits for you.

## Pick the grid: `--grid 4d` or `--grid 5d`

`submit_nanogen.sh --grid {4d,5d}` selects which **bundled** points grid drives the
fragment names AND the matching default gridpack set. They are paired because a
fragment's name must equal its gridpack's name:

| `--grid` | points JSON (bundled beside this script) | default gridpack dir |
|---|---|---|
| `4d` | `FINALgrid_for_SMEFT_4D_leadingOnly_updated_PDF.json` (no CtG) | `…/smeft_gridpacks_keep_stage1` |
| `5d` | `FINALgrid_for_SMEFT_5D_leading_plus_ctg.json` (leading + CtG) | `…/smeft_gridpacks_5param_keep_stage1` |

Override either with `--points <file>` / `--gridpack-dir <dir>`. Default is `5d`.

## The ready point for this canary

`--grid 4d --start 4 --end 4` selects point **index 4** (1-based):

```
powheg_ggHH_SMEFT_CHbox_2p40586_CH_m12p6565_CuH_m1p32303_CHG_m0p00131494
```

Its gridpack is present in `smeft_gridpacks_keep_stage1` (one of 48 landed 4D
gridpacks). Any other landed index works too — swap the `--start/--end` value.

## Command A — HTCondor (1 job, 500 events)

```bash
cd MYOMC/submission
voms-proxy-init --voms cms --valid 192:00          # EOS access from the worker
./submit_nanogen.sh --grid 4d --start 4 --end 4 --total-events 500 --njobs 1
```

- `--total-events 500 --njobs 1` ⇒ one job of 500 events (`NEVENTS = 500/1`).
- Output ROOT lands at `--output-dir` (default `…/smeft_nanogen`) as
  `<point>/NANOGEN_<point>_1.root`. Override with `--output-dir root://…/<your dir>`.
- Add `--dry-run` first to see the joblist without submitting.

## Command B — CRAB (1 task, 1 job of 500 events)

```bash
cd MYOMC/submission
source /cvmfs/cms.cern.ch/common/crab-setup.sh
voms-proxy-init --voms cms --valid 192:00
./submit_nanogen.sh --grid 4d --start 4 --end 4 --total-events 500 --njobs 1 \
    --backend crab \
    --output-lfn /store/user/<YOU>/smeft_nanogen_canary \
    --storage-site T3_CH_CERNBOX
```

- CRAB `EventBased` splitting: `totalUnits = 500`, `unitsPerJob = 500` ⇒ **one** job.
- `--output-lfn` / `--storage-site` must point at storage **you** can write to
  (`T3_CH_CERNBOX` = your `/eos/user`; `T2_CH_CERN` = your grid `/store/user`).
- Monitor: `crab status -d crab_nanogen/crab_<point>`.

## Third-party notes

- **Gridpacks** are ~50 MB each on EOS and are **not** in the repo. `--grid 4d` defaults
  to the author's `smeft_gridpacks_keep_stage1`; point `--gridpack-dir` at your own copy
  (or a shared/world-readable location) if you don't have access.
- **Everything else** the job needs (`runcmsgrid.sh`, `creategrid.py`, the points JSON,
  the campaign `run.sh`) is bundled in this repo — a fresh clone is self-contained.
- **CRAB is initial-production only.** To add statistics later use the condor backend
  with `--job-offset` (collision-free seed windows). See `README.md` → "Seeds".
