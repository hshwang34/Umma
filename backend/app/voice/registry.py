"""Build the voice vendors from settings. ``None`` means off: ``PAID_VOICE_ENABLED`` is false
(the default, DECISIONS #26) or the vendor key is missing."""

from __future__ import annotations

from app.core.config import Settings
from app.voice.stt import DeepgramStreamingSTT, SpeechToText
from app.voice.tts import ElevenLabsTTS, TextToSpeech


def build_stt(settings: Settings) -> SpeechToText | None:
    if not settings.voice_stt_configured or settings.deepgram_api_key is None:
        return None
    return DeepgramStreamingSTT(
        settings.deepgram_api_key.get_secret_value(),
        model=settings.deepgram_model,
        endpointing_ms=settings.deepgram_endpointing_ms,
        utterance_end_ms=settings.deepgram_utterance_end_ms,
    )


def build_tts(settings: Settings) -> TextToSpeech | None:
    if not settings.voice_tts_configured or settings.elevenlabs_api_key is None:
        return None
    return ElevenLabsTTS(
        settings.elevenlabs_api_key.get_secret_value(),
        settings.elevenlabs_voice_id or "",
        model=settings.elevenlabs_model,
        output_format=settings.elevenlabs_output_format,
        timeout_seconds=settings.voice_tts_timeout_seconds,
    )
