# NWP — Narrow Way Project

*Executive summary. Last updated 2026-07-25.*

## What it is

NWP is the toolbox that builds and looks after all the other projects. It is a
single command — `pl` — that creates websites, backs them up, tests them, and
moves them safely from a laptop to a real server on the internet.

Think of it as the difference between a builder with a van full of tools and a
builder with a bag of hammers. Every site in the fleet is created, updated,
backed up and restored the same way, by the same commands, with the same safety
checks — whether it is a Drupal community site, a Moodle learning site, or a
GitLab server.

## Who it is for

Primarily one technical operator running a fleet of sites, and the AI assistants
working under him within a hard permission boundary. Secondarily, any Catholic
organisation that wants to host its own version of these sites without rebuilding
everything from scratch.

It is not a product for teams — it is deliberately a single-operator system.

## The one idea worth understanding

**No machine that runs AI may write to a real production server.** Ever.

Instead, trust flows through *signatures*, not through machines. Work is built and
signed on machines that can run AI, and applied to production by a separate,
usually-offline machine that verifies those signatures and requires a physical
security key to be touched. If a workflow seems to need an AI machine to reach
production, the workflow is wrong.

This one constraint explains most of NWP's otherwise-surprising design: why
backups are *pulled* rather than pushed, why there are so many separate
environments, why deployments have so many gates, and why nothing is trusted just
because of where it came from.

## Where it is up to

**Version 0.30.0.** About 95 command families; 32 architecture decision records;
27 site directories; two servers under management.

A large consolidation programme ran through July 2026 and has essentially
completed. It delivered:

- **Safer deployments** — the production deployment path now has the same
  protections the live path had: take a snapshot first, switch on maintenance
  mode, and stop rather than continue if either fails.
- **Real backup retention** — backups older than 30 days are now actually deleted,
  which is what members are promised. The newest is always kept.
- **Verified restores** — a restore checks the backup's fingerprint before
  overwriting anything.
- **A two-tier disaster-recovery chain** — raw copies kept 30 days, and separate
  copies with all personal data scrubbed out kept for years. Proven end to end on
  two throwaway servers, scoring 16 out of 16.
- **A configuration-drift gate** — catches settings changed directly on a server
  that a deployment would silently wipe. Off by default.
- **A demo tier** — a copy of the community site that resets from a known-good
  state, so testers can break things freely.
- **A web console** — the fleet's status and a few safe actions, on your phone,
  over the private network, secured with passkeys.

Two real bugs surfaced by actually running this work are worth recording: a
restore check that printed "FAIL" and then reported success anyway, and — more
seriously — **the hardware deploy gate was being silently skipped** because a
library was never loaded. Both are fixed. Both were found by running the code, not
by reading it.

## What is next

**Immediate:**

- Merge the outstanding review requests (the demo-tier cutover in particular).
- Tag a release — a lot of shipped work is sitting in the "unreleased" section.
- Fix the documentation drift this batch has catalogued.

**Blocked on decisions or hardware:**

- The nightly demo reset needs an access decision (the machine meant to run it has
  no key to the server, and granting one would be over-privileged).
- One architecture validation needs a throwaway server and a more capable
  cloud-provider token.

**Known structural weaknesses, honestly stated:**

1. Configuration is still not managed as code on most sites. The mechanism now
   exists; the rollout is a per-site judgement call.
2. Personal data is scrubbed on the server itself on only one path. Everyday
   pulls from live still bring raw data through the workstation first.
3. A meaningful amount of operational knowledge has lived in AI memory rather than
   in the repository. Some of that has now been written down; more remains.

## Where to read more

| For | Read |
|-----|------|
| The whole system, mapped | `docs/guides/using-nwp.md` |
| Getting started | `docs/guides/quickstart.md` |
| Everyday backup and restore | `docs/guides/howto-backup-restore.md` |
| Deploying a change | `docs/guides/howto-deploy.md` |
| Disaster recovery | `docs/guides/howto-dr-chain.md` |
| The trust model | `CLAUDE.md` § Threat Model, and ADR-0017, 0024, 0028 |
