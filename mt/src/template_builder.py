"""Automated template building for mass times extraction.

Analyses parish web pages and PDF bulletins to build extraction templates
using code-based structural analysis — no LLM required.

The template builder:
1. Classifies the source type (iCal, structured data, HTML, PDF)
2. For HTML: identifies CSS selectors for mass times sections
3. For PDF: identifies bounding regions containing mass times
4. Extracts baseline times using regex parsing
5. Classifies sections as static or dynamic via multi-document diffing
"""

import json
import logging
import re
from dataclasses import dataclass, field
from datetime import datetime
from difflib import SequenceMatcher
from pathlib import Path

from bs4 import BeautifulSoup, Tag

from models import Parish, SourceEndpoint, SourceType
from parser import (
    find_times,
    find_days,
    parse_day_time_block,
    has_mass_times_heading,
    MASS_TIMES_HEADING_RE,
    detect_language,
    detect_special_type,
)
from scraper import Scraper

logger = logging.getLogger(__name__)


@dataclass
class WebTemplate:
    """Template for extracting mass times from a web page."""
    url: str = ""
    section_selector: str = ""
    fallback_selectors: list[str] = field(default_factory=list)
    time_regex: str = r'\d{1,2}[:.]\d{2}\s*[AaPp]\.?[Mm]\.?'
    day_regex: str = r'(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)'
    encoding: str = "utf-8"


@dataclass
class PdfTemplate:
    """Template for extracting mass times from a PDF bulletin."""
    bulletin_page_url: str = ""
    pdf_link_pattern: str = ""
    mass_times_page: int = 0
    bounding_region: dict = field(default_factory=lambda: {
        "x_min": 0, "y_min": 0, "x_max": 0, "y_max": 0,
    })
    heading_text: str = ""
    heading_font_size: float = 0.0
    section_static: bool = True


@dataclass
class ParishTemplate:
    """Complete extraction template for a parish."""
    parish_id: str = ""
    parish_name: str = ""
    source_priority: list[str] = field(default_factory=list)
    source_type: str = ""
    extraction_method: str = ""
    web_template: WebTemplate | None = None
    pdf_template: PdfTemplate | None = None
    baseline_times: dict[str, list[str]] = field(default_factory=dict)
    change_indicators: list[str] = field(default_factory=lambda: [
        "No Mass", "Mass cancelled", "changed to", "Note:", "Please note",
    ])
    language_markers: list[str] = field(default_factory=lambda: [
        "Italian", "Vietnamese", "Latin", "Polish",
    ])
    special_mass_markers: list[str] = field(default_factory=lambda: [
        "Vigil", "Reconciliation", "Adoration", "Latin", "Children",
    ])
    validation_rules: dict = field(default_factory=lambda: {
        "min_weekly_masses": 5,
        "max_weekly_masses": 20,
        "expected_sunday_count": 3,
        "alert_if_all_change": True,
    })
    template_version: int = 1
    created_at: str = ""
    last_validated: str = ""
    validation_accuracy: float = 0.0
    build_method: str = "automated"
    notes: str = ""

    def to_dict(self) -> dict:
        """Convert to a JSON-serialisable dict."""
        d = {
            "parish_id": self.parish_id,
            "parish_name": self.parish_name,
            "source_priority": self.source_priority,
            "source_type": self.source_type,
            "extraction_method": self.extraction_method,
            "baseline_times": self.baseline_times,
            "change_indicators": self.change_indicators,
            "language_markers": self.language_markers,
            "special_mass_markers": self.special_mass_markers,
            "validation_rules": self.validation_rules,
            "template_version": self.template_version,
            "created_at": self.created_at,
            "last_validated": self.last_validated,
            "validation_accuracy": self.validation_accuracy,
            "build_method": self.build_method,
            "notes": self.notes,
        }
        if self.web_template:
            d["web_template"] = {
                "url": self.web_template.url,
                "section_selector": self.web_template.section_selector,
                "fallback_selectors": self.web_template.fallback_selectors,
                "time_regex": self.web_template.time_regex,
                "day_regex": self.web_template.day_regex,
                "encoding": self.web_template.encoding,
            }
        if self.pdf_template:
            d["pdf_template"] = {
                "bulletin_page_url": self.pdf_template.bulletin_page_url,
                "pdf_link_pattern": self.pdf_template.pdf_link_pattern,
                "mass_times_page": self.pdf_template.mass_times_page,
                "bounding_region": self.pdf_template.bounding_region,
                "heading_text": self.pdf_template.heading_text,
                "heading_font_size": self.pdf_template.heading_font_size,
                "section_static": self.pdf_template.section_static,
            }
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "ParishTemplate":
        """Load from a JSON dict."""
        t = cls()
        for key in [
            "parish_id", "parish_name", "source_priority", "source_type",
            "extraction_method", "baseline_times", "change_indicators",
            "language_markers", "special_mass_markers", "validation_rules",
            "template_version", "created_at", "last_validated",
            "validation_accuracy", "build_method", "notes",
        ]:
            if key in d:
                setattr(t, key, d[key])

        if "web_template" in d and d["web_template"]:
            wt = WebTemplate()
            for key in ["url", "section_selector", "fallback_selectors",
                        "time_regex", "day_regex", "encoding"]:
                if key in d["web_template"]:
                    setattr(wt, key, d["web_template"][key])
            t.web_template = wt

        if "pdf_template" in d and d["pdf_template"]:
            pt = PdfTemplate()
            for key in ["bulletin_page_url", "pdf_link_pattern", "mass_times_page",
                        "bounding_region", "heading_text", "heading_font_size",
                        "section_static"]:
                if key in d["pdf_template"]:
                    setattr(pt, key, d["pdf_template"][key])
            t.pdf_template = pt

        return t


class TemplateBuilder:
    """Builds extraction templates for parishes using code-based analysis."""

    def __init__(self, scraper: Scraper | None = None, templates_dir: Path | None = None):
        self.scraper = scraper or Scraper()
        self.templates_dir = templates_dir or Path(__file__).parent.parent / "templates"

    def build_web_template(self, url: str, parish: Parish) -> ParishTemplate | None:
        """Build a template from a parish's mass times web page.

        1. Fetch the page
        2. Identify the mass times section via CSS selector heuristics
        3. Extract baseline times using regex
        """
        result = self.scraper.fetch_page(url, archive=True)
        if not result:
            logger.warning("Could not fetch %s", url)
            return None

        html, content_hash = result
        soup = BeautifulSoup(html, "html.parser")

        # Find mass times section
        section, selector, fallbacks = self._find_mass_times_section(soup)
        if not section:
            logger.warning("Could not find mass times section in %s", url)
            return None

        # Extract text and parse times
        section_text = self._extract_section_text(section)
        baseline_times = parse_day_time_block(section_text)

        if not baseline_times:
            logger.warning("No times found in mass times section of %s", url)
            return None

        template = ParishTemplate(
            parish_id=parish.id,
            parish_name=parish.name,
            source_type="website_page",
            extraction_method="css_selector_regex",
            source_priority=["website_page"],
            web_template=WebTemplate(
                url=url,
                section_selector=selector,
                fallback_selectors=fallbacks,
            ),
            baseline_times=baseline_times,
            created_at=datetime.now().isoformat(),
            last_validated=datetime.now().isoformat(),
        )

        return template

    def build_pdf_template(
        self, pdf_bytes_list: list[bytes], parish: Parish,
        bulletin_page_url: str = "", pdf_link_pattern: str = "",
    ) -> ParishTemplate | None:
        """Build a template from parish bulletin PDFs.

        1. Extract text with coordinates from each PDF
        2. Identify the mass times section via heading/keyword search
        3. Define bounding region
        4. Extract baseline times
        5. Diff across PDFs to classify as static/dynamic
        """
        if not pdf_bytes_list:
            return None

        # Analyse the first PDF for structure
        primary_pdf = pdf_bytes_list[0]
        section_info = self._find_pdf_mass_times_section(primary_pdf)

        if not section_info:
            # Fall back to full-text extraction
            full_text = self.scraper.extract_text_from_pdf(primary_pdf)
            baseline_times = parse_day_time_block(full_text)

            if not baseline_times:
                logger.warning("No times found in PDF for %s", parish.name)
                return None

            template = ParishTemplate(
                parish_id=parish.id,
                parish_name=parish.name,
                source_type="pdf_bulletin",
                extraction_method="pdf_fulltext_regex",
                source_priority=["pdf_bulletin"],
                pdf_template=PdfTemplate(
                    bulletin_page_url=bulletin_page_url,
                    pdf_link_pattern=pdf_link_pattern,
                ),
                baseline_times=baseline_times,
                created_at=datetime.now().isoformat(),
                last_validated=datetime.now().isoformat(),
            )
            return template

        page_num, region, heading_text, heading_size = section_info

        # Extract text from the region
        region_text = self.scraper.extract_text_from_region(
            primary_pdf, page_num,
            region["x_min"], region["y_min"], region["x_max"], region["y_max"],
        )
        baseline_times = parse_day_time_block(region_text)

        if not baseline_times:
            # Try full-page text as fallback
            full_text = self.scraper.extract_text_from_pdf(primary_pdf)
            baseline_times = parse_day_time_block(full_text)

        # Classify as static/dynamic by diffing across PDFs
        is_static = self._classify_static_dynamic(pdf_bytes_list, page_num, region)

        template = ParishTemplate(
            parish_id=parish.id,
            parish_name=parish.name,
            source_type="pdf_bulletin",
            extraction_method="pdf_region_regex",
            source_priority=["pdf_bulletin"],
            pdf_template=PdfTemplate(
                bulletin_page_url=bulletin_page_url,
                pdf_link_pattern=pdf_link_pattern,
                mass_times_page=page_num,
                bounding_region=region,
                heading_text=heading_text,
                heading_font_size=heading_size,
                section_static=is_static,
            ),
            baseline_times=baseline_times or {},
            created_at=datetime.now().isoformat(),
            last_validated=datetime.now().isoformat(),
        )

        return template

    def _extract_section_text(self, section: Tag) -> str:
        """Extract text from an HTML section, handling tables specially.

        For tables, joins each row's cells with spaces so day and time
        end up on the same line. For other elements, uses standard text extraction.
        """
        lines = []

        # Check if the section contains a table
        tables = section.find_all("table")
        if tables:
            for table in tables:
                for row in table.find_all("tr"):
                    cells = [td.get_text(strip=True) for td in row.find_all(["td", "th"])]
                    line = " ".join(cells)
                    if line.strip():
                        lines.append(line)

        # Also get non-table text
        for child in section.children:
            if isinstance(child, Tag) and child.name == "table":
                continue  # Already handled above
            text = child.get_text(strip=True) if isinstance(child, Tag) else str(child).strip()
            if text:
                lines.append(text)

        if not lines:
            # Fallback: standard extraction
            return section.get_text("\n", strip=True)

        return "\n".join(lines)

    def _find_mass_times_section(self, soup: BeautifulSoup) -> tuple[Tag | None, str, list[str]]:
        """Find the mass times section in an HTML page.

        Returns (element, best_selector, fallback_selectors).
        Uses a ranked list of heuristics.
        """
        candidates = []
        fallbacks = []

        # Strategy 1: Headings matching mass times patterns
        for tag in soup.find_all(["h1", "h2", "h3", "h4", "h5", "h6"]):
            text = tag.get_text(strip=True)
            if has_mass_times_heading(text):
                # The section is the heading's parent container or next siblings
                parent = tag.parent
                if parent:
                    selector = self._build_selector(parent)
                    candidates.append((parent, selector, 1))

                # Also check for content following the heading
                next_sib = tag.find_next_sibling()
                if next_sib and isinstance(next_sib, Tag):
                    selector = self._build_selector(next_sib)
                    candidates.append((next_sib, selector, 2))

        # Strategy 2: Elements with id/class containing mass/times/schedule
        for el in soup.find_all(id=re.compile(r'mass|times|schedule|liturgy', re.I)):
            selector = f"#{el.get('id')}"
            candidates.append((el, selector, 3))

        for el in soup.find_all(class_=re.compile(r'mass|times|schedule|liturgy', re.I)):
            classes = el.get("class", [])
            for cls in classes:
                if re.search(r'mass|times|schedule|liturgy', cls, re.I):
                    selector = f".{cls}"
                    candidates.append((el, selector, 4))
                    break

        # Strategy 3: Tables containing day names and time patterns
        for table in soup.find_all("table"):
            text = table.get_text(" ", strip=True)
            if find_days(text) and find_times(text):
                selector = self._build_selector(table)
                candidates.append((table, selector, 5))

        # Strategy 4: Lists containing time patterns
        for ul in soup.find_all(["ul", "ol"]):
            text = ul.get_text(" ", strip=True)
            if find_times(text) and (find_days(text) or has_mass_times_heading(text)):
                selector = self._build_selector(ul)
                candidates.append((ul, selector, 6))

        if not candidates:
            return None, "", []

        # Sort by priority (lower = better) and pick the best
        candidates.sort(key=lambda c: c[2])
        best = candidates[0]
        fallbacks = [c[1] for c in candidates[1:4]]

        return best[0], best[1], fallbacks

    def _build_selector(self, element: Tag) -> str:
        """Build a CSS selector for an element.

        Prefers id-based, then class-based, then tag-based.
        """
        if element.get("id"):
            return f"#{element['id']}"

        classes = element.get("class", [])
        if classes:
            # Use the most specific class
            return f"{element.name}.{'.'.join(classes)}"

        # Fall back to tag with parent context
        parent = element.parent
        if parent and parent.name != "[document]":
            parent_selector = ""
            if parent.get("id"):
                parent_selector = f"#{parent['id']}"
            elif parent.get("class"):
                parent_selector = f"{parent.name}.{'.'.join(parent['class'])}"
            else:
                parent_selector = parent.name

            return f"{parent_selector} > {element.name}"

        return element.name

    def _find_pdf_mass_times_section(self, pdf_bytes: bytes) -> tuple[int, dict, str, float] | None:
        """Find the mass times section in a PDF.

        Returns (page_num, bounding_region, heading_text, heading_font_size) or None.
        """
        elements = self.scraper.extract_text_with_coords(pdf_bytes)
        if not elements:
            return None

        # Group characters into lines by proximity
        lines = self._group_chars_to_lines(elements)

        # Search for mass times heading
        for line in lines:
            text = line["text"]
            if has_mass_times_heading(text):
                page = line["page"]

                # Find all subsequent lines on the same page that contain
                # time or day patterns, to define the bounding region
                region_lines = [line]
                for other_line in lines:
                    if other_line["page"] != page:
                        continue
                    if other_line["y0"] <= line["y0"]:
                        continue  # Above the heading
                    # Check if this line has times or days
                    if find_times(other_line["text"]) or find_days(other_line["text"]):
                        region_lines.append(other_line)
                    # Stop if we hit another section heading (non-mass-times heading with large font)
                    elif other_line["size"] >= line["size"] * 0.9 and len(other_line["text"]) > 3:
                        if not has_mass_times_heading(other_line["text"]) and not find_times(other_line["text"]):
                            break

                if len(region_lines) < 2:
                    continue  # Just a heading with no content

                # Calculate bounding region with 20pt margin
                margin = 20.0
                x_min = min(l["x0"] for l in region_lines) - margin
                y_min = min(l["y0"] for l in region_lines) - margin
                x_max = max(l["x1"] for l in region_lines) + margin
                y_max = max(l["y1"] for l in region_lines) + margin

                return page, {
                    "x_min": max(0, x_min),
                    "y_min": max(0, y_min),
                    "x_max": x_max,
                    "y_max": y_max,
                }, text, line["size"]

        return None

    def _group_chars_to_lines(self, elements: list[dict]) -> list[dict]:
        """Group character elements into text lines by vertical proximity."""
        if not elements:
            return []

        # Sort by page, then y position, then x position
        elements.sort(key=lambda e: (e["page"], e["y0"], e["x0"]))

        lines = []
        current_line = {
            "page": elements[0]["page"],
            "x0": elements[0]["x0"],
            "y0": elements[0]["y0"],
            "x1": elements[0]["x1"],
            "y1": elements[0]["y1"],
            "text": elements[0]["text"],
            "size": elements[0]["size"],
        }

        for el in elements[1:]:
            # Same line if similar y position (within 3pt) and same page
            if (el["page"] == current_line["page"]
                    and abs(el["y0"] - current_line["y0"]) < 3):
                current_line["text"] += el["text"]
                current_line["x1"] = max(current_line["x1"], el["x1"])
                current_line["y1"] = max(current_line["y1"], el["y1"])
                current_line["size"] = max(current_line["size"], el["size"])
            else:
                if current_line["text"].strip():
                    lines.append(current_line)
                current_line = {
                    "page": el["page"],
                    "x0": el["x0"],
                    "y0": el["y0"],
                    "x1": el["x1"],
                    "y1": el["y1"],
                    "text": el["text"],
                    "size": el["size"],
                }

        if current_line["text"].strip():
            lines.append(current_line)

        return lines

    def _classify_static_dynamic(
        self, pdf_bytes_list: list[bytes], page_num: int, region: dict,
    ) -> bool:
        """Classify a section as static or dynamic by diffing across multiple PDFs.

        Returns True if section is static (same content across PDFs).
        """
        if len(pdf_bytes_list) < 2:
            return True  # Can't determine, assume static

        texts = []
        for pdf_bytes in pdf_bytes_list:
            text = self.scraper.extract_text_from_region(
                pdf_bytes, page_num,
                region["x_min"], region["y_min"], region["x_max"], region["y_max"],
            )
            texts.append(text.strip())

        if not texts:
            return True

        # Compare all pairs — if all are > 95% similar, it's static
        for i in range(len(texts)):
            for j in range(i + 1, len(texts)):
                ratio = SequenceMatcher(None, texts[i], texts[j]).ratio()
                if ratio < 0.95:
                    return False

        return True

    def save_template(self, template: ParishTemplate):
        """Save a template to a JSON file."""
        self.templates_dir.mkdir(parents=True, exist_ok=True)
        path = self.templates_dir / f"{template.parish_id}.json"
        with open(path, "w") as f:
            json.dump(template.to_dict(), f, indent=2)
        logger.info("Template saved: %s", path)

    def load_template(self, parish_id: str) -> ParishTemplate | None:
        """Load a template from a JSON file."""
        path = self.templates_dir / f"{parish_id}.json"
        if not path.exists():
            return None
        with open(path) as f:
            return ParishTemplate.from_dict(json.load(f))
