"""``WS /v1/voice/stream`` (brief 012 PR 2) with a fake speech-to-text vendor. No spend."""

from __future__ import annotations

import json
import time
import uuid
import warnings
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.security import create_access_token
from app.db.models import AIUsage, User
from app.main import create_app
from app.voice.stt import SpeechStarted, Transcript, UtteranceEnd
from tests.voice_fakes import FakeSTT

with warnings.catch_warnings():
    # Starlette's WebSocket test client still runs on httpx; the deprecation is about that.
    warnings.simplefilter("ignore")
    from starlette.testclient import TestClient, WebSocketDenialResponse

FRAME = b"\x00\x00" * 3200  # 200 ms of 16 kHz s16le mono


def _sign_in(client: TestClient, email: str) -> dict[str, str]:
    challenge = client.post("/v1/auth/dev-login", json={"email": email}).json()
    body = {"challenge_id": challenge["challenge_id"], "code": challenge["code"]}
    token = client.post("/v1/auth/dev-login/verify", json=body).json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


def _open(client: TestClient, email: str) -> Any:
    return client.websocket_connect("/v1/voice/stream", headers=_sign_in(client, email))


@pytest.fixture
def stt() -> FakeSTT:
    return FakeSTT()


def _client(settings: Settings, stt: FakeSTT | None, **overrides: Any) -> Iterator[TestClient]:
    app = create_app(settings.model_copy(update={"paid_voice_enabled": True, **overrides}))
    app.state.voice_stt = stt
    with TestClient(app) as client:
        yield client


@pytest.fixture
def client(settings: Settings, stt: FakeSTT, clean_tables: None) -> Iterator[TestClient]:
    yield from _client(settings, stt)


def _terminal(ws: Any) -> dict[str, Any]:
    while True:
        message = json.loads(ws.receive_text())
        if message["type"] in {"error", "ai_resting", "closed"}:
            return message


def _drain_terminal(ws: Any) -> tuple[list[str], dict[str, Any]]:
    """Final transcript texts received before the terminal message, and that message."""
    texts: list[str] = []
    while True:
        message = json.loads(ws.receive_text())
        if message["type"] == "transcript" and message["is_final"]:
            texts.append(message["text"])
        if message["type"] in {"error", "ai_resting", "closed"}:
            return texts, message


def _portal(client: TestClient) -> Any:
    return client.portal  # type: ignore[attr-defined]


def test_streams_transcripts_and_turn_events(client: TestClient, stt: FakeSTT) -> None:
    stt.script = [
        SpeechStarted(at_ms=40),
        Transcript("next", False, False, 60, 300),
        Transcript("Next step.", True, True, 60, 520),
        UtteranceEnd(last_word_end_ms=520),
    ]
    with _open(client, "a@x.com") as ws:
        ready = ws.receive_json()
        assert ready["type"] == "ready" and ready["sample_rate"] == 16_000
        got = [ws.receive_json() for _ in range(4)]
        ws.send_bytes(FRAME)
        ws.send_text(json.dumps({"type": "finalize"}))
        ws.send_text(json.dumps({"type": "stop"}))
        assert _terminal(ws) == {"type": "closed", "reason": "client_stop"}
    assert [m["type"] for m in got] == [
        "speech_started",
        "transcript",
        "transcript",
        "utterance_end",
    ]
    assert got[2] == {
        "type": "transcript",
        "text": "Next step.",
        "is_final": True,
        "speech_final": True,
        "start_ms": 60,
        "end_ms": 520,
    }
    stream = stt.streams[0]
    assert bytes(stream.audio) == FRAME and stream.finalize_count == 1
    assert stt.closed_count == 1


async def test_audio_is_metered_per_second(
    client: TestClient, stt: FakeSTT, db_session: AsyncSession
) -> None:
    with _open(client, "m@x.com") as ws:
        ws.receive_json()
        for _ in range(5):
            ws.send_bytes(FRAME)
        ws.send_text(json.dumps({"type": "stop"}))
        _terminal(ws)
    rows = (await db_session.execute(select(AIUsage))).scalars().all()
    assert [(r.capability, r.status, r.input_tokens) for r in rows] == [
        ("voice_stt", "settled", 1000)
    ]
    assert rows[0].model == "deepgram/nova-3"


def test_no_token_is_refused_before_the_socket_opens(client: TestClient, stt: FakeSTT) -> None:
    for headers in ({}, {"Authorization": "Bearer not-a-jwt"}):
        with pytest.raises(WebSocketDenialResponse) as denied:
            with client.websocket_connect("/v1/voice/stream", headers=headers):
                pass
        assert denied.value.status_code == 401
        assert denied.value.json()["error"]["code"] == "UNAUTHORIZED"
    assert stt.open_count == 0


def test_free_entitlement_gets_a_clear_refusal(
    settings: Settings, stt: FakeSTT, clean_tables: None
) -> None:
    for client in _client(settings, stt, default_entitlement="free"):
        with client.websocket_connect(
            "/v1/voice/stream", headers=_sign_in(client, "f@x.com")
        ) as ws:
            message = ws.receive_json()
    assert message["code"] == "VOICE_NOT_ENTITLED"
    assert "this iPhone" in message["message"]
    assert stt.open_count == 0


def test_missing_key_or_vendor_down_is_unavailable(settings: Settings, clean_tables: None) -> None:
    for client in _client(settings, None):
        with client.websocket_connect(
            "/v1/voice/stream", headers=_sign_in(client, "n@x.com")
        ) as ws:
            assert ws.receive_json()["code"] == "VOICE_UNAVAILABLE"
    for client in _client(settings, FakeSTT(unavailable=True)):
        with client.websocket_connect(
            "/v1/voice/stream", headers=_sign_in(client, "d@x.com")
        ) as ws:
            assert ws.receive_json()["code"] == "VOICE_UNAVAILABLE"


def test_paid_voice_off_is_unavailable_even_with_a_key(
    settings: Settings, stt: FakeSTT, clean_tables: None
) -> None:
    for client in _client(settings, stt, paid_voice_enabled=False):
        with client.websocket_connect(
            "/v1/voice/stream", headers=_sign_in(client, "off@x.com")
        ) as ws:
            assert ws.receive_json()["code"] == "VOICE_UNAVAILABLE"
    assert stt.open_count == 0


def test_over_the_cap_says_ai_resting(settings: Settings, stt: FakeSTT, clean_tables: None) -> None:
    for client in _client(settings, stt, ai_user_daily_cap_usd=0.0):
        with client.websocket_connect(
            "/v1/voice/stream", headers=_sign_in(client, "c@x.com")
        ) as ws:
            message = ws.receive_json()
    assert message["type"] == "ai_resting" and message["reason"] == "user_daily_cap"
    assert stt.open_count == 0


def test_resting_mid_stream_when_the_next_block_is_refused(
    settings: Settings, stt: FakeSTT, clean_tables: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    # 1 s blocks at $0.000128: the third block would cross a $0.0003 day cap.
    monkeypatch.setattr("app.voice.metering.DEFAULT_BLOCK_MS", 1000)
    stt.final_on_finalize = "the last words"
    for client in _client(settings, stt, ai_user_daily_cap_usd=0.0003):
        with _open(client, "r@x.com") as ws:
            ws.receive_json()
            for _ in range(15):  # 3 s
                ws.send_bytes(FRAME)
            drained, message = _drain_terminal(ws)
    assert message["type"] == "ai_resting" and "this iPhone" in message["message"]
    assert len(stt.streams[0].audio) == 2 * 32_000  # nothing past the cap reached the vendor
    assert drained == ["the last words"], "words already sent are finalized before the close"


def test_frame_limits(client: TestClient) -> None:
    headers = _sign_in(client, "l@x.com")
    with client.websocket_connect("/v1/voice/stream", headers=headers) as ws:
        ws.receive_json()
        ws.send_bytes(b"\x00" * 16_002)
        assert _terminal(ws)["code"] == "BAD_FRAME"
    with client.websocket_connect("/v1/voice/stream", headers=headers) as ws:
        ws.receive_json()
        ws.send_bytes(b"\x00" * 641)  # odd: not 16-bit PCM
        assert _terminal(ws)["code"] == "BAD_FRAME"
    with client.websocket_connect("/v1/voice/stream", headers=headers) as ws:
        ws.receive_json()
        for _ in range(40):  # 8 s of audio within milliseconds of opening
            ws.send_bytes(b"\x00" * 16_000)
        assert _terminal(ws)["code"] == "AUDIO_TOO_FAST"


def test_one_stream_per_user(client: TestClient) -> None:
    headers = _sign_in(client, "two@x.com")
    with client.websocket_connect("/v1/voice/stream", headers=headers) as first:
        assert first.receive_json()["type"] == "ready"
        with client.websocket_connect("/v1/voice/stream", headers=headers) as second:
            assert second.receive_json()["code"] == "VOICE_STREAM_LIMIT"
        first.send_text(json.dumps({"type": "stop"}))
        _terminal(first)
    with client.websocket_connect("/v1/voice/stream", headers=headers) as again:
        assert again.receive_json()["type"] == "ready"


def test_idle_and_max_duration_close(settings: Settings, stt: FakeSTT, clean_tables: None) -> None:
    for client in _client(settings, stt, voice_idle_timeout_seconds=0.2):
        with _open(client, "i@x.com") as ws:
            ws.receive_json()
            assert _terminal(ws) == {"type": "closed", "reason": "idle"}
    for client in _client(settings, stt, voice_max_session_seconds=0.2):
        with _open(client, "j@x.com") as ws:
            ws.receive_json()
            assert _terminal(ws) == {"type": "closed", "reason": "max_duration"}


def test_vendor_dropping_mid_stream_tells_the_phone(client: TestClient, stt: FakeSTT) -> None:
    with _open(client, "u@x.com") as ws:
        ws.receive_json()
        stt.streams[0].emit(None)  # the vendor stream ended on its own
        assert _terminal(ws)["code"] == "VOICE_UPSTREAM_LOST"


def test_stop_finalizes_words_already_sent(client: TestClient, stt: FakeSTT) -> None:
    stt.final_on_finalize = "add the rice"
    with _open(client, "drain@x.com") as ws:
        ws.receive_json()
        ws.send_bytes(FRAME)
        ws.send_text(json.dumps({"type": "stop"}))
        drained, message = _drain_terminal(ws)
    assert drained == ["add the rice"] and message == {"type": "closed", "reason": "client_stop"}


def _token_expiring_in(client: TestClient, settings: Settings, email: str, seconds: float) -> str:
    headers = _sign_in(client, email)
    user_id = uuid.UUID(client.get("/v1/me", headers=headers).json()["id"])
    issued = datetime.now(UTC) - timedelta(days=settings.jwt_ttl_days) + timedelta(seconds=seconds)
    return create_access_token(settings, user_id, now=issued)


def test_the_stream_ends_when_the_token_expires(client: TestClient, settings: Settings) -> None:
    token = _token_expiring_in(client, settings, "exp@x.com", 1.5)
    started = time.monotonic()
    with client.websocket_connect(
        "/v1/voice/stream", headers={"Authorization": f"Bearer {token}"}
    ) as ws:
        assert ws.receive_json()["type"] == "ready"
        message = _terminal(ws)
    assert message["code"] == "TOKEN_EXPIRED"
    assert time.monotonic() - started < 5


async def _delete_user(email: str, app: Any) -> None:
    async with app.state.sessionmaker() as session, session.begin():
        user = (await session.execute(select(User).where(User.email == email))).scalar_one()
        await session.delete(user)


def test_a_deleted_account_is_cut_off_at_the_next_block(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("app.voice.metering.DEFAULT_BLOCK_MS", 1000)
    with _open(client, "gone@x.com") as ws:
        ws.receive_json()
        for _ in range(4):
            ws.send_bytes(FRAME)
        _portal(client).call(_delete_user, "gone@x.com", client.app)
        for _ in range(4):  # crosses the 1 s block boundary
            ws.send_bytes(FRAME)
        assert _terminal(ws)["code"] == "UNAUTHORIZED"


def test_losing_paid_mid_stream_is_refused_at_the_next_block(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("app.voice.metering.DEFAULT_BLOCK_MS", 1000)
    app: Any = client.app
    with _open(client, "downgrade@x.com") as ws:
        ws.receive_json()
        for _ in range(4):
            ws.send_bytes(FRAME)
        app.state.settings = app.state.settings.model_copy(update={"default_entitlement": "free"})
        for _ in range(4):
            ws.send_bytes(FRAME)
        assert _terminal(ws)["code"] == "VOICE_NOT_ENTITLED"


def test_control_flood_is_closed(client: TestClient) -> None:
    with _open(client, "flood@x.com") as ws:
        ws.receive_json()
        for _ in range(30):
            ws.send_text(json.dumps({"type": "keepalive"}))
        assert _terminal(ws)["code"] == "CONTROL_FLOOD"


def test_tiny_frame_flood_is_paced(client: TestClient) -> None:
    with _open(client, "tiny@x.com") as ws:
        ws.receive_json()
        for _ in range(300):  # 1/16 ms each, but charged 20 ms: 6 s > the 5 s burst
            ws.send_bytes(b"\x00\x00")
        assert _terminal(ws)["code"] == "AUDIO_TOO_FAST"


def test_keepalives_without_audio_still_close(
    settings: Settings, stt: FakeSTT, clean_tables: None
) -> None:
    for client in _client(settings, stt, voice_no_audio_timeout_seconds=0.4):
        with _open(client, "quiet@x.com") as ws:
            ws.receive_json()
            for _ in range(3):
                ws.send_text(json.dumps({"type": "keepalive"}))
                time.sleep(0.1)
            assert _terminal(ws) == {"type": "closed", "reason": "no_audio"}


async def _usage_rows(app: Any) -> list[AIUsage]:
    async with app.state.sessionmaker() as session:
        return list((await session.execute(select(AIUsage))).scalars().all())


def test_abrupt_disconnect_still_settles_and_frees_the_slot(client: TestClient) -> None:
    headers = _sign_in(client, "drop@x.com")
    with client.websocket_connect("/v1/voice/stream", headers=headers) as ws:
        ws.receive_json()
        for _ in range(5):
            ws.send_bytes(FRAME)
        # Leave without a stop: the phone vanished.
    for _ in range(100):
        rows = _portal(client).call(_usage_rows, client.app)
        if rows and all(r.status == "settled" for r in rows):
            break
        time.sleep(0.05)
    assert [(r.status, r.input_tokens) for r in rows] == [("settled", 1000)]
    with client.websocket_connect("/v1/voice/stream", headers=headers) as again:
        assert again.receive_json()["type"] == "ready"
