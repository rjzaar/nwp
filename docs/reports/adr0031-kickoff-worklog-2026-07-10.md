# NWP-ADR-0031 kickoff worklog — 2026-07-10 (evening, unattended)

Operator ~1h from bed; **merge policy = hold everything as MRs/plans for review** (merge nothing).

## The plan (from NWP-ADR-0031 line 302 dependency map)
`A → B → C` sequential; `D` independent of A–C but blocks real ssc/ssd parity; **C's auth half gated by the F26 issuer reconcile.** So the first moves that unblock everything, launched now in parallel:

| Agent | Scope | Output | Sensitivity |
|---|---|---|---|
| **F26 issuer reconcile** | spec: avc→nwc issuer (F26 signed off, but audit A4/M1 flagged the stale spec); + a code change-list for nwp!49 | branch `ops-f26-issuer-reconcile-2026-07-10` (push, no MR) + change-list | 🔴 auth — MR-only, two-person review |
| **Phase A plan** (ops#73) | Moodle repo hygiene: manifest/installer/lockfile design + operator runbook (Moodle repos live on the build host, not here → design+plan, not code MR) | branch `ops-73-phase-a-plan-2026-07-10` (push, no MR) | build-host/plan work |

## Guardrails given to both
No ddev/docker; **no writes to any live Moodle site (ss/ssc/ssd) or server** (read-only); no secrets; no merges; `ver` role-vocab (gitleaks); `bash -n`; stop-and-TODO on any auth uncertainty.

## Deliberately NOT started tonight
- **B, C** — sequential, wait for A + your review.
- **D (Moodle sanitizer for minors' consent/learning records)** — the most safeguarding-sensitive code in the project; **human-authored/heavily-reviewed, adversarially verified, synthetic data only** — not delegated to an unattended agent.

## Operator decisions (2026-07-10, before bed)
Build **A→B→C + draft D plumbing**. Auto-merge **design/plan docs + trivial only**; hold all code as MRs.
**F26 = hold for review.** **D = draft plumbing only, never the sanitizer** (operator: *no minors involved*,
but sanitizer stays human-review per CLAUDE.md → fail-closed stub).

## Results
### A — `ops-73-phase-a-plan` → **MR !59 MERGED** ✅ (docs-only, per policy)
Manifest/lockfile design + reconcile runbook. Drift found: copyright_sync 0.2.0-vs-0.1.0 (consent rail),
`auth_nwc_oauth2` 3-way version disagreement (F26-gated), `format_tabbed` empty release, `ssc`/`ssc1`
naming mismatch. Operator TODOs A1–A8 in the runbook.

### F26 reconcile — `ops-f26-issuer-reconcile` → **MR !60 OPEN (held, auth)** 🔴
Spec reconciled avc→nwc throughout. **Key finding: nwp!49 code is already nwc-branded** — issuer
merge-gate satisfied; only the auth-graph signoff remains. **M1 carry-forward** (two-person, *separate
nwc-profile repo*): the UserInfoController fix on `feat/f26-drop-custom-userinfo` must land in lockstep
or M1 reopens; mirror the `simple_oauth_21` GitHub composer pin before non-dev use.

### D-plumbing — `ops-76-phase-d-plumbing` → **MR !61 OPEN (held, code)** 🔴
Type-dispatch in `sanitize_staging_db` (config-driven + schema-probe fallback, off unless Moodle target;
Drupal path preserved byte-for-byte as `_sanitize_staging_db_drupal`). New `lib/sanitizers/moodle.sh` =
**fail-closed stub** (refuses, writes no output) + the interface spec (plane-5b table inventory,
`config.php` creds, configurable prefix, oidc-email shared rule, post-condition contract). **13/13 bats
pass**, no ddev. gitleaks clean. Operator TODO: author `moodle_sanitize()` (security-critical); wire
`moodledata`; rest of D8 substrate (settings-writer/vhost/wwwroot/Moodle-smoke) still open.

### B — `ops-74-phase-b` → **MR !62 OPEN (held, mixed docs+code)**
Single-semver scheme doc + tag/release runbook (the `refs/rollback/` scheme pulls all 11 nwc + 2 nwp
`pre-*` anchors out of `git tag -l` entirely) + `scripts/commands/tag-hygiene.sh` (read-only linter:
untagged-version / empty-release / stray-tag; never mutates/pushes; tested vs the real repos). Held
because it carries the helper (code). gitleaks + bash -n + doc-truth pass; **no real tags cut.** Operator
TODOs B1–B8 (all build-host/GitLab/credentialed; needs ops#73 reconcile before plugin repos tag).

### C — `ops-75-phase-c` → **MR !63 OPEN (held, code)** 🔴 (the core)
Versioned pair contract (schema + `pair-contract.example.yml` + `pairs/`) · **`lib/pair.sh` `pair_guard`**
wired into stg2live/stg2prod/live2prod (provider-first ordering on `contract_version` bump; D6 full-DB→
`--code-only` on identity-coupled provider+consumer; red-pair block; ledgered `--override-pair`) ·
`pl pair-smoke` (dry-run/no-network by default, refuses prod) · `pl pair list/show/status/check/record/rag`
· pairing config in **example.nwp.yml** (nwp.yml untouched). **Off-unless-configured: verified vs the real
fleet (0 `paired_with`) → zero behaviour change**; fail-closed on declared-but-unverifiable; all decision
paths fixture-tested. Auth/OAuth half **stubbed (config-only) pending F26**. bash -n all pass; gitleaks
clean; no `sites/tmp/`. TODOs: `--code-only` fully live only on stg2live today (stg2prod/live2prod
fail-closed-refuse the coupled full-DB push); ssc/ssc1 registration (A5); auth (F26); Moodle substrate (D).

---

## Morning summary (all agents done)
| Phase | MR | State | Notes |
|---|---|---|---|
| A (repo hygiene design) | **!59** | ✅ merged | docs-only, per policy |
| F26 issuer reconcile | **!60** | held (auth) | nwp!49 code already nwc-branded; **M1 fix is in the nwc-profile repo `feat/f26-drop-custom-userinfo` — review in lockstep** |
| B (tag/release) | **!62** | held | docs + `pl tag-hygiene` linter; `refs/rollback/` cleanup; no real tags cut |
| C (pair contract + guard) | **!63** | held | fleet-safe (off-unless-configured), fail-closed; auth stubbed |
| D (Moodle dispatch plumbing) | **!61** | held | fail-closed sanitizer STUB (no anonymisation), 13/13 bats |

> **UPDATE 2026-07-10 — operator reviewed + merged all four (F26 !60 · C !63 · D !61 · B !62).** Merged
> onto `main` in that order, no conflict with ops#78. Post-merge: all deploy/sanitize/pair files `bash -n`
> clean; fleet still off-by-default (0 `paired_with`, dispatch defaults Drupal) → **zero behaviour change**.
> Remaining = operator/future work (not blockers): see "Remaining" below.

**Nothing touched:** live sites, secrets, the Moodle sanitizer logic, ops#78's `ops-78-codium-setup`.
**Suggested review order:** F26 (!60, unblocks C's auth) → C (!63, the core) → D (!61) → B (!62). Each
carries its operator-TODO list for the build-host/GitLab steps I can't reach.
**Sequencing reminder:** B's plugin tags need the ops#73 (Phase A) drift reconcile done on the build host
first; C's auth half needs F26 merged.
