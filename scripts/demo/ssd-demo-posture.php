<?php
// ops#133 Phase 2 — demo posture for the ssd (Moodle) half of the demo pair.
//
// Staged into the Moodle root and run there by scripts/demo/ssd-demo-posture.sh:
//   DEMO_PROVIDER_URL=... DEMO_FEEDBACK_URL=... php8.3 ssd_demo_posture.php [--check]
//
// IDEMPOTENT. Applies the proposal §2.5 safety posture on the Moodle side:
//   * noindex EVERYWHERE            ($CFG->allowindexing = 2)
//   * outbound mail KILLED          ($CFG->noemailever = 1, divert as belt+braces)
//   * a permanent "erased nightly" BANNER on every page (sticky, and with the
//     matching offsets for Boost's viewport-anchored chrome — see the banner
//     block below), carrying the
//     "Report a problem" link back to the provider's feedback form (v1 of the
//     cross-site report path — the proposal explicitly allows linking back)
//   * self-registration OFF         (accounts arrive by SSO only)
//   * human site identity           (site course fullname/shortname — the
//                                    shortname is what Moodle puts in every
//                                    page <title>; 'ssd' is an internal code)
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

// The banner. Pinned to the top of every page; the link opens the
// provider-side report form (same GitLab queue as nwd's own reports).
// Kept as plain inline-styled HTML so it survives any theme.
//
// LAYOUT — why this is not just a coloured div.
// Moodle injects additionalhtmltopofbody immediately after <body>, and Boost's
// main navigation is `position: fixed; top: 0` (`.navbar.fixed-top`, z-index
// 1030). Both therefore occupy the same rectangle at the top of the viewport.
// The first version of this banner answered that with `position: relative;
// z-index: 9999`, which won the paint — and so the banner covered the ENTIRE
// navigation bar at every width. On a phone that includes the drawer-toggle
// hamburger, i.e. a tester could not open the navigation at all. (Hit-tested
// on ssd 2026-08-01: five sample points across the navbar, none of them
// reachable.)
//
// The fix is layout, not z-index, and deliberately NOT `position: fixed`:
//   * `sticky` keeps the banner in NORMAL FLOW, so Boost's own `#page
//     { margin-top: 60px }` is measured from below the banner and stays
//     correct without a second magic number to keep in sync;
//   * and it still pins the banner to the top of the viewport on scroll, so a
//     disclosure that must always be readable always is.
// What flow cannot fix is the chrome that is anchored to the VIEWPORT rather
// than to the document — the navbar itself, the drawers and the drawer
// togglers, all of which hard-code Boost's 60px navbar height. Each is offset
// below by exactly the banner's height.
//
// That height is not a constant: the string wraps to two lines on a phone
// (38px at 1280px wide, 59px at 390px), so it is carried in a custom property
// that the script measures live. The CSS values are the no-JS fallback, and
// are deliberately generous — too much space merely looks roomy, too little
// puts the navigation back on top of the disclosure.
$bannercss = '<style id="nwp-demo-banner-css">'
    . ':root{--nwp-demo-banner-h:40px}'
    . '@media (max-width:600px){:root{--nwp-demo-banner-h:62px}}'
    . 'body .navbar.fixed-top{top:var(--nwp-demo-banner-h)}'
    . 'body .drawer{top:var(--nwp-demo-banner-h);'
    . 'height:calc(100vh - var(--nwp-demo-banner-h))}'
    . '@media (min-width:992px){body .drawer-left,body .drawer-right{'
    . 'top:calc(60px + var(--nwp-demo-banner-h));'
    . 'height:calc(100vh - 60px - var(--nwp-demo-banner-h))}}'
    . 'body .drawer-toggles .drawer-toggler{'
    . 'top:calc(60px + 0.7rem + var(--nwp-demo-banner-h))}'
    // Boost anchors the togglers to the BOTTOM of the viewport on small
    // screens; the rule above would otherwise drag them back to the top.
    . '@media (max-width:767.98px){body .drawer-toggles .drawer-right-toggle,'
    . 'body .drawer-toggles .drawer-left-toggle{top:calc(99vh - 150px)}}'
    . '</style>';

$bannerjs = '<script>(function(){'
    . 'var b=document.getElementById("nwp-demo-banner");if(!b){return;}'
    . 'function s(){document.documentElement.style.setProperty('
    . '"--nwp-demo-banner-h",b.offsetHeight+"px");}'
    . 's();'
    . 'if(window.ResizeObserver){new ResizeObserver(s).observe(b);}'
    . 'else{window.addEventListener("resize",s);}'
    . 'window.addEventListener("load",s);'
    . '})();</script>';

$banner = $bannercss
    . '<div id="nwp-demo-banner" role="status" style="'
    . 'position:-webkit-sticky;position:sticky;top:0;z-index:1040;'
    . 'padding:.55rem 1rem;'
    . 'background:#7a1f1f;color:#fff;font:600 .95rem/1.35 system-ui,sans-serif;'
    . 'text-align:center;">'
    . 'Demo site — everything here is erased nightly. Nothing you enter is kept. '
    . '<a href="' . s($feedback) . '?source=ssd" target="_blank" rel="noopener" style="'
    . 'color:#fff;text-decoration:underline;font-weight:700;">Report a problem</a>'
    . '</div>'
    . $bannerjs;

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

// Human site identity. Moodle appends the SITE COURSE's shortname to every
// page <title> ("Home | ssd"), so the machine code 'ssd' leaked into browser
// tabs, bookmarks and search snippets on every page a tester saw. The site
// course row is not $CFG, hence this block rather than a $want entry. The
// names are demo-tier facts of THIS script's site (the file is ssd-specific
// by name, like the banner text above), not contract endpoints — hardcoded
// deliberately, next to the other hardcoded ssd facts.
$wantfullname  = 'Saint School (Demo)';
$wantshortname = 'Saint School (Demo)';
$site = $DB->get_record('course', ['id' => SITEID], 'id,fullname,shortname', MUST_EXIST);
if ($site->fullname !== $wantfullname || $site->shortname !== $wantshortname) {
    if ($checkonly) {
        $bad[] = 'site_identity';
    } else {
        cli_writeln("site fullname:  '{$site->fullname}' → '{$wantfullname}'");
        cli_writeln("site shortname: '{$site->shortname}' → '{$wantshortname}'");
        $site->fullname  = $wantfullname;
        $site->shortname = $wantshortname;
        $DB->update_record('course', $site);
    }
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
cli_writeln('OK: demo posture applied (noindex=2, noemailever=1, banner, no self-registration, nwp_demo_mode=1, site identity)');
