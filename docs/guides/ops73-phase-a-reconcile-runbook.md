# Moodle plugin reconcile runbook — NWP-ADR-0031 Phase A (ops#73)

> **Status: READY TO RUN once the operator confirms the drift resolutions.**
> Every step below is either **AI-PREPARABLE** (a script/edit an assistant on the
> build host can prepare, operator runs) or **OPERATOR** (a human decision, a
> credentialed push, or a live-tree read the AI-accessible host cannot safely do).
> Nothing here is wired by the Phase-A planning branch — this runbook *is* the
> execution plan the branch delivers. **Date:** 2026-07-10.
> **Audience:** the operator, on the **build host** (where the Moodle plugin
> source trees for ss/ssc/ssd live — see project memory: "Moodle/Drupal plugin
> trees belong on the build host, not the dev workstation"). Resolve `build-host`
> to your concrete box with `pl host build` (bare hostnames never appear in-repo).
> **Companion (the *why* + schemas):**
> [`ops73-moodle-plugin-manifest-design.md`](ops73-moodle-plugin-manifest-design.md).
> **ADR:** [NWP-ADR-0031](../decisions/0031-paired-site-versioning-and-promotion.md) D4.

---

## 0. What's AI-preparable vs. what needs your hands

| # | Step | Who | Why |
|---|------|-----|-----|
| 1 | Snapshot current drift (read every tree's `version.php`) | **AI-PREPARABLE** (read-only) | pure reads; the drift table is already in the design doc |
| 2 | **Decide the winning version per drifted plugin** | **OPERATOR** | newest-wins needs a human to confirm which tree/branch is authoritative (A1) |
| 3 | Reconcile the winning source into `courses_v3` + bump `manifest.yaml` to v2 | **AI-PREPARABLE** (edits, you review) | file edits in a repo the build host holds |
| 4 | Give `courses_v3` plugins a git remote (subtree split) | **OPERATOR** (push needs credentials) | A6 — a push to GitLab with your token |
| 5 | Reconcile drift into the GitLab plugin repos + **tag** them | **OPERATOR** (credentialed push + tag) | A3 — tags/releases are the versioned boundary (D3) |
| 6 | Register `ssc`/`ssd` in `nwp.yml` (+ `example.nwp.yml` template) | **OPERATOR** (`nwp.yml` is never committed) | A5 — resolve the `ssc`/`ssc1` naming |
| 7 | Wire the installer lockfile + `--against-lock` verify | **AI-PREPARABLE** (bash/python) | §5 of the design doc; no live write |
| 8 | Emit lockfiles for ss/ssc/ssd + commit into each tree | **OPERATOR-SUPERVISED** | writes into the site clones; first run supervised |

**AI may prepare** everything marked AI-PREPARABLE *on the build host only*.
**Nothing in this runbook writes to a live/prod Moodle site or a server** — the
site trees touched are the build-host working copies; live promotion is ops D,
out of scope.

---

## 1. Snapshot the drift  *(AI-PREPARABLE, read-only)*

On the build host, from each tree's Moodle root:

```bash
for base in <ss-root> <ssc-root> <ssd-root>; do
  for p in auth/nwc_oauth2 local/nwc_copyright_sync local/feedback \
           mod/depthcontent blocks/dailyreview course/format/tabbed local/browse; do
    f="$base/$p/version.php"
    [[ -f "$f" ]] && printf '%-12s %-26s %s\n' "$base" "$p" \
      "$(grep -hoE '\$plugin->(version|release)[^;]+' "$f" | tr '\n' ' ')"
  done
done
```

Compare against `~/dir/courses_v3/plugins/manifest.yaml`. The expected result is
the drift table in the design doc §0 (copyright_sync `0.2.0` on ssc/ssd vs
`0.1.0` in canon/repo/ss; `auth_nwc_oauth2` canon-only with a self-inconsistent
version; legacy `avc_*` on ss). **If your build-host trees differ from that
table, the dev-workstation read is stale — trust the build host and re-derive.**

---

## 2. Decide the winners  *(OPERATOR — the load-bearing human step)*

For each drifted plugin, pick the authoritative source. NWP-ADR-0031 D4 rule: **"the
newest tree state wins where it is the newest."**

- [ ] **`local_nwc_copyright_sync`** → ssc/ssd `0.2.0` / `2026052000` wins over
      canon/repo/ss `0.1.0`. **⚠ security_critical (copyright/consent rail):**
      diff `0.2.0` vs `0.1.0` and confirm the delta is legitimate before it
      becomes canon (CLAUDE.md sensitive path — two-person review). **[TODO-A2]**
- [ ] **`auth_nwc_oauth2`** → three candidate versions disagree: `manifest.yaml`
      (`1.0.0`/`2026011300`), `plugins/README.md` (`1.1.0`/`2026052000`), and the
      F26 build staged in `nwp/nwp!49`. **Confirm which is newest and correct.**
      This is **auth code + F26-review-gated** — do not tag/deploy until the F26
      human auth review passes (NWP-ADR-0031 ops C auth-half). **[TODO-A1]**
- [ ] **`local_feedback`** → identical (`0.1.0`/`2026051704`) everywhere; no
      reconcile, just pin a `v0.1.0` tag.
- [ ] **ss-only catalog plugins** (`mod_depthcontent`, `block_dailyreview`,
      `format_tabbed`, `local_browse`) → canon == ss; only `format_tabbed` needs
      a non-empty `release` assigned (it is empty today). **[TODO-A4]**
- [ ] **legacy `avc_*` + `local_courses_v3` on ss** → decide keep-frozen vs
      remove; out of the paired-site scope, flag-only. **[TODO-A7]**

---

## 3. Reconcile winners into `courses_v3` + bump manifest to v2  *(AI-PREPARABLE, you review)*

For each plugin where a site tree won (only `local_nwc_copyright_sync` today):

```bash
# copy the winning tree state over the canonical build source
cp -a <ssc-root>/local/nwc_copyright_sync/. ~/dir/courses_v3/plugins/local/nwc_copyright_sync/
# then update manifest.yaml: version 2026051700 -> 2026052000, release 0.1.0 -> 0.2.0
```

- [ ] Edit `~/dir/courses_v3/plugins/manifest.yaml` to **schema_version: 2** and
      add the new per-plugin fields (`repo`, `tag`, `sites`, `security_critical`)
      per design doc §2. Assign `format_tabbed` a real `release` (e.g. `0.1.0`).
- [ ] Reconcile the `plugins/README.md` inventory table so it stops disagreeing
      with `manifest.yaml` (the `auth_nwc_oauth2` mismatch). **[TODO-A1]**
- [ ] Run `~/dir/courses_v3/build/verify_plugins.sh` — it must pass (manifest
      version == source `version.php`). This is the existing check; extend it
      with the `release`⇔`tag` rule (design §5.4) as part of step 7.

---

## 4. Give `courses_v3` plugins a git remote  *(OPERATOR — credentialed push)*

NWP-ADR-0031 D4: "`~/dir/courses_v3` gets a git remote (subtree split; single-disk
canon is unacceptable)." Today `~/dir` is a git repo with **no remote**.

- [ ] Create the GitLab project (e.g. `nwp/courses-plugins`). **[TODO-A6]**
- [ ] `git subtree split --prefix=courses_v3/plugins -b plugins-export` in
      `~/dir`, push `plugins-export` to the new repo's `main`.
- [ ] Set `source_repo:` in `manifest.yaml` to the new repo URL.

*(A push with your GitLab credentials — cannot be delegated to an AI-run host.)*

---

## 5. Reconcile + tag the GitLab plugin repos  *(OPERATOR — credentialed push + tags)*

The two existing repos (`nwp/auth-nwc-oauth2`, `nwp/local-nwc-copyright-sync`)
were pushed once (2026-05-19) and have drifted. D3: **tag `vX.Y.Z` matching
`$plugin->release`; bumping `release` without tagging is the failure mode.**

- [ ] **`nwp/local-nwc-copyright-sync`:** push the reconciled `0.2.0` tree,
      `git tag -a v0.2.0`, push the tag, cut a **GitLab release** `v0.2.0`
      (D3: releases answer "what pairs with what"). **[TODO-A3]** — security_critical.
- [ ] **`nwp/auth-nwc-oauth2`:** **gated on F26 auth review.** Once passed, push
      the confirmed version, `git tag -a vX.Y.Z` to match `$plugin->release`,
      push, cut the release. Until then, leave `optional: true` and untagged.
      **[TODO-A1 + F26 gate]**
- [ ] **`pre-*` rollback tags** anywhere near these repos: keep out-of-band —
      never push, or namespace `rollback/*` so `git tag -l 'v*'` stays clean (D3).

---

## 6. Register `ssc`/`ssd`  *(OPERATOR — `nwp.yml` is never committed)*

Per design doc §4. `nwp.yml` currently registers `ss`, `ssd`, and a
name-mismatched **`ssc1`** (directory is `sites/ssc`).

- [ ] **Resolve `ssc` vs `ssc1`** (rename dir or register key `ssc`); reconcile
      the stray `ssc1` / `ssc1_moodledata`. **[TODO-A5]**
- [ ] Add the `ssc`/`ssd` stanzas (design §4) to `nwp.yml`; mirror the template
      in `example.nwp.yml` (the committable one). Set `project.type: moodle`,
      `paired_with`, and `canonical:` (ssc `live` per D6, ssd `dev`).
- [ ] Confirm `pl rag` / guards now see ssc (it should stop "evaluating invisible
      defaults"). Assign P67 maturity classes.

---

## 7. Wire the installer lockfile + verify  *(AI-PREPARABLE, no live write)*

Design doc §5. On the build host, in the `courses_v3`/`courses-plugins` repo:

- [ ] Extend `build/install_plugins.sh`: `--site <key>` selection; emit
      `<target>/.nwp-plugins.lock.yml` (schema §3) after a successful copy pass.
- [ ] Extend `build/verify_plugins.sh`: `--against-lock <root>` drift mode +
      `release`⇔`tag` semver check (the ops B CI check).
- [ ] `bash -n` both scripts; dry-run `install_plugins.sh --dry-run` against a
      throwaway Moodle root (never `sites/tmp/` — CLAUDE.md).
- [ ] (Future / ops D) `pl moodle plugins install|verify <site>` wrapper so this
      is `pl`-managed rather than a loose script. Flagged, not built in Phase A.

---

## 8. Emit + commit lockfiles  *(OPERATOR-SUPERVISED — writes into site clones)*

- [ ] Run the extended installer against each **build-host** tree (ss, ssc, ssd)
      to generate `.nwp-plugins.lock.yml`; commit each into its site clone.
- [ ] Verify with `verify_plugins.sh --against-lock <root>` — clean exit.
- [ ] **Do NOT run against a live/prod tree** — live promotion is ops D
      (type-dispatch + Moodle sanitizer + `moodledata`), out of scope here.

---

## Operator TODO summary (everywhere AI lacked build-host / live / credentialed access)

| ID | What | Why AI couldn't do it |
|----|------|-----------------------|
| **A1** | Confirm the newest/correct `auth_nwc_oauth2` version (manifest `1.0.0` vs README `1.1.0` vs `nwp!49`) and reconcile README↔manifest | 3-way disagreement; **auth code**, F26-review-gated |
| **A2** | Two-person diff-review of `local_nwc_copyright_sync` `0.1.0`→`0.2.0` before it becomes canon | security_critical (consent/copyright rail) — CLAUDE.md |
| **A3** | Push reconciled trees + **tag `vX.Y.Z`** + cut GitLab releases on the plugin repos | credentialed push/tag; AI-run host has no prod-reaching keys |
| **A4** | Assign `format_tabbed` a non-empty `release` (empty today — the D3 failure mode) | trivial edit, but a versioning policy call |
| **A5** | Resolve `ssc` vs `ssc1` naming; register `ssc`/`ssd` in `nwp.yml` | `nwp.yml` is never committed (CLAUDE.md); config-key vs dir-name decision |
| **A6** | Create `nwp/courses-plugins`, subtree-split `~/dir/courses_v3/plugins`, push (give canon a remote) | GitLab project create + credentialed push |
| **A7** | Decide keep-frozen vs remove for legacy `avc_*` + undeclared `local_courses_v3` on ss | ss-scope policy call; out of paired-site scope |
| **A8** | Verify the build-host trees match the dev-workstation drift snapshot (§1) | the authoritative trees are on the build host, not this workstation |

**Verified read-only from the dev workstation this session** (not the build
host): `~/dir/courses_v3/plugins/manifest.yaml` + installer/verify scripts; the
`ss/ssc/ssd` **dev** Moodle trees under `~/nwp/sites/` (each its own upstream
clone); `~/dir` git repo has **no remote**; `nwp.yml` registers `ss`/`ssd`/`ssc1`.
The **GitLab plugin repos and any live/stg ss/ssc/ssd trees were NOT inspected**
— those require build-host / credentialed access (A3, A8).
