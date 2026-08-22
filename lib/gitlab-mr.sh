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
# yq resolution. The bare `command -v yq` is not enough in CI: the runner has
# yq at ~/.local/bin/yq, which is on an interactive PATH but not necessarily on
# a job's. An empty $YQ then makes every parse call run `"" e …`, which fails —
# and the ONLY visible symptom was the bodies parse returning non-zero, which
# this library reported as "the notes API could not be read" while the notes
# call had in fact returned HTTP 200. A missing tool wearing an API error's
# costume (!314, pipelines 1782/1784).
: "${YQ:=$(command -v yq || true)}"
if [ -z "$YQ" ]; then
  for _c in "$HOME/.local/bin/yq" /usr/local/bin/yq /usr/bin/yq /snap/bin/yq; do
    [ -x "$_c" ] && { YQ="$_c"; break; }
  done
fi

# _mr_require_yq — every parse path goes through yq, so its absence is a
# CANNOT-VERIFY for the whole library, said once and plainly.
_mr_have_yq(){ [ -n "$YQ" ] && [ -x "$YQ" ]; }

# _mr_json <key> <value> [<key> <value> ...]  → a JSON object on stdout
#
# WHY THIS EXISTS (nwp/ops#281). Every write payload in this file was built with
#   payload=$(T="$title" A="$label" "$YQ" -n -o=json '{"title": strenv(T), ...}')
# and $YQ is EMPTY on the CI runner, which has no yq. With an empty command name
# bash runs the assignments and nothing else, so `payload` came back EMPTY, the
# PUT sent an empty body, GitLab answered 400 — and the D13 hold's LAYER 1 (the
# Draft) silently never applied. Every CI-applied hold has therefore been resting
# on layer 2, the red pipeline, which the module docblock itself calls the weaker
# one: "a red pipeline is indistinguishable from a broken build, it trains people
# to retry until green, and one allow_failure: true ends it."
#
# That is the host-blind-branch shape from CLAUDE.md, occurring inside the gate
# built to enforce it.
#
# python3 is the right dependency here: it is already this file's fallback for
# READING json (_mr_jget), it is present wherever Drupal/Drush run, and building
# a two-key object is not a job that needs a YAML processor. Values are passed as
# argv, never interpolated, so quotes/newlines/unicode in a title or a note body
# cannot break the payload or inject a field.
# A key may carry a ":bool" suffix to emit a real JSON boolean rather than a
# string — `remove_source_branch:bool "true"` → {"remove_source_branch": true}.
# Explicit on purpose: the yq expression this replaces wrote
# `(strenv(R) == "true")`, and quietly turning that field into the STRING "true"
# would be a type change hidden inside a bug fix.
_mr_json(){
    python3 -c 'import json,sys
a = sys.argv[1:]
out = {}
for i in range(0, len(a) - 1, 2):
    k, v = a[i], a[i + 1]
    if k.endswith(":bool"):
        out[k[:-5]] = (v == "true")
    else:
        out[k] = v
print(json.dumps(out))' "$@"
}

_mr_require_yq(){
  _mr_have_yq && return 0
  command -v python3 >/dev/null 2>&1 && return 0
  echo "CANNOT VERIFY — neither yq nor python3 is available, and every GitLab" >&2
  echo "  API response in this library is parsed with one of them. This is a" >&2
  echo "  missing tool, not an API or permission problem." >&2
  return 2
}

# JSON parsing prefers yq and falls back to python3.
#
# WHY A FALLBACK AT ALL. This is a SECURITY gate; it decides whether a
# sensitive-path MR may merge. Making that decision depend on one binary being
# on one host's PATH is fragile, and it failed exactly that way: the CI runner
# executes jobs as `gitlab-runner`, yq existed only under /home/rob (mode 750,
# so unreachable), and the gate could not verify anything. python3 is present
# system-wide. yq stays the primary so the yq-first convention holds for YAML;
# this fallback is for JSON API responses only.
_mr_jget(){
  if _mr_have_yq; then
    "$YQ" e -p=json ".$1 // \"\"" - 2>/dev/null | grep -v '^null$'
  else
    # JSON SPELLING, not Python's. python prints True/False where yq prints
    # true/false, so every `[ "$x" = "true" ]` comparison against a _mr_jget
    # result silently evaluated FALSE wherever yq is absent — i.e. on the CI
    # runner, for draft, merge_when_pipeline_succeeds and is_bot alike. Caught by
    # a Draft MR reading as not-held once a test suite was finally made genuinely
    # yq-less (ops#293).
    python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
v=d
for part in sys.argv[1].split("."):
    v = v.get(part) if isinstance(v, dict) else None
    if v is None: break
if v is None: print("")
elif v is True: print("true")
elif v is False: print("false")
else: print(v)' "$1"
  fi
}

# _mr_note_bodies <boundary> — note bodies on stdout, one boundary line after
# each. Non-system notes only.
_mr_note_bodies(){
  if _mr_have_yq; then
    B="$1" "$YQ" e -p=json -r '.[] | select(.system == false) | .body + "\n" + strenv(B)' - 2>/dev/null
  else
    python3 -c 'import json,sys
try: notes=json.load(sys.stdin)
except Exception: sys.exit(1)
for n in notes:
    if not n.get("system", False):
        print(n.get("body","") or ""); print(sys.argv[1])' "$1"
  fi
}

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

MR_HOST_UNRESOLVED='<gitlab-host>'

_mr_host(){
  local h="${NWP_GITLAB_HOST:-}"
  if [ -z "$h" ] && [ -n "$YQ" ]; then
    h=$("$YQ" e '.gitlab.server.domain // ""' "$MR_SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  fi
  # IN CI THERE IS NO .secrets.yml. GitLab exports CI_SERVER_HOST into every
  # job, and _mr_project already leans on CI_PROJECT_ID the same way — the host
  # simply never got the matching fallback. Without it the placeholder below
  # went into the URL and every call returned HTTP 000, which the guard then
  # reported as "no release record for this head": a network failure wearing the
  # costume of a policy decision. Observed on !314, pipeline 1779.
  [ -z "$h" ] && h="${CI_SERVER_HOST:-}"
  # Placeholder keeps the live domain out of git (see .gitleaks.toml). It is NOT
  # a usable host; callers must treat it as "cannot determine", never dial it.
  [ -z "$h" ] && h="$MR_HOST_UNRESOLVED"
  printf '%s' "$h"
}

# _mr_host_ok — 0 if we know where the forge is, 1 if we do not.
# Exists so "I do not know the address" is a distinct, loud outcome instead of
# an unexplained HTTP 000 three layers down.
_mr_host_ok(){ [ "$(_mr_host)" != "$MR_HOST_UNRESOLVED" ]; }

# Token preference: an explicit CI/job token first (so the pipeline never needs
# the developer credential), then .secrets.yml:gitlab.api_token — the non-admin
# group bot that NWP-ADR-0024 left as the MR-capable identity.
#
# NOTE the deliberate omission of gitlab.ops_note_token: it is Reporter on
# nwp/ops only and cannot touch an MR on the code repo. Falling back to it would
# turn "I lack the rights" into a confusing 404.
#
# gitlab.ai_host_token was added 2026-08-03: the ai-host holds a project access
# token for nwp/nwp (api + write_repository, Developer) and NOT gitlab.api_token,
# which is the workstation's group bot. Provisioning that token to the ai-host
# achieved nothing until this function knew to look for it — `pl mr` reported
# "no usable token" on a host that was holding a perfectly valid one.
#
# Order is deliberate: an explicit job token, then the workstation's group bot,
# then the host-local one. Whichever answers first is the identity used.
_mr_token(){
  local t="${NWP_MR_TOKEN:-}" k
  if [ -z "$t" ] && [ -n "$YQ" ]; then
    for k in '.gitlab.api_token' '.gitlab.ai_host_token'; do
      t=$("$YQ" e "$k // \"\"" "$MR_SECRETS_FILE" 2>/dev/null | grep -v '^null$')
      [ -n "$t" ] && break
    done
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

# _mr_jget is defined above, with its python3 fallback.

# _mr_fetch <iid> → the MR JSON object (empty + rc1 when it cannot be read)
_mr_fetch(){
  local iid="$1" proj json
  proj=$(_mr_project) || return 1
  json=$(_mr_get "/projects/$proj/merge_requests/$iid") || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json"
}

# _mr_fetch_rebase <iid> → the MR object INCLUDING `rebase_in_progress`.
#
# GitLab omits that field from the ordinary MR read; it appears only when the
# request asks for it. A rebase is ASYNCHRONOUS — `PUT /rebase` returns 202 and
# the work happens on a sidekiq worker — so without this field there is no way to
# tell "finished" from "not started yet", and a caller that polls the plain
# object sees an unchanged head sha and concludes, wrongly, that nothing
# happened.
_mr_fetch_rebase(){
  local iid="$1" proj json
  proj=$(_mr_project) || return 1
  json=$(_mr_get "/projects/$proj/merge_requests/$iid?include_rebase_in_progress=true") || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json"
}

_mr_source_branch(){ printf '%s' "$1" | _mr_jget source_branch; }
_mr_target_branch(){ printf '%s' "$1" | _mr_jget target_branch; }
_mr_merge_error(){   printf '%s' "$1" | _mr_jget merge_error; }
_mr_rebase_in_progress(){ [ "$(printf '%s' "$1" | _mr_jget rebase_in_progress)" = "true" ]; }

# _mr_branch_is_current <target-branch> <source-branch>
#   rc 0 = origin/<target> is ALREADY an ancestor of origin/<source>, so a
#          rebase is a genuine no-op and the head will not move
#   rc 1 = it is not; a rebase WILL move the head
#   rc 2 = could not measure
#
# WHY THIS EXISTS — a real false negative, observed on !441 on 2026-08-14 by the
# verb that now calls it. `PUT /rebase` returns 202 and a sidekiq worker does the
# work, so for the first second or so `rebase_in_progress` is STILL FALSE and the
# head sha is STILL the old one. A poll loop that treats that state as "finished,
# nothing changed" reports:
#
#     SUCCESS: !441 is already up to date with main — head unchanged (c733a54f9615)
#
# …while the rebase it just requested lands moments later (9d32e469d656). That is
# the swallowed-verdict shape from CLAUDE.md: a literal substituted for a
# measurement that had not yet become takeable, wearing a green tick.
#
# The fix is to MEASURE whether the head must move, instead of inferring it from
# the head not having moved yet. `git merge-base --is-ancestor` answers exactly
# that, against the refs the forge holds. When it cannot be measured the caller
# must NOT fall back to "unchanged means done" — it reports not-finished (exit 3),
# because "I could not tell" is never "there was nothing to do".
_mr_branch_is_current(){
  local target="$1" source="$2" t s
  git rev-parse --git-dir >/dev/null 2>&1 || return 2
  git fetch -q origin "$target" "$source" >/dev/null 2>&1 || return 2
  t=$(git rev-parse --verify --quiet "refs/remotes/origin/$target" 2>/dev/null) || return 2
  s=$(git rev-parse --verify --quiet "refs/remotes/origin/$source" 2>/dev/null) || return 2
  [ -n "$t" ] && [ -n "$s" ] || return 2
  git merge-base --is-ancestor "$t" "$s" && return 0
  return 1
}

# _mr_local_testmerge <target-branch> <source-branch>
#   rc 0 = the merge is CLEAN · 1 = a REPRODUCED conflict (paths on stdout)
#   rc 2 = could not run the test at all
#
# WHY THIS EXISTS — CLAUDE.md, "this GitLab's detailed_merge_status goes stale":
# the API reports `conflict` for branches that merge cleanly, because the value
# is a cached computation that is not always recomputed when the target branch
# moves. A conflict is therefore only a conflict once it has been REPRODUCED
# against the actual bytes. This is that reproduction.
#
# `git merge-tree --write-tree` (git ≥ 2.38), NOT `git merge --no-commit --no-ff`
# followed by `git merge --abort`. The standing order names the latter and the
# INTENT is identical — a real merge of the real commits — but the mechanism
# matters here: ~/nwp is a shared checkout that several sessions switch branches
# in (recorded: "never commit in ~/nwp directly"), and the --no-commit form
# mutates the caller's index and leaves a half-merged tree behind if anything
# dies between the two commands. merge-tree does the same computation with no
# worktree, no index and nothing to abort, so a triage command can never damage
# the tree it was invoked from. Where merge-tree is unavailable this returns 2
# — "I could not run the test" — and never a clean verdict it did not measure.
_mr_local_testmerge(){
  local target="$1" source="$2" out rc=0 t s
  git rev-parse --git-dir >/dev/null 2>&1 || return 2
  # Fetch so the comparison is against what the FORGE holds, not a stale local
  # ref. A test-merge of yesterday's origin/main answers a question nobody asked.
  git fetch -q origin "$target" "$source" >/dev/null 2>&1 || return 2
  t=$(git rev-parse --verify --quiet "refs/remotes/origin/$target" 2>/dev/null) || return 2
  s=$(git rev-parse --verify --quiet "refs/remotes/origin/$source" 2>/dev/null) || return 2
  [ -n "$t" ] && [ -n "$s" ] || return 2
  out=$(git merge-tree --write-tree --name-only "$t" "$s" 2>&1); rc=$?
  case "$rc" in
    0) return 0 ;;
    1) # First line is the merged tree oid; the rest are the conflicted paths.
       printf '%s\n' "$out" | tail -n +2 | grep -v '^[[:space:]]*$' || true
       return 1 ;;
    *) return 2 ;;
  esac
}

# _mr_post_note <iid> <body> — post ONE note, unconditionally.
#
# Distinct from _mr_note_once, which is keyed on a marker so a CI job that runs
# on every push does not spam the thread. A note a human (or an agent acting for
# one) deliberately asked for must be posted every time it is asked for;
# de-duplicating it would silently swallow a correction.
_mr_post_note(){
  local iid="$1" body="$2" proj payload
  proj=$(_mr_project) || return 1
  [ -n "$body" ] || return 1
  payload=$(_mr_json body "$body")
  _mr_api POST "/projects/$proj/merge_requests/$iid/notes" "$payload" >/dev/null || return 1
  return 0
}

# _mr_changed_files <iid> → one repo-relative path per line.
#
# Uses /diffs (paginated, cheap) rather than /changes: /changes is deprecated and
# on a large MR returns the whole patch text, which we neither need nor want to
# hold in memory. Renames report BOTH sides — a rename INTO a sensitive path and
# a rename OUT of one are each worth a hold.
# _mr_diff_paths <json> → one path per line, or rc 1 if the page cannot be READ.
#
# Separated out so "I could not parse this" is expressible at all. The inline
# version could only `break`, which the caller then saw as an empty page.
_mr_diff_paths(){
  if _mr_have_yq; then
    "$YQ" e -p=json -r '.[] | [.new_path, .old_path] | .[]' - <<<"$1" 2>/dev/null || return 1
    return 0
  fi
  # yq is ABSENT ON THE CI RUNNER, and this function is the gate's only source of
  # truth about which files an MR touches. Read with a bare "$YQ" it produced
  # nothing there, the loop broke, and the gate reported an empty change set —
  # i.e. "nothing sensitive" — for every MR in CI (ops#293, the ops#281 class).
  printf '%s' "$1" | python3 -c 'import json,sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(1)
if not isinstance(rows, list): sys.exit(1)
for r in rows:
    if not isinstance(r, dict): sys.exit(1)
    for k in ("new_path", "old_path"):
        v = r.get(k)
        if v: print(v)' || return 1
}

# _mr_changed_files <iid> → one repo-relative path per line.
# rc 0 = read successfully (may legitimately be empty) · 1 = COULD NOT READ.
#
# THE RETURN CODE IS THE POINT. This used to `return 0` unconditionally, so a
# page it could not parse and an MR with no files were the same answer: rc 0,
# no output. The caller reads empty output as "could not look" only because it
# separately knows an MR always has files — a coincidence, not a contract. Now
# an unreadable page fails, and the caller is told.
_mr_changed_files(){
  local iid="$1" proj json page=0 rows out="" rc=0
  proj=$(_mr_project) || return 1
  while :; do
    page=$((page + 1))
    json=$(_mr_get "/projects/$proj/merge_requests/$iid/diffs?per_page=100&page=$page") || return 1
    [ -n "$json" ] || break
    rows=$(_mr_diff_paths "$json") || { rc=1; break; }
    [ -n "$rows" ] || break
    out="${out}${rows}"$'\n'
    [ "$(printf '%s\n' "$rows" | grep -c .)" -lt 100 ] && break
    [ "$page" -ge 30 ] && break
  done
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out" | grep -v '^null$' | sort -u | grep -v '^$' || true
  return 0
}

# _mr_diff_ready <iid> — wait until GitLab has finished PREPARING the diff.
# rc 0 = ready · 1 = still not ready (or unreadable) within the timeout.
#
# WHY THIS EXISTS. GitLab computes an MR's diff asynchronously. For the first
# seconds after creation it reports detailed_merge_status=preparing, diff_refs
# null, and an EMPTY changeset. `pl mr create` ran the sensitive-path gate the
# instant after the POST, read that empty changeset, and concluded "could not
# look" — when the true answer was "not yet". Measured on !368: empty at
# creation, three files moments later, correct verdict from an unchanged gate.
#
# So CANNOT VERIFY was the normal outcome of creating an MR. Combined with a
# cannot-verify path that applied no hold, the gate was decoration on every new
# MR. Distinguishing "not yet" from "cannot" is the whole job.
#
# `checking` is included deliberately: CLAUDE.md's merge-automation rule is that
# checking means retry, not failure.
_mr_diff_ready(){
  local iid="$1" json st refs tries=0 max
  local timeout="${NWP_MR_DIFF_TIMEOUT:-60}" poll="${NWP_MR_DIFF_POLL:-3}"
  # Bounded by ATTEMPTS, not by elapsed time, so the tests can drive it with
  # poll=0 and no sleeping. A time-only bound made poll=0 mean "give up at once",
  # which is not the same knob at all.
  if [ "$poll" -gt 0 ]; then max=$(( timeout / poll + 1 )); else max=$(( timeout > 0 ? timeout : 1 )); fi
  while :; do
    tries=$((tries + 1))
    json=$(_mr_fetch "$iid" 2>/dev/null) || return 1
    st=$(printf '%s' "$json" | _mr_jget 'detailed_merge_status')
    refs=$(printf '%s' "$json" | _mr_jget 'diff_refs.base_sha')
    case "$st" in
      preparing|checking|unchecked|"") ;;
      *) [ -n "$refs" ] && return 0 ;;
    esac
    # Falling out is a REFUSAL, never a pass — "I ran out of patience" is not
    # "the diff is ready and empty".
    [ "$tries" -lt "$max" ] || return 1
    [ "$poll" -gt 0 ] && sleep "$poll"
  done
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
  # Via _mr_jget, which has the python fallback. Read with a raw "$YQ" this
  # returned EMPTY on the CI runner, so the hold CONFIRMATION step — the one that
  # decides between "HELD" and "HOLD-MECHANISM-FAILED" — answered "not draft" for
  # every MR there, including ones whose hold had just been applied successfully.
  # ops#281 fixed the write and left the read (ops#293).
  d=$(printf '%s' "$json" | _mr_jget 'draft')
  [ "$d" = "true" ] && return 0
  d=$(printf '%s' "$json" | _mr_jget 'work_in_progress')
  [ "$d" = "true" ]
}

_mr_title(){    printf '%s' "$1" | _mr_jget title; }
_mr_author(){   printf '%s' "$1" | _mr_jget 'author.username'; }

# _mr_token_user — the username the FORGE associates with our token.
# Empty + rc 1 when it cannot be established.
#
# WHY IT MATTERS. `--approved-by=<handle>` is a string the caller types; nothing
# checks that the caller IS that person. The gate compensates by refusing a
# release note whose Approved-By equals the MR author (see _mr_release_record),
# so an author cannot self-approve under their own name — but they could type
# somebody else's. The two-step flow's real backstop was that a HUMAN, whose
# identity the forge knows, finally clicked Merge.
#
# `--merge` removes that click, so it must put a forge-verified identity back in
# its place: the token's own user. That is checked, not asserted.
# ── REVIEW MODE ───────────────────────────────────────────────────────────────
#
# HOW MANY HUMANS REVIEW A CHANGE. One fact, one reader, and the fact is one the
# estate ALREADY declares.
#
# Operator ruling 2026-08-06: "The current system is just you and me... It should
# only be happening once I approve the shift and there is a second human dev in
# the system. Until then I should be able to approve/merge once and only in one
# spot which is the MR location."
#
# THE FACT IS `approvers:` IN THE SECRETS REGISTRY, not a new setting. That list
# already exists and cmd_release already keys the NWP-ADR-0028 Phase 1 dispensation
# off it, with the rationale spelled out there: "Keyed off a DECLARED FACT, never
# a date or a phase name: inert today, correct forever, and it arms without anyone
# remembering to arm it." Adding the second name IS the shift, and IS the second
# human dev existing — one act, in one place, no flag to remember.
#
# So this does NOT invent a second declaration. Inventing one is what the operator
# meant by "drift back into complexity": two places naming the same fact, free to
# disagree, with nothing noticing.
#
# WHY A TRACKED PROJECTION EXISTS ANYWAY. private/ is a SEPARATE repository, so CI
# cannot read the registry at all — which is why that existing check silently does
# nothing in a pipeline. The sensitive-path gate runs IN CI and must know the mode.
# `.nwp-review-mode` is therefore a generated, tracked PROJECTION of the count, not
# an independent switch:
#
#     registry `approvers:`  ── truth, human-edited, private repo
#              │
#              └─ pl mr review-mode sync ──► .nwp-review-mode  ── tracked, CI reads this
#
# The registry WINS wherever it is readable, so the projection can never quietly
# override the truth; it is only consulted when the truth is out of reach. A
# pre-commit hook refuses to commit a projection that disagrees, so the two cannot
# drift apart unnoticed — drift is DETECTED, not assumed away.
#
# FAIL-CLOSED, AND NOTE THE DIRECTION. Nothing readable at all reads as `team`, the
# STRICTER mode. The tempting default is today's, but then a typo or a bad checkout
# silently switches the estate to single-approval — the permissive direction. This
# nearly bit for real: .nwp-review-mode was silently gitignored on first writing
# (the root .gitignore denies /*), so it would have been present locally and absent
# in CI. Because the fallback is `team`, that mistake would have shown up as CI
# holding everything — annoying and visible — rather than as two-person review
# silently switched off in the pipeline.

# _mr_review_mode_file — the CI-readable projection. Resolved when CALLED: a value
# computed at source time cannot be overridden by a caller later, which is exactly
# the trap that made the yq-less suites run WITH yq for months (ops#293).
_mr_review_mode_file(){ printf '%s' "${NWP_REVIEW_MODE_FILE:-$PROJECT_ROOT/.nwp-review-mode}"; }

# _mr_approver_registry — where the TRUTH lives.
_mr_approver_registry(){ printf '%s' "${NWP_SECRETS_REGISTRY:-$HOME/nwp/private/secrets-registry.yml}"; }

# _mr_approver_count — how many humans are declared able to approve.
# Prints the count and rc 0; rc 1 = could not read it (which is NOT "zero").
_mr_approver_count(){
  local f n
  f=$(_mr_approver_registry)
  [ -r "$f" ] || return 1
  if _mr_have_yq; then
    n=$("$YQ" e '.approvers // [] | length' "$f" 2>/dev/null)
  else
    # No yq: count list items under approvers: without one. Deliberately narrow —
    # a top-level `approvers:` block of `- name` lines, which is the shape in use.
    n=$(awk '
      /^approvers:[[:space:]]*$/ { inb=1; next }
      inb && /^[[:space:]]*-[[:space:]]*[^[:space:]]/ { c++; next }
      inb && /^[^[:space:]#]/ { inb=0 }
      END { print c+0 }' "$f" 2>/dev/null)
  fi
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$n"
}

# _mr_review_mode_raw — the projection's declared word, or empty.
_mr_review_mode_raw(){
  local f; f=$(_mr_review_mode_file)
  [ -r "$f" ] || return 0
  # First non-blank, non-comment line. The file is mostly rationale.
  grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | head -1 | tr -d '[:space:]'
}

# _mr_review_mode — THE ONLY function anything asks. solo | team.
#
# Precedence, and each step earns its place:
#   1. NWP_REVIEW_MODE   — so tests can drive both branches and CI can pin one
#   2. approvers: count  — the TRUTH; >1 human means two-person review
#   3. the projection    — only when the truth is unreachable (i.e. in CI)
#   4. team              — fail closed
_mr_review_mode(){
  if [ -n "${NWP_REVIEW_MODE:-}" ]; then
    case "$NWP_REVIEW_MODE" in solo) printf 'solo'; return 0 ;; team) printf 'team'; return 0 ;; esac
    printf 'team'; return 0
  fi
  local n
  if n=$(_mr_approver_count); then
    # 0 declared approvers is not "nobody reviews" — it is an unfinished registry,
    # so it must not read as solo.
    [ "$n" -eq 1 ] && { printf 'solo'; return 0; }
    printf 'team'; return 0
  fi
  case "$(_mr_review_mode_raw)" in
    solo) printf 'solo' ;;
    team) printf 'team' ;;
    *)    printf 'team' ;;
  esac
}

# _mr_review_mode_source — where the answer came from, so no caller has to guess
# and no report can present a fallback as somebody's decision.
# Prints: env | registry | projection | fallback
_mr_review_mode_source(){
  [ -n "${NWP_REVIEW_MODE:-}" ] && { printf 'env'; return 0; }
  _mr_approver_count >/dev/null 2>&1 && { printf 'registry'; return 0; }
  case "$(_mr_review_mode_raw)" in solo|team) printf 'projection'; return 0 ;; esac
  printf 'fallback'
}

# _mr_review_mode_is_declared — 0 when the mode was actually READ from somewhere,
# 1 when we fell back to team because we could not tell.
_mr_review_mode_is_declared(){
  [ "$(_mr_review_mode_source)" != fallback ]
}

# _mr_review_mode_drift — 0 when truth and projection agree (or truth is out of
# reach, in which case there is nothing to compare). 1 when they DISAGREE.
#
# This is the anti-drift mechanism, and it is a measurement rather than a hope:
# the pre-commit hook fails on it, so a projection that contradicts the registry
# cannot reach CI.
_mr_review_mode_drift(){
  local n want got
  n=$(_mr_approver_count) || return 0
  [ "$n" -eq 1 ] && want=solo || want=team
  got=$(_mr_review_mode_raw)
  case "$got" in solo|team) ;; *) return 1 ;; esac
  [ "$got" = "$want" ]
}

# _mr_merge_actor_ok — THE INVARIANT THAT HOLDS IN BOTH MODES:
#
#         A MACHINE NEVER MERGES. A HUMAN MERGES.
#
# Solo mode removes the SECOND human, not the human. The 2026-08-01 incident was
# a sweeper merging an MR no person had approved, and this is what keeps that
# fixed once the Draft hold is no longer doing it. Every verb that could merge
# calls this, in either mode.
#
# Keyed on the token's forge-verified identity, not on a typed handle or a name
# in a config. rc 0 = a human may merge · 1 = a bot, refuse · 2 = could not tell.
_mr_merge_actor_ok(){
  local u
  u=$(_mr_token_user) || return 2
  _mr_handle_is_bot "$u" && return 1
  return 0
}

_mr_token_user(){
  local json
  json=$(_mr_get "/user") || return 1
  local u; u=$(printf '%s' "$json" | _mr_jget 'username')
  [ -n "$u" ] || return 1
  printf '%s' "$u"
}
_mr_head_sha(){ printf '%s' "$1" | _mr_jget sha; }
_mr_state(){    printf '%s' "$1" | _mr_jget state; }
_mr_detailed_merge_status(){ printf '%s' "$1" | _mr_jget detailed_merge_status; }
_mr_head_pipeline_id(){ printf '%s' "$1" | _mr_jget 'head_pipeline.id'; }

# _mr_pipeline <pipeline-id> → the pipeline JSON, or rc 1.
_mr_pipeline(){
  local pid="$1" proj
  proj=$(_mr_project) || return 1
  _mr_api GET "/projects/$proj/pipelines/${pid}"
}

# _mr_pipeline_ref_iid <pipeline-json> → the MR iid a pipeline belongs to, or
# nothing.
#
# WHY THIS EXISTS. A human reports a NUMBER — "pipeline #2254 failed" — and
# nothing in the estate could turn that number into a branch. A merge_request
# pipeline's `ref` is `refs/merge-requests/<iid>/head`, so the mapping is right
# there in the object; without it the only route was a hand-rolled curl loop,
# which is the shape the pl-first standing order exists to retire.
_mr_pipeline_ref_iid(){
  local ref; ref=$(printf '%s' "$1" | _mr_jget ref)
  case "$ref" in
    refs/merge-requests/*/head) ref="${ref#refs/merge-requests/}"; printf '%s' "${ref%/head}" ;;
    *) return 1 ;;
  esac
}

# _mr_pipeline_jobs <pipeline-id> → "<id>\t<status>\t<stage>\t<name>\t<allow_failure>"
# per job, in the API's order. Unlike _mr_failed_jobs this reports EVERY job:
# reading a pipeline means seeing the skipped and canceled ones too, because
# "the whole test stage was skipped" is the answer surprisingly often.
_mr_pipeline_jobs(){
  local pid="$1" proj json
  proj=$(_mr_project) || return 1
  json=$(_mr_api GET "/projects/$proj/pipelines/${pid}/jobs?per_page=100") || return 1
  # python3 only, deliberately: yq's -r + string concatenation needs the
  # strenv(TAB) dance documented below, and this producer has five fields
  # rather than two. One implementation that behaves identically on every host
  # beats two that agree until a yq version moves.
  printf '%s' "$json" | python3 -c 'import json,sys
try: jobs=json.load(sys.stdin)
except Exception: sys.exit(1)
if not isinstance(jobs, list): sys.exit(1)
for j in jobs:
    print("\t".join([str(j.get("id","")), str(j.get("status","")),
                     str(j.get("stage","")), str(j.get("name","")),
                     "true" if j.get("allow_failure") else "false"]))'
}

# _mr_job_trace <job-id> [<tail-lines>] → the END of one job log.
#
# Clamped like `pl logs` is clamped: a trace can be megabytes, and the answer to
# "why did this go red" is almost always in the last screenful. ANSI escapes and
# GitLab's section markers are stripped so the output is readable in a terminal
# that is not a browser.
_mr_job_trace(){
  local jid="$1" tail_n="${2:-40}" proj raw
  proj=$(_mr_project) || return 1
  raw=$(_mr_api GET "/projects/$proj/jobs/${jid}/trace") || return 1
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw" \
    | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/section_\(start\|end\):[0-9]*:[a-z_]*//g' \
    | grep -v '^[[:space:]]*$' \
    | tail -n "$tail_n"
}

# _mr_failed_jobs <pipeline-id> → "<job-id>\t<job-name>" per FAILED job.
#
# Only `failed` counts. `canceled`, `skipped` and an allow_failure job that went
# red are not what blocks a merge, and treating them as failures here would let
# the retry path below fire on jobs it has no business touching.
_mr_failed_jobs(){
  local pid="$1" proj json
  proj=$(_mr_project) || return 1
  json=$(_mr_api GET "/projects/$proj/pipelines/${pid}/jobs?per_page=100") || return 1
  if _mr_have_yq; then
    # strenv(TAB), NOT "\t". yq only began expanding "\t" to a real tab after
    # v4.44.1, which is the version ensure-yq.sh pins onto the runners. The
    # workstation has v4.50.1, so the "\t" spelling produced a real tab here
    # and the two characters `\t` there: `awk -F'\t'` then found no separator,
    # the job-name list came back EMPTY, and the merge verb refused with no
    # names. Three cases green on this machine, red only in CI (pipeline 1866).
    # Measured against the pinned binary, not assumed. Same trap already
    # documented in monitor.sh, lib/pair.sh and lib/gitlab-issues.sh.
    printf '%s' "$json" | TAB=$'\t' "$YQ" e -p=json -r \
      '.[] | select(.status == "failed") | select(.allow_failure == false) | (.id|tostring) + strenv(TAB) + .name' - 2>/dev/null
  else
    printf '%s' "$json" | python3 -c 'import json,sys
try: jobs=json.load(sys.stdin)
except Exception: sys.exit(1)
for j in jobs:
    if j.get("status")=="failed" and not j.get("allow_failure", False):
        print("%s\t%s" % (j["id"], j["name"]))'
  fi
}

# _mr_retry_job <job-id> → re-run one job. rc 0 on an accepted retry.
_mr_retry_job(){
  local jid="$1" proj
  proj=$(_mr_project) || return 1
  _mr_api POST "/projects/$proj/jobs/${jid}/retry" >/dev/null || return 1
  return 0
}

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
  # NOT yq: $YQ is EMPTY on the CI runner, so this silently returned no labels
  # and every hold-label check answered "not held" there (the ops#281 class,
  # found while building the release guard). python3 is always present.
  labels=$(printf '%s' "$1" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
print(",".join(d.get("labels") or []))' 2>/dev/null)
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

# _mr_disarm_automerge <iid> — cancel any armed merge_when_pipeline_succeeds.
#
# ONE IMPLEMENTATION, called by the Draft hold and by solo mode alike. This is
# the half of the 2026-08-01 fix that matters in EVERY review mode: the incident
# was a sweeper arming auto-merge and the MR merging itself the moment CI went
# green. Solo mode drops the Draft (it would cost the operator a second click)
# but must never drop this.
#
# A 404 means it was not armed, which is the desired end state, so it is not an
# error.
_mr_disarm_automerge(){
  local iid="$1" proj
  proj=$(_mr_project) || return 1
  _mr_api DELETE "/projects/$proj/merge_requests/$iid/merge_when_pipeline_succeeds" >/dev/null 2>&1 || true
  return 0
}

# _mr_note_once <iid> <marker> <body> — post a note unless <marker> is already in
# the discussion. Extracted from _mr_apply_hold so solo mode reuses the
# idempotence rather than reimplementing it; a second copy is how one of them
# starts spamming an MR on every pipeline run.
_mr_note_once(){
  local iid="$1" marker="$2" body="$3" proj notes np
  proj=$(_mr_project) || return 1
  notes=$(_mr_notes "$iid" 2>/dev/null || true)
  printf '%s' "$notes" | grep -q "$marker" && return 0
  np=$(_mr_json body "$body")
  _mr_api POST "/projects/$proj/merge_requests/$iid/notes" "$np" >/dev/null || return 1
  return 0
}

MR_SOLO_MARKER="<!-- nwp:solo-review-sensitive-paths -->"

_mr_apply_hold(){
  local iid="$1" reason="${2:-}" label="${3:-$MR_HOLD_LABEL_MANUAL}" paths="${4:-}"
  local proj json title new_title payload
  proj=$(_mr_project) || return 1
  json=$(_mr_fetch "$iid") || return 1
  title=$(_mr_title "$json")

  # 1. disarm auto-merge
  _mr_disarm_automerge "$iid"

  # 2. draft
  new_title=$(_mr_draft_title "$title")
  payload=$(_mr_json title "$new_title" add_labels "$label")
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
    local np; np=$(_mr_json body "$body")
    _mr_api POST "/projects/$proj/merge_requests/$iid/notes" "$np" >/dev/null || true
  fi
  return 0
}

# _mr_lift_hold <iid> — undraft and drop the hold labels. Nothing else.
# _mr_retry_gate_job <iid>
# Re-run the sensitive-path hold job after a release, so the PIPELINE reflects
# the release.
#
# THE CATCH-22 THIS CLOSES. `pl mr release` recorded the approval and lifted the
# Draft, then printed "merging is still a human action". True — but the operator
# went to the MR and it still said blocked, because layer 2 of the hold is the
# gate job's own RED result, and a release does not re-run an already-finished
# job. So the MR was released and unmergeable at the same time, with nothing on
# screen explaining why. The operator asked, reasonably, whether there was a
# better way; there is, and it is this.
#
# Retrying is safe and is not self-approval: the job re-executes
# scripts/ci/sensitive-path-hold-gate.sh, which looks for a release record bound
# to the CURRENT head. If the release is real the gate passes on its own
# evidence; if it is not, the job goes red again. Nothing is asserted here that
# the gate does not re-verify.
#
# Emits the new job id on stdout. Returns 1 if there is nothing to retry (no
# pipeline, or no failed gate job) — which is not an error, and 2 if the retry
# call itself failed.
_mr_retry_gate_job(){
    local iid="$1" proj json pid jid
    proj=$(_mr_project) || return 1
    json=$(_mr_fetch "$iid") || return 1
    pid=$(printf '%s' "$json" | _mr_jget 'head_pipeline.id')
    [ -n "$pid" ] || return 1

    # Find the FAILED job whose name marks it as the hold gate. Matched on name
    # rather than position: the pipeline's job list is not ordered by contract.
    jid=$(_mr_api GET "/projects/$proj/pipelines/$pid/jobs?per_page=100" \
        | python3 -c 'import json,sys
try: js=json.load(sys.stdin)
except Exception: sys.exit(0)
for j in js if isinstance(js,list) else []:
    if j.get("status")=="failed" and "mr-hold" in (j.get("name") or ""):
        print(j.get("id")); break' 2>/dev/null)
    [ -n "$jid" ] || return 1

    _mr_api POST "/projects/$proj/jobs/$jid/retry" >/dev/null || return 2
    printf '%s\n' "$jid"
    return 0
}

# _mr_assert_project <iid> [<expected-project>]
# Refuse when the project resolved from the CURRENT DIRECTORY is not the one the
# caller meant.
#
# THE INCIDENT (2026-08-06). The operator ran `pl mr release 80` from ~/nwp to
# release nwp/nwc!80 (the php-lint fix). The verb resolves its project from the
# git remote of wherever it runs, so it targeted nwp/nwp!80 — a DIFFERENT,
# long-merged MR — and cheerfully posted a release note onto it. Every line of
# output said SUCCESS. The real MR stayed held, and the operator went looking at
# a page that said "already merged" and reasonably concluded the tooling was
# confused.
#
# MR numbering is PER PROJECT, so `!80` is ambiguous the moment more than one
# project is in play — and this estate has two that are worked on in the same
# breath (nwp/nwp and nwp/nwc). An ambiguous identifier that silently picks one
# is worse than one that asks.
#
# So a WRITE verb states which project it is about, out loud, before it writes.
# The check is cheap: the MR must exist in the resolved project AND its title
# must be non-empty. A 404 here means "you are in the wrong directory", which is
# a far more useful message than a success on the wrong MR.
#
# Returns 0 when the MR exists in the resolved project, 1 when it does not.
# The project as a HUMAN reads it — "nwp/nwc", not "nwp%2Fnwc". Printed before
# any write so the operator can see which project a verb is about without having
# to know that it is inferred from the current directory.
_mr_project_human(){
    local p
    p="$(_mr_project 2>/dev/null || true)"
    [ -n "$p" ] || { printf '(project unresolved)'; return 0; }
    printf '%s' "${p//%2F//}"
}

# The head pipeline's status, or "none". Deliberately a bare word so callers can
# case on it; an unreadable answer is "unknown", never "success".
_mr_pipeline_status(){
    local json st
    json=$(_mr_fetch "$1" 2>/dev/null) || { printf 'unknown'; return 0; }
    st=$(printf '%s' "$json" | _mr_jget 'head_pipeline.status')
    printf '%s' "${st:-none}"
}

# WHY EXISTENCE IS THE WRONG TEST — learned the hard way, twice.
# The first version asked "does !N exist in the resolved project?". It does: BOTH
# projects have an !80 and an !81. So the guard passed and the verb posted a
# release onto the wrong project's MR — reproducing, while under test, the exact
# bug it was written to prevent.
#
# The property that actually distinguishes them is SEMANTIC, not positional: a
# release only means anything on an MR that is currently HELD. A merged MR, a
# closed one, or an open one that was never held cannot be released — there is no
# hold to lift. Both misfires were against MERGED MRs, so this catches them
# whichever project the directory resolves to.
#
# Echoes a word describing what was found; returns 0 only for 'held'. The caller
# prints it, because "!80 here is a merged MR titled X" tells the operator they
# are in the wrong directory far better than a bare refusal.
_mr_assert_releasable(){
    local iid="$1" json state draft labels
    _mr_project >/dev/null 2>&1 || { printf 'unresolved'; return 1; }
    json=$(_mr_fetch "$iid" 2>/dev/null) || { printf 'missing'; return 1; }
    [ -n "$(_mr_title "$json")" ] || { printf 'missing'; return 1; }
    state=$(printf '%s' "$json" | _mr_jget 'state')
    [ "$state" = "opened" ] || { printf '%s' "$state"; return 1; }
    draft=$(printf '%s' "$json" | _mr_jget 'draft')
    # Held = Draft (layer 1) OR a hold label. Reuses the existing
    # _mr_has_hold_label rather than a second reader — a duplicate label parser is
    # how the two drift apart.
    if [ "$draft" = "true" ] || _mr_has_hold_label "$json"; then
        printf 'held'; return 0
    fi
    printf 'not-held'; return 1
}


_mr_lift_hold(){
  local iid="$1" proj json title new_title payload
  proj=$(_mr_project) || return 1
  json=$(_mr_fetch "$iid") || return 1
  title=$(_mr_title "$json")
  new_title=$(_mr_undraft_title "$title")
  payload=$(_mr_json title "$new_title" remove_labels "$MR_HOLD_LABEL_SENSITIVE,$MR_HOLD_LABEL_MANUAL")
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
  # rc 2 = COULD NOT LOOK (no token, API error). rc 1 = looked, found nothing.
  # Collapsing these was a real defect: a tokenless CI job reported "no release
  # record for this head" and told the operator to run `pl mr release`, which
  # could never help because the job could not read the note it would create.
  # A negative you could not verify is not a negative.
  notes=$(_mr_notes "$iid") || return 2
  # Notes come back newest-first; take the first that validates.
  #
  # The bodies are flattened into one stream with an explicit BOUNDARY between
  # them, and the boundary resets the parse. Without it, `Approved-By:` in one
  # note and `Commit:` in a completely different note would combine into a
  # release record that nobody ever wrote — a forgery assembled by accident out
  # of two innocent comments. A release must be one note, entire.
  local BOUNDARY='@@NWP-NOTE-BOUNDARY@@'
  bodies=$(_mr_note_bodies "$BOUNDARY" <<<"$notes") || return 2
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
