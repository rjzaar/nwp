# F33: Repository Topology Refactor

**Status:** SUPERSEDED 2026-05-22 — simpler gitignore-only approach adopted
**Created:** 2026-05-09
**Superseded by:** gitignoring `servers/*` to match the existing `sites/*` pattern; no separate `~/nwp-instances/` repo required. See §10 below for the rationale.
**Author:** Robert Karsten Zaar (with AI assistance)
**Architecture decision record:** [ADR-0021](../decisions/0021-public-only-repo-scope.md) (still in effect — public/private split is real; mechanism simplified)

> **Why this proposal is superseded.** Audit of `~/nwp/` git state on 2026-05-22 showed that `sites/`, `nwp.yml`, `.secrets.yml`, `keys/prod_*`, and `private/` are *already* gitignored; only `servers/<host>/` was tracked. Extending the existing gitignore pattern from `sites/` to `servers/` achieves the public/private split (G1 + G3 from §2) without the overhead of a parallel `~/nwp-instances/` repo, `pl` layout detection (§4.2), or an `instance-manifest.yml` (§4.3). The full move-out remains a valid future direction if multi-operator / multi-machine private-overlay sync becomes a real need (see §10).

> **Original proposal below** is preserved verbatim for context. The simpler resolution lives in the new §10.

---

## 1. Executive Summary

The NWP repository today carries both generic framework code (the `pl` CLI, recipes, deploy patterns, ADRs, generic proposals) and operator-specific configuration (per-site `sites/<name>/` directories, live `nwp.yml` with domain bindings, server inventories under `servers/<host>/`). For NWP to be a public OSS tool, the operator-specific portions must move to a separate private repository.

This proposal implements that cutover in five phases:

1. Create the private overlay repository (`nwp-instances/`) on private hosting.
2. Migrate per-site directories from `nwp/sites/<name>/` into `nwp-instances/<name>/` (verbatim copy plus a generated `instance-manifest.yml`).
3. Replace the public `nwp/sites/<name>/` paths with symlinks for backwards compatibility through v0.40.0.
4. Update `pl` to detect the new layout (`${NWP_INSTANCES_DIR:-$HOME/nwp-instances}` first; fall back to deprecated `nwp/sites/`).
5. Update `CONTRIBUTING.md` to explain the convention; remove the deprecated path in v1.0.0.

Throughout the cutover, the operator's existing deploy chain must continue to work without manual intervention.

## 2. Goals

- **G1.** The public `nwp/` repository contains zero per-site configuration after Phase 5.
- **G2.** The operator's existing deploy commands (`pl deploy <site>`, `pl backup <site>`, `pl test <site>`) continue to work throughout the cutover.
- **G3.** A new contributor cloning the public repository sees no per-site bindings; `pl init --tier=1` works from a clean checkout.
- **G4.** A representative production deploy works end-to-end immediately after each phase.
- **G5.** The private overlay has full git history, full backup pipeline, cross-machine sync working before the public-side cleanup begins.

## 3. Non-Goals

- This proposal does **not** define the tier or feature model; that work is [ADR-0020](../decisions/0020-tiered-architecture-model.md) / [F32](F32-tiered-architecture-implementation.md).
- This proposal does **not** rewrite the AI integration; that work is [F32](F32-tiered-architecture-implementation.md) Phase C.
- This proposal does **not** address content of operator-specific proposals (X-series, per-site A-/S-/M-/C-series); that work is [F34](F34-role-label-proposal-rewrite.md).
- This proposal does **not** install the leakage hygiene gate; that work is [P61](P61-leakage-hygiene-ci.md), which must land first.

## 4. Architecture

### 4.1 Target layout

After cutover:

```
PUBLIC (nwp/)                        PRIVATE (nwp-instances/)
─────────────                        ────────────────────────
pl                                    instance-manifest.yml
lib/                                  _global/
  adapters/                             nwp.yml             ← live operator config
    ci/                                 .secrets.yml
    ai/                                 keys/               ← prod keys (gitignored)
    deploy/                           <site-1>/
  schema/                                nwp.yml            ← per-site config
  migrations/                            settings.local.php
  ...                                    proposals/         ← Tier-B per-site
recipes/                                 server/            ← per-site server inventory
docs/                                 <site-2>/
  decisions/                             ...
  proposals/                          ...
  tiers/
  reference/
servers/
  README.md                          (gitlab.com private mirror)
  example-server.example.yml         (encrypted backup nightly)
sites/                               (cross-machine sync via git)
  README.md                          (single source of truth for instance state)
  example-site.example.yml
tier-1.example.nwp.yml
tier-2.example.nwp.yml
tier-3.example.nwp.yml
tier-4.example.nwp.yml
nwp.example.yml
.secrets.example.yml
LICENSE                              (the public repo never contains
NOTICE                                instance-specific values)
CONTRIBUTING.md
README.md
```

The public repo retains `sites/` and `servers/` directories purely for templates and documentation; concrete per-site / per-server content lives in `nwp-instances/`.

### 4.2 `pl` layout detection

A new helper `lib/common/find-instance-dir.sh`:

```bash
find_instance_dir() {
  if [[ -n "${NWP_INSTANCES_DIR:-}" ]]; then
    echo "${NWP_INSTANCES_DIR}"
    return
  fi
  if [[ -d "${HOME}/nwp-instances" ]]; then
    echo "${HOME}/nwp-instances"
    return
  fi
  if [[ -d "${SCRIPT_DIR}/sites" ]] && [[ -n "$(ls -A "${SCRIPT_DIR}/sites" 2>/dev/null | grep -v README.md | grep -v '\.example\.')" ]]; then
    echo "${SCRIPT_DIR}/sites"
    echo "DEPRECATION: per-site config in nwp/sites/ is deprecated; move to ${HOME}/nwp-instances/" >&2
    return
  fi
  echo ""
}
```

All `pl` subcommands that reference per-site paths route through this helper.

### 4.3 The `instance-manifest.yml`

A single private file at the top of `nwp-instances/` binds role labels to actual hosts:

```yaml
# nwp-instances/instance-manifest.yml — PRIVATE
roles:
  authoring:           [<authoring-host>]
  ci-host:             [<ci-host>]
  ai-host:             [<ai-host>]
  verifier:            [<verifier-host>]
  voice-agent:         [<voice-agent-host>]
  transcription-gpu:   [<transcription-gpu-host>]
  mirror-store:        [<mirror-store-host>]

operator:
  legal-name:          <name>
  email:               <email>
  github:              <handle>
  jurisdiction:        <state, country>

domains:
  prod-base:           <base>
  ddev-base:           ddev.site
```

This file is what makes the role-label vocabulary in public artefacts (proposals, examples, ADRs) reach concrete hosts. It lives in the private overlay and is referenced indirectly via `pl host` / `pl status`.

### 4.4 Per-site directory shape

A `nwp-instances/<site>/` directory contains:

```
<site>/
  nwp.yml                        ← per-site NWP config (recipe, domain, backup target)
  .secrets.yml                   ← per-site secrets (gitignored locally; encrypted in remote)
  settings.local.php             ← Drupal local settings
  proposals/                     ← Tier-B per-site proposals (private)
  server/
    inventory.yml                ← per-site server inventory
  notes/                         ← operator's per-site notes (decisions, runbooks)
```

The `proposals/` subdirectory captures Tier-B (private) per-site proposals. Tier-A (public) per-site proposals stay in the public profile (see [F34](F34-role-label-proposal-rewrite.md)).

## 5. Phases

### Phase 1 — Create the private overlay

**Goal:** `nwp-instances/` exists as a private git repository with backup and sync working.

**Tasks:**
- [ ] Create the `nwp-instances` repository on private hosting.
- [ ] Configure encrypted nightly backup pipeline.
- [ ] Configure cross-machine sync (the operator's existing GitLab + nightly mirror to mirror-store host).
- [ ] Initial commit: empty README plus the `instance-manifest.yml` template.

**Definition of done:** A clone-pull-push cycle works from at least two of the operator's hosts.

### Phase 2 — Migrate per-site directories

**Goal:** Per-site content moves from `nwp/sites/<name>/` into `nwp-instances/<name>/`; existing operations continue to work.

**Tasks:**
- [ ] Author `bin/migrate-sites-to-instances.sh` that copies each `nwp/sites/<name>/` directory verbatim to `nwp-instances/<name>/`.
- [ ] Author `bin/migrate-server-inventory-to-instances.sh` for `nwp/servers/<host>/`.
- [ ] Author `bin/generate-instance-manifest.sh` that emits `nwp-instances/instance-manifest.yml` from the operator's existing host configuration with role-label rebinding prompts.
- [ ] Run all three scripts; commit to `nwp-instances/`.
- [ ] Run a representative `pl deploy <site>` against the new layout (with `NWP_INSTANCES_DIR` set) to verify behaviour matches.

**Definition of done:** Every previously-working `pl` operation against a previously-working site continues to work when run against the migrated `nwp-instances/<site>/` layout.

### Phase 3 — Replace public-repo per-site directories with symlinks

**Goal:** The public `nwp/sites/<name>/` paths become symlinks to `nwp-instances/<name>/` so any tooling that reads the old path continues to work without code changes.

**Tasks:**
- [ ] Author `bin/symlink-sites-from-instances.sh` that replaces each `nwp/sites/<name>/` content with a symlink to the corresponding `nwp-instances/<name>/`.
- [ ] Add the symlinks to `.gitignore` (so they're not committed to the public repo).
- [ ] Verify symlinks resolve correctly across the operator's hosts (the path layout is identical on each host).

**Definition of done:** `pl deploy <site>` works through the symlinks; no code changes required to existing dispatch.

### Phase 4 — `pl` layout detection

**Goal:** `pl` natively detects the private overlay; symlinks become unnecessary; deprecation notice appears for users still on the old layout.

**Tasks:**
- [ ] Implement `lib/common/find-instance-dir.sh` per §4.2.
- [ ] Refactor every `pl` subcommand that reads per-site paths to route through the helper.
- [ ] Remove the symlinks; per-site paths now resolve via the new logic.
- [ ] Add a one-line deprecation notice on `pl status` if `nwp/sites/` contains non-template content (signals "your install is on the old layout").
- [ ] Update tests to use `NWP_INSTANCES_DIR` for the test-fixture setup.

**Definition of done:** `pl status` reports the instance directory in use; no symlinks needed; existing deploy chain works.

### Phase 5 — `CONTRIBUTING.md` update + remove deprecated path

**Goal:** The convention is documented for contributors; the deprecated `nwp/sites/<name>/` content path is removed in v1.0.0.

**Tasks:**
- [ ] Update `CONTRIBUTING.md` with a "Repository Layout" section explaining the public/private split and pointing to the per-tier reference deployments.
- [ ] Add a `nwp/sites/README.md` that is the only file remaining in `nwp/sites/` after cleanup, explaining the convention and pointing to `${HOME}/nwp-instances/`.
- [ ] Author the `tier-N.example.nwp.yml` templates at the repo root (referenced by [F32](F32-tiered-architecture-implementation.md) Phase B).
- [ ] In v1.0.0: remove the fallback to `nwp/sites/` from `find_instance_dir`; print a hard error if the old layout is detected.

**Definition of done:** A first-time contributor can read `CONTRIBUTING.md` and understand where per-site work belongs without seeing operator-specific examples.

## 6. Test plan

- **Pre-cutover snapshot:** record the SHA-256 hash of every file in `nwp/sites/<site>/` for a representative site; compare to `nwp-instances/<site>/` after migration to confirm verbatim copy.
- **Operation regression suite:** run `pl test`, `pl deploy --dry-run`, `pl backup`, `pl status` against the operator's existing site set; record outputs; replay against the migrated layout; diff outputs.
- **Cross-host check:** confirm `pl` works from at least two hosts after the cutover (the symlinks resolve correctly; the layout detection finds the right directory).
- **Stranger-clone test:** in CI, clone the public repo as a stranger, run `pl init --tier=1`, install a fresh site, deploy to a test VPS — confirm zero references to operator-specific content.
- **gitleaks scan** (per [P61](P61-leakage-hygiene-ci.md)) of the public repo after cleanup returns zero findings against the operator-specific ruleset.

## 7. Rollback plan

- **Phase 1 rollback:** delete the `nwp-instances` repo; no public-side change yet.
- **Phase 2 rollback:** keep `nwp-instances/` as a backup; resume operations from `nwp/sites/<name>/`.
- **Phase 3 rollback:** delete the symlinks; restore `nwp/sites/<name>/` content from git.
- **Phase 4 rollback:** revert `pl` to the previous dispatch; restore symlinks if needed.
- **Phase 5 rollback:** restore the deprecated path in `find_instance_dir`; release a patch.

The cutover is staged so each phase can be committed independently and verified before the next begins. The operator's deploy chain is never broken for more than the duration of a single `pl deploy` test cycle.

## 8. Open questions

- **OQ-1.** Should the private overlay use a single monorepo (`nwp-instances/<site>/`) or one repo per site (`nwp-instances-<site>/`)? Single monorepo is simpler for a sole maintainer; per-site repos scale better for multi-operator teams. Recommendation: monorepo for now; revisit if multi-operator teams emerge.
- **OQ-2.** Should `instance-manifest.yml` be encrypted at rest in the private overlay? The file binds role labels to hostnames; loss-of-confidentiality is low (the hostnames are internal). Recommendation: not encrypted by default; the operator may opt to encrypt via sops if their threat model warrants.
- **OQ-3.** What happens to tracked `nwp/sites/<site>/web/sites/default/files/` (Drupal user uploads) during the migration? These can be very large. Recommendation: handled separately by the existing backup pipeline; not part of the git-tracked cutover.

## 9. Phase status

| Phase | Status | Notes |
|---|---|---|
| 1 | Not started | — |
| 2 | Not started | — |
| 3 | Not started | — |
| 4 | Not started | — |
| 5 | Not started | — |

## 10. Related decisions and proposals

- [ADR-0021](../decisions/0021-public-only-repo-scope.md) — the architectural decision this proposal implements.
- [ADR-0020](../decisions/0020-tiered-architecture-model.md) — the tier model that depends on the public/private split.
- [F32](F32-tiered-architecture-implementation.md) — tiered architecture implementation; consumes the cleaner repo layout.
- [F34](F34-role-label-proposal-rewrite.md) — content of existing proposals; depends on this proposal having moved per-site content.
- [P61](P61-leakage-hygiene-ci.md) — leakage gate; must land first.

## 11. Supersession rationale (2026-05-22)

Audit of the actual tracked state in `~/nwp/` on 2026-05-22:

| Path | Tracked? | Ever in history? |
|---|---|---|
| `sites/*` | already gitignored | one per-site `docs/` subtree was tracked, removed in two cleanup commits |
| `nwp.yml` | already gitignored | never |
| `.secrets.yml` / `.secrets.data.yml` | already gitignored | never |
| `keys/prod_*` | already gitignored | never |
| `private/` | already gitignored | (likely never) |
| **`servers/<role>/`** | **41 files tracked** | yes, throughout |

So the public/private split goals (G1, G3) reduce to one concrete action: **extend the `sites/*` gitignore pattern to `servers/*`**. That happened in the same commit that flipped this proposal to SUPERSEDED.

What F33's full move-out *would* have bought that gitignore alone does not:

- Versioned private config (server YAMLs as their own git history)
- A backup pipeline for the private overlay
- Cross-machine sync of private config (overlay pulled to other operator hosts independently)
- A single `instance-manifest.yml` binding role labels to actual hosts
- `pl` layout-detection (`NWP_INSTANCES_DIR` / `find-instance-dir.sh`)

For a sole operator on one authoring host, none of those is load-bearing. If they later become load-bearing (multi-operator team, second authoring host, separate backup tier for private config) this proposal can be revived as a phased migration on top of the gitignore-only baseline.

**What still has to happen** for the public release that F33 was blocking:

- `git ls-files | xargs grep -l ...` finds ~99 tracked files containing internal hostnames or the live internal domain. Most are content references in docs/proposals — handled by **F34** (role-label rewrite).
- Force-push to the public remote still required — pre-2026-05-22 history contains `servers/<role>/` configs (including a wireguard config file) and the past per-site `docs/` commits, which gitignore cannot retroactively remove. The archive remote (Stream B Phase 1) preserves that history privately.
- F34 + P61 remain on the path.
