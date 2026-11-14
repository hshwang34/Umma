"""Brief 019 PR 3: Pexels stock photos (adapter, post-publish lookup, backfill). The Pexels API
is always a mocked httpx transport; no test touches the network."""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator, Callable
from typing import Any

import httpx
import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from pydantic import SecretStr

from app.core.config import Settings
from app.db.models import Recipe
from app.domains.recipes import stock_photos
from app.main import create_app
from app.media.storage import S3Storage
from app.scripts import covers
from tests.conftest import bearer, draft_payload
from tests.integration.test_cover_photos import upload_cover

DRAFTS = "/v1/recipes/drafts"


def photo(n: int = 1) -> dict[str, Any]:
    return {
        "id": n,
        "photographer": f"Jane {n}",
        "photographer_url": f"https://www.pexels.com/@jane{n}",
        "src": {
            "landscape": f"https://images.pexels.com/photos/{n}/l.jpeg",
            "large": f"https://images.pexels.com/photos/{n}/xl.jpeg",
        },
    }


class FakePexels:
    """Answers by query; records every request."""

    def __init__(self, answers: dict[str, Any] | None = None, *, fail: bool = False) -> None:
        self.answers = answers or {}
        self.fail = fail
        self.requests: list[httpx.Request] = []

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.fail:
            raise httpx.ConnectTimeout("timed out", request=request)
        found = self.answers.get(request.url.params["query"])
        return httpx.Response(200, json={"photos": [found] if found else []})

    def client(self) -> stock_photos.PexelsClient:
        return stock_photos.PexelsClient("test-key", transport=httpx.MockTransport(self.handler))

    @property
    def queries(self) -> list[str]:
        return [r.url.params["query"] for r in self.requests]


@pytest.fixture
async def make_env(
    settings: Settings, clean_tables: None, s3_storage: S3Storage
) -> AsyncIterator[Callable[..., Any]]:
    stack: list[Any] = []

    async def make(pexels: FakePexels | None) -> tuple[AsyncClient, FastAPI]:
        app = create_app(settings)
        app.state.storage = s3_storage
        app.state.stock_photos = pexels.client() if pexels else None
        ctx = app.router.lifespan_context(app)
        await ctx.__aenter__()
        client = AsyncClient(
            transport=ASGITransport(app=app, raise_app_exceptions=False), base_url="http://test"
        )
        stack.append((ctx, client))
        return client, app

    yield make
    for ctx, client in reversed(stack):
        await client.aclose()
        await ctx.__aexit__(None, None, None)


async def publish_new(
    client: AsyncClient, headers: dict[str, str], **overrides: Any
) -> dict[str, Any]:
    res = await client.post(DRAFTS, json=draft_payload(**overrides), headers=headers)
    assert res.status_code == 201, res.text
    res = await client.post(f"{DRAFTS}/{res.json()['id']}/publish", json={}, headers=headers)
    assert res.status_code == 201, res.text
    return res.json()


async def recipe_row(app: FastAPI, recipe_id: str) -> Recipe:
    async with app.state.sessionmaker() as s:
        row = await s.get(Recipe, uuid.UUID(recipe_id))
    assert row is not None
    return row


async def test_first_publish_stores_photo_and_credit(make_env) -> None:
    pexels = FakePexels({"Glazed Chicken Thighs": photo(7)})
    client, app = await make_env(pexels)
    alice = await bearer(client, "alice@example.com")
    published = await publish_new(client, alice, title="Glazed Chicken Thighs")
    row = await recipe_row(app, published["recipe_id"])
    assert row.stock_photo_url == "https://images.pexels.com/photos/7/l.jpeg"
    assert row.stock_photo_credit_name == "Jane 7"
    assert row.stock_photo_credit_url == "https://www.pexels.com/@jane7"
    assert row.stock_photo_id == "7"
    request = pexels.requests[0]
    assert request.headers["Authorization"] == "test-key"
    assert request.url.params["per_page"] == "1"
    assert request.url.params["orientation"] == "landscape"
    shown = (await client.get(f"/v1/recipes/{published['recipe_id']}")).json()
    assert shown["cover_image_url"] == row.stock_photo_url
    assert shown["cover_credit"] == {
        "name": "Jane 7",
        "url": "https://www.pexels.com/@jane7",
        "source": "pexels",
    }


async def test_empty_result_retries_with_last_two_words_plus_food(make_env) -> None:
    pexels = FakePexels({"Chicken Thighs food": photo(3)})
    client, app = await make_env(pexels)
    alice = await bearer(client, "alice@example.com")
    published = await publish_new(client, alice, title="Grandma's Sticky Chicken Thighs")
    assert pexels.queries == ["Grandma's Sticky Chicken Thighs", "Chicken Thighs food"]
    assert (await recipe_row(app, published["recipe_id"])).stock_photo_id == "3"


async def test_empty_twice_stores_nothing(make_env) -> None:
    pexels = FakePexels({})
    client, app = await make_env(pexels)
    alice = await bearer(client, "alice@example.com")
    published = await publish_new(client, alice, title="Mystery Dish")
    assert len(pexels.requests) == 2
    row = await recipe_row(app, published["recipe_id"])
    assert row.stock_photo_url is None and row.stock_photo_id is None
    shown = (await client.get(f"/v1/recipes/{published['recipe_id']}")).json()
    assert shown["cover_image_url"] is None and shown["cover_credit"] is None


async def test_pexels_error_never_breaks_publish(make_env) -> None:
    pexels = FakePexels(fail=True)
    client, app = await make_env(pexels)
    alice = await bearer(client, "alice@example.com")
    published = await publish_new(client, alice, title="Timeout Tacos")
    assert pexels.requests  # it was tried
    assert (await recipe_row(app, published["recipe_id"])).stock_photo_url is None


async def test_http_error_status_is_swallowed(make_env) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(429, json={"error": "rate limited"})

    client, app = await make_env(None)
    app.state.stock_photos = stock_photos.PexelsClient(
        "test-key", transport=httpx.MockTransport(handler)
    )
    alice = await bearer(client, "alice@example.com")
    published = await publish_new(client, alice, title="Busy Bibimbap")
    assert (await recipe_row(app, published["recipe_id"])).stock_photo_url is None


async def test_no_key_skips_lookup(make_env, settings: Settings, caplog, monkeypatch) -> None:
    monkeypatch.setattr(stock_photos, "_warned_no_key", False)
    keyless = settings.model_copy(update={"pexels_api_key": None})
    blank = settings.model_copy(update={"pexels_api_key": SecretStr("")})
    with caplog.at_level("INFO", logger="umma.stock_photos"):
        assert stock_photos.build_client(keyless) is None
        assert stock_photos.build_client(blank) is None
    keyed = settings.model_copy(update={"pexels_api_key": SecretStr("k")})
    assert isinstance(stock_photos.build_client(keyed), stock_photos.PexelsClient)
    assert sum("PEXELS_API_KEY" in r.getMessage() for r in caplog.records) == 1
    client, app = await make_env(None)
    alice = await bearer(client, "alice@example.com")
    published = await publish_new(client, alice, title="Keyless Kimchi")
    assert (await recipe_row(app, published["recipe_id"])).stock_photo_url is None


async def test_key_is_never_in_settings_repr(settings: Settings) -> None:
    keyed = settings.model_copy(update={"pexels_api_key": SecretStr("sekrit-pexels-key")})
    assert "sekrit-pexels-key" not in repr(keyed)


async def test_creator_cover_wins_and_removing_it_falls_back_to_stock(make_env) -> None:
    pexels = FakePexels({"Photo Stew": photo(5)})
    client, app = await make_env(pexels)
    alice = await bearer(client, "alice@example.com")
    # A creator URL cover: no lookup on publish.
    linked = await publish_new(
        client, alice, title="Photo Stew", cover_image_url="https://example.com/stew.jpg"
    )
    assert pexels.requests == []
    assert (await recipe_row(app, linked["recipe_id"])).stock_photo_url is None
    # An uploaded cover: no lookup either.
    res = await client.post(DRAFTS, json=draft_payload(title="Photo Stew"), headers=alice)
    draft_id = res.json()["id"]
    cover = (await upload_cover(client, app, alice, draft_id))["cover_media_id"]
    res = await client.post(f"{DRAFTS}/{draft_id}/publish", json={}, headers=alice)
    recipe_id = res.json()["recipe_id"]
    assert pexels.requests == []
    # The backfill skips it too, while the creator photo is there.
    async with app.state.sessionmaker() as s:
        assert uuid.UUID(recipe_id) not in await stock_photos.recipes_without_cover(s)
    # Stock stored anyway (e.g. before the creator added a photo): the creator photo still wins.
    async with app.state.sessionmaker() as s:
        row = await s.get(Recipe, uuid.UUID(recipe_id))
        assert row is not None
        row.stock_photo_url = "https://images.pexels.com/photos/5/l.jpeg"
        row.stock_photo_credit_name = "Jane 5"
        row.stock_photo_credit_url = "https://www.pexels.com/@jane5"
        row.stock_photo_id = "5"
        await s.commit()
    shown = (await client.get(f"/v1/recipes/{recipe_id}")).json()
    assert cover in shown["cover_image_url"] and shown["cover_credit"] is None
    # The creator removes the photo in an edit and republishes: the stock photo shows.
    edit = (await client.post(f"/v1/recipes/{recipe_id}/edit", headers=alice)).json()
    assert (await client.delete(f"{DRAFTS}/{edit['id']}/cover", headers=alice)).status_code == 200
    res = await client.post(f"{DRAFTS}/{edit['id']}/publish", json={}, headers=alice)
    assert res.status_code == 201, res.text
    shown = (await client.get(f"/v1/recipes/{recipe_id}")).json()
    assert shown["cover_image_url"] == "https://images.pexels.com/photos/5/l.jpeg"
    assert shown["cover_credit"]["name"] == "Jane 5"


async def test_backfill_fills_missing_and_redoes_one(make_env, monkeypatch) -> None:
    client, app = await make_env(None)  # publish without lookups
    alice = await bearer(client, "alice@example.com")
    a = await publish_new(client, alice, title="Alpha Soup")
    b = await publish_new(client, alice, title="Beta Bread")
    c = await publish_new(
        client, alice, title="Gamma Salad", cover_image_url="https://example.com/g.jpg"
    )
    pexels = FakePexels({"Alpha Soup": photo(1), "Beta Bread": photo(2)})
    sleeps: list[float] = []

    async def fake_sleep(seconds: float) -> None:
        sleeps.append(seconds)

    monkeypatch.setattr(covers.asyncio, "sleep", fake_sleep)
    monkeypatch.setattr(covers.stock_photos, "build_client", lambda _s: pexels.client())
    monkeypatch.setattr(covers, "get_settings", lambda: app.state.settings)
    assert await covers.run(None, 40.0) == 2
    assert sleeps == [40.0]  # between the two recipes
    assert (await recipe_row(app, a["recipe_id"])).stock_photo_id == "1"
    assert (await recipe_row(app, b["recipe_id"])).stock_photo_id == "2"
    assert (await recipe_row(app, c["recipe_id"])).stock_photo_url is None
    # A second run finds nothing to do.
    assert await covers.run(None, 40.0) == 0
    # --recipe redoes one, replacing its stored photo.
    pexels.answers["Alpha Soup"] = photo(9)
    assert await covers.run(uuid.UUID(a["recipe_id"]), 40.0) == 1
    assert (await recipe_row(app, a["recipe_id"])).stock_photo_id == "9"
    # Two requests per recipe at most, one recipe per sleep: under 200 requests an hour.
    assert 2 * 3600 / covers.DEFAULT_SLEEP_SECONDS < 200


def test_queries_for_title() -> None:
    assert stock_photos.queries_for("Glazed Chicken Thighs") == [
        "Glazed Chicken Thighs",
        "Chicken Thighs food",
    ]
    assert stock_photos.queries_for("Bibimbap") == ["Bibimbap", "Bibimbap food"]
