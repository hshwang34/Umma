"""Fit reads recipe amounts through the shared scaling rules (brief 020)."""

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from app.core.errors import ValidationError
from app.domains.matching.service import ingredients_of, resolve_servings

ROOT = Path(__file__).resolve().parents[3] / "fixtures"
CONTRACT = json.loads((ROOT / "expected_outputs" / "servings_scaling.json").read_text())


def _version(servings: int, *ingredients: dict) -> SimpleNamespace:
    rows = [
        {"id": f"ing-{n}", "name": "thing", "optional": False, **ing}
        for n, ing in enumerate(ingredients, 1)
    ]
    return SimpleNamespace(servings=servings, ingredient_json=rows)


@pytest.mark.parametrize(
    "case",
    CONTRACT["cases"],
    ids=lambda c: f"{c['quantity']}{c['unit']}-{c['original_servings']}to{c['servings']}",
)
def test_fit_ingredients_follow_the_shared_contract(case: dict) -> None:
    version = _version(
        case["original_servings"], {"quantity": case["quantity"], "unit": case["unit"]}
    )
    (ingredient,) = ingredients_of(version, case["servings"])  # type: ignore[arg-type]
    assert ingredient.quantity == case["expected"]
    assert ingredient.unit == case["unit"]


def test_no_servings_and_own_servings_are_the_creators_amounts() -> None:
    version = _version(
        4, {"quantity": 0.3, "unit": "cup"}, {"quantity": None, "unit": None}, {"quantity": 7}
    )
    written = [0.3, None, 7]
    assert [i.quantity for i in ingredients_of(version)] == written  # type: ignore[arg-type]
    assert [i.quantity for i in ingredients_of(version, 4)] == written  # type: ignore[arg-type]
    # "to taste" stays untouched at any servings
    assert ingredients_of(version, 2)[1].quantity is None  # type: ignore[arg-type]


def test_resolve_servings() -> None:
    assert resolve_servings(None, 4) == 4
    assert resolve_servings(None, 8) == 8
    assert resolve_servings(6, 2) == 6
    assert resolve_servings(8, 8) == 8
    for bad, original in ((7, 8), (0, 4), (8, 4), (12, 8)):
        with pytest.raises(ValidationError):
            resolve_servings(bad, original)
