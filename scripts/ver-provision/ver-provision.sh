#!/bin/bash
set -euo pipefail
################################################################################
# ver-provision.sh — one-shot, idempotent provisioning the OPERATOR runs ON `ver`
# (the offline signed-deploy verifier + DR-backup custodian; ops#25, ADR-0025).
#
# Ships inside the signed ver-kit (see prepare-ver-kit.sh). Self-contained: no
# nwp checkout, no repo libs, no network. Fail-closed throughout: nothing is
# installed until its minisign signature verifies against the pinned public key.
#
# Subcommands (run in order, or `all`):
#   verify        verify the kit: manifest signature + sha256 of every file +
#                 per-tool minisign signatures
#   install       install verified tools → /usr/local/bin (with .minisig kept
#                 alongside, so runtime re-verification keeps working); create
#                 /etc/nwp-server layout; install the pinned minisign pubkey
#   issue-keys    generate ver's one-way credentials (private keys NEVER leave
#                 this box); print the public halves + where to register them
#   check         credential-ledger assertion (smoke test #4 in ver-setup.md):
#                 expected keys present, 0600, and NO PAT-shaped token anywhere
#   all           verify → install → issue-keys → check
#
# Options:
#   --kit DIR     kit directory (default: the directory this script's parent kit
#                 root, i.e. ../ relative to scripts/)
#   --with-publish-key   also generate the write-only sanitized-publish key.
#                 OFF by default: the `publish` verb has a known open defect
#                 (mis-wired to the build-tier uploader — nwp/ops#23) and `ver`
#                 itself does not publish; issue this key only for a prod-agent
#                 host once the defect is fixed.
#
# Credential ledger this provisions on `ver` (ADR-0024/0025/0026):
#   1. bundle-pull  (read-only)   pull signed bundles from the artifact host
#   2. restic-pull  (read-only)   drain prod's local restic repo over the 1:1
#                                 WireGuard tunnel (forced-command, sftp -R)
#   3. nwp-minisign.pub           verify bundle + tool signatures
#   (+ optionally, the least-privilege post-only verifier-say token — the
#    documented ops-queue reporting exception; never a PAT.)
################################################################################

SELF_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KIT_DIR="$( cd "$SELF_DIR/.." && pwd )"
# NWP_VER_* overrides exist for sandboxed testing only — never set them on a real ver.
ETC="${NWP_VER_ETC:-/etc/nwp-server}"
KEYS="$ETC/keys"
PUB="$ETC/nwp-minisign.pub"
BIN="${NWP_VER_BIN:-/usr/local/bin}"
SHARE="${NWP_VER_SHARE:-/usr/local/share/nwp-ver}"
WITH_PUBLISH=n

c_ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; }
c_warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
c_err(){  printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
c_head(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die(){ c_err "$*"; exit 1; }

usage(){ sed -n '3,/^####*$/{/^####*$/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

CMD="${1:-}"; [ $# -gt 0 ] && shift
case "$CMD" in verify|install|issue-keys|check|all) ;; -h|--help|"") usage ;; *) die "unknown subcommand: $CMD (try --help)";; esac
while [ $# -gt 0 ]; do
  case "$1" in
    --kit=*) KIT_DIR="${1#*=}" ;;
    --kit)   KIT_DIR="$2"; shift ;;
    --with-publish-key) WITH_PUBLISH=y ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

need_root(){ [ "$(id -u)" = 0 ] || [ -n "${NWP_VER_ETC:-}" ] || die "this step needs root — rerun with sudo"; }

kit_pub(){ # the pinned public key: prefer the already-installed copy over the kit's
  if [ -f "$PUB" ]; then echo "$PUB"; else echo "$KIT_DIR/nwp-minisign.pub"; fi
}

do_verify(){
  c_head "Verify kit ($KIT_DIR)"
  command -v minisign >/dev/null || die "minisign not installed — bootstrap first: sudo apt-get install -y minisign (distro-signed)"
  local pub; pub="$(kit_pub)"
  [ -f "$pub" ] || die "pinned public key not found: $pub"
  [ -f "$KIT_DIR/KIT.sha256" ] || die "KIT.sha256 not found — is --kit pointing at the kit root?"
  minisign -V -q -p "$pub" -m "$KIT_DIR/KIT.sha256" || die "KIT.sha256 signature FAILED — do not proceed; re-transfer the kit"
  c_ok "manifest signature verified"
  ( cd "$KIT_DIR" && sha256sum --quiet -c KIT.sha256 ) || die "kit sha256 manifest check FAILED"
  c_ok "all files match the signed manifest"
  local f
  for f in "$KIT_DIR"/tools/* "$KIT_DIR"/scripts/*; do
    case "$f" in *.minisig) continue ;; esac
    minisign -V -q -p "$pub" -m "$f" || die "signature FAILED: $f"
  done
  c_ok "per-file signatures verified (tools + scripts)"
}

do_install(){
  c_head "Install tools + layout"
  need_root
  local f base
  for f in "$KIT_DIR"/tools/*; do
    case "$f" in *.minisig) continue ;; esac
    base="$(basename "$f")"
    if [ -x "$BIN/$base" ] && cmp -s "$f" "$BIN/$base"; then
      c_ok "$base already installed (identical)"
    else
      install -m 755 "$f" "$BIN/$base"
      c_ok "installed $BIN/$base"
    fi
    # keep the signature alongside so runtime checks (server-backup/ver-pull
    # --restic-pub) can re-verify the binary before every use
    install -m 644 "$f.minisig" "$BIN/$base.minisig"
  done
  install -d -m 700 "$ETC" "$KEYS" "$ETC/keystore"
  if [ ! -f "$PUB" ]; then
    install -m 644 "$KIT_DIR/nwp-minisign.pub" "$PUB"
    c_ok "pinned public key → $PUB"
  else
    cmp -s "$KIT_DIR/nwp-minisign.pub" "$PUB" || c_warn "$PUB differs from the kit copy — keeping the EXISTING pin (replace manually only if you rotated the key)"
  fi
  install -d -m 755 "$SHARE"
  local s
  for s in "$KIT_DIR"/scripts/*.sh; do
    install -m 755 "$s" "$SHARE/$(basename "$s")"
  done
  c_ok "ver scripts → $SHARE/"
}

gen_key(){ # gen_key <name> <comment> — idempotent ed25519 keypair under $KEYS
  local name="$1" comment="$2"
  if [ -f "$KEYS/${name}_ed25519" ]; then
    c_ok "$name key exists (leaving it alone)"
  else
    ssh-keygen -q -t ed25519 -N "" -C "$comment" -f "$KEYS/${name}_ed25519"
    chmod 600 "$KEYS/${name}_ed25519"
    c_ok "generated $name key"
  fi
}

do_issue_keys(){
  c_head "Issue ver's one-way credentials (private halves never leave this box)"
  need_root
  install -d -m 700 "$KEYS"
  gen_key bundle-pull "ver-bundle-pull-$(date -I)"
  gen_key restic-pull "ver-restic-pull-$(date -I)"
  [ "$WITH_PUBLISH" = y ] && gen_key sanitized-publish "prod-sanitized-publish-$(date -I)"

  c_head "Register the PUBLIC halves (operator, from a browser — not from this box)"
  echo
  echo "1. bundle-pull → the artifact host (<gitlab-host>): add as a project"
  echo "   DEPLOY KEY on the signed-bundle project, READ-ONLY (no write access):"
  echo
  sed 's/^/     /' "$KEYS/bundle-pull_ed25519.pub"
  echo
  echo "2. restic-pull → EACH prod host you back up: append to the backup user's"
  echo "   ~/.ssh/authorized_keys USING THE FORCED-COMMAND TEMPLATE"
  echo "   (templates/ver-restic-authorized-keys.tmpl — read-only sftp, chrooted"
  echo "   to the restic repo path, tunnel address only):"
  echo
  sed 's/^/     /' "$KEYS/restic-pull_ed25519.pub"
  echo
  if [ "$WITH_PUBLISH" = y ]; then
    echo "3. sanitized-publish → deploy key with WRITE access on the sanitized-"
    echo "   artifact project ONLY (write-only-to-its-own-repo; ADR-0024 ledger):"
    echo
    sed 's/^/     /' "$KEYS/sanitized-publish_ed25519.pub"
    echo
  else
    echo "3. sanitized-publish key NOT generated (default). ver does not publish;"
    echo "   the nwp-server publish verb has an open defect (nwp/ops#23). Use"
    echo "   --with-publish-key on a prod-agent host once that is fixed."
  fi
}

do_check(){
  c_head "Credential-ledger check (expected: pull keys + pinned pubkey, nothing else)"
  local fail=0 f perm
  for f in "$KEYS/bundle-pull_ed25519" "$KEYS/restic-pull_ed25519"; do
    if [ -f "$f" ]; then
      perm="$(stat -c '%a' "$f")"
      if [ "$perm" = 600 ]; then c_ok "$(basename "$f") present, 0600"; else c_err "$(basename "$f") perms $perm (want 600)"; fail=1; fi
    else
      c_warn "$(basename "$f") missing (run issue-keys)"
    fi
  done
  [ -f "$PUB" ] && c_ok "pinned minisign pubkey present" || { c_err "pinned pubkey missing: $PUB"; fail=1; }

  # No PAT-shaped or api-scope token may exist on this host (the ADR-0024
  # linchpin, applied to ver). glpat-/glrt-/glsoat- are GitLab token prefixes.
  local hits
  hits="$(grep -rlE 'gl(pat|rt|soat)-[A-Za-z0-9_-]{10,}' "$ETC" /root/.config /root/.ssh /home/*/.config /home/*/.ssh 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    c_err "PAT-shaped token found — the ledger forbids PATs on this host:"
    echo "$hits" | sed 's/^/       /'
    fail=1
  else
    c_ok "no PAT-shaped tokens found"
  fi

  # Unexpected extra private keys under $KEYS?
  while IFS= read -r f; do
    case "$(basename "$f")" in
      bundle-pull_ed25519|restic-pull_ed25519|sanitized-publish_ed25519) ;;
      *) c_warn "unexpected key in ledger dir: $f (the ledger is exactly the one-way set)"; ;;
    esac
  done < <(find "$KEYS" -type f ! -name '*.pub' 2>/dev/null)

  # keystore state (sealed restic password — ver-seal-keystore.sh)
  if compgen -G "$ETC/keystore/*.age" >/dev/null; then
    c_ok "sealed keystore entries: $(ls "$ETC"/keystore/*.age 2>/dev/null | wc -l)"
  else
    c_warn "no sealed keystore entries yet (run ver-seal-keystore.sh init + seal)"
  fi

  [ "$fail" = 0 ] && { echo; c_ok "LEDGER CHECK PASSED"; } || { echo; die "LEDGER CHECK FAILED"; }
}

case "$CMD" in
  verify)     do_verify ;;
  install)    do_verify; do_install ;;
  issue-keys) do_issue_keys ;;
  check)      do_check ;;
  all)        do_verify; do_install; do_issue_keys; do_check ;;
esac
