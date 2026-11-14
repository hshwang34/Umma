"""Brief 010 PR 2: ``DELETE /v1/me`` removes the account and everything it owns."""

from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest
from httpx import AsyncClient
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import models as m
from app.db.base import Base
from app.domains.users.deletion import FORMER_CREATOR_NAME, FORMER_CREATOR_PROVIDER
from tests.conftest import bearer

NOW = datetime.now(UTC)
LATER = NOW + timedelta(days=1)

# Every table that holds a user's data: it references ``users`` directly or through another
# owned table. Deleting an account must leave no row of that user in any of them.
# ``ai_usage`` is the one deliberate survivor (user_id nulled; the spend ledger has no content).
OWNED_TABLES = {
    "ai_usage",
    "apple_credentials",
    "capture_events",
    "capture_requests",
    "capture_sessions",
    "cooking_sessions",
    "extraction_jobs",
    "feedback",
    "follows",
    "media_consents",
    "pantry_items",
    "pantry_live_scan_items",
    "pantry_live_scans",
    "pantry_observations",
    "pantry_receipts",
    "recipe_drafts",
    "recipe_media",
    "recipe_variations",
    "recipe_versions",
    "recipes",
    "saves",
    "session_adaptations",
    "session_events",
    "session_messages",
    "session_notes",
    "shopping_items",
    "substitution_suggestions",
    "timers",
    "usage_events",
    "user_preferences",
}


def _tables_reaching_users() -> set[str]:
    owned = {"users"}
    grew = True
    while grew:
        grew = False
        for table in Base.metadata.tables.values():
            if table.name in owned:
                continue
            if any(fk.column.table.name in owned for fk in table.foreign_keys):
                owned.add(table.name)
                grew = True
    return owned - {"users"}


def test_the_owned_table_list_matches_the_schema() -> None:
    """A new table that references users (directly or not) must be added to ``OWNED_TABLES``
    and to ``_populate`` below, which proves account deletion covers it."""
    assert _tables_reaching_users() == OWNED_TABLES


async def _user_id(session: AsyncSession, email: str) -> uuid.UUID:
    return (await session.execute(select(m.User.id).where(m.User.email == email))).scalar_one()


async def _recipe(
    session: AsyncSession, owner: uuid.UUID, slug: str, *, public: bool = True
) -> tuple[m.Recipe, m.RecipeVersion]:
    recipe = m.Recipe(
        id=uuid.uuid4(),
        owner_user_id=owner,
        slug=slug,
        title=slug.title(),
        visibility=m.Visibility.PUBLIC if public else m.Visibility.PRIVATE,
        published_at=NOW,
    )
    session.add(recipe)
    await session.flush()
    version = m.RecipeVersion(
        id=uuid.uuid4(), recipe_id=recipe.id, version_number=1, servings=2, title=recipe.title
    )
    session.add(version)
    await session.flush()
    recipe.latest_version_id = version.id
    await session.flush()
    return recipe, version


async def _populate(session: AsyncSession, user: uuid.UUID, other: uuid.UUID) -> None:
    """At least one row for ``user`` in every table of ``OWNED_TABLES``."""
    other_recipe, other_version = await _recipe(session, other, "bystander-stew")
    recipe, version = await _recipe(session, user, "my-private-soup", public=False)

    def add(*rows: object) -> None:
        session.add_all(rows)

    add(
        m.Follow(follower_id=user, creator_id=other),
        m.Follow(follower_id=other, creator_id=user),
        m.UserPreference(user_id=user, allergies=["peanut"]),
        m.AppleCredential(user_id=user, refresh_token_encrypted="ciphertext"),
        m.UsageEvent(id=uuid.uuid4(), user_id=user, kind="ask"),
        m.AIUsage(
            id=uuid.uuid4(),
            user_id=user,
            capability="coach",
            model="test",
            status="settled",
            reserved_usd=Decimal("0.01"),
        ),
        m.Save(id=uuid.uuid4(), user_id=user, recipe_id=other_recipe.id),
        m.PantryItem(
            id=uuid.uuid4(),
            owner_user_id=user,
            raw_label="eggs",
            normalized_name="egg",
            source=m.PantrySource.MANUAL,
        ),
        m.PantryObservation(
            id=uuid.uuid4(), owner_user_id=user, mode=m.ObservationMode.PHOTO, expires_at=LATER
        ),
        m.PantryReceipt(id=uuid.uuid4(), owner_user_id=user, result_json={}),
        m.RecipeVariation(
            id=uuid.uuid4(),
            owner_user_id=user,
            recipe_id=other_recipe.id,
            recipe_version_id=other_version.id,
            saved_at=NOW,
        ),
        m.SubstitutionSuggestionRecord(
            id=uuid.uuid4(),
            owner_user_id=user,
            recipe_version_id=other_version.id,
            ingredient_ref="ing-1",
            expires_at=LATER,
        ),
    )
    consent = m.MediaConsent(
        id=uuid.uuid4(),
        owner_user_id=user,
        content_id=uuid.uuid4(),
        consent_type="own_video",
        captured_at=NOW,
    )
    draft = m.RecipeDraft(id=uuid.uuid4(), owner_user_id=user, recipe_id=recipe.id)
    scan = m.PantryLiveScan(id=uuid.uuid4(), owner_user_id=user, expires_at=LATER)
    add(consent, draft, scan)
    await session.flush()
    source = m.RecipeMedia(
        id=uuid.uuid4(),
        owner_user_id=user,
        draft_id=draft.id,
        media_kind=m.MediaKind.SOURCE_VIDEO,
        storage_key=f"u/{user}/source.mp4",
        consent_record_id=consent.id,
    )
    add(source)
    await session.flush()
    clip = m.RecipeMedia(
        id=uuid.uuid4(),
        owner_user_id=user,
        recipe_id=recipe.id,
        version_id=version.id,
        source_media_id=source.id,
        media_kind=m.MediaKind.STEP_CLIP,
        storage_key=f"u/{user}/clip.mp4",
    )
    job = m.ExtractionJob(
        id=uuid.uuid4(), owner_user_id=user, draft_id=draft.id, original_media_id=source.id
    )
    add(
        clip,
        job,
        m.PantryLiveScanItem(scan_id=scan.id, key="egg", display_name="Eggs", confidence="high"),
    )
    await session.flush()
    capture = m.CaptureSession(
        id=uuid.uuid4(),
        owner_user_id=user,
        mode="voice",
        draft_id=draft.id,
        extraction_job_id=job.id,
    )
    # One session on the user's own recipe and one on somebody else's.
    own_cook = m.CookingSession(id=uuid.uuid4(), owner_user_id=user, recipe_version_id=version.id)
    cook = m.CookingSession(id=uuid.uuid4(), owner_user_id=user, recipe_version_id=other_version.id)
    add(capture, own_cook, cook)
    await session.flush()
    add(
        m.CaptureEvent(session_id=capture.id, t_ms=0, kind="utterance"),
        m.CaptureRequest(
            session_id=capture.id, idempotency_key="k", request_hash="h" * 64, response_json={}
        ),
        m.SessionEvent(session_id=cook.id, sequence=0, type="started"),
        m.SessionMessage(session_id=cook.id, role=m.MessageRole.USER, text="how long?"),
        m.Timer(session_id=cook.id, step_index=0, label="rice", target_at=LATER),
        m.SessionAdaptation(
            session_id=cook.id,
            ingredient_ref="ing-1",
            original="butter",
            replacement="oil",
            source="rule",
            approved_at=NOW,
        ),
        m.SessionNote(session_id=cook.id, text="less salt"),
        m.ShoppingItem(
            id=uuid.uuid4(),
            owner_user_id=user,
            raw_label="milk",
            normalized_name="milk",
            reason=m.ShoppingReason.MANUAL,
            source_session_id=cook.id,
        ),
        m.Feedback(
            id=uuid.uuid4(),
            user_id=user,
            session_id=cook.id,
            category="bug",
            severity="low",
            details="…",
        ),
    )
    await session.flush()


async def _counts(session: AsyncSession) -> dict[str, int]:
    return {
        name: (await session.execute(text(f'SELECT count(*) FROM "{name}"'))).scalar_one()
        for name in sorted(OWNED_TABLES)
    }


async def test_delete_me_removes_rows_from_every_owned_table(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    doomed = await bearer(client, "doomed@example.com")
    bystander = await bearer(client, "bystander@example.com")
    user = await _user_id(db_session, "doomed@example.com")
    other = await _user_id(db_session, "bystander@example.com")
    await _populate(db_session, user, other)
    # The bystander's own data, which must survive untouched.
    db_session.add(
        m.PantryItem(
            id=uuid.uuid4(),
            owner_user_id=other,
            raw_label="rice",
            normalized_name="rice",
            source=m.PantrySource.MANUAL,
        )
    )
    await db_session.commit()
    before = await _counts(db_session)
    assert all(count >= 1 for count in before.values()), before

    response = await client.delete("/v1/me", headers=doomed)
    assert response.status_code == 204, response.text
    assert response.content == b""

    after = await _counts(db_session)
    survivors = {name: count for name, count in after.items() if count}
    # Left: the bystander's recipe + version + pantry item, and the nulled spend-ledger row.
    assert survivors == {"recipes": 1, "recipe_versions": 1, "pantry_items": 1, "ai_usage": 1}
    assert (await db_session.execute(select(m.AIUsage.user_id))).scalar_one() is None
    assert (await db_session.execute(select(m.PantryItem.owner_user_id))).scalar_one() == other
    users = (await db_session.execute(select(m.User.email))).scalars().all()
    assert users == ["bystander@example.com"]
    # Dev sign-in codes for that email are gone too.
    left = (await db_session.execute(select(m.DevLoginChallenge.email))).scalars().all()
    assert "doomed@example.com" not in left
    # Both media objects are queued for the worker to delete from storage.
    queued = set((await db_session.execute(select(m.MediaDeletion.storage_key))).scalars())
    assert queued == {f"u/{user}/source.mp4", f"u/{user}/clip.mp4"}

    # The old token is dead, the bystander is unaffected, and deleting twice is a plain 401.
    assert (await client.get("/v1/me", headers=doomed)).status_code == 401
    again = await client.delete("/v1/me", headers=doomed)
    assert again.status_code == 401
    assert again.json()["error"]["code"] == "UNAUTHORIZED"
    assert (await client.get("/v1/me", headers=bystander)).status_code == 200
    # Signing in again with the same email is a brand-new, empty account.
    fresh = await bearer(client, "doomed@example.com")
    me = (await client.get("/v1/me", headers=fresh)).json()
    assert me["id"] != str(user)
    assert (await client.get("/v1/pantry", headers=fresh)).json()["items"] == []


async def test_delete_me_needs_a_token(client: AsyncClient) -> None:
    response = await client.delete("/v1/me")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "UNAUTHORIZED"


async def test_recipes_other_people_use_are_kept_anonymously(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    creator = await bearer(client, "creator@example.com")
    cook = await bearer(client, "cook@example.com")
    saver = await bearer(client, "saver@example.com")
    creator_id = await _user_id(db_session, "creator@example.com")
    cook_id = await _user_id(db_session, "cook@example.com")
    saver_id = await _user_id(db_session, "saver@example.com")

    cooked, cooked_v = await _recipe(db_session, creator_id, "cooked-by-someone")
    saved, _ = await _recipe(db_session, creator_id, "saved-by-someone")
    unused, _ = await _recipe(db_session, creator_id, "used-by-nobody")
    clip = m.RecipeMedia(
        id=uuid.uuid4(),
        owner_user_id=creator_id,
        recipe_id=cooked.id,
        version_id=cooked_v.id,
        media_kind=m.MediaKind.STEP_CLIP,
        storage_key="clips/creator-kitchen.mp4",
    )
    session_row = m.CookingSession(
        id=uuid.uuid4(), owner_user_id=cook_id, recipe_version_id=cooked_v.id
    )
    db_session.add_all(
        [clip, session_row, m.Save(id=uuid.uuid4(), user_id=saver_id, recipe_id=saved.id)]
    )
    await db_session.commit()

    assert (await client.delete("/v1/me", headers=creator)).status_code == 204

    owners = dict((await db_session.execute(select(m.Recipe.slug, m.Recipe.owner_user_id))).all())
    assert set(owners) == {"cooked-by-someone", "saved-by-someone"}  # the unused one is gone
    former = (
        await db_session.execute(
            select(m.User).where(m.User.auth_provider == FORMER_CREATOR_PROVIDER)
        )
    ).scalar_one()
    assert set(owners.values()) == {former.id}
    assert former.email is None and former.display_name == FORMER_CREATOR_NAME
    assert await db_session.scalar(select(func.count()).select_from(m.User)) == 3

    # The creator's footage is gone even from a kept recipe.
    assert await db_session.scalar(select(func.count()).select_from(m.RecipeMedia)) == 0
    queued = (await db_session.execute(select(m.MediaDeletion.storage_key))).scalars().all()
    assert queued == ["clips/creator-kitchen.mp4"]

    # The cook's pinned session still opens its version; the saver still sees the recipe.
    pinned = await client.get(f"/v1/recipe-versions/{cooked_v.id}", headers=cook)
    assert pinned.status_code == 200, pinned.text
    assert pinned.json()["creator"]["display_name"] == FORMER_CREATOR_NAME
    listed = (await client.get("/v1/me/saved", headers=saver)).json()["items"]
    assert [card["recipe_id"] for card in listed] == [str(saved.id)]
    assert (await client.get(f"/v1/recipes/{unused.id}", headers=cook)).status_code == 404

    # A second deleted creator reuses the same anonymous account.
    second = await bearer(client, "second@example.com")
    second_id = await _user_id(db_session, "second@example.com")
    another, _ = await _recipe(db_session, second_id, "another-saved")
    db_session.add(m.Save(id=uuid.uuid4(), user_id=saver_id, recipe_id=another.id))
    await db_session.commit()
    assert (await client.delete("/v1/me", headers=second)).status_code == 204
    owner = await db_session.scalar(select(m.Recipe.owner_user_id).where(m.Recipe.id == another.id))
    assert owner == former.id


async def test_nobody_can_sign_in_as_the_former_creator(
    client: AsyncClient, db_session: AsyncSession, caplog: pytest.LogCaptureFixture
) -> None:
    creator = await bearer(client, "creator@example.com")
    saver = await bearer(client, "saver@example.com")
    recipe, _ = await _recipe(db_session, await _user_id(db_session, "creator@example.com"), "r")
    db_session.add(
        m.Save(
            id=uuid.uuid4(),
            user_id=await _user_id(db_session, "saver@example.com"),
            recipe_id=recipe.id,
        )
    )
    await db_session.commit()
    with caplog.at_level(logging.INFO, logger="umma.account"):
        assert (await client.delete("/v1/me", headers=creator)).status_code == 204
    record = next(r for r in caplog.records if r.message == "account deleted")
    assert record.recipes_kept == 1 and record.apple_revoke == "not_apple"
    former = (
        await db_session.execute(
            select(m.User).where(m.User.auth_provider == FORMER_CREATOR_PROVIDER)
        )
    ).scalar_one()
    # It has no email, so the dev code flow (keyed by email) can never resolve to it.
    assert former.email is None
    assert (await client.get("/v1/me", headers=saver)).status_code == 200
