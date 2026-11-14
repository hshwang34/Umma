"""``POST /v1/voice/speak``: text in, streamed ElevenLabs PCM out (brief 012 PR 2).

The text goes to the vendor exactly as sent: safety, allergy and doneness wording is never
rewritten here. The whole text is reserved before the call and settled at the full price once
the vendor accepted it (a barge-in that cuts the stream short is still billed by the vendor),
or at zero when the vendor refused it. The vendor stream is closed and the row settled when
the response ends, including a client that disconnects before the body is ever read.
Audio is streamed through, never stored or logged.
"""

from __future__ import annotations

import asyncio
import contextlib
import time
import uuid
from collections import deque
from collections.abc import AsyncIterator, Awaitable, Callable
from typing import Any

from fastapi.responses import StreamingResponse
from starlette.types import Receive, Scope, Send

from app.ai.budget import CostGuard, Denial
from app.ai.notice import RESTING_MESSAGE
from app.core.errors import AIResting, VoiceUnavailable
from app.voice.metering import reserve_speech_out
from app.voice.tts import TextToSpeech, TTSRejected

WINDOW_SECONDS = 60.0


class SpeakLimiter:
    """At most ``limit`` speak calls per user per minute, in this process."""

    def __init__(self) -> None:
        self._calls: dict[uuid.UUID, deque[float]] = {}

    def allow(self, user_id: uuid.UUID, limit: int, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        calls = self._calls.setdefault(user_id, deque())
        while calls and now - calls[0] >= WINDOW_SECONDS:
            calls.popleft()
        if len(calls) >= limit:
            return False
        calls.append(now)
        return True


async def speak(
    tts: TextToSpeech, guard: CostGuard, user_id: uuid.UUID, text: str
) -> StreamingResponse:
    decision = await reserve_speech_out(guard, user_id, tts.model, text)
    if isinstance(decision, Denial):
        raise AIResting(RESTING_MESSAGE, extra={"reason": decision.reason})
    reservation, meter = decision
    audio = tts.stream(text)
    outcome = "error"
    try:
        # Wait for the first audio so a vendor refusal is an error status, not a broken stream.
        first = await anext(audio, b"")
    except TTSRejected:
        meter.units = 0  # refused before any audio: not billed
        await asyncio.shield(guard.settle(reservation, meter, outcome))
        raise VoiceUnavailable() from None
    except BaseException:
        await asyncio.shield(guard.settle(reservation, meter, outcome))
        raise

    settled = False

    async def cleanup() -> None:
        """Close the vendor stream and settle, exactly once, however the response ends."""
        nonlocal settled
        if settled:
            return
        settled = True
        with contextlib.suppress(Exception):
            await audio.aclose()  # type: ignore[attr-defined]
        await asyncio.shield(guard.settle(reservation, meter, outcome))

    async def body() -> AsyncIterator[bytes]:
        nonlocal outcome
        try:
            if first:
                yield first
            async for chunk in audio:
                yield chunk
            outcome = "ok"
        finally:
            await cleanup()

    return _MeteredSpeech(
        body(),
        cleanup,
        media_type="audio/pcm",
        headers={
            "X-Audio-Encoding": "pcm_s16le",
            "X-Audio-Sample-Rate": str(tts.sample_rate),
            "X-Audio-Channels": "1",
            "Cache-Control": "no-store",
        },
    )


class _MeteredSpeech(StreamingResponse):
    """Runs ``cleanup`` when the response ends, even if the client left before the body was
    ever iterated (then the generator's own ``finally`` never runs)."""

    def __init__(
        self, content: AsyncIterator[bytes], cleanup: Callable[[], Awaitable[None]], **kw: Any
    ) -> None:
        super().__init__(content, **kw)
        self._cleanup = cleanup

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        try:
            await super().__call__(scope, receive, send)
        finally:
            await self._cleanup()
