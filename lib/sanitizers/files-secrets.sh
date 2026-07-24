#!/bin/bash
# NOTE: sourced library — deliberately NO `set -euo pipefail`. Forcing errexit
# onto a sourcing caller (and the bats runner) leaks failures across the process
# boundary (the ops#111 lesson; same rationale as lib/pii-gate.sh). Every function
# does explicit error handling and never relies on the caller's shell options.
################################################################################
# lib/sanitizers/files-secrets.sh — scrub secrets out of the FILE half of an
# export artifact (defence in depth for the ADR-0026 dev/AI-tier publish flow).
#
# The DB sanitizers (lib/sanitizers/<site>.sh) scrub the *database*; this shared
# step scrubs the *file tree* that ships alongside it. A Drupal config-sync YAML
# living under a site's PUBLIC files (…/files/sync/*.yml) — plus any auth.json or
# .env that slips into the export — can carry LIVE credentials. Real incident:
# a config-sync file (nwc_feedback.agent_fast_path.yml) carried a live glpat
# token AND a webhook_secret in files/sync. The files are already chmod-locked
# on prod and nginx-denied over HTTP; this scrub is the third, artifact-level
# layer so a copy that DOES cross the prod boundary carries no live secret.
#
# Two INDEPENDENT redaction passes per target file (either alone is a backstop):
#   1. KEY-BASED   — redact a value whose KEY ends in a secret word
#                    (token / secret / password / api_key / webhook_secret / …),
#                    covering YAML `key: value`, YAML block/folded scalars
#                    (`key: |` / `key: >-` — the indicator line is redacted AND
#                    the indented body is DELETED), YAML/JSON inline flow
#                    mappings (`{gitlab_token: …}` mid-line after `{` or `,`),
#                    env `KEY=value`, and JSON `"k":"v"`.
#   2. SHAPE-BASED — redact any value MATCHING a known credential shape (glpat-…,
#                    ghp_…, slack xox…, AWS AKIA…, Google AIza…, PEM header, and
#                    DSN userinfo `scheme://user:pass@`) wherever it appears,
#                    regardless of key — catches a token nested under a
#                    NON-secret key (e.g. composer auth.json's host→token maps,
#                    where the key is a hostname, or a `db_url:` DSN).
#
# Target files under <root-dir>:
#   */files/sync/*.yml  */files/sync/*.yaml   (config-sync only — not every YAML)
#   auth.json           (anywhere)
#   .env  .env.*        (anywhere)
#
# Fail-closed: files_secrets_verify returns non-zero if ANY secret-shaped value,
# un-redacted secret KEY (line-anchored OR inside a flow mapping), DSN userinfo,
# or surviving block-scalar body under a secret key remains — so a scrub bug can
# never vouch for its own output, mirroring the two-gate model in lib/pii-gate.sh.
#
# WIRING (honest map — where these functions actually run today):
#   - files_secrets_verify:
#       * scripts/commands/backup.sh (local DDEV path) — WARNING gate over the
#         tree being tarred. Backups stay FAITHFUL (never scrubbed); the gate
#         tells the operator loudly when the archive will carry a live secret.
#       * scripts/commands/server-backup.sh — pre-snapshot fail-LOUD warning
#         (never aborts: DR must not be blocked by a leftover secret; the restic
#         --exclude there already keeps the secret-bearing files OUT of the
#         snapshot). The warning exists so the credential gets rotated/removed
#         at source.
#   - files_secrets_scrub has NO production caller yet. No export flow ships a
#     file tree today (standard.sh exports a DB dump only; moodle-full.sh bundles
#     db.sql.gz + an omit-and-placeholder manifest with zero user-file bytes).
#     scrub is the ready building block for the FUTURE sanitized file-tree
#     publish step (ADR-0026): when server-publish.sh (or a successor) exports a
#     file tree, run files_secrets_scrub then files_secrets_verify over the
#     export root BEFORE signing/shipping. Do not call scrub on backups.
#
# Usage:
#   files_secrets_scrub  <root-dir>          # redact in place under <root-dir>
#   files_secrets_verify <root-dir>          # scan only; non-zero if a secret survives
#   bash lib/sanitizers/files-secrets.sh [--verify] <root-dir>
#
# Returns: 0 ok/clean · 1 secret survived (verify) · 2 usage / unreadable root.
################################################################################

# Redaction placeholder. Contains no character special to our sed delimiter (#)
# or replacement (& \), and matches none of the SHAPE patterns below, so a
# re-scan of a scrubbed file is stable (idempotent) and never self-trips verify.
FILES_SECRETS_REDACT='***REDACTED-BY-SANITIZER***'

# Secret KEY tail: a key is secret when it ENDS in one of these words (optionally
# prefixed, e.g. db_password, oauth_token, webhook_secret). Anchoring to the tail
# keeps innocuous flags like `password_reset_enabled` (ends "enabled") out.
FILES_SECRETS_KEYWORD='(webhook[_-]?secret|api[_-]?key|apikey|client[_-]?secret|access[_-]?token|refresh[_-]?token|auth[_-]?token|oauth[_-]?token|private[_-]?key|secret|token|password|passwd|passphrase)'

# Known credential SHAPES — redacted wherever they appear (case-sensitive; these
# prefixes are fixed-case by their issuers). This is the backstop that catches a
# token filed under a non-secret key.
FILES_SECRETS_SHAPES=(
    'glpat-[A-Za-z0-9_-]{20,}'                 # GitLab personal/project access token
    'gh[posru]_[A-Za-z0-9]{20,}'               # GitHub token (ghp_/gho_/ghs_/ghr_/ghu_)
    'github_pat_[A-Za-z0-9_]{20,}'             # GitHub fine-grained PAT
    'xox[baprs]-[A-Za-z0-9-]{10,}'             # Slack token
    'AKIA[0-9A-Z]{16}'                         # AWS access key id
    'AIza[0-9A-Za-z_-]{35}'                    # Google API key
    'sk-[A-Za-z0-9]{20,}'                      # generic "sk-"-prefixed API secret key
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'       # PEM private key header
    # DSN userinfo — mysql://user:pass@host, pgsql://:pass@host, redis://… —
    # the `user:pass` credential pair before `@` is credential-shaped wherever
    # it appears (catches a DSN under a NON-secret key like `db_url:` or
    # `DATABASE_URL=`). Redaction consumes `scheme://user:pass@` whole, so the
    # scrubbed remainder has no `://` and can never re-trip this pattern.
    '[A-Za-z][A-Za-z0-9+.-]*://[^/@[:space:]]*:[^/@[:space:]]+@'
)

# Enumerate the target files under a root. Prints newline-separated paths. Kept
# separate so scrub and verify agree on exactly the same file set.
_files_secrets_targets() { # $1 = root
    local root="$1"
    [ -d "$root" ] || return 0
    find "$root" -type f \( \
            -path '*/files/sync/*.yml'  -o \
            -path '*/files/sync/*.yaml' -o \
            -name 'auth.json'           -o \
            -name '.env'                -o \
            -name '.env.*' \
        \) 2>/dev/null
}

# YAML block/folded scalars — a secret KEY introducing a block scalar
# (`api_key: |`, `signing_key: >-` …) keeps the secret in the INDENTED BODY, not
# on the key line, so a line-anchored sed can never reach it. Redact the
# indicator line to the placeholder AND DELETE the body lines (everything more
# indented than the key, blank lines included) — fail-closed: the body is
# dropped, never kept.
_files_secrets_scrub_yaml_blocks() { # $1 = file
    local f="$1" tmp
    tmp="$(mktemp)" || return 1
    if ! awk -v red="$FILES_SECRETS_REDACT" \
             -v keyre="^[[:space:]]*\"?[a-z0-9_.-]*${FILES_SECRETS_KEYWORD}\"?[[:space:]]*:" '
        function ind(s) { match(s, /^[ ]*/); return RLENGTH }
        {
            if (skip) {
                if ($0 ~ /^[[:space:]]*$/) next        # blank line inside the block
                if (ind($0) > skipind) next            # block body -> drop
                skip = 0
            }
            if (tolower($0) ~ keyre) {
                val = $0; sub(/^[^:]*:[[:space:]]*/, "", val)
                if (val ~ /^[|>]/) {                   # literal/folded indicator
                    head = $0; sub(/:.*$/, "", head)
                    print head ": " red
                    skip = 1; skipind = ind($0)
                    next
                }
            }
            print
        }' "$f" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
}

# Apply the SHAPE backstop to one file (all target types).
_files_secrets_scrub_shapes() { # $1 = file
    local f="$1" shape
    for shape in "${FILES_SECRETS_SHAPES[@]}"; do
        sed -E -i "s#${shape}#${FILES_SECRETS_REDACT}#g" "$f" 2>/dev/null || return 1
    done
    return 0
}

# Scrub one file, dispatching the KEY-based pass by file type, then the SHAPE pass.
_files_secrets_scrub_file() { # $1 = file
    local f="$1"
    [ -w "$f" ] || return 1
    case "$f" in
        *.yml|*.yaml)
            # Block/folded scalars FIRST (`key: |` / `key: >-`): redact the
            # indicator line and DELETE the indented body — a line-anchored sed
            # cannot reach the body, and the SHAPE pass only catches known
            # shapes, not an arbitrary secret string.
            _files_secrets_scrub_yaml_blocks "$f" || return 1
            # YAML `key: value` (key optionally quoted). Redact the whole scalar
            # value.
            sed -E -i \
                "s#^([[:space:]]*\"?[A-Za-z0-9_.-]*${FILES_SECRETS_KEYWORD}\"?[[:space:]]*:[[:space:]]*)[^[:space:]].*\$#\1${FILES_SECRETS_REDACT}#I" \
                "$f" 2>/dev/null || return 1
            # Inline FLOW mappings (`bridge: {gitlab_token: glpat-…, mode: x}`):
            # the secret key sits mid-line after `{` or `,`, invisible to the
            # line-anchored pass above. Redact the pair's value up to the next
            # `,` or `}`.
            sed -E -i \
                "s#([{,][[:space:]]*\"?[A-Za-z0-9_.-]*${FILES_SECRETS_KEYWORD}\"?[[:space:]]*:[[:space:]]*)[^,}]*#\\1${FILES_SECRETS_REDACT}#gI" \
                "$f" 2>/dev/null || return 1
            ;;
        auth.json|*/auth.json)
            # JSON string value — preserve the surrounding quotes so the file
            # stays parseable after redaction. NB: FILES_SECRETS_KEYWORD is itself
            # a capture group (\2), so the CLOSING quote is \3, not \2.
            sed -E -i \
                "s#(\"[A-Za-z0-9_.-]*${FILES_SECRETS_KEYWORD}\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")#\1${FILES_SECRETS_REDACT}\3#I" \
                "$f" 2>/dev/null || return 1
            ;;
        *.env|.env|*.env.*|.env.*)
            # env `KEY=value` (optional leading `export`).
            sed -E -i \
                "s#^([[:space:]]*(export[[:space:]]+)?[A-Za-z0-9_.-]*${FILES_SECRETS_KEYWORD}[[:space:]]*=).*\$#\1${FILES_SECRETS_REDACT}#I" \
                "$f" 2>/dev/null || return 1
            ;;
    esac
    _files_secrets_scrub_shapes "$f" || return 1
    return 0
}

################################################################################
# files_secrets_scrub <root-dir>
#   Redact secrets in place across every target file under <root-dir>.
#   Returns 0 on success, 2 on a missing/unreadable root, 1 if any file failed.
################################################################################
files_secrets_scrub() {
    local root="${1:-}"
    if [ -z "$root" ] || [ ! -d "$root" ]; then
        echo "files_secrets_scrub: usage: files_secrets_scrub <root-dir>" >&2
        return 2
    fi
    command -v sed  >/dev/null 2>&1 || { echo "files_secrets_scrub: sed missing"  >&2; return 2; }
    command -v find >/dev/null 2>&1 || { echo "files_secrets_scrub: find missing" >&2; return 2; }
    local f rc=0 n=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n + 1))
        if ! _files_secrets_scrub_file "$f"; then
            echo "files_secrets_scrub: FAILED to scrub $f" >&2
            rc=1
        fi
    done < <(_files_secrets_targets "$root")
    [ "$n" -gt 0 ] && echo "[files-secrets] scrubbed $n secret-bearing file(s) under $root"
    return "$rc"
}

# Detect a surviving block/folded-scalar BODY under a secret key: the key line
# still carries `|`/`>` (unscrubbed) or already shows the placeholder (i.e. a
# scrub bug redacted the indicator line but left the body), and the next
# non-blank line is MORE indented. Returns 1 on any survivor (fail-closed).
_files_secrets_verify_yaml_blocks() { # $1 = file
    awk -v red="$FILES_SECRETS_REDACT" \
        -v keyre="^[[:space:]]*\"?[a-z0-9_.-]*${FILES_SECRETS_KEYWORD}\"?[[:space:]]*:" '
        function ind(s) { match(s, /^[ ]*/); return RLENGTH }
        {
            if (pend) {
                if ($0 ~ /^[[:space:]]*$/) next
                if (ind($0) > pind) { bad = 1; exit }
                pend = 0
            }
            if (tolower($0) ~ keyre) {
                val = $0; sub(/^[^:]*:[[:space:]]*/, "", val)
                if (val ~ /^[|>]/ || index(val, red) == 1) { pend = 1; pind = ind($0) }
            }
        }
        END { exit bad ? 1 : 0 }' "$1" 2>/dev/null
}

################################################################################
# files_secrets_verify <root-dir>
#   Fail-closed scan: non-zero if any SHAPE-matching credential (incl. DSN
#   userinfo), any secret-KEY line or flow-mapping pair with a real
#   (non-placeholder, non-trivial) value, or any block-scalar body under a
#   secret key survives. Independent of the scrub so a scrub bug can't vouch
#   for its own output.
################################################################################
files_secrets_verify() {
    local root="${1:-}"
    if [ -z "$root" ] || [ ! -d "$root" ]; then
        echo "files_secrets_verify: usage: files_secrets_verify <root-dir>" >&2
        return 2
    fi
    command -v grep >/dev/null 2>&1 || { echo "files_secrets_verify: grep missing" >&2; return 2; }
    local f hits=0 shape
    local -a samples=()
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # 1) SHAPE — a credential-shaped value survived anywhere.
        for shape in "${FILES_SECRETS_SHAPES[@]}"; do
            if grep -Eq -- "$shape" "$f" 2>/dev/null; then
                hits=$((hits + 1))
                [ "${#samples[@]}" -lt 10 ] && samples+=("$f: credential-shaped value survived")
                break
            fi
        done
        # 2) KEY — a secret key still carries a value that is NOT the placeholder
        #    and NOT a trivial literal (empty / null / ~ / true / false / 0 / 1 /
        #    [] / {} / quoted-empty). Case-insensitive: SECRET_TOKEN= counts.
        local bad
        bad="$(grep -EniI -- \
            "^[[:space:]]*(export[[:space:]]+)?\"?[A-Za-z0-9_.-]*${FILES_SECRETS_KEYWORD}\"?[[:space:]]*[:=]" \
            "$f" 2>/dev/null \
          | grep -Fv -- "$FILES_SECRETS_REDACT" \
          | grep -Ev -- "[:=][[:space:]]*(\"\")?('')?[[:space:]]*(null|~|true|false|0|1|\[\]|\{\})?[[:space:]]*,?[[:space:]]*\$" \
          | head -5 || true)"
        if [ -n "$bad" ]; then
            hits=$((hits + 1))
            [ "${#samples[@]}" -lt 10 ] && samples+=("$f: secret key with un-redacted value")
        fi
        # 3) FLOW — a secret key inside an inline flow mapping (`{k_token: v}`)
        #    sits mid-line, invisible to the line-anchored check above. Extract
        #    each `{|, key: value` pair; any non-placeholder, non-trivial value
        #    is a survivor.
        local flowbad
        flowbad="$(grep -hioE -- \
            "[{,][[:space:]]*\"?[A-Za-z0-9_.-]*${FILES_SECRETS_KEYWORD}\"?[[:space:]]*:[[:space:]]*[^,}]+" \
            "$f" 2>/dev/null \
          | grep -Fv -- "$FILES_SECRETS_REDACT" \
          | grep -Ev -- ":[[:space:]]*(\"\")?('')?[[:space:]]*(null|~|true|false|0|1)?[[:space:]]*\$" \
          | head -5 || true)"
        if [ -n "$flowbad" ]; then
            hits=$((hits + 1))
            [ "${#samples[@]}" -lt 10 ] && samples+=("$f: secret key in flow mapping with un-redacted value")
        fi
        # 4) BLOCK — a block/folded-scalar body surviving under a secret key
        #    (`api_key: |` + indented body): the body carries the secret and the
        #    key line may even LOOK redacted. Fail-closed on any survivor.
        case "$f" in
            *.yml|*.yaml)
                if ! _files_secrets_verify_yaml_blocks "$f"; then
                    hits=$((hits + 1))
                    [ "${#samples[@]}" -lt 10 ] && samples+=("$f: block-scalar body under a secret key survived")
                fi
                ;;
        esac
    done < <(_files_secrets_targets "$root")
    if [ "$hits" -eq 0 ]; then
        return 0
    fi
    echo "files_secrets_verify: FAIL — $hits leak indicator(s) across the target files:" >&2
    local s; for s in "${samples[@]}"; do echo "    $s" >&2; done
    return 1
}

# Standalone:  bash lib/sanitizers/files-secrets.sh [--verify] <root-dir>
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "${1:-}" = "--verify" ]; then
        shift
        files_secrets_verify "$@"; exit $?
    fi
    files_secrets_scrub "$@" || exit $?
    # Scrub then self-verify — fail-closed if anything survived the redaction.
    files_secrets_verify "$@" || { echo "files-secrets: post-scrub verify FAILED (fail-closed)" >&2; exit 1; }
    echo "files-secrets: scrub + verify clean"
fi
