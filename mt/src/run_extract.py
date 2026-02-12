"""Runner script for the extraction pipeline.

Called by mass-times.sh --extract. Orchestrates the full extraction cycle:
1. Load templates for all parishes
2. Run three-tier extraction
3. Validate results
4. Save results
5. Sync to Drupal (if configured)
6. Send email report on failure
"""

import argparse
import json
import logging
import sys
from datetime import datetime
from dataclasses import asdict
from pathlib import Path

from config import load_config
from extractor import Extractor
from models import ExtractionResult, ValidationStatus
from scraper import Scraper
from template_builder import TemplateBuilder, ParishTemplate
from validator import validate_extraction, cross_reference

logger = logging.getLogger(__name__)


def load_templates(templates_dir: Path) -> list[ParishTemplate]:
    """Load all parish templates from the templates directory."""
    templates = []
    builder = TemplateBuilder()
    for f in sorted(templates_dir.glob("*.json")):
        template = builder.load_template(f)
        if template:
            templates.append(template)
    return templates


def save_result(result: ExtractionResult, results_dir: Path) -> Path:
    """Save an extraction result to JSON."""
    results_dir.mkdir(parents=True, exist_ok=True)

    data = {
        "parish_id": result.parish_id,
        "times": [
            {
                "day": t.day,
                "time": t.time,
                "mass_type": t.mass_type,
                "language": t.language,
                "notes": t.notes,
            }
            for t in result.times
        ],
        "tier": result.tier.value,
        "confidence": result.confidence,
        "validation_status": result.validation_status.value,
        "content_hash": result.content_hash,
        "source_url": result.source_url,
        "llm_model": result.llm_model,
        "llm_cost_usd": result.llm_cost_usd,
        "extracted_at": result.extracted_at.isoformat(),
    }

    output_file = results_dir / f"{result.parish_id}.json"
    output_file.write_text(json.dumps(data, indent=2))
    return output_file


def main():
    parser = argparse.ArgumentParser(description="Run mass times extraction")
    parser.add_argument("--dry-run", action="store_true", help="Don't save or sync")
    parser.add_argument("--parish", help="Extract for a specific parish only")
    parser.add_argument("--shadow", action="store_true", default=None, help="Shadow mode: flag all as provisional")
    parser.add_argument("--conf", help="Path to mass-times.conf")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    config = load_config(args.conf)

    # Load templates
    templates = load_templates(config.templates_dir)
    if not templates:
        logger.error("No templates found in %s. Run --build first.", config.templates_dir)
        sys.exit(1)

    if args.parish:
        templates = [t for t in templates if t.parish_id == args.parish]
        if not templates:
            logger.error("Template not found for parish '%s'", args.parish)
            sys.exit(1)

    # Determine shadow mode: CLI flag overrides config
    shadow_mode = args.shadow if args.shadow is not None else config.shadow_mode
    if shadow_mode:
        logger.info("Shadow mode enabled — all results will be flagged as provisional")

    logger.info("Loaded %d templates", len(templates))

    # Set up extractor
    scraper = Scraper(data_dir=config.data_dir)
    extractor = Extractor(
        scraper=scraper,
        templates_dir=config.templates_dir,
        claude_api_key=config.claude_api_key,
        fallback_model=config.fallback_model,
    )

    results_dir = config.data_dir / "results"
    results: list[ExtractionResult] = []
    tier_counts = {1: 0, 2: 0, 3: 0}
    total_cost = 0.0
    failures = 0

    for template in templates:
        logger.info("Extracting: %s", template.parish_id)
        try:
            result = extractor.extract(template, dry_run=args.dry_run)

            # Shadow mode: mark everything as provisional
            if shadow_mode:
                result.validation_status = ValidationStatus.PROVISIONAL

            # Validate
            validation = validate_extraction(result, template)
            if not validation["valid"]:
                logger.warning(
                    "Validation failed for %s: %s",
                    template.parish_id, validation["reasons"],
                )
                result.validation_status = ValidationStatus.FLAGGED

            tier_counts[result.tier.value] += 1
            total_cost += result.llm_cost_usd
            results.append(result)

            if result.validation_status == ValidationStatus.FLAGGED:
                failures += 1

            if not args.dry_run:
                save_result(result, results_dir)

        except Exception as e:
            logger.error("Extraction error for %s: %s", template.parish_id, e)
            failures += 1

    # Cross-reference where multiple sources exist
    # Group results by parish
    parish_results: dict[str, list[ExtractionResult]] = {}
    for r in results:
        parish_results.setdefault(r.parish_id, []).append(r)

    for pid, prs in parish_results.items():
        if len(prs) > 1:
            cross_ref = cross_reference(prs)
            logger.info("Cross-reference for %s: confidence=%.2f", pid, cross_ref["confidence"])

    # Summary
    logger.info("=" * 60)
    logger.info("Extraction complete: %d parishes", len(results))
    logger.info("  Tier 1 (static):  %d", tier_counts[1])
    logger.info("  Tier 2 (code):    %d", tier_counts[2])
    logger.info("  Tier 3 (LLM):     %d", tier_counts[3])
    logger.info("  Failures:         %d", failures)
    logger.info("  LLM cost:         $%.4f", total_cost)
    logger.info("=" * 60)

    # Sync to Drupal if configured
    if config.sync_after_extraction and config.drupal_base_url and not args.dry_run:
        logger.info("Syncing to Drupal at %s...", config.drupal_base_url)
        try:
            from drupal_sync import DrupalSync
            sync = DrupalSync(
                base_url=config.drupal_base_url,
                username=config.drupal_api_user,
                password=config.drupal_api_password,
            )
            stats = sync.sync_all(results_dir)
            logger.info(
                "Drupal sync: %d synced, %d failed",
                stats["synced"], stats["failed"],
            )
        except Exception as e:
            logger.error("Drupal sync failed: %s", e)

    if failures > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
