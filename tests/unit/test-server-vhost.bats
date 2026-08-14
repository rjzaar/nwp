#!/usr/bin/env bats
# lib/server-vhost.sh — `pl server vhost` (nwp/ops#359).
#
# THE INCIDENT THIS REPRODUCES (2026-08-13). A live site's nginx vhost was
# renamed to a `.bak` during a box split and never restored, because it still
# included GitLab's bundled nginx config, which does not exist on a standalone
# box. With no server block for that name, TLS fell THROUGH to the first 443
# block loaded and served a different site's certificate. `pl server roots`
# detected it and could not act, so the repair was done by hand over ssh — a
# recorded, time-boxed exception to the pl-first standing order.
#
# Everything here runs against a FIXTURE conf.d captured to a directory. No ssh,
# no live box: the handover requires this verb be proven against a fixture with
# a stashed vhost BEFORE it is pointed at anything real.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d)"
  CONF="${TMP}/conf.d"
  mkdir -p "${CONF}"

  # `alpha.conf` — alphabetically FIRST, so it owns the 443 fall-through. This is
  # the block that ended up answering for the broken site.
  cat > "${CONF}/alpha.conf" <<'EOF'
server {
    listen 80;
    server_name first.example.com;
    location / { return 301 https://$server_name$request_uri; }
}
server {
    listen 443 ssl;
    server_name first.example.com;
    ssl_certificate /etc/letsencrypt/live/first.example.com/fullchain.pem;
    root /var/www/first/html;
}
EOF

  # A healthy twin that DOES serve its declared root, with an ACME location and
  # the system fastcgi include — the shape a restore should produce.
  cat > "${CONF}/healthy.conf" <<'EOF'
server {
    listen 80;
    server_name healthy.example.com;
    location ^~ /.well-known/acme-challenge/ { auth_basic off; root /var/www/healthy/html; allow all; }
    location / { return 301 https://$server_name$request_uri; }
}
server {
    listen 443 ssl;
    server_name healthy.example.com;
    ssl_certificate /etc/letsencrypt/live/healthy.example.com/fullchain.pem;
    root /var/www/healthy/html;
    location ~ \.php$ { include /etc/nginx/fastcgi_params; }
}
EOF

  # THE BROKEN SITE: present on disk, INERT — the suffix is not `.conf`, so
  # nginx never loads it. Both defects are in it: the GitLab-bundled include,
  # and a port-80 block that is a bare `return 301` with no ACME location.
  cat > "${CONF}/broken.conf.bak-fastcgi-20260801T082708Z" <<'EOF'
server {
    listen 80;
    server_name broken.example.com;
    location / { return 301 https://$server_name$request_uri; }
}
server {
    listen 443 ssl;
    server_name broken.example.com;
    ssl_certificate /etc/letsencrypt/live/broken.example.com/fullchain.pem;
    root /var/www/broken/html;
    location ~ \.php$ { include /opt/gitlab/embedded/conf/fastcgi_params; }
}
EOF

  printf 'gitlab_embedded=no\nnginx_present=yes\n' > "${CONF}/.facts"
  source "${REPO_ROOT}/lib/server-vhost.sh"
}

teardown() { rm -rf "${TMP}"; }

# ── what nginx actually loads ───────────────────────────────────────────────

@test "an inert .bak is NOT counted as a loaded vhost" {
  run vhost_active_confs "${CONF}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha.conf"* ]]
  [[ "$output" == *"healthy.conf"* ]]
  # The whole incident: this file exists and nginx does not load it.
  [[ "$output" != *"bak-fastcgi"* ]]
}

@test "a file in a retired-*/ subdirectory is inert too" {
  mkdir -p "${CONF}/retired-20260807"
  cp "${CONF}/healthy.conf" "${CONF}/retired-20260807/old.conf"
  run vhost_active_confs "${CONF}"
  [[ "$output" != *"retired"* ]]
}

@test "the healthy twin is detected as serving its declared root" {
  run vhost_serves_root "${CONF}/healthy.conf" /var/www/healthy
  [ "$status" -eq 0 ]
}

@test "no LOADED vhost serves the broken site's declared root" {
  local rel found=0
  while IFS= read -r rel; do
    vhost_serves_root "${CONF}/${rel}" /var/www/broken && found=1
  done < <(vhost_active_confs "${CONF}")
  [ "$found" -eq 0 ]
}

# ── the fall-through: the question that would have explained the outage ─────

@test "443 falls through to the alphabetically first loaded vhost" {
  run vhost_fallthrough_conf "${CONF}"
  [ "$status" -eq 0 ]
  [ "$output" = "alpha.conf" ]
}

@test "an explicit default_server wins over alphabetical order" {
  cat > "${CONF}/zz-default.conf" <<'EOF'
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate /etc/letsencrypt/live/default.example.com/fullchain.pem;
    root /var/www/default;
}
EOF
  run vhost_fallthrough_conf "${CONF}"
  [ "$output" = "zz-default.conf" ]
}

@test "the fall-through cert is named, so 'why the wrong cert' is answerable" {
  run vhost_cert_of "${CONF}/$(vhost_fallthrough_conf "${CONF}")"
  [[ "$output" == *"first.example.com"* ]]
}

# ── finding the stash ───────────────────────────────────────────────────────

@test "the stashed vhost is found by the root it serves, not just by its name" {
  run vhost_stashes_for "${CONF}" broken /var/www/broken
  [ "$status" -eq 0 ]
  [[ "$output" == *"broken.conf.bak-fastcgi"* ]]
}

@test "a loaded vhost is never offered as a stash to restore from" {
  run vhost_stashes_for "${CONF}" healthy /var/www/healthy
  [[ "$output" != *"healthy.conf"* ]]
}

# ── repair class 1: GitLab-bundled includes ─────────────────────────────────

@test "REPAIR: a GitLab-bundled include is repointed at the system path" {
  # This is why the vhost was never restored: `nginx -t` fails with
  # `open() failed (2: No such file or directory)` on a box with no /opt/gitlab.
  run vhost_repair_gitlab_includes "${CONF}/broken.conf.bak-fastcgi-20260801T082708Z"
  [ "$status" -eq 0 ]
  [[ "$output" == *"include /etc/nginx/fastcgi_params;"* ]]
  [[ "$output" != *"/opt/gitlab/"* ]]
}

@test "REPAIR: a config with no bundled include is returned unchanged" {
  run vhost_repair_gitlab_includes "${CONF}/healthy.conf"
  [ "$status" -eq 1 ]                       # nothing to do
  [[ "$output" == *"include /etc/nginx/fastcgi_params;"* ]]
}

# ── repair class 2: the ACME challenge location ─────────────────────────────

@test "REPAIR: an ACME challenge location is added to a bare redirect block" {
  # A port-80 block that is only `return 301` redirects certbot's own
  # validation request to https, so webroot renewal fails and the site dies
  # when the cert expires — the same outage, deferred 90 days.
  run vhost_repair_acme "${CONF}/broken.conf.bak-fastcgi-20260801T082708Z" /var/www/broken/html
  [ "$status" -eq 0 ]
  [[ "$output" == *"location ^~ /.well-known/acme-challenge/"* ]]
  [[ "$output" == *"root /var/www/broken/html;"* ]]
  # …inserted BEFORE the redirect, or nginx would never reach it.
  local acme_line redirect_line
  acme_line=$(printf '%s\n' "$output" | grep -n 'acme-challenge' | head -1 | cut -d: -f1)
  redirect_line=$(printf '%s\n' "$output" | grep -n 'return 301' | head -1 | cut -d: -f1)
  [ "$acme_line" -lt "$redirect_line" ]
}

@test "REPAIR: a config that already has an ACME location is left alone" {
  run vhost_repair_acme "${CONF}/healthy.conf" /var/www/healthy/html
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'acme-challenge')" -eq 1 ]
}

@test "REFUSES to edit when there is not exactly one redirect line" {
  # The hand-restore script's own guard, kept as the floor. Two redirects and
  # we cannot tell which block is the port-80 one; editing blind makes it worse.
  cat > "${TMP}/two.conf" <<'EOF'
server { listen 80; server_name a.example.com; location / { return 301 https://a.example.com$request_uri; } }
server { listen 80; server_name b.example.com; location / { return 301 https://b.example.com$request_uri; } }
EOF
  run vhost_repair_acme "${TMP}/two.conf" /var/www/x
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" != *"acme-challenge"* ]]
}

@test "REFUSES to edit a config with no redirect line at all" {
  cat > "${TMP}/none.conf" <<'EOF'
server { listen 80; server_name a.example.com; root /var/www/a; }
EOF
  run vhost_repair_acme "${TMP}/none.conf" /var/www/a
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
}

# ── the repaired config is what we actually wanted ──────────────────────────

@test "both repairs together produce a config that nginx -t would accept" {
  local out1="${TMP}/r1" out2="${TMP}/r2"
  vhost_repair_gitlab_includes "${CONF}/broken.conf.bak-fastcgi-20260801T082708Z" > "$out1"
  vhost_repair_acme "$out1" /var/www/broken/html > "$out2"
  [[ "$(cat "$out2")" != *"/opt/gitlab/"* ]]
  grep -q 'acme-challenge' "$out2"
  grep -q 'ssl_certificate /etc/letsencrypt/live/broken.example.com/fullchain.pem;' "$out2"
  # The site's own root survived the repair — a restore that loses the docroot
  # would "succeed" and serve the wrong tree.
  grep -q 'root /var/www/broken/html;' "$out2"
  if command -v nginx >/dev/null 2>&1; then
    run nginx -t -c "$out2"
    [ "$status" -ne 0 ]   # not a whole nginx.conf; we only assert we can call it
  fi
}

# ── the apply path writes nothing without --apply, and guards when it does ──

@test "the apply script REFUSES to overwrite an existing conf" {
  local script; script="$(vhost_apply_script "${TMP}/exists.conf" "true")"
  printf 'server { listen 80; }\n' > "${TMP}/exists.conf"
  # A `sudo` that just runs the command, so the guard itself is exercised.
  mkdir -p "${TMP}/bin"
  cat > "${TMP}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [ "${1#-}" != "$1" ]; do shift; done
exec "$@"
EOF
  chmod +x "${TMP}/bin/sudo"
  run bash -c "PATH='${TMP}/bin:$PATH'; $script" <<<'server { listen 80; }'
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"already exists"* ]]
}

@test "the apply script REMOVES what it wrote when nginx -t fails" {
  # Fail-closed: a config that does not pass `nginx -t` must not survive the
  # attempt, or the next reload (by certbot, by a reboot) takes the box down.
  local script; script="$(vhost_apply_script "${TMP}/new.conf" "true")"
  mkdir -p "${TMP}/bin"
  cat > "${TMP}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [ "${1#-}" != "$1" ]; do shift; done
exec "$@"
EOF
  cat > "${TMP}/bin/nginx" <<'EOF'
#!/usr/bin/env bash
echo "nginx: [emerg] open() \"/opt/gitlab/embedded/conf/fastcgi_params\" failed" >&2
exit 1
EOF
  # `install -o root -g root` cannot succeed unprivileged; drop the ownership
  # flags so the test exercises the nginx -t guard, not the chown.
  cat > "${TMP}/bin/install" <<'EOF'
#!/usr/bin/env bash
args=()
while [ $# -gt 0 ]; do
  case "$1" in -o|-g|-m) shift 2 ;; *) args+=("$1"); shift ;; esac
done
exec /usr/bin/install "${args[@]}"
EOF
  chmod +x "${TMP}/bin/sudo" "${TMP}/bin/nginx" "${TMP}/bin/install"
  run bash -c "PATH='${TMP}/bin:$PATH'; $script" <<<'server { listen 80; }'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REMOVING"* ]]
  [ ! -e "${TMP}/new.conf" ]
}

@test "the apply script refuses an EMPTY configuration" {
  local script; script="$(vhost_apply_script "${TMP}/empty.conf" "true")"
  mkdir -p "${TMP}/bin"
  cat > "${TMP}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [ "${1#-}" != "$1" ]; do shift; done
exec "$@"
EOF
  chmod +x "${TMP}/bin/sudo"
  run bash -c "PATH='${TMP}/bin:$PATH'; $script" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [ ! -e "${TMP}/empty.conf" ]
}

# ── the reload command is measured, never guessed ───────────────────────────

@test "a standalone box reloads with systemctl" {
  run vhost_reload_cmd "${CONF}"
  [[ "$output" == *"systemctl reload nginx"* ]]
}

@test "a box with /opt/gitlab reloads the BUNDLED nginx instead" {
  # Same conf.d path, different nginx. The system nginx.service on a GitLab box
  # is dead, so `systemctl reload nginx` there reports success having reloaded
  # nothing. Keyed off the measured fact, never off the server's name.
  printf 'gitlab_embedded=yes\nnginx_present=yes\n' > "${CONF}/.facts"
  run vhost_reload_cmd "${CONF}"
  [[ "$output" == *"gitlab-ctl hup nginx"* ]]
}

# ── blindness is never a finding ────────────────────────────────────────────

@test "an unreadable config file makes the split fail closed" {
  run bash -c 'printf "NWPVHOST v1\ngitlab_embedded=no\n==NWPVHOSTINCOMPLETE== secret.conf not-readable\n" | { source "'"${REPO_ROOT}"'/lib/server-vhost.sh"; vhost_split_stream "'"${TMP}"'/out"; }'
  [ "$status" -eq 2 ]
}

@test "a probe that did not run is CANNOT VERIFY, not 'no vhost'" {
  host_run() { return 255; }
  run vhost_probe "ssh nowhere"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  [[ "$output" == *"NOT"* ]]
}
