# `pl pipeline`

Run a site's project-specific data pipeline.

## Why this verb exists

Some sites carry a data pipeline: a scraper, an NLP service, a market monitor.
Those pipelines are **site data, not engine code** — they live in the site's own
repository, under `sites/<site>/dev/pipeline/`. The engine's only job is to know
how to find one and run it.

Before ops#326 the engine instead shipped a verb *named after one private site's
pipeline*, which hardcoded that site's directory:

```bash
MT_DIR="$PROJECT_ROOT/<private-site>"
exec "$MT_DIR/<verb>.sh" "$@"
```

Two defects. `nwp/nwp` is the generic engine and is publicly mirrored, so a
private instance's name in it is a disclosure (operator ruling 2026-08-09,
ops#326). And the path had been dead since the F23 layout change, so every
invocation exited 127 with a bare "No such file or directory" — invisible for
months because nothing asserted on it.

`pl pipeline` names the **function**, takes the site as an **argument**, and
resolves the entrypoint inside that site's own tree.

## Usage

```bash
pl pipeline list                                  # sites that ship a pipeline
pl pipeline <site> [args…]                        # run it
pl pipeline <site> --entrypoint=<flow> [args…]    # pick one of several
pl pipeline <site> --setup [args…]                # setup-<flow>.sh
pl pipeline <site> --deploy [args…]               # deploy-<flow>.sh
pl pipeline --find=<flow> [--dry] [args…]         # resolve the owning site
pl pipeline <site> --dry                          # resolve and print, run nothing
```

Everything after the first unrecognised argument is forwarded to the pipeline
verbatim.

## Layout contract

| Path | Meaning |
|---|---|
| `sites/<site>/dev/pipeline/<flow>.sh` | the pipeline |
| `sites/<site>/dev/pipeline/run-<flow>.sh` | optional wrapper — **preferred** when present (it carries the venv / `PYTHONPATH`) |
| `sites/<site>/dev/pipeline/setup-<flow>.sh` | `--setup` |
| `sites/<site>/dev/pipeline/deploy-<flow>.sh` | `--deploy` |
| `sites/<site>/pipeline/…` | pre-F23 layout, still honoured |

## Fail-closed behaviour

Every unresolvable case REFUSES and names what it could not settle — none of
them is allowed to become a silent no-op, which is exactly how the predecessor's
exit 127 went unnoticed:

| Situation | Result |
|---|---|
| no site argument | usage + refusal, exit 2 |
| unknown site | refusal naming the site, exit 1 |
| site has no `dev/pipeline/` | refusal naming the site and the expected path, exit 1 |
| more than one entrypoint, none chosen | refusal listing them + the `--entrypoint` hint, exit 1 |
| `--find` matched zero sites | refusal naming the flow, exit 1 |
| `--find` matched more than one site | refusal listing the owners, exit 1 |

## Deprecated predecessor

The retired scraper verb remains as a thin shim: it prints a deprecation notice
naming `pl pipeline`, translates its old flag spellings (`--setup-check`,
`--setup-uninstall`, `--deploy-conf`), and forwards to
`pl pipeline --find=<its own name>`. It therefore still works, and — because it
resolves the owning site by scanning rather than hardcoding it — it names no
site either. It will be removed once the deprecation window closes.

## Tests

`tests/unit/test-pipeline.bats` (18 cases, all observed RED before
`scripts/commands/pipeline.sh` existed).
