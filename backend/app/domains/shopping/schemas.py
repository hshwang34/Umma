"""Shopping list DTOs (brief 017). Write side is strict; read side mirrors the row."""

from __future__ import annotations

import uuid
from datetime import datetime
from functools import partial
from typing import Annotated, Literal

from pydantic import BaseModel, BeforeValidator, ConfigDict, StringConstraints

from app.db.models import ShoppingItem
from app.domains.recipes.draft_schemas import check_text

NAME_MAX = 120

# ``no_substitute`` is written only by the coach (a later PR), never by the public POST.
ReasonIn = Literal["missing", "ran_out", "manual"]
ReasonOut = Literal["missing", "ran_out", "no_substitute", "manual"]


class ShoppingItemIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: Annotated[
        str,
        BeforeValidator(partial(check_text, multiline=False, trim=True)),
        StringConstraints(min_length=1, max_length=NAME_MAX),
    ]
    reason: ReasonIn = "manual"
    recipe_version_id: uuid.UUID | None = None


class ShoppingItemOut(BaseModel):
    id: uuid.UUID
    raw_label: str
    normalized_name: str
    ingredient_id: uuid.UUID | None
    reason: ReasonOut
    source_session_id: uuid.UUID | None
    source_recipe_version_id: uuid.UUID | None
    checked_at: datetime | None
    checked_by: Literal["user", "receipt"] | None
    created_at: datetime
    updated_at: datetime

    @classmethod
    def of(cls, row: ShoppingItem) -> ShoppingItemOut:
        return cls(
            id=row.id,
            raw_label=row.raw_label,
            normalized_name=row.normalized_name,
            ingredient_id=row.ingredient_id,
            reason=row.reason.value,  # type: ignore[arg-type]
            source_session_id=row.source_session_id,
            source_recipe_version_id=row.source_recipe_version_id,
            checked_at=row.checked_at,
            checked_by=row.checked_by.value if row.checked_by else None,  # type: ignore[arg-type]
            created_at=row.created_at,
            updated_at=row.updated_at,
        )


class ShoppingList(BaseModel):
    items: list[ShoppingItemOut]
