# ggHH_SMEFT POWHEG gridpack production

Committed, clone-portable copy of the gridpack-making pipeline. Generates one POWHEG
`ggHH_SMEFT` gridpack per SMEFT parameter point (5D leading + CtG grid) on HTCondor.
The nanogen step in [`../submission/`](../submission/) then consumes these gridpacks.

> This folder is the **version-controlled** copy. The author's live working tree lives
> outside the repo in `generation_k4/condor/`; the two are kept in sync. Edit here.

## Grid proxy (required — do this first)

`submit_smeft.sub` sets `use_x509userproxy = True`, so `condor_submit` **fail-fasts** if
you have no valid proxy (the worker needs it to xrdcp the gridpack to EOS). Unlike the
nanogen driver, `submit_smeft.sh` does **not** create one for you — make it yourself:

```bash
voms-proxy-init --voms cms --valid 192:00
export X509_USER_PROXY=$(voms-proxy-info -path)   # so this proxy is the one condor ships
```

192 h (8 days) comfortably outlives a `nextweek` gridpack job. Re-run when it expires.

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

**By default the gridpack is CMS-runnable** — `pwhg_main` is packed in (`INCLUDE_BINARY=1`)
alongside `runcmsgrid.sh`, the single-run card and the integration grids, so
`ExternalLHEProducer` in the nanogen step generates events straight from it. Pass
`--no-binary` only if you deliberately want a grids-only pack (not CMS-runnable).

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

## Coarse grid for fast tests (`--test`)

A full point is a multi-day integration (see *Timing* below), so before committing a
wave you validate the **whole pipeline** — warmup → POWHEG stages 1–4 → gridpack
assembly → xrdcp delivery — on a **coarse, physics-degraded** build that finishes in
minutes. `--test` (alias `--smoke`) does exactly that: it sets `TESTMODE=1` in the job
and queues **only the first selected point**.

`TESTMODE=1` (in `run_smeft_gridpack.sh`) rewrites the card down to the floor that still
exercises every stage — the cost of POWHEG integration is ~linear in `ncall*itmx`, so
this is what collapses days into minutes:

| card key | production (from `powheg-2.input`) | `--test` floor |
|---|---|---|
| `ncall1` / `itmx1` (stage 1 grid) | large / several | `300` / `1` |
| `ncall2` / `itmx2` (stage 2 grid) | large / several | `300` / `1` |
| `nubound` (stage 3 upper bound) | large | `300` |
| `numevts` (stage 4 events) | production count | `50` |

Both the **integration AND the event count** are floored — flooring only `ncall/itmx`
once left `numevts` at 5000 and the job still ran into the queue wall. `--test` also
switches `+JobFlavour` to `workday` (8h) — ample for the ~30–40 min floored build.

```bash
cd MYOMC/gridpack
voms-proxy-init --voms cms --valid 192:00
./submit_smeft.sh --start 4 --end 4 --test          # coarse build of point 4 only
```

The result is a **complete, CMS-runnable** gridpack (`pwhg_main` + `runcmsgrid.sh` +
card + grids/`events.cdf`) — use it to exercise the **nanogen** plumbing (see
[`../submission/README_CANARY.md`](../submission/README_CANARY.md)) — but its weights are
**physics-degraded**. Never feed a `--test` gridpack into production. Send coarse builds
to a separate `--outdir` (e.g. `…_test`) so `--only-missing` never mistakes one for a
finished production point.

## Timing

Full-theory `ggHH_SMEFT` is expensive because the `mtdep=3` two-loop virtual costs
**~10 CPU-seconds per phase-space point evaluation**. That single number drives both the
integration and, later, nanogen event generation.

| what | wall time | notes |
|---|---|---|
| **Production point** (default card, 4 cores) | **~52 h** | one HTCondor job; `+JobFlavour nextweek` |
| ├─ stages 1+2 (grid integration) | ~26 h | cost ~linear in `ncall*itmx` |
| └─ stage 3 (`nubound`) + stage 4 (events) | ~26 h | each generated event = a full virtual eval |
| stage-4 event generation alone (5000 evts) | ~3.5 h | dominates the second half |
| **Coarse `--test` build** | **~30–40 min** | floored ncall/itmx/nubound/numevts; `workday` |

- **CtG ≠ 0 points cost more.** `makeSMEFTCards.py` sets `includesubleading 1` for them
  (extra subleading matrix elements in the integration); CtG = 0 points reduce to the 4D
  physics with `includesubleading 0` and integrate faster.
- **`--ncores`** parallelises POWHEG stages 1–4; wall time scales roughly `1/ncores`
  (the ~52 h figure is 4 cores). `request_cpus` is pinned to `--ncores`.
- Start with the generous `nextweek` flavour; tighten `--flavour` only once a real point's
  wall time is measured for your `--ncores`/`--nxgrid`.

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
| `--no-binary` | off | build a grids-only pack **without** `pwhg_main` (NOT CMS-runnable) |
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
