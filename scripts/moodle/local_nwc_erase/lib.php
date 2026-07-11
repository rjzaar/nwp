<?php
/**
 * local_nwc_erase — library hooks.
 *
 * The receiver entry point is erase.php (not a Moodle web service — a plain PHP
 * endpoint guarded by a Bearer token, mirroring local_nwc_copyright_sync). Keep
 * this file minimal so plugin scanning works.
 */
defined('MOODLE_INTERNAL') || die();
