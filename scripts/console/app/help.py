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
    Help is STATIC and site-agnostic. It carries no provenance (nothing was
    gathered, so there is nothing to be stale) and — deliberately — names no
    site anywhere, so `scope.scrub()` has nothing to drop and `scope.redact()`
    has nothing to strip. Both are no-ops over this context BY CONSTRUCTION,
    and tests/test_help.py pins that rather than trusting it.

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
        "title": "The panes, one by one",
        "summary": "Fleet, Issues, Todo, Demo, Backups, CI, Quokka — what each actually shows.",
        "blocks": (
            _t("The tab bar is the whole UI: one full-screen pane at a time, in this order."),
            _d(
                ("Fleet", "One row per site in scope: its RAG grade, its canonical phase, the "
                          "reasons behind the grade, and — when the snapshot carries the security "
                          "feed — a clickable advisory count that opens that site's advisory "
                          "detail further down the pane."),
                ("Issues", "Open issues from the ops tracker in GitLab. An operator can add a "
                           "note, add or remove a label, or close one. With no API token "
                           "provisioned on the host the pane still renders and simply "
                           "deep-links into GitLab instead."),
                ("Todo", "The `pl todo check` sweep as a FLAT list — one row per item, in the "
                         "order the sweep emitted them, each row naming its site in bold and "
                         "carrying a high/medium/low priority chip. It is not grouped or "
                         "re-sorted by site. The table shows the first 60 items; the counts "
                         "above it describe the whole set."),
                ("Demo", "Per demo-tier site: its reset status as a few highlight lines, with "
                         "the full output one tap away, and its invite-code registry — which "
                         "lists HASHES and ids only, never a usable code. Operators get the demo "
                         "actions here. When a reset failed or was skipped it is the Demo TAB "
                         "that raises a dot, not a flag inside the pane."),
                ("Backups", "The backup-freshness slice of the same todo sweep. Read-only "
                            "always — the sweep runs where the backups live, not here."),
                ("CI", "Open merge requests per configured CI project with their head "
                       "pipeline. An operator can retry a pipeline."),
                ("Quokka", "The local-model chat tab. 🟢 means the model answered a health "
                           "check within the last minute; 💤 means it is asleep or "
                           "unreachable, and the other tabs are unaffected."),
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
               "Sign-in needs the passkey to be on the device you are using. Losing every "
               "passkey is an owner-issued reset, not a password reset."),
        ),
    },
    {
        "id": "library",
        "title": "Library",
        "summary": "The published docs corpus — a separate section, not yet wired here.",
        "blocks": (
            _t("The Library is the published documentation corpus, browsable inside the "
               "console at /library, with the same project boundary applied to which "
               "documents you may read."),
            _n("It is delivered as its own stage. If the header has no Library link on this "
               "install, it is not wired here yet — that is the only thing the link's absence "
               "means."),
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
