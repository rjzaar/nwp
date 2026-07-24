#!/usr/bin/env bats
################################################################################
# Unit tests for lib/sanitizers/files-secrets.sh — the artifact-level secret
# scrub for the FILE half of an export (defence in depth alongside the DB
# sanitizers and lib/pii-gate.sh). Verifies it:
#   - redacts secret VALUES in files/sync/*.yml, auth.json and .env (KEY-based)
#   - redacts credential SHAPES (glpat-…, ghp_…, AWS/Google keys) under a
#     NON-secret key (the composer auth.json host→token case)
#   - leaves non-secret config AND non-target files untouched
#   - keeps auth.json valid JSON after redaction
#   - is idempotent, and files_secrets_verify is FAIL-CLOSED on a leaked secret.
################################################################################

source "${BATS_TEST_DIRNAME}/../../lib/sanitizers/files-secrets.sh"

setup() {
    ROOT="$(mktemp -d)"
    mkdir -p "$ROOT/web/sites/default/files/sync" "$ROOT/web/config"
    cat > "$ROOT/web/sites/default/files/sync/nwc_feedback.agent_fast_path.yml" <<'EOF'
langcode: en
status: true
agent_fast_path:
  token: glpat-AbCdEf0123456789xyzQ
  webhook_secret: s3cr3tWebhookValue12345
  api_key: plain-looking-but-secret-value
  password_reset_enabled: true
  endpoint: 'https://example.com/hook'
EOF
    cat > "$ROOT/auth.json" <<'EOF'
{
  "http-basic": {
    "git.nwpcode.org": { "username": "bot", "password": "glpat-ZZZ1122334455667788QQ" }
  },
  "gitlab-token": { "git.nwpcode.org": "glpat-deadbeefdeadbeefdead00" }
}
EOF
    cat > "$ROOT/.env" <<'EOF'
APP_ENV=prod
DATABASE_URL=mysql://u:p@h/db
API_KEY=AIzaSyA1234567890abcdefghijklmnopqrstuvw
export SECRET_TOKEN=abcdef0123456789abcdef
MAIL_ENABLED=true
EOF
    # A non-target file: same secret-looking key, but NOT under files/sync/ →
    # must be left ALONE (proves the scope restriction).
    cat > "$ROOT/web/config/other.yml" <<'EOF'
token: glpat-SHOULDNOTBETOUCHED0000
EOF
}
teardown() { rm -rf "$ROOT"; }

# ── scrub redacts each target type ─────────────────────────────────────────────

@test "scrub redacts a glpat token in files/sync yaml" {
    run files_secrets_scrub "$ROOT"
    [ "$status" -eq 0 ]
    run grep -c 'glpat-AbCdEf' "$ROOT/web/sites/default/files/sync/nwc_feedback.agent_fast_path.yml"
    [ "$output" -eq 0 ]
}

@test "scrub redacts webhook_secret and api_key (key-based) in files/sync yaml" {
    files_secrets_scrub "$ROOT"
    local f="$ROOT/web/sites/default/files/sync/nwc_feedback.agent_fast_path.yml"
    run grep -F 's3cr3tWebhookValue12345' "$f"
    [ "$status" -ne 0 ]
    run grep -F 'plain-looking-but-secret-value' "$f"
    [ "$status" -ne 0 ]
}

@test "scrub leaves NON-secret yaml keys/values intact" {
    files_secrets_scrub "$ROOT"
    local f="$ROOT/web/sites/default/files/sync/nwc_feedback.agent_fast_path.yml"
    grep -q 'password_reset_enabled: true' "$f"
    grep -q "endpoint: 'https://example.com/hook'" "$f"
    grep -q 'langcode: en' "$f"
}

@test "scrub redacts auth.json password (key) AND host→token map (shape)" {
    files_secrets_scrub "$ROOT"
    run grep -c 'glpat-' "$ROOT/auth.json"
    [ "$output" -eq 0 ]
}

@test "scrubbed auth.json is still valid JSON" {
    files_secrets_scrub "$ROOT"
    if command -v python3 >/dev/null 2>&1; then
        run python3 -c "import json,sys; json.load(open('$ROOT/auth.json'))"
        [ "$status" -eq 0 ]
    fi
}

@test "scrub redacts .env secret keys and shape-matching values" {
    files_secrets_scrub "$ROOT"
    local f="$ROOT/.env"
    run grep -F 'AIzaSyA1234567890abcdefghijklmnopqrstuvw' "$f"
    [ "$status" -ne 0 ]
    run grep -F 'abcdef0123456789abcdef' "$f"
    [ "$status" -ne 0 ]
    # non-secret env lines survive
    grep -q '^APP_ENV=prod' "$f"
    grep -q '^MAIL_ENABLED=true' "$f"
}

@test "scrub does NOT touch a yaml OUTSIDE files/sync/" {
    files_secrets_scrub "$ROOT"
    grep -q 'glpat-SHOULDNOTBETOUCHED0000' "$ROOT/web/config/other.yml"
}

# ── verify: fail-closed contract ───────────────────────────────────────────────

@test "verify FAILS (non-zero) on an un-scrubbed tree with live secrets" {
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 1 ]
}

@test "verify PASSES after scrub" {
    files_secrets_scrub "$ROOT"
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 0 ]
}

@test "verify PASSES on a clean tree with only non-secret config" {
    rm -rf "$ROOT"; mkdir -p "$ROOT"   # drop the setup fixtures incl. dotfiles
    mkdir -p "$ROOT/web/sites/default/files/sync"
    printf 'langcode: en\nstatus: true\n' > "$ROOT/web/sites/default/files/sync/system.site.yml"
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 0 ]
}

# ── idempotence + edge cases ───────────────────────────────────────────────────

@test "scrub is idempotent (second run is a no-op and stays clean)" {
    files_secrets_scrub "$ROOT"
    cp -r "$ROOT" "$ROOT.after1"
    files_secrets_scrub "$ROOT"
    run diff -r "$ROOT.after1" "$ROOT"
    [ "$status" -eq 0 ]
    rm -rf "$ROOT.after1"
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 0 ]
}

@test "scrub catches a shape-only leak (token under a NON-secret key in files/sync)" {
    local f="$ROOT/web/sites/default/files/sync/leak.yml"
    printf 'some_field: glpat-1234567890abcdefABCD\n' > "$f"
    files_secrets_scrub "$ROOT"
    run grep -F 'glpat-1234567890abcdefABCD' "$f"
    [ "$status" -ne 0 ]
}

@test "scrub redacts .env.local variant" {
    printf 'GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\n' > "$ROOT/.env.local"
    files_secrets_scrub "$ROOT"
    run grep -F 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' "$ROOT/.env.local"
    [ "$status" -ne 0 ]
}

@test "scrub on a missing root is fail-closed (exit 2)" {
    run files_secrets_scrub "$ROOT/does-not-exist"
    [ "$status" -eq 2 ]
}

@test "verify on a missing root is fail-closed (exit 2)" {
    run files_secrets_verify "$ROOT/does-not-exist"
    [ "$status" -eq 2 ]
}

@test "standalone: scrub-then-self-verify exits 0 and reports clean" {
    run bash "${BATS_TEST_DIRNAME}/../../lib/sanitizers/files-secrets.sh" "$ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scrub + verify clean"* ]]
}
