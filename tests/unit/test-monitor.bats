#!/usr/bin/env bats
# scripts/commands/monitor.sh — the `pl monitor` uptime + mail launch gate
# (PHASED-BUILD-PLAN P13 / nwp/ops#71: registration launch is gated on PROVEN
# mail deliverability).
#
# Everything here runs on throwaway fixtures with NO network: dig / curl /
# openssl are shadowed by mock scripts on PATH, so the checks are exercised
# deterministically. The --send-test path is asserted to be opt-in (it never
# reaches a real send in these tests).

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}"
  MON="${BATS_TEST_DIRNAME}/../../scripts/commands/monitor.sh"

  # A fixture fleet: two real-looking live domains + one placeholder that must
  # be ignored, plus a non-live site with no domain.
  cat > "${PROJECT_ROOT}/nwp.yml" <<'EOF'
sites:
  nwc:
    live:
      enabled: true
      domain: nwc.nwpcode.org
      server_ip: 203.0.113.10
  avc:
    live:
      enabled: true
      domain: avc.nwpcode.org
      server_ip: 203.0.113.10
  placeholder:
    live:
      domain: mysite.example.com
  local_only:
    recipe: d
EOF

  # ── Mock bin dir shadowing dig / curl / openssl / ping ──────────────────────
  export MOCKBIN="${TEST_TMP}/bin"
  mkdir -p "$MOCKBIN"

  # curl: always report a healthy 200 for https targets.
  cat > "$MOCKBIN/curl" <<'EOF'
#!/bin/bash
# emulate `-w '%{http_code}'` output only
echo -n "200"
EOF

  # openssl: table-driven so the TLS column can be exercised for the three
  # states it must tell apart — matching cert, WRONG-HOST cert, and no
  # handshake at all. TLS_MODE selects; default = a healthy matching cert.
  #
  # The s_client mock echoes a marker line carrying the name it will claim, and
  # the x509 mock reads that marker back off stdin — so the "which cert did the
  # handshake actually return" question is answerable in the mock exactly as it
  # is against a real server.
  cat > "$MOCKBIN/openssl" <<'EOF'
#!/bin/bash
mode="${TLS_MODE:-match}"
case "$1" in
  s_client)
    cat >/dev/null 2>&1 || true
    # Which host was asked for (-servername)?
    asked=""; prev=""
    for a in "$@"; do [ "$prev" = "-servername" ] && asked="$a"; prev="$a"; done
    case "$mode" in
      # No handshake: real openssl prints nothing usable on stdout.
      unreachable) exit 1 ;;
      # The incident shape: the box has no vhost for the asked-for name, so
      # TLS falls through to another site's certificate.
      mismatch)    served="borrowed.example.com" ;;
      *)           served="$asked" ;;
    esac
    echo "-----BEGIN CERTIFICATE-----"
    echo "NWPMOCK-SERVED:${served}"
    echo "-----END CERTIFICATE-----"
    ;;
  x509)
    served=""
    while IFS= read -r line; do
      case "$line" in NWPMOCK-SERVED:*) served="${line#NWPMOCK-SERVED:}" ;; esac
    done
    [ -n "$served" ] || exit 1
    for a in "$@"; do
      case "$a" in
        -enddate) echo "notAfter=$(date -u -d '+90 days' '+%b %d %H:%M:%S %Y GMT')" ;;
        -subject) echo "subject=CN = ${served}" ;;
        -ext)     echo "X509v3 Subject Alternative Name:"; echo "    DNS:${served}" ;;
      esac
    done
    ;;
  *) exit 0 ;;
esac
EOF

  # ping: pretend nothing is on the tailnet (met/mini unreachable).
  cat > "$MOCKBIN/ping" <<'EOF'
#!/bin/bash
exit 1
EOF

  # dig: table-driven mock. Default = healthy records; override per-test by
  # setting DIG_MODE in the environment.
  cat > "$MOCKBIN/dig" <<'EOF'
#!/bin/bash
mode="${DIG_MODE:-healthy}"
args="$*"
# reverse lookup: `dig -x <ip> +short`
if [[ "$args" == *"-x "* ]]; then
  [[ "$mode" == "no_ptr" ]] && exit 0
  echo "mail.nwpcode.org."
  exit 0
fi
# TXT / MX / A queries
qtype=""; name=""
for a in "$@"; do
  case "$a" in
    TXT|MX|A) qtype="$a" ;;
    +short) : ;;
    -*) : ;;
    *) name="$a" ;;
  esac
done
case "$qtype:$name" in
  TXT:*_dmarc.*)      [[ "$mode" == "no_dmarc" ]] && exit 0; echo '"v=DMARC1; p=none; rua=mailto:x@y"' ;;
  TXT:*_domainkey.*)  echo '"v=DKIM1; k=rsa; p=MIIBI"' ;;
  TXT:*)              [[ "$mode" == "no_spf" ]] && exit 0; echo '"v=spf1 include:_spf.nwpcode.org -all"' ;;
  MX:*)               echo "10 mail.nwpcode.org." ;;
  A:*)                echo "203.0.113.10" ;;
  *)                  exit 0 ;;
esac
EOF

  chmod +x "$MOCKBIN"/*
  export PATH="$MOCKBIN:$PATH"
}

teardown() { rm -rf "${TEST_TMP}"; }

# ── dispatch / help ──────────────────────────────────────────────────────────

@test "pl monitor --help prints usage and exits 0" {
  run bash "$MON" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"pl monitor uptime"* ]]
  [[ "$output" == *"pl monitor mail <site>"* ]]
}

@test "no args prints help (exit 0)" {
  run bash "$MON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uptime"* ]]
}

@test "an unknown subcommand is refused (non-zero)" {
  run bash "$MON" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown monitor command"* ]]
}

# ── uptime: iterates configured hosts ────────────────────────────────────────

@test "uptime iterates configured domains, distinct server_ips, git host + tailnet" {
  # git host + tailnet are runtime-derived; feed them via the env overrides so
  # no operator infra needs to be hardcoded.
  NWP_MONITOR_GIT_HOST=git.example.org NWP_MONITOR_TAILNET="buildbox" \
    run bash "$MON" uptime
  [ "$status" -eq 0 ]
  [[ "$output" == *"nwc"* ]]
  [[ "$output" == *"nwc.nwpcode.org"* ]]
  [[ "$output" == *"avc.nwpcode.org"* ]]
  # distinct live server_ip probed once (both fixture sites share 203.0.113.10)
  [[ "$output" == *"203.0.113.10"* ]]
  # git origin host, derived from the env override
  [[ "$output" == *"git.example.org"* ]]
  # placeholder example.com domain must be skipped
  [[ "$output" != *"mysite.example.com"* ]]
}

@test "uptime reports nothing to do when no targets are configured" {
  echo 'sites: {}' > "${PROJECT_ROOT}/nwp.yml"
  run bash "$MON" uptime
  [ "$status" -eq 0 ]
  [[ "$output" == *"No monitor targets"* ]]
}

@test "uptime reports HTTP status and TLS days for a healthy host" {
  run bash "$MON" uptime
  [ "$status" -eq 0 ]
  [[ "$output" == *"200"* ]]
  [[ "$output" =~ [0-9]+d ]]   # TLS days-to-expiry rendered (e.g. 89d/90d)
  [[ "$output" == *"green"* ]]
}

@test "uptime rejects an unsupported tier" {
  run bash "$MON" uptime --tier=prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsupported tier"* ]]
}

@test "uptime returns non-zero (3) when a host is RED (curl down)" {
  cat > "$MOCKBIN/curl" <<'EOF'
#!/bin/bash
echo -n "000"
EOF
  chmod +x "$MOCKBIN/curl"
  run bash "$MON" uptime
  [ "$status" -eq 3 ]
  [[ "$output" == *"red"* ]]
}

# ── mail: SPF / DKIM / DMARC / PTR / MX via mocked dig ───────────────────────

@test "mail passes when all records are present" {
  run bash "$MON" mail nwc
  [ "$status" -eq 0 ]
  [[ "$output" == *"SPF: present"* ]]
  [[ "$output" == *"DKIM: selector"* ]]
  [[ "$output" == *"DMARC: present"* ]]
  [[ "$output" == *"PTR: 203.0.113.10"* ]]
  [[ "$output" == *"MX: mail.nwpcode.org"* ]]
  [[ "$output" == *"all checks passed"* ]]
}

@test "mail FAILS (non-zero) with the specific missing record when SPF absent" {
  DIG_MODE=no_spf run bash "$MON" mail nwc
  [ "$status" -ne 0 ]
  [[ "$output" == *"SPF: MISSING"* ]]
  [[ "$output" == *"NOT launch-ready"* ]]
}

@test "mail FAILS (non-zero) when the server_ip has no PTR" {
  DIG_MODE=no_ptr run bash "$MON" mail nwc
  [ "$status" -ne 0 ]
  [[ "$output" == *"PTR"* ]]
  [[ "$output" == *"NO reverse DNS"* ]]
}

@test "mail WARNs (still exit 0) when DMARC is absent" {
  DIG_MODE=no_dmarc run bash "$MON" mail nwc
  [ "$status" -eq 0 ]
  [[ "$output" == *"DMARC: MISSING"* ]]
}

@test "mail refuses a site with no configured live domain" {
  run bash "$MON" mail local_only
  [ "$status" -ne 0 ]
  [[ "$output" == *"No live domain configured"* ]]
}

@test "mail requires a site name" {
  run bash "$MON" mail
  [ "$status" -ne 0 ]
  [[ "$output" == *"Site name required"* ]]
}

# ── --send-test is opt-in: never sends without --execute ─────────────────────

@test "mail --send-test WITHOUT --execute does not send (opt-in)" {
  run bash "$MON" mail nwc --send-test test@example.org
  [[ "$output" == *"send-test is opt-in"* ]]
  [[ "$output" == *"add --execute"* ]]
  # it must NOT have invoked the drush send path
  [[ "$output" != *"Sending one probe"* ]]
}

@test "default mail run never mentions sending anything" {
  run bash "$MON" mail nwc
  [[ "$output" != *"Sending one probe"* ]]
  [[ "$output" != *"send-test"* ]]
}

# ── TLS: the column must be capable of going RED (nwp/ops#359, 2026-08-13)
#
# `_tls_days_left` reported the expiry of WHATEVER certificate the handshake
# returned and never checked it matched the host asked for. Throughout the
# 2026-08-13 outage the fleet dashboard showed a green `82d` for a site that was
# serving no usable TLS at all: its vhost had been renamed away during a box
# split, so TLS fell through to the first 443 block on the box and the column
# was measuring a DIFFERENT site's certificate. Two more sites on that box
# served the same borrowed cert for twelve days. A TLS column that cannot go red
# for a wrong-domain certificate is the CLAUDE.md "check that has never been
# proven to fail".

@test "TLS: a wrong-host certificate grades RED and names the cert actually served" {
  TLS_MODE=mismatch run bash "$MON" uptime
  [ "$status" -eq 3 ]
  [[ "$output" == *"MISMATCH"* ]]
  [[ "$output" == *"borrowed.example.com"* ]]
  [[ "$output" == *"red"* ]]
}

@test "TLS: a wrong-host certificate never renders as days-remaining" {
  # The precise false green: the borrowed cert's 90 days displayed as health.
  TLS_MODE=mismatch run bash "$MON" uptime
  [[ ! "$output" =~ [0-9]+d[[:space:]] ]]
}

@test "TLS: a failed handshake is CANNOT VERIFY, never green" {
  TLS_MODE=unreachable run bash "$MON" uptime
  [[ "$output" == *"CANNOT VERIFY"* ]]
  # Blindness must not be indistinguishable from health: a row whose TLS
  # reading was never taken may not be graded green.
  [[ "$output" != *"0 amber"* ]]
  [[ "$output" == *"amber"* ]]
}

@test "TLS: a matching certificate still reports days remaining and stays green" {
  TLS_MODE=match run bash "$MON" uptime
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]+d ]]
  [[ "$output" != *"MISMATCH"* ]]
  [[ "$output" == *"green"* ]]
}
