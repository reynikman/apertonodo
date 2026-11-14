"""In-memory pass (ref) storage for found audiobooks."""

from __future__ import annotations

from collections import OrderedDict
import secrets
import threading
import time
from typing import Callable, Generic, TypeVar

T = TypeVar("T")

REF_TTL_S: float = 1800.0
MAX_REFS: int = 5000
MAX_REF_LENGTH: int = 64


class _Entry(Generic[T]):
    __slots__ = ("expires_at", "key", "ref", "value")

    def __init__(self, ref: str, key: str, value: T, expires_at: float) -> None:
        self.ref = ref
        self.key = key
        self.value = value
        self.expires_at = expires_at


class BookRefs(Generic[T]):
    def __init__(
        self,
        *,
        ttl: float = REF_TTL_S,
        limit: int = MAX_REFS,
        clock: Callable[[], float] = time.monotonic,
        new_ref: Callable[[], str] = secrets.token_urlsafe,
    ) -> None:
        self._ttl = ttl
        self._limit = max(1, limit)
        self._clock = clock
        self._new_ref = new_ref
        self._lock = threading.Lock()
        self._by_ref: OrderedDict[str, _Entry[T]] = OrderedDict()
        self._by_key: dict[str, _Entry[T]] = {}

    def _purge_expired(self, now: float) -> None:
        while self._by_ref:
            first_ref = next(iter(self._by_ref))
            entry = self._by_ref[first_ref]
            if now < entry.expires_at:
                break
            del self._by_ref[first_ref]
            self._by_key.pop(entry.key, None)

    def put(self, key: str, value: T) -> str:
        with self._lock:
            now = self._clock()
            self._purge_expired(now)

            entry = self._by_key.get(key)
            if entry is not None and now < entry.expires_at:
                entry.value = value
                entry.expires_at = now + self._ttl
                self._by_ref.move_to_end(entry.ref)
                return entry.ref

            if entry is not None:
                self._by_ref.pop(entry.ref, None)
                self._by_key.pop(key, None)

            while True:
                ref = self._new_ref()
                if ref not in self._by_ref:
                    break

            while len(self._by_ref) >= self._limit:
                _, oldest_entry = self._by_ref.popitem(last=False)
                self._by_key.pop(oldest_entry.key, None)

            new_entry = _Entry(
                ref=ref,
                key=key,
                value=value,
                expires_at=now + self._ttl,
            )
            self._by_ref[ref] = new_entry
            self._by_key[key] = new_entry
            return ref

    def get(self, ref: object) -> T | None:
        if not isinstance(ref, str) or not ref or len(ref) > MAX_REF_LENGTH:
            return None

        with self._lock:
            now = self._clock()
            self._purge_expired(now)

            entry = self._by_ref.get(ref)
            if entry is None:
                return None
            if now >= entry.expires_at:
                del self._by_ref[ref]
                self._by_key.pop(entry.key, None)
                return None
            return entry.value

    def __len__(self) -> int:
        with self._lock:
            self._purge_expired(self._clock())
            return len(self._by_ref)

    def __repr__(self) -> str:
        return "BookRefs"

    def __str__(self) -> str:
        return "BookRefs"
