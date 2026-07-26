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
expand_placeholders(){ # stdin/arg -> arg with <gitlab-host> resolved
  local s="$1" d
  case "$s" in *'<gitlab-host>'*) ;; *) printf '%s' "$s"; return 0;; esac
  d=$("$YQ" e '.gitlab.server.domain // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  printf '%s' "${s//<gitlab-host>/$d}"
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
    printf "  ${BOLD}%-3s${NC} ${col}%-24s${NC} %-7s ${col}%-7s${NC} %-12s %-12s\n" "$((i+1))" "$id" "$via" "$dtxt" "$exp" "$rot"
  done
  echo
  print_info "ROTATED '—' = not recorded here yet (the registry only knows what you tell it)."
  print_hint "Guided rotate: pl secrets rotate <#|id>   ·   Record one you did by hand: pl secrets done <#|id> [YYYY-MM-DD]"
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
write_value_to_location(){ # $1=location ("file:key" or "~/path:VAR"); value in env NWP_NEWVAL
  local loc="$1" path="${1%%:*}" ref="${1#*:}"
  case "$loc" in
    VERIFY:*|*"not in .secrets.yml"*|*"Moodle DB"*)
      print_warning "  manual location (not auto-writable): $loc"; return 0 ;;
  esac
  path="${path/#\~/$HOME}"
  if [ "$path" = "$SECRETS_FILE" ] || [[ "$path" == *.secrets*.yml ]] || [[ "$path" == *.yml ]]; then
    [ -f "$path" ] || { print_warning "  missing $path"; return 1; }
    NWP_NEWVAL="$NWP_NEWVAL" "$YQ" e -i ".$ref = strenv(NWP_NEWVAL)" "$path" \
      && print_success "  updated $path : $ref" || { print_error "  yq write failed: $path"; return 1; }
  elif [[ "$path" == *.json ]]; then
    # JSON file (e.g. composer auth.json): $ref is a jq path expression, written verbatim
    # (bracket form required for keys with dashes/dots, e.g. .["gitlab-token"]["<gitlab-host>"]).
    command -v jq >/dev/null || { print_error "  jq required to write $path"; return 1; }
    [ -f "$path" ] || { print_warning "  missing $path"; return 1; }
    local jtmp; jtmp=$(mktemp)
    if jq --arg v "$NWP_NEWVAL" "$ref = \$v" "$path" > "$jtmp" 2>/dev/null && [ -s "$jtmp" ]; then
      chmod --reference="$path" "$jtmp" 2>/dev/null || chmod 600 "$jtmp"
      mv "$jtmp" "$path" && print_success "  updated $path : $ref"
    else
      rm -f "$jtmp"; print_error "  jq write failed: $path : $ref"; return 1
    fi
  else
    # env-style file: replace `export VAR=...` or `VAR=...`
    [ -f "$path" ] || { print_warning "  missing $path"; return 1; }
    if grep -qE "^(export )?$ref=" "$path"; then
      # NOTE: this expression used to read `($1//"")`, which perl tokenises as an
      # empty match `//` rather than defined-or — it aborted with a compile error
      # on EVERY invocation, so `pl secrets rotate` has never once written an
      # env-style location. That is the mechanical reason
      # `~/.nwp-agent-loop.env:GITLAB_TOKEN` drifted away from its canonical
      # `.secrets.yml` value while the registry recorded a clean rotation.
      NWP_REF="$ref" NWP_NEWVAL="$NWP_NEWVAL" perl -i -pe \
        's/^(export\s+)?\Q$ENV{NWP_REF}\E=.*/(defined($1) ? $1 : "") . "$ENV{NWP_REF}=\"$ENV{NWP_NEWVAL}\""/e' "$path" \
        && print_success "  updated $path : $ref" || { print_error "  write failed: $path"; return 1; }
    else
      print_warning "  $ref not present in $path (skipped)"
    fi
  fi
}

stamp_registry(){ # $1=idx $2=expires-date
  local idx="$1" exp="$2" today; today=$(date +%F)
  "$YQ" e -i ".secrets[$idx].last_rotated = \"$today\" | .secrets[$idx].expires = \"$exp\"" "$REGISTRY"
}

log_rotation(){ # $1=id $2=expires
  [ -f "$ROT_LOG" ] || printf '# Credential rotation — %s\n\nDates only; never paste values.\n\n' "$(date +%Y-%m)" > "$ROT_LOG"
  printf -- "- [x] %s — rotated %s, next expiry %s\n" "$1" "$(date +%F)" "$2" >> "$ROT_LOG"
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

  # hidden capture of the new value, write to all stored_in
  local NWP_NEWVAL=""; read -r -s -p "  new value (hidden, Enter to skip write): " NWP_NEWVAL </dev/tty; echo
  if [ -n "$NWP_NEWVAL" ]; then
    export NWP_NEWVAL
    while IFS= read -r loc; do [ -n "$loc" ] && write_value_to_location "$loc"; done \
      < <("$YQ" e ".secrets[$idx].stored_in[]" "$REGISTRY" 2>/dev/null)
    unset NWP_NEWVAL
  else
    print_warning "  no value written (you updated it elsewhere)"
  fi
  post_rotate "$idx" "$id" "$cadence"
}

post_rotate(){ # idx id cadence
  local idx="$1" id="$2" cadence="$3" def exp
  def=$(date -d "+${cadence} days" +%F 2>/dev/null)
  read -r -p "  new expiry date [default $def]: " exp </dev/tty
  [ -z "$exp" ] && exp="$def"
  stamp_registry "$idx" "$exp"
  log_rotation "$id" "$exp"
  print_success "rotated $id — expiry recorded $exp (logged to ${ROT_LOG##*/})"
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
      while IFS= read -r loc; do [ -n "$loc" ] && write_value_to_location "$loc"; done \
        < <("$YQ" e ".secrets[$idx].stored_in[]" "$REGISTRY" 2>/dev/null)
      unset NWP_NEWVAL
      print_success "  GitLab token rotated via API (one-time credential discarded)"
      return 0 ;;
    *) return 1 ;;
  esac
}

cmd_rotate(){
  need_yq; need_registry
  local target="${1:-}"; [ -n "$target" ] || die "usage: pl secrets rotate <id|--due|--all>"
  if [ "$target" = "--due" ] || [ "$target" = "--all" ]; then
    local n i id exp d; n=$("$YQ" e '.secrets | length' "$REGISTRY")
    for ((i=0;i<n;i++)); do
      id=$(field "$i" id); exp=$(field "$i" expires)
      [ "$(field "$i" status)" = "not-provisioned" ] && continue
      if [ "$target" = "--all" ]; then rotate_one "$id"; continue; fi
      [ -z "$exp" ] || [ "$exp" = "unknown" ] && { rotate_one "$id"; continue; }
      d=$(days_until "$exp"); [ "${d:-99}" -le 14 ] 2>/dev/null && rotate_one "$id"
    done
  else
    rotate_one "$target"
  fi
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
  [ -f "$ROT_LOG" ] || printf '# Credential rotation — %s\n\nDates only; never paste values.\n\n' "$(date +%Y-%m)" > "$ROT_LOG"
  printf -- "- [x] %s — rotated %s, next expiry %s\n" "$id" "$when" "$exp" >> "$ROT_LOG"
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
  local key="${1:-}"; [ -n "$key" ] || die "usage: pl secrets adopt <dotted.key>   e.g. linode.provision_token"
  local len; len=$("$YQ" e "(.$key // \"\") | length" "$SECRETS_FILE" 2>/dev/null)
  [ "${len:-0}" -eq 0 ] && die "$key is empty or missing in $SECRETS_FILE — nothing to adopt"
  "$YQ" e '.secrets[].stored_in[]?' "$REGISTRY" 2>/dev/null | grep -qxF ".secrets.yml:$key" \
    && die "$key is already declared by a registry entry"
  local id; id=$(printf '%s' "$key" | tr '.' '_')
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
  if [ -f "$REGISTRY" ] && "$YQ" e '.secrets[].stored_in[]?' "$REGISTRY" 2>/dev/null | grep -qxF ".secrets.yml:$key"; then
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
_audit_code(){ # url full-header-prefix value  -> http_code only
  local cfg; cfg=$(mktemp); chmod 600 "$cfg"
  printf 'silent\noutput = "/dev/null"\nwrite-out = "%%{http_code}"\nmax-time = 12\nurl = "%s"\nheader = "%s %s"\n' "$1" "$2" "$3" > "$cfg"
  curl -K "$cfg" 2>/dev/null; rm -f "$cfg"
}

# Probe ONE value at its provider. Emits "LIVE<TAB>live_expires<TAB>note".
# LIVE ∈ OK | DEAD | SKIP.  The value is passed in memory and never printed.
_probe_value(){ # provider host value
  local prov="$1" host="$2" val="$3" live="SKIP" exp="" note=""
  case "$prov" in
    gitlab)
      if [ -z "$host" ]; then note="no host"; else
        local ujson pjson uname active revoked isadmin
        ujson=$(_audit_body "https://$host/api/v4/user" "PRIVATE-TOKEN" "$val")
        uname=$("$YQ" e -p=json '.username // ""' <<<"$ujson" 2>/dev/null | grep -v '^null$')
        if [ -z "$uname" ]; then live="DEAD"; else
          pjson=$(_audit_body "https://$host/api/v4/personal_access_tokens/self" "PRIVATE-TOKEN" "$val")
          active=$("$YQ" e -p=json '.active // ""' <<<"$pjson" 2>/dev/null)
          revoked=$("$YQ" e -p=json '.revoked // ""' <<<"$pjson" 2>/dev/null)
          exp=$("$YQ" e -p=json '.expires_at // ""' <<<"$pjson" 2>/dev/null | grep -v '^null$')
          isadmin=$("$YQ" e -p=json '.is_admin // ""' <<<"$ujson" 2>/dev/null | grep -v '^null$')
          if [ "$revoked" = "true" ] || [ "$active" = "false" ]; then live="DEAD"; else live="OK"; fi
          [ "$isadmin" = "true" ] && note="ADMIN "
        fi
      fi ;;
    github) [ "$(_audit_code "https://api.github.com/user" "Authorization: Bearer" "$val")" = "200" ] && live="OK" || live="DEAD" ;;
    linode) [ "$(_audit_code "https://api.linode.com/v4/profile" "Authorization: Bearer" "$val")" = "200" ] && live="OK" || live="DEAD" ;;
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
  case "$prov" in
    gitlab) hdr="PRIVATE-TOKEN:" ;;
    github|linode) hdr="Authorization: Bearer" ;;
    *) return 0 ;;
  esac
  for ((j=0;j<np;j++)); do
    url=$(expand_placeholders "$("$YQ" e ".secrets[$idx].probe[$j].url // \"\"" "$REGISTRY" 2>/dev/null)")
    want=$("$YQ" e ".secrets[$idx].probe[$j].expect // \"\"" "$REGISTRY" 2>/dev/null)
    local pname; pname=$("$YQ" e ".secrets[$idx].probe[$j].name // \"probe$j\"" "$REGISTRY" 2>/dev/null)
    [ -z "$url" ] || [ -z "$want" ] && continue
    got=$(_audit_code "$url" "$hdr" "$val")
    [ "$got" = "$want" ] || out="${out}SCOPE-DRIFT($pname want=$want got=$got) "
  done
  printf '%s' "$out"
}

cmd_audit(){
  need_yq; need_registry
  command -v curl >/dev/null || die "curl required"
  local WARN=14 SYNC=0 QUIET=0 LOCS=0 JSON=0
  while [ $# -gt 0 ]; do case "$1" in
    --days) WARN="${2:-14}"; shift 2;;
    --sync) SYNC=1; shift;;
    --quiet|-q) QUIET=1; shift;;
    --locations|--all-locations) LOCS=1; shift;;
    --json) JSON=1; QUIET=1; shift;;
    *) shift;; esac; done

  local host_default
  host_default=$("$YQ" e '.gitlab.server.domain // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  # Reachability gate: if the GitLab host is DOWN, do NOT probe — every gitlab token
  # would false-positive as DEAD. Exit 2 = transient (cron/todo treat as "retry later").
  if [ -n "$host_default" ]; then
    local _rc; _rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "https://$host_default/api/v4/metadata" 2>/dev/null)
    if [ "$_rc" = "000" ]; then
      [ "$QUIET" = 0 ] && print_error "GitLab host $host_default unreachable — not probing (would false-positive). Try again later."
      return 2
    fi
  fi

  if [ "$QUIET" = 0 ]; then
    print_header "Live token audit — every declared location, values never printed"
    printf "  %-26s %-7s %-9s %-12s %-12s %s\n" "ID" "PROV" "LIVE" "EXPIRES" "RECORDED" "NOTE"
    printf "  %-26s %-7s %-9s %-12s %-12s %s\n" "--------------------------" "-------" "---------" "------------" "------------" "----"
  fi

  local n i problems=0 dead=0 expiring=0 drift=0 badloc=0 jbuf=""
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

    if [ -n "$canonval" ]; then
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
                   if [ "${nsc:-0}" -gt 0 ] 2>/dev/null; then
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
      lrows+=("${lstat}"$'\t'"${loc}")
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
        jl="${jl}$(jq -cn --arg s "${r%%$'\t'*}" --arg l "${r#*$'\t'}" '{status:$s,location:$l}')"
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
        local rs="${r%%$'\t'*}" rl="${r#*$'\t'}"
        case "$rs" in
          OK|EXTERNAL|REMOTE|UNVERIFIED) [ "$LOCS" = 1 ] && printf "      ${DIM}%-12s %s${NC}\n" "$rs" "$rl" ;;
          *)                             printf "      ${RED}%-12s${NC} %s\n" "$rs" "$rl" ;;
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
    echo; printf "  %d dead · %d expiring(≤%dd) · %d drifted location(s) · %d unparseable location(s)\n" \
      "$dead" "$expiring" "$WARN" "$drift" "$badloc"
    [ "$problems" -eq 0 ] && print_success "every token valid, and every declared location matches canonical" \
      || print_hint "propagate canonical to every location: pl secrets sync <id>   ·   reissue: pl secrets steps <id>"
  fi
  [ "$problems" -gt 0 ] && return 1 || return 0
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
  local loc lkind lhost lpath lref lval n_ok=0 n_write=0 n_skip=0
  while IFS= read -r loc; do
    [ -z "$loc" ] && continue
    [ "$loc" = "$canon" ] && continue
    IFS=$'\x1f' read -r lkind lhost lpath lref < <(loc_parse "$loc")
    if [ "$lkind" = "external" ] || [ "$lkind" = "bad" ] || [ -n "$lhost" ]; then
      print_warning "  skip (not writable from here): $loc"; n_skip=$((n_skip+1)); continue
    fi
    lval=$(loc_read "$lkind" "$(loc_abspath "$lpath")" "$lref")
    if [ "$lval" = "$canonval" ]; then lval=""; n_ok=$((n_ok+1)); continue; fi
    lval=""
    if [ "$DRY" = 1 ]; then print_info "  would update: $loc"; n_write=$((n_write+1)); continue; fi
    NWP_NEWVAL="$canonval" write_value_to_location "$loc" && n_write=$((n_write+1))
  done < <(entry_locations "$idx")
  canonval=""
  printf "  %d already correct · %d %s · %d skipped\n" \
    "$n_ok" "$n_write" "$([ "$DRY" = 1 ] && echo 'would update' || echo updated)" "$n_skip"
  [ "$n_skip" -gt 0 ] && print_hint "remote/external copies: pl secrets verify-copy $id"
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
      "$YQ" e '.secrets[].stored_in[]?' "$REGISTRY" 2>/dev/null | grep -qxF ".secrets.yml:$k" && continue
      "$YQ" e '.ignored_keys[]? // ""' "$REGISTRY" 2>/dev/null | grep -qxF "$k" && continue
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
  print_header "Undeclared copies of registry-known credentials"

  # hash -> id  for every canonical value we can read
  local -A known=(); local -A declared=()
  local n i id canon ckind chost cpath cref v loc lkind lhost lpath lref
  n=$("$YQ" e '.secrets | length' "$REGISTRY"); [ "$n" = "null" ] && n=0
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
      { [ "$lkind" = "external" ] || [ "$lkind" = "bad" ] || [ -n "$lhost" ]; } && continue
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

  [ "$found" -eq 0 ] && { print_success "no undeclared copies found"; return 0; }
  print_hint "declare them in the entry's stored_in (then `pl secrets sync <id>` keeps them true) — or delete the copy"
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
    case "$lkind" in
      file) remote_cmd="head -1 '$lpath' | tr -d '\\n' | sha256sum | cut -d' ' -f1" ;;
      env)  remote_cmd="grep -E '^(export )?$lref=' '$lpath' | head -1 | sed -E 's/^(export )?$lref=//; s/^\"//; s/\"\$//' | tr -d '\\n' | sha256sum | cut -d' ' -f1" ;;
      yaml) remote_cmd="yq e '.$lref // \"\"' '$lpath' | tr -d '\\n' | sha256sum | cut -d' ' -f1" ;;
      json) remote_cmd="jq -r '($lref) // \"\"' '$lpath' | tr -d '\\n' | sha256sum | cut -d' ' -f1" ;;
      *)    print_warning "  $lhost: cannot verify kind '$lkind'"; continue ;;
    esac
    rhash=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$lhost" "$remote_cmd" 2>/dev/null)
    if [ -z "$rhash" ]; then
      print_warning "  UNREACHABLE  $lhost — $lpath (cannot verify)"; problems=$((problems+1))
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
  capabilities|caps) cmd_capabilities "$@" ;;
  surfaces)       cmd_surfaces "$@" ;;
  rotate)         cmd_rotate "$@" ;;
  done)           cmd_done "$@" ;;
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
  pl secrets rotate <#|id>       guided/assisted rotation (hidden value entry; # from status)
  pl secrets rotate --due        rotate everything expiring within 14 days / untracked
  pl secrets done <#|id> [date]  record a rotation you did by hand (stamps expiry + log)
  pl secrets get <dotted.key>    copy a value to the clipboard (never printed)
  pl secrets whose <#|id>        ask GitLab which user/bot/project owns the token
  pl secrets audit [--days N]    LIVE probe of EVERY declared location: valid? real expiry? drift?
                                 [--locations] row per location · [--json] machine envelope
                                 [--sync] write live expiry back · [--quiet] for cron
  pl secrets sync <#|id>         propagate the canonical value to every declared location (repair verb)
  pl secrets adopt <dotted.key>  register a .secrets.yml key that lint reported as undeclared
  pl secrets discover-copies     find copies of a known credential the registry does NOT declare
  pl secrets verify-copy <#|id>  check host=… remote copies by SHA-256 over ssh (value never crosses)
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
