"""Runner script for template building.

Called by mass-times.sh --build [parish].
"""

import argparse
import json
import logging
from pathlib import Path

from config import load_config
from models import SourceEndpoint, SourceType
from scraper import Scraper
from template_builder import TemplateBuilder

logger = logging.getLogger(__name__)


def load_parishes_and_sources(data_dir: Path) -> tuple[list[dict], list[dict]]:
    """Load discovered parishes and sources from JSON files."""
    parishes_file = data_dir / "parishes.json"
    sources_file = data_dir / "sources.json"

    parishes = []
    sources = []

    if parishes_file.exists():
        parishes = json.loads(parishes_file.read_text())
    if sources_file.exists():
        sources = json.loads(sources_file.read_text())

    return parishes, sources


def main():
    parser = argparse.ArgumentParser(description="Build extraction templates")
    parser.add_argument("--parish", help="Build for a specific parish slug")
    parser.add_argument("--all", action="store_true", help="Build for all parishes")
    parser.add_argument("--conf", help="Path to mass-times.conf")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    config = load_config(args.conf)
    parishes, sources = load_parishes_and_sources(config.data_dir)

    if not parishes:
        logger.error("No parishes discovered yet. Run --discover first.")
        return

    # Build map of parish_id -> sources
    source_map: dict[str, list[dict]] = {}
    for s in sources:
        pid = s.get("parish_id", "")
        if pid:
            source_map.setdefault(pid, []).append(s)

    scraper = Scraper(data_dir=config.data_dir)
    builder = TemplateBuilder(scraper=scraper)

    # Filter parishes if specific one requested
    if args.parish:
        parishes = [p for p in parishes if p.get("id") == args.parish]
        if not parishes:
            logger.error("Parish '%s' not found", args.parish)
            return

    built = 0
    failed = 0

    for parish in parishes:
        pid = parish.get("id", "")
        parish_sources = source_map.get(pid, [])

        if not parish_sources:
            logger.info("No sources for %s, skipping", pid)
            continue

        # Prioritise sources: iCal > structured_data > website_page > pdf_bulletin
        parish_sources.sort(key=lambda s: {
            "ical_feed": 0,
            "structured_data": 1,
            "website_page": 2,
            "pdf_bulletin": 3,
            "facebook_page": 4,
        }.get(s.get("source_type", ""), 99))

        primary = parish_sources[0]
        source_type = primary.get("source_type", "website_page")
        url = primary.get("url", "")

        if not url:
            continue

        try:
            if source_type in ("website_page", "structured_data"):
                template = builder.build_web_template(pid, url)
            elif source_type == "pdf_bulletin":
                template = builder.build_pdf_template(pid, url)
            else:
                logger.info("Skipping unsupported source type %s for %s", source_type, pid)
                continue

            if template:
                template.source_type = source_type
                builder.save_template(template, config.templates_dir)
                built += 1
                logger.info("Built template for %s (%s)", pid, source_type)
            else:
                failed += 1
                logger.warning("Failed to build template for %s", pid)

        except Exception as e:
            failed += 1
            logger.error("Error building template for %s: %s", pid, e)

    logger.info("Templates built: %d, failed: %d", built, failed)


if __name__ == "__main__":
    main()
