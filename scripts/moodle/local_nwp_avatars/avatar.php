<?php
// Local SVG avatar route:  /local/nwp_avatars/avatar.php?saint=francis&colour=royal-blue[&size=100]
//
// Serves the chosen avatar as image/svg+xml, rendered locally from the bundled
// avatar_manager (NO runtime dependency on nwc — see design §4). Cached
// immutably: (saint, colour, size) fully determines the bytes.
//
// This is a public, read-only, no-PII image route (the saint+colour are not
// personal data), so it runs without login — same posture as Moodle's own
// theme/image.php. If access must be gated, wrap in require_login() on the
// build host (design item: confirm whether avatars should be visible to
// guests / logged-out users on ss).

// No Moodle session/cookies needed to render a static SVG.
define('NO_MOODLE_COOKIES', true);
define('NO_UPGRADE_CHECK', true);

require_once(__DIR__ . '/../../config.php');
require_once(__DIR__ . '/classes/avatar_manager.php');

$saint  = optional_param('saint', '', PARAM_ALPHANUMEXT);
$colour = optional_param('colour', '', PARAM_ALPHANUMEXT);
$size   = optional_param('size', 120, PARAM_INT);

// Clamp size to a sane range.
if ($size < 16) {
    $size = 16;
}
if ($size > 512) {
    $size = 512;
}

$mgr = new \local_nwp_avatars\avatar_manager();
$choice = $mgr->normalise_selection($saint, $colour);
$svg = $mgr->render($choice['saint'], $choice['colour'], $size);

// Long-lived immutable cache (bytes are a pure function of the query).
$lifetime = 60 * 60 * 24 * 365; // 1 year.
header('Content-Type: image/svg+xml; charset=utf-8');
header('Content-Length: ' . strlen($svg));
header('Cache-Control: public, max-age=' . $lifetime . ', immutable');
header('Expires: ' . gmdate('D, d M Y H:i:s', time() + $lifetime) . ' GMT');
header('Content-Disposition: inline; filename="' . $choice['saint'] . '-' . $choice['colour'] . '.svg"');

echo $svg;
