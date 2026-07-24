# local/browse — preservation & course-set analysis (2026-07-24)

## What was preserved
- `original-compact-from-ss/` — copy of `sites/ss/dev/local/browse`, **v0.2.0 (2026072100, 2026-07-21)**.
- `current-elaborated-from-ssc/` — copy of `sites/ssc/dev/local/browse`, **v0.1.0 (2026051700, 2026-05-17)**.

Both were **untracked** in their dev trees (no git history) — preservation was time-sensitive.

## Which is which (corrects the initial read)
`version.php` + the `index.php` diff show the **ss/dev v0.2.0 is the NEWER, more COMPACT** one, not older:
- Rail-palette colour-coding per intent tile; tighter spacing (tile margin 16px vs 28px, padding 12px vs
  18px, card min 230px vs 260px, gap 8px vs 12px) → reads tighter + coloured, not flat green.
- **Dropped the v1/v3 catalog toggle** (`cat` param) with the in-code note: *"v1-archive catalog toggle
  removed 2026-07-21: v3 already contains every v1 course, polished + 6 more … archive site ss2 retired."*
- Has `locallib.php`/`settings.php`? No — the richer file set is on the **ssc v0.1.0** side.

The **live** `ss.nwpcode.org/local/browse/` serves from `/var/www/ssc` (per ops#126) = the **older, looser
v0.1.0 that still shows the v1/v3 toggle**. `ss2.nwpcode.org` now 301-redirects to `ss`.

## The real operator ask, made precise
1. **Compaction:** bring the live (ssc v0.1.0) page to the compact v0.2.0 layout. → Plane 4 `local/browse`
   compaction task. Reference = `original-compact-from-ss/`.
2. **"Compare the original sets of courses":** VERIFY the v0.2.0 claim that **v3 ⊇ v1** (dropping the v1
   archive loses no course). Data-integrity check before the compact (v1-less) page goes live.

## Dependency / ordering flag
The authoritative **v1 course set** lives in the **orphan `/var/www/ss` DB**, which **ops#126 retires**.
→ **Snapshot `/var/www/ss` (DB + course list) BEFORE executing #126.** The v3 set = `/var/www/ssc`.
Compare shortname sets: assert `v1_shortnames ⊆ v3_shortnames`; list the "+6 more"; flag any v1-only.

## Course-set verification (2026-07-24) — v3 ⊇ v1 CONFIRMED
Extracted `mdl_course` shortnames from both Phase-0 backups (read-only):
- v1 = `ss-remote-20260724T180042` (orphan /var/www/ss): **56 courses**
- v3 = `ssc-remote-20260724T180130` (live /var/www/ssc): **56 courses**
- v1∖v3 = {`Saint School`}, v3∖v1 = {`ss`} — **both are the Moodle site course (id=1, cat=0)**, i.e. the
  front-page record, NOT real content. All 55 real courses (A1–A8, …) are identical.

**Conclusion:** every real v1 course exists in v3 → the compact browse v0.2.0 (which drops the v1 archive
toggle) loses NO course content; safe to promote course-wise. Independently proves **ops#126 is safe** — the
orphan /var/www/ss holds no unique courses.
**Caveat:** the *original* v1 archive was ss2 (already retired; ss2→ss redirect), so its exact historical set
can't be re-verified; /var/www/ss is a stale mirror of ssc. Parser: scratchpad/course_shortnames.py.
