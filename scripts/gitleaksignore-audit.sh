#!/usr/bin/env bash
#
# gitleaksignore-audit.sh — decide, with evidence, which .gitleaksignore
# fingerprints may safely be deleted.
#
# WHY THIS EXISTS
# ---------------
# .gitleaks.toml RULE 2 says: when the gate is too noisy, add a FINGERPRINT to
# .gitleaksignore with a rationale — never widen a path exemption. That rule is
# correct, but it makes every fingerprint an IOU against a future prose scrub,
# and nothing in the repo could tell you when an IOU had been paid.
#
# The dangerous move is deleting fingerprints by eye. `lint:leakage` scans only
# the MR's own commit range (`gitleaks git --log-opts=<base>..HEAD`), so an MR
# that deletes fingerprint lines and touches nothing else is scanned green no
# matter how many live leaks it just un-silenced. The gate cannot review this
# change class. This script can.
#
# WHAT IT DOES
# ------------
# Exports the tracked tree at a ref, scans the chosen subtree twice against the
# repo's own .gitleaks.toml — once with .gitleaksignore in place, once with it
# physically removed — and classifies every declared fingerprint:
#
#   LOAD-BEARING  the fingerprint still matches a live finding. Deleting it
#                 re-exposes a real hit; the prose is not scrubbed yet.
#   STALE         no live finding matches. The IOU is paid; safe to retire.
#   UNSILENCED    a live finding with no fingerprint at all. The gate will go
#                 red the moment an MR touches that line.
#
# TWO GITLEAKS FOOTGUNS THIS SCRIPT WORKS AROUND (both measured on 8.21.2)
# -----------------------------------------------------------------------
#  1. `--gitleaks-ignore-path` does NOT override a `.gitleaksignore` sitting at
#     the scan root. Pointing it at an empty file while the real one is still on
#     disk yields 0 findings — the root file is honoured regardless. The only
#     reliable way to scan un-silenced is to DELETE the file from the scan tree,
#     which is why this script works on a throwaway export and never in place.
#  2. Scan-source form changes the reported path, and rule `paths` exemptions in
#     .gitleaks.toml are anchored repo-relative (`^docs/reports/.*`). An absolute
#     scan source produces absolute paths that match no exemption and massively
#     over-reports (1131 vs 82 for docs/ on this repo). Always scan with a
#     repo-relative source from inside the export root.
#
# INTENDED USE (the B1b workflow)
# -------------------------------
#   1. Before the prose scrub, to prove the IOUs are still owed:
#        scripts/gitleaksignore-audit.sh --prefix docs/
#      On main at 388ef0b this reports 79 declared / 79 load-bearing / 0 stale.
#   2. After the scrub branch exists, to get the exact retirable list:
#        scripts/gitleaksignore-audit.sh --ref <scrub-branch> --prefix docs/ -v
#      Delete ONLY the lines it prints under `-- stale --`, in their own commit,
#      separate from the prose change, so the two revert independently.
#   3. Re-run step 2 afterwards; it should report 0 stale and 0 unsilenced.
#
# Do NOT substitute a full-history `gitleaks git` scan for this. That scan
# reports every already-reviewed historical string in the repo's past — 2573
# findings on main at 388ef0b, before deleting anything — so it is red no matter
# what you do and can never distinguish a safe deletion from an unsafe one.
#
# EXIT CODES
#   0  every declared fingerprint is load-bearing and nothing is unsilenced
#   1  STALE fingerprints exist — there is cleanup to do
#   2  UNSILENCED findings exist — the gate is primed to go red
#   3  CANNOT VERIFY — gitleaks or jq missing, or the export failed
#
# Exit 3 is deliberate and fail-closed: "I could not look" must never be
# reported as "all clear".
#
set -uo pipefail

PREFIX=""
REF="HEAD"
SELF_TEST=0
VERBOSE=0

usage() {
  cat <<'EOF'
Usage: scripts/gitleaksignore-audit.sh [options]

  --prefix <path>   only audit fingerprints whose path starts with this
                    (e.g. --prefix docs/). Default: the whole tree.
  --ref <ref>       git ref to export and audit. Default: HEAD.
  --self-test       run the built-in negative control and exit.
  -v, --verbose     list every fingerprint in each class.
  -h, --help        this text.

Exit: 0 exact, 1 stale present, 2 unsilenced present, 3 cannot verify.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --ref)    REF="${2:-}"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 3 ;;
  esac
done

for tool in gitleaks jq git; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "CANNOT VERIFY: '$tool' is not installed. Refusing to report a clean" >&2
    echo "               result from a scan that did not run." >&2
    exit 3
  }
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "CANNOT VERIFY: not inside a git repository." >&2; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- export the tracked tree at REF -----------------------------------------
mkdir -p "$WORK/tree"
if ! git -C "$REPO_ROOT" archive "$REF" | tar -x -C "$WORK/tree"; then
  echo "CANNOT VERIFY: could not export tree at '$REF'." >&2; exit 3
fi
[ -f "$WORK/tree/.gitleaks.toml" ] || {
  echo "CANNOT VERIFY: no .gitleaks.toml at '$REF'." >&2; exit 3; }
[ -f "$WORK/tree/.gitleaksignore" ] || {
  echo "CANNOT VERIFY: no .gitleaksignore at '$REF'." >&2; exit 3; }

# ---- self-test (negative control) -------------------------------------------
# A classifier that always answers "LOAD-BEARING" would satisfy the audit on
# today's tree, because today every fingerprint happens to be load-bearing.
# So: plant a fingerprint that CANNOT correspond to a finding (line 999999) and
# require the script to call it STALE, and delete a real fingerprint and require
# the script to call the exposed finding UNSILENCED. If either fails, the
# classifier is not measuring anything.
if [ "$SELF_TEST" -eq 1 ]; then
  echo "== negative control =="
  real="$(grep -m1 '^[^#[:space:]]' "$WORK/tree/.gitleaksignore")"
  [ -n "$real" ] || { echo "CANNOT VERIFY: no fingerprints to test with." >&2; exit 3; }
  probe_file="${real%%:*}"
  echo "-- control A: a fingerprint that can match nothing must be called STALE"
  printf '%s:live-domain-apex:999999\n' "$probe_file" >> "$WORK/tree/.gitleaksignore"
  echo "-- control B: removing '$real' must surface it as UNSILENCED"
  grep -vxF "$real" "$WORK/tree/.gitleaksignore" > "$WORK/ign.tmp" && \
    mv "$WORK/ign.tmp" "$WORK/tree/.gitleaksignore"
  PREFIX="${probe_file%%/*}/"
  VERBOSE=1
fi

# ---- scan the subtree twice --------------------------------------------------
# Choose the narrowest repo-relative scan source that still covers PREFIX, so
# reported paths stay repo-relative (footgun 2) and the scan stays fast.
scan_src="."
if [ -n "$PREFIX" ]; then
  top="${PREFIX%%/*}"
  [ -e "$WORK/tree/$top" ] && scan_src="$top"
fi

# FAIL CLOSED. The first cut of this function ran gitleaks inside
# `( … >/dev/null 2>&1 )`, threw the exit status away, and substituted an empty
# report (`[]`) whenever nothing was written. That is not a harmless default
# here — it is the most dangerous one this script could pick. With no live
# findings, EVERY declared fingerprint classifies as STALE, and this script's
# own documented workflow is "delete ONLY the lines it prints under
# `-- stale --`". A scanner that merely failed to start would therefore instruct
# the operator to delete all 79 suppressions and un-silence 79 real leaks.
# Demonstrated 2026-07-27 with a stub scanner that exits 2 and writes nothing:
# 79 declared / 0 live / 79 STALE "IOU paid — safe to retire".
#
# gitleaks exit codes: 0 = no leaks, 1 = leaks found, anything else = error.
scan() {  # $1 = tree dir, $2 = output json
  local rc=0
  ( cd "$1" && gitleaks dir "$scan_src" \
      --config=.gitleaks.toml --redact --no-banner \
      --report-format=json --report-path="$2" >/dev/null 2>&1 ) || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    echo "CANNOT VERIFY: gitleaks exited $rc scanning '$1' (scanner error, not a" >&2
    echo "               verdict). A malformed .gitleaks.toml is the usual cause." >&2
    echo "               Refusing to classify fingerprints from a scan that failed." >&2
    exit 3
  fi
  if [ ! -s "$2" ]; then
    echo "CANNOT VERIFY: gitleaks wrote no report scanning '$1'. Refusing to read" >&2
    echo "               an absent report as 'no findings' — that would classify" >&2
    echo "               every fingerprint STALE and invite deleting all of them." >&2
    exit 3
  fi
  if ! jq -e 'type == "array"' "$2" >/dev/null 2>&1; then
    echo "CANNOT VERIFY: the gitleaks report at '$2' is not a JSON array." >&2
    exit 3
  fi
}

# "live" = what the rules find with NO fingerprints suppressing anything.
# The file is physically removed, not flag-overridden (footgun 1).
cp -a "$WORK/tree" "$WORK/tree-nofp"
rm -f "$WORK/tree-nofp/.gitleaksignore"
scan "$WORK/tree-nofp" "$WORK/live.json"
scan "$WORK/tree"      "$WORK/silenced.json"

jq -r '.[] | "\(.File):\(.RuleID):\(.StartLine)"' "$WORK/live.json" \
  | sort -u > "$WORK/live.txt"
jq -r '.[] | "\(.File):\(.RuleID):\(.StartLine)"' "$WORK/silenced.json" \
  | sort -u > "$WORK/silenced.txt"
grep '^[^#[:space:]]' "$WORK/tree/.gitleaksignore" | sort -u > "$WORK/declared.txt"

if [ -n "$PREFIX" ]; then
  for f in live declared; do
    grep "^$PREFIX" "$WORK/$f.txt" > "$WORK/$f.f" || true
    mv "$WORK/$f.f" "$WORK/$f.txt"
  done
fi

comm -12 "$WORK/declared.txt" "$WORK/live.txt" > "$WORK/loadbearing.txt"
comm -23 "$WORK/declared.txt" "$WORK/live.txt" > "$WORK/stale.txt"
comm -13 "$WORK/declared.txt" "$WORK/live.txt" > "$WORK/unsilenced.txt"

n_declared=$(wc -l < "$WORK/declared.txt")
n_live=$(wc -l < "$WORK/live.txt")
n_load=$(wc -l < "$WORK/loadbearing.txt")
n_stale=$(wc -l < "$WORK/stale.txt")
n_unsil=$(wc -l < "$WORK/unsilenced.txt")

# ---- report ------------------------------------------------------------------
scope="${PREFIX:-<whole tree>}"
echo "gitleaksignore audit — ref=$REF scope=$scope (gitleaks $(gitleaks version 2>/dev/null))"
echo "  declared fingerprints : $n_declared"
echo "  live findings         : $n_live"
echo "  LOAD-BEARING          : $n_load   (deleting these re-exposes a real hit)"
echo "  STALE                 : $n_stale   (IOU paid — safe to retire)"
echo "  UNSILENCED            : $n_unsil   (no fingerprint; gate primed to go red)"

if [ "$VERBOSE" -eq 1 ]; then
  for cls in stale unsilenced loadbearing; do
    if [ -s "$WORK/$cls.txt" ]; then
      echo; echo "-- ${cls} --"; cat "$WORK/$cls.txt"
    fi
  done
fi

# Sanity assertion: with the ignore file in place nothing in scope should
# survive, otherwise the two scans disagree and the classification is unsound.
# Skipped under --self-test, where a fingerprint is removed ON PURPOSE and a
# surviving finding is the expected result, not a contradiction.
n_sil_scope=$(if [ -n "$PREFIX" ]; then grep -c "^$PREFIX" "$WORK/silenced.txt" || true;
              else wc -l < "$WORK/silenced.txt"; fi)
if [ "$SELF_TEST" -eq 0 ] && [ "${n_sil_scope:-0}" -ne 0 ]; then
  echo
  echo "CANNOT VERIFY: $n_sil_scope finding(s) survive WITH .gitleaksignore applied."
  echo "               The two scans disagree; do not trust the classification."
  exit 3
fi

if [ "$SELF_TEST" -eq 1 ]; then
  echo
  rc=0
  if [ "$n_stale" -ge 1 ]; then echo "control A PASS: planted impossible fingerprint classified STALE"
  else echo "control A FAIL: planted impossible fingerprint was not called STALE"; rc=1; fi
  if [ "$n_unsil" -ge 1 ]; then echo "control B PASS: removed fingerprint surfaced as UNSILENCED"
  else echo "control B FAIL: removed fingerprint did not surface"; rc=1; fi
  [ "$rc" -eq 0 ] && echo "negative control PASSED — the classifier measures something." \
                  || echo "negative control FAILED — do not trust this script."
  exit "$rc"
fi

[ "$n_unsil" -gt 0 ] && exit 2
[ "$n_stale" -gt 0 ] && exit 1
exit 0
