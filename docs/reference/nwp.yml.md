# `nwp.yml` v3 reference

**Schema source of truth:** [`lib/schema/nwp_yml_v3.json`](../../lib/schema/nwp_yml_v3.json)
**Authored:** F32 Phase A
**Decision:** [ADR-0020](../decisions/0020-tiered-architecture-model.md)

`nwp.yml` is the operator's per-instance configuration file. It is
**always private** (never committed to the public repo; lives in
`$HOME/nwp-instances/_global/nwp.yml` per F33). The public NWP repo
ships only `example.nwp.yml` templates per tier.

---

## 1. Three orthogonal mechanisms

A v3 `nwp.yml` composes three mechanisms:

1. **Roles per host** — every host declares the roles it carries
   (`authoring`, `ci-host`, `ai-host`, `verifier`, …). The vocabulary
   is fixed; see [`role-vocabulary.md`](role-vocabulary.md).
2. **Feature flags** — features (`ci`, `ai`, `deploy_mode`, `voice_agent`,
   …) can be enabled or disabled independently.
3. **Adapter selectors** — each enabled feature picks a backend
   (`gitlab-runner` vs `gh-actions` vs `docker-local` for CI, etc.).

A `tier:` preset (1–4) expands to coherent feature defaults; per-feature
overrides take precedence.

---

## 2. Minimal example (Tier 1, single laptop)

```yaml
nwp:
  version: 3
  tier: 1
  operator_alias: solo-blog
hosts:
  dev:
    local: true
    roles: [authoring]
features:
  ci:
    enabled: false
  ai:
    enabled: false
  deploy_mode:
    enabled: true
    backend: manual
```

---

## 3. Reference example (Tier 3, with role labels — never hostnames)

```yaml
nwp:
  version: 3
  tier: 3

hosts:
  dev:
    local: true
    roles: [authoring]
  ci-host-1:
    ssh: user@ci-host.tailnet
    roles: [ci-host, build-host]
  ai-host-1:
    ssh: user@ai-host.tailnet
    roles: [ai-host, voice-agent, rag-backend]

features:
  ci:
    enabled: true
    backend: gitlab-runner
    runner_host: ci-host-1

  ai:
    enabled: true
    backend: claude-api
    bridge_host: ai-host-1
    sandbox: systemd
    blast_radius: [dev, stg]

  voice_agent:
    enabled: true
    host: ai-host-1
    twilio_number_sid_env: TWILIO_VOICE_NUMBER_SID

  rag:
    enabled: true
    backend: sqlite-vec-fts5
    host: ai-host-1
    corpus_root: $HOME/nwp-corpus

  deploy_mode:
    enabled: true
    backend: ci-direct
```

---

## 4. Tier 4 (full reference; adds verifier)

Adds a `verifier` host with the offline signed-deploy role. The verifier
runs the separately-built `nwp-verifier` binary (per ADR-0022), not
`nwp` proper. The full Tier 4 example lives at
[`docs/deployment/reference-tier-4.md`](../deployment/reference-tier-4.md)
(authored in F32 Phase E).

---

## 5. Field reference

### `nwp.version` (integer, required)

Schema version. v3 only. Migrations from v2 are handled by
`lib/migrations/global/migrate_002_to_003.sh`.

### `nwp.tier` (integer, optional, 1–4)

Tier preset. Sets defaults for `features.*.enabled` and
`features.*.backend`. Per-feature settings override.

### `nwp.operator_alias` (string, optional)

Short label shown in `pl status` headers. Useful when running multiple
NWP instances side by side.

### `hosts.<name>` (object, optional)

Each host has at least a `roles:` list plus one of:

- `local: true` — this is the current machine.
- `ssh: <user>@<host>` — SSH target.

Roles must be drawn from
[`docs/reference/role-vocabulary.md`](role-vocabulary.md). The host
*name* in this map is the operator's internal label and should generally
be the role name (`ai-host-1`, `ci-host-2`) so that public proposals
referring to roles read naturally.

### `features.<name>` (object, optional)

Each feature has at least `enabled: <bool>`. Enabled features also pick a
`backend:` selector from
[`reference/feature-flags.md`](feature-flags.md). Feature-specific
sub-fields are documented in the adapter's reference page under
`lib/adapters/<feature>/<backend>/README.md`.

### `sites.<name>` (object, optional)

Cross-cutting per-site defaults. Per-site working config lives in
`$HOME/nwp-instances/<site>/nwp.yml` (per F33).

---

## 6. Migrating from v2

Run:

```bash
pl tier migrate-config
```

The migration script reads the current v2 `nwp.yml`, prompts for
role-label rebinding (one prompt per host), and writes a v3 backup of the
v2 file alongside. Round-trip:

```bash
pl tier migrate-config --dry-run     # show what would change
pl tier migrate-config               # apply
pl tier migrate-config --downgrade-to-v2   # rollback
```

---

## 7. Validation

```bash
pl tier validate-config
```

runs the schema validator (using `lib/schema/nwp_yml_v3.json`) against
the current `nwp.yml`. CI runs the same validator on every push.

---

## 8. Open questions

- **OQ-1.** Schema version naming: integer vs string. F32 §8 OQ-1
  decision: **integer** (operator's accepted default).
- **OQ-2.** First-run `pl init` Enter-key default tier. Per F32 §8 OQ-2:
  `--tier=1`.
- **OQ-3.** Adapter discovery via filesystem layout. Per F32 §8 OQ-3.

---

## 9. Related

- [ADR-0020 — Tiered architecture model](../decisions/0020-tiered-architecture-model.md)
- [F32 — Tiered architecture implementation](../proposals/F32-tiered-architecture-implementation.md)
- [F33 — Repository topology refactor](../proposals/F33-repository-topology-refactor.md)
- [`role-vocabulary.md`](role-vocabulary.md)
