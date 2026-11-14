"""Sign in with Apple: verify the identity token the phone received (brief 010, AUTH-01).

The phone sends Apple's identity token (a JWT signed by Apple) plus the raw nonce it generated
for that request. The checks themselves live in ``oidc.py``, shared with Sign in with Google.
"""

from __future__ import annotations

import time
from collections.abc import Callable

from app.domains.users.oidc import Identity, IdentityTokenVerifier, KeyFetcher, http_key_fetcher

APPLE_ISSUER = "https://appleid.apple.com"
PROVIDER_NAME = "apple"

AppleIdentity = Identity

__all__ = [
    "APPLE_ISSUER",
    "PROVIDER_NAME",
    "AppleIdentity",
    "AppleIdentityVerifier",
    "http_key_fetcher",
]


class AppleIdentityVerifier(IdentityTokenVerifier):
    def __init__(
        self,
        *,
        audience: str,
        fetch_keys: KeyFetcher,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        super().__init__(
            label="Apple",
            issuers=[APPLE_ISSUER],
            audience=audience,
            fetch_keys=fetch_keys,
            clock=clock,
        )
