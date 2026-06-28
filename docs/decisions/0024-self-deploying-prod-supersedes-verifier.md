# ADR-0024: Self-Deploying Prod via Linode-Resident Runner (supersedes the verifier deploy model)

**Status:** Accepted (decision A14 accepted by operator 2026-06-28; operational wiring gated on the linchpin — least-privilege tokens / Developer-only bot users complete)
**Date:** 2026-06-25 (accepted 2026-06-28)
**Decision Makers:** Robert Karsten Zaar (with AI assistance)
**Related Issues:** —
**References:** [ADR-0017](0017-distributed-build-deploy-pipeline.md) (amends its deploy-authority half), [ADR-0019](0019-verifier-always-on-hardware-rooted-keys.md) (**supersedes, before implementation**), [ADR-0004](0004-two-tier-secrets-architecture.md), [F21](../proposals/F21-distributed-build-deploy-pipeline.md), [F28](../proposals/F28-unified-pipeline.md); reeval `07-PIPELINE-EXPLAINER §9–§10`, `08-VISION…CONTROL-PLANE Part III-A & IV`, `09-PROGRESS §3`; decision A14.

> **0023 is reserved** for the AI Confidentiality Boundary (P67); this ADR takes 0024.

## Context

ADR-0017 established a **verifier** as the sole prod-writer:
an AI-free host that verifies minisign signatures and deploys to prod.
ADR-0019 (Proposed, never implemented) revised the verifier to be always-on
with prod keys on a Solo 2C+ hardware token, touch-per-deploy — to fix the
"critical Drupal patch drops while operator is travelling" latency problem.

Two things have since clarified the design (reeval 07 §8–§10, 09 §3):

1. **The operator's actual aim is phone approval of updates.** ADR-0019 tried
   to satisfy this with "phone-as-deploy-client" (its *Deploy client forms* §3:
   phone runs an SSH client + Headscale + taps the Solo via NFC to authorise an
   `ed25519-sk` SSH deploy). On closer inspection this hardware path is weak:
   the Solo 2C+ is **FIDO2/WebAuthn-first**, and NFC-tapping it reliably drives
   **browser WebAuthn logins, not mobile-SSH `ed25519-sk` deploys**. The phone-
   NFC-SSH-deploy form was built on a capability that doesn't pan out in
   practice.
2. **A simpler model removes prod credentials from *every* machine** rather than
   guarding them on one. If a **protected GitLab Runner runs on the prod Linode
   itself**, prod can deploy *to itself* (`git pull` the reviewed/merged ref +
   `pl stg2live`, locally). Then no prod-write credential exists off-box at all —
   there is nothing for an AI host, a stolen laptop, or a lost token to leak.
   The approval the operator wants becomes a **GitLab action** (review the diff
   in the PWA → merge → tap the manual ▶ job), and GitLab WebAuthn — which the
   Solo *does* do well over NFC — is the phone-native gate.

This reframes the deploy boundary (decision A14): authority shifts from "a
physical token touch on a deploy host" to "the right to merge to protected main
/ run the ▶ job in GitLab." That shift is only safe under a hard precondition
(the linchpin, below). This ADR records the model and that precondition.

## Options Considered

### Option 1: Hardware-token verifier (ADR-0017 + ADR-0019 as written)
An AI-free always-on verifier holds the prod key on a Solo 2C+; deploys
require a per-use touch; the phone deploys via NFC+SSH (form 3).
- **Pros:** offline signature re-verification — a compromised GitLab *cannot*
  forge a deploy; prod credential isolated on one hardened, AI-free box; the
  strongest posture against "compromised build tier ships a bad artifact."
- **Cons:** the phone-NFC-SSH-deploy form doesn't work as imagined (see Context);
  builds, hardens, and maintains a whole extra machine for a solo operator;
  prod credential still *exists* (on the token/box) and must be guarded; large
  complexity budget for the current stakes (low-traffic CC0 community sites).

### Option 2: Solo-on-dev (interim floor, 07 §8.2)
Prod key as a touch-gated `ed25519-sk` on dev; touch per deploy; no separate
verifier; deferred-on-trigger.
- **Pros:** makes *unattended* deploys impossible estate-wide with ~1 evening of
  work; no new machine.
- **Cons:** an sk-token on an **AI host** has a consent-confusion gap — "the
  touch approves whatever the host asked for, not what you think you're
  approving"; not phone-native (the deploy still originates from dev); a prod-
  reaching credential still lives on an AI-reachable machine.

### Option 3: Self-deploying prod via a protected Linode-resident runner *(chosen)*
A protected, tagged `prod-deploy` GitLab Runner runs **on the prod Linode**.
Merging to protected main (and/or tapping a manual ▶ job) triggers it; the runner
does a **fixed** `git pull <reviewed ref> + pl stg2live`, locally. No prod-write
credential exists on any off-box machine. Approval/merge is gated by GitLab
WebAuthn (Solo as the authenticator), doable from the phone PWA.
- **Pros:** **no off-box prod credential anywhere** (nothing to leak from dev,
  a lost token, or a stolen laptop); **phone-native approval** via WebAuthn
  (the Solo capability that actually works over NFC); the deployed artifact = the
  exact commit the operator reviewed and merged, so intent↔execution is tight (no
  screenless-token consent gap); **enables same-day emergency patching from a
  phone** (the patch-cadence top tier, feasible for a solo operator); removes a
  whole machine (the verifier host) and its hardening/maintenance burden; simpler.
- **Cons:** **GitLab becomes the deploy-authority root** — a GitLab compromise
  can now reach prod, whereas Option 1's offline re-verification would have
  blocked it; the prod box hosts its own deploy executor; **no offline signature
  re-verification.** These are acceptable at current stakes *with* the guards
  below, and are the explicit escalation triggers back to Option 1.

## Decision

**Adopt Option 3.** Production deploys itself via a protected, tagged
`prod-deploy` GitLab Runner resident on the prod Linode. The authority to
trigger a production deploy is **the right to merge to protected main and/or run
the manual ▶ job in GitLab**, gated by WebAuthn (the Solo 2C+ as authenticator).
**No prod-write credential exists on any machine off the prod box.**

**ADR-0019 is Superseded (before implementation) by this ADR.** The always-on
hardware-token verifier is not built. **the verifier host is held in reserve as the high-
stakes escalation** (see triggers below), not as the default deploy path.

**This amends ADR-0017's deploy-authority half:** "the verifier is the sole
prod-writer" → "prod is its own deployer; trust still flows through review +
protected-merge + CI gates, and no off-box host holds a prod credential." The
following ADR-0017/0019 properties **remain inviolable**:
- **No AI on the prod-write path.** The runner executes a fixed, non-AI script;
  no agent, no LLM, no Claude session may trigger or alter a prod deploy.
- **No prod reachability from any AI-capable host.** no AI host holds a
  prod key or a Maintainer/api GitLab token.
- **Sanitisation stays on prod;** raw user data never leaves prod.
- **Human presence gates prod.** Presence is now established by a WebAuthn-gated
  merge/▶, not a token touch on a deploy host.

### The linchpin (the precondition that makes this sound)
**No `api`- or `Maintainer`-scope GitLab token may live on any AI-reachable
machine.** Bot/role tokens are **Developer-role only**. The operator's
merge/deploy power lives solely in a browser/phone **WebAuthn** session, never in
a file. Enforced during credential rotation (A1) and encoded in the tokenless
`secrets-registry.yml` (every `gitlab_bot_*` entry: `scopes: [read_repository]`,
A14). Without this, "merge/▶ rights = deploy authority" is hollow, because an
AI host holding a powerful token could merge and deploy.

### The three guards (conditions of adoption)
1. **Linchpin** (above): no powerful GitLab token on AI hosts; WebAuthn for all
   human GitLab auth (Solo as authenticator).
2. **Protected, minimal runner:** the runner is registered protected + tagged
   `prod-deploy`, runs **only** on protected-branch/▶ pipelines, and executes a
   **fixed** deploy script (`git pull` the merged ref + `pl stg2live`) — never an
   arbitrary job. Protected branch: merge = operator only; blocking CI gates
   (test suite + K2a CC0 suite + a `check-approval` job).
3. **GitLab joins the critical-patch top tier.** Because GitLab is now the
   deploy-authority root, a self-hosted GitLab security advisory is a **Highly
   Critical / same-day** patch event (see the patch-cadence policy). Keep GitLab
   itself current; WebAuthn-only admin.

### Escalation triggers — when to reintroduce the verifier / Option 1
Build the AI-free verifier with offline signature re-verification if **any** of:
- a **second deployer** with weaker/unknown opsec is onboarded (the merge/▶ gate
  then protects less);
- prod takes on **PII-heavy, financial, or otherwise high-trust load** where a
  GitLab-mediated compromise would be materially worse;
- a **GitLab trust failure** (RCE, supply-chain, or a credible threat to the
  self-hosted instance) makes "trust GitLab to authorise deploys" untenable;
- a **regulatory/contractual** requirement for offline-verified deploys appears;
- the estate grows to **many independent high-value sites** where blast radius
  compounds.

## Rationale

This is the **maturity / inverse-stakes principle** (08 §2/§13, Part IV) applied
to deploy authority: at the project's current stakes — a solo operator, low-
traffic CC0 community sites, no financial/PII-critical load — the simpler model
that *removes* prod credentials everywhere beats the more complex model that
*guards* them on one box. Option 1's distinctive value (offline re-verification
defeating a compromised git server) is real but is a **higher-stakes** defence;
it is recorded as an escalation, not discarded as wrong.

The intent↔execution gap that worried ADR-0019 is closed *better* here than by a
screenless token: the operator approves a **specific reviewed diff** and the
runner deploys **that exact merged commit** — there is no opaque "the host asked
for X, you thought it was Y" step. And it finally makes the operator's real aim —
**approve an update from the phone** — work with the hardware that actually
exists (WebAuthn over NFC), rather than the SSH-over-NFC path that doesn't.

## Consequences

### Positive
- Phone-native approval; emergency Highly-Critical/PSA patches can be reviewed,
  merged, and deployed from a phone with no dev machine and no token-for-SSH.
- No prod-write credential exists off the prod box — nothing to leak from dev,
  a lost token, or a stolen laptop.
- The verifier host and its hardening/maintenance burden are removed from the build path.
- Deployed artifact = reviewed+merged commit (tight intent↔execution).

### Negative / residual risk
- GitLab is the deploy-authority root; a GitLab compromise can reach prod (no
  offline re-verification). Mitigated by WebAuthn, protected branch, the fixed
  runner, and GitLab-in-the-top-patch-tier — not eliminated.
- The prod box hosts its own deploy executor (acceptable: if prod is already
  compromised, the game is lost regardless).

### Neutral / relationship to site maturity (08 Part IV)
- **Incubating** sites: the runner may auto-deploy on merge with **no approval
  gate** (disposable, no public trust).
- **Production** sites: deploys require the WebAuthn-gated merge/▶ approval. This
  ADR governs the production-tier path.

## Implementation Notes
Not live until all complete (partial adoption — e.g. the runner without the
linchpin — is forbidden, as it would let an AI-host token deploy):
- [ ] **Linchpin first:** during A1 rotation, reissue all bot/role GitLab tokens
      as Developer-scope; confirm no `api`/`Maintainer` token on any AI host;
      `secrets-registry.yml` reflects `scopes: [read_repository]` for `gitlab_bot_*`.
- [ ] WebAuthn (Solo 2C+) enrolled for the operator's GitLab account; password+2FA
      hardened; a second Solo enrolled as backup.
- [ ] Protected main: merge = operator only; blocking CI = test suite + K2a CC0
      suite + `check-approval`.
- [ ] Register the protected, tagged `prod-deploy` runner **on the prod Linode**;
      it runs only on protected-branch/▶ pipelines.
- [ ] Wrap existing `pl stg2live` in a fixed, manual ▶ deploy job (tappable from
      the GitLab PWA); the job deploys only the merged ref, logs the SHA+target,
      and pushes a signed deploy-audit record to the `ctl`/GitLab audit ledger.
- [ ] End-to-end test from the phone with a trivial change.
- [ ] Update `ADR-0019` status → Superseded by ADR-0024; update CLAUDE.md
      Distributed Actor Glossary (the verifier host → "reserve / escalation only"; add the
      prod-deploy runner + linchpin); record the ADR-0017 deploy-authority
      amendment in its header.
- [ ] Pair with K2a (wire nwd as the CC0 approval surface) so the approval flow
      has something real to exercise.

## Review
**30-day review date:** 2026-07-25
**Review criteria:** Is the linchpin actually true (no powerful token on any AI
host)? Has a phone-approved deploy run end-to-end? Is the runner restricted to
the fixed deploy job? Has a GitLab SA been treated as a top-tier patch?
**Review outcome:** Pending
**Rollback / escalation:** if any escalation trigger fires, build the ADR-0019
verifier (the Solo tokens are already in hand) and move prod authority back
off-GitLab.
