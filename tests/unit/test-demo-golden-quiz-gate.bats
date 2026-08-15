#!/usr/bin/env bats
#
# `pl demo golden` must REFUSE to seal a catalogue whose every depthcontent
# row has lost its quiz items — the pre-e9c596f build_json.py strip class
# (1,671 quiz items across 213 catalogue LPs on ssd; audited build order
# step 1, 2026-08-15).
#
# THE LOSS CLASS THIS PINS. A golden is a reference image (ops#145): the
# nightly reset restores it verbatim, and the box wrapper deliberately has no
# reseed step. A capture taken while the catalogue's quiz_items are stripped
# therefore FREEZES the loss — every reset re-installs the quiz-less
# catalogue, nothing goes red, and the defect survives until a human notices
# a lesson page with no "Check your understanding" block. The config twin of
# this gate (demo_parity_check_live, ops#145) exists for exactly the same
# reason; this one measures CONTENT, on the CAPTURED DUMP — the exact bytes a
# reset will restore — never on the site, so it cannot pass on bytes it did
# not check.
#
# Scope pinned here: only the systematic strip refuses. No depthcontent rows
# at all (the Drupal half, a Moodle site without the module) passes; SOME
# quiz-bearing rows (authoring in progress) passes; quiz items in a SIBLING
# table (depthcontent_fb_state) must not mask a stripped catalogue.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/quizgate.XXXXXX")"
    export PROJECT_ROOT="$REPO_ROOT"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/ui.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/demo.sh"
}
teardown() { rm -rf "$TMP"; }

# _mkdump <name> <<'SQL' — gzip a fixture dump. Fixture bytes mirror the real
# mysqldump shape measured on live ssd goldens 2026-08-15: one row per line,
# JSON double quotes escaped as \" , and both content encodings seen in the
# wild (compact `\":[{\"` and pretty `\": [\n    {\"`).
_mkdump() { gzip -c > "$TMP/$1"; }

_stripped_dump() { # every depthcontent row quiz-less: empty array or key absent
    _mkdump stripped.sql.gz <<'SQL'
INSERT INTO `mdl_depthcontent` VALUES
(1,80,'LP one','',1,'A1.01','{\"id\":\"A1.01\",\"quiz_items\":[],\"depths\":{}}',0),
(2,80,'LP two','',1,'A1.02','{\"id\":\"A1.02\",\"depths\":{}}',0);
INSERT INTO `mdl_user` VALUES
(1,'admin','x');
SQL
}

_healthy_dump() { # one compact + one pretty quiz-bearing row
    _mkdump healthy.sql.gz <<'SQL'
INSERT INTO `mdl_depthcontent` VALUES
(1,80,'LP one','',1,'A1.01','{\"id\":\"A1.01\",\"quiz_items\":[{\"q\":\"Who?\"}]}',0),
(2,80,'LP two','',1,'A1.02','{\"id\":\"A1.02\",\"quiz_items\": [\n    {\n      \"q\": \"What?\"}]}',0),
(3,80,'LP three','',1,'A1.03','{\"id\":\"A1.03\",\"quiz_items\":[]}',0);
SQL
}

_no_dc_dump() { # no depthcontent table at all (Drupal half / module absent)
    _mkdump nodc.sql.gz <<'SQL'
INSERT INTO `mdl_user` VALUES
(1,'admin','x');
INSERT INTO `users` VALUES
(1,'drupaluser');
SQL
}

_sibling_only_dump() { # stripped catalogue + quiz-bearing SIBLING table
    _mkdump sibling.sql.gz <<'SQL'
INSERT INTO `mdl_depthcontent` VALUES
(1,80,'LP one','',1,'A1.01','{\"id\":\"A1.01\",\"quiz_items\":[]}',0);
INSERT INTO `mdl_depthcontent_fb_state` VALUES
(1,80,'A1.01','{\"candidates\":\"quiz_items\":[{\"q\":\"decoy\"}]}');
SQL
}

@test "RED-PROOF: an all-stripped catalogue dump is REFUSED, by name" {
    _stripped_dump
    run demo_golden_quiz_gate "$TMP/stripped.sql.gz" "" "$TMP/no-payload.json"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'REFUSED'
    echo "$output" | grep -qi 'no quiz items'
}

@test "a healthy dump passes and reports the measured count" {
    _healthy_dump
    run demo_golden_quiz_gate "$TMP/healthy.sql.gz" "" "$TMP/no-payload.json"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '2 rows carry quiz items'
}

@test "a dump with no depthcontent rows passes (gate not applicable)" {
    _no_dc_dump
    run demo_golden_quiz_gate "$TMP/nodc.sql.gz" "" "$TMP/no-payload.json"
    [ "$status" -eq 0 ]
}

@test "quiz items in a SIBLING depthcontent_* table do not mask a stripped catalogue" {
    _sibling_only_dump
    run demo_golden_quiz_gate "$TMP/sibling.sql.gz" "" "$TMP/no-payload.json"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'REFUSED'
}

@test "a missing dump is CANNOT VERIFY (2), never a pass" {
    run demo_golden_quiz_gate "$TMP/absent-$$.sql.gz"
    [ "$status" -eq 2 ]
    echo "$output" | grep -qi 'CANNOT VERIFY'
}

@test "a corrupt dump is CANNOT VERIFY (2), never a pass" {
    _healthy_dump
    head -c 40 "$TMP/healthy.sql.gz" > "$TMP/corrupt.sql.gz"
    run demo_golden_quiz_gate "$TMP/corrupt.sql.gz"
    [ "$status" -eq 2 ]
    echo "$output" | grep -qi 'CANNOT VERIFY'
}

@test "override env captures anyway, loudly, and only with a reason" {
    _stripped_dump
    NWP_DEMO_GOLDEN_ALLOW_EMPTY_QUIZ='seeding a brand-new catalogue' \
        run demo_golden_quiz_gate "$TMP/stripped.sql.gz" "" "$TMP/no-payload.json"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'OVERRIDDEN'
    echo "$output" | grep -q 'seeding a brand-new catalogue'
}

# ── Payload-aware mode ──────────────────────────────────────────────────────
# The canonical payload (servers/live/demo/ssd-catalogue-content.json) DECLARES
# which LPs must carry quiz items. The real 2026-08-02 loss-class golden holds
# 3 quiz-bearing demo.prayer rows while ALL 213 catalogue rows are stripped —
# an any-row heuristic passes it. With the payload, the gate must refuse.

_payload() {
    cat > "$TMP/payload.json" <<'JSON'
{
  "_meta": {"note": "fixture"},
  "content": {
    "A1.01": {"quiz_items": [{"q": "Who?"}]},
    "A1.02": {"quiz_items": [{"q": "What?"}]},
    "A1.03": {"quiz_items": []}
  }
}
JSON
}

_decoy_dump() { # catalogue rows stripped; only a non-catalogue demo row has quizzes
    _mkdump decoy.sql.gz <<'SQL'
INSERT INTO `mdl_depthcontent` VALUES
(1,80,'LP one','',1,'A1.01','{\"id\":\"A1.01\",\"quiz_items\":[]}',0),
(2,80,'LP two','',1,'A1.02','{\"id\":\"A1.02\"}',0),
(3,61,'Praying','',1,'demo.prayer.1','{\"id\":\"demo.prayer.1\",\"quiz_items\":[{\"q\":\"decoy\"}]}',0);
SQL
}

@test "RED-PROOF v2: catalogue rows stripped + quiz-bearing demo row is STILL REFUSED (the real 2026-08-02 shape)" {
    _payload; _decoy_dump
    run demo_golden_quiz_gate "$TMP/decoy.sql.gz" "" "$TMP/payload.json"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'REFUSED'
    echo "$output" | grep -q 'A1.01'
}

@test "payload mode passes when every declared LP present in the dump carries its quiz items" {
    _payload
    _mkdump declared-ok.sql.gz <<'SQL'
INSERT INTO `mdl_depthcontent` VALUES
(1,80,'LP one','',1,'A1.01','{\"id\":\"A1.01\",\"quiz_items\":[{\"q\":\"Who?\"}]}',0),
(2,80,'LP two','',1,'A1.02','{\"id\":\"A1.02\",\"quiz_items\": [\n    {\n      \"q\": \"What?\"}]}',0),
(3,80,'LP three','',1,'A1.03','{\"id\":\"A1.03\",\"quiz_items\":[]}',0);
SQL
    run demo_golden_quiz_gate "$TMP/declared-ok.sql.gz" "" "$TMP/payload.json"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'quiz content present'
}

@test "an LP the payload declares but the dump does not contain is NOT a quiz refusal (absence is a seeding defect, not this gate's)" {
    _payload
    _mkdump declared-absent.sql.gz <<'SQL'
INSERT INTO `mdl_depthcontent` VALUES
(1,80,'LP one','',1,'A1.01','{\"id\":\"A1.01\",\"quiz_items\":[{\"q\":\"Who?\"}]}',0);
SQL
    run demo_golden_quiz_gate "$TMP/declared-absent.sql.gz" "" "$TMP/payload.json"
    [ "$status" -eq 0 ]
}

@test "RED-PROOF v3: a READABLE payload declaring ZERO quiz-bearing LPs must say so LOUDLY before falling back" {
    # !453 follow-up. Proven against the merged gate with this exact probe:
    # {"content":{"A1.01":{"quiz_items":[]}}} against the strip-era decoy dump
    # passed RC=0 with the same 'quiz content present' line a healthy capture
    # prints — a payload that gives the gate NOTHING to measure silently
    # downgraded it to the weak any-row heuristic, and nothing said so.
    printf '%s' '{"content":{"A1.01":{"quiz_items":[]}}}' > "$TMP/empty-expected.json"
    _decoy_dump
    run demo_golden_quiz_gate "$TMP/decoy.sql.gz" "" "$TMP/empty-expected.json"
    [ "$status" -eq 0 ]   # the fallback still rules the verdict…
    echo "$output" | grep -qi 'ZERO quiz-bearing'   # …but the downgrade must be loud
    echo "$output" | grep -qi 'any-row'
}

@test "documented limitation: a declared LP whose pointid the row-matcher cannot see is INVISIBLE to payload mode" {
    # The awk pidre sees only pointids in [A-Za-z0-9._-]+ sitting immediately
    # before the '{'-opening content column. A row whose pointid falls outside
    # that alphabet contributes DCSEEN but no per-LP verdict, so payload mode
    # treats it as absent-from-dump (ignored) even when its quiz_items are
    # stripped — this fixture passes TODAY and pins the blind spot so a future
    # matcher change surfaces here. (Real ssd pointids all fit the alphabet.)
    printf '%s' '{"content":{"A1;01":{"quiz_items":[{"q":"Who?"}]}}}' > "$TMP/odd-payload.json"
    _mkdump odd.sql.gz <<'SQL'
INSERT INTO `mdl_depthcontent` VALUES
(1,80,'LP odd','',1,'A1;01','{\"id\":\"A1;01\",\"quiz_items\":[]}',0),
(2,80,'LP two','',1,'A1.02','{\"id\":\"A1.02\",\"quiz_items\":[{\"q\":\"x\"}]}',0);
SQL
    run demo_golden_quiz_gate "$TMP/odd.sql.gz" "" "$TMP/odd-payload.json"
    [ "$status" -eq 0 ]
}

@test "an unreadable payload falls back to the any-row heuristic, loudly" {
    _healthy_dump
    run demo_golden_quiz_gate "$TMP/healthy.sql.gz" "" "$TMP/absent-payload-$$.json"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'payload'
}

@test "the gate is WIRED into cmd_golden_live (an unwired gate is the inert-guard class)" {
    # ops#214: a guard that exists but is never called has a green history and
    # no effect. Pin the call site: cmd_golden_live must invoke the gate
    # between pulling the dump back and writing the manifest.
    awk '/^cmd_golden_live\(\)/,/^}/' "${REPO_ROOT}/scripts/commands/demo.sh" \
        | grep -q 'demo_golden_quiz_gate'
}
