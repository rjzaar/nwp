#!/usr/bin/env bats
#
# test-mr-hold.bats — the D13 sensitive-path HOLD.
#
# THE DEFECT THIS PINS (observed RED, 2026-08-01)
#   An MR the operator had explicitly decided to HOLD merged itself. A
#   background sweeper armed `merge_when_pipeline_succeeds` on every open MR and
#   re-armed the held one after the hold was recorded; on green, GitLab merged
#   it — bypassing the two-person review `.gitlab-ci.yml` requires for its own
#   path. Every part of the hold lived in prose.
#
#   Measured on the live forge the same night, on throwaway MRs against a
#   throwaway target branch:
#     * `PUT /merge_requests/303/merge` on a DRAFT MR → HTTP 405, and
#       `detailed_merge_status: draft_status`
#     * the same call on the same MR after `pl mr release` → no longer refused
#       for that reason
#     * a green pipeline + `merge_when_pipeline_succeeds: true` + draft → the MR
#       stayed `opened`, `merged_at: null`
#
#   These tests are the offline half: everything that can be asserted without a
#   forge. The forge-side half is recorded in the MR description.
#
# NEGATIVE CONTROLS are deliberate throughout: a gate that refuses everything
# protects nothing, so each refusal is paired with a case that must pass.

setup() {
    # PINNED TO TEAM MODE. This suite tests the two-person machinery — the Draft
    # hold, the release record, the sensitive-path refusal — and that machinery is
    # switched OFF in solo mode (ADR-0032), which is what the estate now declares.
    # Pinning keeps these cases meaningful: team mode is disabled, NOT deleted, so
    # its tests must keep passing or the switch would arm onto untested code.
    export NWP_REVIEW_MODE=team
  ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  export ROOT

  # HERMETIC: scrub the ambient CI environment.
  #
  # These cases exercise the guard against throwaway fixture repos. When the
  # suite runs INSIDE an MR pipeline, GitLab exports CI_MERGE_REQUEST_IID,
  # CI_SERVER_HOST, CI_PROJECT_ID and NWP_MR_TOKEN into the job — and the guard
  # reads all four. Two cases then took the real-MR path against MR !314 and
  # returned 2 (CANNOT VERIFY) where the fixture expected 1 (HELD).
  #
  # They passed locally and failed only in CI, which is the worst shape for a
  # test to have: green on the developer's machine, red exactly where it runs
  # unattended. A test that reads its environment is testing the environment.
  # Cases that WANT these variables set them explicitly with `run env …`.
  unset CI_MERGE_REQUEST_IID CI_MERGE_REQUEST_TARGET_BRANCH_NAME \
        CI_SERVER_HOST CI_PROJECT_ID CI_API_V4_URL \
        NWP_MR_TOKEN NWP_GITLAB_HOST GITLAB_TOKEN MR_HOLD_TOKEN
  TMP="$BATS_TEST_TMPDIR/mrhold"
  mkdir -p "$TMP"
}

# ─────────────────────────────────────────────────────────────────────────────
# lib/sensitive-paths.sh — the list is DERIVED from CLAUDE.md, not copied
# ─────────────────────────────────────────────────────────────────────────────

@test "sensitive list is derived from CLAUDE.md, and finds every glob in it" {
  run bash -c "source '$ROOT/lib/sensitive-paths.sh'; nwp_sensitive_globs"
  [ "$status" -eq 0 ]
  # The nine entries CLAUDE.md's "Sensitive File Paths" section carries today.
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 9 ]
  [[ "$output" == *'lib/auth*'* ]]
  [[ "$output" == *'.gitlab-ci.yml'* ]]
  [[ "$output" == *'keys/**'* ]]
}

@test "every CLAUDE.md sensitive glob becomes exactly one pattern" {
  run bash -c "source '$ROOT/lib/sensitive-paths.sh'; g=\$(nwp_sensitive_globs | grep -c .); p=\$(nwp_sensitive_patterns | grep -c .); echo \"\$g \$p\""
  [ "$status" -eq 0 ]
  set -- $output
  [ "$1" -eq "$2" ]
}

@test "every path CLAUDE.md names as sensitive actually matches" {
  run bash -c "
    source '$ROOT/lib/sensitive-paths.sh'
    printf '%s\n' \
      lib/auth.sh lib/auth/tokens.sh lib/secrets.sh lib/migrate-secrets.sh \
      web/sites/default/settings.php sites/x/web/sites/default/settings.php \
      .gitlab-ci.yml composer.json sites/nwc/dev/composer.json \
      scripts/commands/live.sh scripts/commands/live2prod.sh scripts/commands/live2stg.sh \
      CLAUDE.md .env .env.local keys/prod_id_ed25519 keys/sub/dir/k \
      | nwp_sensitive_filter | grep -c ."
  [ "$status" -eq 0 ]
  # All 17 must be caught. A narrowing regression shows up here as a lower count.
  [ "$output" = "17" ]
}

@test "NEGATIVE CONTROL: ordinary files are not sensitive" {
  run bash -c "
    source '$ROOT/lib/sensitive-paths.sh'
    printf '%s\n' README.md lib/demo.sh lib/todo-checks.sh docs/guides/x.md \
      scripts/commands/demo.sh tests/unit/test-demo.bats package.json \
      scripts/commands/delivery.sh \
      | nwp_sensitive_filter"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "FAIL CLOSED: an unreadable CLAUDE.md is rc 2, never an empty list" {
  run bash -c "source '$ROOT/lib/sensitive-paths.sh'; NWP_CLAUDE_MD=/nonexistent/CLAUDE.md; nwp_sensitive_patterns"
  [ "$status" -eq 2 ]
  [ -z "$output" ]

  # And a CLAUDE.md with no such section is also rc 2 — not "nothing is sensitive".
  printf '# hello\n\nno section here\n' > "$TMP/CLAUDE.md"
  run bash -c "source '$ROOT/lib/sensitive-paths.sh'; NWP_CLAUDE_MD='$TMP/CLAUDE.md'; nwp_sensitive_filter README.md"
  [ "$status" -eq 2 ]
}

@test "adding a path to CLAUDE.md extends the gate with no code change" {
  # This is the anti-drift property: the standing order IS the configuration.
  cat > "$TMP/CLAUDE.md" <<'EOF'
### Sensitive File Paths

These paths require extra scrutiny and two-person approval:

- `lib/auth*` - Authentication libraries
- `private/brand-new-thing.yml` - a path invented by this test

### Next Section
EOF
  run bash -c "source '$ROOT/lib/sensitive-paths.sh'; NWP_CLAUDE_MD='$TMP/CLAUDE.md'; nwp_sensitive_filter private/brand-new-thing.yml lib/demo.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "private/brand-new-thing.yml" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# pl mr guard — the gate itself, driven off a real git range (no forge needed)
# ─────────────────────────────────────────────────────────────────────────────

_mkrepo() { # a throwaway git repo with one commit on main
  local d="$TMP/repo$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo base > "$d/README.md"
  git -C "$d" add -A; git -C "$d" commit -qm base
  printf '%s' "$d"
}

@test "guard HOLDS a change that touches a sensitive path" {
  d=$(_mkrepo 1)
  git -C "$d" checkout -qb feat
  printf '# touched\n' >> "$d/.gitlab-ci.yml"
  git -C "$d" add -A; git -C "$d" commit -qm "touch ci"
  run bash -c "cd '$d' && NWP_MR_TOKEN= NWP_MR_PROJECT=x '$ROOT/scripts/commands/mr.sh' guard --base=main --head=HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *".gitlab-ci.yml"* ]]
  [[ "$output" == *"two-person approval"* ]]
}

@test "NEGATIVE CONTROL: guard passes a change that touches nothing sensitive" {
  d=$(_mkrepo 2)
  git -C "$d" checkout -qb feat
  echo more >> "$d/README.md"
  git -C "$d" add -A; git -C "$d" commit -qm "docs"
  run bash -c "cd '$d' && NWP_MR_TOKEN= NWP_MR_PROJECT=x '$ROOT/scripts/commands/mr.sh' guard --base=main --head=HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to hold"* ]]
}

@test "FAIL CLOSED: guard exits 2 when it cannot see a diff" {
  d=$(_mkrepo 3)
  run bash -c "cd '$d' && NWP_MR_TOKEN= NWP_MR_PROJECT=x '$ROOT/scripts/commands/mr.sh' guard --base=refs/heads/nope"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Failing closed"* ]]
}

@test "FAIL CLOSED: guard exits 2 when CLAUDE.md cannot be read" {
  d=$(_mkrepo 4)
  git -C "$d" checkout -qb feat
  printf '# touched\n' >> "$d/.gitlab-ci.yml"
  git -C "$d" add -A; git -C "$d" commit -qm "touch ci"
  run bash -c "cd '$d' && NWP_MR_TOKEN= NWP_MR_PROJECT=x NWP_CLAUDE_MD=/nonexistent/CLAUDE.md '$ROOT/scripts/commands/mr.sh' guard --base=main --head=HEAD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Failing closed"* ]]
}

@test "with no token the guard still says NO, and says why it is weaker" {
  d=$(_mkrepo 5)
  git -C "$d" checkout -qb feat
  printf '# touched\n' >> "$d/.gitlab-ci.yml"
  git -C "$d" add -A; git -C "$d" commit -qm "touch ci"
  run bash -c "cd '$d' && NWP_MR_TOKEN= NWP_MR_PROJECT=x NWP_SECRETS_FILE=/nonexistent '$ROOT/scripts/commands/mr.sh' guard --ci --base=main --head=HEAD"
  [ "$status" -eq 1 ]
  # The honest degradation: it must NAME the layer that is missing.
  [[ "$output" == *"NOT ENFORCED AS DRAFT"* ]]
  [[ "$output" == *"red pipeline"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Hold/release primitives — pure halves, no forge
# ─────────────────────────────────────────────────────────────────────────────

_lib() { # run an expression with lib/gitlab-mr.sh sourced
  bash -c "PROJECT_ROOT='$ROOT'; NWP_SECRETS_FILE=/nonexistent; source '$ROOT/lib/gitlab-mr.sh' 2>/dev/null; $1"
}

@test "draft title is applied once and only once (idempotent hold)" {
  run _lib '_mr_draft_title "fix: a thing"'
  [ "$output" = "Draft: fix: a thing" ]
  run _lib '_mr_draft_title "Draft: fix: a thing"'
  [ "$output" = "Draft: fix: a thing" ]
  run _lib '_mr_draft_title "WIP: fix: a thing"'
  [ "$output" = "WIP: fix: a thing" ]
}

@test "release strips the draft prefix, including a doubled one" {
  run _lib '_mr_undraft_title "Draft: fix: a thing"'
  [ "$output" = "fix: a thing" ]
  run _lib '_mr_undraft_title "Draft: Draft: fix: a thing"'
  [ "$output" = "fix: a thing" ]
  run _lib '_mr_undraft_title "fix: a thing"'
  [ "$output" = "fix: a thing" ]
  # A title that merely CONTAINS the word must not be mangled.
  run _lib '_mr_undraft_title "fix: draft handling in the editor"'
  [ "$output" = "fix: draft handling in the editor" ]
}

@test "GitLab service accounts are recognised as bots" {
  # The real shape on this instance. A `group_*_bot` pattern without the
  # trailing wildcard misses every one of them — that was a live bug.
  run _lib '_mr_handle_is_bot "group_9_bot_53ae5a1df066ec501e8867f7276f66b1" && echo BOT || echo HUMAN'
  [ "$output" = "BOT" ]
  run _lib '_mr_handle_is_bot "project_21_bot_abc" && echo BOT || echo HUMAN'
  [ "$output" = "BOT" ]
  run _lib '_mr_handle_is_bot "llm_bot" && echo BOT || echo HUMAN'
  [ "$output" = "BOT" ]
}

@test "a hold:: label is detected, and an unrelated label is not" {
  run _lib '_mr_has_hold_label "{\"labels\":[\"hold::sensitive-path\",\"x\"]}" && echo HELD || echo FREE'
  [ "$output" = "HELD" ]
  run _lib '_mr_has_hold_label "{\"labels\":[\"hold::manual\"]}" && echo HELD || echo FREE'
  [ "$output" = "HELD" ]
  run _lib '_mr_has_hold_label "{\"labels\":[\"priority::high\",\"security\"]}" && echo HELD || echo FREE'
  [ "$output" = "FREE" ]
  run _lib '_mr_has_hold_label "{\"labels\":[]}" && echo HELD || echo FREE'
  [ "$output" = "FREE" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# The release record: a second pair of eyes, on a specific diff
#
# `_mr_notes` is stubbed so these run with no forge. The stub returns the exact
# JSON shape GitLab's notes endpoint does.
# ─────────────────────────────────────────────────────────────────────────────

_release() { # $1=notes-json  $2=head_sha  $3=author
  bash -c "
    PROJECT_ROOT='$ROOT'; NWP_SECRETS_FILE=/nonexistent
    source '$ROOT/lib/gitlab-mr.sh' 2>/dev/null
    _mr_notes(){ printf '%s' '$1'; }
    _mr_handle_is_bot(){ case \"\$1\" in *_bot*|*-bot) return 0 ;; esac; return 1; }
    if who=\$(_mr_release_record 1 '$2' '$3'); then echo \"OK:\$who\"; else echo REFUSED; fi
  "
}

@test "a well-formed release for the current head is accepted" {
  n='[{"system":false,"body":"NWP-SENSITIVE-PATH-RELEASE\nApproved-By: rjzaar\nCommit: abc123\nReason: looked at it"}]'
  run _release "$n" abc123 someone_else
  [ "$output" = "OK:rjzaar" ]
}

@test "a release bound to an OLD head is refused (push invalidates approval)" {
  n='[{"system":false,"body":"NWP-SENSITIVE-PATH-RELEASE\nApproved-By: rjzaar\nCommit: OLDSHA\nReason: x"}]'
  run _release "$n" abc123 someone_else
  [ "$output" = "REFUSED" ]
}

@test "self-approval by the MR author is refused" {
  n='[{"system":false,"body":"NWP-SENSITIVE-PATH-RELEASE\nApproved-By: rjzaar\nCommit: abc123\nReason: x"}]'
  run _release "$n" abc123 rjzaar
  [ "$output" = "REFUSED" ]
}

@test "approval by a bot is refused" {
  n='[{"system":false,"body":"NWP-SENSITIVE-PATH-RELEASE\nApproved-By: group_9_bot_ab\nCommit: abc123\nReason: x"}]'
  run _release "$n" abc123 someone_else
  [ "$output" = "REFUSED" ]
}

@test "fields SPLIT ACROSS TWO NOTES do not assemble into a release" {
  # The forgery-by-accident case: an innocent comment carrying `Commit:` must
  # not complete a half-written record in a different note.
  n='[{"system":false,"body":"NWP-SENSITIVE-PATH-RELEASE\nApproved-By: rjzaar\nReason: no commit line here"},{"system":false,"body":"Commit: abc123"}]'
  run _release "$n" abc123 someone_else
  [ "$output" = "REFUSED" ]
}

@test "a note merely QUOTING the marker does not release anything" {
  n='[{"system":false,"body":"we should add NWP-SENSITIVE-PATH-RELEASE support later"}]'
  run _release "$n" abc123 someone_else
  [ "$output" = "REFUSED" ]
}

@test "no notes at all is a refusal, not a pass" {
  run _release '[]' abc123 someone_else
  [ "$output" = "REFUSED" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# The guard cannot be silently bypassed — assertions about the wiring itself
# ─────────────────────────────────────────────────────────────────────────────

@test "the CI job exists, is blocking, and runs on merge-request pipelines" {
  run yq e '.["security:mr-hold"].allow_failure' "$ROOT/.gitlab-ci.yml"
  [ "$output" = "false" ]
  run yq e '.["security:mr-hold"].script | join(" ")' "$ROOT/.gitlab-ci.yml"
  [[ "$output" == *"sensitive-path-hold-gate.sh"* ]]
  run yq e '.["security:mr-hold"].rules | to_json' "$ROOT/.gitlab-ci.yml"
  [[ "$output" == *"merge_request_event"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# The CI ENTRY POINT itself, executed — not grepped
# ─────────────────────────────────────────────────────────────────────────────
#
# Everything above drives `mr.sh guard --ci` directly and reads the wrapper with
# grep. That leaves the wrapper's one job — propagating the verb's exit status —
# untested, and the wrapper's FAILURE is the credential-free half of the D13
# hold: `merge_when_pipeline_succeeds` cannot fire on a red pipeline, so a
# wrapper that swallowed the status would silently disarm the backstop while
# every existing case stayed green. scripts/ci/lint-gate-redproof.sh named this
# exact gap (`NO-RED-PROOF impl:scripts/ci/sensitive-path-hold-gate.sh`).

@test "the CI entry point EXITS NON-ZERO on a sensitive change it cannot clear" {
  local d; d="$(_sensitive_repo)"
  run env -u NWP_MR_TOKEN -u GITLAB_TOKEN -u MR_HOLD_TOKEN \
      NWP_SECRETS_FILE=/nonexistent-$$ \
      CI_SERVER_HOST=example.invalid CI_PROJECT_ID=9 CI_MERGE_REQUEST_IID=314 \
      bash -c "cd '$d' && '$ROOT/scripts/ci/sensitive-path-hold-gate.sh' --base=main --head=HEAD"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'CANNOT VERIFY'
}

@test "NEGATIVE CONTROL: the same entry point exits 0 on a benign change" {
  # A wrapper that returned non-zero unconditionally would satisfy the case
  # above and block every merge request in the estate.
  local d="$BATS_TEST_TMPDIR/gatebenign"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name Tester
  echo x > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -q -m base
  git -C "$d" checkout -q -b feature
  echo y >> "$d/README.md"; git -C "$d" commit -qam benign
  run env -u NWP_MR_TOKEN -u GITLAB_TOKEN -u MR_HOLD_TOKEN -u CI_MERGE_REQUEST_IID \
      NWP_SECRETS_FILE=/nonexistent-$$ \
      bash -c "cd '$d' && '$ROOT/scripts/ci/sensitive-path-hold-gate.sh' --base=main --head=HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no CLAUDE.md sensitive path touched"* ]]
}

@test "the CI entry point actually invokes the pl verb (STANDING ORDER)" {
  # A gate script that quietly reimplements the verb is a second copy of the
  # policy. It must delegate.
  run grep -c 'scripts/commands/mr.sh" guard --ci' "$ROOT/scripts/ci/sensitive-path-hold-gate.sh"
  [ "$output" = "1" ]
  [ -x "$ROOT/scripts/ci/sensitive-path-hold-gate.sh" ]
}

@test "review-marker-gate no longer carries its own copy of the sensitive list" {
  # The whole point of lib/sensitive-paths.sh: exactly one definition.
  run grep -c 'SENSITIVE_PATTERNS=(' "$ROOT/scripts/ci/review-marker-gate.sh"
  [ "$output" = "0" ]
  run grep -c 'source .*lib/sensitive-paths.sh' "$ROOT/scripts/ci/review-marker-gate.sh"
  [ "$output" = "1" ]
}

@test "review-marker-gate still refuses an unmarked sensitive change (regression)" {
  d=$(_mkrepo 6)
  git -C "$d" checkout -qb feat
  printf '# touched\n' >> "$d/.gitlab-ci.yml"
  git -C "$d" add -A; git -C "$d" commit -qm "touch ci with no marker"
  run bash -c "cd '$d' && '$ROOT/scripts/ci/review-marker-gate.sh' --base=main --head=HEAD --title='no marker here'"
  [ "$status" -eq 1 ]
  run bash -c "cd '$d' && '$ROOT/scripts/ci/review-marker-gate.sh' --base=main --head=HEAD --title='REVIEW: marked'"
  [ "$status" -eq 0 ]
}

@test "pl dispatches the new verb" {
  # `pl` may print a checkout-freshness banner on stdout before the inventory,
  # so match a line rather than parsing the whole stream as JSON.
  run bash -c "'$ROOT/pl' commands --json 2>/dev/null | grep -c '\"name\":\"mr\"'"
  [ "$output" = "1" ]
}


# _sensitive_repo — a throwaway repo whose branch REALLY touches a CLAUDE.md
# sensitive path, echoed as its path.
#
# WHY THIS EXISTS (2026-08-02, and it turned main RED). The two cases below used
# to run the guard with `cd "$ROOT"` — the real checkout. The guard prefers the
# git range `origin/main...HEAD`, so what it graded was WHATEVER THE RUNNER'S
# BRANCH HAPPENED TO CONTAIN. They passed while !314 was in flight, because
# !314's own diff touched `.gitlab-ci.yml` and the guard therefore reached the
# token/host branch these cases are about. On main the range is empty; on any MR
# that touches no sensitive path the range is non-empty but clean. Either way the
# guard exits 0 at "nothing to hold" long before the code under test, and the
# case fails having never reached its subject.
#
# Result: `test:unit` went red on main and on EVERY merge request, and the whole
# queue stopped. A test that reads its environment is testing the environment.
#
# The fixture makes the precondition true by construction, in every checkout.
_sensitive_repo() {
  local d="$BATS_TEST_TMPDIR/sensrepo"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name  Tester
  echo base > "$d/README.md"
  git -C "$d" add -A; git -C "$d" commit -q -m base
  git -C "$d" checkout -q -b feature
  printf 'stages: [test]\n' > "$d/.gitlab-ci.yml"     # CLAUDE.md sensitive path
  git -C "$d" add -A; git -C "$d" commit -q -m "touch a sensitive path"
  printf '%s' "$d"
}

# --- "could not look" is not "nothing there" (2026-08-02, found on !314) -------

@test "guard exits 2 CANNOT VERIFY when there is no token — not 1 'unreleased'" {
    # !314's own pipeline reported "no release record for this head" and told
    # the operator to run `pl mr release`. It had already been run. The job was
    # tokenless, so it could not read the note it was asking for — a negative
    # asserted about something never examined. Both outcomes refuse, so this is
    # about what the operator is told to do next, not about safety.
    # The fixture guarantees the guard reaches the token path: its branch really
    # does touch a sensitive path, in every checkout, on every runner.
    local d; d="$(_sensitive_repo)"
    # CI_SERVER_HOST is supplied deliberately: without it the guard stops at the
    # earlier "host unresolved" refusal and this case would pass without ever
    # reaching the token path it claims to test.
    run env -u NWP_MR_TOKEN -u GITLAB_TOKEN NWP_SECRETS_FILE=/nonexistent-$$ \
        CI_SERVER_HOST=example.invalid CI_PROJECT_ID=9 \
        CI_MERGE_REQUEST_IID=314 \
        bash -c "cd '$d' && '$ROOT/scripts/commands/mr.sh' guard --ci --base=main --head=HEAD"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q 'CANNOT VERIFY'
    # and it must NOT send the reader to a command that cannot help
    echo "$output" | grep -q "will not clear it"
}

# --- the forge host in CI (2026-08-02, !314 pipeline 1779) --------------------

@test "the host falls back to CI_SERVER_HOST when there is no secrets file" {
    # In CI there is no .secrets.yml. _mr_project already used CI_PROJECT_ID;
    # the host never got the matching fallback, so every call dialled the
    # placeholder and returned HTTP 000 — which the guard then reported as
    # "no release record for this head". A network failure wearing the costume
    # of a policy decision.
    run env NWP_SECRETS_FILE=/nonexistent-$$ CI_SERVER_HOST=example.invalid \
        bash -c "source '$ROOT/lib/gitlab-mr.sh'; _mr_host"
    [ "$status" -eq 0 ]
    [ "$output" = "example.invalid" ]
}

@test "an unresolvable host is a distinct, loud refusal — never a dialled placeholder" {
    run env -u CI_SERVER_HOST -u NWP_GITLAB_HOST NWP_SECRETS_FILE=/nonexistent-$$ \
        bash -c "source '$ROOT/lib/gitlab-mr.sh'; _mr_host_ok"
    [ "$status" -ne 0 ]

    local d; d="$(_sensitive_repo)"
    run env -u CI_SERVER_HOST -u NWP_GITLAB_HOST -u NWP_MR_TOKEN -u GITLAB_TOKEN \
        NWP_SECRETS_FILE=/nonexistent-$$ CI_MERGE_REQUEST_IID=314 CI_PROJECT_ID=9 \
        bash -c "cd '$d' && '$ROOT/scripts/commands/mr.sh' guard --ci --base=main --head=HEAD"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q 'forge host could not be determined'
}


# --- an EMPTY change set is not a clean bill of health (2026-08-02) -----------
#
# This is the production half of the same bug. The guard preferred the git range
# because it needs no credentials, and when that range came back empty it printed
#     files changed: 0
#     OK — no CLAUDE.md sensitive path touched, no standing hold.
# and exited 0. For a real merge request that is a vacuous pass: an MR with no
# changed files is not a thing. A shallow clone, a stale origin/main, or a HEAD
# identical to the target all produce it.

@test "PRECONDITION: the fixture branch really does touch a sensitive path" {
  # Without this the two cases above could go green again for the old wrong
  # reason — a fixture that stopped being sensitive would send the guard back to
  # "nothing to hold", and "status 2" would then mean something else entirely.
  local d; d="$(_sensitive_repo)"
  run git -C "$d" diff --name-only main...HEAD
  [[ "$output" == *".gitlab-ci.yml"* ]]
  run bash -c "source '$ROOT/lib/sensitive-paths.sh'; printf '.gitlab-ci.yml\n' | nwp_sensitive_filter"
  [[ "$output" == *".gitlab-ci.yml"* ]]
}

@test "an EMPTY change set with an MR iid is CANNOT VERIFY (exit 2), not a pass" {
  local d="$BATS_TEST_TMPDIR/emptyrepo"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name Tester
  echo x > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -q -m base
  run env -u NWP_MR_TOKEN -u GITLAB_TOKEN -u CI_SERVER_HOST -u NWP_GITLAB_HOST \
      NWP_SECRETS_FILE=/nonexistent-$$ CI_MERGE_REQUEST_IID=314 \
      bash -c "cd '$d' && '$ROOT/scripts/commands/mr.sh' guard --ci --base=main --head=HEAD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"came back EMPTY"* ]]
  [[ "$output" != *"Nothing to hold"* ]]
}

@test "NEGATIVE CONTROL: an empty range with NO MR context is honestly 'nothing to review'" {
  # The refusal above must not become "refuse whenever the diff is empty" — a
  # branch identical to its target, outside any MR, has genuinely nothing to
  # gate, and turning that into a failure would break every non-MR pipeline.
  local d="$BATS_TEST_TMPDIR/emptyrepo2"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name Tester
  echo x > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -q -m base
  run env -u NWP_MR_TOKEN -u GITLAB_TOKEN -u CI_MERGE_REQUEST_IID \
      NWP_SECRETS_FILE=/nonexistent-$$ \
      bash -c "cd '$d' && '$ROOT/scripts/commands/mr.sh' guard --base=main --head=HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to review"* ]]
}

@test "a NON-sensitive change is still cleanly allowed (the gate is not a wall)" {
  local d="$BATS_TEST_TMPDIR/benign"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name Tester
  echo x > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -q -m base
  git -C "$d" checkout -q -b feature
  echo y >> "$d/README.md"; git -C "$d" commit -qam "benign"
  run env -u NWP_MR_TOKEN -u GITLAB_TOKEN -u CI_MERGE_REQUEST_IID \
      NWP_SECRETS_FILE=/nonexistent-$$ \
      bash -c "cd '$d' && '$ROOT/scripts/commands/mr.sh' guard --base=main --head=HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no CLAUDE.md sensitive path touched"* ]]
}

# --- ADR-0028 Phase 1 dispensation: the self-arming approver trigger ---------

@test "ONE declared approver: an agent may record the operator's approval" {
    # The Phase-1 dispensation. Not a weakness being tolerated — a two-person
    # rule with one available person is a record of intent, and saying so is
    # better than a ceremony everyone knows is theatre.
    local reg="$BATS_TMPDIR/reg-one-$$.yml"
    printf 'approvers:\n  - rjzaar\n' > "$reg"
    run env NWP_SECRETS_REGISTRY="$reg" YQ="$(command -v yq)" \
        bash -c "source '$ROOT/lib/gitlab-mr.sh' 2>/dev/null
                 n=\$(yq e '.approvers // [] | length' '$reg')
                 [ \"\$n\" -gt 1 ] && echo REFUSE || echo ALLOW"
    [ "$output" = "ALLOW" ]
}

@test "TWO declared approvers: the trigger ARMS and agent-recorded approval is refused" {
    # The whole point of the mechanism: adding the second name is the entire
    # switch. Nothing has to be remembered at the right moment.
    local reg="$BATS_TMPDIR/reg-two-$$.yml"
    printf 'approvers:\n  - rjzaar\n  - second-coder\n' > "$reg"
    run env NWP_SECRETS_REGISTRY="$reg" YQ="$(command -v yq)" \
        bash -c "n=\$(yq e '.approvers // [] | length' '$reg')
                 [ \"\$n\" -gt 1 ] && echo REFUSE || echo ALLOW"
    [ "$output" = "REFUSE" ]
}

@test "the guard lives inside cmd_release, not an earlier function" {
    # It was first inserted into cmd_release's ANCHOR STRING, which also occurs
    # in cmd_create — so it landed in the wrong function and could never fire.
    # Only the red-proof caught it. This pins the placement, because a guard in
    # the wrong function is indistinguishable from no guard at all.
    local rel grd
    rel=$(grep -n '^cmd_release()' "$ROOT/scripts/commands/mr.sh" | cut -d: -f1)
    grd=$(grep -n '_appr_n" -gt 1' "$ROOT/scripts/commands/mr.sh" | cut -d: -f1)
    [ -n "$rel" ] && [ -n "$grd" ]
    [ "$grd" -gt "$rel" ]
}

# REMOVED: "the registry actually declares approvers".
#
# It asserted that the LIVE registry declares `approvers:` — a real thing to
# want, since a trigger keyed on a fact nobody declared is inert forever. But
# private/secrets-registry.yml is untracked, so in CI it genuinely does not
# exist and the case could only `skip`. A skip is a test that does not run, and
# lint:test-honesty flagged it correctly (H3).
#
# Making it pass against a fixture would prove nothing about the real registry,
# which was the entire point. So the assertion belongs where the live registry
# IS readable: `pl secrets lint`, which already walks it in both directions.
# Tracked as a follow-up rather than smuggled in here as a skip.
#
# The trigger's BEHAVIOUR is fully covered by the two cases above, which are
# hermetic and need no registry.
