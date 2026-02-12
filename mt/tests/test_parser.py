"""Tests for the mass times parser module."""

import pytest
import sys
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from parser import (
    parse_time,
    find_times,
    find_days,
    normalise_day,
    expand_day_range,
    parse_day_time_block,
    detect_change_indicators,
    detect_language,
    detect_special_type,
    has_mass_times_heading,
)


class TestParseTime:
    """Test individual time parsing."""

    def test_standard_colon_am(self):
        t = parse_time("9:30am")
        assert t.formatted == "9:30 AM"

    def test_standard_colon_pm(self):
        t = parse_time("6:00pm")
        assert t.formatted == "6:00 PM"

    def test_space_before_period(self):
        t = parse_time("9:30 AM")
        assert t.formatted == "9:30 AM"

    def test_dot_separator(self):
        t = parse_time("9.30am")
        assert t.formatted == "9:30 AM"

    def test_periods_in_ampm(self):
        t = parse_time("9:30 a.m.")
        assert t.formatted == "9:30 AM"

    def test_no_minutes(self):
        t = parse_time("9am")
        assert t.formatted == "9:00 AM"

    def test_no_minutes_with_space(self):
        t = parse_time("9 AM")
        assert t.formatted == "9:00 AM"

    def test_24h_morning(self):
        t = parse_time("09:30")
        assert t.formatted == "9:30 AM"

    def test_24h_afternoon(self):
        t = parse_time("17:00")
        assert t.formatted == "5:00 PM"

    def test_24h_noon(self):
        t = parse_time("12:00")
        assert t.formatted == "12:00 PM"

    def test_24h_midnight(self):
        t = parse_time("00:00")
        assert t.formatted == "12:00 AM"

    def test_12pm(self):
        t = parse_time("12:00pm")
        assert t.formatted == "12:00 PM"

    def test_12am(self):
        t = parse_time("12:00am")
        assert t.formatted == "12:00 AM"

    def test_uppercase(self):
        t = parse_time("9:30 PM")
        assert t.formatted == "9:30 PM"

    def test_no_match(self):
        assert parse_time("hello") is None

    def test_no_match_random_numbers(self):
        assert parse_time("page 45") is None

    def test_sort_key_ordering(self):
        t1 = parse_time("8:00am")
        t2 = parse_time("10:00am")
        t3 = parse_time("6:00pm")
        assert t1.sort_key < t2.sort_key < t3.sort_key


class TestFindTimes:
    """Test finding multiple times in text."""

    def test_multiple_times_in_line(self):
        times = find_times("8:00 AM, 10:00 AM, 5:30 PM")
        assert len(times) == 3
        assert times[0].formatted == "8:00 AM"
        assert times[1].formatted == "10:00 AM"
        assert times[2].formatted == "5:30 PM"

    def test_mixed_formats(self):
        times = find_times("Mass at 9:30am and 6pm")
        assert len(times) == 2
        assert times[0].formatted == "9:30 AM"
        assert times[1].formatted == "6:00 PM"

    def test_deduplication(self):
        times = find_times("9:30 AM ... 9:30am")
        assert len(times) == 1

    def test_sorted_output(self):
        times = find_times("6:00 PM, 8:00 AM, 10:00 AM")
        assert times[0].formatted == "8:00 AM"
        assert times[1].formatted == "10:00 AM"
        assert times[2].formatted == "6:00 PM"

    def test_no_times(self):
        assert find_times("No mass times here") == []

    def test_real_bulletin_line(self):
        times = find_times("Weekend Masses: Saturday 6:00pm (Vigil), Sunday 8:00am, 10:00am & 5:30pm")
        assert len(times) == 4


class TestNormaliseDay:
    """Test day name normalisation."""

    def test_full_name(self):
        assert normalise_day("Monday") == "Monday"

    def test_lowercase(self):
        assert normalise_day("monday") == "Monday"

    def test_abbreviation(self):
        assert normalise_day("Mon") == "Monday"

    def test_abbreviation_with_dot(self):
        assert normalise_day("Mon.") == "Monday"

    def test_all_days(self):
        for day in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]:
            assert normalise_day(day) == day

    def test_invalid(self):
        assert normalise_day("Funday") is None


class TestExpandDayRange:
    """Test day range expansion."""

    def test_monday_to_friday(self):
        result = expand_day_range("Monday", "Friday")
        assert result == ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

    def test_saturday_to_sunday(self):
        result = expand_day_range("Saturday", "Sunday")
        assert result == ["Saturday", "Sunday"]

    def test_single_day(self):
        result = expand_day_range("Wednesday", "Wednesday")
        assert result == ["Wednesday"]

    def test_wrap_around(self):
        result = expand_day_range("Friday", "Monday")
        assert result == ["Friday", "Saturday", "Sunday", "Monday"]


class TestFindDays:
    """Test finding days in text."""

    def test_single_day(self):
        assert find_days("Sunday Mass") == ["Sunday"]

    def test_multiple_days(self):
        days = find_days("Saturday 6pm, Sunday 8am, 10am")
        assert "Saturday" in days
        assert "Sunday" in days

    def test_range(self):
        days = find_days("Monday-Friday: 9:15am")
        assert days == ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

    def test_weekday_keyword(self):
        days = find_days("Weekday Masses: 9:15am")
        assert days == ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

    def test_weekend_keyword(self):
        days = find_days("Weekend Masses")
        assert days == ["Saturday", "Sunday"]

    def test_no_days(self):
        assert find_days("Mass at 9:30am") == []

    def test_range_with_to(self):
        days = find_days("Monday to Friday: 9:15am")
        assert len(days) == 5
        assert days[0] == "Monday"
        assert days[-1] == "Friday"


class TestParseDayTimeBlock:
    """Test full day→time parsing from text blocks."""

    def test_simple_block(self):
        text = """
        Saturday: 6:00 PM
        Sunday: 8:00 AM, 10:00 AM, 5:30 PM
        Monday-Friday: 9:15 AM
        """
        result = parse_day_time_block(text)
        assert result["Saturday"] == ["6:00 PM"]
        assert result["Sunday"] == ["8:00 AM", "10:00 AM", "5:30 PM"]
        assert result["Monday"] == ["9:15 AM"]
        assert result["Friday"] == ["9:15 AM"]

    def test_real_parish_format(self):
        text = """
        MASS TIMES
        Saturday Vigil: 6:00pm
        Sunday: 8:00am, 10:00am, 5:30pm
        Weekday: 9:15am
        """
        result = parse_day_time_block(text)
        assert "Saturday" in result
        assert "Sunday" in result
        assert len(result["Sunday"]) == 3
        assert "Monday" in result  # From "Weekday"

    def test_empty_input(self):
        assert parse_day_time_block("") == {}

    def test_no_matching_content(self):
        assert parse_day_time_block("Parish News\nUpcoming Events") == {}

    def test_mixed_formats(self):
        text = """
        Sat 6pm
        Sun 8am, 10am, 5:30pm
        Mon-Fri 9.15am
        """
        result = parse_day_time_block(text)
        assert "Saturday" in result
        assert "Sunday" in result
        assert len(result["Sunday"]) == 3


class TestDetectChangeIndicators:
    """Test change indicator detection."""

    def test_no_mass(self):
        assert len(detect_change_indicators("No Mass this Tuesday")) > 0

    def test_cancelled(self):
        assert len(detect_change_indicators("Mass cancelled for this week")) > 0

    def test_moved(self):
        assert len(detect_change_indicators("Mass moved to 10am")) > 0

    def test_please_note(self):
        assert len(detect_change_indicators("Please note: different time")) > 0

    def test_no_indicators(self):
        assert detect_change_indicators("Regular Sunday Mass at 10am") == []

    def test_rescheduled(self):
        assert len(detect_change_indicators("Wednesday Mass rescheduled")) > 0


class TestDetectLanguage:
    """Test language detection."""

    def test_english_default(self):
        assert detect_language("Sunday Mass 10:00am") == "English"

    def test_italian(self):
        assert detect_language("Italian Mass 11:00am") == "Italian"

    def test_vietnamese(self):
        assert detect_language("Vietnamese Community Mass") == "Vietnamese"

    def test_latin(self):
        assert detect_language("Latin Mass (Extraordinary Form)") == "Latin"


class TestDetectSpecialType:
    """Test special mass type detection."""

    def test_regular(self):
        assert detect_special_type("Sunday 10:00am") == "Regular"

    def test_vigil(self):
        assert detect_special_type("Saturday Vigil 6:00pm") == "Vigil"

    def test_reconciliation(self):
        assert detect_special_type("Reconciliation Saturday 5:00pm") == "Reconciliation"

    def test_adoration(self):
        assert detect_special_type("Adoration Friday 3:00pm") == "Adoration"

    def test_latin_rite(self):
        assert detect_special_type("Latin Mass 8:00am") == "Latin Rite"

    def test_childrens_liturgy(self):
        assert detect_special_type("Children's Liturgy 10:00am") == "Children's Liturgy"


class TestHasMassTimesHeading:
    """Test mass times heading detection."""

    def test_mass_times(self):
        assert has_mass_times_heading("Mass Times")

    def test_mass_time(self):
        assert has_mass_times_heading("Mass Time")

    def test_liturgy_schedule(self):
        assert has_mass_times_heading("Liturgy Schedule")

    def test_weekend_masses(self):
        assert has_mass_times_heading("Weekend Masses")

    def test_no_heading(self):
        assert not has_mass_times_heading("Parish News")

    def test_case_insensitive(self):
        assert has_mass_times_heading("MASS TIMES")

    def test_service_times(self):
        assert has_mass_times_heading("Service Times")

    def test_mass_schedule(self):
        assert has_mass_times_heading("Mass Schedule")
