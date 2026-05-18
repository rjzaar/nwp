# Voice Agent — Echo Cancellation / Barge-In Handoff

**Date:** 2026-04-09
**Status:** In progress — ec built, integration partially working, needs debugging

## Goal

Allow the user to interrupt quokka (voice-agent) while it's speaking.
Currently, `speak()` blocks (aplay plays the full reply, then the loop
starts listening). The user must wait for the entire reply before
speaking again. The goal is "barge-in": if the user speaks mid-reply,
quokka stops talking and listens.

## What was tried and why it failed

### Attempt 1: Non-blocking aplay + sox onset detection

Made `speak()` run `aplay` in the background and immediately start
`record_until_silence()`. A background watcher polled the sox output
file size — when sox started writing (>200 bytes = voice onset), the
watcher killed aplay.

**Result:** The Blue Yeti mic picked up quokka's own voice from the
speaker. Sox detected the speaker bleed as onset, killed aplay almost
immediately. Quokka cut itself off after ~0.5 seconds of every reply.

### Attempt 2: Higher onset threshold during playback

Raised the sox onset threshold from 0.5% to 3-5% during playback so
only direct voice (not speaker bleed) would trigger recording.

**Result:** Either still too sensitive (self-triggered) or too high
(missed the user's voice). Also introduced "empty recording, skipping"
cycles where sox caught brief speaker bleed as a tiny recording. The
threshold approach is fundamentally unreliable without knowing the
speaker-to-mic coupling level, which varies with volume, position, and
room acoustics.

### Attempt 3: voice-engine/ec (SpeexDSP echo cancellation) — CURRENT

Installed `voice-engine/ec`, a small C binary that uses SpeexDSP to
subtract the known playback signal from the mic input in real time.
This is the correct architectural solution — it removes the echo at
the signal level rather than trying to threshold around it.

**Status: ec works in isolation, integration has a bug.**

## What works

1. **ec binary built and installed** at `~/.local/bin/ec` on the voice-agent host
   - Build deps: `libasound2-dev libspeexdsp-dev pkg-config`
   - Source: `https://github.com/voice-engine/ec.git`
   - Setup script: `servers/<voice-agent>/bin/setup-ec` (repo) / `~/.local/bin/setup-ec` (voice-agent host)

2. **ec data flow verified** — manual test confirms audio flows through:
   ```bash
   # This produces 32KB (1 second) of mic audio through ec pipes
   rm -f /tmp/ec.input /tmp/ec.output
   mkfifo /tmp/ec.input /tmp/ec.output
   exec 7<>/tmp/ec.input; exec 8<>/tmp/ec.output
   ~/.local/bin/ec -o plughw:3,0 -i plughw:1,0 -r 16000 -c 1 -d 100 &
   sleep 2
   timeout 3 dd if=/proc/$$/fd/8 bs=3200 count=10 of=/tmp/test.raw
   # Result: 32000 bytes captured successfully
   ```

3. **ec + sox silence detection verified** — full pipeline works manually:
   ```bash
   timeout 10 cat <&8 | sox -t raw -r 16000 -c 1 -b 16 -e signed-integer - \
     -t wav /tmp/test.wav silence 1 0.3 0.5% 1 1.5 0.5%
   # Result: 64KB WAV captured with voice content
   ```

4. **First exchange works** — voice-agent with ec starts, hears the
   first utterance, responds, and speaks the reply correctly.

## What doesn't work

**After the first reply, all subsequent recordings are empty.**

The tmux log shows:
```
echo-cancellation active (ec pid=391431)
voice-agent ready — model=llama3.1:8b voice=en_GB-alba-medium
Listening...
Transcribing...
you: youyou
Thinking...
voice-agent: It looks like you might have accidentally typed something there, operator!
Listening...
Enable AEC
playback filled 648 bytes zero
No playback, bypass AEC
(empty recording, skipping)
Listening...
(empty recording, skipping)
...repeats...
```

### Likely cause: drain process breaks FD sharing

The voice-agent uses a background "drain" process (`cat <&8 >/dev/null &`)
to keep the ec output pipe buffer empty between recordings (preventing
ec from blocking on write and overflowing ALSA). The drain is stopped
before recording and restarted after.

The start/stop drain cycling appears to break subsequent reads from FD 8.
When the drain was removed just before stopping for the night, the code
was left in a partially edited state.

### Alternative theory: ec state after playback

ec logs "No playback, bypass AEC" after the TTS finishes. In bypass mode,
ec should pass through raw mic audio — but the recordings are still empty.
This could indicate ec stops writing to the output pipe in bypass mode,
or writes in a different format/rate.

## Current state of the code

### `servers/<voice-agent>/bin/voice-agent` (repo, partially edited)

The file has ec integration code that was being debugged when we stopped.
Key functions:

- `start_ec()` — creates FIFOs, opens FDs 7 and 8 with `<>` (O_RDWR to
  avoid FIFO deadlock), starts ec in background
- `stop_ec()` — kills ec, closes FDs, removes FIFOs
- `speak()` — when ec is running, converts WAV to raw via sox and writes
  to FD 7 in background (non-blocking); otherwise uses aplay (blocking)
- `record_until_silence()` — when ec is running, reads from FD 8 via
  `timeout $MAX cat <&8 | sox ...`; otherwise uses arecord
- `start_drain()` / `stop_drain()` — **the drain was being removed when
  we stopped; this code needs to be cleaned up or replaced**

### `servers/<voice-agent>/bin/voice-agent` (deployed on the voice-agent host)

The deployed version still has the drain code. Quokka was stopped before
the fix was deployed.

### `servers/<voice-agent>/bin/setup-ec` (complete, working)

One-shot build script. Already run successfully on the voice-agent host. Does not need changes.

## What needs to be done

### 1. Fix the ec integration (primary task)

Debug why recordings fail after the first exchange. Approach:

**Option A — Remove drain entirely.** Let the pipe buffer fill (64KB =
2 seconds). ec blocks on write, ALSA capture may overflow. When recording
starts, stale data is read first — sox's silence filter strips it. Test
whether ec handles the ALSA overflow gracefully or crashes.

**Option B — Replace drain with a continuous reader.** Instead of
start/stop cycling, keep a single process that reads from ec and either
discards data (when not recording) or routes it to sox (when recording).
This avoids the FD dup/close issues but requires inter-process signaling.

**Option C — Debug the current drain approach.** Add tracing to find
exactly where the FD breaks. Might be a bash subshell FD inheritance
issue, or a race between drain kill and recording start.

**Recommendation:** Try Option A first — it's the simplest. If ec can't
handle the ALSA overflow, fall back to Option B.

### 2. Test barge-in end-to-end

Once recordings work reliably with ec:
- Verify speak() is non-blocking (sox writes to ec input pipe in background)
- Verify recording starts immediately while reply is still playing
- Verify ec actually cancels the echo (mic doesn't hear speaker)
- Verify user speech during reply is captured and transcribed correctly
- Verify stop_playback kills the background sox when recording finishes

### 3. Test ec robustness

- Does ec survive long idle periods (no playback, no recording)?
- Does ec recover if ALSA devices are temporarily unavailable?
- Does ec handle rapid playback→silence→playback transitions?
- What happens if ec crashes? voice-agent should fall back to blocking mode.

### 4. Update docs/guides/voice-agent.md

The guide is stale — it still references:
- POROSVOC mic (replaced by Blue Yeti on plughw:3,0)
- Push-to-talk only (hands-free mode exists now)
- No model switching (voice commands exist now)
- No code writing (save/run exists now)
- No Claude backend (ask_claude exists now)
- No Gotify/quokka-toggle (exists now)
- No echo cancellation (ec exists now)

### 5. Clean up unused variables/code

- `SOX_BARGEIN_THRESHOLD` — can be removed if ec works (no longer needed)
- `BARGE_WATCHER` — remove (was part of the file-watcher approach)

## ec reference

```
~/.local/bin/ec [options]
 -i PCM            playback PCM (speaker device)
 -o PCM            capture PCM (mic device)
 -r rate           sample rate (16000)
 -c channels       recording channels (default 2, use 1 for mono)
 -d delay          playback-to-capture delay in samples (0)
 -f filter_length  AEC filter length (2048)
 -b size           buffer size (262144)
 -s                save debug audio to /tmp/{playback,recording,out}.raw
 -D                daemonize

Named pipes (created by ec if missing):
 /tmp/ec.input   — write raw s16le 16kHz mono here for playback
 /tmp/ec.output  — read echo-cancelled raw s16le 16kHz mono from here
```

**Note:** `-i` is playback and `-o` is capture — the opposite of what
you'd expect. The flags mean "input to speaker" and "output from mic."

## How to resume

```
Read docs/guides/voice-agent-ec-handoff.md for where the ec barge-in
integration left off. The ec binary is installed on the voice-agent host, and the
voice-agent script has partial ec integration that needs debugging.
Fix the "empty recordings after first exchange" bug, test barge-in
end-to-end, then update the voice-agent guide.
```

## Files involved

| File | Location | Status |
|------|----------|--------|
| `servers/<voice-agent>/bin/voice-agent` | repo + voice-agent host | Partially edited, needs drain fix |
| `servers/<voice-agent>/bin/setup-ec` | repo + voice-agent host | Complete, working |
| `servers/<voice-agent>/bin/quokka-toggle` | repo + voice-agent host | Working, no changes needed |
| `servers/<voice-agent>/systemd/quokka-toggle.service` | repo + voice-agent host | Working |
| `docs/guides/voice-agent.md` | repo | Stale, needs update |
| `docs/guides/voice-agent-ec-handoff.md` | repo | This file |
