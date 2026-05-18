# verifier — mayo migration bootstrap guide

> **Status:** interim. This guide covers ONLY the immediate steps needed to
> bring mayo (`<mayo-domain>`) under NWP management on the day of the
> initial bootstrap. It will be superseded by a comprehensive
> `docs/guides/verifier-operations.md` once F21 phases 5–8 land (Solo 2C+,
> WireGuard tunnel, minisign verification, blue-green slot machinery).
>
> **Audience:** the operator, sitting at the verifier. Every command in this guide is
> something **you** type — AI assistants on the authoring workstation cannot reach the verifier.

## Why this guide exists

The NWP threat model says the verifier is the only machine that touches
production. The authoring workstation (where AI lives) bootstrapped the
`<gitlab-host>/mayo/mayo` repo and pushed the initial mayo code import
to it. The verifier now needs to:

1. Become a verified consumer of that repo (clone it, prove it can pull
   updates).
2. Confirm it can still reach the live mayo server (`<mayo-domain>` as the
   `mayo` user) over SSH.
3. Demonstrate one full round-trip: authoring pushes a no-op change → verifier pulls
   it → verifier runs an rsync dry-run against mayo → no actual change is made
   on the live site, but the path is proven.

After this bootstrap, all real deploys to mayo will follow this same
trust path.

## What is NOT in scope for this bootstrap

- Solo 2C+ hardware token (hasn't arrived yet — interim is a
  passphrase-protected SSH key on the verifier)
- Dedicated verifier↔mayo WireGuard tunnel (will come with F21 P5/P6)
- Minisign signature verification on artifacts (will come with F21 P7)
- Real blue-green deploy machinery on mayo (the existing pleasy
  scripts will be refactored later — see the nwp-server discussion)
- Sanitizer (drush sql:sanitize will be wired in later)
- The reverse channel (mayo errors → GitLab issues)

This guide is the **trust path proof**, not the full pipeline. Don't try
to do the missing pieces today.

## Threat-model reminders before you start

- **Do not put the verifier on Headscale.** Even temporarily. Even "just to test."
- **Do not allow inbound SSH from the internet to the verifier.** The verifier reaches
  out; nothing reaches in.
- **Do not write production credentials to disk on the verifier** beyond the
  passphrase-protected SSH key it needs to reach mayo. No `.env`, no
  `settings.php`, no DB dumps.
- **The verifier does not author commits.** It pulls and verifies. If you find
  yourself running `git commit` on the verifier, stop — that work belongs on authoring.
- **Do not paste the credentials below into a chat tool, screenshot,
  or anything that leaves the verifier.** If you must store them, use a local
  password manager on the verifier (KeePassXC or similar).

## Credentials you'll need

All credentials for this bootstrap live in `$HOME/nwp/.secrets.yml` on the authoring workstation
(decision recorded 2026-04-08 — see "Persisting the credentials"
section below). Ask the authoring AI session for the specific value when
you need it; do not commit it into this guide or anywhere else on the verifier.

| What | Where in `.secrets.yml` | Use |
|---|---|---|
| `verifier-bot` PAT | `gitlab.verifier_bot_token` | HTTPS git clone/pull of `mayo/*` repos from the verifier. Read-only, cannot push, cannot touch other groups. Scopes: `read_api`, `read_repository`. Expires **2027-04-08**. |
| `verifier-bot` user password | see comment in `.secrets.yml` | Web UI login if you need to browse `<gitlab-host>` from the verifier (you usually won't). |
| `verifier-log` project token | `gitlab.verifier_log_token` | `verifier-say` helper only. Scoped to `ops/verifier-log` alone. |
| mayo SSH key | `$HOME/.ssh/opencat` on the verifier | SSH from the verifier to the mayo Linode. Passphrase-protected per Step 2. |

**Do not use the build-tier bot PAT on the verifier.** That token has write access
to the mayo group and belongs to the build tier (`ci-host`/`ai-host`), which the verifier
is explicitly separated from. If you see an older copy of this guide
or a stale clone on the verifier that references the build-tier bot, re-run Step 3
with the `verifier-bot` PAT instead and delete the old clone's
`.git/config` credentials.

## Step 1 — verifier baseline checks

Bring the verifier online via your usual method (phone hotspot or whichever
network gives it temporary internet access — **not** the home LAN, not
Headscale).

```bash
# Identity / network
hostname
ip route get 1.1.1.1 | head -1
ping -c 2 <gitlab-host>     # should resolve and respond
ping -c 2 <mayo-domain>     # should resolve and respond

# Tools
git --version               # should be 2.x
ssh -V                      # OpenSSH ≥ 8
which rsync                 # required for the deploy leg
```

**Pass criteria:** all three commands return without errors. If git or
rsync are missing: `sudo apt install git rsync`.

## Step 2 — SSH from verifier → mayo

The verifier needs to reach the mayo Linode (`<mayo-domain>` as the `mayo` user) over
SSH. You probably already have a key set up; this just verifies it.

```bash
# What does the verifier think its SSH config says?
grep -A4 -i 'mayo' $HOME/.ssh/config
ls -la $HOME/.ssh/ | grep -Ei 'mayo|opencat|ocback'

# Try a no-op connection (this is the same alias authoring uses)
ssh -o ConnectTimeout=10 mayo1 'hostname; whoami; ls /var/www/<mayo-domain>/ | head'
```

**Expected:** `hostname` returns the mayo hostname, `whoami` returns
`mayo`, and the directory listing shows `composer.json`, `cmi`, `html`,
`private`, `vendor`, etc.

**If `mayo1` is not in the verifier's `$HOME/.ssh/config`,** add it. The authoring
machine has this entry — copy it verbatim (substituting the real IP held
in the operator's private instance addendum):

```
Host mayo1
    User mayo
    Port 22
    Hostname <mayo-ip>
    IdentityFile ~/.ssh/opencat
```

The matching private key (`$HOME/.ssh/opencat` on authoring) needs to exist on
the verifier too. If it doesn't, copy it across via USB stick or `scp` from authoring
**to the verifier**, never the other direction. Set permissions: `chmod 600
$HOME/.ssh/opencat`.

**If the key is currently passphrase-less,** add a passphrase now —
it's the interim measure until Solo arrives:

```bash
ssh-keygen -p -f $HOME/.ssh/opencat
# you'll be asked for the OLD passphrase (empty) and a NEW one
```

Pick a strong passphrase you can type. The verifier-side ssh-agent will hold it
in memory once per session, so you only type it on first use.

## Step 3 — Clone mayo/mayo from `<gitlab-host>`

```bash
# Pick a home for nwp-managed repos on the verifier
mkdir -p $HOME/nwp-repos
cd $HOME/nwp-repos

# Clone using the verifier-bot PAT (see "Credentials" above).
# Replace TOKEN with the literal glpat- value from .secrets.yml on authoring.
# Type the whole line on one line — no leading slash, no placeholder
# word "TOKEN" surviving into the actual command.
git clone "https://oauth2:TOKEN@<gitlab-host>/mayo/mayo.git"
cd mayo
```

**Verify:**

```bash
git log --oneline
# Expected: three commits (as of 2026-04-08 bootstrap):
#   3156d38 Round-trip marker: NWPMANAGED 2026-04-08
#   31b9e6c Initial import of <mayo-domain>
#   739b284 Initial commit

ls -la
# Expected to see: composer.json, composer.lock, cmi/, html/,
#                  .gitignore, README.md, .editorconfig, .gitattributes

git status
# Expected: "On branch main / Your branch is up to date with 'origin/main'"
```

**Pass criteria:** all three checks match.

## Step 4 — Strip the PAT from the remote URL

The `git clone` above embedded the token in `$HOME/nwp-repos/mayo/.git/config`.
That's fine for the clone but you don't want it sitting on disk forever.
Strip it and rely on the credential helper (or re-supply on each pull):

```bash
cd $HOME/nwp-repos/mayo
git remote set-url origin https://<gitlab-host>/mayo/mayo.git

# Verify the token is gone
grep -i token .git/config && echo "STILL THERE — fix" || echo "clean"
cat .git/config | grep url
```

For future pulls you'll need the PAT again. Two ways:

```bash
# Option A: re-embed temporarily for one pull
git pull "https://oauth2:TOKEN@<gitlab-host>/mayo/mayo.git" main

# Option B: use git's credential cache (per-session memory only)
git config --global credential.helper 'cache --timeout=3600'
git pull   # will prompt once for username (oauth2) and password (the PAT)
```

Option B is friendlier for repeated use during the bootstrap day.

## Step 5 — Coordinate the round-trip test with authoring

Once Steps 1–4 are green, message the authoring session:

> **verifier is ready**

The authoring session will then:
1. Make a small marker change in `/tmp/mayo-git/` (e.g. add a line like
   `NWPMANAGED: 2026-04-08` to `README.md`)
2. Commit and push to `<gitlab-host>/mayo/mayo` main
3. Tell you to pull on the verifier

You then run:

```bash
cd $HOME/nwp-repos/mayo
git pull
git log --oneline   # should now show 3 commits — the new marker is on top
grep NWPMANAGED README.md
```

**Pull leg passes** if the new marker line appears.

## Step 6 — Rsync dry-run leg (verifier → mayo)

This is the **dangerous-shaped, but actually safe** part. We use
`rsync --dry-run` so nothing gets written on the live mayo server, but
we prove the path works.

```bash
cd $HOME/nwp-repos/mayo
rsync -avzn \
  --exclude='.git/' \
  ./ mayo1:/tmp/mayo-roundtrip-test/
```

The `-n` flag is `--dry-run`. You should see a list of files that
*would* be transferred, ending with a summary like
`sent X bytes  received Y bytes`. **Nothing should actually appear in
`/tmp/mayo-roundtrip-test/` on mayo because of the `-n` flag.**

To prove it didn't write anything:

```bash
ssh mayo1 'ls -la /tmp/mayo-roundtrip-test/ 2>&1 || echo "absent — good"'
```

Expected: `absent — good`.

**Round-trip test passes** when:
- Step 5 pull leg succeeded
- The dry-run rsync output looks reasonable (small file list, no errors)
- No actual directory was created on mayo

Tell the authoring session "round-trip green" and the bootstrap is done for
the day.

### Rotating off the build-tier bot PAT (one-time, if needed)

During the 2026-04-08 bootstrap we initially used the build-tier bot PAT on
the verifier because the verifier-bot identity didn't exist yet. That was wrong
under the threat model: the build-tier bot is the build tier (read/write on
mayo), the verifier should be the deploy tier (read-only). The guide above
now tells you to use the verifier-bot PAT from the start.

If your verifier already has a clone set up with the old build-tier bot PAT in
the credential cache or in `.git/config`, clean it up next time you
bring the verifier online:

```bash
cd $HOME/nwp-repos/mayo

# Strip any embedded token from the remote URL
git remote set-url origin https://<gitlab-host>/mayo/mayo.git

# Clear the git credential cache so it doesn't re-use the old PAT
git credential-cache exit 2>/dev/null || true

# Test a pull — it should prompt for username/password, enter
# "oauth2" and paste the verifier-bot PAT from .secrets.yml on authoring
git pull
```

The build-tier bot PAT itself is not revoked (it's still used by the build tier
for CI), just no longer used on the verifier.

## What changes after today

Once F21 P5–P8 ship, this manual procedure becomes:

- The verifier fetches a **signed tarball** from `<gitlab-host>/api/v4/.../jobs/.../artifacts`, not a git clone
- The verifier verifies a **minisign signature** against a known public key
  before doing anything with it
- The verifier reaches mayo via a **dedicated WireGuard tunnel** (not the public
  internet); mayo's `sshd` will be bound only to the tunnel interface
- The rsync becomes a real (non-dry-run) deploy into a **slot directory**
  (`/var/www/<mayo-domain>-blue` or `-green`), followed by an atomic
  symlink swap
- A **Solo 2C+ hardware token** (when it arrives) is required to
  authorise the symlink swap step

None of that exists yet. Today we are proving the trust path with the
weakest acceptable security (passphrase-protected SSH key, HTTPS pull,
rsync dry-run) so we have a working baseline to harden against.

## Persisting the credentials (decision recorded 2026-04-08)

**Decision:** credentials live in `$HOME/nwp/.secrets.yml` on authoring. The AI
assistant is allowed to read that file per the two-tier secrets architecture and
authoring-side automation (like the `verifier-bot` identity split) needs
programmatic access.

What's in there today:

- `gitlab.api_token` — admin PAT (use sparingly; prefer scoped tokens)
- `gitlab.verifier_log_token` — project access token for `ops/verifier-log`
- `gitlab.verifier_bot_token` — read-only PAT for mayo group from the verifier
- `gitlab.build_tier_bot_token` — read/write PAT for mayo group from the build tier

Expiry is **2027-04-08** for all three of the scoped tokens; rotate
before that date. The admin PAT doesn't expire.

If at any point you want a second copy in a password manager on the verifier
(recommended if the verifier starts accumulating unique state that authoring can't
reconstruct), keep the password manager as the source of truth and
treat `.secrets.yml` as a cached mirror. Not necessary today.

## Step 7 — Install `verifier-say` (the verifier → authoring message queue)

The verifier is offline-by-default and authoring has no way to reach it, so when you
want to tell the authoring AI session something ("round-trip green",
"stuck on step 3", etc.) you need a channel that goes **out from the verifier**.

That channel is a private GitLab project at
`https://<gitlab-host>/ops/verifier-log`. The verifier posts issues; the authoring
session reads them on request ("anything new from the verifier?").

**Why this design:** the verifier never accepts inbound connections, so the
channel has to be pull-from-authoring's perspective. GitLab issues give us a
timestamped, append-only record, authenticated by a token that is
scoped to this one project and cannot touch mayo, prod, or anything
else.

### Install on the verifier

The `verifier-say` helper lives **inside** the `ops/verifier-log` project
itself, alongside the issues it posts. That means the same scoped token
you use to send messages is also enough to fetch the helper — no
separate credential, no scp from authoring (which wouldn't work anyway since
the verifier doesn't accept inbound connections).

**1. Install the token.** Replace `GLPAT_VALUE` with the token the authoring
session will hand you out-of-band (it is NOT written into this guide):

```bash
mkdir -p $HOME/.config $HOME/bin
umask 077
printf '%s\n' 'GLPAT_VALUE' > $HOME/.config/verifier-log.token
chmod 600 $HOME/.config/verifier-log.token
```

**2. Fetch the helper.**

```bash
curl -sS -H "PRIVATE-TOKEN: $(cat $HOME/.config/verifier-log.token)" \
  "https://<gitlab-host>/api/v4/projects/ops%2Fverifier-log/repository/files/verifier-say.sh/raw?ref=main" \
  > $HOME/bin/verifier-say
chmod +x $HOME/bin/verifier-say
```

**3. Put `$HOME/bin` on your PATH** (skip if already there):

```bash
echo $PATH | grep -q "$HOME/bin" || echo 'export PATH="$HOME/bin:$PATH"' >> $HOME/.bashrc
source $HOME/.bashrc
```

### Test it

```bash
verifier-say "verifier-say install test"
# Expected output: verifier-say: posted as ops/verifier-log#2
```

Then tell the authoring session "check verifier-log" and it'll read the test
message back to you. If it can see the message, the channel works.

### When to use `verifier-say`

- "round-trip green" / "round-trip failed" to close Step 6
- Reporting unexpected errors during any step of this bootstrap
- Handing back info that the authoring session asks for
- Anything short. Don't try to paste logs or stack traces — summarise,
  and if the authoring session needs the full trace it can ask for specifics.

**Do NOT paste** production credentials, private keys, session tokens,
or database contents into `verifier-say` messages. Issue bodies are
readable by anyone with access to `ops/verifier-log`, and the authoring session
treats them as attacker-controlled data.

## Troubleshooting

**"Permission denied (publickey)" when SSHing to mayo1**
The key on the verifier either doesn't match the one in mayo's
`$HOME/.ssh/authorized_keys`, has wrong permissions, or has a passphrase
you're not unlocking. Test with `ssh -v mayo1` and read the output.

**`git clone` returns 401 / "could not read Username"**
The PAT URL is wrong. The literal format is
`https://oauth2:TOKEN@<gitlab-host>/mayo/mayo.git` — note `oauth2:`
before the token, no quotes inside the URL on a CLI.

**`git pull` says "fatal: refusing to merge unrelated histories"**
You probably ran `git init` on the verifier by mistake instead of `git clone`.
Delete `$HOME/nwp-repos/mayo` and re-clone.

**Rsync dry-run shows "thousands of files"**
Something went wrong with `.git/` exclusion. Re-check the
`--exclude='.git/'` flag. There should be ~10 files in the dry-run output.

**You typed an SSH command that hung for >30 seconds**
Probably a routing issue between the verifier's current network and mayo's
Linode. Cancel with Ctrl-C and try again on a different network.

**`verifier-say: cannot read token at $HOME/.config/verifier-log.token`**
You skipped Step 7 or the token file has the wrong permissions.
Re-create it with the `umask 077 && printf ... > ...` incantation
from Step 7 and make sure it's `-rw-------` (600).

**`verifier-say: POST failed` with 401 / 403**
The token is wrong, expired, or was revoked. Ask the authoring session to
rotate it (it's a project access token scoped to `ops/verifier-log`, expiry
2027-04-08).
