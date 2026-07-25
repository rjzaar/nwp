# Console push notifications (Gotify)

**What this gives you:** the NWP Console stops being something you have to *look
at*. When a site goes red, a tester files a report, the demo reset skips, a token
dies, or CI breaks, your phone buzzes.

**What it costs:** nothing leaves the mesh. Push is delivered by a **self-hosted
Gotify** server on the `ai-host` — no Pushover, no Firebase, no third party in the path.

> Related: `docs/guides/gotify.md` covers the Gotify server itself and its
> original producer (the ollama health check). This doc is specifically the
> **console** leg. Server reachability history lives in
> `docs/proposals/F22-gotify-remote-reachability.md`.

```
console checker (on the ai-host, every 5 min)
  ├─ reuses the SAME gatherers the panes use (pl rag / pl todo / pl demo / GitLab API)
  ├─ compares against ~/.local/share/nwp-console/notify-state.json  (dedupe)
  └─ on CHANGE only:  POST http://100.64.0.2:8080/message
                              │
                              ▼
                    Gotify server on ai-host (systemd --user)
                              │  WebSocket
                              ▼
                    Gotify app on your phone (on the tailnet)
```

## The events

| Event | Toggle key | Fires when | Priority |
|---|---|---|---|
| Site goes RAG red | `rag` | a site's grade **changes** to RED (and again when it recovers to GREEN) | 8 / 4 |
| New tester report | `demo_tester` | a GitLab issue labelled `demo-tester` appears with an iid above the high-water mark | 6 |
| Demo reset failed/skipped | `demo_reset` | the latest event in `pl demo status` changes to `reset-failed`, `skip-floor` or `skip-active` | 7 / 6 / 5 |
| Token dead or expiring | `token_expiry` | `pl todo check --json` reports a new dead/expiring token (this is `pl secrets audit` under the hood) | 7 / 5 |
| CI failed | `ci` | an open MR's head pipeline changes to `failed` | 6 |
| Morning brief | `brief` | once a day at `NWP_CONSOLE_NOTIFY_BRIEF_AT`, if the local model is awake | 3 |

Gotify's Android client makes noise at priority ≥ 8 and stays quiet below it, so
only "a site just went red" actually buzzes by default.

### Dedupe — why you don't get spammed

Every event fires on **state change only**. The last-seen value for each detector
is persisted to `~/.local/share/nwp-console/notify-state.json` (0600), so:

- a site that stays red is announced **once**, not every 5 minutes;
- restarting or redeploying the console does **not** re-announce anything;
- a feed that breaks (GitLab down, `pl rag` unparseable) produces **no** events
  and leaves its high-water mark untouched — so you don't get a burst when it
  comes back.

**First run seeds silently.** The very first pass against an empty state file
records current reality and says nothing. This is deliberate: without it, a fresh
deploy would fire one push per already-red site. You are told about changes *from
that point on*. Deleting the state file re-seeds the same way.

## Setup

### 1. The server (already running on the ai-host)

Gotify v2.9.1 runs as a systemd **user** service on the `ai-host`:

```bash
systemctl --user status gotify        # on the ai-host
```

| Thing | Where |
|---|---|
| binary | `~/.local/bin/gotify` |
| config | `~/.config/gotify/config.yml` (0600) |
| database | `~/.local/share/gotify/gotify.db` |
| admin password | `.secrets.yml` → `gotify.admin_password`, mirrored to `~/.config/gotify-admin.pass` on the host |

It listens on port **8080**. Footprint is ~19 MB RSS — irrelevant next to ollama.

### 2. The application token

Each producer gets its own Gotify *application* token, so any one of them can be
revoked without touching the others. The console's is called `nwp-console`.

Create it on the `ai-host` (this never prints the token):

```bash
umask 077
CFG=$(mktemp); trap "rm -f $CFG" EXIT
printf 'user = "<gotify-admin-user>:%s"\n' "$(cat ~/.config/gotify-admin.pass)" > "$CFG"
curl -sS -K "$CFG" -X POST http://127.0.0.1:8080/application \
  -H 'Content-Type: application/json' \
  -d '{"name":"nwp-console","description":"NWP Console push notifications"}' \
  | python3 -c '
import sys, json, pathlib, os
a = json.load(sys.stdin)
p = pathlib.Path.home()/".config/nwp-console/gotify.token"
fd = os.open(p, os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
os.write(fd, a["token"].encode()); os.close(fd)
print("created application id=%s" % a["id"])'
```

`pl console deploy` **never copies this token** — same discipline as the GitLab
pane token. To rotate: delete the application in the Gotify UI, re-run the above,
restart the console.

### 3. Console config

In `~/.config/nwp-console/env` on the console host:

```sh
NWP_CONSOLE_GOTIFY_URL=http://100.64.0.2:8080
# optional, these are the defaults:
# NWP_CONSOLE_GOTIFY_TOKEN_FILE=<home>/.config/nwp-console/gotify.token   # must be absolute
# NWP_CONSOLE_NOTIFY_EVENTS=rag,demo_tester,demo_reset,token_expiry,ci
# NWP_CONSOLE_NOTIFY_INTERVAL=300
# NWP_CONSOLE_NOTIFY_BRIEF_AT=07:30     # empty = no morning brief
```

Then `systemctl --user restart nwp-console`.

**Leave `NWP_CONSOLE_GOTIFY_URL` unset anywhere else.** With no URL (or no token
file) the whole feature is a silent no-op — which is exactly what you want on a
dev checkout, and why running the console locally never errors.

To turn a single event off, drop its key from `NWP_CONSOLE_NOTIFY_EVENTS` and
restart. `NWP_CONSOLE_NOTIFY_EVENTS=none` disables all events but leaves the
manual test button working.

### 4. Your phone

1. **Join the phone to the mesh.** Install **Tailscale** and connect it to the
   Headscale network (`pl console enroll` prints the pre-auth key runbook).
   Without this the phone cannot reach `100.64.0.2` and nothing is delivered.
2. **Install Gotify** — [F-Droid](https://f-droid.org/packages/com.github.gotify/)
   or Play Store. The client is open source.
3. Open it, choose *Add server*, enter `http://100.64.0.2:8080`, and log in with
   your Gotify **user** account (the admin user + password) — *not* the
   application token. The app token is for producers; the user login is for
   readers.
4. In the console (owner role) open **Alerts → Send test notification** and
   confirm it lands on the phone.

## The reachability caveat, stated plainly

Gotify delivers over a WebSocket the phone holds open. **A notification only
arrives while the phone can actually reach the server.**

- On the mesh (Tailscale connected): near-instant.
- Off the mesh, or with Tailscale toggled off to save battery: messages **queue
  on the server** and are delivered when you reconnect. They are not lost — but
  they are not timely either, which for a "site is red" alert is most of the
  value gone.
- Practically: if you want to be told at 2 a.m., Tailscale has to stay on.

This channel is the **"tell me now"** path. It is deliberately *not* the record
of record — that stays in the console audit log
(`~/.local/share/nwp-console/audit.jsonl`, also at `/audit`) and in GitLab, both
of which work whether or not your phone was reachable. Don't collapse the two.

## Current bind posture (honest gap)

The Gotify server currently listens on `0.0.0.0:8080` — loopback **plus** the
home LAN **plus** the tailnet. It is not reachable from the public internet
(the host sits behind the home router with no port forward), but it is not
tailnet-only either.

Tightening it to `listenaddr: "100.64.0.2"` is a one-line change in
`~/.config/gotify/config.yml`. **It has not been made yet, deliberately**, because:

- the phone is **not currently a tailnet node** (`tailscale status` shows only
  the workstation, the build host, the ai-host and the forge — no phone). Today the phone reaches Gotify over the LAN, so a
  tailnet-only bind would silently kill all existing notifications;
- two local producers (`ollama-health-check`, `quokka-toggle`) POST to
  `127.0.0.1:8080` and would need updating in the same change.

**Do this in one go when you're ready:** put the phone on Tailscale, then flip
the bind, then repoint those two scripts at `100.64.0.2:8080`, then re-test all
three producers. See `docs/proposals/F22-gotify-remote-reachability.md`.

## Troubleshooting

| Symptom | Check |
|---|---|
| Test button says "not configured" | `NWP_CONSOLE_GOTIFY_URL` set? token file present and non-empty? restarted? |
| Test accepted but nothing on the phone | phone on the mesh? Gotify app logged in and showing "connected"? |
| No event pushes, but test works | first pass seeds silently — nothing has *changed* yet. Use **Run a check now**. |
| Suspect a stuck high-water mark | `cat ~/.local/share/nwp-console/notify-state.json`; delete it to re-seed |
| Nothing at all | `journalctl --user -u nwp-console -n 50`; `systemctl --user status gotify` |

Delivery failures never affect the console: the notifier is fail-open by
construction, so a dead Gotify degrades to "no pushes", never to a broken pane
or a failed action.

## Tests

```bash
python3 -m pytest scripts/console/tests/test_notify.py   # 53 tests, no network
```

The suite covers fail-open on every transport error, no-op when unconfigured,
dedupe and state persistence for all five detectors, brief scheduling, and that
the token never appears in any status output.
