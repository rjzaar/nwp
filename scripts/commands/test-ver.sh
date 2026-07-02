#!/bin/bash
set -uo pipefail
################################################################################
# test-ver.sh — validate the ver deploy-tier setup on throwaway Linodes.
#
# The sibling of `pl build-server`'s tp1 rehearsal (nwp/ops#23), extended for the
# ver role (nwp/ops#29): two disposable boxes joined by a dedicated 1:1 WireGuard
# tunnel, where a **test-ver** verifier pulls a signed bundle over public HTTPS,
# minisign-verifies it, pushes it to **test-prod** ONLY over the tunnel, and prod
# re-verifies and applies. It then asserts the trust-model invariants fail-closed.
#
# IMPORTANT boundaries (do not pretend otherwise):
#   - A public cloud VM validates the DEPLOY/VERIFY MECHANICS + SOFTWARE invariants
#     only. It CANNOT reproduce ver's offline-by-default / air-gapped / hardware-
#     token (Solo 2C+) posture — that stays a human runbook step. This is `pl verify`
#     for the runbook, not a replacement for building real ver.
#   - This harness only ever touches DISPOSABLE replicas. NEVER point it at real ver.
#
# Subcommands (compose, or use `all`):
#   provision        create test-ver + test-prod Linodes (or pass --reuse IPs)
#   tunnel           bring up the 1:1 WireGuard tunnel + tunnel-only deploy sshd
#   install          install the nwp-server artifact + ledger on both boxes
#   flow             ver: pull -> verify -> push-over-WG -> prod re-verify+apply
#   assert           fail-closed invariant sweep (AI-free, ledger, tunnel-only, ...)
#   teardown         destroy both Linodes
#   all              provision -> tunnel -> install -> flow -> assert
#
# Config (no live domain in-tree — read from env/secrets like the rest of nwp):
#   NWP_GITLAB_HOST     registry host (default: reads .secrets.yml gitlab.server.domain)
#   TESTVER_MONS_IP    reuse an existing ver box instead of provisioning
#   TESTVER_PROD_IP    reuse an existing prod box
#   TESTVER_BUNDLE_URL signed bundle URL the ver box should pull (required for flow)
#   TESTVER_PKG_PROJECT registry project id/path holding the artifact+bundle
#   TESTVER_SSH_KEY    operator ssh key for orchestration (default: ~/.ssh/nwp)
#
# Exit: 0 all requested phases OK; non-zero on any provisioning/flow/assert failure.
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/linode.sh"

SSH_KEY="${TESTVER_SSH_KEY:-$HOME/.ssh/nwp}"
STATE_DIR="${TESTVER_STATE_DIR:-$PROJECT_ROOT/private/test-ver}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
WG_MONS_IP="10.99.0.1"
WG_PROD_IP="10.99.0.2"
DEPLOY_PORT="2222"

die(){ print_error "$*"; exit 1; }

# Resilient one-shot remote run (the tp1 public path can be lossy). $1=ip $2=script.
# NOTE: the script is delivered on stdin (here-string) so we must NOT use `ssh -n`.
# Scripts passed here must therefore not themselves spawn a bare `ssh`/`scp` that
# would consume the remaining stdin — such steps live in the ops#29 file scripts.
rrun(){ local ip="$1" scr="$2" n=0
  until timeout 110 ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o ServerAliveInterval=8 \
      -o ServerAliveCountMax=6 -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
      root@"$ip" "bash -s" <<<"$scr"; do
    n=$((n+1)); [ "$n" -ge 8 ] && return 1; sleep 6
  done
}

resolve_host(){ # registry host, config-driven (keeps the live domain out of git)
  local h="${NWP_GITLAB_HOST:-}"
  [ -z "$h" ] && h="$(yaml_get_secret "gitlab.server.domain" "$PROJECT_ROOT/.secrets.yml" 2>/dev/null || true)"
  [ -n "$h" ] || die "registry host unknown: set NWP_GITLAB_HOST or gitlab.server.domain"
  echo "$h"
}

ip_of(){ # $1=var-name $2=state-file
  local v="${!1:-}"; [ -n "$v" ] && { echo "$v"; return; }
  [ -f "$STATE_DIR/$2" ] && cat "$STATE_DIR/$2"
}

# ── provision ────────────────────────────────────────────────────────────────
do_provision(){
  local mip pip
  mip="$(ip_of TESTVER_MONS_IP ver.ip)"; pip="$(ip_of TESTVER_PROD_IP prod.ip)"
  [ -n "$mip" ] && [ -n "$pip" ] && { print_info "reusing ver=$mip prod=$pip"; return 0; }
  local token pub; token="$(get_linode_token "$PROJECT_ROOT")"; pub="$(cat "$SSH_KEY.pub")"
  [ -n "$token" ] || die "no linode token"
  print_header "Provisioning throwaway test-ver + test-prod (destroy after!)"
  local mid pid
  mid="$(create_linode_instance "$token" "test-ver" "$pub" "us-iad" "g6-nanode-1" "linode/ubuntu24.04")" || die "ver provision failed"
  pid="$(create_linode_instance "$token" "test-prod" "$pub" "us-iad" "g6-standard-1" "linode/ubuntu24.04")" || die "prod provision failed"
  echo "$mid" >"$STATE_DIR/ver.id"; echo "$pid" >"$STATE_DIR/prod.id"
  wait_for_linode "$token" "$mid" 300; wait_for_linode "$token" "$pid" 300
  get_linode_ip "$token" "$mid" >"$STATE_DIR/ver.ip"
  get_linode_ip "$token" "$pid" >"$STATE_DIR/prod.ip"
  print_success "provisioned ver=$(cat "$STATE_DIR/ver.ip") prod=$(cat "$STATE_DIR/prod.ip")"
}

# ── teardown ─────────────────────────────────────────────────────────────────
do_teardown(){
  local token; token="$(get_linode_token "$PROJECT_ROOT")"
  for role in ver prod; do
    local id; id="$(cat "$STATE_DIR/$role.id" 2>/dev/null || true)"
    [ -n "$id" ] || { print_info "no $role id on record"; continue; }
    curl -s --max-time 30 -X DELETE -H "Authorization: Bearer $token" \
      "https://api.linode.com/v4/linode/instances/$id" -o /dev/null \
      -w "$role ($id) delete: HTTP %{http_code}\n"
    rm -f "$STATE_DIR/$role.id" "$STATE_DIR/$role.ip"
  done
}

# ── assert (the point of the harness) ────────────────────────────────────────
do_assert(){
  local mip pip fail=0
  mip="$(ip_of TESTVER_MONS_IP ver.ip)"; pip="$(ip_of TESTVER_PROD_IP prod.ip)"
  [ -n "$mip" ] && [ -n "$pip" ] || die "no ver/prod IP (provision first)"
  print_header "Invariant sweep (fail-closed)"
  local out
  out="$(rrun "$mip" '
grep -rInE "anthropic|openai|\bclaude\b|gitlab-ci|api\.linode\.com" /opt/nwp-server >/dev/null 2>&1 && echo "AIFREE FAIL" || echo "AIFREE PASS"
[ -e /opt/nwp/pl ] && echo "NO_FULL_NWP FAIL" || echo "NO_FULL_NWP PASS"
find / -xdev -name .secrets.yml 2>/dev/null|grep -q . && echo "NO_SECRETS FAIL" || echo "NO_SECRETS PASS"
(command -v tailscale >/dev/null||[ -e /etc/headscale ]||ip link show tailscale0 >/dev/null 2>&1) && echo "NOT_ON_HEADSCALE FAIL" || echo "NOT_ON_HEADSCALE PASS"
grep -rIl "glpat-" /root /etc 2>/dev/null|grep -q . && echo "NO_PAT FAIL" || echo "NO_PAT PASS"
[ "$(wg show wg0 peers 2>/dev/null|wc -l)" = "1" ] && echo "MONS_WG_ONE_PEER PASS" || echo "MONS_WG_ONE_PEER FAIL"')"
  echo "$out" | sed "s/^/  [ver] /"
  # fail-closed: an empty/errored remote sweep is a FAILURE, not a silent pass
  { echo "$out" | grep -q "AIFREE PASS"; } || { print_error "  [ver] sweep unreachable/empty — fail-closed"; fail=1; }
  echo "$out" | grep -q FAIL && fail=1
  out="$(rrun "$pip" '
ss -ltnp 2>/dev/null | grep -q "10.99.0.2:'"$DEPLOY_PORT"'" && echo "DEPLOY_SSHD_TUNNEL_ONLY PASS" || echo "DEPLOY_SSHD_TUNNEL_ONLY FAIL"
[ "$(wg show wg0 peers 2>/dev/null|wc -l)" = "1" ] && echo "PROD_WG_ONE_PEER PASS" || echo "PROD_WG_ONE_PEER FAIL"')"
  echo "$out" | sed "s/^/  [prod] /"
  { echo "$out" | grep -q "PROD_WG_ONE_PEER"; } || { print_error "  [prod] sweep unreachable/empty — fail-closed"; fail=1; }
  echo "$out" | grep -q FAIL && fail=1
  if timeout 10 bash -c "exec 3<>/dev/tcp/$pip/$DEPLOY_PORT" 2>/dev/null; then
    echo "  [ext]  PUBLIC_DEPLOY_PORT_CLOSED FAIL"; fail=1
  else echo "  [ext]  PUBLIC_DEPLOY_PORT_CLOSED PASS"; fi
  print_warning "NOT assertable on a cloud VM: Solo 2C+ hardware gate / offline posture (human runbook)."
  [ "$fail" = 0 ] && { print_success "all invariants PASS"; return 0; } || { print_error "invariant(s) FAILED"; return 1; }
}

usage(){ sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-help}"; shift || true
case "$cmd" in
  provision) do_provision ;;
  teardown)  do_teardown ;;
  assert)    do_assert ;;
  tunnel|install|flow)
    print_warning "'$cmd' phase: see ~/central/nwc-internal/handover-assets/ops23-ver/ for the"
    print_warning "validated step scripts (nwp/ops#29). Codification into this harness is in progress."
    exit 0 ;;
  all)       do_provision && print_info "run tunnel/install/flow from the ops#29 step scripts, then: pl test-ver assert" ;;
  -h|--help|help) usage ;;
  *) die "unknown subcommand: $cmd (try --help)" ;;
esac
