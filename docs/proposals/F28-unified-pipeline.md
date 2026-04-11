## F28: Unified Pipeline — mmt → mons → prod Signed-Artifact Handoff

**Status:** PROPOSED
**Created:** 2026-04-12
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** High (formal successor to F24 Phase 3; unblocks prod deploys under ADR-0017)
**Depends On:** F21 Phase 2 (met runner) ✅, F21 Phase 5 (mons bootstrap — tooling complete, hardware token pending), ADR-0019 (mons posture), F23 (site layout) ✅
**Breaking Changes:** Yes — replaces the deleted legacy `deploy:staging` / `deploy:production` CI stages (see commits `24baecd`, `05d181a`, `4bb1264`)
**Estimated Effort:** Large — this is the load-bearing spine of the distributed pipeline; phased over weeks

---

## 1. Executive Summary

### 1.1 Problem statement

As of commit `faf98b6`, NWP no longer has a deploy path in CI. The
legacy `deploy:staging` / `deploy:production` jobs were deleted
(F24 Phase 3 Step 1) because they violated ADR-0017's trust model
— they ran on CI runners that were AI-accessible, with SSH keys
that could reach prod. The fix was to remove them now, before they
were used under the new threat model, rather than leave a wired-up
footgun in the tree.

That deletion was *necessary and sufficient* to stop the old path
from being accidentally used, but it leaves NWP with a concrete
gap:

- `build` still runs on met (under composer.json gating) and
  produces artifacts.
- There is no path from those artifacts to prod.
- mons exists, has WireGuard configs, has a minisign library, and
  is documented in `docs/guides/mons-operations.md` — but has no
  CI-side counterpart that actually produces the signed bundles
  mons knows how to consume.

F28 is the formal design for that missing spine. It absorbs what
F24 Phase 3 would have been if it had specified the *replacement*
rather than just the *deletion*.

### 1.2 Proposed solution

A three-hop pipeline where the only trust-inversion happens
**between** hops, not within them:

```
       (AI-accessible tier)               (human tier, hardware-token-gated)
  ┌─────────────────────────────┐   ┌────────────────────────────┐
  │          mmt                │   │          mons              │
  │ (met + mini, dev, CI)       │   │ (offline-default laptop,    │
  │                             │   │  Solo 2C+, per ADR-0019)   │
  │ build → test → sanitize →  │   │                            │
  │ sign artifact → upload to  │──>│ pull from Packages API →   │
  │ GitLab Packages            │   │ minisign verify → bring up │
  │                             │   │ WireGuard → deploy → tear  │
  │                             │   │ down WireGuard             │
  └─────────────────────────────┘   └────────────────────────────┘
                 │                                │
                 │                                │ WireGuard
                 │                                │ one-to-one tunnel
                 │                                v
                 │                      ┌─────────────────────┐
                 v                      │     prod servers    │
        git.nwpcode.org                 │ (avc, ss, dir1, …)  │
        (GitLab Packages API)           │ sshd bound to       │
        (authority: minisign public     │ WireGuard iface only│
        key on mons, NOT mmt's token)   └─────────────────────┘
```

Key design properties:

1. **mmt never writes to prod.** mmt's only write destination is
   the GitLab Packages API on `git.nwpcode.org`. Its token scope
   is `write_package_registry` on a single package path.
2. **mons never runs CI.** mons has no gitlab-runner, no Claude,
   no local LLM. It runs a single deploy script per invocation,
   driven by human hands.
3. **Trust flows through the minisign signature, not through the
   network.** An artifact is trusted because it verifies against a
   public key held on mons, and the public key was installed at
   bootstrap time, not fetched at deploy time. An attacker who
   compromises `git.nwpcode.org` cannot forge a signature; an
   attacker who intercepts the HTTPS pull cannot forge a signature;
   the only credential-compromise path to prod runs through
   physical theft of the signing key (which lives on mmt under
   LUKS, offline when not in use) AND the Solo 2C+ on mons AND a
   network path to prod. Three factors, three locations, three
   trust tiers.
4. **The deploy *trigger* is a human tap, not a CI event.** When
   mmt finishes a build and uploads a signed bundle, nothing
   happens automatically. mons polls (or is manually run by Rob)
   and surfaces the available bundle; Rob reviews what's being
   deployed, taps the Solo 2C+, and the tunnel comes up. This is
   the inversion of the deleted `deploy:production` job and is the
   whole point of F28.

### 1.3 Relationship to F24, F21, F26, F27, ADR-0017, ADR-0019

- **F24** identified the need and executed the *deletion* half
  (Phase 3 Step 1, merged). F28 is the *construction* half. F24 is
  complete; F28 supersedes it for all forward design work.
- **F21** provides the infrastructure (Headscale, met runner, mons
  bootstrap) that F28 depends on. F28 does not build any new
  infrastructure — it wires together what F21 has already provided.
- **F26 (OIDC)** and **F27 (feedback ingest)** are downstream
  consumers of F28's signed-artifact shape. F27 uses the *same*
  Packages API primitive in the *reverse* direction (prod → mmt).
  F26's per-MR preview provisioning lives entirely on mmt and
  never triggers an F28 deploy, but shares the CI job definitions.
- **ADR-0017** is the trust model F28 implements. If F28 contradicts
  ADR-0017, F28 is wrong.
- **ADR-0019** changes mons's posture from "offline by default" to
  "always-on with hardware-rooted keys". F28 respects both postures
  — the always-on property means mons can *poll* for bundles rather
  than needing Rob to physically open it, but the hardware-token
  gate means every deploy still requires a human tap.

## 2. Goals & Non-Goals

### Goals

- A signed artifact produced by mmt's CI can be deployed to a prod
  site through a single Rob-initiated mons command, with full
  signature verification at every step and no AI agent in the hot
  path.
- The pipeline is *observable*: every build produces a bundle with
  a manifest that says what it contains, which sites it targets,
  which commit it builds from, and who signed it. mons logs every
  verify and every deploy.
- The pipeline is *reversible*: every deploy is a bundle, every
  bundle is addressable, and rolling back is "deploy the previous
  bundle". No in-place mutation of prod state.
- The pipeline is *minimal*: no new services, no new daemons on
  prod, no new SaaS dependencies. Uses only what already exists:
  gitlab-runner on met, GitLab Packages API on `git.nwpcode.org`,
  minisign, WireGuard, OpenSSH, and the pl script.
- The replacement for the deleted `deploy:staging` / `deploy:production`
  stages is **clearly named in the CI config as an F28 reference**
  so that future maintainers know exactly why the slot is empty in
  the template.

### Non-goals

- Not an auto-deploy-on-green pipeline. F28 is designed so that
  green CI is *necessary but not sufficient* for a deploy. The
  sufficient condition is a human tap on mons.
- Not a blue-green deploy system. That's F21 Phase 8 — F28 is the
  *transport layer* that blue-green slots will sit on top of. A
  Phase 8 deploy will still be an F28 bundle; it just happens to
  flip slots as part of the apply step.
- Not a multi-signer system. There is one minisign signing key at
  a time (with one offsite backup). Multi-party signing is a
  future proposal if and when it's needed.
- Not a replacement for F22 (Gotify alerting) or the mons alert
  path. F28 is a deploy channel, not a monitoring channel.

## 3. Architecture

### 3.1 Bundle format

An F28 bundle is a tarball with a fixed layout:

```
nwp-bundle-<site>-<commit>-<ts>.tar.gz
├── manifest.yaml
├── manifest.yaml.minisig
├── payload/
│   ├── code/                # the site's built artifact tree
│   ├── fixtures/            # sanitized fixtures if the deploy
│   │                        # includes a data refresh (see F21
│   │                        # Phase 6 sanitizer contract)
│   └── migrations/          # db migrations to run on deploy
└── scripts/
    ├── pre-deploy.sh        # runs on prod before payload apply
    ├── apply.sh             # idempotent payload apply
    └── post-deploy.sh       # runs on prod after apply (cache
                             # clears, health check, etc.)
```

`manifest.yaml` fields (all required):

- `schema_version` — bumped when the format changes
- `nwp_version` — the `pl` version that built the bundle
- `site` — the target site name (avc, ss, dir1, mayostudios, …)
- `git_commit` — full SHA of the source commit
- `git_branch` — branch name at build time (informational)
- `built_at` — ISO-8601 timestamp
- `built_by` — the mmt host that built it (met typically)
- `signing_key_fingerprint` — minisign public key fingerprint
- `targets` — list of prod hosts the bundle is intended for
- `sha256_payload` — of the `payload/` tree, for local integrity
- `sha256_scripts` — of the `scripts/` tree, for local integrity
- `dependencies` — list of previous bundle ids this one builds on
  (for rollback graph reasoning)

The entire manifest is minisigned. The payload and scripts are
covered indirectly via the manifest's `sha256_*` fields — verifying
the manifest signature and then verifying the sha256s is equivalent
to signing the whole bundle, with the advantage that the manifest
can be read without touching the payload.

### 3.2 The mmt → Packages API upload

`lib/packages-upload.sh` (shared primitive with F27, to be built
once) takes a bundle path + a Packages API URL + a project id +
a package name + a token, and uploads via the Packages API. On
mmt, the token has `write_package_registry` scope on exactly the
bundle-publishing project, and nothing else.

The upload happens as a new `publish:bundle` CI job, replacing
the deleted `deploy:staging` / `deploy:production` slot in
`.gitlab-ci.yml`. This job:

- runs on the met shell runner (`tags: [met, shell]`),
- is gated by `exists: [composer.json]` (so the NWP meta-repo
  doesn't try to publish itself),
- is gated by `rules: if: $CI_COMMIT_BRANCH == "main"` so feature
  branches do not produce prod bundles,
- needs `build` and the sanitize job from F21 Phase 6,
- calls `lib/packages-upload.sh`.

Importantly, the `publish:bundle` job does **not** run on MRs.
F26's preview-deploy flow is a separate path and does not produce
signed bundles — its artifacts live only on met, never go to
`git.nwpcode.org` Packages, and never reach mons.

### 3.3 The mons pull + verify + deploy

`pl deploy` on mons (superseding the placeholder script referenced
in ADR-0019 § Deploy script changes) does, in order:

1. **List available bundles** for a given site by calling the
   GitLab Packages API with a *read-only* token. This token is
   scoped to `read_package_registry` on exactly the bundle
   project. Yes, mons holds a token with read access to Packages
   — this is acceptable because Packages content is already
   signature-verified, and a token leak grants only "can read
   public bundles" which is a no-op against the threat model.
2. **Display the top N bundles** with their manifest summaries
   (commit, date, diff summary if available). Rob picks one.
3. **Download the chosen bundle** over public HTTPS.
4. **Verify the signature** against the pinned minisign public
   key installed on mons at bootstrap time. A verify failure
   **aborts the deploy and posts a Gotify alert**. No retry, no
   fallback, no "maybe the key rotated" path.
5. **Verify the manifest sha256s** against the payload and scripts
   trees. Mismatch aborts.
6. **Print a deploy summary** and require a Solo 2C+ touch:
   `"about to deploy commit abc123 to avc — touch to confirm"`.
7. **Bring up the WireGuard tunnel** to the target prod host.
   The tunnel config is static on mons (installed at bootstrap);
   `wg-quick up` requires a second touch because the WG private
   key is gated behind `pam_u2f` (ADR-0019 alternative to
   on-disk-key).
8. **SSH to prod** over the tunnel, copy the bundle, run
   `scripts/pre-deploy.sh`, `scripts/apply.sh`, and
   `scripts/post-deploy.sh` in order. Every SSH use requires a
   touch.
9. **Tear down the tunnel** on exit (success or failure).
10. **Post a Gotify notification** summarising the deploy: bundle
    id, site, commit, exit status, duration, number of touches.
11. **Log the deploy** to a mons-local append-only audit trail
    that is also shipped via the signed-artifact monitoring path
    to `git.nwpcode.org`.

A deploy failure at any step leaves the tunnel torn down and
prod untouched (pre-deploy, apply, and post-deploy are required
to be idempotent and to fail loudly rather than half-apply —
see § 3.5).

### 3.4 Rollback

Rollback in F28 is just "deploy the previous bundle". Because
bundles are immutable addressable artifacts in the Packages API,
and because `apply.sh` is idempotent by design, rolling back is
operationally identical to rolling forward — the only difference
is which bundle id Rob picks at step 2.

The bundle `dependencies` field in the manifest enables mons to
warn when the chosen rollback target is "too old" (e.g., the user
is trying to roll back across a schema migration). The warning is
advisory; Rob can still proceed with a second touch.

### 3.5 Idempotent apply contract

The F28 contract requires `apply.sh` to satisfy:

- **Safe to re-run.** Running `apply.sh` twice in a row leaves
  prod in the same state as running it once.
- **Fails loud.** Any step that cannot complete exits non-zero
  and writes a marker file on prod that `pre-deploy.sh` checks
  on the next deploy. If the marker is present, the next deploy
  refuses to run until Rob clears it.
- **No partial writes.** Where possible, use atomic file moves
  (`mv` of staged tree into place) rather than in-place edits.

This contract is imposed on site-specific apply logic by convention
and enforced by a pre-upload lint in `publish:bundle`. Sites whose
apply logic cannot satisfy the contract must be refactored before
they can be onboarded to F28.

## 4. Security posture

### 4.1 Key custody

| Key | Location | Custody | Usage |
|---|---|---|---|
| minisign secret (sign bundles) | mmt, LUKS-encrypted home | Rob, passphrase-wrapped | Touched only during `publish:bundle`; CI runner unlocks via a sidecar that requires Rob to have been present in the last N minutes |
| minisign public (verify bundles) | mons, in root-owned file | Pinned at bootstrap | Read by every deploy; never rotated without a full re-bootstrap |
| Packages write token | mmt | In met CI variables, masked | `write_package_registry` scope only |
| Packages read token | mons | In mons secret store | `read_package_registry` scope only |
| Prod SSH key | Solo 2C+ (ed25519-sk) | Hardware token, touch-required | Used once per deploy action |
| WireGuard key | mons, pam_u2f-gated | Touch-required on tunnel up | Used once per deploy |

The minisign secret on mmt is the highest-value key in this system.
Its compromise means an attacker can sign a malicious bundle that
mons will happily deploy. Mitigations:

- It is passphrase-wrapped.
- It is only unlocked when Rob is physically at mmt in a CI-adjacent
  window.
- Publication of a bundle produces a Gotify notification that Rob
  sees on his phone; an unexpected publication is a signal.
- mons logs every verify it performs, and the audit trail is
  shipped to `git.nwpcode.org` as a signed artifact of its own. An
  attacker who forges a bundle also has to silence the mons audit
  trail, which requires compromising mons — two independent
  compromises.

### 4.2 Why mons can hold a read-Packages token

mons's threat model forbids AI, forbids prod-reachable secrets
without hardware gating, and forbids disk-resident credentials for
prod actions. A `read_package_registry` token is none of these —
it can only pull signed artifacts, which mons will verify before
trusting. Compromise of this token by an attacker grants "can
download bundles that I, the attacker, have no way to forge the
signatures for". That is not a useful capability.

### 4.3 What the deleted stages could have done that F28 cannot

The deleted `deploy:staging` / `deploy:production` jobs were
wired for a world where CI is allowed to write to prod. They
held SSH keys in CI variables. An attacker who compromised the
met runner (or tricked a CI variable extraction vulnerability)
could have shelled into prod directly. F28 removes this
capability — there is no path from a compromised met runner to
prod. The deploy decision sits with a human on a machine that
CI cannot reach.

The corresponding *lost* capability is "CI auto-deploys on
green". That capability is not coming back. It was the threat.

### 4.4 Review gates

- Changes to `lib/minisign.sh`, `lib/packages-upload.sh`, the
  `publish:bundle` job, or the `pl deploy` script on mons
  require **2 human approvers** from day one (no single-reviewer
  phase). F28's security is load-bearing and these files are
  the seams.
- Changes to site-specific `pre-deploy.sh` / `apply.sh` /
  `post-deploy.sh` require 1 approver until a given site has
  been deployed via F28 for 30 days, then 2.
- Addition of a new site to F28's target list requires 2
  approvers and a written onboarding note in
  `docs/guides/mons-operations.md`.

## 5. Phases

### Phase 1 — Packages primitive *(reversible, no prod)*

Build `lib/packages-upload.sh` and `lib/packages-download.sh`.
Smoke-test against a throwaway project on `git.nwpcode.org`. No
changes to mons, prod, or CI. This primitive is shared with F27
and is the first thing both proposals consume.

### Phase 2 — Bundle format + signing *(reversible, no prod)*

Build `lib/bundle-build.sh` and `lib/bundle-verify.sh` wrapping
`lib/minisign.sh` (already exists per F21 Phase 5). Test harness
in `t/` that builds a bundle from a fixture site, verifies it,
tampers with a payload file, reverifies, and asserts the second
verify fails. This is the point where the manifest schema
stabilises.

### Phase 3 — `publish:bundle` CI job *(reversible, mmt only)*

Add `publish:bundle` to `.gitlab-ci.yml`, gated on `main` only and
`composer.json` existence. On green build + sanitize, it produces
a bundle and uploads it to the Packages API. Does not touch
mons or prod. Verify by inspecting the uploaded package manually
after the first run.

### Phase 4 — `pl deploy` on mons *(reversible, no prod writes yet)*

Build `pl deploy` on mons to list, download, and verify bundles.
In this phase, the script **stops short of the WireGuard tunnel**
— it prints "would deploy: <summary>" and exits. This lets the
pull + verify flow be exercised end-to-end without touching prod.

### Phase 5 — First real F28 deploy *(pilot site, gated)*

Enable the WireGuard + SSH + apply path on mons for one pilot
site. First real F28 deploy runs against that site. This is the
moment the spine is load-bearing. Require 2 approvers on the
bundle *and* on the PR that enables apply for that site.

### Phase 6 — Rollout to remaining sites *(per-site gates)*

Onboard each remaining site to F28 individually. Each onboarding:

1. Site's `pre-deploy.sh` / `apply.sh` / `post-deploy.sh` reviewed.
2. Site's apply contract lint run in `publish:bundle`.
3. First F28 deploy of the site done with 2 approvers.
4. 30-day bedding-in period before the review gate drops to 1.

### Phase 7 — Deprecate any remaining legacy paths

Any old non-F28 deploy commands (if any survive) are removed. The
placeholder NOTE in `templates/.gitlab-ci.yml` referencing F24
Phase 3 Step 1 is updated to reference F28 directly and the F28
phase table.

## 6. CI skeleton

The `publish:bundle` job, in shape (not final form):

```yaml
publish:bundle:
  stage: publish
  tags: [met, shell]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
      exists: [composer.json]
  needs:
    - job: build
      optional: false
    - job: sanitize
      optional: false
  script:
    - ./lib/bundle-build.sh "$CI_PROJECT_NAME" "$CI_COMMIT_SHA"
    - ./lib/packages-upload.sh
        --project-id "$NWP_BUNDLE_PROJECT_ID"
        --package "nwp-bundles/$CI_PROJECT_NAME"
        --file "dist/nwp-bundle-*.tar.gz"
  variables:
    NWP_BUNDLE_PROJECT_ID: "<set in CI variables>"
  # no artifacts: pipelines do not hand bundles back to GitLab CI;
  # the only consumer is the Packages API, and mons pulls from there
```

## 7. Open questions

- Does the `publish:bundle` job run on every main commit, or only
  on tagged commits? **Proposed: every main commit, but mons
  displays tagged bundles more prominently. Untagged bundles are
  deployable but Rob has to explicitly ask for them.**
- Does mons poll the Packages API, or is `pl deploy` always
  manually invoked? **Proposed: manually invoked in Phase 4 and
  Phase 5 so the flow is exercised by humans end-to-end. Polling
  can be added as a convenience in a later phase if it proves
  useful.**
- Should F28 bundles include the sanitized dev fixtures used to
  test the build, for audit purposes? **Proposed: no — sanitized
  fixtures are a separate artifact type shipped via the F21 Phase
  6 fixture channel. F28 bundles are deploy-only.**
- How does F28 handle a multi-site atomic deploy (e.g., AVC + SS
  change that must land together per F26)? **Proposed: atomicity
  is not a transport-layer concern. Two bundles are built, two
  deploys are executed in a defined order, and if the second
  fails, the first is rolled back via its previous bundle id.
  Operators coordinate; the pipeline does not.**

## 8. References

- [ADR-0017](../decisions/0017-distributed-build-deploy-pipeline.md) — trust boundaries
- [ADR-0019](../decisions/0019-mons-always-on-hardware-rooted-keys.md) — mons posture + deploy client forms
- [F21](F21-distributed-build-deploy-pipeline.md) — infrastructure (Headscale, met runner, mons bootstrap, sanitizer)
- [F24](F24-relocate-dev-tree-to-met.md) — F28 supersedes its Phase 3 for forward design
- [F26](F26-avc-ss-oidc.md) — cross-site consumer; uses F28 bundles for prod cut-over
- [F27](F27-feedback-ingest.md) — reverse-direction consumer of the same Packages primitive
- `lib/minisign.sh` — existing signing library (F21 Phase 5)
- `docs/guides/mons-operations.md` — existing operational runbook
- CI deletions that F28 supersedes: commits `24baecd`, `05d181a`, `4bb1264`
