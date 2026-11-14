"""Sign in with Apple (brief 010). This router is only mounted when ``AUTH_MODE=apple``."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Request

from app.core.errors import NotFound
from app.core.security import SettingsDep, create_access_token
from app.db.engine import DbSession
from app.domains.users import apple_tokens
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
    if payload.authorization_code:
        await _store_refresh_token(request, session, settings, user.id, payload.authorization_code)
    token = create_access_token(settings, user.id)
    return TokenResponse(access_token=token, user=UserOut.from_model(user, settings))


async def _store_refresh_token(
    request: Request,
    session: DbSession,
    settings: SettingsDep,
    user_id: uuid.UUID,
    authorization_code: str,
) -> None:
    """Exchange the one-time code for a refresh token and keep it (encrypted) for the revoke
    at account deletion. Best effort: sign-in never fails because of it."""
    client: apple_tokens.AppleTokenClient | None = getattr(
        request.app.state, "apple_token_client", None
    )
    if client is None:
        return
    refresh_token = await client.exchange_code(authorization_code)
    if refresh_token is None:
        return
    await apple_tokens.store_refresh_token(session, settings, user_id, refresh_token)
    await session.commit()
