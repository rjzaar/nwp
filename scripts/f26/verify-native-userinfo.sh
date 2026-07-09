#!/usr/bin/env bash
#
# F26 rec (a) — prove the NATIVE simple_oauth userinfo endpoint returns the
# expected OIDC claims (including the custom `guilds` guild-membership claim)
# for a VALID access token, now that the custom nwc_moodle_oauth controller has
# been removed and nwc_oidc_claims injects the guild claim on the native path.
#
#   NOT read-only: this mints a short-lived (1h) dev access token for a
#   guild-member user so it can call userinfo. Dev-only. Never run against prod.
#
# What it does:
#   1. Mints a signed RS256 access token (openid/profile/email) for a chosen
#      user via simple_oauth's own repositories (no browser round-trip needed),
#      persists it so the resource server accepts it, and prints the JWT.
#   2. Calls /oauth/userinfo with that bearer and asserts HTTP 200 + the guild
#      claim + a standard profile claim (email).
#   3. Calls /oauth/userinfo with a bogus bearer and asserts HTTP 401.
#
# Usage: scripts/f26/verify-native-userinfo.sh [ddev-project-dir] [uid]
#   uid defaults to 1 (the admin, which the provisioned nwc-dev seeds into
#   several guilds). Pick any uid that belongs to at least one *guild* group.
set -uo pipefail

SITE_DIR="${1:-$HOME/nwp/sites/nwc/dev}"
UID_ARG="${2:-1}"
cd "$SITE_DIR"
drush() { ddev drush "$@"; }
BASE="$(drush php:eval 'print \Drupal::request()->getSchemeAndHttpHost();' 2>/dev/null || echo 'https://nwc-dev.ddev.site')"
HOST="${BASE#https://}"; HOST="${HOST#http://}"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

echo "== F26 native-userinfo verification against $BASE (uid=$UID_ARG) =="

# 1. Mint a valid access token via a temporary drush php:script.
MINT="$SITE_DIR/.f26-mint-$$.php"
cat > "$MINT" <<'PHP'
<?php
use Drupal\simple_oauth\Entities\ClientEntity;
use League\OAuth2\Server\CryptKey;
$uid = getenv('F26_UID') ?: '1';
$etm = \Drupal::entityTypeManager();
$consumers = $etm->getStorage('consumer')->loadByProperties(['client_id' => 'ss_moodle']);
$consumer = $consumers ? reset($consumers) : NULL;
if (!$consumer) { print "ERR:NO_CLIENT\n"; return; }
$client = new ClientEntity($consumer);
$scopeRepo = \Drupal::service('simple_oauth.repositories.scope');
$scopes = [];
foreach (['openid', 'profile', 'email'] as $sid) {
  $s = $scopeRepo->getScopeEntityByIdentifier($sid);
  if ($s) { $scopes[] = $s; }
}
$repo = \Drupal::service('simple_oauth.repositories.access_token');
$token = $repo->getNewToken($client, $scopes, (string) $uid);
$token->setIdentifier(bin2hex(random_bytes(20)));
$token->setExpiryDateTime(new \DateTimeImmutable('+1 hour'));
$keyPath = \Drupal::config('simple_oauth.settings')->get('private_key');
$real = \Drupal::service('file_system')->realpath($keyPath) ?: $keyPath;
$perm = \Drupal\Core\Site\Settings::get('simple_oauth.key_permissions_check', TRUE);
$token->setPrivateKey(new CryptKey($real, NULL, $perm));
$repo->persistNewAccessToken($token);
print $token->convertToJWT()->toString() . "\n";
PHP
JWT="$(F26_UID="$UID_ARG" ddev exec sh -c "F26_UID=$UID_ARG drush php:script $(basename "$MINT")" 2>/dev/null | tr -d '\r' | tail -1)"
rm -f "$MINT"
if [ -z "$JWT" ] || [[ "$JWT" == ERR:* ]] || [[ "$JWT" == Error:* ]]; then
  no "could not mint a dev access token (${JWT:-empty})"
  echo "== $pass passed, $fail failed =="; exit 1
fi
ok "minted a signed RS256 access token for uid=$UID_ARG"

# 2. Valid token -> native userinfo returns claims incl guilds. Two calls with
#    the same token: one for the body, one for the status code (avoids fragile
#    inline status parsing through `ddev exec`).
BODY="$(ddev exec curl -sk -H "Host: $HOST" -H "Authorization: Bearer $JWT" "https://localhost/oauth/userinfo" 2>/dev/null)"
CODE="$(ddev exec curl -sk -o /dev/null -w '%{http_code}' -H "Host: $HOST" -H "Authorization: Bearer $JWT" "https://localhost/oauth/userinfo" 2>/dev/null)"
if [[ "$CODE" == "200" ]] && echo "$BODY" | grep -q '"guilds"' && echo "$BODY" | grep -q '"email"'; then
  ok "native userinfo returns 200 with guild claim + standard claims (email)"
else
  no "native userinfo did not return the expected claims (HTTP $CODE): $BODY"
fi
echo "  userinfo (valid token): $BODY"

# 3. Bogus token -> 401.
BADTOK="not.a.valid.token"
CODE="$(ddev exec curl -sk -o /dev/null -w '%{http_code}' -H "Host: $HOST" -H "Authorization: Bearer $BADTOK" "https://localhost/oauth/userinfo" 2>/dev/null)"
[[ "$CODE" == "401" ]] && ok "native userinfo rejects an invalid token (401)" || no "invalid token returned $CODE (expected 401)"

echo "== $pass passed, $fail failed =="
[[ $fail -eq 0 ]]
