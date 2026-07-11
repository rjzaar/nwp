<?php
// Restore structure step for mod_depthcontent.

defined('MOODLE_INTERNAL') || die();

/**
 * Defines the structure step to restore one depthcontent activity.
 */
class restore_depthcontent_activity_structure_step extends restore_activity_structure_step {

    protected function define_structure() {
        $paths = [];
        $userinfo = $this->get_setting_value('userinfo');

        $paths[] = new restore_path_element('depthcontent', '/activity/depthcontent');

        if ($userinfo) {
            $paths[] = new restore_path_element('depthcontent_progress',
                '/activity/depthcontent/progresses/progress');
            $paths[] = new restore_path_element('depthcontent_response',
                '/activity/depthcontent/responses/response');
            $paths[] = new restore_path_element('depthcontent_sr',
                '/activity/depthcontent/srs/sr');
        }

        // Wrap and return.
        return $this->prepare_activity_structure($paths);
    }

    protected function process_depthcontent($data) {
        global $DB;

        $data = (object)$data;
        $data->course = $this->get_courseid();
        $data->timemodified = $this->apply_date_offset($data->timemodified);

        // Insert the depthcontent instance and hook it to the course module.
        $newitemid = $DB->insert_record('depthcontent', $data);
        $this->apply_activity_instance($newitemid);
    }

    protected function process_depthcontent_progress($data) {
        global $DB;

        $data = (object)$data;
        $data->depthcontentid = $this->get_new_parentid('depthcontent');
        $data->userid = $this->get_mappingid('user', $data->userid);
        $data->timecreated = $this->apply_date_offset($data->timecreated);
        $data->timemodified = $this->apply_date_offset($data->timemodified);

        $DB->insert_record('depthcontent_progress', $data);
    }

    protected function process_depthcontent_response($data) {
        global $DB;

        $data = (object)$data;
        $data->depthcontentid = $this->get_new_parentid('depthcontent');
        $data->userid = $this->get_mappingid('user', $data->userid);
        $data->timecreated = $this->apply_date_offset($data->timecreated);

        $DB->insert_record('depthcontent_responses', $data);
    }

    protected function process_depthcontent_sr($data) {
        global $DB;

        $data = (object)$data;
        $data->depthcontentid = $this->get_new_parentid('depthcontent');
        $data->userid = $this->get_mappingid('user', $data->userid);
        $data->next_review = $this->apply_date_offset($data->next_review);
        $data->last_reviewed = $this->apply_date_offset($data->last_reviewed);

        $DB->insert_record('depthcontent_sr', $data);
    }

    protected function after_execute() {
        // Restore the intro editor files.
        $this->add_related_files('mod_depthcontent', 'intro', null);
    }
}
