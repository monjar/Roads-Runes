"""The entry an outing leaves, and the week's notice (docs/ROADMAP.md, 0.6.2 b)."""

from __future__ import annotations

import random
import re
from datetime import date

from app.chronicle.compose import Facts, compose
from app.lore.voice import violations
from app.quests import week
from tests.test_world_objects import ride

NAMES = ["Fen Troll", "Grey Stag", "Bog Wraith", "Stave Hill", "Greenwich Park", "The Crown"]


def varied(n: int) -> list[tuple[Facts, str]]:
    rng = random.Random(7)
    out = []
    for i in range(n):
        distance = rng.choice([1500, 4200, 8000, 12500, 26000, 41000])
        new = rng.choice([0, 0, 3, 12, 40])
        out.append(
            (
                Facts(
                    activity=rng.choice(["RIDE", "RUN", "WALK"]),
                    distance_m=distance,
                    climb_m=rng.choice([0, 40, 180, 420]),
                    new_cells=new,
                    known_share=rng.random() if new else 1.0,
                    places=rng.sample(NAMES[3:], rng.choice([0, 0, 1, 2])),
                    seen_off=rng.sample(NAMES[:3], rng.choice([0, 0, 1])),
                    chests=rng.choice([0, 0, 1, 2]),
                ),
                f"ride-{i}",
            )
        )
    return out


def test_the_same_outing_reads_the_same_and_thirty_do_not_read_alike():
    entries = [compose(f, seed) for f, seed in varied(30)]
    assert entries == [compose(f, seed) for f, seed in varied(30)]
    assert len(set(entries)) == 30
    openings = {e.split(".")[0].split(",")[0].split(" ")[-1] for e in entries}
    assert len({e.split(" ")[0] for e in entries}) >= 4, "every entry opens the same way"
    assert openings


def test_an_entry_keeps_the_voice_and_names_only_what_it_was_given():
    allowed = {"Walter", "Garth", "The", "A", "Out", "It", "Nothing", "That", "Two", "Three"}
    for facts, seed in varied(60):
        entry = compose(facts, seed)
        assert not violations(entry), entry
        given = " ".join(facts.places + facts.seen_off + facts.loosened)
        for word in re.findall(r"\b[A-Z][a-z]+", entry):
            assert word in given or word in allowed or re.search(rf"(^|[.:] ){word}\b", entry), (word, entry)
        # At most one dry turn.
        assert len(entry.split(". ")) <= 7


def test_a_short_outing_has_no_entry_and_the_quarry_leads():
    assert compose(Facts(distance_m=200), "x") == ""
    entry = compose(
        Facts(distance_m=9000, new_cells=4, known_share=0.7, seen_off=["Fen Troll", "Grey Stag"], quarry="Grey Stag",
              quarry_seen_off=True),
        "q",
    )  # fmt: skip
    first_event = entry.split(". ")[1] if ". " in entry else entry
    assert "Grey Stag, which was the point" in entry and entry.index("Grey Stag") < entry.index("Fen Troll"), (
        first_event
    )


def test_the_week_has_one_notice_with_a_fixed_target():
    import uuid

    someone = uuid.uuid4()
    monday, sunday, next_monday = date(2026, 10, 5), date(2026, 10, 11), date(2026, 10, 12)
    assert week.notice_for(someone, monday)["week"] == week.notice_for(someone, sunday)["week"] == "2026-W41"
    assert week.notice_for(someone, monday)["kind"] == week.notice_for(someone, sunday)["kind"]
    assert week.notice_for(someone, next_monday)["week"] == "2026-W42"
    for n in week.NOTICES:
        assert n["target"] > 0 and not violations(n["title"])


async def test_an_outing_writes_its_entry_and_meets_the_week_once(explorer_client, monkeypatch):
    """Outings ridden this week (the shared trace is dated in June)."""
    from tests.test_effort_combat import past

    monkeypatch.setattr(
        week, "NOTICES", ({"kind": "OUTINGS", "title": "One outing this week.", "target": 1, "unit": "outings"},)
    )
    first = await ride(explorer_client, past(1500, 3000))
    assert first["entry"], "an outing of a few kilometres leaves an entry"
    assert first["weekNotice"]["paid"] is True
    assert any(line["kind"] == "WEEK_NOTICE" for line in first["acBreakdown"])
    assert any(line["source"] == "WEEK_NOTICE" for line in first["xpBreakdown"])
    second = await ride(explorer_client, past(1500, 2500, bearing=0))
    assert second["weekNotice"] is None, "paid once a week"
    r = await explorer_client.get("/quests/week")
    assert r.status_code == 200 and r.json()["paid"] is True and r.json()["done"] is True
