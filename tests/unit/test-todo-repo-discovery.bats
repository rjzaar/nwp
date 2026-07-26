#!/usr/bin/env bats
# Item 2 (oversight-honesty): check_uncommitted_work must actually find the repos.
#
# Defect this locks down: `check_uncommitted_work` required `sites/<name>/.git`.
# NO site has that in the F17/F23 v2 layout — the git repos live one level
# deeper (sites/<name>/dev, sites/<name>/stg, the profile trees under
# html/profiles/custom/*, sites/<name>/backups, servers/<name>). So the loop
# `continue`d on every single site and reported clean while 1,000+ dirty entries
# sat in 20 nested repos. It also only iterated sites listed in nwp.yml, so a
# repo under servers/ was invisible by construction, and it never looked at
# `git stash list` — stashes are invisible to `git status`, unreachable after a
# gc, and destroyed by `git stash clear`. One held 179 lines of consent/legal
# canonical text for two months.
#
# NOTE ON PROVENANCE: item 2 originally shipped its own `lib/vcs-discovery.sh`
# for this. While item 2 was in flight, another agent landed `discover_repos` in
# lib/project-resolver.sh — a strictly better implementation (timeouts, per-stash
# items, worktree sprawl, site mapping, thresholds). The duplicate was deleted
# rather than kept; two discovery helpers over one tree is how they drift. These
# tests were repointed at the surviving implementation, so the behaviour stays
# pinned regardless of which file provides it.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  TMP="$BATS_TEST_TMPDIR/vcs"
  mkdir -p "$TMP"
  export TODO_CHECKS_PROJECT_ROOT="$TMP"
  export NWP_DIR="$TMP"
  cat > "$TMP/nwp.yml" <<'EOF'
settings:
  todo:
    categories: {}
    thresholds: {}
sites:
  demo:
    directory: SITEDIR
EOF
  sed -i "s|SITEDIR|$TMP/sites/demo|" "$TMP/nwp.yml"
  export TODO_CONFIG_FILE="$TMP/nwp.yml"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
}

_mkrepo() { # $1 = path
  mkdir -p "$1"
  git -C "$1" init -q -b main
  echo seed > "$1/seed.txt"
  git -C "$1" add -A && git -C "$1" commit -qm seed
}

_run_check() {
  bash -c '
    set +e
    source "'"$ROOT"'/lib/project-resolver.sh"
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    NWP_DIR="'"$TMP"'"
    todo_clear_items
    check_uncommitted_work
    printf "%s\n" "${TODO_ITEMS[@]:-}"
  '
}

@test "repo discovery finds nested repos in the v2 layout" {
  _mkrepo "$TMP/sites/demo/dev"
  _mkrepo "$TMP/sites/demo/dev/html/profiles/custom/demo"
  _mkrepo "$TMP/servers/box"
  run bash -c 'NWP_DIR="'"$TMP"'" bash -c '"'"'source "'"$ROOT"'/lib/project-resolver.sh"; discover_repos'"'"' | sort'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == *"sites/demo/dev"* ]]
  [[ "$output" == *"sites/demo/dev/html/profiles/custom/demo"* ]]
  [[ "$output" == *"servers/box"* ]]
}

@test "repo discovery excludes vendor/ and node_modules/" {
  _mkrepo "$TMP/sites/demo/dev"
  _mkrepo "$TMP/sites/demo/dev/vendor/thing"
  _mkrepo "$TMP/sites/demo/dev/node_modules/pkg"
  run bash -c 'NWP_DIR="'"$TMP"'" bash -c '"'"'source "'"$ROOT"'/lib/project-resolver.sh"; discover_repos'"'"''
  [ "$status" -eq 0 ]
  echo "$output"
  # Non-vacuity guard: the real repo MUST be found, or "no vendor/ in the output"
  # is true only because there is no output at all.
  [[ "$output" == *"sites/demo/dev"* ]]
  [[ "$output" != *"vendor/thing"* ]]
  [[ "$output" != *"node_modules/pkg"* ]]
}

@test "a dirty repo one level below sites/<name> is reported (v2 layout)" {
  _mkrepo "$TMP/sites/demo/dev"
  echo dirty > "$TMP/sites/demo/dev/changed.txt"
  run _run_check
  echo "$output"
  [[ "$output" == *'"category":"GWK"'* ]]
}

@test "untracked-only dirt is reported (git status -uall, not the default summary)" {
  _mkrepo "$TMP/sites/demo/dev"
  mkdir -p "$TMP/sites/demo/dev/newdir"
  echo x > "$TMP/sites/demo/dev/newdir/a.txt"
  echo y > "$TMP/sites/demo/dev/newdir/b.txt"
  run _run_check
  echo "$output"
  [[ "$output" == *'"category":"GWK"'* ]]
  # -uall means both files count, not one collapsed directory entry
  [[ "$output" == *"2 entr"* ]] || [[ "$output" == *"2 file"* ]]
}

@test "a repo with only a stash is reported — stashes are invisible to git status" {
  _mkrepo "$TMP/sites/demo/dev"
  echo secret-legal-text > "$TMP/sites/demo/dev/seed.txt"
  git -C "$TMP/sites/demo/dev" stash -q
  run _run_check
  echo "$output"
  [[ "$output" == *"tash"* ]]
}

@test "a repo under servers/ is discovered, not just sites/ listed in nwp.yml" {
  _mkrepo "$TMP/servers/box"
  echo dirty > "$TMP/servers/box/changed.txt"
  run _run_check
  echo "$output"
  [[ "$output" == *"servers/box"* ]] || [[ "$output" == *"servers-box"* ]]
}

@test "uncommitted work is not filed as 'low' priority" {
  _mkrepo "$TMP/sites/demo/dev"
  echo dirty > "$TMP/sites/demo/dev/changed.txt"
  run _run_check
  echo "$output"
  # Non-vacuity guard: there must BE an item before its priority means anything.
  [[ "$output" == *'"category":"GWK"'* ]]
  [[ "$output" != *'"priority":"low"'* ]]
}

@test "a clean tree produces no GWK item and no UNK item" {
  _mkrepo "$TMP/sites/demo/dev"
  run _run_check
  echo "$output"
  # Both halves matter: "no GWK" is only meaningful if the check actually ran.
  [[ "$output" != *'"category":"GWK"'* ]]
  [[ "$output" != *'"category":"UNK"'* ]]
}
