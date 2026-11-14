"""Key ingredient rule and its effect on ``can_make`` (brief 017, DECISIONS #29). Pure."""

from __future__ import annotations

from datetime import timedelta

import pytest

from app.domains.matching.dictionary import IngredientDictionary, load_dictionary_file
from app.domains.matching.fit import PantryEntry, RecipeIngredient, fit
from app.domains.matching.key_ingredient import key_ingredient_ref
from tests.unit.test_matching_fit import FIXTURES_DIR, NOW, VERSION_ID, ing, pantry


@pytest.fixture(scope="module")
def d() -> IngredientDictionary:
    return load_dictionary_file(FIXTURES_DIR)


CHICKEN = [
    ing("gochujang", 3, "tbsp", ref="ing-1"),
    ing("boneless skinless chicken thighs", 2, "lb", ref="ing-2"),
    ing("sesame seeds", optional=True, ref="ing-3"),
]


def key(d: IngredientDictionary, title: str, *ingredients: RecipeIngredient) -> str | None:
    return key_ingredient_ref(title, ingredients, d)


def test_title_match_prefers_the_protein_over_an_earlier_hit(d: IngredientDictionary) -> None:
    assert key(d, "Gochujang chicken thighs", *CHICKEN) == "ing-2"


def test_title_tie_without_a_protein_takes_the_earliest(d: IngredientDictionary) -> None:
    lines = [ing("salt", ref="a"), ing("garlic", ref="b"), ing("spaghetti", 8, "oz", ref="c")]
    assert key(d, "Garlic Spaghetti", *lines) == "b"


def test_title_match_reads_or_alternatives_and_aliases(d: IngredientDictionary) -> None:
    lines = [ing("egg", 2, ref="a"), ing("spam or bacon", 4, "oz", ref="b")]
    assert key(d, "Bacon fried rice", *lines) == "b"
    assert key(d, "Green Onion Pancakes", ing("flour", ref="a"), ing("scallions", ref="b")) == "b"


def test_title_match_is_on_whole_words_and_skips_optional_lines(d: IngredientDictionary) -> None:
    lines = [ing("flour", 1, "cup", ref="a"), ing("egg", 2, ref="b")]
    assert key(d, "Eggplant bake", *lines) == "b"  # by protein, not because "egg" is in "eggplant"
    lines = [ing("rice", 1, "cup", ref="a"), ing("kimchi", optional=True, ref="b")]
    assert key(d, "Kimchi rice bowl", *lines) == "a"


def test_first_protein_when_the_title_names_nothing(d: IngredientDictionary) -> None:
    lines = [ing("butter", 500, "g", ref="a"), ing("tofu", ref="b"), ing("eggs", 2, ref="c")]
    assert key(d, "Weeknight dinner", *lines) == "b"


def test_largest_by_mass_across_units_never_volume(d: IngredientDictionary) -> None:
    lines = [
        ing("water", 8, "cup", ref="a"),
        ing("flour", 400, "g", ref="b"),
        ing("butter", 1, "lb", ref="c"),  # 453.6 g
        ing("sugar", 0.3, "kg", ref="d"),
        ing("potatoes", 2, "kg", optional=True, ref="e"),
    ]
    assert key(d, "Sunday bake", *lines) == "c"
    tie = [ing("flour", 1, "kg", ref="a"), ing("sugar", 1000, "g", ref="b")]
    assert key(d, "Sunday bake", *tie) == "a"


def test_first_required_ingredient_as_the_last_resort(d: IngredientDictionary) -> None:
    lines = [ing("basil", optional=True, ref="a"), ing("water", 2, "cup", ref="b"), ing("salt")]
    assert key(d, "Sunday bake", *lines) == "b"


def test_no_required_ingredients_means_no_key(d: IngredientDictionary) -> None:
    assert key(d, "Salt", ing("salt", optional=True)) is None
    result = fit(VERSION_ID, [ing("salt", optional=True)], [], d, NOW, title="Salt")
    assert result.key_ingredient_ref is None and result.can_make is True
    assert not any(i.is_key for i in result.items)


def _fit(d: IngredientDictionary, *items: PantryEntry):
    result = fit(VERSION_ID, CHICKEN, list(items), d, NOW, title="Gochujang chicken thighs")
    assert result.key_ingredient_ref == "ing-2"
    assert [i.is_key for i in result.items] == [False, True, False]
    return result, result.items[1]


@pytest.mark.parametrize(
    ("chicken", "status"),
    [
        (None, "missing"),
        (("chicken thighs", 15), "uncertain"),  # stale
        (("chicken", 1), "uncertain"),  # ambiguous name
    ],
)
def test_can_make_is_false_without_an_available_key(
    d: IngredientDictionary,
    chicken: tuple[str, int] | None,
    status: str,
) -> None:
    items = [pantry(d, "gochujang", 1, "cup")]
    if chicken:
        confirmed = NOW - timedelta(days=chicken[1])
        items.append(pantry(d, chicken[0], 3, "lb", confirmed=confirmed))
    result, item = _fit(d, *items)
    assert item.status == status and result.can_make is False
    assert item.last_confirmed_at == (items[1].last_confirmed_at if chicken else None)


def test_can_make_with_a_fresh_key_and_last_confirmed_passes_through(
    d: IngredientDictionary,
) -> None:
    seen = NOW - timedelta(days=6)
    result, item = _fit(
        d, pantry(d, "gochujang", 1, "cup"), pantry(d, "chicken thighs", 3, "lb", confirmed=seen)
    )
    assert item.status == "available" and result.can_make is True
    assert item.last_confirmed_at == seen
    assert result.items[0].last_confirmed_at == NOW - timedelta(days=1)
    assert result.items[2].last_confirmed_at is None
