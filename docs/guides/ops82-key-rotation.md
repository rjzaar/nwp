# Runbook: nwc OIDC signing-key rotation (ssc ↔ nwc, F26) — ops#82

**Scope:** rotating the nwc (Drupal / `simple_oauth`) OIDC signing keypair without
breaking the ssc (Moodle) SSO pair. `ver` role-vocab; no real prod domain
(`<example-prod-domain>`); no secrets are printed. Pairs with
`pairs/ssc.pair-contract.yml` (`oidc.key_rotation`) and NWP-ADR-0031.

> This document describes the LIVE rotation procedure. Do **not** run it as part of
> ops#82 — ops#82 is design + a read-only behaviour check; the working F26 SSO is
> untouched. Run the procedure only when a real rotation is authorised.

**The claim below is now machine-checked.** Everything in §0 used to be prose — a
comment in `auth.php`, a paragraph here, a `false` in the contract — and nothing
failed when the code drifted out from under it. `pl contracts key-rotation` now
couples the claim to the code and fails closed:

```bash
pl contracts key-rotation --all       # exit 0 = the invariant still holds
```

If it reports **CLAIM-DRIFT**, the consumer has started verifying signatures and
**everything in §0–§3 is void** — go to §4, not §2. If it reports **CANNOT-VERIFY**,
the consumer checkout is absent and the runbook has verified nothing; that is not a
pass. See §10.

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

**Re-verified 2026-07-28 (ops#82 close):**

- `grep -riE 'jwks|id_token|openssl_verify|JWT::decode'` over
  `sites/ssc/dev/lib/classes/oauth2/` and `sites/ssc/dev/auth/oauth2/` → **0 hits**.
  Claims come from `lib/classes/oauth2/client.php:529 get_userinfo()`.
- The same grep over every `auth_nwc` copy → **6 hits, all of them comments**
  (`auth.php:22,27,90`, `classes/uid_lock.php:26,27,28`). Zero executable JWT code.
- Live demo issuer JWKS (`nwd`, read-only GET, 2026-07-28): **HTTP 200, exactly one
  key**, fields `kty`/`n`/`e` only — **no `kid`, no `alg`, no `use`**. Overlap is not
  merely unused, it is structurally impossible on stock `simple_oauth`.

**Net:** for this pair, rotation is a low-risk hard swap. The trust anchors are
**TLS + the confidential-client token endpoint + PKCE (S256) + the bearer userinfo call**,
not the JWT signature.

> **The dangerous corollary.** Because no consumer verifies, an *unintended* rotation
> is also invisible — it breaks nothing loudly. That is exactly how ops#146 went
> unnoticed: an unprivileged key probe in `scripts/demo/nwd-issuer-provision.sh`
> answered "keys absent" every run, so **every** provisioning run silently minted a
> fresh signing keypair. Safety-from-overlap and silence-on-error are the same
> property. Treat "SSO still works" as evidence of nothing about key state; assert on
> the JWKS modulus (§3), which is the only thing that actually changes.

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
pl drush nwc --tier=live --execute -- cget simple_oauth.settings access_token_expiration
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
   pl drush nwc --tier=live --execute -- simple-oauth:generate-keys /var/www/nwc/oauth-keys
   pl drush nwc --tier=live --execute -- cset -y simple_oauth.settings public_key  /var/www/nwc/oauth-keys/public.key
   pl drush nwc --tier=live --execute -- cset -y simple_oauth.settings private_key /var/www/nwc/oauth-keys/private.key
   pl drush nwc --tier=live --execute -- cr
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

## 4. The OVERLAP procedure — required the moment any consumer verifies signatures

**Not applicable to ssc/ssd today** (§0). This section is the procedure that becomes
mandatory the day `consumer_verifies_signature` flips to `true`, and `pl contracts
key-rotation` will refuse the flip until the prerequisites below exist. Do not
improvise this under outage pressure; that is why it is written now.

### 4.0 Prerequisites (all three, or rotation is an outage)

| Prerequisite | Why | Contract field |
|---|---|---|
| Issuer can publish **two keys at once** | Otherwise the new key only appears at the instant the old one dies — there is no overlap to soak in | `provider_supports_overlap: true` |
| Tokens carry a **`kid`** | A verifier holding both keys must know which one to use; without `kid` it must trial-verify, and cannot distinguish "wrong key" from "bad token" | `tokens_carry_kid: true` |
| Consumer **refetches on unknown `kid`** | The load-bearing behaviour. A verifier that caches a JWKS and does *not* refetch when it sees an unseen `kid` rejects **every** token signed by the new key until its cache expires | `refetch_impl: <path>` |

Stock `simple_oauth` 6.1 satisfies **none** of these (`JwksEntity::getKeys()` emits a
single bare RSA key). Delivering them is a real project — a custom `KeyRepository` +
`JwksEntity` override, or a second parallel issuer — and needs its own ops issue.

> **Refetch-on-unknown-kid, precisely.** On signature-verification failure where the
> token's `kid` is not in the cached set: bust the cache, refetch the JWKS **once**,
> retry verification, and **fail closed** on the second failure. The single retry and
> the rate limit matter — without them an attacker can drive unbounded outbound
> fetches by minting tokens with random `kid`s. The vendored
> `lib/php-jwt/src/CachedKeySet.php` implements exactly this shape
> (`keyIdExists()` :175 unknown-kid → :177 rate-limit guard → :180 refetch →
> :194 still-missing → fail → :198 cache write); it is **currently dead code** in both
> Moodle trees (zero callers outside `php-jwt/src`). If a verifying consumer is ever
> built, wire that rather than hand-rolling — and note its `$expiresAfter` defaults to
> `null`, meaning **no expiry**, and that a JWK with no `kid` is indexed by array
> position (`:152`), which is useless as a stable identifier.

### 4.1 Pre-publish (announce)

Add the NEW key to the JWKS **while the OLD key still signs everything**. Nothing
changes for any consumer yet; you are only making the new key fetchable.

```bash
# provider: publish both, sign with old
pl contracts key-rotation <pair>            # must be green BEFORE you start
curl -sS "$JWKS" | jq '.keys | length'      # expect 2
curl -sS "$JWKS" | jq -r '.keys[].kid'      # expect old-kid AND new-kid
```

Wait `announce_window` (contract field). This window must exceed the **longest consumer
JWKS cache TTL**, or a consumer will still be holding the old-only set at cut-over.

### 4.2 Soak — prove consumers actually fetched the new set

The step operators skip, and the reason rotations fail. "We waited long enough" is not
evidence. Get positive confirmation from the **consumer** side:

```bash
# On the Moodle (consumer) box — did it fetch since the new key was published?
sudo tail -n 2000 /var/log/nginx/access.log | grep -c 'jwks'     # provider side: consumer IPs hitting JWKS
# Moodle caches: confirm the cached JWKS set now contains the NEW kid.
pl moodle cli ssc --tier=live --execute -- admin/cli/cfg.php --name=...  # (verifier-specific; see refetch_impl)
```

Because ssc has no verifier today there is no cache to inspect — that inspection command
is defined by whatever `refetch_impl` ships, and **that plugin must expose a way to dump
its cached kid set**. Make that a review requirement on the verifying-consumer MR: a
cache you cannot inspect is a soak you cannot perform.

Go/no-go: every consumer observed holding the new `kid`. If you cannot prove it for even
one consumer, **do not cut over** — extend the window. An unverifiable soak is a failed
soak.

### 4.3 Cut over (sign with the new key)

```bash
# provider: switch the SIGNING key; keep BOTH published
pl drush nwc --tier=live --execute -- cset -y simple_oauth.settings private_key <new>
pl drush nwc --tier=live --execute -- cr
curl -sS "$JWKS" | jq '.keys | length'      # STILL 2 — do not drop the old key yet
```

Then a real browser SSO login (§3). New tokens now carry the new `kid`; consumers that
soaked correctly verify immediately, and any that did not are rescued by
refetch-on-unknown-kid — which is why §4.0's third prerequisite is non-negotiable.

### 4.4 Retire the old key

Wait `retire_after`, which **must exceed the longest lifetime of any token signed by the
old key** — `access_token_expiration` (§1d), and refresh-token lifetime if refresh tokens
are signature-verified — **plus margin**. Only then:

```bash
curl -sS "$JWKS" | jq '.keys | length'      # 2, before
# provider: drop the old key from the published set
curl -sS "$JWKS" | jq -r '.keys[].kid'      # 1 — only new-kid remains
```

Then delete the old private key material and the `.bak` copy (§7).

### 4.5 Rollback during overlap

Overlap makes rollback *safer* than the hard swap: because both keys are still published,
reverting the **signing** key to the old one is a one-line `cset` + `drush cr`, and
consumers need no cache action at all. Roll back at the signing step, never by
un-publishing a key — un-publishing is the one irreversible move in this procedure.

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
pl drush nwc --tier=live --execute -- cr
# re-verify JWKS modulus == the pre-swap value, then a test login.
```

## 7. Retire the old key

After a clean post-swap login and `> access_token_expiration` has elapsed, delete the
`oauth-keys.bak.<date>` backup. No JWKS entry to remove (only ever one key is published).

---

## 8. Rehearse on the demo pair first (nwd → ssd)

**Never rehearse on the real pair.** `nwd → ssd` is the disposable demo pair and is the
designated rehearsal target: same codebase, same `simple_oauth` issuer, same `auth_nwc`
consumer, no real members. Its contract is `pairs/ssd.pair-contract.yml`.

```bash
# 1. Baseline — read-only, before touching anything.
pl contracts key-rotation ssd                 # must be green
pl pair smoke ssd                             # oidc_signing probes JWKS = 200
pl link verify ssd --tier=live                # 3-channel SSO/token health
curl -sS https://nwd.<example-prod-domain>/.well-known/jwks.json \
  | tee /tmp/jwks.ssd.before.json | jq '.keys | length'    # expect 1

# 2. Rotate (hard swap — §2, but against nwd's key dir).
#    scripts/demo/nwd-issuer-provision.sh already codifies generate + cset;
#    read it before running — it is the script ops#146 fixed.
#
# 3. Verify (§3): modulus changed, JWKS still 200, real browser SSO into ssd,
#    mdl_user.idnumber still == nwc sub.
curl -sS https://nwd.<example-prod-domain>/.well-known/jwks.json \
  | diff - /tmp/jwks.ssd.before.json          # expect a diff in "n"
pl pair smoke ssd
pl link verify ssd --tier=live --round-trip

# 4. Restore posture: the nightly demo reset re-provisions the pair.
pl demo status ssd
```

A rehearsal that does not end with a **real browser SSO login** has verified nothing —
`curl` cannot exercise the userinfo + UID-lock path that actually carries the identity.

### What the rehearsal cannot tell you

The demo pair proves the *provider* steps. It cannot prove consumer soak behaviour
(§4.2), because ssd's consumer does not verify signatures either. When a verifying
consumer lands, the rehearsal must be extended to include a cache-inspection step, or
the overlap procedure remains untested in the only place it matters.

---

## 9. Failure signatures — what an operator actually sees

Exact strings, read off the source in this tree (not from memory):

| Symptom | Exact message | Source | Means |
|---|---|---|---|
| Login bounces back to the Moodle login page | `No user information was returned. The OAuth 2 service may be configured incorrectly.` | `auth/oauth2/lang/en/auth_oauth2.php:96` (`loginerror_nouserinfo`) | The bearer call to `/oauth/userinfo` returned nothing. **The most likely post-rotation failure on this pair** — the access token was minted under the old key state. Usually self-clears on retry; if not, the provider's key config is inconsistent. |
| Login fails with a generic error | `The authentication process failed.` | `auth/oauth2/lang/en/auth_oauth2.php:98` (`loginerror_authenticationfailed`) | Token exchange failed. Check the provider is up and the client secret is unchanged — rotation must not touch the client secret. |
| Debug detail behind either of the above | `The login attempt failed. Reason: {$a}` | `auth/oauth2/lang/en/auth_oauth2.php:102` (`notloggedindebug`) | Enable Moodle debugging to see the underlying reason. |
| Provider-side rejection in the nwc log | `The resource owner or authorization server denied the request.` | `league/oauth2-server/src/Exception/OAuthServerException.php:172` (`access_denied`) | The presented token was not accepted. After a hard swap this is expected exactly once for tokens in flight at the swap instant. |
| Account created fresh / SSO identity severed | *(no error — login succeeds)* | — | **Not a key-rotation symptom.** The UID-lock broke; `mdl_user.idnumber` no longer matches `sub`. This is the full-DB-push hazard, not rotation. Stop and check the standing `--code-only` rule. |
| JWKS endpoint 500 | *(HTTP 500)* | — | The configured `public_key` path is unreadable by `www-data`. This was the ops#146 symptom before the fix. Check ownership of the key dir, not the key contents. |
| JWKS endpoint 301 | *(HTTP 301)* | — | You probed `/oauth/jwks`, which redirects. The contract requires `/.well-known/jwks.json`; `pl link verify` asserts this specifically. |
| Gate says `CLAIM-DRIFT` | `the contract says consumer_verifies_signature=false, but the consumer tree contains executable signature/JWKS code` | `pl contracts key-rotation` | **Stop.** §0–§3 are void. The hard swap you are about to run is an outage. Go to §4. |

**A rotation that produces no symptom at all is not evidence of success** — see the §0
corollary. Assert on the JWKS modulus.

---

## 10. Who may run this — gating

| Tier | Gate |
|---|---|
| `nwd → ssd` demo, `*.<example-test-domain>` test tier | AI-runnable (A14 test-tier scope). This is the rehearsal path. |
| Real `nwc → ssc` **live** | **Operator.** A rotation invalidates issued tokens; run it in a change window with a human present. |
| Real **prod** | **Operator + offline-deploy-host gated.** Prod writes go through the offline deploy host (role vocab; see NWP-ADR-0017) under hardware-token presence; no AI-accessible machine holds a key that reaches prod. Nothing in this runbook may be executed against prod from an AI-run host — the AI half stops at producing the signed change and the go/no-go evidence. |

The read-only steps (§1, §3 verification, §8 step 1, `pl contracts key-rotation`,
`pl pair smoke`, `pl link verify`) are safe to run anywhere and are the AI's half of the
work at every tier.

---

## Contract linkage

The verified behaviour is recorded in `pairs/ssc.pair-contract.yml` and
`pairs/ssd.pair-contract.yml` under `oidc.key_rotation` — and, since ops#82 closed, it is
**enforced** rather than merely recorded:

| Field | Today | Obligation |
|---|---|---|
| `consumer_verifies_signature` | `false` | The load-bearing fact. Checked against code by `pl contracts key-rotation` → `CLAIM-DRIFT`. |
| `tokens_carry_kid` | `false` | Must be `true` before verification may be enabled. |
| `provider_supports_overlap` | `false` | Must be `true` before verification may be enabled. |
| `mode` | `hard_swap` | Must be `hard_swap` while nobody verifies (`MODE-MISMATCH` otherwise). |
| `announce_window` | `0` | §4.1 — must exceed the longest consumer JWKS cache TTL. |
| `overlap_window` | `0` | §4.3 — both keys published across cut-over. |
| `retire_after` | `0` | §4.4 — must exceed the longest-lived token signed by the old key, plus margin. |
| `refetch_impl` | `null` | §4.0 — must name an existing file once verifying (`NO-REFETCH`). |
| `consumer_core_roots` | `sites/<pair>/dev` | **ops#152** — where the Moodle **core** tree lives. Undeclared or absent ⇒ `CANNOT-VERIFY`. |
| `verification_exempt_paths` | 19 entries | Explicit, reviewable waivers for inert matches. Shell globs. |
| `runbook` | this file | Must exist (`MISSING-RUNBOOK`). |

### ops#152 — what the gate actually scans

Until ops#152 the gate scanned only `crossref.consumer_roots`, i.e. the first-party
plugin trees (**~105 PHP files**). The claim under test is a claim about *the consumer*,
and the consumer is Moodle: core (**~16,517 PHP/inc files**) plus plugins. Scanning the
plugins and printing OK was fail-open at the worst possible spot — JWT verification
planted at `sites/ssc/dev/lib/classes/oauth2/client.php`, the very file this runbook's
hand verification cites, did **not** trip `CLAIM-DRIFT`.

Core is now a declared, scanned root. Two consequences worth knowing:

* **The hand verification is now machine-checked.** With core in the corpus,
  `lib/classes/oauth2/` and `auth/oauth2/` produce **zero** hits for the whole
  signature/JWKS pattern — so §"the SSO login path never parses `id_token`" is
  re-confirmed on every run, and a core upgrade that starts verifying `id_token`
  **will** go red.
* **`verification_exempt_paths` carries the real exceptions.** Moodle core genuinely
  does verify JWS — for **LTI 1.3** (`lib/lti1p3` `LtiMessageLaunch::validateJwtSignature`,
  `enrol/lti/**`, `mod/lti/**`), against LTI *platform* keys: a different issuer with its
  own JWKS and its own rotation story. The rest of the waiver list is other trust domains
  (WebAuthn attestation, MNet peer signing, BBB, the Google API client) and substring
  false positives (`BADGE_USER_ID_TOKEN`, `INVALID_TOKEN`). Each entry is listed and
  justified in `pairs/ssc.pair-contract.yml`, so removing one is a reviewable act — a
  blanket "skip core" would not be.

**Cost:** the `grep -rlE` prefilter is the only pass over all 16.5k files (~0.5 s) and
narrows to ~80 candidates; only those are comment-stripped. `pl contracts key-rotation
--all` over both real pairs measures **5.9 s**.

**How to flip verification on, safely.** Do not edit `consumer_verifies_signature` on its
own — the gate will reject it, by design. The order is: (1) open an ops issue for
`simple_oauth` multi-key support (6.1 cannot overlap natively); (2) ship the provider
change so the JWKS publishes two keyed entries; (3) ship the consumer's
refetch-on-unknown-kid implementation and point `refetch_impl` at it; (4) set real
`announce_window` / `overlap_window` / `retire_after`; (5) *then* flip
`consumer_verifies_signature` and `mode: overlap` together. The gate going green is the
signal that §4 is actually executable.

Acceptance tests: `tests/unit/test-oidc-key-rotation.bats`.

> Follow-up doc-patch: the released `nwp/auth-nwc` v1.0.0 plugin repo carries the same inaccurate
> "verified against nwc's JWKS" comments this runbook corrects; ship a v1.0.1 doc-patch there.
