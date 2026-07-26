# How to: issue demo invite codes

**Who this is for:** whoever is recruiting testers for the demo site.
**Last updated:** 2026-07-26

---

## How joining works, from the tester's side

1. You send them a code, e.g. `Kolbe-9305`.
2. They open the demo site's `/demo/join` page (the exact address is in the
   invitation email `pl demo invite` generates for you).
3. They paste the code.
4. They are in — with an account already made for them, named after a saint.

They never type an email address or a real name. Nothing about them is stored.
The code decides what they can do.

---

## The five levels you can hand out

Each code is tied to a **role bundle** — the set of permissions the tester gets.

| Bundle | What they can do | Offered by default? |
|--------|------------------|---------------------|
| `tester-member` | an ordinary verified member | ✅ yes |
| `tester-guild-leader` | member, plus leading a guild (small group) | ✅ yes |
| `tester-content-manager` | manage content across the site | ✅ yes |
| `tester-copyright-reviewer` | plus the copyright review queue | only if asked |
| `tester-safeguarding-reviewer` | plus the safeguarding review queue | only if asked |

> **Site manager is never offered.** The most powerful bundle is *content
> manager*. Nobody gets full control of the site through an invite code.
>
> The two reviewer bundles are opt-in because reviewer queues are a narrower ask
> — you normally recruit for those separately.

---

## The one command you will use most

```bash
pl demo invite nwd --tier=live
```

> **`--tier` is required, and there is no default.** `--tier=live` is the public
> demo site — the one your testers will open — and is what you want almost every
> time. `--tier=dev` targets the local DDEV copy on your own machine.
>
> It used to default to `dev`, which meant that leaving the flag off printed a
> perfectly good-looking invitation whose codes had been loaded into the copy on
> your laptop. The live site had never heard of them, so every recipient was
> turned away at `/demo/join`, and nothing in the output said so. The command now
> refuses rather than guess. (It refuses *before* issuing anything, so a refusal
> never burns a code.)

This does three things at once:

1. Issues **one fresh code per level** (the three default levels).
2. Renders a **complete, ready-to-send invitation email** — plain language, no
   jargon, explaining what the site is, what you're asking for, that everything is
   wiped nightly, and how to join in three steps.
3. Saves that email as a draft at `sites/nwd/demo-invites/invite-<timestamp>.md`,
   readable only by you (mode 0600).

The email contains a separate block for each level. **Delete the blocks the
recipient should not get**, then paste the rest into any mail client and send.

### Variations

```bash
pl demo invite nwd --tier=live --all                       # include both reviewer levels
pl demo invite nwd --tier=live --bundles tester-member     # just one level
pl demo invite nwd --tier=live --bundles tester-member,tester-guild-leader
pl demo invite nwd --tier=live --expiry 30d                # default is 14d
```

An unknown bundle name is rejected outright rather than silently ignored.

---

## Managing codes directly

```bash
pl demo codes nwd list                                     # what exists (hashes and IDs only)
pl demo codes nwd issue tester-member --tier=live          # one code, printed ONCE
pl demo codes nwd issue tester-member --tier=live --expires=30d
pl demo codes nwd revoke 7 --tier=live                     # kill code #7
pl demo codes nwd rotate --tier=live                       # revoke everything, reissue one per level
pl demo codes nwd sync --tier=live                         # re-push the registry into the site
```

`list` is read-only and needs no `--tier`. The other four all write codes into a
running site, so each one must name the tier. `revoke` is the sharpest of them:
revoking against `dev` while the code is live in the site's state leaves the
code **still redeemable** on the live site, which is the opposite of what you
asked for.

---

## Three things about codes you must internalise

### 1. The code is shown exactly once

The registry stores only a **hash** — a one-way fingerprint. Nobody, including
you, can read a code back out of it later. If you lose the plaintext, you revoke
that code and issue a new one. There is no recovery.

That is why `pl demo invite` writes a 0600 draft file: it is the only place the
plaintext survives after the command finishes.

### 2. Delete the draft after you send it

`sites/nwd/demo-invites/*.md` contain **plain-text codes**. Once the email is
sent, delete the draft. The registry keeps everything it needs.

Drafts are never overwritten — a second invite in the same second gets a `-2`
suffix — precisely because the codes in an old draft exist nowhere else.

### 3. Codes survive the nightly wipe

The registry lives **outside** the golden image and is re-pushed into the site
after every reset. So a code you sent last week still works after tonight's wipe,
right up until its expiry date. Tell testers this — it is in the email template
already.

If codes ever stop working after a reset, the re-push failed:
`pl demo codes nwd sync --tier=live`.

---

## Distribution rules

- **Invited helpers only.** Never post a code publicly, in a newsletter, or on
  social media. One leaked code is one uninvited account per person who sees it.
- **One code per level, not per person, is fine** for a small trusted group — but
  if you want to revoke one person's access without disturbing the others, issue
  them their own code.
- If a code leaks: `pl demo codes nwd revoke <id> --tier=live`, then reissue.
  Check afterwards with `pl demo codes nwd list --tier=live` that the code you
  meant to kill is gone from the tier you meant to kill it on.
- After any round of testing you no longer need:
  `pl demo codes nwd rotate --tier=live`.

---

## Built-in protections

| Protection | What it stops |
|------------|---------------|
| Rate limiting | someone guessing codes by brute force |
| Expiry | an old code working forever |
| Forbidden-role guard | a code ever granting a role it should not |
| Consent seeding | new demo accounts arriving without the data policies applied |
| Mail disabled | the demo site emailing anyone by accident |
| `noindex` | search engines listing demo pages |
| Banner | a visitor mistaking the demo for the real site |

---

## Quick reference

| I want to… | Command |
|------------|---------|
| Invite some testers (the usual case) | `pl demo invite nwd --tier=live` |
| Invite reviewers too | `pl demo invite nwd --tier=live --all` |
| One code, one level | `pl demo codes nwd issue tester-member --tier=live` |
| See what's outstanding | `pl demo codes nwd list --tier=live` |
| Kill a leaked code | `pl demo codes nwd revoke <id> --tier=live` |
| Start over | `pl demo codes nwd rotate --tier=live` |
| Codes stopped working | `pl demo codes nwd sync --tier=live` |

## See also

- [How to: run the demo tier](howto-demo-tier.md)
- [How to: use the NWP Console](howto-console.md) — there is an invite button on the phone
