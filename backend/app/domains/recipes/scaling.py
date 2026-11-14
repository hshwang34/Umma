"""Servings scaling (PRD §12.2, brief 020). Pure: no I/O, no model calls.

A published recipe version is never changed. Scaling is a view of its ingredient amounts for a
different number of servings, used by pantry fit, cooking sessions and the coach. The phone
runs the same rules for the live dial; ``fixtures/expected_outputs/servings_scaling.json`` is
the shared contract both implementations are tested against.

Rules:

* At the recipe's own servings every amount is returned exactly as the creator wrote it.
* No quantity ("to taste") stays no quantity.
* ``g`` and ``ml`` round to whole numbers (to 5 from 100 up), never below 1.
* Other measured units (tsp, tbsp, cup, oz, lb, kg, l, fl oz) round to kitchen fractions:
  ¼, ⅓, ½, ⅔, ¾, with ⅛ as the smallest spoon amount.
* Counts and units we do not know ("clove", "sheet", a bare "3 eggs") round to the nearest
  half, never below ½.
* Nothing scales to zero. Times, step text and warnings are not this module's business.
"""

from __future__ import annotations

from app.domains.matching.units import canonical_unit

MIN_SERVINGS = 1
MAX_DIAL_SERVINGS = 6

_METRIC_SMALL = frozenset({"g", "ml"})
_SPOONS = frozenset({"tsp", "tbsp"})
_FRACTIONAL = frozenset({"tsp", "tbsp", "cup", "oz", "lb", "kg", "l", "fl_oz"})

_FRACTIONS: tuple[float, ...] = (0.0, 1 / 4, 1 / 3, 1 / 2, 2 / 3, 3 / 4, 1.0)
_EIGHTH = 1 / 8

# Stored and sent with three decimals, like the ``Numeric(12, 3)`` quantity columns. ⅓ and ⅔
# therefore travel as 0.333 and 0.667, which is what the phone's fraction glyphs match on.
_DECIMALS = 3


def dial_stops(original_servings: int) -> list[int]:
    """Servings the dial offers: 1 to 6, plus the recipe's own when it is larger (DECISIONS #32)."""
    stops = list(range(MIN_SERVINGS, MAX_DIAL_SERVINGS + 1))
    if original_servings > MAX_DIAL_SERVINGS:
        stops.append(original_servings)
    return stops


def is_valid_servings(servings: int, original_servings: int) -> bool:
    return servings in dial_stops(original_servings)


def scale_quantity(
    quantity: float | None,
    unit: str | None,
    *,
    original_servings: int,
    servings: int,
) -> float | None:
    """``quantity`` of ``unit`` for ``servings`` instead of ``original_servings``."""
    if original_servings < 1 or servings < 1:
        raise ValueError("servings must be at least 1")
    if quantity is None or servings == original_servings:
        return quantity
    if quantity <= 0:
        return quantity
    raw = quantity * servings / original_servings
    canonical = canonical_unit(unit)
    if canonical in _METRIC_SMALL:
        return _round_metric(raw)
    if canonical in _FRACTIONAL:
        return _round_fraction(raw, allow_eighth=canonical in _SPOONS)
    return _round_half(raw)


def _round_metric(raw: float) -> float:
    step = 5 if raw >= 100 else 1
    return float(max(1, _half_up(raw / step) * step))


def _round_half(raw: float) -> float:
    return max(0.5, _half_up(raw * 2) / 2)


def _round_fraction(raw: float, *, allow_eighth: bool) -> float:
    whole = int(raw)
    candidates = [whole + fraction for fraction in _FRACTIONS]
    if allow_eighth and whole == 0:
        candidates.append(_EIGHTH)
    # Nearest non-zero amount. Ties go up: a little more is the safer side of "never zero".
    best = min(
        (c for c in candidates if c > 0),
        key=lambda c: (round(abs(c - raw), 9), -c),
    )
    return round(best, _DECIMALS)


def _half_up(value: float) -> int:
    """Round half up (Python's ``round`` is half-to-even, which the phone would not match)."""
    return int(value + 0.5 + 1e-9)
