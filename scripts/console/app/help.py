"""In-app operator help — pure DATA plus two lookups. Stdlib only.

WHY THIS IS A DATA STRUCTURE AND NOT A PILE OF TEMPLATES
    Help rots the moment it is expensive to edit. Everything below is text in
    one file, in one shape (`SECTIONS`), rendered by one small template that
    knows four block kinds and nothing else. Adding a paragraph is editing a
    string; adding a section is appending a dict. No HTML lives in the content,
    which also means Jinja escapes every character of it — help text can never
    become a markup injection.

WHAT IT IS ALLOWED TO SAY
    Only what this console actually does. Every claim here was read off
    `app/main.py`, `app/scope.py`, `app/authz.py`, `app/actions.py`,
    `app/config.py`, the pane templates and `static/sw.js`. Where a feature is
    absent (keyboard shortcuts) or not yet wired (the Library) the text says so
    rather than describing a plan as a fact.

TENANCY
    Help is STATIC. It carries no provenance (nothing was gathered, so there
    is nothing to be stale) and no gathered row, so `scope.scrub()` has
    nothing to drop and `scope.redact()` has nothing to strip. Both are
    no-ops over this context BY CONSTRUCTION, and tests/test_help.py pins
    that rather than trusting it. Site names and live domains stay OUT of the
    text — the engine repo is publicly mirrored and the leak lints ban them —
    so the tester-facing demo help names the /demo/join PATH and points at the
    invitation email (rendered at draft time from the site's declared live
    domain) for the exact link.

COVERAGE CONTRACT
    Every pane id in main.PANES has a section here with the SAME id, and the
    tab bar's contextual "?" deep-links to /help/(active pane).
    tests/test_help.py fails when a tab exists with no help — adding a pane
    means writing its section in the same change.

This module must not import main/actions/runner/subprocess: it is content, and
content must never be able to run anything.
"""
from __future__ import annotations

import re

# A section id appears in a URL (`/help/<id>`), so it is validated, not trusted.
SECTION_ID_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")

# The four block kinds the template understands. A fifth would be a template
# change, so the set is asserted in the tests — an unknown kind must never
# render as silence.
BLOCK_KINDS = frozenset({"text", "list", "defs", "note"})


def _t(text: str) -> dict:
    return {"kind": "text", "text": text}


def _l(*items: str) -> dict:
    return {"kind": "list", "items": list(items)}


def _d(*rows: tuple) -> dict:
    return {"kind": "defs", "rows": [{"term": t, "desc": d} for t, d in rows]}


def _n(text: str) -> dict:
    return {"kind": "note", "text": text}


SECTIONS: tuple = (
    {
        "id": "start",
        "title": "What this console is",
        "summary": "A read-mostly window onto the fleet, on the mesh, on your phone.",
        "blocks": (
            _t("The console is the `pl` command line turned into a phone-friendly web app. "
               "It is reachable only over the Headscale mesh (the app binds the tailnet "
               "address, so off-mesh the name resolves but routes nowhere), and it has no "
               "passwords — you sign in with a passkey on the device in your hand."),
            _t("It is deliberately lopsided: almost everything is a READ. A handful of safe "
               "actions exist for the demo tier, GitLab issues and CI retries, and nothing "
               "else can be expressed at all."),
            _l("Reads run on the console host, which is the AI/dev tier.",
               "Live and prod verbs are not wired here by design — run those on the "
               "workstation (and real prod from the offline deploy host).",
               "Heavy issue editing is still better in GitLab; the panes deep-link there."),
            _n("The console host holds NO sites. What you see on the Fleet, Todo and Backups "
               "panes was published to it by the machine that does hold them — see "
               "“Where the numbers come from” below."),
        ),
    },
    {
        "id": "panes",
        "title": "The tab bar — a map",
        "summary": "Nine panes in tab order; each has its own help section below.",
        "blocks": (
            _t("The tab bar is the whole UI: one full-screen pane at a time, in this order. "
               "Each pane has its own section further down this page — tap a name in the "
               "topics list, or use the small ? beside the ⟳ button, which always links to "
               "the help for the pane you are on."),
            _d(
                ("Review", "The operator's ONE queue: open merge requests plus needs-decision "
                           "issues. It sits first because it is the thing the console exists "
                           "to answer."),
                ("Fleet", "One row per site in scope: RAG grade, canonical phase, reasons, "
                          "and clickable advisory counts."),
                ("Issues", "Every issue tracker this console reads — the ops board and the "
                           "tester-feedback tracker — with filters and safe actions."),
                ("Todo", "The `pl todo check` sweep as a flat, priority-chipped list."),
                ("Demo", "The demo tier: golden-seal status, the invite-code registry, the "
                         "tester roster and editor, and the demo actions. When a reset "
                         "failed or was skipped it is the Demo TAB that raises a dot."),
                ("Backups", "The backup-freshness slice of the todo sweep. Read-only."),
                ("CI", "Open merge requests per configured CI project with their head "
                       "pipeline, and a retry button."),
                ("Quokka", "The local-model chat tab. 🟢 means the model answered a health "
                           "check within the last minute; 💤 means it is asleep or "
                           "unreachable, and the other tabs are unaffected."),
                ("Visuals", "The estate overview and four charts as subtabs, plus the "
                            "walkthrough jump-in page for the demo pair."),
                ("Sessions", "tmux sessions on the console host: list them, start a named "
                             "one, and join any of them in a real terminal. Owner-only, "
                             "because a terminal is a shell on that host. The point is "
                             "detach-safety — work started here keeps running when your "
                             "laptop drops off wifi. Its own help section explains the "
                             "workflow."),
            ),
            _t("Numbers in the tab bar refresh on load and then every 90 seconds. Each count "
               "is computed independently and best-effort: a feed that breaks loses its "
               "number, it never breaks the tab."),
            _l("The ⟳ button re-fetches the pane you are on. What that means differs by pane: "
               "the ones built from `pl` output — Fleet, Todo, Backups, Demo and Quokka's "
               "context — are served from a short-lived cache, about a minute by default, and "
               "⟳ is what bypasses it. Issues and CI are not cached at all; they ask GitLab on "
               "every load, so there ⟳ simply asks again.",
               "A link or a push notification ending in “?tab=” plus a pane name opens "
               "straight on that pane — that is how tapping an alert lands you where it "
               "happened.",
               "Otherwise the console reopens on the last pane you used, remembered "
               "per-device in the browser."),
        ),
    },
    {
        "id": "review",
        "title": "Review — the one queue",
        "summary": "Open MRs + needs-decision issues, from `pl decisions --json`. Estate-level.",
        "blocks": (
            _t("The Review pane is the operator's single queue: every open merge request in "
               "the configured projects, then every issue labelled needs-decision, grouped by "
               "the gate it blocks. It reads `pl decisions --json` and nothing else, and it "
               "is estate-level — inside a project scope it does not render; step back to "
               "“All projects” to see it."),
            _d(
                ("Awaiting your merge", "Open MRs with title, draft/conflict flags and the "
                 "description one tap away. “Review / Approve on GitLab” is a DEEP LINK: in "
                 "solo mode the merge click on the MR page is the whole approval. This "
                 "console holds no merge credential and never merges — a machine never "
                 "merges, a human does, there."),
                ("RED — decision needed", "needs-decision issues in reading order. Nothing "
                 "moves until these are answered. “Approve recommended” posts your approval "
                 "as a [console-review]-tagged note AND discharges the decision labels in the "
                 "same action, then shows the tracker state re-read after it — so an "
                 "answered decision cannot sit in the queue being re-approved."),
                ("AMBER — decision wanted", "The decision::wanted tier: real questions, but "
                 "nothing is standing still waiting for them. Ordered partly by inference — "
                 "treat it as a reading sequence, not a ruling. Promote one to RED with "
                 "`pl issue label` adding needs-decision."),
                ("comment", "Every write here is a [console-review]-tagged note on the issue "
                 "or MR; the note is the instruction the next working session acts on."),
                ("skip", "Hides the card on this device only. The console is the window, not "
                 "the store — nothing is recorded, and the card returns on reload."),
            ),
            _n("A queue this console could not read renders CANNOT-VERIFY, never as empty — "
               "“nothing to review” and “the console could not look” are different facts. "
               "Likewise “⚠ possibly already resolved” on a decision is a flag to read the "
               "newest comment, never a reason the issue was hidden."),
        ),
    },
    {
        "id": "fleet",
        "title": "Fleet — sites and their grades",
        "summary": "One row per site: RAG grade, canonical phase, reasons, advisories.",
        "blocks": (
            _t("One row per site in scope: its RAG grade as a coloured dot, its canonical "
               "phase (dev, live or prod), and the reasons behind the grade. When the "
               "published snapshot carries the security feed, a site with advisories shows a "
               "clickable count that opens that site's advisory detail further down the "
               "pane."),
            _l("The RED / AMBER / GREEN badges at the top are counts over the rows you can "
               "see, recounted inside a project scope — never inherited from a fleet total.",
               "“Re-run RAG check” (operators) re-grades the whole fleet, so it cannot be "
               "narrowed to a project: scoped users are refused and told to run it unscoped "
               "or on the workstation.",
               "The provenance line above the table says which host published these numbers "
               "and how old they are — see “Where the numbers come from”. A red STALE banner "
               "means you are reading history."),
            _n("What the grades mean — and why an unscanned site can never be GREEN — is in "
               "“What the RAG grades mean”, the next section."),
        ),
    },
    {
        "id": "rag",
        "title": "What the RAG grades mean",
        "summary": "RED, AMBER, GREEN — and why an unscanned site can never be green.",
        "blocks": (
            _t("The grade comes from `pl rag`, which merges two existing signals per site: "
               "security advisories from `pl audit`'s cached records, and work/drift items "
               "from the `pl todo` sweep."),
            _d(
                ("🔴 RED", "An open security advisory, or a high-priority security todo."),
                ("🟠 AMBER", "Any other todo item (drift, uncommitted work, backup freshness…), "
                             "a stale audit cache, a site that was never scanned, or a check "
                             "that could not run."),
                ("🟢 GREEN", "We looked, and it was clear."),
            ),
            _n("GREEN is a positive assertion, not a default. A site nobody has scanned grades "
               "AMBER, never GREEN — otherwise adding a site to the fleet would make the fleet "
               "look safer."),
            _t("The three badges at the top of the Fleet pane are RED / AMBER / GREEN counts "
               "for the sites you can see. When you are inside a project they are recounted "
               "from your own rows, never inherited from a fleet-wide total."),
        ),
    },
    {
        "id": "issues",
        "title": "Issues — the boards, and the safe writes",
        "summary": "Ops board + tester-feedback tracker, filtered server-side, honest about gaps.",
        "blocks": (
            _t("Every issue tracker this console reads renders as its own block, paginated "
               "and with the real total stated (“showing N of M”): the ops board AND the "
               "tester-feedback tracker, which is where the feedback testers file on the "
               "demo sites ends up. A truncated list says it was cut off; it never trims "
               "silently."),
            _d(
                ("Filters", "State and label are applied BY THE TRACKER per query — a filter "
                 "is a real search, not a client-side hide of rows that were never fetched. "
                 "The quick chips cover agent-eligible (queued for the agent-loop), "
                 "needs-human (agents must not touch it) and demo-tester."),
                ("act", "On the write tracker an operator can post a note, add or remove a "
                 "label, or close an issue — each re-checked server-side at POST time. Other "
                 "trackers are read-only here and deep-link into GitLab."),
                ("⏸ agent-loop paused", "The banner means nothing labelled agent-eligible "
                 "will be picked up until the loop resumes — a queue whose consumer is "
                 "stopped is not a queue, and you deserve to know before approving work "
                 "into it."),
                ("unreadable tracker", "A tracker this console's token cannot read is shown "
                 "as UNREADABLE with the reason, never as an empty (clean-looking) list. The "
                 "fix is a sibling 0600 token file on the console host — the message names "
                 "it."),
            ),
            _n("Inside a project, an empty list means “nothing carries this project's "
               "label” — the pane names the label it filtered on so you can check that "
               "first. A project with no issue label configured sees no issues at all, and "
               "says so as a warning, not as good news."),
        ),
    },
    {
        "id": "todo",
        "title": "Todo — the sweep, flat",
        "summary": "Every `pl todo check` item, one row each, priority-chipped.",
        "blocks": (
            _t("The `pl todo check` sweep as a FLAT list — one row per item, in the order "
               "the sweep emitted them, each row naming its site in bold and carrying a "
               "high, medium or low priority chip. It is not grouped or re-sorted by site; "
               "where a row carries a suggested command it is shown under the item."),
            _n("The table shows the first 60 items; the counts above it describe the whole "
               "set. Inside a project you see only rows for your project's sites."),
        ),
    },
    {
        "id": "demo",
        "title": "Demo — the pane, control by control",
        "summary": "Golden seal, invite codes, the join queue, tester roster and editor, and the demo actions.",
        "blocks": (
            _t("One block per demo-tier site in scope. Everything here acts on the LIVE demo "
               "pair only — the tier that exists to be handed to outside testers — and every "
               "action is an allowlisted verb with fixed arguments, never a pasted command."),
            _d(
                ("Golden seal banner", "When the golden image was last sealed, from where, "
                 "and the nightly reset window. THE FACT THAT MATTERS: any change made on "
                 "the live demo now — revoke, purge, guild edits, tester content — REVERTS "
                 "at the next nightly reset unless a new golden is sealed; the banner names "
                 "the workstation command (`pl demo golden … --with-pair`). An unreadable "
                 "seal renders CANNOT VERIFY, which is not the same as “no golden”."),
                ("Return leg", "The demo box's own last feedback-status run. It is hourly, "
                 "so a stale timestamp means the leg has stopped and nobody has said so — "
                 "rendered as CANNOT VERIFY, not ignored."),
                ("Live-box backups", "Newest backup per subdirectory on the live box, with "
                 "age and size — or CANNOT VERIFY with the reason."),
                ("Reset status", "A few highlight lines from the site's demo status, with "
                 "the full raw output one tap away. A failed or skipped reset raises the "
                 "dot on the Demo tab itself."),
            ),
            _t("INVITE CODES — the registry table. It lists ids, bundles, states and sha256 "
               "hash prefixes; a usable code is never in this table. The chips (All, Live, "
               "Revoked, Expired) always count the WHOLE registry; the row-count line under "
               "the table declares any narrowing."),
            _d(
                ("Select all", "A labelled control that says exactly what it will do — "
                 "“Select all N shown”, scoped to the rows the current filter rendered. Rows "
                 "the filter hides are NOT selected, and it cannot reach another site's "
                 "table."),
                ("Revoke selected", "Revokes the selected codes by id. The registry change "
                 "is durable and the live site is updated immediately; one bad id refuses "
                 "the whole batch. What renders afterwards is the registry RE-READ, not a "
                 "success note."),
                ("Purge selected", "Removes already-revoked or expired rows from the "
                 "registry, archiving them to a purged-codes file. A LIVE id in the "
                 "selection refuses the whole batch."),
                ("reveal", "Shows a code's plaintext ONCE, if it is still recoverable from "
                 "an invite pack on the registry home. The access (id and who) is recorded "
                 "in the demo log; the value never is. “Not in a pack” is a real "
                 "measurement; “unknown” means the console could not look."),
                ("plaintext column", "Whether a plaintext still exists ANYWHERE: the "
                 "registry stores hashes only, so a code's plaintext survives only in the "
                 "invitation draft and the 0600 invite pack saved beside it."),
            ),
            _t("JOIN REQUESTS — the queue of people who have asked to test, and the one "
               "control that decides who exists at all. THE MODEL IN ONE SENTENCE: "
               "approval IS the persistence decision. Somebody who enters a valid invite "
               "code at /demo/join creates NO account — the join records a request and "
               "nothing else — so an unapproved visitor cannot accumulate a login, and "
               "there is nothing to wipe. Approving is what creates the account AND puts "
               "them in the tester registry, which is the list the nightly reset "
               "preserves. So an approved tester comes back tomorrow with their own "
               "password; everyone else simply never existed."),
            _d(
                ("Approve", "Creates the tester and hands you their sign-in details. "
                 "Under the hood it is deliberately ordered: the account is created "
                 "BLOCKED, the registry is written and PROVEN, the payload is staged to "
                 "the demo box, and only then is the account unblocked. If any step "
                 "fails the whole approval is abandoned and says so — an account that "
                 "was never registered is wiped tonight, so the refusal tells you not to "
                 "tell anybody they are in."),
                ("The password", "Shown ONCE, in the approval result, and stored nowhere "
                 "— not in the audit log, not in the demo log, not in any cache. Pass it "
                 "to the tester before you close the panel. If you lose it, approve is "
                 "not repeatable; reset the account's password on the site instead."),
                ("Reject", "Records the decision so the queue stops showing it. Nothing "
                 "is created and nothing is destroyed, because a join never made an "
                 "account in the first place."),
                ("Add a tester", "The same registry write without a join request: give "
                 "the account name, the name you want to see in the list, and a bundle. "
                 "Use it for people you are setting up yourself. Optional guild, "
                 "Sojourner level and admin rights."),
                ("Malformed lines", "If the request store has lines the site could not "
                 "parse, the count is shown. It means the queue is NOT the whole truth — "
                 "somebody may have asked to join and not be listed."),
            ),
            _n("Who may approve: any console OPERATOR, in a project that carries the "
               "site. That is how \u201cme or another tester with admin rights\u201d is "
               "expressed \u2014 give that person a console account with the operator role. "
               "There is deliberately no separate tester-admin permission, because a "
               "policy expressed in two places is a policy that drifts."),
            _t("TESTERS — the fenced roster, read live from the site (a ~5-7 second read, so "
               "it loads when scrolled into view; ⟳ re-reads it). Only the synthetic "
               "@demo.invalid accounts are editable; real accounts are counted but not "
               "touchable here. Tap an account to open its editor:"),
            _d(
                ("Guild × role matrix", "Every guild in the site's catalogue, with join, "
                 "role-set and remove per guild. Roles offered are the site's own "
                 "assignable ids plus plain membership."),
                ("Sojourner level", "RAISE-ONLY, and it works through evidence: the verb "
                 "records qualifying course completions and the real engine recomputes the "
                 "level. There is deliberately no raw setter and no demotion — to lower a "
                 "tester, reset the demo tier."),
                ("Consent", "Read-only, always. Even a synthetic tester's consent changes "
                 "only through the site's own consent flows, so every consent record stays "
                 "one a real gate wrote."),
                ("Sign in as this tester", "Mints a ONE-TIME login link for that account: "
                 "single use, shown once, stored nowhere, and proven to belong to that uid "
                 "before it is shown (an admin session can never wear a tester's name). "
                 "Open it in a private window — in this one it replaces your own session."),
            ),
            _t("ACTIONS at the bottom of each site block: “Invite email” drafts the "
               "invitation (next section); “Reset to golden (if idle)” resets the site but "
               "keeps the idle guard even on the button — it skips if a tester was active "
               "in the last 30 minutes — and restores the standard tester set; “Issue "
               "code” mints one code for a chosen tester role bundle, valid 14 days."),
            _n("The code registry has ONE writable home per tier and it survives the "
               "nightly wipe — which is exactly why a tester's code keeps working after "
               "everything they did has been erased."),
        ),
    },
    {
        "id": "demo-tester",
        "title": "Demo — giving a tester access, and what they do",
        "summary": "The invite email, the join URL, the code, and the nightly reset.",
        "blocks": (
            _t("The whole tester flow is carried by the invitation email the console drafts "
               "for you: Demo pane, “Invite email” (tick the checkbox to add the reviewer "
               "levels). It mints one fresh code per tester level and renders a complete, "
               "copy-ready email — the codes appear ONCE in that draft (the registry stores "
               "hashes), with a 0600 copy saved in the site's demo-invites directory on the "
               "console host. Delete the level blocks your recipient should not get, paste "
               "the rest into your mail client, and send."),
            _l("STEP 1 — joining. The tester opens the join link the email carries — the "
               "community demo site's /demo/join page, resolved from the site's declared "
               "live domain when the draft is rendered — and pastes their code. A short "
               "discernment page (the examen) comes first; answering it "
               "honestly either carries them straight on or asks them to come back later. "
               "They land signed in on the community home, under a saint's name the site "
               "gives them — no email address, no real name, nothing about them is kept.",
               "STEP 2 — the courses. From the courses site's login page they click the "
               "single-sign-on button under “Log in using your account on:” — the email "
               "names the exact button — and they are in the courses half with the same "
               "identity. There is no code box on the courses site; it uses the community "
               "sign-in, not a code.",
               "REPORTING. On the community site: the feedback form the email links "
               "(/feedback/submit). On the courses site: the floating “Report a problem” "
               "button. One sentence is plenty — reports land in the tester-feedback "
               "tracker you see on the Issues tab."),
            _n("THE NIGHTLY RESET, which you should tell every tester about: both halves of "
               "the demo pair are wiped back to the sealed golden every night in the "
               "01:00-03:30 Australia/Melbourne window. Everything anyone did that day is "
               "erased — tester content is disposable by design. The tester's ACCESS CODE "
               "is not — the code registry lives outside the wiped site, so the same code "
               "keeps working until it expires (14 days by default); a returning tester "
               "simply joins again with the code they already have."),
            _n("The apply-route bundles (apply-review, apply-auto) are different: those "
               "codes are redeemed on the site's real application form at /apply, not on "
               "/demo/join — they exist to test joining-for-real end to end. The console's "
               "Issue-code dropdown offers only the tester bundles; apply codes are minted "
               "from the workstation with `pl demo codes … issue`."),
        ),
    },
    {
        "id": "backups",
        "title": "Backups — freshness only",
        "summary": "The backup-freshness slice of the todo sweep. Read-only, always.",
        "blocks": (
            _t("The backup-freshness slice of the same `pl todo check` sweep the Todo pane "
               "shows: one priority-chipped row per stale or missing backup, or a green "
               "“no backup-freshness items” line when the sweep is clean on this host."),
            _n("Read-only always — the backup sweeps run where the backups live (the "
               "workstation and the backup hosts), not here. This console can tell you a "
               "backup is stale; fixing it happens on the machine that owns it."),
        ),
    },
    {
        "id": "ci",
        "title": "CI — pipelines on open MRs",
        "summary": "Head pipeline per open merge request, and a retry button.",
        "blocks": (
            _t("Open merge requests per configured CI project, each with its head "
               "pipeline's status chip. An operator can retry a FAILED pipeline from here; "
               "everything else is a deep link into GitLab."),
            _n("With no GitLab token on this host the pane degrades to deep links and says "
               "so. CI is read live on every load — the ⟳ button simply asks GitLab "
               "again."),
        ),
    },
    {
        "id": "quokka",
        "title": "Quokka — chat and voice",
        "summary": "A local model, told only what you may see. Nothing leaves the host.",
        "blocks": (
            _t("Quokka is a local language model running on the console host itself. It is "
               "given a rendered snapshot of live state as context — built from the SAME "
               "scoped gatherers the panes use, so it is never told a fact about a site you "
               "may not see, and it is told which project it is answering inside."),
            _t("It is read-only by construction: the chat path has no route to the action "
               "allowlist, and a test asserts that it cannot acquire one."),
            _l("The brief button asks for a summary over a richer 24-hour context.",
               "If the model is unreachable the tab shows 💤 and says so plainly. Nothing "
               "else on the console depends on it.",
               "Speaking to Quokka is exactly as privileged as typing to it: the microphone "
               "produces text, which is then sent like any other message.",
               "Both speech legs run on this host — no cloud speech service is called, and "
               "the browser's own speech recognition is deliberately never used because in "
               "several browsers it uploads your microphone audio.",
               "The audio itself is never kept: it lives in a locked-down temporary file for "
               "as long as one transcription runs and is shredded afterwards, on success and "
               "on failure alike.",
               "No microphone button means the host has no speech backend installed. Type "
               "instead; nothing is broken."),
            _n("If the mic button is there but the browser says the microphone is blocked, it "
               "is a browser permission, not the console. Allow it in the site settings behind "
               "the padlock and reload."),
        ),
    },
    {
        "id": "visuals",
        "title": "Visuals — overview, charts, and the walkthrough",
        "summary": "Subtabs: estate overview, four read-only charts, and the demo jump-in page.",
        "blocks": (
            _t("A subtabbed collection: the estate overview first, then four charts, then "
               "the walkthrough. Everything is rendered on the console host — no chart "
               "library, no external request — and every chart carries a table view with "
               "the same numbers. The pane repaints itself every two minutes, preserving "
               "the subtab you are on (the walkthrough deliberately does not — its data is "
               "a slow live read, and repainting under your cursor is worse)."),
            _d(
                ("overview", "Estate slots — local host, ops queue, fleet, demo pair — each "
                 "carrying its own age and its own ⟳ (a re-read, not an action)."),
                ("fleet / security / todo", "Charts over the published fleet snapshot. When "
                 "that snapshot is stale a banner says every number below is history — the "
                 "charts never quietly present old numbers as current."),
                ("ci", "The pipeline strip, read live from GitLab — which is why the stale "
                 "banner never covers it."),
                ("walkthrough", "The ONE subtab that acts. Every link is a button that "
                 "mints a one-time login for the demo pair's walkthrough account at CLICK "
                 "time and drops you straight onto that page, signed in — the page you "
                 "were looking at never contained a credential. Targets show their "
                 "verification state (verified, unknown, missing, drifted); “NEVER "
                 "MEASURED” means every target reads unknown until someone runs the "
                 "verify verb where the sites live. Signing out is the site's own confirm "
                 "page — this console cannot do it for you, and says so."),
            ),
            _n("Apart from the walkthrough, no subtab carries a form or a POST anywhere — "
               "a test keeps it that way. The charts can never disagree with the Fleet, "
               "Todo and CI tabs because they render from the same scoped gatherers."),
        ),
    },
    {
        "id": "roles",
        "title": "Roles — who can do what",
        "summary": "Two axes: your console role, and your role inside a project.",
        "blocks": (
            _t("There are two role axes and they are not the same axis. Your GLOBAL role says "
               "what you may do to the console itself. Your PROJECT role says what you may do "
               "inside one project."),
            _d(
                ("viewer (global)", "Read every pane in scope. No actions, no audit page."),
                ("operator (global)", "Viewer, plus the allowlisted safe actions, the issue/CI "
                                      "actions and the audit page — each of which ALSO needs "
                                      "operator in the project you are scoped into."),
                ("owner (global)", "Operator, plus user management, project management, the "
                                   "notifications page, and the unscoped all-projects view."),
            ),
            _d(
                ("viewer (project)", "Read this project's sites, issues and CI."),
                ("operator (project)", "Run the safe actions on this project's demo sites, and "
                                       "read this project's slice of the audit log."),
                ("maintainer (project)", "Assign existing users to this project — but never "
                                         "above their own project role, and never mint a new "
                                         "user (that is an owner power)."),
            ),
            _n("The global role is a CEILING and the project role is a FLOOR, and you need to "
               "clear both. A global viewer recorded as a project maintainer is still, "
               "effectively, a project viewer — a membership can never grant more than your "
               "console role already allows. Equally, a global operator recorded as a viewer in "
               "the project they are scoped into is refused the operator surfaces there; the "
               "console role does not rescue them. An owner is the one exception, resolving to "
               "maintainer in every project."),
            _t("Everything is enforced server-side, per route. A button you cannot see is not "
               "the control; the route refusing you is."),
        ),
    },
    {
        "id": "projects",
        "title": "Projects and scope — why you see what you see",
        "summary": "A project is a named set of sites. It narrows every number on the screen.",
        "blocks": (
            _t("A project is a named set of sites, plus the GitLab issue label and CI projects "
               "that belong with them. Your membership in a project is what decides the "
               "contents of every pane."),
            _d(
                ("Sites", "You see only your project's sites, everywhere — Fleet rows, todo "
                          "items, backup items, and the advisory counts derived from them."),
                ("Issues", "Only issues carrying your project's label. The pane tells you which "
                           "label bounds the view, so an empty list reads as “nothing "
                           "carries this label” rather than “the tracker is broken”."),
                ("CI", "Only the CI projects your project declares, intersected with what this "
                       "console is configured for."),
                ("Demo", "Only your project's demo sites — and an action against another "
                         "project's site is refused by the server, not merely hidden."),
                ("Audit", "Only entries stamped with your project."),
            ),
            _t("The bar under the header shows the active project and spells out the sites it "
               "covers. It rides on every screen that shows you fleet data — the dashboard, all "
               "seven panes, and the audit page — because a dashboard quietly showing a subset "
               "of the fleet is how someone concludes “everything is green” about sites they "
               "cannot see."),
            _t("It is not on every page. The owner-only admin screens (users, projects, alerts), "
               "the no-project landing and the sign-in page carry no bar, because none of them "
               "is reporting fleet state to you in the first place."),
            _l("More than one membership: the bar becomes a picker, and your choice is "
               "remembered on this device.",
               "An owner starts unscoped (“All projects”) and can step into any "
               "single project from the same picker.",
               "Asking for a project you are not in is refused and recorded — never silently "
               "downgraded to something you may see.",
               "Authenticated but a member of nothing: you land on a page that says so. That "
               "is information; a working-looking console showing nothing is not."),
            _n("If this console has no projects at all, none of the above is visible: the "
               "scope bar renders nothing and every pane behaves exactly as it did before "
               "projects existed."),
        ),
    },
    {
        "id": "freshness",
        "title": "Where the numbers come from (and how old they are)",
        "summary": "Published fleet state, its provenance line, and the STALE banner.",
        "blocks": (
            _t("This host has no sites, so it cannot compute fleet state — it DISPLAYS state "
               "published to it by the machine that holds the sites (`pl fleet publish`)."),
            _t("Every pane that shows fleet state therefore carries a provenance line saying "
               "which host produced it and how long ago. Read it. It is the difference "
               "between a number and a claim."),
            _d(
                ("“fleet state from … , N min ago”", "Normal. A published "
                 "snapshot, fresh, filtered to your project if you are in one."),
                ("“⚠ STALE …” (red)", "The snapshot exists but is older than the "
                 "maximum age, and nothing has published since. It is NOT current. The fleet "
                 "tab flags itself too, so a dead publisher is visible from the tab bar."),
                ("“computed on this host …”", "No usable snapshot, so the console "
                 "shelled out locally. On a host with no sites that answers nothing, and the "
                 "pane says so and points at `pl fleet publish` instead of showing a "
                 "healthy-looking empty table."),
            ),
            _n("Publishing is push-only today. If the publishing machine is off, nothing "
               "refreshes — the console cannot pull, because it holds no keys to the sites."),
        ),
    },
    {
        "id": "actions",
        "title": "The actions — and everything that is not one",
        "summary": "A short literal allowlist. No live or prod verb is representable.",
        "blocks": (
            _t("Operators get a small fixed set of actions. They are not built by pasting your "
               "input into a command line: each one is a literal argument list with strict "
               "per-argument validators, and an unknown action is simply rejected."),
            _d(
                ("Re-run RAG fleet check", "Re-runs the fleet grading. It covers the whole "
                                           "fleet, so it cannot be narrowed to a project — a "
                                           "scoped user is refused and told to run it "
                                           "unscoped or on the workstation."),
                ("Demo reset (idle-guarded)", "Resets a demo site, and keeps its idle guard "
                                              "even on the console's button: never green-light "
                                              "a wipe while a tester is mid-session."),
                ("Issue demo invite code", "Mints one invite code for a tester role bundle."),
                ("Revoke demo invite code", "Revokes a code by id."),
                ("Invitation email draft", "Renders a copy-ready invite email. The plaintext "
                                           "codes exist in that response only — the audit log "
                                           "records the sizes, never the draft."),
                ("Jump in (Visuals \u25b8 walkthrough)", "Mints a ONE-TIME login for the demo "
                                                     "pair's walkthrough account and redirects "
                                                     "you straight onto the page you clicked. "
                                                     "The credential is minted on the CLICK, "
                                                     "never on the render, so the page you were "
                                                     "looking at never contained one; it "
                                                     "travels from the verb's output into the "
                                                     "Location header and nowhere else — not "
                                                     "the audit line, not the cache. The "
                                                     "destination must be one of the targets "
                                                     "the verb itself listed for that site, and "
                                                     "a site whose canonical phase is prod is "
                                                     "refused outright."),
            ),
            _t("Issue actions (note, label, close) and the CI pipeline retry are the other "
               "writes. An issue is writable only if it carries one of your project's labels, "
               "re-checked at POST time; if the tracker cannot be reached to prove it, the "
               "write is refused rather than allowed."),
            _n("Nothing on the live or prod tier can be expressed here at all — not deploys, "
               "not restores, not rollbacks, not deletes. That is a property of the allowlist, "
               "not a missing button. Run those where they belong."),
        ),
    },
    {
        "id": "audit",
        "title": "The audit log",
        "summary": "Every action, every denial — at /audit, and in a file on the host.",
        "blocks": (
            _t("Every action POST, every login and every scope denial appends one line to the "
               "console's audit log. A notification pass appends one only when it actually had "
               "something to report: a pass that found no events and sent nothing writes "
               "nothing, so the log is not padded with an entry every interval saying so. "
               "Silence in the log therefore means “no events”, not “the checker stopped” — "
               "the notifications page is where you confirm the checker is alive."),
            _t("The page at /audit is gated on your PROJECT role, not your console role: it "
               "requires operator INSIDE the project you are currently scoped into. That rule "
               "bites in both directions. A console operator who is recorded as a mere viewer in "
               "that project is refused, and switching projects can change the answer. An owner "
               "resolves to maintainer in every project, so an owner always passes."),
            _n("The Audit link in the header is drawn from your CONSOLE role alone, so it is "
               "shown to every operator and owner — including an operator the route will then "
               "refuse. The link is a hint; the route is the rule. That is the same property "
               "stated under “Roles”, seen from the other side."),
            _l("Inside a project you see only entries stamped with that project.",
               "Entries written before projects existed carry no project stamp and are "
               "therefore owner-only — a backfill would have to guess, and a guess in an "
               "audit log is worse than an omission.",
               "The log records what ran and whether it succeeded; it records the transcript "
               "of a voice message but never the audio, and never an invite draft.",
               "On disk it is a JSON-lines file in the console's own state directory, "
               "alongside the user store — both 0600."),
        ),
    },
    {
        "id": "notifications",
        "title": "Push notifications",
        "summary": "Owner-only. Self-hosted Gotify, one channel, deep-linked back.",
        "blocks": (
            _t("The console can speak first: a periodic checker reuses the same gatherers the "
               "panes use and pushes to a self-hosted Gotify server. The page is owner-only "
               "and lists every event with its last-sent time, a test button, and a "
               "“check now” button."),
            _d(
                ("Site goes RAG red", "…and again when it recovers to green."),
                ("New demo-tester issue", "A tester filed something in the tracker."),
                ("Demo reset failed or skipped", "The idle guard or the reset itself."),
                ("Token dead or nearing expiry", "From the token-liveness sweep."),
                ("New security advisory", "A site picked up an advisory."),
                ("CI pipeline failed", "On an open merge request."),
                ("Daily morning brief", "Optional, at a configured time, only if the local "
                                        "model is awake — it is never woken for this."),
            ),
            _l("Notifications are fleet-wide and belong to the operator: there is one channel.",
               "Unconfigured is a silent no-op, not an error — a fresh deploy never fails "
               "because Gotify is absent.",
               "Tapping a push opens the console on the pane that explains it."),
        ),
    },
    {
        "id": "pwa",
        "title": "Phone, PWA and keyboard",
        "summary": "Install it to the home screen; there are no custom shortcuts.",
        "blocks": (
            _t("The console is a Progressive Web App: add it to your home screen and it opens "
               "standalone, without browser chrome. Sessions last a week, in a signed "
               "cookie that is secure, HTTP-only and same-site strict."),
            _l("There is NO offline mode, on purpose. The service worker passes every request "
               "to the network and caches no authenticated page — a console that showed you "
               "yesterday's fleet from a cache would be worse than one that says it cannot "
               "reach the network.",
               "Off the mesh you get exactly that message: the console is unreachable, check "
               "the VPN app is connected.",
               "There are no custom keyboard shortcuts. The tab bar is ordinary buttons, so "
               "Tab moves between them and Enter or Space activates one.",
               "Sign-in needs the passkey to be on the device you are using. An account can "
               "hold several — a hardware key beside a phone — via the owner's \"add key\" "
               "button, which keeps the ones already enrolled. Losing every passkey is an "
               "owner-issued reset, not a password reset."),
        ),
    },
    {
        "id": "library",
        "title": "Library",
        "summary": "The published docs corpus — reached from the Library link in the header.",
        "blocks": (
            _t("The Library is the published documentation corpus, browsable inside the "
               "console at /library, with the same project boundary applied to which "
               "documents you may read."),
            _n("It is in the header, next to this page's ? link — not in the tab bar, which "
               "is full at eight panes. If the Library says nothing has been published on "
               "this host, that is a publishing step nobody has run yet, not an empty "
               "corpus: the two are shown differently on purpose."),
        ),
    },
    {
        "id": "sessions",
        "title": "Sessions — long-running work that survives your laptop",
        "summary": "tmux on the console host; the tab is only the window onto it.",
        "blocks": (
            _t("The Sessions tab lists the tmux sessions on the console host, lets you "
               "start a named one, and lets you join any of them in a real terminal in the "
               "browser. The terminal is the intermittent part; the session is not — it "
               "runs on the host, not on your laptop, so it survives the laptop sleeping, "
               "roaming or dropping off wifi entirely."),
            _d(
                ("Start", "Type a name and press start. The name is the only thing you can "
                          "type here: letters, digits, - and _, up to 32 characters. The "
                          "session starts detached, with your shell, in your home "
                          "directory on the console host."),
                ("Join", "Opens the terminal attached to that session. Run what you like "
                         "there — an agent, a build, `claude` — it is an ordinary shell "
                         "inside tmux."),
                ("Leave", "Close the page, lose the network, or detach with the tmux "
                          "prefix and d. All three are the same event to the session: the "
                          "window went away, the work did not."),
                ("Rejoin", "Come back to the Sessions tab and join again — from this "
                           "device or another one. You land exactly where the session is, "
                           "scrollback and all."),
                ("End", "Exit the shell inside the session (or `tmux kill-session` from "
                        "the terminal). Closing the browser page never ends a session."),
            ),
            _t("The intended shape for long work: start a session here, kick the work off "
               "inside it, close the laptop and walk away. Check in from the tab — phone "
               "included — whenever you are back in range."),
            _n("This tab is OWNER-only, and it is the one place the console hands out a "
               "real shell on its host. Every list, start, join and detach is written to "
               "the audit log; joining needs your signed session cookie on the websocket "
               "itself, so an unauthenticated socket is refused before any terminal "
               "exists. Everything runs on the console host over the mesh — no third "
               "party, no cloud terminal, nothing leaves the tailnet."),
        ),
    },
    {
        "id": "trouble",
        "title": "When a pane looks wrong",
        "summary": "The common shapes, and what each one actually means.",
        "blocks": (
            _d(
                ("Fleet is empty and says it computed locally",
                 "Nothing has been published to this host. Run `pl fleet publish` on the "
                 "machine that holds the sites."),
                ("A red STALE banner",
                 "The publisher stopped. The numbers are real but old — treat them as history "
                 "until the publish cron is healthy again."),
                ("Issues shows only deep links",
                 "No GitLab API token is provisioned on this host. That is a deliberate "
                 "operator step; deploys never copy tokens."),
                ("An empty Issues list inside a project",
                 "Nothing carries your project's label. The pane names the label it filtered "
                 "on, so you can check that first."),
                ("Issues says a tracker is unreadable (http-404)",
                 "This console's GitLab token is walled to one project — 404 is how GitLab "
                 "says 'not authorised'. Give that tracker its own 0600 sibling token file, "
                 "e.g. ~/.config/nwp-console/gitlab.nwc.token. Until then the pane refuses "
                 "to render that queue as empty."),
                ("A tab count is missing",
                 "That one feed failed. Counts are independent and best-effort — the pane "
                 "itself will tell you more."),
                ("“You are not a member of any project”",
                 "Your account exists but has no membership. Only an owner can grant one."),
                ("An action button you expected is absent",
                 "Either your role does not allow it, or the action does not exist here at "
                 "all — nothing on the live or prod tier does."),
                ("Everything 401s or the app will not load",
                 "You are almost certainly off the mesh, or your week-long session expired. "
                 "Reconnect the VPN app, then sign in with your passkey."),
            ),
        ),
    },
)

# id -> section, built once. A duplicate id would silently shadow a section, so
# the tests assert uniqueness against this map's length.
_BY_ID: dict = {s["id"]: s for s in SECTIONS}


def index() -> list:
    """The table of contents: id, title and one-line summary per section."""
    return [{"id": s["id"], "title": s["title"], "summary": s["summary"]} for s in SECTIONS]


def get_section(section_id) -> dict | None:
    """One section, or None for anything that is not one.

    Returns None — never a fabricated empty section — so the route can answer
    404. A help page that rendered an unknown topic as an empty body would be
    indistinguishable from a section someone forgot to write.
    """
    if not isinstance(section_id, str) or not SECTION_ID_RE.match(section_id):
        return None
    return _BY_ID.get(section_id)


def _walkable(section: dict) -> dict:
    """One section, with its block sequence as a LIST rather than a tuple.

    This is not cosmetic. `scope.scrub()` recurses into dicts and lists and
    stops at a tuple — a tuple is returned untouched, contents unexamined. The
    content above is authored as tuples (they are constants), so a help context
    handed over verbatim would be one the scrubber cannot see inside, and the
    "scrub found nothing to drop" test would pass because nothing was LOOKED
    at. Handing over lists means the zero is a measurement.

    tests/test_help.py plants a foreign `site` key and asserts the scrubber
    catches it, so this conversion cannot be quietly removed.
    """
    return dict(section, blocks=list(section["blocks"]))


def page_context(section_id=None) -> dict | None:
    """The render context for /help (whole page) or /help/<id> (one section).

    None means “no such section” and the route must 404.

    The shape is flat and static on purpose: no `prov` key (nothing was
    gathered, so there is no provenance and nothing can be stale), no `res`,
    no row carrying a `site`. `scope.scrub()` and `scope.redact()` are both
    no-ops over it — asserted, and with a positive control proving the
    scrubber can see the context it is finding nothing in.
    """
    if section_id is None:
        sections = [_walkable(s) for s in SECTIONS]
        current = ""
    else:
        one = get_section(section_id)
        if one is None:
            return None
        sections = [_walkable(one)]
        current = one["id"]
    return {
        "help": {
            "index": index(),
            "sections": sections,
            "current": current,
            "single": bool(current),
        }
    }
