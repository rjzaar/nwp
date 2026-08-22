## F26: NWC↔SS OIDC Single Sign-On

**Status:** SIGNED OFF (2026-07-10, operator) — approved to build. OIDC SSO is the
sanctioned path for the paired sites (ssc↔nwc, ssd↔nwd) per NWP-ADR-0031 / ops#73–76.
**Implementation caveat:** the code MR (nwp!49) must first reconcile the issuer to
**nwc** (not avc) per the 2026-07-09 deep audit before it merges — the design decision
is signed off here; the stale-spec reconcile is a merge gate on the implementation.

> **Issuer reconcile (2026-07-10).** This spec was authored (2026-04-12) when **avc**
> was the canonical Drupal site, so its body named avc as the OIDC issuer/provider and
> §2 treated nwc as out of scope. Both are now stale: avc is **frozen** and **nwc** is
> the canonical 2.0 site (the un-fork to Open Social 13), and NWP-ADR-0031 makes the pairing
> **ssc↔nwc / ssd↔nwd**. This pass reconciles the design to **nwc as the issuer** and
> lifts the §2 clause that forbade the nwc↔ss extension (that extension is exactly what
> is now signed off). The nwp!49 code branch was already nwc-branded; this brings the
> spec into line. Filename kept as `F26-avc-ss-oidc.md` to preserve inbound links (e.g.
> NWP-ADR-0031); the *title* is now NWC↔SS.

**Created:** 2026-04-12
**Author:** Robert Karsten Zaar (with AI assistance)
**Priority:** Medium (unblocks cross-site UX for the nwc↔ss Moodle integration)
**Depends On:** F23 (site environment layout) ✅, F21 Phase 2 (mirror-store runner) ✅, sanitizer framework (F21 Phase 6) ✅
**Breaking Changes:** No (new issuer + new client; existing logins untouched until flag flip)
**Estimated Effort:** Medium — ~2 days Drupal issuer setup, ~1 day Moodle client wiring, ~half day sanitizer coupling, ~half day per-MR preview plumbing

---

## 1. Executive Summary

### 1.1 Problem statement

nwc.<example-prod-domain> (Drupal, canonical) and <site>.example.org (Moodle — the ss
Saint School sites, ssc live / ssd demo) are separate
sites with overlapping audiences. A user who already has an nwc
account shouldn't need a second account to access the SS Moodle
courses, and a staff-side change to a user's nwc profile shouldn't
need to be mirrored by hand into Moodle's user table. The current
workaround is that each site has its own authentication, and cross-
site consistency is maintained manually.

This has three concrete pain points:

1. **Double onboarding.** Every new student creates two accounts,
   gets two welcome emails, and then wonders why "I already signed
   up" doesn't let them into the courses.
2. **Drift between `user.mail` and `mdl_user.email`.** A user
   changing their email in Drupal doesn't change it in Moodle, so
   password-reset emails on the Moodle side silently go to the old
   address.
3. **Per-MR preview environments can't test cross-site flows.** A
   preview of an nwc MR has no way to link to a corresponding SS
   preview, because the current auth coupling is "they share the
   production database". That's fine for prod and hostile to CI.

### 1.2 Proposed solution

Make nwc the **OIDC identity provider** and SS a **client** via
well-understood Drupal/Moodle modules:

- **Drupal issuer:** `simple_oauth` (already the canonical choice
  for OAuth2/OIDC on Drupal 10+, and already installed + enabled on
  nwc-dev). Configures nwc's user table as the source of truth.
- **Moodle client:** Moodle core OAuth2 (`\core\oauth2\api`) with a
  thin `auth_nwc` plugin adding the UID-lock. Points at nwc's
  `.well-known/openid-configuration` endpoint, accepts nwc's ID
  tokens, and creates Moodle users on first login. (The legacy
  `auth/avc_oauth2` plugin is avc-branded and has no UID-lock;
  `auth_nwc` supersedes it — see §5.)

The load-bearing design decisions are:

1. **Moodle UID locks to Drupal UID on first match**, via
   `mdl_user.idnumber` being set to the nwc user id (the ID token
   `sub`) on the first OIDC login. After lock, the Moodle account is
   permanently bound to that Drupal account regardless of email
   changes.
2. **Sanitizer emails are deterministic**, so a dev-environment
   Drupal user and the corresponding dev-environment Moodle user
   end up with the same fake email and the OIDC flow works end-to-
   end in sanitized previews: `sha256(real_email || shared_salt)[:16]
   + "@sanitized.test"`.
3. **The shared salt is NOT rotated**, because rotating it would
   break the dev-environment linkage between nwc and SS users every
   time a new sanitizer run happened. This is a deliberate deviation
   from "rotate all salts on a schedule" and is justified in § 4.2.
4. **Per-MR preview environments get their own subdomain per site**:
   `mock-<mr-id>.nwc.<example-prod-domain>` and `mock-<mr-id>.<site>.example.org`.
   A cross-site MR produces *both* URLs and the OIDC flow between
   them is configured at preview-provision time.
5. **TLS for preview subdomains comes from certbot-dns-linode**
   (wildcard cert), **not Cloudflare**. Linode hosts the DNS so
   certbot can use the DNS-01 challenge directly against the Linode
   API; no Cloudflare token is needed and the preview flow doesn't
   require a CDN.

### 1.3 Relationship to NWP-ADR-0017, NWP-ADR-0031, F21, F23

F26 sits entirely inside the dev tier under NWP-ADR-0017 — preview
environments are built on the mirror-store, sanitized fixtures come from the
F21 Phase 6 sanitizer, and the wildcard TLS automation runs on the
mirror-store runner. Prod sites (production nwc + production SS) are
reconfigured at deploy time through the F28 pipeline, not by F26
directly. F23 provides the site environment layout (`sites/nwc/dev`,
`sites/ss/dev`) that the preview provisioning script consumes.
NWP-ADR-0031 is the parent contract for the pair: it names the nwc↔ss
OIDC edge as the **identity rail** (the UID-lock couples ssc's user
state to nwc's site content) and requires the per-environment issuer
URL to become live `.nwp.yml` config (`oauth2:` / `paired_with:`).

## 2. Goals & Non-Goals

### Goals

- A user with an nwc account can click "Log in with nwc" on SS and
  land in Moodle with a matching session, no separate password.
- A user with only an SS account (legacy) can still log in the old
  way during a migration window; new SS accounts require nwc.
- `user.mail` on nwc is the authoritative email address for both
  sites. Changing it on nwc changes it on SS on next login.
- A cross-site MR in CI produces two preview URLs (nwc + ss) that
  are fully OIDC-linked with each other, so a reviewer can actually
  click through the flow before merge.
- Sanitized fixtures preserve the email-based linkage between a
  Drupal user and their Moodle user, without leaking real emails.

### Non-goals

- Not a general SSO for all NWP sites. F26 is the **nwc↔ss pair**
  specifically (ssc↔nwc live, ssd↔nwd demo, per NWP-ADR-0031). Adding a
  *further* site to this SSO graph is out of scope and would require
  a separate proposal. *(The original spec named avc↔ss and treated
  nwc as out of scope; that clause is superseded — avc is frozen and
  nwc is the canonical issuer. The nwc↔ss edge is the very extension
  this proposal now sanctions.)*
- Not a social-login replacement. "Log in with Google" is not in
  scope and is explicitly rejected (NWP-ADR-0017's SaaS stance).
- Not a SAML deployment. OIDC is sufficient and cheaper to
  operate on both sides.
- Not a replacement for Moodle's existing course-access controls.
  OIDC decides *who you are*; Moodle still decides what courses
  you can see.

## 3. Architecture

### 3.1 Trust flow

```
                  ┌──────────────────┐
                  │ user's browser   │
                  └────────┬─────────┘
                           │
                    (1) GET <site>.example.org/some-course
                           │
                           v
                  ┌──────────────────┐
                  │ Moodle (SS)      │
                  │ auth_nwc /       │
                  │ core OAuth2      │
                  └────────┬─────────┘
                           │
                (2) redirect to nwc /oauth/authorize
                           │
                           v
                  ┌──────────────────┐
                  │ Drupal (nwc)     │
                  │ simple_oauth     │
                  │ (source of       │
                  │  truth for user) │
                  └────────┬─────────┘
                           │
                (3) ID token (signed JWT) + access token
                           │
                           v
                  ┌──────────────────┐
                  │ Moodle (SS)      │
                  │ creates/updates  │
                  │ mdl_user,        │
                  │ locks idnumber   │
                  │ to nwc uid       │
                  └──────────────────┘
```

### 3.2 The UID lock

On first OIDC login for a given nwc user id, SS looks for an
existing `mdl_user` row with `idnumber = <nwc_uid>`. If none,
create a new row with `idnumber = <nwc_uid>`, copy email + name
from the ID token, and save. On subsequent logins, look up by
`idnumber` — **not** by email. Email and name may change; the lock
never does.

This is why Moodle's `idnumber` is chosen over `username`:
`username` has historical format constraints that collide with
Drupal's username rules, and `idnumber` is already designed as an
opaque external-system identifier.

If an nwc user is deleted, their Moodle counterpart is **not**
automatically deleted — Moodle course history depends on the user
row existing. Instead, the Moodle user is marked `suspended = 1` on
next login attempt (when the OIDC flow fails to resolve the nwc
uid). An operator can then decide whether to anonymise the account
or leave it suspended.

### 3.3 Sanitized fixtures

The F21 Phase 6 sanitizer produces dev-environment fixtures for
both nwc and SS. For F26 to work in preview environments, both
sanitizers must produce the **same** fake email for the **same**
real user across both sites. The chosen rule:

```
sanitized_email = sha256(real_email + shared_salt)[:16] + "@sanitized.test"
```

Applied identically in the nwc sanitizer (on `users_field_data.mail`)
and in the SS sanitizer (on `mdl_user.email`). The `shared_salt` is
a single value stored outside the fixtures, loaded at sanitizer
run time, and **never rotated** (see § 4.2). The primitive is
already in-tree as `lib/sanitizers/oidc-email.sh` (F26 Phase 3,
committed with passing bats tests).

Because the same real email hashes to the same fake email on both
sides, a preview nwc user with sanitized email
`a1b2c3d4e5f6a7b8@sanitized.test` matches a preview SS user with
the same sanitized email, and the OIDC first-login flow finds or
creates a Moodle row that tracks the corresponding Drupal row.

### 3.4 Per-MR preview environments

When a merge request is opened on nwc or SS (or both simultaneously
as a cross-site change), the mirror-store runner:

1. Provisions `mock-<mr-id>.nwc.<example-prod-domain>` and/or
   `mock-<mr-id>.<site>.example.org` as DDEV projects on the mirror-store.
2. Requests a wildcard cert via `certbot-dns-linode` for
   `*.nwc.<example-prod-domain>` and `*.<site>.example.org` (both held in a
   single Linode zone; the Linode API token has `domains:read_write`
   scope only).
3. Injects the preview URLs into `simple_oauth`'s redirect URI
   allow-list *in the preview instance* — prod's allow-list is
   never touched by CI.
4. Injects the preview nwc's issuer URL into the preview SS's
   OAuth2-service configuration — again, prod SS is never touched.
5. Posts both URLs as a comment on the MR with a note:
   "Cross-site auth preview: click the SS URL, log in with the
   demo nwc credential `demo@sanitized.test` / `demo`, verify that
   your session survives the redirect."
6. Tears everything down on MR merge or close.

Cross-site MRs (one branch on nwc's repo, one on SS's, same MR id)
produce two URLs linked to each other. Single-site MRs produce one
URL linked to a stable shared preview of the other site (named
`mock-main.<site>.<example-prod-domain>`).

### 3.5 Wildcard TLS via Linode DNS (not Cloudflare)

certbot with the `certbot-dns-linode` plugin uses Linode's API to
add a TXT record, wait for propagation, and obtain a wildcard cert.
Requirements:

- A Linode personal access token with `domains:read_write` scope
  (and no other scopes — this is a different token than the
  infrastructure token in `.secrets.yml`, and it lives on the mirror-store only).
- The Linode API token stored in the F21 secret loader on the mirror-store,
  loaded into certbot via its standard credentials-file mechanism.
- Renewal on a mirror-store systemd timer, weekly.

Cloudflare is explicitly **not** used for this flow. Reason: the
DNS already lives at Linode, and adding Cloudflare would create a
new SaaS dependency purely for TLS automation. NWP-ADR-0017's
self-hosted-first rule applies and Cloudflare is not a documented
exception.

## 4. Security posture

### 4.1 OIDC surface

`simple_oauth` on nwc adds an `/oauth/authorize`, `/oauth/token`,
`/oauth/userinfo`, and `.well-known/openid-configuration` route.
These are reachable
from the public internet *for prod nwc* because SS needs to call
them. This is fine: OIDC is designed to be public-facing. The
sensitive part is the signing key, which stays on the nwc host and
never leaves.

Preview environments expose the same endpoints on the
`mock-<mr-id>.nwc.<example-prod-domain>` subdomain. Because each preview has
a freshly generated signing key (generated at DDEV-spin-up time, not
copied from prod), a compromised preview signing key cannot forge
tokens for prod. **This is load-bearing: the provisioning script
must never copy the prod signing key into a preview.**

### 4.2 The non-rotating sanitizer salt

Normally, a deterministic-hashing salt is rotated on a schedule so
that historical hashes stop being useful after a window. Here, the
salt cannot rotate, because the whole point of the hash is to
maintain a stable cross-table linkage between the nwc and SS
sanitized fixtures. If the salt rotated, a dev MR rebased onto a
newer fixture set would see its preview users spontaneously
de-link, and the OIDC flow would break in preview without breaking
in prod — the worst kind of CI drift.

The mitigations:

- The salt lives in `.secrets.data.yml` (NOT `.secrets.yml`), so it
  is gated by the data-secret tier (per CLAUDE.md § Two-Tier Secrets).
  Claude and other AI agents cannot read it.
- The salt is 32 bytes of cryptographic random, so brute-force of
  the preimage given a hash is not computationally feasible for an
  attacker who does not also have the salt.
- Preview environments are firewall-gated: wildcard DNS + Let's
  Encrypt means the URL is guessable, but the DDEV project is only
  accessible from the mirror-store's public interface and is torn down on MR
  close. An attacker would need to race MR lifetime.
- If the salt ever *is* compromised, the recovery is to rotate it
  once and accept that historical fixture archives become unusable.
  That is an acceptable one-time cost; the unacceptable cost is
  rotating it routinely.

### 4.3 Token replay

ID tokens from `simple_oauth` are short-lived (default 10 minutes)
and carry a `nonce` that Moodle's core OAuth2 checks. Access tokens
are also short-lived; refresh tokens are opt-in and are *not* used
in the F26 configuration (Moodle re-authenticates via the OIDC
flow when its session expires).

### 4.4 Review gate

Changes to `simple_oauth` configuration (allowed redirect URIs,
scopes, client secrets, signing key rotation) require **1 human
approver now**, **2 approvers once F26 is live in prod**. Matches
the progression in F27 and keeps the single-reviewer convenience
during the build-out phase.

## 5. Phases

### Phase 1 — Issuer on preview nwc *(reversible, no prod)*

Install and configure `simple_oauth` on a preview nwc provisioned
on the mirror-store. Confirm `.well-known/openid-configuration` is served,
signing key is fresh per-preview, and a test client (a local
`curl` or `requests` script) can complete the authorization code
flow end-to-end. *(Implemented on nwc-dev via
`scripts/f26/provision-nwc-issuer.sh` + `verify-nwc-issuer.sh`.)*

### Phase 2 — Client on preview SS *(reversible, no prod)*

Install and configure the `auth_nwc` client on a preview SS, pointed
at the Phase 1 preview nwc. Log in as a sanitized demo user, verify
the Moodle user row is created with `idnumber = <drupal_uid>`, verify
subsequent logins hit the existing row. *(UID-lock decision logic is
in `scripts/f26/moodle/auth_nwc/`, unit-tested; end-to-end browser
verification needs a Moodle env the operator owns — the nwp!49 build
did not reconfigure a shared ss Moodle site.)*

### Phase 3 — Sanitizer salt primitive

Add a helper `lib/sanitizers/oidc-email.sh` that takes a real
email and returns the sanitized form. Wire it into the nwc
sanitizer and the SS sanitizer so they produce consistent output.
Add a test fixture that asserts both sanitizers produce the same
fake email for the same real input. *(Helper committed; sanitizer
wiring on each side still pending.)*

### Phase 4 — Preview provisioning plumbing

Extend the existing mirror-store preview provisioning (used by `deploy:preview`
in `.gitlab-ci.yml`) to handle F26's cross-site case: detect
cross-site MRs, allocate both subdomains, request (or reuse) the
wildcard cert, inject the redirect URI + issuer URL into both
previews, post the combined URLs as an MR comment. Tear down on
close.

### Phase 5 — Wildcard TLS automation

Install `certbot-dns-linode` on the mirror-store, provision the scoped Linode
API token, set up the weekly renewal timer, verify a preview URL
serves a valid wildcard cert end-to-end.

### Phase 6 — Prod cut-over *(gated by 2 approvers)*

Configure prod nwc as the issuer, prod SS as the client. Announce
the migration window. Flip the flag. Keep the old Moodle-native
login path available for 30 days as a fallback, then remove it.
Per NWP-ADR-0031 D5 the **provider (nwc) promotes first, consumer (ss)
second**; and per NWP-ADR-0031 D6, once real ssc users hold UID-locks
against nwc's live tier, full-DB pushes that renumber nwc live uids
are forbidden (they would sever every SSO identity).

## 6. Open questions

- What happens if an nwc user changes their username (not email)?
  The OIDC ID token doesn't carry the Drupal machine-name, only
  the UID. **Proposed: username changes have no effect on the
  Moodle row, same as email changes.**
- Do we want PKCE? Moodle's core OAuth2 supports it; it's a
  defense-in-depth measure. **Decided: yes — the `ss_moodle` client
  is provisioned PKCE-required (S256).**
- Should preview OIDC issuer signing keys live in the repo
  (checked in as test fixtures) or be generated fresh per preview?
  **Proposed: generated fresh. Checked-in keys are a future foot-
  gun where someone copies them to prod by accident.**

## 7. References

- [NWP-ADR-0017](../decisions/0017-distributed-build-deploy-pipeline.md) — trust boundaries
- [NWP-ADR-0031](../decisions/0031-paired-site-versioning-and-promotion.md) — paired-site contract; the nwc↔ss identity rail
- [F21](F21-distributed-build-deploy-pipeline.md) — mirror-store infrastructure + sanitizer
- [F23](F23-site-environment-layout.md) — site layout dev/stg split
- [F28](F28-unified-pipeline.md) — unified pipeline (consumer of preview plumbing)
- Drupal `simple_oauth`: `https://www.drupal.org/project/simple_oauth`
- Moodle core OAuth2 auth + the `auth_nwc` UID-lock plugin (`scripts/f26/moodle/auth_nwc/`)
- `certbot-dns-linode`: `https://certbot-dns-linode.readthedocs.io/`
</content>
