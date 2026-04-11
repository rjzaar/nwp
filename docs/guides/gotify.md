# Gotify Push Notifications on mini — Dev Briefing

This doc is the **kick-off briefing for a Claude Code session focused on
improving or extending NWP's push-notification path via Gotify on mini**.
It is deliberately short on history and long on concrete pointers. If
you are a fresh Claude session that has just been handed this file,
read it end-to-end before touching anything.

## How to use this doc to start a session

Paste this into a new Claude Code session in `~/nwp`:

> Read `docs/guides/gotify.md` for context on mini's Gotify push
> notification server. I want to improve or extend it — ask me what
> aspect first, then propose concrete changes. Don't start coding
> until we've agreed on scope. The server runs on a remote host
> (`mini`, reachable via `ssh mini` from this dev workstation); treat
> `ssh mini '<cmd>'` as your normal way to probe state. Gotify's admin
> password and application tokens are in `.secrets.yml` on dev.

Then tell Claude which improvement area you want (§ "Improvement ideas").

## What exists today (as of 2026-04-09)

A **self-hosted Gotify server** running on mini, bound to the LAN,
receiving alerts from one producer (the mini LLM stack health check)
and pushing them to the Gotify Android app.

### Data flow

```
ollama-health-check (on mini, every ~5 min via systemd timer)
  ├─ check 7 things about the ollama daemon and models
  ├─ write new state to ~/.cache/ollama-health.state
  └─ on transition (healthy ↔ unhealthy):
      ├─ POST to git.nwpcode.org/ops/mons-log  (audit trail, GitLab issue)
      └─ POST to Gotify 127.0.0.1:8080/message (phone push)
              │
              ▼
         Gotify server on mini (LAN bind 0.0.0.0:8080)
              │
              ▼  (WebSocket, long-poll, from Android app)
         Gotify Android app on Rob's phone
              │
              ▼
         Phone notification
```

The ops/mons-log GitLab path and the Gotify path are **both** fired on
every transition. They are different durability/latency trade-offs for
the same event:

- **ops/mons-log** — slow, append-only audit trail. Works even without
  phone reachability. Queryable history. This is the record of record.
- **Gotify** — fast, ephemeral push. Only works if the phone can reach
  mini (LAN only right now). No persistent history beyond Gotify's
  SQLite DB. This is the "tell me NOW" channel.

Do not collapse them into one. See § Ground rules.

### Files of record (dev-side in this repo, deployed to mini)

| Path in repo | Deployed to | Purpose |
|---|---|---|
| `servers/mini/gotify/config.example.yml` | `~/.config/gotify/config.yml` (substituted) | Server config template. `pass:` field is `REPLACE_ME_WITH_RANDOM`; real password in `.secrets.yml` |
| `servers/mini/systemd/gotify.service` | `~/.config/systemd/user/gotify.service` | systemd --user unit |
| `servers/mini/bin/ollama-health-check` | `~/.local/bin/ollama-health-check` | The only current producer; posts to both ops/mons-log and Gotify on transitions |
| `.secrets.yml` (gitignored) | — | Holds `gotify.admin_password` and `gotify.mini_health_token` |

### Binaries + runtime on mini (NOT in repo)

| Path on mini | What | Install origin |
|---|---|---|
| `~/.local/bin/gotify` | Gotify v2.9.1 server binary | `github.com/gotify/server/releases/download/v2.9.1/gotify-linux-amd64.zip` |
| `~/.config/gotify/config.yml` | Server config (0600) | Deployed from `servers/mini/gotify/config.example.yml` with the password substituted |
| `~/.local/share/gotify/gotify.db` | SQLite DB (users, apps, messages) | Created on first run |
| `~/.local/share/gotify/data/images` | Uploaded app icons | Empty |
| `~/.config/gotify-mini-alerts.token` | The one producer's app token (0600) | Matches `gotify.mini_health_token` in `.secrets.yml` |

### Credentials

All in `.secrets.yml` on dev under the `gotify:` key:

- `url: "http://192.168.0.11:8080"`
- `admin_user: "rob"`
- `admin_password: "<generated-24-byte-urlsafe-random>"`
- `mini_health_token: "AVbuuXA5oxiFQr2"` (the one application token
  currently in use)

**These credentials are sensitive.** Treat the admin password as an
infra-tier secret per ADR-0004. The app token is less sensitive — it
can only POST messages to the `mini-health-check` application and
cannot read anything. Compromise is contained; rotate via the admin
API.

### Reachability

- **Binds** `0.0.0.0:8080` on mini. Reachable from anything on the
  192.168.0.0/24 LAN.
- **Not reachable from outside the LAN.** Phone only gets notifications
  when on home wifi.
- **Not TLS.** Plain HTTP. Acceptable for now because messages are
  low-value health transitions, not secrets. Upgrade path is TLS +
  Headscale, not TLS alone.

### Verified working

- ✓ Gotify binary starts and survives systemd restart
- ✓ Admin login via API (`curl -u rob:<pass>`)
- ✓ Application created, token works
- ✓ Message POST with token succeeds, returns message object
- ✓ `ollama-health-check` successfully posts a transition alert
  (verified by forcing a fake unhealthy→healthy transition via the
  sentinel file, then reading `GET /message?since=0`)
- ✓ Both the mons-log (GitLab issue) and Gotify paths fire on the
  same transition event

### NOT yet verified by a human

- **Gotify Android app not yet installed on Rob's phone.** The whole
  "push reaches the phone" leg is unconfirmed. First order of business
  for any session is to confirm this end-to-end with a real
  notification.
- **No reboot test of the systemd unit.** It's enabled and lingered,
  same pattern as `ollama.service` (which has been reboot-tested), but
  has not been through a cold boot cycle yet.

## Known limitations (these are the interesting targets)

1. **LAN-only, no TLS.** Phone has to be on home wifi for pushes to
   arrive. This is the single biggest limitation and the motivating
   target for Headscale migration.
2. **One producer only** (`mini-health-check`). Many other things
   should be talking to Gotify — build failures, prod site monitoring,
   cron output from mons, pl verify failures, cathnet pipeline alerts.
   None of those are wired up.
3. **No routing / application segmentation.** All messages go to the
   single `mini-health-check` application. Severity is encoded as
   Gotify priority (5 = normal, 8 = high) but there is no per-producer
   app, per-topic app, or filtering.
4. **No deduplication.** If ollama-health-check runs twice in a minute
   and flaps, you get two notifications. Debouncing exists at the
   *transition* level (sentinel file) but not at the *delivery* level.
5. **No delivery confirmation.** Gotify server accepts the POST and
   returns 200, but there is no feedback about whether the Android
   app actually received it.
6. **No backup of `gotify.db`.** The SQLite DB holds all apps, users,
   message history, and tokens. A disk failure loses everything.
7. **Token rotation never exercised.** The runbook for "rotate the
   mini-health-check app token" exists in principle (create new via
   admin API, update `~/.config/gotify-mini-alerts.token`, update
   `.secrets.yml`, delete old) but has never been run.
8. **No Gotify self-health check.** Nothing tells Rob if Gotify itself
   is down. Ironic: the notification system can't notify you that it
   can't notify you. Partial mitigation: `ollama-health-check` will
   print a non-fatal error if the POST fails, and that lands in the
   journal — but only if Rob reads the journal.
9. **No pl CLI integration.** No `pl notify send "..."` command. Every
   producer has to curl Gotify directly with the right token.
10. **The ops/mons-log dual-path assumes both producers can reach
    git.nwpcode.org.** If git.nwpcode.org is the thing that broke, the
    audit trail fails but Gotify still works. If mini is the thing
    that broke, both fail.
11. **No metrics / observability of Gotify itself.** How many messages
    posted today? Any auth failures? Unknown.

## Improvement ideas, ranked by value-per-effort

**High value, low effort:**

- **Confirm the phone leg works.** Install Gotify from F-Droid, add
  the server, push a test message. Until this is done, everything
  else is academic.
- **Add a second producer**: `mmt` build failures, posted from met via
  a tiny bash script. One-line curl, separate app token, done.
- **Write a `pl notify send` command** that reads the token from
  `.secrets.yml` and posts to the right app. Becomes the standard
  interface for producers instead of raw curl.
- **Back up `gotify.db` daily** to the existing backup location.
  Single cron line.

**High value, moderate effort:**

- **Headscale migration** (unblocks remote reachability). This is the
  single biggest improvement but depends on F21 Phase 1 shipping.
  When Headscale lands, rebind Gotify to the mesh interface and
  repoint the Android app at the mesh address.
- **TLS in front** (caddy or nginx with a self-signed cert added to
  the phone's trust store). Adds encryption on LAN. Lower priority
  than Headscale because Headscale provides encryption intrinsically.
- **Multiple applications**: one app per producer class
  (`mini-health-check`, `mmt-builds`, `prod-sites`, `verify-failures`,
  `cathnet-pipeline`, etc.) so the phone can filter and mute
  individual streams.
- **Priority convention**: document and enforce what
  priority values mean (0 = info, 5 = normal, 8 = high, 10 = urgent)
  and tie them to notification behaviour in the Android app.
- **Self-health check**: a sibling producer on met or dev that pings
  Gotify every 5 minutes and posts to `ops/mons-log` (NOT Gotify!) if
  it's unreachable. This is the "who watches the watcher" path.

**High value, high effort:**

- **Bidirectional channel via a second Gotify-style tool?** No. Don't.
  Gotify is deliberately one-way. For bidirectional, the pattern is
  ops/mons-log (pull-on-demand) plus Gotify (push-on-event). See
  § Ground rules.
- **Metrics scrape**: pull Gotify's internal state via the admin API,
  expose via a local dashboard. Depends on how observability lands
  generally in NWP.

**Speculative:**

- **Gotify plugin for custom routing / templating.** Gotify supports
  Go plugins for message transformation. Useful if the priority
  convention needs more nuance. Probably overkill.
- **Replace Gotify with ntfy.sh self-hosted.** Different protocol,
  different trade-offs. Only worth doing if a specific Gotify
  limitation bites hard. Currently none does.

## How to test a change

```bash
# Is the server up?
ssh mini 'systemctl --user status gotify.service --no-pager | head -5'

# Is it reachable from dev?
curl -sS http://192.168.0.11:8080/health && echo
curl -sS http://192.168.0.11:8080/version; echo

# Admin login
GPASS=$(grep 'admin_password' .secrets.yml | cut -d'"' -f2)
curl -sS -u rob:$GPASS http://192.168.0.11:8080/application | python3 -m json.tool

# Send a test push via the mini-health app token
GTOKEN=$(grep 'mini_health_token' .secrets.yml | cut -d'"' -f2)
curl -sS -X POST "http://192.168.0.11:8080/message?token=$GTOKEN" \
    -F "title=test" -F "message=hello $(date +%s)" -F "priority=5" \
    | python3 -m json.tool

# Read messages back
curl -sS -u rob:$GPASS "http://192.168.0.11:8080/message?since=0" \
    | python3 -m json.tool | head -30

# Exercise the producer path end-to-end by flipping the sentinel
ssh mini 'echo "unhealthy" > ~/.cache/ollama-health.state && \
          ~/.local/bin/ollama-health-check >/dev/null'
# ↑ should post a "recovered" alert to BOTH ops/mons-log and Gotify
# Verify with the curl above and by polling ops/mons-log

# Check the journal for any POST failures
ssh mini 'journalctl --user -u ollama-health.service -n 20 --no-pager'

# Server logs (useful when debugging auth or routing)
ssh mini 'journalctl --user -u gotify.service -n 30 --no-pager'
```

## Related reading (load these into context as needed)

- `docs/guides/voice-agent.md` — parallel briefing for the other mini
  subsystem from the same session; similar format
- `docs/decisions/0017-distributed-build-deploy-pipeline.md` — why mini
  is in the AI-accessible tier and what that means for what can run
  on it
- `docs/decisions/0019-mons-always-on-hardware-rooted-keys.md` (if
  accepted) — may change the reachability story for mons as a potential
  Gotify producer
- `CLAUDE.md` § "Threat Model" — "Prefer open-source, self-hosted,
  local-first tools" is what put Gotify in play instead of Pushover,
  Pushbullet, Firebase, etc.
- Memory: `mini-llm-baseline.md` has the Gotify section alongside the
  ollama/voice-agent state
- Memory: `mons-log-channel.md` has the ops/mons-log GitLab queue
  documented — understand this before touching the dual-path producer
  pattern in `ollama-health-check`

## Ground rules for changes

1. **Gotify is push-only. Do not make it two-way.** The return path
   (from the operator or from another machine back to Rob's agents)
   is `ops/mons-log` GitLab issues, polled on demand. Keep the
   separation: Gotify notifies, ops/mons-log records. Collapsing them
   into a single bidirectional chat destroys both the audit trail
   property and the notification reliability property.
2. **Every new producer gets its own application token.** Separately
   revocable, separately identifiable. Never share a token across
   producers. This is the same discipline as the GitLab PAT
   separation in `.secrets.yml` (mini-bot vs mons-bot vs mons-log vs
   mini-alerts).
3. **Admin password stays in `.secrets.yml`**, never in the repo,
   never in `servers/mini/gotify/config.example.yml` (which has the
   literal string `REPLACE_ME_WITH_RANDOM` as a safeguard).
4. **Do not bind Gotify to a public IP.** LAN-interim is acceptable;
   public internet is not. Migration target is the Headscale mesh,
   not a public DNS name.
5. **Do not add cloud dependencies.** No Firebase, no Pushover, no
   OneSignal, no Pushbullet — all of those violate CLAUDE.md §
   "Threat Model". Gotify's whole point is to avoid them.
6. **Every producer must also preserve its ops/mons-log path** (or
   another durable audit trail). Gotify is ephemeral. If a producer
   only ever writes to Gotify, that producer is losing events on
   every restart.
7. **Do not add AI-authored messages without scope review.** The
   voice agent and the Claude session on dev should NOT be writing
   free-form messages to Gotify. Producers are scripts with fixed
   templates. If a future feature wants AI-composed alerts, that is
   a new trust decision.
8. **Signing:** commit edits to `servers/mini/gotify/*` and
   `servers/mini/bin/ollama-health-check` from dev, not from mini.
   Same rule as voice-agent.

## Open questions a new session should ask before coding

- **Has the phone app been installed and verified?** If not, that is
  the first thing. Everything else waits.
- **Is F21 Phase 1 (Headscale) ready?** If yes, LAN-interim is a
  legacy problem. If no, LAN-interim is the current reality and
  improvements should be backward-compatible with a future Headscale
  rebind.
- **Which producer is most urgent to add next?** mmt build failures?
  Prod site monitoring? cron output from mons? Each has a different
  shape.
- **Does Rob want notification segmentation** (multiple Gotify apps,
  one per topic, so the phone can mute individually) or is a single
  stream with priorities enough?
- **Is there an existing "pl notify" command or are you building it
  new?** Check `scripts/commands/` and `pl` before creating anything.
- **Token rotation runbook** — does it exist in written form yet, or
  only as a mental model? If the latter, consider writing it as a
  side-effect of any token-adjacent change.
