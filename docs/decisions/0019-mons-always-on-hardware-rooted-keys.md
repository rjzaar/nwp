# ADR-0019: mons Always-On with Hardware-Rooted Keys

**Status:** Proposed
**Date:** 2026-04-09
**Decision Makers:** Rob
**Related Issues:** —
**References:** [ADR-0017](0017-distributed-build-deploy-pipeline.md), [CLAUDE.md § Threat Model](../../CLAUDE.md), [F21](../proposals/F21-distributed-build-deploy-pipeline.md)

## Context

[ADR-0017](0017-distributed-build-deploy-pipeline.md) and CLAUDE.md establish
mons as the sole host authorised to write to production, with two
defence-in-depth properties:

1. **mons is offline by default** — it connects only while actively
   deploying, via a phone hotspot or dedicated cellular modem, never via
   the home LAN, and never as a member of the Headscale mesh alongside
   met/mini.
2. **mons holds the prod-write credentials** — SSH deploy keys and
   WireGuard tunnel keys live on mons's disk, protected only by file
   permissions and the fact that the host is usually powered off.

The two properties work together: the credentials are on disk in the
clear-ish (file perms only), but the host is unreachable most of the time,
so neither stolen-in-memory nor stolen-from-disk attacks have a window
to execute.

This ADR is triggered by a concrete operational scenario that the
offline-by-default rule handles poorly:

> A Drupal SA-CORE critical patch drops while I am away from home for
> several days. I want to push it to prod immediately. The current rule
> forces me to wait until I can physically open mons at home, which may
> be 12–72 hours later.

The scenario is not hypothetical. Drupal SA-CORE advisories have landed
on travel days before. The window between advisory publication and
in-the-wild exploitation is typically hours to a day. A 12–72 hour delay
is itself a threat to prod — possibly a larger one than the threat that
offline-by-default exists to prevent.

This ADR revisits whether "offline by default" is load-bearing, or
whether the load-bearing property has been quietly shifting onto
something else that could carry the weight alone.

## Forces

- **Patch latency is a security property.** The correct latency target
  for a critical Drupal patch is measured in hours, not days. A rule
  that adds days of delay to patching is itself a security cost.
- **The prod credentials, not the host state, are the crown jewels.**
  An attacker does not care about mons's uptime; they care about whether
  they can exfiltrate a key that lets them write to prod.
- **Hardware security tokens change the calculus.** If the prod write
  capability lives on a Solo 2C+ with touch-to-use, no amount of host
  compromise lets an attacker deploy. The key cannot be extracted and
  cannot be used without a human finger. This wasn't part of the
  ADR-0017 assumption set because the Solo 2C+ hadn't been chosen yet.
- **mons is not yet the sole deploy host in practice.** F21 Phases 5-8
  (signed artifacts, WireGuard tunnel, blue-green slots) are pending.
  This is a design-time decision, not a retreat from a running system.
- **"Offline by default" is operationally expensive.** Requires physical
  presence for every deploy, no background backup or log collection,
  no real-time alerting reaches mons, no patch windows outside physical
  access.
- **Always-on hosts are a real attack surface.** Headscale membership,
  sshd, kernel network stack, and any daemons are all potential vectors.
  Offline-by-default reduces all of these to zero.
- **Traffic analysis is a minor but real concern.** An always-on mons
  on a mesh reveals deploy cadence to a network observer.
- **"No AI on mons" is inviolable independent of this decision.** No
  option considered here touches that rule.

## Options Considered

### Option 1: Status quo — strict offline by default (ADR-0017 as written)

mons stays offline most of the time. For urgent patches, Rob returns
home (or a trusted proxy opens mons on his behalf). Credentials stay
on mons's disk, protected by file permissions.

- **Pros:**
  - Zero remote attack surface on the prod-write host
  - Stolen laptop / cold-boot attack has narrow window
  - No dependence on a hardware token being procured
  - Defence-in-depth at both network and credential layers
- **Cons:**
  - Patch latency is bounded below by physical travel time
  - Rob's traveling-security-update scenario takes 12–72 hours
  - Requires a proxy relationship if "someone else opens mons" is on
    the table, which introduces its own trust problem
  - Disk-resident credentials are the real crown jewels and this option
    does nothing to harden them against a one-time physical-access
    compromise of mons

### Option 2: Always-on mons with hardware-token-gated keys *(chosen)*

mons joins the Headscale mesh as a hardened, always-on member. The
prod SSH and WireGuard keys move from disk to a Solo 2C+ NFC hardware
token. Every deploy action requires touch-to-use on the token. The
host is patched, monitored, and file-integrity-checked continuously.
"No AI on mons" stays absolute.

- **Pros:**
  - Patch latency reduced to "open a laptop anywhere, `ssh mons`, touch
    the token"
  - **Credentials cannot be extracted from the token**, so host
    compromise does not yield deploy capability
  - **Credentials cannot be used without a human finger**, so an
    attacker who owns mons still cannot write to prod in the absence
    of the operator
  - Real-time alerting, backups, and log shipping become possible
  - Patches to mons itself can flow through normal update channels
  - Aligns mons's operational model with met/mini (mesh member,
    patched, monitored) while keeping the trust distinction in the key,
    not the network position
- **Cons:**
  - Non-zero remote attack surface on the host
  - Supply-chain risk if Headscale, sshd, or the kernel ship a bad
    update (mitigated by scoping `unattended-upgrades` to security
    repo only)
  - Piggyback attack: an attacker with persistent on-host access could
    wait for Rob to initiate a deploy and hijack the touched session.
    Real but narrow — requires active, sustained compromise during the
    exact deploy window
  - Creates a hard dependency on procuring a Solo 2C+ NFC before the
    new posture can be adopted
  - Traffic analysis reveals mons exists and when it's active

### Option 3: Split mons — cold signer + warm deployer

Keep the offline "cold" mons as the holder of a master signing key.
Introduce an always-on "warm" mons (or repurpose an existing host) that
holds only a short-lived deploy capability signed by the cold mons.
Rob periodically brings cold mons online to pre-sign deploy windows;
the warm mons executes within those windows.

- **Pros:**
  - Preserves offline-by-default for the highest-value key
  - Always-on component has limited blast radius (only the window
    it was pre-authorised for)
  - Separation of "issue authority" and "execute authority"
- **Cons:**
  - Substantially more complex: two hosts, two key lifecycles, windowing
    protocol, revocation story
  - Traveling-update scenario still partly broken — if a window expires
    while Rob is away, he's back to Option 1's problem
  - More moving parts means more opportunities for the protocol to
    be wrong in subtle ways
  - Overkill for a one-person project; the complexity budget would be
    better spent on the patches themselves

### Option 4: Scheduled wake-on-LAN windows

mons stays powered off by default. A trusted on-home-network proxy can
wake it via WoL in response to a signed request from Rob. mons comes
up, performs its queue, powers off.

- **Pros:**
  - Keeps mons cold most of the time
  - Reduces mean uptime → reduces remote attack window
- **Cons:**
  - Requires an always-on home proxy (which is itself now the
    always-on target; the problem has moved, not vanished)
  - Rob-from-a-cafe scenario still requires the home network to be
    healthy and the proxy to be reachable
  - WoL fails silently in many real-world conditions (BIOS settings,
    driver bugs, switch misconfigurations)
  - Doesn't address the disk-resident-credentials concern at all
  - Adds operational complexity for a marginal improvement

## Decision

**Adopt Option 2: mons becomes always-on, Headscale-resident, and
prod-write credentials move to a Solo 2C+ NFC hardware token. The new
inviolable property is "no prod write without physical touch on the
hardware token," not "mons is offline."**

The Solo 2C+ hardware token is a **prerequisite, not an enhancement**.
Until the token is in hand and the deploy path is reworked to use it,
the old ADR-0017 posture remains in force.

The following properties from ADR-0017 and CLAUDE.md **remain
inviolable** under this ADR:

- **No AI access on mons, ever.** No Claude session, no local LLM,
  no agent-driven anything. mons is purely a human-driven deploy
  executor.
- **No prod access from any AI-accessible host.** dev, met, mini, and
  any other AI-capable machine continue to have zero prod reachability.
- **Trust flows through signatures, not machines.** Artifacts are still
  trusted because they carry a valid minisign signature from the mmt
  build tier, not because mons happens to have pulled them.
- **Sanitisation stays on the prod server.** Raw user data never
  leaves prod.
- **Deploy requires human presence.** Under the new posture, human
  presence is established by touch on the Solo 2C+, not by physical
  proximity to a powered-off laptop.

## Rationale

The load-bearing property of ADR-0017 — "AI errors cannot cause
production damage" — is carried by *two* defences:

1. The network boundary (offline mons)
2. The credential boundary (keys mons's disk is protected by the
   fact that the host is mostly unreachable)

Under this ADR, **defence 1 is replaced by a stronger defence 2**: keys
move to hardware where they cannot be extracted or used without a human
touch. The new defence 2 is **strictly stronger than the old defence
1+2 combination against the attack this ADR is supposed to prevent**:
an attacker with code execution on mons.

- **Old posture:** attacker needs code execution + time + disk access.
  If they get on-host during the deploy window, they win (can read
  keys from disk, exfiltrate, deploy later).
- **New posture:** attacker needs code execution + operator presence +
  operator touch on the token during their session. If they get
  on-host outside a deploy window, they win nothing — there are no
  keys to steal.

The only attack that is genuinely *worse* under the new posture is the
remote-exploit-of-an-unattended-host class: an attacker who owns mons
while Rob is not deploying. Under the old posture, this attacker wins
(steals disk keys). Under the new posture, this attacker wins nothing
until Rob next deploys, at which point they need to be actively
present on-host to piggyback. That is a materially higher bar.

Patch latency is a security property. A rule that forces a 12-72 hour
delay on critical security patches imposes a cost that was not
enumerated in ADR-0017. The traveling-security-update scenario is
realistic, not contrived, and it occurs often enough for a solo
operator that the cumulative expected exploit window under the old
posture is probably larger than the cumulative expected exploit window
under the new posture — especially once the hardware token closes off
the primary credential-theft path.

## Consequences

### Positive

- Critical security patches land in minutes from anywhere Rob has a
  Solo 2C+ and a network path — a laptop plus hotspot, a phone on its
  own (see *Deploy client forms* below), or any borrowed machine with
  an NFC reader or USB port
- Host compromise of mons no longer implies credential compromise
- Host compromise of mons no longer implies deploy capability
- Real-time alerting from prod can reach mons (and from there, Rob)
- mons itself can be patched, monitored, and file-integrity-checked
- The mental model for operators is simpler: "touch the token to deploy"
  is a single rule, replacing "wait until you're near the laptop"
- Eliminates the proxy-trust question raised by Option 1's workaround
  ("someone else opens mons for me")

### Negative

- Requires procuring a Solo 2C+ NFC (cost: ~AU$100, lead time: ~2 weeks
  for shipping from SoloKeys)
- Creates a hard dependency on the token being physically available.
  A lost/destroyed token blocks deploys until a spare is enrolled — so
  **a second Solo 2C+ must be enrolled as a backup before this ADR is
  considered implemented**
- Adds hardening work: sshd scope restriction, fail2ban, aide file
  integrity, scoped unattended-upgrades, auditd log shipping
- Traffic analysis reveals mons's network presence and deploy cadence
  (mitigated by: traffic is on a Headscale mesh, not public internet)
- Introduces new operational error modes: token pin lockout, token
  firmware bugs, NFC reader driver issues on mons

### Neutral

- mons gains a Headscale membership. This does not change its trust
  tier — it remains "no AI, no agent, human-driven only" — but it does
  change its network position. Treat it as a restricted mesh peer:
  reachable by dev for deploy orchestration, reachable by no other host
- The WireGuard tunnel to prod can remain ephemeral (brought up only
  during deploys) even though mons itself is always on. Belt-and-braces
  against a persistent mesh-to-prod pivot

### Deploy client forms

With the Solo 2C+ now the root of trust for every prod-write action,
the "deploy client" is just *whatever machine holds the SSH session
that touches the token*. The client no longer has to be a specific
trusted laptop. Three forms are explicitly supported and equivalent
from a trust standpoint — the token gates everything, so the client
can be minimal:

1. **Laptop + USB token.** Default form at home. Rob's dev workstation
   initiates the deploy, the Solo 2C+ is in a USB port, touch confirms
   each credential use. Largest screen, richest diff review, preferred
   when available.

2. **Laptop + phone hotspot + USB token.** Travel form when Rob has
   his laptop with him but is on an untrusted network. Identical to
   form 1 from mons's perspective — the only difference is the path
   from the laptop to Headscale runs over LTE instead of the home
   router. Preferred travel form when the laptop is practical to
   carry.

3. **Phone-as-deploy-client (NFC + SSH client).** Laptop-less form.
   The phone runs an SSH client (Termux or Blink) and a Headscale
   mobile client, and the Solo 2C+ is tapped against the phone's
   NFC reader for touch-to-use. The phone itself holds no long-lived
   prod credentials; it only holds a Headscale identity and an SSH
   session — both revocable, both useless without the token. This
   form is the one that closes the "Drupal SA-CORE drops on travel
   day" window when Rob is carrying nothing but a phone.

The trust-equivalence argument is load-bearing: **the hardware token
is the root of trust, not the client machine.** An attacker who
compromises the phone (or the laptop, or a borrowed machine) gets
a live Headscale session and an SSH terminal — but cannot produce a
token touch, so cannot deploy. This is why form 3 is acceptable even
though a general-purpose phone has a larger attack surface than a
dedicated deploy laptop.

Caveats on form 3:

- **Smaller screen for diff review.** The deploy script's "about to
  deploy commit abc123 to dir1 — touch to confirm" prompt is easy to
  read on a phone; a multi-file diff is not. Use form 3 for deploys
  that have already been reviewed on a larger screen (typical path:
  MR reviewed on laptop during the work week → SA-CORE patch lands
  on travel day → mmt rebuilds and signs → Rob taps to deploy from
  phone, confident in what he already reviewed).
- **Phone as deploy client still needs validation.** The SSH client,
  Headscale mobile client, and NFC touch flow need to be exercised
  end-to-end before form 3 can be declared supported. This is tracked
  as F21 Phase 5b.
- **No AI on the phone deploy path, same as mons.** Don't install a
  phone-side agent that auto-deploys — the phone is a dumb terminal.

## Implementation Notes

The new posture is **not live until every item below is completed**.
Partial adoption (e.g., always-on mons without the hardware token) is
explicitly worse than the status quo and is forbidden.

### Prerequisites (block implementation)

1. **Two Solo 2C+ NFC tokens procured and enrolled** — primary and
   backup. Keys generated on-device, never exported.
2. **CLAUDE.md amendment staged** — see next section. The amendment
   lands in the same commit as the hardening changes, not ahead of
   them.
3. **F21 Phase 1 (Headscale)** complete, since mons's always-on access
   path is the mesh.

### Host hardening checklist

- [ ] mons joins Headscale as a restricted peer (ACL: only `rob@dev`
      can reach it, no met/mini/ba/cathnet reachability)
- [ ] sshd: `AllowUsers rob`, `PasswordAuthentication no`,
      `KbdInteractiveAuthentication no`, `PermitRootLogin no`,
      bind only to the Headscale interface
- [ ] fail2ban with aggressive ban times on the sshd jail
- [ ] `unattended-upgrades` scoped to the security repo only; daily;
      reboot-if-required scheduled for a known window
- [ ] `aide` (or equivalent) with weekly runs and report mailed to Rob
- [ ] `auditd` with a rule set covering `/etc`, `/home/rob/.ssh`,
      `/home/rob/.config`, and the deploy script directory; logs
      shipped daily to git.nwpcode.org as a signed artifact
- [ ] Firewall: default-deny inbound on the physical NIC; allow only
      on the Headscale interface
- [ ] No Linux user other than `rob` has a login shell
- [ ] Full-disk encryption verified (LUKS), unlock required on boot

### Credential migration

- [ ] Prod SSH key regenerated on the Solo 2C+ (`ssh-keygen` with
      FIDO2 / `ed25519-sk` resident key, `-O verify-required` so touch
      is mandatory per-use, not per-session)
- [ ] Prod servers' `authorized_keys` updated to the new public key;
      old disk-resident key revoked
- [ ] WireGuard key: if using standard WireGuard, the key still lives
      on disk but the tunnel is only brought up inside a deploy script
      that requires a token touch to initiate. Alternative: investigate
      `wg-quick` wrappers that can gate on `pam_u2f` or equivalent
- [ ] Backup Solo 2C+ enrolled against prod `authorized_keys` as a
      second key; stored in a physically separate location from the
      primary
- [ ] Rotation runbook: what to do if the primary is lost or
      destroyed. Must not require the missing primary

### Deploy script changes

- [ ] `pl deploy` (or whatever replaces it post-F21) requires a touch
      for every `ssh prod` / `wg-quick up` / `rsync` against prod
- [ ] The deploy script displays a prompt before each touch:
      "about to deploy commit abc123 to dir1 — touch to confirm"
- [ ] Failed touches (timeout, wrong token, cancelled) fail the deploy
      step loudly rather than silently retrying
- [ ] Deploy script logs every touch event with commit SHA and target,
      mailed to Rob on completion

### Monitoring

- [ ] Real-time alerting from prod reaches mons over the prod→mons
      ingress path (this path does not yet exist; it's a new work item)
- [ ] mons itself has a Gotify producer (pattern established in
      `servers/mini/bin/ollama-health-check`) that posts "mons boot",
      "mons shutdown", "mons aide report clean/dirty" to the existing
      queue
- [ ] File integrity (`aide`) reports are treated as "must be green";
      a dirty aide report gates deploys until investigated

### CLAUDE.md amendment

The following CLAUDE.md text must be replaced in the same commit that
implements this ADR:

**Remove:**

> "Don't put mons on the Headscale mesh. mons is offline by default and
> connects only while actively deploying, via a phone hotspot or
> dedicated cellular modem — never via the home LAN and never as a
> Headscale member alongside met/mini. During deploys mons reaches
> `git.nwpcode.org` over public HTTPS (with signature verification) and
> reaches prod through a dedicated one-to-one WireGuard tunnel where
> mons and prod are the only peers and prod's sshd binds only to the
> tunnel interface. Don't suggest adding mons to Headscale or putting
> its traffic over the home router."

**Replace with:**

> "mons is the sole host that may write to production, and its
> prod-write credentials live on a Solo 2C+ NFC hardware token with
> touch-required-per-use. mons is an always-on Headscale mesh peer,
> reachable only from the dev workstation, hardened (sshd key-only,
> fail2ban, aide, auditd, scoped unattended-upgrades, LUKS). **No AI
> access on mons, ever** — no Claude session, no local LLM, no
> agent-driven anything. A deploy requires a human touch on the token
> for every credential use; there is no session cache. See
> [ADR-0019](docs/decisions/0019-mons-always-on-hardware-rooted-keys.md)
> for the full posture."

The table row in CLAUDE.md § "Distributed Actor Glossary" for `mons`
also updates: its cell in the "Runs AI?" column stays **no** (inviolable),
its cell in "Prod access?" stays **yes**, and its Role cell changes from
"Verifies signed artifacts, deploys to prod via dedicated WireGuard
tunnel, creates bug reports back to mmt" to "Verifies signed artifacts,
deploys to prod via hardware-token-gated credentials; always-on mesh
peer hardened per ADR-0019".

### F21 amendment

F21 Phase 5 (minisign verification on mons), Phase 6 (WireGuard tunnel
to prod), and Phase 7 (key management) all need to be revised to reflect
the new credential custody model. The cleanest approach is to add a new
Phase 4.5 ("mons hardening per ADR-0019") that gates Phases 5-8.

## Review

**30-day review date:** 2026-05-09

**Review criteria:**

- Has the Solo 2C+ been procured, enrolled, and verified as working?
- Has mons been hardened per the checklist and does aide report clean?
- Has at least one test deploy been completed end-to-end from a
  non-home network (e.g., a cafe, tethered hotspot)?
- Has the traveling-security-update scenario actually been exercised,
  or is it still hypothetical?
- Any attempted compromise events visible in fail2ban / auditd logs?

**Review outcome:** Pending

**Rollback plan:** if the new posture proves unworkable or a successful
compromise is observed, revert to Option 1 by: (1) removing mons from
the Headscale mesh, (2) regenerating the prod SSH key on a disk-resident
file, (3) updating prod `authorized_keys`, (4) reinstating the
CLAUDE.md text removed above, (5) marking this ADR as Superseded. The
Solo 2C+ tokens can be repurposed for other roles (e.g., signing git
commits, SSH to met/mini) so the procurement cost is not lost.
