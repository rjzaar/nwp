#!/bin/bash
################################################################################
# lib/moodle-promote.sh — Moodle promotion SUBSTRATE (ADR-0031 D8 / ops D)
#
# The Moodle-stack analogue of the environment-rewrite steps the Drupal
# promotion commands (dev2stg/prod2stg/live2stg/stg2live) do for Drupal:
# settings rewrite, base-URL rewrite, cache clear, vhost generation, smoke.
#
# Drupal rewrites  html/sites/default/settings.local.php + `drush cr`.
# Moodle has NO drush; the equivalents are:
#   - config.php ($CFG->wwwroot/dataroot/db*/prefix/dboptions)   ← settings writer
#   - $CFG->wwwroot search-replace in the DB + purge_caches      ← wwwroot rewrite
#   - an nginx server block tuned for Moodle's front controller  ← vhost generator
#   - php admin/cli/checks.php + a login-page/OIDC probe          ← smoke
#
# HARD SAFETY CONTRACT (mirrors the Drupal guards):
#   * FAIL-CLOSED, non-canonical only. The settings writer REFUSES any tier that
#     is not dev/stg/test — it NEVER rewrites a live/prod Moodle root. A Moodle
#     `canonical: live` site holds real students' records (ADR-0031 plane 5b);
#     rewriting its config.php from the pipeline is forbidden.
#   * OFF-UNLESS-CONFIGURED. Every entry point is a no-op unless the target site
#     declares `project.type: moodle`. No fleet site is Moodle-canonical today,
#     so this whole library is inert on the current fleet.
#   * NO SECRETS. The DB password is NEVER taken on argv and NEVER hardcoded —
#     it is resolved at write time via `moodle_db_password` (get_data_secret) or,
#     for a ddev dev tier, the well-known non-secret ddev default. config.php is
#     written with umask 077 (mode 0600).
#   * NO NETWORK, NO NGINX INSTALL/RELOAD, NO DB EXECUTION here. The wwwroot
#     DB-side rewrite and cache purge are PLANNED (command strings printed), not
#     run — Moodle's canonical tool is `php admin/cli/...`, executed by an
#     operator against a non-prod site, never by this library.
#
# ⚠ The OAuth/OIDC WIRING (moodle_oauth_*) targets nwc's NATIVE simple_oauth
#   userinfo endpoint (/oauth/userinfo, route simple_oauth.userinfo — F26 M1;
#   there is no custom UserInfoController). It is off-by-default: the writers
#   emit configuration DESCRIPTORS the promotion pipeline applies; enabling a
#   live OIDC client is an operator step (client-secret provisioning).
#
# Requires (soft): lib/ui.sh (print_*), lib/pair.sh (pair_contract_get). yq for
# config reads. Everything degrades to a no-op / refusal when a dep is absent.
################################################################################

# --- soft-dep messaging (works with or without lib/ui.sh) --------------------
if ! command -v print_error >/dev/null 2>&1; then
    _mp_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$_mp_here/ui.sh" ]; then
        # shellcheck source=ui.sh
        source "$_mp_here/ui.sh"
    fi
fi
_mp_err()  { if command -v print_error   >/dev/null 2>&1; then print_error   "$*"; else printf 'ERROR: %s\n' "$*" >&2; fi; }
_mp_warn() { if command -v print_warning >/dev/null 2>&1; then print_warning "$*"; else printf 'WARN: %s\n'  "$*" >&2; fi; }
_mp_info() { if command -v print_info    >/dev/null 2>&1; then print_info    "$*"; else printf '%s\n'        "$*"; fi; }
_mp_ok()   { if command -v print_status  >/dev/null 2>&1; then print_status "OK" "$*"; else printf 'OK: %s\n' "$*"; fi; }

# yq resolver (matches project-resolver.sh's fallback).
_mp_yq() {
    if command -v yq >/dev/null 2>&1; then echo yq;
    elif [ -x "$HOME/.local/bin/yq" ]; then echo "$HOME/.local/bin/yq";
    else return 1; fi
}

# --- tier gate (fail-closed) -------------------------------------------------
# 0 iff <tier> is a non-canonical tier the substrate is allowed to write to.
# dev / stg / test are allowed; live / prod / anything unknown are REFUSED.
_mp_is_noncanonical_tier() {
    case "${1:-}" in
        dev|stg|test) return 0 ;;
        *)            return 1 ;;
    esac
}

# --- config reader (scalar from a site .nwp.yml-shaped file) -----------------
# Usage: _mp_cfg <config_file> <yq_path> [default]
_mp_cfg() {
    local file="$1" path="$2" default="${3:-}"
    local yq_bin; yq_bin="$(_mp_yq)" || { echo "$default"; return 1; }
    [ -f "$file" ] || { echo "$default"; return 1; }
    local v
    v=$("$yq_bin" eval "$path" "$file" 2>/dev/null || echo "null")
    if [ -z "$v" ] || [ "$v" = "null" ]; then echo "$default"; return 1; fi
    printf '%s\n' "$v"
    return 0
}

# 0 iff the site config declares `project.type: moodle`. This is the
# off-unless-configured switch every entry point checks.
# Usage: _moodle_is_moodle_site <config_file>
_moodle_is_moodle_site() {
    local t; t="$(_mp_cfg "$1" '.project.type' '' 2>/dev/null || true)"
    case "$t" in moodle|Moodle|MOODLE) return 0 ;; *) return 1 ;; esac
}

# --- DB password resolver (NEVER argv, NEVER hardcoded) ----------------------
# Default: infra/data-secret lookup. Tests and the ddev-dev path override/bypass
# this. Returns empty when no secret backend is available (caller decides).
# Usage: moodle_db_password <site> <tier>
moodle_db_password() {
    local site="$1" tier="$2"
    if declare -F get_data_secret >/dev/null 2>&1; then
        get_data_secret "moodle.${site}.${tier}.db_password" "" 2>/dev/null || true
    else
        echo ""
    fi
}

################################################################################
# moodle_write_config <moodle_root> <tier> <config_file>
#
# Deterministically (re)write <moodle_root>/config.php for a NON-canonical tier
# from the per-tier values under `.moodle.tiers.<tier>` in <config_file>.
# Idempotent (no timestamps / randomness). Written with mode 0600.
#
# REFUSES (returns non-zero, writes nothing) when:
#   - <tier> is not dev/stg/test (fail-closed — never a live/prod root);
#   - <moodle_root>/version.php is absent (not a Moodle codebase);
#   - the tier has no `wwwroot` configured;
#   - wwwroot points at the site's live_domain (misconfig pointing dev at prod).
################################################################################
moodle_write_config() {
    local moodle_root="$1" tier="$2" config_file="$3"

    if [ -z "$moodle_root" ] || [ -z "$tier" ] || [ -z "$config_file" ]; then
        _mp_err "moodle_write_config: usage: <moodle_root> <tier> <config_file>"
        return 2
    fi

    # 1. Tier gate — fail-closed. NEVER write a live/prod/unknown-tier root.
    if ! _mp_is_noncanonical_tier "$tier"; then
        _mp_err "REFUSED: moodle_write_config target tier '$tier' is not a non-canonical tier."
        _mp_info "Only dev/stg/test may be rewritten. A live/prod Moodle root holds real"
        _mp_info "students' records (ADR-0031 plane 5b) and is never rewritten by the pipeline."
        return 1
    fi

    # 2. Confirm this really is a Moodle codebase (defensive; also blocks a
    #    typo'd path from getting a config.php dropped into it).
    if [ ! -f "$moodle_root/version.php" ]; then
        _mp_err "REFUSED: '$moodle_root' has no version.php — not a Moodle root (fail-closed)."
        return 1
    fi

    # 3. Read tier values from config (NOT hardcoded).
    local wwwroot dataroot dbtype dbhost dbname dbuser prefix dbreadonly ddev_default
    wwwroot="$(_mp_cfg "$config_file" ".moodle.tiers.${tier}.wwwroot" '' || true)"
    if [ -z "$wwwroot" ]; then
        _mp_err "REFUSED: no .moodle.tiers.${tier}.wwwroot in $config_file (fail-closed)."
        return 1
    fi
    dataroot="$(_mp_cfg "$config_file" ".moodle.tiers.${tier}.dataroot" "${moodle_root%/}/moodledata" || true)"
    dbtype="$(_mp_cfg   "$config_file" ".moodle.tiers.${tier}.dbtype"  'mariadb' || true)"
    dbhost="$(_mp_cfg   "$config_file" ".moodle.tiers.${tier}.dbhost"  'db' || true)"
    dbname="$(_mp_cfg   "$config_file" ".moodle.tiers.${tier}.dbname"  'db' || true)"
    dbuser="$(_mp_cfg   "$config_file" ".moodle.tiers.${tier}.dbuser"  'db' || true)"
    prefix="$(_mp_cfg   "$config_file" ".moodle.tiers.${tier}.prefix"  'mdl_' || true)"
    dbreadonly="$(_mp_cfg "$config_file" ".moodle.tiers.${tier}.dboptions_readonly" 'false' || true)"
    ddev_default="$(_mp_cfg "$config_file" ".moodle.tiers.${tier}.dbpass_ddev_default" 'false' || true)"

    # 3a. Guard: a dev/stg wwwroot must not point at the configured live domain.
    local live_domain
    live_domain="$(_mp_cfg "$config_file" '.live.domain' '' || true)"
    [ -z "$live_domain" ] && live_domain="$(_mp_cfg "$config_file" '.live_domain' '' || true)"
    if [ -n "$live_domain" ] && printf '%s' "$wwwroot" | grep -qF "$live_domain"; then
        _mp_err "REFUSED: tier '$tier' wwwroot ($wwwroot) contains the live_domain ($live_domain)."
        _mp_info "That would point a non-canonical tier at the production URL — fail-closed."
        return 1
    fi

    # 4. Resolve the DB password WITHOUT argv/hardcoding. site name from config.
    local site pass
    site="$(_mp_cfg "$config_file" '.project.name' "$(basename "$moodle_root")" || true)"
    pass="$(moodle_db_password "$site" "$tier")"
    if [ -z "$pass" ]; then
        if [ "$ddev_default" = "true" ]; then
            pass="db"   # well-known ddev dev default — not a secret
        else
            _mp_warn "No DB password resolved for $site@$tier (get_data_secret empty)."
            _mp_warn "Writing an EMPTY \$CFG->dbpass. Provision the secret, or set"
            _mp_warn "  .moodle.tiers.${tier}.dbpass_ddev_default: true for a ddev dev tier."
        fi
    fi

    # 5. dboptions block.
    local readonly_line=""
    if [ "$dbreadonly" = "true" ]; then
        readonly_line="  'readonly' => array(),"
    fi

    # 6. Write config.php deterministically, mode 0600 (umask, not chmod-after).
    local tmp; tmp="$(mktemp)" || { _mp_err "mktemp failed"; return 1; }
    (
        umask 077
        cat > "$tmp" <<PHPEOF
<?php  // Moodle configuration file — GENERATED by NWP moodle_write_config (ADR-0031 D8).
// Tier: ${tier} (non-canonical). Do NOT hand-edit; re-generated on each promotion.
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = '${dbtype}';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = '${dbhost}';
\$CFG->dbname    = '${dbname}';
\$CFG->dbuser    = '${dbuser}';
\$CFG->dbpass    = '${pass}';
\$CFG->prefix    = '${prefix}';
\$CFG->dboptions = array(
  'dbpersist' => 0,
  'dbport'    => '',
  'dbsocket'  => '',
  'dbcollation' => 'utf8mb4_unicode_ci',
${readonly_line}
);

\$CFG->wwwroot   = '${wwwroot}';
\$CFG->dataroot  = '${dataroot}';
\$CFG->admin     = 'admin';
\$CFG->directorypermissions = 02777;

require_once(__DIR__ . '/lib/setup.php');
// There is no php closing tag in a Moodle config file. This is intentional.
PHPEOF
    )
    # move into place (preserve the 0600 perms from the umask above)
    if ! cat "$tmp" > "$moodle_root/config.php" 2>/dev/null; then
        _mp_err "Could not write $moodle_root/config.php"
        rm -f "$tmp"; return 1
    fi
    chmod 600 "$moodle_root/config.php" 2>/dev/null || true
    rm -f "$tmp"

    _mp_ok "Wrote $moodle_root/config.php (tier=$tier, wwwroot=$wwwroot, prefix=$prefix, mode 0600)"
    return 0
}

################################################################################
# wwwroot DB-side rewrite — PLAN ONLY (never executes against any site).
#
# Moodle stores its base URL in config.php ($CFG->wwwroot, rewritten above) AND
# references the old URL in DB rows + caches. Moodle has no drush; the canonical
# tools are `php admin/cli/...`. These helpers PRINT the commands an operator
# runs against a NON-prod Moodle; they never touch a DB or the network.
################################################################################

# Echo the cache-purge command to run after a wwwroot change.
# Usage: moodle_purge_caches_cmd <moodle_root>
moodle_purge_caches_cmd() {
    printf 'php %s/admin/cli/purge_caches.php\n' "${1%/}"
}

# Print the DB-side $CFG->wwwroot search-replace PLAN. Does NOT run it.
# Usage: moodle_wwwroot_rewrite_plan <moodle_root> <old_wwwroot> <new_wwwroot>
moodle_wwwroot_rewrite_plan() {
    local root="${1%/}" old="$2" new="$3"
    if [ -z "$root" ] || [ -z "$old" ] || [ -z "$new" ]; then
        _mp_err "moodle_wwwroot_rewrite_plan: usage: <moodle_root> <old_wwwroot> <new_wwwroot>"
        return 2
    fi
    _mp_info "Moodle wwwroot DB-side rewrite PLAN (run against a NON-prod site only):"
    echo "  # 1. Search-replace the old base URL across the DB (tool_replace):"
    echo "  php ${root}/admin/cli/replace.php --search='${old}' --replace='${new}' --non-interactive"
    echo "  # 2. Purge all caches so the new wwwroot takes effect:"
    echo "  $(moodle_purge_caches_cmd "$root")"
    echo "  # NOTE: admin/cli/replace.php is destructive text replacement — never"
    echo "  #       run it against a live/prod Moodle. This substrate only PLANS it."
    return 0
}

################################################################################
# moodle_generate_vhost <domain> <moodle_root> <tier> <out_file> [php_version]
#
# Emit an nginx server block tuned for Moodle's front controller (Moodle serves
# .php directly with PATH_INFO / slasharguments — NOT Drupal's single index.php
# rewrite). Tier-aware: a non-prod tier gets a noindex X-Robots-Tag. Writes to
# <out_file>; NEVER installs or reloads nginx. No secrets.
################################################################################
moodle_generate_vhost() {
    local domain="$1" moodle_root="$2" tier="$3" out_file="$4" php_version="${5:-8.1}"
    if [ -z "$domain" ] || [ -z "$moodle_root" ] || [ -z "$tier" ] || [ -z "$out_file" ]; then
        _mp_err "moodle_generate_vhost: usage: <domain> <moodle_root> <tier> <out_file> [php_version]"
        return 2
    fi

    local noindex=""
    case "$tier" in
        live|prod) : ;;   # production tiers may be indexed
        *)                # non-prod: keep it out of search engines
            noindex=$'    # Non-canonical tier — keep out of search engines.\n    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;'
            ;;
    esac

    local sock="/run/php/php${php_version}-fpm.sock"
    cat > "$out_file" <<NGINXEOF
# GENERATED by NWP moodle_generate_vhost (ADR-0031 D8) — tier: ${tier}
# Install target (operator): /etc/nginx/sites-available/ or GitLab conf.d/.
# This file is NOT installed or reloaded by NWP.
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    root ${moodle_root};
    index index.php index.html;
${noindex}

    # Moodle uses slasharguments (PATH_INFO); route unknown paths to index.php.
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # Protect the config + version files and dot-dirs.
    location ~ ^/(config\.php|install\.php|\.git) {
        deny all;
        return 404;
    }
    location ~ (^|/)\. {
        return 403;
    }

    # Moodle executes .php directly (front controller per script), with PATH_INFO.
    location ~ [^/]\.php(/|\$) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
        if (!-f \$document_root\$fastcgi_script_name) { return 404; }
        fastcgi_index index.php;
        fastcgi_pass unix:${sock};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_read_timeout 300;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?|ttf|eot)\$ {
        expires 90d;
        log_not_found off;
    }
}
NGINXEOF

    _mp_ok "Wrote Moodle nginx vhost for ${domain} → ${out_file} (tier=${tier})"
    return 0
}

################################################################################
# OAuth wiring (F26 — consumer + provider halves). Off-by-default DESCRIPTORS.
#
# Provider = nwc (Drupal, native simple_oauth issuer). Consumer = Moodle
# (auth_nwc). The per-tier issuer URL comes from the PAIR CONTRACT
# (endpoints.<tier>.issuer); the userinfo endpoint is nwc's NATIVE
# /oauth/userinfo (F26 M1). NO secret value is ever written — the writers name
# the secret SOURCE path; the promotion pipeline resolves + injects it at apply
# time into a 0600 file.
################################################################################

# JWKS URI for an issuer — the LIVE-PROVEN path (memory f26-auth-plugin-reconcile
# 2026-07-11): nwc serves its JWKS at /.well-known/jwks.json. The obvious
# /oauth/jwks 301-redirects, which silently breaks token signature verification.
# Single source of truth so the descriptor and the apply-script never diverge.
# Usage: _mp_jwks_uri <issuer_baseurl>
_mp_jwks_uri() { printf '%s/.well-known/jwks.json\n' "${1%/}"; }

# Read the issuer URL for <tier> from a pair contract file.
# Uses lib/pair.sh's pair_contract_get when available, else a direct yq read.
# Usage: _mp_issuer_for_tier <contract_file> <tier>
_mp_issuer_for_tier() {
    local contract="$1" tier="$2"
    if declare -F pair_contract_get >/dev/null 2>&1; then
        pair_contract_get "$contract" ".endpoints.${tier}.issuer" 2>/dev/null || true
        return 0
    fi
    _mp_cfg "$contract" ".endpoints.${tier}.issuer" '' 2>/dev/null || true
}

# moodle_oauth_consumer_config <consumer> <tier> <contract_file> <config_file> <out_file>
#
# Write the tier-aware auth_nwc issuer DESCRIPTOR the promotion pipeline
# applies to the Moodle consumer. Issuer URL from the pair contract; client_id
# + secret-source from <config_file> `.moodle.oauth`. userinfo = native. The
# descriptor is `enabled: false` — an operator flips it on after provisioning
# the client secret. REFUSES a prod tier or an empty issuer (fail-closed).
moodle_oauth_consumer_config() {
    local consumer="$1" tier="$2" contract="$3" config_file="$4" out_file="$5"
    if [ -z "$consumer" ] || [ -z "$tier" ] || [ -z "$contract" ] || [ -z "$out_file" ]; then
        _mp_err "moodle_oauth_consumer_config: usage: <consumer> <tier> <contract> <config_file> <out_file>"
        return 2
    fi
    if [ "$tier" = "prod" ]; then
        _mp_err "REFUSED: OAuth consumer config for a prod tier (auth-adjacent, operator-only)."
        return 1
    fi
    local issuer; issuer="$(_mp_issuer_for_tier "$contract" "$tier")"
    if [ -z "$issuer" ] || [ "$issuer" = "null" ]; then
        _mp_err "REFUSED: no endpoints.${tier}.issuer in $contract (fail-closed) — cannot wire OIDC."
        return 1
    fi
    issuer="${issuer%/}"

    local client_id secret_source enabled
    client_id="$(_mp_cfg "$config_file" '.moodle.oauth.client_id' 'ss_moodle' || true)"
    secret_source="$(_mp_cfg "$config_file" '.moodle.oauth.client_secret_source' "moodle.${consumer}.oauth.client_secret" || true)"
    enabled="$(_mp_cfg "$config_file" '.moodle.oauth.enabled' 'false' || true)"

    cat > "$out_file" <<YAMLEOF
# GENERATED by NWP moodle_oauth_consumer_config (ADR-0031 D8 / F26) — DESCRIPTOR.
# Applied to the Moodle consumer by the promotion pipeline (auth_nwc).
# Contains NO secret: the client secret is resolved at apply time from
# client_secret_source (get_data_secret) into a 0600 file. Off-by-default.
oauth2_issuer:
  name: "nwc (${tier})"
  consumer: ${consumer}
  tier: ${tier}
  enabled: ${enabled}          # operator flips true AFTER provisioning the secret
  # Native simple_oauth issuer (F26 M1 — /oauth/userinfo, route simple_oauth.userinfo).
  baseurl: "${issuer}"
  authorization_endpoint: "${issuer}/oauth/authorize"
  token_endpoint: "${issuer}/oauth/token"
  userinfo_endpoint: "${issuer}/oauth/userinfo"
  # ⚠ LIVE-PROVEN GOTCHA (memory f26-auth-plugin-reconcile 2026-07-11): the JWKS
  # URI is /.well-known/jwks.json — NOT /oauth/jwks, which 301-redirects and
  # breaks token signature verification.
  jwks_uri: "$(_mp_jwks_uri "$issuer")"
  discovery: "${issuer}/.well-known/openid-configuration"   # nwc returns 404 — endpoints set MANUALLY
  scopes: "openid email profile"
  pkce: "S256"                 # F26 §6: ss_moodle client is PKCE-required
  requireconfirmation: 0       # trusted issuer — no email-confirm interstitial
  client_id: "${client_id}"
  client_secret_source: "${secret_source}"   # secret PATH, never the value
  # UID-lock: Moodle mdl_user.idnumber ← Drupal uid (ID token sub) on first SSO.
  # The sub→idnumber user-field mapping is MANDATORY: without it auth_nwc DENIES
  # every login (B1 fail-closed edge).
  uid_lock_field: idnumber
  user_field_mappings:         # applied by the generated apply-script (live-proven)
    sub: idnumber              # the UID-lock — mandatory
    email: email
    name: firstname
    preferred_username: lastname
  # Moodle 4.4 rejects PHP 8.4; run admin/cli with php8.2/8.3 -d max_input_vars=5000.
  cli_php_version: "8.2"
YAMLEOF

    _mp_ok "Wrote Moodle OIDC consumer descriptor (${consumer}@${tier}, issuer=${issuer}) → ${out_file}"
    return 0
}

# moodle_oauth_provider_snippet <consumer> <tier> <contract_file> <config_file> <out_file>
#
# Emit the Drupal simple_oauth CONSUMER (client) registration artifact for the
# provider (nwc) side, as a documented config snippet + operator TODO. NOT
# committed into the nwc profile repo (separate repo) — produced as an artifact
# the operator applies. NO secret value. Redirect URI = the Moodle consumer's
# per-tier wwwroot + Moodle's OAuth2 callback path.
moodle_oauth_provider_snippet() {
    local consumer="$1" tier="$2" contract="$3" config_file="$4" out_file="$5"
    if [ -z "$consumer" ] || [ -z "$tier" ] || [ -z "$out_file" ]; then
        _mp_err "moodle_oauth_provider_snippet: usage: <consumer> <tier> <contract> <config_file> <out_file>"
        return 2
    fi
    if [ "$tier" = "prod" ]; then
        _mp_err "REFUSED: provider OAuth snippet for a prod tier (auth-adjacent, operator-only)."
        return 1
    fi
    local provider client_id consumer_wwwroot redirect
    provider="$(_mp_issuer_for_tier "$contract" "$tier")"; provider="${provider%/}"
    client_id="$(_mp_cfg "$config_file" '.moodle.oauth.client_id' 'ss_moodle' || true)"
    consumer_wwwroot="$(_mp_cfg "$config_file" ".moodle.tiers.${tier}.wwwroot" '' || true)"
    consumer_wwwroot="${consumer_wwwroot%/}"
    if [ -n "$consumer_wwwroot" ]; then
        redirect="${consumer_wwwroot}/admin/oauth2callback.php"
    else
        redirect="<consumer-${tier}-wwwroot>/admin/oauth2callback.php"
    fi

    cat > "$out_file" <<YAMLEOF
# GENERATED by NWP moodle_oauth_provider_snippet (ADR-0031 D8 / F26) — ARTIFACT.
# ⚠ Do NOT commit into the nwc profile repo (separate repo). This is an operator
#   TODO: apply the Consumer entity on the nwc PROVIDER (${provider:-<nwc-${tier}-issuer>})
#   via drush config or the Consumers admin UI. NO secret here — the operator
#   generates the client secret on nwc and provisions it into the consumer's
#   secret store (client_secret_source in the consumer descriptor).
#
# Prefer config/optional or a settings snippet over code where possible.
consumer:
  label: "SS Moodle (${consumer}, ${tier})"
  client_id: "${client_id}"
  # client_secret: <operator provisions on nwc; do NOT write it here>
  is_default: false
  confidential: true               # live-proven: Consumer confidential=TRUE
  pkce: true                       # S256 (F26 §6)
  redirect_uri:
    - "${redirect}"
  grant_types:
    - authorization_code
    - refresh_token
  # Claim allow-list is enforced by NwcOidcClaimsServiceProvider (already exists).
  scopes:
    - openid
    - email
    - profile
# ── Provider-side prerequisites the operator MUST also apply on nwc (steps 5–7,
#    memory f26-auth-plugin-reconcile — MISSING these silently breaks the flow):
#   * simple_oauth signing keypair: drush simple-oauth:generate-keys <dir>, then
#       drush cset simple_oauth.settings public_key  <dir>/public.key
#       drush cset simple_oauth.settings private_key <dir>/private.key
#     (were absent on live → JWKS + token signing failed until generated).
#   * permission: grant 'grant simple_oauth codes' to the authenticated role,
#     else the consent step fails.
#   These are automated by scripts/f26/nwc-provider-oidc-setup.sh (operator-run).
YAMLEOF

    _mp_ok "Wrote Drupal (nwc) provider Consumer snippet (${consumer}@${tier}) → ${out_file}"
    return 0
}

################################################################################
# F26 CONSUMER APPLY — codification of the LIVE-PROVEN ssc↔nwc flow.
#
# On 2026-07-11 the ssc (Moodle) ↔ nwc (Drupal) OIDC round-trip was stood up BY
# HAND on live and PROVEN end-to-end (a nwc user logged into ssc; Moodle
# idnumber == nwc sub — the UID-lock held; the B1 user_loggedin observer fired).
# The functions below turn that manual sequence into repeatable tooling. See
# memory f26-auth-plugin-reconcile.md.
#
# The by-hand consumer steps, now generated/executed:
#   1. deploy auth_nwc plugin → <moodleroot>/auth/nwc + admin/cli/upgrade.php
#   2. create a core oauth2_issuer "nwc (F26)" with MANUAL endpoints
#      (nwc has no discovery doc), jwks = /.well-known/jwks.json (NOT /oauth/jwks)
#   3. create user-field mappings — sub→idnumber (the UID-lock — mandatory) +
#      email→email, name→firstname, preferred_username→lastname
#   4. set_config auth_nwc (issuerid, nwc_url, autoredirect=0) + add oauth2,nwc
#      to $CFG->auth (keeping email)
#
# SAFETY (same contract as the rest of this library):
#   * REFUSES a prod tier (auth-adjacent; operator-only) — mirrors the descriptor
#     writers. dev/stg/test/live are permitted (live is where it was proven; the
#     wiring is ADDITIVE — a new issuer + auth config, it does NOT rewrite the
#     Moodle DB or config.php).
#   * NO SECRET on argv or in any generated file. The generated PHP reads the
#     client secret from the NWC_OIDC_CLIENT_SECRET environment variable; the
#     runner resolves it via get_data_secret and exports it to the child php
#     process only.
#   * php-version-aware: Moodle 4.4 rejects PHP 8.4 → the emitted commands use
#     php8.2 (the FPM version) with -d max_input_vars=5000.
#   * The generator writes an artifact; EXECUTION against a live DB is a separate,
#     explicit runner call (moodle_run_oidc_apply) — never implicit.
################################################################################

# 0 iff <tier> is permitted for the (additive, auth-adjacent) OIDC wiring.
# Everything except prod is allowed (prod stays operator-only, offline-gated).
_mp_oidc_tier_ok() { case "${1:-}" in prod) return 1 ;; ''|*) return 0 ;; esac; }

# Resolve the OIDC client secret WITHOUT argv/hardcoding. Reads the SOURCE path
# from config (.moodle.oauth.client_secret_source) and looks it up via
# get_data_secret. Returns empty when no backend/secret — the caller decides.
# Usage: moodle_oauth_client_secret <consumer> <config_file>
moodle_oauth_client_secret() {
    local consumer="$1" config_file="$2" src
    src="$(_mp_cfg "$config_file" '.moodle.oauth.client_secret_source' "moodle.${consumer}.oauth.client_secret" || true)"
    if declare -F get_data_secret >/dev/null 2>&1; then
        get_data_secret "$src" "" 2>/dev/null || true
    else
        echo ""
    fi
}

# moodle_generate_oidc_apply_script <consumer> <tier> <contract> <config_file> <out_file>
#
# Emit a REAL, idempotent admin/cli-style PHP script that — when run against a
# non-prod Moodle — creates/updates the core oauth2_issuer, its MANUAL endpoints,
# the user-field mappings (sub→idnumber first), and the auth_nwc plugin config,
# exactly as was done by hand on live ssc. Uses core \core\oauth2\api +
# persistent classes. Contains NO secret (reads getenv('NWC_OIDC_CLIENT_SECRET')).
# REFUSES a prod tier or an empty issuer (fail-closed).
moodle_generate_oidc_apply_script() {
    local consumer="$1" tier="$2" contract="$3" config_file="$4" out_file="$5"
    if [ -z "$consumer" ] || [ -z "$tier" ] || [ -z "$contract" ] || [ -z "$out_file" ]; then
        _mp_err "moodle_generate_oidc_apply_script: usage: <consumer> <tier> <contract> <config_file> <out_file>"
        return 2
    fi
    if ! _mp_oidc_tier_ok "$tier"; then
        _mp_err "REFUSED: OIDC apply-script for a prod tier (auth-adjacent, operator-only)."
        return 1
    fi
    local issuer; issuer="$(_mp_issuer_for_tier "$contract" "$tier")"
    if [ -z "$issuer" ] || [ "$issuer" = "null" ]; then
        _mp_err "REFUSED: no endpoints.${tier}.issuer in $contract (fail-closed) — cannot wire OIDC."
        return 1
    fi
    issuer="${issuer%/}"
    local client_id issuer_name jwks
    client_id="$(_mp_cfg "$config_file" '.moodle.oauth.client_id' 'ss_moodle' || true)"
    issuer_name="nwc (F26)"
    jwks="$(_mp_jwks_uri "$issuer")"

    cat > "$out_file" <<PHPEOF
<?php
// GENERATED by NWP moodle_generate_oidc_apply_script (ADR-0031 D8 / F26).
// Codifies the LIVE-PROVEN ssc↔nwc OIDC consumer wiring (memory
// f26-auth-plugin-reconcile, proven end-to-end 2026-07-11). IDEMPOTENT.
//
// Run against a NON-prod Moodle (Moodle 4.4 rejects PHP 8.4 → use php8.2/8.3):
//   MOODLE_CONFIG_PATH=<moodleroot>/config.php \\
//   NWC_OIDC_CLIENT_SECRET=<secret-from-secret-store> \\
//   php8.2 -d max_input_vars=5000 ${out_file##*/}
//
// Contains NO secret — the client secret is read from the environment.
define('CLI_SCRIPT', true);
\$cfgpath = getenv('MOODLE_CONFIG_PATH');
if (!\$cfgpath || !is_file(\$cfgpath)) {
    fwrite(STDERR, "MOODLE_CONFIG_PATH is unset or not a file\n"); exit(2);
}
require(\$cfgpath);
require_once(\$CFG->libdir . '/clilib.php');

\$ISSUER_NAME = '${issuer_name}';
\$BASEURL     = '${issuer}';
\$CLIENTID    = '${client_id}';
\$JWKS        = '${jwks}';   // /.well-known/jwks.json — NOT /oauth/jwks (301s)
\$SECRET      = getenv('NWC_OIDC_CLIENT_SECRET');
if (\$SECRET === false || \$SECRET === '') {
    cli_error('NWC_OIDC_CLIENT_SECRET not set in the environment (never pass it on argv).');
}

// 1. Find-or-create the issuer (idempotent by name). Manual endpoints because
//    nwc exposes no discovery doc (/.well-known/openid-configuration = 404).
\$issuer = null;
foreach (\core\oauth2\api::get_all_issuers() as \$i) {
    if (\$i->get('name') === \$ISSUER_NAME) { \$issuer = \$i; break; }
}
\$fields = (object)[
    'name'                => \$ISSUER_NAME,
    'clientid'            => \$CLIENTID,
    'clientsecret'        => \$SECRET,
    'baseurl'             => \$BASEURL,
    'loginscopes'         => 'openid email profile',
    'loginscopesoffline'  => 'openid email profile',
    'showonloginpage'     => 1,
    'enabled'             => 1,
    'requireconfirmation' => 0,   // trusted issuer — no email-confirm interstitial
];
if (\$issuer === null) {
    \$issuer = new \core\oauth2\issuer(0, \$fields);
    \$issuer->create();
    cli_writeln('Created issuer "' . \$ISSUER_NAME . '" #' . \$issuer->get('id'));
} else {
    foreach ((array)\$fields as \$k => \$v) {
        if (\$k === 'clientsecret' && (\$v === '' || \$v === null)) { continue; }
        \$issuer->set(\$k, \$v);
    }
    \$issuer->update();
    cli_writeln('Updated issuer "' . \$ISSUER_NAME . '" #' . \$issuer->get('id'));
}
\$issuerid = \$issuer->get('id');

// 2. Manual endpoints — upsert by name.
\$endpoints = [
    'authorization_endpoint' => \$BASEURL . '/oauth/authorize',
    'token_endpoint'         => \$BASEURL . '/oauth/token',
    'userinfo_endpoint'      => \$BASEURL . '/oauth/userinfo',
    'jwks_uri'               => \$JWKS,
];
\$byname = [];
foreach (\core\oauth2\api::get_endpoints(\$issuer) as \$e) { \$byname[\$e->get('name')] = \$e; }
foreach (\$endpoints as \$name => \$url) {
    if (isset(\$byname[\$name])) {
        \$byname[\$name]->set('url', \$url); \$byname[\$name]->update();
    } else {
        (new \core\oauth2\endpoint(0, (object)[
            'issuerid' => \$issuerid, 'name' => \$name, 'url' => \$url,
        ]))->create();
    }
}

// 3. User-field mappings. sub→idnumber is the UID-lock and is MANDATORY:
//    without it auth_nwc DENIES every login (B1 fail-closed edge).
\$maps = [
    'sub'                => 'idnumber',
    'email'              => 'email',
    'name'               => 'firstname',
    'preferred_username' => 'lastname',
];
\$mapped = [];
foreach (\core\oauth2\api::get_user_field_mappings(\$issuer) as \$m) {
    \$mapped[\$m->get('externalfield')] = \$m;
}
foreach (\$maps as \$ext => \$int) {
    if (isset(\$mapped[\$ext])) {
        \$mapped[\$ext]->set('internalfield', \$int); \$mapped[\$ext]->update();
    } else {
        (new \core\oauth2\user_field_mapping(0, (object)[
            'issuerid' => \$issuerid, 'externalfield' => \$ext, 'internalfield' => \$int,
        ]))->create();
    }
}
// Fail-closed assertion: the UID-lock MUST be present before we finish.
\$haslock = false;
foreach (\core\oauth2\api::get_user_field_mappings(\$issuer) as \$m) {
    if (\$m->get('externalfield') === 'sub' && \$m->get('internalfield') === 'idnumber') { \$haslock = true; }
}
if (!\$haslock) {
    cli_error('FATAL: sub->idnumber mapping absent — auth_nwc would DENY all logins. Aborting.');
}

// 4. auth_nwc plugin config + enable oauth2,nwc in \$CFG->auth (keep email).
set_config('issuerid', \$issuerid, 'auth_nwc');
set_config('nwc_url', \$BASEURL, 'auth_nwc');
set_config('autoredirect', 0, 'auth_nwc');   // keep the login page recoverable
\$auths = array_filter(array_map('trim', explode(',', (string)\$CFG->auth)));
foreach (['email', 'oauth2', 'nwc'] as \$a) {
    if (!in_array(\$a, \$auths, true)) { \$auths[] = \$a; }
}
set_config('auth', implode(',', \$auths));
if (class_exists('\\core\\plugininfo\\auth')) {
    \core\plugininfo\auth::enable_plugin('oauth2', 1);
    \core\plugininfo\auth::enable_plugin('nwc', 1);
}

cli_writeln('OK: issuer #' . \$issuerid . ' wired — sub->idnumber locked, requireconfirmation=0, auth=' . \$CFG->auth);
PHPEOF

    _mp_ok "Wrote F26 OIDC apply-script (${consumer}@${tier}, issuer=${issuer}) → ${out_file}"
    return 0
}

# moodle_deploy_auth_nwc <moodle_root> <tier> <plugin_src> [php_version]
#
# Deploy the auth_nwc plugin into <moodle_root>/auth/nwc (step 1) and PRINT the
# php-version-aware upgrade command (Moodle 4.4 rejects PHP 8.4 → php8.2/8.3 with
# -d max_input_vars=5000). Copies files (additive); does NOT run the upgrade
# (that is a DB write — operator runs the printed command). REFUSES a prod tier,
# a non-Moodle root, or a missing/invalid plugin source.
moodle_deploy_auth_nwc() {
    local moodle_root="$1" tier="$2" plugin_src="$3" php_version="${4:-8.2}"
    if [ -z "$moodle_root" ] || [ -z "$tier" ] || [ -z "$plugin_src" ]; then
        _mp_err "moodle_deploy_auth_nwc: usage: <moodle_root> <tier> <plugin_src> [php_version]"
        return 2
    fi
    if ! _mp_oidc_tier_ok "$tier"; then
        _mp_err "REFUSED: auth_nwc deploy to a prod tier (auth-adjacent, operator-only)."
        return 1
    fi
    if [ ! -f "$moodle_root/version.php" ]; then
        _mp_err "REFUSED: '$moodle_root' has no version.php — not a Moodle root (fail-closed)."
        return 1
    fi
    if [ ! -f "$plugin_src/version.php" ]; then
        _mp_err "REFUSED: plugin source '$plugin_src' has no version.php — not an auth_nwc plugin."
        return 1
    fi
    local dest="${moodle_root%/}/auth/nwc"
    mkdir -p "$dest" || { _mp_err "Cannot create $dest"; return 1; }
    # Copy the plugin tree (additive). Prefer rsync; fall back to cp.
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "${plugin_src%/}/" "$dest/" || { _mp_err "rsync of auth_nwc failed"; return 1; }
    else
        rm -rf "$dest" && mkdir -p "$dest" && cp -a "${plugin_src%/}/." "$dest/" \
            || { _mp_err "cp of auth_nwc failed"; return 1; }
    fi
    _mp_ok "Deployed auth_nwc → ${dest}"
    _mp_info "Then run the Moodle upgrade (operator; Moodle 4.4 needs php8.2/8.3, NOT 8.4):"
    echo "  php${php_version} -d max_input_vars=5000 ${moodle_root%/}/admin/cli/upgrade.php --non-interactive"
    return 0
}

# moodle_run_oidc_apply <moodle_root> <tier> <script> <consumer> <config_file> [php_version]
#
# EXECUTE the generated apply-script against a Moodle DB (the "actually create"
# step). Resolves the client secret via get_data_secret and exports it to the
# child php process only (NEVER argv, NEVER a file). php-version-aware. REFUSES
# prod; requires the moodle root, the script, and a php binary. This is the one
# place that writes to the Moodle DB, and only when called explicitly (the
# command's default path generates the script and prints this command instead).
moodle_run_oidc_apply() {
    local moodle_root="$1" tier="$2" script="$3" consumer="$4" config_file="$5" php_version="${6:-8.2}"
    if [ -z "$moodle_root" ] || [ -z "$tier" ] || [ -z "$script" ] || [ -z "$consumer" ]; then
        _mp_err "moodle_run_oidc_apply: usage: <moodle_root> <tier> <script> <consumer> <config_file> [php_version]"
        return 2
    fi
    if ! _mp_oidc_tier_ok "$tier"; then
        _mp_err "REFUSED: OIDC apply execution against a prod tier (auth-adjacent, operator-only)."
        return 1
    fi
    if [ ! -f "$moodle_root/config.php" ]; then
        _mp_err "REFUSED: no $moodle_root/config.php — Moodle not bootstrappable."
        return 1
    fi
    if [ ! -f "$script" ]; then
        _mp_err "REFUSED: apply-script '$script' not found."
        return 1
    fi
    local php_bin="php${php_version}"
    command -v "$php_bin" >/dev/null 2>&1 || php_bin="php"
    command -v "$php_bin" >/dev/null 2>&1 || { _mp_err "No php binary (need php${php_version})."; return 1; }

    local secret; secret="$(moodle_oauth_client_secret "$consumer" "$config_file")"
    if [ -z "$secret" ]; then
        _mp_err "REFUSED: no OIDC client secret resolved (get_data_secret empty). Provision it first."
        return 1
    fi
    _mp_info "Executing OIDC apply-script (${consumer}@${tier}) via ${php_bin} …"
    # Secret goes to the child process env ONLY — never argv, never logged.
    MOODLE_CONFIG_PATH="${moodle_root%/}/config.php" \
    NWC_OIDC_CLIENT_SECRET="$secret" \
        "$php_bin" -d max_input_vars=5000 "$script"
    local rc=$?
    if [ "$rc" -eq 0 ]; then _mp_ok "OIDC apply-script completed (${consumer}@${tier})."
    else _mp_err "OIDC apply-script exited $rc."; fi
    return "$rc"
}

################################################################################
# moodle_promote_plan <site> <tier> <config_file> <moodle_root> [contract_file] [out_dir]
#
# The orchestration "what-would-happen" summary — PURE (writes nothing). It is
# the off-unless-configured switch: if <site> is not a Moodle-stack site it
# prints a single no-op line and returns 0. Otherwise it prints the ordered plan
# (settings → vhost → oauth → wwwroot-rewrite → smoke) without performing it.
# The command (scripts/commands/moodle-promote.sh) calls the individual writers
# for --apply; this function stays side-effect-free so it is unit-testable.
################################################################################
moodle_promote_plan() {
    local site="$1" tier="$2" config_file="$3" moodle_root="$4"
    local contract_file="${5:-}" out_dir="${6:-}"

    if ! _moodle_is_moodle_site "$config_file"; then
        _mp_info "no-op: '$site' is not a Moodle site (project.type != moodle) — nothing to promote."
        return 0
    fi
    if ! _mp_is_noncanonical_tier "$tier"; then
        _mp_err "REFUSED: tier '$tier' is not dev/stg/test — the substrate never targets a live/prod Moodle."
        return 1
    fi

    _mp_info "Moodle promotion PLAN for ${site}@${tier} (dry-run — nothing written):"
    echo "  1. settings: write ${moodle_root}/config.php from .moodle.tiers.${tier} (mode 0600)"
    echo "  2. vhost:    generate nginx server block (tier-aware; NOT installed)"
    if [ -n "$contract_file" ]; then
        local issuer; issuer="$(_mp_issuer_for_tier "$contract_file" "$tier")"
        echo "  3. oauth:    consumer descriptor + provider snippet (issuer=${issuer:-<none>}; off-by-default)"
    else
        echo "  3. oauth:    (no pair contract given — OIDC wiring skipped)"
    fi
    echo "  4. wwwroot:  DB-side search-replace + purge_caches PLAN (printed, NOT run)"
    echo "  5. smoke:    pl moodle-smoke ${site} --tier=${tier} --dry-run"
    [ -n "$out_dir" ] && echo "  (artifacts would be written under: ${out_dir})"
    return 0
}
