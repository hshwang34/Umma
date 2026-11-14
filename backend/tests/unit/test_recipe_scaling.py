"""Servings scaling rules (brief 020, PRD §12.2)."""

import json
from pathlib import Path

import pytest

from app.domains.recipes.scaling import dial_stops, is_valid_servings, scale_quantity

ROOT = Path(__file__).resolve().parents[3] / "fixtures"
CONTRACT = json.loads((ROOT / "expected_outputs" / "servings_scaling.json").read_text())


@pytest.mark.parametrize(
    "case",
    CONTRACT["cases"],
    ids=lambda c: f"{c['quantity']}{c['unit']}-{c['original_servings']}to{c['servings']}",
)
def test_shared_contract_cases(case: dict) -> None:
    got = scale_quantity(
        case["quantity"],
        case["unit"],
        original_servings=case["original_servings"],
        servings=case["servings"],
    )
    assert got == case["expected"]


@pytest.mark.parametrize("row", CONTRACT["dial_stops"], ids=lambda r: str(r["original_servings"]))
def test_shared_contract_dial_stops(row: dict) -> None:
    assert dial_stops(row["original_servings"]) == row["stops"]


def test_dial_is_one_to_six_plus_a_larger_original() -> None:
    assert dial_stops(4) == [1, 2, 3, 4, 5, 6]
    assert dial_stops(8) == [1, 2, 3, 4, 5, 6, 8]
    assert is_valid_servings(8, 8)
    assert not is_valid_servings(7, 8)
    assert not is_valid_servings(0, 4)


def test_hand_checked_amounts() -> None:
    def scale(quantity: float, unit: str | None, servings: int) -> float | None:
        return scale_quantity(quantity, unit, original_servings=4, servings=servings)

    assert scale(400, "g", 2) == 200
    assert scale(2, "tbsp", 2) == 1
    assert scale(1, "cup", 3) == 0.75
    assert scale(6, None, 2) == 3  # six cucumbers for four is three for two
    assert scale(2, "clove", 1) == 0.5
    assert scale(1.5, "lb", 6) == 2.25
    assert scale_quantity(1, "cup", original_servings=3, servings=1) == 0.333
    assert scale_quantity(1, "cup", original_servings=3, servings=2) == 0.667


def test_to_taste_stays_untouched() -> None:
    assert scale_quantity(None, "tsp", original_servings=4, servings=2) is None


def test_rejects_servings_below_one() -> None:
    with pytest.raises(ValueError):
        scale_quantity(1, "cup", original_servings=4, servings=0)
    with pytest.raises(ValueError):
        scale_quantity(1, "cup", original_servings=0, servings=2)


def _seeded() -> list[dict]:
    return [json.loads(p.read_text()) for p in sorted((ROOT / "seeded_recipes").glob("*.json"))]


def test_seeded_recipes_are_exact_at_their_own_servings() -> None:
    for recipe in _seeded():
        for ing in recipe["ingredients"]:
            got = scale_quantity(
                ing.get("quantity"),
                ing.get("unit"),
                original_servings=recipe["servings"],
                servings=recipe["servings"],
            )
            assert got == ing.get("quantity")


def test_seeded_recipes_never_scale_to_zero_and_grow_with_servings() -> None:
    for recipe in _seeded():
        for ing in recipe["ingredients"]:
            if ing.get("quantity") is None:
                continue
            amounts = [
                scale_quantity(
                    ing["quantity"],
                    ing.get("unit"),
                    original_servings=recipe["servings"],
                    servings=servings,
                )
                for servings in dial_stops(recipe["servings"])
            ]
            assert all(a is not None and a > 0 for a in amounts), (recipe["slug"], ing["name"])
            assert amounts == sorted(amounts), (recipe["slug"], ing["name"], amounts)
