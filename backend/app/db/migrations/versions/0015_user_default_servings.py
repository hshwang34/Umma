"""Default servings on the user (brief 020 PR 3)

Revision ID: 0015
Revises: 0014
Create Date: 2026-11-14

Nullable: null means every recipe opens at its own servings, which is today's behaviour.
"""
from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = '0015'
down_revision: str | None = '0014'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('users', sa.Column('default_servings', sa.Integer(), nullable=True))
    op.create_check_constraint(
        op.f('ck_users_default_servings_range'),
        'users',
        'default_servings IS NULL OR default_servings BETWEEN 1 AND 6',
    )


def downgrade() -> None:
    op.drop_constraint(op.f('ck_users_default_servings_range'), 'users', type_='check')
    op.drop_column('users', 'default_servings')
