# The nwc ↔ ssc paired-site architecture

> **Audience:** an operator who knows NWP basics (sites, tiers, `pl`, canonical
> phases) but has not worked on the paired-site subsystem. **Scope:** the single
> place that answers three questions —
> **(A)** how nwc and ssc code stays *in sync*,
> **(B)** what the *generic/canonical* layer is vs the *adapter/overlay* layer (and
> how the SSO + boundary mechanics work), and
> **(C)** how *site-specific content* is stored and how it flows.
>
> This is a **synthesis + map** doc. It does not restate the deep detail of the
> ADRs and runbooks it cross-links — it tells you what each piece is, how they fit,
> and where the sharp edges are. Every claim is traceable to a file cited inline.
>
> **Primary sources:** [NWP-ADR-0031](../decisions/0031-paired-site-versioning-and-promotion.md)
> (paired-site versioning), [NWP-ADR-0027](../decisions/0027-unified-course-content-architecture.md)
> (unified course content), [NWP-ADR-0029](../decisions/0029-nwc-authorization-model.md)
> (nwc authorization), the pair contract `private/pairs/ssc.pair-contract.yml` (the private overlay repo — ops#326; sample shape: [`pairs/ssd.pair-contract.yml`](../../pairs/ssd.pair-contract.yml)),
> the guard [`lib/pair.sh`](../../lib/pair.sh), the boundary classifier
> [`lib/boundary.sh`](../../lib/boundary.sh), and the two runbooks
> [`ops75-pair-contract-schema.md`](ops75-pair-contract-schema.md) and
> [`moodle-promotion-substrate.md`](moodle-promotion-substrate.md).

---

## 0. The pair in one paragraph

**nwc** is the Drupal / Open Social 13 "2.0" community platform — the un-forked
canonical site (covers avc ∪ nwc). **ssc** ("Saint School Canonical") is a
**Moodle** LMS with **real students**, paired to nwc. They live on two different
stacks that *cannot* share a package or a deploy mechanism, but they are coupled
by a narrow contract: **OIDC single-sign-on**, **copyright-policy sync**, a
**feedback bridge**, and a few read/sync surfaces. nwc is the **provider**
(OIDC issuer, copyright source, feedback sink); ssc is the **consumer** (SSO
client, real learning records). A demo twin pair, **nwd ↔ ssd**, mirrors the
topology but carries no real users and is uncoupled
([`pairs/README.md`](../../pairs/README.md) lines 24–33).

The load-bearing correction that shapes everything below (NWP-ADR-0031 Context,
"The framing correction"): **"two sites move in lockstep" is the wrong model.**
There are **five planes** with three different movement patterns, and only a
*narrow, versioned contract* actually couples the pair.

---

## The two boundaries (read this first)

Two orthogonal boundaries run through the whole system. Conflating them is the
"category error of the last three months of docs" that NWP-ADR-0027 §2 exists to
kill. Keep them separate in your head:

```
  COMMUNITY / INTERACTION boundary            CONTENT boundary
  (safeguarding — isolates PEOPLE)            (isolates NOTHING for safeguarding)
  ─────────────────────────────────           ─────────────────────────────────
  • minors ✕ interact-with unchecked adults   • content flows freely once checked
  • per-site community + its own user base     • receiver VERIFIES provenance
  • OIDC trust chains (F26)                      (a signature), does not re-review
  • two-tier sanitization                      • attributed to the MEMBER, CC0
```
*(NWP-ADR-0027 §2, lines 88–107; NWP-ADR-0029 Implementation Notes lines 163–167.)*

- The **community/interaction boundary** is a *people* boundary. It is where the
  OIDC SSO + UID-lock, sanitization, and guild membership live. This is what
  couples nwc↔ssc — it is the subject of §A and §B below.
- The **content boundary** isolates *nothing* for safeguarding: content that
  cleared its origin's checks flows freely; a receiver *verifies a signature*
  rather than re-reviewing. This is the subject of §C.

NWP-ADR-0029 is the authorization companion to NWP-ADR-0027: NWP-ADR-0027 severs *individual
identity* at the site boundary (member-level, CC0); NWP-ADR-0029 ensures the *acting
identity inside* a site is authentic and authorized (NWP-ADR-0029 lines 163–167).

---

## The five-plane model (the shared vocabulary)

Any tool, guard, or runbook that says "promote the pair" must say **which
plane** it moves. This table is NWP-ADR-0031's authoritative decomposition
(NWP-ADR-0031 Context lines 68–80, Decision D1 lines 132–136):

```
  #    PLANE                         TRUTH LIVES IN            MOVES              DISPOSABLE?
  ───────────────────────────────────────────────────────────────────────────────────────
  1    Drupal code (nwc)             nwp/nwc git repo          up the tiers       yes (rebuildable)
                                                               (git; P67 maturity)
  2    Drupal site content           one env's DB, declared    content pushes up  NO — it IS the
       (community DB)                by canonical: (nwc=dev)    / DB pulls DOWN    community; holds
                                                               (sanitized)         in-flight editorial
  3    Moodle code (ssc plugins)     GitLab plugin repos +     manifest+installer yes (once repos
                                     pinned Moodle core tag     into site trees    are fixed)
  4    Formation content             nwp/courses YAML + JSON    git MRs; rendered  it's the canon
       (canonical courses)           Schema (NWP-ADR-0027)          SIDEWAYS
  5a   Moodle rendered course rows   none (projection of 4)    --clear re-render  yes (NWP-ADR-0027 D1)
  5b   Moodle learning/user state    the ssc LIVE DB +         never regenerated; ABSOLUTELY NOT
       (accounts, attempts, grades,  moodledata                backup/restore     — PII, minors'
       badges, policy acceptances)                              only              records
```

Three movement patterns, and a paired promotion scheme must respect all three
(NWP-ADR-0031 lines 77–80):

- **code flows UP** (git, dev → stg → live → prod) — planes 1, 3
- **site content flows DOWN** (sanitized DB pulls) — plane 2
- **formation content flows SIDEWAYS** (canonical repo → rendered into whichever
  environment as a pure function) — plane 4 → 5a

**Why this matters:** "content" used to mean four different things (community DB,
canonical courses, rendered rows, learning records) with four different sync
semantics. Name the plane and the confusion disappears.

---

## A. How nwc ↔ ssc **code** stays in sync

### A.1 The wrong answers, and the chosen one

NWP-ADR-0031 rejected two tempting models (Options 1–2, lines 106–129):

- **Collapse into one versioned unit** (one tag, one release) — *impossible across
  stacks*: a Drupal profile and Moodle plugins can't share a package or deploy
  mechanism. It works only for *same-stack* twins (nwc/nwd already share
  `nwp/nwc`; ssc/ssd share one plugin set).
- **Atomic two-site promotion transaction** — distributed-transaction machinery
  across two stacks, two DBs; a failed half still strands live users on mismatched
  halves; doubles every deploy's blast radius; complicates the single-site,
  security-critical deploy gate.

The chosen model (Option 3, NWP-ADR-0031 D2/D5, lines 121–129 & 138–205):

> **Version the *contract*, not the pair.** Add per-surface minimum counterpart
> versions + expand-contract discipline + **provider-first ordering** + a **pair
> smoke suite** as the safety net. Each side stays independently deployable and
> rollback-able; brief version-skew windows are *normal* and *observable*, not
> faults.

### A.2 The pair contract — the central artifact

One YAML file per pair, named by the **consumer** key, lives in `pairs/`:
`private/pairs/ssc.pair-contract.yml` (the private overlay repo — ops#326; sample shape: [`pairs/ssd.pair-contract.yml`](../../pairs/ssd.pair-contract.yml)) (nwc↔ssc) and
`pairs/ssd.pair-contract.yml` (nwd↔ssd). It is **committable** — it holds only
`contract_version`, per-surface minimum versions, per-tier public issuer URLs,
smoke URLs, and the boundary manifest. **No secrets** (contract header lines 8–9;
[`pairs/README.md`](../../pairs/README.md) lines 12–13). Deployed-version + RAG
**state** lives elsewhere, in gitignored `private/pairs/`.

The key fields (`private/pairs/ssc.pair-contract.yml`, overlay — ops#326):

| Field | Line(s) | What it declares |
|---|---|---|
| `contract_version` | 21 | monotonically increasing **integer**; a bump = an expand-contract change |
| `provider: nwc` / `consumer: ssc` | 22–23 | roles (OIDC issuer / SSO client) |
| `dependencies.*` | 26–28 | F28 signed-bundle linkage (`nwc@0.5.0`, `auth_nwc@1.0.0`) |
| `surfaces.*` | 31–80 | per-surface `provider_min` / `consumer_min` versions + JSON-Schema pin |
| `boundary.*` | 101–161 | per-surface path/symbol map — the change-impact source of truth (§B.3) |
| `identity.*` | 164–192 | the UID-lock, coupled tiers, sub-stability, restore invariant |
| `policy.*` | 194–197 | single-writer copyright rule |
| `endpoints.*` / `oidc.*` | 208–279 | per-tier OIDC issuer URLs + the concrete F26 wiring |
| `smoke_urls.*` | 284–312 | the 5-URL post-promotion check |

The **seven real surfaces** (contract lines 31–80): `oauth_sso`, `copyright_sync`,
`feedback_bridge`, `erasure`, `role_cohort_sync`, `badge_read`, `shared_salt`.
(P74 Phase 1 note, contract lines 58–62: three of the seven were *live but
undeclared* before P74 — declaring them makes the change-impact gate see the
whole boundary.) Each surface may carry a `schema:` path into
[`contracts/`](../../contracts/) plus a `schema_sha256:` pin.

### A.3 The guard — `pair_guard` (`lib/pair.sh`)

[`lib/pair.sh`](../../lib/pair.sh) is a deploy-time choke-point that reads the
contract + both sides' recorded deployed versions and refuses an unsafe
promotion. It runs at the same choke-points as the other guards, in this order
(NWP-ADR-0031 D5 lines 187–190): `canonical_guard_content_push` →
`maturity_guard_deploy` → **`pair_guard`** → `deploy_gate_require`.

Its properties (`lib/pair.sh` header lines 11–35):

- **Off-unless-configured.** A site with no `paired_with:` and nothing pointing
  at it is a no-op — `pair_guard` returns 0 immediately. Pairing is opt-in: the
  single key `paired_with: nwc` in the global `nwp.yml` turns it on
  (`pairs/README.md` lines 36–60).
- **Fail-closed.** Once a site is declared paired, a **missing or unparseable
  contract refuses the deploy** (soften with `NWP_PAIR_GATE_SOFT=true` only while
  authoring; `lib/pair.sh` lines 327–343).
- The checks it enforces (`lib/pair.sh` `pair_guard()` lines 311–440):
  1. **Provider-first ordering** (D5): a consumer promotion whose
     `contract_version` exceeds the provider's recorded version at that tier is
     refused — deploy nwc first, then ssc (lines 382–401).
  2. **Schema-pin integrity** (P74 Phase 3): if a surface's `schema_sha256` no
     longer matches the on-disk `contracts/*.schema.json`, refuse — the wire shape
     drifted from the pinned contract (lines 350–369).
  3. **UID-lock / `--code-only` rule** (D6): a full-DB push to an
     identity-coupled `live`/`prod` tier is refused for **either** half — see §Gotchas
     (lines 402–424).
  4. **Red-pair block**: while the last pair-smoke is RED, promotion of either
     half is refused (lines 371–379).
  - Every refusal has a loud, **ledgered** `--override-pair` escape
    (`private/pairs/<pair>.log`).

A parallel `pair_guard_restore()` (`lib/pair.sh` lines 550–676) governs **DB
restore/rebuild** at a coupled tier — the *both-or-forward* invariant (§Gotchas,
NWP-ADR-0031 D9).

`pair_guard_record_success()` (lines 446–460) is called by the deploy verbs on
success to record which `contract_version` each side reached at each tier, so the
ordering check has data to compare.

### A.4 Inspection + smoke commands

From [`ops75-pair-contract-schema.md`](ops75-pair-contract-schema.md) §0 and
`pairs/README.md` lines 62–71 (all network-free with `--dry-run`):

```
pl pair list                    # shows nwc↔ssc, nwd↔ssd once paired_with is set
pl pair status ssc              # both sides' recorded contract_version vs the contract
pl pair check ssc live          # dry-run pair_guard's decision for a tier
pl pair-smoke ssc --dry-run     # print the 5-URL plan; touches NO network by default
```

The **pair smoke suite** (`scripts/commands/pair-smoke.sh`) runs the contract's
`smoke_urls` (contract lines 284–312) after any promotion of either half; a
failure sets the pair RAG red, which `pair_guard` then blocks on (NWP-ADR-0031 D5
lines 191–194). The safety net is **observation, not a transaction**.

### A.5 Versioning + multi-repo coordination

- **Tagging (D3, NWP-ADR-0031 lines 153–165):** `nwp/nwc` uses a single `vX.Y.Z`
  scheme (the old `nwc/v*` scheme is retired); a tag is cut whenever
  `composer.json`'s version changes. Moodle plugin repos tag `vX.Y.Z` matching
  `$plugin->release` (the `YYYYMMDDXX` `$plugin->version` stays the Moodle-native
  key). `pre-*` rollback anchors are out-of-band, never pushed.
- **Repo boundaries (D4, lines 167–179):** on the Moodle side the **plugins are
  the versioned unit**, not the site trees. Site trees stay upstream-Moodle clones;
  plugins deploy via a manifest + installer with a per-tree lockfile — see
  [`ops73-moodle-plugin-manifest-design.md`](ops73-moodle-plugin-manifest-design.md).
- **Multi-MR coordination (D7, lines 222–235):** one **ops issue per cross-site
  change** is the transaction; the **same branch name `ops-N` in every affected
  repo**; each MR body carries a "Pairs with `<repo>!<iid>`" line; **merge order =
  provider first, same day** for contract-bump MRs. (The onboarding `paired/<x>-<y>`
  branch convention was retired unbuilt; a `paired` label carries the semantics.)

---

## B. The generic/canonical layer vs the adapter/overlay layer

There are **two different "generic vs specific" splits** in play. Do not confuse
them:

1. **Within one site** (nwc alone): *generic package* (`nwp/nwc`) vs *your
   instance* (config + content). This is [`nwc-fork-guide.md`](nwc-fork-guide.md).
2. **Across the pair** (nwc + ssc): the *canonical content model* (one source,
   many disposable render targets) vs the per-target *adapters/overlays*. This is
   NWP-ADR-0027.

### B.1 Within-site: generic package vs instance (nwc-fork-guide)

The rule ([`nwc-fork-guide.md`](nwc-fork-guide.md) §1, §3): **behaviour/structure
→ the generic package; content/identity → your private instance.**

| Layer | Repo | Holds |
|---|---|---|
| **Generic package** | `nwp/nwc` (public, versioned) | modules (engines/behaviour), the 9-tier `recipes/`, *template* content, `[nwc:*]` tokens |
| **Your instance** | a private root project (`nwp/nwc-project`) | `composer.json` requiring `nwp/nwc`, `config/sync/`, `settings.php`, your legal texts, a content-seed manifest |
| **Content + files** | not git | the DB (nodes, guilds, users) + uploaded files |

A fresh `recipes/full` install with no demo and no content **is** the generic
platform — the "anyone can install" guarantee. The ~40 nwc modules live under
`sites/nwc/dev/html/profiles/custom/nwc/modules/nwc_features/` (e.g. `nwc_oidc_claims`,
`nwc_copyright`, `nwc_moodle`, `nwc_editorial`, `nwc_guild`, `nwc_feedback`).

### B.2 Across-pair: canonical content, disposable adapters (NWP-ADR-0027)

The single source of truth for *formation content* (plane 4) is **`nwp/courses`**:
authored in YAML, distributed as JSON, contracted by a JSON Schema. **Every render
target is a pure function of canonical JSON and is disposable** (NWP-ADR-0027 D1,
lines 62–85):

```
              CANONICAL STORE — nwp/courses (git)  [YAML → JSON → JSON Schema]
                                     │  build = pure function
              ┌──────────────────────┼──────────────────────┐
              ▼                       ▼                      ▼
     ss mod_depthcontent       Flutter courses.db      nwc / Drupal
     (Moodle — disposable)     (offline app)           (community + render)
              └──────── all honour the SAME render contract ────────┘
```

The Moodle rows are plane 5a — re-rendered with `populate_courses.php --clear`;
**nothing authored *in* Moodle survives** (NWP-ADR-0027 clarification 1, lines 43–45).
A member site (mayo, avcommons, future) is a **federation member**: same canonical
code, its own community, its own manifest + an `adaptations/<member>/` overlay
carrying only what differs — **not a git fork** (NWP-ADR-0027 D3, lines 109–117).

### B.3 The boundary between generic and adapter — mechanized

`lib/boundary.sh` is the **change-impact classifier** — the sibling of
`lib/impact.sh` ("what does this destructive verb destroy?"). `boundary.sh`
answers "**does this diff touch the nwc↔ssc boundary?**"
([`lib/boundary.sh`](../../lib/boundary.sh) lines 4–16). It is a pure
**set-intersection** of the diff's changed files against the pair contract's
`boundary:` block globs — **one declared source of truth, no hardcoding**. It
**classifies only, never blocks** (`pl impact` always exits 0), and is
**fail-safe closed**: if the diff can't be computed, the change is treated as
BOUNDARY-TOUCHING (lines 13–16).

The `boundary:` block (contract lines 101–161) maps each surface to
`provider_paths` (nwc modules), `provider_symbols` (private classes/services), and
`consumer_paths` (the *external* Moodle plugin repo). A `test-boundary-honesty`
bats suite fails if a declared-private symbol is referenced from outside its
surface's paths (contract lines 91–96).

### B.4 The SSO mechanics (F26 OIDC — the coupling itself)

This is the concrete wiring of the community/interaction boundary. It was
**stood up by hand on live and proven end-to-end on 2026-07-11** (a nwc user
logged into ssc; the Moodle `idnumber` equalled the nwc `sub` — the UID-lock held).
The full runbook is [`moodle-promotion-substrate.md`](moodle-promotion-substrate.md)
§"F26 OIDC end-to-end runbook"; the codified facts are in the contract's `oidc:`
block (lines 217–279). The load-bearing facts:

- **nwc is the OIDC provider** via Drupal `simple_oauth`; **ssc consumes** it with
  the **`auth_nwc`** Moodle plugin (authtype `nwc`) — the *genuine* UID-lock
  plugin, **not** the lock-less `auth_nwc_oauth2` decoy (contract lines 225–226).
- **nwc exposes no discovery document** (`/.well-known/openid-configuration` = 404).
  Endpoints are set **manually** on the Moodle issuer (contract lines 228–236):
  `/oauth/authorize`, `/oauth/token`, `/oauth/userinfo` (native `simple_oauth`),
  and JWKS at **`/.well-known/jwks.json`** — **not** `/oauth/jwks`, which 301s and
  silently breaks signature verification.
- **The UID-lock**: `sub → idnumber` is the mandatory field mapping. Without it
  `auth_nwc` **denies every login** (fail-closed; contract lines 243–249). This
  locks `mdl_user.idnumber == OIDC sub == nwc Drupal account`.
- **`sub` is the Drupal account UUID, not the serial uid** (NWP-ADR-0031 D9(A),
  contract lines 172–177). The UUID is row-stored, never renumbered, never reused —
  so the lock survives a *within-half* renumber/rebuild/migrate. This is
  live-proven on the empty-seed nwc live tier.
- **Key rotation is safe** (ops#82, contract lines 262–279): Moodle's
  `auth_oauth2`/`auth_nwc` take claims from the **userinfo** endpoint and **do not
  verify the id_token signature against JWKS**, so a signing-key swap does not break
  SSO. Trust anchors = TLS + confidential client + PKCE(S256) + bearer userinfo. See
  [`ops82-key-rotation.md`](ops82-key-rotation.md).

The Moodle **promotion substrate** (`lib/moodle-promote.sh`, NWP-ADR-0031 D8) is the
Moodle analogue of the Drupal `settings.php` rewrite + `drush cr`: it writes
`config.php`, plans the `$CFG->wwwroot` rewrite, generates the vhost, and emits the
OIDC descriptors — all **fail-closed and off-unless-configured**, refusing any tier
that is not dev/stg/test (a live/prod Moodle root holds plane-5b records and is
never rewritten by the pipeline). Details:
[`moodle-promotion-substrate.md`](moodle-promotion-substrate.md).

The other coupling surfaces:

- **Copyright sync** (plane 2 → 5b, single-writer): `nwc_copyright vN` →
  `local_nwc_copyright_sync` → Moodle `tool_policy_versions` → student re-consent
  events. **One writer, both paths read** (`policy.writer: nwc_copyright`, contract
  lines 194–197; NWP-ADR-0031 D2(b)). Never dual-write — that is the ops#31 race.
- **Feedback bridge** (ssc → nwc): the consumer POSTs; nwc is the sink.
- **Erasure** (nwc → ssc, ops#81): a signed OP→RP right-to-be-forgotten channel —
  destructive, single-writer, idempotent. See [`ops81-erasure-channel.md`](ops81-erasure-channel.md).
- **role_cohort_sync / badge_read / shared_salt**: guild roles pushed into Moodle
  cohorts (matched by email/username — a *different* join key than the OIDC
  UID-lock; contract lines 63–68 flag the silent-break risk), Moodle badges read
  back for Drupal display, and a shared sanitizer salt so a real email maps to the
  *same* fake on both stacks (keeping the OIDC join alive in dev/stg; contract
  lines 74–80).

---

## C. How **site-specific content** is stored

"Site-specific content" is again two different things — keep the planes straight:

### C.1 nwc community content (plane 2)

The nwc **community DB** (nodes, guilds, users, in-flight editorial state) is
**not disposable — it *is* the community** (NWP-ADR-0031 plane table, line 71). It
lives in one environment's DB, declared by the site's `canonical:` phase
([`lib/canonical.sh`](../../lib/canonical.sh) header lines 3–24):

- `canonical: dev` — dev DB is the source of truth; dev→live content pushes are
  *allowed*. **nwc is `canonical: dev` today.**
- `canonical: live` — live is the source; dev receives a *sanitized* copy; dev→live
  content pushes are *refused*.

Per the fork-guide (§B.1), the *content itself* is never in the package git: it
arrives as recipe-template content, a content-seed manifest, or a sanitized DB
copy. The operator's private instance holds `config/sync/`, `settings.php`, and
the site's legal texts — never the `nwp/nwc` package.

### C.2 ssc learning/user state (plane 5b)

ssc's **learning records** — accounts, enrolments, quiz attempts, grades, badges,
`tool_policy` acceptances, and `moodledata` files — are **plane 5b: absolutely not
disposable** (minors' PII; NWP-ADR-0031 plane table, line 75). They are **never
regenerated** — backup/restore + (future) sanitized pulls only. For ssc,
`canonical: live` (real students → user state is canonical there;
`pairs/README.md` lines 52–56). The **Moodle sanitizer is security-critical** and
gets the same human-review treatment as auth code, with fail-closed default
(NWP-ADR-0031 D8, lines 237–244). ⚠ `moodledata` is in **zero backups today** and must
join the backup surface (D8; substrate doc TODO #8).

### C.3 formation content (plane 4) — the shared canon

Formation *courses* are **not** site-specific: they are the canonical
`nwp/courses` store rendered *sideways* into each target (§B.2). The Moodle course
rows (plane 5a) are a disposable projection; the durable per-student state
(plane 5b) hangs off them, which is *only* safe because the join key is id-stable
(`render_id_stability.join_key: canonical_id`, contract lines 199–203; NWP-ADR-0027
§7). Cross-site sharing of member-contributed content rides the two rails
(NWP-ADR-0027 D8, lines 197–204): **within the fleet**, the P65/ops#32 seed-content
lifecycle (`nwc-content:update` delivers DRAFT revisions, skipping locally-modified
content); **cross-trust-boundary**, the F28 signed pipeline + F26 OIDC, with
member-level CC0 attribution and identity severed at the site boundary.

---

## Gotchas (the sharp edges)

1. **`--code-only` for nwc live/prod deploys — the standing rule.** While ssc
   students hold UID-locks against nwc's live tier, a **full-DB `pl stg2live nwc` /
   `stg2prod nwc` is forbidden** — it would renumber Drupal uids and silently sever
   *every* ssc SSO identity. `pair_guard` enforces this for **both** halves at
   coupled tiers (`lib/pair.sh` lines 402–424; NWP-ADR-0031 D6 + Immediate hazard note
   lines 293–298; `identity.coupled_tiers: [live, prod]`, contract lines 169–171).
   Use `--code-only`. On the consumer half the same full-DB refusal protects real
   students' plane-5b records. This holds even though nwc is `canonical: dev`
   (which would otherwise *legally allow* a full-DB push — that is exactly the
   hazard the guard closes).

2. **Provider-first ordering on a contract bump.** When `contract_version` bumps,
   **nwc (provider) promotes before ssc (consumer)** at a tier; a consumer
   promotion past its provider is refused (`lib/pair.sh` lines 382–401; NWP-ADR-0031
   D5). Merge order for contract-bump MRs is likewise provider-first, same day
   (D7). Between the two promotions the halves run different code — this skew is
   **normal and observable**, not a fault; contract-surface changes must be
   **expand-contract** (backward compatible) so ordering is otherwise free.

3. **`contract_version` is an integer, bumped on expand-contract changes only.**
   It is not a semver of either half — it versions the *contract*. Bump it when you
   add/remove a surface claim or endpoint; keep the change backward-compatible
   (add new form → update both sides in either order → remove old form one release
   later). The per-surface `provider_min`/`consumer_min` fields carry the actual
   version constraints.

4. **Restore ≠ code rollback (both-or-forward).** NWP-ADR-0031 D5's "rollback is safe
   per-site" covers **code** (git revert). It does **not** cover a **DB
   restore/rebuild that renumbers uids** at a coupled tier — that can orphan every
   consumer UID-lock. `pair_guard_restore()` fails closed unless a provider identity
   ledger + consumer join-snapshot exist and the restored anchor is **≥** the
   counterpart's (NWP-ADR-0031 D9; `lib/pair.sh` lines 550–676; runbook
   [`ops83-dr-restore.md`](ops83-dr-restore.md)).

5. **JWKS path trap.** The signing-health probe is `/.well-known/jwks.json` (200) —
   **not** `/oauth/jwks`, which 301-redirects and silently breaks token signature
   verification (contract lines 234–236, 287–291).

6. **`sub → idnumber` is mandatory.** Miss the field mapping and `auth_nwc` denies
   *every* login (fail-closed edge; contract lines 243–249).

7. **Copyright: single-writer only.** Never dual-write `nwc_copyright` version
   fields — a spurious bump forces a sitewide student re-consent (the ops#31 race;
   contract lines 194–197).

---

## Discrepancies & caveats found while writing this (verify before relying)

These are places where sources disagree or a doc is stale — flagged rather than
silently reconciled:

1. **NWP-ADR-0031 calls the OIDC wiring a "STUB / F26-gated / not implemented"**
   (NWP-ADR-0031 lines 99–102, 348–351; `lib/pair.sh` lines 37–40), but the **pair
   contract and the substrate runbook say it is LIVE-PROVEN 2026-07-11**
   (contract lines 217–223; `moodle-promotion-substrate.md` §F26 runbook). The ADR
   (2026-07-10) simply predates the live proof (2026-07-11); treat the contract +
   substrate doc as the current truth. The contract even annotates the older
   "STUB" lines (15–17) as superseded further down (217–223).

2. **The consumer plugin name is inconsistent across sources.** The live-proven,
   genuine UID-lock plugin is **`auth_nwc`** (authtype `nwc`; contract lines
   225–226, 250–252). But (a) the site config
   `sites/ssc/.nwp.yml` (dated 2026-05-19, pre-F26)
   still names `auth_nwc_oauth2` as the provider plugin, and (b) the contract's own
   `boundary.oauth_sso.consumer_paths` still points at `moodle/auth/oauth2/**` with
   the comment "auth_nwc_oauth2 Moodle plugin" (contract lines 110–111) while the
   `oidc:` block uses `auth_nwc`. The contract explicitly calls `auth_nwc_oauth2` a
   "lock-less decoy" (line 226). **Treat `sites/ssc/.nwp.yml` as stale**, and note
   the boundary path may need updating to the `auth_nwc` plugin path — flag for the
   operator/ops#75 owner.

3. **ADR numbering.** In `docs/decisions/`, **NWP-ADR-0029 is the nwc authorization
   model** and **NWP-ADR-0031 is paired-site versioning** (NWP-ADR-0027 is unified course
   content). NWP-ADR-0031's own numbering note (lines 19–23) flags a *separate*
   NWC-profile-local "NWP-ADR-0030/0031" series cited in `docs/onboarding/adrs.md`
   that does **not** exist in `docs/decisions/` and collides by number — it
   recommends renumbering that onboarding series `NWC-ADR-*`. Not yet done.

4. **Prod-domain redaction.** The contract redacts the prod domain as
   `nwc.<example-prod-domain>` (e.g. lines 214, 269), while
   `sites/ssc/.nwp.yml` records the real live domain (`nwc.<live>`). Not a
   contradiction — the committable contract deliberately avoids pinning the real
   prod host; the live domain lives in the (equally in-repo but per-site) `.nwp.yml`.

---

## Cross-reference map

| You want… | Read |
|---|---|
| The full versioning/promotion decision + 5-plane rationale | [NWP-ADR-0031](../decisions/0031-paired-site-versioning-and-promotion.md) |
| The pair contract schema, field-by-field | [ops75-pair-contract-schema.md](ops75-pair-contract-schema.md) + `private/pairs/ssc.pair-contract.yml` (the private overlay repo — ops#326; sample shape: [`pairs/ssd.pair-contract.yml`](../../pairs/ssd.pair-contract.yml)) |
| The Moodle promotion substrate + the F26 SSO runbook | [moodle-promotion-substrate.md](moodle-promotion-substrate.md) |
| The canonical content model + the two boundaries | [NWP-ADR-0027](../decisions/0027-unified-course-content-architecture.md) |
| The nwc authorization model (acting identity inside a site) | [NWP-ADR-0029](../decisions/0029-nwc-authorization-model.md) |
| Generic package vs your instance (single-site) | [nwc-fork-guide.md](nwc-fork-guide.md) |
| Moodle plugin repo hygiene + manifest/installer | [ops73-moodle-plugin-manifest-design.md](ops73-moodle-plugin-manifest-design.md) |
| Tag/release + versioning scheme | [ops74-versioning-scheme.md](ops74-versioning-scheme.md), [ops74-tag-release-runbook.md](ops74-tag-release-runbook.md) |
| Key rotation / erasure / DR-restore runbooks | [ops82-key-rotation.md](ops82-key-rotation.md), [ops81-erasure-channel.md](ops81-erasure-channel.md), [ops83-dr-restore.md](ops83-dr-restore.md) |
| The intersite data contract proposal | [P74-intersite-data-contract.md](../proposals/P74-intersite-data-contract.md) |

---

*Last updated: 2026-07-16. This is a synthesis/navigation doc; when it disagrees
with a primary source (ADR or the pair contract), the primary source wins — and
please fix this doc.*
