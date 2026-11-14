from __future__ import annotations

from fastapi import APIRouter, Depends

from app.api.v1 import (
    ai,
    capture,
    creators,
    drafts,
    extractions,
    feed,
    health,
    live_scans,
    me,
    media,
    pantry,
    receipts,
    recipes,
    sessions,
    shopping,
    substitutions,
    voice,
)
from app.core.ratelimit import limit_ip
from app.core.security import limit_costly
from app.media.signing import bind_media_signer

# Routers where every write spends money, storage or a provider call (brief 010). Single
# routes elsewhere are marked on the route. A new write route must be classified in
# tests/integration/test_rate_limits.py.
COSTLY = [Depends(limit_costly)]

router = APIRouter(prefix="/v1", dependencies=[Depends(limit_ip), Depends(bind_media_signer)])
router.include_router(health.router)
router.include_router(me.router)
router.include_router(creators.router)
router.include_router(feed.router)
router.include_router(drafts.router)  # before recipes: `/recipes/drafts` is not a recipe id
router.include_router(recipes.router)
router.include_router(recipes.versions_router)
router.include_router(
    live_scans.router, dependencies=COSTLY
)  # before pantry: `/pantry/live-scans` is not an item
router.include_router(receipts.router, dependencies=COSTLY)  # before pantry, like live scans
router.include_router(pantry.router)
router.include_router(shopping.router)
router.include_router(substitutions.router, dependencies=COSTLY)
router.include_router(sessions.router)
router.include_router(ai.router, dependencies=COSTLY)
router.include_router(media.router, dependencies=COSTLY)
router.include_router(extractions.router)
router.include_router(capture.router, dependencies=COSTLY)
router.include_router(voice.router)
