# F30: Content Federation Network — course registry, three-stage review, theocat integration, cross-site sharing

**Status:** PROPOSED
**Created:** 2026-04-14
**Updated:** 2026-04-19 (domain rename `nwprog.org` → `nwpcom.org`; avcommons.org reframed as federation member, not fork; Domain Rollout section added; canonical-library role clarified — `saint.school` is the canonical learning library, `nwpcom.org` is the canonical governance/community site, three federation members each have their own user base; Editorial Loop §6.6 added)
**Author:** Rob Zaar, Claude Opus 4.6, Claude Opus 4.7
**Priority:** High (architectural keystone connecting nwpcom.org, saint.school, mayostudios.org, avcommons.org, and future sites into a coherent content ecosystem)
**Depends On:** F26 (OIDC — proposed; cross-domain SSO is load-bearing for the multi-site federation), F28 (unified pipeline — proposed), F29 (mayo integration — proposed), S05 (cognitive redesign — in progress), A02 (workflow system — complete), A09 (blueprints — complete)
**Breaking Changes:** No (new infrastructure; existing sites gain new capabilities without disrupting current operation)

---

## 1. Executive Summary

### 1.1 Problem Statement

NWP manages multiple sites that share overlapping audiences, overlapping content, and overlapping educational goals — but have no mechanism to share *course content* between them:

1. **nwpcom.org** is the canonical **governance / community / authoring** site (production). It is the editorial home for Catholic formation content — where reviewers approve changes, where the editorial team coordinates, and where the canonical AVC member community lives. It has its own user base. Today it runs at `avc.nwpcode.org` (test) and is being migrated through `nwpcode.org` (intermediate test deployment) before the final cutover to `nwpcom.org` — see §16 Domain Rollout.

2. **saint.school** is the **canonical learning library** (production) — the single user-facing source of truth for approved Catholic formation courses. It currently runs at `ss.nwpcode.org` pending the prod cutover. It hosts 49 Moodle courses with 217 learning points across 6 depth levels (S05), 584 quiz items (S06), and a spaced-repetition engine. The canonical *source store* for this library is `git.nwpcom.org:nwp/courses` (YAML); `saint.school` is the canonical *delivery instance* of that store. Today this content is locked to one Moodle instance and changes flow one-way from authors to delivery — there is no structured feedback loop and no mechanism for other sites to consume the same courses.

3. **mayostudios.org** is a youth-focused AVC member site with **its own user base** (Catholic youth and youth ministers). It needs many of the same courses as saint.school, but adapted for a younger audience: simplified language, youth-relevant examples, a chooseable youth theme. Today there is no mechanism to create, track, or distribute youth adaptations of canonical content.

4. **avcommons.org** is a federated AVC member site with **its own user base** (AV members), NOT a code fork — see §1.3 and §6.5. It serves AV-specific courses via its own site manifest and an `avc` adaptation layer. The same pattern applies to any future AVC member site: select courses from the canonical library at saint.school, optionally adapt them via overlay, and contribute new courses back via merge request.

5. **No structured editorial feedback loop** today. Students/learners on `saint.school` have no easy path to flag errata, suggest improvements, or request new content. Editorial decisions happen ad-hoc rather than through a defined review-approve-deploy cycle anchored in `nwpcom.org`. See §6.6.

5. **No quality gate exists for course content.** Courses go from author to Moodle with no structured review. There is no writer's check (spelling, grammar, completeness), no pedagogy check (learning design quality), and no theology check (doctrinal accuracy) — despite theocat providing exactly the tools needed for the theology stage and the AVC `workflow_assignment` module providing the workflow engine.

6. **Content cannot flow back.** If mayo develops a youth adaptation or a new course, there is no mechanism to submit it for canonical approval, share it with other sites, or maintain it as an overlay that stays in sync with the original.

### 1.2 Proposed Solution

A **Content Federation Network** that connects all NWP sites through a central git-based course registry with structured review, adaptation overlays, and per-site course selection:

1. **Central course repository** (`git.nwpcode.org:nwp/courses`) stores all canonical course content in the proven S05 YAML format. Each learning point is a versioned, individually-reviewable entity.

2. **Three-stage review workflow** using AVC's existing `workflow_assignment` module: Writer's Check → Pedagogy Check → Theology Check. Each learning point passes all three stages independently before reaching Approved status.

3. **Theocat integration** for the theology stage: automated pre-checks (quote verification, citation validation, copyright scan, theological grade classification) generate a review report that the human theology reviewer uses as input.

4. **Adaptation overlay format** allows sites like mayo to create youth-adapted versions of canonical content without forking. Overlays contain only what differs; the build pipeline merges canonical + overlay at package time.

5. **Per-site course manifest** declares which courses each site uses and which adaptation layer to apply. The build pipeline reads the manifest and produces site-specific Moodle packages.

6. **Git-based distribution** using the existing F28 signed-artifact pipeline. Approved content is tagged, signed, published to GitLab Packages, and deployed to each site's Moodle instance via mons.

7. **Contribution-back via merge requests.** Sites submit new courses or adaptations as MRs to the central repository. The same three-stage review applies.

### 1.3 Design Rationale

- **Git, not MoodleNet.** MoodleNet uses ActivityPub for federated resource sharing between Moodle instances. It has no version control, no branching, no adaptation mechanism, no approval workflow, and is a third-party SaaS (violating the threat model). Git provides all of these and runs on git.nwpcode.org. MoodleNet can be an *additional* public distribution channel for approved content in future (see Phase 10), but the primary mechanism must be git.

- **YAML, not Moodle backup (.mbz).** The S05 pipeline already proves that structured YAML is the right authoring format: human-readable, diffable, version-controllable, and convertible to both Moodle activities (via `populate_courses.php`) and Flutter app databases (via `build_seed_db.py`). Course backups (.mbz) are opaque, undiffable, and tied to specific Moodle versions.

- **Overlays, not forks.** A youth adaptation that forks the entire course creates a maintenance burden: every canonical update must be manually merged into the fork. An overlay that contains only the changed fields stays in sync automatically — the build pipeline merges canonical + overlay, and a canonical update to an un-overlaid field propagates instantly. The same logic applies at the *site* level: AVC member sites (`avcommons.org`, future members) are federation members with their own manifest + adaptation layer, **not git forks** of `nwpcom.org`. A code fork would double the review burden, fragment the canonical course catalogue, and break contribution-back. Federation gives each member its own course selection and adaptation while keeping a single source of truth. See §6.5.

- **Per-learning-point review, not per-course.** A course with 20 learning points shouldn't wait for all 20 to pass review before deploying the first 10. Granular review enables incremental progress and parallel work by different reviewers.

- **Three stages because content has three independent failure modes.** A learning point can be well-written but pedagogically unsound (lacks scaffolding), or pedagogically excellent but theologically imprecise (misattributes a doctrine), or theologically correct but poorly written (unclear sentences). Each failure mode requires different expertise to catch.

- **Theocat assists, never auto-approves.** The theology check is the highest-stakes stage. Theocat's automated reports reduce reviewer workload (flagging unverified quotes, missing citations, potential copyright issues) but the final approval is always a human decision by a qualified theology reviewer.

### 1.4 Site Architecture

```
DRUPAL (AVC Profile — community/governance/identity)     CANONICAL LIBRARY
──────────────────────────────────────────────────       ─────────────────
nwpcom.org      (governance + canonical community)        saint.school
mayostudios.org (youth member, own user base)             (canonical Moodle
avcommons.org   (AVC member,   own user base)              learning library)
        │                                                          ▲
        │  OIDC (F26 — multi-domain)                               │
        │  Each member's users sign in to saint.school             │
        ▼                                                          │
   ┌────────────────────────────────────────────────┐              │
   │                                                │              │
   │           Optional per-member Moodle           │              │
   │           (ss.mayostudios.org,                 │              │
   │            ss.avcommons.org)                   │              │
   │           Pulls content from saint.school      │──────────────┘
   │           via the federation pipeline          │
   └────────────────────────────────────────────────┘

                                   ▲
                                   │  Editorial loop (see §6.6)
                                   │  feedback → review → approve → deploy
                                   ▼
                        git.nwpcom.org           (prod, post-cutover)
                        git.nwpcode.org          (test alias during migration)
                        (GitLab: source of truth for nwp/courses)
                                   ▲
                                   │ verification tools + PD corpus
                                   │
                             theocat (local)
```

Roles:

- **`saint.school`** is the **canonical learning library** — the single user-facing source of truth for approved courses. The canonical *source store* is `git.nwpcom.org:nwp/courses` (YAML); `saint.school` is the canonical *delivery instance*.
- **`nwpcom.org`** is the canonical **governance / community / authoring** site — where the editorial team reviews feedback, approves changes, and the canonical AVC member community lives. It has its own user base.
- **`mayostudios.org`** and **`avcommons.org`** are **federation members** — they run the same AVC code as `nwpcom.org` (no fork), each with their own user base (youth, AV members). They optionally run their own Moodle delivery (`ss.mayostudios.org`, `ss.avcommons.org`) which pulls content from the canonical library at `saint.school` via the federation pipeline. Members can also point users directly at `saint.school` if they don't need a member-specific Moodle delivery.
- **`git.nwpcom.org`** is the distribution backbone for both code and content (today served by `git.nwpcode.org`, aliased through the cutover — see §16).
- **OIDC** (F26) ties identities together across all sites, with member-site users able to sign in to `saint.school` using their member-site account. F26 must support multiple issuer/client domains.
- **theocat** provides the theological verification layer feeding the three-stage review.

Each Drupal AVC site (`nwpcom.org`, `mayostudios.org`, `avcommons.org`) is its **own community** with its **own user base**. They are not redirects to a central authority — they are independent member sites that participate in a shared canonical course library. The `saint.school` library is the shared substrate; community life is per-site.

See §6.5 for federation-vs-fork, §6.6 for the editorial feedback loop, §3.4 for manifest examples.

---

## 2. Current State (2026-04-14)

### 2.1 What Exists

| Asset | Location | Status |
|---|---|---|
| 49 courses in YAML format | `sites/ss/dev/data/learning-points/courses/` | Complete (A1–J7, 217 learning points) |
| Learning point schema | `sites/ss/dev/data/learning-points/schema.yaml` | Defined (6 depth levels, quiz items, sources, prerequisites) |
| YAML→Moodle pipeline | `sites/ss/dev/faith_formation/tools/build_seed_db.py`, `mod/depthcontent/cli/populate_courses.php` | Working |
| YAML→Flutter pipeline | `sites/ss/dev/faith_formation/tools/build_seed_db.py` | Working (S01 Phase 7 complete) |
| mod_depthcontent | `sites/ss/dev/mod/depthcontent/` | Deployed (6 depths, inline quizzes, SM-2 spaced repetition) |
| Quiz bank | `sites/ss/dev/data/learning-points/courses/` | 584 items across 49 courses |
| workflow_assignment module | `sites/avc/*/html/profiles/contrib/avc/modules/avc_features/workflow_assignment/` | Production-ready (templates, sequential assignments, revision tracking) |
| A02 workflow system | AVC profile | Complete (versioning, re-edit, time-limited claiming) |
| A09 community blueprints | AVC profile | Complete (context/blueprint/specialist, including `avc_moodle` course specialist) |
| avc_moodle module | `sites/avc/dev/html/modules/custom/avc_moodle/` | Built (OAuth2, role sync, badge display) |
| theocat CLI | `~/theocat/` | Working (search, install, update, status) |
| theocat quote-verifier | `~/theocat/tools/quote-verifier/` | Working (online + local modes, fuzzy matching) |
| theocat citation-checker | `~/theocat/tools/citation-checker/` | Working |
| Open Dogmatics (S03) | `~/theocat/data/open-dogmatics/` | Complete (290 propositions, 218 SS-course mappings, theological grades) |
| Pseudo-Catechism (S02) | `~/theocat/projects/pseudo-catechism/` | In progress (50 learning points, 2,840 CCC paragraphs mapped) |
| copyright_scan.py (S07) | SS site tools | Complete (0 HIGH-risk across all content) |
| F26 OIDC architecture | `docs/proposals/F26-avc-ss-oidc.md` | Designed (AVC issuer, Moodle client, UID lock, email hashing) |
| F28 signed pipeline | `docs/proposals/F28-unified-pipeline.md` | Designed (mmt→Packages→mons→prod) |
| F29 mayo integration | `docs/proposals/F29-mayo-comprehensive-integration.md` | Designed (10 phases, two-tier sanitization) |
| git.nwpcode.org | Running | GitLab with Packages registry, CI/CD |

### 2.2 What Does NOT Exist

- Central `nwp/courses` repository (courses live only in `sites/ss/`)
- Adaptation overlay format or schema
- Three-stage review workflow template
- `theocat review` command (individual tools exist but no unified review subcommand)
- Per-site course manifest format
- Course build pipeline that reads manifests and merges overlays
- Any mechanism for mayo/avcommons to select, adapt, or contribute courses
- ss.mayostudios.org or ss.avcommons.org Moodle instances
- Youth adaptation of any course content
- avcommons.org AVC instance

---

## 3. Course Content Format

### 3.1 Canonical Format (Existing S05 Schema)

The proven format from S05 becomes the canonical content format for the entire network. Each course is a directory containing a `course.yaml` metadata file and individual learning point files:

```
courses/A1/
├── course.yaml
└── learning-points/
    ├── A1.01.yaml
    ├── A1.02.yaml
    ├── A1.03.yaml
    ├── A1.04.yaml
    └── A1.05.yaml
```

**course.yaml:**
```yaml
course:
  code: "A1"
  title: "The Universal Call to Holiness"
  category: "A"
  category_name: "Foundations"
  sessions: 5
  prerequisites: []
  certificate_quote: "..."
  certificate_source: "..."
  status: approved           # draft | in_review | approved | archived
  version: "2.1"
  last_approved: "2026-04-10"
  approved_by: "fr-john"
```

**Learning point (A1.01.yaml):** Follows the existing S05 schema with 6 depth levels (short, standard, longer, detailed, advanced, scholar), quiz items, practice actions, cross-references, and source citations. See `sites/ss/dev/data/learning-points/schema.yaml` for the full definition.

### 3.2 Review Metadata

Each learning point carries review status tracked in the YAML:

```yaml
learning_point:
  id: "A1.01"
  title: "God's universal call"
  status: approved           # draft | writer_review | pedagogy_review | theology_review | approved
  version: "2.1"
  review:
    writer:
      status: passed         # pending | in_progress | passed | revision_requested
      reviewer: "editor-jane"
      date: "2026-04-01"
      notes: ""
    pedagogy:
      status: passed
      reviewer: "educator-mary"
      date: "2026-04-05"
      notes: "Excellent scaffolding from short to standard depth"
    theology:
      status: passed
      reviewer: "fr-john"
      theocat_report: "review/A1.01-theocat.md"
      date: "2026-04-10"
      notes: "All citations verified. De fide grade confirmed for core claims."
  # ... depths, quiz_items, practice, etc.
```

The review metadata is authoritative for distribution decisions: only learning points with `status: approved` are included in built packages. The AVC workflow engine drives the review process; the YAML metadata records the outcome.

### 3.3 Adaptation Overlay Format

An adaptation contains only the fields that differ from canonical. The build pipeline deep-merges canonical + overlay:

```yaml
# adaptations/mayo/A1/learning-points/A1.01.yaml
adaptation:
  id: "A1.01"
  layer: "youth"
  base_version: "2.1"       # Canonical version this adapts
  status: approved           # Same review stages apply
  review:
    writer:
      status: passed
      reviewer: "youth-editor"
      date: "2026-04-12"
    pedagogy:
      status: passed
      reviewer: "youth-educator"
      date: "2026-04-13"
    theology:
      status: passed         # Theology check mandatory even for rewrites
      reviewer: "fr-john"
      date: "2026-04-14"

  # Only override what changes — everything else inherits from canonical
  overrides:
    depths:
      standard:
        text: "God calls every single person to holiness — yes, even you..."
        key_quotes:
          - text: "Be holy, for I the Lord your God am holy."
            source: "Leviticus 19:2 (Douay-Rheims)"
      longer:
        text: "..."
    quiz_items:
      - id: "A1.01.q1"
        question: "What does it mean when we say God calls everyone to holiness?"
        # Youth-friendly language, same doctrinal content
```

**Merge rules:**
- Scalar fields: overlay replaces canonical
- Array fields (quiz_items): overlay replaces the entire array (not merged item-by-item) to prevent confusing partial overwrites
- Missing fields: canonical value used
- `base_version` mismatch: build warns that overlay may need updating (canonical changed since adaptation was written)

### 3.4 Site Course Manifest

Each site declares which courses it uses:

```yaml
# sites/nwpcom.yaml
site: nwpcom.org
moodle: saint.school
adaptation: null             # Canonical content, no overlay

courses:
  # All 49 canonical courses
  - { id: A1, version: ">=2.0" }
  - { id: A2, version: ">=1.0" }
  # ... all courses listed
```

```yaml
# sites/mayo.yaml
site: mayostudios.org
moodle: ss.mayostudios.org
context: mayo                # A09 blueprint context
adaptation: youth            # Default adaptation layer

courses:
  # Canonical courses with youth adaptation
  - { id: A1, version: ">=2.0", adaptation: youth }
  - { id: A2, version: ">=1.0", adaptation: youth }
  - { id: B1, version: ">=1.0" }       # No youth version yet — use canonical

  # Mayo-originated courses
  - id: MAYO-L01
    title: "Youth Leadership"
    origin: local                        # Developed by mayo, not canonical
    canonical_status: submitted          # MR pending for canonical adoption
```

```yaml
# sites/avcommons.yaml
site: avcommons.org
moodle: ss.avcommons.org
context: avc-member          # A09 blueprint context for AVC member orgs
adaptation: avc              # AVC-member adaptation layer (see adaptations/avc/)

courses:
  # Canonical courses with optional avc adaptation
  - { id: A1, version: ">=2.0", adaptation: avc }
  - { id: A2, version: ">=1.0" }                    # No avc overlay yet — canonical
  # ... selected subset

  # AVC-member-originated courses (AV-specific formation content)
  - id: AVC-C01
    title: "AV-Specific Formation Module"
    origin: local
    canonical_status: member-only        # Stays in adaptations/avc/, not promoted to canonical
```

The `avc` adaptation layer parallels `mayo`'s `youth` layer: AV-specific examples, internal references, and member-only courses live under `adaptations/avc/` (see §7.1 repo layout). Canonical courses without an `avc` overlay render unchanged on `ss.avcommons.org`.

---

## 4. Three-Stage Review Workflow

### 4.1 Workflow Template

The AVC `workflow_assignment` module supports templates with sequential assignments. A single template named "Course Content Review" creates three assignments per learning point:

| Stage | Assignment Name | Typical Assignee | Checks | Completion Criteria |
|---|---|---|---|---|
| 1 | **Writer's Check** | Content editor | Spelling, grammar, completeness, formatting, source attribution, depth-level consistency | All 6 depth levels well-written and internally consistent |
| 2 | **Pedagogy Check** | Educator / curriculum designer | Learning objectives, explanation quality, depth scaffolding, quiz alignment, prerequisites, practice action quality | Content is pedagogically sound across all depths |
| 3 | **Theology Check** | Formation director / priest | Doctrinal accuracy, source verification, magisterial alignment, theological grade appropriateness, copyright compliance | theocat report clean; all doctrinal claims substantiated |

### 4.2 Workflow States

Each assignment transitions through: `pending` → `in_progress` → `passed` or `revision_requested`

If any stage returns `revision_requested`, the learning point returns to the author with reviewer notes. After revision, it re-enters at the stage that requested revision (not from stage 1, unless the revision was substantial enough to warrant re-checking writing/pedagogy).

```
                          ┌─ revision_requested ─┐
                          │                      │
Author ──► Writer Check ──┼──► Pedagogy Check ──┼──► Theology Check ──► Approved
           (stage 1)      │    (stage 2)         │    (stage 3)
                          │                      │
                          └─ revision_requested ─┘
```

### 4.3 Adaptation Review

Youth adaptations and other overlays go through the same three-stage review, but with awareness that the underlying canonical content is already approved:

- **Writer's Check:** Focuses on the adaptation text quality (not re-checking canonical text)
- **Pedagogy Check:** Evaluates whether the adaptation is appropriate for the target audience (e.g., youth reading level, age-appropriate examples)
- **Theology Check:** Mandatory. A youth rewrite that simplifies language could inadvertently change doctrinal meaning. The theology reviewer verifies that the adaptation preserves the theological substance of the canonical version.

### 4.4 Review Efficiency

Not every change requires full three-stage review:

| Change Type | Writer | Pedagogy | Theology |
|---|---|---|---|
| New learning point | Required | Required | Required |
| Depth-level text rewrite | Required | Required | Required |
| Quiz item edit | Required | — | Required (if doctrinal) |
| Typo fix / formatting | Required | — | — |
| Source citation update | — | — | Required |
| Youth adaptation | Required | Required | Required |
| Metadata-only change | — | — | — |

The workflow template supports skipping stages via the reviewer marking the stage as "not applicable" — but theology review can never be skipped for content changes.

---

## 5. Theocat Integration

### 5.1 The `theocat review` Command

A new subcommand that bundles existing tools into a single review pipeline:

```bash
theocat review path/to/A1.01.yaml --output review/A1.01-theocat.md
```

**Pipeline steps:**

1. **Parse learning point YAML** — extract all text content across depth levels, quiz items, and source citations.

2. **Quote verification** (existing `quote-verifier`) — for every quoted passage, check that it exists in the installed theocat sources. Report match score (exact, minor difference, significant difference, not found).

3. **Citation validation** (existing `citation-checker`) — verify all Denzinger references (DH numbers), Scripture references (book/chapter/verse against Douay-Rheims), Council references, and Summa references (Part/Question/Article).

4. **Theological grade classification** (S03 Open Dogmatics) — for each doctrinal claim in the learning point, look up the corresponding proposition in the open-dogmatics data and report its theological grade (de fide, sententia certa, sententia communis, or unclassified).

5. **Copyright scan** (existing `copyright_scan.py` from S07) — verify no copyrighted text has leaked into the content. Flag CCC verbatim quotes, Ott verbatim text, copyrighted Scripture translations (RSV-CE, NRSV-CE).

6. **Source authority check** — for each source cited, classify its authority level per theocat's hierarchy: Sacred Scripture > Ecumenical Councils > Catechism > Denzinger > Ott > Aquinas > Church Fathers > Doctors > theological opinion. Flag any learning point that makes a strong doctrinal claim supported only by lower-authority sources.

**Output:** A structured markdown report attached to the theology review assignment:

```markdown
# Theocat Review Report: A1.01 — God's Universal Call

**Generated:** 2026-04-14  **Schema:** 1.0

## Quote Verification
| # | Quote | Source | Match | Score |
|---|-------|--------|-------|-------|
| 1 | "Be holy, for I..." | Leviticus 19:2 (DR) | ✓ Exact | 100% |
| 2 | "God wills all men..." | 1 Timothy 2:4 (DR) | ✓ Exact | 100% |
| 3 | "The universal call..." | Lumen Gentium §40 | ⚠ Not in corpus | — |

## Citation Validation
| Reference | Type | Valid | Notes |
|-----------|------|-------|-------|
| DH 1528 | Denzinger | ✓ | Council of Trent, Session VI |
| ST I-II, Q.109, A.9 | Aquinas | ✓ | On grace and free will |

## Theological Grade
| Claim | Proposition | Grade |
|-------|-------------|-------|
| All are called to holiness | T1.A.003 | de_fide |
| Grace is necessary for salvation | T4.G.008 | de_fide |

## Copyright Scan
✓ No HIGH-risk content detected
✓ No copyrighted Scripture translations
✓ All quotes from PD sources

## Source Authority
✓ All de_fide claims supported by Scripture or Council sources
⚠ 1 claim supported only by Doctors (recommend adding Council citation)

## Summary
- Quotes: 2/3 verified (1 not in local corpus — check manually)
- Citations: 2/2 valid
- Copyright: Clean
- Recommendation: PASS with minor note (add Lumen Gentium to corpus or verify manually)
```

### 5.2 CI Integration

The `theocat review` command runs automatically in GitLab CI on every merge request to `nwp/courses`:

```yaml
# .gitlab-ci.yml (nwp/courses)
theology-check:
  stage: verify
  script:
    - for f in $(git diff --name-only origin/main -- 'courses/*/learning-points/*.yaml'); do
        theocat review "$f" --output "review/$(basename "$f" .yaml)-theocat.md"
        --fail-on-high-copyright;
      done
  artifacts:
    paths: [review/]
  rules:
    - if: $CI_MERGE_REQUEST_IID
      changes: ["courses/*/learning-points/*.yaml"]
```

The CI job:
- Runs only on changed learning point files
- Fails the pipeline if copyright scan finds HIGH-risk content (hard gate)
- Produces review reports as downloadable artifacts
- Does NOT auto-approve (theology reviewer still required)

### 5.3 Theocat Corpus Expansion

For the theology check to be effective, the theocat corpus must cover the sources cited in courses. Current coverage:

| Source Category | theocat Coverage | Action Needed |
|---|---|---|
| Aquinas (Summa) | ✓ Complete (180 MB) | None |
| Church Fathers | ✓ Complete (760 MB patristics-english) | None |
| Councils (Nicaea I – Vatican I) | ✓ Complete (45 MB) | None |
| Scripture (Douay-Rheims) | ✓ Complete (717 MB scripture-pd) | None |
| Vatican II documents | Partial (in councils package) | Add remaining documents |
| PD Catechisms | ✓ Complete (Baltimore, Pius X, Deharbe, Roman Catechism) | None |
| Doctors of the Church | ✓ Complete (medieval + reformation + modern-pd) | None |
| Open Dogmatics (S03) | ✓ Complete (290 propositions) | None |
| Lumen Gentium, Dei Verbum, etc. | ✗ Not in corpus | Add as new theocat source package |

**Phase 3 action:** Create `theocat-sources/vatican2-pd` package with freely available Vatican II document texts (English translations from Vatican.va are freely distributable for non-commercial educational use).

---

## 6. Cross-Site Content Flow

### 6.1 Canonical Content (nwpcom.org → all sites)

```
Author creates learning point on nwpcom.org
    ↓
Submits for review → workflow_assignment creates 3 assignments
    ↓
Writer's Check → Pedagogy Check → Theology Check (with theocat report)
    ↓
All three pass → status: approved
    ↓
Approved YAML committed to nwp/courses (main branch)
    ↓
CI runs: schema validation, theocat check, copyright scan
    ↓
Tagged release → signed package published to GitLab Packages
    ↓
Each site's build pipeline reads its manifest, builds Moodle package
    ↓
Deploy via F28 pipeline: mmt → Packages → mons → prod Moodle instances
```

### 6.2 Youth Adaptation (mayo → canonical)

```
Mayo youth author adapts canonical A1.01 for youth audience
    ↓
Creates overlay YAML in adaptations/mayo/A1/learning-points/A1.01.yaml
    ↓
Local three-stage review on mayostudios.org
  (Writer: youth-appropriate language?
   Pedagogy: suitable for 13-18 age range?
   Theology: doctrinal substance preserved?)
    ↓
Local review passes → MR submitted to nwp/courses
    ↓
Canonical three-stage review (nwpcom.org reviewers)
    ↓
Approved → merged to main → available to ALL sites as "youth" adaptation
    ↓
Deployed to ss.mayostudios.org (default: youth)
Also selectable on saint.school (user preference: "youth presentation")
```

### 6.3 New Course Contribution (any site → canonical)

```
Mayo develops new course MAYO-L01 "Youth Leadership"
    ↓
Full three-stage review on mayostudios.org
    ↓
Deployed locally to ss.mayostudios.org
    ↓
Optionally: MR to nwp/courses for canonical adoption
    ↓
Canonical review (may request changes for broader audience)
    ↓
If approved: course moves from adaptations/mayo/ to courses/
  (or stays in adaptations/mayo/ if it's mayo-specific)
    ↓
Available to all sites via manifests
```

### 6.4 Chooseable Themes on saint.school

A user on saint.school can select a "youth" presentation for any course that has a youth adaptation. This works through `mod_depthcontent`'s existing user preference system (S05):

- Current preferences: depth level (default, per-point overrides)
- New preference: `adaptation` (canonical / youth / community / ...)
- When set to "youth", the module loads the overlay content for that learning point
- If no overlay exists for a particular point, canonical content is shown
- Theme/styling also switches (youth-friendly CSS within the Moodle theme)

This means saint.school is not locked to canonical presentation — it can offer the youth adaptation to users who prefer it, without requiring a separate Moodle instance.

### 6.5 Federation vs Fork (avcommons.org and future members)

When a new AVC-aligned organisation wants its own site (e.g. `avcommons.org`), there are two architectural options. F30 deliberately rules out the fork model in favour of federation:

| Concern | **Fork** (rejected) | **Federation** (chosen) |
|---|---|---|
| Code | Member runs a fork of the AVC profile and diverges over time | Member runs the same canonical AVC code; updates flow via standard upgrades |
| Course catalogue | Member maintains its own copy of `nwp/courses` and merges changes manually | Member declares a manifest selecting canonical courses; updates flow automatically |
| Adaptation | Forks the YAML and edits in place (lossy diff against canonical) | Overlay layer — only changed fields stored, base content auto-updates |
| Three-stage review | Doubled — fork must run its own review of identical content | Single — canonical review covers shared content; only adaptations re-reviewed |
| Contribution back | "Send a patch upstream" — usually never happens, so forks stagnate or diverge | Standard MR to `nwp/courses` — same workflow members already use internally |
| Identity | Each fork might run its own auth | Multi-domain OIDC (F26) keeps members on a single trust chain |
| Bug fixes | Each fork must cherry-pick or re-implement | Fix once in canonical, all members get it |
| Member-only content | Mixed into the forked tree, hard to extract or share | Lives clearly in `adaptations/<member>/`, can be promoted to canonical via MR if generally useful |
| Threat model | More attack surface (more independently-maintained codebases) | One canonical codebase under unified review |

**Conclusion:** Every AVC member site is a federation member. There are no code forks of `nwpcom.org`. Members can have their own theme, blueprint context, course manifest, adaptation overlay, and member-only courses — all the divergence a member realistically needs — without paying the maintenance cost of a fork.

The single exception that could justify a fork is a **hard policy split** (e.g., a member organisation rejects the canonical review process or doctrinal stance). At that point the right answer is not a fork but a separate-but-friendly project — different repo, different governance, no expectation of content reciprocity. F30 does not budget for this case.

### 6.6 Editorial Feedback Loop (saint.school → git.nwpcom.org → nwpcom.org → saint.school)

`saint.school` is the canonical learning library and a **production** Moodle instance — students, reviewers, and authors hit real content there. That makes saint.school the natural source of editorial signal: typo reports, broken-quote flags, "this lesson is unclear", "this quiz item is wrong", reviewer queue items, and full course-revision proposals all originate from real use.

The editorial loop closes those signals back into the canonical content without bypassing the three-stage review:

```
   ┌──────────────────────────────────────────────────────────────────┐
   │  saint.school  (canonical Moodle, production users)              │
   │  ─ Inline "report issue" on lesson / quiz / quote                │
   │  ─ Reviewer queue (Writer / Pedagogy / Theology stages)          │
   │  ─ Author "propose revision" workflow                            │
   └──────────────────────────────┬───────────────────────────────────┘
                                  │  Issues + MRs (F27 ingest pattern)
                                  ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  git.nwpcom.org   nwp/courses                                    │
   │  ─ Issue tracker (one issue per editorial signal)                │
   │  ─ Branch / MR per proposed revision                             │
   │  ─ CI: schema validation, theocat review, copyright scan         │
   └──────────────────────────────┬───────────────────────────────────┘
                                  │  Reviewer assignment
                                  ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  nwpcom.org  (canonical AVC governance + community)              │
   │  ─ Reviewer dashboard (Writer / Pedagogy / Theology)             │
   │  ─ Three-stage approval (§4)                                     │
   │  ─ Reviewer marks MR approved → merges to nwp/courses main       │
   └──────────────────────────────┬───────────────────────────────────┘
                                  │  Merge to main
                                  ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  git.nwpcom.org   build pipeline (§8)                            │
   │  ─ build-site-courses.sh --site saint.school                     │
   │  ─ Sign artifact (F28 minisign)                                  │
   │  ─ Publish to GitLab Packages                                    │
   └──────────────────────────────┬───────────────────────────────────┘
                                  │  Signed package, mons verifies
                                  ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  saint.school  (deploy)                                          │
   │  ─ populate_courses.php consumes JSON                            │
   │  ─ mod_depthcontent picks up updated learning points             │
   │  ─ Reporters notified that their issue shipped                   │
   └──────────────────────────────────────────────────────────────────┘
```

**Why this matters:** the canonical library can't be authored in a vacuum. Every canonical lesson improves through real use. saint.school is where that signal lives; nwp/courses is where it becomes a reviewable change; nwpcom.org is where qualified humans approve it; the build pipeline gets it back to saint.school under the same signed-artifact discipline as any other deploy.

**Reviewer governance lives on nwpcom.org, not saint.school.** This is deliberate:
- nwpcom.org owns the AVC profile and the workflow_assignment / blueprint machinery (the right place for governance UI)
- saint.school stays focused on learning delivery (Moodle, mod_depthcontent, spaced repetition)
- The reviewer dashboard, role assignments, and approval audit trail all live in the Drupal/AVC stack on nwpcom.org

**Member-site signals.** Editorial feedback can also originate from `mayostudios.org` (or `ss.mayostudios.org`), `avcommons.org` (or `ss.avcommons.org`), and any future member. These sites surface issues against either:
- A canonical learning point → MR against `courses/<id>/learning-points/<lp>.yaml` (canonical review on nwpcom.org)
- An adaptation overlay → MR against `adaptations/<member>/<id>/learning-points/<lp>.yaml` (adaptation review per §4.3, scoped to the member)

The same git issue tracker (`nwp/courses`) collects both classes; routing is determined by which path the MR touches.

**Reuses F27 ingest pattern.** F27 (feedback ingest) already defines how production sites file structured issues into a GitLab project. F30's editorial loop is F27 applied to nwp/courses with course-content-specific labels (`lesson:typo`, `quiz:incorrect`, `quote:unverified`, `theology:flag`, `pedagogy:rewrite`). No new ingest mechanism is needed.

---

## 7. Repository Structure

### 7.1 nwp/courses Repository

```
nwp/courses/
├── README.md                           # What this repo is, how to contribute
├── schema.yaml                         # Learning point schema (from S05)
├── adaptation-schema.yaml              # Overlay format definition
├── manifest-schema.yaml                # Site manifest format definition
├── registry.yaml                       # Master course catalogue with metadata
├── .gitlab-ci.yml                      # CI: schema validation, theocat, copyright
├── courses/
│   ├── A1/
│   │   ├── course.yaml                 # Course metadata, status, version
│   │   ├── learning-points/
│   │   │   ├── A1.01.yaml
│   │   │   ├── A1.02.yaml
│   │   │   └── ...
│   │   └── review/                     # theocat reports (generated, gitignored)
│   ├── A2/
│   ├── ...
│   └── J7/                             # All 49 existing courses
├── adaptations/
│   ├── mayo/                           # Youth adaptations (mayostudios.org)
│   │   ├── adaptation.yaml             # Layer metadata (name, audience, theme)
│   │   ├── A1/
│   │   │   └── learning-points/
│   │   │       ├── A1.01.yaml          # Youth overlay for A1.01
│   │   │       └── ...
│   │   └── MAYO-L01/                   # Mayo-originated course
│   │       ├── course.yaml
│   │       └── learning-points/
│   │           └── ...
│   └── avc/                            # AVC member adaptations (avcommons.org)
│       ├── adaptation.yaml             # Layer metadata (name: avc, audience, theme)
│       ├── A1/
│       │   └── learning-points/        # AVC overlays where canonical needs AV-specific framing
│       │       └── ...
│       └── AVC-C01/                    # AVC-member-originated course
│           ├── course.yaml
│           └── learning-points/
│               └── ...
├── sites/
│   ├── nwpcom.yaml                     # Canonical site manifest
│   ├── mayo.yaml                       # Mayo site manifest
│   └── avcommons.yaml                  # AVCommons site manifest
└── tools/
    ├── build-site-courses.sh           # Read manifest, merge overlays, package
    ├── validate-schema.py              # Schema validation for CI
    └── merge-overlay.py                # Canonical + overlay deep merge
```

### 7.2 Relationship to Existing Repositories

| Repository | Role | Relationship to nwp/courses |
|---|---|---|
| `nwp/nwp` | NWP tooling and harness | Contains `lib/`, `scripts/`, build pipeline |
| `nwp/courses` | **Course content** (NEW) | Central content registry |
| `mayo/mayo` | Mayo Drupal site code | References courses via manifest |
| `mayo/saintschool` | Mayo Moodle site (F29) | Receives built course packages |
| `avc/avc` | AVC Drupal profile | workflow_assignment module, blueprints |
| `nwp/theocat` | Theology tools | Provides `theocat review` for CI and reviewers |

---

## 8. Build Pipeline

### 8.1 Course Build Flow

```bash
# Build courses for a specific site
./tools/build-site-courses.sh --site mayo --output /tmp/mayo-courses/
```

**Steps:**

1. **Read manifest** (`sites/mayo.yaml`) — list of courses, versions, adaptation layer
2. **For each course in manifest:**
   a. Load canonical `courses/{id}/course.yaml` — check version constraint
   b. Load all canonical learning points from `courses/{id}/learning-points/`
   c. If adaptation specified, load overlay from `adaptations/{layer}/{id}/learning-points/`
   d. Deep-merge canonical + overlay (overlay wins for present fields)
   e. Filter: only include learning points with `status: approved`
   f. Validate merged content against schema
3. **Output:** One JSON file per course (matching existing `populate_courses.php` input format)
4. **Package:** tar.gz with manifest.yaml for signing

### 8.2 Integration with Existing Pipelines

The output JSON format is identical to what `populate_courses.php` already consumes. This means:

- **saint.school:** Existing S04/S05 pipeline works unchanged (it already reads JSON)
- **ss.mayostudios.org:** Same pipeline, different input (merged canonical + youth overlay)
- **Faith Formation app (S01):** `build_seed_db.py` reads the same YAML, so the app can also offer adaptation selection

### 8.3 Signing and Distribution

Built course packages follow the F28 signed-artifact pipeline:

```
nwp/courses CI builds JSON packages per site
    ↓
minisign signs each package
    ↓
Published to GitLab Packages: nwp/courses/<site>/<version>.tar.gz
    ↓
mons downloads, verifies signature, deploys to site's Moodle
    ↓
populate_courses.php imports into Moodle database
    ↓
Moodle cache purge
```

---

## 9. Phased Execution

### Phase 1 — Course Repository Bootstrap

**Goal:** Migrate 49 SS courses to `nwp/courses` repository. Define schemas for adaptations and manifests.

**Autonomy level:** Fully autonomous (moving existing files + defining schemas).

1.1. Create GitLab project `nwp/courses` at git.nwpcode.org.

1.2. Copy existing course YAML files:
```bash
cp -r ~/nwp/sites/ss/dev/data/learning-points/courses/ courses/
cp ~/nwp/sites/ss/dev/data/learning-points/schema.yaml schema.yaml
```

1.3. Add `course.yaml` metadata file to each course directory (extracted from the `course:` block in each YAML).

1.4. Define `adaptation-schema.yaml` — overlay format with `adaptation`, `overrides`, `base_version` fields.

1.5. Define `manifest-schema.yaml` — site manifest format with `site`, `moodle`, `adaptation`, `courses` fields.

1.6. Create `sites/nwpcom.yaml` — canonical manifest listing all 49 courses.

1.7. Create `registry.yaml` — master catalogue of all courses with codes, titles, categories, statuses.

1.8. Create `README.md` — what this repo is, how courses are structured, how to contribute.

1.9. Initial commit, push to GitLab, protect main branch.

1.10. Update `sites/ss/` to reference `nwp/courses` as the content source (symlink or git submodule during transition).

**Verification:**
- [ ] `nwp/courses` repo on GitLab with 49 course directories
- [ ] Each course has `course.yaml` + `learning-points/` with existing YAML files
- [ ] `schema.yaml`, `adaptation-schema.yaml`, `manifest-schema.yaml` defined
- [ ] `sites/nwpcom.yaml` manifest lists all 49 courses
- [ ] Existing `populate_courses.php` still works against the course files

---

### Phase 2 — Three-Stage Workflow Template

**Goal:** Configure AVC's workflow_assignment module with a "Course Content Review" template.

**Autonomy level:** Fully autonomous (Drupal configuration).

2.1. Create workflow template "Course Content Review" in AVC with three sequential prototype assignments:
- Assignment 1: "Writer's Check" — assignee type: group (Content Editors)
- Assignment 2: "Pedagogy Check" — assignee type: group (Educators)
- Assignment 3: "Theology Check" — assignee type: group (Theology Reviewers)

2.2. Export configuration to AVC profile config sync directory.

2.3. Define a "Course Learning Point" content type in AVC (or extend an existing one) with:
- `field_course_code` — reference to course
- `field_learning_point_id` — string (e.g., "A1.01")
- `field_workflow_list` — reference to workflow template
- `field_review_status` — taxonomy (draft, writer_review, pedagogy_review, theology_review, approved)
- `field_theocat_report` — file field for theocat review report

2.4. Create view "Review Queue" showing learning points awaiting review, filterable by stage.

2.5. Document the review process in `nwp/courses/docs/review-guide.md`.

**Verification:**
- [ ] Workflow template visible in AVC admin at `/admin/content/workflow-template`
- [ ] Creating a learning point content entity attaches three workflow assignments
- [ ] Each assignment can be picked up, worked on, and completed independently
- [ ] Review queue view shows pending items per stage

---

### Phase 3 — Theocat Review Command

**Goal:** Bundle existing theocat tools into a single `theocat review` subcommand.

**Autonomy level:** Fully autonomous.

3.1. Create `~/theocat/core/review.py` — orchestrates the review pipeline:
- Parse learning point YAML
- Run quote-verifier against all quoted passages
- Run citation-checker against all references
- Look up theological grades from open-dogmatics
- Run copyright scan
- Check source authority levels
- Generate structured markdown report

3.2. Add `review` subcommand to `~/theocat/bin/theocat.py`:
```bash
theocat review <yaml-file> [--output <report.md>] [--fail-on-high-copyright]
```

3.3. Create Vatican II source package for theocat (`theocat-sources/vatican2-pd`) — freely available English texts of Lumen Gentium, Dei Verbum, Gaudium et Spes, Sacrosanctum Concilium, and other key documents.

3.4. Test against 5 existing learning points (A1.01–A1.05) and verify reports are accurate.

3.5. Document in `~/theocat/docs/review-guide.md`.

**Verification:**
- [ ] `theocat review courses/A1/learning-points/A1.01.yaml` produces structured markdown report
- [ ] Report includes: quote verification, citation validation, theological grades, copyright scan, source authority
- [ ] `--fail-on-high-copyright` returns non-zero exit code if HIGH-risk content found
- [ ] Vatican II documents searchable via `theocat search "Lumen Gentium"`

---

### Phase 4 — CI Validation Pipeline

**Goal:** GitLab CI on `nwp/courses` runs schema validation, theocat checks, and copyright scan on every MR.

**Autonomy level:** Fully autonomous.

4.1. Create `tools/validate-schema.py` — validates all YAML files against `schema.yaml` and `adaptation-schema.yaml`.

4.2. Create `.gitlab-ci.yml` for `nwp/courses`:
```yaml
stages:
  - validate
  - review

validate:schema:
  stage: validate
  script:
    - python3 tools/validate-schema.py
  rules:
    - if: $CI_MERGE_REQUEST_IID

validate:copyright:
  stage: validate
  script:
    - python3 tools/copyright-scan.py --fail-on-high
  rules:
    - if: $CI_MERGE_REQUEST_IID
      changes: ["courses/**/*.yaml", "adaptations/**/*.yaml"]

review:theology:
  stage: review
  script:
    - |
      for f in $(git diff --name-only origin/main -- 'courses/*/learning-points/*.yaml' 'adaptations/*/*/learning-points/*.yaml'); do
        theocat review "$f" --output "review/$(basename "$f" .yaml)-theocat.md"
      done
  artifacts:
    paths: [review/]
  allow_failure: true  # Reports are advisory, not blocking (except copyright)
  rules:
    - if: $CI_MERGE_REQUEST_IID
      changes: ["courses/**/*.yaml", "adaptations/**/*.yaml"]
```

4.3. Add `tools/copyright-scan.py` — adapted from S07's scanner for the nwp/courses context.

4.4. Test pipeline with a sample MR that modifies a learning point.

**Verification:**
- [ ] MR to `nwp/courses` triggers CI pipeline
- [ ] Schema validation catches malformed YAML
- [ ] Copyright scan blocks MR with HIGH-risk content
- [ ] Theocat review reports downloadable as pipeline artifacts

---

### Phase 5 — Course Build Pipeline

**Goal:** `build-site-courses.sh` reads a site manifest, merges canonical + adaptation overlays, and produces JSON packages compatible with `populate_courses.php`.

**Autonomy level:** Fully autonomous.

5.1. Create `tools/merge-overlay.py` — deep-merge logic for canonical + adaptation YAML. Handles:
- Scalar replacement
- Array replacement (not item-level merge)
- `base_version` mismatch warning
- Missing overlay = use canonical unchanged

5.2. Create `tools/build-site-courses.sh`:
```bash
./tools/build-site-courses.sh --site mayo --output /tmp/mayo-courses/
```
- Reads `sites/mayo.yaml`
- For each course: load canonical, apply overlay if specified, filter approved-only
- Output: JSON files matching `populate_courses.php` input format
- Package as tar.gz with manifest

5.3. Verify backward compatibility: run build for `nwpcom` site (no overlays), compare output against existing SS JSON files — should be identical.

5.4. Create `tools/package-courses.sh` — signs the tar.gz with minisign for F28 distribution.

**Verification:**
- [ ] `build-site-courses.sh --site nwpcom` produces JSON identical to current SS pipeline
- [ ] `build-site-courses.sh --site mayo` applies youth overlays where present
- [ ] Missing overlays gracefully fall back to canonical content
- [ ] `base_version` mismatch produces a warning (not failure)
- [ ] Output JSON importable by `populate_courses.php`

---

### Phase 6 — First Youth Adaptation (Mayo pilot)

**Goal:** Youth-adapt 5 courses (A1–A5, "Foundations" category) to validate the overlay format in practice.

**Autonomy level:** Content creation requires human review. Overlay format is autonomous.

6.1. Create `adaptations/mayo/adaptation.yaml`:
```yaml
name: youth
display_name: "Youth Presentation"
audience: "Catholic youth ages 13-18"
theme: youth
description: "Simplified language, youth-relevant examples, age-appropriate scaffolding"
```

6.2. For each of A1.01 through A5.xx (approximately 25 learning points):
- Create overlay YAML with `depths.standard.text` rewritten for youth audience
- Adjust quiz item language where needed
- Adjust practice actions for youth context
- Preserve all theological substance (same sources, same depth of doctrine)

6.3. Submit all overlays as a single MR to `nwp/courses`.

6.4. Run three-stage review on the adaptations:
- Writer's check: youth-appropriate language quality
- Pedagogy check: suitable for 13-18 age range
- Theology check: doctrinal substance preserved (theocat report confirms)

6.5. Build and test: `build-site-courses.sh --site mayo` produces merged JSON with youth content.

**Verification:**
- [ ] 5 courses have youth overlays in `adaptations/mayo/`
- [ ] All overlays pass three-stage review
- [ ] Built JSON contains youth-adapted text for overlaid points
- [ ] Built JSON contains canonical text for non-overlaid points
- [ ] theocat reports confirm theological equivalence between canonical and youth versions

---

### Phase 7 — mod_depthcontent Adaptation Preference

**Goal:** Users on any Moodle instance can select an adaptation (e.g., "youth") as a preference, and the module loads overlay content.

**Autonomy level:** Fully autonomous (Moodle plugin extension).

7.1. Add `adaptation` column to `depthcontent_progress` table (or a new `depthcontent_preferences` table).

7.2. Add adaptation selector to `mod_depthcontent` view.php — dropdown or toggle alongside the existing depth-level selector.

7.3. When rendering a learning point:
- If user preference is "youth" and youth overlay exists: merge and render overlay content
- If user preference is "youth" but no overlay exists: render canonical with a note
- If user preference is "canonical" (default): render canonical content

7.4. The `content_json` field in the `depthcontent` table stores canonical content. Overlay content is stored in a new `depthcontent_adaptations` table:
```sql
CREATE TABLE depthcontent_adaptations (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    depthcontentid BIGINT NOT NULL,
    adaptation VARCHAR(50) NOT NULL,   -- 'youth', 'community', etc.
    content_json LONGTEXT NOT NULL,     -- Merged overlay content
    UNIQUE KEY (depthcontentid, adaptation)
);
```

7.5. Update `populate_courses.php` to populate both canonical and adaptation content.

**Verification:**
- [ ] User on saint.school can select "Youth Presentation" preference
- [ ] Selecting it shows youth-adapted content where available
- [ ] Points without youth overlay show canonical content seamlessly
- [ ] Switching back to "Canonical" shows original content
- [ ] Quiz items reflect the selected adaptation

---

### Phase 8 — ss.mayostudios.org Moodle Bootstrap

**Goal:** Mayo's Moodle instance running with youth-adapted courses.

**Depends on:** F29 Phase 6 (saintschool directory), F26 (OIDC architecture)

8.1. This phase is primarily executed by F29 Phase 6 (saintschool bootstrap). F30's contribution is:
- Supply built course packages from Phase 5
- Configure `mod_depthcontent` with youth adaptation as default
- Populate courses via `populate_courses.php` using mayo manifest

8.2. OIDC: mayostudios.org as identity provider → ss.mayostudios.org as client (per F26/F29 architecture).

8.3. Default adaptation preference set to "youth" for all users on ss.mayostudios.org.

8.4. Mayo-originated courses (MAYO-L01, etc.) installed alongside canonical courses.

**Verification:**
- [ ] ss.mayostudios.org Moodle running with courses from mayo manifest
- [ ] Youth-adapted content displayed by default
- [ ] OIDC login from mayostudios.org works
- [ ] Mayo-originated courses present and functional

---

### Phase 9 — avcommons.org Bootstrap (Federation Member)

**Goal:** Stand up `avcommons.org` as a **federation member** of the canonical AVC network — same code, same canonical course catalogue, member-specific manifest + adaptation overlay. Not a code fork.

**Depends on:** Phases 1-5 (course registry infrastructure), F26 (multi-domain OIDC)

9.1. Create AVC instance at avcommons.org running the canonical AVC profile (same code as nwpcom.org). Use A09 blueprint with `avc-member` context — a new context blueprint distinct from generic `community`, scoped to AVC member organisations and their internal formation needs.

9.2. Create Moodle instance at ss.avcommons.org.

9.3. OIDC: avcommons.org as provider → ss.avcommons.org as client. Per F26, avcommons.org is a peer issuer alongside nwpcom.org and mayostudios.org — multi-domain OIDC support is the prerequisite.

9.4. Create `adaptations/avc/` layer in `nwp/courses` repo:
- `adaptation.yaml` — layer metadata (name: avc, audience: "AV members", theme: avc)
- Initial overlays for the canonical courses where AV-specific framing is wanted
- AV-member-originated courses (`AVC-C01`, `AVC-C02`, …) live here as `member-only` content (not promoted to canonical)

9.5. Create `sites/avcommons.yaml` manifest — select canonical courses + the `avc` adaptation layer + member-only courses.

9.6. Build and deploy courses: `build-site-courses.sh --site avcommons`.

9.7. Contribution-back path: any AVC-member-originated content judged broadly applicable can be MR'd from `adaptations/avc/` into `courses/` (canonical) following the standard three-stage review. Member-only content stays in `adaptations/avc/` indefinitely — no second review burden, no fork drift.

**Verification:**
- [ ] avcommons.org AVC running on the same code as nwpcom.org (no code fork)
- [ ] `avc-member` blueprint context registered and applied
- [ ] ss.avcommons.org Moodle running with selected canonical + `avc` overlay courses
- [ ] Multi-domain OIDC login from avcommons.org → ss.avcommons.org works
- [ ] Site manifest respected (only selected courses deployed)
- [ ] At least one AVC-member-originated course visible only on ss.avcommons.org
- [ ] Canonical course updates flow to ss.avcommons.org without manual merge

---

### Phase 10 — Public Distribution (Optional)

**Goal:** Approved canonical courses available for broader distribution beyond the NWP network.

10.1. **MoodleNet channel:** Publish approved course packages to MoodleNet for discovery by other Moodle instances worldwide. This is a one-way publish (MoodleNet users can download; they cannot push changes back through MoodleNet — contributions come via git MR).

10.2. **Course pack downloads:** Public page on nwpcode.org listing available course packs with download links. Each pack is a signed tar.gz containing JSON files + import instructions for any Moodle instance.

10.3. **Moodle backup (.mbz) export:** For sites not using mod_depthcontent, provide standard Moodle backup files generated from the course content. These are less feature-rich (no depth levels, no inline quizzes) but broadly compatible.

10.4. **Documentation:** How to import NWP courses into any Moodle instance, with and without mod_depthcontent.

**Verification:**
- [ ] At least 5 course packs downloadable from nwpcode.org
- [ ] MoodleNet listing live (if MoodleNet is stable enough)
- [ ] .mbz export produces importable backups on stock Moodle
- [ ] Import documentation tested on a fresh Moodle instance

---

## 10. Success Criteria

### Phase 1
- [ ] `nwp/courses` repo on GitLab with 49 courses
- [ ] Schemas defined for courses, adaptations, and manifests
- [ ] nwpcom.yaml manifest lists all 49 courses
- [ ] Existing SS pipeline still works

### Phase 2
- [ ] Three-stage workflow template in AVC
- [ ] Learning point content type with workflow integration
- [ ] Review queue view showing pending items by stage

### Phase 3
- [ ] `theocat review` produces structured reports
- [ ] Vatican II source package installed and searchable
- [ ] Reports tested against 5 learning points

### Phase 4
- [ ] CI pipeline running on nwp/courses MRs
- [ ] Schema validation, copyright scan, theocat reports all functional
- [ ] COPYRIGHT HIGH-risk blocks merge

### Phase 5
- [ ] Build pipeline reads manifests and produces JSON
- [ ] Overlay merge works correctly
- [ ] Output compatible with populate_courses.php

### Phase 6
- [ ] 5 courses youth-adapted (A1-A5)
- [ ] All overlays pass three-stage review
- [ ] theocat confirms theological equivalence

### Phase 7
- [ ] Adaptation preference in mod_depthcontent
- [ ] Youth content renders on saint.school when selected
- [ ] Seamless fallback to canonical for non-overlaid points

### Phase 8
- [ ] ss.mayostudios.org running with youth-adapted courses
- [ ] OIDC from mayostudios.org working
- [ ] Default adaptation: youth

### Phase 9
- [ ] avcommons.org + ss.avcommons.org running
- [ ] Course manifest respected
- [ ] OIDC working

### Phase 10
- [ ] Public course packs downloadable
- [ ] Import documentation tested

---

## 11. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Overlay format too rigid for complex adaptations | Medium | Start with 5-course pilot (Phase 6); iterate format based on real experience before scaling |
| Youth rewrites inadvertently change doctrine | High | Theology check is mandatory for all adaptations; theocat report flags doctrinal divergence |
| Canonical content changes break overlays | Medium | `base_version` field in overlays; build pipeline warns on mismatch; overlay author notified |
| Three-stage review creates bottleneck (not enough reviewers) | Medium | Start with Rob as all three reviewers; expand as community grows; A06 tier gating applies (small sites need fewer stages) |
| theocat corpus gaps produce false negatives (unverified quotes pass) | Low | Report clearly shows "not in corpus" vs "verified"; theology reviewer checks manually; corpus expanded over time |
| Schema migration for existing 49 courses | Low | Phase 1 is a file move, not a rewrite; existing YAML format is the canonical format |
| mod_depthcontent adaptation table adds complexity | Low | Single new table with simple schema; population handled by existing populate script |
| MoodleNet instability or deprecation | Low | MoodleNet is Phase 10 (optional); git distribution is primary and unaffected |
| avcommons.org server provisioning | Medium | Same Linode infrastructure as other sites; follows established patterns |

---

## 12. Dependency Graph

```
Phase 1 (course repo)       Phase 2 (workflow)      Phase 3 (theocat review)
    │                            │                        │
    └────────────┬───────────────┘                        │
                 │                                        │
             Phase 4 (CI validation) ◄────────────────────┘
                 │
             Phase 5 (build pipeline)
                 │
             Phase 6 (youth pilot: A1-A5)
                 │
             Phase 7 (mod_depthcontent adaptation pref)
                 │
        ┌────────┼────────────────┐
        │        │                │
    Phase 8   Phase 9         Phase 10
    (ss.mayo)  (avcommons)    (public dist)
```

Phases 1, 2, and 3 can run in parallel. Phase 4 requires 1 and 3. Phases 8, 9, and 10 can run in parallel after Phase 7.

---

## 13. Effort Estimates

| Phase | Effort | Notes |
|---|---|---|
| Phase 1 | Medium (2-3 days) | File migration, schema definition, repo setup |
| Phase 2 | Small (1 day) | Drupal configuration, content type, view |
| Phase 3 | Medium (2-3 days) | Python development, Vatican II source, testing |
| Phase 4 | Medium (1-2 days) | GitLab CI, scanner adaptation |
| Phase 5 | Medium (2-3 days) | Merge logic, build script, packaging |
| Phase 6 | Large (1-2 weeks) | Content creation for ~25 learning points, review |
| Phase 7 | Small (1-2 days) | Moodle plugin extension, DB table |
| Phase 8 | Medium (2-3 days) | Coordinated with F29 Phase 6 |
| Phase 9 | Medium (3-5 days) | New AVC + Moodle instance |
| Phase 10 | Small (1-2 days) | Optional; packaging and documentation |

---

## 14. Relationship to Other Proposals

| Proposal | Relationship |
|---|---|
| **S05** (Cognitive Redesign) | **Foundation.** S05's learning-point YAML format, 6 depth levels, and mod_depthcontent are the canonical content format that F30 distributes. |
| **S06** (Inline Quizzes) | **Included.** Quiz items in the YAML are part of the distributed content. SM-2 state is per-user per-site (not shared). |
| **S07** (Copyright Compliance) | **Integrated.** copyright_scan.py becomes a CI gate in the nwp/courses pipeline (Phase 4). |
| **S03** (Open Dogmatics) | **Consumed.** Theological grade data feeds theocat review reports (Phase 3). |
| **S02** (Pseudo-Catechism) | **Consumed.** Learning point enrichment content included in depth levels. |
| **A02** (Workflow System) | **Extended.** Workflow_assignment module powers the three-stage review. A02's versioning and re-edit support apply to learning point content entities. |
| **A09** (Blueprints) | **Leveraged.** Blueprint contexts (mayo, parish, community) determine which courses a site selects. The `avc_moodle` specialist module handles course sync. |
| **F26** (OIDC) | **Prerequisite.** Cross-site SSO enables users to access courses on any Moodle instance with a single account from their AVC site. |
| **F28** (Unified Pipeline) | **Prerequisite.** Signed-artifact distribution pipeline delivers course packages to production Moodle instances via mons. |
| **F29** (Mayo Integration) | **Coordinated.** F29 Phase 6 (saintschool bootstrap) provides the Moodle instance that F30 Phase 8 populates with courses. |
| **F21** (Distributed Pipeline) | **Infrastructure.** Build/sign/deploy infrastructure that F30 uses for course package distribution. |
| **A03** (OAuth2 + Coders Guild Sync) | **Parallel.** A03 handles developer identity; F30 handles content identity. Both use AVC as the identity provider. |

---

## 15. Acceptance

This proposal is done when:

1. All 49 canonical courses live in `nwp/courses` with working CI validation.
2. The three-stage review workflow is operational in AVC with at least one learning point having passed all three stages.
3. `theocat review` produces accurate reports and runs in CI.
4. At least 5 courses have approved youth adaptations.
5. A user on saint.school can switch between canonical and youth presentation.
6. ss.mayostudios.org serves youth-adapted courses with OIDC from mayostudios.org.
7. The build pipeline produces correct, signed course packages for each site from their manifests.
8. A new site (avcommons.org or other) can be bootstrapped by creating a manifest and running the build pipeline — no bespoke course setup required.
9. The Domain Rollout (§16) reaches Phase 2 — `nwpcom.org` and `saint.school` serving prod with multi-domain OIDC operational; `avc.nwpcode.org` retired.

---

## 16. Domain Rollout

The federation operates across multiple domains that are migrating from test (`*.nwpcode.org`) to prod (`*.nwpcom.org`, `saint.school`, `avcommons.org`, `mayostudios.org`). This section captures the domain-state machine so that manifest paths, OIDC client configs, and signed-package distribution endpoints stay coherent across the cutover.

### 16.1 Domain inventory

| Role | Test (today) | Intermediate test | Production (target) |
|---|---|---|---|
| Canonical AVC site | `avc.nwpcode.org` | `nwpcode.org` | **`nwpcom.org`** |
| Canonical Moodle | `ss.nwpcode.org` | `ss.nwpcode.org` | **`saint.school`** (alias `saintschool.org`) |
| Code distribution | `git.nwpcode.org` | `git.nwpcode.org` | **`git.nwpcom.org`** |
| Youth member AVC | n/a | `mayostudios.org` | `mayostudios.org` |
| Youth member Moodle | n/a | `ss.mayostudios.org` | `ss.mayostudios.org` |
| AVC member site | n/a | `avcommons.org` | `avcommons.org` |
| AVC member Moodle | n/a | `ss.avcommons.org` | `ss.avcommons.org` |

Member domains (`mayostudios.org`, `avcommons.org`) are stable across the cutover — only the canonical AVC + Moodle + git domains change.

### 16.2 Phased cutover

**Phase 0 — Today (test mapping).** `avc.nwpcode.org` is the live AVC test site, `ss.nwpcode.org` is its Moodle pair, `git.nwpcode.org` is the code/content host. F30 development happens against these domains under an explicit mapping:

| Logical role (production) | Acted by (today, test) |
|---|---|
| `nwpcom.org` — canonical AVC + governance | `nwpcode.org` (Phase 1+) / `avc.nwpcode.org` (today) |
| `saint.school` — canonical Moodle library | `ss.nwpcode.org` |
| `git.nwpcom.org` — code + course registry | `git.nwpcode.org` |

Reviewers, the editorial loop (§6.6), and the build pipeline all run against this mapping. F30 manifests, OIDC client configs, and signed-package URIs use the test domains during Phase 0–1 and only swap to production names at Phase 2 cutover. Anywhere this proposal says "nwpcom.org" or "saint.school" without qualification, read it as "the production target — currently acted by the test domain in the table above."

**Phase 1 — Test consolidation.** Move the AVC test site from `avc.nwpcode.org` to `nwpcode.org` (root domain). `ss.nwpcode.org` stays. `git.nwpcode.org` stays. Goal: prove the canonical AVC profile on a clean root domain before the prod cut. F30 manifests still reference `nwpcode.org` / `saint.school` (logical names) — only DNS/server config changes.

**Phase 2 — Prod cutover.** Stand up `nwpcom.org`, `saint.school` (with `saintschool.org` redirect), `git.nwpcom.org`. Migrate the AVC instance, Moodle instance, and GitLab project namespace. `git.nwpcode.org` is aliased to `git.nwpcom.org` for a transition window so existing remotes/clones keep working; new clones use `git.nwpcom.org`. Update OIDC issuer URLs (F26) for all member sites. Retire `avc.nwpcode.org`.

**Phase 3 — Member onboarding.** Stand up `avcommons.org` + `ss.avcommons.org` per Phase 9. Mayo (`mayostudios.org` + `ss.mayostudios.org`) joins per F29. Both register as OIDC clients of `nwpcom.org` and as content consumers of `nwp/courses` on `git.nwpcom.org`.

### 16.3 Manifest / config naming convention

F30 references **logical site names** (`nwpcom`, `saint.school`, `avcommons`, `mayo`) rather than current physical hostnames. This means:

- `sites/nwpcom.yaml` is the canonical manifest, not `sites/avc.nwpcode.org.yaml` — the manifest survives the cutover unchanged.
- Build commands use logical names: `build-site-courses.sh --site nwpcom`, not `--site avc.nwpcode.org`.
- Physical hostnames live in deployment config (DNS, Nginx, OIDC client URIs), not in F30 manifests.

This decoupling lets the test→prod cutover be a deployment change, not a content-pipeline change.

### 16.4 Cross-cutting effects

- **F26 (OIDC):** Multi-domain OIDC is required for federation. F26 must support multiple issuer/client domains and survive the `nwpcode.org` → `nwpcom.org` issuer rename. Every OIDC client config (Moodle plugin, member-site auth) needs a config update at Phase 2.
- **F28 (signed pipeline):** Package distribution endpoint changes from `git.nwpcode.org` (Packages) to `git.nwpcom.org` at Phase 2. Existing signatures stay valid (they sign the artifact, not the URL); only the download URL changes.
- **F29 (mayo integration):** Mayo's `ss.mayostudios.org` consumes course packages from `git.nwp{code,com}.org` per the active phase. Mayo's OIDC client for `mayostudios.org` ↔ `ss.mayostudios.org` is internal to mayo and unaffected by the canonical cutover.
- **DNS aliasing:** `git.nwpcode.org` → `git.nwpcom.org` alias kept indefinitely (or until measured zero traffic). `avc.nwpcode.org` retired with 301 → `nwpcom.org`. `ss.nwpcode.org` retired with 301 → `saint.school`.
- **Member domains:** No change required at Phase 2 cutover — `avcommons.org` / `mayostudios.org` re-point their OIDC trust to `nwpcom.org` and their content source to `git.nwpcom.org`. One config edit per member.

### 16.5 Risk

The biggest risk is OIDC issuer rename mid-flight. Mitigation: stand up `nwpcom.org` OIDC alongside `nwpcode.org` OIDC (dual-issue) for the cutover window, retire `nwpcode.org` issuer only after every member has migrated.
