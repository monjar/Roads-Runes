from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response, status

from app.core.deps import CurrentUser, DBDep, get_job_queue
from app.core.pagination import Page, clamp_limit
from app.rides import service
from app.rides.export import to_gpx, to_tcx
from app.rides.schemas import (
    AdventureSummary,
    RideCellsIn,
    RideCompleteIn,
    RideCompleteOut,
    RideCreate,
    RideGeometry,
    RideOut,
    RidePatch,
    RidePointsIn,
)

router = APIRouter(prefix="/rides", tags=["rides"])


@router.post("", response_model=RideOut, status_code=status.HTTP_201_CREATED)
async def create(payload: RideCreate, user: CurrentUser, db: DBDep) -> RideOut:
    return service.ride_out(await service.create_ride(db, user, payload))


@router.get("", response_model=Page[RideOut])
async def list_rides(
    user: CurrentUser, db: DBDep, limit: int | None = None, cursor: str | None = None
) -> Page[RideOut]:
    rows, next_cursor = await service.list_rides(db, user, clamp_limit(limit), cursor)
    return Page(items=[service.ride_out(r) for r in rows], nextCursor=next_cursor)


@router.get("/{ride_id}", response_model=RideOut)
async def get(ride_id: uuid.UUID, user: CurrentUser, db: DBDep) -> RideOut:
    return service.ride_out(await service.get_ride(db, user, ride_id))


@router.post("/{ride_id}/points", response_model=RideOut)
async def add_points(ride_id: uuid.UUID, payload: RidePointsIn, user: CurrentUser, db: DBDep) -> RideOut:
    ride = await service.get_ride(db, user, ride_id)
    await service.add_points(db, ride, payload.points)
    return service.ride_out(ride)


@router.post("/{ride_id}/exploration", response_model=RideOut)
async def add_cells(ride_id: uuid.UUID, payload: RideCellsIn, user: CurrentUser, db: DBDep) -> RideOut:
    ride = await service.get_ride(db, user, ride_id)
    await service.add_cells(db, ride, payload.cellsVisited)
    return service.ride_out(ride)


@router.post("/{ride_id}/complete", response_model=RideCompleteOut)
async def complete(
    ride_id: uuid.UUID,
    payload: RideCompleteIn,
    user: CurrentUser,
    db: DBDep,
    jobs: Annotated[object, Depends(get_job_queue)],
) -> RideCompleteOut:
    ride = await service.get_ride(db, user, ride_id)
    was_recording = ride.status == "RECORDING"
    ride = await service.complete_ride(db, ride, payload)
    if was_recording:
        await db.commit()  # the job runs in another session/process; make the upload visible first
        await jobs.enqueue("process_ride", {"rideId": str(ride.id)})  # type: ignore[attr-defined]
        processing = "QUEUED"
    else:
        processing = "DONE" if ride.status in ("PROCESSED", "FLAGGED") else "QUEUED"
    return RideCompleteOut(ride=service.ride_out(ride), processing=processing)


@router.get(
    "/{ride_id}/summary",
    response_model=AdventureSummary,
    responses={202: {"description": "Still processing"}},
)
async def summary(ride_id: uuid.UUID, user: CurrentUser, db: DBDep):
    ride = await service.get_ride(db, user, ride_id)
    result = await service.summary(db, user, ride)
    if result is None:
        # A bare response: returning None through response_model=AdventureSummary failed
        # validation and turned every "still processing" poll into a 500.
        return Response(status_code=status.HTTP_202_ACCEPTED)
    return result


@router.get("/{ride_id}/geometry", response_model=RideGeometry)
async def geometry(ride_id: uuid.UUID, user: CurrentUser, db: DBDep) -> RideGeometry:
    return await service.geometry(db, await service.get_ride(db, user, ride_id))


@router.get("/{ride_id}/export")
async def export(
    ride_id: uuid.UUID,
    user: CurrentUser,
    db: DBDep,
    format: str = Query(default="gpx", pattern="^(gpx|tcx)$"),
) -> Response:
    ride = await service.get_ride(db, user, ride_id)
    pts = await service.points(db, ride)
    body = to_gpx(ride, pts) if format == "gpx" else to_tcx(ride, pts)
    media = "application/gpx+xml" if format == "gpx" else "application/vnd.garmin.tcx+xml"
    return Response(
        content=body,
        media_type=media,
        headers={"Content-Disposition": f'attachment; filename="ride-{ride.id}.{format}"'},
    )


@router.patch("/{ride_id}", response_model=RideOut)
async def patch(ride_id: uuid.UUID, payload: RidePatch, user: CurrentUser, db: DBDep) -> RideOut:
    return service.ride_out(await service.patch(db, await service.get_ride(db, user, ride_id), payload))


@router.delete("/{ride_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete(ride_id: uuid.UUID, user: CurrentUser, db: DBDep) -> None:
    await service.discard(db, await service.get_ride(db, user, ride_id))
