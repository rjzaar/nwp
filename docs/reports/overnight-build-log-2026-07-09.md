# Overnight autonomous build — decision log (2026-07-09)

**Operator authorization:** full autonomy to complete all waves; test-and-fix (incl. narrative
tests) as you go; multiple agents at max; **auto-merge all MRs**; rollback via preservation;
research any open question with best recommendation and **log every decision here** for morning
review.

**Standing safety rules for this run**
- **Preserve-first / rollback:** before any overwrite/retire/merge, snapshot prior state
  (`git tag pre-<task>-2026-07-09`, tar/copy irreplaceable untracked data). Never leave a dirty
  working tree on `main`.
- **Test before merge:** run the relevant suite (validator for schema; PHPUnit/Behat on `nwc-dev`
  for nwc; narrative Behat where a user-facing flow changes).
- **Merge protocol:** push branch → create+merge MR via GitLab API (admin token via
  `get_infra_secret gitlab.api_token`). If the API fails, leave the MR **open** (operator
  auto-approves on GitLab) — never force-merge to `main` locally.
- **Dev/test tier only.** Never touch real prod or mons. `*.nwpcode.org` test tier only (A14).
- **F26 / auth = branch-only, NOT merged** (operator wants to review the auth surface first).
- **Sanitizer / legal text / `.gitlab-ci.yml` / `CLAUDE.md`:** if any task would touch these, stop
  and log for morning review rather than auto-merging.

---

## Decisions (chronological)

### Design decisions settled in-session (2026-07-08/09) — see NWP-ADR-0027
1. Canonical = `nwp/courses`; adapters disposable. 2. Two boundaries (safeguarding=people /
content=flows-signed). 3. Federation by overlay, not fork. 4. Member-level CC0, identity severed at
boundary. 5. Ceremony scales with trust distance. 6. Audience birthing ladder (IG→guild→site).
7. Audience vocab = youth·single·married·religious·priest (open). 8. Contributed = community-tier
default. 9. Formative-value axis = bounded yes. 10. Per-member signing key. 11. Retire F30.
12. Promote Writers + Pedagogy IGs → guilds. 13. Sojourners proposes core / Theology approves
(apprenticeship). 14. Scores = the site's grading, opt-out visibility, corroboration-based,
recognition-framed.

### Build-run decisions
- **BR-1 (reconciliation):** Report proved v3 is a clean byte-identical superset of v1; the whole
  gap is one course (v1 `D6`, 32 quizzes) whose only copy is untracked and whose backup is broken.
  → **Decision:** preserve v1 `D6` (+ the whole v1 source) in 3 places before anything; do NOT
  auto-retire v1 or auto-merge the reconciliation content change — leave the v1-`D6` disposition
  (retire vs re-slot to D9) for operator. *Rationale: irreversible content loss risk; operator's
  preserve-for-rollback directive.*
- **BR-2 (F26):** built on a branch + MR, **not merged**. *Rationale: auth surface; operator's
  specific "present me so I can tweak it" instruction overrides blanket auto-merge.*
- **BR-3 (schema v3.1):** additive/backward-compatible; existing flat LPs validate as implicit
  single `core`; audience vocab is an OPEN list (validator warns, never rejects). *Rationale: zero
  regression on the live 55-course catalog.*

*(Agents append their build/decision notes here as they complete — aggregated by the orchestrator.)*

---

## Wave status
- **Wave 0 (preserve + docs + approvals):** IN PROGRESS.
- **Wave 1 (schema v3.1 · guild seeding):** IN PROGRESS.
- **Wave 2 (editorial engine: compound-key fix, scoring wiring, audience-fit stage, Theology
  confirm-gate, story_contribution):** QUEUED (after Wave 1 merges).
- **Wave 3 (un-strip Moodle build, repoint app build, ops#62 help publish):** QUEUED (after schema
  + reconciliation disposition).
- **F26 (branch-only):** IN PROGRESS → awaits operator merge.
