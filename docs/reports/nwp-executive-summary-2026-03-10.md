# Narrow Way Project (NWP): Executive Summary

**Date:** 10 March 2026
**Full Report:** nwp-status-2026-03-10.md

---

## Overview

Over four months (December 2025 -- March 2026), a single developer with AI-assisted tooling has built an integrated Catholic faith formation ecosystem spanning 9 project repositories, 6 production websites, ~100,000 files, and 20 GB of structured content -- all running on a $26/month infrastructure.

The platform's centrepiece is a **cross-platform faith formation app** (F20) that bundles 49 courses from ss.nwpcode.org and runs offline on phones, tablets, laptops, and desktops from a single Flutter codebase. The app is designed as a shell that progressively integrates content from every other project in the ecosystem.

---

## The Faith Formation App (F20) -- Phases 1-7 Complete

The app ships with the complete Divine Intimacy Radio standalone mini-course catalogue: **49 courses across 10 categories** (Foundations, Prayer, Growing in Prayer, Discernment of Spirits, The Ascetical Life, Suffering & Warfare, Marriage & Community, Saints as Guides, False Teachings, The Interior Castle), covering the full arc of Catholic spiritual formation from beginner to advanced.

**Bundled database:** 49 courses, 315 sections, 160 quizzes, 732 questions, 1,797 answers. All 160 quizzes are fully populated and working.

**What works now:**
- Category-grouped course browser with per-course progress rings
- Tabbed section viewer rendering Moodle HTML content
- Quiz engine supporting multiple choice, true/false, short answer, and matching questions
- 80% pass threshold with per-question feedback and unlimited retakes
- Progress tracking with section visit detection and course completion logic
- Progress export to JSON for USB transfer
- Liturgical colour theme with full dark mode
- Linux desktop release build (56 MB); Android, iOS, Windows, macOS, and Web targets available

**Pending:** Phase 8 (Moodle server sync) and Phase 9 (content pack system for adding courses without rebuilding).

---

## Content Pipeline: From Audio to App

A repeatable pipeline converts podcast audio into structured educational content:

1. **CIYTools** -- 10-stage dual-precision transcription (INT8 on GPU + FP32 on CPU) with CCC source text alignment, producing letter-perfect doctrinal quotations. 1,013 episodes transcribed (365 CIY (Catechism in a Year) complete, 648 DIR in progress), ~3.3 million words.

2. **DIR** -- 648 episodes of Divine Intimacy Radio live at dir.nwpcode.org with full-text search across 288,236 timestamped segments. Educational derivatives include 10 comprehensive Moodle course specifications and the 49 mini-courses now bundled in the app.

3. **Moodle (ss.nwpcode.org)** -- Courses authored and managed in Moodle, exported to the app via a single SSH/PHP call (`moodle_live_export.py --all`), converted to a seed SQLite database, and bundled as a Flutter asset.

---

## CathNet Knowledge Graph (F18/F19)

Realises a 2005 MEd(Research) proposal: "Automatically Concept Mapping the Catechism."

- **2,863 paragraphs** parsed into a navigable knowledge graph with 300+ concepts and 4,134+ relationships
- **Interactive concept map** (Cytoscape.js) with macro/micro views and click-to-zoom navigation
- **Offline NLP search** with semantic retrieval, extractive QA, and cross-encoder re-ranking -- all running locally with no API costs (~685 MB RAM)
- **Planned: Prolog inference engine** (F19 Amendment A1) enabling multi-step theological reasoning from 15,000+ formal facts, answering complex doctrinal questions entirely offline

CathNet is designed to ship as a **25 MB content pack** for the faith formation app.

---

## Supporting Projects

**Prayer** -- 13 GB theological library (342 Church Fathers, complete Aquinas, Magisterium) plus curriculum for Mazenod College including 100+ guided meditation scripts and a 4-year RE programme.

**Logic** -- 8-lesson Aristotelian logic curriculum (3 variants each) based on Kreeft's *Socratic Logic*, with automated document generation and Learnosity quiz banks. Includes "Fallacies Against the Catholic Faith" (30+ formal refutations).

**Carmel** -- 1.5 GB interlinear reading system for 16th-century Carmelite Spanish. Complete works of St. Teresa of Avila and St. John of the Cross in original Spanish plus five English translation editions (Peers, Lewis, Zimmerman, Kavanaugh-Rodriguez, Stanbrook Benedictines) -- 773 MB of public domain texts. 364 texts imported into LWT (Learning with Texts) with sentence/word parsing. 61,636 unique words extracted from 1.7M tokens with 61.9% coverage. Custom Carmelite Dictionary API (Flask + SQLite) serving 890+ definitions including entries from Covarrubias' 1611 *Tesoro de la Lengua Castellana* with era-aware tagging (`[16c]` vs `[mod]`). Three-container Docker infrastructure (LWT web app, dictionary API, MariaDB). Phases 1-2 complete; phases 3-5 pending (enhanced interlinear display, parallel translation, morphological analysis).

**Truth/DOS** -- Philosophical comparative analysis (Thomistic Catholicism scores 8.5/10 across six criteria) and scholarly translation of Ignatius's 14 Rules for the Discernment of Spirits (5 translations, new 2025 synthesis).

---

## Infrastructure: NWP

NWP (Narrow Way Project) is the deployment and operations layer. 52+ completed proposals provide recipe-based site provisioning, four-tier deployment (DEV -> STG -> LIVE -> PROD), automated backup/restore, 553+ verification items, and comprehensive security. Six production sites run on a single Linode server.

---

## The Integrated Vision: Five Phases

The app evolves through five phases, each building on the last to transform a standalone study tool into a comprehensive formation platform.

### Phase 1: Standalone App (Current)

The app ships as a self-contained package with all 49 courses, 160 quizzes, and progress tracking bundled in a local SQLite database. It requires no internet connection and can be distributed via USB stick -- making it immediately usable in parishes, seminaries, and developing nations with limited connectivity. Users study at their own pace, take quizzes with instant feedback, and export their progress to JSON for transfer back to a coordinator.

### Phase 2: Connected (F20 Phase 8)

Adding optional Moodle Web Services connectivity turns the app into a two-way sync client for ss.nwpcode.org. Users who have internet access can download updated or newly published courses, and upload their quiz scores and progress to the central Moodle server. Sync is queue-based: actions are stored locally when offline and transmitted automatically when connectivity returns. A simple "Connect to Moodle" toggle in settings keeps the offline-first experience intact for users who prefer it.

### Phase 3: Extensible (F20 Phase 9)

A content pack system allows new material to be added without rebuilding the app. Each pack is a ZIP file containing a SQLite database fragment and metadata JSON. Planned packs include:

- **CathNet Catechism** (25 MB) -- interactive concept map, 2,863 paragraphs with cross-references, semantic search, and extractive QA
- **Logic Curriculum** -- 8 Aristotelian logic lessons with quizzes and a fallacies reference
- **DIR Transcript Archive** -- searchable transcripts of all 648 Divine Intimacy Radio episodes with YouTube deep-links
- **Apologetics** -- comparative analysis framework, evidence documents, and self-assessment quizzes from the Truth project

Packs can be loaded from USB or downloaded, letting the app grow without requiring app store updates.

### Phase 4: Community

Integration with AVC (the community platform) adds a social dimension to what has been a solitary study experience. Features include per-course discussion forums, mentorship matching (pairing advanced students with beginners), group study sessions, and guild membership tracking. The theological library from the Prayer project (342 Church Fathers, complete Aquinas, Magisterium, Scripture) becomes searchable within the app. The Carmelite Reading Room brings interlinear Spanish-English texts with historical dictionary lookups and vocabulary tracking.

### Phase 5: Certification and Guilds

The final phase introduces a medieval guild-inspired certification model with two parallel tracks, each progressing through five tiers:

- **Spirituality Guild** (Seeker → Practitioner → Director-in-Training → Spiritual Director → Formation Director): Begins with completing foundational and prayer courses, advances through the full DIR programme and Interior Castle capstone, and culminates in mentored practice and certified spiritual direction of others.
- **Theology Guild** (Student → Apologist → Theologian → Scholar → Doctor): Begins with CathNet Catechism exploration, advances through logic, apologetics, and patristic study, includes original-language work (Carmelite Spanish, Latin, or Greek), and culminates in peer-reviewed research contribution.

Certification combines automated tracking (quiz scores, section visits, concept coverage) with human verification (mentor confirmation at Tier 4, peer review at Tier 5). Certificates are issued through Moodle with blockchain verification.

---

## Guild Certification Model

**Spirituality Guild:** Seeker -> Practitioner -> Director-in-Training -> Spiritual Director -> Formation Director. Progresses from completing foundational courses through mentored practice to certified mentoring of others.

**Theology Guild:** Student -> Apologist -> Theologian -> Scholar -> Doctor. Progresses from Catechism exploration through logic and apologetics, patristic study, original-language work, to peer-reviewed research contribution.

Certification combines automated tracking (quiz scores, section visits, concept coverage) with human verification (mentor confirmation, peer review at advanced tiers).

---

## Key Numbers

| Metric | Value |
|--------|-------|
| Development period | ~4 months |
| Developer count | 1 (with AI assistance) |
| Monthly infrastructure cost | ~$26 |
| Production websites | 6 |
| App bundled courses | 49 (160 quizzes, 732 questions) |
| Podcast episodes transcribed | 1,013 |
| Catechism paragraphs mapped | 2,863 |
| Theological concepts extracted | 300+ |
| Church Fathers in library | 342 |
| Flutter build targets | 6 platforms |
| NWP proposals completed | 52+ |

---

## Immediate Priorities

1. **F20 Phase 8** -- Moodle Web Services sync (enables connected experience)
2. **F20 Phase 9** -- Content pack format and first CathNet pack (enables extensibility)
3. **Android APK testing** on real devices (highest-impact distribution channel)
4. **App Store submission** (Google Play and Apple App Store)
5. **DIR FP32 transcription completion** (ETA March 18, improves content accuracy)

---

## Significance

The ecosystem demonstrates that a single developer with AI assistance can build what would traditionally require a funded team of 10-20 people over 2-3 years. For Catholic education, this means small parishes, remote communities, and developing nations can access structured formation programmes previously available only to well-resourced institutions -- delivered on a phone, entirely offline if needed, for effectively zero cost to the end user.

The extractive (not generative) approach to AI ensures the system always presents the Church's own words with precise citations, never AI-generated paraphrases -- respecting magisterial authority while making the Catechism vastly more accessible.

---

*Summary of the full report: nwp-status-2026-03-10.md*
