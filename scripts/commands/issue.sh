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
cmd_close(){  _set_state "${1:-}" close;  }
cmd_reopen(){ _set_state "${1:-}" reopen; }

# add/remove labels:  pl issue label <iid> --add a,b --remove c
cmd_label(){
  [ -n "$YQ" ] || die "yq required"
  local iid="${1:-}"; [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl issue label <iid> --add a,b [--remove c]"
  shift
  local add="" rem=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --add|-a)    add="${2:-}";  shift 2 ;;
      --add=*)     add="${1#*=}"; shift ;;
      --remove|-r) rem="${2:-}";  shift 2 ;;
      --remove=*)  rem="${1#*=}"; shift ;;
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
      --dry-run|-n) dryrun=1; shift ;;
      -m|--message) msg="${2:-}"; shift 2 ;;
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
      -n|--no-launch|--print) launch=0; shift ;;
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
    show|view)  cmd_show "$@" ;;
    url)        cmd_url "$@" ;;
    create|new) cmd_create "$@" ;;
    comment|note) cmd_comment "$@" ;;
    close)      cmd_close "$@" ;;
    reopen)     cmd_reopen "$@" ;;
    label)      cmd_label "$@" ;;
    work|start) cmd_work "$@" ;;
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
    pl issue close <iid>           close an issue
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
