#!/usr/bin/env bats
#
# nwp-daily-audit.sh — the audit that audited nothing for 33 nights.
#
# WHAT THESE TESTS ARE FOR
#
# The old script ran `composer` inside a DDEV container. The container was
# stopped. Every probe returned an empty file, an empty result was treated as a
# clean result, and the run logged "no change" / "DONE (changes=0)" and exited
# 0. Thirty-three consecutive nights of "I could not look" were indistinguish-
# able from thirty-three nights of "I looked and all is well", because the
# script only spoke when state CHANGED — and blindness is perfectly stable.
#
# So the tests that matter here are not "does it find advisories". They are:
#
#   1. can this script FAIL?  (simulate the unavailable container; the run must
#      exit non-zero and must notify BECAUSE it could not look)
#   2. can it still be QUIET when it genuinely has nothing to say?  (the
#      negative controls — an alarm that always rings is not an improvement on
#      an alarm that never rings)
#
# Every blindness case below was observed RED against the pre-fix script, which
# returned exit 0 and posted nothing for all of them. Set
# NWP_AUDIT_SCRIPT_UNDER_TEST to a checkout of the old file to reproduce.

SCRIPT="${NWP_AUDIT_SCRIPT_UNDER_TEST:-${BATS_TEST_DIRNAME}/../../scripts/nwp-daily-audit.sh}"

# ---------------------------------------------------------------------------
# Harness: a sandboxed site + stubbed composer/curl/ddev.
#
# The stubs are driven by files so each test can choose a probe's behaviour:
#   $WORK/composer-audit-mode     json | empty | garbage | findings
#   $WORK/composer-outdated-mode  json | empty | garbage | stale
#   $WORK/curl-upstream-mode      ok   | fail
# Every curl POST is appended to $WORK/posts.txt and every curl argv token to
# $WORK/argv.txt.
# ---------------------------------------------------------------------------
setup() {
    WORK="$BATS_TEST_TMPDIR/w"
    STUB="$WORK/bin"
    SITE="$WORK/site"
    mkdir -p "$STUB" "$SITE" "$WORK/cache"

    # A realistic-enough site: composer.json + composer.lock, and NO container.
    cat > "$SITE/composer.json" <<'EOF'
{
  "require": { "drupal/core": "^10.5", "guzzlehttp/guzzle": "^7.0" },
  "repositories": [
    { "type": "composer", "url": "https://git.example.internal/api/v4/group/x/-/packages/composer/" }
  ],
  "scripts": { "post-install-cmd": ["echo should-not-run"] }
}
EOF
    printf '{"packages":[],"packages-dev":[]}\n' > "$SITE/composer.lock"

    echo json > "$WORK/composer-audit-mode"
    echo json > "$WORK/composer-outdated-mode"
    echo ok   > "$WORK/curl-upstream-mode"

    cat > "$STUB/composer" <<'EOF'
#!/bin/bash
case "$1" in
  audit)
    case "$(cat "$WORK/composer-audit-mode")" in
      empty)    exit 1 ;;                                # container down: nothing on stdout
      garbage)  echo 'not json at all {{{' ; exit 0 ;;
      findings) echo '{"advisories":{"twig/twig":[{"advisoryId":"CVE-2026-49981","severity":"high"}]},"abandoned":{"old/pkg":"new/pkg"}}'; exit 2 ;;
      *)        echo '{"advisories":{},"abandoned":{}}'; exit 0 ;;
    esac ;;
  outdated)
    case "$(cat "$WORK/composer-outdated-mode")" in
      empty)   exit 1 ;;
      garbage) echo 'nope' ; exit 0 ;;
      stale)   echo '{"installed":[{"name":"drupal/core","version":"10.5.0","latest":"10.5.6"}]}' ; exit 0 ;;
      *)       echo '{"installed":[]}' ; exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF

    cat > "$STUB/curl" <<'EOF'
#!/bin/bash
for a in "$@"; do printf '%s\n' "$a" >> "$WORK/argv.txt"; done
is_post=0; for a in "$@"; do [ "$a" = "POST" ] && is_post=1; done
if [ "$is_post" = "1" ]; then
  { echo "=== POST ==="; for a in "$@"; do printf '%s\n' "$a"; done; } >> "$WORK/posts.txt"
  echo '{"iid":1}'; exit 0
fi
if [ "$(cat "$WORK/curl-upstream-mode")" = "fail" ]; then exit 22; fi
echo '{"require":{"drupal/core":"^10.5.6","webonyx/graphql-php":"^15"}}'
exit 0
EOF

    # If the script ever reaches for a container, the test must notice.
    cat > "$STUB/ddev" <<'EOF'
#!/bin/bash
echo "DDEV-WAS-INVOKED" >> "$WORK/ddev-calls.txt"
echo "No running container found for service 'web'" >&2
exit 1
EOF
    cat > "$STUB/docker" <<'EOF'
#!/bin/bash
echo "DOCKER-WAS-INVOKED" >> "$WORK/ddev-calls.txt"
exit 1
EOF
    chmod +x "$STUB"/composer "$STUB"/curl "$STUB"/ddev "$STUB"/docker

    printf 'SENTINELTOKEN123\n' > "$WORK/token"
    chmod 600 "$WORK/token"
    : > "$WORK/posts.txt"; : > "$WORK/argv.txt"
    export WORK
}

# Run the audit with the sandbox wired in. Extra env may be passed as args.
run_audit() {
    run env WORK="$WORK" PATH="$STUB:$PATH" \
        NWP_AUDIT_TOKEN_FILE="$WORK/token" \
        NWP_AUDIT_SITES="testsite:$SITE:goalgorilla/open_social" \
        NWP_AUDIT_CACHE_DIR="$WORK/cache" \
        NWP_AUDIT_LOG="$WORK/audit.log" \
        NWP_GITLAB_HOST="gitlab.example" \
        NWP_OPS_LOG_PROJECT="ops/verifier-log" \
        NWP_AUDIT_GIT_PULL=0 \
        "$@" \
        bash "$SCRIPT"
}

posts_count() { grep -c '=== POST ===' "$WORK/posts.txt" 2>/dev/null || true; }

# ===========================================================================
# THE HEADLINE CASES — "could not audit" must be a FAILURE, not "no change".
# All of these were RED against the pre-fix script (exit 0, zero posts).
# ===========================================================================

@test "BLIND: composer produces no output (container down) => run FAILS" {
    echo empty > "$WORK/composer-audit-mode"
    run_audit
    # The whole defect in one assertion: this used to be 0.
    [ "$status" -ne 0 ]
    [ "$status" -eq 2 ]
}

@test "BLIND: composer produces no output => it NOTIFIES because it could not look" {
    echo empty > "$WORK/composer-audit-mode"
    run_audit
    [ "$(posts_count)" -ge 1 ]
    grep -q 'COULD NOT AUDIT' "$WORK/posts.txt"
}

@test "BLIND: the notification says an unaudited state is UNKNOWN, not clean" {
    echo empty > "$WORK/composer-audit-mode"
    run_audit
    grep -qi 'did not run' "$WORK/posts.txt"
    grep -qi 'not an all-clear' "$WORK/posts.txt"
    grep -q 'UNKNOWN' "$WORK/posts.txt"
}

@test "BLIND: 'no change' is never logged for a run that could not look" {
    echo empty > "$WORK/composer-audit-mode"
    run_audit
    # The exact lie the old log told 33 times.
    ! grep -q 'no change' "$WORK/audit.log"
    grep -q 'COULD_NOT_AUDIT' "$WORK/audit.log"
}

@test "BLIND: a blind axis never erases what it last saw (R2)" {
    # A real prior finding on record...
    printf 'ADV twig/twig CVE-2026-49981 high\n' > "$WORK/cache/baseline-testsite.txt"
    echo empty > "$WORK/composer-audit-mode"
    run_audit
    [ "$status" -eq 2 ]
    # ...must survive a night we could not see. Otherwise the next diff shows
    # the advisory "disappearing" and we congratulate ourselves on a fix that
    # never happened.
    grep -q 'CVE-2026-49981' "$WORK/cache/baseline-testsite.txt"
    grep -q 'carried forward' "$WORK/audit.log"
}

@test "BLIND: a blind axis does NOT suppress findings from a sighted axis" {
    # Regression guard for a bug in the first cut of this fix: skipping the
    # findings comparison whenever anything was blind. On the real build host
    # the `outdated` axis is persistently blind (dead registry credential), so
    # that behaviour would have suppressed CVE reporting indefinitely — a check
    # that cannot fire, which is the very defect being fixed here.
    run_audit                                       # baseline: clean, all sighted
    : > "$WORK/posts.txt"
    echo findings > "$WORK/composer-audit-mode"     # a real CVE appears
    echo empty    > "$WORK/composer-outdated-mode"  # ...on a night we are part-blind
    run_audit
    [ "$status" -eq 2 ]                             # still a failure
    grep -q 'CVE-2026-49981' "$WORK/posts.txt"      # ...but the CVE still got out
    grep -q 'PARTIAL' "$WORK/posts.txt"             # ...flagged as an incomplete picture
}

@test "BLIND: unparseable probe output is blindness, not a clean result" {
    echo garbage > "$WORK/composer-audit-mode"
    run_audit
    [ "$status" -eq 2 ]
    grep -q 'BLIND' "$WORK/audit.log"
}

@test "BLIND: a missing site directory fails instead of silently skipping" {
    run env WORK="$WORK" PATH="$STUB:$PATH" \
        NWP_AUDIT_TOKEN_FILE="$WORK/token" \
        NWP_AUDIT_SITES="ghost:$WORK/does-not-exist:" \
        NWP_AUDIT_CACHE_DIR="$WORK/cache" NWP_AUDIT_LOG="$WORK/audit.log" \
        NWP_GITLAB_HOST="gitlab.example" NWP_OPS_LOG_PROJECT="ops/verifier-log" \
        bash "$SCRIPT"
    [ "$status" -eq 2 ]
}

@test "BLIND: partial blindness still fails, and keeps the axis that DID work" {
    echo findings > "$WORK/composer-audit-mode"    # adv OK, with findings
    echo empty    > "$WORK/composer-outdated-mode" # outdated BLIND
    run_audit
    [ "$status" -eq 2 ]
    grep -q 'testsite/adv: OK' "$WORK/audit.log"
    grep -q 'testsite/outdated: BLIND' "$WORK/audit.log"
}

@test "BLIND: the failure reason is reported, not swallowed as 'unknown'" {
    # Probes run in a subshell, so the reason must travel out-of-band; if that
    # is broken, every report degrades to a useless 'unknown reason'.
    echo empty > "$WORK/composer-audit-mode"
    run_audit
    ! grep -q 'BLIND — unknown reason' "$WORK/audit.log"
    grep -q 'produced no output' "$WORK/audit.log"
}

@test "BLIND: upstream fetch failure is blindness too" {
    echo fail > "$WORK/curl-upstream-mode"
    run_audit
    [ "$status" -eq 2 ]
    grep -q 'testsite/upstream: BLIND' "$WORK/audit.log"
}

# ===========================================================================
# NEGATIVE CONTROLS — an alarm that always rings is no better than one that
# never rings. A genuinely clean audit must stay silent and exit 0.
# ===========================================================================

@test "NEGATIVE CONTROL: a genuinely clean audit is silent and exits 0" {
    run_audit                      # all probes OK, no advisories
    [ "$status" -eq 0 ]
    [ "$(posts_count)" -eq 0 ]
    grep -q 'AUDITED_CLEAN' "$WORK/audit.log"
}

@test "NEGATIVE CONTROL: unchanged findings stay silent on the second run" {
    echo findings > "$WORK/composer-audit-mode"
    run_audit                      # first run bootstraps the baseline, silent
    [ "$status" -eq 0 ]
    : > "$WORK/posts.txt"
    run_audit                      # second run: same findings => nothing to say
    [ "$status" -eq 0 ]
    [ "$(posts_count)" -eq 0 ]
    grep -q 'no change' "$WORK/audit.log"
}

@test "NEGATIVE CONTROL: findings are recorded as AUDITED_FOUND_N, not as failure" {
    echo findings > "$WORK/composer-audit-mode"
    run_audit
    [ "$status" -eq 0 ]            # having findings is not a broken audit
    grep -qE 'AUDITED_FOUND_[1-9]' "$WORK/audit.log"
}

@test "a real state change does post" {
    run_audit                                   # baseline: clean
    : > "$WORK/posts.txt"
    echo findings > "$WORK/composer-audit-mode" # an advisory appears
    run_audit
    [ "$status" -eq 0 ]
    [ "$(posts_count)" -eq 1 ]
    grep -q 'site(s) changed' "$WORK/posts.txt"
    grep -q 'CVE-2026-49981' "$WORK/posts.txt"
}

# ===========================================================================
# ALERT FATIGUE — 33 blind nights must not mean 33 issues, and must not mean 1.
# ===========================================================================

@test "ALERT FATIGUE: continued blindness exits non-zero EVERY run but notifies on a cadence" {
    echo empty > "$WORK/composer-audit-mode"
    nonzero=0
    for i in 1 2 3 4 5 6 7 8; do
        run_audit NWP_AUDIT_BLIND_EVERY=7
        [ "$status" -ne 0 ] && nonzero=$((nonzero + 1))
    done
    # The continuous signal: every single run is red.
    [ "$nonzero" -eq 8 ]
    # The rate-limited signal: run 1 and run 7 only.
    [ "$(posts_count)" -eq 2 ]
}

@test "ALERT FATIGUE: the streak count is reported so 'how long' is never guesswork" {
    echo empty > "$WORK/composer-audit-mode"
    run_audit NWP_AUDIT_BLIND_EVERY=1
    run_audit NWP_AUDIT_BLIND_EVERY=1
    grep -q 'consecutive blind runs: 2' "$WORK/audit.log"
    grep -q '2 consecutive run' "$WORK/posts.txt"
}

@test "recovery from blindness is announced" {
    echo empty > "$WORK/composer-audit-mode"
    run_audit                                  # blind
    echo json > "$WORK/composer-audit-mode"    # sight returns
    run_audit
    [ "$status" -eq 0 ]
    grep -q 'RECOVERED after 1 blind run' "$WORK/audit.log"
}

# ===========================================================================
# NO CONTAINER IN THE PATH OF A SECURITY CHECK (R3)
# ===========================================================================

@test "the audit never invokes ddev or docker" {
    run_audit
    [ "$status" -eq 0 ]
    [ ! -f "$WORK/ddev-calls.txt" ]
}

@test "the audit works with no container and no vendor/ tree" {
    # $SITE has composer.json + composer.lock and nothing else. That is enough.
    [ ! -d "$SITE/vendor" ]
    run_audit
    [ "$status" -eq 0 ]
    grep -q 'AUDITED_CLEAN' "$WORK/audit.log"
}

@test "the CVE probe reads the lockfile and strips private repositories" {
    grep -q 'audit --locked' "$SCRIPT"
    grep -q 'composer.lock' "$SCRIPT"
    # A private registry credential must not be able to blind the CVE check.
    grep -q 'packagist.org' "$SCRIPT"
}

@test "the site tree is never mutated by an audit" {
    before="$(md5sum "$SITE/composer.json" "$SITE/composer.lock")"
    echo findings > "$WORK/composer-audit-mode"
    run_audit
    [ "$(md5sum "$SITE/composer.json" "$SITE/composer.lock")" = "$before" ]
}

# ===========================================================================
# STATIC / SECURITY INVARIANTS (carried over from the previous suite)
# ===========================================================================

@test "nwp-daily-audit.sh has valid bash syntax" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "nwp-daily-audit.sh is strict (set -euo pipefail)" {
    grep -Eq '^set -euo pipefail' "$SCRIPT"
}

@test "runs composer audit and composer outdated" {
    grep -Eq 'composer[^\n]*audit' "$SCRIPT"
    grep -Eq 'composer[^\n]*outdated' "$SCRIPT"
}

@test "tracks upstream drift" {
    grep -q 'upstream_probe' "$SCRIPT"
    grep -q 'UPSTREAM' "$SCRIPT"
}

@test "GitLab host/project defaults are placeholders, not a real host" {
    grep -q 'NWP_GITLAB_HOST' "$SCRIPT"
    run grep -Eq 'nwpcode\.org' "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "no hardcoded secret — token read from a 0600 file, not inline" {
    grep -q 'AUDIT_TOKEN_FILE' "$SCRIPT"
    run grep -Eq 'glpat-[A-Za-z0-9]' "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "has a SITES array and a parameterised override" {
    grep -Eq 'SITES=\(' "$SCRIPT"
    grep -q 'NWP_AUDIT_SITES' "$SCRIPT"
}

@test "documents the 02:30 UTC schedule wiring" {
    grep -Eq '30 2 \* \* \*' "$SCRIPT"
}

@test "token is passed via a 0600 curl config, never on curl argv" {
    echo findings > "$WORK/composer-audit-mode"
    run_audit                                   # bootstrap baseline
    echo json > "$WORK/composer-audit-mode"     # change state so it posts
    : > "$WORK/argv.txt"
    run_audit
    grep -q -- '-K' "$WORK/argv.txt"            # a POST really happened
    run grep -q 'SENTINELTOKEN123' "$WORK/argv.txt"
    [ "$status" -ne 0 ]                         # ...and the token was not on it
}

@test "a failed notification does not advance the baseline" {
    run_audit                                   # baseline: clean
    rm -f "$WORK/token"                         # notification channel now broken
    echo findings > "$WORK/composer-audit-mode"
    run_audit
    [ "$status" -eq 4 ]                         # audited fine, could not tell anyone
    # The finding must still be pending next run, not silently absorbed.
    ! grep -q 'CVE-2026-49981' "$WORK/cache/baseline-testsite.txt"
}

# ===========================================================================
# ANTI-SPLIT-BRAIN — the second defect: the running copy was not this copy.
# ===========================================================================

@test "the script reports its own provenance so divergence is visible in the log" {
    run_audit
    grep -qE 'START run . script=' "$WORK/audit.log"
    grep -qE 'commit=|not-a-git-checkout' "$WORK/audit.log"
}

@test "running an out-of-tree copy is labelled UNVERSIONED-COPY in the log" {
    # The split-brain symptom, made self-announcing: a hand-placed copy running
    # from outside the repo must say so, which is what ~/bin/nwp-daily-audit
    # never did.
    cp "$SCRIPT" "$WORK/handplaced-copy.sh"
    run env WORK="$WORK" PATH="$STUB:$PATH" \
        NWP_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )" \
        NWP_AUDIT_TOKEN_FILE="$WORK/token" \
        NWP_AUDIT_SITES="testsite:$SITE:goalgorilla/open_social" \
        NWP_AUDIT_CACHE_DIR="$WORK/cache" NWP_AUDIT_LOG="$WORK/audit.log" \
        NWP_GITLAB_HOST="gitlab.example" NWP_OPS_LOG_PROJECT="ops/verifier-log" \
        bash "$WORK/handplaced-copy.sh"
    grep -q 'UNVERSIONED-COPY' "$WORK/audit.log"
}

@test "the upstream-source comment matches what the code actually fetches" {
    # The reconstruction claimed Packagist while the running copy read GitHub
    # main. Whichever is chosen, the prose must describe the code.
    if grep -q 'raw.githubusercontent.com' "$SCRIPT"; then
        grep -q '/main/composer.json' "$SCRIPT"
        run grep -q 'repo.packagist.org/p2' "$SCRIPT"
        [ "$status" -ne 0 ]
    else
        grep -q 'repo.packagist.org/p2' "$SCRIPT"
    fi
}

@test "the wiring docs point cron at the versioned copy, not a hand-placed file" {
    grep -q 'scripts/nwp-daily-audit.sh' "$SCRIPT"
    grep -qi 'shim' "$SCRIPT"
}
