#!/bin/bash
################################################################################
# lib/sensitive-paths.sh — ONE definition of CLAUDE.md's "Sensitive File Paths".
#
# WHY THIS FILE EXISTS
#   Two things already claimed to know which paths need two-person approval:
#   CLAUDE.md's "Sensitive File Paths" bullet list (the standing order that
#   humans and agents read) and a hardcoded SENSITIVE_PATTERNS array inside
#   scripts/ci/review-marker-gate.sh (the thing that actually ran). A second
#   copy of a security list is a second copy that can silently fall behind the
#   first — and the copy nobody reads is the one that gates the merge.
#
#   So the list is not copied. It is DERIVED from CLAUDE.md at run time: add a
#   path to the standing order and every gate in this repo covers it on the next
#   pipeline, with no code change and nothing to remember.
#
# FAIL-CLOSED
#   If CLAUDE.md is missing, or its "Sensitive File Paths" section cannot be
#   parsed, or the section yields zero globs, these functions return 2 and print
#   nothing. A caller MUST treat rc=2 as "cannot verify" and refuse — never as
#   "no sensitive paths touched". An unreadable standing order is not an empty
#   standing order.
#
# PROVIDES
#   nwp_sensitive_globs                → one CLAUDE.md glob per line
#   nwp_sensitive_patterns             → one ERE per line (glob-derived)
#   nwp_sensitive_filter [file...]     → echoes only the paths that match
#                                        (reads stdin when given no arguments)
#
# CONFIG
#   NWP_CLAUDE_MD   override the standing-order file (tests use this)
################################################################################

# Resolve the standing order. Callers may pre-set PROJECT_ROOT.
if [ -z "${PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
fi
: "${NWP_CLAUDE_MD:=$PROJECT_ROOT/CLAUDE.md}"

# nwp_sensitive_globs — the backticked globs under "### Sensitive File Paths".
#
# Deliberately narrow parsing: only `- \`glob\` ...` bullet lines inside that one
# section count. Prose in the section is ignored; the section ends at the next
# heading. Nothing else in CLAUDE.md can accidentally become a merge gate.
nwp_sensitive_globs() {
  [ -r "$NWP_CLAUDE_MD" ] || return 2
  local out
  out=$(awk '
    /^###[[:space:]]+Sensitive File Paths[[:space:]]*$/ { insec = 1; next }
    insec && /^#{1,6}[[:space:]]/ { insec = 0 }
    insec && /^-[[:space:]]+`[^`]+`/ {
      line = $0
      sub(/^-[[:space:]]+`/, "", line)
      sub(/`.*$/, "", line)
      if (line != "") print line
    }
  ' "$NWP_CLAUDE_MD" 2>/dev/null)
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

# _nwp_glob_to_ere <glob> — the conversion, kept in one auditable place.
#
#   **/x        → (^|/)x$          any depth
#   dir/**      → ^dir/            everything under a directory
#   a/b*.sh     → ^a/b[^/]*\.sh$   interior * does not cross a path separator
#   a/b*        → ^a/b.*$          a TRAILING * is greedy on purpose: CLAUDE.md's
#                                  `lib/auth*` means "the auth code", and a
#                                  narrower reading would quietly drop
#                                  lib/auth/whatever.sh out of the gate
#   name        → (^|/)name$       a bare filename is sensitive wherever it sits
#                                  (this is why every settings.php and every
#                                  composer.json in the tree is covered, which
#                                  matches the behaviour the old hardcoded list
#                                  already had)
_nwp_glob_to_ere() {
  local g="${1:-}" prefix suffix body
  [ -n "$g" ] || return 1

  # Directory form: dir/** — match everything beneath it.
  if [[ "$g" == */\*\* ]]; then
    body="${g%/\*\*}"
    printf '^%s/' "$(_nwp_ere_escape "$body")"
    return 0
  fi

  if [[ "$g" == \*\*/* ]]; then
    prefix='(^|/)'
    g="${g#\*\*/}"
  elif [[ "$g" == */* ]]; then
    prefix='^'
  else
    prefix='(^|/)'
  fi

  # A trailing * becomes .* (crosses separators); interior * becomes [^/]*.
  if [[ "$g" == *\* ]]; then
    g="${g%\*}"
    suffix='.*$'
  else
    suffix='$'
  fi

  body="$(_nwp_ere_escape "$g")"
  body="${body//\*/[^/]*}"
  printf '%s%s%s' "$prefix" "$body" "$suffix"
}

# Escape ERE metacharacters, leaving `*` alone (the caller expands it).
_nwp_ere_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//./\\.}"
  s="${s//+/\\+}"
  s="${s//\?/\\?}"
  s="${s//(/\\(}"
  s="${s//)/\\)}"
  s="${s//[/\\[}"
  s="${s//]/\\]}"
  s="${s//\{/\\\{}"
  s="${s//\}/\\\}}"
  s="${s//^/\\^}"
  s="${s//\$/\\\$}"
  s="${s//|/\\|}"
  printf '%s' "$s"
}

# nwp_sensitive_patterns — one ERE per line. rc=2 when the list cannot be read.
nwp_sensitive_patterns() {
  local globs g ere
  globs=$(nwp_sensitive_globs) || return 2
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    ere=$(_nwp_glob_to_ere "$g") || continue
    printf '%s\n' "$ere"
  done <<<"$globs"
}

# nwp_sensitive_filter [file...] — echo only the paths that are sensitive.
# With no arguments, reads one path per line from stdin.
# rc: 0 = ran (matches may be zero) · 2 = could not read the standing order.
nwp_sensitive_filter() {
  local -a pats=() files=()
  local p f
  while IFS= read -r p; do [ -n "$p" ] && pats+=("$p"); done < <(nwp_sensitive_patterns)
  [ "${#pats[@]}" -gt 0 ] || return 2

  if [ "$#" -gt 0 ]; then
    files=("$@")
  else
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done
  fi

  for f in "${files[@]}"; do
    for p in "${pats[@]}"; do
      if printf '%s\n' "$f" | grep -qE "$p"; then
        printf '%s\n' "$f"
        break
      fi
    done
  done
  return 0
}
