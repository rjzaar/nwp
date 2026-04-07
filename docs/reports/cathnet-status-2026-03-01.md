# CathNet Project Status Report

**Date:** 2026-03-01
**Live Site:** https://ccc.nwpcode.org
**Author:** Rob Zaar + Claude Opus 4.6

---

## 1. Project Overview

CathNet is an interactive concept map and knowledge graph of the Catechism of the Catholic Church (CCC). It transforms the Catechism's 2,863 paragraphs into a structured, searchable, interconnected knowledge base with an interactive web interface.

**Origin:** Robert Zaar's 2005 MEd(Research) proposal at Australian Catholic University, "Automatically Concept Mapping the Catechism" (ACMC). The 2005 vision described macro/micro views of a concept map, sentence-level navigation, and auto-summation -- the ability to select any concept and receive an ordered summary of related passages. In 2026, LLMs and modern NLP make this fully achievable.

---

## 2. Architecture

```
cathnet/                           # Python data pipeline & NLP
  src/                             # Core pipeline modules (12 files)
  src/nlp/                         # NLP service modules (16 files)
  data/cathnet.db                  # SQLite database (25.1 MB)
  data/cccnet/                     # Knowledge base (cccnet.json, cccnet.pl)
  tests/                           # Test suite (15 files, 53 tests)
  venv/                            # Python 3.12 virtual environment

modules/cathnet/                   # Drupal 10/11 module
  src/Controller/                  # PHP controllers (2 files)
  templates/                       # Twig templates (9 files)
  css/                             # Stylesheets (8 files)
  js/                              # JavaScript (2 files)
  cathnet.install                  # Database schema
  cathnet.routing.yml              # 12 routes
```

**Technology stack:** Python 3.12 + FastAPI | Drupal 10/11 (PHP 8.3) | SQLite + FTS5 | Cytoscape.js | sentence-transformers | spaCy | Prolog (pure-Python fallback)

---

## 3. What's Working on ccc.nwpcode.org

### Fully Functional (Drupal Module)

| Page | URL | Description |
|------|-----|-------------|
| Landing | `/cathnet` (front page) | Stats: 1,514 concepts, 2,863 paragraphs |
| Concept Map | `/map` | Interactive Cytoscape.js graph, 200 nodes, 500 edges |
| Concept Detail | `/map/{id}` | Knowledge Graph (typed relations), paragraphs with concept highlighting |
| Browse | `/browse` | Hierarchical catechism: 4 parts, chapters, paragraphs |
| Search | `/search/catechism` | SQL keyword search with highlighted snippets |
| Paragraph | `/paragraph/{n}` | Full text, concept links, prev/next navigation |
| Help | `/help/cathnet` | 6 sections describing all features |
| Graph API | `/api/cathnet/graph` | Cytoscape.js JSON (200 nodes, 500 edges) |
| Concept API | `/api/cathnet/concept/{id}` | Concept + paragraphs + typed relations |
| Search API | `/api/cathnet/search?q=` | JSON concept + paragraph search |
| Import APIs | `/api/cathnet/import-*` | POST endpoints for pipeline data import |

**Copyright footer:** "Catechism of the Catholic Church (c) Libreria Editrice Vaticana" on all pages.

### Concept Detail Page Features

The concept detail page (`/map/{id}`) now shows a **Knowledge Graph** section that groups relationships by type, with color-coded cards:

- **Is a type of** (green) -- IS_A relationships
- **Part of** (orange) -- PART_OF relationships
- **Requires** (red) -- REQUIRES relationships
- **Effects** (teal) -- HAS_EFFECT relationships
- **Instituted by** (purple) -- INSTITUTED_BY relationships
- **Contrasts with** (pink) -- CONTRASTS_WITH relationships
- **Leads to** -- LEADS_TO relationships

Below the Knowledge Graph, generic co-occurrence "Related Concepts" are shown as clickable tags.

### NOT Running on the Server

The **NLP service** (FastAPI, port 8019) is NOT deployed on the live server. This means:

- Semantic search (embedding cosine similarity + BM25 + cross-encoder re-ranking)
- Extractive QA (`/ask` endpoint, 5-tier pipeline)
- Runtime Prolog inference
- Answer bank lookup
- Template NLG

**Why:** The Linode server has only **365 MB free RAM** (3.5 GB used of 3.8 GB). The NLP service needs ~732 MB minimum (bi-encoder 100 MB, cross-encoder 90 MB, QA model 475 MB, indexes ~50 MB).

---

## 4. Database Statistics

### cathnet.db (25.1 MB, SQLite)

| Table | Count |
|-------|-------|
| Paragraphs | 2,863 |
| Sentences (with embeddings) | 5,937 |
| Concepts | 1,514 |
| Relationships | 5,305 |
| Concept-paragraph links | 31,950 |

### Relationship Types

| Type | Count | Source |
|------|-------|--------|
| related | 4,134 | Co-occurrence (F18 Phase 3) |
| part_of | 266 | CCC-Net extraction |
| requires | 229 | CCC-Net extraction |
| is_a | 171 | CCC-Net extraction |
| contrasts_with | 148 | CCC-Net extraction |
| leads_to | 146 | CCC-Net extraction |
| has_effect | 126 | CCC-Net extraction |
| instituted_by | 67 | CCC-Net extraction |
| broader | 18 | CCC-Net extraction |

### Concept Types

| Type | Count |
|------|-------|
| theological_term | 564 |
| doctrine | 368 |
| glossary_term | 304 |
| liturgical_term | 68 |
| event | 51 |
| prayer | 42 |
| virtue | 28 |
| person | 24 |
| sacrament | 22 |
| vice | 19 |
| commandment | 19 |
| other | 5 |

### CCC-Net Knowledge Base (data/cccnet/)

| Artifact | Size | Contents |
|----------|------|----------|
| cccnet.json | 1,053 KB | 1,104 concepts, 1,778 relations, 119 frames, 669 rules |
| cccnet.pl | 1,438 KB | Prolog facts + meta-rules (transitivity, symmetry, inheritance) |
| extraction_cache/ | ~287 files | Per-batch extraction results |

---

## 5. Proposals and Implementation Status

### F18: CathNet -- Automatically Concept Mapping the Catechism (ACMC)

**File:** `docs/proposals/F18-cathnet-acmc.md`
**Status:** Phases 1-7 COMPLETE, Phases 8-10 PROPOSED

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Data Extraction & Structural Parsing | Complete |
| 2 | Database & Schema | Complete |
| 3 | Concept Extraction (Claude API) | Complete |
| 4 | Embeddings & Semantic Search | Complete |
| 5 | Concept Map Algorithm | Complete |
| 6 | Drupal Module & Visualization | Complete |
| 7 | Site Deployment (ccc.nwpcode.org) | Complete |
| 8 | Auto-Summation & RAG | Proposed (not started) |
| 9 | Educational Integration (LTI) | Proposed (not started) |
| 10 | Extensions & Multi-Document | Proposed (not started) |

**What was built:** Complete Catechism extraction pipeline, concept extraction via Claude API (~$15 one-time cost), sentence embeddings (all-MiniLM-L6-v2), interactive concept map (Cytoscape.js), Drupal module with browsing/search/paragraph views, deployed at ccc.nwpcode.org.

**Issues:**
- F18 originally proposed PostgreSQL + pgvector + Apache AGE; actual implementation uses SQLite (simpler, sufficient for current scale).
- The concept map shows 200 nodes / 500 edges (filtered for visualization). Full graph is larger but would be unreadable.
- Graph layout uses spring-force algorithm from NetworkX, not the original 2005 planar graph algorithm (which assumed a tree structure).

### F19: CathNet -- Offline NLP Search & Question Answering

**File:** `docs/proposals/F19-cathnet-nlp-qa.md`
**Status:** Phases 1-4 IMPLEMENTED (code exists), Phase 5 PARTIAL, Phase 6 NOT STARTED

| Phase | Description | Status | Notes |
|-------|-------------|--------|-------|
| 1 | Semantic Search + Cross-Encoder Re-Ranking | Code complete | FastAPI `/search` endpoint |
| 2 | Extractive QA | Code complete | FastAPI `/ask` endpoint, roberta-base-squad2 |
| 3 | Query Understanding & Expansion | Code complete | spaCy NER, WordNet, intent classification |
| 4 | Keyword & Relationship Indexes | Code complete | YAKE, KeyBERT, triple extraction |
| 5 | Drupal Integration & /ask Page | Partial | API exists, no Drupal `/ask` page yet |
| 6 | Conversational Follow-Up | Not started | Optional phase |

**What was built:** Complete FastAPI NLP service (`nlp_service.py`) with semantic search, BM25, RRF fusion, cross-encoder re-ranking, extractive QA, query understanding, entity extraction, and query expansion. 53 tests passing.

**Issues:**
- **Not deployed to production.** Server has insufficient RAM (365 MB free, needs ~732 MB).
- **No Drupal `/ask` page.** The NLP service has `/search` and `/ask` endpoints but these are not wired into the Drupal frontend. The Drupal search page uses SQL `LIKE` queries only.
- **Intent classification is rule-based.** Some intents misclassify (e.g., "What does Baptism require?" classifies as "topical" instead of "requirements"). Falls through to extractive QA which handles it anyway.
- **Model download required.** First run downloads ~660 MB of models (sentence-transformers, cross-encoder, spaCy, QA model).

### F19 Amendment A1: Multi-Paragraph Synthesis Without Runtime LLM

**File:** `docs/proposals/F19-amendment-A1-synthesis.md`
**Status:** Phase 7A COMPLETE, Phases 7B-7C PARTIAL

| Phase | Description | Status | Notes |
|-------|-------------|--------|-------|
| 7A | CCC-Net Construction | Complete | 1,104 concepts, 1,778 relations, 119 frames, 669 rules extracted |
| 7B | Pre-Computed Answer Bank | Not started | Requires Claude API key (~$12.50 Batch API cost) |
| 7C | Inference & NLG Integration | Partial | Prolog engine works (Python fallback), NLG templates exist |

**What was built:**
- CCC-Net knowledge base extracted from all 2,863 paragraphs using 10 parallel Claude Code agents (no API key needed -- done within Claude Code session).
- Pure-Python Prolog inference engine (`prolog_engine.py`) that parses `.pl` facts and does transitive closure, symmetric lookup, and multi-hop inference. Works without SWI-Prolog.
- `db_to_prolog.py` generates Prolog KB directly from the database.
- `glossary_relations.py` extracts 39 typed relationships from glossary definitions.
- The 5-tier `/ask` pipeline in `nlp_service.py` is fully wired: answer bank -> Prolog inference -> template NLG -> extractive QA -> LexRank summary.

**Issues:**
- **Answer bank (Phase 7B) not built.** Requires an Anthropic API key with credits (~$12.50 via Batch API with Haiku). The CCC-Net itself was built without an API key (extracted via Claude Code agents), but the answer bank generation script (`answer_bank_builder.py`) calls the Anthropic Messages API.
- **SWI-Prolog not installed on server.** The pure-Python fallback works but is slower and limited to the inference rules coded in `_PythonKB`. Can't do arbitrary Prolog queries.
- **NLG templates are basic.** `nlg_templates.py` generates simple sentences from triples ("X is a type of Y. X requires Z.") but lacks the rhetorical sophistication described in the proposal.
- **CCC-Net extraction quality varies.** Some agent-extracted batches have overly broad relations (e.g., linking concepts that co-occur but aren't semantically related). The 1,778 relations include some noise.

---

## 6. Deployment Details

### Server

- **Host:** Linode (97.107.137.88)
- **SSH user:** `gitlab` (with key `/home/rob/.ssh/gitlab_linode`)
- **Drupal root:** `/var/www/ccc/web/`
- **Module path:** `/var/www/ccc/web/modules/custom/cathnet/`
- **Drush:** `/var/www/ccc/vendor/bin/drush`
- **RAM:** 3.8 GB total, ~365 MB free
- **Disk:** 79 GB total, 60 GB free

### Deployment Process

```bash
# 1. Sync module files
ssh gitlab@97.107.137.88 "sudo chown -R gitlab:www-data /var/www/ccc/web/modules/custom/cathnet"
rsync -av --delete -e "ssh -i ~/.ssh/gitlab_linode" modules/cathnet/ gitlab@97.107.137.88:/var/www/ccc/web/modules/custom/cathnet/
ssh gitlab@97.107.137.88 "sudo chown -R www-data:www-data /var/www/ccc/web/modules/custom/cathnet"

# 2. Clear cache
ssh gitlab@97.107.137.88 "sudo -u www-data bash -c 'cd /var/www/ccc && vendor/bin/drush cr'"

# 3. Import data (copy JSON then run drush php-eval)
scp -i ~/.ssh/gitlab_linode data/drupal_export/concepts.json gitlab@97.107.137.88:/tmp/
ssh gitlab@97.107.137.88 "cd /var/www/ccc && vendor/bin/drush php-eval '...import script...'"
```

### Data Import

The pipeline exports three JSON files to `data/drupal_export/`:
- `concepts.json` -- concepts, concept_paragraphs, relationships (3.2 MB)
- `graph.json` -- Cytoscape.js graph data (172 KB)
- `paragraphs.json` -- full paragraph text and structure

These are imported to Drupal via the `/api/cathnet/import-*` POST endpoints or via `drush php-eval`.

---

## 7. What Could Be Done Next

### Priority 1: Deploy NLP Service (requires server upgrade)

Upgrade the Linode from 4 GB to 8 GB RAM (~$12/month increase), then:

1. Copy `cathnet/` directory to server
2. Create Python venv, install `requirements-nlp.txt`
3. Download models (`python -m spacy download en_core_web_sm`, etc.)
4. Run `uvicorn src.nlp_service:app --host 127.0.0.1 --port 8019`
5. Configure systemd service for auto-start
6. Add Drupal integration: proxy `/ask` to the NLP service, or add an `/ask` page that calls the FastAPI backend via JavaScript

**Alternative:** Deploy a "lean mode" NLP service without the QA model (saves 475 MB), relying on Prolog inference + retrieval only. Needs ~150 MB -- might fit in current RAM.

### Priority 2: Build the Answer Bank (Phase 7B)

Requires an Anthropic API key with ~$12.50 in credits:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
cd cathnet
./venv/bin/python3 -m src.nlp.answer_bank_builder
```

This would generate pre-computed answers for ~400 topics x 3-5 questions = 1,200-2,000 Q&A pairs with FAISS index for instant lookup.

### Priority 3: Drupal `/ask` Page

Create a new Drupal route `/ask` with a question input and answer display. Options:
- **JavaScript-only:** Fetch from FastAPI service on port 8019 (requires NLP service running)
- **Hybrid:** Simple questions answered by Drupal PHP (SQL search + typed relationship display), complex questions forwarded to NLP service
- **Static:** Pre-compute answers and store in Drupal, no runtime NLP needed

### Priority 4: Improve the Concept Map

- Add edge type visualization (color-code edges by relationship type)
- Add cluster labels
- Add zoom-to-concept from search
- Add "explore neighborhood" (expand graph around selected concept)

### Priority 5: Educational Integration (F18 Phase 9)

- LTI integration for embedding in LMS (Moodle, Canvas)
- Quiz generation from concept relationships
- Learning path recommendations based on concept dependencies

---

## 8. Known Issues and Limitations

### Data Quality
1. **Co-occurrence relationships are noisy.** 4,134 "related" edges from word co-occurrence include many weak or spurious connections.
2. **CCC-Net extraction has variable quality.** Some agent-extracted batches produced overly broad or generic relations. Quality could be improved with a validation pass.
3. **Glossary coverage is partial.** The glossary from seraphim.my has 397 terms but some definitions are cross-references only ("See X").
4. **Paragraph numbering gaps.** The CCC has 2,865 numbered paragraphs but some numbers are skipped (footnotes, headers). Our DB has 2,863.

### Infrastructure
5. **Server RAM constraint.** 3.8 GB Linode can't run the NLP service alongside Drupal + MySQL + Apache.
6. **No HTTPS certificate management.** Relies on existing Linode/NWP infrastructure.
7. **No backup strategy for Drupal data.** The source of truth is `cathnet.db`; Drupal data can be re-imported.

### NLP Service
8. **Not deployed.** All NLP features are development-only.
9. **Intent classifier is rule-based.** Misclassifies some query types. Could be improved with a small trained classifier.
10. **No Drupal `/ask` page.** The NLP `/ask` endpoint exists but no Drupal frontend for it.
11. **Anthropic API key not configured.** Needed for answer bank builder and CCC-Net builder (if re-running with the API script).
12. **SWI-Prolog not installed.** Pure-Python fallback works but is limited.

### UI/UX
13. **Search is SQL-only on live site.** No semantic ranking, no cross-encoder re-ranking.
14. **Concept map is static.** 200 nodes pre-computed; no dynamic expansion.
15. **No mobile optimization.** CSS is basic; concept map is desktop-oriented.

---

## 9. File Reference

### Key Python Files

| File | Purpose |
|------|---------|
| `cathnet/src/run_pipeline.py` | Main orchestrator: `--phase 1-7`, `--serve`, `--status` |
| `cathnet/src/nlp_service.py` | FastAPI app: `/health`, `/search`, `/ask` |
| `cathnet/src/database.py` | SQLite schema (25 tables) and DB constants |
| `cathnet/src/extractor.py` | HTML parsing of raw catechism |
| `cathnet/src/parser.py` | Tokenization and co-occurrence computation |
| `cathnet/src/concept_extractor.py` | Claude API concept extraction |
| `cathnet/src/embeddings.py` | Sentence embedding generation (all-MiniLM-L6-v2) |
| `cathnet/src/graph_builder.py` | Concept graph + community detection + Cytoscape export |
| `cathnet/src/glossary_extractor.py` | CCC Glossary HTML scraping |
| `cathnet/src/glossary_importer.py` | Glossary -> database import |
| `cathnet/src/glossary_relations.py` | Pattern-based typed relationship extraction |
| `cathnet/src/drupal_sync.py` | Drupal API sync |
| `cathnet/src/nlp/retrieval.py` | EmbeddingIndex, BM25Index, RRF fusion, cross-encoder |
| `cathnet/src/nlp/qa.py` | ExtractiveQA (roberta-base-squad2) |
| `cathnet/src/nlp/query_understanding.py` | Intent classification, entity extraction, query expansion |
| `cathnet/src/nlp/prolog_engine.py` | PrologEngine with pure-Python _PythonKB fallback |
| `cathnet/src/nlp/cccnet_builder.py` | Claude API CCC-Net extraction (batch processing) |
| `cathnet/src/nlp/db_to_prolog.py` | Generate cccnet.pl from database |
| `cathnet/src/nlp/nlg_templates.py` | Template-based NLG from triples |
| `cathnet/src/nlp/answer_bank_builder.py` | Pre-computed answer bank (Claude Batch API) |
| `cathnet/src/nlp/answer_bank_lookup.py` | Runtime answer bank query |
| `cathnet/src/nlp/extractive_summarizer.py` | LexRank summarization fallback |
| `cathnet/src/nlp/keyword_extractor.py` | YAKE + KeyBERT keyword extraction |
| `cathnet/src/nlp/triple_extractor.py` | Semantic triple extraction |
| `cathnet/src/nlp/models.py` | Pydantic request/response models |

### Key Drupal Files

| File | Purpose |
|------|---------|
| `modules/cathnet/cathnet.module` | hook_theme (9 templates), hook_preprocess (nav, copyright) |
| `modules/cathnet/cathnet.install` | Schema: cathnet_paragraphs, _concepts, _relationships, _concept_paragraphs, _graph_data |
| `modules/cathnet/cathnet.routing.yml` | 12 routes (8 pages + 4 APIs) |
| `modules/cathnet/src/Controller/CathnetController.php` | Page controllers: map, concept, browse, paragraph, landing, search, help, admin |
| `modules/cathnet/src/Controller/CathnetApiController.php` | API: graph, conceptDetail, searchApi, importGraph, importConcepts, importParagraphs |

### Proposal Documents

| File | Description |
|------|-------------|
| `docs/proposals/F18-cathnet-acmc.md` | Core ACMC proposal (10 phases) |
| `docs/proposals/F19-cathnet-nlp-qa.md` | NLP Search & QA proposal (6 phases) |
| `docs/proposals/F19-amendment-A1-synthesis.md` | Multi-paragraph synthesis amendment (phases 7A/7B/7C) |

---

## 10. How to Pick This Up

### Quick Start (Development)

```bash
cd ~/nwp/cathnet
source venv/bin/activate

# Check current state
./venv/bin/python3 -m src.run_pipeline --status

# Run tests (53 tests, ~5 min)
./venv/bin/pytest tests/ -v

# Test Prolog engine
./venv/bin/python3 -c "
from src.nlp.prolog_engine import PrologEngine
p = PrologEngine('data/cccnet/cccnet.pl')
print(p.can_answer('baptism', 'definitional'))
print(p.can_answer('eucharist', 'relational'))
"

# Start NLP service locally
./venv/bin/uvicorn src.nlp_service:app --host 127.0.0.1 --port 8019

# Test NLP endpoints
curl -X POST http://localhost:8019/search -H 'Content-Type: application/json' -d '{"query":"What is Baptism?"}'
curl -X POST http://localhost:8019/ask -H 'Content-Type: application/json' -d '{"query":"What is required for Baptism?"}'
```

### Deploy Module Updates

```bash
# Sync module to live
ssh gitlab@97.107.137.88 "sudo chown -R gitlab:www-data /var/www/ccc/web/modules/custom/cathnet"
rsync -av --delete -e "ssh -i ~/.ssh/gitlab_linode" ~/nwp/modules/cathnet/ gitlab@97.107.137.88:/var/www/ccc/web/modules/custom/cathnet/
ssh gitlab@97.107.137.88 "sudo chown -R www-data:www-data /var/www/ccc/web/modules/custom/cathnet"
ssh gitlab@97.107.137.88 "sudo -u www-data bash -c 'cd /var/www/ccc && vendor/bin/drush cr'"
```

### Re-import Data

```bash
# Export from pipeline DB
cd ~/nwp/cathnet
./venv/bin/python3 -c "
import json, sqlite3
conn = sqlite3.connect('data/cathnet.db')
# ... (export concepts, links, relationships to JSON)
"

# Copy and import to live
scp -i ~/.ssh/gitlab_linode data/drupal_export/concepts.json gitlab@97.107.137.88:/tmp/
ssh gitlab@97.107.137.88 "cd /var/www/ccc && vendor/bin/drush php-eval '...'"
```

### Rebuild CCC-Net

The CCC-Net was built by 10 parallel Claude Code agents processing all 287 batches. To rebuild:

```bash
# Option A: Re-run agents in Claude Code (free, uses subscription)
# Ask Claude Code to process batches from data/cccnet/batches.json

# Option B: Use API directly (requires key, ~$5)
export ANTHROPIC_API_KEY=sk-ant-...
./venv/bin/python3 -c "from src.nlp.cccnet_builder import build_cccnet; build_cccnet('data/cathnet.db')"

# After either option, regenerate Prolog KB
./venv/bin/python3 -c "from src.nlp.db_to_prolog import generate_prolog_kb; generate_prolog_kb()"
```
