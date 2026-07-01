# NWP — What still needs to be done (thorough status, 2026-07-01)

Consolidated backlog across security, the nw2/avc-2.0 build, the operating-model connective
gaps, and hygiene. Priority tiers; each item marked **[auto]** (I can do without you) or
**[gate]** (needs your decision/merge/prod-auth). Live sources: `pl rag`, `pl issue ls`,
`pl todo`, git branch state.

---

## ✅ DONE in the autonomous pass (2026-07-01)
- **Fleet security cleared** where within-constraint fixes exist: **ba 41→0, mg 43→0** (green);
  **nwt 43→3** (3 graphql only, unreachable/ignored — the OS-site floor). Wave-1 earlier: mt/
  cathnet/dir1 → 0. Board synced (#8/#13/#17).
- **RAG hygiene:** deleted 3 stale junk audit records (dev/verify-test/verify-test1) + the 2
  orphan `verify-test*` DDEV fixtures (**freed 2.6 GB**). Fleet view now = 10 real sites (4 red,
  6 green) — the 4 red are all structural (avc/mayo profile-pins, nwd/nwt graphql).
- **nw2:** recipe now installs `nwc_collab` + `nwc_moodle`; collab Node sidecar `npm install`ed
  (49 pkgs); stray avc `collab.sqlite` removed.
- **Diagnosed (documented, not band-aided):** the `nwc_document/resource/project` content-type
  quirk is a **pre-existing nwc-profile bug** (`nwc_asset` declares bare `node.type` configs w/o
  fields; the orphan nodes are empty stubs) → fix belongs in the profile (ops#3). The 3 nwc-only
  modules (`editorial`/`formation`/`pairing`) are **pre-existing WIP** — fail to enable (missing
  `nwc_formation`), which is why nwc's own recipe omits them; left as-is.
- **Reported (needs you):** 11 of 21 secrets need rotation recording (`pl secrets status`).

## TIER 0 — Unfinished from the current session (concrete, ready)
1. **[auto] Finish fleet security — ba / mg / nwt.** Still RED (ba 41, mg 43, nwt 43). These are
   the **paused wave-2** updates; the recipe is proven (mt 53→0, cathnet 49→0, dir1 49→0). Just run
   the within-constraint composer update per site → commit composer.json if needed → `pl audit`.
2. **[gate] Merge two pushed branches** (§6 boundary — merge is your call):
   - `ops-6` (4 commits) — `pl rag --sync-issues` + the daily cron. Closes nwp/ops#6.
   - `fix/yaml-get-site-field` (1 commit) — the `pl audit` site-resolution bug fix.
3. **[gate] avc profile — the 95 uncommitted curated files.** Backed up (`~/nwp-curated-backups/`).
   Decision pending: commit-in-reviewed-groups (incl. 3 auth surfaces for two-person review +
   the broken `avc_registration` stub) vs hold. Independent of the security-pin fix.

## TIER 1 — Security (ops#1 / the fleet is mostly RED)
4. **[auto] avc / mayo remaining 7 advisories each** — 3 contrib pins (ginvite/paragraphs/
   role_delegation) blocked by the `nwp/avc` **profile** exact-pins. Fix = relax pins in the profile
   (safe, verified) — but entangled with #3 (95 dirty files) + the registry release train (0.3.1 vs
   v0.8 drift). Cleanest: a **0.3.2 backport** from the `v0.3.1` tag → publish → `composer update`.
5. **nwc / nwt graphql** (3 each, `audit.ignore`'d) — **unreachable** (graphql modules OFF); real
   fix = OS graphql-5 (ops#3). **WARNING: nwd is DIFFERENT — graphql modules are ENABLED on nwd**,
   so its 3 graphql DoS advisories are **REACHABLE (a real exposure)** and must NOT be ignored.
   Decide: disable graphql on nwd if unused (removes exposure), or upgrade to graphql-5. Do NOT
   copy nwc's ignore to nwd blindly.
6. **[auto] Secret rotation tracking** — `pl todo`: **11 of 21 secrets have no recorded rotation**.
   `pl secrets status` → verify at provider → `pl secrets done`.
7. **[auto] Backups** — ss / ss2 have none; avc backup **166 days old**; avc-stg no backup dir.
   `pl backup <site>`.
8. **[auto] RAG hygiene** — `dev`, `verify-test`, `verify-test1` (all "RED 43") are **test/junk**
   polluting the fleet view. Extend the `_rag_eligible_sites` denylist (or delete the fixtures).

## TIER 2 — nw2 / the avc+nwc → 2.0 build (current big thread)
Core integration DONE (see `handover-nw2-build.md`): nw2 = un-forked OS13 + all nwc modules + the
2 ported avc-only modules + real help-book content. Remaining:
9.  **[auto] Recipe integration** — add `nwc_collab` + `nwc_moodle*` to `…/nwc/recipe/recipe.yml`
    so a FRESH nw2 install enables them (today only enabled in the imported DB).
10. **[gate] Auth-surface review (two-person, CLAUDE.md)** — `nwc_collab` HMAC token service;
    `nwc_moodle_oauth` OIDC UserInfo endpoint. Ported verbatim; review before any stg/live.
11. **[auto] `nwc_collab` Node sidecar** — `npm install` in `…/nwc_collab/hocuspocus/` (real-time
    editing won't run until built).
12. **[gate] Naming/rebrand decision** — keep `nwc_` module prefix or rebrand `nwc_`→`nw2_`.
13. **[auto] Content-type config quirk** — nw2's imported DB has `nwc_document/resource/project`
    NODES but those content-type configs aren't fully present (type list = codoc/event/page/topic).
    Clean up (import the type configs or drop the orphan nodes).
14. **[gate] nw2 identity** — not in `nwp.yml`, git remotes disconnected. Register + give it a repo
    when it graduates from sandbox.
15. **[gate] Guild charters/content** — nw2's guilds have the canonical structure but no content;
    avc had none to migrate (demo only). Needs fresh authoring.
16. **[gate] Strategic: avc 1.x fate** — maintain the fork in parallel, or freeze once nw2 is 2.0?
    Drives whether #4's profile work is worth the release-train effort.

## TIER 3 — Operating-model connective gaps (the "self-driving" build)
17. **ops#4 — onboarding pipeline + AI-free `nwp-server` agent.**
    - **`pl onboard` — BUILT + VERIFIED 2026-07-01** ✅. `scripts/commands/onboard.sh` chains all 7
      steps (create-repo → human-supervised sanitize → **fail-closed PII gate** → scaffold → load →
      register → status). PII gate passed 6/6 adversarial tests; preflight hard-stops verified.
    - **Remaining [gate/human]:** actually onboard mayostudios.org (needs the human-run sanitize on
      prod — AI has no prod access by design); build the **AI-free `nwp-server` prod-executor**
      (§5/§7 design; less blocked now A14 test-tier authority is granted).
18. **ops#3 — un-fork productionization** (nwc WORKS; punch list to close): replace the 2 dev
    symlinks with composer packaging; retire `nwc.profile`/`.info.yml` (extract demo-seed to an
    `nwc_demo` recipe); `pl install nwc` wrapper (with memory_limit≥2G); verification gate (module
    lifecycle + Behat/PHPUnit + fresh-install test + profile CI); replicate to nwd/nwt; graphql-5
    follow-up. **[auto]** for most; cutover **[gate]** on A14.
19. **ops#6 §6 follow-ups — close the self-healing loop:** `pl rag` red should **auto-open/update**
    an nwp/ops issue (partly done: `--sync-issues`); wire the **agent-loop to nwp/ops** with the
    fix-repo routing + prompt-template selector (designed, gated in `handover-ops6-*`); fold the RAG
    grade into the `pl status` table. **[auto]** design/dev-side; agent-eligible promotion **[gate]**.
20. **A14 decision** — self-deploying-prod authority (ADR-0024). Provision the `ctl` seat /
    phone-approval. **[gate]** — unblocks every prod-touching path above.
21. **Finish the Part VIII `pl <verb>` backlog** — only `pl secrets`/`rag`/`issue` are
    registry/API-driven so far. **[auto]** incrementally.

## TIER 4 — Hygiene / housekeeping
22. **[auto]** Test-fixture cleanup — `verify-test*`, `bats-test-delete`, `trace-del2`, `hidden`,
    orphan DDEV volumes (the recurring theme).
23. **[auto]** `pl todo`: 13 HIGH + 40 MEDIUM items to burn down (backups, schedules, drift).
24. **[auto]** Promote ONE in-repo read-first doc; `~/nwp/CLAUDE.md` is May-stale → point at the
    OPERATING-MODEL.

---

## The decisions only you can make (the real bottlenecks)
- **A14** — prod deploy authority (gates ops#4, ops#3 cutover, any live security deploy).
- **avc 1.x**: maintain vs freeze-for-nw2 (gates #4/#16).
- **Merge** ops-6 + fix/yaml-get-site-field.
- **Naming/rebrand** nwc_→nw2_ (#12).
- **Auth-surface sign-off** for the 2 ported modules (#10).

## What I can do right now without you (highest-leverage first)
ba/mg/nwt security (#1) · nw2 recipe + npm sidecar + content-type cleanup (#9/#11/#13) ·
secret-rotation + backups (#6/#7) · RAG hygiene (#8) · ops#3 productionization dev-side (#18).
