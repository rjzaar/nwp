#!/usr/bin/env bats
# Item 7 (host-state-capture) — the acceptance suite for `pl server-state`.
#
# WHY THIS EXISTS
#
# Load-bearing host state in this estate lives ONLY on the boxes. Measured
# 2026-07-26 against the live fleet:
#
#   * The whole DR chain is one root cron one-liner on met, written by a
#     `dr-pull-setup.sh` that exists in NO repo. Its restic retention
#     (`--keep-monthly 12` of raw prod) is an inline flag nobody can grep —
#     while the GDPR retention work is about exactly that number.
#   * `nginx/snippets/deny-files-secrets.conf` is committed and calls itself
#     "the HTTP-serving layer of a 3-part defence". On the box
#     /etc/nginx/snippets/ holds only fastcgi-php.conf and snakeoil.conf, and
#     NO vhost includes it. Layer 2 is fiction.
#   * max_input_vars=5000 is set on PHP 8.3. Moodle runs on 8.2
#     (ss.conf -> php8.2-fpm.sock), still at the default 1000.
#   * nwc-cron.timer/.service and cccrdf-api.service are unversioned.
#   * ufw allows 22/tcp from Anywhere (twice) plus an orphan world-open 5050
#     with nothing bound.
#
# The counterexample this project already paid for is `nwp-daily-audit`: a
# load-bearing script that existed only on met, diverged from its repo
# namesake, and reported "no change" for 31 nights over a stopped container.
# THE RULE THAT FALLS OUT: if it is load-bearing, it must be in version
# control, and a `pl` verb must be able to prove the captured copy still
# matches the running one.
#
# THE VACUITY THESE TESTS GUARD AGAINST
#
# Capturing a file into servers/ and never committing it is WORSE than not
# capturing it, because the tree then LOOKS captured. Root .gitignore line 169
# is a blanket `servers/*`, so every path this command writes is ignored by
# default and `git status` stays clean. `check` therefore asserts
# git-TRACKEDNESS, not mere presence on disk -- that is case 1, and it is the
# single most important assertion in this file.
#
# Everything below runs against a SYNTHETIC fixture tree with a stub fetcher,
# so the detector behaves identically on a workstation and on a CI runner with
# no ssh access and no servers/ directory at all. A case that degraded to
# "skip" without the real fleet would be the same disease we are curing.

setup() {
    REAL_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    PL="${REAL_ROOT}/pl"
    FIX="${BATS_TEST_TMPDIR}/fix"
    mkdir -p "$FIX"

    # A throwaway git repo so git-trackedness is a real, testable property
    # rather than something we mock.
    git init -q "$FIX"
    git -C "$FIX" config user.email t@t.t
    git -C "$FIX" config user.name t
    export NWP_SERVER_STATE_ROOT="$FIX"

    # Stub fetcher: `pl server-state` shells out to this for every remote read,
    # so no test in this file touches the network. It echoes whatever the case
    # staged for that artifact id.
    export NWP_SERVER_STATE_FETCH="${FIX}/fetch-stub.sh"
    cat > "$NWP_SERVER_STATE_FETCH" <<'STUB'
#!/bin/bash
# args: <host> <artifact-id>; prints staged "live" content for that id.
staged="${NWP_SERVER_STATE_STAGE}/${2}"
[ -f "$staged" ] || exit 7
cat "$staged"
STUB
    chmod +x "$NWP_SERVER_STATE_FETCH"

    export NWP_SERVER_STATE_STAGE="${FIX}/stage"
    mkdir -p "$NWP_SERVER_STATE_STAGE"
}

# Write a one-artifact inventory for host `h1`.
mk_inventory() {
    mkdir -p "${FIX}/servers/h1/system"
    cat > "${FIX}/servers/h1/system/inventory.yml" <<YML
host: h1
artifacts:
  - id: ${1:-motd}
    kind: ${2:-file}
    remote: /etc/motd
    why: fixture
YML
}

# ---------------------------------------------------------------------------
# 1. THE HEADLINE CASE. A captured file that is not git-tracked is not
#    captured. Under the blanket `servers/*` ignore rule this is the default
#    outcome, which is why it must be an error and not a warning.
# ---------------------------------------------------------------------------
@test "check FAILS when a captured artifact exists on disk but is untracked" {
    mk_inventory motd
    echo "hello" > "${FIX}/servers/h1/system/motd"
    # deliberately NOT git-added, and mirror the real blanket ignore
    echo 'servers/*' > "${FIX}/.gitignore"

    run "$PL" server-state check h1
    [ "$status" -ne 0 ]
    [[ "$output" == *UNTRACKED* ]]
}

@test "check PASSES once that same artifact is committed" {
    mk_inventory motd
    echo "hello" > "${FIX}/servers/h1/system/motd"
    git -C "$FIX" add -A
    git -C "$FIX" -c commit.gpgsign=false commit -qm fixture

    run "$PL" server-state check h1
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 2. Drift must be loud. This is the property `nwp-daily-audit` never had.
# ---------------------------------------------------------------------------
@test "diff EXITS NON-ZERO when the live artifact differs from the captured copy" {
    mk_inventory motd
    echo "captured" > "${FIX}/servers/h1/system/motd"
    echo "live-and-different" > "${NWP_SERVER_STATE_STAGE}/motd"

    run "$PL" server-state diff h1
    [ "$status" -ne 0 ]
    [[ "$output" == *DRIFT* ]]
}

@test "diff exits zero when live matches captured" {
    mk_inventory motd
    echo "same" > "${FIX}/servers/h1/system/motd"
    echo "same" > "${NWP_SERVER_STATE_STAGE}/motd"

    run "$PL" server-state diff h1
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 3. "Cannot verify" is not "clean" -- the lesson from the boundary gate and
#    from the met audit that reported no-change over a stopped container. An
#    unreachable host must NOT read as agreement.
# ---------------------------------------------------------------------------
@test "diff reports UNREACHABLE (non-zero) rather than clean when the fetch fails" {
    mk_inventory motd
    echo "captured" > "${FIX}/servers/h1/system/motd"
    # nothing staged -> stub exits 7

    run "$PL" server-state diff h1
    [ "$status" -ne 0 ]
    [[ "$output" == *UNREACHABLE* ]]
}

# ---------------------------------------------------------------------------
# 4. A declared artifact that was never captured is a hole in the DR story.
# ---------------------------------------------------------------------------
@test "check FAILS when the inventory declares an artifact with no captured file" {
    mk_inventory motd
    git -C "$FIX" add -A
    git -C "$FIX" -c commit.gpgsign=false commit -qm fixture
    # inventory names motd; no servers/h1/system/motd was ever written

    run "$PL" server-state check h1
    [ "$status" -ne 0 ]
    [[ "$output" == *MISSING* ]]
}

# ---------------------------------------------------------------------------
# 5. SECURITY. Capturing authorized_keys verbatim would copy every public key
#    into the repo and, worse, train the habit of pulling ~/.ssh into git. The
#    capture must keep OPTIONS and COMMENTS only. If this ever regresses, the
#    capture verb becomes an exfiltration path.
# ---------------------------------------------------------------------------
@test "ssh-policy capture strips key material and keeps only options" {
    mk_inventory authorized-keys ssh-policy
    cat > "${NWP_SERVER_STATE_STAGE}/authorized-keys" <<'AK'
command="/usr/bin/rrsync -ro /var/backups/nwp-pull",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISECRETKEYMATERIALXXXX dr-pull@met
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDLONGSECRETBLOBHEREXXXX operator@laptop
AK

    run "$PL" server-state capture h1
    [ "$status" -eq 0 ]

    captured="${FIX}/servers/h1/system/authorized-keys"
    [ -f "$captured" ]
    # The option string is the security-relevant part and must survive.
    grep -q 'command="/usr/bin/rrsync -ro /var/backups/nwp-pull"' "$captured"
    # No key material may appear, in any form.
    ! grep -q 'SECRETKEYMATERIAL' "$captured"
    ! grep -q 'LONGSECRETBLOB' "$captured"
    ! grep -qE 'AAAA[A-Za-z0-9+/]{16,}' "$captured"
}

# ---------------------------------------------------------------------------
# 5b. Routable IP literals must not enter the repo. The DR cron -- the single
#     most important artifact to version -- carries `gitlab@<public-ip>`, and
#     the leakage gate rightly rejects the operator's public address. Private,
#     tailnet/CGNAT and loopback ranges are KEPT: the topology they describe is
#     the reviewable part, and stripping it would gut the capture's value.
# ---------------------------------------------------------------------------
@test "capture redacts routable IPs but keeps private and tailnet ones" {
    mk_inventory dr-cron file
    cat > "${NWP_SERVER_STATE_STAGE}/dr-cron" <<'CRON'
0 3 * * * root rsync -a -e ssh gitlab@203.0.113.9: /srv/staging/ && \
  restic -r /srv/repo forget --keep-monthly 12 --prune
# peers: tailnet 100.64.0.3, lan 192.168.0.13, loopback 127.0.0.1
CRON

    run "$PL" server-state capture h1
    [ "$status" -eq 0 ]

    captured="${FIX}/servers/h1/system/dr-cron"
    ! grep -q '203\.0\.113\.9' "$captured"
    grep -q '<public-ip-redacted>' "$captured"
    # topology preserved
    grep -q '100\.64\.0\.3'   "$captured"
    grep -q '192\.168\.0\.13' "$captured"
    grep -q '127\.0\.0\.1'    "$captured"
    # and the thing we actually came for survives intact
    grep -q -- '--keep-monthly 12' "$captured"
}

# ---------------------------------------------------------------------------
# 5d. IDENTITY. The first real capture of the fleet put SIX leakage-gate
#     findings into the tree -- internal-bare-hostname, live-domain-apex,
#     live-internal-domain and operator-home-path twice -- because host state
#     is, by its nature, made of the operator's hostnames, domain and home
#     directories. The gate was working; the capture was the new leak.
#
#     The tempting fix (add servers/ to the gitleaks allowlist) would re-blind
#     the gate over precisely the tree this item exists to add, so instead the
#     identifiers are substituted for their ROLE placeholders, read from the
#     same private manifest `pl host` uses. Nothing is hardcoded: writing the
#     apex domain literally in the script would itself trip live-domain-apex,
#     which covers .sh files.
#
#     Ordering is the subtle part: the longest literal must win, or the bare
#     apex swallows the tail of `git.<apex>` and leaves a half-substituted
#     hostname that still reads as a leak to a human.
# ---------------------------------------------------------------------------
@test "capture substitutes hostnames and the apex domain for role placeholders" {
    cat > "${FIX}/manifest.yml" <<'YML'
roles:
  gitlab-host: [git.example-apex.org]
  ci-host: [buildbox]
domains:
  prod-base: example-apex.org
YML
    export NWP_INSTANCE_MANIFEST="${FIX}/manifest.yml"

    mk_inventory audit file
    cat > "${NWP_SERVER_STATE_STAGE}/audit" <<'SH'
#!/bin/bash
API="https://git.example-apex.org/api/v4/projects"
SITE="https://nwc.example-apex.org"
ROOT=/home/someone/nwp
scp buildbox:/srv/x /tmp/x
SH

    run "$PL" server-state capture h1
    [ "$status" -eq 0 ]

    captured="${FIX}/servers/h1/system/audit"
    # Longest-first: the bound host must become its role, not a mangled tail.
    grep -q 'https://<gitlab-host>/api/v4/projects' "$captured"
    ! grep -q 'git\.example-apex\.org' "$captured"
    # The bare apex still goes, and the subdomain label survives as structure.
    grep -q 'nwc\.<prod-base>' "$captured"
    ! grep -q '[^-]example-apex\.org' "$captured"
    # Bare internal hostname -> role.
    grep -q 'scp <ci-host>:/srv/x' "$captured"
    # Operator home is generic (the account name differs per host).
    grep -q '/home/<operator>/nwp' "$captured"
    ! grep -q '/home/someone' "$captured"
}

# ---------------------------------------------------------------------------
# 5e. FAIL CLOSED when identity substitution cannot be performed.
#
# This is the real bug the CI runner found, and it is worth stating precisely.
# yq 4.44.1 emits a literal backslash-t for "\t" inside a concatenation; 4.50.1
# emits a real tab. The dev box has 4.50.1, the runner has 4.44.1. The map was
# built with a tab separator, so on the runner every line was one unsplit
# field: `read` put the whole thing in the literal and left the placeholder
# empty, every substitution looked for a string that never occurred, and
# REDACTION SILENTLY DID NOTHING while capture reported success.
#
# The separator is now `|`, which every version passes through verbatim. But
# the separator was only the trigger; the defect was that a broken map
# degraded to "write the file unredacted". Writing an un-redacted host file
# into the repo is the leak this pass exists to prevent, and it is silent by
# construction — so the map is now asserted USABLE before any byte is written.
# ---------------------------------------------------------------------------
@test "capture REFUSES to write when the manifest yields no usable identity pairs" {
    # A syntactically fine manifest with no roles and no domains: yq succeeds,
    # the map is empty. Previously this captured happily, unredacted.
    printf 'something_else: true\n' > "${FIX}/manifest.yml"
    export NWP_INSTANCE_MANIFEST="${FIX}/manifest.yml"

    mk_inventory conf file
    printf 'url=https://git.example-apex.org/x\n' > "${NWP_SERVER_STATE_STAGE}/conf"

    run "$PL" server-state capture h1
    [ "$status" -ne 0 ]
    [[ "$output" == *"NO usable identity pairs"* ]]
    # Nothing may have been written.
    [ ! -f "${FIX}/servers/h1/system/conf" ]
}

@test "the identity map survives a yq that does not expand backslash escapes" {
    # Pin the separator contract directly, independent of the local yq version:
    # every emitted pair must split into exactly two fields on '|', and the
    # placeholder must be angle-bracketed. A map line containing a literal
    # backslash-t is the 4.44.1 signature and must not appear.
    cat > "${FIX}/manifest.yml" <<'YML'
roles:
  gitlab-host: [git.example-apex.org]
domains:
  prod-base: example-apex.org
YML
    export NWP_INSTANCE_MANIFEST="${FIX}/manifest.yml"

    mk_inventory conf file
    printf 'x\n' > "${NWP_SERVER_STATE_STAGE}/conf"
    run "$PL" server-state capture h1
    [ "$status" -eq 0 ]

    # Re-derive the map the way the script does and assert its SHAPE.
    map="$(yq e '.roles // {} | to_entries | .[] | .key as $r | (.value // []) | .[] | . + "|<" + $r + ">"' "${FIX}/manifest.yml")"
    [ -n "$map" ]
    [[ "$map" != *'\t'* ]]
    echo "$map" | grep -qE '^[^|]+\|<[^>]+>$'
}

# A home-relative remote (`~/bin/x`) is how an inventory names a file without
# writing an operator home path into the repo -- the account differs per host,
# and the literal would trip operator-home-path. It only works if the remote
# shell gets to expand it: quoting the whole path turns the tilde into a
# literal directory name and the artifact silently becomes UNREACHABLE. That
# happened on the first run of the real inventory, so it is pinned here.
@test "a home-relative remote path is expanded by the remote shell, not quoted literally" {
    mkdir -p "${FIX}/servers/h1/system"
    cat > "${FIX}/servers/h1/system/inventory.yml" <<'YML'
host: h1
ssh_role: ci-host
artifacts:
  - id: script
    kind: file
    remote: ~/bin/thing
    why: fixture
YML
    # The default fetch path is what we are testing, so the stub has to stand
    # in for ssh itself rather than for the whole fetch.
    unset NWP_SERVER_STATE_FETCH
    export NWP_INSTANCE_MANIFEST="${FIX}/manifest.yml"
    printf 'roles:\n  ci-host: [stub-host]\n' > "${FIX}/manifest.yml"

    mkdir -p "${FIX}/bin"
    cat > "${FIX}/bin/ssh" <<'STUB'
#!/bin/bash
# Echo back the remote command so the test can assert on its SHAPE.
for a in "$@"; do last="$a"; done
printf '%s\n' "$last"
STUB
    chmod +x "${FIX}/bin/ssh"
    PATH="${FIX}/bin:$PATH" run "$PL" server-state capture h1
    [ "$status" -eq 0 ]

    captured="${FIX}/servers/h1/system/script"
    # $HOME must reach the remote shell in expandable form (it is double-quoted,
    # so the remote shell expands it); the tail is separately quoted.
    grep -q '"\$HOME"/bin/thing' "$captured"
    # The literal tilde must NOT survive as a directory component.
    ! grep -q '~/bin/thing' "$captured"
}

@test "redaction is idempotent, so diff does not report permanent drift" {
    cat > "${FIX}/manifest.yml" <<'YML'
roles:
  gitlab-host: [git.example-apex.org]
domains:
  prod-base: example-apex.org
YML
    export NWP_INSTANCE_MANIFEST="${FIX}/manifest.yml"

    mk_inventory conf file
    printf 'url=https://git.example-apex.org/x\nhome=/home/someone\n' \
        > "${NWP_SERVER_STATE_STAGE}/conf"

    run "$PL" server-state capture h1
    [ "$status" -eq 0 ]

    # Same live content, unchanged host: diff must be clean. If redaction were
    # not deterministic and idempotent, every host would look permanently
    # drifted and the signal would be trained away as noise.
    run "$PL" server-state diff h1
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 5c. THE nwp-daily-audit LESSON. met runs a 257-line ~/bin/nwp-daily-audit;
#     the repo ships a 331-line scripts/nwp-daily-audit.sh. They share no
#     header. Nothing compared them, so the divergence survived — and the
#     running one reported "no change" for 31 nights over a stopped container.
#     Divergence is allowed; SILENT divergence is not.
# ---------------------------------------------------------------------------
mk_counterpart_inventory() {
    mkdir -p "${FIX}/servers/h1/system"
    {
        printf 'host: h1\nartifacts:\n  - id: script\n    kind: file\n    remote: /x\n'
        printf '    repo_counterpart: scripts/thing.sh\n'
        if [ -n "${1:-}" ]; then
            printf '    counterpart_divergence: "%s"\n' "$1"
        fi
    } > "${FIX}/servers/h1/system/inventory.yml"
}

@test "check FAILS when a captured artifact silently differs from its repo counterpart" {
    mk_counterpart_inventory
    mkdir -p "${FIX}/scripts"
    echo "running version"  > "${FIX}/servers/h1/system/script"
    echo "repo version"     > "${FIX}/scripts/thing.sh"
    git -C "$FIX" add -A
    git -C "$FIX" -c commit.gpgsign=false commit -qm fixture

    run "$PL" server-state check h1
    [ "$status" -ne 0 ]
    [[ "$output" == *COUNTERPART-DRIFT* ]]
}

@test "check PASSES when that divergence is declared with a reason" {
    mk_counterpart_inventory "on-host copy is authoritative until pl host schedule lands"
    mkdir -p "${FIX}/scripts"
    echo "running version"  > "${FIX}/servers/h1/system/script"
    echo "repo version"     > "${FIX}/scripts/thing.sh"
    git -C "$FIX" add -A
    git -C "$FIX" -c commit.gpgsign=false commit -qm fixture

    run "$PL" server-state check h1
    [ "$status" -eq 0 ]
    [[ "$output" == *DECLARED-DIVERGENCE* ]]
}

# ---------------------------------------------------------------------------
# 6. known C, generalised. The 2026-07-26 Moodle outage was a max_input_vars
#    ceiling. The fix was applied to the PHP version Moodle does NOT run. A
#    check that reads "is 5000 set anywhere" would have passed then and would
#    pass now -- so this asserts the value on the SAPI the site actually uses.
# ---------------------------------------------------------------------------
@test "php-floor check FAILS when the SAPI a site actually uses is below the floor" {
    mkdir -p "${FIX}/servers/h1/system"
    cat > "${FIX}/servers/h1/system/inventory.yml" <<'YML'
host: h1
php_floors:
  - sapi: "8.2/fpm"
    setting: max_input_vars
    min: 5000
    why: "Moodle course edit forms; ss.conf -> php8.2-fpm.sock"
artifacts: []
YML
    # Live map says 8.3 has it and 8.2 does not -- the real 2026-07-26 shape.
    cat > "${NWP_SERVER_STATE_STAGE}/php-map" <<'MAP'
8.2/fpm max_input_vars=1000
8.3/fpm max_input_vars=5000
MAP

    run "$PL" server-state php-check h1
    [ "$status" -ne 0 ]
    [[ "$output" == *"8.2/fpm"* ]]
    [[ "$output" == *BELOW-FLOOR* ]]
}

@test "php-floor check passes when the used SAPI meets the floor" {
    mkdir -p "${FIX}/servers/h1/system"
    cat > "${FIX}/servers/h1/system/inventory.yml" <<'YML'
host: h1
php_floors:
  - sapi: "8.2/fpm"
    setting: max_input_vars
    min: 5000
    why: fixture
artifacts: []
YML
    cat > "${NWP_SERVER_STATE_STAGE}/php-map" <<'MAP'
8.2/fpm max_input_vars=5000
MAP

    run "$PL" server-state php-check h1
    [ "$status" -eq 0 ]
}
