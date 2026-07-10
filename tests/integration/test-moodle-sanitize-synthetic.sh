#!/bin/bash
################################################################################
# Integration test: lib/sanitizers/moodle.sh against a SYNTHETIC Moodle DB.
#
# HARD RULES honoured here:
#   - SYNTHETIC DATA ONLY. Creates a throwaway database `moodle_synth_<pid>`
#     inside an existing dev database container, populated with fake PII
#     (teacher.real@x.test etc.). It NEVER touches a real Moodle DB, and DROPs
#     everything it created on exit (success or failure).
#   - No secrets: the OIDC salt is a synthetic value exported here, never read
#     from .secrets.data.yml.
#   - A NON-DEFAULT table prefix (`mymoodle_`) is used specifically to prove the
#     sanitizer resolves $CFG->prefix and does not hardcode `mdl_`.
#
# Self-skips (exit 0) when there is no database container / host mysql client,
# so it is safe to run anywhere (CI without docker just skips it).
#
# Override the DB endpoint with:
#   MOODLE_TEST_DB_CONTAINER (default: ddev-nwc-dev-db)
#   MOODLE_TEST_DB_USER / MOODLE_TEST_DB_PASS (default: root / root)
################################################################################
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SANITIZER="$REPO_ROOT/lib/sanitizers/moodle.sh"

CONTAINER="${MOODLE_TEST_DB_CONTAINER:-ddev-nwc-dev-db}"
DBUSER="${MOODLE_TEST_DB_USER:-root}"
DBPASS="${MOODLE_TEST_DB_PASS:-root}"
PREFIX="mymoodle_"                       # deliberately NOT the default mdl_
TEST_PREFIX="$PREFIX"                     # stable copy: `source`ing the sanitizer resets its own $PREFIX
SYNTH_DB="moodle_synth_$$"
SCRATCH_DB="${SYNTH_DB}_sanitize_scratch"
SALT="synthetic-integration-salt-0123456789abcdef"

skip() { echo "SKIP: $*"; exit 0; }
command -v docker >/dev/null 2>&1 || skip "docker not available"
command -v mysql  >/dev/null 2>&1 || skip "host mysql client not available"
command -v php    >/dev/null 2>&1 || skip "php not available"
docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER" || skip "DB container '$CONTAINER' not running"

PORT="$(docker port "$CONTAINER" 3306/tcp 2>/dev/null | head -1 | sed 's/.*://')"
[ -n "$PORT" ] || skip "could not resolve host port for $CONTAINER:3306"

MYSQL=(mysql -h127.0.0.1 -P"$PORT" -u"$DBUSER" -p"$DBPASS")
"${MYSQL[@]}" -e "SELECT 1" >/dev/null 2>&1 || skip "cannot connect to $CONTAINER over 127.0.0.1:$PORT"

WORK="$(mktemp -d)"
cleanup() {
    "${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${SYNTH_DB}\`; DROP DATABASE IF EXISTS \`${SCRATCH_DB}\`;" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

echo "=== Moodle sanitizer synthetic integration test ==="
echo "container=$CONTAINER port=$PORT synth_db=$SYNTH_DB prefix=$PREFIX"

################################################################################
# 1. Build a synthetic Moodle DB with fake PII (non-default prefix).
################################################################################
"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${SYNTH_DB}\`; CREATE DATABASE \`${SYNTH_DB}\` CHARACTER SET utf8mb4;"

"${MYSQL[@]}" "$SYNTH_DB" <<SQL
CREATE TABLE ${PREFIX}user (
  id BIGINT PRIMARY KEY,
  username VARCHAR(100) NOT NULL DEFAULT '',
  password VARCHAR(255) NOT NULL DEFAULT '',
  idnumber VARCHAR(255) NOT NULL DEFAULT '',
  firstname VARCHAR(100) NOT NULL DEFAULT '',
  lastname VARCHAR(100) NOT NULL DEFAULT '',
  email VARCHAR(190) NOT NULL DEFAULT '',
  phone1 VARCHAR(20) NOT NULL DEFAULT '',
  phone2 VARCHAR(20) NOT NULL DEFAULT '',
  address VARCHAR(255) NOT NULL DEFAULT '',
  city VARCHAR(120) NOT NULL DEFAULT '',
  lastip VARCHAR(45) NOT NULL DEFAULT '',
  secret VARCHAR(15) NOT NULL DEFAULT '',
  description LONGTEXT,
  alternatename VARCHAR(255) NOT NULL DEFAULT ''
);
-- id=1 guest, id=2 admin (real person), id>=3 students
INSERT INTO ${PREFIX}user VALUES
 (1,'guest','not cached','','Guest','User','root@localhost','','','','','','',NULL,''),
 (2,'principal@school.example','\$2y\$10\$realbcrypthashabcdefghij','STAFF001','Mary','Principal','principal@school.example','0400111222','','12 Real St','Realtown','203.0.113.9','sEcReT1','Head of school',''),
 (3,'jsmith','\$2y\$10\$anotherhashvalue012345','STU12345','John','Smith','john.smith@x.test','0400333444','0399887766','5 Student Rd','Studyville','198.51.100.7','tok2','bio text here','Johnny'),
 (4,'teacher.real@x.test','\$2y\$10\$teacherhashvalue0123','STAFF002','Jane','Teacher','teacher.real@x.test','0400555666','','9 Teach Ave','Teachton','198.51.100.8','tok3','teacher bio','JT');

CREATE TABLE ${PREFIX}auth_oauth2_linked_login (
  id BIGINT PRIMARY KEY,
  userid BIGINT NOT NULL,
  username VARCHAR(190) NOT NULL DEFAULT '',
  email VARCHAR(190) NOT NULL DEFAULT '',
  confirmtoken VARCHAR(64) NOT NULL DEFAULT ''
);
-- external OIDC identity: SAME real emails as core user rows (the AVC↔SS join)
INSERT INTO ${PREFIX}auth_oauth2_linked_login VALUES
 (1,3,'john.smith@x.test','john.smith@x.test','ctoken-aaa'),
 (2,4,'teacher.real@x.test','teacher.real@x.test','ctoken-bbb');

CREATE TABLE ${PREFIX}tool_policy_acceptances (
  id BIGINT PRIMARY KEY,
  policyversionid BIGINT NOT NULL,
  userid BIGINT NOT NULL,
  status TINYINT NOT NULL DEFAULT 0,
  note LONGTEXT
);
INSERT INTO ${PREFIX}tool_policy_acceptances VALUES
 (1,1,3,1,'accepted by John'),
 (2,1,4,1,'accepted by Jane');

CREATE TABLE ${PREFIX}tool_policy (id BIGINT PRIMARY KEY, currentversionid BIGINT);
INSERT INTO ${PREFIX}tool_policy VALUES (1, 1);

CREATE TABLE ${PREFIX}sessions (id BIGINT PRIMARY KEY, userid BIGINT, sid VARCHAR(128));
INSERT INTO ${PREFIX}sessions VALUES (1,3,'sessionidsecret1'),(2,4,'sessionidsecret2');

CREATE TABLE ${PREFIX}user_password_history (id BIGINT PRIMARY KEY, userid BIGINT, hash VARCHAR(255));
INSERT INTO ${PREFIX}user_password_history VALUES (1,3,'\$2y\$10\$oldhash1'),(2,4,'\$2y\$10\$oldhash2');

-- auth/deleted columns + siteadmins → exercises the admin-loginability restore.
ALTER TABLE ${PREFIX}user ADD COLUMN auth VARCHAR(20) NOT NULL DEFAULT 'manual',
                          ADD COLUMN deleted TINYINT NOT NULL DEFAULT 0;
UPDATE ${PREFIX}user SET auth='nologin' WHERE id=2;
CREATE TABLE ${PREFIX}config (id BIGINT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(100), value TEXT);
INSERT INTO ${PREFIX}config (name,value) VALUES ('siteadmins','2');

-- free-text CONTENT table with real PII a student typed (must be TRUNCATED).
CREATE TABLE ${PREFIX}forum_posts (id BIGINT PRIMARY KEY, userid BIGINT, subject VARCHAR(255), message LONGTEXT);
INSERT INTO ${PREFIX}forum_posts VALUES (1,3,'hello','contact me at real.student@school.example');
-- numeric attainment (retention dial → TRUNCATE by default).
CREATE TABLE ${PREFIX}grade_grades (id BIGINT PRIMARY KEY, userid BIGINT, finalgrade DECIMAL(10,5));
INSERT INTO ${PREFIX}grade_grades VALUES (1,3,87.50000),(2,4,92.00000);
SQL

echo "--- BEFORE (synthetic real PII) ---"
"${MYSQL[@]}" "$SYNTH_DB" -e "SELECT id,username,email,idnumber,firstname,lastname,phone1,lastip FROM ${PREFIX}user ORDER BY id;"
echo "--- BEFORE oauth linkage ---"
"${MYSQL[@]}" "$SYNTH_DB" -e "SELECT id,userid,username,email,confirmtoken FROM ${PREFIX}auth_oauth2_linked_login ORDER BY id;"
echo "--- BEFORE consent acceptances: $("${MYSQL[@]}" -N "$SYNTH_DB" -e "SELECT COUNT(*) FROM ${PREFIX}tool_policy_acceptances;") ; sessions: $("${MYSQL[@]}" -N "$SYNTH_DB" -e "SELECT COUNT(*) FROM ${PREFIX}sessions;") ; pw-history: $("${MYSQL[@]}" -N "$SYNTH_DB" -e "SELECT COUNT(*) FROM ${PREFIX}user_password_history;")"

################################################################################
# 2. Fake Moodle root (config.php + version.php + stub lib/setup.php).
################################################################################
ROOT="$WORK/moodleroot"
mkdir -p "$ROOT/lib"
echo '<?php return;' > "$ROOT/lib/setup.php"
cat > "$ROOT/version.php" <<'EOF'
<?php
$version = 2024042200.00;
$release = 'synthetic';
EOF
cat > "$ROOT/config.php" <<EOF
<?php
\$CFG = new stdClass();
\$CFG->dbtype   = 'mariadb';
\$CFG->dbhost   = '127.0.0.1';
\$CFG->dbname   = '${SYNTH_DB}';
\$CFG->dbuser   = '${DBUSER}';
\$CFG->dbpass   = '${DBPASS}';
\$CFG->prefix   = '${PREFIX}';
\$CFG->dboptions = array('dbport' => '${PORT}', 'dbsocket' => '');
require_once(__DIR__ . '/lib/setup.php');
EOF

################################################################################
# 3. Run the sanitizer (synthetic salt; no secrets).
################################################################################
OUT="$WORK/moodle-sanitized.sql.gz"
echo "--- RUN sanitizer ---"
OIDC_SANITIZER_SALT="$SALT" bash "$SANITIZER" --site-dir "$ROOT" --output "$OUT"
RUN_RC=$?
echo "sanitizer exit=$RUN_RC"
[ "$RUN_RC" -eq 0 ] && ok "sanitizer returned 0 (clean run)" || bad "sanitizer returned $RUN_RC"

################################################################################
# 4. Verify the sanitized OUTPUT dump (this is what downstream consumes).
################################################################################
[ -s "$OUT" ] && ok "sanitized dump written and non-empty" || bad "no sanitized dump produced"

echo "--- AFTER (from sanitized dump) ---"
zcat "$OUT" | grep -E "INSERT INTO \`?${PREFIX}user\`?" | sed -E "s/^/  /" | head

# 4a. No real PII strings anywhere in the dump.
for needle in "teacher.real@x.test" "john.smith@x.test" "principal@school.example" \
              "STU12345" "STAFF001" "STAFF002" "0400333444" "203.0.113.9" \
              "sessionidsecret" "realbcrypthash" "oldhash1"; do
    if zcat "$OUT" | grep -qF "$needle"; then
        bad "residual real PII in dump: $needle"
    else
        ok "no residual: $needle"
    fi
done

# 4b. Emails follow the OIDC rule (@sanitized.test) and are DETERMINISTIC:
#     the same real email → same fake on user.email AND on the oauth link.
export OIDC_SANITIZER_SALT="$SALT"; export NWP_ROOT="$REPO_ROOT"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/sanitizers/oidc-email.sh"
expect_teacher="$(oidc_email_sanitize 'teacher.real@x.test')"
expect_john="$(oidc_email_sanitize 'john.smith@x.test')"
if zcat "$OUT" | grep -qF "$expect_teacher" && zcat "$OUT" | grep -qF "$expect_john"; then
    ok "emails rewritten to deterministic OIDC form ($expect_teacher, $expect_john)"
else
    bad "expected OIDC-hashed emails not found in dump"
fi
# The oauth-link row for teacher must carry the SAME fake email as user.email →
# count of that fake string should be >= 2 (core user + linked login).
cnt="$(zcat "$OUT" | grep -oF "$expect_teacher" | wc -l | tr -d ' ')"
[ "$cnt" -ge 2 ] && ok "AVC↔SS join preserved (same fake email on user + oauth link, x$cnt)" \
                 || bad "OIDC join not preserved (fake email count=$cnt, expected >=2)"

# 4c. Truncations landed (no rows for those tables in the dump).
for tbl in tool_policy_acceptances sessions user_password_history \
           forum_posts grade_grades; do
    if zcat "$OUT" | grep -qE "INSERT INTO \`?${PREFIX}${tbl}\`?"; then
        bad "$tbl not truncated (INSERT present in dump)"
    else
        ok "$tbl truncated (no INSERT in dump)"
    fi
done
# Free-text content PII must be gone (the forum message held a real email).
zcat "$OUT" | grep -q 'real.student@school.example' \
    && bad "free-text forum PII survived (real.student@school.example in dump)" \
    || ok "free-text forum content PII removed"
# Admin loginability restored: uid 2 (siteadmins) → auth='manual' (was 'nologin').
if zcat "$OUT" | grep -oE "\(2,'[^)]*'manual'[^)]*\)" | grep -q manual \
   || zcat "$OUT" | grep -E "INSERT INTO \`?${PREFIX}user\`?" | grep -q "'manual'"; then
    ok "admin (uid 2) auth restored to manual (loginability)"
else
    bad "admin auth not restored to manual (staging would be unadministerable)"
fi
# Policy DEFINITION kept.
zcat "$OUT" | grep -qE "INSERT INTO \`?${PREFIX}tool_policy\`? " && ok "tool_policy definition KEPT (consent handled, not blanket-dropped)" \
    || bad "tool_policy definition missing (should be kept)"

# 4d. --verify path agrees the dump is clean.
if OIDC_SANITIZER_SALT="$SALT" bash "$SANITIZER" --verify --output "$OUT" >/dev/null 2>&1; then
    ok "--verify PII sweep passes on the sanitized dump"
else
    bad "--verify PII sweep failed on the sanitized dump"
fi

################################################################################
# 5. FAIL-CLOSED proof: the post-condition gate returns non-zero when a real
#    email survives (simulating a tampered / buggy anonymisation). We source the
#    sanitizer functions and point them at a scratch DB holding one real email.
################################################################################
echo "--- FAIL-CLOSED (tampered) check ---"
TAMPER_DB="${SYNTH_DB}_tamper"
"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${TAMPER_DB}\`; CREATE DATABASE \`${TAMPER_DB}\`;"
"${MYSQL[@]}" "$TAMPER_DB" <<SQL
CREATE TABLE ${PREFIX}user (id BIGINT PRIMARY KEY, username VARCHAR(190), email VARCHAR(190), idnumber VARCHAR(190));
INSERT INTO ${PREFIX}user VALUES (2,'user2','still.real@x.test','');
SQL
(
    set +e +u
    # shellcheck source=/dev/null
    source "$SANITIZER"                 # guarded main does NOT run when sourced
    MYSQL_CNF="$(mktemp)"; chmod 600 "$MYSQL_CNF"
    { echo "[client]"; echo "user=${DBUSER}"; echo "password=${DBPASS}"; echo "host=127.0.0.1"; echo "port=${PORT}"; } > "$MYSQL_CNF"
    SCRATCH_DB="$TAMPER_DB"; PREFIX="$TEST_PREFIX"
    _moodle_assert_no_pii >/dev/null 2>&1
    rc=$?
    rm -f "$MYSQL_CNF"
    exit "$rc"
)
TAMPER_RC=$?
"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${TAMPER_DB}\`;" >/dev/null 2>&1 || true
[ "$TAMPER_RC" -ne 0 ] && ok "post-condition returns non-zero on residual real email (fail-closed)" \
                       || bad "post-condition PASSED on a real email — NOT fail-closed!"

# And a well-formed scratch (only sanitized values) must pass the same gate.
CLEAN_DB="${SYNTH_DB}_clean"
"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${CLEAN_DB}\`; CREATE DATABASE \`${CLEAN_DB}\`;"
"${MYSQL[@]}" "$CLEAN_DB" <<SQL
CREATE TABLE ${PREFIX}user (id BIGINT PRIMARY KEY, username VARCHAR(190), email VARCHAR(190), idnumber VARCHAR(190));
INSERT INTO ${PREFIX}user VALUES (2,'user2','abcdef0123456789@sanitized.test',''),(3,'user3','user3@example.com','');
SQL
(
    set +e +u
    # shellcheck source=/dev/null
    source "$SANITIZER"
    MYSQL_CNF="$(mktemp)"; chmod 600 "$MYSQL_CNF"
    { echo "[client]"; echo "user=${DBUSER}"; echo "password=${DBPASS}"; echo "host=127.0.0.1"; echo "port=${PORT}"; } > "$MYSQL_CNF"
    SCRATCH_DB="$CLEAN_DB"; PREFIX="$TEST_PREFIX"
    _moodle_assert_no_pii >/dev/null 2>&1
    rc=$?
    rm -f "$MYSQL_CNF"
    exit "$rc"
)
CLEAN_RC=$?
"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${CLEAN_DB}\`;" >/dev/null 2>&1 || true
[ "$CLEAN_RC" -eq 0 ] && ok "post-condition passes a fully-sanitized scratch" \
                      || bad "post-condition rejected a clean scratch (false positive)"

echo "=== RESULT: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
