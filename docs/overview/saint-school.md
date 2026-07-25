# Saint School (`ss`) — the learning site

*Executive summary. Last updated 2026-07-25.*

## What it is

Saint School is a website of short Catholic formation courses. A member picks a
course, reads each lesson **at whichever depth suits them** — a two-minute summary
or a scholar's treatment of the same material — answers questions as they go, gets
reminded to revisit things before they forget them, and records the one practical
thing they have decided to do about it.

They sign in with their Narrow Way Commons account. There is no second password.

It is built on Moodle, the widely-used open-source learning platform, with eight
custom-built additions that provide the parts Moodle does not have.

## Who it is for

Ordinary Catholics who want to grow in the faith and do not have a theology
degree — with the depth control meaning the *same* course also serves someone who
does.

Two dials, independent of each other:

- **Depth** — six levels, from "Short" to "Scholar".
- **Audience** — courses can be written for young adults, single people, married
  people, religious, or priests, drawing on one shared core rather than being
  written five times.

The first concrete audience being built is young adults (roughly 18–21).

## Where it is up to

**Live**, with **55 courses** and **247 lesson activities** —
213 with questions, 175 with video, 18 with audio.

Recently completed and proven:

- **Single sign-on with Narrow Way Commons works**, verified through a real
  browser six times out of six. A member's account is permanently bound to their
  Commons identity by an internal identifier, not by email address — so changing
  an email address cannot detach or hijack an account.
- **Guild membership flows across automatically.** Join a guild on the Commons
  and the corresponding group appears here.
- **Consent is enforced across the boundary.** If a member has not consented to
  their formation data being stored, this site *cannot* store it. The permission
  travels with the log-in and the site refuses rather than guesses. Verified: a
  consenting member's work persists; a non-consenting member's work is discarded;
  a missing permission is treated as "no".
- **Data-deletion works**, verified across all eleven tables that hold personal
  data, with a control account confirmed untouched.

## What is next

**The one that matters most:** withdrawing consent on the Commons does **not**
currently reach this site's write-gate. The site keeps saving formation data while
the withdrawal form says it has been erased. The fix is built but ships switched
off, awaiting an operator decision and a dedicated access token. This is a real
correctness gap, not a theoretical one.

Also queued:

- Merge the outstanding data-protection review request.
- Build a proper way to keep the custom plugin code in step — there are currently
  three divergent copies of the course-browsing plugin, and one plugin exists on
  the live site but not in the development tree.
- Decide how course visibility is gated (54 courses visible, 1 hidden, with no
  review recorded).
- Declare which course catalogue is the authoritative one. Everything about
  serving different audiences is blocked behind that decision, and the counts in
  the competing catalogues do not agree.
- Upgrade to the next long-term-support release of Moodle.

**A latent data risk worth knowing about:** the spaced-repetition and mastery
records are keyed to an internal activity identifier rather than to the lesson
point itself. Rebuilding a course would orphan every member's revision history.
This must be changed before any rebuild on a site with real members.

## A note on names

The naming here is genuinely confusing and has caused mistakes:

| Name | What it is |
|------|-----------|
| the `ss` hostname | the live address |
| `sites/ssc/` | the current development tree — **this is the one to work in** |
| `sites/ss/` | a build tree holding some newer components |
| `sites/ss2/` | the frozen version 1 archive |
| `sites/ssd/` | the demo copy (currently broken) |
| `sites/saintschool/` | **unrelated** — a different site on another server |

And the live `ss` address serves files from the `ssc` directory. The old `ssc` and
`ss2` addresses redirect to it.

## Where to read more

| For | Read |
|-----|------|
| How it connects to the Commons | `docs/guides/nwc-ssc-architecture.md` |
| Creating a course | `docs/guides/moodle-course-creation.md` |
| The plugin code | GitLab: `nwp/ss-moodle-plugins` |
| The fleet picture | `docs/overview/README.md` |
