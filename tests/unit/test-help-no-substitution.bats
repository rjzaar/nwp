#!/usr/bin/env bats
#
# A `--help` screen must not EXECUTE anything.
#
# WHY THIS EXISTS
#   `pl secrets --help` printed, above its own usage text:
#
#       scripts/commands/secrets.sh: line 3637: audit: command not found
#
#   The help body is a heredoc opened as `<<EOF` (unquoted, because the text
#   interpolates ${BOLD}/${NC}), and a line of prose said "`audit` points here".
#   In an unquoted heredoc backticks are command substitution, so bash ran
#   `audit` while rendering the help.
#
#   Harmless here only by luck. The same construct in a help screen that
#   happened to quote `rm -rf …` or any real command would RUN it, and `--help`
#   is the one thing a person types when they are unsure what a verb does.
#
# WHAT THIS ASSERTS
#   No unquoted heredoc in scripts/commands/ contains a backtick. Quoted
#   heredocs (`<<'EOF'`) are exempt: nothing in them expands. `$(…)` is NOT
#   flagged — `$(basename "$0")` in a usage block is deliberate and common.

setup() {
    ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

# Emit "file:line" for every offending line, or nothing.
_offenders() {
    python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
# `<<EOF` / `<<-EOF` are expanding; `<<'EOF'` / `<<"EOF"` are not.
# `<<<` is a HERESTRING, not a heredoc — matching it made the state machine
# think a heredoc had opened and flag ordinary code for the rest of the file.
open_unquoted = re.compile(r"<<-?(?!<)\s*([A-Za-z_][A-Za-z0-9_]*)\s*$")
open_quoted   = re.compile(r"<<-?(?!<)\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]")
# BACKTICKS ONLY. `$(basename "$0")` in a usage block is deliberate and common;
# flagging it would make this gate noisy, and a noisy gate gets switched off.
# Backticks in an expanding heredoc are almost always prose quotes, which is
# the actual defect: the shell runs the word.
# UNESCAPED backticks only. `\`` inside an expanding heredoc is literal text
# and perfectly safe — most help screens escape correctly, and flagging those
# would report 27 findings where 1 was real.
danger        = re.compile(r"(?<!\\)`")
# SCOPE: scripts/commands/ only — that is where `pl <verb> --help` lives, which
# is the stated risk. A wider sweep produced false positives in scripts/ci
# (this line-based scanner loses heredoc state around embedded awk/python
# blocks and then flags ordinary comments). Reporting those would make the gate
# noisy, and a noisy gate gets switched off — so the scope is narrowed
# deliberately rather than the findings suppressed one by one.
for sub in ("scripts/commands",):
    d = os.path.join(root, sub)
    if not os.path.isdir(d):
        continue
    for dirpath, _, names in os.walk(d):
        for n in sorted(names):
            if not n.endswith(".sh"):
                continue
            path = os.path.join(dirpath, n)
            try:
                lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
            except OSError:
                continue
            term = None
            for i, line in enumerate(lines, 1):
                if term is None:
                    if open_quoted.search(line):
                        m = open_quoted.search(line)
                        # skip to its terminator; nothing inside expands
                        term = ("QUOTED", m.group(1))
                    elif open_unquoted.search(line):
                        m = open_unquoted.search(line)
                        term = ("EXPANDS", m.group(1))
                    continue
                kind, word = term
                if line.strip() == word:
                    term = None
                    continue
                if kind == "EXPANDS" and danger.search(line):
                    print(f"{os.path.relpath(path, root)}:{i}: {line.strip()[:90]}")
PY
}

@test "no unquoted heredoc contains a backtick — a --help must not execute" {
    run _offenders
    [ "$status" -eq 0 ]
    if [ -n "$output" ]; then
        echo "Command substitution inside an EXPANDING heredoc:"
        echo "$output"
        echo ""
        echo "Fix: use plain quotes in prose, or open the heredoc as <<'EOF' if it"
        echo "needs no variable expansion."
        return 1
    fi
}

@test "RED-PROOF: the detector fires on a planted offender" {
    # Without this the case above proves only that the tree is currently quiet,
    # which is indistinguishable from a detector that never looks.
    local tmp; tmp="$(mktemp -d "${BATS_TMPDIR:-/tmp}/helpsub.XXXXXX")"
    mkdir -p "$tmp/scripts/commands"
    cat > "$tmp/scripts/commands/planted.sh" <<'OUTER'
#!/bin/bash
cat <<EOF
  see `audit` for detail
EOF
OUTER
    ROOT="$tmp" run _offenders
    [ -n "$output" ]
    echo "$output" | grep -q 'planted.sh'
    rm -rf "$tmp"
}

@test "NEGATIVE CONTROL: a quoted heredoc with backticks is NOT reported" {
    # <<'EOF' expands nothing, so backticks in it are just characters. Flagging
    # those would make the gate noisy and it would get switched off.
    local tmp; tmp="$(mktemp -d "${BATS_TMPDIR:-/tmp}/helpsub.XXXXXX")"
    mkdir -p "$tmp/scripts/commands"
    cat > "$tmp/scripts/commands/safe.sh" <<'OUTER'
#!/bin/bash
cat <<'EOF'
  see `audit` for detail
EOF
OUTER
    ROOT="$tmp" run _offenders
    [ -z "$output" ]
    rm -rf "$tmp"
}

@test "pl secrets --help renders with no shell diagnostic" {
    run bash -c "cd '$ROOT' && ./pl secrets --help 2>&1"
    echo "$output" | grep -qv 'command not found'
    ! echo "$output" | grep -q 'command not found'
    ! echo "$output" | grep -qE 'secrets\.sh: line [0-9]+:'
    echo "$output" | grep -q 'pl secrets sync'
}
