"""Sync extraction results to Drupal via JSON:API."""

import json
import logging
import sys
from dataclasses import dataclass
from pathlib import Path

import requests

from config import load_config

logger = logging.getLogger(__name__)


@dataclass
class DrupalSync:
    """Syncs mass times extraction results to Drupal."""

    base_url: str
    username: str
    password: str
    timeout: int = 30

    def __post_init__(self):
        self.session = requests.Session()
        self.session.auth = (self.username, self.password)
        self.session.headers.update({
            'Content-Type': 'application/vnd.api+json',
            'Accept': 'application/vnd.api+json',
        })

    def get_parish_uuid(self, slug: str) -> str | None:
        """Look up a parish node UUID by its slug field."""
        url = (
            f"{self.base_url}/jsonapi/node/parish"
            f"?filter[field_parish_slug]={slug}"
            f"&fields[node--parish]=id,title"
        )
        try:
            resp = self.session.get(url, timeout=self.timeout)
            resp.raise_for_status()
            data = resp.json().get('data', [])
            if data:
                return data[0]['id']
        except Exception as e:
            logger.error("Failed to look up parish %s: %s", slug, e)
        return None

    def get_parish_nid(self, uuid: str) -> int | None:
        """Get the Drupal node ID from a UUID."""
        url = f"{self.base_url}/jsonapi/node/parish/{uuid}?fields[node--parish]=drupal_internal__nid"
        try:
            resp = self.session.get(url, timeout=self.timeout)
            resp.raise_for_status()
            return resp.json()['data']['attributes']['drupal_internal__nid']
        except Exception as e:
            logger.error("Failed to get nid for %s: %s", uuid, e)
        return None

    def sync_extraction(self, result_file: Path) -> bool:
        """Sync a single extraction result file to Drupal.

        The result file is a JSON file produced by the extractor, with keys:
        parish_id, times, tier, confidence, validation_status, content_hash,
        source_url, llm_model, llm_cost_usd.
        """
        try:
            data = json.loads(result_file.read_text())
        except (json.JSONDecodeError, OSError) as e:
            logger.error("Failed to read %s: %s", result_file, e)
            return False

        parish_id = data.get('parish_id', '')
        if not parish_id:
            logger.error("No parish_id in %s", result_file)
            return False

        uuid = self.get_parish_uuid(parish_id)
        if not uuid:
            logger.warning("Parish %s not found in Drupal, skipping", parish_id)
            return False

        nid = self.get_parish_nid(uuid)
        if not nid:
            return False

        # Update the parish node's mass times paragraphs.
        times = data.get('times', [])
        if not times:
            logger.info("No times for %s, skipping sync", parish_id)
            return True

        # Build paragraph references for each mass time.
        paragraphs = []
        for t in times:
            para_data = self._create_mass_time_paragraph(t)
            if para_data:
                paragraphs.append(para_data)

        if not paragraphs:
            return True

        # Update the parish node with new mass time paragraphs.
        payload = {
            'data': {
                'type': 'node--parish',
                'id': uuid,
                'relationships': {
                    'field_mass_times': {
                        'data': paragraphs,
                    },
                },
            },
        }

        url = f"{self.base_url}/jsonapi/node/parish/{uuid}"
        try:
            resp = self.session.patch(url, json=payload, timeout=self.timeout)
            resp.raise_for_status()
            logger.info("Synced %d times for %s", len(paragraphs), parish_id)
            return True
        except requests.RequestException as e:
            logger.error("Failed to sync %s: %s", parish_id, e)
            return False

    def _create_mass_time_paragraph(self, time_entry: dict) -> dict | None:
        """Create a mass time paragraph entity and return its reference."""
        payload = {
            'data': {
                'type': 'paragraph--mass_time',
                'attributes': {
                    'field_day': time_entry.get('day', ''),
                    'field_time': time_entry.get('time', ''),
                    'field_mass_type': time_entry.get('mass_type', 'Regular'),
                    'field_language': time_entry.get('language', 'English'),
                    'field_notes': time_entry.get('notes', ''),
                },
            },
        }

        url = f"{self.base_url}/jsonapi/paragraph/mass_time"
        try:
            resp = self.session.post(url, json=payload, timeout=self.timeout)
            resp.raise_for_status()
            result = resp.json()['data']
            return {
                'type': 'paragraph--mass_time',
                'id': result['id'],
            }
        except requests.RequestException as e:
            logger.error("Failed to create paragraph: %s", e)
            return None

    def sync_all(self, results_dir: Path) -> dict:
        """Sync all extraction results from a directory.

        Returns dict with counts: synced, skipped, failed.
        """
        stats = {'synced': 0, 'skipped': 0, 'failed': 0}

        result_files = sorted(results_dir.glob('*.json'))
        if not result_files:
            logger.info("No result files in %s", results_dir)
            return stats

        for f in result_files:
            try:
                success = self.sync_extraction(f)
                if success:
                    stats['synced'] += 1
                else:
                    stats['failed'] += 1
            except Exception as e:
                logger.error("Unexpected error syncing %s: %s", f, e)
                stats['failed'] += 1

        logger.info(
            "Sync complete: %d synced, %d skipped, %d failed",
            stats['synced'], stats['skipped'], stats['failed'],
        )
        return stats


def main():
    """CLI entry point for Drupal sync."""
    logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')

    config = load_config()
    base_url = getattr(config, 'drupal_base_url', '')
    username = getattr(config, 'drupal_username', '')
    password = getattr(config, 'drupal_password', '')

    if not all([base_url, username, password]):
        logger.error("Drupal sync credentials not configured in mass-times.conf")
        sys.exit(1)

    results_dir = Path(getattr(config, 'data_dir', 'data')) / 'results'
    if not results_dir.exists():
        logger.error("Results directory not found: %s", results_dir)
        sys.exit(1)

    sync = DrupalSync(
        base_url=base_url,
        username=username,
        password=password,
    )

    stats = sync.sync_all(results_dir)
    if stats['failed'] > 0:
        sys.exit(1)


if __name__ == '__main__':
    main()
