"""Brief 019 PR 2: creator cover photos (upload intent, confirm, reject, replace and remove)."""

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
from app.db.models import MediaDeletion, RecipeMedia, UsageEvent
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


async def media(app: FastAPI, media_id: str) -> RecipeMedia | None:
    async with app.state.sessionmaker() as s:
        return await s.get(RecipeMedia, uuid.UUID(media_id))


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


# --- draft delete ---------------------------------------------------------------------------


async def test_deleting_draft_discards_its_covers(env) -> None:
    client, app = env
    alice = await bearer(client, "alice@example.com")
    draft_id = await new_draft(client, alice)
    cover = (await upload_cover(client, app, alice, draft_id))["cover_media_id"]
    pending = (await intent(client, alice, draft_id)).json()["media_id"]
    assert (await client.delete(f"{DRAFTS}/{draft_id}", headers=alice)).status_code == 204
    assert await media(app, cover) is None and await media(app, pending) is None
