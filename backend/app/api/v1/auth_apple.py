"""Sign in with Apple (brief 010). This router is only mounted when ``AUTH_MODE=apple``."""

from __future__ import annotations

from fastapi import APIRouter, Request

from app.core.errors import NotFound
from app.core.security import SettingsDep, create_access_token
from app.db.engine import DbSession
from app.domains.users import service as users_service
from app.domains.users.apple import PROVIDER_NAME, AppleIdentityVerifier
from app.domains.users.schemas import AppleSignInRequest, TokenResponse, UserOut

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/apple", response_model=TokenResponse)
async def sign_in_with_apple(
    payload: AppleSignInRequest, request: Request, session: DbSession, settings: SettingsDep
) -> TokenResponse:
    verifier: AppleIdentityVerifier | None = getattr(request.app.state, "apple_verifier", None)
    if settings.auth_mode != "apple" or verifier is None:
        # Backstop: the router is only mounted in apple mode (see create_app).
        raise NotFound("Not found")
    identity = await verifier.verify(payload.identity_token, raw_nonce=payload.nonce)
    user = await users_service.get_or_create_by_subject(
        session,
        auth_provider=PROVIDER_NAME,
        subject=identity.subject,
        email=identity.email,
        display_name=payload.display_name,
    )
    await session.commit()
    token = create_access_token(settings, user.id)
    return TokenResponse(access_token=token, user=UserOut.from_model(user, settings))
