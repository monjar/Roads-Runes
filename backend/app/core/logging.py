"""Structured logging via structlog. Backend events use the names in spec §78."""

from __future__ import annotations

import logging
import sys

import structlog


def configure_logging(level: str = "INFO", json_output: bool = True) -> None:
    logging.basicConfig(format="%(message)s", stream=sys.stdout, level=level.upper())
    renderer = structlog.processors.JSONRenderer() if json_output else structlog.dev.ConsoleRenderer()
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            renderer,
        ],
        wrapper_class=structlog.make_filtering_bound_logger(logging.getLevelName(level.upper())),
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )


def get_logger(name: str) -> structlog.stdlib.BoundLogger:
    return structlog.get_logger(name)


# Canonical backend event names (spec §78)
EVENT_ROUTE_GENERATED = "route_generated"
EVENT_ROUTE_GENERATION_FAILED = "route_generation_failed"
EVENT_QUEST_GENERATION_FAILED = "quest_generation_failed"
EVENT_RIDE_UPLOAD_FAILED = "ride_upload_failed"
EVENT_STRAVA_UPLOAD_FAILED = "strava_upload_failed"
EVENT_EXPLORATION_VALIDATION_FAILED = "exploration_validation_failed"
