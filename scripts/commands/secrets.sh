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
# audit — LIVE token validity + REAL expiry + drift (the daily-check engine)
#   Probes each provisioned token at its provider. Token values NEVER printed
#   (0600 curl config, like `whose`). Exits non-zero if any token is DEAD or
#   expiring within the warning window — so cron / pl doctor can alert.
#   Flags: --days N (warn window, default 14) · --sync (write live expiry back
#          to the registry, fixing drift) · --quiet (machine output for cron)
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
cmd_audit(){
  need_yq; need_registry
  command -v curl >/dev/null || die "curl required"
  local WARN=14 SYNC=0 QUIET=0
  while [ $# -gt 0 ]; do case "$1" in
    --days) WARN="${2:-14}"; shift 2;;
    --sync) SYNC=1; shift;;
    --quiet|-q) QUIET=1; shift;;
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
    print_header "Live token audit — probes each provider (values never printed)"
    printf "  %-26s %-7s %-9s %-12s %-12s %s\n" "ID" "PROV" "LIVE" "EXPIRES" "RECORDED" "NOTE"
    printf "  %-26s %-7s %-9s %-12s %-12s %s\n" "--------------------------" "-------" "---------" "------------" "------------" "----"
  fi
  local n i problems=0 dead=0 expiring=0 drift=0
  n=$("$YQ" e '.secrets | length' "$REGISTRY"); [ "$n" = "null" ] && n=0
  for ((i=0;i<n;i++)); do
    local id prov st recorded key val live liveexp note col d useexp host
    id=$(field "$i" id); prov=$(field "$i" provider); st=$(field "$i" status); recorded=$(field "$i" expires)
    [ "$st" = "not-provisioned" ] && continue
    key=$("$YQ" e ".secrets[$i].stored_in[]?" "$REGISTRY" 2>/dev/null | grep -oE '^\.secrets\.yml:[A-Za-z0-9_.]+' | head -1 | sed 's/^\.secrets\.yml://')
    live="SKIP"; liveexp=""; note=""
    if [ -n "$key" ]; then
      val=$("$YQ" e ".$key // \"\"" "$SECRETS_FILE" 2>/dev/null)
      if [ -z "$val" ] || [ "$val" = "null" ]; then live="EMPTY"; note="not provisioned"
      else
        local nsc; nsc=$("$YQ" e ".secrets[$i].scopes // [] | length" "$REGISTRY" 2>/dev/null)
        if [ "${nsc:-0}" -eq 0 ]; then live="SKIP"; note="no API scope (password/app cred — recorded-date only)"
        else
        case "$prov" in
          gitlab)
            host=$(field "$i" rotate_url | sed -E 's|https?://([^/]+).*|\1|')
            { [ -z "$host" ] || [ "$host" = "$(field "$i" rotate_url)" ]; } && host="$host_default"
            if [ -z "$host" ]; then live="SKIP"; note="no host"; else
              local ujson pjson uname active revoked isadmin
              ujson=$(_audit_body "https://$host/api/v4/user" "PRIVATE-TOKEN" "$val")
              uname=$("$YQ" e -p=json '.username // ""' <<<"$ujson" 2>/dev/null | grep -v '^null$')
              if [ -z "$uname" ]; then live="DEAD"
              else
                pjson=$(_audit_body "https://$host/api/v4/personal_access_tokens/self" "PRIVATE-TOKEN" "$val")
                active=$("$YQ" e -p=json '.active // ""' <<<"$pjson" 2>/dev/null)
                revoked=$("$YQ" e -p=json '.revoked // ""' <<<"$pjson" 2>/dev/null)
                liveexp=$("$YQ" e -p=json '.expires_at // ""' <<<"$pjson" 2>/dev/null | grep -v '^null$')
                isadmin=$("$YQ" e -p=json '.is_admin // ""' <<<"$ujson" 2>/dev/null | grep -v '^null$')
                if [ "$revoked" = "true" ] || [ "$active" = "false" ]; then live="DEAD"; else live="OK"; fi
                [ "$isadmin" = "true" ] && note="ADMIN! "
              fi
            fi ;;
          github) [ "$(_audit_code "https://api.github.com/user" "Authorization: Bearer" "$val")" = "200" ] && live="OK" || live="DEAD" ;;
          linode) [ "$(_audit_code "https://api.linode.com/v4/profile" "Authorization: Bearer" "$val")" = "200" ] && live="OK" || live="DEAD" ;;
          *) live="SKIP"; note="no live API (recorded-date only)" ;;
        esac
        fi
      fi
    else live="SKIP"; note="value not on this host"; fi
    val=""
    useexp="$liveexp"; { [ -z "$useexp" ]; } && useexp="$recorded"
    d=$(days_until "$useexp")
    if [ -n "$liveexp" ] && [ -n "$recorded" ] && [ "$recorded" != "unknown" ] && [ "$liveexp" != "$recorded" ]; then
      note="${note}DRIFT(rec=$recorded) "; drift=$((drift+1))
      [ "$SYNC" = 1 ] && { "$YQ" e -i ".secrets[$i].expires = \"$liveexp\"" "$REGISTRY" && note="${note}[synced] "; }
    fi
    case "$live" in
      DEAD)  col="$RED";    dead=$((dead+1));     problems=$((problems+1)); note="REVOKED/INVALID ${note}" ;;
      OK)    if   [ -n "$d" ] && [ "$d" -lt 0 ]      2>/dev/null; then col="$RED";    note="EXPIRED ${note}";        expiring=$((expiring+1)); problems=$((problems+1))
             elif [ -n "$d" ] && [ "$d" -le "$WARN" ] 2>/dev/null; then col="$YELLOW"; note="expires in ${d}d ${note}"; expiring=$((expiring+1)); problems=$((problems+1))
             else col="$GREEN"; fi ;;
      *)     col="$DIM" ;;
    esac
    if [ "$QUIET" = 0 ]; then
      printf "  ${col}%-26s${NC} %-7s ${col}%-9s${NC} %-12s %-12s %s\n" "$id" "$prov" "$live" "${liveexp:--}" "${recorded:-unknown}" "$note"
    elif [ "$live" = "DEAD" ] || { [ "$live" = "OK" ] && [ -n "$d" ] && [ "$d" -le "$WARN" ] 2>/dev/null; }; then
      printf '%s\t%s\t%s\t%s\n' "$id" "$live" "${useexp:-unknown}" "$note"
    fi
  done
  if [ "$QUIET" = 0 ]; then
    echo; printf "  %d dead · %d expiring(≤%dd) · %d drift\n" "$dead" "$expiring" "$WARN" "$drift"
    [ "$problems" -eq 0 ] && print_success "all live tokens valid and outside the ${WARN}-day window" \
      || print_hint "reissue a token: pl secrets steps <id> → create it → pl secrets rotate <id>"
    [ "$drift" -gt 0 ] && [ "$SYNC" = 0 ] && print_hint "sync recorded expiry to live truth: pl secrets audit --sync"
  fi
  [ "$problems" -gt 0 ] && return 1 || return 0
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
  local WRITE=0 only="" a
  for a in "$@"; do case "$a" in --write) WRITE=1;; -*) ;; *) only="$a";; esac; done
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
  if [ "$WRITE" = 1 ]; then
    local dest="$PROJECT_ROOT/private/token-consumers.md"
    { printf '# Token → code consumers  (generated by `pl secrets consumers --write`)\n\n'
      printf 'Which lib/ + scripts/ functions reference each token. Regenerate after code changes.\n\n'
      cat "$out"; } > "$dest"
    print_success "wrote $dest"
  else
    print_header "Token → code consumers  (lib/ + scripts/)"
    cat "$out"
  fi
  rm -f "$out"
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
        local stg_ddev="$PROJECT_ROOT/sites/$base/stg/.ddev/config.yaml"
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
  pl secrets audit [--days N]    LIVE probe: is each token valid? real expiry? drift? (--sync fixes drift, --quiet for cron)
  pl secrets steps <#|id>        print the exact reissue procedure for one entry
  pl secrets consumers [--write] map each token to the code/functions that read it (--write → private/token-consumers.md)
  pl secrets inject <site> --tier=stg|live [--dry-run|--apply]
                                 registry-driven env-config + cross-site token injection (§6 P0-4):
                                 Drupal → settings.local.overrides.php + drush cr; Moodle → admin/cli/cfg.php.
                                 DRY-RUN default; prints key-paths + targets ONLY, never values (ADR-0017).
  pl secrets lint                cross-check the registry against .secrets.yml (orphans, comment-secrets, gaps)
  pl secrets scan                leak sweep over transcripts, logs, history
  pl secrets scrub [files...]    redact secret strings (pattern + value) in place
  pl secrets check               show what the pl-todo expiry alert would report

Registry (tokenless): $REGISTRY
EOF
    ;;
  *) die "unknown subcommand: $sub (try: pl secrets help)" ;;
esac
