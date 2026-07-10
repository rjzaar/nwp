# Overnight worklog — 2026-07-09 (unattended)

Operator asleep; pre-approved scope = all four streams, **merge policy = hold everything
as MRs for morning review** (merge nothing). Decision log per operator's standing request.

## Guardrails in force (given to every agent)
- No ddev/docker, no prod/live/`ver` network ops, no secrets (`.secrets.data.yml`, `keys/**`,
  `*.sql`, `settings.php`), no merges.
- Role name `ver` only — never bare host-names (the gitleaks gate blocks them).
- `bash -n` on every shell edit; changes additive + fail-closed; stop-and-TODO on any uncertainty.
- Each stream on its own branch, pushed for review. Sensitive paths (sanitizer, deploy, auth) are
  MR-only by policy regardless.

## Streams launched (background agents, isolated worktrees)
| # | Branch | Scope | Sensitivity |
|---|--------|-------|-------------|
| A | `ops-tooling-fixes-2026-07-09` | inverted `pl security` gate (reports vulnerable as green), empty-var `rm -rf` guards, `eval`-on-parsed-data RCE path, `coders.sh` recursion | dev/CI |
| B | `ops-doc-adr-hygiene-2026-07-09` | wire `pl doc-truth` into CI; draft ADR-0029/0030; correct ADR-0013/0014/0021 status; accept+index ADR-0027; proposal status pass | docs |
| C | `ops-sanitizer-failclosed-2026-07-09` | `pii-gate.sh` PIPESTATUS bug; `sanitize_staging_db` fail-closed + post-condition; add sanitize/PII-gate to prod2stg/live2stg | SECURITY — human review required |
| D | `ops-nwc-auth-substrate-2026-07-09` (nwc profile) or patches | GuildEligibility substrate; H1 legal-route anonymous fail-open; H2 stored-XSS | SECURITY — human review required |

## What I could NOT do (operator-only — waits for you)
Revoke the two admin PATs · enrol Solo W/W2 + phone · provision the `ver` box / LUKS-FIDO2 · anything
touching real prod. These remain the Tier-0 blockers.

## Results
_(assembled as each agent reports; MRs opened but not merged.)_

### A — `ops-tooling-fixes-2026-07-09` → **MR !52** (open, not merged) ✅
Commit `c27c528`, 9 files. gitleaks passed.
- **Inverted `pl security` gate FIXED** — `security.sh` now classifies clean / vulnerable / UNKNOWN; UNKNOWN returns non-zero (fail loud), never green. *Caveat: bash -n + logic review only; needs one live smoke test vs a known-vulnerable + known-clean site.*
- Empty-var `rm -rf` guards (`${var:?}` + non-empty floor not bypassable by `--force`) in `verify-runner.sh`, `delete.sh`, `live.sh` (remote `/var/www`). **`live.sh`/`delete.sh` are sensitive — review.**
- `eval`-on-parsed-remote-data removed (`server-scan` → `declare -g`, eval dropped at 8 call sites); verified a `$(touch canary)` site-name does not execute.
- `coders.sh` recursion fixed.
- TODO: `get_server_config` still `eval`'d in `import.sh:222,372` (parses local `nwp.yml`, lower risk) — left for a follow-up.

### B — `ops-doc-adr-hygiene-2026-07-09` → **MR !53** (open, not merged) ✅
Commit `80f3f09`, 14 files. gitleaks passed. Docs/CI only.
- Wired `pl doc-truth` → new `lint:doc-truth` CI job + `doc_truth` in `pl verify`; ships green via regenerated `.doc-truth-baseline`.
- New ADRs (Proposed): **0029** nwc authorization model, **0030** canonical+maturity axes + impact contract.
- Status fixes (banners only): 0013→Superseded-by-0030, 0014→Deprecated, 0021→Rejected; ADR-0027 accepted+indexed.
- Proposal pass: F30 dual-status removed, F25→Superseded-by-F29, F28 dep repointed, P70 amended-by-0027.
- **Operator TODO:** P71 has two pre-existing dead links (to still-untracked P68 + a cross-repo path) — baselined so the gate isn't red-on-arrival; fix links / commit P68 then `pl doc-truth --baseline`.

### C — `ops-sanitizer-failclosed-2026-07-09` → **MR !54** (open, not merged) ✅ 🔴 SECURITY
Commit `66ea9aa`. gitleaks passed. **Two-person review required (sanitizer = auth-code scrutiny).**
- **Finding correction:** the audit's "prod2stg/live2stg import raw PII" was measured on a STALE checkout — current `main` already has the P67 sanitize wiring. Real gap = the independent file-level `pii_gate_scan` backstop; built on existing wiring, not duplicated.
- `pii-gate.sh` PIPESTATUS fail-open fixed (truncated `.gz` scanned CLEAN) → upfront `gunzip -t`, returns 2. Fixture-tested (clean/PII/truncated = 0/1/2).
- `sanitize_staging_db`: schema-detect + refuse non-Drupal; post-condition assert (0 rows uid>1 with non-example mail); fixed `download_db_production` unconditional `return 0`.
- prod2stg/live2stg: independent post-sanitize `pii_gate_scan` + fixed 8 top-level `local` (fatal under `set -e`) + a `$STG_NAME` undefined var.
- **Review points (need live ddev/Drupal+Moodle):** ddev export gzip-format assumption; drush query output parsing; **admin uid=1 email NOT anonymized** (scope uid>1; `standard.sh` does uid>0 — decide); `--no-sanitize`/dev-canonical bypass by design.

### D — `ops-nwc-auth-substrate-2026-07-09` → **NOT pushed** (branch `17d64f5` in the nwc repo) 🔴 SECURITY
Committed to a local branch in the nwc profile repo (`sites/nwc/dev/html/profiles/custom/nwc`); **agent deliberately did NOT push** — judged an unattended push to the nwc repo could trigger CI/agent-loop side effects with no human watching. Patches also saved at `scratchpad/nwc-auth-patches/`. Shared nwc checkout untouched (still `unfork/open-social-13`). **No MR — you review + push.**
- **GuildEligibility** primitive (new, fail-closed trinary; wired to `GuildLocator`; no consumer yet → behaviour-neutral).
- **H1** legal fail-open→anonymous: `_permission: 'author legal documents'` floor on legal routes (granted to nobody by default) + anonymous-deny in `LegalGate::can()` and in `TransitionAuthorizer::decide()` for `legal`.
- **H2** stored-XSS: `LegalDocRenderer::toCleanHtml()` single choke-point → `Xss::filter` allowlist + `UrlHelper::stripDangerousProtocols`; no-op `stripInternalHtml()` removed; `Markup::create()` now wraps filtered output.
- Verified: `php -l` + YAML parse pass (php -l is the nwc CI's only PHP gate). Could NOT run Drupal/Behat.
- **Operator TODO (blocks H1 working on fresh install):** grant `author legal documents` to the seeded Copyright-adjacent role via `hook_install`/`config/optional` (sibling of audit M7) — agent left it granted to nobody (fail-closed) rather than guess. To push after review: `cd sites/nwc/dev/html/profiles/custom/nwc && git push -u origin ops-nwc-auth-substrate-2026-07-09`.

## Morning summary
4/4 streams done. **3 MRs open on nwp/nwp (!52 tooling, !53 docs, !54 sanitizer); 1 branch prepped in the nwc repo (D, unpushed).** Nothing merged. No prod/secrets/ddev touched. Review order suggestion: !52 (dev/CI safety, lowest risk) → !53 (docs) → then the two 🔴 security ones (!54 sanitizer, D nwc-auth) with a second set of eyes. Each has explicit "verify before trusting" notes above.
