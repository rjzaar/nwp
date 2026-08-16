#!/bin/bash
set -euo pipefail
################################################################################
# ver-test.sh — pl-driven ver DR test harness on throwaway Linodes
# (ops#25 provisioning + ops#127 two-tier retention, composed end-to-end).
#
# Provisions a disposable **test-ver** (offline-custodian stand-in) and, from it,
# a disposable **test-prod** (minimal Drupal fixture), then runs the FULL DR
# chain for real:
#
#   prod: server-backup (RAW)  +  server-backup --sanitize (preserve-admin,
#         fail-closed PII gate)          → local staging restic repos
#   ver:  ver-pull-session (generated pull-sources.conf, raw|…|raw +
#         sanitized|…|sanitized)         → raw gets the --keep-within 30d
#         erasure ceiling, sanitised keeps the tiered policy
#   ver:  restic check both repos + a restore drill (sanitised restore must
#         PASS the independent PII gate; a RAW restore must FAIL it)
#
# The same `pl` commands are the dress rehearsal for the real ver build: the
# real run swaps the harness deltas (below) for the hardware pieces.
#
# HARNESS DELTAS vs the real ver (documented, deliberate):
#   1. transport  — plain ssh with a dedicated ephemeral ed25519 key generated ON
#      test-ver (real ver: dedicated 1:1 WireGuard tunnel; prod sshd binds the
#      tunnel interface only, forced-command chrooted sftp backup user).
#   2. keystore   — a plaintext-file shim with the same CLI as
#      ver-seal-keystore.sh (real ver: age-plugin-fido2-hmac sealed to a Solo
#      token; unseal = physical touch + PIN).
#   3. signing    — an ephemeral harness minisign keypair signs the restic
#      binaries (real ver: the pinned NWP minisign key via the signed ver-kit).
#   4. prod ssh user — root (real: forced-command, chrooted, read-mostly backup
#      user; see templates/ver-restic-authorized-keys.tmpl).
#
# NEVER point this at real ver/prod hosts. It only creates fresh Linodes tagged
# `arc-disposable` + `ver-harness`, records every id in the disposable ledger
# (docs/reports/consolidation-arc-2026-07/DISPOSABLE-LINODE.md) the moment it is
# created, and `teardown` destroys them and verifies they are gone (fail-closed).
#
# Subcommands:
#   provision        create test-ver, install restic/minisign + the nwp-server
#                    artifact + the REAL ver-pull-session.sh (+ keystore shim)
#   provision-prod   create test-prod, install the Drupal fixture (uid1 admin
#                    with a real-domain email + planted fake members), the
#                    artifact, and the ver→prod ssh path
#   cycle            run the full DR chain + print a PASS/FAIL scorecard
#   teardown         DELETE both Linodes via API, verify gone, update the ledger
#                    (prints a fate manifest naming every instance first — -y
#                     skips the prompt, never the report)
#   status           show recorded state + live instances tagged ver-harness
#
# Options / env:
#   -y | --yes         skip the teardown confirmation PROMPT. It never skips
#                      the fate manifest (ops#47): teardown always prints, and
#                      the ledger always records, exactly which instances it
#                      destroyed.
#   --state-dir DIR    (or VERTEST_STATE_DIR)  default: private/ver-test-harness
#   --region R         (or VERTEST_REGION)     default: us-iad-2
#   --type T           (or VERTEST_TYPE)       default: g6-standard-2
#   VERTEST_SSH_KEY    operator orchestration key (default: ~/.ssh/nwp)
#   NWP_VERTEST_LINODE_TOKEN  token override (tests); else .secrets.yml
#                             linode.provision_token via get_infra_secret
#
# Exit: 0 = requested phase fully OK; non-zero on any failure (fail-closed).
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/impact.sh"   # ops#47 impact contract (fate manifest)

API="https://api.linode.com/v4"
STATE_DIR="${VERTEST_STATE_DIR:-$PROJECT_ROOT/private/ver-test-harness}"
LEDGER="${VERTEST_LEDGER:-$PROJECT_ROOT/docs/reports/consolidation-arc-2026-07/DISPOSABLE-LINODE.md}"
SSH_KEY="${VERTEST_SSH_KEY:-$HOME/.ssh/nwp}"
REGION="${VERTEST_REGION:-us-iad-2}"
TYPE="${VERTEST_TYPE:-g6-standard-2}"
IMAGE="${VERTEST_IMAGE:-linode/ubuntu24.04}"
LABEL_PREFIX="nwp-vertest"
TAGS_JSON='["arc-disposable","ver-harness"]'
ASSUME_YES="${VERTEST_ASSUME_YES:-false}"   # -y: skips the PROMPT, not the report

# Fixture identity (the PII-gate semantics depend on these):
#   - admin uses a REAL-DOMAIN address (NOT on the pii-gate allowlist) so
#     --preserve-admin + the admin-allow sidecar are genuinely exercised;
#   - members use another real-looking domain so a RAW dump must FAIL the gate.
SITE="drupalfx"
SITE_DIR="/var/www/drupalfx"
ADMIN_MAIL="admin@vertest-harness.org"
MEMBER_DOMAIN="harness-member.net"
MEMBERS=5

LOGS="$STATE_DIR/logs"
# Dedicated known_hosts: cloud IPs get recycled (the #120 box's IP came straight
# back on the first harness run), and a stale global entry + accept-new = refusal.
SSH_OPTS=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$STATE_DIR/known_hosts"
          -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=12
          -o BatchMode=yes)

die(){ print_error "$*"; exit 1; }
usage(){ sed -n '3,/^####*$/{/^####*$/d;p}' "$0" | sed 's/^# \{0,1\}//'; }

# ── Linode API (token only ever inside a 0600 curl config; never argv/ps) ─────
CURLCFG_TEXT=""   # set by require_token (ops#374: config text, never a file)
require_token(){
  type get_infra_secret >/dev/null 2>&1 || die "lib/common.sh not loaded — cannot read secrets (fail-closed)"
  local token="${NWP_VERTEST_LINODE_TOKEN:-}"
  [ -n "$token" ] || token="$(get_infra_secret "linode.provision_token" "")"
  [ -n "$token" ] || die "no linode.provision_token in .secrets.yml — refusing (fail-closed; see pl secrets status)"
  mkdir -p "$STATE_DIR" "$LOGS"
  # ops#374: this used to be written to $STATE_DIR/api.curlcfg — a LONG-LIVED
  # 0600 credential file that outlived every run. The config is now held in
  # memory and fed to curl on STDIN, so it never touches disk. See lib/http.sh.
  CURLCFG_TEXT="$(printf 'header = "Authorization: Bearer %s"\n' "$token")"
  token=""
}

api(){ # $1=METHOD $2=/path [$3=json-body] → body on stdout
  local method="$1" path="$2" body="${3:-}"
  local args=(-K - -s --max-time 60 -X "$method"
              -H "Content-Type: application/json" "$API$path")
  [ -n "$body" ] && args+=(-d "$body")
  printf '%s\n' "$CURLCFG_TEXT" | curl "${args[@]}"
}
api_code(){ # $1=METHOD $2=/path → http status code only
  printf '%s\n' "$CURLCFG_TEXT" | curl -K - -s --max-time 60 -o /dev/null -w '%{http_code}' -X "$1" "$API$2"
}

# ── disposable-ledger bookkeeping (record BEFORE anything else can fail) ──────
record_created(){ # $1=role $2=id $3=ip $4=label
  local role="$1" id="$2" ip="$3" label="$4"
  mkdir -p "$STATE_DIR"
  echo "$id" > "$STATE_DIR/$role.id"
  echo "$ip" > "$STATE_DIR/$role.ip"
  echo "$label" > "$STATE_DIR/$role.label"
  {
    echo ""
    echo "## [ver-harness] $label — ACTIVE until torn down"
    echo "- **id:** $id  ·  **ip:** $ip  ·  role: test-$role  ·  region $REGION  ·  $TYPE  ·  tags arc-disposable,ver-harness"
    echo "- **Created:** $(date -u +%Y-%m-%dT%H:%MZ) by \`pl ver-test\` (task #11 / ops#25+#127)"
    echo "- Teardown: \`pl ver-test teardown\`  (or: \`curl -X DELETE .../linode/instances/$id\` with the provision token)"
  } >> "$LEDGER"
  print_status "OK" "recorded $role id $id in $(basename "$LEDGER")"
}
record_torndown(){ # $1=role $2=id $3=delete_code $4=verify_code
  {
    echo "- **TORN DOWN** $(date -u +%Y-%m-%dT%H:%MZ): test-$1 id $2 — DELETE HTTP $3, verify GET now HTTP $4 ✓"
  } >> "$LEDGER"
}

state_of(){ cat "$STATE_DIR/$1" 2>/dev/null || true; }

# ── remote execution (script is scp'd then run: no stdin games, retryable) ────
hrun(){ # $1=ip $2=step-name $3=script $4=timeout(s, default 600) → rc
  local ip="$1" name="$2" script="$3" tmo="${4:-600}" tmpf rc n=0
  tmpf="$(mktemp)"; printf '%s\n' "$script" > "$tmpf"
  until ssh "${SSH_OPTS[@]}" "root@$ip" "mkdir -p /root/.nwp-harness && cat > /root/.nwp-harness/$name.sh" < "$tmpf"; do
    n=$((n+1)); [ "$n" -ge 5 ] && { rm -f "$tmpf"; print_error "[$name] could not deliver step to $ip"; return 1; }
    sleep 5
  done
  rm -f "$tmpf"
  mkdir -p "$LOGS"
  set +e
  timeout "$tmo" ssh "${SSH_OPTS[@]}" "root@$ip" "bash /root/.nwp-harness/$name.sh" 2>&1 | tee "$LOGS/$name.log"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}
hpush(){ # $1=ip $2=local $3=remote
  scp -q "${SSH_OPTS[@]}" "$2" "root@$1:$3"
}

wait_ssh(){ # $1=ip
  local ip="$1" waited=0
  print_info "waiting for ssh on $ip (cloud-init can take a few minutes)…"
  until ssh "${SSH_OPTS[@]}" "root@$ip" true 2>/dev/null; do
    sleep 6; waited=$((waited+6))
    [ "$waited" -ge 420 ] && return 1
  done
  print_status "OK" "ssh up on $ip (${waited}s)"
}

# ── instance lifecycle ────────────────────────────────────────────────────────
create_instance(){ # $1=role → records state; echoes nothing
  local role="$1" label ts pub root_pass payload resp id status ip waited
  ts="$(date +%Y%m%d-%H%M%S)"
  label="$LABEL_PREFIX-$role-$ts"
  [ -f "$SSH_KEY.pub" ] || die "ssh pubkey not found: $SSH_KEY.pub"
  pub="$(cat "$SSH_KEY.pub")"
  root_pass="$(openssl rand -base64 32 | tr -d '/=+' | cut -c-24)"
  payload="$(jq -n --arg label "$label" --arg region "$REGION" --arg type "$TYPE" \
                  --arg image "$IMAGE" --arg pass "$root_pass" --arg key "$pub" \
                  --argjson tags "$TAGS_JSON" \
      '{label:$label, region:$region, type:$type, image:$image, root_pass:$pass,
        authorized_keys:[$key], booted:true, backups_enabled:false,
        private_ip:false, tags:$tags}')"
  print_header "Provisioning test-$role ($TYPE in $REGION) — DISPOSABLE"
  resp="$(api POST /linode/instances "$payload")"
  id="$(jq -r '.id // empty' <<<"$resp")"
  if [ -z "$id" ]; then
    jq -r '.errors[]?.reason // empty' <<<"$resp" | sed 's/^/  ✗ /' >&2
    die "instance create FAILED for test-$role"
  fi
  # Record in the ledger IMMEDIATELY — before anything else can fail/orphan it.
  ip="$(api GET "/linode/instances/$id" | jq -r '.ipv4[0] // empty')"
  record_created "$role" "$id" "$ip" "$label"
  # a FRESH instance means any known host key for this (recycled) IP is stale
  [ -f "$STATE_DIR/known_hosts" ] && ssh-keygen -R "$ip" -f "$STATE_DIR/known_hosts" >/dev/null 2>&1 || true
  waited=0
  until [ "$(api GET "/linode/instances/$id" | jq -r '.status // empty')" = "running" ]; do
    sleep 6; waited=$((waited+6))
    [ "$waited" -ge 420 ] && die "test-$role ($id) did not reach 'running' in ${waited}s"
  done
  print_status "OK" "test-$role running: id $id  ip $ip"
  wait_ssh "$ip" || die "ssh never came up on test-$role ($ip) — instance is RECORDED in the ledger; tear down"
}

reuse_or_create(){ # $1=role → 0 if usable instance present (state+ssh), else creates
  local role="$1" ip
  ip="$(state_of "$role.ip")"
  if [ -n "$ip" ] && ssh "${SSH_OPTS[@]}" "root@$ip" true 2>/dev/null; then
    print_info "reusing recorded test-$role at $ip (id $(state_of "$role.id"))"
    return 0
  fi
  [ -n "$ip" ] && print_warning "recorded test-$role ($ip) unreachable — provisioning a fresh one"
  create_instance "$role"
}

# ── harness minisign key (delta #3: ephemeral, NOT the pinned NWP key) ────────
ensure_harness_minisign(){
  command -v minisign >/dev/null || die "minisign not installed on this workstation"
  if [ ! -f "$STATE_DIR/harness-minisign.key" ]; then
    ( umask 077
      minisign -G -f -W -s "$STATE_DIR/harness-minisign.key" -p "$STATE_DIR/harness-minisign.pub" \
        -c "nwp ver-test harness key (ephemeral, disposable)" >/dev/null )
    print_status "OK" "generated ephemeral harness minisign keypair"
  fi
}

sign_remote_restic(){ # $1=ip — pull the host's restic, sign, push .minisig back
  local ip="$1" tmpd
  tmpd="$(mktemp -d)"
  scp -q "${SSH_OPTS[@]}" "root@$ip:/usr/bin/restic" "$tmpd/restic"
  minisign -S -s "$STATE_DIR/harness-minisign.key" -m "$tmpd/restic" >/dev/null
  hpush "$ip" "$tmpd/restic.minisig" /usr/bin/restic.minisig
  rm -rf "$tmpd"
  print_status "OK" "restic on $ip minisign-signed (harness key)"
}

build_and_push_artifact(){ # $1=ip — assemble nwp-server + install to /opt/nwp-server
  local ip="$1"
  print_info "building nwp-server artifact (fail-closed deny-scan)…"
  bash "$PROJECT_ROOT/scripts/build-nwp-server.sh" --out "$STATE_DIR/artifact" >/dev/null \
    || die "nwp-server artifact build failed"
  tar -C "$STATE_DIR/artifact" -czf - . \
    | ssh "${SSH_OPTS[@]}" "root@$ip" "rm -rf /opt/nwp-server && mkdir -p /opt/nwp-server && tar -xzf - -C /opt/nwp-server" \
    || die "artifact push to $ip failed"
  print_status "OK" "nwp-server artifact → $ip:/opt/nwp-server"
}

# ── keystore shim (delta #2: same CLI as ver-seal-keystore.sh, no FIDO2) ──────
KEYSTORE_SHIM='#!/bin/bash
set -euo pipefail
################################################################################
# HARNESS SHIM — ver-seal-keystore.sh CLI, WITHOUT the FIDO2 hardware seal.
# Real ver seals restic passwords to a Solo token (age-plugin-fido2-hmac; unseal
# = physical touch + PIN). A throwaway cloud box has no token, so this shim keeps
# entries as 0600 plaintext at $ETC/keystore/NAME.plain and honours the exact
# contract ver-pull-session.sh uses: unseal NAME --out PATH / lock [NAME] / list.
# NEVER install this on a real ver.
################################################################################
ETC="${NWP_VER_ETC:-/etc/nwp-server}"; KS="$ETC/keystore"; RUN="${NWP_VER_RUN:-/run/nwp-server}"
die(){ echo "keystore-shim: $*" >&2; exit 1; }
cmd="${1:-}"; shift || true
case "$cmd" in
  seal)
    name="${1:?seal NAME}"; shift || true
    mode=""
    while [ $# -gt 0 ]; do case "$1" in --generate) mode=generate;; --from-stdin) mode=stdin;; esac; shift; done
    [ -n "$mode" ] || die "seal needs --generate or --from-stdin"
    mkdir -p "$KS"; umask 077
    case "$mode" in
      generate) head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n" > "$KS/$name.plain" ;;
      stdin)    cat > "$KS/$name.plain"; [ -s "$KS/$name.plain" ] || die "empty secret" ;;
    esac
    echo "  [shim] sealed(plain) → $KS/$name.plain" ;;
  unseal)
    name="${1:?unseal NAME}"; shift || true
    out="$RUN/$name"
    while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift;; --out=*) out="${1#--out=}";; esac; shift; done
    [ -f "$KS/$name.plain" ] || die "no keystore entry: $KS/$name.plain"
    mkdir -p "$(dirname "$out")"; chmod 700 "$(dirname "$out")" 2>/dev/null || true
    install -m 600 "$KS/$name.plain" "$out"
    echo "  [shim] unsealed → $out (no touch: HARNESS ONLY)" ;;
  lock)
    name="${1:-}"
    if [ -n "$name" ]; then rm -f "$RUN/$name"; else rm -f "$RUN"/* 2>/dev/null || true; fi
    echo "  [shim] locked" ;;
  list) ls -1 "$KS" 2>/dev/null || true ;;
  *) die "unknown subcommand: $cmd (seal|unseal|lock|list)" ;;
esac'

# ══════════════════════════════════════════════════════════════════════════════
# provision — test-ver
# ══════════════════════════════════════════════════════════════════════════════
do_provision(){
  require_token
  reuse_or_create ver
  local vip; vip="$(state_of ver.ip)"

  hrun "$vip" ver-base '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq restic minisign jq >/dev/null
install -d -m 700 /etc/nwp-server /etc/nwp-server/keystore /run/nwp-server
install -d -m 755 /srv/ver-backups /usr/local/share/nwp-ver
restic version
' 600 || die "test-ver base install failed"

  build_and_push_artifact "$vip"
  ensure_harness_minisign
  hpush "$vip" "$STATE_DIR/harness-minisign.pub" /etc/nwp-server/nwp-minisign.pub
  sign_remote_restic "$vip"

  # the REAL session script under test + the keystore shim beside it
  hpush "$vip" "$PROJECT_ROOT/scripts/ver-provision/ver-pull-session.sh" /usr/local/share/nwp-ver/ver-pull-session.sh
  local shimf; shimf="$(mktemp)"; printf '%s\n' "$KEYSTORE_SHIM" > "$shimf"
  hpush "$vip" "$shimf" /usr/local/share/nwp-ver/ver-seal-keystore.sh
  rm -f "$shimf"
  hrun "$vip" ver-scripts '
set -euo pipefail
chmod 755 /usr/local/share/nwp-ver/ver-pull-session.sh /usr/local/share/nwp-ver/ver-seal-keystore.sh
# ver-repo: the durable-repo password, generated ON ver, never leaves it
[ -f /etc/nwp-server/keystore/ver-repo.plain ] || /usr/local/share/nwp-ver/ver-seal-keystore.sh seal ver-repo --generate
' 120 || die "test-ver script install failed"

  print_success "test-ver ready at $vip (id $(state_of ver.id)) — next: pl ver-test provision-prod"
}

# ══════════════════════════════════════════════════════════════════════════════
# provision-prod — test-prod (from/for test-ver)
# ══════════════════════════════════════════════════════════════════════════════
do_provision_prod(){
  require_token
  local vip; vip="$(state_of ver.ip)"
  [ -n "$vip" ] || die "no test-ver on record — run: pl ver-test provision first"
  reuse_or_create prod
  local pip; pip="$(state_of prod.ip)"

  hrun "$pip" prod-base '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq restic minisign mariadb-server mariadb-client \
  composer php-cli php-mysql php-gd php-xml php-mbstring php-curl php-zip php-intl \
  unzip git jq >/dev/null
systemctl enable --now mariadb >/dev/null 2>&1 || true
install -d -m 700 /etc/nwp-server
install -d -m 755 /var/backups/nwp-server
umask 077
[ -f /root/.harness-db.pass ] || head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n" > /root/.harness-db.pass
[ -f /etc/nwp-server/restic.pass ] || head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n" > /etc/nwp-server/restic.pass
chmod 600 /etc/nwp-server/restic.pass
DBPASS="$(cat /root/.harness-db.pass)"
mysql <<SQL
CREATE DATABASE IF NOT EXISTS drupal CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '"'"'drupal'"'"'@'"'"'localhost'"'"' IDENTIFIED BY '"'"'${DBPASS}'"'"';
ALTER USER '"'"'drupal'"'"'@'"'"'localhost'"'"' IDENTIFIED BY '"'"'${DBPASS}'"'"';
GRANT ALL PRIVILEGES ON drupal.* TO '"'"'drupal'"'"'@'"'"'localhost'"'"';
GRANT ALL PRIVILEGES ON \`drupal_sanitize_scratch\`.* TO '"'"'drupal'"'"'@'"'"'localhost'"'"';
FLUSH PRIVILEGES;
SQL
echo "base + mariadb ready"
' 900 || die "test-prod base install failed"

  # minimal Drupal fixture (#120 approach): composer drupal + drush site:install,
  # uid1 admin on a real domain, planted fake members on another real domain.
  hrun "$pip" prod-drupal "
set -euo pipefail
export COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1
if [ ! -x $SITE_DIR/vendor/bin/drush ]; then
  mkdir -p /var/www
  [ -d $SITE_DIR ] || composer create-project drupal/recommended-project $SITE_DIR --no-progress --quiet
  cd $SITE_DIR && composer require drush/drush --no-progress --quiet
fi
cd $SITE_DIR
DBPASS=\"\$(cat /root/.harness-db.pass)\"
if ! vendor/bin/drush status --field=bootstrap 2>/dev/null | grep -q Successful; then
  vendor/bin/drush site:install standard -y \
    --db-url=\"mysql://drupal:\${DBPASS}@localhost/drupal\" \
    --site-name='ver-harness fixture' \
    --account-name=admin --account-mail='$ADMIN_MAIL' \
    --account-pass=\"\$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')\" >/dev/null
fi
for i in \$(seq 1 $MEMBERS); do
  vendor/bin/drush user:create \"member\$i\" --mail=\"member\$i@$MEMBER_DOMAIN\" \
    --password=\"\$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')\" >/dev/null 2>&1 || true
done
echo '--- fixture state ---'
vendor/bin/drush sql:query \"SELECT uid,name,mail FROM users_field_data WHERE uid>0 ORDER BY uid;\"
" 1500 || die "Drupal fixture install failed on test-prod"

  build_and_push_artifact "$pip"
  hpush "$pip" "$STATE_DIR/harness-minisign.pub" /etc/nwp-server/nwp-minisign.pub
  sign_remote_restic "$pip"

  # ver→prod path (delta #1/#4): dedicated ephemeral key generated ON test-ver;
  # plain ssh to root@test-prod stands in for the 1:1 WireGuard tunnel + chrooted
  # forced-command backup user of the real deployment.
  local verpub
  verpub="$(hrun "$vip" ver-key '
set -euo pipefail
[ -f /root/.ssh/vertest-prod ] || ssh-keygen -q -t ed25519 -N "" -C "harness-ver-to-prod" -f /root/.ssh/vertest-prod
cat /root/.ssh/vertest-prod.pub
' 60 | tail -1)"
  [ -n "$verpub" ] || die "could not obtain ver→prod pubkey from test-ver"
  hrun "$pip" prod-authorize "
set -euo pipefail
mkdir -p /root/.ssh && chmod 700 /root/.ssh
grep -qF 'harness-ver-to-prod' /root/.ssh/authorized_keys 2>/dev/null || echo '$verpub' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
echo authorized
" 60 || die "authorizing ver→prod key on test-prod failed"
  hrun "$vip" ver-sshcfg "
set -euo pipefail
mkdir -p /root/.ssh && chmod 700 /root/.ssh
cat > /root/.ssh/config <<CFG
Host vertest-prod
  HostName $pip
  User root
  IdentityFile /root/.ssh/vertest-prod
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ConnectTimeout 10
CFG
chmod 600 /root/.ssh/config
ssh vertest-prod true && echo 'ver → prod ssh OK'
# seed prod's staging-repo password into ver's keystore, pulled OVER the ver→prod
# path (never through the workstation): both staging repos share restic.pass.
ssh vertest-prod cat /etc/nwp-server/restic.pass | /usr/local/share/nwp-ver/ver-seal-keystore.sh seal $SITE.from --from-stdin
ssh vertest-prod cat /etc/nwp-server/restic.pass | /usr/local/share/nwp-ver/ver-seal-keystore.sh seal $SITE-sanitized.from --from-stdin
/usr/local/share/nwp-ver/ver-seal-keystore.sh list
" 120 || die "ver→prod ssh path setup failed"

  print_success "test-prod ready at $pip (id $(state_of prod.id)) — next: pl ver-test cycle"
}

# ══════════════════════════════════════════════════════════════════════════════
# cycle — the full DR chain + scorecard
# ══════════════════════════════════════════════════════════════════════════════
SCORE=(); SCORE_FAIL=0
sc(){ # $1=0|nonzero $2=name $3=desc
  if [ "$1" = 0 ]; then SCORE+=("PASS  $2 — $3")
  else SCORE+=("FAIL  $2 — $3"); SCORE_FAIL=$((SCORE_FAIL+1)); fi
}
sc_grep(){ # $1=pattern $2=file $3=name $4=desc  (errexit-safe grep assert)
  local rc=0; grep -q -- "$1" "$2" 2>/dev/null || rc=1
  sc "$rc" "$3" "$4"
}

do_cycle(){
  local vip pip rc
  vip="$(state_of ver.ip)"; pip="$(state_of prod.ip)"
  [ -n "$vip" ] && [ -n "$pip" ] || die "need both test-ver and test-prod on record (run provision + provision-prod)"
  mkdir -p "$LOGS"
  print_header "ver-test cycle — full DR chain (prod=$pip → ver=$vip)"

  # 1 · RAW staging backup on prod (db + files → <site> repo)
  rc=0; hrun "$pip" cycle-raw-backup "
set -euo pipefail
/opt/nwp-server/scripts/commands/server-backup.sh --site-dir $SITE_DIR \
  --restic-pub /etc/nwp-server/nwp-minisign.pub --execute
" 900 || rc=$?
  sc "$rc" "raw-backup" "prod: RAW restic snapshot (db+files) → /var/backups/nwp-server/$SITE"

  # 2 · SANITISED staging backup on prod (preserve-admin, PII gate w/ sidecar)
  rc=0; hrun "$pip" cycle-san-backup "
set -euo pipefail
/opt/nwp-server/scripts/commands/server-backup.sh --site-dir $SITE_DIR --sanitize \
  --sanitizer /opt/nwp-server/lib/sanitizers/standard.sh \
  --restic-pub /etc/nwp-server/nwp-minisign.pub --execute
" 900 || rc=$?
  sc "$rc" "sanitized-backup" "prod: sanitise (preserve-admin) + fail-closed PII gate → $SITE-sanitized repo"
  sc_grep "sanitised + PII-gate clean" "$LOGS/cycle-san-backup.log" \
    "prod-pii-gate" "prod: independent PII gate PASSED on the sanitised dump (admin sidecar)"

  # 3 · generate pull-sources.conf on ver (raw + sanitized data classes)
  rc=0; hrun "$vip" cycle-conf "
set -euo pipefail
cat > /etc/nwp-server/pull-sources.conf <<CONF
# generated by pl ver-test cycle $(date -u +%Y-%m-%dT%H:%MZ)
$SITE|sftp:vertest-prod:/var/backups/nwp-server/$SITE|/srv/ver-backups/$SITE|raw
$SITE-sanitized|sftp:vertest-prod:/var/backups/nwp-server/$SITE-sanitized|/srv/ver-backups/$SITE-sanitized|sanitized
CONF
chmod 600 /etc/nwp-server/pull-sources.conf
bash /usr/local/share/nwp-ver/ver-pull-session.sh --check
" 120 || rc=$?
  sc "$rc" "session-preflight" "ver: pull-sources.conf --check (data classes validate fail-closed)"

  # 4 · the pull session itself (REAL ver-pull-session.sh, --execute)
  rc=0; hrun "$vip" cycle-session '
set -euo pipefail
bash /usr/local/share/nwp-ver/ver-pull-session.sh --execute
' 900 || rc=$?
  sc "$rc" "pull-session" "ver: ver-pull-session --execute drained both sources"
  sc_grep "session complete: 2 source(s) drained" "$LOGS/cycle-session.log" \
    "session-both-sources" "ver: session reports 2/2 sources drained"
  sc_grep "keep-within 30d" "$LOGS/cycle-session.log" \
    "raw-keep-within" "ver: RAW repo pruned with --keep-within 30d (ops#127 erasure ceiling)"
  sc_grep "Retention (d:7 w:8 m:12)" "$LOGS/cycle-session.log" \
    "sanitized-tiered" "ver: sanitised repo kept the tiered daily/weekly/monthly policy"

  # 5 · integrity + restore drill + gate assertions on ver
  rc=0; hrun "$vip" cycle-drill "
set -euo pipefail
KS=/usr/local/share/nwp-ver/ver-seal-keystore.sh
\$KS unseal ver-repo --out /run/nwp-server/ver-repo >/dev/null
trap '\$KS lock >/dev/null 2>&1 || true' EXIT
R_RAW=(restic -r /srv/ver-backups/$SITE --password-file /run/nwp-server/ver-repo)
R_SAN=(restic -r /srv/ver-backups/$SITE-sanitized --password-file /run/nwp-server/ver-repo)

echo '== restic check (raw repo) =='
\"\${R_RAW[@]}\" check --read-data && echo CHECK_RAW_OK
echo '== restic check (sanitized repo) =='
\"\${R_SAN[@]}\" check --read-data && echo CHECK_SAN_OK

echo '== snapshot inventory =='
nraw=\$(\"\${R_RAW[@]}\" snapshots --json | jq length)
nsan=\$(\"\${R_SAN[@]}\" snapshots --json | jq length)
echo \"SNAPSHOTS raw=\$nraw sanitized=\$nsan\"
[ \"\$nraw\" -ge 1 ] && [ \"\$nsan\" -ge 1 ] && echo SNAPSHOTS_PRESENT_OK

echo '== restore drill (sanitised → scratch) =='
rm -rf /root/drill && mkdir -p /root/drill/san /root/drill/raw
\"\${R_SAN[@]}\" restore latest --tag db --target /root/drill/san >/dev/null
sandump=\$(find /root/drill/san -name 'db.sql.gz' | head -1)
[ -n \"\$sandump\" ] && echo RESTORE_SAN_OK

source /opt/nwp-server/lib/pii-gate.sh
umask 077
printf '%s\n' '$ADMIN_MAIL' > /etc/nwp-server/harness-admin.allow

grc=0; pii_gate_scan \"\$sandump\" /etc/nwp-server/harness-admin.allow || grc=\$?
echo \"GATE_SANITIZED_WITH_ALLOW rc=\$grc\"

grc2=0; pii_gate_scan \"\$sandump\" >/dev/null 2>&1 || grc2=\$?
echo \"GATE_SANITIZED_NO_ALLOW rc=\$grc2\"

echo '== restore drill (RAW → scratch; gate MUST fail) =='
\"\${R_RAW[@]}\" restore latest --tag db --target /root/drill/raw >/dev/null
rawdump=\$(find /root/drill/raw -name 'db.sql.gz' | head -1)
[ -n \"\$rawdump\" ] && echo RESTORE_RAW_OK
grc3=0; pii_gate_scan \"\$rawdump\" /etc/nwp-server/harness-admin.allow >/dev/null 2>&1 || grc3=\$?
echo \"GATE_RAW rc=\$grc3\"
rm -rf /root/drill
" 900 || rc=$?
  local dlog="$LOGS/cycle-drill.log"
  sc_grep "CHECK_RAW_OK" "$dlog"          "restic-check-raw" "ver: restic check --read-data PASSED on the raw repo"
  sc_grep "CHECK_SAN_OK" "$dlog"          "restic-check-sanitized" "ver: restic check --read-data PASSED on the sanitised repo"
  sc_grep "SNAPSHOTS_PRESENT_OK" "$dlog"  "snapshots-present" "ver: both durable repos hold >=1 snapshot"
  sc_grep "RESTORE_SAN_OK" "$dlog"        "restore-sanitized" "ver: sanitised db snapshot restored to scratch"
  sc_grep "GATE_SANITIZED_WITH_ALLOW rc=0" "$dlog" \
    "gate-sanitized-pass" "ver: PII gate PASSES on restored sanitised dump (admin allowlisted)"
  sc_grep "GATE_SANITIZED_NO_ALLOW rc=1" "$dlog" \
    "gate-needs-allowlist" "ver: without the admin allowlist the gate FAILS → admin really preserved (real domain)"
  sc_grep "RESTORE_RAW_OK" "$dlog"        "restore-raw" "ver: raw db snapshot restored to scratch"
  sc_grep "GATE_RAW rc=1" "$dlog" \
    "gate-raw-fails" "ver: PII gate FAILS (rc=1) on the RAW dump — planted member@$MEMBER_DOMAIN detected"

  # ── scorecard ───────────────────────────────────────────────────────────────
  print_header "ver-test cycle scorecard"
  local line
  for line in "${SCORE[@]}"; do
    case "$line" in
      PASS*) printf '  \033[32m✓ %s\033[0m\n' "$line" ;;
      *)     printf '  \033[31m✗ %s\033[0m\n' "$line" ;;
    esac
  done
  echo
  local total=${#SCORE[@]}
  if [ "$SCORE_FAIL" = 0 ]; then
    print_success "CYCLE PASS — $total/$total checks green (logs: $LOGS/cycle-*.log)"
  else
    die "CYCLE FAIL — $SCORE_FAIL/$total checks failed (logs: $LOGS/cycle-*.log)"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# teardown — destroy BOTH, verify gone, ledger the result (fail-closed)
# ══════════════════════════════════════════════════════════════════════════════
do_teardown(){
  require_token
  local fail=0 role id code vcode tries

  # ── FATE MANIFEST (nwp/ops#47 impact contract) ─────────────────────────────
  # Disposable-by-design is a reason the answer is usually "yes"; it is not a
  # reason to skip the question. A DELETE here destroys the instance AND its
  # disks (the harness runs backups_enabled:false), so name every instance —
  # id, label, type/region, ip and its LIVE status from the API — before any
  # of them is touched. -y skips the prompt, never the report.
  local -a doomed=()
  for role in prod ver; do
    id="$(state_of "$role.id")"
    if [ -n "$id" ]; then doomed+=("$role"); else print_info "no test-$role on record"; fi
  done
  if [ "${#doomed[@]}" -eq 0 ]; then
    print_info "no harness instances on record — nothing to tear down"
    return 0
  fi

  impact_reset
  local info label status ip type region
  for role in "${doomed[@]}"; do
    id="$(state_of "$role.id")"
    info="$(api GET "/linode/instances/$id" 2>/dev/null)" || info=""
    label="$(jq -r '.label  // empty' <<<"$info" 2>/dev/null || true)"
    status="$(jq -r '.status // empty' <<<"$info" 2>/dev/null || true)"
    ip="$(jq -r '.ipv4[0]   // empty' <<<"$info" 2>/dev/null || true)"
    type="$(jq -r '.type    // empty' <<<"$info" 2>/dev/null || true)"
    region="$(jq -r '.region// empty' <<<"$info" 2>/dev/null || true)"
    [ -n "$label" ] || label="$(state_of "$role.label")"
    [ -n "$ip" ]    || ip="$(state_of "$role.ip")"
    impact_delete "test-$role" \
      "Linode id ${id} — ${label:-<unlabelled>} (${type:-$TYPE} in ${region:-$REGION}, ip ${ip:-unknown}, status ${status:-UNKNOWN — API could not see it}): instance and all its disks DESTROYED, no snapshot or backup exists"
    [ -n "$status" ] || impact_warn "the API did not return a status for id ${id} — it may already be gone, or the token cannot see it; teardown verifies with GET→404 either way"
  done

  # Orphans: anything tagged ver-harness that this state dir did NOT record is
  # NOT ours to destroy — say so loudly rather than leaving it billing quietly.
  local tagged untracked
  tagged="$(api GET "/linode/instances" | jq -r '[.data[]? | select(.tags | index("ver-harness")) | .id] | join(" ")' 2>/dev/null || true)"
  untracked=""
  for id in $tagged; do
    local mine=false r
    for r in "${doomed[@]}"; do [ "$(state_of "$r.id")" = "$id" ] && mine=true; done
    [ "$mine" = false ] && untracked="${untracked}${untracked:+ }$id"
  done
  [ -n "$untracked" ] && impact_warn "instance(s) tagged ver-harness that are NOT on record here: ${untracked} — teardown will not destroy them; check 'pl ver-test status'"

  impact_keep "The disposable ledger ($(basename "$LEDGER")) — a TORN DOWN line is appended; nothing is rewritten or removed"
  impact_keep "Local harness state and logs under $STATE_DIR (ids, keys, cycle logs) — kept for the run report"
  impact_keep "Every other Linode on the account — teardown only ever acts on ids it recorded itself"
  impact_render

  impact_confirm standard "destroy ${#doomed[@]} disposable harness Linode(s)" "$ASSUME_YES" \
    || { print_info "Teardown cancelled — instances left running (they keep billing)."; return 1; }

  for role in "${doomed[@]}"; do
    id="$(state_of "$role.id")"
    print_header "Tearing down test-$role (id $id)"
    code="$(api_code DELETE "/linode/instances/$id")"
    if [ "$code" != 200 ]; then
      print_error "DELETE /linode/instances/$id → HTTP $code (expected 200)"
      # already gone is acceptable — verify below decides
      [ "$code" != 404 ] && fail=1
    fi
    # verify it is REALLY gone (fail-closed: nothing may keep billing)
    vcode=""; tries=0
    while [ "$tries" -lt 10 ]; do
      vcode="$(api_code GET "/linode/instances/$id")"
      [ "$vcode" = 404 ] && break
      sleep 3; tries=$((tries+1))
    done
    if [ "$vcode" = 404 ]; then
      print_status "OK" "test-$role ($id) confirmed GONE (GET → 404)"
      record_torndown "$role" "$id" "$code" "$vcode"
      rm -f "$STATE_DIR/$role.id" "$STATE_DIR/$role.ip" "$STATE_DIR/$role.label"
    else
      print_error "test-$role ($id) still answers HTTP $vcode — NOT torn down; ledger entry stays ACTIVE"
      fail=1
    fi
  done
  # residual sweep: nothing tagged ver-harness may remain on the account
  local left
  left="$(api GET "/linode/instances" | jq -r '[.data[]? | select(.tags | index("ver-harness"))] | length')"
  if [ "$left" = 0 ]; then
    print_status "OK" "no instances tagged ver-harness remain on the account"
  else
    print_error "$left instance(s) tagged ver-harness still exist — check: pl ver-test status"
    fail=1
  fi
  [ "$fail" = 0 ] && print_success "teardown complete — both Linodes destroyed and verified gone" \
                  || die "teardown INCOMPLETE — fix manually (ids in $(basename "$LEDGER"))"
}

do_status(){
  print_header "ver-test harness state ($STATE_DIR)"
  local role
  for role in ver prod; do
    if [ -n "$(state_of "$role.id")" ]; then
      print_info "test-$role: id $(state_of "$role.id")  ip $(state_of "$role.ip")  ($(state_of "$role.label"))"
    else
      print_info "test-$role: (none on record)"
    fi
  done
  require_token
  print_header "Live instances tagged ver-harness (API)"
  api GET "/linode/instances" \
    | jq -r '.data[]? | select(.tags | index("ver-harness")) | "  \(.id)  \(.label)  \(.status)  \(.ipv4[0])"' \
    || true
}

# ── dispatch ──────────────────────────────────────────────────────────────────
main(){
  local cmd="${1:-}"; [ $# -gt 0 ] && shift
  # options after the subcommand
  while [ $# -gt 0 ]; do
    case "$1" in
      --state-dir=*) STATE_DIR="${1#*=}"; LOGS="$STATE_DIR/logs" ;;
      --state-dir)   STATE_DIR="$2"; LOGS="$STATE_DIR/logs"; shift ;;
      --region=*)    REGION="${1#*=}" ;;
      --region)      REGION="$2"; shift ;;
      --type=*)      TYPE="${1#*=}" ;;
      --type)        TYPE="$2"; shift ;;
      -y|--yes)      ASSUME_YES=true ;;
      -h|--help)     usage; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done
  case "$cmd" in
    provision)      do_provision ;;
    provision-prod) do_provision_prod ;;
    cycle)          do_cycle ;;
    teardown)       do_teardown ;;
    status)         do_status ;;
    -h|--help)      usage ;;
    "")             usage; exit 1 ;;
    *)              die "unknown subcommand: $cmd (provision|provision-prod|cycle|teardown|status)" ;;
  esac
}

# Sourced by tests (bats) to exercise helpers without dispatching.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
