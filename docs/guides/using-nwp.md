# Using nwp — a map of the whole system

> **Status:** ACTIVE map for a new operator. Points at canonical sources rather than
> duplicating them.
> **Date:** 2026-07-01
> **Audience:** someone picking up nwp who needs the shape of the whole thing —
> the roles, the `pl` command surface, and the self-driving loop — before diving in.

nwp is a recipe-based system for standing up and operating Drupal (and Moodle) sites,
plus a self-driving control model that keeps a fleet of them healthy. You can use as
little or as much of it as you want — see the concentric tiers in
[`nwp-single-machine.md`](nwp-single-machine.md).

## 1. The role tiers (who does what)

Every host carries a **role** (never a bare hostname — see
[`role-vocabulary.md`](../reference/role-vocabulary.md)). The ones you meet first:

| Role | Job | Trust |
|------|-----|-------|
| `authoring` | operator's workstation; signed commits originate here | identity tier; never reaches prod directly |
| `ci-host` / `build-host` | CI runners; build release artifacts (`pl build-server`) | untrusted by prod; holds no prod creds |
| `ai-host` | local LLM / agent workloads | AI tier; never reaches prod |
| `ver` | offline signed-deploy **ver**ifier + backup custodian; hardware-rooted key | prod-trust; air-gapped except outbound WireGuard; never AI-accessible |
| `prod-agent` | the AI-free `nwp-server` artifact running **on** a prod host: pull+verify / apply / publish / rollback / backup / status | prod-trust; exactly three one-way keys; zero AI code |
| `prod-cluster` | the user-facing Drupal sites | public-facing; hardened |
| `gitlab-host` | self-hosted git + artifact distribution | trusted by build tier; distrusted by `ver` (signatures, not paths) |

The rule that ties them together (CLAUDE.md threat model): **no AI-accessible machine
may write to prod, and no AI code may be present on a host with production-write
capability.** Trust flows through **signatures**, not machines.

## 2. The `pl` command surface, grouped by purpose

`pl <command>` is the single entry point. Grouped by what you reach for:

> **Additions since this table was written (2026-07):** `pl console` (mesh-only web
> console), `pl demo` (the daily-reset demo tier, incl. `demo invite`), `pl ver-test`
> (the DR test harness), `pl backup prune` (30-day retention), `pl config track` (the
> configuration-drift gate), `pl doc-truth` (the documentation-truth gate), and
> `nwp-server backup --sanitize` (the sanitised long-term DR tier). Each has a how-to
> guide — see [the guides index](README.md).

**Oversight (read-only — "what needs attention"):**

| Command | Purpose |
|---------|---------|
| `pl status` | per-site table, per-cell health |
| `pl rag` | per-site 🔴/🟠/🟢 rollup (🔴 security · 🟠 needs work · 🟢 clear); `--json` envelope |
| `pl todo` | one priority-ranked work queue |
| `pl audit` | read-only composer-advisory awareness per site |
| `pl issue` | read/write CLI against the ops issue tracker (`ls`/`show`/`create`/`comment`/`close`/…) |

**Sites (day-to-day lifecycle):**

| Command | Purpose |
|---------|---------|
| `pl install` / `pl delete` | create / remove a local site |
| `pl backup` / `pl restore` | site backup and restore |
| `pl onboard <site>` | chain a prod site into the fleet (create repo → import → **fail-closed PII gate** → register → first `pl status`) |
| `pl verify` | run the verification suite; writes `.badges.json` (R/A/G) |
| `pl secrets` | registry-driven secrets lifecycle (no token stored on host) |

**Deploy / prod agent (the AI-free build target):**

| Command | Purpose |
|---------|---------|
| `pl build-server` | assemble the AI-free `nwp-server` artifact (allowlist + fail-closed deny-scan) |
| `pl publish <site>` | publish a **sanitized** artifact (fail-closed PII gate) to its own repo |
| `pl rollback list` / `pl rollback execute` | manage / execute deploy rollback |
| `pl server-backup --site-dir DIR` | prod-side raw restic DR snapshot (NWP-ADR-0025) |
| `pl ver-pull --from … --to …` | `ver` drains prod's snapshots, prunes, verifies (NWP-ADR-0025) |

> **Verifying commands exist:** everything above dispatches through `pl` (explicit
> case or the `scripts/commands/<name>.sh` fallback). Note the DR pull command is
> **`pl ver-pull`** (script `ver-backup-pull.sh`). There is deliberately **no**
> `pl apply` / `pl pull` verb — pull+verify+apply live inside the AI-free artifact
> (`lib/bundle-verify.sh`, `lib/rollback.sh`) and were **validated end-to-end on
> 2026-07-02** on a disposable prod-boundary test host (nwp/ops#23), the `publish`
> verb excepted (mis-wired — see [`ver-setup.md`](ver-setup.md) §5 and NWP-ADR-0026's
> validation record).

## 3. The self-driving loop

nwp's operating model treats **every unit of work as a `pl` command (action), an
issue (work item), or a `pl status`/`pl rag` signal (oversight)** — you improve the
commands rather than doing the work by hand.

```
  pl status / pl rag  🔴🟠
          │
          ▼
     pl issue create ──────────►  agent-loop (issue → MR)          [AI tier]
          ▲                                │
          │                                ▼
          │                        human MERGE approval            ← the A14 / NWP-ADR-0024 boundary
          │                                │  (WebAuthn / hardware-gated)
          │                                ▼
          │                        signed bundle → prod
          │                                │
          │                   prod-agent: pull + verify + apply
          │                                │  (roll back on failure)
          └────────────  re-test · pl status re-checks ◄───────────┘
```

Failures on the control plane don't get hand-fixed — they **become issues the loop
fixes**. The human approves merges and watches `pl status`. This is what ends the
"same problem, seventh manual pass" cycle: issues are the single system of record,
`pl verify` asserts claims against code, and `pl rag` is live truth.

## 4. Where to go next

- **[`nwp-single-machine.md`](nwp-single-machine.md)** — the simplest way in: the
  AI-free core on one box, and the concentric tiers.
- **[`ver-setup.md`](ver-setup.md)** — set up `ver` / the AI-free `nwp-server`
  build: trust posture, credential ledger, backups, smoke tests.
- **OPERATING-MODEL concepts** — the self-driving system (session-start protocol,
  RAG contract, the self-healing loop). The authoritative write-up is the operator's
  private read-first doc (`nwc-internal/OPERATING-MODEL.md`); its *concepts* are
  summarised in §3 above.
- **Runbooks** — the operator's private `SECURITY-REMEDIATION`, `UNFORK`, and
  `PUBLISH-SCRUB` runbooks for each workstream.
- **ADRs** — [NWP-ADR-0020 tiered model](../decisions/0020-tiered-architecture-model.md),
  [NWP-ADR-0022 binary split](../decisions/0022-nwp-verifier-binary-split.md),
  [NWP-ADR-0024 self-deploying prod / deploy authority](../decisions/0024-self-deploying-prod-supersedes-verifier.md),
  [NWP-ADR-0026 the `nwp-server` capability agent](../decisions/0026-nwp-server-capability-agent.md),
  [NWP-ADR-0025 backup to `ver`](../decisions/0025-production-backup-to-ver.md).
- **[`../README.md`](../README.md)** — the full documentation index.
