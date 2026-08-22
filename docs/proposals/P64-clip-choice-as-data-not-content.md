# P64 — Clip choice as data, not content

**Status:** PROPOSED
**Owner:** *(unassigned)*
**Surfaced by:** Worker-A session 2026-05-22 (Track A clip-review smoke test)
**Predecessor:** `sites/avc/.../docs/proposals/A28-clip-review.md` (clip-review module design); `sites/nwc/.../docs/decisions/0017-media-guild-promotion.md` (Media Guild as the review pool)
**Estimated effort:** ~1.5 days focused, plus migration verification on a non-trivial subset of catalogs
**Risk:** medium-low — additive entity in NWC, swap of one write target in MrGeneratorService, one-time YAML strip of `video:` blocks across 55 catalogs

## Problem

The clip-review pipeline (`avc_clip_review`, soon to port to `nwc_clip_review`) treats a curated video clip as **editorial content** stored in the per-course catalog YAML, alongside title/text/sources. An "apply" decision means opening a GitLab MR against `nwp/courses` that mutates a `video:` block inside `courses_v3/catalog/<course>.yaml`. The MR machinery is in `MrGeneratorService::openMr()` and the catalog-mutation logic is in `MrGeneratorService::applyVideoBlock()`.

This is structurally wrong. The clip-review module is purpose-built for **iterating clip choices frequently** — slots, suggestions, snippets, signals, dashboards, dual-attestation review via Media Guild (NWC-ADR-0017). Iteration-heavy operational data does not belong in slow-moving human-edited course content. The mismatch is what makes the YAML-editing fragile, and it is what makes every routine clip swap a MR-review-and-merge ceremony rather than a transactional operation.

The smoke test on 2026-05-22 surfaced one concrete consequence of the mismatch: the regex in `applyVideoBlock()` silently no-ops on every current catalog file, so the production pipeline opens zero real MRs and falls back to writing JSON request files into a private directory that nobody is reading.

## Concrete bug surface (snapshot 2026-05-22, smoke test against slot 10)

Smoke test executed via `ReviewDecisionService::apply()` against `LpReviewSlot.id=10` (course=A1, lp=A1.01, depth=standard, swap snippet 59 → 60):

- Drupal state mutated: slot status `pending → applied`, `current_clip 59 → 60`, ClipSuggestion #51 created and marked applied, ReviewDecision #3 created.
- MrGeneratorService wrote `private/clip_review/mr_requests/slot-10-suggestion-51-20260522080614.json` correctly.
- `maybeOpenGitlabMr()` fetched `courses_v3/catalog/A1.yaml` from `<gitlab-host>/nwp/courses` fine, called `applyVideoBlock()`, got `$updated === $existing_yaml`, logged "No-op: YAML unchanged for slot 10", and returned NULL.
- No branch created, no MR opened. Confirmed via `GET /projects/nwp%2Fcourses/repository/branches?search=clip-review` (empty) and `GET /merge_requests?state=opened&search=clip-review` (empty).

Root cause of the no-op:

The regex in `MrGeneratorService::applyVideoBlock()` (`src/Service/MrGeneratorService.php:175`) hardcodes:

```
(- id: $lp_id\b[\s\S]*?depths:\s*\n[\s\S]*?  $depth:\s*\n[\s\S]*?  video:\s*\n)
(    episode:\s*\d+\s*\n    start:\s*[^\n]+\n    end:\s*[^\n]+\n
 (    duration_min:\s*[^\n]+\n)?(    youtube_id:\s*[^\n]+\n)?)
```

— assumes 2-space indent for `depths:`, `<depth>:`, `video:`, and 4-space indent for `episode/start/end/...` children.

Actual `courses_v3/catalog/*.yaml` (PyYAML default block style) uses:

```
  - id: A1.01           # 2-space (with hyphen)
    title: ...          # 4-space
    depths:             # 4-space
      standard:         # 6-space
        text: '...'     # 8-space
        video:          # 8-space
          episode: 645  # 10-space
          start: 06:56  # 10-space
          end: 08:55    # 10-space
          ...
```

Plus three further variations across the 55 catalogs:

- **Timestamp quoting is inconsistent.** PyYAML's sexagesimal-safety heuristic quotes some and not others within the same file: `start: 06:56` vs `start: '22:01'` vs `start: '3:50'` vs `start: 0:00`. The regex's `start:\s*[^\n]+` accidentally tolerates this, but any handwritten replacement must produce a value the next round won't break on.
- **Optional fields.** `duration_min` and `youtube_id` are both optional in practice. Some video blocks omit one or both. Some `video:` blocks are followed by `sources:`, some are immediately followed by a sibling depth (`longer:`).
- **No tests exist against real catalog fixtures.** A28 and the module's existing PHPUnit cases don't include a captured `A1.yaml` (or any other course YAML) as a fixture, so format drift in `nwp/courses` cannot be caught at CI time.

## Why "fix the symptom" is not the recommended path

Three options were considered as bug-patch fixes:

| Approach | Diff size | Robust? | Effort |
|---|---|---|---|
| Fix the regex's indentation constants | Tiny | No — still hardcodes structure; brittle to next reformat | 15 min |
| Full Symfony YAML round-trip (parse → mutate → dump) | **Whole file reformats** (key ordering, quoting, multiline strings) | Yes | 1 hr |
| Parse to locate + textual surgical edit + reparse to validate | Tiny (3–5 lines change) | Yes | 2–3 hr |

The last of these (parse-locate-edit-validate) is the right answer **if we keep editing the catalog YAML**. But every one of these patches leaves us still editing course content for every clip swap — keeping the MR-as-gate ceremony, keeping the file-format dependency, keeping the test-fixture maintenance burden.

If clip-review's domain operation is "pick a better clip for this LP", that operation should not require:
- A regex over hand-edited YAML
- A round-trip through GitLab API (3 calls: fetch, branch, commit) per swap
- An MR opened, reviewed, merged
- A consumer rebuild step downstream

The cost of those is acceptable only if clip swaps are **rare** and **editorially significant**. Clip-review's module shape (slots, suggestions, snippets, signals, dashboards, dual-attestation) is built for the opposite — frequent, structured, gradient-of-confidence iteration.

## Proposed architecture: clip choices as first-class data

### Shape

Introduce a `clip_choice` Drupal entity in the NWC profile (`sites/nwc/dev/html/profiles/custom/nwc/modules/nwc_features/nwc_clip_review/` once the AVC → NWC port lands; an interim copy in AVC if the AVC site needs to keep functioning before the cutover). The entity is keyed by `(course_id, lp_id, depth)` and stores:

| Field | Type | Notes |
|---|---|---|
| `course_id` | string | e.g. `A1` |
| `lp_id` | string | e.g. `A1.01` |
| `depth` | string enum | `short` / `standard` / `longer` |
| `episode` | int | e.g. `645` |
| `start_s` | decimal(10,3) | seconds, e.g. `416.000` |
| `end_s` | decimal(10,3) | seconds, e.g. `535.000` |
| `youtube_id` | string | e.g. `lrgODcWOjnQ` |
| `duration_s` | decimal computed | derived `end_s - start_s`, stored for query convenience |
| `provenance_snippet` | reference to `video_snippet` | the snippet this choice was derived from; null for hand-set |
| `provenance_suggestion` | reference to `clip_suggestion` | the suggestion that drove this apply; null for hand-set or migration-seeded |
| `decided_by` | reference to user | actor who applied |
| `decided_at` | timestamp | apply time |
| `note` | text | admin note copied from `ReviewDecision.note` |
| `live_from` | timestamp | when this choice became live; supports staged go-live if needed |

Drupal revisions enabled on the entity so per-row history is queryable.

The entity is exposed read-only via JSON:API at `/api/clip-choices/{course_id}` (whole-course map) or `/api/clip-choices/{course_id}/{lp_id}/{depth}` (single). No write API — writes go through `ReviewDecisionService::apply()`.

### Apply path becomes transactional

`ReviewDecisionService::apply()` (today's flow at `ReviewDecisionService.php:29–73`) keeps its responsibilities but swaps its terminal step. The current line `$mr_url = $this->mrGenerator->openMr(...)` becomes `$revision = $this->clipChoiceWriter->upsert(...)`. The returned identifier on `ReviewDecision.mr_url` becomes a `clip-choice://{course}/{lp}/{depth}#{revision_id}` URI — a stable reference into the entity's revision log.

`MrGeneratorService::openMr()`, `maybeOpenGitlabMr()`, `applyVideoBlock()`, `buildCommitMessage()`, `buildMrDescription()` all delete. The `private/clip_review/mr_requests/` JSON queue and its writer (`writeMrRequest()`) also delete — the queue exists because the GitLab leg was best-effort; once the choice writes to a transactional entity, the queue's purpose is gone.

The whole `gitlab_*` config block under `avc_clip_review.settings` (and the equivalent in `nwc_clip_review.settings`) is deprecated and removed in the same release.

### Player

The course player no longer reads `video:` blocks from the catalog. Instead:

- **NWC course-render path** (Drupal): a new block plugin `clip_player_block` that takes `(course_id, lp_id, depth)`, queries the clip-choice service, and renders a YouTube IFrame Player API embed with `start=N&end=M`. ~100 lines including a small JS hook on `onStateChange` to pause exactly at `end_s` (YouTube's native `end=` overshoots by ~1 second; the JS hook gives sub-second fidelity). Cache: render-cache keyed by `(course_id, lp_id, depth, revision_id)`; invalidated by an entity-save hook on `clip_choice`.

- **SS Moodle course player** (only if Moodle remains in service past the NWC cutover): a Moodle activity module of the same shape. ~150 lines. If the NWC cutover is close enough that SS Moodle won't see new clip swaps before retirement, this can be skipped — SS retires on the frozen catalog.

- **Future Vimeo / self-hosted video.** The player block accepts an optional `video_source` enum (`youtube` / `vimeo` / `mp4_url`); YouTube is the only implementation in the initial cut. Adding Vimeo is an additive change to the block, not a data-shape change.

### Catalog becomes editorial-only

Once clip choices live in the entity, the `video:` block in every `courses_v3/catalog/*.yaml` is dead weight. One migration MR on `nwp/courses` removes all `video:` blocks. The catalog's job becomes purely: course metadata + LP titles + depth text + sources + tags + pathways. Editorial content, slow-moving, hand-edited, where YAML belongs.

The catalog's `sources:` field stays — that's editorial provenance, not operational data.

### Downstream consumers (Flutter app, ccapp)

**Surfaced 2026-05-22 during the Flutter v3 update:** the Faith Formation app (`~/nwp/sites/ss2/dev/faith_formation/` post-2026-05-23 — was `ss1/dev/faith_formation/` 2026-05-16 → 2026-05-23, was `ss/dev/faith_formation/` before that; launched via `~/.local/bin/ccapp`) reads `video:` blocks from the catalog YAML via `tools/build_seed_db.py`. The script populates the SQLite seed DB columns `video_episode`, `video_start`, `video_end`, `video_duration_min`, `video_youtube_id` — used by the in-app course player to embed YouTube clips with start/end times. If step 6 of the migration plan strips `video:` blocks from the catalog, the Flutter app's next seed-DB rebuild will produce courses with no clip data, breaking in-app clip playback for all 247 learning points.

Three resolution options, ordered by simplicity:

1. **Keep catalog `video:` blocks as a denormalised read-cache (recommended starting position).** Skip step 6 of the migration plan. Catalog still carries `video:` for read-only consumers (Flutter, future static-site renderers). Source of truth becomes the `clip_choice` entity; catalog is regenerated from the entity by a drush command after every apply. Trade-off: the catalog YAML keeps a redundant field, but file-based consumers don't change. **This is the lowest-risk path** because it preserves the existing Flutter contract while still moving the operational data into the entity.

2. **Flutter switches to NWC JSON:API.** `build_seed_db.py` is rewritten to pull clip choices from `https://nwc.<example-prod-domain>/api/clip-choices/{course_id}` at build time, alongside the catalog YAML for editorial content. Trade-off: build-time dependency on a live NWC site (offline builds need a cached snapshot); but architecturally cleanest — Flutter follows the same source-of-truth move.

3. **Flutter ships pre-cutover catalog as frozen seed.** If Faith Formation app development is paused, the current seed DB (49→55 courses, just rebuilt 2026-05-22) is "good enough" for a long time. Skip Flutter from the cutover entirely; new clip choices stop reaching the app until someone picks up option 2.

**Recommendation:** option 1 for the cutover, option 2 as a follow-up once the JSON:API is stable. The catalog-regen drush command is small (~30 lines) and preserves every existing consumer's contract. Whoever owns P64 must add this drush command to the migration plan as a new step 6b ("regenerate catalog from clip_choice entity") and downgrade step 6 (strip catalog video: blocks) to optional / never-runs-by-default.

Other downstream consumers to audit before catalog strip:
- **SS Moodle**'s catalog reader (covered in R6 risk above; resolved by NWC cutover timing).
- **nwp/courses static-site renderer** (if any exists in the future) — same JSON:API path applies.
- **External forkers** (per fork-seam NWC-ADR-0017) — they may read catalog `video:`; documenting the catalog-as-read-cache option preserves the fork's contract.

### Review gate

A28 implicitly leaned on MR review as the human gate before a clip swap goes live. That gate disappears under this proposal. Two ways to restore it cleanly:

1. **Dual-attestation per Media Guild (NWC-ADR-0017).** Two Media Guild members independently propose the same swap on the same slot. Their suggestions match per the matching-rule tolerances defined in `VIDEO_GUILD_v3.md`. The apply is automatic on match. This is review-by-structure, not review-by-gatekeeper, and it's exactly what the Media Guild was promoted to provide.

2. **Pending-state on `clip_choice`.** Add a `status` field (`pending` / `live`). Apply writes a `pending` row; a Master-tier Media Guild member (or guild-admin) flips it to `live`. The player reads only `live` rows. Equivalent to MR review, in-app, without the GitLab round-trip.

These compose: dual-attestation suggestions go straight to `live`; solo suggestions stay `pending` until a Master flips them. This mirrors NWP-ADR-0011's pipeline-operator scoping cleanly.

### Audit trail

Drupal entity revisions cover per-row history (actor, timestamp, before/after, note) — queryable in-app and via JSON:API. For an external, greppable, git-tracked log:

- A nightly drush command appends new `clip_choice` revisions to `clip_choices_history.jsonl` in the `nwp/courses` repo. One commit per night, one line per revision. Immutable. The courses repo gains a long-term audit log without per-apply commit overhead.
- The job is idempotent — it tracks `last_exported_revision_id` in state and resumes cleanly after failure.

This preserves "git is the audit trail" for clip choices, just at a different granularity (nightly batch vs. per-swap MR).

## Migration plan

In dependency order, each step independently verifiable:

1. **Build `clip_choice` entity + storage + JSON:API endpoint** in `nwc_clip_review`. Drupal install hook seeds an empty table. No data, no consumers yet.

2. **Build `clip_choice_writer` service.** API: `upsert(course_id, lp_id, depth, $video_block, $provenance, $actor, $note)`. Wired into `ReviewDecisionService::apply()` behind a feature flag `clip_review.use_db_choice` (default off in this commit, on in a later commit). The MR path still runs while the flag is off.

3. **Build `clip_player_block`.** Includes pause-at-end JS. Render-tested against three test slots seeded in step 4.

4. **Seed migration: drush command `nwc-clip-review:seed-from-catalog`.** Walks every `courses_v3/catalog/*.yaml`, reads each `video:` block, upserts a `clip_choice` row with `provenance_snippet = NULL` and a synthetic note `"seeded from catalog $sha on $date"`. Idempotent — re-running is a no-op. Verified by spot-checking 5 LPs across 3 courses (a "render before" / "render after" comparison against the actual SS Moodle iframe params).

5. **Cutover commit:** flip `clip_review.use_db_choice` to `on`. From here, apply writes the entity. Players read the entity. The MR machinery still exists but is unreachable.

6. **Catalog strip MR on `nwp/courses`:** one bulk MR removes every `video:` block from every catalog file. Tag `catalog-v3.1` on merge.

7. **Decommission MrGeneratorService.** Delete the GitLab MR code, the JSON queue, the `gitlab_*` settings keys. Update CLIP-REVIEW-HANDOVER-2026-05-19.md (or its NWC successor) accordingly.

8. **Backfill audit log:** drush command writes one historical export of every `clip_choice` revision (created during seeding + any applies between step 5 and step 8) to `clip_choices_history.jsonl`. After this, the nightly job continues from `last_exported_revision_id`.

9. **Retire SS Moodle's catalog `video:` reader** if SS is still live. If not, skip.

Estimated calendar time: 1 working day for steps 1–5 if focused; another 0.5 day for steps 6–8; step 9 only if applicable.

## Risks and open questions

**R1. Behaviour parity at cutover.** Seeding catalog → entity must be byte-exact for the player to render the same video position on the same LP/depth pre- and post-cutover. Mitigation: render-diff harness in step 4 that hits a sample of LPs through both code paths and asserts equality on `(youtube_id, start_s, end_s)` integer-seconds.

**R2. Drupal-entity-as-API performance.** SS Moodle (still on the old path during transition) plus a future NWC player both reading clip choices over HTTP is a new dependency. Mitigation: ETag + Last-Modified headers on the JSON:API endpoint; consumer caches keyed on those; render-cache invalidation hook on entity save. The data is tiny (3 ints + 1 string per LP) and read-mostly; this should not be a load concern.

**R3. Cross-site write authority.** Today, only `nwp/courses` reviewers can change the catalog (MR review). Under this proposal, anyone with `apply clip suggestion` permission in NWC can change a clip choice instantly. Mitigation: the permission stays guild-admin-restricted as today (`ReviewDecisionService::apply()` already enforces `'apply clip suggestion'` permission at line 31); only Master-tier Media Guild members get that permission via role mapping. The review gate moves into the role/guild model rather than the MR model.

**R4. Loss of `git log` for clip changes.** Removed by `nightly clip_choices_history.jsonl` export (see Audit trail above). Open question: is one batched commit per night acceptable, or should the granularity be smaller (e.g., one commit per apply, triggered by entity-save hook)? Recommend nightly for noise reduction; revisit if reviewers complain.

**R5. The Media Guild matching-rule tolerances are not yet defined.** Dual-attestation as the auto-apply gate depends on `VIDEO_GUILD_v3.md`'s skill definitions being finalised for the Clip Selection skill. Until they are, all applies route to the pending-state gate (Master flips to live). This is fine as a starting position and the pending path is the safer default anyway.

**R6. SS Moodle's existing catalog-dependent renderer.** If SS continues to read `video:` blocks during the transition window between step 5 and step 9, the catalog strip in step 6 will break SS. Mitigation: either keep the catalog's `video:` block in place until step 9 (push step 6 to after SS retirement), or backport SS to read from the JSON:API endpoint in step 5b. The first option is simpler if the cutover is close.

**R7. The interim AVC keeps the bug.** If the AVC site is still expected to produce real clip-review MRs before the NWC cutover, the immediate-stopgap (parse-locate-edit-validate fix in `applyVideoBlock()`) is still required. That work is in the order of 2–3 hours and is mutually exclusive with P64 only by labour-allocation — not technically. Recommend doing it only if the operator confirms AVC clip-review needs to remain functional pre-cutover.

## Decision needed

1. **Adopt P64 vs patch the regex?** Recommend adopt. Patching the regex leaves the structural mismatch in place and merely defers the next variant of this bug.
2. **Build the SS Moodle player activity, or let SS retire on the frozen catalog?** Recommend the latter if NWC cutover is on track for the same quarter; the former otherwise.
3. **Dual-attestation auto-apply vs pending-state-only?** Recommend pending-state-only at launch, with dual-attestation auto-apply added as an opt-in once the Clip Selection skill's matching rule is locked in `VIDEO_GUILD_v3.md`.
4. **Stopgap regex fix on AVC?** Recommend yes only if AVC clip-review needs to remain functional before NWC cutover. Otherwise skip and let the existing apply-without-MR fallback (JSON request files) accumulate harmlessly until decommissioning.

## Cross-references

- `sites/avc/.../docs/proposals/A28-clip-review.md` — original clip-review module proposal; this proposal supersedes A28's GitLab-MR-as-apply-target.
- `sites/nwc/.../docs/decisions/0017-media-guild-promotion.md` — ADR creating the review pool that auto-apply can lean on.
- `~/dir/courses_v3/VIDEO_GUILD_v3.md` — Media Guild's skill catalogue, including Clip Selection (the skill whose dual-attestation gates auto-apply).
- `~/central/CLIP-REVIEW-HANDOVER-2026-05-19.md` — current handover document; will need an update or replacement when P64 ships.
- `~/nwp/private/session-handover-2026-05-22-worker-A.md` — smoke-test that surfaced the bug (Worker-A finding F1).
- `MrGeneratorService.php:113–166, 168–186` — code that this proposal removes.
- `ReviewDecisionService.php:60` — single-line swap point (`mrGenerator->openMr` → `clipChoiceWriter->upsert`).
