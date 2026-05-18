# F22: Gotify Remote Reachability (phone ↔ ai-host from outside the home LAN)

**Status:** PROPOSED
**Created:** 2026-04-09
**Author:** Robert Karsten Zaar (with AI assistance)
**Priority:** Medium (blocks the "notify me when I'm away" use case; does not block home-network notifications)
**Depends On:** F21 Phase 1 (Headscale) — soft dep for the long-term option; interim option has no dependencies
**Breaking Changes:** No
**Estimated Effort:** Option 1 inherits from F21 Phase 1. Option 2 is ~1 hour of setup. Option 3 is ~3 hours.

---

## 1. Executive Summary

### 1.1 Problem Statement

The Gotify push notification server installed on the `ai-host` on 2026-04-09 binds
`0.0.0.0:8080`, which makes it reachable from any host on the 192.168.0.0/24
home LAN. When the operator is **outside** the home network — travelling, at a cafe,
tethered — the Gotify Android app cannot reach the server and no
notifications arrive.

This defeats the primary use case: "tell me immediately when the `ai-host`'s LLM
stack dies or when a Drupal CVE drops, so I can react from wherever I am."
A notification system that only works at home is a status panel, not an
alerting system.

The ops/verifier-log GitLab channel is unaffected — it's pull-on-demand and
works from anywhere because the operator's Claude session reaches `<gitlab-host>`
over the public internet. But GitLab issues are not push notifications;
they require the operator to *ask* "anything new?", which defeats the "tell me
immediately" property.

### 1.2 Proposed Solution

Accept that this is a **reachability** problem, not a Gotify problem, and
address it at the network layer. Three routes exist; this proposal
enumerates them, recommends Option 2 as an interim and Option 1 as the
long-term target, and explicitly rejects Option 3.

### 1.3 Relationship to F21

F21 Phase 1 ships Headscale — a self-hosted WireGuard coordination server
that lets the operator's devices form a private mesh. Once F21 Phase 1 is complete,
**Option 1** in this proposal is a ~10-minute configuration change. F22 is
therefore largely about **what to do in the interim**, and whether that
interim is worth the effort given F21's current schedule.

---

## 2. Goals & Non-Goals

### Goals

- The operator's phone receives Gotify push notifications from **anywhere** with
  an internet connection, not just home wifi
- No new SaaS dependencies (consistent with CLAUDE.md § Threat Model)
- No inbound SSH exposed to the public internet (consistent with
  CLAUDE.md § Threat Model)
- The chosen interim path (if any) migrates cleanly to the F21 Phase 1
  Headscale mesh with minimal rework
- End-to-end encryption in transit (WireGuard or TLS, not plain HTTP)

### Non-Goals

- **Replacing Gotify** with a different notification system. Gotify is
  the right tool; the question is purely "how does the phone reach it?"
- **Bidirectional chat.** Gotify is deliberately push-only; the return
  channel is `ops/verifier-log` via GitLab (see `docs/guides/gotify.md` §
  Ground rules). This proposal does not add a return path.
- **Notifying multiple devices.** One phone is the only target. Adding
  a tablet or a second phone is trivially supported by any of the three
  options and doesn't affect the decision.
- **Opening up Gotify to receive webhooks from third parties** (e.g.
  GitHub webhook → Gotify push). Separate concern; same reachability
  problem but different threat surface.
- **Multi-hop or fanout routing** (e.g. some alerts go only to phone,
  others go to phone + laptop). Solve once reachability is working.

---

## 3. Options Considered

### 3.1 Option 1 — Headscale mesh (long-term, correct, blocked on F21)

Phone and `ai-host` both join a Headscale-coordinated WireGuard mesh. The `ai-host`
binds Gotify to its mesh interface (e.g. `100.64.0.2:8080`), phone opens
the Gotify app against `http://100.64.0.2:8080`, traffic flows over
WireGuard end-to-end.

**How it works:**

1. Headscale coordination server runs on the `au-mel` Linode (same box
   as `<gitlab-host>`, or a sibling Linode) — this is F21 Phase 1's
   scope
2. The `ai-host` runs the Tailscale client (the data plane; Headscale is just
   the control plane), authorises via Headscale, gets a mesh IP
3. Phone installs the Tailscale Android app, authorises against
   Headscale, gets a mesh IP
4. Gotify on the `ai-host` rebinds to the mesh interface (not `0.0.0.0`)
5. Phone's Gotify app points at the mesh URL

**Trust properties:**

- Nothing reaches the open internet — traffic between phone and `ai-host` is
  WireGuard with end-to-end encryption
- No inbound port open on the home router
- Headscale server is self-hosted, not a SaaS dependency
- ACLs in Headscale can restrict which mesh members can reach which
  (e.g. "phone can reach ai-host:8080 only")
- The Tailscale client on the phone is closed-source but the data plane
  it runs is WireGuard, which is open. An auditable replacement
  (`tailscale-ios-oss` or a pure WireGuard config extracted from the
  Headscale auth flow) exists if the client itself becomes a concern

**Pros:**

- Architecturally the right answer under CLAUDE.md § Threat Model
- Zero additional attack surface on the home router
- Automatic key rotation and peer discovery via Headscale
- Extends naturally to more devices (laptop, tablet, dev workstation
  when remote) without per-device setup
- The phone can be on *any* internet connection and still reach the `ai-host`

**Cons:**

- **Blocked on F21 Phase 1.** Headscale server not deployed. No ETA
  committed in F21
- The phone needs the Tailscale Android app (free, on F-Droid and Play
  Store). Tailscale client is closed-source (data plane is open
  WireGuard); mitigated by the option to switch to a direct WireGuard
  client that talks to Headscale's advertised peers
- Requires Headscale ACL config to be done right — a mistake exposes
  Gotify to every mesh member, not just the phone

**Effort:** Assuming F21 Phase 1 has shipped, ~10 minutes to rebind
Gotify and configure the phone. If F21 Phase 1 has not shipped, effort
is "whatever F21 Phase 1 costs" plus those 10 minutes.

### 3.2 Option 2 — Interim WireGuard peer, phone ↔ ai-host *(recommended interim)*

A manually-configured WireGuard tunnel between phone and `ai-host`, with no
coordination server. This is *what Headscale automates away*, done by
hand for a single peer pair.

**How it works:**

1. Generate a WireGuard keypair for the `ai-host` (server side) and one for
   phone (client side)
2. Write `/etc/wireguard/wg0.conf` on the `ai-host`: UDP listen port (randomly
   chosen, e.g. 51820 or something less scanned), private key, one
   peer block for the phone's public key
3. Write the corresponding phone-side config: the `ai-host`'s public key, home
   router's public IP (or a dynamic DNS hostname), the listen port, a
   private IP address in a WireGuard-internal subnet
4. Forward **one UDP port** on the home router to the `ai-host`'s LAN IP —
   this is the only compromise vs. Option 1
5. Install the official WireGuard Android app (F-Droid or Play Store),
   import the phone-side config via QR code
6. Phone toggles the tunnel on when it wants notifications from away;
   Gotify is reachable at the `ai-host`'s WireGuard-internal IP

**Trust properties:**

- WireGuard is the same crypto primitive Headscale uses; there is no
  security downgrade at the data plane
- WireGuard is designed to be silent on the wire: without the correct
  key, it does not respond to probes. Port scans see nothing.
  Reference: WireGuard paper, § "Cryptokey Routing"
- One UDP port is exposed on the home router. CLAUDE.md's "don't
  expose SSH" rule is about SSH specifically; WireGuard is explicitly
  allowed (Headscale itself IS WireGuard on the wire)
- No public DNS name, no TLS certificate, no third-party CA in the
  path. The only thing the attacker sees is a UDP port that doesn't
  respond

**Pros:**

- **Available today** — no F21 dependency
- Threat posture is nearly identical to Option 1 (same underlying
  crypto)
- Teaches the operator WireGuard directly, which is valuable background for
  Option 1 when it ships
- Migration path to Option 1 is additive, not destructive: Headscale
  can subsume the manual tunnel. The manual tunnel is torn down cleanly
  with a single `wg-quick down wg0` when F21 Phase 1 lands
- WireGuard Android app is fully open source (GPL-2.0) and official,
  written by the WireGuard author

**Cons:**

- One UDP port open on the home router (vs. zero in Option 1). This
  is a real delta, small but non-zero
- Manual key management: rotation is a script or a remembered ritual,
  not automatic
- Phone has to toggle the tunnel on manually when away from home (or
  configure it as always-on, which costs a small amount of battery)
- Requires the home router to allow UDP port forwarding. Some ISP-
  locked routers don't; a firmware flash or router replacement is a
  separate problem
- Requires either a static home IP or a dynamic DNS service (e.g.
  Cloudflare DNS record updated by a cron on the `ai-host`). Dynamic DNS is
  itself a minor SaaS dependency unless self-hosted
- If the phone's tunnel is left always-on and home network goes down,
  the tunnel breaks until either the phone toggles it off or home
  comes back

**Effort:** ~1 hour including router port-forward, keypair generation,
config files, phone setup, and end-to-end smoke test.

### 3.3 Option 3 — Reverse proxy via <gitlab-host> *(rejected)*

Gotify exposed at a public URL (`https://gotify.<example-prod-domain>`) via a
caddy or nginx reverse proxy on the `au-mel` Linode, with the `ai-host`
maintaining a reverse SSH tunnel out to the Linode so the proxy can
forward traffic to Gotify's LAN-bound port.

**How it works:**

1. Add `gotify.<example-prod-domain>` DNS A record pointing at the `au-mel`
   Linode
2. Caddy or nginx on the Linode terminates TLS (Let's Encrypt or
   internal CA) and reverse-proxies `https://gotify.<example-prod-domain>` to
   `127.0.0.1:<tunnel-port>`
3. The `ai-host` runs `autossh -R <tunnel-port>:localhost:8080 <gitlab-host>`
   as a systemd unit, establishing a persistent reverse tunnel
4. Phone's Gotify app points at `https://gotify.<example-prod-domain>`
5. Auth is whatever Gotify's built-in auth provides (password for the
   admin, token for each app). No additional layer unless explicitly
   added

**Trust properties:**

- Gotify is now reachable from the entire internet. The only thing
  between the open internet and the Gotify admin login is Gotify's
  own auth, which is HTTP Basic over TLS. Vulnerable to credential
  stuffing and brute force if the attacker guesses the admin URL
- The `au-mel` Linode has a new public HTTPS endpoint — additional
  attack surface on a host that previously only served GitLab
- The reverse SSH tunnel on the `ai-host` is a persistent outbound process.
  If it drops, notifications silently stop working until it
  reconnects. Needs its own health check
- Plain HTTPS + password auth is the standard pattern for public
  webapps, but it is a meaningful downgrade from the WireGuard-only
  posture of Options 1 and 2

**Pros:**

- No port opens on the home router (the `ai-host` dials out, `<gitlab-host>`
  dials nothing)
- Works from any device with a browser, no phone-side WireGuard
  client needed
- Standard HTTPS — caching, headers, bookmarkability, all the usual
  webapp ergonomics

**Cons:**

- **Worst threat posture of the three.** Exposes a private service
  to the public internet, which is exactly what CLAUDE.md § Threat
  Model is built to avoid
- `<gitlab-host>`'s attack surface grows (new subdomain, new
  reverse proxy, new backend)
- Credential stuffing is a real threat on any public login page;
  needs rate limiting at the proxy layer, which is more config and
  another thing to get wrong
- The reverse SSH tunnel is additional moving infrastructure that
  has to be monitored
- Does not migrate cleanly to Option 1: when Headscale lands, this
  whole stack is torn down and replaced, not reused
- Adds a SaaS-adjacent dependency (Let's Encrypt) that Options 1/2
  avoid

**Rejected for:** inconsistency with CLAUDE.md § Threat Model; higher
attack surface; no migration path to Option 1. This option exists in
the proposal only to be explicit about why it was considered and
rejected.

---

## 4. Recommendation

### 4.1 Long-term target: Option 1

**Do not build Option 3 under any circumstances.**

Option 1 is the architecturally correct end state. Its only problem is
that it's blocked on F21 Phase 1, which has not shipped. When F21 Phase
1 ships, switch to Option 1 regardless of what interim was in place.

### 4.2 Interim decision: Option 2 or do nothing

The interim question is: "is the 'notify me when away from home'
property worth ~1 hour of work right now, knowing that F21 Phase 1
will replace it eventually?"

Two honest answers:

**Answer A — Yes, build Option 2 now.** The traveling-security-update
scenario from [ADR-0019](../decisions/0019-verifier-always-on-hardware-rooted-keys.md)
is the same shape as the "notify me when away" scenario — being away
from home is the exact moment notifications matter most, and the exact
moment the current setup fails. The ~1 hour cost is small, the
learning value (understanding WireGuard directly) is real, and the
tear-down when F21 Phase 1 lands is clean.

**Answer B — No, wait for F21 Phase 1.** If F21 Phase 1 is expected to
ship within weeks, the interim work is wasted motion. Use ops/verifier-log
polling from the dev laptop as a partial substitute in the meantime:
the operator's Claude session can poll the channel on request from anywhere
`<gitlab-host>` is reachable, which is everywhere. This is not a
push, but it is a "tell me what happened" that works from away. For
critical alerts, this is adequate until Headscale lands.

**Recommendation:** take **Answer A (Option 2)** if F21 Phase 1 is
expected to take more than a month. Take **Answer B (wait)** if it's
expected to ship sooner. The operator is the only one who can make this call
because only the operator knows F21's schedule.

Either way, **Option 3 is off the table.**

---

## 5. Affected NWP Components

### 5.1 New paths (Option 2 interim, if adopted)

| Path | Purpose |
|---|---|
| `servers/<ai-host>/wireguard/wg0.conf.example` | Template config with placeholders for keys and phone peer block |
| `servers/<ai-host>/wireguard/README.md` | Operator runbook: generate keys, install on the `ai-host`, forward router port, generate phone config QR |
| `docs/guides/wireguard-interim.md` | End-to-end walkthrough for the first-time setup, including router port-forwarding |

### 5.2 New paths (Option 1, when F21 Phase 1 ships)

| Path | Purpose |
|---|---|
| `servers/<ai-host>/systemd/tailscale.service` or equivalent | If a user-level unit is needed; Tailscale usually installs its own system unit |
| (updates to) `servers/<ai-host>/gotify/config.example.yml` | Rebind from `0.0.0.0:8080` to the mesh interface |
| (updates to) F21 Phase 1 deliverables | Headscale ACL including a `phone → ai-host:8080` grant |

### 5.3 Modified paths

| Path | Change |
|---|---|
| `docs/guides/gotify.md` | Update the "Reachability" section to reflect chosen interim (if any) and the Headscale migration target |
| `.secrets.yml` | Add `wireguard.phone_peer_public_key` (Option 2) or `headscale.auth_key` (Option 1) |
| `CLAUDE.md` § Threat Model | No changes — neither option violates existing rules |

### 5.4 Not modified

Nothing in `lib/`, `scripts/commands/`, `recipes/`, `pl`, `sites/`, or
core NWP machinery. This is purely a networking-layer change confined
to the `ai-host`'s configuration and `docs/guides/`.

---

## 6. Risk Assessment

### High risk

| Risk | Mitigation |
|---|---|
| **Option 3 gets cargo-culted back in** by someone reading only the options list and not the recommendation. | Rejection is explicit in § 3.3 and § 4.1. Future sessions should be told "Option 3 is rejected" before being shown the options list. |
| **Option 2's router port-forward is misconfigured** and exposes something other than WireGuard. | Runbook specifies port-forward scope explicitly: single UDP port, forwarded to a single LAN IP, no TCP. Verify with an external port scanner after setup. |

### Medium risk

| Risk | Mitigation |
|---|---|
| WireGuard key rotation never happens (Option 2) | Document rotation in the runbook; low consequence because a compromised WireGuard key only exposes the Gotify instance on the `ai-host`, not the rest of the LAN |
| Phone's Tailscale client exfiltrates data (Option 1) | Known closed-source concern; mitigated by the option to switch to a direct WireGuard client configured from Headscale's peer info |
| Home ISP changes the public IP and the phone config breaks (Option 2) | Use a dynamic DNS name (home.<example-prod-domain> or similar, updated by the `ai-host` via a script) instead of hard-coding the IP; document the dynamic-DNS provider choice separately |
| Headscale ACL misconfigured, phone reaches more than just Gotify (Option 1) | ACL lint step in the F21 Phase 1 runbook; verify with `tailscale ping` from the phone to hosts that should be blocked |

### Low risk

| Risk | Mitigation |
|---|---|
| WireGuard kernel module not available (Option 2) | The `ai-host` runs a recent Linux kernel with WireGuard in-tree; verified by a `modprobe wireguard` check in the runbook |
| Gotify Android app doesn't tolerate the mesh IP well (Option 1) | The app connects to whatever URL it's configured for; tested in Option 2 on LAN IPs already, same pattern |

---

## 7. Success Criteria

- [ ] The operator can dial up a test push from any internet-connected location
      and see it arrive on the phone within 5 seconds
- [ ] No inbound SSH port open on the home router (only UDP/WireGuard
      if Option 2, nothing if Option 1)
- [ ] `ollama-health-check` transition alerts reach the phone when the operator
      is not at home, verified at least once end-to-end
- [ ] The chosen option is documented in `docs/guides/gotify.md` §
      Reachability, including the migration target
- [ ] If Option 2 is adopted: a rotation runbook exists for the phone
      peer key and has been dry-run once

Deliberately not a success criterion:

- "Notifications arrive within N milliseconds" — Gotify is already
  fast enough; the extra WireGuard hop adds single-digit milliseconds.
  Don't over-engineer latency

---

## 8. Open Questions

- **What's F21 Phase 1's expected ship date?** Drives the
  Answer-A/Answer-B decision in § 4.2. Only the operator knows.
- **Does the operator's home router support UDP port forwarding?** If no, Option
  2 is blocked and the decision collapses to "wait for F21" or "rethink
  the router setup." Most consumer routers support it; some ISP-locked
  ones don't.
- **Static public IP, or dynamic DNS?** If dynamic, which provider?
  Self-hosted dynamic DNS (a cron updating a record on
  `<gitlab-host>`'s own DNS) is the CLAUDE.md-consistent choice;
  Cloudflare / DuckDNS / etc. are faster to set up but add a SaaS
  dependency.
- **Phone's WireGuard tunnel: always-on or on-demand?** Always-on means
  notifications arrive without user action; on-demand means battery
  lasts longer but alerts are missed when the tunnel is off. This is an
  operator-preference question, not an architectural one.
- **Does the operator want Option 2 work bundled with F21 Phase 1, or
  sequenced before it?** Bundling makes Option 2 unnecessary; sequencing
  delivers value today and accepts the tear-down cost later.

---

## 9. Out of Scope

- Replacing Gotify with any other notification tool
- Adding notification destinations beyond the single phone
- Adding a bidirectional chat channel (see
  `docs/guides/gotify.md` § Ground rules — the return channel is
  ops/verifier-log, deliberately)
- Public webhook ingestion into Gotify (e.g. GitHub → Gotify). Similar
  reachability problem, different threat surface, different proposal
- Replacing the phone's notification app with a custom NWP-branded one
  (the stock Gotify app is fine; custom apps are a distraction)
- Multi-phone or tablet-to-ai-host setups
- Notification templating / routing rules / fanout logic

---

## 10. Cross-references

- **[CLAUDE.md § Threat Model](../../CLAUDE.md)** — "don't expose SSH
  to public internet," "prefer open-source self-hosted" — constraints
  this proposal inherits
- **[F21 Phase 1: Headscale](F21-distributed-build-deploy-pipeline.md)**
  — the long-term dependency for Option 1
- **[ADR-0017: Distributed Build/Deploy Pipeline](../decisions/0017-distributed-build-deploy-pipeline.md)**
  — the Headscale-as-control-plane decision
- **[ADR-0019: verifier Always-On with Hardware-Rooted Keys](../decisions/0019-verifier-always-on-hardware-rooted-keys.md)**
  — parallel remote-access concern; same traveling-operator scenario
- **[`docs/guides/gotify.md`](../guides/gotify.md)** — current Gotify
  operator guide; § Reachability is the section this proposal modifies
- **[`docs/guides/voice-agent.md`](../guides/voice-agent.md)** —
  sibling briefing for the other `ai-host` subsystem; not directly
  affected by this proposal but helpful context for anyone picking up
  `ai-host` work

---

## 11. Decision Record

*This section is filled in when the proposal is accepted.*

**Decided option:** pending
**Decision date:** pending
**Decision maker:** the operator
**Interim action:** pending
**Long-term action:** Option 1 (Headscale) via F21 Phase 1
