# Narrow Way Project (NWP): Comprehensive Achievement Report

**Date:** 10 March 2026
**Author:** Rob Zaar, with Claude Opus 4.6
**Scope:** All projects across ~/nwp, ~/prayer, ~/logic, ~/carmel, ~/dir, ~/ciytools, ~/claudemax, ~/dos, ~/truth

---

## Executive Summary

Over the course of approximately four months (December 2025 -- March 2026), a single developer working with AI-assisted tooling has built an integrated ecosystem of Catholic faith formation, theological research, and educational technology spanning nine project repositories, 100,000+ files, and roughly 20 GB of structured content. What began as a Drupal hosting automation tool (NWP) has evolved into the foundation for a comprehensive Catholic digital formation platform -- one that can operate as a native app (Android/iOS/desktop), a Progressive Web App, a laptop-based learning tool, or a USB-distributed offline package for environments with no internet connectivity.

The end-game vision, crystallised in proposal F20 and informed by all preceding work, is a **faith formation application** that:

- Ships with all 49 courses from ss.nwpcode.org -- the complete Divine Intimacy Radio mini-course catalogue covering Foundations through the Interior Castle
- Can be updated with additional courses as they are added to ss.nwpcode.org (Moodle LMS)
- Can integrate the CathNet interactive Catechism concept map for doctrinal exploration
- Can connect to collaborative communities via the AVC Drupal site
- Can incorporate the theological and spiritual research libraries for deep study
- Supports guild-based certification in theology and spirituality through mentored use
- Works entirely offline (USB distribution) or online with sync capabilities
- Runs on phones, tablets, laptops, and desktops from a single codebase (Flutter)

This report documents what has been achieved, the methods used, the architecture that connects the projects, and recommendations for the path forward.

---

## Table of Contents

1. [The Nine Projects](#1-the-nine-projects)
2. [Infrastructure: NWP](#2-infrastructure-nwp)
3. [Content Pipeline: CIYTools and DIR](#3-content-pipeline-ciytools-and-dir)
4. [The Faith Formation App: F20](#4-the-faith-formation-app-f20)
5. [The Knowledge Graph: CathNet (F18/F19)](#5-the-knowledge-graph-cathnet-f18f19)
6. [Theological Research Library: Prayer](#6-theological-research-library-prayer)
7. [Educational Curricula: Logic](#7-educational-curricula-logic)
8. [Spiritual Reading Platform: Carmel](#8-spiritual-reading-platform-carmel)
9. [Foundational Research: Truth and DOS](#9-foundational-research-truth-and-dos)
10. [Development Tooling: ClaudeMax](#10-development-tooling-claudemax)
11. [Key Methods and How It Was Achieved](#11-key-methods-and-how-it-was-achieved)
12. [The Integrated Vision: From F20 to the Full Platform](#12-the-integrated-vision)
13. [Guild-Based Certification Model](#13-guild-based-certification-model)
14. [Deployment Scenarios](#14-deployment-scenarios)
15. [Recommendations and Future Work](#15-recommendations-and-future-work)
16. [Implications](#16-implications)
17. [Appendix: Project Statistics](#17-appendix-project-statistics)

---

## 1. The Nine Projects

| Project | Directory | Type | Size | Status |
|---------|-----------|------|------|--------|
| **NWP** (Narrow Way Project) | `~/nwp` | Infrastructure & hosting | 200+ docs, 38 libs, 48 commands | Production (v0.29.0) |
| **CIYTools** | `~/ciytools` | Transcription pipeline | 6.7 GB, 365 episodes | Complete (CIY), 78% (DIR) |
| **DIR** (Divine Intimacy Radio) | `~/dir` | Searchable archive + courses | 648 episodes, 288K segments | Live at dir.nwpcode.org |
| **Prayer** | `~/prayer` | Theological library + curriculum | 13 GB, 81,600+ files | Active development |
| **Logic** | `~/logic` | Aristotelian logic curriculum | 221 files, 8 lessons | Active development |
| **Carmel** | `~/carmel` | Interlinear reading system | 773 MB texts, 364 imported | Active development |
| **Truth** | `~/truth` | Philosophical analysis | 12 documents, ~300 KB | Complete |
| **DOS** (Discernment of Spirits) | `~/dos` | Translation & analysis | 91 files, 3.6 MB | Complete |
| **ClaudeMax** | `~/claudemax` | AI development tooling | 6 scripts, 3 docs | Production |

---

## 2. Infrastructure: NWP

**NWP -- Narrow Way Project** is the foundation layer. It is a recipe-based Drupal and Moodle hosting, deployment, and infrastructure automation system that provides the `pl` CLI for managing the entire lifecycle of web applications -- from local development through staging to production.

### Achievements (52+ completed proposals)

- **Core Infrastructure (P01--P35):** Four-tier deployment model (DEV -> STG -> LIVE -> PROD), DDEV-based local development, automated backup/restore, GitLab CI/CD integration, Linode server provisioning, Cloudflare DNS management, Let's Encrypt SSL
- **Verification System (P50--P51):** 553+ verification items with machine checks and human prompts, interactive TUI, badge generation, 99.5%+ machine pass rate
- **Security (P56, F05, F15):** Two-tier secrets architecture (infrastructure vs production credentials), UFW firewall, fail2ban, security headers, SSH user management
- **Governance (F04):** Distributed contribution model with role-based access (Newcomer -> Contributor -> Core Developer -> Steward)
- **Testing (F09):** Unified test framework spanning PHPCS, PHPStan, PHPUnit, Behat, and BATS with 200+ assertions
- **Documentation:** 100% command documentation, full library API reference, 200+ documentation files

### Active Deployments

| Site | URL | Platform | Purpose |
|------|-----|----------|---------|
| AVC | avc.nwpcode.org | Drupal | Audio-Visual Commons community |
| CathNet | cathnet.nwpcode.org | Drupal | Catechism concept map |
| DIR | dir.nwpcode.org | Drupal | Podcast transcript archive |
| MT | mt.nwpcode.org | Drupal | Mass times display |
| SS | ss.nwpcode.org | Moodle | Faith formation courses |
| GitLab | git.nwpcode.org | GitLab | Source code hosting |

### Why It Matters

NWP is not just a hosting tool -- it is the deployment and operations layer for the entire ecosystem. Every site, every module, every database, and every content pipeline flows through NWP's standardised recipes, backup systems, and deployment commands. Without this foundation, none of the other projects could reach production.

---

## 3. Content Pipeline: CIYTools and DIR

### CIYTools: AI-Powered Transcription at Scale

CIYTools is a 10-stage transcription pipeline that converts Catholic podcast audio into structured, searchable, time-stamped text with unprecedented accuracy.

**Architecture:**
1. RSS feed parsing and episode discovery
2. Audio download (MP3 from Libsyn)
3. **Dual-precision transcription:** INT8 on GPU (fast, ~3 min/episode) + FP32 on CPU (accurate, ~30 min/episode)
4. Auto-resolution of discrepancies between INT8 and FP32 outputs (32,231 resolved automatically for CIY (Catechism in a Year))
5. Optional Claude API conflict resolution for remaining ambiguities
6. **CCC source text alignment** -- the unique innovation: when Fr. Mike reads from the Catechism, the transcription is replaced with the authoritative source text from the official CCC, ensuring letter-perfect doctrinal quotations
7. Forced alignment for word-level timestamps (CTC alignment via torchaudio)
8. Validation and quality reporting

**Results:**

| Metric | CIY (Complete) | DIR (In Progress) |
|--------|---------------|-------------------|
| Episodes | 365 | 648 |
| Total words | 1,306,267 | ~2,000,000 (est.) |
| CCC-sourced words | 112,043 | N/A |
| INT8 transcription | Complete | Complete |
| FP32 transcription | Complete | ~9% (ETA March 18) |
| Word-level timestamps | Complete | Pending |

**Hardware:** NVIDIA RTX 2060 6GB GPU, 32GB RAM, CUDA 12.2, Python 3.12

### DIR: From Transcripts to Searchable Archive

The Divine Intimacy Radio project takes the CIYTools output and transforms 648 episodes of Catholic spiritual teaching into a live, searchable web archive.

**Live at:** https://dir.nwpcode.org/dir

**Features:**
- Full-text search across 648 episodes and 288,236 timestamped segments
- Episode transcript pages with timestamped segments
- YouTube video matching for 643+ episodes
- Custom Drupal `dir_search` module with 7 routes and 3 custom database tables

**Educational Content Derived:**
- 10 comprehensive Moodle course specifications (100 KB proposal)
- 49 standalone mini-courses (224 KB specification) designed for 15-minute mobile sessions
- "Spiritual Life Explained" systematic teaching guide (36 KB)
- "Disciplines Tree" skill-tree map of spiritual development (84 KB)
- Video guide with best teaching clips and timestamps (52 KB)

This content pipeline demonstrates a repeatable pattern: **audio -> transcription -> structured data -> searchable archive -> educational courses**. The same pattern can be applied to any podcast, lecture series, or audio teaching.

---

## 4. The Faith Formation App: F20

**Proposal F20** is the convergence point -- the application that brings together content from across the ecosystem into a single, deployable package.

### What Has Been Built (Phases 1--7 Complete)

| Component | Technology | Status |
|-----------|-----------|--------|
| Content export | Python (lxml, sqlite3) | Complete |
| Cross-platform UI | Flutter 3.41+ | Complete |
| Local database | Drift + SQLite | Complete |
| State management | Riverpod | Complete |
| Course viewer | Tabbed sections, HTML rendering | Complete |
| Quiz engine | Multiple choice, T/F, short answer, matching | Complete |
| Progress tracking | Section visits, quiz scores, course completion | Complete |
| Theming | Liturgical colours, dark mode, responsive layout | Complete |
| Linux build | 56 MB release binary | Complete |
| PWA server | Python serve_pwa.py for USB distribution | Complete |

### Bundled Courses (49 courses from ss.nwpcode.org)

The app ships with the complete Divine Intimacy Radio standalone mini-course catalogue, organised into 10 categories:

| Category | Courses | Topics |
|----------|---------|--------|
| **A: Foundations** | A1--A5 | Universal Call to Holiness, Interior Castle map, Three Phases, Paradigm of Ascent, Sacraments and Grace |
| **B: Prayer** | B1--B6 | Why Prayer, Sacred Time/Space, Lectio Divina, Distractions, Daily Examen, Rosary as Mental Prayer |
| **C: Growing in Prayer** | C1--C5 | Meditation to Contemplation, Prayer of Simplicity, Contemplative Prayer, Aridity/Dark Night, Teresa's Four Waters |
| **D: Discernment of Spirits** | D1--D6 | Battle Within, Consolation/Desolation, Ignatian Rules 1-14, Discernment in Daily Life |
| **E: The Ascetical Life** | E1--E5 | Self-Knowledge, Appetites/Attachments, Mortification, Little Way, Fasting/Habitual Sin |
| **F: Suffering & Warfare** | F1--F4 | God's Will, Redemptive Suffering, Spiritual Warfare, Defence Against the Enemy |
| **G: Marriage & Community** | G1--G4 | Marriage/Interior Castle, Warfare in Marriage, Community, Spiritual Direction |
| **H: Saints as Guides** | H1--H4 | St. Therese, St. John of the Cross, St. Ignatius, Fr. Jacques Philippe |
| **I: False Teachings** | I1--I3 | Centering Prayer, Mindfulness/Eastern Meditation, Yoga/Gateway Spirituality |
| **J: The Interior Castle** | J1--J7 | Seven Mansions journey from entry to Spiritual Marriage |

**Database totals:** 49 courses, 315 sections, 160 quizzes, 732 questions, 1,797 answers.

The home screen groups courses by category with per-category progress counters and per-course progress rings, making the 49-course catalogue navigable and trackable.

### Pending Phases

- **Phase 8: Server Sync** -- Optional connectivity to ss.nwpcode.org for content sync and progress upload via Moodle Web Services
- **Phase 9: Content Packs** -- Extensible content system (ZIP containing `.db` + metadata JSON) for adding courses without rebuilding the app, including CathNet catechism integration (25 MB database)

### Build Targets

Flutter enables a single codebase to compile for:
- Android (APK/AAB for Play Store)
- iOS (IPA for App Store)
- Linux desktop
- Windows desktop
- macOS desktop
- Web (PWA)

This means the app can be distributed through app stores, served as a PWA from any web server, distributed on USB drives, or installed directly on laptops.

---

## 5. The Knowledge Graph: CathNet (F18/F19)

CathNet realises Robert Zaar's 2005 MEd(Research) proposal at Australian Catholic University: "Automatically Concept Mapping the Catechism." In 2005, NLP accuracy was insufficient for theological text and no XML standard existed for Catholic catechetical knowledge. In 2026, both barriers have been overcome.

### F18: Interactive Concept Map (10 phases)

**Core capability:** Transform the Catechism's 2,865 paragraphs into a navigable knowledge graph with:
- **Macro view:** Full concept graph with clustered supernodes
- **Micro view:** Single paragraph with word-level concept highlighting
- **Sentence view:** Any word shows all sentences containing it
- **Navigation:** Click-to-zoom between macro and micro views
- **Auto-summation:** Select any concept and receive an ordered summary of all related passages

**Technology:**
- PostgreSQL + pgvector + Apache AGE (relational + vector + graph in one engine)
- Claude API for one-time concept extraction (~$15 total)
- Cytoscape.js for interactive visualisation
- JSON-LD + SKOS for semantic web interoperability
- all-MiniLM-L6-v2 for sentence embeddings (runs locally, no API cost)

**Already built:** 2,863 paragraphs parsed, 300+ concepts extracted, 4,134+ relationships identified, 5,937 sentence embeddings computed, Drupal module with routes for /map, /browse, /search, /paragraph.

### F19: Offline NLP Search and QA (6 phases)

**Design principle:** No ongoing AI API calls. All models run locally. Total runtime RAM: ~685MB.

**Capabilities:**
- Semantic search with cross-encoder re-ranking (transforms SQL LIKE into intelligent retrieval)
- Extractive QA: highlights the exact Catechism sentence that answers a question
- Query understanding: intent classification, entity recognition, concept graph expansion
- Pre-computed keyword and relationship indexes (YAKE, KeyBERT, spaCy triples)
- Graceful degradation: falls back to keyword search if NLP service is down

### F19 Amendment A1: Formal Knowledge Base (CCC-Net)

The most ambitious extension: a one-time Claude API analysis produces a **Prolog knowledge base** of the entire Catechism, enabling logical inference at runtime with zero API costs.

**Architecture:**
- **Phase 7A:** Build formal knowledge base -- 15,000+ Prolog facts, 200+ inference rules, doctrinal ontology in OWL
- **Phase 7B:** Prolog inference engine answers multi-step questions ("Can an unbaptised person receive Communion?") by chaining logical rules
- **Phase 7C:** Template-based natural language generation composes paragraph-length answers from Prolog query results

**This is the bridge between the knowledge graph and the educational platform.** When CathNet is packaged as a content pack (F20 Phase 9), the app gains the ability to answer theological questions using formal logical reasoning -- offline, on a phone, with no internet connection.

### Integration with F20

CathNet is designed to ship as a **25 MB content pack** that can be loaded into the faith formation app. Users would gain:
- Interactive concept map exploration on their phone
- Natural-language question answering about any Catechism topic
- Structured browsing of all 2,865 paragraphs with cross-references
- Concept-linked navigation ("show me everything related to Baptism")

---

## 6. Theological Research Library: Prayer

The Prayer project is the scholarly backbone -- a 13 GB theological research library and curriculum development workspace serving Mazenod College, Melbourne (a Catholic boys' secondary school, Years 7--10, 42% non-Catholic student population).

### The Library (8.4 GB primary sources)

| Collection | Size | Contents |
|-----------|------|----------|
| Patristics | 8.2 GB | 342 Church Fathers (ANF, NPNF1, NPNF2), Augustine, commentaries |
| Magisterium | 266 MB | CCC, Denzinger, Ludwig Ott, 21 Ecumenical Councils, Vatican II |
| Medieval | 229 MB | Complete Summa Theologiae (Aquinas), 9 medieval theologians |
| Modern | 1.2 GB | Garrigou-Lagrange, John Paul II, Edith Stein, Therese of Lisieux |
| Reformation | 177 MB | Ignatius of Loyola, Teresa of Avila, and others |
| Scripture | 60 MB | 3 Catholic Bible translations (RSV-CE, NRSV-ACE, NRSVACE) |

### The Curriculum

- **100+ guided meditation scripts** for Ignatian contemplation (Year 7, 5-minute duration, 340 words)
- **4-year RE program** (Years 7--10) with unit documents, assessment tasks, and teacher guides
- **GROW emotional literacy framework** verified against Catholic sources
- **Morality booklet** (v1 through v3, iterative refinement)
- **Conscience formation curriculum** with magisterial fidelity review

### Methodological Innovations

- **DBTI Framework** (Discussion-Based Theological Inquiry): pedagogical model for classroom theology with scaffolded discussion and structured inquiry
- **Magisterial Fidelity Protocol**: rigorous source hierarchy (Scripture -> Councils -> CCC -> Denzinger -> Ott -> Aquinas) with doctrinal authority classification
- **Multi-version document system**: Standard, DBTI, TI (guided inquiry), and Simple versions of each document, enabling one scholarly work to serve multiple audiences and ability levels

### Integration with the Platform

The Prayer library's structured theological data (parsed CCC JSON, Ott analysis, Aquinas extracts) can feed directly into:
- CathNet's concept extraction pipeline (as verification data)
- The faith formation app's content packs (as reference material)
- Guild certification requirements (as the authoritative source for theology assessments)

---

## 7. Educational Curricula: Logic

The Logic project is a multi-model Aristotelian logic curriculum based on Peter Kreeft's *Socratic Logic*, designed for Catholic secondary students (Year 10/VCE).

### What Has Been Built

- **8 complete lesson sets** x 3 variants (core, Part A spirituality, advanced) = 24+ lesson packages
- **221 total files** including DOCX worksheets, PPTX slide decks, and Learnosity JSON quiz banks
- **14 Python build scripts** for automated document generation
- **Three curriculum models:**
  - Model A: Pure logic (8 standalone lessons)
  - Model B: Spirituality + Logic (two-part lessons integrating contemplation with reasoning)
  - Model C: 4-course progressive curriculum (26 lessons, advanced track)

### Key Content

- Complete treatment of Aristotelian logic: Three Laws of Thought, Categories, Predicables, Square of Opposition, Syllogisms, Fallacies, Definition, Dialectic
- **"Fallacies Against the Catholic Faith"** (42 KB): 30+ common anti-Catholic arguments systematically refuted using formal logic
- **Relativism and Self-Refutation analysis**: proof by reductio ad absurdum that "there is no absolute truth" is self-contradictory
- **VCE-aligned teaching proposal** on St. Eugene de Mazenod with three significant life experiences

### Integration with the Platform

Logic lessons can be packaged as Moodle courses on ss.nwpcode.org and distributed through the faith formation app. The quiz generation pipeline (Learnosity JSON) can be adapted to Moodle question bank format. The "Fallacies Against the Catholic Faith" document is a natural candidate for a standalone mini-course in the DIR/Moodle framework.

---

## 8. Spiritual Reading Platform: Carmel

The Carmel project creates a digital platform for studying the 16th-century Spanish mystical works of St. Teresa of Avila and St. John of the Cross -- two Doctors of the Church and pillars of Carmelite mysticism. It is a 1.5 GB project combining a complete public domain text corpus, an interlinear reading platform, a historical dictionary API, and scholarly analysis tools.

### Text Corpus (773 MB)

The project preserves the complete works of both authors in their original 16th-century Spanish alongside multiple English translations:

**St. Teresa of Avila:**
- Libro de la Vida (Autobiography), Camino de Perfección (Way of Perfection), Las Moradas / Castillo Interior (Interior Castle), Libro de las Fundaciones (Book of Foundations), Conceptos del Amor de Dios (Meditations on Song of Songs), Exclamaciones del Alma, Letters, Poetry, Relations

**St. John of the Cross:**
- Subida del Monte Carmelo (Ascent of Mount Carmel), Noche Oscura (Dark Night of the Soul), Cántico Espiritual (Spiritual Canticle), Llama de Amor Viva (Living Flame of Love), Letters, Maxims, Poetry

**Translation editions:** Peers, Lewis, Zimmerman, Kavanaugh-Rodriguez, and Stanbrook Benedictines -- all public domain or permissively licensed. Texts available in PDF (original formatting), Markdown (clean reading), and TXT (NLP-ready).

### Interlinear Reading Platform

- **364 texts imported** into LWT (Learning with Texts) -- a community-maintained PHP/TypeScript reading platform -- with sentence/word parsing and indexing (235 chapters from Teresa, 129 sections from John)
- **Language configured** as "Spanish (16th Century)" with era-aware vocabulary tagging (`[16c]` vs `[mod]`)
- **Three-container Docker setup:** LWT web app (port 8010), Carmelite Dictionary API (port 5000), MariaDB database
- **LUTE** (Python-based reading tool) also configured as a lighter alternative

### Dictionary Infrastructure

| Source | Entries | Date | Notes |
|--------|---------|------|-------|
| Wiktionary Spanish | 798 | Modern | CC BY-SA 3.0 |
| Covarrubias Tesoro | 4,316 raw / 33 curated | 1611 | Public domain, from Internet Archive |
| Custom Carmelite Glossary | 77 | 2026 | Theological terms with era markers |
| **Total in API** | **890+** | | |

The **Carmelite Dictionary API** (Flask + SQLite) serves definitions at `/api/lookup/<word>` with autocomplete, stats endpoints, and an HTML popup format for LWT integration. Historical definitions from Covarrubias' 1611 *Tesoro de la Lengua Castellana* provide period-accurate meanings for words whose senses have shifted over four centuries.

### Vocabulary & Coverage

- **61,636 unique words** extracted from 1.7 million tokens across the full corpus
- **61.9% token coverage** achieved through automated vocabulary expansion (Wiktionary scraping, Covarrubias parsing, custom glossary)
- **584 words** imported into LWT with translations (361 newly added)
- High-frequency gaps are mostly common grammatical words already known to students

### Scholarly Analysis

- **"Stages of Prayer in Teresa and John"** -- comprehensive analysis from secondary sources (32 KB)
- **Primary source verification** -- same analysis rebuilt from the original Spanish texts (35 KB)
- **Comparison of methods** -- evaluating the accuracy of secondary scholarship against primary evidence (12 KB)

### Completed Phases

- **Phase 1 (Dictionary Coverage Expansion):** Complete -- vocabulary extraction, Wiktionary scraping, Covarrubias parsing, LWT import
- **Phase 2 (Dictionary Integration):** Complete -- 364 texts imported, language configured, dictionary API linked, Docker stack running

### Pending Phases

- **Phase 3 (Enhanced Interlinear Display):** Modify LWT frontend for era-aware tooltip meanings with visual styling
- **Phase 4 (Parallel Translation):** Side-by-side Spanish-English display with segment alignment
- **Phase 5 (Advanced Features):** Lemmatisation, morphological analysis, theological terminology indexing, scholarly annotation

### Why This Matters for the Platform

The Carmel project demonstrates that the ecosystem can support **original-language study of primary sources** -- not just English translations. This is critical for a theology guild where certification at advanced levels requires engagement with primary texts. The dictionary API pattern (historical definitions with era markers) is reusable for any pre-modern text corpus (e.g., Latin Vulgate, Greek New Testament, Arabic philosophical texts). The entire corpus is public domain or permissively licensed, enabling unrestricted redistribution.

---

## 9. Foundational Research: Truth and DOS

### Truth: Philosophical Comparative Analysis

A systematic evaluation of which philosophical or religious framework provides the most reasonable explanation of reality, using six criteria (evidential support, internal consistency, external consistency, explanatory power, parsimony, falsifiability).

**Key outputs:**
- Comprehensive final report (47 KB) evaluating 10+ frameworks
- Full comparative analysis (69 KB) across 12 domains
- Empirical evidence documents: Eucharistic miracles (cardiac tissue, blood type AB), Resurrection evidence (minimal facts method), Shroud of Turin analysis, NDE research
- Civilisation contributions analysis (21 KB)
- Conclusion: Thomistic Catholicism scores highest across all criteria (8.5/10)

### DOS: Discernment of Spirits Translation Project

A scholarly translation and comparative analysis of St. Ignatius of Loyola's 14 Rules for the Discernment of Spirits.

**Key outputs:**
- Five complete English translations preserved (Seager 1847, Morris 1880, Mullan 1914, Gallagher 2020, plus original Spanish)
- Massive comparative analysis (3,183 lines): sentence-by-sentence examination across all versions
- New "Improved 2025 Translation" synthesising the best of all four English translations (92-94% word similarity to Gallagher, with improved scholarly precision)

### Integration with the Platform

Both projects provide **foundational content** for apologetics and discernment courses. The Truth project's evidence-based approach to demonstrating the reasonableness of Catholic faith is directly applicable to courses on apologetics and evangelisation. The DOS translation work feeds directly into the Discernment of Spirits course (Course 4 of the DIR Moodle programme and Category D of the 49 standalone mini-courses).

---

## 10. Development Tooling: ClaudeMax

ClaudeMax is a utility suite that enhanced the development process itself -- the meta-tool that made building everything else more efficient.

**Components:**
- **Command aliases** (`co` for Opus, `cs` for Sonnet): quick Claude Code invocation
- **Completion notification**: desktop alert + sound when Claude finishes a long task
- **Session size monitoring**: auto-archives conversations exceeding 200 MB to prevent degradation
- **Conversation monitor daemon**: systemd service checking every 30 seconds, kills runaway processes
- **Comprehensive cheatsheet** (582 lines): Claude Code CLI reference covering permissions, hooks, model selection, cost optimisation
- **API reference** (137 lines): pricing, caching, batch API, rate limits

ClaudeMax represents an important insight: **the development methodology itself is a deliverable.** AI-assisted development at this scale requires explicit tooling to manage context windows, costs, and session lifecycle.

---

## 11. Key Methods and How It Was Achieved

### AI-Assisted Development as Force Multiplier

The entire ecosystem was built by a single developer using Claude Code (Anthropic's CLI) as the primary development partner. The methodology:

1. **Proposal-driven development:** Every significant feature begins as a written proposal (F-series or P-series) with clear phases, verification criteria, and cost estimates. This disciplined approach prevents scope creep and ensures each phase delivers independently useful output.

2. **Code first, AI last:** A consistent design principle across the ecosystem. Deterministic methods (regex, CSS selectors, SQL queries, rule-based classification) handle the bulk of work. LLM calls are reserved for tasks where no algorithmic shortcut exists (concept extraction from theological text, conflict resolution in ambiguous transcriptions).

3. **Incremental delivery:** No "big bang" launches. Each proposal phase produces a working, demonstrable system. F20 has 9 phases; phases 1-7 are complete and usable. CathNet has 10 phases; the data pipeline is complete and the Drupal module is functional.

4. **Dual-precision transcription:** The CIYTools innovation of running both INT8 (fast/GPU) and FP32 (accurate/CPU) transcriptions, then auto-resolving discrepancies, achieves professional-grade accuracy at a fraction of commercial transcription costs.

5. **Recipe-based infrastructure:** NWP's recipe system means standing up a new Drupal or Moodle site takes a single command (`pl install <recipe> <site>`). This dramatically reduces the friction of deploying new components of the ecosystem.

6. **Persistent AI memory:** Claude Code's project memory files (`~/.claude/projects/*/memory/MEMORY.md`) maintain context across sessions -- server details, deployment procedures, architectural decisions, and known issues carry forward without repetition.

### Technology Choices

| Layer | Choice | Rationale |
|-------|--------|-----------|
| Infrastructure | Bash + YAML + DDEV | Universal availability, no build toolchain, YAML for configuration |
| CMS | Drupal 10/11 | Extensible, API-first (JSON:API), proven at scale |
| LMS | Moodle 4.x | Open source, H5P support, SCORM compliance, LTI integration |
| Mobile/Desktop | Flutter | Single codebase for 6 platforms, offline-first with SQLite |
| Transcription | Faster-Whisper (large-v3) | State-of-the-art accuracy, runs on consumer GPU |
| NLP | sentence-transformers + spaCy | Runs locally, no API costs, 685 MB total RAM |
| Knowledge graph | PostgreSQL + pgvector | Relational + vector + graph in one engine |
| Visualisation | Cytoscape.js | Best graph visualisation library for web |
| Logical inference | SWI-Prolog | Proven for formal reasoning, zero runtime cost |

### Cost Structure

| Item | Cost |
|------|------|
| Linode shared server (all sites) | ~$20/month |
| Domain (nwpcode.org) | ~$12/year |
| SSL certificates | Free (Let's Encrypt) |
| CathNet concept extraction (one-time) | ~$15 |
| CathNet RAG queries (ongoing) | ~$3/month |
| All NLP models | Free (open source, local) |
| Flutter builds | Free (open source SDK) |
| **Total ongoing** | **~$26/month** |

---

## 12. The Integrated Vision: From F20 to the Full Platform

The faith formation app (F20) is designed as a **shell that can be progressively filled** with content from across the ecosystem. Here is how the pieces connect:

### Phase 1: Standalone App (Current State)

```
Faith Formation App (Flutter)
├── 49 courses (A1-J7) bundled in SQLite (756 KB)
│   ├── 10 categories: Foundations through Interior Castle
│   ├── 315 sections of teaching content
│   ├── 160 quizzes with 592 questions
│   └── Category-grouped home screen with progress tracking
├── Quiz engine (4 question types)
├── Progress tracking + JSON export
└── Offline-first, USB-distributable
```

### Phase 2: Connected to Moodle (F20 Phase 8)

```
Faith Formation App
├── All Phase 1 features (49 bundled courses)
├── Sync with ss.nwpcode.org
│   ├── Download updated or new courses
│   ├── Upload progress/scores
│   └── Queue offline, sync when connected
└── Settings: "Connect to Moodle" toggle
```

### Phase 3: Content Packs (F20 Phase 9)

```
Faith Formation App
├── All Phase 2 features
├── Content Pack: CathNet Catechism (25 MB)
│   ├── Interactive concept map
│   ├── 2,865 paragraphs with cross-references
│   ├── Semantic search + extractive QA
│   └── (Optional) Prolog inference engine
├── Content Pack: Logic Curriculum
│   ├── 8 lessons with quizzes
│   └── Fallacies reference
├── Content Pack: DIR Transcript Archive
│   ├── Searchable transcripts (648 episodes)
│   └── Video deep-links to YouTube
└── Content Pack: Apologetics (from Truth project)
    ├── Comparative analysis framework
    ├── Evidence documents (Eucharist, Resurrection, Shroud)
    └── Self-assessment quizzes
```

### Phase 4: Community Integration

```
Faith Formation App
├── All Phase 3 features
├── AVC Community Connection
│   ├── Discussion forums (per course)
│   ├── Mentorship matching
│   ├── Group study sessions
│   └── Guild membership and progress
├── Theological Library Access
│   ├── Searchable Patristics (342 Church Fathers)
│   ├── Aquinas Summa with cross-references
│   ├── Magisterial documents
│   └── Scripture (3 Catholic translations)
└── Carmelite Reading Room
    ├── Interlinear Spanish-English texts
    ├── Historical dictionary lookups
    └── Vocabulary tracking
```

### Phase 5: Certification and Guilds

```
Faith Formation App
├── All Phase 4 features
├── Spirituality Guild
│   ├── Tier 1: Complete Foundations + Prayer courses
│   ├── Tier 2: Complete Ascetical Life + Discernment
│   ├── Tier 3: Complete all 10 DIR courses + Capstone
│   ├── Tier 4: Mentored practice (verified by guild mentor)
│   └── Tier 5: Certified to mentor others
├── Theology Guild
│   ├── Tier 1: CathNet Catechism exploration (coverage threshold)
│   ├── Tier 2: Logic curriculum + apologetics courses
│   ├── Tier 3: Patristic reading programme
│   ├── Tier 4: Original-language study (Carmel, Latin, Greek)
│   └── Tier 5: Research contribution + mentoring
└── Certificate issuance via Moodle + blockchain verification
```

---

## 13. Guild-Based Certification Model

The guild model draws on medieval craft guild structures adapted for spiritual and theological formation:

### Spirituality Guild

| Level | Title | Requirements | Content Source |
|-------|-------|-------------|---------------|
| Apprentice | Seeker | Complete Foundations + Prayer courses (DIR Course 1-2) | DIR mini-courses, ss.nwpcode.org |
| Journeyman | Practitioner | Complete Discernment + Ascetical Life + one elective (DIR Course 3-6) | DIR courses, DOS translation |
| Craftsman | Director-in-Training | Complete all 10 DIR courses + Interior Castle Capstone | Full DIR programme |
| Master | Spiritual Director | 1 year mentored practice, verified by guild mentor | AVC community, mentor matching |
| Grand Master | Formation Director | 3 years directing others, peer review, contribution to course content | AVC governance |

### Theology Guild

| Level | Title | Requirements | Content Source |
|-------|-------|-------------|---------------|
| Apprentice | Student | CathNet concept map exploration (visit 80%+ of concepts) | CathNet (F18) |
| Journeyman | Apologist | Logic curriculum + apologetics courses + 50 QA sessions on CathNet | Logic project, Truth project, CathNet (F19) |
| Craftsman | Theologian | Patristic reading programme (20+ Fathers) + Aquinas study | Prayer library |
| Master | Scholar | Original-language study (Carmel Spanish, Latin, or Greek) + research paper | Carmel project |
| Grand Master | Doctor | Peer-reviewed contribution to theological knowledge base + 3 years mentoring | All projects |

### How Certification Works

1. **Course completion** is tracked automatically by the app (quiz scores, section visits, time spent)
2. **Practice verification** uses structured self-reporting confirmed by assigned mentors through the AVC community platform
3. **Mentorship** is facilitated through the AVC site's group and messaging features (existing OpenSocial integration)
4. **Certificates** are issued through Moodle's certificate module with unique verification codes
5. **Guild progression** is visible on the user's profile, encouraging continued growth
6. **Content contribution** at higher levels feeds back into the ecosystem (new courses, improved translations, research documents)

---

## 14. Deployment Scenarios

### Scenario 1: App Store Distribution

- Flutter builds to Android (Play Store) and iOS (App Store)
- Bundled with all 49 formation courses (Foundations through Interior Castle)
- Optional in-app content pack downloads (CathNet, Logic, Apologetics, etc.)
- Free to download; content packs also free (mission-driven, not commercial)
- Online sync to ss.nwpcode.org for progress tracking and community features

### Scenario 2: Progressive Web App (PWA)

- Served from any web server (ss.nwpcode.org or parish-hosted)
- No app store approval required
- Works on any device with a modern browser
- Service worker enables offline functionality after first load
- `tools/serve_pwa.py` included for USB-based PWA serving

### Scenario 3: Laptop/Desktop Installation

- Flutter builds to Linux, Windows, and macOS
- Full functionality identical to mobile
- Larger screen enables side-by-side content (e.g., concept map + paragraph text)
- Ideal for theological library research and original-language study

### Scenario 4: USB Distribution (No Internet)

- `tools/build_all.sh` assembles a complete USB distribution folder
- Contains: app binary + content packs + PWA fallback + documentation
- Users run the app directly from USB or install locally
- Progress exports to JSON on USB, carried back to parish for upload
- Critical for remote communities, developing nations, restricted environments

### Scenario 5: Parish/Institutional Deployment

- Parish installs Moodle (via NWP recipe `m`) on any hosting
- Imports course content from the course specification documents
- Distributes the app to parishioners (app store, PWA, or USB)
- App syncs with the parish's Moodle instance
- Mentors track progress through Moodle gradebook
- Community discussion through AVC-style Drupal site (optional)

---

## 15. Recommendations and Future Work

### Immediate Priorities (Next 4 weeks)

1. **Complete F20 Phase 8 (Server Sync):** Implement Moodle Web Services client for bidirectional sync between the app and ss.nwpcode.org. This unlocks the connected experience.

2. **Complete F20 Phase 9 (Content Packs):** Define and implement the content pack format (ZIP containing `.db` + metadata JSON). Build the first content pack from the existing CathNet data.

3. **Android APK testing:** Verify the Flutter build on real Android devices. This is the highest-impact distribution channel.

4. **Complete DIR FP32 transcription:** The higher-quality transcripts (ETA March 18) will improve the DIR search experience and course content accuracy.

### Medium-Term (1--3 months)

5. **Enrich existing Moodle courses:** The 49 courses on ss.nwpcode.org are live and bundled in the app. Enhance them with H5P interactive content, additional video timestamps, and habit formation prompts as specified in MOODLE_COURSE_PROPOSAL.md.

6. **Implement CathNet F18 Phase 6 (Drupal visualisation):** The data pipeline is complete; the interactive Cytoscape.js concept map needs to be built in the Drupal module.

7. **Package Logic curriculum for Moodle:** Convert the 8 lesson sets and Learnosity quizzes to Moodle question bank format. Deploy as courses on ss.nwpcode.org and export to the app.

8. **App Store submission:** Prepare and submit to Google Play Store and Apple App Store with appropriate metadata, screenshots, and privacy policy.

9. **PHP 8.3 upgrade on live server:** Required for DIR's SQLite FTS5 search to work in production (currently using SQL LIKE fallback).

### Long-Term (3--12 months)

10. **Implement F19 NLP service:** Deploy the offline NLP search and extractive QA system on the server. This transforms CathNet from a browsable map into an intelligent question-answering system.

11. **Implement F19 Amendment A1 (CCC-Net Prolog):** Build the formal knowledge base. This is the most intellectually ambitious component but has the highest long-term payoff for the guild certification model.

12. **Build guild infrastructure:** Implement the certification tracking system in Moodle (completion criteria, badge system, mentor assignment) and the community features in AVC (groups, mentorship matching, discussion forums).

13. **Host the Carmel reading platform online:** Deploy LWT or a custom reading interface via NWP, enabling browser-based study of Teresa and John in original Spanish.

14. **Integrate the Prayer theological library:** Build a searchable index of the 8.4 GB primary source collection and expose it through the app's content pack system or as a web service.

15. **Multilingual support:** The Catechism exists in dozens of languages on the Vatican website. CathNet's concept graph structure is language-independent; adding additional language editions of the Catechism enables global reach.

16. **LTI 1.3 integration (F18 Phase 9):** Make the concept map embeddable in any LMS (not just Moodle), enabling Catholic schools and universities to integrate CathNet into their existing platforms.

---

## 16. Implications

### For Catholic Education

This ecosystem demonstrates that a **single developer with AI assistance** can build what would traditionally require a funded team of 10--20 people over 2--3 years. The implications for Catholic educational institutions are significant:

- **Small parishes** can offer structured formation programmes previously available only to well-resourced institutions
- **Remote communities** (including developing nations) can receive the same quality content via USB distribution
- **Catholic schools** can integrate the concept map, logic curriculum, and meditation scripts into their existing RE programmes via LTI
- **Seminaries and formation houses** can use the theological library and guild certification model for structured study

### For AI-Assisted Development

The project serves as a case study in what AI-assisted development makes possible:

- **Throughput:** 52+ completed proposals, 9 project repositories, 6 live production sites in ~4 months
- **Quality:** Comprehensive verification systems, security architecture, documentation coverage
- **Scope:** From infrastructure automation to NLP pipelines to mobile app development to scholarly translation -- domains that would traditionally require separate specialist teams
- **Cost:** Total infrastructure cost of ~$26/month for the entire ecosystem

### For the Church

The deepest implication is ecclesiological. The ecosystem creates a **digital formation pathway** from casual curiosity ("What does the Church teach about suffering?") through structured learning (courses and quizzes) to deep engagement (original-language study, theological research) to service (mentoring others through the guild system). This mirrors the traditional catechumenal journey but makes it accessible to anyone with a phone.

The extractive (not generative) approach to AI in CathNet is theologically important: the system always shows the Church's own words with precise citations, never AI-generated paraphrases that could introduce error. This respects the magisterial authority of the Catechism while making it vastly more accessible.

---

## 17. Appendix: Project Statistics

### Aggregate Numbers

| Metric | Value |
|--------|-------|
| Total project repositories | 9 |
| Total files (all projects) | ~100,000+ |
| Total data (all projects) | ~20 GB |
| Production websites | 6 |
| NWP proposals completed | 52+ |
| Podcast episodes transcribed | 1,013 (365 CIY + 648 DIR) |
| Transcript words | ~3,300,000 |
| Transcript segments (timestamped) | 288,236+ |
| Catechism paragraphs parsed | 2,863 |
| Theological concepts extracted | 300+ |
| Concept relationships | 4,134+ |
| Sentence embeddings | 5,937 |
| Church Fathers in library | 342 |
| Moodle courses live + bundled in app | 49 (A1--J7) |
| Moodle courses specified (full programme) | 10 full + 49 mini |
| Logic lessons created | 8 x 3 variants = 24+ |
| Carmelite texts imported | 364 |
| Unique Spanish words extracted | 61,636 |
| Dictionary definitions | 890+ |
| Guided meditation scripts | 100+ |
| App bundled courses | 49 (315 sections, 160 quizzes, 732 questions, 1,797 answers) |
| App seed database size | 804 KB |
| Flutter build targets | 6 (Android, iOS, Linux, Windows, macOS, Web) |
| Development period | ~4 months (Dec 2025 -- Mar 2026) |
| Developer count | 1 (with AI assistance) |
| Monthly infrastructure cost | ~$26 |

### Technology Inventory

| Category | Technologies Used |
|----------|------------------|
| Languages | Bash, Python, PHP, Dart, JavaScript, SQL, Prolog (planned) |
| Frameworks | Drupal 10/11, Moodle 4.x, Flutter 3.41, Flask, FastAPI |
| Databases | MariaDB, PostgreSQL, SQLite, pgvector |
| AI/ML | Faster-Whisper, sentence-transformers, spaCy, Claude API, torchaudio |
| Infrastructure | DDEV, Docker, Linode, Cloudflare, GitLab CI/CD, systemd |
| Visualisation | Cytoscape.js, Leaflet/OpenStreetMap |
| Standards | JSON-LD, SKOS, LTI 1.3, xAPI, SCORM, OAuth2, JSON:API |

---

*This document covers the state of the CathNet ecosystem as of 10 March 2026. It is intended as both a record of achievement and a roadmap for continued development toward the full platform vision.*
