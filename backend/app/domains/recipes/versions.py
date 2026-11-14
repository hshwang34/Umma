"""Reading a ``recipe_versions`` row as served (shared by the read side and the editor)."""

from __future__ import annotations

from typing import TypedDict

from app.db.models import Recipe, RecipeVersion
from app.domains.recipes.schemas import CoverCredit
from app.media import signing


class VersionMeta(TypedDict):
    title: str
    summary: str | None
    tags: list[str]
    cover_image_url: str | None


def version_meta(recipe: Recipe, version: RecipeVersion) -> VersionMeta:
    """Display metadata snapshotted on the version at publish time.

    Every version written by publish/seed has a non-null ``title`` (a publish rule), so a null
    title marks a row that predates the snapshot columns; only then do we fall back to the
    mutable ``recipes`` columns, for all four fields together.
    """
    if version.title is None:
        return VersionMeta(
            title=recipe.title,
            summary=recipe.summary,
            tags=list(recipe.tags),
            cover_image_url=recipe.cover_image_url,
        )
    return VersionMeta(
        title=version.title,
        summary=version.summary,
        tags=list(version.tags or []),
        cover_image_url=version.cover_image_url,
    )


class ServedMeta(VersionMeta):
    cover_credit: CoverCredit | None


def served_meta(recipe: Recipe, version: RecipeVersion) -> ServedMeta:
    """``version_meta`` as the read side serves it, with the cover resolved (brief 019):
    the version's uploaded photo (a fresh signed URL), else its https ``cover_image_url``, else
    the recipe's stock photo with its credit, else none."""
    meta = version_meta(recipe, version)
    url, credit = meta["cover_image_url"], None
    media = version.cover_media
    signed = signing.sign(media) if media is not None and media.status == "ready" else None
    if signed:
        url = signed
    elif not url and recipe.stock_photo_url:
        url = recipe.stock_photo_url
        if recipe.stock_photo_credit_name and recipe.stock_photo_credit_url:
            credit = CoverCredit(
                name=recipe.stock_photo_credit_name, url=recipe.stock_photo_credit_url
            )
    return ServedMeta(**{**meta, "cover_image_url": url}, cover_credit=credit)
