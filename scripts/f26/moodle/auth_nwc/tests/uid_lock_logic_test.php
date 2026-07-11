<?php
// Standalone unit test for auth_nwc\uid_lock — runs with plain `php`, no Moodle.
//
//   php scripts/f26/moodle/auth_nwc/tests/uid_lock_logic_test.php
//
// Verifies the five F26 § 3.2 branches of the UID-lock decision. This is the
// load-bearing, runnable part of the (otherwise Moodle-dependent) client side.

require __DIR__ . '/../classes/uid_lock.php';

use auth_nwc\uid_lock;

$pass = 0; $fail = 0;
function check($name, $got, $want) {
    global $pass, $fail;
    if ($got === $want) { echo "  ok   $name\n"; $pass++; }
    else { echo "  FAIL $name (got '$got', want '$want')\n"; $fail++; }
}

$row = (object) ['id' => 42]; // stand-in for an mdl_user row

// 1. New user, nwc active -> create, locked to sub.
$d = uid_lock::decide(['sub' => '1001', 'nwc_active' => true]);
check('new user -> create', $d['action'], uid_lock::ACTION_CREATE);
check('new user idnumber = sub', $d['idnumber'], '1001');

// 2. Already locked to this sub -> reuse (match by idnumber, not email).
$d = uid_lock::decide(['sub' => '1001', 'nwc_active' => true, 'row_by_idnumber' => $row]);
check('locked row -> reuse', $d['action'], uid_lock::ACTION_REUSE_LOCKED);

// 3. Locked row wins even if a different email row exists (never rematch by email).
$d = uid_lock::decide(['sub' => '1001', 'nwc_active' => true,
    'row_by_idnumber' => $row, 'row_by_email' => (object)['id' => 99],
    'link_legacy_by_email' => true]);
check('idnumber beats email', $d['action'], uid_lock::ACTION_REUSE_LOCKED);

// 4. Legacy email match, migration ON -> one-time lock of existing row.
$d = uid_lock::decide(['sub' => '1001', 'nwc_active' => true,
    'row_by_email' => $row, 'link_legacy_by_email' => true]);
check('legacy email + migration on -> lock_existing', $d['action'], uid_lock::ACTION_LOCK_EXISTING);

// 5. Legacy email match, migration OFF -> create (do NOT silently link).
$d = uid_lock::decide(['sub' => '1001', 'nwc_active' => true,
    'row_by_email' => $row, 'link_legacy_by_email' => false]);
check('legacy email + migration off -> create', $d['action'], uid_lock::ACTION_CREATE);

// 6. nwc account gone but a locked row exists -> suspend (keep history).
$d = uid_lock::decide(['sub' => '1001', 'nwc_active' => false, 'row_by_idnumber' => $row]);
check('nwc gone + locked row -> suspend', $d['action'], uid_lock::ACTION_SUSPEND);

// 7. nwc account gone, no locked row -> deny.
$d = uid_lock::decide(['sub' => '1001', 'nwc_active' => false]);
check('nwc gone + no row -> deny', $d['action'], uid_lock::ACTION_DENY);

// 8. Empty sub -> deny (never fabricate identity; no anonymous shortcut).
$d = uid_lock::decide(['sub' => '', 'nwc_active' => true]);
check('empty sub -> deny', $d['action'], uid_lock::ACTION_DENY);

// 9. Whitespace-only sub -> deny.
$d = uid_lock::decide(['sub' => "   ", 'nwc_active' => true]);
check('whitespace sub -> deny', $d['action'], uid_lock::ACTION_DENY);

echo "== $pass passed, $fail failed ==\n";
exit($fail === 0 ? 0 : 1);
