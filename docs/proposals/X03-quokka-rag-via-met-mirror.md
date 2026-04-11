# X03: Quokka Local RAG via met Corpus Mirror

**Status:** PROPOSED
**Created:** 2026-04-11
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** Low (scope expansion; extends X02 voice agent)
**Depends On:** X02 (Local Voice Agent on mini — direct-mic push-to-talk ✅ 2026-04-09), F21 Phase 1 (Headscale ✅), F21 Phase 3a (mini as local-LLM agent ✅), F24 Phase 1 (met as NWP mirror ✅). F24 Phase 2 (auto-pull timer) is **rolled into X03 Phase 1** — see §5 Recommendation and §6 Phase 1.
**Breaking Changes:** None (purely additive)
**Estimated Effort:** ~7 phases; Phase 1 (corpus mirror + sync script) ≈ half-day, Phase 2 (retrieval backbone on met) ≈ half-day, remaining phases incremental
**Type:** OUTLIER — voice agent augmentation + non-NWP project mirroring, outside NWP's core Drupal deployment mission

---

## 1. Executive Summary

### 1.1 Problem statement

Quokka, mini's local voice agent (X02), currently has no factual
grounding beyond its 8B model's pretraining and the current
conversation's `history.json`. When Rob asks Quokka a question about
NWP project state ("what does F21 Phase 3 say about mons?"), about
other project trees (ado, theocat, …), about past conversations
("remember when we fixed the Moodle tabbed renderer?"), or about
Catholic reference material (catechism passages, saint biographies),
the agent either hallucinates or replies "I don't know."

The obvious fix is retrieval-augmented generation. The non-obvious
question is **where the corpus and the index should live**. mini is
already running ollama (llama3.1:8b resident), whisper.cpp, and piper,
plus the Phase 10 bot skeleton and gotify/quokka-toggle systemd
services. Duplicating 30–50 GB of project trees and indexing them on
mini contends with those tenants for disk and compute.

**met** (Ryzen 9 3900X, 32 GiB, 915 GB disk, ~60 % used) is the
designated home-compute tier per ADR-0017 and already serves as
NWP's build/test runner (F21 Phase 2) and the NWP tree mirror
(F24 Phase 1). It has enormous headroom for an index and indexer.

### 1.2 Proposed solution

Three additive pieces:

1. **Extend F24's mirror pattern to a locked shortlist of dev-laptop
   project trees.** The initial corpus is **nwp, theocat, logic,
   claudemax** (synced via git, with canonical remotes on
   git.nwpcode.org) and **ado** (synced via rsync, no git remote).
   Everything else listed in `~/central/README.md` (prayer, ciytools,
   carmel, …) is deferred. Sync is **bidirectional** and
   **script-triggered**, not timer-triggered — a single `central-sync`
   script run manually from whichever laptop/met side is ahead. This
   differs from F24 Phase 2's one-way pull timer design (see § 6.1
   for why this context allows two-way sync where F24's context did
   not).

2. **Build a local RAG service on met** that indexes the mirrored
   corpus plus Rob's existing `~/.claude` working data (26 installed
   SKILL.md files under `~/.claude/plugins/marketplaces/` and the
   1.6 GB of JSONL conversation history under `~/.claude/projects/`,
   spanning 28 project slugs). Hybrid search via sqlite-vec + FTS5
   with reciprocal rank fusion, served to thin clients.

3. **Wire Quokka on mini as a thin client.** One small step in the
   voice-agent loop, gated by a quick intent check, with graceful
   fallback when met is unreachable.

Critically, **everything stays local.** Embeddings via ollama's
`nomic-embed-text` on met. Vector store is `sqlite-vec` (single
file, MIT, no daemon). Keyword search is SQLite FTS5 (already in
sqlite). Hybrid ranking via reciprocal rank fusion. No cloud
inference. Nothing leaves the home LAN. The per-chunk
context-prefix LLM call (Phase 5, following the Anthropic
Contextual Retrieval cookbook) uses local `llama3.1:8b` on met
instead of cloud Haiku.

Network overhead is ~10–30 ms per query over LAN or Headscale.
Quokka's voice pipeline is already 2–4 seconds per turn (whisper +
ollama + piper); the RAG round-trip is imperceptible inside it.

### 1.3 Relationship to X02, F24, and ADR-0017

- **X02** shipped Phase 0 (direct-mic push-to-talk) on 2026-04-09.
  X03 is additive: a new step in the existing `voice-agent` and
  `quokka-netcat-handler` loops. It does not block X02 Phase 2
  (Twilio/Pipecat) and does not require X02 Phase 2 to land first.
- **F24** established met as NWP's always-on mirror. X03 generalises
  that pattern to "everything Rob authors," with the same
  `git fetch + merge --ff-only` contract where a canonical remote
  exists and a bounded rsync fallback where it doesn't.
- **ADR-0017** names met as the home-compute tier and mini as the
  day-to-day agent tier. Both are AI-capable, neither has prod
  access. A RAG service on met serving mini is entirely within the
  existing trust boundary — no new paths cross the mmt → mons → prod
  seam.

"Claude's RAG" (the Anthropic Contextual Retrieval cookbook) is the
reference technique, adapted: cookbook uses Claude Haiku to generate
per-chunk context prefixes; X03 swaps in local llama3.1:8b on met so
nothing goes to a cloud provider.

---

## 2. Goals & Non-Goals

### Goals

- Quokka gains factual recall across NWP docs, other project trees,
  past conversations, and (optionally) Catholic reference material,
  with zero cloud inference.
- Extend the F24 mirror pattern to non-NWP project trees so met has
  a complete, up-to-date snapshot of everything Rob actively works
  on.
- RAG query overhead is imperceptible inside Quokka's existing voice
  pipeline (target: < 100 ms p50 for the full embed + hybrid search
  + chunk fetch round-trip from mini).
- Quokka degrades gracefully when met is unreachable — no hangs,
  short timeout, fall through to the current no-RAG behaviour with
  a one-word audible hint ("offline").
- Index stays fresh automatically — mtime-based reindexing on a
  systemd timer, no manual rebuilds.
- Secrets and user data never enter the corpus — explicit exclude
  rules enforced at indexer level and verified in CI.
- Optional Skills layer on top (SKILL.md procedures loaded on demand)
  so Quokka can "know how to do" a short list of structured tasks
  in addition to "know facts about" the corpus.

### Non-Goals

- **Replacing X02 Phase 2 (Twilio/Pipecat).** X03 extends the
  existing direct-mic loop; Twilio integration proceeds independently.
- **Offline RAG on mini.** Quokka is a home-LAN-only voice agent;
  there is no use case for RAG working when met is unreachable.
  Fallback is "no retrieval for this turn," not "local mini-sized
  index."
- **Exposing met's RAG service to the open internet.** The transport
  is SSH (or a Headscale-bound HTTP daemon), never a public port.
- **RAG over production data.** The sanitizer boundary is inviolable
  (CLAUDE.md § Threat Model). No `*.sql`, `*.sql.gz`, `settings.php`,
  `.secrets.data.yml`, or `keys/prod_*` ever enters the corpus.
- **Two-way sync between mini and met.** met is the canonical mirror
  host; mini holds no project trees. This is the *opposite* of F24's
  decision for the dev laptop ↔ met relationship — Quokka needs a
  read-only corpus, not a working tree.
- **Learning / fine-tuning the local LLM.** RAG is the stated
  technique. No LoRA, no continued pretraining, no custom model
  training.
- **Multi-user RAG access.** Quokka is single-user (Rob). If dev
  wants to query the same index that is a cleanly separate client,
  not a multi-tenant design.
- **Touching mons, prod, or the signing path.** Out of scope as
  with all dev-side proposals.

---

## 3. Current State

### 3.1 What Quokka looks like today (post-X02 Phase 0)

- `servers/mini/bin/voice-agent` — bash push-to-talk loop
- `servers/mini/bin/quokka-netcat-handler` — netcat bridge variant
- `servers/mini/bin/quokka-toggle` — Gotify-triggered hands-free mode
- STT: `whisper.cpp` (ggml base.en, CPU)
- LLM: `ollama` with `llama3.1:8b` (and `qwen2.5-coder:14b` for code
  mode, plus a `claude` CLI shell-out branch)
- TTS: `piper` with `en_GB-alba-medium.onnx`
- Conversation memory: a JSON array in `/tmp/quokka-netcat/history.json`
  or a per-session file under `$TMPDIR_AGENT`. Linear append, no
  retrieval, truncated at context window.

Quokka has **no long-term memory** between invocations and **no
factual grounding** beyond the 8B model's pretraining.

### 3.2 What met looks like today (post-F24 Phase 1)

- Ryzen 9 3900X (12c/24t), 32 GiB, 915 GB root (~60 % used).
- Headscale node `met.nwp.headscale` — direct LAN connections <5 ms.
- F21 Phase 2 GitLab Runner installed and serving `nwp,met` tags.
- `~/nwp` checked out at `da39764` (matches dev laptop as of
  2026-04-11).
- `openai-whisper` installed via pipx (F24 Phase 1) — reusable for
  indexing transcripts if the corpus grows to include audio.
- No Docker (F24 Phase 2 blocker, separate concern).
- Per F24 § 9 Open Questions: "mini's role. Does mini also become an
  always-on-main mirror? Useful for the X02 voice agent if it grows
  to need source context." — X03 answers that question with "no,
  met is the mirror; mini is a thin client."

### 3.3 What's on dev laptop

`~/central/README.md` is the authoritative inventory of top-level
project directories. As of 2026-04-12 it lists ~25 projects with
per-project `.md` files describing purpose, machine placement, and
(ad-hoc) sync state. Rob's Phase 1 corpus shortlist:

| Project | Size | Git | Remote | Sync method |
|---|---|---|---|---|
| `~/nwp` | — | yes | `git.nwpcode.org/root/nwp` | git (F24 pattern) |
| `~/theocat` (thin core) | **29 MB** | yes | `github.com/nwpcode/theocat` (currently on GitHub; the thin core is public CC0) | git (F24 pattern) — but see § 3.3a for why theocat is split into "core sync" and "per-package install" |
| `~/logic` | 234 MB | **not git** — needs `git init` + push to `git.nwpcode.org` | — | git (after one-time conversion) |
| `~/claudemax` | 460 KB | yes | `git@git.nwpcode.org:root/claudemax.git` | git (F24 pattern) |
| `~/ado` | 562 MB | not git | — | rsync |

Deferred (listed in central but out of scope for X03 Phase 1):
prayer (14 GB, heavy), ciytools (6.7 GB, GPU workloads on met),
carmel (1.5 GB, content to be ported into theocat), cardinals, dir,
masstimes, recurric, saint_school, truth, hwp, tools, ignatius,
private (excluded), metaclaude. These can be added to the mirror
manifest later without changing the Phase 1 design.

### 3.3a Theocat is a thin core; corpus loads separately

Per `~/theocat/README.md` ("How It Works"), theocat is explicitly
designed as **four things — a registry, a manager, AI guides, and
an extension point**, *not* a corpus repo:

> The core repo does not contain theological texts directly. Instead,
> it manages independent **source packages** (content), **tool
> packages** (functionality), and **project packages** (work
> products) that you install into pluggable directories.
>
> `sources/`, `projects/`, `tools/` directories are entirely
> gitignored

Measured on dev 2026-04-12:

| Path | Size | What it is |
|---|---|---|
| `~/theocat` (minus `sources/projects/tools`) | 29 MB | Thin core: CLI, guides (3,500+ lines), registries (`sources.yaml`, `projects.yaml`, `tools.yaml`), overlay manifests. Public CC0. |
| `~/theocat/sources/aquinas` | 295 MB | Installed package (public, CC-BY-SA) |
| `~/theocat/sources/patristics-english` | 1.1 GB | Installed package (public) |
| `~/theocat/sources/reformation-doctors` | 332 MB | Installed package (public) |
| `~/theocat/sources/medieval-doctors` | 88 MB | Installed package (public) |
| `~/theocat/sources/councils` | 82 MB | Installed package (public) |
| `~/theocat/sources/{catechism,catechisms-pd,ott,modern-pd,doctors-index}` | ~18 MB total | Installed packages (public) |
| `~/theocat/sources/magisterium-private` | 1 015 MB | **Private** — `private: true` in manifest, should not be redistributed |
| `~/theocat/sources/scripture-private` | 41 MB | **Private** |
| `~/theocat/projects/{curriculum,research,pseudo-catechism}` | — | Installed public projects |
| `~/theocat/projects/{allroads-private,logic-private,school-private,Domingo_Banez}` | — | **Private** projects |
| `~/theocat/tools/{catalog,citation-checker,doc-generator,quote-verifier}` | — | Installed tools |

This splits theocat's role in Phase 1 into **two layers** that are
handled by two different mechanisms:

1. **Thin core (29 MB)** — synced via `central-sync` like any other
   git repo. Contains registries, AI guides, and the CLI. Rarely
   changes. Bidirectional sync is trivial and safe.
2. **Installed packages (~3 GB of public content + ~1 GB of private
   content)** — **not synced via central-sync.** Instead, met runs
   theocat's native install mechanism (`./bin/theocat install
   bundle essential`, etc.) to clone each public package from its
   own upstream git remote directly onto met. `theocat update`
   keeps them fresh. The packages are *already* independent git
   repos with their own remotes — any bidirectional-sync attempt
   would duplicate the package's own update mechanism and create
   two conflicting sources of truth.

**Private packages (`*-private` under sources, projects, tools)**
are treated as out of scope for X03 Phase 1. They can be installed
on met later by hand once Rob decides whether met's trust zone is
the same as dev's for that material. The default posture is "no
private-flag content on met until Rob says otherwise." The RAG
indexer's exclude list has `**/*-private/**` as a hard block to
prevent accidental indexing even if a private package does end up
on met.

Net effect for RAG: Quokka on met queries an indexed corpus of
(a) the thin core's AI guides and registries, and (b) the
public installed packages (~3 GB), all fetched and updated by
theocat's own tooling on met. No new mechanism, no duplication,
and private content stays off met until explicitly authorised.

### 3.4 What's in `~/.claude` on dev

Discovered 2026-04-11 while sizing Phase 6 / Phase 7:

- **26 installed SKILL.md files** under
  `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/*/skills/*/SKILL.md`
  — e.g. `skill-creator`, `claude-md-improver`, `session-report`,
  `frontend-design`, `writing-rules`, `build-mcp-server`,
  `math-olympiad`. Each is a markdown file with YAML frontmatter
  (`name`, `description`) and a long procedural body. Ideal RAG
  input: structured, descriptive, bounded.
- **1.6 GB of JSONL conversation history** under
  `~/.claude/projects/`, spanning 28 project slugs. `~/nwp` alone
  has 294 MB / 34 sessions. Each JSONL line is one event
  (user message, assistant message, tool call, file snapshot) with
  `timestamp`, `sessionId`, `cwd`, `gitBranch` metadata — trivial to
  parse, chunk by session or by turn, and index.

These two sources (skills + conversation history) answer Rob's
follow-up request to "analyse all the current claude skills on this
dev machine and all conversations to create the RAG infrastructure
for mini's llm quokka." They become first-class corpus roots in
Phase 2 and re-shape Phases 6 and 7 — see § 6.

### 3.5 Latency budget

Measured in the X02 Phase 0 / F21 Phase 3a work:

| Stage | Typical latency |
|---|---|
| whisper.cpp base.en on a 3 s clip | ~500 ms |
| ollama `llama3.1:8b` first-token | ~400 ms |
| ollama `llama3.1:8b` steady state | ~25 tok/s |
| Full LLM response (50–100 tokens) | ~1.5–3 s |
| piper TTS | ~200 ms |
| **Total turn** | **~2–4 s** |

Home LAN / Headscale ping between mini and met: <1 ms typical.
HTTP or SSH round-trip: ~5–20 ms. Query embedding via nomic-embed-text
on met: ~30–80 ms. Hybrid search on a 100k-chunk index via
sqlite-vec + FTS5: ~20–50 ms. Chunk payload transfer: <5 ms.

**Expected RAG overhead per turn: 60–150 ms.** Voice pipeline is
2–4 seconds. Overhead is ~3–5 % of total turn time. Imperceptible.

---

## 4. Options Considered

### 4.1 Option A — Full RAG on mini (index corpus locally on mini)

Duplicate ado, nwp, theocat, etc. onto mini. Index on mini. Query
on mini. No network dependency.

**Rejected** because:

- Although mini has plenty of RAM (128 GB unified LPDDR5X per
  `~/central/README.md`), duplicating 30+ GB of project trees onto
  mini's NVMe is wasted storage when met has 915 GB at ~60 % free.
- Indexing and re-embedding on mini would compete with ollama for
  CPU / iGPU time and degrade the voice agent's first-token latency
  — the thing X02 explicitly budgets for.
- mini is the day-to-day agent tier (ADR-0017); adding "always-on
  indexer" as another tenant muddies its role and couples voice-loop
  availability to indexer health.
- F24 already took the position that mini *might* become a mirror
  "if the X02 voice agent grows to need source context" and flagged
  it as open. X03 closes that question by picking the opposite
  design: met holds the corpus, mini stays a thin client.

### 4.2 Option B — Full RAG on met, mini as thin client (recommended)

met mirrors every project tree, runs the indexer and query service,
and serves mini over SSH or a local HTTP daemon. mini adds a tiny
`quokka-rag-ask` wrapper to its voice loop.

**Pros:**
- Uses the right box for the right job (heavy indexing on met,
  light voice pipeline on mini).
- Consolidates "where do project trees live?" — met is the single
  mirror host for everything Rob actively authors.
- Trivially supports future clients (dev laptop's Claude Code
  sessions, a future mons-side diagnostic tool) querying the same
  index.
- Reversible at every step. Deleting `servers/met/quokka-rag/`
  plus two lines in `voice-agent` and `quokka-netcat-handler`
  removes the whole feature.

**Cons:**
- Network dependency (mitigated: home LAN, Headscale, graceful
  fallback).
- Extends F24 to cover non-NWP trees — adds operational surface
  (more timers, more sync endpoints).
- Requires an answer to "how do ado / theocat / … get to met?"
  for each one that doesn't have a canonical git remote today.

### 4.3 Option C — RAG on dev laptop

Corpus is already there; no mirror step needed.

**Rejected** because:
- F24's entire motivation was to get compute and disk load **off**
  the laptop (memory-pressure crash 2026-04-11).
- Laptop isn't always on; Quokka is. Dependency inversion.
- Duplicates the "laptop is the critical path" problem F24 set
  out to fix.

### 4.4 Option D — Hosted RAG service (OpenAI, Pinecone, …)

**Rejected** immediately — violates CLAUDE.md § Threat Model's
local-first rule. Not considered seriously; listed for completeness.

### 4.5 Option E — Full Anthropic Skills framework only, no retrieval

Use the open-source anthropics/skills pattern (`SKILL.md` frontmatter
+ on-demand loading) without any embedding/vector layer.

**Rejected as sole solution, accepted as Phase 6 additive layer.**
Skills are good for structured procedures ("how to pray the rosary")
but cannot answer factual recall questions ("what did the F21 Phase 2
commit message say?"). RAG is the load-bearing piece; Skills are
the cherry on top.

---

## 5. Recommendation

Take **Option B** in seven phases. Phases 1 and 2 are independently
useful — Phase 1 (corpus mirror + bidirectional sync script) is a
clean extension of F24 regardless of whether the RAG work lands.
Phase 2 (retrieval backbone on met) is the load-bearing deliverable.
Phases 3–7 are quality improvements that can land in any order.

**F24 Phase 2 is rolled into X03 Phase 1.** F24 Phase 2's pending
work (auto-pull timer for `~/nwp` on met, exclude-list verification,
one-shot laptop→met rsync) is a strict subset of what Phase 1 below
needs to do anyway, for four other project trees simultaneously.
Rather than land F24 Phase 2 first and then redo the same pattern
for ado / theocat / logic / claudemax a week later, X03 Phase 1
ships a single `central-sync` script that handles all five projects
(including nwp) in one mechanism. F24 Phase 2 closes as
"superseded by X03 Phase 1" once X03 Phase 1 lands.

---

## 6. Phases

### Phase 1 — Corpus mirror and bidirectional sync script

**Goal:** met holds an up-to-date copy of the locked-shortlist
project trees (nwp, theocat, logic, claudemax, ado), and the dev
laptop holds whatever changes were authored on met, via a single
script run on demand from whichever side is ahead.

This phase subsumes F24 Phase 2 (see § 5 Recommendation).

#### 6.1 Why bidirectional, and why this differs from F24

F24 § 4.4 explicitly **rejected** two-way sync for the dev-laptop
↔ met relationship on the grounds that (a) `.git` object state
would diverge if both sides committed independently, (b) uncommitted
working trees would fight each other, and (c) it solved a problem
F24 did not have at the time (F24 wanted "get compute off the
laptop," which is strictly dev→met).

X03's context is materially different:

- **Workflow is now bi-hosted.** F21 Phase 3a and F24 Phase 1
  established mini / met as real working nodes that may run Claude
  Code sessions and produce commits of their own (docs, scripts,
  experiments). A one-way laptop→met sync would discard that work.
- **The corpus isn't `~/nwp` alone any more.** ado has no git at
  all; theocat and logic will have git remotes *after* Phase 1 but
  currently do not; claudemax already has one. A uniform one-way
  pull would require every project to be a git repo with a canonical
  remote, which is a larger up-front change than the user has
  approved.
- **Sync is script-triggered, not timer-triggered.** The F24 timer
  design assumed a single canonical source and a single frequent
  consumer. A manually-invoked `central-sync` script is inherently
  serialised (no two copies race) and gives the operator an
  explicit "I am about to converge state" checkpoint, which is the
  point where `.git` divergence can be noticed and resolved like
  any other merge conflict. This sidesteps F24's race-condition
  objection.
- **Per-project rules handle the remaining risks.** For git repos
  (nwp, theocat, logic, claudemax) the script does `git fetch` on
  both sides, refuses to auto-merge if either side is behind/ahead
  of the other and instead reports the divergence for human
  resolution, and only rsyncs working-tree files that are
  untracked-but-wanted (e.g. build output intentionally kept out of
  git). For non-git projects (ado) the script uses `rsync -auv`
  with `--delete` disabled (never destructive) and mtime-based
  conflict resolution.

The net effect: X03's two-way script has a narrower race window
than F24's rejected two-way design, because it runs at
human-initiated checkpoints rather than continuously, and because
git repos handle their own divergence detection rather than relying
on blanket file-level sync.

#### 6.2 The `central-sync` script

Single entry point on both laptop and met:

```
central-sync [--dry-run] [--project=<name>] [--direction=auto|push|pull]
             [--auto-rebase]
             [--claude-review[=local|haiku]] [--apply]
```

- Reads `servers/met/mirror/manifest.yml` to find the project list,
  each project's type (`git` or `rsync`), each project's exclude
  globs, and each project's peer path on the other side.
- For `git` projects: on each side, `git fetch` both directions,
  report commits ahead / behind. If one side is strictly ahead,
  fast-forward the other. If both sides have diverged, handle per
  § 6.2.1 below.
- For `rsync` projects: `rsync -auv` laptop→met first, then met→laptop,
  both passes with the shared exclude list and `--delete` **disabled**.
- Pre-sync hook: run the secret-exclusion check
  (`servers/met/mirror/check-no-secrets.sh`) against the file set
  each `rsync` invocation is about to move. Reject the sync if any
  path matches a secret glob — **never silently strip, always
  refuse and report.**
- Transport: SSH over Headscale
  (`ssh -o ControlPersist=10m met.nwp.headscale`).
- Exit codes: 0 = all projects converged, 1 = one or more projects
  need human resolution, 2 = secret-exclusion check failed.

##### 6.2.1 Git divergence handling — refuse-and-report default, opt-in auto-rebase

Three cases when `git fetch` finishes:

1. **One side strictly ahead** (the common case). `central-sync`
   fast-forwards the behind side. No user interaction. Silent.
2. **Both sides strictly behind a common origin** (neither has
   local commits; both just need to pull). Fast-forward both from
   origin. Silent.
3. **Both sides have local commits the other doesn't.** This is
   the divergence case. Two policies, picked per invocation:

   **Default — refuse and report.**
   `central-sync` prints a human-readable summary for the diverged
   project ("`~/nwp`: laptop ahead by 3 commits, met ahead by 2
   commits; earliest divergence at <sha>; touched files <list>"),
   exits non-zero on that project (others continue), and leaves
   both working trees untouched. Rob resolves by hand on whichever
   side he considers the correct base: `git rebase` or `git merge`
   as appropriate, then re-runs `central-sync`. Zero risk of
   auto-rebase corrupting history or producing surprising semantic
   conflicts. This is the sane default because divergence is
   almost always a signal that two Claude sessions edited the same
   area of the code and a human should look at the diff.

   **Opt-in — `--auto-rebase`.**
   When the operator passes `--auto-rebase`, `central-sync` will
   attempt an automatic rebase **only when all three of these are
   true** for a given diverged project:
   - The side with fewer unique commits has **not yet pushed**
     those commits to any remote (checked via `git log
     origin/<branch>..HEAD` on that side — if the ahead-commits
     haven't been published, rewriting them locally is safe).
   - The rebase runs in a scratch worktree (`git worktree add`
     to a tmp dir) so the live tree is never left in a broken
     mid-rebase state.
   - The rebase completes with **zero conflicts**. Any conflict
     (even trivial ones) aborts the rebase, removes the scratch
     worktree, and falls back to refuse-and-report for that project.

   If the rebase succeeds cleanly, `central-sync` applies the
   rebased commits to the real branch on the appropriate side,
   then fast-forwards the other side as in case 1. The operator
   sees "`~/nwp`: auto-rebased 2 commits on met onto laptop's
   head — 0 conflicts" in the summary.

   **`--auto-rebase` is never the default** because it rewrites
   commit hashes, which can surprise a human who was about to
   `git push` those commits from the original side. The opt-in
   gate makes the operator acknowledge "yes, I want the script
   to rewrite local history when it's safe to do so."

   **`--auto-rebase` never runs on `~/nwp`.** NWP commits are
   signed (per CLAUDE.md threat model) and the signing workflow
   assumes commits are not rewritten after the fact. The manifest
   has a per-project `allow_auto_rebase: false` flag that blocks
   `--auto-rebase` regardless of CLI invocation; `~/nwp` sets it
   to false, other projects default to true. `~/ado` is rsync-type
   so the flag is moot.

##### 6.2.2 Divergence review with `--claude-review` (Claude as advisor)

`--auto-rebase` only helps when a rebase is textually clean. It
doesn't help when divergence needs *judgment* — which side is the
refinement, which Claude Code session produced each commit, whether
the two commits are adjacent independent work or competing
implementations of the same thing. Git alone can't see this, but a
Claude session with access to the diffs + the
`~/.claude/projects/*` session metadata can.

`--claude-review` adds a third mode: when divergence is detected,
`central-sync` shells out to Claude with a structured prompt and
gets back a structured verdict. **Default behaviour is advisory
only** — the verdict is printed, central-sync exits non-zero for
that project just like refuse-and-report, and the human decides
whether to accept the recommendation. `--apply` is a separate
opt-in that allows central-sync to execute the verdict when every
safety gate is satisfied.

**Inputs sent to Claude:**
- Commit list + full diffs for both sides of the divergence
- Commit author timestamps
- Working-tree `mtime`s for every touched file
- Relevant `~/.claude/projects/*` session windows (start and end
  timestamps, `cwd` matches, `gitBranch` matches) to show which
  Claude Code sessions produced each side's commits
- The project's manifest entry (so Claude knows the
  `allow_auto_rebase` / `allow_claude_review_apply` posture)

**Verdict JSON schema:**

```json
{
  "verdict": "clean_rebase_met_onto_laptop"
           | "clean_rebase_laptop_onto_met"
           | "fast_forward_met"
           | "fast_forward_laptop"
           | "manual_resolution_required",
  "confidence": "high" | "medium" | "low",
  "rationale": "natural-language explanation, 2–6 sentences",
  "touched_files": ["path/to/file1", "path/to/file2"],
  "session_evidence": {
    "laptop_sessions": ["<sessionId> at <start>–<end>"],
    "met_sessions": ["<sessionId> at <start>–<end>"]
  }
}
```

Unparseable or malformed JSON is treated as
`manual_resolution_required` with `confidence: low` — Claude is
allowed to be unreliable; `central-sync` is not.

**Model choice.**
- **`--claude-review` (no argument) / `--claude-review=local`:**
  default. Uses the local LLM appropriate for whichever side
  `central-sync` runs from:
  - **From dev with a live Claude Code session attached** (§ 6.2.3):
    the review is dispatched **in-session** as a tool call back to
    the running Claude Code instance. The verdict appears inline
    in the session, Rob sees the reasoning in context, and can ask
    follow-ups ("show me the diff for that commit", "what did I
    write in the met session at 10:45?") before acting.
  - **From met (or detached dev):** out-of-band call to local
    `llama3.1:8b` on met via `ollama /api/chat`. Fresh context,
    same JSON contract.
- **`--claude-review=haiku`:** opt-in cloud touchpoint. Uses
  Anthropic Haiku via API for harder cases where local-llama's
  reasoning is visibly thin. Same explicit-cloud posture as the
  Stage 2 digest pipeline in § 6.3a. Not the default; requires
  the operator to type the flag.

**Advisory by default.** Without `--apply`, `central-sync
--claude-review` does exactly what refuse-and-report does for
exit codes and working-tree state — *nothing is rewritten* — but
the summary printed to the terminal is the Claude verdict
(rationale, confidence, touched files, session evidence) rather
than a mechanical "laptop ahead by 3, met ahead by 2" line. Rob
reads, decides, and either re-runs with `--auto-rebase` (if
Claude recommends a clean rebase and Rob agrees) or resolves by
hand.

**Opt-in `--apply`.** `central-sync --claude-review --apply`
executes the verdict *only* when **all** of the following are
true:

- `verdict` ∈ {`fast_forward_met`, `fast_forward_laptop`,
  `clean_rebase_met_onto_laptop`, `clean_rebase_laptop_onto_met`}
- `confidence` = `high`
- The project's manifest has `allow_claude_review_apply: true`
- For rebase verdicts, **all the `--auto-rebase` safety gates also
  pass** (scratch worktree, unpushed commits only, zero textual
  conflicts). `--claude-review --apply` never bypasses a safety
  gate; it layers on top of them.

If any gate fails, `--apply` silently downgrades to advisory for
that project — the verdict prints, the project exits non-zero, no
history is rewritten.

**`--claude-review --apply` never runs on `~/nwp`.** The manifest
sets `allow_claude_review_apply: false` on `~/nwp`, same rationale
as `allow_auto_rebase: false`: signed commits, threat model, the
`mmt → mons` seam assumes commits are not rewritten by an AI
agent. Advisory-mode `--claude-review` *does* run on `~/nwp` —
reading diffs and producing a rationale is safe and useful — but
`--apply` is a hard stop.

**Limitations worth being honest about:**

- Review adds 2–5 s of latency per diverged project on local
  llama3.1:8b, ~1 s on Haiku.
- Running `central-sync` from met and from dev can produce
  different rationales for the same divergence (different models,
  different session context). Both should converge on the same
  safe verdict, but the prose will differ.
- Timing signal is informative, not decisive. "Newer wins" is a
  heuristic; the human might deliberately commit an experimental
  commit after the real work. Claude's job is to *surface* the
  timing, not to rule by it.
- The verdict JSON is only as reliable as Claude's prompt-following.
  Budget for occasional malformed output and treat it as
  `manual_resolution_required`.
- Determinism: the same divergence run twice may produce two
  different rationales (and in rare cases two different verdicts).
  The `--apply` gates guarantee that a non-deterministic verdict
  can never silently rewrite history — at worst, one run applies a
  clean rebase and the next run finds no divergence to act on.

##### 6.2.3 In-session dispatch from dev

When `central-sync` is invoked as a tool call from within a running
Claude Code session on the dev laptop, the `--claude-review`
pathway short-circuits its model call and passes the divergence
prompt **back to the caller session** as a structured tool result.
Concretely:

- `central-sync` detects in-session invocation by inspecting the
  process parents for a Claude Code runner, or by checking a
  `CLAUDE_SESSION_ID` environment variable Claude Code sets on
  tool execution. (Whichever mechanism is stable at the time
  Phase 1 is built — this is a Phase 1 implementation detail, not
  a design commitment.)
- When in-session invocation is detected and `--claude-review` is
  passed, `central-sync` emits the divergence prompt as its own
  *non-fatal tool output* (stderr or a dedicated JSON stream) and
  exits non-zero. The calling Claude Code session sees the output
  as part of the tool result, reads the divergence context
  inline, and continues the conversation — Rob sees the reasoning
  in the same session where he just ran the sync, with full
  access to read/grep tools to investigate further.
- When in-session invocation is **not** detected (plain terminal,
  or called from met), `central-sync` falls back to the
  out-of-band call described in § 6.2.2 (local llama3.1:8b on
  met, or Haiku if `--claude-review=haiku`).

**Why in-session is the default from dev.** Rob is already in
conversation with Claude; handing the divergence to that same
conversation is strictly better than spawning a fresh one. The
caller session has the accumulated context of the day's work,
can reference the same files Rob just edited, and can answer
follow-up questions like "show me the diff at <sha>" or
"what did the met session at 10:45 say about this function?"
without re-reading the context from scratch. The out-of-band
mode exists for met-side invocations and for cases where Rob
runs `central-sync` from a plain terminal with no Claude Code
session attached.

**`--apply` semantics in-session.** When `--apply` is passed and
the session decides (after reading the divergence context) that
a clean rebase is the right call, the session has two ways to
act on it: (a) re-invoke `central-sync` with the verdict as
explicit arguments (`central-sync --claude-review=verdict-file
--apply`), or (b) directly invoke git in the session with the
operator watching. Both are acceptable — the session, like the
operator, is just another authorised actor with the same safety
gates applied. The manifest's `allow_claude_review_apply: false`
on `~/nwp` still holds.

#### 6.3 Phase 1 work items

1. **One-time prep.**
   - `~/theocat` thin core: already has a git remote
     (`github.com/nwpcode/theocat`). Mirror that remote to
     `git.nwpcode.org/root/theocat` as a second remote so the
     project fits into the `git.nwpcode.org`-backed sync pattern
     alongside the others. The thin core is public CC0; no private
     content is moved.
   - `~/logic`: `git init` + first commit + push to
     `git.nwpcode.org/root/logic`.
   - Confirm `~/nwp` and `~/claudemax` already have their remotes.
   - Confirm `~/ado` has none (intentional — rsync track).
   - On met: `./bin/theocat install bundle essential` plus any
     additional public source bundles Rob wants Quokka to recall
     over. Private packages are **not** installed on met by
     default. Theocat's own `update` command keeps these fresh;
     `central-sync` does *not* touch `~/theocat/sources/`,
     `~/theocat/projects/`, or `~/theocat/tools/`.
2. Create `servers/met/mirror/manifest.yml` with the five projects
   plus a sixth entry for `~/.claude` (dev→met **one-way** rsync,
   read-only on met — see Phase 2 for why this is a corpus root),
   their sync types, peer paths, and exclude globs. Reference
   `~/central/README.md`'s project list as the upstream inventory
   the manifest is derived from.
3. Implement `servers/met/mirror/central-sync` (bash, runs on
   either side; installed via symlink as `~/bin/central-sync` on
   both laptop and met). Includes the refuse-and-report default
   (§ 6.2.1), the `--auto-rebase` opt-in (§ 6.2.1), and the
   `--claude-review` advisor mode (§ 6.2.2) with in-session
   dispatch detection (§ 6.2.3).
4. Implement `servers/met/mirror/check-no-secrets.sh` — reads the
   exclude-glob list from the manifest, walks a staged path set,
   fails loudly on match. Called by `central-sync` before each
   rsync pass.
5. Implement `servers/met/mirror/claude-review.sh` — the
   `--claude-review` dispatcher. Detects in-session vs out-of-band
   invocation, builds the structured prompt (diffs + timestamps +
   `~/.claude/projects/*` session windows + manifest entry),
   either emits it as a non-fatal tool-result stream (in-session
   from dev) or shells it to local `llama3.1:8b` on met / Haiku
   API, parses the returned JSON verdict, and hands back to
   `central-sync` for advisory print or gated `--apply` execution.
6. One-shot sync of each project tree to `~/mirror/<project>/` on
   met. For the four git projects, this is effectively the same
   work F24 Phase 2's one-shot step would have done for `~/nwp`.
7. Manual smoke test: edit a file on laptop, run `central-sync`,
   confirm the file appears on met. Edit a file on met, run
   `central-sync` from met, confirm it appears on laptop. Edit the
   same file on both sides, confirm the script reports divergence
   and exits non-zero without data loss. Then re-run with
   `--claude-review` from inside a Claude Code session and confirm
   the verdict appears inline with usable rationale.
8. Document the contract in `docs/guides/central-sync.md` (new):
   how to run, how to recover from divergence, how the three
   divergence modes interact (refuse-and-report, `--auto-rebase`,
   `--claude-review`), how to add a project to the manifest, how
   the secret-exclusion check is enforced, where the logs land,
   and the per-project `allow_auto_rebase` / `allow_claude_review_apply`
   manifest flags with their default values.

**Deliverables:**
- `docs/guides/central-sync.md` — operator runbook
- `servers/met/mirror/manifest.yml` — five projects locked, exclude
  globs, peer paths, sync types, per-project
  `allow_auto_rebase` + `allow_claude_review_apply` flags
  (both default false on `~/nwp`, default true on
  `claudemax`/`theocat`/`logic`, moot on `ado` which is rsync)
- `servers/met/mirror/central-sync` — bash entry point (≈ 400 LOC
  with the three divergence modes)
- `servers/met/mirror/check-no-secrets.sh` — secret-exclusion
  enforcer (≈ 50 LOC)
- `servers/met/mirror/claude-review.sh` — divergence advisor
  dispatcher (≈ 200 LOC), plus a fixed prompt template at
  `servers/met/mirror/claude-review-prompt.md` (versioned so
  changes are auditable)
- `~/mirror/{nwp,theocat,logic,claudemax,ado}/` on met (working
  trees, not in NWP git)
- `~/mirror/claude/` on met — a read-only rsync mirror of
  `~/.claude/plugins/` and `~/.claude/projects/` from dev, updated
  whenever `central-sync` runs. Excluded: `~/.claude/shell-snapshots/`,
  `~/.claude/file-history/`, `~/.claude/tasks/`, caches, and
  anything under `~/.claude/plugins/marketplaces/*/external_plugins/*/.git/`.
- F24 Phase 2 marked **superseded by X03 Phase 1** in
  `F24-relocate-dev-tree-to-met.md` once this phase lands.

### Phase 2 — Retrieval backbone on met

**Goal:** A working hybrid search over the mirrored corpus, callable
from mini, end-to-end latency under 150 ms LAN RTT.

1. `ollama pull nomic-embed-text` on met.
2. Python venv at `~/quokka-rag/venv` on met. `pip install
   sqlite-vec`. SQLite FTS5 is already built in.
3. `servers/met/bin/quokka-rag-index` — walks the configured corpus
   roots, chunks markdown / text / code by ~500-token windows with
   50-token overlap, embeds each chunk via ollama's `/api/embeddings`
   against `nomic-embed-text`, stores rows in `~/quokka-rag/index.db`
   (table with `content`, `path`, `mtime`, `source_kind`,
   `embedding BLOB`, plus a parallel FTS5 virtual table for lexical
   search). Initial corpus roots:
   - `~/mirror/` — the five Phase 1 project trees
   - `~/theocat/sources/` and `~/theocat/projects/` on met —
     the installed public theological packages (~3 GB), *not*
     routed through `central-sync` but through theocat's own
     `./bin/theocat update` (see § 3.3a). Indexed under
     `source_kind=theocat`.
   - `~/quokka-rag/skills-catalog/` — the 26 installed SKILL.md
     files after catalog extraction (see Phase 6), indexed with
     `source_kind=skill` so the query layer can boost or filter.
   - `~/quokka-rag/claude-digests/` — **not** the raw JSONL, but
     the digested outputs of § 6.3a below. Indexed with
     `source_kind=claude_history`.
   - The `~/.claude` source tree is mirrored dev→met via a
     dedicated one-way rsync entry in the Phase 1 `central-sync`
     manifest (dev is the only writer), and feeds the § 6.3a
     digest pipeline; it is **not** indexed directly.
4. `servers/met/bin/quokka-rag-query` — takes a question as its
   single argument, embeds the query, runs vector search via
   sqlite-vec, runs FTS5 lexical search, fuses with reciprocal
   rank fusion (`score = sum(1 / (60 + rank))`), returns the top-K
   chunks as JSON on stdout.
5. Incremental re-indexing: compare each source file's mtime to
   the indexed mtime, only re-embed changed chunks.
6. `servers/met/quokka-rag/config.yml` — corpus roots, chunk size,
   overlap, top-K default, exclude globs (shares the secret
   exclusion contract from Phase 1).
7. Manual smoke test from met: `quokka-rag-query "What does F21
   Phase 3 say about mons?"` → relevant chunks come back in under
   100 ms.

**Deliverables:**
- `servers/met/bin/quokka-rag-index` (Python, ~200 LOC)
- `servers/met/bin/quokka-rag-query` (Python, ~100 LOC)
- `servers/met/quokka-rag/config.yml`
- `~/quokka-rag/index.db` on met (not in git)
- `docs/guides/quokka-rag.md` — operator runbook (install, index,
  query, troubleshoot)

#### 6.3a `~/.claude` digest pipeline — two-stage LLM preprocessing

Indexing the raw 1.6 GB of `~/.claude/projects/**/*.jsonl` directly
would bury the useful signal under tool-call metadata, file-history
snapshots, system reminders, and thinking blocks. Per the
2026-04-12 design follow-up — "can't [the SKILL.md files + 1.6 GB
JSONL] be processed by claude to provide the essential bits for
quokka's RAG?" — the JSONL corpus is preprocessed before it enters
the index.

Two stages, run in order on met:

**Stage 1 — mechanical strip (no LLM, fast).**
- `servers/met/bin/quokka-claude-strip` (Python, ~150 LOC).
- Walks `~/mirror/claude/projects/**/*.jsonl` (rsync'd from dev by
  `central-sync`).
- Parses each JSONL line. Keeps only entries of type `user` or
  `assistant`. For assistant entries, extracts just the text content,
  dropping `tool_use` blocks, `tool_result` blocks, `thinking`
  blocks, and system reminders. Preserves per-turn metadata
  (`timestamp`, `sessionId`, `cwd`, `gitBranch`).
- Emits one markdown file per session at
  `~/quokka-rag/claude-stripped/<project-slug>/<sessionId>.md` with
  a YAML frontmatter header (session id, project, first/last
  timestamps, turn count, cwd, gitBranch) and alternating
  `[user]` / `[assistant]` blocks for the text.
- Typical reduction: raw JSONL → stripped markdown ≈ 4–6× smaller,
  roughly 300–400 MB from 1.6 GB of input. No LLM cost; runs in
  seconds to minutes depending on disk speed.

**Stage 2 — LLM digest (local `llama3.1:8b` on met).**
- `servers/met/bin/quokka-claude-digest` (Python, ~200 LOC).
- For each stripped session markdown, calls ollama
  `/api/chat` against `llama3.1:8b` on met with a fixed digest
  prompt: *"Summarize this Claude Code session in 150–300 words.
  Include: (1) the problem being solved, (2) the decisions made
  and why, (3) the files or components touched, (4) any reusable
  insights or gotchas. Be terse. Do not invent detail that isn't
  in the transcript."*
- Writes the digest to
  `~/quokka-rag/claude-digests/<project-slug>/<sessionId>.md`
  with frontmatter carrying the source session metadata plus a
  `digest_model: llama3.1:8b` tag and a pointer back to the
  stripped markdown file.
- Idempotent: skip sessions whose digest file is newer than the
  stripped input.
- Budget: ~500–1 000 sessions × ~2 s per local-LLM call ≈ 15–40
  minutes for the initial pass. Incremental thereafter as new
  `central-sync` runs drop new stripped files in.
- Optional upgrade (6.3a-b): use Anthropic Haiku via API for the
  digest pass if local-llama digests are visibly thin. The API
  call is the *only* cloud touchpoint X03 proposes, and it's
  clearly opt-in. Default is local.

**What the indexer actually embeds.**
- `~/quokka-rag/claude-digests/**/*.md` — primary. ~1–2 MB total,
  trivially cheap to re-embed in full on schema changes. Gives
  Quokka answers to "what did we decide about X", "when did we
  last work on Y", "why did we pick approach Z".
- `~/quokka-rag/claude-stripped/**/*.md` — **parent-document**
  layer. When a digest chunk matches a query, the indexer can
  surface the stripped parent on demand so Quokka answers from
  the full transcript rather than the summary alone. This is the
  Anthropic parent-document / small-to-big RAG pattern.
- `~/.claude/plugins/marketplaces/**/skills/*/SKILL.md` — indexed
  as-is. SKILL.md files are already distilled and have YAML
  frontmatter; no preprocessing needed. Catalog extraction
  (Phase 6) produces `skills-catalog.json` separately for the
  Skills layer.

**Why two stages and not one.**
Stage 1 is cheap, deterministic, and reversible — useful
regardless of whether Stage 2 ever runs. If Stage 2's digest
prompt turns out to be wrong, Stage 1's output is untouched and
Stage 2 can be re-run with a new prompt for pennies of CPU. If
Stage 2 were bundled into Stage 1, prompt changes would require
re-parsing the raw JSONL each time.

**Secret-exclusion still applies.** The Phase 1 secret-exclusion
check runs before `~/.claude` is rsync'd to met. Stage 1 and
Stage 2 both operate on the already-scrubbed mirror, so no
`.env`, `.secrets.yml`, or similar can appear in a digest via a
tool-result block.

**Deliverables for § 6.3a:**
- `servers/met/bin/quokka-claude-strip` (Python, ~150 LOC)
- `servers/met/bin/quokka-claude-digest` (Python, ~200 LOC)
- `servers/met/quokka-rag/digest-prompt.md` — the fixed prompt
  Stage 2 uses (versioned so changes are auditable)
- `~/quokka-rag/claude-stripped/` on met (not in git)
- `~/quokka-rag/claude-digests/` on met (not in git)
- systemd timer on met: `quokka-claude-digest.timer` — runs
  after `central-sync` completes, incremental only (not in git).

### Phase 3 — Wire Quokka on mini as a thin client

**Goal:** mini's `voice-agent` and `quokka-netcat-handler` call
the met service before `ask_ollama`, gated by a lightweight intent
check, with graceful fallback on failure.

1. `servers/mini/bin/quokka-rag-ask` — wrapper that runs
   `ssh -o ControlMaster=auto -o ControlPersist=10m -o ConnectTimeout=2
   met.nwp.headscale quokka-rag-query "$1"` with a 2-second overall
   timeout. Prints the JSON result on success, exits non-zero on
   timeout or transport failure.
2. Intent gate: a 20–30-line bash function `needs_retrieval()` that
   pattern-matches the user's transcript against "question-ish"
   heuristics (`what|how|when|where|why|who|remind|recall|find`,
   keyword matches for project names, explicit "search for…"
   phrasing). Chitchat ("hello", "good morning", "switch to code")
   skips retrieval entirely.
3. In `ask_ollama`: if `needs_retrieval "$text"` returns true,
   call `quokka-rag-ask "$text"`, parse the top-K chunks, prepend
   them to the user message as a `## Retrieved context` block
   before appending to the history file.
4. Fallback: on timeout or non-zero exit, log a dim `(rag offline,
   answering without context)` line, optionally speak "offline"
   with piper for audible feedback, and proceed with the existing
   no-RAG flow.
5. Both `voice-agent` (push-to-talk and hands-free) and
   `quokka-netcat-handler` (netcat bridge variant) get the same
   integration via a shared helper, not two copies.

**Deliverables:**
- `servers/mini/bin/quokka-rag-ask`
- `servers/mini/lib/quokka-rag.sh` — shared `needs_retrieval`,
  `call_rag`, `inject_context` helpers, sourced by both scripts
- Edits in `servers/mini/bin/voice-agent` and
  `servers/mini/bin/quokka-netcat-handler` — ≤ 10 lines each

### Phase 4 — Indexer automation

**Goal:** The index stays fresh without human intervention.

1. systemd timer on met: `quokka-rag-index.timer` → runs every
   5 minutes, dispatches `quokka-rag-index --incremental`.
2. Re-indexing budget: incremental re-embed of changed files only.
   On first run, seed the full corpus (can take hours on a large
   mirror — run overnight, progress logged to journal).
3. Log scrape: tail `journalctl -u quokka-rag-index.service` to a
   short status for the operator runbook.
4. `quokka-rag-index --stats` prints chunk count, corpus size,
   last update time — consumed by a later `pl mini llm health`
   style diagnostic.

### Phase 5 — Contextual Retrieval (optional quality step)

**Goal:** Recall quality matches the Anthropic Contextual Retrieval
cookbook technique, adapted to fully local models.

1. For each chunk, generate a one-sentence "where does this chunk
   sit in the enclosing document?" prefix using a local LLM call
   on met (`llama3.1:8b` via ollama — no cloud inference).
2. Prepend the contextual prefix to the chunk text before embedding.
3. Reindex the corpus once (slow — budget hours to a day for the
   first pass, incremental thereafter).
4. A/B evaluate against a fixed question set: if recall@10 improves
   materially, keep; if not, revert.

This step is labelled optional because (a) vanilla hybrid search
is often already sufficient, (b) the cost is non-trivial indexing
time, (c) it's the first thing to skip if Phase 2 is "good enough."

### Phase 6 — Skills framework on top (reuse existing `~/.claude` skills)

**Goal:** Quokka gains structured procedure knowledge by reusing
the **26 SKILL.md files already installed on the dev laptop** under
`~/.claude/plugins/marketplaces/claude-plugins-official/plugins/*/skills/*/SKILL.md`.
No new skills are authored in Phase 6 — the load-bearing idea is
that Rob's existing Claude Code skill corpus *is* Quokka's skill
corpus.

1. **Catalog extraction.** A tiny Python script (or jq pipeline)
   walks the mirrored `~/mirror/claude/plugins/marketplaces/**/SKILL.md`,
   parses the YAML frontmatter of each file (`name`, `description`),
   and writes `~/quokka-rag/skills-catalog.json` — one row per
   skill with its name, description, absolute path, and plugin
   parent (e.g. `skill-creator` lives under the `skill-creator`
   plugin). Re-run on each `central-sync` so the catalog stays in
   step with whatever Rob installed / updated on dev.
2. **Skill index injection.** At voice-agent startup, the catalog
   (just names + one-line descriptions, ≈ 26 × 100 bytes ≈ 3 KB)
   is loaded into Quokka's system prompt as a short menu — "You
   have access to the following skills on demand: skill-creator
   (create new skills…), writing-rules (linter rules for prose…),
   …".
3. **Per-turn skill selection.** After retrieval and before the
   main LLM call, a cheap classifier picks one skill or "none"
   based on the user's transcript. Two options, ship the simpler
   first:
   - **6a (ship first):** pure regex / keyword match against the
     skill `description` fields. No LLM call, zero latency.
     Misses will fall through to RAG-only answering, which is
     fine.
   - **6b (optional upgrade):** a small `llama3.1:8b` call with
     the catalog + transcript asking for a skill-id or `none`.
     Adds ~200 ms; enable only if 6a's miss rate is visibly bad.
4. **Skill injection.** When a skill is picked, the matching
   SKILL.md body is read from `~/mirror/claude/…`, prepended to
   the LLM context as a `## Skill: <name>` block, and passed
   through to the normal generation path. No copy, no caching
   beyond a per-turn read.
5. **Why this path instead of authoring new skills.** The original
   draft of this proposal suggested shipping a hand-written bootstrap
   set (rosary, daily-readings, nwp-command-help,
   moodle-tabbed-plugin). Per the 2026-04-11 design conversation,
   Rob asked whether the existing `~/.claude` skills could be used
   directly. They can, and the benefits compound: the corpus
   grows automatically as Rob installs new Claude Code plugins,
   there is exactly one source of truth for "how do I…"
   procedures, and Quokka inherits whatever quality control upstream
   marketplaces apply to those skills. If Rob later wants
   Quokka-specific skills (e.g. a rosary skill that has no Claude
   Code analogue), he authors them as a new plugin under
   `~/.claude/plugins/local/` — `central-sync` and the catalog
   extractor pick them up on the next run.

### Phase 7 — Long-term conversation memory (Quokka-side archive)

**Goal:** Past *Quokka* conversations join the corpus alongside the
Claude Code conversation history already indexed in Phase 2.

Context: Phase 2 already indexes `~/.claude/projects/**/*.jsonl` —
the 1.6 GB of Claude Code conversation history across 28 project
slugs. That immediately gives Quokka recall over "what did we
decide about X in the nwp Claude session last week?" without any
extra infrastructure. Phase 7 closes the remaining gap: Quokka's
own voice conversations, which live only in `$HISTORY_FILE` on
mini and get thrown away on `/new`.

1. On `/new` (conversation reset) in `voice-agent` and
   `quokka-netcat-handler`, copy `$HISTORY_FILE` to
   `~/.local/share/quokka/history/YYYYMMDD-HHMMSS.json` on mini
   before resetting. Keep a hard cap on the directory (e.g. 500
   files) with FIFO rotation.
2. Extend `central-sync` with a seventh manifest entry — mini→met
   one-way rsync of `~/.local/share/quokka/history/` to
   `~/mirror/quokka-history/`. mini is the sole writer, same
   pattern as `~/mirror/claude/` but sourced from mini instead of
   dev.
3. Extend the indexer's corpus roots to include
   `~/mirror/quokka-history/*.json`, chunking by turn with
   `source_kind=quokka_history` metadata and a `ts` column for
   time-sorted retrieval. Same embedding / FTS5 / fusion pipeline
   as everything else — no special casing.
4. Retrieval over past Quokka conversations uses the same hybrid
   search machinery as doc retrieval, so "remember when we talked
   about Moodle?" surfaces the relevant archived conversation
   alongside doc chunks and Claude Code session chunks.

---

## 7. Affected NWP Components

### 7.1 New paths

| Path | Purpose |
|---|---|
| `docs/proposals/X03-quokka-rag-via-met-mirror.md` | This proposal |
| `docs/guides/quokka-rag.md` | Operator runbook — install, reindex, query, troubleshoot |
| `docs/guides/central-sync.md` | `central-sync` operator runbook — how to run, recover from divergence, add a project, enforce secret exclusion |
| `servers/met/mirror/manifest.yml` | Machine-readable mirror manifest — 7 entries (nwp, theocat, logic, claudemax, ado, claude, quokka-history) with sync type, direction, peer paths, exclude globs |
| `servers/met/mirror/central-sync` | Bash entry point, ≈ 400 LOC. Runs on both laptop and met. Script-triggered bidirectional sync with per-project rules, refuse-and-report default, `--auto-rebase` opt-in, `--claude-review` advisor mode with in-session dispatch. |
| `servers/met/mirror/check-no-secrets.sh` | Secret-exclusion enforcer called by `central-sync` before every rsync pass |
| `servers/met/mirror/claude-review.sh` | Divergence advisor dispatcher (§ 6.2.2–6.2.3). In-session from dev → tool-result stream; out-of-band from met → local llama3.1:8b; `--claude-review=haiku` → opt-in API call. |
| `servers/met/mirror/claude-review-prompt.md` | Versioned prompt template for the `--claude-review` dispatcher |
| `servers/met/bin/quokka-rag-index` | Indexer (Python) — walks corpus, chunks, embeds, stores |
| `servers/met/bin/quokka-rag-query` | Query tool (Python) — hybrid search, returns top-K chunks as JSON |
| `servers/met/bin/quokka-claude-strip` | Stage 1 JSONL → markdown stripper. Per § 6.3a. Deterministic, no LLM. |
| `servers/met/bin/quokka-claude-digest` | Stage 2 stripped-markdown → summary digester. Per § 6.3a. Local `llama3.1:8b` via ollama by default; optional cloud Haiku opt-in. |
| `servers/met/quokka-rag/digest-prompt.md` | Versioned Stage 2 prompt |
| `servers/met/bin/quokka-skills-catalog` | Tiny extractor (Python or bash + jq) — walks `~/mirror/claude/plugins/marketplaces/**/SKILL.md` and writes `~/quokka-rag/skills-catalog.json` |
| `servers/met/quokka-rag/config.yml` | Corpus roots, chunk config, exclude globs, per-root `source_kind` tagging |
| `servers/met/quokka-rag/skills-catalog.json` | Generated — list of 26 `~/.claude` skills with names, descriptions, paths |
| `servers/met/systemd/quokka-rag-index.{service,timer}` | Incremental reindex every 5 min (not in git) |
| `servers/met/systemd/quokka-claude-digest.{service,timer}` | Runs after `central-sync` finishes; incremental only (not in git) |
| `servers/mini/bin/quokka-rag-ask` | SSH/HTTP thin client, 2 s timeout, graceful fallback |
| `servers/mini/lib/quokka-rag.sh` | Shared `needs_retrieval`, `call_rag`, `inject_context`, `pick_skill`, `inject_skill` helpers |

### 7.2 Modified paths

| Path | Change |
|---|---|
| `servers/mini/bin/voice-agent` | Source `servers/mini/lib/quokka-rag.sh`; call `needs_retrieval` + `call_rag` + `inject_context` before `ask_ollama`. ≤ 10-line diff. |
| `servers/mini/bin/quokka-netcat-handler` | Same pattern as above. ≤ 10-line diff. |
| `servers/mini/.nwp-server.yml` | Add `voice_agent.rag.enabled`, `voice_agent.rag.endpoint` (default: `ssh://met.nwp.headscale`), `voice_agent.rag.timeout_ms` (default: 2000). |
| `servers/met/.nwp-server.yml` | Add `quokka_rag.enabled`, `quokka_rag.corpus_roots`, `quokka_rag.embedding_model` (default: `nomic-embed-text`). |
| `docs/governance/roadmap.md` | Add X03 entry under Phase X — Experimental & Outliers. |
| `CLAUDE.md` | No changes. Threat model unchanged — both mini and met are AI-capable, neither touches prod. |

### 7.3 Not modified

- **`lib/`** — shared bash library needs no changes.
- **`pl`** — runs unchanged.
- **`recipes/`** — machine-agnostic.
- **`sites/`** — Quokka does not index `sites/*/backups/` or any
  other per-site data that falls under the sanitizer boundary.
- **Anything mons, prod, or mmt → mons signing path** — completely
  out of scope.

### 7.4 Data that must not enter the corpus

Hard excludes enforced at indexer and mirror-sync level:

- `.secrets.data.yml` (CLAUDE.md § Two-Tier Secrets)
- `.secrets.yml` — even infra-tier secrets don't belong in a search
  index
- `keys/prod_*`, `keys/*.pem`, `keys/*.key`
- `*.sql`, `*.sql.gz` — database dumps, even sanitised ones
- `**/settings.php` — Drupal credentials
- `**/sites/*/backups/**` — per-site backup content
- `**/.env`, `**/.env.local`, `**/.env.production`
- `**/node_modules/**`, `**/vendor/**`, `**/.venv/**`,
  `**/__pycache__/**` — build artefacts, bloat the index with no
  retrieval value
- `**/.git/objects/**` — the git object store; `.git/config` and
  `.git/HEAD` are fine if a use case emerges but default-excluded

The exclude list is versioned in `servers/met/mirror/manifest.yml`
(mirror side) and `servers/met/quokka-rag/config.yml` (indexer
side) so both lines of defence are explicit.

---

## 8. Risk Assessment

### High risk

| Risk | Mitigation |
|---|---|
| **A secret file leaks into the corpus** — an excluded file slips through, gets embedded, and surfaces in a retrieved chunk. | Two independent exclude layers: mirror-sync refuses to copy matching paths (Phase 1), indexer refuses to read matching paths (Phase 2). CI check walks the index, scans for patterns matching known secret signatures, fails the build on hit. Periodic manual audit of a random sample of indexed chunks. |
| **Mirror-sync for non-git projects drifts silently** — rsync fails, met falls behind, Quokka gives stale answers. | Sync timer logs to journal with unit-file `OnFailure=`. A nightly health check compares source mtimes to met-side mtimes and pages (via Gotify per F22) on drift > N minutes. |
| **Quokka hangs when met is unreachable** — SSH round-trip blocks the voice loop. | Hard 2-second timeout on every RAG call. Graceful fallback (no-RAG turn) on timeout. Intent gate skips retrieval for chitchat, so most turns don't even attempt the call. Audible "offline" hint so Rob knows the fallback kicked in. |
| **Contextual Retrieval step (Phase 5) re-embeds the whole corpus and takes days on met.** | Phase 5 is optional; skip if Phase 2 quality is sufficient. Incremental contextualisation (only new / changed chunks) after the initial pass. Run overnight; progress to journal. |

### Medium risk

| Risk | Mitigation |
|---|---|
| **Index bloat** — 30+ GB of code, docs, history pushed through nomic-embed-text produces a large sqlite file. | Exclude rules kill most of the bulk (node_modules, vendor, .git objects). Monitor `quokka-rag-index --stats` in Phase 4. If the index exceeds met's headroom, prune by corpus root or lower top-K. |
| **F24 Phase 2 (auto-pull on met) is still pending** — X03 Phase 1 can't cleanly generalise a pattern that isn't formally finalised yet. | Phase 1 writes the generalised pattern and lets F24 Phase 2 land first, or F24 Phase 2 is rolled into X03 Phase 1 as one work item. Coordinate in the decision record. |
| **Embedding model quality is poor on Catholic reference material** — nomic-embed-text is trained on general web text and may not handle liturgical/theological vocabulary well. | Phase 5 contextual prefixes help. If not enough, upgrade path to `bge-large-en-v1.5` or `mxbai-embed-large` (both MIT, both run on ollama, both larger). Met can host these fine; mini couldn't. |
| **SSH ControlMaster overhead** — each query spawns a new shell session. | `ControlPersist=10m` amortises session setup over many queries. If measured overhead > 50 ms, switch transport to a tiny FastAPI daemon on met bound to the Headscale interface. |

### Low risk

| Risk | Mitigation |
|---|---|
| **sqlite-vec is relatively new** (v0.1.x, pure C, MIT). | Fall back to numpy + cosine similarity if sqlite-vec proves unstable. The interface is small; migration is <50 LOC. |
| **Intent gate misfires** — Quokka retrieves for chitchat or skips retrieval for real questions. | Gate is regex-based and tunable. Log every decision for the first week; iterate. The worst case (false negative) degrades to today's no-RAG behaviour. |
| **Skills framework (Phase 6) selection LLM call adds latency.** | Phase 6 is optional. Can be gated by a keyword match ("pray the rosary" → rosary skill) that skips the LLM selection call entirely. |

---

## 9. Open Questions

- **Transport: SSH vs HTTP daemon on met?** SSH with ControlMaster
  is simpler and reuses existing trust. A small FastAPI daemon
  bound to the Headscale interface is faster per-query and allows
  future clients. Phase 3 defaults to SSH; revisit if measured
  overhead is annoying.
- **Embedding model:** `nomic-embed-text` (137M, fast, fine for
  general English) vs `bge-large-en-v1.5` (335M, better recall,
  only viable on met). Default `nomic-embed-text` for Phase 2,
  upgrade as Phase 5b if quality is insufficient on theological or
  technical vocabulary.
- **JSONL chunking strategy for `~/.claude/projects/`.** Per-turn
  is the obvious choice but produces very small chunks for quick
  user messages; per-session is too coarse for specific recall.
  Phase 2 ships with per-turn and a sliding window; tune once
  real queries happen.
- **Theology corpus completeness.** `~/theocat` is the theology
  corpus and is in scope for Phase 1. Content migration from
  `~/prayer` and `~/carmel` *into* theocat is Rob's ongoing work
  and is explicitly **out of scope** for X03 — Quokka will index
  whatever is in theocat at the time each reindex runs.
- **Does mons ever need RAG?** mons is offline-by-default and
  hardware-token-gated per ADR-0019. If a future use case needs
  mons to query diagnostics, the same thin-client pattern applies,
  but the network dependency is wrong for mons's posture. Treat
  as out of scope for X03.
- **Multi-client access.** dev laptop could benefit from the same
  RAG index for Claude Code sessions. Phase 2's query tool is
  already usable from any box that can SSH to met, so this is
  "free" but deferred as an explicit deliverable.
- **Deferred mirror projects.** prayer (14 GB), ciytools (6.7 GB,
  heavy GPU), carmel (1.5 GB, content being ported into theocat),
  and the rest of `~/central/README.md` are all **deferred** from
  Phase 1 per Rob's 2026-04-11 confirmation. Revisit if Quokka's
  recall is visibly thin on those topics after Phase 2.

---

## 10. Out of Scope

- Replacing mini's existing STT / LLM / TTS stack (whisper /
  ollama / piper). RAG is an additional step, not a rewrite.
- X02 Phase 2 (Twilio / Pipecat integration). X03 extends the
  current direct-mic loop; PSTN is an independent track.
- Mirror-syncing `sites/*/backups/` to met. Those are per-site
  local-only repos per F18 and are explicitly excluded by the
  manifest.
- Fine-tuning or LoRA-ing the local LLM. RAG is the stated
  technique.
- Exposing met's RAG service to anything outside the home LAN /
  Headscale mesh.
- Indexing production data (sanitised or otherwise) — the
  sanitizer boundary is inviolable per CLAUDE.md.
- Multi-user / multi-tenant RAG (auth, rate limiting, per-user
  corpora). Quokka is single-user.
- Replacing CLAUDE.md or any standing orders.
- Touching mons, prod, or the mmt → mons signing path.

---

## 11. Cross-references

- **[CLAUDE.md § Threat Model](../../CLAUDE.md)** — paranoid +
  open-source + local-first assumptions X03 inherits
- **[X02: Local Voice Agent on mini](X02-local-voice-agent-on-mini.md)**
  — the voice agent X03 extends with a retrieval layer
- **[F24: Mirror NWP Tree on met](F24-relocate-dev-tree-to-met.md)**
  — the mirror pattern X03 generalises from `~/nwp` to all project
  trees; F24 § 9 explicitly flagged "mini's role" as an open
  question that X03 answers
- **[F21: Distributed Build/Deploy Pipeline](F21-distributed-build-deploy-pipeline.md)**
  — Phase 1 (Headscale) and Phase 3a (mini as local-LLM agent) are
  load-bearing hard deps
- **[F22: Gotify Remote Reachability](F22-gotify-remote-reachability.md)**
  — proposed mirror-sync health-check paging route
- **[ADR-0017: Distributed Build/Deploy Pipeline](../decisions/0017-distributed-build-deploy-pipeline.md)**
  — defines the trust boundary that lets met host a service mini
  can call
- **[ADR-0004: Two-Tier Secrets Architecture](../decisions/0004-two-tier-secrets-architecture.md)**
  — governs what may and may not enter the corpus
- **[ADR-0011: Proposal Designation System](../decisions/0011-proposal-designation-system.md)**
  — justifies the X## prefix for scope-expansion proposals
- **[docs/guides/voice-agent.md](../guides/voice-agent.md)** —
  X02 Phase 0 operator runbook that X03 Phase 3 will extend
- **Anthropic Contextual Retrieval cookbook** (external) —
  `anthropics/anthropic-cookbook` → `contextual-embeddings/`. The
  RAG technique X03 Phase 5 adapts to fully local inference.
- **Anthropic Skills** (external) —
  `anthropics/skills`. The on-demand SKILL.md pattern X03 Phase 6
  adopts.

---

## 12. Decision Record

**Decided option:** Option B (RAG on met, mini as thin client)
with the locked Phase 1 corpus and bidirectional script-triggered
sync described in § 6.1–6.3.
**Decision date:** 2026-04-11
**Decision maker:** Rob.

**Design conversation of record (2026-04-11):** Rob asked whether
Quokka on mini uses RAG (it doesn't) and then whether "the RAG
Claude uses" (Anthropic Contextual Retrieval) is open source (yes).
After clarifying the difference between Contextual Retrieval (RAG
technique) and Claude Skills (on-demand context loading) and
confirming Quokka can use both, Rob proposed duplicating all
project folders (ado, nwp, theocat, …) onto met and having Quokka
reach over the network to met as its RAG source. I drafted the
first version of this proposal. Rob then answered five follow-up
questions:

1. **Corpus scope:** locked to nwp, theocat, logic, claudemax (git)
   and ado (rsync); everything else in `~/central/README.md` is
   deferred. "There is a file in ~/central that lists which folders
   are synced and how" — resolved as `~/central/README.md`'s
   per-project tables and the per-project `.md` files, referenced
   by `servers/met/mirror/manifest.yml` as upstream inventory.
2. **Sync direction:** bidirectional, triggered by a script
   (`central-sync`), not by a systemd timer. § 6.1 addresses the
   tension with F24 § 4.4's earlier rejection of two-way sync.
3. **Theology corpus:** `~/theocat` holds everything currently;
   prayer/carmel porting into theocat is out of scope.
4. **Skills framework:** use the **existing 26 SKILL.md files**
   installed on dev under
   `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/*/skills/*/`,
   plus the 1.6 GB of JSONL conversation history under
   `~/.claude/projects/`, as the bootstrap RAG + Skills material.
   Phase 6 becomes "catalog and inject the already-installed
   skills" rather than "author a bootstrap skill set."
5. **F24 Phase 2 rollup:** rolled into X03 Phase 1. F24 Phase 2
   closes as "superseded by X03 Phase 1" once this lands.

**Explicit rejections from the conversation:**

1. **"Full RAG on mini."** Storage waste + compute contention
   with the voice pipeline, even though mini has 128 GB unified
   RAM.
2. **"Hosted / cloud RAG."** Violates CLAUDE.md § Threat Model.
3. **"Skills without retrieval."** Skills can't answer factual
   recall questions; retrieval is load-bearing.
4. **"F24-style one-way pull for non-nwp projects."** Rejected in
   favour of bidirectional script-triggered sync for the reasons
   in § 6.1.
5. **"Author bootstrap skills for Quokka from scratch."** Rejected
   in favour of reusing the 26 installed `~/.claude` skills.

**Design follow-up of record (2026-04-12):** Rob flagged two
things in the first review of this proposal:

6. **Theocat is a thin core, not a 6.3 GB bulk repo.** Confirmed
   against `~/theocat/README.md` ("How It Works") and on-disk
   sizing: the thin core is 29 MB, the 6.3 GB on dev is installed
   packages under `sources/`, `projects/`, `tools/`, each an
   independent git repo. X03 now splits theocat into a sync layer
   (thin core via `central-sync`) and an install layer (public
   packages installed on met via `./bin/theocat install` / `update`;
   private `*-private` packages not installed on met by default).
   See § 3.3a and § 6.3 step 1.
7. **Raw `~/.claude/projects/**/*.jsonl` is too noisy to index
   directly.** Rob asked whether Claude could preprocess the
   conversation history into "essential bits" before embedding.
   X03 now adds a two-stage digest pipeline in § 6.3a: a
   mechanical strip (no LLM) followed by a local `llama3.1:8b`
   summarisation pass, with a Haiku-via-API upgrade path left
   opt-in. The parent-document / small-to-big RAG pattern surfaces
   the stripped transcript when a digest chunk matches a query.
8. **Git divergence handling defaults to "refuse and report"**
   with an opt-in `--auto-rebase` flag that only operates in a
   scratch worktree, only on unpushed local commits, only when
   the rebase is zero-conflict, and never on `~/nwp` (signed
   commits). Details in § 6.2.1.
9. **Claude-as-advisor divergence review** (`--claude-review`)
   added as a third mode in § 6.2.2. Rob flagged that git alone
   can't see timing signals that Claude can — specifically the
   `~/.claude/projects/*` session windows that show which Claude
   Code session produced each side's commits. `--claude-review`
   dispatches divergences to Claude with diffs + timestamps +
   session context, and receives a JSON verdict
   (`{verdict, confidence, rationale, touched_files,
   session_evidence}`). **Default is advisory only** — the
   verdict is printed, central-sync exits non-zero, no history is
   rewritten. `--apply` is an additional opt-in gated on
   `confidence=high`, manifest flag `allow_claude_review_apply`,
   and all the `--auto-rebase` safety gates; `~/nwp` sets
   `allow_claude_review_apply: false` regardless.
10. **In-session dispatch is the default from dev** (§ 6.2.3).
    When `central-sync --claude-review` is invoked as a tool call
    from a live Claude Code session on the dev laptop, the review
    short-circuits its own model call and passes the divergence
    prompt back to the caller session via a tool-result stream.
    The verdict appears inline in the same conversation Rob is
    already in, with the accumulated context of the day's work
    available for follow-up questions. Out-of-band dispatch
    (local llama3.1:8b on met, or opt-in Haiku) is the fallback
    for met-side invocations or plain-terminal runs with no
    session attached.
