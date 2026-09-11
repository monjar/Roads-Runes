"""Seed a development rider with discoveries and quests around a location.

Usage: python scripts/seed_dev.py [--subject rider-1] [--lat 51.49] [--lon -0.04] [--count 6] [--no-pois]

Creates (or reuses) the user the app signs in as through "Developer sign in"
(subject `rider-1` by default), an Explorer character with a gravel bike, a
curated set of discoveries around Rotherhithe when none exist within 15 km of
the location, and tops available quests up to --count from the templates.
Requires DEV_AUTH_ENABLED=true; safe to re-run.
"""

from __future__ import annotations

import argparse
import asyncio

from sqlalchemy import select

import app.db.models  # noqa: F401  # register every mapper before the first query
from app.auth.service import dev_sign_in
from app.characters.schemas import BikeIn, CharacterCreate
from app.characters.service import create_bike, create_character, list_bikes, maybe_character
from app.core.config import get_settings
from app.core.llm import build_llm
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.discoveries.service import nearby
from app.exploration.cells import cell_for
from app.quests.service import generate_quests, list_quests
from app.users.models import User

# Real places around the sample location (south-east London); coordinates are
# approximate. Tags mirror OSM keys so the quest templates can pick them
# (parks, viewpoints, waterside, cafés, trails).
CURATED_POIS: list[tuple[str, str, float, float, dict[str, str]]] = [
    ("Stave Hill", "VIEWPOINT", 51.4978, -0.0447, {"tourism": "viewpoint"}),
    ("Russia Dock Woodland", "NATURE", 51.4991, -0.0418, {"leisure": "park", "water": "pond"}),
    ("Surrey Docks Farm", "NATURE", 51.4992, -0.0326, {"tourism": "attraction", "river": "Thames"}),
    ("Greenland Dock", "NATURE", 51.4933, -0.0362, {"natural": "water", "water": "dock"}),
    ("Southwark Park", "NATURE", 51.4936, -0.0578, {"leisure": "park", "lake": "yes"}),
    ("The Mayflower", "PUB", 51.5011, -0.0533, {"amenity": "pub", "historic": "yes"}),
    ("Brunel Museum", "HISTORICAL", 51.5013, -0.0538, {"tourism": "museum", "historic": "yes"}),
    ("Greenwich Foot Tunnel", "LANDMARK", 51.4854, -0.0100, {"tourism": "attraction", "historic": "yes"}),
    ("Cutty Sark", "HISTORICAL", 51.4829, -0.0096, {"historic": "ship", "tourism": "attraction"}),
    ("Royal Observatory", "VIEWPOINT", 51.4769, -0.0005, {"tourism": "viewpoint", "historic": "yes"}),
    ("Greenwich Park", "NATURE", 51.4770, 0.0010, {"leisure": "park"}),
    ("Mudchute Park and Farm", "NATURE", 51.4912, -0.0130, {"leisure": "park"}),
    ("Thames Path at Deptford", "TRAIL", 51.4870, -0.0250, {"highway": "path", "route": "foot", "river": "Thames"}),
    ("The Dog and Bell", "PUB", 51.4830, -0.0292, {"amenity": "pub"}),
    ("Deptford Market Yard", "CAFE", 51.4790, -0.0263, {"amenity": "cafe"}),
    ("Watch House Café", "CAFE", 51.4985, -0.0810, {"amenity": "cafe"}),
    ("Burgess Park", "NATURE", 51.4832, -0.0812, {"leisure": "park", "lake": "yes"}),
    ("Hilly Fields", "VIEWPOINT", 51.4600, -0.0330, {"tourism": "viewpoint", "leisure": "park"}),
    ("Ladywell Fields", "NATURE", 51.4550, -0.0175, {"leisure": "park", "river": "Ravensbourne"}),
    ("Waterlink Way", "TRAIL", 51.4562, -0.0172, {"route": "bicycle", "highway": "path", "river": "Ravensbourne"}),
    ("Nunhead Cemetery", "HISTORICAL", 51.4643, -0.0530, {"historic": "cemetery", "leisure": "nature_reserve"}),
    ("Peckham Rye Park", "NATURE", 51.4600, -0.0648, {"leisure": "park"}),
    ("One Tree Hill", "VIEWPOINT", 51.4585, -0.0625, {"tourism": "viewpoint"}),
    ("Blackheath", "NATURE", 51.4672, 0.0092, {"leisure": "park"}),
    ("Greenwich Peninsula Ecology Park", "NATURE", 51.4980, 0.0100, {"leisure": "nature_reserve", "lake": "yes"}),
    ("Thames Barrier", "LANDMARK", 51.4956, 0.0369, {"tourism": "attraction", "river": "Thames"}),
    ("Severndroog Castle", "VIEWPOINT", 51.4665, 0.0643, {"tourism": "viewpoint", "historic": "castle"}),
    ("Beckenham Place Park", "NATURE", 51.4205, -0.0240, {"leisure": "park", "lake": "yes"}),
    ("Beckenham Place Mansion Café", "CAFE", 51.4200, -0.0230, {"amenity": "cafe"}),
    ("Brockwell Lido Café", "CAFE", 51.4520, -0.1080, {"amenity": "cafe"}),
]


async def main(args: argparse.Namespace) -> None:
    settings = get_settings()
    llm = build_llm(settings)
    async with get_session_factory()() as db:
        await dev_sign_in(db, settings, args.subject, "Dev Rider")
        user = await db.scalar(select(User).where(User.apple_subject == f"dev:{args.subject}"))
        assert user is not None
        character = await maybe_character(db, user.id)
        if character is None:
            character = await create_character(
                db, settings, user, CharacterCreate(name="Rowan", characterClass="EXPLORER")
            )
        if not await list_bikes(db, user):
            await create_bike(
                db,
                user,
                BikeIn(name="Boardman ADV 8.8", bikeType="GRAVEL", allowGravel=True, allowTrails=True, isDefault=True),
            )

        added_pois = 0
        if not args.no_pois and not await nearby(db, args.lat, args.lon, 15_000, limit=1):
            for name, category, lat, lon, tags in CURATED_POIS:
                db.add(
                    Discovery(
                        name=name,
                        category=category,
                        latitude=lat,
                        longitude=lon,
                        source="CURATED",
                        h3_index=cell_for(lat, lon, settings.h3_resolution),
                        tags=tags,
                    )
                )
                added_pois += 1
            await db.flush()

        available = await list_quests(db, user, "AVAILABLE", args.lat, args.lon, 50)
        missing = max(0, args.count - len(available))
        generated = (
            await generate_quests(db, settings, llm, user, character, args.lat, args.lon, missing) if missing else []
        )
        await db.commit()

    print(
        f"user dev:{args.subject} · {character.name} the {character.character_class.title()} (level {character.overall_level})"
    )
    print(f"added {added_pois} discoveries, {len(generated)} quests ({len(available)} were already available)")
    for quest in available + generated:
        print(f"  {quest.difficulty:<9} {quest.recommended_distance_km:>5.1f} km  {quest.title}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--subject", default="rider-1", help="dev sign-in subject the app uses")
    parser.add_argument("--lat", type=float, default=51.49)
    parser.add_argument("--lon", type=float, default=-0.04)
    parser.add_argument("--count", type=int, default=6, help="available quests to top up to")
    parser.add_argument("--no-pois", action="store_true", help="skip the curated discoveries")
    asyncio.run(main(parser.parse_args()))
