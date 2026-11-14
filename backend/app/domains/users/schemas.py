"""Public user DTOs (snake_case JSON, shared with the iOS client)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.core.config import Settings
from app.db.models import User

Entitlement = Literal["free", "paid"]


def entitlement_for(user: User, settings: Settings) -> Entitlement:
    """Which tier this user gets (brief 012). Config-only until StoreKit: no DB column, and the
    beta default is ``paid``. Server AI capabilities gate on this value."""
    del user  # per-user entitlements arrive with purchases (out of scope for brief 012)
    return settings.default_entitlement


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    display_name: str
    preference_units: Literal["us", "metric"]
    created_at: datetime
    entitlement: Entitlement
    # Brief 015: null until onboarding is finished / a role is chosen.
    onboarded_at: datetime | None = None
    role: Literal["cook", "creator"] | None = None

    @classmethod
    def from_model(cls, user: User, settings: Settings) -> UserOut:
        return cls(
            id=user.id,
            display_name=user.display_name,
            preference_units=user.preference_units.value,
            created_at=user.created_at,
            entitlement=entitlement_for(user, settings),
            onboarded_at=user.onboarded_at,
            role=user.role.value if user.role else None,
        )


class UserPatch(BaseModel):
    """``PATCH /me`` (brief 015). Only the role is editable for now."""

    model_config = ConfigDict(extra="forbid")

    role: Literal["cook", "creator"]


_EMAIL_PATTERN = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"


class DevLoginRequest(BaseModel):
    """Step 1: ask for a one-time code. The code is written to the server log only."""

    email: str = Field(min_length=3, max_length=320, pattern=_EMAIL_PATTERN)

    @field_validator("email")
    @classmethod
    def _normalize_email(cls, value: str) -> str:
        return value.strip().lower()


class DevLoginChallengeResponse(BaseModel):
    challenge_id: uuid.UUID
    expires_in_seconds: int
    hint: str = "Check the server log for your sign-in code."
    code: str | None = Field(
        default=None,
        description="Only present when DEV_LOGIN_ECHO_CODE=true in the test environment.",
    )


class DevLoginVerifyRequest(BaseModel):
    """Step 2: prove possession of the logged code."""

    challenge_id: uuid.UUID
    code: str = Field(min_length=6, max_length=6, pattern=r"^[0-9]{6}$")


class AppleSignInRequest(BaseModel):
    """``POST /auth/apple`` (brief 010). ``nonce`` is the raw value the phone generated; Apple's
    token carries its SHA-256. ``display_name`` is only available on a person's first sign-in."""

    model_config = ConfigDict(extra="forbid")

    identity_token: str = Field(min_length=20, max_length=8192)
    nonce: str = Field(min_length=16, max_length=128)
    display_name: str | None = Field(default=None, max_length=120)


class GoogleSignInRequest(BaseModel):
    """``POST /auth/google`` (brief 010). ``nonce`` is the raw value the phone generated; it
    sent Google the SHA-256, which Google copies into the ID token. The name comes from the
    token, never from the request."""

    model_config = ConfigDict(extra="forbid")

    id_token: str = Field(min_length=20, max_length=8192)
    nonce: str = Field(min_length=16, max_length=128)


class TokenResponse(BaseModel):
    access_token: str
    token_type: Literal["bearer"] = "bearer"
    user: UserOut
