# X02: Local Voice Agent on mini (Twilio + Pipecat + local LLM)

**Status:** PROPOSED
**Created:** 2026-04-08
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** Low (scope expansion; exploratory)
**Depends On:** F21 Phase 3a (mini as local-LLM agent), F21 Phase 1 (Headscale), F21 Phase 3 (mini as runner — soft dep). Operator orientation: [`docs/guides/local-llm.md`](../guides/local-llm.md).
**Breaking Changes:** None
**Estimated Effort:** ~4 phases; Phases 0–3 can land in a long weekend, Phase 4 (SMS) paces at TCR's 10–15 day review cycle

---

## 1. Executive Summary

Run an AI voice agent on **mini** (Beelink Ryzen AI Max+ 395) that answers phone
calls on a Twilio US 10DLC number using a fully local stack: Pipecat
orchestration + faster-whisper STT + Llama 3.1 8B (or Qwen 2.5 7B) on Ollama
+ Piper/Kokoro TTS.

This is explicitly scope expansion beyond NWP's core Drupal deployment
mission — hence the X## designation per ADR-0011. The justification is that
mini is NWP's day-to-day agent tier (see CLAUDE.md § "Distributed Actor
Glossary" and F21), and giving mini a voice channel is a natural extension
of that role. If the experiment turns out to be noise, the whole stack
deletes cleanly: it lives under `servers/mini/voice-agent/` and touches no
core NWP machinery.

The load-bearing constraint: **the voice agent must not evict the coding
agent**, which is mini's primary job. This is achieved by running the voice
LLM on-demand (`keep_alive=5m`) while the coding model stays resident
(`keep_alive=24h`). Calls are sporadic; the coding agent is steady; Strix
Halo's unified LPDDR5X pool absorbs the brief overlap.

Third-party SaaS (Twilio) is unavoidable for PSTN access — the only
self-hosted alternative is becoming a CLEC. The mitigation is keeping
everything *above* the audio layer local: all STT/LLM/TTS/state stays on
mini. Twilio sees only the TLS audio stream, never transcripts or model
state. Pipecat's transport abstraction means swapping Twilio for Telnyx,
Bandwidth, SignalWire, or a self-hosted Asterisk + SIP trunk is a
single-file change.

---

## 2. Goals & Non-Goals

### Goals

- **Inbound voice answered by a local LLM** on mini
- **No cloud AI** — STT/LLM/TTS all on mini, audio the only thing Twilio sees
- **Coexist with mini's coding agent** without evicting it
- **Pipecat as the orchestration layer** — vendor-neutral so telephony can
  be swapped later without rewriting the agent
- **Sub-1.5 s response latency p50** for 8B-model conversations
- **No webhook exposure to the open internet** — Twilio reaches mini only
  through a Headscale-routed ingress

### Non-Goals

- **Outbound robocalling** — unwanted, and triggers different regulatory
  scrutiny
- **SMS-first agent** — SMS requires A2P 10DLC registration (10–15 day TCR
  review for a non-US business registration), which is a parallel track
  (Phase 4) with its own gating; voice does not wait on it
- **Production integration** — mini is in the AI-capable tier per F21; it
  must not reach prod. The voice agent's tool allowlist starts empty and
  nothing prod-adjacent is ever added to it
- **Replacing commercial telephony** — this is a self-tooling experiment,
  not a product
- **Voice cloning / impersonation** — generic TTS voices only
- **Multi-language** — English-only to start

---

## 3. Architecture

### 3.1 Component diagram

```
Phone call (PSTN)
  → Twilio US 10DLC number
  → Twilio Media Streams (WebSocket, bidirectional audio, TLS)
  → au-mel ingress (Headscale exit node, reuses git.nwpcode.org Linode)
  → mini:<port> (Pipecat FastAPI WebSocket transport)
      │
      ├─ Silero VAD          (CPU)      turn detection
      ├─ faster-whisper      (CPU)      STT (distil-large-v3 or small.en)
      ├─ Ollama              (iGPU)     LLM
      │    ├─ coding model:  keep_alive=24h   (primary tenant, always on)
      │    └─ voice model:   keep_alive=5m    (loads on call, unloads after)
      ├─ Piper or Kokoro     (CPU)      TTS
      └─ Local SQLite        (disk)     call log, transcripts (gitignored)
```

### 3.2 Resource strategy

mini's Radeon 8060S iGPU and unified LPDDR5X memory are shared between the
coding agent (primary) and the voice agent (sporadic).

| Workload          | Runtime              | Keep-alive | Notes                               |
|-------------------|----------------------|------------|-------------------------------------|
| Coding agent LLM  | Ollama / iGPU        | `24h`      | Always resident                     |
| Voice agent LLM   | Ollama / iGPU        | `5m`       | Loads on call start, unloads after  |
| STT (whisper.cpp) | CPU (Zen 5 cores)    | n/a        | Streaming, ~150 ms cold start       |
| TTS (Piper)       | CPU                  | n/a        | Effectively instant                 |
| VAD (Silero)      | CPU                  | n/a        | Tiny                                |

During a call, both LLMs are briefly co-resident (~5 GB voice + ~20 GB
coding ≈ 25 GB on the iGPU side), which Strix Halo's unified memory handles
comfortably on a 64 GB+ SKU. After the call, the voice model is evicted and
bandwidth is fully available to the coding agent again. STT/TTS on CPU means
the iGPU is only contended for LLM work.

### 3.3 Threat model alignment

Follows CLAUDE.md § "Threat Model" and F21 § "Distributed Actor Glossary":

- **mini has no prod access.** Voice agent reads no prod credentials. The
  voice agent's tool schema starts with an **empty allowlist**. Any future
  tool requires an explicit scope review before being added, and nothing
  `pl deploy`-adjacent is ever exposed.
- **Twilio as a distrusted SaaS boundary.** Only audio crosses the
  boundary. Pipecat's `TwilioFrameSerializer` is the only code in NWP that
  talks to Twilio; swapping to Telnyx / Bandwidth / SignalWire / self-hosted
  Asterisk is a single-file change verified by the Phase 3 runbook.
- **No webhook exposure to the open internet.** No port opens on the home
  router. Pipecat's WebSocket is reached via a Headscale-routed ingress
  (reusing the `au-mel` Linode that hosts `git.nwpcode.org` post-F21 Phase 4,
  or a sibling Linode if co-tenancy is undesirable).
- **Call logs stay local.** SQLite on mini, gitignored. Transcripts never
  leave the home LAN.
- **Signed commits apply unchanged.** Changes to `servers/mini/voice-agent/`
  go through the same signed-commit discipline as the rest of NWP.

---

## 4. Phased Implementation

### Phase 0 — Preflight on mini *(reversible)*

**Goal:** Verify mini can run an 8B model at voice-grade latency *while*
the coding agent is loaded, before investing in Pipecat.

1. Confirm Ollama is installed on mini; install with Vulkan backend if not.
2. `ollama pull llama3.1:8b` and `ollama pull qwen2.5:7b-instruct`.
3. Benchmark tokens/sec and first-token latency using `ollama run --verbose`.
4. Confirm the iGPU backend (Vulkan or ROCm) is actually being used
   (`nvtop` / `radeontop`). CPU fallback is a red flag at this stage.
5. Measure memory headroom with the coding model *and* a voice model loaded
   simultaneously. Check whether `OLLAMA_KEEP_ALIVE` per-request overrides
   behave as documented.
6. Sanity-check BIOS iGPU memory allocation — some Beelink SKUs lock it
   lower than Strix Halo allows; raise it if needed.

**Success:** 8B model first-token < 400 ms, steady-state > 25 tok/s on
mini's iGPU. Both models coexist in memory without host swapping.

### Phase 1 — Twilio voice number (no SMS) *(reversible)*

**Goal:** Working US 10DLC number that accepts voice calls, with no A2P
10DLC dependency.

1. Upgrade Twilio account from trial to paid — trial accounts have caller
   restrictions and can't use A2P at all (relevant for Phase 4).
2. Buy a US 10DLC local number (~$1.15/month).
3. Verify inbound calls reach a throwaway TwiML `<Say>Hello</Say>` response
   (hard-code the TwiML in the Twilio console, no server yet).
4. Record the number, its SID, and webhook URL in `.secrets.yml` (infra
   tier per ADR-0004 — the Twilio account SID and auth token are
   infrastructure automation credentials, not user data).

**Success:** A human can dial the number and reach the hello-world TwiML.

### Phase 2 — Pipecat pipeline with local stack

**Goal:** Replace the hello-world with a Pipecat agent running entirely on
mini, reached via a Headscale-routed ingress.

1. Create `servers/mini/voice-agent/` (new subdirectory under mini's
   server config, consistent with F23 Phase 8 per-server layout).
2. Python venv + `pip install "pipecat-ai[ollama,whisper,silero,piper]"`.
3. Adapt Pipecat's foundational Twilio example
   (`pipecat-ai/pipecat/examples/foundational/`) to use:
   - `FastAPIWebsocketTransport` + `TwilioFrameSerializer`
   - `WhisperSTTService` (faster-whisper, `distil-large-v3` or `small.en`)
   - `OLlamaLLMService`
     (`base_url="http://localhost:11434/v1"`, `model="llama3.1:8b"`)
   - `PiperTTSService` (start simple; Kokoro upgrade is a Phase 3 option)
   - `SileroVADAnalyzer` for turn detection
4. Versioned system prompt at `servers/mini/voice-agent/system_prompt.md`
   — persona, scope boundaries, refusal patterns. No tool access yet.
5. Systemd unit `voice-agent.service` under `servers/mini/voice-agent/`,
   starts on boot, restarts on failure.
6. Headscale-routed ingress so Twilio can reach mini's WebSocket: the
   `au-mel` Linode terminates Twilio's TLS and forwards to mini's tailnet
   address. This is the **only** externally reachable surface in the
   voice path.
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
   - Ollama busy → voice agent responds with a fallback apology and hangs
     up gracefully, no hanging call.
   - Model fails to load → ditto.
   - Twilio WebSocket drops mid-call → clean teardown, log the drop.
   - Headscale ingress down → Twilio's failover webhook (a static TwiML
     "try again later") catches the call so it doesn't just ring.
7. Metrics scrape: call count, p50/p95 latency, STT/LLM/TTS cold-start
   timings. Exported to mini's local dashboard (no cloud telemetry).
8. Runbook: how to swap the telephony provider (Twilio → Telnyx), how to
   roll the system prompt, how to rotate the Twilio auth token, how to
   decommission the whole stack.

**Success:** 7 consecutive days of operation with ≥ 10 test calls, zero
incidents affecting the coding agent's SLA, metrics visible on mini's
local dashboard, and the telephony-provider-swap runbook has been walked
through on paper at least once.

### Phase 4 — SMS (parallel, slow track, gated on A2P 10DLC)

**Goal:** Enable SMS on the same number once TCR registration completes.
This phase can start at any time in parallel with Phase 1–3; its
completion does **not** gate voice.

1. Gather non-US business registration details. Twilio's Sole Proprietor
   path is US/Canada only and cannot be used; the registration must go
   through the Business Representative path with a local business
   registration ID (Australian ABN/ACN or equivalent for the operator's
   jurisdiction).
2. Update any NWP-adjacent public website's privacy policy to explicitly
   mention SMS — collection, usage, opt-out. This is the #1 TCR rejection
   cause. The words "SMS" and the handling description must be present.
3. Draft the opt-in flow description, sample messages (every sample must
   include HELP and STOP instructions), and a specific use case narrative
   (vague descriptions are the #2 rejection cause).
4. Submit Brand registration in Twilio Console → TCR (approves in minutes).
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
   Do not try to work around TCR via toll-free — as of 2026-01-01 toll-free
   verification requires the same business registration details, so there
   is no shortcut.

**Success:** SMS can be sent and received on the same number, routed to
the same local LLM, without violating any TCR approval conditions.

---

## 5. Affected NWP Components

### 5.1 New Paths

| Path | Purpose |
|---|---|
| `servers/mini/voice-agent/` | Pipecat pipeline, systemd unit, helper scripts |
| `servers/mini/voice-agent/pipeline.py` | Main Pipecat pipeline definition |
| `servers/mini/voice-agent/system_prompt.md` | Versioned system prompt |
| `servers/mini/voice-agent/voice-agent.service` | Systemd unit |
| `servers/mini/voice-agent/requirements.txt` | Pinned Python dependencies |
| `servers/mini/voice-agent/README.md` | Operator runbook (swap provider, rotate tokens, decommission) |
| `servers/mini/voice-agent/.gitignore` | Excludes `calls.db`, `venv/`, transcripts, local cache |

### 5.2 Modified Paths

| Path | Change |
|---|---|
| `.secrets.example.yml` | Add `twilio.account_sid`, `twilio.auth_token`, `twilio.voice_number_sid` (all infra tier) |
| `servers/mini/.nwp-server.yml` | Add `voice_agent.enabled`, `voice_agent.headscale_ingress`, `voice_agent.model`, `voice_agent.keep_alive` |
| `docs/governance/roadmap.md` | Add X02 entry under "Experimental" |

### 5.3 Not Modified

No changes to `lib/`, `scripts/commands/`, `pl`, `recipes/`, or any core
NWP machinery. This proposal is deliberately self-contained under
`servers/mini/voice-agent/` so that deleting that directory (plus reverting
three small edits in 5.2) fully removes it.

---

## 6. Risk Assessment

### High Risk

| Risk | Mitigation |
|---|---|
| **Prompt injection via a phone call to reach tools.** An attacker calls the number and talks the agent into invoking something dangerous. | Tool allowlist starts **empty**. Any tool addition requires an explicit scope review. System prompt explicitly refuses anything deployment-related. mini has no prod credentials regardless of what the agent is persuaded to try. |
| **A2P 10DLC rejection due to privacy policy.** TCR rejects SMS registration because the public privacy policy doesn't mention SMS. | Phase 4 is gated on privacy policy update; Phase 1–3 (voice) has no dependency on it. Rejection loops are expected; budget multiple rounds. |
| **Twilio SaaS disruption** (account suspended, policy change, price change). | Pipecat transport abstraction — swap to Telnyx/Bandwidth/SignalWire/self-hosted Asterisk is a single-file change. Phase 3 runbook documents the swap. |
| **Voice model evicts coding agent during call.** | Phase 0 preflight validates memory headroom. `keep_alive=5m` on voice ensures eviction. Phase 3 load test catches regressions. |

### Medium Risk

| Risk | Mitigation |
|---|---|
| Headscale ingress complexity (Twilio → tailnet via au-mel Linode) | Reuse F21 Phase 1 Headscale; document the ingress pattern once, reuse for future services |
| Latency > 1.5 s on busy mini | Phase 3 metrics; fall back to smaller STT model (`small.en`) or harder-quantized voice LLM |
| TCR rejection cycles on SMS (Phase 4) | Plan multiple submission attempts; 10–15 day per cycle accepted as normal; voice is unaffected |
| Co-tenancy with `git.nwpcode.org` on au-mel Linode | If undesirable, spin up a sibling Linode for the ingress; document trade-off |

### Low Risk

| Risk | Mitigation |
|---|---|
| Pipecat dependency churn | Pinned versions; reproducible venv; Ollama is the load-bearing dep and is stable |
| Audio quality from Piper is too robotic | Phase 3 upgrade path to Kokoro (better quality, still CPU-friendly) |
| BIOS iGPU memory allocation locked too low | Phase 0 catches this; escalate to Beelink BIOS update or kernel `amdgpu.gttsize` param |

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

- **Which country's business registration** will Twilio accept for A2P 10DLC? Australian ABN assumed but needs verification on the TCR form.
- **Headscale ingress** — reuse `git.nwpcode.org`'s `au-mel` Linode as the ingress proxy, or spin up a sibling? Reuse preferred (lower surface), sibling safer (isolation).
- **Primary coding model on mini** — which model and what quantization? Needed to size the Phase 0 coexistence test accurately. (This is also an F21 open question.)
- **Use case**. "Ambient assistant" is too vague; narrowing to e.g. "after-hours voicemail with smart summaries", "inbound monitoring triage", or "personal appointment taker" would focus the system prompt and the success criteria. Deferred to Phase 2 kickoff.
- **TTS voice choice** — Piper (fast, robotic), Kokoro (fast, warmer), or XTTS (slower, best quality)? Start Piper, decide in Phase 3.
- **ADR needed?** This proposal implements a non-trivial trust decision (accepting Twilio as an unavoidable SaaS dependency). If Phase 2 lands, consider writing ADR-00XX to make that decision explicit and link it from CLAUDE.md § "Threat Model".

---

## 9. Out of Scope

- Outbound calling beyond test dials
- Any integration with production sites (avc, ss, dir1, …)
- Voice cloning / impersonation / synthesized operator voice
- Multi-language beyond English
- Mobile app or web frontend — the interface is the phone line
- Replacing existing monitoring/alerting (that remains F21 Phase 12's job; voice is a complement, not a substitute)
- "Agentic" behavior — the agent converses; it does not autonomously take actions, at least until the tool allowlist is explicitly reviewed and expanded

---

## 10. Cross-references

- **[CLAUDE.md § Threat Model](../../CLAUDE.md)** — paranoid + open-source + local-first assumptions this proposal inherits
- **[Local LLM Guide](../guides/local-llm.md)** — Ollama baseline this proposal builds on (promoted from F10 on 2026-04-08)
- **F21 Phase 3a** — the concrete mini provisioning plan X02 inherits from (see F21 proposal below)
- **[F21: Distributed Build/Deploy Pipeline](F21-distributed-build-deploy-pipeline.md)** — defines mini's role as the day-to-day agent tier and the "no prod access" rule
- **[ADR-0004: Two-tier Secrets Architecture](../decisions/0004-two-tier-secrets-architecture.md)** — classifies Twilio credentials as infra tier
- **[ADR-0011: Proposal Designation System](../decisions/0011-proposal-designation-system.md)** — justifies the X## prefix
- **[ADR-0017: Distributed Build/Deploy Pipeline](../decisions/0017-distributed-build-deploy-pipeline.md)** — mini's trust boundary
