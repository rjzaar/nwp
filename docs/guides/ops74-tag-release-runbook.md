# Tag & release runbook — ADR-0031 Phase B (ops#74)

> **Status: READY TO RUN on the build host / GitLab once the operator confirms.**
> Every step is **AI-PREPARABLE** (a command/edit an assistant prepares, operator
> runs) or **OPERATOR** (a credentialed push/tag/release, or a decision). Nothing
> here was executed by the Phase-B planning branch — this runbook *is* the
> execution plan the branch delivers. **The AI-run workstation deliberately did
> NOT tag, push, or create any release** (threat model: no AI-run machine cuts a
> real tag/release). **Date:** 2026-07-10.
> **Companion (the *why* + the scheme):** [`ops74-versioning-scheme.md`](ops74-versioning-scheme.md).
> **ADR:** [ADR-0031](../decisions/0031-paired-site-versioning-and-promotion.md) D3.
> **Depends on:** ops#73 reconcile (plugin repos must be reconciled before tagged).

---

## 0. AI-preparable vs. operator-hands

| # | Step | Who | Why |
|---|------|-----|-----|
| 1 | Snapshot current tag/version state (this doc §1) | **AI-PREPARABLE** (read-only) | pure reads; the tables below were produced this way |
| 2 | Tag `nwp/nwc` **v0.5.0** to match composer.json | **OPERATOR** (credentialed push) | tag + push to origin needs the operator's key |
| 3 | Move the 11 `nwp/nwc` + 2 `nwp/nwp` `pre-*` anchors out-of-band | **OPERATOR-run, AI-PREPARED** (§2 gives exact commands) | local ref surgery on the operator's real clones — AI must not mutate them |
| 4 | Give `format_tabbed` a real `release` + tag its (future) repo | **OPERATOR** | versioning-policy call + credentialed tag; gated on ops#73 §A4 |
| 5 | Tag the two plugin repos at their reconciled `release` | **OPERATOR** (credentialed push + tag) | gated on ops#73 reconcile; `auth` half gated on F26 review |
| 6 | Cut GitLab **releases** on `nwp/nwc` + plugin repos | **OPERATOR** (GitLab UI/API) | release objects need the operator's GitLab session |
| 7 | Wire the CI consistency checks | **AI-PREPARABLE** (script/CI yaml, held for review) | pure bash; folds into ops#54 minimal CI |

**AI may prepare** everything marked AI-PREPARABLE. **Nothing here writes to a
live/prod site or server** — the only writes are git tags/refs/releases on the
GitLab code-distribution tier, all operator-run.

---

## 1. Snapshot — verified state (read-only, 2026-07-10)

`nwp/nwc` profile repo (`git@<gitlab-host>:nwp/nwc.git`,
`sites/nwc/dev/html/profiles/custom/nwc`):

- **On origin:** `v0.0.0-scaffold`, `v0.3.1`, `v0.4.0`, `nwc/v1.0.0`,
  `nwc/v1.0.0-mvp` (verified via `git ls-remote --tags origin`).
- **composer.json:** `version: 0.5.0` — **no matching tag anywhere.**
- **Local-only `pre-*` (11, none on origin):**
  `pre-guild-seed-2026-07-09`, `pre-narrative-behat-2026-07-09`,
  `pre-p68-operational-2026-07-09`, `pre-p73a-2026-07-09`, `pre-p73b-2026-07-09`,
  `pre-pedagogy-settings-2026-07-09`, `pre-wave2a-2026-07-09`,
  `pre-wave2b-2026-07-09`, `pre-wave4-help-2026-07-09`,
  `pre-wave5-integrate-2026-07-09`, `pre-wave5b-2026-07-09`.

`nwp/nwp` tool repo (this repo):

- **Durable:** `v0.30.0`.
- **Clutter to move/retire:** `pre-f26-2026-07-09`, `pre-f26-recs-2026-07-09`
  (rollback anchors), plus `archive-pre-restart-v0.30.0` and
  `cleanup-backup-2026-07-10-local-main` (session bookmarks — same class).

Plugin repos & `format_tabbed`: see ops#73 §0 (copyright-sync `0.2.0` on ssc/ssd
vs `0.1.0` in repo; `auth_nwc_oauth2` 3-way disagreement, F26-gated;
`format_tabbed` has **no `$plugin->release` line at all**).

> **Before running any step below, re-verify on the build host** — the
> authoritative plugin trees live there, not the dev workstation. If the
> build-host `git ls-remote` differs from §1, trust the build host and re-derive.

---

## 2. Move the `pre-*` rollback anchors out-of-band  *(AI-PREPARED, OPERATOR-run)*

D3: rollback anchors are out-of-band — "never pushed to origin, or namespaced
`rollback/*` so `git tag -l 'v*'` stays clean." Because the anchors are
**local-only** (§1), this is a **purely local** operation: no force-push, no
origin rewrite, nothing leaves the operator's machine.

**Chosen approach: move them to a `refs/rollback/` namespace.** This is stronger
than a `rollback/*` tag: refs outside `refs/tags/` do **not** appear in
`git tag -l` *at all* (so `git tag -l` is fully clean, not just `git tag -l
'v*'`), are **never** pushed by `git push --tags`, and the anchored commits stay
fully reachable/recoverable. List them with `git for-each-ref refs/rollback/`.

### 2.1 `nwp/nwc` — move all 11 (run in the profile repo)

```bash
cd sites/nwc/dev/html/profiles/custom/nwc   # or the build-host clone
for t in pre-guild-seed-2026-07-09 pre-narrative-behat-2026-07-09 \
         pre-p68-operational-2026-07-09 pre-p73a-2026-07-09 pre-p73b-2026-07-09 \
         pre-pedagogy-settings-2026-07-09 pre-wave2a-2026-07-09 \
         pre-wave2b-2026-07-09 pre-wave4-help-2026-07-09 \
         pre-wave5-integrate-2026-07-09 pre-wave5b-2026-07-09; do
  git rev-parse -q --verify "refs/tags/$t" >/dev/null || { echo "skip $t (absent)"; continue; }
  git update-ref "refs/rollback/$t" "refs/tags/$t^{commit}"   # preserve the commit
  git tag -d "$t"                                             # remove from refs/tags
  echo "moved $t -> refs/rollback/$t"
done
git tag -l 'pre-*'    # expect: empty
git tag -l 'v*'       # expect: v0.0.0-scaffold v0.3.1 v0.4.0 (+ v0.5.0 after §3)
git for-each-ref refs/rollback/   # the anchors, preserved out-of-band
```

### 2.2 `nwp/nwp` — move the 2 `pre-*` (+ optionally the two session bookmarks)

```bash
cd <nwp-repo-root>
for t in pre-f26-2026-07-09 pre-f26-recs-2026-07-09 \
         archive-pre-restart-v0.30.0 cleanup-backup-2026-07-10-local-main; do
  git rev-parse -q --verify "refs/tags/$t" >/dev/null || { echo "skip $t"; continue; }
  git update-ref "refs/rollback/$t" "refs/tags/$t^{commit}"
  git tag -d "$t"
  echo "moved $t -> refs/rollback/$t"
done
git tag -l   # expect: only v0.30.0 (+ future v-tags)
```

*(Keep `archive-pre-restart-v0.30.0` / `cleanup-backup-*` as tags if you prefer —
they are not `pre-*` and do not fail Check B; moving them just makes `git tag -l`
a pure release line. Operator's call.)*

### 2.3 Never re-introduce the clutter — two guards (AI-PREPARABLE)

1. **Never `git push --tags`.** Push named tags only: `git push origin v0.5.0`.
   `refs/rollback/*` is never pushed by a named or `--tags` push.
2. Optional belt-and-braces `pre-push` hook rejecting `refs/tags/pre-*`:

```bash
# .git/hooks/pre-push  (chmod +x) — refuse to push a pre-*/rollback tag
while read -r localref localsha remoteref remotesha; do
  case "$remoteref" in
    refs/tags/pre-*|refs/tags/rollback/*|refs/rollback/*)
      echo "pre-push: refusing to push rollback anchor $remoteref" >&2; exit 1 ;;
  esac
done
exit 0
```

Future rollback anchors created by session tooling should be written straight to
`refs/rollback/<name>` (`git update-ref`) instead of `git tag pre-...`, so they
never enter `refs/tags` in the first place.

---

## 3. Tag `nwp/nwc` v0.5.0  *(OPERATOR — credentialed push)*

composer.json already declares `0.5.0`; the tag is missing. D3: "tag v0.5.0 now
to match composer.json; composer version and tag may never diverge again."

```bash
cd sites/nwc/dev/html/profiles/custom/nwc   # or the build-host clone
git fetch origin
# Confirm the version and that no tag exists yet:
grep -E '"version"' composer.json           # expect: "version": "0.5.0"
git tag -l v0.5.0                            # expect: empty
# Tag the intended release commit (HEAD of the merged 0.5.0 line):
git tag -a v0.5.0 -m "nwc v0.5.0 — matches composer.json (ADR-0031 D3; single vX.Y.Z scheme)"
git push origin v0.5.0
git tag -l 'v*'                              # expect a clean semver line ending at v0.5.0
```

Do **not** cut a `nwc/v*` tag — that scheme is retired (§ scheme doc 1).
`nwc/v1.0.0*` stay as frozen historical tags.

---

## 4. `format_tabbed` — give it a real release  *(OPERATOR; gated on ops#73 §A4)*

`format_tabbed/version.php` has `$plugin->version = 2026030900` and **no
`$plugin->release`**. Assign one so it stops being the empty-release failure case:

```php
// in course/format/tabbed/version.php, alongside $plugin->version:
$plugin->release = '0.1.0';
```

Then, once `format_tabbed` has its own repo (or is vendored under the
`courses-plugins` source_repo per ops#73 §A6), tag `v0.1.0`. Until it has a repo,
the manifest `tag: v0.1.0` + `release: 0.1.0` is the record; `verify_plugins.sh`
(ops#73 §5.4) enforces `release` non-empty. This is ops#73 TODO-A4 — a versioning
call this scheme now makes concrete: **`0.1.0`**.

---

## 5. Tag the plugin repos  *(OPERATOR — credentialed push + tag; gated on ops#73)*

Only after the ops#73 reconcile settles the winning `release` per plugin:

- **`nwp/local-nwc-copyright-sync`** → reconciled `0.2.0` (ssc/ssd newest-wins):
  ```bash
  git tag -a v0.2.0 -m "local_nwc_copyright_sync 0.2.0 (== \$plugin->release; ADR-0031 D3)"
  git push origin v0.2.0
  ```
  **security_critical** (copyright/consent rail) — two-person review before the
  tag (CLAUDE.md; ops#73 §A2).
- **`nwp/auth-nwc-oauth2`** → **F26-review-gated.** Leave untagged / `optional:
  true` until the human auth review passes; then tag `vX.Y.Z` to match the
  confirmed `$plugin->release` (ops#73 §A1 resolves which of 1.0.0/1.1.0 is
  correct).
- **`nwp/local-feedback`** (once it has a repo) → `v0.1.0` (identical everywhere).

Every plugin tag equals `v` + its `$plugin->release`. `$plugin->version`
(`YYYYMMDDXX`) is never tagged.

---

## 6. GitLab releases  *(OPERATOR — GitLab UI/API)*

D3: cut GitLab **release** objects (not just tags) so "what pairs with what" is
answerable from the UI. At minimum, satisfy the ops#74 acceptance ("at least one
GitLab release on nwp/nwc"):

```bash
# via glab (or the Releases UI): release named for the tag, notes name the pair
glab release create v0.5.0 \
  --repo nwp/nwc \
  --name "nwc v0.5.0" \
  --notes "First release under the single vX.Y.Z scheme (ADR-0031 D3).
Pairs with: (pair contract TBD — ops#75). Retires the nwc/v* scheme.
Rollback anchors moved to refs/rollback/ (out-of-band)."
```

Cut releases at **pair-contract bumps** going forward (ADR-0031 D2/D3): the
release notes name the counterpart minimums (e.g. "nwc 0.6.0 requires
`auth_nwc_oauth2` ≥ 1.1.0"), which is what makes the pairing answerable from
GitLab. Plugin-repo releases follow the same pattern at their tags.

---

## 7. Wire the CI consistency checks  *(AI-PREPARABLE; fold into ops#54)*

Per scheme doc §4 (Check A + Check B). Two mechanizations, both held-for-review:

1. **`pl tag-hygiene`** (this branch, §ops74 scheme 5 / helper below) in the
   release checklist + nightly audit — the "documented equivalent gate" for the
   acceptance criterion if GitLab CI can't block-a-merge-that-tags directly.
2. **nwc CI job** (fold into ops#54 minimal CI): fail the pipeline when
   `composer.json` `version` changes on an MR without the release/tag discipline
   (the job asserts `git tag -l "v$(jq -r .version composer.json)"` is non-empty
   on the release commit, and `git tag -l 'pre-*'` is empty).
3. **plugin-repo check:** `verify_plugins.sh --release-tag` (ops#73 §5.4) —
   `$plugin->release` non-empty semver and `== tag` minus `v`.

---

## 8. Acceptance mapping (ops#74)

| Acceptance item | Runbook step | Who |
|---|---|---|
| `git tag -l 'v*'` on nwc clean, ending at v0.5.0, pushed | §3 (+§2 removes clutter) | OPERATOR |
| both plugin repos have a v-tag == current `$plugin->release` | §5 (gated on ops#73; auth on F26) | OPERATOR |
| no `pre-*` tags on any origin | §2 (already local-only; move to `refs/rollback/`) | OPERATOR-run, AI-prepared |
| CI fails an untagged version/`release` bump (or documented equivalent) | §7 (`pl tag-hygiene` + ops#54 job) | AI-PREPARABLE |
| ≥1 GitLab release on nwc | §6 | OPERATOR |

---

## 9. Operator TODO summary

| ID | What | Why AI couldn't do it |
|----|------|-----------------------|
| **B1** | Tag `nwp/nwc` **v0.5.0** + push | credentialed push; AI-run host holds no push key here |
| **B2** | Run the §2 `refs/rollback/` moves on the real nwc + nwp clones | local ref surgery on the operator's repos — AI must not mutate real repos |
| **B3** | Assign `format_tabbed` `release = 0.1.0` + tag when it has a repo | versioning-policy call + credentialed tag (ops#73 §A4) |
| **B4** | Tag `nwp/local-nwc-copyright-sync` **v0.2.0** after 2-person review | security_critical + credentialed tag (ops#73 §A2) |
| **B5** | Tag `nwp/auth-nwc-oauth2` — **only after F26 auth review** | auth code, F26-review-gated (ops#73 §A1) |
| **B6** | Cut GitLab release(s) on nwc (+ plugin repos at contract bumps) | needs the operator's GitLab session |
| **B7** | Fold the nwc composer-version↔tag CI job into ops#54 minimal CI | operator owns the CI pipeline config on the GitLab tier |
| **B8** | Re-verify §1 snapshot on the build host before acting | authoritative plugin trees live on the build host, not this workstation |
</content>
