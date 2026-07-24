#!/usr/bin/env bats
################################################################################
# Unit tests for lib/sanitizers/files-secrets.sh — the artifact-level secret
# scrub for the FILE half of an export (defence in depth alongside the DB
# sanitizers and lib/pii-gate.sh). Verifies it:
#   - redacts secret VALUES in files/sync/*.yml, auth.json and .env (KEY-based)
#   - redacts credential SHAPES (glpat-…, ghp_…, AWS/Google keys) under a
#     NON-secret key (the composer auth.json host→token case)
#   - deletes the indented BODY of YAML block/folded scalars under a secret key
#     (api_key: | / key: >-) — and verify refuses a surviving body even when the
#     key line already looks redacted (scrub-bug simulation)
#   - covers inline flow mappings ({gitlab_token: …}) and DSN userinfo
#     credentials (scheme://user:pass@host), shape- and key-based
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
    # Covers the three adversarial-verify classes: a block scalar under a secret
    # key, an inline flow mapping, and DSN-embedded credentials — all in one
    # config-sync file so the idempotence + verify-after-scrub tests sweep them.
    cat > "$ROOT/web/sites/default/files/sync/nwc_bridge.settings.yml" <<'EOF'
bridge:
  push: {auth_token: glpat-InlineFlow0123456789, mode: live}
private_key: |
  block-body-secret-AAAA
  block-body-secret-BBBB
dsn: mysql://svc:S3cretDsnPw@db.internal/prod
after_block: kept
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

# ── adversarial-verify classes: block scalars, flow mappings, DSN creds ───────

@test "scrub deletes the indented BODY of a literal block scalar under a secret key (api_key: |)" {
    local f="$ROOT/web/sites/default/files/sync/block.yml"
    cat > "$f" <<'EOF'
langcode: en
api_key: |
  line1-very-secret-material
  line2-very-secret-material
after: kept
EOF
    files_secrets_scrub "$ROOT"
    run grep -F 'very-secret-material' "$f"
    [ "$status" -ne 0 ]
    grep -q 'langcode: en' "$f"
    grep -q 'after: kept' "$f"
    grep -qF "api_key: $FILES_SECRETS_REDACT" "$f"
}

@test "scrub deletes a FOLDED scalar body under a secret key (key: >-)" {
    local f="$ROOT/web/sites/default/files/sync/folded.yml"
    printf 'client_secret: >-\n  folded-secret-body-value\nnext: ok\n' > "$f"
    files_secrets_scrub "$ROOT"
    run grep -F 'folded-secret-body-value' "$f"
    [ "$status" -ne 0 ]
    grep -q 'next: ok' "$f"
}

@test "verify FAILS on an unscrubbed block scalar under a secret key" {
    rm -rf "$ROOT"; mkdir -p "$ROOT/web/sites/default/files/sync"
    printf 'api_key: |\n  cleartext-block-secret\n' > "$ROOT/web/sites/default/files/sync/b.yml"
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 1 ]
}

@test "verify FAILS while a block body survives under a REDACTED key (scrub-bug simulation)" {
    rm -rf "$ROOT"; mkdir -p "$ROOT/web/sites/default/files/sync"
    # The key line LOOKS clean (placeholder) but the body leaked — verify must
    # not vouch for the scrub's own output.
    printf 'api_key: %s\n  leaked-block-body-secret\n' "$FILES_SECRETS_REDACT" \
        > "$ROOT/web/sites/default/files/sync/bug.yml"
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 1 ]
}

@test "scrub + verify cover an inline flow mapping (shape token under {})" {
    rm -rf "$ROOT"; mkdir -p "$ROOT/web/sites/default/files/sync"
    local f="$ROOT/web/sites/default/files/sync/flow.yml"
    printf 'bridge: {gitlab_token: glpat-FlowMapSecret1234567890, url: kept}\n' > "$f"
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 1 ]
    files_secrets_scrub "$ROOT"
    run grep -F 'glpat-FlowMapSecret' "$f"
    [ "$status" -ne 0 ]
    grep -qF 'url: kept' "$f"
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 0 ]
}

@test "scrub + verify catch a NON-shape secret in a flow mapping (key-based)" {
    rm -rf "$ROOT"; mkdir -p "$ROOT/web/sites/default/files/sync"
    local f="$ROOT/web/sites/default/files/sync/flow2.yml"
    printf 'thing: {client_secret: plainNotAShape123, name: ok}\n' > "$f"
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 1 ]
    files_secrets_scrub "$ROOT"
    run grep -F 'plainNotAShape123' "$f"
    [ "$status" -ne 0 ]
    grep -qF 'name: ok' "$f"
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 0 ]
}

@test "scrub + verify catch DSN-embedded credentials (scheme://user:pass@host)" {
    rm -rf "$ROOT"; mkdir -p "$ROOT/web/sites/default/files/sync"
    printf 'db_url: mysql://produser:pr0dpass@db.example.com/main\n' \
        > "$ROOT/web/sites/default/files/sync/dsn.yml"
    printf 'DATABASE_URL=pgsql://u1:hunter2@10.0.0.5/app\n' > "$ROOT/.env"
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 1 ]
    files_secrets_scrub "$ROOT"
    run grep -F 'pr0dpass' "$ROOT/web/sites/default/files/sync/dsn.yml"
    [ "$status" -ne 0 ]
    run grep -F 'hunter2' "$ROOT/.env"
    [ "$status" -ne 0 ]
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 0 ]
}

@test "DSN redaction leaves a plain https URL (no userinfo) alone" {
    rm -rf "$ROOT"; mkdir -p "$ROOT/web/sites/default/files/sync"
    local f="$ROOT/web/sites/default/files/sync/url.yml"
    printf "endpoint: 'https://example.com/hook'\n" > "$f"
    files_secrets_scrub "$ROOT"
    grep -qF "endpoint: 'https://example.com/hook'" "$f"
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 0 ]
}

@test "verify catches an UPPERCASE secret key in .env (SECRET_TOKEN=…)" {
    rm -rf "$ROOT"; mkdir -p "$ROOT"
    printf 'SECRET_TOKEN=notAShapedValueButLive42\n' > "$ROOT/.env"
    run files_secrets_verify "$ROOT"
    [ "$status" -eq 1 ]
}

@test "standalone: scrub-then-self-verify exits 0 and reports clean" {
    run bash "${BATS_TEST_DIRNAME}/../../lib/sanitizers/files-secrets.sh" "$ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scrub + verify clean"* ]]
}

@test "key-family vocabulary: signing_key block scalar scrubbed AND caught by verify" {
  d="$BATS_TEST_TMPDIR/keyfam"; mkdir -p "$d/files/sync"
  printf 'signing_key: |\n  -----BEGIN FAKE-----\n  abc123secretbody\n  -----END FAKE-----\nname: ok\n' > "$d/files/sync/x.yml"
  run bash "${BATS_TEST_DIRNAME}/../../lib/sanitizers/files-secrets.sh" --verify "$d"   # raw file must FAIL
  [ "$status" -ne 0 ]
  run bash "${BATS_TEST_DIRNAME}/../../lib/sanitizers/files-secrets.sh" "$d"            # scrub+self-verify must PASS
  [ "$status" -eq 0 ]
  ! grep -q "abc123secretbody" "$d/files/sync/x.yml"
  grep -q "name: ok" "$d/files/sync/x.yml"
}
