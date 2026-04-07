# SS Faith Formation App — Phased Implementation Plan

**Date:** 2026-03-09
**Site:** ss.nwpcode.org (Moodle 4.4 — Catholic faith formation)
**Stack:** Flutter + Drift (SQLite) + Riverpod
**Targets:** Android APK, Linux, Windows, macOS, PWA fallback
**Design principle:** Build for Scenario 4 (fully offline/USB) — Scenarios 1-3 come free

---

## Phase 1: Content Export & Data Model

**Goal:** Extract all course content from Moodle into a portable format and define the app's database schema.

### 1.1 Export course content from Moodle

- Parse existing `.mbz` backup files (rosary-complete-v3.mbz, ignatian_examen_backup_COMPLETE.mbz)
- Extract: section titles, section content (HTML), ordering, metadata
- Write a Python script (`mt/src/moodle_export.py` or standalone) that reads `.mbz` (ZIP containing XML) and outputs clean JSON

### 1.2 Export quiz content from Moodle

- Extract from `.mbz` or via Moodle Web Services API (`mod_quiz_get_quizzes_by_courses`)
- For each quiz: questions, answer options, correct answers, scoring rules, feedback text
- Question types to support: multiple choice, true/false, matching, short answer
- Export pass threshold (80% for Rosary quizzes)

### 1.3 Define Drift database schema

```
courses: id, title, description, sort_order
sections: id, course_id, title, content_html, sort_order
quizzes: id, course_id, section_id, title, pass_percentage, max_attempts
questions: id, quiz_id, type, question_text, sort_order, points
answers: id, question_id, answer_text, is_correct, feedback, sort_order
user_progress: id, course_id, last_section_id, completed, completed_at
quiz_attempts: id, quiz_id, attempt_number, score, passed, started_at, completed_at
quiz_responses: id, attempt_id, question_id, selected_answer_id, is_correct
```

### 1.4 Build seed database

- Write a Dart CLI tool that reads the exported JSON and populates `courses.db`
- This `.db` file becomes the bundled asset in the app

**Deliverable:** `courses.db` SQLite file containing all Rosary and Ignatian Examen content, ready to bundle.
**Effort:** 1-2 weeks

---

## Phase 2: Flutter Project Setup

**Goal:** Scaffold the Flutter project with all dependencies and build targets configured.

### 2.1 Create Flutter project

```bash
flutter create --org org.nwpcode --project-name faith_formation faith_formation
```

### 2.2 Add dependencies

```yaml
# pubspec.yaml
dependencies:
  flutter_riverpod: ^2.x
  drift: ^2.x
  sqlite3_flutter_libs: ^0.5.x
  path_provider: ^2.x
  flutter_html: ^3.x        # Render course content HTML
  google_fonts: ^6.x         # Typography
  shared_preferences: ^2.x   # Simple settings storage

dev_dependencies:
  drift_dev: ^2.x
  build_runner: ^2.x
```

### 2.3 Configure build targets

- Android: set minSdkVersion 21 (Android 5.0+, covers ~99% of devices)
- Linux: configure for x86_64
- Windows: configure MSIX or raw executable
- macOS: configure for universal binary
- Set app icon, splash screen, app name

### 2.4 Set up project structure

```
lib/
  main.dart
  app.dart
  database/
    database.dart            # Drift database definition
    tables.dart              # Table definitions
    daos/                    # Data access objects
  models/                   # Freezed/data classes
  providers/                # Riverpod providers
  screens/                  # UI screens
  widgets/                  # Reusable widgets
  theme/                    # Colours, typography, spacing
assets/
  courses.db                # Bundled seed database
  images/
```

### 2.5 Implement database initialisation

- On first launch: copy bundled `courses.db` from assets to app storage
- Drift opens from the copied location (so user progress can be written)
- Add version check for future content updates

**Deliverable:** Flutter project that builds and runs on all targets with empty screens and a working database connection.
**Effort:** 1 week

---

## Phase 3: Course Viewer

**Goal:** Users can browse courses, read sections, and navigate with tabs (matching the existing Moodle tabbed format).

### 3.1 Home screen

- List of available courses (Rosary, Ignatian Examen)
- Course card showing: title, description, progress bar, completion status
- Riverpod provider watches `user_progress` table for reactive updates

### 3.2 Course screen with tabbed sections

- Replicate the custom tabbed format from Moodle (`sites/ss/course/format/tabbed/`)
- Tab bar across top (desktop) or swipeable tabs (mobile)
- Each tab = one course section
- Section content rendered via `flutter_html` (preserves formatting from Moodle)
- Track last-viewed section in `user_progress`

### 3.3 Section content rendering

- HTML content from Moodle rendered natively
- Handle: headings, paragraphs, lists, bold/italic, images, blockquotes
- Strip Moodle-specific markup that doesn't apply (activity links, etc.)
- Style to match app theme, not Moodle theme

### 3.4 Navigation

- Previous / Next section buttons at bottom of each section
- Section completion checkmarks on tabs
- Course overview showing which sections visited

**Deliverable:** Users can open a course, swipe through tabbed sections, and read all content.
**Effort:** 2 weeks

---

## Phase 4: Quiz Engine

**Goal:** Users can take quizzes, receive scores, and track pass/fail against the 80% threshold.

### 4.1 Quiz launcher

- "Take Quiz" button appears in relevant course sections
- Shows: quiz title, number of questions, pass mark, previous best score, attempts used
- Confirm dialog before starting (to avoid accidental attempts)

### 4.2 Question renderer

- **Multiple choice:** Radio buttons for single answer, checkboxes for multi-answer
- **True/False:** Two large buttons
- **Matching:** Drag-and-drop or dropdown selectors pairing items
- **Short answer:** Text input with exact-match or contains-match validation
- One question per screen with Previous/Next navigation
- Question progress indicator (e.g., "Question 3 of 12")

### 4.3 Answer validation & scoring

- On submit: compare responses against correct answers in database
- Calculate percentage score
- Per-question feedback shown after submission (from `answers.feedback` field)
- Overall result: PASS (green) or FAIL (red) against threshold
- Store attempt in `quiz_attempts`, individual responses in `quiz_responses`

### 4.4 Quiz review mode

- After submission: review all questions with correct/incorrect highlighting
- Green = correct, Red = incorrect, show correct answer for wrong responses
- Option to retake quiz (new attempt)

### 4.5 Scoring dashboard

- Per-quiz: best score, all attempts with dates, pass/fail history
- Per-course: quizzes completed / total, overall readiness

**Deliverable:** Full quiz-taking experience with grading, feedback, and attempt history.
**Effort:** 3 weeks

---

## Phase 5: Progress Tracking & Completion

**Goal:** Track course completion across sections and quizzes, with a dashboard showing overall progress.

### 5.1 Section completion tracking

- Mark section as "visited" when user scrolls to bottom or spends >30 seconds
- Visual indicator on tab (checkmark or filled dot)
- Stored in `user_progress` table

### 5.2 Course completion logic

- Course complete when: all sections visited AND all quizzes passed at threshold
- Rosary: 3 quizzes at 80% + all sections viewed
- Ignatian Examen: all sections viewed (no quizzes, or reflection-based)
- Completion timestamp recorded

### 5.3 Dashboard / home screen updates

- Progress ring on each course card (e.g., "75% complete")
- Breakdown: "4/5 sections read, 2/3 quizzes passed"
- Celebration state when course completed (simple animation or icon change)

### 5.4 Progress export (for Scenario 4 USB return)

- "Export Progress" button in settings
- Writes a small JSON file to device storage or USB
- Contains: user name (optional), course completions, quiz scores, dates
- Can be carried back on USB drive and imported into Moodle by an administrator

**Deliverable:** Complete progress tracking with visual dashboard and optional export.
**Effort:** 1-2 weeks

---

## Phase 6: Responsive Layout & Theming

**Goal:** App looks good and works well on phones, tablets, and desktop screens.

### 6.1 Responsive breakpoints

- **Phone** (<600dp): Single column, bottom navigation, swipe tabs
- **Tablet** (600-1024dp): Side navigation rail, wider content area
- **Desktop** (>1024dp): Persistent side navigation, maximised content, larger fonts

### 6.2 Theme

- Colours: Catholic/liturgical palette (deep blue, gold, cream, burgundy)
- Typography: Serif for content (readability), sans-serif for UI
- Dark mode support (important for reading in low light)
- Consistent with faith formation context — dignified, not flashy

### 6.3 Accessibility

- Minimum touch targets 48dp
- Text scaling support (respect system font size)
- Screen reader labels on all interactive elements
- High contrast mode

### 6.4 Platform adaptations

- Android: Material Design 3 conventions
- Desktop: Menu bar, keyboard shortcuts (arrow keys for section nav, Enter for quiz submit)
- Window resizing handles gracefully on desktop

**Deliverable:** Polished, responsive UI across all form factors.
**Effort:** 1-2 weeks

---

## Phase 7: Build, Package & Test

**Goal:** Produce distributable binaries for all targets, test on real devices.

### 7.1 Android APK build

```bash
flutter build apk --release
```
- Test sideloading on 2-3 real Android devices (different OS versions)
- Test on a cheap/old device (e.g., Android 8 with 2GB RAM)
- Verify database loads, quizzes work, scores persist across app restarts

### 7.2 Desktop builds

```bash
flutter build linux --release
flutter build windows --release
flutter build macos --release
```
- Test on Ubuntu 22.04+, Windows 10+, macOS 12+
- Verify window resizing, keyboard navigation, file export

### 7.3 PWA fallback build

```bash
flutter build web --release
```
- Test in Chrome, Firefox, Safari (mobile and desktop)
- Verify offline capability via Service Worker
- Test opening from USB drive (file:// protocol — may need a local HTTP server wrapper)
- If file:// doesn't work: include a tiny Python/Node HTTP server script on the USB

### 7.4 Integration testing

- Write Flutter integration tests for critical paths:
  - Open course → read section → take quiz → submit → view score
  - Course completion flow
  - App restart preserves progress
  - Database migration (for future content updates)

### 7.5 USB package assembly

- Assemble the distribution folder structure:
```
USB_DRIVE/
  README.txt
  android/faith-formation.apk
  desktop/
    linux/faith-formation
    windows/faith-formation.exe
    macos/faith-formation.dmg
  browser/
    index.html
    ...
  data/
    courses.db
```
- Test the complete USB flow: plug in, install, use, export progress

**Deliverable:** Release-ready binaries for Android, Linux, Windows, macOS, and web.
**Effort:** 2 weeks

---

## Phase 8: Optional — Server Sync (Enables Scenarios 1-2)

**Goal:** Add optional connectivity to ss.nwpcode.org for users who have internet access. This phase is not required for Scenario 4.

### 8.1 Moodle API client

- Implement Moodle Web Services client in Dart
- Authentication: token-based (user enters site URL + credentials)
- Key endpoints:
  - `core_webservice_get_site_info` — verify connection
  - `core_course_get_contents` — sync course structure
  - `mod_quiz_get_attempt_review` — sync quiz attempts
  - `core_completion_update_activity_completion` — push completion status

### 8.2 Content sync

- Pull latest course content from Moodle → update local Drift database
- Detect content changes (compare checksums or modified timestamps)
- Merge without losing local progress

### 8.3 Progress upload

- Push local quiz attempts and completion status to Moodle
- Queue uploads when offline, send when connectivity returns
- Conflict resolution: server has authority on grades, local has authority on attempts

### 8.4 Settings screen

- "Connect to Moodle" toggle
- Site URL, username/token fields
- Sync status indicator
- Last sync timestamp
- Manual "Sync Now" button

**Deliverable:** App works standalone (Scenario 3-4) but can optionally connect to Moodle for sync (Scenario 1-2).
**Effort:** 2-3 weeks

---

## Phase 9: Optional — Additional Content

**Goal:** Add CathNet and other content modules to the same app shell.

### 9.1 CathNet integration

- Bundle `cathnet.db` (25MB) as a second database
- New tab/module: "Catechism"
- Browse paragraphs, search by keyword, view concept map
- Cytoscape.js concept map via Flutter WebView or native graph widget
- Fully offline — all data in SQLite

### 9.2 Content pack system

- Define a "content pack" format: ZIP containing a `.db` file + metadata JSON
- Users can load new content packs from USB or download
- App detects and imports new packs into the content library
- Enables future courses without rebuilding the app

### 9.3 Multi-course expansion

- Structure supports unlimited courses in the same schema
- New courses added by updating `courses.db` or loading a content pack
- No code changes needed — quiz engine and course viewer are generic

**Deliverable:** Extensible content platform that can grow beyond the initial two courses.
**Effort:** 2-4 weeks

---

## Summary

| Phase | Description | Effort | Cumulative |
|-------|-------------|--------|------------|
| **1** | Content export & data model | 1-2 weeks | 1-2 weeks |
| **2** | Flutter project setup | 1 week | 2-3 weeks |
| **3** | Course viewer with tabs | 2 weeks | 4-5 weeks |
| **4** | Quiz engine | 3 weeks | 7-8 weeks |
| **5** | Progress tracking & completion | 1-2 weeks | 8-10 weeks |
| **6** | Responsive layout & theming | 1-2 weeks | 9-12 weeks |
| **7** | Build, package & test | 2 weeks | 11-14 weeks |
| | **Scenario 4 complete** | **11-14 weeks** | |
| **8** | Optional: Moodle server sync | 2-3 weeks | 13-17 weeks |
| **9** | Optional: CathNet + content packs | 2-4 weeks | 15-21 weeks |

**Core app (Phases 1-7):** 11-14 weeks — fully offline, USB-distributable
**Full app (Phases 1-9):** 15-21 weeks — offline + online sync + extensible content

---

## Prerequisites

- Flutter SDK installed (stable channel)
- Android SDK for APK builds
- Access to ss.nwpcode.org Moodle (for content export)
- Moodle `.mbz` backup files (already in `sites/ss/`)
- Test devices: 1 Android phone, 1 desktop (Linux or Windows)

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| `.mbz` export doesn't contain quiz answers | Fall back to Moodle Web Services API to extract question banks |
| Flutter web (PWA) doesn't work from file:// | Include a 10-line Python HTTP server script on the USB |
| Old Android devices too slow | Set minimum SDK to 21, test on a budget device early (Phase 2) |
| Content updates needed post-distribution | Content pack system (Phase 9) or simple DB file replacement |
| Quiz types not covered | Start with multiple choice + true/false (covers ~90% of content), add others iteratively |
