"""Paid voice spend in the ``ai_usage`` ledger, under the existing caps (brief 012 PR 2)."""

from __future__ import annotations

import uuid
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from app.ai.budget import CostGuard, Denial
from app.core.config import Settings
from app.db.engine import make_sessionmaker
from app.db.models import AIUsage, User
from app.voice.metering import SpeechLease, reserve_speech_out


async def _user(db_session: AsyncSession) -> uuid.UUID:
    tag = uuid.uuid4().hex
    user = User(
        email=f"{tag}@example.com", display_name="Cook", auth_provider="dev", auth_subject=tag
    )
    db_session.add(user)
    await db_session.commit()
    return user.id


async def test_speech_lease_reserves_blocks_and_settles_audio_sent(
    engine: AsyncEngine, db_session: AsyncSession, settings: Settings
) -> None:
    guard = CostGuard(make_sessionmaker(engine), settings)
    user_id = await _user(db_session)
    lease = SpeechLease(guard, user_id, "deepgram/nova-3", block_ms=1000)
    for _ in range(5):
        assert await lease.admit(400)  # 2 s of audio in 400 ms frames → 3 blocks
    await lease.close()
    rows = (await db_session.execute(select(AIUsage).order_by(AIUsage.created_at))).scalars().all()
    assert [r.capability for r in rows] == ["voice_stt"] * 3
    assert all(r.status == "settled" for r in rows)
    assert sum(r.input_tokens for r in rows) == 2000 == lease.total_ms
    # The ledger keeps 6 decimal places per row.
    assert abs(sum(r.cost_usd or 0 for r in rows) - Decimal("0.0077") * 2 / 60) < Decimal("3e-6")


async def test_speech_lease_stops_at_the_daily_cap(
    engine: AsyncEngine, db_session: AsyncSession, settings: Settings
) -> None:
    capped = settings.model_copy(update={"ai_user_daily_cap_usd": 0.001})
    guard = CostGuard(make_sessionmaker(engine), capped)
    lease = SpeechLease(guard, await _user(db_session), "deepgram/nova-3", block_ms=5_000)
    assert await lease.admit(4_000)  # a 5 s block reserves $0.00064
    # Block one settles at 4 s ($0.00051); another $0.00064 block would cross $0.001.
    assert not await lease.admit(4_000)
    assert lease.denied == "user_daily_cap"
    assert not await lease.admit(10)
    await lease.close()


async def test_speech_out_reserves_the_full_text(
    engine: AsyncEngine, db_session: AsyncSession, settings: Settings
) -> None:
    guard = CostGuard(make_sessionmaker(engine), settings)
    user_id = await _user(db_session)
    result = await reserve_speech_out(guard, user_id, "elevenlabs/eleven_flash_v2_5", "x" * 500)
    assert not isinstance(result, Denial)
    reservation, meter = result
    assert reservation.ceiling == Decimal("0.02") and meter.units == 500
    await guard.settle(reservation, meter, "ok")
    row = (await db_session.execute(select(AIUsage))).scalar_one()
    assert (row.capability, row.output_tokens, row.cost_usd) == ("voice_tts", 500, Decimal("0.02"))
    big = await reserve_speech_out(guard, user_id, "elevenlabs/eleven_flash_v2_5", "x" * 20_000)
    assert big == Denial("user_daily_cap")
