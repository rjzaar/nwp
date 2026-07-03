# Setting up `ver` — the offline verifier / single-machine AI-free nwp

> **Status:** DRAFT — the build is real and reproducible, and the runtime
> capabilities were **validated end-to-end on 2026-07-02** on a disposable
> prod-boundary test host (nwp/ops#23; `publish` verb excepted — see §5). `ver`
> itself is **not provisioned** and not on the tailnet. Read the DONE / PENDING
> markers in each section before acting.
> **Date:** 2026-07-01 (updated 2026-07-02)
> **Audience:** the operator, sitting at `ver`. Every command here is something
> **you** type at the machine — `ai-host`/`authoring` assistants cannot reach it.
> **See also:** ADR-0022, ADR-0024 (deploy authority), ADR-0026 (the capability
> agent), ADR-0025, [`docs/reference/role-vocabulary.md`](../reference/role-vocabulary.md),
> and [`nwp-single-machine.md`](nwp-single-machine.md) (the reframing: this same
> build is the minimal one-machine install).

## 1. What `ver` is, and its trust posture

`ver` is the **offline signed-deploy verifier + backup custodian** role
([role-vocabulary](../reference/role-vocabulary.md)): it holds the hardware-rooted
signing/verification key, verifies signed bundles locally, and pulls disaster-recovery
backups from production. It is the **prod-trust tier** — air-gapped except for an
outbound WireGuard session, and **never AI-accessible**.

The software `ver` runs is the **`nwp-server` build target**: a minimal, separately-built,
**AI-free** artifact assembled from the `nwp` source tree (ADR-0022, renamed and
re-scoped by ADR-0026). The AI-free property is a **build-time guarantee** — the
AI / CI / SaaS modules are *absent from the artifact*, not merely disabled by a flag.

> **Tier framing (who deploys what, today).** The **live-test tier** self-deploys
> via this agent — validated end-to-end 2026-07-02 (per the 2026-07-01 operator
> grant recorded in ADR-0024). **Real user-facing prod today** is gated by the
> offline deploy host + hardware token (ADR-0017). **Real prod's target model**
> is the runner-resident ADR-0024, once its preconditions (token downscope,
> WebAuthn, protected runner) land. The agent remains the capability set and the
> documented escalation / reserve path for real prod (ADR-0026).

The capability set, and nothing else (ADR-0026 + ADR-0025):

| Verb | What it does | Backed by |
|------|--------------|-----------|
| pull + verify | fetch a signed bundle over public HTTPS, minisign-verify locally, check payload/scripts SHA-256 against the manifest | `lib/minisign.sh`, `lib/bundle-verify.sh` |
| apply | apply a verified bundle in canonical order, enter maintenance, **roll back on failure** — this host only | `lib/rollback.sh`, `lib/rollback-remote.sh`, `scripts/commands/rollback.sh` |
| snapshot → sanitize → verify → publish | snapshot the DB, run the per-site sanitizer, **fail-closed PII gate**, publish the sanitized artifact to *its own* repo | `lib/sanitizers/`, `lib/pii-gate.sh`, `scripts/commands/publish.sh` |
| rollback | restore the previous release / DB on this host | `lib/rollback.sh` |
| backup (DR) | raw restic snapshot to a local repo; `ver` later pulls it (ADR-0025) | `scripts/commands/server-backup.sh`, `scripts/commands/ver-backup-pull.sh` |
| status | emit local health as JSON (local-only subset) | *(pending — see §7)* |

> **Naming.** ADR-0022 called this target `nwp-verifier`; ADR-0026 renamed it
> **`nwp-server`** for the self-deploying role. `ver` (the offline custodian)
> and `prod-agent` (the same build running *on* a prod host) are the two roles that
> carry this artifact. This guide uses `ver`.

## 2. Hardware / OS assumptions (capability language)

- A small, always-available x86-64 machine you physically control. No GPU, no AI
  runtime, no cloud dependency.
- A current, patched Linux with `bash`, `git`, `ssh`, `minisign`, `wireguard`,
  and `restic` available (the last three installed in §5–§6).
- A **FIDO2 hardware token** (Solo 2-class) for sealing the backup keystore
  (ADR-0025) and, later, the hardware-rooted signing key (ADR-0019).
- Outbound WireGuard reachability to each `prod-cluster` host you back up; no
  inbound exposure required.

Describe the box by capability, never by SKU or hostname (role-vocabulary §2.4).

## 3. Build the artifact on the `build-host` and transfer it

**DONE — reproducible and deny-scan-clean.** Build on the `build-host` (never on
`ver`, which holds no `nwp` source tree):

```bash
pl build-server                 # assemble → build/out/nwp-server/ + MANIFEST.sha256
pl build-server --list          # print the 15-entry include allowlist (no build)
pl build-server --scan-only DIR # re-run the fail-closed deny-scan on an assembled tree
```

What this produces and guarantees:

- The artifact is assembled from an **allowlist** (`build/nwp-server.include`,
  15 entries → **16 files**) — anything not listed is absent by construction.
- A **fail-closed deny-scan** (`build/nwp-server.deny-symbols`) then greps the
  assembled tree for any AI / CI / distrusted-SaaS vendor token; **any match fails
  the build**. This is the mechanical form of ADR-0022's "`strings` returns zero
  AI-vendor symbols."
- The build is **reproducible**: an independent checkout on a second host produces
  an **identical `MANIFEST.sha256`** (verified this session on two hosts).

**Verify the artifact independently on `ver`** after transfer:

```bash
pl build-server --scan-only /path/to/received/nwp-server   # must print deny-scan PASSED
sha256sum -c MANIFEST.sha256                                # from inside the artifact dir
```

Transfer the assembled tree to `ver` through the operator's offline channel
(signed, per ADR-0019 once the hardware key is in place). `nwp` itself is **not**
installed on `ver` — only this artifact.

## 4. The credential ledger (ADR-0026 — the inviolable part)

A host carrying this artifact holds **exactly three** credentials and nothing else:

1. a **read-only deploy key** — pull signed bundles (inbound, one-way);
2. a **write-only-to-its-own-repo deploy key** — publish the sanitized artifact
   (outbound, one-way; optionally locked with an `authorized_keys` forced `command=`);
3. the **minisign public key** — verify bundle signatures.

**Zero** Personal Access Tokens, **zero** control-plane credentials, **zero** keys
that reach another prod host. Both data directions are one-way, so a compromise of
this box cannot pivot to the control plane, another prod host, or any AI machine.

> **PENDING for `ver`.** `ver` is not yet provisioned; its keys are **not yet
> issued**. Provisioning them is gate 2 of the ADR-0026 migration path. (The
> ledger itself has been exercised: the 2026-07-02 field validation ran on a
> disposable test host with exactly the three keys and no PAT.)

## 5. Verify a signed bundle, then apply / rollback

**VALIDATED 2026-07-02 (nwp/ops#23)** on a disposable prod-boundary test host,
artifact-only, three-key ledger, no PAT, no AI: signed pull → verify (including
a tamper negative-test that was correctly **rejected**) → apply → rollback →
status all ran end-to-end. The `publish` verb, initially mis-wired to the
build-tier uploader, was **reworked and validated the same day**: it now runs
the prod-side snapshot → sanitize → fail-closed PII gate → write-only-token
upload chain (`server-publish.sh`; positive and fail-closed negative tests both
passed — see ADR-0026's validation record). There is no standalone `pl apply` /
`pl pull` verb — the verify/apply path is carried by the shipped libraries via
the artifact's own entrypoint:

- **Verify:** `lib/bundle-verify.sh` checks that the bundle is a well-formed tarball,
  that `manifest.json.minisig` verifies against the pinned public key, and that the
  recomputed SHA-256 of `payload/` and `scripts/` match the manifest. It **never
  partially verifies** — any failure aborts non-zero. Never set
  `BUNDLE_VERIFY_NO_SIG=1` on `ver`.
- **Apply / rollback:** `pl rollback list` / `pl rollback execute <site>` (and the
  underlying `lib/rollback.sh`) manage rollback points; apply enters maintenance and
  **rolls back on failure**, this host only.

> The pull/verify/apply/rollback/status paths **ran end-to-end on 2026-07-02**
> on a disposable test host (nwp/ops#23) — but not yet on a live `ver` or a real
> prod host. Treat the first run on any *new* host as supervised, with a dry-run
> first (`pl rollback execute … --dry-run`, `nwp-server publish … --dry-run`).

## 6. Backups — restic, custodian-pull, sealed keystore (ADR-0025)

The DR flow keeps **raw** prod data flowing to `ver` **only** (never to the dev/AI
tier — that path is the *sanitized* publish of §5). v1 is **direct pull**:

1. **On prod** (`prod-agent`): `pl server-backup --site-dir DIR` runs a `restic`
   backup of the raw DB dump + files into a repo **local to prod**, keeping only a
   short `--keep-last` window. Prod holds **no** credential that can prune or delete
   the durable copy. Dry-run is the default; add `--execute` for a real run. The
   restic binary is **minisign-verified before use** (fail-closed).
2. **On `ver`**: `pl ver-pull --from <prod-repo-over-tunnel> --to <ver-repo>` runs
   `restic copy` to drain new snapshots into `ver`'s **own full-access repo**, then
   `forget` / `prune` / `check --read-data-subset`. `ver` holds the **only** prune
   authority and the durable, immutable, off-box copy — the "pull + immutable"
   anti-ransomware pattern.

**Sealed keystore.** `ver`'s restic repo password is **sealed at rest** using the
Solo 2 via `age-plugin-fido2-hmac` (FIDO2 hmac-secret → transient age identity), and
escrowed independently of both the relay and `ver`. Losing it loses the backups —
escrow is mandatory.

**The "0" in 3-2-1-1-0.** Every drain runs `restic check`; a **monthly full restore
drill into an isolated sandbox** confirms recoverability. A backup that has not been
test-restored is not a backup.

> **PENDING.** First real run is supervised on prod + `ver` and needs: restic
> installed both sides, the read-only pull key, the tunnel, and `ver`'s sealed
> keystore — none provisioned yet.

## 7. First smoke tests (run in order, once provisioned)

| # | Test | Expected | State |
|---|------|----------|-------|
| 1 | `pl build-server` on `build-host`, then again on a second host | identical `MANIFEST.sha256` | **DONE** |
| 2 | `pl build-server --scan-only <artifact>` on `ver` | deny-scan PASSED, 0 AI/CI/SaaS symbols | **DONE** on build-host; rerun on `ver` after transfer |
| 3 | `sha256sum -c MANIFEST.sha256` inside the transferred artifact | all OK | PENDING (needs transfer) |
| 4 | credential ledger check: exactly 3 keys, all one-way | 3 keys, no PAT | PENDING (not provisioned) |
| 5 | `pl rollback list <site>` | lists rollback points (or empty, cleanly) | **VALIDATED** 2026-07-02 on a disposable test host (rollback = re-apply of the previous bundle); rerun on `ver` once provisioned |
| 6 | `nwp-server publish <site> --dry-run` | sanitize + PII gate run, uploads nothing | **VALIDATED** 2026-07-02 (reworked `server-publish.sh`: positive + fail-closed negative test; nwp/ops#23); rerun on the target host once provisioned |
| 7 | `pl server-backup --site-dir DIR` (dry-run) then `--execute` | local restic snapshot created | PENDING (needs restic + site) |
| 8 | `pl ver-pull --from … --to …` (dry-run) then `--execute` | snapshots drained, `restic check` passes | PENDING (needs tunnel + keystore) |
| 9 | monthly restore drill into a sandbox | a site reconstructed from `ver`'s repo | PENDING |

## 8. Status summary

| Area | State |
|------|-------|
| `pl build-server` builds a 16-file AI-free artifact | **DONE** |
| Deny-scan passes fail-closed | **DONE** |
| Reproducible build (identical MANIFEST on two hosts) | **DONE** |
| Capability paths (pull/verify/apply/rollback/status) exercised | **VALIDATED 2026-07-02** — full signed cycle incl. tamper negative-test on a disposable prod-boundary test host (nwp/ops#23) |
| `publish` verb | **FIXED + VALIDATED 2026-07-02** — reworked to snapshot → sanitize → fail-closed PII gate → write-only-token upload (`server-publish.sh`); old build-tier uploader excluded from the allowlist (nwp/ops#23, ADR-0026) |
| server-backup / ver-pull (ADR-0025) tested | **PENDING** (needs restic, tunnel, sealed keystore) |
| `ver` provisioned / on tailnet | **PENDING — not provisioned** |
| Three-key credential ledger issued on `ver` | **PENDING** (exercised on the test host 2026-07-02) |
| A local `status` verb in the artifact | **DONE** — validated 2026-07-02 (local JSON reflected real site state) |

## Related

- [ADR-0022 — nwp-verifier binary split](../decisions/0022-nwp-verifier-binary-split.md)
- [ADR-0024 — self-deploying prod via a runner resident on the prod host](../decisions/0024-self-deploying-prod-supersedes-verifier.md)
  (canonical for production deploy authority)
- [ADR-0026 — the `nwp-server` capability agent](../decisions/0026-nwp-server-capability-agent.md)
  (renumbered from a duplicate ADR-0024 on 2026-07-02)
- [ADR-0025 — production backup to `ver`](../decisions/0025-production-backup-to-ver.md)
- [`nwp-single-machine.md`](nwp-single-machine.md) — the same build as the minimal one-machine install
- [`using-nwp.md`](using-nwp.md) — the whole-system map
