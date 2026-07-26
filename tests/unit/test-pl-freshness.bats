#!/usr/bin/env bats
#
# test-pl-freshness.bats — item C, "pl must know, and say, when its own
# checkout is behind its remote".
#
# WHY THIS FILE EXISTS
#   /usr/local/bin/pl is a symlink into ONE shared checkout, and that checkout
#   is the only code path for every `pl secrets audit`, `pl rag`,
#   `pl deploy-gate` and every impact/fate manifest on this machine. Until now
#   `pl` had no idea whether that checkout was current: VERSION is a hardcoded
#   string, so `pl version` reported "0.30.0" identically on a checkout at
#   origin/main and on one 40 commits behind it. An operator reading a green
#   oversight surface could not tell which code produced it.
#
# WHAT THIS SUITE IS GUARDING AGAINST — BOTH FAILURE DIRECTIONS
#   The check is trivial to "pass" in two useless ways, so both are asserted:
#
#     TOO QUIET — an implementation that prints nothing, ever, satisfies every
#       silence case below. Case (a) and case (e) are the negative control for
#       that: they are the ONLY cases that demand output, and they differ from
#       the silent cases only in the state of the repository, never in the
#       flags or environment passed to pl.
#
#     TOO LOUD — an implementation that always prints "you may be behind"
#       satisfies case (a) and fails (b), (c1..c3), (d1..d3) and (f). The
#       pinned-checkout cases (c*) are the specific ones a naive
#       `rev-list --count HEAD..@{u}` implementation gets wrong: on a detached
#       HEAD or a tag checkout `@{u}` either fails or is meaningless, and
#       nagging an operator who pinned on purpose trains them to ignore it.
#
#   Two further properties are load-bearing and asserted separately:
#     NO NETWORK  — the banner must never fetch (case g: `git fetch` must not
#                   appear in the recorded git calls; a repo whose upstream has
#                   moved but which has NOT fetched must stay silent, because
#                   the only honest thing pl can say is what is already local).
#     FAIL OPEN   — a broken freshness check must never be the thing that stops
#                   an emergency `pl rollback` (cases d1..d3).
#
# METHOD
#   Every case runs the REAL `pl` launcher, copied into a throwaway git repo
#   built in $BATS_TEST_TMPDIR, with `lib/` and `scripts/` symlinked back to
#   the real tree. `pl` resolves SCRIPT_DIR from its own location, so the copy
#   makes the temp repo the checkout under test. The real checkout is never
#   touched and is never the subject of an assertion — a test that asserted
#   against ~/nwp would report a different verdict every time someone pulled.
#
#   git calls are recorded by a shim placed first on PATH; the shim execs the
#   real git, so behaviour is unchanged and only observation is added.
#
# NO SKIPS. tests/.skip-budget sets unit=0. Nothing here may `skip`: in
# particular the fail-open cases deliberately corrupt the repository rather
# than `chmod 000 .git`, because chmod does not stop uid 0 and CI runs as root
# — a case that quietly degrades to a skip on the runner is the same disease
# this repo's skip budget exists to stop.

setup() {
    REAL_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache"
    export NO_COLOR=1
    GIT_LOG="${BATS_TEST_TMPDIR}/git-calls.log"
    : > "$GIT_LOG"
    SHIM="${BATS_TEST_TMPDIR}/shim"
    mkdir -p "$SHIM"
    REAL_GIT="$(command -v git)"
    {
        echo '#!/usr/bin/env bash'
        echo "printf '%s\\n' \"\$*\" >> '${GIT_LOG}'"
        echo "exec '${REAL_GIT}' \"\$@\""
    } > "$SHIM/git"
    chmod +x "$SHIM/git"
}

# git with a deterministic identity — the workstation and the CI runner do not
# share a gitconfig, and a global commit.gpgsign would break repo construction.
_g() {
    command git -c user.email=t@example.invalid -c user.name=t \
                -c init.defaultBranch=main -c commit.gpgsign=false \
                -c protocol.file.allow=always "$@"
}

# Build: bare origin + a work clone that pushes + CO, the checkout under test.
#   $1 = how many commits origin gains AFTER CO was cloned
#   $2 = "fetch" to let CO learn about them (so CO is genuinely N behind),
#        anything else to leave CO ignorant (so CO must stay silent)
_make_checkout() {
    local ahead="${1:-0}" learn="${2:-fetch}"
    ORIGIN="${BATS_TEST_TMPDIR}/origin.git"
    WORK="${BATS_TEST_TMPDIR}/work"
    CO="${BATS_TEST_TMPDIR}/co"
    _g init --quiet --bare "$ORIGIN"
    _g clone --quiet "$ORIGIN" "$WORK" 2>/dev/null
    echo base > "$WORK/f"
    _g -C "$WORK" add f
    _g -C "$WORK" commit -qm base
    _g -C "$WORK" push -q -u origin main
    _g clone --quiet "$ORIGIN" "$CO"
    local i
    for ((i = 0; i < ahead; i++)); do
        echo "c$i" >> "$WORK/f"
        _g -C "$WORK" commit -qam "c$i"
    done
    [ "$ahead" -gt 0 ] && _g -C "$WORK" push -q origin main
    [ "$learn" = "fetch" ] && _g -C "$CO" fetch -q origin
    _install_pl "$CO"
}

_install_pl() {
    cp "$REAL_ROOT/pl" "$1/pl"
    ln -s "$REAL_ROOT/lib" "$1/lib"
    ln -s "$REAL_ROOT/scripts" "$1/scripts"
}

# Run the checkout's pl, capturing stdout and stderr SEPARATELY (the banner
# belongs on stderr; a banner on stdout would corrupt anything parsing
# `pl version`, which is the whole reason the stream matters).
_pl() {
    local errf="${BATS_TEST_TMPDIR}/err.$$.$RANDOM"
    set +e
    OUT="$(env -u NWP_FRESHNESS_SHOWN -u NWP_NO_FRESHNESS_CHECK \
              PATH="${SHIM}:${PATH}" \
              XDG_CACHE_HOME="$XDG_CACHE_HOME" NO_COLOR=1 \
              "$CO/pl" "$@" 2>"$errf")"
    STATUS=$?
    set -e
    ERR="$(cat "$errf")"
    rm -f "$errf"
}

_git_calls() { grep -c -- "$1" "$GIT_LOG" || true; }

# ---------------------------------------------------------------------------
# (a) behind its upstream → exactly one honest stderr line, exit still 0
#     NEGATIVE CONTROL for a check that simply never speaks.
# ---------------------------------------------------------------------------
@test "(a) checkout 3 commits behind upstream says so, once, on stderr, exit 0" {
    _make_checkout 3 fetch
    _pl version

    [ "$STATUS" -eq 0 ]
    [ "$OUT" = "NWP CLI (pl) version 0.30.0" ]
    [ -n "$ERR" ]
    [ "$(printf '%s\n' "$ERR" | wc -l)" -eq 1 ]
    [[ "$ERR" == *"3 commits behind"* ]]
    # It must not claim to have just checked the remote — it read local refs.
    [[ "$ERR" == *"as of"* ]]
    # NO_COLOR honoured: no escape sequences.
    [[ "$ERR" != *$'\033'* ]]
}

# ---------------------------------------------------------------------------
# (b) up to date → silence
# ---------------------------------------------------------------------------
@test "(b) checkout level with upstream prints nothing to stderr" {
    _make_checkout 0 fetch
    _pl version
    [ "$STATUS" -eq 0 ]
    [ -z "$ERR" ]
}

# ---------------------------------------------------------------------------
# (c) the pinned-checkout family → silence, always.
# ---------------------------------------------------------------------------
@test "(c1) detached HEAD prints nothing (deliberately pinned)" {
    _make_checkout 3 fetch
    _g -C "$CO" checkout -q --detach HEAD
    _pl version
    [ "$STATUS" -eq 0 ]
    [ -z "$ERR" ]
}

@test "(c2) branch with no upstream prints nothing" {
    _make_checkout 3 fetch
    _g -C "$CO" checkout -q -b local-only
    _pl version
    [ "$STATUS" -eq 0 ]
    [ -z "$ERR" ]
}

@test "(c3) checkout sitting on a tag prints nothing even with an upstream" {
    _make_checkout 3 fetch
    _g -C "$CO" tag v9.9.9
    _pl version
    [ "$STATUS" -eq 0 ]
    [ -z "$ERR" ]
}

# ---------------------------------------------------------------------------
# (d) fail open. A broken check must never be what stops `pl rollback`.
# ---------------------------------------------------------------------------
@test "(d1) corrupt .git (gitdir pointer to nowhere): exit 0, no output at all" {
    _make_checkout 3 fetch
    rm -rf "$CO/.git"
    echo "gitdir: /nonexistent/definitely" > "$CO/.git"
    _pl version
    [ "$STATUS" -eq 0 ]
    [ "$OUT" = "NWP CLI (pl) version 0.30.0" ]
    [ -z "$ERR" ]
}

@test "(d2) .git present but unreadable/garbage: exit 0, no output at all" {
    _make_checkout 3 fetch
    rm -rf "$CO/.git"
    mkdir -p "$CO/.git"
    echo "not a ref" > "$CO/.git/HEAD"
    _pl version
    [ "$STATUS" -eq 0 ]
    [ -z "$ERR" ]
}

@test "(d3) git binary absent entirely: exit 0, no output at all" {
    _make_checkout 3 fetch
    # A PATH with coreutils but NO git. Emptying PATH outright would also
    # remove `dirname`/`readlink`, which pl needs to resolve SCRIPT_DIR — that
    # would make the case pass for a reason unrelated to the freshness check.
    local nogit="${BATS_TEST_TMPDIR}/nogit-bin"
    mkdir -p "$nogit"
    local t p
    for t in dirname readlink basename cat sed grep date stat wc tr mkdir rm find id uname; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$nogit/$t"
    done
    [ ! -e "$nogit/git" ]

    local errf="${BATS_TEST_TMPDIR}/nogit.err"
    set +e
    OUT="$(env -u NWP_FRESHNESS_SHOWN -u NWP_NO_FRESHNESS_CHECK \
              PATH="$nogit" \
              XDG_CACHE_HOME="${XDG_CACHE_HOME}.nogit" NO_COLOR=1 \
              /bin/bash "$CO/pl" version 2>"$errf")"
    STATUS=$?
    set -e
    ERR="$(cat "$errf")"
    [ "$STATUS" -eq 0 ]
    [ "$OUT" = "NWP CLI (pl) version 0.30.0" ]
    [ -z "$ERR" ]
}

# ---------------------------------------------------------------------------
# (e) opt-out honoured — and this is also the TOO-QUIET control's mirror: the
#     same repo that spoke in (a) must fall silent ONLY because of the env var.
# ---------------------------------------------------------------------------
@test "(e) NWP_NO_FRESHNESS_CHECK=1 silences a checkout that is provably behind" {
    _make_checkout 3 fetch
    _pl version
    [[ "$ERR" == *"3 commits behind"* ]]   # same repo, speaks by default

    local errf="${BATS_TEST_TMPDIR}/optout.err"
    set +e
    env -u NWP_FRESHNESS_SHOWN NWP_NO_FRESHNESS_CHECK=1 \
        PATH="${SHIM}:${PATH}" XDG_CACHE_HOME="${XDG_CACHE_HOME}.optout" \
        NO_COLOR=1 "$CO/pl" version >/dev/null 2>"$errf"
    STATUS=$?
    set -e
    [ "$STATUS" -eq 0 ]
    [ ! -s "$errf" ]
}

# ---------------------------------------------------------------------------
# (f) ahead, not behind → silence. Guards against reporting a symmetric diff.
# ---------------------------------------------------------------------------
@test "(f) checkout 2 commits AHEAD of upstream prints nothing" {
    _make_checkout 0 fetch
    echo x >> "$CO/f"; _g -C "$CO" commit -qam x1
    echo y >> "$CO/f"; _g -C "$CO" commit -qam x2
    _pl version
    [ "$STATUS" -eq 0 ]
    [ -z "$ERR" ]
}

# ---------------------------------------------------------------------------
# (g) NEVER fetch on an ordinary invocation. Origin has moved 3 ahead and CO
#     has not fetched: the honest answer is silence, and no network call.
# ---------------------------------------------------------------------------
@test "(g) an ordinary pl call never fetches, and stays silent on unfetched drift" {
    _make_checkout 3 nofetch
    : > "$GIT_LOG"
    _pl version
    [ "$STATUS" -eq 0 ]
    [ -z "$ERR" ]
    [ "$(_git_calls 'fetch')" -eq 0 ]
    [ "$(_git_calls 'ls-remote')" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (h) TTL cache — the second invocation inside the TTL must not re-walk the
#     revision graph. Asserted via the git shim, not by timing.
# ---------------------------------------------------------------------------
@test "(h) second invocation within TTL does not spawn git rev-list" {
    _make_checkout 3 fetch
    : > "$GIT_LOG"
    _pl version
    [[ "$ERR" == *"3 commits behind"* ]]
    local cold_revlist cold_total
    cold_revlist="$(_git_calls 'rev-list')"
    cold_total="$(wc -l < "$GIT_LOG")"
    [ "$cold_revlist" -ge 1 ]

    : > "$GIT_LOG"
    _pl version
    # Still reports — the verdict is cached, not the silence.
    [[ "$ERR" == *"3 commits behind"* ]]
    [ "$(_git_calls 'rev-list')" -eq 0 ]
    # and strictly cheaper overall than the cold path
    [ "$(wc -l < "$GIT_LOG")" -lt "$cold_total" ]
}

# ---------------------------------------------------------------------------
# (i) the cache is invalidated the instant the checkout moves, TTL or no TTL.
# ---------------------------------------------------------------------------
@test "(i) cache is invalidated when HEAD moves" {
    _make_checkout 3 fetch
    _pl version
    [[ "$ERR" == *"3 commits behind"* ]]

    _g -C "$CO" merge -q --ff-only origin/main
    _pl version
    [ -z "$ERR" ]
}

# ---------------------------------------------------------------------------
# (j) the cache must not be written inside the repository — a stray file in
#     the checkout trips the leakage/containment gates and dirties git status.
# ---------------------------------------------------------------------------
@test "(j) freshness cache lives outside the checkout" {
    _make_checkout 3 fetch
    _pl version
    [[ "$ERR" == *"3 commits behind"* ]]
    run bash -c "find '$CO' -maxdepth 2 -name '*freshness*' -print"
    [ -z "$output" ]
    # …and it does exist, under XDG_CACHE_HOME (otherwise (h) proves nothing).
    run bash -c "find '$XDG_CACHE_HOME' -type f -print"
    [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# (k) `pl version --check` is the ONE place allowed to touch the network, and
#     only because it was asked to. Same repo as (g), which was silent.
# ---------------------------------------------------------------------------
@test "(k) pl version --check fetches on request and then reports the drift" {
    _make_checkout 3 nofetch
    : > "$GIT_LOG"
    _pl version --check
    [ "$STATUS" -eq 0 ]
    [ "$(_git_calls 'fetch')" -ge 1 ]
    [[ "$OUT$ERR" == *"3 commits behind"* ]]
}

# ---------------------------------------------------------------------------
# (l) the library itself is syntactically sound and sourceable in isolation.
# ---------------------------------------------------------------------------
@test "(l) lib/pl-freshness.sh parses and defines its entry point" {
    run bash -n "${REAL_ROOT}/lib/pl-freshness.sh"
    [ "$status" -eq 0 ]
    run bash -c "source '${REAL_ROOT}/lib/pl-freshness.sh'; declare -F pl_freshness_banner"
    [ "$status" -eq 0 ]
}
