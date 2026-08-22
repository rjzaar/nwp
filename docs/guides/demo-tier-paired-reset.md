# The nwd ↔ ssd demo pair — paired golden & paired reset

**Status:** built + browser-proven on dev (ops#133 Phase 2, 2026-07-26)
**Scope:** dev/stg. The live half is provider-only today — see §7.

---

## 1. What the demo tier is now

One product, two sites:

| | site | stack | role |
|---|---|---|---|
| provider | **nwd** | Drupal / Open Social | OIDC issuer, invite codes (`/demo/join`), feedback sink |
| consumer | **ssd** | Moodle 4.4 | SSO client, the actual courses |

An invited helper gets **one code**, redeems it at `nwd/demo/join`, and is
instantly an account (patron-saint name, `user<N>@demo.invalid`, no PII). From
there they walk into ssd courses over SSO without entering anything again.
Everything both sites hold is erased nightly.

## 2. Why the two halves must be reset TOGETHER

At runtime `auth_nwc` writes `mdl_user.idnumber = <nwd account uuid>` on first
SSO — the UID-lock — and reconciles the `guilds` claim into `nwcguild:<uuid>`
cohorts. So ssd's user rows are **references into nwd's account set**.

Restore one half alone and those references dangle: ssd holds locks against
accounts nwd no longer has (or, worse, against uuids nwd has since reissued).
NWP-ADR-0031 D9 already names this hazard for the real ssc↔nwc pair and states the
invariant — *restore BOTH halves to one logical cut*. The demo pair runs that
restore **every night, unattended**, so Phase 2 makes "one logical cut" a
mechanically verified fact rather than an operator convention.

## 3. How it is enforced — the pair cut

`pl demo golden nwd --with-pair` captures both halves back-to-back, then writes
**`sites/nwd/demo-golden/pair.cut.json`** binding the two golden images by the
sha256s they had at capture time:

```json
{ "type": "demo-golden-pair-cut", "pair": "ssd-nwd", "cut_id": "…",
  "provider": { "site": "nwd", "db_sha256": "…", "files_sha256": "…" },
  "consumer": { "site": "ssd", "db_sha256": "…", "files_sha256": "…" } }
```

`pl demo reset nwd --with-pair` re-derives both halves' shas and **refuses**
unless they still match the cut. Re-capturing one half alone — the realistic
way an operator breaks this — is therefore caught *before* anything is
destroyed:

```
ERROR: PAIR CUT BROKEN: ssd db sha256 0d17aa02… ≠ cut 4daa3071….
ERROR: One half was re-captured alone. A paired restore would leave SSO identities mismatched.
WARNING: Fix: re-capture BOTH — 'pl demo golden nwd --with-pair'.
```

`pl demo status nwd` shows the current cut id and whether it still holds.

## 4. Opt-in, not opt-out

A pair joins the demo tier by declaring it **in the pair contract** — the same
committed, CI-validated file `lib/pair.sh` already reads at every deploy
choke-point. There is no second registry to drift:

```yaml
# pairs/ssd.pair-contract.yml
demo:
  enabled: true              # ← the opt-in. Without it every paired path refuses.
  paired_golden: true
  paired_reset: true
  restore_order: provider-first
  idle_guard: both
  harvest: both
  feedback_path: /feedback/submit
```

This is what keeps the **real ssc↔nwc pair out of the nightly wipe**: its
contract has no `demo:` block at all, so `demo_pair_contract_for ssc` returns
nothing and every paired verb refuses.

## 5. What a paired reset actually does

Order is the safety property — everything that can refuse refuses *first*:

1. verify **both** goldens (manifest site-match + sha256) **and** the cut;
2. idle-guard **both** halves (Drupal `sessions`, Moodle `mdl_sessions`); either
   half active ⇒ exit **3** (retryable), never an error;
3. one confirmation for the pair (`--force` for the scheduler);
4. pre-wipe harvest of **both** halves into the **provider's** spool, so the
   nightly digest is one issue: Drupal watchdog + PHP log; Moodle failed
   scheduled tasks + error/failure/denied events from the standard logstore +
   PHP log (fail-OPEN — a harvest failure never blocks a reset);
5. restore **provider first** (NWP-ADR-0031 D5): if the run dies between halves the
   consumer holds *old* locks against accounts the provider has already
   restored — recoverable by re-running. The reverse order is not;
6. reseed the provider's demo matrix + re-push the hashed invite codes;
7. rebuild caches on both;
8. **re-assert the consumer**: OIDC wiring, demo posture and course catalogue
   are each re-checked by the same `--check` mode the build scripts expose. A
   reset that restores data but leaves the demo unusable **returns non-zero**
   and logs `reset-degraded`.

Naming *either* half from the CLI runs the paired path. `--no-pair` is the
explicit single-site override; it warns loudly and logs
`reset-unpaired-override`.

## 6. Building / rebuilding the ssd half

All idempotent, all dev-only, all fail-closed:

```sh
scripts/demo/ssd-rebuild.sh                 # plugins from ss-moodle-plugins + upgrade + posture
scripts/demo/nwd-issuer-provision.sh        # provider: keys, scopes, client, consent permission
scripts/demo/ssd-oidc-wire.sh               # consumer: issuer, endpoints, sub→idnumber, auth_nwc
scripts/demo/ssd-seed-courses.sh            # 3 visible, self-enrolable demo courses
pl demo golden nwd --with-pair              # bind the cut
```

Each has a `--check` mode (except rebuild) used by the paired reset's
post-restore verification and by the bats suite.

**Plugin provenance is recorded, not assumed.** `ssd-rebuild.sh` clones
`nwp/ss-moodle-plugins` into `sites/ssd/.plugin-src/`, pins the ref from
`sites/ssd/.nwp.yml → moodle.plugins_ref`, and writes the resolved SHA to
`sites/ssd/.plugin-src/INSTALLED.json`. It also runs a **decoy sweep**: the
build refuses if `auth_nwc_oauth2` appears in the tree, in `oauth2.provider_plugin`,
or in `mdl_config_plugins`. That plugin was the lock-less decoy removed
fleet-wide; `sites/ssd/.nwp.yml` named it until Phase 2.

> ⚠ `sites/<site>/dev/<type>/<name>` **is** the promotion source for the live
> site: `pl moodle plugin deploy` prefers it over any configured `--from`
> (`scripts/commands/moodle.sh`, the `staging=` line). Whatever is in the dev
> tree is what ships. That is why provenance is recorded.

## 7. Known gaps (honest list)

- **ssd has no live host.** No DNS, no vhost, no `/var/www/ssd`. Paired
  `--tier=live` is explicitly REFUSED rather than half-implemented. nwd's own
  live demo tier (Phase 1) is unaffected: the pair guard is scoped to tiers
  where the partner actually has an instance.
- **Forced profile completion on first SSO.** `nwc_demo_access` sets no profile
  first/last name, so nwd emits no `family_name` and Moodle interposes a
  "complete your profile" form. Fixable in one place (populate
  `field_profile_first_name` / `field_profile_last_name` at account creation).
- **`nwc_moodle_sync` is not used and should not be enabled** on this pair: it
  joins on email/username, which never matches `@demo.invalid` accounts, and
  its `nwc_moodle_sync_user` QueueWorker plugin does not exist — enabling
  `sync_on_login` would throw on cron. Guild→cohort works via the `guilds`
  claim in `auth_nwc` instead, which needs no web services at all.
- **Cross-site feedback is a link-back (v1).** ssd's banner links to nwd's
  `/feedback/submit` with the Moodle page URL attached; nwd's `demo-tester`
  label is applied automatically while `demo_mode` is on. The machine endpoint
  `POST /api/feedback/log` exists on nwd but its `bearer_token` is empty and
  `local_feedback`'s `avc_url` is unset — wiring that is Phase 3.
- **`lib/moodle-promote.sh` emits the wrong field mappings.** Its generated
  apply-script maps `name→firstname` / `preferred_username→lastname`, but
  `auth_nwc` consumes `given_name` / `family_name` and neither of the other
  two. Live ssc is configured the correct way; the generic generator is drift.
  ssd is wired from the pair contract, so it is unaffected.
