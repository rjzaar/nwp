## F24: Mirror NWP Tree on met and Establish Branch-CI Workflow

**Status:** PROPOSED (Phase 1 complete 2026-04-11)
**Created:** 2026-04-11
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** Medium-High (immediate trigger: laptop disk-full crash; architectural alignment with ADR-0017)
**Depends On:** F21 Phase 1 (Headscale mesh) ✅, F21 Phase 2 (met GitLab Runner) ✅
**Breaking Changes:** No (workflow is additive — laptop keeps full dev capability)
**Estimated Effort:** Phased; Phase 1 done, Phase 2 ~half-day, Phase 3 ~day

---

## 1. Executive Summary

### 1.1 Problem statement

On 2026-04-11 the dev laptop (i7-1165G7, 15 GiB RAM, 186 GB root) froze
and had to be hard power-cycled. Post-mortem of `journalctl -b -1`:

- `/` was **completely full** at 15:51:46 (rsyslog spammed hundreds of
  "No space left on device" errors, Brave's IndexedDB corrupted itself
  on a failed flush).
- From 15:54:38, `systemd-journald` and `systemd-resolved` started
  flushing caches under memory pressure every few seconds.
- At 15:56:31 the log abruptly ends — no graceful shutdown, no OOM
  kill logged. The system thrashed itself into unresponsiveness.

Disk breakdown at the time of the crash:

| Category | Size |
|---|---|
| Docker images + volumes + build cache | ~30 GB |
| `~/nwp/sites/` (DDEV project trees) | ~17 GB |
| `~/.local/share/pipx/venvs/openai-whisper` | 7.0 GB |
| `~/nwp/sites/*/backups/` (DB backups) | ~2.5 GB |
| `~/nwp/sites/verify-test*/` (stale fixture orphans) | ~10 GB |
| `~/.cache` | 3.5 GB |

The laptop is permanently under-provisioned for the combined load of
DDEV/Docker, local Whisper, ad-hoc verify-test orphans, and an
interactive workload (Brave + Codium + Claude Code). Meanwhile, **met**
(Ryzen 9 3900X, 32 GiB RAM, 915 GB root, ~60 % used) sits on the same
home LAN at `met.nwp.headscale` and is already designated by ADR-0017
as the primary build/test runner.

### 1.2 Proposed solution

F24 makes met a **full mirror of the NWP tree** — not a replacement
for the laptop, and not a thin-client target. Both machines retain a
complete `~/nwp` working tree including all sites, all DDEV configs,
and all per-site backups. The two trees stay coherent through
**git.nwpcode.org as the single canonical remote**.

The workflow this enables:

1. **Edit on the laptop** as today. Editor, browser, and Claude Code
   all stay local. Nothing about the day-to-day editing experience
   changes.
2. **Commit signed → push to a feature branch** on `git.nwpcode.org`.
   Direct pushes to `main` are forbidden by branch protection.
3. **CI runs on the met GitLab Runner** (already shipped in F21
   Phase 2) and executes the **full** `pl verify --run --depth=thorough`
   suite plus DDEV smoke tests against the branch.
4. **Merge to main is gated** by the CI result. Only branches with a
   green thorough-verify pipeline can be merged.
5. **met auto-pulls main** on a short interval. After every merge, met
   converges to the new HEAD without operator action. The laptop also
   pulls main (manually, as today) — both mirrors stay current.

The relief for the laptop comes from three orthogonal changes, not
from relocation:

- Heavy *one-shot* compute (Whisper transcription, ad-hoc ffmpeg work)
  runs on met via thin SSH wrappers (`whisper-remote` ships in Phase 1).
- Stale fixture and cache directories are cleaned up routinely; the
  habit is enforced by a `pl cleanup` style command.
- The expensive `pl verify --depth=thorough` run no longer happens on
  the laptop at all — branch-CI on met is the new home for it.

Docker and DDEV remain installed on **both** machines. The laptop runs
the sites it actually uses day-to-day; met runs everything for the
verify suite and acts as the integration target.

### 1.3 Relationship to ADR-0017 and F21

ADR-0017 § Actor roster names met as "always-on home compute, primary
build/test runner". F21 Phase 2 already shipped the GitLab Runner on
met that exercises this role for `pl verify --depth=basic`. F24 does
two things on top of that:

1. **Promotes the runner from `--depth=basic` to `--depth=thorough`**
   so that branches genuinely earn the right to merge.
2. **Establishes mirror semantics** so the laptop and met tree are
   permanently coherent through git, not divergent through ad-hoc
   rsync.

ADR-0017 also mentions "(often via Remote SSH to met)" as one possible
laptop pattern. F24 **does not require Remote SSH**. Remote SSH stays
available for jobs that genuinely benefit from it (large builds, mass
test runs, things the laptop's 15 GiB RAM can't host), but it is not
the default workflow.

Earlier drafts of F24 proposed making met the "canonical dev tree" and
turning the laptop into a thin client. That direction has been
**explicitly rejected** by the user — see § 12 Decision Record. Both
machines remain full development workstations.

---

## 2. Goals & Non-Goals

### Goals

- Laptop disk usage stops being a realistic failure mode under normal
  workload (Brave + Codium + Claude + Docker for active sites).
- Both `~/nwp` trees are full mirrors — no "which copy is newest?"
  question, because the answer is always "whatever main is on
  git.nwpcode.org".
- met is **always on main** within seconds-to-minutes of any merge,
  via an auto-pull mechanism (systemd timer or cron).
- All branch work is gated by full `pl verify --depth=thorough` on
  met before it can land in main. Direct push to main is blocked.
- Heavy one-shot compute (Whisper, etc.) runs on met via thin
  wrappers, not on the laptop.
- The laptop retains full DDEV / Docker / `pl` capability for
  day-to-day work; nothing about the local edit-test loop is taken
  away.
- No new AI-touches-prod paths. Branch CI is dev-side only; the
  mons → prod boundary is unchanged.

### Non-Goals

- **Making the laptop a thin client.** The laptop remains a full
  development workstation. Docker, DDEV, and `pl` continue to run
  locally for the sites the user actively works on.
- **Single-tree-on-met model.** Earlier drafts of F24 proposed this;
  it has been rejected. Both machines mirror the full tree.
- **Replacing git.nwpcode.org as canonical remote.** It stays
  canonical. F24 makes met *track* canonical, not *become* it.
- **Pushing branches directly between laptop and met.** All sync is
  through git.nwpcode.org. There is no laptop ↔ met git transport.
- **Two-way file sync (unison/mutagen).** We are not introducing a
  sync daemon. git is the sync mechanism.
- **Moving mini's voice-agent Whisper stack.** Mini's Whisper is a
  separate concern (X02). F24 only touches the laptop's pipx-installed
  Whisper that exists for ad-hoc transcription.
- **Touching the mons → prod path.** Out of scope; the boundary is
  inviolable.
- **Removing the existing `deploy:staging` / `deploy:production` CI
  stages.** Those stages contradict ADR-0017's mons-mediated model
  but cleaning them up belongs to a separate proposal — see § 9.
- **Multi-developer access to met.** met is single-user (Rob) under
  this proposal.

---

## 3. Current State

### 3.1 Machines in play

| Machine | CPU | RAM | Root disk | Role today | Role after F24 |
|---|---|---|---|---|---|
| `carlo` (laptop) | i7-1165G7 (4c/8t) | 15 GiB | 186 GB / now 47 GB free | Full dev workstation; sometimes overloaded | Full dev workstation; offloads heavy one-shot compute and full verify to met |
| `Carlo` (met) | Ryzen 9 3900X (12c/24t) | 32 GiB | 915 GB / 60 % used | F21 Phase 2 GitLab Runner (basic verify) | F21 runner + always-on-main mirror + branch CI runner for `--depth=thorough` |

The hostname collision (`carlo` lowercase vs `Carlo` capitalised) is
unrelated to this proposal but will bite someone eventually. Tracked
in § 9 Open Questions.

### 3.2 What's on the laptop after Phase 1

```
/home/rob/nwp                                        18 GB
  sites/avc                                           3.5 GB
  sites/avc/backups                                   1.9 GB    (mirrored on met)
  sites/ss                                            2.2 GB
  sites/{ba,cathnet,dir1,mt,mayo,cccrdf,opensocial2} ~7 GB
  sites/mayo/backups                                  12 MB     (mirrored on met)
/var/lib/docker                                     ~26 GB
/home/rob/.cache                                    ~3 GB
```

Phase 1 reclaimed ~21 GB on the laptop (free space went from 19 GB
to 47 GB) by deleting:

- 4 old `.deb` installers (~843 MB)
- 17 stale `verify-test*` orphan directories (~10 GB)
- the local `openai-whisper` pipx venv (7 GB) — replaced by
  `~/.local/bin/whisper-remote`
- Docker image and builder caches (~3.5 GB)

The laptop tree and the met tree are now **identical mirrors** for
all `sites/*/backups/` content (verified by rsync round-trip on
2026-04-11).

### 3.3 What met looks like today

- F21 Phase 2 runner installed and serving the `nwp,met` tags.
- `~/nwp` clone exists but is **behind canonical main**: met is at
  `da39764f`, laptop is at `7df7e24a` (3 commits ahead). No auto-pull
  is installed yet.
- `git remote -v` for met's `~/nwp` clone currently points at
  `https://github.com/rjzaar/nwp.git`, **not** `git.nwpcode.org`.
  This is a discrepancy with the user's stated direction and must be
  fixed in Phase 2 before the auto-pull mechanism is enabled.
- met also has no SSH key registered for `git.nwpcode.org`
  (`ssh -T git@git.nwpcode.org` returns `Permission denied
  (publickey)`), so the remote retargeting in Phase 2 requires a
  new key to be generated on met and added as a deploy key on the
  `nwp/nwp` project first.
- met has a **local `ollama` branch** at `2b1b4b1b` containing F10
  LLM-related commits and historical release tags (`v0.29.0`,
  `v0.28.0`) that are not visible on `main` from the laptop. Needs
  triage in Phase 2 before `origin` is repointed — the work may
  have been rebased/cherry-picked to main under different SHAs, or
  it may be orphaned and need pushing to git.nwpcode.org before
  the remote swap.
- Docker Engine **is** running on met (systemd `docker.service`
  active, socket at `/var/run/docker.sock`). An earlier investigation
  pass misdiagnosed Docker as "broken" — in fact the only problem
  was that `~/.docker/config.json` had leftover Docker Desktop
  state (`"credsStore": "desktop"`, `"currentContext":
  "desktop-linux"`) pointing DDEV at a non-existent socket at
  `/home/rob/.docker/desktop/docker.sock`. Running
  `docker context use default` once was sufficient to restore
  DDEV; `ddev version` now returns clean (DDEV v1.24.10, docker
  29.3.0, compose v2.40.3). This was executed during F24
  investigation on 2026-04-11 and is already fixed.
- F21 Phase 2's GitLab Runner is already sharing this daemon
  successfully; the coexistence check in the earlier draft is
  therefore low-priority rather than a blocker.
- Whisper installed via pipx, accessible from the laptop through
  `whisper-remote` (Phase 1 deliverable).

### 3.4 What the CI pipeline does today

`.gitlab-ci.yml` already has:

- Branch-push triggers (`$CI_PIPELINE_SOURCE == "push"`) and merge
  request triggers.
- A `test:verification` stage that runs
  `./scripts/commands/verify.sh ci --depth=basic --export-json`,
  but **only on `main` and merge requests** — not on arbitrary
  feature branches.
- `tags: [nwp, met]` targeting the F21 runner.
- `deploy:preview` / `cleanup:preview` stub stages for MR previews.
- `deploy:staging` / `deploy:production` / `stop:staging` stages
  (`.gitlab-ci.yml:535–643`) that ssh-keyscan `$STAGING_HOST` /
  `$PRODUCTION_HOST`, decode a base64 SSH key from CI variables
  (`$STAGING_SSH_KEY` / `$PRODUCTION_SSH_KEY`), rsync the entire
  working tree into `${STAGING_PATH}` / `${PRODUCTION_PATH}`, then
  ssh into the host and run `ddev drush deploy`. These stages are
  gated only by `when: manual`, but if ever clicked, they put the
  CI runner (met, an AI-accessible machine per ADR-0017) in
  possession of an SSH key to prod and writing arbitrary files
  into the production path. **This is precisely the trust
  inversion ADR-0017 exists to prevent.** They also assume a
  pre-F17/F23 site layout (rsync `./` → a single target path,
  no per-site structure, no sanitizer, no mons). They are leftover
  stubs from before mons was introduced, and F24 removes them — see
  § 6 Phase 3 step 1.

The gap F24 closes: the runner only proves `--depth=basic` against
`main` and MRs. Feature branches don't get the full
`--depth=thorough` treatment, and there is no merge gate that
*requires* a green thorough run. F24 also closes the standing
trust-inversion exposure by deleting the legacy staging/production
deploy stages before touching the thorough-verify additions.

---

## 4. Options Considered

### 4.1 Option A — Mirror tree, branch-CI workflow (recommended)

Both machines hold full `~/nwp` trees. git.nwpcode.org is canonical.
met auto-pulls main. Dev pushes feature branches; CI runs full
`--depth=thorough` verify on the met runner; branches that pass can
be merged; met converges on main automatically.

**Pros:**
- Zero workflow change for the editor experience. The laptop keeps
  doing what it does today.
- Heavy verify load moves off the laptop **automatically** —
  developers don't need to remember to run it on met, because they
  push a branch and CI handles it.
- Mirror semantics are guaranteed by git rather than by ad-hoc rsync.
  No drift, no two-source-of-truth problems.
- Naturally extends to multi-machine in the future (e.g. mini could
  also become an always-on-main mirror) without re-architecting.
- Matches ADR-0017's spirit: met is the build/test runner, the
  laptop is the developer workstation, and trust flows through git
  and signatures rather than through "which machine has the freshest
  copy".
- Reversible at every step. Disabling auto-pull on met or blocking
  the new CI stage is a one-line change.

**Cons:**
- Requires actually wiring branch protection on git.nwpcode.org,
  which the user has not yet done.
- Met's Docker daemon needs to be fixed before branch CI can run
  DDEV-touching jobs.
- Met's git remote needs to be retargeted from GitHub to
  git.nwpcode.org before auto-pull is meaningful.
- The full `--depth=thorough` verify is slower than `--depth=basic`,
  so feedback latency on a push is longer (minutes, not seconds).
  Mitigation: keep the basic verify as a fast-fail stage that runs
  first.

### 4.2 Option B — Single canonical tree on met, laptop as thin client

Earlier draft of F24. Move `~/nwp` to met permanently; laptop edits
via Codium Remote SSH; uninstall Docker on the laptop.

**Rejected** because the user has explicitly stated both machines
should retain full mirrors and the laptop should remain a full
development workstation. See § 12 Decision Record. Pros and cons
are preserved in git history of this file (commit prior to the
2026-04-11 rewrite) for context.

### 4.3 Option C — Hybrid: Docker-only relocation via `DOCKER_HOST=ssh://met`

Keep `~/nwp` on the laptop, but point DDEV at met's Docker daemon
over SSH.

**Rejected** because:

- DDEV-over-remote-Docker is a known sharp-edge configuration. Bind
  mounts from laptop into containers on met require an overlay
  (NFS, SSHFS, Mutagen) to perform adequately, and DDEV's
  bind-mount assumptions break in subtle ways.
- It doesn't actually deliver the Phase 3 win (branch CI on met),
  which is the load-bearing improvement F24 makes.
- The ddev-router has to live somewhere. Either it runs on met and
  the laptop tunnels 80/443 (introduces port-conflict pain) or it
  runs on the laptop and routes to containers on met (adds a second
  network hop per request). Neither is great.

### 4.4 Option D — Two-way file sync (unison / mutagen)

Use a sync daemon to keep `~/nwp` coherent between laptop and met
without going through git.

**Rejected** because:

- Sync conflicts during concurrent edits are a real operational
  burden.
- It introduces a parallel source-of-truth alongside git.
- `.git` directory state diverges under sync — the usual answer is
  to exclude `.git`, which means git commands only work on one side,
  which defeats the point.
- git itself is the sync mechanism we already have. Using something
  else is reinventing the wheel.

### 4.5 Option E — Do nothing (bigger SSD)

Add an external NVMe to the laptop and keep the current workflow.

**Rejected** because RAM is the tighter constraint than disk; a
bigger disk doesn't help with the memory-pressure half of the crash.
And it doesn't deliver the branch-CI win at all.

---

## 5. Recommendation

Take **Option A** in four phases. Phase 1 is already done (2026-04-11)
and bought ~28 GB of laptop free space without any architectural
change. The remaining phases are sequential and each is independently
useful.

**Phase 2** (mirror infrastructure on met) should start once the
operator (Rob) has confirmed the rewritten F24 direction matches his
mental model — see § 12.

**Phase 3** (branch-CI workflow) follows once Phase 2 is stable and
met is reliably converging on main.

**Phase 4** (optional remote-compute wrappers beyond `whisper-remote`)
is open-ended cleanup that can land any time after Phase 1.

---

## 6. Phases

### Phase 1 — Leaf cleanup and `whisper-remote` (DONE 2026-04-11)

| Step | Result |
|---|---|
| Delete 4 old `.deb` installers | ~843 MB freed |
| Delete 17 stale `verify-test*` orphan directories on the laptop | ~10 GB freed |
| Uninstall `~/.local/share/pipx/venvs/openai-whisper` on the laptop | 7 GB freed |
| Install `openai-whisper` via pipx on met | + ~7 GB on met (well within headroom) |
| Install `~/.local/bin/whisper-remote` wrapper on the laptop | scp + ssh + scp pattern, hardcoded full path to met's whisper |
| `docker image prune -a -f` on the laptop | 2.5 GB freed |
| `docker builder prune -a -f` on the laptop | 966 MB freed |
| `docker volume prune -f` on the laptop | 0 B (volumes pinned by paused DDEV containers — left alone) |
| Verify `sites/avc/backups/` and `sites/mayo/backups/` are mirrored on both machines | ✅ verified by rsync round-trip 2026-04-11 |

Phase 1 totals: laptop free space went from **19 GB to 47 GB**
(+28 GB). No workflow change required. No code change required.
Reversible by re-running `pipx install openai-whisper` and re-pulling
images on demand (DDEV does this automatically when projects start).

### Phase 2 — Mirror infrastructure on met

**Step 0 — Docker context cleanup (already done 2026-04-11).**
Running `docker context use default` on met was sufficient to
restore DDEV. `ddev version` returns clean. Optional follow-up:
edit `~/.docker/config.json` on met to remove `"credsStore":
"desktop"` and `"currentContext": "desktop-linux"`, which are
Docker Desktop leftovers that cause cosmetic warnings. No package
install or systemd work is required — Docker Engine was already
running the whole time.

**Step 1 — Generate a dedicated SSH key on met for
git.nwpcode.org.** met currently has 15+ SSH keys in `~/.ssh/`
but none registered with `git.nwpcode.org`. Create a new
identity scoped to this purpose:

```bash
ssh met.nwp.headscale "ssh-keygen -t ed25519 \
  -f ~/.ssh/gitnwpcode -C 'met@git.nwpcode.org' -N ''"
ssh met.nwp.headscale "cat ~/.ssh/gitnwpcode.pub"
```

Add the public key to the `nwp/nwp` GitLab project as a
**read-only deploy key** (not a user account key) — the tighter
scope for an always-on-main mirror that never pushes.

**Step 2 — Wire the key into met's SSH config.** Append to
`~/.ssh/config` on met:

```
Host git.nwpcode.org
    IdentityFile ~/.ssh/gitnwpcode
    IdentitiesOnly yes
```

Verify: `ssh met.nwp.headscale "ssh -T git@git.nwpcode.org"`
should return GitLab's welcome banner rather than
`Permission denied (publickey)`.

**Step 3 — Triage the local `ollama` branch on met.** met has
a local `ollama` branch at `2b1b4b1b` with F10-related commits
and historical releases that aren't visible on main from the
laptop. Compare the ranges before touching `origin`:

```bash
ssh met.nwp.headscale "cd ~/nwp && git log --oneline main..ollama"
```

If all commits in that range already exist on canonical main
(under the same or rebased SHAs), the branch is safely
discardable. If any are orphaned, push the branch to
git.nwpcode.org as `archive/met-ollama-2026-04-11` before the
remote swap so the work isn't lost to a stale remote.

**Step 4 — Retarget `origin` and fast-forward main.**

```bash
ssh met.nwp.headscale "cd ~/nwp && \
  git remote set-url origin git@git.nwpcode.org:nwp/nwp.git && \
  git fetch origin && \
  git checkout main && \
  git merge --ff-only origin/main && \
  git remote prune origin"
```

Fast-forward-only is intentional: if met's main has somehow
diverged from canonical main, the merge fails loudly rather than
guessing. Run only after Step 3 confirms no orphaned work.

**Step 5 — Install the auto-pull systemd timer.** Create
`/etc/systemd/system/nwp-auto-pull-main.service`:

```ini
[Unit]
Description=NWP: keep ~/nwp on origin/main
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=rob
ExecStart=/usr/bin/git -C /home/rob/nwp fetch --quiet origin main
ExecStart=/usr/bin/git -C /home/rob/nwp merge --ff-only origin/main
```

And `/etc/systemd/system/nwp-auto-pull-main.timer`:

```ini
[Unit]
Description=NWP: periodic main converge

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
Unit=nwp-auto-pull-main.service

[Install]
WantedBy=timers.target
```

Enable and start: `sudo systemctl enable --now
nwp-auto-pull-main.timer`. Fast-forward-only means dirty working
trees, rebased branches, or out-of-band manual pulls all cause
the service to fail loudly into the journal instead of silently
overwriting state. Expected "working tree dirty" style failures
are the signal to switch to a feature branch on met.

**Step 6 — Coexistence check with F21 runner.** Now a
low-priority sanity check rather than a blocker, because the
runner and DDEV already share `/var/run/docker.sock` cleanly.
Verify by starting a DDEV project on met while the runner is
idle and watching `docker ps` for unexpected contention. If the
two ever fight (e.g. a verify run on the runner starts while a
DDEV project on met holds the ddev-router ports), give the
runner its own Docker context or namespace the DDEV port range.

**Step 7 — Mirror per-site backup repos.** Each
`sites/<name>/backups/` is its own per-site git repo (F18
pattern). Default for Phase 2: keep them local-only on both
machines and mirror through a nightly rsync in a direction that
never deletes on the receiving side (`rsync -a --ignore-existing`
or a two-pass pull-then-push with `--update`). Promoting them to
GitLab projects with LFS is a separate decision tracked in § 9.

**Step 8 — Document the always-on-main contract.** Add a short
subsection to
`docs/decisions/0017-distributed-build-deploy-pipeline.md`
naming met as the always-on-main mirror, pointing at the
systemd unit files, and stating the fast-forward-only guarantee.

**Phase 2 deliverables:**

- met has a dedicated `git.nwpcode.org` deploy key (read-only
  scope).
- met's `origin` is `git@git.nwpcode.org:nwp/nwp.git`, not
  GitHub; local main is a fast-forward of canonical main.
- Any orphaned `ollama`-branch work is pushed to
  `archive/met-ollama-2026-04-11` (or confirmed redundant).
- `nwp-auto-pull-main.timer` is installed and healthy in
  `systemctl list-timers`.
- Per-site backup repos have a documented rsync policy.
- ADR-0017 names the always-on-main contract.

### Phase 3 — Branch-CI workflow

**Step 1 — Delete the legacy `deploy:staging` / `deploy:production`
/ `stop:staging` stages from `.gitlab-ci.yml` as a small standalone
commit.** These stages (`.gitlab-ci.yml:535–643`) and the
accompanying "CI/CD Variables Required" documentation at
~lines 655–690 must go before any Phase 3 work touches the same
file. They are not "legacy but harmless": the moment someone
clicks the manual trigger, they grant met (an AI-accessible CI
runner) an SSH key to prod and a direct rsync path into
`${PRODUCTION_PATH}`, which is exactly the trust inversion
ADR-0017 exists to prevent.

Three approaches were considered:

- **A (chosen): delete outright.** One focused commit that
  removes the `deploy:staging`, `stop:staging`, and
  `deploy:production` jobs and the matching variable docs. Keeps
  the diff small and reviewable; rollback is a `git revert`.
- **B: neuter in place.** Replace each script body with
  `exit 1 "mons-mediated per ADR-0017"`. Rejected because it
  leaves misleading job names in the pipeline UI that someone
  will eventually try to debug.
- **C: defer to a successor proposal.** Leave for whichever
  later proposal implements the ADR-0017-compliant
  build-artifact → mons handoff and replaces the stages in the
  same change. Rejected because the current state has standing
  blast radius and shouldn't persist longer than necessary.

After the deletion commit lands, **rotate or remove any
`STAGING_SSH_KEY`, `PRODUCTION_SSH_KEY`, `STAGING_HOST`,
`STAGING_USER`, `STAGING_PATH`, `PRODUCTION_SSH_KEY`,
`PRODUCTION_HOST`, `PRODUCTION_USER`, `PRODUCTION_PATH`, and
any matching `$*_DB_PASSWORD` / `$*_API_KEY` variables from the
git.nwpcode.org project CI/CD settings.** Stale credentials in
CI variable storage are a liability even when no job references
them. This cleanup happens in the GitLab UI, not in code.

Replacing the deleted stages with a proper ADR-0017-compliant
build-artifact-handoff is **not** in F24's scope — it belongs
to a successor proposal slotted into F21's remaining phases.

**Step 2 — Expand `.gitlab-ci.yml` verify stage.** The current
`test:verification` job runs `verify.sh ci --depth=basic`. Add
a second verify job (parallel or sequential) that runs
`verify.sh ci --depth=thorough --export-json` and is required
for branch merges to main. Keep `--depth=basic` as the fast-fail
gate so obvious breakage fails in seconds.

**Step 3 — Add branch-push triggers for the thorough job.** Today
`test:verification` only runs on main and MRs. Add the thorough
job for any branch matching a feature pattern (e.g. `feat/*`,
`fix/*`, anything that isn't main or a tag).

**Step 4 — Configure branch protection on git.nwpcode.org.** In
the GitLab project settings:

- Protect `main`. Disallow direct push.
- Require merge requests for changes to main.
- Require the `test:verification:thorough` pipeline status to be
  green before the merge button is enabled.
- Require the verify-signature job (already in CI) to be green.

**Step 5 — Document the new dev workflow** in
`docs/guides/branch-ci-workflow.md`:

- "Edit on the laptop. Commit signed. Push a branch. Watch the
  pipeline at git.nwpcode.org. When it goes green, open an MR
  and merge. met converges on main within ~1 min."
- Include the rare-case escape hatches (force-push to a personal
  branch is fine; force-push to main is blocked by protection).

**Step 6 — Verify the merge gate end-to-end** with a deliberately
trivial no-op branch.

**Phase 3 deliverables:**

- The legacy `deploy:staging` / `deploy:production` / `stop:staging`
  stages no longer exist in `.gitlab-ci.yml`. Their associated CI
  variables no longer exist in git.nwpcode.org project settings.
- Branches that don't pass `--depth=thorough` cannot be merged
  into main.
- met converges on main within ~1 min of every merge.
- The dev workflow is documented and tested end-to-end.

### Phase 4 — Optional: more remote-compute wrappers

Whenever a heavy one-shot tool surfaces a need (ffmpeg encoding,
Drupal `composer install` against a fat repo, large rsync of
production fixtures), add a thin SSH wrapper to `~/.local/bin/`
that runs the tool on met instead. `whisper-remote` is the
template.

This is open-ended. No commitment to a specific list.

---

## 7. Affected NWP Components

### 7.1 New paths

| Path | Purpose |
|---|---|
| `~/.local/bin/whisper-remote` (laptop, not in git) | Phase 1 — wrapper that runs Whisper on met via ssh |
| `/etc/systemd/system/nwp-auto-pull-main.{service,timer}` (met, not in git) | Phase 2 — keeps met's `~/nwp` converged on origin/main |
| `docs/guides/branch-ci-workflow.md` | Phase 3 — operator runbook for the branch → CI → merge workflow |
| `docs/guides/met-as-mirror.md` | Phase 2 — operator runbook: retargeting the git remote, fixing Docker, installing the auto-pull timer |

### 7.2 Modified paths

| Path | Change |
|---|---|
| `.gitlab-ci.yml` (first commit) | Phase 3 Step 1 — delete `deploy:staging`, `stop:staging`, `deploy:production` jobs and their variable documentation blocks (lines 535–643 and ~655–690 in the current file) |
| `.gitlab-ci.yml` (second commit) | Phase 3 Steps 2–3 — add `test:verification:thorough` job, expand branch-push triggers, mark thorough verify as required for merge to main |
| git.nwpcode.org `nwp/nwp` CI/CD variables | Phase 3 Step 1 — remove `STAGING_SSH_KEY`, `PRODUCTION_SSH_KEY`, `STAGING_HOST`, `STAGING_USER`, `STAGING_PATH`, `PRODUCTION_HOST`, `PRODUCTION_USER`, `PRODUCTION_PATH` (in GitLab UI, not in code) |
| git.nwpcode.org `nwp/nwp` deploy keys | Phase 2 Step 1 — add new read-only deploy key `met@git.nwpcode.org` (public key generated on met) |
| met: `~/.docker/config.json` | Phase 2 Step 0 — optional cosmetic cleanup, remove `credsStore` and `currentContext` Docker Desktop leftovers |
| met: `~/.ssh/config` | Phase 2 Step 2 — add `Host git.nwpcode.org` block pinning `IdentityFile` to `~/.ssh/gitnwpcode` |
| met: `~/nwp/.git/config` | Phase 2 Step 4 — `origin` URL changes from GitHub to git.nwpcode.org |
| `docs/decisions/0017-distributed-build-deploy-pipeline.md` | Phase 2 Step 8 — add an "always-on-main mirror" subsection naming met and pointing at the auto-pull timer |
| `CLAUDE.md` | Phase 3 — add a one-paragraph "Branch CI Workflow" note under Project Structure (no Threat Model changes) |
| `docs/governance/roadmap.md` | Move F24 PROPOSED → IN PROGRESS → COMPLETE as phases land |

### 7.3 Not modified

- **`lib/`** — no shared library code needs to change. Both machines
  run the same `pl` against the same shape of tree.
- **`pl`** — runs unchanged on both machines.
- **`recipes/`** — recipes are machine-agnostic.
- **`sites/*/`** — site config is filesystem-layout data, identical
  on both machines.
- **`servers/*/`** — per-server config is about the prod/service
  side, not the dev-host side.
- **Anything under `mons`, prod, sanitizer, or the mmt → prod signing
  path** — completely out of scope.

### 7.4 Data that must not move during this migration

Per CLAUDE.md § Two-Tier Secrets Architecture and ADR-0004:

- **`.secrets.data.yml`** must not be transmitted to met by F24.
  Phase 2's git remote work runs over `git fetch`, which only ever
  pulls what is in the canonical remote — no untracked secret files
  can sneak across that path. Any auxiliary rsync used in Phase 2 or
  later **must** include an explicit `--exclude='.secrets.data.yml'`
  and `--exclude='keys/prod_*'`.
- **`keys/prod_*`** must not move to met. Same reasoning. Both
  trees verified clean as of 2026-04-11 (only `.gitkeep` in `keys/`
  on each).
- **Sanitizer scripts** are security-critical per CLAUDE.md and
  must not be modified by F24 even incidentally.

---

## 8. Risk Assessment

### High risk

| Risk | Mitigation |
|---|---|
| **The auto-pull timer races with an in-progress edit on met** (e.g. an interactive `pl` invocation, a `ddev` start, a verify run). | Auto-pull is `merge --ff-only` only. If the working tree is dirty or local main has diverged, the merge fails loudly and a journal entry is logged. The timer never force-resets. Rule of thumb: use feature branches for any in-place experimentation on met. |
| **Branch CI thorough verify takes long enough that developers stop pushing branches** and route around the merge gate. | Phase 3 keeps the basic verify job as a fast-fail first stage. Thorough verify runs in parallel where possible. Keep the merge gate strict regardless: a slow gate is still better than no gate. If it becomes painful, optimise verify, don't bypass the gate. |
| **A `.secrets.data.yml` or `keys/prod_*` file accidentally enters the tree on the laptop and gets pushed to git.nwpcode.org via a feature branch.** | `.gitignore` already excludes both. CI's `verify-signature` and lint stages run on every push. Add a pre-receive hook on git.nwpcode.org (out of scope for F24 itself, but flagged in § 9) that rejects pushes containing `.secrets.data.yml` regardless of `.gitignore`. |
| **met's git remote is currently pointing at GitHub, not git.nwpcode.org**, and met has no SSH key registered for git.nwpcode.org, so the "always on main" claim is currently false in a confusing way. Also, met carries a local `ollama` branch with historical commits whose relationship to canonical main is unverified. | Phase 2 Steps 1–4 fix this explicitly (generate key, wire SSH config, triage ollama branch, retarget origin). Until Step 4 succeeds, do not install the auto-pull timer. |
| **The `deploy:staging` / `deploy:production` / `stop:staging` CI stages grant met an SSH key to prod if manually triggered.** This is a standing trust-inversion violation of ADR-0017, not just a model mismatch. | Phase 3 Step 1 deletes the stages as a small standalone commit before any other `.gitlab-ci.yml` work. The matching CI variables (`STAGING_SSH_KEY`, `PRODUCTION_SSH_KEY`, etc.) are removed from git.nwpcode.org project settings in the same step. |

### Medium risk

| Risk | Mitigation |
|---|---|
| F21 Phase 2 GitLab Runner and Phase 2 DDEV projects both use Docker; they may contend. | Lower priority than originally assessed — the runner and DDEV already share `/var/run/docker.sock` cleanly as of 2026-04-11. Phase 2 Step 6 still sanity-checks coexistence under load; if they fight, the runner gets its own Docker context or DDEV uses a non-default port range. |
| Per-site backup repos under `sites/<name>/backups/` are local-only. If both mirrors drift (one has a backup the other doesn't), the rsync direction matters. | Phase 2 Step 7 makes the sync policy explicit. Default: rsync from laptop to met daily; never delete on the receiving side without confirmation. |
| Triaging the `ollama` branch on met requires judgment. Commits may have been rebased onto main under different SHAs, or they may be genuinely orphaned. Getting it wrong means either losing work or preserving stale cruft as an archive branch forever. | Phase 2 Step 3 is a review gate, not a script. The operator (Rob) makes the call after reading `git log --oneline main..ollama`. Default-safe: if in doubt, push as `archive/met-ollama-2026-04-11` before the remote swap. The archive branch costs nothing to keep. |
| Removing the legacy staging/production deploy stages leaves CI with no "deploy" path at all until a successor proposal lands. | Acceptable — the stages never worked in the F17/F23 site layout anyway, and manual SSH deploys remain available out-of-band. The replacement belongs to the ADR-0017-compliant build-artifact handoff proposal. |

### Low risk

| Risk | Mitigation |
|---|---|
| met's 915 GB disk fills up. | Currently 60 % used. Adding a full DDEV stack and verify fixtures is well under another 100 GB. Plenty of headroom. |
| Hostname collision (`carlo` lowercase vs `Carlo`) confuses scripts. | Always use `met.nwp.headscale` explicitly in runbooks and CI. Never rely on short hostnames. |
| Codium Remote SSH (still available, just not the default) breaks under some extension. | Not exercised by F24's default workflow. Falls back to local edit. |

---

## 9. Open Questions

- **Per-site backup repos and git.nwpcode.org.** Should each
  `sites/<name>/backups/` repo become a real GitLab project under
  `nwp/site-backups/<name>` with LFS for the dump files, or stay as
  local-only repos that are mirrored through rsync? The local-only
  path is simpler but means one machine could drift from the other
  if rsync fails silently. F18 originally assumed local-only; F24
  Phase 2 defaults to that and flags the question for revisit.
- **Pre-receive hook on git.nwpcode.org for accidental secret
  pushes.** Out of scope for F24 itself but worth a follow-up
  proposal. The hook would reject any push containing a path matching
  `.secrets.data.yml` or `keys/prod_*` regardless of `.gitignore`.
- **Replacement for the deleted `deploy:staging` / `deploy:production`
  stages.** F24 Phase 3 Step 1 deletes them outright as a standing
  trust-inversion risk, but does not replace them. A successor
  proposal needs to design the ADR-0017-compliant build-artifact →
  mons handoff: CI on met produces a signed bundle, mons verifies
  the signature and pulls the bundle from git.nwpcode.org Packages
  (or equivalent), mons alone applies it to prod. That work belongs
  to F21's remaining phases or a dedicated successor F-proposal.
- **Auto-pull frequency.** Every 30 s? Every 1 min? Every 5 min?
  Tighter is better for "met is on main", looser is gentler on
  systemd journal noise. Phase 2 default is 1 min; revisit if it
  proves wrong.
- **Hostname `carlo` vs `Carlo`.** Tracked here, not solved here.
  Will bite a script eventually.
- **`whisper-remote` PATH issue.** met's non-interactive SSH PATH
  doesn't include `~/.local/bin`, so the wrapper hardcodes
  `MET_WHISPER="/home/rob/.local/bin/whisper"`. This is fragile if
  Whisper ever moves. A small `~/.ssh/environment` change on met or
  a wrapper-side `command -v` lookup would be cleaner.
- **mini's role.** Does mini also become an always-on-main mirror?
  Useful for the X02 voice agent if it grows to need source
  context. Not in scope for F24 but easy to add later under the
  same auto-pull pattern.

---

## 10. Out of Scope

- Anything touching `mons`, prod credentials, or the mmt → mons →
  prod signing path
- Adding any new SaaS dependency
- Exposing met to the public internet
- Changing the four-state (dev → stg → live → prod) deployment model
- Rewriting `pl` to be Docker-context aware
- Replacing DDEV
- Replacing Codium / VS Code as the editor
- Moving mini's voice-agent Whisper stack
- Multi-developer access to met
- **Replacing** the legacy `deploy:staging` / `deploy:production` CI
  stages with an ADR-0017-compliant build-artifact → mons handoff
  (separate proposal). *Deleting* them is in scope — see Phase 3
  Step 1 — but designing the replacement is not.
- Pre-receive hook for secret-file rejection on git.nwpcode.org
  (separate proposal)
- LFS configuration for per-site backup repos (separate decision)

---

## 11. Cross-references

- **[CLAUDE.md](../../CLAUDE.md)** — § Project Structure (Phase 3
  adds a Branch CI Workflow note), § Threat Model (unchanged),
  § Two-Tier Secrets Architecture (F24 respects the data/infra
  tier split throughout)
- **[ADR-0017: Distributed Build/Deploy Pipeline](../decisions/0017-distributed-build-deploy-pipeline.md)**
  — names met as the build/test runner; F24 promotes the runner
  from `--depth=basic` to `--depth=thorough` and adds the
  always-on-main mirror role
- **[ADR-0004: Two-Tier Secrets Architecture](../decisions/0004-two-tier-secrets-architecture.md)**
  — governs what may and may not be replicated to met
- **[F21: Distributed Build/Deploy Pipeline](F21-distributed-build-deploy-pipeline.md)**
  — Phase 1 (Headscale) is F24's hard dependency, ✅; Phase 2 (met
  GitLab Runner) is F24's foundation for branch CI, ✅
- **[F18: Unified Backup Strategy](F18-unified-backup-strategy.md)**
  — per-site backup repos; F24 Phase 2 step 5 makes the laptop ↔
  met sync policy for them explicit
- **[F22: Gotify remote reachability](F22-gotify-remote-reachability.md)**
  — orthogonal; runs over the same Headscale mesh
- **[X02: Local Voice Agent on mini](X02-local-voice-agent-on-mini.md)**
  — mini's Whisper, explicitly not touched by F24
- **[docs/guides/voice-agent.md](../guides/voice-agent.md)** —
  mini-side docs cross-checked for laptop-Whisper assumptions
  before Phase 1

---

## 12. Decision Record

**Decided option (Phase 1):** Option A, Phase 1 only.
**Decision date (Phase 1):** 2026-04-11.
**Decision maker:** Rob.
**Phase 1 action:** Executed 2026-04-11. Laptop free space went from
19 GB to 47 GB. `whisper-remote` shipped to `~/.local/bin/`. Whisper
installed on met. Backups confirmed mirrored on both machines.

**Architectural pivot 2026-04-11:** Earlier drafts of F24 proposed
making met the canonical dev tree and turning the laptop into a
thin client (Codium Remote SSH model). The user explicitly rejected
this in two parts:

1. *"nwp should be on both with git.nwpcode.org as canonical. meta
   is upto date with main on git.nwpcode while any new code from
   dev should go to a branch first, full test on meta before
   recommendation to go to main."*
2. *"There should be a full copy of all sites in the dev nwp."*

The proposal is rewritten under those constraints: both machines
mirror the full tree (including all `sites/*` and their backups),
git.nwpcode.org is canonical, met is always-on-main via auto-pull,
and feature branches must pass `pl verify --depth=thorough` on the
met runner before they can be merged to main.

**Investigation pass 2026-04-11 (post-rewrite):** Concrete
discrepancy audit against met found three issues; two turned out
to be cheaper than the initial framing suggested, one more
serious:

1. **Docker on met was not actually broken.** Docker Engine is
   running (systemd `docker.service` active, socket at
   `/var/run/docker.sock`). The only problem was leftover Docker
   Desktop state in `~/.docker/config.json` pointing DDEV at a
   non-existent `/home/rob/.docker/desktop/docker.sock`.
   `docker context use default` was executed during the
   investigation and `ddev version` now returns clean. This is
   recorded in Phase 2 Step 0 as already-done.
2. **met's git remote swap is not a one-liner.** met has **no
   SSH key registered with git.nwpcode.org**, so a new key must
   be generated on met, wired into `~/.ssh/config`, and added as
   a read-only deploy key on the `nwp/nwp` project before
   `origin` can be repointed. met also carries a local `ollama`
   branch at `2b1b4b1b` with historical commits (F10 LLM fixes,
   `v0.29.0`, `v0.28.0`) whose relationship to canonical main
   is unverified and must be triaged before the remote swap, to
   avoid orphaning work. Phase 2 Steps 1–4 capture this as a
   five-step procedure.
3. **The legacy `deploy:staging` / `deploy:production` stages
   are a standing trust-inversion risk, not just a model
   mismatch.** If manually triggered, they ssh-keyscan the prod
   host, decode a base64 SSH key from a CI variable, and rsync
   the working tree into `${PRODUCTION_PATH}`. That puts met
   (an AI-accessible CI runner) in possession of a prod SSH
   key, which is precisely the inversion ADR-0017 exists to
   prevent. F24 originally flagged these stages as "out of
   scope, for a separate proposal"; post-investigation, Phase 3
   Step 1 now **deletes them as a required standalone commit
   before any other `.gitlab-ci.yml` work**. Replacement by an
   ADR-0017-compliant build-artifact → mons handoff remains out
   of scope and belongs to a successor proposal.

**Phase 2 action:** pending — awaits operator go-ahead on the
five-step git-remote procedure and the systemd timer install.
**Phase 3 action:** pending Phase 2. Step 1 (delete legacy
deploy stages) can be executed independently of Phase 2 and is
the recommended first substantive commit because it reduces
standing blast radius.
**Phase 4 action:** open-ended; can land any time after Phase 1.
