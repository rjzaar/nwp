#!/usr/bin/env bash
#
# lib/server-vhost.sh — the engine behind `pl server vhost`.
#
# WHY THIS EXISTS (nwp/ops#359, incident 2026-08-13)
# -------------------------------------------------
# A live site lost its nginx server block during a box split: the vhost was
# renamed to a `.bak` and never restored, because it still referenced GitLab's
# bundled nginx (`include /opt/gitlab/embedded/conf/fastcgi_params`) which does
# not exist on a standalone box, so it would not have loaded anyway.
#
# With no server block for that name, TLS did not fail — it fell THROUGH to the
# first 443 block on the box and served a different site's certificate. The site
# was down for twelve days behind a fleet dashboard that showed it green.
#
# `pl server roots` DETECTED it (`UNREACHABLE-DECLARATION … no vhost serves
# it`) and could not act on it. There was no verb to inspect a vhost, and none
# to restore one. So the repair was done by hand over ssh — a deliberate,
# recorded, time-boxed exception to the pl-first standing order, taken under an
# operator token constraint. This file is the repayment: the exception exists
# because the verb did not.
#
# DESIGN RULES
# ------------
#  1. THE REMOTE PROBE IS FIXED AND READ-ONLY. It takes no argument. Nothing
#     from argv reaches the remote shell. Only vhost_apply_script writes, and
#     only behind --apply.
#  2. THE ANALYSIS IS LOCAL AND PURE. The probe ships bytes; every verdict is
#     computed here, against a directory of files. That is what lets the whole
#     verb be driven red-then-green from a FIXTURE with a stashed vhost, with
#     no ssh and no live box — which is what the handover demanded before any
#     live use.
#  3. FAIL CLOSED. A probe that cannot read the config directory is
#     CANNOT VERIFY, never "no vhost". Blindness is not a finding.
#  4. THE RELOAD COMMAND IS KEYED OFF MEASURED REALITY, never off a host's
#     name. A box with /opt/gitlab runs GitLab's BUNDLED nginx and reloads with
#     `gitlab-ctl hup nginx`; the system `nginx.service` there is dead. Same
#     conf.d path, different reload. Guessing from the server name is how you
#     write a "successful" reload that reloaded nothing.

[ -n "${_NWP_SERVER_VHOST_SOURCED:-}" ] && return 0
_NWP_SERVER_VHOST_SOURCED=1

# nginx loads /etc/nginx/conf.d/*.conf — top level only, and only that suffix.
# Anything else in there (a .bak, a retired-*/ subdirectory) is INERT. That
# distinction is the whole subject of this file: the broken site's config was
# present on disk the entire time, one rename away from being loaded.
VHOST_CONF_DIR="${NWP_VHOST_CONF_DIR:-/etc/nginx/conf.d}"

################################################################################
# SECTION 1 — the remote probe (fixed, read-only, cheap)
################################################################################

# vhost_probe_script
# Emits every file under conf.d (including the inert ones, which are the point)
# plus the two facts that decide how a repair would be applied.
vhost_probe_script() {
    cat <<'PROBE'
set -u
printf 'NWPVHOST v1\n'
# Which nginx is this? Measured, never inferred from the host's name.
if [ -d /opt/gitlab ]; then printf 'gitlab_embedded=yes\n'; else printf 'gitlab_embedded=no\n'; fi
if [ -x /usr/sbin/nginx ] || command -v nginx >/dev/null 2>&1; then printf 'nginx_present=yes\n'; else printf 'nginx_present=no\n'; fi
d=/etc/nginx/conf.d
if [ ! -d "$d" ]; then
  printf '==NWPVHOSTINCOMPLETE== conf.d no-such-directory\n'
  exit 0
fi
# Top-level files AND one level of subdirectory (retired-*/ mothballed-*/ hold
# the stashed vhosts a restore reads from). Depth is bounded deliberately.
for f in "$d"/* "$d"/*/*; do
  [ -f "$f" ] || continue
  rel="${f#"$d"/}"
  if [ -r "$f" ]; then
    printf '==NWPVHOSTFILE== %s\n' "$rel"
    cat "$f"
  elif sudo -n test -r "$f" 2>/dev/null; then
    printf '==NWPVHOSTFILE== %s\n' "$rel"
    sudo -n cat "$f"
  else
    printf '==NWPVHOSTINCOMPLETE== %s not-readable\n' "$rel"
  fi
done
PROBE
}

# vhost_probe <ssh-prefix>
# Emits the raw stream. 3 = unreachable/unusable — NEVER "no vhosts".
vhost_probe() {
    local prefix="$1" out rc
    out="$(host_run "$prefix" "$(vhost_probe_script)" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ] || [[ "$out" != *"NWPVHOST v1"* ]]; then
        printf 'CANNOT VERIFY: the vhost probe did not run (rc=%s) — this is NOT "no vhost serves it"\n' "$rc" >&2
        return 3
    fi
    printf '%s\n' "$out"
    return 0
}

# vhost_split_stream <destdir>   (stdin)
# Splits the probe stream into files under <destdir>. Returns 2 if the host
# declared it could not read part of its own config.
vhost_split_stream() {
    local dest="$1"
    mkdir -p "$dest"
    awk -v dest="$dest" '
      BEGIN { cur = ""; incomplete = 0 }
      /^NWPVHOST v1$/ { next }
      /^gitlab_embedded=/ { print > (dest "/.facts"); next }
      /^nginx_present=/   { print >> (dest "/.facts"); next }
      /^==NWPVHOSTINCOMPLETE== / { incomplete = 1; print "INCOMPLETE " $2 " " $3 > "/dev/stderr"; next }
      /^==NWPVHOSTFILE== / {
        cur = dest "/" $2
        n = split($2, parts, "/")
        if (n > 1) { d = dest; for (i = 1; i < n; i++) { d = d "/" parts[i]; system("mkdir -p \"" d "\"") } }
        printf "" > cur
        next
      }
      { if (cur != "") print >> cur }
      END { exit (incomplete ? 2 : 0) }
    '
}

# vhost_fact <dir> <key>
# `cmd | head -1` is a SIGPIPE race under `set -o pipefail` (ops#351): head
# exits first and the writer's 141 becomes the pipeline's verdict, so the
# branch is decided by timing. Read the first line from a process substitution
# instead — `|| true` would discard the real verdict as well.
vhost_fact() {
    local dir="$1" key="$2" line=""
    [ -f "$dir/.facts" ] || return 0
    read -r line < <(sed -n "s/^${key}=//p" "$dir/.facts") || true
    printf '%s\n' "$line"
}

# vhost_reload_cmd <dir>
# RULE 4. Measured, not guessed.
vhost_reload_cmd() {
    local dir="$1"
    if [ "$(vhost_fact "$dir" gitlab_embedded)" = "yes" ]; then
        printf 'sudo gitlab-ctl hup nginx\n'
    else
        printf 'sudo systemctl reload nginx\n'
    fi
}

# vhost_test_cmd <dir>
# RULE 4, APPLIED TO THE TEST AS WELL AS THE RELOAD.
#
# This was the half that was missed. `vhost_apply_script` hardcoded `nginx -t`,
# and the tempting reading is "there is only one nginx, so that is fine". On the
# forge there are TWO, and both are installed:
#
#   /usr/sbin/nginx                     Debian build — nginx.service is
#                                       `inactive` and `disabled`
#   /opt/gitlab/embedded/sbin/nginx     Omnibus build — the RUNNING master,
#                                       `-p /var/opt/gitlab/nginx`
#
# Both read `include /etc/nginx/conf.d/*.conf;`, so the hardcoded test does at
# least parse the new file — this is not a blind green. It is a green from the
# WRONG PROGRAM, which is worse than it sounds, because the two builds
# demonstrably disagree over that very directory: measured 2026-08-22, the
# Omnibus binary emits `the "listen ... http2" directive is deprecated` for
# another static vhost in that directory and the Debian binary reports the same tree clean.
#
# Both failure directions are live:
#   * a config the RUNNING nginx would reject passes the dead one's test, so the
#     verb reports "nginx -t passed, nginx reloaded" while the Omnibus master
#     refused the reload and kept serving the old config — a false green on the
#     box that also serves GitLab;
#   * the Debian nginx.conf additionally pulls in /etc/nginx/sites-enabled/*,
#     which the Omnibus one does not, so unrelated breakage there fails the test
#     and rolls back a perfectly good vhost.
#
# Same fact, same measurement, same rule as the reload: ask the box which nginx
# it is running, never the server's name.
vhost_test_cmd() {
    local dir="$1"
    if [ "$(vhost_fact "$dir" gitlab_embedded)" = "yes" ]; then
        printf 'sudo -n /opt/gitlab/embedded/sbin/nginx -p /var/opt/gitlab/nginx -t\n'
    else
        printf 'sudo -n nginx -t\n'
    fi
}

################################################################################
# SECTION 2 — reading a vhost. Pure functions over a captured directory.
################################################################################

# vhost_is_active <relpath>
# True only for a file nginx actually loads: top level, suffix .conf.
vhost_is_active() {
    local rel="$1"
    case "$rel" in */*) return 1 ;; esac
    case "$rel" in *.conf) return 0 ;; esac
    return 1
}

# vhost_active_confs <dir>   — loaded files, in the order nginx loads them.
vhost_active_confs() {
    local dir="$1" f rel
    for f in "$dir"/*.conf; do
        [ -f "$f" ] || continue
        rel="${f#"$dir"/}"
        printf '%s\n' "$rel"
    done | sort
}

# vhost_all_files <dir> — every captured file, active or inert.
vhost_all_files() {
    local dir="$1"
    (cd "$dir" 2>/dev/null && find . -type f ! -name '.facts' 2>/dev/null | sed 's|^\./||' | sort) || true
}

# vhost_roots_of <file> — the `root` directives declared in one config.
vhost_roots_of() {
    local f="$1"
    [ -f "$f" ] || return 0
    # NOT anchored to the line start. A `root` directive is frequently inline
    # inside a location block — including the ACME location this file writes.
    # Missing those would report "no vhost serves it" about a vhost that plainly
    # does, which is the one sentence this verb must never get wrong. The
    # leading-boundary class stops it matching `proxy_set_header X-Root`.
    grep -oE '(^|[[:space:]{;])root[[:space:]]+[^;]+;' "$f" 2>/dev/null \
        | sed -E 's/^[^r]*root[[:space:]]+//; s/;[[:space:]]*$//' \
        | tr -d '"' | sed 's|/*$||' | sed '/^$/d' | sort -u
}

# vhost_server_names_of <file>
vhost_server_names_of() {
    local f="$1"
    [ -f "$f" ] || return 0
    grep -oE '^[[:space:]]*server_name[[:space:]]+[^;]+;' "$f" 2>/dev/null \
        | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;[[:space:]]*$//' \
        | tr ' ' '\n' | sed '/^$/d' | sort -u
}

# vhost_serves_root <file> <declared-root>
# A vhost serves a declared root when a `root` directive IS that path or sits
# BENEATH it — the site declares /var/www/x and nginx serves /var/www/x/html.
# Same containment rule `pl server roots` uses, deliberately.
vhost_serves_root() {
    local f="$1" decl="$2" r
    [ -n "$decl" ] || return 1
    decl="${decl%/}"
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        [ "$r" = "$decl" ] && return 0
        [[ "$r" == "$decl"/* ]] && return 0
    done < <(vhost_roots_of "$f")
    return 1
}

# vhost_has_443 <file>
vhost_has_443() { grep -qE '^[[:space:]]*listen[[:space:]]+[^;]*443' "$1" 2>/dev/null; }

# vhost_cert_of <file> — the first ssl_certificate path.
vhost_cert_of() {
    local line=""
    read -r line < <(grep -oE '^[[:space:]]*ssl_certificate[[:space:]]+[^;]+;' "$1" 2>/dev/null \
        | sed -E 's/^[[:space:]]*ssl_certificate[[:space:]]+//; s/;[[:space:]]*$//') || true
    printf '%s\n' "$line"
}

# vhost_fallthrough_conf <dir>
# WHICH CERTIFICATE DOES 443 FALL THROUGH TO? This is the question that would
# have explained the incident in one command. When no server block matches the
# requested name, nginx serves the DEFAULT server for that port: the block
# marked `default_server`, or failing that the first one loaded — and conf.d is
# globbed in collation order, so "first" means alphabetically first file.
vhost_fallthrough_conf() {
    local dir="$1" rel first=""
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        vhost_has_443 "$dir/$rel" || continue
        if grep -qE '^[[:space:]]*listen[[:space:]]+[^;]*443[^;]*default_server' "$dir/$rel" 2>/dev/null; then
            printf '%s\n' "$rel"; return 0
        fi
        [ -z "$first" ] && first="$rel"
    done < <(vhost_active_confs "$dir")
    [ -n "$first" ] && printf '%s\n' "$first"
}

# vhost_stashes_for <dir> <site> <declared-root>
# Inert files that look like a stashed vhost for this site. Attribution is by
# CONTENT first (it serves the declared root) and only then by name, so a
# stash named nothing like the site is still found — and a file merely named
# after the site but serving something else is not silently trusted.
vhost_stashes_for() {
    local dir="$1" site="$2" decl="$3" rel
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        vhost_is_active "$rel" && continue
        if [ -n "$decl" ] && vhost_serves_root "$dir/$rel" "$decl"; then
            printf '%s\n' "$rel"; continue
        fi
        case "$(basename "$rel")" in
            "$site".conf*|"$site".*.conf|"$site"-*) printf '%s\n' "$rel" ;;
        esac
    done < <(vhost_all_files "$dir")
}

################################################################################
# SECTION 3 — the two repair classes the incident proved necessary
################################################################################

# vhost_repair_gitlab_includes <file>
# REPAIR 1. A vhost written when the box ran GitLab's bundled nginx includes
# /opt/gitlab/embedded/conf/…; on a standalone box that path does not exist and
# nginx -t fails with `open() failed (2: No such file or directory)`. The
# system copy is the same file at /etc/nginx/. Emits the repaired config on
# stdout; returns 0 if it changed anything, 1 if there was nothing to do.
vhost_repair_gitlab_includes() {
    local f="$1"
    if grep -q '/opt/gitlab/embedded/conf/' "$f" 2>/dev/null; then
        sed 's|/opt/gitlab/embedded/conf/|/etc/nginx/|g' "$f"
        return 0
    fi
    cat "$f"
    return 1
}

# vhost_needs_acme <file>
vhost_needs_acme() {
    grep -q 'well-known/acme-challenge' "$1" 2>/dev/null && return 1
    return 0
}

# vhost_repair_acme <file> <webroot>
# REPAIR 2. A port-80 block that is a bare `return 301` breaks certbot's
# webroot renewal: the ACME challenge is redirected to https and the validation
# fails. The site keeps working until the cert expires, then goes down — which
# is precisely the class of outage this whole issue is about, deferred 90 days.
#
# GUARD (the hand-restore script's own floor, kept): the file must contain
# EXACTLY ONE `return 301` line. Zero means this is not the shape we think it
# is; more than one means we cannot tell which block is the port-80 redirect.
# Either way, refuse rather than edit the wrong line. Returns 1 and changes
# nothing when it cannot act; 2 when the guard refuses.
vhost_repair_acme() {
    local f="$1" webroot="$2" n
    if ! vhost_needs_acme "$f"; then cat "$f"; return 1; fi
    # `grep -c` already prints a count AND exits 1 when the count is zero, so
    # `|| echo 0` appends a SECOND line and yields "0\n0" — which is not an
    # integer, so the guard below errored out and fell through to the edit. The
    # guard that refuses to edit blind was itself blind. Caught by the
    # no-redirect-line case in tests/unit/test-server-vhost.bats.
    # NOT anchored to the line start: in every real vhost on the estate the
    # redirect lives INSIDE its location block on one line —
    #   `location / { return 301 https://$server_name$request_uri; }`
    # An anchored regex matched nothing and reported "found 0" on exactly the
    # configs this repair exists for.
    n=$(grep -cE 'return[[:space:]]+301' "$f" 2>/dev/null || true)
    [ -n "$n" ] || n=0
    if [ "$n" != "1" ]; then
        cat "$f"
        printf 'REFUSED: expected exactly one `return 301` line, found %s — not editing blind\n' "$n" >&2
        return 2
    fi
    [ -n "$webroot" ] || { cat "$f"; printf 'REFUSED: no webroot for the ACME location\n' >&2; return 2; }
    awk -v wr="$webroot" '
      /return[[:space:]]+301/ && !done {
        match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
        printf "%slocation ^~ /.well-known/acme-challenge/ { auth_basic off; root %s; allow all; }\n", ind, wr
        done = 1
      }
      { print }
    ' "$f"
    return 0
}

################################################################################
# SECTION 3b — CREATING a vhost that has never existed
#
# WHY THIS EXISTS (static image-host handover 2026-08-22, §8.1)
# ----------------------------------------------------------
# `--restore` rebuilds from a STASH and, by design, "never overwrites an
# existing conf". A name that has never existed has no stash, so --restore has
# nothing to rebuild from and correctly refuses. The verb detected the gap and
# could not act on it — the same shape as ops#359 itself, one level up: creating
# a vhost was still hand-run `ssh` + `install`, so the standing-order exception
# ops#359 was opened to repay reopened the moment a NEW name was needed.
#
# THE TWO-STAGE SHAPE IS NOT A STYLE CHOICE. The real vhost names
# /etc/letsencrypt/live/<domain>/fullchain.pem, which does not exist until
# certbot has issued it. Install it first and `nginx -t` fails — on the box that
# also serves GitLab. So the bootstrap (port 80, ACME only, no TLS) is a
# separate emission, and the caller runs certbot between the two.
#
# GENERATION IS PURE (rule 2): these functions take strings and emit a config on
# stdout. No ssh, no box, no state — which is what lets every property below be
# driven from a fixture.
################################################################################

# _vhost_valid_domain <s> — a hostname, and nothing that could close a block.
# What this emits is fed to `nginx -t` and installed as root on the forge, so a
# domain carrying `;` or `}` would let argv write arbitrary nginx directives.
_vhost_valid_domain() {
    case "$1" in
        ''|*[!a-zA-Z0-9.-]*) return 1 ;;
        -*|.*|*.|*..*)       return 1 ;;
    esac
    case "$1" in *.*) return 0 ;; esac
    return 1
}

# _vhost_valid_root <s> — an absolute path, no metacharacters, no traversal.
_vhost_valid_root() {
    case "$1" in
        /*) ;;
        *)  return 1 ;;
    esac
    case "$1" in
        *[!a-zA-Z0-9._/-]*) return 1 ;;
        *..*)               return 1 ;;
    esac
    return 0
}

# vhost_create_conf <stage> <kind> <domain> <root>
#   stage : bootstrap | full
#   kind  : static          (the only kind today — see the REFUSED below)
# Emits the config on stdout. 2 = REFUSED, and nothing is emitted.
vhost_create_conf() {
    local stage="$1" kind="$2" domain="$3" root="$4"

    if ! _vhost_valid_domain "$domain"; then
        printf 'REFUSED: %s is not a valid domain for a server_name\n' "${domain:-<empty>}" >&2
        return 2
    fi
    if ! _vhost_valid_root "$root"; then
        printf 'REFUSED: %s is not a valid absolute document root\n' "${root:-<empty>}" >&2
        return 2
    fi
    root="${root%/}"

    case "$kind" in
        static) ;;
        *)
            # Deliberately NOT a fallback to static. A php or proxy vhost needs
            # a socket or an upstream this function was never told about, and
            # guessing one onto the box that serves GitLab is exactly the class
            # of "helpful" default this estate does not take.
            printf 'REFUSED: unsupported template kind %s (known: static)\n' "${kind:-<empty>}" >&2
            return 2 ;;
    esac

    case "$stage" in
        bootstrap)
            cat <<EOF
# ${domain} — STAGE 1 of 2 (HTTP only), generated by \`pl server vhost --create\`.
#
# The full vhost names /etc/letsencrypt/live/${domain}/fullchain.pem, which does
# not exist until certbot has issued it — installing that first fails nginx -t.
# This stage exists ONLY to answer the http-01 challenge. Replace it with
# --stage=full once the certificate exists.

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    # The challenge is served, not redirected. A bare \`return 301\` here sends
    # certbot's own validation request to https and issuance fails.
    location ^~ /.well-known/acme-challenge/ {
        auth_basic off;
        root ${root};
        allow all;
    }

    location / {
        return 404;
    }
}
EOF
            return 0 ;;
        full)
            cat <<EOF
# ${domain} — static host, generated by \`pl server vhost --create\`.
#
# Reload and test with the commands this box actually uses; \`vhost_reload_cmd\`
# and \`vhost_test_cmd\` derive them from a measured fact, never from the host's
# name. On a GitLab-bundled box \`systemctl reload nginx\` targets a dead unit
# and reports success having reloaded nothing.

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    # Kept on the TLS-serving vhost too: certbot renews over http-01 every 60
    # days, and a port-80 block that only redirects breaks renewal silently —
    # the site then dies when the certificate expires, 90 days after anyone
    # touched it.
    location ^~ /.well-known/acme-challenge/ {
        auth_basic off;
        root ${root};
        allow all;
    }

    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};

    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    root ${root};

    # No listing and no index: a bare directory path 404s rather than
    # enumerating what is in the docroot.
    autoindex off;

    # An ALLOW-LIST of static image types. Everything else is refused rather
    # than served, so a stray file landing in this docroot can never become an
    # executable or phishable page on the box that also serves GitLab.
    #
    # \`add_header\` is NOT repeated here on purpose. nginx's add_header
    # inheritance is replace-not-merge: one add_header in this block would drop
    # all three security headers above from every image response. \`expires\`
    # belongs to a different module and does not have that effect.
    location ~* \\.(png|jpe?g|gif|webp|avif|svg|ico)\$ {
        try_files \$uri =404;
        expires 30d;
    }

    location ~ /\\. {
        deny all;
    }

    location / {
        return 404;
    }
}
EOF
            return 0 ;;
        *)
            printf 'REFUSED: unknown stage %s (known: bootstrap, full)\n' "${stage:-<empty>}" >&2
            return 2 ;;
    esac
}

# The marker every generated config carries. It is what lets --create tell its
# own throwaway stage-1 from somebody's live configuration.
VHOST_GENERATED_MARKER='generated by `pl server vhost --create`'

# vhost_is_generated_bootstrap <file> <domain>
# 0 only for a STAGE 1 config this verb generated, for THIS domain. Everything
# else — a hand-written vhost, a generated bootstrap for another name, an
# already-completed full vhost — is somebody's live config and returns 1.
#
# This is the guard on the one legitimate overwrite in the whole verb: replacing
# the HTTP-only bootstrap with the TLS vhost once certbot has issued the
# certificate. Without it, "--create again to finish the job" would be a
# general-purpose clobber.
vhost_is_generated_bootstrap() {
    local f="$1" domain="$2"
    [ -f "$f" ] || return 1
    [ -n "$domain" ] || return 1
    grep -qF "$VHOST_GENERATED_MARKER" "$f" 2>/dev/null || return 1
    grep -qF 'STAGE 1 of 2' "$f" 2>/dev/null || return 1
    # A bootstrap names no certificate. If this one does, it is not a bootstrap.
    grep -q 'ssl_certificate' "$f" 2>/dev/null && return 1
    # …and it must be the bootstrap for the name we are about to serve.
    vhost_server_names_of "$f" | grep -qx "$domain" || return 1
    return 0
}

################################################################################
# SECTION 4 — applying a restore (the only thing here that writes)
################################################################################

# vhost_apply_script <target-conf-path> <test-cmd> <reload-cmd>
# Writes the new conf, TESTS the whole nginx config, and reloads only if the
# test passed — otherwise removes what it wrote and leaves the box exactly as
# it was. Refuses to overwrite an existing conf (the hand-restore's guard, kept
# as the floor). The content is delivered on stdin, never interpolated into the
# remote command line.
#
# <test-cmd> is PASSED IN, from vhost_test_cmd, rather than hardcoded to
# `nginx -t`. On a box running GitLab's bundled nginx a bare `nginx -t` tests a
# different binary against a different top-level config from the one about to be
# reloaded — see vhost_test_cmd for the measurement.
vhost_apply_script() {
    local target="$1" test_cmd="$2" reload="$3" allow_replace="${4:-0}"
    cat <<REMOTE
set -u
target='${target}'
allow_replace='${allow_replace}'
backup=''
if sudo -n test -e "\$target"; then
  if [ "\$allow_replace" != "1" ]; then
    printf 'REFUSED: %s already exists — this never overwrites a live config\n' "\$target" >&2
    exit 1
  fi
  # Keep the ORIGINAL bytes. On a replace, removing the file when the config
  # test fails would delete a WORKING vhost because its successor was bad —
  # turning a failed upgrade into an outage.
  backup=\$(mktemp)
  sudo -n cat "\$target" > "\$backup" || { printf 'FAILED: could not read %s to back it up\n' "\$target" >&2; exit 1; }
fi
tmp=\$(mktemp)
cat > "\$tmp"
if [ ! -s "\$tmp" ]; then
  printf 'REFUSED: empty configuration — refusing to install it\n' >&2
  rm -f "\$tmp"; exit 1
fi
sudo -n install -o root -g root -m 0644 "\$tmp" "\$target" || { printf 'FAILED: could not write %s\n' "\$target" >&2; rm -f "\$tmp"; exit 1; }
rm -f "\$tmp"
if ! ${test_cmd} 2>&1; then
  if [ -n "\$backup" ]; then
    sudo -n install -o root -g root -m 0644 "\$backup" "\$target"
    rm -f "\$backup"
    printf 'FAILED: the config test rejected this config — RESTORED the previous %s, the box is unchanged\n' "\$target" >&2
  else
    sudo -n rm -f "\$target"
    printf 'FAILED: the config test rejected this config — REMOVING it, the box is unchanged\n' >&2
  fi
  exit 2
fi
rm -f "\$backup" 2>/dev/null || true
${reload} || { printf 'FAILED: reload failed\n' >&2; exit 3; }
printf 'APPLIED: %s installed, config test passed, nginx reloaded\n' "\$target"
REMOTE
}
