# SMEFT truncation validation

Reproduce the five di-Higgs SMEFT benchmark points of **LHCHWG-2026-006**
*("Higgs boson pair production in SMEFT: shape and truncation studies", Bär,
Chargeishvili, Gröber, Heinrich, Schmid)*, each generated **twice** — once under
**linear** truncation and once under **full (quadratic)** truncation — to study how the
truncation scheme changes the m_hh and p_T,h shapes. Five benchmarks × two truncations =
**10 gridpacks / 10 NANOGEN points**, at **13.6 TeV** (the paper's energy).

This is a self-contained study, separate from the main SMEFT grid production
(`submit_smeft.sh`) and the HEFT basis (`submit_heft.sh`). It reuses the shared per-job
executable (`run_smeft_gridpack.sh`) and condor submit file (`submit_smeft.sub`), and the
shared NANOGEN backend (`submission/submit_nanogen.sh`).

---

## Physics setup (matches the paper)

| quantity | value | source |
|----------|-------|--------|
| √s | 13.6 TeV (Run 3) | Table 1 |
| PDF | **PDF4LHC21_40** (LHAID 93300) | Table 1 |
| central scale | µ_R = µ_F = **m_hh / 2** | Sec. 3 |
| EFT scale Λ | 1 TeV | Table 1 |
| RGE running | **OFF** (`WCscaledependence 0`) | Sec. 3.2 |

> The main production uses PDF4LHC15 (90400) at 13.6 TeV; this study deliberately switches
> to the paper's PDF4LHC21_40 (93300). The central scale m_hh/2 already matches both.

### The two truncations

The linear/quadratic switch is the POWHEG card parameter **`SMEFTtruncation`** (aliased
`multiple-insertion` in the generator source — `setSMEFTcoupl.f` reads `#SMEFTtruncation`,
falling back to `#multiple-insertion`; they set the same variable):

| variant | `SMEFTtruncation` | cross section | report |
|---------|-------------------|---------------|--------|
| **linear** (`lin`) | **0** | \|A_SM\|² + 2·Re(A_SM·conj(A_dim6)) | Eq. 5–6: σ_SM + Σ Aᵢ Cᵢ |
| **full / quadratic** (`quad`) | **1** | \|A_SM + A_dim6\|² | Eq. 9: \|M_SM + M⁽⁶⁾\|² |

Options 2/3 (which add dim-6 *double* insertions, `A_dbldim6`, formally dim-8) are **not**
used — the paper excludes them. `MEborn.f90` carries the matching *single insertion*
(linear) and *double insertion* (quadratic) amplitude blocks.

### Benchmark points (report Table 3)

Wilson coefficients mapped to this setup's card parameter names:

| report | card | note |
|--------|------|------|
| C_H,kin | `CHbox` | with `CHD=0`, C_H,kin = C_H□ − C_HD/4 = `CHbox` (Eq. 4 field redef) |
| C_H | `CH` | |
| C_tH | `CuH` | modified top Yukawa operator |
| C_HG, C_tG, C_Qt⁽¹⁾, C_Qt⁽⁸⁾ | `CHG`, `CtG`, `CQt`, `CQt8` | all 0 in these BMs |

| BM | `CHbox` | `CH` | `CuH` | µ_hh (Table 3) |
|----|---------|------|-------|----------------|
| BM1 | 0 | 3 | 0 | 2.9 |
| BM2 | −2 | −2 | 4 | 2.1 |
| BM3 | 0 | −3 | 0 | 0.4 |
| BM4 | 0 | −6 | 0 | 1.2 |
| BM5 | −2 | −3 | 0.5 | 0.6 |

All five use only `CHbox`/`CH`/`CuH`; the four-fermion/`CtG` operators stay 0, so
`includesubleading` stays 0 (cheaper). Only BM1 & BM2 give non-negative distributions under
linear truncation; BM3–5 turn negative — that is the shape-breakdown the study probes.

---

## Files

| file | role |
|------|------|
| `smeft_truncation_bm.csv` | the 5 benchmarks, report coeffs → card names (+ µ_hh for reference) |
| `makeTruncationCards.py` | writes 2 POWHEG cards/point (lin & quad), setting `SMEFTtruncation` + forcing `WCscaledependence 0` |
| `submit_truncation.sh` | gridpack driver — 1 condor job per card; `--check`, `--only-missing`, `--dry-run`, `--test` |
| `../submission/make_trunc_fragments.py` | tag-named NANOGEN fragments (+ manifest) for these gridpacks |
| `../submission/submit_nanogen_trunc.sh` | NANOGEN driver (wrapper over `submit_nanogen.sh --grid trunc`) |

Card / gridpack / fragment / output names all share the tag
`powheg_ggHH_SMEFT_TRUNC_<BM>_<lin|quad>` (lin/quad in the name so the two never collide —
they share every coupling).

### EOS locations (13.6 TeV)

- gridpacks: `/eos/user/a/acarvalh/gghh_smeft_truncation_gridpacks_13p6TeV`
- nanogen:   `/eos/user/a/acarvalh/gghh_smeft_truncation_nanogen_13p6TeV`

---

## Workflow

All commands run from `MYOMC/` with the environment sourced (`source env.sh`) and a valid
grid proxy at `$HOME/private/x509up`
(`voms-proxy-init --rfc --voms cms -valid 192:00`).

### 1 — Build the 10 gridpacks

```bash
cd gridpack
./submit_truncation.sh              # submit all 10 (5 BM × {lin,quad}), 13.6 TeV
./submit_truncation.sh --check      # TEST IF ALL DONE: lists done/missing, exit 0 iff 10/10
./submit_truncation.sh --only-missing   # resubmit only not-yet-done gridpacks
./submit_truncation.sh --dry-run    # build cards + cards.list, submit nothing
```

Useful subsets: `--points BM1,BM3` (both variants of a subset), `--only lin` / `--only quad`.
Gridpack builds take ~1–2 days on the `testmatch` queue.

### 2 — Submit NANOGEN

Only runs for tags whose gridpack already exists, so it is safe to run repeatedly while
gridpacks are still building.

```bash
cd ../submission
./submit_nanogen_trunc.sh               # all 10 (condor), 50k evts/point = 5 jobs × 10k
./submit_nanogen_trunc.sh --report      # TEST IF ALL DONE: per-tag NANOGEN status
./submit_nanogen_trunc.sh --only-missing   # resubmit only missing NANOGEN jobs
./submit_nanogen_trunc.sh --dry-run     # build fragments + joblist, submit nothing
./submit_nanogen_trunc.sh --backend crab   # CRAB backend (one PrivateMC task per tag)
```

NANOGEN inherits the main production's `HARD_ONLY=1` default (Pythia hard process only, no
shower) — the right level for the paper's parton-level m_hh / p_T,h shape comparison. Add
`--with-shower` to enable the full shower/hadronization. Any extra `submit_nanogen.sh` flag
(`--njobs`, `--total-events`, `--flavour`, `--job-offset`, …) passes straight through.

### 3 — Cross sections (optional)

Once the gridpacks are done, extract the per-point NLO cross sections the same way as the
HEFT basis:

```bash
cd ../gridpack
python3 ../tools/gridpack_xsec.py \
    /eos/user/a/acarvalh/gghh_smeft_truncation_gridpacks_13p6TeV \
    --csv truncation_xsec_13p6TeV.csv --sort name
```

The linear cross section can be **negative** for BM3–5 — that is physical for this study
(the linear truncation breaks down), not a bug.

---

## Notes & gotchas

- **Naming is the linchpin.** The nanogen fragment/output name must equal the gridpack tag,
  because `run_nanogen.sh` fetches `<GRIDPACK_DIR>/<tag>_gridpack.tar.gz`. `lin`/`quad`
  therefore live in the name, not in coefficients (which are identical for the pair).
- **13.6 TeV only.** `submit_nanogen.sh --grid trunc` rejects other energies — the gridpack
  dir is hardcoded with the `_13p6TeV` tag `submit_truncation.sh` used (submit_nanogen's own
  `ECM_TAG` is empty at 13.6, so it cannot derive that path).
- **Seed windows** use the fragment manifest's canonical index (BM1_lin=0 … BM5_quad=9), so
  the 10 points get disjoint, collision-free seed ranges like the main production.
- **CRAB is initial-production only** — for statistics top-ups use the condor backend with
  `--job-offset` (CRAB would reuse job-number seeds and duplicate events).
