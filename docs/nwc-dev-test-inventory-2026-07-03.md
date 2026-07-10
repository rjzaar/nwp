# nwc-dev page-type test inventory — 2026-07-03 (Lane A, ops#22)

Base: **https://nwc-dev.ddev.site** · login **admin / adminpass** (`/user/login`)
Rollback: `ddev snapshot restore lane-a-pretest-20260703`

**Auth-state method:** do one pass logged in as admin, then repeat the ★-marked rows
in a private window. Rule of thumb: everything under `/admin/*` must 403 (or redirect
to login) for anonymous; ★ rows have a meaningful anonymous behaviour of their own.

Enumerated live from the site 2026-07-03: 38 nwc modules enabled, 4 node types
(page/topic/event/codoc) + 3 restored (nwc_document/nwc_resource/nwc_project),
1 group type + guild bundle, 59 enabled views, all `*.routing.yml` routes.

---

## 1. Open Social core surfaces

| URL | Check |
|---|---|
| ★ `/` → `/stream` | Front page = activity stream; anon should redirect (observed 301) — confirm it lands somewhere sane (login or /explore) |
| ★ `/explore` | Public activity stream; renders for anon (200 verified) |
| `/stream` | Logged-in home stream; post-creation form works (posting exercises the Solr-less indexer — expect log errors, see §10) |
| ★ `/all-groups` | Groups directory; anon sees only public groups |
| ★ `/all-topics` | Topics directory (currently NO topic content — should be empty, not error) |
| ★ `/community-events` | Events directory (no event content yet — empty state) |
| ★ `/all-members` | Member directory; anon visibility rules |
| ★ `/search/all` · `/search/content` · `/search/users` · `/search/groups` | Pages render (200 verified) but **Solr is missing** — expect empty/stale results, see §10 |
| `/notifications` | Notification centre for admin |
| `/following` | "Content I follow" view |
| `/wholiked` | Who-liked listing |
| ★ `/user/register` | Registration flow — nwc_registration hooks into this; check what a new registrant sees |
| ★ `/user/login` · `/user/password` | Standard auth forms |

## 2. Profiles / member (nwc_member)

| URL | Check |
|---|---|
| ★ `/user/1` | Admin profile page; anon view of a profile |
| `/user/1/edit` | Account edit |
| `/user/1/information` | Profile info tab |
| `/user/1/groups` · `/user/1/topics` · `/user/1/events` | Per-user OS tabs (empty states OK) |
| `/user/1/dashboard` | **nwc_member dashboard** — the custom member landing |
| `/user/1/notification-preferences` | nwc_notification per-user prefs form |
| `/user/1/growth` | nwc_onboarding progress page |
| `/user/group-invitations` | My group invitations |

## 3. Groups & guilds

Sample groups: **1 = Copyright Guild (guild)** · **2 = Writers IG (flexible_group)** · 8 = Media Guild (guild); 3–7 more IGs exist.

Open Social group surfaces (use group 2):

| URL | Check |
|---|---|
| ★ `/group/2` | Group home; anon visibility of an IG |
| `/group/2/about` · `/group/2/members` · `/group/2/events` · `/group/2/topics` | Group tabs |
| `/group/2/membership` | Manage members (admin) |
| `/group/2/invitations` · `/group/2/membership-requests` | Invite/request queues |
| `/group/add/flexible_group` | Create IG form |
| `/group/add/guild` | Create guild form |
| `/group/2/workflow` (+ `/add`, `/settings`) | **nwc_group** per-group workflow pages |

Guild surfaces — nwc_guild (use group 1, Copyright Guild):

| URL | Check |
|---|---|
| `/group/1/guild-dashboard` | Guild dashboard |
| `/group/1/leaderboard` | Leaderboard |
| `/group/1/member/1` | Guild member profile (+ `/skills`, `/endorse`) |
| `/group/1/my-skills` | My skills page |
| `/group/1/verifications` | Level-verification queue (sample verification id 1 exists) |
| `/group/1/ratification-queue` | Ratification queue (no ratifications yet — empty state) |
| `/group/1/admin/skills` (+ `/report`) | Skill admin (skill_level 1 exists; vocab `guild_skills` term 18) |
| ★ `/guild-resources` | Global guild resources page |
| `/admin/config/nwc/guild` | Guild module settings |

## 4. Node content types — sample + add form

| Type | Sample | Add form | Check |
|---|---|---|---|
| page | ★ `/node/23` (Collaborative Editing Demo), `/node/22` (About) | `/node/add/page` | Anon on /node/23 gave **307** — confirm it redirects to login, not an error loop |
| topic | none | `/node/add/topic` | Create one; verify it appears in /all-topics + stream |
| event | none | `/node/add/event` | Create one; enrollment tabs (`/node/{id}/enrollments`) after creation |
| codoc | none | `/node/add/codoc` | **Collab doc type** — creation OK even if Hocuspocus sidecar isn't running; editor behaviour is the real test |
| nwc_document | ★ `/node/24` (Data Privacy Policy; 24–28) | `/node/add/nwc_document` | **Restored bundle** (§10.1) — full render with body, workflow tab present |
| nwc_resource | ★ `/node/29` (Vatican II Documents; 29–32) | `/node/add/nwc_resource` | Same |
| nwc_project | ★ `/node/33` (Liturgy Translation Project; 33–35) | `/node/add/nwc_project` | Same |
| Post (not a node) | create on `/stream` | — | Post + photo post from the stream form |

Workflow surfaces on nodes (nwc_asset + workflow_assignment):

| URL | Check |
|---|---|
| `/node/24/workflow` | Workflow tab (+ `/assign`, `/add-task`, `/apply-template`, `/check`, `/process`, `/advance`, `/resend`) |
| `/node/24/versions` · `/node/24/reedit` | Version history / re-edit |
| `/admin/content/assets` | nwc_asset admin listing |

## 5. Help book + nwc_help

| URL | Check |
|---|---|
| ★ `/node/13` | **AV Commons Help** book root (children 14–21: Getting Started, Dashboard, Assets, Workflow, Guilds, Notifications, FAQ, Contact) — book nav renders, anon gets redirect (307) not error |
| `/node/20` | FAQ page — deepest-linked child |
| `/nwc/help/panel` · `/nwc/help/all` | nwc_help panel + all-topics page |
| `/admin/nwc/help` (+ `/add`) | Help-topic config collection — **empty**; test the add form |

## 6. Legal / copyright (nwc_copyright)

Docs configured: terms, privacy, aup, copyright-notice, beta-community-cc0-agreement.

| URL | Check |
|---|---|
| `/admin/nwc/copyright` | Canonical-text overview (versions.yml driven) |
| `/admin/nwc/copyright/terms` | Single-doc admin view |
| `/admin/nwc/copyright/sync` | **Run this first** — it populates data_policy from canonical-text (Moodle target ss-dev may be unreachable; settings tolerate that: `fail_on_ss_unreachable: false`) |
| ★ `/legal/terms` etc. | **404 until the sync above is run** (renders from data_policy revisions). After sync: verify each of the 5 docs + anon access |
| ★ `/legal/terms/raw` | Body-only HTML endpoint used by consent boxes |

## 7. Governance / growth cluster

nwc_governance (samples exist: scope_grant 1, policy_decision 1, governance_action 1):

| URL | Check |
|---|---|
| `/admin/nwc/governance` | Dashboard |
| `/admin/nwc/governance/scope-tree` · `/policies` (+ `/add`) · `/grants` · `/templates` · `/style` | Sub-pages; policy add form |
| `/admin/nwc/governance/actions` · `/actions/1` (+ `/undo`) | Action log + detail + undo path |
| `/admin/nwc/governance/decisions` (+ `/export.csv`) | Decision records — **empty collection**, check empty state + CSV |
| `/admin/nwc/governance/levels/propose` · `/subgroups/propose` | Proposal forms |

Growth / onboarding / delegation / telemetry / blueprints / mailer:

| URL | Check |
|---|---|
| `/admin/nwc` | Growth hub landing |
| `/admin/nwc/welcome` | First-run wizard (+ `/{step}`) |
| ★ `/welcome` | Member-facing onboarding welcome |
| `/admin/nwc/tiers` | Growth tiers — **empty**, check empty state |
| `/admin/nwc/health` | Telemetry health dashboard |
| `/admin/nwc/blueprints` | Blueprint catalog |
| `/admin/nwc/delegation` (+ `/who-runs-what`) | Delegation overview |
| `/admin/nwc/mail-templates` (+ `/add`) | Email templates — **empty**; add-form + (after creating) preview/test-send |

## 8. Feedback, registration, error report

| URL | Check |
|---|---|
| ★ `/community/suggestions` | Public feedback board (no feedback yet — empty state) |
| `/feedback/submit` | Submit form → creates first feedback entity; then `/community/suggestions/{id}` + vote |
| ★ `/community/feedback/guide` (+ `/member`, `/admin`, `/moderator`, `/technical`) | Role guides |
| `/admin/nwc/feedback` (+ `/analytics`) | Admin overview + analytics |
| `/admin/nwc/registration/review` | Registration review queue (webform-based; **no webforms exist** — verify it degrades gracefully) |
| ★ `/report-error` | Error-report form — test as anon AND authed |
| `/admin/config/nwc/error-report` | Its settings |

## 9. Remaining nwc admin/config surfaces (one row per module)

| URL | Check |
|---|---|
| `/admin/nwc/annotations` (+ `/layers`) | nwc_annotation admin (no annotations yet) |
| `/admin/review/clips` (+ `/dashboard`) | nwc_clip_review queue + dashboard (empty) |
| `/admin/nwc/code-sync` (+ `/repositories`, `/pipelines`) | nwc_code_sync dashboard |
| `/admin/config/nwc/collab` | nwc_collab settings (HMAC/sidecar config — view only, signed-off surface) |
| `/admin/config/development/nwc-generate` · `/nwc-cleanup` | nwc_devel generate/cleanup forms (generate re-runs the seed idempotently) |
| `/admin/config/nwc/email-reply` (+ `/test`) | nwc_email_reply settings + test harness |
| `/admin/config/services/nwc-moodle/data` · `/oauth` · `/sync` | The 3 Moodle sub-module settings forms |
| ★ `/oauth/userinfo` | OIDC endpoint — expect 401/403-style JSON for anon, not 500 |
| `/admin/config/nwc/notifications` (+ `/queue`, `/process`) | nwc_notification settings + queue (empty) + manual process |
| `/admin/nwc/safeguarding` (+ `/checks`, `/consent`, `/incidents`) | Safeguarding overview + 3 registers (empty) |
| `/admin/nwc/scripture` | Scripture admin (no verses/CCC imported) |
| `/admin/nwc/translations` | Translation projects (empty) |
| `/admin/nwc/trials` (+ `/surveys`) | Trials + surveys (empty) |
| `/admin/nwc/videos` | Video assets (empty) |
| `/admin/nwc/visual-dam` (+ `/color-palettes`, `/color-palettes/add`) | Visual DAM dashboard; palette add form |
| `/my-work` | nwc_work_management dashboard (workflow_task 1 exists; claim/release from here) |
| `/admin/structure/workflow-list` (+ `/add`) | workflow_assignment list config |
| `/admin/structure/workflow-template` (+ `/add`) | Templates |
| `/workflow-task/1` (+ `/edit`) · `/workflow-task/add` | Task detail/add |
| `/admin/config/workflow/workflow-assignment` | Module settings |

## 10. Verified status (full 151-URL smoke crawl, admin + anon, 2026-07-03)

Every URL above was machine-crawled in both auth states after the fixes below:
**131/151 return 200 as admin**, 10 are normal redirects (302/301/307), and the 10
remaining non-200s are all explained (list below). No admin-visible 5xx remain.
Raw matrix: scratchpad `crawl3-results.txt` (admin-code anon-code URL).

**Fixed this session (recorded on ops#22):**

1. **Orphaned node bundles → 500s.** `node.type.{nwc_document,nwc_project,nwc_resource}`
   missing from active config → nodes 1–12 returned 500. Restored types + body fields,
   reseeded via `nwc_devel_create_sample_content()` → now **nids 24–35**, verified 200.
2. **45 missing module-shipped configs restored** (same lifecycle-gate fallout, found by
   auditing every enabled module's `config/install` vs active config): `group.type.guild`
   + 7 guild group-roles + `user.role.copyright_reviewer` (was 500ing the whole guild
   cluster and 404ing `/group/add/guild`), 21 nwc_help topics, 7 nwc_mailer templates,
   4 nwc_growth tiers, 4 nwc_blueprints contexts, `webform.webform.apply` (registration).
   The previously "empty" collections (§5/§7/§9) are now populated — retest them as lists,
   not empty states.
3. **Three code bugs fixed + committed + pushed** (`unfork/open-social-13`,
   `ec96fee`/`29b8558`/`15f3e5e`): `/node/{n}/versions` 500 for every node
   (workflow_assignment read non-existent `field_version_major`); email-reply test page
   500 (`theme.registry` has no `has()`); `/admin/config/services/nwc-moodle/data` 500
   (routing referenced a `SettingsForm` class that was never committed — now written).

**Remaining non-200s, all explained (no action needed to start testing):**

| URL(s) | Admin | Why |
|---|---|---|
| `/group/1/member/1{,/skills,/endorse}`, `/group/1/verifications`, `/group/1/ratification-queue` | 403 | Guild membership access checks — uid 1 isn't a member of the Copyright Guild. **Join via `/group/1/membership` first**, then retest. |
| `/node/24/workflow` | 403 | Workflow-participant access check on the workflow tab — verify intent once workflow roles are assigned. |
| `/wholiked` | 403 | View-level permission — confirm which role is meant to see it. |
| `/legal/terms{,/raw}` | ~~404~~ **200 — LIVE** | Sync run 2026-07-03 + data_policy field config restored (see §10 addendum); all 5 docs verified anon. |
| `/oauth/userinfo` | 403/401 | Expected — OIDC bearer-token endpoint, not a session page. |

**Addendum (2026-07-03, after operator ran the copyright sync):** the config loss
also hit **contrib dependencies** of nwc modules — a full-site audit found 55 more
missing objects (data_policy `field_description` + displays + agreements view,
**simple_oauth token bundles ×3**, 45 webform configs incl. the contact form,
symfony_mailer test policy, media full view-mode). All restored. The first sync had
created the 5 data_policy entities with silently-dropped (empty) bodies; deleted +
re-synced → **all 5 `/legal/{doc}` + `/raw` now 200 anon with real content.**
Cumulative restored config: **100 objects.** The sync's `ss tool_policy: error` ×5 and
`NOTICE: unwritable` ×2 lines are expected on dev (no ss-dev Moodle, placeholder token,
prod-only `/srv/data` paths).

**Environment notes:**
- **Solr missing.** No solr container; node saves log `SearchApiSolrException`, search
  results will be empty/stale (pages render). Decide: `ddev add-on get ddev/ddev-solr`
  vs DB backend for dev.
- **WIP modules disabled by design:** nwc_editorial, nwc_formation, nwc_pairing,
  nwc_carmelite_dictionary — their routes 404 (ops#22 punch item 4, not a regression).
- Anon `/stream` → 301 and anon *pages* (13, 23) → 307 login redirects, but the
  nwc_devel fixture nodes (24–35) are anon-visible (200). Confirm that split is intended.

## 11. Test coverage (asked 2026-07-03: "are there behat tests for all these?")

**No — nowhere near.** What exists:
- **Open Social upstream:** 146 behat features under
  `html/profiles/contrib/social/tests/behat/features/capabilities/` (stream, groups,
  topics, events, search, book, profile, …) + `behat.yml.dist` at the site root —
  covers §1–§4's OS surfaces upstream, but is not wired into any nwc CI run.
- **nwc modules:** exactly **2** behat features (`nwc_copyright` policy_reacceptance,
  `nwc_editorial` pipeline — the latter for a module that isn't even enabled), plus
  **30 PHPUnit test classes** (only 6 Functional; mostly Unit/Kernel for
  workflow_assignment, nwc_work_management, nwc_content_access, nwc_guild internals).
- Nothing exercises the ~40 custom routes/pages in §5–§9 end-to-end. The 151-URL crawl
  above is currently the only page-level check; candidate to become a smoke test in the
  profile CI gate (ops#3 §4 #8) — even a status-code assertion would have caught all
  six defects found today.
