#!/usr/bin/env bats
# lib/server-host-guard.sh — `pl server host-guard` (nwp/ops#381).
#
# THE INCIDENT THIS REPRODUCES (2026-08-19/20). GitLab's bundled nginx on the
# forge box claims `default_server` on both ports and declares NO `server_name`
# at all, so every unmatched Host header was served the full GitLab application:
#
#     Host: forge.example.com    -> 200, 17647 bytes
#     Host: scan-target.example.net    -> 200, 17647 bytes
#     Host: totally-bogus.test -> 200, 17668 bytes
#
# An unrelated third party had a DANGLING A record pointing at a cloud address
# that had since been reallocated to us, and aimed a commercial web-application
# vulnerability scanner at it. 295,483 requests / 2.1 GB on 19 Aug; 254,399 /
# 13.1 GB by 04:43 on 20 Aug, peaking near 20 Mb/s and tripping the provider's
# outbound traffic-rate alarm. Names and addresses are in nwp/ops#381; this
# repo is publicly mirrored, so the fixtures below use RFC 2606 reserved names.
#
# The dangling record was the trigger. The Host-header promiscuity was the
# defect, and it was ours: ANY hostname on earth pointed at that IP got a full
# GitLab instance to crawl.
#
# ops#214 — "a check that has never been proven to fail is not a check" — is why
# the first test here is a RED PROOF: a fixture in exactly the live box's shape
# must make the verdict come back PROMISCUOUS with a non-zero status. A guard
# nobody has watched fire is a hypothesis, not a gate.
#
# Everything runs against FIXTURES. No ssh, no live box.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d)"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/lib/server-host-guard.sh"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "${TMP}"
}

# A probe capture in the shape the live box produced on 2026-08-20.
_facts_promiscuous() {
  cat > "${TMP}/facts" <<'EOF'
NWPHOSTGUARD v1
real_host=forge.example.com
real_code=200
bogus_host=nwp-host-guard-probe.invalid
bogus_code=200
EOF
  printf '%s' "${TMP}/facts"
}

# The same box once the guard is in place: real host still served, bogus host
# gets 444 — which a client observes as a closed connection, i.e. code 000.
_facts_guarded() {
  cat > "${TMP}/facts" <<'EOF'
NWPHOSTGUARD v1
real_host=forge.example.com
real_code=200
bogus_host=nwp-host-guard-probe.invalid
bogus_code=000
EOF
  printf '%s' "${TMP}/facts"
}

################################################################################
# THE RED PROOF — this is the test that must fail against a promiscuous box.
################################################################################

@test "RED PROOF: a promiscuous box (live shape, 2026-08-20) is graded PROMISCUOUS, non-zero" {
  local f; f="$(_facts_promiscuous)"
  run host_guard_verdict "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PROMISCUOUS"* ]]
}

@test "RED PROOF: the promiscuous verdict NAMES the bogus host that was served" {
  local f; f="$(_facts_promiscuous)"
  run host_guard_verdict "$f"
  [[ "$output" == *"nwp-host-guard-probe.invalid"* ]]
}

@test "a guarded box is graded GUARDED, zero" {
  local f; f="$(_facts_guarded)"
  run host_guard_verdict "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GUARDED"* ]]
}

################################################################################
# BLINDNESS — fail closed. An unmeasurable box is never "guarded".
################################################################################

@test "CANNOT VERIFY: a missing capture is exit 3, never GUARDED" {
  run host_guard_verdict "${TMP}/does-not-exist"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  [[ "$output" != *"GUARDED"* ]]
}

@test "CANNOT VERIFY: a capture with no version banner is exit 3" {
  printf 'real_code=200\nbogus_code=000\n' > "${TMP}/facts"
  run host_guard_verdict "${TMP}/facts"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "CANNOT VERIFY: both probes dead means the BOX is dead, not that it is guarded" {
  cat > "${TMP}/facts" <<'EOF'
NWPHOSTGUARD v1
real_host=forge.example.com
real_code=000
bogus_host=nwp-host-guard-probe.invalid
bogus_code=000
EOF
  run host_guard_verdict "${TMP}/facts"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  [[ "$output" != *"GUARDED"* ]]
}

@test "CANNOT VERIFY: an unmeasured bogus probe is exit 3" {
  cat > "${TMP}/facts" <<'EOF'
NWPHOSTGUARD v1
real_host=forge.example.com
real_code=200
bogus_host=nwp-host-guard-probe.invalid
bogus_code=
EOF
  run host_guard_verdict "${TMP}/facts"
  [ "$status" -eq 3 ]
}

################################################################################
# RENDERING — what actually gets installed, and which hosts survive it.
################################################################################

@test "render refuses an empty allowlist — that would 444 the box off the internet" {
  run host_guard_render
  [ "$status" -ne 0 ]
  [[ "$output" == *"refus"* ]] || [[ "$output" == *"REFUS"* ]]
}

@test "render carries the version marker so the guard can be found again" {
  run host_guard_render forge.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"NWP-HOST-GUARD"* ]]
}

@test "render always returns 444 — a body would still cost bandwidth" {
  run host_guard_render forge.example.com
  [[ "$output" == *"444"* ]]
}

@test "the declared host is ADMITTED by the rendered guard" {
  local snip; snip="$(host_guard_render forge.example.com)"
  run host_guard_matches "$snip" "forge.example.com"
  [ "$status" -eq 0 ]
}

@test "the scan's Host header is REJECTED by the rendered guard" {
  local snip; snip="$(host_guard_render forge.example.com)"
  run host_guard_matches "$snip" "scan-target.example.net"
  [ "$status" -eq 1 ]
}

@test "an arbitrary bogus Host is REJECTED" {
  local snip; snip="$(host_guard_render forge.example.com)"
  run host_guard_matches "$snip" "totally-bogus.test"
  [ "$status" -eq 1 ]
}

@test "dots are regex-escaped: forgeXexample.com must NOT slip through" {
  local snip; snip="$(host_guard_render forge.example.com)"
  run host_guard_matches "$snip" "forgeXexample.com"
  [ "$status" -eq 1 ]
}

@test "no suffix smuggling: evil-forge.example.com.attacker.test is REJECTED" {
  local snip; snip="$(host_guard_render forge.example.com)"
  run host_guard_matches "$snip" "forge.example.com.attacker.test"
  [ "$status" -eq 1 ]
}

@test "no prefix smuggling: notforge.example.com is REJECTED" {
  local snip; snip="$(host_guard_render forge.example.com)"
  run host_guard_matches "$snip" "notforge.example.com"
  [ "$status" -eq 1 ]
}

@test "Host matching is case-insensitive, as nginx's !~* is" {
  local snip; snip="$(host_guard_render forge.example.com)"
  run host_guard_matches "$snip" "FORGE.EXAMPLE.COM"
  [ "$status" -eq 0 ]
}

@test "a Host with a port is admitted — clients may send host:port" {
  local snip; snip="$(host_guard_render forge.example.com)"
  run host_guard_matches "$snip" "forge.example.com:443"
  [ "$status" -eq 0 ]
}

@test "localhost survives the guard — nginx-status and local health checks must not break" {
  local snip; snip="$(host_guard_render forge.example.com)"
  run host_guard_matches "$snip" "localhost"
  [ "$status" -eq 0 ]
  run host_guard_matches "$snip" "127.0.0.1"
  [ "$status" -eq 0 ]
}

@test "multiple declared hosts are all admitted" {
  local snip; snip="$(host_guard_render forge.example.com aux.example.com)"
  run host_guard_matches "$snip" "aux.example.com"
  [ "$status" -eq 0 ]
  run host_guard_matches "$snip" "forge.example.com"
  [ "$status" -eq 0 ]
  run host_guard_matches "$snip" "other.example.org"
  [ "$status" -eq 1 ]
}

@test "render rejects a host that is not a plausible hostname" {
  run host_guard_render 'forge.example.com"; return 200; #'
  [ "$status" -ne 0 ]
}

@test "render rejects a host containing a newline (config injection)" {
  run host_guard_render "$(printf 'a.test\nreturn 200;')"
  [ "$status" -ne 0 ]
}

################################################################################
# ops#351 — no verdict may be decided by a SIGPIPE race.
#
# CI caught this in the first cut of this file: every fact was read with
# `sed -n 's/^k=//p' "$f" | head -1`. head closes the pipe after one line, sed
# dies of SIGPIPE, and under `set -o pipefail` the caller sees 141 — so which
# branch ran depended on whether sed had finished writing. These run the real
# functions under errexit+pipefail, which is the shell the CI lint is defending.
################################################################################

@test "ops#351: the verdict survives errexit+pipefail (no SIGPIPE race)" {
  local f; f="$(_facts_promiscuous)"
  run bash -c "set -euo pipefail
    source '${REPO_ROOT}/lib/server-host-guard.sh'
    host_guard_verdict '$f'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PROMISCUOUS"* ]]
}

# THE DETERMINISTIC ONE. The three tests around it use the small fixture and,
# measured, do NOT reproduce the bug: sed finishes writing four lines before head
# closes the pipe, so `sed | head -1` returned 0 on 5 runs out of 5. A test that
# cannot fail is not a gate (ops#214), so this one makes the writer outrun the
# reader. Measured against the ORIGINAL `sed -n … | head -1` implementation:
# rc=141 on 3 runs out of 3. Against the awk implementation: rc=0, 3 of 3.
@test "ops#351 RED PROOF: a fact read from a LARGE capture survives errexit+pipefail" {
  {
    echo "NWPHOSTGUARD v1"
    # Enough matching lines that the writer is still going when head -1 quits.
    for _ in $(seq 1 20000); do echo "real_host=forge.example.com"; done
    echo "real_code=200"
    echo "bogus_host=nwp-host-guard-probe.invalid"
    echo "bogus_code=200"
  } > "${TMP}/big.facts"

  run bash -c "set -euo pipefail
    source '${REPO_ROOT}/lib/server-host-guard.sh'
    v=\"\$(host_guard_fact '${TMP}/big.facts' real_host)\"
    printf 'v=[%s]\n' \"\$v\"
    echo REACHED_END"
  [ "$status" -eq 0 ]
  [ "$status" -ne 141 ]
  [[ "$output" == *"v=[forge.example.com]"* ]]
  [[ "$output" == *"REACHED_END"* ]]
}

@test "ops#351 RED PROOF: the full verdict survives a LARGE capture under pipefail" {
  {
    echo "NWPHOSTGUARD v1"
    echo "real_host=forge.example.com"
    echo "real_code=200"
    echo "bogus_host=nwp-host-guard-probe.invalid"
    echo "bogus_code=200"
    # Trailing bulk: whatever the reader stops at, the writer has more to say.
    for _ in $(seq 1 20000); do echo "real_host=forge.example.com"; done
  } > "${TMP}/big2.facts"

  run bash -c "set -euo pipefail
    source '${REPO_ROOT}/lib/server-host-guard.sh'
    host_guard_verdict '${TMP}/big2.facts'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PROMISCUOUS"* ]]
}

@test "ops#351: fact extraction survives errexit+pipefail, and a MISSING key is empty not fatal" {
  local f; f="$(_facts_promiscuous)"
  run bash -c "set -euo pipefail
    source '${REPO_ROOT}/lib/server-host-guard.sh'
    printf 'got=[%s]\n' \"\$(host_guard_fact '$f' real_host)\"
    printf 'absent=[%s]\n' \"\$(host_guard_fact '$f' no_such_key)\"
    echo REACHED_END"
  [ "$status" -eq 0 ]
  [[ "$output" == *"got=[forge.example.com]"* ]]
  [[ "$output" == *"absent=[]"* ]]
  [[ "$output" == *"REACHED_END"* ]]
}

@test "ops#351: host_guard_matches survives errexit+pipefail" {
  run bash -c "set -euo pipefail
    source '${REPO_ROOT}/lib/server-host-guard.sh'
    snip=\"\$(host_guard_render forge.example.com)\"
    host_guard_matches \"\$snip\" forge.example.com && echo ADMITTED
    host_guard_matches \"\$snip\" stranger.example.net || echo REJECTED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ADMITTED"* ]]
  [[ "$output" == *"REJECTED"* ]]
}

################################################################################
# The gitlab.rb route. Editing /var/opt/gitlab/nginx/conf/ is CLOBBERED by
# `gitlab-ctl reconfigure`; the durable seat is gitlab.rb.
################################################################################

@test "the gitlab.rb line targets custom_gitlab_server_config, not the generated conf" {
  run host_guard_gitlab_rb_line "/etc/gitlab/nwp-host-guard.conf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"custom_gitlab_server_config"* ]]
  [[ "$output" != *"/var/opt/gitlab/nginx/conf"* ]]
}
