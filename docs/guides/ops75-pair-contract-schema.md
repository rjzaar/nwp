# Pair contract + `pair_guard` + pair-smoke — design & schema (ADR-0031 Phase C / ops#75)

> **Status: SHIPPED (guard + schema + smoke), auth half STUBBED.** This document
> specifies the versioned **pair contract** format, the `pair_guard` deploy-time
> check that consumes it, and the **pair smoke** suite. The non-auth machinery is
> wired and tested; the **OAuth/OIDC wiring is F26-gated and NOT implemented here**
> (see [§OAuth](#oauth-stub-f26-gated)). **Date:** 2026-07-10.
> **ADR:** [ADR-0031](../decisions/0031-paired-site-versioning-and-promotion.md)
> D2 (version the contract), D5 (provider-first + pair smoke), D6 (per-plane
> canonicality + the UID-lock/`--code-only` invariant), D7 (multi-MR convention).

---

## 0. What Phase C delivers

| Piece | File | Role |
|---|---|---|
| Pair contract schema + worked example | [`pair-contract.example.yml`](../../pair-contract.example.yml) | the versioned artifact (D2) |
| `pair_guard` + helpers | [`lib/pair.sh`](../../lib/pair.sh) | deploy-time invariant check |
| Guard wiring | `scripts/commands/{stg2live,stg2prod,live2prod}.sh` | choke-point calls |
| Pair smoke suite | [`scripts/commands/pair-smoke.sh`](../../scripts/commands/pair-smoke.sh) | onboarding 5-URL check (D5) |
| Inspection surface | [`scripts/commands/pair.sh`](../../scripts/commands/pair.sh) | `pl pair list/show/status/check/record/rag` |
| Pairing config template | [`example.nwp.yml`](../../example.nwp.yml) `sites:` | `paired_with:` for ssc↔nwc, ssd↔nwd |

The pairs: `nwc` (Drupal/Open Social, **provider**) ↔ `ssc` (Moodle, real
students, **consumer**); demo twins `nwd` ↔ `ssd`.

---

## 1. The pair contract (`pairs/<consumer>.pair-contract.yml`)

ADR-0031 D2 versions the **contract, not the pair**. One contract per pair, its
id = the **consumer** site name (each consumer has exactly one provider). It
lives in `pairs/` (committable — no secrets, only versions + public URLs); the
default dir is `$PROJECT_ROOT/pairs` (override `NWP_PAIR_CONTRACT_DIR`).

### 1.1 Required keys (guard fails closed without these)

- `contract_version` — monotonically increasing **integer**; a bump is an
  expand-contract change (D5).
- `provider` — the Drupal/OIDC-issuer site key (`nwc`).
- `consumer` — the Moodle site key (`ssc`).

### 1.2 Full schema — see the worked example

The complete, commented, worked example is
[`pair-contract.example.yml`](../../pair-contract.example.yml). Sections:

- `dependencies` — **first use of the F28 `dependencies` manifest field** (D5):
  the counterpart bundle id each half's signed bundle carries.
- `surfaces` — per surface (`oauth_sso`, `copyright_sync`, `feedback_bridge`)
  the minimum counterpart version (expand-contract).
- `identity` — the D6 data rail: `uid_lock` + `coupled_tiers` (the tiers on
  which a full-DB push is forbidden).
- `policy` — the ops#31 fix at the design level: a **single-writer** version
  field for `nwc_copyright`; both sync paths read it.
- `render_id_stability` — the ADR-0027 §7 canonical-id join-key guarantee.
- `endpoints.<tier>.issuer` — per-tier OIDC issuer URL (makes the dead
  `paired_with`/`oauth2` keys live **config**; wiring is F26-gated).
- `smoke_urls` — the onboarding 5-URL set the smoke suite probes (D5).

---

## 2. `pair_guard` — the deploy-time invariant check

`pair_guard <site> <target-tier> <cmd> <code-only> <override-pair>` is called at
the **same choke-point** as the existing guards, in the ADR-mandated order:

```
canonical_guard_content_push → canonical_enforce_branch_policy
  → maturity_guard_deploy → pair_guard → deploy_gate_require
```

It is wired into `stg2live` (target `live`), `stg2prod` and `live2prod` (target
`prod`), immediately after `maturity_guard_deploy` and before
`deploy_gate_require`.

### 2.1 What it refuses

1. **Provider-first ordering (D5).** A **consumer** promotion is refused when
   the provider has not reached the consumer's `contract_version` at that tier
   (or has no recorded deployment there at all). "Provider promotes first."
2. **UID-lock / `--code-only` rule (D6).** A **full-DB** push to a tier listed
   in `identity.coupled_tiers` is refused —
   - on the **provider** (nwc) it would renumber Drupal uids and sever every
     ssc SSO identity;
   - on the **consumer** (ssc) it would clobber real students' learning state
     (minors' records, plane 5b).
   The fix in both cases: re-run with `--code-only`.
3. **Red-pair block.** While the pair's last pair-smoke set the tier RAG to
   `red`, promotion of either half onto that tier is refused.

Each refusal points at the remedy and at the ledgered `--override-pair` escape
(mirrors `--override-canonical`): a loud warning + an audit line in
`private/pairs/<pair>.log`.

### 2.2 How it fails closed

- **Off-unless-configured.** A site that is not part of any pair — no
  `paired_with:` in `nwp.yml` and nothing points at it — makes `pair_guard`
  return 0 immediately. Every current (unpaired) site is unaffected; this is the
  same additive pattern as `lib/deploy-gate.sh`.
- **Fail-closed on a declared-but-unverifiable pair.** Once a site **is**
  declared paired, a **missing or unparseable** contract means the invariants
  cannot be checked — so the guard **refuses** the deploy. The escape for an
  operator mid-authoring is `NWP_PAIR_GATE_SOFT=true` (downgrades to a warning;
  the skip is ledgered), mirroring deploy-gate's `NWP_DEPLOY_GATE_REQUIRE`
  inverse.
- **Unknown values are refused, not guessed.** Missing provider deployment
  record ⇒ refuse (can't prove provider is ahead). `yq` absent ⇒ contract
  invalid ⇒ fail closed for a declared pair.

### 2.3 Deployed-version + RAG state

`pair_guard` needs both halves' *deployed* `contract_version` to check ordering.
That state lives in `private/pairs/` (gitignored, never committed):

- `<pair>.<side>.<tier>.cv` — the last-recorded contract_version.
- `<pair>.<tier>.rag` — `green|amber|red` from the last smoke.
- `<pair>.log` — append-only ledger (records, overrides, RAG changes).

Written on a **successful** promotion by `pair_guard_record_success` (called at
the end of each deploy verb; best-effort, never fatal, no-op for unpaired sites
and dry runs) and by `pl pair record` / `pl pair rag` for bootstrap/recovery.

---

## 3. Pair smoke suite (`pl pair-smoke`)

`scripts/commands/pair-smoke.sh` runs the onboarding 5-URL set (D5) after a
promotion. **Safe by default:**

- Default mode is **dry-run** — it prints the URLs it *would* probe and touches
  **no network**. `--run` is required to actually probe.
- `--run` against `--tier=prod` is refused unless `--force-prod` is also given.
- It is a read-only HTTP GET/POST probe; it never writes to any site.
- A red result sets the tier RAG red (which `pair_guard` then blocks on).

```
pl pair-smoke ssc                         # dry-run plan, no network (default)
pl pair-smoke ssc --tier=dev --run \
    --provider-base=https://nwc-dev.ddev.site \
    --consumer-base=https://ssc-dev.ddev.site   # actually probe (non-prod)
```

> **This session did not run the smoke against any live site** — only the
> dry-run plan was exercised.

---

## 4. Inspection surface (`pl pair`)

```
pl pair list                       # configured pairs (nwp.yml paired_with)
pl pair show ssc                   # the resolved contract
pl pair status ssc                 # both sides' recorded versions vs contract  ← ops#75 acceptance
pl pair check ssc live             # dry-run pair_guard's decision (no deploy)
pl pair record ssc provider live 1 # record a deployed contract_version (bootstrap)
pl pair rag ssc live green         # set the RAG (testing/recovery)
```

---

## OAuth (STUB, F26-gated)

**The OAuth/OIDC wiring is deliberately NOT implemented in Phase C.** What is and
is not here:

**Present (config only):**
- The contract's `endpoints.<tier>.issuer` URLs are *read* as configuration and
  displayed by `pl pair-smoke` / `pl pair show`.
- The `oauth_sso` surface min-versions are recorded in the contract.
- The smoke suite lists an `oauth_callback` + `oidc_discovery` probe and prints
  a "token round-trip would run here (STUB — F26-gated)" line on non-prod tiers.

**Absent (F26 — nwp/nwp!49 human review; ADR-0029 D4):**
- No Drupal `simple_oauth` client is created/configured.
- No Moodle OIDC issuer is provisioned or pointed at nwc-dev vs nwc-live.
- No secrets are read, written, or round-tripped; `pl secrets` is not touched.
- The actual token round-trip in the smoke suite is a printed stub, not a call.

Per the ops#75 acceptance and CLAUDE.md, **all auth-touching parts carry human
sign-off (F26 !49) before merge.** The auth `pair` command (issuer provisioning,
`avc-moodle-setup` generalisation) named in the ops#75 scope item 2 is **not**
built here — it lands on the F26 path. `lib/pair.sh` contains no auth logic; it
reads versions and public URLs only.

---

## TODO / follow-ups (not in Phase C scope)

- **Auth half (F26):** issuer provisioning command + real token round-trip in
  the smoke suite (nwp/nwp!49 human-gated; ADR-0029 D4 → `nwp/auth-nwc-oauth2`).
- **Moodle promotion substrate (ops D / ADR-0031 D8):** `pl` cannot promote a
  Moodle site yet, so the consumer-side guard checks are correct but currently
  guard a path (`stg2live ssc`) that ops D must first make real. The
  `--code-only` remedy is fully honored only on `stg2live` today; `stg2prod` /
  `live2prod` parse `--code-only` and pass it to the guard but do not yet skip
  the DB step in their bodies (they refuse the coupled full-DB push instead).
- **Version signal source (ops#73/#74):** the Moodle half's deployed
  `contract_version` should be derived from the plugin lockfile
  (`.nwp-plugins.lock.yml`) once Phase A wiring lands; today it is recorded by
  the deploy verbs / `pl pair record`.
- **Multi-repo `pl issue work` preflight (D7):** check `origin/ops-N` across all
  pair-affected repos before building — convention documented, tooling deferred
  to ops#49 (`pl gitlab`).
- **`ssc` vs `ssc1` registration mismatch** (Phase A doc §4 TODO-A5) — resolve
  before the guard governs the real ssc site.
