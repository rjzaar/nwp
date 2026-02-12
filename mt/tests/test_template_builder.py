"""Tests for the template builder module."""

import json
import pytest
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from template_builder import (
    TemplateBuilder,
    ParishTemplate,
    WebTemplate,
    PdfTemplate,
)
from models import Parish


def make_html(body: str, head: str = "") -> str:
    return f"<html><head>{head}</head><body>{body}</body></html>"


class TestWebTemplateBuilding:
    """Test building templates from web pages."""

    def test_finds_section_by_heading(self):
        html = make_html('''
            <div id="content">
                <h2>Mass Times</h2>
                <p>Saturday: 6:00 PM</p>
                <p>Sunday: 8:00 AM, 10:00 AM, 5:30 PM</p>
                <p>Monday-Friday: 9:15 AM</p>
            </div>
        ''')

        builder = TemplateBuilder()
        with patch.object(builder.scraper, 'fetch_page') as mock_fetch:
            mock_fetch.return_value = (html, "abc123")
            parish = Parish(id="test-parish", name="Test Parish")
            template = builder.build_web_template("https://example.com/mass-times", parish)

        assert template is not None
        assert template.parish_id == "test-parish"
        assert template.extraction_method == "css_selector_regex"
        assert "Saturday" in template.baseline_times
        assert "Sunday" in template.baseline_times
        assert len(template.baseline_times["Sunday"]) == 3

    def test_finds_section_by_id(self):
        html = make_html('''
            <div id="mass-times">
                <p>Saturday: 6:00 PM</p>
                <p>Sunday: 10:00 AM</p>
            </div>
        ''')

        builder = TemplateBuilder()
        with patch.object(builder.scraper, 'fetch_page') as mock_fetch:
            mock_fetch.return_value = (html, "abc123")
            parish = Parish(id="test", name="Test")
            template = builder.build_web_template("https://example.com", parish)

        assert template is not None
        assert template.web_template.section_selector == "#mass-times"

    def test_finds_section_by_class(self):
        html = make_html('''
            <div class="liturgy-schedule">
                <p>Saturday: 6:00 PM</p>
                <p>Sunday: 10:00 AM</p>
            </div>
        ''')

        builder = TemplateBuilder()
        with patch.object(builder.scraper, 'fetch_page') as mock_fetch:
            mock_fetch.return_value = (html, "abc123")
            parish = Parish(id="test", name="Test")
            template = builder.build_web_template("https://example.com", parish)

        assert template is not None

    def test_finds_table_with_times(self):
        html = make_html('''
            <table>
                <tr><td>Saturday</td><td>6:00 PM</td></tr>
                <tr><td>Sunday</td><td>8:00 AM</td><td>10:00 AM</td></tr>
            </table>
        ''')

        builder = TemplateBuilder()
        with patch.object(builder.scraper, 'fetch_page') as mock_fetch:
            mock_fetch.return_value = (html, "abc123")
            parish = Parish(id="test", name="Test")
            template = builder.build_web_template("https://example.com", parish)

        assert template is not None
        assert "Saturday" in template.baseline_times

    def test_returns_none_for_no_section(self):
        html = make_html('<p>Welcome to our parish</p>')

        builder = TemplateBuilder()
        with patch.object(builder.scraper, 'fetch_page') as mock_fetch:
            mock_fetch.return_value = (html, "abc123")
            parish = Parish(id="test", name="Test")
            template = builder.build_web_template("https://example.com", parish)

        assert template is None

    def test_returns_none_for_fetch_failure(self):
        builder = TemplateBuilder()
        with patch.object(builder.scraper, 'fetch_page') as mock_fetch:
            mock_fetch.return_value = None
            parish = Parish(id="test", name="Test")
            template = builder.build_web_template("https://example.com", parish)

        assert template is None


class TestTemplateSerialization:
    """Test template JSON serialization/deserialization."""

    def test_round_trip(self, tmp_path):
        template = ParishTemplate(
            parish_id="sacred-heart-croydon",
            parish_name="Sacred Heart Parish, Croydon",
            source_type="website_page",
            extraction_method="css_selector_regex",
            source_priority=["website_page", "pdf_bulletin"],
            web_template=WebTemplate(
                url="https://example.com/mass-times",
                section_selector="#mass-times",
                fallback_selectors=[".content", "article"],
            ),
            baseline_times={
                "Saturday": ["6:00 PM"],
                "Sunday": ["8:00 AM", "10:00 AM", "5:30 PM"],
                "Monday": ["9:15 AM"],
            },
            created_at="2026-02-10T00:00:00",
            validation_accuracy=0.95,
        )

        builder = TemplateBuilder(templates_dir=tmp_path)
        builder.save_template(template)

        loaded = builder.load_template("sacred-heart-croydon")
        assert loaded is not None
        assert loaded.parish_id == "sacred-heart-croydon"
        assert loaded.baseline_times["Sunday"] == ["8:00 AM", "10:00 AM", "5:30 PM"]
        assert loaded.web_template.section_selector == "#mass-times"
        assert loaded.web_template.fallback_selectors == [".content", "article"]

    def test_round_trip_pdf_template(self, tmp_path):
        template = ParishTemplate(
            parish_id="our-lady-ringwood",
            parish_name="Our Lady, Ringwood",
            source_type="pdf_bulletin",
            extraction_method="pdf_region_regex",
            pdf_template=PdfTemplate(
                bulletin_page_url="https://example.com/bulletin",
                mass_times_page=0,
                bounding_region={"x_min": 350, "y_min": 100, "x_max": 580, "y_max": 400},
                section_static=True,
            ),
            baseline_times={"Sunday": ["10:00 AM"]},
        )

        builder = TemplateBuilder(templates_dir=tmp_path)
        builder.save_template(template)

        loaded = builder.load_template("our-lady-ringwood")
        assert loaded is not None
        assert loaded.pdf_template.mass_times_page == 0
        assert loaded.pdf_template.bounding_region["x_min"] == 350
        assert loaded.pdf_template.section_static is True

    def test_load_nonexistent(self, tmp_path):
        builder = TemplateBuilder(templates_dir=tmp_path)
        assert builder.load_template("nonexistent") is None

    def test_to_dict_without_templates(self):
        template = ParishTemplate(parish_id="test", parish_name="Test")
        d = template.to_dict()
        assert "web_template" not in d
        assert "pdf_template" not in d
        assert d["parish_id"] == "test"


class TestStaticDynamicClassification:
    """Test static/dynamic section classification."""

    def test_identical_texts_are_static(self):
        builder = TemplateBuilder()

        # Mock the scraper's extract_text_from_region to return identical text
        with patch.object(builder.scraper, 'extract_text_from_region') as mock:
            mock.return_value = "Saturday: 6:00 PM\nSunday: 10:00 AM"

            result = builder._classify_static_dynamic(
                [b"pdf1", b"pdf2", b"pdf3"],
                page_num=0,
                region={"x_min": 0, "y_min": 0, "x_max": 100, "y_max": 100},
            )
            assert result is True

    def test_different_texts_are_dynamic(self):
        builder = TemplateBuilder()

        texts = [
            "Saturday: 6:00 PM\nSunday: 10:00 AM",
            "Saturday: 6:00 PM\nSunday: 9:00 AM\nNote: No 10am Mass this week",
            "Saturday: 6:00 PM\nSunday: 10:00 AM, 5:00 PM",
        ]

        with patch.object(builder.scraper, 'extract_text_from_region') as mock:
            mock.side_effect = texts

            result = builder._classify_static_dynamic(
                [b"pdf1", b"pdf2", b"pdf3"],
                page_num=0,
                region={"x_min": 0, "y_min": 0, "x_max": 100, "y_max": 100},
            )
            assert result is False

    def test_single_pdf_defaults_to_static(self):
        builder = TemplateBuilder()
        result = builder._classify_static_dynamic(
            [b"pdf1"], page_num=0,
            region={"x_min": 0, "y_min": 0, "x_max": 100, "y_max": 100},
        )
        assert result is True
