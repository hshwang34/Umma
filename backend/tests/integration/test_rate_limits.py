"""Request rate limits (brief 010): per IP, per user, tighter on sign-in and costly routes."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import pytest
from httpx import ASGITransport, AsyncClient

from app.core.config import Settings
from app.core.ratelimit import (
    COARSE_FACTOR,
    WINDOW_SECONDS,
    IpLimiter,
    RateLimits,
    WindowLimiter,
    _bucket,
    _coarse,
)
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


def test_window_limiter_zero_is_off() -> None:
    assert all(WindowLimiter(0).allow("a") for _ in range(50))


def test_a_full_table_evicts_only_idle_keys() -> None:
    now = [0.0]
    limiter = WindowLimiter(5, clock=lambda: now[0], max_keys=100)
    for key in range(100):
        assert limiter.allow(key)
    now[0] = WINDOW_SECONDS + 1
    assert limiter.allow("new")  # everything else is idle, so there is room again
    assert len(limiter._hits) == 1


def test_a_flood_of_new_keys_never_lifts_an_existing_limit() -> None:
    now = [0.0]
    limiter = WindowLimiter(2, clock=lambda: now[0], max_keys=50)
    assert limiter.allow("victim") and limiter.allow("victim")
    assert not limiter.allow("victim")  # throttled
    flood = [limiter.allow(f"flood-{n}") for n in range(500)]
    # The table filled up; later new keys are refused (fail closed) instead of clearing it.
    assert flood[:49] == [True] * 49
    assert not any(flood[49:])
    assert len(limiter._hits) == 50
    assert not limiter.allow("victim")  # still throttled
    assert limiter.allow("flood-0")  # keys already in the table keep their own budget
    # Once the flood goes quiet, new callers are served again.
    now[0] = WINDOW_SECONDS + 1
    assert limiter.allow("newcomer")


def _sizes(limiter: IpLimiter) -> tuple[int, int, int]:
    return (len(limiter.fine._hits), len(limiter.coarse._hits), len(limiter.overflow._hits))


def test_a_full_ip_table_degrades_to_prefix_buckets_instead_of_locking_out() -> None:
    now = [0.0]
    limiter = IpLimiter(2, clock=lambda: now[0], max_keys=50, coarse_max_keys=10)
    assert limiter.allow("192.0.2.1") and limiter.allow("192.0.2.1")
    assert not limiter.allow("192.0.2.1")  # the victim is throttled
    # A flood from one /16: 49 addresses fill the table, the rest land in their /24 buckets.
    flood = [limiter.allow(f"10.9.{n // 250}.{n % 250 + 1}") for n in range(1000)]
    assert flood[:49] == [True] * 49
    assert _sizes(limiter) == (50, 4, 0)
    # Each flooding /24 got at most its coarse budget, then was throttled.
    assert sum(flood[49:]) <= 4 * 2 * COARSE_FACTOR
    assert not limiter.allow("10.9.0.240")  # a new address from the flooding prefix
    # A new caller from an unrelated prefix is still served while the table is full...
    assert limiter.allow("198.51.100.20")
    assert limiter.allow("2001:db8:5::1")
    # ...and the already-throttled key stays throttled.
    assert not limiter.allow("192.0.2.1")
    assert _sizes(limiter) == (50, 6, 0)


def test_when_the_prefix_table_is_full_too_one_shared_bucket_takes_over() -> None:
    now = [0.0]
    limiter = IpLimiter(1, clock=lambda: now[0], max_keys=5, coarse_max_keys=3)
    for n in range(5):
        assert limiter.allow(f"10.0.{n}.1")  # fills the fine table
    for n in range(3):
        assert limiter.allow(f"10.1.{n}.1")  # fills the coarse table (three /24s)
    served = [limiter.allow(f"10.2.{n}.1") for n in range(100)]  # everyone else: overflow
    assert sum(served) == COARSE_FACTOR
    assert _sizes(limiter) == (5, 3, 1)  # nothing ever exceeds its cap
    assert not limiter.allow("10.0.0.1")  # existing keys keep their own counters
    now[0] = WINDOW_SECONDS + 1
    assert limiter.allow("203.0.113.1")  # the flood went quiet: a normal bucket again
    assert _sizes(limiter) == (1, 3, 1)  # idle prefix buckets go when that table needs room


def test_ipv6_is_capped_per_48_as_well_as_per_64() -> None:
    now = [0.0]
    limiter = IpLimiter(2, clock=lambda: now[0])
    # One allocation presenting a new /64 for every request.
    served = [limiter.allow(f"2001:db8:1:{n:x}::/64") for n in range(100)]
    assert sum(served) == 2 * COARSE_FACTOR
    assert served[: 2 * COARSE_FACTOR] == [True] * (2 * COARSE_FACTOR)
    # Another /48 is unaffected, and a single /64 still has its own smaller limit.
    assert limiter.allow("2001:db8:2:1::/64") and limiter.allow("2001:db8:2:1::/64")
    assert not limiter.allow("2001:db8:2:1::/64")


def test_coarse_buckets() -> None:
    assert _coarse("203.0.113.77") == "203.0.113.0/24"
    assert _coarse("2001:db8:1:2::/64") == "2001:db8:1::/48"
    assert _coarse("peer:unknown") == "peer:unknown"
    assert all(IpLimiter(0).allow("203.0.113.1") for _ in range(50))  # 0 = off


@pytest.mark.parametrize(
    "address, bucket",
    [
        ("203.0.113.7", "203.0.113.7"),
        (" 203.0.113.7 ", "203.0.113.7"),
        ("2001:db8:1:2:aaaa::1", "2001:db8:1:2::/64"),
        ("2001:db8:1:2:ffff:ffff:ffff:ffff", "2001:db8:1:2::/64"),
        ("2001:db8:1:3::1", "2001:db8:1:3::/64"),
        ("::ffff:203.0.113.7", "203.0.113.7"),
        ("203.0.113.7, 10.0.0.1", None),
        ("not-an-address", None),
        ("", None),
        (None, None),
    ],
)
def test_address_buckets(address: str | None, bucket: str | None) -> None:
    assert _bucket(address) == bucket


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


async def test_ipv6_callers_share_a_bucket_per_64(settings: Settings) -> None:
    async with _client(
        settings, rate_limit_per_ip_per_minute=2, client_ip_header="Fly-Client-IP"
    ) as client:
        for host in ("1", "2"):
            headers = {"Fly-Client-IP": f"2001:db8:aa:bb::{host}"}
            assert (await client.get("/v1/recipes", headers=headers)).status_code == 200
        # A third address in the same /64 is the same customer.
        same = {"Fly-Client-IP": "2001:db8:aa:bb:1234:5678:9abc:def0"}
        _assert_limited(await client.get("/v1/recipes", headers=same))
        # A different /64 is not.
        other = {"Fly-Client-IP": "2001:db8:aa:cc::1"}
        assert (await client.get("/v1/recipes", headers=other)).status_code == 200


async def test_a_garbage_client_ip_header_is_never_used_as_a_key(settings: Settings) -> None:
    async with _client(
        settings, rate_limit_per_ip_per_minute=2, client_ip_header="Fly-Client-IP"
    ) as client:
        # Each value is different, so if the text were the key every call would pass.
        for value in ("garbage-1", "203.0.113.7, 10.0.0.1"):
            response = await client.get("/v1/recipes", headers={"Fly-Client-IP": value})
            assert response.status_code == 200
        _assert_limited(await client.get("/v1/recipes", headers={"Fly-Client-IP": "garbage-3"}))
        limits: RateLimits = client._transport.app.state.rate_limits  # type: ignore[attr-defined]
        assert all("garbage" not in str(key) for key in limits.ip.fine._hits)
        assert len(limits.ip.fine._hits) == 1  # the socket peer


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
        assert (await client.get("/v1/pantry/live-scans/nope", headers=alice)).status_code != 429
        assert (await client.post("/v1/pantry", json={}, headers=alice)).status_code != 429
        bob = await bearer(client, "bob@example.com")
        other = await client.post("/v1/substitutions/suggest", json=body, headers=bob)
        assert other.status_code != 429
        # Without a valid token the costly marker does nothing: the route answers 401.
        anonymous = await client.post("/v1/substitutions/suggest", json=body)
        assert anonymous.status_code == 401


# Every write route, classified. COSTLY spends money, storage or a provider call (AI, voice,
# extraction, receipts, live tokens, upload intents, uploaded callbacks, publish) and must be
# marked with ``Depends(limit_costly)``. A new write route fails the test below until it is
# added to one of the sets, so the question "does this cost something?" is always asked.
COSTLY_WRITES = {
    ("POST", "/v1/ai/live-token"),
    ("POST", "/v1/capture/sessions"),
    ("DELETE", "/v1/capture/sessions/{session_id}"),
    ("POST", "/v1/capture/sessions/{session_id}/commands"),
    ("POST", "/v1/capture/sessions/{session_id}/finish"),
    ("POST", "/v1/capture/sessions/{session_id}/generate"),
    ("POST", "/v1/capture/sessions/{session_id}/questions/{question_id}"),
    ("POST", "/v1/capture/sessions/{session_id}/turns"),
    ("POST", "/v1/media/upload-intents"),
    ("POST", "/v1/media/{media_id}/uploaded"),
    ("DELETE", "/v1/media/{media_id}"),
    ("POST", "/v1/pantry/live-scans"),
    ("POST", "/v1/pantry/live-scans/{scan_id}/finish"),
    ("POST", "/v1/pantry/live-scans/{scan_id}/items"),
    ("DELETE", "/v1/pantry/live-scans/{scan_id}/items/{key}"),
    ("POST", "/v1/pantry/observations"),
    ("POST", "/v1/pantry/receipts"),
    ("POST", "/v1/pantry/receipts/{receipt_id}/undo"),
    ("POST", "/v1/recipes/drafts/{draft_id}/cover/upload-intents"),
    ("POST", "/v1/recipes/drafts/{draft_id}/cover/{media_id}/uploaded"),
    ("POST", "/v1/recipes/drafts/{draft_id}/publish"),
    ("POST", "/v1/recipes/drafts/{draft_id}/steps/{step_id}/trim"),
    ("POST", "/v1/sessions/{session_id}/ask"),
    ("POST", "/v1/sessions/{session_id}/inspect"),
    ("POST", "/v1/substitutions/suggest"),
    ("POST", "/v1/voice/speak"),
}
ORDINARY_WRITES = {
    ("PUT", "/v1/creators/{creator_id}/follow"),
    ("DELETE", "/v1/creators/{creator_id}/follow"),
    ("PATCH", "/v1/me"),
    ("POST", "/v1/me/onboarding/complete"),
    ("PUT", "/v1/me/preferences"),
    ("POST", "/v1/pantry"),
    ("PATCH", "/v1/pantry/{item_id}"),
    ("DELETE", "/v1/pantry/{item_id}"),
    ("POST", "/v1/pantry/{item_id}/confirm"),
    ("DELETE", "/v1/recipe-versions/{version_id}/my-variation"),
    ("POST", "/v1/recipe-versions/{version_id}/fit"),
    ("POST", "/v1/recipes/drafts"),
    ("PATCH", "/v1/recipes/drafts/{draft_id}"),
    ("DELETE", "/v1/recipes/drafts/{draft_id}"),
    ("DELETE", "/v1/recipes/drafts/{draft_id}/cover"),
    ("POST", "/v1/recipes/{recipe_id}/edit"),
    ("POST", "/v1/recipes/{recipe_id}/save"),
    ("DELETE", "/v1/recipes/{recipe_id}/save"),
    ("POST", "/v1/recipes/{recipe_id}/unpublish"),
    ("POST", "/v1/sessions"),
    ("DELETE", "/v1/sessions/{session_id}"),
    ("POST", "/v1/sessions/{session_id}/commands"),
    ("POST", "/v1/sessions/{session_id}/notes"),
    ("POST", "/v1/shopping-list"),
    ("DELETE", "/v1/shopping-list/{item_id}"),
    ("POST", "/v1/shopping-list/{item_id}/check"),
    ("POST", "/v1/shopping-list/{item_id}/uncheck"),
}
# Sign-in routes have their own per-IP budget (limit_sign_in) and no user yet.
SIGN_IN_WRITES = {
    ("POST", "/v1/auth/dev-login"),
    ("POST", "/v1/auth/dev-login/verify"),
}
MONEY_WORDS = (
    "/ai/",
    "/voice/",
    "upload",
    "/publish",
    "extract",
    "generate",
    "receipt",
    "live-",
    "/ask",
    "/inspect",
    "/trim",
    "observations",
    "suggest",
)
NIL_UUID = "00000000-0000-0000-0000-000000000000"


async def test_every_write_route_is_classified_and_costly_ones_are_limited(
    settings: Settings,
) -> None:
    async with _client(settings, rate_limit_costly_per_user_per_minute=1) as client:
        app = client._transport.app  # type: ignore[attr-defined]
        writes = {
            (method.upper(), path)
            for path, operations in app.openapi()["paths"].items()
            for method in operations
            if method.upper() in {"POST", "PUT", "PATCH", "DELETE"}
        }
        assert not (COSTLY_WRITES & ORDINARY_WRITES)
        assert writes == COSTLY_WRITES | ORDINARY_WRITES | SIGN_IN_WRITES
        # Nothing that sounds like it spends money may sit in the ordinary set.
        assert not [r for r in ORDINARY_WRITES if any(word in r[1] for word in MONEY_WORDS)]

        headers = await bearer(client, "alice@example.com")
        limits: RateLimits = app.state.rate_limits

        async def second_call_status(method: str, template: str) -> int:
            limits.costly_user._hits.clear()
            path = template.replace("{key}", "egg").replace("{step_id}", "s1")
            for name in template.split("{")[1:]:
                path = path.replace("{" + name.split("}")[0] + "}", NIL_UUID)
            first = await client.request(method, path, headers=headers)
            assert first.status_code != 429, (method, template)
            return (await client.request(method, path, headers=headers)).status_code

        for method, template in sorted(COSTLY_WRITES):
            assert await second_call_status(method, template) == 429, (method, template)
        for method, template in sorted(ORDINARY_WRITES):
            assert await second_call_status(method, template) != 429, (method, template)
