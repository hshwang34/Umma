"""Receipt save rule as pure functions (brief 017 PR 2): hash, line triage, quantity merge."""

from __future__ import annotations

from decimal import Decimal
from pathlib import Path

import pytest

from app.ai.providers.base import ReceiptDraft, ReceiptLine
from app.domains.matching.dictionary import load_dictionary_file
from app.domains.pantry.receipts import Purchase, merged_quantity, read_lines, receipt_hash

D = load_dictionary_file(Path(__file__).resolve().parents[2].parent / "fixtures")


def line(name: str | None, raw: str = "LINE", **kw: object) -> ReceiptLine:
    fields = {"raw_text": raw, "name": name, "is_food": True, "count": 1, "confidence": 0.95}
    return ReceiptLine.model_validate({**fields, **kw})


def draft(*lines: ReceiptLine, **kw: object) -> ReceiptDraft:
    fields = {"purchased_on": "2026-11-14", "store": "Corner Shop", "total": "12.50"}
    return ReceiptDraft.model_validate({**fields, **kw, "lines": list(lines)})


def test_hash_is_date_store_and_total_only() -> None:
    a = draft(line("whole milk"), line("egg", count=2), line(None, raw="GV PRM 4X"))
    # The same receipt read again: a line misread, the store spaced and cased differently.
    b = draft(line("milk"), line(None, raw="EGGS??"), store="  CORNER   shop ", total="12.5")
    assert receipt_hash(a) == receipt_hash(b) and len(receipt_hash(a) or "") == 64


@pytest.mark.parametrize(
    "change",
    [{"purchased_on": "2026-11-13"}, {"store": "Other"}, {"total": "12.51"}],
)
def test_hash_changes_with_date_store_or_total(change: dict) -> None:
    assert receipt_hash(draft(line("milk"))) != receipt_hash(draft(line("milk"), **change))


@pytest.mark.parametrize(
    "missing", [{"purchased_on": None}, {"total": None}, {"purchased_on": None, "total": None}]
)
def test_hash_needs_both_a_date_and_a_total(missing: dict) -> None:
    assert receipt_hash(draft(line("milk"), **missing)) is None
    assert receipt_hash(draft(line("milk"), store=None)) is not None


def bought(count: int = 1, quantity: str | None = None, unit: str | None = None) -> Purchase:
    q = Decimal(quantity) if quantity else None
    return Purchase("milk", "milk", "MILK", count, q, unit, 0.95)


@pytest.mark.parametrize(
    ("existing", "unit", "purchase", "expected"),
    [
        ("2", "kg", bought(quantity="5", unit="kg"), "7"),  # same unit: added
        ("1", None, bought(count=2), "3"),  # pack count onto a unitless quantity: added
        ("500", "g", bought(quantity="1.24", unit="lb"), None),  # other unit: never converted
        ("250", "ml", bought(quantity="1", unit="lb"), None),  # mass onto volume
        ("500", "g", bought(count=2), None),  # a count is not grams
        ("2", None, bought(quantity="1", unit="kg"), None),  # a weight is not a count
        (None, None, bought(count=2), None),  # no amount on file: none invented
        ("999999", None, bought(count=5), None),  # would pass the pantry's quantity limit
    ],
)
def test_merged_quantity(existing, unit, purchase: Purchase, expected) -> None:
    result = merged_quantity(Decimal(existing) if existing else None, unit, purchase)
    assert result == (Decimal(expected) if expected else None)


def test_read_lines_triage_and_combining() -> None:
    purchases, skipped = read_lines(
        draft(
            line("egg", count=2),
            line("whole egg"),  # same ingredient: counts add
            line("chicken thigh", quantity="1.24", unit="LB"),
            line("chicken thigh", quantity="0.5", unit="lb"),
            line("butter", quantity="250", unit="g"),
            line("butter"),  # a weight and a bare pack: falls back to the pack count
            line("garlic", count=None, quantity="3", unit="clove"),  # not a pantry unit
            line(None, raw="GV PRM 4X", confidence=0.2),
            line("xylofruit", raw="XYLOFRUIT"),
            line("milk", raw="MLK?", confidence=0.85),  # the bar is strictly above 0.85
            line(None, raw="PAPER TOWELS", is_food=False),
            line("milk", raw="MILK CRATE", is_food=False),
        ),
        D,
    )
    assert [(p.key, p.count, p.quantity, p.unit) for p in purchases] == [
        ("egg", 3, None, None),
        ("chicken thigh", 2, Decimal("1.74"), "lb"),
        ("butter", 2, None, None),
        ("garlic", 1, None, None),
    ]
    assert [(s.raw_text, s.reason) for s in skipped] == [
        ("GV PRM 4X", "unreadable"),
        ("XYLOFRUIT", "unknown_item"),
        ("MLK?", "low_confidence"),
    ]
