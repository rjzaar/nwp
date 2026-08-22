# NWP-ADR-0028: ver as a single-operator, human-gated desktop workstation

> **Numbering note (2026-07-09).** This ADR took the next sequential number, 0028.
> The deep-audit recommendations doc (`docs/reports/nwp-deep-audit-recommendations-2026-07-09.md`)
> earlier *proposed* 0028/0029/0030 for the un-fork / nwc-auth-model / canonical-axes
> ADRs; those are not yet written and shift to 0029/0030/0031 when they are.

**Status:** Accepted — operator decision, 2026-07-09.
**Date:** 2026-07-09
**Decision Makers:** Robert Karsten Zaar
**Related Issues:** nwp/ops#25 (`ver`/ver provisioning), nwp/ops#28 (deploy-authority topology)
**Amends:** [NWP-ADR-0017](0017-distributed-build-deploy-pipeline.md) and
[NWP-ADR-0026](0026-nwp-server-capability-agent.md) — the *operating posture* of the
ver host only (not the deploy-authority topology, not the signature-trust model).
**Supersedes:** the "minimal server / no desktop / no browser / no AI tooling"
posture in `docs/guides/ver-provisioning-runbook.md` §2, the two-Solo **K/W**
role split in §4, and the `cd ~/nwp` / mesh framing in the operational-readiness
guide under `docs/guides/`.
**References:** NWP-ADR-0017, [NWP-ADR-0022](0022-nwp-verifier-binary-split.md),
[NWP-ADR-0024](0024-self-deploying-prod-supersedes-verifier.md),
[NWP-ADR-0025](0025-production-backup-to-ver.md), NWP-ADR-0026, CLAUDE.md (threat model),
`docs/reports/nwp-deep-audit-recommendations-2026-07-09.md` (streams ①/⑤).

---

## Context

NWP-ADR-0017 establishes an offline-by-default host ("ver", role `ver`) as the
production-write boundary: the AI-capable tier signs artifacts; ver verifies
signatures locally and reaches prod only over a dedicated 1:1 WireGuard tunnel.
NWP-ADR-0022/0026 add that the host runs a **separately-built, AI-free** artifact
(`nwp-server`) — no AI/CI/SaaS code in the binary at all.

The ops#25 provisioning work (MR !37) implemented this as a **minimal, headless
server**: `ver-provisioning-runbook.md` §2 mandates *"minimal server install …
no desktop, no browser profile, no password manager, no AI tooling of any kind"*,
and split hardware duties across **two Solos with distinct jobs** — Solo K (seals
the restic DR-backup keystore via `age-plugin-fido2-hmac`, stays with the box) and
Solo W (WebAuthn carry token for GitLab).

Three facts, established in operator discussion on 2026-07-09, motivate amending
the *operating posture* (not the trust model):

1. **The operator is the sole ver user and is not a terminal native.** ver is one
   physical box in the operator's home. Remote developers never touch it (they are
   GitLab-MR-only — see the dev scale ladder below). For a solo, non-terminal
   operator who wants to **run and test the full `pl` command surface on the box and
   feed back bugs**, a minimal headless server is a poor ergonomic fit, and
   operator error is a larger real risk than the attack surface a GUI adds to an
   offline-by-default box.

2. **"AI-free" means no autonomous AI *execution path*, not "no AI code / no
   browser."** A browser tab running a hosted LLM produces only *text the operator
   reads*; it has no shell, cannot run a command, cannot read a key, cannot reach
   prod. The human is the airgap between AI suggestion and execution — the same
   human gate already relied on for reviewing a diff before deploy. This is
   categorically different from a live AI *agent/loop/MCP server* with shell access,
   which remains forbidden on ver.

3. **The load-bearing control is the hardware+signature gate on prod-writes, not the
   absence of a GUI.** No `pl` command reaches a live server without an operator
   Solo touch on a validly-signed artifact. Therefore operator terminal fluency
   affects *productivity* on the box, not *prod safety* — which frees the box to be
   optimised for operator comfort. (The deep audit's stream ① reached the same
   conclusion: the minimal-surface rules were defence-in-depth *on top of* the
   hardware gate, not the gate itself.)

The ops#25 backup-custody half (Solo K + sealed keystore + restic DR pull + escrow,
runbook §4-Solo-K/§5/§8) is a *separate capability* from deploy-verification and is
**deferred** — it is not required to deploy.

## Decision

ver is a **single-operator, human-gated desktop workstation**, running the **full
`pl` command surface**, with the following properties.

### Operating environment
- **Desktop OS** (e.g. Ubuntu Desktop, or a light DE such as XFCE) — reversing the
  runbook §2 "no desktop" line. Includes a **graphical git/diff tool** (open-source:
  `gitg`, `git-cola`, or Meld) so the pre-deploy review gate is point-and-click, and
  a **browser** for reference and hosted-AI use.
- **Full `pl` / `~/nwp` tree present**, so the operator can run and test every `pl`
  command on the box and report feedback. ver is thus both the prod-write host
  *and* a `pl` test/QA environment.
- **Browser-based AI is permitted** (read-only, human-gated). **No live AI agent,
  autonomous loop, MCP server, or any AI process with shell/execution access may run
  on ver** — that is what "AI-free" means here and it is inviolable.

### Retained invariants (unchanged from NWP-ADR-0017/0026 — the actual security)
- **Offline-by-default.** Network default-off; online only in deliberate windows.
  **No Headscale/tailnet membership** (ops#25 decision, 2026-07-03). Connectivity is
  outbound HTTPS to the GitLab host plus the per-session 1:1 WireGuard tunnel per
  prod host, ideally over a hotspot/dedicated modem, never the home LAN.
- **Full-disk encryption** (LUKS), ideally unlocked by a **Solo touch**
  (`systemd-cryptenroll --fido2-device`) — works headless or desktop, at the console.
- **Hardware + signature gate on every prod-write — absolute.** No `pl` command may
  reach a live server without (a) an operator **Solo touch** and (b) successful
  **signature verification** of the artifact being applied. Even a malicious pasted
  command, a `pl` bug under test, or a browser compromise cannot push to prod without
  the physical touch on a signature it cannot forge. This gate — not the absence of a
  browser — is the property the whole design rests on.
- **Canonical phase guards** (dev|live|prod, NWP-ADR-0013-successor) keep non-prod `pl`
  testing safely in dev/local; a test command cannot silently act on prod.

### Signing
- **Per-deploy authorization = SSH `ed25519-sk` touch key** (git SSH-signing /
  `ssh-keygen -Y sign|verify` against an `allowed_signers` file). Each deploy is a
  Solo touch; **no exportable signing key lives on disk** — this resolves the deep
  audit's C4 ("minisign secret key on the AI-reachable disk") for the deploy path.
- **minisign is retained only for the rare `ver-kit` bootstrap** (built, tested,
  USB-transferred, TOFU-verified — low ongoing exposure). It may later be unified onto
  `ed25519-sk` but that is not required now.

### MR approval while there is only one human (Phase 1 dispensation)

**Added 2026-08-03 by operator decision.** This records what is actually
sanctioned, because a control that reads stronger than it is, is worse than a
control that is honestly scoped.

`pl mr release <iid> --approved-by=<handle>` lifts the D13 sensitive-path hold.
The gate checks that the approver is **not the MR author** and **not a bot**. It
does **not** — and today cannot — verify that the named human typed the command.
An AI agent running `--approved-by=rjzaar` is indistinguishable from the
operator running it.

**During Phase 1 that is accepted, deliberately, and is not a defect.** There is
exactly one human on this estate. A "two-person rule" with one person available
is not two-person review; it is a record of intent. Pretending otherwise would
mean either blocking all sensitive-path work, or maintaining a ceremony everyone
knows is theatre — and theatre is how real controls come to be ignored.

So, while the estate has one signer:

- An agent **may** record the operator's approval, **only** on an explicit,
  in-session instruction from the operator, naming the MR.
- The `--reason` **must cite that instruction** — what was asked, and when — so
  the audit trail shows *why* the approval is recorded as the operator's, not
  merely *that* it is.
- The release remains bound to the head commit. Pushing re-holds. That part is
  real enforcement and is unaffected.
- What this buys is **traceability, not authentication**. Read the release note
  as "the operator asked for this", never as "a second human reviewed this".

**THE TRIGGER — this dispensation ends by itself.** The registry carries a
declared `approvers:` fact. While it names one human, the above applies. The
moment a **second** name appears — a second coder able to sign MRs — the verb
**refuses agent-recorded approvals** and the approver must authenticate. Nothing
has to be remembered at the right moment; adding the second name arms it.

This follows the same rule as every other guard here: key off a **declared
fact**, never off a date, a phase name, or an intention. A guard that is inert
today, correct forever, and arms itself when the world changes (cf. the
canonical-phase rule in `CLAUDE.md`) beats one that depends on somebody noticing.

When enforcement does arm, the mechanism is already specified above: the
`ed25519-sk` Solo touch. A signature the agent cannot produce is the difference
between recording an approval and *being* one.

### Hardware tokens (repurposed from the deferred Solo-K plan)
- The **part-built Solo K → Solo W** (primary WebAuthn + carry token). **Factory-reset
  it first** to clear the half-built keystore credential and PIN.
- The **second Solo → Solo W2**, an **independently-enrolled backup** (FIDO2 keys
  cannot be cloned — W2 is registered separately on the GitLab account, not copied).
  Kept in a drawer.
- Both are **touch-only WebAuthn 2FA**; the "something you know" factor remains the
  **GitLab account password, held in the operator's vault** (KeePassXC). Day-to-day
  login = vault auto-fills the password + one tap, no PIN prompt. A device PIN is
  added only if the operator later goes fully passwordless (passkey), where the PIN
  replaces the password.

### Operator ergonomics for a non-terminal user
- Prod-write `pl` commands present a **plain-English "here is exactly what this will
  do" impact/fate-manifest and require a typed/tapped confirmation** before acting
  (the deep audit's impact-contract, generalised — see ops#47). The scary commands
  become a readable summary + a Solo touch, not a memorised incantation.
- Work splits by comfort: **review / merge / authorize** happen in the **GitLab web
  UI** (browser, Solo/phone WebAuthn — point-and-click); **testing `pl` + the single
  gated deploy step** happen on ver.

### Deferred (with reactivation triggers)
- **DR-backup custody** (Solo K role → now unused; sealed keystore, restic DR pull,
  escrow; runbook §4-Solo-K/§5/§8): **deferred.** *Reactivate when disaster-recovery
  backups are wanted.* When reactivated, it needs its own hardware factor bound to
  the box (a fresh Solo K, or a documented decision to reuse a W-class token — noting
  that a travelling token that also decrypts backups weakens the stolen-token story).
- **A second person deploying to prod:** not now. See the ladder.

### Dev scale ladder (recorded here for reference)
Remote/other developers never touch ver. They climb an additive, reversible ladder:
0 · **Contributor** (GitLab Developer role, MRs only, own-device 2FA — where all new
devs start) → 1 · **Reviewer/merger** (Maintainer on specific projects) → 2 ·
**dev/stg host access** (own `ed25519-sk` key; never prod/ver) → 3 · **Release
co-signer** (own Solo; their pubkey in ver `allowed_signers`; optional 2-signature
quorum; authorizes releases but holds no prod key, never touches ver) → 4 ·
**Independent deployer** (their *own* ver — own prod key + own WireGuard peer;
crown-jewel trust). Only the operator is anywhere near rung 4.

## Consequences

**What is kept (the security):** offline-by-default, no mesh, FDE, signature-trust,
no autonomous-AI execution on ver, the hardware+signature prod-write gate, phase
guards. None of these change.

**What is traded (accepted, defence-in-depth):**
- *Larger attack surface* (browser/desktop) — mitigated by offline-by-default (surface
  only matters in online windows), a patched browser used for AI/reference not general
  browsing, and the fact that the prod-write gate holds even against a browser
  compromise.
- *Larger trusted computing base* (full `pl` vs the minimal `nwp-server` artifact) —
  accepted; it is reviewed, in-git code, and the prod-write subset is gated.

**Residual risk the operator accepts:** pasting AI-generated commands is only as safe
as reading them before running — the discipline is "read before you paste-run,
especially into a prod command." The hardware gate bounds the worst case (no prod
reach without a touch on a valid signature), but non-prod damage on the box is
possible if unread commands are run.

**Net:** matching the box to a solo, non-terminal operator reduces operator error —
itself a security gain — without weakening any load-bearing control. Being "not a
terminal person" does not endanger prod, *because the gate does the protecting, not
terminal fluency.*

## Follow-up
- Rewrite `ver-provisioning-runbook.md` §2 (desktop + browser-AI + full `pl`), §4
  (Solo **W/W2**, not K/W), and mark §4-Solo-K/§5/§8 **deferred — DR capability**;
  add a top-of-file "deploy-half fast path" (Solo W enrol + `sk`-signing).
- Reconcile the operational-readiness guide to this ADR (it currently frames `cd
  ~/nwp` and no-tailnet as gaps; both are now intended). A future F34 role-vocab
  scrub renames that guide and clears its remaining bare host-names.
- Land the `ed25519-sk` verify gate + the impact-manifest confirmation in the
  prod-write `pl` commands (via the shared deploy-preamble — deep-audit stream ③).
- Operator (unchanged, hands-on): revoke the two root-admin GitLab PATs + shred the
  stale PATs the ops#25 ledger scan already found; enrol Solo W + W2 + phone on
  GitLab.
