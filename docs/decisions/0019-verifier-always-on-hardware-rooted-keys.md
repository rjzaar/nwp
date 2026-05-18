# ADR-0019: verifier Always-On with Hardware-Rooted Keys

**Status:** Proposed
**Date:** 2026-04-09
**Decision Makers:** Robert Karsten Zaar (with AI assistance)
**Related Issues:** —
**References:** [ADR-0017](0017-distributed-build-deploy-pipeline.md), [CLAUDE.md § Threat Model](../../CLAUDE.md), [F21](../proposals/F21-distributed-build-deploy-pipeline.md)

## Context

[ADR-0017](0017-distributed-build-deploy-pipeline.md) and CLAUDE.md establish
the verifier as the sole host authorised to write to production, with two
defence-in-depth properties:

1. **The verifier is offline by default** — it connects only while actively
   deploying, via a phone hotspot or dedicated cellular modem, never via
   the home LAN, and never as a member of the Headscale mesh alongside
   the `ci-host`/`ai-host`.
2. **The verifier holds the prod-write credentials** — SSH deploy keys and
   WireGuard tunnel keys live on the verifier's disk, protected only by file
   permissions and the fact that the host is usually powered off.

The two properties work together: the credentials are on disk in the
clear-ish (file perms only), but the host is unreachable most of the time,
so neither stolen-in-memory nor stolen-from-disk attacks have a window
to execute.

This ADR is triggered by a concrete operational scenario that the
offline-by-default rule handles poorly:

> A Drupal SA-CORE critical patch drops while the operator is away from home for
> several days. They want to push it to prod immediately. The current rule
> forces them to wait until they can physically open the verifier at home, which may
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
  An attacker does not care about the verifier's uptime; they care about whether
  they can exfiltrate a key that lets them write to prod.
- **Hardware security tokens change the calculus.** If the prod write
  capability lives on a Solo 2C+ with touch-to-use, no amount of host
  compromise lets an attacker deploy. The key cannot be extracted and
  cannot be used without a human finger. This wasn't part of the
  ADR-0017 assumption set because the Solo 2C+ hadn't been chosen yet.
- **The verifier is not yet the sole deploy host in practice.** F21 Phases 5-8
  (signed artifacts, WireGuard tunnel, blue-green slots) are pending.
  This is a design-time decision, not a retreat from a running system.
- **"Offline by default" is operationally expensive.** Requires physical
  presence for every deploy, no background backup or log collection,
  no real-time alerting reaches the verifier, no patch windows outside physical
  access.
- **Always-on hosts are a real attack surface.** Headscale membership,
  sshd, kernel network stack, and any daemons are all potential vectors.
  Offline-by-default reduces all of these to zero.
- **Traffic analysis is a minor but real concern.** An always-on verifier
  on a mesh reveals deploy cadence to a network observer.
- **"No AI on the verifier" is inviolable independent of this decision.** No
  option considered here touches that rule.

## Options Considered

### Option 1: Status quo — strict offline by default (ADR-0017 as written)

The verifier stays offline most of the time. For urgent patches, the operator returns
home (or a trusted proxy opens the verifier on their behalf). Credentials stay
on the verifier's disk, protected by file permissions.

- **Pros:**
  - Zero remote attack surface on the prod-write host
  - Stolen laptop / cold-boot attack has narrow window
  - No dependence on a hardware token being procured
  - Defence-in-depth at both network and credential layers
- **Cons:**
  - Patch latency is bounded below by physical travel time
  - The operator's traveling-security-update scenario takes 12–72 hours
  - Requires a proxy relationship if "someone else opens the verifier" is on
    the table, which introduces its own trust problem
  - Disk-resident credentials are the real crown jewels and this option
    does nothing to harden them against a one-time physical-access
    compromise of the verifier

### Option 2: Always-on verifier with hardware-token-gated keys *(chosen)*

The verifier joins the Headscale mesh as a hardened, always-on member. The
prod SSH and WireGuard keys move from disk to a Solo 2C+ NFC hardware
token. Every deploy action requires touch-to-use on the token. The
host is patched, monitored, and file-integrity-checked continuously.
"No AI on the verifier" stays absolute.

- **Pros:**
  - Patch latency reduced to "open a laptop anywhere, `ssh verifier`, touch
    the token"
  - **Credentials cannot be extracted from the token**, so host
    compromise does not yield deploy capability
  - **Credentials cannot be used without a human finger**, so an
    attacker who owns the verifier still cannot write to prod in the absence
    of the operator
  - Real-time alerting, backups, and log shipping become possible
  - Patches to the verifier itself can flow through normal update channels
  - Aligns the verifier's operational model with `ci-host`/`ai-host` (mesh member,
    patched, monitored) while keeping the trust distinction in the key,
    not the network position
- **Cons:**
  - Non-zero remote attack surface on the host
  - Supply-chain risk if Headscale, sshd, or the kernel ship a bad
    update (mitigated by scoping `unattended-upgrades` to security
    repo only)
  - Piggyback attack: an attacker with persistent on-host access could
    wait for the operator to initiate a deploy and hijack the touched session.
    Real but narrow — requires active, sustained compromise during the
    exact deploy window
  - Creates a hard dependency on procuring a Solo 2C+ NFC before the
    new posture can be adopted
  - Traffic analysis reveals the verifier exists and when it's active

### Option 3: Split verifier — cold signer + warm deployer

Keep the offline "cold" verifier as the holder of a master signing key.
Introduce an always-on "warm" verifier (or repurpose an existing host) that
holds only a short-lived deploy capability signed by the cold verifier.
The operator periodically brings the cold verifier online to pre-sign deploy windows;
the warm verifier executes within those windows.

- **Pros:**
  - Preserves offline-by-default for the highest-value key
  - Always-on component has limited blast radius (only the window
    it was pre-authorised for)
  - Separation of "issue authority" and "execute authority"
- **Cons:**
  - Substantially more complex: two hosts, two key lifecycles, windowing
    protocol, revocation story
  - Traveling-update scenario still partly broken — if a window expires
    while the operator is away, they're back to Option 1's problem
  - More moving parts means more opportunities for the protocol to
    be wrong in subtle ways
  - Overkill for a one-person project; the complexity budget would be
    better spent on the patches themselves

### Option 4: Scheduled wake-on-LAN windows

The verifier stays powered off by default. A trusted on-home-network proxy can
wake it via WoL in response to a signed request from the operator. The verifier comes
up, performs its queue, powers off.

- **Pros:**
  - Keeps the verifier cold most of the time
  - Reduces mean uptime → reduces remote attack window
- **Cons:**
  - Requires an always-on home proxy (which is itself now the
    always-on target; the problem has moved, not vanished)
  - Operator-from-a-cafe scenario still requires the home network to be
    healthy and the proxy to be reachable
  - WoL fails silently in many real-world conditions (BIOS settings,
    driver bugs, switch misconfigurations)
  - Doesn't address the disk-resident-credentials concern at all
  - Adds operational complexity for a marginal improvement

## Decision

**Adopt Option 2: the verifier becomes always-on, Headscale-resident, and
prod-write credentials move to a Solo 2C+ NFC hardware token. The new
inviolable property is "no prod write without physical touch on the
hardware token," not "the verifier is offline."**

The Solo 2C+ hardware token is a **prerequisite, not an enhancement**.
Until the token is in hand and the deploy path is reworked to use it,
the old ADR-0017 posture remains in force.

The following properties from ADR-0017 and CLAUDE.md **remain
inviolable** under this ADR:

- **No AI access on the verifier, ever.** No cloud AI session, no local LLM,
  no agent-driven anything. The verifier is purely a human-driven deploy
  executor.
- **No prod access from any AI-accessible host.** authoring, `ci-host`, `ai-host`, and
  any other AI-capable machine continue to have zero prod reachability.
- **Trust flows through signatures, not machines.** Artifacts are still
  trusted because they carry a valid minisign signature from the build-tier
  build tier, not because the verifier happens to have pulled them.
- **Sanitisation stays on the prod server.** Raw user data never
  leaves prod.
- **Deploy requires human presence.** Under the new posture, human
  presence is established by touch on the Solo 2C+, not by physical
  proximity to a powered-off laptop.

## Rationale

The load-bearing property of ADR-0017 — "AI errors cannot cause
production damage" — is carried by *two* defences:

1. The network boundary (offline verifier)
2. The credential boundary (keys on the verifier's disk are protected by the
   fact that the host is mostly unreachable)

Under this ADR, **defence 1 is replaced by a stronger defence 2**: keys
move to hardware where they cannot be extracted or used without a human
touch. The new defence 2 is **strictly stronger than the old defence
1+2 combination against the attack this ADR is supposed to prevent**:
an attacker with code execution on the verifier.

- **Old posture:** attacker needs code execution + time + disk access.
  If they get on-host during the deploy window, they win (can read
  keys from disk, exfiltrate, deploy later).
- **New posture:** attacker needs code execution + operator presence +
  operator touch on the token during their session. If they get
  on-host outside a deploy window, they win nothing — there are no
  keys to steal.

The only attack that is genuinely *worse* under the new posture is the
remote-exploit-of-an-unattended-host class: an attacker who owns the verifier
while the operator is not deploying. Under the old posture, this attacker wins
(steals disk keys). Under the new posture, this attacker wins nothing
until the operator next deploys, at which point they need to be actively
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

- Critical security patches land in minutes from anywhere the operator has a
  Solo 2C+ and a network path — a laptop plus hotspot, a phone on its
  own (see *Deploy client forms* below), or any borrowed machine with
  an NFC reader or USB port
- Host compromise of the verifier no longer implies credential compromise
- Host compromise of the verifier no longer implies deploy capability
- Real-time alerting from prod can reach the verifier (and from there, the operator)
- The verifier itself can be patched, monitored, and file-integrity-checked
- The mental model for operators is simpler: "touch the token to deploy"
  is a single rule, replacing "wait until you're near the laptop"
- Eliminates the proxy-trust question raised by Option 1's workaround
  ("someone else opens the verifier for me")

### Negative

- Requires procuring a Solo 2C+ NFC (cost: ~AU$100, lead time: ~2 weeks
  for shipping from SoloKeys)
- Creates a hard dependency on the token being physically available.
  A lost/destroyed token blocks deploys until a spare is enrolled — so
  **a second Solo 2C+ must be enrolled as a backup before this ADR is
  considered implemented**
- Adds hardening work: sshd scope restriction, fail2ban, aide file
  integrity, scoped unattended-upgrades, auditd log shipping
- Traffic analysis reveals the verifier's network presence and deploy cadence
  (mitigated by: traffic is on a Headscale mesh, not public internet)
- Introduces new operational error modes: token pin lockout, token
  firmware bugs, NFC reader driver issues on the verifier

### Neutral

- The verifier gains a Headscale membership. This does not change its trust
  tier — it remains "no AI, no agent, human-driven only" — but it does
  change its network position. Treat it as a restricted mesh peer:
  reachable by the authoring workstation for deploy orchestration, reachable by no other host
- The WireGuard tunnel to prod can remain ephemeral (brought up only
  during deploys) even though the verifier itself is always on. Belt-and-braces
  against a persistent mesh-to-prod pivot

### Deploy client forms

With the Solo 2C+ now the root of trust for every prod-write action,
the "deploy client" is just *whatever machine holds the SSH session
that touches the token*. The client no longer has to be a specific
trusted laptop. Three forms are explicitly supported and equivalent
from a trust standpoint — the token gates everything, so the client
can be minimal:

1. **Laptop + USB token.** Default form at home. The operator's authoring workstation
   initiates the deploy, the Solo 2C+ is in a USB port, touch confirms
   each credential use. Largest screen, richest diff review, preferred
   when available.

2. **Laptop + phone hotspot + USB token.** Travel form when the operator has
   their laptop with them but is on an untrusted network. Identical to
   form 1 from the verifier's perspective — the only difference is the path
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
   day" window when the operator is carrying nothing but a phone.

The trust-equivalence argument is load-bearing: **the hardware token
is the root of trust, not the client machine.** An attacker who
compromises the phone (or the laptop, or a borrowed machine) gets
a live Headscale session and an SSH terminal — but cannot produce a
token touch, so cannot deploy. This is why form 3 is acceptable even
though a general-purpose phone has a larger attack surface than a
dedicated deploy laptop.

Caveats on form 3:

- **Smaller screen for diff review.** The deploy script's "about to
  deploy commit abc123 to <site> — touch to confirm" prompt is easy to
  read on a phone; a multi-file diff is not. Use form 3 for deploys
  that have already been reviewed on a larger screen (typical path:
  MR reviewed on laptop during the work week → SA-CORE patch lands
  on travel day → build-tier rebuilds and signs → the operator taps to deploy from
  phone, confident in what they already reviewed).
- **Phone as deploy client still needs validation.** The SSH client,
  Headscale mobile client, and NFC touch flow need to be exercised
  end-to-end before form 3 can be declared supported. This is tracked
  as F21 Phase 5b.
- **No AI on the phone deploy path, same as the verifier.** Don't install a
  phone-side agent that auto-deploys — the phone is a dumb terminal.

## Implementation Notes

The new posture is **not live until every item below is completed**.
Partial adoption (e.g., always-on verifier without the hardware token) is
explicitly worse than the status quo and is forbidden.

### Prerequisites (block implementation)

1. **Two Solo 2C+ NFC tokens procured and enrolled** — primary and
   backup. Keys generated on-device, never exported.
2. **CLAUDE.md amendment staged** — see next section. The amendment
   lands in the same commit as the hardening changes, not ahead of
   them.
3. **F21 Phase 1 (Headscale)** complete, since the verifier's always-on access
   path is the mesh.

### Host hardening checklist

- [ ] verifier joins Headscale as a restricted peer (ACL: only the operator's authoring workstation
      can reach it, no `ci-host`/`ai-host`/other reachability)
- [ ] sshd: `AllowUsers <operator>`, `PasswordAuthentication no`,
      `KbdInteractiveAuthentication no`, `PermitRootLogin no`,
      bind only to the Headscale interface
- [ ] fail2ban with aggressive ban times on the sshd jail
- [ ] `unattended-upgrades` scoped to the security repo only; daily;
      reboot-if-required scheduled for a known window
- [ ] `aide` (or equivalent) with weekly runs and report mailed to the operator
- [ ] `auditd` with a rule set covering `/etc`, `$HOME/.ssh`,
      `$HOME/.config`, and the deploy script directory; logs
      shipped daily to `<gitlab-host>` as a signed artifact
- [ ] Firewall: default-deny inbound on the physical NIC; allow only
      on the Headscale interface
- [ ] No Linux user other than the operator has a login shell
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
      "about to deploy commit abc123 to <site> — touch to confirm"
- [ ] Failed touches (timeout, wrong token, cancelled) fail the deploy
      step loudly rather than silently retrying
- [ ] Deploy script logs every touch event with commit SHA and target,
      mailed to the operator on completion

### Monitoring

- [ ] Real-time alerting from prod reaches the verifier over the prod→verifier
      ingress path (this path does not yet exist; it's a new work item)
- [ ] The verifier itself has a Gotify producer (pattern established in
      the `ai-host`'s ollama health-check tooling) that posts "verifier boot",
      "verifier shutdown", "verifier aide report clean/dirty" to the existing
      queue
- [ ] File integrity (`aide`) reports are treated as "must be green";
      a dirty aide report gates deploys until investigated

### CLAUDE.md amendment

The following CLAUDE.md text must be replaced in the same commit that
implements this ADR:

**Remove:**

> "Don't put the verifier on the Headscale mesh. The verifier is offline by default and
> connects only while actively deploying, via a phone hotspot or
> dedicated cellular modem — never via the home LAN and never as a
> Headscale member alongside the `ci-host`/`ai-host`. During deploys the verifier reaches
> `<gitlab-host>` over public HTTPS (with signature verification) and
> reaches prod through a dedicated one-to-one WireGuard tunnel where
> the verifier and prod are the only peers and prod's sshd binds only to the
> tunnel interface. Don't suggest adding the verifier to Headscale or putting
> its traffic over the home router."

**Replace with:**

> "The verifier is the sole host that may write to production, and its
> prod-write credentials live on a Solo 2C+ NFC hardware token with
> touch-required-per-use. The verifier is an always-on Headscale mesh peer,
> reachable only from the authoring workstation, hardened (sshd key-only,
> fail2ban, aide, auditd, scoped unattended-upgrades, LUKS). **No AI
> access on the verifier, ever** — no cloud AI session, no local LLM, no
> agent-driven anything. A deploy requires a human touch on the token
> for every credential use; there is no session cache. See
> [ADR-0019](docs/decisions/0019-verifier-always-on-hardware-rooted-keys.md)
> for the full posture."

The table row in CLAUDE.md § "Distributed Actor Glossary" for `verifier`
also updates: its cell in the "Runs AI?" column stays **no** (inviolable),
its cell in "Prod access?" stays **yes**, and its Role cell changes from
"Verifies signed artifacts, deploys to prod via dedicated WireGuard
tunnel, creates bug reports back to build-tier" to "Verifies signed artifacts,
deploys to prod via hardware-token-gated credentials; always-on mesh
peer hardened per ADR-0019".

### F21 amendment

F21 Phase 5 (minisign verification on the verifier), Phase 6 (WireGuard tunnel
to prod), and Phase 7 (key management) all need to be revised to reflect
the new credential custody model. The cleanest approach is to add a new
Phase 4.5 ("verifier hardening per ADR-0019") that gates Phases 5-8.

## Review

**30-day review date:** 2026-05-09

**Review criteria:**

- Has the Solo 2C+ been procured, enrolled, and verified as working?
- Has the verifier been hardened per the checklist and does aide report clean?
- Has at least one test deploy been completed end-to-end from a
  non-home network (e.g., a cafe, tethered hotspot)?
- Has the traveling-security-update scenario actually been exercised,
  or is it still hypothetical?
- Any attempted compromise events visible in fail2ban / auditd logs?

**Review outcome:** Pending

**Rollback plan:** if the new posture proves unworkable or a successful
compromise is observed, revert to Option 1 by: (1) removing the verifier from
the Headscale mesh, (2) regenerating the prod SSH key on a disk-resident
file, (3) updating prod `authorized_keys`, (4) reinstating the
CLAUDE.md text removed above, (5) marking this ADR as Superseded. The
Solo 2C+ tokens can be repurposed for other roles (e.g., signing git
commits, SSH to the `ci-host`/`ai-host`) so the procurement cost is not lost.
