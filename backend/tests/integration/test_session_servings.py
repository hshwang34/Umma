"""Servings carried into cooking (brief 020 PR 5): set at session creation only, used for the
session's ingredient amounts and the coach's grounding, never for step text or times."""

from __future__ import annotations

import json
from types import SimpleNamespace
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.domains.recipes.scaling import scale_quantity
from app.domains.substitutions.service import context_from
from tests.conftest import FIXTURES_DIR, bearer
from tests.integration.slice3_helpers import command, ok, seed, start_session

KIMCHI = "kimchi-fried-rice"  # written for 2
SALAD = "cucumber-salad"  # written for 4
CONTRACT = json.loads((FIXTURES_DIR / "expected_outputs" / "servings_scaling.json").read_text())
NEW_FIELDS = {"servings", "original_servings", "amounts_scaled"}


async def create(client: AsyncClient, h: dict[str, str], version_id: str, **extra: Any) -> Any:
    body = {"recipe_version_id": version_id, **extra}
    return await client.post("/v1/sessions", json=body, headers=h)


async def version_detail(client: AsyncClient, h: dict[str, str], version_id: str) -> dict:
    return (await client.get(f"/v1/recipe-versions/{version_id}", headers=h)).json()


def quantities(recipe: dict) -> dict[str, float | None]:
    return {i["id"]: i["quantity"] for i in recipe["ingredients"]}


async def test_omitted_servings_changes_nothing(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    h = await bearer(client, "cook@example.com")
    written = await version_detail(client, h, versions[KIMCHI])
    for extra in ({}, {"servings": None}, {"servings": 2}):
        r = await create(client, h, versions[KIMCHI], **extra)
        assert r.status_code == 201, r.text
        s = r.json()
        assert NEW_FIELDS <= set(s)
        assert (s["servings"], s["original_servings"], s["amounts_scaled"]) == (2, 2, False)
        # The embedded recipe is the published version, exactly as the creator wrote it.
        assert {**s["recipe"], "saved": written["saved"]} == written
        await client.delete(f"/v1/sessions/{s['id']}", headers=h)
    stored = (await db_session.execute(text("select servings from cooking_sessions"))).all()
    assert stored == []  # deleted; nothing left behind


async def test_session_amounts_are_scaled_and_nothing_else(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    h = await bearer(client, "cook@example.com")
    written = await version_detail(client, h, versions[KIMCHI])
    plain = await start_session(client, h, versions[KIMCHI])
    r = await create(client, h, versions[KIMCHI], servings=1)
    assert r.status_code == 201, r.text
    s = r.json()
    assert (s["servings"], s["original_servings"], s["amounts_scaled"]) == (1, 2, True)

    got = quantities(s["recipe"])
    assert got["ing-1"] == 1.5  # 3 cups of rice for 2
    assert got["ing-3"] == 1.5  # 3 tbsp
    assert got["ing-8"] == 0.5  # 1 tsp
    assert got["ing-10"] == 1.0  # 2 eggs
    assert got["ing-13"] == 0.5  # 1 sheet: never zero
    for ing in written["ingredients"]:
        assert got[ing["id"]] == scale_quantity(
            ing["quantity"], ing["unit"], original_servings=2, servings=1
        )
    # Only quantities differ: names, units, notes, steps, times and the recipe's own servings.
    unscaled = [{**i, "quantity": None} for i in written["ingredients"]]
    assert [{**i, "quantity": None} for i in s["recipe"]["ingredients"]] == unscaled
    for key in ("steps", "servings", "prep_minutes", "cook_minutes", "creator_notes", "title"):
        assert s["recipe"][key] == written[key]
    assert s["steps"] == plain["steps"]

    # Locked: it survives start, navigation and a re-read, and the published version is as it was.
    s = ok(await command(client, h, s, "start"))
    s = ok(await command(client, h, s, "next"))
    assert (s["servings"], s["amounts_scaled"]) == (1, True) and quantities(s["recipe"]) == got
    again = (await client.get(f"/v1/sessions/{s['id']}", headers=h)).json()
    assert again["servings"] == 1 and quantities(again["recipe"]) == got
    assert await version_detail(client, h, versions[KIMCHI]) == written


async def test_no_command_changes_servings(client: AsyncClient, db_session: AsyncSession) -> None:
    versions = await seed(db_session)
    h = await bearer(client, "cook@example.com")
    s = (await create(client, h, versions[SALAD], servings=6)).json()
    assert (s["servings"], s["original_servings"], s["amounts_scaled"]) == (6, 4, True)
    for name in ("start", "pause"):
        r = await command(client, h, s, name, servings=2)
        assert r.status_code == 422, r.text
        r = await command(client, h, s, name, metadata={"servings": 2})
        s = ok(r)
        assert s["servings"] == 6
    stored = (await db_session.execute(text("select servings from cooking_sessions"))).scalar_one()
    assert stored == 6


@pytest.mark.parametrize("servings", [0, -2, 7, 8, "2", 1.5, True])
async def test_servings_must_be_a_dial_stop(
    client: AsyncClient, db_session: AsyncSession, servings: object
) -> None:
    versions = await seed(db_session)
    h = await bearer(client, "cook@example.com")
    r = await create(client, h, versions[KIMCHI], servings=servings)
    assert r.status_code == 422, r.text
    assert (await client.get("/v1/sessions", headers=h)).json()["items"] == []


async def test_sessions_from_before_behave_as_the_original(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """A stored null (every session started before this shipped) reads as the recipe's own."""
    versions = await seed(db_session)
    h = await bearer(client, "cook@example.com")
    s = await start_session(client, h, versions[SALAD])
    stored = (await db_session.execute(text("select servings from cooking_sessions"))).scalar_one()
    assert stored is None
    s = (await client.get(f"/v1/sessions/{s['id']}", headers=h)).json()
    assert (s["servings"], s["original_servings"], s["amounts_scaled"]) == (4, 4, False)


async def test_coach_answers_for_the_sessions_servings(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    h = await bearer(client, "cook@example.com")

    async def how_much(session: dict) -> str:
        session = ok(await command(client, h, session, "start"))
        r = await client.post(
            f"/v1/sessions/{session['id']}/ask", json={"query": "how much rice?"}, headers=h
        )
        assert r.status_code == 200, r.text
        return r.json()["answer_text"]

    for_two = await how_much(await start_session(client, h, versions[KIMCHI]))
    assert "3 cup cooked short-grain rice" in for_two
    for_one = await how_much((await create(client, h, versions[KIMCHI], servings=1)).json())
    assert "1.5 cup cooked short-grain rice" in for_one and "3 cup" not in for_one


async def test_finish_hook_still_fills_the_shopping_list(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    h = await bearer(client, "cook@example.com")
    items = [{"raw_label": n, "source": "manual"} for n in ("persian cucumber", "kosher salt")]
    assert (await client.post("/v1/pantry", json={"items": items}, headers=h)).status_code == 201
    s = (await create(client, h, versions[SALAD], servings=2)).json()
    s = ok(await command(client, h, s, "start"))
    done = ok(await command(client, h, s, "complete", outcome={"result": "cooked"}))
    assert done["servings"] == 2 and done["amounts_scaled"] is True
    assert done["shopping_added"] == [
        "garlic", "rice vinegar", "soy sauce", "toasted sesame oil", "sugar"
    ]  # fmt: skip


@pytest.mark.parametrize(
    "case",
    CONTRACT["cases"],
    ids=lambda c: f"{c['quantity']}{c['unit']}-{c['original_servings']}to{c['servings']}",
)
def test_session_context_follows_the_shared_contract(case: dict) -> None:
    row = {"id": "ing-1", "name": "thing", "quantity": case["quantity"], "unit": case["unit"]}
    version = SimpleNamespace(
        id=None, servings=case["original_servings"], ingredient_json=[row], step_json=[],
        warning_json={}, title="Dish", summary=None, tags=[], cover_image_url=None,
    )  # fmt: skip
    recipe = SimpleNamespace(id=None)
    ctx = context_from(version, recipe, case["servings"])  # type: ignore[arg-type]
    assert ctx.ingredients[0].quantity == case["expected"]
    assert context_from(version, recipe).ingredients[0].quantity == case["quantity"]  # type: ignore[arg-type]
