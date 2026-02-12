"""Tests for drupal_sync module."""

import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'src'))

from drupal_sync import DrupalSync


@pytest.fixture
def sync():
    """Create a DrupalSync instance with mocked session."""
    with patch('drupal_sync.requests.Session') as mock_session_cls:
        mock_session = MagicMock()
        mock_session_cls.return_value = mock_session
        s = DrupalSync(
            base_url='https://mt.example.com',
            username='admin',
            password='secret',
        )
        s.session = mock_session
        yield s


class TestGetParishUuid:
    def test_returns_uuid_when_found(self, sync):
        sync.session.get.return_value.json.return_value = {
            'data': [{'id': 'uuid-123', 'attributes': {'title': 'Sacred Heart'}}],
        }
        sync.session.get.return_value.raise_for_status = MagicMock()
        assert sync.get_parish_uuid('sacred-heart') == 'uuid-123'

    def test_returns_none_when_not_found(self, sync):
        sync.session.get.return_value.json.return_value = {'data': []}
        sync.session.get.return_value.raise_for_status = MagicMock()
        assert sync.get_parish_uuid('nonexistent') is None

    def test_returns_none_on_error(self, sync):
        sync.session.get.side_effect = Exception('Connection error')
        assert sync.get_parish_uuid('test') is None


class TestGetParishNid:
    def test_returns_nid(self, sync):
        sync.session.get.return_value.json.return_value = {
            'data': {'attributes': {'drupal_internal__nid': 42}},
        }
        sync.session.get.return_value.raise_for_status = MagicMock()
        assert sync.get_parish_nid('uuid-123') == 42

    def test_returns_none_on_error(self, sync):
        sync.session.get.side_effect = Exception('error')
        assert sync.get_parish_nid('uuid-123') is None


class TestSyncExtraction:
    def test_syncs_valid_file(self, sync, tmp_path):
        result_file = tmp_path / 'sacred-heart.json'
        result_file.write_text(json.dumps({
            'parish_id': 'sacred-heart',
            'times': [
                {'day': 'Sunday', 'time': '9:30 AM', 'mass_type': 'Regular'},
            ],
            'tier': 2,
            'confidence': 0.95,
        }))

        sync.get_parish_uuid = MagicMock(return_value='uuid-123')
        sync.get_parish_nid = MagicMock(return_value=42)

        # Mock paragraph creation.
        sync.session.post.return_value.json.return_value = {
            'data': {'id': 'para-uuid-1'},
        }
        sync.session.post.return_value.raise_for_status = MagicMock()
        sync.session.patch.return_value.raise_for_status = MagicMock()

        assert sync.sync_extraction(result_file) is True
        sync.session.patch.assert_called_once()

    def test_skips_when_parish_not_found(self, sync, tmp_path):
        result_file = tmp_path / 'unknown.json'
        result_file.write_text(json.dumps({
            'parish_id': 'unknown-parish',
            'times': [{'day': 'Sunday', 'time': '10:00 AM'}],
        }))

        sync.get_parish_uuid = MagicMock(return_value=None)
        assert sync.sync_extraction(result_file) is False

    def test_skips_empty_times(self, sync, tmp_path):
        result_file = tmp_path / 'empty.json'
        result_file.write_text(json.dumps({
            'parish_id': 'test-parish',
            'times': [],
        }))

        sync.get_parish_uuid = MagicMock(return_value='uuid-123')
        sync.get_parish_nid = MagicMock(return_value=42)
        assert sync.sync_extraction(result_file) is True

    def test_handles_missing_file(self, sync, tmp_path):
        result_file = tmp_path / 'nonexistent.json'
        assert sync.sync_extraction(result_file) is False


class TestSyncAll:
    def test_syncs_all_files(self, sync, tmp_path):
        for name in ['parish-a.json', 'parish-b.json']:
            (tmp_path / name).write_text(json.dumps({
                'parish_id': name.replace('.json', ''),
                'times': [{'day': 'Sunday', 'time': '10:00 AM'}],
            }))

        sync.sync_extraction = MagicMock(return_value=True)
        stats = sync.sync_all(tmp_path)
        assert stats['synced'] == 2
        assert stats['failed'] == 0

    def test_counts_failures(self, sync, tmp_path):
        (tmp_path / 'fail.json').write_text(json.dumps({
            'parish_id': 'fail',
            'times': [{'day': 'Sunday', 'time': '10:00 AM'}],
        }))

        sync.sync_extraction = MagicMock(return_value=False)
        stats = sync.sync_all(tmp_path)
        assert stats['failed'] == 1
        assert stats['synced'] == 0

    def test_empty_directory(self, sync, tmp_path):
        stats = sync.sync_all(tmp_path)
        assert stats == {'synced': 0, 'skipped': 0, 'failed': 0}
