"""Review login for Apple's Beta App Review (brief 010 PR 3).

App Review cannot use Sign in with Apple with a personal Apple account, so production offers
one extra way in: ``POST /v1/auth/review`` with a secret code from ``REVIEW_LOGIN_CODE``.

* The router is mounted only when the secret is set. Unset (the default), the path is a 404.
* The code is compared in constant time and is never logged or echoed.
* Every caller signs in as the same single account (``review`` / ``app-review``). It is an
  ordinary user: it owns only what it creates and sees other people's data exactly as any
  other account does, which is not at all.
* Attempts are limited per IP and across all callers (``app/core/ratelimit.py``), on top of
  the sign-in limit, so the code cannot be guessed at speed. A wrong code and a rate limit
  are the only two failures, and neither says anything about the code.
"""

from __future__ import annotations

import hashlib
import hmac

from fastapi import APIRouter, Request
from pydantic import BaseModel, ConfigDict, Field

from app.core import ratelimit
from app.core.errors import NotFound, Unauthorized
from app.core.security import SettingsDep, create_access_token
from app.db.engine import DbSession
from app.domains.users import service as users_service
from app.domains.users.schemas import TokenResponse, UserOut

router = APIRouter(prefix="/auth", tags=["auth"])

PROVIDER_NAME = "review"
REVIEW_SUBJECT = "app-review"
REVIEW_DISPLAY_NAME = "App Review"
INVALID_MESSAGE = "Invalid review code"


class ReviewLoginRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: str = Field(min_length=1, max_length=256)


def _matches(provided: str, expected: str) -> bool:
    # Digests first, so the comparison is constant time whatever the lengths are.
    return hmac.compare_digest(
        hashlib.sha256(provided.encode("utf-8")).digest(),
        hashlib.sha256(expected.encode("utf-8")).digest(),
    )


@router.post("/review", response_model=TokenResponse)
async def review_login(
    payload: ReviewLoginRequest, request: Request, session: DbSession, settings: SettingsDep
) -> TokenResponse:
    if settings.review_login_code is None:
        # Backstop: the router is only mounted when the secret is set (see create_app).
        raise NotFound("Not found")
    ratelimit.check_review_login(request)
    if not _matches(payload.code, settings.review_login_code.get_secret_value()):
        raise Unauthorized(INVALID_MESSAGE)
    user = await users_service.get_or_create_by_subject(
        session,
        auth_provider=PROVIDER_NAME,
        subject=REVIEW_SUBJECT,
        email=None,
        display_name=REVIEW_DISPLAY_NAME,
    )
    await session.commit()
    token = create_access_token(settings, user.id)
    return TokenResponse(access_token=token, user=UserOut.from_model(user, settings))
