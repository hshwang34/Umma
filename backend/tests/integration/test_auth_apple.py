"""Brief 010: ``POST /v1/auth/apple`` exists only in apple mode, creates one account per Apple
subject and issues the same JWT the rest of the API accepts."""

from __future__ import annotations

from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.db.models import User
from app.main import create_app
from tests.apple_helpers import RAW_NONCE, FakeApple
from tests.conftest import dev_sign_in

APPLE = "/v1/auth/apple"


@pytest.fixture
def apple() -> FakeApple:
    return FakeApple()


@pytest.fixture
async def apple_client(
    settings: Settings, clean_tables: None, apple: FakeApple
) -> AsyncIterator[AsyncClient]:
    app = create_app(settings.model_copy(update={"auth_mode": "apple"}))
    app.state.apple_verifier = apple.verifier()
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


def body(token: str, **extra: object) -> dict[str, object]:
    return {"identity_token": token, "nonce": RAW_NONCE, **extra}


async def test_first_sign_in_creates_the_account_and_the_token_works(
    apple_client: AsyncClient, apple: FakeApple, db_session: AsyncSession
) -> None:
    response = await apple_client.post(APPLE, json=body(apple.token(), display_name="  Mina  "))
    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["user"]["display_name"] == "Mina"
    me = await apple_client.get(
        "/v1/me", headers={"Authorization": f"Bearer {payload['access_token']}"}
    )
    assert me.status_code == 200
    assert me.json()["id"] == payload["user"]["id"]
    user = (await db_session.execute(select(User))).scalar_one()
    assert (user.auth_provider, user.auth_subject) == ("apple", "001234.abcdef.5678")
    assert user.email == "cook@example.com"


async def test_signing_in_again_reuses_the_account_and_keeps_the_name(
    apple_client: AsyncClient, apple: FakeApple, db_session: AsyncSession
) -> None:
    first = await apple_client.post(APPLE, json=body(apple.token(), display_name="Mina"))
    again = await apple_client.post(APPLE, json=body(apple.token(email=None)))
    assert again.status_code == 200
    assert again.json()["user"] == first.json()["user"]
    assert (await db_session.execute(select(func.count()).select_from(User))).scalar_one() == 1


async def test_two_apple_ids_are_two_accounts(apple_client: AsyncClient, apple: FakeApple) -> None:
    one = await apple_client.post(APPLE, json=body(apple.token(subject="a.1", email="a@x.com")))
    two = await apple_client.post(APPLE, json=body(apple.token(subject="b.2", email="b@x.com")))
    assert one.json()["user"]["id"] != two.json()["user"]["id"]


@pytest.mark.parametrize(
    ("email", "expected_name"),
    [
        ("mina@example.com", "mina"),
        ("x7f9k2@privaterelay.appleid.com", "Cook"),
        (None, "Cook"),
    ],
)
async def test_display_name_fallback(
    apple_client: AsyncClient, apple: FakeApple, email: str | None, expected_name: str
) -> None:
    response = await apple_client.post(APPLE, json=body(apple.token(email=email)))
    assert response.json()["user"]["display_name"] == expected_name


async def test_email_already_held_by_another_account_is_not_stored(
    apple_client: AsyncClient, apple: FakeApple, db_session: AsyncSession
) -> None:
    await apple_client.post(APPLE, json=body(apple.token(subject="a.1")))
    second = await apple_client.post(APPLE, json=body(apple.token(subject="b.2")))
    assert second.status_code == 200
    emails = (await db_session.execute(select(User.email).order_by(User.created_at))).scalars()
    assert list(emails) == ["cook@example.com", None]


async def test_invalid_token_is_401_and_creates_nobody(
    apple_client: AsyncClient, apple: FakeApple, db_session: AsyncSession
) -> None:
    for token in (apple.token(aud="com.someone.else"), FakeApple().token(), "x" * 40):
        response = await apple_client.post(APPLE, json=body(token))
        assert response.status_code == 401
        assert response.json()["error"]["code"] == "UNAUTHORIZED"
        assert response.json()["error"]["message"] == "Invalid Apple sign-in"
    wrong_nonce = {"identity_token": apple.token(), "nonce": "another-nonce-0123456789"}
    assert (await apple_client.post(APPLE, json=wrong_nonce)).status_code == 401
    assert (await db_session.execute(select(func.count()).select_from(User))).scalar_one() == 0


async def test_malformed_body_is_422(apple_client: AsyncClient, apple: FakeApple) -> None:
    for payload in (
        {"identity_token": apple.token()},
        {"identity_token": apple.token(), "nonce": "short"},
        body(apple.token(), email="smuggled@example.com"),
        body("y" * 9000),
    ):
        assert (await apple_client.post(APPLE, json=payload)).status_code == 422


async def test_apple_keys_unreachable_is_a_retryable_503(
    apple_client: AsyncClient, apple: FakeApple
) -> None:
    apple.fail = True
    response = await apple_client.post(APPLE, json=body(apple.token()))
    assert response.status_code == 503
    assert response.json()["error"]["retryable"] is True


async def test_route_does_not_exist_in_dev_mode(client: AsyncClient, apple: FakeApple) -> None:
    response = await client.post(APPLE, json=body(apple.token()))
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"
    assert await dev_sign_in(client, "dev@example.com")
