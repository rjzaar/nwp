# NWP Console

The `pl` surfaces as a **mesh-only, passkey-only, role-gated** web app (PWA).
Phases 1+2: dashboards + safe actions + roles + audit log. Phase 3: **push
notifications** via self-hosted Gotify — see `docs/guides/console-notifications.md`
(setup, events, dedupe contract, phone app). Unconfigured = silent no-op.

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
4. **Tenancy = the Scope choke point** (`app/scope.py`). A *project* is a named
   set of sites; a member sees only those sites, only issues carrying the
   project's label, only its CI projects. Three nets enforce it: the `scoped()`
   route dependency, `_pane()`'s recursive scrub + redact, and an AST test over
   `main.py` that fails the build if a new route forgets any of it. **Inert
   until an owner creates a project** — with none, behaviour is byte-identical
   to the pre-project console. See
   [ADR-0033](../../docs/decisions/0033-console-multi-tenant-projects.md) and
   [howto-console-projects](../../docs/guides/howto-console-projects.md).

## Deploy / operate (from the workstation)

```
pl console dns             # upsert the console A record -> tailnet IP (Linode API)
pl console cert            # issue/renew LE cert via DNS-01 locally, push cert+key over
pl console deploy          # rsync src -> host:~/nwp-console/src, venv, unit, restart, health
pl console status          # systemd + /health over the mesh
pl console user add <you> --role owner  # first-run bootstrap -> ONE-TIME enrolment link
pl console user addkey <name>           # enrol ONE MORE passkey — keeps the existing ones
pl console user keys <name>             # what passkeys exist, and what each one IS
pl console user rmkey <name> <handle>   # revoke ONE passkey (refuses the last)
pl console user reset <name>            # break-glass: revoke passkeys, fresh link (shell-only)
pl console user list
pl console enroll          # MINTS a Headscale pre-auth key for a new device (+ the steps)
pl console enroll --runbook # the steps only, no network — for when the mesh is what is broken
pl console logs            # tail the console log
```

First-run bootstrap: `pl console user add <you> --role owner` prints a one-time
`/enroll?token=…` link (48 h, single use, token stored hashed). Open it on the
device that holds the passkey. Further users can be added from `/users` (owner
role) — but their device needs mesh access first (`pl console enroll`).

### More than one passkey per account

`add` and `reset` were the only token issuers until 2026-08-01, and `reset`
**wipes every credential first** — so the ordinary case, putting a Solo
hardware key beside a phone passkey, cost you the passkey you were signed in
with. `addkey` issues the same single-use, 48 h, hashed-at-rest token *without
touching credentials*, and runs the whole ceremony as a script:

```
pl console user addkey <name>                 # health -> token -> browser -> watch
pl console user addkey <name> --no-open       # enrolling on a phone: print the link, still watch
pl console user addkey <name> --no-wait       # just issue the link and exit
pl console user addkey <name> --timeout 600   # default 300 s
```

1. **Health first**, so a single-use token is never burned while the mesh is
   down. 2. `fido2-token -L` reports what is plugged into *this* machine —
   advisory, since the key may be on the phone. 3. The link is printed and
   opened. 4. It then **polls the host until the passkey count actually goes
   up**, and returns non-zero if it doesn't — so an abandoned or failed
   ceremony reports as a failure instead of leaving you to run `user show`
   yourself. What it canNOT tell you is *which authenticator* answered: the
   store keeps only the credential id, public key and sign count, so a
   platform passkey saved on the laptop and a touch on the Solo both read as
   "+1". Choosing the security key in the browser prompt is still on you.
   Ctrl-C stops watching and revokes nothing.

The owner-facing equivalent is the **add key** button on `/users`. Either way,
redeem the link on the device holding the NEW key, on the mesh. For a phone,
`--qr` prints the link as a QR code to scan (needs `qrencode`) and suppresses
the local browser — opening it here would burn the single-use token on the
wrong device.

### Knowing which passkey is which, and revoking just one

Each credential records what the authenticator said about itself at
registration — `transports` from the browser's `getTransports()`, plus
py_webauthn's device-type/backed-up pair — so an inventory can name it:

```
$ pl console user keys rob
_2NnRQ6dRe  security key (usb), bound to that device            added=2026-08-01T07:00:42Z
kFtOtqBjZi  unknown — enrolled before authenticator metadata was recorded  added=2026-07-25T00:11:07Z
```

That is deliberately *unattested self-report*: fine for "which of my keys is
this", never a security control. Credentials enrolled before 2026-08-01 read
as **unknown** rather than being guessed at — a passkey inventory that
confidently mislabels a row is worse than one that admits the gap.

`pl console user rmkey <name> <handle>` (or **revoke** on `/users`) removes one
by id prefix. It refuses an ambiguous prefix, and it refuses the **last**
passkey on an account: that is a lockout with no way back in, and the verb
that means "I have lost everything" is `reset`, which hands back an enrolment
link in the same breath. A key that is already enrolled is refused by the browser —
registration sends `excludeCredentials`. One token outstanding per user, so
re-issuing invalidates any unredeemed one; that also makes `addkey` the way to
re-send an expired invite without revoking anything. `reset` stays the
break-glass verb for *lost every key*.

**Cert renewal is manual-ish:** Let's Encrypt certs last 90 days; re-run
`pl console cert` (idempotent). A `pl todo` freshness check is a good follow-up.

### deploy is fail-closed against divergence

`pl console deploy` rsyncs with `--delete`. Before writing anything it compares
the target's `~/nwp-console/src` with what is about to be shipped and **refuses**
when the target holds work this deploy does not explain:

| mark | meaning | verdict |
|------|---------|---------|
| `A` | new file we will create | fine |
| `M` | differs, ours is newer — the change being deployed | fine |
| `!` | differs and the **target's copy is newer** (edited on the box) | REFUSE |
| `D` | exists **only** on the target — `--delete` would destroy it | REFUSE |

```
pl console deploy --dry-run           # show the plan, write nothing
pl console deploy --force-overwrite   # tar.gz backup on the target FIRST, then deploy
```

`--force-overwrite` writes `~/nwp-console/backups/src-<UTC-stamp>.tar.gz` on the
host before touching anything, and aborts if that backup is missing or empty.
(This exists because on 2026-07-25 the console host was carrying an **unpushed**
local branch with the voice feature and a plain deploy would have deleted it.)

## Fleet state is PUBLISHED to the console, not computed on it

The console host has no sites. `pl rag` there returns **zero sites** — which is
why the Fleet tab used to be empty and the "a site went RED" push could never
fire. The machine that holds the sites publishes a snapshot instead:

```
pl fleet publish              # on the workstation: gather -> snapshot -> ship
pl fleet publish --dry-run    # build + summarise, ship nothing
pl fleet publish --no-security   # skip the advisory feed
pl fleet security             # what the advisory feed will contain, as a table
pl fleet security --json      # …every advisory in full
pl fleet status               # what is published here and on the console host
pl fleet schedule             # cron it (default every 30 min)
```

The snapshot lands at `~/.local/share/nwp-console/fleet-state.json` (0600,
written atomically), schema `nwp.fleet-state` v1:

```jsonc
{
  "schema": "nwp.fleet-state", "schema_version": 1,
  "generated_at": "2026-07-26T01:14:07Z",
  "generated_by": {"host": "workstation", "user": "rob", "root": "$HOME/nwp", "pl_version": "0.30.0"},
  "max_age_hint_seconds": 7200,
  "summary": {"RED": 12, "AMBER": 0, "GREEN": 4, "sites": 16, "todo_items": 45, "backup_items": 35,
              "security_advisories": 88, "security_sites_affected": 12, "security_sites_unknown": 5,
              "security_worst": "high", "security_by_site": {"avc": 13, "mayo": 13, …}},
  "feeds": {
    "rag":  {"ok": true, "rc": 3, "secs": 0.4,  "cmd": "pl rag --json --no-todo", "data": {…}},
    "todo": {"ok": true, "rc": 0, "secs": 30.5, "cmd": "pl todo check --json",    "data": {…}},
    "security": {"ok": true, "rc": 0, "secs": 0.2, "cmd": "pl fleet security --json", "data": {…}}
  }
}
```

The `security` feed was **added without moving `schema_version`**, deliberately:
the consumer refuses a version it does not know
(`fleet_state.SUPPORTED_VERSIONS`), so a bump would blank the Fleet *and* Todo
panes on any console not yet upgraded — a new feature taking out two working
ones during the deploy window. Adding a feed is backwards-compatible by
construction: an old console never asks for `security`, and a new console
tolerates a snapshot without it (it says *"no security data in this
snapshot"*, never a reassuring zero). Both directions are tested. `v2` stays
reserved for a genuinely breaking change.

`feeds.security.data` is `{generated_at, sites[], totals}`; each site carries
`state` (`ok` / `stale` / `unreadable` / `n/a` / `missing`), `count`, and every
advisory in full — id, CVE, package, installed version, affected constraint,
title, severity, reported date, link.

It is built from **`pl audit`'s cached records** in `private/update-awareness/`
— the same source `pl rag` grades RED on — not from a fresh `composer audit`.
Two reasons: 16 × `ddev composer audit` (containers up, minutes) cannot fit a
`*/30` cron, and re-auditing would let the advisory detail disagree with the RAG
badge next to it. Reading the cache costs **~0.2 s for 21 sites**.
`pl fleet publish --refresh-security` is the explicit opt-in to re-audit first
(slow — never on the cron); the daily audit timer keeps the cache fresh.

`feeds.<name>.data` is the feed's JSON **verbatim**, so the console runs it
through the same `parsers.py` as a local shell-out — one shape in the app.
(`rc` is recorded but does not decide `ok`: `pl rag` exits 3 when a site is RED,
which is the signal, not a failure.)

Consumption (`app/fleet_state.py`, `NWP_CONSOLE_FLEET_STATE` /
`NWP_CONSOLE_FLEET_MAX_AGE`, default 2 h):

1. snapshot present and fresh → **show it**, with provenance
   *"fleet state from **workstation**, 14 min ago"*;
2. snapshot present but stale → try the local `pl`; it only wins if it actually
   knows something (parsed ok **and** non-empty). Otherwise the stale snapshot
   is still what you see — banner-red, *"⚠ STALE — fleet state from workstation, 5 h
   old (max 2 h) … this is not current"*, and the Fleet tab flags itself;
3. no snapshot → the local shell-out, labelled *"computed on this host (the console host) —
   no published fleet state"*. If that returns zero sites the pane says so and
   points at `pl fleet publish` instead of showing a healthy-looking empty table.

The Gotify RAG detector reads the same gatherer, so it works off published state
with no changes of its own.

## Sessions tab (owner-only tmux terminal on the console host)

The Sessions tab lists the console host's tmux sessions, starts named ones, and
attaches a real browser terminal (vendored xterm.js ↔ FastAPI websocket ↔ a
local `tmux attach` pty — no third-party service, no extra daemon, no new
port). Long-running operator work lives in tmux ON THE HOST and survives the
laptop dropping wifi; the tab is only the intermittent window.

Because a terminal is a shell on this host, the surface is **stricter than
everything else here**: global-owner only, refused for operators; the websocket
re-validates the signed session cookie + role + origin itself, before accept();
the session *name* is the only user input and is regex-validated in one place
(`app/sessions.py`); every attach/detach/start is audit-logged. The terminal
JS is pinned + sha256-verified into `static/vendor/` by `fetch-xterm.sh` —
never CDN-loaded. `tests/test_sessions.py` proves the refusals (including
close-before-accept, structurally).

## Settings tab (owner-only, and deliberately read-only) — ops#383

One tab holding the estate's most important **declared facts**: merge authority
(ops#385), review mode (ADR-0037), each site's canonical phase (ops#33), the
merge queue, and how fresh this console's own feeds are.

It is a **window, not a control panel, and that is the design**. Every fact on
it is declared in exactly one place already, and CLAUDE.md's standing order on
`approvers:` says where a second place ends: *"a policy expressed in several
places is a policy that drifts"* — which is why there is no `pl mr review-mode
set`, and why ops#385 specifies "no console toggle, no env var, no CLI flag".
So each block renders the value **and names the file that declares it**.
`tests/test_settings_pane.py` fails if `pane_settings.html` grows a form, an
input, a select or an htmx write attribute, and if any write-shaped `/settings*`
route appears.

Every block is in one of **three** states, never two:

| state | meaning |
|---|---|
| declared | the source was read and says something |
| `NOT DECLARED` | the source was read and declares nothing — a real answer (no merge authority granted means *a human merges*) |
| `CANNOT VERIFY` | we could not look — always with the verb's own reason, never an empty table and never a default that looks like a decision |

Owner-only, and the only tab that is **hidden** rather than shown-and-refused
(`OWNER_ONLY_PANES` in `app/main.py` drives both the tab bar and the route):
estate governance has no per-project subset to show a member. `/panes/settings`
is a 403 with an audited `settings.denied` row.

**What it reads.** `pl mr authority --json` (merge authority), `pl mr review-mode`
(text — the verb has no `--json`; parsed in `app/settings.py`, and an
unrecognised mode reads as the fail-closed `team`), `pl mr ready --json` (merge
queue), and the **published fleet snapshot** for the phase table — this host
holds no sites, so `pl canonical show` here would report on an empty tree, and
riding the fleet feed means the phase table inherits its provenance and says
when it is stale.

**Tab-bar geometry.** Settings is the eleventh tab, and eleven is the last that
fits: `static/style.css` was re-sized (min-width 59→55px, tab padding 2→1px,
label 12→11.5px, ⟳ padding 8→6px) to 667px of content in the 672px the desktop
bar has at its narrowest. `tests/test_tabbar_fit.py` re-derives that arithmetic
from the CSS and from `PANES` and proves a **twelfth** would not fit (723px), so
the next pane is a structural change — an overflow menu or a grouped bar — not
another 4px shaved off.

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

### The feedback tracker needs its own token

`NWP_CONSOLE_OPS_PROJECT` is the one tracker the Issues pane may **write** to.
`NWP_CONSOLE_ISSUE_PROJECTS` (default `nwp/ops,nwp/nwc`) is every tracker it
**reads**, because tester feedback does not land on the ops board: the nwd demo
site syncs it out with `drush nwc-feedback:sync-to-gitlab` into **`nwp/nwc`**
(e.g. `nwc#8` "[feedback-2] help topic should be clickable", labelled
`demo-tester,feedback,needs-human,tier-3`). Measured 2026-08-02: 136 open in
`nwp/ops`, 3 open in `nwp/nwc`.

The walled `ops_note_token` is walled *hard* — from the console host it returns
`200` for project 21 and **`404 Project Not Found`** for project 16. Widening it
would hand the console reach it was deliberately denied, so each extra tracker
gets a **sibling token file named for its basename**:

```
ssh <console-host> 'umask 077 && cat > ~/.config/nwp-console/gitlab.nwc.token'
# paste a token that can READ nwp/nwc (reporter is enough), Ctrl-D
```

Until that file exists the pane does **not** show `nwp/nwc` as empty — it shows
`⚠ This console could not read: nwp/nwc (http-404)`, because an unreadable
tracker and a clean one must never render the same.

Related verb: `pl issue ls --project=all` gives the same combined queue on the
command line.

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
                  fleet_state.py (published-snapshot consumption + provenance)
                  settings.py (declared-fact VIEWS for the Settings pane —
                               imports no runner/subprocess: it cannot act)
                  runner.py (only process spawner) gitlab_api.py webauthn_flow.py
                  notify.py (Gotify push: fail-open client + pure detectors)
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
`~/.local/share/nwp-console/{users.json,audit.jsonl,secret.key,notify-state.json}` (0600),
`~/.config/nwp-console/{env,gitlab.token,gotify.token,tls/}`.

Push notifications add **no dependencies** (stdlib `urllib`) and no second
service: one asyncio task inside the app reuses the pane gatherers and their TTL
cache. Owner role gets a `/notifications` page (per-event status, last-sent
times, test button). Notification click-URLs deep-link back via `/?tab=<pane>`.

## Tests

```
python3 -m pytest scripts/console/tests/          # pure-python unit tests
bats tests/unit/test-console.bats                 # pl console dispatch
bats tests/unit/test-console-deploy-guard.bats    # deploy divergence guard (stubbed ssh/rsync)
bats tests/unit/test-fleet-publish.bats           # pl fleet publish snapshot contract
```

Everything under `tests/` is stdlib-only except the handful of security-advisory
**render** tests, which need a real Jinja environment to assert that hostile
advisory text is actually escaped (a hand-rolled stand-in would only prove the
stand-in works). Those skip cleanly on a bare interpreter and run wherever
jinja2 exists — the console's own venv, the workstation, and the console host.
The tenancy route tests (`test_route_scoping.py`, `test_tenant_isolation.py`)
likewise need fastapi + httpx and skip without them.

### Proving the tenancy tests can fail

`tests/test_tenant_isolation.py` is the cross-project leakage test. A test that
only ever passes proves nothing, so it ships with a switch that simulates a
future change forgetting the boundary — the scoped gatherers are replaced by
their fleet-wide counterparts and `scrub`/`redact` are neutered:

```
NWP_CONSOLE_TEST_DISABLE_SCOPE=1 python3 -m pytest scripts/console/tests/test_tenant_isolation.py
# expect ~11 failures, each naming the foreign site that leaked
```

The switch is honoured only by that test module; it does not exist in the app.

## Honest limits

- **Project scoping is an APPLICATION boundary, not an OS one.** One Unix user,
  one `pl` checkout, one GitLab token, one audit log, one snapshot. Anyone with
  a *shell* on the console host reads every project's data whatever
  `users.json` says. A Headscale ACL restricting an external dev's node to
  the console port only (no SSH, no ollama, no Gotify) is a **hard
  prerequisite before the first external developer** and lives outside this
  codebase. Real isolation means a second console instance.
- Audit entries written before projects existed carry no `project` field and
  are therefore **owner-only**. A backfill would have to guess.

- `pl demo status` output is parsed heuristically (a human table); the pane
  keeps the raw text in a collapsible block. `pl demo codes list --json`,
  `pl demo seal-status --json` (both ops#328), `pl rag --json` and
  `pl todo check --json` are real contracts.
- The Demo tab's bulk revoke/purge DISCHARGES (ops#327): the response renders
  the registry re-read after the verb ran, cache bypassed — on refusals too.
  The seal banner states the golden-capture age and that live changes revert
  at the nightly reset unless a new golden is sealed; sealing itself
  (`pl demo golden <site> --tier=live --with-pair`, ~4–6 min) stays a
  workstation verb in tranche 1 — it is longer than the console's synchronous
  action budget and is designed as an async job in ops#328 tranche 2.
- **Two of the Settings pane's five blocks cannot read anything yet, and say
  so.** `pl mr authority --json` (ops#385) and `pl mr ready --json` are being
  built by other streams; measured 2026-08-22, neither verb exists in this
  tree. Both blocks therefore render `CANNOT VERIFY` with the verb's own error
  text — which is the honest state and is visibly different from "no authority
  is granted" / "nothing is queued". The argv for each is declared once, in
  `app/settings.py`, so wiring them up when the verbs land is one place to
  look. The parsers accept the field names ops#385 specifies for the
  `merge_authority:` block (`granted_to`, `granted_by`, `granted_on`, `ref`,
  `scope`); if the verb ships a different JSON shape, that module is where it
  is reconciled.
- The fleet view is only as current as the last `pl fleet publish`. It always
  says which host produced it and how old it is, and shouts once that is past
  `NWP_CONSOLE_FLEET_MAX_AGE` — but a dead publisher means stale numbers, so
  keep the cron well inside the max-age window.
- Publishing is **push-only from the workstation** today. If the workstation is
  off, nothing refreshes (the console cannot pull — it holds no keys to the
  sites). Later ver/met can take over the publish job; nothing in the schema is
  workstation-specific.
- Backups pane is read-only (the sweep runs where the backups live) and shows
  the backup-freshness slice of the *published* todo sweep.
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
