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
| `report_batches.sh`  | read-only progress table: gridpacks + NANOGEN ready, per index batch |

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
 start   stop   pts |     gridpacks |   nanogen files |   points w/ full nanogen
  1701   1800   100 |     100/100 * |       500/500 * |                100/100 *
  1801   1900   100 |     100/100 * |         0/500   |                  0/100
  1901   2000   100 |      74/100   |         0/500   |                  0/100
```
A `*` marks a **complete** cell. A star in the *gridpacks* column means the batch is
ready for `submit_nanogen.sh`; a star in the last column means the batch is finished.
That last column counts points with a complete set of `--njobs` files — a point with
3/5 is still short, and a re-submit tops it up (the driver skips `gjob`s that exist).

Options — all optional, all read-only:

| flag | default | note |
|------|---------|------|
| `--grid`    | `5d` | `4d`\|`5d`: picks the JSON **and** its gridpack dir together |
| `--points`  | (from `--grid`) | explicit JSON; overrides `--grid` |
| `--gpdir`   | (from `--grid`) | explicit gridpack dir; overrides `--grid` |
| `--nanodir` | `…/smeft_nanogen` | **must match the `--outdir` you submitted with** |
| `--njobs`   | `5` | keep in sync with `NJOBS_PER_POINT` in `submit_nanogen.sh` |
| `--batches` | (built-in layout) | file of `start stop` lines — your own row split |
| `--chunk`   | — | uniform blocks of N points instead of the built-in layout |

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
