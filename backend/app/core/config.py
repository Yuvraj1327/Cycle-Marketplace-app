import json
from functools import lru_cache
from typing import Annotated

from pydantic import field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict

# Local dev servers of the admin console (Vite uses 5173, and 5174 when 5173 is taken).
DEFAULT_DEV_ORIGINS = ["http://localhost:5173", "http://localhost:5174", "http://127.0.0.1:5173", "http://127.0.0.1:5174"]


def parse_origins(value: object) -> list[str]:
    """CORS_ORIGINS may be a JSON list (["https://a","https://b"]) or comma separated (https://a,https://b), as people type it into Railway.
    Each entry is trimmed and loses a trailing slash (browsers never send one in `Origin`). A wildcard is refused: origins must be explicit."""
    if value is None or value == "":
        return []
    if isinstance(value, str):
        text = value.strip()
        items = json.loads(text) if text.startswith("[") else text.split(",")
    else:
        items = list(value)  # type: ignore[call-overload]
    origins = [str(o).strip().rstrip("/") for o in items if str(o).strip()]
    if "*" in origins:
        raise ValueError('CORS_ORIGINS must list explicit origins; "*" is not allowed.')
    return list(dict.fromkeys(origins))


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "Cycle Marketplace API"
    app_env: str = "development"
    debug: bool = False
    api_v1_prefix: str = "/api/v1"
    # Browser origins allowed to call this API (the admin console). In production set CORS_ORIGINS to the real https admin origin(s).
    cors_origins: Annotated[list[str], NoDecode] = DEFAULT_DEV_ORIGINS

    supabase_url: str = ""
    supabase_anon_key: str = ""
    supabase_service_role_key: str = ""

    # JWT verification. Asymmetric signing keys (RS256/ES256) are verified against the project's JWKS endpoint
    # and need no secret. SUPABASE_JWT_SECRET is only for projects still on the legacy shared HS256 secret.
    supabase_jwt_secret: str = ""
    jwt_audience: str = "authenticated"
    jwt_leeway_seconds: int = 5
    jwks_cache_seconds: int = 600

    # payments. No provider has been chosen yet: leaving PAYMENT_PROVIDER empty means "online payments not configured".
    payment_provider: str = ""
    payment_provider_key_id: str = ""        # public/key id of the provider account
    payment_provider_key_secret: str = ""    # secret API key - server side only
    payment_webhook_secret: str = ""         # used to verify webhook signatures
    currency: str = "INR"

    # push notifications (Firebase Cloud Messaging). Leave empty until the client has a Firebase project: push is then reported as "not configured".
    # Provide EITHER the service-account JSON inline OR a path to the key file. These are server-only secrets.
    fcm_project_id: str = ""
    fcm_service_account_json: str = ""
    fcm_service_account_file: str = ""
    fcm_android_channel_id: str = "cycle_default"
    push_dispatch_interval_seconds: int = 15      # in-process dispatcher period; 0 disables the background loop (the admin endpoint can still dispatch)
    push_batch_size: int = 50
    push_max_attempts: int = 5
    push_max_age_hours: int = 24                  # an older notification is never pushed (it stays in the in-app list)
    business_timezone: str = "Asia/Kolkata"   # 'today' and slot times for servicing are evaluated in this zone
    max_booking_images: int = 5

    # marketplace limits
    max_product_images: int = 8
    max_image_bytes: int = 5 * 1024 * 1024
    max_cart_items: int = 50
    max_wishlist_items: int = 200

    @field_validator("cors_origins", mode="before")
    @classmethod
    def _normalise_origins(cls, v: object) -> list[str]:
        return parse_origins(v)

    @property
    def jwt_issuer(self) -> str:
        return f"{self.supabase_url.rstrip('/')}/auth/v1"

    @property
    def jwks_url(self) -> str:
        return f"{self.jwt_issuer}/.well-known/jwks.json"

    @property
    def supabase_configured(self) -> bool:
        return bool(self.supabase_url and self.supabase_anon_key and self.supabase_service_role_key)


@lru_cache
def get_settings() -> Settings:
    return Settings()
