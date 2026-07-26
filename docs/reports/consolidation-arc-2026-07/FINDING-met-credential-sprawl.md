# FINDING — a complete, current credential set lives in an unmanaged backup tree on met

**Found:** 2026-07-27, while fixing the met daily-audit blindness (ops#49 / MR !196).
**Status:** reported, **not remediated** — deleting an operator's backups is their call.
**Severity:** the credentials are current, not historical.

## What is there

`met` (hostname `Carlo`, `rob@100.64.0.3`) holds `~/backups/carlo/` containing:

| | count |
|---|---|
| `auth.json` files carrying a composer registry token | **70** |
| complete `.secrets.yml` snapshots | **1** (`~/backups/carlo/nwp/.secrets.yml`, 5105 B, mode 600, 2026-07-19) |

Composer tokens across those 70 files, by sha256[:12] of the value:

| hash | copies | state |
|---|---|---|
| `0e2eb05a530a` | **31** | the pre-2026-07-27 composer token — **still live** (probes HTTP 200) until it is revoked |
| `e3b0c44298fc` | 23 | empty (sha of empty string) — no token |
| `6d87552aceb3` | 16 | long dead (HTTP 401) |

## The snapshot is not stale

Comparing the 2026-07-19 `.secrets.yml` on met against the live `.secrets.yml` on the workstation,
by hash of each value (values never printed):

| key | backup | current | same? |
|---|---|---|---|
| `gitlab.api_token` | `80f8c062da5c` | `80f8c062da5c` | **yes** |
| `gitlab.ops_note_token` | `ab52eeeca5cf` | `ab52eeeca5cf` | **yes** |
| `gitlab.mons_log_token` | `6204a78c9221` | `6204a78c9221` | **yes** |
| `gitlab.mini_alerts_token` | `9f5fc7ad9e93` | `9f5fc7ad9e93` | **yes** |
| `gitlab.met_audit_token` | `608aac992aea` | `608aac992aea` | **yes** |
| `linode.api_token` | `4007a16bfdcf` | `4007a16bfdcf` | **yes** |
| `gitlab.composer_registry_token` | `0e2eb05a530a` | `618f6e7b107a` | no — rotated 2026-07-27 |

**Six of seven are byte-identical to production.** This is not a historical artefact; it is a second,
undeclared copy of the current credential set.

## Why this matters beyond "a backup exists"

The two-tier secrets architecture works by every credential having a **declared** set of locations
(`stored_in` in `private/secrets-registry.yml`), so that a rotation reaches all of them and an audit
can check all of them. None of these 71 files is declared. Concretely:

- Tonight's rotation propagated to 49 declared locations. It did not touch these, because the
  registry does not know they exist. The estate looked 100% consistent while 31 copies of the
  superseded token sat on met.
- `pl secrets audit` cannot see them, so they can never be reported as drifted or dead.
- The `pl secrets discover-copies` verb proposed in the fix programme — grep the tree for
  registry-known token shapes and report undeclared holders — is exactly the control that would
  have surfaced this. It is specified but **not implemented**.

## This cleanup was done once already, and missed a host

Session memory records ~291 secret copies under `~/backups/carlo/` on **mini**, including 17 real
`.secrets.yml` files, all shredded. `met` carries the same tree and the same pattern, and was not
cleaned. A remediation that fixes one host of a pair and is recorded as done is its own instance of
the pattern this arc keeps finding.

## Recommended, in order

1. **Revoke the old composer token.** Independently safe (all 49 declared locations plus met's two
   live `auth.json` files now carry the new one, hash- and probe-verified) and it neutralises 31 of
   the 70 files in one action.
2. **Decide the fate of `~/backups/carlo/nwp/.secrets.yml`.** If the backup is still wanted, it
   should hold no credentials; if the credentials are wanted, the file belongs in the registry as a
   declared location so rotations reach it. The status quo — undeclared and current — is the only
   option with no upside. Operator's call; do not shred someone's backups autonomously.
3. **Implement `pl secrets discover-copies`** so the next undeclared copy announces itself rather
   than waiting to be stumbled over during unrelated work.
4. **Re-run the mini cleanup against met**, and check any other host with a `~/backups/` tree.

## What was changed on met (and what was not)

Changed: `~/nwp/sites/nwc/dev/auth.json` and `~/nwp/sites/mayo/dev/auth.json` were updated from a
fourth, dead token value (`803f515644d6`, `Invalid credentials`) to the current canonical
(`618f6e7b107a`), verified by probe from met (HTTP 200) *before* writing, with `.pre-2026-07-27.bak`
copies alongside. This un-blinded the `composer outdated` axis of the nightly audit (`RC=0`, real
JSON returned) — it had been failing on dead credentials independently of the stopped-container
problem.

Not changed: nothing under `~/backups/carlo/` was read for its values, modified, or deleted.
