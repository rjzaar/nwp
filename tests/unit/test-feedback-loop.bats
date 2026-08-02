#!/usr/bin/env bats
# lib/feedback-loop.sh + scripts/commands/feedback.sh — the tester-feedback closure.
#
# WHAT THIS SUITE IS FOR
#   Three properties, and every test below serves one of them.
#
#   P1 — THE AUTO-DEPLOY GUARD FIRES. It keys on the canonical phase, and today
#        every real site is `dev`, so in production it currently refuses nothing.
#        An inert guard nobody has ever seen fire is indistinguishable from a
#        broken one, so `deploy-check refuses a fixture site marked prod` builds
#        a site that IS prod and watches the guard say no. Its behaviour is
#        demonstrated years before it matters.
#
#   P2 — `needs-human` IS ENFORCED, NOT DOCUMENTED. Arming a needs-human item
#        would hand a tier-3 doctrine/safeguarding judgement to a code
#        generator. There is no --force, and the refusal is asserted here.
#
#   P3 — NOTHING SILENT. Every derivation that CANNOT be proven returns a rung
#        that says so. In particular `deployed` is unreachable from a merge
#        alone, and "I could not look" is rc 3, never rc 0.
#
# NETWORK: impossible. `curl` is PATH-stubbed and every invocation logged, so
# "no API call" is asserted positively (log absent), not assumed.
#
# NO `command -v yq || skip` GUARDS HERE (removed 2026-08-03, MR !317)
#   The five P1 cases below used to guard on yq and skip when it was absent.
#   bats scores a skip as `ok`, so on any machine without yq the ONLY proof in
#   the tree that the canonical:prod deploy REFUSAL actually fires reported
#   green having asserted nothing. That is H3 in
#   scripts/ci/lint-test-honesty.sh, and this was the worst possible place for
#   it: the guard is inert against the real estate, so the fixture IS the
#   evidence.
#
#   The guards were also dead in the only place they claimed to help. test:unit
#   provisions a pinned, sha256-verified yq (scripts/ci/ensure-yq.sh), declares
#   `NWP_BATS_REQUIRED_TOOLS: "bats git php yq"`, and scripts/ci/run-bats.sh
#   exits 2 — "cannot verify" — before running a single case if any of those is
#   missing. The skip budget is an exact-equality contract on top of that. So a
#   yq-less runner is ALREADY a red pipeline; the guard could only ever fire on
#   a workstation, where silently not running these is exactly wrong.
#
#   If you land here because a case failed with "yq: command not found": that is
#   the intended report. Install yq (`pl setup`), do not re-add the guard.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  LIB="$ROOT/lib/feedback-loop.sh"
  CMD="$ROOT/scripts/commands/feedback.sh"
  TEST_TMP="$(mktemp -d)"

  STUB="$TEST_TMP/bin"; mkdir -p "$STUB"
  export CURL_LOG="$TEST_TMP/curl.log"
  cat > "$STUB/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$CURL_LOG"
echo '{}'
EOF
  chmod +x "$STUB/curl"
  export PATH="$STUB:$PATH"

  export NWP_GITLAB_HOST="gitlab.example.invalid"
  export NWP_SECRETS_FILE="$TEST_TMP/secrets.yml"
  : > "$NWP_SECRETS_FILE"   # deliberately tokenless by default: blind, not clean
}

teardown() { rm -rf "$TEST_TMP"; }

# Source the pure library in a subshell, run one expression, print the result.
_lib() { bash -c "source '$LIB'; $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# fb_has_label — exactness. A substring match here is a safety hole.
# ─────────────────────────────────────────────────────────────────────────────

@test "fb_has_label matches an exact label" {
  run _lib 'fb_has_label "feedback,needs-human,tier-3" needs-human && echo HIT'
  [ "$status" -eq 0 ]; [[ "$output" == *HIT* ]]
}

@test "fb_has_label does NOT match a longer label containing it" {
  # Negative control for the whole label vocabulary: if this ever passes,
  # `needs-human-review` would satisfy the needs-human guard.
  run _lib 'fb_has_label "feedback,needs-human-review" needs-human && echo HIT'
  [ "$status" -ne 0 ]; [[ "$output" != *HIT* ]]
}

@test "fb_has_label tolerates whitespace around list items" {
  run _lib 'fb_has_label "feedback, needs-human , tier-3" needs-human && echo HIT'
  [ "$status" -eq 0 ]; [[ "$output" == *HIT* ]]
}

@test "fb_has_label_prefix finds a scoped refusal label" {
  run _lib 'fb_has_label_prefix "feedback,loop::refused-sensitive" "loop::refused" && echo HIT'
  [ "$status" -eq 0 ]; [[ "$output" == *HIT* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# fb_derive_rung — the state model, as a truth table.
# ─────────────────────────────────────────────────────────────────────────────

@test "rung: a fresh issue with no MR is 'filed'" {
  run _lib 'fb_derive_rung opened "feedback" none no unknown ""'
  [ "$output" = "filed" ]
}

@test "rung: needs-human is surfaced, not hidden behind 'filed'" {
  run _lib 'fb_derive_rung opened "feedback,needs-human" none no unknown ""'
  [ "$output" = "needs-human" ]
}

@test "rung: agent-eligible with no MR is 'armed'" {
  run _lib 'fb_derive_rung opened "feedback,agent-eligible" none no unknown ""'
  [ "$output" = "armed" ]
}

@test "rung: needs-human AND agent-eligible is 'conflict', never silently resolved" {
  # P2. Picking one of the two would be how a needs-human item quietly reaches
  # an agent. The contradiction is reported instead.
  run _lib 'fb_derive_rung opened "feedback,needs-human,agent-eligible" none no unknown ""'
  [ "$output" = "conflict" ]
}

@test "rung: a loop refusal outranks any progress label" {
  run _lib 'fb_derive_rung opened "feedback,agent-eligible,loop::refused-sensitive" none no unknown ""'
  [ "$output" = "refused" ]
}

@test "rung: an open non-draft MR is 'mr-open'" {
  run _lib 'fb_derive_rung opened "feedback" opened no unknown ""'
  [ "$output" = "mr-open" ]
}

@test "rung: an open DRAFT MR is 'held' — the operator asked to check it first" {
  run _lib 'fb_derive_rung opened "feedback" opened yes unknown ""'
  [ "$output" = "held" ]
}

@test "rung: merged with no deploy since is 'merged-not-deployed'" {
  # P3, and the ops#206 lesson: merged must never read as live.
  run _lib 'fb_derive_rung opened "feedback" merged no before ""'
  [ "$output" = "merged-not-deployed" ]
}

@test "rung: merged with no deploy record at all is 'merged-not-deployed'" {
  run _lib 'fb_derive_rung opened "feedback" merged no none ""'
  [ "$output" = "merged-not-deployed" ]
}

@test "rung: merged + a deploy afterwards is 'deployed?' — NEVER 'deployed'" {
  # A timestamp cannot prove WHICH commit is on the site. The question mark is
  # the honest answer and the test that keeps it honest.
  run _lib 'fb_derive_rung opened "feedback" merged no after ""'
  [ "$output" = "deployed?" ]
}

@test "rung: merged with an unreadable deploy record says so" {
  run _lib 'fb_derive_rung opened "feedback" merged no unknown ""'
  [ "$output" = "merged-deploy-unknown" ]
}

@test "rung: no combination of issue/MR state alone can produce 'deployed'" {
  # Exhaustive negative control for the top rung. `deployed` is reachable only
  # from the (not yet built) commit-ancestry anchor, i.e. deploy verdict
  # 'proven'. If a future edit makes a timestamp sufficient, this goes red.
  run bash -c "source '$LIB'
    for istate in opened closed none; do
      for mstate in none opened merged closed; do
        for draft in yes no; do
          for dep in after before none unknown; do
            r=\$(fb_derive_rung \"\$istate\" 'feedback' \"\$mstate\" \"\$draft\" \"\$dep\" '')
            [ \"\$r\" = deployed ] && { echo \"LEAK: \$istate/\$mstate/\$draft/\$dep\"; exit 1; }
          done; done; done; done
    echo CLEAN"
  [ "$status" -eq 0 ]; [[ "$output" == *CLEAN* ]]
}

@test "rung: 'proven' deploy evidence is the ONLY route to 'deployed'" {
  run _lib 'fb_derive_rung opened "feedback" merged no proven ""'
  [ "$output" = "deployed" ]
}

@test "rung: the reporter's confirmation is terminal and outranks everything" {
  run _lib 'fb_derive_rung opened "feedback,agent-eligible" opened no unknown closed_poster_confirmed'
  [ "$output" = "checked" ]
}

@test "rung: the reporter reopening is terminal for this item" {
  run _lib 'fb_derive_rung closed "feedback" merged no after follow_up'
  [ "$output" = "follow-up" ]
}

@test "rung: an issue closed with no MR is 'closed-no-fix', not 'deployed'" {
  run _lib 'fb_derive_rung closed "feedback" none no unknown ""'
  [ "$output" = "closed-no-fix" ]
}

@test "every rung has a plain-language sentence and none of them says Unknown" {
  run bash -c "source '$LIB'
    for r in \$FB_RUNGS; do
      s=\$(fb_plain_rung \"\$r\")
      [ \"\$s\" = Unknown ] && { echo \"MISSING: \$r\"; exit 1; }
    done; echo CLEAN"
  [ "$status" -eq 0 ]; [[ "$output" == *CLEAN* ]]
}

@test "the plain sentence for merged-not-deployed does not claim the fix is live" {
  run _lib 'fb_plain_rung merged-not-deployed'
  [[ "$output" == *"NOT on the site"* ]]
}

@test "fb_rung_needs_operator flags the rungs that are waiting on a human" {
  run _lib 'fb_rung_needs_operator mr-open && fb_rung_needs_operator merged-not-deployed && fb_rung_needs_operator conflict && echo HIT'
  [ "$status" -eq 0 ]; [[ "$output" == *HIT* ]]
}

@test "fb_rung_needs_operator does NOT flag rungs that progress on their own" {
  run _lib 'fb_rung_needs_operator armed || fb_rung_needs_operator checked || echo CLEAN'
  [[ "$output" == *CLEAN* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# P1 — THE AUTO-DEPLOY GUARD
# ─────────────────────────────────────────────────────────────────────────────

@test "guard: canonical dev is allowed (Phase 1 — this is today)" {
  run _lib 'fb_autodeploy_phase_verdict dev'
  [ "$status" -eq 0 ]; [ "$output" = "allow" ]
}

@test "guard: canonical live is allowed — live is not prod, and holds no real users yet" {
  run _lib 'fb_autodeploy_phase_verdict live'
  [ "$status" -eq 0 ]; [ "$output" = "allow" ]
}

@test "guard: canonical PROD is refused" {
  run _lib 'fb_autodeploy_phase_verdict prod'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:prod-phase" ]
}

@test "guard: an unparseable phase is refused, not defaulted" {
  run _lib 'fb_autodeploy_phase_verdict "invalid:staging"'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:phase-unparseable" ]
}

@test "guard: 'I could not read nwp.yml' is refused — a blind guard is not a pass" {
  run _lib 'fb_autodeploy_phase_verdict "cannot-verify:nwp.yml does not parse"'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:phase-unreadable" ]
}

@test "guard: an empty phase is refused" {
  run _lib 'fb_autodeploy_phase_verdict ""'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:phase-empty" ]
}

@test "guard: fb_autodeploy_allowed refuses when no phase reader is loaded" {
  # Fail-closed on a missing dependency, rather than treating the absence of an
  # opinion as permission.
  run _lib 'fb_autodeploy_allowed somesite'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:no-phase-reader" ]
}

@test "guard: every refusal carries an operator-readable reason" {
  run bash -c "source '$LIB'
    for v in refuse:prod-phase refuse:phase-unparseable refuse:phase-unreadable refuse:phase-empty refuse:phase-unknown; do
      t=\$(fb_autodeploy_refusal_text \"\$v\")
      [ \"\$t\" = 'unknown refusal' ] && { echo \"BARE: \$v\"; exit 1; }
    done; echo CLEAN"
  [ "$status" -eq 0 ]; [[ "$output" == *CLEAN* ]]
}

# ── The end-to-end proof: build a site that IS prod, watch the CLI refuse it ──

_fixture_estate() {
  # A two-site fixture estate: one live (Phase 1 shape), one prod (Phase 2
  # shape). Nothing here touches the operator's real nwp.yml.
  export FIXTURE_ROOT="$TEST_TMP/estate"
  mkdir -p "$FIXTURE_ROOT/sites/demosite" "$FIXTURE_ROOT/sites/realprod"
  printf 'project:\n  name: demosite\n' > "$FIXTURE_ROOT/sites/demosite/.nwp.yml"
  printf 'project:\n  name: realprod\n' > "$FIXTURE_ROOT/sites/realprod/.nwp.yml"
  export NWP_YML="$TEST_TMP/nwp.yml"
  cat > "$NWP_YML" <<'EOF'
sites:
  demosite:
    canonical: live
  realprod:
    canonical: prod
EOF
}

@test "deploy-check ALLOWS a canonical:live site (the whole estate, today)" {
  _fixture_estate
  run env PROJECT_ROOT="$FIXTURE_ROOT" NWP_YML="$NWP_YML" bash "$CMD" deploy-check demosite
  [ "$status" -eq 0 ]
  [[ "$output" == *"demosite"* ]]
  [[ "$output" == *"ALLOW"* ]]
}

@test "deploy-check REFUSES a canonical:prod site — the guard is proven to fire" {
  # THIS IS THE TEST THE WHOLE GUARD EXISTS FOR. It is inert against the real
  # estate today (nothing is prod), so its behaviour is demonstrated here on a
  # fixture instead of being taken on trust until the day it matters.
  _fixture_estate
  run env PROJECT_ROOT="$FIXTURE_ROOT" NWP_YML="$NWP_YML" bash "$CMD" deploy-check realprod
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSE"* ]]
  [[ "$output" == *"provisioned from ver"* ]]
}

@test "deploy-check over a mixed estate refuses as a whole but reports per site" {
  _fixture_estate
  run env PROJECT_ROOT="$FIXTURE_ROOT" NWP_YML="$NWP_YML" bash "$CMD" deploy-check
  [ "$status" -eq 1 ]              # one refusal makes the whole check non-zero
  [[ "$output" == *"ALLOW"* ]]     # …and the allowed one is still named
  [[ "$output" == *"REFUSE"* ]]
}

@test "deploy-check --json is machine-readable and carries the verdict per site" {
  _fixture_estate
  run env PROJECT_ROOT="$FIXTURE_ROOT" NWP_YML="$NWP_YML" bash "$CMD" deploy-check realprod --json
  [ "$status" -eq 1 ]
  [[ "$output" == *'"verdict"'* ]]
  [[ "$output" == *'refuse:prod-phase'* ]]
}

@test "deploy-check makes no network call" {
  _fixture_estate
  run env PROJECT_ROOT="$FIXTURE_ROOT" NWP_YML="$NWP_YML" bash "$CMD" deploy-check
  [ ! -f "$CURL_LOG" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# P2 — needs-human
# ─────────────────────────────────────────────────────────────────────────────

@test "arm: REFUSES a needs-human item" {
  run _lib 'fb_arm_verdict "feedback,needs-human,tier-3" no no'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:needs-human" ]
}

@test "arm: the needs-human refusal explains that a PERSON writes this fix" {
  run _lib 'fb_arm_refusal_text refuse:needs-human'
  [[ "$output" == *"a person writes this fix"* ]]
}

@test "arm: needs-human outranks every other condition — it is checked first" {
  # Even a perfectly armable item is refused if it is needs-human, and the
  # reason returned is the needs-human one, not an incidental other refusal.
  run _lib 'fb_arm_verdict "feedback,needs-human,agent-eligible" yes yes'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:needs-human" ]
}

@test "arm: allows an ordinary tier-2 item" {
  run _lib 'fb_arm_verdict "feedback,tier-2,demo-tester" no no'
  [ "$status" -eq 0 ]; [ "$output" = "allow" ]
}

@test "arm: refuses while the agent loop is globally paused" {
  run _lib 'fb_arm_verdict "feedback,tier-2" yes no'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:loop-paused" ]
}

@test "arm: refuses when an MR is already open" {
  run _lib 'fb_arm_verdict "feedback,tier-2" no yes'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:mr-already-open" ]
}

@test "arm: refuses re-arming something already armed" {
  run _lib 'fb_arm_verdict "feedback,agent-eligible" no no'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:already-armed" ]
}

@test "arm: there is no --force flag for needs-human anywhere in the command" {
  # The refusal must not have a bypass. If one is ever added, this goes red.
  run grep -nE -- '--force' "$CMD"
  [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Approval — the operator's two modes, and nothing else
# ─────────────────────────────────────────────────────────────────────────────

@test "approve: exactly two modes exist" {
  run _lib 'echo $FB_APPROVE_MODES'
  [ "$output" = "review auto" ]
}

@test "approve: an unknown mode is refused" {
  run _lib 'fb_approve_verdict yolo "feedback" opened no'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:bad-mode" ]
}

@test "approve: review mode is allowed on an open, unheld MR" {
  run _lib 'fb_approve_verdict review "feedback" opened no'
  [ "$status" -eq 0 ]; [ "$output" = "allow" ]
}

@test "approve: auto mode is allowed on a held MR — that is the release path" {
  run _lib 'fb_approve_verdict auto "feedback" opened yes'
  [ "$status" -eq 0 ]; [ "$output" = "allow" ]
}

@test "approve: refuses when there is no MR to approve" {
  run _lib 'fb_approve_verdict auto "feedback" none no'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:no-mr" ]
}

@test "approve: refuses on an already-merged MR and points at the deploy question" {
  run _lib 'fb_approve_verdict auto "feedback" merged no'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:already-merged" ]
  run _lib 'fb_approve_refusal_text refuse:already-merged'
  [[ "$output" == *"DEPLOYED"* ]]
}

@test "approve: re-holding an already-held MR is refused, with the release hint" {
  run _lib 'fb_approve_verdict review "feedback" opened yes'
  [ "$status" -eq 1 ]; [ "$output" = "refuse:already-held" ]
}

@test "approve: the default mode in the CLI is the SAFE one (review)" {
  run grep -n 'local ref="" mode="review"' "$CMD"
  [ "$status" -eq 0 ]
}

@test "approve: refuses fail-closed when 'pl mr' is not in the checkout, and names it" {
  # `pl mr hold/release` is the approval primitive and lands with MR !314. Until
  # it is on main this must refuse and SAY WHY — the one thing it must not do is
  # grow a second, weaker hold beside a forge-enforced one.
  run env NWP_MR_CMD="$TEST_TMP/definitely-not-here" bash "$CMD" approve 16#42 --mode=auto --approved-by=someone -y
  [ "$status" -eq 3 ]
  [[ "$output" == *"pl mr"* ]]
  [[ "$output" == *"feat/mr-hold-gate"* ]]
  [ ! -f "$CURL_LOG" ]   # and it refused BEFORE any network I/O
}

@test "approve: --mode=auto without --approved-by is a usage error, before any call" {
  cat > "$TEST_TMP/fake-mr" <<'EOF'
#!/bin/bash
echo "fake-mr $*" >> "$FAKE_MR_LOG"
EOF
  chmod +x "$TEST_TMP/fake-mr"
  export FAKE_MR_LOG="$TEST_TMP/mr.log"
  printf 'gitlab:\n  ops_note_token: not-a-real-token-test-fixture\n' > "$NWP_SECRETS_FILE"
  run env NWP_MR_CMD="$TEST_TMP/fake-mr" bash "$CMD" approve 16#42 --mode=auto -y
  [ "$status" -ne 0 ]
  [ ! -f "$FAKE_MR_LOG" ]
}

@test "approve: an unparseable ref is refused before any network I/O" {
  run bash "$CMD" approve "not-a-ref" --mode=review -y
  [ "$status" -eq 2 ]
  [ ! -f "$CURL_LOG" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# P3 — nothing silent
# ─────────────────────────────────────────────────────────────────────────────

@test "status: no token is rc 3 (CANNOT VERIFY), not rc 0" {
  run bash "$CMD" status 16#42
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "list: no token is rc 3, not an empty list" {
  # An empty list and an unaskable question must never look the same.
  run bash "$CMD" list
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "sync-status: no token is rc 3 and says nothing was changed" {
  run bash "$CMD" sync-status nwd --tier=live
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT RUN"* ]]
  [[ "$output" == *"Nothing was changed"* ]]
}

@test "sync-status: the no-token message refuses to be read as 'nothing to sync'" {
  run bash "$CMD" sync-status nwd
  [[ "$output" == *"not 'no feedback to sync'"* ]] || [[ "$output" == *"NOT 'no feedback to sync'"* ]]
}

@test "sync-status: --dry-run runs no drush and touches nothing" {
  printf 'gitlab:\n  ops_note_token: not-a-real-token-test-fixture\n' > "$NWP_SECRETS_FILE"
  run bash "$CMD" sync-status nwd --tier=live --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [ ! -f "$CURL_LOG" ]
}

@test "sync-status: an invalid tier is refused" {
  run bash "$CMD" sync-status nwd --tier=prod
  [ "$status" -eq 2 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# The deploy verdict + the manifest reader
# ─────────────────────────────────────────────────────────────────────────────

@test "deploy verdict: no deploy record at all is 'none'" {
  run _lib 'fb_deploy_verdict "" 1000'
  [ "$output" = "none" ]
}

@test "deploy verdict: a deploy older than the merge is 'before' (a sound negative)" {
  run _lib 'fb_deploy_verdict 900 1000'
  [ "$output" = "before" ]
}

@test "deploy verdict: a deploy after the merge is 'after' — necessary, not sufficient" {
  run _lib 'fb_deploy_verdict 1100 1000'
  [ "$output" = "after" ]
}

@test "deploy verdict: an unreadable merge time is 'unknown', never 'after'" {
  run _lib 'fb_deploy_verdict 1100 ""'
  [ "$output" = "unknown" ]
}

@test "deploy verdict: a non-numeric input is 'unknown', not a crash or a pass" {
  run _lib 'fb_deploy_verdict "yesterday" 1000'
  [ "$output" = "unknown" ]
}

@test "fb_last_deploy_epoch reads the NEWEST stg2live manifest" {
  mkdir -p "$TEST_TMP/deploys/demosite"
  : > "$TEST_TMP/deploys/demosite/stg2live-20260701T101010Z.json"
  : > "$TEST_TMP/deploys/demosite/stg2live-20260728T124622Z.json"
  expected=$(date -u -d '2026-07-28T12:46:22Z' +%s)
  run _lib "fb_last_deploy_epoch demosite '$TEST_TMP/deploys'"
  [ "$output" = "$expected" ]
}

@test "fb_last_deploy_epoch IGNORES dev2stg — staging is not the live site" {
  mkdir -p "$TEST_TMP/deploys/demosite"
  : > "$TEST_TMP/deploys/demosite/dev2stg-20260801T101010Z.json"
  run _lib "fb_last_deploy_epoch demosite '$TEST_TMP/deploys'"
  [ -z "$output" ]
}

@test "fb_last_deploy_epoch returns empty for a site that has never been deployed" {
  mkdir -p "$TEST_TMP/deploys"
  run _lib "fb_last_deploy_epoch neverdeployed '$TEST_TMP/deploys'"
  [ -z "$output" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Ref parsing — refusing to guess
# ─────────────────────────────────────────────────────────────────────────────

@test "ref: project#iid parses to both parts" {
  run _lib 'fb_parse_issue_ref 16#42'
  [ "$output" = "16 42" ]
}

@test "ref: a bare iid defaults to nwp/nwc (16), where feedback issues are filed" {
  run _lib 'fb_parse_issue_ref 42'
  [ "$output" = "16 42" ]
}

@test "ref: a #-prefixed iid parses" {
  run _lib 'fb_parse_issue_ref "#42"'
  [ "$output" = "16 42" ]
}

@test "ref: garbage is refused rather than guessed" {
  run _lib 'fb_parse_issue_ref "nwp/nwc!7"'
  [ "$status" -ne 0 ]
}

@test "ref: a half-formed ref is refused" {
  run _lib 'fb_parse_issue_ref "16#"'
  [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Wiring
# ─────────────────────────────────────────────────────────────────────────────

@test "pl dispatches the new verb" {
  run bash -c "cd '$ROOT' && ./pl commands --json 2>/dev/null | grep -c '\"name\": *\"feedback\"'"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "pl feedback --help lists both approval modes and makes no API call" {
  run bash "$CMD" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"review"* ]]
  [[ "$output" == *"auto"* ]]
  [ ! -f "$CURL_LOG" ]
}

@test "pl feedback --help points the reporter at /my/feedback and the reopen path" {
  run bash "$CMD" --help
  [[ "$output" == *"/my/feedback"* ]]
  [[ "$output" == *"follow-up"* ]]
}

@test "an unknown subcommand is a usage error with no API call" {
  run bash "$CMD" frobnicate
  [ "$status" -eq 2 ]
  [ ! -f "$CURL_LOG" ]
}

@test "every subcommand accepts --help without touching the network" {
  for s in status list arm approve sync-status deploy-check; do
    run bash "$CMD" "$s" --help
    [ "$status" -eq 0 ]
  done
  [ ! -f "$CURL_LOG" ]
}

@test "the command EXECUTES exactly one pl verb, and it is not a deploy" {
  # This loop reports on deploys and gates them; it does not perform one. It may
  # PRINT `pl stg2live …` as a hint to the operator — that is the point — but it
  # must never invoke it. The assertion is therefore over what is executed, not
  # what is mentioned: if a future edit makes `pl feedback` deploy, that is a new
  # capability and must be a reviewed decision, not a drive-by.
  run bash -c "grep -oE '\"\\\$PROJECT_ROOT/pl\" [a-z0-9-]+' '$CMD' | sort -u"
  [ "$status" -eq 0 ]
  [ "$output" = '"$PROJECT_ROOT/pl" drush' ]
}

@test "the only external command the approval path spawns is pl mr" {
  # Same discipline for the approval half: the hold/release primitive is `pl mr`
  # and nothing else is shelled to.
  run bash -c "grep -nE '\\\$mrcmd\" [a-z]+' '$CMD' | grep -oE '\\\$mrcmd\" [a-z]+' | sort -u | tr '\n' ' '"
  [ "$status" -eq 0 ]
  [[ "$output" == *'$mrcmd" hold'* ]]
  [[ "$output" == *'$mrcmd" release'* ]]
}
