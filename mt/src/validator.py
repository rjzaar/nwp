"""Extraction validation module.

Validates extracted mass times against template rules and previous extractions.
"""

import logging
from datetime import datetime

from models import ExtractionResult, MassTime, ValidationStatus

logger = logging.getLogger(__name__)


def validate_extraction(
    result: ExtractionResult,
    template_rules: dict,
    previous_times: list[MassTime] | None = None,
) -> ExtractionResult:
    """Validate an extraction result against template rules.

    Checks:
    1. Minimum/maximum mass count
    2. Expected Sunday count
    3. Sudden large changes vs previous extraction
    4. All-change detection (likely error)

    Modifies result.validation_status and result.confidence in place.
    Returns the modified result.
    """
    if not result.times:
        result.validation_status = ValidationStatus.FLAGGED
        result.confidence = 0.0
        return result

    issues = []

    # Rule 1: Minimum mass count
    min_masses = template_rules.get("min_weekly_masses", 5)
    if len(result.times) < min_masses:
        issues.append(f"Only {len(result.times)} masses found (min: {min_masses})")

    # Rule 2: Maximum mass count
    max_masses = template_rules.get("max_weekly_masses", 20)
    if len(result.times) > max_masses:
        issues.append(f"{len(result.times)} masses found (max: {max_masses})")

    # Rule 3: Expected Sunday count
    expected_sunday = template_rules.get("expected_sunday_count", 0)
    if expected_sunday > 0:
        sunday_count = sum(1 for t in result.times if t.day == "Sunday")
        if sunday_count == 0:
            issues.append("No Sunday masses found")
        elif abs(sunday_count - expected_sunday) > 1:
            issues.append(f"Sunday count {sunday_count} differs from expected {expected_sunday}")

    # Rule 4: Compare against previous extraction
    if previous_times:
        prev_set = {(t.day, t.time) for t in previous_times}
        curr_set = {(t.day, t.time) for t in result.times}

        if prev_set and curr_set:
            changed = prev_set.symmetric_difference(curr_set)
            change_ratio = len(changed) / max(len(prev_set), len(curr_set))

            if change_ratio > 0.5:
                alert_if_all_change = template_rules.get("alert_if_all_change", True)
                if alert_if_all_change:
                    issues.append(
                        f"{len(changed)} times changed ({change_ratio:.0%}) — "
                        "possible extraction error"
                    )

    # Set validation status based on issues
    if not issues:
        result.validation_status = ValidationStatus.CONFIRMED
        # Preserve confidence from extraction tier
    elif len(issues) == 1 and "differs from expected" in issues[0]:
        # Minor discrepancy — publish with caveat
        result.validation_status = ValidationStatus.PROVISIONAL
        result.confidence = min(result.confidence, 0.7)
    else:
        result.validation_status = ValidationStatus.FLAGGED
        result.confidence = min(result.confidence, 0.3)

    if issues:
        logger.warning("Validation issues for %s: %s", result.parish_id, "; ".join(issues))
        result.changes_from_previous.extend(issues)

    return result


def cross_reference(results: list[ExtractionResult]) -> ExtractionResult | None:
    """Cross-reference multiple extraction results for the same parish.

    If a parish has multiple sources (website + bulletin + iCal),
    compare results and prefer the highest-confidence one.

    Returns the best result, or None if no results.
    """
    if not results:
        return None

    if len(results) == 1:
        return results[0]

    # Sort by source type priority (iCal > structured > web > PDF)
    source_priority = {
        "ical_feed": 0,
        "structured_data": 1,
        "website_page": 2,
        "pdf_bulletin": 3,
    }

    results.sort(key=lambda r: (
        source_priority.get(r.source_type.value, 99),
        -r.confidence,
    ))

    best = results[0]

    # Cross-reference: if multiple sources agree, boost confidence
    if len(results) >= 2:
        times_a = {(t.day, t.time) for t in results[0].times}
        times_b = {(t.day, t.time) for t in results[1].times}

        if times_a and times_b:
            overlap = times_a.intersection(times_b)
            overlap_ratio = len(overlap) / max(len(times_a), len(times_b))

            if overlap_ratio > 0.8:
                best.confidence = min(1.0, best.confidence + 0.1)
                best.validation_status = ValidationStatus.CONFIRMED
                logger.info(
                    "Cross-reference confirms %s: %.0f%% agreement between sources",
                    best.parish_id, overlap_ratio * 100,
                )

    return best
