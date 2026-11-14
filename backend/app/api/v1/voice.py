"""Paid server voice routes (brief 012 PR 2). Keys stay here; the phone never sees them."""

from __future__ import annotations

import uuid
from collections.abc import Awaitable, Callable
from typing import Any

from fastapi import APIRouter, WebSocket
from fastapi.responses import JSONResponse

from app.core.config import Settings
from app.core.errors import AppError
from app.core.security import verify_access_token_claims
from app.db.models import User
from app.domains.users import service as users_service
from app.domains.users.schemas import entitlement_for
from app.voice.stream import (
    CLOSE_LIMIT,
    CLOSE_NOT_ENTITLED,
    CLOSE_UNAUTHORIZED,
    CLOSE_UNAVAILABLE,
    StreamLimiter,
    VoiceStreamSession,
    error_message,
    refusal,
    send_terminal,
)

router = APIRouter(tags=["voice"])

NOT_ENTITLED_MESSAGE = "Server voice is part of Paid. Voice runs on this iPhone."
UNAVAILABLE_MESSAGE = "Server voice is unavailable. Voice runs on this iPhone."


async def _ws_user(ws: WebSocket, settings: Settings) -> tuple[User, int] | None:
    """Bearer JWT from the handshake's Authorization header (never a query string), with its
    ``exp`` so the stream ends when the token does."""
    scheme, _, token = (ws.headers.get("authorization") or "").partition(" ")
    if scheme.lower() != "bearer" or not token:
        return None
    try:
        user_id, expires_at = verify_access_token_claims(settings, token)
    except AppError:
        return None
    async with ws.app.state.sessionmaker() as session:
        user = await users_service.get_by_id(session, user_id)
    return (user, expires_at) if user is not None else None


async def _refuse_handshake(ws: WebSocket) -> None:
    """No valid sign-in: refuse before accepting, as HTTP 401 where the server supports it
    (uvicorn does), else a policy-violation close. Nothing unauthenticated gets a socket."""
    body = {"error": {"code": "UNAUTHORIZED", "message": "Sign in again to use server voice."}}
    try:
        await ws.send_denial_response(JSONResponse(body, status_code=401))
    except RuntimeError:
        await ws.close(code=1008)


def _recheck(ws: WebSocket, user_id: uuid.UUID) -> Callable[[], Awaitable[Any]]:
    async def check() -> Any:
        state = ws.app.state
        async with state.sessionmaker() as session:
            user = await users_service.get_by_id(session, user_id)
        if user is None:
            message = error_message("UNAUTHORIZED", "Sign in again to use server voice.")
            return refusal(message, CLOSE_UNAUTHORIZED)
        if entitlement_for(user, state.settings) != "paid":
            message = error_message("VOICE_NOT_ENTITLED", NOT_ENTITLED_MESSAGE)
            return refusal(message, CLOSE_NOT_ENTITLED)
        return None

    return check


@router.websocket("/voice/stream")
async def voice_stream(ws: WebSocket) -> None:
    state = ws.app.state
    settings: Settings = state.settings
    signed_in = await _ws_user(ws, settings)
    if signed_in is None:
        await _refuse_handshake(ws)
        return
    user, expires_at = signed_in
    await ws.accept()
    if entitlement_for(user, settings) != "paid":
        message = error_message("VOICE_NOT_ENTITLED", NOT_ENTITLED_MESSAGE)
        await send_terminal(ws, message, CLOSE_NOT_ENTITLED)
        return
    stt = state.voice_stt
    # Dark until the PM's go (DECISIONS #26), even with a key set: the phone falls back.
    if stt is None or not settings.paid_voice_enabled:
        await send_terminal(
            ws, error_message("VOICE_UNAVAILABLE", UNAVAILABLE_MESSAGE), CLOSE_UNAVAILABLE
        )
        return
    limiter: StreamLimiter = state.voice_streams
    if not limiter.acquire(user.id, settings.voice_max_streams_per_user):
        message = error_message("VOICE_STREAM_LIMIT", "Server voice is already on elsewhere.")
        await send_terminal(ws, message, CLOSE_LIMIT)
        return
    try:
        session = VoiceStreamSession(
            ws,
            settings,
            stt,
            state.cost_guard,
            user.id,
            token_expires_at=float(expires_at),
            recheck=_recheck(ws, user.id),
        )
        await session.run()
    finally:
        limiter.release(user.id)
