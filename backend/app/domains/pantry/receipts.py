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
from datetime import datetime
from decimal import Decimal

import pydantic
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.providers.base import ReceiptDraft, ReceiptLine
from app.db.models import PantryItem, PantryReceipt, User
from app.domains.matching.dictionary import IngredientDictionary
from app.domains.matching.normalize import normalize
from app.domains.matching.units import pantry_unit
from app.domains.pantry import service
from app.domains.pantry.observations import confidence_bin
from app.domains.pantry.schemas import (
    QUANTITY_MAX,
    CreateReceiptPantryItems,
    MergeInto,
    PantryItemOut,
    ReceiptNewItem,
    ReceiptResult,
    ReceiptSkipped,
    ReceiptWouldAdd,
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


def _snapshot(row: PantryItem) -> dict[str, object]:
    return {
        "quantity": _dec(row.quantity),
        "unit": row.unit,
        "last_confirmed_at": row.last_confirmed_at.isoformat() if row.last_confirmed_at else None,
        "source": row.source.value,
        "confidence": row.confidence,
        "quantity_is_estimate": row.quantity_is_estimate,
    }


async def save_receipt(
    session: AsyncSession,
    user: User,
    draft: ReceiptDraft,
    dictionary: IngredientDictionary,
    now: datetime,
) -> ReceiptResult:
    purchases, skipped = read_lines(draft, dictionary)
    result = ReceiptResult(
        receipt_id=None, purchased_on=draft.purchased_on, store=draft.store, skipped=skipped
    )
    if draft.demo:  # a fixture answered: nothing is saved and no receipt is recorded
        result.demo = True
        result.would_add = [
            ReceiptWouldAdd(name=p.key, quantity=float(p.amount), unit=p.unit) for p in purchases
        ]
        return result

    # The pantry lock also serialises two uploads of one receipt: the second sees the first's row.
    await service.lock_user(session, user.id, "pantry")
    digest = receipt_hash(draft)
    if digest is not None:
        seen = await session.scalar(
            select(PantryReceipt).where(
                PantryReceipt.owner_user_id == user.id, PantryReceipt.receipt_hash == digest
            )
        )
        if seen is not None:
            replay = ReceiptResult.model_validate(seen.result_json["response"])
            return replay.model_copy(update={"duplicate": True})

    existing: dict[str, PantryItem] = {}
    rows = await session.scalars(
        select(PantryItem)
        .where(
            PantryItem.owner_user_id == user.id,
            PantryItem.normalized_name.in_({p.key for p in purchases}),
        )
        .order_by(PantryItem.last_confirmed_at.desc().nulls_last(), PantryItem.id)
    )
    for row in rows:  # several rows of one name (keep_both): the most recently confirmed
        existing.setdefault(row.normalized_name, row)

    items: list[ReceiptNewItem] = []
    undo_merged: list[dict[str, object]] = []
    for p in purchases:
        target = existing.get(p.key)
        if target is None:
            quantity, unit = p.amount, p.unit
        else:
            quantity, unit = merged_quantity(target.quantity, target.unit, p), target.unit
        try:
            item = ReceiptNewItem(
                raw_label=p.label,
                quantity=float(quantity) if quantity is not None else None,
                unit=unit if quantity is not None else None,  # type: ignore[arg-type]
                source="receipt",
                confidence=p.confidence,
                resolution=MergeInto(merge_into=target.id) if target is not None else None,
            )
        except pydantic.ValidationError:  # a label or amount the pantry would not accept
            result.skipped.append(ReceiptSkipped(raw_text=p.raw_text, reason="unreadable"))
            continue
        items.append(item)
        if target is not None:
            undo_merged.append({"id": str(target.id), "previous": _snapshot(target)})

    saved: list[PantryItem] = []
    if items:
        body = CreateReceiptPantryItems(items=items)
        saved = await service.create_items(session, user, body, dictionary, now)
    for item, row in zip(items, saved, strict=True):
        (result.merged if item.resolution is not None else result.added).append(
            PantryItemOut.of(row)
        )

    receipt = PantryReceipt(
        owner_user_id=user.id,
        receipt_hash=digest,
        purchased_on=draft.purchased_on,
        store=draft.store,
        result_json={},
    )
    session.add(receipt)
    await session.flush()
    result.receipt_id = receipt.id
    receipt.result_json = {
        "response": result.model_dump(mode="json"),
        # What a whole-receipt undo needs (the endpoint is a later PR).
        "undo": {"created": [str(i.id) for i in result.added], "merged": undo_merged},
    }
    await session.flush()
    return result
