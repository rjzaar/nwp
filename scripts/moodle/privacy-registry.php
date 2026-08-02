<?php
// scripts/moodle/privacy-registry.php — the staged, READ-ONLY half of
// `pl moodle privacy` (scripts/commands/moodle.sh cmd_privacy).
//
// WHY THIS EXISTS
// ---------------
// On 2026-08-03 `local/feedback` was found installed on live ssd AND live ssc
// with `classes/privacy/provider.php` simply ABSENT from the deployed tree
// (nwp/ops#259). The plugin stores userid, username, email, ipaddress and
// user_agent per submission. With no provider class, Moodle's privacy API does
// not know the plugin exists: a DSAR export returns nothing for it and an
// Art.17 erasure silently skips it. Nothing anywhere went red.
//
// `pl moodle plugin drift` could not catch it — it compares $plugin->version
// between copies, and every copy agreed. A file can be missing from all of
// them at once. And "the file is on disk" is still not "the privacy API sees
// it": the class has to exist, autoload under the right namespace, implement
// the right interfaces, and the plugin has to be INSTALLED at a version the
// database agrees with. This script asks Moodle itself, on the target.
//
// It is strictly read-only. It opens no transaction, writes no row, touches no
// file. Its only side effect is the one the caller already made: this file
// being staged in /tmp and deleted again.
//
// USAGE (always via the verb; the verb stages it and cleans up):
//   privacy-registry.php [--component=<frankenstyle>]... [--all] [--verbose]
//
//   With one or more --component: report a line for EACH named component and
//   exit non-zero if any of them is not compliant. This is the assertion form.
//   With --all (or nothing): scan every installed plugin, print a line for the
//   non-compliant ones only (plus --verbose for all), and summarise.
//
// OUTPUT (one line per component, stable and greppable):
//   PRIVACY <component> <STATUS> versiondisk=<n> versiondb=<n> metadata=<n> \
//           interfaces=<csv> missing=<csv|->
//   PRIVACY-SUMMARY checked=<n> compliant=<n> null=<n> noprovider=<n> incomplete=<n>
//
// STATUS values. The verdict is \core_privacy\manager::component_is_compliant()
// — the exact predicate the plugin privacy registry page uses — never a rule
// re-derived here. An earlier draft did re-derive it and called 64 stock Moodle
// 4.4 core plugins broken; a checker that cries wolf about core is a checker
// nobody reads.
//   COMPLIANT       Moodle says compliant, declares metadata, and every method
//                   its own declared interfaces oblige is present.
//   NULL-PROVIDER   Moodle says compliant via null_provider — legitimately
//                   declares that it stores no personal data.
//   NO-PROVIDER     no privacy\provider class at all — INVISIBLE to the API.
//   INCOMPLETE      a provider class exists but Moodle does not accept it, or a
//                   method its declared interfaces promise is absent. Worse
//                   than absent, because it looks answered.
//   NOT-INSTALLED   asserted with --component but not installed on the target.
//
// EXIT: 0 = every checked component is COMPLIANT or NULL-PROVIDER.
//       1 = at least one is NO-PROVIDER or INCOMPLETE.
//       2 = could not run (no Moodle root, bad arguments). NEVER conflate this
//           with a clean result: a check that could not look has not looked.

define('CLI_SCRIPT', true);

// ---------------------------------------------------------------------------
// Arguments are validated before Moodle is loaded — a malformed invocation is
// a caller bug and must fail identically on a healthy and an unhealthy site.
// ---------------------------------------------------------------------------
$components = [];
$scanall = false;
$verbose = false;
foreach (array_slice($argv, 1) as $a) {
    if (strpos($a, '--component=') === 0) {
        $c = trim(substr($a, strlen('--component=')));
        if ($c === '' || !preg_match('/^[a-z][a-z0-9_]*$/', $c)) {
            fwrite(STDERR, "Bad --component value: '$c' (expect a frankenstyle name like local_feedback)\n");
            exit(2);
        }
        $components[$c] = true;
        continue;
    }
    if ($a === '--all')     { $scanall = true;  continue; }
    if ($a === '--verbose') { $verbose = true;  continue; }
    fwrite(STDERR, "Unknown argument: $a\n");
    exit(2);
}
$components = array_keys($components);
if (!$components) { $scanall = true; }

$root = null;
foreach ([getcwd(), __DIR__] as $c) {
    if (is_file("$c/config.php") && is_dir("$c/lib")) { $root = $c; break; }
}
if ($root === null) { fwrite(STDERR, "Cannot find Moodle root\n"); exit(2); }
require("$root/config.php");
require_once($CFG->libdir . '/clilib.php');

if (!class_exists('\core_privacy\manager')) {
    fwrite(STDERR, "CANNOT-VERIFY: this Moodle has no \\core_privacy\\manager\n");
    exit(2);
}

/**
 * The methods the API will actually call, given the interfaces a provider
 * declares. Checked by name rather than by is_callable() on an instance: these
 * are all static and the point is to prove the API's call sites will resolve.
 *
 * ONLY the interfaces that genuinely oblige a PLUGIN-level implementation are
 * listed. `userlist_provider` and `shared_userlist_provider` are markers used
 * for subplugin aggregation and do NOT oblige get_users_in_context() on the
 * component itself — requiring them flagged 64 stock Moodle 4.4 core plugins
 * as broken, which is how a check earns the right to be ignored.
 */
function privreg_required_methods(array $interfaces): array {
    $need = [];
    if (isset($interfaces['core_privacy\local\metadata\provider'])) {
        $need[] = 'get_metadata';
    }
    if (isset($interfaces['core_privacy\local\request\plugin\provider'])
        || isset($interfaces['core_privacy\local\request\subsystem\provider'])) {
        $need[] = 'get_contexts_for_userid';
        $need[] = 'export_user_data';
        $need[] = 'delete_data_for_all_users_in_context';
        $need[] = 'delete_data_for_user';
    }
    if (isset($interfaces['core_privacy\local\request\core_userlist_provider'])) {
        $need[] = 'get_users_in_context';
        $need[] = 'delete_data_for_users';
    }
    return array_values(array_unique($need));
}

/** One shared privacy manager for the whole run. */
function privreg_manager(): \core_privacy\manager {
    static $m = null;
    if ($m === null) { $m = new \core_privacy\manager(); }
    return $m;
}

/**
 * Inspect ONE component. Returns a row array; never throws for a merely
 * absent provider — that is the finding, not an error.
 */
function privreg_inspect(string $component, array $versions): array {
    $classname = '\\' . $component . '\\privacy\\provider';
    $row = [
        'component'   => $component,
        'status'      => 'NO-PROVIDER',
        'versiondisk' => $versions['disk'] ?? '-',
        'versiondb'   => $versions['db'] ?? '-',
        'metadata'    => '-',
        'interfaces'  => '-',
        'missing'     => '-',
    ];
    if (!class_exists($classname)) {
        return $row;
    }
    $interfaces = class_implements($classname);
    if ($interfaces === false) { $interfaces = []; }
    $short = [];
    foreach (array_keys($interfaces) as $i) {
        $parts = explode('\\', $i);
        $short[] = end($parts) === 'provider' ? implode('\\', array_slice($parts, -2)) : end($parts);
    }
    sort($short);
    $row['interfaces'] = $short ? implode(',', $short) : '-';

    $isnull = isset($interfaces['core_privacy\local\metadata\null_provider']);
    $hasmeta = isset($interfaces['core_privacy\local\metadata\provider']);

    $missing = [];
    foreach (privreg_required_methods($interfaces) as $m) {
        if (!method_exists($classname, $m)) { $missing[] = $m; }
    }
    $row['missing'] = $missing ? implode(',', $missing) : '-';

    // Metadata item count — ask the provider to describe itself, exactly as
    // the plugin privacy registry page does. A provider that declares metadata
    // but returns an empty collection is reported as metadata=0, which is a
    // real (and suspicious) answer, not an error.
    if ($hasmeta && method_exists($classname, 'get_metadata')) {
        try {
            $collection = new \core_privacy\local\metadata\collection($component);
            $collection = $classname::get_metadata($collection);
            $items = ($collection instanceof \core_privacy\local\metadata\collection)
                ? $collection->get_collection() : [];
            $row['metadata'] = (string) count($items);
        } catch (\Throwable $e) {
            $row['metadata'] = 'ERROR';
            $missing[] = 'get_metadata:threw';
            $row['missing'] = implode(',', $missing);
        }
    }

    // THE VERDICT IS MOODLE'S, NOT OURS. component_is_compliant() is the exact
    // predicate the plugin privacy registry page uses, so a plugin this script
    // calls compliant is one the privacy API will actually interrogate. Our own
    // interface bookkeeping above stays, but only as the DETAIL columns that
    // say *why* — re-deriving the verdict is how a checker drifts from the
    // thing it is supposed to be checking.
    // component_is_compliant() is an INSTANCE method in Moodle 4.4
    // (privacy/classes/manager.php:143), not a static one. Calling it
    // statically throws, and a catch-all that maps "threw" to "not compliant"
    // reported all 449 components on ssd@live as INCOMPLETE — a check that
    // fails uniformly is indistinguishable from a check that is broken, which
    // is exactly what it was. The manager is reused across components.
    $compliant = false;
    try {
        $compliant = (bool) privreg_manager()->component_is_compliant($component);
    } catch (\Throwable $e) {
        $row['status'] = 'CANNOT-VERIFY';
        $row['missing'] = 'component_is_compliant:' . get_class($e);
        return $row;
    }
    if (!$compliant) {
        $row['status'] = 'INCOMPLETE';
        return $row;
    }
    if ($missing) {
        // Moodle says compliant, but a method its own interfaces promise is
        // absent. Report it rather than smoothing it over.
        $row['status'] = 'INCOMPLETE';
        return $row;
    }
    // NULL-PROVIDER is a distinct, legitimate answer ("this component stores no
    // personal data"), and it is worth separating from COMPLIANT in the summary
    // so that a plugin which QUIETLY became a null_provider stands out.
    $row['status'] = ($isnull && !$hasmeta) ? 'NULL-PROVIDER' : 'COMPLIANT';
    return $row;
}

// ---------------------------------------------------------------------------
// Build the component -> {disk,db} version map from the plugin manager. A
// component whose versiondb differs from versiondisk has NOT completed its
// upgrade, which is precisely the state a "deployed but never upgraded" plugin
// is in — so it is reported alongside the provider verdict, not separately.
// ---------------------------------------------------------------------------
$versions = [];
$allcomponents = [];
$pluginman = core_plugin_manager::instance();
foreach ($pluginman->get_plugins() as $type => $plugins) {
    foreach ($plugins as $plugin) {
        $name = $plugin->component;
        $allcomponents[] = $name;
        $versions[$name] = [
            'disk' => isset($plugin->versiondisk) && $plugin->versiondisk !== null ? (string) $plugin->versiondisk : '-',
            'db'   => isset($plugin->versiondb) && $plugin->versiondb !== null ? (string) $plugin->versiondb : '-',
        ];
    }
}
sort($allcomponents);

$targets = $scanall && !$components ? $allcomponents : $components;
if ($scanall && $components) { $targets = $allcomponents; }

$named = array_flip($components);
$counts = ['COMPLIANT' => 0, 'NULL-PROVIDER' => 0, 'NO-PROVIDER' => 0,
           'INCOMPLETE' => 0, 'CANNOT-VERIFY' => 0];
$rows = [];
$failednamed = 0;

foreach ($targets as $component) {
    // A --component the target does not have installed at all is a hard
    // finding, not a silent skip: asserting against an absent plugin must
    // never look like a pass.
    if (isset($named[$component]) && !isset($versions[$component])) {
        printf("PRIVACY %s NOT-INSTALLED versiondisk=- versiondb=- metadata=- interfaces=- missing=-\n", $component);
        $failednamed++;
        continue;
    }
    $row = privreg_inspect($component, $versions[$component] ?? []);
    $counts[$row['status']] = ($counts[$row['status']] ?? 0) + 1;
    $rows[] = $row;
    $isnamed = isset($named[$component]);
    if ($isnamed && $row['status'] !== 'COMPLIANT' && $row['status'] !== 'NULL-PROVIDER') {
        $failednamed++;
    }
    $interesting = ($row['status'] !== 'COMPLIANT' && $row['status'] !== 'NULL-PROVIDER');
    if ($isnamed || $verbose || $interesting) {
        printf("PRIVACY %s %s versiondisk=%s versiondb=%s metadata=%s interfaces=%s missing=%s\n",
            $row['component'], $row['status'], $row['versiondisk'], $row['versiondb'],
            $row['metadata'], $row['interfaces'], $row['missing']);
    }
}

printf("PRIVACY-SUMMARY checked=%d compliant=%d null=%d noprovider=%d incomplete=%d cannotverify=%d\n",
    count($rows), $counts['COMPLIANT'], $counts['NULL-PROVIDER'],
    $counts['NO-PROVIDER'], $counts['INCOMPLETE'], $counts['CANNOT-VERIFY']);

// SELF-CHECK. A stock Moodle has hundreds of compliant core components. If a
// full scan finds NONE, the probe is broken, not the site — and a broken probe
// that reports "everything is non-compliant" is worse than no probe, because
// the real finding drowns in it. This exact state happened on the first run
// (component_is_compliant() called statically), so the guard is not theoretical.
if ($scanall && count($rows) > 50 && $counts['COMPLIANT'] === 0 && $counts['NULL-PROVIDER'] === 0) {
    fwrite(STDERR, "SELFCHECK-FAILED: scanned " . count($rows)
        . " components and not one was compliant. This probe is broken; the result is not a finding.\n");
    exit(2);
}

// Named components are an ASSERTION: any failure among them is exit 1.
// A bare scan is a REPORT: it exits 0 and lets the caller read the summary,
// because a fleet-wide scan of core will always surface something.
if ($components && $failednamed > 0) {
    exit(1);
}
exit(0);
