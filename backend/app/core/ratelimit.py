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

Every table of counters is bounded and nothing is ever cleared wholesale, so a flood from
many addresses can neither grow memory nor un-throttle anyone. A full table first evicts idle
keys. If every key is still active:

* per-IP limiters (``IpLimiter``) degrade instead of locking new callers out: the new caller
  is counted in a coarser bucket (IPv4 /24, IPv6 /48) in a second, smaller table, and if that
  is full too, in one shared overflow bucket. Only the flooding prefix is throttled.
* per-user limiters refuse the new key (keys there are signed-in accounts, not addresses).

IPv6 callers are also capped per /48 on every request, so one allocation cannot fill the
table with distinct /64s.

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
# The most keys one limiter tracks. Full: idle keys are evicted first (see the module docs).
MAX_KEYS = 20_000
# IpLimiter's second table of coarse buckets (IPv4 /24, IPv6 /48), and how many times the
# per-address limit a coarse bucket, or the shared overflow bucket, may carry per minute.
COARSE_MAX_KEYS = 4_000
COARSE_FACTOR = 8
OVERFLOW_KEY = "overflow"
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
        """A full table of active keys refuses a new key (fail closed)."""
        return self.try_allow(key) is True

    def would_allow(self, key: Hashable) -> bool:
        """Whether a hit would be within the limit, without recording one or adding a key.
        (A new key on a full table still answers ``True``: ``try_allow`` decides that.)"""
        if self.limit <= 0:
            return True
        hits = self._hits.get(key)
        if hits is None:
            return True
        now = self._clock()
        return sum(1 for hit in hits if now - hit < WINDOW_SECONDS) < self.limit

    def try_allow(self, key: Hashable) -> bool | None:
        """``True`` allowed, ``False`` over the limit, ``None`` when the key is new and the
        table is full of active keys (the caller decides what a full table means)."""
        if self.limit <= 0:
            return True
        now = self._clock()
        hits = self._hits.get(key)
        if hits is None:
            if len(self._hits) >= self._max_keys:
                self._evict_idle(now)
                if len(self._hits) >= self._max_keys:
                    # Never forget anybody's count: clearing would let a flood lift limits.
                    return None
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


def _coarse(key: str) -> str:
    """The wider bucket for an address key from ``_bucket``: IPv4 /24, IPv6 /48."""
    try:
        if "/" in key:
            return str(ipaddress.ip_network(key).supernet(new_prefix=48))
        return str(ipaddress.ip_network(f"{key}/24", strict=False))
    except ValueError:
        return key  # not an address (an unknown socket peer): its own coarse bucket


class IpLimiter:
    """Per-address limit that degrades, instead of locking out, when its table is full.

    * ``fine``: one bucket per caller (IPv4 address or IPv6 /64), ``limit`` per minute.
    * ``coarse``: one bucket per IPv4 /24 or IPv6 /48, ``limit * COARSE_FACTOR`` per minute,
      in a smaller table. Every IPv6 request is counted here first (a cap per allocation),
      and so is any new caller that arrives while ``fine`` is full of active keys.
    * ``overflow``: a single shared bucket, used only when ``coarse`` is full as well.

    Existing counters are never dropped while active, so a throttled caller stays throttled."""

    def __init__(
        self,
        limit: int,
        *,
        clock: Callable[[], float] = time.monotonic,
        max_keys: int = MAX_KEYS,
        coarse_max_keys: int = COARSE_MAX_KEYS,
    ) -> None:
        self.limit = limit
        wide = limit * COARSE_FACTOR
        self.fine = WindowLimiter(limit, clock=clock, max_keys=max_keys)
        self.coarse = WindowLimiter(wide, clock=clock, max_keys=coarse_max_keys)
        self.overflow = WindowLimiter(wide, clock=clock, max_keys=1)

    def allow(self, key: str) -> bool:
        if self.limit <= 0:
            return True
        if "/" in key:
            # IPv6, check then charge. A /64 already over its own limit is rejected without
            # charging its /48 (it must not starve its neighbours). A request the /48 cap
            # rejects never creates or touches a /64 entry (one allocation cannot fill the
            # fine table). Only a request both allow is counted in both.
            if not self.fine.would_allow(key) or not self._wide(key):
                return False
            return self.fine.try_allow(key) is not False  # full table: the /48 cap stands in
        tracked = self.fine.try_allow(key)
        if tracked is None:
            return self._wide(key)  # full table: the /24 bucket stands in
        return tracked

    def _wide(self, key: str) -> bool:
        wide = self.coarse.try_allow(_coarse(key))
        return self.overflow.allow(OVERFLOW_KEY) if wide is None else wide


@dataclass
class RateLimits:
    sign_in_ip: IpLimiter
    ip: IpLimiter
    user: WindowLimiter
    costly_user: WindowLimiter
    # Review login (brief 010 PR 3): attempts per IP, and across every caller together.
    review_ip: IpLimiter
    review_total: WindowLimiter

    @classmethod
    def from_settings(cls, settings: Settings) -> RateLimits:
        return cls(
            sign_in_ip=IpLimiter(settings.rate_limit_sign_in_per_ip_per_minute),
            ip=IpLimiter(settings.rate_limit_per_ip_per_minute),
            user=WindowLimiter(settings.rate_limit_per_user_per_minute),
            costly_user=WindowLimiter(settings.rate_limit_costly_per_user_per_minute),
            review_ip=IpLimiter(settings.rate_limit_review_login_per_ip_per_minute),
            review_total=WindowLimiter(settings.rate_limit_review_login_total_per_minute),
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


def check_review_login(request: Request) -> None:
    """Every review-login attempt, right or wrong, spends the caller's and the global budget,
    so the code cannot be guessed at speed from one address or from many."""
    limits = _limits(request)
    if not limits.review_ip.allow(client_ip(request)) or not limits.review_total.allow("all"):
        raise RateLimited(TOO_MANY_SIGN_INS)
