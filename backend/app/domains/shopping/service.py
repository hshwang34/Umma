"""In-app shopping list (brief 017, DECISIONS #29). Owner only: a foreign id is the same 404 as a
missing one.

Each ingredient appears once: at most one open (unchecked) item per owner and normalised name,
enforced by the partial unique index. Adding a name that is already open returns the open item
and writes nothing, so every caller (the manual add, the key-ingredient card, the coach, the
session finish) is idempotent. Names outside the ingredient dictionary are allowed and stored
with ``ingredient_id`` NULL. Nothing here touches the pantry.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterable, Mapping, Sequence
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import func, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import ShoppingCheckedBy, ShoppingItem, ShoppingReason, User
from app.domains.matching.dictionary import IngredientDictionary, load_dictionary
from app.domains.matching.fit import PantryEntry, RecipeIngredient, fit
from app.domains.matching.normalize import Normalized, alternatives, conjuncts, normalize
from app.domains.ownership import get_owned_or_404
from app.domains.recipes.schemas import IngredientOut
from app.domains.shopping.schemas import NAME_MAX

CHECKED_VISIBLE_FOR = timedelta(days=14)
_OPEN = ShoppingItem.checked_at.is_(None)


async def list_items(session: AsyncSession, user: User, now: datetime) -> list[ShoppingItem]:
    """Open items, newest first, then the items checked in the last 14 days, newest first."""
    stmt = (
        select(ShoppingItem)
        .where(
            ShoppingItem.owner_user_id == user.id,
            _OPEN | (ShoppingItem.checked_at > now - CHECKED_VISIBLE_FOR),
        )
        .order_by(
            ShoppingItem.checked_at.is_not(None),
            func.coalesce(ShoppingItem.checked_at, ShoppingItem.created_at).desc(),
            ShoppingItem.normalized_name,
            ShoppingItem.id,
        )
    )
    return list((await session.scalars(stmt)).all())


async def _open_item(session: AsyncSession, user: User, key: str) -> ShoppingItem | None:
    stmt = select(ShoppingItem).where(
        ShoppingItem.owner_user_id == user.id, ShoppingItem.normalized_name == key, _OPEN
    )
    return (await session.scalars(stmt)).one_or_none()


def _keyed(name: str, dictionary: IngredientDictionary) -> tuple[str, str, Normalized]:
    label = " ".join(name.split())[:NAME_MAX]
    norm = normalize(label, dictionary)
    return label, (norm.key or label.casefold())[:NAME_MAX], norm


async def is_listed(
    session: AsyncSession, user: User, name: str, dictionary: IngredientDictionary
) -> bool:
    """Is ``name`` already an open item on the caller's list? Read only."""
    return await _open_item(session, user, _keyed(name, dictionary)[1]) is not None


async def add_item(
    session: AsyncSession,
    user: User,
    name: str,
    reason: ShoppingReason,
    dictionary: IngredientDictionary,
    *,
    session_id: uuid.UUID | None = None,
    recipe_version_id: uuid.UUID | None = None,
) -> tuple[ShoppingItem, bool]:
    """(the open item for ``name``, whether this call created it)."""
    label, key, norm = _keyed(name, dictionary)
    insert = (
        pg_insert(ShoppingItem)
        .values(
            owner_user_id=user.id,
            raw_label=label,
            normalized_name=key,
            ingredient_id=norm.ingredient_id,
            reason=reason,
            source_session_id=session_id,
            source_recipe_version_id=recipe_version_id,
        )
        .on_conflict_do_nothing(
            index_elements=["owner_user_id", "normalized_name"], index_where=_OPEN
        )
        .returning(ShoppingItem.id)
    )
    for _ in range(3):  # a concurrent add wins the index; its item may be checked before we read
        new_id = await session.scalar(insert)
        if new_id is not None:
            return await session.get_one(ShoppingItem, new_id), True
        existing = await _open_item(session, user, key)
        if existing is not None:
            return existing, False
    raise RuntimeError("shopping item could not be added")  # pragma: no cover


async def add_missing(
    session: AsyncSession,
    user: User,
    names: Iterable[str],
    reason: ShoppingReason,
    session_id: uuid.UUID | None = None,
    recipe_version_id: uuid.UUID | None = None,
) -> list[ShoppingItem]:
    """Put each named ingredient on the list unless it is already open there. Returns only the
    items this call created, so calling it twice adds (and returns) nothing new."""
    dictionary = await load_dictionary(session)
    created: list[ShoppingItem] = []
    for name in names:
        if not name.strip():
            continue
        row, new = await add_item(
            session,
            user,
            name,
            reason,
            dictionary,
            session_id=session_id,
            recipe_version_id=recipe_version_id,
        )
        if new:
            created.append(row)
    return created


def missing_at_start(
    ingredients: Sequence[IngredientOut],
    pantry_snapshot: Sequence[Mapping[str, Any]],
    swapped_refs: set[str],
    dictionary: IngredientDictionary,
    now: datetime,
) -> list[str]:
    """Names of the required ingredients a cooking session started without and never swapped.

    Recomputed with the Pantry fit rules against the session's ``pantry_snapshot_json`` (the
    pantry items relevant to the recipe when the session was created). Only presence counts:
    the snapshot keeps names, not amounts, so "too little" is never missing. Optional
    ingredients and ingredients with an approved swap are left out. Each part of a "salt and
    pepper" line is judged on its own; an "X or Y" line is named by its first alternative. Pure.
    """
    pantry = [
        PantryEntry(
            id=uuid.UUID(str(p["pantry_item_id"])),
            raw_label=str(p["normalized_name"]),
            normalized_name=str(p["normalized_name"]),
            quantity=None,
            unit=None,
            last_confirmed_at=now,
        )
        for p in pantry_snapshot
    ]
    parts = [
        RecipeIngredient(id=ing.id, name=part)
        for ing in ingredients
        if not ing.optional and ing.id not in swapped_refs
        for part in conjuncts(ing.name, dictionary)
    ]
    result = fit(uuid.UUID(int=0), parts, pantry, dictionary, now)
    names: list[str] = []
    for item in result.items:
        if item.status == "missing":
            options = alternatives(item.name)
            names.append(options[0] if len(options) > 1 else item.name)
    return names


async def _owned(session: AsyncSession, user: User, item_id: uuid.UUID) -> ShoppingItem:
    return await get_owned_or_404(
        session, ShoppingItem, item_id, user.id, label="Shopping item", for_update=True
    )


async def check_item(
    session: AsyncSession, user: User, item_id: uuid.UUID, now: datetime
) -> ShoppingItem:
    row = await _owned(session, user, item_id)
    if row.checked_at is None:
        row.checked_at = now
        row.checked_by = ShoppingCheckedBy.USER
        await session.flush()
        await session.refresh(row)
    return row


async def uncheck_item(session: AsyncSession, user: User, item_id: uuid.UUID) -> ShoppingItem:
    """Back to open. If the same ingredient was put on the list again meanwhile, that open item
    is the answer and this checked duplicate is dropped: each item appears once."""
    row = await _owned(session, user, item_id)
    if row.checked_at is None:
        return row
    try:
        async with session.begin_nested():
            row.checked_at = None
            row.checked_by = None
            await session.flush()
    except IntegrityError:
        await session.refresh(row)
        twin = await _open_item(session, user, row.normalized_name)
        if twin is None:  # pragma: no cover - the twin was checked or deleted in between
            raise
        await session.delete(row)
        await session.flush()
        return twin
    await session.refresh(row)
    return row


async def delete_item(session: AsyncSession, user: User, item_id: uuid.UUID) -> None:
    row = await _owned(session, user, item_id)
    await session.delete(row)
    await session.flush()


async def check_bought(
    session: AsyncSession, user: User, keys: Iterable[str], now: datetime
) -> list[ShoppingItem]:
    """Tick off the open items a receipt just brought home (``checked_by = receipt``)."""
    wanted = set(keys)
    if not wanted:
        return []
    stmt = (
        update(ShoppingItem)
        .where(
            ShoppingItem.owner_user_id == user.id,
            ShoppingItem.normalized_name.in_(wanted),
            _OPEN,
        )
        .values(checked_at=now, checked_by=ShoppingCheckedBy.RECEIPT)
        .returning(ShoppingItem)
        .execution_options(synchronize_session=False, populate_existing=True)
    )
    rows = list((await session.scalars(stmt)).all())
    return sorted(rows, key=lambda r: r.normalized_name)
