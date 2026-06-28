# ADR-0025: Production Backup to `ver` (restic, custodian-pull, append-only)

**Status:** Accepted — 2026-06-29
**Decision Makers:** Robert Karsten Zaar (with AI assistance)
**Related Issues:** nwp/ops#4 (Session D); "there must be a way to back up to `ver` from prod"
**References:** [ADR-0017](0017-distributed-build-deploy-pipeline.md),
[ADR-0022](0022-nwp-verifier-binary-split.md),
[ADR-0024](0024-self-deploying-prod-agent.md),
[role-vocabulary](../reference/role-vocabulary.md),
prior art: `rjzaar/pleasy` `server/` (`gitbackupdb.sh`, `gitbackupfiles.sh`, `getlatestbackup.sh`).

## Context

`nwp-server` (ADR-0024) runs on each `prod-cluster` host and can `pull+verify`,
`apply`, `snapshot→sanitize→publish`, `rollback`, and report `status`. It does **not**
yet ship a disaster-recovery backup. The operator's earlier project (`pleasy`) backed up
prod by committing a `drush sql-dump` and the files tree into dedicated git repos and
pushing them (`gitbackupdb.sh` / `gitbackupfiles.sh`), with a per-prod SSH key. That
worked but has three flaws we must not carry forward:

1. **Raw PII pushed to the git host.** The dumps were unsanitized *and* unencrypted, so
   the (cloud-hosted, less-trusted) `gitlab-host` saw production user data in the clear.
2. **No retention / unbounded history.** Git history of large SQL dumps grows without
   bound; binary files dedup poorly in git.
3. **Push model with a writing credential on prod.** A compromised prod host could
   rewrite or delete its own backup history.

We need a backup path that fits the NWP threat model: `ver` (the offline,
hardware-keyed custodian — the role formerly written `verifier`) is the trusted backup
tier; `prod-cluster` is internet-facing and higher-risk; the `gitlab-host` is a
distrusted relay; **trust flows through signatures and keys, not machines.**

### The two flows must stay separate (threat-model invariant)

| Flow | Data | Crosses to | Encryption | Why allowed |
|---|---|---|---|---|
| **DR backup** (this ADR) | **raw** DB + files | `ver` only | restic client-side + tunnel; keystore sealed on `ver` | `ver` is in the **prod-trust tier** (offline, hardware-keyed, already deploys to prod). It MAY hold raw prod data. |
| **sanitized publish** (ADR-0024) | **scrubbed** (fail-closed PII gate) | `git-host` → dev/AI tier | n/a (already PII-free) | dev/AI tier must NEVER see raw data. |

Conflating them — e.g. sending a raw backup anywhere the AI/dev tier can read — breaks
the inviolable boundary. The DR backup goes to `ver` and nowhere else.

## Decision

Adopt **restic**, in a **custodian-pull, append-only** architecture.

### Engine: restic
Chosen over borg/kopia because it uniquely combines: an `--append-only` REST/SFTP
posture the prod client can be locked to; a first-class **`restic copy`** that lets
`ver` pull snapshots into its *own* full-access repo and prune there; content-defined
dedup (near-ideal for the large mostly-static `sites/default/files` tree plus a daily
text SQL dump); authenticated client-side encryption (a relay/transport host sees only
ciphertext); retention policies (`forget --keep-daily/weekly/monthly`); integrity
verification (`check --read-data`); and a single static Go binary that suits
signed-binary distribution. (restic's encryption is symmetric — acceptable here: prod
reading its *own* data is not a new disclosure; the property we need is that the
**relay/transport cannot read** and a **compromised prod cannot delete history**, both
of which hold.)

### Direction: `ver` PULLS (prod holds no delete-capable credential)
1. **prod (`nwp-server backup`)** runs `restic backup` of the raw DB dump + files into a
   restic repo it owns. Default repo location is **local to prod** (`--append-only`
   posture for any networked variant). prod keeps only a short local window
   (`--keep-last N`); it has **no credential that can prune/delete** the durable copy.
2. **`ver` (`ver backup pull`)**, during its scheduled online session, reaches prod over
   the existing dedicated WireGuard tunnel and runs **`restic copy`** to bring new
   snapshots into `ver`'s offline full-access repo, then `forget` + `prune` +
   `check --read-data-subset`. `ver` holds the only prune authority and the durable,
   immutable, off-box copy.

A compromised prod can at worst corrupt its short local staging window; it cannot reach
or delete `ver`'s repo. This is the "pull + immutable" anti-ransomware pattern.

### Credential ledger (extends ADR-0024)
- **prod** gains **no** new outbound credential for backups — it writes a *local* repo.
- **`ver`** gains one **read-only pull credential** to prod's restic repo path (over the
  tunnel; ideally an `authorized_keys` forced `command=` restricting it to restic/SFTP
  read on that path). This keeps "prod never holds a credential that writes the backup
  store" intact.

### Supply chain + key custody
- The **restic binary** on prod and `ver` is **minisign-verified** before use
  (reuses `lib/minisign.sh`), consistent with nwp-server's `pull+verify`.
- `ver`'s restic **repo password / keys are sealed at rest** on the offline host using
  the Solo 2 via **`age-plugin-fido2-hmac`** (FIDO2 hmac-secret → transient age identity;
  a Solo 2 is FIDO2-only and cannot be a *native* age/PIV recipient, so we seal the
  keystore rather than make the token the recipient). Key material is escrowed
  independently of both the relay and `ver` (zero-knowledge ⇒ no recovery if lost).

### Verification (the "0" in 3-2-1-1-0)
Every drain on `ver` runs `restic check`; a **full restore drill into an isolated
sandbox on a monthly cadence** (and after any tooling change) confirms recoverability.
A backup that has not been test-restored is not counted as a backup.

### Optional RPO upgrade (deferred): encrypted relay
Direct pull gates RPO on `ver`'s online cadence (a prod loss while `ver` is dark loses
data since the last pull). If that window is too wide, add an **append-only restic
REST/SFTP relay** co-located with (but credential-isolated from) the `gitlab-host`: prod
pushes ciphertext frequently to an add-only mailbox; `ver` drains it. The relay holds
only restic ciphertext and cannot delete. This is deferred until a measured RPO target
demands it; the direct-pull design is the v1.

## Consequences

### Positive
- Fixes all three pleasy flaws: no raw PII off-box except to `ver` (encrypted), bounded
  retention, and prod cannot delete backup history.
- Reuses NWP primitives: minisign verification, the ver↔prod tunnel, the role model.
- Dedup makes the large files tree cheap after the first snapshot.
- Satisfies 3-2-1-1-0: prod (1) + prod-local staging (2) + `ver` off-site immutable (3,
  +1 air-gapped), verified restores (0).

### Negative / costs
- New tool dependency (restic) on prod and `ver`; both must carry a minisign-verified
  binary.
- restic is symmetric-key: prod can read its *own* backups (acceptable — same data it
  serves live) — it does **not** give "prod can't read past backups." If that property
  is ever required, it needs the deferred relay + storage-layer Object Lock, or a
  future asymmetric engine.
- `ver`'s online cadence sets the RPO until/unless the relay is added.
- Key custody is unforgiving (lose `ver`'s key ⇒ lose the backups); escrow is mandatory.

### Neutral
- The `nwp-server backup` verb extends ADR-0024's capability set to six verbs; it stays
  AI-free (no AI/CI/SaaS modules) and is covered by the `pl build-server` deny-scan.

## Implementation Notes
- prod verb: `scripts/commands/server-backup.sh` (`nwp-server backup`) — restic backup of
  the raw DB (`drush sql-dump`) + the files tree to a local repo; `--keep-last` local
  window; `--dry-run` default-safe; minisign-verify the restic binary first.
- `ver` verb: `scripts/commands/ver-backup-pull.sh` (`ver backup pull`) — `restic copy`
  from prod (sftp over tunnel) → `ver`'s repo → `forget`/`prune`/`check`.
- Both added to `build/nwp-server.include`; `pl build-server` deny-scan must stay green.
- First real run is **supervised on prod + `ver`** (needs restic installed, the pull key,
  the tunnel, and `ver`'s sealed keystore) — like the sanitizer and onboard live paths.

## Review
**30-day review:** 2026-07-29. **Success metrics:** a `ver`-side `restic check` passes on
a real drained repo; a monthly restore drill reconstructs a site; prod holds no
credential able to delete `ver`'s repo; `pl build-server` deny-scan stays green with the
backup verbs included.

## Related Decisions
- [ADR-0017](0017-distributed-build-deploy-pipeline.md) — `ver` role + the prod boundary.
- [ADR-0024](0024-self-deploying-prod-agent.md) — the `nwp-server` agent this extends.
- [ADR-0022](0022-nwp-verifier-binary-split.md) — AI-free build target the backup verbs join.
