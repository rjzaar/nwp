## F27: Feedback Ingest — Prod → mmt via Signed Packages

**Status:** PROPOSED
**Created:** 2026-04-12
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** Medium (unblocks closed-loop QA on mayo without opening prod→dev trust)
**Depends On:** F21 Phase 2 (met runner) ✅, F25 (mayo↔NWP integration), F28 (unified pipeline) for the handoff shape
**Breaking Changes:** No (new channel; does not touch existing deploy path)
**Estimated Effort:** Medium — ~1 day for the Packages-upload primitive + met timer, plus ~half day for the Drupal feedback module wiring

---

## 1. Executive Summary

### 1.1 Problem statement

Prod sites currently have no first-class way to send structured
feedback back to dev. When something breaks, a logged-in user might
email Rob, or an error lands in a Drupal watchdog log that nobody
reads until the next audit. There is no channel that:

- lets an end-user flag "this page is wrong" in-context without
  leaving the site,
- lets prod ship that report back to the dev environment with
  enough metadata to reproduce,
- preserves ADR-0017's trust posture — no AI-accessible host may
  hold a credential that reaches prod, and the mons boundary is
  inviolable in *both* directions.

The last constraint is the hard one. The obvious architectures
(prod → webhook → met, prod → SSH into met, prod → IMAP → parse)
all either open a hole from prod back into dev, or bolt on a
credential that prod must protect in perpetuity. Neither is
acceptable for a mayo-scale deployment where feedback volume is
low but authenticity matters.

### 1.2 Proposed solution

Prod writes feedback items to **GitLab Packages API** on
`git.nwpcode.org`, using a write-only Packages-API token scoped to a
single repository and a single package name. A met systemd timer
polls for new packages, converts each one into a GitLab issue in the
project's issue tracker, and closes the package. The token on prod
has **no** ability to read issues, read code, or write anywhere
outside the one package path — it cannot be used to exfiltrate, only
to deposit.

This is **option (i)** from the Q11 discussion (approved). The
alternatives considered and rejected were:

- **(ii) IMAP mailbox on met.** Works, but reintroduces email as a
  control path and requires parsing untrusted MIME in a shell
  environment. Rejected.
- **(iii) Prod-to-mini push over Headscale.** Requires mini to be a
  receiver on a path prod can reach, which pokes a hole in the
  "prod only talks to mons via WireGuard" rule. Rejected.
- **(iv) Manual CSV export.** Loses the closed loop, defeats the
  point. Rejected.

Option (i) keeps prod strictly *outbound HTTPS* and keeps all
ingestion logic on met, where AI access is already permitted under
ADR-0017.

### 1.3 Relationship to F28, F25, ADR-0017

F27 is a *consumer* of the F28 handoff shape (signed artifacts
travelling through GitLab Packages) applied in the reverse
direction: F28 moves build → mons → prod, F27 moves prod → met. The
signing, verification, and package-naming conventions are shared so
the two pipelines can reuse `lib/minisign.sh` and the Packages API
client wrapper. F25 is the first real tenant — mayostudios.org is
where the feedback button will first appear.

## 2. Goals & Non-Goals

### Goals

- A logged-in end-user on a mayo prod site can click "Report a
  problem on this page", write a short message, and submit.
- The submission reaches a met-hosted GitLab issue within the polling
  interval (target: ≤ 5 minutes) with enough context to reproduce:
  URL, user id (hashed, not raw — see § 4.3), Drupal version,
  user-agent, a short free-text message, and a server-side
  correlation ID that links to the prod watchdog log line.
- The channel is one-way (prod → met). There is no path from met
  back to prod triggered by a feedback submission. Replies, if any,
  happen out-of-band once the bug is fixed and a release is cut.
- The Packages token on prod can be revoked in one click without
  disabling any other prod function.
- Prod never sees an issue tracker, an API for reading issues, or
  any git contents. It only knows how to POST to one endpoint.

### Non-goals

- Not a bug bounty channel. The feedback button is visible only to
  logged-in users.
- Not an incident-response pager. For that, see F22 (Gotify) and the
  mons alerting path.
- Not a support ticketing system. If volume grows past what a GitLab
  issue tracker handles comfortably, F27 will be *extended* (new
  consumer on the met side), not replaced.
- Not a data-collection channel. The sanitizer in the other direction
  (F26 etc.) is about *removing* PII from prod→dev data flows; F27
  must be held to the same standard for the small amount of context
  it carries.

## 3. Architecture

### 3.1 Components

```
[Drupal feedback module]  --write--> [prod disk queue]
        (on prod)                          |
                                           v
                                [feedback-publisher cron]
                                (on prod; runs hourly or on
                                 submit, packages the queue,
                                 minisigns it, POSTs to Packages)
                                           |
                                           v  HTTPS (443 only)
                                  git.nwpcode.org
                                  Packages registry:
                                  feedback/<site>/<ts>.tar.gz
                                           |
                                           v  systemd timer (5 min)
                                [met: feedback-ingest]
                                (downloads new packages, verifies
                                 minisig, extracts, creates issues,
                                 closes packages)
                                           |
                                           v
                                GitLab issue tracker
                                  group/<site>#<nnn>
```

### 3.2 Credentials, step by step

1. **Drupal feedback module** writes to a local queue dir owned by
   `www-data`. Holds no credentials.
2. **`feedback-publisher`** runs as an unprivileged `feedback`
   user (not www-data, not root). Reads two secrets from
   `/etc/nwp/feedback.env`:
   - `FEEDBACK_TOKEN` — GitLab personal access token with
     **`write_package_registry` scope only**. Scoped to one project.
     No `api`, no `read_api`, no `read_repository`.
   - `FEEDBACK_SIGNING_KEY` — minisign secret key, passphrase-wrapped.
     Passphrase held in a Drupal-readable sidecar that only
     `feedback-publisher` can decrypt (via a boot-time unlock).
3. **git.nwpcode.org** enforces the token scope at GitLab's edge. An
   attacker who steals the token cannot list projects, read code,
   or open issues.
4. **met `feedback-ingest`** runs as the `gitlab-runner` user and
   holds a *separate* token with `api` scope on the same project
   — this is the high-privilege token, but it lives on met (AI-
   accessible, inside Headscale), not on prod.
5. **Signature verification on met** is load-bearing: an attacker
   who somehow uploaded an unsigned package would produce a met
   issue titled "SIGNATURE INVALID — possible tampering", which is
   the only thing the ingest pipeline will do with an untrusted
   payload.

### 3.3 Package format

Each upload is a tarball containing:

```
feedback-<site>-<ts>/
├── manifest.json        # schema-versioned, signed
├── items/
│   ├── 0001.json        # one feedback item
│   ├── 0002.json
│   └── ...
└── manifest.json.minisig
```

`manifest.json` fields: `site`, `generated_at`, `count`,
`publisher_host`, `schema_version`. Each `items/*.json` carries:
`submitted_at`, `url`, `user_ref` (hashed — see § 4.3),
`drupal_version`, `user_agent`, `message`, `correlation_id`.

No raw email, no raw username, no IP address. The hashed `user_ref`
is deterministic per-site per-salt so a met maintainer can cluster
reports from the same user without knowing who they are.

## 4. Security posture

### 4.1 Prod → dev trust boundary

F27 respects ADR-0017 by having prod *write to a public-HTTPS
endpoint* rather than *open a port*. The path from prod looks
identical to any outbound HTTPS call Drupal already makes (composer
update, update.php, etc.). No new inbound surface on prod, no new
Headscale membership, no new VPN, no new systemd socket.

### 4.2 Token compromise

The worst case if `FEEDBACK_TOKEN` is stolen from prod:

- Attacker can upload junk packages to the one feedback project on
  `git.nwpcode.org`. The met ingest timer will try to verify them,
  the signatures will fail (signing key is separate and not exposed
  by the token path), and met will create a flood of "SIGNATURE
  INVALID" issues. That is loud, not silent.
- Attacker **cannot** read any code, any issue, any other package,
  any other project. GitLab enforces scope at the API layer.
- Recovery is one token revoke + one reissue.

### 4.3 User identification

`user_ref = sha256(site_salt || raw_user_id)[:16]`. The `site_salt`
is per-site, generated at feedback-module install time, and lives on
prod only. This is **not** the same salt used by F26's OIDC email
sanitiser — these salts must never converge, because F26's purpose
is cross-site linking (AVC↔SS) and F27's purpose is the opposite:
making a user's feedback un-linkable to anything else about them.

### 4.4 Review gate

Feedback pages-to-deploy changes (the feedback module itself, the
publisher script, the token provisioning) require **1 human approval
now**, with a note to escalate to **2 approvers once F27 carries
traffic from more than one prod site**. This matches the progression
used by F26 and keeps the single-reviewer convenience during the
mayo-only phase.

## 5. Phases

### Phase 1 — Publisher primitive *(reversible, no prod changes)*

Build `lib/packages-upload.sh` as a wrapper around `curl` + the
GitLab Packages API, plus a dry-run mode that just prints the
request. Smoke-test against a throwaway project on
`git.nwpcode.org`. No prod touched. No Drupal touched.

### Phase 2 — met ingest timer *(reversible, met only)*

Build `servers/met/bin/feedback-ingest` + a systemd timer running
every 5 minutes. Downloads new packages, verifies minisig, extracts
items, creates issues, closes the package. All visible on met;
nothing leaves the home LAN except the GitLab API calls.

Smoke-test by uploading hand-crafted test packages from a laptop
(not from prod yet).

### Phase 3 — Drupal feedback module *(mayo only, gated)*

Ship a Drupal module `nwp_feedback` that adds a per-page "Report a
problem" link for logged-in users, writes items to a local queue,
and exposes a drush command to run the publisher. Initial rollout:
mayostudios.org only, behind a config flag.

### Phase 4 — Token provisioning + cron *(first-use gate)*

Create the `write_package_registry`-only token, install
`/etc/nwp/feedback.env`, enable the publisher cron. This is the
first moment prod actually holds a credential that leaves prod, so
it requires explicit human approval (1 approver).

### Phase 5 — First real submission + dogfood

Rob (as a logged-in mayo user) files the first feedback item on
mayostudios.org. The full chain from click → met issue is exercised
end-to-end. Close the loop in the issue tracker, confirm no stray
credentials leaked to the issue body.

### Phase 6 — Second site rollout *(triggers 2-approver gate)*

When `saintschool.mayostudios.org` is ready (see "mayo Linode sites
scope" memory), add it as the second tenant. This is the trigger to
raise the review gate from 1 approver to 2, per § 4.4.

## 6. Open questions

- Does the publisher run on a cron or on-submit? Cron is simpler and
  batches uploads; on-submit is faster but makes every feedback
  submission synchronous on a slow GitLab API. **Proposed default:
  hourly cron with a 5-item flush threshold — a burst uploads
  immediately, a trickle waits up to an hour.**
- Does F27 need its own project on `git.nwpcode.org`, or does it
  attach to each site's existing project? **Proposed: each site gets
  a dedicated `nwp-feedback/<site>` project, separate from the code
  project, so the write-only token can't even name the code
  repository.**
- What happens when a feedback item contains a secret the user
  pasted in by mistake (API key, password)? **Proposed: met-side
  scrubber with the same regex set as F26's sanitizer, running on
  the item body before issue creation. First offence: issue is
  created with the body redacted and the original stored in an
  ops-only location. Second offence from same user_ref: rate-limit.**

## 7. References

- [ADR-0017](../decisions/0017-distributed-build-deploy-pipeline.md) — trust boundaries
- [F21](F21-distributed-build-deploy-pipeline.md) — met runner infrastructure
- [F25](F25-mayo-nwp-integration.md) — mayo integration (first tenant)
- [F28](F28-unified-pipeline.md) — signed-artifact handoff shape (shared with F27)
- GitLab Packages API: `https://docs.gitlab.com/ee/user/packages/`
