"""Streaming text-to-speech: the ``TextToSpeech`` protocol and the ElevenLabs client.

ElevenLabs ``POST /v1/text-to-speech/{voice_id}/stream`` streams raw s16le mono PCM for a
``pcm_*`` output format, which the phone schedules straight into its audio engine. The text is
sent exactly as given (safety and allergy wording is never rewritten, brief 012).

ElevenLabs bills every character of an accepted request, even when the stream is cut short by
a barge-in, so the ledger charges the whole text once the request is accepted, and nothing when
it is refused with an error status.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from typing import Protocol

import httpx

log = logging.getLogger("umma.voice.tts")

ELEVENLABS_BASE_URL = "https://api.elevenlabs.io"
_SAMPLE_RATES = {"pcm_16000": 16_000, "pcm_22050": 22_050, "pcm_24000": 24_000}


class TTSRejected(Exception):
    """The vendor answered with an error status before any audio (not billed)."""

    def __init__(self, status_code: int) -> None:
        super().__init__(f"text-to-speech refused ({status_code})")
        self.status_code = status_code


class TextToSpeech(Protocol):
    #: Ledger model id, vendor-prefixed (``elevenlabs/eleven_flash_v2_5``).
    model: str
    sample_rate: int

    def stream(self, text: str) -> AsyncIterator[bytes]:
        """Raw s16le mono PCM at ``sample_rate``. Raises ``TTSRejected`` before any audio."""
        ...


class ElevenLabsTTS:
    def __init__(
        self,
        api_key: str,
        voice_id: str,
        *,
        model: str = "eleven_flash_v2_5",
        output_format: str = "pcm_24000",
        timeout_seconds: float = 20.0,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        if output_format not in _SAMPLE_RATES:
            raise ValueError(f"unsupported output format {output_format!r}")
        self._api_key = api_key
        self._voice_id = voice_id
        self._model = model
        self._output_format = output_format
        self._timeout = httpx.Timeout(timeout_seconds, connect=5.0)
        self._client = client
        self.model = f"elevenlabs/{model}"
        self.sample_rate = _SAMPLE_RATES[output_format]

    async def stream(self, text: str) -> AsyncIterator[bytes]:
        url = f"{ELEVENLABS_BASE_URL}/v1/text-to-speech/{self._voice_id}/stream"
        params = {"output_format": self._output_format}
        headers = {"xi-api-key": self._api_key, "Accept": "audio/pcm"}
        body = {"text": text, "model_id": self._model}
        client = self._client or httpx.AsyncClient(timeout=self._timeout)
        try:
            async with client.stream(
                "POST", url, params=params, headers=headers, json=body, timeout=self._timeout
            ) as response:
                if response.status_code != 200:
                    # Status only: the body may quote the request.
                    log.warning("elevenlabs refused", extra={"status": response.status_code})
                    raise TTSRejected(response.status_code)
                async for chunk in response.aiter_bytes():
                    if chunk:
                        yield chunk
        finally:
            if self._client is None:
                await client.aclose()
