<?php
/**
 * Internal helpers for local_browse (tabbed multi-front over the catalog).
 *
 * @package    local_browse
 * @copyright  2026 Saint School
 * @license    https://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

defined('MOODLE_INTERNAL') || die();

/** Valid tab/view identifiers, in locked order (Curated → Ascent → Browse). */
define('LOCAL_BROWSE_VIEWS', 'curated,ascent,browse');

/**
 * Rail colour + label keyed off a STABLE category idnumber, not the display name.
 *
 * The historical fragility was colour-by-exact-category-NAME. We now key first on
 * a stable idnumber (rail_sacraments / rail_prayer / rail_ascesis / rail_your_yes),
 * fall back to the legacy name map, and finally to a neutral default — so the view
 * degrades gracefully whether or not the operator has stamped the idnumbers on the
 * live categories yet.
 *
 * @param stdClass $category a course_categories record (needs ->idnumber and ->name)
 * @return array ['color' => hex, 'label' => string]
 */
function local_browse_rail_style($category): array {
    // Preferred: stable idnumber.
    $byidnumber = [
        'rail_sacraments' => ['color' => '#5D4037', 'label' => 'Sacraments'],
        'rail_prayer'     => ['color' => '#1565C0', 'label' => 'Prayer & Recollection'],
        'rail_ascesis'    => ['color' => '#7B1FA2', 'label' => 'Ascesis'],
        'rail_your_yes'   => ['color' => '#2E7D32', 'label' => '"Your Yes"'],
    ];
    $idnumber = trim((string)($category->idnumber ?? ''));
    if ($idnumber !== '' && isset($byidnumber[$idnumber])) {
        return $byidnumber[$idnumber];
    }

    // Fallback: legacy exact-name map (kept until idnumbers are stamped live).
    $byname = [
        'Sacraments rail'            => '#5D4037',
        'Prayer & Recollection rail' => '#1565C0',
        'Ascesis rail'               => '#7B1FA2',
        '"Your Yes" rail'            => '#2E7D32',
        'Your Yes rail'              => '#2E7D32',
    ];
    $name = (string)($category->name ?? '');
    if (isset($byname[$name])) {
        return ['color' => $byname[$name], 'label' => $name];
    }

    // Final fallback: neutral.
    return ['color' => '#607D8B', 'label' => ($name !== '' ? $name : get_string('rail_unknown', 'local_browse'))];
}

/**
 * Load the intent-tile data contract: admin setting if present + valid, else seed.
 *
 * @return array normalised {version:int, tiles:[{id,heading,blurb,action_label,order,courses}]}
 */
function local_browse_get_intent_tiles(): array {
    require_once(__DIR__ . '/db/intent_tiles.php');

    $raw = trim((string)get_config('local_browse', 'intent_tiles_json'));
    if ($raw !== '') {
        $decoded = json_decode($raw, true);
        if (is_array($decoded) && !empty($decoded['tiles']) && is_array($decoded['tiles'])) {
            return local_browse_normalise_intent_tiles($decoded);
        }
        // Invalid JSON in the setting — fall through to the shipped seed.
        debugging('local_browse: intent_tiles_json is set but not valid; using shipped seed.', DEBUG_DEVELOPER);
    }
    return local_browse_normalise_intent_tiles(local_browse_intent_tiles_seed());
}

/**
 * Normalise + order a raw intent-tile structure defensively (data may be authored
 * externally by the Theology Editor / def-sync).
 *
 * @param array $data
 * @return array
 */
function local_browse_normalise_intent_tiles(array $data): array {
    $tiles = [];
    foreach (($data['tiles'] ?? []) as $t) {
        if (empty($t['id']) || empty($t['heading'])) {
            continue;
        }
        $courses = [];
        foreach (($t['courses'] ?? []) as $code) {
            $code = trim((string)$code);
            if ($code !== '') {
                $courses[] = $code;
            }
        }
        $tiles[] = [
            'id' => (string)$t['id'],
            'heading' => (string)$t['heading'],
            'blurb' => (string)($t['blurb'] ?? ''),
            'action_label' => (string)($t['action_label'] ?? get_string('tile_default_action', 'local_browse')),
            'order' => (int)($t['order'] ?? 0),
            'courses' => $courses,
        ];
    }
    usort($tiles, function($a, $b) {
        return $a['order'] <=> $b['order'];
    });
    return ['version' => (int)($data['version'] ?? 1), 'tiles' => $tiles];
}

/**
 * Fetch visible course records for a list of shortcodes, preserving the given
 * order and silently dropping codes that do not resolve to a visible course.
 *
 * @param string[] $codes course shortnames in desired order
 * @return stdClass[] course records in the same order (subset of $codes)
 */
function local_browse_courses_by_shortname(array $codes): array {
    global $DB;
    if (empty($codes)) {
        return [];
    }
    list($insql, $params) = $DB->get_in_or_equal($codes, SQL_PARAMS_NAMED);
    $params['siteid'] = SITEID;
    $records = $DB->get_records_sql("
        SELECT c.id, c.shortname, c.fullname, c.summary, c.summaryformat
          FROM {course} c
         WHERE c.shortname $insql AND c.visible = 1 AND c.id <> :siteid
    ", $params);

    // Re-key by shortname, then re-emit in the requested order.
    $byshort = [];
    foreach ($records as $r) {
        $byshort[$r->shortname] = $r;
    }
    $ordered = [];
    foreach ($codes as $code) {
        if (isset($byshort[$code])) {
            $ordered[] = $byshort[$code];
        }
    }
    return $ordered;
}

/**
 * Resolve a Browse-tab toggle value. Precedence:
 *   1. an explicit, allowed GET param (and persist it as a user pref if logged in);
 *   2. the stored user preference (logged-in, non-guest users only);
 *   3. the supplied default.
 * Anonymous/guest users get GET-param + default only (no persistence) — guest-safe.
 *
 * @param string   $param   GET param name (also the user-preference key sans prefix)
 * @param string   $default default value
 * @param string[] $allowed allowed values
 * @return string
 */
function local_browse_resolve_toggle(string $param, string $default, array $allowed): string {
    $persist = isloggedin() && !isguestuser();
    $prefkey = 'local_browse_' . $param;

    $get = optional_param($param, null, PARAM_ALPHANUMEXT);
    if ($get !== null && in_array($get, $allowed, true)) {
        if ($persist) {
            set_user_preference($prefkey, $get);
        }
        return $get;
    }

    if ($persist) {
        $pref = get_user_preferences($prefkey, null);
        if ($pref !== null && in_array($pref, $allowed, true)) {
            return $pref;
        }
    }

    return $default;
}

/**
 * Short, tag-stripped course summary for a card.
 *
 * @param stdClass $course
 * @param context  $context
 * @param int      $width
 * @return string
 */
function local_browse_short_summary($course, $context, int $width = 140): string {
    $summary = format_text($course->summary ?? '', $course->summaryformat ?? FORMAT_HTML, ['context' => $context]);
    $summary = trim(strip_tags($summary));
    if ($summary === '') {
        return '';
    }
    return mb_strimwidth($summary, 0, $width, '…');
}
