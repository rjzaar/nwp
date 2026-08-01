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
#   pl issue ls [--all]      list open (or all) nwp/ops issues — # title labels
#   pl issue show <iid>      show one issue: fields, description, comment thread
#   pl issue url <iid>       print the web URL for one issue
#   pl issue create ...      open a new issue (--title/--desc/--label)
#   pl issue comment <iid>   add a comment   ·  close/reopen/label <iid>
#   pl issue work <iid>      create/open isolated worktree ~/nwp-ops<iid> (branch
#                            ops-<iid>, tools+fleet linked) and LAUNCH Claude in it with
#                            the first prompt. --no-launch just creates it. Override the
#                            launcher via NWP_CLAUDE_CMD (e.g. set it to your `co`).
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null || true

SECRETS_FILE="${NWP_SECRETS_FILE:-$PROJECT_ROOT/.secrets.yml}"
PROJECT_ID="${NWP_OPS_PROJECT_ID:-21}"          # nwp/ops
YQ="$(command -v yq || true)"

die(){ print_error "$*"; exit 1; }

# Shared GitLab issue API plumbing (_host/_token/_api_get/_api_send/_jget/
# _require_ok). Extracted to a lib so `pl rag --sync-issues` reuses it (ops#6).
source "$PROJECT_ROOT/lib/gitlab-issues.sh"

cmd_ls(){
  [ -n "$YQ" ] || die "yq required"
  local state="opened"; [ "${1:-}" = "--all" ] && state="all"
  print_header "nwp/ops issues (project $PROJECT_ID) — state: $state"
  local json; json=$(_api_get "/projects/$PROJECT_ID/issues?state=$state&per_page=100&order_by=created_at&sort=asc")
  [ -n "$json" ] || die "no response from GitLab (token rejected, or host unreachable)"
  # GitLab returns [] for an empty project; surface that clearly.
  if [ "$("$YQ" e -p=json 'length' <<<"$json" 2>/dev/null)" = "0" ]; then
    print_warning "no $state issues found in nwp/ops — seed the work board first"; return 0
  fi
  printf "  %-5s %-9s %-46s %s\n" "#" "STATE" "TITLE" "LABELS"
  printf "  %-5s %-9s %-46s %s\n" "-----" "---------" "----------------------------------------------" "------"
  "$YQ" e -p=json -o=tsv '.[] | [.iid, .state, .title, (.labels | join(","))]' <<<"$json" 2>/dev/null \
  | while IFS=$'\t' read -r iid st title labels; do
      printf "  ${BOLD}%-5s${NC} %-9s %-46.46s %s\n" "$iid" "$st" "$title" "$labels"
    done
  echo
  print_hint "open one in its OWN window:  start a fresh Claude in ~/nwp and say  \"work on nwp/ops#<#>\""
}


# pl issue board — one screen: every open op grouped by kind (P67 §5e).
# WORK ITEMS (human/agent work) vs RAG-AUTO (fleet-health auto-issues) vs
# recently closed. Same token/plumbing as ls; no MR join (the ops token is
# least-privilege and cannot read code repos — deliberate).
cmd_board(){
  [ -n "$YQ" ] || die "yq required"
  local json closed
  json=$(_api_get "/projects/$PROJECT_ID/issues?state=opened&per_page=100&order_by=created_at&sort=asc")
  [ -n "$json" ] || die "no response from GitLab (token rejected, or host unreachable)"
  closed=$(_api_get "/projects/$PROJECT_ID/issues?state=closed&per_page=10&order_by=updated_at&sort=desc")

  print_header "nwp/ops board"

  echo -e "${BOLD}WORK ITEMS (open):${NC}"
  printf "  %-5s %-52s %-10s %s
" "#" "TITLE" "PRIORITY" "FLAGS"
  "$YQ" e -p=json -o=tsv \
      '.[] | select((.labels | contains(["rag-auto"])) | not) | [.iid, .title, (.labels | join(","))]' \
      <<<"$json" 2>/dev/null \
  | while IFS=$'\t' read -r iid title labels; do
      local prio="-" flags=""
      case ",$labels," in *,priority::high,*) prio="high" ;; *,priority::medium,*) prio="medium" ;; *,priority::low,*) prio="low" ;; esac
      case ",$labels," in *,agent-eligible,*) flags="agent-eligible" ;; esac
      printf "  ${BOLD}%-5s${NC} %-52.52s %-10s %s
" "$iid" "$title" "$prio" "$flags"
    done

  echo ""
  echo -e "${BOLD}RAG-AUTO (fleet health, auto-managed — clears when the site goes green):${NC}"
  "$YQ" e -p=json -o=tsv \
      '.[] | select(.labels | contains(["rag-auto"])) | [.iid, .title, (.labels | join(","))]' \
      <<<"$json" 2>/dev/null \
  | while IFS=$'\t' read -r iid title labels; do
      local sev="🟠"
      case ",$labels," in *,security,*) sev="🔴" ;; esac
      printf "  %s #%-4s %-52.52s
" "$sev" "$iid" "$title"
    done

  if [ -n "$closed" ] && [ "$("$YQ" e -p=json 'length' <<<"$closed" 2>/dev/null)" != "0" ]; then
    echo ""
    echo -e "${BOLD}RECENTLY CLOSED:${NC}"
    "$YQ" e -p=json -o=tsv '.[] | [.iid, .title, .closed_at]' <<<"$closed" 2>/dev/null \
    | while IFS=$'\t' read -r iid title closed_at; do
        printf "  ${DIM:-}✓ #%-4s %-52.52s %s${NC}
" "$iid" "$title" "${closed_at:0:10}"
      done
  fi
  echo ""
  print_hint "detail: pl issue show <#>   ·   fleet state: pl rag   ·   work queue: pl todo"
}

cmd_url(){
  local iid="${1:-}"; [ -n "$iid" ] || die "usage: pl issue url <iid>"
  printf 'https://%s/nwp/ops/-/issues/%s\n' "$(_host)" "$iid"
}

# show one issue: header fields + description + the discussion thread (notes)
cmd_show(){
  [ -n "$YQ" ] || die "yq required"
  local iid="${1:-}"; [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl issue show <iid>"
  local json; json=$(_api_get "/projects/$PROJECT_ID/issues/$iid")
  [ -n "$json" ] || die "no response from GitLab (token rejected, or host unreachable)"
  local title state author labels created updated desc
  title=$(printf '%s' "$json" | _jget title)
  [ -n "$title" ] || die "issue #$iid not found in nwp/ops"
  state=$(printf '%s'  "$json" | _jget state)
  author=$(printf '%s' "$json" | _jget 'author.username')
  labels=$(printf '%s' "$json" | "$YQ" e -p=json '.labels | join(", ")' - 2>/dev/null)
  created=$(printf '%s' "$json" | _jget created_at)
  updated=$(printf '%s' "$json" | _jget updated_at)
  desc=$(printf '%s'   "$json" | "$YQ" e -p=json '.description // ""' - 2>/dev/null)
  print_header "nwp/ops#$iid — $title"
  printf "  ${BOLD}%-9s${NC} %s\n" "state:"   "$state"
  printf "  ${BOLD}%-9s${NC} %s\n" "author:"  "${author:-?}"
  printf "  ${BOLD}%-9s${NC} %s\n" "labels:"  "${labels:-—}"
  printf "  ${BOLD}%-9s${NC} %s\n" "created:" "$created"
  printf "  ${BOLD}%-9s${NC} %s\n" "updated:" "$updated"
  printf "  ${BOLD}%-9s${NC} %s\n" "url:"     "$(cmd_url "$iid")"
  echo; echo "$desc"; echo
  # discussion thread (skip GitLab system notes)
  local notes; notes=$(_api_get "/projects/$PROJECT_ID/issues/$iid/notes?sort=asc&per_page=100")
  local n; n=$(printf '%s' "$notes" | "$YQ" e -p=json '[.[] | select(.system == false)] | length' - 2>/dev/null)
  if [ -n "$n" ] && [ "$n" != "0" ]; then
    print_header "Comments ($n)"
    printf '%s' "$notes" | "$YQ" e -p=json -o=tsv '.[] | select(.system == false) | [.author.username, .created_at, .body]' - 2>/dev/null \
    | while IFS=$'\t' read -r who when bd; do
        printf "  ${BOLD}%s${NC} ${DIM}%s${NC}\n    %s\n\n" "$who" "$when" "$bd"
      done
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
  # empty description / labels are harmless no-ops to the GitLab API
  local payload; payload=$(T="$title" D="$desc" L="$labels" "$YQ" -n -o=json \
    '{"title": strenv(T), "description": strenv(D), "labels": strenv(L)}')
  local resp iid; resp=$(_api_send POST "/projects/$PROJECT_ID/issues" "$payload")
  iid=$(_require_ok "$resp" iid "create issue")
  print_success "created nwp/ops#$iid — $title"
  print_info "$(cmd_url "$iid")"
}

# add a comment:  pl issue comment <iid> "text"   (or pipe text on stdin)
cmd_comment(){
  [ -n "$YQ" ] || die "yq required"
  case "${1:-}" in -h|--help) printf 'usage: pl issue comment <iid> "text"   (or pipe text on stdin)\n'; return 0 ;; esac
  local iid="${1:-}"; [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl issue comment <iid> \"text\""
  shift
  local body="$*"
  [ -z "$body" ] && [ ! -t 0 ] && body="$(cat)"
  [ -n "$body" ] || die "comment body required (argument or stdin)"
  local payload; payload=$(B="$body" "$YQ" -n -o=json '{"body": strenv(B)}')
  local resp; resp=$(_api_send POST "/projects/$PROJECT_ID/issues/$iid/notes" "$payload")
  _require_ok "$resp" id "comment on #$iid" >/dev/null
  print_success "commented on nwp/ops#$iid"
}

# close / reopen
_set_state(){ # $1=iid $2=close|reopen
  [ -n "$YQ" ] || die "yq required"
  local iid="$1" ev="$2"
  [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl issue $ev <iid>"
  local payload; payload=$(E="$ev" "$YQ" -n -o=json '{"state_event": strenv(E)}')
  local resp st; resp=$(_api_send PUT "/projects/$PROJECT_ID/issues/$iid" "$payload")
  st=$(_require_ok "$resp" state "$ev #$iid")
  print_success "nwp/ops#$iid is now: $st"
}
cmd_close(){
  local iid="${1:-}" force=0 a
  for a in "$@"; do [ "$a" = "--force" ] && force=1; done
  # Close guard: an issue with an OPEN merge request against it is not done.
  # Closing it makes the tracker assert completion while the code is unlanded —
  # the exact shape that produced "ops#133 closed 2026-07-25 with Phase 2
  # unlanded" and "ops#98 closed while its implementing commit never merged".
  if [ "$force" = "0" ] && [[ "$iid" =~ ^[0-9]+$ ]]; then
    local open_mrs
    open_mrs=$(_api_get "/projects/$PROJECT_ID/issues/$iid/related_merge_requests" 2>/dev/null || echo '[]')
    local n
    n=$(printf '%s' "$open_mrs" | "$YQ" e -p=json '[.[] | select(.state == "opened")] | length' - 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if [ "$n" -gt 0 ]; then
      print_error "refusing to close nwp/ops#$iid: $n open merge request(s) still reference it"
      printf '%s' "$open_mrs" | "$YQ" e -p=json '.[] | select(.state == "opened") | "  !" + (.iid|tostring) + "  " + .title' - 2>/dev/null || true
      print_hint "land the MR first, or: pl issue close $iid --force"
      exit 1
    fi
  fi
  _set_state "$iid" close
}
cmd_reopen(){ _set_state "${1:-}" reopen; }

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
  # assertion over data it never read. nwp/ops is already AT the 100 cap, so
  # every issue past the first page was invisible to this command.
  #
  # The rows are flattened to TSV as they arrive rather than concatenating JSON:
  # one representation, no merge step that can quietly drop a page.
  local issues_tsv="" page=0 batch rows
  while :; do
    page=$((page + 1))
    batch=$(_api_get "/projects/$PROJECT_ID/issues?state=all&per_page=100&page=$page&order_by=updated_at")
    [ -n "$batch" ] || break
    rows=$(printf '%s' "$batch" | "$YQ" e -p=json -r \
             '.[] | [(.iid|tostring), .state, .title,
                     ((.description // "") | sub("\n"; " ") | sub("\t"; " "))] | @tsv' - 2>/dev/null || true)
    [ -n "$rows" ] || break
    issues_tsv="${issues_tsv}${rows}"$'\n'
    [ "$(printf '%s\n' "$rows" | grep -c .)" -lt 100 ] && break
    [ "$page" -ge 20 ] && break   # 2000 issues is not a tracker, it is a landfill
  done
  [ -n "$issues_tsv" ] || die "could not read the issue list"

  # State the SCOPE. "STALE-REF" means "found in none of the repositories this
  # run could see" — which is only useful if the reader knows how many that was.
  # An unqualified phantom report is itself an over-claim.
  local n_repos=0 _r
  for _r in "${repos[@]}"; do
    git -C "$_r" rev-parse --git-dir >/dev/null 2>&1 && n_repos=$((n_repos + 1))
  done

  if [ "$as_json" = false ]; then
    print_header "Issue ↔ code reconciliation (project $PROJECT_ID)"
    printf '  scope: %d issue(s) · %d git repo(s) searched for cited refs%s\n\n' \
      "$(printf '%s' "$issues_tsv" | grep -c .)" "$n_repos" \
      "$([ "$scan_notes" = true ] && echo ' · notes included' || echo ' · notes SKIPPED (--no-notes)')"
  else
    printf '[\n'
  fi

  local first=true findings=0
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

    open_mr_n=$(_api_get "/projects/$PROJECT_ID/issues/$iid/related_merge_requests" 2>/dev/null \
                | "$YQ" e -p=json '[.[] | select(.state == "opened")] | length' - 2>/dev/null || echo 0)
    [[ "$open_mr_n" =~ ^[0-9]+$ ]] || open_mr_n=0

    # STALE-REF: branch-shaped tokens in the issue text that resolve nowhere.
    # Notes are scanned too (ops#70's phantom is in a note, not the body); pass
    # --no-notes to halve the API calls when you only want the state classes.
    local text="$title $desc" ref stale_refs=""
    if [ "$scan_notes" = true ]; then
      local notes
      notes=$(_api_get "/projects/$PROJECT_ID/issues/$iid/notes?per_page=100" 2>/dev/null || true)
      if [ -n "$notes" ]; then
        text="$text $("$YQ" e -p=json -r '[.[] | .body] | join(" ")' - <<<"$notes" 2>/dev/null | tr '\n\t' '  ' || true)"
      fi
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
    if [ "$state" = "opened" ] && [ -n "$merged_in" ] && [ "$open_mr_n" = "0" ]; then
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
  done < <(printf '%s' "$issues_tsv")

  if [ "$as_json" = true ]; then
    printf '\n]\n'
    return 0
  fi
  echo ""
  if [ "$findings" -eq 0 ]; then
    print_success "tracker and code agree (no merged-but-open or closed-with-open-MR issues)"
  else
    print_warning "$findings issue(s) disagree with what landed — nothing was changed; act with the commands above"
  fi
}

# add/remove labels:  pl issue label <iid> --add a,b --remove c
cmd_label(){
  [ -n "$YQ" ] || die "yq required"
  case "${1:-}" in -h|--help) printf 'usage: pl issue label <iid> --add a,b [--remove c]\n'; return 0 ;; esac
  local iid="${1:-}"; [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl issue label <iid> --add a,b [--remove c]"
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
      -*) die "unknown option: $1 (usage: pl issue label <iid> --add a,b [--remove c])" ;;
      *) [ -z "$add" ] && { add="$1"; shift; } || die "unexpected arg: $1" ;;
    esac
  done
  [ -n "$add$rem" ] || die "nothing to do: pass --add and/or --remove"
  # empty add_labels / remove_labels are harmless no-ops to the GitLab API
  local payload; payload=$(A="$add" R="$rem" "$YQ" -n -o=json \
    '{"add_labels": strenv(A), "remove_labels": strenv(R)}')
  local resp; resp=$(_api_send PUT "/projects/$PROJECT_ID/issues/$iid" "$payload")
  local labels; labels=$(_require_ok "$resp" id "label #$iid" >/dev/null; printf '%s' "$resp" | "$YQ" e -p=json '.labels | join(", ")' - 2>/dev/null)
  print_success "nwp/ops#$iid labels: ${labels:-—}"
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
  local s
  for s in .secrets.yml nwp.yml private sites; do
    if [ -e "$PROJECT_ROOT/$s" ] && [ ! -e "$wt/$s" ]; then
      ln -s "$PROJECT_ROOT/$s" "$wt/$s" && print_info "linked shared state → $s"
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
  case "$sub" in
    ls|list)    cmd_ls "$@" ;;
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
pl issue — the nwp/ops work board (read + write) + per-issue worktrees

  Read:
    pl issue ls [--all]            list open (or all) nwp/ops issues
    pl issue show <iid>            show one issue: fields, description, comments
    pl issue url <iid>             print the web URL for an issue

  Write (uses the least-privilege gitlab.ops_note_token):
    pl issue create --title "..." [--desc "..."] [--label a,b]
                                   open a new nwp/ops issue
    pl issue comment <iid> "text"  add a comment (or pipe text on stdin)
    pl issue close <iid>           close an issue (refuses while an MR referencing
                                   it is still open; --force overrides)
    pl issue reconcile [<iid>] [--no-notes] [--json]
                                   report issues that disagree with what landed:
                                   MERGED-BUT-OPEN · CLOSED-BUT-OPEN-MR · STALE-REF
                                   (cites a branch found in none of the repos
                                   searched). Paginates the whole tracker.
                                   Read-only. --no-notes skips the per-issue note
                                   fetch (roughly twice as fast, misses refs that
                                   only appear in comments).
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
  main "$@"
fi
