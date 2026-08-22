# theocat — the theology source library

*Executive summary. Last updated 2026-07-25.*

## What it is

Theocat (theology + Catholic) is a package manager for Catholic theological texts.
You run one command to install large collections of source material — Aquinas, the
Church Fathers, the Councils, Scripture, the Doctors of the Church — then search
across all of them at once, and use its tools to check whether a quotation or a
citation in a document is actually real.

The comparison that makes it click: it is to theological texts what an app store
is to apps. The core program contains **no texts at all** — it is a catalogue and
an installer. Each collection is a separate package you choose to install.

## Who it is for

Researchers, curriculum writers, and anyone using AI to help with theological
work — where the risk is not that the AI writes badly but that it invents a
plausible-sounding quotation. Theocat exists so that claims can be checked against
real sources rather than trusted.

Within this ecosystem it plays a specific role: it is the **verification layer**
behind the course content, and it holds the source material for the young-adult
courses.

## What is in it

- **8 first-party collections**, about 2 terabytes fully installed: Aquinas, the
  English Fathers, the Medieval and Reformation-era Doctors, the Councils, a
  Doctors index, modern public-domain works, and public-domain Scripture.
- **11 third-party collections** referenced and installed as-is, never copied or
  forked — including the Latin and Greek patrologies.
- **4 tools**: a quotation verifier, a citation checker, a document generator, and
  a catalogue browser.
- **About 4,600 lines of methodology guidance** on doing theological work
  accurately with AI assistance.

Two notable things it has produced:

- **Open Dogmatics** — a copyright-free systematic-theology reference covering the
  same ground as the standard modern textbook, with **290 propositions**, each
  carrying its traditional theological weight, its citations, and proofs drawn
  only from public-domain sources. 218 of them are already mapped to Saint School
  courses.
- **A pseudo-Catechism** — every paragraph of the Catechism mapped to equivalent
  public-domain source material. **2,840 paragraphs** mapped so far.

## Where it is up to

Working. The command-line tool installs, updates, searches and reports. The
quotation verifier and citation checker both work, online and offline, with fuzzy
matching for imprecise quotations.

**It is deliberately private.** Its only backup is a private mirror on a home
machine; it is never pushed to the shared code server, because the collections it
installs include copyrighted material. The core framework is public-domain
licensed and is intended to be published eventually; the operator-only catalogue
entries need separating out first — roughly an hour's work, not yet done.

Last substantial work: July 2026.

## What is next

One concrete item: a single `theocat review <file>` command that bundles the
existing tools into one report — verify the quotations, validate the citations,
scan for copyright problems, classify the theological weight of each claim, and
check each source against a hierarchy of authority (Scripture above Councils
above the Catechism above the standard references above Aquinas above the Fathers
above private opinion).

That report would then run automatically on every proposed change to the course
catalogue.

**The standing principle, and it is not negotiable:** *theocat assists, never
auto-approves.* It reduces how much a reviewer has to check. Final approval is
always a qualified human being.

Also proposed: a package of the public-domain Second Vatican Council documents,
which is a current gap in the collection.

## A caution on the record

Some of the material in theocat's private research sections was assembled by AI
agents drawing on the web. It is useful and was judged against Church teaching,
but the citations should be checked against critical editions before being used
formally. This caution is recorded in the source index and is repeated here
because it is easy to forget.

## Where to read more

| For | Read |
|-----|------|
| The tool itself | `~/theocat/README.md` |
| Its role in course content | `docs/proposals/F30-content-federation-network.md` |
| The course architecture | NWP-ADR-0027 (`docs/decisions/0027-unified-course-content-architecture.md`) |
