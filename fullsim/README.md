# ggHH_SMEFT 2024 full simulation (bbgg / 4b / bbtt)

Full-sim driver for **selected** ggHH_SMEFT points in three HH decay channels,
running the complete **Run3Summer24** chain
`LHE → GEN → SIM → DIGI → HLT → RECO → MINIAODSIM → NANOAODSIM` via the campaign
`campaigns/Run3Summer24wmLHEGS/run.sh`, submitted with `bin/crun.py`.

> **Separate from the running pipelines.** This folder has its own fragments,
> condor jobs and EOS output. It only *reads* the 13.6 TeV SMEFT gridpacks that
> `gridpack/submit_smeft.sh` produced — it does not touch the gridpack or NANOGEN
> (`submission/`) submissions.

## Usage

Points are given with the **required `--points`** option, as a **comma-separated
list of JSON index numbers** (**1-based**, the same numbering as `--start/--end`
elsewhere in MYOMC):

```bash
source ../env.sh                       # sets $MYOMCPATH, needed by crun.py
cd fullsim

./submit_fullsim.sh --points 12,57,340              # 3 points, all 3 channels, 500k events each
./submit_fullsim.sh --bbgg --points 12,57           # only the bbgg channel
./submit_fullsim.sh --bbgg --bbtt --points 12,57    # bbgg and bbtt
./submit_fullsim.sh --channels bbgg,4b --points 12,57   # same, via comma list
./submit_fullsim.sh --nevents 200000 --points 12    # 200k events/point/channel
./submit_fullsim.sh --grid 9d --points 4,8,15       # indices into the 9D grid
./submit_fullsim.sh --dry-run --points 12,57,340    # build fragments + print crun cmds, submit nothing
```

One condor submission is made **per (point, channel)**. `--nevents` is the total
per point per channel (**default 500 000**); it is split into `--njobs` jobs of
`--nevents-job` events (default `2000` ⇒ `njobs = ceil(nevents / 2000) = 250`).

## What each channel forces

The gridpack gives `gg → HH`; the Higgs decays are forced in the fragment. The
Higgs (25) decay **table is replaced** with the channel's two legs at **equal
weight** (`25:oneChannel`/`25:addChannel`, `meMode 100`), and a
`ResonanceDecayFilter` (exclusive on the daughter multiset) keeps the
one-and-one combination. Equal weight — rather than leaving natural BRs, which
send almost every Higgs to `bb` and give a <1% filter efficiency — is the
standard CMS recipe for asymmetric HH decays: each Higgs picks a leg ~evenly, so
~half the showered events survive the filter.

| `--channels` | forced decay | daughters | filter eff |
|---|---|---|---|
| `bbgg` | one `H→bb`, one `H→γγ` | `5,5,22,22` | ~0.5 |
| `4b`   | both `H→bb`            | `5,5,5,5`  | ~1.0 |
| `bbtt` | one `H→bb`, one `H→ττ` | `5,5,15,15` | ~0.5 |

The per-channel filter efficiency above is recorded in the fragment's
`filterEfficiency` for bookkeeping.

`comEnergy = 13600` (Run 3 / 2024). Gridpacks come from the **untagged 13.6 TeV**
production selected by `--grid` (`4d`/`5d`/`9d`, default `5d`).

## Key options

| flag | default | meaning |
|---|---|---|
| `--points` **(required)** | — | JSON point indices, 1-based, **comma-separated** (e.g. `12,57,340`) |
| `--bbgg` `--4b` `--bbtt` | (all 3) | pick channels as bare flags; any given override the default set |
| `--channels`   | `bbgg,4b,bbtt` | same, as a comma list, any subset |
| `--nevents`    | `500000` | total events per point per channel |
| `--nevents-job`| `2000` | events per condor job |
| `--njobs`      | derived | override the derived `ceil(nevents/nevents-job)` |
| `--grid`       | `5d` | `4d`/`5d`/`9d`: which JSON the indices index, and its gridpack set |
| `--points-json`| (from `--grid`) | explicit points JSON file (overrides `--grid`'s bundled one) |
| `--gridpack-dir` | (from `--grid`) | explicit xrootd gridpack base |
| `--campaign`   | `Run3Summer24wmLHEGS` | campaign chain |
| `--outeos`     | `/store/user/acarvalh/smeft_fullsim_2024` | EOS base; a `/<channel>` subdir is appended |
| `--keep`       | `MINI,NANO` | tiers to stage out (`GS,DR,RECO,MINI,NANO`) |
| `--seed-offset`| `0` | crun seed offset (collision-free top-ups) |
| `--mem`        | `7900` | `request_memory` (MB) |
| `--max-threads`| `8` | cmsRun threads (`request_cpus`) |
| `--no-env`     | (env on) | do **not** pass `--env` (build CMSSW in-job instead of a tarball) |
| `--no-pileup-file` | (on) | do **not** pass `--pileup_file` |
| `--dry-run` (`-n`) | off | build fragments, print the `crun.py` commands, submit nothing |

## Prerequisites (once)

1. **`source ../env.sh`** — exports `$MYOMCPATH`, which `crun.py` requires.
2. **Pre-packaged CMSSW env** (`--env`, the default): run
   `campaigns/Run3Summer24wmLHEGS/setup_env.sh` first to build the CMSSW tarballs
   (it also patches the DIGI step so it doesn't choke on the ~300k premix pileup
   files). Use `--no-env` to skip and let each job `scram p` instead (slower).
3. **Pileup** (`--pileup_file`, the default): a premade premix input list must be
   available to the campaign (`campaigns/Run3Summer24wmLHEGS/getpileupfiles.sh`).
   Use `--no-pileup-file` to fall back to the in-job DAS query.
4. **Grid proxy** — `crun.py` handles a 72 h `x509` proxy; jobs xrdcp outputs to EOS.
5. **Gridpacks present** — the selected points' `<point>_gridpack.tar.gz` must exist
   in `--gridpack-dir` (built by `gridpack/submit_smeft.sh`).

## Files

| file | role |
|---|---|
| `submit_fullsim.sh` | driver: indices → per-(point,channel) fragment → `crun.py` submit |
| `make_fullsim_fragment.py` | one full-hadronization + decay-filter fragment per (point, channel); imports the point→name encoder from `../submission/make_fragments.py` so fragment names match the gridpacks |
| `fragments_fullsim/` | generated fragments (`idx<N>__<channel>.py`) |
