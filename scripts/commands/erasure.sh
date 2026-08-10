#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/erasure.sh — `pl erasure` (ops#81 / GDPR Art.17)
#
# WHY THIS EXISTS
# ---------------
# A right-to-be-forgotten request against the nwc↔ssc pair spans two stacks
# (Drupal provider + Moodle consumer), a shared identity anchor (the OIDC `sub`
# == mdl_user.idnumber), moodledata files, and a backup repo whose retention
# ceiling decides when residual PII actually disappears. Before this verb there
# was NO tooling at all: `grep -rE 'dataprivacy|data_request|DSAR'` over
# scripts/commands + lib returned zero hits, and docs/guides/ops83-dr-restore.md
# handed the operator raw SQL against `mdl_user` to run over ssh. The first real,
# time-boxed erasure request would have been serviced by hand, across two
# systems, under a legal deadline.
#
# WHAT THIS VERB DOES *NOT* DO
# ----------------------------
# It does not pretend the erasure channel is built. ops#81 is at P0 (schema +
# contract surface only): the receiver plugin `local_nwc_erase` and the sender
# `nwc_moodle_erase` are PHASED (P1-P5) and are not deployed anywhere. So
# `execute` FAILS CLOSED with an explicit reason code rather than reporting a
# success it cannot have achieved. What is real today, and useful today, is:
#
#   plan     build + schema-validate the exact erasure command, record it, and
#            print the full two-sided target inventory (the thing an operator
#            would otherwise assemble by hand under deadline).
#   verify   probe BOTH halves for residual rows and assert a backup retention
#            ceiling exists. This is the honest answer to "is this person gone?"
#            and it is capable of going red.
#   status   what happened to a request, from a durable ledger.
#
# THE ANTI-VACUITY RULE
# ---------------------
# A probe that cannot run is NOT a probe that found nothing. Every unreachable
# probe, non-numeric answer, missing schema, missing ceiling and unresolvable
# contract is reported as CANNOT-VERIFY and exits NON-ZERO. "Zero residual rows"
# is only ever printed when something actually counted zero.
#
# IDENTITY RULE (ops#81 §3): the subject is ALWAYS the OIDC `sub` (the Drupal
# account UUID). Resolution by email is not offered — recycled/changed addresses
# make it unsafe, and an email-keyed erasure can delete the wrong person.
#
# Usage:
#   pl erasure plan    <consumer> --sub=<uuid> [--action=delete|anonymise]
#                                 [--tier=dev|stg|live|prod] [--request-id=ID]
#                                 [--issuer=URL]
#   pl erasure execute <consumer> --request-id=ID [--transport-cmd=CMD]
#                                 [--confirm=ERASE-EXECUTE]
#   pl erasure verify  <consumer> --sub=<uuid> [--tier=T]
#                                 [--provider-probe-cmd=CMD] [--consumer-probe-cmd=CMD]
#                                 [--backup-probe-cmd=CMD] [--backup-ceiling=DUR]
#   pl erasure status  [<request-id>]
#   pl erasure list
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
NWP_REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# Honour an injected PROJECT_ROOT (tests / alternate checkouts), same contract
# as scripts/commands/contracts.sh.
PROJECT_ROOT="${PROJECT_ROOT:-$NWP_REPO_ROOT}"
PAIRS_DIR="${NWP_PAIR_CONTRACT_DIR:-$PROJECT_ROOT/pairs}"
# ops#326: real pair contracts live in the private overlay, searched second.
PAIRS_OVERLAY_DIR="${NWP_PAIR_OVERLAY_DIR:-$PROJECT_ROOT/private/pairs}"
STATE_DIR="${NWP_ERASURE_STATE_DIR:-$PROJECT_ROOT/private/erasure}"
LEDGER="$STATE_DIR/ledger.jsonl"

# shellcheck source=/dev/null
[ -f "$NWP_REPO_ROOT/lib/ui.sh" ] && source "$NWP_REPO_ROOT/lib/ui.sh"

_say()  { if command -v print_info    >/dev/null 2>&1; then print_info    "$*"; else printf '%s\n' "$*"; fi; }
_warn() { if command -v print_warning >/dev/null 2>&1; then print_warning "$*"; else printf 'WARN: %s\n' "$*"; fi; }
_err()  { if command -v print_error   >/dev/null 2>&1; then print_error   "$*"; else printf 'ERROR: %s\n' "$*"; fi; }
_ok()   { if command -v print_status  >/dev/null 2>&1; then print_status "OK" "$*"; else printf 'OK: %s\n' "$*"; fi; }

# NOTE: every diagnostic goes to STDOUT on purpose. These messages are the
# product — an operator under a 30-day statutory clock must see the reason code
# in the same stream as the plan, and `bats`'s $output must contain it.

_yqe() { # <file> <expr>  -> value or empty (never the literal "null")
    local f="$1" e="$2"
    command -v yq >/dev/null 2>&1 || return 1
    yq e -r "$e" "$f" 2>/dev/null | grep -v '^null$' || true
}

_contract_for() {
    # ops#326: shipped first, then overlay; a pair declared in BOTH echoes a
    # path that cannot exist (fail-closed — same rule as lib/pair.sh).
    local shipped="$PAIRS_DIR/${1}.pair-contract.yml"
    local overlay="$PAIRS_OVERLAY_DIR/${1}.pair-contract.yml"
    if [ -f "$shipped" ] && [ -f "$overlay" ] && [ "$shipped" != "$overlay" ]; then
        echo "$shipped.DUPLICATE-DECLARATION"; return 0
    fi
    if [ ! -f "$shipped" ] && [ -f "$overlay" ]; then echo "$overlay"; else echo "$shipped"; fi
}

# Resolve the pair contract or fail closed. Echoes the path on success.
_require_contract() {
    local pair="$1" contract
    contract="$(_contract_for "$pair")"
    if [ ! -f "$contract" ]; then
        _err "erasure: NO-CONTRACT — no pair contract for '$pair' at $contract"
        _say  "  Pairs available: $(ls "$PAIRS_DIR"/*.pair-contract.yml "$PAIRS_OVERLAY_DIR"/*.pair-contract.yml 2>/dev/null | xargs -r -n1 basename | sed 's/\.pair-contract\.yml//' | sort -u | tr '\n' ' ')"
        return 1
    fi
    if ! command -v yq >/dev/null 2>&1; then
        _err "erasure: CANNOT-VERIFY — yq is not installed, the pair contract cannot be parsed."
        return 1
    fi
    echo "$contract"
}

# The schema that pins the wire shape. Absent = we cannot prove the command is
# well formed, which is a failure, not a warning.
_schema_path() {
    local contract="$1" rel
    rel="$(_yqe "$contract" '.surfaces.erasure.schema')"
    [ -n "$rel" ] || rel="contracts/erasure.command.schema.json"
    if [ -f "$PROJECT_ROOT/$rel" ]; then echo "$PROJECT_ROOT/$rel"
    elif [ -f "$NWP_REPO_ROOT/$rel" ]; then echo "$NWP_REPO_ROOT/$rel"
    fi
}

################################################################################
# Command validation.
#
# Two layers, both fail-closed:
#   1. STRUCTURAL (always, pure bash+jq): required keys present and non-empty,
#      `action` inside the contract's enum, `timestamp` an integer, `issuer` a
#      URI. These are exactly the schema's constraints; the object is built
#      here, so additionalProperties cannot be violated by construction.
#   2. JSON SCHEMA (when python3 + jsonschema exist): the authoritative check
#      against the signed schema file. Unavailable => reported, never silent.
################################################################################
_validate_command() { # <json> <schema-path>
    local json="$1" schema="$2" bad=0 v

    if [ -z "$schema" ] || [ ! -f "$schema" ]; then
        _err "erasure: SCHEMA-MISSING — the erasure command schema is not present; the command cannot be validated."
        return 1
    fi

    for key in sub request_id action issuer timestamp; do
        v="$(printf '%s' "$json" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null || true)"
        if [ -z "$v" ]; then
            _err "erasure: SCHEMA-INVALID — required field '$key' is missing or empty."
            bad=1
        fi
    done

    v="$(printf '%s' "$json" | jq -r '.action // empty' 2>/dev/null || true)"
    # Read the permitted actions FROM the schema, so a schema change cannot be
    # silently out-voted by a hardcoded list here.
    local enum
    enum="$(jq -r '.properties.action.enum[]?' "$schema" 2>/dev/null | tr '\n' ' ')"
    [ -n "$enum" ] || enum="delete anonymise"
    if ! printf '%s\n' $enum | grep -qxF "$v"; then
        _err "erasure: SCHEMA-INVALID — action '$v' is not one of the contract's actions ($enum)."
        bad=1
    fi

    v="$(printf '%s' "$json" | jq -r '.timestamp | type' 2>/dev/null || true)"
    if [ "$v" != "number" ]; then
        _err "erasure: SCHEMA-INVALID — timestamp must be an integer (seconds since epoch)."
        bad=1
    fi

    v="$(printf '%s' "$json" | jq -r '.issuer // empty' 2>/dev/null || true)"
    if ! printf '%s' "$v" | grep -qE '^[a-zA-Z][a-zA-Z0-9+.-]*://[^[:space:]]+$'; then
        _err "erasure: SCHEMA-INVALID — issuer '$v' is not a URI."
        bad=1
    fi

    [ "$bad" -eq 0 ] || return 1

    if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' 2>/dev/null; then
        if ! printf '%s' "$json" | python3 -c '
import json, sys
from jsonschema import Draft202012Validator
schema = json.load(open(sys.argv[1]))
doc = json.load(sys.stdin)
errs = sorted(Draft202012Validator(schema).iter_errors(doc), key=lambda e: e.path)
for e in errs:
    print("  %s: %s" % ("/".join(str(p) for p in e.path) or "<root>", e.message))
sys.exit(1 if errs else 0)
' "$schema"; then
            _err "erasure: SCHEMA-INVALID — the command does not validate against $(basename "$schema")."
            return 1
        fi
    else
        _warn "erasure: jsonschema validator unavailable — structural validation only (install python3-jsonschema for the authoritative check)."
    fi
    return 0
}

# The target inventory (ops#81 §2). Printed with every plan so the operator sees
# what "erased" is supposed to mean on both stacks, rather than inferring it.
_print_targets() {
    local provider="$1" consumer="$2"
    _say "  Erasure targets — PROVIDER ($provider, Drupal):"
    echo "    - users_field_data / user row + profile fields"
    echo "    - the OIDC identity anchor (account uuid = sub)"
    echo "    - authored content re-attributed or removed per the retention policy"
    _say "  Erasure targets — CONSUMER ($consumer, Moodle) via the Privacy API, NOT delete_user():"
    echo "    - mdl_user row + residual PII (lastip, phone, address, idnumber)"
    echo "    - grade_grades / quiz_attempts / course_completions"
    echo "    - tool_policy_acceptances (consent records)"
    echo "    - auth_oauth2_linked_login (severs re-link)"
    echo "    - moodledata files for every user context (ops#84 scrub)"
    _say "  Erasure targets — BACKUPS:"
    echo "    - raw (unsanitised) restic repo must carry a --keep-within ceiling"
    echo "      (ops#127); residual PII in snapshots outlives the erasure promise"
    echo "      until that window elapses. 'verify' asserts the ceiling exists."
}

_ledger_append() { # <json-line>
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    printf '%s\n' "$1" >> "$LEDGER" 2>/dev/null || true
}

_request_file() { # <pair> <id>
    echo "$STATE_DIR/${1}/${2}.json"
}

# Find a request file by id across every pair. Echoes the path, or nothing.
_find_request() {
    local id="$1" f
    for f in "$STATE_DIR"/*/"${id}.json"; do
        [ -e "$f" ] || continue
        echo "$f"; return 0
    done
    return 1
}

################################################################################
# plan
################################################################################
cmd_plan() {
    local pair="" sub="" action="delete" tier="dev" reqid="" issuer="" sub_set=false arg
    for arg in "$@"; do
        case "$arg" in
            --sub=*)        sub="${arg#*=}"; sub_set=true ;;
            --action=*)     action="${arg#*=}" ;;
            --tier=*)       tier="${arg#*=}" ;;
            --request-id=*) reqid="${arg#*=}" ;;
            --issuer=*)     issuer="${arg#*=}" ;;
            -h|--help)      cmd_help; return 0 ;;
            -*)             _err "erasure plan: unknown option '$arg'"; return 2 ;;
            *)              [ -z "$pair" ] && pair="$arg" || { _err "erasure plan: unexpected argument '$arg'"; return 2; } ;;
        esac
    done
    [ -n "$pair" ] || { _err "erasure plan: a pair (consumer site key) is required, e.g. 'pl erasure plan ssc --sub=<uuid>'"; return 2; }
    if [ "$sub_set" != true ] || [ -z "$sub" ]; then
        _err "erasure plan: --sub=<uuid> is required. The subject is ALWAYS the OIDC sub"
        _say  "  (the Drupal account UUID == mdl_user.idnumber). Erasure is never keyed on email."
        return 2
    fi

    local contract; contract="$(_require_contract "$pair")" || return 1

    if [ -z "$(_yqe "$contract" '.surfaces.erasure')" ]; then
        _err "erasure plan: NO-ERASURE-SURFACE — '$pair' declares no 'erasure' surface in its pair contract."
        return 1
    fi

    local provider consumer
    provider="$(_yqe "$contract" '.provider')"
    consumer="$(_yqe "$contract" '.consumer')"
    [ -n "$consumer" ] || consumer="$pair"

    [ -n "$issuer" ] || issuer="$(_yqe "$contract" ".endpoints.${tier}.issuer")"
    if [ -z "$issuer" ]; then
        _err "erasure plan: NO-ISSUER — the contract declares no endpoints.${tier}.issuer and none was passed."
        _say  "  The consumer validates the issuer against its configured trusted issuer; a blank one is never valid."
        return 1
    fi

    [ -n "$reqid" ] || reqid="$( (command -v uuidgen >/dev/null 2>&1 && uuidgen) || printf 'req-%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$RANDOM" )"

    local ts; ts="$(date -u +%s)"
    local cmdjson
    cmdjson="$(jq -cn --arg sub "$sub" --arg rid "$reqid" --arg act "$action" \
                     --arg iss "$issuer" --argjson ts "$ts" \
                     '{sub:$sub, request_id:$rid, action:$act, issuer:$iss, timestamp:$ts}')"

    local schema; schema="$(_schema_path "$contract")"
    _validate_command "$cmdjson" "$schema" || return 1

    mkdir -p "$STATE_DIR/$pair"
    local out; out="$(_request_file "$pair" "$reqid")"
    jq -n --arg pair "$pair" --arg provider "$provider" --arg consumer "$consumer" \
          --arg tier "$tier" --arg at "$(date -u +%FT%TZ)" \
          --argjson cmd "$cmdjson" \
          '{request_id: $cmd.request_id, pair:$pair, provider:$provider, consumer:$consumer,
            tier:$tier, state:"planned", planned_at:$at, command:$cmd}' > "$out"
    _ledger_append "$(jq -cn --arg t "plan" --arg rid "$reqid" --arg pair "$pair" --arg at "$(date -u +%FT%TZ)" \
                            '{t:$t, request_id:$rid, pair:$pair, at:$at}')"

    if command -v print_header >/dev/null 2>&1; then
        print_header "Erasure plan: ${consumer} ← ${provider}  (request ${reqid})"
    else
        echo "== Erasure plan: ${consumer} <- ${provider} (request ${reqid})"
    fi
    echo "  subject (sub) : $sub"
    echo "  action        : $action"
    echo "  tier          : $tier"
    echo "  issuer        : $issuer"
    echo "  recorded      : $out"
    echo ""
    _print_targets "$provider" "$consumer"
    echo ""
    _ok "Command is schema-valid and recorded as PLANNED. Nothing has been erased."
    _say "  Next: 'pl erasure execute $pair --request-id=$reqid' (fails closed until the"
    _say "  ops#81 channel is deployed and the operator has approved the semantics)."
    return 0
}

################################################################################
# execute — the fail-closed half
################################################################################
cmd_execute() {
    local pair="" reqid="" transport="" confirm="${NWP_ERASURE_CONFIRM:-}" arg
    for arg in "$@"; do
        case "$arg" in
            --request-id=*)   reqid="${arg#*=}" ;;
            --transport-cmd=*) transport="${arg#*=}" ;;
            --confirm=*)      confirm="${arg#*=}" ;;
            -h|--help)        cmd_help; return 0 ;;
            -*)               _err "erasure execute: unknown option '$arg'"; return 2 ;;
            *)                [ -z "$pair" ] && pair="$arg" || { _err "erasure execute: unexpected argument '$arg'"; return 2; } ;;
        esac
    done
    [ -n "$pair" ]  || { _err "erasure execute: a pair is required"; return 2; }
    [ -n "$reqid" ] || { _err "erasure execute: --request-id=ID is required (plan it first)"; return 2; }

    local contract; contract="$(_require_contract "$pair")" || return 1

    local reqfile; reqfile="$(_request_file "$pair" "$reqid")"
    if [ ! -f "$reqfile" ]; then
        _err "erasure execute: NO-SUCH-REQUEST — '$reqid' was never planned for pair '$pair'."
        _say  "  Plan it first: pl erasure plan $pair --sub=<uuid> --request-id=$reqid"
        return 1
    fi

    # --- 1. is the ops#81 channel actually deployed on BOTH sides? -----------
    local recv send missing=""
    recv="$(_yqe "$contract" '.erasure.receiver_path')"
    send="$(_yqe "$contract" '.erasure.sender_path')"
    [ -n "$recv" ] || recv="local/nwc_erase/erase.php"
    [ -n "$send" ] || send="modules/nwc_moodle_erase"

    local found_recv=false found_send=false r
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        [ -e "$PROJECT_ROOT/$r/$recv" ] && found_recv=true
    done < <(_yqe "$contract" '.crossref.consumer_roots[]')
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        [ -e "$PROJECT_ROOT/$r/$send" ] && found_send=true
    done < <(_yqe "$contract" '.crossref.provider_roots[]')

    [ "$found_recv" = true ] || missing="${missing}    consumer receiver: $recv (local_nwc_erase — ops#81 P1, not built)\n"
    [ "$found_send" = true ] || missing="${missing}    provider sender:   $send (nwc_moodle_erase — ops#81 P2, not built)\n"
    if [ -n "$missing" ]; then
        _err "erasure execute: CHANNEL-NOT-DEPLOYED — refusing to report an erasure this estate cannot perform."
        printf '%b' "$missing"
        _say "  ops#81 is at P0 (schema + contract surface only). Until P1/P2 land, an erasure"
        _say "  must be recorded, escalated and performed under the operator DR runbook —"
        _say "  it must NOT be marked done here."
        return 1
    fi

    # --- 2. has the operator approved the erasure SEMANTICS? -----------------
    # anonymise-vs-delete and "what counts as verified erased" across nwc + ssc
    # + moodledata + restic snapshots is a lawful-basis question. An agent must
    # not settle it. Approval is recorded in the contract, in git, reviewable.
    local approved; approved="$(_yqe "$contract" '.erasure.semantics_approved')"
    if [ "$approved" != "true" ] && [ "${NWP_ERASURE_SEMANTICS_APPROVED:-}" != "yes" ]; then
        _err "erasure execute: SEMANTICS-UNAPPROVED — the pair contract does not record operator approval."
        _say  "  Set 'erasure.semantics_approved: true' in $(basename "$contract") once the operator has"
        _say  "  signed off: anonymise vs delete, which aggregates are lawfully retained, and what"
        _say  "  'verified erased' means across nwc + ssc + moodledata + restic snapshots."
        return 1
    fi

    # --- 3. transport ---------------------------------------------------------
    [ -n "$transport" ] || transport="$(_yqe "$contract" '.erasure.transport_cmd')"
    if [ -z "$transport" ]; then
        _err "erasure execute: NO-TRANSPORT — no transport command is configured for this pair."
        _say  "  The signed command is built and validated, but nothing is wired to deliver it."
        _say  "  Pass --transport-cmd=CMD (receives the command JSON on stdin) or declare"
        _say  "  erasure.transport_cmd in the pair contract."
        return 1
    fi

    # --- 4. coupled-tier confirmation ----------------------------------------
    local tier; tier="$(jq -r '.tier // "dev"' "$reqfile")"
    if _tier_is_coupled "$contract" "$tier" && [ "$confirm" != "ERASE-EXECUTE" ]; then
        _err "erasure execute: CONFIRM required — '$tier' is a coupled tier with real member identities."
        _say  "  Re-run with --confirm=ERASE-EXECUTE once you have read the plan."
        return 1
    fi

    local cmdjson; cmdjson="$(jq -c '.command' "$reqfile")"
    local rc=0
    printf '%s' "$cmdjson" | eval "$transport" || rc=$?
    local now; now="$(date -u +%FT%TZ)"
    if [ "$rc" -ne 0 ]; then
        jq --arg at "$now" --argjson rc "$rc" '.state="failed" | .executed_at=$at | .exit_code=$rc' \
            "$reqfile" > "${reqfile}.tmp" && mv "${reqfile}.tmp" "$reqfile"
        _ledger_append "$(jq -cn --arg t execute --arg rid "$reqid" --arg pair "$pair" --arg at "$now" --argjson rc "$rc" '{t:$t,request_id:$rid,pair:$pair,at:$at,result:"failed",exit_code:$rc}')"
        _err "erasure execute: TRANSPORT-FAILED — the erasure command was not accepted (exit $rc)."
        return 1
    fi
    jq --arg at "$now" '.state="executed" | .executed_at=$at' "$reqfile" > "${reqfile}.tmp" && mv "${reqfile}.tmp" "$reqfile"
    _ledger_append "$(jq -cn --arg t execute --arg rid "$reqid" --arg pair "$pair" --arg at "$now" '{t:$t,request_id:$rid,pair:$pair,at:$at,result:"executed"}')"
    _ok "Erasure command delivered for request $reqid."
    _say "  This is NOT proof of erasure. Run: pl erasure verify $pair --sub=<uuid>"
    return 0
}

_tier_is_coupled() { # <contract> <tier>
    local contract="$1" tier="$2" t
    while IFS= read -r t; do
        [ "$t" = "$tier" ] && return 0
    done < <(_yqe "$contract" '.identity.coupled_tiers[]')
    return 1
}

################################################################################
# verify — the honest answer to "is this person gone?"
################################################################################
# Each probe is a command receiving the sub as $1 and printing ONE integer: the
# number of residual rows that side still holds for that subject. Pluggable so
# the check runs offline, in CI, and against real DBs through pl drush /
# pl moodle cli without this file needing DB credentials.
cmd_verify() {
    local pair="" sub="" tier="live" prov_cmd="" cons_cmd="" bak_cmd="" ceiling="" arg
    for arg in "$@"; do
        case "$arg" in
            --sub=*)                 sub="${arg#*=}" ;;
            --tier=*)                tier="${arg#*=}" ;;
            --provider-probe-cmd=*)  prov_cmd="${arg#*=}" ;;
            --consumer-probe-cmd=*)  cons_cmd="${arg#*=}" ;;
            --backup-probe-cmd=*)    bak_cmd="${arg#*=}" ;;
            --backup-ceiling=*)      ceiling="${arg#*=}" ;;
            -h|--help)               cmd_help; return 0 ;;
            -*)  _err "erasure verify: unknown option '$arg'"
                 case "$arg" in --email*)
                    _say "  Erasure is NEVER keyed on email (ops#81 §3): addresses are recycled and"
                    _say "  changed, so an email-keyed erasure can delete the wrong person. Use --sub." ;;
                 esac
                 return 2 ;;
            *)   [ -z "$pair" ] && pair="$arg" || { _err "erasure verify: unexpected argument '$arg'"; return 2; } ;;
        esac
    done
    [ -n "$pair" ] || { _err "erasure verify: a pair is required"; return 2; }
    [ -n "$sub" ]  || { _err "erasure verify: --sub=<uuid> is required"; return 2; }

    local contract; contract="$(_require_contract "$pair")" || return 1
    local provider consumer
    provider="$(_yqe "$contract" '.provider')"; [ -n "$provider" ] || provider="provider"
    consumer="$(_yqe "$contract" '.consumer')"; [ -n "$consumer" ] || consumer="$pair"

    [ -n "$prov_cmd" ] || prov_cmd="$(_yqe "$contract" '.erasure.provider_probe_cmd')"
    [ -n "$cons_cmd" ] || cons_cmd="$(_yqe "$contract" '.erasure.consumer_probe_cmd')"
    [ -n "$bak_cmd" ]  || bak_cmd="$(_yqe  "$contract" '.erasure.backup_probe_cmd')"
    [ -n "$ceiling" ]  || ceiling="$(_yqe  "$contract" '.erasure.backup_ceiling')"

    if command -v print_header >/dev/null 2>&1; then
        print_header "Erasure verification: ${consumer} ↔ ${provider} @ ${tier}"
    else
        echo "== Erasure verification: ${consumer} <-> ${provider} @ ${tier}"
    fi
    echo "  subject (sub): $sub"
    echo ""

    local unknown=0 residual=0

    _probe_side() { # <label> <cmd>
        local label="$1" cmd="$2" out rc=0 n
        if [ -z "$cmd" ]; then
            _err "  ${label}: CANNOT-VERIFY — no residual-row probe is configured."
            _say  "    Pass --${label}-probe-cmd=CMD, or declare erasure.${label}_probe_cmd in the"
            _say  "    pair contract. A probe that cannot run is NOT a probe that found nothing."
            unknown=$((unknown + 1)); return
        fi
        out="$(eval "$cmd $(printf '%q' "$sub")" 2>/dev/null)" || rc=$?
        if [ "$rc" -ne 0 ]; then
            _err "  ${label}: CANNOT-VERIFY — the probe exited $rc; residual state is UNKNOWN, not clean."
            unknown=$((unknown + 1)); return
        fi
        n="$(printf '%s' "$out" | tr -d '[:space:]')"
        case "$n" in
            ''|*[!0-9]*)
                _err "  ${label}: CANNOT-VERIFY — the probe printed '${out}', which is not a row count."
                unknown=$((unknown + 1)); return ;;
        esac
        if [ "$n" -gt 0 ]; then
            _err "  ${label}: RESIDUAL — ${n} row(s) still reference this subject."
            residual=$((residual + 1))
        else
            _ok "  ${label}: 0 residual row(s) (counted)."
        fi
    }

    _probe_side provider "$prov_cmd"
    _probe_side consumer "$cons_cmd"

    # --- backups: the half everybody forgets ---------------------------------
    # Live rows can be zero while an unsanitised restic repo still holds the
    # person in every snapshot. Erasure is only complete once the retention
    # ceiling has elapsed, so the ceiling must at minimum EXIST.
    if [ -n "$bak_cmd" ]; then
        _probe_side backup "$bak_cmd"
    elif [ -n "$ceiling" ]; then
        _ok "  backup: retention ceiling declared (${ceiling}) — residual snapshot copies age out within it."
    else
        _err "  backup: NO-BACKUP-CEILING — no --keep-within retention ceiling is declared for this pair."
        _say  "    Residual PII inside an unsanitised backup repo outlives the erasure promise"
        _say  "    indefinitely (ops#127). Declare erasure.backup_ceiling (e.g. 30d) matching the"
        _say  "    'pl ver-backup-pull --keep-within' value, or wire erasure.backup_probe_cmd."
        unknown=$((unknown + 1))
    fi

    echo ""
    if [ "$residual" -gt 0 ]; then
        _err "erasure verify: RESIDUAL — ${residual} side(s) still hold data for this subject. NOT erased."
        return 1
    fi
    if [ "$unknown" -gt 0 ]; then
        _err "erasure verify: CANNOT-VERIFY — ${unknown} check(s) could not be evaluated. This is not a pass."
        return 1
    fi
    _ok "ERASURE VERIFIED — every configured probe counted zero and a retention ceiling is declared."
    return 0
}

################################################################################
# status / list
################################################################################
cmd_status() {
    local id="${1:-}"
    if [ -z "$id" ]; then cmd_list; return $?; fi
    local f
    if ! f="$(_find_request "$id")"; then
        _err "erasure status: NO-SUCH-REQUEST — no planned request with id '$id'."
        return 1
    fi
    if command -v print_header >/dev/null 2>&1; then print_header "Erasure request $id"; else echo "== Erasure request $id"; fi
    jq -r '"  pair       : \(.pair)\n  tier       : \(.tier)\n  state      : \(.state)\n  planned_at : \(.planned_at)\n  action     : \(.command.action)\n  sub        : \(.command.sub)"' "$f"
    [ -f "$LEDGER" ] && { echo ""; _say "  ledger:"; grep -F "\"$id\"" "$LEDGER" 2>/dev/null | sed 's/^/    /' || true; }
    return 0
}

cmd_list() {
    if command -v print_header >/dev/null 2>&1; then print_header "Erasure requests"; else echo "== Erasure requests"; fi
    local f found=0
    for f in "$STATE_DIR"/*/*.json; do
        [ -e "$f" ] || continue
        found=1
        jq -r '"  \(.request_id)  \(.pair)/\(.tier)  \(.state)  \(.command.action)  planned=\(.planned_at)"' "$f"
    done
    [ "$found" -eq 0 ] && _say "  (none — nothing has been planned in $STATE_DIR)"
    return 0
}

cmd_help() {
    sed -n '3,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
    local verb="${1:-help}"; shift || true
    case "$verb" in
        plan)    cmd_plan    "$@" ;;
        execute) cmd_execute "$@" ;;
        verify)  cmd_verify  "$@" ;;
        status)  cmd_status  "$@" ;;
        list)    cmd_list    "$@" ;;
        -h|--help|help) cmd_help ;;
        *) _err "pl erasure: unknown verb '$verb' (plan|execute|verify|status|list)"; return 2 ;;
    esac
}

main "$@"
