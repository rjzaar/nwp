#!/usr/bin/env bash
#
# pl operating-model — generate + gate the read-first document's state block
#                      (ops#319 F2 / Tranche 2: injection becomes projection).
#
# WHY THIS IS A VERB
# ------------------
# `~/central/nwc-internal/OPERATING-MODEL.md` is injected into every ops prompt
# by a UserPromptSubmit hook. That makes it the most authoritative surface in
# the estate — and, measured on 2026-08-09, one of the stalest: it asserted the
# agent-loop was "paused" while the loop was armed and running on the ai-host,
# and printed an issue map stopping at ops#53 while the queue was past ops#332.
# Its top was a stack of "⇢ STATE UPDATE" banners correcting a body nobody
# regenerated.
#
# The estate already knows the cure and applies it elsewhere: `.nwp-review-mode`
# is a GENERATED PROJECTION of `approvers:`, and there is deliberately no verb
# to hand-set it. This verb does the same for operating state. Facts about the
# current world are measured and written between DO-NOT-EDIT markers; doctrine
# stays hand-written prose, because a sentence about what we intend does not go
# stale when the fleet moves.
#
# SUBCOMMANDS
#   state    [--json] [--budget=SEC]   render the generated block to stdout
#   sync     [--file=F] [--dry-run]    splice a fresh block into the document
#   status   [--file=F] [--json]       freshness verdict — the staleness gate
#   inject   [--file=F] [--refresh]    what the injection hook calls
#   lint     [--file=F]                contradictions (also: pl doc-truth --projection)
#
# EXIT
#   0 ok / FRESH · 1 STALE or findings · 2 CANNOT VERIFY (missing, hand-edited,
#   unreadable). Exit 2 is never a pass — grade it AMBER, never green.
#
set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh" 2>/dev/null || true
source "$PROJECT_ROOT/lib/operating-model.sh"
: "${YQ:=yq}"

usage() { sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

_arg_file() {
  local a
  for a in "$@"; do case "$a" in --file=*) printf '%s' "${a#--file=}"; return 0 ;; esac; done
  printf '%s' "$OM_DOC"
}

cmd_state() {
  local a
  for a in "$@"; do
    case "$a" in
      --budget=*) OM_BUDGET_SEC="${a#--budget=}" ;;
      --json)     om_render_json; return $? ;;
      -h|--help)  usage; return 0 ;;
    esac
  done
  om_render_block
}

cmd_sync() {
  local file dry=0 a
  file="$(_arg_file "$@")"
  for a in "$@"; do case "$a" in --dry-run) dry=1 ;; --budget=*) OM_BUDGET_SEC="${a#--budget=}" ;; esac; done
  if [ ! -e "$file" ]; then
    print_error "operating-model: no such document: $file"
    print_info   "Point it with --file=PATH or NWP_OPERATING_MODEL_FILE."
    return 2
  fi
  if [ "$dry" = 1 ]; then
    print_header "operating-model sync --dry-run → $file"
    om_render_block
    return 0
  fi
  om_sync "$file" || return 2
  om_status "$file" || true
  print_success "state block regenerated in $file ($OM_REASON)"
  # Report, immediately, whether the hand-written half now disagrees with what
  # was just measured. Regenerating the block does NOT fix a stale sentence in
  # the prose, and silently leaving one there is the whole defect.
  local findings; findings="$(om_lint "$file" || true)"
  if printf '%s' "$findings" | grep -q '^projection-contradiction\|^state-banner'; then
    print_warning "the hand-written prose still disagrees with the measurements:"
    printf '%s\n' "$findings" | grep '^projection-contradiction\|^state-banner' \
      | while IFS='|' read -r k w d; do print_error "[$k] $w → $d"; done
    return 1
  fi
  return 0
}

cmd_status() {
  local file json=0 a rc=0
  file="$(_arg_file "$@")"
  for a in "$@"; do case "$a" in --json) json=1 ;; esac; done
  om_status "$file" || rc=$?
  if [ "$json" = 1 ]; then
    printf '{"file":"%s","verdict":"%s","age_min":"%s","horizon_min":"%s","reason":"%s"}\n' \
      "$file" "$OM_VERDICT" "${OM_AGE_MIN:-}" "${OM_HORIZON_SEEN:-}" "$(_om_jstr "$OM_REASON")"
    return $rc
  fi
  case "$OM_VERDICT" in
    FRESH) print_success "FRESH — $OM_REASON" ;;
    STALE) print_error   "STALE — $OM_REASON"; print_info "Regenerate: pl operating-model sync" ;;
    *)     print_error   "CANNOT VERIFY ($OM_VERDICT) — $OM_REASON" ;;
  esac
  return $rc
}

# ── inject — the hook's entry point ──────────────────────────────────────────
#
# THE GATE, IN ONE SENTENCE: an injected document may not look authoritative
# about state it cannot demonstrate is current.
#
# FRESH  → confirm it, briefly, with the age. The AI may rely on the block.
# STALE / MISSING / HAND-EDITED → do NOT present the document's state as
#   current. Try ONE bounded regeneration (addendum S3 prefers
#   generate-at-injection: age≈0 or honestly blind beats a file mtime), and if
#   that fails, emit a loud banner instead. Fail-closed to LESS information —
#   never to stale-as-fresh.
#
# It always exits 0. A hook that fails hard would silently drop the injection
# altogether, which is the failure mode it exists to prevent.
cmd_inject() {
  local file refresh=1 a rc=0
  file="$(_arg_file "$@")"
  for a in "$@"; do case "$a" in --no-refresh) refresh=0 ;; --budget=*) OM_BUDGET_SEC="${a#--budget=}" ;; esac; done

  om_status "$file" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '=== OPERATING-MODEL state gate: FRESH ===\n'
    printf 'The generated state block in %s was measured %s min ago (horizon %s min).\n' \
      "$file" "$OM_AGE_MIN" "$OM_HORIZON_SEEN"
    printf 'Its figures are readings, not recollections; prefer them over anything you remember.\n'
    return 0
  fi

  printf '=== ⛔ OPERATING-MODEL state gate: %s ===\n' "$OM_VERDICT"
  printf '%s\n\n' "$OM_REASON"
  printf 'DO NOT treat any state claim in %s as current — not the loop status,\n' "$file"
  printf 'not the issue map, not the phase table, not what is deployed. Its DOCTRINE\n'
  printf '(north star, session protocol, trust model) is still good; its STATE is not.\n\n'

  if [ "$refresh" = 1 ]; then
    local block
    block="$(cmd_state 2>/dev/null)" || block=""
    if [ -n "$block" ]; then
      printf 'Measured just now instead (this supersedes the document):\n\n%s\n' "$block"
      return 0
    fi
  fi
  printf 'A live regeneration was also not possible here. Derive what you need:\n'
  printf '  pl session brief   ·   pl issue ls   ·   pl rag   ·   pl loop --host <role> status\n'
  printf 'and run `pl operating-model sync` before relying on the document again.\n'
  return 0
}

cmd_lint() {
  local file out rc=0
  file="$(_arg_file "$@")"
  # Measurements first: three of the four rules are conditional on them, and a
  # rule that fires without a measurement is the stale literal it is policing.
  om_collect_sections
  out="$(om_lint "$file")" || rc=$?
  print_header "operating-model lint — hand-written claims vs measured state"
  if [ -z "$out" ]; then
    print_success "no contradictions: $file agrees with what was just measured"
    return 0
  fi
  local kind where detail nfind=0 nblind=0
  while IFS='|' read -r kind where detail; do
    [ -n "$kind" ] || continue
    case "$kind" in
      projection-blind) print_warning "[CANNOT VERIFY] $where → $detail"; nblind=$((nblind+1)) ;;
      *)                print_error   "[$kind] $where → $detail"; nfind=$((nfind+1)) ;;
    esac
  done < <(printf '%s\n' "$out")
  [ "$nblind" -gt 0 ] && print_warning "$nblind measurement(s) unavailable — those rules stood down (UNCHECKED, not clean)"
  if [ "$nfind" -gt 0 ]; then
    print_warning "$nfind finding(s). Fix the prose (delete the state claim; the block carries it) then: pl operating-model sync"
    return 1
  fi
  return 2
}

main() {
  local cmd="${1:-status}"; shift || true
  case "$cmd" in
    state)   cmd_state "$@" ;;
    sync)    cmd_sync "$@" ;;
    status)  cmd_status "$@" ;;
    inject)  cmd_inject "$@" ;;
    lint)    cmd_lint "$@" ;;
    -h|--help|help) usage ;;
    *) print_error "pl operating-model: unknown subcommand '$cmd'"; usage; return 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
