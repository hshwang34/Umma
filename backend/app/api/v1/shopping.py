"""Shopping list (brief 017). Owner only: a foreign item id and a missing one are the same 404."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

from fastapi import APIRouter, Response, status

from app.core.errors import NotFound
from app.core.security import CurrentUser
from app.db.engine import DbSession
from app.db.models import ShoppingReason
from app.domains.matching.dictionary import load_dictionary
from app.domains.recipes import service as recipes_service
from app.domains.shopping import service
from app.domains.shopping.schemas import ShoppingItemIn, ShoppingItemOut, ShoppingList

router = APIRouter(prefix="/shopping-list", tags=["shopping-list"])


def _now() -> datetime:
    return datetime.now(UTC)


def _item_id(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise NotFound("Shopping item not found") from exc


@router.get("", response_model=ShoppingList)
async def list_shopping(session: DbSession, user: CurrentUser) -> ShoppingList:
    rows = await service.list_items(session, user, _now())
    return ShoppingList(items=[ShoppingItemOut.of(r) for r in rows])


@router.post(
    "",
    response_model=ShoppingItemOut,
    status_code=status.HTTP_201_CREATED,
    responses={200: {"model": ShoppingItemOut, "description": "Already on the list"}},
)
async def add_shopping_item(
    body: ShoppingItemIn, response: Response, session: DbSession, user: CurrentUser
) -> ShoppingItemOut:
    """201 with the new item, or 200 with the open item that already has this name."""
    if body.recipe_version_id is not None:  # only a version the caller may read (else 404)
        await recipes_service.get_accessible_version(session, body.recipe_version_id, user=user)
    row, created = await service.add_item(
        session,
        user,
        body.name,
        ShoppingReason(body.reason),
        await load_dictionary(session),
        recipe_version_id=body.recipe_version_id,
    )
    if not created:
        response.status_code = status.HTTP_200_OK
    return ShoppingItemOut.of(row)


@router.post("/{item_id}/check", response_model=ShoppingItemOut)
async def check_shopping_item(
    item_id: str, session: DbSession, user: CurrentUser
) -> ShoppingItemOut:
    return ShoppingItemOut.of(await service.check_item(session, user, _item_id(item_id), _now()))


@router.post("/{item_id}/uncheck", response_model=ShoppingItemOut)
async def uncheck_shopping_item(
    item_id: str, session: DbSession, user: CurrentUser
) -> ShoppingItemOut:
    return ShoppingItemOut.of(await service.uncheck_item(session, user, _item_id(item_id)))


@router.delete("/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_shopping_item(item_id: str, session: DbSession, user: CurrentUser) -> Response:
    await service.delete_item(session, user, _item_id(item_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)
