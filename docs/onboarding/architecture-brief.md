# NWC Architecture Brief

**Audience:** Coder, reviewing PRs against the NWC codebase.
**Status:** v1 — written 2026-05-20.
**Read time:** 15 minutes.

This is the condensed architecture of NWC, scoped to what you need to recognize while reviewing PRs. The full architecture lives in `~/nwp/sites/nwc/dev/html/profiles/custom/nwc/docs/NWC-ARCHITECTURE.md`; this brief is the subset that matters for review work.

If you only remember three things:

1. **NWC = Drupal 10 + Open Social distribution + ~34 `nwc_*` modules.** Most PRs touch a `nwc_*` module; rare ones touch Open Social config or core. Treat the latter with suspicion.
2. **Editorial state is the spine.** Almost everything routes through the `editorial_revision` entity and the `EditorialStateService`. If a PR touches state transitions, it's at least T2.
3. **There are 4 live sites.** Code lives in two repos (`nwp/nwc` and `nwp-courses`). Always ask: "does this PR's change apply cleanly to *both* paired sites?"

---

## 1. The stack

```
Browser (member / steward / guest)
    │
    ▼
nginx — TLS + rate-limit + serves static, proxies to PHP-FPM
    │
    ▼
Drupal 10.4 + Open Social 12.x (distribution)
    │  + ~34 nwc_* modules in profiles/custom/nwc/modules/nwc_features/
    │  + MariaDB 10.11
    │  + Redis (cache + session)
    │  + Solr (search; optional, fallback to db search)
    ▼
GitLab self-hosted at git.nwpcode.org (CI + issues + MRs)
    │
    ▼
Moodle 4.4 at ssc.nwpcode.org / ssd.nwpcode.org (paired)
```

Key facts you'll see in diffs:

- **PHP 8.3.** Type hints, readonly props, enums are expected. Pre-8.3 syntax in a new file is a smell.
- **Drupal 10.4.x.** Symfony 6 underneath. `Drupal::service()` static calls in new code are a smell; prefer constructor injection.
- **DDEV** for local dev. PHPUnit + Behat run in the DDEV web container. CI runs the same containers.

---

## 2. Repo map (only what affects review)

| Repo                                             | What's in it                                                  | When you'll see PRs       |
|--------------------------------------------------|---------------------------------------------------------------|---------------------------|
| `nwp/nwc`                                        | The NWC install profile + 34 modules + Behat + PHPUnit suites | 80% of agent PRs land here |
| `nwp/nwc-project`                                | Composer wrapper, scaffolding, `auth.json` template           | Rare — dep bumps mostly   |
| `nwp/nwd-project`                                | Same, but the `nwd` (demo) deployment shell                   | Rare                      |
| `nwp/local-nwc-copyright-sync`                   | Moodle plugin: pushes NWC copyright policy → Moodle           | Cross-site PRs            |
| `nwp/auth-nwc-oauth2`                            | Moodle OAuth2 plugin: nwc Drupal → ssc Moodle SSO             | Auth changes              |
| `nwp/nwp`                                        | The overlay scripts (deploy, agent loop, etc.)                | Infra PRs, T3 only        |

All private. All under `git@git.nwpcode.org:nwp/<repo>.git`. See [repo-map.md](./repo-map.md) for the full breakdown including dev paths.

---

## 3. The custom-module landscape

Modules under `~/nwp/sites/nwc/dev/html/profiles/custom/nwc/modules/nwc_features/`. The naming prefix is `nwc_`. Group them this way:

### 3a. Editorial pipeline (the spine — most PRs touch one of these)

- **`nwc_editorial`** — the state machine; `EditorialArtifact` + `EditorialRevision` entities; `EditorialStateService`; trial feedback ingest.
- **`nwc_pedagogy_guild`** — pedagogy reviewer queue + claim service.
- **`nwc_theology_guild`** — theology reviewer queue + claim service.
- **`nwc_copyright_guild`** — copyright clearance recording + cross-site Moodle sync trigger.
- **`nwc_trialing_guild`** — trial feedback classification A1–E3 + halt/escalate/fold/revise routing.

If you see an "editorial" word in a PR description, it lives in one of these five.

### 3b. Governance + audit

- **`nwc_governance`** — the `governance_action` audit entity. Every state change writes here. **Removing a governance write is a regression** even if tests pass.
- **`nwc_decision_log`** — public-facing Decision Log; visibility tiers (Stewards / Members / Public) enforced by ADR-0010.

### 3c. Cross-site integration

- **`nwc_feedback`** — accepts feedback both from on-site widget and from Moodle (cross-site POST). Routes to GitLab issue; this is the input side of the loop.
- **`nwc_copyright`** — drives copyright policy text → Moodle `tool_policy` (via the `local-nwc-copyright-sync` Moodle plugin).
- **`nwc_oauth_bridge`** — auth handshake helpers (the actual OAuth server is `simple_oauth`; this is just the bridge config).

### 3d. UX / surface

- **`nwc_search`**, **`nwc_dashboard`**, **`nwc_profile`**, **`nwc_invitations`**, etc. — these mostly skin Open Social. PRs here are usually T1 or T2 and won't touch state.

Other modules exist; these are the ones that show up in 95% of review work.

---

## 4. The editorial pipeline (A30)

```
draft
  └─ in_writer_review
       └─ in_pedagogy_review     ─┐
            └─ in_theology_review ─┤  (skipped for typo template)
                 └─ in_safeguarding_review (skipped for typo template)
                      └─ in_copyright_clearance ── (gate: copyright_cleared = TRUE)
                           └─ approved
                                └─ in_trial         ─┐
                                     └─ trialed     ─┤ (skipped for hotfix)
                                          └─ in_production
```

Things to know for review:

- **State transitions are gated.** `EditorialStateService::advance($rev, $user)` enforces guards. New code that bypasses the service (writes `state` directly with `$rev->set('state', ...)`) is **always wrong**. Look for direct sets and reject.
- **Templates** are the skip-rules. `CHANGE_TYPO`, `CHANGE_DOCTRINAL`, `CHANGE_HOTFIX`, `CHANGE_PEDAGOGICAL` define which stages get skipped. New templates require a [T3 PR + ADR](./pr-review-checklist.md#6-special-checks-for-t3).
- **The copyright gate is real.** `recordCopyrightClearance()` must be called before advancing out of `in_copyright_clearance`, or the service throws `RuntimeException`. There's a kernel test that proves this; if a PR weakens this guard, demand a justification.
- **Trial feedback classes A1–E3** map to four outcomes:
  - `fold` (A1, A2, B1, B2): merge feedback into the revision silently
  - `revise` (B3, B4, C1–C3): kick back to writer
  - `halt` (B5, D1–D3): pause trial, raise to theology
  - `escalate` (D4, D5, E1–E3): pause trial, raise to stewards

Tests live at `nwc_editorial/tests/src/Kernel/StateMachineTest.php` (you can read it — it's the executable spec) and `nwc_editorial/tests/src/Behat/editorial_pipeline.feature`.

---

## 5. Authentication + access

- **OAuth2** via `simple_oauth` (contrib) — Drupal NWC is the issuer; Moodle SSC/SSD are clients. Token lifetime 1 hour. Refresh tokens 30 days.
- **Cross-site POST** (feedback ingest) uses a **shared secret** in the `X-NWC-Shared-Secret` header. Routes that accept cross-site traffic must set `_oauth_skip_auth: TRUE` or `simple_oauth`'s interceptor will 401 the request before it reaches the controller. **If you see a cross-site route without `_oauth_skip_auth`, request changes.**
- **Open Social visibility** uses `field_content_visibility`. Default must be `community` for NWC content. **A PR that changes the default to `public` is auto-T3 and needs Rob.**
- **Anonymous routes** are explicitly listed in `r4032login.settings.yml` (`match_noredirect_pages`). New anonymous routes added without adding them here will 302 to login — which usually breaks tests and the visible flow.

---

## 6. Cross-site dependencies you'll see in PRs

Three integration paths cross between Drupal NWC and Moodle SS:

- **OAuth SSO** — `nwc_oauth_bridge` + Moodle plugin `auth-nwc-oauth2`. Member logs into nwc Drupal, single-signs into ssc Moodle. Change to the bridge → change in both repos → **paired PRs**.
- **Copyright policy sync** — `nwc_copyright` + Moodle plugin `local-nwc-copyright-sync`. NWC writes the policy; Moodle plugin pulls it and writes `tool_policy_versions`. Schema-defensive — Moodle 4.4 changed where `name` lives.
- **Feedback bridge** — Moodle's own feedback widget → POST to `nwc.nwpcode.org/api/feedback/log` with shared secret. Routes through `CrossSiteFeedbackController`.

**If a PR claims to "fix the X bridge" but only touches one of the two repos, that's a smell** — confirm the other side is either already correct or has its own paired PR.

---

## 7. Where the agent typically goes wrong

Patterns I've seen go past CI but fail review:

- **Trying to skip the state machine.** Adding shortcut transitions ("draft → in_production" for hotfixes that aren't actually hotfixes). Look for any new `case` in `EditorialStateService::advance()`.
- **Adding a "convenience" service that wraps an existing service.** Three-layer indirection where one would do. Usually triggered by an issue saying "the X workflow is awkward" — agent invents a wrapper instead of fixing the underlying ergonomics.
- **Removing test guards as a fix.** A test fails → agent makes the test less strict. Always look at the test diff *first* on red→green PRs.
- **Adding `nwc_editorial` deps to modules outside the spine.** Tight coupling. If `nwc_dashboard` suddenly depends on `nwc_editorial.state`, ask why; it usually means the dashboard logic should live elsewhere.
- **Catching `EntityStorageException` and logging.** Almost always wrong — storage exceptions should propagate so the state machine can roll back the transaction.

---

## 8. Quick decision tree for unfamiliar PRs

```
Does the PR touch profiles/custom/nwc/modules/nwc_features/nwc_editorial/?
    YES → at least T2. Read the state-machine test diff.
    NO ↓

Does it touch profiles/custom/nwc/modules/nwc_features/nwc_governance/?
    YES → at least T2. Audit writes must not be removed.
    NO ↓

Does it touch routes (*.routing.yml) or services (*.services.yml)?
    YES → check auth + access guards explicitly.
    NO ↓

Does it touch nwc_copyright/, nwc_feedback/, nwc_oauth_bridge/, or auth-nwc-oauth2/?
    YES → cross-site impact; check both repos.
    NO ↓

Is it a template / CSS / docs / typo change?
    YES → T1. 2-minute review.
    NO → default T2.
```

---

## See also

- `~/nwp/sites/nwc/dev/html/profiles/custom/nwc/docs/NWC-ARCHITECTURE.md` — the unabridged version
- [pr-review-checklist.md](./pr-review-checklist.md) — what to actually do per PR
- [adrs.md](./adrs.md) — the architectural decisions referenced above
- [glossary.md](./glossary.md) — Sojourner, Steward, Guild, Trialing, etc.
