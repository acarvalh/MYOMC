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
| `report_batches.sh`  | read-only progress table: gridpacks + NANOGEN ready, per index batch (condor or `--backend crab`, any `--ecm`) |

## Grid proxy
Jobs xrdcp gridpacks from EOS (and NANOGEN back), so they need a grid proxy. The driver
**auto-creates** one at `$X509_USER_PROXY` (else `$HOME/private/x509up`) if none is valid,
so you usually don't have to. To make it yourself — e.g. to share one proxy with the
gridpack step (`MYOMC/gridpack`, which does **not** auto-create) — run first:

```bash
voms-proxy-init --voms cms --valid 192:00
export X509_USER_PROXY=$(voms-proxy-info -path)   # the nanogen driver honours this path
```

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

## Progress report (`report_batches.sh`)
Read-only. Prints, per index batch, how many **gridpacks** and how many **NANOGEN**
files are on EOS — i.e. what is ready to run nanogen on, and what is already done:

```bash
cd /afs/cern.ch/work/a/acarvalh/generation_k4/MYOMC/submission
./report_batches.sh
```
```
 start   stop   pts |     gridpacks |  run idle held  gap  card   log |   nanogen files |        full
  1701   1800   100 |     100/100 * |    0    0    0    0     -     - |       500/500 * |   100/100 *
  1801   1900   100 |     100/100 * |    0    0    0    0     -     - |         0/500   |     0/100
  1901   2000   100 |      75/100   |    8    0    0   17   yes    no |         0/500   |     0/100
  2001   2050    50 |       3/50    |    0   47    0    0     -     - |         0/250   |      0/50
   601    700   100 |       0/100   |    0    0    0  100    no    no |         0/500   |     0/100
```
A `*` marks a **complete** cell. A star in the *gridpacks* column means the batch is
ready for `submit_nanogen.sh`; a star in `full` means the batch is finished. `full`
counts points with a complete set of `--njobs` files — a point with 3/5 is still short,
and a re-submit tops it up (the driver skips `gjob`s that exist).

**`run`/`idle`/`held`/`gap` explain the missing gridpacks**, so a `74/100` is not
ambiguous: they count only points with **no gridpack yet**, and always sum to the
shortfall. Read from `condor_q` (JobStatus 1/2/5), not from logs:

| column | meaning | what to do |
|--------|---------|------------|
| `run`  | building now | wait |
| `idle` | queued, waiting for a slot | wait — usually fair-share, see below |
| `held` | job stuck | `condor_rm` + resubmit; a release alone rarely fixes it |
| `gap`  | **no file and no job** | never submitted, or submitted and lost — resubmit |

`gap` is the column to act on: a build that finished and then failed to deliver (an
expired proxy at the xrdcp step) looks exactly like a point that was never submitted.
Both show up here and nowhere else.

**`card` and `log` say *why* a batch has gaps.** They ask, of the gap points only, does
a `<point>.input` card exist (in `cards_prod`) and does a condor `<point>.*.out` exist —
printed as `yes`, `no`, `n/total` when mixed, or `-` when the batch has no gaps:

| card | log | reading |
|------|-----|---------|
| `no`  | `no`  | **never submitted.** Cards are written at submit time, so no card means the range was never driven. Just submit it. |
| `yes` | `no`  | **submitted, but the job left no trace — it probably hit the wall.** A job killed at its `MaxRuntime` is *evicted*, not held: it requeues, re-runs from zero (no checkpointing), and after `NumJobStarts > 3` the `periodic_remove` backstop drops it. Resubmit with a **longer flavour** (`--week`). |
| `yes` | `yes` | it ran and finished or failed — read the log for the reason. |

Two caveats on `log`. `submit_smeft.sub` writes to a **relative** `logs/` path, so logs
land under whichever directory the submit ran from — the script searches
`../gridpack/logs` and `../../condor/logs`, and `--logdir "d1 d2"` overrides. A submit
from a third location leaves logs the report can't see, so `no` is weaker evidence than
`yes`. And a colleague's job logs to *their* directory, never yours.

⚠️ **When several people build into the same EOS directory, the two halves of the table
have different scopes.** The gridpack/nanogen counts are the **team's** output; the
queue columns are **yours alone**. So a point a colleague is building right now shows
as a `gap` — and `gap` is exactly the column you'd act on. Reconcile ranges with the
others before resubmitting a batch full of gaps, or you will duplicate multi-day builds.

There is **no way to tell from EOS who delivered a file**: it reports the *space owner*,
so everything written into `/eos/user/a/acarvalh/...` is owned by `acarvalh` whoever ran
the job. `mtime` doesn't help either. If attribution matters, agree the ranges up front,
or have each person deliver to their own directory and merge afterwards.

This is also a *live* view: a job that already failed and left the queue is a `gap` with
no trace here, so check `logs/` for the reason (`Delivering` at the end of a `.out` with
a `[3010] ... Permission denied` in the `.err` is the classic expired-proxy delivery
failure).

Skip the queue read with `--no-queue` (offline, or no proxy) — those four columns then
read 0.

### Resubmitting the gaps
`--gaps` collapses the gap indices into contiguous runs and **prints** the commands —
it submits nothing:

```bash
./report_batches.sh --batches <(echo "1901 2000") --gaps
```
```
gaps: 17 point(s) in 7 contiguous run(s)
  1901-1908, 1913-1915, 1935, 1944-1945, 1952, 1960, 1962

>> resubmit commands (run from …/MYOMC/gridpack):
   ./submit_smeft.sh --start 1901 --end 1908 --only-missing
   ./submit_smeft.sh --start 1913 --end 1915 --only-missing
   …
```

`--resubmit-gaps` runs them, after showing the list and asking for confirmation
(`--yes` skips the prompt; with no tty it aborts rather than submitting):

```bash
./report_batches.sh --batches <(echo "1901 2000") --resubmit-gaps
```

#### Resubmitting with a one-week wall
`--week` (= `--flavour nextweek`, 168 h) is appended to every emitted command. Use it
for the `card=yes, log=no` gaps above — the ones that most likely died at a shorter
wall — and for the expensive class in general (`CuH≠0` **and** `CHG≠0`: median ~56 h,
p95 ~107 h, max ~154 h, so ~4% overrun a 72 h `testmatch`):

```bash
# the 1901-2000 gaps: carded, no logs -> wall suspects. Look first:
./report_batches.sh --batches <(echo "1901 2000") --gaps --week
```
```
gaps: 17 point(s) in 7 contiguous run(s)
  1901-1908, 1913-1915, 1935, 1944-1945, 1952, 1960, 1962

>> resubmit commands (run from …/MYOMC/gridpack):
   ./submit_smeft.sh --start 1901 --end 1908 --only-missing --flavour nextweek
   ./submit_smeft.sh --start 1913 --end 1915 --only-missing --flavour nextweek
   …
```
```bash
# how many jobs would this actually queue?  submits nothing
./report_batches.sh --batches <(echo "1901 2000") --resubmit-gaps --week --dry-run
```
```
>> resubmit commands (run from …/MYOMC/gridpack):
   ./submit_smeft.sh --start 1901 --end 1908 --only-missing --flavour nextweek
   …
>> DRY RUN: would submit 17 job(s) in 7 batch(es). Nothing submitted.
```
```bash
# then actually submit them
./report_batches.sh --batches <(echo "1901 2000") --resubmit-gaps --week
```

**The job count equals the gap count** -- the runs are collapsed from *consecutive* gap
indices, so a non-gap point can never sit inside one (it would have broken the run).
Between the dry-run and the real submit the number can only **shrink**, never grow:
`--only-missing` re-checks EOS and drops whatever finished in the meantime.

Any other flavour works too: `--flavour tomorrow`, `--flavour testmatch`.

Every emitted command keeps `--only-missing`, so a point that completes between the
report and the submit is dropped at submit time. The runs are contiguous spans that
exclude your running/idle/held points, but `--only-missing` does **not** consult the
queue — it only re-checks EOS.

⚠️ Read the shared-directory warning above before using `--resubmit-gaps` on a large
range: gaps include points a colleague may already be building, and an expensive point
is a ~56h 4-core build. `--gaps` first, then decide.

Point it at a different driver with `--submitter <path>` (default `../gridpack/submit_smeft.sh`).

### Reporting a CRAB run (`--backend crab`)
By default the report counts flat condor output files (`NANOGEN_<point>_<gjob>.root`) and
reads `condor_q` for the nanogen queue columns. If you submitted nanogen through **CRAB**,
pass `--backend crab` so the report counts the right thing:

```bash
./report_batches.sh --backend crab --grid 5d --ecm 100 --njobs 5
```

- **"done" is counted by walking the CRAB LFN tree**
  `NANODIR/<req>/ggHH_SMEFT_NANOGEN/<timestamp>/000X/*.root`, counting `.root` files per
  `<req>` (= point name minus the `powheg_` prefix, `[:100]` — exactly how `submit_crab.sh`
  names `outputPrimaryDataset`). The first *count* job-slots of each point are treated as
  delivered, so the `nanogen files` / `full` columns read the same as condor. Set `--njobs`
  to your CRAB `totalUnits ÷ unitsPerJob`.
- **CRAB jobs are not in your local `condor_q`,** so the nanogen `run`/`idle`/`held`
  columns read **0** under `--backend crab`. Check in-flight status with
  `crab status -d crab_nanogen/crab_<req>`. (Gridpack columns are unaffected — gridpacks
  are always condor.)

#### Resubmitting CRAB gaps
CRAB seeds jobs by job-number-within-task, so a **second submit of a point would duplicate
events** — `submit_nanogen … --only-missing` is unsafe here. Instead, under `--backend crab`,
`--gaps`/`--resubmit-nano` resolve each nanogen gap **per point** and only **print** the
right command (never auto-run):

```bash
./report_batches.sh --backend crab --grid 5d --ecm 100 --gaps
```
```
nanogen gaps (crab): 3 point(s) -- 1 with a task to resubmit, 2 not yet submitted

>> CRAB resubmit commands for incomplete tasks (run from …/submission, after
   'source /cvmfs/cms.cern.ch/common/crab-setup.sh'):
   crab resubmit -d …/crab_nanogen/crab_ggHH_SMEFT_…   # point 2
>> ranges with NO CRAB task yet -- these need an INITIAL submission (run from …/submission):
   ./submit_nanogen.sh --grid 5d --ecm 100 --start 3 --end 3 --backend crab
```

For each gap point the report checks its CRAB project dir
(`$CRAB_WORKAREA/crab_<req>`, default `./crab_nanogen/crab_<req>` — where `submit_crab.sh`
runs `crab submit` from). If it **exists**, the point has a task, so the fix is
`crab resubmit -d …` (safe: re-runs only that task's *failed* jobs — no seed reuse). If it
**does not**, the point was never submitted to CRAB, so it is grouped into contiguous ranges
flagged as needing an **initial** `./submit_nanogen.sh … --backend crab`. Override the
project-dir search root with `CRAB_WORKAREA=/path ./report_batches.sh …` if you ran
`crab submit` from elsewhere.

Options — all optional, all read-only:

| flag | default | note |
|------|---------|------|
| `--grid`    | `5d` | `4d`\|`5d`: picks the JSON **and** its gridpack dir together |
| `--ecm`     | `13.6` | `13`\|`13.6`\|`14`\|`100`: read the matching energy-tagged gridpack/nanogen dirs, and thread `--ecm` into the emitted resubmit commands. `13`/`14` also count against the reduced half grid |
| `--backend` | `condor` | `condor`\|`crab`: how nanogen "done" is counted and how gaps are resubmitted (see below) |
| `--resubmit-nano` | — | resubmit nanogen gaps: condor runs `submit_nanogen … --only-missing`; crab **prints** `crab resubmit` / initial-submit commands |
| `--points`  | (from `--grid`) | explicit JSON; overrides `--grid` |
| `--gpdir`   | (from `--grid`) | explicit gridpack dir; overrides `--grid` |
| `--nanodir` | `…/smeft_nanogen` | **must match the `--outdir` you submitted with** |
| `--no-queue` | — | skip the `condor_q` read; run/idle/held/gap read 0 |
| `--njobs`   | `5` | keep in sync with `NJOBS_PER_POINT` in `submit_nanogen.sh` |
| `--batches` | (built-in layout) | file of `start stop` lines — your own row split |
| `--chunk`   | — | uniform blocks of N points instead of the built-in layout |
| `--gaps`    | — | print the resubmit commands for the gaps; **submits nothing** |
| `--resubmit-gaps` | — | run them, after a confirmation prompt |
| `--dry-run` (`-n`) | — | with `--resubmit-gaps`: print the job count only, submit nothing |
| `--yes` (`-y`) | — | skip the confirmation prompt |
| `--week`    | — | append `--flavour nextweek` (168 h wall) to the emitted commands |
| `--flavour` | — | any flavour: `tomorrow`, `testmatch`, `nextweek` |
| `--submitter` | `../gridpack/submit_smeft.sh` | driver used by `--resubmit-gaps` |
| `--carddir` | `../gridpack/cards_prod` | where the `card` column looks |
| `--logdir`  | `"../gridpack/logs ../../condor/logs"` | dirs the `log` column searches |

```bash
./report_batches.sh --grid 4d          # the 4D grid + its gridpack dir
./report_batches.sh --chunk 500        # 5 coarse rows instead of 27

# if you submitted nanogen somewhere else, point the report at it
./report_batches.sh --nanodir root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen_5d
```

`--points` and `--gpdir` override `--grid` individually, but the JSON and the gridpack
dir must describe the **same** grid — mismatch them and every index silently maps to
the wrong point. Prefer `--grid`, which keeps the pair together (as `submit_nanogen.sh`
does).

### Custom batch ranges
The built-in rows are the production split. To use your own, put `start stop` pairs in
a file — one per line, `#` comments and blank lines ignored — and pass `--batches`:

```
# who-owns-what.txt
1701 1800
1801 1900   # mine
2401 2450
```
```bash
./report_batches.sh --batches who-owns-what.txt
```
Ranges are 1-based inclusive, like `--start/--end` everywhere else. They may overlap
and need not cover the grid; each row is counted independently, so the TOTAL line is
the sum of the rows shown, **not** the whole grid. Ranges past the end of the grid are
clamped with a warning on stderr, and the built-in layout falls back to uniform blocks
if the JSON is smaller than it expects.

Two counting traps the script handles, worth knowing if you ever count by hand:
EOS keeps **versioned shadow copies** named `.sys.v#.<name>` that also end in
`_gridpack.tar.gz` (counting them roughly doubles the total), and NANOGEN files
live in **per-point subfolders**, so the nanogen listing must be recursive
(`xrdfs ls -R`) or it reads 0.

⚠️ A truncated `xrdfs ls` returns a short listing with **exit status 0** — it looks
like a normal, smaller result. If a batch drops from one run to the next, suspect
the listing before you suspect lost files, and re-run.

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

> ⚠️ **CRAB is for INITIAL production only — do not use it to add statistics.**
> CRAB seeds jobs by job-number-within-task, so a **second task for a point that
> already ran** restarts numbering at 1 and reuses the first task's seeds on the
> same gridpack → **duplicate events**. There's no CRAB knob to offset the base seed
> (hardcoding one would collapse all jobs in a task to one seed). Within a task CRAB
> *is* collision-free (unique per-job seeds), and across different points the
> gridpacks differ so shared seed integers don't duplicate. `crab resubmit`
> (re-running only failed jobs) is safe. **For top-ups, use the condor backend's
> `--job-offset`** (see *Seeds* above) — its disjoint index-based windows are
> collision-free across resubmissions; CRAB ignores `--job-offset`.

## Centre-of-mass energy (`--ecm`)
`--ecm {13|13.6|14|100}` (TeV) sets the Pythia `comEnergy` **and** selects energy-tagged
input/output dirs, matching the gridpack driver `../gridpack/submit_smeft.sh --ecm`. It
**must match the energy the gridpack was built at** — the PDF and beam energy are baked
into the gridpack, so nanogen only needs the right `comEnergy` and the matching dirs.

| `--ecm` | `comEnergy` (GeV) | gridpack + output dirs | PDF (baked in the gridpack) |
|---|---|---|---|
| `13`   | 13000  | `…_13TeV` | 90400 = PDF4LHC15_nlo_30_pdfas |
| `13.6` (default, current production) | 13600 | *(untagged — the live dirs)* | 90400 = PDF4LHC15_nlo_30_pdfas |
| `14`   | 14000  | `…_14TeV` | 90400 = PDF4LHC15_nlo_30_pdfas |
| `100` (FCC-hh) | 100000 | `…_100TeV` | 93300 = PDF4LHC21_40_pdfas |

13.6 TeV keeps the original untagged EOS dirs (production untouched); 13 / 14 / 100 TeV read
and write the sibling `…_13TeV` / `…_14TeV` / `…_100TeV` dirs. `--comenergy` overrides only
the Pythia `comEnergy` (not the dir tag) for special cases.

**Reduced ("half") grid at 13 and 14 TeV.** These two cost-saving energies run a reduced
point set: the pairwise-2D scans **and** the axis points are kept in full, only the
many-operator **Gaussian block is halved** (every other point in file order). The swap is
**automatic and needs no extra flag** — with `--ecm 13`/`14` on `--grid 5d`/`9d`, the driver
(and `report_batches.sh`) pick `FINALgrid_for_SMEFT_{5D,9D}_halfgauss_for_13_14TeV.json`
instead of the full JSON, so gridpack → nanogen → report all iterate the **same** reduced
set (9D: 2000 → 1416; 5D: 2500 → 1651). Pass an explicit `--points` to override. See the
gridpack README's *Reduced grid* section for the full rationale.

```bash
# FCC-hh 100 TeV: reads …_100TeV gridpacks, writes …_100TeV nanogen, comEnergy 100000
./submit_nanogen.sh --start 1 --end 500 --ecm 100
./submit_nanogen.sh --start 1 --end 500 --ecm 100 --backend crab

# HL-LHC 14 TeV: reads …_14TeV gridpacks, writes …_14TeV nanogen, half grid (auto)
./submit_nanogen.sh --ncards 0 --ecm 14
```

### Grid selection: 4D vs 5D

`--grid {4d,5d}` picks which **bundled** points grid drives fragment names **and** the
matching default gridpack set (they are paired — a fragment name must equal its gridpack
name). `4d` = leading-only (no CtG, names omit `_CtG_`); `5d` = leading + CtG. Override
the JSON with `--points <file>` or the gridpack set with `--gridpack-dir <dir>`.

| `--grid` | bundled points JSON | default gridpack dir |
|---|---|---|
| `4d` | `FINALgrid_for_SMEFT_4D_leadingOnly_updated_PDF.json` | `…/smeft_gridpacks_keep_stage1` |
| `5d` (default) | `FINALgrid_for_SMEFT_5D_leading_plus_ctg.json` | `…/smeft_gridpacks_5param_keep_stage1` |

For a minimal single-job smoke test on a landed 4D gridpack, see
[`README_CANARY.md`](README_CANARY.md).

### Key options (defaults)
| flag | default | meaning |
|------|---------|---------|
| `--grid` | `5d` | `4d` or `5d`: bundled points grid + matching default gridpack set |
| `--points` | (from `--grid`) | explicit points JSON, overrides `--grid` |
| `--total-events` | `50000` | **total events per point** |
| `--njobs`     | `5`      | jobs per point |
| `--job-offset` | `0`     | add to jobidx → **global job number** for **collision-free top-ups** (see below) |
| `--ecm` | `13.6` | centre-of-mass energy in TeV: `13`\|`13.6`\|`14`\|`100`; sets `comEnergy` **and** the energy-tagged gridpack/output dirs; `13`/`14` auto-use the reduced half grid (see *Centre-of-mass energy* below) |
| `--comenergy` | (from `--ecm`) | √s in GeV; overrides only the Pythia `comEnergy`, not the dir tag (advanced) |

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
| `--hard-only` (`--no-shower`) | off | **store only the hard scattering** — disable the Pythia shower |
| `--test` (`--smoke`) | off | **quick smoke test** — 1 job × 100 events on the first gridpack-ready point |

### Seeds — collision-free by construction, and how to add statistics later
Every RNG seed is a deterministic function of the point's **unique JSON index** and a
**global job number** `gjob = --job-offset + jobidx`. Each `(point, gjob)` owns a
**disjoint 1000-wide seed window** computed in the driver and passed to the job as
`RSEED_BASE`:
```
RSEED_BASE = point_index*100000 + gjob*1000        # lower edge of the window
externalLHEProducer.initialSeed = RSEED_BASE + 1   # POWHEG (LHE)
generator.initialSeed           = RSEED_BASE + 2   # Pythia8
POWHEG per-core stream i        = RSEED_BASE + 10 + i   # set in condor/runcmsgrid.sh
```
Because the windows never overlap, **no two (point, job, core) or Pythia seeds can ever
collide** — across points, across the N parallel POWHEG streams, and across resubmissions.
Using the JSON *index* (not a `crc32` hash) removes the last residual point-collision
chance. Ceiling: index < 9000 and gjob < 100 keep every seed `< 9e8` (the CMS
`RandomNumberGeneratorService` / Pythia8 limit); the driver **guards** both bounds.

**⚠️ Re-running the same `gjob` reproduces the identical events** (the seed is fully
deterministic). That is exactly what you want for `--only-missing` (regenerate a failed
job identically), but it means you must **not** naively resubmit to *add* statistics.

**To add more events to points that already have jobs `1..N`,** give the new batch a
`--job-offset` of `N` so it uses fresh `gjob = N+1 …` — fresh seed windows **and** fresh
output filenames (`NANOGEN_<point>_<gjob>.root`), so nothing is overwritten or duplicated:
```bash
# initial 50k/point in 5 jobs (gjob 1..5)
./submit_nanogen.sh --start 1701 --end 2500
# later: +40k/point in 4 more jobs (gjob 6..9), collision-free
./submit_nanogen.sh --start 1701 --end 2500 --job-offset 5 --njobs 4 --total-events 40000
```
Keep total jobs/point ≤ 99. (CRAB backend seeds itself and ignores `--job-offset`.)

### Quick smoke test (`--test`)
`--test` runs a single, cheap NANOGEN job to validate the chain end-to-end. It
forces `--total-events 100 --njobs 1` and, after listing which gridpacks are
ready on `--gridpack-dir`, queues **only the first ready point** in the selection
(condor backend only). Combine with `--start/--end` or `--ncards` to control the
pool it picks from, and with `--hard-only` to probe the no-shower path:
```bash
./submit_nanogen.sh --ncards 0 --test              # first ready gridpack anywhere
./submit_nanogen.sh --start 4 --end 20 --test      # first ready in points 4..20
./submit_nanogen.sh --ncards 0 --test --hard-only  # + hard-scattering only
```
If no gridpack in the selection is ready yet, it prints `nothing to submit` and
exits without queuing anything.

### Hard-scattering only (no parton shower)
For SMEFT reweighting/templates you often need only the **hard process**, not the
showered final state. Pass `--hard-only` (alias `--no-shower`) and the per-point
fragment gets `PartonLevel:all = off` + `HadronLevel:all = off`, so Pythia just
passes the LHE hard process through — no ISR/FSR, MPI, beam remnants,
hadronization, or decays:
```bash
./submit_nanogen.sh --ncards 3 --hard-only            # condor
./submit_nanogen.sh --ncards 0 --hard-only --backend crab
```
The NANOGEN `GenPart` table then holds only the gg→HH hard-scattering particles,
and `LHEPart` (filled directly from the gridpack LHE) is present regardless —
much faster and smaller. The switch lives in the **fragment**, so it applies to
both backends; combine freely with `--report`/`--only-missing`/range flags.

## Timing

Cost is dominated by the **hard process**: every generated event triggers a full
`ggHH_SMEFT` `mtdep=3` two-loop virtual evaluation inside `ExternalLHEProducer`
(**~10 CPU-seconds/event**). The Pythia8 shower, the NANOGEN step and the CMSSW build are
small by comparison. Because the gridpack ships its integration grids, jobs **generate on
demand** — no long integration here, unlike the gridpack step.

Per-job wall time on the defaults (`--nthreads 1`, ~10 s/event, single core):

| events/job | ≈ gen time | + CMSSW build | job total | how you get there |
|---|---:|---|---:|---|
| 100 (`--test`) | ~17 min | ~few min | **~20 min** | `--total-events 100 --njobs 1` |
| 1 000 | ~2.8 h | ~few min | **~2.8 h** | measured timing probe |
| 10 000 | ~28 h | ~few min | **~28 h** | default `--total-events 50000 --njobs 5` |
| 20 000 | ~56 h | ~few min | **~56 h** | e.g. 100k in 5 jobs |

- **Fixed overhead:** each job builds `CMSSW_14_1_8` fresh in scratch (~few min). Subtract
  it (from the `.out` timestamps) before scaling a probe to production.
- **Wall budget:** the default `--flavour testmatch` = 72 h, so keep **events/job ≲ 20 000**
  on one thread. Split more events into more jobs (`--njobs`) rather than fatter jobs.
- **`--nthreads N`** hands `cmsRun` N threads (`request_cpus = N`); event generation scales
  roughly `1/N`, so `--nthreads 4` brings 20k events into ~14 h.
- **`--hard-only`** skips the parton shower / hadronization — faster and smaller output, but
  the ~10 s/event virtual (the dominant term) is unchanged, so the wall-time win is modest.

## Where the NANOGEN files go
The output location depends on the backend.

### HTCondor backend (default)
Each job xrdcp's its file (from `run_nanogen.sh`) to **`--outdir`**, default:
```
root://eosuser.cern.ch//eos/user/a/acarvalh/smeft_nanogen/
```
Files are delivered into a **per-point subfolder**, named by the global job number
`gjob` (= `--job-offset + jobidx`): `<point>/NANOGEN_<point>_<gjob>.root`. E.g. the
default 5 jobs give `..._1.root … _5.root`, and a `--job-offset 5` top-up adds
`..._6.root …` alongside them without overwriting:
```
/eos/user/a/acarvalh/smeft_nanogen/<point>/NANOGEN_<point>_5.root
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
- **Per-job seeds**: the driver assigns each `(point, gjob)` a disjoint seed window
  (`RSEED_BASE`, see *Seeds* above), so all jobs, POWHEG streams and Pythia seeds are
  statistically independent and **globally collision-free**, including across top-up
  batches submitted with `--job-offset`.
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
