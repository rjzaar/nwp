# F19 + Amendment A1: Phases 1-7 Implementation Plan

## Context

CathNet F18 (Phases 1-5) is complete: 2,863 paragraphs extracted, 5,937 sentences with embeddings, 300 concepts, 4,134 relationships, concept map graph — all in `cathnet/data/cathnet.db`. The Drupal module at `modules/cathnet/` provides `/map`, `/browse`, `/search`, `/paragraph` pages.

This plan implements the 7 phases from the F19 + Amendment A1 updated phase summary (Section 10 of `docs/proposals/F19-amendment-A1-synthesis.md`): **1 → 2 → 3 → 4 → 7A → 7B → 7C**. These add NLP search, extractive QA, query understanding, a formal knowledge base (CCC-Net), pre-computed answer bank, Prolog inference, template NLG, and LexRank summarization — all with $0 ongoing cost.

---

## Phase 1: Semantic Search & Cross-Encoder Re-Ranking

**Create `cathnet/src/nlp_service.py`** — FastAPI app (the central service all phases build on):
- Load bi-encoder (`all-MiniLM-L6-v2`) and cross-encoder (`cross-encoder/ms-marco-MiniLM-L-6-v2`) at startup
- Load all 5,937 sentence embeddings from `cathnet.db` into a contiguous numpy matrix (~9MB) for fast matmul search (replaces the per-row iteration in `embeddings.py`)
- Build BM25 index from paragraph texts using `rank_bm25.BM25Okapi`
- `POST /search` endpoint: encode query → cosine similarity top-50 → BM25 top-50 → RRF merge to top-20 → cross-encoder re-rank → return top-5
- `GET /health` endpoint

**Create `cathnet/requirements-nlp.txt`** — All NLP pip dependencies (phases 1-7C)

**Create `cathnet/nlp_service.sh`** — Startup script (downloads models on first run, starts uvicorn on 127.0.0.1:8019)

**Modify `cathnet/src/run_pipeline.py`** — Add `--serve` flag to start the FastAPI service

**New deps:** `fastapi`, `uvicorn`, `rank-bm25`

---

## Phase 2: Extractive QA

**Modify `cathnet/src/nlp_service.py`** — Add:
- Load `deepset/roberta-base-squad2` via `transformers.pipeline("question-answering")` at startup
- `POST /ask` endpoint: run Phase 1 retrieval → extractive QA on top-5 passages → confidence thresholding (>0.5 direct, 0.2-0.5 possible, <0.2 no answer) → return answer span + source paragraph + related concepts + cross-references

**No new deps** — `transformers` already installed (5.2.0)

---

## Phase 3: Query Understanding & Expansion

**Create `cathnet/src/query_understanding.py`**:
- `classify_intent(query)` — regex-based: definitional, factual, relational, scriptural, comparative, effects, requirements, topical
- `extract_entities(query, nlp)` — spaCy `en_core_web_sm` + EntityRuler seeded from 300 concepts in `cathnet.db`
- `expand_query(query, entities, conn, model)` — WordNet synonyms + concept graph co-occurrence neighbors; weighted embedding: 0.7×original + 0.3×expansion
- `SectionClassifier` — scikit-learn TF-IDF + LogisticRegression trained on paragraph→part mapping, saved to `cathnet/data/nlp/section_classifier.pkl`

**Modify `cathnet/src/nlp_service.py`** — Integrate query understanding before retrieval in `/search` and `/ask`

**Modify `cathnet/src/run_pipeline.py`** — Add `phase6_nlp_indexes()` to train classifier, build entity patterns, download WordNet

**New data:** `cathnet/data/nlp/section_classifier.pkl`, `entity_patterns.jsonl`, `concept_synonyms.json`

**New deps:** `spacy`, `nltk` + downloads (`en_core_web_sm`, `wordnet`, `omw-1.4`)

---

## Phase 4: Keyword & Relationship Indexes

**Create `cathnet/src/keyword_extractor.py`**:
- YAKE: top-10 keywords per paragraph
- KeyBERT: top-5 semantic keywords per paragraph (reuses bi-encoder model)
- Output: `cathnet/data/nlp/keywords.json`

**Create `cathnet/src/triple_extractor.py`**:
- spaCy dependency parsing with patterns for IS_A, REQUIRES, HAS_EFFECT, PART_OF
- Structured index by subject for direct lookup
- Output: `cathnet/data/nlp/triples.json`, `structured_index.json`

**Modify `cathnet/src/run_pipeline.py`** — Add keyword + triple extraction to `phase6_nlp_indexes()`

**Modify `cathnet/src/nlp_service.py`** — Load structured index at startup; for effects/requirements intents, check structured index first

**New deps:** `yake`, `keybert`

---

## Phase 7A: CCC-Net Construction (Build-Time, ~$5 API Cost)

**Create `cathnet/src/cccnet_builder.py`** — Claude-powered extraction:
- Process 2,863 paragraphs in section-aware batches of 10
- Extract: concepts (with aliases, definitions), typed relations (IS_A, PART_OF, REQUIRES, EFFECTS, INSTITUTED_BY, PREFIGURED_BY, LEADS_TO, CONTRASTS_WITH, DEPENDS_ON, ELABORATES), semantic frames, inference rules
- Follow `concept_extractor.py` caching pattern (JSON files in `cathnet/data/cccnet/extraction_cache/`)
- Two-pass: Haiku bulk (~$3) + Sonnet verification on ambiguous items (~$2)
- Cross-validate against existing 300 F18 concepts
- Output: `cathnet/data/cccnet/cccnet.json`

**Create `cathnet/src/cccnet_to_prolog.py`** — JSON → Prolog:
- Generate facts: `concept/2`, `alias/2`, `definition/2`, `relation/4`, `frame_role/4`
- Generate inference rules from extracted rules
- Add meta-rules: IS_A transitivity, REQUIRES inheritance, CONTRASTS_WITH symmetry
- Add contradiction detection rules
- Validate: subprocess `swipl -g "consult('cccnet.pl'), halt"`
- Output: `cathnet/data/cccnet/cccnet.pl`

**Create `cathnet/src/cccnet_db.py`** — CCC-Net SQLite index:
- Tables: concepts, aliases, relations, frames, rules
- Concept embeddings for query-time matching
- Output: `cathnet/data/cccnet/cccnet.db`

**Modify `cathnet/src/run_pipeline.py`** — Add `--phase 7a`

---

## Phase 7B: Pre-Computed Answer Bank (Build-Time, ~$12.50 API Cost)

**Create `cathnet/src/answer_bank_builder.py`**:
- Build topic inventory from CCC-Net concepts (~400 topics)
- Generate 3-5 canonical questions per topic (~1,600 total): definitional, explanatory, relational, effects, requirements
- Use Claude Batch API (Haiku, 50% discount) with relevant CCC paragraphs as context
- Sonnet for top-50 complex topics (~200 questions)
- Compute question embeddings, build FAISS index
- Output: `cathnet/data/answer_bank/answers.db` + `question_embeddings.faiss`

**Create `cathnet/src/answer_bank_lookup.py`**:
- `find_answer(query, model, threshold=0.75)` — FAISS cosine similarity match → return pre-computed answer or None

**Modify `cathnet/src/run_pipeline.py`** — Add `--phase 7b`

**New deps:** `faiss-cpu`

---

## Phase 7C: Inference & NLG Integration

**Create `cathnet/src/prolog_engine.py`** — PySwip wrapper:
- Load `cccnet.pl` at startup
- `query_requirements(entity)`, `query_effects(entity)`, `query_reasoning(entities, intent)`
- Justification chain formatting
- Graceful degradation: if SWI-Prolog not installed, `PROLOG_AVAILABLE = False`

**Create `cathnet/src/nlg_templates.py`** — Template-based NLG:
- Load CCC-Net triples for a concept → assemble multi-sentence paragraph
- Templates: IS_A, PART_OF, REQUIRES, EFFECTS, INSTITUTED_BY + citations
- List aggregation: "X, Y, and Z"

**Create `cathnet/src/extractive_summarizer.py`** — LexRank fallback:
- Build sentence similarity graph from embeddings
- PageRank for centrality
- Select top-5 sentences ordered by CCC paragraph number

**Modify `cathnet/src/nlp_service.py`** — Wire the full answer pipeline in `/ask`:
1. Check answer bank → if hit, return (source: "pre-computed")
2. Check Prolog → if answerable by logic, return (source: "inferred")
3. Try template NLG → if sufficient triples, return (source: "structured")
4. Run retrieval + extractive QA (Phases 1-2)
5. Fall back to LexRank extractive summary (source: "extractive")
6. Tag every response with its source method

**System dep:** `apt-get install swi-prolog` (~20MB)

**New deps:** `pyswip`, `sumy`

---

## Complete New File Inventory

### Python Modules (`cathnet/src/`)
| File | Phase | Lines (est.) |
|---|---|---|
| `nlp_service.py` | 1-7C | ~400 |
| `query_understanding.py` | 3 | ~200 |
| `keyword_extractor.py` | 4 | ~100 |
| `triple_extractor.py` | 4 | ~150 |
| `cccnet_builder.py` | 7A | ~300 |
| `cccnet_to_prolog.py` | 7A | ~200 |
| `cccnet_db.py` | 7A | ~150 |
| `answer_bank_builder.py` | 7B | ~250 |
| `answer_bank_lookup.py` | 7B | ~80 |
| `prolog_engine.py` | 7C | ~150 |
| `nlg_templates.py` | 7C | ~120 |
| `extractive_summarizer.py` | 7C | ~80 |

### Config/Deploy
| File | Purpose |
|---|---|
| `cathnet/requirements-nlp.txt` | All NLP pip deps |
| `cathnet/nlp_service.sh` | Startup script |

### Tests (`cathnet/tests/`)
| File | Covers |
|---|---|
| `test_nlp_service.py` | Phases 1-2 |
| `test_query_understanding.py` | Phase 3 |
| `test_nlp_indexes.py` | Phase 4 |
| `test_cccnet.py` | Phase 7A |
| `test_answer_bank.py` | Phase 7B |
| `test_prolog_engine.py` | Phase 7C |
| `test_nlg.py` | Phase 7C |
| `test_answer_pipeline.py` | Phase 7C (integration) |

### Modified Files
| File | Changes |
|---|---|
| `cathnet/src/run_pipeline.py` | Add phases 6, 7a, 7b, 7c, --serve |

---

## Dependencies Summary

```
# requirements-nlp.txt
fastapi>=0.100.0
uvicorn[standard]>=0.23.0
rank-bm25>=0.2.2
spacy>=3.6.0
nltk>=3.8.0
yake>=0.4.8
keybert>=0.7.0
faiss-cpu>=1.7.4
pyswip>=0.2.11
sumy>=0.11.0
```

System: `apt-get install swi-prolog`
Downloads: `python -m spacy download en_core_web_sm`, NLTK wordnet

Already installed: `sentence-transformers`, `transformers`, `torch`, `scikit-learn`, `numpy`, `anthropic`

---

## RAM Budget: ~732MB

| Component | RAM |
|---|---|
| Bi-encoder + embeddings matrix | 89MB |
| Cross-encoder | 80MB |
| roberta-base-squad2 | 475MB |
| spaCy + EntityRuler | 50MB |
| CCC-Net + answer bank (SQLite) | 20MB |
| BM25 + indexes + Prolog | 18MB |
| **Total** | **~732MB** |

---

## Verification

After all phases complete:
1. `python -m cathnet.src.run_pipeline --status` shows all phases complete
2. `python -m cathnet.src.run_pipeline --serve` starts FastAPI on :8019
3. `curl localhost:8019/health` returns model info
4. `curl -X POST localhost:8019/search -d '{"query":"What is Baptism?"}'` returns ranked passages with Baptism content at top
5. `curl -X POST localhost:8019/ask -d '{"query":"What is required for Baptism?"}'` returns answer with source tagging
6. `cd cathnet && python -m pytest tests/ -v` passes all tests

---

## Key Design Decisions

1. **CCC-Net is separate from F18 data** — Lives in `cathnet/data/cccnet/`, never modifies `cathnet.db`
2. **Prolog is optional** — System works without SWI-Prolog (just skips inference step)
3. **QA model loaded at startup** — If RAM is tight, can be deferred to on-demand loading
4. **BERTopic skipped** — CCC-Net concepts are sufficient as topic inventory; avoids heavy UMAP/HDBSCAN deps
5. **Follow existing patterns** — Caching, API key handling, database access all follow `concept_extractor.py` conventions

---

## Existing Code Patterns to Follow

- **Database**: `cathnet/src/database.py` — `DB_PATH`, `init_db()`, SQLite with WAL mode, foreign keys
- **Embeddings**: `cathnet/src/embeddings.py` — `_pack_embedding()`, `_unpack_embedding()`, `EMBEDDING_MODEL = "all-MiniLM-L6-v2"`, `EMBEDDING_DIM = 384`
- **API extraction**: `cathnet/src/concept_extractor.py` — `get_api_key()`, batch caching to JSON files, rate limiting, concept deduplication across batches
- **Pipeline CLI**: `cathnet/src/run_pipeline.py` — argparse with `--phase N`, logging, status command
- **Models**: `cathnet/src/models.py` — dataclasses for Concept, Relationship, etc.; enums for ConceptType, RelationshipType
