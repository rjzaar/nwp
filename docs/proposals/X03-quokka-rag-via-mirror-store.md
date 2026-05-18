# X03: Local RAG for the Voice Agent via Mirror-Store Corpus

**Status:** PROPOSED
**Created:** 2026-04-11
**Author:** Robert Karsten Zaar (with AI assistance)
**Priority:** Low (scope expansion; extends X02 voice agent)
**Depends On:** [X02](X02-local-voice-agent.md) Phase 0 (direct-mic push-to-talk DONE), F21 Phase 1 (Headscale), F21 Phase 3a (`ai-host` as local-LLM agent), F24 Phase 1 (`mirror-store` as NWP mirror). F24 Phase 2 (auto-pull timer) is **rolled into X03 Phase 1** — see §5 Recommendation and §6 Phase 1.
**Breaking Changes:** None (purely additive)
**Estimated Effort:** ~7 phases; Phase 1 (corpus mirror + sync script) ≈ half-day, Phase 2 (retrieval backbone on `mirror-store`) ≈ half-day, remaining phases incremental
**Type:** OUTLIER — voice agent augmentation + non-NWP project mirroring, outside NWP's core Drupal deployment mission

> **Reference deployment.** Concrete role-to-host bindings, the specific
> set of project trees in the operator's Phase 1 corpus, and detailed
> latency / disk numbers for the operator's reference deployment live in a
> private instance addendum. The public proposal is self-contained against
> the role-label vocabulary (see [`docs/reference/role-vocabulary.md`](../reference/role-vocabulary.md)).

---

## 1. Executive Summary

### 1.1 Problem statement

The local voice agent introduced by [X02](X02-local-voice-agent.md) has
no factual grounding beyond its 8B model's pretraining and the current
conversation's history. When the operator asks the agent a question about
NWP project state ("what does F21 Phase 3 say?"), about other project
trees, about past conversations, or about reference material, the agent
either hallucinates or replies "I don't know."

The obvious fix is retrieval-augmented generation. The non-obvious
question is **where the corpus and the index should live**. The `ai-host`
(running the voice agent) is already a tenant-heavy box. Duplicating
30–50 GB of project trees and indexing them on the `ai-host` contends
with the existing voice/coding LLM tenants for disk and compute.

The `mirror-store` role (CPU-heavy, large-disk, always-on, F24 Phase 1)
is the designated home-compute tier per ADR-0017 and already serves as
NWP's tree mirror. It has enormous headroom for an index and indexer.

### 1.2 Proposed solution

Three additive pieces:

1. **Extend F24's mirror pattern to a locked shortlist of operator
   project trees.** Each project syncs via git (where a canonical remote
   exists on `gitlab-host`) or rsync (where no remote exists). Sync is
   **bidirectional** and **script-triggered**, not timer-triggered — a
   single `central-sync` script run on demand from whichever side is
   ahead. The shortlist and per-project mechanism live in the private
   instance addendum.

2. **Build a local RAG service on the `mirror-store`** that indexes the
   mirrored corpus plus the operator's working AI tool data (installed
   `SKILL.md` files and JSONL conversation history). Hybrid search via
   sqlite-vec + FTS5 with reciprocal rank fusion, served to thin clients.

3. **Wire the voice agent on the `ai-host` as a thin client.** One small
   step in the voice-agent loop, gated by a quick intent check, with
   graceful fallback when the `mirror-store` is unreachable.

Critically, **everything stays local.** Embeddings via Ollama's
`nomic-embed-text` on `mirror-store`. Vector store is `sqlite-vec` (single
file, MIT, no daemon). Keyword search is SQLite FTS5. Hybrid ranking via
reciprocal rank fusion. No cloud inference. Nothing leaves the home LAN.
The per-chunk context-prefix LLM call (Phase 5, following the Anthropic
Contextual Retrieval cookbook) uses local `llama3.1:8b` on `mirror-store`
instead of cloud Haiku.

Network overhead is ~10–30 ms per query over LAN or Headscale. The voice
pipeline is already 2–4 seconds per turn (whisper + ollama + piper); the
RAG round-trip is imperceptible inside it.

### 1.3 Relationship to X02, F24, and ADR-0017

- **X02** shipped Phase 0 (direct-mic push-to-talk) ahead of X03. X03 is
  additive: a new step in the existing voice-agent loop. It does not
  block X02 Phase 2 (Twilio/Pipecat) and does not require X02 Phase 2 to
  land first.
- **F24** established the `mirror-store` role as NWP's always-on mirror.
  X03 generalises that pattern to "everything the operator authors,"
  with the same `git fetch + merge --ff-only` contract where a canonical
  remote exists and a bounded rsync fallback where it doesn't.
- **ADR-0017** names the `mirror-store` as the home-compute tier and the
  `ai-host` as the day-to-day agent tier. Both are AI-capable, neither
  has prod access. A RAG service on `mirror-store` serving the `ai-host`
  is entirely within the existing trust boundary — no new paths cross
  the AI-tier -> `verifier` -> prod seam.

"Claude's RAG" (the Anthropic Contextual Retrieval cookbook) is the
reference technique, adapted: cookbook uses Claude Haiku to generate
per-chunk context prefixes; X03 swaps in local `llama3.1:8b` on
`mirror-store` so nothing goes to a cloud provider.

---

## 2. Goals & Non-Goals

### Goals

- Voice agent gains factual recall across NWP docs, other project trees,
  past conversations, and (optionally) reference material, with zero
  cloud inference.
- Extend the F24 mirror pattern to non-NWP project trees so `mirror-store`
  has a complete, up-to-date snapshot of everything the operator
  actively works on.
- RAG query overhead is imperceptible inside the voice pipeline
  (target: < 100 ms p50 for the full embed + hybrid search + chunk
  fetch round-trip from the `ai-host`).
- Voice agent degrades gracefully when `mirror-store` is unreachable —
  no hangs, short timeout, fall through to the current no-RAG behaviour
  with a one-word audible hint ("offline").
- Index stays fresh automatically — mtime-based reindexing on a systemd
  timer, no manual rebuilds.
- Secrets and user data never enter the corpus — explicit exclude rules
  enforced at indexer level and verified in CI.
- Optional Skills layer on top (SKILL.md procedures loaded on demand)
  so the voice agent can "know how to do" a short list of structured
  tasks in addition to "know facts about" the corpus.

### Non-Goals

- **Replacing X02 Phase 2 (Twilio/Pipecat).** X03 extends the existing
  direct-mic loop; Twilio integration proceeds independently.
- **Offline RAG on the `ai-host`.** The voice agent is a home-LAN-only
  service; there is no use case for RAG working when `mirror-store` is
  unreachable. Fallback is "no retrieval for this turn," not "local
  ai-host-sized index."
- **Exposing the `mirror-store`'s RAG service to the open internet.** The
  transport is SSH (or a Headscale-bound HTTP daemon), never a public
  port.
- **RAG over production data.** The sanitizer boundary is inviolable
  (CLAUDE.md § Threat Model). No `*.sql`, `*.sql.gz`, `settings.php`,
  `.secrets.data.yml`, or `keys/prod_*` ever enters the corpus.
- **Two-way sync between `ai-host` and `mirror-store`.** The
  `mirror-store` is the canonical mirror host; the `ai-host` holds no
  project trees.
- **Learning / fine-tuning the local LLM.** RAG is the stated technique.
  No LoRA, no continued pretraining, no custom model training.
- **Multi-user RAG access.** Single-user. Multi-tenant is out of scope.
- **Touching `verifier`, prod, or the signing path.** Out of scope as
  with all `ai-host`-side proposals.

---

## 3. Current State (generic shape)

The corpus shortlist, sync method (git vs rsync) per project, working-set
sizes, and the `~/.claude` artefacts (installed `SKILL.md` files + JSONL
conversation history) used as additional corpus roots are all
deployment-specific. See the private instance addendum for the operator's
concrete Phase 1 corpus and per-project sync method.

### 3.1 Latency budget (representative, not operator-specific)

| Stage | Typical latency |
|---|---|
| whisper.cpp base.en on a 3 s clip | ~500 ms |
| Ollama `llama3.1:8b` first-token | ~400 ms |
| Ollama `llama3.1:8b` steady state | ~25 tok/s |
| Full LLM response (50–100 tokens) | ~1.5–3 s |
| Piper TTS | ~200 ms |
| **Total turn** | **~2–4 s** |

Home LAN / Headscale ping `ai-host` <-> `mirror-store`: <1 ms typical.
HTTP or SSH round-trip: ~5–20 ms. Query embedding via nomic-embed-text
on `mirror-store`: ~30–80 ms. Hybrid search on a 100k-chunk index via
sqlite-vec + FTS5: ~20–50 ms. Chunk payload transfer: <5 ms.

**Expected RAG overhead per turn: 60–150 ms.** Voice pipeline is
2–4 seconds. Overhead is ~3–5 % of total turn time. Imperceptible.

---

## 4. Options Considered

### 4.1 Option A — Full RAG on the `ai-host` (index corpus locally)

Duplicate project trees onto the `ai-host`. Index there. Query there.
No network dependency.

**Rejected** because:

- Although the `ai-host` has plenty of RAM, duplicating 30+ GB of project
  trees onto its NVMe is wasted storage when the `mirror-store` has
  900 GB+ at ~60 % free.
- Indexing and re-embedding on the `ai-host` would compete with Ollama
  for CPU / iGPU time and degrade the voice agent's first-token latency
  — the thing X02 explicitly budgets for.
- The `ai-host` is the day-to-day agent tier (ADR-0017); adding
  "always-on indexer" as another tenant muddies its role and couples
  voice-loop availability to indexer health.

### 4.2 Option B — Full RAG on the `mirror-store`, `ai-host` as thin client (recommended)

The `mirror-store` mirrors every project tree, runs the indexer and
query service, and serves the `ai-host` over SSH or a local HTTP daemon.
The `ai-host` adds a tiny `quokka-rag-ask` wrapper to its voice loop.

**Pros:**
- Uses the right box for the right job (heavy indexing on `mirror-store`,
  light voice pipeline on `ai-host`).
- Consolidates "where do project trees live?" — `mirror-store` is the
  single mirror host for everything the operator actively authors.
- Trivially supports future clients querying the same index.
- Reversible at every step. Deleting the RAG service directory plus two
  lines in the voice-agent loop removes the whole feature.

**Cons:**
- Network dependency (mitigated: home LAN, Headscale, graceful fallback).
- Extends F24 to cover non-NWP trees — adds operational surface (more
  timers, more sync endpoints).
- Requires a sync mechanism for any project that doesn't have a canonical
  git remote today.

### 4.3 Option C — RAG on the `authoring` host

Corpus is already there; no mirror step needed.

**Rejected** because:
- F24's entire motivation was to get compute and disk load **off** the
  `authoring` host (memory-pressure crash).
- The `authoring` host isn't always on; the voice agent is.
- Duplicates the "authoring host is the critical path" problem F24 set
  out to fix.

### 4.4 Option D — Hosted RAG service (OpenAI, Pinecone, …)

**Rejected** immediately — violates CLAUDE.md § Threat Model's
local-first rule. Not considered seriously; listed for completeness.

### 4.5 Option E — Full Anthropic Skills framework only, no retrieval

Use the open-source anthropics/skills pattern (`SKILL.md` frontmatter
+ on-demand loading) without any embedding/vector layer.

**Rejected as sole solution, accepted as Phase 6 additive layer.**
Skills are good for structured procedures but cannot answer factual
recall questions. RAG is the load-bearing piece; Skills are the cherry
on top.

---

## 5. Recommendation

Take **Option B** in seven phases. Phases 1 and 2 are independently
useful — Phase 1 (corpus mirror + bidirectional sync script) is a clean
extension of F24 regardless of whether the RAG work lands. Phase 2
(retrieval backbone on `mirror-store`) is the load-bearing deliverable.
Phases 3–7 are quality improvements that can land in any order.

**F24 Phase 2 is rolled into X03 Phase 1.** F24 Phase 2's pending work
(auto-pull timer for NWP on `mirror-store`, exclude-list verification,
one-shot `authoring` -> `mirror-store` rsync) is a strict subset of what
Phase 1 below needs to do anyway, for several other project trees
simultaneously.

---

## 6. Phases

### Phase 1 — Corpus mirror and bidirectional sync script

**Goal:** `mirror-store` holds an up-to-date copy of the locked-shortlist
project trees, and the `authoring` host holds whatever changes were
authored on `mirror-store`, via a single script run on demand from
whichever side is ahead.

This phase subsumes F24 Phase 2.

**Tasks:**
- [ ] `central-sync` script (bash). For each project in the shortlist,
      detect git-remote vs rsync mechanism (per-project YAML config) and
      do the safe sync.
- [ ] One-shot first-time sync of each project to `mirror-store`.
- [ ] Excluded paths: `.secrets.data.yml`, `keys/prod_*`, `*.sql*`,
      `web/sites/default/files/`, `node_modules/`, `vendor/`, `.ddev/`,
      `**/*-private/**`.
- [ ] Verify exclude list with a synthetic `sentinel.secret` file at the
      `authoring` end; confirm `mirror-store` never receives it.

**Definition of done:** All shortlisted projects are present on
`mirror-store`; `central-sync` is idempotent; no excluded patterns
leaked.

### Phase 2 — Retrieval backbone on `mirror-store`

**Goal:** A running RAG service on `mirror-store` that indexes the
mirrored corpus, embeds with `nomic-embed-text`, stores in `sqlite-vec`,
and serves a hybrid-search query API over the home LAN.

**Tasks:**
- [ ] Indexer: walk the corpus, chunk by paragraph + structural
      heuristic, store text + metadata (path, project, mtime, sha) in
      SQLite.
- [ ] Embedder: pull `nomic-embed-text` model via Ollama; embed all
      chunks; insert into `sqlite-vec`.
- [ ] Keyword index: SQLite FTS5 over the same chunk table.
- [ ] Query API: simple HTTP daemon (or systemd-socket-activated) that
      accepts a query, embeds it, runs vector + FTS5 in parallel,
      fuses via reciprocal rank, returns top-N chunks with metadata.
- [ ] Local-only bind (`127.0.0.1` + Headscale-bound, no public port).

**Definition of done:** `curl localhost:<port>/query?q=...` returns
top-N chunks with provenance.

### Phase 3 — Voice agent thin client

**Goal:** The voice agent on the `ai-host` calls the RAG service before
constructing the LLM prompt, and threads the retrieved chunks into the
system context.

**Tasks:**
- [ ] `quokka-rag-ask` wrapper: tiny script that POSTs to the
      `mirror-store` query API.
- [ ] Voice loop integration: between STT and LLM call, run a fast
      intent check ("does this need retrieval?") and, if yes, fetch
      chunks and prepend to the system prompt.
- [ ] Timeout: 250 ms default; on timeout, skip retrieval and continue
      with a soft audible hint ("offline").
- [ ] Logging: per-turn retrieval status, chunk count, total overhead.

**Definition of done:** Voice agent answers factual-recall questions
about the corpus correctly; latency overhead is < 200 ms p50.

### Phase 4 — Index freshness

**Goal:** New / changed files on `mirror-store` are re-indexed
automatically, without operator intervention.

**Tasks:**
- [ ] Systemd timer on `mirror-store`: hourly mtime-based delta scan.
- [ ] Embed only delta chunks; sweep deleted chunks.
- [ ] Metrics: per-run count of indexed / re-indexed / deleted chunks.

### Phase 5 — Contextual retrieval (per-chunk context prefixes)

**Goal:** Apply the Anthropic Contextual Retrieval technique using local
`llama3.1:8b` on `mirror-store` to add a short context prefix to each
chunk before embedding.

**Tasks:**
- [ ] Per-chunk context-prefix generation via local LLM (50–100 tokens
      summarising the chunk's relationship to its parent document).
- [ ] Re-index the corpus with context-prefixed chunks.
- [ ] A/B: measure retrieval quality vs Phase 2 baseline on a small
      labelled set.

### Phase 6 — Skills layer (additive)

**Goal:** Optional Skills (`SKILL.md` procedures) loaded on demand by
the voice agent for structured tasks.

**Tasks:**
- [ ] Skill registry stored alongside RAG metadata.
- [ ] On voice-agent turn: if the query matches a registered skill,
      load the SKILL.md body and inject as system prompt addendum.
- [ ] Tiny scope at first: 3–5 hand-picked skills.

### Phase 7 — Operator dashboard

**Goal:** Visibility into RAG state — corpus health, index freshness,
query stats, fallback rates.

**Tasks:**
- [ ] Small static-html dashboard on `mirror-store` (read-only).
- [ ] Daily/weekly summary email to the operator with anomalies.

---

## 7. Risk Assessment

### High Risk

| Risk | Mitigation |
|---|---|
| **Secrets leak into the corpus** (forgotten exclude pattern, new project tree with unexpected layout). | Exclude list in `central-sync`; verifier in CI that re-scans the indexed corpus for high-entropy strings / known-secret patterns. Failed verifier blocks the index swap. |
| **RAG service contended with the voice LLM** (if it were ever co-located on the `ai-host`). | The whole proposal is built on Option B; the `mirror-store` is the only host that runs the indexer/embedder/query API. The `ai-host` is a thin client. |
| **`mirror-store` becomes a single point of failure** for the voice agent's intelligence. | Phase 3 timeout + graceful fallback. Voice agent works (with reduced grounding) when `mirror-store` is unreachable. |

### Medium Risk

| Risk | Mitigation |
|---|---|
| Embedding model drift if Ollama updates `nomic-embed-text` | Pin the model version in the indexer; require an explicit operator action to upgrade and reindex. |
| Index corruption on power loss | SQLite WAL + atomic index swap (rename a fully-rebuilt DB into place). |
| Stale chunks confusing answers | Phase 4 freshness sweep + per-chunk mtime in retrieval metadata; bias scoring toward recency. |

### Low Risk

| Risk | Mitigation |
|---|---|
| FTS5 + sqlite-vec compatibility | Both are battle-tested SQLite extensions; the combo is a published pattern. |
| Disk pressure on `mirror-store` | The `mirror-store` is sized for far larger workloads; the corpus + index together fit in <50 GB even with Phase 5 context prefixes. |

---

## 8. Success Criteria

- [ ] Voice agent answers a factual-recall question about NWP correctly
- [ ] Voice agent answers a factual-recall question about a non-NWP
      project tree correctly
- [ ] Total round-trip overhead from retrieval < 200 ms p50
- [ ] Graceful fallback when `mirror-store` is unreachable (one-word
      audible hint, no hang)
- [ ] Index freshness: a new commit on the `authoring` host shows up in
      retrieval within 2 hours without operator intervention
- [ ] Secret-scanner sentinel test passes — no excluded pattern ever
      reaches `mirror-store`
- [ ] All inference local — `tcpdump` on the home router during a query
      cycle shows zero outbound traffic to AI providers
- [ ] (Phase 6, optional) at least one structured Skill loaded by the
      voice agent on demand

---

## 9. Open Questions

- **Bidirectional vs one-way sync.** Recommendation: bidirectional,
  script-triggered. Justification recorded in the private addendum
  (operator's workflow is bi-hosted in practice).
- **Chunk size and overlap.** Recommendation: paragraph + 200-char
  overlap baseline; revisit in Phase 5 A/B.
- **Context-prefix prompt design.** The Anthropic cookbook template is
  the starting point; iterate in Phase 5.
- **Skills v1 selection.** Defer to Phase 6 kickoff.
- **Disk budget for the index.** Estimated < 5 GB for the Phase 1
  corpus, < 50 GB worst case after Phase 5. Confirmed against the
  `mirror-store`'s free-space headroom in the private addendum.

---

## 10. Out of Scope

- Cross-LAN access to the RAG service (Headscale only)
- Multi-user authentication beyond the operator
- Indexing transcripts/audio (would re-use the indexer trivially; not in
  scope for v1)
- Re-ranking via cross-encoder (not needed at this corpus size)
- Replacement for the operator's existing manual `grep` / `rg` workflow
  on the `authoring` host

---

## 11. Cross-references

- **[X02: Local Voice Agent](X02-local-voice-agent.md)** — the voice
  agent that X03 makes smarter
- **F21: Distributed Build/Deploy Pipeline** — defines the `ai-host`
  and `mirror-store` roles
- **F24: NWP Tree Mirror** — the mirror pattern this proposal extends
- **[ADR-0017: Distributed Build/Deploy Pipeline](../decisions/0017-distributed-build-deploy-pipeline.md)** — trust boundaries this proposal inherits
- **[CLAUDE.md § Threat Model](../../CLAUDE.md)** — local-first inference
  rule this proposal complies with

---

## 12. Reference Deployment

In the operator's deployment, the `ai-host`, `mirror-store`,
`authoring`, and `gitlab-host` role bindings are documented in the
private instance addendum (`_proposals-private/X03-instance.md` in the
operator's `nwp-instances/` overlay). The addendum also captures the
operator's Phase 1 corpus shortlist (specific project trees), per-project
sync method (git remote vs rsync), and milestone-to-commit-hash mapping.
None of that is required to understand or implement X03.
