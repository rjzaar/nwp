#!/usr/bin/env bash
# pubrel-docs-check.sh — helpers for the public-release doc scrub (item B1).
#
# The public-release docs must not carry the operator's real identifiers.
# `tests/fixtures/pubrel-docs.txt` lists the 31 prose docs in scope: the set
# the stranded branch pubrel/scrub-and-gate genericised. That branch's
# .gitleaks.toml half is SUPERSEDED (all three identity rules it added are on
# main since 92cf069) and is deliberately NOT taken here.
#
# Sourced by tests/unit/test-pubrel-docs-genericised.bats; also runnable
# standalone to reproduce the red/green transcript:
#
#   bash tests/helpers/pubrel-docs-check.sh report
#   bash tests/helpers/pubrel-docs-check.sh scan
#
# ---------------------------------------------------------------------------
# TWO GITLEAKS FOOTGUNS THIS FILE WORKS AROUND (both verified on 8.21.2)
#
# 1. `.gitignore` line 7 of this repo is `/*` (deny-all, then re-include).
#    `gitleaks detect --no-git` HONOURS .gitignore, so scanning the repo root
#    walks almost nothing: a root scan reports 1 finding where scanning docs/
#    explicitly reports 82. The ledger header's documented regenerate command
#    (`gitleaks detect --no-git --source .`) therefore scans an empty tree.
#    We work around it by exporting the TRACKED file list to a temp dir with
#    .gitignore omitted, and scanning that.
#
# 2. `--gitleaks-ignore-path/-i` does NOT reliably override the
#    `.gitleaksignore` found in the --source directory; the source-dir copy
#    wins. So to scan with a pruned ledger we must write the pruned ledger
#    INTO the exported tree rather than pass it with -i.
# ---------------------------------------------------------------------------

set -uo pipefail

# Operator identifiers that must not appear in public-release prose.
#
# NOTE: the item's stated grep was domains-only, which under-counts. Two of the
# 31 in-scope files (F13, F16) leak the operator's public IP rather than a
# domain, so a domains-only test would call them clean while they are dirty.
# The three identity rules the gate on main enforces are live-domain-apex /
# live-internal-domain, operator-public-ip and operator-personal-email; this
# mirrors all three.
PUBREL_DOMAIN_RE='nwpcode\.org|mayostudios\.org|97\.107\.137\.88|rjzaar@'

# ALLOWLISTED FUNCTIONAL REFERENCES — must NOT be scrubbed.
#
# .gitleaks.toml carries an explicit allowlist for public forge URLs of the
# form git.<domain>/<project>/-/(issues|merge_requests|blob|tree)/..., described
# there as "public project links, not subdomain leaks". They are live
# hyperlinks to the issue tracker: genericising them produces a dead link and a
# factually wrong document, which is the "functional target" failure the
# acceptance test warns about. We mask them before matching so the checker
# agrees with the gate.
#
# This is load-bearing: docs/pedagogy/learning-science-foundations.md's ONLY
# hit is such a URL, so it needs no scrub at all. The stranded branch
# pubrel/scrub-and-gate rewrote it anyway (to git.example.com) and thereby
# broke the link -- a defect in that branch, not something to import.
#
# NB: the s/// delimiter must NOT be `|`, or it collides with the `\|`
# alternation and the mask silently matches nothing.
PUBREL_ALLOWLIST_SED='s@git\.nwpcode\.org/[A-Za-z0-9./_-]*/-/\(issues\|merge_requests\|blob\|tree\)/@<ALLOWLISTED-FORGE-URL>@g'

pubrel_repo_root() {
  git rev-parse --show-toplevel
}

pubrel_file_list() {
  local root
  root="$(pubrel_repo_root)"
  grep -vE '^[[:space:]]*(#|$)' "${root}/tests/fixtures/pubrel-docs.txt"
}

# Files (from the in-scope list) that still contain a real operator identifier.
pubrel_offending_files() {
  local root f
  root="$(pubrel_repo_root)"
  while read -r f; do
    [ -n "$f" ] || continue
    # NB: do NOT use `grep -q` here. Under `set -o pipefail`, grep -q exits on
    # the first match and SIGPIPEs sed, so the pipeline's status depends on
    # whether sed had finished writing -- which made this check flaky (it
    # reported 24, 25 and 27 offenders on three consecutive runs of an
    # unchanged tree). grep -c consumes all input, so the result is stable.
    local hits
    hits="$(sed "$PUBREL_ALLOWLIST_SED" "${root}/${f}" 2>/dev/null \
              | grep -cE "$PUBREL_DOMAIN_RE")"
    if [ "${hits:-0}" -gt 0 ]; then
      printf '%s\n' "$f"
    fi
  done < <(pubrel_file_list)
}

# Every occurrence, with line numbers — for the transcript.
pubrel_offending_lines() {
  local root f
  root="$(pubrel_repo_root)"
  while read -r f; do
    [ -n "$f" ] || continue
    sed "$PUBREL_ALLOWLIST_SED" "${root}/${f}" 2>/dev/null \
      | grep -nE "$PUBREL_DOMAIN_RE" | sed "s|^|${f}:|"
  done < <(pubrel_file_list)
}

# Write a copy of .gitleaksignore with every fingerprint belonging to an
# in-scope file removed.
pubrel_pruned_gitleaksignore() {
  local out="$1" root
  root="$(pubrel_repo_root)"
  local -a pats=()
  local f
  while read -r f; do
    [ -n "$f" ] || continue
    pats+=("-e" "^${f}:")
  done < <(pubrel_file_list)
  if [ "${#pats[@]}" -eq 0 ]; then
    cp "${root}/.gitleaksignore" "$out"
  else
    grep -v "${pats[@]}" "${root}/.gitleaksignore" > "$out"
  fi
}

# Count of fingerprints the prune removes (suppressions the scrub retires).
pubrel_pruned_count() {
  local tmp before after
  tmp="$(mktemp)"
  pubrel_pruned_gitleaksignore "$tmp"
  before="$(wc -l < "$(pubrel_repo_root)/.gitleaksignore")"
  after="$(wc -l < "$tmp")"
  rm -f "$tmp"
  printf '%s\n' "$(( before - after ))"
}

# Export the TRACKED working tree (minus .gitignore, see footgun 1) into $1.
pubrel_export_tree() {
  local dest="$1" root f
  root="$(pubrel_repo_root)"
  rm -rf "$dest"; mkdir -p "$dest"
  while IFS= read -r -d '' f; do
    [ "$f" = ".gitignore" ] && continue
    mkdir -p "${dest}/$(dirname "$f")"
    cp "${root}/${f}" "${dest}/${f}" 2>/dev/null || true
  done < <(cd "$root" && git ls-files -z)
  cp "${root}/.gitleaks.toml" "${dest}/.gitleaks.toml"
}

# Scan the tracked tree. $1 = "full" (ledger as committed) or "pruned"
# (in-scope suppressions removed). Exit 0 == clean.
pubrel_scan() {
  local mode="${1:-pruned}"
  local root dest report rc real
  root="$(pubrel_repo_root)"
  dest="$(mktemp -d)"
  report="$(mktemp)"
  pubrel_export_tree "$dest"
  if [ "$mode" = "full" ]; then
    cp "${root}/.gitleaksignore" "${dest}/.gitleaksignore"
  else
    pubrel_pruned_gitleaksignore "${dest}/.gitleaksignore"
  fi
  ( cd "$dest" && gitleaks detect --no-git --source . --config .gitleaks.toml \
      --report-format json --report-path "$report" \
      --redact --no-banner >/dev/null 2>&1 )
  real="$(python3 - "$report" <<'PY'
import json, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception:
    rows = []
for r in rows:
    print(f"  LEAK {r.get('File')}:{r.get('StartLine')} rule={r.get('RuleID')}",
          file=sys.stderr)
print(len(rows))
PY
)"
  rc=0
  [ "${real:-1}" -eq 0 ] || rc=1
  rm -rf "$dest" "$report"
  return "$rc"
}

pubrel_scan_without_suppressions() { pubrel_scan pruned; }

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-report}" in
    files)  pubrel_offending_files ;;
    lines)  pubrel_offending_lines ;;
    count)  pubrel_offending_files | wc -l ;;
    pruned) pubrel_pruned_count ;;
    scan)   pubrel_scan pruned; echo "pruned-ledger scan exit=$?" ;;
    base)   pubrel_scan full;   echo "full-ledger scan exit=$?" ;;
    *)
      echo "in-scope files:      $(pubrel_file_list | wc -l)"
      echo "files with leaks:    $(pubrel_offending_files | wc -l)"
      echo "fingerprints pruned: $(pubrel_pruned_count)"
      ;;
  esac
fi
