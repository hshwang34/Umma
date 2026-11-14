"""Brief 015: onboarding state on /me and the taste fields on /me/preferences."""

from __future__ import annotations

from httpx import AsyncClient

from tests.conftest import dev_sign_in


async def _bearer(client: AsyncClient, email: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {await dev_sign_in(client, email)}"}


async def test_new_user_is_not_onboarded_and_completion_is_idempotent(
    client: AsyncClient,
) -> None:
    alice = await _bearer(client, "alice@example.com")
    me = (await client.get("/v1/me", headers=alice)).json()
    assert me["onboarded_at"] is None
    assert me["role"] is None

    first = await client.post("/v1/me/onboarding/complete", headers=alice)
    assert first.status_code == 200, first.text
    stamp = first.json()["onboarded_at"]
    assert stamp

    again = await client.post("/v1/me/onboarding/complete", headers=alice)
    assert again.json()["onboarded_at"] == stamp
    assert (await client.get("/v1/me", headers=alice)).json()["onboarded_at"] == stamp

    bob = await _bearer(client, "bob@example.com")
    assert (await client.get("/v1/me", headers=bob)).json()["onboarded_at"] is None


async def test_patch_role(client: AsyncClient) -> None:
    alice = await _bearer(client, "alice@example.com")
    r = await client.patch("/v1/me", json={"role": "creator"}, headers=alice)
    assert r.status_code == 200, r.text
    assert r.json()["role"] == "creator"
    assert (await client.get("/v1/me", headers=alice)).json()["role"] == "creator"
    for bad in ({"role": "chef"}, {}, {"role": "cook", "display_name": "x"}):
        assert (await client.patch("/v1/me", json=bad, headers=alice)).status_code == 422
    assert (await client.patch("/v1/me", json={"role": "cook"})).status_code == 401


async def test_taste_fields_save_and_survive_old_clients(client: AsyncClient) -> None:
    alice = await _bearer(client, "alice@example.com")
    body = {
        "allergies": ["peanuts"],
        "avoid": [],
        "diets": ["vegetarian", "vegetarian", "halal"],
        "cuisines": ["korean", "italian"],
        "skill_level": "beginner",
    }
    out = (await client.put("/v1/me/preferences", json=body, headers=alice)).json()
    assert out["allergies"] == ["peanut"]
    assert out["diets"] == ["vegetarian", "halal"]
    assert out["cuisines"] == ["korean", "italian"]
    assert out["skill_level"] == "beginner"

    # A pre-015 client sends only allergies/avoid: taste fields are kept.
    old = {"allergies": ["peanuts", "sesame"], "avoid": ["cilantro"]}
    out = (await client.put("/v1/me/preferences", json=old, headers=alice)).json()
    assert out["allergies"] == ["peanut", "sesame"]
    assert out["cuisines"] == ["korean", "italian"]
    assert out["skill_level"] == "beginner"

    # Explicit empty / null clears.
    clear = {**old, "diets": [], "cuisines": None, "skill_level": None}
    out = (await client.put("/v1/me/preferences", json=clear, headers=alice)).json()
    assert (out["diets"], out["cuisines"], out["skill_level"]) == ([], [], None)
    assert (await client.get("/v1/me/preferences", headers=alice)).json() == out


async def test_first_put_with_only_taste_fields(client: AsyncClient) -> None:
    alice = await _bearer(client, "alice@example.com")
    r = await client.put("/v1/me/preferences", json={"cuisines": ["thai"]}, headers=alice)
    assert r.status_code == 200, r.text
    assert r.json()["cuisines"] == ["thai"]
    assert r.json()["diets"] == []


async def test_taste_fields_reject_values_outside_the_lists(client: AsyncClient) -> None:
    alice = await _bearer(client, "alice@example.com")
    for bad in (
        {"diets": ["keto"]},
        {"cuisines": ["martian"]},
        {"skill_level": "expert"},
        {"diets": "vegan"},
    ):
        r = await client.put("/v1/me/preferences", json=bad, headers=alice)
        assert r.status_code == 422, bad


async def test_default_servings_set_change_and_clear(client: AsyncClient) -> None:
    """Brief 020: off ("the recipe's own") until set, 1 to 6 once set, null clears it."""
    alice = await _bearer(client, "alice@example.com")
    assert (await client.get("/v1/me", headers=alice)).json()["default_servings"] is None

    r = await client.patch("/v1/me", json={"default_servings": 2}, headers=alice)
    assert r.status_code == 200, r.text
    assert r.json()["default_servings"] == 2
    assert r.json()["role"] is None, "an omitted field is left alone"

    # Setting the role later does not reset the default, and the other way round.
    r = await client.patch("/v1/me", json={"role": "cook"}, headers=alice)
    assert (r.json()["role"], r.json()["default_servings"]) == ("cook", 2)
    r = await client.patch("/v1/me", json={"default_servings": 6}, headers=alice)
    assert (r.json()["role"], r.json()["default_servings"]) == ("cook", 6)

    r = await client.patch("/v1/me", json={"default_servings": None}, headers=alice)
    assert r.status_code == 200, r.text
    assert r.json()["default_servings"] is None
    assert (await client.get("/v1/me", headers=alice)).json()["default_servings"] is None

    bob = await _bearer(client, "bob@example.com")
    assert (await client.get("/v1/me", headers=bob)).json()["default_servings"] is None


async def test_default_servings_rejects_out_of_range_and_bad_bodies(client: AsyncClient) -> None:
    alice = await _bearer(client, "alice@example.com")
    await client.patch("/v1/me", json={"default_servings": 3}, headers=alice)
    for bad in (
        {"default_servings": 0},
        {"default_servings": 7},
        {"default_servings": -1},
        {"default_servings": 2.5},
        {"default_servings": "lots"},
        {"role": None},
        {"role": None, "default_servings": 2},
    ):
        r = await client.patch("/v1/me", json=bad, headers=alice)
        assert r.status_code == 422, (bad, r.text)
    assert (await client.get("/v1/me", headers=alice)).json()["default_servings"] == 3
    assert (await client.patch("/v1/me", json={"default_servings": 2})).status_code == 401
