"""Brief 010 / DECISIONS #33: Google ID tokens get the same checks as Apple's, with Google's
issuers and audience, and an email is kept only when Google says it is verified."""

from __future__ import annotations

import time

import pytest

from app.core.errors import ProviderUnavailable, Unauthorized
from tests.apple_helpers import RAW_NONCE, FakeApple
from tests.google_helpers import SUBJECT, FakeGoogle


async def test_valid_token_returns_subject_email_and_name() -> None:
    google = FakeGoogle()
    identity = await google.verifier().verify(
        google.token(email="Cook@Example.com", name="  Mina Cho "), raw_nonce=RAW_NONCE
    )
    assert (identity.subject, identity.email, identity.name) == (
        SUBJECT,
        "cook@example.com",
        "Mina Cho",
    )


@pytest.mark.parametrize("issuer", ["https://accounts.google.com", "accounts.google.com"])
async def test_both_google_issuers_are_accepted(issuer: str) -> None:
    google = FakeGoogle()
    identity = await google.verifier().verify(google.token(iss=issuer), raw_nonce=RAW_NONCE)
    assert identity.subject == SUBJECT


@pytest.mark.parametrize("verified", [False, "false", None, "yes"])
async def test_unverified_email_is_dropped(verified: object) -> None:
    google = FakeGoogle()
    identity = await google.verifier().verify(
        google.token(email_verified=verified), raw_nonce=RAW_NONCE
    )
    assert identity.email is None


@pytest.mark.parametrize("name", [None, "", "   ", 42])
async def test_missing_or_blank_name_is_none(name: object) -> None:
    google = FakeGoogle()
    identity = await google.verifier().verify(google.token(name=name), raw_nonce=RAW_NONCE)
    assert identity.name is None


@pytest.mark.parametrize(
    "overrides",
    [
        {"aud": "another-client.apps.googleusercontent.com"},
        {"iss": "https://appleid.apple.com"},
        {"iss": "https://accounts.google.com.evil.example"},
        {"exp": int(time.time()) - 3600},
        {"sub": None},
        {"raw_nonce": None},
        {"raw_nonce": "a-different-nonce-entirely"},
    ],
)
async def test_bad_claims_are_refused(overrides: dict[str, object]) -> None:
    google = FakeGoogle()
    with pytest.raises(Unauthorized) as caught:
        await google.verifier().verify(google.token(**overrides), raw_nonce=RAW_NONCE)
    assert str(caught.value) == "Invalid Google sign-in"


async def test_apple_token_is_not_a_google_token() -> None:
    """A valid Apple token signed by the same key is still refused (issuer and audience)."""
    google = FakeGoogle()
    apple_token = FakeApple.token(google)
    with pytest.raises(Unauthorized):
        await google.verifier().verify(apple_token, raw_nonce=RAW_NONCE)


async def test_token_signed_by_another_key_is_refused() -> None:
    google = FakeGoogle()
    with pytest.raises(Unauthorized):
        await google.verifier().verify(FakeGoogle().token(), raw_nonce=RAW_NONCE)


async def test_keys_unreachable_is_unavailable() -> None:
    google = FakeGoogle()
    google.fail = True
    with pytest.raises(ProviderUnavailable) as caught:
        await google.verifier().verify(google.token(), raw_nonce=RAW_NONCE)
    assert "Google" in str(caught.value)
