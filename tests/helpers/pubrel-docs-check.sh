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
# STANDING RULE FOR THIS FILE: every check here FAILS CLOSED. "I could not
# check" must never be encoded as "clean" — this is the check that authorises a
# public docs release, so a false green publishes real identifiers. See the
# block above pubrel_scan for the fail-open defect this rule was written from.
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
#
# SCOPE — this mirrors ALL SIX operator-identity rules on main's .gitleaks.toml:
#
#   operator-home-path        /home/([a-z][a-z0-9_-]+)/           (line ~51)
#   operator-organisation     mazenod|oblates of mary…|omi        (line ~312)
#   operator-public-ip        97.107.137.88 | 45.33.94.133        (line ~390)
#   operator-personal-email   rjzaar@…                            (line ~468)
#   live-domain-apex          nwpcode.org | mayostudios.org       (line ~484)
#   live-internal-domain      *.nwpcode.org | *.mayostudios.org   (line ~593)
#
# An earlier revision of this file claimed the gate enforced "three identity
# rules" and mirrored only four of the six patterns — it omitted
# operator-home-path and operator-organisation, and it omitted the second
# operator IP (45.33.94.133). That claim was wrong, and the omission mattered:
# a planted `/home/rob/…` left this grep GREEN and was caught only by the
# gitleaks backstop in pubrel_scan (tests 7/8). A checker whose scope is
# narrower than the gate's silently relies on the backstop; when the backstop
# failed open (see pubrel_scan) nothing watched those two rules at all.
#
# NOT mirrored, deliberately: internal-hostname-fqdn (*.home/.local/.tunnel) and
# internal-bare-hostname (mini|metabox|mons|carlo|mmt). Those are role/host
# names, not operator identity, and the bare-hostname alternation false-positives
# hard on ordinary prose ("mini", "mons"). They remain the gitleaks backstop's
# job — which is now safe to rely on, because the backstop fails closed.
#
# Matched with `grep -iE`: operator-organisation is `(?i)` in the gate, and
# case-folding the rest can only widen what we catch, never narrow it.
PUBREL_IDENTITY_RE='/home/[a-z][a-z0-9_-]+/|\b(mazenod|oblates?[[:space:]]+of[[:space:]]+mary[[:space:]]+immaculate|oblatesmi|omi)\b|\b(97\.107\.137\.88|45\.33\.94\.133)\b|\brjzaar@[a-z0-9.-]+\.[a-z]{2,}\b|\b(nwpcode|mayostudios)\.org\b|\b[a-z0-9_-]+\.(nwpcode\.org|mayostudios\.org)\b'

# Back-compat alias: the variable was PUBREL_DOMAIN_RE while it was domains-only.
PUBREL_DOMAIN_RE="$PUBREL_IDENTITY_RE"

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
# SECOND MASK — /home/gitlab/. .gitleaks.toml path-allowlists
# docs/proposals/F15-ssh-user-management.md for operator-home-path with the
# reason "the conventional gitlab system service-account home (/home/gitlab/.ssh)
# — a well-known service account, not the operator's home". Mirroring the six
# identity rules means mirroring that exemption too, or the checker disagrees
# with the gate it is supposed to mirror. This mask is NARROWER than the gate's:
# the gate exempts that whole file for the rule; we exempt only the literal
# service-account path, in every file. Any other /home/<user>/ still trips.
#
# NB: the s/// delimiter must NOT be `|`, or it collides with the `\|`
# alternation and the mask silently matches nothing.
PUBREL_ALLOWLIST_SED='s@git\.nwpcode\.org/[A-Za-z0-9./_-]*/-/\(issues\|merge_requests\|blob\|tree\)/@<ALLOWLISTED-FORGE-URL>@g; s@/home/gitlab/@<SERVICE-ACCOUNT-HOME>/@g'

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
              | grep -ciE "$PUBREL_IDENTITY_RE")"
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
      | grep -niE "$PUBREL_IDENTITY_RE" | sed "s|^|${f}:|"
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

# Resolve the scanner binary, in the same order tests/unit/test-leakage-gate.bats
# uses: an explicitly supplied binary (its setup_file pins the same 8.30.0
# release lint:leakage installs, sha256-verified) beats PATH.
pubrel_gitleaks_bin() {
  if [ -n "${GITLEAKS_BIN:-}" ] && [ -x "${GITLEAKS_BIN}" ]; then
    printf '%s\n' "$GITLEAKS_BIN"; return 0
  fi
  if [ -n "${NWP_GITLEAKS_BIN:-}" ] && [ -x "${NWP_GITLEAKS_BIN}" ]; then
    printf '%s\n' "$NWP_GITLEAKS_BIN"; return 0
  fi
  command -v gitleaks 2>/dev/null
}

# Which tool pubrel_scan needs is missing? (prints the name, exits 0 if any)
#
# ABSENCE is a declared, visible condition. RUNTIME FAILURE of a tool that IS
# present is a different thing entirely: that is an error, and pubrel_scan must
# report it as one. Never as "clean". Note the bats suite does NOT skip on
# absence either — it resolves gitleaks or fails the whole file, because
# "we could not check" is not a pass for a gate that authorises publication.
pubrel_scan_missing_tool() {
  pubrel_gitleaks_bin >/dev/null 2>&1 || { printf 'gitleaks\n'; return 0; }
  command -v python3 >/dev/null 2>&1  || { printf 'python3\n';  return 0; }
  return 1
}

# Scan the tracked tree. $1 = "full" (ledger as committed) or "pruned"
# (in-scope suppressions removed).
#
#   0 = scanned, no findings          (the ONLY value that means "clean")
#   1 = scanned, findings present
#   2 = COULD NOT SCAN — tool missing, scanner errored, report absent or
#       unparseable, or scanner rc and report disagree
#
# ---------------------------------------------------------------------------
# WHY 2 EXISTS (fail-closed). This function used to run gitleaks inside
# `( … >/dev/null 2>&1 )` and throw its exit status away, then judge the tree
# solely by `json.load(report)` under a bare `except Exception: rows = []`.
# A missing, empty or unparseable report therefore decoded as "0 findings =
# clean". Reproduced 2026-07-27 on this branch: appending one malformed rule to
# .gitleaks.toml (a single unbalanced paren — and .gitleaks.toml is actively
# edited by another workstream) makes gitleaks exit 2 and write no report, and
# the whole 8-test suite went GREEN with a real `/home/rob/nwp/lib/common.sh`
# operator-home-path leak sitting in docs/governance/roles.md.
#
# That is the worst possible failure mode for this particular check: it is what
# authorises publishing a "scrubbed" docs library. A build that fails is a
# nuisance; a scan that cannot run but says "clean" publishes the operator's
# home path, personal email or prod IP.
#
# gitleaks exit codes: 0 = no leaks, 1 = leaks found, anything else = error.
# ---------------------------------------------------------------------------
pubrel_scan() {
  local mode="${1:-pruned}"
  local root dest report gl_rc real py_rc missing gl_bin

  # Guard FIRST, before touching the tree, so the guard itself is testable.
  if missing="$(pubrel_scan_missing_tool)"; then
    printf 'pubrel_scan: %s is not installed — cannot verify, refusing to report clean\n' \
      "$missing" >&2
    return 2
  fi

  root="$(pubrel_repo_root)"
  dest="$(mktemp -d)"
  report="$(mktemp)"
  pubrel_export_tree "$dest"
  if [ "$mode" = "full" ]; then
    cp "${root}/.gitleaksignore" "${dest}/.gitleaksignore"
  else
    pubrel_pruned_gitleaksignore "${dest}/.gitleaksignore"
  fi

  gl_bin="$(pubrel_gitleaks_bin)"
  gl_rc=0
  ( cd "$dest" && "$gl_bin" detect --no-git --source . --config .gitleaks.toml \
      --report-format json --report-path "$report" \
      --redact --no-banner >/dev/null 2>&1 ) || gl_rc=$?

  if [ "$gl_rc" -ne 0 ] && [ "$gl_rc" -ne 1 ]; then
    printf 'pubrel_scan: gitleaks exited %s (scanner error, not a verdict) — refusing to report clean\n' \
      "$gl_rc" >&2
    printf 'pubrel_scan: re-run without 2>/dev/null to see why; a malformed .gitleaks.toml is the usual cause\n' >&2
    rm -rf "$dest" "$report"
    return 2
  fi

  if [ ! -s "$report" ]; then
    printf 'pubrel_scan: gitleaks wrote no report (%s) — refusing to report clean\n' \
      "$report" >&2
    rm -rf "$dest" "$report"
    return 2
  fi

  # Parse. NO bare `except: rows = []` — an unreadable report is an error.
  py_rc=0
  real="$(python3 - "$report" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        rows = json.load(fh)
except Exception as exc:                       # noqa: BLE001 - reported, not swallowed
    print(f"report unparseable: {exc}", file=sys.stderr)
    sys.exit(3)
if not isinstance(rows, list):
    print(f"report is {type(rows).__name__}, expected a list", file=sys.stderr)
    sys.exit(3)
for r in rows:
    print(f"  LEAK {r.get('File')}:{r.get('StartLine')} rule={r.get('RuleID')}",
          file=sys.stderr)
print(len(rows))
PY
)" || py_rc=$?

  rm -rf "$dest" "$report"

  if [ "$py_rc" -ne 0 ] || ! [[ "$real" =~ ^[0-9]+$ ]]; then
    printf 'pubrel_scan: could not read the gitleaks report — refusing to report clean\n' >&2
    return 2
  fi

  # The scanner's own verdict and the report must agree. If they do not, we do
  # not know which is right, so we do not get to say "clean".
  if { [ "$gl_rc" -eq 0 ] && [ "$real" -ne 0 ]; } ||
     { [ "$gl_rc" -eq 1 ] && [ "$real" -eq 0 ]; }; then
    printf 'pubrel_scan: gitleaks rc=%s disagrees with a %s-row report — refusing to report clean\n' \
      "$gl_rc" "$real" >&2
    return 2
  fi

  [ "$real" -eq 0 ] || return 1
  return 0
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
