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

REGISTRY="${NWP_SECRETS_REGISTRY:-$PROJECT_ROOT/private/secrets-registry.yml}"
SECRETS_FILE="${NWP_SECRETS_FILE:-$PROJECT_ROOT/.secrets.yml}"
ROT_LOG="$PROJECT_ROOT/private/rotation-$(date +%Y-%m).md"
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

field(){ "$YQ" e ".secrets[$1].$2 // \"\"" "$REGISTRY" 2>/dev/null | grep -v '^null$'; }

days_until(){ # ISO date -> integer days from now (empty/unknown -> "")
  local d="$1" e; [ -z "$d" ] || [ "$d" = "unknown" ] && return 0
  e=$(date -d "$d" +%s 2>/dev/null) || return 0
  echo $(( (e - $(date +%s)) / 86400 ))
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
      NWP_REF="$ref" NWP_NEWVAL="$NWP_NEWVAL" perl -i -pe \
        's/^(export\s+)?\Q$ENV{NWP_REF}\E=.*/($1//"")."$ENV{NWP_REF}=\"$ENV{NWP_NEWVAL}\""/e' "$path" \
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
################################################################################
cmd_scan(){
  need_yq
  local TMP; TMP="$(mktemp)"; chmod 600 "$TMP"
  { "$YQ" e '.. | select(tag == "!!str")' "$SECRETS_FILE" 2>/dev/null
    cut -d= -f2- "$HOME/.nwp-agent-loop.env" 2>/dev/null
  } | tr -d '"'\' | sed -E 's/[[:space:]]+$//' \
    | grep -E '^[A-Za-z0-9_./+=:-]{16,}$' | grep -vE '^(https?://|/home/|~/|[0-9]+$)' \
    | sort -u > "$TMP"
  local nvals; nvals=$(wc -l < "$TMP")
  local PAT='glpat-[A-Za-z0-9_-]{20,}|github_pat_[A-Za-z0-9_]{40,}|gh[pousr]_[A-Za-z0-9]{36,}|sk-ant-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  print_header "Secret leak scan ($nvals live values + shape patterns)"
  local surfaces=("$HOME/.claude/projects" "$HOME/.claude/prompts.log" "$HOME/.bash_history" "$PROJECT_ROOT/private" "$PROJECT_ROOT/logs")
  local hit=0 s
  for s in "${surfaces[@]}"; do
    [ -e "$s" ] || continue
    while IFS= read -r f; do
      [ -z "$f" ] && continue; hit=1
      local c; c=$(grep -F -o -f "$TMP" "$f" 2>/dev/null | sort -u | wc -l)
      printf "  ${RED}LEAK${NC} %-3s value(s) + shape  %s\n" "$c" "$f"
    done < <( { [ -s "$TMP" ] && grep -rlF -f "$TMP" "$s" 2>/dev/null; grep -rlE "$PAT" "$s" 2>/dev/null; } | sort -u )
  done
  rm -f "$TMP"
  [ "$hit" = "0" ] && print_success "no secret values or shaped strings found in any surface"
  [ "$hit" = "1" ] && print_hint "rotate the affected secrets (their values become worthless), then re-run scan"
}

################################################################################
# scrub — redact secret strings (pattern + live value) in place
################################################################################
cmd_scrub(){
  need_yq
  local ASSUME=0; { [ "${1:-}" = "-y" ] || [ "${1:-}" = "--yes" ]; } && { ASSUME=1; shift; }
  local today; today=$(date +%F)
  local TMP; TMP="$(mktemp)"; chmod 600 "$TMP"
  { "$YQ" e '.. | select(tag == "!!str")' "$SECRETS_FILE" 2>/dev/null
    cut -d= -f2- "$HOME/.nwp-agent-loop.env" 2>/dev/null
  } | tr -d '"'\' | sed -E 's/[[:space:]]+$//' \
    | grep -E '^[A-Za-z0-9_./+=:-]{16,}$' | grep -vE '^(https?://|/home/|~/|[0-9]+$)' \
    | sort -u > "$TMP"
  local PAT='glpat-[A-Za-z0-9_-]{20,}|github_pat_[A-Za-z0-9_]{40,}|gh[pousr]_[A-Za-z0-9]{36,}|sk-ant-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|AKIA[0-9A-Z]{16}'
  print_header "Scrub secret strings (pattern + live value) -> [REDACTED-$today]"

  local -a targets=("$@") roots=("$HOME/.claude/projects" "$HOME/.claude/prompts.log" "$HOME/.bash_history" "$PROJECT_ROOT/private")
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

  echo
  [ "$issues" -eq 0 ] && print_success "LINT PASS — registry and .secrets.yml are consistent" \
    || { print_error "LINT: $issues issue(s) above"; return 1; }
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
# main
################################################################################
sub="${1:-status}"; shift || true
case "$sub" in
  status|list|ls) cmd_status "$@" ;;
  keys|tree|structure) cmd_keys "$@" ;;
  set)            cmd_set "$@" ;;
  scaffold)       cmd_scaffold "$@" ;;
  rotate)         cmd_rotate "$@" ;;
  done)           cmd_done "$@" ;;
  get)            cmd_get "$@" ;;
  whose)          cmd_whose "$@" ;;
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
  pl secrets lint                cross-check the registry against .secrets.yml (orphans, comment-secrets, gaps)
  pl secrets scan                leak sweep over transcripts, logs, history
  pl secrets scrub [files...]    redact secret strings (pattern + value) in place
  pl secrets check               show what the pl-todo expiry alert would report

Registry (tokenless): $REGISTRY
EOF
    ;;
  *) die "unknown subcommand: $sub (try: pl secrets help)" ;;
esac
