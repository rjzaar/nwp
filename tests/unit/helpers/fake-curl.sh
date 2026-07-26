#!/bin/bash
# fake-curl — offline stand-in for curl, used by the `pl secrets` unit tests.
#
# It understands the two shapes secrets.sh actually uses:
#   1. `curl -K <cfg>`  — a 0600 curl config carrying `url = "..."` and
#      `header = "PRIVATE-TOKEN: <value>"` (or `Authorization: Bearer <value>`).
#      Emits a canned JSON body, or the http_code when the cfg sets write-out.
#   2. `curl -s -o /dev/null -w '%{http_code}' ... <url>` — the reachability probe.
#
# Liveness is driven by a fixture file whose path is in $FAKE_CURL_ALIVE: one
# token value per line = "this token is alive". Anything else is treated as
# revoked. $FAKE_CURL_ADMIN (optional) lists values that report is_admin:true.
# $FAKE_CURL_403 (optional) lists "value<TAB>url-substring" pairs that 403.
set -uo pipefail

cfg=""; url=""; want_code=0; val=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    -K) cfg="${args[$((i+1))]}" ;;
    -w|--write-out) want_code=1 ;;
    http*://*) url="${args[$i]}" ;;
  esac
done

if [ -n "$cfg" ] && [ -f "$cfg" ]; then
  url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg" | head -1)
  val=$(sed -n 's/^header = "[^:]*: *\(.*\)"$/\1/p' "$cfg" | head -1)
  val="${val#Bearer }"
  grep -q '^write-out' "$cfg" && want_code=1
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
      [ "$want_code" = 1 ] && { printf '403'; exit 0; }
      printf '{"message":"403 Forbidden"}'; exit 0
    fi
  done < "$FAKE_CURL_403"
fi

case "$url" in
  */api/v4/metadata)
    [ "$want_code" = 1 ] && { printf '200'; exit 0; }
    printf '{"version":"18.7.7"}' ;;
  */api/v4/user)
    if [ "$alive" = 1 ]; then
      [ "$want_code" = 1 ] && { printf '200'; exit 0; }
      printf '{"id":27,"username":"fixture_bot","name":"fixture","is_admin":%s}' "$is_admin"
    else
      [ "$want_code" = 1 ] && { printf '401'; exit 0; }
      printf '{"message":"401 Unauthorized"}'
    fi ;;
  */personal_access_tokens/self)
    if [ "$alive" = 1 ]; then
      printf '{"active":true,"revoked":false,"expires_at":"%s","scopes":["api"],"access_level":30}' "${FAKE_CURL_EXPIRES:-2099-01-01}"
    else
      printf '{"active":false,"revoked":true,"expires_at":null}'
    fi ;;
  *)
    if [ "$want_code" = 1 ]; then
      [ "$alive" = 1 ] && printf '200' || printf '401'
    else
      [ "$alive" = 1 ] && printf '{"ok":true}' || printf '{"message":"401 Unauthorized"}'
    fi ;;
esac
exit 0
