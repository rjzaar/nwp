"""Tests for the extraction pipeline."""

import pytest
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from extractor import Extractor
from validator import validate_extraction, cross_reference
from template_builder import ParishTemplate, WebTemplate, PdfTemplate
from models import (
    ExtractionResult, ExtractionTier, MassTime,
    SourceType, ValidationStatus,
)


def make_template(**kwargs) -> ParishTemplate:
    """Create a test template with defaults."""
    defaults = {
        "parish_id": "test-parish",
        "parish_name": "Test Parish",
        "source_type": "website_page",
        "extraction_method": "css_selector_regex",
        "baseline_times": {
            "Saturday": ["6:00 PM"],
            "Sunday": ["8:00 AM", "10:00 AM", "5:30 PM"],
            "Monday": ["9:15 AM"],
            "Tuesday": ["9:15 AM"],
            "Wednesday": ["9:15 AM"],
            "Thursday": ["9:15 AM"],
            "Friday": ["9:15 AM"],
        },
        "validation_rules": {
            "min_weekly_masses": 5,
            "max_weekly_masses": 20,
            "expected_sunday_count": 3,
            "alert_if_all_change": True,
        },
    }
    defaults.update(kwargs)
    return ParishTemplate(**defaults)


class TestTier1Static:
    """Test Tier 1 static confirmation."""

    def test_confirms_when_no_changes(self):
        extractor = Extractor()
        template = make_template()

        # Text with no change indicators
        text = "Saturday: 6:00 PM\nSunday: 8:00 AM, 10:00 AM, 5:30 PM"

        result = extractor._tier1_static(template, text)
        assert result is not None
        assert len(result) == 9  # 1 Sat + 3 Sun + 5 weekdays (Mon-Fri separate)

    def test_escalates_on_change_indicator(self):
        extractor = Extractor()
        template = make_template()

        text = "No Mass this Tuesday due to maintenance"
        result = extractor._tier1_static(template, text)
        assert result is None  # Should escalate

    def test_escalates_when_no_baseline(self):
        extractor = Extractor()
        template = make_template(baseline_times={})

        result = extractor._tier1_static(template, "Saturday: 6:00 PM")
        assert result is None

    def test_escalates_for_dynamic_pdf(self):
        extractor = Extractor()
        template = make_template(
            source_type="pdf_bulletin",
        )
        template.pdf_template = PdfTemplate(section_static=False)

        result = extractor._tier1_static(template, "Saturday: 6:00 PM")
        assert result is None


class TestTier2Code:
    """Test Tier 2 code-based extraction."""

    def test_extracts_from_simple_text(self):
        extractor = Extractor()
        template = make_template()

        text = """
        Saturday: 6:00 PM
        Sunday: 8:00 AM, 10:00 AM, 5:30 PM
        Monday-Friday: 9:15 AM
        """

        result = extractor._tier2_code(template, text)
        assert result is not None
        assert len(result) >= 8

        days = {t.day for t in result}
        assert "Saturday" in days
        assert "Sunday" in days
        assert "Monday" in days

    def test_detects_vigil_mass(self):
        extractor = Extractor()
        template = make_template(validation_rules={"min_weekly_masses": 1, "max_weekly_masses": 20})

        text = "Saturday Vigil: 6:00 PM\nSunday: 10:00 AM"
        result = extractor._tier2_code(template, text)
        assert result is not None

        saturday = [t for t in result if t.day == "Saturday"]
        assert len(saturday) >= 1

    def test_detects_language(self):
        extractor = Extractor()
        template = make_template()

        text = "Sunday: 10:00 AM\nSunday Italian Mass: 11:30 AM\nMonday: 9:00 AM\nTuesday: 9:00 AM\nWednesday: 9:00 AM\nThursday: 9:00 AM\nFriday: 9:00 AM"
        result = extractor._tier2_code(template, text)
        assert result is not None

        italian = [t for t in result if t.language == "Italian"]
        assert len(italian) >= 1

    def test_returns_none_when_too_few(self):
        extractor = Extractor()
        template = make_template()

        text = "Sunday: 10:00 AM"
        result = extractor._tier2_code(template, text)
        assert result is None  # Only 1 time, min is 5

    def test_returns_none_for_no_content(self):
        extractor = Extractor()
        template = make_template()

        result = extractor._tier2_code(template, "Welcome to our parish")
        assert result is None


class TestFullExtraction:
    """Test the full extraction pipeline."""

    def test_tier1_success(self):
        extractor = Extractor()
        template = make_template()
        template.web_template = WebTemplate(
            url="https://example.com/mass-times",
            section_selector="#mass-times",
        )

        html = """<html><body>
            <div id="mass-times">
                <p>Saturday: 6:00 PM</p>
                <p>Sunday: 8:00 AM, 10:00 AM, 5:30 PM</p>
            </div>
        </body></html>"""

        with patch.object(extractor.scraper, 'fetch_page') as mock_fetch:
            mock_fetch.return_value = (html, "abc123")
            result = extractor.extract(template)

        assert result.tier == ExtractionTier.TIER1_STATIC
        assert result.confidence == 1.0
        assert len(result.times) > 0

    def test_tier2_on_change_indicator(self):
        extractor = Extractor()
        template = make_template()
        template.web_template = WebTemplate(
            url="https://example.com/mass-times",
            section_selector="#mass-times",
        )

        html = """<html><body>
            <div id="mass-times">
                <p>Note: No 7am Mass this week</p>
                <p>Saturday: 6:00 PM</p>
                <p>Sunday: 8:00 AM, 10:00 AM, 5:30 PM</p>
                <p>Monday-Friday: 9:15 AM</p>
            </div>
        </body></html>"""

        with patch.object(extractor.scraper, 'fetch_page') as mock_fetch:
            mock_fetch.return_value = (html, "abc123")
            result = extractor.extract(template)

        assert result.tier == ExtractionTier.TIER2_CODE
        assert len(result.times) >= 5

    def test_flagged_when_all_fail(self):
        extractor = Extractor()
        template = make_template(baseline_times={})
        template.web_template = WebTemplate(
            url="https://example.com",
            section_selector="#mass-times",
        )

        html = "<html><body><div id='mass-times'>No content</div></body></html>"

        with patch.object(extractor.scraper, 'fetch_page') as mock_fetch:
            mock_fetch.return_value = (html, "abc123")
            result = extractor.extract(template)

        assert result.validation_status == ValidationStatus.FLAGGED
        assert result.confidence == 0.0


class TestValidation:
    """Test extraction validation."""

    def _make_times(self, day_time_pairs):
        return [MassTime(day=d, time=t) for d, t in day_time_pairs]

    def test_valid_extraction(self):
        result = ExtractionResult(
            parish_id="test",
            times=self._make_times([
                ("Saturday", "6:00 PM"),
                ("Sunday", "8:00 AM"), ("Sunday", "10:00 AM"), ("Sunday", "5:30 PM"),
                ("Monday", "9:15 AM"), ("Tuesday", "9:15 AM"),
                ("Wednesday", "9:15 AM"), ("Thursday", "9:15 AM"), ("Friday", "9:15 AM"),
            ]),
            confidence=0.85,
        )

        rules = {"min_weekly_masses": 5, "max_weekly_masses": 20, "expected_sunday_count": 3}
        validated = validate_extraction(result, rules)
        assert validated.validation_status == ValidationStatus.CONFIRMED

    def test_too_few_masses(self):
        result = ExtractionResult(
            parish_id="test",
            times=self._make_times([("Sunday", "10:00 AM")]),
            confidence=0.85,
        )

        rules = {"min_weekly_masses": 5}
        validated = validate_extraction(result, rules)
        assert validated.validation_status == ValidationStatus.FLAGGED

    def test_no_sunday_masses(self):
        result = ExtractionResult(
            parish_id="test",
            times=self._make_times([
                ("Monday", "9:15 AM"), ("Tuesday", "9:15 AM"),
                ("Wednesday", "9:15 AM"), ("Thursday", "9:15 AM"), ("Friday", "9:15 AM"),
            ]),
            confidence=0.85,
        )

        rules = {"min_weekly_masses": 5, "expected_sunday_count": 3}
        validated = validate_extraction(result, rules)
        assert validated.validation_status == ValidationStatus.FLAGGED

    def test_large_change_flagged(self):
        result = ExtractionResult(
            parish_id="test",
            times=self._make_times([
                ("Saturday", "5:00 PM"),
                ("Sunday", "9:00 AM"), ("Sunday", "11:00 AM"),
                ("Monday", "8:00 AM"), ("Tuesday", "8:00 AM"), ("Wednesday", "8:00 AM"),
            ]),
            confidence=0.85,
        )

        previous = self._make_times([
            ("Saturday", "6:00 PM"),
            ("Sunday", "8:00 AM"), ("Sunday", "10:00 AM"), ("Sunday", "5:30 PM"),
            ("Monday", "9:15 AM"), ("Tuesday", "9:15 AM"),
        ])

        rules = {"min_weekly_masses": 5, "alert_if_all_change": True}
        validated = validate_extraction(result, rules, previous)
        assert validated.validation_status == ValidationStatus.FLAGGED

    def test_empty_extraction_flagged(self):
        result = ExtractionResult(parish_id="test", times=[])
        validated = validate_extraction(result, {})
        assert validated.validation_status == ValidationStatus.FLAGGED


class TestCrossReference:
    """Test cross-referencing multiple sources."""

    def _make_result(self, source_type, times, confidence=0.85):
        return ExtractionResult(
            parish_id="test",
            times=[MassTime(day=d, time=t) for d, t in times],
            source_type=SourceType(source_type),
            confidence=confidence,
        )

    def test_single_result(self):
        r = self._make_result("website_page", [("Sunday", "10:00 AM")])
        best = cross_reference([r])
        assert best is r

    def test_prefers_ical(self):
        r1 = self._make_result("ical_feed", [("Sunday", "10:00 AM")])
        r2 = self._make_result("website_page", [("Sunday", "10:00 AM")])
        best = cross_reference([r2, r1])
        assert best.source_type == SourceType.ICAL_FEED

    def test_agreement_boosts_confidence(self):
        r1 = self._make_result("website_page", [
            ("Sunday", "10:00 AM"), ("Saturday", "6:00 PM"),
        ], confidence=0.85)
        r2 = self._make_result("pdf_bulletin", [
            ("Sunday", "10:00 AM"), ("Saturday", "6:00 PM"),
        ], confidence=0.8)

        best = cross_reference([r1, r2])
        assert best.confidence >= 0.9
        assert best.validation_status == ValidationStatus.CONFIRMED

    def test_empty_list(self):
        assert cross_reference([]) is None
