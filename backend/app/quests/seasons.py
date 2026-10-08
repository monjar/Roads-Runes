"""The four festivals (0.9.0), worked out from the date with no scheduler. Pure.

Spring Festival (25 March), Midsummer (24 June), Harvest (29 September) and
Midwinter (25 December). South of the equator Spring Festival and Harvest swap
dates, and so do Midsummer and Midwinter: the seasons are six months apart. The
hemisphere is the player's (where they usually start).

A festival's window is the 14 days from its day: its SEASON arc is offered while
the window is open. District pay is doubled from the day before a festival to the
day after (three days).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta

SEASONS = ("SPRING", "MIDSUMMER", "HARVEST", "MIDWINTER")
NAMES = {"SPRING": "Spring Festival", "MIDSUMMER": "Midsummer", "HARVEST": "Harvest", "MIDWINTER": "Midwinter"}
NORTH = {"SPRING": (3, 25), "MIDSUMMER": (6, 24), "HARVEST": (9, 29), "MIDWINTER": (12, 25)}
SOUTH = {"SPRING": NORTH["HARVEST"], "HARVEST": NORTH["SPRING"], "MIDSUMMER": NORTH["MIDWINTER"],
         "MIDWINTER": NORTH["MIDSUMMER"]}  # fmt: skip
WINDOW_DAYS = 14
PAY_DOUBLED_DAYS = 1


@dataclass(frozen=True)
class Festival:
    season: str
    day: date

    @property
    def name(self) -> str:
        return NAMES[self.season]

    @property
    def starts_at(self) -> datetime:
        return datetime.combine(self.day, time.min, tzinfo=UTC)

    @property
    def ends_at(self) -> datetime:
        """The moment the window closes: midnight after its fourteenth day."""
        return self.starts_at + timedelta(days=WINDOW_DAYS)

    def open_on(self, today: date) -> bool:
        return self.day <= today < self.day + timedelta(days=WINDOW_DAYS)


def is_south(latitude: float | None) -> bool:
    return latitude is not None and latitude < 0


def festival_dates(year: int, *, south: bool = False) -> dict[str, date]:
    table = SOUTH if south else NORTH
    return {season: date(year, *table[season]) for season in SEASONS}


def festivals_near(today: date, *, south: bool = False) -> list[Festival]:
    """This year's festivals and the ones either side, in date order."""
    out = [
        Festival(season, day)
        for year in (today.year - 1, today.year, today.year + 1)
        for season, day in festival_dates(year, south=south).items()
    ]
    return sorted(out, key=lambda f: f.day)


def current_festival(today: date, *, south: bool = False) -> Festival | None:
    """The festival whose 14-day window is open today, if any."""
    return next((f for f in festivals_near(today, south=south) if f.open_on(today)), None)


def next_festival(today: date, *, south: bool = False) -> Festival:
    return next(f for f in festivals_near(today, south=south) if f.day >= today)


def pay_doubled(today: date, *, south: bool = False) -> bool:
    """District pay is doubled from the day before a festival to the day after."""
    return any(abs((f.day - today).days) <= PAY_DOUBLED_DAYS for f in festivals_near(today, south=south))
