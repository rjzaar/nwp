<?php
// This file is part of the NWP avatar system for Moodle (ss counterpart to
// the Drupal nwp_avatars / mayo_avatars module). GPL v3 or later.

namespace local_nwp_avatars;

defined('MOODLE_INTERNAL') || die();

/**
 * Manages the NWP patron-saint avatar library on Moodle: patron saints,
 * virtues, nature, and abstract symbols with colour personalisation. All
 * avatars are inline SVG — no photo uploads permitted.
 *
 * FAITHFUL PORT of the Drupal source of truth:
 *   sites/mayo/dev/html/modules/custom/mayo_avatars/src/AvatarManager.php
 * The getColours()/getAvatars()/render()/buildSymbolMap() output MUST stay
 * byte-consistent with the Drupal module. See README-nwp-avatars.md for the
 * shared-asset drift strategy (future signed nwp-avatars-assets bundle).
 *
 * Namespaced/static so it can be used both inside Moodle and by the
 * standalone render-match test (tests/render_match_test.php) without a DB.
 */
class avatar_manager {

    /**
     * Available colour palettes. Keyed by colour id.
     *
     * @return array<string, array{bg:string, label:string}>
     */
    public function get_colours(): array {
        return [
            'royal-blue'    => ['bg' => '#4A6FA5', 'label' => 'Royal Blue'],
            'forest-green'  => ['bg' => '#2E7D32', 'label' => 'Forest Green'],
            'ruby'          => ['bg' => '#C62828', 'label' => 'Ruby'],
            'golden'        => ['bg' => '#E6A817', 'label' => 'Golden'],
            'purple'        => ['bg' => '#6A1B9A', 'label' => 'Purple'],
            'teal'          => ['bg' => '#00897B', 'label' => 'Teal'],
            'rose'          => ['bg' => '#AD1457', 'label' => 'Rose'],
            'slate'         => ['bg' => '#546E7A', 'label' => 'Slate'],
            'burgundy'      => ['bg' => '#880E4F', 'label' => 'Burgundy'],
            'bronze'        => ['bg' => '#8D6E63', 'label' => 'Bronze'],
        ];
    }

    /**
     * Avatar definitions grouped by category. Keyed by avatar (saint) id.
     *
     * @return array<string, array{name:string, patron:string, feast:string, cat:string}>
     */
    public function get_avatars(): array {
        static $avatars = null;
        if ($avatars !== null) {
            return $avatars;
        }

        $avatars = [
            // --- Patron Saints (43) ---
            'francis'          => ['name' => 'St Francis of Assisi',    'patron' => 'Animals, ecology, peace',            'feast' => '4 Oct',  'cat' => 'saints'],
            'cecilia'          => ['name' => 'St Cecilia',              'patron' => 'Musicians, singers',                 'feast' => '22 Nov', 'cat' => 'saints'],
            'joan'             => ['name' => 'St Joan of Arc',          'patron' => 'Soldiers, France',                   'feast' => '30 May', 'cat' => 'saints'],
            'therese'          => ['name' => 'St Thérèse of Lisieux',   'patron' => 'Missions, florists',                 'feast' => '1 Oct',  'cat' => 'saints'],
            'patrick'          => ['name' => 'St Patrick',              'patron' => 'Ireland, engineers',                 'feast' => '17 Mar', 'cat' => 'saints'],
            'brigid'           => ['name' => 'St Brigid of Kildare',    'patron' => 'Ireland, scholars',                  'feast' => '1 Feb',  'cat' => 'saints'],
            'joseph'           => ['name' => 'St Joseph',               'patron' => 'Workers, fathers, the Church',       'feast' => '19 Mar', 'cat' => 'saints'],
            'michael'          => ['name' => 'St Michael the Archangel', 'patron' => 'Protector, police, military',        'feast' => '29 Sep', 'cat' => 'saints'],
            'anthony'          => ['name' => 'St Anthony of Padua',     'patron' => 'Lost things, the poor',              'feast' => '13 Jun', 'cat' => 'saints'],
            'clare'            => ['name' => 'St Clare of Assisi',      'patron' => 'Television, eye disease',            'feast' => '11 Aug', 'cat' => 'saints'],
            'benedict'         => ['name' => 'St Benedict',             'patron' => 'Europe, students, monks',            'feast' => '11 Jul', 'cat' => 'saints'],
            'teresa-avila'     => ['name' => 'St Teresa of Ávila',      'patron' => 'Headache sufferers, writers',        'feast' => '15 Oct', 'cat' => 'saints'],
            'ignatius'         => ['name' => 'St Ignatius of Loyola',   'patron' => 'Jesuits, soldiers, education',       'feast' => '31 Jul', 'cat' => 'saints'],
            'aquinas'          => ['name' => 'St Thomas Aquinas',       'patron' => 'Students, academics',                'feast' => '28 Jan', 'cat' => 'saints'],
            'augustine'        => ['name' => 'St Augustine',            'patron' => 'Theologians, printers',              'feast' => '28 Aug', 'cat' => 'saints'],
            'catherine-siena'  => ['name' => 'St Catherine of Siena',   'patron' => 'Italy, nurses, firefighters',        'feast' => '29 Apr', 'cat' => 'saints'],
            'dominic'          => ['name' => 'St Dominic',              'patron' => 'Astronomers, the Rosary',            'feast' => '8 Aug',  'cat' => 'saints'],
            'kolbe'            => ['name' => 'St Maximilian Kolbe',     'patron' => 'Journalists, prisoners',             'feast' => '14 Aug', 'cat' => 'saints'],
            'pio'              => ['name' => 'St Padre Pio',            'patron' => 'Prayer groups, healing',             'feast' => '23 Sep', 'cat' => 'saints'],
            'jpii'             => ['name' => 'St John Paul II',         'patron' => 'World Youth Day, families',          'feast' => '22 Oct', 'cat' => 'saints'],
            'teresa-calcutta'  => ['name' => 'St Mother Teresa',        'patron' => 'Missionaries of Charity',            'feast' => '5 Sep',  'cat' => 'saints'],
            'seton'            => ['name' => 'St Elizabeth Ann Seton',  'patron' => 'Catholic schools, widows',           'feast' => '4 Jan',  'cat' => 'saints'],
            'kateri'           => ['name' => 'St Kateri Tekakwitha',    'patron' => 'Ecology, Indigenous peoples',        'feast' => '14 Jul', 'cat' => 'saints'],
            'martin'           => ['name' => 'St Martin de Porres',     'patron' => 'Mixed-race people, barbers, animals', 'feast' => '3 Nov',  'cat' => 'saints'],
            'rose-lima'        => ['name' => 'St Rose of Lima',         'patron' => 'Latin America, gardeners',           'feast' => '23 Aug', 'cat' => 'saints'],
            'juan-diego'       => ['name' => 'St Juan Diego',           'patron' => 'Indigenous peoples of Americas',     'feast' => '9 Dec',  'cat' => 'saints'],
            'bernadette'       => ['name' => 'St Bernadette',           'patron' => 'Illness, Lourdes',                   'feast' => '16 Apr', 'cat' => 'saints'],
            'sebastian'        => ['name' => 'St Sebastian',            'patron' => 'Athletes, soldiers',                 'feast' => '20 Jan', 'cat' => 'saints'],
            'christopher'      => ['name' => 'St Christopher',          'patron' => 'Travellers, drivers',                'feast' => '25 Jul', 'cat' => 'saints'],
            'luke'             => ['name' => 'St Luke',                 'patron' => 'Physicians, artists',                'feast' => '18 Oct', 'cat' => 'saints'],
            'mark'             => ['name' => 'St Mark',                 'patron' => 'Venice, notaries',                   'feast' => '25 Apr', 'cat' => 'saints'],
            'matthew'          => ['name' => 'St Matthew',              'patron' => 'Accountants, tax collectors',        'feast' => '21 Sep', 'cat' => 'saints'],
            'john-evangelist'  => ['name' => 'St John the Evangelist',  'patron' => 'Authors, publishers',                'feast' => '27 Dec', 'cat' => 'saints'],
            'peter'            => ['name' => 'St Peter',                'patron' => 'Fishermen, the papacy',              'feast' => '29 Jun', 'cat' => 'saints'],
            'paul'             => ['name' => 'St Paul',                 'patron' => 'Missionaries, writers',              'feast' => '29 Jun', 'cat' => 'saints'],
            'andrew'           => ['name' => 'St Andrew',               'patron' => 'Scotland, fishermen',                'feast' => '30 Nov', 'cat' => 'saints'],
            'bakhita'          => ['name' => 'St Josephine Bakhita',    'patron' => 'Human trafficking survivors',        'feast' => '8 Feb',  'cat' => 'saints'],
            'gianna'           => ['name' => 'St Gianna Beretta Molla', 'patron' => 'Mothers, physicians',                'feast' => '28 Apr', 'cat' => 'saints'],
            'philip-neri'      => ['name' => 'St Philip Neri',          'patron' => 'Joy, humour, Rome',                  'feast' => '26 May', 'cat' => 'saints'],
            'agnes'            => ['name' => 'St Agnes',                'patron' => 'Young girls, chastity',              'feast' => '21 Jan', 'cat' => 'saints'],
            'lucy'             => ['name' => 'St Lucy',                 'patron' => 'Eyesight, the blind',                'feast' => '13 Dec', 'cat' => 'saints'],
            'scholastica'      => ['name' => 'St Scholastica',          'patron' => 'Nuns, convulsive children',          'feast' => '10 Feb', 'cat' => 'saints'],
            'thomas-more'      => ['name' => 'St Thomas More',          'patron' => 'Lawyers, politicians',               'feast' => '22 Jun', 'cat' => 'saints'],

            // --- Virtues (8) ---
            'faith'            => ['name' => 'Faith',    'patron' => 'Cross and flame',    'feast' => '', 'cat' => 'virtues'],
            'hope'             => ['name' => 'Hope',     'patron' => 'Anchor of the soul', 'feast' => '', 'cat' => 'virtues'],
            'charity'          => ['name' => 'Charity',  'patron' => 'Heart and hands',    'feast' => '', 'cat' => 'virtues'],
            'courage'          => ['name' => 'Courage',  'patron' => 'Lion rampant',       'feast' => '', 'cat' => 'virtues'],
            'wisdom'           => ['name' => 'Wisdom',   'patron' => 'Owl',                'feast' => '', 'cat' => 'virtues'],
            'patience'         => ['name' => 'Patience', 'patron' => 'Hourglass',          'feast' => '', 'cat' => 'virtues'],
            'humility'         => ['name' => 'Humility', 'patron' => 'Basin and water',    'feast' => '', 'cat' => 'virtues'],
            'joy'              => ['name' => 'Joy',      'patron' => 'Radiant sun',        'feast' => '', 'cat' => 'virtues'],

            // --- Nature / Creation (10) ---
            'mountain'         => ['name' => 'Mountain',  'patron' => 'Steadfastness',       'feast' => '', 'cat' => 'nature'],
            'river'            => ['name' => 'River',     'patron' => 'Living water',        'feast' => '', 'cat' => 'nature'],
            'oak'              => ['name' => 'Oak Tree',  'patron' => 'Strength, endurance', 'feast' => '', 'cat' => 'nature'],
            'eagle-soaring'    => ['name' => 'Eagle',     'patron' => 'Renewal, strength',   'feast' => '', 'cat' => 'nature'],
            'star'             => ['name' => 'Star',      'patron' => 'Guidance, light',     'feast' => '', 'cat' => 'nature'],
            'sunrise'          => ['name' => 'Sunrise',   'patron' => 'New beginnings',      'feast' => '', 'cat' => 'nature'],
            'lamb'             => ['name' => 'Lamb',      'patron' => 'Innocence, peace',    'feast' => '', 'cat' => 'nature'],
            'dove'             => ['name' => 'Dove',      'patron' => 'Holy Spirit, peace',  'feast' => '', 'cat' => 'nature'],
            'fish'             => ['name' => 'Ichthys',   'patron' => 'Early Christians',    'feast' => '', 'cat' => 'nature'],
            'wheat'            => ['name' => 'Wheat',     'patron' => 'Eucharist, harvest',  'feast' => '', 'cat' => 'nature'],

            // --- Abstract / Symbols (6) ---
            'celtic-cross'     => ['name' => 'Celtic Cross',    'patron' => 'Faith and heritage', 'feast' => '', 'cat' => 'abstract'],
            'shield-cross'     => ['name' => 'Shield of Faith', 'patron' => 'Spiritual armour',   'feast' => '', 'cat' => 'abstract'],
            'celtic-knot'      => ['name' => 'Trinity Knot',    'patron' => 'Holy Trinity',       'feast' => '', 'cat' => 'abstract'],
            'rose-window'      => ['name' => 'Rose Window',     'patron' => 'Sacred geometry',    'feast' => '', 'cat' => 'abstract'],
            'chi-rho'          => ['name' => 'Chi-Rho',         'patron' => 'Christ monogram',    'feast' => '', 'cat' => 'abstract'],
            'alpha-omega'      => ['name' => 'Alpha & Omega',   'patron' => 'Beginning and end',  'feast' => '', 'cat' => 'abstract'],
        ];

        return $avatars;
    }

    /**
     * Avatars grouped by category for display.
     *
     * @return array<string, array{label:string, items:array}>
     */
    public function get_avatars_by_category(): array {
        $categories = [
            'saints'   => ['label' => 'Patron Saints', 'items' => []],
            'virtues'  => ['label' => 'Virtues',        'items' => []],
            'nature'   => ['label' => 'Creation',        'items' => []],
            'abstract' => ['label' => 'Symbols',         'items' => []],
        ];
        foreach ($this->get_avatars() as $id => $avatar) {
            $categories[$avatar['cat']]['items'][$id] = $avatar;
        }
        return $categories;
    }

    /**
     * Render a complete avatar SVG.
     *
     * Byte-for-byte identical output to the Drupal AvatarManager::render()
     * for the same ($avatarid, $colourid, $size). Keep it that way — the
     * render-match test asserts this.
     */
    public function render(string $avatarid, string $colourid, int $size = 120): string {
        $colours = $this->get_colours();
        $avatars = $this->get_avatars();
        $bg = $colours[$colourid]['bg'] ?? '#546E7A';
        $label = $avatars[$avatarid]['name'] ?? 'Avatar';
        $symbol = $this->get_symbol_svg($avatarid);

        return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120" '
            . 'width="' . $size . '" height="' . $size . '" '
            . 'role="img" aria-label="' . htmlspecialchars($label, ENT_QUOTES) . '">'
            . '<circle cx="60" cy="60" r="58" fill="' . $bg . '" class="avatar-bg"/>'
            . $symbol
            . '</svg>';
    }

    /**
     * Return the white SVG symbol elements for a given avatar id.
     */
    public function get_symbol_svg(string $id): string {
        static $symbols = null;
        if ($symbols === null) {
            $symbols = $this->build_symbol_map();
        }
        return $symbols[$id] ?? '';
    }

    /**
     * All 67 avatar symbols as inline SVG fragments (white on transparent).
     *
     * Design rules (mirrored from the Drupal source):
     *   - viewBox 0 0 120 120; symbol area ≈ 30,28 → 90,92
     *   - white (#fff) fills and strokes only
     *   - stroke-linecap="round" everywhere
     *   - ≤ 8 elements per symbol for rendering speed at scale
     */
    private function build_symbol_map(): array {
        // Shorthand stroke group openers.
        $s = '<g fill="none" stroke="#fff" stroke-linecap="round"';
        $f = '<g fill="#fff"';

        return [

            // =====================================================================
            //  PATRON SAINTS (43)
            // =====================================================================

            // Bird in flight — two curved V-lines.
            'francis' =>
                "$s stroke-width=\"3.5\">"
                . '<path d="M30,58 Q45,36 60,50 Q75,36 90,58"/>'
                . '<path d="M38,72 Q49,56 60,64 Q71,56 82,72"/>'
                . '</g>',

            // Harp — curved frame + three strings.
            'cecilia' =>
                "$s stroke-width=\"3\">"
                . '<path d="M48,32 Q38,60 48,88"/>'
                . '<path d="M48,32 Q78,42 78,60 Q78,78 48,88"/>'
                . '<line x1="55" y1="40" x2="55" y2="80"/>'
                . '<line x1="62" y1="44" x2="62" y2="76"/>'
                . '<line x1="69" y1="50" x2="69" y2="70"/>'
                . '</g>',

            // Upright sword.
            'joan' =>
                "$s stroke-width=\"5\">"
                . '<line x1="60" y1="26" x2="60" y2="90"/>'
                . '<line x1="42" y1="56" x2="78" y2="56"/>'
                . '</g>'
                . '<circle cx="60" cy="90" r="4" fill="#fff"/>',

            // Five-petal rose + stem.
            'therese' =>
                '<circle cx="60" cy="54" r="6" fill="#fff"/>'
                . '<circle cx="60" cy="40" r="9" fill="none" stroke="#fff" stroke-width="2.5"/>'
                . '<circle cx="73" cy="50" r="9" fill="none" stroke="#fff" stroke-width="2.5"/>'
                . '<circle cx="68" cy="65" r="9" fill="none" stroke="#fff" stroke-width="2.5"/>'
                . '<circle cx="52" cy="65" r="9" fill="none" stroke="#fff" stroke-width="2.5"/>'
                . '<circle cx="47" cy="50" r="9" fill="none" stroke="#fff" stroke-width="2.5"/>'
                . "<line x1=\"60\" y1=\"72\" x2=\"60\" y2=\"92\" stroke=\"#fff\" stroke-width=\"3\" stroke-linecap=\"round\"/>",

            // Shamrock — three round leaves + stem.
            'patrick' =>
                '<circle cx="60" cy="38" r="11" fill="#fff"/>'
                . '<circle cx="48" cy="54" r="11" fill="#fff"/>'
                . '<circle cx="72" cy="54" r="11" fill="#fff"/>'
                . "<line x1=\"60\" y1=\"58\" x2=\"60\" y2=\"90\" stroke=\"#fff\" stroke-width=\"3.5\" stroke-linecap=\"round\"/>",

            // Brigid's cross — woven arms + diamond centre.
            'brigid' =>
                "$s stroke-width=\"6\">"
                . '<line x1="60" y1="28" x2="60" y2="92"/>'
                . '<line x1="28" y1="60" x2="92" y2="60"/>'
                . '</g>'
                . '<rect x="48" y="48" width="24" height="24" rx="2" fill="none" stroke="#fff" stroke-width="3" transform="rotate(45 60 60)"/>',

            // Lily — three petal ellipses + stem.
            'joseph' =>
                '<ellipse cx="50" cy="42" rx="7" ry="16" fill="#fff" transform="rotate(-12 50 42)"/>'
                . '<ellipse cx="60" cy="38" rx="7" ry="18" fill="#fff"/>'
                . '<ellipse cx="70" cy="42" rx="7" ry="16" fill="#fff" transform="rotate(12 70 42)"/>'
                . "<line x1=\"60\" y1=\"55\" x2=\"60\" y2=\"92\" stroke=\"#fff\" stroke-width=\"3\" stroke-linecap=\"round\"/>",

            // Winged sword — sword + wing arcs.
            'michael' =>
                "$s stroke-width=\"4\">"
                . '<line x1="60" y1="24" x2="60" y2="92"/>'
                . '<line x1="40" y1="50" x2="80" y2="50"/>'
                . '<path d="M44,50 Q32,38 38,26"/>'
                . '<path d="M76,50 Q88,38 82,26"/>'
                . '</g>',

            // Open book with small cross.
            'anthony' =>
                "$s stroke-width=\"3\">"
                . '<path d="M34,38 Q60,48 60,88"/>'
                . '<path d="M86,38 Q60,48 60,88"/>'
                . '<line x1="34" y1="38" x2="86" y2="38"/>'
                . '</g>'
                . '<line x1="60" y1="26" x2="60" y2="36" stroke="#fff" stroke-width="2.5" stroke-linecap="round"/>'
                . '<line x1="55" y1="30" x2="65" y2="30" stroke="#fff" stroke-width="2.5" stroke-linecap="round"/>',

            // Monstrance — circle + radiating lines.
            'clare' =>
                '<circle cx="60" cy="52" r="12" fill="none" stroke="#fff" stroke-width="3"/>'
                . '<circle cx="60" cy="52" r="5" fill="#fff"/>'
                . "$s stroke-width=\"3\">"
                . '<line x1="60" y1="32" x2="60" y2="26"/><line x1="60" y1="72" x2="60" y2="78"/>'
                . '<line x1="40" y1="52" x2="34" y2="52"/><line x1="80" y1="52" x2="86" y2="52"/>'
                . '<line x1="46" y1="38" x2="42" y2="34"/><line x1="74" y1="38" x2="78" y2="34"/>'
                . '<line x1="46" y1="66" x2="42" y2="70"/><line x1="74" y1="66" x2="78" y2="70"/>'
                . '</g>'
                . "<line x1=\"60\" y1=\"78\" x2=\"60\" y2=\"92\" stroke=\"#fff\" stroke-width=\"3\" stroke-linecap=\"round\"/>",

            // Chalice with cross.
            'benedict' =>
                "$f>"
                . '<path d="M42,42 Q42,68 60,72 Q78,68 78,42 Z"/>'
                . '<rect x="56" y="72" width="8" height="10" rx="1"/>'
                . '<rect x="48" y="82" width="24" height="6" rx="2"/>'
                . '</g>'
                . '<line x1="60" y1="26" x2="60" y2="40" stroke="#fff" stroke-width="2.5" stroke-linecap="round"/>'
                . '<line x1="54" y1="32" x2="66" y2="32" stroke="#fff" stroke-width="2.5" stroke-linecap="round"/>',

            // Quill pen.
            'teresa-avila' =>
                "$s stroke-width=\"3\">"
                . '<path d="M42,88 L78,28"/>'
                . '<path d="M78,28 Q88,36 80,46"/>'
                . '<path d="M78,28 Q68,24 72,40"/>'
                . '</g>'
                . '<circle cx="40" cy="90" r="3" fill="#fff"/>',

            // IHS monogram in sunburst.
            'ignatius' =>
                '<circle cx="60" cy="56" r="22" fill="none" stroke="#fff" stroke-width="2.5"/>'
                . "$s stroke-width=\"3\">"
                . '<line x1="60" y1="28" x2="60" y2="24"/><line x1="60" y1="84" x2="60" y2="88"/>'
                . '<line x1="32" y1="56" x2="28" y2="56"/><line x1="88" y1="56" x2="92" y2="56"/>'
                . '<line x1="42" y1="38" x2="38" y2="34"/><line x1="78" y1="38" x2="82" y2="34"/>'
                . '<line x1="42" y1="74" x2="38" y2="78"/><line x1="78" y1="74" x2="82" y2="78"/>'
                . '</g>'
                . '<text x="60" y="64" text-anchor="middle" fill="#fff" font-size="22" font-family="serif" font-weight="bold">IHS</text>',

            // Radiant star — 8-point.
            'aquinas' =>
                "$f>"
                . '<polygon points="60,28 64,50 86,44 68,58 80,78 60,66 40,78 52,58 34,44 56,50"/>'
                . '</g>',

            // Heart with flame.
            'augustine' =>
                "$f>"
                . '<path d="M60,82 Q30,62 30,46 Q30,32 44,32 Q54,32 60,42 Q66,32 76,32 Q90,32 90,46 Q90,62 60,82Z"/>'
                . '</g>'
                . '<path d="M60,42 Q54,34 58,24 Q60,20 62,24 Q66,34 60,42Z" fill="none" stroke="#fff" stroke-width="2.5"/>',

            // Crown of thorns (spiky circle).
            'catherine-siena' =>
                '<circle cx="60" cy="55" r="20" fill="none" stroke="#fff" stroke-width="3"/>'
                . "$s stroke-width=\"3\">"
                . '<line x1="60" y1="35" x2="60" y2="28"/>'
                . '<line x1="77" y1="42" x2="82" y2="36"/>'
                . '<line x1="80" y1="55" x2="88" y2="55"/>'
                . '<line x1="77" y1="68" x2="82" y2="74"/>'
                . '<line x1="60" y1="75" x2="60" y2="82"/>'
                . '<line x1="43" y1="68" x2="38" y2="74"/>'
                . '<line x1="40" y1="55" x2="32" y2="55"/>'
                . '<line x1="43" y1="42" x2="38" y2="36"/>'
                . '</g>',

            // Rosary loop with star.
            'dominic' =>
                '<circle cx="60" cy="58" r="24" fill="none" stroke="#fff" stroke-width="3" stroke-dasharray="5,4"/>'
                . '<polygon points="60,30 62,38 70,38 64,43 66,52 60,47 54,52 56,43 50,38 58,38" fill="#fff"/>',

            // Two overlapping crowns.
            'kolbe' =>
                "$s stroke-width=\"3\">"
                . '<path d="M36,58 L42,40 L50,52 L58,38 L66,52 L74,40 L80,58 Z"/>'
                . '<line x1="36" y1="58" x2="80" y2="58"/>'
                . '<path d="M40,78 L46,60 L54,72 L62,58 L70,72 L78,60 L84,78 Z"/>'
                . '<line x1="40" y1="78" x2="84" y2="78"/>'
                . '</g>',

            // Rosary beads — loop of small circles.
            'pio' =>
                '<circle cx="60" cy="56" r="22" fill="none" stroke="#fff" stroke-width="2"/>'
                . "$f>"
                . '<circle cx="60" cy="34" r="3"/><circle cx="72" cy="37" r="3"/>'
                . '<circle cx="80" cy="46" r="3"/><circle cx="82" cy="58" r="3"/>'
                . '<circle cx="78" cy="70" r="3"/><circle cx="68" cy="76" r="3"/>'
                . '<circle cx="56" cy="78" r="3"/><circle cx="44" cy="74" r="3"/>'
                . '<circle cx="38" cy="64" r="3"/><circle cx="38" cy="50" r="3"/>'
                . '<circle cx="46" cy="40" r="3"/>'
                . '</g>'
                . '<line x1="60" y1="78" x2="60" y2="92" stroke="#fff" stroke-width="2" stroke-linecap="round"/>'
                . '<line x1="55" y1="88" x2="65" y2="88" stroke="#fff" stroke-width="2" stroke-linecap="round"/>',

            // Papal cross — triple bar.
            'jpii' =>
                "$s stroke-width=\"5\">"
                . '<line x1="60" y1="24" x2="60" y2="92"/>'
                . '</g>'
                . "$s stroke-width=\"4\">"
                . '<line x1="50" y1="38" x2="70" y2="38"/>'
                . '<line x1="46" y1="52" x2="74" y2="52"/>'
                . '<line x1="42" y1="66" x2="78" y2="66"/>'
                . '</g>',

            // Praying hands cupping a heart.
            'teresa-calcutta' =>
                "$s stroke-width=\"3\">"
                . '<path d="M44,72 Q36,56 42,44 Q46,38 52,42"/>'
                . '<path d="M76,72 Q84,56 78,44 Q74,38 68,42"/>'
                . '<line x1="44" y1="72" x2="60" y2="86"/>'
                . '<line x1="76" y1="72" x2="60" y2="86"/>'
                . '</g>'
                . '<path d="M60,62 Q50,52 50,46 Q50,40 56,40 Q60,42 60,42 Q60,42 64,40 Q70,40 70,46 Q70,52 60,62Z" fill="#fff"/>',

            // Open book with letter A.
            'seton' =>
                "$s stroke-width=\"3\">"
                . '<path d="M32,40 Q60,50 60,90"/>'
                . '<path d="M88,40 Q60,50 60,90"/>'
                . '<line x1="32" y1="40" x2="88" y2="40"/>'
                . '</g>'
                . '<text x="60" y="38" text-anchor="middle" fill="#fff" font-size="18" font-family="serif" font-weight="bold">A</text>',

            // Cross with lily.
            'kateri' =>
                "$s stroke-width=\"4\">"
                . '<line x1="60" y1="26" x2="60" y2="92"/>'
                . '<line x1="40" y1="48" x2="80" y2="48"/>'
                . '</g>'
                . '<ellipse cx="48" cy="72" rx="5" ry="10" fill="#fff" opacity="0.6" transform="rotate(-10 48 72)"/>'
                . '<ellipse cx="72" cy="72" rx="5" ry="10" fill="#fff" opacity="0.6" transform="rotate(10 72 72)"/>',

            // Broom.
            'martin' =>
                "<line x1=\"60\" y1=\"26\" x2=\"60\" y2=\"68\" stroke=\"#fff\" stroke-width=\"4\" stroke-linecap=\"round\"/>"
                . "$s stroke-width=\"3\">"
                . '<line x1="48" y1="68" x2="44" y2="92"/>'
                . '<line x1="53" y1="68" x2="52" y2="92"/>'
                . '<line x1="60" y1="68" x2="60" y2="92"/>'
                . '<line x1="67" y1="68" x2="68" y2="92"/>'
                . '<line x1="72" y1="68" x2="76" y2="92"/>'
                . '</g>',

            // Wreath of small roses (circle of dots).
            'rose-lima' =>
                "$f>"
                . '<circle cx="60" cy="32" r="5"/><circle cx="74" cy="36" r="5"/>'
                . '<circle cx="82" cy="48" r="5"/><circle cx="84" cy="62" r="5"/>'
                . '<circle cx="78" cy="74" r="5"/><circle cx="68" cy="82" r="5"/>'
                . '<circle cx="54" cy="84" r="5"/><circle cx="42" cy="78" r="5"/>'
                . '<circle cx="36" cy="66" r="5"/><circle cx="36" cy="52" r="5"/>'
                . '<circle cx="42" cy="40" r="5"/><circle cx="52" cy="34" r="5"/>'
                . '</g>',

            // Tilma (poncho shape) with star.
            'juan-diego' =>
                "$f>"
                . '<path d="M40,36 L60,28 L80,36 L86,80 Q60,90 34,80 Z"/>'
                . '</g>'
                . '<polygon points="60,46 62,52 68,52 63,56 65,62 60,58 55,62 57,56 52,52 58,52" fill="none" stroke="#fff" stroke-width="1.5"/>',

            // Candle with flame.
            'bernadette' =>
                '<rect x="52" y="50" width="16" height="40" rx="3" fill="#fff"/>'
                . '<path d="M60,50 Q54,42 58,32 Q60,26 62,32 Q66,42 60,50Z" fill="#fff"/>',

            // Three arrows pointing up.
            'sebastian' =>
                "$s stroke-width=\"3\">"
                . '<line x1="46" y1="88" x2="46" y2="30"/>'
                . '<line x1="60" y1="88" x2="60" y2="30"/>'
                . '<line x1="74" y1="88" x2="74" y2="30"/>'
                . '</g>'
                . "$f>"
                . '<polygon points="46,30 40,42 52,42"/>'
                . '<polygon points="60,30 54,42 66,42"/>'
                . '<polygon points="74,30 68,42 80,42"/>'
                . '</g>',

            // Staff crossing wavy water line.
            'christopher' =>
                "<line x1=\"56\" y1=\"26\" x2=\"56\" y2=\"92\" stroke=\"#fff\" stroke-width=\"5\" stroke-linecap=\"round\"/>"
                . '<path d="M30,68 Q45,58 60,68 Q75,78 90,68" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round"/>',

            // Ox head — horns + face oval.
            'luke' =>
                '<ellipse cx="60" cy="62" rx="16" ry="20" fill="#fff"/>'
                . '<path d="M44,52 Q36,34 30,30" fill="none" stroke="#fff" stroke-width="4" stroke-linecap="round"/>'
                . '<path d="M76,52 Q84,34 90,30" fill="none" stroke="#fff" stroke-width="4" stroke-linecap="round"/>',

            // Lion face — mane circle + inner face.
            'mark' =>
                '<circle cx="60" cy="56" r="28" fill="#fff" opacity="0.5"/>'
                . '<circle cx="60" cy="58" r="18" fill="#fff"/>'
                . '<circle cx="52" cy="52" r="3" fill="none" stroke="#000" stroke-width="1.5" opacity="0.5"/>'
                . '<circle cx="68" cy="52" r="3" fill="none" stroke="#000" stroke-width="1.5" opacity="0.5"/>'
                . '<ellipse cx="60" cy="62" rx="5" ry="3" fill="none" stroke="#000" stroke-width="1.5" opacity="0.5"/>',

            // Angel wings — spread pair.
            'matthew' =>
                "$s stroke-width=\"3\">"
                . '<path d="M60,70 Q40,50 30,32 Q38,44 44,40 Q36,30 42,28 Q50,36 52,46"/>'
                . '<path d="M60,70 Q80,50 90,32 Q82,44 76,40 Q84,30 78,28 Q70,36 68,46"/>'
                . '</g>'
                . '<circle cx="60" cy="76" r="6" fill="#fff"/>',

            // Eagle — spread wings + head.
            'john-evangelist' =>
                "$f>"
                . '<path d="M60,42 Q40,34 28,44 Q36,40 42,42 Q34,48 30,58 Q40,50 48,50 L60,56Z"/>'
                . '<path d="M60,42 Q80,34 92,44 Q84,40 78,42 Q86,48 90,58 Q80,50 72,50 L60,56Z"/>'
                . '<circle cx="60" cy="38" r="6"/>'
                . '</g>',

            // Crossed keys.
            'peter' =>
                '<g fill="none" stroke="#fff" stroke-width="3.5" stroke-linecap="round">'
                . '<circle cx="42" cy="36" r="7"/>'
                . '<line x1="47" y1="41" x2="82" y2="76"/>'
                . '<line x1="72" y1="66" x2="78" y2="60"/>'
                . '<circle cx="78" cy="36" r="7"/>'
                . '<line x1="73" y1="41" x2="38" y2="76"/>'
                . '<line x1="48" y1="66" x2="42" y2="60"/>'
                . '</g>',

            // Sword + scroll.
            'paul' =>
                "$s stroke-width=\"4\">"
                . '<line x1="42" y1="26" x2="42" y2="90"/>'
                . '<line x1="32" y1="46" x2="52" y2="46"/>'
                . '</g>'
                . "$s stroke-width=\"3\">"
                . '<path d="M64,34 Q82,34 82,50 L82,76 Q82,86 72,86"/>'
                . '<path d="M72,34 Q72,44 82,44"/>'
                . '</g>',

            // Saltire (X-cross).
            'andrew' =>
                '<g fill="none" stroke="#fff" stroke-width="7" stroke-linecap="round">'
                . '<line x1="32" y1="32" x2="88" y2="88"/>'
                . '<line x1="88" y1="32" x2="32" y2="88"/>'
                . '</g>',

            // Broken chain — two links with gap.
            'bakhita' =>
                '<g fill="none" stroke="#fff" stroke-width="3.5" stroke-linecap="round">'
                . '<ellipse cx="44" cy="52" rx="12" ry="8"/>'
                . '<ellipse cx="44" cy="68" rx="12" ry="8"/>'
                . '<ellipse cx="76" cy="52" rx="12" ry="8"/>'
                . '<ellipse cx="76" cy="68" rx="12" ry="8"/>'
                . '</g>'
                . '<line x1="56" y1="48" x2="64" y2="42" stroke="#fff" stroke-width="3" stroke-linecap="round"/>'
                . '<line x1="56" y1="72" x2="64" y2="78" stroke="#fff" stroke-width="3" stroke-linecap="round"/>',

            // Stethoscope.
            'gianna' =>
                "$s stroke-width=\"3\">"
                . '<path d="M46,34 L46,58 Q46,78 60,78 Q74,78 74,58 L74,34"/>'
                . '</g>'
                . '<circle cx="60" cy="86" r="6" fill="none" stroke="#fff" stroke-width="3"/>'
                . '<circle cx="46" cy="32" r="4" fill="#fff"/>'
                . '<circle cx="74" cy="32" r="4" fill="#fff"/>',

            // Joyful heart with rays.
            'philip-neri' =>
                "$f>"
                . '<path d="M60,78 Q34,60 34,46 Q34,34 46,34 Q54,34 60,42 Q66,34 74,34 Q86,34 86,46 Q86,60 60,78Z"/>'
                . '</g>'
                . "$s stroke-width=\"3\">"
                . '<line x1="60" y1="30" x2="60" y2="22"/>'
                . '<line x1="44" y1="30" x2="40" y2="22"/>'
                . '<line x1="76" y1="30" x2="80" y2="22"/>'
                . '</g>',

            // Lamb with nimbus.
            'agnes' =>
                "$f>"
                . '<ellipse cx="58" cy="60" rx="18" ry="14"/>'
                . '<circle cx="40" cy="50" r="9"/>'
                . '<rect x="44" y="70" width="5" height="14" rx="2"/>'
                . '<rect x="54" y="70" width="5" height="14" rx="2"/>'
                . '<rect x="64" y="70" width="5" height="14" rx="2"/>'
                . '<rect x="72" y="68" width="5" height="12" rx="2"/>'
                . '</g>'
                . '<circle cx="40" cy="50" r="13" fill="none" stroke="#fff" stroke-width="1.5"/>',

            // Oil lamp with flame.
            'lucy' =>
                "$f>"
                . '<ellipse cx="60" cy="72" rx="22" ry="10"/>'
                . '<rect x="50" y="62" width="20" height="12" rx="4"/>'
                . '<path d="M60,62 Q55,54 58,46 Q60,40 62,46 Q65,54 60,62Z"/>'
                . '</g>'
                . '<rect x="48" y="82" width="24" height="4" rx="2" fill="#fff"/>',

            // Descending dove.
            'scholastica' =>
                "$f>"
                . '<ellipse cx="60" cy="56" rx="12" ry="10"/>'
                . '<circle cx="55" cy="50" r="8"/>'
                . '<path d="M48,56 Q30,48 26,58 Q36,54 48,56Z"/>'
                . '<path d="M72,56 Q90,48 94,58 Q84,54 72,56Z"/>'
                . '<path d="M56,64 L60,78 L64,64Z"/>'
                . '</g>',

            // Scales of justice.
            'thomas-more' =>
                "<line x1=\"60\" y1=\"28\" x2=\"60\" y2=\"88\" stroke=\"#fff\" stroke-width=\"4\" stroke-linecap=\"round\"/>"
                . "<line x1=\"34\" y1=\"44\" x2=\"86\" y2=\"44\" stroke=\"#fff\" stroke-width=\"3\" stroke-linecap=\"round\"/>"
                . '<path d="M28,66 Q34,48 40,66 Z" fill="#fff"/>'
                . '<path d="M80,72 Q86,54 92,72 Z" fill="#fff"/>'
                . "$s stroke-width=\"3\">"
                . '<line x1="34" y1="44" x2="34" y2="66"/>'
                . '<line x1="86" y1="44" x2="86" y2="72"/>'
                . '</g>',

            // =====================================================================
            //  VIRTUES (8)
            // =====================================================================

            // Cross with flame.
            'faith' =>
                "$s stroke-width=\"5\">"
                . '<line x1="60" y1="40" x2="60" y2="90"/>'
                . '<line x1="42" y1="58" x2="78" y2="58"/>'
                . '</g>'
                . '<path d="M60,40 Q54,32 58,24 Q60,18 62,24 Q66,32 60,40Z" fill="#fff"/>',

            // Anchor.
            'hope' =>
                "$s stroke-width=\"4\">"
                . '<line x1="60" y1="28" x2="60" y2="82"/>'
                . '<line x1="48" y1="38" x2="72" y2="38"/>'
                . '<path d="M36,82 Q36,62 60,62"/>'
                . '<path d="M84,82 Q84,62 60,62"/>'
                . '</g>'
                . '<circle cx="60" cy="28" r="5" fill="none" stroke="#fff" stroke-width="3"/>'
                . '<circle cx="36" cy="84" r="3" fill="#fff"/>'
                . '<circle cx="84" cy="84" r="3" fill="#fff"/>',

            // Heart cradled in hands.
            'charity' =>
                '<path d="M60,62 Q42,48 42,40 Q42,32 50,32 Q56,34 60,40 Q64,34 70,32 Q78,32 78,40 Q78,48 60,62Z" fill="#fff"/>'
                . "$s stroke-width=\"3\">"
                . '<path d="M36,72 Q36,56 48,56 Q54,56 56,62"/>'
                . '<path d="M84,72 Q84,56 72,56 Q66,56 64,62"/>'
                . '<path d="M36,72 Q60,88 84,72"/>'
                . '</g>',

            // Lion rampant (standing).
            'courage' =>
                "$f>"
                . '<circle cx="56" cy="40" r="10"/>'
                . '<circle cx="56" cy="40" r="16" opacity="0.5"/>'
                . '<ellipse cx="60" cy="60" rx="12" ry="16"/>'
                . '<rect x="46" y="72" width="6" height="16" rx="2"/>'
                . '<rect x="68" y="72" width="6" height="16" rx="2"/>'
                . '<path d="M72,56 Q80,50 84,44" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round"/>'
                . '</g>',

            // Owl face.
            'wisdom' =>
                '<circle cx="48" cy="52" r="12" fill="none" stroke="#fff" stroke-width="3"/>'
                . '<circle cx="72" cy="52" r="12" fill="none" stroke="#fff" stroke-width="3"/>'
                . '<circle cx="48" cy="52" r="5" fill="#fff"/>'
                . '<circle cx="72" cy="52" r="5" fill="#fff"/>'
                . '<path d="M56,58 L60,64 L64,58" fill="none" stroke="#fff" stroke-width="2.5" stroke-linecap="round"/>'
                . '<path d="M36,44 L48,36 L60,44 L72,36 L84,44" fill="none" stroke="#fff" stroke-width="2.5" stroke-linecap="round"/>',

            // Hourglass.
            'patience' =>
                '<rect x="40" y="28" width="40" height="6" rx="2" fill="#fff"/>'
                . '<rect x="40" y="86" width="40" height="6" rx="2" fill="#fff"/>'
                . "$s stroke-width=\"3\">"
                . '<line x1="44" y1="34" x2="44" y2="38"/><line x1="76" y1="34" x2="76" y2="38"/>'
                . '<line x1="44" y1="82" x2="44" y2="86"/><line x1="76" y1="82" x2="76" y2="86"/>'
                . '<path d="M44,38 Q44,60 60,60 Q76,60 76,38"/>'
                . '<path d="M44,82 Q44,60 60,60 Q76,60 76,82"/>'
                . '</g>',

            // Basin with water drops.
            'humility' =>
                '<path d="M34,58 Q34,82 60,82 Q86,82 86,58 Z" fill="#fff"/>'
                . '<line x1="34" y1="58" x2="86" y2="58" stroke="#fff" stroke-width="3" stroke-linecap="round"/>'
                . "$f opacity=\"0.7\">"
                . '<path d="M52,48 Q54,38 56,48 Z"/>'
                . '<path d="M60,44 Q62,32 64,44 Z"/>'
                . '<path d="M68,48 Q70,38 72,48 Z"/>'
                . '</g>',

            // Radiant sun.
            'joy' =>
                '<circle cx="60" cy="58" r="14" fill="#fff"/>'
                . "$s stroke-width=\"3\">"
                . '<line x1="60" y1="36" x2="60" y2="28"/><line x1="60" y1="80" x2="60" y2="88"/>'
                . '<line x1="38" y1="58" x2="30" y2="58"/><line x1="82" y1="58" x2="90" y2="58"/>'
                . '<line x1="44" y1="42" x2="38" y2="36"/><line x1="76" y1="42" x2="82" y2="36"/>'
                . '<line x1="44" y1="74" x2="38" y2="80"/><line x1="76" y1="74" x2="82" y2="80"/>'
                . '</g>',

            // =====================================================================
            //  NATURE / CREATION (10)
            // =====================================================================

            // Mountain peaks.
            'mountain' =>
                "$f>"
                . '<polygon points="60,28 86,88 34,88"/>'
                . '<polygon points="78,48 96,88 60,88" opacity="0.6"/>'
                . '</g>',

            // Winding river S-curve.
            'river' =>
                "$s stroke-width=\"8\" opacity=\"0.9\">"
                . '<path d="M44,26 Q76,40 44,58 Q28,68 56,82 Q72,90 76,94"/>'
                . '</g>'
                . "$s stroke-width=\"4\" opacity=\"0.5\">"
                . '<path d="M52,26 Q84,40 52,58 Q36,68 64,82 Q80,90 84,94"/>'
                . '</g>',

            // Oak tree — trunk + round crown.
            'oak' =>
                '<rect x="55" y="62" width="10" height="28" rx="2" fill="#fff"/>'
                . '<circle cx="60" cy="46" r="24" fill="#fff"/>',

            // Eagle soaring — spread wings.
            'eagle-soaring' =>
                "$f>"
                . '<path d="M60,52 Q40,40 24,48 Q32,42 36,44 Q28,34 34,32 Q42,38 60,48Z"/>'
                . '<path d="M60,52 Q80,40 96,48 Q88,42 84,44 Q92,34 86,32 Q78,38 60,48Z"/>'
                . '<ellipse cx="60" cy="56" rx="8" ry="5"/>'
                . '</g>',

            // Six-pointed star (Star of David / Bethlehem).
            'star' =>
                "$f>"
                . '<polygon points="60,26 68,48 92,48 72,62 80,86 60,72 40,86 48,62 28,48 52,48"/>'
                . '</g>',

            // Half sun with rays rising.
            'sunrise' =>
                '<path d="M28,72 Q28,40 60,40 Q92,40 92,72 Z" fill="#fff"/>'
                . "$s stroke-width=\"3\">"
                . '<line x1="60" y1="32" x2="60" y2="24"/>'
                . '<line x1="42" y1="36" x2="38" y2="28"/>'
                . '<line x1="78" y1="36" x2="82" y2="28"/>'
                . '<line x1="30" y1="48" x2="24" y2="44"/>'
                . '<line x1="90" y1="48" x2="96" y2="44"/>'
                . '</g>'
                . '<line x1="24" y1="72" x2="96" y2="72" stroke="#fff" stroke-width="3" stroke-linecap="round"/>',

            // Gentle lamb lying down.
            'lamb' =>
                "$f>"
                . '<ellipse cx="58" cy="62" rx="22" ry="12"/>'
                . '<circle cx="36" cy="54" r="10"/>'
                . '<rect x="40" y="72" width="5" height="10" rx="2"/>'
                . '<rect x="52" y="72" width="5" height="10" rx="2"/>'
                . '<rect x="64" y="70" width="5" height="10" rx="2"/>'
                . '<rect x="74" y="68" width="5" height="8" rx="2"/>'
                . '</g>',

            // Dove with olive branch.
            'dove' =>
                "$f>"
                . '<ellipse cx="58" cy="54" rx="14" ry="10"/>'
                . '<circle cx="48" cy="48" r="8"/>'
                . '<path d="M38,52 Q22,44 20,54 Q28,50 38,54Z"/>'
                . '<path d="M70,52 Q86,42 92,50 Q84,48 70,52Z"/>'
                . '</g>'
                . '<path d="M44,56 Q36,66 32,62 Q34,70 42,68 Q38,74 44,76" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"/>',

            // Ichthys fish outline.
            'fish' =>
                '<path d="M28,60 Q60,32 92,60 Q60,88 28,60Z" fill="none" stroke="#fff" stroke-width="3.5"/>'
                . '<circle cx="78" cy="56" r="3" fill="#fff"/>',

            // Wheat sheaf — stems + grain heads.
            'wheat' =>
                "$s stroke-width=\"3\">"
                . '<line x1="50" y1="90" x2="46" y2="50"/>'
                . '<line x1="55" y1="90" x2="54" y2="46"/>'
                . '<line x1="60" y1="90" x2="60" y2="44"/>'
                . '<line x1="65" y1="90" x2="66" y2="46"/>'
                . '<line x1="70" y1="90" x2="74" y2="50"/>'
                . '</g>'
                . "$f>"
                . '<ellipse cx="46" cy="44" rx="4" ry="8" transform="rotate(-5 46 44)"/>'
                . '<ellipse cx="54" cy="40" rx="4" ry="8"/>'
                . '<ellipse cx="60" cy="38" rx="4" ry="8"/>'
                . '<ellipse cx="66" cy="40" rx="4" ry="8"/>'
                . '<ellipse cx="74" cy="44" rx="4" ry="8" transform="rotate(5 74 44)"/>'
                . '</g>',

            // =====================================================================
            //  ABSTRACT / SYMBOLS (6)
            // =====================================================================

            // Celtic cross — cross with circle.
            'celtic-cross' =>
                "$s stroke-width=\"5\">"
                . '<line x1="60" y1="24" x2="60" y2="92"/>'
                . '<line x1="34" y1="50" x2="86" y2="50"/>'
                . '</g>'
                . '<circle cx="60" cy="50" r="18" fill="none" stroke="#fff" stroke-width="3.5"/>',

            // Shield with cross.
            'shield-cross' =>
                '<path d="M34,32 L60,26 L86,32 L86,64 Q86,86 60,92 Q34,86 34,64 Z" fill="none" stroke="#fff" stroke-width="3"/>'
                . "$s stroke-width=\"3.5\">"
                . '<line x1="60" y1="38" x2="60" y2="80"/>'
                . '<line x1="44" y1="54" x2="76" y2="54"/>'
                . '</g>',

            // Trinity knot (triquetra).
            'celtic-knot' =>
                '<g fill="none" stroke="#fff" stroke-width="3.5">'
                . '<path d="M60,30 Q80,50 60,70 Q40,50 60,30Z"/>'
                . '<path d="M42,74 Q42,46 60,30 Q52,58 42,74Z"/>'
                . '<path d="M78,74 Q78,46 60,30 Q68,58 78,74Z"/>'
                . '<path d="M42,74 Q60,82 78,74"/>'
                . '</g>',

            // Rose window — divided circle.
            'rose-window' =>
                '<circle cx="60" cy="58" r="28" fill="none" stroke="#fff" stroke-width="3"/>'
                . '<circle cx="60" cy="58" r="10" fill="none" stroke="#fff" stroke-width="2.5"/>'
                . "$s stroke-width=\"3\">"
                . '<line x1="60" y1="30" x2="60" y2="48"/><line x1="60" y1="68" x2="60" y2="86"/>'
                . '<line x1="32" y1="58" x2="50" y2="58"/><line x1="70" y1="58" x2="88" y2="58"/>'
                . '<line x1="40" y1="38" x2="53" y2="51"/><line x1="67" y1="65" x2="80" y2="78"/>'
                . '<line x1="80" y1="38" x2="67" y2="51"/><line x1="53" y1="65" x2="40" y2="78"/>'
                . '</g>',

            // Chi-Rho ☧.
            'chi-rho' =>
                '<g fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round">'
                . '<line x1="36" y1="82" x2="84" y2="32"/>'
                . '<line x1="84" y1="82" x2="36" y2="32"/>'
                . '</g>'
                . '<path d="M60,28 Q80,28 80,44 Q80,60 60,60" fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round"/>',

            // Alpha Α and Omega Ω.
            'alpha-omega' =>
                '<text x="38" y="72" text-anchor="middle" fill="#fff" font-size="42" font-family="serif">&#913;</text>'
                . '<text x="82" y="72" text-anchor="middle" fill="#fff" font-size="42" font-family="serif">&#937;</text>',

        ];
    }

    /**
     * Default avatar for users who haven't chosen one.
     *
     * @return array{saint:string, colour:string}
     */
    public function get_default_avatar(): array {
        return ['saint' => 'chi-rho', 'colour' => 'royal-blue'];
    }

    /**
     * Normalise a (saint, colour) selection, falling back to defaults for
     * missing/unknown ids. Moodle-side equivalent of the Drupal
     * getUserAvatar(); takes raw string values (read from profile fields)
     * rather than a Drupal account object.
     *
     * @return array{saint:string, colour:string}
     */
    public function normalise_selection(string $saint, string $colour): array {
        $default = $this->get_default_avatar();
        if ($saint === '' || !isset($this->get_avatars()[$saint])) {
            return $default;
        }
        if ($colour === '' || !isset($this->get_colours()[$colour])) {
            $colour = $default['colour'];
        }
        return ['saint' => $saint, 'colour' => $colour];
    }

}
