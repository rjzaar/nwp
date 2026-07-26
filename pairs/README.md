# `pairs/` — versioned pair contracts (ADR-0031 D2 / ops#75)

This directory holds the **pair contracts** that `lib/pair.sh` (`pair_guard`)
and `scripts/commands/pair-smoke.sh` consume — one file per pair, named
`<consumer>.pair-contract.yml` (the pair id is the **consumer** site key):

```
pairs/ssc.pair-contract.yml    # nwc (provider) ↔ ssc (consumer)
pairs/ssd.pair-contract.yml    # nwd (provider) ↔ ssd (consumer)
```

- **Committable** — a contract holds only `contract_version`, per-surface
  minimum versions, per-tier public issuer URLs, and smoke URLs. **No secrets.**
- **Authoring:** copy [`../pair-contract.example.yml`](../pair-contract.example.yml)
  here and fill in the real versions/URLs. See
  [`../docs/guides/ops75-pair-contract-schema.md`](../docs/guides/ops75-pair-contract-schema.md).
- **Fail-closed:** if a site declares `paired_with:` in `nwp.yml` but its
  contract here is missing/invalid, `pair_guard` refuses the deploy (override
  with `NWP_PAIR_GATE_SOFT=true` while mid-authoring).
- Override the location with `NWP_PAIR_CONTRACT_DIR`.

Deployed-version + RAG **state** lives elsewhere — `private/pairs/` (gitignored).

## Committed contracts (ops#75)

| File | Pair | contract_version | identity coupling |
|---|---|---|---|
| [`ssc.pair-contract.yml`](ssc.pair-contract.yml) | nwc (provider) ↔ ssc (consumer, **real students**) | 1 | `uid_lock`, `coupled_tiers: [live, prod]` — D6 `--code-only` applies |
| [`ssd.pair-contract.yml`](ssd.pair-contract.yml) | nwd (provider) ↔ ssd (consumer, **demo twin**) | 1 | none (`uid_lock: false`, `coupled_tiers: []`) — full-DB rebuild is fine |

Both hold only versions + public URLs (no secrets) and pass `pair_contract_valid`.
The OAuth/OIDC issuer wiring the `endpoints.*` describe is **F26-gated** (config
only) — see [`../docs/guides/ops75-pair-contract-schema.md`](../docs/guides/ops75-pair-contract-schema.md) §OAuth.

## Operator activation

The contracts above are inert until the two consumer sites declare their
provider in the **operator's** `nwp.yml` (which is gitignored — **never
committed**; the template lives in `example.nwp.yml`). Add, under `sites:`:

```yaml
sites:
  nwc:                        # PROVIDER (Drupal/Open Social)
    project: { type: drupal }
    canonical: dev            # community content source-of-truth (today)
  ssc:                        # CONSUMER (Moodle, real students)
    project: { type: moodle }
    paired_with: nwc          # ← turns on pair_guard for ssc's promotions
    canonical: live           # real students → user state canonical (D6)
  nwd:                        # PROVIDER demo twin
    project: { type: drupal }
    canonical: dev
  ssd:                        # CONSUMER demo twin
    project: { type: moodle, demo: true }
    paired_with: nwd          # ← turns on pair_guard for ssd's promotions
    canonical: dev            # demo — throwaway user state
```

`paired_with:` is the single opt-in key: a consumer that declares it activates
`pair_guard`; its provider is auto-derived (any site another site points at).

### Verify (no network, no deploy)

```bash
pl pair list                        # shows nwc↔ssc, nwd↔ssd once paired_with is set
pl pair status ssc                  # both sides' recorded cv vs the ssc contract
pl pair status ssd
pl pair check ssc live              # dry-run pair_guard's decision for a tier
pl pair-smoke ssc --dry-run         # prints the 5-URL plan; touches NO network (default)
pl pair-smoke ssd --dry-run
```

Until the provider has a recorded deployment at a tier, `pl pair status` shows
the consumer as "provider-first pending" and a consumer promotion there is
refused (D5) — bootstrap the first record with `pl pair record nwc-side...` or
let the deploy verbs record it on the first successful provider promotion.

> **D6 standing rule (ssc only):** while ssc students hold UID-locks against
> nwc's live tier, no full-DB `pl stg2live nwc` — use `--code-only`. `pair_guard`
> enforces this once `paired_with: nwc` is set. ssd (demo) is uncoupled, so a
> full-DB rebuild of either half is allowed.

### Cross-repo + adoption gates

A pair contract makes promises about a **different repository** and about
guards inside the provider's own code. Three read-only verbs prove them:

```bash
pl contracts crossref ssc     # every WS fn the provider calls is defined in the
                              # consumer tree, and every consumer smoke path exists
pl contracts guards ssc       # every guard declared under `guards:` has a real,
                              # non-comment CALL SITE (ops#138)
pl pair reconcile ssc --tier=live   # severed UID-locks after a restore (ops#83 §3)
```

All three **fail closed on an unverifiable corpus** (`CANNOT-VERIFY`) rather
than reporting clean — a gate scanned over an absent checkout that prints OK is
worse than no gate. `crossref` is wired into `pl pair-smoke` at plan time;
`guards` is deliberately **not**, because it is red on the real estate today
(ops#138) and turning a known operator-owned finding into a surprise promotion
block is a separate decision.

Contract blocks these read:

| block | read by | notes |
|---|---|---|
| `crossref.provider_roots` / `.consumer_roots` | `crossref`, `guards` | where each side's code is checked out |
| `crossref.core_paths` / `.core_ws_functions` | `crossref` | exemptions are DECLARED, never inferred |
| `guards[].symbol` / `.side` / `.why` / `.defined_in` | `guards` | `defined_in` is excluded under **every** root |
| `erasure.*` | `pl erasure` | operational half of ops#81; **not** a wire surface, so it does not move `contract_version` |
