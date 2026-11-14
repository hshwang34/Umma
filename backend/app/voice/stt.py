"""Streaming speech-to-text: the ``SpeechToText`` protocol and the Deepgram client.

Deepgram live streaming (``wss://api.deepgram.com/v1/listen``) takes raw 16 kHz s16le mono
PCM as binary frames and answers with JSON: ``Results`` (interim and final transcripts with
word timings), ``SpeechStarted`` (with ``vad_events``) and ``UtteranceEnd`` (with
``utterance_end_ms``). Control messages are ``KeepAlive``, ``Finalize`` and ``CloseStream``.

Times in events are milliseconds of *audio sent on this stream*. The phone sends audio only
while someone speaks, so this clock skips silence; the phone maps it back onto its own clock.

``mip_opt_out=true`` keeps our audio out of Deepgram's model-improvement programme.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
from collections.abc import AsyncIterator, Callable
from contextlib import AbstractAsyncContextManager, asynccontextmanager
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.parse import urlencode

from websockets.asyncio.client import ClientConnection, connect
from websockets.exceptions import ConnectionClosed

log = logging.getLogger("umma.voice.stt")

SAMPLE_RATE = 16_000
BYTES_PER_SECOND = SAMPLE_RATE * 2  # s16le mono
DEEPGRAM_URL = "wss://api.deepgram.com/v1/listen"


@dataclass(frozen=True)
class Transcript:
    text: str
    is_final: bool
    #: Deepgram's endpointing fired: the speaker finished a phrase.
    speech_final: bool
    start_ms: int
    end_ms: int
    confidence: float | None = None


@dataclass(frozen=True)
class SpeechStarted:
    at_ms: int


@dataclass(frozen=True)
class UtteranceEnd:
    last_word_end_ms: int


STTEvent = Transcript | SpeechStarted | UtteranceEnd


class STTUnavailable(Exception):
    """The vendor could not be reached or refused the stream (no audio was billed)."""


class STTStream(Protocol):
    async def send_audio(self, pcm: bytes) -> None: ...
    async def finalize(self) -> None: ...
    async def keepalive(self) -> None: ...
    def events(self) -> AsyncIterator[STTEvent]: ...


class SpeechToText(Protocol):
    #: Ledger model id, vendor-prefixed (``deepgram/nova-3``).
    model: str

    def open(self) -> AbstractAsyncContextManager[STTStream]: ...


def _ms(seconds: Any) -> int:
    try:
        return max(0, round(float(seconds) * 1000))
    except (TypeError, ValueError):
        return 0


def parse_deepgram_message(raw: str | bytes) -> STTEvent | None:
    """One Deepgram JSON message → an event, or None (metadata, empty interim, unknown)."""
    try:
        msg = json.loads(raw)
    except (ValueError, TypeError):
        return None
    if not isinstance(msg, dict):
        return None
    kind = msg.get("type")
    if kind == "SpeechStarted":
        return SpeechStarted(at_ms=_ms(msg.get("timestamp")))
    if kind == "UtteranceEnd":
        return UtteranceEnd(last_word_end_ms=_ms(msg.get("last_word_end")))
    if kind != "Results":
        return None
    alternatives = (msg.get("channel") or {}).get("alternatives") or []
    best = alternatives[0] if alternatives and isinstance(alternatives[0], dict) else {}
    text = str(best.get("transcript") or "").strip()
    is_final = bool(msg.get("is_final"))
    if not text and not is_final:
        return None
    start = _ms(msg.get("start"))
    end = start + _ms(msg.get("duration"))
    words = [w for w in best.get("words") or [] if isinstance(w, dict)]
    if words:  # word timings are tighter than the result window
        start, end = _ms(words[0].get("start")), _ms(words[-1].get("end"))
    confidence = best.get("confidence")
    return Transcript(
        text=text,
        is_final=is_final,
        speech_final=bool(msg.get("speech_final")),
        start_ms=start,
        end_ms=max(start, end),
        confidence=float(confidence) if isinstance(confidence, int | float) else None,
    )


class _DeepgramStream:
    def __init__(self, ws: ClientConnection) -> None:
        self._ws = ws

    async def send_audio(self, pcm: bytes) -> None:
        await self._ws.send(pcm)

    async def finalize(self) -> None:
        await self._ws.send(json.dumps({"type": "Finalize"}))

    async def keepalive(self) -> None:
        await self._ws.send(json.dumps({"type": "KeepAlive"}))

    async def events(self) -> AsyncIterator[STTEvent]:
        try:
            async for raw in self._ws:
                event = parse_deepgram_message(raw)
                if event is not None:
                    yield event
        except ConnectionClosed:
            return


Connector = Callable[..., Any]


class DeepgramStreamingSTT:
    def __init__(
        self,
        api_key: str,
        *,
        model: str = "nova-3",
        endpointing_ms: int = 300,
        utterance_end_ms: int = 1000,
        connector: Connector = connect,
        open_timeout: float = 5.0,
    ) -> None:
        self._api_key = api_key
        self._model = model
        self._endpointing_ms = endpointing_ms
        self._utterance_end_ms = utterance_end_ms
        self._connect = connector
        self._open_timeout = open_timeout
        self.model = f"deepgram/{model}"

    def url(self) -> str:
        params = {
            "model": self._model,
            "encoding": "linear16",
            "sample_rate": SAMPLE_RATE,
            "channels": 1,
            "interim_results": "true",
            "smart_format": "true",
            "punctuate": "true",
            "vad_events": "true",
            "endpointing": self._endpointing_ms,
            "utterance_end_ms": self._utterance_end_ms,
            "mip_opt_out": "true",
        }
        return f"{DEEPGRAM_URL}?{urlencode(params)}"

    @asynccontextmanager
    async def open(self) -> AsyncIterator[STTStream]:
        try:
            ws = await asyncio.wait_for(
                self._connect(
                    self.url(),
                    additional_headers={"Authorization": f"Token {self._api_key}"},
                    max_size=2**20,
                ),
                timeout=self._open_timeout,
            )
        except Exception as exc:
            # Never include the exception text: a handshake error can echo request headers.
            log.warning("deepgram connect failed", extra={"error_type": type(exc).__name__})
            raise STTUnavailable("speech-to-text unavailable") from None
        try:
            yield _DeepgramStream(ws)
        finally:
            with contextlib.suppress(Exception):
                await ws.send(json.dumps({"type": "CloseStream"}))
            with contextlib.suppress(Exception):
                await ws.close()
