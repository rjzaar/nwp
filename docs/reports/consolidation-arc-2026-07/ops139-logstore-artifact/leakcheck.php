<?php
/**
 * ops#139 — pure leak-detection logic for the logstore declassification check.
 *
 * Deliberately Moodle-free so it can be unit-tested standalone (see
 * canonical_id_test.php). The Moodle CLI wrapper
 * verify_logstore_declassified.php supplies the real rows and titles.
 *
 * Design note. The check is TITLE-DRIVEN, not pattern-driven: it is handed the
 * actual doctrine/practice titles read out of the database and looks for those
 * exact strings. A regex for "what a doctrine title looks like" would pass
 * whenever it failed to recognise one, which is the wrong direction to fail in
 * for an Art.9 acceptance check.
 *
 * @package   ops139
 * @copyright NWP
 */

/**
 * Normalise a value to a searchable string.
 *
 * logstore `other` is a serialised PHP array in the DB; callers may hand us
 * either the raw string or an already-unserialised array. Both must be
 * searched, and an unserialisable blob must be searched as its raw text
 * rather than skipped.
 *
 * @param mixed $value
 * @return string
 */
function ops139_stringify($value): string {
    if (is_string($value)) {
        return $value;
    }
    if (is_array($value) || is_object($value)) {
        return print_r($value, true);
    }
    if (is_bool($value)) {
        return $value ? 'true' : 'false';
    }
    if ($value === null) {
        return '';
    }
    return (string) $value;
}

/**
 * Is $needle present in $haystack, case-insensitively?
 *
 * Case-insensitive on purpose: a log row that stored "confession" rather than
 * "Confession" is exactly as re-identifying.
 */
function ops139_contains(string $haystack, string $needle): bool {
    if ($needle === '') {
        return false;
    }
    return stripos($haystack, $needle) !== false;
}

/**
 * Titles worth asserting against.
 *
 * Drops empty strings and anything too short to be a meaningful title —
 * a one- or two-character "title" would match half the log by accident and
 * turn the check into noise. Values that look like a canonical id (B5.03,
 * A1.01.q4) are dropped too: those are exactly what we WANT in the log, so
 * matching them would report the fix as the failure.
 *
 * @param string[] $titles
 * @return string[]
 */
function ops139_meaningful_titles(array $titles): array {
    $out = [];
    foreach ($titles as $t) {
        $t = trim(ops139_stringify($t));
        if (mb_strlen($t) < 3) {
            continue;
        }
        // Canonical ids: a letter, digits, a dot, digits — optionally .qN etc.
        if (preg_match('/^[A-Za-z]\d+\.\d+(\.[A-Za-z0-9_]+)*$/', $t)) {
            continue;
        }
        $out[$t] = true;
    }
    return array_keys($out);
}

/**
 * Find doctrine/practice titles leaking into logstore rows.
 *
 * @param array $rows   Each row an associative array of column => value.
 *                      The `id` and `eventname` columns are used for
 *                      reporting when present.
 * @param string[] $titles Known doctrine/practice titles from the DB.
 * @return array List of findings: ['row_id', 'eventname', 'column', 'title'].
 */
function ops139_find_title_leaks(array $rows, array $titles): array {
    $titles = ops139_meaningful_titles($titles);
    $findings = [];

    foreach ($rows as $row) {
        $row = (array) $row;
        $rowid = $row['id'] ?? '?';
        $eventname = ops139_stringify($row['eventname'] ?? '?');

        foreach ($row as $column => $value) {
            // The id/eventname columns are metadata; a class name cannot leak
            // a title, and skipping them keeps findings pointed at real data.
            if ($column === 'id') {
                continue;
            }
            $haystack = ops139_stringify($value);
            if ($haystack === '') {
                continue;
            }
            foreach ($titles as $title) {
                if (ops139_contains($haystack, $title)) {
                    $findings[] = [
                        'row_id'    => $rowid,
                        'eventname' => $eventname,
                        'column'    => $column,
                        'title'     => $title,
                    ];
                }
            }
        }
    }

    return $findings;
}
