<?php
/**
 * Seed data for the Curated ("Where would you like to begin?") tab.
 *
 * This is the SHIPPED FALLBACK for the intent-tile data contract. At runtime
 * the plugin prefers the `local_browse | intent_tiles_json` admin setting (which
 * the nwc Theology-Editor authoring / def-sync path can overwrite without a code
 * change); if that setting is empty or invalid, this seed renders instead so the
 * Curated tab always works standalone.
 *
 * DATA CONTRACT (version 1) — the nwc authoring agent codes to this shape:
 *
 *   {
 *     "version": 1,
 *     "tiles": [
 *       {
 *         "id":           slug (stable, unique),
 *         "heading":      short intent phrase ("I'm new to the spiritual life"),
 *         "blurb":        one- or two-sentence description of who this is for,
 *         "action_label": call-to-action label for the tile,
 *         "order":        int (ascending render order),
 *         "courses":      [shortcode, ...]  (ordered course codes, e.g. A1, B4)
 *       },
 *       ...
 *     ]
 *   }
 *
 * A course shortcode that does not resolve to a visible course in THIS Moodle is
 * skipped gracefully at render time (so tiles can safely list not-yet-built codes).
 *
 * This seed is the ss2 "10 intent tiles" ported into data and re-pointed at ssc's
 * own v3 courses (the 11 authored pathway YAMLs are the backbone). It deliberately
 * places the 6 v3-new courses (A6, A7, A8, B7, D7, D8) so the curated map covers
 * the whole catalog. The Theology Guild owns the CONTENT (headings, blurbs, per-tile
 * sequence); engineering owns only this MECHANISM.
 *
 * @package    local_browse
 * @copyright  2026 Saint School
 * @license    https://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

defined('MOODLE_INTERNAL') || die();

/**
 * The shipped intent-tile seed.
 *
 * @return array data-contract structure {version:int, tiles:array}
 */
function local_browse_intent_tiles_seed(): array {
    return [
        'version' => 1,
        'tiles' => [
            [
                'id' => 'beginner',
                'heading' => "I'm new to the spiritual life",
                'blurb' => 'The on-ramp: the universal call, the Paradigm of Ascent as a map, '
                    . 'then daily prayer, the sacraments rhythm, and the Examen.',
                'action_label' => 'Start here',
                'order' => 1,
                'courses' => ['A1', 'A4', 'B1', 'B4', 'A5', 'A6', 'B5', 'B2', 'B3', 'B6'],
            ],
            [
                'id' => 'mass-centred',
                'heading' => 'I want to pray the Mass better',
                'blurb' => 'The Mass as the subject of formation: Sacraments and Confession, '
                    . 'then the Mass walked externally and interiorly, capped by the Paradigm of Ascent.',
                'action_label' => 'Begin',
                'order' => 2,
                'courses' => ['A5', 'A6', 'A7', 'A8', 'B5', 'A4'],
            ],
            [
                'id' => 'prayer-deepening',
                'heading' => 'I already pray daily and want to grow',
                'blurb' => 'Past the beginner stage: the Carmelite frame, the progression through '
                    . 'aridity and the dark night, simplicity, and contemplation proper.',
                'action_label' => 'Go deeper',
                'order' => 3,
                'courses' => ['B6', 'B3', 'C1', 'C2', 'C3', 'C4', 'C5'],
            ],
            [
                'id' => 'apophatic-detox',
                'heading' => "I'm leaving centering prayer, mindfulness, or yoga",
                'blurb' => 'For someone trained in technique-based "prayer": the apophatic primer, '
                    . 'an audit of the false practices, then the positive Catholic alternative.',
                'action_label' => 'Re-orient',
                'order' => 4,
                'courses' => ['B7', 'I1', 'I2', 'I3', 'B6', 'C2', 'C3'],
            ],
            [
                'id' => 'discernment',
                'heading' => "I'm facing a major decision",
                'blurb' => 'Theory to rules to combat posture: consolation and desolation, the '
                    . 'Ignatian rules, then renunciation and daily defense.',
                'action_label' => 'Discern',
                'order' => 5,
                'courses' => ['D1', 'D2', 'D3', 'D4', 'D5', 'D6', 'D7', 'D8'],
            ],
            [
                'id' => 'spiritual-warfare-101',
                'heading' => 'I feel under spiritual attack',
                'blurb' => 'A practical combat stance: the reality of the battle, daily defense, '
                    . 'the renunciation drill, the "fight, don\'t run" posture, and false-practice audits.',
                'action_label' => 'Take up the shield',
                'order' => 6,
                'courses' => ['F3', 'D8', 'D7', 'D6', 'D2', 'I1', 'I2', 'I3'],
            ],
            [
                'id' => 'marriage',
                'heading' => 'I want to grow in holiness in my marriage',
                'blurb' => 'Marriage as a path of holiness: marriage and community, grounded in the '
                    . 'universal call and daily prayer, then the sacramental rhythm.',
                'action_label' => 'Begin together',
                'order' => 7,
                'courses' => ['G1', 'G2', 'A1', 'A4', 'B1', 'B5', 'A5', 'A6'],
            ],
            [
                'id' => 'ascetical',
                'heading' => 'I want to grow in self-mastery',
                'blurb' => 'The Ascesis rail walked deliberately: predominant fault, mortification, '
                    . 'fasting, the Little Way, the virtues, and the meaning of suffering.',
                'action_label' => 'Train',
                'order' => 8,
                'courses' => ['E1', 'E2', 'E3', 'E4', 'E5', 'F1', 'F2'],
            ],
            [
                'id' => 'interior-castle',
                'heading' => 'I want Teresa of Avila as my guide',
                'blurb' => "Teresa's Interior Castle end-to-end: Teresa herself, the overview, "
                    . 'then the seven mansions in order.',
                'action_label' => 'Enter the castle',
                'order' => 9,
                'courses' => ['H2', 'A2', 'J1', 'J2', 'J3', 'J4', 'J5', 'J6', 'J7'],
            ],
            [
                'id' => 'complete-journey',
                'heading' => 'I want to walk the entire library',
                'blurb' => 'Every course in code order, A1 through J7. Pace yourself — formation is a '
                    . 'years-long arc; the catalog is just the input.',
                'action_label' => 'Walk it all',
                'order' => 10,
                'courses' => [
                    'A1', 'A2', 'A3', 'A4', 'A5', 'A6', 'A7', 'A8',
                    'B1', 'B2', 'B3', 'B4', 'B5', 'B6', 'B7',
                    'C1', 'C2', 'C3', 'C4', 'C5',
                    'D1', 'D2', 'D3', 'D4', 'D5', 'D6', 'D7', 'D8', 'D9',
                    'E1', 'E2', 'E3', 'E4', 'E5',
                    'F1', 'F2', 'F3', 'F4',
                    'G1', 'G2', 'G3', 'G4',
                    'H1', 'H2', 'H3', 'H4',
                    'I1', 'I2', 'I3',
                    'J1', 'J2', 'J3', 'J4', 'J5', 'J6', 'J7',
                ],
            ],
        ],
    ];
}
