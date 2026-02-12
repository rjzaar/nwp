"""Runner script for generating extraction reports.

Called by mass-times.sh --report.
"""

import argparse
import json
import logging
from collections import Counter
from datetime import datetime
from pathlib import Path

from config import load_config

logger = logging.getLogger(__name__)


def main():
    parser = argparse.ArgumentParser(description="Generate mass times report")
    parser.add_argument("--conf", help="Path to mass-times.conf")
    parser.add_argument("--format", choices=["text", "json"], default="text")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    config = load_config(args.conf)
    results_dir = config.data_dir / "results"

    if not results_dir.exists():
        logger.error("No results directory found. Run --extract first.")
        return

    result_files = sorted(results_dir.glob("*.json"))
    if not result_files:
        logger.info("No extraction results found.")
        return

    # Aggregate stats
    total = len(result_files)
    tier_counts = Counter()
    status_counts = Counter()
    total_times = 0
    total_cost = 0.0
    parishes = []

    for f in result_files:
        try:
            data = json.loads(f.read_text())
        except (json.JSONDecodeError, OSError):
            continue

        tier = data.get("tier", 0)
        tier_counts[tier] += 1
        status_counts[data.get("validation_status", "unknown")] += 1
        total_times += len(data.get("times", []))
        total_cost += data.get("llm_cost_usd", 0.0)

        parishes.append({
            "id": data.get("parish_id", f.stem),
            "tier": tier,
            "status": data.get("validation_status", "unknown"),
            "times_count": len(data.get("times", [])),
            "confidence": data.get("confidence", 0),
        })

    if args.format == "json":
        report = {
            "generated_at": datetime.now().isoformat(),
            "total_parishes": total,
            "tier_distribution": dict(tier_counts),
            "status_distribution": dict(status_counts),
            "total_times": total_times,
            "total_llm_cost_usd": total_cost,
            "parishes": parishes,
        }
        print(json.dumps(report, indent=2))
    else:
        print("=" * 60)
        print(f"Mass Times Extraction Report — {datetime.now():%Y-%m-%d %H:%M}")
        print("=" * 60)
        print()
        print(f"Parishes:       {total}")
        print(f"Total times:    {total_times}")
        print()
        print("Tier distribution:")
        print(f"  Tier 1 (static):  {tier_counts.get(1, 0)}")
        print(f"  Tier 2 (code):    {tier_counts.get(2, 0)}")
        print(f"  Tier 3 (LLM):     {tier_counts.get(3, 0)}")
        print()
        print("Validation status:")
        for status, count in sorted(status_counts.items()):
            print(f"  {status:15s} {count}")
        print()
        print(f"LLM cost:       ${total_cost:.4f}")
        print()

        # Show flagged parishes
        flagged = [p for p in parishes if p["status"] == "flagged"]
        if flagged:
            print("Flagged parishes (need attention):")
            for p in flagged:
                print(f"  - {p['id']} (tier {p['tier']}, {p['times_count']} times)")
            print()

        print("=" * 60)


if __name__ == "__main__":
    main()
