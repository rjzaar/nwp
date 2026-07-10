<?php
// Standalone render + Drupal-parity test for local_nwp_avatars.
//
// This is NOT a PHPUnit/Moodle test (there is no Moodle bootstrap available
// on the dev workstation). It is a plain CLI script — the Moodle counterpart
// of the Drupal module's own render smoke test — that:
//
//   1. Instantiates the ported avatar_manager,
//   2. Renders every saint × a sample of colours,
//   3. Asserts each output is well-formed SVG (opens <svg>, closes </svg>,
//      contains the bg <circle>, balanced-ish),
//   4. If the canonical Drupal source of truth is reachable, asserts the
//      Moodle render() output is BYTE-IDENTICAL to the Drupal
//      AvatarManager::render() for the same inputs (the art must be the same).
//
// Run:  php scripts/moodle/local_nwp_avatars/tests/render_match_test.php
// The Drupal source is auto-located relative to the nwp repo, or via
// NWP_AVATARS_DRUPAL_SOURCE=/path/to/AvatarManager.php.
//
// Exit code 0 = all assertions passed (parity check skipped counts as pass
// with a loud warning); non-zero = a failure.

error_reporting(E_ALL);

// avatar_manager.php guards on MOODLE_INTERNAL; define it so we can load the
// class outside a Moodle bootstrap.
if (!defined('MOODLE_INTERNAL')) {
    define('MOODLE_INTERNAL', true);
}

require __DIR__ . '/../classes/avatar_manager.php';

$fail = 0;
$checks = 0;

function check(bool $cond, string $msg): void {
    global $fail, $checks;
    $checks++;
    if (!$cond) {
        $fail++;
        fwrite(STDERR, "  FAIL: $msg\n");
    }
}

$mgr = new \local_nwp_avatars\avatar_manager();

$avatars = $mgr->get_avatars();
$colours = $mgr->get_colours();

echo "local_nwp_avatars render test\n";
echo '  avatars: ' . count($avatars) . ' | colours: ' . count($colours) . "\n";

// Expected structural counts (mirrors the Drupal source of truth).
check(count($avatars) === 67, 'expected 67 avatars, got ' . count($avatars));
check(count($colours) === 10, 'expected 10 colours, got ' . count($colours));

// Sample of colours to cross with every saint.
$samplecolours = ['royal-blue', 'forest-green', 'ruby', 'purple'];

$rendered = 0;
foreach (array_keys($avatars) as $saint) {
    foreach ($samplecolours as $colour) {
        $svg = $mgr->render($saint, $colour, 120);
        $rendered++;

        // Well-formedness assertions.
        check(str_starts_with($svg, '<svg '), "svg opens for $saint/$colour");
        check(str_ends_with($svg, '</svg>'), "svg closes for $saint/$colour");
        check(substr_count($svg, '<svg') === 1, "single root svg for $saint/$colour");
        check(str_contains($svg, 'class="avatar-bg"'), "bg circle for $saint/$colour");
        check(str_contains($svg, $colours[$colour]['bg']), "bg colour hex for $saint/$colour");

        // A non-empty symbol body must be present for every defined saint.
        $symbol = $mgr->get_symbol_svg($saint);
        check($symbol !== '', "non-empty symbol for $saint");

        // Parse as XML to guarantee well-formedness (SVG is XML).
        $prev = libxml_use_internal_errors(true);
        $xml = simplexml_load_string($svg);
        libxml_use_internal_errors($prev);
        check($xml !== false, "well-formed XML for $saint/$colour");
    }
}
echo "  rendered $rendered avatar variants\n";

// ---------------------------------------------------------------------------
// Drupal-parity check: identical art on both platforms.
// ---------------------------------------------------------------------------
$drupalsource = getenv('NWP_AVATARS_DRUPAL_SOURCE') ?: '';
if ($drupalsource === '') {
    // Auto-locate within the nwp repo (dev workstation only). Walk up to the
    // repo root and look for the canonical module.
    $candidates = [];
    $dir = __DIR__;
    for ($i = 0; $i < 8; $i++) {
        $candidates[] = $dir . '/sites/mayo/dev/html/modules/custom/mayo_avatars/src/AvatarManager.php';
        $candidates[] = $dir . '/sites/nwc/dev/html/profiles/custom/nwc/modules/custom/nwp_avatars/src/AvatarManager.php';
        $dir = dirname($dir);
    }
    foreach ($candidates as $c) {
        if (is_file($c)) {
            $drupalsource = $c;
            break;
        }
    }
}

if ($drupalsource !== '' && is_file($drupalsource)) {
    echo "  parity source: $drupalsource\n";

    // Load the Drupal class. It declares namespace Drupal\<module>\AvatarManager.
    // Read the source to discover its namespace, then include it.
    $src = file_get_contents($drupalsource);
    if (preg_match('/namespace\s+([^;]+);/', $src, $m)) {
        $ns = trim($m[1]);
        $fqcn = '\\' . $ns . '\\AvatarManager';
        require $drupalsource;

        if (class_exists($fqcn)) {
            $drupal = new $fqcn();
            $mismatch = 0;
            foreach (array_keys($avatars) as $saint) {
                foreach ($samplecolours as $colour) {
                    $a = $mgr->render($saint, $colour, 120);
                    $b = $drupal->render($saint, $colour, 120);
                    if ($a !== $b) {
                        $mismatch++;
                        if ($mismatch <= 5) {
                            fwrite(STDERR, "  DRIFT: $saint/$colour differs from Drupal source\n");
                        }
                    }
                }
            }
            check($mismatch === 0, "$mismatch render(s) drifted from the Drupal source of truth");
            if ($mismatch === 0) {
                echo "  parity: OK — Moodle render() is byte-identical to Drupal for all sampled inputs\n";
            }
        } else {
            fwrite(STDERR, "  WARN: could not load $fqcn from $drupalsource — parity check SKIPPED\n");
        }
    } else {
        fwrite(STDERR, "  WARN: no namespace found in $drupalsource — parity check SKIPPED\n");
    }
} else {
    fwrite(STDERR, "  WARN: Drupal source of truth not found — parity check SKIPPED.\n");
    fwrite(STDERR, "        Set NWP_AVATARS_DRUPAL_SOURCE to enforce byte-parity.\n");
}

echo "\n";
echo "checks: $checks | failures: $fail\n";
if ($fail > 0) {
    echo "RESULT: FAIL\n";
    exit(1);
}
echo "RESULT: PASS\n";
exit(0);
