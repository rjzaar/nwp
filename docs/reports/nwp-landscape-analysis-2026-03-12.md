# NWP vs. the Catholic AI Landscape: Comprehensive Analysis

**Date:** 12 March 2026
**Author:** Rob Zaar, with Claude Opus 4.6
**Scope:** Deep comparison of all NWP subprojects against 75+ Catholic AI projects, open-source tools, and institutional initiatives

---

## Table of Contents

1. [Where NWP Fits](#1-where-nwp-fits)
2. [What's in NWP That Isn't in Other Projects](#2-whats-in-nwp-that-isnt-in-other-projects)
3. [What's in Other Projects That Could Improve NWP](#3-whats-in-other-projects-that-could-improve-nwp)
4. [Groups and Communities to Join](#4-groups-and-communities-to-join)
5. [Specific Technical Improvements NWP Should Make](#5-specific-technical-improvements-nwp-should-make)
6. [Questions You Haven't Asked](#6-questions-you-havent-asked)
7. [Recommended Priorities](#7-recommended-priorities)
8. [Appendix A: NWP Subproject Deep Dives](#appendix-a-nwp-subproject-deep-dives)
9. [Appendix B: External Project Details](#appendix-b-external-project-details)

---

## 1. Where NWP Fits

NWP occupies a **unique niche** in the Catholic tech ecosystem. Most Catholic AI projects (75+ identified) fall into one of three categories:

| Category | Examples | Approach |
|----------|----------|----------|
| **AI Chatbots** | Magisterium AI, Justin, CateGPT, Truthly | Wrap a commercial LLM with Catholic RAG corpus |
| **Prayer/Devotional Apps** | Hallow, Pray.com, Credo Chat, Grace | Audio-first, subscription model, celebrity narration |
| **Church Operations** | ParishStaq, CristO ERP, Source & Summit | SaaS parish management |

**NWP doesn't fit any of these.** It is:

- **Infrastructure-first** (not app-first) -- a deployment platform that hosts the ecosystem
- **Offline-first** (not cloud-dependent) -- USB-distributable, zero ongoing API costs
- **Knowledge-assessment-first** (not devotional) -- quizzes, courses, mastery tracking
- **Extractive, not generative** -- shows the Church's own words with citations, never AI paraphrases
- **Open source / free** (not subscription) -- mission-driven, not commercial
- **Multi-domain** -- spans infrastructure, NLP, mobile apps, transcription, linguistics, curriculum

This makes NWP more comparable to an **academic research project** or **digital humanities initiative** than to any of the commercial Catholic apps.

---

## 2. What's in NWP That Isn't in Other Projects

### A. CCC Knowledge Graph with Formal Logical Reasoning (CathNet)

**Nobody else has this.** The closest comparisons:

| Project | What It Does | How CathNet Differs |
|---------|-------------|-------------------|
| **Magisterium AI** | RAG over 28K+ documents, LLM-generated answers | CathNet uses **Prolog inference** (36,472 lines of facts/rules) for logical chaining -- no LLM at runtime. Answers are derived from formal logic, not generated text. |
| **Master Catechism** | Semantic search across 35+ historic catechisms | CathNet adds a **graph structure** (1,514 concepts, 5,305 relationships) with interactive Cytoscape.js visualization. Master Catechism is text-search only. |
| **catechism-ccc-json** | Static JSON of CCC paragraphs | CathNet adds concept extraction, embeddings, relationship typing, and a 5-tier answer pipeline on top of the raw text. |
| **CatholicOS ontologies** | OWL ontologies for Catholic knowledge | Early-stage (0 stars). CathNet already has working data (1,104 concepts, 1,778 relations, 119 semantic frames in CCC-Net). |

**CathNet's unique contributions:**

- Interactive concept map with macro/micro views (no one else has this)
- Prolog-based logical inference over the Catechism (unprecedented)
- Hybrid search: BM25 + semantic embeddings + cross-encoder re-ranking
- 5-tier answer pipeline: answer bank -> Prolog -> template NLG -> extractive QA -> LexRank
- Zero ongoing API cost after build ($32.50 total one-time)
- 55,742 Scripture citations and 26,855 document references parsed and linked
- 5,937 sentence embeddings (all-MiniLM-L6-v2, runs locally)
- FastAPI NLP service on localhost:8019 with /search and /ask endpoints
- Total runtime RAM: ~732 MB

### B. Dual-Precision Podcast Transcription with Source Text Alignment

**Nobody else does this.** Existing Catholic transcription:

| Project | Approach |
|---------|----------|
| **Pray.com PRAY Studio** | AI transcription for podcasts -- but focused on marketing clips, not scholarly accuracy |
| **Hallow** | Professional audio recording with scripts -- no transcription pipeline |
| **Verbum/Logos** | Text search of published books -- no podcast transcription |

**CIYTools' unique contributions:**

- Dual INT8+FP32 transcription with rule-based auto-resolution (32,231 discrepancies resolved automatically across CIY)
- CCC source text alignment -- replaces Whisper output with letter-perfect Catechism text (112,043 words, 8.6% of total)
- CTC forced alignment for word-level timestamps
- Reproducible 10-stage pipeline applicable to any Catholic podcast
- 1,306,267 total words transcribed for CIY (365 episodes)
- DIR: 648 episodes, INT8 complete, FP32 at ~9% (ETA March 14-18)

**Dual-precision empirical results (5-episode pilot):**

| Outcome | Percentage |
|---------|-----------|
| FP32 wins (formal CCC text, proper nouns, punctuation) | 61.6% |
| INT8 wins (conversational speech, filler words) | 30.9% |
| Neither correct (Latin terms, proper names) | 7.5% |

### C. Three-Tier Mass Times Extraction

**Credo Chat** has a church/Mass finder for 115,000+ churches, but it's a lookup service, not an extraction pipeline. NWP's mass_times module does **active extraction** with:

- Tier 1: Static baseline comparison (100% confidence if unchanged)
- Tier 2: Code-based CSS/regex/PDF parsing (85% confidence)
- Tier 3: LLM fallback with Claude Sonnet (cost-capped at $5/month, 10/day)
- Automated discovery from Google Places, Melbourne Archdiocese directory, MassTimes.org
- Template learning for repeat extractions
- Leaflet/OpenStreetMap interactive parish map
- Drupal module with JSON:API sync and Search API SQLite FTS5

### D. Interlinear 16th-Century Spanish Reading Platform (Carmel)

**Nobody in the Catholic AI space is doing original-language digital humanities.** The closest analog is the `awesome-theology` GitHub list which links to tools for Latin and Greek, but nothing for 16th-century Spanish Carmelite mysticism specifically.

**What's built:**

- 364 imported texts in LWT (235 Teresa + 129 John)
- Historical dictionary API with Covarrubias (1611) definitions
- Era-aware vocabulary tagging (`[16c]` vs `[mod]`)
- Docker infrastructure: LWT (port 8010) + Dictionary API (port 5000) + MariaDB
- 223 archaic vocabulary entries + 361 new definitions
- 61,636 unique words extracted, 61.9% token coverage
- Complete works of both Doctors of the Church in original Spanish

### E. Offline-First Faith Formation App with Quiz Engine (F20)

| Feature | NWP F20 | Hallow | Truthly | Magisterium AI |
|---------|---------|--------|---------|----------------|
| **Primary mode** | Knowledge mastery (quizzes) | Audio prayer/meditation | AI chat + micro-learning | Q&A answer engine |
| **Offline** | Full (SQLite, USB-distributable) | Partial (cached audio) | No (requires internet) | No |
| **Cost** | Free, no subscription | $9.99/month | $4.99/month | Free tier (10/week) |
| **Content** | 49 curated courses, 732 questions | 10,000+ audio sessions | AI-generated micro-lessons | 28K+ documents |
| **Quiz types** | 4 (MC, T/F, short answer, matching) | None | None | None |
| **Progress tracking** | Section visits + quiz scores + completion | Streaks + minutes | Goals | None |
| **Platform** | Flutter (6 platforms) | Native iOS/Android | Native iOS/Android | Web + API |
| **Content source** | Hand-curated from Moodle | Professional recordings | AI-generated | RAG over corpus |

F20 is the **only Catholic app** with a structured quiz engine and offline-first course delivery. It's also the only one distributable via USB for environments with no internet.

**What's built (Phases 1-7 complete):**

- 49 courses (A1-J7), 315 sections, 160 quizzes, 732 questions, 1,797 answers
- 10-table Drift/SQLite database with 3 DAOs
- Riverpod state management with reactive streams
- 4 question types: multiple choice, true/false, short answer, matching
- Progress tracking with section visits (30+ sec threshold), quiz scoring (80% pass), course completion
- Dark mode with liturgical color palette (deep blue, gold, cream, burgundy)
- Merriweather serif + Source Sans 3 typography
- Linux release binary (56 MB), Android APK (132+ MB), PWA web build
- USB distribution via tools/build_all.sh + tools/serve_pwa.py
- JSON progress export

### F. 13 GB Theological Research Library (Prayer)

No other project has assembled a comparable structured theological library:

| Collection | Size | Contents |
|-----------|------|----------|
| Patristics | 8.2 GB | 342 Church Fathers (ANF, NPNF1, NPNF2), Augustine, Latin/Greek/Syriac |
| Magisterium | 266 MB | CCC, Denzinger (4,500+ definitions), Ludwig Ott (376 statements), 21 Ecumenical Councils |
| Medieval | 229 MB | Complete Summa Theologiae (215,023 lines), 9 medieval theologians |
| Modern | 1.2 GB | Garrigou-Lagrange, John Paul II, Edith Stein, Therese of Lisieux |
| Reformation | 177 MB | Ignatius of Loyola, Teresa of Avila |
| Scripture | 60 MB | 3 Catholic Bible translations (RSV-CE, NRSV-CE, NRSVACE) |

Plus:
- 80+ Ignatian meditation scripts for Year 7
- 4-year RE program (Years 7-10) for Mazenod College
- DBTI research methodology framework
- Magisterial fidelity protocol with source hierarchy
- GROW emotional literacy framework verified against Catholic sources

---

## 3. What's in Other Projects That Could Improve NWP

### A. Magisterium AI's API and MCP Server -- HIGH PRIORITY

Magisterium now offers:

- **OpenAI-compatible Chat API** ($0.50/Mtok input, $2.00/Mtok output)
- **Search API** ($4-8/1K requests, returns relevant magisterial passages)
- **MCP Server** at `https://mcp.magisterium.com` (OAuth-authenticated, works with Claude Desktop)

**How NWP could use this:**

1. Wire the MCP server into Claude Code for theological verification during development
2. Use the Search API as a verification layer for CathNet's concept extraction (cross-check 1,514 concepts against 28K+ documents)
3. Use the Chat API for answer bank pre-computation (Phase 7B) -- answers grounded in magisterial sources
4. Integrate into F20 as an optional online feature (Phase 8/9)
5. Cost: Minimal. 1,600 pre-computed answers at ~500 tokens each = ~800K tokens = ~$2.00

### B. CatholicOS Ontologies -- MEDIUM PRIORITY

CatholicOS is building formal OWL ontologies for Catholic knowledge representation at [github.com/CatholicOS](https://github.com/CatholicOS).

**Opportunity:** Align CathNet's concept schema with CatholicOS's OWL ontology standard:

- Make CathNet interoperable with other Catholic knowledge projects
- Enable linked data / semantic web publishing (JSON-LD + SKOS already in CathNet proposal)
- Position NWP as a contributor to an emerging Catholic knowledge standard

**Repositories of interest:**
- `ontologies-project` -- OWL ontologies for liturgy, Scripture, magisterial hierarchy
- `ontology-semantic-canon` -- Framework modeling foundational sources of Catholic doctrine
- `ontokit-api` -- FastAPI-based collaborative OWL ontology curation API

### C. Machine-Readable Catholic Text Standards -- MEDIUM PRIORITY

Multiple projects provide Catholic texts in JSON:

| Project | Contents | Stars |
|---------|----------|-------|
| `nossbigg/catechism-ccc-json` | CCC in JSON (already used by NWP) | 37 |
| `aseemsavio/catholicism-in-json` | CCC + Canon Law + GIRM in JSON | 26 |
| `Biblia-Sacra-Vulgata` | Latin Vulgate REST API with CPDV translation | -- |
| `AquinasOperaOmnia` | Complete works of Aquinas | -- |

**What NWP should incorporate:**

- Canon Law JSON for guild certification rules
- GIRM JSON for liturgical reference in mass_times module
- Latin Vulgate API for Carmel's future Latin/Greek expansion
- Standardize NWP's own data exports in compatible JSON formats for others to consume

### D. Liturgical Calendar API -- LOW-MEDIUM PRIORITY

Both CatholicOS and the `awesome-catholic` list include liturgical calendar APIs.

**Opportunity:** Add liturgical calendar integration to:

- Show relevant courses based on liturgical season (Lent -> suffering/asceticism courses)
- Add daily readings to the Faith Formation app (via EWTN API or open-source alternatives)
- Seasonal theming (liturgical colors already in the app's design language)

### E. Algorethics -- LOW PRIORITY BUT WORTH KNOWING

The Vatican's Rome Call for AI Ethics implemented as a Python library ([github.com/smartkuttan/Algorethics](https://github.com/smartkuttan/Algorethics)). Integrates with TensorFlow, PyTorch, Scikit-Learn. If CathNet's NLP pipeline ever needs to demonstrate ethical compliance for institutional adoption, this provides ready-made fairness/bias/privacy checks.

### F. Parallel Bible Corpus Tools (BibleNLP) -- LOW PRIORITY

BibleNLP's parallel corpus tools (utoken, uroman, Wildebeest) would be useful if NWP adds multilingual Scripture support. The `ebible` parallel corpus format could be adopted for the Prayer library's three Bible translations. Primary mission is Bible translation support, not catechetical content, but the NLP tooling is reusable.

Key resources:
- [github.com/BibleNLP](https://github.com/BibleNLP) -- 10+ repositories
- [awesome-bible-nlp](https://github.com/BibleNLP/awesome-bible-nlp) -- Curated NLP resource list
- `assistant.bible` -- RAG-based Bible assistant (architecture could inform CathNet Q&A)

### G. Hallow's Educator Curriculum Model -- WORTH STUDYING

Hallow offers structured educator tools: teacher guides by topic/grade, sample lesson plans, curriculum supplements, and mental health sessions developed with Catholic psychologists. 20M+ downloads, $100M+ funding, #1 App Store on Ash Wednesday 2026.

NWP's Prayer project has 80+ meditation scripts but only for Year 7. Studying Hallow's curriculum packaging could inform how NWP packages the Logic curriculum and meditation scripts for broader adoption.

### H. Longbeard's Ephrem SLM -- MONITOR

Launching 2026. First Catholic Small Language Model, trained on 80,000+ digitized Catholic texts. Designed to be "theologically accurate without needing a billion-dollar data center." Could be relevant for:

- CathNet Phase 7B answer bank generation (Catholic-native model vs. general-purpose LLM)
- CIYTools conflict resolution (Stage 7)
- Future CCC-Net enrichment

---

## 4. Groups and Communities to Join

### Definitely Join

#### 1. SENT Ventures
- **Website:** [sentventures.com](https://www.sentventures.com/)
- **What:** Vetted community of Catholic founders, CEOs, and business leaders
- **Founded by:** John Cannon (Notre Dame, Oxford, Harvard MBA, former Carmelite Brother for 7 years)
- **Benefits:**
  - 1:1 mentorship with top Catholic founders (including Hallow's CTO Erich Kerekes)
  - Peer advisory groups
  - $70K+ in tech credits and discounts
  - VirtueTech workshops (virtue, silence, disciplined reflection)
  - Holy Collisions speed networking events
- **SENT Summit:** Annual event at Catholic University of America. Pitch competition: $10K cash + $50K in-kind. 400+ Catholic founders and investors attend.
- **Apply:** members.sentventures.com/signup
- **Why:** Most directly relevant network for Catholic tech builders

#### 2. Builders AI Forum (BAIF)
- **Website:** [baif.ai](https://www.baif.ai/)
- **What:** Premier Catholic AI conference at the Vatican/Gregorian University
- **Organizers:** Matthew Sanders (Longbeard CEO) + David Nazar, S.J.
- **Scale:** ~200 participants from 160 organizations (Microsoft, Palantir, Goldman Sachs, Catholic educators, bishops, Vatican officials)
- **Events:** BAIF 2024 (Vatican), BAIF 2025 (Gregorian University)
- **Pope Leo XIV** sent a message to BAIF 2025: "technological innovation can be a form of participation in the divine act of creation"
- **Contact:** info@baif.ai to express interest in BAIF 2026
- **Why:** CathNet's Prolog-based logical reasoning would be a distinctive presentation topic. No other project offers formal logical inference over the Catechism.
- **Suggested abstract:** "Formal Logical Reasoning Over the Catechism: A Prolog-Based Approach to Catholic AI That Works Offline"

#### 3. CatholicOS / Catholic Digital Commons Foundation
- **GitHub:** [github.com/CatholicOS](https://github.com/CatholicOS)
- **What:** Open-source Catholic tech organization building ontologies, parish tools, and AI platforms
- **Repositories:** ~10 repos (homilia-ai, ontologies-project, liturgical-calendar-api, outwardsign)
- **Status:** Early-stage (0 stars on most repos, but active commits)
- **Why:** Open-source aligned with NWP's philosophy. Their ontologies work complements CathNet. Good time to get involved as a founding contributor.
- **Action:** Contribute NWP's data formats, offer CathNet data as a resource

### Worth Exploring

#### 4. awesome-catholic
- **GitHub:** [servusdei2018/awesome-catholic](https://github.com/servusdei2018/awesome-catholic) (163 stars)
- **What:** Curated list of 76 Catholic open-source projects across 10 categories
- **Updated:** January 2, 2026 (maintained weekly)
- **Action:** Submit NWP's open-source components (CathNet, F20, mass_times, Carmel dictionary API) for listing
- **Why:** Most-watched Catholic open-source aggregator. Immediate visibility.

#### 5. Open Source Catholic
- **Website:** [opensourcecatholic.com](https://www.opensourcecatholic.com/)
- **GitHub:** [github.com/opensourcecatholic](https://github.com/opensourcecatholic)
- **What:** Older organization, central resource for Catholic OSS developers
- **Action:** Register and list NWP projects

#### 6. Noesis Collaborative
- **Website:** [noesiscollaborative.org](https://www.noesiscollaborative.org/)
- **Founded by:** Ron Ivey (research fellow, Harvard Human Flourishing Program)
- **What:** Nonprofit steering AI development toward human flourishing
- **Programs:** Noesis Institute (wisdom for AI builders), Noesis Forum (empowering communities), Noesis Lab (co-creating tools), HumanConnections.AI
- **Why:** Their HumanConnections.AI program aligns with NWP's community/guild vision. Co-hosted roundtable at House of Lords; attended Vatican AI Ethics conference.

#### 7. Notre Dame ACE Higher-Powered Learning
- **Website:** [ace.nd.edu/programs/higher-powered-learning/ai-catholic-education](https://ace.nd.edu/programs/higher-powered-learning/ai-catholic-education)
- **What:** Catholic AI Literacy Materials Challenge
- **Why:** NWP's Logic curriculum and meditation scripts could qualify

### Monitor / Long-term

#### 8. Catholic Institute of Technology (CatholicTech)
- **Website:** [catholic.tech](https://catholic.tech/)
- **What:** New university at Castel Gandolfo. BS in 5 engineering disciplines + philosophy/theology minor.
- **Tech+ Accelerator:** Office space at CIC Cambridge, Rome campus housing, $500/month stipend
- **Why:** More suited to early-stage commercial ventures, but worth watching

#### 9. Laudato Si' Startup Challenge
- **What:** Vatican-affiliated, $100K seed funding for 6-8% equity, mentoring in Rome
- **Why:** Would require NWP to incorporate as a venture

#### 10. Catholic Ventures (Denver)
- **Website:** [catholic.ventures](https://www.catholic.ventures/)
- **Founded by:** Matt Meeks (former CDO at Archdiocese of LA)
- **What:** Venture builder for Catholic small businesses and e-commerce

#### 11. Venture Catholic
- **Website:** [venturecatholic.com](https://www.venturecatholic.com/)
- **What:** Incubator for Catholic missionaries starting Christ-centered startups

---

## 5. Specific Technical Improvements NWP Should Make

### Infrastructure / Architecture

1. **Publish NWP's data as open standards.** Export CathNet's concept graph as JSON-LD + SKOS (already planned in F18). Publish the 25MB CathNet SQLite as a downloadable dataset. This positions NWP as a data provider, not just a consumer.

2. **Add Magisterium MCP to Claude Code config.** This gives you theologically-grounded verification during development sessions. Free at 100 requests/day. Config:
   ```json
   {
     "mcpServers": {
       "magisterium": {
         "url": "https://mcp.magisterium.com"
       }
     }
   }
   ```

3. **Initialize git for ~/prayer.** 81,623 files with no version control is the project's single biggest risk. A `.gitignore` excluding `theology/patristics/` (8.2 GB) would make this manageable.

4. **Run CIYTools Stage 7 with an actual API key.** 21,691 discrepancies are using FP32-fallback instead of Claude resolution. Cost: $5-15 one-time. This is the cheapest quality improvement available. Token usage currently shows 0 -- no API key was configured.

### CathNet

5. **Run Phase 7B (answer bank).** Framework exists, code is written (`cathnet/src/nlp/answer_bank_builder.py`), just needs to be executed. ~$12.50 one-time for 1,600 pre-computed answers using Claude Batch API (50% discount). This makes CathNet Q&A feel instant.

6. **Deploy cathnet.nwpcode.org.** DNS record + Drupal install + systemd service for the NLP microservice at localhost:8019. The data pipeline (Phases 1-7A) and Drupal module (12 routes, Cytoscape.js map, search UI) are production-ready.

7. **Cross-validate concepts against Magisterium API.** Use Magisterium's Search API ($4/1K requests) to verify that CathNet's 1,514 extracted concepts align with the broader magisterial corpus of 28K+ documents.

8. **Align with CatholicOS ontology standards.** Export CCC-Net concepts (1,104 concepts, 1,778 relations, 119 semantic frames) in OWL format for interoperability.

### Faith Formation App

9. **Test Android APK on real devices.** This is the highest-impact distribution channel. APK builds at 132+ MB, minSdkVersion 21 (Android 5.0+). Not yet tested on physical hardware.

10. **Add liturgical calendar awareness.** Use an open-source liturgical calendar API to suggest seasonally relevant courses and to add daily readings.

11. **Implement content pack system (Phase 9).** The CathNet 25MB database is the first natural content pack. Define the ZIP + metadata JSON format so other content can follow.

12. **Consider publishing to F-Droid** (open-source Android store) before Google Play. No $25 developer fee, aligned with NWP's open-source ethos, and the Catholic open-source community would discover it there.

### Transcription Pipeline

13. **Configure Claude API key for CIYTools Stage 7.** Cheapest quality improvement available. $5-15 for 21,691 better-resolved discrepancies across 365 CIY episodes.

14. **Lower CCC similarity threshold experimentally.** Currently at 0.70 in `segment_and_correct.py`, which misses paraphrased readings. Try 0.60 on a test batch to see if the remaining 984 unmatched paragraphs (34.4%) can be recovered.

15. **Explore Longbeard's Ephrem SLM** when released. If Ephrem is better at Catholic theological text than general-purpose models, it could improve both CIYTools conflict resolution and CathNet concept extraction.

### Carmel

16. **Reparse texts in LWT.** 364 texts were imported before vocabulary was added. This is a simple operation in the LWT UI (My Languages -> Spanish (16th Century) -> folder icon -> Mark All -> Reparse Texts) that would unlock full interlinear functionality.

17. **Expand vocabulary using the Prayer library's Aquinas Latin.** The Prayer project has the complete Summa in Latin (215,023 lines). Cross-referencing Teresa/John's theological vocabulary with Aquinas's Latin terminology would enrich the Carmelite dictionary.

### Mass Times

18. **Compare against Credo Chat's 115,000-church database.** They have global coverage. If there's an API, NWP could bootstrap discovery data for parishes beyond the Melbourne 20km radius.

### Documentation / Community

19. **Write a "How NWP Uses AI" architecture document** that articulates the "code first, AI last" philosophy. This would resonate at BAIF and with CatholicOS contributors who share concerns about over-reliance on commercial LLMs.

20. **Prepare a BAIF 2026 abstract.** Topic: "Formal Logical Reasoning Over the Catechism: A Prolog-Based Approach to Catholic AI That Works Offline." The combination of zero-cost runtime, extractive (not generative) answers, and formal logic is a distinctive contribution that no one else is presenting.

---

## 6. Questions You Haven't Asked

### Data and Open Source Strategy

1. **Should NWP's CathNet data be contributed upstream?** The 25MB structured CCC database (1,514 concepts, 5,305 relationships, 5,937 embeddings, 55,742 Scripture citations, 26,855 document references) is more comprehensive than any open-source alternative. Publishing it as a standalone dataset on GitHub would benefit the entire Catholic open-source ecosystem and establish NWP as the authoritative source for machine-readable Catechism data.

2. **Should the Carmel dictionary API be published as a standalone microservice?** A REST API for 16th-century Spanish mystical vocabulary would be useful to digital humanities scholars beyond the Catholic AI space.

3. **Could NWP's transcription pipeline be offered as a service?** Other Catholic podcasts (Pints with Aquinas, Catholic Stuff You Should Know, The Thomistic Institute) might want the same dual-precision transcription + searchable archive. This could be a community contribution or even a modest revenue source.

### Institutional and Canonical

4. **Is the guild certification model legally viable?** Issuing "certificates" in theology and spirituality could raise questions about institutional authority. How does this relate to canonical norms about catechetical instruction? A bishop's nihil obstat or imprimatur on the course content would strengthen legitimacy.

5. **Is there a path to institutional adoption?** NWP's Prayer library is built for Mazenod College. Could the Faith Formation app + Logic curriculum be pitched to the Catholic Education Office of Melbourne (or equivalent) for wider adoption across Catholic schools? Notre Dame's ACE "Higher-Powered Learning" initiative is specifically looking for Catholic AI literacy materials.

### Technical Architecture

6. **Should CathNet target the Ephrem SLM instead of Claude for Phase 7B?** If Longbeard releases Ephrem in 2026, pre-computing the answer bank with a Catholic-native model could produce more theologically precise answers than a general-purpose LLM.

7. **Should NWP adopt the Magisterium API as a verification oracle?** For the guild certification system, using Magisterium's API to cross-check student answers against the broader magisterial corpus would add credibility. "Your answer was verified against 28,000+ magisterial documents."

8. **What happens when the CCC is updated?** Pope Leo XIV could issue a revised Catechism. Is the CathNet pipeline designed to be re-run on a new source text, or is it hardcoded to the current edition? The extractor scrapes vatican.va, so a re-run would pick up changes -- but the concept extraction and Prolog KB would need regeneration.

9. **Should the Prayer project's 8.4 GB theological library be indexed and searchable?** Currently it's a file system. Adding a search index (even a simple SQLite FTS5 over the text files) would transform it from a reference library into a research tool. This could eventually become a content pack for the Faith Formation app.

### Strategic

10. **Is there a role for NWP in the Vatican's AI translation initiative?** The Vatican is launching AI-powered real-time Mass translation at St. Peter's in 60 languages (spring 2026). NWP's transcription pipeline expertise (forced alignment, source text matching) could be relevant to this initiative.

---

## 7. Recommended Priorities

### Immediate (This Week)

| Priority | Action | Effort | Cost |
|----------|--------|--------|------|
| 1 | Initialize git for ~/prayer (biggest risk mitigation) | 30 min | $0 |
| 2 | Add Magisterium MCP server to Claude Code config | 5 min | $0 |
| 3 | Run CIYTools Stage 7 with API key | 1-2 hours | $5-15 |
| 4 | Reparse Carmel texts in LWT | 5 min | $0 |

### Short-Term (Next 2 Weeks)

| Priority | Action | Effort | Cost |
|----------|--------|--------|------|
| 5 | Run CathNet Phase 7B answer bank | 30 min + API | $12.50 |
| 6 | Deploy cathnet.nwpcode.org | 2-3 hours | $0 |
| 7 | Test F20 Android APK on physical device | 1 hour | $0 |
| 8 | Submit NWP components to awesome-catholic list | 30 min | $0 |
| 9 | Apply to SENT Ventures | 1 hour | TBD |

### Medium-Term (Next Month)

| Priority | Action | Effort | Cost |
|----------|--------|--------|------|
| 10 | Contact info@baif.ai about BAIF 2026 | 30 min | $0 |
| 11 | Publish CathNet data as open dataset on GitHub | 2 hours | $0 |
| 12 | Implement F20 content pack format (Phase 9) | 1-2 weeks | $0 |
| 13 | Explore CatholicOS ontology alignment | 1 week | $0 |
| 14 | Add liturgical calendar to Faith Formation app | 1 week | $0 |

### Longer-Term (Next Quarter)

| Priority | Action | Effort | Cost |
|----------|--------|--------|------|
| 15 | Prepare BAIF 2026 abstract | 1 day | $0 |
| 16 | Explore institutional adoption (Catholic Ed Office, Notre Dame ACE) | Ongoing | $0 |
| 17 | Evaluate Ephrem SLM when released | 1 week | TBD |
| 18 | Build searchable index over Prayer library (FTS5) | 1 week | $0 |
| 19 | Explore offering transcription pipeline to other Catholic podcasts | Ongoing | $0 |
| 20 | Investigate canonical considerations for guild certification | Ongoing | $0 |

---

## Appendix A: NWP Subproject Deep Dives

### A1. CathNet -- Built vs. Planned

| Phase | Description | Status | Output |
|-------|-------------|--------|--------|
| 1 | Data extraction & parsing | COMPLETE | catechism_structured.json (24.5 MB), 2,863 paragraphs |
| 2 | Database & schema | COMPLETE | cathnet.db (25.1 MB), FTS5 indexes |
| 3 | Concept extraction | COMPLETE | 1,514 concepts, 5,305 relationships |
| 4 | Embeddings & semantic search | COMPLETE | 5,937 sentence embeddings (all-MiniLM-L6-v2) |
| 5 | Concept map algorithm | COMPLETE | graph.json (200 nodes, 500 edges), Cytoscape.js |
| 6 | NLP keyword & triple indexes | PARTIAL | Framework built, output not fully generated |
| 7A | CCC-Net knowledge base | COMPLETE | cccnet.json (1,104 concepts), cccnet.pl (36,472 lines) |
| 7B | Pre-computed answer bank | FRAMEWORK | Code exists, not yet run (~$12.50 cost) |
| 7C | Inference & NLG | COMPLETE | nlp_service.py with 5-tier pipeline |
| 8 | Auto-summation & RAG | PROPOSED | ~$3/month with caching |
| 9 | Educational integration (LTI 1.3) | PROPOSED | Not started |
| 10 | Multi-document & extensions | PROPOSED | Not started |

**Drupal Module:** 12 routes, 9 templates, Cytoscape.js visualization, JSON API endpoints, custom database schema. Not yet deployed to production.

**Python Pipeline:** 15+ modules in `cathnet/src/`, orchestrated by `run_pipeline.py`. FastAPI NLP service at localhost:8019 with /health, /search, /ask endpoints. Total RAM: ~732 MB.

**Cost Summary:** $32.50 one-time (Phases 1-7A), $0 ongoing for core system.

### A2. Faith Formation App (F20) -- Architecture

**Database:** 10-table SQLite via Drift ORM

- `courses` (49) -> `sections` (315) -> `quizzes` (160) -> `questions` (732) -> `answers` (1,797)
- `userProgress` (per-course), `sectionVisits` (30+ sec threshold), `quizAttempts`, `quizResponses`, `appMeta`

**State Management:** 15+ Riverpod providers (streams for reactive updates, futures for one-shot queries)

**Content Pipeline:**
```
ss.nwpcode.org Moodle
    |
    v
moodle_live_export.py --all  (SSH + PHP CLI, batch export)
    |
    v
all_courses.json (1.2 MB)
    |
    v
build_seed_db.py
    |
    v
courses.db (804 KB, bundled as Flutter asset)
```

**Dart Codebase:** ~2,600 lines across 12 files. Largest: quiz_screen.dart (736 lines).

### A3. CIYTools Transcription Pipeline -- 10 Stages

| Stage | Script | Purpose | CIY Status | DIR Status |
|-------|--------|---------|------------|------------|
| 1 | fetch_ccc_source.py | Download CCC paragraphs | COMPLETE | N/A |
| 2 | build_episode_map.py | Parse RSS, map episodes to CCC | COMPLETE | N/A |
| 3 | download_episodes.py | Download MP3 audio | COMPLETE (6.9 GB) | COMPLETE (23 GB) |
| 4 | transcribe_batch.py --mode int8 | GPU transcription (~2 min/ep) | COMPLETE | COMPLETE |
| 5 | transcribe_batch.py --mode fp32 | CPU transcription (~25 min/ep) | COMPLETE | 9% (~March 18) |
| 6 | auto_resolve.py | Rule-based discrepancy resolution | COMPLETE (59.8%) | PENDING |
| 7 | claude_resolve.py | LLM discrepancy resolution | NOT USED (0 tokens) | PENDING |
| 8 | segment_and_correct.py | CCC source text alignment | COMPLETE (65.6%) | N/A |
| 9 | forced_align.py | CTC word-level timestamps | COMPLETE | PENDING |
| 10 | validate.py | Quality validation & reporting | COMPLETE | PENDING |

**Auto-resolve rules (Stage 6):** Hallucination loop detection, Latin corrections (27 entries), capitalisation rules (27 terms + 29 multi-word), content-aware model preference, filler word normalisation.

### A4. Carmel -- Working vs. Planned

| Feature | Status | Notes |
|---------|--------|-------|
| Docker infrastructure (LWT + API + MariaDB) | WORKING | 3 containers running |
| Text corpus import (364 texts) | WORKING | 235 Teresa + 129 John |
| Dictionary API (Flask + SQLite) | WORKING | Port 5000, 223+ entries |
| Wiktionary integration | WORKING | 295 definitions scraped |
| Covarrubias 1611 dictionary | WORKING | OCR parsed, 33 curated |
| Interlinear word linking | PARTIAL | Needs text reparsing |
| Era-aware display (Phase 3) | NOT STARTED | Requires LWT frontend mods |
| Parallel English (Phase 4) | NOT STARTED | DB schema + views needed |
| Context-aware selection (Phase 5) | NOT STARTED | High complexity UX |

### A5. Mass Times Module -- Data Flow

```
1. DISCOVERY (discovery.py)
   -> Google Places / Archdiocese / MassTimes.org
   -> Deduplicate & Geocode (Nominatim, 1 req/sec)
   -> Output: parishes.json, endpoints.json

2. TEMPLATE BUILDING (template_builder.py)
   -> Fetch parish websites/PDFs
   -> Identify mass times sections (CSS/regex/PDF coords)
   -> Extract baseline times
   -> Output: {parish_id}.json templates

3. EXTRACTION (extractor.py)
   -> Tier 1: Compare vs baseline (static, 100% confidence)
   -> Tier 2: Apply templates (CSS/regex/PDF, 85% confidence)
   -> Tier 3: LLM fallback (Claude Sonnet, capped $5/month, 10/day)
   -> Output: extraction results as JSON

4. DRUPAL SYNC (drupal_sync.py)
   -> JSON:API for parish CRUD
   -> drush php:eval for paragraph creation
   -> Geofield: POINT(lng lat) WKT format

5. PRESENTATION
   -> /map -> Leaflet/OpenStreetMap interactive map
   -> Parish nodes with mass_time paragraphs
   -> Haversine distance calculation
   -> Next upcoming mass per parish
```

### A6. NWP Infrastructure -- Key Capabilities

**CLI (`pl`):** 40+ commands for site management, backup/restore, deployment, testing, cloud provisioning, security.

**Deployment Pipeline:** DEV -> STG -> LIVE -> PROD (4-tier model)

**Recipe System:** `pl install <recipe> <site>` for Drupal, Moodle, Podcast (Castopod)

**Verification:** 553+ items, 99.5%+ machine pass rate, interactive TUI, badge generation

**Libraries:** 60+ bash libraries in `lib/` covering UI, databases, SSH, Linode, Cloudflare, backup, testing, frontend build tools

**Security:** Two-tier secrets (.secrets.yml for infrastructure, .secrets.data.yml for production data), UFW, fail2ban, security headers

**Active Deployments:** 6 production sites (AVC, CathNet, DIR, MT, SS, GitLab) on single $20/month Linode

---

## Appendix B: External Project Details

### B1. Magisterium AI / Longbeard Ecosystem

| Product | Description | Status |
|---------|-------------|--------|
| **Magisterium AI** | Answer engine, 28K+ documents, 50+ languages, 100K monthly users | Live |
| **Magisterium API** | OpenAI-compatible, $0.50-2.00/Mtok, 50K RPD | Live |
| **Magisterium MCP** | Model Context Protocol server for Claude Desktop | Live |
| **Vulgate AI** | Library digitization, neural search, machine translation | Active |
| **Alexandria Hub** | Robotic scanning in Rome, 2,500 pages/hour, 80K+ texts | Operational |
| **Ephrem** | Catholic SLM trained on full Catholic corpus | Coming 2026 |
| **Christendom** | Platform for Catholic content creators | Active |

**Digitization partnerships:** Salesian Pontifical University, Pontifical Gregorian University, Pontifical Oriental Institute (200K volumes).

**Criticism:** New Polity (Jan 2026) published "Delete Magisterium AI." Religion News Service noted mixing official documents with journal opinions. The Vatican has not officially approved it (a continuously changing LLM cannot receive an imprimatur).

### B2. Master Catechism by Tradivox

- Semantic search across 1,000 years of traditional catechisms at mastercatechism.com
- NOT a chatbot -- direct-query research tool
- AI correlates terms across loaded catechism documents using semantic similarity
- Source toggling by copyright date to show doctrinal consensus across centuries
- "Classic" vs "Contemporary" modes (Classic relies on Bishop Schneider's "Credo")
- 10 language modes
- Free (accepts donations)
- Endorsed by Bishop Athanasius Schneider

### B3. CatholicOS GitHub Organization

| Repository | Purpose | Tech | Status |
|-----------|---------|------|--------|
| homilia-ai | RAG Q&A for parishes | FastAPI, React, PostgreSQL, OpenSearch | Early-stage |
| ontologies-project | OWL ontologies for Catholic knowledge | OWL | Active |
| ontology-semantic-canon | Modeling foundational doctrine sources | Python | Active |
| ontokit-api | Collaborative ontology curation | FastAPI | Active |
| ontokit-web | Ontology frontend | Next.js | Active |
| liturgical-calendar-api | Liturgical calendar REST API | PHP | 2 stars |
| outwardsign | Sacrament management for parishes | TypeScript | Active |

Assessment: Real working projects but very early-stage. Ontologies work is most intellectually ambitious. Foundation governance docs suggest aspiration to become formal non-profit.

### B4. Catholic App Landscape Summary

| App | Users/Downloads | Pricing | Primary Mode |
|-----|----------------|---------|-------------|
| **Hallow** | 20M+ downloads | $9.99/month | Audio prayer/meditation |
| **Truthly** | 100K+ downloads | $4.99/month | AI chat + micro-learning |
| **Magisterium AI** | 100K monthly | Free (10/week) | Q&A answer engine |
| **Credo Chat** | Growing quickly | Free | Faith Q&A + daily tools |
| **Acutis AI** | Early phase | Subscription | Catholic-filtered general AI |
| **MagisAI** | New (Oct 2025) | Free basic | Apologetics (Fr. Spitzer) |
| **Grace** | Active | Subscription | Spiritual companion |
| **Jenova AI** | 127K+ users | Free + $20/month | Pastoral care + prayer |

### B5. Key Conferences and Events

| Event | Organizer | Location | Frequency |
|-------|-----------|----------|-----------|
| **Builders AI Forum** | Longbeard + Gregorian U. | Rome | Annual |
| **SENT Summit** | SENT Ventures | CUA, Washington DC | Annual |
| **Catholic Tech Week** | CatholicTech | Rome | Annual (2025 Jubilee) |
| **Wonder Conference** | Word on Fire | TBD | Annual |

### B6. Key Institutional Initiatives

| Initiative | Funding | Focus |
|-----------|---------|-------|
| **Notre Dame DELTA Network** | $50.8M (Lilly Endowment) | AI, Faith and Human Flourishing |
| **Carlo Acutis Center** (Benedictine College) | Institutional | Catholic AI Ethics |
| **Catholic University of America AI Programs** | Institutional | AI healthcare, robotics, ethical AI |
| **IFCU NHNAI Project** | Multi-university | AI and neuroscience ethics |

---

## Summary

**NWP is doing things nobody else is doing** -- formal logical reasoning over the Catechism, dual-precision transcription with source text alignment, offline-first faith formation with quiz assessment, and original-language mystical text study.

**The gap is visibility, not capability.** Joining SENT Ventures, presenting at BAIF, publishing data as open standards, and listing on awesome-catholic would connect NWP's work to the broader Catholic tech ecosystem where it can have maximum impact.

**Total cost of all recommended immediate improvements:** $17.50-27.50 and a few hours of work.

---

*This document was compiled March 12, 2026, based on deep-dive analysis of all NWP subprojects and comprehensive research into 75+ Catholic AI projects, open-source tools, and institutional initiatives.*
