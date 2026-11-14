"""Opt-in live smoke for paid server voice (brief 012 PR 2): ``make voice-live-smoke``.

Skipped unless ``UMMA_VOICE_LIVE=1`` **and** ``DEEPGRAM_API_KEY``, ``ELEVENLABS_API_KEY`` and
``ELEVENLABS_VOICE_ID`` are set, so keys in the environment never make ``make check`` spend.
One short sentence through ElevenLabs, then at most 3 s of that audio through Deepgram:
well under $0.01 in total. Nothing is written to disk, and no key or audio is printed.
"""

from __future__ import annotations

import array
import asyncio
import os
import time

import pytest

from app.voice.stt import BYTES_PER_SECOND, DeepgramStreamingSTT, Transcript
from app.voice.tts import ElevenLabsTTS

KEYS = ("DEEPGRAM_API_KEY", "ELEVENLABS_API_KEY", "ELEVENLABS_VOICE_ID")
LIVE = os.environ.get("UMMA_VOICE_LIVE") == "1" and all(os.environ.get(k) for k in KEYS)
pytestmark = pytest.mark.skipif(
    not LIVE, reason="voice live smoke: set UMMA_VOICE_LIVE=1 and the three voice keys"
)
SENTENCE = "Next, stir the rice."
MAX_AUDIO_SECONDS = 3


def to_16k(pcm_24k: bytes) -> bytes:
    """Nearest-sample 24 kHz → 16 kHz (good enough for a transcription smoke)."""
    src = array.array("h", pcm_24k[: len(pcm_24k) // 2 * 2])
    out = array.array("h", (src[int(i * 1.5)] for i in range(int(len(src) / 1.5))))
    return out.tobytes()


async def test_speak_then_transcribe() -> None:
    tts = ElevenLabsTTS(
        os.environ["ELEVENLABS_API_KEY"],
        os.environ["ELEVENLABS_VOICE_ID"],
        model=os.environ.get("ELEVENLABS_MODEL", "eleven_flash_v2_5"),
    )
    started = time.monotonic()
    first_audio_ms: float | None = None
    chunks: list[bytes] = []
    async for chunk in tts.stream(SENTENCE):
        if first_audio_ms is None:
            first_audio_ms = (time.monotonic() - started) * 1000
        chunks.append(chunk)
    pcm = to_16k(b"".join(chunks))[: MAX_AUDIO_SECONDS * BYTES_PER_SECOND]
    assert pcm, "no audio from ElevenLabs"

    stt = DeepgramStreamingSTT(os.environ["DEEPGRAM_API_KEY"])
    finals: list[str] = []
    async with stt.open() as stream:

        async def collect() -> None:
            async for event in stream.events():
                if isinstance(event, Transcript) and event.is_final and event.text:
                    finals.append(event.text)

        reader = asyncio.create_task(collect())
        frame = BYTES_PER_SECOND // 10  # 100 ms, sent in real time
        for i in range(0, len(pcm), frame):
            await stream.send_audio(pcm[i : i + frame])
            await asyncio.sleep(0.1)
        await stream.finalize()
        await asyncio.sleep(2.0)
        reader.cancel()
    heard = " ".join(finals).lower()
    print(f"\ntts first audio {first_audio_ms:.0f} ms; {len(pcm) / BYTES_PER_SECOND:.1f} s sent")
    assert "rice" in heard, "Deepgram did not hear the sentence"
