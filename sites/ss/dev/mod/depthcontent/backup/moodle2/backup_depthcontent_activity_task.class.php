<?php
// Backup task for mod_depthcontent.

defined('MOODLE_INTERNAL') || die();

require_once($CFG->dirroot . '/mod/depthcontent/backup/moodle2/backup_depthcontent_stepslib.php');

/**
 * The backup task that provides all the settings and steps to perform a
 * complete backup of a depthcontent activity.
 */
class backup_depthcontent_activity_task extends backup_activity_task {

    /**
     * No activity-specific settings.
     */
    protected function define_my_settings() {
    }

    /**
     * Define the single structure step.
     */
    protected function define_my_steps() {
        $this->add_step(new backup_depthcontent_activity_structure_step('depthcontent_structure', 'depthcontent.xml'));
    }

    /**
     * Encode absolute links to this module so they survive backup/restore.
     *
     * @param string $content
     * @return string
     */
    public static function encode_content_links($content) {
        global $CFG;

        $base = preg_quote($CFG->wwwroot, '/');

        // Link to the index of depthcontents in a course.
        $content = preg_replace(
            '/(' . $base . '\/mod\/depthcontent\/index\.php\?id\=)([0-9]+)/',
            '$@DEPTHCONTENTINDEX*$2@$',
            $content
        );

        // Link to a single depthcontent view by course-module id.
        $content = preg_replace(
            '/(' . $base . '\/mod\/depthcontent\/view\.php\?id\=)([0-9]+)/',
            '$@DEPTHCONTENTVIEWBYID*$2@$',
            $content
        );

        return $content;
    }
}
