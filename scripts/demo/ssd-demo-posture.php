<?php
// ops#133 Phase 2 — demo posture for the ssd (Moodle) half of the demo pair.
//
// Staged into the Moodle root and run there by scripts/demo/ssd-demo-posture.sh:
//   DEMO_PROVIDER_URL=... DEMO_FEEDBACK_URL=... php8.3 ssd_demo_posture.php [--check]
//
// IDEMPOTENT. Applies the proposal §2.5 safety posture on the Moodle side:
//   * noindex EVERYWHERE            ($CFG->allowindexing = 2)
//   * outbound mail KILLED          ($CFG->noemailever = 1, divert as belt+braces)
//   * a permanent "erased nightly" BANNER on every page, carrying the
//     "Report a problem" link back to the provider's feedback form (v1 of the
//     cross-site report path — the proposal explicitly allows linking back)
//   * self-registration OFF         (accounts arrive by SSO only)
//   * a machine-readable demo marker ($CFG->nwp_demo_mode = 1) — the SAME
//     opt-in fact the live reset guard requires before it will wipe anything.
//
// --check exits 0 only if every posture fact is already true (used by the
// paired reset's post-restore verification and by the bats suite).
//
// Nothing here touches plugin code or user data.

define('CLI_SCRIPT', true);

$root = null;
foreach ([getcwd(), __DIR__] as $cand) {
    if (is_file("$cand/config.php") && is_dir("$cand/lib")) { $root = $cand; break; }
}
if ($root === null) { fwrite(STDERR, "Cannot find Moodle root\n"); exit(2); }
require("$root/config.php");
require_once($CFG->libdir . '/clilib.php');

$checkonly = in_array('--check', $argv, true);

$provider = rtrim((string) getenv('DEMO_PROVIDER_URL'), '/');
$feedback = (string) getenv('DEMO_FEEDBACK_URL');
if ($provider === '') {
    cli_error('DEMO_PROVIDER_URL not set (the nwd base URL) — refusing to write a banner with a dead link.');
}
if ($feedback === '') {
    $feedback = $provider . '/demo/feedback';
}

// The banner. Fixed to the top of the body on every page; the link opens the
// provider-side report form (same GitLab queue as nwd's own reports).
// Kept as plain inline-styled HTML so it survives any theme.
$banner = '<div id="nwp-demo-banner" role="status" style="'
    . 'position:relative;z-index:9999;padding:.55rem 1rem;'
    . 'background:#7a1f1f;color:#fff;font:600 .95rem/1.35 system-ui,sans-serif;'
    . 'text-align:center;">'
    . 'Demo site — everything here is erased nightly. Nothing you enter is kept. '
    . '<a href="' . s($feedback) . '?source=ssd" target="_blank" rel="noopener" style="'
    . 'color:#fff;text-decoration:underline;font-weight:700;">Report a problem</a>'
    . '</div>';

$want = [
    // name                    => value
    'allowindexing'            => '2',   // 2 = nowhere (0 = everywhere except login)
    'noemailever'              => '1',   // hard mail kill
    'registerauth'             => '',    // no self-registration; SSO only
    'additionalhtmltopofbody'  => $banner,
    'nwp_demo_mode'            => '1',   // the demo opt-in marker (reset guard)
];

$bad = [];
foreach ($want as $name => $value) {
    $current = isset($CFG->{$name}) ? (string) $CFG->{$name} : null;
    if ($current === (string) $value) {
        continue;
    }
    if ($checkonly) {
        $bad[] = $name;
        continue;
    }
    set_config($name, $value);
    cli_writeln("set $name");
}

// Mail diversion as belt-and-braces: if noemailever were ever cleared by hand,
// everything still lands in a black hole rather than a real inbox.
if (!$checkonly) {
    set_config('divertallemailsto', 'demo-blackhole@demo.invalid');
} else if ((string) ($CFG->divertallemailsto ?? '') === '') {
    $bad[] = 'divertallemailsto';
}

if ($checkonly) {
    if ($bad) {
        cli_writeln('DEMO-POSTURE-FAIL: ' . implode(',', $bad));
        exit(1);
    }
    cli_writeln('DEMO-POSTURE-OK');
    exit(0);
}

purge_all_caches();
cli_writeln('OK: demo posture applied (noindex=2, noemailever=1, banner, no self-registration, nwp_demo_mode=1)');
