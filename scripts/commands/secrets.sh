#!/bin/bash
set -uo pipefail
################################################################################
# NWP Secrets Command (pl secrets)
#
# Registry-driven secret lifecycle. Values live in .secrets.yml; this command
# reads the TOKENLESS registry (private/secrets-registry.yml) for metadata and
# assists rotation WITHOUT ever storing a credential on this host (ADR-0017).
#
# Usage:
#   pl secrets status                 list every secret + expiry (no secret read)
#   pl secrets rotate <id|--due>      guided/assisted rotation; stamps expiry
#   pl secrets get <dotted.key>       value -> clipboard, never printed
#   pl secrets scan                   leak sweep over transcripts/logs/history
#   pl secrets check                  run the expiry check (same as in `pl todo`)
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"
# rotation-debt: the exposure/pending-rotation reader + the prod go-live gate
# (operator ruling D8). Shared with lib/deploy-gate.sh, lib/todo-checks.sh and
# pl canonical, so all four agree on what "a debt is open" means.
source "$PROJECT_ROOT/lib/rotation-debt.sh"

# The ESTATE root — the main checkout, not whichever worktree we happen to be
# running from. `.secrets.yml`, `private/` and the `sites/**/auth.json` copies
# live in exactly one place; the standing rule is to work in `pl issue work`
# worktrees, so resolving these against $PROJECT_ROOT made every relative
# stored_in path report MISSING inside a worktree and OK in the main checkout —
# a check whose answer depends on your current directory is not a check.
NWP_ROOT="${NWP_ROOT:-}"
if [ -z "$NWP_ROOT" ]; then
  NWP_ROOT="$PROJECT_ROOT"
  if _gcd=$(git -C "$PROJECT_ROOT" rev-parse --git-common-dir 2>/dev/null); then
    case "$_gcd" in /*) ;; *) _gcd="$PROJECT_ROOT/$_gcd" ;; esac
    _cand=$(cd "$(dirname "$_gcd")" 2>/dev/null && pwd) && [ -n "$_cand" ] && NWP_ROOT="$_cand"
  fi
  unset _gcd _cand
fi

REGISTRY="${NWP_SECRETS_REGISTRY:-$NWP_ROOT/private/secrets-registry.yml}"
SECRETS_FILE="${NWP_SECRETS_FILE:-$NWP_ROOT/.secrets.yml}"
ROT_LOG="$NWP_ROOT/private/rotation-$(date +%Y-%m).md"
YQ="$(command -v yq || true)"

die(){ print_error "$*"; exit 1; }
need_yq(){ [ -n "$YQ" ] || die "yq is required (https://github.com/mikefarah/yq)"; }
need_registry(){ [ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"; }

# index of an entry by id, or -1
registry_index_of(){
  local id="$1" n i rid
  n=$("$YQ" e '.secrets | length' "$REGISTRY" 2>/dev/null); [ "$n" = "null" ] && n=0
  for ((i=0;i<n;i++)); do
    rid=$("$YQ" e ".secrets[$i].id // \"\"" "$REGISTRY" 2>/dev/null)
    [ "$rid" = "$id" ] && { echo "$i"; return 0; }
  done
  echo "-1"
}

# The registry is committed to git, so it must never carry the operator's live
# domain (the leakage gate would — correctly — reject it). Hosts are written as
# the `<gitlab-host>` placeholder and expanded here from the secret store, which
# is exactly the pattern `pl issue` already uses.
expand_placeholders(){ # stdin/arg -> arg with <gitlab-host>/<gitlab-ip> resolved
  local s="$1" d
  case "$s" in *'<gitlab-'*) ;; *) printf '%s' "$s"; return 0;; esac
  # If a placeholder cannot be resolved, LEAVE IT IN. Substituting an empty
  # string would turn "https://<gitlab-host>/api/v4/user" into "https:///api/v4/…"
  # and a host= location into an empty hostname — both fail, but as a confusing
  # transport error rather than as "this placeholder is not configured".
  case "$s" in *'<gitlab-host>'*)
    d=$("$YQ" e '.gitlab.server.domain // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
    case "$d" in ""|YOUR_*|CHANGEME*|"<"*) ;; *) s="${s//<gitlab-host>/$d}" ;; esac ;;
  esac
  # The forge's public IP is `operator-public-ip` to the leakage gate — the
  # highest-severity class the registry still carried after the host placeholders
  # went in. It is already in the secret store under gitlab.server.ip, so it can
  # be resolved exactly like the hostname rather than written out.
  # NOTE (measured 2026-07-27): .secrets.yml:gitlab.server.ip is still the unfilled
  # template value, so this placeholder cannot resolve yet. That is why the forge
  # IP is still written literally in the registry, and part of why the registry is
  # NOT committed to this repo — see the decision log.
  case "$s" in *'<gitlab-ip>'*)
    d=$("$YQ" e '.gitlab.server.ip // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
    case "$d" in ""|YOUR_*|CHANGEME*|"<"*) ;; *) s="${s//<gitlab-ip>/$d}" ;; esac ;;
  esac
  printf '%s' "$s"
}

field(){ expand_placeholders "$("$YQ" e ".secrets[$1].$2 // \"\"" "$REGISTRY" 2>/dev/null | grep -v '^null$')"; }

# raw (unexpanded) read — for writing back, and for grammar checks
field_raw(){ "$YQ" e ".secrets[$1].$2 // \"\"" "$REGISTRY" 2>/dev/null | grep -v '^null$'; }

entry_locations(){ # idx -> one stored_in string per line, placeholders expanded
  local loc
  while IFS= read -r loc; do
    [ -n "$loc" ] && expand_placeholders "$loc" && echo
  done < <("$YQ" e ".secrets[$1].stored_in[]?" "$REGISTRY" 2>/dev/null)
}

days_until(){ # ISO date -> integer days from now (empty/unknown -> "")
  local d="$1" e; [ -z "$d" ] || [ "$d" = "unknown" ] && return 0
  e=$(date -d "$d" +%s 2>/dev/null) || return 0
  echo $(( (e - $(date +%s)) / 86400 ))
}

################################################################################
# stored_in GRAMMAR  (item 1 — `secrets-registry-truth`)
#
# Every stored_in entry is ONE of:
#
#   <path>:<ref>                 a machine-checkable location on THIS host
#   host=<role>:<path>:<ref>     the same location on another host — checked by
#                                `pl secrets verify-copy` (hash over ssh), never
#                                read from here
#   external:<free text>         deliberately NOT machine-checkable (a CI
#                                variable, a provider-side store, a DB row)
#
#   <path>  absolute, ~/-relative, or relative to the repo root.
#           The literal `.secrets.yml` always means the active secret store.
#   <ref>   *.yml|*.yaml -> dotted yq key   ·   *.json -> jq path expression
#           `@file`      -> the whole file IS the value
#           otherwise    -> a VAR name in a KEY=VALUE env file
#
# Prose belongs in `stored_in_notes:` / `host:`, never inside a location.
# Anything that does not parse is a LINT ERROR — because a location the tooling
# cannot read is a location the tooling silently stops checking, which is the
# exact failure this whole item exists to remove.
################################################################################
loc_parse(){ # loc -> "kind<TAB>host<TAB>path<TAB>ref"; kind: yaml|json|env|file|external|bad
  local loc="$1" host="" rest="$1" path ref kind
  case "$loc" in
    external:*) printf 'external\x1f\x1f\x1f%s\n' "${loc#external:}"; return 0 ;;
    host=*)
      rest="${loc#host=}"; host="${rest%%:*}"; rest="${rest#*:}"
      if [ -z "$host" ] || [ "$host" = "$rest" ]; then printf 'bad\x1f\x1f\x1f%s\n' "$loc"; return 0; fi ;;
  esac
  case "$rest" in *:*) ;; *) printf 'bad\x1f\x1f\x1f%s\n' "$loc"; return 0 ;; esac
  path="${rest%%:*}"; ref="${rest#*:}"
  if [ -z "$path" ] || [ -z "$ref" ]; then printf 'bad\x1f\x1f\x1f%s\n' "$loc"; return 0; fi
  case "$path" in *[[:space:]]*) printf 'bad\x1f\x1f\x1f%s\n' "$loc"; return 0 ;; esac
  if [ "$ref" = "@file" ]; then
    kind=file
  else
    case "$path" in
      *.yml|*.yaml) kind=yaml ;;
      *.json)       kind=json ;;
      *)            kind=env  ;;
    esac
  fi
  # a yq key / env var name never contains whitespace; a jq path may not either
  case "$ref" in *[[:space:]]*) printf 'bad\x1f\x1f\x1f%s\n' "$loc"; return 0 ;; esac
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$kind" "$host" "$path" "$ref"
}

loc_abspath(){ # path -> absolute path on this host (relative = estate root)
  local p="$1"
  [ "$p" = ".secrets.yml" ] && { printf '%s' "$SECRETS_FILE"; return 0; }
  p="${p/#\~/$HOME}"
  case "$p" in /*) ;; *) p="$NWP_ROOT/$p" ;; esac
  printf '%s' "$p"
}

# Read the value at a location. rc: 0 ok · 3 file missing · 4 key absent/empty
# · 5 tool missing. The value goes to stdout and is only ever consumed by
# loc_hash / a probe — it is never printed.
loc_read(){ # kind abspath ref
  local kind="$1" f="$2" ref="$3" v=""
  [ -f "$f" ] || return 3
  case "$kind" in
    yaml) v=$("$YQ" e ".$ref // \"\"" "$f" 2>/dev/null) ;;
    json) command -v jq >/dev/null || return 5
          v=$(jq -r "($ref) // \"\"" "$f" 2>/dev/null) ;;
    env)  v=$(grep -E "^(export )?${ref}=" "$f" 2>/dev/null | head -1 | sed -E "s/^(export )?${ref}=//")
          v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}" ;;
    file) v=$(head -1 "$f" 2>/dev/null) ;;
    *)    return 5 ;;
  esac
  v="${v%"${v##*[![:space:]]}"}"   # rtrim
  if [ -z "$v" ] || [ "$v" = "null" ]; then return 4; fi
  printf '%s' "$v"
}

loc_hash(){ printf '%s' "$1" | sha256sum | cut -c1-16; }

# The SHA-256 of the empty string. A remote read that finds nothing hashes to
# exactly this, so treating it as a value turns "the file is not there" into a
# confident-looking digest. Every remote comparison must reject it explicitly.
readonly HASH_OF_NOTHING_16="e3b0c44298fc1c14"
readonly HASH_OF_NOTHING_64="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
loc_is_empty_hash(){ case "$1" in "$HASH_OF_NOTHING_16"*|"$HASH_OF_NOTHING_64") return 0;; *) return 1;; esac; }

# Render a registry path for use inside a SINGLE-QUOTED remote shell word.
# A leading "~/" must become "$HOME/" *outside* the quotes, because the remote
# shell does not expand a tilde inside single quotes: `head -1 '~/.config/x'`
# looks for a directory literally named "~". Every remote location in this
# registry is written with a tilde, so verify-copy compared the hash of nothing
# against canonical and reported permanent DRIFT on copies that were identical.
loc_remote_quoted(){ # path -> shell-safe remote expression
  case "$1" in
    "~/"*) printf '"$HOME"/%s' "$(printf '%s' "${1#\~/}" | sed "s/'/'\\\\''/g")" ;;
    *)     printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
  esac
}

# The canonical location of an entry: its `canonical:` field if set, else the
# first `.secrets.yml:` location, else the first machine-readable local one.
entry_canonical_loc(){ # idx
  local idx="$1" c loc kind host
  c=$(field "$idx" canonical); [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  while IFS= read -r loc; do
    [ -z "$loc" ] && continue
    case "$loc" in .secrets.yml:*) printf '%s' "$loc"; return 0 ;; esac
  done < <(entry_locations "$idx")
  while IFS= read -r loc; do
    [ -z "$loc" ] && continue
    IFS=$'\x1f' read -r kind host _ _ < <(loc_parse "$loc")
    if [ -n "$host" ] || [ "$kind" = "external" ] || [ "$kind" = "bad" ]; then continue; fi
    printf '%s' "$loc"; return 0
  done < <(entry_locations "$idx")
  printf ''
}

################################################################################
# leak surfaces — ONE definition, shared by `scan` and `scrub`.
# They diverged once (scrub omitted logs/, the single surface scan reported
# in-repo), so the sets are now the same function and a test asserts it.
################################################################################
_leak_surfaces(){
  if [ -n "${NWP_LEAK_SURFACES:-}" ]; then
    printf '%s\n' "${NWP_LEAK_SURFACES//:/$'\n'}"
    return 0
  fi
  printf '%s\n' \
    "$HOME/.claude/projects" \
    "$HOME/.claude/prompts.log" \
    "$HOME/.bash_history" \
    "$HOME/.config" \
    "$NWP_ROOT/private" \
    "$NWP_ROOT/logs" \
    "/tmp"
}

################################################################################
# status
################################################################################
cmd_status(){
  need_yq; need_registry
  print_header "Secret registry — $REGISTRY"
  printf "  %-3s %-24s %-7s %-7s %-12s %-12s\n" "#" "ID" "VIA" "DAYS" "EXPIRES" "ROTATED"
  printf "  %-3s %-24s %-7s %-7s %-12s %-12s\n" "---" "------------------------" "-------" "-------" "------------" "------------"
  local n i; n=$("$YQ" e '.secrets | length' "$REGISTRY"); [ "$n" = "null" ] && n=0
  for ((i=0;i<n;i++)); do
    local id via exp d rot dtxt col st
    id=$(field "$i" id); via=$(field "$i" rotate_via); exp=$(field "$i" expires)
    rot=$(field "$i" last_rotated); [ -z "$rot" ] && rot="—"
    st=$(field "$i" status)
    if [ "$st" = "not-provisioned" ]; then dtxt="·"; col="$DIM"; exp="not-prov"; rot="—"
    elif [ -z "$exp" ] || [ "$exp" = "unknown" ]; then dtxt="-"; col="$DIM"; exp="unknown"
    else
      d=$(days_until "$exp"); dtxt="$d"
      if   [ "${d:-0}" -lt 0 ]   2>/dev/null; then col="$RED";    dtxt="EXPIRED"
      elif [ "${d:-0}" -le 3 ]   2>/dev/null; then col="$RED"
      elif [ "${d:-0}" -le 14 ]  2>/dev/null; then col="$YELLOW"
      else col="$GREEN"; fi
    fi
    # A credential can be perfectly in-date and still owe a rotation because its
    # value was SEEN. That fact belongs on the same line as the expiry, or the
    # table quietly reports a green row for a burnt token.
    local dbt=""
    [ "$("$YQ" e ".secrets[$i].exposure // [] | map(select((.rotated // false) != true)) | length" "$REGISTRY" 2>/dev/null)" != "0" ] \
      && dbt=" ${RED}EXPOSED — rotation OWED${NC}"
    printf "  ${BOLD}%-3s${NC} ${col}%-24s${NC} %-7s ${col}%-7s${NC} %-12s %-12s%b\n" "$((i+1))" "$id" "$via" "$dtxt" "$exp" "$rot" "$dbt"
  done
  echo
  print_info "ROTATED '—' = not recorded here yet (the registry only knows what you tell it)."
  print_hint "Guided rotate: pl secrets rotate <#|id>   ·   Record one you did by hand: pl secrets done <#|id> [YYYY-MM-DD]"
  local ndebt; ndebt=$(rotation_debt_count 2>/dev/null || echo 0)
  if [ "${ndebt:-0}" -gt 0 ] 2>/dev/null; then
    echo
    print_error "$ndebt open rotation DEBT record(s) — these block a prod bring-up (ruling D8)."
    print_hint "detail: pl secrets debt   ·   record one: pl secrets expose <id> --reason='…'"
  fi
}

################################################################################
# get — value to clipboard, never to stdout
################################################################################
clip_copy(){ # reads value on stdin
  if command -v wl-copy >/dev/null; then wl-copy
  elif command -v xclip >/dev/null; then xclip -selection clipboard
  elif command -v xsel  >/dev/null; then xsel --clipboard --input
  else return 1; fi
}
cmd_get(){
  need_yq
  local key="${1:-}"; [ -n "$key" ] || die "usage: pl secrets get <dotted.key>   e.g. gitlab.api_token"
  [ -f "$SECRETS_FILE" ] || die "no .secrets.yml"
  local val; val=$("$YQ" e ".$key // \"\"" "$SECRETS_FILE" 2>/dev/null)
  [ -z "$val" ] || [ "$val" = "null" ] && die "key not found or empty: $key"
  if printf '%s' "$val" | clip_copy; then
    print_success "copied $key to clipboard (cleared in 45s — never printed, never logged)"
    ( sleep 45; printf '' | clip_copy 2>/dev/null ) >/dev/null 2>&1 &
  else
    die "no clipboard tool (install wl-clipboard or xclip). Refusing to print the value."
  fi
}

################################################################################
# rotate
################################################################################
# Write NWP_NEWVAL to ONE declared location.
#
# The path is resolved by exactly the same two helpers the READER uses —
# `loc_parse` then `loc_abspath`. It used to do its own ad-hoc path handling
# (`~` expansion and nothing else), so every RELATIVE location resolved against
# the caller's working directory instead of the estate root. `pl` is on $PATH
# and the project's standing rule is to work inside a `pl issue work` worktree,
# so the working directory is essentially never the estate root: on the live
# registry that mis-resolved 48 of the 49 declared copies of the composer
# registry token — including the canonical `.secrets.yml` itself.
#
# A writer and a reader that disagree about where a value lives is the same
# defect class as an audit that checks one location out of forty-nine: the
# command reports on something other than the thing it claims to report on.
# There is now exactly one resolver, so `audit`, `sync`, `done` and `rotate`
# cannot disagree.
#
# rc: 0 written · 1 skipped BY DESIGN (external / another host) · 2 FAILED
write_value_to_location(){ # $1=location; value in env NWP_NEWVAL
  local loc="$1" kind host path ref f jtmp
  IFS=$'\x1f' read -r kind host path ref < <(loc_parse "$loc")

  case "$kind" in
    external) print_info    "  SKIP     $loc  (declared unverifiable)"; return 1 ;;
    bad)      print_error   "  BAD      $loc  (unparseable — see: pl secrets migrate-registry)"; return 2 ;;
  esac
  if [ -n "$host" ]; then
    print_info "  REMOTE   $loc  (on $host — propagate there, verify with: pl secrets verify-copy)"
    return 1
  fi

  f=$(loc_abspath "$path")
  [ -f "$f" ] || { print_error "  MISSING  $loc  -> $f"; return 2; }

  case "$kind" in
    yaml)
      NWP_NEWVAL="$NWP_NEWVAL" "$YQ" e -i ".$ref = strenv(NWP_NEWVAL)" "$f" \
        && { print_success "  WROTE    $loc"; return 0; } \
        || { print_error   "  FAILED   $loc  (yq write)"; return 2; } ;;
    json)
      command -v jq >/dev/null || { print_error "  FAILED   $loc  (jq not installed)"; return 2; }
      jtmp=$(mktemp)
      if jq --arg v "$NWP_NEWVAL" "$ref = \$v" "$f" > "$jtmp" 2>/dev/null && [ -s "$jtmp" ]; then
        chmod --reference="$f" "$jtmp" 2>/dev/null || chmod 600 "$jtmp"
        mv "$jtmp" "$f" && { print_success "  WROTE    $loc"; return 0; }
      fi
      rm -f "$jtmp"; print_error "  FAILED   $loc  (jq write)"; return 2 ;;
    env)
      # NOTE: this expression used to read `($1//"")`, which perl tokenises as an
      # empty match `//` rather than defined-or — it aborted with a compile error
      # on EVERY invocation, so `pl secrets rotate` never once wrote an env-style
      # location. That is the mechanical reason `~/.nwp-agent-loop.env:GITLAB_TOKEN`
      # drifted away from canonical while the registry recorded a clean rotation.
      if grep -qE "^(export )?$ref=" "$f"; then
        NWP_REF="$ref" NWP_NEWVAL="$NWP_NEWVAL" perl -i -pe \
          's/^(export\s+)?\Q$ENV{NWP_REF}\E=.*/(defined($1) ? $1 : "") . "$ENV{NWP_REF}=\"$ENV{NWP_NEWVAL}\""/e' "$f" \
          && { print_success "  WROTE    $loc"; return 0; } \
          || { print_error   "  FAILED   $loc  (perl write)"; return 2; }
      fi
      # The variable is not in the file. Declaring a location and then not
      # writing it is how the estate drifted; append it rather than "skip".
      printf '%s="%s"\n' "$ref" "$NWP_NEWVAL" >> "$f" \
        && { print_success "  WROTE    $loc  (appended — var was absent)"; return 0; } \
        || { print_error   "  FAILED   $loc  (append)"; return 2; } ;;
    file)
      # `@file`: the whole file IS the value.
      jtmp=$(mktemp)
      printf '%s\n' "$NWP_NEWVAL" > "$jtmp" \
        && chmod --reference="$f" "$jtmp" 2>/dev/null || chmod 600 "$jtmp"
      mv "$jtmp" "$f" && { print_success "  WROTE    $loc"; return 0; }
      rm -f "$jtmp"; print_error "  FAILED   $loc  (file write)"; return 2 ;;
  esac
  print_error "  FAILED   $loc  (no writer for kind '$kind')"; return 2
}

# Write NWP_NEWVAL to every declared location of an entry and REPORT HONESTLY.
# Sets WAL_WROTE / WAL_SKIPPED / WAL_FAILED / WAL_TOTAL and prints one row per
# location. rc 0 only when nothing failed.
WAL_WROTE=0; WAL_SKIPPED=0; WAL_FAILED=0; WAL_TOTAL=0
write_all_locations(){ # $1=idx
  local idx="$1" loc
  WAL_WROTE=0; WAL_SKIPPED=0; WAL_FAILED=0; WAL_TOTAL=0
  print_info "  propagating to every declared location:"
  while IFS= read -r loc; do
    [ -z "$loc" ] && continue
    WAL_TOTAL=$((WAL_TOTAL+1))
    write_value_to_location "$loc"
    case $? in
      0) WAL_WROTE=$((WAL_WROTE+1)) ;;
      1) WAL_SKIPPED=$((WAL_SKIPPED+1)) ;;
      *) WAL_FAILED=$((WAL_FAILED+1)) ;;
    esac
  done < <(entry_locations "$idx")
  printf "  %d/%d written · %d skipped by design · %d FAILED\n" \
    "$WAL_WROTE" "$WAL_TOTAL" "$WAL_SKIPPED" "$WAL_FAILED"
  [ "$WAL_FAILED" -eq 0 ]
}

stamp_registry(){ # $1=idx $2=expires-date
  local idx="$1" exp="$2" today; today=$(date +%F)
  "$YQ" e -i ".secrets[$idx].last_rotated = \"$today\" | .secrets[$idx].expires = \"$exp\"" "$REGISTRY"
}

log_rotation(){ # $1=id $2=expires $3=optional marker (e.g. PARTIAL)
  [ -f "$ROT_LOG" ] || printf '# Credential rotation — %s\n\nDates only; never paste values.\n\n' "$(date +%Y-%m)" > "$ROT_LOG"
  printf -- "- [x] %s — rotated %s, next expiry %s%s\n" \
    "$1" "$(date +%F)" "$2" "${3:+ — $3}" >> "$ROT_LOG"
}

rotate_one(){
  local arg="$1" id idx
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    [ "$arg" -ge 1 ] || { print_error "number must be >= 1"; return 1; }
    idx=$((arg-1)); id=$(field "$idx" id)
    [ -z "$id" ] && { print_error "no secret #$arg (see: pl secrets status)"; return 1; }
  else
    id="$arg"; idx=$(registry_index_of "$id")
    [ "$idx" = "-1" ] && { print_error "unknown id: $id"; return 1; }
  fi
  local via url cmd cadence prov typ
  via=$(field "$idx" rotate_via); url=$(field "$idx" rotate_url); cmd=$(field "$idx" rotate_cmd)
  cadence=$(field "$idx" cadence_days); prov=$(field "$idx" provider); typ=$(field "$idx" type)
  [ -z "$cadence" ] && cadence=90

  print_header "Rotate: $id"
  echo "  provider: $prov   type: $typ   via: $via"
  "$YQ" e ".secrets[$idx].stored_in[]" "$REGISTRY" 2>/dev/null | sed 's/^/  stored in: /'
  [ -n "$url" ] && echo "  page: $url"
  echo

  case "$via" in
    manual)
      [ -n "$url" ] && command -v xdg-open >/dev/null && (xdg-open "$url" >/dev/null 2>&1 &)
      print_info "1) Create the new credential at the page above (match the scopes shown in the registry)."
      print_info "2) Paste it below — input is hidden, never echoed, never logged."
      ;;
    cli)
      print_info "Running local helper: ${cmd:-<none>}"
      run_cli_helper "$id" "$cmd"
      # cli helpers set the credential at the source; may still need a stored_in update:
      print_info "If the new value must also live in .secrets.yml, paste it below (hidden); else press Enter to skip."
      ;;
    api)
      print_info "API-assisted rotation for $id."
      print_warning "Per policy no token is stored here — you'll paste a ONE-TIME credential, used in memory then discarded."
      api_rotate "$id" "$idx" "$prov" && { post_rotate "$idx" "$id" "$cadence"; return 0; }
      print_info "Falling back to manual: create the token at $url and paste it below (hidden)."
      ;;
    *) print_warning "unknown rotate_via '$via' — treating as manual" ;;
  esac

  # hidden capture of the new value, write to EVERY stored_in
  local NWP_NEWVAL="" partial=""
  read -r -s -p "  new value (hidden, Enter to skip write): " NWP_NEWVAL </dev/tty; echo
  if [ -n "$NWP_NEWVAL" ]; then
    export NWP_NEWVAL
    write_all_locations "$idx"; local wrc=$?
    unset NWP_NEWVAL
    if [ "$wrc" -ne 0 ]; then
      # A rotation that reached 1 of 49 locations is a FAILED rotation. Stamping
      # `last_rotated` here is what let the registry assert a clean rotation over
      # 47 copies of the previous token — the record said "done" and the estate
      # said otherwise, which is the exact failure this command exists to prevent.
      print_error "$id: $WAL_FAILED of $WAL_TOTAL declared location(s) were NOT written."
      if [ "$FORCE_ROTATE" != 1 ]; then
        print_error "  NOT stamping the registry and NOT logging a rotation."
        print_hint  "  fix the locations above, then:  pl secrets sync $id && pl secrets done $id"
        print_hint  "  or, if the partial state is genuinely intended:  pl secrets rotate $id --force"
        return 1
      fi
      print_warning "  --force given: recording a PARTIAL rotation."
      partial="PARTIAL ($WAL_FAILED/$WAL_TOTAL location(s) not written)"
    fi
  else
    print_warning "  no value pasted — assuming you updated it elsewhere; verifying the estate agrees."
    local drifted; drifted=$(entry_locations_in_sync "$idx" 2>&1 >/dev/null)
    if [ -n "$drifted" ]; then
      print_error "$id: these declared locations do NOT hold the canonical value:"
      printf '    %s\n' $drifted
      if [ "$FORCE_ROTATE" != 1 ]; then
        print_error "  NOT stamping the registry and NOT logging a rotation."
        print_hint  "  propagate first:  pl secrets sync $id"
        return 1
      fi
      print_warning "  --force given: recording a PARTIAL rotation."
      partial="PARTIAL (declared copies still drifted)"
    fi
  fi
  post_rotate "$idx" "$id" "$cadence" "$partial"
}

# SAME GATE AS `done`: a half-propagated rotation is a failed rotation and must
# read as one. This branch wrote that gate INSIDE post_rotate; main has since
# landed it in the CALLER (rotate_one, above), where it also understands
# `--force` and records the result as an explicit PARTIAL rather than refusing
# outright. Main's placement is kept — duplicating the check here would re-refuse
# exactly the `--force` path main added, so the gate would be unoverridable by
# the flag built to override it.
post_rotate(){ # idx id cadence [partial-marker]
  local idx="$1" id="$2" cadence="$3" partial="${4:-}" def exp
  def=$(date -d "+${cadence} days" +%F 2>/dev/null)
  read -r -p "  new expiry date [default $def]: " exp </dev/tty
  [ -z "$exp" ] && exp="$def"
  stamp_registry "$idx" "$exp"
  # A rotation is the ONLY thing that discharges a recorded exposure (D8). It
  # happens here, after the same propagation gate that guards `last_rotated`, so
  # the debt can never be cleared by a rotation this command refused to stamp.
  # A PARTIAL rotation leaves the debt standing: some copy still holds the value
  # that was seen.
  local cleared=""
  if [ -z "$partial" ]; then cleared=$(exposure_discharge "$idx" "$(date +%F)"); fi
  log_rotation "$id" "$exp" "${partial:-${cleared:+cleared exposure debt: $cleared}}"
  if [ -n "$partial" ]; then
    print_warning "rotated $id — expiry recorded $exp, logged as $partial"
  else
    print_success "rotated $id — expiry recorded $exp (logged to ${ROT_LOG##*/})"
  fi
}

run_cli_helper(){ # id cmd
  local id="$1" cmd="$2"
  case "$cmd" in
    ss-admin-reset)   [ -x "$PROJECT_ROOT/scripts/ss-admin-reset.sh" ] && "$PROJECT_ROOT/scripts/ss-admin-reset.sh" || print_warning "scripts/ss-admin-reset.sh not found/executable" ;;
    drush-user-password) print_info "Run on the target: drush user:password <admin> --password=… (set via hidden prompt on the server)" ;;
    *) print_warning "no built-in helper for '$cmd' — rotate manually" ;;
  esac
}

api_rotate(){ # id idx provider  -> 0 on success
  local id="$1" idx="$2" prov="$3"
  case "$prov" in
    gitlab)
      local host onetime tokid pid newtok defhost
      defhost=$("$YQ" e '.gitlab.server.domain // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
      read -r -p "  GitLab host${defhost:+ [$defhost]}: " host </dev/tty; host="${host:-$defhost}"
      [ -n "$host" ] || { print_error "no GitLab host given (and none in .secrets.yml gitlab.server.domain)"; return 1; }
      read -r -s -p "  one-time owner/admin token (api scope, NOT stored): " onetime </dev/tty; echo
      [ -z "$onetime" ] && return 1
      read -r -p "  project/group path or numeric id (blank = personal self-rotate): " pid </dev/tty
      if [ -z "$pid" ]; then
        newtok=$(curl -fsS --request POST --header "PRIVATE-TOKEN: $onetime" \
          "https://$host/api/v4/personal_access_tokens/self/rotate" 2>/dev/null | "$YQ" e '.token // ""' -p=json 2>/dev/null)
      else
        read -r -p "  access-token numeric id to rotate: " tokid </dev/tty
        local enc; enc=$(printf '%s' "$pid" | sed 's:/:%2F:g')
        newtok=$(curl -fsS --request POST --header "PRIVATE-TOKEN: $onetime" \
          "https://$host/api/v4/projects/$enc/access_tokens/$tokid/rotate" 2>/dev/null | "$YQ" e '.token // ""' -p=json 2>/dev/null)
      fi
      unset onetime
      [ -z "$newtok" ] || [ "$newtok" = "null" ] && { print_error "  rotation API returned no token"; return 1; }
      export NWP_NEWVAL="$newtok"; newtok=""
      write_all_locations "$idx"; local wrc=$?
      unset NWP_NEWVAL
      if [ "$wrc" -ne 0 ]; then
        # The credential at the PROVIDER has already changed; the old one is
        # dead. Saying so is the whole point — a half-propagated API rotation is
        # the one case where silence actually breaks the estate.
        print_error "  GitLab issued a NEW token but $WAL_FAILED of $WAL_TOTAL declared location(s) still hold the OLD one."
        print_hint  "  the previous value is now invalid — repair before anything runs: pl secrets sync $id"
        return 1
      fi
      print_success "  GitLab token rotated via API (one-time credential discarded)"
      return 0 ;;
    *) return 1 ;;
  esac
}

################################################################################
# rotate --dry-run — the preflight. Answers "if I rotated this right now, would
#   the stamp be honest?" WITHOUT prompting for a value and without writing a
#   byte. Safe to run from CI and from `pl todo`; that is the point.
################################################################################
rotate_dry_run(){ # id-or-#
  local arg="$1" idx id
  if [[ "$arg" =~ ^[0-9]+$ ]]; then idx=$((arg-1)); else idx=$(registry_index_of "$arg"); fi
  { [ "$idx" = "-1" ] || [ -z "$(field "$idx" id)" ]; } && { print_error "no such secret: $arg"; return 1; }
  id=$(field "$idx" id)
  print_header "Rotate (dry-run): $id — nothing will be written"
  "$YQ" e ".secrets[$idx].stored_in[]" "$REGISTRY" 2>/dev/null | sed 's/^/  stored in: /'
  local drifted; drifted=$(entry_locations_in_sync "$idx" 2>&1 >/dev/null)
  if [ -n "$drifted" ]; then
    print_error "$id: refusing to stamp — these declared locations do NOT hold the canonical value:"
    printf '    %s\n' $drifted
    print_hint "propagate first:  pl secrets sync $id"
    return 1
  fi
  print_success "$id: every declared location agrees — a rotation here would stamp honestly"
  return 0
}

FORCE_ROTATE=0
cmd_rotate(){
  need_yq; need_registry
  # --dry-run (this branch) and --force (main) may appear on either side of the
  # target, so both are parsed in one pass rather than by position.
  local target="" DRY=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run|-n) DRY=1 ;;
      --force)      FORCE_ROTATE=1 ;;
      -*)           [ -z "$target" ] && target="$a" ;;   # --due / --all
      *)            [ -z "$target" ] && target="$a" ;;
    esac
  done
  [ -n "$target" ] || die "usage: pl secrets rotate <id|--due|--all> [--dry-run] [--force]"
  local rc=0
  if [ "$DRY" = 1 ]; then
    local n i id
    if [ "$target" = "--due" ] || [ "$target" = "--all" ]; then
      n=$("$YQ" e '.secrets | length' "$REGISTRY"); [ "$n" = "null" ] && n=0
      for ((i=0;i<n;i++)); do
        [ "$(field "$i" status)" = "not-provisioned" ] && continue
        id=$(field "$i" id); rotate_dry_run "$id" || rc=1
      done
    else
      rotate_dry_run "$target" || rc=1
    fi
    return "$rc"
  fi
  if [ "$target" = "--due" ] || [ "$target" = "--all" ]; then
    local n i id exp d; n=$("$YQ" e '.secrets | length' "$REGISTRY")
    for ((i=0;i<n;i++)); do
      id=$(field "$i" id); exp=$(field "$i" expires)
      [ "$(field "$i" status)" = "not-provisioned" ] && continue
      if [ "$target" = "--all" ]; then rotate_one "$id" || rc=1; continue; fi
      [ -z "$exp" ] || [ "$exp" = "unknown" ] && { rotate_one "$id" || rc=1; continue; }
      d=$(days_until "$exp"); [ "${d:-99}" -le 14 ] 2>/dev/null && { rotate_one "$id" || rc=1; }
    done
  else
    rotate_one "$target" || rc=1
  fi
  return $rc
}

################################################################################
# done — record a rotation performed by hand (stamps registry + rotation log)
################################################################################
mark_done(){ # idx when
  local idx="$1" when="$2" id cadence exp
  id=$(field "$idx" id); cadence=$(field "$idx" cadence_days); [ -z "$cadence" ] && cadence=90
  exp=$(date -d "$when + $cadence days" +%F 2>/dev/null) || { print_error "bad date: $when (use YYYY-MM-DD)"; return 1; }
  # You may not RECORD a rotation you did not PROPAGATE. Stamping last_rotated
  # while half the declared copies still hold the old value is precisely how the
  # registry came to assert "OK 2027-06-26" over 16 dead tokens.
  if [ "${NWP_SECRETS_FORCE_DONE:-0}" != "1" ]; then
    local drifted; drifted=$(entry_locations_in_sync "$idx" 2>&1 >/dev/null)
    if [ -n "$drifted" ]; then
      print_error "$id: refusing to stamp — these declared locations do NOT hold the canonical value:"
      printf '    %s\n' $drifted
      print_hint "propagate first:  pl secrets sync $id    (override only if you know why: NWP_SECRETS_FORCE_DONE=1)"
      return 1
    fi
  fi
  "$YQ" e -i ".secrets[$idx].last_rotated = \"$when\" | .secrets[$idx].expires = \"$exp\"" "$REGISTRY"
  # Same discharge as `rotate` (D8): this verb is the "I rotated it by hand"
  # path and it passes the SAME propagation gate above, so it earns the same
  # right to clear a recorded exposure. Doing it in only one of the two verbs
  # would leave a debt standing forever for anyone who rotates at the provider.
  local cleared; cleared=$(exposure_discharge "$idx" "$when")
  [ -f "$ROT_LOG" ] || printf '# Credential rotation — %s\n\nDates only; never paste values.\n\n' "$(date +%Y-%m)" > "$ROT_LOG"
  printf -- "- [x] %s — rotated %s, next expiry %s%s\n" "$id" "$when" "$exp" \
    "${cleared:+ — cleared exposure debt: $cleared}" >> "$ROT_LOG"
  print_success "marked $id rotated $when → expires $exp"
}
cmd_done(){
  need_yq; need_registry
  local arg="${1:-}"; [ -n "$arg" ] || die "usage: pl secrets done <#|id|--all> [YYYY-MM-DD]   (date defaults to today)"
  local when="${2:-$(date +%F)}"
  if [ "$arg" = "--all" ]; then
    local n i; n=$("$YQ" e '.secrets | length' "$REGISTRY"); [ "$n" = "null" ] && n=0
    for ((i=0;i<n;i++)); do mark_done "$i" "$when"; done
  else
    local idx
    if [[ "$arg" =~ ^[0-9]+$ ]]; then
      [ "$arg" -ge 1 ] || die "number must be >= 1"
      idx=$((arg-1))
    else
      idx=$(registry_index_of "$arg")
    fi
    { [ "$idx" = "-1" ] || [ -z "$(field "$idx" id)" ]; } && die "no such secret: $arg (see: pl secrets status)"
    mark_done "$idx" "$when"
  fi
}

################################################################################
# expose / debt — KNOWN-EXPOSED credentials and the rotation DEBT they create
#
# Operator ruling D8 (2026-08-01): "I'm not worried about token exposure.
# Exposures need to be logged in the todo list so they can be rotated when I get
# to it and must be done before prod site starts."
#
# Before this, an exposure could only be written down as free-text prose in a
# GitLab issue. Three were found in one night (ops#182/#183/#194) plus a token
# value in a local transcript, and prose in a tracker is exactly the shape that
# gets forgotten: nothing reads it, nothing counts it, nothing refuses because
# of it. Now the fact lives on the CREDENTIAL, in the registry that `status`,
# `audit`, `lint`, `pl todo`, `pl rag` and the prod deploy gate all already read.
#
# THE ONE DISTINCTION THAT MATTERS: closing the leak SURFACE (redacting the doc)
# is NOT rotating. `closed:` and `rotated:` are independent booleans and only
# the second discharges the debt — see lib/rotation-debt.sh for the schema and
# the `where:` grammar.
################################################################################
EXPOSURE_SEVERITIES="low medium high critical"

# where_parse <loc> -> 0 if it matches the `where:` grammar, 1 otherwise.
# Same reasoning as loc_parse for stored_in: a location the tooling cannot parse
# is a location it silently stops checking.
where_parse(){
  local w="$1"
  case "$w" in
    doc:?*|repo:?*|issue:?*|transcript:?*|log:?*|ci:?*|external:?*) return 0 ;;
    host=*:*)
      # Separate statements, not one `local a=… b=${a}`: bash expands every word
      # of a `local` BEFORE assigning any of them, so the second would read an
      # unbound `rest` and die under `set -u` (measured — it aborted a real
      # backfill mid-command).
      local rest h p
      rest="${w#host=}"; h="${rest%%:*}"; p="${rest#*:}"
      { [ -n "$h" ] && [ -n "$p" ] && [ "$p" != "$rest" ]; } && return 0
      return 1 ;;
  esac
  return 1
}
where_grammar_help(){
  print_hint "  where: grammar — doc:<path> · repo:<project>:<path> · issue:<project>#<n> ·"
  print_hint "                   host=<role>:<path> · transcript:<path> · log:<path> ·"
  print_hint "                   ci:<text> · external:<text>"
}

is_iso_date(){ [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; }

# exposure_discharge <idx> <when> — flip every OPEN exposure on this entry to
# rotated. Called ONLY from the rotation paths (rotate/done), never from
# `expose`, so a debt cannot be cleared by anything other than an actual
# rotation that already passed the propagation gate those verbs enforce.
# Echoes the refs it cleared (for the rotation log); silent when there were none.
exposure_discharge(){
  local idx="$1" when="$2" open refs
  open=$("$YQ" e ".secrets[$idx].exposure // [] | map(select((.rotated // false) != true)) | length" "$REGISTRY" 2>/dev/null)
  [ "${open:-0}" -gt 0 ] 2>/dev/null || return 0
  refs=$("$YQ" e ".secrets[$idx].exposure // [] | map(select((.rotated // false) != true)) | map(.ref // \"unref'd\") | join(\",\")" "$REGISTRY" 2>/dev/null)
  NWP_EXP_WHEN="$when" "$YQ" e -i \
    "(.secrets[$idx].exposure[] | select((.rotated // false) != true)) |= (.rotated = true | .rotated_at = strenv(NWP_EXP_WHEN))" \
    "$REGISTRY" || return 1
  # Human line to stderr, refs to stdout: callers capture the refs for the
  # rotation log, and a captured success message would end up inside it.
  print_success "  discharged $open exposure rotation-debt record(s) [$refs]" >&2
  printf '%s' "$refs"
}

cmd_expose(){
  need_yq; need_registry
  local arg="" reason="" ref="" sev="high" at="" notes="" closed=false close_only=false
  local adopt="" list=false
  local -a wheres=() stored=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason=*)   reason="${1#*=}" ;;
      --reason)     shift; reason="${1:-}" ;;
      --where=*)    wheres+=("${1#*=}") ;;
      --ref=*)      ref="${1#*=}" ;;
      --severity=*) sev="${1#*=}" ;;
      --at=*)       at="${1#*=}" ;;
      --notes=*)    notes="${1#*=}" ;;
      --closed)     closed=true ;;
      --close)      close_only=true ;;
      --adopt=*)    adopt="${1#*=}" ;;
      --adopt)      adopt="unknown" ;;
      --stored-in=*) stored+=("${1#*=}") ;;
      --list|-l)    list=true ;;
      -h|--help)    cmd_expose_help; return 0 ;;
      -*)           die "unknown option: $1  (try: pl secrets expose --help)" ;;
      *)            [ -z "$arg" ] && arg="$1" || die "unexpected argument: $1" ;;
    esac
    shift
  done
  [ "$list" = true ] && { cmd_debt --all; return $?; }
  [ -n "$arg" ] || { cmd_expose_help; die "an id (or #) is required"; }
  [ -n "$at" ] || at=$(date +%F)
  is_iso_date "$at" || die "--at must be YYYY-MM-DD (got: $at)"

  local idx id
  if [[ "$arg" =~ ^[0-9]+$ ]]; then idx=$((arg-1)); else idx=$(registry_index_of "$arg"); fi

  # ── adopt-on-record ──────────────────────────────────────────────────────
  # 3 of the 4 exposures found on 2026-08-01 were of credentials the registry
  # did not know about AT ALL — which is a large part of why they could be
  # exposed unnoticed. If recording one required a separate "first add the
  # entry" step, the sweep that finds them would keep filing prose instead.
  if [ "$idx" = "-1" ] || [ -z "$(field "$idx" id)" ]; then
    [ -n "$adopt" ] || die "no such secret: $arg (see: pl secrets status)
  If this credential is not in the registry yet, record it AND the exposure in one go:
    pl secrets expose $arg --adopt=<provider> --stored-in='external:…' --reason='…'"
    [[ "$arg" =~ ^[a-z0-9_]+$ ]] || die "--adopt needs a registry-shaped id ([a-z0-9_]+), got: $arg"
    [ "${#stored[@]}" -gt 0 ] || die "--adopt needs at least one --stored-in=<location> (stored_in grammar)"
    local sloc skind
    for sloc in "${stored[@]}"; do
      IFS=$'\x1f' read -r skind _ _ _ < <(loc_parse "$sloc")
      [ "$skind" = "bad" ] && die "--stored-in does not parse: '$sloc' (see: pl secrets help, stored_in grammar)"
    done
    NWP_EXP_ID="$arg" NWP_EXP_PROV="$adopt" "$YQ" e -i \
      ".secrets += [{\"id\": strenv(NWP_EXP_ID), \"provider\": strenv(NWP_EXP_PROV),
                     \"type\": \"TODO — describe what this credential is for\",
                     \"scopes\": [], \"stored_in\": [], \"rotate_via\": \"manual\",
                     \"rotate_url\": \"\", \"cadence_days\": 365, \"expires\": \"unknown\",
                     \"last_rotated\": \"\", \"owner\": \"operator\",
                     \"status\": \"needs-classification\",
                     \"notes\": \"Adopted by 'pl secrets expose --adopt' when an exposure was recorded against it.\"}]" \
      "$REGISTRY" || die "failed to adopt $arg into the registry"
    idx=$(registry_index_of "$arg")
    for sloc in "${stored[@]}"; do
      NWP_EXP_LOC="$sloc" "$YQ" e -i ".secrets[$idx].stored_in += [strenv(NWP_EXP_LOC)]" "$REGISTRY"
    done
    print_success "adopted new registry entry: $arg (status: needs-classification)"
  fi
  id=$(field "$idx" id)

  # ── --close: the SURFACE is remediated. The debt is NOT. ─────────────────
  if [ "$close_only" = true ]; then
    local nopen
    nopen=$("$YQ" e ".secrets[$idx].exposure // [] | map(select((.closed // false) != true)) | length" "$REGISTRY" 2>/dev/null)
    [ "${nopen:-0}" -gt 0 ] 2>/dev/null || die "$id: no exposure record with an open surface to close"
    NWP_EXP_AT="$at" "$YQ" e -i \
      "(.secrets[$idx].exposure[] | select((.closed // false) != true)) |= (.closed = true | .closed_at = strenv(NWP_EXP_AT))" \
      "$REGISTRY" || die "failed to update $REGISTRY"
    print_success "$id: marked $nopen exposure surface(s) CLOSED as of $at"
    print_warning "the rotation debt is UNCHANGED — a closed surface is not a rotated credential."
    print_hint "discharge it: pl secrets rotate $id   (or, if you rotated by hand: pl secrets done $id)"
    return 0
  fi

  # ── record a new exposure ────────────────────────────────────────────────
  [ -n "$reason" ] || { cmd_expose_help; die "--reason='<one line: how it leaked>' is required"; }
  case " $EXPOSURE_SEVERITIES " in *" $sev "*) ;; *) die "--severity must be one of: $EXPOSURE_SEVERITIES" ;; esac
  # A ref alone is a legitimate `where` — the issue itself is a surface holding
  # the description, and requiring more would push people back to prose.
  if [ "${#wheres[@]}" -eq 0 ] && [ -n "$ref" ]; then wheres+=("issue:$ref"); fi
  [ "${#wheres[@]}" -gt 0 ] || { where_grammar_help; die "at least one --where=<loc> (or a --ref=) is required — 'where did it leak to' is the whole record"; }
  local w
  for w in "${wheres[@]}"; do
    where_parse "$w" || { where_grammar_help; die "--where does not parse: '$w'"; }
  done

  local wlist; wlist=$(printf '%s\n' "${wheres[@]}")
  NWP_EXP_AT="$at" NWP_EXP_HOW="$reason" NWP_EXP_WHERE="$wlist" \
  NWP_EXP_REF="$ref" NWP_EXP_SEV="$sev" NWP_EXP_NOTES="$notes" \
  "$YQ" e -i ".secrets[$idx].exposure = ((.secrets[$idx].exposure // []) + [{
        \"at\": strenv(NWP_EXP_AT),
        \"how\": strenv(NWP_EXP_HOW),
        \"where\": (strenv(NWP_EXP_WHERE) | split(\"\n\")),
        \"closed\": $closed,
        \"rotated\": false,
        \"ref\": strenv(NWP_EXP_REF),
        \"severity\": strenv(NWP_EXP_SEV),
        \"notes\": strenv(NWP_EXP_NOTES)
      }])" "$REGISTRY" || die "failed to write $REGISTRY"
  # Drop the optional fields that were left empty rather than record "".
  "$YQ" e -i "del(.secrets[$idx].exposure[-1].ref | select(. == \"\")) | del(.secrets[$idx].exposure[-1].notes | select(. == \"\"))" "$REGISTRY" 2>/dev/null || true

  print_success "recorded exposure on $id (at $at, severity $sev, surface $([ "$closed" = true ] && echo CLOSED || echo OPEN))"
  print_warning "ROTATION IS NOW OWED on $id. It will appear in 'pl todo', redden 'pl rag',"
  print_warning "and REFUSE any prod bring-up until 'pl secrets rotate $id' discharges it."
  print_hint "review the queue: pl secrets debt"
}

cmd_expose_help(){
  cat <<EOF
${BOLD}pl secrets expose${NC} — record that a credential's VALUE was exposed (rotation becomes OWED)

  pl secrets expose <#|id> --reason='<one line: how it leaked>'
                    [--where=<loc>]...   where it leaked to (repeatable; grammar below)
                    [--ref=ops#182]      tracker reference (also usable AS a --where)
                    [--closed]           the leak SURFACE is already remediated
                    [--severity=low|medium|high|critical]   default: high
                    [--at=YYYY-MM-DD]    default: today
                    [--notes='…']
                    [--adopt=<provider> --stored-in=<loc>]  credential not in the
                                         registry yet? adopt + record in ONE command
  pl secrets expose <#|id> --close [--at=DATE]   the SURFACE is now closed (debt UNCHANGED)
  pl secrets expose --list                        same as: pl secrets debt --all

  A CLOSED SURFACE IS NOT A ROTATION. Only 'pl secrets rotate <id>' / 'pl secrets
  done <id>' discharge the debt, and both already refuse to stamp while any
  declared copy still holds a different value.

$(where_grammar_help 2>&1)
EOF
}

################################################################################
# debt — the open rotation-debt queue (what blocks a prod bring-up)
################################################################################
cmd_debt(){
  need_yq; need_registry
  local all=false json=false a
  for a in "$@"; do
    case "$a" in
      --all) all=true ;;
      --json) json=true ;;
      -h|--help) echo "usage: pl secrets debt [--all] [--json]   (--all also lists discharged records)"; return 0 ;;
    esac
  done

  if [ "$json" = true ]; then
    "$YQ" e -o=json '[.secrets[] | .id as $id | (.exposure // [])[]
        | select('"$([ "$all" = true ] && echo 'true' || echo '(.rotated // false) != true')"')
        | {"id": $id, "at": .at, "how": .how, "where": (.where // []),
           "closed": (.closed // false), "rotated": (.rotated // false),
           "ref": (.ref // ""), "severity": (.severity // "high")}]' "$REGISTRY"
    return 0
  fi

  print_header "Rotation debt — credentials known to be EXPOSED and not yet rotated"
  local n=0 id at ref closed sev how
  while IFS=$'\t' read -r id at ref closed sev how; do
    [ -n "$id" ] || continue
    n=$((n+1))
    printf "  ${RED}●${NC} ${BOLD}%-28s${NC} exposed %s  [%s, %s]  %s\n" "$id" "$at" "$sev" "$(rotation_debt_surface_label "$closed")" "${ref:--}"
    printf "      %s\n" "$how"
    local idx; idx=$(registry_index_of "$id")
    "$YQ" e ".secrets[$idx].exposure // [] | map(select((.rotated // false) != true)) | .[].where[]?" "$REGISTRY" 2>/dev/null \
      | sed 's/^/      ↳ /'
  done < <(rotation_debt_open)

  if [ "$all" = true ]; then
    echo
    print_info "Discharged (rotation completed):"
    "$YQ" e '.secrets[] | .id as $id | (.exposure // [])[] | select((.rotated // false) == true)
             | "  ✓ " + $id + "  exposed " + (.at // "?") + ", rotated " + (.rotated_at // "?") + "  " + (.ref // "-")' \
      "$REGISTRY" 2>/dev/null
  fi

  echo
  if [ "$n" -eq 0 ]; then
    print_success "no open rotation debt — a prod bring-up is not blocked by this gate"
    return 0
  fi
  print_error "$n open rotation debt record(s)."
  print_warning "These BLOCK a prod bring-up (pl canonical set <site> prod, and every prod"
  print_warning "write through the ADR-0028 deploy gate: pl stg2prod / pl live2prod)."
  print_hint "discharge: pl secrets rotate <id>   ·   surface remediated only: pl secrets expose <id> --close"
  return 1
}

################################################################################
# whose — ask GitLab which user/bot/project owns a token (token never printed)
################################################################################
cmd_whose(){
  need_yq; need_registry
  command -v curl >/dev/null || die "curl required"
  local arg="${1:-}"; [ -n "$arg" ] || die "usage: pl secrets whose <#|id>   (asks GitLab who owns the token)"
  local idx
  if [[ "$arg" =~ ^[0-9]+$ ]]; then idx=$((arg-1)); else idx=$(registry_index_of "$arg"); fi
  { [ "$idx" = "-1" ] || [ -z "$(field "$idx" id)" ]; } && die "no such secret: $arg (see: pl secrets status)"
  local id prov url host key val
  id=$(field "$idx" id); prov=$(field "$idx" provider); url=$(field "$idx" rotate_url)
  [ "$prov" = "gitlab" ] || die "'whose' supports gitlab tokens only (this entry is: ${prov:-unknown})"
  host=$(printf '%s' "$url" | sed -E 's|https?://([^/]+).*|\1|')
  if [ -z "$host" ] || [ "$host" = "$url" ]; then
    host=$("$YQ" e '.gitlab.server.domain // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  fi
  [ -n "$host" ] || die "cannot determine the GitLab host (no rotate_url on the entry, no gitlab.server.domain in .secrets.yml)"
  key=$("$YQ" e ".secrets[$idx].stored_in[]" "$REGISTRY" 2>/dev/null | grep -E '^\.secrets[^:]*\.yml:' | head -1 | sed -E 's/^[^:]*://')
  [ -n "$key" ] || die "no .secrets.yml key recorded in stored_in for $id"
  val=$("$YQ" e ".$key // \"\"" "$SECRETS_FILE" 2>/dev/null)
  { [ -z "$val" ] || [ "$val" = "null" ]; } && die "$key is empty in .secrets.yml — not provisioned, nothing to query"
  print_header "Who owns $id?  → https://$host/api/v4/user"
  # token via a 0600 curl config so it never lands in argv / ps / history
  local cfg resp; cfg=$(mktemp); chmod 600 "$cfg"
  printf 'silent\nmax-time = 10\nurl = "https://%s/api/v4/user"\nheader = "PRIVATE-TOKEN: %s"\n' "$host" "$val" > "$cfg"
  val=""
  resp=$(curl -K "$cfg" 2>/dev/null)
  local uname nm uid
  uname=$("$YQ" e -p=json '.username // ""' <<<"$resp" 2>/dev/null | grep -v '^null$')
  if [ -z "$uname" ]; then
    val=""; rm -f "$cfg"
    print_error "no user returned — the token is most likely REVOKED/expired (or host unreachable)."
    print_hint "If revoked there's nothing to find: just create a fresh token and run  pl secrets rotate $((idx+1))"
    return 0
  fi
  nm=$("$YQ" e -p=json '.name // ""' <<<"$resp"); uid=$("$YQ" e -p=json '.id // ""' <<<"$resp")
  print_success "owner: $uname   (name: $nm, id: $uid)"
  # Resolve the exact project/group path so we can print the real Access Tokens URL.
  local rid rpath
  case "$uname" in
    project_*_bot_*)
      rid="${uname#project_}"; rid="${rid%%_bot_*}"
      printf 'silent\nmax-time = 10\nurl = "https://%s/api/v4/projects/%s"\nheader = "PRIVATE-TOKEN: %s"\n' "$host" "$rid" "$val" > "$cfg"
      rpath=$("$YQ" e -p=json '.path_with_namespace // ""' <<<"$(curl -K "$cfg" 2>/dev/null)" 2>/dev/null | grep -v '^null$')
      [ -n "$rpath" ] \
        && print_info "→ PROJECT access token (token name '$nm') on '$rpath'.  Rotate at:  https://$host/$rpath/-/settings/access_tokens" \
        || print_info "→ PROJECT access token (token name '$nm', project id $rid).  Open project $rid → Settings → Access Tokens" ;;
    group_*_bot_*)
      rid="${uname#group_}"; rid="${rid%%_bot_*}"
      printf 'silent\nmax-time = 10\nurl = "https://%s/api/v4/groups/%s"\nheader = "PRIVATE-TOKEN: %s"\n' "$host" "$rid" "$val" > "$cfg"
      rpath=$("$YQ" e -p=json '.full_path // ""' <<<"$(curl -K "$cfg" 2>/dev/null)" 2>/dev/null | grep -v '^null$')
      [ -n "$rpath" ] \
        && print_info "→ GROUP access token (token name '$nm') on '$rpath'.  Rotate at:  https://$host/groups/$rpath/-/settings/access_tokens" \
        || print_info "→ GROUP access token (token name '$nm', group id $rid).  Open group $rid → Settings → Access Tokens" ;;
    *)
      print_info "→ PERSONAL token of '$uname' (token name '$nm').  Manage at:  https://$host/-/user_settings/personal_access_tokens" ;;
  esac
  val=""; rm -f "$cfg"
}

################################################################################
# scan — leak sweep (filenames + counts only, never values)
#
#   Returns 1 on ANY hit. It used to print LEAK lines and exit 0, so nothing —
#   not cron, not `pl todo`, not CI — could gate on it: 57 LEAK lines and a
#   green exit code is a report nobody has to act on.
#   Flags: --quiet (paths only) · --transcripts (also sweep the AI transcript
#   tree, folding in what was previously a crontab-only script).
################################################################################
_leak_values_file(){ # -> path of a 0600 temp file holding every live value
  local TMP; TMP="$(mktemp)"; chmod 600 "$TMP"
  { "$YQ" e '.. | select(tag == "!!str")' "$SECRETS_FILE" 2>/dev/null
    cut -d= -f2- "$HOME/.nwp-agent-loop.env" 2>/dev/null
  } | tr -d '"'\' | sed -E 's/[[:space:]]+$//' \
    | grep -E '^[A-Za-z0-9_./+=:-]{16,}$' | grep -vE '^(https?://|/home/|~/|[0-9]+$)' \
    | sort -u > "$TMP"
  printf '%s' "$TMP"
}
_LEAK_PAT='glpat-[A-Za-z0-9_-]{20,}|github_pat_[A-Za-z0-9_]{40,}|gh[pousr]_[A-Za-z0-9]{36,}|sk-ant-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

cmd_surfaces(){ _leak_surfaces; }

cmd_scan(){
  need_yq
  umask 077   # nothing this command writes may be group/world readable
  local QUIET=0 TRANSCRIPTS=0 a
  for a in "$@"; do case "$a" in
    --quiet|-q) QUIET=1 ;;
    --transcripts) TRANSCRIPTS=1 ;;
  esac; done
  local TMP; TMP="$(_leak_values_file)"
  local nvals; nvals=$(wc -l < "$TMP")
  [ "$QUIET" = 0 ] && print_header "Secret leak scan ($nvals live values + shape patterns)"
  local -a surfaces=(); mapfile -t surfaces < <(_leak_surfaces)
  [ "$TRANSCRIPTS" = 1 ] && surfaces+=("$HOME/.claude/projects" "$HOME/.claude/todos")
  local hit=0 s f
  for s in "${surfaces[@]}"; do
    [ -e "$s" ] || continue
    while IFS= read -r f; do
      [ -z "$f" ] && continue; hit=1
      if [ "$QUIET" = 1 ]; then printf '%s\n' "$f"; else
        local c; c=$(grep -F -o -f "$TMP" "$f" 2>/dev/null | sort -u | wc -l)
        printf "  ${RED}LEAK${NC} %-3s value(s) + shape  %s\n" "$c" "$f"
      fi
    done < <( { [ -s "$TMP" ] && grep -rlF -f "$TMP" "$s" 2>/dev/null; grep -rlE "$_LEAK_PAT" "$s" 2>/dev/null; } | sort -u )
  done
  rm -f "$TMP"
  if [ "$hit" = "0" ]; then
    [ "$QUIET" = 0 ] && print_success "no secret values or shaped strings found in any surface"
    return 0
  fi
  [ "$QUIET" = 0 ] && print_hint "scrub them (pl secrets scrub), then rotate the affected secrets — a leaked value is a dead value"
  return 1
}

################################################################################
# scrub — redact secret strings (pattern + live value) in place
################################################################################
cmd_scrub(){
  need_yq
  umask 077
  local ASSUME=0; { [ "${1:-}" = "-y" ] || [ "${1:-}" = "--yes" ]; } && { ASSUME=1; shift; }
  local today; today=$(date +%F)
  local TMP; TMP="$(_leak_values_file)"
  local PAT="$_LEAK_PAT"
  print_header "Scrub secret strings (pattern + live value) -> [REDACTED-$today]"

  # scan and scrub MUST sweep the same set — they diverged once (scrub omitted
  # $PROJECT_ROOT/logs, the one surface scan reported in-repo), so both now read
  # _leak_surfaces() and a unit test asserts the two sets are equal.
  local -a targets=("$@") roots=(); mapfile -t roots < <(_leak_surfaces)
  if [ ${#targets[@]} -eq 0 ]; then
    mapfile -t targets < <( { [ -s "$TMP" ] && grep -rlF -f "$TMP" "${roots[@]}" 2>/dev/null
                              grep -rlE "$PAT" "${roots[@]}" 2>/dev/null; } | sort -u )
  fi
  if [ ${#targets[@]} -eq 0 ]; then print_success "nothing to scrub"; rm -f "$TMP"; return 0; fi
  printf '  %d file(s):\n' "${#targets[@]}"; printf '    %s\n' "${targets[@]}"
  print_warning "in-place, no backup (a backup would re-leak). private/ values become worthless after rotation."
  if [ "$ASSUME" = 0 ]; then
    local a; read -r -p "  proceed? [y/N] " a </dev/tty; [[ "$a" == [yY]* ]] || { print_warning "aborted"; rm -f "$TMP"; return 0; }
  fi

  local f v
  for f in "${targets[@]}"; do
    [ -f "$f" ] || continue
    perl -i -pe "s/glpat-[A-Za-z0-9_-]{20,}/[REDACTED-$today]/g; s/github_pat_[A-Za-z0-9_]{40,}/[REDACTED-$today]/g; s/gh[pousr]_[A-Za-z0-9]{36,}/[REDACTED-$today]/g; s/sk-ant-[A-Za-z0-9_-]{20,}/[REDACTED-$today]/g; s/AIza[0-9A-Za-z_-]{35}/[REDACTED-$today]/g; s/AKIA[0-9A-Z]{16}/[REDACTED-$today]/g" "$f" 2>/dev/null
    if [ -s "$TMP" ]; then
      while IFS= read -r v; do [ -n "$v" ] && v="$v" perl -i -pe 's/\Q$ENV{v}\E/[REDACTED]/g' "$f" 2>/dev/null; done < "$TMP"
    fi
    print_success "  scrubbed $f"
  done
  rm -f "$TMP"
  print_hint "verify with: pl secrets scan"
}

################################################################################
# lint — cross-check the registry against .secrets.yml (repeatable assurance)
################################################################################
cmd_lint(){
  need_yq; need_registry
  local issues=0
  print_header "secrets lint — registry vs .secrets.yml"

  # 1. orphans: every registry .secrets.yml:KEY must exist
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    local key="${ref#*:}"
    [ "$("$YQ" e "(.$key // \"__MISSING__\")" "$SECRETS_FILE" 2>/dev/null)" = "__MISSING__" ] \
      && { print_error "orphan: registry refs $ref but it's missing in .secrets.yml"; issues=$((issues+1)); }
  done < <("$YQ" e '.secrets[].stored_in[]?' "$REGISTRY" 2>/dev/null | grep -oE '^\.secrets\.yml:[A-Za-z0-9_.]+')

  # 2. no secrets hiding in .secrets.yml comments
  local cs; cs=$(grep -E '^[[:space:]]*#' "$SECRETS_FILE" 2>/dev/null | grep -Ec 'glpat-[A-Za-z0-9_-]{20,}|github_pat_|sk-ant-|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|password[^:]*:[[:space:]]*[A-Za-z0-9_+/=-]{12,}')
  [ "${cs:-0}" -gt 0 ] && { print_error "comment-secret sweep: $cs secret-shaped string(s) in .secrets.yml comments"; issues=$((issues+1)); } \
    || print_success "no secrets in .secrets.yml comments"

  # 3. provisioned/empty consistency + required id
  local n i; n=$("$YQ" e '.secrets | length' "$REGISTRY"); [ "$n" = "null" ] && n=0
  for ((i=0;i<n;i++)); do
    local id st key len
    id=$(field "$i" id); st=$(field "$i" status)
    [ -z "$id" ] && { print_error "entry $i has no id"; issues=$((issues+1)); continue; }
    key=$("$YQ" e ".secrets[$i].stored_in[]?" "$REGISTRY" 2>/dev/null | grep -oE '^\.secrets\.yml:[A-Za-z0-9_.]+' | head -1 | sed 's/^.secrets.yml://')
    [ -z "$key" ] && continue
    len=$("$YQ" e "(.$key // \"\") | length" "$SECRETS_FILE" 2>/dev/null)
    if [ "$st" = "not-provisioned" ] && [ "${len:-0}" -gt 0 ]; then
      print_warning "$id: marked not-provisioned but $key has a value"; issues=$((issues+1))
    elif [ "$st" != "not-provisioned" ] && [ "${len:-0}" -eq 0 ]; then
      print_warning "$id: expected a value but $key is empty"; issues=$((issues+1))
    fi
  done

  # 4. REVERSE direction — every non-empty .secrets.yml leaf must be DECLARED.
  #    Without this the lint only ever asked "does what I recorded exist?", never
  #    "is there anything here I never recorded?" — which is how the single most
  #    powerful token in the estate (linode.provision_token) and a NON-RECOVERABLE
  #    DR password (restic.dr_pull.password) sat untracked under a LINT PASS.
  #    Suppression is allowed, but only as a recorded decision in `ignored_keys:`.
  local declared ignored k len
  declared=$("$YQ" e '.secrets[].stored_in[]?' "$REGISTRY" 2>/dev/null \
             | grep -oE '^\.secrets\.yml:[A-Za-z0-9_.]+' | sed 's/^\.secrets\.yml://' | sort -u)
  ignored=$("$YQ" e '.ignored_keys[]? // ""' "$REGISTRY" 2>/dev/null | grep -v '^null$' | grep -v '^$')
  local undeclared=0
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    printf '%s\n' "$declared" | grep -qxF "$k" && continue
    printf '%s\n' "$ignored"  | grep -qxF "$k" && continue
    len=$("$YQ" e "(.$k // \"\") | length" "$SECRETS_FILE" 2>/dev/null)
    [ "${len:-0}" -eq 0 ] && continue
    print_error "undeclared: .secrets.yml holds '$k' (${len} chars) but no registry entry claims it"
    undeclared=$((undeclared+1)); issues=$((issues+1))
  done < <("$YQ" e '.. | select(tag == "!!str") | path | join(".")' "$SECRETS_FILE" 2>/dev/null)
  if [ "$undeclared" -gt 0 ]; then
    print_hint "register it:  pl secrets adopt <dotted.key>   ·   or record the exemption in the registry's ignored_keys:"
  else
    print_success "every non-empty .secrets.yml key is declared (or explicitly in ignored_keys)"
  fi

  # 5. stored_in GRAMMAR — a location the tooling cannot parse is a location the
  #    tooling silently stops checking. Prose goes in stored_in_notes:.
  local loc lkind lhost lpath lref bad=0 phantom=0
  for ((i=0;i<n;i++)); do
    local eid; eid=$(field "$i" id)
    while IFS= read -r loc; do
      [ -z "$loc" ] && continue
      IFS=$'\x1f' read -r lkind lhost lpath lref < <(loc_parse "$loc")
      if [ "$lkind" = "bad" ]; then
        print_error "$eid: unparseable stored_in (grammar) — '$loc'"
        bad=$((bad+1)); issues=$((issues+1)); continue
      fi
      { [ "$lkind" = "external" ] || [ -n "$lhost" ]; } && continue
      if [ ! -f "$(loc_abspath "$lpath")" ]; then
        print_error "$eid: declared location does not exist — $lpath"
        phantom=$((phantom+1)); issues=$((issues+1))
      fi
    done < <(entry_locations "$i")
  done
  [ "$bad" -eq 0 ] && [ "$phantom" -eq 0 ] && print_success "every stored_in entry parses and resolves"

  # 6. FILE PERMISSIONS — a correctly-recorded secret in a world-readable file
  #    is still a leaked secret.
  local perm_bad=0 f mode
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    mode=$(stat -c '%a' "$f" 2>/dev/null)
    if [ "$(( 8#${mode:-600} & 8#077 ))" -ne 0 ]; then
      print_error "permission: $f is mode $mode — group/world readable (want 600)"
      perm_bad=$((perm_bad+1)); issues=$((issues+1))
    fi
  done < <( { printf '%s\n' "$SECRETS_FILE" "$HOME/.nwp-agent-loop.env"
              ls -1 "$NWP_ROOT"/logs/*leak*.json "$NWP_ROOT"/logs/gitleaks*.json 2>/dev/null
              for ((i=0;i<n;i++)); do
                while IFS= read -r loc; do
                  [ -z "$loc" ] && continue
                  IFS=$'\x1f' read -r lkind lhost lpath lref < <(loc_parse "$loc")
                  { [ "$lkind" = "external" ] || [ "$lkind" = "bad" ] || [ -n "$lhost" ]; } && continue
                  loc_abspath "$lpath"; echo
                done < <(entry_locations "$i")
              done; } | sort -u )
  [ "$perm_bad" -eq 0 ] && print_success "every secret-bearing file is 0600"

  # 7. NO-PROBE — a declared SCOPE that is never checked is folklore.
  #    `_probe_scopes` has existed since the last pass and works; 0 of 25 entries
  #    carried a `probe:` block, so the scope column could not disagree with the
  #    provider even in principle. That is how the registry came to attribute
  #    "can destroy every prod Linode" to a token that is in fact DNS-only, while
  #    the token that actually holds instances:read_write was not recorded at all.
  #    If an entry claims a capability, it must also say how to check the claim.
  local noprobe=0
  for ((i=0;i<n;i++)); do
    local pid pst nsc npr
    pid=$(field "$i" id); pst=$(field "$i" status)
    [ -z "$pid" ] && continue
    # A credential that does not exist yet, or no longer exists, has no live
    # capability to check — demanding a probe for it would only train people to
    # add probes that cannot run.
    case "$pst" in not-provisioned|RETIRED|retired) continue ;; esac
    nsc=$("$YQ" e ".secrets[$i].scopes // [] | length" "$REGISTRY" 2>/dev/null)
    [ "${nsc:-0}" -eq 0 ] 2>/dev/null && continue
    npr=$("$YQ" e ".secrets[$i].probe // [] | length" "$REGISTRY" 2>/dev/null)
    [ "${npr:-0}" -gt 0 ] 2>/dev/null && continue
    print_error "NO-PROBE: $pid declares scopes but no probe: — the scope claim can never be falsified"
    noprobe=$((noprobe+1)); issues=$((issues+1))
  done
  if [ "$noprobe" -gt 0 ]; then
    print_hint "scaffold one:  pl secrets probe-scaffold <id>    (then correct the expected codes against reality)"
  else
    print_success "every entry that claims a scope also declares how to check it"
  fi

  # 8. TIER — .secrets.yml is the tier CLAUDE.md tells an AI agent it MAY read.
  #    An admin password or a backup-DECRYPTION password in that file is a tier
  #    violation by construction: it hands an AI-readable file the ability to
  #    become the operator, or to read prod user data out of a DR snapshot.
  #    Those belong in .secrets.data.yml, which the agent is deny-ruled from.
  #    Note this fires on the KEY NAME, deliberately — a rule that needed the
  #    value would have to read the value.
  local tierbad=0
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    case "$k" in
      *admin.password|*admin.initial_password|*admin_password|*.root_password) ;;
      restic.*.password|*.restic_password|*backup*.password|*.decryption_key) ;;
      *) continue ;;
    esac
    len=$("$YQ" e "(.$k // \"\") | length" "$SECRETS_FILE" 2>/dev/null)
    [ "${len:-0}" -eq 0 ] && continue
    print_error "TIER: '$k' is an admin/backup-decryption credential living in the AI-readable tier ($SECRETS_FILE)"
    tierbad=$((tierbad+1)); issues=$((issues+1))
  done < <("$YQ" e '.. | select(tag == "!!str") | path | join(".")' "$SECRETS_FILE" 2>/dev/null)

  # 8b. TIER by CAPABILITY, not by name. The name-based rule above would not have
  #     caught the worst credential in the estate: `linode.provision_token` reads
  #     like an ordinary infra token, and sat in the AI-readable tier while being
  #     able to enumerate and destroy every production Linode. CLAUDE.md's first
  #     trust assumption — "No AI-run machine may hold a key that reaches a
  #     production server" — is about what a credential CAN DO, so the lint has to
  #     be too. This reads the registry's recorded scope (which NO-PROBE now
  #     forces to be a measured claim rather than an assumed one), so widening a
  #     token's scope makes it fail here without anyone renaming anything.
  local ti tid tst tk tsc
  local ntier; ntier=$("$YQ" e '.secrets | length' "$REGISTRY" 2>/dev/null); [ "$ntier" = "null" ] && ntier=0
  for ((ti=0; ti<ntier; ti++)); do
    tid=$(field "$ti" id); [ -z "$tid" ] && continue
    tst=$(field "$ti" status)
    case "$tst" in not-provisioned|RETIRED|retired) continue ;; esac
    tsc=$("$YQ" e ".secrets[$ti].scopes // [] | join(\",\")" "$REGISTRY" 2>/dev/null)
    # Scopes that reach production infrastructure control.
    case ",$tsc," in
      *,linodes:read_write,*|*,linodes:*write*,*|*,instances:read_write,*|*,read_write,*) ;;
      *) continue ;;
    esac
    # …only a problem if it actually lives in the tier the agent may read.
    tk=$("$YQ" e ".secrets[$ti].stored_in[]? | select(. == \".secrets.yml:*\")" "$REGISTRY" 2>/dev/null | head -1)
    [ -z "$tk" ] && continue
    print_error "TIER-CAPABILITY: '$tid' can control production infrastructure (scopes: $tsc) from the AI-readable tier (${tk})"
    print_hint "  CLAUDE.md: no AI-run machine may hold a key that reaches a production server — revoke it, or move it to the deny-ruled tier"
    tierbad=$((tierbad+1)); issues=$((issues+1))
  done
  if [ "$tierbad" -gt 0 ]; then
    print_hint "move it to .secrets.data.yml (operator action — an AI agent must not perform this move):"
    print_hint "  pl secrets migrate-tier <dotted.key>   then re-run this lint"
  else
    print_success "no admin/backup-decryption credential in the AI-readable tier"
  fi

  # 9. UNTRACKED-REGISTRY — the source of record had no history, no review and no
  #    second copy, while its own GENERATED outputs (token-consumers.md, the
  #    rotation logs) were tracked. A registry you cannot diff is a registry that
  #    cannot be shown to have been wrong.
  #
  #    NOTE ON WHERE. The obvious fix — un-ignore it in nwp/nwp — is the wrong
  #    one, and measurably so: gitleaks over this file reports 162 findings, ALL
  #    of them identity/topology (66 live-domain-apex, 65 live-internal-domain,
  #    25 internal-bare-hostname, 4 operator-public-ip, 2 operator-personal-email)
  #    and ZERO credential findings. The registry is value-free exactly as
  #    designed — and it is also a complete map of the estate plus the operator's
  #    public IP and personal address. nwp/nwp is the public-release track; those
  #    three rules exist precisely to keep that out of it. So the requirement is
  #    "under version control", not "in THIS repo": a nested private repo at
  #    private/.git satisfies the history/review/second-copy goal without
  #    publishing the topology. `git -C <dir-of-registry>` resolves to whichever
  #    repo is innermost, so either arrangement passes.
  local _regdir; _regdir=$(dirname "$REGISTRY")
  if git -C "$_regdir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if ! git -C "$_regdir" ls-files --error-unmatch "$REGISTRY" >/dev/null 2>&1; then
      print_error "UNTRACKED-REGISTRY: $REGISTRY is not tracked by git — no history, no review, no second copy"
      print_hint "put it under version control WITHOUT publishing the estate topology:  pl secrets registry-track"
      issues=$((issues+1))
    else
      print_success "the registry itself is under version control"
      # Tracked but never committed since the last edit is only half the property.
      if ! git -C "$_regdir" diff --quiet -- "$REGISTRY" 2>/dev/null; then
        print_warning "UNCOMMITTED-REGISTRY: tracked, but the working copy differs from the last commit"
        issues=$((issues+1))
      fi
      # …and a repo with no remote is still a single copy on a single disk.
      if [ -z "$(git -C "$_regdir" remote 2>/dev/null)" ]; then
        print_warning "NO-REGISTRY-REMOTE: $_regdir has no remote — history exists, but there is still only one copy"
        print_hint "add a PRIVATE remote (never nwp/nwp — see the note above):  git -C $_regdir remote add origin <private-url>"
        issues=$((issues+1))
      fi
    fi
  fi

  # 10. EXPOSURE records — schema + the one integrity property that matters.
  #     A malformed exposure is worse than none: `pl todo`, `pl rag` and the
  #     prod deploy gate all read this block, so a record they cannot parse is a
  #     rotation debt that silently stops blocking anything. Hence a strict
  #     grammar, exactly as for stored_in.
  #
  #     UNBACKED is the integrity property: `rotated: true` asserts the
  #     credential was replaced, and the registry ALREADY records when that
  #     happened (`last_rotated`, stamped only by rotate/done, which refuse
  #     while declared copies disagree). If a record claims a discharge the
  #     rotation history does not corroborate, the debt was cleared by editing
  #     the file — which is the one way to defeat this whole mechanism.
  local expbad=0 expopen=0
  for ((i=0;i<n;i++)); do
    local xid nx j
    xid=$(field "$i" id); [ -z "$xid" ] && continue
    local xtag; xtag=$("$YQ" e ".secrets[$i].exposure | tag" "$REGISTRY" 2>/dev/null)
    case "$xtag" in
      '!!null'|"") continue ;;
      '!!seq') ;;
      *) print_error "EXPOSURE-SHAPE: $xid: exposure: must be a LIST of records (found $xtag)"
         expbad=$((expbad+1)); issues=$((issues+1)); continue ;;
    esac
    nx=$("$YQ" e ".secrets[$i].exposure | length" "$REGISTRY" 2>/dev/null); [ "$nx" = "null" ] && nx=0
    for ((j=0;j<nx;j++)); do
      local p="secrets[$i].exposure[$j]" tag
      local xat xhow xclosed xrot xsev xnw xrotat xclat
      xat=$("$YQ" e ".$p.at // \"\"" "$REGISTRY" 2>/dev/null)
      xhow=$("$YQ" e ".$p.how // \"\"" "$REGISTRY" 2>/dev/null)
      xsev=$("$YQ" e ".$p.severity // \"high\"" "$REGISTRY" 2>/dev/null)
      xrotat=$("$YQ" e ".$p.rotated_at // \"\"" "$REGISTRY" 2>/dev/null)
      xclat=$("$YQ" e ".$p.closed_at // \"\"" "$REGISTRY" 2>/dev/null)
      xnw=$("$YQ" e ".$p.where // [] | length" "$REGISTRY" 2>/dev/null)

      is_iso_date "$xat" || { print_error "EXPOSURE: $xid[$j]: at: must be YYYY-MM-DD (got: '${xat:-<missing>}')"; expbad=$((expbad+1)); issues=$((issues+1)); }
      [ -n "$xhow" ] || { print_error "EXPOSURE: $xid[$j]: how: is required — one line on how it leaked"; expbad=$((expbad+1)); issues=$((issues+1)); }
      [ "${xnw:-0}" -gt 0 ] 2>/dev/null || { print_error "EXPOSURE: $xid[$j]: where: needs at least one location"; expbad=$((expbad+1)); issues=$((issues+1)); }
      case " $EXPOSURE_SEVERITIES " in *" $xsev "*) ;; *) print_error "EXPOSURE: $xid[$j]: severity: '$xsev' not one of: $EXPOSURE_SEVERITIES"; expbad=$((expbad+1)); issues=$((issues+1)) ;; esac
      for tag in closed rotated; do
        local btag; btag=$("$YQ" e ".$p.$tag | tag" "$REGISTRY" 2>/dev/null)
        [ "$btag" = "!!bool" ] || { print_error "EXPOSURE: $xid[$j]: $tag: must be an explicit true/false (found ${btag:-missing}) — an unstated answer is not a 'no debt'"; expbad=$((expbad+1)); issues=$((issues+1)); }
      done
      for tag in "$xrotat" "$xclat"; do
        [ -z "$tag" ] && continue
        is_iso_date "$tag" || { print_error "EXPOSURE: $xid[$j]: date '$tag' must be YYYY-MM-DD"; expbad=$((expbad+1)); issues=$((issues+1)); }
      done
      local wloc
      while IFS= read -r wloc; do
        [ -z "$wloc" ] && continue
        where_parse "$wloc" || { print_error "EXPOSURE-WHERE: $xid[$j]: unparseable location — '$wloc'"; expbad=$((expbad+1)); issues=$((issues+1)); }
      done < <("$YQ" e ".$p.where[]?" "$REGISTRY" 2>/dev/null)

      xclosed=$("$YQ" e ".$p.closed // false" "$REGISTRY" 2>/dev/null)
      xrot=$("$YQ" e ".$p.rotated // false" "$REGISTRY" 2>/dev/null)
      if [ "$xrot" = "true" ]; then
        local lastrot; lastrot=$(field "$i" last_rotated)
        if [ -z "$lastrot" ]; then
          print_error "EXPOSURE-UNBACKED: $xid[$j]: claims rotated: true but the entry has no last_rotated — no rotation was ever recorded"
          expbad=$((expbad+1)); issues=$((issues+1))
        elif [ -n "$xrotat" ] && [ "$lastrot" \< "$xrotat" ]; then
          print_error "EXPOSURE-UNBACKED: $xid[$j]: rotated_at $xrotat is AFTER the last recorded rotation ($lastrot)"
          expbad=$((expbad+1)); issues=$((issues+1))
        fi
      else
        expopen=$((expopen+1))
      fi
    done
  done
  if [ "$expbad" -gt 0 ]; then
    print_hint "record one properly:  pl secrets expose <id> --reason='…' --where=… [--closed]"
    where_grammar_help
  else
    print_success "every exposure record parses (or there are none)"
  fi
  if [ "$expopen" -gt 0 ]; then
    # NOT a lint issue: the record is well-formed, the DEBT is real work. It is
    # counted by `pl todo`, reddens `pl rag`, and refuses a prod bring-up.
    print_warning "EXPOSURE-DEBT: $expopen credential exposure(s) still owe a rotation — 'pl secrets debt'"
  fi

  echo
  [ "$issues" -eq 0 ] && print_success "LINT PASS — registry and .secrets.yml are consistent" \
    || { print_error "LINT: $issues issue(s) above"; return 1; }
}

################################################################################
# adopt — scaffold a registry entry for a .secrets.yml key that lint found
#         undeclared. Makes "register it" a command, not a hand-edit.
################################################################################
cmd_adopt(){
  need_yq; need_registry
  local key="${1:-}"; [ -n "$key" ] || die "usage: pl secrets adopt <dotted.key>|<path>:<ref>|host=<role>:<path>:<ref> [--as <id>]"
  local AS=""; shift || true
  while [ $# -gt 0 ]; do case "$1" in --as) AS="${2:-}"; shift 2;; *) shift;; esac; done

  # A credential that lives ONLY on another host was previously unadoptable: this
  # verb spoke .secrets.yml and nothing else, so the one live api-scoped token in
  # the estate that is not on this laptop could not be entered into the source of
  # record at all — the registry called it `not-provisioned` while it answered
  # the API. Adopting by location closes that.
  if [[ "$key" == host=* ]]; then
    [ -n "$AS" ] || die "adopting a remote location needs an id:  pl secrets adopt '$key' --as <id>"
    local akind ahost apath aref
    IFS=$'\x1f' read -r akind ahost apath aref < <(loc_parse "$key")
    [ -n "$ahost" ] || die "cannot parse host from '$key'"
    local already
    already=$("$YQ" e '.secrets[].stored_in[]?' "$REGISTRY" 2>/dev/null | grep -cxF "$key" || true)
    [ "${already:-0}" -gt 0 ] && die "$key is already declared by a registry entry — see: pl secrets status"

    # Refuse to record a location we cannot show exists. Hash only; the value
    # neither crosses the wire nor enters this process.
    local rcmd rh qp; qp=$(loc_remote_quoted "$apath")
    case "$akind" in
      env)  rcmd="grep -E '^(export )?$aref=' $qp | head -1 | sed -E 's/^(export )?$aref=//; s/^\"//; s/\"\$//' | tr -d '\\n' | sha256sum | cut -c1-16" ;;
      file) rcmd="head -1 $qp | tr -d '\\n' | sha256sum | cut -c1-16" ;;
      *)    die "cannot verify a '$akind' location on a remote host" ;;
    esac
    rh=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$ahost" "$rcmd" 2>/dev/null)
    [ -n "$rh" ] || die "$ahost: unreachable — refusing to adopt a location we could not look at"
    loc_is_empty_hash "$rh" && die "$ahost: nothing readable at $apath${aref:+:$aref} — refusing to adopt a location that is not there"
    ID="$AS" LOC="$key" "$YQ" e -i '.secrets += [{
        "id": strenv(ID),
        "provider": "gitlab",
        "type": "TODO — describe what this credential is for",
        "scopes": [],
        "stored_in": [strenv(LOC)],
        "rotate_via": "manual",
        "rotate_url": "",
        "cadence_days": 365,
        "expires": "unknown",
        "last_rotated": "",
        "owner": "operator",
        "status": "adopted-needs-review",
        "notes": "Adopted by `pl secrets adopt` from a remote location — fill in type/scopes/rotate_url and add a probe: before the next rotation."
      }]' "$REGISTRY" || die "failed to write registry"
    print_success "adopted $key as registry entry '$AS' (status: adopted-needs-review)"
    print_hint "now give it a checkable scope:  pl secrets probe-scaffold $AS   ·   verify:  pl secrets lint"
    return 0
  fi

  # A credential that is a FILE ON THIS HOST rather than a `.secrets.yml` key
  # was also unadoptable: this verb spoke only dotted keys, so the estate's own
  # live-box ssh key — the one `servers/live/.nwp-server.yml` names, and which
  # `pl server health` / `pl drush --tier=live` ride on — could not be entered
  # into the source of record at all. It was therefore undeclared on EVERY host
  # that held it. Adopting by local location closes that direction, and lets one
  # entry name both the canonical and the remote copy so `verify-copy` can
  # actually compare them.
  if [[ "$key" == *:* ]] && [[ "$key" != host=* ]] && [[ "$key" != external:* ]]; then
    local lkind lhost lpath lref
    IFS=$'\x1f' read -r lkind lhost lpath lref < <(loc_parse "$key")
    [ "$lkind" = "bad" ] && die "does not parse as <path>:<ref>: '$key'"
    [ -n "$lhost" ] && die "internal: host= should have been handled above"
    local labs; labs=$(loc_abspath "$lpath")
    [ -f "$labs" ] || die "$labs does not exist — refusing to adopt a location that is not there"
    loc_read "$lkind" "$labs" "$lref" >/dev/null \
      || die "nothing readable at $key — refusing to adopt a location the tooling cannot check"
    if [ "$( { "$YQ" e '.secrets[].stored_in[]?' "$REGISTRY" 2>/dev/null || true; } | grep -cxF "$key" || true)" -gt 0 ]; then
      die "$key is already declared by a registry entry — see: pl secrets status"
    fi
    local lid; lid="${AS:-$(printf '%s' "$lpath" | tr -c 'a-zA-Z0-9' '_' | sed 's/__*/_/g; s/^_//; s/_$//')}"
    ID="$lid" LOC="$key" "$YQ" e -i '.secrets += [{
        "id": strenv(ID),
        "provider": "local",
        "type": "TODO — describe what this credential is for",
        "scopes": [],
        "stored_in": [strenv(LOC)],
        "rotate_via": "manual",
        "rotate_url": "",
        "cadence_days": 365,
        "expires": "unknown",
        "last_rotated": "",
        "owner": "operator",
        "status": "adopted-needs-review",
        "notes": "Adopted by `pl secrets adopt` from a LOCAL file location — fill in type/scopes and add a probe: before the next rotation."
      }]' "$REGISTRY" || die "failed to write registry"
    print_success "adopted $key as registry entry '$lid' (status: adopted-needs-review)"
    print_hint "declare its copies:  pl secrets provision $lid --to 'host=<role>:<path>:<ref>'   ·   verify: pl secrets verify-copy $lid"
    return 0
  fi

  local len; len=$("$YQ" e "(.$key // \"\") | length" "$SECRETS_FILE" 2>/dev/null)
  [ "${len:-0}" -eq 0 ] && die "$key is empty or missing in $SECRETS_FILE — nothing to adopt"
  # NOT `yq | grep -q && die`: with `set -o pipefail` (line 2), grep -q exits at
  # the FIRST match, the still-writing yq takes SIGPIPE, the pipeline reports 141
  # and the `&&` never fires — so the guard silently lets a duplicate through.
  # It reproduces on the CI runner and not on a fast local disk, which is exactly
  # the shape of bug a gate must not have. Buffer first, then match.
  if [ "$( { "$YQ" e '.secrets[].stored_in[]?' "$REGISTRY" 2>/dev/null || true; } | grep -cxF ".secrets.yml:$key" || true)" -gt 0 ]; then
    die "$key is already declared by a registry entry"
  fi
  local id; id="${AS:-$(printf '%s' "$key" | tr '.' '_')}"
  local prov="${key%%.*}"
  ID="$id" PROV="$prov" KEY="$key" "$YQ" e -i '.secrets += [{
      "id": strenv(ID),
      "provider": strenv(PROV),
      "type": "TODO — describe what this credential is for",
      "scopes": [],
      "stored_in": ["\.secrets\.yml:" + strenv(KEY)],
      "rotate_via": "manual",
      "rotate_url": "",
      "cadence_days": 365,
      "expires": "unknown",
      "last_rotated": "",
      "owner": "operator",
      "status": "adopted-needs-review",
      "notes": "Adopted by `pl secrets adopt` — fill in type/scopes/rotate_url before the next rotation."
    }]' "$REGISTRY" || die "failed to write registry"
  # yq strenv concat above escapes oddly on some versions; normalise the location
  local last; last=$(( $("$YQ" e '.secrets | length' "$REGISTRY") - 1 ))
  KEY="$key" "$YQ" e -i ".secrets[$last].stored_in = [\".secrets.yml:\" + strenv(KEY)]" "$REGISTRY"
  print_success "adopted $key as registry entry '$id' (status: adopted-needs-review)"
  print_hint "now fill it in:  pl secrets steps $id   ·   verify:  pl secrets lint"
}

################################################################################
# keys — show the STRUCTURE of .secrets.yml (key paths) WITHOUT exposing values
#         (this is the safe way for a human/agent to inspect shape; use instead
#          of `yq`-ing values directly)
################################################################################
cmd_keys(){
  need_yq
  [ -f "$SECRETS_FILE" ] || die "no .secrets.yml at $SECRETS_FILE"
  # registry-declared .secrets.yml keys → the tracked/untracked column
  local tracked
  tracked=$( { [ -f "$REGISTRY" ] && "$YQ" e '.secrets[].stored_in[]?' "$REGISTRY" 2>/dev/null; } \
      | grep -oE '^\.secrets\.yml:[A-Za-z0-9_.]+' | sed 's/^\.secrets\.yml://' | sort -u )

  print_header "secrets structure — $SECRETS_FILE  (key paths only, NO values)"
  printf "  %-30s %-12s %-5s %s\n" "KEY" "STATUS" "LEN" "REGISTRY"
  printf "  %-30s %-12s %-5s %s\n" "------------------------------" "------------" "-----" "--------"
  local key len ph st col reg
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    # length + placeholder test are evaluated INSIDE yq — the value never leaves it
    len=$("$YQ" e "(.$key // \"\") | length" "$SECRETS_FILE" 2>/dev/null); len=${len:-0}
    ph=$("$YQ" e "(.$key // \"\") | test(\"(?i)paste|changeme|todo|xxxx+|placeholder|^<.*>$\")" "$SECRETS_FILE" 2>/dev/null)
    if   [ "${len:-0}" -eq 0 ];  then st="empty";       col="$DIM"
    elif [ "$ph" = "true" ];      then st="placeholder"; col="$YELLOW"
    else                               st="set";         col="$GREEN"; fi
    if printf '%s\n' "$tracked" | grep -qxF "$key"; then reg="tracked"; else reg="${YELLOW}untracked${NC}"; fi
    printf "  %-30s ${col}%-12s${NC} %-5s %b\n" "$key" "$st" "$len" "$reg"
  done < <("$YQ" e '.. | select(tag == "!!str") | path | join(".")' "$SECRETS_FILE" 2>/dev/null)
  echo
  # registry-declared keys MISSING from the file (gaps lint would also flag)
  local miss=0 k
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    [ "$("$YQ" e "(.$k // \"__M__\")" "$SECRETS_FILE" 2>/dev/null)" = "__M__" ] \
      && { print_warning "declared in registry but missing here: $k"; miss=1; }
  done <<<"$tracked"
  [ "$miss" = 0 ] && print_info "every registry-declared key exists in the file"
  print_hint "store a value safely: pl secrets set <dotted.key>  ·  fill gaps: pl secrets scaffold"
}

################################################################################
# set — store a value at a dotted key via HIDDEN entry (never echoed/logged/argv)
################################################################################
cmd_set(){
  need_yq
  local key="${1:-}"; [ -n "$key" ] || die "usage: pl secrets set <dotted.key>   e.g. gitlab.ops_note_token"
  [ -f "$SECRETS_FILE" ] || die "no .secrets.yml at $SECRETS_FILE"
  local curlen; curlen=$("$YQ" e "(.$key // \"\") | length" "$SECRETS_FILE" 2>/dev/null)
  if [ "${curlen:-0}" -gt 0 ]; then
    local a; read -r -p "  $key already set (${curlen} chars). Replace? [y/N] " a </dev/tty
    [[ "$a" == [yY]* ]] || { print_warning "unchanged"; return 0; }
  fi
  local v=""; read -r -s -p "  paste value for $key (hidden, Enter to cancel): " v </dev/tty; echo
  [ -n "$v" ] || { print_warning "empty — nothing written"; return 0; }
  # value passed via env (strenv) so it never appears in argv / ps / history
  if v="$v" "$YQ" e -i ".$key = strenv(v)" "$SECRETS_FILE"; then
    local n="${#v}"; v=""
    chmod 600 "$SECRETS_FILE" 2>/dev/null || true
    print_success "stored $key (${n} chars) — value never printed"
  else
    v=""; die "yq write failed for $key"
  fi
  if [ -f "$REGISTRY" ] && [ "$( { "$YQ" e '.secrets[].stored_in[]?' "$REGISTRY" 2>/dev/null || true; } | grep -cxF ".secrets.yml:$key" || true)" -gt 0 ]; then
    print_hint "registry tracks this key — stamp the rotation: pl secrets done <#|id>"
  fi
  print_hint "verify: pl secrets keys   ·   leak check: pl secrets scan"
}

################################################################################
# scaffold — create any registry-declared .secrets.yml keys that are missing,
#            as empty placeholders ready for `pl secrets set` (never values)
################################################################################
cmd_scaffold(){
  need_yq; need_registry
  [ -f "$SECRETS_FILE" ] || die "no .secrets.yml at $SECRETS_FILE"
  local made=0 k
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    if [ "$("$YQ" e "(.$k // \"__M__\")" "$SECRETS_FILE" 2>/dev/null)" = "__M__" ]; then
      "$YQ" e -i ".$k = \"\"" "$SECRETS_FILE" && { print_success "created empty key: $k"; made=$((made+1)); }
    fi
  done < <("$YQ" e '.secrets[].stored_in[]?' "$REGISTRY" 2>/dev/null \
            | grep -oE '^\.secrets\.yml:[A-Za-z0-9_.]+' | sed 's/^\.secrets\.yml://' | sort -u)
  chmod 600 "$SECRETS_FILE" 2>/dev/null || true
  [ "$made" = 0 ] && print_info "nothing to scaffold — every registry-declared key already exists" \
    || print_hint "now fill them: pl secrets set <dotted.key>"
}

################################################################################
# audit — LIVE token validity + REAL expiry + drift, across EVERY declared
#         location (the daily-check engine).
#
#   The old implementation took `... | head -1` and probed only the FIRST
#   `.secrets.yml:` location of each entry. Every other declared copy — the 16
#   DDEV-mounted composer auth.json files, the agent-loop env token — was never
#   read, so a dead or drifted copy printed OK and exited 0. A registry that
#   records where a value lives, and then checks one of those places, is a
#   registry that lies by construction.
#
#   Now: canonical value is probed at the provider; EVERY declared location is
#   read and compared to canonical BY HASH (never by value, never printed);
#   a distinct value found in a copy is itself probed. Any DRIFT / DEAD /
#   MISSING / ABSENT / SCOPE-DRIFT counts as a problem and forces exit 1.
#
#   Flags: --days N (warn window, default 14) · --sync (write live expiry back
#          to the registry) · --quiet (machine output for cron) · --locations
#          (one row per location) · --json (machine envelope)
################################################################################
_audit_body(){ # url header-name value  -> response body (token only via 0600 cfg)
  local cfg; cfg=$(mktemp); chmod 600 "$cfg"
  printf 'silent\nmax-time = 12\nurl = "%s"\nheader = "%s: %s"\n' "$1" "$2" "$3" > "$cfg"
  curl -K "$cfg" 2>/dev/null; rm -f "$cfg"
}

# Same request, but the HTTP STATUS is not thrown away.
#
# WHY THIS EXISTS. `_audit_body` returns the body and discards the status, and
# `_probe_value` then said "no username in the body ⇒ DEAD". So EVERY non-200 —
# a 429 rate-limit, a 502 from the box, a 12-second timeout, a captive-portal
# HTML page — was rendered as `DEAD` / `REVOKED/INVALID`. Measured 2026-07-26:
# `gitlab_bot_ci_audit` was reported DEAD while the identical probe run again
# returned HTTP 200 with `username: project_11_bot_…`, i.e. a healthy
# project-access token on ops/verifier-log. The token was fine; the verdict was
# invented from a transient failure.
#
# That is the same defect as `--honesty` printing "clean" over a corpus it could
# not see, only inverted: here the tool asserts a DEFINITE NEGATIVE it has no
# evidence for. A credential audit that cries "revoked" at healthy tokens gets
# ignored exactly as fast as one that stays green over a dead one — and this
# audit runs daily from cron (scripts/secrets-daily-audit.sh).
#
# Echoes "<http_code>\n<body verbatim>". Read it with:
#     out="$(_audit_status_body …)"
#     code="${out%%$'\n'*}"    body="${out#*$'\n'}"
#
# STATUS FIRST, on its own line, and the body untouched after it. Two earlier
# shapes of this helper were wrong, and both are worth remembering:
#
#   1. "<code>\t<body>" with the body's newlines folded by `tr '\n' '\x01'`.
#      In single quotes that is the literal string \x01 and GNU tr has no \xNN
#      escape, so it translated the SET {\, x, 0, 1} to newline — every 0, 1
#      and x in the JSON became a line break, the body stopped parsing, and a
#      HEALTHY token probed as "unparseable body". A body is arbitrary bytes:
#      do not encode it.
#   2. Returning the body and passing the status in a global. `$( )` runs in a
#      SUBSHELL, so the global never reached the caller and EVERY probe read
#      "000". That reads as UNKNOWN — fail-safe, but it would have made the
#      whole audit permanently unverifiable.
#
# Status-first + "everything after the first newline" needs no encoding, no
# global and no subshell escape: the code is exactly three digits on line 1.
_audit_status_body(){ # url header-name value
  local cfg out code; cfg=$(mktemp); chmod 600 "$cfg"
  printf 'silent\nmax-time = 12\nurl = "%s"\nheader = "%s: %s"\nwrite-out = "\\n%%{http_code}"\n' \
    "$1" "$2" "$3" > "$cfg"
  out="$(curl -K "$cfg" 2>/dev/null)"; rm -f "$cfg"
  code="${out##*$'\n'}"                 # curl appends the status last…
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  printf '%s\n%s' "$code" "${out%$'\n'*}"   # …we re-emit it FIRST.
}

# Turn an HTTP status into a verdict about the CREDENTIAL.
#   200        -> OK        the provider accepted it
#   401 / 403  -> DEAD      the provider actively REJECTED it (revoked/expired)
#   anything   -> UNKNOWN   we did not get an answer about the credential at all
# 404 is UNKNOWN, not DEAD: `/personal_access_tokens/self` 404s for a PROJECT
# access token, which says nothing about whether the token works.
_audit_verdict(){ # http_code -> OK|DEAD|UNKNOWN
  case "$1" in
    200)     echo OK ;;
    401|403) echo DEAD ;;
    *)       echo UNKNOWN ;;
  esac
}
_audit_code(){ # url full-header-prefix value [method] -> http_code only
  # $4 (optional) is the HTTP method. It exists for the "create-without-creating"
  # idiom: POST an EMPTY body to a creating endpoint. A token that may not create
  # answers 401/403 at the authorization layer; a token that MAY create gets past
  # it and is then rejected at validation with 400 — because the body is empty, so
  # nothing is created. That distinguishes "can create MRs" from "cannot" without
  # ever creating an MR. Never wire a method that mutates on an empty body here
  # (no DELETE — the resource in the URL would be the thing destroyed).
  local cfg; cfg=$(mktemp); chmod 600 "$cfg"
  printf 'silent\noutput = "/dev/null"\nwrite-out = "%%{http_code}"\nmax-time = 12\nurl = "%s"\nheader = "%s %s"\n' "$1" "$2" "$3" > "$cfg"
  case "${4:-GET}" in
    GET|"") : ;;
    POST|PUT|PATCH|HEAD)
      printf 'request = "%s"\n' "${4}" >> "$cfg"
      # Explicitly empty body: this is what makes the probe non-mutating.
      [ "$4" = "POST" ] || [ "$4" = "PUT" ] || [ "$4" = "PATCH" ] && printf 'data = ""\n' >> "$cfg"
      ;;
    *) rm -f "$cfg"; printf '000'; return 0 ;;
  esac
  curl -K "$cfg" 2>/dev/null
  shred -u "$cfg" 2>/dev/null || rm -f "$cfg"
}

# Probe ONE value at its provider. Emits "LIVE<TAB>live_expires<TAB>note".
# LIVE ∈ OK | DEAD | SKIP.  The value is passed in memory and never printed.
_probe_value(){ # provider host value
  local prov="$1" host="$2" val="$3" live="SKIP" exp="" note=""
  case "$prov" in
    gitlab)
      if [ -z "$host" ]; then note="no host"; else
        local ucode ujson pjson uname active revoked isadmin
        local _u; _u="$(_audit_status_body "https://$host/api/v4/user" "PRIVATE-TOKEN" "$val")"
        ucode="${_u%%$'\n'*}"; ujson="${_u#*$'\n'}"; _u=""
        live="$(_audit_verdict "$ucode")"
        if [ "$live" = "UNKNOWN" ]; then
          note="no verdict (HTTP $ucode) "
        elif [ "$live" = "OK" ]; then
          uname=$("$YQ" e -p=json '.username // ""' <<<"$ujson" 2>/dev/null | grep -v '^null$')
          if [ -z "$uname" ]; then
            # 200 but unparseable — still not evidence of revocation.
            live="UNKNOWN"; note="no verdict (HTTP 200, unparseable body) "
          else
            # /personal_access_tokens/self is a PERSONAL-token endpoint; a
            # PROJECT access token 404s here. Only trust it when it answers 200.
            local pcode
            local _p; _p="$(_audit_status_body "https://$host/api/v4/personal_access_tokens/self" "PRIVATE-TOKEN" "$val")"
            pcode="${_p%%$'\n'*}"; pjson="${_p#*$'\n'}"; _p=""
            if [ "$pcode" = "200" ]; then
              active=$("$YQ" e -p=json '.active // ""' <<<"$pjson" 2>/dev/null)
              revoked=$("$YQ" e -p=json '.revoked // ""' <<<"$pjson" 2>/dev/null)
              exp=$("$YQ" e -p=json '.expires_at // ""' <<<"$pjson" 2>/dev/null | grep -v '^null$')
              [ "$revoked" = "true" ] || [ "$active" = "false" ] && live="DEAD"
            fi
            isadmin=$("$YQ" e -p=json '.is_admin // ""' <<<"$ujson" 2>/dev/null | grep -v '^null$')
            [ "$isadmin" = "true" ] && note="ADMIN "
          fi
        fi
      fi ;;
    github) live="$(_audit_verdict "$(_audit_code "https://api.github.com/user" "Authorization: Bearer" "$val")")"
            [ "$live" = "UNKNOWN" ] && note="no verdict (transport/rate-limit) " ;;
    linode) live="$(_audit_verdict "$(_audit_code "https://api.linode.com/v4/profile" "Authorization: Bearer" "$val")")"
            [ "$live" = "UNKNOWN" ] && note="no verdict (transport/rate-limit) " ;;
    *) note="no live API (recorded-date only)" ;;
  esac
  printf '%s\t%s\t%s\n' "$live" "$exp" "$note"
}

# Scope reconciliation: assert the registry's declared capability against the
# provider. Registry entries carry
#   probe:
#     - { url: "https://<gitlab-host>/api/v4/projects", expect: 200, name: read-projects }
# and this reports SCOPE-DRIFT when reality disagrees with the record. The
# registry exists to record scope; a scope it never checks is folklore.
_probe_scopes(){ # idx provider value -> "" (ok) | "SCOPE-DRIFT(name exp!=got) …"
  local idx="$1" prov="$2" val="$3" np j url want got hdr out=""
  np=$("$YQ" e ".secrets[$idx].probe // [] | length" "$REGISTRY" 2>/dev/null)
  [ "${np:-0}" -eq 0 ] 2>/dev/null && return 0

  # ── ssh probes ────────────────────────────────────────────────────────────
  # Run BEFORE the provider gate, because the credentials that most need a
  # falsifiable scope claim are the ones with no HTTP surface at all. The
  # estate's live-box ssh key is the example: it is root-equivalent on the box
  # that holds the trust root, and until it was adopted it had neither a
  # registry entry nor any way to state — let alone check — where it does and
  # does not reach.
  #
  #   probe:
  #     - { name: reaches-live-box, ssh: <user>@<live-host>,
  #         key: ~/.ssh/<key>, expect_rc: 0 }
  #     - { name: must-not-reach-x, ssh: <user>@<other>, key: …, expect_rc: 255 }
  #
  # A NEGATIVE probe (expect_rc non-zero) is how a LIMIT gets recorded, so that
  # widening it goes red. Nothing is ever executed on the far side beyond
  # `true`; BatchMode means a key that is not accepted fails instead of
  # prompting. The credential VALUE is not passed to ssh — the probe names its
  # own key file, because for a keypair the "value" this registry can read is
  # the public half.
  local nssh=0
  for ((j=0;j<np;j++)); do
    local pssh pkey prc pname_s
    pssh=$("$YQ" e ".secrets[$idx].probe[$j].ssh // \"\"" "$REGISTRY" 2>/dev/null)
    [ -z "$pssh" ] || [ "$pssh" = "null" ] && continue
    nssh=$((nssh+1))
    pkey=$("$YQ" e ".secrets[$idx].probe[$j].key // \"\"" "$REGISTRY" 2>/dev/null)
    prc=$("$YQ" e ".secrets[$idx].probe[$j].expect_rc // 0" "$REGISTRY" 2>/dev/null)
    pname_s=$("$YQ" e ".secrets[$idx].probe[$j].name // \"probe$j\"" "$REGISTRY" 2>/dev/null)
    local -a sargs=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes)
    if [ -n "$pkey" ] && [ "$pkey" != "null" ]; then
      local kf="${pkey/#\~/$HOME}"
      # A probe whose key is not on this host cannot answer the question. Say
      # so rather than reporting the resulting 255 as a clean negative — "I
      # could not look" is not "it does not reach".
      [ -f "$kf" ] || { out="${out}PROBE-BLIND($pname_s key-absent) "; continue; }
      sargs+=(-o IdentitiesOnly=yes -i "$kf")
    fi
    ssh "${sargs[@]}" "$pssh" true >/dev/null 2>&1; got=$?
    [ "$got" = "$prc" ] || out="${out}SCOPE-DRIFT($pname_s want_rc=$prc got_rc=$got) "
  done
  # every probe on this entry was an ssh probe — no HTTP work to do
  [ "$nssh" -eq "$np" ] && { printf '%s' "$out"; return 0; }

  case "$prov" in
    gitlab) hdr="PRIVATE-TOKEN:" ;;
    github|linode) hdr="Authorization: Bearer" ;;
    *) printf '%s' "$out"; return 0 ;;
  esac
  for ((j=0;j<np;j++)); do
    url=$(expand_placeholders "$("$YQ" e ".secrets[$idx].probe[$j].url // \"\"" "$REGISTRY" 2>/dev/null)")
    want=$("$YQ" e ".secrets[$idx].probe[$j].expect // \"\"" "$REGISTRY" 2>/dev/null)
    local pname; pname=$("$YQ" e ".secrets[$idx].probe[$j].name // \"probe$j\"" "$REGISTRY" 2>/dev/null)
    [ -z "$url" ] || [ -z "$want" ] && continue
    local pmeth; pmeth=$("$YQ" e ".secrets[$idx].probe[$j].method // \"GET\"" "$REGISTRY" 2>/dev/null)
    got=$(_audit_code "$url" "$hdr" "$val" "$pmeth")
    [ "$got" = "$want" ] || out="${out}SCOPE-DRIFT($pname want=$want got=$got) "
  done
  printf '%s' "$out"
}

cmd_audit(){
  need_yq; need_registry
  command -v curl >/dev/null || die "curl required"
  local WARN=14 SYNC=0 QUIET=0 LOCS=0 JSON=0 OFFLINE=0
  while [ $# -gt 0 ]; do case "$1" in
    --days) WARN="${2:-14}"; shift 2;;
    --sync) SYNC=1; shift;;
    --quiet|-q) QUIET=1; shift;;
    --locations|--all-locations) LOCS=1; shift;;
    --offline|--no-probe) OFFLINE=1; LOCS=1; shift;;
    --json) JSON=1; QUIET=1; shift;;
    *) shift;; esac; done

  local host_default
  host_default=$("$YQ" e '.gitlab.server.domain // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  # Reachability gate: if the GitLab host is DOWN, do NOT probe — every gitlab token
  # would false-positive as DEAD. Exit 2 = transient (cron/todo treat as "retry later").
  # `--offline` answers the question that needs no network at all — "does every
  # declared location hold the same value?" — without spending a probe. The
  # provider rate-limits repeated auth probes and then answers 000, and a 000 is
  # not a verdict; a check that cannot be repeated safely gets run less often.
  #
  # The gate used to be a SINGLE 12s shot. On the 3.8 GB forge box — which serves
  # GitLab plus five live sites and is routinely slow under load — one slow reply
  # was indistinguishable from an outage, and an outage was indistinguishable from
  # "audited clean": the caller got a quiet exit and no alarm. So:
  #   · retry (default 3) with a short backoff before believing the host is down,
  #   · say AUDIT-BLIND out loud so the word appears in logs and in `pl todo`,
  #   · and NEVER stamp last_successful_audit while blind. That field is what lets
  #     every downstream surface distinguish "checked, clean" from "never checked".
  if [ "$OFFLINE" = 0 ] && [ -n "$host_default" ]; then
    local _tries="${NWP_SECRETS_AUDIT_RETRIES:-3}" _backoff="${NWP_SECRETS_AUDIT_BACKOFF:-3}"
    local _rc="000" _t
    for ((_t=1; _t<=_tries; _t++)); do
      _rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$host_default/api/v4/metadata" 2>/dev/null)
      [ "$_rc" != "000" ] && break
      [ "$_t" -lt "$_tries" ] && sleep "$_backoff"
    done
    if [ "$_rc" = "000" ]; then
      if [ "$JSON" = 1 ]; then
        jq -n --arg h "$host_default" --argjson t "$_tries" \
          '{state:"AUDIT-BLIND",host:$h,attempts:$t,problems:null,entries:[]}'
      else
        print_error "AUDIT-BLIND: $host_default did not answer in $_tries attempt(s) — not probing (would report every token DEAD)."
        print_hint "this is a STATE, not a pass: last_successful_audit is unchanged. Downstream surfaces must grade AMBER, not GREEN."
      fi
      return 2
    fi
  fi

  if [ "$QUIET" = 0 ]; then
    print_header "Live token audit — every declared location, values never printed"
    printf "  %-26s %-7s %-9s %-12s %-12s %s\n" "ID" "PROV" "LIVE" "EXPIRES" "RECORDED" "NOTE"
    printf "  %-26s %-7s %-9s %-12s %-12s %s\n" "--------------------------" "-------" "---------" "------------" "------------" "----"
  fi

  local n i problems=0 dead=0 expiring=0 drift=0 badloc=0 unknown=0 jbuf=""
  n=$("$YQ" e '.secrets | length' "$REGISTRY"); [ "$n" = "null" ] && n=0
  for ((i=0;i<n;i++)); do
    local id prov st recorded canon canonval canonhash live liveexp note col d useexp host
    id=$(field "$i" id); prov=$(field "$i" provider); st=$(field "$i" status); recorded=$(field "$i" expires)
    [ "$st" = "not-provisioned" ] && continue

    host=$(field "$i" rotate_url | sed -E 's|https?://([^/]+).*|\1|')
    { [ -z "$host" ] || [ "$host" = "$(field "$i" rotate_url)" ]; } && host="$host_default"

    canon=$(entry_canonical_loc "$i")
    live="SKIP"; liveexp=""; note=""; canonval=""; canonhash=""
    local ckind chost cpath cref crc
    if [ -n "$canon" ]; then
      IFS=$'\x1f' read -r ckind chost cpath cref < <(loc_parse "$canon")
      if [ "$ckind" = "bad" ] || [ "$ckind" = "external" ]; then
        note="canonical location not machine-readable"
      else
        canonval=$(loc_read "$ckind" "$(loc_abspath "$cpath")" "$cref"); crc=$?
        case "$crc" in
          3) live="MISSING"; note="canonical file absent: $cpath" ;;
          4) live="EMPTY";   note="not provisioned" ;;
          5) live="SKIP";    note="reader unavailable" ;;
        esac
      fi
    else
      note="value not on this host"
    fi

    if [ -n "$canonval" ] && [ "$OFFLINE" = 1 ]; then
      canonhash=$(loc_hash "$canonval")
      live="OFFLINE"; note="not probed (--offline) "
    elif [ -n "$canonval" ]; then
      canonhash=$(loc_hash "$canonval")
      local nsc; nsc=$("$YQ" e ".secrets[$i].scopes // [] | length" "$REGISTRY" 2>/dev/null)
      if [ "${nsc:-0}" -eq 0 ]; then
        live="SKIP"; note="no API scope (password/app cred — recorded-date only)"
      else
        IFS=$'\t' read -r live liveexp _n < <(_probe_value "$prov" "$host" "$canonval")
        note="${note}${_n}"
        local sd; sd=$(_probe_scopes "$i" "$prov" "$canonval")
        [ -n "$sd" ] && { note="${note}${sd}"; problems=$((problems+1)); }
      fi
      # An admin-capable token is a hard failure unless the entry says so out loud.
      if [[ "$note" == *"ADMIN"* ]] && [ "$(field "$i" allow_admin)" != "true" ]; then
        note="ADMIN-NOT-ALLOWED ${note}"; problems=$((problems+1))
      fi
    fi

    # ---- every declared location, compared to canonical BY HASH -------------
    local -a lrows=(); local loc lkind lhost lpath lref lval lrc lstat lhash lrc2
    while IFS= read -r loc; do
      [ -z "$loc" ] && continue
      IFS=$'\x1f' read -r lkind lhost lpath lref < <(loc_parse "$loc")
      lstat=""; lhash=""
      case "$lkind" in
        external) lstat="EXTERNAL" ;;
        bad)      lstat="UNPARSEABLE"; badloc=$((badloc+1)); problems=$((problems+1)) ;;
        *)
          if [ -n "$lhost" ]; then
            lstat="REMOTE"    # checked by `pl secrets verify-copy` (hash over ssh)
          else
            lval=$(loc_read "$lkind" "$(loc_abspath "$lpath")" "$lref"); lrc=$?
            case "$lrc" in
              0) lhash=$(loc_hash "$lval")
                 if [ -z "$canonhash" ]; then lstat="UNVERIFIED"
                 elif [ "$lhash" = "$canonhash" ]; then lstat="OK"
                 else
                   lstat="DRIFT"; drift=$((drift+1)); problems=$((problems+1))
                   # a drifted copy may ALSO be revoked — that is the composer case
                   if [ "$OFFLINE" = 0 ] && [ "${nsc:-0}" -gt 0 ] 2>/dev/null; then
                     IFS=$'\t' read -r lrc2 _ _ < <(_probe_value "$prov" "$host" "$lval")
                     [ "$lrc2" = "DEAD" ] && { lstat="DRIFT/DEAD"; dead=$((dead+1)); }
                   fi
                 fi ;;
              3) lstat="MISSING"; problems=$((problems+1)) ;;
              4) lstat="ABSENT";  problems=$((problems+1)) ;;
              5) lstat="NOREADER" ;;
            esac
            lval=""
          fi ;;
      esac
      lrows+=("${lstat}"$'\t'"${loc}"$'\t'"${lhash:--}")
    done < <(entry_locations "$i")
    canonval=""

    useexp="$liveexp"; [ -z "$useexp" ] && useexp="$recorded"
    d=$(days_until "$useexp")
    if [ -n "$liveexp" ] && [ -n "$recorded" ] && [ "$recorded" != "unknown" ] && [ "$liveexp" != "$recorded" ]; then
      note="${note}DRIFT(rec=$recorded) "; problems=$((problems+1))
      [ "$SYNC" = 1 ] && { "$YQ" e -i ".secrets[$i].expires = \"$liveexp\"" "$REGISTRY" && note="${note}[synced] "; }
    fi
    case "$live" in
      DEAD)    col="$RED"; dead=$((dead+1)); problems=$((problems+1)); note="REVOKED/INVALID ${note}" ;;
      # UNKNOWN is NOT dead and NOT ok. The provider did not answer the question,
      # so neither a green tick nor "REVOKED/INVALID" would be true. Surfaced in
      # yellow and counted separately; it drives exit 2 (cannot verify), never
      # exit 0 — a probe nobody could run must not read as a passing audit.
      UNKNOWN) col="$YELLOW"; unknown=$((unknown+1)) ;;
      MISSING) col="$RED"; problems=$((problems+1)) ;;
      OK)      if   [ -n "$d" ] && [ "$d" -lt 0 ]      2>/dev/null; then col="$RED";    note="EXPIRED ${note}";        expiring=$((expiring+1)); problems=$((problems+1))
               elif [ -n "$d" ] && [ "$d" -le "$WARN" ] 2>/dev/null; then col="$YELLOW"; note="expires in ${d}d ${note}"; expiring=$((expiring+1)); problems=$((problems+1))
               else col="$GREEN"; fi ;;
      *)       col="$DIM" ;;
    esac

    # location summary always shown when anything is wrong — a problem can never
    # be hidden behind the entry-level row.
    local nloc=0 nbad=0 r
    for r in "${lrows[@]:-}"; do
      [ -z "$r" ] && continue; nloc=$((nloc+1))
      case "${r%%$'\t'*}" in OK|EXTERNAL|REMOTE|UNVERIFIED) ;; *) nbad=$((nbad+1)) ;; esac
    done

    if [ "$JSON" = 1 ]; then
      local jl="" first=1
      for r in "${lrows[@]:-}"; do
        [ -z "$r" ] && continue
        [ "$first" = 1 ] || jl="${jl},"; first=0
        local _rest="${r#*$'\t'}"
        jl="${jl}$(jq -cn --arg s "${r%%$'\t'*}" --arg l "${_rest%$'\t'*}" --arg h "${_rest##*$'\t'}" \
                     '{status:$s,location:$l,hash:$h}')"
      done
      [ -n "$jbuf" ] && jbuf="${jbuf},"
      jbuf="${jbuf}$(jq -cn --arg id "$id" --arg prov "$prov" --arg live "$live" \
        --arg exp "$liveexp" --arg rec "$recorded" --arg note "$note" \
        --argjson locs "[${jl}]" \
        '{id:$id,provider:$prov,live:$live,live_expires:$exp,recorded_expires:$rec,note:$note,locations:$locs}')"
    elif [ "$QUIET" = 0 ]; then
      printf "  ${col}%-26s${NC} %-7s ${col}%-9s${NC} %-12s %-12s %s\n" \
        "$id" "$prov" "$live" "${liveexp:--}" "${recorded:-unknown}" "${note}${nbad:+ [${nbad}/${nloc} locations bad]}"
      for r in "${lrows[@]:-}"; do
        [ -z "$r" ] && continue
        # row is "<status>\t<location>\t<hash-prefix>". The hash is a 64-bit
        # SHA-256 prefix, printed so a human can verify propagation without the
        # value ever being displayed, logged or put on a clipboard.
        local rs="${r%%$'\t'*}" rest="${r#*$'\t'}" rl rh
        rl="${rest%$'\t'*}"; rh="${rest##*$'\t'}"
        case "$rs" in
          OK|EXTERNAL|REMOTE|UNVERIFIED) [ "$LOCS" = 1 ] && printf "      ${DIM}%-12s %-16s %s${NC}\n" "$rs" "$rh" "$rl" ;;
          *)                             printf "      ${RED}%-12s${NC} %-16s %s\n" "$rs" "$rh" "$rl" ;;
        esac
      done
    elif [ "$live" = "DEAD" ] || [ "$nbad" -gt 0 ] || { [ "$live" = "OK" ] && [ -n "$d" ] && [ "$d" -le "$WARN" ] 2>/dev/null; }; then
      printf '%s\t%s\t%s\t%s\n' "$id" "$live" "${useexp:-unknown}" "${nbad} bad location(s) ${note}"
    fi
  done

  if [ "$JSON" = 1 ]; then
    jq -n --argjson e "[${jbuf}]" --argjson p "$problems" \
      '{problems:$p,entries:$e}'
  elif [ "$QUIET" = 0 ]; then
    echo; printf "  %d dead · %d unverifiable · %d expiring(≤%dd) · %d drifted location(s) · %d unparseable location(s)\n" \
      "$dead" "$unknown" "$expiring" "$WARN" "$drift" "$badloc"
    if [ "$problems" -gt 0 ]; then
      print_hint "propagate canonical to every location: pl secrets sync <id>   ·   reissue: pl secrets steps <id>"
    elif [ "$unknown" -gt 0 ]; then
      print_warning "CANNOT VERIFY ${unknown} token(s) — the provider gave no verdict (rate-limit, 5xx or timeout)."
      print_hint    "This is NOT a clean audit. Re-run when the provider is answering; nothing here says a token is bad."
    else
      print_success "every token valid, and every declared location matches canonical"
    fi
  fi

  # We got all the way here, which means the provider ANSWERED. Record it. This
  # is the difference between "audited clean" and "never checked" — without the
  # stamp, a fleet that has been blind for a fortnight is indistinguishable from
  # one that was verified this morning. Findings do not suppress the stamp: an
  # audit that found problems is still an audit that RAN.
  #
  # But UNKNOWN entries do suppress it. This branch's own rule is "never stamp
  # last_successful_audit while blind", and main has since added a FINER-GRAINED
  # blindness than the whole-host one this branch knew about: `unknown` counts
  # tokens the provider gave no verdict on (rate-limit, 5xx, timeout). That is
  # the same blindness per token, so it gets the same answer. Stamping a
  # "successful audit" over tokens nobody managed to check is the exact lie both
  # halves of this merge exist to remove.
  if [ "$unknown" -eq 0 ]; then
    local _now; _now=$(date -u +%FT%TZ)
    NWP_AUDIT_STAMP="$_now" "$YQ" e -i '.last_successful_audit = strenv(NWP_AUDIT_STAMP)' "$REGISTRY" 2>/dev/null || true
  fi

  # 1 = a real problem · 2 = cannot verify · 0 = verified clean.
  [ "$problems" -gt 0 ] && return 1
  [ "$unknown"  -gt 0 ] && return 2
  return 0
}

################################################################################
# sync — rewrite EVERY declared location from the canonical value.
#   `rotate` already wrote all locations; nothing re-asserted it afterwards, so
#   the estate drifted silently. This is the repair verb `audit` points at.
################################################################################
cmd_sync(){
  need_yq; need_registry
  local arg="${1:-}"; [ -n "$arg" ] || die "usage: pl secrets sync <#|id> [--dry-run]"
  local DRY=0; [ "${2:-}" = "--dry-run" ] && DRY=1
  local idx; if [[ "$arg" =~ ^[0-9]+$ ]]; then idx=$((arg-1)); else idx=$(registry_index_of "$arg"); fi
  { [ "$idx" = "-1" ] || [ -z "$(field "$idx" id)" ]; } && die "no such secret: $arg (see: pl secrets status)"
  local id canon ckind chost cpath cref canonval
  id=$(field "$idx" id); canon=$(entry_canonical_loc "$idx")
  [ -n "$canon" ] || die "$id: no machine-readable canonical location"
  IFS=$'\x1f' read -r ckind chost cpath cref < <(loc_parse "$canon")
  canonval=$(loc_read "$ckind" "$(loc_abspath "$cpath")" "$cref") \
    || die "$id: canonical location unreadable ($canon)"

  print_header "Sync $id — canonical: $canon"
  local loc lkind lhost lpath lref lval n_ok=0 n_write=0 n_skip=0 n_fail=0
  while IFS= read -r loc; do
    [ -z "$loc" ] && continue
    [ "$loc" = "$canon" ] && continue
    IFS=$'\x1f' read -r lkind lhost lpath lref < <(loc_parse "$loc")
    if [ "$lkind" = "external" ] || [ -n "$lhost" ]; then
      print_info "  SKIP     $loc  (not writable from here)"; n_skip=$((n_skip+1)); continue
    fi
    if [ "$lkind" = "bad" ]; then
      # An unparseable location is not a location we may quietly leave alone —
      # it is a declared copy the tooling has stopped checking.
      print_error "  BAD      $loc  (unparseable — pl secrets migrate-registry)"; n_fail=$((n_fail+1)); continue
    fi
    lval=$(loc_read "$lkind" "$(loc_abspath "$lpath")" "$lref")
    if [ "$lval" = "$canonval" ]; then lval=""; n_ok=$((n_ok+1)); continue; fi
    lval=""
    if [ "$DRY" = 1 ]; then
      # A dry run that cannot predict a failure is not a rehearsal. Check the
      # thing the real write will check.
      if [ ! -f "$(loc_abspath "$lpath")" ]; then
        print_error "  WOULD FAIL  $loc  -> $(loc_abspath "$lpath") does not exist"
        n_fail=$((n_fail+1))
      else
        print_info "  would update: $loc"; n_write=$((n_write+1))
      fi
      continue
    fi
    NWP_NEWVAL="$canonval" write_value_to_location "$loc"
    case $? in 0) n_write=$((n_write+1)) ;; 1) n_skip=$((n_skip+1)) ;; *) n_fail=$((n_fail+1)) ;; esac
  done < <(entry_locations "$idx")
  canonval=""
  printf "  %d already correct · %d %s · %d skipped · %d FAILED\n" \
    "$n_ok" "$n_write" "$([ "$DRY" = 1 ] && echo 'would update' || echo updated)" "$n_skip" "$n_fail"
  [ "$n_skip" -gt 0 ] && print_hint "remote/external copies: pl secrets verify-copy $id"
  # `audit` tells the operator to run `sync`. If `sync` can return 0 having
  # written nothing, the tool's own remedy is a silent no-op and the audit
  # finding survives untouched — which is exactly what happened when every
  # relative path resolved against $PWD.
  if [ "$n_fail" -gt 0 ]; then
    print_error "$id: $n_fail declared location(s) could NOT be written — canonical has NOT been propagated everywhere."
    return 1
  fi
  [ "$DRY" = 1 ] && { print_info "$id: dry run — nothing was written"; return 0; }
  print_success "$id: every writable declared location now holds the canonical value"
  return 0
}

# Are every machine-readable local location and canonical in agreement?
# rc 0 = yes.  Used by `done` so a rotation cannot be RECORDED without having
# been PROPAGATED — the registry may not claim a state the estate is not in.
entry_locations_in_sync(){ # idx  -> 0 in sync, 1 drift (names printed on stderr)
  local idx="$1" canon ckind chost cpath cref canonval loc lkind lhost lpath lref lval bad=0
  canon=$(entry_canonical_loc "$idx"); [ -n "$canon" ] || return 0
  IFS=$'\x1f' read -r ckind chost cpath cref < <(loc_parse "$canon")
  canonval=$(loc_read "$ckind" "$(loc_abspath "$cpath")" "$cref") || return 0
  while IFS= read -r loc; do
    [ -z "$loc" ] && continue
    [ "$loc" = "$canon" ] && continue
    IFS=$'\x1f' read -r lkind lhost lpath lref < <(loc_parse "$loc")
    { [ "$lkind" = "external" ] || [ "$lkind" = "bad" ] || [ -n "$lhost" ]; } && continue
    lval=$(loc_read "$lkind" "$(loc_abspath "$lpath")" "$lref")
    if [ "$lval" != "$canonval" ]; then printf '%s\n' "$loc" >&2; bad=1; fi
    lval=""
  done < <(entry_locations "$idx")
  canonval=""
  return $bad
}

################################################################################
# migrate-registry — bring an existing registry up to the stored_in grammar and
#   the publishable host placeholders, IDEMPOTENTLY.
#
#   Shipped as a verb, not performed as a one-off hand edit, for the reason the
#   whole programme exists: a transformation that lives only in somebody's shell
#   history is a transformation nobody can re-run, review or reverse. Run it
#   with --dry-run first; --apply writes a timestamped .bak beside the registry.
#
#   Rewrites, in order, per stored_in entry:
#     "<loc> (on <role>)"        -> host=<role>:<loc>
#     "live <host>:<path> (…)"   -> host=<host>:<path>:@file
#     "<path>" with no <ref>     -> <path>:@file
#     anything unparseable       -> external:<original text>
#   and lifts trailing parentheticals into stored_in_notes:.
################################################################################
normalise_location(){ # raw stored_in string -> canonical grammar
  local L="$1" note="" host="" base="$1" p r
  case "$L" in external:*|host=*) printf '%s' "$L"; return 0 ;; esac

  # lift ONE trailing parenthetical into $note
  if [[ "$base" =~ ^(.*[^[:space:]])[[:space:]]+\((.*)\)$ ]]; then
    base="${BASH_REMATCH[1]}"; note="${BASH_REMATCH[2]}"
  fi
  # "<loc> on <role>" / "(on the <role> host)" -> a host= qualifier
  if [[ "$base" =~ ^(.*[^[:space:]])[[:space:]]+on[[:space:]]+(the[[:space:]]+)?\`?([A-Za-z0-9_.-]+)\`?([[:space:]]+host)?$ ]]; then
    base="${BASH_REMATCH[1]}"; host="${BASH_REMATCH[3]}"
  elif [[ "$note" =~ (^|[[:space:]])on[[:space:]]+(the[[:space:]]+)?\`?([A-Za-z0-9_.-]+)\`?([[:space:]]+host)?([,[:space:]]|$) ]]; then
    host="${BASH_REMATCH[3]}"
  fi
  # "live <host>:<rest>" prefix
  if [[ "$base" =~ ^live[[:space:]]+([^[:space:]:]+):(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"; base="${BASH_REMATCH[2]}"
  fi
  # a bare path with no ref: the whole file IS the value.
  # NB '~/'* is QUOTED — bash tilde-expands an unquoted case pattern, so a bare
  # ~/* pattern silently becomes /home/<user>/* and never matches a literal '~'.
  case "$base" in
    /*|'~/'*) case "$base" in *:*) ;; *) base="${base}:@file" ;; esac ;;
  esac
  # final validation — a <path>:<ref> pair with no whitespace in either half.
  # Anything else is declared unverifiable rather than left to rot as a location
  # the tooling cannot read.
  case "$base" in *:*) p="${base%%:*}"; r="${base#*:}" ;; *) printf 'external:%s' "$L"; return 0 ;; esac
  case "${p}${r}" in *[[:space:]]*) printf 'external:%s' "$L"; return 0 ;; esac
  if [ -n "$host" ]; then printf 'host=%s:%s' "$host" "$base"; else printf '%s' "$base"; fi
}

cmd_migrate_registry(){
  need_yq; need_registry
  local APPLY=0 a
  for a in "$@"; do case "$a" in --apply) APPLY=1 ;; esac; done
  print_header "Registry migration — stored_in grammar + publishable host placeholders"
  if [ "$APPLY" = 1 ]; then
    cp -p "$REGISTRY" "${REGISTRY}.bak" || die "could not write ${REGISTRY}.bak — refusing to migrate"
    print_info "backup: ${REGISTRY}.bak"
  fi

  local n i changed=0
  n=$("$YQ" e '.secrets | length' "$REGISTRY"); [ "$n" = "null" ] && n=0
  for ((i=0;i<n;i++)); do
    local id j m loc new; id=$(field_raw "$i" id)
    m=$("$YQ" e ".secrets[$i].stored_in // [] | length" "$REGISTRY" 2>/dev/null)
    for ((j=0;j<m;j++)); do
      loc=$("$YQ" e ".secrets[$i].stored_in[$j]" "$REGISTRY" 2>/dev/null)
      new=$(normalise_location "$loc")
      [ "$new" = "$loc" ] && continue
      changed=$((changed+1))
      printf "  %-26s\n    ${RED}- %s${NC}\n    ${GREEN}+ %s${NC}\n" "$id" "$loc" "$new"
      if [ "$APPLY" = 1 ]; then
        NEW="$new" "$YQ" e -i ".secrets[$i].stored_in[$j] = strenv(NEW)" "$REGISTRY"
        # the prose that used to live inside the location is preserved, not lost
        OLD="$loc" "$YQ" e -i ".secrets[$i].stored_in_notes = (.secrets[$i].stored_in_notes // []) + [strenv(OLD)]" "$REGISTRY"
      fi
    done
  done

  # host placeholders — so the registry can eventually carry history without
  # publishing the operator's live surfaces (docs/reference/role-vocabulary.md)
  local host_default hits=0
  host_default=$("$YQ" e '.gitlab.server.domain // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  if [ -n "$host_default" ]; then
    hits=$(grep -cF "$host_default" "$REGISTRY" 2>/dev/null || true)
    if [ "${hits:-0}" -gt 0 ]; then
      printf "  %d literal GitLab-host reference(s) -> <gitlab-host>\n" "$hits"
      [ "$APPLY" = 1 ] && perl -i -pe "s/\Q$host_default\E/<gitlab-host>/g" "$REGISTRY"
      changed=$((changed+hits))
    fi
  fi

  if [ "$("$YQ" e 'has("ignored_keys")' "$REGISTRY")" != "true" ]; then
    printf "  add ignored_keys: [] (the recorded-exemption list that lint reads)\n"
    [ "$APPLY" = 1 ] && "$YQ" e -i '.ignored_keys = []' "$REGISTRY"
    changed=$((changed+1))
  fi

  # Seed ignored_keys with the STRUCTURAL, non-credential keys only — hostnames,
  # ids, usernames, URLs. A lint that is red on day one with a page of
  # non-findings is a lint everybody learns to skip, so the noise is baselined
  # and the signal is left red. Deliberately NOT seeded: anything whose name
  # says credential (…password, …token, …key, …secret, …login). Those stay red
  # until `pl secrets adopt` records what they are.
  if [ -f "$SECRETS_FILE" ]; then
    local k tail seeded=0
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      tail="${k##*.}"
      case "$tail" in
        url|domain|ip|linode_id|ssh_user|username|user|admin_user) ;;
        *) continue ;;
      esac
      [ "$( { "$YQ" e '.secrets[].stored_in[]?' "$REGISTRY" 2>/dev/null || true; } | grep -cxF ".secrets.yml:$k" || true)" -gt 0 ] && continue
      [ "$( { "$YQ" e '.ignored_keys[]? // ""' "$REGISTRY" 2>/dev/null || true; } | grep -cxF "$k" || true)" -gt 0 ] && continue
      printf "  ignored_keys += %s (structural, not a credential)\n" "$k"
      [ "$APPLY" = 1 ] && K="$k" "$YQ" e -i '.ignored_keys += [strenv(K)]' "$REGISTRY"
      seeded=$((seeded+1)); changed=$((changed+1))
    done < <("$YQ" e '.. | select(tag == "!!str") | path | join(".")' "$SECRETS_FILE" 2>/dev/null)
    [ "$seeded" -gt 0 ] && print_info "baselined $seeded structural key(s); every credential-shaped key stays RED until adopted"
  fi

  echo
  if [ "$changed" -eq 0 ]; then print_success "registry already migrated — nothing to do"; return 0; fi
  if [ "$APPLY" = 1 ]; then
    print_success "$changed change(s) applied — backup at ${REGISTRY}.bak"
    print_hint "verify: pl secrets lint   then   pl secrets audit --locations"
  else
    print_warning "$changed change(s) NOT applied (dry-run). Re-run with --apply."
  fi
  return 0
}

################################################################################
# discover-copies — find copies of a registry-known credential that the registry
#   does NOT declare. `audit` proves the declared copies are right; this proves
#   there is nothing undeclared. (Four undeclared sites/nw1/** copies existed.)
#   Compares BY HASH; no value is ever printed or written anywhere.
################################################################################
cmd_discover_copies(){
  need_yq; need_registry
  command -v jq >/dev/null || die "jq required"
  local REMOTE=1 INCLUDE_PROD=0 a
  for a in "$@"; do case "$a" in
    --no-remote|--local-only) REMOTE=0;;
    --include-prod) INCLUDE_PROD=1;;
  esac; done
  print_header "Undeclared copies of registry-known credentials"

  # hash -> id  for every canonical value we can read
  local -A known=(); local -A declared=(); local -A declared_remote=(); local -A fleet=()
  local n i id canon ckind chost cpath cref v loc lkind lhost lpath lref
  n=$("$YQ" e '.secrets | length' "$REGISTRY"); [ "$n" = "null" ] && n=0

  # Pass 0: the fleet roster, collected INDEPENDENTLY of whether we can read the
  # entry's canonical value here. An entry whose canonical lives somewhere this
  # machine cannot read (a build host's loop env, an agent host's bot token) still
  # names a host, and that host must still be swept — against every hash we do
  # know. Folding this into the pass below meant precisely the remote-only entries
  # contributed no host, so the sweep visited 2 of 5 hosts and still reported
  # "no undeclared copies".
  for ((i=0;i<n;i++)); do
    while IFS= read -r loc; do
      [ -z "$loc" ] && continue
      IFS=$'\x1f' read -r lkind lhost lpath lref < <(loc_parse "$loc")
      [ -n "$lhost" ] || continue
      declared_remote["$lhost|$lpath|$lref"]=1
      fleet["$lhost"]=1
    done < <(entry_locations "$i")
  done

  for ((i=0;i<n;i++)); do
    id=$(field "$i" id); [ -z "$id" ] && continue
    canon=$(entry_canonical_loc "$i"); [ -z "$canon" ] && continue
    IFS=$'\x1f' read -r ckind chost cpath cref < <(loc_parse "$canon")
    { [ "$ckind" = "bad" ] || [ "$ckind" = "external" ] || [ -n "$chost" ]; } && continue
    v=$(loc_read "$ckind" "$(loc_abspath "$cpath")" "$cref") || continue
    known["$(loc_hash "$v")"]="$id"; v=""
    while IFS= read -r loc; do
      [ -z "$loc" ] && continue
      IFS=$'\x1f' read -r lkind lhost lpath lref < <(loc_parse "$loc")
      { [ "$lkind" = "external" ] || [ "$lkind" = "bad" ]; } && continue
      # Remote copies were rostered in pass 0 above.
      [ -n "$lhost" ] && continue
      declared["$(loc_abspath "$lpath")|$lref"]=1
    done < <(entry_locations "$i")
  done
  [ "${#known[@]}" -eq 0 ] && { print_warning "no readable canonical values — nothing to compare against"; return 0; }

  local found=0 f h key
  # composer auth.json copies anywhere under the tree
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    while IFS= read -r h; do
      [ -z "$h" ] && continue
      key="$f|$h"
      local hv; hv=$(jq -r --arg k "$h" '.["gitlab-token"][$k] // ""' "$f" 2>/dev/null)
      [ -z "$hv" ] && continue
      local hh; hh=$(loc_hash "$hv"); hv=""
      [ -z "${known[$hh]:-}" ] && continue
      local jref=".[\"gitlab-token\"][\"$h\"]"
      [ -n "${declared["$f|$jref"]:-}" ] && continue
      print_error "UNDECLARED  ${known[$hh]}  ->  ${f#$NWP_ROOT/}:$jref"
      found=$((found+1))
    done < <(jq -r '.["gitlab-token"] // {} | keys[]' "$f" 2>/dev/null)
  done < <(find "$NWP_ROOT/sites" -maxdepth 6 -name auth.json -not -path '*/vendor/*' 2>/dev/null)

  # env-style files holding a known value
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
      case "$line" in *=*) ;; *) continue ;; esac
      local vn="${line%%=*}"; vn="${vn#export }"
      local vv="${line#*=}"; vv="${vv%\"}"; vv="${vv#\"}"
      local vh; vh=$(loc_hash "$vv"); vv=""
      [ -z "${known[$vh]:-}" ] && continue
      [ -n "${declared["$f|$vn"]:-}" ] && continue
      print_error "UNDECLARED  ${known[$vh]}  ->  $f:$vn"
      found=$((found+1))
    done < "$f"
  done < <(printf '%s\n' "$HOME/.nwp-agent-loop.env" "$HOME/.nwp-agent-loop.env.local")

  # ---- fleet sweep -------------------------------------------------------
  # Until now this function only ever looked at the machine it ran on, so a copy
  # on a build/agent/deploy host could not be found even in principle — the loop above
  # `continue`d on any location carrying a host. That made "no undeclared copies
  # found" a statement about one laptop dressed up as a statement about the fleet.
  #
  # The hashing runs on the REMOTE. Only 64 hex characters ever cross the wire,
  # in the same direction verify-copy already sends them. No value is read into
  # this process, printed, or written anywhere.
  local unreachable=0
  if [ "$REMOTE" = "1" ] && [ "${#fleet[@]}" -gt 0 ]; then
    local rh rline rkind rpath rref rhash; local -A swept_mid=()
    # shellcheck disable=SC2016
    local sweep='
      # Emit the path HOME-RELATIVE ("~/.config/x.token"). The registry declares
      # locations in exactly that form, so emitting the expanded absolute form
      # made every correctly-declared remote copy look undeclared.
      rel() { case "$1" in "$HOME"/*) printf "~/%s" "${1#$HOME/}" ;; *) printf "%s" "$1" ;; esac; }
      for f in "$HOME"/.config/*.token "$HOME"/.config/*.tok; do
        [ -f "$f" ] || continue
        h=$(head -1 "$f" | tr -d "\n" | sha256sum | cut -d" " -f1)
        printf "file\037%s\037\037%s\n" "$(rel "$f")" "$h"
      done
      for f in "$HOME"/.nwp-agent-loop.env "$HOME"/.nwp-agent-loop.env.local "$HOME"/.netrc.nwp; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
          case "$line" in *=*) ;; *) continue ;; esac
          n=${line%%=*}; n=${n#export }
          v=${line#*=}; v=${v%\"}; v=${v#\"}
          [ -z "$v" ] && continue
          h=$(printf "%s" "$v" | sha256sum | cut -d" " -f1)
          printf "env\037%s\037%s\037%s\n" "$(rel "$f")" "$n" "$h"
        done < "$f"
      done'
    for rh in "${!fleet[@]}"; do
      # A bare IP in this estate is a production endpoint, not a fleet role.
      # CLAUDE.md: "No AI-run machine may hold a key that reaches a production
      # server" — a read-only hash sweep is still a connection, and this verb runs
      # unattended from cron. Named fleet roles only, unless the
      # operator asks for prod explicitly and is present to see it.
      if [[ "$rh" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$INCLUDE_PROD" != "1" ]; then
        print_warning "  SKIPPED (prod endpoint)  $rh — re-run with --include-prod to sweep it"
        unreachable=$((unreachable+1)); continue
      fi
      # Two ssh aliases for one machine (this estate has such a pair) would
      # otherwise sweep it twice and report its single, correctly-declared copy
      # as undeclared under the alias the registry does not happen to use.
      # Identity is the machine, not the name we reached it by.
      local rmid
      rmid=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$rh" 'cat /etc/machine-id 2>/dev/null' 2>/dev/null)
      if [ -n "$rmid" ] && [ -n "${swept_mid[$rmid]:-}" ]; then
        print_info "  $rh is the same machine as ${swept_mid[$rmid]} — already swept"
        continue
      fi
      [ -n "$rmid" ] && swept_mid["$rmid"]="$rh"

      print_info "  sweeping $rh …"
      local rout
      rout=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$rh" "$sweep" 2>/dev/null)
      if [ -z "$rout" ]; then
        # Say blindness out loud. A host we could not reach is not a host we
        # cleared; silently counting it as clean is the bug this item exists for.
        print_warning "  UNREACHABLE  $rh — swept nothing (NOT the same as clean)"
        unreachable=$((unreachable+1)); continue
      fi
      # \x1f, not \t: tab is IFS *whitespace*, so bash collapses a run of tabs
      # into ONE delimiter and an empty middle field (a file location has no ref)
      # shifts the hash into rref, leaving rhash empty — every row then fell out
      # at the emptiness guard and the sweep reported a clean fleet it had in fact
      # never compared. loc_parse already uses \x1f for this reason.
      while IFS=$'\x1f' read -r rkind rpath rref rhash; do
        [ -z "$rhash" ] && continue
        # The remote emits a full SHA-256; `known` is keyed by loc_hash, which is
        # that digest truncated to 16. Comparing the two forms silently matched
        # nothing — the sweep would have reported "no undeclared copies" on a
        # fleet it had genuinely searched, which is the exact failure mode this
        # item exists to remove. Narrow to the same form before comparing.
        rhash="${rhash:0:16}"
        [ -z "${known[$rhash]:-}" ] && continue
        # A whole-file location is spelled both ":@file" and with an empty ref in
        # the wild; treat them as the same location rather than reporting a
        # correctly-declared copy as undeclared.
        if [ -n "${declared_remote["$rh|$rpath|$rref"]:-}" ] \
        || [ -n "${declared_remote["$rh|$rpath|@file"]:-}" ] \
        || [ -n "${declared_remote["$rh|$rpath|"]:-}" ]; then continue; fi
        print_error "UNDECLARED  ${known[$rhash]}  ->  host=$rh:$rpath${rref:+:$rref}"
        found=$((found+1))
      done <<<"$rout"
    done
  fi

  if [ "$found" -eq 0 ]; then
    if [ "$unreachable" -gt 0 ]; then
      print_warning "no undeclared copies found HERE, but $unreachable fleet host(s) were unreachable"
      return 2
    fi
    print_success "no undeclared copies found"; return 0
  fi
  print_hint "declare them in the entry's stored_in (then \`pl secrets sync <id>\` keeps them true) — or delete the copy"
  return 1
}

################################################################################
# verify-copy — check a REMOTE declared location (host=<role>:…) by HASH over
#   ssh. The value never crosses the wire and is never printed on either end.
################################################################################
cmd_verify_copy(){
  need_yq; need_registry
  local arg="${1:-}"; [ -n "$arg" ] || die "usage: pl secrets verify-copy <#|id>"
  local idx; if [[ "$arg" =~ ^[0-9]+$ ]]; then idx=$((arg-1)); else idx=$(registry_index_of "$arg"); fi
  { [ "$idx" = "-1" ] || [ -z "$(field "$idx" id)" ]; } && die "no such secret: $arg"
  local id canon ckind chost cpath cref canonval canonhash
  id=$(field "$idx" id); canon=$(entry_canonical_loc "$idx")
  [ -n "$canon" ] || die "$id: no readable canonical location on this host"
  IFS=$'\x1f' read -r ckind chost cpath cref < <(loc_parse "$canon")
  canonval=$(loc_read "$ckind" "$(loc_abspath "$cpath")" "$cref") || die "$id: canonical unreadable"
  canonhash=$(printf '%s' "$canonval" | sha256sum | cut -d' ' -f1); canonval=""

  print_header "Remote copies of $id — compared by SHA-256, never by value"
  local loc lkind lhost lpath lref remote_cmd rhash problems=0 checked=0
  while IFS= read -r loc; do
    [ -z "$loc" ] && continue
    IFS=$'\x1f' read -r lkind lhost lpath lref < <(loc_parse "$loc")
    [ -n "$lhost" ] || continue
    checked=$((checked+1))
    local qpath; qpath=$(loc_remote_quoted "$lpath")
    case "$lkind" in
      file) remote_cmd="head -1 $qpath | tr -d '\\n' | sha256sum | cut -d' ' -f1" ;;
      env)  remote_cmd="grep -E '^(export )?$lref=' $qpath | head -1 | sed -E 's/^(export )?$lref=//; s/^\"//; s/\"\$//' | tr -d '\\n' | sha256sum | cut -d' ' -f1" ;;
      yaml) remote_cmd="yq e '.$lref // \"\"' $qpath | tr -d '\\n' | sha256sum | cut -d' ' -f1" ;;
      json) remote_cmd="jq -r '($lref) // \"\"' $qpath | tr -d '\\n' | sha256sum | cut -d' ' -f1" ;;
      *)    print_warning "  $lhost: cannot verify kind '$lkind'"; continue ;;
    esac
    rhash=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$lhost" "$remote_cmd" 2>/dev/null)
    if [ -z "$rhash" ]; then
      print_warning "  UNREACHABLE  $lhost — $lpath (cannot verify)"; problems=$((problems+1))
    elif loc_is_empty_hash "$rhash"; then
      # Absent is not the same as different. Saying DRIFT here sends the operator
      # to re-propagate a value to a path that does not exist.
      print_error "  ABSENT       $lhost:$lpath  (nothing readable there — declared location is wrong or the copy is gone)"
      problems=$((problems+1))
    elif [ "$rhash" = "$canonhash" ]; then
      print_success "  MATCH        $lhost:$lpath"
    else
      print_error   "  DRIFT        $lhost:$lpath  (remote value differs from canonical)"; problems=$((problems+1))
    fi
  done < <(entry_locations "$idx")
  [ "$checked" -eq 0 ] && { print_info "no host=… locations declared for $id"; return 0; }
  [ "$problems" -eq 0 ] && return 0 || return 1
}

################################################################################
# provision — put a credential ONTO another host, and DECLARE it in the same
#   step. The missing half of the registry contract.
#
#   Before this verb there was no `pl` way to give another host a credential.
#   `sync` parses the grammar, sees `host=…`, and prints "SKIP (not writable
#   from here)"; `write_value_to_location` returns 1 on every `host=` location
#   with "propagate there". So the only route was `scp` — and a hand-scp'd
#   secret is UNDECLARED BY CONSTRUCTION. That is not a hypothetical: it is the
#   defect already recorded against met (70 auth.json files plus a whole
#   .secrets.yml, 6 of 7 values byte-identical to live, invisible to
#   rotate/audit forever because nothing ever named them).
#
#   The contract here is that the write and the declaration are ONE operation:
#   · nothing is written unless the target is a parseable host= location;
#   · nothing is declared unless the write read back clean over ssh;
#   · a failed write rolls the declaration back, so the registry can never
#     claim a copy the estate does not have.
#
#   The value goes over ssh on STDIN, never in argv — it must not appear in
#   `ps` on either machine, nor in either shell history.
#
# THE PROD BOUNDARY (operator-stated 2026-08-02, permanent; ADR-0028):
#   The `ver` role owns prod, alone, and is offline by default. It is never fed
#   a credential by an AI-run host. The rule is *never*, not *not yet*.
#
#   Enforced two ways, both fail-closed:
#
#   (1) ALLOWLIST. A host is provisionable only if the registry names it in
#       `ai_provisionable_hosts:`. An estate that has declared nothing can
#       provision nothing. A denylist would have to be complete to be correct,
#       and the one time it is not is the time it matters; an allowlist is wrong
#       in the safe direction.
#
#   (2) PROD ROLES are refused even if someone allowlists them, so the two
#       lists cannot be edited into agreement by accident. No --force, no env
#       var, no config key gets past this — an escape hatch would make the
#       boundary a preference rather than a rule.
#
#   Host names themselves live in the operator's registry, not in this file:
#   the repo is the public-release track and refers to hosts by ROLE
#   (docs/reference/role-vocabulary.md).
################################################################################

# Prod-trust role labels. Refused unconditionally. The operator's registry may
# add its own host names under `prod_hosts:`; it can never remove these.
PROVISION_FORBIDDEN_ROLES="ver verifier signed-deploy prod-agent prod-cluster"

# Entry statuses that must not be spread to another machine: a credential on
# its way out, or one sitting in the wrong tier, is not one to make more copies
# of. Widening the blast radius of a token you are about to revoke is strictly
# worse than doing nothing.
PROVISION_FORBIDDEN_STATUS="RETIRED REVOKE-PENDING TIER-VIOLATION not-provisioned"

# Build the remote command that writes stdin into <path>:<ref>. Path and ref
# are not secret and may travel in argv; the VALUE never does — it arrives on
# stdin and is read into a shell variable on the far side.
provision_remote_write_cmd(){ # kind path ref -> command string
  local kind="$1" qp; qp=$(loc_remote_quoted "$2"); local ref="$3"
  local pre="set -eu; umask 077; d=\$(dirname $qp); [ -d \"\$d\" ] || mkdir -p \"\$d\";"
  case "$kind" in
    file) printf '%s cat > %s; chmod 600 %s' "$pre" "$qp" "$qp" ;;
    yaml) printf '%s [ -f %s ] || : > %s; chmod 600 %s; NWP_V=$(cat); export NWP_V; yq e -i %s.%s = strenv(NWP_V)%s %s' \
            "$pre" "$qp" "$qp" "$qp" "'" "$ref" "'" "$qp" ;;
    json) printf '%s [ -f %s ] || echo {} > %s; chmod 600 %s; NWP_V=$(cat); t=$(mktemp); jq --arg v "$NWP_V" %s%s = $v%s %s > "$t" && mv "$t" %s && chmod 600 %s' \
            "$pre" "$qp" "$qp" "$qp" "'" "$ref" "'" "$qp" "$qp" "$qp" ;;
    env)  printf '%s [ -f %s ] || : > %s; chmod 600 %s; NWP_V=$(cat); export NWP_V NWP_REF=%s; if grep -qE "^(export )?$NWP_REF=" %s; then perl -i -pe %ss/^(export\\s+)?\\Q$ENV{NWP_REF}\\E=.*/(defined($1) ? $1 : "") . "$ENV{NWP_REF}=\\"$ENV{NWP_V}\\""/e%s %s; else printf %s%%s="%%s"\\n%s "$NWP_REF" "$NWP_V" >> %s; fi' \
            "$pre" "$qp" "$qp" "$qp" "$(printf '%q' "$ref")" "$qp" "'" "'" "$qp" "'" "'" "$qp" ;;
    *)    return 1 ;;
  esac
}

# The read-back. Deliberately the SAME expression `verify-copy` uses, so a copy
# provisioned here and a copy audited later are judged by identical arithmetic.
provision_remote_hash_cmd(){ # kind path ref -> command string
  local kind="$1" qp; qp=$(loc_remote_quoted "$2"); local ref="$3"
  case "$kind" in
    file) printf "head -1 %s | tr -d '\\\\n' | sha256sum | cut -d' ' -f1" "$qp" ;;
    env)  printf "grep -E '^(export )?%s=' %s | head -1 | sed -E 's/^(export )?%s=//; s/^\"//; s/\"\$//' | tr -d '\\\\n' | sha256sum | cut -d' ' -f1" "$ref" "$qp" "$ref" ;;
    yaml) printf "yq e '.%s // \"\"' %s | tr -d '\\\\n' | sha256sum | cut -d' ' -f1" "$ref" "$qp" ;;
    json) printf "jq -r '(%s) // \"\"' %s | tr -d '\\\\n' | sha256sum | cut -d' ' -f1" "$ref" "$qp" ;;
    *)    return 1 ;;
  esac
}

cmd_provision(){
  need_yq; need_registry
  local arg="" TO="" ONLY_HOST="" APPLY=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --to)      TO="${2:-}"; shift 2 ;;
      --to=*)    TO="${1#--to=}"; shift ;;
      --host)    ONLY_HOST="${2:-}"; shift 2 ;;
      --host=*)  ONLY_HOST="${1#--host=}"; shift ;;
      --apply)   APPLY=1; shift ;;
      --dry-run|-n) APPLY=0; shift ;;
      --force)   print_warning "--force is not honoured by provision"; shift ;;
      -*)        die "unknown option: $1" ;;
      *)         [ -z "$arg" ] && arg="$1"; shift ;;
    esac
  done
  [ -n "$arg" ] || die "usage: pl secrets provision <#|id> [--to host=<role>:<path>:<ref>] [--host=<role>] [--apply]"

  local idx; if [[ "$arg" =~ ^[0-9]+$ ]]; then idx=$((arg-1)); else idx=$(registry_index_of "$arg"); fi
  { [ "$idx" = "-1" ] || [ -z "$(field "$idx" id)" ]; } && die "no such secret: $arg (see: pl secrets status)"

  local id status; id=$(field "$idx" id); status=$(field "$idx" status)
  local s; for s in $PROVISION_FORBIDDEN_STATUS; do
    [ "$status" = "$s" ] && die "$id: status is $status — refusing to make another copy of a credential that is on its way out or in the wrong tier. Fix the entry first."
  done

  # canonical, read here, never printed
  local canon ckind chost cpath cref canonval canonhash
  canon=$(entry_canonical_loc "$idx")
  [ -n "$canon" ] || die "$id: no machine-readable canonical location on this host"
  IFS=$'\x1f' read -r ckind chost cpath cref < <(loc_parse "$canon")
  [ -n "$chost" ] && die "$id: canonical lives on $chost, not here — provision from the host that holds it"
  canonval=$(loc_read "$ckind" "$(loc_abspath "$cpath")" "$cref") \
    || die "$id: canonical location unreadable ($canon)"
  canonhash=$(printf '%s' "$canonval" | sha256sum | cut -d' ' -f1)

  # Targets: an explicit --to (may be NEW), else every declared host= copy.
  local -a targets=(); local -a is_new=()
  if [ -n "$TO" ]; then
    case "$TO" in host=*) ;; *) canonval=""; die "--to must be a host= location (got '$TO'). A local copy is what \`pl secrets sync\` is for." ;; esac
    local tkind thost tpath tref
    IFS=$'\x1f' read -r tkind thost tpath tref < <(loc_parse "$TO")
    [ "$tkind" = "bad" ] && { canonval=""; die "--to does not parse as host=<role>:<path>:<ref>: '$TO'"; }
    targets+=("$TO")
    if entry_locations "$idx" | grep -qxF "$TO"; then is_new+=(0); else is_new+=(1); fi
  else
    local loc lkind lhost
    while IFS= read -r loc; do
      [ -z "$loc" ] && continue
      IFS=$'\x1f' read -r lkind lhost _ _ < <(loc_parse "$loc")
      [ -n "$lhost" ] || continue
      [ -n "$ONLY_HOST" ] && [ "$lhost" != "$ONLY_HOST" ] && continue
      targets+=("$loc"); is_new+=(0)
    done < <(entry_locations "$idx")
    if [ "${#targets[@]}" -eq 0 ]; then
      canonval=""
      print_info "$id: no host=… copies declared${ONLY_HOST:+ for $ONLY_HOST} — nothing to provision"
      print_hint "declare and write one:  pl secrets provision $id --to 'host=<role>:<path>:<ref>' --apply"
      return 0
    fi
  fi

  # The allowlist, read once. Absent/empty means nothing is provisionable —
  # an estate that has declared no agent host has not opted in to having one.
  local -a ALLOWED=(); local _a
  while IFS= read -r _a; do [ -n "$_a" ] && ALLOWED+=("$_a"); done \
    < <("$YQ" e '.ai_provisionable_hosts[]? // ""' "$REGISTRY" 2>/dev/null)

  print_header "Provision $id${APPLY:+}  ·  canonical: $canon"
  [ "$APPLY" = 0 ] && print_info "DRY RUN — nothing will be written or declared (add --apply)"

  local t n=0 fails=0
  for ((n=0; n<${#targets[@]}; n++)); do
    t="${targets[$n]}"
    local kind host path ref
    IFS=$'\x1f' read -r kind host path ref < <(loc_parse "$t")

    # ── the boundary. No flag reaches past this. ──────────────────────────────
    local h forbidden=0
    for h in $PROVISION_FORBIDDEN_ROLES; do [ "$host" = "$h" ] && forbidden=1; done
    while IFS= read -r h; do
      [ -n "$h" ] && [ "$host" = "$h" ] && forbidden=1
    done < <("$YQ" e '.prod_hosts[]? // ""' "$REGISTRY" 2>/dev/null)
    if [ "$forbidden" = 1 ]; then
      canonval=""
      print_error "  REFUSED  $t"
      print_error "  '$host' is prod territory (ADR-0028). An AI-run host does not provision it — the operator does, in person."
      print_error "  This refusal has no --force and no env override: the rule is never, not not-yet."
      return 1
    fi
    if ! printf '%s\n' "${ALLOWED[@]:-}" | grep -qxF "$host"; then
      canonval=""
      print_error "  REFUSED  $t"
      print_error "  '$host' is not in the registry's ai_provisionable_hosts: — refusing to push a credential to a host nobody declared provisionable."
      print_hint  "  if that is wrong, the operator adds it:  yq e -i '.ai_provisionable_hosts += [\"$host\"]' \$REGISTRY"
      return 1
    fi

    if [ "$APPLY" = 0 ]; then
      print_info "  would write + verify   $t"
      [ "${is_new[$n]}" = 1 ] && print_info "  would declare (new stored_in row)   $t"
      continue
    fi

    local wcmd hcmd rhash
    wcmd=$(provision_remote_write_cmd "$kind" "$path" "$ref") \
      || { print_error "  FAILED   $t  (no writer for kind '$kind')"; fails=$((fails+1)); continue; }
    hcmd=$(provision_remote_hash_cmd "$kind" "$path" "$ref")

    # The value crosses on stdin only.
    if ! printf '%s' "$canonval" | ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" "$wcmd" >/dev/null 2>&1; then
      print_error "  FAILED   $t  (remote write did not succeed — nothing declared)"
      fails=$((fails+1)); continue
    fi

    rhash=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" "$hcmd" 2>/dev/null)
    if [ -z "$rhash" ] || loc_is_empty_hash "$rhash"; then
      print_error "  UNVERIFIED  $t  (wrote, but read back nothing — NOT declaring a copy we cannot see)"
      fails=$((fails+1)); continue
    fi
    if [ "$rhash" != "$canonhash" ]; then
      print_error "  MISMATCH $t  (read-back differs from canonical — NOT declaring)"
      fails=$((fails+1)); continue
    fi

    if [ "${is_new[$n]}" = 1 ]; then
      IDX="$idx" LOC="$t" "$YQ" e -i '.secrets[env(IDX)|tonumber].stored_in += [strenv(LOC)]' "$REGISTRY" \
        || { print_error "  DECLARE FAILED  $t"; fails=$((fails+1)); continue; }
      print_success "  VERIFIED + DECLARED  $t"
    else
      print_success "  VERIFIED (already declared)  $t"
    fi
  done
  canonval=""

  if [ "$fails" -gt 0 ]; then
    print_error "$id: $fails target(s) failed — the registry declares only what was verified."
    return 1
  fi
  [ "$APPLY" = 0 ] && { print_info "$id: dry run — nothing written, nothing declared"; return 0; }
  print_success "$id: every target holds canonical and is declared in the registry"
  print_hint "confirm independently:  pl secrets verify-copy $id   ·   pl secrets audit --locations"
  return 0
}

################################################################################
# registry-track — put the source of record under version control, in the right
#   place. Answers the UNTRACKED-REGISTRY lint error with a command instead of a
#   paragraph of advice.
#
#   Why a NESTED repo and not the outer one: the registry holds no values, but it
#   does hold the whole estate topology — measured, 162 gitleaks findings, all
#   identity/hostname, zero credential. nwp/nwp is the public-release track and
#   carries rules specifically to keep operator IP / personal email / live domains
#   out of it. Committing the registry there would be the leakage gate's own
#   counterexample. private/.git keeps history and review; a private remote (an
#   operator step, since only the operator can choose it) supplies the second copy.
################################################################################
cmd_registry_track(){
  need_registry
  local regdir; regdir=$(dirname "$REGISTRY")
  local DRY=0 a; for a in "$@"; do case "$a" in --dry-run|-n) DRY=1;; esac; done

  # Refuse if the registry would land in the OUTER repo — that is the failure
  # mode this verb exists to prevent, so it must not be reachable by accident.
  local outer; outer=$(git -C "$regdir" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$outer" ] && [ ! -e "$regdir/.git" ] && ! git -C "$regdir" check-ignore -q "$REGISTRY" 2>/dev/null; then
    die "refusing: $REGISTRY is NOT ignored by the outer repo at $outer — tracking it there would publish the estate topology. Restore the private/* ignore first."
  fi

  print_header "registry-track — version control for $REGISTRY"
  if [ -e "$regdir/.git" ]; then
    print_info "$regdir is already a git repository"
  else
    if [ "$DRY" = 1 ]; then print_warning "--dry-run: would 'git init' $regdir"; else
      git -C "$regdir" init -q || die "git init failed in $regdir"
      print_success "initialised $regdir as its own repository"
    fi
  fi

  # Belt and braces: even inside the private repo, never track a VALUE file.
  local gi="$regdir/.gitignore"
  if [ "$DRY" = 0 ] && [ ! -f "$gi" ]; then
    cat > "$gi" <<'EOF'
# This repo holds the TOKENLESS registry and its rotation log — metadata only.
# Never a value. These denies are defence in depth, not the primary control.
.secrets.yml
.secrets.data.yml
*.token
*.key
*.pem
.token-audit-alert
.token-audit-blind
EOF
    print_success "wrote $gi (value files denied even here)"
  fi

  if [ "$DRY" = 1 ]; then
    print_warning "--dry-run: would add + commit secrets-registry.yml, rotation logs and token-consumers.md"
    return 0
  fi

  git -C "$regdir" add -- "$(basename "$REGISTRY")" .gitignore 2>/dev/null || true
  git -C "$regdir" add -- rotation-*.md token-consumers.md 2>/dev/null || true
  if git -C "$regdir" diff --cached --quiet 2>/dev/null; then
    print_info "nothing to commit — already up to date"
  else
    git -C "$regdir" commit -q -m "secrets: record the registry state ($(date -u +%F))" \
      && print_success "committed"
  fi

  if [ -z "$(git -C "$regdir" remote 2>/dev/null)" ]; then
    echo
    print_warning "OPERATOR ACTION: this repo has no remote, so there is still exactly one copy."
    print_warning "Add a PRIVATE remote — NOT nwp/nwp, which is the public-release track:"
    print_hint "  git -C $regdir remote add origin <private-url> && git -C $regdir push -u origin HEAD"
    return 0
  fi
  print_success "remote configured: $(git -C "$regdir" remote -v | head -1)"
}

################################################################################
# cron — provision the daily audit BY CODE.
#
#   CLAUDE.md asserts "a daily `pl secrets audit` catches dead/expiring tokens".
#   That was false: scripts/secrets-daily-audit.sh was installed on zero hosts,
#   and there was no verb to install it — only a comment in the script's header
#   telling a human to hand-edit a crontab. A control that exists only as an
#   instruction is not a control, and the estate had no way to tell whether it
#   was running anywhere.
#
#   install/status/remove are idempotent block rewrites on a MARKED region, so
#   re-running never duplicates the entry and `remove` never eats a neighbour's
#   line. --host=<role> installs on a remote role over ssh via server-resolver;
#   with no --host it targets this machine. --dry-run prints the crontab that
#   WOULD be written and touches nothing.
################################################################################
CRON_MARK_BEGIN="# >>> nwp secrets daily audit (pl secrets cron) >>>"
CRON_MARK_END="# <<< nwp secrets daily audit <<<"

_cron_block(){ # root schedule
  printf '%s\n%s %s/scripts/secrets-daily-audit.sh >> %s/logs/secrets-daily-audit.log 2>&1\n%s\n' \
    "$CRON_MARK_BEGIN" "$2" "$1" "$1" "$CRON_MARK_END"
}

cmd_cron(){
  local sub="${1:-status}"; shift || true
  local HOSTROLE="" DRY=0 SCHED="${NWP_SECRETS_CRON_SCHEDULE:-30 6 * * *}" a
  for a in "$@"; do case "$a" in
    --host=*)     HOSTROLE="${a#--host=}" ;;
    --schedule=*) SCHED="${a#--schedule=}" ;;
    --dry-run|-n) DRY=1 ;;
  esac; done

  # Resolve where the estate checkout lives on the TARGET. Locally that is
  # $NWP_ROOT; remotely we ask, rather than assuming $HOME/nwp — assuming it is
  # how `pl loop` came to report on whichever machine you typed it on.
  local ssh_cmd="" target_desc="this machine ($(hostname -s 2>/dev/null || echo local))" remote_root=""
  if [ -n "$HOSTROLE" ]; then
    # shellcheck disable=SC1091
    [ -f "$PROJECT_ROOT/lib/server-resolver.sh" ] && source "$PROJECT_ROOT/lib/server-resolver.sh" 2>/dev/null
    if declare -F get_server_ssh_command >/dev/null 2>&1; then
      ssh_cmd=$(get_server_ssh_command "$HOSTROLE" 2>/dev/null) || ssh_cmd=""
    fi
    [ -z "$ssh_cmd" ] && ssh_cmd="ssh -o BatchMode=yes $HOSTROLE"
    target_desc="$HOSTROLE (via ${ssh_cmd%% *})"
    remote_root=$($ssh_cmd 'for d in "$HOME/nwp" /opt/nwp /srv/nwp; do [ -x "$d/scripts/secrets-daily-audit.sh" ] && { echo "$d"; break; }; done' 2>/dev/null | head -1)
    [ -z "$remote_root" ] && die "no NWP checkout with scripts/secrets-daily-audit.sh found on $HOSTROLE — deploy the checkout first"
  fi
  local root="${remote_root:-$NWP_ROOT}"

  local block; block=$(_cron_block "$root" "$SCHED")

  case "$sub" in
    status)
      print_header "secrets daily audit — cron status on $target_desc"
      local ct
      if [ -n "$ssh_cmd" ]; then ct=$($ssh_cmd 'crontab -l 2>/dev/null'); else ct=$(crontab -l 2>/dev/null); fi
      if printf '%s\n' "$ct" | grep -qF "$CRON_MARK_BEGIN"; then
        printf '%s\n' "$ct" | sed -n "/$(printf '%s' "$CRON_MARK_BEGIN" | sed 's/[]\/$*.^[]/\\&/g')/,/$(printf '%s' "$CRON_MARK_END" | sed 's/[]\/$*.^[]/\\&/g')/p" | sed 's/^/  /'
        print_success "installed"
        return 0
      fi
      print_error "NOT INSTALLED on $target_desc — the daily token audit is not running here"
      print_hint "install it:  pl secrets cron install${HOSTROLE:+ --host=$HOSTROLE}"
      return 1
      ;;
    install)
      print_header "secrets daily audit — install on $target_desc"
      echo "$block" | sed 's/^/  /'
      if [ "$DRY" = 1 ]; then print_warning "--dry-run: nothing written"; return 0; fi
      # idempotent: strip any existing marked block, then append the new one
      local script
      script=$(printf '%s\n' \
        'set -e' \
        "cur=\$(crontab -l 2>/dev/null || true)" \
        "new=\$(printf '%s\n' \"\$cur\" | awk 'BEGIN{s=1} /^# >>> nwp secrets daily audit/{s=0} s{print} /^# <<< nwp secrets daily audit/{s=1}')" \
        "printf '%s\n%s\n' \"\$new\" \"\$BLOCK\" | grep -v '^\$' | crontab -")
      if [ -n "$ssh_cmd" ]; then
        BLOCK="$block" $ssh_cmd "BLOCK=\$(cat <<'EOF'
$block
EOF
); $script" || die "failed to install cron on $HOSTROLE"
      else
        BLOCK="$block" bash -c "$script" || die "failed to install cron locally"
      fi
      print_success "installed on $target_desc — schedule: $SCHED"
      print_hint "verify:  pl secrets cron status${HOSTROLE:+ --host=$HOSTROLE}"
      ;;
    remove)
      if [ "$DRY" = 1 ]; then print_warning "--dry-run: would remove the marked block on $target_desc"; return 0; fi
      local rm_script="cur=\$(crontab -l 2>/dev/null || true); printf '%s\n' \"\$cur\" | awk 'BEGIN{s=1} /^# >>> nwp secrets daily audit/{s=0} s{print} /^# <<< nwp secrets daily audit/{s=1}' | crontab -"
      if [ -n "$ssh_cmd" ]; then $ssh_cmd "$rm_script"; else bash -c "$rm_script"; fi
      print_success "removed from $target_desc"
      ;;
    *) die "usage: pl secrets cron install|status|remove [--host=<role>] [--schedule='30 6 * * *'] [--dry-run]" ;;
  esac
}

################################################################################
# probe-scaffold — write a starter `probe:` block for an entry, so that "this
#   entry claims a scope it never checks" is a fixable lint error rather than a
#   hand-edit of the source of record.
#
#   A probe is a triple (name, url, expect). The expectation may be POSITIVE
#   ("this token MUST reach instances" → 200) or NEGATIVE ("this token must NOT
#   reach instances" → 401/403). The negative form is the important one and the
#   one prose could never carry: it is how you record "linode.api_token is
#   DNS-only" in a way that goes red the day somebody widens it.
#
#   Every scaffolded probe is READ-ONLY or a create-without-creating idiom
#   (an empty-body POST that must be rejected at validation, i.e. 400 — proving
#   the token was authorised to attempt it without any object being made).
################################################################################
cmd_probe_scaffold(){
  need_yq; need_registry
  local arg="${1:-}"
  [ -n "$arg" ] || die "usage: pl secrets probe-scaffold <#|id|--all> [--force]"

  # --all: scaffold every entry lint reports as NO-PROBE, so clearing the finding
  # is one command rather than ten. Without this the lint error is technically
  # actionable and practically a chore, and chores get muted.
  if [ "$arg" = "--all" ]; then
    local n i id st nsc npr done=0 skipped=0
    n=$("$YQ" e '.secrets | length' "$REGISTRY"); [ "$n" = "null" ] && n=0
    for ((i=0;i<n;i++)); do
      id=$(field "$i" id); st=$(field "$i" status)
      [ -z "$id" ] && continue
      [ "$st" = "not-provisioned" ] && continue
      nsc=$("$YQ" e ".secrets[$i].scopes // [] | length" "$REGISTRY" 2>/dev/null)
      [ "${nsc:-0}" -eq 0 ] 2>/dev/null && continue
      npr=$("$YQ" e ".secrets[$i].probe // [] | length" "$REGISTRY" 2>/dev/null)
      [ "${npr:-0}" -gt 0 ] 2>/dev/null && { skipped=$((skipped+1)); continue; }
      cmd_probe_scaffold "$id" "${2:-}" && done=$((done+1)) || true
    done
    echo
    print_info "scaffolded $done entr(ies); $skipped already had a probe:"
    print_warning "EVERY scaffolded expectation is a TEMPLATE. Run 'pl secrets audit' and correct"
    print_warning "each SCOPE-DRIFT against what the provider actually says — an unverified probe"
    print_warning "is the same folklore in a new shape."
    return 0
  fi

  local idx
  if [[ "$arg" =~ ^[0-9]+$ ]]; then idx=$((arg-1)); else idx=$(registry_index_of "$arg"); fi
  { [ "$idx" = "-1" ] || [ -z "$(field "$idx" id)" ]; } && die "no such secret: $arg (see: pl secrets status)"

  local id prov scopes host
  id=$(field "$idx" id); prov=$(field "$idx" provider)
  scopes=$("$YQ" e ".secrets[$idx].scopes // [] | join(\",\")" "$REGISTRY" 2>/dev/null)
  [ -z "$scopes" ] && die "$id declares no scopes: — nothing to probe (add scopes: first, or leave both absent)"

  local existing; existing=$("$YQ" e ".secrets[$idx].probe // [] | length" "$REGISTRY" 2>/dev/null)
  if [ "${existing:-0}" -gt 0 ] && [ "${2:-}" != "--force" ]; then
    print_warning "$id already has ${existing} probe(s) — refusing to overwrite (use --force)"
    return 0
  fi

  # Write the PLACEHOLDER, not the resolved hostname. `expand_placeholders`
  # resolves <gitlab-host> from .secrets.yml at probe time, so the registry never
  # hard-codes the estate's internal domain — which is also why this file does
  # not either (the leakage gate's live-internal-domain rule catches it if it
  # ever does, as it did on the first draft of this function).
  host='<gitlab-host>'

  local json
  case "$prov" in
    gitlab)
      # /user is the floor: any live token answers it. read_api/api then widen it.
      json="[{\"name\":\"alive\",\"url\":\"https://${host}/api/v4/user\",\"expect\":200}"
      case ",$scopes," in
        *,api,*|*,read_api,*)
          json="${json},{\"name\":\"read-projects\",\"url\":\"https://${host}/api/v4/projects?per_page=1\",\"expect\":200}" ;;
      esac
      # An entry that does NOT claim admin must be shown not to have it. This is
      # the negative probe that would have caught a root PAT in a bot's slot.
      [ "$(field "$idx" allow_admin)" = "true" ] \
        || json="${json},{\"name\":\"not-admin\",\"url\":\"https://${host}/api/v4/admin/ci/variables\",\"expect\":403}"
      json="${json}]"
      ;;
    linode)
      # The exact pair that was mis-attributed: DNS reachable, instances NOT.
      # Flip `expect` to 200 on the entry that is genuinely instances-capable.
      json="[{\"name\":\"domains\",\"url\":\"https://api.linode.com/v4/domains\",\"expect\":200},"
      json="${json}{\"name\":\"no-instances\",\"url\":\"https://api.linode.com/v4/linode/instances\",\"expect\":401}]"
      ;;
    github)
      json="[{\"name\":\"alive\",\"url\":\"https://api.github.com/user\",\"expect\":200}]"
      ;;
    *)
      die "no probe template for provider '$prov' — add one to cmd_probe_scaffold, or drop scopes: from $id if it has no API surface"
      ;;
  esac

  PROBE_JSON="$json" "$YQ" e -i ".secrets[$idx].probe = (strenv(PROBE_JSON) | from_json)" "$REGISTRY" \
    || die "failed to write probe block for $id"

  print_success "scaffolded probe: for $id ($prov, scopes: $scopes)"
  "$YQ" e ".secrets[$idx].probe" "$REGISTRY" | sed 's/^/    /'
  echo
  print_warning "these are TEMPLATE expectations. Verify each against the provider and correct it —"
  print_warning "a probe that asserts what you assumed is the same folklore in a new shape."
  print_hint "check it now:  pl secrets audit    (SCOPE-DRIFT = the registry and the provider disagree)"
}

################################################################################
# capabilities — live token x capability grid. Turns "which token can do X?"
#   from folklore into a command. Probes read-only endpoints only.
################################################################################
cmd_capabilities(){
  need_yq; need_registry
  command -v curl >/dev/null || die "curl required"
  local host_default
  host_default=$("$YQ" e '.gitlab.server.domain // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  [ -n "$host_default" ] || die "no gitlab.server.domain in $SECRETS_FILE"
  local proj="${NWP_CAP_PROJECT:-nwp%2Fnwp}"

  # name | url-suffix — every one is a READ; nothing here creates or deletes.
  local -a CAPS=(
    "read-mr|/api/v4/projects/$proj/merge_requests?per_page=1"
    "read-issues|/api/v4/projects/$proj/issues?per_page=1"
    "deploy-keys|/api/v4/projects/$proj/deploy_keys"
    "ci-variables|/api/v4/projects/$proj/variables"
    "proj-tokens|/api/v4/projects/$proj/access_tokens"
    "admin-users|/api/v4/users?per_page=1&without_project_bots=true"
  )
  print_header "Token x capability (live, read-only probes against $host_default)"
  printf "  %-26s" "ID"; local c; for c in "${CAPS[@]}"; do printf " %-12s" "${c%%|*}"; done; echo
  local n i id prov canon ckind chost cpath cref val code
  n=$("$YQ" e '.secrets | length' "$REGISTRY"); [ "$n" = "null" ] && n=0
  for ((i=0;i<n;i++)); do
    id=$(field "$i" id); prov=$(field "$i" provider)
    [ "$prov" = "gitlab" ] || continue
    [ "$(field "$i" status)" = "not-provisioned" ] && continue
    canon=$(entry_canonical_loc "$i"); [ -z "$canon" ] && continue
    IFS=$'\x1f' read -r ckind chost cpath cref < <(loc_parse "$canon")
    { [ "$ckind" = "bad" ] || [ "$ckind" = "external" ] || [ -n "$chost" ]; } && continue
    val=$(loc_read "$ckind" "$(loc_abspath "$cpath")" "$cref") || continue
    printf "  %-26s" "$id"
    for c in "${CAPS[@]}"; do
      code=$(_audit_code "https://$host_default${c#*|}" "PRIVATE-TOKEN:" "$val")
      case "$code" in
        200|201) printf " ${GREEN}%-12s${NC}" "yes" ;;
        401)     printf " ${RED}%-12s${NC}"   "dead" ;;
        403)     printf " ${DIM}%-12s${NC}"   "no" ;;
        404)     printf " ${DIM}%-12s${NC}"   "no/404" ;;
        *)       printf " ${YELLOW}%-12s${NC}" "${code:-?}" ;;
      esac
    done
    val=""; echo
  done
  echo
  print_info "Least privilege: prefer the LOWEST row that says yes for the job you need."
}

################################################################################
# steps — print the exact reissue procedure for one entry (non-interactive)
################################################################################
cmd_steps(){
  need_yq; need_registry
  local arg="${1:-}"; [ -n "$arg" ] || die "usage: pl secrets steps <#|id>"
  local idx; if [[ "$arg" =~ ^[0-9]+$ ]]; then idx=$((arg-1)); else idx=$(registry_index_of "$arg"); fi
  { [ "$idx" = "-1" ] || [ -z "$(field "$idx" id)" ]; } && die "no such secret: $arg (see: pl secrets status)"
  local id prov typ scopes url role name proj
  id=$(field "$idx" id); prov=$(field "$idx" provider); typ=$(field "$idx" type)
  scopes=$("$YQ" e ".secrets[$idx].scopes // [] | join(\", \")" "$REGISTRY" 2>/dev/null)
  url=$(field "$idx" rotate_url); role=$(field "$idx" role)
  name=$(field "$idx" token_name_target); proj=$(field "$idx" project)
  print_header "Reissue steps — $id"
  echo "  provider : $prov"
  echo "  type     : $typ"
  [ -n "$name" ]   && echo "  name it  : $name"
  [ -n "$role" ]   && echo "  role     : $role"
  [ -n "$scopes" ] && echo "  scopes   : $scopes"
  [ -n "$proj" ]   && echo "  scope to : $proj"
  echo
  echo "  1) Create the new token here (match name/role/scopes above):"
  echo "       ${url:-<no rotate_url recorded — add one to the registry entry>}"
  echo "  2) Feed it in — hidden entry, propagates to EVERY stored location, stamps expiry + logs:"
  echo "       pl secrets rotate $((idx+1))"
  echo "     …which writes it to:"
  "$YQ" e ".secrets[$idx].stored_in[]" "$REGISTRY" 2>/dev/null | sed 's/^/         - /'
  echo "  3) Revoke the OLD token at the same page."
  echo "  4) Verify:  pl secrets whose $((idx+1))   then   pl secrets audit"
}

################################################################################
# consumers — map each token to the CODE that reads it (which functions use it).
#   Live-derived: greps lib/ + scripts/ for every identifier a token is known by
#   (its .secrets.yml dotted key, the key tail, and any env-var name in
#   stored_in) and reports file:line + the enclosing shell function. A token with
#   no in-repo hit is consumed via env / a per-host script / auth.json (see its
#   stored_in). `--write` (re)generates private/token-consumers.md as a durable log.
################################################################################
_enclosing_fn(){ # file line -> nearest preceding shell-function name (or "-")
  awk -v L="$2" '
    NR<=L && /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/ {
      f=$0; sub(/\(\).*/,"",f); sub(/^[[:space:]]*(function[[:space:]]+)?/,"",f); gsub(/[[:space:]]/,"",f); last=f
    }
    END{ print (last==""?"-":last) }' "$1" 2>/dev/null
}
cmd_consumers(){
  need_yq; need_registry
  local WRITE=0 STRICT=0 only="" a
  for a in "$@"; do case "$a" in --write) WRITE=1;; --strict) STRICT=1;; -*) ;; *) only="$a";; esac; done
  local roots=("$PROJECT_ROOT/lib" "$PROJECT_ROOT/scripts")
  local out; out=$(mktemp)
  local n i; n=$("$YQ" e '.secrets | length' "$REGISTRY"); [ "$n" = "null" ] && n=0
  for ((i=0;i<n;i++)); do
    local id; id=$(field "$i" id); [ -z "$id" ] && continue
    [ -n "$only" ] && [ "$only" != "$id" ] && continue
    local -a idents=()
    while IFS= read -r loc; do
      [ -z "$loc" ] && continue
      case "$loc" in
        .secrets*.yml:*)                                    # gitlab.x_token (+ tail if specific)
          local k="${loc#*:}" tail; tail="${k##*.}"; idents+=("$k")
          case "$tail" in
            api_token|token|password|initial_password|admin_password|url|user|username|key|secret|domain|ip) ;;  # too generic — full key only
            *) idents+=("$tail") ;;
          esac ;;
        *:*)             local v="${loc#*:}"; v="${v%% *}"; idents+=("$v") ;; # env-var name e.g. GITLAB_TOKEN
      esac
    done < <("$YQ" e ".secrets[$i].stored_in[]?" "$REGISTRY" 2>/dev/null)
    printf '## %s\n' "$id" >> "$out"
    local found=0 idt file line
    while IFS= read -r idt; do
      [ -z "$idt" ] && continue; [ ${#idt} -lt 5 ] && continue
      while IFS=: read -r file line _; do
        [ -z "$file" ] && continue
        printf -- '- `%s` — %s:%s  (`%s`)\n' "$idt" "${file#$PROJECT_ROOT/}" "$line" "$(_enclosing_fn "$file" "$line")" >> "$out"
        found=1
      done < <(grep -rnI --include='*.sh' -wF "$idt" "${roots[@]}" 2>/dev/null | grep -v '/\.secrets')
    done < <(printf '%s\n' "${idents[@]}" | sort -u)
    [ "$found" = 0 ] && printf -- '- _(no in-repo consumer — used via env / per-host script / auth.json; see stored_in)_\n' >> "$out"
    printf '\n' >> "$out"
  done
  # ---- REVERSE pass: code that reads a secret the registry never heard of ----
  # The forward pass answers "where is this token used?". It cannot answer
  # "what is this code reading?" — so every get_infra_secret/get_data_secret key
  # that no registry entry declares is harvested here and reported. Without it,
  # a whole class of credentials (claude.*, moodle.<site>.<tier>.db_password,
  # cloudflare.*) is consumed by code and tracked by nothing.
  local unreg=0 declared_keys ignored_keys
  declared_keys=$("$YQ" e '.secrets[].stored_in[]?' "$REGISTRY" 2>/dev/null \
                  | grep -oE '^\.secrets\.yml:[A-Za-z0-9_.]+' | sed 's/^\.secrets\.yml://' | sort -u)
  ignored_keys=$("$YQ" e '.ignored_keys[]? // ""' "$REGISTRY" 2>/dev/null | grep -v '^null$')
  {
    printf '## UNREGISTERED CONSUMERS\n\n'
    local key hit=0
    while IFS= read -r key; do
      [ -z "$key" ] && continue
      case "$key" in *'$'*|*'"'*|*"'"*) continue ;; esac   # dynamic key — cannot resolve statically
      printf '%s\n' "$declared_keys" | grep -qxF "$key" && continue
      printf '%s\n' "$ignored_keys"  | grep -qxF "$key" && continue
      printf -- '- `%s` — read by code, declared by NO registry entry\n' "$key"
      hit=1; unreg=$((unreg+1))
    done < <(grep -rhoE "get_(infra|data)_secret[[:space:]]+[\"']([A-Za-z0-9_.]+)[\"']" \
               --include='*.sh' "${roots[@]}" 2>/dev/null \
             | sed -E "s/.*[\"']([A-Za-z0-9_.]+)[\"'].*/\1/" | sort -u)
    [ "$hit" = 0 ] && printf -- '- _(none — every statically-resolvable secret key a script reads is declared)_\n'
    printf '\n'
  } >> "$out"

  if [ "$WRITE" = 1 ]; then
    local dest="$NWP_ROOT/private/token-consumers.md"
    # Refuse to replace a populated map with an empty one. This file is tracked;
    # a run against a missing/empty registry would otherwise silently truncate
    # it, which is a data-loss shape, not a regeneration.
    if [ ! -s "$out" ] && [ -s "$dest" ]; then
      print_error "refusing to overwrite $dest with an empty document (no registry entries resolved)"
      rm -f "$out"; return 1
    fi
    { printf '# Token → code consumers  (generated by `pl secrets consumers --write`)\n\n'
      printf 'Which lib/ + scripts/ functions reference each token. Regenerate after code changes.\n\n'
      cat "$out"; } > "$dest"
    print_success "wrote $dest"
  else
    print_header "Token → code consumers  (lib/ + scripts/)"
    cat "$out"
  fi
  rm -f "$out"
  if [ "$unreg" -gt 0 ]; then
    print_warning "$unreg unregistered consumer key(s) — adopt them: pl secrets adopt <dotted.key>"
    [ "$STRICT" = 1 ] && return 1
  fi
  return 0
}

################################################################################
# inject — registry-driven env-config + cross-site token injection (§6 P0-4)
#
#   pl secrets inject <site> --tier=stg|live [--dry-run|--apply]
#
# Injects the env-specific $config overrides + the cross-site link secrets
# onto a LIVE box, WITHOUT ever reading a raw secret value off live (ADR-0017).
#   • Drupal (project.type=drupal): writes the rsync-excluded, include-at-
#     generate_live_settings file  settings.local.overrides.php  (NOT
#     settings.local.php, which is nuked every deploy — design §3.5/§5.3),
#     then `drush cr`.
#   • Moodle (project.type=moodle): sets mdl_config rows via admin/cli/cfg.php
#     as `sudo -u www-data`.
#
# The WHAT-to-inject + WHERE-it-targets come entirely from the registry's
# top-level `inject:` list (private/secrets-registry.yml, tokenless). Secret
# VALUES are pulled from the secret store (.secrets.yml) via each item's
# `secret: <dotted.key>`; non-secret env-invariants (key PATHS, base_urls)
# via `value: <literal>`. FAIL-CLOSED if a required `secret:` key is empty
# or missing. Values are NEVER echoed; --dry-run prints key-paths + target
# host/file only (no values). Registry inject-entry schema:
#
#   inject:
#     - site: nwc
#       platform: drupal
#       tiers: [live, stg]
#       # overrides_file: /var/www/nwc/html/sites/default/settings.local.overrides.php  (optional; else derived)
#       # webroot: html   # optional; else derived from stg .ddev docroot, default "web"
#       config:
#         - { object: "nwc_feedback.cross_site", keys: [bearer_token],       secret: link.nwc_ssc.bearer_token }
#         - { object: "nwc_copyright.settings",  keys: [moodle, admin_token], secret: link.nwc_ssc.admin_token }
#         - { object: "nwc_copyright.settings",  keys: [moodle, base_url],    value:  "https://ssc.example.org" }
#         - { object: "simple_oauth.settings",   keys: [public_key],          value:  "/var/www/nwc/oauth-keys/public.key" }
#         - { object: "simple_oauth.settings",   keys: [private_key],         value:  "/var/www/nwc/oauth-keys/private.key" }
#     - site: ssc
#       platform: moodle
#       tiers: [live, stg]
#       config:
#         - { component: local_nwc_copyright_sync, name: admin_token,  secret: link.nwc_ssc.admin_token }
#         - { component: local_nwc_copyright_sync, name: signal_token, secret: link.nwc_ssc.signal_token }
#         - { component: local_nwc_copyright_sync, name: nwc_base_url, value: "https://nwc.example.org" }
################################################################################

# yq scalar read helper for the inject: tree (empty on null/missing)
_inj(){ "$YQ" e "$1 // \"\"" "$REGISTRY" 2>/dev/null | grep -v '^null$'; }

# Find the inject-entry index for <site>+<tier>, or -1.
inject_index_of(){
  local site="$1" tier="$2" n i s t match
  n=$("$YQ" e '.inject | length' "$REGISTRY" 2>/dev/null); { [ "$n" = "null" ] || [ -z "$n" ]; } && { echo "-1"; return; }
  for ((i=0;i<n;i++)); do
    s=$(_inj ".inject[$i].site")
    [ "$s" = "$site" ] || continue
    match=""
    while IFS= read -r t; do [ "$t" = "$tier" ] && match=1; done \
      < <("$YQ" e ".inject[$i].tiers[]?" "$REGISTRY" 2>/dev/null)
    [ -n "$match" ] && { echo "$i"; return; }
  done
  echo "-1"
}

# Escape a value for a PHP single-quoted string literal.
_php_q(){ local s="$1"; s="${s//\\/\\\\}"; s="${s//\'/\\\'}"; printf '%s' "$s"; }

# Resolve a secret value length WITHOUT letting the value leave yq (presence
# check only; used in every mode so fail-closed happens before any live write).
_secret_len(){ "$YQ" e "(.$1 // \"\") | length" "$SECRETS_FILE" 2>/dev/null; }

# Live config resolver — mirrors stg2live.sh/moodle.sh get_live_config VERBATIM
# (reads per-site .nwp.yml → server config). Requires lib/common.sh sourced.
get_live_config(){
  local sitename="$1" field="$2"
  local base; base=$(get_base_name "$sitename")
  local yq_path
  case "$field" in
    server_ip)
      local server_name
      server_name=$(get_site_config_value "$base" '.live.server' "")
      if [[ -n "$server_name" ]]; then get_server_config "$server_name" "ip" ""; return; fi
      get_site_config_value "$base" '.live.server_ip' ""; return ;;
    domain)      yq_path='.live.domain' ;;
    type)        yq_path='.live.type' ;;
    server)      yq_path='.live.server' ;;
    remote_path) yq_path='.live.remote_path' ;;
    *)           yq_path=".live.$field" ;;
  esac
  get_site_config_value "$base" "$yq_path" ""
}

cmd_inject(){
  local site="" tier="" MODE="dry-run"
  while [ $# -gt 0 ]; do case "$1" in
    --tier=*)   tier="${1#*=}" ;;
    --tier)     tier="${2:-}"; shift ;;
    --dry-run)  MODE="dry-run" ;;
    --apply|--apply-to-live) MODE="apply" ;;
    -h|--help)  echo "usage: pl secrets inject <site> --tier=stg|live [--dry-run|--apply]"; return 0 ;;
    -*)         die "unknown flag: $1" ;;
    *)          [ -z "$site" ] && site="$1" || die "unexpected arg: $1" ;;
  esac; shift; done

  [ -n "$site" ] || die "usage: pl secrets inject <site> --tier=stg|live [--dry-run|--apply]"
  case "$tier" in stg|live) ;; *) die "--tier must be stg or live (got: '${tier:-}')" ;; esac

  need_yq; need_registry
  # Heavy libs only needed here — keep the rest of `pl secrets` lightweight.
  source "$PROJECT_ROOT/lib/common.sh"      2>/dev/null || die "cannot source lib/common.sh"
  source "$PROJECT_ROOT/lib/impact.sh"      2>/dev/null || die "cannot source lib/impact.sh"
  source "$PROJECT_ROOT/lib/deploy-gate.sh" 2>/dev/null || true

  local base; base=$(get_base_name "$site")

  # Registry-driven: find the inject spec for this site+tier. Fail-closed if absent.
  local ix; ix=$(inject_index_of "$site" "$tier")
  [ "$ix" = "-1" ] && ix=$(inject_index_of "$base" "$tier")
  [ "$ix" = "-1" ] && die "no inject spec for site '$site' tier '$tier' in $REGISTRY (add an inject: block — see design §5.7 / P0-5 follow-up)"

  local platform; platform=$(_inj ".inject[$ix].platform")
  [ -n "$platform" ] || die "inject entry for '$site' has no platform (drupal|moodle)"

  # Live-provision + gate checks (only bite on the live tier).
  local server_ip="" ssh_user="" remote_path="" sudo_prefix=""
  if [ "$tier" = "live" ]; then
    server_ip=$(get_live_config "$base" "server_ip")
    [ -n "$server_ip" ] || die "refusing live inject: no server_ip for '$base' (site not provisioned)"
    ssh_user=$(get_ssh_user "$base")
    remote_path=$(get_live_config "$base" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${base}"
  else
    # stg tier: resolve from stg config if present; else the deterministic default.
    server_ip=$(get_site_config_value "$base" '.stg.server_ip' "")
    ssh_user=$(get_site_config_value "$base" '.stg.ssh_user' "$(get_ssh_user "$base")")
    remote_path=$(get_site_config_value "$base" '.stg.remote_path' "/var/www/${base}")
  fi
  [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"

  print_header "secrets inject — $base ($platform, tier=$tier, mode=$MODE)"

  # ── Build the plan (targets only; secret VALUES never touched in this loop) ──
  # Parallel arrays describing each config item.
  local -a P_LABEL=() P_KIND=() P_SRC=() P_OBJ=() P_KEYIDX=() P_COMP=() P_NAME=()
  local -a MISSING=()
  local nc j
  nc=$("$YQ" e ".inject[$ix].config | length" "$REGISTRY" 2>/dev/null); [ "$nc" = "null" ] && nc=0
  [ "${nc:-0}" -gt 0 ] || die "inject entry for '$site' has no config items"

  for ((j=0;j<nc;j++)); do
    local secret value keypath keyidx object comp name label kind src
    secret=$(_inj ".inject[$ix].config[$j].secret")
    value=$(_inj ".inject[$ix].config[$j].value")
    if [ "$platform" = "drupal" ]; then
      object=$(_inj ".inject[$ix].config[$j].object")
      [ -n "$object" ] || die "config item $j: drupal inject needs 'object'"
      # Build the $config[...] index string from keys[]
      keyidx=""
      while IFS= read -r k; do [ -n "$k" ] && keyidx="${keyidx}['$(_php_q "$k")']"; done \
        < <("$YQ" e ".inject[$ix].config[$j].keys[]?" "$REGISTRY" 2>/dev/null)
      [ -n "$keyidx" ] || die "config item $j: drupal inject needs non-empty 'keys'"
      label="\$config['${object}']${keyidx}"
      P_OBJ+=("$object"); P_KEYIDX+=("$keyidx"); P_COMP+=(""); P_NAME+=("")
    else
      comp=$(_inj ".inject[$ix].config[$j].component")
      name=$(_inj ".inject[$ix].config[$j].name")
      { [ -n "$comp" ] && [ -n "$name" ]; } || die "config item $j: moodle inject needs 'component' + 'name'"
      label="${comp}/${name}"
      P_OBJ+=(""); P_KEYIDX+=(""); P_COMP+=("$comp"); P_NAME+=("$name")
    fi

    if [ -n "$secret" ]; then
      kind="secret"; src="$secret"
      # Fail-closed presence check — length computed INSIDE yq; value never read here.
      local ln; ln=$(_secret_len "$secret"); ln=${ln:-0}
      [ "$ln" = "null" ] && ln=0
      [ "${ln:-0}" -gt 0 ] || MISSING+=("$label  ⇐  .secrets.yml:$secret (empty/missing)")
    elif [ -n "$value" ]; then
      kind="value"; src="$value"
    else
      die "config item $j ($label): neither 'secret' nor 'value' set"
    fi
    P_LABEL+=("$label"); P_KIND+=("$kind"); P_SRC+=("$src")
  done

  # Resolve the Drupal overrides-file path (target file).
  local overrides_file="" webroot=""
  if [ "$platform" = "drupal" ]; then
    overrides_file=$(_inj ".inject[$ix].overrides_file")
    if [ -z "$overrides_file" ]; then
      webroot=$(_inj ".inject[$ix].webroot")
      if [ -z "$webroot" ]; then
        local stg_ddev="$NWP_ROOT/sites/$base/stg/.ddev/config.yaml"
        [ -f "$stg_ddev" ] && webroot=$(grep "^docroot:" "$stg_ddev" 2>/dev/null | awk '{print $2}')
        [ -z "$webroot" ] && webroot="web"
      fi
      overrides_file="${remote_path}/${webroot}/sites/default/settings.local.overrides.php"
    fi
  fi

  # ── Print the plan (key-paths + targets ONLY; never any value) ──
  local target_desc
  if [ "$platform" = "drupal" ]; then
    target_desc="${ssh_user}@${server_ip}:${overrides_file}"
  else
    target_desc="${ssh_user}@${server_ip}: admin/cli/cfg.php @ ${remote_path}"
  fi
  echo "  target: $target_desc"
  printf "  %-6s %s\n" "KIND" "CONFIG KEY-PATH  ⇐  SOURCE"
  printf "  %-6s %s\n" "----" "--------------------------"
  local i
  for i in "${!P_LABEL[@]}"; do
    if [ "${P_KIND[$i]}" = "secret" ]; then
      printf "  %-6s %s  ⇐  .secrets.yml:%s\n" "secret" "${P_LABEL[$i]}" "${P_SRC[$i]}"
    else
      printf "  %-6s %s  =  %s\n" "value" "${P_LABEL[$i]}" "${P_SRC[$i]}"
    fi
  done
  echo

  # ── Fail-closed on any missing required secret (before any live write) ──
  if [ "${#MISSING[@]}" -gt 0 ]; then
    print_error "FAIL-CLOSED: required secret value(s) empty/missing in $SECRETS_FILE:"
    printf '    - %s\n' "${MISSING[@]}"
    print_hint "store them safely: pl secrets set <dotted.key>  (hidden entry, never echoed)"
    return 1
  fi

  # ── IMPACT manifest (always rendered) ──
  impact_reset
  if [ "$platform" = "drupal" ]; then
    impact_overwrite "Overrides" "${overrides_file} — ${nc} \$config override(s), rewritten in full"
    impact_keep "Live member DB, oauth-keys/{private,public}.key, settings.local.php — untouched"
  else
    impact_overwrite "mdl_config" "${nc} row(s) via admin/cli/cfg.php on ${base} (${remote_path})"
    impact_keep "Live Moodle DB content, moodledata, config.php — untouched"
  fi
  impact_warn "cross-site secret values transit ssh only; written ${platform} target on '${base}' (mode 440 www-data). Never printed."
  impact_render

  if [ "$MODE" = "dry-run" ]; then
    print_info "[dry-run] no live write. Re-run with --apply to inject."
    return 0
  fi

  # ── APPLY ──
  # No TTY + no live server → nothing to write to.
  [ -n "$server_ip" ] || die "no server_ip resolved for '$base' tier '$tier' — cannot apply"

  # Confirm: typed name on live (last-recovery-ish); standard on stg.
  if [ "$tier" = "live" ]; then
    # Hardware/signature deploy gate (ADR-0028) — no-op unless configured on ver.
    if declare -F deploy_gate_require >/dev/null; then
      deploy_gate_require "$base" "live" "inject cross-site config/secrets ($platform)" || die "deploy gate refused — aborting inject"
    fi
    impact_confirm typed "$base" "${AUTO_CONFIRM:-false}" || { print_warning "aborted"; return 1; }
  else
    impact_confirm standard "inject $platform config on '$base' (stg)" "${AUTO_CONFIRM:-false}" || { print_warning "aborted"; return 1; }
  fi

  local ssh_opts; ssh_opts=$(nwp_ssh_opts "$base")

  if [ "$platform" = "drupal" ]; then
    # Assemble the overrides file content locally (values in-memory only; never
    # printed), pipe it over ssh into the rsync-excluded overrides file.
    local body php_val
    body="<?php
/**
 * settings.local.overrides.php — operator/tooling-managed, rsync-excluded,
 * include()d at the tail of the generated settings.local.php. Written by
 * \`pl secrets inject\` (design §3.5/§5.3, P0-4). DO NOT hand-edit tokens here;
 * re-run \`pl secrets inject $base --tier=$tier --apply\`.
 */
"
    for i in "${!P_LABEL[@]}"; do
      if [ "${P_KIND[$i]}" = "secret" ]; then
        # Read the value ONLY now, at write time, straight into the PHP literal.
        php_val=$(_php_q "$("$YQ" e ".${P_SRC[$i]} // \"\"" "$SECRETS_FILE" 2>/dev/null)")
      else
        php_val=$(_php_q "${P_SRC[$i]}")
      fi
      body+="\$config['${P_OBJ[$i]}']${P_KEYIDX[$i]} = '${php_val}';
"
      php_val=""
    done

    if printf '%s' "$body" | ssh $ssh_opts -o BatchMode=yes "${ssh_user}@${server_ip}" \
         "$sudo_prefix tee '${overrides_file}' >/dev/null"; then
      body=""
      ssh $ssh_opts -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "$sudo_prefix chown www-data:www-data '${overrides_file}'; $sudo_prefix chmod 440 '${overrides_file}'" 2>/dev/null
      print_status "OK" "wrote ${nc} override(s) → ${overrides_file}"
    else
      body=""; die "failed to write ${overrides_file}"
    fi

    print_info "rebuilding Drupal cache (drush cr)…"
    ssh $ssh_opts -o BatchMode=yes "${ssh_user}@${server_ip}" \
      "cd '${remote_path}' && $sudo_prefix -u www-data drush cr" 2>/dev/null \
      && print_status "OK" "drush cr" || print_warning "drush cr failed — run it manually on ${base}"

  else
    # Moodle: one cfg.php invocation per row, as www-data. cfg.php requires the
    # value on argv (no stdin form) — that is the minimum exposure cfg.php needs;
    # nothing is echoed locally and it lands only in the live php process argv.
    local runas="sudo -u www-data"; [ "$ssh_user" = "www-data" ] && runas=""
    local cfg="${remote_path}/admin/cli/cfg.php" ok=1 cval rcval
    for i in "${!P_LABEL[@]}"; do
      if [ "${P_KIND[$i]}" = "secret" ]; then
        cval=$("$YQ" e ".${P_SRC[$i]} // \"\"" "$SECRETS_FILE" 2>/dev/null)
      else
        cval="${P_SRC[$i]}"
      fi
      # Escape the value for the remote single-quoted context (' -> '\'').
      # cfg.php needs --set on argv (no stdin form) — that is the minimum
      # exposure; the value transits ssh only and is never echoed locally.
      rcval="${cval//\'/\'\\\'\'}"; cval=""
      if ssh $ssh_opts -o BatchMode=yes "${ssh_user}@${server_ip}" \
           "$runas php '${cfg}' --component='${P_COMP[$i]}' --name='${P_NAME[$i]}' --set='${rcval}'" 2>/dev/null; then
        print_status "OK" "set ${P_COMP[$i]}/${P_NAME[$i]}"
      else
        print_status "FAIL" "set ${P_COMP[$i]}/${P_NAME[$i]}"; ok=0
      fi
      rcval=""
    done
    ssh $ssh_opts -o BatchMode=yes "${ssh_user}@${server_ip}" \
      "$runas php '${remote_path}/admin/cli/purge_caches.php'" 2>/dev/null \
      && print_status "OK" "purge_caches" || print_warning "purge_caches failed — run it manually on ${base}"
    [ "$ok" = "1" ] || return 1
  fi

  print_success "inject complete — $base ($platform, tier=$tier). No value was printed (ADR-0017)."
}

################################################################################
# main
################################################################################
sub="${1:-status}"; shift || true
case "$sub" in
  status|list|ls) cmd_status "$@" ;;
  keys|tree|structure) cmd_keys "$@" ;;
  set)            cmd_set "$@" ;;
  scaffold)       cmd_scaffold "$@" ;;
  adopt)          cmd_adopt "$@" ;;
  sync)           cmd_sync "$@" ;;
  migrate-registry|migrate) cmd_migrate_registry "$@" ;;
  discover-copies|discover) cmd_discover_copies "$@" ;;
  verify-copy)    cmd_verify_copy "$@" ;;
  provision)      cmd_provision "$@" ;;
  probe-scaffold|probe) cmd_probe_scaffold "$@" ;;
  cron)           cmd_cron "$@" ;;
  registry-track) cmd_registry_track "$@" ;;
  capabilities|caps) cmd_capabilities "$@" ;;
  surfaces)       cmd_surfaces "$@" ;;
  rotate)         cmd_rotate "$@" ;;
  done)           cmd_done "$@" ;;
  expose|exposed) cmd_expose "$@" ;;
  debt|debts)     cmd_debt "$@" ;;
  get)            cmd_get "$@" ;;
  whose)          cmd_whose "$@" ;;
  audit)          cmd_audit "$@" ;;
  steps|reissue)  cmd_steps "$@" ;;
  consumers)      cmd_consumers "$@" ;;
  inject)         cmd_inject "$@" ;;
  scan)           cmd_scan "$@" ;;
  scrub)          cmd_scrub "$@" ;;
  lint)           cmd_lint "$@" ;;
  check)          # reuse the todo check
    source "$PROJECT_ROOT/lib/todo-checks.sh" 2>/dev/null
    export TODO_CHECKS_PROJECT_ROOT="$PROJECT_ROOT"
    TODO_ITEMS=(); TODO_ITEM_ID=0; check_secret_expiry; printf '%s\n' "${TODO_ITEMS[@]:-(none due)}" ;;
  -h|--help|help)
    cat <<EOF
${BOLD}pl secrets${NC} — registry-driven secret lifecycle (no token stored on this host)

  pl secrets status              list every secret + days-to-expiry
  pl secrets keys                show .secrets.yml STRUCTURE (key paths, status, len) — NO values
  pl secrets set <dotted.key>    store a value via hidden entry (never echoed/logged)
  pl secrets scaffold            create registry-declared keys missing from .secrets.yml (empty)
  pl secrets rotate <#|id>       guided/assisted rotation (hidden value entry; # from status).
                                 FAIL-CLOSED: if any declared location cannot be written it
                                 prints a per-location table, refuses to stamp the registry or
                                 the rotation log, and exits 1. [--force] records a PARTIAL.
  pl secrets rotate --due        rotate everything expiring within 14 days / untracked
  pl secrets done <#|id> [date]  record a rotation you did by hand (stamps expiry + log)
  pl secrets expose <#|id> --reason='…' [--where=…] [--ref=ops#N] [--closed] [--adopt=<provider>]
                                 record that this credential's VALUE was EXPOSED. Rotation
                                 becomes OWED: it appears in 'pl todo', reddens 'pl rag', and
                                 REFUSES every prod bring-up until rotate/done discharges it
                                 (operator ruling D8). --closed means the leak SURFACE is
                                 remediated — that does NOT clear the rotation debt.
                                 --adopt lets you record an exposure of a credential the
                                 registry does not know about yet, in ONE command.
  pl secrets expose <#|id> --close   the surface is now closed (debt unchanged)
  pl secrets debt [--all] [--json]   the open rotation-debt queue — what blocks going to prod
  pl secrets get <dotted.key>    copy a value to the clipboard (never printed)
  pl secrets whose <#|id>        ask GitLab which user/bot/project owns the token
  pl secrets audit [--days N]    LIVE probe of EVERY declared location: valid? real expiry? drift?
                                 [--locations] row per location + SHA-256 prefix (never the value)
                                 [--offline] compare locations WITHOUT spending a probe — the
                                             provider rate-limits and then answers 000, and 000
                                             is not a verdict
                                 [--json] machine envelope
                                 [--sync] write live expiry back · [--quiet] for cron
  pl secrets sync <#|id>         propagate the canonical value to every declared location (repair
                   [--dry-run]   verb). Exits 1 if any declared location could not be written —
                                 `audit` points here, so a silent no-op would leave the finding
                                 standing while reporting success.
  pl secrets adopt <dotted.key>  register a .secrets.yml key that lint reported as undeclared
  pl secrets discover-copies     find copies of a known credential the registry does NOT declare
  pl secrets verify-copy <#|id>  check host=… remote copies by SHA-256 over ssh (value never crosses)
  pl secrets provision <#|id>    put a credential ONTO another host and DECLARE it in one step —
                                 the write and the stored_in row are the same operation, so a
                                 copy cannot exist undeclared (the met defect). Value travels on
                                 stdin, never argv; verified by SHA-256 read-back before the
                                 registry is touched; a failed write declares nothing.
                                 DRY-RUN by default — add --apply.
                                   --to host=<role>:<path>:<ref>   write + declare a NEW copy
                                   --host=<role>                   re-push declared copies
                                 FAIL-CLOSED: only hosts named in the registry's
                                 ai_provisionable_hosts: may be written at all, and prod-trust
                                 roles are refused even if allowlisted (ADR-0028). No flag,
                                 env var or config key overrides the prod refusal.
  pl secrets probe-scaffold <#|id> [--force]
                                 write a starter probe: block so the entry's SCOPE claim is checkable.
                                 Supports NEGATIVE probes (expect: 401/403 = "must NOT reach this") —
                                 the only way to record "DNS-only" so it goes red when widened.
  pl secrets cron install|status|remove [--host=<role>] [--dry-run]
                                 provision the daily audit BY CODE instead of by remembered incantation.
  pl secrets registry-track [--dry-run]
                                 put the registry under version control in a NESTED private repo.
                                 Not the outer repo: the registry is value-free but is a complete
                                 estate map (162 gitleaks identity findings, 0 credential), and
                                 nwp/nwp is the public-release track.
  pl secrets capabilities        live token x capability grid ("which token can do X" as a command)
  pl secrets surfaces            print the leak surfaces scan/scrub sweep
  pl secrets steps <#|id>        print the exact reissue procedure for one entry
  pl secrets consumers [--write] map each token to the code/functions that read it (--write → private/token-consumers.md)
                       [--strict] also fail on code reading an UNDECLARED secret key
  pl secrets inject <site> --tier=stg|live [--dry-run|--apply]
                                 registry-driven env-config + cross-site token injection (§6 P0-4):
                                 Drupal → settings.local.overrides.php + drush cr; Moodle → admin/cli/cfg.php.
                                 DRY-RUN default; prints key-paths + targets ONLY, never values (ADR-0017).
  pl secrets lint                BOTH directions: registry->file AND file->registry (undeclared keys),
                                 stored_in grammar, phantom paths, 0600 permissions. Exit 1 on any.
  pl secrets scan [--quiet]      leak sweep over transcripts, logs, history — EXIT 1 on any hit
                  [--transcripts] also sweep the AI transcript tree
  pl secrets scrub [files...]    redact secret strings (pattern + value) in place
  pl secrets check               show what the pl-todo expiry alert would report

Registry (tokenless): $REGISTRY
EOF
    ;;
  *) die "unknown subcommand: $sub (try: pl secrets help)" ;;
esac
