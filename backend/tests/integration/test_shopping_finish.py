"""Session finish → shopping list (brief 017 PR 6): what was missing at the start and got no
swap is added once; optional and swapped ingredients are not."""

from __future__ import annotations

from typing import Any

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from tests.conftest import bearer
from tests.integration.slice3_helpers import command, ok, seed, start_session

SALAD = "cucumber-salad"
# Required: persian cucumber, kosher salt, garlic, rice vinegar (ing-4), soy sauce (ing-5),
# toasted sesame oil (ing-6), sugar (ing-7). Optional: chili crisp, sesame seeds, cilantro.
STOCKED = ["persian cucumber", "kosher salt", "garlic"]
URL = "/v1/shopping-list"


def swap(ref: str, replacement: str) -> dict[str, str]:
    return {"ingredient_ref": ref, "replacement": replacement, "source": "ai"}


async def shopping(client: AsyncClient, h: dict[str, str]) -> list[dict[str, Any]]:
    return (await client.get(URL, headers=h)).json()["items"]


async def stock(client: AsyncClient, h: dict[str, str], *labels: str) -> None:
    items = [{"raw_label": label, "source": "manual"} for label in labels]
    assert (await client.post("/v1/pantry", json={"items": items}, headers=h)).status_code == 201


async def test_finish_adds_what_was_missing_and_never_swapped(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    await db_session.commit()
    cook = await bearer(client, "cook@example.com")
    other = await bearer(client, "other@example.com")
    await stock(client, cook, *STOCKED)
    await client.post(URL, json={"name": "butter"}, headers=other)

    # Soy sauce is swapped before starting; sesame oil mid-cook; the rice vinegar swap is undone.
    s = await start_session(client, cook, versions[SALAD], [swap("ing-5", "coconut aminos")])
    s = ok(await command(client, cook, s, "start"))
    s = ok(await command(client, cook, s, "approve_adaptation", adaptation=swap("ing-6", "ghee")))
    s = ok(
        await command(client, cook, s, "approve_adaptation", adaptation=swap("ing-4", "lime juice"))
    )
    vinegar = next(a for a in s["adaptations"] if a["ingredient_ref"] == "ing-4")
    s = ok(await command(client, cook, s, "revert_adaptation", adaptation_id=vinegar["id"]))
    assert s["shopping_added"] == [] and await shopping(client, cook) == []  # nothing until done
    # Sugar is already on the list by hand, and bought since the session started.
    sugar = (await client.post(URL, json={"name": "sugar"}, headers=cook)).json()
    await stock(client, cook, "rice vinegar")  # the snapshot from the start still decides

    done = await command(client, cook, s, "complete", key="finish-1", outcome={"result": "partly"})
    body = ok(done)
    assert body["status"] == "completed"
    assert body["shopping_added"] == ["rice vinegar"]  # not sugar (listed), not the swaps
    items = await shopping(client, cook)
    assert [(i["normalized_name"], i["reason"]) for i in items] == [
        ("rice vinegar", "missing"),
        ("sugar", "manual"),
    ]
    assert items[0]["source_session_id"] == s["id"]
    assert items[0]["source_recipe_version_id"] == versions[SALAD]
    assert items[1] == sugar

    # The same completion replayed: the same answer, nothing new on the list.
    replay = await command(
        client,
        cook,
        s,
        "complete",
        key="finish-1",
        outcome={"result": "partly"},
    )
    assert ok(replay) == body
    assert await shopping(client, cook) == items
    # Any later read of the session reports nothing added.
    read = ok(await client.get(f"/v1/sessions/{s['id']}", headers=cook))
    assert read["shopping_added"] == []
    assert [i["normalized_name"] for i in await shopping(client, other)] == ["butter"]


async def test_finish_with_everything_at_hand_adds_nothing(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    await db_session.commit()
    cook = await bearer(client, "cook@example.com")
    await stock(client, cook, *STOCKED, "rice vinegar", "soy sauce", "toasted sesame oil", "sugar")
    s = await start_session(client, cook, versions[SALAD])
    s = ok(await command(client, cook, s, "start"))
    body = ok(await command(client, cook, s, "complete"))  # no outcome given: the hook still runs
    assert body["shopping_added"] == [] and await shopping(client, cook) == []

    # An abandoned session adds nothing either: only a completion does.
    gone = await start_session(client, cook, versions["garlic-pasta"])
    assert ok(await command(client, cook, gone, "abandon"))["shopping_added"] == []
    assert await shopping(client, cook) == []
