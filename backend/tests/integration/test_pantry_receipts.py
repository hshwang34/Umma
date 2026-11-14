"""POST /v1/pantry/receipts (brief 017 PR 2): save rule, rebuy merge, repeat, demo, failures."""

from __future__ import annotations

from collections.abc import AsyncIterator
from datetime import datetime

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncEngine

from app.ai.providers.base import ReceiptDraft
from app.core.config import Settings
from app.core.errors import AIResting, ProviderOutputInvalid
from app.db.models import PantryReceipt
from app.main import create_app
from tests.conftest import bearer

pytestmark = pytest.mark.usefixtures("ingredients")

URL = "/v1/pantry/receipts"
JPEG = b"\xff\xd8\xff\xe0" + b"\x01" * 64


class StubReader:
    """Stands in for the provider: answers with a fixed draft or raises a fixed error."""

    name = "stub"

    def __init__(self, answer: ReceiptDraft | Exception) -> None:
        self.answer = answer

    async def read_receipt(self, request: object) -> ReceiptDraft:
        if isinstance(self.answer, Exception):
            raise self.answer
        return self.answer


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


def food(name: str | None, raw: str, **kw: object) -> dict:
    return {"raw_text": raw, "name": name, "is_food": True, "count": 1, "confidence": 0.95, **kw}


def receipt(*lines: dict, **kw: object) -> ReceiptDraft:
    fields = {"purchased_on": "2026-11-14", "store": "Corner Shop", "total": "23.10"}
    return ReceiptDraft.model_validate({**fields, **kw, "lines": list(lines)})


async def upload(client: AsyncClient, h: dict[str, str], data: bytes = JPEG):
    return await client.post(URL, files={"image": ("receipt.jpg", data, "image/jpeg")}, headers=h)


async def pantry(client: AsyncClient, h: dict[str, str]) -> dict[str, dict]:
    items = (await client.get("/v1/pantry", headers=h)).json()["items"]
    return {i["normalized_name"]: i for i in items}


async def stock(client: AsyncClient, h: dict[str, str], *items: dict) -> None:
    body = {"items": [{"source": "manual", **i} for i in items]}
    res = await client.post("/v1/pantry", json=body, headers=h)
    assert res.status_code == 201, res.text


async def receipt_rows(engine: AsyncEngine) -> list[dict]:
    async with engine.connect() as conn:
        return list((await conn.execute(select(PantryReceipt.result_json))).scalars())


async def test_saves_only_food_dictionary_high_confidence_lines(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "cook@example.com")
    other = await bearer(client, "other@example.com")
    await stock(client, other, {"raw_label": "milk", "quantity": 1})
    app.state.ai_provider = StubReader(
        receipt(
            food("whole milk", "ORG WHOLE MILK"),
            food("egg", "LRG EGGS 12CT", count=2),
            food("egg", "EGGS 6CT"),
            food("chicken thigh", "CHKN THIGH 1.24 lb", quantity="1.24", unit="lb"),
            food("butter", "KS SLT BTR", confidence=0.62),
            food("xylofruit", "XYLOFRUIT 2PK"),
            food(None, "GV PRM 4X 22", confidence=0.2),
            {"raw_text": "PAPER TOWELS", "name": None, "is_food": False, "confidence": 0.95},
        )
    )
    res = await upload(client, h)
    assert res.status_code == 200, res.text
    body = res.json()
    assert (body["duplicate"], body["demo"], body["merged"]) == (False, False, [])
    assert (body["purchased_on"], body["store"]) == ("2026-11-14", "Corner Shop")
    assert [
        (i["normalized_name"], i["quantity"], i["unit"], i["source"]) for i in body["added"]
    ] == [
        ("milk", 1.0, None, "receipt"),
        ("egg", 3.0, None, "receipt"),
        ("chicken thigh", 1.24, "lb", "receipt"),
    ]
    assert body["skipped"] == [
        {"raw_text": "KS SLT BTR", "reason": "low_confidence"},
        {"raw_text": "XYLOFRUIT 2PK", "reason": "unknown_item"},
        {"raw_text": "GV PRM 4X 22", "reason": "unreadable"},
    ]
    assert "PAPER TOWELS" not in res.text
    assert set(await pantry(client, h)) == {"milk", "egg", "chicken thigh"}
    theirs = await pantry(client, other)  # another user's pantry is untouched
    assert (theirs["milk"]["quantity"], theirs["milk"]["source"]) == (1.0, "manual")
    (stored,) = await receipt_rows(engine)
    assert stored["undo"] == {
        "created": [i["id"] for i in body["added"]],
        "merged": [],
        "shopping_checked": [],
    }


KEPT = ("source", "confidence", "quantity_is_estimate", "storage_location", "note")


async def test_rebought_items_merge_and_refresh_last_seen(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "cook@example.com")
    photo = {"source": "photo", "confidence": 0.7, "quantity_is_estimate": True}
    await stock(
        client,
        h,
        {"raw_label": "butter", "quantity": 2, "unit": "kg", "storage_location": "fridge"},
        {"raw_label": "milk", "quantity": 1, "note": "the blue carton", **photo},
        {"raw_label": "chicken thigh", "quantity": 500, "unit": "g"},
        {"raw_label": "soy sauce", "quantity": 1, "unit": "cup"},
        {"raw_label": "garlic"},
        {"raw_label": "egg", "quantity": 999_999},
    )
    before = await pantry(client, h)
    app.state.ai_provider = StubReader(
        receipt(
            food("butter", "BUTTER 5KG", quantity="5", unit="kg"),  # same unit: added
            food("milk", "MILK x2", count=2),  # count onto a unitless quantity: added
            food("chicken thigh", "CHKN 1.24 lb", quantity="1.24", unit="lb"),  # other unit
            food("soy sauce", "SOY SAUCE"),  # a count onto a volume
            food("garlic", "GARLIC BULB"),  # no amount on file
            food("egg", "EGGS x5", count=5),  # would pass the pantry's quantity limit
        )
    )
    body = (await upload(client, h)).json()
    assert body["added"] == []
    assert [i["id"] for i in body["merged"]] == [
        before[k]["id"] for k in ("butter", "milk", "chicken thigh", "soy sauce", "garlic", "egg")
    ]
    after = await pantry(client, h)
    assert body["merged"] == [after[i["normalized_name"]] for i in body["merged"]]
    assert {k: (v["quantity"], v["unit"]) for k, v in after.items()} == {
        "butter": (7.0, "kg"),
        "milk": (3.0, None),
        "chicken thigh": (500.0, "g"),
        "soy sauce": (1.0, "cup"),
        "garlic": (None, None),
        "egg": (999_999.0, None),
    }
    for key, item in after.items():
        # Only the amount and "last seen" move: provenance, place and note stay as they were.
        assert {f: item[f] for f in KEPT} == {f: before[key][f] for f in KEPT}, key
        seen = datetime.fromisoformat(item["last_confirmed_at"])
        assert seen > datetime.fromisoformat(before[key]["last_confirmed_at"]), key
    milk = after["milk"]  # an estimate plus an exact amount is still an estimate
    assert (milk["source"], milk["confidence"], milk["quantity_is_estimate"], milk["note"]) == (
        "photo",
        0.7,
        True,
        "the blue carton",
    )
    assert (after["butter"]["source"], after["butter"]["storage_location"]) == ("manual", "fridge")
    (stored,) = await receipt_rows(engine)
    undo = {m["id"]: m["previous"] for m in stored["undo"]["merged"]}
    was = undo[before["butter"]["id"]]
    assert (was["quantity"], was["unit"]) == ("2", "kg")
    assert datetime.fromisoformat(was["last_confirmed_at"]) == datetime.fromisoformat(
        before["butter"]["last_confirmed_at"]
    )


async def test_blurry_first_read_saves_nothing_and_a_retake_is_read_afresh(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "cook@example.com")
    app.state.ai_provider = StubReader(
        receipt(food(None, "M?LK", confidence=0.2), food("egg", "EG?S", confidence=0.4))
    )
    blurry = (await upload(client, h)).json()
    assert (blurry["receipt_id"], blurry["duplicate"], blurry["added"]) == (None, False, [])
    assert [s["reason"] for s in blurry["skipped"]] == ["unreadable", "low_confidence"]
    assert await receipt_rows(engine) == []

    app.state.ai_provider = StubReader(receipt(food("milk", "MILK"), food("egg", "EGGS")))
    retake = (await upload(client, h)).json()
    assert retake["duplicate"] is False and retake["receipt_id"] is not None
    assert set(await pantry(client, h)) == {"milk", "egg"}
    assert (await upload(client, h)).json()["duplicate"] is True  # now it is on record


async def test_store_spelling_does_not_defeat_the_duplicate_check(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "cook@example.com")
    app.state.ai_provider = StubReader(receipt(food("milk", "MILK"), store="TRADER JOE'S"))
    first = (await upload(client, h)).json()
    app.state.ai_provider = StubReader(receipt(food("milk", "MILK"), store="Trader Joes"))
    assert (await upload(client, h)).json() == {**first, "duplicate": True}
    assert len(await receipt_rows(engine)) == 1


async def test_same_receipt_twice_changes_nothing(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "cook@example.com")
    app.state.ai_provider = StubReader(receipt(food("milk", "MILK x2", count=2)))
    first = (await upload(client, h)).json()
    after_first = await pantry(client, h)
    again = (await upload(client, h)).json()
    assert again == {**first, "duplicate": True}
    assert await pantry(client, h) == after_first
    assert len(await receipt_rows(engine)) == 1

    other = await bearer(client, "other@example.com")  # the same receipt is new to someone else
    assert (await upload(client, other)).json()["duplicate"] is False


async def test_reread_with_a_line_now_unreadable_is_still_a_duplicate(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "cook@example.com")
    app.state.ai_provider = StubReader(receipt(food("milk", "MILK"), food("egg", "EGGS 12CT")))
    first = (await upload(client, h)).json()
    after_first = await pantry(client, h)
    app.state.ai_provider = StubReader(
        receipt(food("milk", "MILK", count=3), food(None, "EG?S 1ZCT", confidence=0.2))
    )
    again = (await upload(client, h)).json()
    assert again == {**first, "duplicate": True}
    assert await pantry(client, h) == after_first
    assert len(await receipt_rows(engine)) == 1


async def test_same_store_and_date_with_a_different_total_is_saved(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "cook@example.com")
    app.state.ai_provider = StubReader(receipt(food("milk", "MILK")))
    assert (await upload(client, h)).json()["added"][0]["quantity"] == 1.0
    app.state.ai_provider = StubReader(receipt(food("milk", "MILK"), total="4.99"))
    second = (await upload(client, h)).json()
    assert (second["duplicate"], second["merged"][0]["quantity"]) == (False, 2.0)
    assert len(await receipt_rows(engine)) == 2


@pytest.mark.parametrize("missing", [{"purchased_on": None}, {"total": None}, {"store": None}])
async def test_receipt_missing_date_store_or_total_is_never_a_duplicate(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine, missing: dict
) -> None:
    h = await bearer(client, "cook@example.com")
    app.state.ai_provider = StubReader(receipt(food("milk", "MILK"), **missing))
    assert (await upload(client, h)).json()["added"][0]["quantity"] == 1.0
    second = (await upload(client, h)).json()
    assert second["duplicate"] is False
    assert second["merged"][0]["quantity"] == 2.0
    assert len(await receipt_rows(engine)) == 2


async def test_demo_draft_saves_nothing(client: AsyncClient, engine: AsyncEngine) -> None:
    h = await bearer(client, "cook@example.com")  # AI_PROVIDER=mock: the fixture receipt
    body = (await upload(client, h)).json()
    assert (body["demo"], body["receipt_id"], body["added"], body["merged"]) == (True, None, [], [])
    assert {"name": "egg", "quantity": 2.0, "unit": None} in body["would_add"]
    assert {"name": "chicken thigh", "quantity": 1.24, "unit": "lb"} in body["would_add"]
    assert {"raw_text": "KS SLT BTR QTR", "reason": "low_confidence"} in body["skipped"]
    assert await pantry(client, h) == {}
    assert await receipt_rows(engine) == []


@pytest.mark.parametrize(
    ("error", "status", "code"),
    [
        (AIResting("AI is resting"), 503, "AI_RESTING"),
        (ProviderOutputInvalid("malformed"), 502, "AI_OUTPUT_INVALID"),
        (RuntimeError("boom"), 503, "PROVIDER_UNAVAILABLE"),
    ],
)
async def test_provider_failures_save_nothing(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine, error: Exception, status: int, code: str
) -> None:
    h = await bearer(client, "cook@example.com")
    app.state.ai_provider = StubReader(error)
    res = await upload(client, h)
    assert (res.status_code, res.json()["error"]["code"]) == (status, code)
    assert await pantry(client, h) == {}
    assert await receipt_rows(engine) == []


async def test_upload_rules(client: AsyncClient, engine: AsyncEngine) -> None:
    h = await bearer(client, "cook@example.com")
    assert (await upload(client, h, b"%PDF-1.7 not an image")).status_code == 415
    assert (await client.post(URL, json={"image": "x"}, headers=h)).status_code == 415
    assert (await client.post(URL, files={"other": ("a.jpg", JPEG)}, headers=h)).status_code == 422
    assert (await upload(client, h, b"\xff\xd8\xff" + b"\x00" * 5_000_000)).status_code == 413
    assert (await client.post(URL, files={"image": ("a.jpg", JPEG)})).status_code == 401
    async with engine.connect() as conn:
        assert await conn.scalar(select(func.count()).select_from(PantryReceipt)) == 0


# --- brief 017 PR 6: a receipt ticks off the shopping list --------------------------------------

SHOPPING = "/v1/shopping-list"


async def shopping(client: AsyncClient, h: dict[str, str]) -> dict[str, str | None]:
    """{normalised name: who ticked it, or None while open}; open items only once each."""
    items = (await client.get(SHOPPING, headers=h)).json()["items"]
    return {i["normalized_name"]: i["checked_by"] for i in reversed(items)}


async def want(client: AsyncClient, h: dict[str, str], *names: str) -> None:
    for name in names:
        res = await client.post(SHOPPING, json={"name": name}, headers=h)
        assert res.status_code == 201, res.text


async def test_receipt_ticks_off_matching_shopping_items(
    app: FastAPI, client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "cook@example.com")
    other = await bearer(client, "other@example.com")
    await stock(client, h, {"raw_label": "eggs", "quantity": 2})
    await want(client, h, "Milk", "eggs", "butter", "xylofruit", "paper towels")
    await want(client, other, "milk")
    app.state.ai_provider = StubReader(
        receipt(
            food("whole milk", "ORG WHOLE MILK"),  # added
            food("egg", "LRG EGGS 12CT"),  # merged into the pantry's eggs
            food("butter", "KS SLT BTR", confidence=0.62),  # skipped: not read for sure
            food("xylofruit", "XYLOFRUIT 2PK"),  # skipped: not in the dictionary
        )
    )
    body = (await upload(client, h)).json()
    assert [i["normalized_name"] for i in body["added"]] == ["milk"]
    assert [i["normalized_name"] for i in body["merged"]] == ["egg"]
    assert body["shopping_checked"] == ["eggs", "Milk"]
    (stored,) = await receipt_rows(engine)
    ticked = {i["id"] for i in (await client.get(SHOPPING, headers=h)).json()["items"][-2:]}
    assert set(stored["undo"]["shopping_checked"]) == ticked  # what an undo would reopen
    assert await shopping(client, h) == {
        "milk": "receipt",
        "egg": "receipt",
        "butter": None,
        "xylofruit": None,
        "paper towel": None,
    }
    assert await shopping(client, other) == {"milk": None}  # another cook's list is untouched

    # The same receipt again ticks nothing, even with milk back on the list.
    await want(client, h, "milk")
    again = (await upload(client, h)).json()
    assert (again["duplicate"], again["shopping_checked"]) == (True, [])
    assert (await shopping(client, h))["milk"] is None


async def test_demo_and_unsaved_receipts_tick_nothing(app: FastAPI, client: AsyncClient) -> None:
    h = await bearer(client, "cook@example.com")
    await want(client, h, "milk", "butter")
    app.state.ai_provider = StubReader(receipt(food("whole milk", "ORG WHOLE MILK"), demo=True))
    demo = (await upload(client, h)).json()
    assert (demo["demo"], demo["shopping_checked"]) == (True, [])
    app.state.ai_provider = StubReader(receipt(food("butter", "KS SLT BTR", confidence=0.4)))
    unread = (await upload(client, h)).json()
    assert (unread["receipt_id"], unread["shopping_checked"]) == (None, [])
    assert await shopping(client, h) == {"milk": None, "butter": None}
