#!/bin/bash
set -euo pipefail
################################################################################
# build-nwp-server.sh — assemble the AI-free `nwp-server` build target.
#
# nwp-server is a BUILD TARGET of the nwp source tree (ADR-0022 + ADR-0024), not a
# separate repo. The AI-free guarantee is BUILD-TIME: the artifact is assembled
# from an ALLOWLIST (build/nwp-server.include) and then scanned FAIL-CLOSED against
# a deny-list (build/nwp-server.deny-symbols). Any AI / CI / SaaS vendor token in
# the assembled tree fails the build — the mechanical form of ADR-0022's
# "`strings` check returns zero AI-vendor symbols" success metric.
#
# Usage:
#   pl build-server                 assemble + scan → build/out/nwp-server/
#   pl build-server --out DIR       assemble into DIR
#   pl build-server --list          print the include allowlist (no build)
#   pl build-server --scan-only DIR scan an already-assembled tree, no assemble
#   pl build-server -h|--help
#
# Exit: 0 = clean artifact built; 1 = deny-scan failed (PII/AI/SaaS leak) or error.
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh" 2>/dev/null || { echo "[!] lib/ui.sh missing"; exit 1; }

INCLUDE_FILE="$PROJECT_ROOT/build/nwp-server.include"
DENY_FILE="$PROJECT_ROOT/build/nwp-server.deny-symbols"
OUT_DIR="$PROJECT_ROOT/build/out/nwp-server"
MODE="build"
SCAN_DIR=""

die(){ print_error "$*"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2 ;;
    --out=*) OUT_DIR="${1#*=}"; shift ;;
    --list) MODE="list"; shift ;;
    --scan-only) MODE="scan"; SCAN_DIR="$2"; shift 2 ;;
    --scan-only=*) MODE="scan"; SCAN_DIR="${1#*=}"; shift ;;
    -h|--help) sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -f "$INCLUDE_FILE" ] || die "include allowlist not found: $INCLUDE_FILE"
[ -f "$DENY_FILE" ]    || die "deny-symbols list not found: $DENY_FILE"

# Read a manifest file into a clean array (strip comments + blank lines).
read_manifest(){ # $1 = file
  local line
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] && printf '%s\n' "$line"
  done < "$1"
}

mapfile -t INCLUDES < <(read_manifest "$INCLUDE_FILE")
[ "${#INCLUDES[@]}" -gt 0 ] || die "include allowlist is empty — refusing to build an empty artifact"

if [ "$MODE" = "list" ]; then
  print_header "nwp-server include allowlist (${#INCLUDES[@]} entries)"
  printf '  %s\n' "${INCLUDES[@]}"
  exit 0
fi

# ── Fail-closed deny scan ─────────────────────────────────────────────────────
# Scans a tree against build/nwp-server.deny-symbols (case-insensitive ERE union).
# Returns 0 = clean, 1 = at least one match (prints file:line:token).
deny_scan(){ # $1 = tree
  local tree="$1"
  mapfile -t deny < <(read_manifest "$DENY_FILE")
  [ "${#deny[@]}" -gt 0 ] || { print_error "deny-list empty — refusing to declare clean (fail-closed)"; return 1; }
  local union; union=$(IFS='|'; echo "${deny[*]}")
  local hits
  hits=$(grep -rInE -- "$union" "$tree" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    print_error "deny-scan FAILED — AI/CI/SaaS vendor token(s) present in artifact:"
    printf '%s\n' "$hits" | sed -E "s#^$tree/?##" | head -40 | while IFS= read -r l; do echo "    $l"; done
    local n; n=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
    [ "$n" -gt 40 ] && echo "    … and $((n - 40)) more"
    return 1
  fi
  return 0
}

if [ "$MODE" = "scan" ]; then
  [ -d "$SCAN_DIR" ] || die "scan target not a directory: $SCAN_DIR"
  print_header "Scanning $SCAN_DIR (fail-closed)"
  if deny_scan "$SCAN_DIR"; then print_success "deny-scan PASSED — no AI/CI/SaaS symbols"; exit 0
  else exit 1; fi
fi

# ── Assemble ──────────────────────────────────────────────────────────────────
print_header "Building nwp-server artifact"
print_info "source:  $PROJECT_ROOT"
print_info "out:     $OUT_DIR"
print_info "include: ${#INCLUDES[@]} entries"

rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
copied=0
for rel in "${INCLUDES[@]}"; do
  src="$PROJECT_ROOT/$rel"
  if [ -d "${src%/}" ] || [[ "$rel" == */ ]]; then
    [ -d "${src%/}" ] || die "include dir not found: $rel"
    mkdir -p "$OUT_DIR/${rel%/}"
    # deterministic copy of regular files under the dir
    while IFS= read -r f; do
      local_rel="${f#$PROJECT_ROOT/}"
      mkdir -p "$OUT_DIR/$(dirname "$local_rel")"
      cp -p "$f" "$OUT_DIR/$local_rel"
      copied=$((copied+1))
    done < <(find "${src%/}" -type f | LC_ALL=C sort)
  else
    [ -f "$src" ] || die "include file not found: $rel"
    mkdir -p "$OUT_DIR/$(dirname "$rel")"
    cp -p "$src" "$OUT_DIR/$rel"
    copied=$((copied+1))
  fi
done
print_status "OK" "assembled $copied file(s)"

# ── The fail-closed gate ──────────────────────────────────────────────────────
print_info "running fail-closed deny-scan…"
if ! deny_scan "$OUT_DIR"; then
  print_error "BUILD FAILED — artifact is not AI-free. Tighten build/nwp-server.include"
  print_hint  "or partition the offending shared lib into lib/ai|ci|saas (08 K1.1/K1.2)."
  rm -rf "$OUT_DIR"
  exit 1
fi
print_status "OK" "deny-scan PASSED — zero AI/CI/SaaS symbols"

# ── Self-describing manifest (deterministic, sorted) ─────────────────────────
{
  echo "# nwp-server artifact manifest — generated by scripts/build-nwp-server.sh"
  echo "# AI-free build target of nwp (ADR-0022, ADR-0024). Capability set:"
  echo "#   pull+verify · apply · snapshot+sanitize+publish (fail-closed PII gate) · rollback · status"
  echo "#"
  ( cd "$OUT_DIR" && find . -type f ! -name MANIFEST.sha256 | LC_ALL=C sort | while IFS= read -r f; do
      sha256sum "$f"
    done )
} > "$OUT_DIR/MANIFEST.sha256"

n_files=$(grep -vc '^#' "$OUT_DIR/MANIFEST.sha256" || echo 0)
print_success "nwp-server built: $OUT_DIR ($n_files files, MANIFEST.sha256 written)"
print_hint "verify independently:  pl build-server --scan-only $OUT_DIR"
