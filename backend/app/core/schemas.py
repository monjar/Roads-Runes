"""Shared pydantic base: camelCase field names are used directly so the
JSON matches docs/API.md without alias machinery."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict


class APIModel(BaseModel):
    model_config = ConfigDict(from_attributes=True, populate_by_name=True, extra="ignore")


class Coordinate(APIModel):
    latitude: float
    longitude: float
