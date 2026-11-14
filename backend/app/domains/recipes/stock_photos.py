"""Pexels stock photos for recipes without a creator photo (brief 019, DECISIONS #31).

* Looked up once, after a first publish commits (a background task) or by the backfill
  (``make covers``), and stored on the recipe. The read side never calls Pexels.
* Query: the recipe title; if Pexels finds nothing, the title's last two words plus "food";
  if that finds nothing too, nothing is stored and the card keeps its placeholder.
* A creator photo (uploaded cover or ``cover_image_url``) always wins, so recipes that have one
  are skipped. Best effort: every Pexels or network error is logged and swallowed.
* Without ``PEXELS_API_KEY`` there is no client and every lookup is skipped (logged once).
* The key is a ``SecretStr`` and only ever goes into the ``Authorization`` header.
"""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass
from typing import Any

import httpx
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.config import Settings
from app.db.models import Recipe

log = logging.getLogger("umma.stock_photos")

SEARCH_URL = "https://api.pexels.com/v1/search"
_warned_no_key = False


@dataclass(frozen=True)
class StockPhoto:
    url: str
    photographer: str
    photographer_url: str
    photo_id: str


class PexelsClient:
    def __init__(
        self,
        api_key: str,
        *,
        timeout_seconds: float = 5.0,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._api_key = api_key
        self._timeout = timeout_seconds
        self._transport = transport

    async def search_one(self, query: str) -> StockPhoto | None:
        """The first landscape result for ``query``, or ``None`` when there is none. Raises
        ``httpx.HTTPError`` on transport or HTTP errors."""
        async with httpx.AsyncClient(timeout=self._timeout, transport=self._transport) as client:
            res = await client.get(
                SEARCH_URL,
                params={"query": query, "per_page": 1, "orientation": "landscape"},
                headers={"Authorization": self._api_key},
            )
            res.raise_for_status()
            return _first_photo(res.json())


def _first_photo(body: Any) -> StockPhoto | None:
    photos = body.get("photos") if isinstance(body, dict) else None
    if not photos or not isinstance(photos[0], dict):
        return None
    photo = photos[0]
    src = photo.get("src")
    if not isinstance(src, dict):
        return None
    url = src.get("landscape") or src.get("large")
    name, page, photo_id = photo.get("photographer"), photo.get("photographer_url"), photo.get("id")
    if not (isinstance(url, str) and url.startswith("https://") and name and page and photo_id):
        return None
    return StockPhoto(
        url=url, photographer=str(name), photographer_url=str(page), photo_id=str(photo_id)
    )


def build_client(settings: Settings) -> PexelsClient | None:
    global _warned_no_key
    if settings.pexels_api_key is None or not settings.pexels_api_key.get_secret_value():
        if not _warned_no_key:
            log.info("PEXELS_API_KEY is not set; stock photo lookups are skipped")
            _warned_no_key = True
        return None
    return PexelsClient(
        settings.pexels_api_key.get_secret_value(), timeout_seconds=settings.pexels_timeout_seconds
    )


def queries_for(title: str) -> list[str]:
    words = title.split()
    fallback = " ".join(words[-2:]) + " food"
    return [title.strip(), fallback] if words else []


async def find_photo(client: PexelsClient, title: str) -> StockPhoto | None:
    for query in queries_for(title):
        photo = await client.search_one(query)
        if photo is not None:
            return photo
    return None


def has_creator_cover(recipe: Recipe) -> bool:
    return recipe.cover_media_id is not None or bool(recipe.cover_image_url)


async def fill_recipe(
    sessionmaker: async_sessionmaker[AsyncSession],
    client: PexelsClient | None,
    recipe_id: uuid.UUID,
    *,
    replace: bool = False,
) -> bool:
    """Look up and store a stock photo for one recipe. True when one was stored. Never raises
    for Pexels trouble; the network call runs outside any transaction."""
    if client is None:
        return False
    async with sessionmaker() as session:
        recipe = await session.get(Recipe, recipe_id)
        if recipe is None or recipe.latest_version_id is None or has_creator_cover(recipe):
            return False
        if recipe.stock_photo_url and not replace:
            return False
        title = recipe.title
    try:
        photo = await find_photo(client, title)
    except (httpx.HTTPError, ValueError) as exc:
        log.warning(
            "stock photo lookup failed",
            extra={"recipe_id": str(recipe_id), "error_type": type(exc).__name__},
        )
        return False
    if photo is None:
        log.info("no stock photo found", extra={"recipe_id": str(recipe_id)})
        return False
    async with sessionmaker() as session:
        stmt = (
            update(Recipe)
            .where(Recipe.id == recipe_id, Recipe.cover_media_id.is_(None))
            .values(
                stock_photo_url=photo.url,
                stock_photo_credit_name=photo.photographer[:200],
                stock_photo_credit_url=photo.photographer_url,
                stock_photo_id=photo.photo_id[:64],
            )
        )
        if not replace:
            stmt = stmt.where(Recipe.stock_photo_url.is_(None))
        stored = (await session.execute(stmt)).rowcount  # type: ignore[attr-defined]
        await session.commit()
    return bool(stored)


async def recipes_without_cover(session: AsyncSession) -> list[uuid.UUID]:
    stmt = (
        select(Recipe.id)
        .where(
            Recipe.latest_version_id.is_not(None),
            Recipe.cover_media_id.is_(None),
            (Recipe.cover_image_url.is_(None)) | (Recipe.cover_image_url == ""),
            Recipe.stock_photo_url.is_(None),
        )
        .order_by(Recipe.published_at, Recipe.id)
    )
    return list((await session.execute(stmt)).scalars().all())
