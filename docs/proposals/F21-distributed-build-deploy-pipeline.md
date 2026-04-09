# F21: Distributed Build/Deploy Pipeline (mmt build, mons deploy)

**Status:** IN PROGRESS (Phases 1 ✅, 2 ✅, 3a ✅ complete; Phase 10 dry-run skeleton landed; phases 3, 4, 5–9, 11–13 outstanding)
**Created:** 2026-04-08
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** High (security architecture; gates open-source release)
**Depends On:** F17 (Project Separation), F18 (Unified Backup Strategy)
**Breaking Changes:** Yes — changes how production deploys happen (managed via phased rollout)
**Estimated Effort:** ~13 phases, multi-week buildout
**Architecture decision record:** [`docs/decisions/0017-distributed-build-deploy-pipeline.md`](../decisions/0017-distributed-build-deploy-pipeline.md)

> **Why this proposal exists.** ADR-0017 captures the architectural *decision*
> behind a distributed build/deploy pipeline. This proposal is the
> *implementation plan* — a phased, numbered work breakdown that can be
> tracked in the roadmap, milestone'd as phases complete, and pointed at by
> code references. The ADR is the "why"; F21 is the "what to build, in what
> order, and how to know each phase is done."
>
> The two documents are kept separate on purpose: ADRs record decisions and
> rationale and are not meant to drift; proposals carry checkboxes, phase
> status, and success criteria, and must be updated as work lands.

---

## 1. Executive Summary

NWP currently builds, tests, and deploys from a single machine that also runs
AI agents (Claude, local LLMs). Production credentials, AI tooling, and
unsanitized data all share one trust domain. As AI takes a larger share of
day-to-day code authoring, this single-tier model becomes the dominant
risk in NWP's threat model.

F21 implements the distributed pipeline described in ADR-0017:

1. **mmt** (met + mini) does build/test/lint on home hardware.
2. **mons** is a separate AI-free machine that holds prod SSH keys on a
   hardware token, verifies signed artifacts, and is the **only** thing that
   touches production.
3. **`git.nwpcode.org`** moves from Newark to `au-mel` for sub-10 ms RTT to
   home development machines.
4. **Production sites** are hosted in `us-iad` for east-coast US user
   proximity.
5. **Blue-green deploys** with shared DB and forward-compatible migrations
   replace in-place overwrite.
6. **Sanitizer-on-prod** publishes PII-stripped fixtures via the GitLab
   Packages API for use as the realistic CI test substrate.

The single load-bearing property is: **trust flows through cryptographic
signatures, not through machines.** AI machines are productive but not
trusted; the git server is available but not trusted; CI runners are fast
but not trusted; mons is trusted only because the things it accepts must
be signed by a key the operator controls offline, and the things it does
require a hardware token touch.

This proposal does not duplicate ADR-0017's threat-model discussion.
Read ADR-0017 first; this document handles the phasing, the success
criteria, and the affected NWP scripts.

---

## 2. Goals & Non-Goals

### Goals

- **Air-gap AI from production.** No machine that runs AI can deploy.
- **Sub-10 ms RTT** to the git server from home development machines.
- **Realistic CI tests** running against sanitized clones of production data.
- **Blue-green deploy** with validation before any user-visible swap.
- **Hardware-backed prod credentials.** Solo 2C+ tokens with PIN + touch.
- **Open-source-ready codebase.** Clean PII boundary so site source code
  (avc, ss, dir1, etc.) can eventually be published without leaking user
  data. NWP itself does not own those sites — they live in their own
  per-project proposals — but F21 builds the boundary they need.
- **Self-hosted, open-source tooling end-to-end.** Headscale instead of
  Tailscale, minisign instead of cosign, Gotify instead of Pushover, local
  LLM on mini.

### Non-Goals

- **Multi-region production hosting.** Deferred until user-geography data
  justifies the cost.
- **Public release of any specific site source code.** That is a separate
  decision per site.
- **Replacing the four-state deployment model** (dev → stg → live → prod
  per ADR-0013). F21 refactors what happens at the "prod" step; the
  upstream state machine is unchanged.

---

## 3. Architecture Summary

The full actor roster, key separation, threat model, and rationale for
each tool choice live in
[`docs/decisions/0017-distributed-build-deploy-pipeline.md`](../decisions/0017-distributed-build-deploy-pipeline.md).
A condensed view:

| Name | Role | AI? | Touches prod? |
|---|---|---|---|
| **dev workstation** | interactive editor (often via Remote SSH to met) | yes | no |
| **met** (Ryzen 9 3900X) | always-on home compute, primary build/test runner | yes | no |
| **mini** (Beelink Ryzen AI Max+ 395) | always-on home AI agent, second runner, alerting | yes | no |
| **mmt** | met + mini together — the build/test team | yes collectively | no |
| **mons** | separate laptop, runs `pl` deploy commands, holds prod keys on hardware token | **no AI** | **yes — only one** |
| **`git.nwpcode.org`** | self-hosted GitLab in `au-mel`; transports code/fixtures/audit | n/a | indirectly |
| **prod servers** | `us-iad` Linode hosting site code; runs sanitizer daily | n/a | self |

```
authoring on met → signed git push → git.nwpcode.org (au-mel)
   → mmt CI: verify-signatures, lint, build, test, sign-artifact, upload
   → human approves with offline release-tag signing key
   → mons polls registry, fetches artifact + signature
   → mons verifies signature against locally-held public key
   → mons touches Solo 2C+ for prod SSH
   → mons unpacks to test.prod.site, runs forward-compat migrations
   → mons validates against test slot
   → mons acquires brief RO lock, atomic symlink swap, releases
   → mons writes signed deploy audit to git.nwpcode.org

Independently, daily on prod:
   nwp-publish-fixture → scrub DB → PII regex sweep → minisign → upload
   → mmt CI uses latest published fixture as test substrate
```

---

## 4. Phased Implementation

The 14 phases below mirror the implementation notes in ADR-0017. They are
sequenced so phases 1 through 4 (including the user-space-only Phase 3a)
are reversible — no hardware tokens, no mons, nothing outside of `rob`'s
home directory on the affected machines. Phases 5–8 require hardware
tokens and mons to exist, phase 9 is the first "moment of truth" where
the whole pipeline runs end-to-end, and phases 10–13 are stabilization,
rollout, and hardening.

### Phase 1 — External access foundation *(reversible)* ✅ COMPLETE (2026-04-09)

**Goal:** Headscale-based VPN for mmt, with mons explicitly excluded.

1. ~~Provision Headscale on the `au-mel` Linode~~ → Installed on Newark
   (97.107.137.88) alongside GitLab. au-mel migration dropped (latency
   gain not worth the cost; no new Linode needed).
2. Install Tailscale clients on `met`, `mini`, and the dev workstation. ✅
3. Define Headscale ACLs that grant the three machines reach to each other
   and to `git.nwpcode.org`. ✅ (permissive ACL; only mmt nodes exist)
4. Verify VS Code Remote SSH from the dev workstation → `met` works over
   the overlay. ✅
5. Document recovery: how to add a new client, how to revoke a device. (pending — `docs/guides/headscale.md`)

**Completion notes:** Headscale 0.28.0 on port 8085, TLS via GitLab's
bundled nginx at `https://hs.nwpcode.org`. Three nodes: dev (100.64.0.1),
mini (100.64.0.2), met (100.64.0.3). Direct LAN connections <5ms.
MagicDNS base domain `nwp.headscale`. $0 incremental cost.

### Phase 2 — First runner *(reversible)* ✅ COMPLETE (2026-04-09)

**Goal:** Metabox registered as GitLab Runner; first signed-commit pipeline.

1. Install GitLab Runner on `met`, registered against the existing GitLab
   instance. ✅ (GitLab Runner 18.10.1, shell executor, tags: shell,linux,nwp,met)
2. ~~Configure the runner to verify signed commits before running anything.~~
   → Deferred. `verify-signature` stage added as placeholder with
   `allow_failure: true` until commit signing is configured on the dev
   workstation.
3. Implement a pilot pipeline (lint + build + test) for one NWP-managed
   project. ✅ (`nwp/nwp` — lint:bash, test:unit, test:integration all pass)
4. Capture runner credentials in the infra tier of NWP secrets (per
   ADR-0004). (pending — runner token in GitLab, not yet in `.secrets.yml`)

**Completion notes:** Runner online and idle in GitLab. Pipeline 186:
verify-signature, lint:bash, test:unit, test:integration all pass on
met-shell. Pre-existing CI validation errors in `.gitlab-ci.yml` fixed
(inline comments in script arrays, `only:` mixed with `rules:`, unquoted
colons). Signing gate deferred to a follow-up commit.

### Phase 3 — Second runner + artifact pipeline *(reversible)*

**Goal:** Beelink as second runner; artifacts produced and signed.

1. Install GitLab Runner on `mini`, registered as a second runner.
2. Add a `build-artifact` stage to the pilot pipeline.
3. Add a `minisign-artifact` stage that signs artifacts with the runner
   artifact-signing key.
4. Push signed artifacts to the GitLab Package Registry.

**Success:** A signed pipeline run produces a signed artifact in the
package registry. Unsigned commits are rejected.

### Phase 3a — mini as local-LLM agent *(reversible)* — ✅ COMPLETE (2026-04-08)

**Status:** Landed 2026-04-08. All nine steps below are done, the
reboot gate criterion passed, and the on-mini state has been persisted
into the nwp repo under `servers/mini/systemd/` and
`servers/mini/bin/ollama-health-check` (commit `7580ea3`). The
diagnostic side of the work — `pl mini llm health`
(`scripts/commands/mini.sh`) and the 5-minute systemd user timer
`ollama-health.timer` — shipped in the same commit. The §8 open
question "Local LLM on Beelink" is closed.

**Goal:** Stand up a persistent, GPU-accelerated local LLM on mini so
that downstream phases (Phase 10's AI-fix loop, Phase 12's alerting) and
dependent proposals (X02 voice agent, F14 provider switching) have a
known-good substrate to build on.

This phase is slotted between Phase 3 (mini as a GitLab runner) and
Phase 4 (GitLab migration) because it needs mini to exist and to be
reachable from mmt over the overlay, but it does not depend on the
au-mel migration. It is fully reversible — every change is in user-space
under `~rob`, no system packages are installed, and no daemon is exposed
beyond loopback.

The detailed how-to lives in
[`docs/guides/local-llm.md`](../guides/local-llm.md). This phase is the
**deployment plan**: what gets installed, what success looks like, and
what the rest of the F21 pipeline can assume about mini afterward.

1. Install ollama in user-space on mini (`~/.local/bin/ollama`, no sudo
   for the binary itself). Pin: 0.20.3 as of 2026-04-08.
2. Run `sudo loginctl enable-linger rob` once on mini. This is the only
   sudo step in the phase. It allows user-level systemd units to start
   at boot without an interactive login.
3. Write a systemd user unit at `~/.config/systemd/user/ollama.service`
   that runs `ollama serve`, restarts on failure, and pins three
   environment variables:
   - `OLLAMA_HOST=127.0.0.1:11434` — loopback only, never exposed to
     the LAN.
   - `OLLAMA_VULKAN=1` — enable Vulkan via Mesa RADV against the Radeon
     8060S iGPU. This is the only working acceleration path on Strix
     Halo; ROCm is not supported on this APU.
   - `OLLAMA_CONTEXT_LENGTH=8192` — see the 111 GiB footgun note below.
4. `systemctl --user daemon-reload && systemctl --user enable --now
   ollama.service`. Verify with `systemctl --user status ollama.service`
   and `journalctl --user -u ollama.service`.
5. Pull the two baseline models, both Q4_K_M:
   - `llama3.1:8b` (4.9 GB on disk) — chat, triage, fast Q&A. Default
     for non-code tasks.
   - `qwen2.5-coder:14b` (9.0 GB on disk) — code generation, code
     review, the agent role for Phase 10's AI-fix loop. Default for
     code tasks.
6. Benchmark each model under Vulkan against a fixed prompt of 100+
   output tokens. Acceptance: `llama3.1:8b` ≥ 25 tok/s eval,
   `qwen2.5-coder:14b` ≥ 20 tok/s eval. As of 2026-04-08 the actual
   numbers are 44.72 tok/s and 24.86 tok/s respectively, so this leaves
   comfortable headroom and matches X02 Phase 0's preflight criterion.
7. Verify two-model coexistence by querying both models in succession,
   then checking `free -h`. Combined `size_vram` reports come to ~17 GB,
   but actual physical RAM consumed is far smaller — Linux mmaps the
   model files from disk, so `size_vram` is virtual mapping, not pinned
   residency. On the current 32 GB SKU, real physical use is ~5–6 GiB
   with both models loaded, leaving ~25 GiB free.
8. Reboot mini and confirm the daemon comes back without intervention.
   Confirm both models still respond. **The reboot test is the gate** —
   anything that does not survive a clean reboot does not count as
   deployed.
9. Document the endpoint and capability map for downstream phases:
   - URL: `http://127.0.0.1:11434` (loopback on mini); reachable from
     met or the dev workstation only over the Headscale overlay
     (Phase 1) — never publicly, never via the home LAN outside the
     overlay.
   - Models registered: `llama3.1:8b`, `qwen2.5-coder:14b`.
   - No `pl llm` CLI surface yet — deferred until the agent role
     stabilises after Phase 10, so the CLI does not have to be rewritten
     once the real usage pattern is known.

**The 111 GiB footgun.** Vulkan on Strix Halo reports a device-local
heap of ~111 GiB. This is the GTT region the iGPU can address in unified
memory, **not** real fast memory. Without `OLLAMA_CONTEXT_LENGTH` pinned,
ollama auto-sizes the context window from that fake heap and tries to
allocate a 262144-token window — load time blows up and the daemon may
fail outright. The 8192 pin in the unit file fixes this; per-request
`num_ctx` can still override on a call-by-call basis. Physical RAM is
the real constraint, not the Vulkan-reported heap.

**RAM upgrade path.** The current Beelink 395 SKU is 32 GB, chosen
because the iGPU was meant to handle LLMs on its own and the 32 GB SKU
is significantly cheaper. Phase 3a is sized for 32 GB and verified to
fit two coexisting Q4_K_M models with margin. The chassis supports
larger SKUs; if downstream workloads (X02's STT+LLM+TTS chain, larger
coder models, embeddings stores) need more headroom, the upgrade is in
scope and Phase 3a does **not** hard-code 32 GB as a ceiling. The
"raise the SKU" lever is an explicit, expected option, not an
emergency.

**Reversibility.** Everything is in user-space. To roll back:
`systemctl --user disable --now ollama.service`, then
`rm -rf ~/.config/systemd/user/ollama.service ~/.local/bin/ollama
~/.ollama/`. The `enable-linger` flag can be left or undone with
`sudo loginctl disable-linger rob`. Nothing on mini outside `rob`'s
home directory is touched.

**Success:**
- ollama daemon survives a clean reboot, running under user-level
  systemd with linger.
- Endpoint is reachable from met over the Headscale overlay (after
  Phase 1) and **not** reachable from the public internet or the home
  LAN outside the overlay.
- `llama3.1:8b` sustains ≥ 25 tok/s eval rate on Vulkan;
  `qwen2.5-coder:14b` sustains ≥ 20 tok/s.
- Both models can be loaded together on the current 32 GB SKU and
  remain responsive.
- The "Local LLM on Beelink" item in § 8 is closed.
- [`docs/guides/local-llm.md`](../guides/local-llm.md) and X02
  Phase 0's preflight criteria are satisfied with no further work
  required on mini.

### Phase 4 — GitLab migration Newark → au-mel *(reversible)*

**Goal:** Reduce home → git RTT from ~297 ms to ~5 ms by relocating
`git.nwpcode.org` to a Linode in Melbourne.

This is the only F21 phase that touches existing prod-adjacent
infrastructure (the GitLab instance itself). It is reversible — the
Newark instance is held running through the entire soak period, and
DNS can be flipped back at any point until decommission.

1. Provision a new Linode in `au-mel` sized at least to match the
   current Newark instance. Harden the host: SSH key-only, fail2ban,
   ufw, automatic security updates, the same baseline applied to every
   NWP-managed server.
2. Install the **same** GitLab CE version that runs on Newark — version
   match is required for backup/restore compatibility.
3. At least 24 hours before the cutover window, lower the DNS TTL on
   `git.nwpcode.org` to 300 s so the eventual flip propagates fast.
4. Open a maintenance window. On Newark, stop background jobs
   (`gitlab-ctl stop sidekiq puma`) and take a full backup with
   `gitlab-backup create`. Capture `/etc/gitlab/gitlab-secrets.json`
   and `/etc/gitlab/gitlab.rb` alongside the backup tarball — the
   secrets file is **not** included in `gitlab-backup` output and is
   required for the restore to succeed.
5. Transfer the backup bundle to the au-mel host over the existing
   Headscale overlay (Phase 1), never over the public internet
   unencrypted.
6. Restore on au-mel: drop the secrets and config in place,
   `gitlab-ctl reconfigure`, `gitlab-backup restore`, `gitlab-ctl
   restart`. Smoke test from a Headscale client: clone over SSH, push
   a no-op commit, fetch a package from the registry.
7. Update DNS for `git.nwpcode.org` to point at the au-mel IP.
8. Re-register the `met` and `mini` GitLab Runners against the new
   instance. (Runner registration tokens captured in the backup may
   continue to work — verify before assuming, and rotate if anything
   looks off.)
9. Verify: home → `git.nwpcode.org` ping is < 15 ms; a full pilot
   pipeline (Phase 2 / Phase 3) runs green end-to-end on the new
   instance; package registry fetches succeed.
10. Soak for 7 days. Newark stays running but receives no new pushes.
    Watch for: stale-DNS clients still hitting Newark, runner
    connectivity gaps, CI failures that only show up under real load,
    package fetches that resolve to the wrong IP.
11. After 7 consecutive days with zero Newark traffic, destroy the
    Newark Linode and restore the DNS TTL to its normal value.

**Success:** Home → `git.nwpcode.org` ping is < 15 ms; runners on met
and mini have re-registered against au-mel; no Newark traffic for 7
consecutive days; Newark Linode destroyed; DNS TTL restored.

### Phase 5 — mons bootstrap *(requires hardware tokens)*

**Goal:** Provision the `mons` machine and prepare it for prod deploys.

1. Acquire mons hardware (separate laptop, will not run AI).
2. Provision from clean media with LUKS full-disk encryption.
3. Install only what's needed: `pl`, ssh client, WireGuard, minisign.
   **No AI tooling, no language servers that call out, nothing speculative.**
4. Acquire 2× Solo 2C+ NFC Security Keys (daily + offsite backup).
5. Enroll a resident `ed25519-sk` key on each Solo 2C+ with `verify-required`
   (PIN) and `resident` (key-on-token) flags.
6. Bake the deploy-approval public key into the mons image.
7. Configure on-demand cellular connectivity (dedicated cellular modem
   preferred over phone tethering — keeps general-purpose-phone attack
   surface out of the deploy path).
8. Generate mons's WireGuard keypair under LUKS-protected root.
9. Configure prod with mons's public key as its **only** WireGuard peer.
10. Rebind prod `sshd` to the WireGuard tunnel interface only; close the
    public SSH port.
11. End-to-end tunnel test from a clean cold boot.
12. First manual deploy of a pilot site through the full mons-mediated
    flow (no automation yet — just prove the path works).

**Success:** mons can deploy a single pilot site through hardware-token
SSH; prod is unreachable on its public SSH port from the open internet;
the mons↔prod path is the only way in.

### Phase 6 — Sanitizer v0 *(security-critical)*

**Goal:** A sanitizer that can scrub one production site safely enough to
publish its output.

The first target site is chosen by whichever site project owns
the production data and is willing to be the first canary. F21 does not
choose the site; it builds the framework.

1. Design the sanitizer's classification model: per-table rules covering
   "drop entirely", "hash with deterministic salt", "regenerate with
   faker", "leave as-is".
2. Implement per-table strategies for the chosen pilot site.
3. Build a sanitizer test suite that exercises each strategy on
   synthetic input and verifies the output contains no input PII.
4. Implement an output regex sweep that runs after sanitization and
   refuses to publish anything that matches PII patterns (emails, phone
   numbers, common name patterns, plausible passwords).
5. Run the first sanitized snapshot through manual review by a human
   before any automated publication.
6. Document the sanitizer's threat model: it runs on prod, it never
   transfers raw data off prod, its code lives in NWP and follows the
   "AI may propose, human MUST review" merge rule.

**Success:** A sanitized snapshot of the pilot site exists, has been
manually verified to contain no PII, and the sanitizer is reproducible.

### Phase 7 — Fixture publication channel

**Goal:** mmt CI consumes sanitized fixtures from prod automatically.

1. Provision a `write_package_registry`-only deploy token on prod for
   sanitizer output.
2. Implement `nwp-publish-fixture` as a systemd timer on prod: scrub →
   sweep → minisign → POST to GitLab Packages API.
3. Set the timer cadence (default: daily; can be on-demand for testing).
4. Update mmt CI to fetch the latest published fixture as its test
   substrate, verifying minisign signature before use.
5. Add CI failure modes for "no recent fixture", "signature mismatch",
   "fixture older than threshold".

**Success:** mmt CI runs against a sanitized fixture every pipeline; no
test ever runs against invented fixture data again.

### Phase 8 — Blue-green slot mechanism

**Goal:** Per-site `prod.site` and `test.prod.site` slots with shared DB
and forward-compatible migrations.

1. Implement the slot directory layout on prod (symlink + shared files
   dir + shared DB).
2. Implement the swap script: brief RO lock → atomic symlink swap →
   release lock → smoke test.
3. Implement forward-compat migration runner that can apply migrations
   to the shared DB without breaking the still-live previous slot.
4. Codify the migration discipline (expand-contract default; INSTANT/ONLINE
   acceptable; brief RO window only for unavoidable exclusive-lock changes
   per ADR-0013).
5. Wire `pl` so the existing `stg2live` and `live2stg` paths can target
   the new slot mechanism behind a feature flag.

**Success:** A site can be deployed to its `test.prod.site` slot,
validated against live DB, and swapped to `prod.site` atomically. Roll
back is symmetric.

### Phase 9 — End-to-end blue-green deploy *(moment of truth)*

**Goal:** First pilot site running through the full pipeline end to end.

1. Signed commit on met
2. → mmt CI runs against the latest sanitized fixture
3. → CI uploads a signed artifact to the package registry
4. → human signs the release tag with the offline approval key
5. → mons boots, connects via cellular, brings up `wg0` to prod
6. → mons fetches artifact over public HTTPS, verifies minisign signature
7. → mons SSHes to prod through the tunnel (Solo 2C+ touch required)
8. → mons unpacks to `test.prod.site`
9. → forward-compat migrate against shared DB
10. → mons runs validation suite against test slot
11. → mons acquires brief RO lock, swaps symlinks, releases
12. → mons runs post-swap smoke test
13. → mons writes a signed deploy audit record back to `git.nwpcode.org`
14. → `wg-quick down wg0`, mons powered off

**Success:** Every step above is automated; the first end-to-end deploy
of the pilot site through this flow leaves prod healthy and produces an
audit record. A deliberate fault injection at any step is caught before
it reaches users.

### Phase 10 — Bug-report and AI-fix loop

**Goal:** mons reports failures in a structured form; mini's local LLM
proposes fixes; the loop closes on a deliberate drill.

**Skeleton landed 2026-04-08 (commit `b716ac9`):** an inert, dry-run-only
poller now lives at `servers/mini/bot/` with a hard-default `dry_run:
true`, a static `repos.allowlist: [mayo/mayo]`, prompt-injection-defence
delimiters around untrusted issue bodies and repo files, 13 unit tests
for diff parsing and prompt framing, and a five-item checklist that
must be satisfied before `dry_run: false` is considered. The skeleton
refuses to start if the flag is flipped without the live apply/push/MR
code being written. See `servers/mini/bot/README.md` for the full
operational policy. The skeleton is not yet wired to anything — the
mayo issue channel (step 1) does not exist, so the poller has no input.

1. Standardize mons failure reports as signed JSON pushed to a dedicated
   repo on `git.nwpcode.org`. *(Blocked: mons does not exist yet;
   waits on Phase 5.)*
2. Subscribe mini's local LLM to the failure report stream.
   *(Plumbing in place via `servers/mini/bot/poll.py`; waits on step 1
   for real input.)*
3. Implement the AI-fix proposal flow: mini drafts an MR, mmt CI runs
   it, human reviews and merges if appropriate. *(Dry-run half is
   ready; the live apply/branch/push/MR code is intentionally
   unimplemented.)*
4. Run a deliberate fault-injection drill (e.g. break a migration on
   purpose) to exercise the loop end to end. *(Blocked on steps 1–3.)*

**Success:** A deliberately broken commit triggers the failure path, the
local LLM produces a plausible fix MR, and the human reviewer can decide
in under five minutes.

### Phase 11 — Per-site rollout

**Goal:** Roll out phases 6–10 to additional sites beyond the pilot.

The roster of sites to roll out, and their order, lives in each
site's own project documentation (e.g.
`sites/avc/docs/proposals/`, `sites/ss/docs/proposals/`,
`sites/dir1/docs/proposals/`). F21 provides the framework; the per-site
proposals decide when each site adopts it.

**Success:** Every production site lives behind blue-green deploys with
sanitized fixtures and signed artifacts.

### Phase 12 — mini alerting + Claude escalation

**Goal:** Layered alerting with hard severity floors that AI cannot
downgrade.

1. Ship logs from prod, mons, mmt to mini.
2. Implement a rules engine with severity levels (INFO/WARN/ERROR/CRITICAL/SECURITY).
3. Implement hard floors: SECURITY-level events cannot be suppressed by
   any AI agent under any circumstance.
4. Wire push notifications via self-hosted Gotify.
5. Define the SECURITY-level Claude auto-engagement protocol: when does
   the system page a human, when does it call Claude.

**Success:** A simulated SECURITY-level event reaches the operator on
their phone within seconds; AI cannot be coaxed into dropping it.

### Phase 13 — Hardening + tabletop review

**Goal:** Runbooks for the failure modes that matter and a tabletop
walkthrough of each.

Runbooks to write:

- **mons down** (broken hardware, lost laptop)
- **token lost** (one Solo 2C+ stolen, the other still in offsite storage)
- **sanitizer false negative** (PII published; how do we contain, recall,
  and post-mortem)
- **`git.nwpcode.org` compromised** (transport compromised; signature
  trust unchanged; how do we verify and restore)
- **prod compromised through some path other than mons** (do we even know?)
- **AI prompt injection during a build** (CI catches it; what if it didn't?)

**Success:** Every runbook has been walked through at least once by the
human operator. Each tabletop produces at least one improvement to the
runbook or the architecture.

---

## 5. Affected NWP Scripts

The components below are added to or modified in NWP itself by F21.
Site-specific work (sanitizer rules per table, per-site slot config) lives
in each site's own project, not here.

### 5.1 New Scripts

| Path | Purpose |
|---|---|
| `scripts/commands/deploy.sh` | mons-side deploy entrypoint: fetch artifact, verify signature, run blue-green swap |
| `scripts/commands/sanitizer.sh` | Run-on-prod sanitizer driver; per-site rules loaded from each site's project dir |
| `scripts/commands/audit.sh` | Push signed deploy audit records back to `git.nwpcode.org` |
| `scripts/helpers/verify-artifact.sh` | minisign verification helper used by mons |
| `scripts/helpers/swap-slots.sh` | Atomic blue-green symlink swap with brief RO lock |
| `lib/wireguard.sh` | mons-only helpers for `wg-quick up/down wg0` plus ping checks |
| `lib/sanitizer.sh` | Shared sanitizer plumbing (table classification framework, regex sweep) |

### 5.2 Modified Scripts

| Path | Change |
|---|---|
| `scripts/commands/stg2live.sh` | Add a path that produces a signed artifact instead of running an in-place deploy |
| `scripts/commands/live2stg.sh` | Same |
| `lib/ssh.sh` | Add support for hardware-token (`-o IdentitiesOnly=yes` already lands via P59; F21 adds Solo 2C+ resident-key handling) |
| `lib/state.sh` | Read and emit deploy audit records |
| `pl` | New top-level subcommands `pl deploy`, `pl audit`, `pl sanitizer` |

### 5.3 New Configuration

| Path | Purpose |
|---|---|
| `servers/<name>/.nwp-server.yml` | Extended with `deploy.slots.{prod,test_prod}` paths and `wireguard.peer_key` |
| `~/nwp/.mons.yml` | Mons-only local config (artifact registry URL, public key fingerprints, tunnel config). Gitignored. |

---

## 6. Risk Assessment

### High Risk

| Risk | Mitigation |
|---|---|
| Sanitizer false negative publishes PII | Output regex sweep; human review of first N snapshots; "AI may propose, human MUST review" rule on sanitizer code; tabletop drill in Phase 13 |
| mons hardware loss / theft | LUKS full-disk encryption; offsite backup Solo 2C+; documented bootstrap drill |
| Hardware token shipping delay | Order tokens in Phase 1, not Phase 5 — they have weeks of lead time from EU |
| Blue-green migration breaks live slot | Forward-compat-by-default; CI canary "old code on new schema"; expand-contract pattern; brief RO window tolerance per ADR-0013 |

### Medium Risk

| Risk | Mitigation |
|---|---|
| Dev workstation latency to met during Phase 1 | Headscale + Tailscale clients are mature; Remote SSH dev experience is well-trodden |
| GitLab migration window (Phase 4) | Sequenced under its own plan; soak period before cutover; Newark instance kept running until 7 days clean |
| Cellular connectivity unreliable on deploy day | Deploys can wait; phone tethering as fallback; documented "deploy from anywhere with cellular" property |
| Adding a new runner introduces a supply-chain risk | GitLab Runner is widely deployed; both runners are home hardware under operator control; signed-commit verification gates everything |

### Low Risk

| Risk | Mitigation |
|---|---|
| Solo 2C+ firmware bug | Open-source firmware; two units; can fall back to manual key file briefly during incident |
| Headscale crash | Self-hosted; one operator; restart is quick; mmt work continues over LAN |

---

## 7. Success Criteria

Top-level success criteria for F21 as a whole. Per-phase criteria are
in the phase definitions in Section 4.

- [ ] AI agents have **no** path to production SSH credentials
- [ ] Every prod deploy passes through mons and is recorded as a signed
      audit record on `git.nwpcode.org`
- [ ] Every prod deploy requires a Solo 2C+ touch
- [ ] CI runs against a sanitized fixture from real production data, never
      against invented fixtures
- [ ] Sanitizer output passes a regex PII sweep before publication
- [ ] Sanitizer code is on the "AI may propose, human MUST review" list
- [ ] Home → `git.nwpcode.org` ping < 15 ms
- [ ] First pilot site has been deployed end-to-end through the full
      pipeline at least once with no human intervention beyond the
      release-tag signature and Solo 2C+ touch
- [ ] Runbooks exist for "mons down", "token lost", "sanitizer false
      negative", "`git.nwpcode.org` compromised", and have been walked
      through by the operator
- [ ] All tooling is open source and self-hosted (Headscale, minisign,
      Gotify, GitLab CE, local LLM)

---

## 8. Open Questions

Carried over from ADR-0017 § "Open Questions" — to be resolved as
implementation proceeds and recorded back into the ADR when settled:

- Where does mons physically live (same room, different room, different
  building)?
- Greenfield sanitizer or carry forward existing per-site sanitization
  code?
- Site sizes (drives fixture channel sizing).
- Are uploaded files sensitive enough to need sanitizing too, or can
  they ship as-is?
- Existing Drupal migration history — any non-forward-compat patterns
  to know about?

**Resolved 2026-04-08:**

- ~~Local LLM on Beelink — already running, planned, or still to set
  up?~~ Closed by Phase 3a. Running under user-level systemd with
  linger as of 2026-04-08; `llama3.1:8b` and `qwen2.5-coder:14b` both
  resident on Vulkan, baseline numbers captured in
  [`docs/guides/local-llm.md`](../guides/local-llm.md).

---

## 9. Out of Scope

Same as ADR-0017 § "Out of scope":

- Migration of any specific site's source code to public repos
- Migration of production sites from current hosts to `us-iad` Linode
  (separate decision per site)
- Multi-region production hosting
- Per-site sanitizer rules (those live in each site's own proposals)

---

## 10. Cross-references

- **[ADR-0017](../decisions/0017-distributed-build-deploy-pipeline.md)** —
  the architecture decision record this proposal implements.
- **[ADR-0004](../decisions/0004-two-tier-secrets-architecture.md)** —
  Two-tier secrets; preserved unchanged.
- **[ADR-0013](../decisions/0013-four-state-deployment-model.md)** —
  Four-state deployment; preserved unchanged.
- **F17 (Project Separation)** — F21 depends on the per-site config layer
  F17 introduced; mons identifies sites by their `sites/<name>/.nwp.yml`.
- **F18 (Unified Backup)** — F21 audit records and mons-side state get
  backed up via F18's restic strategy.
- **P59 (SSH IdentitiesOnly hardening)** — already complete; F21 builds on
  it for hardware-token SSH.
