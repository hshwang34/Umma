"""/v1/shopping-list (brief 017 PR 6): CRUD, ownership, and the one-open-item rule."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import ShoppingItem, ShoppingReason, User
from app.domains.shopping import service
from tests.conftest import bearer
from tests.integration.slice3_helpers import seed

pytestmark = pytest.mark.usefixtures("ingredients")

URL = "/v1/shopping-list"


async def add(client: AsyncClient, h: dict[str, str], name: str, **kw: object):
    return await client.post(URL, json={"name": name, **kw}, headers=h)


async def listed(client: AsyncClient, h: dict[str, str]) -> list[dict]:
    res = await client.get(URL, headers=h)
    assert res.status_code == 200, res.text
    return res.json()["items"]


def _error(res) -> dict:  # type: ignore[no-untyped-def]
    return {k: v for k, v in res.json()["error"].items() if k != "correlation_id"}


async def test_requires_auth(client: AsyncClient) -> None:
    assert (await client.get(URL)).status_code == 401
    assert (await client.post(URL, json={"name": "milk"})).status_code == 401
    assert (await client.post(f"{URL}/{uuid.uuid4()}/check")).status_code == 401


async def test_add_list_check_uncheck_delete(client: AsyncClient, db_session: AsyncSession) -> None:
    h = await bearer(client, "cook@example.com")
    milk = await add(client, h, "  Whole   Milk ")
    assert milk.status_code == 201, milk.text
    body = milk.json()
    assert (body["raw_label"], body["normalized_name"]) == ("Whole Milk", "milk")
    assert body["ingredient_id"] is not None and body["reason"] == "manual"
    assert (body["checked_at"], body["checked_by"]) == (None, None)
    assert (body["source_session_id"], body["source_recipe_version_id"]) == (None, None)
    eggs = (await add(client, h, "eggs", reason="ran_out")).json()
    rice = (await add(client, h, "rice", reason="missing")).json()
    assert (eggs["reason"], rice["reason"]) == ("ran_out", "missing")
    assert [i["id"] for i in await listed(client, h)] == [rice["id"], eggs["id"], body["id"]]

    checked = await client.post(f"{URL}/{rice['id']}/check", headers=h)
    assert checked.status_code == 200, checked.text
    assert checked.json()["checked_by"] == "user" and checked.json()["checked_at"] is not None
    again = await client.post(f"{URL}/{rice['id']}/check", headers=h)
    assert again.json()["checked_at"] == checked.json()["checked_at"]  # already ticked: no change
    # Open items first, then the ticked ones.
    assert [i["id"] for i in await listed(client, h)] == [eggs["id"], body["id"], rice["id"]]

    # A tick older than 14 days drops off the list; a recent one stays.
    old = datetime.now(UTC) - timedelta(days=15)
    await db_session.execute(
        update(ShoppingItem).where(ShoppingItem.id == uuid.UUID(rice["id"])).values(checked_at=old)
    )
    await db_session.commit()
    assert [i["id"] for i in await listed(client, h)] == [eggs["id"], body["id"]]

    back = await client.post(f"{URL}/{rice['id']}/uncheck", headers=h)
    assert back.status_code == 200 and back.json()["checked_at"] is None
    assert back.json()["checked_by"] is None
    assert len(await listed(client, h)) == 3

    assert (await client.delete(f"{URL}/{eggs['id']}", headers=h)).status_code == 204
    assert (await client.delete(f"{URL}/{eggs['id']}", headers=h)).status_code == 404
    assert {i["id"] for i in await listed(client, h)} == {body["id"], rice["id"]}


async def test_each_ingredient_is_open_once(client: AsyncClient) -> None:
    h = await bearer(client, "cook@example.com")
    first = await add(client, h, "eggs")
    repeat = await add(client, h, "Egg", reason="ran_out")  # same ingredient, other spelling
    assert (first.status_code, repeat.status_code) == (201, 200)
    assert repeat.json() == first.json()  # the existing row, unchanged
    assert len(await listed(client, h)) == 1

    # A ticked item is history: it does not block putting the ingredient on the list again.
    await client.post(f"{URL}/{first.json()['id']}/check", headers=h)
    second = await add(client, h, "eggs")
    assert second.status_code == 201 and second.json()["id"] != first.json()["id"]
    assert [(i["id"], i["checked_by"]) for i in await listed(client, h)] == [
        (second.json()["id"], None),
        (first.json()["id"], "user"),
    ]

    # Unticking the old one while a new one is open keeps a single open item, never a 500.
    back = await client.post(f"{URL}/{first.json()['id']}/uncheck", headers=h)
    assert back.status_code == 200, back.text
    assert back.json()["id"] == second.json()["id"]
    assert [i["id"] for i in await listed(client, h)] == [second.json()["id"]]


async def test_manual_add_allows_names_outside_the_dictionary(client: AsyncClient) -> None:
    h = await bearer(client, "cook@example.com")
    towels = await add(client, h, "Paper towels")
    assert towels.status_code == 201, towels.text
    assert towels.json()["ingredient_id"] is None
    assert (towels.json()["raw_label"], towels.json()["normalized_name"]) == (
        "Paper towels",
        "paper towel",  # the normaliser singularises; the label keeps what was typed
    )
    assert (await add(client, h, "paper  TOWELS")).status_code == 200  # still one open item
    assert (await add(client, h, "!!!")).status_code == 201  # nothing to normalise: kept as typed

    for bad in (
        {"name": "   "},
        {"name": "x" * 121},
        {"name": "two\nlines"},
        {"name": "milk", "reason": "no_substitute"},  # the coach's reason, not the client's
        {"name": "milk", "checked_by": "receipt"},
        {},
    ):
        res = await client.post(URL, json=bad, headers=h)
        assert res.status_code == 422, (bad, res.text)
    assert len(await listed(client, h)) == 2


async def test_recipe_version_must_be_readable(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    await db_session.commit()
    h = await bearer(client, "cook@example.com")
    version_id = versions["cucumber-salad"]
    ok = await add(client, h, "rice vinegar", reason="missing", recipe_version_id=version_id)
    assert ok.status_code == 201, ok.text
    assert ok.json()["source_recipe_version_id"] == version_id
    unknown = await add(client, h, "garlic", recipe_version_id=str(uuid.uuid4()))
    assert unknown.status_code == 404 and unknown.json()["error"]["code"] == "NOT_FOUND"
    assert [i["normalized_name"] for i in await listed(client, h)] == ["rice vinegar"]


async def test_foreign_and_missing_ids_are_the_same_404(client: AsyncClient) -> None:
    owner = await bearer(client, "owner@example.com")
    other = await bearer(client, "other@example.com")
    item = (await add(client, owner, "milk")).json()
    mine = (await add(client, other, "milk")).json()  # the same name on two lists is fine
    assert mine["id"] != item["id"]

    for method, suffix in (("POST", "/check"), ("POST", "/uncheck"), ("DELETE", "")):
        foreign = await client.request(method, f"{URL}/{item['id']}{suffix}", headers=other)
        missing = await client.request(method, f"{URL}/{uuid.uuid4()}{suffix}", headers=other)
        malformed = await client.request(method, f"{URL}/not-a-uuid{suffix}", headers=other)
        assert foreign.status_code == missing.status_code == malformed.status_code == 404
        assert _error(foreign) == _error(missing) == _error(malformed)
        assert _error(foreign)["message"] == "Shopping item not found"

    assert await listed(client, owner) == [item]  # untouched by the other user's attempts
    assert await listed(client, other) == [mine]


async def test_add_missing_is_idempotent_and_owner_scoped(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    h = await bearer(client, "cook@example.com")
    other = await bearer(client, "other@example.com")
    await add(client, other, "butter")
    user = (await db_session.scalars(select(User).where(User.email == "cook@example.com"))).one()

    names = ["gochujang", "Scallions", "scallion", " "]
    first = await service.add_missing(db_session, user, names, ShoppingReason.MISSING)
    assert [r.normalized_name for r in first] == ["gochujang", "scallion"]
    again = await service.add_missing(db_session, user, names, ShoppingReason.RAN_OUT)
    assert again == []
    await db_session.commit()

    mine = await listed(client, h)
    assert sorted((i["normalized_name"], i["reason"]) for i in mine) == [
        ("gochujang", "missing"),
        ("scallion", "missing"),
    ]
    assert [i["normalized_name"] for i in await listed(client, other)] == ["butter"]
