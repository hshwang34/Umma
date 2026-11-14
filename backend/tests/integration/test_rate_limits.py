"""Request rate limits (brief 010): per IP, per user, tighter on sign-in and costly routes."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import pytest
from httpx import ASGITransport, AsyncClient

from app.core.config import Settings
from app.core.ratelimit import COSTLY_PATHS, MAX_KEYS, WINDOW_SECONDS, WindowLimiter
from app.main import create_app
from tests.conftest import bearer

pytestmark = pytest.mark.usefixtures("clean_tables")

LIMITS = {
    "rate_limit_sign_in_per_ip_per_minute": 1000,
    "rate_limit_per_ip_per_minute": 1000,
    "rate_limit_per_user_per_minute": 1000,
    "rate_limit_costly_per_user_per_minute": 1000,
}


@asynccontextmanager
async def _client(settings: Settings, **update: object) -> AsyncIterator[AsyncClient]:
    app = create_app(settings.model_copy(update={**LIMITS, **update}))
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


def _assert_limited(response) -> None:  # type: ignore[no-untyped-def]
    assert response.status_code == 429, response.text
    error = response.json()["error"]
    assert error["code"] == "RATE_LIMITED"
    assert error["retryable"] is True
    assert error["correlation_id"] == response.headers["x-correlation-id"]


# --- the limiter itself ----------------------------------------------------------------------


def test_window_limiter_counts_per_key_and_recovers_after_the_window() -> None:
    now = [0.0]
    limiter = WindowLimiter(2, clock=lambda: now[0])
    assert limiter.allow("a") and limiter.allow("a")
    assert not limiter.allow("a")
    assert limiter.allow("b")  # another key has its own budget
    now[0] = WINDOW_SECONDS - 0.1
    assert not limiter.allow("a")
    now[0] = WINDOW_SECONDS
    assert limiter.allow("a")


def test_window_limiter_zero_is_off_and_the_table_is_bounded() -> None:
    assert all(WindowLimiter(0).allow("a") for _ in range(50))
    now = [0.0]
    limiter = WindowLimiter(5, clock=lambda: now[0])
    for key in range(MAX_KEYS):
        limiter.allow(key)
    now[0] = WINDOW_SECONDS + 1
    limiter.allow("new")
    assert len(limiter._hits) == 1  # idle keys were swept


@pytest.mark.parametrize(
    "path, costly",
    [
        ("/v1/ai/live-token", True),
        ("/v1/media/upload-intents", True),
        ("/v1/capture/sessions", True),
        ("/v1/pantry/receipts", True),
        ("/v1/pantry/observations", True),
        ("/v1/pantry/live-scans/abc/items", True),
        ("/v1/sessions/abc/ask", True),
        ("/v1/sessions/abc/inspect", True),
        ("/v1/substitutions/suggest", True),
        ("/v1/voice/speak", True),
        ("/v1/recipes/drafts/abc/cover/upload-intents", True),
        ("/v1/sessions/abc/commands", False),
        ("/v1/pantry", False),
        ("/v1/pantry/abc", False),
        ("/v1/recipes/drafts/abc", False),
        ("/v1/me", False),
    ],
)
def test_costly_paths(path: str, costly: bool) -> None:
    assert bool(COSTLY_PATHS.search(path)) is costly


# --- sign-in, per IP -------------------------------------------------------------------------


async def test_sign_in_is_limited_per_ip_with_the_standard_envelope(settings: Settings) -> None:
    async with _client(settings, rate_limit_sign_in_per_ip_per_minute=3) as client:
        for _ in range(3):
            ok = await client.post("/v1/auth/dev-login", json={"email": "a@example.com"})
            assert ok.status_code == 202
        _assert_limited(await client.post("/v1/auth/dev-login", json={"email": "b@example.com"}))
        # The verify step shares the budget, and an over-budget call is refused before parsing.
        _assert_limited(await client.post("/v1/auth/dev-login/verify", json={}))
        # Other routes are not affected by the sign-in budget.
        assert (await client.get("/v1/recipes")).status_code == 200


async def test_apple_sign_in_is_limited_per_ip(settings: Settings) -> None:
    body = {"identity_token": "x" * 40, "nonce": "n" * 16}
    async with _client(
        settings, auth_mode="apple", rate_limit_sign_in_per_ip_per_minute=2
    ) as client:
        for _ in range(2):
            assert (await client.post("/v1/auth/apple", json=body)).status_code == 401
        _assert_limited(await client.post("/v1/auth/apple", json=body))


# --- which address counts --------------------------------------------------------------------


async def test_client_ip_header_is_used_only_when_configured(settings: Settings) -> None:
    async with _client(
        settings, rate_limit_per_ip_per_minute=2, client_ip_header="Fly-Client-IP"
    ) as client:
        alice = {"Fly-Client-IP": "203.0.113.7"}
        for _ in range(2):
            assert (await client.get("/v1/recipes", headers=alice)).status_code == 200
        _assert_limited(await client.get("/v1/recipes", headers=alice))
        # Another caller behind the same proxy has their own budget.
        bob = {"fly-client-ip": "203.0.113.8"}
        assert (await client.get("/v1/recipes", headers=bob)).status_code == 200
        # X-Forwarded-For is never read, so it cannot buy a fresh budget.
        spoof = {**alice, "X-Forwarded-For": "198.51.100.1"}
        _assert_limited(await client.get("/v1/recipes", headers=spoof))


async def test_spoofed_headers_are_ignored_when_no_header_is_configured(
    settings: Settings,
) -> None:
    async with _client(settings, rate_limit_per_ip_per_minute=2, client_ip_header=None) as client:
        for n in range(2):
            headers = {"Fly-Client-IP": f"203.0.113.{n}", "X-Forwarded-For": f"198.51.100.{n}"}
            assert (await client.get("/v1/recipes", headers=headers)).status_code == 200
        headers = {"Fly-Client-IP": "203.0.113.99", "X-Forwarded-For": "198.51.100.99"}
        _assert_limited(await client.get("/v1/recipes", headers=headers))


async def test_health_is_never_limited(settings: Settings) -> None:
    async with _client(settings, rate_limit_per_ip_per_minute=1) as client:
        for _ in range(5):
            assert (await client.get("/v1/health")).status_code == 200


# --- per user --------------------------------------------------------------------------------


async def test_authenticated_requests_are_limited_per_user(settings: Settings) -> None:
    async with _client(settings, rate_limit_per_user_per_minute=3) as client:
        alice = await bearer(client, "alice@example.com")
        bob = await bearer(client, "bob@example.com")
        for _ in range(3):
            assert (await client.get("/v1/me", headers=alice)).status_code == 200
        _assert_limited(await client.get("/v1/me", headers=alice))
        assert (await client.get("/v1/me", headers=bob)).status_code == 200
        # A bad token is a 401, not a way to spend someone's budget.
        bad = await client.get("/v1/me", headers={"Authorization": "Bearer nope"})
        assert bad.status_code == 401


async def test_costly_writes_have_their_own_tighter_user_budget(settings: Settings) -> None:
    async with _client(settings, rate_limit_costly_per_user_per_minute=2) as client:
        alice = await bearer(client, "alice@example.com")
        body = {"target": "butter"}
        for _ in range(2):
            response = await client.post("/v1/substitutions/suggest", json=body, headers=alice)
            assert response.status_code != 429
        _assert_limited(await client.post("/v1/substitutions/suggest", json=body, headers=alice))
        # Ordinary routes, and reads on costly routers, are not in that budget.
        assert (await client.get("/v1/me", headers=alice)).status_code == 200
        assert (await client.get("/v1/pantry", headers=alice)).status_code == 200
        bob = await bearer(client, "bob@example.com")
        other = await client.post("/v1/substitutions/suggest", json=body, headers=bob)
        assert other.status_code != 429
