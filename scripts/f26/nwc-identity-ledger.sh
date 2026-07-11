#!/bin/bash
set -euo pipefail
################################################################################
# scripts/f26/nwc-identity-ledger.sh — provider identity ledger (nwp/ops#83)
#
# The nwc↔ssc pair binds mdl_user.idnumber == OIDC sub == the Drupal account
# UUID (contract identity.sub_stability: uuid). A restore/rebuild of the nwc
# (PROVIDER) DB can change or drop the (uuid,uid,email) mapping and silently
# orphan every ssc UID-lock. This ledger is the deterministic, append-only,
# tamper-evident record of that mapping so a post-restore reconcile can detect
# and repair divergence WITHOUT trusting email (recycled-email risk, pitfall 2c).
#
#   dump    Snapshot users_field_data → append one hash-chained snapshot of
#           {uuid, uid, email, created} rows to an append-only JSONL ledger.
#   verify  (1) INTEGRITY: recompute the sha256 hash-chain over the whole file;
#               a broken/truncated/tampered chain FAILS CLOSED (exit 2).
#           (2) DIVERGENCE: diff the current DB against the newest snapshot and
#               flag any uuid→uid or uuid→email change, or a dropped uuid
#               (an identity a consumer may have locked). Any flag → exit 3.
#
# PRIVACY / TRUST BOUNDARY: email is PII. The ledger lives under private/
# (gitignored) — the SAME trust boundary as DB backups. Never commit it. Use
# --hash-email to store sha256(email) instead of the plaintext address; the
# divergence check still works on the hash.
#
# BLAST RADIUS: this reads a Drupal DB (via drush) and writes a local file. It
# is safe on dev/stg/live-test. A LIVE-PROD ledger dump/reconcile is part of the
# ver/Solo-gated DR runbook (CLAUDE.md) — this tool never writes to a site.
#
# ROW SOURCE (pluggable — makes the tool testable offline & drush-agnostic):
#   --site=<name>          resolve a `ddev drush` in sites/<name>/dev (default nwc)
#   --drush="ddev drush"   explicit drush invocation prefix
#   --rows-from=FILE       read rows from a TSV  (uuid<TAB>uid<TAB>email<TAB>created)
#   NWC_LEDGER_ROWS_CMD    env: a command whose stdout is that TSV
# Exactly one source is used (precedence: --rows-from > NWC_LEDGER_ROWS_CMD > drush).
#
# NOTE ON THE DRUSH-COMMAND ALTERNATIVE (design §1): the design suggests a
# `drush nwc_identity:ledger-dump` command inside the nwc profile. That profile
# is a SEPARATE, gitignored git repo, so such a command would not appear on this
# reviewable nwp branch and could not be unit-tested here. This staged
# `drush sql:query` + jq script is the documented, in-repo, testable equivalent.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# UI is optional (keeps the tool usable standalone / in CI without lib/ui.sh).
if [ -f "$PROJECT_ROOT/lib/ui.sh" ]; then
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/ui.sh"
fi
_lg_err()  { if command -v print_error   >/dev/null 2>&1; then print_error   "$*"; else printf 'ERROR: %s\n' "$*" >&2; fi; }
_lg_ok()   { if command -v print_status  >/dev/null 2>&1; then print_status "OK" "$*"; else printf 'OK: %s\n' "$*"; fi; }
_lg_info() { if command -v print_info    >/dev/null 2>&1; then print_info    "$*"; else printf '%s\n' "$*"; fi; }
_lg_warn() { if command -v print_warning >/dev/null 2>&1; then print_warning "$*"; else printf 'WARN: %s\n' "$*" >&2; fi; }

PAIR_ID="ssc"
LEDGER=""
SITE="nwc"
DRUSH=""
ROWS_FROM=""
HASH_EMAIL=false
NO_DB=false

ledger_default_path() {
    local dir="${NWP_PAIR_LEDGER_DIR:-${PROJECT_ROOT}/private/pairs/ledger}"
    echo "${dir}/${PAIR_ID}.provider-identity.jsonl"
}

sha256_of() { # hashes stdin → bare hex
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}';
    elif command -v shasum  >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}';
    else _lg_err "no sha256sum/shasum available"; return 1; fi
}

# --- row source --------------------------------------------------------------
# Emits TSV rows: uuid<TAB>uid<TAB>email<TAB>created  (one user per line, uid>0).
emit_rows() {
    if [ -n "$ROWS_FROM" ]; then
        [ -f "$ROWS_FROM" ] || { _lg_err "--rows-from file not found: $ROWS_FROM"; return 1; }
        # Skip blank lines / comments; pass through TSV.
        grep -v '^[[:space:]]*#' "$ROWS_FROM" | grep -v '^[[:space:]]*$' || true
        return 0
    fi
    if [ -n "${NWC_LEDGER_ROWS_CMD:-}" ]; then
        eval "$NWC_LEDGER_ROWS_CMD"
        return 0
    fi
    # drush path: uuid lives in `users`, email/created in `users_field_data`.
    local drush="$DRUSH"
    if [ -z "$drush" ]; then
        local sdir="${PROJECT_ROOT}/sites/${SITE}/dev"
        [ -d "$sdir" ] || { _lg_err "site dir not found: $sdir (use --drush= or --rows-from=)"; return 1; }
        drush="cd '$sdir' && ddev drush"
    fi
    local sql="SELECT u.uuid, u.uid, ufd.mail, ufd.created \
FROM users u JOIN users_field_data ufd ON u.uid = ufd.uid \
WHERE u.uid > 0 AND ufd.default_langcode = 1 ORDER BY u.uid;"
    # drush sql:query returns tab-separated rows.
    eval "$drush sql:query \"\$sql\"" 2>/dev/null
}

# Normalise a TSV row into a canonical record JSON object (email or its hash).
# stdin: TSV rows; stdout: one compact JSON object per line (sorted keys).
rows_to_records() {
    local snap="$1"
    local hash_email="$2"
    while IFS=$'\t' read -r uuid uid email created; do
        [ -z "${uuid:-}" ] && continue
        [ -z "${uid:-}" ]  && continue
        local emailfield
        if [ "$hash_email" = "true" ]; then
            local eh; eh="$(printf '%s' "${email:-}" | sha256_of)"
            emailfield="$(jq -cn --arg v "$eh" '{email_sha256:$v}')"
        else
            emailfield="$(jq -cn --arg v "${email:-}" '{email:$v}')"
        fi
        jq -cn \
           --argjson snap "$snap" \
           --arg uuid "$uuid" \
           --argjson uid "$uid" \
           --arg created "${created:-}" \
           --argjson ef "$emailfield" \
           '{t:"rec", snap:$snap, uuid:$uuid, uid:$uid, created:$created} + $ef'
    done
}

cmd_dump() {
    local ledger; ledger="${LEDGER:-$(ledger_default_path)}"
    mkdir -p "$(dirname "$ledger")"
    touch "$ledger"

    # Next snapshot number + previous chain head.
    local prev_snap prev_sha
    prev_snap="$(grep '"t":"snap"' "$ledger" 2>/dev/null | tail -1 | jq -r '.snap' 2>/dev/null || true)"
    prev_sha="$(grep '"t":"snap"'  "$ledger" 2>/dev/null | tail -1 | jq -r '.sha256' 2>/dev/null || true)"
    [ -z "$prev_snap" ] || [ "$prev_snap" = "null" ] && prev_snap=0
    [ -z "$prev_sha" ]  || [ "$prev_sha"  = "null" ] && prev_sha="GENESIS"
    local snap=$((prev_snap + 1))

    # Build this snapshot's record block (deterministic: sorted).
    local recblock; recblock="$(emit_rows | rows_to_records "$snap" "$HASH_EMAIL" | LC_ALL=C sort)"
    local rows; rows="$(printf '%s' "$recblock" | grep -c '"t":"rec"' || true)"
    [ -z "$rows" ] && rows=0

    # Hash-chain: sha256( prev_sha + "\n" + sorted-record-block ).
    local sha; sha="$(printf '%s\n%s' "$prev_sha" "$recblock" | sha256_of)"
    local at who
    at="$(date -u +%FT%TZ)"
    who="$(id -un 2>/dev/null)@$(hostname -s 2>/dev/null || hostname)"

    {
        [ -n "$recblock" ] && printf '%s\n' "$recblock"
        jq -cn \
           --argjson snap "$snap" --arg at "$at" --arg who "$who" \
           --argjson rows "$rows" --arg prev "$prev_sha" --arg sha "$sha" \
           '{t:"snap", snap:$snap, at:$at, who:$who, rows:$rows, prev:$prev, sha256:$sha}'
    } >> "$ledger"

    _lg_ok "ledger snapshot #$snap written: $rows row(s) → $ledger"
    _lg_info "  chain head sha256=${sha:0:16}…  (prev=${prev_sha:0:16}…)"
}

# Recompute + check the hash chain over the whole ledger. Exit 2 on any break.
verify_integrity() {
    local ledger="$1"
    local expected_prev="GENESIS"
    local seen=0
    local snaps; snaps="$(grep -c '"t":"snap"' "$ledger" 2>/dev/null || true)"
    [ -z "$snaps" ] && snaps=0
    if [ "$snaps" -eq 0 ]; then
        _lg_warn "ledger has no snapshots yet: $ledger"
        return 0
    fi
    local n
    for n in $(grep '"t":"snap"' "$ledger" | jq -r '.snap'); do
        local recblock stored_prev stored_sha calc_sha
        recblock="$(grep "\"t\":\"rec\",\"snap\":$n," "$ledger" 2>/dev/null | LC_ALL=C sort || true)"
        # jq-produced records order keys t,snap,uuid,... so the prefix match above
        # is stable; fall back to a jq filter if the grep prefix misses.
        if [ -z "$recblock" ]; then
            recblock="$(jq -c "select(.t==\"rec\" and .snap==$n)" "$ledger" 2>/dev/null | LC_ALL=C sort || true)"
        fi
        local snapline; snapline="$(grep "\"t\":\"snap\"" "$ledger" | jq -c "select(.snap==$n)")"
        stored_prev="$(printf '%s' "$snapline" | jq -r '.prev')"
        stored_sha="$(printf '%s' "$snapline" | jq -r '.sha256')"
        if [ "$stored_prev" != "$expected_prev" ]; then
            _lg_err "INTEGRITY FAIL: snapshot #$n prev=${stored_prev:0:16}… expected ${expected_prev:0:16}… (chain broken/reordered)"
            return 2
        fi
        calc_sha="$(printf '%s\n%s' "$stored_prev" "$recblock" | sha256_of)"
        if [ "$calc_sha" != "$stored_sha" ]; then
            _lg_err "INTEGRITY FAIL: snapshot #$n sha256 mismatch (recomputed ${calc_sha:0:16}… vs stored ${stored_sha:0:16}…) — tampered/truncated"
            return 2
        fi
        expected_prev="$stored_sha"
        seen=$((seen+1))
    done
    _lg_ok "integrity OK: $seen snapshot(s), hash-chain intact"
    return 0
}

cmd_verify() {
    local ledger; ledger="${LEDGER:-$(ledger_default_path)}"
    if [ ! -f "$ledger" ]; then
        _lg_err "no ledger at $ledger — run 'dump' first (fail-closed: cannot verify a missing ledger)"
        return 2
    fi
    verify_integrity "$ledger" || return $?

    if [ "$NO_DB" = "true" ]; then
        _lg_info "--no-db: skipping DB divergence check (integrity-only)."
        return 0
    fi

    # Latest snapshot number.
    local latest; latest="$(grep '"t":"snap"' "$ledger" | jq -r '.snap' | tail -1)"
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        _lg_warn "no snapshot to diff against."
        return 0
    fi

    # Ledger truth for the latest snapshot: uuid -> "uid|email".
    local tmpled tmpcur
    tmpled="$(mktemp)"; tmpcur="$(mktemp)"
    jq -r "select(.t==\"rec\" and .snap==$latest) | [.uuid, (.uid|tostring), (.email // .email_sha256 // \"\")] | @tsv" \
        "$ledger" | LC_ALL=C sort > "$tmpled"

    # Current DB, normalised the same way (respect --hash-email so emails compare).
    emit_rows | while IFS=$'\t' read -r uuid uid email created; do
        [ -z "${uuid:-}" ] && continue
        local ev="${email:-}"
        if [ "$HASH_EMAIL" = "true" ]; then ev="$(printf '%s' "${email:-}" | sha256_of)"; fi
        printf '%s\t%s\t%s\n' "$uuid" "${uid:-}" "$ev"
    done | LC_ALL=C sort > "$tmpcur"

    local flags=0
    # Walk ledger rows; compare against current.
    while IFS=$'\t' read -r luuid luid lemail; do
        local cur; cur="$(grep -P "^$(printf '%s' "$luuid" | sed 's/[.[\*^$()+?{|]/\\&/g')\t" "$tmpcur" || true)"
        if [ -z "$cur" ]; then
            _lg_err "DIVERGENCE: uuid=$luuid present in ledger but MISSING from current DB (dropped/orphaned identity)"
            flags=$((flags+1)); continue
        fi
        local cuid cemail
        cuid="$(printf '%s' "$cur" | cut -f2)"
        cemail="$(printf '%s' "$cur" | cut -f3)"
        if [ "$cuid" != "$luid" ]; then
            _lg_err "DIVERGENCE: uuid=$luuid uid changed ledger=$luid → current=$cuid (renumber — UID-lock repair needed)"
            flags=$((flags+1))
        fi
        if [ "$cemail" != "$lemail" ]; then
            _lg_err "DIVERGENCE: uuid=$luuid email changed (ledger vs current differ)"
            flags=$((flags+1))
        fi
    done < "$tmpled"

    rm -f "$tmpled" "$tmpcur"
    if [ "$flags" -gt 0 ]; then
        _lg_err "verify FAILED: $flags divergence(s) vs snapshot #$latest — reconcile per ops#83 §3 before any promotion."
        return 3
    fi
    _lg_ok "verify GREEN: current DB matches ledger snapshot #$latest (no uuid→uid / uuid→email drift)."
    return 0
}

show_help() {
    cat <<EOF
nwc-identity-ledger.sh — provider identity ledger (nwp/ops#83)

USAGE:
    nwc-identity-ledger.sh dump   [OPTIONS]
    nwc-identity-ledger.sh verify [OPTIONS]

OPTIONS:
    --pair=<id>        pair id (consumer key); default ssc
    --ledger=PATH      ledger file (default private/pairs/ledger/<pair>.provider-identity.jsonl)
    --site=<name>      provider site for drush (default nwc → sites/nwc/dev)
    --drush="CMD"      explicit drush prefix (e.g. "ddev drush")
    --rows-from=FILE   TSV rows uuid<TAB>uid<TAB>email<TAB>created (offline/tests)
    --hash-email       store/compare sha256(email) instead of the address (reduced PII)
    --no-db            verify: integrity-only, skip the live-DB divergence diff
    -h, --help         this help

EXIT (verify): 0 ok · 2 integrity/chain failure (fail-closed) · 3 divergence detected
EOF
}

main() {
    local sub="${1:-}"; shift || true
    for arg in "$@"; do
        case "$arg" in
            --pair=*)      PAIR_ID="${arg#*=}" ;;
            --ledger=*)    LEDGER="${arg#*=}" ;;
            --site=*)      SITE="${arg#*=}" ;;
            --drush=*)     DRUSH="${arg#*=}" ;;
            --rows-from=*) ROWS_FROM="${arg#*=}" ;;
            --hash-email)  HASH_EMAIL=true ;;
            --no-db)       NO_DB=true ;;
            -h|--help)     show_help; exit 0 ;;
            *) _lg_err "unknown option: $arg"; show_help; exit 1 ;;
        esac
    done
    case "$sub" in
        dump)        cmd_dump ;;
        verify)      cmd_verify ;;
        -h|--help|"") show_help ;;
        *) _lg_err "unknown subcommand: $sub"; show_help; exit 1 ;;
    esac
}

main "$@"
