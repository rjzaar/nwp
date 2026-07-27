#!/usr/bin/env bash
################################################################################
# install-mini-runner.sh — install a second GitLab CI runner on `mini`
################################################################################
#
# WHY THIS EXISTS
#   `met` (Carlo) carries the entire CI queue alone. During the 2026-07-26
#   consolidation arc it backed up to 36 pending jobs, and MR !197's pipeline sat
#   with all 13 jobs pending and NO runner available at all — so that work was
#   never gated by CI. Meanwhile `mini` sits at load 0.02 on 32 cores.
#
#   A task recorded "Register fallback GitLab CI runner on mini" as COMPLETE.
#   Verified 2026-07-27: mini has no gitlab-runner binary, no systemd unit, no
#   container and no config.toml. It was never done. This script does it, and —
#   more importantly — PROVES it afterwards rather than asserting it.
#
# RUN THIS ON MINI, AS AN OPERATOR WITH sudo:
#   ssh rob@100.64.0.2                      # tailnet; the `mini` ssh alias
#                                           # points at a dead LAN address
#   git -C ~/nwp pull
#   sudo ~/nwp/scripts/install-mini-runner.sh --token <RUNNER_AUTH_TOKEN>
#
# GETTING THE TOKEN (GitLab 16+ uses runner *authentication* tokens, not the old
# shared registration token):
#   https://git.nwpcode.org/nwp/nwp/-/settings/ci_cd  →  Runners  →  New project runner
#     Tags:                nwp            ← REQUIRED. Every job in .gitlab-ci.yml
#                                            carries `tags: [nwp]`; an untagged
#                                            runner will sit idle and you will
#                                            think it is broken.
#     Run untagged jobs:   NO
#     Executor (next step): shell
#   Copy the `glrt-…` token it shows you once.
#
# DESIGN NOTES
#   * Executor is **shell**, matching met. The CI config depends on it —
#     .gitlab-ci.yml:170 and :281 explicitly note "shell executor, no Docker
#     image", and lint:leakage installs gitleaks onto the host because of it.
#     A docker executor here would fail those jobs in confusing ways.
#   * `concurrent` is deliberately conservative (4). mini also runs the NWP
#     Console and the agent-loop; CI is a guest, not the tenant.
#   * Idempotent: re-running detects an existing registration and refuses rather
#     than creating a duplicate runner.
#   * The token is never echoed, never written to a world-readable file, and is
#     passed to `gitlab-runner register` via env, not argv (argv is visible in
#     /proc/<pid>/cmdline to every user on the box).
################################################################################

set -euo pipefail

GITLAB_URL="https://git.nwpcode.org"
RUNNER_TAGS="nwp"
RUNNER_NAME="$(hostname)-nwp"
EXECUTOR="shell"
CONCURRENT=4
TOKEN=""
DRY_RUN=false

die()  { printf '\033[0;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[0;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

usage() {
  sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)   TOKEN="${2:-}"; shift 2 ;;
    --token=*) TOKEN="${1#*=}"; shift ;;
    --url)     GITLAB_URL="${2:-}"; shift 2 ;;
    --tags)    RUNNER_TAGS="${2:-}"; shift 2 ;;
    --name)    RUNNER_NAME="${2:-}"; shift 2 ;;
    --concurrent) CONCURRENT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) die "unknown option: $1  (try --help)" ;;
  esac
done

################################################################################
step "Preflight"
################################################################################

[[ $EUID -eq 0 ]] || die "must run as root (sudo $0 ...)"

# Refuse to run anywhere but mini — this script hardcodes mini-specific
# reasoning (concurrency budget, coexistence with the console + agent-loop).
host="$(hostname)"
if [[ "$host" != "mini" ]]; then
  die "this script is for 'mini'; this host is '$host'. For another host, review the design notes first."
fi
ok "host is mini"

command -v curl >/dev/null || die "curl not found"
curl -fsS --max-time 15 -o /dev/null "$GITLAB_URL/-/health" 2>/dev/null \
  || curl -fsS --max-time 15 -o /dev/null "$GITLAB_URL/" \
  || die "cannot reach $GITLAB_URL — check the mesh before continuing"
ok "reachable: $GITLAB_URL"

# Fail closed on a missing token, and never accept one via a file we then leave
# lying around.
[[ -n "$TOKEN" ]] || die "--token is required (see the header for where to get it)"
[[ "$TOKEN" == glrt-* ]] || warn "token does not start with 'glrt-' — GitLab 16+ issues glrt- authentication tokens. Continuing, but check you did not paste a registration token."

if [[ -f /etc/gitlab-runner/config.toml ]] && grep -q '\[\[runners\]\]' /etc/gitlab-runner/config.toml 2>/dev/null; then
  die "a runner is already registered on this host (/etc/gitlab-runner/config.toml).
       Refusing to create a duplicate. To re-register:  gitlab-runner unregister --all-runners"
fi
ok "no existing runner registration"

if $DRY_RUN; then
  step "DRY RUN — would install gitlab-runner, register '$RUNNER_NAME' (tags: $RUNNER_TAGS, executor: $EXECUTOR, concurrent: $CONCURRENT)"
  exit 0
fi

################################################################################
step "Install gitlab-runner"
################################################################################

if command -v gitlab-runner >/dev/null; then
  ok "already installed: $(gitlab-runner --version | head -1)"
else
  curl -fsSL --max-time 60 "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | bash
  apt-get install -y gitlab-runner
  ok "installed: $(gitlab-runner --version | head -1)"
fi

################################################################################
step "Register"
################################################################################

# Token via env, NOT argv: argv is world-readable in /proc/<pid>/cmdline.
CI_SERVER_TOKEN="$TOKEN" gitlab-runner register \
  --non-interactive \
  --url "$GITLAB_URL" \
  --name "$RUNNER_NAME" \
  --executor "$EXECUTOR" \
  --tag-list "$RUNNER_TAGS" \
  --run-untagged=false \
  --locked=false
unset TOKEN CI_SERVER_TOKEN
ok "registered as '$RUNNER_NAME' (tags: $RUNNER_TAGS, executor: $EXECUTOR)"

sed -i "s/^concurrent = .*/concurrent = $CONCURRENT/" /etc/gitlab-runner/config.toml
grep -q "^concurrent = $CONCURRENT" /etc/gitlab-runner/config.toml \
  || die "failed to set concurrent = $CONCURRENT — check /etc/gitlab-runner/config.toml by hand"
ok "concurrent = $CONCURRENT"

chmod 600 /etc/gitlab-runner/config.toml
ok "config.toml is 0600 (it holds the runner token)"

################################################################################
step "Start"
################################################################################

systemctl enable --now gitlab-runner
sleep 3
systemctl is-active --quiet gitlab-runner || die "service did not start — journalctl -u gitlab-runner"
ok "gitlab-runner active"

################################################################################
step "PROVE it — a green service is not a working runner"
################################################################################

# The failure this guards against is real: a runner can be installed, running,
# and registered, yet never pick up a job because its tags do not match. Every
# job in .gitlab-ci.yml carries `tags: [nwp]`.
if gitlab-runner verify --delete 2>&1 | grep -qi "is alive\|Verifying runner"; then
  ok "runner verifies against $GITLAB_URL"
else
  warn "gitlab-runner verify did not clearly confirm — check manually"
fi

printf '\n'
printf '  registered tags : %s\n' "$(grep -m1 -oP '(?<=tags = \[).*(?=\])' /etc/gitlab-runner/config.toml 2>/dev/null || echo '?')"
printf '  executor        : %s\n' "$(grep -m1 -oP '(?<=executor = ").*(?=")' /etc/gitlab-runner/config.toml 2>/dev/null || echo '?')"
printf '  concurrent      : %s\n' "$(grep -m1 -oP '(?<=^concurrent = ).*' /etc/gitlab-runner/config.toml 2>/dev/null || echo '?')"

cat <<'EOF'

────────────────────────────────────────────────────────────────────────────
NOT DONE UNTIL A JOB ACTUALLY RUNS HERE.

  1. https://git.nwpcode.org/nwp/nwp/-/settings/ci_cd → Runners
     The new runner should show ONLINE with the `nwp` tag.

  2. Push any branch, or re-run a pipeline, then confirm a job landed here:
        sudo journalctl -u gitlab-runner -n 40 --no-pager | grep -i "job succeeded\|checkout"

  3. Sanity-check that met still gets its share — both should be online:
        both runners visible and picking up work = the queue is genuinely split.

If the runner is ONLINE but never takes a job, the cause is almost always the
tag list. Every job in .gitlab-ci.yml carries `tags: [nwp]`, and a runner with
"run untagged jobs" disabled and no matching tag will idle forever while
looking perfectly healthy.
────────────────────────────────────────────────────────────────────────────
EOF
