#!/bin/bash
# Tier 2a: paired real-DB SSO-join test. Proves the same real email → same fake
# email on BOTH the Drupal (standard.sh) and Moodle (moodle.sh) sanitisers, so
# the cross-stack OIDC/SSO join survives a sanitised copy. No Linode needed.
set -uo pipefail
NWP=/home/rob/nwp-guards
SP=/tmp/claude-1000/-home-rob-nwp/85de94b6-332b-4b22-8cc8-268cc116ae14/scratchpad/paired
rm -rf "$SP"; mkdir -p "$SP/moodleroot" "$SP/moodledata/filedir"
SALT="$SP/salt.yml"; printf 'oidc:\n  sanitizer_salt: paired-test-salt-0123456789abcdef-not-real\n' > "$SALT"
M="mysql -h127.0.0.1 -P13306 -uroot -prootpw"

echo "=== start MariaDB ==="
docker rm -f nwp-paired-db >/dev/null 2>&1 || true
docker run -d --name nwp-paired-db -e MARIADB_ROOT_PASSWORD=rootpw -p 13306:3306 mariadb:10.11 >/dev/null
for i in $(seq 1 30); do $M -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
echo "  ready"

echo "=== create paired DBs with MATCHING real emails ==="
$M <<'SQL'
CREATE DATABASE drupaltest; CREATE DATABASE moodletest;
USE drupaltest;
CREATE TABLE users_field_data (uid BIGINT PRIMARY KEY, name VARCHAR(255), mail VARCHAR(255), init VARCHAR(255));
INSERT INTO users_field_data VALUES
 (1,'admin','alice.admin@realschool.edu','alice.admin@realschool.edu'),
 (2,'jsmith','john.smith@gmail.com','john.smith@gmail.com'),
 (3,'mjones','mary.jones@yahoo.com','mary.jones@yahoo.com');
USE moodletest;
CREATE TABLE mdl_user (id BIGINT PRIMARY KEY, auth VARCHAR(20) DEFAULT 'manual', deleted TINYINT DEFAULT 0,
  username VARCHAR(100), password VARCHAR(255), firstname VARCHAR(100), lastname VARCHAR(100),
  email VARCHAR(100), idnumber VARCHAR(255));
INSERT INTO mdl_user (id,username,firstname,lastname,email) VALUES
 (1,'guest','Guest','User',''),
 (2,'jsmith','John','Smith','john.smith@gmail.com'),
 (3,'mjones','Mary','Jones','mary.jones@yahoo.com');
CREATE TABLE mdl_config (id BIGINT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(255), value TEXT);
INSERT INTO mdl_config (name,value) VALUES ('siteadmins','2');
SQL
echo "  drupaltest + moodletest seeded (john.smith@gmail.com, mary.jones@yahoo.com shared)"

echo "=== drush shim (returns drupaltest creds to standard.sh) ==="
cat > "$SP/drush" <<SH
#!/bin/bash
printf 'database\tdrupaltest\nusername\troot\npassword\trootpw\nhost\t127.0.0.1\nport\t13306\nunix_socket\t\n'
SH
chmod +x "$SP/drush"

echo "=== Moodle fixture (config.php + version.php) ==="
printf '<?php\n$release="4.1.2";\n' > "$SP/moodleroot/version.php"
cat > "$SP/moodleroot/config.php" <<PHP
<?php
\$CFG=new stdClass();
\$CFG->dbtype='mariadb'; \$CFG->dbhost='127.0.0.1'; \$CFG->dbname='moodletest';
\$CFG->dbuser='root'; \$CFG->dbpass='rootpw'; \$CFG->prefix='mdl_';
\$CFG->dboptions=array('dbport'=>13306); \$CFG->dataroot='$SP/moodledata'; \$CFG->wwwroot='http://localhost';
PHP

echo ""
echo "=== RUN Drupal sanitiser (standard.sh) with shared salt ==="
OIDC_SANITIZER_SALT_FILE="$SALT" bash "$NWP/lib/sanitizers/standard.sh" --site-dir "$SP" --drush "$SP/drush" --output "$SP/drupal.sql.gz" 2>&1 | grep -iE "salt|OIDC|anonymis|sweep|done|error|fail" | tail -6
echo "=== RUN Moodle sanitiser (moodle.sh) with the SAME salt ==="
OIDC_SANITIZER_SALT_FILE="$SALT" bash "$NWP/lib/sanitizers/moodle.sh" --site-dir "$SP/moodleroot" --output "$SP/moodle.sql.gz" 2>&1 | grep -iE "anonymis|post-condition|sweep|done|error|fail" | tail -4

echo ""
echo "=== load both sanitised dumps into _out DBs and compare the JOIN KEY (email) ==="
$M -e "DROP DATABASE IF EXISTS d_out; CREATE DATABASE d_out; DROP DATABASE IF EXISTS m_out; CREATE DATABASE m_out;"
zcat "$SP/drupal.sql.gz" | $M d_out
zcat "$SP/moodle.sql.gz" | $M m_out
echo "--- Drupal sanitised emails (uid 2,3):"
$M -N d_out -e "SELECT uid,mail FROM users_field_data WHERE uid IN (2,3) ORDER BY uid;"
echo "--- Moodle sanitised emails (id 2,3):"
$M -N m_out -e "SELECT id,email FROM mdl_user WHERE id IN (2,3) ORDER BY id;"
echo ""
echo "=== VERDICT: do the join keys MATCH across stacks? ==="
d2=$($M -N d_out -e "SELECT mail FROM users_field_data WHERE uid=2;")
m2=$($M -N m_out -e "SELECT email FROM mdl_user WHERE id=2;")
d3=$($M -N d_out -e "SELECT mail FROM users_field_data WHERE uid=3;")
m3=$($M -N m_out -e "SELECT email FROM mdl_user WHERE id=3;")
echo "  john.smith@gmail.com  → Drupal='$d2'  Moodle='$m2'  $([ "$d2" = "$m2" ] && [ -n "$d2" ] && echo '✅ MATCH (SSO join preserved)' || echo '⛔ MISMATCH (SSO would break)')"
echo "  mary.jones@yahoo.com  → Drupal='$d3'  Moodle='$m3'  $([ "$d3" = "$m3" ] && [ -n "$d3" ] && echo '✅ MATCH' || echo '⛔ MISMATCH')"
echo ""
echo "=== teardown ==="
docker rm -f nwp-paired-db >/dev/null 2>&1 && echo "  container removed"
rm -rf "$SP" && echo "  scratch removed"
