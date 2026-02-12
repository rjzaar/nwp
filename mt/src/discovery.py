"""Parish discovery module for Mass Times scraper.

Discovers Catholic parishes within a radius of a centre point using:
1. Google Places API
2. Melbourne Archdiocese directory scraping
3. MassTimes.org scraping

Also discovers source endpoints (bulletin pages, iCal feeds, etc.)
for each parish.
"""

import hashlib
import json
import logging
import math
import re
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from urllib.parse import urljoin, urlparse

import httpx
from bs4 import BeautifulSoup

from models import Parish, SourceEndpoint, SourceType

logger = logging.getLogger(__name__)

# Minimum delay between requests to same domain (seconds)
REQUEST_DELAY = 2.0

# User-Agent string for polite scraping
USER_AGENT = "NWP-MassTimesScraper/1.0 (+https://mt.nwpcode.org; Catholic mass times aggregator)"


def haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Calculate distance in km between two lat/lng points using Haversine formula."""
    R = 6371.0  # Earth radius in km
    lat1_r, lat2_r = math.radians(lat1), math.radians(lat2)
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = math.sin(dlat / 2) ** 2 + math.cos(lat1_r) * math.cos(lat2_r) * math.sin(dlng / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def slug_from_name(name: str) -> str:
    """Generate a URL-safe slug from a parish name.

    'Sacred Heart Parish, Croydon' -> 'sacred-heart-croydon'
    """
    # Remove common suffixes
    name = re.sub(r'\s*(Catholic\s*)?(Parish|Church|Community)\s*', ' ', name, flags=re.IGNORECASE)
    name = name.lower().strip()
    name = re.sub(r'[^a-z0-9\s-]', '', name)
    name = re.sub(r'\s+', '-', name)
    name = re.sub(r'-+', '-', name)
    return name.strip('-')


@dataclass
class DiscoveryResult:
    """Result of a parish discovery run."""
    parishes: list[Parish] = field(default_factory=list)
    endpoints: list[SourceEndpoint] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)


class ParishDiscovery:
    """Discovers Catholic parishes and their mass times sources."""

    def __init__(
        self,
        centre_lat: float = -37.8131,
        centre_lng: float = 145.2285,
        radius_km: float = 20.0,
        google_api_key: str = "",
    ):
        self.centre_lat = centre_lat
        self.centre_lng = centre_lng
        self.radius_km = radius_km
        self.google_api_key = google_api_key
        self._last_request_by_domain: dict[str, float] = {}
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

    def _fetch(self, url: str) -> httpx.Response | None:
        """Fetch a URL with rate limiting and error handling."""
        self._rate_limit(url)
        try:
            resp = self._client.get(url)
            resp.raise_for_status()
            return resp
        except httpx.HTTPError as e:
            logger.warning("Failed to fetch %s: %s", url, e)
            return None

    def discover_google_places(self) -> list[Parish]:
        """Discover parishes via Google Places API.

        Requires a valid google_api_key.
        """
        if not self.google_api_key:
            logger.info("No Google API key configured, skipping Places discovery")
            return []

        parishes = []
        url = "https://maps.googleapis.com/maps/api/place/nearbysearch/json"
        params = {
            "location": f"{self.centre_lat},{self.centre_lng}",
            "radius": int(self.radius_km * 1000),
            "keyword": "Catholic Church",
            "type": "church",
            "key": self.google_api_key,
        }

        while True:
            try:
                resp = self._client.get(url, params=params)
                resp.raise_for_status()
                data = resp.json()
            except httpx.HTTPError as e:
                logger.error("Google Places API error: %s", e)
                break

            for place in data.get("results", []):
                loc = place.get("geometry", {}).get("location", {})
                lat = loc.get("lat", 0)
                lng = loc.get("lng", 0)
                distance = haversine_km(self.centre_lat, self.centre_lng, lat, lng)

                parish = Parish(
                    id=slug_from_name(place.get("name", "")),
                    name=place.get("name", ""),
                    address=place.get("vicinity", ""),
                    lat=lat,
                    lng=lng,
                    distance_km=round(distance, 2),
                )
                parishes.append(parish)

            # Handle pagination
            next_token = data.get("next_page_token")
            if not next_token:
                break
            time.sleep(2)  # Google requires delay before using next_page_token
            params = {"pagetoken": next_token, "key": self.google_api_key}

        logger.info("Google Places: found %d parishes", len(parishes))
        return parishes

    def discover_archdiocese(self) -> list[Parish]:
        """Discover parishes from the Melbourne Archdiocese directory.

        Scrapes melbournecatholic.org parish listings.
        """
        parishes = []
        url = "https://melbournecatholic.org/parishes"

        resp = self._fetch(url)
        if not resp:
            logger.warning("Could not access archdiocese directory")
            return []

        soup = BeautifulSoup(resp.text, "html.parser")

        # Look for parish listing links
        for link in soup.find_all("a", href=True):
            text = link.get_text(strip=True)
            href = link["href"]

            # Parish links typically contain parish names
            if not re.search(r'parish|church|catholic', href, re.IGNORECASE):
                continue
            if len(text) < 3:
                continue

            parish = Parish(
                id=slug_from_name(text),
                name=text,
                website=urljoin(url, href),
            )
            parishes.append(parish)

        logger.info("Archdiocese directory: found %d parishes", len(parishes))
        return parishes

    def discover_masstimes_org(self) -> list[Parish]:
        """Discover parishes from MassTimes.org.

        Searches for parishes near the centre coordinates.
        """
        parishes = []
        url = (
            f"https://masstimes.org/search"
            f"?lat={self.centre_lat}&lng={self.centre_lng}"
            f"&radius={int(self.radius_km)}"
        )

        resp = self._fetch(url)
        if not resp:
            logger.warning("Could not access MassTimes.org")
            return []

        soup = BeautifulSoup(resp.text, "html.parser")

        # Parse search results — structure varies, use flexible matching
        for item in soup.find_all(["div", "article", "li"], class_=re.compile(r'parish|church|result', re.I)):
            name_el = item.find(["h2", "h3", "h4", "a", "strong"])
            if not name_el:
                continue
            name = name_el.get_text(strip=True)
            if not name:
                continue

            address_el = item.find(class_=re.compile(r'address|location', re.I))
            address = address_el.get_text(strip=True) if address_el else ""

            parish = Parish(
                id=slug_from_name(name),
                name=name,
                address=address,
            )
            parishes.append(parish)

        logger.info("MassTimes.org: found %d parishes", len(parishes))
        return parishes

    def deduplicate(self, all_parishes: list[Parish]) -> list[Parish]:
        """Deduplicate parishes by name similarity and proximity.

        Two entries within 100m are treated as duplicates. The entry
        with more metadata is kept.
        """
        result = []

        for parish in all_parishes:
            is_dup = False
            for existing in result:
                # Name similarity check
                name_match = (
                    existing.id == parish.id
                    or existing.name.lower() == parish.name.lower()
                )

                # Proximity check (if both have coordinates)
                close = False
                if parish.lat and parish.lng and existing.lat and existing.lng:
                    dist = haversine_km(existing.lat, existing.lng, parish.lat, parish.lng)
                    close = dist < 0.1  # 100m

                if name_match or close:
                    # Merge: keep the one with more data
                    if not existing.website and parish.website:
                        existing.website = parish.website
                    if not existing.address and parish.address:
                        existing.address = parish.address
                    if not existing.lat and parish.lat:
                        existing.lat = parish.lat
                        existing.lng = parish.lng
                    if not existing.phone and parish.phone:
                        existing.phone = parish.phone
                    is_dup = True
                    break

            if not is_dup:
                result.append(parish)

        logger.info("After dedup: %d parishes (from %d)", len(result), len(all_parishes))
        return result

    def discover_sources(self, parish: Parish) -> list[SourceEndpoint]:
        """Discover source endpoints for a single parish.

        Crawls the parish website to find bulletin pages, mass times pages,
        iCal feeds, structured data, and platform indicators.
        """
        endpoints = []

        if not parish.website:
            return endpoints

        resp = self._fetch(parish.website)
        if not resp:
            return endpoints

        soup = BeautifulSoup(resp.text, "html.parser")
        base_url = parish.website

        # 1. Check for iCal feeds
        for link in soup.find_all("link", rel="alternate"):
            if link.get("type") in ("text/calendar", "application/calendar+xml"):
                url = urljoin(base_url, link.get("href", ""))
                endpoints.append(SourceEndpoint(
                    parish_id=parish.id,
                    source_type=SourceType.ICAL_FEED,
                    url=url,
                    is_primary=True,
                    check_frequency_hours=168,  # Weekly for iCal
                ))

        # Check for .ics links in page
        for a in soup.find_all("a", href=re.compile(r'\.ics(\?|$)', re.I)):
            url = urljoin(base_url, a["href"])
            endpoints.append(SourceEndpoint(
                parish_id=parish.id,
                source_type=SourceType.ICAL_FEED,
                url=url,
                check_frequency_hours=168,
            ))

        # 2. Check for structured data (JSON-LD)
        for script in soup.find_all("script", type="application/ld+json"):
            try:
                data = json.loads(script.string or "")
                if isinstance(data, dict):
                    data = [data]
                for item in (data if isinstance(data, list) else []):
                    schema_type = item.get("@type", "")
                    if schema_type in ("Church", "CatholicChurch", "PlaceOfWorship", "Event"):
                        endpoints.append(SourceEndpoint(
                            parish_id=parish.id,
                            source_type=SourceType.STRUCTURED_DATA,
                            url=base_url,
                            is_primary=True,
                        ))
                        break
            except (json.JSONDecodeError, TypeError):
                pass

        # 3. Find mass times / bulletin pages
        mass_times_url = None
        bulletin_url = None

        for a in soup.find_all("a", href=True):
            text = a.get_text(strip=True).lower()
            href = a["href"]
            full_url = urljoin(base_url, href)

            # Mass times page
            if re.search(r'mass\s*times?|liturgy|schedule\s*of\s*mass|mass\s*schedule', text):
                if not mass_times_url:
                    mass_times_url = full_url

            # Bulletin / newsletter page
            if re.search(r'bulletin|newsletter|parish\s*news', text):
                if not bulletin_url:
                    bulletin_url = full_url

            # Direct PDF bulletin link
            if re.search(r'\.pdf(\?|$)', href, re.I) and re.search(r'bulletin|newsletter', text + href, re.I):
                endpoints.append(SourceEndpoint(
                    parish_id=parish.id,
                    source_type=SourceType.PDF_BULLETIN,
                    url=full_url,
                ))

        if mass_times_url:
            endpoints.append(SourceEndpoint(
                parish_id=parish.id,
                source_type=SourceType.WEBSITE_PAGE,
                url=mass_times_url,
                is_primary=True,
            ))

        if bulletin_url:
            # Check if the bulletin page has PDF links
            self._discover_bulletin_pdfs(parish, bulletin_url, endpoints)

        # 4. Set primary if no primary yet
        if endpoints and not any(e.is_primary for e in endpoints):
            # Pick the highest-priority source
            endpoints.sort(key=lambda e: e.source_type.priority)
            endpoints[0].is_primary = True

        return endpoints

    def _discover_bulletin_pdfs(
        self, parish: Parish, bulletin_url: str, endpoints: list[SourceEndpoint]
    ):
        """Fetch a bulletin archive page and find PDF links."""
        resp = self._fetch(bulletin_url)
        if not resp:
            return

        soup = BeautifulSoup(resp.text, "html.parser")
        pdf_count = 0

        for a in soup.find_all("a", href=re.compile(r'\.pdf(\?|$)', re.I)):
            url = urljoin(bulletin_url, a["href"])
            # Only add if not already discovered
            if not any(e.url == url for e in endpoints):
                endpoints.append(SourceEndpoint(
                    parish_id=parish.id,
                    source_type=SourceType.PDF_BULLETIN,
                    url=url,
                ))
                pdf_count += 1

        if pdf_count > 0:
            logger.info("Found %d bulletin PDFs for %s", pdf_count, parish.name)

    def run(self) -> DiscoveryResult:
        """Run full parish discovery pipeline.

        1. Discover from all sources
        2. Deduplicate
        3. Calculate distances
        4. Filter by radius
        5. Discover source endpoints for each parish
        """
        result = DiscoveryResult()

        # Step 1: Discover from all sources
        all_parishes = []

        try:
            all_parishes.extend(self.discover_google_places())
        except Exception as e:
            result.errors.append(f"Google Places: {e}")

        try:
            all_parishes.extend(self.discover_archdiocese())
        except Exception as e:
            result.errors.append(f"Archdiocese: {e}")

        try:
            all_parishes.extend(self.discover_masstimes_org())
        except Exception as e:
            result.errors.append(f"MassTimes.org: {e}")

        # Step 2: Deduplicate
        parishes = self.deduplicate(all_parishes)

        # Step 3: Calculate distances for parishes with coordinates
        for p in parishes:
            if p.lat and p.lng:
                p.distance_km = round(
                    haversine_km(self.centre_lat, self.centre_lng, p.lat, p.lng), 2
                )

        # Step 4: Filter by radius (keep parishes with coords within radius,
        # and all parishes without coords for manual review)
        filtered = []
        for p in parishes:
            if p.lat and p.lng:
                if p.distance_km <= self.radius_km:
                    filtered.append(p)
                elif p.distance_km <= self.radius_km + 2:
                    # Boundary parishes (18-22km) — include for review
                    filtered.append(p)
            else:
                # No coords — include for manual review
                filtered.append(p)

        # Sort by distance
        filtered.sort(key=lambda p: p.distance_km)
        result.parishes = filtered

        # Step 5: Discover source endpoints
        for p in filtered:
            try:
                endpoints = self.discover_sources(p)
                result.endpoints.extend(endpoints)
            except Exception as e:
                result.errors.append(f"Source discovery for {p.name}: {e}")

        logger.info(
            "Discovery complete: %d parishes, %d endpoints, %d errors",
            len(result.parishes), len(result.endpoints), len(result.errors),
        )

        return result

    def save_results(self, result: DiscoveryResult, output_dir: Path):
        """Save discovery results to JSON files."""
        output_dir.mkdir(parents=True, exist_ok=True)

        parishes_data = []
        for p in result.parishes:
            parishes_data.append({
                "id": p.id,
                "name": p.name,
                "address": p.address,
                "lat": p.lat,
                "lng": p.lng,
                "distance_km": p.distance_km,
                "website": p.website,
                "phone": p.phone,
                "email": p.email,
                "status": p.status.value,
            })

        endpoints_data = []
        for e in result.endpoints:
            endpoints_data.append({
                "parish_id": e.parish_id,
                "source_type": e.source_type.value,
                "url": e.url,
                "is_primary": e.is_primary,
                "check_frequency_hours": e.check_frequency_hours,
            })

        with open(output_dir / "parishes.json", "w") as f:
            json.dump(parishes_data, f, indent=2)

        with open(output_dir / "endpoints.json", "w") as f:
            json.dump(endpoints_data, f, indent=2)

        if result.errors:
            with open(output_dir / "discovery_errors.json", "w") as f:
                json.dump(result.errors, f, indent=2)

        logger.info("Results saved to %s", output_dir)
