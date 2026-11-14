"""Lead check FT-671: tokens of found books (contract Д5а)."""

from __future__ import annotations

import threading

import pytest

from app import book_refs
from app.book_refs import MAX_REF_LENGTH, MAX_REFS, REF_TTL_S, BookRefs


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


@pytest.fixture
def clock() -> Clock:
    return Clock()


def numbered() -> object:
    counter = iter(range(1, 10**6))
    return lambda: f"ref-{next(counter)}"


def refs(clock: Clock, **kw: object) -> BookRefs[str]:
    return BookRefs(clock=clock, **kw)  # type: ignore[arg-type]


def test_constants() -> None:
    assert REF_TTL_S == 1800
    assert MAX_REFS == 5000
    assert MAX_REF_LENGTH == 64


def test_a_stored_release_comes_back_by_its_ref(clock: Clock) -> None:
    keeper = refs(clock)
    ref = keeper.put("ref:a", "release-a")
    assert keeper.get(ref) == "release-a"
    assert len(keeper) == 1


def test_reading_does_not_use_the_ref_up(clock: Clock) -> None:
    keeper = refs(clock)
    ref = keeper.put("ref:a", "release-a")
    assert keeper.get(ref) == "release-a"
    assert keeper.get(ref) == "release-a"


def test_refs_are_random_long_and_url_safe() -> None:
    keeper: BookRefs[str] = BookRefs()
    made = {keeper.put(f"k{i}", "v") for i in range(200)}
    assert len(made) == 200
    for ref in made:
        assert 32 <= len(ref) <= MAX_REF_LENGTH
        assert ref.replace("-", "").replace("_", "").isalnum() and ref.isascii()


def test_the_ref_says_nothing_about_the_release() -> None:
    keeper: BookRefs[str] = BookRefs()
    ref = keeper.put("ref:?xt=urn:btih:0123456789abcdef", "Tolstoy War and Peace")
    # Without dashes and underscores: "war-and-peace" is also a leak. Words not shorter
    # than six letters: the ref is random, and the three-letter "war" once appeared
    # by itself (FT-719, ~1 run in 800).
    low = ref.lower().replace("-", "").replace("_", "")
    for leak in ("ref:", "0123456789abcdef", "tolstoy", "warandpeace"):
        assert leak not in low
    assert repr(keeper) == "BookRefs" and str(keeper) == "BookRefs"


def test_different_releases_get_different_refs(clock: Clock) -> None:
    keeper = refs(clock)
    a = keeper.put("ref:a", "release-a")
    b = keeper.put("ref:b", "release-b")
    assert a != b
    assert (keeper.get(a), keeper.get(b)) == ("release-a", "release-b")


def test_the_same_release_keeps_its_ref_and_takes_the_new_value(clock: Clock) -> None:
    keeper = refs(clock)
    first = keeper.put("ref:a", "old")
    second = keeper.put("ref:a", "new")
    assert first == second
    assert keeper.get(first) == "new"
    assert len(keeper) == 1


def test_the_default_life_is_half_an_hour(clock: Clock) -> None:
    keeper = refs(clock)
    ref = keeper.put("ref:a", "release-a")
    clock.now += REF_TTL_S - 1
    assert keeper.get(ref) == "release-a"
    clock.now += 1
    assert keeper.get(ref) is None


def test_an_expired_ref_is_gone_and_forgotten(clock: Clock) -> None:
    keeper = refs(clock, ttl=10)
    ref = keeper.put("ref:a", "release-a")
    clock.now += 9.5
    assert keeper.get(ref) == "release-a"
    clock.now += 0.5
    assert keeper.get(ref) is None
    assert len(keeper) == 0


def test_the_count_does_not_include_the_expired(clock: Clock) -> None:
    keeper = refs(clock, ttl=10)
    keeper.put("ref:a", "release-a")
    clock.now += 5
    keeper.put("ref:b", "release-b")
    clock.now += 5
    assert len(keeper) == 1
    clock.now += 5
    assert len(keeper) == 0


def test_reading_does_not_prolong_the_life(clock: Clock) -> None:
    keeper = refs(clock, ttl=10)
    ref = keeper.put("ref:a", "release-a")
    clock.now += 6
    assert keeper.get(ref) == "release-a"
    clock.now += 6
    assert keeper.get(ref) is None


def test_finding_the_release_again_prolongs_the_life(clock: Clock) -> None:
    keeper = refs(clock, ttl=10)
    ref = keeper.put("ref:a", "release-a")
    clock.now += 6
    assert keeper.put("ref:a", "release-a") == ref
    clock.now += 6
    assert keeper.get(ref) == "release-a"
    clock.now += 4
    assert keeper.get(ref) is None


def test_a_prolonged_ref_outlives_a_younger_one(clock: Clock) -> None:
    keeper = refs(clock, ttl=10)
    a = keeper.put("ref:a", "release-a")
    clock.now += 2
    b = keeper.put("ref:b", "release-b")
    clock.now += 6
    keeper.put("ref:a", "release-a")
    clock.now += 5
    assert keeper.get(b) is None
    assert keeper.get(a) == "release-a"
    assert len(keeper) == 1


def test_a_release_found_after_its_ref_expired_gets_a_new_ref(clock: Clock) -> None:
    keeper = refs(clock, ttl=10, new_ref=numbered())
    old = keeper.put("ref:a", "release-a")
    clock.now += 10
    new = keeper.put("ref:a", "release-a")
    assert (old, new) == ("ref-1", "ref-2")
    assert keeper.get(old) is None
    assert keeper.get(new) == "release-a"


def test_over_the_limit_the_oldest_goes(clock: Clock) -> None:
    keeper = refs(clock, limit=3)
    made = []
    for name in "abcd":
        clock.now += 1
        made.append(keeper.put(f"ref:{name}", name))
    assert len(keeper) == 3
    assert [keeper.get(ref) for ref in made] == [None, "b", "c", "d"]


def test_exactly_at_the_limit_nothing_goes(clock: Clock) -> None:
    keeper = refs(clock, limit=3)
    made = [keeper.put(f"ref:{name}", name) for name in "abc"]
    assert [keeper.get(ref) for ref in made] == ["a", "b", "c"]


def test_over_the_limit_a_refreshed_one_stays(clock: Clock) -> None:
    keeper = refs(clock, limit=2)
    a = keeper.put("ref:a", "a")
    b = keeper.put("ref:b", "b")
    keeper.put("ref:a", "a")
    c = keeper.put("ref:c", "c")
    assert [keeper.get(ref) for ref in (a, b, c)] == ["a", None, "c"]


def test_a_pushed_out_release_can_be_stored_again(clock: Clock) -> None:
    keeper = refs(clock, limit=1, new_ref=numbered())
    keeper.put("ref:a", "a")
    keeper.put("ref:b", "b")
    again = keeper.put("ref:a", "a2")
    assert again == "ref-3"
    assert keeper.get(again) == "a2"
    assert len(keeper) == 1


@pytest.mark.parametrize("limit", [0, -5])
def test_a_senseless_limit_still_keeps_one(clock: Clock, limit: int) -> None:
    keeper = refs(clock, limit=limit)
    ref = keeper.put("ref:a", "a")
    assert keeper.get(ref) == "a"
    keeper.put("ref:b", "b")
    assert len(keeper) == 1


def test_a_repeated_random_string_is_not_given_twice(clock: Clock) -> None:
    answers = iter(["same", "same", "same", "other"])
    keeper = refs(clock, new_ref=lambda: next(answers))
    a = keeper.put("ref:a", "a")
    b = keeper.put("ref:b", "b")
    assert (a, b) == ("same", "other")
    assert (keeper.get(a), keeper.get(b)) == ("a", "b")


@pytest.mark.parametrize("ref", [None, 5, b"ref-1", "", "nope", ["ref-1"], 1.5, True])
def test_a_wrong_ref_gives_nothing(clock: Clock, ref: object) -> None:
    keeper = refs(clock, new_ref=numbered())
    keeper.put("ref:a", "a")
    assert keeper.get(ref) is None


def test_an_overlong_ref_is_refused_without_a_lookup(clock: Clock) -> None:
    long = "x" * (MAX_REF_LENGTH + 1)
    edge = "y" * MAX_REF_LENGTH
    answers = iter([long, edge])
    keeper = refs(clock, new_ref=lambda: next(answers))
    assert keeper.put("ref:a", "a") == long
    assert keeper.put("ref:b", "b") == edge
    assert keeper.get(long) is None
    assert keeper.get(edge) == "b"


def test_the_stored_value_may_be_empty_or_falsy(clock: Clock) -> None:
    keeper: BookRefs[object] = BookRefs(clock=clock)
    ref = keeper.put("ref:a", 0)
    assert keeper.get(ref) == 0 and keeper.get(ref) is not None


def test_two_keepers_do_not_share_refs(clock: Clock) -> None:
    one = refs(clock, new_ref=numbered())
    two = refs(clock, new_ref=numbered())
    ref = one.put("ref:a", "a")
    assert two.get(ref) is None


def test_the_default_clock_does_not_jump_with_the_wall_clock() -> None:
    import time

    assert BookRefs.__init__.__kwdefaults__["clock"] is time.monotonic


def test_many_threads_store_the_same_release_once() -> None:
    keeper: BookRefs[str] = BookRefs()
    got: list[str] = []
    start = threading.Barrier(16)

    def work() -> None:
        start.wait()
        for i in range(200):
            got.append(keeper.put(f"ref:{i % 20}", "v"))

    threads = [threading.Thread(target=work) for _ in range(16)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert len(keeper) == 20
    assert len(set(got)) == 20


def test_the_module_writes_nothing_to_the_log() -> None:
    source = open(book_refs.__file__, encoding="utf-8").read()
    assert "logging" not in source and "print(" not in source
