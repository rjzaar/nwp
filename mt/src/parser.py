"""Time, day, and section regex parsing for mass times extraction.

This module provides deterministic parsing of mass times from text using
regex patterns. It handles the wide variety of formats used by Catholic
parishes in their bulletins and websites.
"""

import re
from dataclasses import dataclass


# === TIME PATTERNS ===

# 9:30am, 9:30 AM, 9:30am., 9.30am, 9:30 a.m.
TIME_COLON_DOT = re.compile(
    r'(\d{1,2})[:.]\s?(\d{2})\s*([AaPp]\.?\s?[Mm]\.?)',
)

# 9am, 9 AM, 9pm (no minutes)
TIME_NO_MINUTES = re.compile(
    r'(?<!\d)(\d{1,2})\s*([AaPp]\.?\s?[Mm]\.?)(?!\s*\d)',
)

# 24-hour: 09:30, 17:00
TIME_24H = re.compile(
    r'(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?!\s*[AaPp])',
)

# All time patterns combined for scanning
ALL_TIME_PATTERNS = [TIME_COLON_DOT, TIME_NO_MINUTES, TIME_24H]


# === DAY PATTERNS ===

DAYS_FULL = [
    "Monday", "Tuesday", "Wednesday", "Thursday",
    "Friday", "Saturday", "Sunday",
]

DAYS_ABBREV = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

DAY_FULL_RE = re.compile(
    r'(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)',
    re.IGNORECASE,
)

DAY_ABBREV_RE = re.compile(
    r'(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\.?(?:day)?',
    re.IGNORECASE,
)

# Ranges: Monday-Friday, Monday to Friday, Weekday, Weekend
DAY_RANGE_RE = re.compile(
    r'(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)'
    r'\s*[-–—to]+\s*'
    r'(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)',
    re.IGNORECASE,
)

WEEKDAY_RE = re.compile(r'\b(Weekday)s?\b', re.IGNORECASE)
WEEKEND_RE = re.compile(r'\b(Weekend)s?\b', re.IGNORECASE)


# === SECTION HEADING PATTERNS ===

MASS_TIMES_HEADING_RE = re.compile(
    r'mass\s*times?|liturgy\s*schedule|weekend\s*mass|weekday\s*mass'
    r'|service\s*times?|worship\s*times?|schedule\s*of\s*mass'
    r'|mass\s*schedule|holy\s*mass|eucharist',
    re.IGNORECASE,
)

# === CHANGE INDICATOR PATTERNS ===

CHANGE_INDICATORS = [
    re.compile(r'\bno\s+mass\b', re.IGNORECASE),
    re.compile(r'\bmass\s+cancell?ed\b', re.IGNORECASE),
    re.compile(r'\bcancell?ed\b', re.IGNORECASE),
    re.compile(r'\bchanged?\s+to\b', re.IGNORECASE),
    re.compile(r'\bnote\s*:', re.IGNORECASE),
    re.compile(r'\bplease\s+note\b', re.IGNORECASE),
    re.compile(r'\bno\s+\w+\s+this\s+week\b', re.IGNORECASE),
    re.compile(r'\binstead\b', re.IGNORECASE),
    re.compile(r'\bwill\s+not\s+be\s+held\b', re.IGNORECASE),
    re.compile(r'\bmoved?\s+to\b', re.IGNORECASE),
    re.compile(r'\brescheduled\b', re.IGNORECASE),
]

# === SPECIAL MASS MARKERS ===

SPECIAL_MARKERS_RE = re.compile(
    r'\b(Vigil|Reconciliation|Adoration|Latin\s*(?:Mass|Rite)?|Children\'?s?\s*(?:Liturgy|Mass)'
    r'|First\s+Friday|First\s+Saturday|Holy\s+Day|School\s+Term)\b',
    re.IGNORECASE,
)

# === LANGUAGE MARKERS ===

LANGUAGE_RE = re.compile(
    r'\b(Italian|Vietnamese|Latin|Polish|Croatian|Korean|Chinese'
    r'|Spanish|Maltese|Filipino|Tagalog|Slavonic)\b',
    re.IGNORECASE,
)


@dataclass
class ParsedTime:
    """A parsed time value."""
    hour: int
    minute: int
    period: str  # "AM" or "PM"
    original: str  # Original text matched

    @property
    def formatted(self) -> str:
        """Return standardised time string like '9:30 AM'."""
        return f"{self.hour}:{self.minute:02d} {self.period}"

    @property
    def sort_key(self) -> int:
        """Return minutes since midnight for sorting."""
        h = self.hour % 12
        if self.period == "PM":
            h += 12
        return h * 60 + self.minute


def normalise_day(text: str) -> str | None:
    """Normalise a day name to full capitalised form.

    Returns None if text doesn't match a day name.
    """
    text = text.strip().rstrip(".")
    for full, abbrev in zip(DAYS_FULL, DAYS_ABBREV):
        if text.lower() == full.lower() or text.lower().startswith(abbrev.lower()):
            return full
    return None


def expand_day_range(start: str, end: str) -> list[str]:
    """Expand a day range like 'Monday'-'Friday' to a list of days."""
    start_norm = normalise_day(start)
    end_norm = normalise_day(end)
    if not start_norm or not end_norm:
        return []
    start_idx = DAYS_FULL.index(start_norm)
    end_idx = DAYS_FULL.index(end_norm)
    if start_idx <= end_idx:
        return DAYS_FULL[start_idx:end_idx + 1]
    # Wrap around (e.g., Saturday-Sunday)
    return DAYS_FULL[start_idx:] + DAYS_FULL[:end_idx + 1]


def parse_time(text: str) -> ParsedTime | None:
    """Parse a single time string into a ParsedTime.

    Handles formats: 9:30am, 9.30 AM, 9am, 09:30, 17:00, etc.
    Returns None if no valid time found.
    """
    text = text.strip()

    # Try colon/dot format first: 9:30am, 9.30 AM
    m = TIME_COLON_DOT.search(text)
    if m:
        hour, minute = int(m.group(1)), int(m.group(2))
        period = m.group(3).replace(".", "").replace(" ", "").upper()
        period = "AM" if period.startswith("A") else "PM"
        if 1 <= hour <= 12 and 0 <= minute <= 59:
            return ParsedTime(hour, minute, period, m.group(0).strip())

    # Try no-minutes format: 9am, 9 PM
    m = TIME_NO_MINUTES.search(text)
    if m:
        hour = int(m.group(1))
        period = m.group(2).replace(".", "").replace(" ", "").upper()
        period = "AM" if period.startswith("A") else "PM"
        if 1 <= hour <= 12:
            return ParsedTime(hour, 0, period, m.group(0).strip())

    # Try 24-hour format: 09:30, 17:00
    m = TIME_24H.search(text)
    if m:
        hour, minute = int(m.group(1)), int(m.group(2))
        if 0 <= hour <= 23 and 0 <= minute <= 59:
            if hour == 0:
                return ParsedTime(12, minute, "AM", m.group(0).strip())
            elif hour < 12:
                return ParsedTime(hour, minute, "AM", m.group(0).strip())
            elif hour == 12:
                return ParsedTime(12, minute, "PM", m.group(0).strip())
            else:
                return ParsedTime(hour - 12, minute, "PM", m.group(0).strip())

    return None


def find_times(text: str) -> list[ParsedTime]:
    """Find all time values in a text string.

    Returns a list of ParsedTime objects, deduplicated and sorted.
    """
    results = []
    seen = set()

    for pattern in [TIME_COLON_DOT, TIME_NO_MINUTES, TIME_24H]:
        for m in pattern.finditer(text):
            parsed = parse_time(m.group(0))
            if parsed and parsed.formatted not in seen:
                seen.add(parsed.formatted)
                results.append(parsed)

    results.sort(key=lambda t: t.sort_key)
    return results


def find_days(text: str) -> list[str]:
    """Find all day names in a text string.

    Returns normalised day names in order of appearance,
    with ranges expanded.
    """
    days = []
    seen = set()

    # Check for ranges first
    for m in DAY_RANGE_RE.finditer(text):
        expanded = expand_day_range(m.group(1), m.group(2))
        for d in expanded:
            if d not in seen:
                days.append(d)
                seen.add(d)

    # Check for "Weekday" / "Weekend"
    if WEEKDAY_RE.search(text):
        for d in DAYS_FULL[:5]:  # Mon-Fri
            if d not in seen:
                days.append(d)
                seen.add(d)

    if WEEKEND_RE.search(text):
        for d in DAYS_FULL[5:]:  # Sat-Sun
            if d not in seen:
                days.append(d)
                seen.add(d)

    # Check for individual days (only if not already found via range)
    for m in DAY_FULL_RE.finditer(text):
        d = normalise_day(m.group(1))
        if d and d not in seen:
            days.append(d)
            seen.add(d)

    for m in DAY_ABBREV_RE.finditer(text):
        d = normalise_day(m.group(1))
        if d and d not in seen:
            days.append(d)
            seen.add(d)

    return days


def detect_change_indicators(text: str) -> list[str]:
    """Detect change indicator phrases in text.

    Returns a list of matched indicator phrases.
    """
    found = []
    for pattern in CHANGE_INDICATORS:
        for m in pattern.finditer(text):
            found.append(m.group(0))
    return found


def detect_language(text: str) -> str:
    """Detect language marker in a text line. Returns 'English' if none found."""
    m = LANGUAGE_RE.search(text)
    if m:
        return m.group(1).title()
    return "English"


def detect_special_type(text: str) -> str:
    """Detect special mass type markers. Returns 'Regular' if none found."""
    m = SPECIAL_MARKERS_RE.search(text)
    if m:
        raw = m.group(1).strip()
        # Normalise common types
        if re.match(r'vigil', raw, re.IGNORECASE):
            return "Vigil"
        if re.match(r'reconcil', raw, re.IGNORECASE):
            return "Reconciliation"
        if re.match(r'ador', raw, re.IGNORECASE):
            return "Adoration"
        if re.match(r'latin', raw, re.IGNORECASE):
            return "Latin Rite"
        if re.match(r'children', raw, re.IGNORECASE):
            return "Children's Liturgy"
        if re.match(r'holy\s+day', raw, re.IGNORECASE):
            return "Holy Day"
        return raw
    return "Regular"


def parse_day_time_block(text: str) -> dict[str, list[str]]:
    """Parse a block of text into a day→times mapping.

    Handles common formats:
    - "Saturday: 6:00 PM"
    - "Sunday 8:00 AM, 10:00 AM, 5:30 PM"
    - "Monday-Friday 9:15 AM"
    - "Weekday Masses: 9:15am"

    Returns dict mapping day names to lists of formatted time strings.
    """
    result: dict[str, list[str]] = {}

    # Split into lines for line-by-line parsing
    lines = text.strip().split("\n")

    for line in lines:
        line = line.strip()
        if not line:
            continue

        days = find_days(line)
        times = find_times(line)

        if days and times:
            time_strs = [t.formatted for t in times]
            for day in days:
                if day not in result:
                    result[day] = []
                result[day].extend(time_strs)

    return result


def has_mass_times_heading(text: str) -> bool:
    """Check if text contains a mass times section heading."""
    return bool(MASS_TIMES_HEADING_RE.search(text))
