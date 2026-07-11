<?php
/**
 * Upgrade script for local_nwc_erase (ops#81).
 *
 * @package    local_nwc_erase
 * @copyright  2026 NWC
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */
defined('MOODLE_INTERNAL') || die();

/**
 * @param int $oldversion the version we are upgrading from
 * @return bool result
 */
function xmldb_local_nwc_erase_upgrade($oldversion) {
    // No upgrade steps yet — install.xml defines the current schema (1.0.0).
    return true;
}
