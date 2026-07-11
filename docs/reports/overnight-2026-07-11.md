# Overnight work report — 2026-07-11

Scope honoured: **security holes + pilot-readiness**, AI-safe only. **No credential
changes** (your tokens/keys are untouched — the loop still has the access you use for
live work). **Nothing deployed to prod** (mons boundary intact). **Nothing deployed to
live sites** unattended. Sensitive/consent-gated work was left as MRs or issues.

## Merged to main (done)
| MR | What | Why it mattered |
|----|------|-----------------|
| **!89** | Authored the missing `contracts/erasure.command.schema.json` + re-pinned (SHA256SUMS + pair contract) | The file was pinned but never committed → `validate.py` crashed and `pair_schema_verify` refused **every** paired nwc↔ssc promotion. Now green. **You must run `pl contracts sign`** to re-anchor the bundle signature. |
| **!90** | bats-wrapped the plain-PHP `uid_lock::decide()` + `erase_guard` logic tests into `tests/unit/` | The SSO identity core + erasure guards were runnable but ran in no CI. Highest-ROI test win (audit §5). Skips gracefully until php-cli is added. |
| **!92** | Member getting-started guide (`docs/guides/member-getting-started.md`) | Audit §4: no member-facing onboarding doc + no "locked out → contact" recourse existed. Has an operator note (set the support contact + confirm the defect route reaches a human before publishing). |

**Branch cleanup:** deleted 5 already-in-main local branches (`ops-79`, `ops-87`,
`ops-78-codium-setup`, `docs/onboarding-getting-started`, `feat/autolog-mapping-rebased`) + pruned.

## Opened for your review (NOT merged)
- **!91** — one-line `.gitlab-ci.yml` change adding `php-cli` to `test:unit` (activates the !90 tests). Sensitive path → needs a second reviewer.

## New issues filed (the tracked work-list)
- **#90** [P0-sec] depthcontent stored XSS (`<details>` raw re-insertion)
- **#91** [P0-sec] member feedback → armed agent-loop chain + pre-push denylist
- **#92** [P1] source↔live drift detector → `pl rag`
- **#93** [P1-test] ssc Moodle test suite + nwc→ssc e2e SSO
- **#94** [P1] content work-list: Gap Detector + adopt-from-draft form + AI-content import

## Findings that already have issues (no duplicate filed)
- Erasure deploy prereqs → **#81**; restore-gate identity → **#83**; **guild seeding (the content-pilot P0)** → **#55** (materialise Copyright/Writers/Pedagogy/Media/Shepherds; reconcile Stewards→Shepherds; ≥2 members/guild); editorial authorizer hardening → **#71**; avatars branch → **#86**; PAT downscope → **#49**; nwc profile CI → **#54**; content-workflow substrate → **#61/#64/#65/#66**.

## Two research docs delivered
- `docs/reports/nwc-ssc-audit-recommendations-2026-07-11.md` — per-finding recommendations + branch verdicts + sequenced plan.
- `docs/reports/nwc-ssc-readiness-guild-workflow-2026-07-11.md` — branch/erasure/S1-Half-B readiness + test-parity design + **the content-through-guild workflow** (the engine is ~85% already built; the work is seeding + a Gap Detector + import/export legs).

## What I deliberately did NOT do overnight (and why)
- **S4 XSS fix, S9 escape/autolock** — the correct fix needs a Moodle instance to test (PHPUnit bootstrap); merging+deploying an unrun refactor of a live module's rendering unattended is the wrong risk. Filed with the exact fix (#90). Bounded today anyway (not member-exploitable until content delegation).
- **S1 Half B, S12** — live in the gitignored nwc **profile** repo; deploying is operator-gated. Explained in the readiness doc §3; filed (#91).
- **ops#81 erasure live-deploy** — NOT READY: needs the schema *signed* (!89 authored it; signing is yours), ops#83 deployed, two-person review recorded, and R1 (the receiver reports success before the async delete runs) fixed. Details in readiness doc §2.
- **The 3 operator-decision branches + ops#24 sanitizer** — verdicts in readiness doc §1 (`nwptoolkit-deploy`: **block & escalate** — it already wrote a root systemd service to the forge box; `stg2live`: abandon + fix drush as a profile `require`; avatars #86: two-person WS-auth review; `mayo.allow`: human sanitizer sign-off).
- **Guild seeding / content import** — operator-gated (#55): importing AI atoms into an unseeded, single-operator rubber-stamp pipeline would march AI content to production under one signature. Must seed real guild members first.

## Suggested operator morning order
1. `pl contracts sign` (re-anchor the erasure bundle — 10 min) and review+merge **!91**.
2. Review the 3 branch verdicts (esp. **reconcile the live `nwptoolkit.service` on the box** — #34).
3. Decide the pilot go/no-go framing (readiness doc §4 recommends: small supervised cohort, member-intake OFF, after the P0s).
4. Green-light #91 Half A (AI-safe, I can do it next session) and schedule #55 guild seeding (the content-pilot gate).
