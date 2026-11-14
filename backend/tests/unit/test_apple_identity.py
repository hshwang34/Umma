"""Brief 010: Apple identity tokens are checked for signature, issuer, audience, expiry and
nonce, and every failure looks the same."""

from __future__ import annotations

import time

import jwt
import pytest

from app.core.errors import ProviderUnavailable, Unauthorized
from tests.apple_helpers import RAW_NONCE, FakeApple


async def test_valid_token_returns_subject_and_email() -> None:
    apple = FakeApple()
    identity = await apple.verifier().verify(
        apple.token(email="Cook@Example.com"), raw_nonce=RAW_NONCE
    )
    assert identity.subject == "001234.abcdef.5678"
    assert identity.email == "cook@example.com"


async def test_token_without_email_is_accepted() -> None:
    apple = FakeApple()
    identity = await apple.verifier().verify(apple.token(email=None), raw_nonce=RAW_NONCE)
    assert identity.email is None


@pytest.mark.parametrize(
    "overrides",
    [
        {"aud": "com.someone.else"},
        {"iss": "https://evil.example.com"},
        {"exp": int(time.time()) - 3600},
        {"sub": None},
        {"sub": ""},
        {"exp": None},
        {"raw_nonce": None},
        {"raw_nonce": "a-different-nonce-entirely"},
    ],
)
async def test_bad_claims_are_refused(overrides: dict[str, object]) -> None:
    apple = FakeApple()
    with pytest.raises(Unauthorized) as caught:
        await apple.verifier().verify(apple.token(**overrides), raw_nonce=RAW_NONCE)
    assert str(caught.value) == "Invalid Apple sign-in"


async def test_token_signed_by_another_key_is_refused() -> None:
    apple, attacker = FakeApple(), FakeApple()
    with pytest.raises(Unauthorized):
        await apple.verifier().verify(attacker.token(), raw_nonce=RAW_NONCE)


async def test_symmetric_and_unsigned_tokens_are_refused() -> None:
    apple = FakeApple()
    verifier = apple.verifier()
    hs256 = jwt.encode({"sub": "x"}, "k" * 32, algorithm="HS256", headers={"kid": apple.kid})
    unsigned = jwt.encode({"sub": "x"}, None, algorithm="none", headers={"kid": apple.kid})
    for forged in (hs256, unsigned, "not-a-jwt", apple.token(headers={"kid": ""})):
        with pytest.raises(Unauthorized):
            await verifier.verify(forged, raw_nonce=RAW_NONCE)


async def test_keys_are_cached_and_unknown_key_ids_refetch_at_most_once_a_minute() -> None:
    apple = FakeApple()
    now = [1000.0]
    verifier = apple.verifier(clock=lambda: now[0])
    await verifier.verify(apple.token(), raw_nonce=RAW_NONCE)
    await verifier.verify(apple.token(), raw_nonce=RAW_NONCE)
    assert apple.fetches == 1

    forged = FakeApple(kid="unknown-key")
    for _ in range(3):
        with pytest.raises(Unauthorized):
            await verifier.verify(forged.token(), raw_nonce=RAW_NONCE)
    assert apple.fetches == 1

    now[0] += 61
    with pytest.raises(Unauthorized):
        await verifier.verify(forged.token(), raw_nonce=RAW_NONCE)
    assert apple.fetches == 2


async def test_rotated_key_is_picked_up() -> None:
    apple = FakeApple()
    now = [1000.0]
    verifier = apple.verifier(clock=lambda: now[0])
    await verifier.verify(apple.token(), raw_nonce=RAW_NONCE)
    rotated = FakeApple(kid="test-key-2")
    apple.kid, apple.private_key = rotated.kid, rotated.private_key
    now[0] += 61
    identity = await verifier.verify(apple.token(), raw_nonce=RAW_NONCE)
    assert identity.subject


async def test_apple_unreachable_with_no_keys_is_a_retryable_503() -> None:
    apple = FakeApple()
    apple.fail = True
    with pytest.raises(ProviderUnavailable):
        await apple.verifier().verify(apple.token(), raw_nonce=RAW_NONCE)


async def test_apple_unreachable_keeps_serving_cached_keys() -> None:
    apple = FakeApple()
    now = [1000.0]
    verifier = apple.verifier(clock=lambda: now[0])
    await verifier.verify(apple.token(), raw_nonce=RAW_NONCE)
    apple.fail = True
    now[0] += 25 * 3600
    assert (await verifier.verify(apple.token(), raw_nonce=RAW_NONCE)).subject
    assert apple.fetches == 2
    await verifier.verify(apple.token(), raw_nonce=RAW_NONCE)
    assert apple.fetches == 2
