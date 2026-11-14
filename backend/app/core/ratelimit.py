"""Request rate limits (brief 010 hardening): per IP address and per signed-in user.

Counters live in this process, like the voice ``SpeakLimiter``. That is correct for one web
machine (see ``docs/release/backend.md``); a second machine would need a shared store. The AI
*spend* limits are separate and durable (``app/ai/budget.py``); these only bound request bursts.

Four budgets, each per minute, each from settings (``0`` switches one off, refused in prod):

* sign-in routes, per IP: guessing and token-replay attempts;
* every ``/v1`` route, per IP: anonymous scraping and floods;
* every authenticated route, per user;
* writes on routes that spend money, storage or provider calls, per user. Those routes (or
  their whole router) are marked with ``Depends(limit_costly)`` from ``app/core/security.py``;
  ``tests/integration/test_rate_limits.py`` fails when a new write route is not classified.

The table of counters is bounded. When it is full only idle keys are evicted; if every key is
still active, new keys are refused (fail closed) and existing counters are never reset, so a
flood from many addresses cannot un-throttle anyone.

Over a budget the answer is the standard envelope: 429 ``RATE_LIMITED``, ``retryable: true``.
"""

from __future__ import annotations

import ipaddress
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
# The most keys one limiter tracks. Full: idle keys are evicted, else new keys are refused.
MAX_KEYS = 20_000
SAFE_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})
UNLIMITED_PATHS = frozenset({"/v1/health"})  # Fly's health check must never be throttled

TOO_MANY_REQUESTS = "Too many requests. Try again in a minute."
TOO_MANY_SIGN_INS = "Too many sign-in attempts. Try again in a minute."


class WindowLimiter:
    """At most ``limit`` hits per key per sliding minute. ``limit <= 0`` allows everything."""

    def __init__(
        self,
        limit: int,
        *,
        clock: Callable[[], float] = time.monotonic,
        max_keys: int = MAX_KEYS,
    ) -> None:
        self.limit = limit
        self._clock = clock
        self._max_keys = max_keys
        self._hits: dict[Hashable, deque[float]] = {}

    def allow(self, key: Hashable) -> bool:
        if self.limit <= 0:
            return True
        now = self._clock()
        hits = self._hits.get(key)
        if hits is None:
            if len(self._hits) >= self._max_keys:
                self._evict_idle(now)
                if len(self._hits) >= self._max_keys:
                    # Every tracked key is active. Refuse the new one rather than forget
                    # anybody's count: clearing here would let a flood lift every limit.
                    return False
            hits = self._hits[key] = deque()
        while hits and now - hits[0] >= WINDOW_SECONDS:
            hits.popleft()
        if len(hits) >= self.limit:
            return False
        hits.append(now)
        return True

    def _evict_idle(self, now: float) -> None:
        """Drop keys with no hit inside the window: forgetting them changes no decision."""
        idle = [k for k, hits in self._hits.items() if not hits or now - hits[-1] >= WINDOW_SECONDS]
        for key in idle:
            del self._hits[key]


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


def _bucket(address: str | None) -> str | None:
    """The rate-limit key for an address, or ``None`` when it is not an IP address.

    IPv4: the address. IPv6: its /64, because one customer is routinely given a whole /64 and
    could otherwise present 2^64 different keys. An IPv4-mapped IPv6 address counts as IPv4."""
    try:
        ip = ipaddress.ip_address((address or "").strip())
    except ValueError:
        return None
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped is not None:
            return str(ip.ipv4_mapped)
        return str(ipaddress.ip_network(f"{ip}/64", strict=False))
    return str(ip)


def client_ip(request: HTTPConnection) -> str:
    """The caller's rate-limit key.

    Behind Fly the socket peer is Fly's proxy, so ``CLIENT_IP_HEADER`` names the header the
    proxy sets itself (``Fly-Client-IP``; a caller cannot forge it). The header is read only
    when that setting is configured, and only when its value is a real IP address: anything
    else falls back to the socket peer, never to the header text. ``X-Forwarded-For`` and
    every other forwarding header are never read."""
    settings: Settings = request.app.state.settings
    if settings.client_ip_header:
        forwarded = _bucket(request.headers.get(settings.client_ip_header))
        if forwarded is not None:
            return forwarded
    peer = request.client.host if request.client else None
    return _bucket(peer) or f"peer:{peer or 'unknown'}"


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
    if not _limits(request).user.allow(user_id):
        raise RateLimited(TOO_MANY_REQUESTS)


def check_costly(request: Request, user_id: uuid.UUID) -> None:
    """Called by ``limit_costly`` for a write on a route that spends money or storage."""
    if request.method not in SAFE_METHODS and not _limits(request).costly_user.allow(user_id):
        raise RateLimited(TOO_MANY_REQUESTS)
