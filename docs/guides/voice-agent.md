# Voice Agent — Dev Briefing

This doc is the **kick-off briefing for a Claude Code session focused on
improving the voice chat loop on the voice-agent host**. It is deliberately short on
history and long on concrete pointers. If you are a fresh Claude session
that has just been handed this file, read it end-to-end before touching
anything.

## How to use this doc to start a session

Paste this into a new Claude Code session in `~/nwp`:

> Read `docs/guides/voice-agent.md` for context on the voice-agent host's local voice
> agent. I want to improve it — ask me what aspect first, then propose
> concrete changes. Don't start coding until we've agreed on scope. The
> agent runs on a remote host (the voice-agent role, reachable via `ssh <voice-agent>` from
> this dev workstation); treat `ssh <voice-agent> '<cmd>'` as your normal way to
> probe state.

Then tell Claude which improvement area you want (§ "Improvement ideas").

## What exists today (as of 2026-04-09)

A **push-to-talk voice loop** on the voice-agent host that records from a USB mic,
transcribes with whisper.cpp, sends to ollama's `llama3.1:8b`, speaks
the reply with piper. Fully local — no cloud inference, no PSTN, no
Twilio. This is **not** the X02 Twilio endgame; it is a useful
side-effect that validated the local STT/LLM/TTS pipeline.

### Pipeline

```
ENTER (start) → arecord from plughw:2,0 (POROSVOC USB mic, 16 kHz mono)
              → ENTER (stop)
              → whisper.cpp / ggml-base.en (CPU, ~150 ms for short clips)
              → ollama /api/chat with llama3.1:8b (iGPU Vulkan, shared with coding agent)
              → piper / en_US-lessac-medium (CPU, RTF ≈ 0.03)
              → aplay to plughw:1,0 (ALC897 motherboard analog out)
              → loop
```

### Files of record (dev-side in this repo, deployed to voice-agent host)

| Path in repo | Deployed to | Purpose |
|---|---|---|
| `servers/<voice-agent>/bin/voice-agent` | `~/.local/bin/voice-agent` | The bash loop itself |
| `servers/<voice-agent>/bin/ollama-health-check` | `~/.local/bin/ollama-health-check` | Unrelated but colocated |
| `docs/proposals/X02-local-voice-agent.md` §11 | — | Historical progress notes |

### Binaries + models on the voice-agent host (NOT in repo)

| Path on voice-agent host | What | Install origin |
|---|---|---|
| `~/.local/bin/whisper-cli` | whisper.cpp CLI | Built from `~/src/whisper.cpp` (CPU release, no Vulkan) |
| `~/.local/share/whisper/ggml-base.en.bin` | whisper base.en (142 MB) — **currently used by the script** | HF `ggerganov/whisper.cpp` |
| `~/.local/share/whisper/ggml-medium.en.bin` | whisper medium.en (1.5 GB) — benchmark candidate, see §Whisper benchmark | HF `ggerganov/whisper.cpp` |
| `~/.local/share/whisper/ggml-large-v3-turbo.bin` | whisper large-v3-turbo (1.6 GB) — multilingual benchmark candidate | HF `ggerganov/whisper.cpp` |
| `~/.local/bin/piper` → `~/src/piper/piper` | piper TTS 1.2.0 | `piper_linux_x86_64.tar.gz` release |
| `~/.local/share/piper/voices/en_US-lessac-medium.onnx(+.json)` | piper voice — **currently used by the script** | HF `rhasspy/piper-voices` |
| `~/.local/share/piper/voices/en_GB-cori-high.onnx(+.json)` | piper voice, en_GB high-quality — TTS A/B candidate (closest thing to AU in piper) | HF `rhasspy/piper-voices` |
| `~/.local/bin/ollama` | ollama daemon | See `docs/guides/local-llm.md` |
| Models: `llama3.1:8b`, `qwen2.5-coder:14b` (both Q4_K_M) | Chat + coding | `ollama pull` |

### Audio hardware

Three sound cards visible to the kernel on the voice-agent host:

- card 0 — AMD Radeon HDMI (playback only, not used)
- card 1 — ALC897 motherboard, analog **playback AND capture** (`plughw:1,0`)
- card 2 — POROSVOC USB mic, **capture only** (`plughw:2,0`) — no playback node

Defaults in the script: `MIC_DEVICE=plughw:2,0`, `SPEAKER_DEVICE=plughw:1,0`.
Override via env vars `VOICE_AGENT_MIC` / `VOICE_AGENT_SPEAKER`.

**Critical gotcha:** the operator user on the voice-agent host must be in the `audio`
group. Earlier this week the group was missing and PipeWire only
showed a `auto_null` Dummy-Driver. Fixed with `sudo usermod -aG audio <operator>`.
If you find audio is broken, check `groups` on the voice-agent host first.

### Verified working

- ✓ piper synthesises audio (RTF 0.03, very fast)
- ✓ aplay runs without error on `plughw:1,0` (whether sound is audible
  depends on whether something is plugged into the 3.5 mm jack)
- ✓ arecord opens `plughw:2,0` and returns frames (the frames are silent
  unless a human is physically in front of the POROSVOC — see NOT verified)
- ✓ whisper-cli transcribes (correctly reports `[BLANK_AUDIO]` on silence)
- ✓ ollama chat API returns replies through the existing loopback daemon
- ✓ End-to-end: voice-agent script deployed and passes `bash -n`
- ✓ Whisper `base.en` / `medium.en` / `large-v3-turbo` all run on the voice-agent host
  CPU within budget for push-to-talk (see §Whisper benchmark, 2026-04-09)
- ✓ POROSVOC confirmed native format: `S16_LE / 16000 Hz / mono`
  **only** (per `/proc/asound/card2/stream0`) — script's defaults
  already match this, no conversion tax
- ✓ POROSVOC capture volume control exposes only ~0.39 dB of digital
  range (`dBminmax-min=0.00dB,max=0.39dB`) — the real preamp is
  hardware-fixed inside the USB device; do not expect ALSA-level gain
  tuning to help quiet input

### NOT yet verified by a human

- Physical audibility of the speaker (no one has confirmed sound
  actually came out of the 3.5 mm jack during our test)
- **POROSVOC capturing real voice from a human physically at the voice-agent host.**
  On 2026-04-09 we tried this from dev and got `peak=0` silence: the
  mic enumerates fine (USB bus 003 dev 008, `/proc/asound/card2/stream0`
  healthy, ALSA mixer at 100%, nothing holding `/dev/snd/*`) but nobody
  was in the voice-agent room, so there was nothing for the capsule to hear.
  Workaround used for the whisper benchmark: record on dev's mic,
  `scp` WAV to the voice-agent host, run whisper-cli there. See limitation #9.
- A full end-to-end voice conversation with a real user speaking to
  the mic (the accent benchmark used dev-mic clips, not POROSVOC clips)

### Whisper model benchmark (2026-04-09)

Two speakers (both Australian English), same sentence constructed to
pack accent-tricky phonemes: `g'day, reckon, barbie, arvo, fertile,
docile, water, dance, castle, tomato, pasta, no worries, mate,
Melbourne, schedule, Our Father, cheers`. Clips recorded on dev's
digital mic (16 kHz mono S16_LE, ~25 s each) and `scp`'d to the voice-agent host for
transcription. Test clips preserved at `<voice-agent>:/tmp/voice-test-{op1,op2}.wav`
and `dev:/tmp/dev_{op1,op2}.wav` for reproducibility.

**Latency per model** (25-sec clip, CPU, 4 threads):

| Model | Size | Wall-clock | Realtime factor | Est. for 5-sec utterance |
|---|---|---|---|---|
| `ggml-base.en` | 142 MB | ~0.9 s | 0.04× | **~0.18 s** |
| `ggml-medium.en` | 1.5 GB | ~6.5 s | 0.26× | **~1.3 s** |
| `ggml-large-v3-turbo` | 1.6 GB | ~7.7 s | 0.31× | **~1.5 s** |

**Accuracy finding (surprising):** the accent-bias hypothesis did not
pan out as expected. All three models correctly transcribed `docile`,
`fertile`, `dance`, `castle`, `tomato`, `pasta`, `water`, `Melbourne`
on both speakers — words we expected to expose US-corpus bias. The
multilingual `large-v3-turbo` was **not** meaningfully better than the
English-only `medium.en`.

**The one genuine accent error, shared by every model:**
`"say an Our Father"` → `"say in our father"`. The AU reduction of
unstressed `an` to /ən/ is decoded as `in` by whisper's language model
regardless of model size or training corpus. This is an LM-level bias,
not an audio-quality issue — **swapping whisper models does not fix it**.
The right fix is a post-processing regex or a custom vocabulary prompt
(whisper's `--prompt`, or `initial_prompt` in `faster-whisper`).

**Other minor errors observed:**

- `base.en` on Speaker 1's clip transcribed `arvo` as `arbo` (single data point;
  `base.en` got it right on Speaker 2's clip)
- `base.en` on Speaker 1's clip capitalized `Barbie` (the doll)
- `large-v3-turbo` on Speaker 2's clip capitalized `Arvo` (as a name)
- `Our Father` is never capitalized by any model — none recognize it as
  a proper-noun prayer reference

**Conclusion:** the data does not justify upgrading from `base.en`.
Latency cost (0.18 s → 1.3 s) is ~1.1 s per turn for marginal accuracy
gains on two data points. The real accuracy wins come from
post-processing and LM prompting, which cost nothing. Keep `base.en`
as the default; keep `medium.en` and `large-v3-turbo` on disk for
future re-benchmarking against more varied material.

## Known limitations (these are the interesting targets)

1. **Batch, not streaming.** whisper.cpp transcribes the full clip after
   recording stops. For conversational feel you want partial hypotheses
   while the user is still speaking. Options:
   - Use whisper.cpp `-stream` mode (it exists)
   - Switch to `faster-whisper` (Python, CTranslate2 backend, better streaming)
   - Roll chunked STT in the bash loop (slice clips, transcribe, concatenate)
2. **Push-to-talk, no wake word.** User has to hit ENTER twice per turn.
   No VAD (voice activity detection). Candidates: Silero VAD, porcupine
   wake-word (free for personal use), whisper.cpp's own VAD.
   **Chosen wake word: "Quokka"** — phonetically distinct (/kw/ onset),
   won't false-trigger on saint names or Catholic vocabulary common in
   this household. Resource cost is negligible (~10 MB RAM, ~1–2% CPU)
   but implementation requires Python (porcupine or openWakeWord), so
   this is X02 Phase 2 scope.
3. **No interruption handling.** If the assistant is mid-reply, user
   can't cut it off. Need to watch for mic input during aplay and stop it.
4. **Conversation history lives in /tmp.** Dies on exit. Fine for a
   throwaway but a session memory that survives reboots would be nicer.
5. **Single voice, single model.** No way to swap mid-conversation.
   (`--model` and `--voice` flags exist for startup only.)
6. **No metrics.** No way to see "how long did STT take vs LLM vs TTS."
   Would help latency tuning.
7. **No guard against the LLM emitting markdown/code fences.** The system
   prompt asks it not to, but piper will happily try to speak `**bold**`
   if the LLM leaks it. Needs a post-processing sanitizer.
8. **jq dependency.** Not a problem, just a note: the script uses jq
   for conversation history; it's already installed on the voice-agent host.
9. **No remote transport.** You must `ssh <voice-agent>` to run it. If the goal
   is "talk to the voice-agent while I'm at dev," you need one of: run the script
   over the SSH session with audio forwarded (hard); run the
   LLM-chat loop on dev instead with ollama as the backend (easy, but
   then it's not "voice-agent"); or build a network protocol (complex).
   **This limitation bit us during the 2026-04-09 accent benchmark** —
   we had to record on dev's mic and `scp` the WAV to the voice-agent host because the
   speakers were physically at dev, not the voice-agent host. Fine as a one-off test
   workaround; not a real solution for conversation. The real fix is
   X02 Phase 2 (Pipecat transport), not bash-script patches.
10. **LLM personality is thin.** The system prompt is one sentence.
    Improvement is in-band (just edit the prompt) but worth doing once
    the other mechanics work.
11. **Piper has no en_AU voices.** Voices ship only for `en_GB` and
    `en_US`. Closest in-piper option is `en_GB-cori-high` (the only
    `en_GB` voice piper ships at "high" quality — already downloaded
    to the voice-agent host, ready for A/B testing against the current
    `en_US-lessac-medium`). A **genuine** Australian voice requires a
    different TTS engine entirely — Coqui XTTS-v2 (voice cloning from
    a reference clip of an AU speaker) or Kokoro-82M — both Python-only.
    **That is X02 Phase 2 scope territory per ground rule #1**; do not
    sneak it into bash-script improvements.
12. **`"an"` → `"in"` decoding bias in whisper.** All three tested
    models (base.en, medium.en, large-v3-turbo) transcribe the AU
    reduction of unstressed `an` to `/ən/` as `in`. Not audio quality,
    not model size — it's an LM-level decoding bias. Only fixable via
    post-processing or `--prompt` context hints. See §Whisper benchmark.

## Improvement ideas, ranked by value-per-effort

**High value, low effort:**
- Add latency metrics to the script (dump timing per stage to stderr)
- Sanitise LLM output before piper (strip markdown, code fences, URLs)
- **Post-process STT output** to fix the known accent/decoding errors:
  `s/\bsay in our father\b/say an Our Father/i`, normalize `arbo`→`arvo`,
  capitalize `Our Father` as a proper noun. Cheaper than a whisper model
  swap — the benchmark (see §Whisper benchmark) showed bigger models
  don't fix these errors anyway.
- **Pass a `--prompt` context hint to whisper-cli** so the LM is biased
  toward known phrases (`"G'day. Our Father who art in heaven. Arvo,
  barbie, mate."`). Costs nothing, may help the `an`→`in` issue.
- Persist conversation history to `~/.local/share/voice-agent/history.jsonl`
- Nicer system prompt with explicit tone and boundaries
- **A/B the new `en_GB-cori-high` piper voice** against current
  `en_US-lessac-medium` — files already on the voice-agent host, closest piper gets to
  an Australian voice. Single-line change once a winner is picked.

**High value, moderate effort:**
- Streaming STT via whisper.cpp's stream example (look in
  `~/src/whisper.cpp/examples/stream/`)
- VAD-based turn detection (Silero, loaded once, run over the mic
  stream — end-of-speech triggers STT)
- Interruption handling: monitor mic level during aplay, stop aplay on
  activity

**High value, high effort:**
- faster-whisper Python rewrite (bigger scope: needs a venv, signals a
  rewrite in Python rather than bash — X02 Phase 2 territory)
- Wake word (porcupine, openWakeWord, or whisper-based)
- Turn the whole thing into a daemon with an API, then have dev talk to
  it over SSH port-forward

**Speculative:**
- Swap LLMs mid-conversation based on intent ("/code" → qwen2.5-coder,
  default → llama3.1)
- Tool use: let the agent run a whitelisted set of commands on the voice-agent host
  (dangerous; needs the same scope review X02 §3.3 demands)

## How to test a change

The loop is fast enough to iterate in real time. Typical cycle:

```bash
# dev side: edit and push
$EDITOR servers/<voice-agent>/bin/voice-agent
scp servers/<voice-agent>/bin/voice-agent <voice-agent>:.local/bin/voice-agent

# sanity
ssh <voice-agent> 'bash -n ~/.local/bin/voice-agent && echo OK'

# smoke test STT alone
ssh <voice-agent> 'arecord -D plughw:2,0 -f S16_LE -r 16000 -c 1 -d 3 /tmp/t.wav && \
          ~/.local/bin/whisper-cli -m ~/.local/share/whisper/ggml-base.en.bin \
            -f /tmp/t.wav -nt -np 2>/dev/null'

# smoke test TTS alone
ssh <voice-agent> 'echo hello | ~/.local/bin/piper \
            --model ~/.local/share/piper/voices/en_US-lessac-medium.onnx \
            --output_file /tmp/t.wav && aplay -D plughw:1,0 /tmp/t.wav'

# smoke test LLM alone (uses the same ollama daemon the voice agent hits)
ssh <voice-agent> 'curl -sS http://127.0.0.1:11434/api/chat \
            -d "{\"model\":\"llama3.1:8b\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":false}" \
            | jq -r .message.content'

# full loop (interactive — you need to be sitting at the voice-agent host or speaking loudly through ssh)
ssh <voice-agent> 'voice-agent'
```

## Related reading (load these into context as needed)

- `docs/guides/local-llm.md` — the ollama baseline this builds on
- `docs/proposals/X02-local-voice-agent.md` — the long-term plan.
  Phase 0 done, §11 documents what this script delivers.
- `docs/proposals/F21-distributed-build-deploy-pipeline.md` Phase 3a —
  provisioning context for the voice-agent host as the local-LLM host
- `CLAUDE.md` § "Threat Model" — the voice-agent host is in the **AI-accessible tier**;
  it has **no prod access** and must never gain any. The voice agent's
  tool allowlist is **empty** and stays empty until an explicit scope
  review happens
- Memory: `voice-agent-llm-baseline.md` has the reboot-tested state of the
  ollama daemon, model benchmarks, and the audio-group gotcha

## Ground rules for changes

1. **Keep the bash script bash.** If you need Python, that is a signal
   you are crossing into X02 Phase 2 territory; stop and talk to the operator
   about whether this is still "incremental improvement" or "start the
   rewrite." Don't sneak a venv in under the bash-improvement banner.
2. **Keep it local.** No new cloud dependencies. No new SaaS. The entire
   point of this thing is that audio never leaves the voice-agent host.
3. **Don't add tool use without scope review.** See CLAUDE.md and X02
   §3.3. The tool allowlist is empty.
4. **Signing:** commit edits to `servers/<voice-agent>/bin/voice-agent` from dev,
   not from the voice-agent host. The voice-agent host is AI-accessible; dev is where the signing key
   lives. Deploy via `scp`.
5. **Threat model carries over.** the voice-agent ollama is on loopback, not LAN.
   Do not bind it to `0.0.0.0` for convenience.

## Open questions a new session should ask before coding

- Which improvement area is the priority *right now*? (streaming?
  wake-word? interruption? prompt quality? metrics?)
- Is the target still "bash script on the voice-agent host driven by SSH," or has the
  remote-from-dev question (limitation #9) become urgent?
- Is the speaker physically connected and audible? (If not, a lot of
  this work is academic until that is fixed.)
- Does the operator have latency he can tolerate, or is it "tune it until it
  feels good"? Without a number you will over-tune.
