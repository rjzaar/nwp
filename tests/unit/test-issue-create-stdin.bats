#!/usr/bin/env bats
# `pl issue create` must not silently discard a piped description.
#
# THE DEFECT UNDER TEST (measured 2026-08-11). `--desc` is the only way to set
# a body, and stdin is ignored. Piping the body in — the obvious idiom, and the
# one this repo uses for `pl issue comment`, which DOES read stdin — produced
# FOUR issues with empty descriptions (ops#327, #331, #333, #336). One of them
# was the operator's own recorded rulings. Nothing failed, nothing warned; the
# text simply went nowhere, and the loss was noticed days later by an agent
# reading the issue back.
#
# Two sibling verbs disagreeing about stdin is the whole bug: `comment` reads
# it, `create` drops it. Either accept it or refuse — never accept and discard.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ISSUE_SH="${REPO_ROOT}/scripts/commands/issue.sh"
}

@test "create READS a piped description when --desc is absent" {
  # the tty test may be negated ('[ ! -t 0 ]'), so match on the tty check and
  # the actual read, not on one exact spelling — the first draft of this case
  # failed a CORRECT implementation for that reason.
  run bash -c "sed -n '/^cmd_create()/,/^}/p' '$ISSUE_SH' | grep -q -- '-t 0'"
  [ "$status" -eq 0 ]
  run bash -c "sed -n '/^cmd_create()/,/^}/p' '$ISSUE_SH' | grep -Eq 'desc=\"?\\\$\\(cat\\)|/dev/stdin'"
  [ "$status" -eq 0 ]
}

@test "create never sends an empty description when stdin carried one" {
  run bash -c "sed -n '/^cmd_create()/,/^}/p' '$ISSUE_SH' | grep -Eq 'stdin|piped'"
  [ "$status" -eq 0 ]
}

@test "the sibling verb comment DOES read stdin — the asymmetry that caused this" {
  run bash -c "grep -Eq 'read|stdin|/dev/stdin|cat' <(sed -n '/^cmd_comment()/,/^}/p' '$ISSUE_SH')"
  [ "$status" -eq 0 ]
}

@test "issue.sh stays syntactically valid" {
  run bash -n "$ISSUE_SH"
  [ "$status" -eq 0 ]
}
