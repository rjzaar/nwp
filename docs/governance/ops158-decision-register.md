# ops#158 decision register — every decision, explained, numbered, phased

**Companion to nwp/ops#158** (the open-ops resolution ladder, 2026-07-29). The
issue holds the analysis; this register holds the **decisions** the ladder
rests on — one entry per decision, so each can be ratified, overridden or
executed independently, and so no session ever re-litigates one silently.

**How to read an entry**

| Field | Meaning |
|---|---|
| **Status** | `STANDING` (already decided, recorded here so it stops being re-asked) · `RECOMMENDED` (proposed; executable on ratification or by standing authority) · `OPERATOR` (only the operator/controller can take it) · `BLOCKED-ON` (waits on a named decision or event) |
| **Why** | The evidence line. Entries marked *[verified 2026-07-29]* were checked against live state during the fleet sweep, not recalled. |
| **How** | The `pl` path. Where the verb is missing, building the verb **is** the decision. |
| **Done when** | The observable state that closes it. |

Numbering is stable: `D<n>` never gets reused. Phases match ops#158's ladder.

> ## ⇢ RATIFICATION EVENT — 2026-07-29 (operator)
> The operator ratified ("do recommended") **D1–D7, D11–D23, D27, D30–D39**;
> execution proceeds per the ladder without further asking. Modifications made
> at ratification, now reflected in the entries below:
> - **D2**: the loop **stays armed, no belt** (D1 proceeds as the mitigation).
> - **D8**: wording drafted (see the entry) — awaiting operator ratification of
>   the TEXT, not the direction.
> - **D9, D10**: **DEFERRED** by the operator, 2026-07-29.
> - **D24**: operator asked which sites apply — answered in the entry
>   (one site: the avc test instance); retirement awaits an explicit nod.
> - **D25**: **AMENDED** — the operator CLAIMS the RDF site; action is
>   backup + reversible switch-off (mothball), NOT retirement.
> - **D26**: **AMENDED** — backup-for-easy-restore only; no retirement
>   decision attached.
> - **D28, D29**: operator asked for fuller explanations — entries expanded.

---

## Phase 1 — Armed-loop hardening (ops#151, #91, #122)

### D1 — Fix the two constructed sensitive-gate bypasses before anything else
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #151
- **Why:** The agent-loop is now armed on the ai-host (operator order,
  2026-07-29). The 2026-07-11 audit constructed two working bypasses of the
  loop's sensitive-path gate; while the loop was paused these were latent —
  armed, they are live attack surface. The member→`agent-eligible` vector was
  re-verified during arming and is double-permission-gated (sync-side labels
  are tier-only; the AI-draft button needs `administer feedback+triage
  feedback` **and** `request ai draft`) *[verified 2026-07-29]* — so #151's
  bypasses are the remaining gap, not the member path.
- **How:** Reproduce both bypasses as failing bats tests (red), fix the gate,
  adversarial verify (revert-the-fix discipline), one REVIEW MR.
- **Done when:** both bypass tests exist, went red against the old gate, and
  the suite is green on main.

### D2 — The loop stays armed while D1 is in flight; optional belt is one verb
- **Status:** RATIFIED 2026-07-29 — **stays armed, no belt** (operator) · **Issues:** #91, #151
- **Why:** Disarming would undo an explicit operator order on a gate that is
  permission-protected; but the operator may want less trigger surface while
  D1 lands.
- **How:** Belt if wanted: `pl loop disable respawn-drain` on the ai-host
  (keeps the 30-min poll, halves the trigger paths; reversible with
  `pl loop enable respawn-drain`). Never touch `.loop-paused` for this.
- **Done when:** operator states a preference (default: stay as armed).

### D3 — Close #91 by demonstration, not argument
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #91, #122
- **Why:** #91's scenario (member feedback steering the loop) deserves an
  end-to-end negative demonstration on a demo site with synthetic accounts,
  which #122's seeder provides.
- **How:** Build `nwc:seed` (#122), run the #91 scenario against the demo
  pair, attach the transcript, close.
- **Done when:** #91 closed with the demonstration linked.

---

## Phase 2 — Promotion-pipeline integrity (ops#75, #72, #76, #120)

### D4 — Rescue the unmerged pair_guard fix first
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #75
- **Why:** `pair_guard` is INERT on the real consumer↔provider pair — it
  reads the config shape the real pair does not use, so the code-only rule
  for the paired live sites has no machine backstop. A fix already exists,
  unmerged, on branch `fix/pair-guard-binds-real-pair` (one commit; its
  worktree survived the 2026-07-29 prune as KEEP(unmerged))
  *[verified 2026-07-29]*. Highest value-per-hour in the queue.
- **How:** Same rescue method as the 2026-07-28 branches: verify red/green,
  independent adversarial pass, REVIEW MR, merge.
- **Done when:** `pl pair check <consumer> live` REFUSES a full-DB promotion
  on the real pair (the currently-passing wrong behavior goes red first).

### D5 — Gates compose only after the guard binds
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #72, #76, #120
- **Why:** The stg-verification gate (#72), Moodle type-dispatch (#76) and
  live-host validation (#120) all assume a working pair/promotion substrate;
  building them on an inert guard bakes the hole in.
- **How:** Sequence strictly after D4; each as its own red-green MR.
- **Done when:** each issue closes citing D4's merged guard in its tests.

---

## Phase 3 — Legal / GDPR follow-through (ops#119, #141, #142, #150, #31; nwc!52)

### D6 — The privacy@ role address is the contact point; deploy gates on the mailbox
- **Status:** RATIFIED 2026-07-29 (direction + fallback-apex domain) · still
  **BLOCKED-ON** one word from the operator: confirmation the test mail
  (subject `privacy-alias-test-20260728-e2e`) reached the controller inbox —
  unverifiable from a session, and the text must not deploy on an unproven
  mailbox · **Issues:** #142 (part 1)
- **Why:** The role address was provisioned 2026-07-29 (forward-only alias on
  the forge host's MTA, same pattern as the existing role aliases) and a test
  message was accepted by the upstream mail provider (dsn 2.0.0)
  *[verified 2026-07-29]*. Canonical privacy.md v2 (merged, nwc!52) carries
  the address with **no effective_date on purpose**. The fork's stale copy is
  retired; the canonical sync tool refuses to run anywhere else (proven).
- **How:** Operator: (1) confirm the test mail reached the controller inbox
  (subject `privacy-alias-test-20260728-e2e`); (2) ratify the fallback-apex
  domain choice from the contact-point memo, or name the long-term domain and
  the text is re-cut before deployment. Then set `effective_date` in
  canonical-text/versions.yml and deploy via D7's verb.
- **Done when:** live sites serve privacy v2 and re-acceptance has triggered.

### D7 — Build `pl moodle policy set` (and pick the Drupal serving route)
- **Status:** RATIFIED 2026-07-29 (verb build greenlit; Drupal route choice
  still owed at build time) · **Issues:** #142, nwc!52
- **Why:** Legal text deployment currently has no verb — the retired sync
  script's site-push sections were stubs. Moodle's tool_policy is native; the
  verb wraps a shipped `admin/cli/` script through `pl moodle cli`'s
  containment (the same pattern as the Art.9 probe). The Drupal half needs a
  one-time route decision: the drupal/legal contrib module vs serving from
  the copyright module's canonical text.
- **How:** Build `pl moodle policy set <site> --doc <name> --file <path>`
  red-green; operator picks the Drupal route; wire `pl drush <site>
  --tier=live --execute -- <set-command>` accordingly.
- **Done when:** one command updates a policy on a live tier and forces
  re-acceptance, and the verb has refusal tests.

### D8 — Ratify the Art.9 wording package after v2 deploys
- **Status:** WORDING DRAFTED 2026-07-29 (below) — awaiting operator
  ratification of the TEXT · **Issues:** #119, #150
- **Why:** The ratification package is drafted; #150's operator decision
  (consent optional on /apply) is merged (nwc!51). Ratifying before the
  contact-point text is live would ratify text that immediately changes.
- **Drafted wording** (operator requested 2026-07-29; plain-language, Art. 9
  explicit-consent standard, consent OPTIONAL per nwc!51, withdrawal +
  contact route included; pre-counsel):

  > **Optional: sharing your formation journey**
  >
  > Some parts of this community can keep a record of your spiritual
  > formation — for example which formation courses you have worked
  > through, reflections you choose to save, and practices you choose to
  > track. Because this reveals your religious beliefs, the law treats it
  > as specially protected information, and we will only keep it if you
  > **explicitly agree** here.
  >
  > **You do not have to agree.** If you skip this, you can still join and
  > take part fully — the site simply won't retain formation progress or
  > reflections for you, and pages that depend on them will say so.
  >
  > ☐ **I explicitly consent** to this community storing my formation
  > records (course progress, saved reflections, tracked practices) so the
  > site can walk with me over time. I understand this information reveals
  > my religious beliefs.
  >
  > You can **withdraw this consent at any time** from your account's
  > privacy page. Withdrawal stops new records immediately and removes the
  > stored formation records within 30 days; it does not affect anything
  > else about your membership. Questions, access, correction or deletion:
  > the privacy contact route in our Privacy Policy.

  Ratification note: the consent-storage plumbing already records
  version + timestamp per member; a wording ratification is a version bump
  through the D7 deploy verb, forcing re-acceptance only for members who
  had opted in.
- **How:** After D6/D7: operator ratifies (or edits) the text above →
  version-bump via D7's verb.
- **Done when:** #119 and #150 closed with the ratified wording live.

### D9 — Applicable regime: adopt the drafted Option C unless counsel says otherwise
- **Status:** DEFERRED by the operator, 2026-07-29 (re-present when D6/D8
  complete, or if the admission-gate tripwire fires) · **Issues:** #142
- **Why:** The regime memo recommends Option C — defer the Art.27 rep /
  UK-ICO registration behind the admission-gate tripwire (~€300–350/yr to
  convert later). This register records the recommendation so the decision is
  a yes/no, not a re-research.
- **How:** Controller reads the memo; records the verdict on #142.
- **Done when:** #142 carries the regime verdict; D10 unblocks.

### D10 — Reconcile the live policy's legal frame with the regime verdict
- **Status:** DEFERRED with D9 (operator, 2026-07-29) · **Issues:** #141, #142
- **Why:** The live privacy policy is written to Australian law while the
  GDPR pack analyses UK/EU; the complaints route and governing-law clauses
  follow whichever regime D9 lands on. The pack's operational docs (breach
  procedure, DSAR process, DP policy) then adopt as drafted.
- **How:** Text changes via the canonical-text flow + D7 deploy; operational
  docs adopted by reference on #141.
- **Done when:** policy §complaints/§law match the regime verdict; #141 closed.

### D11 — data_policy version bookkeeping reads the canonical versions file
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #31
- **Why:** The C3 fork closure made canonical-text/versions.yml the single
  version source *[verified 2026-07-29]*; the module tracking versions
  anywhere else recreates the fork.
- **How:** Point the module's version read at canonical versions.yml in the
  same repo; add a parity test.
- **Done when:** #31 closed; a version bump in one file is the whole bump.

---

## Phase 4 — Moodle tree convergence (ops#103, #137, #90, #139, #153, #154, #81, #138, #125)

### D12 — The toolkit tree is the canonical plugin source; sites vendor from it
- **Status:** STANDING; execution RATIFIED 2026-07-29
- **Why:** Five divergent vendored copies of the formation plugin exist; the
  live sites run different security-fix generations (the newer allowlist XSS
  fix vs the older denylist one) *[state recorded 2026-07-28]*. Every Art.9
  deliverable below rides this train, so it converges first.
- **How:** Reconcile to the toolkit tree per #103; then
  `pl moodle plugin deploy <site> mod/depthcontent --tier=live` per site —
  the gate machinery (ADR-0036 classes, ship-together assertion, AMD
  freshness) now covers every site shape including the unpaired one.
- **Done when:** `pl moodle gate-status <site>` is green (or EXEMPT-by-class)
  fleet-wide from ONE source tree; #90 and #137 close with it.

### D13 — The unpaired formation site exits its exemption via a local consent source, before expiry
- **Status:** STANDING; execution RATIFIED 2026-07-29 · **Issues:** #153, #154
- **Why:** The bounded exemption (merged, ADR-0036) hard-expires
  **2026-10-31**; its declared exit is `posture: local`. The two unbuilt AMD
  modules and the probe deployment ride D12's first deploy to that site.
- **How:** Build the AMD modules in the canonical tree; ship the probe to the
  site's `admin/cli/`; build the local consent source; flip the declaration
  to `posture: local` via `pl class set` review flow; re-attest with the
  probe through `pl class evidence`.
- **Done when:** `pl class check <site>` passes with posture local; the
  exemption file is retired before 2026-10-31.

### D14 — Erasure channel, logstore scrub and visibility floors ride the same train
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #81, #139, #125
- **Why:** All three are Moodle-side deployables; shipping them with D12's
  converged deploy avoids three separate live windows.
- **How:** Land each on the canonical tree first; `pl contracts erasure
  <pair>` gates #81's channel; `pl erasure execute` stops failing closed when
  the channel is live.
- **Done when:** each issue's gate/probe passes against live.

### D15 — Drupal-side write-gate call-site audit completes the Art.9 pair
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #138
- **Why:** The presave gate is merged; #138 is the audit that every
  formation-data write path actually delegates to it — the same
  "symbol-with-zero-callers" defect class the 2026-07-28 review kept finding.
- **How:** Scoped call-site scan + tests on the profile repo, one MR.
- **Done when:** #138 closed with the scan as a repeatable test.

---

## Phase 5 — Deploy-chain and host guards (ops#157, #92, #106, #107, #70, #156, #23, #25, #26, #52)

### D16 — drush is a production dependency on every live-enabled site
- **Status:** STANDING; fleet sweep RATIFIED 2026-07-29 · **Issues:** #157
- **Why:** The staging build strips require-dev; the live deploy runs
  updatedb from the synced vendor. With drush in require-dev the deploy
  aborts in maintenance — it did, live, for ~25 minutes on one site
  *[verified 2026-07-29, recovered]*. Three sites are fixed and pushed; the
  policy must cover the fleet.
- **How:** Sweep every live-enabled site's composer.json; move drush to
  `require`; commit per site repo.
- **Done when:** no live-enabled site carries drush only in require-dev.

### D17 — stg2live refuses BEFORE maintenance-on when the staged vendor lacks drush
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #157
- **Why:** D16 is convention; this is the machine backstop. The incident's
  cost was the abort happening AFTER maintenance was enabled.
- **How:** Preflight in stg2live (staged `vendor/bin/drush` present, else
  refuse pre-maintenance), red-green.
- **Done when:** a drush-less staging tree cannot take a live site into
  maintenance.

### D18 — stg2live learns the remote_dir fallback the site tooling already knows
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #157
- **Why:** One site declares only `remote_dir`; stg2live resolves only
  `remote_path` and would have targeted a nonexistent directory
  *[verified 2026-07-29; worked around in config]*.
- **How:** Port site.sh's `/var/www/<remote_dir>` fallback into stg2live's
  resolver, with a test.
- **Done when:** the config workaround can be removed and the deploy still
  targets the right tree.

### D19 — Served-config parity becomes a checked invariant, not a hope
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #157, #92, #106
- **Why:** Two stray vhost files sat inert on the shared host until an
  unrelated nginx reload activated one and took a live site to 404 for ~15
  minutes *[verified 2026-07-29, recovered; strays retired]*. On an
  omnibus-nginx host, ANY reload arms whatever sits in conf.d — an unloaded
  stray is a time bomb.
- **How:** Extend `pl server roots` (or add a sibling check) to diff the
  host's conf.d against the tracked server repo: flag strays, flag drift,
  fail red into `pl rag`. This is also #92's drift detector, delivered where
  the incident proved it matters.
- **Done when:** re-planting a stray conf on the host turns the check red.

### D20 — The dedicated-nginx split is scheduled work, not tonight's work
- **Status:** RATIFIED 2026-07-29 (as scheduled-later work) · **Issues:** #106, #102
- **Why:** The structural fix for D19's class of fragility is moving the
  fleet off the forge's omnibus nginx — real migration work touching TLS and
  every vhost; the D19 guard makes waiting safe.
- **How:** Fold into #102's tier tooling as its own phase with rollback.
- **Done when:** fleet vhosts are served by a dedicated nginx with parity
  checks, or the operator explicitly declines.

### D21 — Papercut batch: contracts-in-worktrees + nested secret lookup
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #107, #70
- **Why:** Both are small, test-shaped, and cost every session a little.
- **How:** One MR: PROJECT_ROOT resolution honoring worktrees + the
  get_infra_secret nested-key fix, each with a bats red first.
- **Done when:** both issues closed by one reviewed MR.

### D22 — The build-host regains pull access by a dedicated read-only deploy key
- **Status:** RATIFIED 2026-07-29 — the admin key-enablement step itself still
  requires the operator at the forge admin UI (structurally outside any
  session token; nothing a session can pre-execute) · **Issues:** #156
- **Why:** The build-host's checkout now points at the correct origin but no
  credential on it can read the repo (its existing key is a root-created
  deploy key not enabled there; enabling keys is deliberately outside the
  session bot's power) *[verified 2026-07-29]*. Its 665-line local evolution
  of the daily-audit script is backed up and awaits review.
- **How:** Operator mints/enables a read-only deploy key; then a session
  diffs + adopts the local audit script as a reviewed MR.
- **Done when:** the build-host pulls current main; the local script drift is
  merged or retired.

### D23 — The prod-agent's next proof is a gated deploy to the disposable test site
- **Status:** RATIFIED 2026-07-29 · **Issues:** #23, #26; #25 remains operator hardware work
- **Why:** The agent is built and validated on a scratch host; the agreed
  next step is one real gated deploy on the disposable test instance, then
  the regression suite (#26). Verifier-host provisioning (#25) is operator
  hardware work with the kit already prepared.
- **How:** `pl server-apply` path on the test tier per ADR-0024/0026;
  #52's verify-then-apply reconciliation lands with it.
- **Done when:** one signed bundle round-trips pull→verify→apply→rollback on
  the test site with the ledger showing it.

---

## Phase 6 — Retirements and oversight truth (ops#155, #104, #80, #148; RAG-auto #7–#21)

### D24 — Retire the open-registration test site now
- **Status:** OPERATOR (nod), then execution · **Issues:** #155
- **Which sites (operator asked, 2026-07-29):** exactly ONE — the avc *test*
  instance (`avctest`, the throwaway created during avc testing; 6
  example-domain accounts, no content, plaintext-HTTP registration form).
  It is NOT avc itself, and no other site has this exposure. D25/D26 cover
  the other two retirement-family candidates and are now mothball/backup
  decisions, not retirements.
- **Why:** It serves an open Drupal registration form over plaintext HTTP
  with no valid TLS; six example-domain accounts, no content. Verified twice.
- **How:** `pl live --delete <site>` (or tracked-conf removal + `pl server
  roots` confirmation), close #155.
- **Done when:** the vhost is gone and the checker confirms.

### D25 — The RDF site is CLAIMED and mothballed (amended at ratification)
- **Status:** AMENDED + RATIFIED 2026-07-29 — the operator claims the site;
  action is **backup + reversible switch-off**, not retirement ·
  **Issues:** (raised in #158 §5)
- **Why:** First-ever audit found **51 advisories** *[verified 2026-07-29]*.
  Mothballing removes the attack surface today while preserving everything
  for reactivation: the webroot and database stay on disk untouched; only
  the serving vhost is disabled (moved aside, reversibly — the same retired-
  conf pattern used in the 2026-07-29 incident cleanup).
- **How:** `pl backup <site> --remote -y` (webroot tar + DB, sha-verified,
  replicated to the backup peers) → move the site's conf out of the live
  conf.d into the retired directory → reload → verify the domain stops
  serving and every other site is unaffected. **Reactivation** = restore the
  conf + reload (one command), then run it through the normal update train
  before exposure.
- **Done when:** backups verified on all three backup hosts; domain not
  serving; reactivation path recorded here.

### D26 — The legacy courses site is backed up for easy restore (amended at ratification)
- **Status:** AMENDED + RATIFIED 2026-07-29 — backup-for-easy-restore only;
  the site stays up; **no retirement decision attached** ·
  **Issues:** (raised in #158 §5)
- **Why:** Its ~50 courses may be the only copy. (It is a Moodle instance,
  not an identity provider — the name misleads.) A restorable backup makes
  every future decision about it reversible.
- **How:** `pl backup <site> --remote -y` (webroot tar + DB, sha-verified) +
  capture the Moodle data directory if present on the host (course files
  live there, not in the webroot — verify and record what was captured);
  replicate to the backup peers.
- **Done when:** the backup set exists on all three backup hosts with a
  recorded, tested restore path.

### D27 — RAG-auto issues reconcile mechanically, not by hand
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #9–#11, #13, #14, #17–#21
- **Why:** The nightly rag-sync auto-closes on green; after the sweep most of
  these sites audit clean *[verified 2026-07-29]*.
- **How:** Let the cron pass, then `pl issue reconcile`; `pl issue close` any
  green stragglers with a one-line evidence note.
- **Done when:** no rag-auto issue is open for a green site.

### D28 — Frozen forks stay RED; deferral is labelled, never ignore-listed
- **Status:** STANDING (reaffirmed; fuller explanation added at operator
  request, 2026-07-29) · **Issues:** #7, #12
- **What these two actually are:** Both run the estate's 1.x FORK of the
  Open Social distribution, with the profile pinned to forked packages.
  **avc** is the original community site: frozen by operator decision
  2026-07-01 because the 2.0 rebuild (the un-forked profile now on the nwc
  line) supersedes it — every hour spent updating the fork is an hour taken
  from the successor that removes the fork entirely. **mayo** is the same
  fork family serving the external-client tier; that tier's live hosts are
  real production behind the deploy-host boundary, so even a wanted update
  cannot ship from an AI session.
- **Why they stay RED (13 advisories each):** the advisories sit inside the
  pinned fork packages; fixing them means either un-forking (that IS the 2.0
  program) or a bespoke fork-patch effort with no future. Hiding them via
  composer audit-ignore would make a deliberate deferral invisible to
  oversight — the estate's rule is red-with-reason over green-by-silence.
- **The exit, when it comes:** avc's red dissolves when its content/users
  migrate to the 2.0 line (ops#22 program); mayo's when the client tier is
  either migrated to 2.0 or given a dedicated, operator-scheduled fork-patch
  window through the deploy-host.
- **How (bookkeeping now):** add a `deferred-frozen` label via
  `pl issue label 7`/`12`; this entry is the rationale both issues point at.
- **Done when:** both issues carry the label and stop surfacing as new work;
  final closure rides the 2.0 migration.

### D29 — The archived un-fork base is red-by-archive; no churn
- **Status:** STANDING (2026-07-29; fuller detail added at operator request)
- **What the site is:** `nw1` is the ORIGINAL un-fork workspace — the
  checkout where the Open Social 13 un-fork was actually performed (its git
  branch is still the un-fork feature branch). When the un-forked build was
  promoted to become the canonical 2.0 line (the 2026-07-01 rename), this
  workspace was kept as the archive of that work rather than deleted.
- **Details behind the red (6 advisories):** they live in its archived
  composer lock — two in the pinned core, the rest in an HTTP-stack package
  pinned to a *development* version as part of the un-fork surgery, which no
  ordinary `composer update` can move *[verified 2026-07-29: an update
  attempt moved nothing and churned the lock, and was reverted rather than
  committed]*. Its "live" config is a vestigial one-key stub and the domain
  does not serve — zero live exposure.
- **Why keep it at all:** it is the provenance record of the un-fork — the
  place to answer "why does 2.0 differ from upstream here?" while the 2.0
  program (ops#22) is still landing. It costs one honest RAG row.
- **Options if the row should go earlier:** archive-and-remove — `pl backup
  --bundle nw1` (git bundle, replicated via `pl backup replicate`), then
  `pl delete nw1` (backups are archived by default) and drop the registry
  row. Recommended timing: after ops#22's punch list closes.
- **Done when:** permanent as-is; or removed via the bundle path above once
  2.0 ships.

### D30 — The WIP-entangled sites take their security bump only after their WIP lands
- **Status:** RATIFIED 2026-07-29 (direction); still BLOCKED-ON the WIP owner landing/stashing · **Issues:** #15, #16, #157 §4
- **Why:** Both carry substantial uncommitted work including modified
  composer files *[verified 2026-07-29]*; entangling a security bump into
  half-done work destroys bisectability and someone else's intent.
- **How:** WIP owner lands or stashes; then `pl security update -y <site>`
  (the verb now handles the v2 layout and updates the HTTP stack).
- **Done when:** both sites audit 0 active advisories on clean trees.

### D31 — Phantom fleet rows leave the config
- **Status:** RATIFIED 2026-07-29 (executed same day — see Why) · **Issues:** #10 + RAG noise
- **Why:** The fleet registry carries rows for a site alias that
  double-counts a real checkout, a site with no project, and verify
  fixtures — each a permanent false RAG row *[verified 2026-07-29]*.
- **How:** Operator removes/annotates the entries (the registry file is
  local-only by design); `pl rag` confirms the row count drops.
- **Done when:** every RAG row maps to exactly one real site.

### D32 — The unmanaged live site gets tracked and classed
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #104
- **Why:** A live site outside the registry is invisible to every guard this
  register builds.
- **How:** `pl site init <site>` + registry entry + `pl class set` through
  the review flow.
- **Done when:** `pl rag` grades it like any other site.

### D33 — Forge patch cadence becomes a nagging check
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #80
- **Why:** The forge was patched after a CVE window this month; cadence by
  memory is cadence by luck.
- **How:** Add a `pl todo` check wrapping `pl server forge status` (version
  + key expiry, monthly threshold).
- **Done when:** an out-of-date forge turns `pl todo`/`pl rag` amber by
  itself.

### D34 — The CI verification job finishes its fixture and stops being amber-forever
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #148
- **Why:** The bootstrap landed; 12 failures remain from fixture gaps. An
  always-amber job trains everyone to ignore amber.
- **How:** Complete the CI fixture; flip the job to blocking once green twice.
- **Done when:** the job is green and `allow_failure` is removed.

---

## Phase 7 — Product spine and programs (ops#22, #27, #34, #48, #49, #54, #55, #56, #58–#66, #69, #71, #73, #74, #85, #86, #94, #95, #97, #99–#101, #105, #108, #121, #128–#135, #143)

### D35 — The 2.0 spine builds in dependency order, not enthusiasm order
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #63 → #54 → #55 → #71 → #22
- **Why:** Config-as-code (#63) makes the profile testable; profile CI (#54)
  makes it safe to change; the editorial pipeline (#55) is the first feature
  that pays rent; advance() hardening (#71) protects it; #22 is the punch
  list that consumes all of it.
- **Done when:** each closes green before the next starts.

### D36 — Content converges before it federates
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #61 → (#34, #64, #65, #94) → #66
- **Why:** The canonical course-content model (#61) is what D12's tree
  convergence serves; pipelines build on it; federation (#66) is last
  because it multiplies whatever shape exists.
- **Done when:** #61's model is the single source the pipelines read.

### D37 — UX and docs ship as agent batches once the pipeline exists
- **Status:** RATIFIED 2026-07-29 (was RECOMMENDED) · **Issues:** #56, #58, #59, #62, #95, #128–#132, #134
- **Why:** Low-risk, high-volume, test-checkable — the shape agent sessions
  are best at; blocked only on #55 for the member-facing ones.
- **How:** One agent session per batch, each with the red-green + adversarial
  method; `pl doc-truth` gates the doc claims (#59 wires it into CI).
- **Done when:** each batch merges with doc-truth green.

### D38 — Governance items resolve by their governors
- **Status:** RATIFIED 2026-07-29 (the operator adopts the recorded
  recommendations as the working direction; #69 still requires the guild) ·
  **Issues:** #27, #49, #69, #100, #143
- **Why & recommendations (recorded so the decisions are yes/no):**
  #27 — recommend the deploy-host-only scope for the AI-free build;
  #49 — recommend building the proposed forge verb (issue #49's "one door
  for forge operations") as thin wrappers over the proven 0600-curl-config
  pattern — this sweep's MR/merge flow is the prototype;
  #69 — theology staging ratification belongs to the guild;
  #100 — the public/private boundary ADR precedes the #101 history refound
  and #97/#99 gate work; #143 — the impact-contract blind spot needs a
  decision on where the boundary list lives before enforcement widens.
- **Done when:** each carries its governor's verdict; execution items spawn
  from there.

### D39 — Remaining program items ride their named vehicles
- **Status:** RATIFIED 2026-07-29 · **Issues:** #73, #74 (ADR-0031 hygiene MR
  series); #85 (two-person copyright_sync 3-way merge, operator-sanctioned);
  #86 (avatars after the 2.0 theme integration); #105 (live plumbing checks
  fold into `pl todo`); #108 (the audit register closes as its rows do);
  #121 (verify on the next 2.0 deploy, then close); #135 (upstream patch via
  the composer-patches mechanism until fixed upstream); #34 (pipeline runs
  on the build-host once #156/D22 restores its pulls).
- **Done when:** each closes by its vehicle's normal gate.

---

*Register compiled 2026-07-29 from ops#158; verified facts are from the fleet
sweep session logs and are marked as such. Amend by MR — a decision changed
without a diff is a decision nobody made.*
