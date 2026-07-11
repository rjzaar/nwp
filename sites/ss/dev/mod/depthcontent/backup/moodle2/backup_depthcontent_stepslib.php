<?php
// Backup structure step for mod_depthcontent.
//
// Backs up the activity instance (the learning content) plus the three
// per-instance user-data tables (progress, responses, spaced-repetition),
// gated on the standard `userinfo` setting.
//
// Deliberately NOT backed up here: the S13 feedback tables
// (depthcontent_fb_state / _fb_events / _fb_votes). Those are keyed by
// (courseid, pointid) rather than by the activity instance id — they are
// course-shared feedback state, not per-activity user data — so they do not
// belong in a per-activity backup. See README / db/install.xml.

defined('MOODLE_INTERNAL') || die();

/**
 * Defines the complete depthcontent backup structure.
 */
class backup_depthcontent_activity_structure_step extends backup_activity_structure_step {

    protected function define_structure() {

        // Are we including user info?
        $userinfo = $this->get_setting_value('userinfo');

        // Root activity element (the content lives in content_json + pointid).
        $depthcontent = new backup_nested_element('depthcontent', ['id'], [
            'name', 'intro', 'introformat', 'pointid', 'content_json', 'timemodified',
        ]);

        // Per-instance user data.
        $progresses = new backup_nested_element('progresses');
        $progress = new backup_nested_element('progress', ['id'], [
            'userid', 'status', 'depth_viewed', 'mastered_via', 'timecreated', 'timemodified',
        ]);

        $responses = new backup_nested_element('responses');
        $response = new backup_nested_element('response', ['id'], [
            'userid', 'quizitemid', 'response', 'correct', 'timecreated',
        ]);

        $srs = new backup_nested_element('srs');
        $sr = new backup_nested_element('sr', ['id'], [
            'userid', 'ease_factor', 'interval_days', 'repetitions', 'next_review', 'last_reviewed',
        ]);

        // Build the tree.
        $depthcontent->add_child($progresses);
        $progresses->add_child($progress);

        $depthcontent->add_child($responses);
        $responses->add_child($response);

        $depthcontent->add_child($srs);
        $srs->add_child($sr);

        // Data sources.
        $depthcontent->set_source_table('depthcontent', ['id' => backup::VAR_ACTIVITYID]);

        // Only include user rows when userinfo is requested.
        if ($userinfo) {
            $progress->set_source_table('depthcontent_progress', ['depthcontentid' => backup::VAR_PARENTID]);
            $response->set_source_table('depthcontent_responses', ['depthcontentid' => backup::VAR_PARENTID]);
            $sr->set_source_table('depthcontent_sr', ['depthcontentid' => backup::VAR_PARENTID]);
        }

        // Id annotations (so users are remapped on restore).
        $progress->annotate_ids('user', 'userid');
        $response->annotate_ids('user', 'userid');
        $sr->annotate_ids('user', 'userid');

        // File annotations — the standard intro editor area.
        $depthcontent->annotate_files('mod_depthcontent', 'intro', null);

        // Return the root wrapped for an activity.
        return $this->prepare_activity_structure($depthcontent);
    }
}
