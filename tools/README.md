# MYOMC tools

Small helpers that read the SMEFT production artefacts. Nothing here submits jobs
or touches the running pipelines.

## `gridpack_xsec.py` — cross section from gridpacks

Pulls the POWHEG NLO cross section straight out of `*_gridpack.tar.gz` — no
re-running. It reads the `pwg-st3-*-stat.dat` members in memory (nothing is
unpacked to disk), combines the 4 POWHEG parallel strands by an inverse-variance
weighted average, and prints one CSV row per gridpack:

```
index,point_name,xsec_pb,err_pb,nstrands
1,powheg_ggHH_SMEFT_CHbox_0_CH_0_CuH_0_CHG_0_CtG_0,0.030918839,5.879e-05,4
```

The xsec is **inclusive `gg → HH`** at the gridpack's build energy (NLO), **before
any HH decay branching ratio**. `index` is the 1-based position of the point in
the grid JSON given with `--points`, matched by the same `point_name` encoder as
the gridpacks/fragments (`submission/make_fragments.py`); blank if the gridpack
isn't in that JSON.

```bash
# one gridpack
./gridpack_xsec.py /eos/user/a/acarvalh/smeft_gridpacks_5param_keep_stage1/<point>_gridpack.tar.gz

# a whole dir, numbered against the 5D grid, written to CSV
./gridpack_xsec.py /eos/user/a/acarvalh/smeft_gridpacks_5param_keep_stage1 \
    --points ../submission/FINALgrid_for_SMEFT_5D_leading_plus_ctg.json \
    --csv xsec_5d.csv
```

Options: `--points <json>` (add the index column), `--csv <file>` (write a file
instead of stdout), `--sort name|index|xsec` (default `index`).

> **EOS sweeps are slow.** Each gridpack is ~35 MB and the tool reads the whole
> tarball over the network, so a full directory (hundreds of points) takes many
> minutes. Always use `--csv` for a directory sweep and run it detached (e.g.
> `nohup ./gridpack_xsec.py <dir> --points ... --csv xsec.csv &`) rather than
> waiting on stdout. A single gridpack returns in a second or two.
