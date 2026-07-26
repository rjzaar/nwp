#!/usr/bin/env bats
# vcs-truth (fix programme item 8) — a git bundle must be able to REBUILD the
# thing it claims to preserve.
#
# WHY THIS SUITE EXISTS
# ---------------------
# Two "snapshot" bundles were committed to docs/reports/ as the durable,
# offline-safe copy of Art.9 consent work. Both are BRICKS: they are *thin*
# bundles, so `git bundle verify` fails outside the one working copy on this
# laptop that happens to hold their prerequisite objects.
#
#   $ git init -q scratch && git -C scratch bundle verify …/ssc-depthcontent-art9-20260726.bundle
#   error: Repository lacks these prerequisite commits:
#   error: 346025ce13dc2151c0a6d084c1b24c19b713aa91
#
#   $ git -C scratch bundle verify …/ssc-118-artifact/ops-118-moodle-art9-gate.bundle
#   error: Repository lacks these prerequisite commits:
#   error: 67c80957df19d4d908e4927fb1c40db02fe40dd2
#
# The decision log called that snapshot "triply safe". It is singly safe, and
# the one copy is the laptop. Nothing in the tree ever checked.
#
# The gate below is behavioural: every assertion runs a real `git bundle` in a
# PRISTINE scratch repository with no object store, so a bundle can only pass
# by actually carrying its objects (or by declaring, completely, where the
# missing ones come from).

setup() {
  TEST_TMP=$(mktemp -d)
  REPO="${BATS_TEST_DIRNAME}/../.."
  SNAP="$REPO/scripts/commands/snapshot.sh"

  # A source repo with two commits, to bundle.
  SRC="$TEST_TMP/src"
  mkdir -p "$SRC"
  git -C "$SRC" init -q -b main
  git -C "$SRC" config user.email t@t
  git -C "$SRC" config user.name t
  echo one > "$SRC/a.txt"; git -C "$SRC" add -A; git -C "$SRC" commit -q -m one
  BASE_SHA=$(git -C "$SRC" rev-parse HEAD)
  echo two > "$SRC/b.txt"; git -C "$SRC" add -A; git -C "$SRC" commit -q -m two
  TIP_SHA=$(git -C "$SRC" rev-parse HEAD)

  # A tree that stands in for the nwp repo, for the audit tests.
  TREE="$TEST_TMP/tree"
  mkdir -p "$TREE/docs/reports"
  git -C "$TREE" init -q -b main
  git -C "$TREE" config user.email t@t
  git -C "$TREE" config user.name t
}

teardown() { rm -rf "$TEST_TMP"; }

# Build a deliberately BRICK bundle: thin, missing its prerequisite.
_make_brick() {
  local out="$1"
  git -C "$SRC" bundle create -q "$out" "${BASE_SHA}..main" 2>/dev/null
}

# The ground truth this whole suite is about: does the bundle rebuild in a
# repository that has never seen the source?
_verifies_standalone() {
  local bundle="$1" scratch
  scratch="$(mktemp -d)"
  git init -q "$scratch"
  local rc=0
  git -C "$scratch" bundle verify "$bundle" >/dev/null 2>&1 || rc=1
  rm -rf "$scratch"
  return $rc
}

################################################################################
# The fixture itself must be honest: prove the brick really is a brick, and the
# full bundle really is standalone, using plain git. If these two go wrong every
# assertion below is meaningless.
################################################################################

@test "fixture: a thin bundle does NOT verify standalone; a full one does" {
  _make_brick "$TEST_TMP/brick.bundle"
  run _verifies_standalone "$TEST_TMP/brick.bundle"
  [ "$status" -ne 0 ]

  git -C "$SRC" bundle create -q "$TEST_TMP/full.bundle" --all
  run _verifies_standalone "$TEST_TMP/full.bundle"
  [ "$status" -eq 0 ]
}

################################################################################
# pl snapshot bundle — cannot produce a brick
################################################################################

@test "snapshot bundle: writes a standalone bundle plus a checksum sidecar" {
  run "$SNAP" bundle "$SRC" --out="$TEST_TMP/out.bundle"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/out.bundle" ]
  [ -f "$TEST_TMP/out.bundle.sha256" ]
  _verifies_standalone "$TEST_TMP/out.bundle"
  ( cd "$TEST_TMP" && sha256sum -c out.bundle.sha256 >/dev/null )
}

@test "snapshot bundle: the produced bundle can actually be cloned from" {
  "$SNAP" bundle "$SRC" --out="$TEST_TMP/out.bundle"
  git clone -q "$TEST_TMP/out.bundle" "$TEST_TMP/clone"
  [ -f "$TEST_TMP/clone/b.txt" ]
}

@test "snapshot bundle: refuses --thin without a declared prerequisite source" {
  run "$SNAP" bundle "$SRC" --out="$TEST_TMP/thin.bundle" --thin --base="$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--prereq-source"* ]]
  # and it must not leave a half-made artifact lying around
  [ ! -f "$TEST_TMP/thin.bundle" ]
}

@test "snapshot bundle: --thin with a source writes a complete prerequisite manifest" {
  run "$SNAP" bundle "$SRC" --out="$TEST_TMP/thin.bundle" --thin --base="$BASE_SHA" \
      --prereq-source="https://example.org/src.git"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/thin.bundle.prereq.json" ]
  grep -q "$BASE_SHA" "$TEST_TMP/thin.bundle.prereq.json"
  grep -q "example.org/src.git" "$TEST_TMP/thin.bundle.prereq.json"
}

@test "snapshot bundle: a bundle that fails its own standalone check is deleted, not shipped" {
  # Force the self-check to fail after the pack is written.
  NWP_SNAPSHOT_FORCE_VERIFY_FAIL=1 run "$SNAP" bundle "$SRC" --out="$TEST_TMP/bad.bundle"
  [ "$status" -eq 1 ]
  [[ "$output" == *"discarded"* ]]
  [ ! -f "$TEST_TMP/bad.bundle" ]
}

################################################################################
# pl snapshot verify — the brick must be named as a brick
################################################################################

@test "snapshot verify: a brick fails and names the missing prerequisite" {
  _make_brick "$TEST_TMP/brick.bundle"
  run "$SNAP" verify "$TEST_TMP/brick.bundle"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$BASE_SHA"* ]]
}

@test "snapshot verify: a standalone bundle passes" {
  git -C "$SRC" bundle create -q "$TEST_TMP/full.bundle" --all
  run "$SNAP" verify "$TEST_TMP/full.bundle"
  [ "$status" -eq 0 ]
}

@test "snapshot verify: does not borrow objects from the current working repo" {
  # Run the verify from INSIDE the source repo — the exact accident that made
  # the real bricks look fine to whoever created them.
  _make_brick "$TEST_TMP/brick.bundle"
  cd "$SRC"
  run "$SNAP" verify "$TEST_TMP/brick.bundle"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT STANDALONE"* ]]
}

################################################################################
# pl snapshot audit — the repo-wide gate
################################################################################

@test "snapshot audit: fails on a committed brick with no prerequisite manifest" {
  _make_brick "$TREE/docs/reports/x.bundle"
  git -C "$TREE" add -A && git -C "$TREE" commit -q -m add
  run "$SNAP" audit --root="$TREE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"BRICK"* ]]
}

@test "snapshot audit: passes on a standalone committed bundle" {
  git -C "$SRC" bundle create -q "$TREE/docs/reports/x.bundle" --all
  git -C "$TREE" add -A && git -C "$TREE" commit -q -m add
  run "$SNAP" audit --root="$TREE"
  [ "$status" -eq 0 ]
}

@test "snapshot audit: a thin bundle passes only when EVERY prerequisite is declared" {
  _make_brick "$TREE/docs/reports/x.bundle"
  cat > "$TREE/docs/reports/x.bundle.prereq.json" <<EOF
{"standalone": false, "prerequisites": ["$BASE_SHA"], "source": "https://example.org/src.git"}
EOF
  git -C "$TREE" add -A && git -C "$TREE" commit -q -m add
  run "$SNAP" audit --root="$TREE"
  [ "$status" -eq 0 ]

  # Now blank the list: a manifest that declares nothing proves nothing.
  cat > "$TREE/docs/reports/x.bundle.prereq.json" <<'EOF'
{"standalone": false, "prerequisites": [], "source": "https://example.org/src.git"}
EOF
  run "$SNAP" audit --root="$TREE"
  [ "$status" -ne 0 ]
}

@test "snapshot audit: a prerequisite manifest with no source is not a manifest" {
  _make_brick "$TREE/docs/reports/x.bundle"
  cat > "$TREE/docs/reports/x.bundle.prereq.json" <<EOF
{"standalone": false, "prerequisites": ["$BASE_SHA"]}
EOF
  git -C "$TREE" add -A && git -C "$TREE" commit -q -m add
  run "$SNAP" audit --root="$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"source"* ]]
}

@test "snapshot audit: detects a corrupted checksum sidecar" {
  git -C "$SRC" bundle create -q "$TREE/docs/reports/x.bundle" --all
  ( cd "$TREE/docs/reports" && sha256sum x.bundle > x.bundle.sha256 )
  printf 'tamper' >> "$TREE/docs/reports/x.bundle"
  git -C "$TREE" add -A && git -C "$TREE" commit -q -m add
  run "$SNAP" audit --root="$TREE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHECKSUM"* ]]
}

@test "snapshot audit: a scan that found no bundles says so, and does not pass silently" {
  run "$SNAP" audit --root="$TREE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no bundle"* ]] || [[ "$output" == *"0 bundle"* ]]
}

################################################################################
# The live tree — this is the assertion that is RED on origin/main today.
################################################################################

@test "snapshot audit: every bundle committed to THIS repo can rebuild itself" {
  run "$SNAP" audit --root="$REPO"
  [ "$status" -eq 0 ]
}

@test "snapshot audit: and the gate over THIS repo can still go red" {
  # A pass over a tree that happens to contain no bundles proves nothing. Plant
  # a real brick in the real tree, prove the live gate fails, then remove it —
  # so this suite can never become the vacuous green it exists to prevent.
  local planted="$REPO/docs/reports/.vcs-truth-selftest-$$.bundle"
  _make_brick "$planted"
  run "$SNAP" audit --root="$REPO"
  rm -f "$planted"
  [ "$status" -ne 0 ]
  [[ "$output" == *"BRICK"* ]]
}

################################################################################
# PART 1b — the scratch-removal primitive `pl snapshot` deletes through
#
# `_scratch_verify` must destroy the throwaway repo it creates, which is a
# recursive delete, which is indistinguishable to any scanner from the real
# thing. Rather than exempt the file from the impact contract, the delete goes
# through `impact_rm_scratch` — one audited primitive in lib/impact.sh. A guard
# nobody has watched refuse is not a guard, so these are its refusal cases.
################################################################################

@test "impact_rm_scratch: removes a real scratch dir under the temp root" {
  source "${BATS_TEST_DIRNAME}/../../lib/impact.sh"
  local d; d="$(mktemp -d)"
  mkdir -p "$d/nested"; touch "$d/nested/file"
  run impact_rm_scratch "$d"
  [ "$status" -eq 0 ]
  [ ! -d "$d" ]
}

@test "impact_rm_scratch: REFUSES a path outside the temp root" {
  source "${BATS_TEST_DIRNAME}/../../lib/impact.sh"
  local d="$TEST_TMP/not-temp-shaped"
  # A directory inside the bats tmp tree is under /tmp, so build one that is not:
  d="$HOME/.nwp-impact-rm-scratch-probe-$$"
  mkdir -p "$d"
  run impact_rm_scratch "$d"
  local existed=1; [ -d "$d" ] || existed=0
  rmdir "$d" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [ "$existed" -eq 1 ]     # it must still have been there when the call returned
  [[ "$output" == *"refusing"* ]]
}

@test "impact_rm_scratch: REFUSES the temp root itself, and a relative path" {
  source "${BATS_TEST_DIRNAME}/../../lib/impact.sh"
  run impact_rm_scratch "/tmp"
  [ "$status" -ne 0 ]
  [ -d /tmp ]
  run impact_rm_scratch "relative/path"
  [ "$status" -ne 0 ]
  run impact_rm_scratch ""
  [ "$status" -ne 0 ]
}

@test "impact_rm_scratch: REFUSES a symlink pointing out of the temp root" {
  source "${BATS_TEST_DIRNAME}/../../lib/impact.sh"
  local target="$TEST_TMP/precious"; mkdir -p "$target"; touch "$target/keep"
  local link; link="$(mktemp -d)/link"
  ln -s "$target" "$link"
  run impact_rm_scratch "$link"
  [ "$status" -ne 0 ]
  [ -f "$target/keep" ]
}

@test "snapshot.sh contains no raw recursive delete of its own" {
  # The point of the primitive is that this file stops being a scanner target.
  run grep -nE '^[^#]*rm[[:space:]]+-rf' "$REPO/scripts/commands/snapshot.sh"
  [ "$status" -ne 0 ]
}

################################################################################
# PART 2 — work that exists ONLY on this machine
#
# `pl todo` grew check_unpushed_commits, but `pl doctor` — the command a coder
# runs on a new machine, and the one a cleanup session runs before pruning
# worktrees — never looked. `feat/nwptoolkit-deploy` (340 lines: lib/
# nwptoolkit-deploy.sh plus an nginx template) sat on NO remote in ANY repo for
# three weeks and no `pl` surface said so. `servers/nwpcode/.git` is a two-commit
# repository with no remote at all, and it is the only home of the fleet's backup
# producer and the GitLab CVE-response script.
#
# Both are the same defect: a repository can hold the only copy of something and
# nothing asks. These tests exercise the check end-to-end through doctor.sh's
# own main(), against a fixture tree, so a check that is written but never
# called cannot pass them.
################################################################################

_vcs_fixture() {   # → $VROOT, a tree of git repos
  VROOT="$TEST_TMP/vcs"; mkdir -p "$VROOT"
}

# <name> <remote:yes|no> <pushed:yes|no> <age-days>
# Each repo gets its OWN bare origin — sharing one would make the second push
# a non-fast-forward and silently build a different fixture than the one named.
_mk_repo() {
  local name="$1" remote="$2" pushed="$3" age="${4:-0}" d="$VROOT/$1"
  local when; when="$(date -u -d "-${age} days" +%Y-%m-%dT%H:%M:%S)"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  echo x > "$d/f.txt"; git -C "$d" add -A
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$d" commit -q -m seed
  if [ "$remote" = yes ]; then
    git init -q --bare "$TEST_TMP/${name}-origin.git"
    git -C "$d" remote add origin "$TEST_TMP/${name}-origin.git"
    git -C "$d" push -q origin main
    if [ "$pushed" = no ]; then
      echo y > "$d/g.txt"; git -C "$d" add -A
      GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$d" commit -q -m local-only
    fi
  fi
}

_doctor() { NWP_VCS_ROOT="$VROOT" run bash "$REPO/scripts/commands/doctor.sh" "$@"; }

@test "doctor: a branch whose commits are on no remote makes pl doctor fail" {
  _vcs_fixture
  _mk_repo pushed-repo   yes yes 0
  _mk_repo stranded-repo yes no  8
  _doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"stranded-repo"* ]]
}

@test "doctor: a repository with no remote at all is reported — it is the only copy" {
  _vcs_fixture
  _mk_repo orphan-repo no no 30
  _doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"orphan-repo"* ]]
  [[ "$output" == *"no remote"* ]]
}

@test "doctor: a fully pushed tree passes the VCS check, and SAYS it checked" {
  _vcs_fixture
  _mk_repo pushed-repo yes yes 0
  _doctor
  # Other doctor checks may legitimately fail on any given machine, so the
  # assertion is on the VCS section itself: it must run, and it must be green.
  [[ "$output" == *"Version control"* ]]
  [[ "$output" != *"only on this machine"* ]]
}

@test "doctor: recent unpushed work is not treated as stranded (no crying wolf)" {
  _vcs_fixture
  _mk_repo fresh-repo yes no 0
  _doctor
  # Assert the section RAN — otherwise "fresh-repo is absent from the output"
  # is satisfied by a check that does not exist, which is how this suite would
  # become the vacuous green it exists to prevent.
  [[ "$output" == *"Version control"* ]]
  [[ "$output" != *"fresh-repo"* ]]
}

################################################################################
# PART 3 — the tracker citing branches that do not exist
#
# `pl issue reconcile` DOCUMENTS three classes in its own header comment:
#   MERGED-BUT-OPEN · CLOSED-BUT-OPEN-MR · STALE-REF
# and computes two. STALE-REF — "the issue text names a branch that exists on no
# remote" — is never assigned to anything, so the command cannot emit it. That
# is the exact class ops#70 needs: its only note points at a branch and an MR
# that never existed, and a reader has no way to learn that except by trying.
#
# A documented-but-unreachable classification is worse than an absent one: a
# clean run reads as "checked, and none found".
################################################################################

_issue_env() {
  ISS="$REPO/scripts/commands/issue.sh"
  # A repo whose remote-tracking refs we control, standing in for nwp/nwp.
  IREPO="$TEST_TMP/irepo"; mkdir -p "$IREPO"
  git -C "$IREPO" init -q -b main
  git -C "$IREPO" config user.email t@t
  git -C "$IREPO" config user.name t
  echo a > "$IREPO/a"; git -C "$IREPO" add -A; git -C "$IREPO" commit -q -m first
  git -C "$IREPO" update-ref refs/remotes/origin/main HEAD
  git -C "$IREPO" update-ref refs/remotes/origin/feat/real-branch HEAD
}

@test "issue reconcile: extracts branch-shaped refs from prose and ignores issue refs" {
  _issue_env
  # shellcheck disable=SC1090
  source "$ISS"
  run _refs_in_text 'see ops#70 and branch ops-70-foo plus fix/moodle-deploy-x, not a/word here'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ops-70-foo"* ]]
  [[ "$output" == *"fix/moodle-deploy-x"* ]]
  [[ "$output" != *"ops#70"* ]]
}

@test "issue reconcile: a ref that exists on a remote is not stale" {
  _issue_env
  source "$ISS"
  run _ref_is_known "feat/real-branch" "$IREPO"
  [ "$status" -eq 0 ]
}

@test "issue reconcile: a ref that landed and was deleted is not stale" {
  _issue_env
  git -C "$IREPO" checkout -q -b feat/landed
  echo b > "$IREPO/b"; git -C "$IREPO" add -A; git -C "$IREPO" commit -q -m work
  git -C "$IREPO" checkout -q main
  git -C "$IREPO" merge -q --no-ff -m "Merge branch 'feat/landed' into 'main'" feat/landed
  git -C "$IREPO" branch -q -D feat/landed
  git -C "$IREPO" update-ref refs/remotes/origin/main HEAD
  source "$ISS"
  run _ref_is_known "feat/landed" "$IREPO"
  [ "$status" -eq 0 ]
}

@test "issue reconcile: a ref that exists nowhere IS stale" {
  _issue_env
  source "$ISS"
  run _ref_is_known "fix/never-existed" "$IREPO"
  # exactly 1, not 127: "the function is missing" must not read as "stale".
  [ "$status" -eq 1 ]
}

@test "issue reconcile: reports STALE-REF end to end" {
  _issue_env
  source "$ISS"
  # Stub the GitLab API: one open issue whose description cites a dead branch.
  _api_get() {
    case "$1" in
      *related_merge_requests) printf '%s' '[]' ;;
      */issues*) printf '%s' '[{"iid":70,"state":"opened","title":"a thing","description":"fixed on fix/never-existed"}]' ;;
      *) printf '%s' '[]' ;;
    esac
  }
  NWP_RECONCILE_REPOS="$IREPO" run cmd_reconcile
  [[ "$output" == *"STALE-REF"* ]]
  [[ "$output" == *"fix/never-existed"* ]]
}
