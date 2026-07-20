# ADR-0032: Non-Production Data Refresh & File-Store Handling — two flows, omit-and-placeholder, no raw bytes across the boundary

**Status:** Proposed (2026-07-20)
**Date:** 2026-07-20
**Decision Makers:** Robert Karsten Zaar (with AI assistance)
**Related Issues:** ops#110 (ssc DB sanitiser wired, Path A), ops#111 (Flow A — full Moodle
sanitised artifact), ops#112 (Flow B — moodledata DR backup), ops#113 (prod guards),
ops#114 (this ADR umbrella), ops#84 (moodledata scrubber)
**References:** [ADR-0017](0017-distributed-build-deploy-pipeline.md) (trust-through-signatures,
sanitise-on-prod), [ADR-0025](0025-production-backup-to-ver.md) (two-flow invariant: raw→ver only),
[ADR-0026](0026-nwp-server-capability-agent.md) (three-key one-way ledger), [ADR-0031](0031-paired-site-versioning-and-promotion.md)
(plane 5b: moodledata = PII/minors' records; D8: moodledata in zero backups)
**Research basis:** two max-research sweeps 2026-07-20 — external best-practice (8 findings, all
3-0 adversarially verified) + internal architecture map. Key sources: Catalyst `local_datacleaner`,
`moodledata_orphans.php`, drush `sql:sanitize`, minisign, GDPR Recital 26 / ICO / CJEU C-413/23 P,
Oracle Data Safe (deterministic masking).

---

## Context

NWP must produce safe, repeatable developer/staging copies of a **coupled Drupal + Moodle fleet**
joined by OIDC SSO (`nwc` ↔ `ssc`, `nwd` ↔ `ssd`), under a paranoid, local-first, open-source
threat model: **sanitisation happens on the production host, raw user data must never leave prod,
and artifacts are trusted via cryptographic signatures rather than trusted hosts** (ADR-0017).

A complete, fail-closed **Drupal DB** refresh pipeline already exists end-to-end (prod-native
scratch-DB sanitiser → independent PII gate → HTTP-PUT fixture with a write-only deploy token).
The **Moodle** side and the **file store** (both stacks) are the gap:

- The Moodle DB sanitiser (`lib/sanitizers/moodle.sh:moodle_sanitize`) is implemented and, as of
  ops#110, wired for `ssc` via the prod-native path (Path A).
- The moodledata scrubber (`lib/sanitizers/moodle-dataroot.sh`) exists but is **not composed into
  any pipeline**.
- **moodledata is in zero backups** (ADR-0031 D8) and has **no host→host transport** anywhere.
- Drupal `private/` files are similarly excluded from backups.

The open question this ADR answers: *what is the best-possible refresh architecture given what NWP
already has, and specifically how are the binary user-uploaded files handled?*

## The load-bearing insight

Databases are only half the data, but the **file store does not need to be transported for dev
copies**. The mature answer to a content-addressable store (Moodle `filedir/<contenthash>` joined
to `mdl_files` on that hash; Drupal `public/`/`private/`) is **omit-and-placeholder or
omit-and-prune — never copy raw uploads** (verified against Catalyst `local_datacleaner`'s
"Cleanup sitedata" sub-plugin and `moodledata_orphans.php`). NWP's `moodle-dataroot.sh` already
implements this: it emits an **empty scaffold**. Therefore the "sanitised moodledata" carries
**~zero real bytes** — what crosses the trust boundary is a manifest/proof, and the dev side
regenerates the empty scaffold locally.

This splits the problem into two clean, independent flows, both already supported by NWP's
transports and both honouring the immovable constraints.

## Decision

### Two flows, never conflated

| Flow | Purpose | Data | Destination | Transport |
|------|---------|------|-------------|-----------|
| **A — Sanitised dev copy** | dev/stg substrate | scrubbed DB + **empty** dataroot scaffold (manifest) | git-host → dev/AI tier | `server-publish` HTTP PUT, write-only deploy token |
| **B — DR backup** | disaster recovery | **raw** DB + **raw** files + **raw** moodledata | **`ver` only** (encrypted) | `server-backup` restic → `ver-backup-pull` |

Flow A never moves file bytes. Flow B is the **only** place raw moodledata moves, and it goes to
`ver` (prod-trust) over the restic path that already exists — this preserves ADR-0025's invariant
(*raw → ver only; the sanitised/dev channel must never see raw data*).

### File-store handling: omit-and-placeholder + optional prune

For both stacks, the dev-copy file store is **emptied, not copied**:

- Moodle: `moodle_scrub_dataroot` emits an empty `filedir/` + system scaffold + a manifest. On the
  dev copy, run `moosh file-dbcheck` to prune orphaned `mdl_files` rows so users see a clean
  "no submission" instead of "file missing" errors (research-recommended reconciliation for a
  kept-DB/emptied-store copy).
- Drupal: the equivalent is empty `public/`/`private/` scaffolds; orphan handling via
  `stage_file_proxy` or bespoke pruning (a Drupal-side follow-up).

**Rejected: placeholder-substitution** (replace each upload with a generic file of matching type).
It changes `filedir` contenthashes and forces `mdl_files.contenthash` pointer reconciliation for no
dev benefit; NWP uses avatars not real photos (mayo_avatars policy), so profile pictures are moot.

### Flow A composition — one atomic clean artifact

A prod-native orchestrator that wholly succeeds or produces nothing (fail-closed, idempotent):

```
1. moodle_sanitize       --output db.sql.gz          (scratch DB; plane-5b tables; oidc-email salt)
2. moodle_scrub_dataroot --dataroot $CFG->dataroot --output scaffold/   (empty filedir + manifest)
3. pii_gate_scan         db.sql.gz                    (independent backstop)
4. bundle → <site>-sanitized-<ts>.tar.gz { db.sql.gz, dataroot-manifest }
5. publish via write-only deploy token                (existing HTTP PUT path)
```

Loader side (dev/stg): load DB → rebuild empty dataroot scaffold locally from the manifest →
`moosh file-dbcheck` prune. Tracked in **ops#111**.

### Cross-store identity is preserved deterministically

The nwc↔ssc SSO join survives in dev only under **deterministic pseudonymisation** — a given input
maps to the same masked output across both the Drupal and Moodle user tables (joined on OIDC
subject). NWP already implements this via `oidc-email.sh`'s shared salt. The external research
flagged as an *open question* that no proven OSS tool pseudonymises both stacks on one shared seed;
**NWP already built it.** This ADR ratifies keeping it central and never rotating the salt.

The salt lives in `.secrets.data.yml` on prod and **never ships with the artifact**. This is exactly
the GDPR "the recipient without the key holds anonymous data" pattern (Recital 26; ICO
pseudonymisation guidance; CJEU C-413/23 P, 2025): reversible masking keeps a dev copy *in scope*,
so the re-identification key must be siloed from the artifact — which NWP's architecture does by
construction.

### Prod guards (defence in depth)

Add `local_datacleaner`-style fail-closed guards to the sanitiser/scrubber entry points: refuse if
the target's hostname/phase looks like production, or shows recent non-admin login / recent cron.
NWP's scratch-DB model already avoids mutating prod, so this is cheap insurance for any future
in-place path. Tracked in **ops#113**.

### DR backup covers moodledata (Flow B)

Teach `server-backup` to resolve `$CFG->dataroot` (or `.nwp.yml moodle.tiers.<tier>.dataroot`) and
`restic backup --tag files` it alongside the raw DB; fold in Drupal `private/`; add the currently
missing nightly timer. Raw snapshots reach **only** `ver`. Tracked in **ops#112**.

### Scope & cadence

- **Volume:** anonymise-all-in-place for current site sizes. Rule-based subsetting (drop users idle
  > N days, courses older than N days — first-class in `local_datacleaner`) is an **opt-in dial for
  later**, not now.
- **Cadence:** dev refresh **on-demand** (operator-triggered); DR backup **scheduled nightly** → ver.
  GDPR data-minimisation favours **refresh-then-discard** over long-lived stale dev copies.

## Considered and deferred: signing the sanitised fixture

Signing *release artifacts* (packages, images, tarballs) is now common. Signing a *sanitised test
fixture* specifically is **not** common industry practice and is **overkill for most orgs** — a
leaked or stale fixture is already PII-free, so its blast radius is bounded by sanitisation, not by
a signature. ADR-0017 deliberately left the fixture channel unsigned (PII sweep + write-only token).

For NWP the marginal cost is near-zero (minisign already runs on the code channel) and it closes one
minor hole: a compromised git-host serving a **downgraded/stale** fixture to the dev tier
(anti-downgrade via minisign's tamper-proof trusted comment: site + timestamp + schema version).

**Decision: deferred, low priority.** Add later at near-zero cost if/when the threat model warrants
it. Recorded here so the reasoning is not re-litigated.

## Consequences

**Positive**
- The file-store problem is dissolved rather than solved by brute force — no raw byte transport for
  dev copies; the empty scaffold + `moosh` prune yields a working, PII-free dev site.
- moodledata finally enters the backup surface (Flow B), closing the ADR-0031 D8 "zero backups" gap.
- Every immovable constraint is honoured: raw→ver only; sanitise-on-prod; key siloed on prod;
  fail-closed two-gate; three-key ledger.
- NWP's `oidc-email.sh` is ratified as the deterministic-cross-store mechanism the wider ecosystem
  lacks.

**Negative / accepted trade-offs**
- Dev copies show "no submission" placeholders for user uploads — accepted industry default for a
  dev clone; realistic-file debugging is a separate, rare, `ver`-mediated exception.
- Fixture remains unsigned until the deferred enhancement lands — bounded because it is sanitised.
- Subsetting is deferred, so dev DB row counts match prod (fine at current scale).

**Follow-ups**
- ops#111 (Flow A), ops#112 (Flow B), ops#113 (guards); Drupal file-store orphan handling; the
  deferred fixture-signing enhancement.
