# Runbook: nwc OIDC signing-key rotation (ssc ↔ nwc, F26) — ops#82

**Scope:** rotating the nwc (Drupal / `simple_oauth`) OIDC signing keypair without
breaking the ssc (Moodle) SSO pair. `ver` role-vocab; no real prod domain
(`<example-prod-domain>`); no secrets are printed. Pairs with
`pairs/ssc.pair-contract.yml` (`oidc.key_rotation`) and ADR-0031.

> This document describes the LIVE rotation procedure. Do **not** run it as part of
> ops#82 — ops#82 is design + a read-only behaviour check; the working F26 SSO is
> untouched. Run the procedure only when a real rotation is authorised.

---

## 0. Headline: does this pair need key overlap? NO.

**The Moodle consumer does NOT verify the ID-token signature against nwc's JWKS**, so
rotating nwc's signing key does **not** break ssc SSO. Verified read-only (2026-07-11):

- Moodle core OAuth2 (`lib/classes/oauth2/`) carries zero JWT/JWKS logic — a
  `grep -riE 'id_token|jwks|jwt|signature|verify'` over it returns no hits. The only
  claim source is the **userinfo endpoint** (`client.php get_userinfo()` /
  `get_userinfo_mapping()`); claims are mapped from `$userinfo[...]`, never an id_token.
- `auth_nwc` rides on core for the protocol dance and only adds the post-auth UID-lock
  (a `\core\event\user_loggedin` observer); it never parses a JWT.
- **No `kid`, no `alg`, no `use`** in the live JWKS (single bare RSA key); `simple_oauth`
  issues id_tokens with `keyIdentifier = NULL`. Even a signature-verifying consumer
  could not select-by-`kid` during an overlap window.
- **`simple_oauth` 6.1 cannot do key overlap** — its config schema exposes a single
  `public_key`/`private_key` pair only. Rotation is an atomic **hard swap**; true overlap
  would need custom code or a second parallel issuer (out of scope).

**Net:** for this pair, rotation is a low-risk hard swap. The trust anchors are
**TLS + the confidential-client token endpoint + PKCE (S256) + the bearer userinfo call**,
not the JWT signature.

---

## 1. Pre-checks (read-only; run before touching anything)

`ver` runs these read-only first, on the box that hosts nwc/ssc:

```bash
# a. JWKS is live; note the CURRENT modulus (first chars) to compare after the swap
curl -sS https://nwc.<example-prod-domain>/.well-known/jwks.json | tee /tmp/jwks.before.json
# b. discovery is 404 (expected — simple_oauth exposes none; ssc uses MANUAL endpoints)
curl -s -o /dev/null -w '%{http_code}\n' \
     https://nwc.<example-prod-domain>/.well-known/openid-configuration   # -> 404
# c. keypair present + owner www-data (do NOT cat the private key)
sudo ls -la /var/www/nwc/oauth-keys/
# d. record the access-token TTL — you wait > this before declaring the old key retired
cd /var/www/nwc/html && sudo -u www-data php8.2 ../vendor/bin/drush \
     cget simple_oauth.settings access_token_expiration
# e. baseline: a real SSO login into ssc still works (browser, one test user)
```

Go/no-go: JWKS 200 with one key, keys dir owned by `www-data`, clean baseline login.

---

## 2. Rotation procedure (hard swap — the only mode simple_oauth 6.1 supports)

nwc is a `*.example.com` test-tier box (A14), not offline-gated the way real prod is; still
treat a live-with-real-students rotation as a change-window action.

1. **Maintenance window.** Rotation is atomic; pick a low-traffic window so no in-progress
   login straddles the swap (see §5).
2. **Back up the current keypair** (instant rollback):
   ```bash
   sudo cp -a /var/www/nwc/oauth-keys /var/www/nwc/oauth-keys.bak.$(date +%Y%m%d)
   ```
3. **Generate + install the new keypair** (reuse the codified provider step
   `scripts/f26/nwc-provider-oidc-setup.sh:94-97` rather than hand-typing):
   ```bash
   cd /var/www/nwc/html
   sudo -u www-data php8.2 ../vendor/bin/drush simple-oauth:generate-keys /var/www/nwc/oauth-keys
   sudo -u www-data php8.2 ../vendor/bin/drush cset -y simple_oauth.settings public_key  /var/www/nwc/oauth-keys/public.key
   sudo -u www-data php8.2 ../vendor/bin/drush cset -y simple_oauth.settings private_key /var/www/nwc/oauth-keys/private.key
   sudo -u www-data php8.2 ../vendor/bin/drush cr
   ```
   > CLI PHP note: the box default `php` is 8.4; Drupal/Moodle CLI must use **php8.2/8.3**
   > (pair contract `oidc.cli_php_version: "8.2"`).
4. **No overlap available.** Stock `simple_oauth` 6.1 cannot publish both keys — the swap
   is atomic at step 3. Real dual-key overlap = future work (custom `KeyRepository` or a
   second issuer); file its own ops issue if a verifying consumer ever lands.

---

## 3. Cut-over verification

```bash
# JWKS now shows the NEW modulus (differs from /tmp/jwks.before.json), still 200, no kid
curl -sS https://nwc.<example-prod-domain>/.well-known/jwks.json | diff - /tmp/jwks.before.json  # expect a diff in "n"
curl -s -o /dev/null -w '%{http_code}\n' https://nwc.<example-prod-domain>/user/login            # 200
pl pair smoke ssc          # or scripts/commands/pair-smoke.sh — oidc_signing probes JWKS = 200
```

**The decisive test = a real browser SSO login into ssc after the swap.** Log in as a test
nwc user → ssc `/login` → "nwc (F26)" → confirm the session lands and
`mdl_user.idnumber == nwc sub` (UID-lock still holds). Because ssc reads claims from
userinfo (not the token signature), this passes immediately with **no JWKS-cache wait** —
which is itself the confirmation that this pair does not need overlap.

---

## 4. (Only if a signature-verifying consumer ever exists) force a JWKS refetch

Not applicable to ssc today. For a future verifying consumer, after the swap clear its JWKS
cache so it does not reject new tokens against the old cached key (Moodle core: purge caches;
other consumers: hit their JWKS-refresh path or wait out the documented cache TTL).

---

## 5. Residual risks

- **In-flight tokens at the swap instant.** After an atomic swap, any old-key access token
  presented to nwc's own `/oauth/userinfo`, or a refresh-token exchange, is rejected. Moodle
  only calls userinfo at **login**, so the blast radius is a single login caught mid-flow.
  Mitigation: swap in a low-traffic window; optionally wait `> access_token_expiration` (§1d).
- **Doc-drift risk (not a runtime risk).** If a future hardening turns on JWKS verification in
  Moodle (or a new consumer verifies), the hard-swap becomes an outage. Track "consumer verifies
  signature?" explicitly in the pair contract (`oidc.key_rotation.consumer_verifies_signature`).
- **No `kid`** blocks graceful multi-key overlap; combined with the single-key config, overlap is
  doubly blocked. Flag before adding any verifying consumer.
- **Private-key hygiene.** `oauth-keys/` is `www-data`-only, 0600 private key, with deny rules;
  keep the `.bak` copy equally locked and delete it after the retire step.

---

## 6. Rollback (atomic and fast — the upside of the single-key model)

```bash
sudo rm -rf /var/www/nwc/oauth-keys
sudo mv /var/www/nwc/oauth-keys.bak.<date> /var/www/nwc/oauth-keys
cd /var/www/nwc/html && sudo -u www-data php8.2 ../vendor/bin/drush cr
# re-verify JWKS modulus == the pre-swap value, then a test login.
```

## 7. Retire the old key

After a clean post-swap login and `> access_token_expiration` has elapsed, delete the
`oauth-keys.bak.<date>` backup. No JWKS entry to remove (only ever one key is published).

---

## Contract linkage

The verified behaviour is recorded in `pairs/ssc.pair-contract.yml` under `oidc.key_rotation`
(`consumer_verifies_signature: false`, `mode: hard_swap`, `provider_supports_overlap: false`,
`jwks_uri`, `post_rotate_checks`). If a future consumer *does* verify signatures, flip
`consumer_verifies_signature: true`, set a real `overlap_window`, and open a follow-up ops issue
for `simple_oauth` multi-key support — 6.1 cannot overlap natively.

> Follow-up doc-patch: the released `nwp/auth-nwc` v1.0.0 plugin repo carries the same inaccurate
> "verified against nwc's JWKS" comments this runbook corrects; ship a v1.0.1 doc-patch there.
