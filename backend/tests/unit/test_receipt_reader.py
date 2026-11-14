"""Receipt reading (brief 017 PR 1): contract, mock fixture, Gemini path, guard. No network."""

from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal
from typing import Any

import pytest
from pydantic import ValidationError

from app.ai.budget import Denial, Reservation, UsageMeter
from app.ai.guard import RESTING_RECEIPT_MESSAGE, GuardedProvider
from app.ai.providers import gemini as gemini_mod
from app.ai.providers.base import (
    MAX_RECEIPT_LINES,
    PantryExtractor,
    ReceiptDraft,
    ReceiptLine,
    ReceiptRequest,
)
from app.ai.providers.gemini import GeminiProvider, ReceiptReadDraft, gemini_schema
from app.ai.providers.mock import MockAIProvider
from app.core.config import Settings
from app.core.errors import AIResting, ProviderOutputInvalid
from tests.conftest import FIXTURES_DIR, TEST_JWT_SECRET
from tests.gemini_fake import FakeTransport, fake_provider

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
REQUEST = ReceiptRequest(image_bytes=PNG, image_mime_type="image/png")


def provider(*script: object) -> tuple[GeminiProvider, FakeTransport]:
    settings = Settings(ai_provider="gemini", jwt_secret=TEST_JWT_SECRET, auth_mode="dev")
    transport = FakeTransport(*script)
    return fake_provider(settings, transport), transport


def line(**overrides: object) -> dict[str, object]:
    return {"raw_text": "MILK 1GAL", "name": "milk", "is_food": True, "confidence": 0.9} | overrides


# --- contract -------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "bad",
    [
        {"count": 0},
        {"quantity": "0"},
        {"confidence": 1.01},
        {"confidence": -0.1},
        {"raw_text": ""},
        {"shelf_life_days": 7},  # no freshness fields, and unknown fields are refused
    ],
)
def test_receipt_line_bounds(bad: dict[str, object]) -> None:
    ReceiptLine.model_validate(line())
    with pytest.raises(ValidationError):
        ReceiptLine.model_validate(line(**bad))


def test_receipt_draft_caps_lines_and_defaults_to_not_demo() -> None:
    full = ReceiptDraft.model_validate({"lines": [line()] * MAX_RECEIPT_LINES})
    assert full.demo is False and full.purchased_on is None and full.total is None
    with pytest.raises(ValidationError):
        ReceiptDraft.model_validate({"lines": [line()] * (MAX_RECEIPT_LINES + 1)})


def test_receipt_photo_never_appears_in_dumps_or_reprs() -> None:
    assert "image_bytes" not in REQUEST.model_dump()
    assert "PNG" not in repr(REQUEST)
    with pytest.raises(ValidationError):
        ReceiptRequest(image_bytes=b"")


# --- mock -----------------------------------------------------------------------------------


async def test_mock_reads_the_fixture_receipt_and_labels_it_demo() -> None:
    mock = MockAIProvider(FIXTURES_DIR)
    assert isinstance(mock, PantryExtractor)
    draft = await mock.read_receipt(REQUEST)
    assert draft.demo is True and draft.store == "Demo Market"
    by_name = {ln.name: ln for ln in draft.lines if ln.name}
    assert by_name["egg"].count == 2
    assert by_name["chicken thigh"].quantity == Decimal("1.24")
    assert by_name["chicken thigh"].unit == "lb"
    unread = [ln for ln in draft.lines if ln.is_food and ln.name is None]
    assert len(unread) == 1 and unread[0].confidence < 0.6
    assert len([ln for ln in draft.lines if not ln.is_food]) == 2


# --- Gemini ---------------------------------------------------------------------------------


def test_receipt_schema_fits_gemini_subset() -> None:
    text = str(gemini_schema(ReceiptReadDraft))
    assert all(banned not in text for banned in ("$ref", "$defs", "anyOf", "'default'"))


async def test_gemini_reads_a_receipt_on_the_pantry_model() -> None:
    p, t = provider("receipt_read")
    draft = await p.read_receipt(REQUEST)
    assert draft.demo is False
    assert draft.purchased_on == date(2026, 11, 12) and draft.total == Decimal("21.37")
    tofu, cabbage, unread, deposit = draft.lines
    assert tofu.name == "tofu" and tofu.count == 2 and tofu.quantity is None
    assert cabbage.quantity == Decimal("0.82") and cabbage.unit == "kg"
    assert unread.name is None and unread.is_food is True
    assert deposit.is_food is False and deposit.count is None
    (call,) = t.calls
    assert call["model"] == "gemini-3.5-flash-lite"
    assert call["config"].max_output_tokens == gemini_mod.MAX_OUTPUT_TOKENS["pantry_receipt"]
    assert "never guess" in t.prompt_text().lower()
    assert sum(not isinstance(c, str) for c in call["contents"]) == 1  # the photo, once


async def test_malformed_receipt_retries_once_then_succeeds() -> None:
    p, t = provider("receipt_malformed", "receipt_read")
    meter = UsageMeter(model="gemini-3.5-flash-lite", at=gemini_mod.datetime.now(gemini_mod.UTC))
    draft = await p.read_receipt(REQUEST, meter)
    assert len(draft.lines) == 4 and len(t.calls) == 2
    assert meter.attempts == 2 and meter.input_tokens == 3400  # both attempts are billed


@pytest.mark.parametrize("bad", ["receipt_malformed", "coach_malformed", "coach_truncated"])
async def test_receipt_malformed_twice_is_an_error_never_a_partial_read(bad: str) -> None:
    p, t = provider(bad, bad, "receipt_read")
    with pytest.raises(ProviderOutputInvalid):
        await p.read_receipt(REQUEST)
    assert len(t.calls) == 2  # exactly one retry, and no salvaged half receipt


def test_receipt_ceiling_is_sized_for_a_long_receipt() -> None:
    p, _ = provider()
    plan = p.plan_for("pantry_receipt", REQUEST)
    photo = p.plan_for(
        "pantry_photo",
        gemini_mod.PantryObservationRequest(mode="photo", image_bytes=PNG),
    )
    assert plan.capability == "pantry_receipt" and plan.model == photo.model
    assert photo.ceiling_usd < plan.ceiling_usd < Decimal("0.10")  # two fit in the $0.25 day cap


# --- guard ----------------------------------------------------------------------------------


class FakeGuard:
    def __init__(self, deny: bool = False) -> None:
        self.deny = deny
        self.reserved: list[tuple[str, str, Decimal]] = []
        self.settled: list[tuple[str, int, str]] = []

    async def reserve(self, user_id: uuid.UUID, capability: str, model: str, ceiling: Decimal):  # type: ignore[no-untyped-def]
        if self.deny:
            return Denial("user_daily_cap")
        self.reserved.append((capability, model, ceiling))
        return Reservation(id=uuid.uuid4(), capability=capability, model=model, ceiling=ceiling)

    async def settle(self, reservation: Reservation, meter: UsageMeter, outcome: str) -> None:
        self.settled.append((reservation.capability, meter.attempts, outcome))


def guarded(guard: Any, *script: object) -> tuple[GuardedProvider, FakeTransport]:
    real, transport = provider(*script)
    return GuardedProvider(real, MockAIProvider(FIXTURES_DIR), guard, uuid.uuid4()), transport


async def test_guard_reserves_and_settles_under_pantry_receipt() -> None:
    guard = FakeGuard()
    g, _ = guarded(guard, "receipt_read")
    draft = await g.read_receipt(REQUEST)
    assert len(draft.lines) == 4 and draft.demo is False and g.notice is None
    ((capability, model, ceiling),) = guard.reserved
    assert capability == "pantry_receipt" and model == "gemini-3.5-flash-lite"
    assert ceiling == g._real.plan_read_receipt(REQUEST).ceiling_usd
    assert guard.settled == [("pantry_receipt", 1, "ok")]

    g, _ = guarded(guard, "receipt_malformed", "receipt_malformed")
    with pytest.raises(ProviderOutputInvalid):
        await g.read_receipt(REQUEST)
    assert guard.settled[-1] == ("pantry_receipt", 2, "malformed")


async def test_over_budget_is_an_error_not_an_empty_or_demo_receipt() -> None:
    guard = FakeGuard(deny=True)
    g, t = guarded(guard, "receipt_read")
    with pytest.raises(AIResting) as err:
        await g.read_receipt(REQUEST)
    assert err.value.message == RESTING_RECEIPT_MESSAGE and err.value.code == "AI_RESTING"
    assert g.notice is not None and g.notice.reason == "user_daily_cap"
    assert t.calls == [] and guard.reserved == [] and guard.settled == []
