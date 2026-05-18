# ADR-0017: Distributed Build/Deploy Pipeline (build-tier build, verifier deploy)

**Status:** Accepted (2026-04-08 — implementation started; F21 Phases 1, 2, 3a complete)
**Date:** 2026-04-07
**Decision Makers:** Robert Karsten Zaar (with AI assistance)
**Related Issues:** —
**References:** [ADR-0004](0004-two-tier-secrets-architecture.md), [ADR-0005](0005-distributed-contribution-governance.md), [ADR-0006](0006-contribution-workflow.md), [ADR-0009](0009-five-layer-yaml-protection.md), [ADR-0013](0013-four-state-deployment-model.md)

## Context

NWP is moving from a single-machine, manual deployment model to a distributed pipeline that supports:

1. **Hardware-accelerated CI/CD** — running build, lint, and test workloads on local hardware (a `ci-host` with 12-core CPU, mid-range GPU, 32 GB RAM; an `ai-host` running on an APU with Ryzen AI Max+-class silicon and 64–128 GB unified memory) instead of metered cloud runners.
2. **AI-assisted development** — local LLM agents on the `ai-host` plus cloud AI (when invoked) writing and reviewing code on the `ci-host`.
3. **AI-isolated production deployment** — keeping AI agents and prod credentials on physically separate machines, with the deploy machine (`verifier`) network-isolated from all AI-accessible networks, so AI errors, prompt-injection attacks, or supply-chain compromise of AI tooling cannot directly cause production damage.
4. **Realistic CI testing** — running tests against sanitized clones of production data, not invented fixtures.
5. **Blue-green production deployment** — deploying to a parallel slot (`test.prod.site`), validating, then atomically swapping with live `prod.site` so failures never reach users.
6. **Latency-appropriate hosting** — `<gitlab-host>` located in `au-mel` for sub-10 ms RTT to home development machines; production sites in `us-iad` for east-coast US user proximity.
7. **Open-source preparation** — clean separation of code (public-ready) from data (private) so per-site source can eventually be open-sourced.

The existing infrastructure has none of these properties. Builds happen on the dev machine; deploys are manual `pl` commands run from the same machine that wrote the code; the self-hosted GitLab instance is on the wrong continent (Newark, NJ — 297 ms RTT from home); CI fixtures are invented; production deploys overwrite live files in place; AI agents have whatever access their human operator has.

## Forces

- **Latency**: home network → Newark Linode is 297 ms RTT (measured). This is too slow for chatty CI/CD operations. Home network → Melbourne Linode would be ~5–10 ms.
- **Compute economics**: a $5/month Linode runner is meaningfully slower than a 12-core CPU at home. Local hardware is faster AND free at the margin (electricity already paid).
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

### Option 2: Centralized CI/CD on `<gitlab-host>` Linode

- **Pros:**
  - Single machine to manage
  - Simple mental model
- **Cons:**
  - Cloud runners are slow and metered for non-trivial workloads
  - Requires the Linode to be massively oversized for occasional builds
  - Doesn't separate AI agents from production credentials
  - Doesn't enable sanitized fixtures or blue-green deploy
  - Single point of failure for everything

### Option 3: Distributed build-tier + verifier + au-mel + us-iad (chosen)

- **Pros:**
  - Build/test runs on home hardware (free, fast)
  - Air-gap between AI machines and production deploy
  - Blue-green deploy on prod with shared DB and forward-compatible migrations
  - Sanitized fixtures published from prod for realistic CI testing
  - Geographic optimization: dev infrastructure near developer, user infrastructure near users
  - Open-source preparation comes naturally from the sanitization architecture
- **Cons:**
  - More moving parts; more failure modes to understand
  - Requires hardware tokens and a separate physical machine (`verifier`)
  - Sanitizer is security-critical and must be carefully designed
  - Initial buildout effort is meaningful (multi-week)

### Option 4: Hybrid (build-tier build, prod-side runner deploy, no verifier)

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

| Role | Description | AI? | Touches prod? | Trust |
|---|---|---|---|---|
| **authoring** | interactive editor (often via Remote SSH to `ci-host`) | yes | no | trusted, mobile |
| **ci-host** | always-on home compute, primary build/test runner, canonical dev tree | yes (cloud AI, agents) | no | trusted, home LAN |
| **ai-host** | always-on home AI agent, second runner, alerting and triage | yes (local LLM 24/7) | no | trusted, home LAN |
| **build-tier** | `ci-host` + `ai-host` together — the build/test team | yes collectively | no | trusted as a pair |
| **verifier** (also called **signed-deploy**) | separate machine, runs `pl` deploy commands, holds prod SSH keys (on hardware token), publishes deploy audit log | **no AI** | **yes — only one** | maximum trust, isolated |
| **`<gitlab-host>`** | self-hosted GitLab in `au-mel` (post-migration); transports code, fixtures, artifacts, audit between AI side and verifier side | n/a | indirectly | trusted as transport, not as authority |
| **prod servers** | `us-iad` Linode hosting per-site deployments; runs sanitizer daily | n/a | self | the thing being protected |

### Pipeline flow

```
authoring on ci-host (or authoring workstation via Remote SSH to ci-host)
   │ signed git push
   ▼
<gitlab-host> (au-mel)
   │ pipeline trigger
   ▼
build-tier CI: verify-signatures → lint → build → test → sign-artifact → upload-to-package-registry
   │ artifact marked pending-approval
   ▼
human approves (signed release tag with offline approval key)
   │
   ▼
verifier polls package registry, fetches artifact + signature
verifier verifies signature against locally-held public key
   │ touch hardware token for prod SSH
   ▼
verifier unpacks to test.prod.site slot on prod (alongside live prod.site)
verifier runs forward-compat DB migrations against shared live DB
verifier runs validation suite against test.prod.site (live DB, test slot routing)
   │ all green
   ▼
verifier acquires brief RO lock on prod.site, atomic symlink swap, releases lock
verifier runs post-swap smoke test
   │
   ▼
verifier writes signed deploy audit record back to <gitlab-host>

Independently, daily on prod:
nwp-publish-fixture (systemd timer)
   │ scrub current DB → sanitized snapshot
   │ PII regex sweep on output
   │ minisign-sign output
   │ POST to GitLab Packages API (write_package_registry-only token)
   ▼
build-tier CI uses latest published fixture as test substrate
```

### Component-level decisions

These are the specific tools chosen, with rationale:

- **Trust transport**: code, fixtures, and audit records flow through `<gitlab-host>`. The git server is treated as a transport, **not as a trust authority**. The verifier checks all artifacts against a public key it holds locally; a compromised git server cannot forge a signature.
- **Artifact signing**: **minisign** (not sigstore/cosign). Self-contained, no transparency-log dependency on a third party (sigstore.dev/Rekor).
- **Hardware token**: **Solo 2C+ NFC Security Key** (Trussed-based, open firmware), 2 units (daily + offsite backup). SSH ed25519-sk with `verify-required` (PIN) and `resident` (key-on-token) flags. Touch-to-sign on every prod connection.
- **External access VPN for build-tier**: **Headscale on the au-mel Linode** with official Tailscale clients on authoring workstation, `ci-host`, and `ai-host`. The verifier is deliberately not a member of this overlay and never joins a network that `ci-host` or `ai-host` can see.
- **verifier connectivity model**: the verifier is **offline by default** — powered off when not deploying, with no persistent network connection at any time. When deploying, it connects via a **phone hotspot** (or, preferred, a dedicated cellular modem with its own data-only SIM) — never to the home LAN, never to Headscale, never via home router. In this deploy window the verifier reaches two destinations: `<gitlab-host>` over public HTTPS (with minisign verification of every artifact), and prod over a **dedicated one-to-one WireGuard tunnel**. When the deploy completes, the tunnel is torn down and the verifier is powered off.
- **verifier ↔ prod transport**: **dedicated one-to-one WireGuard tunnel**. The verifier and prod are the *only* peers — no coordination server, no other members, no mesh. Prod's `sshd` binds only to the WireGuard tunnel interface, never to the public internet; the public SSH port on prod is closed. This means prod SSH is effectively invisible to internet scanners, the verifier's carrier-NAT'd IP can change freely without reconfiguration, and a compromise of any other machine (including everything on Headscale) has no path to prod SSH.
- **Production hosting region**: `us-iad` (Washington DC, Equinix Ashburn) — modern hardware tier (Premium Plans available), best US peering, closest to expected US audience centroid. To be revisited once user-geography data exists.
- **GitLab hosting region**: `au-mel` (Melbourne) — sub-10 ms RTT from home network for fast CI, git, and registry operations. Migrated from Newark per F21 Phase 4.
- **MariaDB version floor**: 10.11 LTS (Ubuntu 24.04 default) for INSTANT/ONLINE DDL on most schema changes.
- **Migration discipline**: forward-compatible schema migrations as the default; expand-contract pattern for unsafe changes; the rare unavoidable exclusive-lock change runs under a brief read-only window.
- **Sanitization model**: runs **on prod**, never moves raw data off prod. Output published via GitLab Packages API with a `write_package_registry`-only deploy token; additional server-side PII regex sweep before acceptance.
- **Sanitizer code**: lives in NWP, deploys to prod via the normal pipeline, but sits on the **"AI may propose changes via MR but a human MUST review the merge"** list. No AI-only merges of sanitizer code.
- **Blue-green deploy**: code-level only; both slots **share the live DB**; the read-only window covers only the symlink swap (seconds), not the validation phase.
- **Local LLM**: the `ai-host` runs a local LLM (ollama or llama.cpp on its APU silicon) for routine monitoring and triage; cloud AI is invoked only for higher-complexity work explicitly initiated by the user or escalated by the `ai-host`.
- **Alerting**: layered (INFO/WARN/ERROR/CRITICAL/SECURITY) with hard severity floors that AI cannot downgrade; push notifications via self-hosted **Gotify** (not Pushover/Twilio).

## Threat Model

Made explicit because the architecture only makes sense in light of it:

**Third-party services**: We assume any third-party service can be compromised, coerced, or shut down. We minimize reliance on third parties. Where unavoidable (Linode for hosting, Let's Encrypt for certs, OS package repos), we treat them as the trust anchors of last resort and design so that compromise of any one third party does not catastrophically defeat us.

**AI agents**: We assume AI agents (the `ai-host`'s local LLM, cloud AI when invoked) can hallucinate, be prompt-injected, or behave unexpectedly. Production access is gated by the verifier — an AI-free machine with hardware-backed SSH keys. AI proposals must pass CI, signature verification, and (for security-sensitive code) human review before they reach prod.

**Open-source bias**: We prefer open source and self-hosted where reasonable, accepting moderate operational complexity in exchange for reduced third-party trust.

**The single load-bearing property**: **Trust flows through cryptographic signatures, not through machines.** AI machines are productive but not trusted. The git server is available but not trusted. CI runners are fast but not trusted. The verifier is trusted only because the things it accepts must be signed by a key the operator controls offline, and the things it does require a hardware token touch.

## Threat Model Calibration

This architecture is meaningfully more cautious than industry norm for sites of this size and audience. That is intentional, and the calibration deserves to be recorded so future readers (and future operators) can judge whether to relax or tighten any specific rule.

### Why "paranoid" is the right disposition here

Two facts about NWP's situation justify the unusually strict posture. Without them, the model would be overkill:

1. **AI is in the build loop.** This is the unusual factor. If a human were doing every deploy, "ssh key + 2FA on GitLab" would be enough for sites this size. But cloud AI and the `ai-host`'s local LLM will be writing and merging code, and AI agents have been confidently wrong about destructive operations before. The verifier boundary exists because AI is in the loop, not because the data is unusually precious.
2. **Code will be open-sourced with sanitized fixtures.** As soon as per-site source code is published with realistic test fixtures, NWP needs a hard, auditable PII boundary. "We try to be careful" doesn't survive a single mistake. The sanitizer-runs-on-prod rule is what makes open-sourcing safe.

The word "paranoid" sets the right disposition (default-no, justify exceptions) even where individual rules could be relaxed without losing the security property. The disposition is what protects against the next "let's just temporarily…" suggestion.

### Where the architecture is arguably over-engineered

These are places where a less paranoid stance could relax things without breaking the threat model:

- **Strict sneakernet-only air-gap for the verifier.** USB transfer for every deploy would be real friction for a one-person ministry project. The chosen model — "offline by default; phone hotspot or dedicated cellular modem when deploying; dedicated one-to-one WireGuard tunnel to prod" — preserves the meaningful isolation property (the verifier is never on the home LAN, not even via VLAN; stronger than any firewall rule) while removing the daily USB-stick ritual. The signature-based trust model means a hostile carrier cannot compromise the verifier; the worst a hostile transport can do is deny service. Sneakernet is retained for the ceremonies where network-free matters most: initial key enrollment, hardware token pairing, and recovery from a compromised transport.
- **Hardware tokens for prod deploys.** Above industry norm for sites this size, but the friction is one PIN tap per deploy and the hardware cost is ~US$100 for two units. Keep.
- **Self-hosted everything (Headscale, Gotify, GitLab, local LLM).** Higher one-time setup cost than the SaaS equivalents, but matches the open-source preference and the operational cost after setup is near zero. Keep.

### Where the architecture is arguably under-paranoid

Gaps that this ADR does not address and that should be tracked separately:

- **Backup encryption and offsite location.** Where do encrypted backups live? Who holds the decryption key? What's the recovery drill? Not covered here.
- **Dependency supply chain.** Composer and npm lockfile pinning, audit cadence, and policy on accepting transitive updates are not addressed. AI-assisted dependency bumps are a realistic supply-chain risk vector.
- **verifier physical security.** Full-disk encryption, physical location, theft response, and "what if the verifier is lost or damaged" are noted as open questions but not yet solved.
- **Sanitizer false-negative drill.** The architecture says the sanitizer is security-critical and must have a regex sweep, but does not yet specify how false-negative resistance gets ongoing testing.

These gaps are explicitly out of scope for this ADR but should be picked up as follow-on work before the sanitizer pipeline goes live.

### Summary

Reasonable, not paranoid — but only because of the two specific facts above. Track the under-paranoid gaps as follow-on work; relax the air-gap to "pull-only channel by default, USB for ceremony" in the implementation; keep everything else as written.

## Rationale

### Why distribute build/deploy across multiple machines?

Compute and trust have different optimum locations:

- **Compute** wants to be where the cycles are (12-core CPU at home, free at the margin).
- **Trust** wants to be where you can audit and contain it (the verifier, single-purpose, no AI, hardware-backed key).

A single-machine model forces these into the same compromise. The distributed model lets each component optimize for its actual job.

### Why the air-gap, not just "limited permissions"?

Software permissions can be bypassed, escalated, or worked around. Physical separation cannot. A machine with no prod SSH key cannot deploy to prod, even if it is fully compromised. This is the strongest practical defense against AI-introduced or AI-enabled production damage.

### Why sanitized fixtures from prod?

Two independent benefits:

1. **CI tests gain enormous realism.** "Tests pass on the fixture" approaches "tests will pass on prod" because the fixture *is* prod (modulo PII).
2. **The clean PII boundary makes the source code shareable.** Per-site source can be open-sourced (eventually) without exposing user data, because the data lives in private fixtures and the code lives in public repos.

These benefits don't require new technology — just discipline about where the boundary lives.

### Why sanitization on prod, not on the verifier?

Raw data never leaves prod. If sanitization happened on the verifier, raw PII would be transferred from prod to the verifier in the clear (over SSH, but still on disk during processing), giving an extra surface for accidents. Prod-side sanitization is strictly safer for data handling. The cost is that prod gains a narrow git push credential, which is acceptable because it is scoped to the package registry only.

### Why blue-green with a shared DB?

Most blue-green discussions assume two slots with two databases, which creates a data-loss window during the swap. The actual risk being mitigated is **broken code reaching users**, not database failure. Shared DB + forward-compat migrations + code-only swap eliminates the data-loss problem while still giving us the safety property we wanted (validate the new code on the real DB before any user sees it).

### Why these specific tools (Headscale, Solo 2C+, minisign, Gotify)?

All chosen to satisfy the threat model: open source, self-hostable, no third-party transparency log, no SaaS message broker. Each can be replaced individually without breaking the architecture if a better option emerges.

### Why us-iad and au-mel as separate regions?

These optimize for different audiences:

- **Dev infrastructure** (`<gitlab-host>`, build-tier push targets, registry) should be near the developer (Melbourne).
- **User infrastructure** (production sites) should be near users (Washington DC for the assumed US audience).

Trying to put both in one region compromises both.

### Why Solo 2C+ over YubiKey 5?

The operator prefers open source. Solo 2 is built on the open-source Trussed firmware framework with open-source hardware design. YubiKey is more polished and supports more applets (PGP, PIV, OATH) but is fully proprietary. For the SSH ed25519-sk use case, Solo 2C+ is sufficient and aligns with the open-source bias.

### Why a dedicated verifier↔prod WireGuard tunnel, not Headscale?

Headscale is the right answer for build-tier (`ci-host`, `ai-host`, authoring workstation) because those machines form a small mesh where each of them needs to reach several of the others, and the membership changes over time (authoring workstation roams). Coordination-server-based overlays pay for themselves in that shape.

The verifier has a different shape: it talks to *exactly one* other machine (prod), *infrequently*, and wants *maximum isolation from everything else*. Putting the verifier on Headscale would make it a member of an overlay that also contains `ci-host` and `ai-host`, which is exactly the property the design is trying to avoid — the whole point of the verifier is that a compromise of `ci-host` or `ai-host` must not propagate to it. A dedicated point-to-point WireGuard tunnel with two static peer keys and no coordination server gives the verifier its own private wire to prod and nothing else. Setup is a one-time config file on each end; there is no ongoing operational cost.

The two models coexist cleanly: Headscale carries build-tier's daily work; a dedicated WireGuard tunnel carries the verifier's deploys. Different overlays, different trust domains, same underlying protocol.

### Why phone hotspot / cellular modem instead of sneakernet for the verifier?

Strict sneakernet (USB-stick-only transfer) would give the strongest possible isolation but demands a physical ritual on every deploy, which is unsustainable for a one-person project. Phone hotspot (or a dedicated cellular modem) gives near-equivalent isolation with dramatically less friction:

- **Home LAN isolation is preserved**: the verifier is never on the same network as `ci-host`, `ai-host`, or any other home device. An attacker who compromises anything on the home LAN has no network path to the verifier whatsoever.
- **Offline-by-default is preserved**: the verifier has no persistent network state. It comes online only during an active deploy, for minutes at a time.
- **Signature-based trust is unaffected**: a hostile carrier or hostile phone can only delay or drop packets. It cannot forge a signed artifact (minisign verification fails), cannot forge an SSH session (ed25519-sk + hardware token), and cannot reach the verifier inbound (carrier NAT + no listening services on the verifier).
- **Works from anywhere**: the verifier can deploy from any location with cellular coverage, which is useful for disaster-recovery scenarios.

A dedicated cellular modem with its own data-only SIM is preferred over tethering the operator's personal phone, because it keeps the general-purpose-phone attack surface out of the deploy path. The modem costs ~US$60–100 and a minimal data-only plan covers the tiny traffic volume needed.

USB sneakernet is retained, but only for ceremonies where network-free matters most: initial key enrollment, hardware token pairing, deploy-approval key bootstrap, and recovery from a compromised transport.

### Why Headscale over Tailscale?

Tailscale's coordination server is operated by a third party (Tailscale Inc.). Even though they cannot read traffic, their service could be compromised or compelled. Headscale is the open-source self-hosted equivalent of the Tailscale coordination server, giving the same client ergonomics with no third-party dependency. Hosting it on the existing au-mel Linode adds no new infrastructure cost.

## Consequences

### Positive

- **Faster CI/CD**: home hardware vs cloud runners; LAN-class git operations after au-mel migration.
- **Safer production**: AI cannot reach prod directly; signed-artifact verification on the verifier; hardware-backed prod SSH key; blue-green deploy with validation before swap.
- **Realistic tests**: sanitized prod data as the test substrate.
- **Open-source-able codebase**: clean PII boundary makes per-site code publishable without leaking user data.
- **Reduced third-party trust**: VPN, signing, alerting, and AI inference are all self-hosted by default.
- **Geographic latency optimization** for both developer and end-user.
- **Audit trail**: every prod change passes through the verifier and is recorded in `<gitlab-host>` as a signed deploy record.

### Negative

- **More moving parts**: multiple machines, multiple keys, multiple credentials, more failure modes to understand.
- **Sanitizer is security-critical**: a sanitizer bug could publish PII publicly. Requires careful design, test suite, output sweep, manual review on changes.
- **Hardware dependencies**: requires hardware tokens and a separate verifier machine. Tokens cost money and ship from overseas; the verifier must be acquired and set up.
- **Forward-compat migration discipline**: developers must learn the expand-contract pattern for non-trivial schema changes.
- **Buildout effort**: multi-week phased rollout to put it all in place.
- **Operational burden**: more services to monitor, update, and back up than a single-server setup.
- **Cold-machine bootstrapping**: setting up the verifier from scratch requires ceremony (key generation, hardware token enrollment, public key bootstrap).

### Neutral

- **Existing four-state model unchanged**: dev → stg → live → prod still applies (per [ADR-0013](0013-four-state-deployment-model.md)). The new architecture refactors what happens at the "prod" step (in-place overwrite → blue-green swap on the verifier) but does not change the upstream state machine.
- **Existing two-tier secrets architecture preserved**: [ADR-0004](0004-two-tier-secrets-architecture.md)'s data-vs-infra distinction still applies; the verifier holds the data tier, build-tier holds the infra tier.
- **Existing contribution governance applies**: [ADR-0005](0005-distributed-contribution-governance.md) and [ADR-0006](0006-contribution-workflow.md) review/security processes apply to MRs targeting any of the new components, especially the sanitizer.

## Implementation Notes

The full phased rollout is sequenced as approximately 13 phases:

1. **External access foundation** — Headscale on au-mel Linode; Tailscale clients on `ci-host`, `ai-host`, authoring workstation; ACL excludes the verifier; Remote SSH dev experience verified.
2. **First runner** — `ci-host` registered as GitLab Runner against the existing GitLab instance; signed-commit verification; first pilot pipeline (lint+build+test) running.
3. **Second runner + artifact pipeline** — `ai-host` registered as second runner; build-artifact and minisign-artifact stages added; artifacts pushed to GitLab Package Registry.
4. **GitLab migration Newark → au-mel** — provision new au-mel Linode; install matching GitLab CE version; backup/restore over Headscale; DNS cutover (TTL pre-lowered); runner re-registration; 7-day soak with Newark held warm; decommission Newark. Reduces RTT from 297 ms to ~5 ms. Reversible up to the decommission step. See F21 Phase 4 for the step-by-step.
5. **verifier bootstrap** — the verifier provisioned from clean media; LUKS full-disk encryption; no AI tooling installed; Solo 2C+ enrolled; deploy-approval public key baked in; cellular modem (or documented phone-hotspot tethering procedure) configured for on-demand connectivity; WireGuard keypair generated on the verifier with the private key held inside the LUKS-protected root; prod configured with the verifier's public key as its *only* WireGuard peer; prod sshd rebound to the WireGuard tunnel interface and the public SSH port closed; tunnel tested end-to-end; first manual deploy of a pilot site through the full verifier-mediated flow.
6. **Sanitizer v0** — design + classification + per-table strategies for one site; sanitizer test suite; output regex sweep; manual review of first sanitized snapshot before any publish.
7. **Fixture publication channel** — GitLab Packages API integration with `write_package_registry`-only deploy token; first sanitized fixture pushed; build-tier CI fetches it as test substrate.
8. **Blue-green slot mechanism** — symlinks, shared files dir, shared DB, swap script (one pilot site, then per-site).
9. **End-to-end blue-green deploy** — first full pipeline run for the pilot site: signed commit → build-tier CI on fixture → signed artifact uploaded to package registry → verifier powered on → verifier tethers cellular → `wg-quick up wg0` brings tunnel to prod up → verifier fetches artifact from `<gitlab-host>` over public HTTPS → verifies minisign signature → SSHes to prod through the tunnel (hardware token touch) → unpacks to test.prod.site slot → forward-compat migrate → validate on test slot → brief RO lock + atomic symlink swap → smoke test → signed deploy audit record pushed to `<gitlab-host>` → `wg-quick down wg0` → verifier powered off.
10. **Bug-report and AI-fix loop** — the verifier posts structured failure reports; the `ai-host`'s AI watches for them; proposes fix MRs; closes the loop on a deliberate fault-injection drill.
11. **Per-site rollout** — repeat 6–10 for additional sites.
12. **ai-host alerting + cloud-AI escalation** — log shipping to the `ai-host`; rules engine with hard severity floors; Gotify push; SECURITY-level cloud-AI auto-engagement protocol.
13. **Hardening + tabletop review** — runbooks for "verifier down", "token lost", "sanitizer false negative", "`<gitlab-host>` compromised"; tabletop walkthrough of each scenario.

Phases 1–4 are ungated and reversible. Phases 5–8 require hardware tokens and the verifier to exist. Phases 9–10 are the first "moment of truth" where everything must work together. Phases 11–13 are stabilization and rollout.

### Key separation summary

| Key | Lives | Used for |
|---|---|---|
| Personal commit-signing key | authoring workstation + ci-host, in keyring/agent | source commits, release tags |
| Runner artifact signing key | ci-host + ai-host, gitlab-runner user keystore | CI build artifacts (intermediate) |
| Deploy-approval signing key | offline, hardware token (Solo 2C+) | release tags that the verifier trusts |
| Prod SSH key | resident on Solo 2C+, plugged into the verifier during deploys | verifier → prod SSH (touch required) |
| Fixtures publish token | prod server, `/etc/nwp/secrets/`, mode 0600 root-only | sanitizer → GitLab Packages API |
| verifier ↔ prod WireGuard keypair | verifier private key in `/etc/wireguard/wg0.conf` under LUKS; prod holds verifier's public key as its only peer | encrypted transport for verifier → prod deploy traffic; prod sshd binds only to the tunnel interface |

### Drupal/MariaDB migration policy

Per the discussion that produced this ADR:

- **Default**: every schema change should be either INSTANT/ONLINE on MariaDB 10.11+ OR follow expand-contract.
- **Safe-by-default operations**: adding nullable columns, adding new tables, adding indexes. These run as ONLINE/INSTANT on MariaDB 10.11+.
- **Expand-contract required**: column drops, renames, type narrowing. Two-or-three-deploy patterns.
- **CI canary**: "old code on new schema" job verifies forward-compat by running the previous tagged release against the new schema.
- **Read-only window tolerance**: per [ADR-0013](0013-four-state-deployment-model.md), prod sites are free/non-critical enough to tolerate occasional minute-scale RO windows. This allows pragmatic exceptions for unavoidable non-forward-compat changes.

### Out of scope for this ADR

- Migration of per-site source code to public repos (will be a separate ADR once sanitizer pipeline is proven).
- Migration of production sites from current host to `us-iad` Linode (separate decision; same principle as the GitLab migration but with different data and downtime considerations).
- Multi-region production hosting (deferred until user-geography data justifies it).
- Specific recipes for the sanitizer per-site classifications (will be implementation-time decisions captured in the sanitizer's own documentation).

## Open Questions

To be resolved as implementation proceeds:

- Where does the verifier physically live (same room, different room, different building)?
- Existing per-site sanitization code, or greenfield?
- Site sizes (drives fixture channel sizing).
- Are uploaded files sensitive on per-site deployments (drives whether files need sanitizing too or can ship as-is)?
- Existing Drupal migration history — any non-forward-compat patterns to know about?
- Local LLM on the `ai-host` — already running, planned, or still to set up?

## Review

**30-day review date:** 2026-05-07

**Success criteria for review:**

- [ ] Headscale operational; remote dev via VS Code Remote SSH from authoring workstation to `ci-host` working
- [ ] `ci-host` registered as GitLab Runner; first signed-commit pipeline running
- [ ] (Optional gate) au-mel migration started or sequenced
- [ ] Hardware tokens ordered (lead time on shipping from EU)
- [ ] verifier bootstrap plan documented even if not yet executed

## Related Decisions

- **[ADR-0004](0004-two-tier-secrets-architecture.md)**: Two-tier secrets architecture — preserved; the verifier holds the data tier, build-tier holds the infra tier.
- **[ADR-0005](0005-distributed-contribution-governance.md)**: Distributed contribution governance — applies to all MRs in the new system, especially sanitizer changes.
- **[ADR-0006](0006-contribution-workflow.md)**: Contribution workflow — MR review requirements apply.
- **[ADR-0009](0009-five-layer-yaml-protection.md)**: Five-layer YAML protection — orthogonal but complementary protection layer.
- **[ADR-0013](0013-four-state-deployment-model.md)**: Four-state deployment model — preserved; this ADR refactors what happens at the "prod" step but does not change the dev → stg → live → prod state machine.
