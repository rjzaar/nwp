<?php
// Restore task for mod_depthcontent.

defined('MOODLE_INTERNAL') || die();

require_once($CFG->dirroot . '/mod/depthcontent/backup/moodle2/restore_depthcontent_stepslib.php');

/**
 * The restore task that provides the settings and steps to perform a complete
 * restore of a depthcontent activity.
 */
class restore_depthcontent_activity_task extends restore_activity_task {

    /**
     * No activity-specific settings.
     */
    protected function define_my_settings() {
    }

    /**
     * Define the single restore step.
     */
    protected function define_my_steps() {
        $this->add_step(new restore_depthcontent_activity_structure_step('depthcontent_structure', 'depthcontent.xml'));
    }

    /**
     * Content areas to be decoded (intro).
     *
     * @return restore_decode_content[]
     */
    public static function define_decode_contents() {
        $contents = [];
        $contents[] = new restore_decode_content('depthcontent', ['intro'], 'depthcontent');
        return $contents;
    }

    /**
     * Link-decoding rules matching backup's encode_content_links().
     *
     * @return restore_decode_rule[]
     */
    public static function define_decode_rules() {
        $rules = [];
        $rules[] = new restore_decode_rule('DEPTHCONTENTVIEWBYID',
            '/mod/depthcontent/view.php?id=$1', 'course_module');
        $rules[] = new restore_decode_rule('DEPTHCONTENTINDEX',
            '/mod/depthcontent/index.php?id=$1', 'course');
        return $rules;
    }
}
