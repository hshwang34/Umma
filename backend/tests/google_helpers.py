"""A local stand-in for Google's signing keys, so tests never call Google."""

from __future__ import annotations

from typing import Any

from app.domains.users.google import GoogleIdentityVerifier
from tests.apple_helpers import RAW_NONCE, FakeApple

CLIENT_ID = "1234567890-abcdef.apps.googleusercontent.com"
SUBJECT = "110169484474386276334"


class FakeGoogle(FakeApple):
    def verifier(self, **kwargs: Any) -> GoogleIdentityVerifier:
        return GoogleIdentityVerifier(audience=CLIENT_ID, fetch_keys=self.fetch_keys, **kwargs)

    def token(
        self,
        *,
        subject: str = SUBJECT,
        raw_nonce: str | None = RAW_NONCE,
        headers: dict[str, Any] | None = None,
        **overrides: Any,
    ) -> str:
        claims: dict[str, Any] = {
            "iss": "https://accounts.google.com",
            "aud": CLIENT_ID,
            "email_verified": True,
            "name": "Mina Cho",
            **overrides,
        }
        return super().token(subject=subject, raw_nonce=raw_nonce, headers=headers, **claims)
