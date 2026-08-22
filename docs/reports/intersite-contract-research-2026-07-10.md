# Intersite data-contract research — nwc ↔ ss(c)

**Status:** RESEARCH / FOR OPERATOR REVIEW — nothing here is integrated. Produced 2026-07-10 by a
4-way parallel research sweep (boundary inventory · contract mechanisms · change-impact gating ·
pitfalls catalogue). Full raw reports in
`scratchpad/intersite-research/{A,B,C,D}-*.md` (attach to the eventual proposal).

This answers four questions you raised about the real data shared between **nwc** (Drupal/Open
Social — OIDC *provider*, copyright *source*, feedback *sink*) and **ss/ssc/ssd** (Moodle — OIDC
*consumer*, copyright *receiver*, **real students**):

1. If code changes on either side, how do you *know* it won't break the other side?
2. Only some modules touch the boundary — how do we make that explicit so most changes flow
   freely and only boundary-touching ones trigger cross-site work?
3. XML? JSON? some mechanism? What's best practice?
4. What haven't we explored — the pitfalls, angles, issues?

---

## 0. The one-paragraph answer

**You have already built ~70% of the answer without naming it as "the intersite-contract problem."**
`pairs/ssc.pair-contract.yml` (its `surfaces:` block), `lib/impact.sh` (the fate-manifest), P66
(module passports + deptrac), and `pair_guard` are exactly the right skeleton. The three real gaps
are: **(a)** the boundary is declared at *module-version* granularity, but the things that actually
break are *payload shapes* (an OIDC claim renamed, a JSON field retyped) — those aren't pinned;
**(b)** there is no *commit-time* detector that says "this diff is internal, ship freely" vs "this
diff touches the boundary, run the cross-site checks"; and **(c)** three live boundary surfaces
aren't in the contract at all, plus ~15 unexplored risk questions — several of them legally or
operationally serious (GDPR erasure propagation, OIDC key rotation, DR identity asymmetry).
**Recommended mechanism: JSON Schema (not XML), committed in git, sha-pinned from the pair contract,
minisign-signed, validated by both sides' CI — plus a `pl impact` classifier driven by an enriched
`boundary:` block in the same contract.** No new service, no SaaS; it slots into the YAML + bash +
minisign machinery you already run.

---

## 1. What actually crosses the boundary today (the inventory)

Seven real surfaces. **Only three are in the pair contract.** (Moodle plugin code lives on the build
host, so the Moodle side is inferred from the nwc code that talks to it + the contract.)

| # | Surface | Direction | Data crossing | In contract? |
|---|---------|-----------|---------------|--------------|
| 1 | **OIDC SSO / userinfo** | nwc→ss | ID-token + userinfo claim set incl. custom `guilds` claim | ✅ `oauth_sso` (version only) |
| 2 | **UID-lock / identity bind** | nwc→ss (+echo) | `sub`=Drupal uid → `mdl_user.idnumber`; echoed as `oauth_sub` | ✅ `identity.uid_lock` |
| 3 | **Role → cohort sync** | nwc→ss | guild membership+roles → Moodle cohorts/roles; **matched by email/username** | ❌ **undeclared** |
| 4 | **Badge / completion read** | ss→nwc | badges + completions by `moodle_user_id` (display only) | ❌ **undeclared** |
| 5 | **Copyright / legal policy sync** | nwc→ss (single-writer) | canonical legal doc → Moodle `tool_policy` version (forces re-consent) | ✅ `copyright_sync` |
| 6 | **Cross-site feedback bridge** | ss→nwc | feedback payload → Tester/Trialing-Guild score | ✅ `feedback_bridge` |
| 7 | **Sanitizer shared-salt** | bidirectional data contract | real email → same deterministic fake on both stacks (keeps OIDC join alive in dev) | ❌ **undeclared** |

**The exact shapes that cross** (raw material for the schemas — full detail in report A):
- **Claim allow-list** (`NwcOidcClaimsServiceProvider::REQUIRED_CLAIMS`): `sub, name,
  preferred_username, email, email_verified, locale, profile, updated_at, zoneinfo, guilds`.
  Only `guilds` is custom: `[{id:int, label:string, roles:string[]}]`.
- **Copyright record**: `policy_name, title, version:int, effective_date, change_summary, body_md`.
- **Feedback message**: `ss_feedback_id, ss_userid, oauth_sub, type, title, status, timecreated`
  (+ optional `score, reviewer_nwc_uid`).

**Silent-break risks found in the code today** (things that break the other side with *nothing
declaring the dependency*):
- `sub` = uid is a load-bearing `simple_oauth` **default**, guarded nowhere. If `sub` ever became a
  UUID, the UID-lock (`idnumber` = integer uid) breaks fleet-wide.
- Role-sync matches users by **email/username** — a *different* join key than the UID-lock. Two keys
  for one identity, undeclared.
- The `guilds` claim shape is a private contract with no schema (a prior flat-vs-nested collision
  already caused a bug; M1 just cleaned it up).
- Guild role machine-names are a shared vocabulary — the Tester→Trialing rename **already caused a
  silent auto-enrol failure**.
- `render_id_stability.join_key: canonical_id` in the contract **has no code realization** — the real
  key in code is `sub`/uid/`idnumber`. The contract is aspirational there.

---

## 2. Q3 answered — the mechanism: JSON Schema, git-native, signed (NOT XML)

**Reject XML/XSD.** Everything on this boundary is already JSON (JWT claims are JSON; Drupal/Moodle
REST is JSON). XSD would force a JSON↔XML impedance layer that neither `simple_oauth` nor
`auth_oauth2` speaks. Also reject Protobuf/Avro/registry (wire-format + a running service you don't
need — violates no-SaaS) and Pact/PactFlow (the conceptually-best "bi-directional" mode is
**PactFlow-SaaS-only** — hard-disqualified by the threat model).

**Recommended: a three-layer, git-native, minisign-rooted contract layered on what exists.**

1. **Coordination layer (already shipped):** keep `pairs/ssc.pair-contract.yml` (YAML — it's config)
   as the human-facing min-version + policy + rails declaration, enforced by `pair_guard` at deploy.
2. **Data-shape layer (the new piece you're asking for):** one **JSON Schema (Draft 2020-12)** file
   per surface — the claim set, the copyright record, the feedback message — as plain `.json` in git,
   referenced from the pair contract by path + `sha256`. Validate on **both** sides in CI with **Opis
   JSON Schema** (native to both Drupal and Moodle PHP).
3. **Compatibility layer (registry guarantees without a registry):** a small CI checker diffs the
   new schema against the git-committed old one on every MR and enforces **expand-and-contract**
   (add fields optional; never remove/retype a field the consumer reads). This reproduces a schema
   registry's BACKWARD-compat guarantee using only git history. Provider-first deploy ordering — the
   other half of the guarantee — is *already* enforced by `pair_guard` (NWP-ADR-0031 D5).

**OIDC specifically:** use the **standard discovery doc** (`/.well-known/openid-configuration`) +
JWKS for endpoints/keys (Moodle `auth_oauth2` auto-configures from it) — nothing bespoke — plus a
hand-authored `oauth_sso.claims.schema.json` for the claim set (precedent: OpenID eKYC-IDA ships
JSON Schema files in git). ⚠ Gotcha to verify live: `simple_oauth` doesn't natively expose the
discovery endpoint (community submodule needed; issuer must match the consumer's base URL exactly;
Simple OAuth 5.2 EOL 2026-12-09) — this is already on the F26 human-gated path, so land the *schema*
now and the *provisioning* on F26.

**Trust root (the NWP superpower the public patterns lack):** fold `schemas/*.json` into the same
**minisign** signed bundle as everything else (the contract already has a `dependencies:` block for
F28 linkage). The consumer trusts the schema by *signature*, not by host — the exact property that
lets an offline tier verify. Record each schema's `sha256` in the pair contract and extend
`pair_guard` to fail-closed on a sha mismatch (reuses machinery already in `lib/pair.sh`).

**Two-repo sync (different cadences):** primary = **signed-artifact sync** (provider CI signs the
schema bundle; a bot PRs the copy + signature into the Moodle plugin repo; consumer CI verifies by
minisign before merge) — mirrors the build-host→ver signed flow. Fallback = a tag-pinned git submodule.
Avoid a Composer package until the schemas stop changing.

```
pairs/ssc.pair-contract.yml         # EXISTS — coordination
  └─ surfaces.<name>.schema:         # ADD: path + sha256 per surface
contracts/                           # ADD: the data-shape layer (plain JSON Schema 2020-12)
  ├─ oauth_sso.claims.schema.json
  ├─ copyright_sync.record.schema.json
  ├─ feedback_bridge.message.schema.json
  └─ SHA256SUMS(.minisig)            # signed; trusted by signature not host
```

---

## 3. Q1 + Q2 answered — "internal vs boundary-touching" detection

The ask — *most changes flow freely; only boundary-touching ones trigger cross-site work* — is a
solved problem in three stacked disciplines. NWP owns the parts; the design wires them, no parallel
system.

**Detect with three complementary layers (cheapest first — each catches what the others miss):**
1. **Path-based CI gating** (GitLab `rules:changes:`, already used by `lint:doc-truth`) keyed to the
   boundary path set. **Must fail-safe *closed*:** if the diff can't be computed (new branch,
   scheduled pipeline), treat the change as boundary-touching and run the full suite. Never let
   "can't compute" mean "internal."
2. **Architecture-boundary linter (deptrac)** — fits both Drupal *and* Moodle PHP. Catches a *new
   code edge* into a boundary symbol that a path glob misses (an internal module growing a new
   tentacle across the surface). **This is literally P66's proposed deptrac gate, scoped up** from
   intra-nwc modules to the intersite boundary.
3. **Blast-radius intersection** — the useful question isn't "what's affected?" but "has anything
   *important* been affected?" = intersect the diff with a critical-target allowlist. That allowlist
   *is* the boundary manifest.

**Declare the boundary as data** — enrich the existing `surfaces:` block with a `boundary:` map
giving each surface its exact path/symbol set on each side, so the classifier is a pure
set-intersection (one source of truth, no hardcoding). **Keep the manifest honest** with a
symbol-anchored CI test that *fails if a boundary symbol is referenced from a file outside the
declared paths* — turning every escape into a fixable rule instead of a silent false-negative.

**The workflow you described, concretely:**
- New **`pl impact [--base=main]`** command (sibling to `pl pair check`, renders in `lib/impact.sh`'s
  "AFFECTED / NOT AFFECTED" idiom): classifies a diff **INTERNAL** vs **BOUNDARY-TOUCHING** and says
  *which* surface(s) and *why*. Internal → normal single-site CI, ships freely. Un-computable →
  BOUNDARY (fail-safe).
- **CI fork** (cloned from `lint:doc-truth`): boundary MRs additionally get (a) cross-site
  contract-verify against the pinned signed schema, (b) a **`contract_version`-bump gate** (surface
  shape changed but version didn't → FAIL), (c) the **other side's sign-off via CODEOWNERS** scoped
  to the boundary paths (an internal change needs only normal review; a `**/oidc_claims/**` change
  cannot merge without the ss side's approval).
- **Two-repo reality:** each repo's CI verifies against the *pinned signed contract*, not the live
  other side (no cross-repo call at MR time). Provider promotes first (`pair_guard`); `pair-smoke`
  confirms the live pair. This is consumer-driven contract testing, broker-less, signature-rooted.

**Reuse verdict (from report C):** one new `lib/boundary.sh` + `pl impact` verb + a `boundary:` block
and `contracts/*.schema.json` in the pair contract + three CI jobs + one CODEOWNERS section, with
P66's deptrac gates doing double duty. `pair_guard`, the deploy-gate, and the security-critical paths
are **untouched**. `lib/impact.sh` (destructive blast-radius at deploy) and `lib/boundary.sh`
(cross-site blast-radius at commit) are siblings — same philosophy, orthogonal axes.

---

## 4. Q4 answered — the pitfalls & the questions we haven't asked

Full catalogue (10 axes, severity × likelihood × concrete scenario × do-we-mitigate) is in report D.
The headline: **much of NWP-ADR-0031 is contract-*only* today** (pair_guard not built, Moodle sanitizer
is a fail-closed stub, F26 OAuth is a stub), so many "mitigations" are design intent, not running
code. The highest-value **questions you have NOT yet asked** (ranked severity × how-unaddressed):

1. **GDPR / erasure propagation (Q3).** Deleting a person on nwc leaves their Moodle account, grades,
   consent rows, and moodledata intact. There is **no OP→RP delete channel** (emerging standard:
   *OpenID Provider Commands*). A legal obligation the moment an EU or minor user exists. *NWP has
   nothing.*
2. **Issuer key-rotation runbook (Q12).** The single most common OIDC outage in the wild. If nwc
   rotates its JWKS key and the ss plugin doesn't refresh-on-unknown-`kid`, **every login fails**.
   The pair contract has no key-rotation clause; the plugin behaviour is unverified.
3. **Rollback & DR *identity* asymmetry (Q2).** NWP-ADR-0031's "per-site rollback is safe" reasoning
   covers *code*, **not a DB restore that renumbers uids**. Restore one half to a different point in
   time and every UID-lock can point at the wrong human. No paired-restore invariant exists.
4. **Join-integrity monitoring, not just liveness (Q6).** The 5-URL smoke proves endpoints answer;
   nothing proves a *real* `idnumber` still resolves to the right `uid`, or that copyright versions
   *converged*. A silently-severed join is invisible until students pile up at the login screen.
5. **Definitive join key (Q1).** uid (renumber-fragile), `sub` (stable), or email (unsafe —
   recycling/confusables)? Moodle stock `auth_oauth2` links on **email**; the contract names
   `idnumber` but never forbids the email fallback. Recommendation: make OIDC **`sub` the immutable
   anchor** and treat idnumber as a cache of it.
6. **Claim allow-list / data-minimisation (Q9).** No closed, reviewed set of claims → silent PII
   scope creep (worse for minors). The schema in §2 *is* the fix — it pins the allow-list.
7. **Consumer-driven contract test (Q5).** Should ss's expectations *fail nwc's CI* when broken,
   instead of relying on tolerant-reader discipline + post-deploy smoke (catches breaks *after* they
   ship)? §3's contract-verify job is the fix.
8. **uid-reuse / account-merge invariant (Q4).** The UID-lock silently assumes uids are permanent and
   1:1. Is that written down and enforced? (Drupal reusing a freed uid → idnumber silently rebinds to
   a different person.)
9. **Token lifetime & revocation propagation (Q13).** How fast does a suspended nwc user's live
   Moodle session die? Long refresh tokens can outlive deprovisioning.
10. **Consent system-of-record & data residency (Q8/Q10).** Which side authoritatively answers "did
    they consent, to which version, when?" — and is a us-iad host lawful for EU/minor records?
11. **`moodledata` in zero backups (Q15).** Already named in NWP-ADR-0031 D8 but not built — a host loss
    means unrecoverable student submissions/certificates.
12. **Shared-salt blast radius (Q11).** The never-rotated OIDC email salt is a permanent
    re-identification key across every environment. What's the incident plan if it leaks?
13. **Render id-stability actually tested (Q17).** Does the `shared-adapter-test-suite` the contract
    names actually exist, so a `--clear` re-render never orphans grades/attempts?
14. **Shared-host coupling (Q7).** nwc and ss on one Linode — accepted single-point-of-failure for
    real students, or isolate ss?
15. **Cross-site observability (Q14) + boundary doc-truth/upgrade gates (Q18/Q19).** No correlation
    id to trace one login nwc→ss; `pl doc-truth` doesn't yet treat the pair contract as a
    truth-checked artifact (so it can rot); no schema-diff gate catches a Moodle/OS upgrade changing
    `mdl_user` or a claim source.

---

## 5. Suggested integration path (minimal → complete; for your decision, not yet actioned)

Deliberately incremental — each step is independently useful and off-by-default until wired.

- **Phase 0 — pin the shapes (cheap, high value, no auth risk).** Author the three
  `contracts/*.schema.json` from the exact shapes in §1; add `schema:`+`sha256:` to the pair
  contract's `surfaces:`; add the two Opis validators (provider self-check + consumer subset-check)
  as CI. This alone closes the biggest gap (versions→schemas) and pins the claim allow-list (Q9).
- **Phase 1 — declare the full boundary.** Add the **three missing surfaces** (role-sync, badge-read,
  shared-salt) to the contract; add the `boundary:` path/symbol map; write the manifest-honesty test.
- **Phase 2 — the classifier.** `lib/boundary.sh` + `pl impact` + the CI fork (contract-verify,
  version-bump gate) + CODEOWNERS section. Ship *with* P66's deptrac engine (double duty).
- **Phase 3 — the compat checker** (expand-contract enforcement) + fold schemas into the minisign
  bundle + signed-artifact cross-repo sync.
- **Parallel track — the open questions.** Turn the top items (GDPR erasure channel, key-rotation
  runbook, DR paired-restore invariant, join-integrity monitor, `sub`-as-anchor decision) into their
  own ADR amendments / ops issues. Several are **prerequisites for real students on live**, independent
  of the schema work.

Recommend starting a proposal (P-number) or amending NWP-ADR-0031 with §2–§3 as the mechanism and §4 as a
risk register. **None of this is built or committed — it's here for your review before we integrate.**

---

*Raw source reports (with inline citations):
`scratchpad/intersite-research/A-boundary-inventory.md`, `B-contract-mechanisms.md`,
`C-change-impact-gating.md`, `D-pitfalls-and-open-questions.md`.*
