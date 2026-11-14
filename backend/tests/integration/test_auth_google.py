"""Brief 010 / DECISIONS #33: ``POST /v1/auth/google`` exists only when Google sign-in is
configured, creates one account per Google subject, and never merges with an Apple account."""

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
from tests.google_helpers import CLIENT_ID, SUBJECT, FakeGoogle

GOOGLE = "/v1/auth/google"
APPLE = "/v1/auth/apple"


@pytest.fixture
def google() -> FakeGoogle:
    return FakeGoogle()


@pytest.fixture
def apple() -> FakeApple:
    return FakeApple()


@pytest.fixture
async def google_client(
    settings: Settings, clean_tables: None, google: FakeGoogle, apple: FakeApple
) -> AsyncIterator[AsyncClient]:
    app = create_app(
        settings.model_copy(update={"auth_mode": "apple", "google_ios_client_id": CLIENT_ID})
    )
    app.state.google_verifier = google.verifier()
    app.state.apple_verifier = apple.verifier()
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


def body(token: str, **extra: object) -> dict[str, object]:
    return {"id_token": token, "nonce": RAW_NONCE, **extra}


async def count_users(db_session: AsyncSession) -> int:
    return (await db_session.execute(select(func.count()).select_from(User))).scalar_one()


async def test_first_sign_in_creates_the_account_and_the_token_works(
    google_client: AsyncClient, google: FakeGoogle, db_session: AsyncSession
) -> None:
    response = await google_client.post(GOOGLE, json=body(google.token()))
    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["user"]["display_name"] == "Mina Cho"
    me = await google_client.get(
        "/v1/me", headers={"Authorization": f"Bearer {payload['access_token']}"}
    )
    assert me.status_code == 200
    assert me.json()["id"] == payload["user"]["id"]
    user = (await db_session.execute(select(User))).scalar_one()
    assert (user.auth_provider, user.auth_subject) == ("google", SUBJECT)
    assert user.email == "cook@example.com"


async def test_signing_in_again_reuses_the_account(
    google_client: AsyncClient, google: FakeGoogle, db_session: AsyncSession
) -> None:
    first = await google_client.post(GOOGLE, json=body(google.token()))
    again = await google_client.post(GOOGLE, json=body(google.token(name="Someone Else")))
    assert again.status_code == 200
    assert again.json()["user"] == first.json()["user"]
    assert await count_users(db_session) == 1


@pytest.mark.parametrize(
    ("claims", "expected_name"),
    [
        ({"name": None}, "cook"),
        ({"name": None, "email_verified": False}, "Cook"),
        ({"name": None, "email": None}, "Cook"),
    ],
)
async def test_display_name_fallback(
    google_client: AsyncClient, google: FakeGoogle, claims: dict[str, object], expected_name: str
) -> None:
    response = await google_client.post(GOOGLE, json=body(google.token(**claims)))
    assert response.json()["user"]["display_name"] == expected_name


async def test_same_email_on_apple_and_google_is_two_accounts(
    google_client: AsyncClient, google: FakeGoogle, apple: FakeApple, db_session: AsyncSession
) -> None:
    """DECISIONS #33: never merged by email. The second account stores no email."""
    with_apple = await google_client.post(
        APPLE, json={"identity_token": apple.token(), "nonce": RAW_NONCE}
    )
    with_google = await google_client.post(GOOGLE, json=body(google.token()))
    assert with_apple.status_code == with_google.status_code == 200
    assert with_apple.json()["user"]["id"] != with_google.json()["user"]["id"]
    rows = (
        await db_session.execute(select(User.auth_provider, User.email).order_by(User.created_at))
    ).all()
    assert [tuple(row) for row in rows] == [("apple", "cook@example.com"), ("google", None)]


async def test_same_subject_string_on_apple_and_google_is_two_accounts(
    google_client: AsyncClient, google: FakeGoogle, apple: FakeApple
) -> None:
    one = await google_client.post(
        APPLE, json={"identity_token": apple.token(subject="12345"), "nonce": RAW_NONCE}
    )
    two = await google_client.post(GOOGLE, json=body(google.token(subject="12345")))
    assert one.json()["user"]["id"] != two.json()["user"]["id"]


async def test_invalid_token_is_401_and_creates_nobody(
    google_client: AsyncClient, google: FakeGoogle, apple: FakeApple, db_session: AsyncSession
) -> None:
    tokens = (
        google.token(aud="another-client.apps.googleusercontent.com"),
        FakeGoogle().token(),
        apple.token(),
        "x" * 40,
    )
    for token in tokens:
        response = await google_client.post(GOOGLE, json=body(token))
        assert response.status_code == 401
        assert response.json()["error"]["code"] == "UNAUTHORIZED"
        assert response.json()["error"]["message"] == "Invalid Google sign-in"
    wrong_nonce = {"id_token": google.token(), "nonce": "another-nonce-0123456789"}
    assert (await google_client.post(GOOGLE, json=wrong_nonce)).status_code == 401
    assert await count_users(db_session) == 0


async def test_a_google_token_does_not_sign_in_with_apple(
    google_client: AsyncClient, google: FakeGoogle
) -> None:
    response = await google_client.post(
        APPLE, json={"identity_token": google.token(), "nonce": RAW_NONCE}
    )
    assert response.status_code == 401


async def test_malformed_body_is_422(google_client: AsyncClient, google: FakeGoogle) -> None:
    for payload in (
        {"id_token": google.token()},
        {"id_token": google.token(), "nonce": "short"},
        body(google.token(), display_name="Smuggled Name"),
        body("y" * 9000),
    ):
        assert (await google_client.post(GOOGLE, json=payload)).status_code == 422


async def test_google_keys_unreachable_is_a_retryable_503(
    google_client: AsyncClient, google: FakeGoogle
) -> None:
    google.fail = True
    response = await google_client.post(GOOGLE, json=body(google.token()))
    assert response.status_code == 503
    assert response.json()["error"]["retryable"] is True


async def test_route_does_not_exist_without_a_client_id(
    apple_mode_client: AsyncClient, google: FakeGoogle
) -> None:
    response = await apple_mode_client.post(GOOGLE, json=body(google.token()))
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"


async def test_route_does_not_exist_in_dev_mode(client: AsyncClient, google: FakeGoogle) -> None:
    response = await client.post(GOOGLE, json=body(google.token()))
    assert response.status_code == 404
