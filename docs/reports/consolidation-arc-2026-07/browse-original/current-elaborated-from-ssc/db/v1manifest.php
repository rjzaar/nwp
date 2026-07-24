<?php
/**
 * Seed manifest for the Browse tab's N8 "v1 archive" catalog-version toggle.
 *
 * ss2 is the FROZEN v1 archive (the older 49 courses). When a visitor flips the
 * Browse tab to `cat=v1`, the plugin renders READ-ONLY deep-links to those courses
 * on the archive site rather than the live v3 catalog — there is no re-import.
 *
 * The archive host is NOT hard-coded here: each entry carries a relative `path`,
 * and the plugin prefixes it with the `local_browse | v1_base_url` admin setting.
 * If `v1_base_url` is empty the tab shows the titles with an "archive URL not
 * configured" notice instead of broken links (guest-safe, no live config touched).
 *
 * Deep-link strategy: Moodle's /course/view.php accepts `?name=<shortname>`, and
 * ss2's courses keep the same A1..J7 shortcodes, so the link is stable without
 * knowing ss2's internal course ids.
 *
 * Titles below are ss2's (v1) titles verbatim — several differ from the v3
 * repunctuated/renamed equivalents (e.g. v1 D6 = "Discernment in Daily Life").
 *
 * @package    local_browse
 * @copyright  2026 Saint School
 * @license    https://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

defined('MOODLE_INTERNAL') || die();

/**
 * The v1 (ss2) archive manifest — 49 frozen courses.
 *
 * @return array {version:int, courses:[{code, title, path}, ...]}
 */
function local_browse_v1_manifest(): array {
    $mk = function(string $code, string $title): array {
        return ['code' => $code, 'title' => $title, 'path' => '/course/view.php?name=' . $code];
    };
    return [
        'version' => 1,
        'courses' => [
            $mk('A1', 'The Universal Call to Holiness'),
            $mk('A2', 'The Interior Castle — A Map of the Soul'),
            $mk('A3', 'The Three Phases of the Spiritual Life'),
            $mk('A4', 'The Paradigm of Ascent'),
            $mk('A5', 'The Sacraments and Grace'),
            $mk('B1', 'Why Prayer Is Essential'),
            $mk('B2', 'Sacred Time, Sacred Space, Sacred Attention'),
            $mk('B3', 'Discovery Prayer (Lectio Divina)'),
            $mk('B4', 'Distractions in Prayer — The Monkeys'),
            $mk('B5', 'The Daily Examen'),
            $mk('B6', 'The Rosary as Mental Prayer'),
            $mk('C1', 'The Transition from Meditation to Contemplation'),
            $mk('C2', 'The Prayer of Simplicity'),
            $mk('C3', 'Contemplative Prayer'),
            $mk('C4', 'Aridity in Prayer and the Dark Night'),
            $mk('C5', "Teresa's Four Waters and the Prayer of Quiet"),
            $mk('D1', 'The Battle Within'),
            $mk('D2', 'Consolation and Desolation'),
            $mk('D3', 'Ignatian Rules 1-5 — The Foundation'),
            $mk('D4', 'Ignatian Rules 6-9 — Fighting Back'),
            $mk('D5', 'Ignatian Rules 10-14 — Advanced Discernment'),
            $mk('D6', 'Discernment in Daily Life'),
            $mk('E1', 'Self-Knowledge and the Predominant Fault'),
            $mk('E2', 'Appetites, Attachments, and Freedom'),
            $mk('E3', 'Mortification With Love'),
            $mk('E4', 'The Little Way of St. Therese'),
            $mk('E5', 'Fasting and Overcoming Habitual Sin'),
            $mk('F1', 'Everything Is Willed or Permitted by God'),
            $mk('F2', 'Redemptive Suffering'),
            $mk('F3', 'The Reality of Spiritual Warfare'),
            $mk('F4', 'Defence Against the Enemy'),
            $mk('G1', 'Marriage and the Interior Castle'),
            $mk('G2', 'Spiritual Warfare in Marriage'),
            $mk('G3', 'Community — Alone to Hell, Together to Heaven'),
            $mk('G4', 'Spiritual Direction'),
            $mk('H1', 'St. Therese — Confidence, Mercy, and the Little Way'),
            $mk('H2', 'St. John of the Cross — The Mountain of Ascent'),
            $mk('H3', 'St. Ignatius — Discernment as Freedom'),
            $mk('H4', 'Fr. Jacques Philippe — Praying as a Poor Person'),
            $mk('I1', 'Centering Prayer — Why It Is Not Contemplation'),
            $mk('I2', 'Mindfulness, Eastern Meditation, and False Peace'),
            $mk('I3', 'Yoga and Gateway Spirituality'),
            $mk('J1', 'The First Mansion — Entering the Castle'),
            $mk('J2', 'The Second Mansion — The Practice of Prayer'),
            $mk('J3', 'The Third Mansion — Purgative to Illuminative'),
            $mk('J4', 'The Fourth Mansion — Supernatural Prayer Begins'),
            $mk('J5', 'The Fifth Mansion — Union of Wills'),
            $mk('J6', 'The Sixth Mansion — Spiritual Betrothal'),
            $mk('J7', 'The Seventh Mansion — Spiritual Marriage'),
        ],
    ];
}
