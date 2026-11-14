"""POST /v1/pantry/receipts/{id}/undo (brief 017 PR 2c): whole-receipt undo, touched items kept."""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncEngine

from app.core.config import Settings
from app.db.models import PantryReceipt
from app.main import create_app
from tests.conftest import bearer
from tests.integration.test_pantry_receipts import (
    StubReader,
    food,
    pantry,
    receipt,
    receipt_rows,
    stock,
    upload,
)

pytestmark = pytest.mark.usefixtures("ingredients")


@pytest.fixture
async def app(settings: Settings, clean_tables: None) -> AsyncIterator[FastAPI]:
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        yield app


@pytest.fixture
async def client(app: FastAPI) -> AsyncIterator[AsyncClient]:
    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def undo(client: AsyncClient, h: dict[str, str], receipt_id: object):
    return await client.post(f"/v1/pantry/receipts/{receipt_id}/undo", headers=h)


async def shop(app: FastAPI, client: AsyncClient, h: dict[str, str], *lines: dict, **kw) -> dict:
    app.state.ai_provider = StubReader(receipt(*lines, **kw))
    res = await upload(client, h)
    assert res.status_code == 200, res.text
    return res.json()


BUTTER = food("butter", "BUTTER 5KG", quantity="5", unit="kg")
MILK = food("whole milk", "ORG WHOLE MILK")
EGGS = food("egg", "EGGS x2", count=2)


async def test_undo_removes_created_items_and_restores_merged_ones(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "cook@example.com")
    await stock(
        client,
        h,
        {"raw_label": "butter", "quantity": 2, "unit": "kg", "note": "salted"},
        {"raw_label": "garlic"},
        {"raw_label": "rice", "quantity": 1, "unit": "kg"},  # not on the receipt
    )
    before = await pantry(client, h)
    saved = await shop(app, client, h, BUTTER, MILK, EGGS, food("garlic", "GARLIC BULB"))
    assert (len(saved["added"]), len(saved["merged"])) == (2, 2)
    assert (await pantry(client, h))["butter"]["quantity"] == 7.0

    res = await undo(client, h, saved["receipt_id"])
    assert res.status_code == 200, res.text
    assert res.json() == {
        "receipt_id": saved["receipt_id"],
        "removed": 2,
        "restored": 2,
        "unchanged": [],
    }
    after = await pantry(client, h)
    assert set(after) == {"butter", "garlic", "rice"}
    for key in after:  # amount, unit and "last seen" are back; nothing else moved
        was = {k: v for k, v in before[key].items() if k != "updated_at"}
        assert {k: v for k, v in after[key].items() if k != "updated_at"} == was, key
    assert await receipt_rows(engine) == []

    # A second undo is a 404 and restores nothing twice.
    again = await undo(client, h, saved["receipt_id"])
    assert (again.status_code, again.json()["error"]["code"]) == (404, "NOT_FOUND")
    assert await pantry(client, h) == after

    # The same receipt can be photographed again and is saved afresh, not a duplicate.
    resaved = await shop(app, client, h, BUTTER, MILK, EGGS, food("garlic", "GARLIC BULB"))
    assert resaved["duplicate"] is False and resaved["receipt_id"] != saved["receipt_id"]
    assert (await pantry(client, h))["butter"]["quantity"] == 7.0


async def test_items_touched_after_the_receipt_are_left_and_reported(
    app: FastAPI, client: AsyncClient
) -> None:
    h = await bearer(client, "cook@example.com")
    await stock(
        client,
        h,
        {"raw_label": "butter", "quantity": 2, "unit": "kg"},
        {"raw_label": "garlic", "quantity": 3},
    )
    saved = await shop(
        app, client, h, BUTTER, MILK, EGGS, food("garlic", "GARLIC"), food("rice", "RICE")
    )
    ids = {i["normalized_name"]: i["id"] for i in [*saved["added"], *saved["merged"]]}
    # Edited (same amount, another field), confirmed, and deleted since the receipt.
    res = await client.patch(f"/v1/pantry/{ids['milk']}", json={"note": "open"}, headers=h)
    assert res.status_code == 200, res.text
    res = await client.post(f"/v1/pantry/{ids['butter']}/confirm", headers=h)
    assert res.status_code == 200, res.text
    assert (await client.delete(f"/v1/pantry/{ids['egg']}", headers=h)).status_code == 204
    assert (await client.delete(f"/v1/pantry/{ids['garlic']}", headers=h)).status_code == 204
    touched = await pantry(client, h)

    res = await undo(client, h, saved["receipt_id"])
    assert res.status_code == 200, res.text
    body = res.json()
    assert (body["removed"], body["restored"]) == (1, 0)  # only the untouched rice
    assert sorted(body["unchanged"]) == ["butter", "whole milk"]
    after = await pantry(client, h)
    assert set(after) == {"butter", "milk"}
    assert after == {k: touched[k] for k in after}
    assert (after["butter"]["quantity"], after["milk"]["note"]) == (7.0, "open")


async def test_a_later_receipt_that_merged_into_an_item_blocks_its_undo(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "cook@example.com")
    await stock(client, h, {"raw_label": "butter", "quantity": 2, "unit": "kg"})
    stocked = await pantry(client, h)
    first = await shop(app, client, h, BUTTER, MILK)
    second = await shop(app, client, h, BUTTER, food("milk", "MILK x2", count=2), total="9.99")
    assert [i["normalized_name"] for i in second["merged"]] == ["butter", "milk"]
    both = await pantry(client, h)
    assert (both["butter"]["quantity"], both["milk"]["quantity"]) == (12.0, 3.0)

    body = (await undo(client, h, first["receipt_id"])).json()
    assert (body["removed"], body["restored"]) == (0, 0)
    assert sorted(body["unchanged"]) == ["butter", "whole milk"]
    assert await pantry(client, h) == both
    assert len(await receipt_rows(engine)) == 1  # the first receipt's row is gone all the same

    # The later receipt still undoes cleanly, back to what the first one left.
    body = (await undo(client, h, second["receipt_id"])).json()
    assert (body["removed"], body["restored"], body["unchanged"]) == (0, 2, [])
    after = await pantry(client, h)
    assert (after["butter"]["quantity"], after["milk"]["quantity"]) == (7.0, 1.0)
    assert after["butter"]["last_confirmed_at"] != stocked["butter"]["last_confirmed_at"]
    assert after["butter"]["last_confirmed_at"] == first["merged"][0]["last_confirmed_at"]


async def test_another_users_receipt_is_the_same_404_as_a_missing_one(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "cook@example.com")
    other = await bearer(client, "other@example.com")
    await stock(client, h, {"raw_label": "butter", "quantity": 2, "unit": "kg"})
    saved = await shop(app, client, h, BUTTER, MILK)
    mine = await pantry(client, h)

    foreign = await undo(client, other, saved["receipt_id"])
    missing = await undo(client, other, uuid.uuid4())
    malformed = await undo(client, other, "not-a-uuid")
    assert foreign.status_code == missing.status_code == malformed.status_code == 404
    strip = lambda r: {k: v for k, v in r.json()["error"].items() if k != "correlation_id"}  # noqa: E731
    assert strip(foreign) == strip(missing) == strip(malformed)
    assert await pantry(client, h) == mine
    assert len(await receipt_rows(engine)) == 1
    assert (await client.post(f"/v1/pantry/receipts/{saved['receipt_id']}/undo")).status_code == 401


async def test_a_row_without_a_usable_record_is_left_alone(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "cook@example.com")
    await stock(client, h, {"raw_label": "butter", "quantity": 2, "unit": "kg"})
    saved = await shop(app, client, h, BUTTER, MILK)
    (stored,) = await receipt_rows(engine)
    stored["response"]["added"] = []  # what the receipt left the created item as is unknown
    stored["undo"]["merged"][0]["previous"] = {"quantity": "2"}  # an incomplete snapshot
    async with engine.begin() as conn:
        await conn.execute(update(PantryReceipt).values(result_json=stored))
    kept = await pantry(client, h)

    body = (await undo(client, h, saved["receipt_id"])).json()
    assert (body["removed"], body["restored"]) == (0, 0)
    assert sorted(body["unchanged"]) == ["butter", "whole milk"]
    assert await pantry(client, h) == kept
    assert await receipt_rows(engine) == []
