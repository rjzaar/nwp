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

> No real contract is committed yet: authoring the ssc/nwc and ssd/nwd contracts
> is an operator step (real deployed versions + the F26-gated issuer wiring).
