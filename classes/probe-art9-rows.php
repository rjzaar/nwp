<?php
/**
 * probe-art9-rows.php — the re-attestation probe behind an Art.9 `none-stored`
 * exemption (ADR-0036 / nwp/ops#153).
 *
 * Prints the three readings a classes/<site>.class.yml attestation records:
 *
 *   member_count:            non-admin, non-guest, non-deleted accounts
 *   formation_rows:          rows in depthcontent_progress (0 if table absent)
 *   consent_tables_present:  whether any consent/art9/nwc table exists
 *
 * DEPLOYMENT: this file ships in the nwp repo at classes/probe-art9-rows.php
 * and must be placed at admin/cli/probe_art9_rows.php on the target Moodle
 * site — `pl moodle cli` refuses (correctly: containment) to execute any path
 * outside admin/cli/. Once deployed it is run exactly as the declaration
 * records:
 *
 *   pl moodle cli <site> --tier=live --execute -- admin/cli/probe_art9_rows.php
 *
 * FAIL CLOSED: any unreadable source exits non-zero. "I could not look" must
 * never print a reading of 0.
 */

define('CLI_SCRIPT', true);

require(__DIR__ . '/../../config.php');

global $DB, $CFG;

$exit = 0;

echo "probe: art9-rows v1\n";
echo "site: {$CFG->wwwroot}\n";
echo "taken_at: " . gmdate('Y-m-d\TH:i:s\Z') . "\n";

// --- member_count -----------------------------------------------------------
// Real people who are not operators: exclude deleted accounts, the guest
// account, and every site administrator.
try {
    $adminids = array_keys(get_admins());
    $params = ['guestid' => (int) $CFG->siteguest];
    $adminsql = '';
    if ($adminids) {
        [$insql, $inparams] = $DB->get_in_or_equal($adminids, SQL_PARAMS_NAMED, 'adm', false);
        $adminsql = " AND id $insql";
        $params += $inparams;
    }
    $count = $DB->count_records_select('user', "deleted = 0 AND id <> :guestid" . $adminsql, $params);
    echo "member_count: {$count}\n";
} catch (Throwable $e) {
    echo "member_count: CANNOT-VERIFY (" . $e->getMessage() . ")\n";
    $exit = 2;
}

// --- formation_rows ---------------------------------------------------------
try {
    $dbman = $DB->get_manager();
    if ($dbman->table_exists('depthcontent_progress')) {
        echo "formation_rows: " . $DB->count_records('depthcontent_progress') . "\n";
    } else {
        // The table not existing is itself evidence (and is what rgs's 2026-07-28
        // attestation recorded) — report it distinctly, count as zero.
        echo "formation_rows: 0\n";
        echo "formation_table: absent\n";
    }
} catch (Throwable $e) {
    echo "formation_rows: CANNOT-VERIFY (" . $e->getMessage() . ")\n";
    $exit = 2;
}

// --- consent_tables_present -------------------------------------------------
try {
    $matches = [];
    foreach ($DB->get_tables(false) as $table) {
        if (preg_match('/consent|art9|nwc/i', $table)) {
            $matches[] = $table;
        }
    }
    if ($matches) {
        echo "consent_tables_present: true\n";
        echo "consent_tables: " . implode(', ', $matches) . "\n";
    } else {
        echo "consent_tables_present: false\n";
    }
} catch (Throwable $e) {
    echo "consent_tables_present: CANNOT-VERIFY (" . $e->getMessage() . ")\n";
    $exit = 2;
}

if ($exit !== 0) {
    echo "result: CANNOT-VERIFY — do not record these readings as an attestation\n";
} else {
    echo "result: ok — record these readings in classes/<site>.class.yml (tracked, reviewed)\n";
}
exit($exit);
