"""I/O wrapper around the pure ``fit``: loads the version (with the version access rule), the
caller's confirmed pantry and the seeded dictionary."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import ValidationError
from app.db.models import PantryItem, RecipeVersion, User
from app.domains.matching.dictionary import load_dictionary
from app.domains.matching.fit import FitResult, PantryEntry, RecipeIngredient, fit
from app.domains.recipes import scaling
from app.domains.recipes import service as recipes_service
from app.domains.recipes.schemas import IngredientOut


def resolve_servings(servings: int | None, original_servings: int) -> int:
    """The servings to compute for (brief 020): the recipe's own when none is asked for,
    otherwise one of the dial stops (1 to 6, plus the recipe's own when it is larger)."""
    if servings is None:
        return original_servings
    if not scaling.is_valid_servings(servings, original_servings):
        stops = scaling.dial_stops(original_servings)
        raise ValidationError(
            f"servings must be one of {', '.join(map(str, stops))}",
            extra={"fields": ["servings"], "allowed": stops},
        )
    return servings


def ingredients_of(version: RecipeVersion, servings: int | None = None) -> list[RecipeIngredient]:
    """The version's ingredients, with amounts scaled to ``servings`` (brief 020). ``None`` and
    the recipe's own servings both give exactly what the creator wrote."""
    original = version.servings
    target = original if servings is None else servings
    return [
        RecipeIngredient(
            id=i.id,
            name=i.name,
            quantity=scaling.scale_quantity(
                i.quantity, i.unit, original_servings=original, servings=target
            )
            if target != original
            else i.quantity,
            unit=i.unit,
            optional=i.optional,
        )
        for i in (IngredientOut.model_validate(raw) for raw in version.ingredient_json or [])
    ]


async def load_pantry(session: AsyncSession, user: User) -> list[PantryEntry]:
    """The caller's confirmed pantry, as the pure ``fit`` reads it."""
    rows = (
        await session.execute(select(PantryItem).where(PantryItem.owner_user_id == user.id))
    ).scalars()
    return [
        PantryEntry(
            id=r.id,
            raw_label=r.raw_label,
            normalized_name=r.normalized_name,
            quantity=float(r.quantity) if r.quantity is not None else None,
            unit=r.unit,
            last_confirmed_at=r.last_confirmed_at,
            quantity_is_estimate=r.quantity_is_estimate,
        )
        for r in rows
    ]


async def fit_version(
    session: AsyncSession,
    user: User,
    version_id: uuid.UUID,
    now: datetime,
    *,
    servings: int | None = None,
) -> FitResult:
    version, recipe, _saved = await recipes_service.get_accessible_version(
        session, version_id, user=user
    )
    target = resolve_servings(servings, version.servings)
    pantry = await load_pantry(session, user)
    dictionary = await load_dictionary(session)
    title = version.title or recipe.title
    result = fit(version.id, ingredients_of(version, target), pantry, dictionary, now, title=title)
    result.servings = target
    return result
