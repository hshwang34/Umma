"""Dated Gemini price table (USD per 1M tokens, paid tier, Standard).

Source: https://ai.google.dev/gemini-api/docs/pricing, verified 2026-10-28. Thinking tokens are
billed as output ("Output price (including thinking tokens)"). A row applies from its
``effective_from`` (UTC) until the next row for the same model.

Unknown models fail closed: they are priced at :data:`WORST_CASE`, which is above every row
here, so a typo in a model setting can only make the cost guard stricter, never looser.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal

PER_MILLION = Decimal(1_000_000)


@dataclass(frozen=True)
class Price:
    input_per_m: Decimal
    output_per_m: Decimal


@dataclass(frozen=True)
class PriceRow:
    model: str
    effective_from: datetime
    price: Price


def _d(value: str) -> Decimal:
    return Decimal(value)


_EPOCH = datetime(2026, 1, 1, tzinfo=UTC)

PRICE_TABLE: tuple[PriceRow, ...] = (
    # gemini-3.8-flash: $0.75 / $3.75 through 2026-12-31, then doubles on 2027-01-01.
    PriceRow("gemini-3.8-flash", _EPOCH, Price(_d("0.75"), _d("3.75"))),
    PriceRow("gemini-3.8-flash", datetime(2027, 1, 1, tzinfo=UTC), Price(_d("1.50"), _d("7.50"))),
    # gemini-3.5-flash-lite: $0.30 (text / image / video / audio) / $2.50; no change announced.
    PriceRow("gemini-3.5-flash-lite", _EPOCH, Price(_d("0.30"), _d("2.50"))),
    # gemini-3.8-live (brief 016), conservative: text/image/audio input at $1.00 and every output
    # token at the audio-output price, $12.00 (the model speaks even when told not to).
    PriceRow("gemini-3.8-live", _EPOCH, Price(_d("1.00"), _d("12.00"))),
)

# Above every row in the table (and above Gemini 4 Argon's Dec-2026 $4 / $20), so an unknown or
# mistyped model id is charged as the most expensive thing we could plausibly be calling.
WORST_CASE = Price(_d("5.00"), _d("25.00"))


def price_for(model: str, at: datetime) -> Price:
    rows = [r for r in PRICE_TABLE if r.model == model and r.effective_from <= at]
    if not rows:
        return WORST_CASE
    return max(rows, key=lambda r: r.effective_from).price


def is_known(model: str) -> bool:
    return any(r.model == model for r in PRICE_TABLE)


def cost_usd(model: str, at: datetime, *, input_tokens: int, output_tokens: int) -> Decimal:
    """``output_tokens`` must already include thinking tokens (they bill as output)."""
    price = price_for(model, at)
    return (
        Decimal(max(input_tokens, 0)) * price.input_per_m
        + Decimal(max(output_tokens, 0)) * price.output_per_m
    ) / PER_MILLION


# --- Paid server voice (brief 012 PR 2) -------------------------------------------------------
# Priced per unit, not per token: Deepgram per second of audio sent, ElevenLabs per character
# of text sent. List prices, verified 2026-11-13 (https://deepgram.com/pricing,
# https://elevenlabs.io/pricing/api). Deepgram Nova-3 streaming lists $0.0077/min with a
# temporary discount to $0.0048; we charge the undiscounted price so the guard errs strict.
# Model ids in the ledger carry the vendor prefix ("deepgram/nova-3").


@dataclass(frozen=True)
class UnitPriceRow:
    """``usd`` for every ``per`` units (audio milliseconds or characters)."""

    model: str
    effective_from: datetime
    usd: Decimal
    per: Decimal


_AUDIO_MINUTE_MS = Decimal(60_000)
_THOUSAND_CHARS = Decimal(1000)

VOICE_PRICE_TABLE: tuple[UnitPriceRow, ...] = (
    # Speech-to-text: USD per minute of audio (units are audio milliseconds).
    UnitPriceRow("deepgram/nova-3", _EPOCH, _d("0.0077"), _AUDIO_MINUTE_MS),
    # Text-to-speech: USD per 1K characters.
    UnitPriceRow("elevenlabs/eleven_flash_v2_5", _EPOCH, _d("0.04"), _THOUSAND_CHARS),
    UnitPriceRow("elevenlabs/eleven_turbo_v2_5", _EPOCH, _d("0.04"), _THOUSAND_CHARS),
    UnitPriceRow("elevenlabs/eleven_multilingual_v2", _EPOCH, _d("0.08"), _THOUSAND_CHARS),
    UnitPriceRow("elevenlabs/eleven_v3", _EPOCH, _d("0.08"), _THOUSAND_CHARS),
)

# Unknown voice models fail closed, as above: well over any listed price.
VOICE_WORST_CASE_STT = UnitPriceRow("unknown", _EPOCH, _d("0.05"), _AUDIO_MINUTE_MS)
VOICE_WORST_CASE_TTS = UnitPriceRow("unknown", _EPOCH, _d("0.30"), _THOUSAND_CHARS)


def voice_price(model: str, at: datetime) -> UnitPriceRow:
    rows = [r for r in VOICE_PRICE_TABLE if r.model == model and r.effective_from <= at]
    if rows:
        return max(rows, key=lambda r: r.effective_from)
    return VOICE_WORST_CASE_STT if model.startswith("deepgram/") else VOICE_WORST_CASE_TTS


def _unit_cost(model: str, at: datetime, units: int) -> Decimal:
    row = voice_price(model, at)
    return Decimal(max(units, 0)) * row.usd / row.per


def stt_cost_usd(model: str, at: datetime, *, audio_ms: int) -> Decimal:
    return _unit_cost(model, at, audio_ms)


def tts_cost_usd(model: str, at: datetime, *, characters: int) -> Decimal:
    return _unit_cost(model, at, characters)
