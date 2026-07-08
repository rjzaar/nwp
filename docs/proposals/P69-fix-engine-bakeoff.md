# P69: Fix-Engine Bake-off — chronicled evaluation of every reasonable local-agent harness

> **Renumbered P67 → P69 (2026-07-08, ops#53).** This file originally shared number P67
> with the per-site-maturity proposal (`P67-per-site-workflow-maturity.md`, bound to ops#48).
> P67 stays with maturity; P68 was taken by the legal-doc authoring workflow; this bake-off
> becomes P69.

**Status:** PROPOSED (operator requested 2026-07-06: "test and investigate each
of the reasonable alternatives with max research each time by implementing …
each alternative and then chronicling the results as you go so the research
leads to best practice")
**Created:** 2026-07-06
**Author:** Robert Karsten Zaar (with AI assistance)
**Priority:** Medium (research program; feeds P66 Phase 3–4 and the mentor/shadow plan)
**Depends On:** P66 (context bundles — soft dependency, see §6.3); ops#41 loop (engine seam); ai-host LLM stack (UP, verified 2026-07-06)
**Breaking Changes:** No (all work sandboxed; nothing ships to the loop except the eventual winner, via normal MR review)
**Estimated Effort:** multi-week background program; ~1–2 sessions per candidate + compute time

> **Why this proposal exists.** P66 concluded "aider first, OpenCode fallback"
> from *literature*: benchmarks, docs, community reports. That was the right
> way to pick a starting point and the wrong way to pick a standard. The
> tools in this space change monthly, their published claims are frequently
> stale (P66's research caught review sites describing a frozen project as
> "actively maintained"), and none of the published numbers were measured on
> *our* stack: Strix Halo + Vulkan + ollama, PHP/Drupal, module-scoped bugs,
> headless cron, Claude-as-reviewer. The only evidence that settles "which
> harness should hold the local seat" is running each one, tuned to the best
> of our ability, against the same tasks on the same box — and writing down
> what happened while it happens, not after. The chronicle *is* the product:
> even the losers teach us what transfers (prompt shapes, edit-format
> behavior, failure modes), and the record is what makes the final
> best-practice claim auditable instead of vibes.

**Baseline already proven (2026-07-06, the "get it working" step):** headless
aider 0.86.2 + `ollama_chat/qwen2.5-coder:14b` on the ai-host produced a
correct, minimal, well-formed, auto-committed fix for a seeded PHP bug on the
first attempt (863 tokens sent / 117 received; scratch repo `~/aider-smoke`).
The plumbing works end-to-end; P69 turns that anecdote into a program.

---

## 1. Goals

- **G1.** Every *reasonable* candidate harness is evaluated by **implementing
  it** — installed, configured, and tuned to the best of our ability on the
  real rig — not by reading about it.
- **G2.** Every candidate gets a **fresh max-research pass at execution
  time** (web + docs + issue trackers, multi-agent fan-out allowed). Research
  done weeks earlier is treated as expired.
- **G3.** All candidates run the **same frozen task battery** on the **same
  rig** with the **same metrics**, so results are comparable.
- **G4.** Results are **chronicled as they happen** in an append-only journal
  plus per-candidate reports. A finding that isn't written down the same
  session doesn't exist.
- **G5.** The program ends with a **best-practice document + ADR**: which
  engine holds the local seat, in what configuration, with what evidence —
  and the runner-up escape hatch.
- **G6.** Everything runs **sandboxed**: scratch clones, no MRs from
  experiments, no Lane A contact, threat-model constraints per candidate
  (§7). The loop's A14/merge gates are untouched.

## 2. Non-goals

- Not a general "best AI coding tool" review — the question is narrowly *the
  local seat in the NWP self-healing loop*: headless, cron-driven,
  module-scoped, local-model-backed, Claude-reviewed.
- Not model research per se — the model axis is one controlled experiment
  (§5, Experiment H), not a sweep of everything on Hugging Face.
- No fine-tuning (P66 §1.4 stands).
- Not a replacement for the mentor/shadow plan — P69 picks the *engine*;
  shadow mode later grades the *engine+model on real issues* before
  promotion.

## 3. Method — the scientific shape

### 3.1 The task battery (frozen, versioned)

A fixed set of ~12–16 tasks, each with: a realistic issue-style prompt (the
kind the loop actually receives — free text from the feedback widget or a
`rag-auto` body), a repo fixture, a **reference fix**, and **pass criteria**
(tests green + behavior matches reference + scope respected). Tiers:

| Tier | Shape | Count | Source |
|---|---|---|---|
| T1 smoke | trivial seeded bug, one file (the 2026-07-06 discount.php test is T1-01) | 2 | synthetic |
| T2 module-scoped | real-shaped PHP/Drupal bug inside ONE nwc-style module, with the module's context bundle; includes one "bug is NOT in the given module" trap (correct answer: refuse + note) | 6–8 | seeded into a sanitized clone of real module code + replayed real solved issues where available |
| T3 cluster-scoped | fix spans 2–3 modules (e.g. notification + guild interaction) | 2 | seeded |
| T4 kind-shaped | one docs task, one config task, one composer security-bump | 3 | replay of real solved loop issues |

Battery rules: versioned (`battery-v1`); any change bumps the version and
marks prior results non-comparable; the trap task and at least one T2 task
are **held back from tuning** (never used while configuring a candidate) to
catch overfitting the harness config to the test.

### 3.2 The rig (common to all candidates)

- **Box:** the ai-host (Strix Halo, 128 GB unified, Vulkan/ollama stack —
  verified UP 2026-07-06; 1 TB free disk).
- **Models (fixed set):** `qwen2.5-coder:14b` (floor — already benchmarked),
  `qwen3-coder:30b` (fast primary — pulled 2026-07-06), `gpt-oss:120b`
  (quality primary — already resident, 65 GB). Every candidate runs the
  battery against at least the floor and one primary. Model *additions*
  (e.g. Qwen3-Coder-Next 80B GGUF import) are Experiment H, not ad-hoc.
- **Context bundles:** each T2/T3 task ships its bundle (module dir +
  passport-equivalent + index stub). Until P66 lands, bundles are hand-built
  to the P66 template — so P69 is **not blocked on P66** and doubles as a
  test of the bundle format itself.
- **Driver interface:** every candidate is wrapped to the same contract the
  loop's engine seam expects: `engine-run <task-dir>` → exit state determined
  *externally* (git HEAD moved + pass criteria + mechanical scope check +
  hard timeout). No candidate is trusted to report its own success (aider's
  unreliable exit codes made this rule; it applies to all).
- **Runs:** each task ×3 per model (variance is data — a harness that
  succeeds 1/3 is a different animal from 3/3).

### 3.3 Per-candidate protocol (the "max research each time" loop)

For each candidate, in order, one candidate at a time:

1. **RESEARCH (max, fresh):** parallel agents sweep current docs, release
   history, issue tracker, community reports — *as of that day*. Output: a
   research brief in the candidate's report (what config is supposed to work,
   known failure modes, what "best of ability" tuning means for this tool).
2. **IMPLEMENT:** install on the rig; configure per research; tune on the
   tuning-allowed tasks only (conventions/rules files, edit formats,
   permission modes, retry settings — whatever the tool offers). Time-boxed:
   2 focused sessions max before a verdict of "could not be made to work" —
   which is a *result*, chronicled with the evidence, not a silent drop.
3. **RUN:** the full battery per §3.2. Raw logs kept.
4. **CHRONICLE (same session as the runs):** journal entries as things
   happen; then the candidate report: setup friction, config that mattered,
   per-task results table, failure taxonomy, metrics (§3.4), and — most
   important — **transferable lessons** (anything that improves the rig,
   bundles, or prompts for everyone).
5. **VERDICT + RE-PLAN:** score vs the current leader; decide whether the
   remaining candidate order should change (chronicled with reasoning).
   Rig/bundle improvements discovered here roll forward; if one materially
   helps, previously-run candidates get a marked re-run of affected tasks.

### 3.4 Metrics (per task × model × run)

- **Solved** (pass criteria met) / partial / failed / refused-correctly (the
  trap task inverts scoring)
- **Edit well-formedness** (edits applied cleanly vs mangled)
- **Scope compliance** (mechanical diff check — files touched outside the
  bundle = violation, regardless of whether the fix worked)
- **Retries consumed**, **wall-clock**, **local tokens**, **VRAM/pressure notes**
- **Review burden:** Claude reviews every produced diff with the same rubric;
  count of real findings per diff (the mentor's grading, and the cost that
  actually hits the operator)
- **Ops friction:** crashes, hangs, zombie processes, non-deterministic flags
- **Threat-model fit:** what the tool needed (shell? network egress? API
  keys?) vs what it produced

## 4. Candidate roster (the "reasonable alternatives")

| # | Candidate | Why it's on the list | Threat-model notes |
|---|---|---|---|
| A | **aider** (0.86.2) | P66's literature pick; text edit formats need no tool-calling; smoke-proven 2026-07-06 | edit-only protocol; no shell given to model |
| B | **OpenCode** | most active OSS terminal agent; headless `run`; ollama-native; the designated fallback — now tested instead of designated | tool-calling agent; review its permission model in RESEARCH |
| C | **goose** (Linux Foundation) | headless "recipes" are genuinely good; MCP-native | general agent; shell access must be sandboxed |
| D | **Codex CLI** (OpenAI, OSS) | mature harness; supports local/OSS model endpoints | verify local-endpoint story in RESEARCH |
| E | **OpenHands** | strongest published autonomous issue-solver results | heaviest; Docker sandbox with **no network egress** (or explicit allowlist) — hard requirement |
| F | **Claude Code → LiteLLM proxy → local model** | best harness in existence; tests whether local models can drive it | unofficial; keep proxy env vars scoped to the run (never near the subscription login) |
| G | **No-harness control** | deterministic script for T4 security-bump + templated edits; establishes which tasks need *no* LLM | none — it's a shell script |
| H | **Model axis** (winning harness × models) | Qwen3-Coder-Next 80B GGUF import; gpt-oss:120b reasoning-high; architect/editor splits (incl. the policy question of a remote architect) | remote-architect variant sends code context off-box — operator decision before running |
| I | **`claude -p` control** | the incumbent, run on the same battery — the upper bound and the number everything is relative to | already in production |

Roster is amendable: RESEARCH passes may nominate a new entrant (chronicled);
anything scoring below the no-harness control on its natural tasks is out.

## 5. Sequencing

- **Phase 0 — rig + battery.** Build the driver wrapper, the battery
  (battery-v1), the chronicle skeleton. Re-run baseline: **I** (`claude -p`)
  and **A** (aider, properly this time — model settings, conventions,
  `--map-tokens 0` vs repo-map comparison). *Exit: results table has its
  first two rows; journal live.*
- **Phase 1 — the young guard.** **B** (OpenCode), then **C** (goose) —
  the two most likely to displace aider.
- **Phase 2 — the heavyweights.** **D** (Codex CLI), **E** (OpenHands,
  sandbox first), **F** (Claude-via-proxy).
- **Phase 3 — controls + model axis.** **G**, then **H** on the leading
  harness.
- **Phase 4 — synthesis.** Comparative report; best-practice doc
  (`docs/research/engine-bakeoff/BEST-PRACTICE.md`); ADR "local fix-engine
  selection"; winner wired into the loop's engine seam **in shadow mode**
  (mentor plan takes over from there). Runner-up documented as the escape
  hatch with its exact config preserved.

Order within phases is revisable after every candidate (§3.3 step 5) — the
chronicle records each re-plan. The program can pause indefinitely after any
candidate; the journal keeps partial results useful.

## 6. The chronicle (structure)

```
docs/research/engine-bakeoff/
  journal.md            # append-only, dated entries, written DURING sessions
  results.md            # the living comparative table (one row per candidate×model)
  battery/              # task definitions, fixtures, reference fixes, pass criteria
  candidates/
    A-aider.md          # research brief + config + runs + failure taxonomy + lessons
    B-opencode.md
    ...
  BEST-PRACTICE.md      # Phase 4 output
```

- Journal entries are made **during** work (G4). Committed to the nwp repo at
  session milestones via normal MR flow (docs-only MRs).
- 6.3 **P66 interaction:** T2/T3 bundles follow the P66 passport template. If
  P66 Phase 1 lands mid-program, later candidates use real passports — the
  battery version bumps and the change is chronicled. P69 findings about
  bundle quality feed back into P66's template.

## 7. Guardrails

- All experiment repos are scratch clones under `~/bakeoff/` on the ai-host —
  never the operator's tree, never `sites/`, never Lane A paths.
- No experiment opens MRs or touches GitLab (replayed issues are copied into
  fixtures, not driven live).
- Candidates that execute shell (C, E, and possibly B/D) run inside a
  container/sandbox with network egress off or allowlisted to the local
  ollama endpoint only. A harness that can't function without open egress
  gets that fact chronicled as a threat-model failure, not worked around.
- The proxy experiment (F) sets `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`
  only inside the wrapped invocation — nothing persistent that could shadow
  the subscription OAuth the production loop depends on.
- Kill switch: `~/bakeoff/.paused` checked by the driver; hard per-run
  timeouts always.
- Compute etiquette: one large model resident at a time (the iGPU saturates
  at one big inference); long runs scheduled off the transcription pipeline's
  peak hours if that returns.

## 8. Success criteria

- [ ] battery-v1 frozen: ≥12 tasks, tiers T1–T4, trap task included, held-back set defined
- [ ] `results.md` carries rows for ≥6 candidates × ≥2 models, 3 runs each
- [ ] journal.md has same-day entries for every experiment session
- [ ] every candidate report contains a fresh research brief dated within its execution window
- [ ] BEST-PRACTICE.md names a winner + exact config + evidence, and a preserved runner-up path
- [ ] ADR filed; winner running in shadow mode against real loop issues
- [ ] at least three transferable lessons applied to the rig/bundles/prompts and chronicled as such

## 9. Risks

| Risk | Mitigation |
|---|---|
| Program sprawl (9 candidates × research × tuning) | strict time-boxes; one candidate at a time; "couldn't make it work" is a valid chronicled verdict; pause-friendly design |
| Overfitting configs to the battery | held-back tasks; trap task; shadow mode on real issues remains the final gate |
| Battery drift makes results incomparable | versioned battery; version bumps chronicled; re-runs marked |
| Tool churn invalidates results | research briefs are dated; results claim validity *as of* their date; the escape-hatch config is preserved verbatim |
| Sandbox gaps for shell-running agents | egress-off default; a tool needing more is a recorded finding |
| Chronicle written post-hoc (memory-shaped, flattering) | G4 is a hard rule: journal during the session; MR reviews check dates |

## 10. Relationship to existing work

- **P66** — provides the bundle format and, eventually, real passports; P69
  validates them under fire and picks the engine for P66 Phase 3.
- **Mentor/shadow plan (2026-07-03 discussion)** — P69 ends where shadow mode
  begins: engine chosen, config frozen, real-issue grading takes over.
- **ops#41 loop** — the engine seam (`CLAUDE_BIN`-style env override +
  per-kind selection) is the integration point; nothing in the loop changes
  until Phase 4, and then only via reviewed MR.
- **2026-07-06 baseline smoke** — recorded above; becomes journal entry #1
  and task T1-01 when the chronicle is scaffolded.
