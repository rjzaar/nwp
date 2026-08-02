#!/bin/bash
################################################################################
# lib/gitlab-issues.sh — sourceable GitLab issue API helpers for nwp/ops.
#
# Single home for the authenticated curl plumbing so multiple commands reuse it
# instead of duplicating the token handling:
#   - pl issue  (scripts/commands/issue.sh)  — the read+write work-board CLI
#   - pl rag --sync-issues (scripts/commands/rag.sh) — RAG → issue upsert (ops#6)
#
# Values-safe by construction: the api token is read from .secrets.yml by THIS
# lib and used only inside a 0600 curl config + a 0600 data file — never printed,
# never in argv / ps / shell history. Prefers the least-privilege
# gitlab.ops_note_token (Reporter on nwp/ops), falling back to gitlab.api_token.
#
# Provides: _host _token _api_get _api_send _jget _require_ok  (+ a guarded die).
# Config it reads (all overridable by the sourcing script BEFORE sourcing):
#   PROJECT_ROOT  SECRETS_FILE  PROJECT_ID  YQ
################################################################################

# Resolve shared config only if the sourcing script hasn't already set it. The
# `:=` defaults are no-ops when the caller pre-defines these (issue.sh does).
if [ -z "${PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
fi
: "${SECRETS_FILE:=${NWP_SECRETS_FILE:-$PROJECT_ROOT/.secrets.yml}}"
: "${PROJECT_ID:=${NWP_OPS_PROJECT_ID:-21}}"          # nwp/ops
: "${YQ:=$(command -v yq || true)}"

# Shared timeout policy (interactive vs batch) — see lib/http.sh. These two
# helpers previously hardcoded `max-time = 20` / `= 30`, which is bounded but is
# a THIRD opinion about how long to wait, and a 30s stall is far too long in
# front of an operator running `pl issue ls`. Take the budget from one place.
# shellcheck source=/dev/null
[ -f "$PROJECT_ROOT/lib/http.sh" ] && source "$PROJECT_ROOT/lib/http.sh"
# Fallback so this lib still works if sourced standalone without lib/http.sh.
if ! declare -F nwp_http_config_lines >/dev/null 2>&1; then
  nwp_http_config_lines(){ printf 'connect-timeout = 8\nmax-time = 20\n'; }
fi

# Only define die if the caller hasn't (issue.sh defines its own; rag.sh doesn't).
if ! declare -F die >/dev/null 2>&1; then
  die(){ print_error "$*" 2>/dev/null || echo "ERROR: $*" >&2; exit 1; }
fi

_host(){
  local h="${NWP_GITLAB_HOST:-}"
  [ -z "$h" ] && h=$("$YQ" e '.gitlab.server.domain // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  [ -z "$h" ] && h="<gitlab-host>"   # real host comes from .gitlab.server.domain; placeholder keeps the live domain out of git (see .gitleaks.toml)
  printf '%s' "$h"
}

# Which .secrets.yml key(s) to read, in preference order, as a yq expression.
# Default = the least-privilege ops_note_token (Reporter on nwp/ops), falling
# back to gitlab.api_token — UNCHANGED behaviour for every existing caller.
#
# It is overridable per call site because the least-privilege token is scoped to
# ONE project: measured 2026-08-02, `gitlab.ops_note_token` gets `404 Project Not
# Found` on nwp/nwc (project 16), which is where tester feedback lands. A reader
# that wants a different project must be able to say which credential can see it
# instead of silently rendering an empty list.
: "${GITLAB_TOKEN_EXPR:=.gitlab.ops_note_token // .gitlab.api_token // \"\"}"

_token(){
  local t
  t=$("$YQ" e "$GITLAB_TOKEN_EXPR" "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  [ -n "$t" ] || die "no usable token in $SECRETS_FILE (looked for: $GITLAB_TOKEN_EXPR)"
  printf '%s' "$t"
}

# _token_present — "would _token succeed?", WITHOUT dying and without printing
# the value. _token calls die (exit 1), which is right for an operator running
# `pl issue`, and wrong for an unattended step that runs AFTER a live reset has
# already succeeded: there, no token must mean "keep the payload for later", not
# "report the night as a failure". Callers that cannot afford an exit ask here
# first. Same key list as _token, in the same file, so the two cannot drift.
_token_present(){
  local t
  [ -s "$SECRETS_FILE" ] || return 1
  [ -n "${YQ:-}" ] || return 1
  t=$("$YQ" e "$GITLAB_TOKEN_EXPR" "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  [ -n "$t" ]
}

# run an authenticated GET; prints the JSON body. token stays in a 0600 curl config.
_api_get(){ # $1 = path (e.g. /projects/21/issues?...)
  local host token cfg
  host=$(_host); token=$(_token)
  cfg=$(mktemp); chmod 600 "$cfg"
  { printf 'silent\n'
    nwp_http_config_lines
    printf 'header = "PRIVATE-TOKEN: %s"\nurl = "https://%s/api/v4%s"\n' "$token" "$host" "$1"
  } > "$cfg"
  token=""
  curl -K "$cfg" 2>/dev/null
  rm -f "$cfg"
}

################################################################################
# ops#235 — CROSS-PROJECT READS, AND THE DIFFERENCE BETWEEN "NONE" AND "BLIND".
#
# THE BUG. `pl issue close`'s guard asked nwp/ops (project 21) for an issue's
# related merge requests, using `gitlab.ops_note_token` — a Reporter token walled
# to project 21. The implementing MRs live in nwp/nwp (project 9).
#
# GitLab does NOT 403 the cross-project half. It silently FILTERS OUT the merge
# requests the token cannot see and returns `[]`. So the guard's only reachable
# answer was "0 open MRs" and it failed open, silently, every time. Measured on
# 2026-08-02 against a live issue that had four related MRs, one of them open:
#
#     ops_note_token -> []                 (0)
#     api_token      -> !306 merged, !327 merged, !334 merged, !337 OPENED
#
# A 403 would have been loud. `[]` reads as a clean bill of health.
#
# THE RULE THIS ENCODES. A read whose answer depends on the reader's visibility
# must state its own coverage. Two things follow:
#
#   * escalate for the READ. This specific question needs a token that can see
#     the code projects; the least-privilege default stays in force for writes.
#   * FAIL CLOSED on blindness — `pl server health`'s rc-3 convention. An empty
#     array from a token with no cross-project read is not evidence of absence,
#     it is absence of evidence, and the two must not share an exit code.
#
# NWP_ISSUE_CODE_PROJECTS (whitespace-separated project ids) declares where
# implementing MRs can live. Default 9 = nwp/nwp. Tests override it.
################################################################################

# _api_get_as — authenticated GET using a SPECIFIC .secrets.yml key rather than
# the default preference order. Prints the body; prints nothing if the key is
# absent. Token stays inside a 0600 curl config, never in argv/ps/history.
_api_get_as(){ # $1 = yq key expression (e.g. .gitlab.api_token)   $2 = path
  local key="$1" path="$2" host token cfg
  token=$("$YQ" e "$key // \"\"" "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  [ -n "$token" ] || return 1
  host=$(_host)
  cfg=$(mktemp); chmod 600 "$cfg"
  { printf 'silent\n'
    nwp_http_config_lines
    printf 'header = "PRIVATE-TOKEN: %s"\nurl = "https://%s/api/v4%s"\n' "$token" "$host" "$path"
  } > "$cfg"
  token=""
  curl -K "$cfg" 2>/dev/null
  rm -f "$cfg"
}

# _code_projects — the project ids an ops issue's implementing MR can live in.
_code_projects(){
  local ids="${NWP_ISSUE_CODE_PROJECTS:-9}"
  printf '%s\n' $ids
}

# _mr_read_key — which token key can actually SEE every declared code project?
# Sets the global `_MR_READ_KEY` to the yq key expression; returns 1 = BLIND
# with every key we hold. Tries least-privilege first, so a suitably-scoped ops
# token would be preferred if one ever exists; escalates only because the walled
# one cannot answer.
#
# Memoised: which token can see the code projects is a property of the RUN, not
# of the issue. `pl issue reconcile` asks per issue across 160+ issues; without
# the memo that is 300+ extra round trips to answer the same question.
#
# IT SETS A GLOBAL RATHER THAN PRINTING, and that is not a style choice. The
# first version printed the key and callers wrote `key=$(_mr_read_key)` — a
# COMMAND SUBSTITUTION, i.e. a subshell, so every cache write was discarded the
# moment it happened. The memo silently did nothing: measured 10 probe calls for
# 5 issues instead of 2. Caught only because the test asserted the call COUNT
# rather than the presence of a cache variable.
_MR_READ_KEY=""            # the answer, for callers
_MR_READ_KEY_CACHE=""      # "" = not yet probed, "-" = probed and BLIND
_mr_read_key(){
  if [ -n "$_MR_READ_KEY_CACHE" ]; then
    [ "$_MR_READ_KEY_CACHE" = "-" ] && return 1
    _MR_READ_KEY="$_MR_READ_KEY_CACHE"; return 0
  fi
  local key pid resp
  for key in '.gitlab.ops_note_token' '.gitlab.api_token'; do
    local ok=1
    for pid in $(_code_projects); do
      resp=$(_api_get_as "$key" "/projects/$pid" 2>/dev/null || true)
      # A visible project echoes its own numeric id. 404/403 return a .message.
      printf '%s' "$resp" | "$YQ" e -p=json '.id // ""' - 2>/dev/null \
        | grep -qx -- "$pid" || { ok=0; break; }
    done
    [ "$ok" = "1" ] && { _MR_READ_KEY_CACHE="$key"; _MR_READ_KEY="$key"; return 0; }
  done
  _MR_READ_KEY_CACHE="-"; _MR_READ_KEY=""
  return 1
}

# issue_open_mrs — open merge requests referencing an ops issue.
#
# Exit codes are the whole point:
#   0  no open MRs, AND we could see the declared code projects   (safe to close)
#   1  at least one OPEN MR; the list is printed, one per line    (refuse)
#   3  BLIND — could not see the code projects, so "0" is unproven (refuse)
#
# Never conflate 0 and 3. That conflation IS ops#235.
#
# PAGINATED since 2026-08-03 (!320 rebase). The single unpaginated GET this
# replaced took GitLab's DEFAULT page size for this endpoint — 20, not 100 — so
# on an issue with more than 20 related merge requests an open one sitting on
# page 2 was invisible and the guard passed. That is the ops#235 failure again
# in a narrower window: a guard that did not read everything, reporting a pass.
# It walks pages through `_api_rows`, the one pagination primitive, using
# NWP_API_ROWS_KEY so the escalated token is still the one that does the read.
issue_open_mrs(){ # $1 = issue iid
  local iid="$1" key lines rc=0
  # NOT `key=$(_mr_read_key)` — see the note on _mr_read_key. A subshell here
  # throws the memo away on every call.
  _mr_read_key || return 3
  key="$_MR_READ_KEY"
  # Anything that is not a JSON ARRAY is an error body, not "none": _api_rows
  # returns 3 for that, and for an unreachable host, on the FIRST page.
  lines=$(NWP_API_ROWS_KEY="$key" _api_rows \
            "/projects/$PROJECT_ID/issues/$iid/related_merge_requests" \
            'select(.state == "opened")
             | ((.references.full // ("!" + (.iid|tostring))) + "  " + (.title // ""))' \
          2>/dev/null) || rc=$?
  [ "$rc" -eq 3 ] && return 3
  [ -n "$lines" ] || return 0
  printf '%s\n' "$lines"
  return 1
}

# run an authenticated write (POST/PUT). The JSON body is passed via a 0600 temp
# file so newlines/quotes in titles & descriptions survive, and the payload never
# lands in argv / ps / shell history. token stays in the 0600 curl config too.
_api_send(){ # $1=METHOD $2=path [$3=json-body]
  local method="$1" path="$2" payload="${3:-}"
  local host token cfg body=""
  host=$(_host); token=$(_token)
  cfg=$(mktemp); chmod 600 "$cfg"
  {
    printf 'silent\n'
    nwp_http_config_lines
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$token"
    printf 'request = "%s"\n' "$method"
    if [ -n "$payload" ]; then
      body=$(mktemp); chmod 600 "$body"; printf '%s' "$payload" > "$body"
      printf 'header = "Content-Type: application/json"\n'
      printf 'data = "@%s"\n' "$body"
    fi
    printf 'url = "https://%s/api/v4%s"\n' "$host" "$path"
  } > "$cfg"
  token=""
  curl -K "$cfg" 2>/dev/null
  rm -f "$cfg" ${body:+"$body"}
}

# extract one scalar field from a GitLab JSON object response
_jget(){ "$YQ" e -p=json ".$1 // \"\"" - 2>/dev/null | grep -v '^null$'; }

# require an expected field in a response, else die with GitLab's error message.
# prints the field value on success.
_require_ok(){ # $1=json $2=key-that-must-exist  $3=action-description
  local json="$1" key="$2" desc="$3" v msg
  v=$(printf '%s' "$json" | _jget "$key")
  if [ -z "$v" ]; then
    msg=$(printf '%s' "$json" | "$YQ" e -p=json '.message // .error // ""' - 2>/dev/null | grep -v '^null$')
    die "$desc failed${msg:+: $msg}"
  fi
  printf '%s' "$v"
}

################################################################################
# _api_rows — THE pagination primitive. Any read of a GitLab *collection* goes
# through here.
#
# WHY THIS IS A LIB FUNCTION AND NOT AN INLINE LOOP: on 2026-08-02 `pl issue ls`
# showed 100 of nwp/ops' 136 open issues. It asked for `per_page=100`, got the
# API's cap, printed the rows, and stopped — no page 2, no "showing 100 of 136".
# Because the sort was `created_at asc`, the 36 rows it dropped were the NEWEST,
# i.e. exactly the ones an operator opens the list to triage. `cmd_reconcile`
# had already been fixed for the identical bug and carried the reasoning in a
# comment; the fix was not shared, so the bug survived in its siblings. It is
# shared now.
#
#   _api_rows <path> <yq-per-item-expr> [max_pages]
#
# <path> may already carry a query string; per_page/page are appended.
# <yq-per-item-expr> is evaluated as `.[] | <expr>` and must emit ONE LINE per
# item. Use `[...] | join("\t")` after flattening newlines/tabs out of the
# fields — NOT `@tsv`, whose encoder CSV-quotes any field containing a `"`, so
# a title like `replace "amened"` renders to the operator as
# `"replace ""amened"""`.
#
# Prints TSV rows to stdout. Rows are emitted page by page and never merged as
# JSON: there is no concatenation step that could quietly lose a page.
#
# Returns 0 on a complete read, 3 if the FIRST page was not a JSON array (auth
# failure / 404 / unreachable host). rc=3 is "I could not look" and callers MUST
# report it — an empty list from an unreadable source must never render as "no
# issues".
#
# Sets NWP_API_ROWS_COUNT (rows emitted) and NWP_API_ROWS_TRUNCATED (1 if the
# max_pages guard stopped the walk before the server ran out). A cap is allowed;
# a SILENT cap is not.
#
# NWP_API_ROWS_KEY — read with a SPECIFIC .secrets.yml key (via _api_get_as)
# instead of the default preference order. Set it for the one read that must
# escalate past the walled ops token: `issue_open_mrs` (ops#235). Without this
# hook that reader could not use the pagination primitive at all, and a
# collection read that opts out of the primitive is exactly how `pl issue ls`
# kept a truncation bug that `cmd_reconcile` had already fixed.
################################################################################
_api_rows(){
  local path="$1" expr="$2" max="${3:-20}"
  local page=0 sep batch kind n rows
  NWP_API_ROWS_COUNT=0
  NWP_API_ROWS_TRUNCATED=0
  case "$path" in *\?*) sep='&' ;; *) sep='?' ;; esac
  while :; do
    page=$((page + 1))
    if [ -n "${NWP_API_ROWS_KEY:-}" ]; then
      batch=$(_api_get_as "$NWP_API_ROWS_KEY" "${path}${sep}per_page=100&page=${page}" 2>/dev/null || true)
    else
      batch=$(_api_get "${path}${sep}per_page=100&page=${page}")
    fi
    if [ -z "$batch" ]; then
      [ "$page" -eq 1 ] && return 3
      break
    fi
    # A GitLab error is an OBJECT ({"message":"404 …"}); a collection is an
    # array. Iterating an object with `.[]` would emit its values as if they
    # were rows, so the shape is checked before anything is printed.
    kind=$(printf '%s' "$batch" | "$YQ" e -p=json 'tag' - 2>/dev/null || true)
    if [ "$kind" != "!!seq" ]; then
      [ "$page" -eq 1 ] && return 3
      break
    fi
    n=$(printf '%s' "$batch" | "$YQ" e -p=json 'length' - 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    [ "$n" -eq 0 ] && break
    rows=$(printf '%s' "$batch" | "$YQ" e -p=json -r ".[] | $expr" - 2>/dev/null || true)
    if [ -n "$rows" ]; then
      printf '%s\n' "$rows"
      NWP_API_ROWS_COUNT=$((NWP_API_ROWS_COUNT + n))
    fi
    # Fewer than a full page came back → the server has nothing more.
    [ "$n" -lt 100 ] && break
    if [ "$page" -ge "$max" ]; then NWP_API_ROWS_TRUNCATED=1; break; fi
  done
  return 0
}
