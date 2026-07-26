# NWP vs Vortex vs Pleasy — Deep Comparison Report

**Date:** 2026-07-23
**Method:** Four parallel research agents (Opus): full-code deep-dives of `/home/rob/nwp` (pl v0.30.0), `~/tmp/vortex` (DrevOps Vortex 1.40.2+, snapshot current as of today), `~/tmp/pleasy` (rjzaar/pleasy, 2018–2021), plus a codification audit of `~/.claude` (612 NWP session files + 51 memory files) measuring how much of NWP's operational reality is in versioned code vs Claude-session/memory lore. All claims below were verified against actual scripts, not docs.

---

## 1. Executive Summary

**NWP's dev↔stg↔live triangle is genuinely more sophisticated than either comparator** — layered fail-closed guards (canonical phase, maturity class, pair contract, INV-1, profile-change), default-on sanitization with an *independent second PII gate*, snapshot-before-destroy, ledgered overrides, and identity-preservation details (persistent hash_salt, oauth-keys exclusion, UID-lock/`--code-only`) that neither Vortex nor Pleasy has anything comparable to.

**The honest debts are asymmetric investment and codification gaps:**

1. **The prod leg is a generation behind the live leg.** `stg2prod`/`prod2stg`/`live2prod` are v1-era scripts (legacy flat config keys, no pre-deploy snapshot, no maintenance mode, failures demoted to warnings, `backup_production` skipped in `-y` mode). The strongest safety engineering currently protects the *test* tier.
2. **Config-as-code is not practiced** (sync dir gitignored, `cim` deliberately skipped on stg2live/stg2prod). Vortex demonstrates the industry-standard alternative: full config export in git + config_split per environment + config-drift detection in the provision. NWP's position is a *documented interim* (ops#63), but it means live/prod active config drifts invisibly.
3. **Sanitize-on-prod is only true on one path.** The threat-model claim "raw user data never leaves prod" holds for `nwp-server publish`; the everyday `live2stg`/`prod2stg` pulls move raw dumps to the workstation *before* sanitizing. (Vortex is worse — raw prod dumps transit CI and every dev machine by design — but NWP's own bar is higher.)
4. **~1/3 of operational reality lives in Claude memory, not code** — concentrated precisely in git-box disaster recovery (unversioned nginx vhosts, missing certbot deploy-hook, hand-applied SQL/PHP fixes, hand-typed remote crontabs, the daily-audit script existing only on met).

**Where each tool sits:** Pleasy is NWP's abandoned ancestor (same author, same `pl` verb CLI, recipes, stage prefixes, git-hash backup names) — energetic but with zero sanitization, admin/admin everywhere, plaintext creds, and live syntax bugs in core deploy paths. Vortex is a mature, exhaustively self-tested *project template* (297 Bats tests on its own tooling, 90% coverage gate in consumer CI, monthly releases for ~12 years) that delegates servers/backups/prod entirely to a managed host and trusts CI with prod write keys. NWP is the only one of the three that owns the full stack (servers, TLS, backups, DR, fleet) and the only one with an artifact-signing/hardware-gating story — at the cost of being a single-operator system with test coverage and prod-path polish still catching up to its own design.

---

## 2. Comparison Table

| Dimension | **NWP** (pl v0.30.0) | **Vortex** (DrevOps 1.40.2+) | **Pleasy** (2018–2021, abandoned) |
|---|---|---|---|
| **What it is** | Fleet hosting/deploy/infra automation CLI (Drupal + Moodle + GitLab + Castopod); owns servers end-to-end | Drupal project *template* + installer + tooling package; assumes managed hosting (Acquia/Lagoon) | Solo-dev Drupal (varbase) devops CLI; bare-metal LAMP + one remote server |
| **Stage model** | dev (DDEV) → stg (DDEV) → live (test server) → prod; per-site `canonical: dev\|live\|prod` phase + `maturity: incubating\|stabilizing\|production` axes, both guard-enforced in code | local → ci → dev → stage → prod; environments are *branch projections* on the host (feature branch = dev env, main = stage, production branch = prod) | dev → stg_ → server test → prod (name-prefix string surgery); local `prod/` backup mirror |
| **Promotion mechanism** | Explicit verbs: `dev2stg`, `stg2live`, `stg2prod`, `live2prod` (+ reverse pulls); rsync + guarded DB push | Git merges up a branch ladder; CI builds artifact, force-pushes to host repo / calls Lagoon API; tests gate deploy (`needs: [build, lint]`) | rsync dev→stg→server-test, then blue-green dir swap on server (`mv` prod ↔ test) |
| **CODE** | Per-site profile repos; `pl issue work` worktrees; whole-webroot rsync `--delete` under maintenance mode (live path); minisign artifacts, ed25519-sk Solo-touch deploy gate w/ manifest binding; `--code-only` mode w/ profile-change guard | Built in CI inside project containers (`composer --no-dev`, yarn in-image); SHA256-pinned `git-artifact` pushes built tree to host repo; deny-list `.gitignore.artifact` strips dev files | rsync excluding settings/files; deletes `composer.lock` before `composer install --no-dev` (non-reproducible); no artifact concept |
| **CONFIG** | `cex` on source; **no `cim` on stg2live by design**; `cim` fail-closed-skipped on stg2prod (`NWP_ALLOW_CONFIG_IMPORT=1`); sync dir **gitignored** — config-as-code not practiced (ops#63); settings.local.php *generated* per deploy w/ persistent hash_salt + operator-override include | **Full config in git** (`config/default`) + config_split per env (dev/stage/ci/local); provision runs `updatedb → cim → cim` + optional config-drift gate that fails if update hooks changed config; one env-var-driven settings.php, unit-tested | `drush cex` to `../cmi` + triple-`cim` retry; config_split dev flag; prod settings.php stashed in home dir, copied back after each swap; hash_salt from `md5sum $RANDOM` (~15 bits) |
| **CONTENT (DB)** | stg2live full-DB push (guarded: canonical/INV-1/pair); **stg2prod pushes no DB ever**; pulls (live2stg/prod2stg) default-sanitize + independent 2nd PII gate, fail-closed; but raw dump transits workstation first except on `nwp-server publish` (sanitize-on-prod, scratch-DB model) | **Strictly prod→down**; no upward DB path at all; 6 fetch backends; DB-in-image option; provision decision-matrix (preserve/import/profile-fallback); sanitize runs *after* import on destination — raw prod data reaches CI + dev machines | prod→stg via ssh dump + scp; **prod DB overwritten wholesale** by local DB in prodow flows; **no sanitization anywhere in live code**; raw prod DBs on dev laptop, optionally pushed to git repos |
| **CONTENT (files)** | Uploads excluded from *every* rsync both directions; captured only in backup tars; no routine sync (gap: no stage_file_proxy equivalent) | `stage_file_proxy` serves prod files on-demand in all non-prod; Lagoon persistent volumes; Acquia API copy tasks | rsync flows exclude files entirely; tar path carries them (with a latent quoting bug that breaks the excludes) |
| **USERS** | Pre-live password hardening (random admin pw + weak-pw scan); sanitize = random pw + anonymized mail; **UID-lock/`--code-only` D6 rule enforced in `lib/pair.sh`** (full-DB push severs OIDC SSO); shared-salt OIDC email hashing keeps Drupal↔Moodle join post-sanitize; hash_salt persistence keeps sessions/login links valid | `drush sql:sanitize` (random pw, patterned emails) + free-form `sanitize.sql` (blocks uid 1); admin blocked in prod, unblocked locally via `ahoy login`; identity never travels upward so no preservation problem exists | `admin/admin` on every install, never rotated; no user sanitization at all; `drush uli` run on prod |
| **BACKUPS** | `pl backup` (manifest.json w/ phase/commit/composer-sha), remote snapshots w/ **dual sha256 verify**, in-deploy `live_host_snapshot` (fail-closed, ledgered override), sweep + cron, archive-on-delete + typed-name purge; DR: box cron → LUKS sticks; restic w/ retention 7d/8w/12m + `check --read-data-subset`; **gaps: restore never verifies sidecars; no local retention/pruning (ops#37)** | Delegated to hosting; pre-deploy prod dump on Lagoon (no retention); manual `ahoy export-db`; S3 push building-block; no scheduler/retention/restore-verification in template | Timestamped `.sql` + `.tar.gz` pairs named w/ git hash (NWP inherited this); `select`-menu restore; server backups mirrored locally; **zero retention**; settings excluded from tars |
| **Sanitization location** | On prod (scratch-DB, `nwp-server publish` path) ✅ / on workstation post-pull (live2stg/prod2stg) ⚠️; failure aborts; independent 2nd PII gate re-scans export; Moodle local sanitize = fail-closed stub (ops#110) | On destination, *after* raw dump imported (local/CI/dev/stage); default-on, forced-off in prod; no sanitize-at-source mode | Nowhere (defunct `scripts/old/sandb.sh` reset admin pw to `admin` then pushed dump to git) |
| **Testing of itself** | 40+ bats files, `pl verify` 4k-line engine + S01–S10 scenarios, impact-contract CI (shrink-only allowlist — **but all deploy verbs still exempt**, ops#47 ~20% done); GitLab CI lint/test/security | **Best-in-class:** 297 Bats cases over 43 tooling scripts, 994 installer test files, whole-workflow functional suites, settings.php itself unit-tested (30 tests consumers inherit), consumer CI has 90% coverage hard gate, dual CI parity tested | None. `--help` exit codes encode CI status as README emojis; CI = smoke-install Drupal; `--BROKEN DOCUMENTATION--` blocks in generated README |
| **Secrets** | Two-tier (`.secrets.yml` AI-readable / `.secrets.data.yml` denied); registry-driven lifecycle (`pl secrets status/audit/rotate/consumers`); never-print discipline (0600 curl-config) | Committed non-secret `.env` + gitignored `.env.local` + CI secret stores; gitleaks in CI; BuildKit secret mounts | Plaintext prod password in `example.secrets.sh` (`pword='acutis'`); dbname=dbuser=dbpass convention; mysql root:root cnf; NOPASSWD `sudo rm` |
| **Provenance / trust** | Minisign artifacts + contracts; signed commits; hardware Solo-touch gate (2-step verify, hot-spare, fail-closed markers); AI-free `nwp-server` agent w/ deny-symbol scan; mons airgap topology | None beyond SHA-pinned helper binaries; CI holds prod-repo SSH write key (CI fully trusted); `StrictHostKeyChecking=no` in fetch paths | None; dev ssh key = prod root-equivalent (the exact model NWP's mons boundary was built to eliminate) |
| **Maturity** | Live triangle mature; **prod leg v1-era**; several doc-ahead-of-code items (v3 adapters, `recipes/` dir doesn't exist, signed-bundle route = refusal only, `--fresh-build` plan-only) | High; 12 years, monthly releases, active same-day commits; placeholders are deliberate fill-in points | Abandoned 2021; live syntax bugs in core deploy paths (`!==`, overwritten scp filename, dead-string ssh test); ~250 lines dead code after `exit 0` |

---

## 3. Verdict Per Question: "Is NWP doing the right thing?"

### 3.1 Setup / initialization
**Mostly yes, with doc-drift.** `pl install` recipe dispatch → typed installers is sound and broader than either comparator (4 platform types vs Vortex's Drupal-only, Pleasy's Drupal-only). But: `CLAUDE.md` documents a `recipes/` directory that **does not exist** (recipes live in `nwp.yml` + `sites/<recipe>/recipe.yml`), and the v3 `example.nwp.yml` tier/feature/adapter model references `lib/adapters/` which is unimplemented. Vortex's installer is a different league (994 test files, feature-block stripping, template *update* pulls) — but that's the payoff of being a template product, not a fleet tool. **Fix the doc drift; don't chase the installer.**

### 3.2 CODE across stages
**Yes — best of the three.** The stg2live path is the strongest deploy script examined across all three projects: fail-closed snapshot → maintenance ON → rsync → updatedb → cache → maintenance OFF, with profile-change guard, INV-1, ledgered overrides, and Moodle auto-delegation. The signing/hardware-gate chain has no equivalent in Vortex (CI trusted with prod keys) or Pleasy (dev key = prod root). **But** the deploy gate is off-by-default on unconfigured hosts (correct for A14 test tier), `server-apply.sh` still has no `deploy_gate_require` (the ops#79 ungated side door persists), and the DRY_RUN skip means mislabeled dry-runs bypass the gate.

### 3.3 CONFIG across stages
**Defensible interim, but the weakest dimension vs Vortex.** NWP's "no blind cim against a stale sync dir" stance is *correct given that no site tracks config as code* — importing a stale snapshot would revoke runtime-only config (simple_oauth grants). But the root cause is that the sync dir is gitignored. Vortex proves the target state works: config fully in git, config_split per env, and a provision-time drift gate that fails if updatedb mutated config. Until ops#63 lands, live/prod active config is invisible to version control and unrecoverable except via DB backups. **This is the single biggest architectural gap vs industry practice.** Where NWP is *ahead*: generated `settings.local.php` with verified-creds drift protection, persistent hash_salt (reuse → mint-once → fail-closed), and operator-override include — Vortex's env-var settings.php is cleaner but has a weak `sha256(DB host)` hash_salt fallback; Pleasy's is ~15 bits of entropy.

### 3.4 CONTENT across stages
**Direction discipline: yes. Sanitize location: partially.** NWP's asymmetry (guarded full-DB to live; *no* DB path to prod; sanitized pulls down) is more nuanced than Vortex's pure prod-down and vastly safer than Pleasy's prod-overwrite. The double sanitize+PII-gate is stronger than anything in Vortex (drush sanitize + example SQL) and infinitely stronger than Pleasy (nothing). Three real issues: **(a)** raw dumps transit the workstation on live2stg/prod2stg — extend the scratch-DB sanitize-on-source model from `server-publish` to the pull paths; **(b)** no intentional content-promotion mechanism to prod exists, and stg2prod's deploy-gate summary *misstates* that it pushes DB ("files + DB") when it never does; **(c)** stg2live's DB import doesn't drop existing tables first (stale-table residue). Also: no uploads story between stages — consider a stage_file_proxy-style solution (Vortex's is elegant and tiny).

### 3.5 USERS across stages
**Yes — this is NWP's most differentiated strength.** UID-lock enforcement in code (`lib/pair.sh` D6 + sub-shape guard), shared-salt OIDC email hashing so sanitized Drupal↔Moodle identities still join, hash_salt persistence preserving sessions across deploys, oauth-keys exclusion, pre-live password hardening. Neither comparator even has the *problem statement* (Vortex severs identity deliberately; Pleasy ships admin/admin). Residual: the weak-password scan is a fixed 7-password list; Moodle local sanitize is a fail-closed stub blocking the ssc/ssd pull workflow (ops#110 — safe, but unblock it).

### 3.6 BACKUPS
**Creation: excellent. Restore/retention: incomplete.** Manifested backups, dual-sha256 remote pulls, in-deploy snapshots, restic DR with retention + read-data checks — far beyond Vortex (delegates to host, no retention even for its pre-deploy dumps) and Pleasy (accumulate forever). But the loop isn't closed: **`restore.sh` never verifies the `.sha256` sidecars or manifests the backup side carefully writes**; local backups have no pruning (ops#37); `stg2prod`'s `backup_production` is a naive `cp -r` *skipped entirely in `-y` mode*. A backup system is only as good as its restore path.

### 3.7 Prod leg specifically
**No — this is the headline finding.** `stg2prod`/`prod2stg`/`live2prod` read legacy flat config keys, take no snapshot, use no maintenance mode, demote failures to warnings, and `prod2stg` mis-resolves v2 nested site layouts. The strongest safety engineering (everything in §3.2) protects the *test* tier while the tier that matters most runs v1-era code, relying on operator care + ver/mons topology for safety. This matches ops#79's "stg2prod v1-only" and should be the next major arc: **port the stg2live guard stack (snapshot, maintenance, INV-1, fail-loud, v2 config resolution) into the prod verbs.**

---

## 4. In-Code vs Claude-Ad-Hoc (the ~/.claude audit)

**Weighted judgment: roughly two-thirds code-backed, one-third memory/runbook-backed.** In the retained month of transcripts, `pl` tool-calls outnumber raw `gitlab_linode` SSH calls ~4.5:1, and `sudo -u www-data` in actual tool calls has collapsed to 4 occurrences.

### Codified (the system working as intended)
The strongest signal: scripts written explicitly to *retire* ad-hoc idioms, naming the idiom they kill —
- `pl moodle plugin deploy` (`scripts/commands/moodle.sh:6-10` — "RETIRES the unguarded hand-scp idiom")
- `pl drush` (`scripts/commands/drush.sh` — "raw ssh refused", routed through deploy gate)
- All six stage verbs + rollback + deploy gate; `pl secrets` lifecycle; box/stick backup scripts; GitLab install/upgrade/rollback; `pl server *`; agent-loop crontab.entry; audits (`pl audit`, `pl rag`, `pl todo`).

### Ad-hoc only (no corresponding script — DR risk concentrated here)
| Pattern | Evidence | Risk | Suggested fix |
|---|---|---|---|
| Server rebuild deltas (PHP 8.3, nginx sock edits ×5 vhosts, FPM group, Moodle cron, hand SQL fixes, `/tmp/*.php` fixtures) | `memory/server-rebuild-plan.md` — a full page of hand-applied changes | Restore-from-backup reproduces **none** of it | Runnable provisioning under `servers/nwpcode/` |
| Git-box nginx vhosts (ba, rosaryforge, dir, ss) | 0 hits for these in `servers/ scripts/ lib/` | Box rebuild loses all vhosts | Version under `servers/nwpcode/nginx/`, apply via `pl server-apply` |
| certbot renew deploy-hook for GitLab-bundled nginx | flagged *missing* in memory; no hook file in repo | **Silent cert-expiry outage** on every git-box vhost | 3-line hook, installed by setup script |
| `UPDATE {course} SET format='tabbed'` + other hand SQL | 17 `UPDATE mdl_` transcript hits; 0 in repo | Fleet Moodle settings unreproducible | `pl moodle` config verb |
| mons-log poll/close curl one-liners | `memory/mons-log-channel.md` says itself "consider `pl mons`" | Ops queue unreadable without memory file | `pl mons poll` / `pl mons close` |
| `nwp-daily-audit` script | lives only at `met:~/bin/` | met loss = audits vanish silently (state-change-only posting means silence looks normal) | Move into `scripts/`, deploy via `pl schedule` |
| Remote crontab installation (box 01:30, stick 03:15, audit 02:30) | 419 `crontab` transcript hits; only agent-loop has a versioned entry | Scripts survive a rebuild; their *scheduling* doesn't | `pl server-apply` owns remote crontabs |
| Non-NWP sites on the box (ba, rosaryforge, mayo) | memory only; outside `nwp.yml` | No backup/deploy/TLS story | Register in nwp.yml or declare out-of-fleet |
| mini host setup (ollama-health units, audio group) | `memory/mini-llm-baseline.md` | mini rebuild = hand-rediscovery | Populate thin `servers/mini/` |

### Load-bearing infrastructure living in ~/.claude (outside the repo)
- 12 hooks, ~690 lines, incl. `block-secret-write.sh` (**a security control**) — mostly versioned in `~/claudemax` but deployed by manual copy with unchecked drift
- `claude-conversation-monitor` daemon (the 7.3 GB-incident guard) running from `~/.claude`
- A background agent worker running `--permission-mode bypassPermissions` in the nwc_features module dir, state only in `~/.claude/jobs/`
- 51 memory files — the largest single store of operational truth outside git, including standing rules like `--code-only` for nwc

**Bottom line:** if Claude + memory + `~/central` vanished tomorrow, routine deploys would survive on `pl` alone; **a git-box rebuild would not.**

---

## 5. Prioritized Recommendations

**P0 — prod leg parity (the gap between NWP's design and NWP's code):**
1. Port the stg2live guard stack into `stg2prod`/`prod2stg`/`live2prod`: fail-closed snapshot, maintenance mode, v2 config resolution, fail-loud errors, real pre-deploy backup (not `cp -r`, never skipped by `-y`). Fix the deploy-gate summary that claims stg2prod pushes DB.
2. Gate `server-apply.sh` with `deploy_gate_require` (last ops#79 side door).

**P1 — close the DR gap (the ad-hoc third):**
3. Version git-box nginx vhosts + the certbot deploy-hook into `servers/nwpcode/nginx/`.
4. Convert `memory/server-rebuild-plan.md` into runnable provisioning; pull `nwp-daily-audit` off met into `scripts/`; make `pl server-apply` own remote crontabs.

**P2 — close the backup loop:**
5. Make `restore.sh` verify `.sha256` sidecars + manifest.json before overwrite.
6. Local backup retention/pruning (ops#37).

**P3 — config-as-code (ops#63), learning from Vortex:**
7. Track config in git per site, add config_split per env, and adopt Vortex's provision-time config-drift gate (`cex`-before/after-updatedb comparison). This is the one place Vortex's architecture is simply better.

**P4 — sanitize-at-source everywhere:**
8. Extend the scratch-DB sanitize-on-prod model from `server-publish` to the live2stg/prod2stg pull paths, so the threat-model claim holds on every path.
9. Author the ssc/ssd Moodle sanitizers to unblock the fail-closed stub (ops#110).

**P5 — smaller sharp edges:** drop-tables before stg2live DB import; deploy-verb impact-manifest conversion (ops#47); DB password out of ssh argv in `setup_live_database` (use the 0600 option-file pattern the sanitizers already use); uploads strategy (consider stage_file_proxy); reconcile CLAUDE.md's phantom `recipes/` directory.

---

## Appendix: Source Dossiers

Full per-tool dossiers (10-section framework: purpose, environments, code, config, content, users, backups, testing, security, maturity) were produced by the research agents and are summarized above. Key citations are inline; the NWP dossier's file:line references were verified against the working tree at `pl` v0.30.0.
