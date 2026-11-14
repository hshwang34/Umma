"""The ``missing_ingredient`` coach intent (brief 017 PR 7): "I don't have that" is answered
with an offer. Nothing is written until the cook confirms through the existing paths."""

from __future__ import annotations

from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from app.domains.sessions import intent
from tests.conftest import bearer
from tests.integration.slice3_helpers import command, ok, seed, start_session
from tests.integration.test_ask_api import CapturingCoach, ask, use

SALAD = "cucumber-salad"  # step 1: cucumber. step 3: garlic, rice vinegar, soy sauce, oil, sugar
SHOPPING = "/v1/shopping-list"


async def stock(client: AsyncClient, h: dict[str, str], *labels: str) -> dict[str, str]:
    items = [{"raw_label": label, "source": "manual"} for label in labels]
    r = await client.post("/v1/pantry", json={"items": items}, headers=h)
    assert r.status_code == 201, r.text
    return {i["raw_label"]: i["id"] for i in r.json()["items"]}


async def cooking(client: AsyncClient, h: dict[str, str], version_id: str, step: int = 0) -> dict:
    s = ok(await command(client, h, await start_session(client, h, version_id), "start"))
    for _ in range(step):
        s = ok(await command(client, h, s, "next"))
    return s


async def state(client: AsyncClient, h: dict[str, str], s: dict) -> Any:
    session = (await client.get(f"/v1/sessions/{s['id']}", headers=h)).json()
    return (
        (await client.get("/v1/pantry", headers=h)).json(),
        (await client.get(SHOPPING, headers=h)).json(),
        session["revision"],
        session["adaptations"],
        session["steps"],
    )


@pytest.mark.parametrize(
    ("query", "expected"),
    [
        ("I don't have that", ""),
        ("I don\u2019t have it.", ""),
        ("we don't have any", ""),
        ("I dont have soy sauce, what can I use?", "soy sauce"),
        ("We're out of scallions", "scallions"),
        ("I ran out of rice vinegar but I have lime", "rice vinegar"),
        ("I have no honey left", "honey"),
        ("I don't have a thermometer", "thermometer"),
        ("how much soy sauce?", None),
        ("what if you don't have soy sauce?", None),
        ("next step please", None),
    ],
)
def test_missing_object(query: str, expected: str | None) -> None:
    assert intent.missing_object(query) == expected


async def test_offer_writes_nothing_and_each_part_needs_its_own_confirmation(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    h = await bearer(client, "cook@example.com")
    ids = await stock(client, h, "soy sauce", "lemon juice", "rice vinegar")
    s = await cooking(client, h, versions[SALAD], step=2)
    before = await state(client, h, s)
    coach = CapturingCoach()
    use(client, coach)

    r = ok(await ask(client, h, s, "I don't have rice vinegar, what can I use?"))
    offer = r["missing_ingredient"]
    assert offer == {
        "status": "offer",
        "ingredient_ref": "ing-4",
        "name": "rice vinegar",
        "optional": False,
        "candidates": [],
        "swap": {
            "candidate": "lemon juice",  # in the pantry, so ahead of apple cider vinegar
            "ratio_or_amount": "1:1",
            "kind": offer["swap"]["kind"],
            "in_pantry": True,
            "risks": offer["swap"]["risks"],
            "allergy_warning": None,
            "adaptation": {
                "ingredient_ref": "ing-4",
                "replacement": "lemon juice",
                "ratio_or_amount": "1:1",
                "source": "rule",
            },
        },
        "no_swap_reason": None,
        "shopping_name": "rice vinegar",
        "on_shopping_list": False,
        "pantry_item_id": ids["rice vinegar"],
        "requires_confirmation": True,
    }
    assert r["answer_text"].startswith("The recipe says: 2 tbsp rice vinegar. My suggestion: ")
    assert "lemon juice (1:1), and it's in your pantry" in r["answer_text"]
    assert r["answer_text"].endswith("Nothing changes until you confirm.")
    assert r["grounding"] == [{"type": "ingredient", "id": "ing-4"}]
    assert r["proposed_action"] is None and r["requires_confirmation"] is False
    assert r["stale"] is False
    # A proposal only: the model was not called and nothing moved.
    assert coach.calls == 0
    assert await state(client, h, s) == before

    # The cook says yes to each part through the existing confirmed paths.
    s = ok(
        await command(client, h, s, "approve_adaptation", adaptation=offer["swap"]["adaptation"])
    )
    (swap,) = s["adaptations"]
    assert (swap["replacement"], swap["label"]) == ("lemon juice", "Common swap")
    added = await client.post(
        SHOPPING, json={"name": offer["shopping_name"], "reason": "missing"}, headers=h
    )
    assert added.status_code in (200, 201), added.text
    gone = await client.delete(f"/v1/pantry/{offer['pantry_item_id']}", headers=h)
    assert gone.status_code == 204

    again = ok(await ask(client, h, s, "we're out of rice vinegar"))["missing_ingredient"]
    assert again["swap"] is None and again["pantry_item_id"] is None
    assert again["no_swap_reason"] == "You already approved lemon juice instead."
    assert again["on_shopping_list"] is True


async def test_unnamed_uses_the_steps_ingredient_or_asks_which(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    h = await bearer(client, "cook@example.com")
    s = await cooking(client, h, versions[SALAD])  # step 1 uses only the cucumber

    r = ok(await ask(client, h, s, "I don't have that"))
    offer = r["missing_ingredient"]
    assert (offer["status"], offer["ingredient_ref"]) == ("offer", "ing-1")
    # SUB-05: the vetted rule says there is no swap, and the coach says so.
    assert offer["swap"] is None and "No substitute" in offer["no_swap_reason"]
    assert "No substitute" in r["answer_text"]
    assert "I can add persian cucumber to your shopping list." in r["answer_text"]

    s = ok(await command(client, h, s, "next"))
    s = ok(await command(client, h, s, "next"))  # step 3 uses five ingredients
    before = await state(client, h, s)
    r = ok(await ask(client, h, s, "I don't have it"))
    which = r["missing_ingredient"]
    assert which["status"] == "which" and which["swap"] is None
    assert [c["ingredient_ref"] for c in which["candidates"]] == [
        "ing-3", "ing-4", "ing-5", "ing-6", "ing-7"
    ]  # fmt: skip
    assert which["ingredient_ref"] is None and which["shopping_name"] is None
    assert r["answer_text"].startswith("This step uses garlic, rice vinegar, soy sauce,")
    assert r["grounding"] == [{"type": "recipe_step", "id": "step-3"}]
    assert await state(client, h, s) == before


async def test_allergy_wins_over_the_offer(client: AsyncClient, db_session: AsyncSession) -> None:
    versions = await seed(db_session)
    h = await bearer(client, "cook@example.com")
    s = await cooking(client, h, versions[SALAD], step=2)
    first = ok(await ask(client, h, s, "I don't have soy sauce"))["missing_ingredient"]
    assert first["swap"]["candidate"] == "tamari" and first["swap"]["in_pantry"] is False
    assert (
        "but it isn't in your pantry"
        in (ok(await ask(client, h, s, "I don't have soy sauce"))["answer_text"])
    )
    r = await client.put("/v1/me/preferences", json={"allergies": ["soy"]}, headers=h)
    assert r.status_code == 200, r.text
    after = ok(await ask(client, h, s, "I don't have soy sauce"))
    swap = after["missing_ingredient"]["swap"]
    assert swap is None or "tamari" not in swap["candidate"]
    if swap is not None:  # every swap carries the label check once allergies are set
        assert swap["allergy_warning"] and after["safety_notice"] == swap["allergy_warning"]


async def test_other_questions_are_untouched(client: AsyncClient, db_session: AsyncSession) -> None:
    versions = await seed(db_session)
    h = await bearer(client, "cook@example.com")
    s = await cooking(client, h, versions[SALAD], step=2)
    plain = ok(await ask(client, h, s, "how much soy sauce?"))
    assert "missing_ingredient" not in plain and "1 tbsp soy sauce" in plain["answer_text"]
    coach = CapturingCoach()
    use(client, coach)
    # Not an ingredient of this recipe: an ordinary question for the coach.
    r = ok(await ask(client, h, s, "I don't have a wok"))
    assert "missing_ingredient" not in r and coach.calls == 1
    # A closed session never offers.
    done = ok(await command(client, h, s, "complete", outcome={"result": "cooked"}))
    assert (await ask(client, h, done, "I don't have soy sauce")).status_code == 409
