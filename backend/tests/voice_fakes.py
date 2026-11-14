"""Zero-spend fakes for the paid voice vendors (brief 012 PR 2)."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from app.voice.stt import STTEvent, STTUnavailable, Transcript
from app.voice.tts import TTSRejected


class FakeSTTStream:
    def __init__(self, owner: FakeSTT) -> None:
        self._owner = owner
        self.audio = bytearray()
        self.finalize_count = 0
        self.keepalive_count = 0
        self._queue: asyncio.Queue[STTEvent | None] = asyncio.Queue()
        for event in owner.script:
            self._queue.put_nowait(event)

    async def send_audio(self, pcm: bytes) -> None:
        self.audio.extend(pcm)
        if self._owner.echo_after_bytes and len(self.audio) >= self._owner.echo_after_bytes:
            self._owner.echo_after_bytes = 0
            ms = len(self.audio) * 1000 // 32_000
            self.emit(Transcript("heard you", True, True, 0, ms))

    async def finalize(self) -> None:
        self.finalize_count += 1

    async def keepalive(self) -> None:
        self.keepalive_count += 1

    def emit(self, event: STTEvent | None) -> None:
        self._queue.put_nowait(event)

    async def events(self) -> AsyncIterator[STTEvent]:
        while (event := await self._queue.get()) is not None:
            yield event


class FakeSTT:
    """``script`` events are delivered as soon as a stream opens; ``echo_after_bytes`` emits a
    final transcript once that much audio arrived. ``unavailable`` refuses to open."""

    model = "deepgram/nova-3"

    def __init__(self, script: list[STTEvent] | None = None, *, unavailable: bool = False) -> None:
        self.script = list(script or [])
        self.unavailable = unavailable
        self.echo_after_bytes = 0
        self.streams: list[FakeSTTStream] = []
        self.open_count = 0
        self.closed_count = 0

    @asynccontextmanager
    async def open(self) -> AsyncIterator[FakeSTTStream]:
        self.open_count += 1
        if self.unavailable:
            raise STTUnavailable("fake unavailable")
        stream = FakeSTTStream(self)
        self.streams.append(stream)
        try:
            yield stream
        finally:
            stream.emit(None)
            self.closed_count += 1


class FakeTTS:
    model = "elevenlabs/eleven_flash_v2_5"
    sample_rate = 24_000

    def __init__(self, *, reject_status: int | None = None, chunks: int = 3) -> None:
        self.reject_status = reject_status
        self.chunks = chunks
        self.texts: list[str] = []

    async def stream(self, text: str) -> AsyncIterator[bytes]:
        self.texts.append(text)
        if self.reject_status is not None:
            raise TTSRejected(self.reject_status)
        for _ in range(self.chunks):
            yield b"\x00\x01" * 480  # 20 ms of 24 kHz s16le
