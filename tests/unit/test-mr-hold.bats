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

# --- "could not look" is not "nothing there" (2026-08-02, found on !314) -------

@test "guard exits 2 CANNOT VERIFY when there is no token — not 1 'unreleased'" {
    # !314's own pipeline reported "no release record for this head" and told
    # the operator to run `pl mr release`. It had already been run. The job was
    # tokenless, so it could not read the note it was asking for — a negative
    # asserted about something never examined. Both outcomes refuse, so this is
    # about what the operator is told to do next, not about safety.
    cd "$ROOT" || return 1
    # CI_SERVER_HOST is supplied deliberately: without it the guard now stops at
    # the earlier "host unresolved" refusal and this case would pass without
    # ever reaching the token path it claims to test.
    run env -u NWP_MR_TOKEN -u GITLAB_TOKEN NWP_SECRETS_FILE=/nonexistent-$$ \
        CI_SERVER_HOST=example.invalid \
        CI_MERGE_REQUEST_IID=314 CI_MERGE_REQUEST_TARGET_BRANCH_NAME=main \
        ./scripts/commands/mr.sh guard --ci
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

    run env -u CI_SERVER_HOST -u NWP_GITLAB_HOST -u NWP_MR_TOKEN -u GITLAB_TOKEN \
        NWP_SECRETS_FILE=/nonexistent-$$ CI_MERGE_REQUEST_IID=314 \
        CI_MERGE_REQUEST_TARGET_BRANCH_NAME=main \
        "$ROOT/scripts/commands/mr.sh" guard --ci
    [ "$status" -eq 2 ]
    echo "$output" | grep -q 'forge host could not be determined'
}
