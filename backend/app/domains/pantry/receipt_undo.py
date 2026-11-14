"""Whole-receipt undo (brief 017 PR 2c). Owner only; a foreign receipt is the same 404 as a
missing one.

Undo reverses only what the receipt itself did, and only on items that are still exactly as the
receipt left them: the quantity, unit and ``last_confirmed_at`` the stored answer recorded.
``last_confirmed_at`` is the signal because every pantry write sets it (edit, confirm, a merge
from a scan or typed add, a later receipt), so an item touched since then is left alone and
named in ``unchanged``. An item deleted since is skipped. The receipt row is then deleted: the
same receipt can be saved afresh, and a second undo is a 404, never a double restore.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Any

import pydantic
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import PantryItem, PantryReceipt, User
from app.domains.ownership import get_owned_or_404
from app.domains.pantry import service
from app.domains.pantry.schemas import PantryItemOut, ReceiptUndoResult


def _as_left(row: PantryItem, left: object) -> bool:
    """Is the item still as the receipt's stored answer recorded it? Anything unreadable is no."""
    try:
        was = PantryItemOut.model_validate(left)
    except pydantic.ValidationError:
        return False
    now = PantryItemOut.of(row)
    return (now.quantity, now.unit, now.last_confirmed_at) == (
        was.quantity,
        was.unit,
        was.last_confirmed_at,
    )


def _restore(row: PantryItem, previous: Any) -> bool:
    """Put back what the merge changed. ``False`` (nothing written) if the record is unusable."""
    try:
        quantity = previous["quantity"]
        seen = previous["last_confirmed_at"]
        amount = None if quantity is None else Decimal(quantity)
        confirmed = None if seen is None else datetime.fromisoformat(seen)
        unit = previous["unit"]
    except (KeyError, TypeError, ValueError, InvalidOperation):
        return False
    row.quantity, row.unit, row.last_confirmed_at = amount, unit, confirmed
    return True


def _uuid(value: object) -> uuid.UUID | None:
    try:
        return uuid.UUID(str(value))
    except ValueError:
        return None


async def undo_receipt(
    session: AsyncSession, user: User, receipt_id: uuid.UUID
) -> ReceiptUndoResult:
    # The pantry lock serialises this with receipt saves and with a second undo of the same
    # receipt, which then finds no row (404).
    await service.lock_user(session, user.id, "pantry")
    receipt = await get_owned_or_404(
        session, PantryReceipt, receipt_id, user.id, label="Receipt", for_update=True
    )
    stored = receipt.result_json
    undo = stored.get("undo") or {}
    response = stored.get("response") or {}
    left = {
        _uuid(item.get("id")): item
        for item in [*response.get("added", []), *response.get("merged", [])]
    }
    created = [_uuid(i) for i in undo.get("created", [])]
    previous = {_uuid(m.get("id")): m.get("previous") for m in undo.get("merged", [])}

    # Row locks: edits and confirms do not take the pantry lock.
    rows = await session.scalars(
        select(PantryItem)
        .where(
            PantryItem.owner_user_id == user.id,
            PantryItem.id.in_({i for i in [*created, *previous] if i is not None}),
        )
        .order_by(PantryItem.id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    by_id = {row.id: row for row in rows}

    result = ReceiptUndoResult(receipt_id=receipt.id)
    for item_id in dict.fromkeys([*created, *previous]):
        row = by_id.get(item_id) if item_id is not None else None
        if row is None:  # deleted since the receipt
            continue
        if not _as_left(row, left.get(item_id)):
            result.unchanged.append(row.raw_label)
        elif item_id in previous:
            if _restore(row, previous[item_id]):
                result.restored += 1
            else:
                result.unchanged.append(row.raw_label)
        else:
            await session.delete(row)
            result.removed += 1
    await session.delete(receipt)
    await session.flush()
    return result
