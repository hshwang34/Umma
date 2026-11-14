"""Brief 010 PR 2b: deleting an account revokes its Sign in with Apple token. A revoke that
fails or cannot run never blocks the deletion and never logs the token."""

from __future__ import annotations

import logging

import pytest
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.db.models import AppleCredential
from tests.apple_helpers import BUNDLE_ID, FakeApple
from tests.integration.test_apple_code_exchange import (
    AUTH_CODE,
    REFRESH_TOKEN,
    FakeAppleTokens,
    _app_client,
    _logged,
    _sign_in,
    _users,
)

pytestmark = pytest.mark.usefixtures("clean_tables")


async def test_delete_revokes_the_stored_apple_token(
    settings: Settings, db_session: AsyncSession, caplog: pytest.LogCaptureFixture
) -> None:
    tokens, apple = FakeAppleTokens(), FakeApple()
    async with _app_client(settings, tokens, apple) as client:
        caplog.set_level(logging.DEBUG)  # after create_app, which sets the root level
        headers = await _sign_in(client, apple, authorization_code=AUTH_CODE)
        response = await client.delete("/v1/me", headers=headers)
        assert response.status_code == 204 and response.content == b""
        path, form = tokens.calls[-1]
        assert path == "/auth/revoke"
        assert form["token"] == REFRESH_TOKEN
        assert form["token_type_hint"] == "refresh_token"
        assert form["client_id"] == BUNDLE_ID and form["client_secret"]
        assert await _users(db_session) == 0
        assert await db_session.scalar(select(func.count()).select_from(AppleCredential)) == 0

    record = next(r for r in caplog.records if r.message == "account deleted")
    assert record.apple_revoke == "revoked"
    logged = _logged(caplog)
    assert REFRESH_TOKEN not in logged and AUTH_CODE not in logged


@pytest.mark.parametrize("failure", ["status", "network"])
async def test_a_failed_revoke_never_blocks_deletion_and_logs_no_token(
    settings: Settings, db_session: AsyncSession, caplog: pytest.LogCaptureFixture, failure: str
) -> None:
    tokens, apple = FakeAppleTokens(), FakeApple()
    async with _app_client(settings, tokens, apple) as client:
        caplog.set_level(logging.DEBUG)  # after create_app, which sets the root level
        headers = await _sign_in(client, apple, authorization_code=AUTH_CODE)
        tokens.revoke_status = 500
        tokens.down = failure == "network"
        response = await client.delete("/v1/me", headers=headers)
        assert response.status_code == 204, response.text
        assert tokens.paths() == ["/auth/token", "/auth/revoke"]
        assert await _users(db_session) == 0
        assert (await client.get("/v1/me", headers=headers)).status_code == 401
    record = next(r for r in caplog.records if r.message == "account deleted")
    assert record.apple_revoke == "failed" and record.levelno == logging.WARNING
    logged = _logged(caplog)
    assert REFRESH_TOKEN not in logged and AUTH_CODE not in logged


async def test_without_a_code_sign_in_works_and_delete_skips_the_revoke(
    settings: Settings, db_session: AsyncSession, caplog: pytest.LogCaptureFixture
) -> None:
    tokens, apple = FakeAppleTokens(), FakeApple()
    async with _app_client(settings, tokens, apple) as client:
        headers = await _sign_in(client, apple)  # today's iOS build: no authorization_code
        assert tokens.calls == []
        assert await db_session.scalar(select(func.count()).select_from(AppleCredential)) == 0
        with caplog.at_level(logging.INFO, logger="umma.account"):
            assert (await client.delete("/v1/me", headers=headers)).status_code == 204
        assert tokens.calls == []
        assert await _users(db_session) == 0
    record = next(r for r in caplog.records if r.message == "account deleted")
    assert record.apple_revoke == "skipped_no_token"


async def test_without_apple_key_settings_the_code_is_ignored_and_delete_still_works(
    settings: Settings, db_session: AsyncSession, caplog: pytest.LogCaptureFixture
) -> None:
    apple = FakeApple()
    async with _app_client(settings, None, apple) as client:
        headers = await _sign_in(client, apple, authorization_code=AUTH_CODE)
        assert await db_session.scalar(select(func.count()).select_from(AppleCredential)) == 0
        with caplog.at_level(logging.INFO, logger="umma.account"):
            assert (await client.delete("/v1/me", headers=headers)).status_code == 204
        assert await _users(db_session) == 0
    record = next(r for r in caplog.records if r.message == "account deleted")
    assert record.apple_revoke == "skipped_no_token"
