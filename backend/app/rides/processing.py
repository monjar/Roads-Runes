"""Post-ride processing job (spec §15, §35, §40, §66).

Steps: validate points → recompute metrics → exploration cells → discoveries →
objective validation → quest completion → XP via the reward service → summary.
Runs in a background job; the API only enqueues it.
"""

from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.between import letters, pledges
from app.characters.models import Character
from app.characters.sheet import CharacterSheet
from app.chronicle.compose import Facts, compose
from app.core.activity import normalise
from app.core.config import Settings
from app.core.errors import InvalidTransition, NotFound, RideInvalidState
from app.core.feature_flags import is_enabled
from app.core.geo import encode_polyline, haversine_m
from app.core.logging import EVENT_EXPLORATION_VALIDATION_FAILED, get_logger
from app.core.security import utcnow
from app.discoveries.models import Discovery
from app.discoveries.service import discoveries_along, mark_found
from app.districts import geo as district_geo
from app.districts import service as districts
from app.economy import service as economy
from app.economy.rules import ACLine, compute_ride_ac
from app.economy.streaks import StreakOutcome, streak_lines, update_streak
from app.exploration.cells import cell_for, traverse
from app.exploration.service import ExplorationOutcome, record_traversal
from app.inventory import catalog as runes_catalog
from app.inventory import deeds, treasure
from app.inventory import service as inventory
from app.legends import service as legends
from app.lore.service import creature_tallies
from app.progression.engine import RideRewardInput, compute_ride_xp
from app.progression.service import grant
from app.quests import story, week
from app.quests.models import QuestInstance, QuestObjective
from app.quests.service import all_required_complete, completion_payload, quest_out
from app.quests.state_machine import assert_transition
from app.rides.models import Ride, RidePoint, RideRoute
from app.rides.validation import CleanPoint, as_raw, check_cell_plausibility, validate_points
from app.social.service import publish
from app.users.models import User
from app.world_objects import lairs
from app.world_objects import service as world_objects
from app.world_objects.claims import match_rune
from app.world_objects.service import ClaimOutcome

log = get_logger(__name__)


def _stopped_at(points: list[CleanPoint], place: tuple[float, float], radius: float, seconds: float) -> bool:
    """Whether the outing stayed within reach of a place for long enough."""
    inside = [p for p in points if haversine_m(place[0], place[1], p.latitude, p.longitude) <= radius]
    if len(inside) < 2:
        return False
    run_start = inside[0]
    last = inside[0]
    for p in inside[1:]:
        if (p.timestamp - last.timestamp).total_seconds() > 120:
            run_start = p  # it left and came back: a new stop
        last = p
        if (last.timestamp - run_start.timestamp).total_seconds() >= seconds:
            return True
    return False


def _simplify(points: list[CleanPoint], max_points: int = 1500) -> list[list[float]]:
    if len(points) <= max_points:
        return [[p.longitude, p.latitude] for p in points]
    step = len(points) / max_points
    return [[points[int(i * step)].longitude, points[int(i * step)].latitude] for i in range(max_points)] + [
        [points[-1].longitude, points[-1].latitude]
    ]


def evaluate_objectives(
    quest: QuestInstance,
    points: list[CleanPoint],
    *,
    distance_m: float,
    duration_s: float,
    elevation_gain_m: float,
    new_roads_m: float,
    new_cells: set[str],
    resolution: int,
    client_events: list[dict[str, Any]],
    claims: ClaimOutcome | None = None,
    legend: dict[str, Any] | None = None,
    lair: dict[str, Any] | None = None,
    activity: str = "RIDE",
    districts_done: dict[str, Any] | None = None,
    loop: dict[str, Any] | None = None,
) -> list[QuestObjective]:
    """Server-authoritative objective evaluation against the GPS trace. `legend` and
    `lair` are what this journey did to the legend and a lair (0.8.0), as the
    summary has them. `districts_done` is what it did to districts and `loop` how
    much of each district's edge it touched and whether it came back round (0.9.0)."""
    completed: list[QuestObjective] = []
    coords = [(p.latitude, p.longitude) for p in points]
    start = coords[0] if coords else None
    trace_cells = {cell_for(lat, lon, resolution) for lat, lon in coords[::2]} if coords else set()
    client_by_objective = {str(e.get("objectiveId")): e for e in client_events}

    def visited_within(lat: float, lon: float, radius: float) -> bool:
        return any(haversine_m(lat, lon, plat, plon) <= radius for plat, plon in coords)

    for o in quest.objectives:
        if o.status == "COMPLETED" and not o.provisional:
            continue
        done = False
        t = o.objective_type
        if t in ("VISIT_LOCATION", "VISIT_POI", "VISIT_REGION"):
            if o.target_cells:
                done = any(c in trace_cells for c in o.target_cells)
            elif o.latitude is not None and o.longitude is not None:
                done = visited_within(o.latitude, o.longitude, (o.radius_meters or 60) * 1.25)
            o.progress_current = 1.0 if done else 0.0
        elif t == "VISIT_MULTIPLE_LOCATIONS":
            cells = o.target_cells or []
            hits = sum(1 for c in cells if c in trace_cells)
            if not cells and o.extra.get("cells"):
                hits = sum(
                    1
                    for c in o.extra["cells"]
                    if visited_within(float(c["latitude"]), float(c["longitude"]), o.radius_meters or 250)
                )
            o.progress_current = float(hits)
            done = hits >= (o.target_count or len(cells) or 1)
        elif t == "EXPLORE_NEW_ROADS":
            o.progress_current = min(o.progress_target, new_roads_m)
            done = new_roads_m >= (o.target_meters or 0)
        elif t == "EXPLORE_DISTANCE":
            o.progress_current = min(o.progress_target, new_roads_m)
            done = new_roads_m >= (o.target_meters or 0)
        elif t == "COMPLETE_DISTANCE":
            # A step may ask for a walk (Going Quiet, 0.9.0): a ride does not count.
            wanted = (o.extra or {}).get("activity")
            if not wanted or normalise(activity) == wanted:
                o.progress_current = min(o.progress_target, distance_m)
                done = distance_m >= (o.target_meters or 0)
        elif t in ("REACH_ELEVATION", "COMPLETE_CLIMB"):
            o.progress_current = min(o.progress_target, elevation_gain_m)
            done = elevation_gain_m >= (o.target_elevation_meters or 0)
        elif t == "RETURN_TO_START":
            if start and coords:
                end = coords[-1]
                done = haversine_m(start[0], start[1], end[0], end[1]) <= (o.radius_meters or 300) and distance_m > 1000
            o.progress_current = 1.0 if done else 0.0
        elif t in ("PHOTO_LOCATION", "WRITE_NOTE"):
            # Requires explicit user action; accept the client event if position matches.
            ev = client_by_objective.get(str(o.id))
            if ev is not None:
                if o.latitude is None or ev.get("latitude") is None:
                    done = True
                else:
                    done = (
                        haversine_m(o.latitude, o.longitude, float(ev["latitude"]), float(ev["longitude"]))
                        <= (o.radius_meters or 120) * 1.5
                    )
            o.progress_current = 1.0 if done else 0.0
        elif t == "RIDE_DURATION":
            minutes = duration_s / 60
            o.progress_current = min(o.progress_target, minutes)
            done = minutes >= o.progress_target
        elif t == "SUSTAIN_SPEED":
            # Average speed over the whole ride, so stopping for a café costs pace.
            speed_kmh = (distance_m / 1000) / (duration_s / 3600) if duration_s > 0 else 0.0
            o.progress_current = min(o.progress_target, round(speed_kmh, 1))
            # A short spin does not count: the distance floor lives in extra.
            done = speed_kmh >= o.progress_target and distance_m >= float(o.extra.get("minDistanceMeters", 0))
        elif t == "COMPLETE_ROUTE":
            done = distance_m >= (o.target_meters or 0) * 0.9
            o.progress_current = min(o.progress_target, distance_m)
        elif t == "INSCRIBE_RUNE" and o.latitude is not None and o.longitude is not None:
            form = str((o.extra or {}).get("roadForm") or "LOOP")
            radius = float(o.radius_meters or 1500)
            if form == "NOTE":
                # A note of a few words written within reach of the place.
                ev = client_by_objective.get(str(o.id))
                done = bool(
                    ev is not None
                    and len(str(ev.get("note") or "").strip()) >= 12
                    and (
                        ev.get("latitude") is None
                        or haversine_m(o.latitude, o.longitude, float(ev["latitude"]), float(ev["longitude"]))
                        <= radius * 1.5
                    )
                )
            elif form == "STOP":
                done = _stopped_at(
                    points, (o.latitude, o.longitude), radius, float((o.extra or {}).get("stopSeconds", 300))
                )
            else:
                match = match_rune(coords, (o.latitude, o.longitude), threshold=0.25, search_radius_m=radius)
                done = match is not None and match.shape == form
                if done:
                    shape = coords[match.start : match.end + 1]
                    o.extra = {
                        **(o.extra or {}),
                        "cutAt": [sum(p[0] for p in shape) / len(shape), sum(p[1] for p in shape) / len(shape)],
                    }
            o.progress_current = 1.0 if done else 0.0
        elif t == "CARRY" and o.latitude is not None and o.longitude is not None:
            to = (o.extra or {}).get("to") or {}
            radius = float(o.radius_meters or 80) * 1.25
            picked = next(
                (i for i, (lat, lon) in enumerate(coords) if haversine_m(o.latitude, o.longitude, lat, lon) <= radius),
                None,
            )
            delivered = picked is not None and any(
                haversine_m(float(to["latitude"]), float(to["longitude"]), lat, lon) <= radius
                for lat, lon in coords[picked:]
            )
            o.progress_current = 2.0 if delivered else (1.0 if picked is not None else 0.0)
            done = bool(delivered)
        elif t == "COMPLETE_WITH_FRIEND":
            done = bool(o.extra.get("friendConfirmed"))
        elif t == "SLAY_MONSTER":
            wanted = str(o.extra.get("objectId") or "")
            slain = [m for m in (claims.claimed_of("MONSTER") if claims else []) if not wanted or str(m.id) == wanted]
            o.progress_current = 1.0 if slain else 0.0
            done = bool(slain)
        elif t == "OPEN_CHEST":
            opened = len(claims.counted_of("CHEST")) if claims else 0
            o.progress_current = float(min(o.progress_target, opened))
            done = opened >= (o.target_count or 1)
        elif t == "COLLECT":
            gathered = len(claims.counted_of("COLLECTABLE")) if claims else 0
            o.progress_current = float(min(o.progress_target, gathered))
            done = gathered >= (o.target_count or 1)
        elif t == "LAIR_VISIT":
            # A lair's great chest opened on this journey (its fifth tile visited).
            visited = int((lair or {}).get("visited") or 0)
            o.progress_current = float(min(o.progress_target, visited))
            done = bool(lair and lair.get("done"))
        elif t == "DISTRICT_TILES":
            done = _district_tiles(o, quest, districts_done)
        elif t == "DISTRICT_LOOP":
            # A loop round a district's edge: back where it began, touching enough of the edge.
            shares = [float(d.get("share") or 0) for d in ((loop or {}).get("shares") or {}).values()]
            best = max(shares, default=0.0)
            o.progress_current = max(float(o.progress_current or 0), min(o.progress_target, round(best * 100, 1)))
            done = bool((loop or {}).get("closed")) and best * 100 >= float(o.progress_target or 60)
        elif t == "WOUND_BOSS":
            # So much damage to the legend on this one journey.
            damage = float((legend or {}).get("damage") or 0)
            o.progress_current = min(o.progress_target, damage)
            done = damage >= float(o.progress_target or 0) > 0
        if done:
            o.status = "COMPLETED"
            o.provisional = False
            if o.completed_at is None:
                o.completed_at = utcnow()
            completed.append(o)
        elif o.status == "COMPLETED" and o.provisional:
            # Client claimed it, trace does not support it.
            o.status = "PENDING"
            o.provisional = False
            o.completed_at = None
    return completed


def _district_tiles(o: QuestObjective, quest: QuestInstance, districts_done: dict[str, Any] | None) -> bool:
    """DISTRICT_TILES (0.9.0): new tiles in the home district (its id is on the
    objective) or in any district, added up over the quest's journeys; or, for
    "new", a district first passed since the quest was taken, explored to a %."""
    extra = o.extra or {}
    entries = list((districts_done or {}).get("districts") or [])
    mode = str(extra.get("district") or "any")
    if mode == "new":
        since = quest.accepted_at or quest.created_at
        best = max(
            (
                float(d.get("percent") or 0)
                for d in entries
                if d.get("_firstPassedAt") is not None and (since is None or d["_firstPassedAt"] >= since)
            ),
            default=0.0,
        )
        o.progress_current = max(float(o.progress_current or 0), min(o.progress_target, best))
        return best >= float(o.progress_target or 25)
    if mode == "home":
        gained = sum(int(d.get("newTiles") or 0) for d in entries if d.get("id") == extra.get("districtId"))
    else:
        gained = sum(int(d.get("newTiles") or 0) for d in entries)
    o.progress_current = min(o.progress_target, float(o.progress_current or 0) + gained)
    return o.progress_current >= o.progress_target


async def _reward_for_ride(
    db: AsyncSession,
    character: Character,
    ride: Ride,
    quest: QuestInstance | None,
    quest_completed: bool,
    objectives_completed: list[QuestObjective],
    exploration: ExplorationOutcome,
    discoveries: list[Discovery],
    claims: ClaimOutcome | None = None,
    sheet: CharacterSheet | None = None,
    far_new_cells: int = 0,
    wrote_note: bool = False,
    days_away: int | None = None,
    regions_completed: int = 0,
) -> dict[str, Any]:
    inp = RideRewardInput(
        character_class=character.character_class,
        quest_completed=quest_completed,
        quest_difficulty=quest.difficulty if quest else None,
        quest_base_xp=quest.base_xp if quest else 0,
        is_story_quest=bool(quest and quest.story_quest_id),
        objectives_completed_required=sum(1 for o in objectives_completed if o.required),
        objectives_completed_optional=sum(1 for o in objectives_completed if not o.required),
        new_cells=len(exploration.new_cells),
        new_cells_explored=exploration.new_explored,
        new_roads_meters=exploration.new_territory_m,
        discovery_categories=[d.category for d in discoveries],
        distance_meters=ride.distance_meters,
        elevation_gain_meters=ride.elevation_gain_meters,
        activity=ride.activity,
        claims=[(o.kind, o.tier, o.bounty) for o in claims.claimed] if claims else [],
        effort=bool(claims and claims.effort),
        blows=list(claims.blows) if claims else [],
        sets_completed=len(claims.sets_completed) if claims else 0,
        xp_mods=dict(sheet.xp_pct) if sheet else {},
        far_new_cells=far_new_cells,
        wrote_note=wrote_note,
        days_away=days_away,
        optional_xp_scale=float(sheet.rules.get("OPTIONAL_XP_SCALE", 1.0)) if sheet else 1.0,
        foot_xp_scale=float(sheet.rules.get("FOOT_XP_SCALE", 1.0)) if sheet else 1.0,
        regions_completed=regions_completed,
    )
    lines = compute_ride_xp(inp)
    outcome = await grant(db, character, lines, ride_id=ride.id, quest_id=quest.id if quest else None)
    return outcome.to_dict()


async def process_ride(db: AsyncSession, settings: Settings, ride_id: uuid.UUID) -> dict[str, Any]:
    ride = await db.get(Ride, ride_id)
    if ride is None:
        raise NotFound("We couldn't find that journey. Go back and try again.")
    if ride.status not in ("UPLOADED", "PROCESSING"):
        raise RideInvalidState(
            "This journey is still recording. Finish it first."
            if ride.status == "RECORDING"
            else "This journey has already been counted."
        )
    ride.status = "PROCESSING"
    await db.flush()
    character = await db.scalar(select(Character).where(Character.user_id == ride.user_id))
    points_rows = (
        (await db.execute(select(RidePoint).where(RidePoint.ride_id == ride.id).order_by(RidePoint.sequence)))
        .scalars()
        .all()
    )
    raw = as_raw(points_rows)
    validation = validate_points(raw, client_distance_m=ride.distance_meters, activity=ride.activity)
    flags = list(validation.flags)
    points = validation.points

    # Authoritative metrics: trust the trace when we have one.
    if points:
        ride.distance_meters = round(
            min(
                ride.distance_meters or validation.computed_distance_m,
                validation.computed_distance_m * 1.05,
            )
            if ride.distance_meters
            else validation.computed_distance_m,
            1,
        )
        if validation.computed_elevation_gain_m and (
            ride.elevation_gain_meters == 0 or ride.elevation_gain_meters > validation.computed_elevation_gain_m * 1.5
        ):
            ride.elevation_gain_meters = round(validation.computed_elevation_gain_m, 1)
        ride.max_speed_mps = round(validation.max_speed_mps, 2)
        if not ride.moving_seconds:
            ride.moving_seconds = validation.moving_seconds
    if ride.moving_seconds:
        ride.average_speed_mps = round(ride.distance_meters / ride.moving_seconds, 2)
    ride.point_count = len(points)

    ended = ride.ended_at or utcnow()
    exploration = ExplorationOutcome()
    traversal = None
    if points:
        traversal = traverse([(p.latitude, p.longitude) for p in points], settings.h3_resolution)
        try:
            exploration = await record_traversal(
                db,
                ride.user_id,
                traversal,
                list(ride.client_cells or []),
                settings.h3_resolution,
                settings.explored_distance_threshold_meters,
                ended,
            )
        except Exception as exc:  # noqa: BLE001
            log.error(EVENT_EXPLORATION_VALIDATION_FAILED, ride_id=str(ride.id), error=str(exc))
            flags.append("EXPLORATION_ERROR")
        if exploration.rejected_client_cells:
            flags.append("REJECTED_CLIENT_CELLS")
        plaus = check_cell_plausibility(len(exploration.new_cells), ride.distance_meters)
        if plaus:
            flags.append(plaus)
    if validation.suspicious:
        # Suspicious rides still count for the journal but earn no exploration or XP.
        exploration = ExplorationOutcome()

    # Ride geometry stored separately.
    if points:
        coords = _simplify(points)
        lats = [c[1] for c in coords]
        lons = [c[0] for c in coords]
        db.add(
            RideRoute(
                ride_id=ride.id,
                coordinates=coords,
                encoded_polyline=encode_polyline((c[1], c[0]) for c in coords),
                min_lat=min(lats),
                min_lon=min(lons),
                max_lat=max(lats),
                max_lon=max(lons),
            )
        )

    # The character as the ride began, not as it is now (characters/sheet.py).
    if ride.loadout_snapshot:
        sheet = CharacterSheet.from_dict(ride.loadout_snapshot)
    else:
        sheet = await inventory.sheet_for(db, character)

    discoveries: list[Discovery] = []
    if points and not validation.suspicious:
        discoveries = await discoveries_along(
            db,
            ride.user_id,
            [(p.latitude, p.longitude) for p in points],
            ride.id,
            ended,
            # Hagalaz (0.8.0): hidden places further from the journey are found.
            radius_m=float(sheet.rules.get("FIND_RADIUS_M", 0.0)) or None,
        )

    # What the player had met before this outing, for the codex stamp after it.
    met_before = {
        species
        for species, tally in (await creature_tallies(db, ride.user_id)).items()
        if tally.seen_off or tally.loosened
    }

    # What the trace passed or beat. Same gate as XP: a suspicious ride wins nothing.
    claims = ClaimOutcome()
    # Where on the trace each new cell was first entered: new ground, as blows.
    new_cell_indices = (
        sorted(traversal.cells[c].first_seq for c in exploration.new_cells if c in traversal.cells)
        if traversal is not None
        else []
    )
    if points and not validation.suspicious:
        effort = is_enabled(settings, "effort_combat")
        claims = await world_objects.claim_from_ride(
            db,
            ride,
            character.character_class if character else "EXPLORER",
            points,
            set(exploration.new_cells),
            list(ride.encounter_events or []),
            resolution=settings.h3_resolution,
            ended=ended,
            effort=effort,
            new_cell_indices=new_cell_indices,
            sheet=sheet,
        )
        flags.extend(f for f in claims.flags if f not in flags)
        claims.tapped = await world_objects.tapped_during(db, ride.user_id, ride.started_at, ended)

    # Rune stones picked up on the way: the rune is held, or a stone towards its next rank.
    runes_found: list[dict[str, Any]] = []
    if character is not None:
        for obj in claims.claimed:
            rune_id = inventory.rune_of_piece(obj.payload) if obj.kind == "COLLECTABLE" else None
            if rune_id:
                found = await inventory.add_stone(db, character, rune_id, key=f"stone:{obj.id}", ride_id=ride.id)
                if found:
                    runes_found.append(found)

    # What creatures defeated and chests opened left behind (0.7.2): seeded by the
    # thing, once per thing, and outside the coin and XP caps. A drop into a full
    # bag is sold on the spot.
    items_found: list[dict[str, Any]] = []
    if character is not None:
        for obj in claims.claimed:
            found = await inventory.drop_for(db, character, obj, sheet=sheet, ride_id=ride.id)
            if found:
                items_found.append(found)
            # A tier-3 chest sometimes holds a treasure map besides (0.8.0).
            treasure_map = await inventory.map_for(db, character, obj, ride_id=ride.id)
            if treasure_map:
                items_found.append(treasure_map)

    # Ground read without being passed: a ring round each new cell (Cartographer,
    # and a Candle Stub worn), and round each place found (Kenaz, inscribed).
    if character is not None and not validation.suspicious:
        try:
            await _reveal_rings(db, settings, character, sheet, exploration, discoveries)
        except Exception as exc:  # noqa: BLE001
            log.error("reveal_failed", ride_id=str(ride.id), error=str(exc)[:200])

    # Legends, lairs and buried treasure (0.8.0), before the quest, whose new
    # objectives read them. Each in its own savepoint: a failure is a Journey's end
    # without it, never a lost journey.
    legend: dict[str, Any] | None = None
    lair: dict[str, Any] | None = None
    treasure_found: dict[str, Any] | None = None
    district_run: dict[str, Any] | None = None
    if character is not None and points and not validation.suspicious:
        legend = await _guarded(
            db,
            character,
            "legend_failed",
            ride,
            legends.fold_ride(
                db,
                character,
                ride,
                points,
                new_cell_indices=new_cell_indices,
                sheet=sheet,
                ended=ended,
            ),
        )
        entered = set(traversal.cells) if traversal is not None else set()
        lair = await _guarded(
            db,
            character,
            "lair_failed",
            ride,
            lairs.progress_on_ride(db, character, ride, entered, ride.started_at or ended, ended),
        )
        treasure_found = await _guarded(
            db,
            character,
            "treasure_failed",
            ride,
            treasure.open_on_ride(db, character, ride, [(p.latitude, p.longitude) for p in points], ended),
        )
        # Districts (0.9.0): every one the journey's tiles were in, brought up to date. A
        # completion pays its purse and title here, and its XP with the journey's.
        district_run = await _guarded(
            db,
            character,
            "districts_failed",
            ride,
            districts.progress_on_ride(
                db,
                character,
                ride,
                cells=entered,
                new_cells=set(exploration.new_cells),
                resolution=settings.h3_resolution,
                ended=ended,
                rules=dict(sheet.rules),
            ),
        )

    quest: QuestInstance | None = None
    quest_completed = False
    objectives_completed: list[QuestObjective] = []
    if ride.quest_id:
        quest = await db.get(QuestInstance, ride.quest_id)
        if (
            quest is not None
            and quest.user_id == ride.user_id
            and quest.status == "ACTIVE"
            and not validation.suspicious
        ):
            loop = await _loop_for(db, settings, quest, points, set(traversal.cells) if traversal is not None else set(),
                                   ride.distance_meters)  # fmt: skip
            objectives_completed = evaluate_objectives(
                quest,
                points,
                distance_m=ride.distance_meters,
                duration_s=float(ride.duration_seconds or 0),
                elevation_gain_m=ride.elevation_gain_meters,
                new_roads_m=exploration.new_territory_m,
                new_cells=set(exploration.new_cells),
                resolution=settings.h3_resolution,
                client_events=list(ride.objective_events or []),
                claims=claims,
                legend=legend,
                lair=lair,
                activity=ride.activity,
                districts_done=district_run,
                loop=loop,
            )
            for o in objectives_completed:
                # A rune cut for a quest is a cut like any other: on the map, in the Hand.
                if o.objective_type == "INSCRIBE_RUNE":
                    form = str((o.extra or {}).get("roadForm") or "")
                    rune_id = (o.extra or {}).get("rune") or (
                        runes_catalog.rune_for_form(form) if form in runes_catalog.CUT_FORMS else None
                    )
                    at = (o.extra or {}).get("cutAt") or [o.latitude, o.longitude]
                    if rune_id and at[0] is not None:
                        await inventory.record_cut(
                            db, ride.user_id, ride_id=ride.id, rune_id=str(rune_id), latitude=float(at[0]),
                            longitude=float(at[1]), source="QUEST", place_name=(o.extra or {}).get("poiName"),
                        )  # fmt: skip
                if o.discovery_id:
                    d = await db.get(Discovery, o.discovery_id)
                    if d is not None:
                        ud = await mark_found(db, ride.user_id, d, ride.id, ended)
                        if ud is not None:
                            discoveries.append(d)
            # Second Chance: one optional objective missed counts as done.
            if character is not None and all_required_complete(quest):
                forgiven = _forgive_one(quest, character)
                if forgiven is not None:
                    objectives_completed.append(forgiven)
            if all_required_complete(quest):
                assert_transition(quest.status, "COMPLETED")
                quest.status = "COMPLETED"
                quest.completed_at = ended
                quest.ride_id = ride.id
                quest_completed = True
                if character is not None:
                    items_found += await inventory.grant_quest_items(db, character, quest, ride_id=ride.id)
        elif quest is not None and quest.status != "ACTIVE":
            quest = None

    arc: dict[str, Any] | None = None
    reward: dict[str, Any] = {
        "xpAwarded": 0,
        "xpBreakdown": [],
        "levelUps": [],
        "abilitiesUnlocked": [],
        "titlesUnlocked": [],
    }
    if character is not None and not validation.suspicious:
        reward = await _reward_for_ride(
            db,
            character,
            ride,
            quest,
            quest_completed,
            objectives_completed,
            exploration,
            discoveries,
            claims,
            sheet=sheet,
            far_new_cells=_far_cells(points, exploration.new_cells),
            wrote_note=_wrote_note(ride),
            days_away=await _days_away(db, ride),
            regions_completed=len((district_run or {}).get("completed") or []),
        )
    # What a legend's phase paid (0.8.0): its XP, levels and title join the journey's.
    reward = merge_paid_xp(reward, legend)
    # A district complete's title (0.9.0), given by districts.progress_on_ride.
    for name in (district_run or {}).get("titles") or []:
        if name not in reward.get("titlesUnlocked", []):
            reward = {**reward, "titlesUnlocked": [*reward.get("titlesUnlocked", []), name]}

    # Where this leaves them in the arc, if the quest was a step of one: the last
    # step is the arc's ending, with a title, a purse and XP of its own, paid once.
    arc_coins = 0
    # Every finished quest is settled: a cast member's title may come of any notice,
    # and a story step may end its arc.
    if quest_completed and quest is not None and not validation.suspicious:
        owner = await db.get(User, ride.user_id)
        if owner is not None:
            if character is not None:
                cast = await story.cast_titles(db, character, ride_id=ride.id)
                if cast:
                    reward = {**reward, "titlesUnlocked": [*reward.get("titlesUnlocked", []), *cast]}
            arc = await story.settle_arc(db, owner, character, quest, ride_id=ride.id)
            reward, arc_coins = merge_arc(reward, arc)

    # Coins are the other purse: spent on the character where XP is kept. Same
    # gate as XP, so a suspicious ride earns neither.
    coins: dict[str, Any] = {"acAwarded": 0, "acBreakdown": [], "walletBalance": None}
    streak = StreakOutcome(0, 0, extended=False)
    district_pay: dict[str, Any] | None = None
    if character is not None and not validation.suspicious:
        # Days in a row: the outing counts once a day, if it went anywhere.
        streak = await update_streak(db, ride.user_id, ended.date(), ride.distance_meters)
        extra = streak_lines(streak)
        extra += [ACLine("SET_COMPLETED", done["bonusAC"], {"set": done["name"]}) for done in claims.sets_completed]
        coins = await economy.credit_lines(
            db,
            ride.user_id,
            compute_ride_ac(
                activity=normalise(ride.activity),
                distance_meters=ride.distance_meters,
                new_cells=len(exploration.new_cells),
                quest_completed=quest_completed,
                quest_difficulty=quest.difficulty if quest else None,
                claims=[
                    {
                        "id": o.id,
                        "kind": o.kind,
                        "name": o.payload.get("name"),
                        "rewardAC": o.reward_ac,
                        "bounty": o.bounty,
                    }
                    for o in claims.claimed
                ],
                extra_lines=extra,
                coin_pct=sheet.coin_pct,
            ),
            ride_id=ride.id,
            quest_id=quest.id if quest_completed and quest else None,
        )
        if arc_coins and arc is not None:
            # Paid by settle_arc, outside the per-ride cap; shown with the rest.
            coins["acAwarded"] += arc_coins
            coins["acBreakdown"].append({"kind": "STORY_ARC", "ac": arc_coins, "detail": {"arc": arc["arcTitle"]}})
        # A legend's phase, a lair's great chest and buried treasure (0.8.0): paid by
        # their own code, outside the per-ride cap; shown with the rest.
        for kind, paid, name in (
            ("LEGEND", (legend or {}).get("rewards"), (legend or {}).get("name")),
            ("LAIR", (lair or {}).get("rewards"), (lair or {}).get("name")),
            ("TREASURE", treasure_found, (treasure_found or {}).get("name")),
        ):
            if paid and int(paid.get("coins") or 0) > 0:
                coins["acAwarded"] += int(paid["coins"])
                coins["acBreakdown"].append({"kind": kind, "ac": int(paid["coins"]), "detail": {"name": name}})
        # A district complete (0.9.0): its purse, paid by districts.progress_on_ride.
        for name in (district_run or {}).get("completed") or []:
            coins["acAwarded"] += districts.COMPLETE_COINS
            coins["acBreakdown"].append({"kind": "DISTRICT", "ac": districts.COMPLETE_COINS, "detail": {"name": name}})
        # The week's pay for the districts that are yours (0.9.0), on the week's first
        # journey that has one; outside the cap, in its own savepoint.
        district_pay = await _guarded(
            db,
            character,
            "district_pay_failed",
            ride,
            districts.pay_week(
                db,
                character,
                ride,
                day=ride.local_date or (ride.started_at or ended).date(),
                ended=ended,
                rules=dict(sheet.rules),
                south=await _south(db, ride, points),
            ),
        )
        if district_pay:
            coins["acAwarded"] += int(district_pay["coins"])
            coins["acBreakdown"].append(
                {
                    "kind": "DISTRICT_PAY",
                    "ac": int(district_pay["coins"]),
                    "detail": {"districts": district_pay["districts"]},
                }
            )
        for found in [*items_found, *paid_items(legend, lair, treasure_found)]:
            if found.get("soldOnTheSpot") and found.get("soldFor"):
                # Paid by inventory.add_gear, outside the per-ride cap; shown with the rest.
                coins["acAwarded"] += int(found["soldFor"])
                coins["acBreakdown"].append(
                    {"kind": "ITEM_SOLD", "ac": int(found["soldFor"]), "detail": {"name": found["name"]}}
                )
        coins["walletBalance"] = await economy.balance(db, ride.user_id)

    if quest_completed and quest is not None:
        await publish(
            db,
            ride.user_id,
            "FRIEND_QUEST_COMPLETED",
            {"questTitle": quest.title, "difficulty": quest.difficulty},
        )
    for lu in reward.get("levelUps", []):
        await publish(db, ride.user_id, "FRIEND_LEVEL_UP", lu)
    for d in discoveries[:3]:
        await publish(db, ride.user_id, "FRIEND_DISCOVERY", {"name": d.name, "category": d.category})
    if len(exploration.new_cells) >= 10:
        await publish(db, ride.user_id, "FRIEND_NEW_REGION", {"newCells": len(exploration.new_cells)})

    summary = {
        "questTitle": quest.title if quest else None,
        "questId": str(quest.id) if quest else None,
        "questCompleted": quest_completed,
        "questCompletion": {**completion_payload(quest, reward), "storyProgress": arc}
        if quest_completed and quest
        else None,
        "objectivesCompleted": [str(o.id) for o in objectives_completed],
        "xpAwarded": reward["xpAwarded"],
        "xpBreakdown": reward["xpBreakdown"],
        "levelUps": reward["levelUps"],
        "abilitiesUnlocked": reward["abilitiesUnlocked"],
        "titlesUnlocked": reward["titlesUnlocked"],
        "acAwarded": coins["acAwarded"],
        "acBreakdown": coins["acBreakdown"],
        "walletBalance": coins["walletBalance"],
        "worldObjects": claims.to_dict(),
        "quarryId": str(ride.quarry_id) if ride.quarry_id else None,
        "codexFirsts": first_meetings(claims, met_before),
        "runesFound": runes_found + paid_runes(legend, lair),
        "itemsFound": items_found,
        "streak": streak.to_dict(),
        "newCells": len(exploration.new_cells),
        "upgradedCells": len(exploration.upgraded_cells),
        "newTerritoryMeters": round(exploration.new_territory_m, 1),
        "newRoadsMeters": round(exploration.new_territory_m, 1),
        "discoveries": [
            {
                "id": str(d.id),
                "name": d.name,
                "category": d.category,
                "latitude": d.latitude,
                "longitude": d.longitude,
                "source": d.source,
                "discoveredByUser": True,
            }
            for d in discoveries
        ],
        "droppedPoints": validation.dropped_points,
        "flags": flags,
        # 0.8.0: what the journey did to the legend, a lair's tiles visited, and
        # buried treasure found. Absent when there was none.
        **({"legend": legend} if legend else {}),
        **({"lair": lair} if lair else {}),
        **({"treasureFound": treasure_found} if treasure_found else {}),
        # 0.9.0: every district the journey was in, and the week's pay when it was paid.
        "districts": [
            {k: v for k, v in d.items() if not k.startswith("_")} for d in (district_run or {}).get("districts") or []
        ],
        **(
            {
                "districtPay": {
                    "coins": district_pay["coins"],
                    "districts": district_pay["districts"],
                    "doubled": district_pay["doubled"],
                }
            }
            if district_pay
            else {}
        ),
    }
    # The entry: a few written lines about the outing. A failure here is a ride
    # without an entry, never a lost ride.
    try:
        summary["entry"] = compose_entry(ride, summary, claims, quest if quest_completed else None, arc, streak)
    except Exception as exc:  # noqa: BLE001
        log.error("entry_failed", ride_id=str(ride.id), error=str(exc)[:200])

    ride.flags = flags
    ride.processing_result = summary
    ride.processed_at = utcnow()
    ride.status = "FLAGGED" if validation.suspicious else "PROCESSED"
    await db.flush()

    # Deeds, now this outing is processed and counts: the five counts, any threshold
    # newly reached (a deed title), and records beaten. A failure here is an outing
    # without deeds, never a lost outing.
    if character is not None and not validation.suspicious:
        try:
            done = await deeds.update(db, character, ride=ride, points=points, new_cells=len(exploration.new_cells))
            titles = [r["title"] for r in done["reached"] if r.get("title")]
            summary = {**summary, "deeds": done, "titlesUnlocked": [*summary["titlesUnlocked"], *titles]}
            ride.processing_result = summary
            await db.flush()
        except Exception as exc:  # noqa: BLE001
            log.error("deeds_failed", ride_id=str(ride.id), error=str(exc)[:200])

    # The week's notice counts this outing now that it is processed, and pays once.
    if character is not None and not validation.suspicious:
        try:
            paid = await week.settle(
                db,
                ride.user_id,
                (ride.started_at or ended).date(),
                ride_id=ride.id,
                scale=float(sheet.rules.get("WEEK_NOTICE_SCALE", 1.0)),
            )
        except Exception as exc:  # noqa: BLE001
            log.error("week_notice_failed", ride_id=str(ride.id), error=str(exc)[:200])
            paid = None
        if paid is not None:
            summary = {
                **summary,
                "weekNotice": {k: v for k, v in paid.items() if k not in ("startsAt", "endsAt")},
                "xpAwarded": summary["xpAwarded"] + paid["xp"],
                "xpBreakdown": [*summary["xpBreakdown"], {"source": "WEEK_NOTICE", "xp": paid["xp"]}],
                "acAwarded": summary["acAwarded"] + paid["coins"],
                "acBreakdown": [*summary["acBreakdown"], {"kind": "WEEK_NOTICE", "ac": paid["coins"]}],
                "walletBalance": await economy.balance(db, ride.user_id),
            }
            ride.processing_result = summary
            await db.flush()

    # A pledge kept (0.7.3): the creature pledged for the day defeated, or the quest
    # finished. A missed pledge is never mentioned. Each of these two runs in its own
    # savepoint: a failure is a Journey's end without the line, never a lost journey.
    if character is not None and not validation.suspicious:
        kept: dict[str, Any] | None = None
        try:
            async with db.begin_nested():
                kept = await pledges.keep(
                    db,
                    ride,
                    defeated={o.id for o in claims.counted_of("MONSTER")},
                    quest_completed=quest.id if quest_completed and quest is not None else None,
                    ended=ended,
                )
        except Exception as exc:  # noqa: BLE001
            log.error("pledge_failed", ride_id=str(ride.id), error=str(exc)[:200])
            kept = None
        if kept is not None:
            summary = {**summary, "pledge": kept}
            ride.processing_result = summary
            await db.flush()

    # Letters found again (0.7.3): written here a season or more ago, passed within
    # 60 m, shown once. Not a reward, so a flagged journey finds them too.
    letters_found: list[dict[str, Any]] | None = None
    try:
        async with db.begin_nested():
            letters_found = await letters.found_on(db, settings, ride, points, ended)
    except Exception as exc:  # noqa: BLE001
        log.error("letters_failed", ride_id=str(ride.id), error=str(exc)[:200])
        letters_found = None
    if letters_found is not None:
        summary = {**summary, "letters": letters_found}
        ride.processing_result = summary
        await db.flush()

    # A legend wakes (0.8.0) when three creatures have been defeated since the last
    # one: this journey's count now that it is processed.
    if character is not None and not validation.suspicious:
        woke = None
        try:
            async with db.begin_nested():
                engine = await legends.engine_for(settings)
                near = (points[0].latitude, points[0].longitude) if points else None
                woke = await legends.maybe_wake(db, settings, engine, character, near=near)
        except Exception as exc:  # noqa: BLE001
            log.error("legend_wake_failed", ride_id=str(ride.id), error=str(exc)[:200])
            await _settle_after_failure(db, character)
        if woke is not None:
            summary = {**summary, "legendWoke": legends.woke_line(woke)}
            ride.processing_result = summary
            await db.flush()
        # A lair from level 8, one a fortnight: one may be due now this journey is counted.
        near = (points[0].latitude, points[0].longitude) if points else None
        await _guarded(db, character, "lair_offer_failed", ride, lairs.ensure_offered(db, settings, character, near))
    return summary


async def _loop_for(
    db: AsyncSession,
    settings: Settings,
    quest: QuestInstance,
    points: list[CleanPoint],
    cells: set[str],
    distance_m: float,
) -> dict[str, Any] | None:
    """For a quest that asks for a loop round a district's edge (0.9.0): whether the
    journey came back round, and how much of each district's edge it touched."""
    if not any(o.objective_type == "DISTRICT_LOOP" and o.status != "COMPLETED" for o in quest.objectives):
        return None
    try:
        shares = await districts.edge_shares(db, cells, settings.h3_resolution)
    except Exception as exc:  # noqa: BLE001 - a loop not counted, never a lost journey
        log.error("district_loop_failed", quest_id=str(quest.id), error=str(exc)[:200])
        return None
    coords = [(p.latitude, p.longitude) for p in points]
    return {"closed": district_geo.is_closed_loop(coords, distance_m), "shares": shares}


async def _south(db: AsyncSession, ride: Ride, points: list[CleanPoint]) -> bool:
    """South of the equator, where the player usually starts (or this journey did)."""
    from app.inventory.deeds import usual_start
    from app.quests.seasons import is_south

    start = await usual_start(db, ride.user_id)
    if start is None and points:
        start = (points[0].latitude, points[0].longitude)
    return is_south(start[0] if start else None)


async def _guarded(db: AsyncSession, character: Character, event: str, ride: Ride, work: Any) -> Any:
    """Runs one 0.8.0 step in its own savepoint: a failure is logged and is a
    Journey's end without that part, never a lost journey."""
    try:
        async with db.begin_nested():
            return await work
    except Exception as exc:  # noqa: BLE001
        log.error(event, ride_id=str(ride.id), error=str(exc)[:200])
        await _settle_after_failure(db, character)
        return None


async def _settle_after_failure(db: AsyncSession, character: Character) -> None:
    """A rolled-back savepoint expires what it touched; the character is read again
    now, so nothing later in the processing loads it lazily."""
    try:
        await db.refresh(character)
    except Exception as exc:  # noqa: BLE001
        log.error("character_refresh_failed", error=str(exc)[:200])


def merge_paid_xp(reward: dict[str, Any], legend: dict[str, Any] | None) -> dict[str, Any]:
    """Folds what a legend's phase granted (its `_xp`, popped) into the journey's reward."""
    paid = (legend or {}).get("rewards") or {}
    extra = paid.pop("_xp", None)
    if not extra:
        return reward
    titles = [*reward.get("titlesUnlocked", []), *extra["titlesUnlocked"]]
    if paid.get("title") and paid["title"] not in titles:
        titles.append(paid["title"])
    return {
        **reward,
        "xpAwarded": reward.get("xpAwarded", 0) + extra["xpAwarded"],
        "xpBreakdown": [*reward.get("xpBreakdown", []), *extra["xpBreakdown"]],
        "levelUps": [*reward.get("levelUps", []), *extra["levelUps"]],
        "abilitiesUnlocked": [*reward.get("abilitiesUnlocked", []), *extra["abilitiesUnlocked"]],
        "titlesUnlocked": titles,
    }


def paid_items(*outcomes: dict[str, Any] | None) -> list[dict[str, Any]]:
    """The items a legend, a lair or buried treasure gave on this journey."""
    out: list[dict[str, Any]] = []
    for outcome in outcomes:
        if not outcome:
            continue
        paid = outcome.get("rewards") if "rewards" in outcome else outcome
        out += list((paid or {}).get("items") or [])
        if (paid or {}).get("item"):
            out.append(paid["item"])
    return out


def paid_runes(*outcomes: dict[str, Any] | None) -> list[dict[str, Any]]:
    """A Hard rune a legend left or a great chest held, as `runesFound` shows a stone."""
    return [r for o in outcomes if o and (r := (o.get("rewards") or {}).get("rune"))]


async def _reveal_rings(
    db: AsyncSession,
    settings: Settings,
    character: Character,
    sheet: CharacterSheet,
    exploration: ExplorationOutcome,
    discoveries: list[Discovery],
) -> None:
    import h3

    from app.characters import catalog as abilities
    from app.characters.service import ability_map
    from app.exploration.service import reveal

    rings = int(abilities.effect_total(ability_map(character), "FOG_REVEAL_RADIUS_CELLS"))
    rings += int(sheet.rules.get("NEW_TILE_RINGS", 0))
    if rings and exploration.new_cells:
        around = {n for cell in exploration.new_cells for n in h3.grid_disk(cell, rings)} - set(exploration.new_cells)
        await reveal(db, character.user_id, sorted(around), settings.h3_resolution, via="CARTOGRAPHER")
    kenaz = int(sheet.rules.get("REVEAL_RINGS", 0))
    if kenaz and discoveries:
        cells = {cell_for(d.latitude, d.longitude, settings.h3_resolution) for d in discoveries}
        around = {n for cell in cells for n in h3.grid_disk(cell, kenaz)}
        await reveal(db, character.user_id, sorted(around), settings.h3_resolution, via="KENAZ")


def _forgive_one(quest: QuestInstance, character: Character) -> QuestObjective | None:
    """Second Chance: one optional objective of a finished quest counts as done."""
    from app.characters import catalog as abilities
    from app.characters.service import ability_map

    if not abilities.effect_total(ability_map(character), "FORGIVE_OPTIONAL_OBJECTIVE"):
        return None
    missed = next((o for o in quest.objectives if not o.required and o.status != "COMPLETED"), None)
    if missed is None:
        return None
    missed.status = "COMPLETED"
    missed.provisional = False
    missed.completed_at = utcnow()
    missed.extra = {**(missed.extra or {}), "forgiven": True}
    return missed


def first_meetings(claims: ClaimOutcome, met_before: set[str]) -> list[dict[str, Any]]:
    """Creatures seen off or loosened for the first time on this outing."""
    from app.lore import catalog as lore

    met: dict[str, str] = {}
    for obj in claims.claimed:
        if obj.kind == "MONSTER":
            species = lore.species_of(obj.payload)
            if species and species not in met_before:
                met.setdefault(species, str(obj.payload.get("name")))
    for fight in claims.fights:
        species = fight.get("speciesId")
        if species and species not in met_before and fight.get("outcome") in ("SEEN_OFF", "LOOSENED"):
            met.setdefault(species, str(fight.get("name")))
    book = lore.species_by_id()
    return [{"speciesId": s, "name": book.get(s, {}).get("name", n), "metAs": n} for s, n in sorted(met.items())]


def compose_entry(
    ride: Ride,
    summary: dict[str, Any],
    claims: ClaimOutcome,
    quest: QuestInstance | None,
    arc: dict[str, Any] | None,
    streak: StreakOutcome,
) -> str:
    """The facts of the outing, for chronicle.compose; nothing it was not given."""
    world = summary.get("worldObjects") or {}
    fights = world.get("fights") or []
    seen_off = [str(o.payload.get("name")) for o in claims.claimed if o.kind == "MONSTER"]
    loosened = [str(f.get("name")) for f in fights if f.get("outcome") == "LOOSENED" and f.get("name")]
    quarry_name = None
    quarry_seen_off = None
    if ride.quarry_id is not None:
        quarry = next((f for f in fights if f.get("id") == str(ride.quarry_id)), None)
        if quarry is not None:
            quarry_name = str(quarry.get("name"))
            quarry_seen_off = quarry.get("outcome") == "SEEN_OFF"
    distance = float(ride.distance_meters or 0)
    new_m = float(summary.get("newTerritoryMeters") or 0)
    facts = Facts(
        activity=normalise(ride.activity),
        distance_m=distance,
        climb_m=float(ride.elevation_gain_meters or 0),
        new_cells=int(summary.get("newCells") or 0),
        known_share=max(0.0, 1 - new_m / distance) if distance else 1.0,
        places=[str(d["name"]) for d in summary.get("discoveries") or []],
        seen_off=seen_off,
        loosened=loosened,
        chests=sum(1 for o in claims.claimed if o.kind == "CHEST"),
        pieces=sum(1 for o in claims.claimed if o.kind == "COLLECTABLE"),
        quest_title=quest.title if quest is not None else None,
        arc_finished=arc["arcTitle"] if arc and arc.get("arcCompleted") and arc.get("reward") else None,
        quarry=quarry_name,
        quarry_seen_off=quarry_seen_off,
        days_kept=streak.days,
    )
    return compose(facts, seed=str(ride.id))


FAR_CELL_M = 5000.0


def _far_cells(points: list[CleanPoint], new_cells: list[str] | set[str]) -> int:
    """New cells whose centres lie more than 5 km from where the outing began."""
    from app.exploration.cells import cell_center

    if not points or not new_cells:
        return 0
    start = points[0]
    return sum(1 for cell in new_cells if haversine_m(start.latitude, start.longitude, *cell_center(cell)) > FAR_CELL_M)


def _wrote_note(ride: Ride) -> bool:
    """A note of a few words written on the outing: at a creature or for an objective."""
    events = list(ride.encounter_events or []) + list(ride.objective_events or [])
    return any(len(str(e.get("note") or "").strip()) >= 12 for e in events)


async def _days_away(db: AsyncSession, ride: Ride) -> int | None:
    """Days between the outing before this one and this one; None if it is the first."""
    from sqlalchemy import func

    before = await db.scalar(
        select(func.max(Ride.ended_at)).where(
            Ride.user_id == ride.user_id,
            Ride.id != ride.id,
            Ride.status == "PROCESSED",
            Ride.started_at < ride.started_at,
        )
    )
    if before is None or ride.started_at is None:
        return None
    if before.tzinfo is None:
        from datetime import UTC

        before = before.replace(tzinfo=UTC)
    started = ride.started_at if ride.started_at.tzinfo else ride.started_at.replace(tzinfo=before.tzinfo)
    return max(0, (started - before).days)


def merge_arc(reward: dict[str, Any], arc: dict[str, Any] | None) -> tuple[dict[str, Any], int]:
    """Folds an arc's ending (settle_arc) into a ride's or a quest's reward, and
    pops the bookkeeping it carried. Returns the reward and the coins it paid."""
    if arc is None:
        return reward, 0
    extra = arc.pop("_xp", None)
    if extra:
        reward = {
            **reward,
            "xpAwarded": reward.get("xpAwarded", 0) + extra["xpAwarded"],
            "xpBreakdown": [*reward.get("xpBreakdown", []), *extra["xpBreakdown"]],
            "levelUps": [*reward.get("levelUps", []), *extra["levelUps"]],
            "abilitiesUnlocked": [*reward.get("abilitiesUnlocked", []), *extra["abilitiesUnlocked"]],
            "titlesUnlocked": [*reward.get("titlesUnlocked", []), *extra["titlesUnlocked"]],
        }
    paid = arc.get("reward") or {}
    if paid.get("title") and paid["title"] not in reward.get("titlesUnlocked", []):
        reward = {**reward, "titlesUnlocked": [*reward.get("titlesUnlocked", []), paid["title"]]}
    return reward, int(paid.get("ac") or 0)


async def complete_quest_with_ride(
    db: AsyncSession, settings: Settings, user: User, quest: QuestInstance, ride_id: uuid.UUID
) -> dict[str, Any]:
    """Explicit completion call from the client: relies on processed ride data."""
    ride = await db.get(Ride, ride_id)
    if ride is None or ride.user_id != user.id:
        raise NotFound("We couldn't find that journey. Go back and try again.")
    if quest.status == "COMPLETED" and ride.processing_result and ride.processing_result.get("questCompletion"):
        return ride.processing_result["questCompletion"]
    if ride.status in ("UPLOADED", "PROCESSING"):
        raise RideInvalidState(
            "Your journey is still being counted. Wait a moment and try again.", details={"rideId": str(ride.id)}
        )
    if ride.status == "RECORDING":
        raise RideInvalidState("This journey is still recording. Finish it first.")
    assert_transition(quest.status, "COMPLETED")
    if not all_required_complete(quest):
        raise InvalidTransition(
            "Some of this quest's objectives aren't done yet. Finish them, then try again.",
            code="QUEST_OBJECTIVES_INCOMPLETE",
            details={"pending": [str(o.id) for o in quest.objectives if o.required and o.status != "COMPLETED"]},
        )
    quest.status = "COMPLETED"
    quest.completed_at = utcnow()
    quest.ride_id = ride.id
    character = await db.scalar(select(Character).where(Character.user_id == user.id))
    reward = (
        await _reward_for_ride(
            db,
            character,
            ride,
            quest,
            True,
            [o for o in quest.objectives if o.status == "COMPLETED"],
            ExplorationOutcome(),
            [],
        )
        if character
        else {}
    )
    arc = await story.settle_arc(db, user, character, quest, ride_id=ride.id)
    reward, _ = merge_arc(reward, arc)
    items = await inventory.grant_quest_items(db, character, quest, ride_id=ride.id) if character else []
    return {**completion_payload(quest, reward), "storyProgress": arc, "itemsFound": items}


async def complete_quest_without_ride(
    db: AsyncSession, settings: Settings, user: User, quest: QuestInstance
) -> dict[str, Any]:
    """Allowed only when every required objective was validated by a processed ride."""
    assert_transition(quest.status, "COMPLETED")
    if not all_required_complete(quest) or any(o.provisional for o in quest.objectives if o.required):
        raise InvalidTransition(
            "Some objectives haven't been checked yet. Wait until your journey has been counted.",
            code="QUEST_OBJECTIVES_INCOMPLETE",
        )
    quest.status = "COMPLETED"
    quest.completed_at = utcnow()
    character = await db.scalar(select(Character).where(Character.user_id == user.id))
    lines = compute_ride_xp(
        RideRewardInput(
            character_class=character.character_class if character else "EXPLORER",
            quest_completed=True,
            quest_difficulty=quest.difficulty,
            quest_base_xp=quest.base_xp,
        )
    )
    reward = (await grant(db, character, lines, quest_id=quest.id)).to_dict() if character else {}
    arc = await story.settle_arc(db, user, character, quest)
    reward, _ = merge_arc(reward, arc)
    items = await inventory.grant_quest_items(db, character, quest) if character else []
    return {**completion_payload(quest, reward), "storyProgress": arc, "itemsFound": items}


def quest_snapshot(quest: QuestInstance | None) -> dict[str, Any] | None:
    return quest_out(quest).model_dump(mode="json") if quest else None
