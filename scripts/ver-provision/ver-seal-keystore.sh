#!/bin/bash
set -euo pipefail
################################################################################
# ver-seal-keystore.sh — seal/unseal `ver`'s restic secrets with a FIDO2 token
# (Solo 2-class) via age-plugin-fido2-hmac (ADR-0025; ops#25).
#
# The restic repo passwords on `ver` are SEALED AT REST: encrypted to an age
# identity derived from the hardware token's FIDO2 hmac-secret extension. They
# are only ever decrypted to tmpfs (/run) for the duration of a pull session,
# with a physical touch (+ PIN) on the token. Losing the token AND the escrow
# copy loses the backups — escrow is MANDATORY (see `seal --escrow`).
#
# Self-contained: runs on `ver` with no nwp checkout. Requires age +
# age-plugin-fido2-hmac (installed by ver-provision.sh install) and the token
# plugged in for init/seal/unseal.
#
# Subcommands:
#   init                 create the FIDO2 age identity (one-time; touch + PIN).
#                        Writes $ETC/keystore/fido2.identity (0600).
#   seal NAME            seal a secret as $ETC/keystore/NAME.age
#     --generate           generate a fresh 64-hex secret (never displayed)
#     --from-stdin          read the secret from stdin (e.g. piped, no echo)
#     --escrow              ALSO write NAME.escrow.age encrypted to a passphrase
#                           you type (age scrypt) — store on offline media in the
#                           vault, independent of both this box and the token
#   unseal NAME [--out P]  decrypt to tmpfs (default /run/nwp-server/NAME, 0600)
#   lock [NAME]            shred the unsealed tmpfs copy (all, or one)
#   list                   list sealed entries
#   test                   round-trip a throwaway value (seal → unseal → compare)
#
# Typical entries:
#   ver-repo        password of ver's own durable restic repo
#   <site>.from     password of a prod host's local staging repo (for restic copy)
################################################################################

# NWP_VER_* overrides exist for sandboxed testing only — never set them on a real ver.
ETC="${NWP_VER_ETC:-/etc/nwp-server}"
KS="$ETC/keystore"
IDENTITY="$KS/fido2.identity"
RUN="${NWP_VER_RUN:-/run/nwp-server}"

c_ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; }
c_warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
c_err(){  printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
die(){ c_err "$*"; exit 1; }
usage(){ sed -n '3,/^####*$/{/^####*$/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

need_tools(){
  command -v age >/dev/null || die "age not found — run ver-provision.sh install first"
  command -v age-plugin-fido2-hmac >/dev/null || die "age-plugin-fido2-hmac not found — run ver-provision.sh install first"
}
need_identity(){ [ -f "$IDENTITY" ] || die "no FIDO2 identity yet — run: $0 init (token plugged in)"; }

recipient_of(){ # extract the age recipient from the identity file's comments
  grep -oE 'age1[0-9a-z]+' "$IDENTITY" | head -1
}

do_init(){
  need_tools
  mkdir -p "$KS"; chmod 700 "$KS" "$ETC" 2>/dev/null || true
  if [ -f "$IDENTITY" ]; then
    c_ok "identity already exists: $IDENTITY (leaving it alone)"
    return 0
  fi
  echo "Plug in the KEYSTORE token (Solo K). You will be asked for its FIDO2 PIN"
  echo "and a touch. This creates a NEW hmac-secret credential on the token."
  umask 077
  age-plugin-fido2-hmac -g > "$IDENTITY.tmp" || { rm -f "$IDENTITY.tmp"; die "identity generation failed"; }
  mv "$IDENTITY.tmp" "$IDENTITY"
  chmod 600 "$IDENTITY"
  local r; r="$(recipient_of || true)"
  [ -n "$r" ] || { rm -f "$IDENTITY"; die "could not extract an age recipient from the generated identity"; }
  c_ok "identity created: $IDENTITY"
  c_ok "recipient: $r"
  c_warn "the identity file is NOT enough to decrypt — the token (and PIN) is also"
  c_warn "required. But back the identity file up with the escrow media anyway:"
  c_warn "without it, even the token cannot decrypt."
}

do_seal(){
  need_tools; need_identity
  local name="${1:-}"; shift || true
  [ -n "$name" ] || die "usage: $0 seal NAME [--generate|--from-stdin] [--escrow]"
  local mode="" escrow=n
  while [ $# -gt 0 ]; do
    case "$1" in
      --generate) mode=generate ;;
      --from-stdin) mode=stdin ;;
      --escrow) escrow=y ;;
      *) die "unknown seal option: $1" ;;
    esac; shift
  done
  [ -n "$mode" ] || die "pick one: --generate (fresh 64-hex secret) or --from-stdin"
  local out="$KS/$name.age"
  [ ! -f "$out" ] || die "$out already exists — remove it explicitly first if you mean to replace it"
  local r; r="$(recipient_of)"
  umask 077
  local tmp; tmp="$(mktemp -p /dev/shm 2>/dev/null || mktemp)"
  # shellcheck disable=SC2064
  trap "shred -u '$tmp' 2>/dev/null || rm -f '$tmp'" EXIT
  case "$mode" in
    generate) head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$tmp" ;;
    stdin)    cat > "$tmp"; [ -s "$tmp" ] || die "empty secret on stdin" ;;
  esac
  age -r "$r" -o "$out" "$tmp" || die "sealing failed"
  chmod 600 "$out"
  c_ok "sealed → $out (touch NOT needed to seal; needed to UNSEAL)"
  if [ "$escrow" = y ]; then
    echo "Type the ESCROW passphrase (long, written down, stored in the vault"
    echo "independently of this box and the token):"
    age -p -o "$KS/$name.escrow.age" "$tmp" || die "escrow copy failed"
    chmod 600 "$KS/$name.escrow.age"
    c_ok "escrow copy → $KS/$name.escrow.age — MOVE this file to offline escrow media now"
  else
    c_warn "no escrow copy — token loss = backup loss. Re-run with --escrow unless"
    c_warn "this entry is already escrowed."
  fi
}

do_unseal(){
  need_tools; need_identity
  local name="${1:-}"; shift || true
  [ -n "$name" ] || die "usage: $0 unseal NAME [--out PATH]"
  local out="$RUN/$name"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out=*) out="${1#*=}" ;;
      --out) out="$2"; shift ;;
      *) die "unknown unseal option: $1" ;;
    esac; shift
  done
  [ -f "$KS/$name.age" ] || die "no sealed entry: $KS/$name.age"
  mkdir -p "$(dirname "$out")"; chmod 700 "$(dirname "$out")" 2>/dev/null || true
  case "$out" in /run/*|/dev/shm/*) ;; *) c_warn "unsealing OUTSIDE tmpfs ($out) — it will persist on disk until locked" ;; esac
  umask 077
  echo "Touch the KEYSTORE token when it blinks (PIN may be asked first)…"
  age -d -i "$IDENTITY" -o "$out" "$KS/$name.age" || die "unseal failed"
  chmod 600 "$out"
  c_ok "unsealed → $out (run '$0 lock' when the session is done)"
}

do_lock(){
  local name="${1:-}"
  if [ -n "$name" ]; then
    [ -f "$RUN/$name" ] && { shred -u "$RUN/$name"; c_ok "locked $name"; } || c_ok "$name not unsealed"
  else
    if compgen -G "$RUN/*" >/dev/null 2>&1; then
      shred -u "$RUN"/* 2>/dev/null || true
      c_ok "locked all unsealed entries"
    else
      c_ok "nothing unsealed"
    fi
  fi
}

do_list(){
  [ -d "$KS" ] || die "no keystore yet ($KS)"
  local f
  for f in "$KS"/*.age; do
    [ -e "$f" ] || { echo "  (no sealed entries)"; break; }
    echo "  $(basename "$f")"
  done
  if compgen -G "$RUN/*" >/dev/null 2>&1; then
    c_warn "UNSEALED in $RUN: $(ls -m "$RUN")  — lock when done"
  fi
}

do_test(){
  need_tools; need_identity
  local tmp; tmp="$(mktemp -d -p /dev/shm 2>/dev/null || mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  local r; r="$(recipient_of)"
  echo "keystore-roundtrip-$$" > "$tmp/plain"
  age -r "$r" -o "$tmp/sealed.age" "$tmp/plain"
  echo "Touch the token to complete the round-trip test…"
  age -d -i "$IDENTITY" -o "$tmp/back" "$tmp/sealed.age"
  cmp -s "$tmp/plain" "$tmp/back" && c_ok "ROUND-TRIP OK — seal/unseal verified" || die "round-trip MISMATCH"
}

CMD="${1:-}"; [ $# -gt 0 ] && shift
case "$CMD" in
  init)   do_init ;;
  seal)   do_seal "$@" ;;
  unseal) do_unseal "$@" ;;
  lock)   do_lock "${1:-}" ;;
  list)   do_list ;;
  test)   do_test ;;
  -h|--help|"") usage ;;
  *) die "unknown subcommand: $CMD (try --help)" ;;
esac
