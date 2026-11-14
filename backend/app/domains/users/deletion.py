"""Account deletion: ``DELETE /v1/me`` (brief 010 PR 2, App Review guideline 5.1.1(v)).

One transaction removes the account and everything it owns. Almost every owned table hangs off
``users.id`` with ``ON DELETE CASCADE`` (see ``tests/integration/test_delete_account.py``,
which fails when a new table references users without being covered here). What needs care:

* **Media.** ``recipe_media`` rows go by cascade; the 0008 trigger queues every object for the
  worker to delete from storage, in this same transaction.
* **Recipe versions** are append-only (0002 trigger), so the transaction sets the documented
  ``umma.unlock_versions`` switch.
* **Other people's cooking sessions** pin a recipe version forever (``ON DELETE RESTRICT``),
  and other people may have saved or adapted a recipe. Those recipes are kept, without their
  video, clips or cover photo, under one anonymous account (``FORMER_CREATOR``). Every other
  recipe, published or not, is deleted.
* **AI spend ledger** rows stay with ``user_id`` nulled (they hold no content), so deleting an
  account never refunds the monthly budget.
* **Sign in with Apple.** The stored refresh token is read first and revoked after the commit.
  A revoke that fails or cannot run is logged and never blocks the deletion.
"""

from __future__ import annotations

import logging
import uuid

from sqlalchemy import delete, or_, select, text, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.db.models import (
    CookingSession,
    DevLoginChallenge,
    Recipe,
    RecipeDraft,
    RecipeVariation,
    RecipeVersion,
    Save,
    User,
)
from app.domains.users import apple_tokens
from app.domains.users.apple_tokens import AppleTokenClient

log = logging.getLogger("umma.account")

# The anonymous owner of recipes that outlive their creator. No sign-in path accepts this
# provider (like the seed personas), so nobody can ever sign in as it.
FORMER_CREATOR_PROVIDER = "deleted"
FORMER_CREATOR_SUBJECT = "former-creator"
FORMER_CREATOR_NAME = "Former Umma cook"


async def _former_creator(session: AsyncSession) -> User:
    async def find() -> User | None:
        return await session.scalar(
            select(User).where(
                User.auth_provider == FORMER_CREATOR_PROVIDER,
                User.auth_subject == FORMER_CREATOR_SUBJECT,
            )
        )

    existing = await find()
    if existing is not None:
        return existing
    candidate = User(
        id=uuid.uuid4(),
        auth_provider=FORMER_CREATOR_PROVIDER,
        auth_subject=FORMER_CREATOR_SUBJECT,
        display_name=FORMER_CREATOR_NAME,
    )
    try:
        async with session.begin_nested():
            session.add(candidate)
            await session.flush()
    except IntegrityError:
        existing = await find()
        if existing is None:
            raise
        return existing
    return candidate


async def _recipes_others_depend_on(session: AsyncSession, user_id: uuid.UUID) -> list[uuid.UUID]:
    """The user's recipes that someone else has cooked, saved or adapted."""
    cooked = (
        select(CookingSession.id)
        .join(RecipeVersion, RecipeVersion.id == CookingSession.recipe_version_id)
        .where(RecipeVersion.recipe_id == Recipe.id, CookingSession.owner_user_id != user_id)
    )
    saved = select(Save.id).where(Save.recipe_id == Recipe.id, Save.user_id != user_id)
    adapted = select(RecipeVariation.id).where(
        RecipeVariation.recipe_id == Recipe.id, RecipeVariation.owner_user_id != user_id
    )
    stmt = (
        select(Recipe.id)
        .where(
            Recipe.owner_user_id == user_id,
            or_(cooked.exists(), saved.exists(), adapted.exists()),
        )
        .with_for_update(of=Recipe)
    )
    return list((await session.execute(stmt)).scalars().all())


async def delete_user_data(session: AsyncSession, user_id: uuid.UUID) -> int:
    """Delete the account row and everything it owns. Returns how many recipes were kept
    under the anonymous account. The caller commits."""
    locked = await session.scalar(select(User.id).where(User.id == user_id).with_for_update())
    if locked is None:
        return 0
    email = await session.scalar(select(User.email).where(User.id == user_id))
    await session.execute(text("SET LOCAL umma.unlock_versions = 'on'"))

    kept = await _recipes_others_depend_on(session, user_id)
    if kept:
        former = await _former_creator(session)
        # The creator's open edit drafts of a kept recipe go with the account (cascade).
        await session.execute(
            delete(RecipeDraft).where(
                RecipeDraft.owner_user_id == user_id, RecipeDraft.recipe_id.in_(kept)
            )
        )
        await session.execute(
            update(Recipe).where(Recipe.id.in_(kept)).values(owner_user_id=former.id)
        )
    # The user's own sessions first: versions are RESTRICT-pinned by sessions, and a cascade
    # does not promise to remove the sessions before the versions.
    await session.execute(delete(CookingSession).where(CookingSession.owner_user_id == user_id))
    if email:
        await session.execute(delete(DevLoginChallenge).where(DevLoginChallenge.email == email))
    await session.execute(delete(User).where(User.id == user_id))
    return len(kept)


async def delete_account(
    session: AsyncSession,
    settings: Settings,
    user: User,
    apple_client: AppleTokenClient | None,
) -> None:
    user_id, provider = user.id, user.auth_provider
    refresh_token = await apple_tokens.load_refresh_token(session, settings, user_id)
    kept = await delete_user_data(session, user_id)
    await session.commit()

    revoke = "not_apple"
    if provider == "apple":
        if refresh_token is None:
            revoke = "skipped_no_token"
        elif apple_client is None:
            revoke = "skipped_not_configured"
        else:
            revoke = "revoked" if await apple_client.revoke(refresh_token) else "failed"
    level = logging.WARNING if revoke.startswith(("skipped", "failed")) else logging.INFO
    log.log(
        level,
        "account deleted",
        extra={"user_id": str(user_id), "apple_revoke": revoke, "recipes_kept": kept},
    )
