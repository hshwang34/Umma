"""Brief 010 PR 3: the review login for Beta App Review."""

from __future__ import annotations

import json
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import pytest
from httpx import ASGITransport, AsyncClient
from pydantic import SecretStr, ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.auth_review import _matches
from app.core.config import MIN_REVIEW_CODE_CHARS, Settings
from app.db.models import User
from app.main import create_app
from tests.conftest import bearer

pytestmark = pytest.mark.usefixtures("clean_tables")

REVIEW = "/v1/auth/review"
CODE = "review-code-for-tests-0123456789"


@asynccontextmanager
async def _client(settings: Settings, **update: object) -> AsyncIterator[AsyncClient]:
    update.setdefault("review_login_code", SecretStr(CODE))
    app = create_app(settings.model_copy(update=update))
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


async def _review_headers(client: AsyncClient) -> dict[str, str]:
    response = await client.post(REVIEW, json={"code": CODE})
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


async def test_route_does_not_exist_without_the_secret(client: AsyncClient) -> None:
    response = await client.post(REVIEW, json={"code": CODE})
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"
    assert REVIEW not in client._transport.app.openapi()["paths"]  # type: ignore[attr-defined]


async def test_route_exists_in_apple_mode_when_the_secret_is_set(settings: Settings) -> None:
    async with _client(settings, auth_mode="apple") as client:
        assert (await client.post(REVIEW, json={"code": CODE})).status_code == 200
        # Dev sign-in is still absent in apple mode.
        dev = await client.post("/v1/auth/dev-login", json={"email": "a@example.com"})
        assert dev.status_code == 404


async def test_right_code_signs_in_as_the_one_review_account(
    settings: Settings, db_session: AsyncSession
) -> None:
    async with _client(settings) as client:
        first = await client.post(REVIEW, json={"code": CODE})
        second = await client.post(REVIEW, json={"code": CODE})
        assert first.status_code == second.status_code == 200
        assert first.json()["user"]["id"] == second.json()["user"]["id"]
        assert first.json()["user"]["display_name"] == "App Review"
        assert CODE not in first.text
        headers = {"Authorization": f"Bearer {first.json()['access_token']}"}
        assert (await client.get("/v1/me", headers=headers)).status_code == 200
    users = (await db_session.execute(select(User))).scalars().all()
    assert [(u.auth_provider, u.auth_subject, u.email) for u in users] == [
        ("review", "app-review", None)
    ]


@pytest.mark.parametrize("code", ["wrong", CODE + "x", CODE[:-1], CODE.upper(), " " + CODE])
async def test_wrong_code_is_one_indistinguishable_401_and_is_not_logged(
    settings: Settings, db_session: AsyncSession, caplog: pytest.LogCaptureFixture, code: str
) -> None:
    async with _client(settings) as client:
        caplog.set_level(logging.DEBUG)  # after create_app, which sets the root level
        response = await client.post(REVIEW, json={"code": code})
    assert response.status_code == 401
    error = response.json()["error"]
    assert (error["code"], error["message"]) == ("UNAUTHORIZED", "Invalid review code")
    assert code not in response.text and CODE not in response.text
    assert (await db_session.execute(select(User))).first() is None  # no account was made
    logged = json.dumps([record.__dict__ for record in caplog.records], default=str)
    assert CODE not in logged and code not in logged


@pytest.mark.parametrize("body", [{}, {"code": ""}, {"code": 5}, {"code": CODE, "email": "x"}])
async def test_malformed_bodies_are_422_without_echoing_values(
    settings: Settings, body: dict[str, object]
) -> None:
    async with _client(settings) as client:
        response = await client.post(REVIEW, json=body)
    assert response.status_code == 422
    assert CODE not in response.text


def test_comparison_handles_any_length_and_unicode() -> None:
    assert _matches(CODE, CODE)
    assert not _matches("", CODE)
    assert not _matches(CODE * 50, CODE)
    assert not _matches("réview", CODE)


async def test_attempts_are_limited_per_ip(settings: Settings) -> None:
    async with _client(
        settings, rate_limit_review_login_per_ip_per_minute=3, client_ip_header="Fly-Client-IP"
    ) as client:
        guesser = {"Fly-Client-IP": "203.0.113.9"}
        for _ in range(3):
            wrong = await client.post(REVIEW, json={"code": "guess"}, headers=guesser)
            assert wrong.status_code == 401
        # Over the limit even the right code is refused, with the standard envelope.
        limited = await client.post(REVIEW, json={"code": CODE}, headers=guesser)
        assert limited.status_code == 429
        error = limited.json()["error"]
        assert error["code"] == "RATE_LIMITED" and error["retryable"] is True
        # The reviewer, on another address, still gets in.
        reviewer = {"Fly-Client-IP": "198.51.100.4"}
        assert (await client.post(REVIEW, json={"code": CODE}, headers=reviewer)).status_code == 200


async def test_a_flood_of_wrong_codes_cannot_lock_the_reviewer_out(settings: Settings) -> None:
    async with _client(
        settings, rate_limit_review_login_total_per_minute=4, client_ip_header="Fly-Client-IP"
    ) as client:

        async def attempt(code: str, host: int) -> int:
            headers = {"Fly-Client-IP": f"203.0.{host}.9"}  # a different /24 every time
            return (await client.post(REVIEW, json={"code": code}, headers=headers)).status_code

        # Wrong codes from many addresses use up the shared budget, then get 429 themselves.
        assert [await attempt("guess", host) for host in range(4)] == [401] * 4
        assert [await attempt("guess", host) for host in range(4, 30)] == [429] * 26
        # The right code from a fresh address still signs in, again and again.
        assert await attempt(CODE, 100) == 200
        assert await attempt(CODE, 101) == 200
        # Right codes never spent the shared budget, and wrong ones are still refused.
        assert await attempt("guess", 102) == 429
        # Other sign-in routes are not affected by the review budget.
        dev = await client.post("/v1/auth/dev-login", json={"email": "a@example.com"})
        assert dev.status_code == 202


async def test_the_reviewer_is_still_limited_on_their_own_address(settings: Settings) -> None:
    async with _client(
        settings, rate_limit_review_login_per_ip_per_minute=2, client_ip_header="Fly-Client-IP"
    ) as client:
        headers = {"Fly-Client-IP": "198.51.100.4"}
        for _ in range(2):
            assert (
                await client.post(REVIEW, json={"code": CODE}, headers=headers)
            ).status_code == 200
        limited = await client.post(REVIEW, json={"code": CODE}, headers=headers)
        assert limited.status_code == 429


async def test_the_review_account_only_sees_its_own_data(settings: Settings) -> None:
    async with _client(settings) as client:
        tester = await bearer(client, "tester@example.com")
        review = await _review_headers(client)
        item = {"raw_label": "eggs", "source": "manual"}
        made = await client.post("/v1/pantry", json={"items": [item]}, headers=tester)
        assert made.status_code == 201, made.text
        tester_item = (await client.get("/v1/pantry", headers=tester)).json()["items"][0]

        assert (await client.get("/v1/pantry", headers=review)).json()["items"] == []
        # Somebody else's row is the same 404 as a missing one, for the review account too.
        stolen = await client.patch(
            f"/v1/pantry/{tester_item['id']}", json={"quantity": 1}, headers=review
        )
        missing = await client.patch(
            "/v1/pantry/00000000-0000-0000-0000-000000000000",
            json={"quantity": 1},
            headers=review,
        )
        assert stolen.status_code == missing.status_code == 404
        assert stolen.json()["error"]["message"] == missing.json()["error"]["message"]

        # Its own data is its own, and invisible to the tester.
        assert (
            await client.post(
                "/v1/pantry",
                json={"items": [{"raw_label": "rice", "source": "manual"}]},
                headers=review,
            )
        ).status_code == 201
        assert len((await client.get("/v1/pantry", headers=review)).json()["items"]) == 1
        assert len((await client.get("/v1/pantry", headers=tester)).json()["items"]) == 1


async def test_the_reviewer_can_delete_the_account_and_sign_in_again(settings: Settings) -> None:
    async with _client(settings) as client:
        review = await _review_headers(client)
        first_id = (await client.get("/v1/me", headers=review)).json()["id"]
        assert (await client.delete("/v1/me", headers=review)).status_code == 204
        assert (await client.get("/v1/me", headers=review)).status_code == 401
        again = await _review_headers(client)
        assert (await client.get("/v1/me", headers=again)).json()["id"] != first_id


def test_a_short_review_code_is_refused_at_startup() -> None:
    base = {"_env_file": None, "jwt_secret": "x" * 40, "auth_mode": "dev"}
    with pytest.raises(ValidationError, match="REVIEW_LOGIN_CODE"):
        Settings(**base, review_login_code="short")
    with pytest.raises(ValidationError, match="REVIEW_LOGIN_CODE"):
        Settings(**base, review_login_code="r" * (MIN_REVIEW_CODE_CHARS - 1))
    ok = Settings(**base, review_login_code="r" * MIN_REVIEW_CODE_CHARS)
    assert ok.review_login_code is not None
    assert "rrrr" not in repr(ok)  # SecretStr
    assert Settings(**base).review_login_code is None
    assert Settings(**base, review_login_code="").review_login_code is None
