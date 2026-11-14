"""Paid voice vendor adapters (brief 012 PR 2): parsing, request shapes, pricing. No network."""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

import httpx
import pytest
from pydantic import SecretStr

from app.ai.budget import VoiceMeter
from app.ai.pricing import stt_cost_usd, tts_cost_usd
from app.core.config import Settings
from app.voice.registry import build_stt, build_tts
from app.voice.stt import (
    DeepgramStreamingSTT,
    SpeechStarted,
    STTUnavailable,
    Transcript,
    UtteranceEnd,
    parse_deepgram_message,
)
from app.voice.tts import ElevenLabsTTS, TTSRejected

FIXTURE = Path(__file__).resolve().parents[1] / "fixtures" / "voice" / "deepgram_session.jsonl"
NOW = datetime(2026, 11, 13, tzinfo=UTC)
FAKE_KEY = "dg-test-key-not-real"


def test_parses_a_deepgram_session() -> None:
    events = [parse_deepgram_message(line) for line in FIXTURE.read_text().splitlines()]
    assert [e for e in events if e is not None] == [
        SpeechStarted(at_ms=120),
        Transcript("next", False, False, 180, 520, 0.91),
        Transcript("Next step, please.", True, True, 180, 1300, 0.97),
        UtteranceEnd(last_word_end_ms=1300),
    ]


def test_empty_final_is_kept_so_the_phone_can_close_a_partial() -> None:
    raw = {"type": "Results", "is_final": True, "start": 1.0, "duration": 0.5, "channel": {}}
    assert parse_deepgram_message(json.dumps(raw)) == Transcript("", True, False, 1000, 1500)


def test_url_asks_for_turn_events_and_opts_out_of_training() -> None:
    url = DeepgramStreamingSTT(FAKE_KEY, endpointing_ms=250, utterance_end_ms=1200).url()
    for part in (
        "model=nova-3",
        "encoding=linear16",
        "sample_rate=16000",
        "interim_results=true",
        "vad_events=true",
        "endpointing=250",
        "utterance_end_ms=1200",
        "mip_opt_out=true",
    ):
        assert part in url
    assert FAKE_KEY not in url


class FakeConnection:
    def __init__(self, messages: list[str]) -> None:
        self.messages = messages
        self.sent: list[Any] = []
        self.closed = False

    async def send(self, data: Any) -> None:
        self.sent.append(data)

    async def close(self) -> None:
        self.closed = True

    def __aiter__(self) -> AsyncIterator[str]:
        async def gen() -> AsyncIterator[str]:
            for m in self.messages:
                yield m

        return gen()


async def test_stream_sends_audio_and_controls_with_the_key_in_a_header() -> None:
    conn = FakeConnection(FIXTURE.read_text().splitlines())
    seen: dict[str, Any] = {}

    async def connector(url: str, **kwargs: Any) -> FakeConnection:
        seen.update(url=url, **kwargs)
        return conn

    stt = DeepgramStreamingSTT(FAKE_KEY, connector=connector)
    async with stt.open() as stream:
        await stream.send_audio(b"\x00" * 640)
        await stream.keepalive()
        await stream.finalize()
        events = [e async for e in stream.events()]
    assert seen["additional_headers"] == {"Authorization": f"Token {FAKE_KEY}"}
    assert conn.sent[0] == b"\x00" * 640
    controls = [json.loads(s)["type"] for s in conn.sent[1:]]
    assert controls == ["KeepAlive", "Finalize", "CloseStream"]
    assert conn.closed and len(events) == 4
    assert stt.model == "deepgram/nova-3"


async def test_connect_failure_is_unavailable_without_leaking_the_key() -> None:
    async def connector(url: str, **kwargs: Any) -> FakeConnection:
        raise OSError(f"handshake failed for {kwargs['additional_headers']}")

    with pytest.raises(STTUnavailable) as err:
        async with DeepgramStreamingSTT(FAKE_KEY, connector=connector).open():
            pass
    assert FAKE_KEY not in str(err.value) and err.value.__cause__ is None


def _tts(handler: Any) -> ElevenLabsTTS:
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return ElevenLabsTTS("el-test-key", "voice123", client=client)


async def test_tts_streams_pcm_and_sends_text_verbatim() -> None:
    seen: dict[str, Any] = {}
    text = "Cook chicken until it reaches 165°F (74°C) inside.  Don't guess."

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(url=str(request.url), key=request.headers["xi-api-key"])
        seen["body"] = json.loads(request.content)
        return httpx.Response(200, content=b"\x01\x02" * 1000)

    tts = _tts(handler)
    audio = b"".join([c async for c in tts.stream(text)])
    assert audio == b"\x01\x02" * 1000
    assert seen["url"].startswith("https://api.elevenlabs.io/v1/text-to-speech/voice123/stream")
    assert "output_format=pcm_24000" in seen["url"]
    assert seen["key"] == "el-test-key"
    assert seen["body"] == {"text": text, "model_id": "eleven_flash_v2_5"}
    assert (tts.model, tts.sample_rate) == ("elevenlabs/eleven_flash_v2_5", 24_000)


async def test_tts_error_status_is_rejected() -> None:
    tts = _tts(lambda request: httpx.Response(401, json={"detail": "bad key"}))
    with pytest.raises(TTSRejected) as err:
        _ = [c async for c in tts.stream("hello")]
    assert err.value.status_code == 401


def test_registry_is_off_without_keys_and_on_with_them() -> None:
    base = Settings(jwt_secret="x" * 40, auth_mode="dev", _env_file=None)  # type: ignore[call-arg]
    off = base.model_copy(
        update={"deepgram_api_key": None, "elevenlabs_api_key": None, "paid_voice_enabled": True}
    )
    assert build_stt(off) is None and build_tts(off) is None
    no_voice = off.model_copy(update={"elevenlabs_api_key": SecretStr("k")})
    assert build_tts(no_voice) is None  # a key without a voice id is still off
    on = off.model_copy(
        update={
            "deepgram_api_key": SecretStr("d"),
            "elevenlabs_api_key": SecretStr("e"),
            "elevenlabs_voice_id": "v",
        }
    )
    assert isinstance(build_stt(on), DeepgramStreamingSTT)
    assert isinstance(build_tts(on), ElevenLabsTTS)
    assert "d" not in repr(on.deepgram_api_key)


def test_registry_stays_off_with_keys_until_paid_voice_is_enabled() -> None:
    base = Settings(jwt_secret="x" * 40, auth_mode="dev", _env_file=None)  # type: ignore[call-arg]
    assert base.paid_voice_enabled is False  # dark by default (DECISIONS #26)
    keys = base.model_copy(
        update={
            "deepgram_api_key": SecretStr("d"),
            "elevenlabs_api_key": SecretStr("e"),
            "elevenlabs_voice_id": "v",
        }
    )
    assert build_stt(keys) is None and build_tts(keys) is None
    on = keys.model_copy(update={"paid_voice_enabled": True})
    assert build_stt(on) is not None and build_tts(on) is not None


def test_voice_prices() -> None:
    assert stt_cost_usd("deepgram/nova-3", NOW, audio_ms=60_000) == Decimal("0.0077")
    assert tts_cost_usd("elevenlabs/eleven_flash_v2_5", NOW, characters=1000) == Decimal("0.04")
    assert tts_cost_usd("elevenlabs/eleven_v3", NOW, characters=1000) == Decimal("0.08")
    # Unknown models fail closed, above every listed price.
    assert stt_cost_usd("deepgram/nova-9", NOW, audio_ms=1000) > Decimal("0.0077") / 60
    assert tts_cost_usd("elevenlabs/new", NOW, characters=1000) > Decimal("0.08")


def test_voice_meter_fills_the_ledger_columns() -> None:
    speech = VoiceMeter(model="deepgram/nova-3", at=NOW, kind="speech", units=30_000)
    assert (speech.input_tokens, speech.output_tokens) == (30_000, 0)
    assert speech.cost == Decimal("0.00385")
    voice = VoiceMeter(model="elevenlabs/eleven_flash_v2_5", at=NOW, kind="voice", units=250)
    assert (voice.input_tokens, voice.output_tokens, voice.thinking_tokens) == (0, 250, 0)
    assert voice.cost == Decimal("0.01")
