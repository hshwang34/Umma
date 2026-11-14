"""Grocery receipt → pantry (brief 017, DECISIONS #29). Owner only; no review step.

* Every line is untrusted model output. A line is saved only when it is food, its name is in the
  ingredient dictionary and its confidence is in the same ``high`` bin the live scan auto-saves
  (``observations.confidence_bin``). Anything else that is food is reported under ``skipped``,
  never guessed. Non-food lines are dropped.
* Lines for the same ingredient are combined, then written through ``service.create_items`` with
  the internal source ``receipt``. An ingredient already in the pantry is merged into (rebought):
  ``last_confirmed_at`` is refreshed and the amount changes only under ``merged_quantity``.
* A demo draft (mock provider) saves nothing and records nothing.
* ``pantry_receipts`` stores a hash of the receipt's date, store and total and the first answer;
  a second photo of the same receipt replays that answer with ``duplicate`` set and changes
  nothing, even when its lines were read differently.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from decimal import Decimal

from app.ai.providers.base import ReceiptDraft, ReceiptLine
from app.domains.matching.dictionary import IngredientDictionary
from app.domains.matching.normalize import normalize
from app.domains.matching.units import pantry_unit
from app.domains.pantry.observations import confidence_bin
from app.domains.pantry.schemas import (
    QUANTITY_MAX,
    ReceiptSkipped,
)


@dataclass
class Purchase:
    """One ingredient bought on a receipt, after same-ingredient lines are combined."""

    key: str
    label: str
    raw_text: str
    count: int
    quantity: Decimal | None  # set only with a pantry ``unit`` (a printed weight or volume)
    unit: str | None
    confidence: float

    @property
    def amount(self) -> Decimal:
        return self.quantity if self.quantity is not None else Decimal(self.count)


def _dec(value: Decimal | None) -> str | None:
    return None if value is None else format(value.normalize(), "f")


def receipt_hash(draft: ReceiptDraft) -> str | None:
    """SHA-256 over the date, store and total only. The lines are left out on purpose: a second
    photo of the same receipt can read a blurry line differently, and that must still be the same
    receipt. ``None`` unless both a date and a total were printed: same store, same day, same
    total identifies a shop; anything less is too weak, so such a receipt is never a duplicate."""
    if draft.purchased_on is None or draft.total is None:
        return None
    store = " ".join((draft.store or "").lower().split())
    payload = [draft.purchased_on.isoformat(), store, _dec(draft.total)]
    return hashlib.sha256(json.dumps(payload, separators=(",", ":")).encode()).hexdigest()


def merged_quantity(
    existing: Decimal | None, existing_unit: str | None, bought: Purchase
) -> Decimal | None:
    """The rebought item's new quantity, or ``None`` to leave its amount untouched. Amounts are
    added only like for like: same unit, or a pack count onto a unitless quantity. Nothing is
    converted and an amount is never replaced by a guess."""
    if existing is None:
        return None
    if bought.quantity is not None:
        total = existing + bought.quantity if existing_unit == bought.unit else None
    else:
        total = existing + bought.count if existing_unit is None else None
    return total if total is not None and total <= QUANTITY_MAX else None


def read_lines(
    draft: ReceiptDraft, dictionary: IngredientDictionary
) -> tuple[list[Purchase], list[ReceiptSkipped]]:
    """(purchases to save, skipped food lines). Pure."""
    purchases: dict[str, Purchase] = {}
    skipped: list[ReceiptSkipped] = []

    def skip(line: ReceiptLine, reason: str) -> None:
        skipped.append(ReceiptSkipped(raw_text=line.raw_text, reason=reason))  # type: ignore[arg-type]

    for line in draft.lines:
        norm = normalize(line.name, dictionary) if line.name else None
        if not line.is_food:
            continue
        if norm is None or line.name is None:
            skip(line, "unreadable")
        elif norm.entry is None:
            skip(line, "unknown_item")
        elif confidence_bin(line.confidence) != "high":
            skip(line, "low_confidence")
        else:
            unit = pantry_unit(line.unit) if line.quantity is not None and line.unit else None
            bought = Purchase(
                key=norm.key,
                label=line.name,
                raw_text=line.raw_text,
                count=line.count or 1,  # a printed food line is at least one pack
                quantity=line.quantity if unit else None,
                unit=unit,
                confidence=line.confidence,
            )
            first = purchases.get(norm.key)
            if first is None:
                purchases[norm.key] = bought
                continue
            # Two lines, one ingredient: counts add; weights add only in the same unit,
            # otherwise the combined purchase is a pack count.
            same_unit = first.quantity is not None and first.unit == bought.unit
            first.count += bought.count
            first.quantity = first.quantity + bought.quantity if same_unit else None  # type: ignore[operator]
            first.unit = first.unit if same_unit else None
            first.confidence = min(first.confidence, bought.confidence)
    return list(purchases.values()), skipped
