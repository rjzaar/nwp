"""Three-tier extraction engine for mass times.

Tier 1: Static confirmation — compare against baseline, check for change indicators.
Tier 2: Code-based template extraction — CSS selectors, regex, PDF regions.
Tier 3: LLM fallback — send text to Claude Sonnet (rare).
"""

import hashlib
import json
import logging
import re
from datetime import datetime
from difflib import SequenceMatcher
from pathlib import Path

from bs4 import BeautifulSoup

from models import (
    ExtractionResult, ExtractionTier, MassTime, SourceType, ValidationStatus,
)
from parser import (
    find_times, find_days, parse_day_time_block,
    detect_change_indicators, detect_language, detect_special_type,
)
from scraper import Scraper
from template_builder import ParishTemplate, TemplateBuilder

logger = logging.getLogger(__name__)


class Extractor:
    """Three-tier mass times extractor."""

    def __init__(
        self,
        scraper: Scraper | None = None,
        templates_dir: Path | None = None,
        claude_api_key: str = "",
        fallback_model: str = "claude-sonnet-4-5",
    ):
        self.scraper = scraper or Scraper()
        self.templates_dir = templates_dir or Path(__file__).parent.parent / "templates"
        self.claude_api_key = claude_api_key
        self.fallback_model = fallback_model

    def extract(self, template: ParishTemplate, dry_run: bool = False) -> ExtractionResult:
        """Run the three-tier extraction pipeline for a parish.

        Tries Tier 1 first, escalates to Tier 2, then Tier 3 if needed.
        """
        result = ExtractionResult(
            parish_id=template.parish_id,
            source_type=SourceType(template.source_type) if template.source_type else SourceType.WEBSITE_PAGE,
        )

        # Determine source URL
        source_url = ""
        if template.web_template:
            source_url = template.web_template.url
        elif template.pdf_template and template.pdf_template.bulletin_page_url:
            source_url = template.pdf_template.bulletin_page_url
        result.source_url = source_url

        # Fetch the content
        fetched = self._fetch_content(template)
        if not fetched:
            logger.error("Could not fetch content for %s", template.parish_id)
            result.validation_status = ValidationStatus.FLAGGED
            result.confidence = 0.0
            return result

        text, content_hash = fetched
        result.content_hash = content_hash

        # Tier 1: Static confirmation
        tier1_result = self._tier1_static(template, text)
        if tier1_result is not None:
            result.times = tier1_result
            result.tier = ExtractionTier.TIER1_STATIC
            result.confidence = 1.0
            result.validation_status = ValidationStatus.CONFIRMED
            logger.info("Tier 1 (static) extraction for %s: %d times", template.parish_id, len(result.times))
            return result

        # Tier 2: Code-based template extraction
        tier2_result = self._tier2_code(template, text)
        if tier2_result is not None:
            result.times = tier2_result
            result.tier = ExtractionTier.TIER2_CODE
            result.confidence = 0.85
            result.validation_status = ValidationStatus.CONFIRMED
            logger.info("Tier 2 (code) extraction for %s: %d times", template.parish_id, len(result.times))
            return result

        # Tier 3: LLM fallback
        if self.claude_api_key and not dry_run:
            tier3_result, cost = self._tier3_llm(template, text)
            if tier3_result is not None:
                result.times = tier3_result
                result.tier = ExtractionTier.TIER3_LLM
                result.confidence = 0.7
                result.validation_status = ValidationStatus.PROVISIONAL
                result.llm_model = self.fallback_model
                result.llm_cost_usd = cost
                logger.info("Tier 3 (LLM) extraction for %s: %d times", template.parish_id, len(result.times))
                return result

        # All tiers failed
        logger.warning("All extraction tiers failed for %s", template.parish_id)
        result.validation_status = ValidationStatus.FLAGGED
        result.confidence = 0.0
        return result

    def _fetch_content(self, template: ParishTemplate) -> tuple[str, str] | None:
        """Fetch content based on template source type.

        Returns (text_content, content_hash) or None.
        """
        if template.source_type == "website_page" and template.web_template:
            result = self.scraper.fetch_page(template.web_template.url)
            if result:
                html, content_hash = result
                soup = BeautifulSoup(html, "html.parser")
                # Try to extract just the mass times section
                text = self._extract_section_from_html(soup, template)
                return text, content_hash

        elif template.source_type in ("pdf_bulletin", "pdf_fulltext_regex", "pdf_region_regex"):
            if template.pdf_template and template.pdf_template.bulletin_page_url:
                pdf_url = self.scraper.find_latest_pdf_link(
                    template.pdf_template.bulletin_page_url,
                    template.pdf_template.pdf_link_pattern,
                )
                if pdf_url:
                    result = self.scraper.fetch_pdf(pdf_url)
                    if result:
                        pdf_bytes, content_hash = result
                        text = self._extract_text_from_pdf(pdf_bytes, template)
                        return text, content_hash

        return None

    def _extract_section_from_html(self, soup: BeautifulSoup, template: ParishTemplate) -> str:
        """Extract the mass times section text from HTML using template selectors."""
        if not template.web_template:
            return soup.get_text("\n", strip=True)

        # Try the primary selector
        selectors = [template.web_template.section_selector] + template.web_template.fallback_selectors
        for selector in selectors:
            if not selector:
                continue
            try:
                element = soup.select_one(selector)
                if element:
                    return element.get_text("\n", strip=True)
            except Exception:
                continue

        # Fallback: full page text
        return soup.get_text("\n", strip=True)

    def _extract_text_from_pdf(self, pdf_bytes: bytes, template: ParishTemplate) -> str:
        """Extract text from a PDF using template region info."""
        if template.pdf_template and template.pdf_template.bounding_region:
            region = template.pdf_template.bounding_region
            if region.get("x_max", 0) > 0:
                text = self.scraper.extract_text_from_region(
                    pdf_bytes, template.pdf_template.mass_times_page,
                    region["x_min"], region["y_min"], region["x_max"], region["y_max"],
                )
                if text.strip():
                    return text

        # Fallback: full text
        return self.scraper.extract_text_from_pdf(pdf_bytes)

    def _tier1_static(self, template: ParishTemplate, text: str) -> list[MassTime] | None:
        """Tier 1: Static confirmation.

        If the template has baseline times and is marked static, check that
        the content hasn't changed and no change indicators are present.
        Returns baseline MassTime objects if confirmed, None to escalate.
        """
        if not template.baseline_times:
            return None  # No baseline to confirm against

        # Check for change indicators
        changes = detect_change_indicators(text)
        if changes:
            logger.info("Change indicators found for %s: %s", template.parish_id, changes)
            return None  # Escalate to Tier 2

        # For PDF templates, check if the section is marked static
        if template.pdf_template and not template.pdf_template.section_static:
            return None  # Dynamic section, need Tier 2

        # Convert baseline times to MassTime objects
        mass_times = []
        for day, times in template.baseline_times.items():
            for time_str in times:
                mass_times.append(MassTime(day=day, time=time_str))

        return mass_times if mass_times else None

    def _tier2_code(self, template: ParishTemplate, text: str) -> list[MassTime] | None:
        """Tier 2: Code-based template extraction.

        Parse the text using regex patterns to extract day→time mappings.
        Returns MassTime objects if successful, None to escalate.
        """
        day_time_map = parse_day_time_block(text)

        if not day_time_map:
            return None

        # Check minimum count
        total_times = sum(len(times) for times in day_time_map.values())
        min_required = template.validation_rules.get("min_weekly_masses", 5)
        if total_times < min_required:
            logger.warning(
                "Tier 2 extracted only %d times for %s (min: %d)",
                total_times, template.parish_id, min_required,
            )
            return None

        # Convert to MassTime objects with language/type detection
        mass_times = []
        for day, times in day_time_map.items():
            for time_str in times:
                # Build a context string for language/type detection
                # Find the line in the original text that contains this time
                context = ""
                for line in text.split("\n"):
                    if time_str.replace(" ", "").lower() in line.replace(" ", "").lower():
                        context = line
                        break

                mass_times.append(MassTime(
                    day=day,
                    time=time_str,
                    mass_type=detect_special_type(context) if context else "Regular",
                    language=detect_language(context) if context else "English",
                ))

        return mass_times if mass_times else None

    def _tier3_llm(self, template: ParishTemplate, text: str) -> tuple[list[MassTime] | None, float]:
        """Tier 3: LLM fallback extraction using Claude Sonnet.

        Sends the text to Claude with a structured prompt.
        Returns (mass_times, cost_usd) or (None, 0).
        """
        try:
            import anthropic
        except ImportError:
            logger.warning("anthropic package not installed, cannot use Tier 3")
            return None, 0.0

        baseline_hint = ""
        if template.baseline_times:
            baseline_hint = f"\nKnown baseline times for this parish: {json.dumps(template.baseline_times)}\nFlag any differences from the baseline."

        prompt = f"""Extract all Catholic mass times from this text. Return ONLY valid JSON with no other text.

Format:
{{"times": [{{"day": "Sunday", "time": "10:00 AM", "type": "Regular", "language": "English", "notes": ""}}]}}

Valid days: Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday
Valid types: Regular, Vigil, Holy Day, Reconciliation, Adoration, Latin Rite, Children's Liturgy
{baseline_hint}

Text:
{text[:4000]}"""

        try:
            client = anthropic.Anthropic(api_key=self.claude_api_key)
            response = client.messages.create(
                model=self.fallback_model,
                max_tokens=1024,
                messages=[{"role": "user", "content": prompt}],
            )

            response_text = response.content[0].text.strip()

            # Calculate cost (approximate)
            input_tokens = response.usage.input_tokens
            output_tokens = response.usage.output_tokens
            # Sonnet pricing: $3/1M input, $15/1M output
            cost = (input_tokens * 3 + output_tokens * 15) / 1_000_000

            # Parse JSON response
            # Handle markdown code blocks
            if "```" in response_text:
                response_text = re.search(r'```(?:json)?\s*(.*?)```', response_text, re.DOTALL)
                if response_text:
                    response_text = response_text.group(1).strip()
                else:
                    return None, cost

            data = json.loads(response_text)
            times_data = data.get("times", [])

            mass_times = []
            for entry in times_data:
                mass_times.append(MassTime(
                    day=entry.get("day", ""),
                    time=entry.get("time", ""),
                    mass_type=entry.get("type", "Regular"),
                    language=entry.get("language", "English"),
                    notes=entry.get("notes", ""),
                ))

            return mass_times if mass_times else None, cost

        except Exception as e:
            logger.error("Tier 3 LLM extraction failed: %s", e)
            return None, 0.0
