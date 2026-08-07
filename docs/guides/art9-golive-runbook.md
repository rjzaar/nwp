# Art. 9 Consent Go-Live Runbook

**One pre-proven switch.** Everything in this runbook is already running, end to
end, on the **nwd/ssd demo tier**. Going live on `nwc`/`ssc` is not a build — it
is flipping the same code and the same two config flags that counsel will have
seen working.

- **Status:** waiting on ops#119 (counsel ratification of the consent wording).
- **Reference implementation:** `https://nwd.<example-prod-domain>` — full journey live.
- **Last verified:** 2026-07-26.

---

## Table of Contents

1. [The two-tier posture (why this is safe today)](#1-the-two-tier-posture)
2. [Current state](#2-current-state-2026-07-26)
3. [The interlock you must understand first](#3-the-interlock-you-must-understand-first)
4. [Pre-conditions](#4-pre-conditions)
5. [The ordered switch](#5-the-ordered-switch)
6. [Verification](#6-verification)
7. [Rollback](#7-rollback)
8. [What counsel can see today](#8-what-counsel-can-see-today)

---

## 1. The two-tier posture

The Art. 9 gate is **protective, not permissive**. It only ever *refuses* to
store special-category (religious formation) data. Deploying **enforcement**
therefore needs no legal sign-off — it can only reduce what is stored.

ops#119 is needed for the *other* half: **asking** members for consent using
specific ratified wording, and then **relying** on that consent.

| Tier | Sites | Enforcement | Consent-asking |
|------|-------|-------------|----------------|
| Demo (daily reset, `@demo.invalid`, wiped 01:00 Melbourne) | `nwd` / `ssd` | **ON** | **ON** — testers exercise the whole journey |
| Real | `nwc` / `ssc` | **ON** | **OFF** until ops#119 — no member sees unratified wording |

---

## 2. Current state (2026-07-26)

### `nwc` (Drupal, the consent-**asking** side) — real tier

| Thing | Value | Meaning |
|-------|-------|---------|
| Code | **old** `ConsentFreezeSubscriber` (protective, 2 redirects) | Hard freeze, no Trialing mode, no CC0 gate |
| `enforce_gate` | `false` | **This is what keeps consent-asking OFF** — see §3 |
| `enforce_contribution_gate` | *absent* | Pre-Trialing config schema |
| `consent_version` | `2` | Wording still **draft / unratified** |
| `nwc_art9_consent` records | **0** | Nobody has ever been asked |
| Accounts | **2** (`admin` uid1, `rjzaar` uid2 — both operator) | **No real members exist yet** |

### `ssc` (Moodle, the formation-**write** side) — real tier

| Plugin | Gate | Deployed |
|--------|------|----------|
| `auth/nwc` | **GATED** | yes |
| `mod/depthcontent` | **GATED** | **2026-07-26** (this arc) |
| `local/practice` | **GATED** | yes |

Enforcement is **live and proven** on `ssc`: a non-consented member persists
**0 rows**; an explicitly consented member persists normally; withdrawal shuts
the gate again. `depthcontent_mastery`, `local_practice_log` and
`local_practice_state` are all at 0 rows site-wide.

### `nwd` / `ssd` — demo tier

`nwd` runs the **new** code and the **full** journey: `enforce_gate=true`,
`enforce_contribution_gate=true`, Trialing mode, CC0 contribution gate, retired
(no-op) freeze. All paths verified 2026-07-26.

> **Superseded 2026-08-07 (ops#279).** The claim below — that `ssd` had "no NWC
> Moodle plugins deployed at all" — was true when written and is now false. All
> three plugins (`auth/nwc`, `mod/depthcontent`, `local/practice`) are deployed
> AND installed on `ssd` live, `\auth_nwc\consent` loads, and the gate returns
> true for every demo persona. Verified by execution, not by grep:
>
> ```bash
> scripts/demo/ssd-consent-arc.sh  --site=ssd --tier=live --check   # Moodle half
> scripts/demo/nwd-consent-claim.sh --site=nwd --tier=live          # claim in a token
> ```
>
> The second is the one that matters for this runbook's §6: it mints a real
> token, calls the real `/oauth/userinfo`, and asserts `art9_consent=true` for a
> consenting member **and `false` for a Trialing one**. A probe that only ever
> sees `true` cannot tell a working claim from a hardcoded one.
>
> Historical text: *"`ssd` has no NWC Moodle plugins deployed at all (`auth/nwc`,
> `mod/depthcontent`, `local/practice` are all ABSENT) and the nwd→ssd consent
> push reports `skipped: moodle_not_configured`."*

---

## 3. The interlock you must understand first

This is the single most important thing in this runbook.

`Art9ConsentGate::mayWriteArt9()` is:

```php
return $uid === 1 || $this->hasExplicitConsent($uid) || !$this->gateEnforced();
```

and the **old** `ConsentFreezeSubscriber` (currently on live `nwc`) redirects any
member for whom `mayWriteArt9()` is false to the consent form.

So on live `nwc` **right now**:

- `enforce_gate=false` → `mayWriteArt9()` is **true for everyone** → the freeze
  **never fires** → **nobody is ever shown the consent form**.
- Flipping `enforce_gate=true` **while the old code is still deployed** would
  *simultaneously* switch on enforcement **and** switch on consent-asking — as a
  **hard freeze** with no Trialing alternative. That is the "one wall for
  everything" model that was deliberately abandoned, because consent that is a
  condition of membership is not freely given (GDPR Art. 7(4)).

**Therefore: never flip `enforce_gate` before the new code is deployed.**

The compensating fact that makes today safe: the `art9_consent` OIDC claim is
computed from `hasExplicitConsent()`, **not** `mayWriteArt9()`. So
`enforce_gate=false` **cannot** leak a `true` claim to Moodle. The Moodle gate is
independent and stays fail-closed regardless.

The escape hatch that `enforce_gate=false` *does* open is
`writeFormation()` → `'persist'` (logged loudly). It is currently moot — no
callers on live `nwc`, and no real members — but it **must be `true` before any
real member exists**.

---

## 4. Pre-conditions

- [ ] **ops#119 closed**: counsel has ratified the `consent_text` wording.
- [ ] Wording updated in
      `sites/nwc/dev/html/profiles/custom/nwc/modules/nwc_features/nwc_privacy/config/install/nwc_privacy.settings.yml`.
- [ ] **`consent_version` bumped** if the wording changed materially — this
      invalidates prior consents and re-prompts (Art. 7(1) demonstrable,
      versioned consent).
- [ ] Fresh verified remote backup of `nwc` **and** `ssc`
      (`pl backup nwc --remote`, `pl backup ssc --remote`; record in the
      rollback registry).
- [ ] The demo tier still passes the full journey probe (§6).

---

## 5. The ordered switch

> Steps 2 and 3 **must happen in the same maintenance window**. Between them the
> new code is deployed with `enforce_gate` still `false`, which means
> `writeFormation()` persists and `mayContribute()` returns true — both gates
> open. Maintenance mode closes that window to zero member exposure.

### Step 1 — ratify and bump (no deploy)

Update `consent_text`, bump `consent_version`, commit, MR, merge.

### Step 2 — maintenance ON, deploy the new `nwc` code

```bash
pl drush nwc --tier=live --execute -- state:set system.maintenance_mode 1 -y
pl drush nwc --tier=live --execute -- cr

# STANDING RULE: --code-only. A full-DB push rewrites UIDs and severs the
# UID-locked ssc/ssd OIDC SSO identities. See ADR-0029.
#
# Rehearse first — --dry-run snapshots and previews the rsync, then aborts
# before any DB write, permission change or service reload:
pl stg2live nwc --code-only --dry-run

# Then the real thing:
pl stg2live nwc --code-only
```

> `pl stg2live` — there is no "pl deploy" verb, and this runbook prescribed one
> until 2026-07-26 — is what carries the
> `--code-only` primitive, the fail-closed PROFILE-CHANGE GUARD, the pre-deploy
> webroot snapshot and the ADR-0031 paired-site ordering check. `pl live2prod
> nwc --code-only` is the same step for the prod leg.

This retires the freeze (it becomes a documented no-op) and brings in Trialing
mode, `MemberCapabilities` and the CC0 contribution gate.

### Step 3 — flip both flags, still in maintenance

```bash
pl drush nwc --tier=live --execute -- cset nwc_privacy.settings enforce_gate true -y
pl drush nwc --tier=live --execute -- cset nwc_privacy.settings enforce_contribution_gate true -y
pl drush nwc --tier=live --execute -- cset nwc_privacy.settings consent_version <N> -y
pl drush nwc --tier=live --execute -- cr
```

Confirm before lifting maintenance:

```bash
pl drush nwc --tier=live --execute -- cget nwc_privacy.settings
# expect: consent_version: <N> / enforce_gate: true / enforce_contribution_gate: true
```

### Step 4 — maintenance OFF

```bash
pl drush nwc --tier=live --execute -- state:set system.maintenance_mode 0 -y
pl drush nwc --tier=live --execute -- cr
```

### Step 5 — `ssc` Moodle (already done)

Nothing to deploy. The gate shipped 2026-07-26. Re-assert only:

```bash
pl moodle gate-status ssc     # LIVE block must show all three GATED
```

---

## 6. Verification

Both probes are throwaway-account based and clean up after themselves.

### Drupal side (`nwc`) — the four journey paths

Run the same probe already proven on `nwd`:

```bash
# The probe script is staged and removed by the deploy path; the RUN goes through pl
# so the gate, the live.enabled flag and the ledger apply.
pl drush nwc --tier=live --execute -- php:script art9_nwd_journey.php
```

> The probe file itself is staged with the same `--code-only` deploy that ships
> the release, not by a hand `scp`.
>
> **The missing verb this paragraph used to ask for now exists (ops#279):**
> `pl drush <site> --tier=live --execute --script=<local.php>` stages a local
> `.php` outside the docroot (0600, `www-data`), runs it via `drush php:script`,
> and removes it on every exit path — inheriting the dry-run default, the
> ADR-0028 gate and the `live.enabled` check that a hand-rolled `scp`+`ssh`
> silently drops. Two gotchas are handled inside the verb rather than left to
> callers: a literal `--` is inserted before the script's own arguments (drush
> otherwise claims them: *"The --base-url option does not exist"*), and callers
> must not rely on drush's exit status, because drush reports **any** `exit()` a
> `php:script` makes — `exit(0)` included — as "terminated abnormally" and
> returns 1. Have the script print its verdict and parse that, failing closed
> when no verdict line appears.

Expect **ALL DEMO-TIER JOURNEY PATHS PASSED**:

| Path | Assertion |
|------|-----------|
| Declined / not asked | `writeFormation()` = `ephemeral`, `isTrialing`=true, banner shown, claim `art9_consent=false` |
| Consent given | `writeFormation()` = `persist`, banner hidden, claim `art9_consent=true` |
| Withdrawn | erasure runs, back to `ephemeral`/Trialing, claim false, **withdrawal audit row retained** |
| CC0 gate | `contributionGateEnforced()`=true, `mayContribute()`=false before acceptance |

### Moodle side (`ssc`) — enforcement, both directions

```bash
pl moodle gate-status ssc
```

Then the live probe (creates one throwaway non-admin user, asserts 0 rows
without consent, rows **with** consent — proving the zero is the gate and not
dead code — then gate shut again on withdrawal, then purges itself).

### Cross-app round trip

Log a consented demo member in to Moodle via OIDC and confirm
`auth_nwc_art9_consent` preference lands as `1`; withdraw on Drupal, re-login,
confirm it flips to `0`.

---

## 7. Rollback

Reverse order. Each step is independently sufficient to stop consent-asking.

**Fastest stop-the-asking (seconds):**

```bash
pl drush nwc --tier=live --execute -- cset nwc_privacy.settings enforce_gate false -y
pl drush nwc --tier=live --execute -- cr
```

With the **new** code this returns everyone to Trialing-with-gates-open (loudly
logged). With the **old** code it also disables the freeze. Either way, no member
is shown the consent form.

**Full code rollback:** restore from the pre-deploy remote backup recorded in
`docs/reports/consolidation-arc-2026-07/rollback-registry.md` (CP16), then
`drush cr`.

**Moodle gate rollback** (only if the gate itself misbehaves — note this
*removes* protection):

```bash
# Restore the pre-Art.9 plugin tree (CP18 in the rollback registry):
pl moodle rollback ssc --tier=live execute

# Then re-run the Moodle upgrade. The php binary and -d max_input_vars=5000 are
# resolved and ASSERTED by the verb — you do not type them:
pl moodle cli ssc --tier=live --execute -- admin/cli/upgrade.php --non-interactive
```

> **Box gotcha — now enforced, not remembered.** The box's default `php` is 8.4
> (Moodle 4.4 rejects it) and its `max_input_vars` is `1000` (Moodle needs
> `>= 5000`). `admin/cli/upgrade.php` run without the `-d max_input_vars=5000`
> override **fails its environment check AFTER maintenance mode is enabled and
> leaves the site DOWN** — that is what took the `ss` Moodle instance offline for ~6
> minutes on 2026-07-26. Since item 9, `moodle_cli_assert()` REFUSES any
> `pl moodle` invocation whose resolved command has lost either half, so the
> failure mode is a refusal instead of an outage.
>
> If a site does end up stuck in maintenance, recovery is one verb:
>
> ```bash
> pl moodle maintenance ssc --tier=live off --execute
> ```
>
> Persisting `max_input_vars=5000` in `/etc/php/8.2/{cli,fpm}/php.ini` as
> committed server config is programme item 10's `servers/<name>/php/`.

---

## 8. What counsel can see today

Counsel does not have to review a specification. The whole journey is running:

- **URL:** `https://nwd.<example-prod-domain>` (the demo tier's public host — the
  operator will paste the real URL into the ops#119 invitation)
- **Invite code:** `pl demo invite nwd --tier=live` — issues a fresh code per level and
  renders a copy-ready invitation email (plaintext printed once, into a 0600
  draft under `sites/nwd/demo-invites/`).
- **Safety:** synthetic `@demo.invalid` accounts only, entire site wiped and
  restored from a verified golden image nightly at 01:00 Melbourne. The golden
  itself captures `enforce_gate=true` + `enforce_contribution_gate=true`, so the
  consent-enabled state survives every reset.

What counsel is being asked to ratify is **only the wording** of `consent_text`
in `nwc_privacy.settings.yml`. The mechanism around it is built, deployed and
verified.
