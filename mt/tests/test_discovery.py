"""Tests for the parish discovery module."""

import json
import pytest
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from discovery import (
    haversine_km,
    slug_from_name,
    ParishDiscovery,
    DiscoveryResult,
)
from models import Parish, SourceEndpoint, SourceType


class TestHaversine:
    """Test Haversine distance calculation."""

    def test_same_point(self):
        assert haversine_km(-37.8131, 145.2285, -37.8131, 145.2285) == 0.0

    def test_ringwood_to_melbourne_cbd(self):
        # Ringwood to Melbourne CBD is roughly 25km
        dist = haversine_km(-37.8131, 145.2285, -37.8136, 144.9631)
        assert 23 < dist < 27

    def test_short_distance(self):
        # Two points ~1km apart
        dist = haversine_km(-37.8131, 145.2285, -37.8220, 145.2285)
        assert 0.5 < dist < 1.5

    def test_symmetry(self):
        d1 = haversine_km(-37.8131, 145.2285, -37.9, 145.3)
        d2 = haversine_km(-37.9, 145.3, -37.8131, 145.2285)
        assert abs(d1 - d2) < 0.001


class TestSlugFromName:
    """Test parish name to slug conversion."""

    def test_basic(self):
        assert slug_from_name("Sacred Heart") == "sacred-heart"

    def test_with_parish(self):
        assert slug_from_name("Sacred Heart Parish") == "sacred-heart"

    def test_with_location(self):
        slug = slug_from_name("Sacred Heart Parish, Croydon")
        assert slug == "sacred-heart-croydon"

    def test_with_catholic(self):
        assert slug_from_name("Sacred Heart Catholic Church") == "sacred-heart"

    def test_special_characters(self):
        assert slug_from_name("St. Mary's") == "st-marys"

    def test_multiple_spaces(self):
        assert slug_from_name("Our   Lady   of   Lourdes") == "our-lady-of-lourdes"

    def test_our_lady(self):
        slug = slug_from_name("Our Lady of Perpetual Help Parish, Ringwood")
        assert "our-lady" in slug
        assert "ringwood" in slug


class TestParishDedup:
    """Test parish deduplication."""

    def test_same_name(self):
        discovery = ParishDiscovery()
        parishes = [
            Parish(id="sacred-heart", name="Sacred Heart"),
            Parish(id="sacred-heart", name="Sacred Heart"),
        ]
        result = discovery.deduplicate(parishes)
        assert len(result) == 1

    def test_different_names(self):
        discovery = ParishDiscovery()
        parishes = [
            Parish(id="sacred-heart", name="Sacred Heart"),
            Parish(id="our-lady", name="Our Lady"),
        ]
        result = discovery.deduplicate(parishes)
        assert len(result) == 2

    def test_close_proximity(self):
        discovery = ParishDiscovery()
        parishes = [
            Parish(id="church-a", name="Church A", lat=-37.8131, lng=145.2285),
            Parish(id="church-b", name="Church B", lat=-37.8132, lng=145.2285),  # ~11m away
        ]
        result = discovery.deduplicate(parishes)
        assert len(result) == 1

    def test_far_apart(self):
        discovery = ParishDiscovery()
        parishes = [
            Parish(id="church-a", name="Church A", lat=-37.8131, lng=145.2285),
            Parish(id="church-b", name="Church B", lat=-37.9, lng=145.3),
        ]
        result = discovery.deduplicate(parishes)
        assert len(result) == 2

    def test_merge_metadata(self):
        discovery = ParishDiscovery()
        parishes = [
            Parish(id="sacred-heart", name="Sacred Heart", website="https://example.com"),
            Parish(id="sacred-heart", name="Sacred Heart", phone="123456"),
        ]
        result = discovery.deduplicate(parishes)
        assert len(result) == 1
        assert result[0].website == "https://example.com"
        assert result[0].phone == "123456"


class TestSourceDiscovery:
    """Test source endpoint discovery from parish websites."""

    def _make_html(self, body: str) -> str:
        return f"<html><head></head><body>{body}</body></html>"

    def test_finds_mass_times_link(self):
        html = self._make_html('''
            <a href="/mass-times">Mass Times</a>
            <a href="/about">About</a>
        ''')

        discovery = ParishDiscovery()
        with patch.object(discovery, '_fetch') as mock_fetch:
            mock_resp = MagicMock()
            mock_resp.text = html
            mock_fetch.return_value = mock_resp

            parish = Parish(id="test", name="Test", website="https://example.com")
            endpoints = discovery.discover_sources(parish)

            web_pages = [e for e in endpoints if e.source_type == SourceType.WEBSITE_PAGE]
            assert len(web_pages) >= 1
            assert "mass-times" in web_pages[0].url

    def test_finds_ical_link(self):
        html = '<html><head><link rel="alternate" type="text/calendar" href="/cal.ics"></head><body></body></html>'

        discovery = ParishDiscovery()
        with patch.object(discovery, '_fetch') as mock_fetch:
            mock_resp = MagicMock()
            mock_resp.text = html
            mock_fetch.return_value = mock_resp

            parish = Parish(id="test", name="Test", website="https://example.com")
            endpoints = discovery.discover_sources(parish)

            ical = [e for e in endpoints if e.source_type == SourceType.ICAL_FEED]
            assert len(ical) >= 1

    def test_finds_bulletin_pdf(self):
        html = self._make_html('''
            <a href="/files/bulletin-2026-02-09.pdf">This Week's Bulletin</a>
        ''')

        discovery = ParishDiscovery()
        with patch.object(discovery, '_fetch') as mock_fetch:
            mock_resp = MagicMock()
            mock_resp.text = html
            mock_fetch.return_value = mock_resp

            parish = Parish(id="test", name="Test", website="https://example.com")
            endpoints = discovery.discover_sources(parish)

            pdfs = [e for e in endpoints if e.source_type == SourceType.PDF_BULLETIN]
            assert len(pdfs) >= 1

    def test_finds_json_ld_church(self):
        html = '''<html><head>
            <script type="application/ld+json">
            {"@type": "Church", "name": "Test Parish"}
            </script>
        </head><body></body></html>'''

        discovery = ParishDiscovery()
        with patch.object(discovery, '_fetch') as mock_fetch:
            mock_resp = MagicMock()
            mock_resp.text = html
            mock_fetch.return_value = mock_resp

            parish = Parish(id="test", name="Test", website="https://example.com")
            endpoints = discovery.discover_sources(parish)

            structured = [e for e in endpoints if e.source_type == SourceType.STRUCTURED_DATA]
            assert len(structured) >= 1

    def test_no_website(self):
        discovery = ParishDiscovery()
        parish = Parish(id="test", name="Test", website="")
        endpoints = discovery.discover_sources(parish)
        assert endpoints == []

    def test_sets_primary(self):
        html = self._make_html('''
            <a href="/mass-times">Mass Times</a>
        ''')

        discovery = ParishDiscovery()
        with patch.object(discovery, '_fetch') as mock_fetch:
            mock_resp = MagicMock()
            mock_resp.text = html
            mock_fetch.return_value = mock_resp

            parish = Parish(id="test", name="Test", website="https://example.com")
            endpoints = discovery.discover_sources(parish)

            assert any(e.is_primary for e in endpoints)


class TestSaveResults:
    """Test saving discovery results to JSON."""

    def test_save_and_load(self, tmp_path):
        discovery = ParishDiscovery()
        result = DiscoveryResult(
            parishes=[
                Parish(id="test", name="Test Parish", lat=-37.8, lng=145.2, distance_km=5.0),
            ],
            endpoints=[
                SourceEndpoint(
                    parish_id="test",
                    source_type=SourceType.WEBSITE_PAGE,
                    url="https://example.com/mass-times",
                    is_primary=True,
                ),
            ],
            errors=["Test error"],
        )

        discovery.save_results(result, tmp_path)

        assert (tmp_path / "parishes.json").exists()
        assert (tmp_path / "endpoints.json").exists()
        assert (tmp_path / "discovery_errors.json").exists()

        parishes = json.loads((tmp_path / "parishes.json").read_text())
        assert len(parishes) == 1
        assert parishes[0]["name"] == "Test Parish"

        endpoints = json.loads((tmp_path / "endpoints.json").read_text())
        assert len(endpoints) == 1
        assert endpoints[0]["source_type"] == "website_page"
