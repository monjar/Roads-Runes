"""Legends (docs/ROADMAP.md 0.8.0, Appendix I): the only code that writes `old_ones`.

* **Waking**, with no scheduler: after a journey is processed and whenever the
  legends are asked for. When none is awake and the player has defeated three
  creatures since the last one woke (or slept), the next legend wakes: one asleep
  first, with the health it had; otherwise the next in the table's order that can
  be anchored (legends/anchors.py), skipping the defeated. After all five, the
  second round ("The Fog Dragon II", a quarter more health).
* **The fight**: a journey that comes within reach folds the existing fight model
  (world_objects/fight.py) against the current phase only, whether or not
  effort_combat is on. At most one phase breaks per journey and per day: damage
  past a break is lost, the next phase starts full, and a phase that would break
  on a day one already broke is left with 1. A journey's wound is kept by ride
  id, so a rerun replaces it.
* **Healing and sleep**, on read: a tenth of a phase back per full week left
  alone, never above the phase's health; asleep (off the map) after four weeks.
  It never takes anything from the player.
* **Pay**, once each by key: a phase broken pays coins (kind LEGEND, outside the
  per-journey cap), XP, a Rare item and a treasure map; the last phase pays the
  defeat instead (more coins and XP, a Legendary, the Hard rune, the bane title)
  and a treasure map.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Character
from app.core.activity import normalise
from app.core.errors import Conflict, NotFound
from app.core.geo import haversine_m
from app.core.logging import get_logger
from app.core.security import utcnow
from app.inventory import catalog as runes_catalog
from app.legends import anchors, catalog
from app.legends.models import AWAKE, DEFEATED, DORMANT, OldOne
from app.rides.validation import CleanPoint
from app.routing.engine import RoutingEngine, SyntheticRouter
from app.world_objects import claims, fight
from app.world_objects.models import WorldObject

log = get_logger(__name__)

KIND_WORDS = {"ROAD": "distance", "GROUND": "exploring", "CLIMB": "climbing", "RUNE": "a rune shape", "WORD": "a note"}
STOP_RADIUS_M = 40.0

_engine: RoutingEngine | None = None


async def engine_for(settings: Any) -> RoutingEngine:
    """The routing engine a journey's processing tests reach with (it has no request
    to carry one): synthetic in tests, else built once per process."""
    global _engine
    if getattr(settings, "environment", None) == "test" or getattr(settings, "routing_engine", "") == "synthetic":
        return SyntheticRouter()
    if _engine is None:
        from app.routing.engine import build_engine

        _engine = await build_engine(settings)
    return _engine


# --- reading ---------------------------------------------------------------------


def quiet_since(row: OldOne) -> datetime:
    """When it was last hit, or woke, whichever was later: the healing and sleeping clock."""
    if row.last_hit_at is not None and row.last_hit_at > row.woke_at:
        return row.last_hit_at
    return row.woke_at


def phase_left(row: OldOne, now: datetime) -> int:
    """What is left of the current phase now, healing worked out on read."""
    if row.status == DEFEATED:
        return 0
    if row.status != AWAKE:
        return int(row.phase_hold_left)
    return catalog.healed(int(row.phase_hold_left), int(row.phase_hold_max), quiet_since(row), now)


def health(row: OldOne, now: datetime) -> tuple[int, int]:
    """(left, most) over all three phases."""
    phases = int(catalog.book()["phases"])
    most = int(row.phase_hold_max) * phases
    if row.status == DEFEATED:
        return 0, most
    return phase_left(row, now) + (phases - int(row.phase)) * int(row.phase_hold_max), most


async def legends_of(db: AsyncSession, character: Character) -> list[OldOne]:
    rows = await db.execute(
        select(OldOne).where(OldOne.character_id == character.id).order_by(OldOne.woke_at, OldOne.id)
    )
    return list(rows.scalars())


async def get_legend(db: AsyncSession, character: Character, legend_id: uuid.UUID) -> OldOne:
    row = await db.get(OldOne, legend_id)
    if row is None or row.character_id != character.id:
        raise NotFound("We couldn't find that legend. Go back and try again.", code="NO_SUCH_LEGEND")
    return row


def settle_sleep(row: OldOne, now: datetime) -> bool:
    """A legend left alone four weeks goes to sleep, off the map, with what it had
    healed by then. Returns whether it just fell asleep."""
    if row.status != AWAKE:
        return False
    since = quiet_since(row)
    if not catalog.is_asleep(since, now):
        return False
    row.phase_hold_left = catalog.healed(int(row.phase_hold_left), int(row.phase_hold_max), since, now)
    row.status = DORMANT
    row.payload = {**(row.payload or {}), "sleptAt": now.isoformat()}
    log.info("legend_slept", legend=row.species_id, user=str(row.user_id))
    return True


async def awake(db: AsyncSession, character: Character, now: datetime | None = None) -> OldOne | None:
    """The legend awake now, after putting to sleep any left alone too long."""
    now = now or utcnow()
    found = None
    for row in await legends_of(db, character):
        settle_sleep(row, now)
        if row.status == AWAKE:
            found = row
    await db.flush()
    return found


# --- waking ----------------------------------------------------------------------


def _moment(value: Any) -> datetime | None:
    if isinstance(value, datetime):
        return value
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value))
    except ValueError:
        return None


def last_stirred(rows: list[OldOne]) -> datetime | None:
    """When a legend last woke or fell asleep: creatures count towards the next from then."""
    moments = [r.woke_at for r in rows] + [m for r in rows if (m := _moment((r.payload or {}).get("sleptAt")))]
    return max(moments) if moments else None


async def defeats_since(db: AsyncSession, user_id: uuid.UUID, since: datetime | None) -> int:
    stmt = select(func.count(WorldObject.id)).where(
        WorldObject.user_id == user_id, WorldObject.kind == "MONSTER", WorldObject.status == "CLAIMED"
    )
    if since is not None:
        stmt = stmt.where(WorldObject.claimed_at > since)
    return int(await db.scalar(stmt) or 0)


def next_round(rows: list[OldOne]) -> tuple[int, list[str]]:
    """The round being played and the legends still to wake in it, in order."""
    beaten = {lid: sum(1 for r in rows if r.species_id == lid and r.status == DEFEATED) for lid in catalog.ORDER}
    round_ = min(beaten.values()) + 1
    return round_, [lid for lid in catalog.ORDER if beaten[lid] < round_]


async def creatures_until_next(db: AsyncSession, character: Character) -> int | None:
    """How many more creatures to defeat before a legend wakes; None while one is awake."""
    rows = await legends_of(db, character)
    if any(r.status == AWAKE for r in rows):
        return None
    done = await defeats_since(db, character.user_id, last_stirred(rows))
    return max(0, catalog.wake_after_defeats() - done)


async def maybe_wake(
    db: AsyncSession,
    settings: Any,
    engine: RoutingEngine,
    character: Character,
    *,
    near: tuple[float, float] | None = None,
    now: datetime | None = None,
) -> OldOne | None:
    """Wakes the next legend if it is due (see the module's docstring). Returns the
    one that woke, or None."""
    from app.characters.service import get_rider_profile
    from app.inventory.deeds import usual_start

    now = now or utcnow()
    if await awake(db, character, now) is not None:
        return None
    rows = await legends_of(db, character)
    if await defeats_since(db, character.user_id, last_stirred(rows)) < catalog.wake_after_defeats():
        return None
    asleep = sorted((r for r in rows if r.status == DORMANT), key=lambda r: r.woke_at)
    if asleep:
        row = asleep[0]
        row.status = AWAKE
        row.woke_at = now
        row.payload = {k: v for k, v in (row.payload or {}).items() if k != "sleptAt"}
        await db.flush()
        log.info("legend_woke_again", legend=row.species_id, user=str(character.user_id))
        return row
    centre = await usual_start(db, character.user_id) or near
    if centre is None:
        return None
    activity = normalise((await get_rider_profile(db, character.user_id)).default_activity)
    round_, due = next_round(rows)
    # A waking asks the engine a dozen times at most, whatever is due.
    budget = anchors.Budget(int(catalog.book()["wakeReachTests"]))
    for species_id in due:
        spot = await anchors.find(
            db,
            engine,
            user_id=character.user_id,
            species_id=species_id,
            centre=centre,
            activity=activity,
            resolution=int(settings.h3_resolution),
            budget=budget,
        )
        if spot is None:
            log.info("legend_not_anchored", legend=species_id, user=str(character.user_id))
            continue
        most = catalog.phase_health(round_)
        row = OldOne(
            user_id=character.user_id,
            character_id=character.id,
            species_id=species_id,
            name=catalog.round_name(species_id, round_),
            latitude=spot.latitude,
            longitude=spot.longitude,
            anchor_name=spot.name,
            status=AWAKE,
            phase=1,
            phase_hold_max=most,
            phase_hold_left=most,
            wounds={},
            moved=False,
            woke_at=now,
            payload={"round": round_, "discoveryId": spot.discovery_id},
        )
        db.add(row)
        await db.flush()
        log.info("legend_woke", legend=species_id, round=round_, user=str(character.user_id))
        return row
    return None


def woke_line(row: OldOne) -> dict[str, Any]:
    """The summary's `legendWoke`."""
    return {
        "id": str(row.id),
        "speciesId": row.species_id,
        "name": row.name,
        "icon": catalog.legend(row.species_id)["icon"],
        "line": f"A legend has woken: {row.name[0].lower() + row.name[1:] if row.name.startswith('The ') else row.name}",
    }


# --- moving it ---------------------------------------------------------------------


async def move(
    db: AsyncSession, settings: Any, engine: RoutingEngine, character: Character, legend_id: uuid.UUID
) -> OldOne:
    """The one free move: somewhere else it may live, at least 500 m from here."""
    from app.characters.service import get_rider_profile
    from app.inventory.deeds import usual_start

    row = await get_legend(db, character, legend_id)
    settle_sleep(row, utcnow())
    if row.status != AWAKE:
        raise Conflict("That legend isn't awake, so it can't be moved. Move it while it's awake.", code="NOT_AWAKE")
    if row.moved:
        raise Conflict("You've already moved this legend once. It stays where it is now.", code="ALREADY_MOVED")
    centre = await usual_start(db, character.user_id) or (row.latitude, row.longitude)
    activity = normalise((await get_rider_profile(db, character.user_id)).default_activity)
    spot = await anchors.find(
        db,
        engine,
        user_id=character.user_id,
        species_id=row.species_id,
        centre=centre,
        activity=activity,
        resolution=int(settings.h3_resolution),
        avoid=(row.latitude, row.longitude),
    )
    if spot is None:
        raise Conflict("There's nowhere else near you it can go. It stays where it is for now.", code="NOWHERE_ELSE")
    row.latitude, row.longitude, row.anchor_name = spot.latitude, spot.longitude, spot.name
    row.moved = True
    row.payload = {**(row.payload or {}), "discoveryId": spot.discovery_id, "movedAt": utcnow().isoformat()}
    await db.flush()
    return row


# --- the fight ---------------------------------------------------------------------


def foe_for(row: OldOne, hold_before: float, *, rune_today: bool = False, word_today: bool = False) -> fight.Foe:
    """The current phase as the fight sees it: a creature with the phase's health,
    weak to and resisting what the phase says. Its road form is the phase's own
    rune's shape, when the phase names one."""
    spec = catalog.phase_spec(row.species_id, int(row.phase))
    return fight.Foe(
        latitude=row.latitude,
        longitude=row.longitude,
        hold_max=float(row.phase_hold_max),
        hold_before=float(hold_before),
        wants=tuple(spec["weakTo"]),
        minds=tuple(spec["resists"]),
        road_form=catalog.rune_road_form(spec.get("rune")),
        rune_today=rune_today,
        word_today=word_today,
    )


def rune_hit_for(
    spec: dict[str, Any],
    foe: fight.Foe,
    coords: list[tuple[float, float]],
    woken: list[tuple[float, float, int]],
    sheet: Any,
    cfg: dict[str, Any],
) -> fight.RuneHit | None:
    """What rune lands on this phase, by its `rune` rule: ANY (any shape cut near it,
    or a woken rune in reach, landing as WOKEN does), WOKEN (only a woken rune), or a
    rune's id (only that rune's shape, cut near it). Nothing for a phase not weak to runes."""
    rule = spec.get("rune")
    if rule is None or foe.rune_today:
        return None
    reach = float(sheet.rune_reach_m)
    near_woken = [w for w in woken if haversine_m(w[0], w[1], foe.latitude, foe.longitude) <= reach]
    if rule != catalog.RUNE_WOKEN:
        match = claims.match_rune(
            coords,
            (foe.latitude, foe.longitude),
            threshold=sheet.rune_threshold,
            search_radius_m=reach,
            min_length_m=float(cfg.get("runeMinLengthMeters", 300)),
            max_length_m=float(cfg.get("runeMaxLengthMeters", 4000)),
        )
        if match is not None and rule == catalog.RUNE_ANY and match.shape in runes_catalog.CUT_FORMS:
            return fight.RuneHit(fight.WOKEN, match.end)
        if match is not None and foe.road_form and match.shape == foe.road_form:
            return fight.RuneHit(foe.road_form, match.end)
    if near_woken and rule in (catalog.RUNE_ANY, catalog.RUNE_WOKEN):
        return fight.RuneHit(fight.WOKEN, near_woken[0][2])
    return None


def stops(points: list[CleanPoint], seconds: float) -> list[int]:
    """Where the journey stopped (stayed within 40 m) for at least so long: the fix it
    stopped at, once per stop. For a phase where a stop counts as a note."""
    out: list[int] = []
    i = 0
    while i < len(points):
        j = i
        while (
            j + 1 < len(points)
            and haversine_m(points[i].latitude, points[i].longitude, points[j + 1].latitude, points[j + 1].longitude)
            <= STOP_RADIUS_M
        ):
            j += 1
        if (points[j].timestamp - points[i].timestamp).total_seconds() >= seconds:
            out.append(i)
            i = j + 1
        else:
            i += 1
    return out


def line_for(
    name: str,
    *,
    damage: int,
    left: int,
    broke: bool,
    defeated: bool,
    held_over: bool,
    phase_after: int,
    weak: list[str],
) -> str:
    if defeated:
        return f"{name} is defeated!"
    if broke:
        which = "last" if phase_after >= int(catalog.book()["phases"]) else "second"
        return f"Phase broken! {name} is down to its {which} phase."
    if damage >= 1 and held_over:
        return f"{name} took {damage} damage. Its next phase can only break tomorrow."
    if damage >= 1:
        return f"{name} took {damage} damage. {left} left in this phase."
    wants = " and ".join(KIND_WORDS[k] for k in weak)
    return f"{name} took no damage this time. This phase it's weak to {wants}."


async def fold_ride(
    db: AsyncSession,
    character: Character,
    ride: Any,
    points: list[CleanPoint],
    *,
    new_cell_indices: list[int],
    sheet: Any,
    ended: datetime,
    woken: list[tuple[float, float, int]] | None = None,
) -> dict[str, Any] | None:
    """What this journey did to the awake legend, written as a wound and paid for;
    the summary's `legend`, or None when it never came within reach."""
    from app.world_objects import service as world_objects

    row = await awake(db, character)
    if row is None or row.woke_at > ended or len(points) < 2:
        return None
    ride_id = str(getattr(ride, "id", ""))
    wounds = dict(row.wounds or {})
    previous = wounds.get(ride_id)
    if previous is not None and (previous.get("broke") or int(previous.get("phase", 0)) != int(row.phase)):
        # Counted already, and the legend has moved on since (a phase broke): what it
        # did stands. A rerun on the same phase is folded again and replaces it.
        return dict(previous.get("summary") or {}) or None
    base = world_objects.combat_config()
    if world_objects._made_good_m(points) < float(base["minOutingMeters"]) or await world_objects._overlaps_another(
        db, ride
    ):
        return None
    activity = normalise(getattr(ride, "activity", "RIDE"))
    coords = [(p.latitude, p.longitude) for p in points]
    if woken is None:
        # A rune woken on this outing counts a rank deeper here too, as in the creatures' fold.
        sheet, woken, _ = await world_objects.woken_on(db, ride, sheet, points, coords, ended, record=False)
    first_today = await world_objects._outings_today_before(db, ride) + 1
    quarry = getattr(ride, "quarry_id", None) is not None and getattr(ride, "quarry_id", None) == row.id
    cfg = sheet.legend_cfg(sheet.fight_cfg(base, first_outings_today=first_today), quarry=quarry)
    cfg = {**cfg, "groundMeters": float(catalog.book()["groundMeters"])}
    spec = catalog.phase_spec(row.species_id, int(row.phase))
    day = ended.date()
    left_now = phase_left(row, ended) + (float(previous.get("amount", 0)) if previous is not None else 0.0)
    hold_before = min(float(row.phase_hold_max), left_now)
    today = [w for k, w in wounds.items() if k != ride_id and w.get("day") == day.isoformat()]
    foe = foe_for(
        row,
        hold_before,
        rune_today=any(w.get("runeLanded") for w in today),
        word_today=any(w.get("wordLanded") for w in today),
    )
    words = world_objects._word_indices(points, list(getattr(ride, "encounter_events", None) or []), cfg)
    if sheet.rules.get("STOP_IS_WORD_S"):
        words += await world_objects._stops_as_words(db, points, float(sheet.rules["STOP_IS_WORD_S"]))
    if spec.get("stopIsWord"):
        words += stops(points, float(catalog.book()["stopSeconds"]))
    made_good = world_objects._made_good_m(points)
    report = fight.resolve(
        world_objects._fight_points(points, cfg),
        foe,
        activity=activity,
        damage_pct=sheet.pct_against_legend(made_good_m=made_good, foot=activity in ("RUN", "WALK")),
        cfg=cfg,
        new_cell_indices=new_cell_indices,
        rune_hit=rune_hit_for(spec, foe, coords, woken, sheet, cfg),
        word_indices=sorted(set(words)),
    )
    if report.outcome == "NOT_NEAR":
        return None
    broke = report.outcome == "SEEN_OFF"
    left = 0.0 if broke else float(report.hold_after)
    held_over = False
    if broke and row.last_phase_break_day == day:
        # One phase a day: this one waits for tomorrow, with 1 left.
        broke, left, held_over = False, 1.0, True
    damage = int(round(hold_before - left))
    phase_before = int(row.phase)
    defeated = broke and phase_before >= int(catalog.book()["phases"])
    kinds = {k: int(round(v)) for k, v in report.damage.items() if round(v) > 0}
    if held_over and kinds:
        # Damage past the 1 left is lost, from the last blow back.
        over = sum(kinds.values()) - damage
        for kind in reversed(list(kinds)):
            cut = min(over, kinds[kind])
            kinds[kind] -= cut
            over -= cut
        kinds = {k: v for k, v in kinds.items() if v > 0}
    if damage >= 1:
        row.last_hit_at = max(row.last_hit_at or ended, ended)
    rewards = None
    if broke:
        row.last_phase_break_day = day
        if defeated:
            row.status = DEFEATED
            row.defeated_at = ended
            row.phase_hold_left = 0
        else:
            row.phase = phase_before + 1
            row.phase_hold_left = int(row.phase_hold_max)
        rewards = await _pay(db, character, row, phase_before, getattr(ride, "id", None), defeat=defeated)
    elif damage >= 1 or previous is not None:
        # Written only when hit (the healing clock moved with it) or replacing this
        # journey's own wound: a healed value written untouched would heal twice.
        row.phase_hold_left = int(round(left))
    left_total, most_total = health(row, ended)
    summary = {
        "id": str(row.id),
        "speciesId": row.species_id,
        "name": row.name,
        "icon": catalog.legend(row.species_id)["icon"],
        "phaseBefore": phase_before,
        "phaseAfter": int(row.phase),
        "healthLeft": left_total,
        "healthMax": most_total,
        "phaseHealthLeft": phase_left(row, ended),
        "phaseHealthMax": int(row.phase_hold_max),
        "damage": damage,
        "kinds": kinds,
        "phaseBroken": broke,
        "defeated": defeated,
        "heldOver": held_over,
        "rewards": rewards,
        "line": line_for(
            row.name,
            damage=damage,
            left=int(round(left)),
            broke=broke,
            defeated=defeated,
            held_over=held_over,
            phase_after=int(row.phase),
            weak=list(spec["weakTo"]),
        ),
    }
    wounds[ride_id] = {
        "phase": phase_before,
        "amount": damage,
        "kinds": kinds,
        "day": day.isoformat(),
        "at": ended.isoformat(),
        "runeLanded": report.rune_landed,
        "wordLanded": report.word_landed,
        "broke": broke,
        "summary": {**summary, "rewards": _without_xp(rewards)},
    }
    # Reassigned, not edited in place: the JSON column does not see edits.
    row.wounds = wounds
    await db.flush()
    return summary


def _without_xp(rewards: dict[str, Any] | None) -> dict[str, Any] | None:
    return {k: v for k, v in rewards.items() if k != "_xp"} if rewards else rewards


async def _pay(
    db: AsyncSession, character: Character, row: OldOne, phase: int, ride_id: uuid.UUID | None, *, defeat: bool
) -> dict[str, Any] | None:
    """A phase broken (or the last, the defeat), paid once by `legend:{id}:phase:{n}`."""
    from app.economy import service as economy
    from app.inventory import catalog as runes
    from app.inventory import service as inventory
    from app.progression.engine import XPLine
    from app.progression.service import award_title, grant
    from app.progression.titles import legend_title

    key = f"legend:{row.id}:phase:{phase}"
    if not await inventory.first_time(db, character.user_id, key):
        return None
    spec = catalog.book()["pay"]["defeat" if defeat else "phase"]
    coins, xp = int(spec["coins"]), int(spec["xp"])
    await economy.credit(
        db, character.user_id, coins, "LEGEND", ride_id=ride_id, payload={"legend": row.name, "phase": phase}
    )
    outcome = await grant(
        db,
        character,
        [XPLine("LEGEND_DEFEATED" if defeat else "LEGEND_PHASE", xp, {"legend": row.name, "phase": phase})],
        ride_id=ride_id,
    )
    items = [
        await inventory.give_item(
            db, character, str(spec["rarity"]), key=key, source="LEGEND", ride_id=ride_id, from_name=row.name
        ),
        await inventory.give_consumable(db, character, "TREASURE_MAP", source="LEGEND", from_name=row.name),
    ]
    rune = None
    title = None
    if defeat:
        rune_id = str(catalog.legend(row.species_id)["rune"])
        rune = await inventory.give_rune(db, character, rune_id, key=f"legend:{row.id}:rune", ride_id=ride_id)
        if rune is not None:
            rune = {**rune, "name": runes.name(rune_id)}
        entry = legend_title(row.species_id)
        title = await award_title(db, character, entry["slug"], ride_id=ride_id) if entry else None
    rewards = {"coins": coins, "xp": xp, "items": items, "rune": rune, "title": title}
    db.add(inventory.note_paid(character.user_id, "LEGEND", key, ride_id=ride_id, payload=rewards))
    await db.flush()
    log.info("legend_paid", legend=row.species_id, phase=phase, defeat=defeat, user=str(character.user_id))
    return {**rewards, "_xp": outcome.to_dict()}


# --- out --------------------------------------------------------------------------


def legend_out(row: OldOne, now: datetime, *, journeys: bool = False) -> dict[str, Any]:
    """LegendOut: what the legend page, the map and the phone's fold need."""
    meta = catalog.legend(row.species_id)
    phases = []
    for n, spec in enumerate(meta["phases"], start=1):
        if row.status == DEFEATED or n < int(row.phase):
            left = 0
        elif n == int(row.phase):
            left = phase_left(row, now)
        else:
            left = int(row.phase_hold_max)
        rule = spec.get("rune")
        phases.append(
            {
                "n": n,
                "weakTo": list(spec["weakTo"]),
                "resists": list(spec["resists"]),
                "healthMax": int(row.phase_hold_max),
                "healthLeft": left,
                "broken": left == 0,
                "rune": rule,
                "roadForm": catalog.rune_road_form(rule),
                "stopIsNote": bool(spec.get("stopIsWord")),
            }
        )
    left_total, most_total = health(row, now)
    since = quiet_since(row)
    out = {
        "id": row.id,
        "speciesId": row.species_id,
        "name": row.name,
        "icon": meta["icon"],
        "flavour": meta["flavour"],
        "page": meta["page"],
        "livesAt": meta["livesAt"],
        "latitude": row.latitude,
        "longitude": row.longitude,
        "anchorName": row.anchor_name,
        "status": row.status,
        "phase": int(row.phase),
        "phases": phases,
        "healthLeft": left_total,
        "healthMax": most_total,
        "moved": bool(row.moved),
        "wokeAt": row.woke_at,
        "lastHitAt": row.last_hit_at,
        "defeatedAt": row.defeated_at,
        "healsPerWeek": catalog.heal_per_week(int(row.phase_hold_max)),
        "rune": meta["rune"],
        "sleepsAfterDays": catalog.sleep_after_days(),
        "sleepsAt": since + _days(catalog.sleep_after_days()) if row.status == AWAKE else None,
        "phaseBrokenToday": row.last_phase_break_day == now.date(),
        "round": int((row.payload or {}).get("round") or 1),
    }
    if journeys:
        out["journeys"] = [
            {
                "rideId": rid,
                "date": w.get("day"),
                "damage": int(w.get("amount") or 0),
                "phase": int(w.get("phase") or 1),
            }
            for rid, w in sorted((row.wounds or {}).items(), key=lambda kv: str(kv[1].get("at") or ""))
        ]
    return out


def summary_out(row: OldOne) -> dict[str, Any]:
    meta = catalog.legend(row.species_id)
    return {
        "id": row.id,
        "speciesId": row.species_id,
        "name": row.name,
        "icon": meta["icon"],
        "status": row.status,
        "rune": meta["rune"],
        "wokeAt": row.woke_at,
        "defeatedAt": row.defeated_at,
    }


def _days(n: int) -> timedelta:
    return timedelta(days=n)
