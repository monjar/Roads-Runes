"""Application settings.

Every environment-specific value lives here and is read from the environment
(or a `.env` file). Never hard-code credentials; never use production
credentials locally.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Literal

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

Environment = Literal["development", "staging", "production", "test"]

ALL_FEATURE_FLAGS: tuple[str, ...] = (
    "wizard_class",
    "warrior_class",
    "scribe_class",
    "party_quests",
    "fog_of_war",
    "story_quests",
    "strava",
    "llm_narrative",
    "nl_route_requests",
)

DEFAULT_FLAGS: dict[str, bool] = {
    "wizard_class": True,
    "warrior_class": True,
    "scribe_class": True,
    "party_quests": False,
    "fog_of_war": True,
    "story_quests": False,
    "strava": False,
    "llm_narrative": False,
    "nl_route_requests": True,
}


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    environment: Environment = "development"
    app_name: str = "Roads & Runes"
    api_prefix: str = "/api/v1"
    log_level: str = "INFO"

    database_url: str = "postgresql+asyncpg://rr:rr@localhost:5432/roadsandrunes"
    database_echo: bool = False
    redis_url: str = "redis://localhost:6379/0"
    graphhopper_url: str = "http://localhost:8989"
    graphhopper_timeout_seconds: float = 20.0
    # "auto": GraphHopper where its graph covers the ride, Valhalla everywhere else
    # (routing/README.md). The public Valhalla server is for development only.
    routing_engine: Literal["auto", "graphhopper", "valhalla", "synthetic"] = "auto"
    valhalla_url: str = "https://valhalla1.openstreetmap.de"
    valhalla_api_key: str = ""
    valhalla_timeout_seconds: float = 30.0
    # Discoveries are imported from OpenStreetMap per area on first use (discoveries/osm_import.py).
    poi_import_enabled: bool = True
    # Place names in a ride request ("a ride in Notting Hill") are resolved by these, in order.
    geocoding_enabled: bool = True
    photon_url: str = "https://photon.komoot.io/api"
    nominatim_url: str = "https://nominatim.openstreetmap.org/search"
    overpass_urls: str = "https://overpass-api.de/api/interpreter,https://overpass.private.coffee/api/interpreter"
    object_storage_url: str = ""

    jwt_secret: str = "change-me-in-real-environments"
    jwt_algorithm: str = "HS256"
    access_token_ttl_seconds: int = 3600
    refresh_token_ttl_days: int = 90

    apple_client_id: str = "com.roadsandrunes.app"
    apple_jwks_url: str = "https://appleid.apple.com/auth/keys"
    apple_issuer: str = "https://appleid.apple.com"
    dev_auth_enabled: bool = False

    h3_resolution: int = 9
    explored_distance_threshold_meters: float = 400.0

    # Reading a rider's typed request is the model's job (app/routing/preferences.py),
    # so this is on by default and falls back to no provider when there is no key.
    llm_provider: Literal["none", "anthropic"] = "anthropic"
    anthropic_api_key: str = ""
    # Reading a ride request is small structured extraction: Haiku scores the same as
    # Sonnet on backend/scripts/eval_requests.py (26/26 on the hard set) and answers
    # faster. Swap in claude-sonnet-5 with ANTHROPIC_MODEL if that ever stops holding.
    anthropic_model: str = "claude-haiku-4-5-20251001"

    strava_client_id: str = ""
    strava_client_secret: str = ""
    strava_redirect_uri: str = "roadsandrunes://strava/callback"

    apns_enabled: bool = False

    feature_flags: str = ""
    job_queue: Literal["inline", "redis"] = "inline"
    rate_limit_per_minute: int = 240

    @field_validator("h3_resolution")
    @classmethod
    def _validate_resolution(cls, value: int) -> int:
        if not 6 <= value <= 11:
            raise ValueError("h3_resolution must be between 6 and 11")
        return value

    @property
    def is_production(self) -> bool:
        return self.environment == "production"

    @property
    def flags(self) -> dict[str, bool]:
        """Resolved feature flags: defaults overridden by FEATURE_FLAGS.

        FEATURE_FLAGS is a comma separated list; `name` enables, `!name` disables.
        """
        resolved = dict(DEFAULT_FLAGS)
        for raw in self.feature_flags.split(","):
            token = raw.strip()
            if not token:
                continue
            if token.startswith("!"):
                resolved[token[1:]] = False
            else:
                resolved[token] = True
        return resolved

    def validate_for_environment(self) -> None:
        if self.is_production:
            if self.dev_auth_enabled:
                raise RuntimeError("DEV_AUTH_ENABLED must be false in production")
            if self.jwt_secret == "change-me-in-real-environments":
                raise RuntimeError("JWT_SECRET must be set in production")


@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    settings.validate_for_environment()
    return settings
