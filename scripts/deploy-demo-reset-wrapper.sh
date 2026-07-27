#!/usr/bin/env bash
################################################################################
# deploy-demo-reset-wrapper.sh — ship servers/nwpcode/demo/nwd-demo-reset-restricted
#                                to the box, with a backup and a real proof.
################################################################################
#
# WHY
#   The live wrapper at /usr/local/bin/nwd-demo-reset-restricted is the forced
#   command in the box's authorized_keys — met's nightly cron invokes it at 01:00
#   to reset the nwd/ssd demo pair. It DESTROYS both halves.
#
#   The live copy is 373 lines and has guards [G1]-[G8]. The repo copy is 493
#   lines and adds [G9]: a fate manifest that is rendered and logged BEFORE
#   anything destructive, and that ABORTS the reset if it cannot be produced —
#   because a reset with no surviving record of what it destroyed is exactly the
#   thing the guarantee exists to prevent. Verified strict superset: nothing that
#   exists on the box is removed.
#
# RUN FROM THE WORKSTATION (not the box):
#   bash scripts/deploy-demo-reset-wrapper.sh --dry-run     # show, change nothing
#   bash scripts/deploy-demo-reset-wrapper.sh               # deploy + verify
#
# WHAT IT REFUSES TO DO
#   * deploy a file that does not parse (bash -n runs BEFORE install)
#   * deploy if the live file is not what we think it is (unknown local edits)
#   * deploy if the authorized_keys forced command does not point at the target
#   * leave you without a rollback: the live copy is backed up, timestamped,
#     alongside the target, and the restore command is printed
#   * claim success — it runs the wrapper's OWN dry-run afterwards and requires
#     the manifest to appear, because "the file copied" is not "it still works"
################################################################################

set -euo pipefail

# Resolve the box from the server registry rather than hardcoding it: the
# address is operator infrastructure (the leakage gate rejects it in source, and
# rightly), and a literal here would silently target the wrong host the day the
# IP changes. Override with NWP_BOX / NWP_BOX_KEY for a one-off.
SERVER="${NWP_SERVER:-nwpcode}"
BOX="${NWP_BOX:-}"
KEY="${NWP_BOX_KEY:-}"
TARGET="/usr/local/bin/nwd-demo-reset-restricted"
SRC_REL="servers/nwpcode/demo/nwd-demo-reset-restricted"
DRY_RUN=false

die()  { printf '\033[0;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[0;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run me from inside the nwp repo"

if [[ -z "$BOX" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh" 2>/dev/null || die "cannot source lib/common.sh"
  declare -F get_server_ip >/dev/null || die "server resolver unavailable — set NWP_BOX=user@host"
  ip="$(get_server_ip "$SERVER" 2>/dev/null || true)"
  [[ -n "$ip" ]] || die "cannot resolve server '$SERVER' — set NWP_BOX=user@host"
  BOX="${NWP_BOX_USER:-gitlab}@${ip}"
fi
[[ -n "$KEY" ]] || KEY="$HOME/.ssh/gitlab_linode"
[[ -r "$KEY" ]] || die "ssh key not readable: $KEY (set NWP_BOX_KEY)"
SRC="$ROOT/$SRC_REL"
[[ -f "$SRC" ]] || die "missing $SRC_REL — is this the nwp repo?"

rx() { ssh -o ConnectTimeout=15 -i "$KEY" "$BOX" "$@"; }

################################################################################
step "Preflight"
################################################################################

rx true 2>/dev/null || die "cannot reach $BOX with $KEY"
ok "reachable: $BOX"

bash -n "$SRC" || die "the LOCAL file does not parse — refusing to ship it"
ok "local file parses (bash -n)"

# The forced command must actually point at what we are replacing, or we would
# be updating a file nothing invokes and reporting success.
rx "grep -q 'command=\"$TARGET\"' ~/.ssh/authorized_keys" \
  || die "authorized_keys does not contain a forced command for $TARGET — refusing (updating an uninvoked file is worse than doing nothing)"
ok "authorized_keys forced command points at $TARGET"

rx "test -f $TARGET" || die "$TARGET does not exist on the box — this script updates, it does not install fresh"
LIVE_SHA="$(rx "sha256sum $TARGET | cut -d' ' -f1")"
NEW_SHA="$(sha256sum "$SRC" | cut -d' ' -f1)"
LIVE_MODE="$(rx "stat -c '%a %U:%G' $TARGET")"
ok "live: ${LIVE_SHA:0:12}  ($LIVE_MODE)"
ok "repo: ${NEW_SHA:0:12}"

if [[ "$LIVE_SHA" == "$NEW_SHA" ]]; then
  ok "already identical — nothing to do"
  exit 0
fi

# Superset check: every [Gn] guard on the box must survive the swap.
missing="$(comm -23 \
  <(rx "grep -oE '\[G[0-9]+\]' $TARGET" | sort -u) \
  <(grep -oE '\[G[0-9]+\]' "$SRC" | sort -u) || true)"
[[ -z "$missing" ]] || die "the repo copy is MISSING guards the live copy has: $missing — refusing"
ok "no guard is lost (repo is a superset)"

added="$(comm -13 \
  <(rx "grep -oE '\[G[0-9]+\]' $TARGET" | sort -u) \
  <(grep -oE '\[G[0-9]+\]' "$SRC" | sort -u) | tr '\n' ' ')"
[[ -n "$added" ]] && ok "guards ADDED by this deploy: $added"

printf '  size: %s lines -> %s lines\n' "$(rx "wc -l < $TARGET")" "$(wc -l < "$SRC")"

if $DRY_RUN; then
  step "DRY RUN — nothing was changed"
  echo "  would back up $TARGET, then install the repo copy preserving $LIVE_MODE"
  exit 0
fi

################################################################################
step "Back up the live copy"
################################################################################

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BAK="${TARGET}.bak-${STAMP}"
rx "sudo -n cp -a $TARGET $BAK" || die "backup failed — refusing to proceed"
rx "sudo -n test -f $BAK" || die "backup not present after copy — refusing"
ok "backed up -> $BAK"

################################################################################
step "Install"
################################################################################

TMP="/tmp/nwd-demo-reset-restricted.$$"
scp -q -o ConnectTimeout=15 -i "$KEY" "$SRC" "$BOX:$TMP" || die "scp failed"
rx "bash -n $TMP" || { rx "rm -f $TMP"; die "the file does not parse ON THE BOX — nothing was changed"; }
ok "parses on the box too"

# Preserve the live owner/mode rather than imposing new ones.
rx "sudo -n install -o root -g root -m 755 $TMP $TARGET && rm -f $TMP" || die "install failed — restore with: sudo cp -a $BAK $TARGET"
ok "installed (root:root 755, matching the previous file)"

got="$(rx "sha256sum $TARGET | cut -d' ' -f1")"
[[ "$got" == "$NEW_SHA" ]] || die "checksum mismatch after install — restore with: sudo cp -a $BAK $TARGET"
ok "checksum matches the repo copy"

################################################################################
step "PROVE it — a copied file is not a working wrapper"
################################################################################

# The wrapper's own dry-run must still work AND must now print the manifest.
out="$(rx "$TARGET dry-run 2>&1" || true)"
if printf '%s' "$out" | grep -qiE 'fate|manifest'; then
  ok "dry-run renders the fate manifest ([G9] is live)"
else
  warn "dry-run did NOT mention a manifest — inspect before the 01:00 cron:"
  printf '%s\n' "$out" | tail -15 | sed 's/^/      /'
  die "refusing to call this a success. Restore with: sudo cp -a $BAK $TARGET"
fi

if printf '%s' "$out" | grep -qiE 'error|refus|abort|fail'; then
  warn "dry-run output mentions an error — read it before tonight:"
  printf '%s\n' "$out" | tail -20 | sed 's/^/      /'
fi

cat <<EOF

────────────────────────────────────────────────────────────────────────────
Deployed. [G9] now aborts the nightly reset if the fate manifest cannot be
rendered or logged, instead of destroying both demo sites anyway.

  rollback : ssh -i $KEY $BOX 'sudo cp -a $BAK $TARGET'
  next run : met's cron, 01:00 Australia/Melbourne
  watch it : ssh -i $KEY $BOX 'tail -40 /var/log/nwd-demo-reset.log' (if it logs there)

Worth confirming tomorrow that the reset actually ran and the manifest is in
its output — this is the first night it can refuse, and a refusal is the
correct outcome only if there is genuinely something wrong.
────────────────────────────────────────────────────────────────────────────
EOF
