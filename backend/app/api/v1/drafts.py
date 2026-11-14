"""Creator drafts (REC-03/04). Owner only; anyone else's draft is a 404.

Mounted *before* the public ``/recipes/{recipe_id}`` route so ``/recipes/drafts`` is never
read as a recipe id.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, BackgroundTasks, Depends, Request, Response, status

from app.core.errors import NotFound
from app.core.security import CurrentUser, SettingsDep, limit_costly
from app.db.engine import DbSession
from app.domains.extraction import jobs
from app.domains.media import covers
from app.domains.media.service import media_id_or_404
from app.domains.recipes import drafts, stock_photos
from app.domains.recipes.draft_schemas import Draft, DraftList, DraftPatch, PublishResult

router = APIRouter(prefix="/recipes/drafts", tags=["drafts"])


def _draft_id(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise NotFound("Draft not found") from exc


@router.post("", response_model=Draft, status_code=status.HTTP_201_CREATED)
async def create_draft(
    session: DbSession, user: CurrentUser, body: DraftPatch | None = None
) -> Draft:
    row = await drafts.create_draft(session, user, body or DraftPatch())
    return drafts.to_draft(row)


@router.get("", response_model=DraftList)
async def list_drafts(session: DbSession, user: CurrentUser) -> DraftList:
    rows = await drafts.list_drafts(session, user)
    return DraftList(items=[drafts.to_summary(r) for r in rows])


@router.get("/{draft_id}", response_model=Draft)
async def get_draft(draft_id: str, session: DbSession, user: CurrentUser) -> Draft:
    return drafts.to_draft(await drafts.get_draft_row(session, user, _draft_id(draft_id)))


@router.patch("/{draft_id}", response_model=Draft)
async def patch_draft(
    draft_id: str, body: DraftPatch, session: DbSession, user: CurrentUser
) -> Draft:
    return drafts.to_draft(await drafts.patch_draft(session, user, _draft_id(draft_id), body))


@router.delete("/{draft_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_draft(draft_id: str, session: DbSession, user: CurrentUser) -> Response:
    await drafts.delete_draft(session, user, _draft_id(draft_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/{draft_id}/publish",
    response_model=PublishResult,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(limit_costly)],
)
async def publish_draft(
    draft_id: str,
    request: Request,
    background: BackgroundTasks,
    session: DbSession,
    user: CurrentUser,
    settings: SettingsDep,
) -> PublishResult:
    result = await drafts.publish(
        session, user, _draft_id(draft_id), share_url_base=settings.share_url_base
    )
    client = request.app.state.stock_photos
    if result.version_number == 1 and client is not None:
        # Brief 019: look up a stock photo after the publish is committed and the response
        # sent. Best effort; it skips recipes with a creator photo and never raises.
        await session.commit()
        background.add_task(
            stock_photos.fill_recipe, request.app.state.sessionmaker, client, result.recipe_id
        )
    return result


@router.post(
    "/{draft_id}/steps/{step_id}/trim",
    dependencies=[Depends(limit_costly)],
    response_model=jobs.JobOut,
    status_code=status.HTTP_202_ACCEPTED,
)
async def trim_step_clip(
    draft_id: str, step_id: str, body: jobs.TrimIn, session: DbSession, user: CurrentUser
) -> jobs.JobOut:
    """Re-render this step's clip from the source video (brief 008)."""
    job = await jobs.request_trim(session, user, _draft_id(draft_id), step_id, body)
    return jobs.to_job_out(job)


# --- Cover photo (brief 019) ----------------------------------------------------------------


@router.post(
    "/{draft_id}/cover/upload-intents",
    dependencies=[Depends(limit_costly)],
    response_model=covers.CoverIntentOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_cover_intent(
    draft_id: str,
    body: covers.CoverIntentIn,
    request: Request,
    session: DbSession,
    user: CurrentUser,
    settings: SettingsDep,
) -> covers.CoverIntentOut:
    """A presigned PUT for one JPEG cover photo of this draft."""
    return await covers.create_intent(
        session,
        user,
        _draft_id(draft_id),
        body,
        settings=settings,
        storage=request.app.state.storage,
    )


@router.post(
    "/{draft_id}/cover/{media_id}/uploaded",
    response_model=Draft,
    dependencies=[Depends(limit_costly)],
)
async def confirm_cover(
    draft_id: str,
    media_id: str,
    request: Request,
    session: DbSession,
    user: CurrentUser,
    settings: SettingsDep,
) -> Draft:
    """Check the uploaded photo and make it the draft's cover (replacing any earlier one)."""
    row, rejected = await covers.confirm(
        session,
        user,
        _draft_id(draft_id),
        media_id_or_404(media_id),
        settings=settings,
        storage=request.app.state.storage,
    )
    if rejected is not None:
        await session.commit()  # keep the ``rejected`` status and the queued object delete
        raise rejected
    return drafts.to_draft(row)


@router.delete("/{draft_id}/cover", response_model=Draft)
async def remove_cover(draft_id: str, session: DbSession, user: CurrentUser) -> Draft:
    """Remove the draft's cover photo. Idempotent; published versions keep theirs."""
    return drafts.to_draft(await covers.remove(session, user, _draft_id(draft_id)))
