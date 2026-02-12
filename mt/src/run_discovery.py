"""Runner script for parish discovery.

Called by mass-times.sh --discover.
"""

import argparse
import json
import logging
import sys
from pathlib import Path

from config import load_config
from discovery import ParishDiscovery

logger = logging.getLogger(__name__)


def main():
    parser = argparse.ArgumentParser(description="Discover parishes near centre point")
    parser.add_argument("--dry-run", action="store_true", help="Don't save results")
    parser.add_argument("--conf", help="Path to mass-times.conf")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    config = load_config(args.conf)

    discovery = ParishDiscovery(
        centre_lat=config.centre_lat,
        centre_lng=config.centre_lng,
        radius_km=config.radius_km,
        google_api_key=config.google_places_api_key,
    )

    logger.info(
        "Discovering parishes within %.0f km of (%.4f, %.4f)",
        config.radius_km, config.centre_lat, config.centre_lng,
    )

    parishes, sources = discovery.run()

    logger.info("Found %d parishes with %d source endpoints", len(parishes), len(sources))

    if args.dry_run:
        logger.info("Dry run — not saving results")
        for p in parishes:
            print(f"  {p.id}: {p.name} ({p.distance_km:.1f} km)")
        return

    # Save results
    data_dir = config.data_dir
    data_dir.mkdir(parents=True, exist_ok=True)

    discovery.save_results(parishes, sources, data_dir)
    logger.info("Results saved to %s", data_dir)


if __name__ == "__main__":
    main()
