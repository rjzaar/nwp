# Role vocabulary — the public NWP nomenclature

**Status:** Canonical (per ADR-0020, authored as F32 Phase A)
**Audience:** All NWP contributors. Everyone writing or reviewing public
documentation must use these labels — never bare hostnames.

> **Rule.** No literal hostname (`mini`, `metabox`, `met`, `mons`,
> `carlo`, `mmt`, or any specific operator-bound short name) may appear
> in any file under `docs/`, `lib/`, `scripts/`, or the repo root, except
> in this document (which by necessity catalogues the rule) and in
> narrowly path-pinned `.gitleaksignore` entries with rationale comments.
> The leakage gate (per P61) enforces this mechanically.

The role-label vocabulary lets a public NWP repository describe its
distributed architecture in terms of *what each host does* rather than
*who the operator named it*. Each role is a job description; the binding
to a concrete hostname lives only in the operator's private overlay
(`nwp-instances/instance-manifest.yml`, per F33 §4.3).

---

## 1. Canonical role labels

| Label | What this host does | Trust posture |
|---|---|---|
| `authoring` | Primary workstation. Signed commits originate here. Authors content, design notes, ADRs. | Operator's identity tier; never reaches prod directly. |
| `ci-host` | CI/CD runner. Heavy CPU work, long-running jobs, fresh-clone integration tests. | Untrusted by prod. Holds no prod credentials. |
| `build-host` | Builds Drupal release artefacts. Typically co-located with `ci-host`. | Same as `ci-host`. |
| `ai-host` | Local LLM, AI bridge subprocess host. Day-to-day agent workloads. | AI-capable tier. Never reaches prod. |
| `llm-host` | Synonym for `ai-host` when emphasising "the LLM lives here." | Same as `ai-host`. |
| `voice-agent` | Telephony / push-to-talk role (X02-style). Typically co-located with `ai-host`. | Same as `ai-host`. Empty tool allowlist. |
| `transcription-worker` | Whisper CPU forward. Long-running, batch. | CI-tier. |
| `transcription-gpu` | Whisper Vulkan / CUDA. GPU-resident. | AI-tier. |
| `mirror-store` | F24-style corpus mirror. Always-on, large-disk, holds working trees mirrored from `authoring`. | CI-tier. |
| `rag-backend` | X03-style local RAG service (sqlite-vec + FTS5). Serves the voice-agent / coding agents. | CI-tier; reads `mirror-store`. |
| `verifier` | Offline signed-deploy verifier. Holds the hardware-rooted signing key. Reaches prod for **hardware-gated / irreversible** deploys and as a fallback (per ADR-0024, no longer the *sole* prod writer). | Prod-trust tier. Air-gapped except for outbound WireGuard. Never AI-accessible. |
| `signed-deploy` | Synonym for `verifier` in deploy-context narration. | Same as `verifier`. |
| `gitlab-host` | Self-hosted GitLab + artefact distribution. | Trusted by build tier; distrusted by `verifier` (signatures, not paths). |
| `prod-cluster` | User-facing Drupal sites. Receives signed deploys; runs the `prod-agent` to self-apply (ADR-0024). | Public-facing; tightly hardened. |
| `prod-agent` | The minimal, AI-free `nwp-server` agent that runs ON `prod-cluster`: pull+verify a signed bundle, apply (roll back on failure), snapshot→sanitize→publish (fail-closed PII gate), rollback, local status. A build target of `nwp`, not a separate repo (ADR-0022/0024). | Prod-trust tier. Holds exactly three one-way keys (read-only pull, write-only-own-repo publish, minisign pubkey). Zero AI code, zero control-plane creds. |

These labels are stable. Renaming a role label is a breaking change to
proposals, ADRs, and the example configs that reference it.

### Adding a new role

A proposal that introduces a new role label appends a row to this table
*in the same commit* as the proposal. The leakage gate `.gitleaksignore`
allowlist for `role-vocabulary.md:internal-bare-hostname` covers any
operator hostname mentions this file makes by necessity.

---

## 2. Style guide

These rules apply to every file under `docs/`, `lib/`, `scripts/`,
`recipes/`, and the repo root, except where noted.

1. **Never name a host directly.** Refer to roles only:
   "the `ai-host` runs Ollama" — not "mini runs Ollama".
2. **Use the role even when only one host carries it.** A solo deployment
   still has roles; future cluster scaling depends on the role
   abstraction being load-bearing.
3. **Wrap role labels in backticks** when used as identifiers in prose,
   so they're visually distinct from English words.
4. **For hardware shape, describe the *capability*, not the SKU.**
   - Good: "an APU with unified LPDDR5X memory ≥ 64 GB"
   - Bad: "Beelink Ryzen AI Max+ 395"
5. **For paths, use `$HOME/...` placeholders.** Never `/home/<username>/`.
6. **For domains, use `<gitlab-host>` or `<example.org>` placeholders.**
   Never the operator's actual domains.
7. **For operator-specific organisations** (e.g. sponsor schools),
   redact to `<sponsor-school>` or similar.
8. **For author lines on proposals and ADRs**, use
   `Robert Karsten Zaar (with AI assistance)` (the operator's full legal
   name). Never the informal short form. Never the AI model version
   string ("Claude Opus 4.X"). The AI annotation is the parenthetical;
   the model version belongs in the commit message if anywhere.

### When concrete bindings genuinely matter

A proposal whose value depends on the operator's concrete reference
deployment (typically the X-series experimental work — X02 voice agent,
X03 RAG, etc.) gets a **short private addendum** in the operator's
`nwp-instances/_proposals-private/<id>-instance.md`. The public proposal
references the addendum as "(operator's instance bindings, private)"
without disclosing the path. See `docs/proposals/X02-local-voice-agent.md`
§11 for the canonical pattern.

---

## 3. The leakage gate (P61 §4.1)

The role-vocabulary rule is enforced by `.gitleaks.toml`'s
`internal-bare-hostname` rule (`mini|metabox|met|mons|carlo|mmt`). A
contributor who tries to commit a public file that names one of these
hostnames will be blocked by the pre-commit hook (locally) and by the
`leakage-check` CI job (non-bypassable; blocks merge to `main`). See
[`CONTRIBUTING.md`](../../CONTRIBUTING.md) for install instructions.

---

## 4. Open questions

- **OQ-1.** Should the leakage rule's hostname list be narrow (only
  operator-bound names) or broad (any short alphanumeric token)? Per
  P61 §8 OQ-1: **narrow** (current). Expand on demand.
- **OQ-2.** When a contributor needs to write about their own
  deployment in an open-ended discussion (a GitHub issue, an RFC),
  what's the right pattern? Recommendation: open the RFC with their own
  role table reusing the labels in this file. Add new roles only via PR
  to this file.

---

## 5. Related

- [ADR-0020 — Tiered architecture model](../decisions/0020-tiered-architecture-model.md)
- [ADR-0021 — Public-only repo scope](../decisions/0021-public-only-repo-scope.md)
- [F32 — Tiered architecture implementation](../proposals/F32-tiered-architecture-implementation.md)
- [F33 — Repository topology refactor](../proposals/F33-repository-topology-refactor.md)
- [F34 — Role-label proposal rewrite](../proposals/F34-role-label-proposal-rewrite.md)
- [P61 — Leakage hygiene CI](../proposals/P61-leakage-hygiene-ci.md)
