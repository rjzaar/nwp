# ADR-0018: Twilio as Bounded SaaS Dependency for PSTN Voice/SMS

**Status:** Accepted
**Date:** 2026-04-08
**Accepted:** 2026-04-08
**Decision Makers:** Rob
**Related Issues:** X02
**References:** [ADR-0004](0004-two-tier-secrets-architecture.md), [ADR-0017](0017-distributed-build-deploy-pipeline.md), [CLAUDE.md § Threat Model](../../CLAUDE.md), [X02](../proposals/X02-local-voice-agent-on-mini.md)

## Context

NWP's threat model (CLAUDE.md § Threat Model) assumes "third-party SaaS is
distrusted by default. Prefer self-hosted, open-source alternatives even
when they require more setup." Existing examples of this preference in
practice: Headscale over Tailscale, Gotify over Pushover, GitLab
self-hosted over GitLab.com, local LLM on mini, minisign over
sigstore/cosign.

Proposal X02 (Local Voice Agent on mini) wants to give mini an inbound
phone channel. Unlike VPN, push notifications, source-code hosting,
artifact signing, or LLM inference, **PSTN access has no self-hostable
equivalent at any reasonable cost**. The public switched telephone network
is physically owned by telecom carriers. Getting a phone number that can
receive calls from grandma's landline requires an agreement with a telecom
carrier. There are four routes, and three of them are SaaS:

1. **Become a CLEC** (Competitive Local Exchange Carrier). Regulatory
   registration, ~US$50k+ capital requirement, ongoing compliance. Not
   reasonable for a one-person ministry project.
2. **Resell through a wholesale SIP trunk provider** (Flowroute, Bandwidth
   direct, VoIP.ms, etc.). Cheaper than becoming a CLEC but still a SaaS
   dependency — you are a customer of a company that can terminate your
   account.
3. **Buy a number from a programmable telephony platform** (Twilio,
   Telnyx, SignalWire, Bandwidth). Easier, more features, still a SaaS
   dependency.
4. **Don't have a phone number.** Foregoes the use case.

Even a fully self-hosted Asterisk server on mini still requires a SIP
trunk to reach the PSTN, and that SIP trunk is a SaaS account at some
other company's wholesale carrier.

This ADR exists because X02 represents the first NWP component that
cannot obey the "prefer self-hosted" rule, and a clear written decision
is better than an exception buried in a proposal.

## Forces

- **Threat model consistency.** The paranoid + open-source + local-first
  disposition is a strategic asset; unnecessary exceptions dilute it.
  Exceptions should be few, explicit, and bounded.
- **PSTN physics.** Phone numbers are a regulated, cartelized resource.
  There is no technical workaround to the carrier tier.
- **Use case value.** Voice agent experiments need a phone number to be
  useful. The alternative ("no phone number at all") means the X02
  proposal cannot exist.
- **Data minimization.** Even an unavoidable SaaS dependency can be kept
  to the smallest possible surface. Most of the value of a voice agent is
  in the STT/LLM/TTS stack, which *can* be local. Only the audio transport
  fundamentally must cross a SaaS boundary.
- **Switching cost.** Being locked into one telephony provider is a
  separate risk from using telephony at all. Switching cost is
  minimizable by design decisions made at the start.
- **Precedent management.** Whatever we decide here will be cited by
  future proposals. The wording has to survive that pressure without
  becoming a loophole.

## Options Considered

### Option 1: Don't do voice telephony at all

Reject X02. Honor the threat model rule strictly.

- **Pros:**
  - No new SaaS dependency
  - Threat model stays pristine
- **Cons:**
  - X02 cannot exist; the "voice agent on mini" experiment is forgone
  - The precedent becomes overly rigid: "if it touches any SaaS at all,
    it's forbidden" would eventually block other reasonable things that
    have no self-hosted equivalent (e.g. external DNS, CAs, OS package
    mirrors are already accepted SaaS dependencies)

### Option 2: Become a CLEC or buy direct carrier interconnects

Technically possible but absurd for a one-person project.

- **Pros:**
  - Maximum independence in theory
- **Cons:**
  - Capital and time cost are both prohibitive
  - Does not actually remove SaaS dependency — you still transit traffic
    through interconnect partners
  - Regulatory compliance burden

### Option 3: Accept Twilio, but let Twilio-specific assumptions leak through the codebase

Use Twilio and write code that bakes in Twilio-specific shapes (webhook
formats, TwiML, Twilio SDK idioms). Gets the use case working fastest.

- **Pros:**
  - Fastest time to first call
  - Leverages Twilio's best-in-class docs and SDKs
- **Cons:**
  - Vendor lock-in: switching to Telnyx/Bandwidth later requires
    rewriting the agent, not just swapping a config value
  - Bakes the SaaS dependency into multiple layers of code
  - Defeats data minimization: if switching is hard, the threat model
    disposition is *permanently* degraded, not temporarily accommodated

### Option 4: Accept telephony SaaS, but keep it at arm's length via a transport abstraction (chosen)

Use Twilio (or equivalent) for the PSTN bridge, but:

- Route all interaction with the provider through a single adapter
  (Pipecat's `TwilioFrameSerializer` in X02's case).
- Keep STT, LLM, TTS, call logs, and conversation state strictly local
  on mini.
- Design and document a provider-swap procedure and verify it is a
  single-file code change.
- Never let the telephony provider touch anything above the audio layer.
  No transcripts, no call state, no model outputs, no user context.
- Document this as a conscious, bounded exception to the "prefer
  self-hosted" rule, citable from CLAUDE.md.

- **Pros:**
  - X02 becomes possible
  - SaaS exposure minimized to the audio stream only
  - Vendor lock-in kept near zero by design
  - The threat model disposition is preserved by explicit bounding
    rather than strict exclusion
  - Future providers (Telnyx, SignalWire, Bandwidth, self-hosted
    Asterisk + SIP trunk) can be swapped in without rewriting the agent
- **Cons:**
  - First explicit third-party SaaS exception in NWP's core dependency
    tree beyond hosting and certs — creates a precedent that must be
    managed carefully
  - Twilio can still see audio bytes (TLS in transit, but the audio
    endpoint is Twilio's infrastructure; they could in theory retain
    or be compelled to retain recordings)

## Decision

Adopt **Option 4**. Accept Twilio (and any equivalent programmable
telephony SaaS) as a **bounded, arm's-length SaaS dependency** for PSTN
voice/SMS access. The bounding rules are:

1. **Single adapter.** Only one file in the NWP tree talks to the
   telephony provider's SDK or webhook formats. For X02 that is Pipecat's
   `TwilioFrameSerializer` — NWP only depends on Pipecat, which
   abstracts the provider. If a custom adapter is ever needed, it lives
   in exactly one file under `servers/mini/voice-agent/` and does
   nothing else.

2. **Local processing above the audio layer.** STT, LLM inference, TTS
   synthesis, call logs, and any conversation state run on NWP-owned
   infrastructure (mini for X02). The telephony provider sees audio
   bytes only — never transcripts, never model outputs, never user
   identity beyond the caller phone number the PSTN already reveals.

3. **No webhook on the open internet.** The telephony provider reaches
   NWP through a Headscale-routed ingress on an NWP-controlled Linode
   (the same `au-mel` Linode that hosts `git.nwpcode.org` post-F21
   Phase 4, or a sibling). Home-LAN infrastructure is never directly
   exposed to the telephony provider. No inbound port opens on the home
   router.

4. **Provider swap is a first-class requirement.** The swap procedure
   must be documented as part of the voice-agent's runbook (X02 Phase 3).
   "Swap Twilio for Telnyx" must be achievable in under an hour by a
   reader of the runbook. This is verified **on paper**, not necessarily
   executed — but the exercise of writing it catches vendor lock-in
   before it hardens.

5. **Credentials classification.** Twilio Account SID, Auth Token, and
   number SIDs are **infra-tier** secrets per [ADR-0004](0004-two-tier-secrets-architecture.md)
   (they enable infrastructure automation; they don't expose user data).
   They live in `.secrets.yml`, never in `.secrets.data.yml`.

6. **Empty tool allowlist by default.** The voice agent's tool schema
   starts with no tools at all. A voice caller is an untrusted input
   source and a voice-accessible tool is reachable by anyone who dials
   the number. Any future tool addition requires an explicit scope
   review. Nothing prod-adjacent is ever exposed — mini's existing
   no-prod-access rule from [ADR-0017](0017-distributed-build-deploy-pipeline.md)
   is preserved unchanged.

7. **Scope creep prevention.** This exception applies to PSTN voice/SMS
   specifically. It does **not** establish a precedent that other SaaS
   categories (Slack, Discord, Pushover, cloud LLMs, cloud STT, cloud
   TTS) are fine "because we already use Twilio." Each new SaaS proposal
   must be evaluated against the threat model on its own merits. The
   existence of ADR-0018 is not a citation for expanding it.

## Rationale

### Why accept any SaaS at all?

PSTN is regulated physics, not software. The self-hosted equivalent does
not exist. This is different from VPN, notifications, or code hosting,
where the self-hosted equivalent exists and is pragmatic. It is in the
same category as DNS (Linode), TLS certs (Let's Encrypt), and OS package
mirrors — trust anchors of last resort that the threat model
accommodates because there is literally no way around them.

### Why Twilio specifically?

Twilio has the best-documented API, the cleanest Media Streams
implementation (which is what X02 actually uses), and mature open-source
framework integration (Pipecat's `TwilioFrameSerializer` is first-class
in the Pipecat repo). The relative cost of switching providers is low
precisely because Media Streams is a well-trodden path with equivalents
at every major alternative.

**Acceptable alternatives**, in rough order of preference: Telnyx (good
WebSocket media support, slightly cheaper, similar API quality);
SignalWire (Asterisk heritage, strong self-hosted sympathies);
Bandwidth (wholesale-tier, closest to "just a SIP trunk"). **Fallback
of last resort** if all mainstream programmable telephony becomes
untenable: self-hosted Asterisk + a wholesale SIP trunk (Flowroute,
VoIP.ms), which moves the SaaS boundary one layer outward without
eliminating it.

### Why the single-adapter rule?

The actual cost of vendor lock-in is not "we are using Twilio" — it is
"we have written code that assumes Twilio." The former is reversible
(cancel account, buy new number); the latter is refactor work. The
single-adapter rule forces the reversible shape from day one. The rule
is enforced by the fact that NWP-owned code imports Pipecat, not Twilio
— Twilio's SDK is a transitive dependency of Pipecat, not a direct
dependency of NWP.

### Why keep everything above the audio layer local?

Two reasons:

1. **Data sovereignty.** Transcripts and model outputs are the
   high-value extract; audio is the low-value transport. Keeping the
   extract local means even a compromised telephony provider cannot
   exfiltrate what actually matters.
2. **Local LLM is the load-bearing technical bet of this project.** If
   X02 sent audio to cloud STT and cloud LLM, it would be a different
   proposal — "put an AI voice agent behind a Twilio number." The point
   of X02 is specifically to test "can mini's local stack do this." If
   we allow cloud STT/LLM here, the whole experiment is invalid.

### Why cap the blast radius with an empty tool allowlist?

A voice caller is an untrusted input source. A voice-accessible tool is
reachable by anyone who dials the number, including prompt-injection
attempts delivered verbally. The safe default is no tools at all until
each one is reviewed. This is the same discipline as not exposing
`pl deploy` to an HTTP endpoint. Over time the allowlist can grow, but
only by explicit scope review — not by drift.

### Why write an ADR instead of just noting this in X02?

CLAUDE.md is standing orders for AI agents. X02 is an implementation
plan. This is an **architectural trust decision** about where a
boundary sits in NWP's threat model, and decisions of that shape belong
in ADRs so the reasoning is preserved and future readers (including
future AI agents) can audit it. CLAUDE.md will reference this ADR in a
single sentence; future proposals touching SaaS boundaries will cite
it; future-Rob in two years will be able to reconstruct why this
exception was made without re-deriving the argument.

### Why not require Option 2 (CLEC)?

Because "the threat model must be honored at any cost" is not actually
the threat model. The threat model prefers self-hosted where self-hosted
is feasible; PSTN CLEC registration is not feasible. The rule is
"prefer", not "require at any cost."

### Why does this precedent not open the floodgates?

Because the bounding rules are specific to the "no self-hosted
alternative exists at reasonable cost" test. Slack has Matrix. Discord
has Matrix. Pushover has Gotify. Cloud LLMs have Ollama/local LLM on
mini. Cloud STT has faster-whisper. Cloud TTS has Piper. Every
plausible future "please add this SaaS" request has a self-hosted
answer that X02 does not have. The single distinguishing property of
PSTN is that the physical-network layer is carrier-owned. That is not a
property of any of the above, so the ADR does not extend to them.

## Consequences

### Positive

- X02 becomes implementable
- The voice agent use case unblocks with a clear, bounded SaaS exposure
- The single-adapter rule forces a provider-swap test that catches
  lock-in early, before it hardens
- Twilio credentials classification extends [ADR-0004](0004-two-tier-secrets-architecture.md)
  (infra tier) to a new credential type without reopening the schema
- Future telephony-related work inherits the bounding rules
  automatically
- The project gains a worked example of "bounded SaaS exception" that
  future proposals can cite and constrain themselves to, with the
  scope-creep prevention rule explicit

### Negative

- First explicit third-party SaaS exception in NWP's core dependency
  tree beyond hosting and certs
- Twilio can see audio content (TLS in transit; Twilio infrastructure
  terminates the TLS and re-encrypts toward mini's ingress). Mitigation
  is "provider swap is a first-class requirement", not elimination.
- Twilio can terminate service (account policy, billing, regulatory).
  Provider-swap procedure mitigates but does not eliminate this — a
  same-day swap is possible, but not instant.
- Sets a precedent that must be managed carefully. "Other SaaS" requests
  will cite this ADR and must be refused on their own merits, not
  granted by analogy. This is operator discipline, not an automatic
  safeguard.
- Twilio is US-headquartered. If the operator's jurisdiction or legal
  environment changes, the data-in-transit situation must be
  re-evaluated.

### Neutral

- [ADR-0017](0017-distributed-build-deploy-pipeline.md) (distributed
  build/deploy) is unchanged — Twilio is not in the deploy path, mini
  has no prod access, and the voice agent's tool allowlist is empty.
- [ADR-0004](0004-two-tier-secrets-architecture.md) (two-tier secrets)
  gains one more infra-tier credential type without schema changes.
- CLAUDE.md threat model gains a documented exception with a link to
  this ADR, preserving the paranoid disposition with one bounded hole.

## Implementation Notes

This ADR is implemented by X02 phases 1–3.

- **X02 Phase 1** — Twilio account prep, paid upgrade, US 10DLC number
  purchase, TwiML hello-world. Verifies the single-adapter rule
  trivially (no custom code yet).
- **X02 Phase 2** — Pipecat pipeline with `TwilioFrameSerializer`. This
  is the single adapter in practice. Anything Twilio-specific lives in
  the Pipecat version-pinned dependency, not in NWP-owned code.
- **X02 Phase 3** — Runbook for provider swap. Written and reviewed
  even if not executed. The existence of the runbook is the enforcement
  mechanism for the "switchable" property.
- **X02 Phase 4** — SMS via A2P 10DLC registration is parallel and does
  not alter this decision. SMS uses the same adapter, same secrets
  classification, and the same bounding rules.

### CLAUDE.md cross-reference

Once this ADR is accepted, add a single sentence to CLAUDE.md § Threat
Model pointing at it:

> **Bounded SaaS exception for PSTN voice/SMS access** — see
> [ADR-0018](docs/decisions/0018-twilio-bounded-saas-for-pstn.md). The
> `prefer self-hosted` rule holds everywhere else; this is the single
> documented exception, scoped to the audio transport layer only.

This keeps CLAUDE.md short while preserving auditability.

### No schema changes

Twilio credentials fit the existing infra-tier shape per ADR-0004. No
new credential tier or secrets schema change is needed.

### Provider swap runbook sketch

The real runbook lives in X02 Phase 3 under
`servers/mini/voice-agent/README.md`. Sketched here for completeness so
this ADR is self-contained:

1. Identify the new provider's equivalent of Twilio Media Streams (e.g.
   Telnyx bidirectional audio streaming, SignalWire realtime voice,
   Bandwidth BXML Transcription).
2. Replace the `TwilioFrameSerializer` import in
   `servers/mini/voice-agent/pipeline.py` with the new provider's
   serializer class from Pipecat.
3. Update `.secrets.yml` with the new provider's credentials (same
   infra-tier classification).
4. Update the new provider's webhook configuration to point at the
   existing Headscale-routed ingress URL — the ingress does not care
   which telephony provider is upstream.
5. Test with a single call from a known number.
6. Port the phone number if the new provider supports port-in, or run
   both numbers in parallel during a soak period.
7. Decommission the old Twilio account after the soak period.

The runbook is exercised on paper at the end of X02 Phase 3. Actual
execution is optional and only happens if Twilio becomes untenable.

## Review

**30-day review date:** 2026-05-08

**Success criteria for review:**

- [ ] X02 Phase 1 completed (Twilio number works with TwiML hello-world)
- [ ] X02 Phase 2 completed (Pipecat pipeline with local stack answers
      a real call, zero cloud AI)
- [ ] Provider-swap runbook drafted in X02 Phase 3
- [ ] CLAUDE.md cross-reference added
- [ ] No NWP-owned code outside `servers/mini/voice-agent/` imports
      Twilio-specific types or references Twilio SDK classes

**Review question at 30 days:** has the single-adapter discipline held,
or has Twilio-specific code started leaking into other parts of NWP? If
it's leaking, the discipline needs tightening or this ADR needs
revising. If it hasn't leaked, promote the ADR from Proposed to
Accepted.

**Review question at 90 days:** has any other proposal tried to cite
ADR-0018 as a precedent for a SaaS that *does* have a self-hosted
alternative? If so, the scope-creep prevention rule needs strengthening
and possibly an explicit "rejected citations" log in this ADR.

## Related Decisions

- **[ADR-0004: Two-tier Secrets Architecture](0004-two-tier-secrets-architecture.md)**
  — Twilio credentials classified as infra tier under the existing
  schema. No new credential tier required.
- **[ADR-0017: Distributed Build/Deploy Pipeline](0017-distributed-build-deploy-pipeline.md)**
  — Orthogonal. Twilio is not in the deploy path; mini has no prod
  access; the voice agent's tool allowlist is empty; ADR-0018 does not
  weaken any property ADR-0017 establishes.
- **[X02: Local Voice Agent on mini](../proposals/X02-local-voice-agent-on-mini.md)**
  — The proposal this ADR unblocks and scopes.
- **CLAUDE.md § Threat Model** — The standing order this ADR makes an
  explicit, bounded exception to.
