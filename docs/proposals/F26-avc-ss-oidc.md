## F26: AVC↔SS OIDC Single Sign-On

**Status:** PROPOSED
**Created:** 2026-04-12
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** Medium (unblocks cross-site UX for the AVC Moodle integration)
**Depends On:** F23 (site environment layout) ✅, F21 Phase 2 (met runner) ✅, sanitizer framework (F21 Phase 6)
**Breaking Changes:** No (new issuer + new client; existing logins untouched until flag flip)
**Estimated Effort:** Medium — ~2 days Drupal issuer setup, ~1 day Moodle client wiring, ~half day sanitizer coupling, ~half day per-MR preview plumbing

---

## 1. Executive Summary

### 1.1 Problem statement

avc.nwpcode.org (Drupal) and ss.nwpcode.org (Moodle) are separate
sites with overlapping audiences. A user who already has an AVC
account shouldn't need a second account to access the SS Moodle
courses, and a staff-side change to a user's AVC profile shouldn't
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
   preview of an AVC MR has no way to link to a corresponding SS
   preview, because the current auth coupling is "they share the
   production database". That's fine for prod and hostile to CI.

### 1.2 Proposed solution

Make AVC the **OIDC identity provider** and SS a **client** via
well-understood Drupal/Moodle modules:

- **Drupal issuer:** `simple_oauth` (already the canonical choice
  for OAuth2/OIDC on Drupal 10+). Configures AVC's user table as
  the source of truth.
- **Moodle client:** `auth_oidc` (core-supported, widely deployed).
  Points at the AVC `.well-known/openid-configuration` endpoint,
  accepts AVC's ID tokens, and creates Moodle users on first login.

The load-bearing design decisions are:

1. **Moodle UID locks to Drupal UID on first match**, via
   `mdl_user.idnumber` being set to the AVC user id on the first
   OIDC login. After lock, the Moodle account is permanently bound
   to that Drupal account regardless of email changes.
2. **Sanitizer emails are deterministic**, so a dev-environment
   Drupal user and the corresponding dev-environment Moodle user
   end up with the same fake email and the OIDC flow works end-to-
   end in sanitized previews: `sha256(real_email || shared_salt)[:16]
   + "@sanitized.test"`.
3. **The shared salt is NOT rotated**, because rotating it would
   break the dev-environment linkage between AVC and SS users every
   time a new sanitizer run happened. This is a deliberate deviation
   from "rotate all salts on a schedule" and is justified in § 4.2.
4. **Per-MR preview environments get their own subdomain per site**:
   `mock-<mr-id>.avc.nwpcode.org` and `mock-<mr-id>.ss.nwpcode.org`.
   A cross-site MR produces *both* URLs and the OIDC flow between
   them is configured at preview-provision time.
5. **TLS for preview subdomains comes from certbot-dns-linode**
   (wildcard cert), **not Cloudflare**. Linode hosts the DNS so
   certbot can use the DNS-01 challenge directly against the Linode
   API; no Cloudflare token is needed and the preview flow doesn't
   require a CDN.

### 1.3 Relationship to ADR-0017, F21, F23

F26 sits entirely inside the dev tier under ADR-0017 — preview
environments are built on met, sanitized fixtures come from the
F21 Phase 6 sanitizer, and the wildcard TLS automation runs on the
met runner. Prod sites (production AVC + production SS) are
reconfigured at deploy time through the F28 pipeline, not by F26
directly. F23 provides the site environment layout (`sites/avc/dev`,
`sites/ss/dev`) that the preview provisioning script consumes.

## 2. Goals & Non-Goals

### Goals

- A user with an AVC account can click "Log in with AVC" on SS and
  land in Moodle with a matching session, no separate password.
- A user with only an SS account (legacy) can still log in the old
  way during a migration window; new SS accounts require AVC.
- `user.mail` on AVC is the authoritative email address for both
  sites. Changing it on AVC changes it on SS on next login.
- A cross-site MR in CI produces two preview URLs (avc + ss) that
  are fully OIDC-linked with each other, so a reviewer can actually
  click through the flow before merge.
- Sanitized fixtures preserve the email-based linkage between a
  Drupal user and their Moodle user, without leaking real emails.

### Non-goals

- Not a general SSO for all NWP sites. F26 is AVC↔SS specifically.
  Adding another site to this SSO graph is out of scope and would
  require a separate proposal.
- Not a social-login replacement. "Log in with Google" is not in
  scope and is explicitly rejected (ADR-0017's SaaS stance).
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
                    (1) GET ss.nwpcode.org/some-course
                           │
                           v
                  ┌──────────────────┐
                  │ Moodle (SS)      │
                  │ auth_oidc        │
                  └────────┬─────────┘
                           │
                (2) redirect to AVC /oauth/authorize
                           │
                           v
                  ┌──────────────────┐
                  │ Drupal (AVC)     │
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
                  │ to AVC uid       │
                  └──────────────────┘
```

### 3.2 The UID lock

On first OIDC login for a given AVC user id, SS looks for an
existing `mdl_user` row with `idnumber = <avc_uid>`. If none,
create a new row with `idnumber = <avc_uid>`, copy email + name
from the ID token, and save. On subsequent logins, look up by
`idnumber` — **not** by email. Email and name may change; the lock
never does.

This is why Moodle's `idnumber` is chosen over `username`:
`username` has historical format constraints that collide with
Drupal's username rules, and `idnumber` is already designed as an
opaque external-system identifier.

If an AVC user is deleted, their Moodle counterpart is **not**
automatically deleted — Moodle course history depends on the user
row existing. Instead, the Moodle user is marked `suspended = 1` on
next login attempt (when the OIDC flow fails to resolve the AVC
uid). An operator can then decide whether to anonymise the account
or leave it suspended.

### 3.3 Sanitized fixtures

The F21 Phase 6 sanitizer produces dev-environment fixtures for
both AVC and SS. For F26 to work in preview environments, both
sanitizers must produce the **same** fake email for the **same**
real user across both sites. The chosen rule:

```
sanitized_email = sha256(real_email + shared_salt)[:16] + "@sanitized.test"
```

Applied identically in the AVC sanitizer (on `users_field_data.mail`)
and in the SS sanitizer (on `mdl_user.email`). The `shared_salt` is
a single value stored outside the fixtures, loaded at sanitizer
run time, and **never rotated** (see § 4.2).

Because the same real email hashes to the same fake email on both
sides, a preview AVC user with sanitized email
`a1b2c3d4e5f6a7b8@sanitized.test` matches a preview SS user with
the same sanitized email, and the OIDC first-login flow finds or
creates a Moodle row that tracks the corresponding Drupal row.

### 3.4 Per-MR preview environments

When a merge request is opened on AVC or SS (or both simultaneously
as a cross-site change), the met runner:

1. Provisions `mock-<mr-id>.avc.nwpcode.org` and/or
   `mock-<mr-id>.ss.nwpcode.org` as DDEV projects on met.
2. Requests a wildcard cert via `certbot-dns-linode` for
   `*.avc.nwpcode.org` and `*.ss.nwpcode.org` (both held in a
   single Linode zone; the Linode API token has `domains:read_write`
   scope only).
3. Injects the preview URLs into `simple_oauth`'s redirect URI
   allow-list *in the preview instance* — prod's allow-list is
   never touched by CI.
4. Injects the preview AVC's issuer URL into the preview SS's
   `auth_oidc` configuration — again, prod SS is never touched.
5. Posts both URLs as a comment on the MR with a note:
   "Cross-site auth preview: click the SS URL, log in with the
   demo AVC credential `demo@sanitized.test` / `demo`, verify that
   your session survives the redirect."
6. Tears everything down on MR merge or close.

Cross-site MRs (one branch on AVC's repo, one on SS's, same MR id)
produce two URLs linked to each other. Single-site MRs produce one
URL linked to a stable shared preview of the other site (named
`mock-main.<site>.nwpcode.org`).

### 3.5 Wildcard TLS via Linode DNS (not Cloudflare)

certbot with the `certbot-dns-linode` plugin uses Linode's API to
add a TXT record, wait for propagation, and obtain a wildcard cert.
Requirements:

- A Linode personal access token with `domains:read_write` scope
  (and no other scopes — this is a different token than the
  infrastructure token in `.secrets.yml`, and it lives on met only).
- The Linode API token stored in the F21 secret loader on met,
  loaded into certbot via its standard credentials-file mechanism.
- Renewal on a met systemd timer, weekly.

Cloudflare is explicitly **not** used for this flow. Reason: the
DNS already lives at Linode, and adding Cloudflare would create a
new SaaS dependency purely for TLS automation. ADR-0017's
self-hosted-first rule applies and Cloudflare is not a documented
exception.

## 4. Security posture

### 4.1 OIDC surface

`simple_oauth` on AVC adds an `/oauth/authorize`, `/oauth/token`,
and `.well-known/openid-configuration` route. These are reachable
from the public internet *for prod AVC* because SS needs to call
them. This is fine: OIDC is designed to be public-facing. The
sensitive part is the signing key, which stays on the AVC host and
never leaves.

Preview environments expose the same endpoints on the
`mock-<mr-id>.avc.nwpcode.org` subdomain. Because each preview has
a freshly generated signing key (generated at DDEV-spin-up time, not
copied from prod), a compromised preview signing key cannot forge
tokens for prod. **This is load-bearing: the provisioning script
must never copy the prod signing key into a preview.**

### 4.2 The non-rotating sanitizer salt

Normally, a deterministic-hashing salt is rotated on a schedule so
that historical hashes stop being useful after a window. Here, the
salt cannot rotate, because the whole point of the hash is to
maintain a stable cross-table linkage between the AVC and SS
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
  accessible from met's public interface and is torn down on MR
  close. An attacker would need to race MR lifetime.
- If the salt ever *is* compromised, the recovery is to rotate it
  once and accept that historical fixture archives become unusable.
  That is an acceptable one-time cost; the unacceptable cost is
  rotating it routinely.

### 4.3 Token replay

ID tokens from `simple_oauth` are short-lived (default 10 minutes)
and carry a `nonce` that Moodle's `auth_oidc` checks. Access tokens
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

### Phase 1 — Issuer on preview AVC *(reversible, no prod)*

Install and configure `simple_oauth` on a preview AVC provisioned
on met. Confirm `.well-known/openid-configuration` is served,
signing key is fresh per-preview, and a test client (a local
`curl` or `requests` script) can complete the authorization code
flow end-to-end.

### Phase 2 — Client on preview SS *(reversible, no prod)*

Install and configure `auth_oidc` on a preview SS, pointed at the
Phase 1 preview AVC. Log in as a sanitized demo user, verify the
Moodle user row is created with `idnumber = <drupal_uid>`, verify
subsequent logins hit the existing row.

### Phase 3 — Sanitizer salt primitive

Add a helper `lib/sanitizers/oidc-email.sh` that takes a real
email and returns the sanitized form. Wire it into the AVC
sanitizer and the SS sanitizer so they produce consistent output.
Add a test fixture that asserts both sanitizers produce the same
fake email for the same real input.

### Phase 4 — Preview provisioning plumbing

Extend the existing met preview provisioning (used by `deploy:preview`
in `.gitlab-ci.yml`) to handle F26's cross-site case: detect
cross-site MRs, allocate both subdomains, request (or reuse) the
wildcard cert, inject the redirect URI + issuer URL into both
previews, post the combined URLs as an MR comment. Tear down on
close.

### Phase 5 — Wildcard TLS automation

Install `certbot-dns-linode` on met, provision the scoped Linode
API token, set up the weekly renewal timer, verify a preview URL
serves a valid wildcard cert end-to-end.

### Phase 6 — Prod cut-over *(gated by 2 approvers)*

Configure prod AVC as the issuer, prod SS as the client. Announce
the migration window. Flip the flag. Keep the old Moodle-native
login path available for 30 days as a fallback, then remove it.

## 6. Open questions

- What happens if an AVC user changes their username (not email)?
  The OIDC ID token doesn't carry the Drupal machine-name, only
  the UID. **Proposed: username changes have no effect on the
  Moodle row, same as email changes.**
- Do we want PKCE? Moodle's `auth_oidc` supports it; it's a
  defense-in-depth measure. **Proposed: yes, enable PKCE — it's
  free and closes a class of code-interception attacks.**
- Should preview OIDC issuer signing keys live in the repo
  (checked in as test fixtures) or be generated fresh per preview?
  **Proposed: generated fresh. Checked-in keys are a future foot-
  gun where someone copies them to prod by accident.**

## 7. References

- [ADR-0017](../decisions/0017-distributed-build-deploy-pipeline.md) — trust boundaries
- [F21](F21-distributed-build-deploy-pipeline.md) — met infrastructure + sanitizer
- [F23](F23-site-environment-layout.md) — site layout dev/stg split
- [F28](F28-unified-pipeline.md) — unified pipeline (consumer of preview plumbing)
- Drupal `simple_oauth`: `https://www.drupal.org/project/simple_oauth`
- Moodle `auth_oidc`: bundled in Moodle core as an auth plugin
- `certbot-dns-linode`: `https://certbot-dns-linode.readthedocs.io/`
