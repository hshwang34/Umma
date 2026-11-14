"""A local stand-in for Apple's signing keys, so tests never call Apple."""

from __future__ import annotations

import hashlib
import time
from typing import Any

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

from app.domains.users.apple import APPLE_ISSUER, AppleIdentityVerifier

BUNDLE_ID = "com.umma.ios"
RAW_NONCE = "raw-nonce-0123456789abcdef"


class FakeApple:
    def __init__(self, kid: str = "test-key-1") -> None:
        self.kid = kid
        self.private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.fetches = 0
        self.fail = False
        self.published = True

    def jwk(self) -> dict[str, Any]:
        entry = jwt.algorithms.RSAAlgorithm.to_jwk(self.private_key.public_key(), as_dict=True)
        return {**entry, "kid": self.kid, "alg": "RS256", "use": "sig"}

    async def fetch_keys(self) -> dict[str, Any]:
        self.fetches += 1
        if self.fail:
            raise ValueError("apple is down")
        return {"keys": [self.jwk()] if self.published else []}

    def verifier(self, **kwargs: Any) -> AppleIdentityVerifier:
        return AppleIdentityVerifier(audience=BUNDLE_ID, fetch_keys=self.fetch_keys, **kwargs)

    def token(
        self,
        *,
        subject: str = "001234.abcdef.5678",
        raw_nonce: str | None = RAW_NONCE,
        headers: dict[str, Any] | None = None,
        **overrides: Any,
    ) -> str:
        now = int(time.time())
        claims: dict[str, Any] = {
            "iss": APPLE_ISSUER,
            "aud": BUNDLE_ID,
            "sub": subject,
            "iat": now,
            "exp": now + 600,
            "email": "cook@example.com",
            "email_verified": "true",
        }
        if raw_nonce is not None:
            claims["nonce"] = hashlib.sha256(raw_nonce.encode()).hexdigest()
        claims.update(overrides)
        claims = {key: value for key, value in claims.items() if value is not None}
        return jwt.encode(
            claims,
            self.private_key,
            algorithm="RS256",
            headers={"kid": self.kid, **(headers or {})},
        )
