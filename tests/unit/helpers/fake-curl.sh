#!/bin/bash
# fake-curl — offline stand-in for curl, used by the `pl secrets` unit tests.
#
# It understands the two shapes secrets.sh actually uses:
#   1. `curl -K <cfg>`  — a 0600 curl config carrying `url = "..."` and
#      `header = "PRIVATE-TOKEN: <value>"` (or `Authorization: Bearer <value>`).
#      Emits a canned JSON body, or the http_code when the cfg sets write-out.
#   2. `curl -s -o /dev/null -w '%{http_code}' ... <url>` — the reachability probe.
#
# THREE shapes now, and the difference matters:
#   * write-out WITH `output = "/dev/null"`  -> the caller wants ONLY the code
#     (_audit_code, and the argv-form reachability probe).
#   * write-out WITHOUT `output`             -> the caller wants BODY then the
#     code appended (_audit_status_body, which needs both to tell "rejected"
#     from "no answer"). Modelling this as code-only made every probe return an
#     unparseable body, so a healthy token read UNKNOWN.
#   * no write-out                           -> body only.
#
# Liveness is driven by a fixture file whose path is in $FAKE_CURL_ALIVE: one
# token value per line = "this token is alive". Anything else is treated as
# revoked. $FAKE_CURL_ADMIN (optional) lists values that report is_admin:true.
# $FAKE_CURL_403 (optional) lists "value<TAB>url-substring" pairs that 403.
set -uo pipefail

cfg=""; url=""; want_code=0; want_suffix=0; val=""; method="GET"
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    -K) cfg="${args[$((i+1))]}" ;;
    -w|--write-out) want_code=1 ;;
    -X|--request) method="${args[$((i+1))]}" ;;
    http*://*) url="${args[$i]}" ;;
  esac
done

if [ -n "$cfg" ] && [ -f "$cfg" ]; then
  url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg" | head -1)
  val=$(sed -n 's/^header = "[^:]*: *\(.*\)"$/\1/p' "$cfg" | head -1)
  val="${val#Bearer }"
  if grep -q '^write-out' "$cfg"; then
    # `output = "/dev/null"` present -> caller wants ONLY the code.
    # write-out with no output       -> caller wants BODY then the code.
    if grep -q '^output' "$cfg"; then want_code=1; else want_suffix=1; fi
  fi
  m=$(sed -n 's/^request = "\(.*\)"$/\1/p' "$cfg" | head -1)
  [ -n "$m" ] && method="$m"
fi

# Emit per the requested shape. Every branch below sets $body and $code and
# then calls this, so the three shapes stay consistent.
emit() { # $1=body $2=code
  if [ "$want_code" = 1 ];   then printf '%s' "$2"
  elif [ "$want_suffix" = 1 ]; then printf '%s\n%s' "$1" "$2"
  else printf '%s' "$1"; fi
  exit 0
}

# Transport failure. curl reports an unreachable host as exit 7 with an EMPTY
# body; with -w '%{http_code}' that renders as the literal "000". The audit's
# reachability gate keys off exactly that, so the blindness tests need it.
#   FAKE_CURL_UNREACHABLE=1  — every call fails, forever (a real outage)
#   FAKE_CURL_FLAP=<file>    — the file holds a countdown; that many calls fail
#                              and then the host comes back (a transient flap,
#                              which retry must absorb rather than alarm on)
unreachable=0
[ "${FAKE_CURL_UNREACHABLE:-0}" = "1" ] && unreachable=1
if [ -n "${FAKE_CURL_FLAP:-}" ] && [ -f "$FAKE_CURL_FLAP" ]; then
  n=$(head -1 "$FAKE_CURL_FLAP" 2>/dev/null); n="${n//[!0-9]/}"
  if [ "${n:-0}" -gt 0 ]; then
    unreachable=1
    printf '%s\n' "$(( n - 1 ))" > "$FAKE_CURL_FLAP"
  fi
fi
if [ "$unreachable" = 1 ]; then
  [ "$want_code" = 1 ] && printf '000'
  exit 7
fi

alive=0
if [ -n "${FAKE_CURL_ALIVE:-}" ] && [ -f "$FAKE_CURL_ALIVE" ] && [ -n "$val" ]; then
  grep -qxF "$val" "$FAKE_CURL_ALIVE" && alive=1
fi
is_admin=false
if [ -n "${FAKE_CURL_ADMIN:-}" ] && [ -f "$FAKE_CURL_ADMIN" ] && [ -n "$val" ]; then
  grep -qxF "$val" "$FAKE_CURL_ADMIN" && is_admin=true
fi

# forced-403 matrix (value<TAB>url-substring)
if [ -n "${FAKE_CURL_403:-}" ] && [ -f "$FAKE_CURL_403" ] && [ -n "$val" ]; then
  while IFS=$'\t' read -r v frag; do
    [ -z "${frag:-}" ] && continue
    if [ "$v" = "$val" ] && [[ "$url" == *"$frag"* ]]; then
      emit '{"message":"403 Forbidden"}' 403
    fi
  done < "$FAKE_CURL_403"
fi

# The "create-without-creating" idiom. A creating endpoint POSTed with an EMPTY
# body separates the authorization layer from the validation layer: a token that
# may NOT create is refused at 401/403 and never reaches validation; a token that
# MAY create gets past authorization and is then rejected 400 for the empty body,
# having created nothing. Modelling it here keeps the probe honest offline.
if [ "$method" = "POST" ]; then
  case "$url" in
    */merge_requests|*/issues)
      if [ "$alive" = 1 ]; then
        emit '{"message":"400 Bad Request"}' 400
      fi
      emit '{"message":"401 Unauthorized"}' 401 ;;
  esac
fi

case "$url" in
  */api/v4/metadata)
    emit '{"version":"18.7.7"}' 200 ;;
  */api/v4/user)
    if [ "$alive" = 1 ]; then
      emit "$(printf '{"id":27,"username":"fixture_bot","name":"fixture","is_admin":%s}' "$is_admin")" 200
    else
      emit '{"message":"401 Unauthorized"}' 401
    fi ;;
  */personal_access_tokens/self)
    if [ "$alive" = 1 ]; then
      emit "$(printf '{"active":true,"revoked":false,"expires_at":"%s","scopes":["api"],"access_level":30}' "${FAKE_CURL_EXPIRES:-2099-01-01}")" 200
    else
      emit '{"active":false,"revoked":true,"expires_at":null}' 401
    fi ;;
  *)
    if [ "$alive" = 1 ]; then emit '{"ok":true}' 200; else emit '{"message":"401 Unauthorized"}' 401; fi ;;
esac
exit 0
