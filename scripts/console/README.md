# NWP Console

The `pl` surfaces as a **mesh-only, passkey-only, role-gated** web app (PWA).
Phases 1+2: dashboards + safe actions + roles + audit log. Push notifications
(Gotify) are deferred (Phase 3).

```
phone/laptop (Tailscale app → your headscale control URL)
        │  WireGuard mesh (transport gate)
        ▼
console host <tailnet-ip>:<port>  ← uvicorn binds the TAILNET IP ONLY
  https://console.<your-domain>:<port>   (public DNS A → the tailnet IP;
                                          resolvable anywhere, reachable only on the mesh)
```

Operator-specific values (ssh alias of the console host, FQDN, tailnet IP, port,
headscale URL) live in the **gitignored** `nwp.yml` under `settings.console`
(schema in `example.nwp.yml`) — never in this tree (P61 leakage gate).

## Security model (three gates, in order)

1. **Transport = the mesh.** The app binds the console host's tailnet IP only.
   The console FQDN points at tailnet space — off-mesh it routes nowhere.
2. **Auth = WebAuthn passkeys, no passwords.** Hardware security keys (Solo) and
   phone platform passkeys. WebAuthn *requires* a secure context and a DNS-name
   RP ID, hence the real Let's Encrypt cert (DNS-01; the DNS API token stays on
   the workstation — `pl console cert` issues there and pushes only the cert+key
   to the console host). Sessions: itsdangerous-signed cookies, 7 days,
   `Secure; HttpOnly; SameSite=Strict`.
3. **Roles + fail-closed actions.** `viewer` (GET), `operator` (+safe actions),
   `owner` (+user management). The ONLY shell-outs are the literal argv allowlist in
   `app/actions.py` — no interpolation, strict per-arg validators, **no live/prod
   verbs representable**. The console host holds no prod keys anyway (blast radius
   = the A14 dev/test tier). Every action POST appends to
   `~/.local/share/nwp-console/audit.jsonl` (also rendered at `/audit`).

## Deploy / operate (from the workstation)

```
pl console dns             # upsert the console A record -> tailnet IP (Linode API)
pl console cert            # issue/renew LE cert via DNS-01 locally, push cert+key over
pl console deploy          # rsync src -> host:~/nwp-console/src, venv, unit, restart, health
pl console status          # systemd + /health over the mesh
pl console user add <you> --role owner  # first-run bootstrap -> ONE-TIME enrolment link
pl console user reset <name>            # break-glass: revoke passkeys, fresh link (shell-only)
pl console user list
pl console enroll          # prints the Headscale pre-auth key runbook for a new device
pl console logs            # tail the console log
```

First-run bootstrap: `pl console user add <you> --role owner` prints a one-time
`/enroll?token=…` link (48 h, single use, token stored hashed). Open it on the
device that holds the passkey. Further users can be added from `/users` (owner
role) — but their device needs mesh access first (`pl console enroll`).

**Cert renewal is manual-ish:** Let's Encrypt certs last 90 days; re-run
`pl console cert` (idempotent). A `pl todo` freshness check is a good follow-up.

## Issues/CI panes token (operator-provisioned — never automated)

The issues + CI panes call the GitLab API with the **walled bot token pattern**
(`gitlab.ops_note_token` — non-admin, walled to nwp/ops; see
`private/secrets-registry.yml`, use `pl secrets` for any token work). Provision it
on the console host yourself:

```
ssh <console-host> 'umask 077 && mkdir -p ~/.config/nwp-console && cat > ~/.config/nwp-console/gitlab.token'
# paste the token value, Ctrl-D
```

`pl console deploy` never copies tokens. With no token file the panes degrade to
deep-links into GitLab; nothing breaks.

## Quokka voice (talk to Quokka, Quokka talks back)

Both legs run **on the console host**. No cloud speech API is called anywhere,
and the browser's `SpeechRecognition` API is **deliberately never used** — in
Chromium and Brave it implements "local" speech by streaming your microphone
audio to Google. The only browser speech we touch is `speechSynthesis`
(output only), and only as the fallback when the host has no piper.

```
phone mic ──MediaRecorder(webm/opus)──> POST /quokka/stt   (viewer+, ≤60 s, ≤10 MB)
                                          │  faster-whisper in a short-lived child
                                          ▼  audio: 0600 temp file, shredded in a finally
                                       transcript ──> the SAME /quokka/chat pipeline
                                          │            (context injection + loopback ollama)
                                          ▼
                                        reply ──> POST /quokka/tts ──> piper WAV ──> 🔈
                                                  (or the device's own offline voice)
```

**Speaking to Quokka is exactly as privileged as typing to it.** `/quokka/stt`
returns *text*, which the page then posts to `/quokka/chat` like any other
message — `app/voice.py` has no import path to `actions.py`/`runner.py`, and a
test asserts it (alongside the existing one for `quokka.py`).

Nothing is required for the console to run: with no backends installed the mic
button never renders and `/quokka/stt` answers 503 with "type instead".

### Provisioning a host for voice (optional, one-time)

Speech **in** — faster-whisper, in the *system* python (deliberately not in the
console venv: the web process stays ~140 MB and a transcription's ~400 MB peak
belongs to a child that exits):

```
pip3 install --user faster-whisper           # pulls ctranslate2 + av
python3 -c 'from faster_whisper import WhisperModel; WhisperModel("base", device="cpu", compute_type="int8")'
```

That second line pre-fetches the model (~150 MB) into `~/.cache/huggingface`.
Do it once at provisioning time — otherwise the *first* voice request pays for
the download. `whisper.cpp` works too (`NWP_CONSOLE_STT_BACKEND=whisper-cli`,
plus `…_STT_WHISPER_CLI` / `…_STT_WHISPER_MODEL`); it needs `ffmpeg` on PATH.

Speech **out** — piper, in its own tiny venv (~250 MB with one voice):

```
python3 -m venv ~/piper/venv && ~/piper/venv/bin/pip install piper-tts
~/piper/venv/bin/python -m piper.download_voices en_US-lessac-medium --data-dir ~/piper/voices
```

Then `pl console deploy` (or just `systemctl --user restart nwp-console`): the
committed defaults already point at `~/piper/venv/bin/piper` and
`~/piper/voices/en_US-lessac-medium.onnx`, so an existing install picks voice up
with **no env changes**. Backend availability is probed lazily and cached for
5 minutes.

### Knobs (all optional, `~/.config/nwp-console/env`)

| Variable | Default | Notes |
|---|---|---|
| `NWP_CONSOLE_STT_BACKEND` | `auto` | `auto`\|`faster-whisper`\|`whisper-cli`\|`off` |
| `NWP_CONSOLE_STT_MODEL` | `base` | `tiny`/`base`/`small`(`.en`) — bigger = slower |
| `NWP_CONSOLE_STT_PYTHON` | `/usr/bin/python3` | must have faster-whisper |
| `NWP_CONSOLE_STT_MAX_SECONDS` | `60` | over-long audio is refused, not truncated |
| `NWP_CONSOLE_STT_MAX_BYTES` | `10485760` | enforced before the bytes touch disk |
| `NWP_CONSOLE_STT_TIMEOUT` | `120` | hard subprocess kill |
| `NWP_CONSOLE_STT_THREADS` | `4` | be a good neighbour to ollama |
| `NWP_CONSOLE_TTS_BACKEND` | `auto` | `off` ⇒ browser voices only |
| `NWP_CONSOLE_TTS_PIPER` / `_TTS_VOICE` | `~/piper/…` | binary + `.onnx` |

**`MemoryMax` moved 512M → 1500M** in `nwp-console.service` to cover those
short-lived children. Set both backends to `off` and you can put it back.

### Browser notes (mobile-first)

- **Mic needs HTTPS** — the console already is, so this Just Works.
- **Brave**: the mic prompt can be swallowed by Shields. If tapping 🎤 shows
  "Microphone blocked", open the padlock / Shields ▾ → **Site settings** →
  **Microphone** → **Allow**, then reload. Chrome/Chromium: padlock → Site
  settings → Microphone. Once allowed, the PWA remembers it.
- **Codec**: Chromium/Brave/Firefox record `audio/webm;codecs=opus`; iOS Safari
  records `audio/mp4`. Both are decoded server-side by PyAV — no conversion in
  the page.
- **Tap to start, tap to stop** (not press-and-hold: holding fights with scroll
  gestures on a phone). Recording auto-stops at `STT_MAX_SECONDS`.
- **"Speak replies"** is remembered per device in `localStorage`. With piper on
  the host you get the same voice everywhere; without it the page picks a
  `localService` (offline) system voice — note that on Android the *default*
  Google voices may synthesise over the network, which is why we filter for
  local ones first.
- iOS/Safari may require the page to be foregrounded for `speechSynthesis`.

### What voice does and doesn't leave behind

- **The audio is never persisted.** It lives in a 0600 file inside a 0700
  scratch dir for exactly as long as one transcriber process runs, and is
  truncated + unlinked in a `finally` — on success, on error and on timeout.
  Tests assert the file is gone and the scratch dir is empty afterwards. The
  browser-supplied filename is discarded; the temp name is ours.
- **The audit log records the transcript, never the audio** — the same detail a
  typed message leaves, plus size/duration/backend. `/quokka/tts` logs only
  that the speaker was used (char count), since the words were already audited
  as Quokka's reply.
- **New attack surface, stated plainly:** an authenticated viewer+ can now feed
  arbitrary bytes to a media decoder (PyAV/ffmpeg) on the console host. That is
  a large C surface. It is bounded by WebAuthn + the mesh (no anonymous reach),
  a size cap before the bytes touch disk, a duration cap, a hard subprocess
  timeout, and decoding in a short-lived child rather than in uvicorn.

## Layout

```
scripts/console/
  app/            FastAPI app (main.py) + pure modules:
                  authz.py (roles) actions.py (allowlist) parsers.py store.py
                  runner.py (spawns `pl`) gitlab_api.py webauthn_flow.py
                  voice.py (spawns the transcriber/synthesiser — no action path)
                  stt_worker.py (run BY voice.py under the system python, not
                                 imported by the venv: keeps faster-whisper's
                                 ~400 MB out of the long-lived web process)
                  manage.py (shell CLI: python3 -m app.manage — used by pl console user)
  templates/      Jinja2 (base + panes; htmx partial swaps)
  static/         style.css, webauthn.js, sw.js, icons,
                  htmx.min.js  ← vendored htmx.org 2.0.4, integrity verified:
                  sha384-HGfztofotfshcF7+8n44JQL2oJmowVChPTg48S+jvZoztPfvwD79OC/LTtG6dMp+
  tests/          pytest, stdlib-only imports (no server / no venv needed)
  nwp-console.service   systemd --user unit (linger required on the host)
  requirements.txt
```

Runtime state on the console host (never in git):
`~/nwp-console/{src,venv,console.log}`,
`~/.local/share/nwp-console/{users.json,audit.jsonl,secret.key}` (0600),
`~/.config/nwp-console/{env,gitlab.token,tls/}`.

## Tests

```
python3 -m pytest scripts/console/tests/    # pure-python unit tests
bats tests/unit/test-console.bats           # pl console dispatch
```

## Honest limits

- `pl demo status` / `codes list` output is parsed heuristically (human tables);
  the panes always keep the raw text in a collapsible block. `pl rag --json` and
  `pl todo check --json` are real contracts.
- The fleet view reflects **the console host's** checkout/caches (`pl rag
  --no-todo` reads cached audit records on that host — typically empty unless
  synced); it is not a substitute for `pl rag` on the workstation.
- Backups pane is read-only (the sweep runs where the backups live).
- Live/prod anything: read-only by design — run it on the workstation (or the
  air-gapped deploy host for real prod).
- Voice: `base` is chosen for latency, not accuracy — it mangles unusual site
  names and acronyms (say "the fleet" not "n-w-d"). Bump
  `NWP_CONSOLE_STT_MODEL` to `small.en` if you'd rather wait.
- Voice concurrency is not queued: two people recording at once run two
  transcribers. Fine for a household console, wrong for a crowd.
- The model download on first use is a network call to huggingface.co from the
  console host — pre-fetch it at provisioning time (above) so a voice request
  never depends on it.
