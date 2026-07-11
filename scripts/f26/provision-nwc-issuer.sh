#!/usr/bin/env bash
#
# F26 / nwc<->ss OIDC — provision nwc (Drupal) as the OpenID Connect issuer.
#
#   AUTH SURFACE — REQUIRES HUMAN REVIEW BEFORE RUN AGAINST ANYTHING BUT DEV.
#
# This script is idempotent and dev-only. It configures simple_oauth (6.1.1,
# already installed + enabled on nwc-dev) as an OIDC provider and registers a
# single confidential client for the ss Moodle site, per F26 § 3-4 and the
# nwc<->ss scope extension requested by P72 § 3.2 (shape 1: nwc is the issuer).
#
# What it does (all reversible; see rollback in docs/reports/f26-review-2026-07-09.md):
#   1. Registers the RS256 signing keys already generated in oauth-keys/
#      into simple_oauth.settings (public_key / private_key).  The keys are
#      NOT copied from prod — they were generated locally for this dev site.
#   2. Ensures OpenID Connect is enabled (disable_openid_connect = false).
#   3. Ensures the OIDC scope entities exist (openid / profile / email).
#   4. Creates/updates a *confidential* consumer (client) for Moodle with:
#         - PKCE required (defense in depth, F26 § 6)
#         - authorization_code grant only (no implicit, no ROPC)
#         - redirect URI(s) = Moodle's /admin/oauth2callback.php
#         - a freshly generated client secret (NEVER committed; written to a
#           gitignored local file and printed once).
#   5. Prints the endpoint summary Moodle needs.
#
# HARD RULE: no shared-secret / bearer-in-URL / anonymous-user shortcuts.
# The hand-off is a standard authorization-code + PKCE OIDC flow. The client
# secret is per-client and generated here, not a shared static token.
#
# Usage:   scripts/f26/provision-nwc-issuer.sh [ddev-project-dir]
# Default ddev project dir: ~/nwp/sites/nwc/dev
set -euo pipefail

SITE_DIR="${1:-$HOME/nwp/sites/nwc/dev}"
KEY_DIR_CONTAINER="/var/www/html/oauth-keys"
CLIENT_ID="ss_moodle"
CLIENT_LABEL="SS Moodle (F26 OIDC client)"
SECRET_OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.f26-moodle-client-secret"

# Redirect URIs the Moodle client is allowed to return to. Dev + a stable
# preview slot. Prod is intentionally absent — prod cut-over is F26 Phase 6,
# 2-approver gated, and must be added by a human, never by CI or this script
# run against a non-dev target.
REDIRECTS=(
  "https://ss-dev.ddev.site/admin/oauth2callback.php"
  "https://ss2-dev.ddev.site/admin/oauth2callback.php"
)

cd "$SITE_DIR"
drush() { ddev drush "$@"; }

echo "== F26 issuer provisioning on: $SITE_DIR =="

# --- 0. sanity: simple_oauth present + keys on disk --------------------------
drush pm:list --status=enabled --field=name 2>/dev/null | grep -qx 'simple_oauth' \
  || { echo "FATAL: simple_oauth not enabled"; exit 1; }
ddev exec "test -r $KEY_DIR_CONTAINER/private.key && test -r $KEY_DIR_CONTAINER/public.key" \
  || { echo "FATAL: signing keys not found at $KEY_DIR_CONTAINER"; exit 1; }

# --- 1. register signing keys ------------------------------------------------
echo "-- registering RS256 signing keys"
drush cset -y simple_oauth.settings public_key  "$KEY_DIR_CONTAINER/public.key"  >/dev/null
drush cset -y simple_oauth.settings private_key "$KEY_DIR_CONTAINER/private.key" >/dev/null

# --- 2. ensure OIDC on -------------------------------------------------------
drush cset -y simple_oauth.settings disable_openid_connect 0 >/dev/null

# --- 3. ensure OIDC scopes exist (openid/profile/email) ----------------------
echo "-- ensuring OIDC scope entities"
drush php:eval '
$storage = \Drupal::entityTypeManager()->getStorage("oauth2_scope");
$want = ["openid"=>"OpenID Connect","profile"=>"Profile","email"=>"Email address"];
foreach ($want as $id => $desc) {
  if (!$storage->load($id)) {
    $storage->create([
      "id" => $id, "name" => $id, "description" => $desc,
      "grant_types" => ["authorization_code" => ["status" => true, "description" => $desc]],
      "umbrella" => false, "granularity_id" => "permission",
      "granularity_configuration" => ["permission" => "access content"],
    ])->save();
    print "  created scope: $id\n";
  } else { print "  scope exists: $id\n"; }
}
'

# --- 4. create/update the confidential Moodle client -------------------------
echo "-- creating/updating client: $CLIENT_ID"
# Generate a strong secret only if we do not already have one recorded.
if [[ -f "$SECRET_OUT" ]]; then
  SECRET="$(cat "$SECRET_OUT")"
  echo "  reusing recorded secret from $SECRET_OUT"
else
  SECRET="$(openssl rand -hex 32)"
  umask 077; printf '%s' "$SECRET" > "$SECRET_OUT"
  echo "  generated new secret -> $SECRET_OUT (gitignored)"
fi

REDIRECT_JSON="$(printf '%s\n' "${REDIRECTS[@]}" | awk 'NF' | sed 's/.*/"&"/' | paste -sd, -)"

drush php:eval '
$cid = "'"$CLIENT_ID"'";
$label = "'"$CLIENT_LABEL"'";
$secret = "'"$SECRET"'";
$redirects = ['"$REDIRECT_JSON"'];
$etm = \Drupal::entityTypeManager()->getStorage("consumer");
$existing = $etm->loadByProperties(["client_id" => $cid]);
$c = $existing ? reset($existing) : $etm->create(["client_id" => $cid]);
$c->set("label", $label);
$c->set("client_id", $cid);
$c->set("secret", $secret);            // hashed on save by simple_oauth
$c->set("confidential", true);
$c->set("pkce", true);                 // require PKCE
$c->set("is_default", false);
$c->set("third_party", true);
$c->set("grant_types", ["authorization_code"]);
$redir = [];
foreach ($redirects as $r) { $redir[] = ["value" => $r]; }
$c->set("redirect", $redir);
// attach OIDC scopes (oauth2_scope_reference field keys on scope_id)
$scopes = [];
foreach (["openid","profile","email"] as $s) { $scopes[] = ["scope_id" => $s]; }
if ($c->hasField("scopes")) { $c->set("scopes", $scopes); }
$c->save();
printf("  client saved: uuid=%s client_id=%s pkce=%s confidential=%s\n",
  $c->uuid(), $c->get("client_id")->value,
  $c->get("pkce")->value ? "yes":"no",
  $c->get("confidential")->value ? "yes":"no");
'

drush cr >/dev/null 2>&1 || true

# --- 5. endpoint summary -----------------------------------------------------
BASE="$(drush php:eval 'print \Drupal::request()->getSchemeAndHttpHost();' 2>/dev/null || echo 'https://nwc-dev.ddev.site')"
cat <<EOF

== DONE. Moodle needs these (register as a custom OAuth2 issuer, see moodle/INSTALL.md) ==
  Issuer base URL     : $BASE
  Authorization       : $BASE/oauth/authorize
  Token               : $BASE/oauth/token
  UserInfo            : $BASE/oauth/userinfo
  JWKS                : $BASE/.well-known/jwks.json
  Client ID           : $CLIENT_ID
  Client secret       : (in $SECRET_OUT — copy into Moodle by hand, do not commit)
  Scopes              : openid profile email
  PKCE                : required (S256)

NOTE: .well-known/openid-configuration (discovery) is NOT served by simple_oauth
6.1.1 core. If you want auto-discovery, add drupal/simple_oauth (server_metadata
submodule) or enable manual endpoint entry in Moodle (INSTALL.md covers both).
EOF
