# ADR-0038: Forge-box identity scheme — named scoped keys, and a bounded forge-admin credential tier

**Status:** Proposed (Linux plane IMPLEMENTED and installed; application plane SPECIFIED, awaiting the operator's mint)
**Date:** 2026-08-10
**Decision Makers:** Robert Karsten Zaar (operator ruling, 2026-08-10), with AI implementation
**Related Issues:** nwp/ops#331 (AI hosts hold root SSH keys on the forge), ops#330, ops#214
**References:** [ADR-0004](0004-two-tier-secrets-architecture.md), [ADR-0017](0017-distributed-build-deploy-pipeline.md), [ADR-0024](0024-self-deploying-prod-supersedes-verifier.md), [ADR-0026](0026-nwp-server-capability-agent.md), [ADR-0028](0028-ver-single-operator-human-gated-workstation.md), [ADR-0037](0037-review-mode-follows-approvers.md)

## Context

### The operator ruling this ADR implements

> *"You created the forge box in the first place. In a way I want you to control the whole box so you can save me time. That box does not have ssd/nwd users (also since they've been moved off to another box). The devs who might be on the box is not an issue since that's not part of the ssd/nwd user agreement. What would be good is you creating appropriately named and scoped keys for what you do while still holding the possibility of doing more through root."*
> — operator, 2026-08-10

Two instructions, and they pull in opposite directions on purpose: **grant more** (control the
whole box, keep root available) and **grant it in a more disciplined shape** (named, scoped
keys for what you actually do). This ADR is the shape.

### What is actually on the forge box (measured 2026-08-10, not recalled)

| Fact | Reading |
|---|---|
| `<gitlab-host>` = `<forge-ip>`, Ubuntu 24.04.4, 3.9 GB RAM, 2 cores | small; OOM-killed itself for 5–8 min on 2026-07-25 |
| GitLab 18.7.7-ce.0, apt-held, running under runit (`gitlab-ctl`) | `gitlab-rails`/`gitlab-rake` are the OOM risk |
| Login accounts with uid ≥ 1000: **`gitlab` only** | there is no `ssd`, no `nwd`, no per-dev account — the ruling's premise, confirmed |
| `/etc/sudoers.d/gitlab`: `gitlab ALL=(ALL) NOPASSWD:ALL` | **any unrestricted key in `~gitlab/.ssh/authorized_keys` is root on this box** |
| `sshd -T`: `permitrootlogin no`, `passwordauthentication no`, `/root/.ssh/authorized_keys` absent | root has no direct SSH path; root is reached only via `sudo` from `gitlab` |
| `~gitlab/.ssh/authorized_keys`: 4 entries — 1 unrestricted (`gitlab@<forge-fqdn>` = the dev workstation's `~/.ssh/gitlab_linode`), 3 forced-command (`met-stick-backup-pull`, `nwp-dr-pull@met`, `nwd-demo-reset@met`) | one key holds all the power and its name says nothing about that |
| The demo pair (`ssd`/`nwd`) now lives on the LIVE box `<live-box-ip>`; `/var/www/nwd` is **gone** from the forge, but `/usr/local/bin/nwd-demo-reset-restricted` and its key entry remain | harmless residue (the wrapper fails closed on a missing site) but it is stale — see Consequences |

### The three findings that motivate a scheme rather than another key

1. **One credential, one name, and the name is wrong.** ops#331 established that GitLab user
   `root` (id 1) carries three SSH keys, and that key id 1 — titled *"NWP Backup Key"* — is in
   fact the dev workstation. On the Linux side the same key is the single unrestricted entry in
   `~gitlab/.ssh/authorized_keys`. So the most powerful credential on the box is the one whose
   name most understates it. "Delete the old backup key" was, until ops#331 measured it, the
   single most likely wrong move available.

2. **There is no lesser credential to reach for.** Everything `pl` does against this box today —
   `pl server health`, `pl server forge status`, `pl logs`, `pl server roots` — runs over the
   root-equivalent key, because it is the only key there is. A cron that wants to know how much
   RAM is free authenticates with a credential that could `rm -rf /var/opt/gitlab`. That is not a
   theoretical grade: it is the standing reason the demo wrappers exist, stated in their own
   headers ("Handing a scheduler a plain `gitlab@` key would hand it root. Standing rule: never").

3. **The instrument that should have shown this was stuck on "yes".** `pl secrets capabilities`
   probed admin-ness with `GET /api/v4/users?per_page=1`, an endpoint **any authenticated user may
   call**. Measured on 2026-08-10, all ten rows printed `admin-users: yes`, including four bot
   tokens that answer 404 on every other probe and a token proven non-admin by a 403 elsewhere.
   A column that says yes for everything can never say no — the ops#214 class exactly. This ADR
   fixes the probe (`GET /application/settings`, admin-only) as part of the same change, because
   an identity scheme whose privilege meter is painted on is not an identity scheme.

### The tier rule this ADR must confront honestly

`CLAUDE.md` and [ADR-0004](0004-two-tier-secrets-architecture.md) say:

> **Admin and backup-decryption credentials do not belong in `.secrets.yml`.** It is the tier this
> file tells you that you MAY read. `pl secrets lint` fails with `TIER:` on them; moving one to
> `.secrets.data.yml` is an OPERATOR action (you are deny-ruled from it).

The time-saving half of the operator's ruling — stop routing user/key/membership/CI-variable work
through the operator's browser — **cannot be delivered without an admin credential the AI can
read**. There is no clever framing that avoids this. Either the AI holds a forge-admin credential,
or the click list stays with the operator. Pretending otherwise by hiding the credential in a
third file and declaring the rule satisfied would be tier-laundering, and this repo has a standing
order against exactly that species of green tick.

So this ADR states it plainly: **an AI-readable forge-admin credential is a deliberate amendment,
scoped to one instance, not an oversight and not a loophole.** The rest of this document is the
boundary that makes the amendment safe to grant.

## Options Considered

### Option 1: Status quo — one unrestricted key, operator clicks everything else

- **Pros:** no new credential; nothing to revoke; zero new blast radius.
- **Cons:** the ruling is explicitly a request to *stop* this; every cron still authenticates as
  root-on-box; the operator remains the bottleneck for user/key/membership/CI-variable work; and
  the ambiguity that made "NWP Backup Key" dangerous stays exactly as it is.

### Option 2: More unrestricted keys, one per purpose, all with sudo

- **Pros:** trivially simple; each key is named, so `sshd`'s auth log can attribute an action.
- **Cons:** naming is not scoping. Five root keys are five times the exposure of one, and the
  audit trail improves only until the first key is copied. Rejected: this delivers the *label*
  half of the ruling and none of the *scope* half.

### Option 3: Named + scoped Linux keys, admin PAT in `.secrets.data.yml`

- **Pros:** honours the tier rule as literally written; no admin credential in the AI-readable tier.
- **Cons:** the AI is deny-ruled from `.secrets.data.yml`, so `pl forge users|keys|ci-var` could
  never authenticate. The operator's click list is unchanged. This option satisfies the letter of
  ADR-0004 by delivering none of the ruling's purpose — a correct-looking answer to the wrong
  question.

### Option 4 (chosen): Named + scoped Linux keys, plus a BOUNDED forge-admin tier

Three planes, each with its own credential and its own explicitly-stated limit:

- **Plane 1 (Linux)** — a named full-control key, a jailed read-only key, break-glass out-of-band.
- **Plane 2 (GitLab application)** — one admin PAT, forge-instance only, AI-readable *by decision*,
  with negative probes pinning what it must never reach and a one-file kill switch.
- **Plane 3 (`pl forge`)** — the only sanctioned way to use either, so the guarantees live in a
  verb rather than in a session's memory.

- **Pros:** delivers both halves of the ruling; the powerful credential is used by the *minority* of
  operations while the majority drop to a key that cannot write; the amendment is written down,
  numbered, scoped and revocable rather than being an unrecorded drift.
- **Cons:** an AI-readable admin credential exists, and that is a real widening (see Consequences).
  Three credentials to rotate instead of one.

## Decision

### Plane 1 — the Linux plane on the forge box

Three tiers. Both new keys are `ed25519`, generated **on the machine that will hold the private
half** (no private key ever crosses a wire), and installed by
`servers/nwpcode/forge/install-forge-identities.sh`, which is dry-run by default.

| Identity | Where the secret lives | authorized_keys shape | CAN | CANNOT |
|---|---|---|---|---|
| **`nwp-forge-ops`** | dev workstation `~/.ssh/nwp-forge-ops` (0600) | no forced command | shell as `gitlab`; `sudo` (NOPASSWD) → **full control of the box**, which is what the ruling grants | nothing on the box — this is deliberately unlimited *there*. It reaches no other host: see the negative probes below. |
| **`nwp-forge-probe`** | dev workstation `~/.ssh/nwp-forge-probe` (0600) | `command="/usr/local/bin/forge-probe-restricted"` + `no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding` | twelve READ-ONLY action words: `status health services certs backups forge-version disk keys logs-nginx logs-gitlab logs-auth help` | open a shell · run `sudo` on the caller's behalf · write, restart, install or deploy anything · reach `gitlab-rails`/`gitlab-rake` · choose a path, a filename or a tail count · pass any argument at all |
| **root break-glass** | **no key anywhere** — `permitrootlogin no`, `/root/.ssh/authorized_keys` absent | n/a | reached only by `sudo` from a `gitlab` session (i.e. via `nwp-forge-ops`), or **out of band via the Linode LISH console**, which is operator-only and holds no key on any AI machine | be reached ambiently: there is no route that is root *by default*. Every privileged action is a `sudo` line in `/var/log/auth.log` attributable to the key that opened the session. |

**Why "full control" and "least privilege" are not in tension here.** The ops key is not the
default. It is the credential the *write* verbs use; the probe key is what everything routine uses,
and routine work is the overwhelming majority. The ruling grants the ceiling; the scheme keeps the
floor low.

**`~/.ssh/gitlab_linode` is not touched.** It keeps working through the cutover by design — the
installer's authorized_keys rewrite *refuses and restores from backup* if any pre-existing entry
would change. Retiring it is a separate later step (`pl forge retire-legacy-key`, §Migration).

### Plane 2 — the GitLab application plane (SPECIFIED, NOT MINTED)

The AI holds a bot token and **cannot mint an admin PAT**; this section is the operator's
instruction sheet, and `pl forge` refuses cleanly, by name, until it exists.

**What to mint**

| Field | Value |
|---|---|
| Registry id | `gitlab_forge_admin` |
| Identity | a **dedicated bot user** `nwp-forge-admin`, `is_admin: true` — never the `root` account (id 1) and never `rjzaar` (id 11), so revocation is one user-block and the operator's own audit trail stays clean |
| Scopes | `api`, `sudo` — `sudo` is what makes the admin endpoints usable; `read_registry`/`write_registry` are **not** granted |
| Expiry | 12 months, `cadence_days: 365` |
| Storage | `~/.config/nwp/forge-admin.token` (0600) on the dev workstation — **not** `.secrets.yml`, **not** the repo, **not** any git-tracked path |
| Mint URL | `https://`<gitlab-host>`/admin/users/nwp-forge-admin/impersonation_tokens` |

**Why `~/.config/nwp/forge-admin.token` and not `.secrets.yml`.** Not to dodge the tier rule — the
credential is AI-readable either way and this ADR says so out loud. The reasons are operational:
(a) it keeps `pl secrets lint`'s `TIER:` check meaningful for every *other* credential rather than
carving a hole in it; (b) it is outside the repo, so it cannot be committed by accident; (c) it
gives the operator a **one-file kill switch** — `rm ~/.config/nwp/forge-admin.token` removes the
AI's forge-admin capability instantly, from a machine he is already sitting at, with no GitLab UI
round-trip. The registry entry declares it with the normal `stored_in` grammar so `pl secrets
audit`, `verify-copy` and the rotation ledger all see it.

**What this credential is allowed to do — the whole list**

- Users: read, create, block/unblock, manage **SSH keys** (this is what closes ops#331's own
  remediation without an operator browser session).
- Project and group **membership**.
- **CI/CD variables** and **deploy keys** on `nwp/*` projects.
- Project settings, protected branches, and the instance settings needed for the above.

**What this credential must NEVER reach — enforced as NEGATIVE probes on the registry entry, so
that widening any of them goes red rather than going unnoticed**

| Boundary | Why |
|---|---|
| the **live box** `<live-box-ip>` data tier (site DBs, `moodledata`, `settings.php`) | different host, different credential; forge admin is not host access |
| the **offline deploy host** (`ver`) | offline by default, no Headscale membership, no AI-reachable key — ADR-0017's air gap |
| **`ver`** | the ADR-0028 single-operator gate; a Solo touch is a human, not a token |
| **future prod** (any site whose `pl canonical` phase is `prod`) | the phase-keyed guard, per CLAUDE.md: never key off a site's name |
| the **Linode API** | a DNS/provision token is a different provider entirely; the 2026-07-27 `linode.provision_token` incident is the precedent for why these do not get bundled |
| **the minisign signing key** | see the section below — this is the one that would make forge control reach prod |

### ⚠️ The minisign signing key — LOUD FINDING, verified 2026-08-10

The property that makes it safe to hand an AI control of the forge is ADR-0017's:

> **Trust flows through signatures, not machines.** Artifacts are trusted because they carry a valid
> minisign signature from a known key, not because they came from a "trusted" host.

If that holds, then forge control is *distribution* control, not *deployment* control: a tampered
artifact on the forge is caught by `ver` (the offline deploy host) verifying the signature it does not have. **Where
the secret signing key lives is therefore the single fact that decides whether this ADR is safe.**

**It is NOT on the forge box.** Verified: no minisign key material on `<forge-ip>`; `met` does
not even have minisign installed; the nwp CI pipeline has no signing job and no
`MINISIGN_SECRET_KEY` variable. **So nothing in this ADR moves prod exposure.**

**But it is on an AI-accessible machine already, and that is a pre-existing MUST-FIX:**

- The secret key is `~/nwp/keys/minisign/nwp-deploy.key` on **the dev workstation (`authoring`)** —
  a hardcoded repo-relative path in `lib/minisign.sh`, whose own header calls it
  *"software interim — replace with Solo 2C+ when available"*.
- It is passphrase-protected (scrypt KDF, confirmed) and gitignored (`keys/*`), with exactly one
  copy on disk. Those are real mitigations. They are not an air gap.
- It is **operational, not aspirational**: it signs `contracts/SHA256SUMS.minisig` (the P74
  intersite trust root), `lib/bundle-build.sh` manifests, and the `ver-kit` that is the offline deploy host's first
  trust anchor.
- The successor control is **inert here**: ADR-0028 moves per-deploy authorization to an
  `ed25519-sk` Solo touch, but `keys/allowed_signers` does not exist on this machine, so
  `deploy_gate_require()` takes its "not configured — proceeding without it" branch.
- This is already recorded as **C4, MUST-FIX-BEFORE-OFFLINE-DEPLOY**, in
  `docs/reports/nwp-deep-audit-2026-07-09.md`. Two of its five remediation items are done (encrypted
  at rest; stray copy deleted); "move the canonical key to a non-repo restricted path" and "write a
  rotation/compromise runbook" are **not**.

**Three rules follow, and they bind this ADR:**

1. **The minisign secret key and its passphrase must never be placed on the forge box**, in any CI
   variable, or on the CI hosts (`ci-host`, `ai-host`). The `nwp/nwc-project` pipeline has a designed-but-unactivated
   `sign:minisign` job that would set `MINISIGN_SECRET_KEY` **and** `MINISIGN_PASSWORD` on a
   `met-sign` runner. **Do not register that runner or set those variables.** The forge-admin PAT
   specified above *can* set CI variables — so this is now a rule the credential could break, which
   is precisely why it is written here and probed (see §Revocation).
2. **`gitlab_forge_admin` gets a negative probe asserting no CI variable named `MINISIGN_*` exists
   on any `nwp/*` project.** A capability nobody checks is folklore.
3. **C4 stays open and is not discharged by this ADR.** Forge control does not reach prod *today*
   because the signing key is elsewhere; but "elsewhere" is the same laptop that runs Claude. Until
   the key moves to hardware or to a non-AI host, "trust flows through signatures, not machines"
   reads, as implemented, as *"trust flows through a passphrase-encrypted file on the machine an AI
   agent has a shell on."* That gap is older and larger than this ADR, and this ADR neither widens
   nor fixes it — it just refuses to be built on a claim that is not true.

### Plane 3 — `pl forge`

The pl-first standing order applies: the guarantees live in the verb, not in a session's shell.

```
pl forge doctor [--live]                    which identities exist, which work, which are absent
pl forge health | status                    box headroom (probe key)
pl forge services | certs | backups | disk  read-only box state (probe key)
pl forge logs --source=nginx|gitlab|auth    read-only, clamped, fixed source set (probe key)
pl forge version                            gitlab-ce version, apt hold, signing-key expiry
pl forge whoami                             which credential is in play; IS IT ADMIN (discriminating probe)
pl forge users list|show <u>                admin API, read
pl forge keys list [<user>] | add | delete  SSH-key management — the ops#331 remediation itself
pl forge members list|add <project> <user>  project/group membership
pl forge ci-var list|set <project>          CI/CD variables
pl forge deploy-key list|add <project>      deploy keys
pl forge run <word>                         raw probe action word, allowlisted client-side too
pl forge retire-legacy-key                  the gitlab_linode cutover, typed confirm (§Migration)
```

Invariants, each of which already has a precedent in this tree:

- **Read-only by default; every write is dry-run-by-default with a typed confirm.**
- **The token never appears in `argv`** — the 0600-curl-config pattern from `cmd_whose`.
- **Fail closed:** cannot measure ⇒ **exit 2 CANNOT VERIFY**, never exit 0, never a substituted
  literal.
- **Absent credential is a named refusal**, not a crash and not a silent skip: it names the registry
  id, the file it looked in, and the `pl secrets steps` command that explains the mint.
- **`pl forge` never runs `gitlab-rails`/`gitlab-rake`.** Application administration goes through
  the REST API, which runs in the already-resident puma, not a fresh 500 MB Rails process on a
  3.9 GB box.
- **SSH key isolation is mandatory** (see Consequences — this bit nearly produced a fake green).

## Rationale

**Why the ruling is safe to grant at all.** Three independent reasons, and the ADR depends on all
three, so each is stated as a checkable fact rather than a reassurance:

1. **The forge holds no member data.** It is code + artifact distribution (ADR-0017's transport
   row: *"trusted as transport, not as authority"*). Site databases and `moodledata` are on other
   boxes.
2. **No `ssd`/`nwd` unix users exist on it** — measured above. The ruling's premise is that the
   user agreement covering the demo pair does not reach this box, and the box's own passwd file
   agrees.
3. **The AI already had root here.** `gitlab_linode` + NOPASSWD sudo has been exactly that since
   before ops#331. This ADR does not grant new Linux power; **it names and subdivides power that
   was already granted ambiguously.** The *new* grant is the application-plane PAT alone.

**Why a jail with a full-control sibling is not theatre.** The objection writes itself: if the AI
holds `nwp-forge-ops`, what does the probe key protect against? Three things, all real: (a) the
probe key is what goes on schedulers, crons and other hosts, where a stolen credential is a
different event from a stolen workstation; (b) it makes the *default* path unable to destroy
anything, so a wrong command is refused rather than executed; (c) it makes the audit trail
meaningful — `logs-auth` and `pl forge keys` can now say *which* identity did a thing, which the
single-key state made impossible by construction.

**Why one PAT and not five scoped ones.** GitLab's PAT model has no per-endpoint scoping below
`api`; five tokens would be five copies of the same power with more rotation surface. The scoping
that is actually available is *identity* scoping — a dedicated bot user that can be blocked in one
click — and that is what is specified.

## Consequences

### Positive

- The ruling is delivered in both halves: the ceiling is granted, the floor is lowered.
- ops#331's own remediation (rehome three root SSH keys) becomes AI-runnable via `pl forge keys`,
  instead of waiting on an operator browser session.
- Every routine `pl` interaction with the forge drops from root-equivalent to a key that cannot
  write.
- `pl secrets capabilities` gains a privilege column that can say **no** — proven red against a
  known non-admin token.
- Three credentials that previously had no registry entry now have entries, `stored_in` locations,
  and probes — including negative ones.

### Negative — stated plainly

- **An AI-readable instance-admin credential will exist.** That is a real widening of the AI's
  application-plane reach on the forge, granted deliberately under this ADR and revocable by
  deleting one file.
- **The probe wrapper runs as `gitlab`, which has NOPASSWD sudo.** The containment is that the key
  can only *invoke* the program and cannot choose what it does — **not** that the program is
  unprivileged. A dedicated unix account with a narrow sudoers rule would remove the residue; it is
  recorded as follow-up rather than done, and readers should not mistake "restricted key" for
  "unprivileged process". This is the same honest gap the demo wrappers record.
- **`nwp-forge-ops` has no passphrase**, because it drives automation. It is root-on-forge in one
  file on the dev workstation — the same posture `gitlab_linode` already had, not a new one, but it
  is not improved by this ADR either.
- **Three credentials now need rotating** where one did before.
- **Stale residue found and left alone:** `/usr/local/bin/nwd-demo-reset-restricted` and its
  `nwd-demo-reset@met` key entry survive on the forge although `/var/www/nwd` moved to the live box.
  The wrapper fails closed on the missing site, so it is inert, but an inert forced command nobody
  has re-read is exactly the thing this ADR is about. Removing it is deliberately **not** bundled
  here (it belongs with the demo-pair move, not with an identity scheme) — filed as follow-up.

### The trap that nearly produced a fake green — recorded because it will recur

`~/.ssh/config` supplies `IdentityFile ~/.ssh/gitlab_linode` for this host, and **`IdentitiesOnly=yes`
does not exclude config-supplied identity files** — it only excludes *extra* agent keys. So

```
ssh -o IdentitiesOnly=yes -i ~/.ssh/nwp-forge-probe gitlab@<forge-ip> 'id'
  → uid=1000(gitlab) … groups=27(sudo)
```

succeeded **before the probe key was installed anywhere**, because sshd accepted `gitlab_linode`
instead. A jail test written that way would have reported a shell where the jail works, and a pass
where the key does not exist. Every probe-key invocation must therefore use full isolation:

```
ssh -F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -i <key> …
```

With that, both new keys correctly returned `Permission denied (publickey)` pre-install while
`gitlab_linode` still authenticated — a real red. **`pl forge` builds every probe-key invocation
this way, and `_probe_scopes` in `pl secrets` is fixed the same way**, since it had the identical
`-o IdentitiesOnly=yes -i` shape and would have reported `expect_rc: 0` for an ssh key that was
never installed.

## Revocation and rotation

| Credential | Revoke | Rotate | Cadence |
|---|---|---|---|
| `nwp-forge-ops` | remove the `nwp-forge-ops@authoring` line from `~gitlab/.ssh/authorized_keys` (`pl forge keys` or the installer) | regenerate the pair, re-run the installer, delete the old line | 365 d |
| `nwp-forge-probe` | same, for `nwp-forge-probe@authoring` | same | 365 d |
| `gitlab_forge_admin` | **two independent ways:** `rm ~/.config/nwp/forge-admin.token` (instant, local, no GitLab access needed) **or** block/delete the `nwp-forge-admin` user in the GitLab admin area (instant, revokes every copy anywhere) | `pl secrets rotate gitlab_forge_admin` | 365 d |

**Compromise drill.** If the dev workstation is believed compromised: block `nwp-forge-admin`;
remove both `nwp-forge-*` lines from `authorized_keys` over LISH; and treat the **minisign secret
key as compromised too**, because it is on the same machine — which is C4's whole point, and the
reason the drill is written here rather than assumed.

**Scope drift detection.** Every entry carries a `probe:`, and the negative probes are the load-bearing
ones: `nwp-forge-probe` must return the wrapper's refusal (not a shell) for an arbitrary command, and
`gitlab_forge_admin` must find no `MINISIGN_*` CI variable on any `nwp/*` project. A limit that is
never checked is not a limit.

## Migration

1. **Now (this MR):** both Linux keys generated and installed; `gitlab_linode` untouched and
   working; wrapper + installer versioned under `servers/nwpcode/system/`; registry entries with
   probes; `pl forge` read-only surface live; admin verbs present and refusing by name.
2. **Operator:** mint `nwp-forge-admin` + PAT per Plane 2 and drop the value into
   `~/.config/nwp/forge-admin.token` (0600). Nothing else. This retires the pending clicks listed
   in the MR description.
3. **Then (AI, via `pl forge keys`):** execute ops#331's rehoming — workstation key → `rjzaar`,
   met → a dedicated `met` service user, the `ai-host` → its own user — and delete them from `root` only after each new home
   is confirmed.
4. **Then:** `pl forge retire-legacy-key` — swap `pl`'s server config from `~/.ssh/gitlab_linode`
   to `~/.ssh/nwp-forge-ops`, verify, and only then remove the legacy line. **Typed confirm; it is
   the one step that can lock the estate out of the box, so it verifies the replacement works
   before it removes anything.**
5. **Follow-ups, not bundled:** dedicated unprivileged unix account + narrow sudoers for the probe
   wrapper; removal of the stale `nwd-demo-reset` residue; and **C4 — move the minisign secret key
   off the AI-accessible workstation**, which remains MUST-FIX-BEFORE-OFFLINE-DEPLOY and is not this ADR's to
   close.

## Review Notes

- **Sensitive paths touched:** `scripts/commands/secrets.sh` (privilege probe + ssh isolation),
  `servers/nwpcode/system/*` (new forced command). Both are deliberate and central to the change.
- **This ADR grants the AI a new capability.** Under [ADR-0037](0037-review-mode-follows-approvers.md)
  the estate is in `solo` mode: the operator's merge click is the approval, and the AI holds a bot
  token and cannot merge. That is the intended gate for a change of this kind.
