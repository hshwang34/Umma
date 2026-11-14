"""Brief 010 PR 2a: the Apple authorization code is exchanged at sign-in and the refresh token
is stored encrypted. Apple's token endpoint is a local fake throughout."""

from __future__ import annotations

import json
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from urllib.parse import parse_qs

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from httpx import ASGITransport, AsyncClient
from pydantic import SecretStr
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.db.models import AppleCredential, User
from app.domains.users.apple_tokens import AppleTokenClient, decrypt_token
from app.main import create_app
from tests.apple_helpers import BUNDLE_ID, RAW_NONCE, FakeApple

pytestmark = pytest.mark.usefixtures("clean_tables")

REFRESH_TOKEN = "r.apple-refresh-token-SECRET-VALUE"
AUTH_CODE = "c.one-time-authorization-code-SECRET"
SIGNING_KEY = ec.generate_private_key(ec.SECP256R1())
P8 = SIGNING_KEY.private_bytes(
    serialization.Encoding.PEM,
    serialization.PrivateFormat.PKCS8,
    serialization.NoEncryption(),
).decode()
APPLE_KEYS = {"apple_team_id": "TEAM123456", "apple_key_id": "KEY1234567"}


class FakeAppleTokens:
    """Stands in for appleid.apple.com/auth/token and /auth/revoke."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, str]]] = []
        self.token_status = 200
        self.revoke_status = 200
        self.down = False

    def handler(self, request: httpx.Request) -> httpx.Response:
        form = {key: values[0] for key, values in parse_qs(request.content.decode()).items()}
        self.calls.append((request.url.path, form))
        if self.down:
            raise httpx.ConnectError("apple is down")
        if request.url.path == "/auth/token":
            if self.token_status != 200:
                return httpx.Response(self.token_status, json={"error": "invalid_grant"})
            return httpx.Response(200, json={"refresh_token": REFRESH_TOKEN, "access_token": "a"})
        return httpx.Response(self.revoke_status)

    def paths(self) -> list[str]:
        return [path for path, _ in self.calls]


@asynccontextmanager
async def _app_client(
    settings: Settings, tokens: FakeAppleTokens | None, apple: FakeApple
) -> AsyncIterator[AsyncClient]:
    update: dict[str, object] = {"auth_mode": "apple"}
    if tokens is not None:
        update |= {**APPLE_KEYS, "apple_private_key": SecretStr(P8)}
    configured = settings.model_copy(update=update)
    app = create_app(configured)
    app.state.apple_verifier = apple.verifier()
    if tokens is not None:
        assert app.state.apple_token_client is not None
        app.state.apple_token_client = AppleTokenClient(
            configured, transport=httpx.MockTransport(tokens.handler)
        )
    else:
        assert app.state.apple_token_client is None
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


async def _sign_in(client: AsyncClient, apple: FakeApple, **extra: object) -> dict[str, str]:
    body = {"identity_token": apple.token(), "nonce": RAW_NONCE, **extra}
    response = await client.post("/v1/auth/apple", json=body)
    assert response.status_code == 200, response.text
    assert REFRESH_TOKEN not in response.text and AUTH_CODE not in response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


async def _users(session: AsyncSession) -> int:
    return await session.scalar(select(func.count()).select_from(User)) or 0


def _logged(caplog: pytest.LogCaptureFixture) -> str:
    return json.dumps([record.__dict__ for record in caplog.records], default=str)


async def test_code_is_exchanged_and_the_refresh_token_stored_encrypted(
    settings: Settings, db_session: AsyncSession, caplog: pytest.LogCaptureFixture
) -> None:
    tokens, apple = FakeAppleTokens(), FakeApple()
    async with _app_client(settings, tokens, apple) as client:
        caplog.set_level(logging.DEBUG)  # after create_app, which sets the root level
        headers = await _sign_in(client, apple, authorization_code=AUTH_CODE)

        path, form = tokens.calls[0]
        assert path == "/auth/token"
        assert form["grant_type"] == "authorization_code"
        assert form["code"] == AUTH_CODE
        assert form["client_id"] == BUNDLE_ID
        # The client secret is an ES256 JWT signed with the .p8, as Apple requires.
        secret = form["client_secret"]
        assert jwt.get_unverified_header(secret) == {
            "alg": "ES256",
            "kid": APPLE_KEYS["apple_key_id"],
            "typ": "JWT",
        }
        claims = jwt.decode(
            secret,
            SIGNING_KEY.public_key(),
            algorithms=["ES256"],
            audience="https://appleid.apple.com",
        )
        assert claims["iss"] == APPLE_KEYS["apple_team_id"]
        assert claims["sub"] == BUNDLE_ID
        assert 0 < claims["exp"] - claims["iat"] <= 600

        stored = (
            await db_session.execute(select(AppleCredential.refresh_token_encrypted))
        ).scalar_one()
        assert REFRESH_TOKEN not in stored
        assert decrypt_token(settings, stored) == REFRESH_TOKEN
        # A different server secret cannot read it.
        other = settings.model_copy(update={"jwt_secret": "another-secret-0123456789abcdef-xyz"})
        assert decrypt_token(other, stored) is None
        # No route returns it.
        assert REFRESH_TOKEN not in (await client.get("/v1/me", headers=headers)).text
    logged = _logged(caplog)
    assert REFRESH_TOKEN not in logged and AUTH_CODE not in logged


@pytest.mark.parametrize("failure", ["status", "network"])
async def test_a_failed_code_exchange_never_blocks_sign_in(
    settings: Settings, db_session: AsyncSession, caplog: pytest.LogCaptureFixture, failure: str
) -> None:
    tokens, apple = FakeAppleTokens(), FakeApple()
    tokens.token_status = 400
    tokens.down = failure == "network"
    async with _app_client(settings, tokens, apple) as client:
        caplog.set_level(logging.DEBUG)  # after create_app, which sets the root level
        headers = await _sign_in(client, apple, authorization_code=AUTH_CODE)
        assert (await client.get("/v1/me", headers=headers)).status_code == 200
        assert await db_session.scalar(select(func.count()).select_from(AppleCredential)) == 0
    assert AUTH_CODE not in _logged(caplog)


async def test_signing_in_again_replaces_the_stored_token(
    settings: Settings, db_session: AsyncSession
) -> None:
    tokens, apple = FakeAppleTokens(), FakeApple()
    async with _app_client(settings, tokens, apple) as client:
        await _sign_in(client, apple, authorization_code=AUTH_CODE)
        await _sign_in(client, apple, authorization_code=AUTH_CODE + "-2")
        assert await db_session.scalar(select(func.count()).select_from(AppleCredential)) == 1
        # A later sign-in without a code keeps the token already stored.
        await _sign_in(client, apple)
        assert await db_session.scalar(select(func.count()).select_from(AppleCredential)) == 1


async def test_authorization_code_is_validated_and_other_extra_fields_stay_forbidden(
    settings: Settings,
) -> None:
    apple = FakeApple()
    async with _app_client(settings, FakeAppleTokens(), apple) as client:
        base = {"identity_token": apple.token(), "nonce": RAW_NONCE}
        for bad in ({"authorization_code": ""}, {"authorization_code": 5}, {"auth_code": "x"}):
            response = await client.post("/v1/auth/apple", json={**base, **bad})
            assert response.status_code == 422, bad
            assert AUTH_CODE not in response.text


def test_apple_key_settings_are_all_or_nothing() -> None:
    base = {"_env_file": None, "jwt_secret": "x" * 40, "auth_mode": "apple"}
    assert not Settings(**base).apple_revoke_configured
    assert not Settings(**base, **APPLE_KEYS).apple_revoke_configured
    full = Settings(**base, **APPLE_KEYS, apple_private_key=P8)
    assert full.apple_revoke_configured
    assert P8 not in repr(full)


async def test_without_a_code_or_without_the_apple_key_nothing_is_exchanged_or_stored(
    settings: Settings, db_session: AsyncSession
) -> None:
    tokens, apple = FakeAppleTokens(), FakeApple()
    async with _app_client(settings, tokens, apple) as client:
        await _sign_in(client, apple)  # today's iOS build sends no authorization_code
    async with _app_client(settings, None, apple) as client:
        await _sign_in(client, apple, authorization_code=AUTH_CODE)
    assert tokens.calls == []
    assert await db_session.scalar(select(func.count()).select_from(AppleCredential)) == 0
