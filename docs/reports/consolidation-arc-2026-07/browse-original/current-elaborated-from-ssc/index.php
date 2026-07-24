<?php
/**
 * Saint School — tabbed course front-door.
 *
 * A guest-viewable multi-front over the single Saint-School course catalog.
 * Tabs (locked order): Curated (default) → Ascent → Browse → [For-me future].
 *
 *   ?view=curated   "Where would you like to begin?" — intent tiles (data-driven).
 *   ?view=ascent    Rail-grouped cards (colour/label keyed off category idnumber).
 *   ?view=browse    Flat filterable list + N8 toggles (v3|v1, courses|+book-studies).
 *
 * No capabilities are required; every tab and toggle works for anonymous visitors
 * (toggles degrade to GET-params when the user is not logged in). See README.md
 * for the intent-tile data contract and how to make this the site home.
 *
 * URL: /local/browse/  (optionally /local/browse/?view=ascent etc.)
 *
 * @package    local_browse
 * @copyright  2026 Saint School
 * @license    https://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

require_once(__DIR__ . '/../../config.php');
require_once(__DIR__ . '/locallib.php');

$context = context_system::instance();

$views = explode(',', LOCAL_BROWSE_VIEWS);
$defaultview = get_config('local_browse', 'default_view');
if (!in_array($defaultview, $views, true)) {
    $defaultview = 'curated';
}
$view = optional_param('view', $defaultview, PARAM_ALPHA);
if (!in_array($view, $views, true)) {
    $view = $defaultview;
}

$PAGE->set_url(new moodle_url('/local/browse/', ['view' => $view]));
$PAGE->set_context($context);
$PAGE->set_pagelayout('standard');
$PAGE->set_title(get_string('title', 'local_browse'));
$PAGE->set_heading(get_string('title', 'local_browse'));

global $DB, $OUTPUT;

echo $OUTPUT->header();
?>
<div class="ss-browse-page" style="max-width:1100px;margin:20px auto;padding:0 16px;">

    <div style="background:linear-gradient(135deg,#2E7D32 0%,#1B5E20 100%);color:#fff;padding:24px 28px;border-radius:10px;margin-bottom:16px;box-shadow:0 4px 12px rgba(46,125,50,.18);">
        <h1 style="color:#fff;font-size:1.8em;margin:0 0 6px;"><?php echo s(get_string('title', 'local_browse')); ?></h1>
        <p style="color:#c8e6c9;margin:0;font-size:1.05em;"><?php echo s(get_string('tagline', 'local_browse')); ?></p>
    </div>

    <?php // ── Tab bar (guest-safe links; no capability checks). ──────────────── ?>
    <div role="tablist" style="display:flex;gap:6px;border-bottom:2px solid #e0e0e0;margin-bottom:24px;flex-wrap:wrap;">
        <?php foreach ($views as $v):
            $tabURL = new moodle_url('/local/browse/', ['view' => $v]);
            $active = ($v === $view);
            $tabcolor = $active ? '#2E7D32' : '#666';
            $tabborder = $active ? '3px solid #2E7D32' : '3px solid transparent';
            $tabbg = $active ? '#f1f8f1' : 'transparent';
        ?>
            <a role="tab" href="<?php echo $tabURL; ?>"
               aria-selected="<?php echo $active ? 'true' : 'false'; ?>"
               style="padding:10px 18px;text-decoration:none;font-weight:600;color:<?php echo $tabcolor; ?>;border-bottom:<?php echo $tabborder; ?>;background:<?php echo $tabbg; ?>;border-radius:6px 6px 0 0;">
                <?php echo s(get_string('tab_' . $v, 'local_browse')); ?>
            </a>
        <?php endforeach; ?>
    </div>

    <?php
    switch ($view) {
        case 'ascent':
            local_browse_render_ascent($context);
            break;
        case 'browse':
            local_browse_render_browse($context);
            break;
        case 'curated':
        default:
            local_browse_render_curated($context);
            break;
    }
    ?>
</div>
<?php
echo $OUTPUT->footer();


// ─────────────────────────────────────────────────────────────────────────────
//  Renderers (kept in-file to match the existing plugin's inline-render style).
// ─────────────────────────────────────────────────────────────────────────────

/**
 * A single course card (links to /course/view.php?id=X).
 *
 * @param stdClass $course
 * @param context  $context
 * @param string   $color left-border / accent colour
 */
function local_browse_course_card($course, $context, string $color = '#2E7D32'): void {
    $viewurl = new moodle_url('/course/view.php', ['id' => $course->id]);
    $summary = local_browse_short_summary($course, $context);
    ?>
    <a href="<?php echo $viewurl; ?>"
       class="local-browse-course-card"
       style="display:block;background:#fff;border:1px solid #e0e0e0;border-left:4px solid <?php echo $color; ?>;border-radius:6px;padding:14px 18px;text-decoration:none;color:#222;transition:all .15s;box-shadow:0 1px 2px rgba(0,0,0,.04);"
       onmouseover="this.style.transform='translateX(2px)';this.style.boxShadow='0 4px 10px rgba(0,0,0,.08)';"
       onmouseout="this.style.transform='';this.style.boxShadow='0 1px 2px rgba(0,0,0,.04)';">
        <strong style="color:<?php echo $color; ?>;font-family:ui-monospace,monospace;font-size:0.85em;letter-spacing:.04em;"><?php echo s($course->shortname); ?></strong>
        <div style="font-weight:500;color:#222;line-height:1.3;margin:6px 0;font-size:1em;"><?php echo s($course->fullname); ?></div>
        <?php if ($summary): ?>
            <div style="color:#666;font-size:0.88em;line-height:1.45;"><?php echo s($summary); ?></div>
        <?php endif; ?>
    </a>
    <?php
}

/**
 * TAB 1 — Curated ("Where would you like to begin?"): intent tiles.
 *
 * @param context $context
 */
function local_browse_render_curated($context): void {
    $data = local_browse_get_intent_tiles();
    $tiles = $data['tiles'];

    if (empty($tiles)) {
        echo html_writer::tag('p', s(get_string('empty', 'local_browse')),
            ['style' => 'text-align:center;color:#888;padding:40px 0;']);
        return;
    }
    ?>
    <p style="color:#555;font-size:1.05em;margin:0 0 20px;"><?php echo s(get_string('curated_intro', 'local_browse')); ?></p>
    <?php foreach ($tiles as $tile):
        $courses = local_browse_courses_by_shortname($tile['courses']);
        if (empty($courses)) {
            continue; // Nothing resolves in this Moodle — skip the tile.
        }
    ?>
        <div style="margin-bottom:28px;border:1px solid #e0e0e0;border-radius:10px;padding:18px 20px;background:#fafafa;">
            <h2 style="color:#1B5E20;font-size:1.3em;margin:0 0 6px;"><?php echo s($tile['heading']); ?></h2>
            <?php if ($tile['blurb'] !== ''): ?>
                <p style="color:#555;margin:0 0 14px;font-size:0.98em;line-height:1.5;"><?php echo s($tile['blurb']); ?></p>
            <?php endif; ?>
            <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px;">
                <?php foreach ($courses as $course) {
                    local_browse_course_card($course, $context, '#2E7D32');
                } ?>
            </div>
        </div>
    <?php endforeach; ?>
    <?php
}

/**
 * TAB 2 — Ascent: courses grouped by Paradigm rail, colour keyed off idnumber.
 *
 * @param context $context
 */
function local_browse_render_ascent($context): void {
    global $DB;

    $categories = $DB->get_records_sql("
        SELECT *
          FROM {course_categories}
         WHERE visible = 1 AND id <> 1
         ORDER BY sortorder ASC
    ");

    $total = 0;
    ?>
    <p style="color:#555;font-size:1.05em;margin:0 0 20px;"><?php echo s(get_string('ascent_intro', 'local_browse')); ?></p>
    <?php foreach ($categories as $cat):
        $courses = $DB->get_records_sql("
            SELECT c.id, c.shortname, c.fullname, c.summary, c.summaryformat
              FROM {course} c
             WHERE c.category = :cid AND c.visible = 1 AND c.id <> :siteid
             ORDER BY c.shortname ASC
        ", ['cid' => $cat->id, 'siteid' => SITEID]);
        if (empty($courses)) {
            continue;
        }
        $total += count($courses);
        $style = local_browse_rail_style($cat);
        $color = $style['color'];
        $count = count($courses);
        $countstr = ($count === 1)
            ? get_string('count_course_in_rail', 'local_browse', $count)
            : get_string('count_courses_in_rail', 'local_browse', $count);
    ?>
        <div style="margin-bottom:32px;">
            <h2 style="color:<?php echo $color; ?>;font-size:1.35em;border-bottom:3px solid <?php echo $color; ?>;padding-bottom:8px;margin-bottom:16px;display:flex;justify-content:space-between;align-items:baseline;">
                <span><?php echo s($style['label']); ?></span>
                <span style="font-size:0.7em;color:#888;font-weight:400;"><?php echo s($countstr); ?></span>
            </h2>
            <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:14px;">
                <?php foreach ($courses as $course) {
                    local_browse_course_card($course, $context, $color);
                } ?>
            </div>
        </div>
    <?php endforeach; ?>

    <?php if ($total === 0): ?>
        <p style="text-align:center;color:#888;padding:40px 0;"><?php echo s(get_string('empty', 'local_browse')); ?></p>
    <?php endif; ?>
    <?php
}

/**
 * TAB 3 — Browse: flat list + N8 toggles (catalog version, content scope).
 *
 * @param context $context
 */
function local_browse_render_browse($context): void {
    global $DB;

    // ── N8 toggles (persist for logged-in users; GET-param for anonymous). ──
    $cat = local_browse_resolve_toggle('cat', 'v3', ['v3', 'v1']);
    $content = local_browse_resolve_toggle('content', 'courses', ['courses', 'books']);

    // Base params reflect the RESOLVED toggle state so each pill preserves the
    // other toggle (including a logged-in user's persisted preference).
    $baseparams = ['view' => 'browse', 'cat' => $cat, 'content' => $content];
    $togglepill = function(string $param, string $value, string $current, string $label) use ($baseparams) {
        $url = new moodle_url('/local/browse/', $baseparams);
        $url->param($param, $value);
        $active = ($value === $current);
        $bg = $active ? '#2E7D32' : '#fff';
        $fg = $active ? '#fff' : '#555';
        return html_writer::link($url, s($label), [
            'style' => "display:inline-block;padding:6px 14px;border:1px solid #2E7D32;border-radius:16px;"
                . "text-decoration:none;font-size:0.9em;margin:0 6px 6px 0;background:$bg;color:$fg;",
        ]);
    };
    ?>
    <p style="color:#555;font-size:1.05em;margin:0 0 12px;"><?php echo s(get_string('browse_intro', 'local_browse')); ?></p>

    <div style="display:flex;flex-wrap:wrap;gap:24px;margin-bottom:20px;padding:14px 16px;background:#f5f5f5;border-radius:8px;">
        <div>
            <div style="font-size:0.78em;text-transform:uppercase;letter-spacing:.05em;color:#888;margin-bottom:6px;"><?php echo s(get_string('toggle_catalog', 'local_browse')); ?></div>
            <?php
            echo $togglepill('cat', 'v3', $cat, get_string('toggle_v3', 'local_browse'));
            echo $togglepill('cat', 'v1', $cat, get_string('toggle_v1', 'local_browse'));
            ?>
        </div>
        <div>
            <div style="font-size:0.78em;text-transform:uppercase;letter-spacing:.05em;color:#888;margin-bottom:6px;"><?php echo s(get_string('toggle_content', 'local_browse')); ?></div>
            <?php
            echo $togglepill('content', 'courses', $content, get_string('toggle_courses', 'local_browse'));
            echo $togglepill('content', 'books', $content, get_string('toggle_books', 'local_browse'));
            ?>
        </div>
    </div>

    <?php
    if ($cat === 'v1') {
        local_browse_render_browse_v1();
    } else {
        local_browse_render_browse_v3($context, $content);
    }
}

/**
 * Browse: live v3 catalog, flat filterable list (optionally with book-studies).
 *
 * @param context $context
 * @param string  $content 'courses' | 'books'
 */
function local_browse_render_browse_v3($context, string $content): void {
    global $DB;

    $courses = $DB->get_records_sql("
        SELECT c.id, c.shortname, c.fullname, c.summary, c.summaryformat, c.category
          FROM {course} c
         WHERE c.visible = 1 AND c.id <> :siteid
         ORDER BY c.shortname ASC
    ", ['siteid' => SITEID]);

    if (empty($courses)) {
        echo html_writer::tag('p', s(get_string('empty', 'local_browse')),
            ['style' => 'text-align:center;color:#888;padding:40px 0;']);
        return;
    }

    // In-page client-side filter box (guest-safe, no server round-trip).
    ?>
    <input type="text" id="ss-browse-filter" placeholder="<?php echo s(get_string('filter_placeholder', 'local_browse')); ?>"
           oninput="(function(q){q=q.toLowerCase();document.querySelectorAll('.ss-browse-row').forEach(function(r){r.style.display=r.textContent.toLowerCase().indexOf(q)>-1?'':'none';});})(this.value)"
           style="width:100%;max-width:420px;padding:10px 14px;border:1px solid #ccc;border-radius:8px;margin-bottom:18px;font-size:1em;">

    <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:12px;">
        <?php foreach ($courses as $course): ?>
            <div class="ss-browse-row">
                <?php local_browse_course_card($course, $context, '#2E7D32'); ?>
            </div>
        <?php endforeach; ?>
    </div>

    <?php if ($content === 'books'): ?>
        <?php
        // N8 §C.2: book-studies are copyright-gated — a work must be status:cleared
        // before its book-study renders. None are cleared in the shipped stub, so this
        // is an explicit "nothing to show yet" notice rather than a silent no-op.
        ?>
        <div style="margin-top:24px;padding:16px 18px;background:#fff8e1;border:1px solid #ffe082;border-radius:8px;color:#795548;">
            <strong><?php echo s(get_string('books_heading', 'local_browse')); ?></strong>
            <p style="margin:6px 0 0;"><?php echo s(get_string('books_none_cleared', 'local_browse')); ?></p>
        </div>
    <?php endif;
}

/**
 * Browse: v1 archive (ss2) read-only deep-links from the seed manifest.
 */
function local_browse_render_browse_v1(): void {
    require_once(__DIR__ . '/db/v1manifest.php');
    $manifest = local_browse_v1_manifest();
    $base = trim((string)get_config('local_browse', 'v1_base_url'));
    $base = rtrim($base, '/');
    ?>
    <div style="margin-bottom:16px;padding:12px 16px;background:#eceff1;border-radius:8px;color:#455a64;font-size:0.92em;">
        <?php echo s(get_string('v1_notice', 'local_browse')); ?>
    </div>

    <?php if ($base === ''): ?>
        <div style="margin-bottom:16px;padding:12px 16px;background:#fff3e0;border:1px solid #ffcc80;border-radius:8px;color:#e65100;">
            <?php echo s(get_string('v1_base_unset', 'local_browse')); ?>
        </div>
    <?php endif; ?>

    <input type="text" id="ss-browse-filter-v1" placeholder="<?php echo s(get_string('filter_placeholder', 'local_browse')); ?>"
           oninput="(function(q){q=q.toLowerCase();document.querySelectorAll('.ss-browse-row-v1').forEach(function(r){r.style.display=r.textContent.toLowerCase().indexOf(q)>-1?'':'none';});})(this.value)"
           style="width:100%;max-width:420px;padding:10px 14px;border:1px solid #ccc;border-radius:8px;margin-bottom:18px;font-size:1em;">

    <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:12px;">
        <?php foreach ($manifest['courses'] as $c):
            $color = '#78909c';
            $hasurl = ($base !== '');
            $url = $hasurl ? ($base . $c['path']) : null;
            $tag = $hasurl ? 'a' : 'div';
            $attrs = 'style="display:block;background:#fff;border:1px solid #e0e0e0;border-left:4px solid ' . $color . ';border-radius:6px;padding:14px 18px;text-decoration:none;color:#222;"';
            if ($hasurl) {
                $attrs .= ' href="' . s($url) . '" target="_blank" rel="noopener"';
            }
        ?>
            <div class="ss-browse-row-v1">
                <<?php echo $tag; ?> <?php echo $attrs; ?>>
                    <strong style="color:<?php echo $color; ?>;font-family:ui-monospace,monospace;font-size:0.85em;letter-spacing:.04em;"><?php echo s($c['code']); ?></strong>
                    <div style="font-weight:500;color:#222;line-height:1.3;margin:6px 0;font-size:1em;"><?php echo s($c['title']); ?></div>
                    <?php if ($hasurl): ?>
                        <div style="color:#888;font-size:0.8em;"><?php echo s(get_string('v1_open_archive', 'local_browse')); ?></div>
                    <?php endif; ?>
                </<?php echo $tag; ?>>
            </div>
        <?php endforeach; ?>
    </div>
    <?php
}
