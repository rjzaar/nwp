# F26: Integrating the SolveIt Methodology into NWP

**Status:** PROPOSED
**Created:** 2026-03 (renumbered as F26 on 2026-04-07)
**Author:** Rob Gillespie
**Priority:** Medium
**Depends On:** None
**Breaking Changes:** No (additive process documentation)

> Originally drafted as `nwp-solveit-proposal.docx` (March 2026, v1.0 Draft).
> Converted to Markdown and renumbered F26 during the F25 baseline reset.

---

## 1. Executive Summary

This proposal outlines a plan to formally integrate the SolveIt methodology — an iterative, AI-assisted development framework created by Jeremy Howard at Answer.AI — into the Narrow Way Project (NWP). The SolveIt method emphasises small-step development, shared human-AI context, and a learning-first mindset. While the SolveIt platform itself is a paid, proprietary tool built around Python, the underlying methodology is freely adoptable and aligns closely with the iterative development patterns already used in NWP.

The goal is not to adopt the SolveIt platform, but to formalise its principles into a documented, repeatable process embedded within NWP's existing toolchain of DDEV, GitHub Actions, Bash scripting, Drupal, and Moodle development. This proposal also identifies the ACMC (Automatically Concept Mapping the Catechism) project as a natural pilot for the methodology, given its Python-centric stack.

## 2. Background

### 2.1 What Is SolveIt?

SolveIt is an AI-integrated development platform and methodology created by Jeremy Howard (founder of fast.ai) and Eric Ries (author of *The Lean Startup*), built and maintained by Answer.AI, a Public Benefit Company. The platform is available at solve.it.com.

The platform provides a cloud-based Linux development environment with an integrated AI assistant, Monaco editor (the same engine as VS Code), and a structure called "dialogs" — saved workspaces where notes, code, and AI conversation coexist. It is designed around what Howard calls "Dialog Engineering."

**Key insight:** By building code iteratively with planning, notes, and tests mixed in with the source code, you are simultaneously building the perfect context for an AI to assist effectively. The AI sees everything you see, uses the same tools, and becomes a genuine iterative partner.

### 2.2 The SolveIt Methodology (Platform-Independent)

The methodology is distinct from the platform. Its core principles, drawn from Pólya's *How to Solve It* (1945), the fast.ai tradition, and the nbdev literate programming approach, are:

| Principle | Description |
|---|---|
| Small Steps | Write 1–2 lines at a time, verify each one, then build up. Never ask AI to generate large blocks of code in one go. |
| Shared Context | Keep notes, tests, and code together in the same document. The AI should see exactly what you see — no summarising. |
| Conversation Hygiene | When the AI goes down a wrong path, go back, clean up, and redirect rather than prompting forward into confused context. |
| Full Transparency | Give the AI the actual error output, the actual file, the actual context. Paste real output, not summaries. |
| Learning-First | When the AI suggests something unfamiliar, stop and learn it rather than blindly accepting. The goal is understanding, not just output. |
| Iterative Packaging | Once a series of small steps solves part of the problem, package them into a function, script, or module. Then iterate on the next part. |

### 2.3 SolveIt Platform: Pricing and Licensing

The SolveIt platform is not free and not open source. The course includes 30 days of platform access, after which a $10/month subscription is required. Answer.AI is a Public Benefit Company but has not released the platform source code. However, Howard has explicitly stated that the core principles can be practised on any platform with any tools.

### 2.4 The Narrow Way Project (NWP)

NWP is a comprehensive toolkit for managing Drupal/Open Social and Moodle installations throughout their lifecycle. It evolved from the earlier Pleasy library and uses DDEV for local development, GitHub Actions for CI/CD, and a suite of Bash scripts for installation, backup, restore, deployment, and site management.

NWP's current scope includes:

- **cinstall.sh:** Automated OpenSocial/Drupal installation with DDEV, including GitHub token support, checkpoint/resume, and interactive mode
- **Site management:** Backup, restore, copy, delete, and update scripts (in development, migrating from Pleasy)
- **Module ecosystem:** commons_template, workflow_assignment (custom content entity), commons_install
- **Moodle integration:** OpenSocial–Moodle SSO via Simple OAuth, Moodle install/upgrade scripts
- **CI/CD:** GitHub Actions pipelines for testing and deployment
- **ACMC project:** Python-based concept mapping of the Catechism using PostgreSQL/pgvector, spaCy, and sentence transformers

## 3. Gap Analysis: Current NWP Workflow vs. SolveIt Principles

NWP development already aligns with several SolveIt principles in practice, though not formally documented. The following analysis identifies where the methodology is already present and where formalisation would add value.

| SolveIt Principle | Current NWP Practice | Gap |
|---|---|---|
| Small Steps | cinstall.sh uses step-based architecture with checkpoint/resume. Iterative development with Claude in conversation. | Not formalised. No documentation template encourages small-step iteration. |
| Shared Context | Conversations with Claude include full error output and file contents. GitHub repos serve as shared context. | Context is ephemeral (lost between chat sessions). No persistent dialog document alongside code. |
| Conversation Hygiene | New chat threads started when context becomes confused. | No formal protocol. Old threads sometimes accumulate confusion before being abandoned. |
| Full Transparency | Actual error output and file contents routinely pasted into conversations. | Strong alignment. No significant gap. |
| Learning-First | Understanding sought for unfamiliar suggestions (e.g., kernel driver migration, entity architecture). | Implicit, not documented. Some sessions prioritise output over understanding under time pressure. |
| Iterative Packaging | Functions extracted into scripts; modules packaged as Drupal entities. | Good practice but inconsistent. Some scripts grow monolithically before refactoring. |

## 4. Proposed Integration Strategy

The integration is structured in three layers: a documentation layer (formalising the methodology for NWP), a tooling layer (practical scripts and templates), and a pilot project (ACMC as the first full implementation).

### 4.1 Layer 1: Documentation — The NWP Development Protocol

Create a formal document, `DEVELOPMENT_PROTOCOL.md`, to be included in the NWP repository root. This document codifies the SolveIt methodology as adapted for NWP's specific toolchain.

**Contents of `DEVELOPMENT_PROTOCOL.md`:**

1. **The Small-Step Rule:** All new features developed in increments of 1–5 lines of code at a time when working with AI assistance. Each increment tested or verified before proceeding.
2. **The Dialog Document Pattern:** For each significant development task, maintain a companion Markdown file (e.g., `feature-name.dialog.md`) that interleaves notes, rationale, code snippets, test results, and AI conversation excerpts.
3. **Context Protocol:** When starting a new AI conversation about NWP, always provide: (a) the relevant script or module file, (b) the specific error or goal, (c) the current state of the system. Never summarise when you can paste.
4. **Conversation Reset Triggers:** Start a fresh AI session when: the AI has made 3+ incorrect suggestions in succession, the context window is approaching limits, or the direction of exploration has fundamentally changed.
5. **Learning Checkpoints:** When the AI suggests a technique, library, or pattern you don't fully understand, pause development and ask it to explain the concept before implementing it. Document the explanation in the dialog file.
6. **Packaging Cadence:** After every 3–5 successful small steps, consider whether the accumulated code should be packaged into a named function, script section, or module. If it should, do it before continuing.

### 4.2 Layer 2: Tooling — Dialog Templates and Scripts

Practical tooling to support the methodology within NWP's existing infrastructure.

#### 4.2.1 Dialog Document Template

A standardised Markdown template for dialog documents, stored at `templates/dialog.template.md`:

- **Header block:** Feature name, date started, NWP component (e.g., cinstall, workflow_assignment, ACMC), current status
- **Goal statement:** One-paragraph description of what this development session aims to achieve
- **Steps log:** Numbered entries with timestamp, code change, test result, and notes
- **AI interaction log:** Key prompts and responses (not full transcripts — curated highlights)
- **Decisions record:** Why a particular approach was chosen over alternatives
- **Packaging notes:** What was extracted into functions/modules, and where

#### 4.2.2 Context Preparation Script

A Bash script, `nwp-context.sh`, that assembles the current state of an NWP component into a single file suitable for pasting into an AI conversation:

- Collects the target script/module file(s)
- Appends recent git log entries for the relevant files
- Appends any recent error logs from DDEV
- Appends the current `nwp.yml` configuration
- Outputs a single Markdown-formatted context block to clipboard or file

#### 4.2.3 Session Review Script

A post-session script, `nwp-review.sh`, that prompts the developer to:

- Summarise what was accomplished in this session
- Record any new concepts learned
- Identify any code that needs packaging/refactoring
- Note any unresolved issues for the next session
- Append the summary to the relevant dialog document

### 4.3 Layer 3: Pilot Project — ACMC

The ACMC (Automatically Concept Mapping the Catechism) project is the ideal pilot for full SolveIt methodology adoption within NWP, for several reasons:

- **Python-centric:** ACMC uses Python (spaCy, sentence transformers, FastAPI), which is the native language of the SolveIt methodology and its nbdev heritage.
- **Exploratory nature:** Concept extraction from theological text is inherently iterative — you cannot specify the correct extraction rules upfront. The small-step approach is natural.
- **AI-heavy:** ACMC relies on Claude for concept extraction during setup. The dialog document pattern directly captures the extraction refinement process.
- **Clear packaging cadence:** The pipeline (scrape → extract → store → cluster → serve) has natural packaging boundaries that align with the iterative packaging principle.
- **Long-term reference value:** Dialog documents from ACMC development become a permanent record of how theological NLP decisions were made — invaluable for the MEd research context.

**ACMC Pilot Implementation Plan:**

1. **Set up the dialog document:** Create `acmc.dialog.md` in the ACMC repository root. Initialise with the goal statement, technology choices, and architecture overview from the existing analysis document.
2. **First iteration — Catechism scraping:** Using the small-step approach, build the scraping pipeline in 1–2 line increments, documenting each step. Target: all 2,865 paragraphs stored in PostgreSQL with metadata.
3. **Second iteration — Concept extraction:** Use Claude API to process a sample section (e.g., Part One, Section Two on the Creed). Document the extraction prompt refinement process in the dialog file. Target: validated extraction schema.
4. **Third iteration — Graph construction:** Build the concept graph, relationship typing, and Louvain clustering. Package each stage into tested functions. Target: navigable concept map of the sample section.
5. **Review and retrospective:** Assess the methodology's impact on development quality, speed, and understanding. Document findings for application to NWP's Bash/PHP codebase.

## 5. Applying the Methodology to NWP Core Development

While ACMC is the natural pilot, the methodology should be progressively adopted across NWP's Bash and Drupal/PHP codebase. The adaptation requires acknowledging that PHP/Bash development has different rhythms from Python/notebook workflows.

### 5.1 cinstall.sh and Bash Scripts

The cinstall.sh script already uses a step-based architecture with 14 numbered steps, checkpoint/resume capability, and colour-coded output. This is naturally aligned with the SolveIt approach. Formalisation means:

- Maintaining a `cinstall.dialog.md` that tracks the evolution of each step, decisions made, and bugs resolved
- Using the context preparation script before each AI-assisted development session
- Applying the conversation reset triggers when debugging complex DDEV/Drush issues
- Packaging each new capability (e.g., selective reinstall, module update detection) as a discrete function before moving to the next

### 5.2 Drupal Module Development

For the workflow_assignment module and other custom entity development, the small-step approach translates to:

1. Define one field or method at a time in the entity class
2. Test with DDEV immediately after each addition
3. Document the entity architecture evolution in a dialog file
4. When the AI suggests Drupal API patterns, pause to understand the hook/plugin/service pattern before implementing
5. Package completed features behind clean interfaces before starting the next feature

### 5.3 GitHub Actions CI/CD

CI/CD pipeline development is already inherently iterative (push, fail, fix, push). The methodology adds the dialog document to capture why specific workflow configurations were chosen, and the learning checkpoint to ensure that YAML pipeline syntax and GitHub Actions concepts are understood, not just copied.

## 6. Integration with Claude Memory and Persistent Context

A significant advantage of formalising dialog documents is their utility as persistent context for Claude. Currently, NWP development context is partly captured in Claude's memory system but is incomplete and recency-biased. Dialog documents provide:

- **Session continuity:** At the start of each new Claude conversation, paste the relevant dialog document's recent entries. This is far more effective than relying on memory or trying to reconstruct context from scratch.
- **Decision archaeology:** When revisiting code months later, the dialog document explains why decisions were made — something git commit messages rarely capture adequately.
- **Onboarding context:** If NWP is ever developed collaboratively, dialog documents serve as onboarding material for new contributors.

## 7. Cost-Benefit Analysis

| Factor | Assessment |
|---|---|
| Financial cost | Zero. The methodology is free to adopt. No SolveIt platform subscription required. |
| Time investment | Moderate upfront (creating templates, writing the protocol document). Estimated 4–6 hours of initial setup. |
| Ongoing overhead | Minimal. Dialog documents add 5–10 minutes per development session. Context preparation script saves more time than it costs. |
| Quality improvement | High. Small-step iteration catches errors earlier. Dialog documents prevent repeated mistakes across sessions. |
| Learning value | High. Learning checkpoints ensure that NWP development builds genuine understanding, not just working code. |
| Risk | Low. The methodology is additive — it doesn't require changing any existing tools or workflows, only supplementing them. |

## 8. Implementation Phases

| Phase | Deliverables |
|---|---|
| Phase 1: Foundation | `DEVELOPMENT_PROTOCOL.md` written and committed. Dialog document template created. Context preparation script (`nwp-context.sh`) built. |
| Phase 2: ACMC Pilot | ACMC development conducted entirely under the new methodology. `acmc.dialog.md` maintained throughout. First working concept map of a Catechism section. |
| Phase 3: Retrospective | Assessment of methodology impact. Refinements to protocol based on ACMC experience. Blog post or notes documenting findings. |
| Phase 4: NWP Core Adoption | Dialog documents started for cinstall.sh, workflow_assignment, and commons_template. Session review script (`nwp-review.sh`) built. Methodology becomes standard practice. |

## 9. Conclusion

The SolveIt methodology offers NWP a structured, low-cost framework for improving the quality, reproducibility, and educational value of its development process. The methodology's emphasis on small steps, shared context, and learning-first development aligns naturally with NWP's existing iterative approach but formalises it into a documented, repeatable protocol.

The ACMC project provides an ideal pilot: Python-centric, AI-heavy, exploratory, and with clear packaging boundaries. Success there will generate both a working concept mapping tool and a proven process template for NWP's broader Bash and Drupal codebase.

The cost is effectively zero. The return is better code, better understanding, and a permanent record of development decisions that pays dividends every time a script is revisited or a module is extended.

## Appendix A: References and Resources

- **SolveIt Platform:** https://solve.it.com/
- **Answer.AI Blog — SolveIt Launch:** https://www.answer.ai/posts/2025-10-01-solveit-full.html
- **fast.ai — Features Guide:** https://www.fast.ai/posts/2025-11-07-solveit-features.html
- **Johno Whitaker — What Is SolveIt?:** https://johnowhitaker.dev/posts/solveit.html
- **George Pólya,** *How to Solve It* (1945) — The foundational problem-solving methodology
- **NWP Repository:** https://github.com/rjzaar/nwp
- **ACMC Analysis Document:** Previously prepared comprehensive implementation analysis (March 2026)
