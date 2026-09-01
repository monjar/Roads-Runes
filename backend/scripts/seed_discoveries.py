"""Seed discoveries from a GeoJSON FeatureCollection of points.

Usage: python scripts/seed_discoveries.py path/to/pois.geojson

Expected feature properties: name, category (see spec §23), optional
description, osm_id, tags. Export such a file from Overpass with e.g.
`node["tourism"="viewpoint"](bbox)` and map tags to categories with the
CATEGORY_RULES below.
"""

from __future__ import annotations

import asyncio
import json
import sys

from sqlalchemy import select

from app.core.config import get_settings
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.exploration.cells import cell_for

CATEGORY_RULES = [
    ({"tourism": "viewpoint"}, "VIEWPOINT"),
    ({"amenity": "pub"}, "PUB"),
    ({"amenity": "cafe"}, "CAFE"),
    ({"amenity": "restaurant"}, "FOOD"),
    ({"historic": "*"}, "HISTORICAL"),
    ({"tourism": "attraction"}, "LANDMARK"),
    ({"leisure": "park"}, "NATURE"),
    ({"natural": "*"}, "NATURE"),
    ({"route": "bicycle"}, "CYCLING"),
    ({"shop": "bicycle"}, "CYCLING"),
    ({"highway": "path"}, "TRAIL"),
]


def category_for(tags: dict) -> str | None:
    for rule, category in CATEGORY_RULES:
        for k, v in rule.items():
            if k in tags and (v == "*" or tags[k] == v):
                return category
    return None


async def main(path: str) -> None:
    settings = get_settings()
    data = json.load(open(path))
    async with get_session_factory()() as db:
        added = 0
        for feature in data["features"]:
            props = feature.get("properties", {})
            coords = feature["geometry"]["coordinates"]
            tags = props.get("tags", {})
            category = props.get("category") or category_for(tags)
            name = props.get("name") or tags.get("name")
            if not name or not category:
                continue
            osm_id = props.get("osm_id") or props.get("id")
            if osm_id and await db.scalar(select(Discovery).where(Discovery.osm_id == str(osm_id))):
                continue
            db.add(
                Discovery(
                    name=name[:160],
                    category=category,
                    description=props.get("description"),
                    latitude=float(coords[1]),
                    longitude=float(coords[0]),
                    source="OSM",
                    osm_id=str(osm_id) if osm_id else None,
                    h3_index=cell_for(float(coords[1]), float(coords[0]), settings.h3_resolution),
                    tags=tags,
                )
            )
            added += 1
        await db.commit()
    print(f"added {added} discoveries")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
