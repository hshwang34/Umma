"""Sign in with Google (brief 010, DECISIONS #33). Mounted only when ``AUTH_MODE=apple`` and
``GOOGLE_IOS_CLIENT_ID`` is set."""

from __future__ import annotations

from fastapi import APIRouter, Request

from app.core.errors import NotFound
from app.core.security import SettingsDep, create_access_token
from app.db.engine import DbSession
from app.domains.users import service as users_service
from app.domains.users.google import PROVIDER_NAME, GoogleIdentityVerifier
from app.domains.users.schemas import GoogleSignInRequest, TokenResponse, UserOut

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/google", response_model=TokenResponse)
async def sign_in_with_google(
    payload: GoogleSignInRequest, request: Request, session: DbSession, settings: SettingsDep
) -> TokenResponse:
    verifier: GoogleIdentityVerifier | None = getattr(request.app.state, "google_verifier", None)
    if settings.auth_mode != "apple" or verifier is None:
        # Backstop: the router is only mounted when Google sign-in is configured (create_app).
        raise NotFound("Not found")
    identity = await verifier.verify(payload.id_token, raw_nonce=payload.nonce)
    user = await users_service.get_or_create_by_subject(
        session,
        auth_provider=PROVIDER_NAME,
        subject=identity.subject,
        email=identity.email,
        display_name=identity.name,
    )
    await session.commit()
    token = create_access_token(settings, user.id)
    return TokenResponse(access_token=token, user=UserOut.from_model(user, settings))
