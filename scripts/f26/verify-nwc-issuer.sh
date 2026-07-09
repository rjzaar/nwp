#!/usr/bin/env bash
#
# F26 — verify the nwc OIDC issuer is serving the endpoints Moodle needs.
# Dev-only smoke test. Does NOT need real Moodle. Read-only (issues no writes).
#
# Checks:
#   1. JWKS is served and contains at least one key (=> signing keys registered).
#   2. /oauth/userinfo (now served by the NATIVE simple_oauth endpoint after F26
#      rec (a) removed the custom nwc_moodle_oauth controller) rejects an
#      unauthenticated request: a no-token request is bounced to login (3xx) and
#      an INVALID bearer token gets 401 — i.e. not open, no anonymous shortcut,
#      no claim leak.
#   3. /oauth/authorize responds (302/200/400 — i.e. the route exists and runs,
#      not a 404) to a well-formed authorization-code request for our client.
#   4. The ss_moodle consumer exists, is confidential, and has PKCE required.
#   5. OIDC discovery (F26 rec (b)): /.well-known/openid-configuration serves
#      valid metadata with issuer, jwks_uri and the authz/token/userinfo
#      endpoints (=> Moodle can auto-configure instead of hand-entering URLs).
#
# For a positive proof that the native userinfo returns the expected claims
# (including the guild claims) for a VALID token, see the companion script
# scripts/f26/verify-native-userinfo.sh (that one mints a short-lived dev token
# and is therefore NOT read-only).
#
# Usage: scripts/f26/verify-nwc-issuer.sh [ddev-project-dir]
set -uo pipefail

SITE_DIR="${1:-$HOME/nwp/sites/nwc/dev}"
cd "$SITE_DIR"
drush() { ddev drush "$@"; }
BASE="$(drush php:eval 'print \Drupal::request()->getSchemeAndHttpHost();' 2>/dev/null || echo 'https://nwc-dev.ddev.site')"
HOST="${BASE#https://}"; HOST="${HOST#http://}"
c() { ddev exec curl -sk -o /dev/null -w '%{http_code}' -H "Host: $HOST" "https://localhost$1" ${2:+$2}; }
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

echo "== F26 issuer verification against $BASE =="

# 1. JWKS
JWKS="$(ddev exec curl -sk -H "Host: $HOST" "https://localhost/.well-known/jwks.json" 2>/dev/null)"
if echo "$JWKS" | grep -q '"keys"' && echo "$JWKS" | grep -q '"kty"'; then
  ok "JWKS served with a key (signing keys registered)"
else
  no "JWKS missing/empty -> keys not registered (run provision-nwc-issuer.sh)"
fi

# 2a. userinfo with NO token -> rejected (native endpoint bounces cookie-anon to
#     login: 3xx/403/401). Must NOT be 200 (that would mean it served claims).
BODY_ANON="$(ddev exec curl -sk -H "Host: $HOST" "https://localhost/oauth/userinfo" 2>/dev/null)"
CODE="$(ddev exec curl -sk -o /dev/null -w '%{http_code}' -H "Host: $HOST" "https://localhost/oauth/userinfo" 2>/dev/null)"
if [[ "$CODE" != "200" ]] && ! echo "$BODY_ANON" | grep -q '"sub"'; then
  ok "userinfo rejects no-token request (HTTP $CODE, no claims served)"
else
  no "userinfo served content to an anonymous request (HTTP $CODE) — auth surface must not be open"
fi

# 2b. userinfo with an INVALID bearer token -> 401 (OIDC-correct rejection).
BADTOK="not.a.valid.token"
CODE="$(ddev exec curl -sk -o /dev/null -w '%{http_code}' -H "Host: $HOST" -H "Authorization: Bearer $BADTOK" "https://localhost/oauth/userinfo" 2>/dev/null)"
[[ "$CODE" == "401" ]] && ok "userinfo rejects an invalid bearer token (401)" || no "userinfo returned $CODE for an invalid token (expected 401)"

# 3. authorize route runs (not 404)
AUTHZ="/oauth/authorize?response_type=code&client_id=ss_moodle&redirect_uri=https%3A%2F%2Fss-dev.ddev.site%2Fadmin%2Foauth2callback.php&scope=openid%20email%20profile&state=x&code_challenge=abc&code_challenge_method=S256"
CODE="$(ddev exec curl -sk -o /dev/null -w '%{http_code}' -H "Host: $HOST" "https://localhost$AUTHZ" 2>/dev/null)"
[[ "$CODE" != "404" && -n "$CODE" ]] && ok "authorize route runs (HTTP $CODE, not 404)" || no "authorize route 404 — simple_oauth not routing"

# 4. consumer sanity
INFO="$(drush php:eval '
$e=\Drupal::entityTypeManager()->getStorage("consumer")->loadByProperties(["client_id"=>"ss_moodle"]);
if(!$e){print "MISSING"; return;}
$c=reset($e);
printf("pkce=%s conf=%s redirects=%d scopes=%d",
 $c->get("pkce")->value?1:0, $c->get("confidential")->value?1:0,
 count($c->get("redirect")), $c->hasField("scopes")?count($c->get("scopes")):0);
' 2>/dev/null)"
echo "  consumer: $INFO"
if echo "$INFO" | grep -q 'pkce=1' && echo "$INFO" | grep -q 'conf=1'; then
  ok "ss_moodle consumer is confidential + PKCE required"
else
  no "ss_moodle consumer missing/weak ($INFO)"
fi

# 5. OIDC discovery (.well-known/openid-configuration) — F26 rec (b).
DISCO="$(ddev exec curl -sk -H "Host: $HOST" "https://localhost/.well-known/openid-configuration" 2>/dev/null)"
missing=""
for key in '"issuer"' '"jwks_uri"' '"authorization_endpoint"' '"token_endpoint"' '"userinfo_endpoint"'; do
  echo "$DISCO" | grep -q "$key" || missing="$missing ${key//\"/}"
done
if echo "$DISCO" | grep -q '"issuer"' && [ -z "$missing" ]; then
  ok "discovery serves openid-configuration (issuer + jwks_uri + authz/token/userinfo endpoints)"
else
  no "discovery missing/incomplete (absent:${missing:- none but issuer not found}) — is simple_oauth_server_metadata enabled?"
fi

echo "== $pass passed, $fail failed =="
[[ $fail -eq 0 ]]
