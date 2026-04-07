# Mobile App Analysis: ss.nwpcode.org & avc.nwpcode.org

**Date:** 2026-03-09
**Status:** Analysis / Planning
**Author:** Claude Code (deep research across NWP codebase)

---

## What Each Site Does (Summary)

| Site | Platform | Purpose | Key Data |
|------|----------|---------|----------|
| **ss.nwpcode.org** | Moodle 4.4 | Catholic faith formation LMS — Rosary course, Ignatian Examen, quizzes | Courses, quizzes, question banks, completion tracking, grades |
| **avc.nwpcode.org** | Drupal 10 + Open Social | Collaborative workflow platform — guilds, skills, task management, mentorship | Workflows, tasks, groups, guilds, skills, notifications, assets |
| **ccc.nwpcode.org** | Drupal 10 | Catechism concept map & knowledge graph (CathNet) | 2,863 paragraphs, 1,514 concepts, 5,305 relationships |
| **mt.nwpcode.org** | Drupal 10 | Mass times finder — parish map & schedules | ~50 parishes, mass times, GPS coordinates |

---

## The Four Scenarios

### Scenario 1: App as a Frontend Shell for the Websites

The app is essentially a branded browser / API consumer that wraps the existing sites.

**What this means:**
- App authenticates against existing backends (Moodle Web Services API, Drupal JSON:API/GraphQL)
- All data lives on the server; app just renders it natively
- Push notifications replace email alerts
- No offline capability beyond basic caching

**For ss.nwpcode.org (Moodle):**
- Moodle already has a **complete mobile API** (`tool_mobile` plugin is installed)
- The official **Moodle App** (open source, Ionic/Angular) already does exactly this
- You could either: (a) use Moodle App as-is with your site URL, (b) fork Moodle App and rebrand it, or (c) build a custom shell
- Moodle's Web Services API exposes: courses, quizzes, grades, completion, forums, messaging

**For avc.nwpcode.org (Drupal/AVC):**
- JSON:API module is available (needs enabling)
- GraphQL module (`drupal/graphql ^4.9.0`) is in composer.json
- Simple OAuth for JWT tokens is available
- Custom workflow/task/guild APIs would need thin wrappers
- Existing docs (`hybrid-mobile-approach.md`) already plan this at 14-19 weeks

| Aspect | Best Choice | Why |
|--------|-------------|-----|
| **Language** | **Dart** (Flutter) or **TypeScript** (React Native) | Both handle API consumption well; Flutter has better single-codebase parity |
| **Framework** | **Flutter** (preferred) | Existing docs recommend it; strong HTTP/JSON support, single codebase for iOS+Android |
| **Alternative** | **React Native** | Larger ecosystem, easier to find developers, JavaScript familiarity |
| **Python option** | **Flet** | 100% Python, compiles to Flutter; good if you want to stay in the Python ecosystem |
| **For Moodle specifically** | **Ionic/Angular** (fork Moodle App) | Zero API work — Moodle App is already built and open source |
| **Platforms** | **Both iOS + Android** | Flutter/RN give you both from one codebase |
| **Effort** | 3-5 months | Per existing hybrid-implementation-plan.md |
| **Server changes** | Minimal | Enable JSON:API, configure OAuth2, add CORS headers |

**Pros:** Fastest to ship, lowest risk, leverages existing infrastructure, all data stays centralized
**Cons:** Requires internet, no offline, dependent on server uptime

---

### Scenario 2: Standalone App That Pulls Data from the Websites

The app has its own local database and UI logic but syncs data from the servers. Works offline with stale data, syncs when connected.

**What this means:**
- App has a local SQLite/Hive/Isar database
- Periodic sync pulls courses, quiz content, tasks, workflows from servers
- User can browse content offline, but submissions queue until online
- Conflict resolution needed for two-way sync (task status changes, quiz attempts)

**For ss.nwpcode.org (Moodle):**
- Sync course structure, quiz questions, and content pages locally
- Quiz attempts stored locally, submitted when online
- Completion tracking synced bidirectionally
- Moodle Web Services provide: `core_course_get_contents`, `mod_quiz_get_quizzes_by_courses`, `mod_quiz_get_attempt_data`

**For avc.nwpcode.org (AVC):**
- Sync workflow tasks, group memberships, guild progress locally
- Task claiming/completion queued offline
- Notification digest stored locally
- More complex: workflow state machines need local replication

| Aspect | Best Choice | Why |
|--------|-------------|-----|
| **Language** | **Dart** (Flutter) | Strong local DB support (Isar, Hive, Drift/SQLite), background sync APIs |
| **Framework** | **Flutter + Drift (SQLite)** | Drift gives typed SQLite queries; Flutter's isolates handle background sync |
| **Alternative** | **Kotlin Multiplatform (KMP)** | Native performance, shared business logic, SQLDelight for local DB |
| **Python option** | **Flet + SQLite** | Works but weaker background sync; Python not ideal for mobile background tasks |
| **React Native option** | **RN + WatermelonDB** | WatermelonDB handles offline-first sync well; large community |
| **Platforms** | **Both iOS + Android** | Flutter/KMP give you both |
| **Effort** | 5-8 months | Sync logic and conflict resolution add significant complexity |
| **Server changes** | Moderate | Need sync endpoints, delta/changelog APIs, conflict resolution strategy |

**Key technical decisions:**
- **Sync strategy:** Timestamp-based (last_modified) vs event-sourcing (changelog)
- **Conflict resolution:** Server-wins (simplest), client-wins, or manual merge
- **Background sync:** WorkManager (Android), BGTaskScheduler (iOS) — Flutter has plugins for both
- **Data freshness:** Pull on app open + periodic background sync (e.g., every 4 hours)

**Pros:** Works offline with cached data, responsive UI, reduced server load
**Cons:** Complex sync logic, conflict resolution, data consistency challenges, still needs server

---

### Scenario 3: Completely Standalone App (No Server Dependency)

The app contains all functionality and data within itself. No web server needed at all.

**What this means:**
- All course content, quiz engines, workflow logic built into the app
- Database is local (SQLite)
- No user accounts (or local-only accounts)
- Updates require app store releases or in-app content packages
- For AVC: workflow engine reimplemented in app language
- For Moodle: quiz engine, grading, completion all reimplemented

**For ss.nwpcode.org (Moodle LMS replacement):**
- Reimplement: course viewer, quiz engine (multiple choice, matching, true/false, short answer), grading, completion tracking
- Bundle course content as JSON/SQLite within the app
- Content updates via downloadable "course packs"
- No forums, no messaging (or local-only)

**For avc.nwpcode.org (AVC workflow replacement):**
- Reimplement: workflow state machine, task assignment, guild scoring, skill levels, notification queue
- This is a **massive** undertaking — AVC has 12 custom modules, 14+ entities, 26+ routes
- Single-user mode only (collaborative workflows don't work without a server)
- Could work as a personal task/skill tracker

| Aspect | Best Choice | Why |
|--------|-------------|-----|
| **Language (ss/LMS)** | **Dart** (Flutter) or **Kotlin** (native) | Quiz engine needs good UI; Flutter for cross-platform, Kotlin for Android-first |
| **Language (avc/workflow)** | **Kotlin Multiplatform** or **Swift+Kotlin** | Complex business logic benefits from strong typing and native performance |
| **Framework (ss)** | **Flutter + Drift** | Quiz UI components, local SQLite for questions/grades, cross-platform |
| **Framework (avc)** | **Flutter + Riverpod + Drift** | State management (Riverpod) for workflow engine, Drift for local DB |
| **Python option** | **Kivy** or **BeeWare** | Kivy for custom UI, BeeWare for native widgets; both weaker than Flutter/native |
| **Lightweight option** | **PWA (Progressive Web App)** | HTML/CSS/JS, works offline via Service Worker, no app store needed |
| **Platforms** | **Android first, then iOS** | Reduces initial scope; Flutter gives both but testing doubles |
| **Effort (ss only)** | 3-4 months | Quiz engine is well-defined; course content is finite |
| **Effort (avc)** | 9-12+ months | Workflow engine alone is months of work |
| **Effort (both)** | 12-18 months | Massive scope |

**Content packaging for ss:**
```
app_bundle/
  courses/
    rosary-101/
      course.json          # Structure, sections, metadata
      quizzes/
        prayers.json       # Questions, answers, scoring rules
        structure.json
        mysteries.json
      content/
        section-1.html     # Rendered content pages
        section-2.html
    ignatian-examen/
      ...
  media/
    images/
    audio/                 # If any
```

**Pros:** Zero server dependency, works anywhere, full control, no ongoing hosting costs
**Cons:** No collaboration (AVC loses core value), content updates require app releases, massive reimplementation

---

### Scenario 4: USB/Backup Drive Distribution — Fully Offline, Air-Gapped

The app is distributed on physical media and runs without any internet connection ever. This is the "missionary in the bush" scenario.

**What this means:**
- App + all content delivered on USB drive / SD card / external storage
- No app store, no internet, no server
- Must run on whatever device the user has
- Content updates via new USB drives
- For ss: complete catechesis course with quizzes, self-grading
- Potentially runs on old/cheap Android devices

**This changes the technology calculus significantly.** App store deployment is impossible, so sideloading (Android APK) or desktop apps become primary.

| Aspect | Best Choice | Why |
|--------|-------------|-----|
| **Primary target** | **Android APK (sideloaded)** | Most common device globally, supports APK sideloading, cheap devices available |
| **Language** | **Kotlin** (Android native) or **Dart** (Flutter) | Kotlin for smallest APK size and best low-device performance; Flutter for cross-platform |
| **Framework** | **Flutter** (cross-platform) or **Jetpack Compose** (Android-only) | Flutter if you ever want iOS; Jetpack Compose for leanest Android-only build |
| **Desktop fallback** | **Flutter Desktop** or **Electron** or **Python (Flet/Tkinter)** | For users with laptops but no smartphones |
| **Ultra-lightweight** | **Static HTML + JavaScript (PWA on USB)** | Opens in any browser, no installation needed, runs on anything |
| **Database** | **SQLite (bundled)** | Pre-populated database file on the USB; no setup needed |
| **Content format** | **SQLite + HTML fragments + images** | Single .db file contains everything; HTML for rich content rendering |
| **Platforms** | **Android APK + Desktop (Windows/Linux) + Browser fallback** | Cover maximum device types |
| **Effort** | 2-4 months (ss content only) | Scope is well-defined; no network code needed |

**Distribution architecture:**
```
USB_DRIVE/
  README.txt                    # Installation instructions (multilingual)
  android/
    faith-formation.apk         # Sideloadable Android app (~20-50MB)
    install-instructions.pdf
  desktop/
    windows/
      faith-formation.exe       # Flutter desktop or Electron
    linux/
      faith-formation.AppImage
    macos/
      faith-formation.dmg
  browser/
    index.html                  # PWA that works from USB in any browser
    sw.js                       # Service worker for offline
    app/                        # All assets
  data/
    courses.db                  # SQLite database with all content
    media/                      # Images, audio if any
  updates/
    README.txt                  # "Copy new courses.db to replace"
```

**The browser/PWA fallback is critical** — it means even if someone can't install an APK or run a desktop app, they can open `index.html` in Chrome/Firefox on any device and get the full experience. This is the universal fallback.

**For ss.nwpcode.org content specifically:**
- Rosary course: ~5 sections, 3 quizzes, 80% pass threshold
- Ignatian Examen: meditation guide with reflection prompts
- Total content: probably < 5MB of text + images
- Quiz engine: multiple choice, matching, true/false — straightforward to implement
- Grading: local SQLite tracks attempts, scores, completion

**CathNet (ccc.nwpcode.org) is a natural fit for this scenario:**
- cathnet.db is already 25.1MB SQLite — ready to bundle
- 2,863 paragraphs, 1,514 concepts, 5,305 relationships
- Cytoscape.js visualization works in browser
- NLP models (all-MiniLM-L6-v2) are ~80MB — could bundle for semantic search
- Total offline package: ~120MB (with embeddings) or ~30MB (keyword search only)

**Pros:** Works literally anywhere, no internet ever needed, physical distribution for remote areas, total privacy
**Cons:** No updates without new USB, no collaboration, no analytics, sideloading requires user education

---

## Master Comparison Matrix

| Dimension | Scenario 1: Web Shell | Scenario 2: Sync + Pull | Scenario 3: Standalone | Scenario 4: USB/Offline |
|-----------|----------------------|------------------------|----------------------|------------------------|
| **Internet required** | Always | Sometimes | Never | Never |
| **Data location** | Server | Server + local cache | Local only | Local only (USB) |
| **Collaboration** | Full | Full (when online) | None | None |
| **Content updates** | Instant | On sync | App release | New USB drive |
| **Best language** | Dart/TypeScript | Dart | Dart/Kotlin | Dart/Kotlin/HTML+JS |
| **Best framework** | Flutter / React Native | Flutter + Drift | Flutter + Drift | Flutter + PWA fallback |
| **iOS support** | Yes (same codebase) | Yes (same codebase) | Yes (same codebase) | No (can't sideload) |
| **Android support** | Yes | Yes | Yes | Yes (APK sideload) |
| **Desktop support** | N/A (use website) | Optional | Optional | Yes (critical) |
| **Effort (ss only)** | 1-2 months | 3-4 months | 3-4 months | 2-4 months |
| **Effort (avc only)** | 3-5 months | 5-8 months | 9-12+ months | N/A (not feasible) |
| **Effort (both)** | 4-6 months | 6-10 months | 12-18 months | N/A |
| **Server changes** | Enable APIs, OAuth | APIs + sync endpoints | None | None |
| **Ongoing cost** | Server hosting | Server hosting | $0 | $0 + USB media |
| **App store** | Yes | Yes | Yes | No (sideload) |
| **Moodle shortcut** | Fork Moodle App | Partial (sync APIs) | None | None |

---

## Language & Framework Deep Comparison

| Framework | Language | iOS | Android | Desktop | Web | Offline DB | Maturity | Learning Curve | APK Size |
|-----------|----------|-----|---------|---------|-----|-----------|----------|---------------|----------|
| **Flutter** | Dart | Yes | Yes | Yes | Yes | Drift/Hive/Isar | Very High | Medium | ~15MB |
| **React Native** | TypeScript | Yes | Yes | No* | No* | WatermelonDB/SQLite | Very High | Medium | ~20MB |
| **Kotlin Multiplatform** | Kotlin | Yes | Yes | Yes | No | SQLDelight | Medium | High | ~8MB |
| **Flet** | Python | Yes | Yes | Yes | Yes | SQLite (raw) | Low-Medium | Low | ~30MB |
| **Kivy** | Python | Yes | Yes | Yes | No | SQLite | Medium | Medium | ~25MB |
| **BeeWare** | Python | Yes | Yes | Yes | No | SQLite | Low | Medium | ~15MB |
| **Ionic/Capacitor** | TypeScript | Yes | Yes | No | Yes | SQLite/IndexedDB | High | Low | ~12MB |
| **Moodle App** | TypeScript | Yes | Yes | No | Yes | SQLite/IndexedDB | Very High | High** | ~40MB |
| **PWA** | JS/TS | Yes* | Yes* | Yes* | Yes | IndexedDB/SQLite(wasm) | Very High | Low | 0 (web) |
| **.NET MAUI** | C# | Yes | Yes | Yes | No | SQLite | Medium | Medium | ~20MB |
| **SwiftUI+Kotlin** | Swift+Kotlin | Yes | Yes | No | No | Core Data/Room | Very High | Very High | ~5MB each |

\* Limited or via wrappers
\** High because Moodle App codebase is large and complex

---

## Recommendations by Priority

### If building for ss.nwpcode.org only:

1. **Quickest win: Use the Moodle App as-is** — Point it at ss.nwpcode.org. Zero development. Works today. (Scenario 1)

2. **Best custom app: Flutter + Drift** — Covers Scenarios 1-4. Build once, deploy as API shell (Scenario 1), add local DB (Scenario 2-3), export as APK for USB (Scenario 4).

3. **Best offline/USB: PWA + SQLite-WASM** — An `index.html` that opens in any browser. Course content in IndexedDB. Distribute on USB. Works on every device with a browser. Lowest friction for Scenario 4.

### If building for avc.nwpcode.org:

1. **Only Scenario 1 or 2 make sense** — AVC's collaborative workflows require a server. Standalone/offline AVC loses its core value proposition.

2. **Best choice: Flutter** — Existing `hybrid-implementation-plan.md` already lays out a 14-19 week plan. Follow it.

3. **Read-only offline mode** — A Scenario 2 app could show cached tasks/workflows offline but queue all changes for sync. This is realistic.

### If building for both sites:

1. **Flutter monorepo with shared packages** — One Flutter project, two app targets (or one app with site switcher). Shared auth, HTTP, and local DB layers.

2. **Moodle integration via LTI** — Instead of rebuilding Moodle in Flutter, embed Moodle courses in AVC via LTI 1.3 (already planned in proposals). Then one app covers both.

### If Scenario 4 (USB/air-gapped) is the priority:

1. **PWA is the universal answer** — HTML+JS+CSS opens on literally any device with a browser. No installation. Put it on a USB stick.

2. **Bundle CathNet too** — cathnet.db (25MB SQLite) is perfect for offline distribution. Concept map + Catechism search on a USB stick is a powerful catechetical tool.

3. **Android APK as secondary** — For a better native experience, also include a Flutter APK. But the PWA is the fallback that always works.

---

## The "One App to Rule Them All" Option

If you wanted a single app covering everything:

```
NWP Catholic App
  |
  +-- Courses (ss.nwpcode.org data)
  |     Quiz engine, completion tracking, Rosary/Examen content
  |
  +-- Community (avc.nwpcode.org data)  [online only]
  |     Tasks, workflows, guilds, notifications
  |
  +-- Catechism (ccc.nwpcode.org data)
  |     Concept map, paragraph search, cross-references
  |
  +-- Mass Times (mt.nwpcode.org data)
  |     Parish map, next mass finder, GPS proximity
  |
  +-- Radio Archive (dir.nwpcode.org data)
        Episode search, transcript reading, timestamps
```

**Best stack for this:** Flutter + Drift + Riverpod
**Effort:** 6-9 months for Scenarios 1-2, 12+ months for Scenario 3
**Offline bundle size:** ~150MB (all content + embeddings)

This is ambitious but architecturally clean — each "module" in the app maps to one site, and each can operate in whichever scenario mode makes sense (AVC online-only, courses offline-capable, Catechism fully offline, Mass Times cached-with-sync).

---

## Related Documentation

- `sites/avc/html/profiles/custom/avc/docs/mobile/mobile-app-options.md` — AVC-specific mobile options analysis
- `sites/avc/html/profiles/custom/avc/docs/mobile/hybrid-mobile-approach.md` — Hybrid strategy keeping Drupal backend
- `sites/avc/html/profiles/custom/avc/docs/mobile/hybrid-implementation-plan.md` — 9-phase implementation plan (14-19 weeks)
- `sites/avc/html/profiles/custom/avc/docs/mobile/python-alternatives.md` — Python/Django recreation analysis
- `docs/proposals/F18-cathnet-acmc.md` — CathNet concept mapping system
- `docs/proposals/F19-cathnet-nlp-qa.md` — CathNet offline NLP search
- `docs/proposals/F19-amendment-A1-synthesis.md` — Multi-paragraph synthesis without runtime LLM
