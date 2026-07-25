# Overview — what all of this is, and how it fits together

*Written for someone new, or for someone who has been away. Plain language, no
assumed knowledge. Last updated 2026-07-25.*

---

## The one-paragraph version

There are four projects. **Saint School** teaches — short Catholic formation
courses you can read at whatever depth suits you. **Narrow Way Commons** is the
community around it — you apply once, join a guild, and contribute what you learn
back. **theocat** is the library underneath — the theological sources, and the
tools that check a quotation is real. **NWP** is the toolbox that builds, backs up
and deploys all of it safely.

One account gets you into the first two. The other two you never see as a member.

---

## The four projects

| | What it is | Who sees it | Read more |
|-|------------|-------------|-----------|
| **NWP** | the toolbox that runs everything | operators only | [nwp.md](nwp.md) |
| **Saint School** (`ss`) | the courses | members | [saint-school.md](saint-school.md) |
| **Narrow Way Commons** (`nwc`) | the community | members | [narrow-way-commons.md](narrow-way-commons.md) |
| **theocat** | the theology source library | writers and reviewers | [theocat.md](theocat.md) |

There is also **`dir`** (Divine Intimacy Radio) — a searchable archive of a
Catholic podcast. Whether it becomes part of the Commons or stays its own thing
has been an open question; see [the dir question](dir-question.md) for the
research and a recommendation.

---

## How a member experiences it

1. They apply at **Narrow Way Commons**. One form, once.
2. Approved, they get an account — and the same account already works on **Saint
   School**. No second password.
3. They take courses on Saint School. Their progress, and their guild memberships,
   flow between the two sites automatically.
4. They contribute back on the Commons: a story about how a lesson landed in real
   life, a correction, a better video clip. It is reviewed, then published.
5. What they contribute is released into the public domain, so anyone can use it.

The seam between the two sites is meant to be invisible. Most of the engineering
described below exists to keep it that way.

---

## How the pieces connect

```
        theocat                        NWP
   (verified sources)          (builds, backs up, deploys
           │                     — all of the below)
           │  feeds course content        │
           ▼                              ▼
   ┌──────────────────┐   one account   ┌──────────────────┐
   │  Narrow Way      │◀───────────────▶│  Saint School    │
   │  Commons         │   consent       │  (Moodle)        │
   │  (Drupal)        │   guilds        │                  │
   │                  │   identity      │                  │
   │  the community   │                 │  the courses     │
   └──────────────────┘                 └──────────────────┘
           │                                     │
           └──── nwd (demo copy) ── ssd (demo copy) ────┘
                  reset regularly, safe to break
```

Three things travel across the seam:

- **Identity.** The Commons is the source of truth for who someone is. Saint
  School binds each account permanently to a Commons identifier — not to an email
  address, so changing an email cannot detach or hijack an account.
- **Guilds.** Join a guild on the Commons and the matching group appears on Saint
  School.
- **Consent.** Whether a member has agreed to their formation data being stored
  is decided on the Commons and *enforced* on Saint School. If the answer does
  not arrive, Saint School refuses to store rather than assuming yes.

---

## The shared infrastructure

**One small server does most of it.** A single machine hosts every Drupal site,
every Moodle site, the mail system, and — for now — the code server too. It has
**3.8 gigabytes of memory**. That is not much, and it has been taken down by a
single heavy command. Splitting the code server onto its own machine is planned.

**Two homes for code, deliberately.** A public-facing GitLab server holds the code
that can be shared. A set of private mirrors on a home machine holds what must
never touch a shared server — the operations notes, theocat, the transcript
corpus. Material moves one way only: private to public, once it has been checked.

**One backup chain.** Every site is backed up nightly on the server, pulled to
encrypted drives at home, and archived in two tiers: raw copies deleted after 30
days, and copies with all personal data scrubbed out kept for years. The whole
chain was rehearsed on two throwaway servers in July 2026 and scored 16 out of 16,
including a restore and a check that the raw copies really do contain data and the
scrubbed ones really do not.

**One toolbox.** Drupal or Moodle, every site is a folder with a settings file,
driven by the same commands, behind the same safety gates.

**One rule above all the others.** No machine that runs AI may write to a real
production server. Production writes require a physical security key to be
touched. See [nwp.md](nwp.md).

---

## Where each project stands, in one line

| Project | Status |
|---------|--------|
| **NWP** | version 0.30.0; a large safety-and-recovery programme just completed; a release tag is overdue |
| **Saint School** | live with 55 courses; sign-on and consent proven end to end; one real gap — consent withdrawal does not yet propagate |
| **Narrow Way Commons** | live but registration is administrator-only; consent system built and proven; awaiting legal sign-off before opening to members |
| **theocat** | working and useful; deliberately private; one tool left to build |
| **dir** | gated test site; its search capability has already been superseded by a faster replacement that is built but not deployed |

---

## The honest list — what is not right yet

Worth stating plainly, because a summary that only lists achievements is not a
summary.

1. **Consent withdrawal does not reach Saint School.** The fix exists but ships
   switched off. Until it is switched on, the withdrawal form promises more than
   the system delivers.
2. **Legal sign-off is the gate on real members.** Every machine-checkable
   condition is met. What remains is a human ratification of wording.
3. **Configuration is not managed as code** on most sites. The mechanism now
   exists; the rollout does not.
4. **Documentation had drifted badly** from the code. This batch of work is the
   correction; a catalogue of what was wrong is in the merge request that
   introduced these pages.
5. **Several sites have configuration that no longer matches reality** — old
   addresses still declared live, a site settings file left behind by a rename.
   Nothing a visitor sees, but tools reading those settings aim at the wrong
   place.
6. **The main server is one heavy command away from an outage.** It has happened.

---

## Where to go next

| If you want to… | Go to |
|-----------------|-------|
| Understand one project properly | the four summaries linked above |
| Click through everything and check it works | [test-links.md](../guides/test-links.md) |
| Learn the everyday commands | [howto-backup-restore.md](../guides/howto-backup-restore.md), [howto-deploy.md](../guides/howto-deploy.md) |
| Understand disaster recovery | [howto-dr-chain.md](../guides/howto-dr-chain.md) |
| Run the demo site | [howto-demo-tier.md](../guides/howto-demo-tier.md) |
| Check the fleet from your phone | [howto-console.md](../guides/howto-console.md) |
| Know about `dir` | [dir-question.md](dir-question.md) |
