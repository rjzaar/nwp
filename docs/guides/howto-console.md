# How to: use the NWP Console

**Who this is for:** anyone who wants to check on the fleet, or do a small safe
task, from a phone.
**Last updated:** 2026-07-25

---

## What it is

The Console is a small website that shows you what NWP is doing and lets you
press a few safe buttons — from your phone, in the queue at the shops, without a
laptop and without a terminal.

```
https://console.<your-domain>:<port>/
```

It runs on the console host — one of the home machines, named in `nwp.yml` under
`settings.console`. It is **not on the public
internet**: the address resolves everywhere, but it only *answers* if your device
is on the private network mesh.

---

## The three locks on the door

You get in only if all three are satisfied. Each is independent of the others.

1. **You must be on the mesh.** The app listens on a private network address
   only. From an ordinary internet connection there is nothing to connect to — no
   login page, no error, no server. Install the mesh client (Tailscale app,
   pointed at our own control server) and join.
2. **You must have a passkey.** There are no passwords, so there is nothing to
   guess, phish or reuse. You sign in with a hardware security key or the
   fingerprint/face unlock on your phone. Sessions last 7 days.
3. **Your role must allow it.**

| Role | Can do |
|------|--------|
| `viewer` | look at everything |
| `operator` | + press the safe action buttons |
| `owner` | + add and remove people |

---

## What the tabs show you

Seven full-screen tabs, each with a live count in the tab bar so you can see at a
glance whether anything needs you. On a phone they are along the bottom.

| Tab | What it tells you |
|-----|-------------------|
| **Fleet** | every site's health as red / amber / green |
| **Todo** | the things NWP thinks need doing |
| **Backups** | which sites have gone stale (read-only) |
| **Demo** | the demo site's last reset and its outstanding invite codes |
| **Issues** | the GitLab issue queue, with actions built in |
| **CI** | what is building right now |
| **Quokka** | a local AI assistant that can answer questions about the current state |

### Quokka

Quokka is a language model running **on our own hardware** — nothing you type
goes to any outside company. It is given a snapshot of the current fleet state so
it can answer things like "what changed today?"

It can **only read and describe**. It has no ability to run anything; that
restriction is enforced by checking the code's structure, not by asking it
nicely.

Try `summarize today` or open `/quokka/brief`.

---

## The buttons you can press (operator role)

Only five actions exist, and they are a fixed list — not a general command box:

| Button | What it does |
|--------|--------------|
| Re-run RAG fleet check | refresh the red/amber/green picture |
| Demo reset | wipe and rebuild the demo site (skips if someone is active) |
| Issue demo invite code | one code, one level |
| Invitation email draft | the full ready-to-send invite email |
| Revoke demo invite code | kill a leaked code |

> **Nothing that touches live or production can be expressed here at all.** Not
> disabled, not permission-gated — *not representable*. Words like `stg2live`,
> `live2prod`, `rollback`, `restore`, `delete` and `secrets` are on a refusal
> list, and the console host holds no production keys in the first place. If you
> need to deploy, go to a workstation.

Every button press is written to an audit log, viewable at `/audit`.

---

## Setting it up (one-off, from your workstation)

```bash
pl console dns                              # point the address at the mesh
pl console cert                             # get the HTTPS certificate
pl console deploy                           # ship the app to the host and start it
pl console user add rob --role owner        # prints a ONE-TIME enrolment link
```

Open that enrolment link **on the device that holds your passkey**. It is valid
for 48 hours and works once.

Adding someone else:

```bash
pl console enroll                    # get them onto the mesh first
pl console user add sam --role viewer
pl console user role sam operator
pl console user list
pl console user rm sam
```

### Locked out?

```bash
pl console user reset rob      # revokes their passkeys, issues a fresh link
```

This deliberately only works from a shell on a trusted machine. It is the
break-glass path and cannot be triggered from the web interface.

---

## Keeping it running

```bash
pl console status     # is it up?
pl console logs       # what has it been saying?
pl console deploy     # ship an update
```

**Certificates expire every 90 days.** Re-run `pl console cert` — it is safe to
run any time. There is no automatic renewal yet; put a reminder somewhere.

---

## Honest limitations

- The Fleet tab reflects what the **console host** knows, which may lag your
  workstation. For
  the authoritative picture run `pl rag` on the workstation.
- Some panes read human-readable output and parse it approximately. The raw text
  is always kept in a collapsible block underneath so you can check.
- The Backups tab is read-only — backups run where the backups live.
- Without a GitLab token on the host, the Issues and CI tabs degrade to plain
  links into GitLab. Nothing breaks; you just get less detail.

---

## Quick reference

| I want to… | How |
|------------|-----|
| Check the fleet from my phone | open `https://console.<your-domain>:<port>/` while on the mesh |
| Reset the demo site | Demo tab → Demo reset |
| Invite a tester | Demo tab → Invitation email draft |
| See who did what | `/audit` |
| Add a person | `pl console user add <name> --role viewer` |
| Fix a lockout | `pl console user reset <name>` |
| Renew the certificate | `pl console cert` |

## See also

- [How to: run the demo tier](howto-demo-tier.md)
- [How to: issue demo invite codes](howto-invite-codes.md)
- `scripts/console/README.md` — the technical detail and the security model
