from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from pydantic import Field

from app.core.activity import Activity
from app.core.schemas import APIModel, Coordinate


class PreferencesIn(APIModel):
    trafficAversion: float = Field(default=0.7, ge=0, le=1)
    cyclewayPreference: float = Field(default=0.7, ge=0, le=1)
    gravelPreference: float = Field(default=0.3, ge=0, le=1)
    scenicPreference: float = Field(default=0.6, ge=0, le=1)
    hillTolerance: float = Field(default=0.5, ge=0, le=1)


class RouteGenerateRequest(APIModel):
    origin: Coordinate
    destination: Coordinate | None = None
    waypoints: list[Coordinate] = Field(default_factory=list, max_length=10)
    bikeId: uuid.UUID | None = None
    questId: uuid.UUID | None = None
    distanceTargetKm: float | None = Field(default=None, ge=1, le=400)
    loop: bool | None = None
    preferences: PreferencesIn | None = None
    request: str | None = Field(default=None, max_length=400)
    # None: however this player usually moves (the rider profile).
    activity: Activity | None = None


class RerouteRequest(APIModel):
    """Off the route, mid-ride: where the rider is and what they have already done."""

    origin: Coordinate
    # How far along the route they had got when they left it.
    progressMeters: float = Field(default=0.0, ge=0)
    completedObjectiveIds: list[uuid.UUID] = Field(default_factory=list, max_length=50)
    visitedStopIds: list[uuid.UUID] = Field(default_factory=list, max_length=50)


class InstructionOut(APIModel):
    index: int
    text: str
    streetName: str
    sign: str
    distanceMeters: float
    durationSeconds: int
    coordinateIndex: int
    latitude: float
    longitude: float


class RouteOptionOut(APIModel):
    id: uuid.UUID
    label: str
    engine: str
    activity: str = "RIDE"
    distanceMeters: float
    estimatedDurationSeconds: int
    elevationGainMeters: float
    elevationLossMeters: float
    highestPointMeters: float
    maxGradientPercent: float
    averageClimbGradientPercent: float
    longestClimb: dict[str, Any] | None
    surface: dict[str, float]
    cyclewayFraction: float
    trafficExposure: float
    newTerritoryFraction: float
    questObjectiveCoverage: float
    score: float
    scoreComponents: dict[str, float] = {}
    pois: list[dict[str, Any]]
    coordinates: list[list[float]]
    encodedPolyline: str
    instructions: list[InstructionOut]
    elevationSamples: list[dict[str, float]]
    climbs: list[dict[str, Any]]
    boundingBox: dict[str, float]
    createdAt: datetime


class RouteGenerateResponse(APIModel):
    alternatives: list[RouteOptionOut]
    parsedRequest: dict[str, Any] | None = None
    engine: str


class RuneRideRequest(APIModel):
    """A route in a rune's road form, from here (0.7.0)."""

    origin: Coordinate
    rune: str = Field(max_length=20)
    activity: Activity | None = None
    bikeId: uuid.UUID | None = None


class RuneRideResponse(APIModel):
    alternatives: list[RouteOptionOut]
    rune: str
    roadForm: str
    # "Cut Raido here: a loop, about 2.4 km."
    hint: str
    engine: str


class RoutePackageOut(APIModel):
    route: RouteOptionOut
    quest: Any | None
    pois: list[dict[str, Any]]
    mapRegion: dict[str, float]
    generatedAt: datetime
