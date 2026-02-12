"""Data models for Mass Times scraper."""

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class SourceType(Enum):
    """Source types in priority order (lower = more reliable)."""
    ICAL_FEED = "ical_feed"
    STRUCTURED_DATA = "structured_data"
    WEBSITE_PAGE = "website_page"
    PDF_BULLETIN = "pdf_bulletin"
    FACEBOOK_PAGE = "facebook_page"

    @property
    def priority(self) -> int:
        order = [
            self.ICAL_FEED, self.STRUCTURED_DATA,
            self.WEBSITE_PAGE, self.PDF_BULLETIN, self.FACEBOOK_PAGE,
        ]
        return order.index(self)


class ExtractionTier(Enum):
    TIER1_STATIC = 1
    TIER2_CODE = 2
    TIER3_LLM = 3


class ValidationStatus(Enum):
    CONFIRMED = "confirmed"
    PROVISIONAL = "provisional"
    FLAGGED = "flagged"


class ParishStatus(Enum):
    ACTIVE = "active"
    CLOSED = "closed"
    MERGED = "merged"


@dataclass
class Parish:
    """A Catholic parish."""
    id: str  # slug, e.g. "sacred-heart-croydon"
    name: str
    address: str = ""
    lat: float = 0.0
    lng: float = 0.0
    distance_km: float = 0.0
    website: str = ""
    phone: str = ""
    email: str = ""
    archdiocese_id: str = ""
    status: ParishStatus = ParishStatus.ACTIVE


@dataclass
class SourceEndpoint:
    """A discovered source for a parish's mass times."""
    parish_id: str
    source_type: SourceType
    url: str
    is_primary: bool = False
    check_frequency_hours: int = 48
    status: str = "active"


@dataclass
class MassTime:
    """A single mass time entry."""
    day: str  # Monday, Tuesday, ..., Sunday
    time: str  # HH:MM AM/PM format
    mass_type: str = "Regular"  # Regular, Vigil, Holy Day, Reconciliation, etc.
    language: str = "English"
    notes: str = ""
    effective_from: str | None = None
    effective_until: str | None = None


@dataclass
class ExtractionResult:
    """Result of a mass times extraction."""
    parish_id: str
    times: list[MassTime] = field(default_factory=list)
    tier: ExtractionTier = ExtractionTier.TIER1_STATIC
    confidence: float = 1.0
    validation_status: ValidationStatus = ValidationStatus.CONFIRMED
    source_url: str = ""
    source_type: SourceType = SourceType.WEBSITE_PAGE
    content_hash: str = ""
    raw_content_path: str = ""
    llm_model: str | None = None
    llm_cost_usd: float = 0.0
    extracted_at: datetime = field(default_factory=datetime.now)
    changes_from_previous: list[str] = field(default_factory=list)
