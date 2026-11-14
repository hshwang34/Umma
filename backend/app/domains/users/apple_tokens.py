"""Apple's token endpoints: authorization-code exchange and token revoke (brief 010 PR 2).

App Review guideline 5.1.1(v) requires that deleting an account also revokes its Sign in with
Apple token. For that the backend needs a refresh token, which Apple only gives in exchange
for the one-time authorization code the phone receives at sign-in.

* The client secret is a short-lived ES256 JWT signed with the Sign in with Apple key (.p8).
* The refresh token is stored encrypted (Fernet, key derived from ``JWT_SECRET``) and is never
  logged or returned by any route. Rotating ``JWT_SECRET`` makes stored tokens unreadable; a
  later delete then skips the revoke and logs that.
* Nothing here raises to the caller for an Apple failure: sign-in and account deletion must
  both work when Apple's token endpoint is down. Outcomes are logged without the code or token.
"""

from __future__ import annotations

import base64
import hashlib
import logging
import time
import uuid

import httpx
import jwt
from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.db.models import AppleCredential

log = logging.getLogger("umma.apple")

APPLE_AUDIENCE = "https://appleid.apple.com"
CLIENT_SECRET_TTL_SECONDS = 300
_TIMEOUT_SECONDS = 5.0


def _fernet(settings: Settings) -> Fernet:
    digest = hashlib.sha256(b"umma:apple-refresh-token:" + settings.jwt_secret.encode()).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def encrypt_token(settings: Settings, token: str) -> str:
    return _fernet(settings).encrypt(token.encode()).decode()


def decrypt_token(settings: Settings, stored: str) -> str | None:
    try:
        return _fernet(settings).decrypt(stored.encode()).decode()
    except (InvalidToken, ValueError):
        return None


class AppleTokenClient:
    """Talks to Apple's ``/auth/token`` and ``/auth/revoke``. ``transport`` is injected by
    tests, which never reach Apple."""

    def __init__(self, settings: Settings, *, transport: httpx.AsyncBaseTransport | None = None):
        assert settings.apple_revoke_configured
        self._team_id = settings.apple_team_id
        self._key_id = settings.apple_key_id
        self._private_key = settings.apple_private_key.get_secret_value()  # type: ignore[union-attr]
        self._client_id = settings.apple_bundle_id
        self._token_url = settings.apple_token_url
        self._revoke_url = settings.apple_revoke_url
        self._transport = transport

    def client_secret(self, now: float | None = None) -> str:
        issued = int(time.time() if now is None else now)
        return jwt.encode(
            {
                "iss": self._team_id,
                "iat": issued,
                "exp": issued + CLIENT_SECRET_TTL_SECONDS,
                "aud": APPLE_AUDIENCE,
                "sub": self._client_id,
            },
            self._private_key,
            algorithm="ES256",
            headers={"kid": self._key_id},
        )

    async def _post(self, url: str, form: dict[str, str]) -> httpx.Response:
        credentials = {"client_id": self._client_id, "client_secret": self.client_secret()}
        async with httpx.AsyncClient(timeout=_TIMEOUT_SECONDS, transport=self._transport) as http:
            return await http.post(url, data={**credentials, **form})

    async def exchange_code(self, authorization_code: str) -> str | None:
        """The refresh token for a one-time authorization code, or ``None`` (logged)."""
        try:
            response = await self._post(
                self._token_url, {"grant_type": "authorization_code", "code": authorization_code}
            )
            token = response.json().get("refresh_token") if response.status_code == 200 else None
        except (httpx.HTTPError, jwt.PyJWTError, ValueError, AttributeError) as exc:
            log.warning("apple code exchange failed", extra={"error_type": type(exc).__name__})
            return None
        if not isinstance(token, str) or not token:
            log.warning("apple code exchange refused", extra={"apple_status": response.status_code})
            return None
        return token

    async def revoke(self, refresh_token: str) -> bool:
        try:
            response = await self._post(
                self._revoke_url, {"token": refresh_token, "token_type_hint": "refresh_token"}
            )
        except (httpx.HTTPError, jwt.PyJWTError, ValueError) as exc:
            log.warning("apple token revoke failed", extra={"error_type": type(exc).__name__})
            return False
        if response.status_code != 200:
            log.warning("apple token revoke refused", extra={"apple_status": response.status_code})
            return False
        return True


def build_apple_token_client(settings: Settings) -> AppleTokenClient | None:
    """``None`` unless the team id, key id and .p8 are all configured."""
    return AppleTokenClient(settings) if settings.apple_revoke_configured else None


async def store_refresh_token(
    session: AsyncSession, settings: Settings, user_id: uuid.UUID, refresh_token: str
) -> None:
    encrypted = encrypt_token(settings, refresh_token)
    stmt = pg_insert(AppleCredential).values(user_id=user_id, refresh_token_encrypted=encrypted)
    await session.execute(
        stmt.on_conflict_do_update(
            index_elements=[AppleCredential.user_id],
            set_={"refresh_token_encrypted": encrypted},
        )
    )


async def load_refresh_token(
    session: AsyncSession, settings: Settings, user_id: uuid.UUID
) -> str | None:
    stored = await session.scalar(
        select(AppleCredential.refresh_token_encrypted).where(AppleCredential.user_id == user_id)
    )
    if stored is None:
        return None
    token = decrypt_token(settings, stored)
    if token is None:
        log.warning("stored apple token is unreadable", extra={"user_id": str(user_id)})
    return token
