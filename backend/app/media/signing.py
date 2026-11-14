"""Request-scoped signer for media URLs embedded in read models (brief 019 cover photos).

Cards and details are built by plain functions deep in the read side, far from the request
that owns the storage client. Rather than thread a storage handle through every feed, profile
and list call, the v1 router binds one per request (``bind_media_signer``) and ``sign`` reads
it. Presigning is local (no network). Without a bound signer (scripts, unit tests) ``sign``
returns ``None`` and callers fall back to the next cover source.
"""

from __future__ import annotations

from contextvars import ContextVar
from dataclasses import dataclass

from starlette.requests import HTTPConnection

from app.db.models import RecipeMedia
from app.media.storage import ObjectStorage


@dataclass(frozen=True)
class MediaSigner:
    storage: ObjectStorage
    ttl_seconds: int

    def sign(self, row: RecipeMedia) -> str:
        return self.storage.presign_get(
            row.storage_key, expires_in=self.ttl_seconds, content_type=row.mime_type
        )


_signer: ContextVar[MediaSigner | None] = ContextVar("umma_media_signer", default=None)


def bind(signer: MediaSigner | None) -> None:
    _signer.set(signer)


def sign(row: RecipeMedia) -> str | None:
    signer = _signer.get()
    return signer.sign(row) if signer is not None else None


async def bind_media_signer(conn: HTTPConnection) -> None:
    """Router dependency. Async on purpose: it runs in the request's own context, so the value
    is visible to the endpoint (a sync dependency would set it in a worker thread). Takes an
    ``HTTPConnection`` so websocket routes under the router resolve it too."""
    settings = conn.app.state.settings
    bind(MediaSigner(conn.app.state.storage, settings.storage_download_url_ttl_seconds))
