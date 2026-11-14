"""Servings on the cooking session (brief 020 PR 5)

Revision ID: 0017
Revises: 0016
Create Date: 2026-11-14

Nullable: null means the pinned recipe version's own servings, which is how every session
started before this behaves.
"""
from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = '0017'
down_revision: str | None = '0016'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('cooking_sessions', sa.Column('servings', sa.Integer(), nullable=True))
    op.create_check_constraint(
        op.f('ck_cooking_sessions_servings_positive'),
        'cooking_sessions',
        'servings IS NULL OR servings >= 1',
    )


def downgrade() -> None:
    op.drop_constraint(
        op.f('ck_cooking_sessions_servings_positive'), 'cooking_sessions', type_='check'
    )
    op.drop_column('cooking_sessions', 'servings')
