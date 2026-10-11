from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response

from app.core import fit
from app.core.deps import CurrentUser, DBDep, SettingsDep, get_llm, get_router_client
from app.routing import export as route_export
from app.routing import service
from app.routing.schemas import (
    RerouteRequest,
    RouteGenerateRequest,
    RouteGenerateResponse,
    RouteOptionOut,
    RoutePackageOut,
    RuneRideRequest,
    RuneRideResponse,
)

router = APIRouter(prefix="/routes", tags=["routes"])


@router.post("/generate", response_model=RouteGenerateResponse)
async def generate(
    payload: RouteGenerateRequest,
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    engine: Annotated[object, Depends(get_router_client)],
    llm: Annotated[object, Depends(get_llm)],
) -> RouteGenerateResponse:
    results, parsed = await service.generate(db, settings, engine, llm, user, payload)  # type: ignore[arg-type]
    return RouteGenerateResponse(
        alternatives=[service.route_out(r, c) for r, c in results],
        parsedRequest=parsed,
        engine=results[0][0].engine,
    )


@router.post("/rune", response_model=RuneRideResponse)
async def rune_ride(
    payload: RuneRideRequest,
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    engine: Annotated[object, Depends(get_router_client)],
    llm: Annotated[object, Depends(get_llm)],
) -> RuneRideResponse:
    """Up to three ways to cut a rune from here (409 `RUNE_NOT_A_SHAPE`, `RUNE_NOT_FOR_ACTIVITY`)."""
    from app.routing import rune_rides

    results, form, hint = await rune_rides.plan(
        db,
        settings,
        engine,
        llm,
        user,
        payload.origin,
        payload.rune,
        payload.activity,
        payload.bikeId,  # type: ignore[arg-type]
    )
    return RuneRideResponse(
        alternatives=[service.route_out(r, c) for r, c in results],
        rune=payload.rune,
        roadForm=form,
        hint=hint,
        engine=results[0][0].engine,
    )


@router.get("/{route_id}", response_model=RouteOptionOut)
async def get(route_id: uuid.UUID, user: CurrentUser, db: DBDep) -> RouteOptionOut:
    return service.route_out(await service.get_route(db, user, route_id))


@router.get("/{route_id}/export")
async def export(
    route_id: uuid.UUID,
    user: CurrentUser,
    db: DBDep,
    format: str = Query(default="fit", pattern="^(fit|gpx)$"),
) -> Response:
    """The route as a course for a Garmin (docs/GARMIN.md). 409 `ROUTE_SEALED` for an
    open sealed quest's way."""
    course = await route_export.course(db, user, await service.get_route(db, user, route_id))
    if format == "fit":
        body: bytes | str = route_export.to_fit_course(course)
        media = fit.MEDIA_TYPE
    else:
        body, media = route_export.to_gpx_course(course), "application/gpx+xml"
    return Response(
        content=body,
        media_type=media,
        headers={"Content-Disposition": f'attachment; filename="{fit.filename(course.name, format)}"'},
    )


@router.get("/{route_id}/package", response_model=RoutePackageOut)
async def package(route_id: uuid.UUID, user: CurrentUser, db: DBDep, settings: SettingsDep) -> RoutePackageOut:
    return await service.package(db, user, route_id, settings)


@router.post("/{route_id}/reroute", response_model=RouteOptionOut)
async def reroute(
    route_id: uuid.UUID,
    payload: RerouteRequest,
    user: CurrentUser,
    db: DBDep,
    engine: Annotated[object, Depends(get_router_client)],
) -> RouteOptionOut:
    """One new route from where the rider is, through what the old one still had to
    do, to where it was going. One engine request: it is asked for mid-ride."""
    return service.route_out(await service.reroute(db, engine, user, route_id, payload))  # type: ignore[arg-type]
