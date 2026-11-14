"""Sign in with Apple: verify the identity token the phone received (brief 010, AUTH-01).

The phone sends Apple's identity token (a JWT signed by Apple) plus the raw nonce it generated
for that request. This module checks the signature against Apple's published keys, and that the
token was issued by Apple, for this app, is unexpired and is bound to that nonce. It never logs
the token and never says which check failed.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

import httpx
import jwt

from app.core.errors import ProviderUnavailable, Unauthorized

APPLE_ISSUER = "https://appleid.apple.com"
PROVIDER_NAME = "apple"
_ALGORITHM = "RS256"
_KEYS_TTL_SECONDS = 24 * 3600
# An unknown key id triggers at most one refetch per this window, so random key ids in forged
# tokens cannot make the server hammer Apple.
_REFETCH_MIN_INTERVAL_SECONDS = 60
_CLOCK_LEEWAY_SECONDS = 30
_FETCH_TIMEOUT_SECONDS = 5.0
_INVALID = "Invalid Apple sign-in"

KeyFetcher = Callable[[], Awaitable[dict[str, Any]]]


@dataclass(frozen=True)
class AppleIdentity:
    subject: str
    email: str | None


def http_key_fetcher(url: str) -> KeyFetcher:
    async def fetch() -> dict[str, Any]:
        async with httpx.AsyncClient(timeout=_FETCH_TIMEOUT_SECONDS) as client:
            response = await client.get(url)
            response.raise_for_status()
            return response.json()

    return fetch


class AppleIdentityVerifier:
    def __init__(
        self,
        *,
        audience: str,
        fetch_keys: KeyFetcher,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._audience = audience
        self._fetch_keys = fetch_keys
        self._clock = clock
        self._keys: dict[str, Any] = {}
        self._fetched_at: float | None = None
        self._lock = asyncio.Lock()

    async def verify(self, identity_token: str, *, raw_nonce: str) -> AppleIdentity:
        """Return who Apple says this is, or raise ``Unauthorized``."""
        try:
            header = jwt.get_unverified_header(identity_token)
        except jwt.PyJWTError as exc:
            raise Unauthorized(_INVALID) from exc
        kid = header.get("kid")
        if header.get("alg") != _ALGORITHM or not isinstance(kid, str) or not kid:
            raise Unauthorized(_INVALID)
        key = await self._key_for(kid)
        if key is None:
            raise Unauthorized(_INVALID)
        try:
            claims = jwt.decode(
                identity_token,
                key,
                algorithms=[_ALGORITHM],
                audience=self._audience,
                issuer=APPLE_ISSUER,
                leeway=_CLOCK_LEEWAY_SECONDS,
                options={"require": ["sub", "exp", "iat", "aud", "iss"]},
            )
        except jwt.PyJWTError as exc:
            raise Unauthorized(_INVALID) from exc
        subject = claims.get("sub")
        nonce = claims.get("nonce")
        if not isinstance(subject, str) or not subject or not isinstance(nonce, str):
            raise Unauthorized(_INVALID)
        expected = hashlib.sha256(raw_nonce.encode("utf-8")).hexdigest()
        if not hmac.compare_digest(nonce.encode("utf-8"), expected.encode("utf-8")):
            raise Unauthorized(_INVALID)
        email = claims.get("email")
        return AppleIdentity(
            subject=subject,
            email=email.strip().lower() if isinstance(email, str) and "@" in email else None,
        )

    async def _key_for(self, kid: str) -> Any | None:
        async with self._lock:
            now = self._clock()
            age = None if self._fetched_at is None else now - self._fetched_at
            stale = age is None or age >= _KEYS_TTL_SECONDS
            unknown = kid not in self._keys
            if stale or (unknown and age is not None and age >= _REFETCH_MIN_INTERVAL_SECONDS):
                await self._refresh(now, had_keys=bool(self._keys))
            return self._keys.get(kid)

    async def _refresh(self, now: float, *, had_keys: bool) -> None:
        try:
            document = await self._fetch_keys()
            keys = {
                entry["kid"]: jwt.PyJWK(entry).key
                for entry in document["keys"]
                if entry.get("kty") == "RSA" and isinstance(entry.get("kid"), str)
            }
        except (httpx.HTTPError, jwt.PyJWTError, KeyError, TypeError, ValueError) as exc:
            if had_keys:
                # Keep serving with the keys we have; try again after the refetch interval.
                self._fetched_at = now - _KEYS_TTL_SECONDS + _REFETCH_MIN_INTERVAL_SECONDS
                return
            raise ProviderUnavailable("Sign in with Apple is temporarily unavailable") from exc
        if keys:
            self._keys = keys
            self._fetched_at = now
        elif not had_keys:
            raise ProviderUnavailable("Sign in with Apple is temporarily unavailable")
