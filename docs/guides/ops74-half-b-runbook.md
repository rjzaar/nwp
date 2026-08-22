# ops#74 "Half-B" plugin-release runbook — auth_nwc, format_tabbed, copyright_sync

> **Status: PREP COMPLETE — READY TO RUN on the build host once the operator confirms.**
> This runbook cuts three specific Moodle-plugin releases under NWP-ADR-0031 D3
> (tag = `v` + `$plugin->release`; `$plugin->version` = `YYYYMMDDXX` is never
> tagged). Every reviewable change has been **staged on a branch — NO real tags
> were cut, NO branches merged, NO live site was written.** The AI-run workstation
> deliberately does not tag/push releases or write to prod (threat model).
> **Date:** 2026-07-11.
> **Companion / rationale:** [`ops74-tag-release-runbook.md`](ops74-tag-release-runbook.md),
> [`ops74-versioning-scheme.md`](ops74-versioning-scheme.md).
> **Decisions:** scratchpad `sanitizer-decisions/D-tag-versions.md` (tag/version calls),
> `sanitizer-decisions/E-copyright-sync-course.md` (copyright fix-forward), memory
> `f26-auth-plugin-reconcile.md` (auth_nwc is the real F26 consumer).
> **ADR:** [NWP-ADR-0031](../decisions/0031-paired-site-versioning-and-promotion.md) D3/D4.

---

## 0. What must be true before starting

- [ ] **Build-host is authoritative.** Re-verify every version/tag below on the build
      host — the plugin working copies on the dev workstation are
      gitignored copies; the GitLab plugin repos are the source of truth.
- [ ] **Operator holds the credentialed GitLab push key.** All `git tag`/`git push`/
      release-create/repo-create steps are OPERATOR-run. The AI-run host cuts nothing.
- [ ] **copyright_sync ONLY:** the mandated **2-person consent-rail review (§4)** has
      passed and is recorded. This gates the `v0.2.1` tag — it is a consent/legal rail
      (CLAUDE.md sensitive path; plane 5b, minors' records). Do not tag before sign-off.
- [ ] **auth_nwc ONLY:** F26 two-person auth review (`nwp/nwp!49` line) — the code is
      merged + live-proven, but the release cut still wants the sensitive-path sign-off
      recorded (CLAUDE.md `lib/auth*`). memory `f26-auth-plugin-reconcile.md` records the
      live end-to-end proof (demo_writer → ssc SSO, UID-lock held).
- [ ] `pl tag-hygiene` understood: an **untagged-version** finding on a plugin is
      EXPECTED until its tag is cut; it clears the moment `git tag v<release>` lands
      (proven below). **empty-release** is the failure this runbook removes for
      format_tabbed.

## Order of operations

1. **format_tabbed** `v0.1.0` — no dependents, lowest risk. Needs a home repo first (§2).
2. **auth_nwc** `v1.0.0` — needs its OWN new repo `nwp/auth-nwc` (§3). Gated on F26 sign-off.
3. **copyright_sync** `v0.2.1` — **gated on the §4 2-person consent-rail review.** Do last.
4. Bump `pairs/ssc.pair-contract.yml` consumer_min to match (already staged, §5).
5. Cut GitLab releases + re-run `pl tag-hygiene` clean (§6).

## Branches pushed by this prep (all for review — none merged, none tagged)

| Branch | Repo | Contents |
|---|---|---|
| `ops-auth-nwc-v1` | `nwp/nwp` | auth_nwc `version.php` → `2026071101 / 1.0.0 / MATURITY_STABLE`; `pairs/ssc.pair-contract.yml` copyright_sync `consumer_min 0.2.0→0.2.1`; **this runbook** |
| `ops85-copyright-0.2.1` | `nwp/local-nwc-copyright-sync` | fix-forward to `2026070301 / 0.2.1`: native `tool_policy` API + idempotency guard restored, `beta_cc0` restored. **Consent rail — needs the §4 review before merge/tag.** |

format_tabbed's `version.php` addition was **prepped in place** in the gitignored ss
working copy (`sites/ss/dev/course/format/tabbed/version.php`) — it has no repo yet, so
there is no branch (see §2).

---

## 1. Snapshot — verified state (build host must re-confirm)

| Plugin | Lives in | `version` (int) | `release` | `maturity` | Own repo? | Tagged? |
|---|---|---|---|---|---|---|
| `format_tabbed` | ss site tree `course/format/tabbed/` (gitignored) | `2026030900` | *(was absent)* | *(was absent)* | **no** | no |
| `auth_nwc` | `nwp/nwp` `scripts/f26/moodle/auth_nwc/` (merged) | `2026071100` | `0.1.0-f26` | `MATURITY_ALPHA` | **no** | no |
| `local_nwc_copyright_sync` | `nwp/local-nwc-copyright-sync` (HEAD=main) | `2026052000` | `0.2.0` | `MATURITY_STABLE` | yes | no |

- `nwp/auth-nwc-oauth2` (`auth_nwc_oauth2`, `1.1.0`) is the **lock-less decoy** — it is
  a byte-for-byte avc→nwc rename with a dead guild stub and **no UID-lock**. It is NOT
  auth_nwc. **Do not reuse this repo, do not tag it.** Retire/archive it (§3.4).

---

## 2. `format_tabbed` → `v0.1.0`  *(OPERATOR; needs a home repo)*

**Decision (D-tag-versions §a):** `release = '0.1.0'` (house/semver consistency — every
sibling in-house catalog plugin is `0.1.x`; `1.0.0` would over-claim a stable public
API a course format doesn't publish) and `maturity = MATURITY_STABLE` (it is the live
production format on ss with no known issues — the two axes are independent).

### 2.1 version.php state
Before (root `course/format/tabbed/version.php`):
```php
$plugin->version   = 2026030900;
$plugin->requires  = 2024041600;
$plugin->component = 'format_tabbed';
```
After (already prepped in the ss working copy; `php -l` clean):
```php
$plugin->version   = 2026030900;          // unchanged — no code change, no upgrade trigger
$plugin->requires  = 2024041600;
$plugin->component = 'format_tabbed';
$plugin->release   = '0.1.0';
$plugin->maturity  = MATURITY_STABLE;
```

### 2.2 Tag/deploy mechanism — it has NO repo (the open decision)
format_tabbed lives only inside the ss site tree (gitignored working copies), so there
is **nothing to tag today**. Pick a home before tagging:

- **Recommended:** vendor it under the `courses-plugins` source_repo (ops#73 §A6) — the
  same home the other catalog plugins get — OR create a dedicated `nwp/format-tabbed`
  repo, seed it from `sites/ss/dev/course/format/tabbed/`, then:
  ```bash
  cd <format_tabbed repo clone>
  grep -E 'release|maturity' version.php     # expect 0.1.0 / MATURITY_STABLE
  git tag -a v0.1.0 -m "format_tabbed 0.1.0 (== \$plugin->release; NWP-ADR-0031 D3)"
  git push origin v0.1.0
  ```
- **Deploy to the box** stays the current manual path (memory: scp to `/tmp` → `sudo cp`
  into `/var/www/ss/course/format/tabbed/` → `sudo -u www-data php admin/cli/purge_caches.php`).
  Because `$plugin->version` is unchanged, this deploy is metadata-only — Moodle runs no
  upgrade. Once the plugin has a repo, fold it into the signed-bundle deploy path so the
  box gets the tagged artifact, not a hand-copied tree.

---

## 3. `auth_nwc` → `v1.0.0`  *(OPERATOR; needs a NEW repo `nwp/auth-nwc`)*

**Decision:** auth_nwc has earned `MATURITY_STABLE` + `1.0.0` — it is merged into
`nwp/nwp` main, and proven **live end-to-end on ssc** (demo_writer → ssc SSO, Moodle
user created with `idnumber == nwc sub`, UID-lock held, B1 observer fired — memory
`f26-auth-plugin-reconcile.md`). The staged bump is `2026071101 / '1.0.0' /
MATURITY_STABLE` (branch `ops-auth-nwc-v1`; `php -l` clean).

### 3.1 version.php state (staged on `ops-auth-nwc-v1`)
```php
# before                                   # after
$plugin->version   = 2026071100;           $plugin->version   = 2026071101;
$plugin->maturity  = MATURITY_ALPHA;       $plugin->maturity  = MATURITY_STABLE;
$plugin->release   = '0.1.0-f26';          $plugin->release   = '1.0.0';
```

### 3.2 RECOMMENDATION — own repo, NOT tagged in place
**auth_nwc MUST get its own repo `nwp/auth-nwc`; it cannot be tagged in place.**
Reasons:
- `nwp/nwp` is the NWP tool and carries its own release line (currently `v0.30.0`). A
  `v1.0.0` tag on `nwp/nwp` would collide with / corrupt the tool's own versioning — the
  D3 scheme requires the plugin's tag to equal `v` + its `$plugin->release`, and that tag
  can only live on a repo whose release line IS the plugin's.
- NWP-ADR-0031 D4: the plugin is the versioned unit on the Moodle side. It needs to be the
  root of its own repo (root `version.php`) so `pl tag-hygiene` and the signed-bundle
  path treat it as a unit.
- `nwp/auth-nwc-oauth2` is the **decoy** (different component `auth_nwc_oauth2`, no
  UID-lock, wrong git history) — creating `nwp/auth-nwc` fresh keeps the real plugin's
  provenance clean.

### 3.3 Steps (OPERATOR, after F26 sign-off recorded)
```bash
# 1. Create the repo (operator's GitLab session): nwp/auth-nwc  (blank, default main).
# 2. Seed it from the merged, reviewed tree:
git clone git@<gitlab-host>:nwp/auth-nwc.git && cd auth-nwc
cp -a <nwp/nwp checkout>/scripts/f26/moodle/auth_nwc/. .   # version.php at repo ROOT
grep -E 'release|maturity|version' version.php             # 1.0.0 / STABLE / 2026071101
git add -A && git commit -m "auth_nwc 1.0.0 — F26 OIDC consumer (merged + live-proven on ssc)"
git push origin main
# 3. Tag == v + release:
git tag -a v1.0.0 -m "auth_nwc 1.0.0 (== \$plugin->release; NWP-ADR-0031 D3; F26 UID-lock consumer)"
git push origin v1.0.0
```
Keep `scripts/f26/moodle/auth_nwc/` in `nwp/nwp` as the build-source until the repo is
the canonical home, then reconcile to a single source (avoid a two-copy drift like the
one the copyright plugin hit — E-copyright-sync-course §chronology).

### 3.4 Retire the decoy
`nwp/auth-nwc-oauth2` and the sibling `auth_avc_oauth2` working copies are lock-less and
superseded. Archive `nwp/auth-nwc-oauth2` (rename → `-archive` or set to read-only);
do not cut any tag on it. The pair contract already names the real consumer `auth_nwc`.

### 3.5 Deploy to live ssc
Already done manually and proven (memory). Codify the exact issuer/client/observer wiring
into `pl moodle-promote` (commit `4aa5908` began this). Box gotcha: admin CLI must use
**php8.2/8.3** (default CLI php 8.4 is rejected by Moodle 4.4), with `-d max_input_vars=5000`.

---

## 4. `local_nwc_copyright_sync` → `v0.2.1`  *(OPERATOR; 2-person consent-rail review is the gate)*

**Decision (E-copyright-sync-course):** do NOT mechanically adopt `0.2.0` — the version
numbers are inverted vs. correctness (the good code carried the *lower* number). The
`0.2.0` on repo HEAD is the raw-`$DB` regression: it force-re-consents on every sync
(ops#31 hazard) and silently 400s `beta_cc0`. **Fix-forward to `0.2.1`** (option ii):
keep the `0.2.0` rename `db/upgrade.php`, port back the native-API + idempotency guard +
`beta_cc0`. This is **staged on `ops85-copyright-0.2.1`** (the ops#85 diff applied clean
to repo HEAD with `-p3`; `php -l` clean on all 3 files; gitleaks clean).

### 4.1 version.php state (staged)
```php
# before (repo HEAD, the regression)       # after (branch ops85-copyright-0.2.1)
$plugin->version = 2026052000;             $plugin->version = 2026070301;
$plugin->release = '0.2.0';                $plugin->release = '0.2.1';
```
Also on the branch: `classes/policy_writer.php` reverts raw `$DB` →
`api::form_policydoc_add/update_new/make_current` **with** the byte-identical idempotency
guard; `policy_set.php` restores `beta_cc0` to `$allowed_policy_names` + type map;
`db/upgrade.php` avc→nwc rename migration untouched. Provider side needs NO change.

### 4.2 Mandated 2-person consent-rail review (BLOCKS the tag) — from E-copyright-sync
- [ ] `publish()` guard compares **name + revision + content** and returns
      `action:'unchanged'` (no `make_current`) when equal — verify byte-for-byte.
- [ ] Every publish path routes through `api::make_current`, never raw
      `set_field('currentversionid')`.
- [ ] `beta_cc0` present in **both** `$allowed_policy_names` and `$policy_type_map`;
      a live sync of the CC0 doc returns 200 (not 400).
- [ ] `version.php` int strictly `> 2026052000` (it is `2026070301`); rename savepoint preserved.
- [ ] **Manual end-to-end on a scratch Moodle:** sync twice with unchanged text ⇒ NO new
      `tool_policy_versions` row + NO consent re-prompt; then change one doc ⇒ exactly one
      new version for that doc, others untouched.
- [ ] Existing `tool_policy_acceptances` rows retained (guard prevents new versions; no deletion).
- [ ] **Two-person sign-off recorded** before tagging (consent/legal + Bearer endpoint = sensitive).

### 4.3 Tag steps (OPERATOR — only after 4.2 signs off)
```bash
cd <nwp/local-nwc-copyright-sync clone>
git fetch origin && git checkout ops85-copyright-0.2.1
grep -E 'release|version' version.php            # 0.2.1 / 2026070301
# merge the reviewed branch to main via MR first, then tag the merge commit:
git tag -a v0.2.1 -m "local_nwc_copyright_sync 0.2.1 (== \$plugin->release; NWP-ADR-0031 D3; consent-rail fix)"
git push origin v0.2.1
```

### 4.4 Propagate the corrected tree
After the tag, propagate the identical `0.2.1` tree to the working copies that still
carry the regression (`sites/ssc`, `sites/ssd`, `nwptoolkit`, canon `~/dir/courses_v3`)
and re-deploy to the box so no `0.2.0` regression copy survives.

---

## 5. Pair contract — `pairs/ssc.pair-contract.yml`  *(staged on `ops-auth-nwc-v1`)*

- `copyright_sync.consumer_min`: `0.2.0` → **`0.2.1`** (matches the §4 fix-forward). **Staged.**
- `oauth_sso.consumer_min`: confirmed already **`1.0.0`** on origin/main (operator-set) and
  `dependencies.consumer_bundle: auth_nwc@1.0.0` — both match the §3 `auth_nwc v1.0.0` bump. No change needed.
- Do NOT bump `contract_version` for a consumer_min raise unless it is an expand-contract
  break; a min-version raise inside the same surface shape is compatible.

> ⚠ D6 STANDING RULE still holds: while ssc users hold UID-locks against nwc's
> user-bearing tier, **no full-DB push to a coupled tier for either half** — `--code-only`
> only (memory `feedback_nwc_code_only_live_deploys`). Cutting these tags does not change that.

---

## 6. GitLab releases + tag-hygiene close-out

1. Cut a GitLab **release** object per tag (not just the tag) so "what pairs with what"
   is answerable from the UI (D3). Release notes name the counterpart minimums, e.g.
   "`local_nwc_copyright_sync` 0.2.1 — restores consent idempotency + beta_cc0; pairs with
   `nwc_copyright ≥ 0.5.0`."
2. Re-run `pl tag-hygiene --repo <each plugin repo>`; each **untagged-version** finding
   clears the moment its `v<release>` tag exists (proven in prep):
   - copyright repo: `release 0.2.0 no tag` → after bump `release 0.2.1 no tag` → after
     `git tag v0.2.1` → **clean**.
   - format_tabbed: `empty-release` (no release line) → after adding `release 0.1.0` →
     `untagged-version` → after `git tag v0.1.0` → **clean**.

---

## 7. Operator TODO summary

| ID | What | Gate |
|----|------|------|
| **HB1** | Give `format_tabbed` a home repo (or vendor under courses-plugins) + tag `v0.1.0` | versioning-policy call; credentialed tag |
| **HB2** | Create `nwp/auth-nwc`, seed from `scripts/f26/moodle/auth_nwc/`, tag `v1.0.0` | F26 auth sign-off; credentialed repo-create + push |
| **HB3** | Archive the `nwp/auth-nwc-oauth2` decoy (no tag) | operator GitLab session |
| **HB4** | 2-person consent-rail review of `ops85-copyright-0.2.1` (§4.2), then merge + tag `v0.2.1` | **consent/legal sensitive path** |
| **HB5** | Merge `ops-auth-nwc-v1` (version bump + pair contract + this runbook) | code review |
| **HB6** | Propagate corrected `0.2.1` tree to ssc/ssd/nwptoolkit/canon + re-deploy box | after HB4 |
| **HB7** | Cut GitLab releases; re-run `pl tag-hygiene` clean on each repo | after tags |
| **HB8** | Re-verify all snapshots on the build host before any of the above | build host is authoritative |
