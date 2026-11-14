"""Application settings: environment variables first, then backend/.env (PRD §9.1).

Model names and provider keys are pinned here from the environment, never in business code.

Fail-closed rules (enforced by the validator below, the process refuses to start otherwise):

* ``JWT_SECRET`` is required and must be at least 32 bytes.
* ``AUTH_MODE`` is required (no default). ``dev`` is only allowed when ``ENVIRONMENT`` is ``dev``
  or ``test``. **Production deploys must set ``ENVIRONMENT=prod`` and ``AUTH_MODE=apple``.**
  ``ENVIRONMENT`` defaults to ``dev`` because an unset value means a local checkout.
* ``ENVIRONMENT=prod`` also needs the four AI cost-guard caps stated explicitly and above zero,
  every request rate limit on, and ``CLIENT_IP_HEADER`` set (brief 010).
* ``DEV_LOGIN_ECHO_CODE`` (returns the sign-in code in the API response) is only allowed when
  ``ENVIRONMENT=test``; it exists so integration tests can drive the two-step dev login.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_DIR = Path(__file__).resolve().parents[2]
REPO_DIR = BACKEND_DIR.parent

APP_VERSION = "0.1.0"
MIN_JWT_SECRET_BYTES = 32
MIN_REVIEW_CODE_CHARS = 20
# Matches the MinIO container in backend/docker-compose.yml; refused in prod.
DEV_STORAGE_ACCESS_KEY = "umma-dev"
DEV_STORAGE_SECRET_KEY = "umma-dev-secret"
PROD_REQUIRED_CAPS = (
    "ai_user_daily_cap_usd",
    "ai_user_daily_live_cap_usd",
    "ai_month_soft_cap_usd",
    "ai_month_hard_cap_usd",
)
PROD_REQUIRED_RATE_LIMITS = (
    "rate_limit_sign_in_per_ip_per_minute",
    "rate_limit_per_ip_per_minute",
    "rate_limit_per_user_per_minute",
    "rate_limit_costly_per_user_per_minute",
)


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=BACKEND_DIR / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_name: str = "umma"
    app_version: str = APP_VERSION
    environment: Literal["dev", "test", "prod"] = "dev"
    log_level: str = "INFO"

    database_url: str = "postgresql+asyncpg://umma:umma@localhost:5433/umma"
    test_database_url: str = "postgresql+asyncpg://umma:umma@localhost:5433/umma_test"
    db_echo: bool = False

    jwt_secret: str
    jwt_algorithm: Literal["HS256"] = "HS256"
    jwt_ttl_days: int = 30

    auth_mode: Literal["dev", "apple"]
    # Sign in with Apple (brief 010): identity tokens must be issued for this bundle id.
    apple_bundle_id: str = "com.umma.ios"
    apple_keys_url: str = "https://appleid.apple.com/auth/keys"
    # Apple token revoke on account deletion (brief 010 PR 2, guideline 5.1.1(v)). All three
    # are optional: without them sign-in still works, no refresh token is stored, and account
    # deletion skips the revoke (logged). The key is the Sign in with Apple .p8 file's text.
    apple_team_id: str | None = None
    apple_key_id: str | None = None
    apple_private_key: SecretStr | None = None
    apple_token_url: str = "https://appleid.apple.com/auth/token"
    apple_revoke_url: str = "https://appleid.apple.com/auth/revoke"
    # Review login for Apple's Beta App Review (brief 010 PR 3): one fixed account behind this
    # secret code. Unset (or empty) means POST /v1/auth/review does not exist.
    review_login_code: SecretStr | None = None
    rate_limit_review_login_per_ip_per_minute: int = Field(default=5, ge=1)
    rate_limit_review_login_total_per_minute: int = Field(default=30, ge=1)
    # Sign in with Google (DECISIONS #33): the iOS OAuth client id ID tokens must be issued for.
    # Not a secret. Unset means the Google route does not exist.
    google_ios_client_id: str | None = None
    google_keys_url: str = "https://www.googleapis.com/oauth2/v3/certs"
    dev_login_echo_code: bool = False
    # Brute-force budget for the dev sign-in code (per email, across challenges).
    dev_login_cooldown_seconds: int = 30
    dev_login_lockout_window_minutes: int = 15
    dev_login_max_failures_per_window: int = 10
    # Request rate limits (brief 010), per minute, counted in the web process
    # (app/core/ratelimit.py). 0 switches a limit off, which is refused in prod.
    rate_limit_sign_in_per_ip_per_minute: int = Field(default=10, ge=0)
    rate_limit_per_ip_per_minute: int = Field(default=600, ge=0)
    rate_limit_per_user_per_minute: int = Field(default=300, ge=0)
    rate_limit_costly_per_user_per_minute: int = Field(default=60, ge=0)
    # The header the hosting proxy sets to the caller's address (Fly: ``Fly-Client-IP``).
    # Unset means the peer address is used, which is only right without a proxy in front.
    client_ip_header: str | None = None
    ai_provider: Literal["mock", "gemini"] = "mock"
    # Brief 012 tier plumbing (DECISIONS #22): every account gets this entitlement until
    # purchases exist. The beta runs everyone on ``paid``; there is no per-user column yet.
    default_entitlement: Literal["free", "paid"] = "paid"

    # Gemini (Slice 4, DECISIONS #19). The key is a SecretStr: it never appears in reprs, logs
    # or error bodies, and it never leaves the backend. Each capability has its own model so a
    # price or quality change can be made per feature; ids are re-verified at build time.
    gemini_api_key: SecretStr | None = None
    # Brief 019 stock photos. Optional: without a key, Pexels lookups are skipped. A SecretStr,
    # so it never appears in reprs or logs; it is only sent in Pexels' Authorization header.
    pexels_api_key: SecretStr | None = None
    pexels_timeout_seconds: float = Field(default=5.0, gt=0, le=30)
    gemini_model_coach: str = "gemini-3.8-flash"
    gemini_model_inspect: str = "gemini-3.8-flash"
    gemini_model_substitution: str = "gemini-3.8-flash"
    gemini_model_pantry: str = "gemini-3.5-flash-lite"
    gemini_model_video: str = "gemini-3.8-flash"  # brief 008
    gemini_model_capture: str = "gemini-3.8-flash"  # brief 014 interviewer + draft
    gemini_model_live: str = "gemini-3.8-live"  # brief 016 live pantry scan (phone-side session)
    # Brief 014: a capture transcript nobody published is deleted after this many idle days.
    capture_transcript_ttl_days: int = Field(default=30, ge=1, le=365)
    # Whole-call deadline for interactive features, retries included (brief 007).
    gemini_timeout_seconds: float = Field(default=18.0, gt=0, le=60)

    # Cost guard (DECISIONS #18/#19): per-user UTC-day cap, then the global UTC-month soft
    # degrade (video extraction off) and hard stop (labelled mock fallback for everything).
    ai_user_daily_cap_usd: float = Field(default=0.50, ge=0)
    # Live pantry scan's own per-user UTC-day allowance (brief 016, PM 2026-11-13): 2 full
    # scans ≈ 8 sessions x $0.141. Live spend is outside the cap above, inside the monthly caps.
    ai_user_daily_live_cap_usd: float = Field(default=1.15, ge=0)
    ai_month_soft_cap_usd: float = Field(default=15.0, ge=0)
    ai_month_hard_cap_usd: float = Field(default=22.0, ge=0)

    # Live pantry scan (brief 016). The phone gets a single-use token; the server can't see live
    # usage, so each token reserves a worst-case session and settles at that ceiling. The ceiling
    # covers the token's whole lifetime (not just LIVE_MAX_SESSION_SECONDS), so a client that
    # ignores the session limit is still paid for. Spike: 9 nudged turns billed ~43k prompt tokens
    # in 36 s; with a nudge every 2 frames plus silent audio we assume ~70k prompt + 2k output
    # (audio) tokens per 30 s, i.e. 105k + 3k over the 45 s lifetime. iOS rotates sessions every
    # LIVE_MAX_SESSION_SECONDS and fetches a new token for each one.
    live_token_ttl_seconds: int = Field(default=45, ge=30, le=1800)
    live_token_start_seconds: int = Field(default=15, ge=10, le=600)
    live_max_session_seconds: int = Field(default=30, ge=5, le=600)
    live_nudge_text: str = "Report any new items now visible."
    live_nudge_every_frames: int = Field(default=2, ge=1, le=30)
    live_frame_max_fps: float = Field(default=1.0, gt=0, le=2)
    live_ceiling_input_tokens: int = Field(default=105_000, ge=0)
    live_ceiling_output_tokens: int = Field(default=3_000, ge=0)
    live_tokens_per_user_per_hour: int = Field(default=60, ge=0)
    live_token_timeout_seconds: float = Field(default=8.0, gt=0, le=30)

    # Paid server voice (brief 012 PR 2, DECISIONS #26): Deepgram speech-to-text and turn
    # detection, ElevenLabs voice. Keys are optional; without them the voice routes answer
    # "unavailable" and the phone stays on the on-device (Free) pipeline. Backend only.
    # Master switch, off by default: server voice spends money, so it stays dark (routes answer
    # VOICE_UNAVAILABLE even with keys set) until the PM's go (DECISIONS #26). It gates only
    # server voice, never the Free/Paid entitlement other server AI features read.
    paid_voice_enabled: bool = False
    deepgram_api_key: SecretStr | None = None
    deepgram_model: str = "nova-3"
    # Deepgram turn detection: silence that ends a phrase, and the gap that ends an utterance.
    deepgram_endpointing_ms: int = Field(default=300, ge=10, le=5000)
    deepgram_utterance_end_ms: int = Field(default=1000, ge=1000, le=5000)
    elevenlabs_api_key: SecretStr | None = None
    elevenlabs_voice_id: str | None = None
    # Flash v2.5: ElevenLabs' low-latency model (~75 ms model time), half the price of v2/v3.
    elevenlabs_model: str = "eleven_flash_v2_5"
    elevenlabs_output_format: Literal["pcm_16000", "pcm_22050", "pcm_24000"] = "pcm_24000"
    voice_tts_timeout_seconds: float = Field(default=20.0, gt=0, le=120)
    # WS /v1/voice/stream limits.
    voice_max_session_seconds: int = Field(default=60 * 60, ge=10)
    voice_idle_timeout_seconds: int = Field(default=60, ge=5)
    voice_max_streams_per_user: int = Field(default=1, ge=1, le=5)
    voice_max_frame_bytes: int = Field(default=16_000, ge=640)  # 0.5 s of 16 kHz s16le mono
    # A stream that sends keepalives but no audio this long is closed (the phone reopens it).
    voice_no_audio_timeout_seconds: int = Field(default=300, ge=10)
    # keepalive / finalize / other text frames per second before the stream is closed.
    voice_max_controls_per_second: int = Field(default=10, ge=1)
    # POST /v1/voice/speak limits.
    voice_speak_max_chars: int = Field(default=600, ge=1, le=5000)
    voice_speak_per_minute: int = Field(default=20, ge=1)

    media_root: Path = BACKEND_DIR / "media"
    ffmpeg_path: str = "ffmpeg"
    ffprobe_path: str = "ffprobe"

    # Object storage (brief 008): any S3-compatible store. Production is Tigris
    # (https://t3.storage.dev, region "auto", virtual-hosted addressing); dev is the MinIO
    # container in docker-compose. The dev credentials below only match that container and are
    # refused when ENVIRONMENT=prod. No media bytes ever live in Postgres.
    storage_endpoint_url: str | None = "http://localhost:9000"
    # Host the *phone* uses for presigned URLs when it differs from the backend's own route to
    # the store (e.g. a LAN IP for a device build in dev). Defaults to storage_endpoint_url.
    storage_public_endpoint_url: str | None = None
    storage_bucket: str = "umma-media"
    storage_region: str = "auto"
    storage_addressing_style: Literal["path", "virtual", "auto"] = "path"
    storage_access_key_id: SecretStr = SecretStr(DEV_STORAGE_ACCESS_KEY)
    storage_secret_access_key: SecretStr = SecretStr(DEV_STORAGE_SECRET_KEY)
    storage_upload_url_ttl_seconds: int = Field(default=900, ge=60, le=3600)
    storage_download_url_ttl_seconds: int = Field(default=3600, ge=60, le=12 * 3600)

    # CAP-01 limits for a creator's own video (brief 008).
    video_max_bytes: int = Field(default=200 * 1024 * 1024, gt=0)
    video_max_duration_ms: int = Field(default=15 * 60 * 1000, gt=0)
    # DECISIONS #19: 5 video extractions per user (counted per UTC month).
    ai_user_video_extractions_per_month: int = Field(default=5, ge=0)
    # Storage abuse caps (fix round 1): unconfirmed uploads in flight, and source bytes per UTC
    # month (declared size, counted at intent time, never refunded).
    video_max_pending_uploads: int = Field(default=2, ge=1)
    video_upload_bytes_per_month: int = Field(default=1024 * 1024 * 1024, gt=0)
    # Brief 019 cover photos: JPEG only; bytes count toward the same monthly upload budget.
    cover_max_bytes: int = Field(default=10 * 1024 * 1024, gt=0)
    cover_max_pending_uploads: int = Field(default=5, ge=1)

    # Extraction worker (``python -m app.workers.extraction``).
    worker_lease_seconds: int = Field(default=120, ge=10)
    worker_poll_seconds: float = Field(default=2.0, gt=0)
    worker_max_attempts: int = Field(default=3, ge=1, le=10)
    worker_workdir: Path | None = None  # default: a temp dir per process
    # Gemini video: Files API processing wait, then the generate deadline (retries included).
    gemini_file_active_timeout_seconds: float = Field(default=180.0, gt=0)
    gemini_video_timeout_seconds: float = Field(default=300.0, gt=0, le=900)

    fixtures_dir: Path = REPO_DIR / "fixtures"

    # Public share link base (brief 003): share_url = f"{share_url_base}/{recipe_id}".
    # The domain is not live yet; the iOS app also accepts umma://recipe/{recipe_id}.
    share_url_base: str = "https://umma.app/r"

    cors_origins: list[str] = Field(default_factory=list)

    @field_validator("review_login_code", mode="before")
    @classmethod
    def _empty_review_code_is_unset(cls, value: object) -> object:
        return None if value == "" else value

    @model_validator(mode="after")
    def _refuse_insecure_configuration(self) -> Settings:
        if (
            self.review_login_code is not None
            and len(self.review_login_code.get_secret_value()) < MIN_REVIEW_CODE_CHARS
        ):
            raise ValueError(
                f"REVIEW_LOGIN_CODE must be at least {MIN_REVIEW_CODE_CHARS} characters "
                "(generate one: openssl rand -base64 24)"
            )
        if len(self.jwt_secret.encode("utf-8")) < MIN_JWT_SECRET_BYTES:
            raise ValueError(
                f"JWT_SECRET must be at least {MIN_JWT_SECRET_BYTES} bytes (RFC 7518 §3.2)"
            )
        if self.jwt_secret.lower().startswith("change-me"):
            raise ValueError(
                "JWT_SECRET is the .env.example placeholder; run `make env` to generate one"
            )
        if self.auth_mode == "dev" and self.environment not in ("dev", "test"):
            raise ValueError("AUTH_MODE=dev is only allowed when ENVIRONMENT is dev or test")
        if not self.apple_keys_url.startswith("https://"):
            raise ValueError("APPLE_KEYS_URL must be https://")
        if not (
            self.apple_token_url.startswith("https://")
            and self.apple_revoke_url.startswith("https://")
        ):
            raise ValueError("APPLE_TOKEN_URL and APPLE_REVOKE_URL must be https://")
        if not self.google_keys_url.startswith("https://"):
            raise ValueError("GOOGLE_KEYS_URL must be https://")
        if self.ai_month_soft_cap_usd > self.ai_month_hard_cap_usd:
            raise ValueError("AI_MONTH_SOFT_CAP_USD must not exceed AI_MONTH_HARD_CAP_USD")
        if self.live_token_start_seconds > self.live_token_ttl_seconds:
            raise ValueError("LIVE_TOKEN_START_SECONDS must not exceed LIVE_TOKEN_TTL_SECONDS")
        if self.live_max_session_seconds > self.live_token_ttl_seconds:
            raise ValueError("LIVE_MAX_SESSION_SECONDS must not exceed LIVE_TOKEN_TTL_SECONDS")
        if self.dev_login_echo_code and self.environment != "test":
            raise ValueError("DEV_LOGIN_ECHO_CODE=true is only allowed when ENVIRONMENT=test")
        if self.environment == "prod" and (
            self.storage_access_key_id.get_secret_value() == DEV_STORAGE_ACCESS_KEY
            or self.storage_secret_access_key.get_secret_value() == DEV_STORAGE_SECRET_KEY
        ):
            raise ValueError("Set real STORAGE_ACCESS_KEY_ID / STORAGE_SECRET_ACCESS_KEY in prod")
        if self.environment == "prod" and not (self.storage_endpoint_url or "").startswith(
            "https://"
        ):
            raise ValueError("STORAGE_ENDPOINT_URL must be https:// in prod")
        if self.environment == "prod":
            self._refuse_unguarded_production()
        return self

    def _refuse_unguarded_production(self) -> None:
        """Brief 010: production must state its spend caps and keep every rate limit on."""
        for name in PROD_REQUIRED_CAPS:
            # A default is not enough: the deploy config has to state each cap (fly.toml [env]).
            if name not in self.model_fields_set or getattr(self, name) <= 0:
                raise ValueError(f"{name.upper()} must be set above 0 in prod (AI cost guard)")
        for name in PROD_REQUIRED_RATE_LIMITS:
            if getattr(self, name) <= 0:
                raise ValueError(f"{name.upper()} must be above 0 in prod")
        if not self.client_ip_header:
            raise ValueError(
                "CLIENT_IP_HEADER must be set in prod (Fly: Fly-Client-IP); without it every "
                "caller shares the proxy's address and one per-IP rate limit"
            )

    @property
    def apple_revoke_configured(self) -> bool:
        key = self.apple_private_key.get_secret_value() if self.apple_private_key else ""
        return bool(self.apple_team_id and self.apple_key_id and key.strip())

    @property
    def voice_stt_configured(self) -> bool:
        if not self.paid_voice_enabled:
            return False
        return bool(self.deepgram_api_key and self.deepgram_api_key.get_secret_value())

    @property
    def voice_tts_configured(self) -> bool:
        if not self.paid_voice_enabled:
            return False
        key = self.elevenlabs_api_key.get_secret_value() if self.elevenlabs_api_key else ""
        return bool(key and self.elevenlabs_voice_id)


@lru_cache
def get_settings() -> Settings:
    return Settings()
