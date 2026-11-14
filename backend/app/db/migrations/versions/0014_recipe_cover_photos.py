"""Recipe cover photos: cover_media_id on drafts, versions and recipes, stock photo columns
(brief 019 PR 2a)

Revision ID: 0014
Revises: 0013
Create Date: 2026-11-14

All columns are nullable, so no backfill and no version rewrite: ``ADD COLUMN`` does not fire
the ``recipe_versions`` immutability trigger (it is ``BEFORE UPDATE OR DELETE``).
"""
from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op


revision: str = '0014'
down_revision: str | None = '0013'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_COVER_TABLES = ('recipe_drafts', 'recipe_versions', 'recipes')


def upgrade() -> None:
    for table in _COVER_TABLES:
        op.add_column(table, sa.Column('cover_media_id', sa.UUID(), nullable=True))
        op.create_foreign_key(
            op.f(f'fk_{table}_cover_media_id_recipe_media'), table, 'recipe_media',
            ['cover_media_id'], ['id'], ondelete='SET NULL',
        )
    op.add_column('recipes', sa.Column('stock_photo_url', sa.Text(), nullable=True))
    op.add_column('recipes', sa.Column('stock_photo_credit_name', sa.String(length=200), nullable=True))
    op.add_column('recipes', sa.Column('stock_photo_credit_url', sa.Text(), nullable=True))
    op.add_column('recipes', sa.Column('stock_photo_id', sa.String(length=64), nullable=True))


def downgrade() -> None:
    for column in ('stock_photo_id', 'stock_photo_credit_url', 'stock_photo_credit_name', 'stock_photo_url'):
        op.drop_column('recipes', column)
    for table in reversed(_COVER_TABLES):
        op.drop_constraint(
            op.f(f'fk_{table}_cover_media_id_recipe_media'), table, type_='foreignkey'
        )
        op.drop_column(table, 'cover_media_id')
