# CathNet: Prolog + RAG Architecture

**Last Updated:** 2026-03-16
**Related Proposals:** F18 (CathNet ACMC), F19 (CathNet NLP QA)
**Knowledge Base:** `cathnet/data/cccnet/cccnet.pl`

---

## 1. What is RAG?

RAG (Retrieval-Augmented Generation) is a technique that enhances LLM responses by grounding them in external data retrieved at query time, rather than relying solely on what the model learned during training.

### How RAG Works

1. **Indexing (offline)** — Documents are split into chunks, converted to vector embeddings, and stored in a vector database.
2. **Retrieval (at query time)** — The user's query is embedded into the same vector space, and the most semantically similar chunks are fetched via a nearest-neighbour search.
3. **Augmented Generation** — The retrieved chunks are injected into the LLM's prompt as context, and the model generates a response grounded in that material.

```
User Query
    |
[Embed query] --> [Vector search] --> [Top-K relevant chunks]
    |
[Prompt = system instructions + retrieved chunks + user query]
    |
[LLM generates grounded response]
```

### Why RAG Matters

- **Reduces hallucination** — The model answers from actual documents, not just parametric memory.
- **Keeps knowledge current** — Update the document store without retraining the model.
- **Domain-specific answers** — Works with private/proprietary data the model was never trained on.
- **Cheaper than fine-tuning** — No GPU-intensive training required to add new knowledge.

### Limitations

- **Retrieval quality is the bottleneck** — If the right chunks aren't found, the answer will be wrong or incomplete.
- **Chunk size trade-offs** — Too small loses context, too large dilutes relevance.
- **No logical reasoning** — Pure RAG cannot chain inferences across multiple documents.

---

## 2. The CathNet Prolog Knowledge Base

The file `cathnet/data/cccnet/cccnet.pl` is a 36,000-line Prolog knowledge base auto-generated from `cathnet.db`. It contains:

| Fact type | Count | Description |
|-----------|-------|-------------|
| `concept/3` | 1,514 | Concepts with labels and types (sacrament, virtue, vice, doctrine, event, person, etc.) |
| `relation/4` | 1,671 | Typed relationships between concepts with confidence weights |
| `glossary_def/2` | 1,278 | CCC glossary definitions |
| `paragraph_link/2` | 31,950 | Links from concepts to CCC paragraph numbers (sections 1-2865) |

### Fact Structures

```prolog
% concept(Id, Label, Type)
concept('baptism', 'baptism', 'sacrament').
concept('charity', 'charity', 'virtue').
concept('acedia', 'acedia', 'vice').
concept('apostolic_succession', 'apostolic_succession', 'glossary_term').

% relation(Subject, Object, RelationType, Confidence)
relation('actual_grace', 'grace', 'is_a', 0.8).
relation('almsgiving', 'works_of_mercy', 'part_of', 0.8).
relation('anamnesis', 'holy_spirit', 'requires', 0.8).
relation('acedia', 'charity', 'contrasts_with', 0.8).
relation('abraham', 'chosen_people', 'leads_to', 0.8).

% glossary_def(ConceptId, DefinitionText)
glossary_def('baptism', 'The first of the seven sacraments...').

% paragraph_link(ConceptId, ParagraphNumber)
paragraph_link('baptism', 1213).
paragraph_link('baptism', 1214).
```

### Relationship Types

| Type | Meaning | Example |
|------|---------|---------|
| `is_a` | Taxonomic / definitional | actual_grace `is_a` grace |
| `part_of` | Compositional | almsgiving `part_of` works_of_mercy |
| `requires` | Prerequisite | anamnesis `requires` holy_spirit |
| `contrasts_with` | Opposition / tension | acedia `contrasts_with` charity |
| `leads_to` | Causal / historical | abraham `leads_to` chosen_people |

### Concept Types

glossary_term, theological_term, sacrament, virtue, vice, doctrine, event, person, prayer, liturgical_term, other

---

## 3. Prolog vs RAG: Complementary Strengths

Prolog and RAG serve different but complementary purposes in CathNet.

### Prolog = Structured Logical Reasoning

Prolog excels at **exact, deterministic inference over known relationships**. Queries produce traceable, explainable results.

```prolog
% What concepts does Baptism require?
?- relation(X, 'baptism', requires, _).

% What is part of the Eucharist?
?- relation(X, 'eucharist', part_of, _).

% Find all paragraphs about a concept and its related concepts
?- relation('baptism', Related, _, _), paragraph_link(Related, Para).

% Multi-hop: What does Baptism require, and what are those things part of?
?- relation(X, 'baptism', requires, _), relation(X, Y, part_of, _).
```

**Strengths:** Exact answers, explainable paths, multi-hop reasoning, no hallucination.
**Weaknesses:** Cannot handle fuzzy natural language, requires structured data.

### RAG = Fuzzy Semantic Search + Natural Language

RAG handles what Prolog cannot:

- "What does the Church teach about suffering?" (no exact concept match needed)
- Natural language questions that don't map neatly to predicates
- Generating narrative summaries from retrieved passages

**Strengths:** Natural language input, semantic similarity, handles unseen queries.
**Weaknesses:** No logical chaining, retrieval quality is the ceiling, can hallucinate.

### Summary

| Capability | Prolog | RAG |
|-----------|--------|-----|
| Exact relationship traversal | Yes | No |
| Multi-hop inference | Yes | Limited |
| Explainable reasoning paths | Yes | No |
| Natural language queries | No | Yes |
| Fuzzy/semantic matching | No | Yes |
| Narrative generation | No | Yes |
| Hallucination risk | None | Present |

---

## 4. The Combined Architecture

The ideal CathNet system uses **Prolog as a structured index that feeds into RAG retrieval**.

### Query Flow

```
User asks: "How are Baptism and the Eucharist connected?"
    |
    v
1. Prolog traverses the concept graph
   - Find all paths between 'baptism' and 'eucharist'
   - Discovers links through: christian_initiation, grace, sacrament
    |
    v
2. Prolog retrieves paragraph numbers along those paths
   - paragraph_link/2 facts -> sections 1213, 1322, 1275, etc.
    |
    v
3. RAG retrieves the actual text
   - Use paragraph numbers + semantic search to pull CCC passages
   - Hybrid retrieval: BM25 keyword + vector cosine similarity
    |
    v
4. Present the Catechism's own words
   - Ordered by the Prolog-determined logical path
   - With citations and concept links
```

### Why This Works

- **Prolog provides structure** — it knows *how* concepts relate and can find paths that pure vector search would miss.
- **RAG provides language** — it handles the natural language interface and retrieves the actual text.
- **Together they eliminate each other's weaknesses** — Prolog prevents hallucination; RAG prevents rigidity.

---

## 5. Deepening the Index with Prolog Inference Rules

The existing 31,950 paragraph links already provide substantial coverage. Prolog inference rules can derive new knowledge from the existing facts without any additional data extraction.

### Transitive Relationships

```prolog
% If X is_a Y and Y is_a Z, then X is_a Z
ancestor(X, Z) :- relation(X, Z, is_a, _).
ancestor(X, Z) :- relation(X, Y, is_a, _), ancestor(Y, Z).

% All paragraphs related to a concept, including through ancestors
deep_paragraphs(Concept, Para) :- paragraph_link(Concept, Para).
deep_paragraphs(Concept, Para) :- ancestor(Concept, Parent), paragraph_link(Parent, Para).
```

### Path Finding

```prolog
% Find a connection path between two concepts (up to depth 4)
connected(A, B, [A, B]) :- relation(A, B, _, _).
connected(A, B, [A | Path]) :-
    relation(A, Mid, _, _),
    connected(Mid, B, Path).
```

### Auto-Summation

The original 2005 ACMC algorithm's breadth-first concept traversal maps naturally to Prolog's backtracking search:

```prolog
% Collect all concepts within N hops of a starting concept
nearby(Start, Concept, 0) :- Concept = Start.
nearby(Start, Concept, N) :-
    N > 0, N1 is N - 1,
    nearby(Start, Mid, N1),
    relation(Mid, Concept, _, _).

% All paragraphs within N hops
summation_paragraphs(Concept, N, Para) :-
    nearby(Concept, Related, N),
    paragraph_link(Related, Para).
```

---

## 6. Implementation: pyswip Integration

The `cathnet/venv` already has `pyswip` installed, which provides a Python-Prolog bridge. This allows the F19 NLP service to call Prolog directly.

### Example Integration

```python
from pyswip import Prolog

prolog = Prolog()
prolog.consult("cathnet/data/cccnet/cccnet.pl")

# Find all concepts related to baptism
results = list(prolog.query("relation(X, 'baptism', Type, Weight)"))
# [{'X': 'water', 'Type': 'requires', 'Weight': 0.8}, ...]

# Find paragraphs for a concept and its neighbours
results = list(prolog.query(
    "relation('eucharist', Related, _, _), paragraph_link(Related, Para)"
))
# [{'Related': 'sacrament', 'Para': 1210}, ...]
```

### Integration with F19 NLP Service

The FastAPI service (`cathnet/src/nlp_service.py`) can use Prolog as a retrieval stage:

1. **Query understanding** (F19 Phase 3) identifies theological entities in the question
2. **Prolog traversal** finds related concepts and paragraph numbers
3. **Semantic search** (F19 Phase 1) retrieves and re-ranks the actual passage text
4. **Extractive QA** (F19 Phase 2) pulls the answer span from top passages

This gives the best of both worlds: Prolog's logical precision for structured traversal, and the NLP pipeline's natural language capabilities for presentation.

---

## 7. Current State and Next Steps

### What Exists Today

- 36,000-line Prolog knowledge base (`cccnet.pl`)
- 5,937 sentence embeddings in SQLite (`cathnet.db`)
- 300 concepts, 4,134 co-occurrence relationships in the database
- Drupal module with `/map`, `/browse`, `/search/catechism` routes
- pyswip installed in `cathnet/venv`

### Potential Next Steps

1. **Write inference rules** — Add transitive closure, path-finding, and auto-summation rules to `cccnet.pl`
2. **Wire pyswip into F19** — Add Prolog as a retrieval stage in the NLP service
3. **Build a Prolog query endpoint** — Expose structured queries via the FastAPI service (e.g., `/api/prolog/related/baptism`)
4. **Test combined retrieval** — Compare Prolog+RAG results against pure semantic search on a set of theological questions

---

## 8. Technology Stack Summary

| Layer | Technology | Role |
|-------|-----------|------|
| Logical index | SWI-Prolog (via pyswip) | Structured traversal, inference, path-finding |
| Vector index | sentence-transformers + SQLite | Semantic similarity search |
| Keyword index | BM25 (rank-bm25) | Keyword retrieval |
| Re-ranking | cross-encoder/ms-marco-MiniLM | Joint query-passage scoring |
| Answer extraction | deepset/roberta-base-squad2 | Extractive QA |
| API | FastAPI | NLP microservice |
| Frontend | Drupal + Cytoscape.js | Interactive concept map and search |
| Knowledge base | `cccnet.pl` (36K lines) | 1,514 concepts, 1,671 relations, 31,950 paragraph links |
| Source text | Catechism of the Catholic Church | 2,865 paragraphs, ~15,000 sentences |
