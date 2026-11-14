"""Backfill Pexels stock photos for published recipes without any cover (brief 019).

Run: ``make covers`` (or ``uv run python -m app.scripts.covers``). ``--recipe <id>`` redoes one
recipe, replacing its stored stock photo. Each recipe costs at most two Pexels requests, and
the script sleeps ``--sleep`` seconds (default 40) between recipes, so it stays under Pexels'
200 requests an hour. Without ``PEXELS_API_KEY`` it does nothing.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys
import uuid

from app.core.config import get_settings
from app.core.logging import configure_logging
from app.db.engine import make_engine, make_sessionmaker
from app.domains.recipes import stock_photos

log = logging.getLogger("umma.covers")

DEFAULT_SLEEP_SECONDS = 40.0  # ≤ 2 requests per recipe → ≤ 180 requests an hour


async def run(recipe: uuid.UUID | None, sleep_seconds: float) -> int:
    settings = get_settings()
    client = stock_photos.build_client(settings)
    if client is None:
        return 0
    engine = make_engine(settings.database_url)
    sessionmaker = make_sessionmaker(engine)
    stored = 0
    try:
        if recipe is not None:
            ids = [recipe]
        else:
            async with sessionmaker() as session:
                ids = await stock_photos.recipes_without_cover(session)
        for index, recipe_id in enumerate(ids):
            if index:
                await asyncio.sleep(sleep_seconds)
            if await stock_photos.fill_recipe(
                sessionmaker, client, recipe_id, replace=recipe is not None
            ):
                stored += 1
        log.info("covers backfill done", extra={"recipes": len(ids), "stored": stored})
    finally:
        await engine.dispose()
    return stored


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--recipe", type=uuid.UUID, help="redo one recipe by id")
    parser.add_argument("--sleep", type=float, default=DEFAULT_SLEEP_SECONDS)
    args = parser.parse_args(argv)
    configure_logging(get_settings().log_level)
    stored = asyncio.run(run(args.recipe, args.sleep))
    print(f"stored {stored} stock photo(s)", file=sys.stderr)


if __name__ == "__main__":
    main()
