"""Cover photos of the finished dish (brief 019, DECISIONS #31).

* The phone re-encodes the photo as JPEG (dropping EXIF) and PUTs it to a presigned URL; the
  server then checks the object really is there, within the declared size and starts with the
  JPEG magic bytes. Anything else is ``rejected`` and its object queued for deletion.
* A draft holds at most one confirmed cover (``recipe_drafts.cover_media_id``). Replacing or
  removing it deletes the old one unless a published version already uses it.
* Abuse caps: at most ``cover_max_pending_uploads`` unconfirmed covers per user, and the bytes
  count toward the shared monthly upload budget.
"""

from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime, timedelta
from typing import Literal

from botocore.exceptions import BotoCoreError, ClientError
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.errors import (
    AppError,
    ImageTooLarge,
    ImageTypeUnsupported,
    NotFound,
    StateConflict,
    StorageUnavailable,
    UploadIncomplete,
    UploadLimit,
    UploadRejected,
)
from app.db.models import DraftStatus, MediaKind, RecipeDraft, RecipeMedia, User
from app.domains.media.service import charge_upload_bytes, enqueue_deletions, lock_user_video
from app.media.storage import ObjectStorage, cover_key

log = logging.getLogger("umma.media.covers")

COVER_TYPE = "image/jpeg"
JPEG_MAGIC = b"\xff\xd8\xff"


class CoverIntentIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    content_type: str = Field(max_length=100)
    size_bytes: int = Field(ge=1)


class CoverIntentOut(BaseModel):
    media_id: uuid.UUID
    upload_url: str
    method: Literal["PUT"] = "PUT"
    headers: dict[str, str]
    expires_at: datetime
    max_bytes: int


async def _open_draft(session: AsyncSession, user: User, draft_id: uuid.UUID) -> RecipeDraft:
    """The caller's draft, locked; another creator's draft is the same 404 as a missing one."""
    row = (
        await session.execute(
            select(RecipeDraft)
            .where(RecipeDraft.id == draft_id, RecipeDraft.owner_user_id == user.id)
            .with_for_update()
        )
    ).scalar_one_or_none()
    if row is None:
        raise NotFound("Draft not found")
    if row.status == DraftStatus.PUBLISHED:
        raise StateConflict(
            "This draft was published and is read-only; edit the recipe to start a new draft"
        )
    return row


async def create_intent(
    session: AsyncSession,
    user: User,
    draft_id: uuid.UUID,
    body: CoverIntentIn,
    *,
    settings: Settings,
    storage: ObjectStorage,
) -> CoverIntentOut:
    content_type = body.content_type.split(";")[0].strip().lower()
    if content_type != COVER_TYPE:
        raise ImageTypeUnsupported("Cover photos must be JPEG images.")
    if body.size_bytes > settings.cover_max_bytes:
        mb = settings.cover_max_bytes // (1024 * 1024)
        raise ImageTooLarge(f"Cover photos can be at most {mb} MB.")
    draft = await _open_draft(session, user, draft_id)
    await lock_user_video(session, user.id)
    pending = await session.scalar(
        select(func.count(RecipeMedia.id)).where(
            RecipeMedia.owner_user_id == user.id,
            RecipeMedia.media_kind == MediaKind.COVER_IMAGE,
            RecipeMedia.status == "pending",
        )
    )
    if int(pending or 0) >= settings.cover_max_pending_uploads:
        raise UploadLimit(
            "Finish your other photo uploads first.",
            extra={"details": {"pending": int(pending or 0)}},
        )
    now = datetime.now(UTC)
    await charge_upload_bytes(session, user, body.size_bytes, settings=settings, now=now)
    media_id = uuid.uuid4()
    key = cover_key(user.id, media_id)
    session.add(
        RecipeMedia(
            id=media_id,
            owner_user_id=user.id,
            draft_id=draft.id,
            media_kind=MediaKind.COVER_IMAGE,
            status="pending",
            storage_key=key,
            mime_type=COVER_TYPE,
            size_bytes=body.size_bytes,
        )
    )
    await session.flush()
    ttl = settings.storage_upload_url_ttl_seconds
    url = storage.presign_put(
        key, content_type=COVER_TYPE, content_length=body.size_bytes, expires_in=ttl
    )
    return CoverIntentOut(
        media_id=media_id,
        upload_url=url,
        headers={"Content-Type": COVER_TYPE, "Content-Length": str(body.size_bytes)},
        expires_at=now + timedelta(seconds=ttl),
        max_bytes=settings.cover_max_bytes,
    )


async def _check_object(
    row: RecipeMedia, *, settings: Settings, storage: ObjectStorage
) -> str | None:
    """``None`` when the object passes; otherwise why it is rejected. Raises when the object is
    simply not there yet (the phone may retry) or storage is down."""
    try:
        info = await storage.head(row.storage_key)
        if info is None:
            raise UploadIncomplete("The photo hasn't finished uploading yet.")
        if info.size_bytes > settings.cover_max_bytes or info.size_bytes != row.size_bytes:
            return "The uploaded photo doesn't match the declared size."
        if info.content_type and info.content_type.split(";")[0].strip().lower() != COVER_TYPE:
            return "The uploaded file isn't a JPEG image."
        head = await storage.read_prefix(row.storage_key, len(JPEG_MAGIC))
    except (BotoCoreError, ClientError) as exc:
        log.warning("storage check failed", extra={"error_type": type(exc).__name__})
        raise StorageUnavailable("Storage is unavailable right now; try again") from exc
    if head != JPEG_MAGIC:
        return "The uploaded file isn't a JPEG image."
    return None


async def confirm(
    session: AsyncSession,
    user: User,
    draft_id: uuid.UUID,
    media_id: uuid.UUID,
    *,
    settings: Settings,
    storage: ObjectStorage,
) -> tuple[RecipeDraft, AppError | None]:
    """Check the uploaded object and make it the draft's cover. Idempotent once ready.

    A failed check returns the error instead of raising it, so the caller can commit the
    ``rejected`` status before answering."""
    draft = await _open_draft(session, user, draft_id)
    row = (
        await session.execute(
            select(RecipeMedia)
            .where(
                RecipeMedia.id == media_id,
                RecipeMedia.owner_user_id == user.id,
                RecipeMedia.media_kind == MediaKind.COVER_IMAGE,
                RecipeMedia.draft_id == draft.id,
            )
            .with_for_update()
        )
    ).scalar_one_or_none()
    if row is None:
        raise NotFound("Media not found")
    if row.status == "ready":
        return draft, None
    if row.status != "pending":
        raise StateConflict("This photo was rejected; upload it again")
    reason = await _check_object(row, settings=settings, storage=storage)
    if reason is not None:
        row.status = "rejected"
        enqueue_deletions(session, [row.storage_key])
        await session.flush()
        return draft, UploadRejected(reason)
    row.status = "ready"
    row.uploaded_at = datetime.now(UTC)
    previous = draft.cover_media_id
    draft.cover_media_id = row.id
    await session.flush()
    if previous is not None and previous != row.id:
        await _discard_unpublished(session, [previous])
    await session.refresh(draft)  # server-side updated_at
    return draft, None


async def remove(session: AsyncSession, user: User, draft_id: uuid.UUID) -> RecipeDraft:
    """Clear the draft's cover; idempotent. A published version keeps its own cover."""
    draft = await _open_draft(session, user, draft_id)
    previous = draft.cover_media_id
    draft.cover_media_id = None
    await session.flush()
    if previous is not None:
        await _discard_unpublished(session, [previous])
    await session.refresh(draft)  # server-side updated_at
    return draft


async def _discard_unpublished(session: AsyncSession, ids: list[uuid.UUID]) -> None:
    """Delete these covers unless a published version uses them (the trigger queues objects)."""
    await session.execute(
        delete(RecipeMedia).where(
            RecipeMedia.id.in_(ids),
            RecipeMedia.media_kind == MediaKind.COVER_IMAGE,
            RecipeMedia.version_id.is_(None),
        )
    )


# --- Draft lifecycle hook (called from domains.recipes.drafts) -------------------------------


async def discard_for_draft(
    session: AsyncSession, draft_id: uuid.UUID, *, keep: uuid.UUID | None = None
) -> None:
    stmt = delete(RecipeMedia).where(
        RecipeMedia.draft_id == draft_id,
        RecipeMedia.media_kind == MediaKind.COVER_IMAGE,
        RecipeMedia.version_id.is_(None),
    )
    if keep is not None:
        stmt = stmt.where(RecipeMedia.id != keep)
    await session.execute(stmt)
