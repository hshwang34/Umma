"""``POST /v1/voice/speak`` (brief 012 PR 2) with a fake text-to-speech vendor. No spend."""

from __future__ import annotations

import asyncio
import contextlib
import uuid
from collections.abc import AsyncIterator
from decimal import Decimal
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.requests import ClientDisconnect

from app.ai.budget import CostGuard
from app.core.config import Settings
from app.db.engine import make_sessionmaker
from app.db.models import AIUsage, User
from app.main import create_app
from app.voice.speak import SpeakLimiter, speak
from tests.conftest import bearer
from tests.voice_fakes import FakeTTS

SAFETY = "Chicken is safe at 165°F (74°C).  Check the thickest part — don't guess."


async def _client(settings: Settings, tts: FakeTTS | None, **overrides: Any) -> Any:
    app = create_app(settings.model_copy(update={"paid_voice_enabled": True, **overrides}))
    app.state.voice_tts = tts
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


@pytest.fixture
def tts() -> FakeTTS:
    return FakeTTS()


@pytest.fixture
async def client(
    settings: Settings, tts: FakeTTS, clean_tables: None
) -> AsyncIterator[AsyncClient]:
    async for c in _client(settings, tts):
        yield c


async def test_streams_pcm_and_passes_safety_wording_verbatim(
    client: AsyncClient, tts: FakeTTS, db_session: AsyncSession
) -> None:
    headers = await bearer(client, "s@x.com")
    response = await client.post("/v1/voice/speak", json={"text": SAFETY}, headers=headers)
    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/pcm"
    assert response.headers["x-audio-sample-rate"] == "24000"
    assert response.headers["x-audio-encoding"] == "pcm_s16le"
    assert len(response.content) == 3 * 960
    assert tts.texts == [SAFETY]
    row = (await db_session.execute(select(AIUsage))).scalar_one()
    assert (row.capability, row.status, row.outcome) == ("voice_tts", "settled", "ok")
    assert row.output_tokens == len(SAFETY)
    assert row.cost_usd == Decimal(len(SAFETY)) * Decimal("0.04") / 1000


async def test_vendor_refusal_is_unavailable_and_not_billed(
    settings: Settings, clean_tables: None, db_session: AsyncSession
) -> None:
    async for client in _client(settings, FakeTTS(reject_status=401)):
        headers = await bearer(client, "r@x.com")
        response = await client.post("/v1/voice/speak", json={"text": "Hi"}, headers=headers)
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "VOICE_UNAVAILABLE"
    row = (await db_session.execute(select(AIUsage))).scalar_one()
    assert row.cost_usd == 0 and row.status == "settled"


async def test_free_missing_key_and_auth(settings: Settings, clean_tables: None) -> None:
    async for client in _client(settings, FakeTTS(), default_entitlement="free"):
        headers = await bearer(client, "f@x.com")
        response = await client.post("/v1/voice/speak", json={"text": "Hi"}, headers=headers)
        assert response.status_code == 403
        assert response.json()["error"]["code"] == "VOICE_NOT_ENTITLED"
        assert (await client.post("/v1/voice/speak", json={"text": "Hi"})).status_code == 401
    async for client in _client(settings, None):
        headers = await bearer(client, "n@x.com")
        response = await client.post("/v1/voice/speak", json={"text": "Hi"}, headers=headers)
        assert response.json()["error"]["code"] == "VOICE_UNAVAILABLE"


async def test_paid_voice_off_is_unavailable_even_with_a_key(
    settings: Settings, tts: FakeTTS, clean_tables: None
) -> None:
    async for client in _client(settings, tts, paid_voice_enabled=False):
        headers = await bearer(client, "off@x.com")
        response = await client.post("/v1/voice/speak", json={"text": "Hi"}, headers=headers)
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "VOICE_UNAVAILABLE"
    assert tts.texts == []


async def test_over_the_cap_is_ai_resting(
    settings: Settings, tts: FakeTTS, clean_tables: None
) -> None:
    async for client in _client(settings, tts, ai_user_daily_cap_usd=0.0):
        headers = await bearer(client, "c@x.com")
        response = await client.post("/v1/voice/speak", json={"text": "Hi"}, headers=headers)
    assert response.status_code == 503
    error = response.json()["error"]
    assert error["code"] == "AI_RESTING" and error["reason"] == "user_daily_cap"
    assert tts.texts == []


async def test_length_and_rate_limits(client: AsyncClient, tts: FakeTTS) -> None:
    headers = await bearer(client, "l@x.com")
    long = await client.post("/v1/voice/speak", json={"text": "x" * 601}, headers=headers)
    assert long.status_code == 413
    empty = await client.post("/v1/voice/speak", json={"text": ""}, headers=headers)
    assert empty.status_code == 422
    for _ in range(20):
        ok = await client.post("/v1/voice/speak", json={"text": "Next."}, headers=headers)
        assert ok.status_code == 200
    limited = await client.post("/v1/voice/speak", json={"text": "Next."}, headers=headers)
    assert limited.status_code == 429
    assert len(tts.texts) == 20


def test_speak_limiter_window() -> None:
    limiter = SpeakLimiter()
    import uuid

    user = uuid.uuid4()
    assert limiter.allow(user, 2, now=0) and limiter.allow(user, 2, now=1)
    assert not limiter.allow(user, 2, now=59)
    assert limiter.allow(user, 2, now=60.5)


async def _settled_rows(db_session: AsyncSession) -> list[AIUsage]:
    db_session.expire_all()
    return list((await db_session.execute(select(AIUsage))).scalars().all())


async def _run_response(response: Any, *, fail_after: int) -> None:
    """Drive the ASGI response with a client that goes away after ``fail_after`` sends."""
    sent = 0

    async def receive() -> dict[str, Any]:
        await asyncio.sleep(3600)
        return {"type": "http.disconnect"}

    async def send(message: dict[str, Any]) -> None:
        nonlocal sent
        if sent >= fail_after:
            raise OSError("client went away")
        sent += 1

    scope = {"type": "http", "asgi": {"spec_version": "2.4"}}
    with contextlib.suppress(OSError, ClientDisconnect):
        await response(scope, receive, send)


async def test_client_gone_before_the_body_settles_and_closes(
    engine: Any, db_session: AsyncSession, settings: Settings
) -> None:
    guard = CostGuard(make_sessionmaker(engine), settings)
    user_id = await _user_id(db_session)
    tts = FakeTTS()
    response = await speak(tts, guard, user_id, "Never heard.")
    await _run_response(response, fail_after=0)  # the body is never iterated
    assert tts.closed == 1
    rows = await _settled_rows(db_session)
    assert [(r.status, r.output_tokens) for r in rows] == [("settled", len("Never heard."))]


async def test_speak_cut_off_mid_stream_settles_once(
    engine: Any, db_session: AsyncSession, settings: Settings
) -> None:
    guard = CostGuard(make_sessionmaker(engine), settings)
    tts = FakeTTS(chunks=5)
    response = await speak(tts, guard, await _user_id(db_session), "Barge in on me.")
    await _run_response(response, fail_after=2)  # start + one chunk, then the client leaves
    assert tts.closed == 1
    rows = await _settled_rows(db_session)
    assert [(r.status, r.outcome) for r in rows] == [("settled", "error")]
    assert rows[0].cost_usd == Decimal(len("Barge in on me.")) * Decimal("0.04") / 1000


async def _user_id(db_session: AsyncSession) -> uuid.UUID:
    tag = uuid.uuid4().hex
    user = User(email=f"{tag}@x.com", display_name="C", auth_provider="dev", auth_subject=tag)
    db_session.add(user)
    await db_session.commit()
    return user.id
