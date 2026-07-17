<?php
// Standalone unit test for auth_nwc\guild_cohort_map — runs with plain `php`,
// no Moodle.
//
//   php scripts/f26/moodle/auth_nwc/tests/guild_cohort_map_logic_test.php
//
// Verifies the pure guild→cohort reconciliation decision: bind on the stable
// guild uuid, never touch cohorts we don't manage, and never strip everything
// on a missing/empty claim by accident.

// guild_cohort_map calls defined('MOODLE_INTERNAL') || die(); define it so the
// class loads standalone, exactly as uid_lock_logic_test relies on for its own.
define('MOODLE_INTERNAL', true);
require __DIR__ . '/../classes/guild_cohort_map.php';

use auth_nwc\guild_cohort_map;

$pass = 0; $fail = 0;
function check($name, $got, $want) {
    global $pass, $fail;
    $g = json_encode($got); $w = json_encode($want);
    if ($g === $w) { echo "  ok   $name\n"; $pass++; }
    else { echo "  FAIL $name (got $g, want $w)\n"; $fail++; }
}

$UA = 'b677f32c-9388-48b9-bd25-d13a4e863f15';
$UB = '205225aa-85ee-40e6-91f2-96b36cb43c96';

// idnumber helpers.
check('idnumber_for prefixes uuid', guild_cohort_map::idnumber_for($UA), 'nwcguild:' . $UA);
check('is_managed true for our prefix', guild_cohort_map::is_managed('nwcguild:' . $UA), true);
check('is_managed false for operator cohort', guild_cohort_map::is_managed('operator-made'), false);
check('is_managed false for empty', guild_cohort_map::is_managed(''), false);
check('uuid_from round-trips', guild_cohort_map::uuid_from('nwcguild:' . $UA), $UA);
check('uuid_from empty for unmanaged', guild_cohort_map::uuid_from('operator-made'), '');

// 1. First login: member in two guilds, no current managed cohorts.
$d = guild_cohort_map::decide(
    [['uuid' => $UA, 'label' => 'Coders IG'], ['uuid' => $UB, 'label' => 'Trialing Guild']],
    []);
check('first login ensures both', array_column($d['ensure'], 'uuid'), [$UA, $UB]);
check('first login leaves nothing', $d['leave'], []);

// 2. Steady state: member already in exactly the guilds they should be.
$d = guild_cohort_map::decide(
    [['uuid' => $UA, 'label' => 'Coders IG']],
    [$UA]);
check('steady: ensure is idempotent (still lists membership)', array_column($d['ensure'], 'uuid'), [$UA]);
check('steady: nothing to leave', $d['leave'], []);

// 3. Guild left on nwc: member drops UA, keeps UB.
$d = guild_cohort_map::decide(
    [['uuid' => $UB, 'label' => 'Trialing Guild']],
    [$UA, $UB]);
check('leave: only UB ensured', array_column($d['ensure'], 'uuid'), [$UB]);
check('leave: UA removed', $d['leave'], [$UA]);

// 4. THE DANGEROUS CASE — empty claim must NOT be read as "leave everything".
//    (The observer guards this by passing null on a missing claim, but the pure
//    decider must still behave: an explicit empty guilds list means leave all
//    managed. This documents that contract so the observer's null-guard stays
//    load-bearing.)
$d = guild_cohort_map::decide([], [$UA, $UB]);
check('empty claim ensures nothing', $d['ensure'], []);
check('empty claim leaves all managed', $d['leave'], [$UA, $UB]);

// 5. A guild with no uuid is skipped, not bound on a renumber-fragile id.
$d = guild_cohort_map::decide(
    [['id' => 7, 'label' => 'No UUID Guild'], ['uuid' => $UA, 'label' => 'Coders IG']],
    []);
check('no-uuid guild skipped', array_column($d['ensure'], 'uuid'), [$UA]);
check('no-uuid guild recorded a reason', count($d['reasons']) >= 1, true);

// 6. Label falls back to uuid when absent, so a cohort always has a name.
$d = guild_cohort_map::decide([['uuid' => $UA]], []);
check('missing label falls back to uuid', $d['ensure'][0]['label'], $UA);

echo "\n$pass passed, $fail failed\n";
exit($fail === 0 ? 0 : 1);
