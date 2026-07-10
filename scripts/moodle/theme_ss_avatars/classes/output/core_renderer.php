<?php
// theme_ss_avatars\output\core_renderer — overrides the single choke point
// through which every Moodle user picture is drawn.
//
// core_renderer::render_user_picture(user_picture) is called by forums,
// participant lists, course pages, core_user\output\myprofile, etc. By
// overriding it here (with $THEME->rendererfactory =
// theme_overridden_renderer_factory in config.php) we replace the photo/blank
// icon with the member's chosen patron-saint SVG served by local_nwp_avatars.
//
// TODO(build-host): verify this override actually reaches EVERY surface on the
// live ss 4.4 build. Emails (forum digests), the mobile app, and some web
// services (e.g. core_user_get_users profileimageurl) read user/icon directly
// and BYPASS a theme renderer — those may need the rasterise-to-PNG fallback
// (local_nwp_avatars setting rasterise_to_icon / design path (d)). Test on ss.

namespace theme_ss_avatars\output;

defined('MOODLE_INTERNAL') || die();

use user_picture;

/**
 * Renderer overriding user pictures with NWP avatars.
 */
class core_renderer extends \core_renderer {

    /**
     * Render a user picture as the chosen NWP avatar SVG.
     *
     * Falls back to the parent renderer if the plugin helper is unavailable or
     * the picture has no resolvable user, so nothing breaks if the local
     * plugin is disabled.
     *
     * @param user_picture $userpicture
     * @return string HTML
     */
    protected function render_user_picture(user_picture $userpicture) {
        global $CFG;

        $libfile = $CFG->dirroot . '/local/nwp_avatars/lib.php';
        if (!is_readable($libfile)) {
            return parent::render_user_picture($userpicture);
        }
        require_once($libfile);

        $user = $userpicture->user;
        if (empty($user) || empty($user->id)) {
            return parent::render_user_picture($userpicture);
        }

        // Size hint: user_picture->size may be an int (px) or a bool (default).
        $size = 100;
        if (is_int($userpicture->size) && $userpicture->size > 0) {
            $size = $userpicture->size;
        } else if ($userpicture->size === true || $userpicture->size === false) {
            $size = 100;
        }

        $src = local_nwp_avatars_url($user, $size);

        $fullname = fullname($user, has_capability('moodle/site:viewfullnames', $this->page->context));
        $alt = $userpicture->alttext ? $fullname : '';

        $attrs = [
            'src'    => $src->out(false),
            'alt'    => $alt,
            'title'  => $alt,
            'width'  => $size,
            'height' => $size,
            'class'  => 'userpicture nwp-avatar',
            // SVG is decorative-with-alt; keep it out of the a11y tree when no alt.
            'role'   => 'img',
        ];
        if (!empty($userpicture->class)) {
            $attrs['class'] .= ' ' . $userpicture->class;
        }

        $img = \html_writer::empty_tag('img', $attrs);

        // Preserve the link-to-profile behaviour of the core widget.
        if ($userpicture->link) {
            $courseid = $userpicture->courseid ?: SITEID;
            $url = new \moodle_url('/user/view.php', [
                'id'     => $user->id,
                'course' => $courseid,
            ]);
            return \html_writer::link($url, $img, ['class' => 'nwp-avatar-link']);
        }

        return $img;
    }
}
