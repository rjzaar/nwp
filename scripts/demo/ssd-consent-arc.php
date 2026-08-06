<?php
/**
 * scripts/demo/ssd-consent-arc.php — the Art.9 consent-arc probe/applier for the
 * MOODLE half of the nwd↔ssd demo pair (nwp/ops#279, operator GO 2026-08-07).
 *
 * WHY A PROBE AND NOT A GREP
 * --------------------------
 * `pl moodle gate-status` proves the BYTES carrying `may_keep_formation` are on
 * the box. It cannot prove the class LOADS, that the plugin is INSTALLED (a
 * plugin whose db/install.xml never ran has tables missing and a version row
 * absent while its PHP sits happily on disk), or that the gate actually returns
 * TRUE for anybody. Those three are different failures and only execution tells
 * them apart. The operator asked for the staged-PHP idiom for exactly this
 * reason.
 *
 * MODES
 *   --check  (default) READ-ONLY. Prints one `key: value` line per reading and
 *            exits 0 only when the arc is complete for every demo persona.
 *   --apply  Grants Art.9 consent to the DEMO PERSONAS ONLY, by writing the same
 *            preference `\auth_nwc\consent::store()` writes at login. This is the
 *            seed half of the operator spec: without it every persona is Trialing
 *            and every practice tick is silently discarded.
 *
 * WHY WRITING THE PREFERENCE IS THE HONEST THING HERE, NOT A BYPASS
 * ----------------------------------------------------------------
 * The preference is a CARRIED value, not the consent record itself. The record
 * lives on nwd (Drupal); Moodle only ever caches what the OIDC claim told it.
 * Seeding it is the same act the login observer performs, and the demo personas
 * are synthetic `@demo.invalid` accounts that grant consent as part of their
 * scripted persona. The moment such a persona logs in over real OIDC the claim
 * overwrites this value — so a WRONG seed self-corrects rather than persisting a
 * lie. What it must never do is grant consent to a non-persona account, so the
 * selector is fail-closed (see persona_userids()).
 *
 * FAIL-CLOSED: any reading that cannot be taken prints CANNOT-VERIFY and forces
 * a non-zero exit. "I could not look" never prints as a pass.
 */

define('CLI_SCRIPT', true);

// Staged into $CFG->dataroot (live) or the Moodle root (dev) — locate config.php
// from the CWD the runner sets, exactly as the sibling demo scripts do.
$cfgpath = getcwd() . '/config.php';
if (!is_readable($cfgpath)) {
    fwrite(STDERR, "REFUSED: no readable config.php at {$cfgpath}\n");
    exit(2);
}
require($cfgpath);

global $DB, $CFG;

$apply = in_array('--apply', $argv, true);
$exit = 0;

/** Print a reading. */
function reading(string $k, $v): void {
    if (is_bool($v)) {
        $v = $v ? 'true' : 'false';
    }
    echo "{$k}: {$v}\n";
}

/** Record a reading that could not be taken. */
function cannot(string $k, string $why): void {
    global $exit;
    echo "{$k}: CANNOT-VERIFY ({$why})\n";
    $exit = 2;
}

echo "probe: ssd-consent-arc v1\n";
reading('site', $CFG->wwwroot);
reading('mode', $apply ? 'apply' : 'check');
reading('taken_at', gmdate('Y-m-d\TH:i:s\Z'));

// -----------------------------------------------------------------------------
// 1. Does the consent SUBSYSTEM exist as executable code?
// -----------------------------------------------------------------------------
$classok = class_exists('\\auth_nwc\\consent');
reading('auth_nwc_consent_class', $classok);
if (!$classok) {
    $exit = 1;
}

// The gate the practice plane actually calls. Loading local/practice/lib.php is
// what Moodle itself does; if the plugin is absent the require fails and that is
// a distinct, reportable state from "class missing".
$practicelib = $CFG->dirroot . '/local/practice/lib.php';
$gatefn = false;
if (is_readable($practicelib)) {
    require_once($practicelib);
    $gatefn = function_exists('local_practice_may_keep_formation');
} else {
    reading('local_practice_lib', 'ABSENT');
    $exit = 1;
}
reading('local_practice_gate_fn', $gatefn);

// -----------------------------------------------------------------------------
// 2. Is each plugin INSTALLED (not merely present on disk)?
// -----------------------------------------------------------------------------
foreach (['auth_nwc', 'local_practice', 'mod_depthcontent'] as $component) {
    try {
        $v = $DB->get_field('config_plugins', 'value',
            ['plugin' => $component, 'name' => 'version']);
        reading("installed_{$component}", $v === false ? 'NOT-INSTALLED' : $v);
        if ($v === false) {
            $exit = 1;
        }
    } catch (Throwable $e) {
        cannot("installed_{$component}", $e->getMessage());
    }
}

// -----------------------------------------------------------------------------
// 3. Do the practice tables exist, and what do they hold?
// -----------------------------------------------------------------------------
$defrows = null;
try {
    $dbman = $DB->get_manager();
    foreach (['local_practice_def', 'local_practice_log',
              'local_practice_state', 'local_practice_reflection'] as $t) {
        if ($dbman->table_exists($t)) {
            $n = $DB->count_records($t);
            reading("rows_{$t}", $n);
            if ($t === 'local_practice_def') {
                $defrows = $n;
            }
        } else {
            reading("rows_{$t}", 'TABLE-ABSENT');
            $exit = 1;
        }
    }
} catch (Throwable $e) {
    cannot('practice_tables', $e->getMessage());
}

// -----------------------------------------------------------------------------
// 3b. The staleness setting — it decides whether an unstamped '1' still works.
//
// `\auth_nwc\consent::decide()` treats a '1' with no timestamp as UNKNOWN (=no
// consent) ONLY when a max-age is in force. So max-age 0 and max-age 86400 give
// opposite answers for the same stored data, and reporting the prefs without
// reporting this would be reporting half a fact.
// -----------------------------------------------------------------------------
$maxage = $classok ? \auth_nwc\consent::maxage() : null;
reading('art9_consent_maxage', $maxage === null ? 'UNKNOWN' : $maxage
    . ($maxage > 0 ? ' (staleness ENFORCED)' : ' (staleness check disabled)'));

// -----------------------------------------------------------------------------
// 4. The demo personas and their consent state.
// -----------------------------------------------------------------------------
/**
 * Demo personas — fail-closed selector. TWO conditions, both required.
 *
 *   1. email ends `@demo.invalid` — the demo tier's own definition of a
 *      synthetic account (what the nightly wipe and the invite flow key off).
 *      It cannot be routed to a real inbox and no real member's address can
 *      accidentally match it.
 *   2. the account has an `auth_oauth2_linked_login` row — it was provisioned
 *      by, and is bound to, the OIDC PROVIDER.
 *
 * Condition 2 is the load-bearing one and it is not belt-and-braces. The Moodle
 * preference is a CACHE of a consent record that lives on nwd. An account that
 * did not come from nwd has no such record, so seeding it would not be caching
 * a decision — it would be inventing one. Two accounts on ssd would have been
 * wrongly swept in by an email-only selector: `nwd_completion_reader`
 * (auth=webservice, a machine) and `ssddemo_admin` (auth=manual, a local
 * operator login) — neither has a provider-side identity.
 *
 * The linked-login row is deliberately the same signal `\auth_nwc\observer`
 * itself uses to decide "this login was ours" (observer.php:67). Reusing the
 * plugin's own test for provider-provenance means this selector cannot drift
 * away from the thing that actually writes the preference at login. Note the
 * personas run core `auth=oauth2`, NOT `auth=nwc` — auth_nwc is a lock/claims
 * enforcer layered on core's OAuth2 dance, so keying off the auth column would
 * have selected nothing at all.
 *
 * Deleted, suspended, guest and admin accounts are excluded; admins are never
 * gated anyway, so granting them consent would write a row that proves nothing.
 */
function persona_userids(): array {
    global $DB, $CFG;
    $adminids = array_keys(get_admins());
    $select = "deleted = 0 AND suspended = 0 AND id <> :guestid "
            . "AND " . $DB->sql_like('email', ':suffix', false)
            . " AND EXISTS (SELECT 1 FROM {auth_oauth2_linked_login} ll WHERE ll.userid = {user}.id)";
    $params = [
        'guestid' => (int) $CFG->siteguest,
        'suffix'  => '%@demo.invalid',
    ];
    if ($adminids) {
        [$insql, $inparams] = $DB->get_in_or_equal($adminids, SQL_PARAMS_NAMED, 'adm', false);
        $select .= " AND id {$insql}";
        $params += $inparams;
    }
    return $DB->get_records_select_menu('user', $select, $params, 'id', 'id, username');
}

try {
    $personas = persona_userids();
    reading('persona_count', count($personas));

    // Name what the selector REJECTED. A silent exclusion is how a seed quietly
    // stops covering an account nobody notices is missing.
    $alldemo = $DB->get_records_select_menu('user',
        'deleted = 0 AND ' . $DB->sql_like('email', ':suffix', false),
        ['suffix' => '%@demo.invalid'], 'id', 'id, username');
    foreach ($alldemo as $uid => $uname) {
        if (!isset($personas[$uid])) {
            $auth = $DB->get_field('user', 'auth', ['id' => $uid]);
            reading("excluded_{$uname}", "uid={$uid} auth={$auth} reason=no-provider-identity");
        }
    }
    if (!$personas) {
        // Zero personas is not a pass: the whole point of the seed is that the
        // personas carry consent. An empty set means we are looking at the wrong
        // site or the seed never ran.
        cannot('personas', 'no @demo.invalid accounts found — nothing to seed');
    }

    $granted = 0;
    $gateopen = 0;
    $unstamped = 0;
    foreach ($personas as $uid => $username) {
        if ($apply && $classok) {
            // The same call the login observer makes. store() also stamps the
            // PREF_AT timestamp, so the staleness fail-closed stays satisfiable.
            \auth_nwc\consent::store((int) $uid, true);
        }
        $pref = $classok ? \auth_nwc\consent::get((int) $uid) : null;
        $open = $gatefn ? local_practice_may_keep_formation((int) $uid) : false;
        $granted += ($pref === true) ? 1 : 0;
        $gateopen += $open ? 1 : 0;
        $state = ($pref === null) ? 'unset' : ($pref ? '1' : '0');

        // PROVENANCE, not just value. A stored '1' proves somebody wrote a 1; it
        // does NOT prove the nwd claim is flowing. store_from_userinfo() stamps
        // PREF_AT on every login, so a PREF_AT at or after the account's last
        // login means the value was (re)carried BY that login — i.e. the claim
        // arrived. A PREF_AT older than lastaccess means the last login did NOT
        // refresh it, which is the signature of a hand-seeded value and of a
        // claim that is no longer being emitted.
        $at = $classok ? \auth_nwc\consent::get_stored_at((int) $uid) : null;
        $last = (int) $DB->get_field('user', 'lastaccess', ['id' => $uid]);
        if ($at === null) {
            $prov = 'never-stamped';
            $unstamped++;
        } else if ($last > 0 && $at + 300 < $last) {
            // 300s slack: the stamp and the login event are in the same request
            // but not the same clock tick.
            $prov = 'STALE(pref_at=' . gmdate('Y-m-d\TH:i:s\Z', $at)
                  . ' < lastaccess=' . gmdate('Y-m-d\TH:i:s\Z', $last) . ')';
        } else {
            $prov = 'carried-at-login(' . gmdate('Y-m-d\TH:i:s\Z', $at) . ')';
        }

        reading("persona_{$username}", "uid={$uid} art9_pref={$state} gate_open="
            . ($open ? 'true' : 'false') . " provenance={$prov}");
    }
    reading('personas_consent_granted', "{$granted}/" . count($personas));
    reading('personas_gate_open', "{$gateopen}/" . count($personas));

    // An unstamped '1' is a live gate today and a shut gate the moment anybody
    // sets a max-age. Say so while it is still cheap to fix.
    if ($unstamped > 0 && (int) $maxage === 0) {
        echo "note: {$unstamped} persona(s) hold an UNSTAMPED consent value. It works only\n";
        echo "note: because art9_consent_maxage is 0. Setting a max-age would shut the gate\n";
        echo "note: on all of them at once, silently. Re-store via --apply to stamp them.\n";
    }
    if ($personas && $gateopen !== count($personas)) {
        // The arc is only complete when EVERY persona can persist. A partial
        // pass reads as "mostly working" and hides the one that silently drops
        // every tick.
        $exit = ($exit === 0) ? 1 : $exit;
    }
} catch (Throwable $e) {
    cannot('personas', $e->getMessage());
}

// -----------------------------------------------------------------------------
// 5. Verdict.
// -----------------------------------------------------------------------------
// The checkpoint CATALOGUE is a separate precondition from consent, and saying
// so out loud is the point: with zero def rows `local_practice_engaged()` returns
// false for every checkpoint, so a green consent arc still ticks nothing. Two
// distinct causes of "the tick did not stick" must not share one verdict line.
if ($defrows === 0) {
    echo "note: local_practice_def is EMPTY — consent is not the blocker for ticks;\n";
    echo "note: run cli/sync_practice_defs.php before expecting any tick to persist.\n";
}

if ($exit === 0) {
    echo "result: OK — consent arc complete on this half\n";
} elseif ($exit === 2) {
    echo "result: CANNOT-VERIFY — do not record this run as evidence\n";
} else {
    echo "result: INCOMPLETE — see the readings above\n";
}
exit($exit);
