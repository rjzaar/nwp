#!/bin/bash
set -euo pipefail
################################################################################
# prepare-ver-kit.sh — assemble the SIGNED provisioning kit for `ver` (ops#25).
#
# Runs on the `build-host` (inside the nwp checkout). `ver` — the offline
# signed-deploy verifier + DR-backup custodian (role-vocabulary.md; resolve the
# concrete box with `pl host ver`) — never holds the nwp source tree, so
# everything it needs travels as ONE verifiable directory:
#
#   build/out/ver-kit/
#     tools/            restic, age, age-keygen, age-plugin-fido2-hmac (+ .minisig each)
#     scripts/          the ver-side provisioning scripts (+ .minisig each)
#     templates/        WireGuard 1:1 tunnel + forced-command authorized_keys templates
#     nwp-minisign.pub  the pinned public key (verify EVERYTHING against this)
#     KIT.sha256        manifest of every file (+ KIT.sha256.minisig)
#     RUNBOOK.md        offline copy of docs/guides/ver-provisioning-runbook.md
#
# Supply-chain posture (ADR-0025 "the restic binary is minisign-verified before
# use"): this script FAILS CLOSED on tool integrity. Every tool binary must match
# an operator-supplied sha256 pin before it enters the kit; the kit is then signed
# with the NWP minisign key so `ver` can verify the whole tree offline against the
# one pinned public key. No pin, no kit — use --print-sha256 to fetch a candidate
# and print its observed hash, then confirm that hash against the upstream
# project's published checksums (out of band) before writing it into the pins file.
#
# Usage:
#   scripts/ver-provision/prepare-ver-kit.sh [--out DIR] [--pins FILE]
#   scripts/ver-provision/prepare-ver-kit.sh --print-sha256 <restic|age|fido2hmac>
#
#   --out DIR         kit output dir (default: build/out/ver-kit)
#   --pins FILE       pins file (default: scripts/ver-provision/ver-kit.pins)
#   --local TOOL=PATH use a pre-downloaded archive/binary for TOOL instead of
#                     fetching (still verified against the pin; repeatable)
#   --no-sign         skip minisign signing (kit is then NOT transferable — for
#                     testing the assembly only)
#   --print-sha256 T  download tool T per the pins file version and print the
#                     observed sha256 WITHOUT installing anything
#
# Pins file format (see ver-kit.pins.example):
#   restic_version=…    restic_sha256=…    [restic_url=…]
#   age_version=…       age_sha256=…       [age_url=…]
#   fido2hmac_version=… fido2hmac_sha256=… [fido2hmac_url=…]
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/minisign.sh"

OUT_DIR="$PROJECT_ROOT/build/out/ver-kit"
PINS_FILE="$SCRIPT_DIR/ver-kit.pins"
SIGN=y
PRINT_TOOL=""
declare -A LOCAL_SRC=()

die(){ print_error "$*"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out=*)  OUT_DIR="${1#*=}" ;;
    --out)    OUT_DIR="$2"; shift ;;
    --pins=*) PINS_FILE="${1#*=}" ;;
    --pins)   PINS_FILE="$2"; shift ;;
    --local=*) kv="${1#*=}"; LOCAL_SRC["${kv%%=*}"]="${kv#*=}" ;;
    --local)  kv="$2"; LOCAL_SRC["${kv%%=*}"]="${kv#*=}"; shift ;;
    --no-sign) SIGN=n ;;
    --print-sha256=*) PRINT_TOOL="${1#*=}" ;;
    --print-sha256)   PRINT_TOOL="$2"; shift ;;
    -h|--help) sed -n '3,/^####*$/{/^####*$/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# ── Pins ─────────────────────────────────────────────────────────────────────
[ -f "$PINS_FILE" ] || die "pins file not found: $PINS_FILE
Copy scripts/ver-provision/ver-kit.pins.example to ver-kit.pins, then fill each
sha256 after confirming it against the upstream project's published checksums."
# shellcheck source=/dev/null
source "$PINS_FILE"

pin_get(){ # pin_get <tool> <field>  → value or empty
  local var="${1}_${2}"; echo "${!var:-}"
}

tool_url(){ # constructed default download URL per tool (override with <tool>_url pin)
  local t="$1" v; v="$(pin_get "$t" version)"
  local override; override="$(pin_get "$t" url)"
  if [ -n "$override" ]; then echo "$override"; return; fi
  [ -n "$v" ] || die "$t: no ${t}_version set in $PINS_FILE"
  case "$t" in
    restic)    echo "https://github.com/restic/restic/releases/download/v${v}/restic_${v}_linux_amd64.bz2" ;;
    age)       echo "https://github.com/FiloSottile/age/releases/download/v${v}/age-v${v}-linux-amd64.tar.gz" ;;
    fido2hmac) echo "https://github.com/olastor/age-plugin-fido2-hmac/releases/download/v${v}/age-plugin-fido2-hmac-v${v}-linux-amd64.tar.gz" ;;
    *) die "unknown tool: $t" ;;
  esac
}

fetch_tool(){ # fetch_tool <tool> <dest-archive> — download or copy --local source
  local t="$1" dest="$2" url
  if [ -n "${LOCAL_SRC[$t]:-}" ]; then
    [ -f "${LOCAL_SRC[$t]}" ] || die "--local $t=${LOCAL_SRC[$t]}: file not found"
    cp "${LOCAL_SRC[$t]}" "$dest"
    print_info "$t: using local file ${LOCAL_SRC[$t]}"
  else
    url="$(tool_url "$t")"
    print_info "$t: fetching $url"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$dest" "$url" || die "$t: download failed"
  fi
}

verify_pin(){ # verify_pin <tool> <file> — fail-closed sha256 pin check
  local t="$1" f="$2" want got
  want="$(pin_get "$t" sha256)"
  got="$(sha256sum "$f" | awk '{print $1}')"
  if [ -z "$want" ]; then
    die "$t: no sha256 pin set in $PINS_FILE (observed: $got).
Confirm this hash against the upstream published checksums, then pin it."
  fi
  [ "$got" = "$want" ] || die "$t: sha256 MISMATCH — pinned $want, got $got. Refusing."
  print_status "OK" "$t sha256 matches pin"
}

# ── --print-sha256 mode: fetch + print, install nothing ─────────────────────
if [ -n "$PRINT_TOOL" ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  fetch_tool "$PRINT_TOOL" "$tmp/artifact"
  echo
  echo "observed sha256 ($PRINT_TOOL $(pin_get "$PRINT_TOOL" version)):"
  sha256sum "$tmp/artifact" | awk '{print "  " $1}'
  echo
  echo "Confirm this against the upstream project's published checksums (their"
  echo "release SHA256SUMS / checksums.txt) BEFORE pinning it in $PINS_FILE."
  exit 0
fi

# ── Preflight ────────────────────────────────────────────────────────────────
print_header "prepare-ver-kit"
for c in curl sha256sum tar bunzip2; do
  command -v "$c" >/dev/null || die "required command not found: $c"
done
if [ "$SIGN" = y ]; then
  minisign_check || exit 1
  [ -f "$MINISIGN_SECRET_KEY" ] || die "minisign secret key not found: $MINISIGN_SECRET_KEY (or pass --no-sign for a test assembly)"
  [ -f "$MINISIGN_PUBLIC_KEY" ] || die "minisign public key not found: $MINISIGN_PUBLIC_KEY"
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/tools" "$OUT_DIR/scripts" "$OUT_DIR/templates"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ── Tools: fetch → pin-verify → extract binaries ─────────────────────────────
print_header "Step 1 · Tools (fetch, pin-verify, extract)"

fetch_tool restic "$WORK/restic.bz2"
verify_pin restic "$WORK/restic.bz2"
bunzip2 -c "$WORK/restic.bz2" > "$OUT_DIR/tools/restic"

fetch_tool age "$WORK/age.tgz"
verify_pin age "$WORK/age.tgz"
tar -xzf "$WORK/age.tgz" -C "$WORK"
cp "$WORK/age/age" "$OUT_DIR/tools/age"
cp "$WORK/age/age-keygen" "$OUT_DIR/tools/age-keygen"

fetch_tool fido2hmac "$WORK/fido2hmac.tgz"
verify_pin fido2hmac "$WORK/fido2hmac.tgz"
mkdir -p "$WORK/fido2hmac"
tar -xzf "$WORK/fido2hmac.tgz" -C "$WORK/fido2hmac"
# release layout varies; locate the plugin binary inside the archive
plugin="$(find "$WORK/fido2hmac" -type f -name 'age-plugin-fido2-hmac*' ! -name '*.md' ! -name '*.txt' | head -1)"
[ -n "$plugin" ] || die "age-plugin-fido2-hmac binary not found inside the archive"
cp "$plugin" "$OUT_DIR/tools/age-plugin-fido2-hmac"
chmod 755 "$OUT_DIR"/tools/*

# ── Ver-side scripts + templates + runbook ───────────────────────────────────
print_header "Step 2 · Scripts, templates, runbook"
for s in ver-provision.sh ver-seal-keystore.sh ver-pull-session.sh; do
  [ -f "$SCRIPT_DIR/$s" ] || die "missing ver-side script: $SCRIPT_DIR/$s"
  cp "$SCRIPT_DIR/$s" "$OUT_DIR/scripts/$s"
  chmod 755 "$OUT_DIR/scripts/$s"
done
for t in ver-prod-wireguard.conf.tmpl ver-restic-authorized-keys.tmpl; do
  cp "$PROJECT_ROOT/templates/$t" "$OUT_DIR/templates/$t"
done
cp "$PROJECT_ROOT/docs/guides/ver-provisioning-runbook.md" "$OUT_DIR/RUNBOOK.md"
cp "$MINISIGN_PUBLIC_KEY" "$OUT_DIR/nwp-minisign.pub"

# ── Sign every payload file, then the manifest ───────────────────────────────
print_header "Step 3 · Sign + manifest"
( cd "$OUT_DIR"
  if [ "$SIGN" = y ]; then
    # Read the file list into an array FIRST so the signing loop keeps the
    # terminal as stdin — otherwise `done < <(find …)` steals stdin and
    # minisign's password prompt reads EOF from the find stream and bails.
    mapfile -t _sign_files < <(find tools scripts -type f ! -name '*.minisig')
    for f in "${_sign_files[@]}"; do
      minisign_sign "$f" "ver-kit $(basename "$f") $(date -I)" >/dev/null </dev/tty
    done
  fi
  find . -type f ! -name 'KIT.sha256*' -printf '%P\n' | sort | xargs sha256sum > KIT.sha256
  [ "$SIGN" = y ] && minisign_sign KIT.sha256 "ver-kit manifest $(date -I)" >/dev/null
)

echo
print_success "ver-kit assembled → $OUT_DIR"
print_info "transfer the WHOLE directory to ver via the offline channel (USB), then on ver:"
print_info "  sudo apt-get install -y minisign   # bootstrap verifier (distro-signed)"
print_info "  minisign -V -p nwp-minisign.pub -m KIT.sha256 && sha256sum -c KIT.sha256"
print_info "  sudo bash scripts/ver-provision.sh all --kit ."
