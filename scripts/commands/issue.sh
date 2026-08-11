#!/bin/bash
set -euo pipefail
################################################################################
# pl issue — list / inspect the nwp/ops GitLab issue queue (the ops work board)
#
# Values-safe: the api token is read from .secrets.yml by THIS script and used
# only inside a 0600 curl config — never printed, never in argv/ps/history.
# Prefers the least-privilege gitlab.ops_note_token (Reporter on nwp/ops),
# falling back to gitlab.api_token.
#
# Usage:
#   pl issue ls [--all] [--pending|--approved|--needs-human] [--project=ops|nwc|all]
#                            list issues across BOTH trackers — src # gate title labels
#   pl issue approve <ref>   add `agent-eligible` (refuses on `needs-human`)
#   pl issue show <ref>      show one issue: fields, description, comment thread
#   pl issue url <ref>       print the web URL for one issue
#   pl issue create ...      open a new issue (--title/--desc/--label)
#   pl issue comment <ref>   add a comment   ·  close/reopen/label <ref>
#   pl issue work <iid>      create/open isolated worktree ~/nwp-ops<iid> (branch
#                            ops-<iid>, tools+fleet linked) and LAUNCH Claude in it with
#                            the first prompt. --no-launch just creates it. Override the
#                            launcher via NWP_CLAUDE_CMD (e.g. set it to your `co`).
#
# <ref> is a bare number (= nwp/ops) or a qualified `ops#179` / `nwc#8`, exactly
# as `ls` prints it.
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Two roots, deliberately (ops#307): the LIBRARIES always come from the tree
# this script sits in (a fixture estate has no lib/), while the ESTATE root —
# the git repo, the singleton state — honours an existing PROJECT_ROOT so tests
# can run cmd_work against a fixture instead of leaking branches into ~/nwp.
SELF_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$SELF_ROOT}"
source "$SELF_ROOT/lib/ui.sh"
source "$SELF_ROOT/lib/common.sh" 2>/dev/null || true

SECRETS_FILE="${NWP_SECRETS_FILE:-$PROJECT_ROOT/.secrets.yml}"
PROJECT_ID="${NWP_OPS_PROJECT_ID:-21}"          # nwp/ops
YQ="$(command -v yq || true)"

die(){ print_error "$*"; exit 1; }

# One scratch dir per process, cleaned by the EXIT trap installed in the
# executed-as-a-script guard at the bottom. NOT a per-function `trap … RETURN`:
# a RETURN trap set inside a function stays installed and fires again when the
# CALLER returns, by which point its `local` is gone — under `set -u` that made
# `pl issue ls` print a perfect list and then exit 1.
NWP_ISSUE_TMP=""
_tmpdir(){
  [ -n "$NWP_ISSUE_TMP" ] || NWP_ISSUE_TMP=$(mktemp -d)
  printf '%s' "$NWP_ISSUE_TMP"
}

# _tmpdir_cleanup — deliberately NOT `rm -rf`.
#
# lib/impact.sh's detector reads `rm -rf` on a code line as a DESTRUCTIVE
# operation and requires the file to adopt the impact contract (fate manifest +
# typed confirm) or sit on a shrink-only allowlist. Both would be wrong here:
# `pl issue ls` is a read verb and has no business rendering a fate manifest,
# and the allowlist's own header says adding a row needs a recorded decision.
# The detector is not being worked around — the recursion genuinely is not
# needed. This directory only ever holds a handful of flat `*.tsv` files that
# THIS process wrote, and `rmdir` REFUSES if anything unexpected (a
# subdirectory) ever appears, which is a better outcome than erasing it.
_tmpdir_cleanup(){
  [ -n "${NWP_ISSUE_TMP:-}" ] || return 0
  rm -f "$NWP_ISSUE_TMP"/*.tsv 2>/dev/null || true
  rmdir "$NWP_ISSUE_TMP" 2>/dev/null || true
}

# Shared GitLab issue API plumbing (_host/_token/_api_get/_api_send/_jget/
# _require_ok/_api_rows). Extracted to a lib so `pl rag --sync-issues` reuses it
# (ops#6) and so there is exactly ONE paginating collection read (_api_rows).
source "$SELF_ROOT/lib/gitlab-issues.sh"

################################################################################
# ISSUE SOURCES — the operator has TWO trackers, not one.
#
# `pl issue` addressed only nwp/ops (project 21). But tester feedback synced out
# of nwd by `drush nwc-feedback:sync-to-gitlab` lands in nwp/nwc (project 16) —
# e.g. nwc#8 "[feedback-2] help topic should be clickable". The operator had no
# way to see their own testers' reports from `pl` at all.
#
# The combined view (rather than a --project flag alone) is the right grain for
# THIS verb for one concrete reason: the agent-loop already treats the two as a
# single queue — `AGENT_LOOP_PROJECT_IDS` defaults to "16,21" and it polls both
# for `agent-eligible`. A queue the machine reads as one and the operator can
# only read as two is a queue the operator cannot supervise. `--project=` is
# still there to narrow.
#
# TOKENS: nwp/ops keeps the least-privilege ops_note_token. That token cannot
# see nwp/nwc at all (measured 2026-08-02: `404 Project Not Found`), so the nwc
# source names the group bot explicitly rather than pretending the project is
# empty.
################################################################################
OPS_PROJECT_ID="${NWP_OPS_PROJECT_ID:-21}"      # nwp/ops — the ops work board
NWC_PROJECT_ID="${NWP_NWC_PROJECT_ID:-16}"      # nwp/nwc — where tester feedback lands
SRC_NAME="ops"; SRC_SLUG="nwp/ops"

# _resolve_source <spec> — point PROJECT_ID / SRC_* / the token at one tracker.
_resolve_source(){
  local spec="${1:-ops}"
  case "$spec" in
    ops|nwp/ops)
      SRC_NAME="ops"; SRC_SLUG="nwp/ops"; PROJECT_ID="$OPS_PROJECT_ID"
      GITLAB_TOKEN_EXPR='.gitlab.ops_note_token // .gitlab.api_token // ""' ;;
    nwc|nwp/nwc|feedback)
      SRC_NAME="nwc"; SRC_SLUG="nwp/nwc"; PROJECT_ID="$NWC_PROJECT_ID"
      GITLAB_TOKEN_EXPR='.gitlab.api_token // ""' ;;
    *[!0-9]*|'')
      die "unknown issue source: '$spec' (expected: ops | nwc | all | <numeric project id>)" ;;
    *)
      if [ "$spec" = "$OPS_PROJECT_ID" ]; then _resolve_source ops; return; fi
      if [ "$spec" = "$NWC_PROJECT_ID" ]; then _resolve_source nwc; return; fi
      SRC_NAME="p$spec"; SRC_SLUG=""; PROJECT_ID="$spec"
      GITLAB_TOKEN_EXPR='.gitlab.ops_note_token // .gitlab.api_token // ""' ;;
  esac
}

# _use_ref <ref> — accept `179`, `ops#179`, `nwc#8`, `nwp/nwc#8`, `16#8`; point
# the plumbing at that tracker and set REF_IID to the bare number. A bare number
# keeps the historical meaning (nwp/ops), so every existing invocation is
# unchanged.
#
# It sets a GLOBAL rather than printing, because `iid=$(_use_ref …)` would run
# it in a subshell and throw away the very thing it exists to set — the project
# it selected. (That is not hypothetical: it was the first cut of this function,
# and `pl issue show nwc#8` silently read nwp/ops#8 instead.)
REF_IID=""
_use_ref(){
  local a="${1:-}" src
  case "$a" in
    *'#'*) src="${a%%#*}"; REF_IID="${a##*#}" ;;
    *)     src="${SRC_SPEC:-ops}"; REF_IID="$a" ;;
  esac
  [ "$src" = "all" ] && src="ops"
  _resolve_source "$src"
}

# _issue_web_url <iid> — for the CURRENTLY resolved source.
_issue_web_url(){
  local iid="$1"
  if [ -z "${SRC_SLUG:-}" ]; then
    SRC_SLUG=$(_api_get "/projects/$PROJECT_ID" | _jget path_with_namespace)
  fi
  if [ -n "${SRC_SLUG:-}" ]; then
    printf 'https://%s/%s/-/issues/%s\n' "$(_host)" "$SRC_SLUG" "$iid"
  else
    printf '(project %s, issue %s — no web URL: this token cannot read the project)\n' "$PROJECT_ID" "$iid"
  fi
}

################################################################################
# THE APPROVAL GATE, TOLD HONESTLY.
#
# `agent-eligible` is the label the agent-loop polls for. `.loop-paused` has sat
# in the runtime tree since 2026-07-18, so adding that label today changes
# nothing — and nothing in `pl issue` said so. A gate that silently does nothing
# is worse than an absent gate, because the operator believes they acted.
#
# The authority is lib/loop-parts.sh (the same check the cron wrappers make), so
# this cannot drift from what actually gates the loop.
################################################################################
# shellcheck source=/dev/null
[ -f "$SELF_ROOT/lib/loop-parts.sh" ] && source "$SELF_ROOT/lib/loop-parts.sh"

# _loop_gate_reason → rc 0 + "<reason>\t<exact remedy>" if the fix-loop will NOT
# run; rc 1 if it will.
#
# The remedy is per-cause and checked against the code, not guessed: `pl loop
# enable all` writes `all=enabled` to the parts state and does NOT delete the
# legacy `.loop-paused` sentinel (lib/loop-parts.sh:loop_part_set), so telling a
# sentinel-paused operator to run it would leave the loop just as dead — the
# same "you acted, nothing happened" failure this whole item is about.
_loop_gate_reason(){
  declare -F loop_part_enabled >/dev/null 2>&1 || return 1
  loop_part_enabled fix-loop >/dev/null 2>&1 && return 1
  local root; root="$(_loop_nwp_root)"
  if [ -f "$root/.loop-paused" ]; then
    local since; since=$(date -r "$root/.loop-paused" +%Y-%m-%d 2>/dev/null || echo "unknown date")
    printf '.loop-paused sentinel in %s (since %s)\trm %s/.loop-paused   (on EVERY ai-host: pl loop --host <role>)' \
      "$root" "$since" "$root"
  elif [ "$(loop_part_raw all 2>/dev/null)" = "disabled" ]; then
    printf 'loop state all=disabled (%s)\tpl loop enable all' "$(loop_parts_state_file)"
  else
    printf 'loop part fix-loop=disabled (%s)\tpl loop enable fix-loop' "$(loop_parts_state_file)"
  fi
  return 0
}

# _warn_if_loop_paused — every command that ADDS `agent-eligible` calls this.
_warn_if_loop_paused(){
  local line why fix
  if line=$(_loop_gate_reason); then
    why="${line%%$'\t'*}"; fix="${line#*$'\t'}"
    print_warning "the agent loop is PAUSED — $why"
    print_warning "the 'agent-eligible' label is recorded but WILL NOT be acted on until the loop is resumed"
    print_hint "loop state: pl loop status   ·   resume: $fix"
    return 0
  fi
  return 1
}

# _gate_of <labels-csv> → the approval state of one issue, as one word.
_gate_of(){
  local labels=",${1},"
  local ae=0 nh=0
  case "$labels" in *,agent-eligible,*) ae=1 ;; esac
  case "$labels" in *,needs-human,*)    nh=1 ;; esac
  if   [ "$ae" = 1 ] && [ "$nh" = 1 ]; then printf 'CONFLICT'
  elif [ "$ae" = 1 ]; then printf 'approved'
  elif [ "$nh" = 1 ]; then printf 'HUMAN'
  else printf 'pending'
  fi
}

################################################################################
# cmd_ls — list issues across BOTH trackers, paginated, with the approval gate
# shown and the row count stated.
#
# THE BUG THIS REPLACES: the old body issued one `per_page=100` GET and printed
# whatever came back. nwp/ops had 136 open issues, so it showed 100 and said
# nothing. `order_by=created_at&sort=asc` meant the 36 it dropped were the
# NEWEST — the exact rows an operator opens the list to triage. Silent
# truncation reads as completeness; that is the defect, not the cap.
################################################################################
cmd_ls(){
  [ -n "$YQ" ] || die "yq required"
  local state="opened" project="all" filter="" limit=0 a
  for a in "$@"; do
    case "$a" in
      --all)          state="all" ;;
      --pending)      filter="pending" ;;
      --approved)     filter="approved" ;;
      --needs-human)  filter="HUMAN" ;;
      --project=*)    project="${a#*=}" ;;
      --limit=*)      limit="${a#*=}" ;;
      -h|--help)
        cat <<'EOF'
usage: pl issue ls [--all] [--pending|--approved|--needs-human]
                   [--project=ops|nwc|all|<id>] [--limit=N]

  (default)       open issues in BOTH nwp/ops and nwp/nwc, fully paginated
  --all           include closed issues
  --pending       only issues awaiting YOUR approval decision
                  (no agent-eligible, no needs-human)
  --approved      only issues already labelled agent-eligible
  --needs-human   only issues the agent must not pick up
  --project=      narrow to one tracker (ops=nwp/ops, nwc=nwp/nwc feedback)
  --limit=N       cap the rows printed — the cap is always STATED in the footer
EOF
        return 0 ;;
      -*) die "unknown option: $a (try: pl issue ls --help)" ;;
      *)  die "unexpected arg: $a (try: pl issue ls --help)" ;;
    esac
  done
  [[ "$limit" =~ ^[0-9]+$ ]] || die "--limit must be a number"

  local -a specs=()
  case "$project" in
    all) specs=(ops nwc) ;;
    *)   specs=("$project") ;;
  esac

  local tmpd; tmpd=$(_tmpdir)
  local spec rc srcs_read=0 total=0 unreadable="" capped=""
  local rowfile="$tmpd/rows.tsv"; : > "$rowfile"

  for spec in "${specs[@]}"; do
    _resolve_source "$spec"
    rc=0
    _api_rows "/projects/$PROJECT_ID/issues?state=$state&order_by=created_at&sort=asc" \
      '[(.iid|tostring), .state,
        ((.title // "") | sub("\n"; " ") | sub("	"; " ")),
        (.labels | join(","))] | join("	")' \
      > "$tmpd/raw.tsv" || rc=$?
    if [ "$rc" -eq 3 ]; then
      # "I could not look" is NOT "there is nothing there".
      unreadable="${unreadable}${unreadable:+, }${SRC_SLUG:-project $PROJECT_ID}"
      continue
    fi
    srcs_read=$((srcs_read + 1))
    [ "${NWP_API_ROWS_TRUNCATED:-0}" = "1" ] && capped="${capped}${capped:+, }${SRC_SLUG:-project $PROJECT_ID}"
    total=$((total + ${NWP_API_ROWS_COUNT:-0}))
    if [ -s "$tmpd/raw.tsv" ]; then
      awk -v src="$SRC_NAME" 'BEGIN{FS=OFS="\t"} {print src, $0}' "$tmpd/raw.tsv" >> "$rowfile"
    fi
  done

  if [ "$srcs_read" -eq 0 ]; then
    die "could not read any issue tracker (${unreadable:-no source}) — token rejected, or host unreachable"
  fi

  print_header "issues — ${specs[*]} · state: $state${filter:+ · filter: $filter}"

  # Classify + filter into the final render set, counting the gate states over
  # EVERYTHING read (so the summary describes the queue, not the filtered view).
  local n_pending=0 n_approved=0 n_human=0 n_conflict=0 shown=0
  local render="$tmpd/render.tsv"; : > "$render"
  local src iid st title labels gate
  while IFS=$'\t' read -r src iid st title labels; do
    [ -z "$iid" ] && continue
    gate=$(_gate_of "$labels")
    case "$gate" in
      pending)  n_pending=$((n_pending + 1)) ;;
      approved) n_approved=$((n_approved + 1)) ;;
      HUMAN)    n_human=$((n_human + 1)) ;;
      CONFLICT) n_conflict=$((n_conflict + 1)) ;;
    esac
    [ -n "$filter" ] && [ "$gate" != "$filter" ] && continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$src" "$iid" "$st" "$gate" "$title" >> "$render"
    shown=$((shown + 1))
  done < "$rowfile"

  local matched="$shown"
  if [ "$limit" -gt 0 ] && [ "$shown" -gt "$limit" ]; then shown="$limit"; fi

  if [ "$matched" -eq 0 ]; then
    print_warning "no issues matched${filter:+ the '$filter' filter}"
  else
    printf "  %-4s %-5s %-8s %-9s %s\n" "SRC" "#" "STATE" "GATE" "TITLE"
    printf "  %-4s %-5s %-8s %-9s %s\n" "----" "-----" "--------" "---------" "---------------------------------------------"
    head -n "$shown" "$render" | while IFS=$'\t' read -r src iid st gate title; do
      printf "  %-4s ${BOLD}%-5s${NC} %-8s %-9s %-52.52s\n" "$src" "$iid" "$st" "$gate" "$title"
    done
  fi

  # THE HONEST FOOTER. A number here is a claim about completeness, so every
  # reason a row might be missing is named.
  echo
  printf "  read %d issue(s) from %d tracker(s): %s\n" "$total" "$srcs_read" "${specs[*]}"
  if [ "$matched" -ne "$shown" ]; then
    printf "  ${BOLD}showing %d of %d matching (--limit=%d)${NC}\n" "$shown" "$matched" "$limit"
  elif [ "$matched" -eq 0 ]; then
    printf "  showing 0 matching row(s)\n"
  else
    printf "  showing all %d matching row(s) — nothing hidden\n" "$matched"
  fi
  printf "  gate: %d pending · %d approved (agent-eligible) · %d needs-human" \
    "$n_pending" "$n_approved" "$n_human"
  [ "$n_conflict" -gt 0 ] && printf " · ${BOLD}%d CONFLICT${NC}" "$n_conflict"
  echo
  [ "$n_conflict" -gt 0 ] && \
    print_warning "$n_conflict issue(s) carry BOTH agent-eligible and needs-human — the loop's poll filters on agent-eligible only, so it WOULD pick them up"
  [ -n "$unreadable" ] && \
    print_warning "NOT read (so not counted above): $unreadable — this token cannot see it"
  [ -n "$capped" ] && \
    print_warning "page cap reached on: $capped — there may be more issues than shown"
  # If anything is (or is being looked for as) approved, say whether that label
  # is actually being acted on.
  if [ "$n_approved" -gt 0 ] || [ "$n_conflict" -gt 0 ] || [ "$filter" = "approved" ]; then
    _warn_if_loop_paused || true
  fi
  echo
  print_hint "approve one for the agent:  pl issue approve <src>#<n>   ·   detail: pl issue show <src>#<n>"
  print_hint "awaiting your decision:     pl issue ls --pending"
}

################################################################################
# cmd_approve — the operator's "yes, an agent may work this one".
#
# Refuses on `needs-human` and says why. That refusal is load-bearing: the
# loop's own poll is `?state=opened&labels=agent-eligible` with NO exclusion of
# needs-human (scripts/agent-loop/agent-loop.sh), so an issue carrying both
# WOULD be picked up. The policy lives in the nwc feedback classifier
# (GitLabSyncService: doctrine / member-interior / safeguarding signals force
# needs-human); this verb is where it is enforced at the point of decision.
################################################################################
cmd_approve(){
  [ -n "$YQ" ] || die "yq required"
  local ref="" a
  for a in "$@"; do
    case "$a" in
      -h|--help) printf 'usage: pl issue approve <ref>       # ref: 179 | ops#179 | nwc#8\n'; return 0 ;;
      --project=*) SRC_SPEC="${a#*=}" ;;
      -*) die "unknown option: $a (usage: pl issue approve <ref>)" ;;
      *)  [ -z "$ref" ] && ref="$a" || die "unexpected arg: $a" ;;
    esac
  done
  [ -n "$ref" ] || die "usage: pl issue approve <ref>   (ref: 179 | ops#179 | nwc#8)"
  _use_ref "$ref"; local iid="$REF_IID"
  [[ "$iid" =~ ^[0-9]+$ ]] || die "not an issue number: '$ref'"

  local json; json=$(_api_get "/projects/$PROJECT_ID/issues/$iid")
  local title; title=$(printf '%s' "$json" | _jget title)
  [ -n "$title" ] || die "issue $SRC_NAME#$iid not found (or this token cannot read ${SRC_SLUG:-project $PROJECT_ID})"
  local labels; labels=$(printf '%s' "$json" | "$YQ" e -p=json '.labels | join(",")' - 2>/dev/null)
  local state; state=$(printf '%s' "$json" | _jget state)

  case ",${labels}," in
    *,needs-human,*)
      print_error "refusing to approve $SRC_NAME#$iid — it is labelled 'needs-human'"
      printf '    %s\n' "$title"
      print_info "'needs-human' means an agent must NOT pick this up: it was classified as"
      print_info "doctrine / member-interior / safeguarding-shaped, or a human already parked it."
      print_hint "if that classification is wrong, clear it deliberately first:"
      print_hint "  pl issue label $SRC_NAME#$iid --remove needs-human   &&   pl issue approve $SRC_NAME#$iid"
      exit 1 ;;
  esac
  [ "$state" = "opened" ] || die "refusing to approve $SRC_NAME#$iid — it is $state, not open"
  case ",${labels}," in
    *,agent-eligible,*)
      print_info "$SRC_NAME#$iid is already agent-eligible — nothing to change"
      _warn_if_loop_paused || print_success "the loop is running and will pick it up"
      return 0 ;;
  esac

  local payload; payload=$("$YQ" -n -o=json '{"add_labels": "agent-eligible"}')
  local resp; resp=$(_api_send PUT "/projects/$PROJECT_ID/issues/$iid" "$payload")
  _require_ok "$resp" id "approve $SRC_NAME#$iid" >/dev/null
  print_success "approved $SRC_NAME#$iid — $title"
  printf '    %s\n' "$(_issue_web_url "$iid")"
  # The whole point of the verb: never let the operator believe more happened
  # than did.
  _warn_if_loop_paused || print_info "the loop is running — it polls agent-eligible every 30 min"
}


# pl issue board — one screen: every open op grouped by kind (P67 §5e).
# WORK ITEMS (human/agent work) vs RAG-AUTO (fleet-health auto-issues) vs
# recently closed. Same token/plumbing as ls; no MR join (the ops token is
# least-privilege and cannot read code repos — deliberate).
cmd_board(){
  [ -n "$YQ" ] || die "yq required"
  local tmpd; tmpd=$(_tmpdir)
  # PAGINATED (same bug as cmd_ls had: one per_page=100 GET over a 136-issue
  # tracker rendered as a complete board).
  local rc=0
  _api_rows "/projects/$PROJECT_ID/issues?state=opened&order_by=created_at&sort=asc" \
    '[(.iid|tostring), ((.title // "") | sub("\n"; " ") | sub("	"; " ")), (.labels | join(","))] | join("	")' \
    > "$tmpd/open.tsv" || rc=$?
  [ "$rc" -eq 3 ] && die "no response from GitLab (token rejected, or host unreachable)"
  local n_open="${NWP_API_ROWS_COUNT:-0}" capped="${NWP_API_ROWS_TRUNCATED:-0}"
  # DELIBERATE cap, and it is labelled as one below.
  local closed; closed=$(_api_get "/projects/$PROJECT_ID/issues?state=closed&per_page=10&order_by=updated_at&sort=desc")

  print_header "nwp/ops board"

  echo -e "${BOLD}WORK ITEMS (open):${NC}"
  printf "  %-5s %-52s %-10s %s\n" "#" "TITLE" "PRIORITY" "FLAGS"
  # Exact label membership (field 3, comma-separated) — a substring match would
  # also catch a hypothetical "rag-auto-x".
  awk -F'\t' 'BEGIN{OFS="\t"} {n=split($3,L,","); hit=0; for(i=1;i<=n;i++) if(L[i]=="rag-auto") hit=1; if(!hit) print}' \
    "$tmpd/open.tsv" \
  | while IFS=$'\t' read -r iid title labels; do
      prio="-"; flags=""
      case ",$labels," in *,priority::high,*) prio="high" ;; *,priority::medium,*) prio="medium" ;; *,priority::low,*) prio="low" ;; esac
      case ",$labels," in *,agent-eligible,*) flags="agent-eligible" ;; esac
      case ",$labels," in *,needs-human,*)    flags="${flags:+$flags+}needs-human" ;; esac
      printf "  ${BOLD}%-5s${NC} %-52.52s %-10s %s\n" "$iid" "$title" "$prio" "$flags"
    done

  echo ""
  echo -e "${BOLD}RAG-AUTO (fleet health, auto-managed — clears when the site goes green):${NC}"
  local sev
  awk -F'\t' '{n=split($3,L,","); for(i=1;i<=n;i++) if(L[i]=="rag-auto"){print; break}}' \
    "$tmpd/open.tsv" \
  | while IFS=$'\t' read -r iid title labels; do
      sev="🟠"
      case ",$labels," in *,security,*) sev="🔴" ;; esac
      printf "  %s #%-4s %-52.52s\n" "$sev" "$iid" "$title"
    done

  if [ -n "$closed" ] && [ "$("$YQ" e -p=json 'length' <<<"$closed" 2>/dev/null)" != "0" ]; then
    echo ""
    # State the cap. "RECENTLY CLOSED" without a number reads as "all of them".
    echo -e "${BOLD}RECENTLY CLOSED (most recent 10 by update — deliberately capped):${NC}"
    "$YQ" e -p=json -o=tsv '.[] | [.iid, .title, .closed_at]' <<<"$closed" 2>/dev/null \
    | while IFS=$'\t' read -r iid title closed_at; do
        printf "  ${DIM:-}✓ #%-4s %-52.52s %s${NC}\n" "$iid" "$title" "${closed_at:0:10}"
      done
  fi
  echo ""
  printf "  %d open issue(s) read — all shown\n" "$n_open"
  [ "$capped" = "1" ] && print_warning "page cap reached — there may be more open issues than shown"
  print_hint "detail: pl issue show <#>   ·   fleet state: pl rag   ·   work queue: pl todo"
  print_hint "tester feedback lives in nwp/nwc, NOT on this board:  pl issue ls --project=nwc"
}

cmd_url(){
  local ref="${1:-}"; [ -n "$ref" ] || die "usage: pl issue url <ref>   (ref: 179 | ops#179 | nwc#8)"
  _use_ref "$ref"; local iid="$REF_IID"
  _issue_web_url "$iid"
}

# show one issue: header fields + description + the discussion thread (notes)
cmd_show(){
  [ -n "$YQ" ] || die "yq required"
  local ref="${1:-}"; [ -n "$ref" ] || die "usage: pl issue show <ref>   (ref: 179 | ops#179 | nwc#8)"
  _use_ref "$ref"; local iid="$REF_IID"
  [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl issue show <ref>   (ref: 179 | ops#179 | nwc#8)"
  local json; json=$(_api_get "/projects/$PROJECT_ID/issues/$iid")
  [ -n "$json" ] || die "no response from GitLab (token rejected, or host unreachable)"
  local title state author labels created updated desc
  title=$(printf '%s' "$json" | _jget title)
  [ -n "$title" ] || die "issue #$iid not found in ${SRC_SLUG:-project $PROJECT_ID}"
  state=$(printf '%s'  "$json" | _jget state)
  author=$(printf '%s' "$json" | _jget 'author.username')
  labels=$(printf '%s' "$json" | "$YQ" e -p=json '.labels | join(", ")' - 2>/dev/null)
  created=$(printf '%s' "$json" | _jget created_at)
  updated=$(printf '%s' "$json" | _jget updated_at)
  desc=$(printf '%s'   "$json" | "$YQ" e -p=json '.description // ""' - 2>/dev/null)
  print_header "${SRC_SLUG:-project $PROJECT_ID}#$iid — $title"
  printf "  ${BOLD}%-9s${NC} %s\n" "state:"   "$state"
  printf "  ${BOLD}%-9s${NC} %s\n" "author:"  "${author:-?}"
  printf "  ${BOLD}%-9s${NC} %s\n" "labels:"  "${labels:-—}"
  printf "  ${BOLD}%-9s${NC} %s\n" "gate:"    "$(_gate_of "$(printf '%s' "$labels" | tr -d ' ')")"
  printf "  ${BOLD}%-9s${NC} %s\n" "created:" "$created"
  printf "  ${BOLD}%-9s${NC} %s\n" "updated:" "$updated"
  printf "  ${BOLD}%-9s${NC} %s\n" "url:"     "$(_issue_web_url "$iid")"
  echo; echo "$desc"; echo
  # discussion thread (skip GitLab system notes) — PAGINATED: a thread longer
  # than 100 notes used to lose its tail without saying so.
  local tmpd; tmpd=$(_tmpdir)
  _api_rows "/projects/$PROJECT_ID/issues/$iid/notes?sort=asc" \
    'select(.system == false)
     | [(.author.username // "?"), .created_at,
        ((.body // "") | sub("\n"; "  ") | sub("	"; " "))] | join("	")' \
    > "$tmpd/notes.tsv" 2>/dev/null || true
  local n=0; [ -s "$tmpd/notes.tsv" ] && n=$(grep -c . "$tmpd/notes.tsv")
  if [ "$n" -gt 0 ]; then
    print_header "Comments ($n)"
    local who when bd
    while IFS=$'\t' read -r who when bd; do
      printf "  ${BOLD}%s${NC} ${DIM}%s${NC}\n    %s\n\n" "$who" "$when" "$bd"
    done < "$tmpd/notes.tsv"
  fi
}

# create a new issue:  pl issue create --title "..." [--desc "..."] [--label a,b]
cmd_create(){
  [ -n "$YQ" ] || die "yq required"
  local title="" desc="" labels=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -t|--title) title="${2:-}"; shift 2 ;;
      --title=*)  title="${1#*=}"; shift ;;
      -d|--desc|--description) desc="${2:-}"; shift 2 ;;
      --desc=*|--description=*) desc="${1#*=}"; shift ;;
      -l|--label|--labels) labels="${2:-}"; shift 2 ;;
      --label=*|--labels=*) labels="${1#*=}"; shift ;;
      -h|--help)
        echo "usage: pl issue create --title \"...\" [--desc \"...\"] [--label a,b]"
        return 0 ;;
      # An unknown flag must NEVER become the title: `pl issue create --help`
      # once filed a real nwp/ops issue titled "--help" (#186).
      -*) die "unknown option: $1 (usage: pl issue create --title \"...\" [--desc \"...\"] [--label a,b])" ;;
      *) [ -z "$title" ] && { title="$1"; shift; } || die "unexpected arg: $1" ;;
    esac
  done
  [ -n "$title" ] || die "usage: pl issue create --title \"...\" [--desc \"...\"] [--label a,b]"

  # Read a PIPED description when --desc was not given. `pl issue comment`
  # reads stdin; `create` used to ignore it — and an ignored pipe is silent.
  # Measured 2026-08-11: four issues (ops#327, #331, #333, #336) were filed
  # with empty bodies because the text was piped in, including the operator's
  # own recorded rulings. Nothing failed and nothing warned; the loss surfaced
  # days later when an agent read one back. Two sibling verbs disagreeing about
  # stdin is the defect: accept it, or refuse — never accept and discard.
  if [ -z "$desc" ] && [ ! -t 0 ]; then
    desc="$(cat)"
    [ -n "$desc" ] && print_info "description read from stdin ($(printf '%s' "$desc" | wc -c) bytes)"
  fi
  # A title-only issue is legitimate (a stub someone will fill in), so this
  # warns rather than refuses — but it says so, because an issue that records
  # nothing is the thing we just spent an evening repairing.
  [ -n "$desc" ] || print_warning "no description — filing a title-only issue (pass --desc, or pipe the body in)"
  local payload; payload=$(T="$title" D="$desc" L="$labels" "$YQ" -n -o=json \
    '{"title": strenv(T), "description": strenv(D), "labels": strenv(L)}')
  local resp iid; resp=$(_api_send POST "/projects/$PROJECT_ID/issues" "$payload")
  iid=$(_require_ok "$resp" iid "create issue")
  print_success "created ${SRC_SLUG:-nwp/ops}#$iid — $title"
  print_info "$(_issue_web_url "$iid")"
}

# add a comment:  pl issue comment <ref> "text"   (or pipe text on stdin)
cmd_comment(){
  [ -n "$YQ" ] || die "yq required"
  case "${1:-}" in -h|--help) printf 'usage: pl issue comment <ref> "text"   (or pipe text on stdin)\n'; return 0 ;; esac
  local ref="${1:-}"; [ -n "$ref" ] || die "usage: pl issue comment <ref> \"text\""
  _use_ref "$ref"; local iid="$REF_IID"
  [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl issue comment <ref> \"text\""
  shift
  local body="$*"
  [ -z "$body" ] && [ ! -t 0 ] && body="$(cat)"
  [ -n "$body" ] || die "comment body required (argument or stdin)"
  local payload; payload=$(B="$body" "$YQ" -n -o=json '{"body": strenv(B)}')
  local resp; resp=$(_api_send POST "/projects/$PROJECT_ID/issues/$iid/notes" "$payload")
  _require_ok "$resp" id "comment on #$iid" >/dev/null
  print_success "commented on ${SRC_SLUG:-project $PROJECT_ID}#$iid"
}

# close / reopen
_set_state(){ # $1=iid $2=close|reopen  (source already resolved by the caller)
  [ -n "$YQ" ] || die "yq required"
  local iid="$1" ev="$2"
  [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl issue $ev <ref>"
  local payload; payload=$(E="$ev" "$YQ" -n -o=json '{"state_event": strenv(E)}')
  local resp st; resp=$(_api_send PUT "/projects/$PROJECT_ID/issues/$iid" "$payload")
  st=$(_require_ok "$resp" state "$ev #$iid")
  print_success "${SRC_SLUG:-project $PROJECT_ID}#$iid is now: $st"
}
cmd_close(){
  local ref="${1:-}" force=0 a iid=""
  for a in "$@"; do [ "$a" = "--force" ] && force=1; done
  if [ -n "$ref" ] && [ "$ref" != "--force" ]; then _use_ref "$ref"; iid="$REF_IID"; fi
  # Close guard: an issue with an OPEN merge request against it is not done.
  # Closing it makes the tracker assert completion while the code is unlanded —
  # the exact shape that produced "ops#133 closed 2026-07-25 with Phase 2
  # unlanded" and "ops#98 closed while its implementing commit never merged".
  #
  # ops#235: for its whole life this guard asked project 21 with a token walled
  # to project 21, and GitLab answered `[]` instead of 403 — so it could only
  # ever say "0 open MRs". Every close since it was written was unguarded.
  # `issue_open_mrs` escalates the READ to a token that can see the code
  # projects and, crucially, distinguishes 0 from BLIND (rc 3).
  if [ "$force" = "0" ] && [[ "$iid" =~ ^[0-9]+$ ]]; then
    # CONFLICT RESOLUTION, 2026-08-03 (!320 rebased over !338/ops#235). Two
    # versions of this guard existed. The one kept is main's, because on
    # "I cannot read the related MRs" it REFUSES (exit 3); !320's only printed a
    # warning and closed the issue anyway, which is the precise failure ops#235
    # was filed about. !320's contribution here — pagination — is kept, but
    # underneath: `issue_open_mrs` now walks every page (lib/gitlab-issues.sh).
    local open_list rc=0
    open_list=$(issue_open_mrs "$iid") || rc=$?
    case "$rc" in
      1)
        print_error "refusing to close ${SRC_SLUG:-nwp/ops}#$iid: open merge request(s) still reference it"
        printf '%s\n' "$open_list" | sed 's/^/  /'
        print_hint "land the MR first, or: pl issue close ${ref:-$iid} --force"
        exit 1
        ;;
      3)
        # CANNOT-VERIFY. Refusing here is the whole lesson of ops#235: a guard
        # that cannot look must not report a pass. rc 3 mirrors `pl server health`.
        print_error "refusing to close ${SRC_SLUG:-nwp/ops}#$iid: CANNOT VERIFY whether an MR is open"
        echo "  No available token can read the declared code project(s): $(_code_projects | tr '\n' ' ' | sed 's/ *$//')"
        echo "  An empty related-MR list from a walled token is blindness, not evidence (ops#235)."
        print_hint "fix the token scope, or override deliberately: pl issue close ${ref:-$iid} --force"
        exit 3
        ;;
    esac
  fi
  _set_state "$iid" close
}
cmd_reopen(){
  local ref="${1:-}"; [ -n "$ref" ] || die "usage: pl issue reopen <ref>"
  _use_ref "$ref"; local iid="$REF_IID"
  _set_state "$iid" reopen
}

# NOTE: `_open_mrs_for` (the version of this reader shipped on this branch)
# was DROPPED in the 2026-08-03 rebase. `issue_open_mrs` in lib/gitlab-issues.sh
# does the same job and two things this one could not: it escalates to a token
# that can actually SEE the code projects, and it reports blindness as rc 3
# instead of as an empty list (ops#235). It is now paginated too.

################################################################################
# pl issue reconcile — make the tracker agree with what actually landed.
#
# WHY: nothing reconciled the two. Issues stay open after their work merges
# (ops#143, ops#86); issues get closed while their implementing branch never
# merged (ops#98, ops#133 Phase 2); notes cite branches and MRs that do not
# exist. Every one of those is a *silent* wrong assertion by the tracker.
#
# Read-only by default. Reports three classes:
#   MERGED-BUT-OPEN   `ops#N` appears in origin/main history; issue still open
#   CLOSED-BUT-OPEN-MR   issue closed while an MR referencing it is still open
#   STALE-REF         the issue text names a branch that exists on no remote
################################################################################

################################################################################
# STALE-REF plumbing.
#
# For a long time this header advertised three classes and computed two:
# STALE-REF was documented and never assigned to anything, so the command could
# not emit it, and a clean run read as "checked, and none found". That is worse
# than an absent check — ops#70's only note points at a branch and an MR that
# never existed, and the tracker had no way to say so.
#
# Design note — deliberately narrow. A phantom-reference report is only useful
# if a finding means something, so:
#   • only branch-SHAPED tokens count: the namespaces this estate actually uses
#     (feat/ fix/ chore/ ci/ pubrel/ release/ hotfix/ refactor/ perf/) and the
#     ops-<N> convention. `docs/` and `test/` are excluded on purpose: they are
#     far more often file paths in prose than branch names, and a false
#     STALE-REF is noise dressed as signal.
#   • anything ending in a file extension is dropped for the same reason.
#   • "exists" is generous: a remote ref, a local ref, a tag, or a merge commit
#     on origin/main naming the branch (landed and deleted) all count. Only a
#     reference nobody can resolve at all is stale.
################################################################################

# _refs_in_text <text> → one candidate branch name per line (deduplicated)
_refs_in_text() {
  local text="${1:-}"
  printf '%s\n' "$text" \
    | grep -oE '(^|[^A-Za-z0-9._/-])(origin/)?((feat|fix|chore|ci|pubrel|release|hotfix|refactor|perf)/[A-Za-z0-9._/-]+|ops-[0-9]+[A-Za-z0-9._-]*)' 2>/dev/null \
    | sed -E 's/^[^A-Za-z0-9]+//; s|^origin/||' \
    | sed -E 's/[^A-Za-z0-9_/-]+$//' \
    | grep -vE '\.(md|sh|yml|yaml|json|php|py|bats|ini|conf|txt|png|jpg|log|patch|bundle)$' 2>/dev/null \
    | grep -vE '/$' 2>/dev/null \
    | sort -u
  return 0
}

# _ref_is_known <ref> [repo...] → 0 exists somewhere · 1 nowhere · 2 undetermined
#
# rc=2 (no repository could be inspected) is NOT "stale". Reporting a phantom
# because the checkout was missing is exactly the kind of confident wrong answer
# this command exists to remove.
_ref_is_known() {
  local ref="${1:-}"; shift || true
  [ -n "$ref" ] || return 2
  local -a repos=("$@")
  [ "${#repos[@]}" -gt 0 ] || repos=("$PROJECT_ROOT")

  local repo checked=0
  for repo in "${repos[@]}"; do
    [ -n "$repo" ] || continue
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
    checked=$((checked + 1))

    if git -C "$repo" for-each-ref --format='%(refname:short)' 'refs/remotes/' 2>/dev/null \
         | sed -E 's|^[^/]+/||' | grep -qxF "$ref"; then
      return 0
    fi
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$ref" 2>/dev/null; then return 0; fi
    if git -C "$repo" show-ref --verify --quiet "refs/tags/$ref" 2>/dev/null; then return 0; fi

    # Landed and deleted: a merge commit on origin/main still names it.
    if git -C "$repo" rev-parse --verify -q origin/main >/dev/null 2>&1; then
      if git -C "$repo" log origin/main -1 --format=%h --fixed-strings \
             --grep="Merge branch '$ref'" 2>/dev/null | grep -q .; then
        return 0
      fi
    fi
  done

  [ "$checked" -gt 0 ] || return 2
  return 1
}
cmd_reconcile(){
  [ -n "$YQ" ] || die "yq required"
  local as_json=false only_iid="" scan_notes=true a
  for a in "$@"; do
    case "$a" in
      --json) as_json=true ;;
      --no-notes) scan_notes=false ;;
      [0-9]*) only_iid="$a" ;;
      -h|--help) echo "usage: pl issue reconcile [<iid>] [--json] [--no-notes]"; return 0 ;;
    esac
  done

  # Repos whose main history can contain "ops#N": nwp/nwp plus every site repo.
  # NWP_RECONCILE_REPOS (whitespace-separated) overrides, for tests.
  local -a repos=()
  if [ -n "${NWP_RECONCILE_REPOS:-}" ]; then
    # shellcheck disable=SC2206
    repos=(${NWP_RECONCILE_REPOS})
  else
    repos=("$PROJECT_ROOT")
    if command -v discover_repos >/dev/null 2>&1; then
      local r
      while IFS= read -r r; do [ -n "$r" ] && repos+=("$r"); done < <(discover_repos 2>/dev/null)
    fi
  fi

  # PAGINATE. The previous single `per_page=100` call silently scanned a
  # TRUNCATED list and then printed "tracker and code agree" — a positive
  # assertion over data it never read. nwp/ops is already PAST the 100 cap, so
  # every issue on page 2+ was invisible to this command.
  #
  # This used to be an inline loop here; it is now `_api_rows` in
  # lib/gitlab-issues.sh, because keeping the fix local to one function is
  # precisely how `pl issue ls` and `pl issue board` kept the bug (fixed
  # 2026-08-02). Rows are flattened to TSV as they arrive: one representation,
  # no merge step that can quietly drop a page.
  local issues_tsv
  issues_tsv=$(_api_rows "/projects/$PROJECT_ID/issues?state=all&order_by=updated_at" \
    '[(.iid|tostring), .state,
      ((.title // "") | sub("\n"; " ") | sub("	"; " ")),
      ((.description // "") | sub("\n"; " ") | sub("	"; " "))] | join("	")') \
    || die "could not read the issue list (token rejected, or host unreachable)"
  [ -n "$issues_tsv" ] || die "could not read the issue list"

  # State the SCOPE. "STALE-REF" means "found in none of the repositories this
  # run could see" — which is only useful if the reader knows how many that was.
  # An unqualified phantom report is itself an over-claim.
  local n_repos=0 _r
  for _r in "${repos[@]}"; do
    git -C "$_r" rev-parse --git-dir >/dev/null 2>&1 && n_repos=$((n_repos + 1))
  done

  # ops#235: MR VISIBILITY IS PART OF THE SCOPE. Two of the three classes this
  # command reports depend on being able to SEE merge requests in the code
  # projects, and the walled ops token cannot — GitLab returns [] rather than
  # 403. Probe once (memoised in the lib) and SAY SO, because a reconcile run
  # that silently cannot see MRs prints a clean-looking report that is wrong in
  # both directions.
  local mr_blind=false mr_key_desc="code projects: $(_code_projects | tr '\n' ' ' | sed 's/ *$//')"
  _mr_read_key >/dev/null 2>&1 || mr_blind=true

  if [ "$as_json" = false ]; then
    print_header "Issue ↔ code reconciliation (project $PROJECT_ID)"
    printf '  scope: %d issue(s) · %d git repo(s) searched for cited refs%s\n' \
      "$(printf '%s' "$issues_tsv" | grep -c .)" "$n_repos" \
      "$([ "$scan_notes" = true ] && echo ' · notes included' || echo ' · notes SKIPPED (--no-notes)')"
    if [ "$mr_blind" = true ]; then
      printf '  \033[33mMR VISIBILITY: BLIND\033[0m — no token can read %s.\n' "$mr_key_desc"
      printf '  MERGED-BUT-OPEN and CLOSED-BUT-OPEN-MR are NOT REPORTED this run (ops#235).\n\n'
    else
      printf '  MR visibility: OK (%s)\n\n' "$mr_key_desc"
    fi
  else
    printf '[\n'
    if [ "$mr_blind" = true ]; then
      printf '  {"class":"MR-VISIBILITY-BLIND","detail":"%s","advice":"MERGED-BUT-OPEN / CLOSED-BUT-OPEN-MR not reported"}' \
        "$mr_key_desc"
    fi
  fi

  # The blindness row is a real element, so the comma bookkeeping must know it
  # was emitted — otherwise --json produces `[ {...} {...} ]` and no consumer parses.
  local first=true findings=0
  [ "$as_json" = true ] && [ "$mr_blind" = true ] && first=false
  local iid state title desc merged_in open_mr_n repo
  while IFS=$'\t' read -r iid state title desc; do
    [ -z "$iid" ] && continue
    [ -n "$only_iid" ] && [ "$iid" != "$only_iid" ] && continue

    # Does main history CLAIM to have completed this issue?
    #
    # Deliberately narrow: a bare "ops#N" mention is not evidence of completion
    # (issues cite each other constantly), and treating it as such would make
    # this command propose 30 wrong closes — the same noise-as-signal failure
    # the rest of this item exists to remove. Only two things count:
    #   1. a closing keyword ("Closes/Fixes/Resolves/Implements ... ops#N")
    #   2. a merge commit whose source branch was ops-<N>
    merged_in=""
    for repo in "${repos[@]}"; do
      { [ -d "$repo/.git" ] || [ -f "$repo/.git" ]; } || continue
      git -C "$repo" rev-parse --verify -q origin/main >/dev/null 2>&1 || continue
      if git -C "$repo" log origin/main -1 --format=%h \
           --extended-regexp \
           --grep="(([Cc]los|[Ff]ix|[Rr]esolv|[Ii]mplement)(e[sd]?|ing)?)[^\n]{0,40}ops#${iid}([^0-9]|\$)" \
           2>/dev/null | grep -q .; then
        merged_in="${repo#$PROJECT_ROOT/}"; [ "$merged_in" = "$repo" ] && merged_in="(nwp)"
        break
      fi
      if git -C "$repo" log origin/main -1 --format=%h \
           --extended-regexp \
           --grep="Merge branch '(ops-${iid}|ops-${iid}-[^']*)'" \
           2>/dev/null | grep -q .; then
        merged_in="${repo#$PROJECT_ROOT/}"; [ "$merged_in" = "$repo" ] && merged_in="(nwp)"
        break
      fi
    done

    # ops#235: same walled-token blindness as the close guard, and here it is
    # worse in BOTH directions. `open_mr_n` was pinned at 0, so CLOSED-BUT-OPEN-MR
    # was unreachable (false negative) AND MERGED-BUT-OPEN fired on any issue with
    # a merge in history regardless of open MRs, advising `pl issue close` on work
    # that was still in flight (false positive, acted on by a human).
    local mr_rc=0 mr_lines=""
    if [ "$mr_blind" = true ]; then
      open_mr_n=-1
    else
      mr_lines=$(issue_open_mrs "$iid") || mr_rc=$?
      case "$mr_rc" in
        0) open_mr_n=0 ;;
        1) open_mr_n=$(printf '%s\n' "$mr_lines" | grep -c . || true) ;;
        *) open_mr_n=-1 ;;   # went blind mid-run; treated as unknown below
      esac
    fi

    # STALE-REF: branch-shaped tokens in the issue text that resolve nowhere.
    # Notes are scanned too (ops#70's phantom is in a note, not the body); pass
    # --no-notes to halve the API calls when you only want the state classes.
    local text="$title $desc" ref stale_refs=""
    if [ "$scan_notes" = true ]; then
      # PAGINATED: a >100-note thread used to lose its tail, so a phantom ref
      # cited late in a long discussion could not be found and the run still
      # reported "no findings".
      local notes
      notes=$(_api_rows "/projects/$PROJECT_ID/issues/$iid/notes?sort=asc" \
                '((.body // "") | sub("\n"; " ") | sub("	"; " "))' 2>/dev/null || true)
      [ -n "$notes" ] && text="$text $(printf '%s' "$notes" | tr '\n\t' '  ')"
    fi
    local ref_rc
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      ref_rc=0; _ref_is_known "$ref" "${repos[@]}" || ref_rc=$?
      # rc=0 exists · rc=2 could not determine — only rc=1 is a phantom.
      [ "$ref_rc" -eq 1 ] || continue
      stale_refs="${stale_refs:+$stale_refs }$ref"
    done < <(_refs_in_text "$text")

    local class="" advice=""
    # open_mr_n = -1 means UNKNOWN. Neither MR-dependent class may be asserted
    # from an unknown, in either direction — that is the ops#235 lesson applied
    # to the reporting half. The run-level banner above already says we are blind.
    if [ "$open_mr_n" -lt 0 ]; then
      :
    elif [ "$state" = "opened" ] && [ -n "$merged_in" ] && [ "$open_mr_n" = "0" ]; then
      class="MERGED-BUT-OPEN"; advice="pl issue close $iid"
    elif [ "$state" = "closed" ] && [ "$open_mr_n" -gt 0 ]; then
      class="CLOSED-BUT-OPEN-MR"; advice="pl issue reopen $iid"
    fi

    if [ -n "$stale_refs" ]; then
      findings=$((findings + 1))
      if [ "$as_json" = true ]; then
        [ "$first" = true ] && first=false || printf ',\n'
        printf '  {"iid":%s,"state":"%s","class":"STALE-REF","stale_refs":"%s","repos_searched":%s,"advice":"%s"}' \
          "$iid" "$state" "$stale_refs" "$n_repos" "correct or delete the reference"
      else
        printf '  %-20s #%-5s %-58s → %s\n' "STALE-REF" "$iid" "${title:0:58}" \
          "cites (found in none of $n_repos repo(s)): $stale_refs"
      fi
    fi

    [ -z "$class" ] && continue

    findings=$((findings + 1))
    if [ "$as_json" = true ]; then
      [ "$first" = true ] && first=false || printf ',\n'
      printf '  {"iid":%s,"state":"%s","class":"%s","merged_in":"%s","open_mrs":%s,"advice":"%s"}' \
        "$iid" "$state" "$class" "$merged_in" "$open_mr_n" "$advice"
    else
      printf '  %-20s #%-5s %-58s → %s\n' "$class" "$iid" "${title:0:58}" "$advice"
    fi
  # `printf '%s\n'`, NOT `printf '%s'`. `issues_tsv=$(_api_rows …)` strips the
  # trailing newline (command substitution always does), so the final row
  # arrives UNTERMINATED and `while read` skips it — the tracker's last issue
  # was never classified. Caught 2026-08-03 by the ops#235 reconcile test, which
  # has exactly one issue in its fixture and so lost 100% of its input. A
  # de-truncation change that reintroduces an off-by-one at the other end is
  # still a truncation.
  done < <(printf '%s\n' "$issues_tsv")

  if [ "$as_json" = true ]; then
    printf '\n]\n'
    return 0
  fi
  echo ""
  if [ "$findings" -gt 0 ]; then
    print_warning "$findings issue(s) disagree with what landed — nothing was changed; act with the commands above"
  elif [ "$mr_blind" = true ]; then
    # ops#235 again, at the summary line. "tracker and code agree" is a POSITIVE
    # assertion, and two of the three classes behind it were not evaluated. A
    # clean-looking summary over unread data is the whole failure this issue is
    # about; do not print one. rc 3 = could not look, per pl server health.
    print_warning "PARTIAL: no findings in the classes this run could evaluate — MR-dependent classes were NOT checked (blind)"
    return 3
  else
    print_success "tracker and code agree (no merged-but-open or closed-with-open-MR issues)"
  fi
}

# add/remove labels:  pl issue label <ref> --add a,b --remove c
cmd_label(){
  [ -n "$YQ" ] || die "yq required"
  case "${1:-}" in -h|--help) printf 'usage: pl issue label <ref> --add a,b [--remove c]\n'; return 0 ;; esac
  local ref="${1:-}"; [ -n "$ref" ] || die "usage: pl issue label <ref> --add a,b [--remove c]"
  _use_ref "$ref"; local iid="$REF_IID"
  [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl issue label <ref> --add a,b [--remove c]"
  shift
  local add="" rem=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --add|-a)    add="${2:-}";  shift 2 ;;
      --add=*)     add="${1#*=}"; shift ;;
      --remove|-r) rem="${2:-}";  shift 2 ;;
      --remove=*)  rem="${1#*=}"; shift ;;
      # a flag-like arg is never a label name — same class as the
      # `pl issue create --help` bug (fixed in MR !282): `pl issue label 5
      # --typo` must refuse, not PUT the label "--typo"
      -*) die "unknown option: $1 (usage: pl issue label <ref> --add a,b [--remove c])" ;;
      *) [ -z "$add" ] && { add="$1"; shift; } || die "unexpected arg: $1" ;;
    esac
  done
  [ -n "$add$rem" ] || die "nothing to do: pass --add and/or --remove"
  # empty add_labels / remove_labels are harmless no-ops to the GitLab API
  local payload; payload=$(A="$add" R="$rem" "$YQ" -n -o=json \
    '{"add_labels": strenv(A), "remove_labels": strenv(R)}')
  local resp; resp=$(_api_send PUT "/projects/$PROJECT_ID/issues/$iid" "$payload")
  local labels; labels=$(_require_ok "$resp" id "label #$iid" >/dev/null; printf '%s' "$resp" | "$YQ" e -p=json '.labels | join(", ")' - 2>/dev/null)
  print_success "${SRC_SLUG:-project $PROJECT_ID}#$iid labels: ${labels:-—}"
  # Adding the gate label by hand must tell the same truth `approve` does.
  case ",${add}," in *,agent-eligible,*) _warn_if_loop_paused || true ;; esac
}

# submit — fold a worktree branch back: commit (tracked changes only), push over SSH,
# and emit a pre-filled "open MR" URL (target main, Closes nwp/ops#N). NO api token is
# needed on the code repo — push is SSH, the MR is opened by you in the browser, and the
# MERGE stays your call (operating model §6). Self-guards: only acts inside an ops-<N> worktree.
cmd_submit(){
  command -v git >/dev/null || die "git required"
  local dryrun=0 iid="" msg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)    printf 'usage: pl issue submit [<iid>] [-m "msg"] [--dry-run]\n'; return 0 ;;
      --dry-run|-n) dryrun=1; shift ;;
      -m|--message) msg="${2:-}"; shift 2 ;;
      -*) die "unknown option: $1 (usage: pl issue submit [<iid>] [-m \"msg\"] [--dry-run])" ;;
      *) [ -z "$iid" ] && { iid="$1"; shift; } || die "unexpected arg: $1" ;;
    esac
  done
  local branch; branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || die "not a git repo"
  if [ -z "$iid" ]; then
    [[ "$branch" =~ ^ops-([0-9]+)$ ]] || die "not on an ops-<N> branch (on '$branch') — run inside a 'pl issue work <N>' worktree, or pass the number"
    iid="${BASH_REMATCH[1]}"
  fi
  [ "$branch" = "ops-$iid" ] || die "branch '$branch' != ops-$iid — refusing to submit the wrong branch"
  local root host repo
  root=$(git rev-parse --show-toplevel); host=$(_host)
  repo=$(git remote get-url origin 2>/dev/null | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')
  [ -n "$repo" ] || die "no 'origin' remote — can't build the MR URL"

  # 1. commit tracked changes — NEVER `git add -A` (the linked tools/state are untracked
  #    symlinks; -u stages only already-tracked files, so they can't be committed).
  if ! git diff --quiet || ! git diff --cached --quiet; then
    if [ -z "$msg" ]; then
      msg="ops#$iid: $(_api_get "/projects/$PROJECT_ID/issues/$iid" 2>/dev/null | _jget title | head -c 60)"
      [ "$msg" = "ops#$iid: " ] && msg="ops#$iid: work"
    fi
    if [ "$dryrun" = 1 ]; then print_info "[dry-run] would: git add -u && git commit -m \"$msg\""
    else git add -u && git commit -m "$msg" || die "commit failed (gitleaks gate?)"; print_success "committed tracked changes: $msg"; fi
  else
    print_info "working tree clean (tracked) — nothing new to commit"
  fi
  # warn about untracked NON-symlink files (real new files you may need to add by hand)
  local u; u=$(git status --porcelain | sed -n 's/^?? //p' | while read -r p; do [ -L "$p" ] || printf '%s\n' "$p"; done)
  [ -n "$u" ] && { print_warning "untracked files NOT included — add by hand if needed:"; printf '    %s\n' $u; }

  # 2. push the branch (SSH — no token)
  if [ "$dryrun" = 1 ]; then print_info "[dry-run] would: git push -u origin $branch"
  else git push -u origin "$branch" || die "git push failed"; print_success "pushed $branch → origin"; fi

  # 3. pre-filled new-MR URL: target main, Closes nwp/ops#N on merge (merge = your call)
  local mr="https://$host/$repo/-/merge_requests/new?merge_request%5Bsource_branch%5D=$branch&merge_request%5Btarget_branch%5D=main&merge_request%5Bdescription%5D=Closes%20nwp%2Fops%23$iid"
  echo
  print_success "open the merge request (review + merge = your call):"
  printf '    %s\n' "$mr"
  print_hint "after it merges (auto-closes nwp/ops#$iid):  git worktree remove \"$root\" && git branch -d $branch"
}

# Link entries of a shared singleton dir that git did NOT check out into the
# worktree (ops#307). Bounded depth; never touches anything that exists (a
# tracked file from the branch always wins); skips .git. Depth 3 covers the
# real shapes: private/pairs/<file> and sites/<site>/<env>.
_wt_link_missing(){
  local src="$1" dst="$2" depth="$3" e name
  [ "$depth" -le 0 ] && return 0
  for e in "$src"/* "$src"/.[!.]*; do
    [ -e "$e" ] || continue
    name="$(basename "$e")"
    [ "$name" = ".git" ] && continue
    if [ ! -e "$dst/$name" ]; then
      ln -s "$e" "$dst/$name" 2>/dev/null || true
    elif [ -d "$e" ] && [ -d "$dst/$name" ] && [ ! -L "$dst/$name" ]; then
      _wt_link_missing "$e" "$dst/$name" $((depth-1))
    fi
  done
  return 0
}

cmd_work(){
  command -v git >/dev/null || die "git required"
  local n="" base="" launch=1
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) printf 'usage: pl issue work <issue-number> [base-ref] [--no-launch]\n'; return 0 ;;
      -n|--no-launch|--print) launch=0; shift ;;
      -*) die "unknown option: $1 (usage: pl issue work <issue-number> [base-ref] [--no-launch])" ;;
      *) if [ -z "$n" ]; then n="$1"; elif [ -z "$base" ]; then base="$1"; fi; shift ;;
    esac
  done
  [[ "$n" =~ ^[0-9]+$ ]] || die "usage: pl issue work <issue-number> [base-ref] [--no-launch]"
  if [ -z "$base" ]; then
    if git -C "$PROJECT_ROOT" show-ref --verify --quiet refs/heads/main; then base="main"
    else base="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)"; fi
  fi
  local wt="$HOME/nwp-ops$n" branch="ops-$n"
  if [ -d "$wt" ]; then
    print_info "worktree already exists: $wt (branch $(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null))"
  elif git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$PROJECT_ROOT" worktree add "$wt" "$branch" || die "git worktree add failed"
    print_success "opened worktree $wt on existing branch $branch"
  else
    git -C "$PROJECT_ROOT" worktree add -b "$branch" "$wt" "$base" || die "git worktree add failed"
    print_success "created worktree $wt on new branch $branch (from $base)"
  fi
  # A fresh worktree only checks out TRACKED files — link the untracked LOCAL tools in
  # so `pl secrets` / `pl issue` are fully featured inside it too.
  local f
  for f in secrets.sh issue.sh; do
    if [ -f "$PROJECT_ROOT/scripts/commands/$f" ] && [ ! -e "$wt/scripts/commands/$f" ]; then
      ln -s "$PROJECT_ROOT/scripts/commands/$f" "$wt/scripts/commands/$f" \
        && print_info "linked local tool → scripts/commands/$f"
    fi
  done
  # The worktree also lacks the gitignored SINGLETON state (secrets, the live fleet,
  # local config). Link those so the ONE fleet/secret store is SHARED (not duplicated)
  # and `pl` actually works inside the worktree. Different windows isolate their CODE
  # edits; the fleet itself stays a single shared resource.
  #
  # ops#307: private/ and sites/ are PARTIALLY TRACKED, so a whole-dir link only
  # when absent left every worktree with a real skeleton dir SHADOWING the shared
  # state — the pair guard then read a BLANK ledger and refused a deploy the real
  # ledger permitted (observed 2026-08-07, ops#279). So: link the whole thing when
  # absent, and when git checked out a partial dir, descend and link the MISSING
  # children instead. Tracked files came from the branch and are never touched.
  #
  # ops#331: `servers` belongs in this list for exactly the same reason and was
  # missing. It is partially tracked (nginx/, system/, backup/… are versioned;
  # `servers/*/.nwp-server.yml` is gitignored), so a worktree got the tracked
  # skeleton and NO identity file — and every server verb then failed inside a
  # worktree. Observed 2026-08-10 while building `pl forge`:
  #     $ pl server health <forge>        # run inside a worktree
  #     UNKNOWN: health probe failed (rc=255) — treating as UNREACHABLE
  # …against a box that was HEALTHY from the main checkout one second earlier.
  # That is the ops#279 shadowing bug wearing a different hat, and it fails in
  # the *safe* direction only by luck: an unreachable box is refused, but a verb
  # that reads a server list would have read an EMPTY fleet and said so
  # confidently. `_wt_link_missing` skips `.git`, so the nested
  # `servers/nwpcode/.git` repo is left alone.
  local s
  for s in .secrets.yml nwp.yml private sites servers; do
    [ -e "$PROJECT_ROOT/$s" ] || continue
    if [ ! -e "$wt/$s" ]; then
      ln -s "$PROJECT_ROOT/$s" "$wt/$s" && print_info "linked shared state → $s"
    elif [ -d "$PROJECT_ROOT/$s" ] && [ ! -L "$wt/$s" ]; then
      _wt_link_missing "$PROJECT_ROOT/$s" "$wt/$s" 3 \
        && print_info "linked missing shared state under → $s/"
    fi
  done
  echo
  local launch_cmd="${NWP_CLAUDE_CMD:-claude}" first="work on nwp/ops#$n"
  print_hint "list worktrees: git worktree list   ·   when merged: git worktree remove \"$wt\""
  if [ "$launch" = "1" ] && command -v "${launch_cmd%% *}" >/dev/null 2>&1; then
    print_success "launching Claude in $wt  →  \"$first\""
    cd "$wt" || die "cd into worktree failed"
    exec $launch_cmd "$first"     # replaces this process; on exit you return to your shell
  fi
  [ "$launch" = "1" ] && print_warning "launcher '${launch_cmd%% *}' not found — open it yourself:"
  print_hint "open it:  cd \"$wt\" && ${launch_cmd} \"$first\""
}

main(){
  local sub="${1:-ls}"; shift || true
  # A --project= flag may precede the ref on the ref-taking subcommands.
  local -a rest=(); local a
  for a in "$@"; do
    case "$a" in --project=*) SRC_SPEC="${a#*=}" ;; *) rest+=("$a") ;; esac
  done
  case "$sub" in
    ls|list|board) : ;;                       # these parse --project themselves
    *) set -- ${rest[@]+"${rest[@]}"} ;;
  esac
  case "$sub" in
    ls|list)    cmd_ls "$@" ;;
    approve|ok) cmd_approve "$@" ;;
    board)      cmd_board "$@" ;;
    show|view)  cmd_show "$@" ;;
    url)        cmd_url "$@" ;;
    create|new) cmd_create "$@" ;;
    comment|note) cmd_comment "$@" ;;
    close)      cmd_close "$@" ;;
    reopen)     cmd_reopen "$@" ;;
    label)      cmd_label "$@" ;;
    work|start) cmd_work "$@" ;;
    reconcile)  cmd_reconcile "$@" ;;
    submit|fold|mr) cmd_submit "$@" ;;
    -h|--help|help)
      cat <<EOF
pl issue — the work board (read + write) + per-issue worktrees

  TWO TRACKERS, ONE QUEUE. \`ls\` reads both by default, because the agent-loop
  already polls both (AGENT_LOOP_PROJECT_IDS="16,21"):
    ops = nwp/ops (project $OPS_PROJECT_ID)  — ops work board
    nwc = nwp/nwc (project $NWC_PROJECT_ID)  — tester feedback synced from nwd
  A <ref> is a bare number (= ops) or qualified: ops#179 · nwc#8

  Read:
    pl issue ls [--all] [--pending|--approved|--needs-human]
                [--project=ops|nwc|all|<id>] [--limit=N]
                                   list issues — fully PAGINATED, with the
                                   approval GATE per row and an honest count
    pl issue ls --pending          everything awaiting YOUR approval decision
    pl issue show <ref>            show one issue: fields, description, comments
    pl issue url <ref>             print the web URL for an issue

  Approval gate:
    pl issue approve <ref>         add 'agent-eligible' so the loop may work it.
                                   REFUSES if the issue is 'needs-human', and
                                   says plainly when the loop is paused (in which
                                   case the label is recorded but not acted on).

  Write (nwp/ops uses the least-privilege gitlab.ops_note_token; nwp/nwc needs
  the group bot gitlab.api_token — the ops token cannot see that project):
    pl issue create --title "..." [--desc "..."] [--label a,b]
                                   open a new nwp/ops issue
    pl issue comment <ref> "text"  add a comment (or pipe text on stdin)
    pl issue close <ref>           close an issue. Exit 1 = an MR referencing it
                                   is still OPEN. Exit 3 = CANNOT VERIFY (no
                                   token can read the code projects) — refused,
                                   because an empty related-MR list from a walled
                                   token is blindness, not evidence (ops#235).
                                   --force overrides both.
    pl issue reconcile [<iid>] [--no-notes] [--json]
                                   report issues that disagree with what landed:
                                   MERGED-BUT-OPEN · CLOSED-BUT-OPEN-MR · STALE-REF
                                   (cites a branch found in none of the repos
                                   searched). Paginates the whole tracker.
                                   Read-only. --no-notes skips the per-issue note
                                   fetch (roughly twice as fast, misses refs that
                                   only appear in comments). Exit 3 = MR
                                   visibility BLIND: the two MR-dependent classes
                                   were not evaluated and no clean bill of health
                                   is printed.
    pl issue reopen <iid>          reopen an issue
    pl issue label <iid> --add a,b [--remove c]
                                   add and/or remove labels

  Worktree:
    pl issue work <iid> [--no-launch]
                                   create/open isolated worktree ~/nwp-ops<iid> (branch
                                   ops-<iid>, tools+fleet linked) and launch Claude in it on
                                   "work on nwp/ops#<iid>". --no-launch just creates it.
                                   Launcher = \$NWP_CLAUDE_CMD (default: claude).
EOF
      ;;
    *) die "unknown subcommand: $sub (try: pl issue ls)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Installed only when EXECUTED, never when sourced — a sourced lib must not
  # hijack its host's EXIT trap.
  trap _tmpdir_cleanup EXIT
  main "$@"
fi
