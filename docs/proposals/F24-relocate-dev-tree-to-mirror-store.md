## F24: Mirror NWP Tree on the `mirror-store` and Establish Branch-CI Workflow

**Status:** PROPOSED (Phase 1 complete 2026-04-11)
**Created:** 2026-04-11
**Author:** Robert Karsten Zaar (with AI assistance)
**Priority:** Medium-High (immediate trigger: `authoring` workstation disk-full crash; architectural alignment with ADR-0017)
**Depends On:** F21 Phase 1 (Headscale mesh), F21 Phase 2 (`mirror-store` GitLab Runner)
**Breaking Changes:** No (workflow is additive — the `authoring` workstation keeps full dev capability)
**Estimated Effort:** Phased; Phase 1 done, Phase 2 ~half-day, Phase 3 ~day

---

## 1. Executive Summary

### 1.1 Problem statement

On 2026-04-11 the `authoring` workstation (a low-spec ultraportable laptop:
4c/8t CPU, 15 GiB RAM, 186 GB root) froze and had to be hard power-cycled.
Post-mortem of `journalctl -b -1`:

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
| `$HOME/nwp/sites/` (DDEV project trees) | ~17 GB |
| `$HOME/.local/share/pipx/venvs/openai-whisper` | 7.0 GB |
| `$HOME/nwp/sites/*/backups/` (DB backups) | ~2.5 GB |
| `$HOME/nwp/sites/verify-test*/` (stale fixture orphans) | ~10 GB |
| `$HOME/.cache` | 3.5 GB |

The `authoring` workstation is permanently under-provisioned for the
combined load of DDEV/Docker, local Whisper, ad-hoc verify-test orphans,
and an interactive workload (Brave + Codium + Claude Code). Meanwhile,
the `mirror-store` (a 12-core CPU, mid-range discrete GPU, 32 GB RAM
desktop with 915 GB root, ~60% used) sits on the same home LAN at
`mirror-store.tailnet` and is already designated by ADR-0017 as the
primary build/test runner.

### 1.2 Proposed solution

F24 makes the `mirror-store` a **full mirror of the NWP tree** — not a
replacement for the `authoring` workstation, and not a thin-client
target. Both machines retain a complete `$HOME/nwp` working tree
including all sites, all DDEV configs, and all per-site backups. The
two trees stay coherent through **`<gitlab-host>` as the single
canonical remote**.

The workflow this enables:

1. **Edit on the `authoring` workstation** as today. Editor, browser,
   and Claude Code all stay local. Nothing about the day-to-day editing
   experience changes.
2. **Commit signed → push to a feature branch** on `<gitlab-host>`.
   Direct pushes to `main` are forbidden by branch protection.
3. **CI runs on the `mirror-store` GitLab Runner** (already shipped in F21
   Phase 2) and executes the **full** `pl verify --run --depth=thorough`
   suite plus DDEV smoke tests against the branch.
4. **Merge to main is gated** by the CI result. Only branches with a
   green thorough-verify pipeline can be merged.
5. **The `mirror-store` auto-pulls main** on a short interval. After every
   merge, the `mirror-store` converges to the new HEAD without operator
   action. The `authoring` workstation also pulls main (manually, as
   today) — both mirrors stay current.

The relief for the `authoring` workstation comes from three orthogonal
changes, not from relocation:

- Heavy *one-shot* compute (Whisper transcription, ad-hoc ffmpeg work)
  runs on the `mirror-store` via thin SSH wrappers (`whisper-remote`
  ships in Phase 1).
- Stale fixture and cache directories are cleaned up routinely; the
  habit is enforced by a `pl cleanup` style command.
- The expensive `pl verify --depth=thorough` run no longer happens on
  the `authoring` workstation at all — branch-CI on the `mirror-store`
  is the new home for it.

Docker and DDEV remain installed on **both** machines. The `authoring`
workstation runs the sites it actually uses day-to-day; the
`mirror-store` runs everything for the verify suite and acts as the
integration target.

### 1.3 Relationship to ADR-0017 and F21

ADR-0017 § Actor roster names the `mirror-store` as "always-on home
compute, primary build/test runner". F21 Phase 2 already shipped the
GitLab Runner on the `mirror-store` that exercises this role for
`pl verify --depth=basic`. F24 does two things on top of that:

1. **Promotes the runner from `--depth=basic` to `--depth=thorough`**
   so that branches genuinely earn the right to merge.
2. **Establishes mirror semantics** so the `authoring` workstation and
   `mirror-store` tree are permanently coherent through git, not
   divergent through ad-hoc rsync.

ADR-0017 also mentions "(often via Remote SSH to the `mirror-store`)"
as one possible `authoring`-workstation pattern. F24 **does not require
Remote SSH**. Remote SSH stays available for jobs that genuinely
benefit from it (large builds, mass test runs, things the `authoring`
workstation's 15 GiB RAM can't host), but it is not the default
workflow.

Earlier drafts of F24 proposed making the `mirror-store` the
"canonical dev tree" and turning the `authoring` workstation into a
thin client. That direction has been **explicitly rejected** by the
operator — see § 12 Decision Record. Both machines remain full
development workstations.

---

## 2. Goals & Non-Goals

### Goals

- `authoring`-workstation disk usage stops being a realistic failure
  mode under normal workload (Brave + Codium + Claude + Docker for
  active sites).
- Both `$HOME/nwp` trees are full mirrors — no "which copy is newest?"
  question, because the answer is always "whatever main is on
  `<gitlab-host>`".
- The `mirror-store` is **always on main** within seconds-to-minutes
  of any merge, via an auto-pull mechanism (systemd timer or cron).
- All branch work is gated by full `pl verify --depth=thorough` on
  the `mirror-store` before it can land in main. Direct push to main
  is blocked.
- Heavy one-shot compute (Whisper, etc.) runs on the `mirror-store`
  via thin wrappers, not on the `authoring` workstation.
- The `authoring` workstation retains full DDEV / Docker / `pl`
  capability for day-to-day work; nothing about the local edit-test
  loop is taken away.
- No new AI-touches-prod paths. Branch CI is dev-side only; the
  `signed-deploy` → prod boundary is unchanged.

### Non-Goals

- **Making the `authoring` workstation a thin client.** The `authoring`
  workstation remains a full development workstation. Docker, DDEV,
  and `pl` continue to run locally for the sites the operator
  actively works on.
- **Single-tree-on-`mirror-store` model.** Earlier drafts of F24
  proposed this; it has been rejected. Both machines mirror the full
  tree.
- **Replacing `<gitlab-host>` as canonical remote.** It stays
  canonical. F24 makes the `mirror-store` *track* canonical, not
  *become* it.
- **Pushing branches directly between `authoring` and `mirror-store`.**
  All sync is through `<gitlab-host>`. There is no
  `authoring` ↔ `mirror-store` git transport.
- **Two-way file sync (unison/mutagen).** We are not introducing a
  sync daemon. git is the sync mechanism.
- **Moving the `ai-host`'s voice-agent Whisper stack.** The `ai-host`'s
  Whisper is a separate concern (X02). F24 only touches the
  `authoring` workstation's pipx-installed Whisper that exists for
  ad-hoc transcription.
- **Touching the `signed-deploy` → prod path.** Out of scope; the
  boundary is inviolable.
- **Removing the existing `deploy:staging` / `deploy:production` CI
  stages.** Those stages contradict ADR-0017's `signed-deploy`-mediated
  model but cleaning them up belongs to a separate proposal — see § 9.
- **Multi-developer access to the `mirror-store`.** The `mirror-store`
  is single-user under this proposal.

---

## 3. Current State

### 3.1 Machines in play

| Machine | CPU | RAM | Root disk | Role today | Role after F24 |
|---|---|---|---|---|---|
| `authoring` (ultraportable laptop) | i7-1165G7-class (4c/8t) | 15 GiB | 186 GB / now 47 GB free | Full dev workstation; sometimes overloaded | Full dev workstation; offloads heavy one-shot compute and full verify to `mirror-store` |
| `mirror-store` (always-on desktop) | 12-core CPU, mid-range discrete GPU | 32 GiB | 915 GB / 60% used | F21 Phase 2 GitLab Runner (basic verify) | F21 runner + always-on-main mirror + branch CI runner for `--depth=thorough` |

### 3.2 What's on the `authoring` workstation after Phase 1

```
$HOME/nwp                                            18 GB
  sites/avc                                           3.5 GB
  sites/avc/backups                                   1.9 GB    (mirrored on mirror-store)
  sites/ss                                            2.2 GB
  sites/{ba,cathnet,dir1,mt,mayo,cccrdf,opensocial2} ~7 GB
  sites/mayo/backups                                  12 MB     (mirrored on mirror-store)
/var/lib/docker                                     ~26 GB
$HOME/.cache                                        ~3 GB
```

Phase 1 reclaimed ~21 GB on the `authoring` workstation (free space went
from 19 GB to 47 GB) by deleting:

- 4 old `.deb` installers (~843 MB)
- 17 stale `verify-test*` orphan directories (~10 GB)
- the local `openai-whisper` pipx venv (7 GB) — replaced by
  `$HOME/.local/bin/whisper-remote`
- Docker image and builder caches (~3.5 GB)

The `authoring` workstation tree and the `mirror-store` tree are now
**identical mirrors** for all `sites/*/backups/` content (verified by
rsync round-trip on 2026-04-11).

### 3.3 What the `mirror-store` looks like today

- F21 Phase 2 runner installed and serving the `nwp,mirror-store` tags.
- `$HOME/nwp` clone exists but is **behind canonical main**: the
  `mirror-store` is at `da39764f`, the `authoring` workstation is at
  `7df7e24a` (3 commits ahead). No auto-pull is installed yet.
- `git remote -v` for the `mirror-store`'s `$HOME/nwp` clone currently
  points at a public GitHub mirror, **not** `<gitlab-host>`. This is a
  discrepancy with the operator's stated direction and must be fixed
  in Phase 2 before the auto-pull mechanism is enabled.
- The `mirror-store` also has no SSH key registered for `<gitlab-host>`
  (`ssh -T git@<gitlab-host>` returns `Permission denied
  (publickey)`), so the remote retargeting in Phase 2 requires a
  new key to be generated on the `mirror-store` and added as a deploy
  key on the `nwp/nwp` project first.
- The `mirror-store` has a **local `ollama` branch** at `2b1b4b1b`
  containing F10 LLM-related commits and historical release tags
  (`v0.29.0`, `v0.28.0`) that are not visible on `main` from the
  `authoring` workstation. Needs triage in Phase 2 before `origin` is
  repointed — the work may have been rebased/cherry-picked to main
  under different SHAs, or it may be orphaned and need pushing to
  `<gitlab-host>` before the remote swap.
- Docker Engine **is** running on the `mirror-store` (systemd
  `docker.service` active, socket at `/var/run/docker.sock`). An
  earlier investigation pass misdiagnosed Docker as "broken" — in
  fact the only problem was that `$HOME/.docker/config.json` had
  leftover Docker Desktop state (`"credsStore": "desktop"`,
  `"currentContext": "desktop-linux"`) pointing DDEV at a
  non-existent socket at `$HOME/.docker/desktop/docker.sock`. Running
  `docker context use default` once was sufficient to restore
  DDEV; `ddev version` now returns clean (DDEV v1.24.10, docker
  29.3.0, compose v2.40.3). This was executed during F24
  investigation on 2026-04-11 and is already fixed.
- F21 Phase 2's GitLab Runner is already sharing this daemon
  successfully; the coexistence check in the earlier draft is
  therefore low-priority rather than a blocker.
- Whisper installed via pipx, accessible from the `authoring`
  workstation through `whisper-remote` (Phase 1 deliverable).

### 3.4 What the CI pipeline does today

`.gitlab-ci.yml` already has:

- Branch-push triggers (`$CI_PIPELINE_SOURCE == "push"`) and merge
  request triggers.
- A `test:verification` stage that runs
  `./scripts/commands/verify.sh ci --depth=basic --export-json`,
  but **only on `main` and merge requests** — not on arbitrary
  feature branches.
- `tags: [nwp, mirror-store]` targeting the F21 runner.
- `deploy:preview` / `cleanup:preview` stub stages for MR previews.
- `deploy:staging` / `deploy:production` / `stop:staging` stages
  (`.gitlab-ci.yml:535–643`) that ssh-keyscan `$STAGING_HOST` /
  `$PRODUCTION_HOST`, decode a base64 SSH key from CI variables
  (`$STAGING_SSH_KEY` / `$PRODUCTION_SSH_KEY`), rsync the entire
  working tree into `${STAGING_PATH}` / `${PRODUCTION_PATH}`, then
  ssh into the host and run `ddev drush deploy`. These stages are
  gated only by `when: manual`, but if ever clicked, they put the
  CI runner (the `mirror-store`, an AI-accessible machine per
  ADR-0017) in possession of an SSH key to prod and writing
  arbitrary files into the production path. **This is precisely the
  trust inversion ADR-0017 exists to prevent.** They also assume a
  pre-F17/F23 site layout (rsync `./` → a single target path,
  no per-site structure, no sanitizer, no `signed-deploy`). They are
  leftover stubs from before `signed-deploy` was introduced, and F24
  removes them — see § 6 Phase 3 step 1.

The gap F24 closes: the runner only proves `--depth=basic` against
`main` and MRs. Feature branches don't get the full
`--depth=thorough` treatment, and there is no merge gate that
*requires* a green thorough run. F24 also closes the standing
trust-inversion exposure by deleting the legacy staging/production
deploy stages before touching the thorough-verify additions.

---

## 4. Options Considered

### 4.1 Option A — Mirror tree, branch-CI workflow (recommended)

Both machines hold full `$HOME/nwp` trees. `<gitlab-host>` is canonical.
The `mirror-store` auto-pulls main. Dev pushes feature branches; CI runs
full `--depth=thorough` verify on the `mirror-store` runner; branches
that pass can be merged; the `mirror-store` converges on main
automatically.

**Pros:**
- Zero workflow change for the editor experience. The `authoring`
  workstation keeps doing what it does today.
- Heavy verify load moves off the `authoring` workstation
  **automatically** — developers don't need to remember to run it on
  the `mirror-store`, because they push a branch and CI handles it.
- Mirror semantics are guaranteed by git rather than by ad-hoc rsync.
  No drift, no two-source-of-truth problems.
- Naturally extends to multi-machine in the future (e.g. the `ai-host`
  could also become an always-on-main mirror) without re-architecting.
- Matches ADR-0017's spirit: the `mirror-store` is the build/test
  runner, the `authoring` workstation is the developer workstation,
  and trust flows through git and signatures rather than through
  "which machine has the freshest copy".
- Reversible at every step. Disabling auto-pull on the `mirror-store`
  or blocking the new CI stage is a one-line change.

**Cons:**
- Requires actually wiring branch protection on `<gitlab-host>`,
  which the operator has not yet done.
- The `mirror-store`'s Docker daemon needs to be fixed before branch CI
  can run DDEV-touching jobs.
- The `mirror-store`'s git remote needs to be retargeted from GitHub
  to `<gitlab-host>` before auto-pull is meaningful.
- The full `--depth=thorough` verify is slower than `--depth=basic`,
  so feedback latency on a push is longer (minutes, not seconds).
  Mitigation: keep the basic verify as a fast-fail stage that runs
  first.

### 4.2 Option B — Single canonical tree on the `mirror-store`, `authoring` workstation as thin client

Earlier draft of F24. Move `$HOME/nwp` to the `mirror-store` permanently;
the `authoring` workstation edits via Codium Remote SSH; uninstall
Docker on the `authoring` workstation.

**Rejected** because the operator has explicitly stated both machines
should retain full mirrors and the `authoring` workstation should remain
a full development workstation. See § 12 Decision Record. Pros and cons
are preserved in git history of this file (commit prior to the
2026-04-11 rewrite) for context.

### 4.3 Option C — Hybrid: Docker-only relocation via `DOCKER_HOST=ssh://<mirror-store>`

Keep `$HOME/nwp` on the `authoring` workstation, but point DDEV at the
`mirror-store`'s Docker daemon over SSH.

**Rejected** because:

- DDEV-over-remote-Docker is a known sharp-edge configuration. Bind
  mounts from the `authoring` workstation into containers on the
  `mirror-store` require an overlay (NFS, SSHFS, Mutagen) to perform
  adequately, and DDEV's bind-mount assumptions break in subtle ways.
- It doesn't actually deliver the Phase 3 win (branch CI on the
  `mirror-store`), which is the load-bearing improvement F24 makes.
- The ddev-router has to live somewhere. Either it runs on the
  `mirror-store` and the `authoring` workstation tunnels 80/443
  (introduces port-conflict pain) or it runs on the `authoring`
  workstation and routes to containers on the `mirror-store` (adds a
  second network hop per request). Neither is great.

### 4.4 Option D — Two-way file sync (unison / mutagen)

Use a sync daemon to keep `$HOME/nwp` coherent between the `authoring`
workstation and the `mirror-store` without going through git.

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

Add an external NVMe to the `authoring` workstation and keep the current
workflow.

**Rejected** because RAM is the tighter constraint than disk; a
bigger disk doesn't help with the memory-pressure half of the crash.
And it doesn't deliver the branch-CI win at all.

---

## 5. Recommendation

Take **Option A** in four phases. Phase 1 is already done (2026-04-11)
and bought ~28 GB of `authoring`-workstation free space without any
architectural change. The remaining phases are sequential and each is
independently useful.

**Phase 2** (mirror infrastructure on the `mirror-store`) should start
once the operator has confirmed the rewritten F24 direction matches
their mental model — see § 12.

**Phase 3** (branch-CI workflow) follows once Phase 2 is stable and
the `mirror-store` is reliably converging on main.

**Phase 4** (optional remote-compute wrappers beyond `whisper-remote`)
is open-ended cleanup that can land any time after Phase 1.

---

## 6. Phases

### Phase 1 — Leaf cleanup and `whisper-remote` (DONE 2026-04-11)

| Step | Result |
|---|---|
| Delete 4 old `.deb` installers | ~843 MB freed |
| Delete 17 stale `verify-test*` orphan directories on the `authoring` workstation | ~10 GB freed |
| Uninstall `$HOME/.local/share/pipx/venvs/openai-whisper` on the `authoring` workstation | 7 GB freed |
| Install `openai-whisper` via pipx on the `mirror-store` | + ~7 GB on the `mirror-store` (well within headroom) |
| Install `$HOME/.local/bin/whisper-remote` wrapper on the `authoring` workstation | scp + ssh + scp pattern, hardcoded full path to the `mirror-store`'s whisper |
| `docker image prune -a -f` on the `authoring` workstation | 2.5 GB freed |
| `docker builder prune -a -f` on the `authoring` workstation | 966 MB freed |
| `docker volume prune -f` on the `authoring` workstation | 0 B (volumes pinned by paused DDEV containers — left alone) |
| Verify `sites/avc/backups/` and `sites/mayo/backups/` are mirrored on both machines | verified by rsync round-trip 2026-04-11 |

Phase 1 totals: `authoring`-workstation free space went from
**19 GB to 47 GB** (+28 GB). No workflow change required. No code
change required. Reversible by re-running `pipx install openai-whisper`
and re-pulling images on demand (DDEV does this automatically when
projects start).

### Phase 2 — Mirror infrastructure on the `mirror-store`

**Step 0 — Docker context cleanup (already done 2026-04-11).**
Running `docker context use default` on the `mirror-store` was
sufficient to restore DDEV. `ddev version` returns clean. Optional
follow-up: edit `$HOME/.docker/config.json` on the `mirror-store` to
remove `"credsStore": "desktop"` and `"currentContext":
"desktop-linux"`, which are Docker Desktop leftovers that cause
cosmetic warnings. No package install or systemd work is required —
Docker Engine was already running the whole time.

**Step 1 — Generate a dedicated SSH key on the `mirror-store` for
`<gitlab-host>`.** The `mirror-store` currently has 15+ SSH keys in
`$HOME/.ssh/` but none registered with `<gitlab-host>`. Create a new
identity scoped to this purpose:

```bash
ssh mirror-store.tailnet "ssh-keygen -t ed25519 \
  -f ~/.ssh/git-gitlab-host -C 'mirror-store@<gitlab-host>' -N ''"
ssh mirror-store.tailnet "cat ~/.ssh/git-gitlab-host.pub"
```

Add the public key to the `nwp/nwp` GitLab project as a
**read-only deploy key** (not a user account key) — the tighter
scope for an always-on-main mirror that never pushes.

**Step 2 — Wire the key into the `mirror-store`'s SSH config.** Append to
`$HOME/.ssh/config` on the `mirror-store`:

```
Host <gitlab-host>
    IdentityFile ~/.ssh/git-gitlab-host
    IdentitiesOnly yes
```

Verify: `ssh mirror-store.tailnet "ssh -T git@<gitlab-host>"`
should return GitLab's welcome banner rather than
`Permission denied (publickey)`.

**Step 3 — Triage the local `ollama` branch on the `mirror-store`.** The
`mirror-store` has a local `ollama` branch at `2b1b4b1b` with
F10-related commits and historical releases that aren't visible on
main from the `authoring` workstation. Compare the ranges before
touching `origin`:

```bash
ssh mirror-store.tailnet "cd ~/nwp && git log --oneline main..ollama"
```

If all commits in that range already exist on canonical main
(under the same or rebased SHAs), the branch is safely
discardable. If any are orphaned, push the branch to
`<gitlab-host>` as `archive/mirror-store-ollama-2026-04-11` before the
remote swap so the work isn't lost to a stale remote.

**Step 4 — Retarget `origin` and fast-forward main.**

```bash
ssh mirror-store.tailnet "cd ~/nwp && \
  git remote set-url origin git@<gitlab-host>:nwp/nwp.git && \
  git fetch origin && \
  git checkout main && \
  git merge --ff-only origin/main && \
  git remote prune origin"
```

Fast-forward-only is intentional: if the `mirror-store`'s main has
somehow diverged from canonical main, the merge fails loudly rather
than guessing. Run only after Step 3 confirms no orphaned work.

**Step 5 — Install the auto-pull systemd timer.** Create
`/etc/systemd/system/nwp-auto-pull-main.service`:

```ini
[Unit]
Description=NWP: keep ~/nwp on origin/main
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=<operator>
ExecStart=/usr/bin/git -C $HOME/nwp fetch --quiet origin main
ExecStart=/usr/bin/git -C $HOME/nwp merge --ff-only origin/main
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
are the signal to switch to a feature branch on the `mirror-store`.

**Step 6 — Coexistence check with F21 runner.** Now a
low-priority sanity check rather than a blocker, because the
runner and DDEV already share `/var/run/docker.sock` cleanly.
Verify by starting a DDEV project on the `mirror-store` while the
runner is idle and watching `docker ps` for unexpected contention.
If the two ever fight (e.g. a verify run on the runner starts while a
DDEV project on the `mirror-store` holds the ddev-router ports), give
the runner its own Docker context or namespace the DDEV port range.

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
naming the `mirror-store` as the always-on-main mirror, pointing at
the systemd unit files, and stating the fast-forward-only guarantee.

**Phase 2 deliverables:**

- The `mirror-store` has a dedicated `<gitlab-host>` deploy key
  (read-only scope).
- The `mirror-store`'s `origin` is `git@<gitlab-host>:nwp/nwp.git`, not
  GitHub; local main is a fast-forward of canonical main.
- Any orphaned `ollama`-branch work is pushed to
  `archive/mirror-store-ollama-2026-04-11` (or confirmed redundant).
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
clicks the manual trigger, they grant the `mirror-store` (an
AI-accessible CI runner) an SSH key to prod and a direct rsync path
into `${PRODUCTION_PATH}`, which is exactly the trust inversion
ADR-0017 exists to prevent.

Three approaches were considered:

- **A (chosen): delete outright.** One focused commit that
  removes the `deploy:staging`, `stop:staging`, and
  `deploy:production` jobs and the matching variable docs. Keeps
  the diff small and reviewable; rollback is a `git revert`.
- **B: neuter in place.** Replace each script body with
  `exit 1 "signed-deploy-mediated per ADR-0017"`. Rejected because it
  leaves misleading job names in the pipeline UI that someone
  will eventually try to debug.
- **C: defer to a successor proposal.** Leave for whichever
  later proposal implements the ADR-0017-compliant
  build-artifact → `signed-deploy` handoff and replaces the stages in
  the same change. Rejected because the current state has standing
  blast radius and shouldn't persist longer than necessary.

After the deletion commit lands, **rotate or remove any
`STAGING_SSH_KEY`, `PRODUCTION_SSH_KEY`, `STAGING_HOST`,
`STAGING_USER`, `STAGING_PATH`, `PRODUCTION_SSH_KEY`,
`PRODUCTION_HOST`, `PRODUCTION_USER`, `PRODUCTION_PATH`, and
any matching `$*_DB_PASSWORD` / `$*_API_KEY` variables from the
`<gitlab-host>` project CI/CD settings.** Stale credentials in
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

**Step 4 — Configure branch protection on `<gitlab-host>`.** In
the GitLab project settings:

- Protect `main`. Disallow direct push.
- Require merge requests for changes to main.
- Require the `test:verification:thorough` pipeline status to be
  green before the merge button is enabled.
- Require the verify-signature job (already in CI) to be green.

**Step 5 — Document the new dev workflow** in
`docs/guides/branch-ci-workflow.md`:

- "Edit on the `authoring` workstation. Commit signed. Push a branch.
  Watch the pipeline at `<gitlab-host>`. When it goes green, open an
  MR and merge. The `mirror-store` converges on main within ~1 min."
- Include the rare-case escape hatches (force-push to a personal
  branch is fine; force-push to main is blocked by protection).

**Step 6 — Verify the merge gate end-to-end** with a deliberately
trivial no-op branch.

**Phase 3 deliverables:**

- The legacy `deploy:staging` / `deploy:production` / `stop:staging`
  stages no longer exist in `.gitlab-ci.yml`. Their associated CI
  variables no longer exist in `<gitlab-host>` project settings.
- Branches that don't pass `--depth=thorough` cannot be merged
  into main.
- The `mirror-store` converges on main within ~1 min of every merge.
- The dev workflow is documented and tested end-to-end.

### Phase 4 — Optional: more remote-compute wrappers

Whenever a heavy one-shot tool surfaces a need (ffmpeg encoding,
Drupal `composer install` against a fat repo, large rsync of
production fixtures), add a thin SSH wrapper to `$HOME/.local/bin/`
that runs the tool on the `mirror-store` instead. `whisper-remote` is
the template.

This is open-ended. No commitment to a specific list.

---

## 7. Affected NWP Components

### 7.1 New paths

| Path | Purpose |
|---|---|
| `$HOME/.local/bin/whisper-remote` (`authoring` workstation, not in git) | Phase 1 — wrapper that runs Whisper on the `mirror-store` via ssh |
| `/etc/systemd/system/nwp-auto-pull-main.{service,timer}` (`mirror-store`, not in git) | Phase 2 — keeps the `mirror-store`'s `$HOME/nwp` converged on origin/main |
| `docs/guides/branch-ci-workflow.md` | Phase 3 — operator runbook for the branch → CI → merge workflow |
| `docs/guides/mirror-store-as-mirror.md` | Phase 2 — operator runbook: retargeting the git remote, fixing Docker, installing the auto-pull timer |

### 7.2 Modified paths

| Path | Change |
|---|---|
| `.gitlab-ci.yml` (first commit) | Phase 3 Step 1 — delete `deploy:staging`, `stop:staging`, `deploy:production` jobs and their variable documentation blocks (lines 535–643 and ~655–690 in the current file) |
| `.gitlab-ci.yml` (second commit) | Phase 3 Steps 2–3 — add `test:verification:thorough` job, expand branch-push triggers, mark thorough verify as required for merge to main |
| `<gitlab-host>` `nwp/nwp` CI/CD variables | Phase 3 Step 1 — remove `STAGING_SSH_KEY`, `PRODUCTION_SSH_KEY`, `STAGING_HOST`, `STAGING_USER`, `STAGING_PATH`, `PRODUCTION_HOST`, `PRODUCTION_USER`, `PRODUCTION_PATH` (in GitLab UI, not in code) |
| `<gitlab-host>` `nwp/nwp` deploy keys | Phase 2 Step 1 — add new read-only deploy key `mirror-store@<gitlab-host>` (public key generated on the `mirror-store`) |
| `mirror-store`: `$HOME/.docker/config.json` | Phase 2 Step 0 — optional cosmetic cleanup, remove `credsStore` and `currentContext` Docker Desktop leftovers |
| `mirror-store`: `$HOME/.ssh/config` | Phase 2 Step 2 — add `Host <gitlab-host>` block pinning `IdentityFile` to `~/.ssh/git-gitlab-host` |
| `mirror-store`: `$HOME/nwp/.git/config` | Phase 2 Step 4 — `origin` URL changes from GitHub to `<gitlab-host>` |
| `docs/decisions/0017-distributed-build-deploy-pipeline.md` | Phase 2 Step 8 — add an "always-on-main mirror" subsection naming the `mirror-store` and pointing at the auto-pull timer |
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
- **Anything under `signed-deploy`, prod, sanitizer, or the
  `build-tier` → prod signing path** — completely out of scope.

### 7.4 Data that must not move during this migration

Per CLAUDE.md § Two-Tier Secrets Architecture and ADR-0004:

- **`.secrets.data.yml`** must not be transmitted to the `mirror-store`
  by F24. Phase 2's git remote work runs over `git fetch`, which only
  ever pulls what is in the canonical remote — no untracked secret
  files can sneak across that path. Any auxiliary rsync used in Phase
  2 or later **must** include an explicit
  `--exclude='.secrets.data.yml'` and `--exclude='keys/prod_*'`.
- **`keys/prod_*`** must not move to the `mirror-store`. Same reasoning.
  Both trees verified clean as of 2026-04-11 (only `.gitkeep` in
  `keys/` on each).
- **Sanitizer scripts** are security-critical per CLAUDE.md and
  must not be modified by F24 even incidentally.

---

## 8. Risk Assessment

### High risk

| Risk | Mitigation |
|---|---|
| **The auto-pull timer races with an in-progress edit on the `mirror-store`** (e.g. an interactive `pl` invocation, a `ddev` start, a verify run). | Auto-pull is `merge --ff-only` only. If the working tree is dirty or local main has diverged, the merge fails loudly and a journal entry is logged. The timer never force-resets. Rule of thumb: use feature branches for any in-place experimentation on the `mirror-store`. |
| **Branch CI thorough verify takes long enough that developers stop pushing branches** and route around the merge gate. | Phase 3 keeps the basic verify job as a fast-fail first stage. Thorough verify runs in parallel where possible. Keep the merge gate strict regardless: a slow gate is still better than no gate. If it becomes painful, optimise verify, don't bypass the gate. |
| **A `.secrets.data.yml` or `keys/prod_*` file accidentally enters the tree on the `authoring` workstation and gets pushed to `<gitlab-host>` via a feature branch.** | `.gitignore` already excludes both. CI's `verify-signature` and lint stages run on every push. Add a pre-receive hook on `<gitlab-host>` (out of scope for F24 itself, but flagged in § 9) that rejects pushes containing `.secrets.data.yml` regardless of `.gitignore`. |
| **The `mirror-store`'s git remote is currently pointing at GitHub, not `<gitlab-host>`**, and the `mirror-store` has no SSH key registered for `<gitlab-host>`, so the "always on main" claim is currently false in a confusing way. Also, the `mirror-store` carries a local `ollama` branch with historical commits whose relationship to canonical main is unverified. | Phase 2 Steps 1–4 fix this explicitly (generate key, wire SSH config, triage ollama branch, retarget origin). Until Step 4 succeeds, do not install the auto-pull timer. |
| **The `deploy:staging` / `deploy:production` / `stop:staging` CI stages grant the `mirror-store` an SSH key to prod if manually triggered.** This is a standing trust-inversion violation of ADR-0017, not just a model mismatch. | Phase 3 Step 1 deletes the stages as a small standalone commit before any other `.gitlab-ci.yml` work. The matching CI variables (`STAGING_SSH_KEY`, `PRODUCTION_SSH_KEY`, etc.) are removed from `<gitlab-host>` project settings in the same step. |

### Medium risk

| Risk | Mitigation |
|---|---|
| F21 Phase 2 GitLab Runner and Phase 2 DDEV projects both use Docker; they may contend. | Lower priority than originally assessed — the runner and DDEV already share `/var/run/docker.sock` cleanly as of 2026-04-11. Phase 2 Step 6 still sanity-checks coexistence under load; if they fight, the runner gets its own Docker context or DDEV uses a non-default port range. |
| Per-site backup repos under `sites/<name>/backups/` are local-only. If both mirrors drift (one has a backup the other doesn't), the rsync direction matters. | Phase 2 Step 7 makes the sync policy explicit. Default: rsync from the `authoring` workstation to the `mirror-store` daily; never delete on the receiving side without confirmation. |
| Triaging the `ollama` branch on the `mirror-store` requires judgment. Commits may have been rebased onto main under different SHAs, or they may be genuinely orphaned. Getting it wrong means either losing work or preserving stale cruft as an archive branch forever. | Phase 2 Step 3 is a review gate, not a script. The operator makes the call after reading `git log --oneline main..ollama`. Default-safe: if in doubt, push as `archive/mirror-store-ollama-2026-04-11` before the remote swap. The archive branch costs nothing to keep. |
| Removing the legacy staging/production deploy stages leaves CI with no "deploy" path at all until a successor proposal lands. | Acceptable — the stages never worked in the F17/F23 site layout anyway, and manual SSH deploys remain available out-of-band. The replacement belongs to the ADR-0017-compliant build-artifact handoff proposal. |

### Low risk

| Risk | Mitigation |
|---|---|
| The `mirror-store`'s 915 GB disk fills up. | Currently 60 % used. Adding a full DDEV stack and verify fixtures is well under another 100 GB. Plenty of headroom. |
| Hostname collisions confuse scripts. | Always use `mirror-store.tailnet` explicitly in runbooks and CI. Never rely on short hostnames. |
| Codium Remote SSH (still available, just not the default) breaks under some extension. | Not exercised by F24's default workflow. Falls back to local edit. |

---

## 9. Open Questions

- **Per-site backup repos and `<gitlab-host>`.** Should each
  `sites/<name>/backups/` repo become a real GitLab project under
  `nwp/site-backups/<name>` with LFS for the dump files, or stay as
  local-only repos that are mirrored through rsync? The local-only
  path is simpler but means one machine could drift from the other
  if rsync fails silently. F18 originally assumed local-only; F24
  Phase 2 defaults to that and flags the question for revisit.
- **Pre-receive hook on `<gitlab-host>` for accidental secret
  pushes.** Out of scope for F24 itself but worth a follow-up
  proposal. The hook would reject any push containing a path matching
  `.secrets.data.yml` or `keys/prod_*` regardless of `.gitignore`.
- **Replacement for the deleted `deploy:staging` / `deploy:production`
  stages.** F24 Phase 3 Step 1 deletes them outright as a standing
  trust-inversion risk, but does not replace them. A successor
  proposal needs to design the ADR-0017-compliant build-artifact →
  `signed-deploy` handoff: CI on the `mirror-store` produces a signed
  bundle, `signed-deploy` verifies the signature and pulls the bundle
  from `<gitlab-host>` Packages (or equivalent), `signed-deploy` alone
  applies it to prod. That work belongs to F21's remaining phases or
  a dedicated successor F-proposal.
- **Auto-pull frequency.** Every 30 s? Every 1 min? Every 5 min?
  Tighter is better for "the `mirror-store` is on main", looser is
  gentler on systemd journal noise. Phase 2 default is 1 min; revisit
  if it proves wrong.
- **`whisper-remote` PATH issue.** The `mirror-store`'s non-interactive
  SSH PATH doesn't include `$HOME/.local/bin`, so the wrapper
  hardcodes `MS_WHISPER="$HOME/.local/bin/whisper"`. This is fragile
  if Whisper ever moves. A small `$HOME/.ssh/environment` change on
  the `mirror-store` or a wrapper-side `command -v` lookup would be
  cleaner.
- **`ai-host`'s role.** Does the `ai-host` also become an
  always-on-main mirror? Useful for the X02 voice agent if it grows
  to need source context. Not in scope for F24 but easy to add later
  under the same auto-pull pattern.

---

## 10. Out of Scope

- Anything touching `signed-deploy`, prod credentials, or the
  `build-tier` → `signed-deploy` → prod signing path
- Adding any new SaaS dependency
- Exposing the `mirror-store` to the public internet
- Changing the four-state (dev → stg → live → prod) deployment model
- Rewriting `pl` to be Docker-context aware
- Replacing DDEV
- Replacing Codium / VS Code as the editor
- Moving the `ai-host`'s voice-agent Whisper stack
- Multi-developer access to the `mirror-store`
- **Replacing** the legacy `deploy:staging` / `deploy:production` CI
  stages with an ADR-0017-compliant build-artifact → `signed-deploy`
  handoff (separate proposal). *Deleting* them is in scope — see
  Phase 3 Step 1 — but designing the replacement is not.
- Pre-receive hook for secret-file rejection on `<gitlab-host>`
  (separate proposal)
- LFS configuration for per-site backup repos (separate decision)

---

## 11. Cross-references

- **[CLAUDE.md](../../CLAUDE.md)** — § Project Structure (Phase 3
  adds a Branch CI Workflow note), § Threat Model (unchanged),
  § Two-Tier Secrets Architecture (F24 respects the data/infra
  tier split throughout)
- **[ADR-0017: Distributed Build/Deploy Pipeline](../decisions/0017-distributed-build-deploy-pipeline.md)**
  — names the `mirror-store` as the build/test runner; F24 promotes
  the runner from `--depth=basic` to `--depth=thorough` and adds the
  always-on-main mirror role
- **[ADR-0004: Two-Tier Secrets Architecture](../decisions/0004-two-tier-secrets-architecture.md)**
  — governs what may and may not be replicated to the `mirror-store`
- **[F21: Distributed Build/Deploy Pipeline](F21-distributed-build-deploy-pipeline.md)**
  — Phase 1 (Headscale) is F24's hard dependency; Phase 2
  (`mirror-store` GitLab Runner) is F24's foundation for branch CI
- **[F18: Unified Backup Strategy](F18-unified-backup-strategy.md)**
  — per-site backup repos; F24 Phase 2 step 5 makes the
  `authoring` ↔ `mirror-store` sync policy for them explicit
- **[F22: Gotify remote reachability](F22-gotify-remote-reachability.md)**
  — orthogonal; runs over the same Headscale mesh
- **X02: Local Voice Agent on the `ai-host`** — the `ai-host`'s
  Whisper, explicitly not touched by F24
- **`docs/guides/voice-agent.md`** — `ai-host`-side docs cross-checked
  for `authoring`-workstation-Whisper assumptions before Phase 1

---

## 12. Decision Record

**Decided option (Phase 1):** Option A, Phase 1 only.
**Decision date (Phase 1):** 2026-04-11.
**Decision maker:** the operator.
**Phase 1 action:** Executed 2026-04-11. `authoring`-workstation free
space went from 19 GB to 47 GB. `whisper-remote` shipped to
`$HOME/.local/bin/`. Whisper installed on the `mirror-store`. Backups
confirmed mirrored on both machines.

**Architectural pivot 2026-04-11:** Earlier drafts of F24 proposed
making the `mirror-store` the canonical dev tree and turning the
`authoring` workstation into a thin client (Codium Remote SSH model).
The operator explicitly rejected this in two parts:

1. *"nwp should be on both with `<gitlab-host>` as canonical. The
   mirror is up to date with main on `<gitlab-host>` while any new
   code from dev should go to a branch first, full test on the
   mirror before recommendation to go to main."*
2. *"There should be a full copy of all sites in the dev nwp."*

The proposal is rewritten under those constraints: both machines
mirror the full tree (including all `sites/*` and their backups),
`<gitlab-host>` is canonical, the `mirror-store` is always-on-main via
auto-pull, and feature branches must pass `pl verify --depth=thorough`
on the `mirror-store` runner before they can be merged to main.

**Investigation pass 2026-04-11 (post-rewrite):** Concrete
discrepancy audit against the `mirror-store` found three issues; two
turned out to be cheaper than the initial framing suggested, one more
serious:

1. **Docker on the `mirror-store` was not actually broken.** Docker
   Engine is running (systemd `docker.service` active, socket at
   `/var/run/docker.sock`). The only problem was leftover Docker
   Desktop state in `$HOME/.docker/config.json` pointing DDEV at a
   non-existent `$HOME/.docker/desktop/docker.sock`.
   `docker context use default` was executed during the
   investigation and `ddev version` now returns clean. This is
   recorded in Phase 2 Step 0 as already-done.
2. **The `mirror-store`'s git remote swap is not a one-liner.** The
   `mirror-store` has **no SSH key registered with `<gitlab-host>`**,
   so a new key must be generated on the `mirror-store`, wired into
   `$HOME/.ssh/config`, and added as a read-only deploy key on the
   `nwp/nwp` project before `origin` can be repointed. The
   `mirror-store` also carries a local `ollama` branch at `2b1b4b1b`
   with historical commits (F10 LLM fixes, `v0.29.0`, `v0.28.0`)
   whose relationship to canonical main is unverified and must be
   triaged before the remote swap, to avoid orphaning work. Phase 2
   Steps 1–4 capture this as a five-step procedure.
3. **The legacy `deploy:staging` / `deploy:production` stages
   are a standing trust-inversion risk, not just a model
   mismatch.** If manually triggered, they ssh-keyscan the prod
   host, decode a base64 SSH key from a CI variable, and rsync
   the working tree into `${PRODUCTION_PATH}`. That puts the
   `mirror-store` (an AI-accessible CI runner) in possession of a
   prod SSH key, which is precisely the inversion ADR-0017 exists to
   prevent. F24 originally flagged these stages as "out of scope,
   for a separate proposal"; post-investigation, Phase 3 Step 1 now
   **deletes them as a required standalone commit before any other
   `.gitlab-ci.yml` work**. Replacement by an ADR-0017-compliant
   build-artifact → `signed-deploy` handoff remains out of scope and
   belongs to a successor proposal.

**Phase 2 action:** pending — awaits operator go-ahead on the
five-step git-remote procedure and the systemd timer install.
**Phase 3 action:** pending Phase 2. Step 1 (delete legacy
deploy stages) can be executed independently of Phase 2 and is
the recommended first substantive commit because it reduces
standing blast radius.
**Phase 4 action:** open-ended; can land any time after Phase 1.

---

## 13. Reference deployment

This public proposal is written in role-label form per
[F34](F34-role-label-proposal-rewrite.md). The operator-specific
bindings (actual hostnames for `authoring` and the `mirror-store`,
hardware SKUs, host-collision quirks, the specific GitHub/GitLab
URLs, and milestone-to-commit-hash mapping) live in the private
instance addendum at `nwp-instances/_proposals-private/F24-instance.md`.
