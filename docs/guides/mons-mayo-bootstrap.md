# mons — mayo migration bootstrap guide

> **Status:** interim. This guide covers ONLY the immediate steps needed to
> bring mayo (mayostudios.org) under NWP management on the day of the
> initial bootstrap. It will be superseded by a comprehensive
> `docs/guides/mons-operations.md` once F21 phases 5–8 land (Solo 2C+,
> WireGuard tunnel, minisign verification, blue-green slot machinery).
>
> **Audience:** Rob, sitting at mons. Every command in this guide is
> something **you** type — Claude on dev cannot reach mons.

## Why this guide exists

The NWP threat model says mons is the only machine that touches
production. Dev (where Claude lives) bootstrapped the
`git.nwpcode.org/mayo/mayo` repo and pushed the initial mayo code import
to it. Mons now needs to:

1. Become a verified consumer of that repo (clone it, prove it can pull
   updates).
2. Confirm it can still reach the live mayo server (`mayo1` /
   `mayostudios.org`) over SSH.
3. Demonstrate one full round-trip: dev pushes a no-op change → mons pulls
   it → mons runs an rsync dry-run against mayo → no actual change is made
   on the live site, but the path is proven.

After this bootstrap, all real deploys to mayo will follow this same
trust path.

## What is NOT in scope for this bootstrap

- ❌ Solo 2C+ hardware token (hasn't arrived yet — interim is a
  passphrase-protected SSH key on mons)
- ❌ Dedicated mons↔mayo WireGuard tunnel (will come with F21 P5/P6)
- ❌ Minisign signature verification on artifacts (will come with F21 P7)
- ❌ Real blue-green deploy machinery on mayo (the existing pleasy
  scripts will be refactored later — see the nwp-server discussion)
- ❌ Sanitizer (drush sql:sanitize will be wired in later)
- ❌ The reverse channel (mayo errors → GitLab issues)

This guide is the **trust path proof**, not the full pipeline. Don't try
to do the missing pieces today.

## Threat-model reminders before you start

- ✋ **Do not put mons on Headscale.** Even temporarily. Even "just to test."
- ✋ **Do not allow inbound SSH from the internet to mons.** Mons reaches
  out; nothing reaches in.
- ✋ **Do not write production credentials to disk on mons** beyond the
  passphrase-protected SSH key it needs to reach mayo. No `.env`, no
  `settings.php`, no DB dumps.
- ✋ **Mons does not author commits.** It pulls and verifies. If you find
  yourself running `git commit` on mons, stop — that work belongs on dev.
- ✋ **Do not paste the credentials below into a chat tool, screenshot,
  or anything that leaves mons.** If you must store them, use a local
  password manager on mons (KeePassXC or similar).

## Credentials you'll need

Two secrets, currently only living in this conversation's scrollback on
dev. Copy them somewhere durable BEFORE you start, because they will be
overwritten by the next time Claude rotates them:

| What | Value | Use |
|---|---|---|
| `mini` user login on git.nwpcode.org | (ask dev session, see "Credentials persistence" item) | Web UI login as the mini-bot |
| Mini-bot Personal Access Token | (ask dev session, see "Credentials persistence" item) | HTTPS git auth from mons |

The PAT scopes are `api`, `read_repository`, `write_repository`, and it
expires **2027-04-08**.

> The dev session intentionally did not write these to a file before
> handing off to you. Decide where they live (`.secrets.yml` on dev or a
> password manager) before continuing — see "Persisting the credentials"
> at the bottom.

## Step 1 — Mons baseline checks

Bring mons online via your usual method (phone hotspot or whichever
network gives it temporary internet access — **not** the home LAN, not
Headscale).

```bash
# Identity / network
hostname
ip route get 1.1.1.1 | head -1
ping -c 2 git.nwpcode.org   # should resolve and respond
ping -c 2 mayostudios.org   # should resolve and respond

# Tools
git --version               # should be 2.x
ssh -V                      # OpenSSH ≥ 8
which rsync                 # required for the deploy leg
```

✅ **Pass criteria:** all three commands return without errors. If git or
rsync are missing: `sudo apt install git rsync`.

## Step 2 — SSH from mons → mayo

Mons needs to reach `mayo1` (mayostudios.org as the `mayo` user) over
SSH. You probably already have a key set up; this just verifies it.

```bash
# What does mons think its SSH config says?
grep -A4 -i 'mayo' ~/.ssh/config
ls -la ~/.ssh/ | grep -Ei 'mayo|opencat|ocback'

# Try a no-op connection (this is the same alias dev uses)
ssh -o ConnectTimeout=10 mayo1 'hostname; whoami; ls /var/www/mayostudios.org/ | head'
```

**Expected:** `hostname` returns `mayostudios.org`, `whoami` returns
`mayo`, and the directory listing shows `composer.json`, `cmi`, `html`,
`private`, `vendor`, etc.

❌ **If `mayo1` is not in mons's `~/.ssh/config`,** add it. The dev
machine has this entry — copy it verbatim:

```
Host mayo1
    User mayo
    Port 22
    Hostname 172.105.183.226
    IdentityFile ~/.ssh/opencat
```

The matching private key (`~/.ssh/opencat` on dev) needs to exist on
mons too. If it doesn't, copy it across via USB stick or `scp` from dev
**to mons**, never the other direction. Set permissions: `chmod 600
~/.ssh/opencat`.

❌ **If the key is currently passphrase-less,** add a passphrase now —
it's the interim measure until Solo arrives:

```bash
ssh-keygen -p -f ~/.ssh/opencat
# you'll be asked for the OLD passphrase (empty) and a NEW one
```

Pick a strong passphrase you can type. Mons-side ssh-agent will hold it
in memory once per session, so you only type it on first use.

## Step 3 — Clone mayo/mayo from git.nwpcode.org

```bash
# Pick a home for nwp-managed repos on mons
mkdir -p ~/nwp-repos
cd ~/nwp-repos

# Clone using the mini-bot PAT (see "Credentials" above)
# Replace TOKEN with the actual glpat- value
git clone "https://oauth2:TOKEN@git.nwpcode.org/mayo/mayo.git"
cd mayo
```

**Verify:**

```bash
git log --oneline
# Expected: two commits
#   31b9e6c Initial import of mayostudios.org
#   739b284 Initial commit

ls -la
# Expected to see: composer.json, composer.lock, cmi/, html/,
#                  .gitignore, README.md, .editorconfig, .gitattributes

git status
# Expected: "On branch main / Your branch is up to date with 'origin/main'"
```

✅ **Pass criteria:** all three checks match.

## Step 4 — Strip the PAT from the remote URL

The `git clone` above embedded the token in `~/nwp-repos/mayo/.git/config`.
That's fine for the clone but you don't want it sitting on disk forever.
Strip it and rely on the credential helper (or re-supply on each pull):

```bash
cd ~/nwp-repos/mayo
git remote set-url origin https://git.nwpcode.org/mayo/mayo.git

# Verify the token is gone
grep -i token .git/config && echo "STILL THERE — fix" || echo "clean"
cat .git/config | grep url
```

For future pulls you'll need the PAT again. Two ways:

```bash
# Option A: re-embed temporarily for one pull
git pull "https://oauth2:TOKEN@git.nwpcode.org/mayo/mayo.git" main

# Option B: use git's credential cache (per-session memory only)
git config --global credential.helper 'cache --timeout=3600'
git pull   # will prompt once for username (oauth2) and password (the PAT)
```

Option B is friendlier for repeated use during the bootstrap day.

## Step 5 — Coordinate the round-trip test with dev

Once Steps 1–4 are green, message the dev session:

> **mons is ready**

The dev session will then:
1. Make a small marker change in `/tmp/mayo-git/` (e.g. add a line like
   `NWPMANAGED: 2026-04-08` to `README.md`)
2. Commit and push to `git.nwpcode.org/mayo/mayo` main
3. Tell you to pull on mons

You then run:

```bash
cd ~/nwp-repos/mayo
git pull
git log --oneline   # should now show 3 commits — the new marker is on top
grep NWPMANAGED README.md
```

✅ **Pull leg passes** if the new marker line appears.

## Step 6 — Rsync dry-run leg (mons → mayo)

This is the **dangerous-shaped, but actually safe** part. We use
`rsync --dry-run` so nothing gets written on the live mayo server, but
we prove the path works.

```bash
cd ~/nwp-repos/mayo
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

✅ **Round-trip test passes** when:
- Step 5 pull leg succeeded
- The dry-run rsync output looks reasonable (small file list, no errors)
- No actual directory was created on mayo

Tell the dev session "round-trip green" and the bootstrap is done for
the day.

## What changes after today

Once F21 P5–P8 ship, this manual procedure becomes:

- Mons fetches a **signed tarball** from `git.nwpcode.org/api/v4/.../jobs/.../artifacts`, not a git clone
- Mons verifies a **minisign signature** against a known public key
  before doing anything with it
- Mons reaches mayo via a **dedicated WireGuard tunnel** (not the public
  internet); mayo's `sshd` will be bound only to the tunnel interface
- The rsync becomes a real (non-dry-run) deploy into a **slot directory**
  (`/var/www/mayostudios.org-blue` or `-green`), followed by an atomic
  symlink swap
- A **Solo 2C+ hardware token** (when it arrives) is required to
  authorise the symlink swap step

None of that exists yet. Today we are proving the trust path with the
weakest acceptable security (passphrase-protected SSH key, HTTPS pull,
rsync dry-run) so we have a working baseline to harden against.

## Persisting the credentials before you finish

Before mons goes back into its offline-by-default state, decide where
the mini login password and PAT live long-term. Three options:

1. **`~/nwp/.secrets.yml` on dev** — Claude is allowed to read this file
   per the NWP two-tier secrets architecture. Add a `mayo:` block to it.
   Pros: easy for dev-side automation. Cons: another secret on a
   network-attached machine.
2. **A local password manager on mons** (KeePassXC, pass, etc.) — most
   in line with the threat model. Cons: dev-side automation can't pull
   the PAT later (you'd retype it).
3. **Both** — store in the password manager as the source of truth, and
   also in `.secrets.yml` for the convenience of automation. Rotate the
   PAT before its 2027-04-08 expiry.

The dev session is waiting for your decision on this; tell it which
option you picked and it'll either update `.secrets.yml` or stay out of
the way.

## Troubleshooting

**"Permission denied (publickey)" when SSHing to mayo1**
The key on mons either doesn't match the one in mayo's
`~/.ssh/authorized_keys`, has wrong permissions, or has a passphrase
you're not unlocking. Test with `ssh -v mayo1` and read the output.

**`git clone` returns 401 / "could not read Username"**
The PAT URL is wrong. The literal format is
`https://oauth2:TOKEN@git.nwpcode.org/mayo/mayo.git` — note `oauth2:`
before the token, no quotes inside the URL on a CLI.

**`git pull` says "fatal: refusing to merge unrelated histories"**
You probably ran `git init` on mons by mistake instead of `git clone`.
Delete `~/nwp-repos/mayo` and re-clone.

**Rsync dry-run shows "thousands of files"**
Something went wrong with `.git/` exclusion. Re-check the
`--exclude='.git/'` flag. There should be ~10 files in the dry-run output.

**You typed an SSH command that hung for >30 seconds**
Probably a routing issue between mons's current network and mayo's
Linode. Cancel with Ctrl-C and try again on a different network.
