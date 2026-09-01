from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends

from app.core.deps import CurrentUser, DBDep, SettingsDep, get_llm, get_router_client
from app.routing import service
from app.routing.schemas import (
    RouteGenerateRequest,
    RouteGenerateResponse,
    RouteOptionOut,
    RoutePackageOut,
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


@router.get("/{route_id}", response_model=RouteOptionOut)
async def get(route_id: uuid.UUID, user: CurrentUser, db: DBDep) -> RouteOptionOut:
    return service.route_out(await service.get_route(db, user, route_id))


@router.get("/{route_id}/package", response_model=RoutePackageOut)
async def package(route_id: uuid.UUID, user: CurrentUser, db: DBDep) -> RoutePackageOut:
    return await service.package(db, user, route_id)
