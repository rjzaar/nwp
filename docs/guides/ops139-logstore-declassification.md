# Design: declassifying the Moodle native log (ops#139 / R1.4 / B1)

**Scope:** stop `logstore_standard_log` on ssc/ssd from naming the doctrine or practice a
member engaged with. `ver` role-vocab; no real prod domain; no secrets. **Status: DESIGN +
one safe additive patch (staged artifact). Nothing applied, nothing deployed.**

**Source of the requirement:** `~/central/gdpr/REMEDIATION-PLAN.md` R1.4 (launch blocker),
`~/central/gdpr/RETENTION-SCHEDULE.md` row 9, DPIA-v2 risk R4 (High, un-mitigated).

**Done when:** a fresh log dump for a test member contains no doctrine or practice title,
and R4 can be re-rated.

---

## 0. Correction to the premise — the leak is not where the issue assumes

ops#139 states the log records *"user X viewed [Confession/examen] at T"*. Read against the
code, that is **true in effect but not in mechanism**, and the difference decides the fix.

`mod_depthcontent`'s own view event is already clean. Verified at
`sites/ssc/dev/mod/depthcontent/classes/event/course_module_viewed.php:29-39`: it extends
`\core\event\course_module_viewed`, sets only `objecttable='depthcontent'`, `crud='r'`,
`edulevel=LEVEL_PARTICIPATING`, populates **no** `other[]`, and overrides no
`get_description()`. Its trigger at `sites/ssc/dev/mod/depthcontent/lib.php:146-153` passes
`objectid` (the instance id) and `context` — no title. `local_practice` has no
`classes/event/` directory at all.

So the member-view row itself carries an **opaque instance id**. The title reaches a reader
by three other routes:

| # | Route | Where | Severity |
|---|---|---|---|
| **L1** | `other['name']` literally holds the doctrine title | core `course_module_created` / `course_module_updated` | **The literal leak.** A raw table dump contains the title. |
| **L2** | The view row's `objectid` joins to `mdl_depthcontent.name`, which *is* the title | log report UI + any SQL join | The view row is pseudonymous but **trivially re-linkable** — one join. |
| **L3** | A pre-written draft would put a raw `title` into `other` | `sites/ssc/dev/local/feedback/submit.php:93` (commented out) | Latent; ships the leak the day it is uncommented. |

**The root cause under all three is one line.** The Moodle course-module *name* is set to the
doctrine title:

- `sites/ssc/dev/mod/depthcontent/cli/populate_courses.php:147` — `$title = $data['title'] ?? $pointid;`
- `sites/ssc/dev/mod/depthcontent/cli/populate_courses.php:188` — `$moduleinfo->name = $title;`
- `sites/ssc/dev/mod/depthcontent/cli/populate_courses.php:159` — the `--clear` in-place update path
- `sites/ssc/dev/mod/depthcontent/cli/populate_courses.php:196` — `$moduleinfo->cmidnumber = '';` ← **the canonical-id slot is free and unused**

`add_moduleinfo()` then fires `course_module_created` at `sites/ssc/dev/course/modlib.php:193`,
and core builds the payload at
`sites/ssc/dev/lib/classes/event/course_module_created.php:74-82`, line **80** being
`'name' => $cm->name`. Core **mandates** that field —
`course_module_created.php:126-128` throws `coding_exception` when it is unset — so it cannot
simply be dropped at the event level. The edit path repeats it:
`sites/ssc/dev/course/modlib.php:739` → `course_module_updated.php:123` (mandatory at 97-99).

The rows land in `logstore_standard_log.other` (TEXT) —
`sites/ssc/dev/admin/tool/log/store/standard/classes/log/store.php:126`.

Good precedent that core does not always embed the name: `course_module_deleted` passes only
`modulename` + `instanceid` (`sites/ssc/dev/course/lib.php:897-905`).

**Consequence for the fix.** "Log the opaque canonical id, never the title" cannot be done
inside the plugin's event class, because the plugin's event class is already opaque. It has to
be done where the *name* is chosen — and that is a member-facing display string. That is the
part an agent must not decide alone (§2b).

---

## 1. The canonical id already exists

The opaque id R1.4 asks for (`B5.03`) is a first-class column already:

| Table | Column | Declared at | Note |
|---|---|---|---|
| `depthcontent` | `pointid` CHAR(20) | `mod/depthcontent/db/install.xml:17-18` | `"Learning point ID e.g. A1.01"`, indexed at :28 |
| `depthcontent` | `name` CHAR(255) | `mod/depthcontent/db/install.xml:14` | **holds the doctrine title** |
| `depthcontent_mastery` | `pointid` CHAR(64) | `mod/depthcontent/db/install.xml:197-198` | `"Permanent canonical N4 node id (e.g. B5.03); course-agnostic"` |
| `local_practice_def` | `checkpoint_uid` CHAR(160) | `local/practice/db/install.xml:50-51` | canonical `course.pointid.key`, e.g. `B5.03.examen` |
| `local_practice_def` | `title` CHAR(255) | `local/practice/db/install.xml:60-61` | the human-readable label |

Nothing needs inventing. The work is to make the *log-visible* identifier be `pointid`
instead of `name`.

---

## 2. The four-part fix, mapped to code

### Part 1 — route the formation signal to the in-boundary store

**Largely already true, and worth recording as such.** The formation signal (mastery,
retrieval, confidence) is written to `depthcontent_mastery` / `depthcontent_retrieval_log` /
`depthcontent_sr`, which are in-boundary and declared in
`mod/depthcontent/classes/privacy/provider.php:80-83` (`INSTANCE_TABLES` /
`LEDGER_TABLES`). No `add_to_log`, no `set_legacy_logdata`, no custom logstore, and no
`db/events.php` observer exists in either plugin. The external functions
(`record_response`, `set_depth`, `submit_review`, `feedback`) trigger no events at all.

**Remaining work is preventive, not corrective:** a written rule that formation signals never
gain a logstore event, plus §2c below. The residual logstore exposure is core's
activity-view row, which Part 2 addresses.

### Part 2 — log the opaque canonical id, never the title

This is the part that actually declassifies, and it splits into three pieces of very
different risk.

**2a — give every course module a canonical anchor. SAFE, ADDITIVE, BUILT (staged).**
`cmidnumber` is currently set to `''` (`populate_courses.php:196`), so
`course_modules.idnumber` is a free slot. Setting it to `$pointid` costs nothing, changes no
display, and gives every log row a canonical id reachable by a join that does **not** pass
through the title. It also makes 2b mechanically checkable afterwards. This is the patch
staged in the artifact directory (§4).

**2b — stop the literal title entering `other['name']`. OPERATOR DECISION, NOT BUILT.**
Because core mandates `other['name']`, the only way to keep the title out of it is for the
course-module name not to *be* the title. Three options, honestly compared:

| Option | Change | Member-visible? | Cost | Verdict |
|---|---|---|---|---|
| **A** | `$moduleinfo->name = $pointid`; render the human title from `content_json` in the module's own view/renderer | **Yes** — course-page index and breadcrumbs show `B5.03` unless the format/renderer is taught to resolve it | Medium: touches course-page rendering and every place Moodle prints a cm name (search, completion report, gradebook) | Cleanest declassification; **highest UX risk**. Needs an operator call. |
| **B** | Keep `name = $title`, and drop `logstore_standard` for these contexts (`tool_log` per-context config / a filtered logstore) | No | Medium; loses *all* audit rows for those modules, including security-useful ones | Trades one compliance problem for an audit gap. Not recommended. |
| **C** | Keep `name = $title`, and **purge/rewrite** `other['name']` for `depthcontent` rows on a short cycle, plus the §2d retention floor | No | Low | Mitigation, not declassification: the title is in the table until the job runs. Acceptable **only** as an interim beside a 30-day retention. |

**Recommendation: A, staged behind an operator decision, with C as the interim from tonight.**
A is the only option that makes the DONE-WHEN criterion true by construction rather than by
scheduled cleanup. But it changes what members see on a course page, and the surfacing-firewall
architecture exists precisely so that member-facing presentation is deliberate — so the call
belongs to the operator, not to this design. 2a is a prerequisite for A either way and is safe
to land now.

**2c — fix the latent draft before it ships.** `sites/ssc/dev/local/feedback/submit.php:93`
carries a commented-out `'other' => ['type' => $type, 'title' => $title]` for a not-yet-created
`\local_feedback\event\feedback_submitted`. If uncommented as drafted it reintroduces the
literal leak in a new place. Change the draft to carry `pointid`/`checkpoint_uid`, not `title`.

**Secondary, low risk:** `sectionname` reaches `other` at
`sites/ssc/dev/course/format/classes/local/sectionactions.php:249-252`, but
`populate_courses.php:187` maps sections to *session numbers*, so no doctrine title is exposed
today. Flag it if sections are ever given titles.

### Part 3 — restrict `report/log:view`

Documented config change, **not applied** (see `artifact/report-log-view.md`). `report/log:view`
and `report/loglive:view` are granted by default to roles including Manager and Teacher.
Restrict to a covenant-bound site-admin role; remove from Teacher/Manager on ssc and ssd. This
is defence in depth — it narrows *who* can read the log, and does nothing about *what* is in
it, which is why R1.4 lists it third rather than first.

### Part 4 — erasure scope + retention

**Erasure.** Neither plugin's privacy provider touches logstore —
`mod/depthcontent/classes/privacy/provider.php:91-145` declares six
`add_database_table()` calls and **no** `add_subsystem_link()`;
`local/practice/classes/privacy/provider.php:67-96` likewise. logstore is covered by
`logstore_standard`'s own core provider, so a Privacy-API delete *does* reach it — meaning the
ops#81 channel already erases logstore rows for an erased member. What is missing is the
**assertion and the test**, not the mechanism. Add logstore to the ops#93/R2.2 zero-rows
assertions rather than writing new deletion code.

**Retention.** `RETENTION-SCHEDULE.md` row 9: **30 days interim, 90 after this lands.** Moodle
ships the cron purge — `Site administration → Plugins → Logging → Standard log`, setting
`loglifetime`. Operator-applied; recorded in `artifact/retention.md`.

---

## 3. Verifying it — the DONE-WHEN check

`artifact/verify_logstore_declassified.php` is a **read-only** Moodle CLI script that
implements the acceptance criterion directly: for a given test member it dumps every
`logstore_standard_log` row (all columns, `other` included), collects the known doctrine and
practice titles from `mdl_depthcontent.name` and `mdl_local_practice_def.title`, and fails if
any title string appears anywhere in the dump. It reports which column and which event name
leaked, so a failure names its own cause.

It is deliberately **title-driven, not pattern-driven**: it asserts against the actual
titles in the database rather than a regex for what a title might look like, so it cannot
pass by failing to recognise a leak.

It reads; it never writes, and it never deletes. Run it before and after any of §2 to
re-rate R4.

---

## 4. What is staged in the artifact, and what is not

`docs/reports/consolidation-arc-2026-07/ops139-logstore-artifact/`

| File | Status |
|---|---|
| `ops-139-canonical-id.patch` | **2a only** — `cmidnumber = $pointid`. Additive, no display change, no DB schema change. |
| `leakcheck.php` | Moodle-free leak-detection logic, shared by the checker and its test. |
| `verify_logstore_declassified.php` | Read-only Moodle CLI acceptance check (§3). |
| `canonical_id_test.php` | Standalone red-green test — `php canonical_id_test.php`, no Moodle. |

Parts 3 and 4 are console/settings actions rather than code, so they are written up as
Appendix A and Appendix B below rather than as files to apply.

### Applying the patch (operator)

```
cd <ss-moodle-plugins checkout>
git checkout -b ops-139-canonical-id
git apply --check docs/.../ops-139-canonical-id.patch   # must be clean first
git apply           docs/.../ops-139-canonical-id.patch
```

Then re-run the course population (`php mod/depthcontent/cli/populate_courses.php`) to
stamp `cmidnumber` on existing modules, and re-sync the ssd checkout. **Rollback** is
`git revert` plus a re-run; `cmidnumber` was empty before, so reverting restores the prior
state exactly.

### Running the acceptance check

```
cp leakcheck.php verify_logstore_declassified.php <moodle_root>/local/ops139/
php <moodle_root>/local/ops139/verify_logstore_declassified.php --username=<test member>
```

Exit 0 = clean · 1 = leak found (it names the event and column) · 2 = could not verify.
It never returns 0 because it failed to look.

**Not built, deliberately:** option A (§2b) — it is a member-facing display change and an
operator decision; the §2c feedback-draft edit — it lives in a file whose event class does not
yet exist, so it belongs with that build; and the Part 3/4 config, which are console/settings
actions, not code.

**Why an artifact and not a branch.** The canonical plugin repo is
`sites/ssc/.plugin-src/ss-moodle-plugins` (a real git checkout with a remote; the live tree
`sites/ssc/dev` is a byte-identical copy, so a patch maps 1:1). This agent is confined to its
own worktree and is refused git operations against that shared checkout, so the change is
staged as a reviewable patch under the consolidation-arc artifact convention. **Note the patch
must land in `sites/ssd/.plugin-src/ss-moodle-plugins` too**, or be re-synced — ssd carries the
same `mod/depthcontent` and `local/practice`.

---

## 5. Boundary

Nothing here touches prod. The patch is staged, not applied; the config changes are written
down, not made; the verifier is read-only. Applying any of it on a live tier goes through the
ordinary operator path — and the `ver` Solo-touch gate for real prod — per CLAUDE.md
AI-never-prod.

---

## Appendix A — Part 3: restrict `report/log:view` (DOCUMENTED, NOT APPLIED)

Defence in depth. This narrows **who** can read the native log; it does nothing about **what**
is in it, which is why R1.4 lists it third. Applying it does not close ops#139.

| Capability | Default holders | Target |
|---|---|---|
| `report/log:view` | Manager, Teacher (archetype) | covenant-bound site-admin role only |
| `report/loglive:view` | Manager, Teacher | covenant-bound site-admin role only |
| `report/outline:view`, `report/participation:view` | Manager, Teacher | review — same activity-level exposure |

1. **Record the current state first** — *Site administration → Users → Permissions →
   Capability overview*, per capability, "any role". Moodle does not version role
   definitions, so this record is the only rollback path. Do not assume archetype defaults
   are what this site actually has.
2. *Define roles* → for **Teacher**, **Non-editing teacher**, **Manager**: set both
   capabilities to **Not set** (or Prevent where an inherited grant exists).
3. Grant them on a role — e.g. `covenantadmin` — held only by people under the covenant.
4. Re-run the capability overview; confirm the only holders are intended.

**Caveat worth stating plainly:** site administrators bypass capability checks entirely. This
control governs the teacher/manager tier only. Admin exposure is addressed by the covenant and
by §2 making the contents non-revealing in the first place.

## Appendix B — Part 4: retention + erasure scope (OPERATOR)

**Retention.** `RETENTION-SCHEDULE.md` row 9: **30 days interim, 90 days once §2 lands.**
*Site administration → Plugins → Logging → Standard log* → set `loglifetime` to 30 days, and
confirm the `\logstore_standard\task\cleanup_task` scheduled task is enabled and running —
a retention period nobody purges is worse than none, because it documents an intention you
are provably not meeting (`RETENTION-SCHEDULE.md` closing note).

Apply on **ssc and ssd both**. Raise to 90 only after the §3 acceptance check reports CLEAN.

**Erasure scope.** No new deletion code is needed. `logstore_standard` ships its own privacy
provider, so the Privacy-API delete the ops#81 channel already triggers
(`local_nwc_erase` → `tool_dataprivacy`) reaches logstore rows. What is missing is the
**assertion**: add `logstore_standard_log` to the ops#93 / R2.2 end-to-end "zero rows after
erase" test, asserting zero rows for both `userid` and `relateduserid`. FK-free tables with
no cascade are exactly where erasure quietly fails, and logstore is one.
