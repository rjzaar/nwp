"""Web and PDF scraping module for Mass Times.

Fetches parish web pages and bulletin PDFs, with:
- Rate limiting (2s delay per domain)
- Polite User-Agent
- robots.txt respect
- Content hashing for change detection
- Archiving to data/ directory
"""

import hashlib
import logging
import re
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import urljoin, urlparse
from urllib.robotparser import RobotFileParser

import httpx
from bs4 import BeautifulSoup

logger = logging.getLogger(__name__)

USER_AGENT = "NWP-MassTimesScraper/1.0 (+https://mt.nwpcode.org; Catholic mass times aggregator)"
REQUEST_DELAY = 2.0
MAX_RETRIES = 3


class Scraper:
    """Fetches web pages and PDFs with rate limiting and archiving."""

    def __init__(self, data_dir: Path | None = None):
        self.data_dir = data_dir or Path(__file__).parent.parent / "data"
        self._last_request_by_domain: dict[str, float] = {}
        self._robots_cache: dict[str, RobotFileParser] = {}
        self._client = httpx.Client(
            timeout=30.0,
            headers={"User-Agent": USER_AGENT},
            follow_redirects=True,
        )

    def close(self):
        self._client.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def _rate_limit(self, url: str):
        """Enforce per-domain rate limiting."""
        domain = urlparse(url).netloc
        last = self._last_request_by_domain.get(domain, 0)
        elapsed = time.time() - last
        if elapsed < REQUEST_DELAY:
            time.sleep(REQUEST_DELAY - elapsed)
        self._last_request_by_domain[domain] = time.time()

    def _check_robots(self, url: str) -> bool:
        """Check if we're allowed to fetch this URL per robots.txt."""
        parsed = urlparse(url)
        robots_url = f"{parsed.scheme}://{parsed.netloc}/robots.txt"

        if robots_url not in self._robots_cache:
            rp = RobotFileParser()
            try:
                rp.set_url(robots_url)
                rp.read()
            except Exception:
                # If we can't read robots.txt, assume allowed
                rp = RobotFileParser()
            self._robots_cache[robots_url] = rp

        return self._robots_cache[robots_url].can_fetch(USER_AGENT, url)

    def fetch_page(self, url: str, archive: bool = True) -> tuple[str, str] | None:
        """Fetch an HTML page.

        Returns (html_content, content_hash) or None on failure.
        Archives to data/pages/ if archive=True.
        """
        if not self._check_robots(url):
            logger.info("Blocked by robots.txt: %s", url)
            return None

        for attempt in range(MAX_RETRIES):
            self._rate_limit(url)
            try:
                resp = self._client.get(url)
                resp.raise_for_status()
                html = resp.text
                content_hash = hashlib.sha256(html.encode()).hexdigest()

                if archive:
                    self._archive_page(url, html, content_hash)

                return html, content_hash

            except httpx.HTTPError as e:
                logger.warning("Fetch attempt %d/%d failed for %s: %s", attempt + 1, MAX_RETRIES, url, e)
                if attempt < MAX_RETRIES - 1:
                    time.sleep(2 ** (attempt + 1))  # Exponential backoff

        return None

    def fetch_pdf(self, url: str, archive: bool = True) -> tuple[bytes, str] | None:
        """Fetch a PDF file.

        Returns (pdf_bytes, content_hash) or None on failure.
        Archives to data/bulletins/ if archive=True.
        """
        if not self._check_robots(url):
            logger.info("Blocked by robots.txt: %s", url)
            return None

        for attempt in range(MAX_RETRIES):
            self._rate_limit(url)
            try:
                resp = self._client.get(url)
                resp.raise_for_status()

                content_type = resp.headers.get("content-type", "")
                if "pdf" not in content_type and not url.lower().endswith(".pdf"):
                    logger.warning("URL does not appear to be a PDF: %s (content-type: %s)", url, content_type)

                pdf_bytes = resp.content
                content_hash = hashlib.sha256(pdf_bytes).hexdigest()

                if archive:
                    self._archive_pdf(url, pdf_bytes, content_hash)

                return pdf_bytes, content_hash

            except httpx.HTTPError as e:
                logger.warning("Fetch attempt %d/%d failed for %s: %s", attempt + 1, MAX_RETRIES, url, e)
                if attempt < MAX_RETRIES - 1:
                    time.sleep(2 ** (attempt + 1))

        return None

    def find_latest_pdf_link(self, bulletin_page_url: str, pdf_link_pattern: str = "") -> str | None:
        """Find the most recent PDF link on a bulletin archive page.

        Args:
            bulletin_page_url: URL of the page containing PDF links.
            pdf_link_pattern: Optional regex to filter PDF links.

        Returns the URL of the latest PDF, or None.
        """
        result = self.fetch_page(bulletin_page_url, archive=False)
        if not result:
            return None

        html, _ = result
        soup = BeautifulSoup(html, "html.parser")

        pdf_links = []
        for a in soup.find_all("a", href=re.compile(r'\.pdf(\?|$)', re.I)):
            href = a["href"]
            full_url = urljoin(bulletin_page_url, href)

            if pdf_link_pattern:
                if not re.search(pdf_link_pattern, href, re.I):
                    continue

            pdf_links.append(full_url)

        if not pdf_links:
            return None

        # Return the last link (typically the most recent on archive pages)
        return pdf_links[-1]

    def _archive_page(self, url: str, html: str, content_hash: str):
        """Archive a fetched HTML page."""
        pages_dir = self.data_dir / "pages"
        pages_dir.mkdir(parents=True, exist_ok=True)

        domain = urlparse(url).netloc.replace(".", "-")
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        filename = f"{domain}_{timestamp}_{content_hash[:8]}.html"

        (pages_dir / filename).write_text(html, encoding="utf-8")
        logger.debug("Archived page: %s", filename)

    def _archive_pdf(self, url: str, pdf_bytes: bytes, content_hash: str):
        """Archive a fetched PDF."""
        bulletins_dir = self.data_dir / "bulletins"
        bulletins_dir.mkdir(parents=True, exist_ok=True)

        # Use content hash to avoid duplicate archives
        filename = f"{content_hash[:16]}.pdf"
        path = bulletins_dir / filename

        if not path.exists():
            path.write_bytes(pdf_bytes)
            logger.debug("Archived PDF: %s", filename)

    def extract_text_from_pdf(self, pdf_bytes: bytes) -> str:
        """Extract text from a PDF using pdfplumber.

        Returns the full text content of the PDF.
        """
        import io
        import pdfplumber

        text_parts = []
        with pdfplumber.open(io.BytesIO(pdf_bytes)) as pdf:
            for page in pdf.pages:
                page_text = page.extract_text()
                if page_text:
                    text_parts.append(page_text)

        return "\n\n".join(text_parts)

    def extract_text_with_coords(self, pdf_bytes: bytes) -> list[dict]:
        """Extract text elements with coordinates from a PDF.

        Returns a list of dicts with keys: page, x0, y0, x1, y1, text, size, fontname.
        """
        import io
        import pdfplumber

        elements = []
        with pdfplumber.open(io.BytesIO(pdf_bytes)) as pdf:
            for page_num, page in enumerate(pdf.pages):
                for char in page.chars:
                    elements.append({
                        "page": page_num,
                        "x0": float(char.get("x0", 0)),
                        "y0": float(char.get("top", 0)),
                        "x1": float(char.get("x1", 0)),
                        "y1": float(char.get("bottom", 0)),
                        "text": char.get("text", ""),
                        "size": float(char.get("size", 0)),
                        "fontname": char.get("fontname", ""),
                    })

        return elements

    def extract_text_from_region(
        self, pdf_bytes: bytes, page_num: int,
        x_min: float, y_min: float, x_max: float, y_max: float,
    ) -> str:
        """Extract text from a specific region of a PDF page.

        Uses pdfplumber's crop functionality.
        """
        import io
        import pdfplumber

        with pdfplumber.open(io.BytesIO(pdf_bytes)) as pdf:
            if page_num >= len(pdf.pages):
                return ""

            page = pdf.pages[page_num]
            cropped = page.crop((x_min, y_min, x_max, y_max))
            text = cropped.extract_text()
            return text or ""
