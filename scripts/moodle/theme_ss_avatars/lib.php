<?php
// theme_ss_avatars — library.
//
// Minimal: the theme adds no SCSS of its own (it inherits the parent's look),
// so the extra-SCSS callback returns nothing. Present only because config.php
// references it.

defined('MOODLE_INTERNAL') || die();

/**
 * Extra SCSS appended after the parent theme's SCSS. None for this theme.
 *
 * @param \theme_config $theme
 * @return string
 */
function theme_ss_avatars_get_extra_scss($theme): string {
    return '';
}
