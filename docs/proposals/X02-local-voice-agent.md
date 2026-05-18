# X02: Local Voice Agent on the AI-Host Tier (Twilio + Pipecat + local LLM)

**Status:** PROPOSED — Phase 0 preflight DONE; direct-mic push-to-talk loop DONE (see §11 Progress Notes)
**Created:** 2026-04-08
**Author:** Robert Karsten Zaar (with AI assistance)
**Priority:** Low (scope expansion; exploratory)
**Depends On:** F21 Phase 3a (`ai-host` as local-LLM agent), F21 Phase 1 (Headscale ingress), F21 Phase 3 (`ai-host` as runner — soft dep). Operator orientation: [`docs/guides/local-llm.md`](../guides/local-llm.md).
**Breaking Changes:** None
**Estimated Effort:** ~4 phases; Phases 0–3 can land in a long weekend, Phase 4 (SMS) paces at TCR's 10–15 day review cycle

> **Reference deployment.** Concrete role-to-host bindings, the specific
> Twilio number SID, hardware specifics, and milestone-to-commit mapping for
> the operator's reference deployment live in a private instance addendum.
> The public proposal is self-contained against the role-label vocabulary
> (see [`docs/reference/role-vocabulary.md`](../reference/role-vocabulary.md)).

---

## 1. Executive Summary

Run an AI voice agent on the `voice-agent` role (typically co-located with
the `ai-host` / `llm-host` role) that answers phone calls on a North-American
A2P 10DLC number using a fully local stack: Pipecat orchestration +
faster-whisper STT + an 8B-class instruction model on Ollama + Piper or
Kokoro TTS.

This is explicitly scope expansion beyond NWP's core Drupal deployment
mission — hence the X## designation per ADR-0011. The justification is that
the `ai-host` tier is NWP's day-to-day agent tier (see [F21](F21-distributed-build-deploy-pipeline.md)),
and giving it a voice channel is a natural extension of that role. If the
experiment turns out to be noise, the whole stack deletes cleanly: it lives
under the `voice-agent`'s per-role config directory and touches no core NWP
machinery.

The load-bearing constraint: **the voice agent must not evict the coding
agent**, which is the `ai-host`'s primary job. This is achieved by running
the voice LLM on-demand (`keep_alive=5m`) while the coding model stays
resident (`keep_alive=24h`). Calls are sporadic; the coding agent is steady;
a host with unified memory (≥64 GB on a modern APU with unified LPDDR5X
memory) absorbs the brief overlap.

Third-party SaaS (Twilio) is unavoidable for PSTN access — the only
self-hosted alternative is becoming a CLEC. The mitigation is keeping
everything *above* the audio layer local: all STT/LLM/TTS/state stays on
the `voice-agent`. Twilio sees only the TLS audio stream, never transcripts
or model state. Pipecat's transport abstraction means swapping Twilio for
Telnyx, Bandwidth, SignalWire, or a self-hosted Asterisk + SIP trunk is a
single-file change.

---

## 2. Goals & Non-Goals

### Goals

- **Inbound voice answered by a local LLM** on the `voice-agent` role
- **No cloud AI** — STT/LLM/TTS all local, audio the only thing Twilio sees
- **Coexist with the coding agent** on the same `ai-host` without evicting it
- **Pipecat as the orchestration layer** — vendor-neutral so telephony can
  be swapped later without rewriting the agent
- **Sub-1.5 s response latency p50** for 8B-model conversations
- **No webhook exposure to the open internet** — Twilio reaches the
  `voice-agent` only through a Headscale-routed ingress on `gitlab-host`

### Non-Goals

- **Outbound robocalling** — unwanted, and triggers different regulatory
  scrutiny
- **SMS-first agent** — SMS requires A2P 10DLC registration (10–15 day TCR
  review for a non-US business registration), which is a parallel track
  (Phase 4) with its own gating; voice does not wait on it
- **Production integration** — the `ai-host` is in the AI-capable tier per
  F21; it must not reach prod. The voice agent's tool allowlist starts empty
  and nothing prod-adjacent is ever added to it
- **Replacing commercial telephony** — this is a self-tooling experiment,
  not a product
- **Voice cloning / impersonation** — generic TTS voices only
- **Multi-language** — English-only to start

---

## 3. Architecture

### 3.1 Component diagram

```
Phone call (PSTN)
  -> Twilio A2P 10DLC number
  -> Twilio Media Streams (WebSocket, bidirectional audio, TLS)
  -> Headscale ingress on gitlab-host
  -> voice-agent:<port> (Pipecat FastAPI WebSocket transport)
      |
      |- Silero VAD          (CPU)      turn detection
      |- faster-whisper      (CPU)      STT (distil-large-v3 or small.en)
      |- Ollama              (iGPU)     LLM
      |    |- coding model:  keep_alive=24h   (primary tenant, always on)
      |    |- voice model:   keep_alive=5m    (loads on call, unloads after)
      |- Piper or Kokoro     (CPU)      TTS
      |- Local SQLite        (disk)     call log, transcripts (gitignored)
```

### 3.2 Resource strategy

The `voice-agent` host's iGPU and unified memory are shared between the
coding agent (primary) and the voice agent (sporadic).

| Workload          | Runtime              | Keep-alive | Notes                               |
|-------------------|----------------------|------------|-------------------------------------|
| Coding agent LLM  | Ollama / iGPU        | `24h`      | Always resident                     |
| Voice agent LLM   | Ollama / iGPU        | `5m`       | Loads on call start, unloads after  |
| STT (whisper.cpp) | CPU                  | n/a        | Streaming, ~150 ms cold start       |
| TTS (Piper)       | CPU                  | n/a        | Effectively instant                 |
| VAD (Silero)      | CPU                  | n/a        | Tiny                                |

During a call, both LLMs are briefly co-resident (~5 GB voice + ~20 GB
coding ≈ 25 GB on the iGPU side), which a modern APU's unified memory
handles comfortably on a 64 GB+ SKU. After the call, the voice model is
evicted and bandwidth is fully available to the coding agent again.
STT/TTS on CPU means the iGPU is only contended for LLM work.

### 3.3 Threat model alignment

Follows CLAUDE.md § "Threat Model" and F21 § "Distributed Actor Glossary":

- **The `voice-agent` role has no prod access.** Voice agent reads no prod
  credentials. The voice agent's tool schema starts with an **empty
  allowlist**. Any future tool requires an explicit scope review before
  being added, and nothing `pl deploy`-adjacent is ever exposed.
- **Twilio as a distrusted SaaS boundary.** Only audio crosses the
  boundary. Pipecat's `TwilioFrameSerializer` is the only code in NWP that
  talks to Twilio; swapping to Telnyx / Bandwidth / SignalWire / self-hosted
  Asterisk is a single-file change verified by the Phase 3 runbook.
- **No webhook exposure to the open internet.** No port opens on the home
  router. Pipecat's WebSocket is reached via a Headscale-routed ingress on
  `gitlab-host` (post-F21 Phase 4), or a sibling host if co-tenancy is
  undesirable.
- **Call logs stay local.** SQLite on the `voice-agent` host, gitignored.
  Transcripts never leave the home LAN.
- **Signed commits apply unchanged.** Changes to the `voice-agent`'s
  per-role config directory go through the same signed-commit discipline
  as the rest of NWP.

---

## 4. Phased Implementation

### Phase 0 — Preflight on the `voice-agent` host *(reversible)*

**Goal:** Verify the host can run an 8B model at voice-grade latency
*while* the coding agent is loaded, before investing in Pipecat.

1. Confirm Ollama is installed; install with the host's iGPU backend
   (Vulkan or ROCm) if not.
2. `ollama pull llama3.1:8b` and `ollama pull qwen2.5:7b-instruct`.
3. Benchmark tokens/sec and first-token latency using `ollama run --verbose`.
4. Confirm the iGPU backend is actually being used (`nvtop` / `radeontop`).
   CPU fallback is a red flag at this stage.
5. Measure memory headroom with the coding model *and* a voice model loaded
   simultaneously. Check whether `OLLAMA_KEEP_ALIVE` per-request overrides
   behave as documented.
6. Sanity-check BIOS iGPU memory allocation — some APU SKUs lock it lower
   than the silicon allows; raise it if needed.

**Success:** 8B model first-token < 400 ms, steady-state > 25 tok/s on
the host's iGPU. Both models coexist in memory without host swapping.

### Phase 1 — Twilio voice number (no SMS) *(reversible)*

**Goal:** Working A2P 10DLC number that accepts voice calls, with no A2P
10DLC dependency.

1. Upgrade Twilio account from trial to paid — trial accounts have caller
   restrictions and can't use A2P at all (relevant for Phase 4).
2. Buy an A2P 10DLC local number (~$1.15/month).
3. Verify inbound calls reach a throwaway TwiML `<Say>Hello</Say>` response
   (hard-code the TwiML in the Twilio console, no server yet).
4. Record the number, its SID, and webhook URL in `.secrets.yml` (infra
   tier per ADR-0004 — the Twilio account SID and auth token are
   infrastructure automation credentials, not user data).

**Success:** A human can dial the number and reach the hello-world TwiML.

### Phase 2 — Pipecat pipeline with local stack

**Goal:** Replace the hello-world with a Pipecat agent running entirely on
the `voice-agent` host, reached via a Headscale-routed ingress on
`gitlab-host`.

1. Create the per-role config directory for the `voice-agent`, consistent
   with F23 Phase 8 per-server layout. Concrete path lives in the
   instance addendum.
2. Python venv + `pip install "pipecat-ai[ollama,whisper,silero,piper]"`.
3. Adapt Pipecat's foundational Twilio example
   (`pipecat-ai/pipecat/examples/foundational/`) to use:
   - `FastAPIWebsocketTransport` + `TwilioFrameSerializer`
   - `WhisperSTTService` (faster-whisper, `distil-large-v3` or `small.en`)
   - `OLlamaLLMService`
     (`base_url="http://localhost:11434/v1"`, `model="llama3.1:8b"`)
   - `PiperTTSService` (start simple; Kokoro upgrade is a Phase 3 option)
   - `SileroVADAnalyzer` for turn detection
4. Versioned system prompt at the `voice-agent`'s per-role config dir as
   `system_prompt.md` — persona, scope boundaries, refusal patterns. No
   tool access yet.
5. Systemd unit `voice-agent.service` under the same directory; starts on
   boot, restarts on failure.
6. Headscale-routed ingress so Twilio can reach the `voice-agent`'s
   WebSocket: `gitlab-host` terminates Twilio's TLS and forwards to the
   tailnet address. This is the **only** externally reachable surface in
   the voice path.
7. Point the Twilio number's voice webhook at the ingress URL.
8. First real call.

**Success:** A call to the number is answered by the local LLM, with
< 1.5 s round-trip latency p50, zero cloud AI inference, and the home
router's inbound port map unchanged.

### Phase 3 — Polish, coexistence tuning, observability

**Goal:** The voice agent is reliable enough to leave running 24/7 without
disrupting the coding agent.

1. Tune Ollama `keep_alive` per model (coding: `24h`, voice: `5m`) and
   verify eviction actually happens after idle.
2. Call log to local SQLite: timestamp, duration, caller (hashed),
   full transcript, disposition. Schema versioned alongside the rest of
   NWP configs.
3. System prompt iteration: persona, scope boundaries, explicit refusal of
   anything deployment-related, anything prod-credential-related, anything
   that looks like a prompt injection attempt.
4. Tool schema allowlist — initial set: **none**. Later candidates:
   read-only calendar lookup, weather, local note search. Each addition
   requires explicit scope review.
5. Load test: run a call while the coding agent is mid-task; verify
   coding-agent tokens/sec doesn't drop more than 10 %.
6. Failure modes:
   - Ollama busy -> voice agent responds with a fallback apology and hangs
     up gracefully, no hanging call.
   - Model fails to load -> ditto.
   - Twilio WebSocket drops mid-call -> clean teardown, log the drop.
   - Headscale ingress down -> Twilio's failover webhook (a static TwiML
     "try again later") catches the call so it doesn't just ring.
7. Metrics scrape: call count, p50/p95 latency, STT/LLM/TTS cold-start
   timings. Exported to the host's local dashboard (no cloud telemetry).
8. Runbook: how to swap the telephony provider (Twilio -> Telnyx), how to
   roll the system prompt, how to rotate the Twilio auth token, how to
   decommission the whole stack.

**Success:** 7 consecutive days of operation with ≥ 10 test calls, zero
incidents affecting the coding agent's SLA, metrics visible on the host's
local dashboard, and the telephony-provider-swap runbook has been walked
through on paper at least once.

### Phase 4 — SMS (parallel, slow track, gated on A2P 10DLC)

**Goal:** Enable SMS on the same number once TCR registration completes.
This phase can start at any time in parallel with Phase 1–3; its
completion does **not** gate voice.

1. Gather non-US business registration details. Twilio's Sole Proprietor
   path is US/Canada only and cannot be used; the registration must go
   through the Business Representative path with a local business
   registration ID.
2. Update any NWP-adjacent public website's privacy policy to explicitly
   mention SMS — collection, usage, opt-out. This is the #1 TCR rejection
   cause. The words "SMS" and the handling description must be present.
3. Draft the opt-in flow description, sample messages (every sample must
   include HELP and STOP instructions), and a specific use case narrative
   (vague descriptions are the #2 rejection cause).
4. Submit Brand registration in Twilio Console -> TCR (approves in minutes).
5. Submit Campaign registration with everything above (10–15 day review).
6. Expect at least one rejection cycle; iterate on whichever element was
   flagged.
7. Once approved, add an SMS handler to the Pipecat service (or a
   separate tiny webhook) that routes to the same local LLM with a
   different system prompt specialized for text.
8. Costs to accept:
   - Brand: $4.50 (low-volume) or $46 (standard) one-time
   - Campaign: $15 one-time vetting
   - Campaign: $1.50–$10/month recurring
9. **Fallback if TCR registration is rejected permanently:** document the
   rejection reasons, defer SMS indefinitely, voice continues to work.
   Do not try to work around TCR via toll-free — toll-free verification
   now requires the same business registration details, so there is no
   shortcut.

**Success:** SMS can be sent and received on the same number, routed to
the same local LLM, without violating any TCR approval conditions.

---

## 5. Affected NWP Components

### 5.1 New Paths (under the `voice-agent`'s per-role config dir)

| Path | Purpose |
|---|---|
| `<voice-agent-role-dir>/` | Pipecat pipeline, systemd unit, helper scripts |
| `<voice-agent-role-dir>/pipeline.py` | Main Pipecat pipeline definition |
| `<voice-agent-role-dir>/system_prompt.md` | Versioned system prompt |
| `<voice-agent-role-dir>/voice-agent.service` | Systemd unit |
| `<voice-agent-role-dir>/requirements.txt` | Pinned Python dependencies |
| `<voice-agent-role-dir>/README.md` | Operator runbook |
| `<voice-agent-role-dir>/.gitignore` | Excludes `calls.db`, `venv/`, transcripts, local cache |

The concrete filesystem path resolves through `pl host voice-agent`
(see F33) which reads `instance-manifest.yml`.

### 5.2 Modified Paths

| Path | Change |
|---|---|
| `.secrets.example.yml` | Add `twilio.account_sid`, `twilio.auth_token`, `twilio.voice_number_sid` (all infra tier) |
| `<voice-agent-host-config>` | Add `voice_agent.enabled`, `voice_agent.headscale_ingress`, `voice_agent.model`, `voice_agent.keep_alive` |
| `docs/governance/roadmap.md` | Add X02 entry under "Experimental" |

### 5.3 Not Modified

No changes to `lib/`, `scripts/commands/`, `pl`, `recipes/`, or any core
NWP machinery. This proposal is deliberately self-contained under the
`voice-agent`'s per-role config dir so that deleting that directory (plus
reverting three small edits in 5.2) fully removes it.

---

## 6. Risk Assessment

### High Risk

| Risk | Mitigation |
|---|---|
| **Prompt injection via a phone call to reach tools.** An attacker calls the number and talks the agent into invoking something dangerous. | Tool allowlist starts **empty**. Any tool addition requires an explicit scope review. System prompt explicitly refuses anything deployment-related. The `voice-agent` host has no prod credentials regardless of what the agent is persuaded to try. |
| **A2P 10DLC rejection due to privacy policy.** TCR rejects SMS registration because the public privacy policy doesn't mention SMS. | Phase 4 is gated on privacy policy update; Phase 1–3 (voice) has no dependency on it. Rejection loops are expected; budget multiple rounds. |
| **Twilio SaaS disruption** (account suspended, policy change, price change). | Pipecat transport abstraction — swap to Telnyx/Bandwidth/SignalWire/self-hosted Asterisk is a single-file change. Phase 3 runbook documents the swap. |
| **Voice model evicts coding agent during call.** | Phase 0 preflight validates memory headroom. `keep_alive=5m` on voice ensures eviction. Phase 3 load test catches regressions. |

### Medium Risk

| Risk | Mitigation |
|---|---|
| Headscale ingress complexity (Twilio -> tailnet via `gitlab-host`) | Reuse F21 Phase 1 Headscale; document the ingress pattern once, reuse for future services |
| Latency > 1.5 s on busy host | Phase 3 metrics; fall back to smaller STT model (`small.en`) or harder-quantized voice LLM |
| TCR rejection cycles on SMS (Phase 4) | Plan multiple submission attempts; 10–15 day per cycle accepted as normal; voice is unaffected |
| Co-tenancy with `gitlab-host` | If undesirable, spin up a sibling host for the ingress; document trade-off |

### Low Risk

| Risk | Mitigation |
|---|---|
| Pipecat dependency churn | Pinned versions; reproducible venv; Ollama is the load-bearing dep and is stable |
| Audio quality from Piper is too robotic | Phase 3 upgrade path to Kokoro (better quality, still CPU-friendly) |
| BIOS iGPU memory allocation locked too low | Phase 0 catches this; escalate to vendor BIOS update or kernel `amdgpu.gttsize` param |

---

## 7. Success Criteria

- [ ] 8B-class local LLM answers phone calls on the Twilio number
- [ ] Zero cloud AI inference in the call path
- [ ] Voice agent response latency < 1.5 s p50
- [ ] Coding agent's tokens/sec does not degrade more than 10 % during a concurrent voice call
- [ ] Voice agent has no path to prod credentials (tool allowlist empty or scope-reviewed)
- [ ] Twilio provider swap would take < 1 hour (verified by documented runbook, not necessarily executed)
- [ ] Voice agent runs as a systemd service with restart-on-failure
- [ ] No inbound port open on the home router for the voice path
- [ ] 7 consecutive days of operation with ≥ 10 test calls and no incident
- [ ] Call logs stored locally only, gitignored
- [ ] (Phase 4, parallel track, not blocking) SMS works after TCR approval, or rejection is documented and SMS is deferred

---

## 8. Open Questions

- **Which country's business registration** will Twilio accept for A2P 10DLC?
  This depends on the operator's jurisdiction (recorded in
  `instance-manifest.yml`).
- **Headscale ingress** — reuse `gitlab-host` as the ingress proxy, or
  spin up a sibling? Reuse preferred (lower surface), sibling safer (isolation).
- **Primary coding model on the `ai-host`** — which model and what quantization?
  Needed to size the Phase 0 coexistence test accurately. (This is also
  an F21 open question.)
- **Use case**. "Ambient assistant" is too vague; narrowing to e.g.
  "after-hours voicemail with smart summaries", "inbound monitoring triage",
  or "personal appointment taker" would focus the system prompt and the
  success criteria. Deferred to Phase 2 kickoff.
- **TTS voice choice** — Piper (fast, robotic), Kokoro (fast, warmer), or
  XTTS (slower, best quality)? Start Piper, decide in Phase 3.
- **ADR needed?** This proposal implements a non-trivial trust decision
  (accepting Twilio as an unavoidable SaaS dependency). If Phase 2 lands,
  consider writing ADR-00XX to make that decision explicit and link it
  from CLAUDE.md § "Threat Model".

---

## 9. Out of Scope

- Outbound calling beyond test dials
- Any integration with production sites
- Voice cloning / impersonation / synthesized operator voice
- Multi-language beyond English
- Mobile app or web frontend — the interface is the phone line
- Replacing existing monitoring/alerting (that remains F21 Phase 12's job;
  voice is a complement, not a substitute)
- "Agentic" behavior — the agent converses; it does not autonomously take
  actions, at least until the tool allowlist is explicitly reviewed and
  expanded

---

## 10. Cross-references

- **[CLAUDE.md § Threat Model](../../CLAUDE.md)** — paranoid + open-source + local-first assumptions this proposal inherits
- **[Local LLM Guide](../guides/local-llm.md)** — Ollama baseline this proposal builds on
- **F21 Phase 3a** — concrete `ai-host` provisioning plan X02 inherits from
- **[F21: Distributed Build/Deploy Pipeline](F21-distributed-build-deploy-pipeline.md)** — defines the `ai-host` role and the "no prod access" rule
- **[ADR-0004: Two-tier Secrets Architecture](../decisions/0004-two-tier-secrets-architecture.md)** — classifies Twilio credentials as infra tier
- **[ADR-0011: Proposal Designation System](../decisions/0011-proposal-designation-system.md)** — justifies the X## prefix
- **[ADR-0017: Distributed Build/Deploy Pipeline](../decisions/0017-distributed-build-deploy-pipeline.md)** — the `ai-host`'s trust boundary

---

## 11. Reference Deployment

In the operator's deployment, the role bindings for `voice-agent`,
`ai-host`, and `gitlab-host` are documented in the private instance
addendum (`_proposals-private/X02-instance.md` in the operator's
`nwp-instances/` overlay). The addendum captures the specific hardware
SKU, Ollama backend choice, the Twilio number SID, and the
milestone-to-commit-hash mapping; none of that is required to understand
or implement X02.

---

## 12. Progress Notes (status only)

- **Phase 0 preflight DONE** — local 8B-class model verified at voice-grade
  latency while the coding agent was loaded. Detailed benchmark numbers
  are in the private addendum.
- **Direct-mic push-to-talk loop DONE** — a push-to-talk voice loop that
  talks to the `voice-agent` host directly via its attached mic and speaker
  (no Twilio, no PSTN) is working. This validates the local STT/LLM/TTS
  pipeline before Phase 2 wires it up to Pipecat. Stack: whisper.cpp (base.en),
  Ollama (8B-class), Piper (en_US-lessac-medium), USB mic + onboard analog
  output, bash push-to-talk script. Hardware-specific device paths and
  pre-requisite group memberships are in the private addendum.
- **Whisper accent benchmark DONE** — accent-bias hypothesis (Australian
  English vs. `base.en`) was weaker than expected. The one genuine accent
  error was shared by `base.en`, `medium.en`, and multilingual
  `large-v3-turbo`, so it is an LM-level decoding bias, not fixable by
  model swap. Implications captured in `docs/guides/voice-agent.md`
  § "Whisper model benchmark"; the upshot for Phase 2 is to budget for
  prompt-level vocabulary hints rather than a blanket model upgrade.
