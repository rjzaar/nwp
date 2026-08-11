#!/usr/bin/env bats
#
# tests/unit/test-gitlab-list.bats — `pl gitlab-list`, the "does this code have
# a forge home?" verb.
#
# THE DEFECT THIS GUARDS
# ----------------------
# On 2026-08-11 the question "is there an `nwp/dir` project?" had to be answered
# by hand with a raw token, because the verb that exists to answer it did three
# separate wrong things:
#
#   1. IT CRASHED. `cmd_gitlab_list` sources lib/git.sh and lib/common.sh, both
#      of which read `${PROJECT_ROOT}` under `set -u`, and `pl` never set it on
#      the inline-function path. Every invocation died with
#      `PROJECT_ROOT: unbound variable` and then `ERROR: API token required`.
#
#   2. IT PUT THE TOKEN IN ARGV. `curl --header "PRIVATE-TOKEN: $token"` is
#      visible in `ps -ef` to every user on the box. lib/gitlab-mr.sh and
#      lib/gitlab-issues.sh already carry the credential inside a 0600 curl
#      config; this one did not.
#
#   3. IT SWALLOWED THE VERDICT — the worst of the three. The listing was
#      `curl … | grep -o '"path":"[^"]*"' | sed … | sort`. A 403, a 500, an
#      expired token or a dead transport all produce a body with no `"path":`
#      match, so `grep` finds nothing, `sort` exits 0, and the function returns
#      SUCCESS with an EMPTY LIST. "The group contains no such project" and
#      "I was not allowed to look" were byte-identical outputs. That is the
#      exact shape CLAUDE.md names: a check may not substitute a literal for a
#      measurement it failed to take.
#
# Two further blind spots, both latent:
#
#   4. `grep -o '"path":"…"'` matches EVERY `path` key in the payload, including
#      `namespace.path` and `forked_from_project.path`, so the "list of
#      projects" silently contained rows that are not projects.
#   5. `per_page=100` with no pagination: project 101 does not exist as far as
#      this verb is concerned, and nothing says so.
#
# Every assertion below is paired with a negative control (an EMPTY group that
# really is empty must still be rc=0), so a guard that is simply always-red
# cannot pass this file.
#
# Everything runs offline: curl is shadowed by a stub on PATH and PROJECT_ROOT
# is a fixture, so nothing here touches the real forge, nwp.yml or .secrets.yml.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="${BATS_TEST_TMPDIR}"

  export STUBBIN="${TMP}/bin"; mkdir -p "$STUBBIN"
  export ARGV_LOG="${TMP}/curl-argv.log"
  export CFG_COPY="${TMP}/curl-cfg.copy"
  export CFG_MODE="${TMP}/curl-cfg.mode"
  export BODY_DIR="${TMP}/bodies"; mkdir -p "$BODY_DIR"
  export FAKE_CODE_GROUPS=200
  export FAKE_CODE_PROJECTS=200
  export FAKE_TRANSPORT_FAIL=0
  : > "$ARGV_LOG"

  # ── A fixture PROJECT_ROOT: nwp.yml for the host, .secrets.yml for the token.
  export FIXTURE_ROOT="${TMP}/root"; mkdir -p "$FIXTURE_ROOT"
  cat > "${FIXTURE_ROOT}/nwp.yml" <<'YML'
settings:
  url: example.test
YML
  cat > "${FIXTURE_ROOT}/.secrets.yml" <<'YML'
gitlab:
  api_token: fixture-not-a-real-token-FIXTURETOKEN
YML
  chmod 600 "${FIXTURE_ROOT}/.secrets.yml"

  # ── The curl stub. It records its OWN argv (that is one of the things under
  # test), copies any -K config and its mode, and answers from $BODY_DIR.
  cat > "${STUBBIN}/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
cfg=""; url=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    -K) cfg="${args[$((i+1))]}" ;;
    https://*) url="${args[$i]}" ;;
  esac
done
if [ -n "$cfg" ] && [ -f "$cfg" ]; then
  cp "$cfg" "$CFG_COPY"
  stat -c '%a' "$cfg" > "$CFG_MODE"
  url="$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg" | tail -1)"
fi
if [ "${FAKE_TRANSPORT_FAIL:-0}" = "1" ]; then exit 7; fi

case "$url" in
  *"/groups?"*|*"/groups/"*"?"*"search"*|*"/groups?search"*) kind=groups ;;
  *"/groups/"*"/projects"*) kind=projects ;;
  *) kind=groups ;;
esac

page=1
case "$url" in *"page="*) page="${url##*page=}"; page="${page%%&*}" ;; esac

if [ "$kind" = groups ]; then
  code="${FAKE_CODE_GROUPS:-200}"
  body_file="$BODY_DIR/groups.json"
else
  code="${FAKE_CODE_PROJECTS:-200}"
  body_file="$BODY_DIR/projects-page${page}.json"
  [ -f "$body_file" ] || body_file="$BODY_DIR/projects-empty.json"
fi
[ -f "$body_file" ] || printf '[]' > "$body_file"

if [ "$code" != "200" ]; then
  printf '{"message":"%s"}' "$code"
else
  cat "$body_file"
fi
# Only emit the status line when the caller asked for one (write-out).
if [ -n "$cfg" ] && grep -q '^write-out' "$cfg" 2>/dev/null; then
  printf '\n%s' "$code"
fi
STUB
  chmod +x "${STUBBIN}/curl"

  printf '[{"id":9,"path":"nwp","full_path":"nwp"}]' > "${BODY_DIR}/groups.json"
  printf '[]' > "${BODY_DIR}/projects-empty.json"

  # A realistic single page: note the NESTED "path" keys, which are what the
  # old grep-based reader mistook for projects.
  cat > "${BODY_DIR}/projects-page1.json" <<'JSON'
[
 {"id":1,"path":"nwp","path_with_namespace":"nwp/nwp","visibility":"private",
  "default_branch":"main","namespace":{"id":9,"path":"nwp","full_path":"nwp"}},
 {"id":2,"path":"sample-site-project","path_with_namespace":"nwp/sample-site-project","visibility":"private",
  "default_branch":"main","namespace":{"id":9,"path":"nwp","full_path":"nwp"},
  "forked_from_project":{"id":77,"path":"upstream-decoy","path_with_namespace":"other/upstream-decoy"}},
 {"id":3,"path":"courses","path_with_namespace":"nwp/courses","visibility":"public",
  "default_branch":"main","namespace":{"id":9,"path":"nwp","full_path":"nwp"}}
]
JSON
  cat > "${BODY_DIR}/projects-page2.json" <<'JSON'
[
 {"id":4,"path":"server-met","path_with_namespace":"nwp/server-met","visibility":"private",
  "default_branch":"main","namespace":{"id":9,"path":"nwp","full_path":"nwp"}}
]
JSON

  PATH="${STUBBIN}:${PATH}"; export PATH
}

# Run the library function directly, in a fixture root, with the stub on PATH.
run_list() {
  run env PROJECT_ROOT="$FIXTURE_ROOT" NWP_DIR="$FIXTURE_ROOT" \
      bash -c '
        set -uo pipefail
        source "$1/lib/ui.sh"
        source "$1/lib/common.sh"
        source "$1/lib/git.sh"
        gitlab_api_list_projects "${2:-nwp}"
      ' _ "$REPO_ROOT" "${1:-nwp}"
}

################################################################################
# 1. The crash. `pl gitlab-list` must not die on an unset PROJECT_ROOT.
################################################################################
@test "pl gitlab-list does not die with 'PROJECT_ROOT: unbound variable'" {
  run env -u PROJECT_ROOT PATH="${STUBBIN}:${PATH}" \
      "${REPO_ROOT}/pl" gitlab-list nwp
  [[ "$output" != *"PROJECT_ROOT: unbound variable"* ]]
}

################################################################################
# 2. The credential must never reach argv.
################################################################################
@test "the token travels in a 0600 curl config, never in argv" {
  run_list nwp
  # Nothing on any curl command line may contain the token or the header.
  run grep -c 'FIXTURETOKEN' "$ARGV_LOG"
  [ "$output" = "0" ]
  run grep -c 'PRIVATE-TOKEN' "$ARGV_LOG"
  [ "$output" = "0" ]
  # And it must have gone through -K with 0600 on the config.
  [ -f "$CFG_COPY" ]
  [ "$(cat "$CFG_MODE")" = "600" ]
  grep -q 'PRIVATE-TOKEN' "$CFG_COPY"
}

################################################################################
# 3. THE SWALLOWED VERDICT. An unreadable API is never an empty group.
################################################################################
@test "HTTP 403 on the project listing is CANNOT VERIFY (rc=2), not an empty list" {
  FAKE_CODE_PROJECTS=403
  run_list nwp
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  # It must NOT have printed anything that reads as a project inventory.
  [[ "$output" != *"nwp/courses"* ]]
}

@test "HTTP 500 on the project listing is CANNOT VERIFY (rc=2)" {
  FAKE_CODE_PROJECTS=500
  run_list nwp
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "a dead transport is CANNOT VERIFY (rc=2), not an empty list" {
  FAKE_TRANSPORT_FAIL=1
  run_list nwp
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "an unreadable GROUP lookup is CANNOT VERIFY (rc=2), not 'group not found'" {
  FAKE_CODE_GROUPS=403
  run_list nwp
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

################################################################################
# 3b. NEGATIVE CONTROL — a group that really is empty is an honest rc=0 that
#     SAYS zero. Without this, an always-red guard would pass the file above.
################################################################################
@test "a genuinely empty group is rc=0 and says so out loud" {
  printf '[]' > "${BODY_DIR}/projects-page1.json"
  run_list nwp
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 project"* ]]
}

################################################################################
# 4. Nested "path" keys are not projects.
################################################################################
@test "a nested namespace/fork 'path' does not appear as a project" {
  run_list nwp
  [ "$status" -eq 0 ]
  [[ "$output" != *"upstream-decoy"* ]]
  # "nwp" appears once, as nwp/nwp — not three times as the namespace of each row.
  run bash -c "printf '%s\n' \"\$1\" | grep -c 'nwp/nwp'" _ "$output"
  [ "$output" = "1" ]
}

################################################################################
# 5. Pagination. Project 101 exists.
################################################################################
@test "every page is read, not just the first" {
  # A FULL first page (100 = per_page) is what tells a reader there may be more.
  # The old code asked for one page of 100 and stopped, so project 101 did not
  # exist as far as it was concerned — and nothing said so.
  python3 - "$BODY_DIR/projects-page1.json" <<'PY'
import json,sys
rows=[{"id":100+i,"path":f"filler{i:03d}","path_with_namespace":f"nwp/filler{i:03d}",
       "visibility":"private","default_branch":"main",
       "namespace":{"id":9,"path":"nwp","full_path":"nwp"}} for i in range(100)]
json.dump(rows, open(sys.argv[1],"w"))
PY
  run_list nwp
  [ "$status" -eq 0 ]
  [[ "$output" == *"nwp/server-met"* ]]   # lives on page 2
  [[ "$output" == *"101 project(s)"* ]]
}

################################################################################
# 6. Visibility is reported — this verb is how the estate answers "would
#    pushing this repo publish it?", and a name alone cannot answer that.
################################################################################
@test "each project reports its visibility" {
  run_list nwp
  [ "$status" -eq 0 ]
  [[ "$output" == *"public"* ]]
  [[ "$output" == *"private"* ]]
  # The public one must be identifiable BY NAME, not just by the word appearing.
  [[ "$output" =~ nwp/courses[[:space:]]+public ]]
}
