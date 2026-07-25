# Narrow Way Commons (`nwc`) — the community site

*Executive summary. Last updated 2026-07-25.*

## What it is

Narrow Way Commons is where the people are. A member applies once, joins one or
more **guilds** (small communities with a shared craft — theology, writing,
teaching, coding, media), works through a formation ladder tied to the Saint
School courses, and contributes: stories from their own experience, notes and
annotations on the material, video clip choices, edits and corrections.

What they contribute goes through review before it is published, and is released
into the public domain so anyone can use it.

It is built on Open Social, an open-source community platform, on top of Drupal.

## Who it is for

Catholics who want to belong to something, not just consume something. The
membership model is unusually explicit:

- **9 guilds** — Sojourners, Theology, Trialing (the Tester's Guild), Shepherds,
  Copyright, Media, Pedagogy, Writers, Coders.
- **9 interest groups** — open feeder communities anyone can join.
- **Sojourners has 12 levels**, from Inquirer to Abider, earned by completing
  courses and clusters. Every member is a Sojourner.
- **Shepherds** are invitation-only oversight, with decision rules that scale:
  one person may act alone, two or three must all agree, four or more take a
  majority.
- Levels belong **within** a guild. There is no cross-guild points currency — a
  deliberate decision, taken after the alternative was proposed and rejected.

## The big change of 2026: consent as a functionality gate

The old model made every agreement compulsory, and froze members who declined out
of the whole site. That was judged both coercive and legally shaky — consent
extracted under threat of exclusion is not freely given.

The new model, now built and proven:

- **Three agreements remain compulsory** to be a member at all: the terms, the
  acceptable-use policy, and the privacy policy.
- **Two agreements are genuinely optional**, and declining them costs you a
  feature rather than your membership:
  - Decline the **contribution agreement** (which places your work in the public
    domain) → you stay a full member, but read-only.
  - Decline **consent for formation data** (which is legally sensitive
    religious-belief data) → you stay a full member in **Trialing mode**.
- **Trialing mode** means you can work through a curated subset of courses with
  nothing recorded. A persistent banner says so plainly. The same mechanism serves
  three different people: an anonymous visitor trying a course, a member who
  declined, and a tester who does not want to generate real data.

Crucially, this decision travels across the boundary. The Commons tells Saint
School whether a member has consented, and Saint School **refuses to write**
rather than guessing. If the message is missing, the answer is no.

An adversarial review of the first implementation found three ways it could have
failed *open* — including a default that would have permitted writes when the
answer was unknown. All three were fixed before it shipped. That review was worth
more than the feature.

## Where it is up to

**Live**, but **registration is still administrator-only** —
it is live, not yet open to the public.

Recently shipped: search moved to a simpler backend, a feedback triage system,
an error-report button, a help section with 44 topics, and the teaching-checkpoint
editor.

## What is next

**One trio stands between the consent system and real members:**

1. A data-protection officer must ratify the wording of the consent text.
2. One sign-in must be tested through a real browser on the test tier.
3. The configuration must be imported.

Then: switch on the consent-withdrawal bridge to Saint School.

After that, the queue is about making it understandable — which is the point of
this batch of work:

- Reorganise the help section as an accordion with counts, so it is navigable
  rather than a wall of text.
- Give the application form a proper introduction explaining how the whole system
  works before it asks for agreements.
- Offer **explanation depth levels** — plain, normal, technical — across both the
  help section and the application form.
- Rewrite the copy to reflect the new consent model.

Designed but not built: the skill-level system (guilds exist, the levels within
them are not yet materialised), audience interest groups, and possibly a fifth
guild.

## Relatives

| Site | Relationship |
|------|--------------|
| **avc** (AV Commons) | the frozen predecessor. Narrow Way Commons replaced it feature by feature. |
| **nwd** | the demo copy, wiped and rebuilt regularly so testers can break it. |
| **nw1** | an archived earlier version. |
| **ssc** (Saint School) | the paired learning site. One account spans both. |

**Standing rule:** never push a whole database to the live Commons. Doing so
rewrites every internal user identifier, which severs the single-sign-on link and
locks every member out of Saint School. Deploy code only.

## Where to read more

| For | Read |
|-----|------|
| How it connects to Saint School | `docs/guides/nwc-ssc-architecture.md` |
| Getting started as a member | `docs/guides/member-getting-started.md` |
| Deploying a change | `docs/guides/howto-deploy.md` |
| The demo copy | `docs/guides/howto-demo-tier.md` |
