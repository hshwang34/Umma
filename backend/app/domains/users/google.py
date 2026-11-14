"""Sign in with Google: verify the ID token the phone received (brief 010, DECISIONS #33).

The phone signs in through the system web sign-in sheet with this app's iOS OAuth client and
sends Google's ID token plus the raw nonce it generated. Google copies the nonce parameter into
the token unchanged, so the phone sends Google the SHA-256 of its raw nonce, exactly as Sign in
with Apple does. An email is kept only when Google says it is verified.
"""

from __future__ import annotations

import time
from collections.abc import Callable

from app.domains.users.oidc import IdentityTokenVerifier, KeyFetcher

# Google documents both spellings of its issuer.
GOOGLE_ISSUERS = ("https://accounts.google.com", "accounts.google.com")
PROVIDER_NAME = "google"


class GoogleIdentityVerifier(IdentityTokenVerifier):
    def __init__(
        self,
        *,
        audience: str,
        fetch_keys: KeyFetcher,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        super().__init__(
            label="Google",
            issuers=GOOGLE_ISSUERS,
            audience=audience,
            fetch_keys=fetch_keys,
            require_verified_email=True,
            clock=clock,
        )
