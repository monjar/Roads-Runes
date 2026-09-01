from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from pydantic import Field

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


class RoutePackageOut(APIModel):
    route: RouteOptionOut
    quest: Any | None
    pois: list[dict[str, Any]]
    mapRegion: dict[str, float]
    generatedAt: datetime
