"""Unit tests for the diff extraction logic in ``poll.py``.

These tests run against static fixtures, not against a live ollama
instance or a live GitLab. Run from the repo root:

    python3 -m unittest discover -s servers/mini/bot/tests -v

or from the bot directory:

    cd servers/mini/bot && python3 -m unittest tests.test_diff_parser -v
"""
from __future__ import annotations

import pathlib
import sys
import unittest

# Make ``poll`` importable regardless of cwd.
BOT_DIR = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BOT_DIR))

import poll  # noqa: E402 — path injection above is intentional

FIXTURES = pathlib.Path(__file__).parent / "fixtures"


def load_fixture(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


class ExtractDiffTests(unittest.TestCase):
    """Tests for ``poll.extract_diff``."""

    def test_extracts_from_prose_wrapped_response(self) -> None:
        response = load_fixture("response_with_prose.md")
        diff = poll.extract_diff(response)
        self.assertIn("--- a/src/greet.py", diff)
        self.assertIn("+++ b/src/greet.py", diff)
        self.assertIn("@@", diff)
        self.assertIn('name = "friend"', diff)
        # Prose around the fence must not leak into the diff body.
        self.assertNotIn("Looking at the issue", diff)
        self.assertNotIn("Let me know if you'd like", diff)

    def test_extracts_from_patch_fence(self) -> None:
        """Model sometimes labels the fence ``patch`` instead of ``diff``."""
        response = load_fixture("response_patch_fence.md")
        diff = poll.extract_diff(response)
        self.assertIn("--- a/README.md", diff)
        self.assertIn("Version: 1.1", diff)

    def test_empty_diff_block_returns_empty_string(self) -> None:
        """An explicitly empty diff block means the model declined. That
        is valid, expected behaviour — return '' rather than raising."""
        response = load_fixture("response_empty_diff.md")
        diff = poll.extract_diff(response)
        self.assertEqual(diff, "")

    def test_no_fence_raises(self) -> None:
        response = load_fixture("response_no_diff.md")
        with self.assertRaises(ValueError):
            poll.extract_diff(response)

    def test_raw_diff_with_unlabelled_fence(self) -> None:
        """Fence without a language label should still be picked up."""
        response = (
            "Here you go:\n"
            "```\n"
            "--- a/x\n"
            "+++ b/x\n"
            "@@ -1 +1 @@\n"
            "-old\n"
            "+new\n"
            "```\n"
        )
        diff = poll.extract_diff(response)
        self.assertIn("--- a/x", diff)
        self.assertIn("+new", diff)


class LooksLikeDiffTests(unittest.TestCase):
    """Tests for the cheap sanity checker ``poll.looks_like_unified_diff``."""

    def test_valid_diff(self) -> None:
        body = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n"
        self.assertTrue(poll.looks_like_unified_diff(body))

    def test_empty_is_not_valid(self) -> None:
        self.assertFalse(poll.looks_like_unified_diff(""))

    def test_missing_hunk_marker_is_not_valid(self) -> None:
        body = "--- a/x\n+++ b/x\n- no hunk header\n+new line\n"
        self.assertFalse(poll.looks_like_unified_diff(body))

    def test_missing_file_marker_is_not_valid(self) -> None:
        body = "@@ -1 +1 @@\n-old\n+new\n"
        self.assertFalse(poll.looks_like_unified_diff(body))

    def test_new_file_against_dev_null(self) -> None:
        body = "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+content\n"
        self.assertTrue(poll.looks_like_unified_diff(body))


class BuildPromptTests(unittest.TestCase):
    """Tests for ``poll.build_prompt`` injection-defence framing."""

    def test_issue_body_is_delimited(self) -> None:
        prompt = poll.build_prompt("bug: crash", [], max_bytes=100_000)
        self.assertIn("<<<ISSUE_BODY_BEGIN>>>", prompt)
        self.assertIn("<<<ISSUE_BODY_END>>>", prompt)
        self.assertIn("UNTRUSTED USER DATA", prompt)

    def test_repo_files_are_delimited(self) -> None:
        prompt = poll.build_prompt(
            "bug", [("a.py", "print('x')")], max_bytes=100_000,
        )
        self.assertIn("<<<REPO_FILES_BEGIN>>>", prompt)
        self.assertIn("<<<REPO_FILES_END>>>", prompt)
        self.assertIn("--- FILE: a.py ---", prompt)
        self.assertIn("print('x')", prompt)

    def test_body_truncated_on_overflow(self) -> None:
        """A huge body must not blow the byte cap."""
        huge = "x" * 200_000
        prompt = poll.build_prompt(huge, [], max_bytes=4_000)
        self.assertLessEqual(len(prompt.encode("utf-8")), 4_096)
        self.assertIn("truncated", prompt)


if __name__ == "__main__":
    unittest.main()
