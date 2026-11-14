"""``WS /v1/voice/stream``: the phone's gated mic audio → Deepgram → transcripts and turn
events back (brief 012 PR 2).

Protocol (JSON text frames unless noted):

* phone → server: binary frames of 16 kHz s16le mono PCM, sent only while someone speaks;
  ``{"type": "keepalive"}`` (resets the idle timer), ``{"type": "finalize"}`` (a speech span
  ended: flush the transcript now), ``{"type": "stop"}``.
* server → phone: ``ready``; ``transcript`` {text, is_final, speech_final, start_ms, end_ms};
  ``speech_started`` {at_ms}; ``utterance_end`` {last_word_end_ms}; then exactly one terminal
  message before the close: ``ai_resting`` {reason, message}, ``error`` {code, message} or
  ``closed`` {reason}. Times are milliseconds of audio received on this stream. Before any
  close, audio already sent is finalized and its transcript forwarded.

Limits: max session length and the token's ``exp``, an idle timeout, a no-audio timeout, a
control-message rate, frame size, and real-time pacing. The user and their Paid entitlement
are re-checked at every 30 s billing block.

Audio and transcript text are never stored or logged. Spend is metered per audio second
through ``SpeechLease``; over a cap the phone is told ``ai_resting`` and falls back to Free.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import asdict
from typing import Any

from starlette.websockets import WebSocket, WebSocketDisconnect

from app.ai.budget import CostGuard
from app.core.config import Settings
from app.voice import metering
from app.voice.metering import SpeechLease
from app.voice.stt import (
    BYTES_PER_SECOND,
    SAMPLE_RATE,
    SpeechToText,
    STTStream,
    STTUnavailable,
    Transcript,
)

log = logging.getLogger("umma.voice.stream")

VOICE_RESTING_MESSAGE = "AI is resting, so voice runs on this iPhone for now."
UPSTREAM_KEEPALIVE_SECONDS = 5.0
# Audio may run ahead of wall time by this much (network bunching), never more.
AUDIO_BURST_MS = 5_000
# Pacing charges every audio frame at least this much, however small it is.
MIN_FRAME_MS = 20
# Before a close, how long to wait for the final transcript of audio already sent.
DRAIN_SECONDS = 1.5

# Close codes (4000-4999 are application codes).
CLOSE_NORMAL = 1000
CLOSE_UNAUTHORIZED = 4401
CLOSE_NOT_ENTITLED = 4403
CLOSE_LIMIT = 4429
CLOSE_BAD_FRAME = 4400
CLOSE_UNAVAILABLE = 4503


class StreamLimiter:
    """Open streams per user, in this process. One process serves the beta (DECISIONS #19)."""

    def __init__(self) -> None:
        self._open: dict[uuid.UUID, int] = {}

    def acquire(self, user_id: uuid.UUID, limit: int) -> bool:
        if self._open.get(user_id, 0) >= limit:
            return False
        self._open[user_id] = self._open.get(user_id, 0) + 1
        return True

    def release(self, user_id: uuid.UUID) -> None:
        left = self._open.get(user_id, 0) - 1
        if left > 0:
            self._open[user_id] = left
        else:
            self._open.pop(user_id, None)


async def send_terminal(ws: WebSocket, message: dict[str, Any], code: int) -> None:
    with contextlib.suppress(Exception):
        await ws.send_text(json.dumps(message))
    with contextlib.suppress(Exception):
        await ws.close(code=code)


def error_message(code: str, message: str) -> dict[str, Any]:
    return {"type": "error", "code": code, "message": message}


def _event_json(event: Any) -> str:
    if isinstance(event, Transcript):
        body = asdict(event)
        body.pop("confidence", None)
        return json.dumps({"type": "transcript", **body})
    kind = "speech_started" if hasattr(event, "at_ms") else "utterance_end"
    return json.dumps({"type": kind, **asdict(event)})


class _End(Exception):
    def __init__(self, message: dict[str, Any], code: int, outcome: str) -> None:
        self.message, self.code, self.outcome = message, code, outcome


def refusal(message: dict[str, Any], code: int) -> _End:
    """A terminal error for ``Recheck`` to return."""
    return _End(message, code, "ok")


def _closed(reason: str) -> _End:
    return _End({"type": "closed", "reason": reason}, CLOSE_NORMAL, "ok")


#: Checks the user still exists and is Paid; returns the reason to close, or None.
Recheck = Callable[[], Awaitable[Any]]


class VoiceStreamSession:
    def __init__(
        self,
        ws: WebSocket,
        settings: Settings,
        stt: SpeechToText,
        guard: CostGuard,
        user_id: uuid.UUID,
        *,
        token_expires_at: float,
        recheck: Recheck,
    ) -> None:
        self._ws = ws
        self._settings = settings
        self._stt = stt
        self._lease = SpeechLease(guard, user_id, stt.model)
        self._recheck = recheck
        self._started = time.monotonic()
        # The token's exp, as a monotonic deadline: the stream never outlives its sign-in.
        self._token_deadline = self._started + max(0.0, token_expires_at - time.time())
        self._credit_ms = float(AUDIO_BURST_MS)
        self._last_audio = self._started
        self._controls: list[float] = []
        self._unfinalized = False
        self._final_seen = asyncio.Event()

    async def run(self) -> None:
        end = _closed("client_stop")
        try:
            # Reserve the first block before opening the vendor stream: over a cap, say so now.
            if not await self._lease.admit(0):
                raise self._resting()
            async with self._stt.open() as upstream:
                await self._ws.send_text(
                    json.dumps(
                        {
                            "type": "ready",
                            "sample_rate": SAMPLE_RATE,
                            "encoding": "linear16",
                            "max_frame_bytes": self._settings.voice_max_frame_bytes,
                            "max_session_seconds": self._settings.voice_max_session_seconds,
                        }
                    )
                )
                end = await self._pump(upstream)
        except _End as stop:
            end = stop
        except STTUnavailable:
            message = "Server voice is unavailable. Voice runs on this iPhone."
            end = _End(error_message("VOICE_UNAVAILABLE", message), CLOSE_UNAVAILABLE, "error")
        except Exception as exc:
            # Type only: a vendor exception's text or traceback could carry request details.
            log.warning("voice stream failed", extra={"error_type": type(exc).__name__})
            message = "Server voice stopped. Voice runs on this iPhone."
            end = _End(error_message("VOICE_UPSTREAM_LOST", message), 1011, "error")
        finally:
            await self._lease.close(end.outcome)
        await send_terminal(self._ws, end.message, end.code)

    def _resting(self) -> _End:
        reason = self._lease.denied or "monthly_cap"
        body = {"type": "ai_resting", "reason": reason, "message": VOICE_RESTING_MESSAGE}
        return _End(body, CLOSE_NORMAL, "resting")

    async def _pump(self, upstream: STTStream) -> _End:
        to_phone = asyncio.create_task(self._to_phone(upstream))
        tasks = {
            asyncio.create_task(self._from_phone(upstream)),
            to_phone,
            asyncio.create_task(self._keepalive(upstream)),
        }
        try:
            max_end = self._started + self._settings.voice_max_session_seconds
            deadline = min(max_end, self._token_deadline)
            done, _ = await asyncio.wait(
                tasks,
                timeout=max(0.0, deadline - time.monotonic()),
                return_when=asyncio.FIRST_COMPLETED,
            )
            if not done:
                if self._token_deadline < max_end:
                    message = "Sign in again to use server voice."
                    result = _End(error_message("TOKEN_EXPIRED", message), CLOSE_UNAUTHORIZED, "ok")
                else:
                    result = _closed("max_duration")
            else:
                first = done.pop()
                exc = first.exception()
                if isinstance(exc, _End):
                    result = exc
                elif exc is not None:
                    raise exc
                elif isinstance(first.result(), _End):
                    result = first.result()
                else:
                    message = "Server voice stopped. Voice runs on this iPhone."
                    return _End(error_message("VOICE_UPSTREAM_LOST", message), 1011, "error")
            if result.message.get("reason") != "disconnected" and not to_phone.done():
                await self._drain(upstream)
            return result
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    async def _drain(self, upstream: STTStream) -> None:
        """Before any close, words already sent are finalized and forwarded, so none are lost
        (``ai_resting``, timeouts, stop)."""
        if not self._unfinalized:
            return
        self._final_seen.clear()
        with contextlib.suppress(Exception):
            await upstream.finalize()
            await asyncio.wait_for(self._final_seen.wait(), timeout=DRAIN_SECONDS)

    async def _from_phone(self, upstream: STTStream) -> _End:
        idle = self._settings.voice_idle_timeout_seconds
        no_audio = self._settings.voice_no_audio_timeout_seconds
        while True:
            quiet_left = self._last_audio + no_audio - time.monotonic()
            try:
                message = await asyncio.wait_for(
                    self._ws.receive(), timeout=max(0.0, min(idle, quiet_left))
                )
            except TimeoutError:
                if time.monotonic() - self._last_audio >= no_audio:
                    return _closed("no_audio")
                return _closed("idle")
            except WebSocketDisconnect:
                return _closed("disconnected")
            if message["type"] == "websocket.disconnect":
                return _closed("disconnected")
            if (data := message.get("bytes")) is not None:
                await self._audio(upstream, data)
                continue
            self._count_control()
            control = _parse_control(message.get("text"))
            if control == "stop":
                return _closed("client_stop")
            if control == "finalize":
                self._unfinalized = False
                await upstream.finalize()

    def _count_control(self) -> None:
        now = time.monotonic()
        self._controls = [t for t in self._controls if now - t < 1.0]
        self._controls.append(now)
        if len(self._controls) > self._settings.voice_max_controls_per_second:
            message = "Too many control messages."
            raise _End(error_message("CONTROL_FLOOD", message), CLOSE_BAD_FRAME, "error")

    async def _audio(self, upstream: STTStream, data: bytes) -> None:
        if len(data) > self._settings.voice_max_frame_bytes or len(data) % 2:
            message = "Audio frames must be 16-bit PCM, at most "
            message += f"{self._settings.voice_max_frame_bytes} bytes."
            raise _End(error_message("BAD_FRAME", message), CLOSE_BAD_FRAME, "error")
        audio_ms = -(-len(data) * 1000 // BYTES_PER_SECOND)  # rounded up: never under-bill
        # Pace against real time since the last frame (a token bucket that holds at most
        # AUDIO_BURST_MS). Every frame costs at least MIN_FRAME_MS, so tiny-frame floods stop.
        now = time.monotonic()
        refill = (now - self._last_audio) * 1000
        self._credit_ms = min(float(AUDIO_BURST_MS), self._credit_ms + refill)
        self._last_audio = now
        charge = max(audio_ms, MIN_FRAME_MS)
        if charge > self._credit_ms:
            message = "Audio arrived faster than real time."
            raise _End(error_message("AUDIO_TOO_FAST", message), CLOSE_BAD_FRAME, "error")
        self._credit_ms -= charge
        # Every billing block, check the account is still there and still Paid.
        before, block = self._lease.total_ms, metering.DEFAULT_BLOCK_MS
        if before and before // block != (before + audio_ms) // block:
            if (refused := await self._recheck()) is not None:
                raise refused
        if not await self._lease.admit(audio_ms):
            raise self._resting()
        self._unfinalized = True
        await upstream.send_audio(data)

    async def _to_phone(self, upstream: STTStream) -> None:
        async for event in upstream.events():
            await self._ws.send_text(_event_json(event))
            if isinstance(event, Transcript) and event.is_final:
                self._final_seen.set()

    async def _keepalive(self, upstream: STTStream) -> None:
        while True:
            await asyncio.sleep(UPSTREAM_KEEPALIVE_SECONDS)
            await upstream.keepalive()


def _parse_control(text: str | None) -> str | None:
    try:
        body = json.loads(text or "")
    except ValueError:
        return None
    kind = body.get("type") if isinstance(body, dict) else None
    return kind if kind in {"keepalive", "finalize", "stop"} else None
