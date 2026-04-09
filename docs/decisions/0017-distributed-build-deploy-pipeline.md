# ADR-0017: Distributed Build/Deploy Pipeline (mmt build, mons deploy)

**Status:** Accepted (2026-04-08 — implementation started, F21 Phase 3a complete)
**Date:** 2026-04-07
**Decision Makers:** Rob
**Related Issues:** —
**References:** [ADR-0004](0004-two-tier-secrets-architecture.md), [ADR-0005](0005-distributed-contribution-governance.md), [ADR-0006](0006-contribution-workflow.md), [ADR-0009](0009-five-layer-yaml-protection.md), [ADR-0013](0013-four-state-deployment-model.md)

## Context

NWP is moving from a single-machine, manual deployment model to a distributed pipeline that supports:

1. **Hardware-accelerated CI/CD** — running build, lint, and test workloads on local hardware (Ryzen 9 3900X, 24 threads, 31 GiB RAM, NVMe; Beelink Ryzen AI Max+ 395) instead of metered cloud runners.
2. **AI-assisted development** — local LLM agents on the Beelink (mini) plus Claude (when invoked) writing and reviewing code on the metabox (met).
3. **AI-isolated production deployment** — keeping AI agents and prod credentials on physically separate machines, with the deploy machine (mons) network-isolated from all AI-accessible networks, so AI errors, prompt-injection attacks, or supply-chain compromise of AI tooling cannot directly cause production damage.
4. **Realistic CI testing** — running tests against sanitized clones of production data, not invented fixtures.
5. **Blue-green production deployment** — deploying to a parallel slot (`test.prod.site`), validating, then atomically swapping with live `prod.site` so failures never reach users.
6. **Latency-appropriate hosting** — `git.nwpcode.org` located in `au-mel` for sub-10 ms RTT to home development machines; production sites in `us-iad` for east-coast US user proximity.
7. **Open-source preparation** — clean separation of code (public-ready) from data (private) so avc, ss, and dir1 source can eventually be open-sourced.

The existing infrastructure has none of these properties. Builds happen on the dev machine; deploys are manual `pl` commands run from the same machine that wrote the code; the GitLab instance is on the wrong continent (Newark, NJ — 297 ms RTT from home); CI fixtures are invented; production deploys overwrite live files in place; AI agents have whatever access their human operator has.

## Forces

- **Latency**: home network → Newark Linode is 297 ms RTT (measured). This is too slow for chatty CI/CD operations. Home network → Melbourne Linode would be ~5–10 ms.
- **Compute economics**: a $5/month Linode runner is meaningfully slower than a 24-thread Ryzen at home. Local hardware is faster AND free at the margin (electricity already paid).
- **Home upload bandwidth**: measured ~75 Mbps up, ~250 Mbps down (NBN-equivalent). Adequate for fixture uploads and artifact transfers; the bottleneck is RTT, not throughput.
- **AI risk surface**: AI agents that can directly touch production are a single hallucination or prompt injection away from catastrophe.
- **Test fidelity**: tests against invented fixtures pass for the wrong reasons; sanitized prod data is qualitatively different.
- **PII protection**: the only way to combine "realistic test data" with "shareable codebase" is a clean PII boundary that lives in the publication pipeline, not in the code.
- **User-perceived latency**: user-facing sites should be hosted near users, which is a different geographic decision than where dev infrastructure should live.
- **Open-source preference**: prefer open source and self-hosted infrastructure where the operational cost is reasonable.

## Options Considered

### Option 1: Status quo (manual local deploy, no CI)

- **Pros:**
  - No new infrastructure
  - No new failure modes
- **Cons:**
  - Doesn't scale beyond a couple of sites
  - No safety net between dev and prod
  - AI agents either have to be denied access or given dangerous prod access
  - No realistic test substrate
  - Trans-Pacific latency dominates every git/CI operation

### Option 2: Centralized CI/CD on `git.nwpcode.org` Linode

- **Pros:**
  - Single machine to manage
  - Simple mental model
- **Cons:**
  - Cloud runners are slow and metered for non-trivial workloads
  - Requires the Linode to be massively oversized for occasional builds
  - Doesn't separate AI agents from production credentials
  - Doesn't enable sanitized fixtures or blue-green deploy
  - Single point of failure for everything

### Option 3: Distributed mmt + mons + au-mel + us-iad (chosen)

- **Pros:**
  - Build/test runs on home hardware (free, fast)
  - Air-gap between AI machines and production deploy
  - Blue-green deploy on prod with shared DB and forward-compatible migrations
  - Sanitized fixtures published from prod for realistic CI testing
  - Geographic optimization: dev infrastructure near developer, user infrastructure near users
  - Open-source preparation comes naturally from the sanitization architecture
- **Cons:**
  - More moving parts; more failure modes to understand
  - Requires hardware tokens and a separate physical machine (mons)
  - Sanitizer is security-critical and must be carefully designed
  - Initial buildout effort is meaningful (multi-week)

### Option 4: Hybrid (mmt build, prod-side runner deploy, no mons)

- **Pros:**
  - Slightly simpler than Option 3
  - Removes the need for a separate physical machine
- **Cons:**
  - Loses the air-gap that defends against AI errors and prompt injection
  - Whatever runs the deploy step still has prod credentials accessible to it
  - Defeats the entire point of the threat model

## Decision

Adopt **Option 3**: a distributed pipeline with named, role-bound components.

### Actor roster

| Name | Role | AI? | Touches prod? | Trust |
|---|---|---|---|---|
| **dev workstation** | interactive editor (often via Remote SSH to met) | yes | no | trusted, mobile |
| **met** (metabox, Ryzen 9 3900X) | always-on home compute, primary build/test runner, canonical dev tree | yes (Claude, agents) | no | trusted, home LAN |
| **mini** (Beelink Ryzen AI Max+ 395) | always-on home AI agent, second runner, alerting and triage | yes (local LLM 24/7) | no | trusted, home LAN |
| **mmt** | met + mini together — the build/test team | yes collectively | no | trusted as a pair |
| **mons** | separate laptop, runs `pl` deploy commands, holds prod SSH keys (on hardware token), publishes deploy audit log | **no AI** | **yes — only one** | maximum trust, isolated |
| **`git.nwpcode.org`** | self-hosted GitLab in `au-mel` (post-migration); transports code, fixtures, artifacts, audit between AI side and mons side | n/a | indirectly | trusted as transport, not as authority |
| **prod servers** | `us-iad` Linode hosting avc/ss/dir1; runs sanitizer daily | n/a | self | the thing being protected |

### Pipeline flow

```
authoring on met (or dev workstation via Remote SSH to met)
   │ signed git push
   ▼
git.nwpcode.org (au-mel)
   │ pipeline trigger
   ▼
mmt CI: verify-signatures → lint → build → test → sign-artifact → upload-to-package-registry
   │ artifact marked pending-approval
   ▼
human approves (signed release tag with offline approval key)
   │
   ▼
mons polls package registry, fetches artifact + signature
mons verifies signature against locally-held public key
   │ touch hardware token for prod SSH
   ▼
mons unpacks to test.prod.site slot on prod (alongside live prod.site)
mons runs forward-compat DB migrations against shared live DB
mons runs validation suite against test.prod.site (live DB, test slot routing)
   │ all green
   ▼
mons acquires brief RO lock on prod.site, atomic symlink swap, releases lock
mons runs post-swap smoke test
   │
   ▼
mons writes signed deploy audit record back to git.nwpcode.org

Independently, daily on prod:
nwp-publish-fixture (systemd timer)
   │ scrub current DB → sanitized snapshot
   │ PII regex sweep on output
   │ minisign-sign output
   │ POST to GitLab Packages API (write_package_registry-only token)
   ▼
mmt CI uses latest published fixture as test substrate
```

### Component-level decisions

These are the specific tools chosen, with rationale:

- **Trust transport**: code, fixtures, and audit records flow through `git.nwpcode.org`. The git server is treated as a transport, **not as a trust authority**. mons verifies all artifacts against a public key it holds locally; a compromised git server cannot forge a signature.
- **Artifact signing**: **minisign** (not sigstore/cosign). Self-contained, no transparency-log dependency on a third party (sigstore.dev/Rekor).
- **Hardware token**: **Solo 2C+ NFC Security Key** (Trussed-based, open firmware), 2 units (daily + offsite backup). SSH ed25519-sk with `verify-required` (PIN) and `resident` (key-on-token) flags. Touch-to-sign on every prod connection.
- **External access VPN for mmt**: **Headscale on the au-mel Linode** with official Tailscale clients on dev workstation, met, and mini. mons is deliberately not a member of this overlay and never joins a network that met or mini can see.
- **mons connectivity model**: mons is **offline by default** — powered off when not deploying, with no persistent network connection at any time. When deploying, mons connects via a **phone hotspot** (or, preferred, a dedicated cellular modem with its own data-only SIM) — never to the home LAN, never to Headscale, never via home router. In this deploy window mons reaches two destinations: `git.nwpcode.org` over public HTTPS (with minisign verification of every artifact), and prod over a **dedicated one-to-one WireGuard tunnel**. When the deploy completes, the tunnel is torn down and mons is powered off.
- **mons ↔ prod transport**: **dedicated one-to-one WireGuard tunnel**. mons and prod are the *only* peers — no coordination server, no other members, no mesh. Prod's `sshd` binds only to the WireGuard tunnel interface, never to the public internet; the public SSH port on prod is closed. This means prod SSH is effectively invisible to internet scanners, mons's carrier-NAT'd IP can change freely without reconfiguration, and a compromise of any other machine (including everything on Headscale) has no path to prod SSH.
- **Production hosting region**: `us-iad` (Washington DC, Equinix Ashburn) — modern hardware tier (Premium Plans available), best US peering, closest to expected US Catholic audience centroid. To be revisited once user-geography data exists.
- **GitLab hosting region**: `au-mel` (Melbourne) — sub-10 ms RTT from home network for fast CI, git, and registry operations. Migrated from Newark per F21 Phase 4.
- **MariaDB version floor**: 10.11 LTS (Ubuntu 24.04 default) for INSTANT/ONLINE DDL on most schema changes.
- **Migration discipline**: forward-compatible schema migrations as the default; expand-contract pattern for unsafe changes; the rare unavoidable exclusive-lock change runs under a brief read-only window.
- **Sanitization model**: runs **on prod**, never moves raw data off prod. Output published via GitLab Packages API with a `write_package_registry`-only deploy token; additional server-side PII regex sweep before acceptance.
- **Sanitizer code**: lives in NWP, deploys to prod via the normal pipeline, but sits on the **"AI may propose changes via MR but a human MUST review the merge"** list. No AI-only merges of sanitizer code.
- **Blue-green deploy**: code-level only; both slots **share the live DB**; the read-only window covers only the symlink swap (seconds), not the validation phase.
- **Local LLM**: mini runs a local LLM (ollama or llama.cpp on Ryzen AI Max+ 395) for routine monitoring and triage; Claude API is invoked only for higher-complexity work explicitly initiated by the user or escalated by mini.
- **Alerting**: layered (INFO/WARN/ERROR/CRITICAL/SECURITY) with hard severity floors that AI cannot downgrade; push notifications via self-hosted **Gotify** (not Pushover/Twilio).

## Threat Model

Made explicit because the architecture only makes sense in light of it:

**Third-party services**: We assume any third-party service can be compromised, coerced, or shut down. We minimize reliance on third parties. Where unavoidable (Linode for hosting, Let's Encrypt for certs, OS package repos), we treat them as the trust anchors of last resort and design so that compromise of any one third party does not catastrophically defeat us.

**AI agents**: We assume AI agents (mini's local LLM, Claude when invoked) can hallucinate, be prompt-injected, or behave unexpectedly. Production access is gated by mons — an AI-free machine with hardware-backed SSH keys. AI proposals must pass CI, signature verification, and (for security-sensitive code) human review before they reach prod.

**Open-source bias**: We prefer open source and self-hosted where reasonable, accepting moderate operational complexity in exchange for reduced third-party trust.

**The single load-bearing property**: **Trust flows through cryptographic signatures, not through machines.** AI machines are productive but not trusted. The git server is available but not trusted. CI runners are fast but not trusted. mons is trusted only because the things it accepts must be signed by a key the operator controls offline, and the things it does require a hardware token touch.

## Threat Model Calibration

This architecture is meaningfully more cautious than industry norm for sites of this size and audience. That is intentional, and the calibration deserves to be recorded so future readers (and future-Rob) can judge whether to relax or tighten any specific rule.

### Why "paranoid" is the right disposition here

Two facts about NWP's situation justify the unusually strict posture. Without them, the model would be overkill:

1. **AI is in the build loop.** This is the unusual factor. If a human were doing every deploy, "ssh key + 2FA on GitLab" would be enough for sites this size. But Claude and mini's local LLM will be writing and merging code, and AI agents have been confidently wrong about destructive operations before. The mons boundary exists because AI is in the loop, not because the data is unusually precious.
2. **Code will be open-sourced with sanitized fixtures.** As soon as avc/ss/dir1 source code is published with realistic test fixtures, NWP needs a hard, auditable PII boundary. "We try to be careful" doesn't survive a single mistake. The sanitizer-runs-on-prod rule is what makes open-sourcing safe.

The word "paranoid" sets the right disposition (default-no, justify exceptions) even where individual rules could be relaxed without losing the security property. The disposition is what protects against the next "let's just temporarily…" suggestion.

### Where the architecture is arguably over-engineered

These are places where a less paranoid stance could relax things without breaking the threat model:

- **Strict sneakernet-only air-gap for mons.** USB transfer for every deploy would be real friction for a one-person ministry project. The chosen model — "offline by default; phone hotspot or dedicated cellular modem when deploying; dedicated one-to-one WireGuard tunnel to prod" — preserves the meaningful isolation property (mons is never on the home LAN, not even via VLAN; stronger than any firewall rule) while removing the daily USB-stick ritual. The signature-based trust model means a hostile carrier cannot compromise mons; the worst a hostile transport can do is deny service. Sneakernet is retained for the ceremonies where network-free matters most: initial key enrollment, hardware token pairing, and recovery from a compromised transport.
- **Hardware tokens for prod deploys.** Above industry norm for sites this size, but the friction is one PIN tap per deploy and the hardware cost is ~US$100 for two units. Keep.
- **Self-hosted everything (Headscale, Gotify, GitLab, local LLM).** Higher one-time setup cost than the SaaS equivalents, but matches the open-source preference and the operational cost after setup is near zero. Keep.

### Where the architecture is arguably under-paranoid

Gaps that this ADR does not address and that should be tracked separately:

- **Backup encryption and offsite location.** Where do encrypted backups live? Who holds the decryption key? What's the recovery drill? Not covered here.
- **Dependency supply chain.** Composer and npm lockfile pinning, audit cadence, and policy on accepting transitive updates are not addressed. AI-assisted dependency bumps are a realistic supply-chain risk vector.
- **mons physical security.** Full-disk encryption, physical location, theft response, and "what if mons is lost or damaged" are noted as open questions but not yet solved.
- **Sanitizer false-negative drill.** The architecture says the sanitizer is security-critical and must have a regex sweep, but does not yet specify how false-negative resistance gets ongoing testing.

These gaps are explicitly out of scope for this ADR but should be picked up as follow-on work before the sanitizer pipeline goes live.

### Summary

Reasonable, not paranoid — but only because of the two specific facts above. Track the under-paranoid gaps as follow-on work; relax the air-gap to "pull-only channel by default, USB for ceremony" in the implementation; keep everything else as written.

## Rationale

### Why distribute build/deploy across multiple machines?

Compute and trust have different optimum locations:

- **Compute** wants to be where the cycles are (24-thread Ryzen at home, free at the margin).
- **Trust** wants to be where you can audit and contain it (mons, single-purpose, no AI, hardware-backed key).

A single-machine model forces these into the same compromise. The distributed model lets each component optimize for its actual job.

### Why the air-gap, not just "limited permissions"?

Software permissions can be bypassed, escalated, or worked around. Physical separation cannot. A machine with no prod SSH key cannot deploy to prod, even if it is fully compromised. This is the strongest practical defense against AI-introduced or AI-enabled production damage.

### Why sanitized fixtures from prod?

Two independent benefits:

1. **CI tests gain enormous realism.** "Tests pass on the fixture" approaches "tests will pass on prod" because the fixture *is* prod (modulo PII).
2. **The clean PII boundary makes the source code shareable.** avc/ss/dir1 can be open-sourced (eventually) without exposing user data, because the data lives in private fixtures and the code lives in public repos.

These benefits don't require new technology — just discipline about where the boundary lives.

### Why sanitization on prod, not on mons?

Raw data never leaves prod. If sanitization happened on mons, raw PII would be transferred from prod to mons in the clear (over SSH, but still on disk during processing), giving an extra surface for accidents. Prod-side sanitization is strictly safer for data handling. The cost is that prod gains a narrow git push credential, which is acceptable because it is scoped to the package registry only.

### Why blue-green with a shared DB?

Most blue-green discussions assume two slots with two databases, which creates a data-loss window during the swap. The actual risk being mitigated is **broken code reaching users**, not database failure. Shared DB + forward-compat migrations + code-only swap eliminates the data-loss problem while still giving us the safety property we wanted (validate the new code on the real DB before any user sees it).

### Why these specific tools (Headscale, Solo 2C+, minisign, Gotify)?

All chosen to satisfy the threat model: open source, self-hostable, no third-party transparency log, no SaaS message broker. Each can be replaced individually without breaking the architecture if a better option emerges.

### Why us-iad and au-mel as separate regions?

These optimize for different audiences:

- **Dev infrastructure** (`git.nwpcode.org`, mmt push targets, registry) should be near the developer (Melbourne).
- **User infrastructure** (production sites) should be near users (Washington DC for the assumed US Catholic audience).

Trying to put both in one region compromises both.

### Why Solo 2C+ over YubiKey 5?

The user prefers open source. Solo 2 is built on the open-source Trussed firmware framework with open-source hardware design. YubiKey is more polished and supports more applets (PGP, PIV, OATH) but is fully proprietary. For the SSH ed25519-sk use case, Solo 2C+ is sufficient and aligns with the open-source bias.

### Why a dedicated mons↔prod WireGuard tunnel, not Headscale?

Headscale is the right answer for mmt (met, mini, dev workstation) because those machines form a small mesh where each of them needs to reach several of the others, and the membership changes over time (dev workstation roams). Coordination-server-based overlays pay for themselves in that shape.

mons has a different shape: it talks to *exactly one* other machine (prod), *infrequently*, and wants *maximum isolation from everything else*. Putting mons on Headscale would make it a member of an overlay that also contains met and mini, which is exactly the property the design is trying to avoid — the whole point of mons is that a compromise of met or mini must not propagate to mons. A dedicated point-to-point WireGuard tunnel with two static peer keys and no coordination server gives mons its own private wire to prod and nothing else. Setup is a one-time config file on each end; there is no ongoing operational cost.

The two models coexist cleanly: Headscale carries mmt's daily work; a dedicated WireGuard tunnel carries mons's deploys. Different overlays, different trust domains, same underlying protocol.

### Why phone hotspot / cellular modem instead of sneakernet for mons?

Strict sneakernet (USB-stick-only transfer) would give the strongest possible isolation but demands a physical ritual on every deploy, which is unsustainable for a one-person project. Phone hotspot (or a dedicated cellular modem) gives near-equivalent isolation with dramatically less friction:

- **Home LAN isolation is preserved**: mons is never on the same network as met, mini, or any other home device. An attacker who compromises anything on the home LAN has no network path to mons whatsoever.
- **Offline-by-default is preserved**: mons has no persistent network state. It comes online only during an active deploy, for minutes at a time.
- **Signature-based trust is unaffected**: a hostile carrier or hostile phone can only delay or drop packets. It cannot forge a signed artifact (minisign verification fails), cannot forge an SSH session (ed25519-sk + hardware token), and cannot reach mons inbound (carrier NAT + no listening services on mons).
- **Works from anywhere**: mons can deploy from any location with cellular coverage, which is useful for disaster-recovery scenarios.

A dedicated cellular modem with its own data-only SIM is preferred over tethering the user's personal phone, because it keeps the general-purpose-phone attack surface out of the deploy path. The modem costs ~US$60–100 and a minimal data-only plan covers the tiny traffic volume needed.

USB sneakernet is retained, but only for ceremonies where network-free matters most: initial key enrollment, hardware token pairing, deploy-approval key bootstrap, and recovery from a compromised transport.

### Why Headscale over Tailscale?

Tailscale's coordination server is operated by a third party (Tailscale Inc.). Even though they cannot read traffic, their service could be compromised or compelled. Headscale is the open-source self-hosted equivalent of the Tailscale coordination server, giving the same client ergonomics with no third-party dependency. Hosting it on the existing au-mel Linode adds no new infrastructure cost.

## Consequences

### Positive

- **Faster CI/CD**: home hardware vs cloud runners; LAN-class git operations after au-mel migration.
- **Safer production**: AI cannot reach prod directly; signed-artifact verification on mons; hardware-backed prod SSH key; blue-green deploy with validation before swap.
- **Realistic tests**: sanitized prod data as the test substrate.
- **Open-source-able codebase**: clean PII boundary makes avc/ss/dir1 publishable without leaking user data.
- **Reduced third-party trust**: VPN, signing, alerting, and AI inference are all self-hosted by default.
- **Geographic latency optimization** for both developer and end-user.
- **Audit trail**: every prod change passes through mons and is recorded in `git.nwpcode.org` as a signed deploy record.

### Negative

- **More moving parts**: multiple machines, multiple keys, multiple credentials, more failure modes to understand.
- **Sanitizer is security-critical**: a sanitizer bug could publish PII publicly. Requires careful design, test suite, output sweep, manual review on changes.
- **Hardware dependencies**: requires hardware tokens and a separate mons machine. Tokens cost money and ship from overseas; mons must be acquired and set up.
- **Forward-compat migration discipline**: developers must learn the expand-contract pattern for non-trivial schema changes.
- **Buildout effort**: multi-week phased rollout to put it all in place.
- **Operational burden**: more services to monitor, update, and back up than a single-server setup.
- **Cold-machine bootstrapping**: setting up mons from scratch requires ceremony (key generation, hardware token enrollment, public key bootstrap).

### Neutral

- **Existing four-state model unchanged**: dev → stg → live → prod still applies (per [ADR-0013](0013-four-state-deployment-model.md)). The new architecture refactors what happens at the "prod" step (in-place overwrite → blue-green swap on mons) but does not change the upstream state machine.
- **Existing two-tier secrets architecture preserved**: [ADR-0004](0004-two-tier-secrets-architecture.md)'s data-vs-infra distinction still applies; mons holds the data tier, mmt holds the infra tier.
- **Existing contribution governance applies**: [ADR-0005](0005-distributed-contribution-governance.md) and [ADR-0006](0006-contribution-workflow.md) review/security processes apply to MRs targeting any of the new components, especially the sanitizer.

## Implementation Notes

The full phased rollout is sequenced as approximately 13 phases:

1. **External access foundation** — Headscale on au-mel Linode; Tailscale clients on met, mini, dev workstation; ACL excludes mons; Remote SSH dev experience verified.
2. **First runner** — metabox registered as GitLab Runner against the existing GitLab instance; signed-commit verification; first pilot pipeline (lint+build+test) running.
3. **Second runner + artifact pipeline** — beelink registered as second runner; build-artifact and minisign-artifact stages added; artifacts pushed to GitLab Package Registry.
4. **GitLab migration Newark → au-mel** — provision new au-mel Linode; install matching GitLab CE version; backup/restore over Headscale; DNS cutover (TTL pre-lowered); runner re-registration; 7-day soak with Newark held warm; decommission Newark. Reduces RTT from 297 ms to ~5 ms. Reversible up to the decommission step. See F21 Phase 4 for the step-by-step.
5. **mons bootstrap** — mons provisioned from clean media; LUKS full-disk encryption; no AI tooling installed; Solo 2C+ enrolled; deploy-approval public key baked in; cellular modem (or documented phone-hotspot tethering procedure) configured for on-demand connectivity; WireGuard keypair generated on mons with the private key held inside the LUKS-protected root; prod configured with mons's public key as its *only* WireGuard peer; prod sshd rebound to the WireGuard tunnel interface and the public SSH port closed; tunnel tested end-to-end; first manual deploy of a pilot site through the full mons-mediated flow.
6. **Sanitizer v0** — design + classification + per-table strategies for one site (avc); sanitizer test suite; output regex sweep; manual review of first sanitized snapshot before any publish.
7. **Fixture publication channel** — GitLab Packages API integration with `write_package_registry`-only deploy token; first sanitized fixture pushed; mmt CI fetches it as test substrate.
8. **Blue-green slot mechanism** — symlinks, shared files dir, shared DB, swap script (avc only, then per-site).
9. **End-to-end blue-green deploy** — first full pipeline run for avc: signed commit → mmt CI on fixture → signed artifact uploaded to package registry → mons powered on → mons tethers cellular → `wg-quick up wg0` brings tunnel to prod up → mons fetches artifact from `git.nwpcode.org` over public HTTPS → verifies minisign signature → SSHes to prod through the tunnel (hardware token touch) → unpacks to test.prod.site slot → forward-compat migrate → validate on test slot → brief RO lock + atomic symlink swap → smoke test → signed deploy audit record pushed to `git.nwpcode.org` → `wg-quick down wg0` → mons powered off.
10. **Bug-report and AI-fix loop** — mons posts structured failure reports; mini's AI watches for them; proposes fix MRs; closes the loop on a deliberate fault-injection drill.
11. **Per-site rollout** — repeat 6–10 for ss, dir1, others.
12. **mini alerting + Claude escalation** — log shipping to mini; rules engine with hard severity floors; Gotify push; SECURITY-level Claude auto-engagement protocol.
13. **Hardening + tabletop review** — runbooks for "mons down", "token lost", "sanitizer false negative", "git.nwpcode.org compromised"; tabletop walkthrough of each scenario.

Phases 1–4 are ungated and reversible. Phases 5–8 require hardware tokens and mons to exist. Phases 9–10 are the first "moment of truth" where everything must work together. Phases 11–13 are stabilization and rollout.

### Key separation summary

| Key | Lives | Used for |
|---|---|---|
| Personal commit-signing key | dev workstation + met, in keyring/agent | source commits, release tags |
| Runner artifact signing key | metabox + beelink, gitlab-runner user keystore | CI build artifacts (intermediate) |
| Deploy-approval signing key | offline, hardware token (Solo 2C+) | release tags that mons trusts |
| Prod SSH key | resident on Solo 2C+, plugged into mons during deploys | mons → prod SSH (touch required) |
| Fixtures publish token | prod server, `/etc/nwp/secrets/`, mode 0600 root-only | sanitizer → GitLab Packages API |
| mons ↔ prod WireGuard keypair | mons private key in `/etc/wireguard/wg0.conf` under LUKS; prod holds mons's public key as its only peer | encrypted transport for mons → prod deploy traffic; prod sshd binds only to the tunnel interface |

### Drupal/MariaDB migration policy

Per the discussion that produced this ADR:

- **Default**: every schema change should be either INSTANT/ONLINE on MariaDB 10.11+ OR follow expand-contract.
- **Safe-by-default operations**: adding nullable columns, adding new tables, adding indexes. These run as ONLINE/INSTANT on MariaDB 10.11+.
- **Expand-contract required**: column drops, renames, type narrowing. Two-or-three-deploy patterns.
- **CI canary**: "old code on new schema" job verifies forward-compat by running the previous tagged release against the new schema.
- **Read-only window tolerance**: per [ADR-0013](0013-four-state-deployment-model.md), prod sites are free/non-critical enough to tolerate occasional minute-scale RO windows. This allows pragmatic exceptions for unavoidable non-forward-compat changes.

### Out of scope for this ADR

- Migration of avc/ss/dir1 source code to public repos (will be a separate ADR once sanitizer pipeline is proven).
- Migration of production sites avc/ss/dir1 from current host to `us-iad` Linode (separate decision; same principle as the GitLab migration but with different data and downtime considerations).
- Multi-region production hosting (deferred until user-geography data justifies it).
- Specific recipes for the sanitizer per-site classifications (will be implementation-time decisions captured in the sanitizer's own documentation).

## Open Questions

To be resolved as implementation proceeds:

- Where does mons physically live (same room, different room, different building)?
- Existing avc/ss sanitization code, or greenfield?
- Site sizes (drives fixture channel sizing).
- Are uploaded files sensitive on avc/ss (drives whether files need sanitizing too or can ship as-is)?
- Existing Drupal migration history — any non-forward-compat patterns to know about?
- Local LLM on the Beelink — already running, planned, or still to set up?

## Review

**30-day review date:** 2026-05-07

**Success criteria for review:**

- [ ] Headscale operational; remote dev via VS Code Remote SSH from dev workstation to met working
- [ ] Metabox registered as GitLab Runner; first signed-commit pipeline running
- [ ] (Optional gate) au-mel migration started or sequenced
- [ ] Hardware tokens ordered (lead time on shipping from EU)
- [ ] mons bootstrap plan documented even if not yet executed

## Related Decisions

- **[ADR-0004](0004-two-tier-secrets-architecture.md)**: Two-tier secrets architecture — preserved; mons holds the data tier, mmt holds the infra tier.
- **[ADR-0005](0005-distributed-contribution-governance.md)**: Distributed contribution governance — applies to all MRs in the new system, especially sanitizer changes.
- **[ADR-0006](0006-contribution-workflow.md)**: Contribution workflow — MR review requirements apply.
- **[ADR-0009](0009-five-layer-yaml-protection.md)**: Five-layer YAML protection — orthogonal but complementary protection layer.
- **[ADR-0013](0013-four-state-deployment-model.md)**: Four-state deployment model — preserved; this ADR refactors what happens at the "prod" step but does not change the dev → stg → live → prod state machine.
