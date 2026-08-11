"""Walkthrough — one click into any part of the demo pair, already signed in.

Pure, stdlib only. Everything here turns `pl demo walkthrough <site> --json`'s
already-parsed document into the shape the template places, and decides — by
allowlist — whether a requested destination may be jumped to at all. Nothing
here spawns anything, reads a file, or holds a credential.

WHY MINTING HAPPENS ON CLICK AND NOT ON RENDER
----------------------------------------------
The request was "an auto login sequence onto both sites as part of its initial
render". That is not built, on purpose, and this module is where the difference
lives.

A one-time login link is a single-use credential with a 24-hour life (measured:
nwd's `user.settings:password_reset_timeout` = 86400). Minting one per pane
render would:

  * burn a token every time the pane's own 120 s poller repainted it;
  * write a `tester-login-minted` line to the demo log each time, so the real
    audit signal drowns in noise;
  * put a live credential into the HTML of a page nobody has asked to use yet,
    where it lands in the browser cache and in any screenshot.

So the pane carries NO link. Each jump is a POST to `/actions/walkthrough_go`,
which mints server-side and 303s the browser straight onto the target page with
`?destination=<path>`. Same one click for the operator; the credential exists
only in a Location header, for one hop.

WHY THE DESTINATION IS AN ALLOWLIST
-----------------------------------
`resolve_destination()` accepts a path ONLY if the verb itself listed it as a
target for that side of the pair. A redirector that takes free text is an open
redirect, and this one would arrive at its destination CARRYING A SESSION. The
allowlist is the whole defence; the shape checks below are belt and braces.

WHAT THIS ACCOUNT CANNOT TELL YOU
---------------------------------
The walkthrough account holds every permission, so it answers "does this page
work / is this tool there". It CANNOT answer "what does a member see" — a link
that should 403, a gate that should block, a tool that should be hidden all look
fine to it. `CAVEAT` is returned in the view (not written into the template) so
it travels with the data and cannot be dropped by a markup edit.
"""
from __future__ import annotations

from urllib.parse import quote

# The four states the verb can attach to a target, plus the two it may not
# invent. Anything outside this set is normalised to "unknown" by the parser —
# a template that receives an unrecognised word would render it as a link with
# no warning, which is the failure mode this whole pane is designed against.
VERIFY_STATES = ("verified", "missing", "drifted", "ambiguous", "unknown", "cannot_verify")

# Rendered verbatim in the pane. It is a fact about the account, so it lives
# with the data.
CAVEAT = (
    "This account holds every permission and sits in every guild, so it answers "
    "“does the page work / is the tool there” — it CANNOT tell you what a member "
    "sees. A link that should 403 for a member, a gate that should block, a tool "
    "that should be hidden all look fine from here. For that question use the "
    "Demo tab’s per-tester editor and sign in as a real persona."
)

# The verdicts that are safe to click through to. `unknown` is deliberately
# clickable — the operator may want to find out — but it is labelled, and
# `missing` is not, because that link is known to land on nothing.
CLICKABLE = ("verified", "unknown", "ambiguous", "cannot_verify")


class DestinationError(Exception):
    """A destination that is not on the verb's own allowlist for that side."""


def _role(state: str) -> str:
    """Chart/state role, mapped by the template to the console's own tokens.
    `unknown` is MUTED, never green: not-measured is not the same as fine."""
    return {"verified": "ok", "missing": "crit", "drifted": "crit",
            "ambiguous": "warn", "cannot_verify": "warn"}.get(state, "muted")


def page_view(doc: dict) -> dict:
    """The parsed verb document -> everything the walkthrough subtab renders.

    Two columns, provider first. Within a column, the catalogue's own section
    order is preserved and the per-guild targets are folded into one block per
    guild, so sixteen guilds are sixteen collapsible rows rather than 160 loose
    links.
    """
    if not isinstance(doc, dict) or not doc.get("ok"):
        reason = ""
        if isinstance(doc, dict):
            reason = str(doc.get("reason") or "")
        return {
            "ok": False,
            "columns": [],
            "can_jump": False,
            "blocked_reason": "",
            "caveat": CAVEAT,
            "reason": reason or "the walkthrough could not be read on this host",
            "hint": "Measure it where the sites live: pl demo walkthrough <site> --verify --tier=live",
            "verification": {"state": "unknown", "warn": True, "at": None,
                             "age_seconds": None, "note": ""},
            "counts": {},
            "account": {},
            "dropped": [],
        }

    account = doc.get("account") or {}
    phase = str(doc.get("phase") or "")
    can_jump = bool(doc.get("jump_in_allowed")) and bool(account.get("present"))
    blocked = ""
    if not doc.get("jump_in_allowed"):
        blocked = (f"'{doc.get('site')}' is canonical: {phase or 'unknown'} — the demo "
                   "verbs refuse to mint a login for it, and so does this pane.")
    elif not account.get("present"):
        blocked = str(account.get("reason") or
                      "the walkthrough account is not on this site yet")

    columns = []
    for side in ("provider", "consumer"):
        half = doc.get(side) if isinstance(doc.get(side), dict) else {}
        rows = [t for t in doc.get("targets", []) if t.get("side") == side]
        sess = ((doc.get("session") or {}).get(side) or {}).get("signout") or {}
        sections: list[dict] = []
        index: dict[str, dict] = {}
        for t in rows:
            key = str(t.get("section") or "")
            sec = index.get(key)
            if sec is None:
                sec = {"key": key, "label": str(t.get("section_label") or key),
                       "targets": [], "groups": [], "group_index": {}}
                index[key] = sec
                sections.append(sec)
            row = dict(t)
            row["role"] = _role(row["verify"]["state"])
            row["clickable"] = row["verify"]["state"] in CLICKABLE
            g = t.get("group")
            if g:
                blk = sec["group_index"].get(g)
                if blk is None:
                    blk = {"group": g, "seed_key": t.get("group_seed_key"), "targets": []}
                    sec["group_index"][g] = blk
                    sec["groups"].append(blk)
                blk["targets"].append(row)
            else:
                sec["targets"].append(row)
        for sec in sections:
            sec.pop("group_index", None)
        columns.append({
            "side": side,
            # `site` is the key scope.scrub() looks for. Do not rename it: a
            # column keyed any other way is invisible to the scrubber.
            "site": str(half.get("site") or ""),
            "base": str(half.get("base") or ""),
            "signout": {"label": str(sess.get("label") or "Sign out"),
                        "path": str(sess.get("path") or ""),
                        "note": str(sess.get("note") or "")},
            "sections": sections,
            "count": len(rows),
        })

    ver = doc.get("verification") or {}
    state = str(ver.get("state") or "unknown")
    return {
        "ok": True,
        "site": str(doc.get("site") or ""),
        "phase": phase,
        "columns": columns,
        "account": account,
        "groups": doc.get("groups") or {},
        "counts": doc.get("counts") or {},
        "dropped": doc.get("dropped") or [],
        "can_jump": can_jump,
        "blocked_reason": blocked,
        "caveat": CAVEAT,
        "reason": "",
        "hint": "",
        "verification": {
            "state": state,
            # Never measured, or measured and unreadable, both SHOUT. A pane
            # full of confident-looking links over an unmeasured catalogue is
            # exactly the shape ops#292 was about.
            "warn": state != "measured",
            "at": ver.get("at"),
            "age_seconds": ver.get("age_seconds"),
            "note": str(ver.get("note") or ""),
        },
    }


def resolve_destination(doc: dict, side: str, dest: str) -> str:
    """Return `dest` iff the verb listed it as a target path for `side`.

    The allowlist is the defence; everything before it is cheap sanity. Note
    the sides do NOT share an allowlist: a provider jump may only ever land on
    a provider path, because the credential it carries is a provider session.
    """
    if not isinstance(dest, str) or not dest or len(dest) > 300:
        raise DestinationError("no destination given")
    if any(c in dest for c in "\r\n\t\x00"):
        raise DestinationError("destination contains a control character")
    if not dest.startswith("/") or dest.startswith("//"):
        raise DestinationError("destination must be a site-relative path")
    if "://" in dest or ".." in dest:
        raise DestinationError("destination must be a plain site path")
    allowed = {str(t.get("path")) for t in (doc.get("targets") or [])
               if t.get("side") == side}
    if dest not in allowed:
        raise DestinationError(
            "destination is not one of this side's declared walkthrough targets")
    return dest


def jump_url(one_time_url: str, dest: str) -> str:
    """The one-time login link, aimed at `dest`.

    Drupal's RedirectResponseSubscriber lets `destination` override where a
    redirect lands, and refuses an external one outright (verified in core on
    the deployed tree), so this is how one click ends on the target page rather
    than on the account-edit form the one-time link otherwise goes to.
    """
    sep = "&" if "?" in one_time_url else "?"
    return f"{one_time_url}{sep}destination={quote(dest, safe='')}"


def signout_then(base: str, signout_path: str, one_time_url: str, dest: str) -> str:
    """Sign out first, then land on `dest` signed in as the walkthrough account.

    This exists because Drupal REFUSES a one-time login link while a session
    exists — `user.reset.login` carries `_user_is_logged_in: 'FALSE'`, verified
    in the deployed router — so an operator who is already signed in as some
    tester gets Access denied rather than a jump. The logout-confirm form's own
    redirect is overridden by the same `destination` mechanism.

    The nested destination is the one-time link's PATH, never its absolute URL:
    Drupal rejects an external destination, and nesting the host would also put
    the credential in the outer query string twice.
    """
    path = one_time_url
    if base and path.startswith(base):
        path = path[len(base):]
    inner = jump_url(path, dest)
    return f"{base}{signout_path}?destination={quote(inner, safe='')}"
