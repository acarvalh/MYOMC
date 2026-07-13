# ggHH_SMEFT POWHEG gridpack production

Committed, clone-portable copy of the gridpack-making pipeline. Generates one POWHEG
`ggHH_SMEFT` gridpack per SMEFT parameter point (5D leading + CtG grid) on HTCondor.
The nanogen step in [`../submission/`](../submission/) then consumes these gridpacks.

> This folder is the **version-controlled** copy. The author's live working tree lives
> outside the repo in `generation_k4/condor/`; the two are kept in sync. Edit here.

## Submit from THIS folder

```bash
cd MYOMC/gridpack          # <-- run submissions from here (cards.list, logs/ are written in cwd)
./submit_smeft.sh --ncards 3 --dry-run     # smoke: build 3 cards, print what would submit
./submit_smeft.sh --start 1 --end 200      # points 1..200 (1-based, inclusive)
./submit_smeft.sh --ncards 0               # all points in the grid
```

Output gridpacks land in `--outdir` (default:
`root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_5param_keep_stage1`).
A point is "done" when `<point>_gridpack.tar.gz` appears there; re-runs skip completed
points, and `--only-missing` submits only the not-yet-done ones.

## What ships in the job

`submit_smeft.sh` generates per-point POWHEG cards with `makeSMEFTCards.py` (from the
bundled template `powheg-2.input` and the bundled points grid
`../submission/FINALgrid_for_SMEFT_5D_leading_plus_ctg.json`), writes `cards.list`, and
`condor_submit`s `submit_smeft.sub` (executable `run_smeft_gridpack.sh`). On the worker,
`run_smeft_gridpack.sh` stages the process tarball, runs POWHEG stages 1–4, assembles
`<point>_gridpack.tar.gz`, and xrdcp's it to `--outdir`.

`makeSMEFTCards.py` sets `includesubleading 1` **only** for points with `CtG != 0` (the
chromomagnetic operator is subleading; enabling it costs extra grid integration, so
CtG=0 points leave it `0` and reduce to the 4D physics).

## The process tarball (the one thing NOT in git)

`ggHH_SMEFT_run.tar.gz` (~55 MB) is the **compiled** POWHEG process — the `pwhg_main`
binary, `Virtual/creategrid.py`, and `testrun/run.sh`. It is a platform-specific binary
blob (LCG_107 / x86_64-el9) and does **not** belong in the repo. It is **hosted on EOS**,
so a fresh clone works out of the box:

```
PROCESS_TARBALL = root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_gridpacks_keep_stage1/ggHH_SMEFT_run.tar.gz
```

`run_smeft_gridpack.sh` xrdcp's this URL on the worker. To use a different one:

```bash
./submit_smeft.sh --process-tarball root://.../ggHH_SMEFT_run.tar.gz ...   # hosted URL
./submit_smeft.sh --process-tarball /path/to/local/ggHH_SMEFT_run.tar.gz ... # local (AFS-visible) path
```

A hosted URL is trusted as-is (staged on the node). Only a **missing local path**
triggers an automatic rebuild via `make_process_tarball.sh`, which needs the full
compiled `POWHEG-BOX/ggHH_SMEFT` build tree — set `PROC_DIR`/`GEN_DIR` to point at it.
After rebuilding (`OUT_TARBALL` defaults beside this script), upload it back to the EOS
URL above so clones and workers pick up the new binary.

## Can a third person run this from a clone?

Yes, with two external things a clone can't carry:
1. **The process tarball** — already solved: it's the hosted EOS URL above (no action).
2. **Where gridpacks are written** — pass `--outdir <your EOS/xrootd dir>`; the default
   points at the author's EOS.

Everything else (scripts, card template, points grid, `runcmsgrid.sh`) is in the repo.

## Key flags

| flag | default | meaning |
|---|---|---|
| `--ncards N` | 3 | first N points (0 = all); ignored if `--start/--end` given |
| `--start / --end` | – | 1-based inclusive point range |
| `--outdir DIR` | 5param EOS dir | where `<point>_gridpack.tar.gz` is delivered |
| `--process-tarball URL\|PATH` | hosted EOS URL | compiled process tarball to stage on the node |
| `--carddir DIR` | `./cards_prod` | where generated POWHEG cards go |
| `--ncores N` | 4 | cores/job (`request_cpus`); POWHEG parallelises stages 1–4 |
| `--nxgrid N` | 1 | xgrid iterations at parstage 1 |
| `--flavour F` | nextweek | HTCondor `+JobFlavour` (wall-clock budget) |
| `--only-missing` | off | (re)submit only points without a gridpack yet |
| `--report` | off | print done/missing status, do not submit |
| `--dry-run` | off | build cards + `cards.list`, print submit args, do not submit |
| `--test` | off | coarse smoke build of the FIRST selected point (degraded stats) |

## Files

| file | role |
|---|---|
| `submit_smeft.sh` | driver: cards → `cards.list` → `condor_submit` |
| `submit_smeft.sub` | HTCondor submit description (one job per point) |
| `run_smeft_gridpack.sh` | worker job: stage tarball, run POWHEG, assemble + deliver gridpack |
| `make_process_tarball.sh` | (re)build `ggHH_SMEFT_run.tar.gz` from a compiled POWHEG-BOX build |
| `makeSMEFTCards.py` | one POWHEG card per point (conditional `includesubleading`) |
| `powheg-2.input` | base POWHEG template (`usesmeft 1`, `SMEFTtruncation 1`) |
