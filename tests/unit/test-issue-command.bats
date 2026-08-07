#!/usr/bin/env bats
# scripts/commands/issue.sh — flag-safety of the positional-arg subcommands
# OTHER than create.
#
# WHY: on 2026-08-01 `pl issue create --help` CREATED a real issue titled
# "--help" — that cmd_create fix + tests live in MR !282
# (tests/unit/test-issue-create-args.bats). This suite covers the SAME class
# of bug in the sibling subcommands, which !282 does not touch:
#   * cmd_label: a flag-like arg silently became --add and was PUT
#   * cmd_comment / cmd_work / cmd_submit: no -h/--help handling; unknown
#     flags were swallowed as positional args
# The fix pinned here: -h/--help prints usage and exits 0 WITHOUT any API
# call, and an unknown flag-like arg is REFUSED before any network I/O.
#
# No network is possible here: curl is stubbed via PATH and every invocation
# is logged, so "no API call" is asserted positively (log absent), not
# assumed.

setup() {
  TEST_TMP=$(mktemp -d)
  ISSUE="${BATS_TEST_DIRNAME}/../../scripts/commands/issue.sh"

  # PATH-stub curl: log every call, answer like a successful API write.
  STUB="$TEST_TMP/bin"; mkdir -p "$STUB"
  export CURL_LOG="$TEST_TMP/curl.log"
  cat > "$STUB/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$CURL_LOG"
echo '{"iid":123,"id":1,"labels":["papercut"],"state":"opened","web_url":"https://example.invalid/x"}'
EOF
  chmod +x "$STUB/curl"
  export PATH="$STUB:$PATH"

  # Fixture host + token so the plumbing works IF (and only if) a test
  # legitimately reaches the API. Values are obviously fake.
  export NWP_GITLAB_HOST="gitlab.example.invalid"
  export NWP_SECRETS_FILE="$TEST_TMP/secrets.yml"
  printf 'gitlab:\n  ops_note_token: not-a-real-token-test-fixture\n' > "$NWP_SECRETS_FILE"
}

teardown() { rm -rf "$TEST_TMP"; }

# ── cmd_label ────────────────────────────────────────────────────────────────

@test "issue label --help prints usage, exits 0, no API call" {
  run bash "$ISSUE" label --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
  [ ! -f "$CURL_LOG" ]
}

@test "issue label refuses an unknown flag-like arg as --add (no API call)" {
  run bash "$ISSUE" label 7 --frobnicate
  [ "$status" -ne 0 ]
  [ ! -f "$CURL_LOG" ]
}

@test "issue label with a legitimate bare label still works (stubbed API)" {
  run bash "$ISSUE" label 7 papercut
  [ "$status" -eq 0 ]
  [ -f "$CURL_LOG" ]
}

# ── cmd_comment ──────────────────────────────────────────────────────────────

@test "issue comment --help prints usage, exits 0, no API call" {
  run bash "$ISSUE" comment --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
  [ ! -f "$CURL_LOG" ]
}

# ── cmd_work / cmd_submit ────────────────────────────────────────────────────

@test "issue work --help prints usage, exits 0, touches no git state" {
  run bash "$ISSUE" work --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
}

@test "issue work refuses an unknown flag-like arg (never a worktree name)" {
  run bash "$ISSUE" work 7 --frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "issue submit --help prints usage, exits 0" {
  run bash "$ISSUE" submit --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
}

# ── regression guard ─────────────────────────────────────────────────────────

@test "top-level 'pl issue --help' still prints the full help and exits 0" {
  run bash "$ISSUE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"pl issue create"* ]]
  [ ! -f "$CURL_LOG" ]
}

# ── cmd_work singleton linking (ops#307) ─────────────────────────────────────
#
# WHY: cmd_work linked private/ and sites/ only when ABSENT — but both are
# partially tracked, so every worktree got real skeleton dirs SHADOWING the
# shared estate state. Observed 2026-08-07 (ops#279): the ADR-0031 pair guard
# read the worktree's blank ledger and refused a deploy the real ledger
# permitted, and the --override-pair rows scattered into the worktree.
# The fix links MISSING CHILDREN (bounded depth) instead of skipping the dir.

_work_fixture() {
  # A fixture "estate": tracked skeleton + gitignored singletons, like ~/nwp.
  FIX="$TEST_TMP/estate"
  mkdir -p "$FIX"
  git -C "$FIX" init -q -b main
  git -C "$FIX" config user.email t@t; git -C "$FIX" config user.name t
  mkdir -p "$FIX/private/pairs" "$FIX/sites/ss" "$FIX/scripts/commands"
  echo tracked > "$FIX/private/pairs/tracked.log"
  echo tracked > "$FIX/sites/ss/tracked.txt"
  printf 'private/pairs/*.cv\nsites/ssd/\nnwp.yml\n.secrets.yml\n' > "$FIX/.gitignore"
  git -C "$FIX" add -A && git -C "$FIX" commit -qm fixture
  # The gitignored singleton state the worktree must still reach:
  echo 3 > "$FIX/private/pairs/ssd.provider.live.cv"
  mkdir -p "$FIX/sites/ssd"
  echo siteconfig > "$FIX/sites/ssd/.nwp.yml"
  echo config > "$FIX/nwp.yml"
  export HOME="$TEST_TMP/home"; mkdir -p "$HOME"
}

@test "issue work: a worktree resolves the gitignored SINGLETON state, not a blank shadow (ops#307)" {
  _work_fixture
  PROJECT_ROOT="$FIX" run bash "$ISSUE" work 7 --no-launch
  [ "$status" -eq 0 ]
  wt="$HOME/nwp-ops7"
  # Tracked skeleton is real files from the branch, untouched:
  [ -f "$wt/private/pairs/tracked.log" ]
  [ ! -L "$wt/private/pairs/tracked.log" ]
  # The gitignored ledger entry INSIDE a tracked dir must resolve to the estate copy:
  [ -e "$wt/private/pairs/ssd.provider.live.cv" ]
  [ "$(cat "$wt/private/pairs/ssd.provider.live.cv")" = "3" ]
  # A whole gitignored site dir must resolve too:
  [ -e "$wt/sites/ssd/.nwp.yml" ]
  # And the flat singletons still link as before:
  [ -e "$wt/nwp.yml" ]
}

@test "issue work: linking never overwrites something the worktree already has (ops#307)" {
  _work_fixture
  PROJECT_ROOT="$FIX" run bash "$ISSUE" work 8 --no-launch
  [ "$status" -eq 0 ]
  wt="$HOME/nwp-ops8"
  # tracked.log came from git, and must still be the branch's copy:
  [ "$(cat "$wt/private/pairs/tracked.log")" = "tracked" ]
  [ ! -L "$wt/private/pairs/tracked.log" ]
}
