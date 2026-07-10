<?php
// Theme config for theme_ss_avatars.
//
// This is a thin child theme. Its purpose is the renderer override in
// classes/output/core_renderer.php; it inherits everything visual from its
// parent.
//
// TODO(build-host): set $THEME->parents to the theme actually ENABLED on ss.
// The ss dev tree ships only core 'boost' and 'classic'; the live site may run
// a custom child of boost. Confirm the enabled theme and set the parent to it
// so the look is unchanged and only the avatar rendering is added. If ss runs
// a custom theme, the cleaner option is to move the core_renderer override
// INTO that theme instead of stacking another child (a page has one theme, so
// two independent avatar/theme children cannot both apply).

defined('MOODLE_INTERNAL') || die();

$THEME->name = 'ss_avatars';

// TODO(build-host): replace 'boost' with the site's active theme.
$THEME->parents = ['boost'];

// No extra sheets — we only change the user-picture renderer.
$THEME->sheets = [];
$THEME->editor_sheets = [];

// Force Moodle to use overridden renderers from this theme.
$THEME->rendererfactory = 'theme_overridden_renderer_factory';

// Inherit boost's SCSS pipeline so the parent look is preserved.
$THEME->scss = function($theme) {
    return theme_boost_get_main_scss_content($theme);
};

$THEME->enable_dock = false;
$THEME->extrascsscallback = 'theme_ss_avatars_get_extra_scss';
