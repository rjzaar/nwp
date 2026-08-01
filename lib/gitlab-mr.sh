#!/bin/bash
################################################################################
# lib/gitlab-mr.sh — GitLab *merge request* API plumbing + the HOLD primitives.
#
# WHY THIS FILE EXISTS
#   On 2026-08-01 an MR that had been explicitly decided-against was merged
#   anyway. A background merge sweeper armed `merge_when_pipeline_succeeds=true`
#   on every open MR, re-armed the held one after the hold was recorded, and the
#   MR self-merged the moment CI went green — bypassing the two-person review
#   that .gitlab-ci.yml requires for its own path.
#
#   The lesson, recorded verbatim by the operator:
#       a hold expressed only in a document is not a hold —
#       it must be expressed in the automation.
#
#   So a hold, here, is a state the FORGE enforces, not a label a bot can
#   ignore. See `_mr_apply_hold` for the mechanism and the header of
#   scripts/commands/mr.sh for the alternatives that were rejected.
#
# VALUES-SAFE
#   Same contract as lib/gitlab-issues.sh: the token is read here and used only
#   inside a 0600 curl config file — never printed, never in argv/ps/history.
#   The live GitLab domain is read from .secrets.yml; when it cannot be resolved
#   the placeholder `<gitlab-host>` is used so the real domain stays out of git.
#
# PROVIDES
#   _mr_host _mr_token _mr_project
#   _mr_api  <METHOD> <path> [json]        → body; status in $MR_HTTP_STATUS
#   _mr_get  <path>                        → body (GET)
#   _mr_fetch <iid>                        → the MR object
#   _mr_changed_files <iid>                → one path per line
#   _mr_sensitive_paths <iid>              → sensitive subset (rc 2 = unknown)
#   _mr_is_draft <iid-json>                → 0 held-as-draft · 1 not
#   _mr_apply_hold <iid> <reason> <label>  → enforce the hold (idempotent)
#   _mr_lift_hold  <iid>                   → undraft + drop hold labels
#   _mr_release_record <iid> <head_sha> <author>
#                                          → prints a valid Approved-By handle,
#                                            or nothing; rc 0 only when valid
#
# CONFIG (env overrides, all optional)
#   NWP_GITLAB_HOST · NWP_MR_TOKEN · NWP_MR_PROJECT · NWP_SECRETS_FILE
################################################################################

if [ -z "${PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
fi
: "${MR_SECRETS_FILE:=${NWP_SECRETS_FILE:-$PROJECT_ROOT/.secrets.yml}}"
: "${YQ:=$(command -v yq || true)}"

# shellcheck source=/dev/null
[ -f "$PROJECT_ROOT/lib/http.sh" ] && source "$PROJECT_ROOT/lib/http.sh"
if ! declare -F nwp_http_config_lines >/dev/null 2>&1; then
  nwp_http_config_lines(){ printf 'connect-timeout = 8\nmax-time = 20\n'; }
fi
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/sensitive-paths.sh"

if ! declare -F die >/dev/null 2>&1; then
  die(){ print_error "$*" 2>/dev/null || echo "ERROR: $*" >&2; exit 1; }
fi

# The marker lines. Deliberately unlovely: they are parsed, not read.
MR_HOLD_MARKER="NWP-SENSITIVE-PATH-HOLD"
MR_RELEASE_MARKER="NWP-SENSITIVE-PATH-RELEASE"
MR_HOLD_LABEL_SENSITIVE="hold::sensitive-path"
MR_HOLD_LABEL_MANUAL="hold::manual"

# The HTTP status of the last call.
#
# It is kept in a FILE, not just a variable, on purpose: almost every caller
# reads a response with `json=$(_mr_fetch …)`, and a variable assigned inside a
# command substitution dies with the subshell. The first version of this lib
# used a plain variable and every error message in `pl mr` said
# "HTTP ${MR_HTTP_STATUS:-?}" → "HTTP ?" — a diagnostic that never once
# diagnosed anything. Use `_mr_http_status` to read it.
MR_HTTP_STATUS=""
: "${MR_STATUS_FILE:=$(mktemp "${TMPDIR:-/tmp}/.nwp-mr-status.XXXXXX")}"
chmod 600 "$MR_STATUS_FILE" 2>/dev/null || true
_mr_status_cleanup(){ rm -f "$MR_STATUS_FILE" 2>/dev/null || true; }
trap _mr_status_cleanup EXIT

_mr_http_status(){ cat "$MR_STATUS_FILE" 2>/dev/null || printf '?'; }

_mr_host(){
  local h="${NWP_GITLAB_HOST:-}"
  if [ -z "$h" ] && [ -n "$YQ" ]; then
    h=$("$YQ" e '.gitlab.server.domain // ""' "$MR_SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  fi
  # Placeholder keeps the live domain out of git (see .gitleaks.toml).
  [ -z "$h" ] && h="<gitlab-host>"
  printf '%s' "$h"
}

# Token preference: an explicit CI/job token first (so the pipeline never needs
# the developer credential), then .secrets.yml:gitlab.api_token — the non-admin
# group bot that ADR-0024 left as the MR-capable identity.
#
# NOTE the deliberate omission of gitlab.ops_note_token: it is Reporter on
# nwp/ops only and cannot touch an MR on the code repo. Falling back to it would
# turn "I lack the rights" into a confusing 404.
_mr_token(){
  local t="${NWP_MR_TOKEN:-}"
  if [ -z "$t" ] && [ -n "$YQ" ]; then
    t=$("$YQ" e '.gitlab.api_token // ""' "$MR_SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  fi
  printf '%s' "$t"
}

_mr_have_token(){ [ -n "$(_mr_token)" ]; }

# URL-encoded project path. CI hands us CI_PROJECT_ID; otherwise derive it from
# the origin remote so `pl mr` works in any checkout of any NWP repo.
_mr_project(){
  if [ -n "${NWP_MR_PROJECT:-}" ]; then printf '%s' "$NWP_MR_PROJECT"; return 0; fi
  if [ -n "${CI_PROJECT_ID:-}" ];   then printf '%s' "$CI_PROJECT_ID";  return 0; fi
  local url path
  url=$(git remote get-url origin 2>/dev/null) || return 1
  path=$(printf '%s' "$url" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')
  [ -n "$path" ] || return 1
  printf '%s' "${path//\//%2F}"
}

# _mr_api METHOD path [json-body] — body on stdout, HTTP status in MR_HTTP_STATUS.
_mr_api(){
  local method="$1" path="$2" payload="${3:-}"
  local host token cfg body_file="" raw
  host=$(_mr_host); token=$(_mr_token)
  if [ -z "$token" ]; then
    MR_HTTP_STATUS="000"; printf '000' > "$MR_STATUS_FILE" 2>/dev/null || true
    return 1
  fi
  cfg=$(mktemp); chmod 600 "$cfg"
  {
    printf 'silent\n'
    nwp_http_config_lines
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$token"
    printf 'request = "%s"\n' "$method"
    if [ -n "$payload" ]; then
      body_file=$(mktemp); chmod 600 "$body_file"; printf '%s' "$payload" > "$body_file"
      printf 'header = "Content-Type: application/json"\n'
      printf 'data = "@%s"\n' "$body_file"
    fi
    printf 'write-out = "\\n%%{http_code}"\n'
    printf 'url = "https://%s/api/v4%s"\n' "$host" "$path"
  } > "$cfg"
  token=""
  raw=$(curl -K "$cfg" 2>/dev/null)
  rm -f "$cfg" ${body_file:+"$body_file"}
  MR_HTTP_STATUS="${raw##*$'\n'}"
  printf '%s' "$MR_HTTP_STATUS" > "$MR_STATUS_FILE" 2>/dev/null || true
  printf '%s' "${raw%$'\n'*}"
  case "$MR_HTTP_STATUS" in 2*) return 0 ;; *) return 1 ;; esac
}

_mr_get(){ _mr_api GET "$1"; }

_mr_jget(){ "$YQ" e -p=json ".$1 // \"\"" - 2>/dev/null | grep -v '^null$'; }

# _mr_fetch <iid> → the MR JSON object (empty + rc1 when it cannot be read)
_mr_fetch(){
  local iid="$1" proj json
  proj=$(_mr_project) || return 1
  json=$(_mr_get "/projects/$proj/merge_requests/$iid") || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json"
}

# _mr_changed_files <iid> → one repo-relative path per line.
#
# Uses /diffs (paginated, cheap) rather than /changes: /changes is deprecated and
# on a large MR returns the whole patch text, which we neither need nor want to
# hold in memory. Renames report BOTH sides — a rename INTO a sensitive path and
# a rename OUT of one are each worth a hold.
_mr_changed_files(){
  local iid="$1" proj json page=0 rows
  proj=$(_mr_project) || return 1
  while :; do
    page=$((page + 1))
    json=$(_mr_get "/projects/$proj/merge_requests/$iid/diffs?per_page=100&page=$page") || return 1
    [ -n "$json" ] || break
    rows=$("$YQ" e -p=json -r '.[] | [.new_path, .old_path] | .[]' - <<<"$json" 2>/dev/null) || break
    [ -n "$rows" ] || break
    printf '%s\n' "$rows"
    [ "$(printf '%s\n' "$rows" | grep -c .)" -lt 100 ] && break
    [ "$page" -ge 30 ] && break
  done | grep -v '^null$' | sort -u
  return 0
}

# _mr_sensitive_paths <iid> → sensitive subset of the MR's changed files.
# rc 0 = determined (may print nothing) · 2 = COULD NOT DETERMINE.
# rc 2 is not "clean". Every caller must fail closed on it.
_mr_sensitive_paths(){
  local iid="$1" files
  files=$(_mr_changed_files "$iid") || return 2
  [ -n "$files" ] || return 0
  printf '%s\n' "$files" | nwp_sensitive_filter || return 2
  return 0
}

# _mr_is_draft <mr-json> → 0 when GitLab itself considers this a draft.
_mr_is_draft(){
  local json="$1" d
  d=$(printf '%s' "$json" | "$YQ" e -p=json '.draft // .work_in_progress // false' - 2>/dev/null)
  [ "$d" = "true" ]
}

_mr_title(){    printf '%s' "$1" | _mr_jget title; }
_mr_author(){   printf '%s' "$1" | _mr_jget 'author.username'; }
_mr_head_sha(){ printf '%s' "$1" | _mr_jget sha; }
_mr_state(){    printf '%s' "$1" | _mr_jget state; }
_mr_detailed_merge_status(){ printf '%s' "$1" | _mr_jget detailed_merge_status; }
_mr_auto_merge_armed(){
  local v
  v=$(printf '%s' "$1" | "$YQ" e -p=json '.merge_when_pipeline_succeeds // false' - 2>/dev/null)
  [ "$v" = "true" ]
}

# _mr_has_hold_label <mr-json> → 0 when a hold:: label is present.
#
# This is what makes a MANUAL hold durable rather than one-shot. The label is
# not the lock (see the header), but it IS the record of intent that lets the
# guard re-apply the lock on the next pipeline if someone un-drafts the MR
# without going through `pl mr release`. A hold you can undo by clicking
# "Mark as ready" once is the document-shaped hold again, wearing a badge.
_mr_has_hold_label(){
  local labels
  labels=$(printf '%s' "$1" | "$YQ" e -p=json -r '.labels | join(",")' - 2>/dev/null)
  case ",$labels," in
    *",$MR_HOLD_LABEL_MANUAL,"*|*",$MR_HOLD_LABEL_SENSITIVE,"*) return 0 ;;
  esac
  return 1
}

# _mr_notes <iid> → the note bodies, newest first, tab-flattened one per line.
_mr_notes(){
  local iid="$1" proj json
  proj=$(_mr_project) || return 1
  json=$(_mr_get "/projects/$proj/merge_requests/$iid/notes?per_page=100&sort=desc&order_by=created_at") || return 1
  printf '%s' "$json"
}

################################################################################
# THE HOLD
#
# `_mr_apply_hold` makes THREE changes, in this order, and the order matters:
#
#   1. cancel any armed auto-merge          — undoes the exact thing that went
#                                             wrong: a sweeper's blanket
#                                             `merge_when_pipeline_succeeds`
#   2. set Draft (title prefix `Draft: `)   — the ENFORCEMENT. GitLab refuses
#                                             PUT .../merge with 405 while an MR
#                                             is a draft, and refuses it even
#                                             when auto-merge is armed: the
#                                             armed merge simply never fires.
#                                             A bot re-arming auto-merge cannot
#                                             defeat this, because arming is not
#                                             what merges — leaving draft is.
#   3. add a hold:: label + an explaining   — for humans and for `pl mr list`.
#      note                                   Advisory only, and labelled as
#                                             such: the label is documentation,
#                                             the draft is the lock.
#
# Idempotent: re-running on an already-held MR re-asserts every layer and adds
# no duplicate note.
################################################################################

# Pure title transforms, split out so they are testable without a forge.
# `Draft:` is GitLab's marker; `WIP:` is the legacy spelling it still honours.
_mr_draft_title(){
  local t="${1:-}"
  case "$t" in
    Draft:*|draft:*|DRAFT:*|WIP:*|wip:*) printf '%s' "$t" ;;
    *) printf 'Draft: %s' "$t" ;;
  esac
}
_mr_undraft_title(){
  printf '%s' "${1:-}" | sed -E 's/^[[:space:]]*((Draft|draft|DRAFT|WIP|wip):[[:space:]]*)+//'
}

_mr_apply_hold(){
  local iid="$1" reason="${2:-}" label="${3:-$MR_HOLD_LABEL_MANUAL}" paths="${4:-}"
  local proj json title new_title payload
  proj=$(_mr_project) || return 1
  json=$(_mr_fetch "$iid") || return 1
  title=$(_mr_title "$json")

  # 1. disarm auto-merge (404 simply means it was not armed)
  _mr_api DELETE "/projects/$proj/merge_requests/$iid/merge_when_pipeline_succeeds" >/dev/null 2>&1 || true

  # 2. draft
  new_title=$(_mr_draft_title "$title")
  payload=$(T="$new_title" A="$label" "$YQ" -n -o=json \
    '{"title": strenv(T), "add_labels": strenv(A)}')
  _mr_api PUT "/projects/$proj/merge_requests/$iid" "$payload" >/dev/null || return 1

  # 3. explain, once
  local notes
  notes=$(_mr_notes "$iid" 2>/dev/null || true)
  if ! printf '%s' "$notes" | grep -q "$MR_HOLD_MARKER"; then
    local body
    body="$MR_HOLD_MARKER
This merge request is HELD. It has been set to **Draft**, which is the state the
forge itself enforces: GitLab refuses a merge on a draft (HTTP 405) even when
\`merge_when_pipeline_succeeds\` is armed. Arming auto-merge on this MR is
harmless and will not merge it.

Reason: ${reason:-(none given)}"
    [ -n "$paths" ] && body="$body

Sensitive paths touched:
$(printf '%s\n' "$paths" | sed 's/^/  - /')"
    body="$body

Release it deliberately, with a second pair of eyes:
    pl mr release $iid --approved-by=<handle> --reason='...'"
    local np; np=$(B="$body" "$YQ" -n -o=json '{"body": strenv(B)}')
    _mr_api POST "/projects/$proj/merge_requests/$iid/notes" "$np" >/dev/null || true
  fi
  return 0
}

# _mr_lift_hold <iid> — undraft and drop the hold labels. Nothing else.
_mr_lift_hold(){
  local iid="$1" proj json title new_title payload
  proj=$(_mr_project) || return 1
  json=$(_mr_fetch "$iid") || return 1
  title=$(_mr_title "$json")
  new_title=$(_mr_undraft_title "$title")
  payload=$(T="$new_title" R="$MR_HOLD_LABEL_SENSITIVE,$MR_HOLD_LABEL_MANUAL" "$YQ" -n -o=json \
    '{"title": strenv(T), "remove_labels": strenv(R)}')
  _mr_api PUT "/projects/$proj/merge_requests/$iid" "$payload" >/dev/null || return 1
  return 0
}

################################################################################
# THE RELEASE RECORD
#
# A release is a claim by a SECOND person about a SPECIFIC diff. Both halves are
# checked, because either one alone is trivially satisfiable by whoever (or
# whatever) opened the MR:
#
#   Approved-By ≠ the MR author       one pair of eyes is not two
#   Approved-By is not a bot handle   `group_9_bot` approving itself is not review
#   Commit == the MR's current head   pushing a new commit INVALIDATES the
#                                     release, so "approved, then quietly
#                                     amended" re-holds automatically
#
# The last condition is the one that makes this hard to game by accident, and it
# is why no approver allowlist is needed: a release is scoped to bytes, not to a
# name.
################################################################################
_mr_release_record(){
  local iid="$1" head_sha="$2" author="$3"
  local notes bodies approved commit
  notes=$(_mr_notes "$iid") || return 1
  # Notes come back newest-first; take the first that validates.
  #
  # The bodies are flattened into one stream with an explicit BOUNDARY between
  # them, and the boundary resets the parse. Without it, `Approved-By:` in one
  # note and `Commit:` in a completely different note would combine into a
  # release record that nobody ever wrote — a forgery assembled by accident out
  # of two innocent comments. A release must be one note, entire.
  local BOUNDARY='@@NWP-NOTE-BOUNDARY@@'
  bodies=$(B="$BOUNDARY" "$YQ" e -p=json -r \
             '.[] | select(.system == false) | .body + "\n" + strenv(B)' - <<<"$notes" 2>/dev/null) || return 1
  local block=""
  while IFS= read -r line; do
    if [ "$line" = "$BOUNDARY" ]; then
      block=""; approved=""; commit=""
      continue
    fi
    if [ "$line" = "$MR_RELEASE_MARKER" ]; then
      block="$MR_RELEASE_MARKER"; approved=""; commit=""
      continue
    fi
    [ -n "$block" ] || continue
    case "$line" in
      Approved-By:*) approved=$(printf '%s' "${line#Approved-By:}" | tr -d ' @' ) ;;
      Commit:*)      commit=$(printf '%s' "${line#Commit:}" | tr -d ' ' ) ;;
    esac
    if [ -n "$approved" ] && [ -n "$commit" ]; then
      if [ "$commit" = "$head_sha" ] \
         && [ "$approved" != "$author" ] \
         && ! _mr_handle_is_bot "$approved"; then
        printf '%s' "$approved"; return 0
      fi
      block=""
    fi
  done <<<"$bodies"
  return 1
}

# A bot cannot be the second pair of eyes. Two independent signals, because
# either alone has a hole: the naming convention catches GitLab's own
# `group_<n>_bot` / `project_<n>_bot` service accounts without an API call, and
# the user lookup catches a bot with a human-looking name.
_mr_handle_is_bot(){
  local h="${1:-}"
  [ -n "$h" ] || return 0
  # NOTE the trailing wildcards. GitLab's service accounts are not named
  # `group_9_bot` but `group_9_bot_53ae5a1df066ec501e8867f7276f66b1` — a bare
  # `group_*_bot` pattern misses every real one, which is the sort of guard that
  # tests green and protects nothing.
  case "$h" in
    group_*_bot*|project_*_bot*|*-bot|*_bot|*_bot_*|ghost|support-bot|alert-bot) return 0 ;;
  esac
  local json isbot
  json=$(_mr_get "/users?username=$h" 2>/dev/null) || return 1
  isbot=$("$YQ" e -p=json '.[0].bot // false' - <<<"$json" 2>/dev/null)
  [ "$isbot" = "true" ]
}
