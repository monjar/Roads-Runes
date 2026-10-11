"""How different Plan a ride's cards are, on the real Valhalla server (0.9.2).

Usage:
    python scripts/route_diversity.py [--flags '!route_shapes'] [--max-calls 60] [--only 1,3]

Five London requests, planned in-process against a scratch SQLite database
(places imported from OpenStreetMap once, then kept) with the public Valhalla
server as the engine. For each it prints the cards' labels and lengths, how much
of each loop's way back rides its way out, the similarity of every pair of cards,
and how many engine requests the plan made.

Fair use. Valhalla requests are paced at one a second, a run stops at
`--max-calls` network requests (60), and every answer is cached under
`scripts/.route_diversity_cache/` (gitignored), so running it again costs only the
requests that changed. Readings are scripted (no model) and place names resolve to
fixed coordinates (no geocoder), so two runs differ only in the routing.

`--flags '!route_shapes'` plans the way 0.9.1 did. Summaries are written to
`.route_diversity_cache/runs/` for comparing runs.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
# Never more than this many requests to the public server in one run.
MAX_CALLS = 60
CACHE = HERE / ".route_diversity_cache"
sys.path.insert(0, str(HERE.parent))


def configure(flags: str) -> None:
    """Environment for an in-process backend; must run before any app import."""
    CACHE.mkdir(exist_ok=True)
    os.environ.update(
        {
            "ENVIRONMENT": "test",  # quiet logs; the engine is swapped in below
            "DEV_AUTH_ENABLED": "true",
            "JWT_SECRET": "route-diversity",
            "JOB_QUEUE": "inline",
            "LLM_PROVIDER": "none",
            "POI_IMPORT_ENABLED": "true",
            "GEOCODING_ENABLED": "false",
            "ROUTING_ENGINE": "valhalla",
            # This script paces the network itself (only real requests wait).
            "VALHALLA_MIN_INTERVAL_S": "0",
            "DATABASE_URL": f"sqlite+aiosqlite:///{CACHE / 'places.db'}",
            "FEATURE_FLAGS": flags,
            "LOG_LEVEL": "CRITICAL",
            # More mirrors than the app's two: a run imports twenty dense London tiles.
            "OVERPASS_URLS": ",".join(
                (
                    "https://overpass.kumi.systems/api/interpreter",
                    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
                    "https://overpass-api.de/api/interpreter",
                    "https://overpass.private.coffee/api/interpreter",
                )
            ),
        }
    )


# Where the names in the requests are, from Photon on 2026-10-11.
PLACES = {
    "aragon tower": ("Aragon Tower", 51.49074, -0.03155),
    "westminster": ("Westminster", 51.50044, -0.12654),
    "greenwich": ("Greenwich", 51.48208, -0.00454),
    "tower bridge": ("Tower Bridge", 51.50552, -0.07537),
    "notting hill": ("Notting Hill", 51.51100, -0.20553),
    "camden town": ("Camden Town", 51.53925, -0.14276),
    "rotherhithe": ("Rotherhithe", 51.50029, -0.04363),
}
ARAGON = PLACES["aragon tower"][1:]
ROTHERHITHE = PLACES["rotherhithe"][1:]
CAMDEN = PLACES["camden town"][1:]


def reading(**fields: Any) -> dict[str, Any]:
    """What the model would have read: everything unsaid is null."""
    names = (
        "origin destination area via distanceKm stops trafficAversion cyclewayPreference gravelPreference "
        "scenicPreference hillTolerance loop"
    ).split()
    return {name: None for name in names} | fields


def stops(*categories: str, count: int | None = None) -> dict[str, Any]:
    return {"categories": list(categories), "count": count, "preferredPosition": None, "quality": False}


@dataclass
class Case:
    title: str
    origin: tuple[float, float]
    request: str | None = None
    read: dict[str, Any] | None = None
    destination: tuple[float, float] | None = None
    loop: bool | None = None
    distance_km: float | None = 25.0  # the app always sends its slider
    places: list[tuple[float, float]] = field(default_factory=list)  # for the place import


CASES = [
    Case(
        "Aragon Tower to Westminster and back, with some pubs",
        ARAGON,
        "From Aragon Tower to Westminster and back, checking out some pubs",
        reading(
            origin={"query": "Aragon Tower"},
            destination={"query": "Westminster"},
            stops=stops("PUB"),
            loop=True,
        ),
        places=[PLACES["westminster"][1:]],
    ),
    Case(
        "To Greenwich and back from Rotherhithe",
        ROTHERHITHE,
        "To Greenwich and back from Rotherhithe",
        reading(origin={"query": "Rotherhithe"}, destination={"query": "Greenwich"}, loop=True),
        places=[PLACES["greenwich"][1:]],
    ),
    Case(
        "A quiet ride to Tower Bridge with 2 cafes",
        ARAGON,
        "A quiet ride to Tower Bridge with 2 cafes",
        reading(destination={"query": "Tower Bridge"}, trafficAversion=0.95, stops=stops("CAFE", count=2), loop=False),
        places=[PLACES["tower bridge"][1:]],
    ),
    Case(
        "A 15 km loop through 3 pubs in Notting Hill",
        ARAGON,
        "A 15 km loop through 3 pubs in Notting Hill",
        reading(
            area={"query": "Notting Hill"},
            distanceKm={"target": 15, "tolerance": 3},
            stops=stops("PUB", count=3),
            loop=True,
        ),
        loop=True,
        places=[PLACES["notting hill"][1:]],
    ),
    Case(
        "Map tap: Rotherhithe to Camden",
        ROTHERHITHE,
        destination=CAMDEN,
        loop=False,
        distance_km=10.0,
        places=[CAMDEN],
    ),
]


class Network:
    """Valhalla through a cache, a pace and a cap: one request a second at most,
    never more than `cap` real requests, and an answer seen before is not asked for."""

    def __init__(self, cap: int, interval_s: float = 1.0) -> None:
        import httpx

        self.httpx = httpx
        self.real = httpx.AsyncHTTPTransport()
        self.cap = cap
        self.interval_s = interval_s
        self.sent = 0  # real requests this run
        self.asked = 0  # requests the planner made, cached or not
        self.last = 0.0
        (CACHE / "valhalla").mkdir(exist_ok=True)

    def transport(self):
        network = self

        class Transport(self.httpx.AsyncBaseTransport):
            async def handle_async_request(self, request):
                return await network.handle(request)

        return Transport()

    async def handle(self, request):
        httpx = self.httpx
        body = await request.aread()
        key = hashlib.sha256(request.url.path.encode() + b"\n" + body).hexdigest()[:32]
        path = CACHE / "valhalla" / f"{key}.json"
        self.asked += 1
        if path.exists():
            saved = json.loads(path.read_text())
            return httpx.Response(saved["status"], json=saved["body"], request=request)
        if self.sent >= self.cap:
            raise httpx.ConnectError(f"route_diversity: the {self.cap}-request cap for this run is spent")
        wait = self.last + self.interval_s - time.monotonic()
        if wait > 0:
            await asyncio.sleep(wait)
        self.sent += 1
        self.last = time.monotonic()
        response = await self.real.handle_async_request(request)
        content = await response.aread()
        if response.status_code in (200, 400):  # an answer, either way; worth keeping
            try:
                path.write_text(json.dumps({"status": response.status_code, "body": json.loads(content)}))
            except ValueError:
                pass
        return httpx.Response(response.status_code, content=content, headers=response.headers, request=request)


def scripted_llm(cases: list[Case]):
    by_text = {case.request: case.read for case in cases if case.request}

    class Scripted:
        enabled = True

        async def extract(self, system: str, user: str, schema: dict) -> dict | None:
            return by_text.get(user)

        async def complete_json(self, system: str, user: str, schema_hint: str) -> dict | None:
            return None

    return Scripted()


async def import_places(settings, cases: list[Case]) -> None:
    """Every tile the requests touch, one at a time (Overpass refuses a crowd), before
    any plan, so two runs see the same places. A tile that failed is tried again."""
    from sqlalchemy import delete

    from app.db.session import get_session_factory
    from app.discoveries import osm_import
    from app.discoveries.models import PoiImportArea

    async with get_session_factory()() as db:
        await db.execute(delete(PoiImportArea).where(PoiImportArea.status == "FAILED"))
        await db.commit()
    started = time.monotonic()
    for case in cases:
        for lat, lon in [case.origin, *case.places]:
            await osm_import.ensure_pois(settings, lat, lon, wait=True)
            await osm_import.drain()
        for lat, lon in case.places:
            await osm_import.ensure_pois_along(settings, *case.origin, lat, lon, budget_s=120)
            await osm_import.drain()
    async with get_session_factory()() as db:
        failed = (await db.execute(PoiImportArea.__table__.select().where(PoiImportArea.status == "FAILED"))).all()
    print(f"places ready in {time.monotonic() - started:.0f} s; tiles that failed: {[row.key for row in failed]}")


def turn_of(route: dict[str, Any], destination: tuple[float, float] | None) -> int | None:
    from app.core.geo import haversine_m

    coords = route["coordinates"]
    if destination is None:
        return None
    return min(
        range(len(coords)), key=lambda i: haversine_m(destination[0], destination[1], coords[i][1], coords[i][0])
    )


def summarise(case: Case, body: dict[str, Any], calls: int, sent: int) -> dict[str, Any]:
    from app.routing import overlap

    alternatives = body.get("alternatives", [])
    parsed = body.get("parsedRequest") or {}
    destination = case.destination
    if destination is None and (parsed.get("destination") or {}).get("latitude") is not None:
        destination = (parsed["destination"]["latitude"], parsed["destination"]["longitude"])
    loops = case.loop if case.loop is not None else bool((case.read or {}).get("loop"))
    cards = []
    for route in alternatives:
        back = (
            overlap.self_overlap(route["coordinates"], turn_of(route, destination) if destination else None)
            if loops
            else None
        )
        cards.append(
            {
                "label": route["label"],
                "km": round(route["distanceMeters"] / 1000, 2),
                "selfOverlap": None if back is None else round(back, 3),
                "stops": sum(1 for poi in route.get("pois", []) if poi.get("requested")),
                "detailsMissing": route.get("detailsMissing"),
            }
        )
    matrix = [
        [
            None if i == j else round(overlap.similarity(a["coordinates"], b["coordinates"]), 3)
            for j, b in enumerate(alternatives)
        ]
        for i, a in enumerate(alternatives)
    ]
    return {
        "title": case.title,
        "cards": cards,
        "similarity": matrix,
        "calls": calls,
        "network": sent,
        "understood": parsed.get("understood"),
        "notes": parsed.get("notes"),
        "stopsPicked": len(parsed.get("stops") or []),
        "startsAt": (parsed.get("startsAt") or {}).get("name"),
    }


def show(n: int, summary: dict[str, Any]) -> None:
    print(f"\n{n}. {summary['title']}")
    if summary.get("error"):
        print(f"   failed: {summary['error']}")
        return
    print(f"   understood: {' · '.join(summary['understood'] or []) or '-'}")
    if summary["notes"]:
        print(f"   notes: {' · '.join(summary['notes'])}")
    print(f"   stops picked: {summary['stopsPicked']}   engine calls: {summary['calls']} ({summary['network']} sent)")
    print(f"   {'card':<16}{'km':>7}{'back on way out':>17}{'stops':>7}")
    for card in summary["cards"]:
        back = "-" if card["selfOverlap"] is None else f"{card['selfOverlap'] * 100:.0f}%"
        print(f"   {card['label']:<16}{card['km']:>7.1f}{back:>17}{card['stops']:>7}")
    if len(summary["cards"]) > 1:
        heads = "".join(f"{c['label'][:10]:>12}" for c in summary["cards"])
        print(f"   similarity      {heads}")
        for card, row in zip(summary["cards"], summary["similarity"], strict=True):
            cells = "".join(f"{'-' if v is None else f'{v:.2f}':>12}" for v in row)
            print(f"   {card['label'][:16]:<16}{cells}")


def overall(summaries: list[dict[str, Any]]) -> dict[str, Any]:
    pairs = [v for s in summaries for i, row in enumerate(s.get("similarity", [])) for j, v in enumerate(row) if j > i]
    backs = [c["selfOverlap"] for s in summaries for c in s.get("cards", []) if c["selfOverlap"] is not None]
    return {
        "cards": sum(len(s.get("cards", [])) for s in summaries),
        "meanSimilarity": round(sum(pairs) / len(pairs), 3) if pairs else None,
        "maxSimilarity": max(pairs) if pairs else None,
        "meanSelfOverlap": round(sum(backs) / len(backs), 3) if backs else None,
        "maxSelfOverlap": max(backs) if backs else None,
        "calls": sum(s.get("calls", 0) for s in summaries),
        "network": sum(s.get("network", 0) for s in summaries),
    }


async def run(args: argparse.Namespace) -> None:
    configure(args.flags)
    from httpx import ASGITransport, AsyncClient

    from app.core.config import get_settings
    from app.db.models import Base
    from app.db.session import configure_engine, make_engine
    from app.jobs.handlers import HANDLERS
    from app.jobs.queue import InlineJobQueue
    from app.main import build_state, create_app
    from app.routing import geocode
    from app.routing.valhalla import ValhallaClient

    get_settings.cache_clear()
    settings = get_settings()
    engine = make_engine(settings.database_url)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    configure_engine(engine)

    cases = [c for i, c in enumerate(CASES, 1) if not args.only or i in args.only]
    await import_places(settings, cases)

    async def resolve(_settings, query, lat, lon, transport=None, kind="area"):
        found = PLACES.get(str(query).lower().strip())
        return geocode.Area(*found) if found else None

    geocode.resolve = resolve  # fixed answers: the comparison is about routing

    network = Network(0 if args.offline else min(args.max_calls, MAX_CALLS))
    app = create_app(settings)
    await build_state(app, settings)
    app.state.jobs = InlineJobQueue(HANDLERS, background=False)
    app.state.llm = scripted_llm(cases)
    app.state.router = ValhallaClient(
        settings.valhalla_url,
        settings.valhalla_timeout_seconds,
        settings.valhalla_api_key,
        transport=network.transport(),
    )

    summaries: list[dict[str, Any]] = []
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://local/api/v1", timeout=300) as client:
        token = (await client.post("/auth/dev", json={"subject": "route-diversity", "displayName": "Diversity"})).json()
        client.headers["Authorization"] = f"Bearer {token['accessToken']}"
        await client.post("/character", json={"name": "Rowan", "characterClass": "EXPLORER"})
        bikes = (await client.get("/character/bikes")).json()
        if not bikes:
            await client.post("/character/bikes", json={"name": "Hybrid", "bikeType": "HYBRID"})
        for n, case in enumerate(CASES, 1):
            if case not in cases:
                continue
            if network.cap and network.cap - network.sent < 10:
                print(f"\n{n}. {case.title}: skipped, fewer than 10 requests left under the cap")
                continue
            asked, sent = network.asked, network.sent
            payload: dict[str, Any] = {"origin": {"latitude": case.origin[0], "longitude": case.origin[1]}}
            if case.request:
                payload["request"] = case.request
            if case.destination:
                payload["destination"] = {"latitude": case.destination[0], "longitude": case.destination[1]}
            if case.loop is not None:
                payload["loop"] = case.loop
            if case.distance_km:
                payload["distanceTargetKm"] = case.distance_km
            started = time.monotonic()
            response = await client.post("/routes/generate", json=payload)
            if response.status_code != 200:
                summary = {"title": case.title, "error": response.text[:300], "cards": [], "similarity": []}
            else:
                summary = summarise(case, response.json(), network.asked - asked, network.sent - sent)
            summary["seconds"] = round(time.monotonic() - started, 1)
            summaries.append(summary)
            show(n, summary)

    total = overall(summaries)
    print(
        f"\n{total['cards']} cards · mean similarity {total['meanSimilarity']} (max {total['maxSimilarity']}) · "
        f"mean back-on-way-out {total['meanSelfOverlap']} (max {total['maxSelfOverlap']}) · "
        f"{total['calls']} engine calls, {total['network']} sent"
    )
    runs = CACHE / "runs"
    runs.mkdir(exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    name = "flags-" + (args.flags.replace("!", "no-").replace(",", "+") or "default")
    out = runs / f"{stamp}-{name}.json"
    out.write_text(json.dumps({"flags": args.flags, "overall": total, "requests": summaries}, indent=2))
    print(f"written to {out.relative_to(HERE.parent)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--flags", default="", help="FEATURE_FLAGS for this run, e.g. '!route_shapes'")
    parser.add_argument(
        "--max-calls", type=int, default=MAX_CALLS, help=f"network requests to Valhalla (<= {MAX_CALLS})"
    )
    parser.add_argument("--offline", action="store_true", help="cached answers only; nothing is sent to Valhalla")
    parser.add_argument("--only", type=lambda s: [int(x) for x in s.split(",")], default=None, help="e.g. 1,3")
    asyncio.run(run(parser.parse_args()))


if __name__ == "__main__":
    main()
