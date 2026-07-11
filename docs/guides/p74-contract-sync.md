# P74 Phase 3 — signed intersite-contract sync (provider → Moodle plugin repos)

**Status:** IMPLEMENTED (compat gate + signed bundle + this runbook). The bot
step is DESIGNED + scriptable but does not require a running service.
**Parent:** [P74](../proposals/P74-intersite-data-contract.md) §Phase-3 ·
[intersite-contract research](../reports/intersite-contract-research-2026-07-10.md) §2.
**Trust root:** minisign (per the threat model, trust flows through the
signature, not the transport or host).

The JSON Schemas in `contracts/` are the wire shape of the nwc↔ssc boundary.
They live in **this** (provider) repo, but the **consumer** — the Moodle plugins
(`auth_nwc`, `local_nwc_copyright_sync`, `local_feedback`) — must validate the
same shapes on its side. Those plugins live in a **separate** repo. This is the
cross-repo sync: how a schema change reaches the consumer **trusted by signature,
not by host**, with no broker and no cross-repo call at MR time.

## The three layers this sits on

1. **Compat gate** (`pl contracts compat`, CI job `contracts:compat`): a schema
   change must be backward-compatible (expand-and-contract) vs its git-committed
   prior version, or the MR fails. This is a schema-registry's BACKWARD
   guarantee with only git history.
2. **Signed bundle** (`pl contracts sign` → `contracts/SHA256SUMS.minisig`): the
   pins in `SHA256SUMS` are signed with the NWP deploy key. `pair_guard`
   fail-closes at deploy if a surface's `schema_sha256` drifts from the file.
3. **This sync**: the signed bundle is copied into the consumer repo; the
   consumer verifies the signature before it will build.

## Runbook

### 1. Provider side (this repo) — on any schema change

```bash
pl contracts compat --base=main      # gate: backward-compatible? (CI enforces)
pl contracts sums                    # regenerate contracts/SHA256SUMS
pl contracts sign                    # minisign-sign it (prompts for the key password)
#   → writes contracts/SHA256SUMS.minisig — COMMIT it with the schema change,
#     and update each changed surface's schema_sha256: in pairs/ssc.pair-contract.yml.
pl contracts bundle                  # → dist/nwp-contracts-<ts>.tar.gz (+ nwp-deploy.pub)
```

> **Operator TODO (the one thing an AI agent cannot do):** `pl contracts sign`
> needs the minisign secret-key password, which is not available to automation.
> The signature (`contracts/SHA256SUMS.minisig`) is therefore produced by the
> operator on the dev workstation. Everything else — compat, sums, bundle,
> verify — is non-interactive. When the Solo 2C+ hardware key lands, signing
> moves to hardware touch; the runbook is unchanged (the public key is stable).

### 2. Bot side — PR the signed bundle into the Moodle plugin repo

No running service is required. A CI job (or a cron on `met`) unpacks the bundle
into the consumer repo's vendored contract dir and opens an MR:

```bash
# pseudo — see the helper's --out bundle in scripts/commands/contracts.sh
tar -xzf nwp-contracts-<ts>.tar.gz -C <moodle-plugin-repo>/contracts/
cp nwp-deploy.pub <moodle-plugin-repo>/contracts/     # pinned key (or already pinned)
git -C <moodle-plugin-repo> checkout -b sync/contracts-<ts>
git -C <moodle-plugin-repo> add contracts/
git -C <moodle-plugin-repo> commit -m "chore(contracts): sync signed intersite schemas <ts>"
# push + open MR via the bot token (Developer scope; never a prod key)
```

The bot holds no prod access; it only moves a **signed** artifact between two
code repos. A tampered bundle fails the consumer's verify step below, so the
bot is not a trust boundary.

### 3. Consumer side (Moodle plugin CI) — verify BEFORE merge (fail-closed)

```bash
cd contracts/
minisign -Vm SHA256SUMS -p nwp-deploy.pub    # signature against the PINNED key
sha256sum -c SHA256SUMS                        # files match the signed pins
python3 validate.py                            # (optional) schemas still self-valid
```

A bad signature or a checksum mismatch **fails the plugin pipeline** — the
consumer refuses to build against an unverified contract. This is
consumer-driven contract testing, broker-less, signature-rooted: each repo
verifies against the *pinned signed contract*, never the live other side.

## Fallback (documented, not primary)

If the signed-artifact flow is unavailable, a **tag-pinned git submodule** of
`contracts/` into the plugin repo also works (pin to a signed tag). Avoid a
Composer package until the schemas stop changing (research §2, "two-repo sync").

## Why not a registry / broker

A running schema-registry or PactFlow broker is a SaaS/service dependency the
threat model rejects. Git history + minisign gives the same BACKWARD guarantee
and the same "trusted by signature" property an offline tier can verify. See the
research report §2 for the full rejected-alternatives rationale.
