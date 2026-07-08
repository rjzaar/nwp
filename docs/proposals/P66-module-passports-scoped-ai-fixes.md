# P66: Module Passports & Scoped AI Fixes

**Status:** PROPOSED (worked out, not actioned — per operator instruction 2026-07-06)
**Created:** 2026-07-06
**Author:** Robert Karsten Zaar (with AI assistance; research base: 3 parallel agent reports 2026-07-06 — nwc coupling analysis, aider/local-model capabilities, per-module-context prior art)
**Priority:** Medium-High (multiplies the value of the §6 self-healing loop; gates nothing currently shipping)
**Depends On:** ops#41 (§6 loop, SHIPPED); coordinates with ops#22/ops#32 (Lane A owns the nwc profile tree); complements the mentor/shadow local-LLM plan (unfiled, discussed 2026-07-03)
**Breaking Changes:** No (additive docs + CI gates + ~20 one-line info.yml corrections)
**Architecture decision records:** none yet; §11 proposes one (module-boundary contract)

> **Why this proposal exists.** The knowledge an AI needs to fix a bug in NWC
> currently lives *everywhere*: `~/nwp/CLAUDE.md` (376 lines), 28 root ADRs,
> 55 proposals, the profile's own `docs/` (81 files, 2.1 MB), and the code —
> **~600k+ tokens of ambient context** for what is usually a one-module fix.
> Meanwhile 35 of the 43 custom modules would fit, code + dependency surface,
> in a 32k-token window. The mismatch is two orders of magnitude. Closing it
> makes fixes cheaper and more reliable for Claude **and** is the single
> precondition that makes a local model on the ai-host viable at all:
> published measurements show agents spend ~48% of their effort just
> *locating* the fault in repo-scale context (SHERLOC, 2026), and that small
> models with good scoping beat big models with whole-repo wandering
> (SweRank, 2025). Scope is the lever.

---

## 1. Executive summary

Give every nwc module a **passport**: a ≤150-line `AGENTS.md` in the module
directory containing its purpose, public surface, invariants, allowed
dependencies, DO-NOT list, and exact test commands — the factual half
**generated** from Drupal's machine-readable metadata (`.info.yml`,
`.services.yml`, `.routing.yml`, config schema) and **drift-gated in CI**;
the judgment half hand-written once and reviewed like code. A thin central
`MODULES.md` index (~1 line per module + the cluster map) routes an issue to
its module(s). The agent-loop then hands a fix task *only* the passport(s) +
module dir(s) instead of the whole repo — which immediately improves Claude
runs, and makes module-scoped fixes winnable by a local model driven by
**aider** (chosen because its text-based edit formats need no tool-calling,
its `--subtree-only`/`--file` fencing enforces scope mechanically, and its
lint/test loop gives ground truth). Boundaries stop being aspirational:
**deptrac** + a cross-module-service check enforce "each module knows its
place" in CI, so the passports stay true instead of rotting.

Verdict on the operator's questions, up front:

1. *Can all information an AI needs for one module live in that module?* —
   **Yes for ~35 of 43 modules today** (17 standalone + the small cluster
   members), **after ~20 one-line dependency-honesty fixes**. Two modules
   (workflow_assignment, nwc_guild) are too big/central and need curated
   surface docs first; the notification hub needs its two hidden cycles
   resolved or explicitly sanctioned.
2. *Demarcation: docs in each module, or links between modules?* — Both,
   with a rule: **the provider owns the contract** (its passport documents
   what it exposes and guarantees), **the consumer documents its
   consumption** (one line per dependency: what it uses and why), and a
   **thin central index** exists only for routing and the cluster map. No
   duplicated prose between modules — links + one-liners only.
3. *Is the code sufficiently stable?* — **The core seven modules and the 17
   standalone specialists: yes** (unchanged since the un-fork import except
   intra-module fixes; the module *lifecycle* was gate-verified 38/38 on
   2026-07-02). **The periphery: not yet** (7 modules added in the last 5
   weeks). So: retrofit passports to the stable set now, and make passports
   **birth certificates** — the new-module template requires one — so the
   accreting periphery arrives documented instead of needing a second
   retrofit.
4. *Fine-tune aider?* — Tune means **configure, not train**. The 2025–26
   evidence is one-sided: LoRA on your own codebase plateaus, goes stale
   with churn, and nobody credibly reports it improving repo-scoped
   bug-fixing; conventions files + edit-format choice + lint/test loops are
   the consensus mechanism. §7 gives the full aider configuration.

## 2. Goals

- **G1.** A bug scoped to one module is fixable by an agent that has read
  ONLY: the central index, that module's passport + directory, and the
  passports (not code) of its declared dependencies. Target: ≤32k tokens of
  context for ≥80% of single-module fixes.
- **G2.** The declared dependency graph (`info.yml`) is *honest*: every
  runtime cross-module reference is either declared or explicitly listed in
  the passport as a guarded soft-dependency. Enforced in CI, not by promise.
- **G3.** Passports cannot rot: generated sections are re-derived and
  `--check`-compared in CI on every MR touching the module (drift = red).
- **G4.** Issues arriving in GitLab (feedback widget or `rag-auto`) get a
  `module::<name>` (or `cluster::<name>`) label automatically, with
  low-confidence cases falling back to human triage — never mis-scoped
  silently.
- **G5.** The agent-loop consumes the scope: its prompt for a routed issue
  names the passport file(s) explicitly and forbids edits outside the scoped
  dir(s) — enforced mechanically at review time (driver-side path check),
  not just by prompt obedience.
- **G6.** The same scoped-context bundles work for *both* engines: `claude
  -p` now, aider+local later. Scoping is engine-independent.

## 3. Non-goals

- **No model fine-tuning** (see §1.4 / §7.6).
- **No architectural rewrite** of module boundaries. The only code changes
  are ~20 one-line `dependencies:` additions and (optionally, Phase 5) the
  cycle-breaking around nwc_notification. Everything else is docs + CI + loop
  plumbing.
- **No change to the A14/merge gates.** Local-model output enters the same
  MR-review pipeline as Claude's; promotion rules from the mentor/shadow plan
  apply unchanged.
- **Does not touch prod** or the deploy pipeline.
- **Does not retrofit the ~600k-token ambient doc corpus.** CLAUDE.md, ADRs,
  proposals stay as they are; this proposal makes them *unnecessary* for
  module-scoped fixes rather than reorganizing them.

## 4. Current reality (measured 2026-07-06)

From the coupling analysis of `sites/nwc/dev/html/profiles/custom/nwc/`
(branch `unfork/open-social-13`, git history from the 2026-05-19 un-fork
import, 67 commits):

- **43 custom modules, ~81k LOC** (php+yml+twig), under `modules/nwc_features/`
  (flat + 3 nested families: growth, moodle, formation). Packaged post-unfork
  as a single `drupal-custom-module` composer package with 9-tier recipes.
- **Declared graph:** acyclic. `nwc_core` has 24 dependents but itself
  depends on `workflow_assignment` — making workflow_assignment the true
  root. ~20 modules are leaves.
- **Hidden coupling (undeclared in info.yml):** ~20 cross-module references.
  `nwc_notification` is the hub — 5 modules (guild, work_management, asset,
  editorial, email_reply) silently use its services/entities, and it silently
  reaches back into guild (5 `hook_nwc_guild_*` implementations) and
  email_reply. **Two hidden runtime cycles:** guild↔notification,
  notification↔email_reply — invisible to the declared graph, partially
  `moduleExists()`-guarded. The contrib `group` entity is the universal join
  point (referenced by guild ×7, workflow_assignment ×3, notification,
  feedback); workflow_task/template entities are queried by 8 modules.
- **Context sizes:** ~35/43 modules fit 32k tokens (own code + dependency
  *surfaces*); ~41/43 fit 100k. The two that fit neither — workflow_assignment
  (~97k own) and nwc_guild (~92k own) — are also the churn leaders and
  coupling hubs. The hard cases coincide, which is convenient: one problem,
  not three.
- **Docs:** 7/43 modules have any markdown. workflow_assignment's 15-file doc
  suite is imported-and-stale (untouched while the module took 7 commits).
  New modules (moodle, collab, registration) *do* get READMEs — the
  convention is emerging unprompted; P66 formalizes it.
- **Tests:** 12/43 modules have PHPUnit tests (39 files, concentrated in 4
  modules); profile Behat is organized by lifecycle phase, not module. So
  "run this module's tests" is currently answerable for a minority — the
  passport's test-commands section will expose this gap module-by-module.
- **Stability:** core seven (core, guild, group, member, workflow_assignment,
  notification, editorial) stable since import; periphery accreting
  (+pairing 05-22, +carmelite_dictionary 06-28, mass deletion of ~30
  inherited Open Social modules 06-29, +collab & moodle family 07-01,
  +demo 07-02). Module *lifecycle* (install/uninstall) gate-verified 38/38
  on 2026-07-02 — the boundaries work mechanically even where they're
  undocumented.
- **Bug-shape estimate from coupling:** ~40–45% of bugs single-module,
  ~40% cluster-scoped (3–7 modules), ~15% effectively whole-profile.

### 4.1 The cluster map (co-load groups for non-single-module bugs)

| Cluster | Modules | Co-load estimate |
|---|---|---|
| A. Workflow/editorial (spine) | workflow_assignment, work_management, asset, editorial, content_access, member, group (+core) | ~190k tok — needs surface stubs, never full co-load |
| B. Guild/community | guild, group, member, oidc_claims, pairing, demo (+notification surface) | ~120k tok |
| C. Notifications/comms | notification, email_reply, mailer (+guild surface) | ~72k tok |
| D. Growth/governance | growth, blueprints, delegation, onboarding, telemetry, governance (+guild, mailer surfaces) | ~68k tok |
| E. Media/specialists | video, annotation, clip_review, feedback (+guild surface) | ~78k tok |
| F. Moodle | moodle + oauth/sync/data | ~27k tok |
| G. Standalone (17 modules) | error_report, collab, copyright, registration, scripture, translation, trial, carmelite_dictionary, safeguarding, help, code_sync, content, visual_dam, mailer*, devel, oidc_claims*, demo* | each ≤32k |

*appear in a cluster too; standalone for bugs not crossing the boundary.

## 5. Design

### 5.1 The passport: one `AGENTS.md` per module

Named `AGENTS.md` because it is the emerging cross-tool standard
(Linux Foundation / Agentic AI Foundation since Dec 2025; read natively by
Codex, Copilot, Cursor, Gemini CLI, aider-via-`--read`, 30+ tools;
nearest-file-wins nesting). Claude Code does **not** read it natively yet —
wiring for Claude is a module-level `CLAUDE.md` containing one line,
`@AGENTS.md` (the documented import workaround), **plus** the loop prompt
naming the file explicitly (nested-CLAUDE.md lazy loading has known
reliability bugs; never rely on it alone — and explicit naming works for
every engine anyway).

Hard rules, all evidence-backed:

- **≤150 lines.** Augment's internal study: 100–150-line files with links
  performed like a model-tier upgrade; longer files *reversed* the gains.
- **Judgment sections are hand-written.** The ETH/arXiv 2026 evaluation
  found LLM-generated context files made agents *worse* in 5 of 8 settings;
  developer-written ones gave ~+4%. Claude may draft; a human reviews every
  passport like code. Never mass-generate 43 passports in one unattended
  pass.
- **Factual sections are machine-generated** between markers, and CI fails
  if regeneration differs (§5.3). Facts that can drift must not be
  hand-maintained.

Template:

```markdown
# <module>  <!-- AGENTS.md, ≤150 lines total -->

## Purpose (hand-written, 1–2 lines)

## Place & limits (hand-written — "knows its place")
- This module OWNS: <entities/tables/config namespaces/routes it alone may define>
- This module MAY call: <declared deps and what for, one line each>
- This module MUST NOT: <e.g. "query workflow_task storage directly — use
  WorkManagerInterface", "assume nwc_guild is installed — every reference is
  moduleExists()-guarded", "touch config outside nwc_<name>.*">
- Modules that depend on THIS one rely on: <the promises — service contracts,
  entity fields, hook invocations — that must not silently change>

## Public surface (GENERATED — do not edit between markers)
<!-- passport:generated:begin -->
services: <id → class, one line each, from .services.yml>
routes: <name → path → controller, from .routing.yml>
entities: <type ids + owning classes>
hooks implemented: <list, incl. hook_<other_module>_* "on-behalf" hooks>
declared deps: <from .info.yml — internal + contrib>
undeclared references detected: <from the cross-module scan; MUST be empty
  or each line justified in "Place & limits">
config namespace: nwc_<name>.*  schema files: <n>
<!-- passport:generated:end -->

## Gotchas (hand-written; the tribal knowledge)

## Test & verify (hand-written once, then stable)
- <exact ddev/phpunit/behat commands scoped to this module>
- <if the module has no tests: say so explicitly + name the nearest
  covering Behat phase — an honest gap beats a silent one>

## Owner & escalation
- owner: <human>  ·  cluster: <A–G from MODULES.md>  ·  if a fix needs
  modules outside this dir + declared deps → STOP, relabel cluster::<x>
```

The last line operationalizes "knows its limits": the *module doc itself*
tells the agent when to abandon single-module scope.

### 5.2 Demarcation: provider-owns-contract, consumer-documents-use, thin index

- **Provider:** everything another module may rely on is in the provider's
  passport (its public surface + promises). If it's not listed, it's private
  — and deptrac will treat reaching for it as a violation.
- **Consumer:** one line per dependency in "MAY call" — *what* it uses and
  *why*. No copying the provider's docs (that's how contradictions breed).
- **Central index `MODULES.md`** (profile root, also generated + gated):
  one line per module (name, purpose, cluster, owner) + the cluster table +
  the dependency edge list. ~150 lines total. This is the routing layer's
  input and the agent's level-1 context — Anthropic's progressive-disclosure
  shape exactly: index (~2k tokens) → passport (~1.5k) → code (only the
  scoped module).

### 5.3 Truth enforcement (the P62-cousin — same shape: ruleset + scan + gate)

Three CI checks in the profile repo (`.gitlab-ci.yml` additions — a
**sensitive path**: human-review required, per standing security rules):

1. **Passport drift gate:** `passport-gen --check` regenerates every
   generated block from the YAML/AST and fails on diff. The generator is a
   ~100–200-line PHP/drush script over `.info.yml`, `.services.yml`,
   `.routing.yml`, `config/schema/`, entity attributes, and grep-able hook
   implementations — all first-party machine-readable formats. (Survey
   found no off-the-shelf Drupal "public surface" emitter; the third-party
   AGENTS.md generators are immature. Owning this small script is more
   robust than adopting any of them.)
2. **Boundary gate (deptrac):** one deptrac layer per `Drupal\nwc_*`
   namespace; ruleset *derived from* the `info.yml` dependencies (a tiny
   script keeps `deptrac.yaml` == declared graph, so there is one source of
   truth). Violation = CI red. This is the established PHP tool for exactly
   this (and `deptrac.yaml` doubles as the machine-checkable architecture
   doc).
3. **String-coupling gate:** deptrac only sees `use`-level references, not
   `\Drupal::service('other_module.thing')` strings, YAML wiring, or hooks.
   A grep/phpstan-drupal pass (the same scan the research agent ran) catches
   service-id strings, `config('nwc_X.*')` reads, and entity-type usage
   across module boundaries; anything not declared-or-passport-justified
   fails.

Together these make the passports *load-bearing*: a module can't silently
grow a new tentacle without CI demanding either a declared dependency or a
documented, justified soft-dependency.

### 5.4 Issue → module routing

Extends the two existing entry points; both end with labels the loop reads.

Deterministic first (established practice — Sentry-style ownership
resolution), LLM fallback, human floor:

1. **Path/route signals** (feedback widget already captures the page URL;
   error reports carry stack traces): route path → `.routing.yml` owner;
   stack-trace file paths → module dir globs; entity type names → provider.
   A ~50-line lookup against the generated index. High confidence →
   `module::<name>` label applied by the `nwc-feedback:sync-to-gitlab`
   classifier (it already does tier/class — this is one more field).
2. **LLM fallback:** one cheap call — "given MODULES.md, which module most
   likely owns this report?" — used only when (1) yields nothing; labels
   with `module::<name>` + `triage::llm-routed` (visible provenance).
3. **Low confidence → `triage::needs-routing`,** a human picks the module.
   Rollout follows the standard shadow → assisted → auto ladder; auto-apply
   only after measured precision on the assisted phase.
4. Multi-module signals (paths in ≥2 modules, or the passport's escalation
   line triggered) → `cluster::<A–G>` instead. Whole-profile → stays with
   Claude/human; never routed to a small model.

### 5.5 Agent-loop integration (consumes ops#41's routing)

- New/extended kind: `kind::nwc-module-fix`. The loop resolves
  `module::<name>` → context bundle: `MODULES.md` + the module's `AGENTS.md`
  + passports (not code) of its declared deps; prompt template instructs
  "read these files first; edit only under `<module dir>`; if the fix needs
  more, write AGENT-NOTE.md and stop."
- **Mechanical scope check in the driver** (not trust): before pushing, the
  loop diffs the branch; any file outside the scoped dir(s) → abort + comment.
  This closes the "small model ignores instructions" hole and is worth
  shipping for *Claude* runs too.
- Engine selection per scope (the mentor/shadow plan's promotion policy):
  `module::` in a promoted standalone module → aider+local (once
  shadow-proven per module tier); `cluster::` → Claude; unrouted/profile →
  Claude or human. All output → same MR review gate.

## 6. Why aider for the local seat (and its honest limits)

- **Edit formats are plain text** (SEARCH/REPLACE or whole-file), parsed
  from the completion — no function-calling API. This is the decisive fit:
  local models' tool-calling is their weakest skill; their text output is
  fine. (Claude-Code-via-proxy inherits a harness tuned for frontier
  tool-calling — exactly the wrong assumption for a 96GB-class model.)
- **Scope fencing exists natively:** run from the module dir with
  `--subtree-only`; `--file` (editable) and `--read` (context) whitelists;
  `.aiderignore` for core/vendor/contrib.
- **Ground-truth loop:** `--auto-lint` (`php -l`, phpcs w/ Drupal standard)
  and `--test-cmd` (the passport's test commands) feed failures back for
  retry — cheap iteration where the local model needs it most.
- **Git-native:** auto-commits per edit give Claude-the-reviewer a clean
  per-step diff trail for free.
- **PHP fully supported** in the tree-sitter repo map; drupal.org's own AI
  tooling wiki recommends aider as the established open-source + Ollama
  option, with the explicit warning that agents don't deeply understand
  hooks/plugins/services — i.e., the passport + conventions file is not
  optional garnish, it is the mechanism.
- **Known limits (design around, don't wish away):** exit codes are
  unreliable for scripted use — the wrapper must detect success externally
  (HEAD moved + lint/tests green + scope check) with a hard timeout;
  development has slowed (last release Feb 2026) so 2026 models need manual
  `.aider.model.settings.yml`; if the project stays frozen, **OpenCode** is
  the designated fallback (most-active successor, has headless `run`,
  Ollama support) — the engine seam in §5.5 makes swapping cheap.

### 6.1 Reference configuration (the "tuning")

- Model: **Qwen3-Coder-Next 80B-A3B** (Apache 2.0) at Q6 via llama.cpp
  Vulkan or ollama — aider-polyglot 66.2 (self-reported; the best verified
  ≤96GB score), 3B active params so it's fast on Strix Halo bandwidth.
  Alternatives: gpt-oss-120b at reasoning=high (68.4, community-verified,
  slower wall-clock); Qwen3-Coder-30B-A3B as a fast editor model. Never
  below ~Q4 quantization (measurable coding degradation).
- Frontier gap, stated plainly: ~66–68 vs ~88–89 polyglot. Edit-format
  compliance is a solved problem at this tier (92–98% well-formed); the gap
  is multi-step reasoning. Which is precisely why this proposal pairs the
  local model with **narrow scope + lint/test feedback + Claude review** —
  the configuration under which that tier is workable, per both benchmarks
  and the coupling data (single-module fixes are 40–45% of the queue).
- Invocation shape (wrapper-owned):

```bash
cd <module dir>
aider --subtree-only --yes-always \
  --model ollama_chat/qwen3-coder-next:80b \
  --read ../../MODULES.md --read AGENTS.md --read <dep passports…> \
  --map-tokens 0 \            # scoped bug + weak model: explicit files beat the map
  --lint-cmd "php: php -l" --auto-lint \
  --test-cmd "<passport's test command>" --auto-test \
  --message-file /tmp/task.md
# wrapper then: scope-check the diff, verify HEAD moved + tests green,
# hand the commits to the loop for MR + Claude review
```

- `num_ctx` pinned per model in `.aider.model.settings.yml` (ollama silently
  truncates at 2k otherwise); 32–64k is the working band — KV cache eats
  VRAM, size to the job.
- **No LoRA fine-tuning** (G-non-goal): industrial evidence says RAG/context
  beats per-codebase tuning and tuning goes stale with churn; nobody
  credibly reports LoRA improving aider-style repo fixing. Revisit only if a
  strict house-DSL emerges.

## 7. Implementation phases

Lane discipline: Phases 0–1 edit the nwc profile tree → **queue behind /
coordinate with Lane A** (ops#22/ops#32). Phases 2–4 are meta-repo/loop work
(concurrent-safe). Each phase lands value alone; stop anywhere.

- **Phase 0 — dependency honesty (small, high-value, code-touching).**
  Add the ~20 missing `dependencies:` lines; decide the two hidden cycles
  (§8 OQ-2): either break them (events/BC interfaces) or *sanction* them
  (declare one direction + passport-justify the guarded reverse). Land the
  deptrac + string-coupling CI gates as **warn-only** first, flip to
  blocking once green. CI file changes = human-review path. *Exit:* declared
  graph == runtime graph, enforced.
- **Phase 1 — passports for the stable set.** Build `passport-gen` (+
  `--check`); generate + hand-write passports for the 17 standalone modules,
  cluster F (moodle), and the core seven (surface-only for
  workflow_assignment/guild — their own decomposition is Phase 5, optional).
  `MODULES.md` index. Module-level `CLAUDE.md → @AGENTS.md` shims.
  **New-module template requires a passport** (birth-certificate rule) so
  the accreting periphery self-documents. *Exit:* ≥26 modules passported,
  drift gate blocking.
- **Phase 2 — routing + scoped Claude runs (no local model yet).**
  Classifier emits `module::`/`cluster::` labels (shadow → assisted → auto);
  loop gains `kind::nwc-module-fix` + context-bundle assembly + the
  **mechanical scope check**. Claude runs get scoped context immediately —
  this phase pays for itself before any local hardware works. *Exit:*
  routed issues fixed by Claude with ≤32k context bundles; scope-check
  live.
- **Phase 3 — aider engine, shadow mode.** Re-provision ollama/llama.cpp on
  the ai-host (it is currently down); pull Qwen3-Coder-Next; build the aider
  wrapper (§6.1). Run in **shadow**: same routed issues Claude already
  solved, diff outcomes, auto-grade against the merged fix, accumulate
  per-module scorecards + a lessons file fed back into the conventions doc.
  Zero risk — shadow output never ships. *Exit:* ≥20 shadow runs, scorecard
  per module tier.
- **Phase 4 — promotion.** Standalone modules with ≥N shadow passes flip to
  aider-primary with Claude reviewing every MR (mentor gate); demote on
  regression. Clusters stay Claude. Whole-profile stays Claude/human.
  *Exit:* first local-model MR merged through the normal gate.
- **Phase 5 (optional, later) — the hard two.** Decompose
  workflow_assignment and nwc_guild internally (or write curated ~5k-token
  surface docs that let *dependents* be fixed without loading them);
  refresh/mine workflow_assignment's stale 15-file doc suite into its
  passport; passport the remaining clusters as the module set stabilizes.

Estimated effort: Phase 0 ≈ 1 session; Phase 1 ≈ 2–3 sessions (passport
hand-writing is the long pole — Claude drafts, human reviews, per the ETH
finding); Phase 2 ≈ 1–2 sessions; Phase 3 ≈ 1–2 sessions + model download;
Phase 4 is policy, not build.

## 8. Open questions (operator decisions)

- **OQ-1 — file name:** `AGENTS.md` (standard, future-proof, needs the
  one-line CLAUDE.md shim) vs `CLAUDE.md` (native today, nonstandard
  tomorrow). Proposal assumes AGENTS.md + shim.
- **OQ-2 — the notification cycles:** refactor (notification stops reaching
  into guild/email_reply; use events or move the on-behalf hooks) vs
  sanction (declare + justify; cluster C absorbs them). Refactor is cleaner
  but touches the spine; sanction is honest and cheap. Proposal recommends
  **sanction now, refactor only if cluster-C bugs prove noisy**.
- **OQ-3 — who hand-writes judgment sections:** operator, or
  Claude-drafts-operator-reviews per module (recommended; the ETH result
  argues only against *unreviewed* generation).
- **OQ-4 — routing autonomy threshold:** measured precision required before
  `module::` labels auto-apply (suggest ≥90% over ≥30 assisted routings).
- **OQ-5 — hardware/ops budget:** re-provisioning the ai-host LLM stack is
  a real ops task (its stack has been down since early July) — schedule it,
  or defer Phase 3 and still bank Phases 0–2.

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Passport rot (the classic docs failure) | Generated sections + CI `--check`; hand sections capped at ~100 lines and reviewed like code; drift gate = red MR |
| Verbose/auto-generated context makes agents *worse* (measured, ETH 2026) | 150-line cap; hand-written judgment; no unattended mass-generation |
| Module set still accreting → retrofit churn | Phase passports by stability tier; birth-certificate rule catches new modules |
| aider stagnation | Wrapper + engine seam; OpenCode designated fallback |
| Local model ignores scope | Mechanical driver-side diff check (never prompt-only) |
| Hidden coupling regrows | deptrac + string-coupling CI gates (Phase 0), not periodic audits |
| Lane A collision (profile edits) | Phases 0–1 explicitly queued behind/coordinated with ops#22/#32 |
| Two mega-modules poison scoped fixes in their clusters | Their *surface docs* ship in Phase 1; their decomposition is deferred, optional, and not load-bearing for the 17 standalone modules |

## 10. Success criteria

- [ ] Declared graph == runtime graph (string-coupling scan returns zero
      unjustified hits) — Phase 0
- [ ] ≥26 modules carry gate-checked passports ≤150 lines — Phase 1
- [ ] A routed single-module issue is fixed by Claude with a ≤32k-token
      bundle, scope-check green — Phase 2
- [ ] Routing precision ≥90% on assisted phase — Phase 2/4 gate
- [ ] ≥20 shadow runs scored; ≥1 module tier promoted; first aider MR merged
      through the normal review gate — Phases 3–4
- [ ] Time-to-fix and tokens-per-fix for tier-1 module bugs measurably down
      vs. the pre-P66 loop baseline (the loop's state file + MR timestamps
      give this for free)

## 11. Relationship to existing work

- **ops#41 / §6 loop:** P66 is the context layer under the loop's routing —
  `module::` labels slot into the same label-driven dispatch as `kind::`.
- **Mentor/shadow local-LLM plan (2026-07-03 discussion, unfiled):** P66 is
  its "make tasks winnable" half; the shadow/promotion mechanics are shared.
- **P62 (documentation-truth gate):** same philosophy, different target —
  P62 verifies the private central index against machines; P66 verifies
  module docs against code. Cousins, not dependencies.
- **ops#22/ops#32 (Lane A):** own the profile tree; P66 Phases 0–1 are Lane
  A work items when scheduled.
- **ADR candidate:** "module boundary contract" (provider-owns-contract +
  deptrac-mirrors-info.yml + passport drift gate) deserves an ADR in the
  profile's `docs/decisions/` when Phase 0 lands.
