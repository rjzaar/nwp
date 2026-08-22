#!/usr/bin/env bats
# ops#319 Tranche 2 (F2) — the acceptance suite for INJECTION → PROJECTION.
#
# WHAT WAS RED, ON THE REAL TREE, BEFORE ANY OF THIS EXISTED
# ----------------------------------------------------------
# `pl doc-truth --projection` run against the untouched
# `~/central/nwc-internal/OPERATING-MODEL.md` on 2026-08-10 reported 8 findings
# and exited 1:
#
#   [state-banner]              :9   > ## ⇢ STATE UPDATE 2026-07-08 (read first — supersedes …)
#   [state-banner]              :29  > ## ⇢ STATE UPDATE 2026-07-01 (read this first — supersedes …)
#   [projection-contradiction]  :14  claims the loop is paused; measured ARMED on mini
#   [projection-contradiction]  :90  claims the loop is paused; measured ARMED on mini
#   [projection-contradiction]  :21  issue map stops at #53; highest issue opened is ops#332
#   [projection-contradiction]  :42  issue map stops at #4;  highest issue opened is ops#332
#   [projection-contradiction]  :78  calls NWP-ADR-0024 Proposed; its Status line says Accepted
#   [unprojected-state]              no generated state block in …
#
# That run needed the live estate (an ssh probe to the ai-host, the forge API).
# The cases below reproduce every one of those SHAPES on fixtures, so the red is
# repeatable on a CI runner with no network and no ~/central — while staying
# honest about the difference: a fixture proves the RULE fires, the live run
# proved the DOCUMENT was wrong.
#
# THE PROPERTY THAT MATTERS MOST is case 4: the rules are conditional on a
# MEASUREMENT, not on a literal. Feed the same "the loop is paused" prose a
# measurement that says paused, and the check is silent. A lint carrying its own
# hard-coded copy of the fact would be exactly the stale literal it polices —
# and would go on firing forever after somebody pauses the loop for real.

setup() {
    PROJECT_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    export PROJECT_ROOT
    OM_LIB="${PROJECT_ROOT}/lib/operating-model.sh"
    OMV="${PROJECT_ROOT}/scripts/commands/operating-model.sh"
    DT="${PROJECT_ROOT}/scripts/commands/doc-truth.sh"
    HOOK="${PROJECT_ROOT}/scripts/hooks/userpromptsubmit-om-freshness.sh"
    TMP="$(mktemp -d)"
    # Every test runs OFFLINE and OFF the operator's private tree.
    export NWP_SECRETS_FILE="$TMP/no-such-secrets.yml"
    export NWP_OPERATING_MODEL_FILE="$TMP/doc.md"
}

teardown() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; return 0; }

# A measurement fixture in the exact shape a section emits.
loop_json() { # $1=state $2=blind
    printf '{"section":"loop","provenance":{"source":"fixture","at":"2026-08-10T00:00:00Z","blind":"%s"},"host":"mini","state":"%s","cron":"armed","oversight":""}' "${2:-}" "${1:-}"
}
issues_json() { # $1=high_water $2=blind
    printf '{"section":"issues","provenance":{"source":"fixture","at":"2026-08-10T00:00:00Z","blind":"%s"},"high_water":"%s","open_total":"180","decisions_open":"30"}' "${2:-}" "${1:-}"
}
adrs_json() {
    printf '{"section":"adrs","provenance":{"source":"fixture","at":"2026-08-10T00:00:00Z","blind":""},"accepted":"28","proposed":"3","superseded":"5","other":"0","proposed_list":""}'
}
# Run om_lint with the measurements stated, so a case tests ONE rule.
lint_with() { # $1=doc $2=loop-json $3=issues-json
    OM_S_LOOP="$2" OM_S_ISSUES="$3" OM_S_ADRS="$(adrs_json)" \
    bash -c 'source "$1"; OM_S_LOOP="$2"; OM_S_ISSUES="$3"; OM_S_ADRS="$4"; om_lint "$5"' \
        _ "$OM_LIB" "$2" "$3" "$(adrs_json)" "$1"
}

# ── 1. the banner rule ───────────────────────────────────────────────────────
@test "1. a STATE UPDATE banner is itself a finding (the body should have been regenerated)" {
    cat > "$TMP/doc.md" <<'EOF'
# Operating model
> ## ⇢ STATE UPDATE 2026-07-08 (read first — supersedes the banners + §3/§4/§8 below)
> - something the body below gets wrong.
## 1. North Star
Every unit of work is a `pl` command.
EOF
    run lint_with "$TMP/doc.md" "$(loop_json armed)" "$(issues_json 332)"
    [ "$status" -ne 0 ]
    [[ "$output" == *"state-banner"* ]]
    [[ "$output" == *"$TMP/doc.md:2"* ]]
}

@test "2. a document with no banner and no state prose produces no banner finding" {
    cat > "$TMP/doc.md" <<'EOF'
# Operating model
## 1. North Star
Every unit of work is a `pl` command, a GitLab issue, or a `pl status` signal.
EOF
    run lint_with "$TMP/doc.md" "$(loop_json armed)" "$(issues_json 332)"
    [[ "$output" != *"state-banner"* ]]
}

# ── 2. the contradiction rules, and their conditionality ─────────────────────
@test "3. 'the loop is paused' is a finding when the loop is MEASURED armed" {
    printf '# doc\nThe loop is **paused** (`.loop-paused`, since 2026-05-22).\n' > "$TMP/doc.md"
    run lint_with "$TMP/doc.md" "$(loop_json armed)" "$(issues_json 332)"
    [ "$status" -ne 0 ]
    [[ "$output" == *"projection-contradiction"* ]]
    [[ "$output" == *"claims the loop is paused; measured ARMED"* ]]
}

@test "4. the SAME sentence is silent when the loop is MEASURED paused (conditional on the measurement, not a literal)" {
    printf '# doc\nThe loop is **paused** (`.loop-paused`, since 2026-05-22).\n' > "$TMP/doc.md"
    run lint_with "$TMP/doc.md" "$(loop_json paused)" "$(issues_json 332)"
    [[ "$output" != *"claims the loop is paused"* ]]
}

@test "5. a blind loop probe STANDS THE RULE DOWN and reports CANNOT VERIFY (never a finding)" {
    printf '# doc\nThe loop is **paused** (`.loop-paused`).\n' > "$TMP/doc.md"
    run lint_with "$TMP/doc.md" "$(loop_json '' 'ssh to the loop host failed')" "$(issues_json 332)"
    [[ "$output" != *"claims the loop is paused"* ]]
    [[ "$output" == *"projection-blind"* ]]
    [[ "$output" == *"loop state unmeasured"* ]]
}

@test "6. an issue map that stops below the high-water mark is a finding" {
    printf '# doc\n- **Issue map (2026-07-08):** live queue runs to **ops#53**.\n' > "$TMP/doc.md"
    run lint_with "$TMP/doc.md" "$(loop_json armed)" "$(issues_json 332)"
    [ "$status" -ne 0 ]
    [[ "$output" == *"issue map stops at #53; highest issue opened is ops#332"* ]]
}

@test "7. the same map is silent once the high-water mark is not above it" {
    printf '# doc\n- **Issue map:** live queue runs to **ops#53**.\n' > "$TMP/doc.md"
    run lint_with "$TMP/doc.md" "$(loop_json armed)" "$(issues_json 53)"
    [[ "$output" != *"issue map stops"* ]]
}

@test "8. a blind issue probe stands its rule down too" {
    printf '# doc\n- **Issue map:** live queue runs to **ops#53**.\n' > "$TMP/doc.md"
    run lint_with "$TMP/doc.md" "$(loop_json armed)" "$(issues_json '' 'the forge refused the issue list')"
    [[ "$output" != *"issue map stops"* ]]
    [[ "$output" == *"issue queue unmeasured"* ]]
}

@test "9. calling an Accepted ADR 'Proposed' is a finding (the status line is the oracle)" {
    # NWP-ADR-0001 is Accepted in this tree; the check reads its Status line, not a copy.
    printf '# doc\nDeploy authority: `docs/decisions/0001-*` (**Proposed**, gated on A14).\n' > "$TMP/doc.md"
    run lint_with "$TMP/doc.md" "$(loop_json armed)" "$(issues_json 332)"
    [ "$status" -ne 0 ]
    [[ "$output" == *"calls NWP-ADR-0001 Proposed; its Status line says Accepted"* ]]
}

@test "10. an ADR mentioned with no status claim is not a finding" {
    printf '# doc\nSee NWP-ADR-0001 for the DDEV decision.\n' > "$TMP/doc.md"
    run lint_with "$TMP/doc.md" "$(loop_json armed)" "$(issues_json 332)"
    [[ "$output" != *"calls NWP-ADR-0001"* ]]
}

@test "11. the escape hatch lets a document quote a stale sentence in order to explain it" {
    printf '# doc\nThe old banner said "the loop is paused" — it was wrong. <!-- doc-truth:projection-ok -->\n' > "$TMP/doc.md"
    run lint_with "$TMP/doc.md" "$(loop_json armed)" "$(issues_json 332)"
    [[ "$output" != *"claims the loop is paused"* ]]
}

# ── 3. the staleness gate ────────────────────────────────────────────────────
@test "12. a document with no generated block is UNPROJECTED — exit 2 CANNOT VERIFY, never green" {
    printf '# doc\nDoctrine only.\n' > "$TMP/doc.md"
    run bash -c 'source "$1"; om_status "$2"; echo "verdict=$OM_VERDICT rc=$?"' _ "$OM_LIB" "$TMP/doc.md"
    [[ "$output" == *"verdict=MISSING"* ]]
    run bash -c 'source "$1"; om_status "$2"' _ "$OM_LIB" "$TMP/doc.md"
    [ "$status" -eq 2 ]
}

@test "13. sync writes a block that immediately verifies FRESH" {
    printf '# doc\nDoctrine only.\n' > "$TMP/doc.md"
    run bash -c 'source "$1"; om_sync "$2" >/dev/null; om_status "$2"; echo "$OM_VERDICT"' _ "$OM_LIB" "$TMP/doc.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FRESH"* ]]
    grep -q 'BEGIN GENERATED STATE' "$TMP/doc.md"
    grep -q 'nwp:om-state v1' "$TMP/doc.md"
}

@test "14. a hand edit INSIDE the markers is detected (checksum), exit 2 TAMPERED" {
    printf '# doc\nDoctrine only.\n' > "$TMP/doc.md"
    bash -c 'source "$1"; om_sync "$2" >/dev/null' _ "$OM_LIB" "$TMP/doc.md"
    # The precise attack: quietly improve a generated figure by hand.
    sed -i 's/^| `mini` |/| `mini-EDITED` |/' "$TMP/doc.md"
    printf 'a hand-added line inside the block\n' >> "$TMP/doc.md.none" 2>/dev/null || true
    sed -i "s|^### Current state — GENERATED, not asserted|### Current state — GENERATED, not asserted (edited)|" "$TMP/doc.md"
    run bash -c 'source "$1"; om_status "$2"; echo "verdict=$OM_VERDICT"' _ "$OM_LIB" "$TMP/doc.md"
    [[ "$output" == *"verdict=TAMPERED"* ]]
    run bash -c 'source "$1"; om_status "$2"' _ "$OM_LIB" "$TMP/doc.md"
    [ "$status" -eq 2 ]
}

@test "15. a block past its horizon is STALE, exit 1" {
    printf '# doc\nDoctrine only.\n' > "$TMP/doc.md"
    bash -c 'source "$1"; om_sync "$2" >/dev/null' _ "$OM_LIB" "$TMP/doc.md"
    # Age it by rewriting only the meta line's timestamp, then re-stamp the
    # checksum so this tests STALENESS and not tampering.
    run bash -c '
        source "$1"; f="$2"
        body="$(om_block_body "$f")"
        sha="$(printf "%s" "$body" | sha256sum | awk "{print \$1}")"
        sed -i "s|^<!-- nwp:om-state .*|<!-- nwp:om-state v1 generated=2026-01-01T00:00:00Z horizon_min=1440 sha256=${sha} -->|" "$f"
        om_status "$f"; rc=$?; echo "verdict=$OM_VERDICT age=$OM_AGE_MIN"; exit $rc' _ "$OM_LIB" "$TMP/doc.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"verdict=STALE"* ]]
}

@test "16. an unreadable document is CANNOT VERIFY, not clean" {
    run bash -c 'source "$1"; om_status "/no/such/file.md"; rc=$?; echo "$OM_VERDICT"; exit $rc' _ "$OM_LIB"
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREADABLE"* ]]
}

# ── 4. the injector ──────────────────────────────────────────────────────────
@test "17. inject on a STALE document says so loudly and refuses to present it as current" {
    printf '# doc\nDoctrine only.\n' > "$TMP/doc.md"
    run env NWP_OPERATING_MODEL_FILE="$TMP/doc.md" bash "$OMV" inject --no-refresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"state gate: MISSING"* ]]
    [[ "$output" == *"DO NOT treat any state claim"* ]]
}

@test "18. inject on a FRESH document confirms the age and does not shout" {
    printf '# doc\nDoctrine only.\n' > "$TMP/doc.md"
    bash -c 'source "$1"; om_sync "$2" >/dev/null' _ "$OM_LIB" "$TMP/doc.md"
    run env NWP_OPERATING_MODEL_FILE="$TMP/doc.md" bash "$OMV" inject --no-refresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"state gate: FRESH"* ]]
    [[ "$output" != *"DO NOT treat"* ]]
}

@test "19. inject ALWAYS exits 0 — a hook that fails hard suppresses the very warning it exists to give" {
    run env NWP_OPERATING_MODEL_FILE="/no/such/dir/doc.md" bash "$OMV" inject --no-refresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"state gate:"* ]]
}

# ── 5. the hook ──────────────────────────────────────────────────────────────
@test "20. the hook is silent on a prompt that is not ops work" {
    run bash -c 'printf "%s" "{\"prompt\":\"rename a css class\"}" | "$1"' _ "$HOOK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "21. the hook fires on an ops#N prompt and carries the verdict into the turn" {
    printf '# doc\nDoctrine only.\n' > "$TMP/doc.md"
    run env NWP_OPERATING_MODEL_FILE="$TMP/doc.md" bash -c \
        'printf "%s" "{\"prompt\":\"please look at nwp/ops#319\"}" | "$1"' _ "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OPERATING-MODEL state gate"* ]]
}

@test "22. the hook says CANNOT VERIFY rather than nothing when it cannot run the verb" {
    run env NWP_PL="/no/such/pl" bash -c \
        'printf "%s" "{\"prompt\":\"ops#319\"}" | "$1"' _ "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

# ── 6. the doc-truth face ────────────────────────────────────────────────────
@test "23. pl doc-truth --projection exits 2 CANNOT VERIFY on an unreadable corpus" {
    run bash "$DT" --projection=/no/such/operating-model.md
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "24. pl doc-truth --projection reports blind measurements as UNCHECKED (exit 2), not clean" {
    # No forge token and no loop host reachable from a bats runner: the issue
    # and loop probes are blind by construction here.
    printf '# doc\nDoctrine only.\n' > "$TMP/doc.md"
    bash -c 'source "$1"; om_sync "$2" >/dev/null' _ "$OM_LIB" "$TMP/doc.md"
    run env NWP_OPERATING_MODEL_LOOP_HOST="no-such-role" NWP_OPERATING_MODEL_BUDGET_SEC=15 \
        bash "$DT" --projection="$TMP/doc.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CANNOT VERIFY"* || "$output" == *"UNCHECKED"* ]]
}

@test "25. the verb is dispatchable, so pl commands (the doc-truth oracle) can see it" {
    run bash -c '"$1"/pl commands 2>/dev/null | grep -qE "^ *operating-model( |$)"' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
}

@test "26. --help does not need a document, a network or a token" {
    run env NWP_OPERATING_MODEL_FILE=/no/such/file bash "$OMV" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"operating-model"* ]]
}
