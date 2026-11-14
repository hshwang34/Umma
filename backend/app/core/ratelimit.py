"""Request rate limits (brief 010 hardening): per IP address and per signed-in user.

Counters live in this process, like the voice ``SpeakLimiter``. That is correct for one web
machine (see ``docs/release/backend.md``); a second machine would need a shared store. The AI
*spend* limits are separate and durable (``app/ai/budget.py``); these only bound request bursts.

Four budgets, each per minute, each from settings (``0`` switches one off, refused in prod):

* sign-in routes, per IP: guessing and token-replay attempts;
* every ``/v1`` route, per IP: anonymous scraping and floods;
* every authenticated route, per user;
* writes on the AI, media and capture routes (``COSTLY_PATHS``), per user: the calls that
  cost money or storage. Reads there, such as polling a job, only count as ordinary requests.

Over a budget the answer is the standard envelope: 429 ``RATE_LIMITED``, ``retryable: true``.
"""

from __future__ import annotations

import re
import time
import uuid
from collections import deque
from collections.abc import Callable, Hashable
from dataclasses import dataclass

from fastapi import Request
from starlette.requests import HTTPConnection

from app.core.config import Settings
from app.core.errors import RateLimited

WINDOW_SECONDS = 60.0
# Sweep idle keys once the table is this big, so many distinct IPs cannot grow it forever.
MAX_KEYS = 20_000
SAFE_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})
UNLIMITED_PATHS = frozenset({"/v1/health"})  # Fly's health check must never be throttled
COSTLY_PATHS = re.compile(
    r"^/v1/(?:ai|media|capture|substitutions|voice)/"
    r"|^/v1/pantry/(?:observations|receipts|live-scans)(?:/|$)"
    r"|^/v1/sessions/[^/]+/(?:ask|inspect)$"
    r"|^/v1/recipes/drafts/[^/]+/(?:cover/upload-intents|steps/[^/]+/trim)$"
)

TOO_MANY_REQUESTS = "Too many requests. Try again in a minute."
TOO_MANY_SIGN_INS = "Too many sign-in attempts. Try again in a minute."


class WindowLimiter:
    """At most ``limit`` hits per key per sliding minute. ``limit <= 0`` allows everything."""

    def __init__(self, limit: int, *, clock: Callable[[], float] = time.monotonic) -> None:
        self.limit = limit
        self._clock = clock
        self._hits: dict[Hashable, deque[float]] = {}

    def allow(self, key: Hashable) -> bool:
        if self.limit <= 0:
            return True
        now = self._clock()
        hits = self._hits.get(key)
        if hits is None:
            if len(self._hits) >= MAX_KEYS:
                self._sweep(now)
            hits = self._hits[key] = deque()
        while hits and now - hits[0] >= WINDOW_SECONDS:
            hits.popleft()
        if len(hits) >= self.limit:
            return False
        hits.append(now)
        return True

    def _sweep(self, now: float) -> None:
        idle = [k for k, hits in self._hits.items() if not hits or now - hits[-1] >= WINDOW_SECONDS]
        for key in idle:
            del self._hits[key]
        if len(self._hits) >= MAX_KEYS:
            # Every key is active: a flood from many addresses. Start over rather than grow.
            self._hits.clear()


@dataclass
class RateLimits:
    sign_in_ip: WindowLimiter
    ip: WindowLimiter
    user: WindowLimiter
    costly_user: WindowLimiter

    @classmethod
    def from_settings(cls, settings: Settings) -> RateLimits:
        return cls(
            sign_in_ip=WindowLimiter(settings.rate_limit_sign_in_per_ip_per_minute),
            ip=WindowLimiter(settings.rate_limit_per_ip_per_minute),
            user=WindowLimiter(settings.rate_limit_per_user_per_minute),
            costly_user=WindowLimiter(settings.rate_limit_costly_per_user_per_minute),
        )


def client_ip(request: HTTPConnection) -> str:
    """The caller's address. Behind Fly the peer is Fly's proxy, so ``CLIENT_IP_HEADER`` names
    the header the proxy sets itself (``Fly-Client-IP``; a caller cannot forge it). Without the
    setting, or the header, it is the peer address."""
    settings: Settings = request.app.state.settings
    if settings.client_ip_header:
        forwarded = request.headers.get(settings.client_ip_header, "").strip()
        if forwarded:
            return forwarded[:64]
    return request.client.host if request.client else "unknown"


def _limits(request: HTTPConnection) -> RateLimits:
    return request.app.state.rate_limits


async def limit_ip(request: HTTPConnection) -> None:
    """Router-level dependency for everything under ``/v1``. The voice WebSocket is not
    counted here: it has its own per-user stream limit (``app/voice/stream.py``)."""
    if request.scope["type"] != "http" or request.url.path in UNLIMITED_PATHS:
        return
    if not _limits(request).ip.allow(client_ip(request)):
        raise RateLimited(TOO_MANY_REQUESTS)


async def limit_sign_in(request: Request) -> None:
    """Dependency for the sign-in routers: a tighter per-IP budget, checked before any work."""
    if not _limits(request).sign_in_ip.allow(client_ip(request)):
        raise RateLimited(TOO_MANY_SIGN_INS)


def check_user(request: Request, user_id: uuid.UUID) -> None:
    """Called once per authenticated request, right after the token resolves to a user."""
    limits = _limits(request)
    if not limits.user.allow(user_id):
        raise RateLimited(TOO_MANY_REQUESTS)
    if (
        request.method not in SAFE_METHODS
        and COSTLY_PATHS.search(request.url.path)
        and not limits.costly_user.allow(user_id)
    ):
        raise RateLimited(TOO_MANY_REQUESTS)
