"""Sign in with Apple refresh tokens (brief 010 PR 2)

Revision ID: 0018
Revises: 0017
Create Date: 2026-11-14

One encrypted refresh token per Apple account, kept only so account deletion can revoke it
(App Review guideline 5.1.1(v)). Deleted with the user.
"""
from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = '0018'
down_revision: str | None = '0017'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'apple_credentials',
        sa.Column('user_id', sa.UUID(), nullable=False),
        sa.Column('refresh_token_encrypted', sa.Text(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['user_id'], ['users.id'], name=op.f('fk_apple_credentials_user_id_users'), ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('user_id', name=op.f('pk_apple_credentials')),
    )


def downgrade() -> None:
    op.drop_table('apple_credentials')
