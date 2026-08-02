#!/usr/bin/env bats
# scripts/commands/issue.sh — the LIST must show everything it claims to.
#
# THREE MEASURED DEFECTS THIS SUITE PINS (all confirmed live 2026-08-02):
#
#   1. SILENT TRUNCATION. `cmd_ls` issued a single `per_page=100` GET. nwp/ops
#      had 136 open issues, so it printed 100 and said nothing. The sort was
#      `created_at asc`, so the 36 rows it dropped were the NEWEST — exactly
#      the ones an operator opens the list to triage. A cap is allowed; a
#      SILENT cap is a false claim of completeness.
#
#   2. A WHOLE TRACKER WAS INVISIBLE. Tester feedback synced out of nwd by
#      `drush nwc-feedback:sync-to-gitlab` lands in nwp/nwc (project 16), not
#      nwp/ops (21) — e.g. nwc#8 "[feedback-2] help topic should be clickable".
#      `pl issue` only ever addressed project 21, so the operator could not see
#      their own testers' reports. The agent-loop already polls BOTH
#      (AGENT_LOOP_PROJECT_IDS="16,21").
#
#   3. THE APPROVAL GATE WAS INERT AND SILENT. `agent-eligible` is what the
#      loop polls for, but `.loop-paused` has sat in the runtime tree since
#      2026-07-18. Labelling an issue therefore changed nothing, and no verb
#      said so.
#
# The fixture tracker is 136 issues on purpose: the real measured number, so a
# regression to "one page" fails here for the same reason it failed the
# operator.
#
# No network is possible: curl is PATH-stubbed and every call is logged, so
# "page 2 was requested" and "no write happened" are asserted positively.

setup() {
  TEST_TMP=$(mktemp -d)
  ISSUE="${BATS_TEST_DIRNAME}/../../scripts/commands/issue.sh"

  STUB="$TEST_TMP/bin"; mkdir -p "$STUB"
  export CURL_LOG="$TEST_TMP/curl.log"
  : > "$CURL_LOG"

  # A stub GitLab: project 21 = 136 open issues (the real count), project 16 =
  # the three real feedback issues. It paginates exactly as the API does, so a
  # caller that never asks for page 2 provably cannot see issue 101+.
  cat > "$STUB/curl" <<'STUBEOF'
#!/bin/bash
cfg=""; prev=""
for a in "$@"; do [ "$prev" = "-K" ] && cfg="$a"; prev="$a"; done
url=$(grep -m1 '^url = ' "$cfg" | sed 's/^url = "//; s/"$//')
method=$(grep -m1 '^request = ' "$cfg" | sed 's/^request = "//; s/"$//')
[ -n "$method" ] || method=GET
payload=""
dataf=$(grep -m1 '^data = "@' "$cfg" | sed 's/^data = "@//; s/"$//')
[ -n "$dataf" ] && [ -f "$dataf" ] && payload=$(tr -d '\n' < "$dataf")
echo "$method $url $payload" >> "$CURL_LOG"

emit_issue(){ # $1=iid $2=labels-json $3=title
  printf '{"id":%s,"iid":%s,"state":"opened","title":"%s","labels":%s,"author":{"username":"fixture"},"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-01T00:00:00Z","description":"d"}' \
    "$1" "$1" "$3" "$2"
}

case "$url" in
  */projects/16) echo '{"id":16,"path_with_namespace":"nwp/nwc"}'; exit 0 ;;
  */projects/21) echo '{"id":21,"path_with_namespace":"nwp/ops"}'; exit 0 ;;
  *related_merge_requests*) echo '[]'; exit 0 ;;
  */projects/99*) echo '{"message":"404 Project Not Found"}'; exit 0 ;;
esac

if [ "$method" != "GET" ]; then
  # a write: answer like GitLab does, echoing a plausible label set
  echo '{"id":1,"iid":1,"state":"opened","labels":["agent-eligible"]}'
  exit 0
fi

# NB: match "&page=" exactly — "per_page=100" also contains "page=", and a
# loose match here would make the stub answer page 100 to an unpaginated
# request, i.e. hide the very bug under test behind a fixture artefact.
page=1
case "$url" in *"&page="*) page="${url##*&page=}"; page="${page%%&*}" ;; esac

case "$url" in
  */projects/21/issues/*/notes*) echo '[]'; exit 0 ;;
  */projects/21/issues/*)
    # single-issue read: labels depend on the iid, same rule as the list
    iid="${url##*/issues/}"; iid="${iid%%\?*}"
    labels='[]'
    case "$iid" in 5|130) labels='["agent-eligible"]';; 7|136) labels='["needs-human"]';; esac
    emit_issue "$iid" "$labels" "fixture issue $iid"; exit 0 ;;
  */projects/16/issues/*/notes*) echo '[]'; exit 0 ;;
  */projects/16/issues/*)
    iid="${url##*/issues/}"; iid="${iid%%\?*}"
    emit_issue "$iid" '["demo-tester","feedback","needs-human","tier-3"]' "[feedback] fixture nwc $iid"
    exit 0 ;;
esac

case "$url" in
  */projects/21/issues\?*)
    total=${OPS_TOTAL:-136}
    start=$(( (page - 1) * 100 + 1 )); end=$(( page * 100 ))
    [ "$end" -gt "$total" ] && end=$total
    if [ "$start" -gt "$total" ]; then echo '[]'; exit 0; fi
    printf '['; sep=""
    for ((i = start; i <= end; i++)); do
      labels='[]'
      case "$i" in 5|130) labels='["agent-eligible"]';; 7|136) labels='["needs-human"]';; esac
      printf '%s' "$sep"; emit_issue "$i" "$labels" "fixture issue $i"; sep=","
    done
    printf ']'; exit 0 ;;
  */projects/16/issues\?*)
    if [ "$page" -gt 1 ]; then echo '[]'; exit 0; fi
    printf '['
    emit_issue 1 '["class-b1","demo-fixture","feedback","needs-human","tier-1"]' "[feedback-1] Typo on /about"
    printf ','
    emit_issue 4 '["demo-fixture","feedback","needs-human","tier-1"]' "[feedback-4] Typo demo amened"
    printf ','
    emit_issue 8 '["demo-tester","feedback","needs-human","tier-3"]' "[feedback-2] help topic should be clickable"
    printf ']'; exit 0 ;;
esac
echo '[]'
STUBEOF
  chmod +x "$STUB/curl"
  export PATH="$STUB:$PATH"

  export NWP_GITLAB_HOST="gitlab.example.invalid"
  export NWP_SECRETS_FILE="$TEST_TMP/secrets.yml"
  printf 'gitlab:\n  ops_note_token: not-a-real-token-test-fixture\n  api_token: not-a-real-token-test-fixture-2\n' \
    > "$NWP_SECRETS_FILE"

  # Loop state is host-local; pin BOTH inputs so these tests never read (or
  # depend on) the real ~/nwp sentinel.
  export NWP_ROOT="$TEST_TMP/fakeroot"; mkdir -p "$NWP_ROOT"
  export NWP_LOOP_STATE="$TEST_TMP/parts.state"
}

teardown() { rm -rf "$TEST_TMP"; }

################################################################################
# refute / refute_grep — a NEGATIVE assertion that actually fails the test.
#
# `! cmd` inside a bats test is a NO-OP unless it happens to be the last line.
# bash exempts a negated command from errexit ("the shell does not exit ... if
# the command's return value is being inverted with !"), and bats grades a test
# by the status of its final command. Measured 2026-08-03: with the row
# separator deliberately broken, `! printf '%s\n' "$output" | grep -qF '\t'`
# matched — and the test still reported `ok`.
#
# Every negative assertion in this file is one of "no write happened" or "the
# walled token was not used". Those are the assertions that make the positive
# ones mean anything, and they were the ones not running.
################################################################################
refute()       { if "$@"; then echo "refute: '$*' unexpectedly SUCCEEDED" >&2; return 1; fi; }
refute_grep()  { if printf '%s\n' "$output" | grep -qE "$1"; then echo "refute_grep: output matched /$1/" >&2; return 1; fi; }
refute_grepf() { if printf '%s\n' "$output" | grep -qF "$1"; then echo "refute_grepf: output contained '$1'" >&2; return 1; fi; }


pages_requested() { grep -c 'page=2' "$CURL_LOG" || true; }
rows_shown()      { grep -cE '^  (ops|nwc) ' <<<"$output" || true; }

# ── DEFECT 0: the row separator must be a TAB BYTE, on every yq ──────────────
#
# MEASURED 2026-08-03. Every `_api_rows` expression joined its fields with
# `join("\t")`. yq only began interpreting that escape after v4.44.1 — which is
# exactly what the CI runner has. On the runner every row came back as ONE field
# containing literal `\t`, so `IFS=$'\t' read -r src iid st title labels`
# assigned the whole row to `src` and left the rest empty. Twelve unit tests
# passed on a v4.50.1 workstation and failed on the v4.44.1 runner.
#
# "It works on my machine" is the same defect class as "the guard could not
# look": a claim whose truth depends on something the claim never states. So
# these two cases assert the BYTE, and the second one re-runs the real
# expression under the CI-pinned yq when this host has it cached.

@test "rows are separated by a real TAB byte — not a literal backslash-t" {
  run bash "$ISSUE" ls --project=ops --limit=3
  [ "$status" -eq 0 ]
  # No row may contain the two-character sequence backslash-t.
  refute_grepf '\t'
  # And the parse that consumes those rows must yield 5 fields, not 1.
  local n
  n=$(printf '%s' '[{"iid":7,"state":"opened","title":"t","labels":["a","b"]}]' \
      | "$(command -v yq)" e -p=json -r \
          ".[] | [(.iid|tostring), .state, .title, (.labels | join(\",\"))] | join(\"$(printf '\t')\")" - \
      | awk -F'\t' '{print NF}')
  [ "$n" -eq 4 ]
}

@test "PORTABILITY: the REAL verb still tabulates under the OLDEST yq available here" {
  # Runs `pl issue ls` itself — not a re-typed copy of its expression — with the
  # oldest yq this host can offer first on PATH. On the CI runner that is
  # v4.44.1, the version the bug needed. On a workstation it may be the only yq
  # there is, in which case this case still asserts the behaviour and NAMES the
  # version it checked, so the report cannot be read as broader than it is.
  #
  # Deliberately not a `skip`: the suite pins its skip count, and a case that
  # opts out on the machine where it matters is the failure mode this whole
  # block was written about.
  local dir yqbin="" c
  for c in "$HOME/.cache/nwp-ci"/yq-v4.44.1/yq "$HOME/.cache/nwp-ci"/yq-*/yq; do
    [ -x "$c" ] && { yqbin="$c"; break; }
  done
  if [ -n "$yqbin" ]; then dir=$(dirname "$yqbin"); else dir=""; yqbin=$(command -v yq); fi
  echo "# checked against: $("$yqbin" --version)" >&3

  PATH="${dir:+$dir:}$PATH" run bash "$ISSUE" ls --project=ops --limit=3
  [ "$status" -eq 0 ]
  refute_grepf '\t'      # no literal backslash-t leaked into a row
  [ "$(rows_shown)" -eq 3 ]                       # and the rows really parsed into columns
  [[ "$output" == *"fixture issue 1"* ]]
}

# ── DEFECT 1: silent truncation ──────────────────────────────────────────────

@test "ls renders ALL 136 open ops issues, not just the first page of 100" {
  run bash "$ISSUE" ls --project=ops
  [ "$status" -eq 0 ]
  [ "$(rows_shown)" -eq 136 ]
}

@test "ls actually requests page 2 (the truncation was a missing pagination loop)" {
  run bash "$ISSUE" ls --project=ops
  [ "$status" -eq 0 ]
  [ "$(pages_requested)" -ge 1 ]
}

@test "ls shows the NEWEST issues — #101 and #136 are on page 2 and must appear" {
  run bash "$ISSUE" ls --project=ops
  [[ "$output" == *"fixture issue 101"* ]]
  [[ "$output" == *"fixture issue 136"* ]]
}

@test "ls states the count it read, so the number is a checkable claim" {
  run bash "$ISSUE" ls --project=ops
  [[ "$output" == *"read 136 issue(s)"* ]]
  [[ "$output" == *"showing all 136 matching row(s)"* ]]
}

@test "an intentional cap SAYS it is a cap (--limit prints 'showing 10 of 136')" {
  run bash "$ISSUE" ls --project=ops --limit=10
  [ "$status" -eq 0 ]
  [ "$(rows_shown)" -eq 10 ]
  [[ "$output" == *"showing 10 of 136"* ]]
}

@test "board paginates too — it had the identical single-page bug" {
  run bash "$ISSUE" board
  [ "$status" -eq 0 ]
  [[ "$output" == *"fixture issue 136"* ]]
  [[ "$output" == *"136 open issue(s) read"* ]]
}

# ── DEFECT 2: the feedback tracker was unreachable ───────────────────────────

@test "ls reads BOTH trackers by default and marks the source of each row" {
  run bash "$ISSUE" ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"help topic should be clickable"* ]]
  [[ "$output" == *"ops "* ]]
  [[ "$output" == *"nwc "* ]]
  [ "$(rows_shown)" -eq 139 ]
}

@test "--project=nwc narrows to the tester-feedback tracker" {
  run bash "$ISSUE" ls --project=nwc
  [ "$status" -eq 0 ]
  [ "$(rows_shown)" -eq 3 ]
  [[ "$output" == *"help topic should be clickable"* ]]
}

@test "a tracker this token cannot read is REPORTED, never rendered as empty" {
  run bash "$ISSUE" ls --project=99
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read"* ]]
}

@test "show accepts the qualified ref that ls prints (nwc#8)" {
  run bash "$ISSUE" show nwc#8
  [ "$status" -eq 0 ]
  [[ "$output" == *"nwp/nwc#8"* ]]
  grep -q '/projects/16/issues/8' "$CURL_LOG"
}

@test "a bare number still means nwp/ops — no existing invocation changes meaning" {
  run bash "$ISSUE" show 5
  [ "$status" -eq 0 ]
  grep -q '/projects/21/issues/5' "$CURL_LOG"
}

# ── DEFECT 3: the approval gate was invisible and inert ──────────────────────

@test "ls marks the approval gate per row: approved / HUMAN / pending" {
  run bash "$ISSUE" ls --project=ops
  [[ "$output" =~ ops[[:space:]]+5[[:space:]]+opened[[:space:]]+approved ]]
  [[ "$output" =~ ops[[:space:]]+7[[:space:]]+opened[[:space:]]+HUMAN ]]
  [[ "$output" =~ ops[[:space:]]+9[[:space:]]+opened[[:space:]]+pending ]]
}

@test "the gate summary counts across ALL pages (issue 130 is on page 2)" {
  run bash "$ISSUE" ls --project=ops
  [[ "$output" == *"2 approved (agent-eligible)"* ]]
  [[ "$output" == *"2 needs-human"* ]]
  [[ "$output" == *"132 pending"* ]]
}

@test "--pending lists only what awaits the operator's decision" {
  run bash "$ISSUE" ls --project=ops --pending
  [ "$status" -eq 0 ]
  [ "$(rows_shown)" -eq 132 ]
  [[ "$output" != *"fixture issue 5 "* ]]
}

@test "--needs-human lists exactly the issues an agent must not take" {
  run bash "$ISSUE" ls --project=ops --needs-human
  [ "$(rows_shown)" -eq 2 ]
}

@test "ls tells the truth when the loop is paused and approvals exist" {
  touch "$NWP_ROOT/.loop-paused"
  run bash "$ISSUE" ls --project=ops
  [[ "$output" == *"agent loop is PAUSED"* ]]
  [[ "$output" == *"WILL NOT be acted on"* ]]
}

@test "ls does NOT claim the loop is paused when it is running" {
  run bash "$ISSUE" ls --project=ops
  [[ "$output" != *"agent loop is PAUSED"* ]]
}

@test "approve adds agent-eligible" {
  run bash "$ISSUE" approve 9
  [ "$status" -eq 0 ]
  grep -q 'PUT .*projects/21/issues/9 .*add_labels.*agent-eligible' "$CURL_LOG"
}

@test "approve REFUSES a needs-human issue and performs no write" {
  run bash "$ISSUE" approve 7
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs-human"* ]]
  [[ "$output" == *"refusing"* ]]
  refute grep -q '^PUT ' "$CURL_LOG"
}

@test "approve's refusal explains the remedy instead of just failing" {
  run bash "$ISSUE" approve 7
  [[ "$output" == *"--remove needs-human"* ]]
}

@test "approve on a paused loop still labels, but says the label is not acted on" {
  touch "$NWP_ROOT/.loop-paused"
  run bash "$ISSUE" approve 9
  [ "$status" -eq 0 ]
  grep -q 'PUT .*add_labels' "$CURL_LOG"
  [[ "$output" == *"agent loop is PAUSED"* ]]
  [[ "$output" == *"WILL NOT be acted on"* ]]
}

@test "the resume remedy names the ACTUAL cause — sentinel, not 'pl loop enable all'" {
  # `pl loop enable all` writes all=enabled and does NOT delete .loop-paused
  # (lib/loop-parts.sh:loop_part_set), so offering it here would be advice that
  # does nothing — the same defect class as the inert label itself.
  touch "$NWP_ROOT/.loop-paused"
  run bash "$ISSUE" approve 9
  [[ "$output" == *"rm $NWP_ROOT/.loop-paused"* ]]
  [[ "$output" != *"pl loop resume"* ]]
}

@test "a parts-state global kill gets the parts-state remedy" {
  printf 'all=disabled\n' > "$NWP_LOOP_STATE"
  run bash "$ISSUE" approve 9
  [[ "$output" == *"all=disabled"* ]]
  [[ "$output" == *"pl loop enable all"* ]]
}

@test "approve on a running loop does not warn about a pause" {
  run bash "$ISSUE" approve 9
  [ "$status" -eq 0 ]
  [[ "$output" != *"PAUSED"* ]]
}

@test "approve works on the feedback tracker by qualified ref" {
  run bash "$ISSUE" approve nwc#8
  # nwc#8 is needs-human in real life and in the fixture: it must be refused,
  # against project 16, not silently approved or 'not found'.
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs-human"* ]]
  grep -q '/projects/16/issues/8' "$CURL_LOG"
}

@test "labelling agent-eligible by hand tells the same truth as approve" {
  touch "$NWP_ROOT/.loop-paused"
  run bash "$ISSUE" label 9 --add agent-eligible
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent loop is PAUSED"* ]]
}

# ── regression guards ────────────────────────────────────────────────────────

@test "ls --help prints usage, exits 0, makes no API call" {
  run bash "$ISSUE" ls --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: pl issue ls"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "ls refuses an unknown flag rather than silently ignoring it" {
  run bash "$ISSUE" ls --frobnicate
  [ "$status" -ne 0 ]
  [ ! -s "$CURL_LOG" ]
}

@test "approve --help prints usage, exits 0, makes no API call" {
  run bash "$ISSUE" approve --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: pl issue approve"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "top-level help documents both trackers and the approval gate" {
  run bash "$ISSUE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"pl issue approve"* ]]
  [[ "$output" == *"nwp/nwc"* ]]
  [[ "$output" == *"--pending"* ]]
}
