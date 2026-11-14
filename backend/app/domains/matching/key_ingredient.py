"""The key ingredient of a recipe (brief 017, DECISIONS #29). Pure and deterministic.

Derived at fit time, never stored on the recipe. Among the required (non-optional) ingredients,
in order:

1. one named in the recipe title: its normalised name, or that of one of its "X or Y"
   alternatives, appears in the title as whole words ("Gochujang chicken thighs" → "boneless
   skinless chicken thighs"). Several hits: a protein first, then the earliest in the list;
2. else the first whose dictionary category is ``protein``;
3. else the largest quantity among those measured by mass (volume is never converted to mass);
4. else the first required ingredient.

A recipe with no required ingredients has no key ingredient.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from typing import Protocol

from app.domains.matching.dictionary import IngredientDictionary, clean
from app.domains.matching.normalize import Normalized, alternatives, normalize
from app.domains.matching.units import canonical_unit, convert, family

PROTEIN = "protein"
_WORD_RE = re.compile(r"[^\W_]+(?:[-'][^\W_]+)*")
_MAX_TITLE_PHRASE = 5


class _Ingredient(Protocol):
    @property
    def id(self) -> str: ...
    @property
    def name(self) -> str: ...
    @property
    def quantity(self) -> float | None: ...
    @property
    def unit(self) -> str | None: ...
    @property
    def optional(self) -> bool: ...


def title_keys(title: str, dictionary: IngredientDictionary) -> frozenset[str]:
    """The normalised name of every run of whole words in the title."""
    words = _WORD_RE.findall(clean(title))
    keys = set()
    for start in range(len(words)):
        for end in range(start + 1, min(len(words), start + _MAX_TITLE_PHRASE) + 1):
            keys.add(normalize(" ".join(words[start:end]), dictionary).key)
    keys.discard("")
    return frozenset(keys)


def _grams(ing: _Ingredient) -> float | None:
    unit = canonical_unit(ing.unit)
    if ing.quantity is None or family(unit) != "mass":
        return None
    return convert(ing.quantity, unit, "g")


def key_ingredient_ref(
    title: str, ingredients: Sequence[_Ingredient], dictionary: IngredientDictionary
) -> str | None:
    required = [i for i in ingredients if not i.optional]
    if not required:
        return None
    norms: dict[str, list[Normalized]] = {
        i.id: [normalize(alt, dictionary) for alt in alternatives(i.name)] for i in required
    }

    def is_protein(ing: _Ingredient) -> bool:
        return any(n.entry is not None and n.entry.category == PROTEIN for n in norms[ing.id])

    in_title = title_keys(title, dictionary)
    named = [i for i in required if any(n.key in in_title for n in norms[i.id])]
    if named:
        return next((i for i in named if is_protein(i)), named[0]).id
    protein = next((i for i in required if is_protein(i)), None)
    if protein is not None:
        return protein.id
    by_mass = [(grams, i) for i in required if (grams := _grams(i)) is not None]
    if by_mass:
        return max(by_mass, key=lambda pair: pair[0])[1].id  # max keeps the earliest on a tie
    return required[0].id
