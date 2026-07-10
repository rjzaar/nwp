# Single semver scheme — nwc, profile, and Moodle plugins under one policy (ADR-0031 Phase B / ops#74)

> **Status: DESIGN + POLICY.** This document is the authoritative expansion of
> ADR-0031 **D3** (tagging policy). It defines the one versioning scheme every
> versioned unit on both stacks follows, how `release` (semver, == git tag)
> relates to Moodle's `$plugin->version` (a `YYYYMMDDXX` integer), and how the
> per-pair `contract_version` (ops#75 / ADR-0031 D2) sits above both.
> The *execution* (cutting the tags, moving the rollback anchors, creating GitLab
> releases) is the companion runbook,
> [`ops74-tag-release-runbook.md`](ops74-tag-release-runbook.md) — it happens on
> the build host / GitLab, which this planning branch cannot reach.
> **Date:** 2026-07-10. **Author:** AI (Phase-B planning session, read-only).
> **ADR:** [ADR-0031](../decisions/0031-paired-site-versioning-and-promotion.md) D3.
> **Depends on:** ops#73 (plugin repos reconciled before they can be tagged) —
> see `ops73-moodle-plugin-manifest-design.md` (lands on `main` with Phase A).

---

## 0. The problem this closes (verified state, 2026-07-10)

Read-only inventory of the actual repos this session:

| Repo | Tags on origin | composer/`release` says | Local-only clutter |
|---|---|---|---|
| `nwp/nwc` (profile, `git@<gitlab-host>:nwp/nwc.git`) | `v0.0.0-scaffold`, `v0.3.1`, `v0.4.0`, **`nwc/v1.0.0`, `nwc/v1.0.0-mvp`** | composer.json `version: 0.5.0` — **untagged** | **11 `pre-*` anchors** (none pushed) |
| `nwp/nwp` (tool) | `v0.30.0` | — | `pre-f26-2026-07-09`, `pre-f26-recs-2026-07-09`, `archive-pre-restart-v0.30.0`, `cleanup-backup-2026-07-10-local-main` |
| `nwp/local-nwc-copyright-sync` | (pushed once 2026-05-19 at `0.1.0`; drifted to `0.2.0` on ssc/ssd) | `$plugin->release 0.2.0` | none / no tags |
| `nwp/auth-nwc-oauth2` | (pushed once 2026-05-19) | `$plugin->release` 3-way disagreement (see ops#73) | no tags |
| `format_tabbed` (ss catalog) | — (no repo yet) | **`$plugin->release` line absent entirely** | — |

Three defects:

1. **Two competing schemes on `nwp/nwc`** (`v0.4.0` vs `nwc/v1.0.0`) and a
   composer version (`0.5.0`) that matches no tag — "what is 0.5.0?" is
   unanswerable.
2. **`pre-*` rollback anchors pollute `git tag -l`** on both `nwp/nwc` (11) and
   `nwp/nwp` (2) — release tags are drowned out by session rollback bookmarks.
3. **Moodle plugins carry `$plugin->release` strings with no tag behind them**
   (and `format_tabbed` has no `release` at all) — the string can drift silently.

Confirmed: **the 11 `nwc` `pre-*` anchors are local-only** (`git ls-remote --tags`
on origin returns only the five durable tags above). So "moving them out-of-band"
is a **purely local** operation — no force-push, no origin history rewrite.

---

## 1. The one scheme

> **Every independently versioned unit — the Drupal profile (`nwp/nwc`), the NWP
> tool (`nwp/nwp`), and each Moodle plugin repo — is versioned as `vX.Y.Z`
> semver, and its version string and its git tag may never diverge.**

Concretely:

| Unit | Semver source of truth | Tag | Bump trigger |
|---|---|---|---|
| `nwp/nwc` profile | `composer.json` `version` | `vX.Y.Z` (annotated) | any `composer.json` version change |
| `nwp/nwp` tool | `NWP_VERSION` in `pl` | `vX.Y.Z` (annotated) | release checklist (CLAUDE.md) |
| Moodle plugin (each repo) | `$plugin->release` in `version.php` | `vX.Y.Z` (annotated) | any `release` bump |

**Retired:** the `nwc/v*` scheme. `nwc/v1.0.0` and `nwc/v1.0.0-mvp` remain in
history as **frozen historical tags** (the un-fork era). No new `nwc/v*` tags are
ever cut. The single forward line is `v*` only.

**Invariant (CI-enforced, §4):** for every unit, the declared version has a
matching `vX.Y.Z` tag, and no `vX.Y.Z` tag exists without the declaration behind
it. `release: 0.2.0` ⇔ `tag: v0.2.0` (tag = `v` + release).

### 1.1 Why one scheme across two stacks (not one collapsed version)

ADR-0031 Option 1 (collapse the pair into a single version) is **rejected** —
Drupal and Moodle cannot share a package or deploy mechanism. What they *can*
share is the **grammar**: `vX.Y.Z`, tag==declaration, tag-at-every-bump. Each
unit keeps its own independent number line; the pair coupling lives one level up,
in the contract (§3). This is exactly ADR-0031's "version the contract, not the
pair."

---

## 2. `release` (semver) vs `version` (Moodle `YYYYMMDDXX`) — two keys, one plugin

Moodle plugins carry **two** version fields in `version.php`, and they answer
different questions. Both are kept; neither replaces the other:

| Field | Example | Whose key | Monotonic? | Human-facing? | Drives the git tag? |
|---|---|---|---|---|---|
| `$plugin->version` | `2026052000` | **Moodle core** (upgrade engine) | strictly increasing `YYYYMMDDXX` | no | no |
| `$plugin->release` | `"0.2.0"` | **NWP / this scheme** | semver | yes | **yes → `v0.2.0`** |

- `$plugin->version` is the **Moodle-native monotonic key**. Moodle's plugin
  upgrade machinery compares it as an integer to decide whether to run
  `upgrade.php` steps. It must only ever go up. It is *not* the release identity
  and is *not* what we tag.
- `$plugin->release` is the **NWP release identity**. It is the semver that
  matches the git tag and appears in the manifest, the lockfile, GitLab releases,
  and (eventually) the pair contract. This is the number a human reads to answer
  "which copyright-sync are ssc and ssd on?"

**Rule:** bump `version` on every schema/upgrade-relevant change (Moodle requires
it); bump `release` + cut the matching `vX.Y.Z` tag on every change you want to
be a nameable, pairable release. In practice they move together, but `version`
may tick without a `release` bump for a pure no-schema hotfix — **`release`
without a new tag is the failure mode CI must catch** (D3), not `version` moving.

`format_tabbed` today has `$plugin->version = 2026030900` and **no `release`
line** — that is the empty-release failure this scheme forbids. Phase B gives it
a real `release` (`0.1.0` → tag `v0.1.0`); see the runbook §4.

---

## 3. How the pair `contract_version` (ops#75) relates

The **pair contract** (`pair-contract.yml`, ADR-0031 D2, built in ops C / ops#75)
carries a single monotonically increasing **integer** `contract_version`. It is a
**third, independent** number line — *not* a semver, *not* derived from either
side's tag:

```
nwc profile:        v0.4.0   v0.5.0   v0.5.1   v0.6.0 ...   (Drupal semver)
copyright-sync:              v0.1.0   v0.2.0   ...           (Moodle-plugin semver)
auth_nwc_oauth2:                      v1.1.0   ...           (Moodle-plugin semver)
pair contract:      1        2                 3             (integer, bumps only on surface change)
```

- A `contract_version` bump records a **change to a coupling surface** (oauth-sso,
  copyright-sync, feedback-bridge) or a **data-rail invariant** (identity, policy,
  render id-stability). It says, e.g., *"contract 3: nwc ≥ 0.6.0 requires
  `auth_nwc_oauth2` ≥ 1.1.0."*
- **Most tag bumps do NOT bump the contract.** A patch release on either side that
  doesn't touch a coupling surface leaves `contract_version` untouched. The
  contract only moves when the *relationship* between the two versioned units
  changes.
- The contract references the **`release` semver tags**, never
  `$plugin->version`: it is a human/policy artifact, and `pair_guard` compares
  deployed `release` versions against the minimums the contract declares.
- **GitLab releases are cut at contract bumps** (D3 / §5) — so the GitLab UI can
  answer "what pairs with what" by reading release notes that name the
  counterpart minimums.

So the three number lines nest cleanly: `$plugin->version` (Moodle's internal
upgrade clock) < `release`/`vX.Y.Z` (per-unit human release identity) <
`contract_version` (the pair-coupling epoch). This scheme owns the middle line
and its relationship to the bottom; ops#75 owns the top.

---

## 4. CI checks (ADR-0031 D3 acceptance; fold nwc-side into ops#54's minimal CI)

Two consistency gates, both cheap and read-only. The local helper
`pl tag-hygiene` (§5) implements the profile/tool side of check A now; the plugin
side lands with the ops#73 installer/verify work on the build host.

**Check A — declared-version ↔ tag consistency (per repo).**
- `nwp/nwc`: `composer.json` `version` must have a matching `refs/tags/vX.Y.Z`.
  Fail an MR that changes `composer.json` version without the matching tag
  discipline (tag cut on the merge commit / release commit).
- `nwp/nwp`: `NWP_VERSION` in `pl` ↔ `vX.Y.Z` tag (already the CLAUDE.md release
  checklist; now mechanized).
- Plugin repos: `$plugin->release` ↔ `vX.Y.Z` tag; `$plugin->release` non-empty
  semver (the `format_tabbed` empty-release case). This is the same rule
  `verify_plugins.sh --release-tag` gains in ops#73 §5.4.

**Check B — no stray `pre-*` / rollback tags under `refs/tags` on any origin.**
`git tag -l 'v*'` must be a clean semver line; `git tag -l 'pre-*'` must be empty
on every origin. Rollback anchors live out-of-band (§ runbook 2 / D3).

**Equivalent-gate escape (D3 acceptance):** if wiring CI to *block a merge that
tags* is impractical on the self-hosted GitLab tier now, the documented
equivalent is: `pl tag-hygiene` runs in the pre-release checklist (CLAUDE.md) and
in the nightly audit, and fails on any untagged version bump or stray `pre-*`.
That satisfies "or a documented equivalent gate."

---

## 5. The local helper: `pl tag-hygiene`

A **read-only linter** (never mutates tags — it only *reports*). It answers the
two acceptance questions locally, on any repo it is pointed at:

- untagged version bump (composer.json / `$plugin->release` with no matching tag);
- stray `pre-*` / rollback anchors under `refs/tags`.

See [`../../scripts/commands/tag-hygiene.sh`](../../scripts/commands/tag-hygiene.sh)
and the runbook §6 for usage. It is **held as code for review** (Phase B ships it
but merges nothing). It is safe to run against real repos because it performs no
writes and no network calls.

---

## 6. Relationship to the Phase-A manifest/lockfile

This scheme is the versioning half; ops#73's manifest/lockfile is the deployment
half. They meet at `release`/`tag`:

- the **manifest** (`plugins/manifest.yaml`, schema v2) declares each plugin's
  `release` + `tag` + `repo` — the values this scheme governs;
- the **lockfile** (`<moodle-root>/.nwp-plugins.lock.yml`) records the `release` +
  `tag` actually installed — the concrete version `pair_guard` reads;
- `verify_plugins.sh` enforces Check A's plugin side (`release` ⇔ `tag`,
  non-empty semver) — the `format_tabbed` empty-release fails it until fixed.

Nothing here touches the security-critical Moodle sanitizer or `moodledata`
(ops D). The two `security_critical` plugins (`auth_nwc_oauth2`,
`local_nwc_copyright_sync`) get two-person review when their tags are cut
(CLAUDE.md sensitive paths).
</content>
</invoke>
