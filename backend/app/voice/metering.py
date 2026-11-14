"""Paid-voice spend through the existing cost guard (brief 012 PR 2).

Both capabilities are interactive, so they sit under the per-person $0.25 UTC-day cap and the
global monthly caps, like the coach.

* ``voice_stt``: a stream reserves audio in blocks (``block_ms`` of audio at a time) before it
  forwards any of it. When a block is used up it is settled at the audio actually sent and the
  next block is reserved; a refused reservation means the stream must stop (``ai_resting``).
* ``voice_tts``: one reservation per utterance at the full character price, settled at the full
  price once the vendor accepted the request (it bills cut-off streams too), at zero when the
  vendor refused it, and at the ceiling for anything unknown.
"""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime

from app.ai.budget import CostGuard, Denial, Reservation, VoiceMeter
from app.ai.notice import DenialReason
from app.ai.pricing import stt_cost_usd, tts_cost_usd

DEFAULT_BLOCK_MS = 30_000


class SpeechLease:
    """Audio budget for one speech-to-text stream. Not thread-safe: one stream, one task."""

    def __init__(
        self,
        guard: CostGuard,
        user_id: uuid.UUID,
        model: str,
        *,
        block_ms: int | None = None,
    ) -> None:
        self._guard = guard
        self._user_id = user_id
        self._model = model
        self._block_ms = block_ms or DEFAULT_BLOCK_MS
        self._reservation: Reservation | None = None
        self._meter: VoiceMeter | None = None
        self.total_ms = 0
        self.denied: DenialReason | None = None

    async def admit(self, audio_ms: int) -> bool:
        """Account for ``audio_ms`` more audio. False (and ``denied`` set) over a cap."""
        if self.denied is not None:
            return False
        if self._meter is None or self._meter.units + audio_ms > self._block_ms:
            await self._settle("ok")
            now = datetime.now(UTC)
            block = max(self._block_ms, audio_ms)
            ceiling = stt_cost_usd(self._model, now, audio_ms=block)
            decision = await self._guard.reserve(self._user_id, "voice_stt", self._model, ceiling)
            if isinstance(decision, Denial):
                self.denied = decision.reason
                return False
            self._reservation = decision
            self._meter = VoiceMeter(model=self._model, at=now, kind="speech")
        self._meter.units += audio_ms
        self.total_ms += audio_ms
        return True

    async def close(self, outcome: str = "ok") -> None:
        await asyncio.shield(self._settle(outcome))

    async def _settle(self, outcome: str) -> None:
        reservation, meter = self._reservation, self._meter
        self._reservation, self._meter = None, None
        if reservation is not None and meter is not None:
            await self._guard.settle(reservation, meter, outcome)


async def reserve_speech_out(
    guard: CostGuard, user_id: uuid.UUID, model: str, text: str
) -> tuple[Reservation, VoiceMeter] | Denial:
    now = datetime.now(UTC)
    ceiling = tts_cost_usd(model, now, characters=len(text))
    decision = await guard.reserve(user_id, "voice_tts", model, ceiling)
    if isinstance(decision, Denial):
        return decision
    return decision, VoiceMeter(model=model, at=now, kind="voice", units=len(text))
