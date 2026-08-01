#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/pair.sh — paired-site contract surface (ADR-0031 / ops#75)
#
# Read-only inspection + manual state management for the pair contract that
# lib/pair.sh (pair_guard) consumes. This command NEVER touches a live site.
#
#   pl pair list                      list configured pairs (from nwp.yml)
#   pl pair show <consumer>           print the resolved pair contract
#   pl pair status <consumer>         both sides' recorded versions vs contract
#   pl pair check <site> <tier> [--code-only]
#                                     dry-run the guard decision for a site/tier
#   pl pair record <consumer> <side> <tier> <cv>
#                                     manually record a deployed contract_version
#                                     (side = provider|consumer) — for bootstrap
#   pl pair rag <consumer> <tier> <green|amber|red>
#                                     manually set the pair RAG (testing/recovery)
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
[ -f "$PROJECT_ROOT/lib/common.sh" ] && source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/pair.sh"

show_help() {
    cat <<EOF
${BOLD}NWP Pair — paired-site contract surface (ADR-0031 / ops#75)${NC}

${BOLD}USAGE:${NC}
    pl pair <subcommand> [args]

${BOLD}SUBCOMMANDS:${NC}
    list                              List configured pairs (nwp.yml paired_with)
    show <consumer>                   Print the resolved pair contract
    status <consumer>                 Both sides' recorded versions vs the contract
    check <site> <tier> [--code-only] Dry-run pair_guard's decision (no deploy)
    record <consumer> <side> <tier> <cv>
                                      Record a deployed contract_version
                                      (side = provider|consumer)
    rag <consumer> <tier> <value>     Set the pair RAG (green|amber|red)
    anchor <consumer> <side> <tier> [value]
                                      Get/set an identity anchor (ops#83). side =
                                      provider|consumer. Monotonic: set bumps the
                                      newest identity cut for the both-or-forward
                                      restore gate.
    checkpoint <pair-id> <tier> <CP-id> --provider-anchor=N --consumer-anchor=M
    checkpoint <pair-id> <tier> --list
                                      Record (or list) a PAIRED CHECKPOINT — one
                                      logical cut both halves can be restored to.
                                      This is the "both" branch of both-or-forward;
                                      --paired-restore-ack names one, and the guard
                                      resolves the name against this record rather
                                      than trusting the assertion.
    restore-check <site> <tier> [<target-anchor>] [--code-only]
                                      [--paired-restore-ack=CP-id] [--override-pair]
                                      Dry-run pair_guard_restore's decision (ops#83).
                                      target-anchor is OPTIONAL — omit it to rehearse
                                      the "cut unknown" refusal.
    reconcile <consumer> [--tier=T] [--apply] [--repair-cmd=CMD] [--json]
                                      Detect (and deterministically repair) severed
                                      UID-locks after a provider restore/rebuild —
                                      ops#83 §3, replacing the raw-SQL runbook.
                                      Dry-run by default; fails closed when the
                                      provider ledger or consumer join snapshot
                                      is missing. Orphans are never auto-repaired.

${BOLD}NOTES:${NC}
    * All subcommands are read-only w.r.t. sites; 'record'/'rag'/'anchor' only write
      the local private/pairs/ state that pair_guard reads.
    * A pair id is the CONSUMER site name (e.g. ssc, ssd).
EOF
}

cmd_list() {
    # Reads exactly what pair_guard reads (pair_scan): the committed contracts
    # first, then the two `paired_with:` operator-config shapes. It used to read
    # only nwp.yml's `sites.*.paired_with` — so it agreed with the guard about
    # the real ssc↔nwc pair only by both being blind to it. Exits non-zero when
    # a declaration is unreadable, because a pair list that silently omits a
    # pair is the failure mode this whole fix exists to end.
    print_header "Configured pairs"
    local rows; rows="$(pair_scan)"
    local found=0 blind=0 kind cons prov file
    while IFS=$'\t' read -r kind cons prov file; do
        [ -n "${kind:-}" ] || continue
        if [ "$kind" = "ok" ]; then
            printf '  %-12s (consumer)  ↔  %-12s (provider)   [%s]\n' "$cons" "$prov" "$(basename "$file")"
            found=1
        fi
    done <<< "$rows"
    [ "$found" -eq 0 ] && print_info "No pair is declared (no pairs/*.pair-contract.yml, no 'paired_with:')."

    local problems; problems="$(pair_scan_problems)"
    if [ -n "$problems" ]; then
        blind=1
        echo ""
        print_error "CANNOT VERIFY — unreadable pair declaration(s). This list is NOT complete:"
        while IFS= read -r p; do [ -n "$p" ] && print_error "  - $p"; done <<< "$problems"
        print_info "pair_guard REFUSES promotions while any of these is unreadable."
    fi
    [ "$blind" -eq 0 ]
}

cmd_show() {
    local consumer="${1:?consumer required}"
    local contract; contract="$(pair_contract_file "$consumer")"
    if ! pair_contract_valid "$contract"; then
        print_error "No valid pair contract for '$consumer' at: $contract"
        return 1
    fi
    print_header "Pair contract: $consumer"
    echo "  file: $contract"
    echo ""
    cat "$contract"
}

cmd_status() {
    local consumer="${1:?consumer required}"
    local contract; contract="$(pair_contract_file "$consumer")"
    if ! pair_contract_valid "$contract"; then
        print_error "No valid pair contract for '$consumer' at: $contract"
        print_info  "Author it from pair-contract.example.yml (docs/guides/ops75-pair-contract-schema.md)."
        return 1
    fi
    local provider cv
    provider="$(pair_contract_get "$contract" '.provider')"
    cv="$(pair_contract_get "$contract" '.contract_version')"

    print_header "Pair status: ${consumer} ↔ ${provider}  (contract v${cv})"
    printf '  %-10s %-10s %-10s %-8s\n' "tier" "provider" "consumer" "RAG"
    printf '  %-10s %-10s %-10s %-8s\n' "----" "--------" "--------" "---"
    local tier pcv ccv rag
    for tier in dev stg live prod; do
        pcv="$(pair_state_get "$consumer" provider "$tier")"; [ -z "$pcv" ] && pcv="-"
        ccv="$(pair_state_get "$consumer" consumer "$tier")"; [ -z "$ccv" ] && ccv="-"
        rag="$(pair_rag_get "$consumer" "$tier")"
        printf '  %-10s v%-9s v%-9s %-8s\n' "$tier" "$pcv" "$ccv" "$rag"
    done
    echo ""
    print_info "Contract version = $cv. 'provider'/'consumer' columns = last recorded deployed contract_version per tier."
    print_info "A consumer promotion is refused while its provider column is behind (or '-') for that tier (ADR-0031 D5)."
}

cmd_check() {
    local site="${1:?site required}" tier="${2:?tier required}"; shift 2 || true
    local code_only=false
    for a in "$@"; do [ "$a" = "--code-only" ] && code_only=true; done
    print_header "pair_guard dry-run: site=$site tier=$tier code_only=$code_only"
    if pair_guard "$site" "$tier" "pair-check" "$code_only" "false"; then
        print_status "OK" "pair_guard would ALLOW this promotion."
    else
        print_status "FAIL" "pair_guard would REFUSE this promotion (see above)."
        return 1
    fi

    # Boundary manifest-honesty (P74 Phase 1), run WHERE THE CORPUS EXISTS.
    # This check needs the provider trees under sites/<provider>/ on disk; in
    # nwp CI sites/* is gitignored, so 5 of the 7 declared surfaces can never
    # be scanned there and the old boundary:classify CI step was red on every
    # MR by construction (ops#165). The workstation running a promotion
    # dry-run is exactly the machine that HAS the corpus and exactly the
    # moment the manifest's honesty matters — so it lives here now, and it is
    # part of the verdict: a leaked boundary symbol (exit 1) or an
    # unverifiable manifest (exit 2) fails the check the same way a guard
    # refusal does. Direct verb: `pl impact --honesty`.
    echo ""
    print_header "boundary manifest-honesty (pl impact --honesty --pair=$site)"
    if [ ! -f "${NWP_PAIR_CONTRACT_DIR:-$PROJECT_ROOT/pairs}/${site}.pair-contract.yml" ]; then
        print_status "WARN" "no pairs/${site}.pair-contract.yml — nothing to honesty-check for this site."
        return 0
    fi
    local rc=0
    "$PROJECT_ROOT/scripts/commands/impact.sh" --honesty --pair="$site" || rc=$?
    case "$rc" in
        0) print_status "OK" "boundary manifest verified clean." ;;
        1) print_status "FAIL" "boundary symbol(s) referenced outside their declared paths (see above)."; return 1 ;;
        *) print_status "FAIL" "boundary manifest could NOT be verified here (corpus/yq missing — see above). Run where sites/ is checked out."; return 1 ;;
    esac
}

cmd_record() {
    local consumer="${1:?consumer required}" side="${2:?side required}" tier="${3:?tier required}" cv="${4:?cv required}"
    case "$side" in provider|consumer) ;; *) print_error "side must be provider|consumer"; return 1 ;; esac
    pair_guard_record "$consumer" "$side" "$tier" "$cv"
    print_status "OK" "Recorded ${consumer} ${side}@${tier} = contract_version ${cv}"
}

cmd_rag() {
    local consumer="${1:?consumer required}" tier="${2:?tier required}" value="${3:?value required}"
    case "$value" in green|amber|red) ;; *) print_error "value must be green|amber|red"; return 1 ;; esac
    pair_rag_set "$consumer" "$tier" "$value"
    print_status "OK" "Set RAG ${consumer}@${tier} = ${value}"
}

# ops#83: get/set identity anchors used by the both-or-forward restore gate.
cmd_anchor() {
    local consumer="${1:?consumer required}" side="${2:?side required}" tier="${3:?tier required}" value="${4:-}"
    case "$side" in provider|consumer) ;; *) print_error "side must be provider|consumer"; return 1 ;; esac
    if [ -z "$value" ]; then
        local cur; cur="$(pair_anchor_get "$consumer" "$side" "$tier")"
        printf '%s\n' "${cur:-<unset>}"
        return 0
    fi
    pair_anchor_set "$consumer" "$side" "$tier" "$value" || return 1
    print_status "OK" "Set anchor ${consumer} ${side}@${tier} = ${value}"
}

# ops#83: record a PAIRED CHECKPOINT — a joint cut both halves can be restored
# to. This is the "both" branch of both-or-forward; --paired-restore-ack names
# one of these, and the guard resolves the name against the record.
cmd_checkpoint() {
    local pair_id="" tier="" cp_id="" pa="" ca="" a
    for a in "$@"; do
        case "$a" in
            --provider-anchor=*) pa="${a#*=}" ;;
            --consumer-anchor=*) ca="${a#*=}" ;;
            --list)              cp_id="--list" ;;
            -*) print_error "pair checkpoint: unknown option '$a'"; return 2 ;;
            *)  if   [ -z "$pair_id" ]; then pair_id="$a"
                elif [ -z "$tier" ];    then tier="$a"
                elif [ -z "$cp_id" ];   then cp_id="$a"
                else print_error "pair checkpoint: unexpected argument '$a'"; return 2; fi ;;
        esac
    done
    [ -n "$pair_id" ] && [ -n "$tier" ] || {
        print_error "usage: pl pair checkpoint <pair-id> <tier> <CP-id> --provider-anchor=N --consumer-anchor=M"
        print_info  "       pl pair checkpoint <pair-id> <tier> --list"
        return 2; }

    if [ "$cp_id" = "--list" ] || [ -z "$cp_id" ]; then
        local f; f="$(pair_checkpoint_file "$pair_id" "$tier")"
        print_header "Paired checkpoints: ${pair_id} @ ${tier}"
        if [ ! -s "$f" ]; then
            print_info "None recorded ($f)."
            print_info "Without one, a coupled-tier restore has only the FORWARD branch or a typed override."
            return 0
        fi
        printf '  %-24s %-10s %-10s %s\n' "CP-ID" "PROVIDER" "CONSUMER" "RECORDED"
        awk -F'\t' '{printf "  %-24s %-10s %-10s %s\n", $1, ($2==""?"-":$2), ($3==""?"-":$3), $4}' "$f"
        return 0
    fi

    [ -n "$pa" ] && [ -n "$ca" ] || {
        print_error "pair checkpoint: BOTH --provider-anchor and --consumer-anchor are required."
        print_info  "A checkpoint that names only one half is not a joint cut, and the guard will refuse an ack against it."
        return 2; }
    pair_checkpoint_record "$pair_id" "$tier" "$cp_id" "$pa" "$ca" || return 1
    print_status "OK" "Recorded checkpoint ${cp_id} for ${pair_id}@${tier} (provider=${pa} consumer=${ca})"
    print_info "Restore EACH half with:  --paired-restore-ack ${cp_id}"
    print_info "The pair goes RAG red after the first half lands, and stays red until you re-verify the join."
}

# ops#83: dry-run the both-or-forward restore decision (no restore is performed).
cmd_restore_check() {
    # target-anchor is OPTIONAL. It used to be `${3:?}`, which meant the single
    # most important case — "I do not know what cut this backup is" — died with a
    # raw bash error instead of exercising the guard's own refusal. A dry-run verb
    # that cannot rehearse the fail-closed path is not a dry run.
    local site="${1:?site required}" tier="${2:?tier required}"; shift 2 || true
    local target_anchor="" override=false code_only=false ack="" a
    for a in "$@"; do
        case "$a" in
            --override-pair)         override=true ;;
            --code-only)             code_only=true ;;
            --paired-restore-ack=*)  ack="${a#*=}" ;;
            --anchor=*)              target_anchor="${a#*=}" ;;
            -*) print_error "pair restore-check: unknown option '$a'"; return 2 ;;
            *)  [ -z "$target_anchor" ] && target_anchor="$a" \
                    || { print_error "pair restore-check: unexpected argument '$a'"; return 2; } ;;
        esac
    done
    print_header "pair_guard_restore dry-run: site=$site tier=$tier target_anchor=${target_anchor:-<unknown>} code_only=$code_only ack=${ack:-<none>} override=$override"
    if pair_guard_restore "$site" "$tier" "restore-check" "$target_anchor" "$override" "" "$code_only" "$ack"; then
        print_status "OK" "pair_guard_restore would ALLOW this restore."
    else
        print_status "FAIL" "pair_guard_restore would REFUSE this restore (see above)."
        return 1
    fi
}

################################################################################
# reconcile — ops#83 §3 orphaned-UID-lock detect/repair, as a verb
#
# docs/guides/ops83-dr-restore.md handed the operator four raw SQL statements
# against mdl_user to run over ssh, under DR time pressure, with an email-join
# fallback sitting one line below the safe one. This replaces that with a
# dry-run-by-default verb that classifies every live lock from the two
# artifacts pair_guard_restore already requires, and repairs ONLY the
# deterministically repairable ones.
#
#   pl pair reconcile <consumer> [--tier=T] [--snapshot=FILE] [--ledger=FILE]
#                     [--dry-run|--apply] [--repair-cmd=CMD] [--confirm=TOKEN] [--json]
#
# Fail-closed: a missing ledger, a missing snapshot, or a snapshot with zero
# live rows is CANNOT-VERIFY and exits non-zero. "Nothing to reconcile" and
# "nothing to reconcile WITH" must never print the same thing.
################################################################################
cmd_reconcile() {
    local consumer="" tier="live" snapshot="" ledger="" apply=false repair_cmd="" \
          confirm="${NWP_PAIR_RECONCILE_CONFIRM:-}" json=false arg
    for arg in "$@"; do
        case "$arg" in
            --tier=*)       tier="${arg#*=}" ;;
            --snapshot=*)   snapshot="${arg#*=}" ;;
            --ledger=*)     ledger="${arg#*=}" ;;
            --apply)        apply=true ;;
            --dry-run)      apply=false ;;
            --repair-cmd=*) repair_cmd="${arg#*=}" ;;
            --confirm=*)    confirm="${arg#*=}" ;;
            --json)         json=true ;;
            -*) print_error "pair reconcile: unknown option '$arg'"; return 2 ;;
            *)  [ -z "$consumer" ] && consumer="$arg" || { print_error "pair reconcile: unexpected argument '$arg'"; return 2; } ;;
        esac
    done
    [ -n "$consumer" ] || { print_error "pair reconcile: a consumer (pair id) is required"; return 2; }

    local contract; contract="$(pair_contract_file "$consumer")"
    if ! pair_contract_valid "$contract"; then
        print_error "pair reconcile: CANNOT-VERIFY — no valid pair contract for '$consumer' at $contract"
        return 1
    fi
    local provider; provider="$(pair_contract_get "$contract" '.provider')"

    [ -n "$ledger" ]   || ledger="$(pair_ledger_file "$consumer")"
    [ -n "$snapshot" ] || snapshot="$(pair_join_snapshot_file "$consumer" "$tier")"

    print_header "Pair reconcile: ${consumer} ↔ ${provider} @ ${tier}  (ops#83 §3)"
    echo "  provider identity ledger : $ledger"
    echo "  consumer join snapshot   : $snapshot"
    echo ""

    local blocked=0
    if [ ! -f "$ledger" ] || [ ! -s "$ledger" ] || ! grep -q '"t":"snap"' "$ledger" 2>/dev/null; then
        print_error "CANNOT-VERIFY — the provider identity ledger is absent or holds no snapshot."
        print_info  "  Capture one: scripts/f26/nwc-identity-ledger.sh dump --pair=$consumer"
        print_info  "  Without it there is no deterministic old-uid→uuid map, and email is not a safe substitute."
        blocked=1
    fi
    if [ ! -f "$snapshot" ]; then
        print_error "CANNOT-VERIFY — the consumer join snapshot is absent."
        print_info  "  Capture it on the consumer BEFORE any coupled-tier restore (ops#83 §2):"
        print_info  "    SELECT id AS mdl_id, idnumber AS locked_sub, email, deleted"
        print_info  "      FROM mdl_user WHERE idnumber <> '' AND deleted = 0;"
        print_info  "  …written as TSV to $snapshot"
        blocked=1
    fi
    [ "$blocked" -eq 0 ] || return 1

    local rows; rows="$(pair_reconcile_classify "$ledger" "$snapshot")" || {
        print_error "CANNOT-VERIFY — the ledger/snapshot pair could not be classified (jq missing, or an empty ledger snapshot)."
        return 1
    }
    if [ -z "$rows" ]; then
        print_error "CANNOT-VERIFY — the join snapshot holds ZERO live locks."
        print_info  "  An empty corpus scanning clean is not the same as an intact join. Re-capture the snapshot."
        return 1
    fi

    local n_intact n_repair n_orphan
    n_intact="$(printf '%s\n' "$rows" | grep -c '^intact'     || true)"
    n_repair="$(printf '%s\n' "$rows" | grep -c '^repairable' || true)"
    n_orphan="$(printf '%s\n' "$rows" | grep -c '^orphaned'   || true)"

    local cls mdl_id locked target
    while IFS=$'\t' read -r cls mdl_id locked target; do
        [ -n "$cls" ] || continue
        case "$cls" in
            intact)     [ "$json" = true ] || print_status "OK"   "intact      mdl_id=$mdl_id  sub=$locked" ;;
            repairable) print_status "WARN" "repairable  mdl_id=$mdl_id  locked=$locked  →  $target" ;;
            orphaned)   print_status "FAIL" "orphaned    mdl_id=$mdl_id  locked=$locked  (no ledger row — human-gated)" ;;
        esac
    done <<< "$rows"
    echo ""
    printf '  intact=%s  repairable=%s  orphaned=%s\n' "$n_intact" "$n_repair" "$n_orphan"

    if [ "$json" = true ]; then
        jq -cn --argjson i "$n_intact" --argjson r "$n_repair" --argjson o "$n_orphan" \
               --arg pair "$consumer" --arg tier "$tier" \
               '{pair:$pair, tier:$tier, intact:$i, repairable:$r, orphaned:$o}'
    fi

    if [ "$n_repair" -eq 0 ] && [ "$n_orphan" -eq 0 ]; then
        echo ""
        print_status "OK" "JOIN INTACT — every live UID-lock resolves on the provider."
        return 0
    fi

    # ---- repair --------------------------------------------------------------
    local rc=1
    if [ "$apply" != true ]; then
        echo ""
        print_info "Dry run — nothing was changed. Re-run with --apply --repair-cmd=CMD to repoint"
        print_info "the ${n_repair} repairable lock(s). Orphans are never auto-repaired (ops#83: the"
        print_info "email fallback is a human-gated last resort; a recycled address re-points a lock"
        print_info "at the wrong person)."
        return 1
    fi

    if [ -z "$repair_cmd" ]; then
        print_error "NO-REPAIR-EXECUTOR — --apply needs --repair-cmd=CMD."
        print_info  "  CMD is invoked once per repairable lock as: CMD <mdl_id> <new_idnumber>"
        print_info  "  (e.g. a 'pl moodle cli <site> --tier=$tier --execute -- …' wrapper). This verb"
        print_info  "  deliberately holds no DB credentials and issues no SQL of its own."
        return 1
    fi
    local couples_reason couples_rc=0
    couples_reason="$(pair_contract_couples_tier "$contract" "$tier")" || couples_rc=$?
    if [ "$couples_rc" -eq 2 ]; then
        # An illegible coupling clause must not read as "no confirm needed" —
        # that would skip the typed confirm on exactly the tier it protects.
        print_error "CANNOT VERIFY whether '$tier' is a coupled tier — the contract's identity"
        print_error "coupling declaration is illegible: ${couples_reason}"
        print_info  "  Fix the identity: block in $(basename "$contract"), then re-run."
        return 1
    fi
    if [ "$couples_rc" -eq 0 ] && [ "$confirm" != "RECONCILE-APPLY" ]; then
        print_error "CONFIRM required — '$tier' is a coupled tier carrying real member identities."
        print_info  "  Re-run with --confirm=RECONCILE-APPLY once you have read the classification above."
        return 1
    fi

    local failed=0 done_n=0
    while IFS=$'\t' read -r cls mdl_id locked target; do
        [ "$cls" = "repairable" ] || continue
        [ -n "$target" ] || continue
        # Subshell on purpose: a repair command that calls `exit` (or trips
        # `set -e` inside a sourced wrapper) must fail THAT repair, not abort
        # the reconcile mid-run and leave the operator unsure what applied.
        if ( eval "$repair_cmd $(printf '%q %q' "$mdl_id" "$target")" ); then
            done_n=$((done_n + 1))
            pair_ledger_append "$consumer" "action=reconcile-repair tier=$tier mdl_id=$mdl_id from=$locked to=$target"
            print_status "OK" "repaired mdl_id=$mdl_id  →  $target"
        else
            failed=$((failed + 1))
            print_status "FAIL" "REPAIR-FAILED mdl_id=$mdl_id  →  $target"
        fi
    done <<< "$rows"

    echo ""
    if [ "$failed" -gt 0 ]; then
        print_error "REPAIR-FAILED — ${failed} of ${n_repair} repair(s) did not apply."
        return 1
    fi
    print_status "OK" "Repaired ${done_n} lock(s)."
    if [ "$n_orphan" -gt 0 ]; then
        print_error "${n_orphan} orphaned lock(s) remain — these need an operator decision (ops#83 §3)."
        return 1
    fi
    rc=0
    return "$rc"
}

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        -h|--help|"") show_help ;;
        list)   cmd_list "$@" ;;
        show)   cmd_show "$@" ;;
        status) cmd_status "$@" ;;
        check)  cmd_check "$@" ;;
        record) cmd_record "$@" ;;
        rag)    cmd_rag "$@" ;;
        anchor) cmd_anchor "$@" ;;
        checkpoint)    cmd_checkpoint "$@" ;;
        restore-check) cmd_restore_check "$@" ;;
        reconcile)     cmd_reconcile "$@" ;;
        *) print_error "Unknown subcommand: $sub"; show_help; exit 1 ;;
    esac
}

main "$@"
