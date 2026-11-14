"""Identity-token verification shared by Sign in with Apple and Sign in with Google (brief 010).

Both providers hand the phone an OpenID Connect ID token: a JWT signed with a key the provider
publishes. The checks are the same for both: signature against the published keys, issuer,
audience (this app), expiry, and the nonce the phone generated for that request. The token is
never logged and a failure never says which check failed.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import time
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from typing import Any

import httpx
import jwt

from app.core.errors import ProviderUnavailable, Unauthorized

_ALGORITHM = "RS256"
_KEYS_TTL_SECONDS = 24 * 3600
# An unknown key id triggers at most one refetch per this window, so random key ids in forged
# tokens cannot make the server hammer the provider.
_REFETCH_MIN_INTERVAL_SECONDS = 60
_CLOCK_LEEWAY_SECONDS = 30
_FETCH_TIMEOUT_SECONDS = 5.0

KeyFetcher = Callable[[], Awaitable[dict[str, Any]]]


@dataclass(frozen=True)
class Identity:
    subject: str
    email: str | None
    # The person's name when the provider puts one in the token (Google does, Apple does not).
    name: str | None = None


def http_key_fetcher(url: str) -> KeyFetcher:
    async def fetch() -> dict[str, Any]:
        async with httpx.AsyncClient(timeout=_FETCH_TIMEOUT_SECONDS) as client:
            response = await client.get(url)
            response.raise_for_status()
            return response.json()

    return fetch


class IdentityTokenVerifier:
    def __init__(
        self,
        *,
        label: str,
        issuers: Sequence[str],
        audience: str,
        fetch_keys: KeyFetcher,
        require_verified_email: bool = False,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._invalid = f"Invalid {label} sign-in"
        self._unavailable = f"Sign in with {label} is temporarily unavailable"
        self._issuers = list(issuers)
        self._audience = audience
        self._fetch_keys = fetch_keys
        self._require_verified_email = require_verified_email
        self._clock = clock
        self._keys: dict[str, Any] = {}
        self._fetched_at: float | None = None
        self._lock = asyncio.Lock()

    async def verify(self, identity_token: str, *, raw_nonce: str) -> Identity:
        """Return who the provider says this is, or raise ``Unauthorized``."""
        try:
            header = jwt.get_unverified_header(identity_token)
        except jwt.PyJWTError as exc:
            raise Unauthorized(self._invalid) from exc
        kid = header.get("kid")
        if header.get("alg") != _ALGORITHM or not isinstance(kid, str) or not kid:
            raise Unauthorized(self._invalid)
        key = await self._key_for(kid)
        if key is None:
            raise Unauthorized(self._invalid)
        try:
            claims = jwt.decode(
                identity_token,
                key,
                algorithms=[_ALGORITHM],
                audience=self._audience,
                issuer=self._issuers,
                leeway=_CLOCK_LEEWAY_SECONDS,
                options={"require": ["sub", "exp", "iat", "aud", "iss"]},
            )
        except jwt.PyJWTError as exc:
            raise Unauthorized(self._invalid) from exc
        subject = claims.get("sub")
        nonce = claims.get("nonce")
        if not isinstance(subject, str) or not subject or not isinstance(nonce, str):
            raise Unauthorized(self._invalid)
        expected = hashlib.sha256(raw_nonce.encode("utf-8")).hexdigest()
        if not hmac.compare_digest(nonce.encode("utf-8"), expected.encode("utf-8")):
            raise Unauthorized(self._invalid)
        email = claims.get("email")
        if self._require_verified_email and claims.get("email_verified") not in (True, "true"):
            email = None
        name = claims.get("name")
        return Identity(
            subject=subject,
            email=email.strip().lower() if isinstance(email, str) and "@" in email else None,
            name=name.strip() or None if isinstance(name, str) else None,
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
            raise ProviderUnavailable(self._unavailable) from exc
        if keys:
            self._keys = keys
            self._fetched_at = now
        elif not had_keys:
            raise ProviderUnavailable(self._unavailable)
