"""Brief 019 PR 2: creator cover photos (upload intent, confirm, remove, publish pinning) and the
read-side cover precedence (uploaded photo > https URL > stock photo, with ``cover_credit``)."""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import timedelta
from typing import Any
from urllib.parse import urlsplit

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, update

from app.core.config import Settings
from app.db.models import MediaDeletion, Recipe, RecipeMedia, RecipeVersion, UsageEvent
from app.domains.media.service import reap_expired_uploads
from app.main import create_app
from app.media.storage import S3Storage
from tests.conftest import bearer, draft_payload

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 60
DRAFTS = "/v1/recipes/drafts"


@pytest.fixture
async def env(
    settings: Settings, clean_tables: None, s3_storage: S3Storage
) -> AsyncIterator[tuple[AsyncClient, FastAPI]]:
    app = create_app(settings)
    app.state.storage = s3_storage
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client, app


async def new_draft(client: AsyncClient, headers: dict[str, str], **overrides: Any) -> str:
    res = await client.post(DRAFTS, json=draft_payload(**overrides), headers=headers)
    assert res.status_code == 201, res.text
    return res.json()["id"]


async def intent(
    client: AsyncClient, headers: dict[str, str], draft_id: str, size: int = len(JPEG), **kw: Any
):
    body = {"content_type": "image/jpeg", "size_bytes": size, **kw}
    return await client.post(
        f"{DRAFTS}/{draft_id}/cover/upload-intents", json=body, headers=headers
    )


async def put(app: FastAPI, url: str, data: bytes, content_type: str = "image/jpeg") -> None:
    storage: S3Storage = app.state.storage
    key = urlsplit(url).path.lstrip("/")[len(storage.bucket) + 1 :]
    await asyncio.to_thread(
        storage.client.put_object,
        Bucket=storage.bucket,
        Key=key,
        Body=data,
        ContentType=content_type,
    )


async def upload_cover(
    client: AsyncClient, app: FastAPI, headers: dict[str, str], draft_id: str, data: bytes = JPEG
) -> dict[str, Any]:
    res = await intent(client, headers, draft_id, size=len(data))
    assert res.status_code == 201, res.text
    await put(app, res.json()["upload_url"], data)
    media_id = res.json()["media_id"]
    res = await client.post(f"{DRAFTS}/{draft_id}/cover/{media_id}/uploaded", headers=headers)
    assert res.status_code == 200, res.text
    assert res.json()["cover_media_id"] == media_id
    return res.json()


async def publish(client: AsyncClient, headers: dict[str, str], draft_id: str) -> dict[str, Any]:
    res = await client.post(f"{DRAFTS}/{draft_id}/publish", json={}, headers=headers)
    assert res.status_code == 201, res.text
    return res.json()


async def media(app: FastAPI, media_id: str) -> RecipeMedia | None:
    async with app.state.sessionmaker() as s:
        return await s.get(RecipeMedia, uuid.UUID(media_id))


async def detail(client: AsyncClient, recipe_id: str) -> dict[str, Any]:
    res = await client.get(f"/v1/recipes/{recipe_id}")
    assert res.status_code == 200, res.text
    return res.json()


def is_signed_cover(url: str | None, media_id: str) -> bool:
    return url is not None and "covers/" in url and media_id in url and "Signature" in url


# --- intent / confirm / reject -------------------------------------------------------------


async def test_intent_confirm_sets_draft_cover_and_charges_bytes(env) -> None:
    client, app = env
    alice = await bearer(client, "alice@example.com")
    draft_id = await new_draft(client, alice)
    res = await intent(client, alice, draft_id)
    assert res.status_code == 201, res.text
    body = res.json()
    assert body["method"] == "PUT"
    assert body["headers"] == {"Content-Type": "image/jpeg", "Content-Length": str(len(JPEG))}
    assert body["max_bytes"] == 10 * 1024 * 1024
    await put(app, body["upload_url"], JPEG)
    url = f"{DRAFTS}/{draft_id}/cover/{body['media_id']}/uploaded"
    res = await client.post(url, headers=alice)
    assert res.status_code == 200, res.text
    assert res.json()["cover_media_id"] == body["media_id"]
    # Idempotent.
    assert (await client.post(url, headers=alice)).status_code == 200
    row = await media(app, body["media_id"])
    assert row is not None and row.status == "ready" and row.media_kind.value == "cover_image"
    # The owner can read it through the generic media endpoint (editor preview).
    got = (await client.get(f"/v1/media/{body['media_id']}", headers=alice)).json()
    assert got["kind"] == "cover_image" and got["url"]
    async with app.state.sessionmaker() as s:
        charged = (await s.execute(select(UsageEvent.amount))).scalars().all()
    assert charged == [len(JPEG)]


@pytest.mark.parametrize(
    ("body", "status", "code"),
    [
        ({"content_type": "image/png", "size_bytes": 10}, 415, "IMAGE_TYPE_UNSUPPORTED"),
        (
            {"content_type": "image/jpeg", "size_bytes": 10 * 1024 * 1024 + 1},
            413,
            "IMAGE_TOO_LARGE",
        ),
        ({"content_type": "image/jpeg", "size_bytes": 10, "owns_rights": True}, 422, None),
    ],
)
async def test_intent_refuses_wrong_type_and_size(env, body, status, code) -> None:
    client, _ = env
    alice = await bearer(client, "alice@example.com")
    draft_id = await new_draft(client, alice)
    res = await client.post(f"{DRAFTS}/{draft_id}/cover/upload-intents", json=body, headers=alice)
    assert res.status_code == status, res.text
    if code:
        assert res.json()["error"]["code"] == code


async def test_confirm_rejects_wrong_magic_bytes(env) -> None:
    client, app = env
    alice = await bearer(client, "alice@example.com")
    draft_id = await new_draft(client, alice)
    png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 20
    res = await intent(client, alice, draft_id, size=len(png))
    await put(app, res.json()["upload_url"], png)
    media_id = res.json()["media_id"]
    url = f"{DRAFTS}/{draft_id}/cover/{media_id}/uploaded"
    res = await client.post(url, headers=alice)
    assert res.status_code == 422 and res.json()["error"]["code"] == "UPLOAD_REJECTED"
    row = await media(app, media_id)
    assert row is not None and row.status == "rejected"
    async with app.state.sessionmaker() as s:
        queued = (await s.execute(select(MediaDeletion.storage_key))).scalars().all()
    assert queued == [row.storage_key]
    # A rejected upload stays rejected; the draft has no cover.
    assert (await client.post(url, headers=alice)).status_code == 409
    got = (await client.get(f"{DRAFTS}/{draft_id}", headers=alice)).json()
    assert got["cover_media_id"] is None


async def test_confirm_rejects_size_mismatch(env) -> None:
    client, app = env
    alice = await bearer(client, "alice@example.com")
    draft_id = await new_draft(client, alice)
    res = await intent(client, alice, draft_id, size=len(JPEG))
    await put(app, res.json()["upload_url"], JPEG + b"extra")
    media_id = res.json()["media_id"]
    res = await client.post(f"{DRAFTS}/{draft_id}/cover/{media_id}/uploaded", headers=alice)
    assert res.status_code == 422 and res.json()["error"]["code"] == "UPLOAD_REJECTED"
    assert (await media(app, media_id)).status == "rejected"  # type: ignore[union-attr]


async def test_confirm_missing_object_is_retryable_409(env) -> None:
    client, app = env
    alice = await bearer(client, "alice@example.com")
    draft_id = await new_draft(client, alice)
    res = await intent(client, alice, draft_id)
    media_id = res.json()["media_id"]
    url = f"{DRAFTS}/{draft_id}/cover/{media_id}/uploaded"
    res = await client.post(url, headers=alice)
    assert res.status_code == 409 and res.json()["error"]["code"] == "UPLOAD_INCOMPLETE"
    assert (await media(app, media_id)).status == "pending"  # type: ignore[union-attr]
    # The PUT lands late: confirming again works.
    await put_by_key(app, media_id, JPEG)
    assert (await client.post(url, headers=alice)).status_code == 200


async def put_by_key(app: FastAPI, media_id: str, data: bytes) -> None:
    row = await media(app, media_id)
    assert row is not None
    storage: S3Storage = app.state.storage
    await asyncio.to_thread(
        storage.client.put_object,
        Bucket=storage.bucket,
        Key=row.storage_key,
        Body=data,
        ContentType="image/jpeg",
    )


async def test_pending_cap_and_reaper(env, settings: Settings) -> None:
    client, app = env
    alice = await bearer(client, "alice@example.com")
    draft_id = await new_draft(client, alice)
    for _ in range(5):
        assert (await intent(client, alice, draft_id)).status_code == 201
    res = await intent(client, alice, draft_id)
    assert res.status_code == 429 and res.json()["error"]["code"] == "UPLOAD_LIMIT"
    async with app.state.sessionmaker() as s:
        await s.execute(
            update(RecipeMedia).values(created_at=RecipeMedia.created_at - timedelta(hours=2))
        )
        assert await reap_expired_uploads(s, settings) == 5
        await s.commit()
    assert (await intent(client, alice, draft_id)).status_code == 201


async def test_monthly_byte_budget_is_shared(env, settings: Settings) -> None:
    client, app = env
    alice = await bearer(client, "alice@example.com")
    draft_id = await new_draft(client, alice)
    assert (await intent(client, alice, draft_id)).status_code == 201
    async with app.state.sessionmaker() as s:
        event = (await s.execute(select(UsageEvent))).scalar_one()
        # A month's worth of video bytes already used: the next cover is refused.
        s.add(
            UsageEvent(
                user_id=event.user_id,
                kind=event.kind,
                amount=settings.video_upload_bytes_per_month,
                created_at=event.created_at,
            )
        )
        await s.commit()
    res = await intent(client, alice, draft_id)
    assert res.status_code == 429 and res.json()["error"]["code"] == "UPLOAD_LIMIT"


# --- replace / remove / ownership ----------------------------------------------------------


async def test_replace_and_remove_discard_unpublished_covers(env) -> None:
    client, app = env
    alice = await bearer(client, "alice@example.com")
    draft_id = await new_draft(client, alice)
    first = (await upload_cover(client, app, alice, draft_id))["cover_media_id"]
    second = (await upload_cover(client, app, alice, draft_id))["cover_media_id"]
    assert await media(app, first) is None  # replaced before publish → deleted, object queued
    res = await client.delete(f"{DRAFTS}/{draft_id}/cover", headers=alice)
    assert res.status_code == 200 and res.json()["cover_media_id"] is None
    assert await media(app, second) is None
    assert (await client.delete(f"{DRAFTS}/{draft_id}/cover", headers=alice)).status_code == 200
    async with app.state.sessionmaker() as s:
        queued = (await s.execute(select(MediaDeletion))).scalars().all()
    assert len(queued) == 2


async def test_foreign_draft_and_media_are_the_same_404(env) -> None:
    client, app = env
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    alice_draft = await new_draft(client, alice)
    bob_draft = await new_draft(client, bob)
    missing = str(uuid.uuid4())
    for draft_id in (alice_draft, missing):
        res = await intent(client, bob, draft_id)
        assert res.status_code == 404 and res.json()["error"]["message"] == "Draft not found"
        res = await client.delete(f"{DRAFTS}/{draft_id}/cover", headers=bob)
        assert res.status_code == 404
    res = await intent(client, alice, alice_draft)
    alice_media = res.json()["media_id"]
    await put(app, res.json()["upload_url"], JPEG)
    # Bob confirming Alice's media on his own draft: same 404 as a missing media id.
    for media_id in (alice_media, missing):
        res = await client.post(f"{DRAFTS}/{bob_draft}/cover/{media_id}/uploaded", headers=bob)
        assert res.status_code == 404 and res.json()["error"]["message"] == "Media not found"
    # Alice's media on another of her drafts is also a 404 (it belongs to its own draft).
    other = await new_draft(client, alice)
    res = await client.post(f"{DRAFTS}/{other}/cover/{alice_media}/uploaded", headers=alice)
    assert res.status_code == 404


# --- publish pinning -----------------------------------------------------------------------


async def test_publish_pins_cover_and_v2_leaves_v1_untouched(env) -> None:
    client, app = env
    alice = await bearer(client, "alice@example.com")
    draft_id = await new_draft(client, alice)
    v1_cover = (await upload_cover(client, app, alice, draft_id))["cover_media_id"]
    v1 = await publish(client, alice, draft_id)
    row = await media(app, v1_cover)
    assert row is not None and str(row.version_id) == v1["recipe_version_id"]
    shown = await detail(client, v1["recipe_id"])
    assert is_signed_cover(shown["cover_image_url"], v1_cover)
    assert shown["cover_credit"] is None
    # Published drafts are read-only for covers too.
    assert (await intent(client, alice, draft_id)).status_code == 409

    # Edit: the new draft starts with v1's cover; replacing it keeps v1's photo.
    res = await client.post(f"/v1/recipes/{v1['recipe_id']}/edit", headers=alice)
    assert res.status_code in (200, 201), res.text
    v2_draft = res.json()["id"]
    assert res.json()["cover_media_id"] == v1_cover
    v2_cover = (await upload_cover(client, app, alice, v2_draft))["cover_media_id"]
    assert await media(app, v1_cover) is not None  # pinned to v1: kept
    v2 = await publish(client, alice, v2_draft)
    v1_detail = (
        await client.get(f"/v1/recipe-versions/{v1['recipe_version_id']}", headers=alice)
    ).json()
    assert is_signed_cover(v1_detail["cover_image_url"], v1_cover)
    assert is_signed_cover((await detail(client, v2["recipe_id"]))["cover_image_url"], v2_cover)
    async with app.state.sessionmaker() as s:
        versions = {
            str(v.id): str(v.cover_media_id)
            for v in (await s.execute(select(RecipeVersion))).unique().scalars()
        }
        recipe = await s.get(Recipe, uuid.UUID(v1["recipe_id"]))
    assert versions == {v1["recipe_version_id"]: v1_cover, v2["recipe_version_id"]: v2_cover}
    assert recipe is not None and str(recipe.cover_media_id) == v2_cover
    # A pinned cover can't be deleted through the media endpoint.
    assert (await client.delete(f"/v1/media/{v1_cover}", headers=alice)).status_code == 409


async def test_edit_removing_cover_publishes_without_it(env) -> None:
    client, app = env
    alice = await bearer(client, "alice@example.com")
    draft_id = await new_draft(client, alice)
    cover = (await upload_cover(client, app, alice, draft_id))["cover_media_id"]
    v1 = await publish(client, alice, draft_id)
    v2_draft = (await client.post(f"/v1/recipes/{v1['recipe_id']}/edit", headers=alice)).json()
    res = await client.delete(f"{DRAFTS}/{v2_draft['id']}/cover", headers=alice)
    assert res.status_code == 200
    assert await media(app, cover) is not None  # still v1's
    await publish(client, alice, v2_draft["id"])
    assert (await detail(client, v1["recipe_id"]))["cover_image_url"] is None


async def test_deleting_draft_discards_its_covers(env) -> None:
    client, app = env
    alice = await bearer(client, "alice@example.com")
    draft_id = await new_draft(client, alice)
    cover = (await upload_cover(client, app, alice, draft_id))["cover_media_id"]
    pending = (await intent(client, alice, draft_id)).json()["media_id"]
    assert (await client.delete(f"{DRAFTS}/{draft_id}", headers=alice)).status_code == 204
    assert await media(app, cover) is None and await media(app, pending) is None


# --- read precedence -----------------------------------------------------------------------


async def _set_stock(app: FastAPI, recipe_id: str) -> None:
    async with app.state.sessionmaker() as s:
        await s.execute(
            update(Recipe)
            .where(Recipe.id == uuid.UUID(recipe_id))
            .values(
                stock_photo_url="https://images.pexels.com/photos/1/pexels-photo-1.jpeg",
                stock_photo_credit_name="Jane Doe",
                stock_photo_credit_url="https://www.pexels.com/@jane",
                stock_photo_id="1",
            )
        )
        await s.commit()


async def test_read_precedence_upload_then_url_then_stock(env) -> None:
    client, app = env
    alice = await bearer(client, "alice@example.com")
    # Stock only.
    plain = await publish(client, alice, await new_draft(client, alice, title="Plain Rice"))
    await _set_stock(app, plain["recipe_id"])
    shown = await detail(client, plain["recipe_id"])
    assert shown["cover_image_url"] == "https://images.pexels.com/photos/1/pexels-photo-1.jpeg"
    assert shown["cover_credit"] == {
        "name": "Jane Doe",
        "url": "https://www.pexels.com/@jane",
        "source": "pexels",
    }
    # An https cover_image_url beats stock.
    linked = await publish(
        client,
        alice,
        await new_draft(
            client, alice, title="Linked Soup", cover_image_url="https://example.com/soup.jpg"
        ),
    )
    await _set_stock(app, linked["recipe_id"])
    shown = await detail(client, linked["recipe_id"])
    assert shown["cover_image_url"] == "https://example.com/soup.jpg"
    assert shown["cover_credit"] is None
    # An uploaded photo beats both, on cards (list, saved, creator profile, feeds) too.
    draft_id = await new_draft(
        client, alice, title="Photo Stew", cover_image_url="https://example.com/stew.jpg"
    )
    cover = (await upload_cover(client, app, alice, draft_id))["cover_media_id"]
    photo = await publish(client, alice, draft_id)
    await _set_stock(app, photo["recipe_id"])
    assert (await client.post(f"/v1/recipes/{photo['recipe_id']}/save", headers=alice)).is_success

    def card(items: list[dict[str, Any]]) -> dict[str, Any]:
        return next(i for i in items if i["recipe_id"] == photo["recipe_id"])

    me = (await client.get("/v1/me", headers=alice)).json()
    lists = [
        (await client.get("/v1/recipes")).json()["items"],
        (await client.get("/v1/me/saved", headers=alice)).json()["items"],
        (await client.get("/v1/me/recipes", headers=alice)).json()["items"],
        (await client.get(f"/v1/creators/{me['id']}")).json()["recipes"],
        (await client.get("/v1/feed/for-you", headers=alice)).json()["items"],
    ]
    for items in lists:
        shown_card = card(items)
        assert is_signed_cover(shown_card["cover_image_url"], cover), shown_card
        assert shown_card["cover_credit"] is None
    assert is_signed_cover((await detail(client, photo["recipe_id"]))["cover_image_url"], cover)
    plain_card = next(
        i
        for i in (await client.get("/v1/recipes")).json()["items"]
        if i["recipe_id"] == plain["recipe_id"]
    )
    assert plain_card["cover_credit"]["name"] == "Jane Doe"
