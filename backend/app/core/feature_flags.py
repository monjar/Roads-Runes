"""Feature flag access. Flags are resolved from settings; a per-user override
table is a later addition — the interface stays the same."""

from __future__ import annotations

from app.core.config import Settings
from app.core.errors import FeatureDisabled

CLASS_FLAGS = {"WIZARD": "wizard_class", "WARRIOR": "warrior_class", "SCRIBE": "scribe_class"}


def is_enabled(settings: Settings, flag: str) -> bool:
    return settings.flags.get(flag, False)


def require_flag(settings: Settings, flag: str) -> None:
    if not is_enabled(settings, flag):
        raise FeatureDisabled(f"Feature '{flag}' is not enabled", details={"flag": flag})


def class_enabled(settings: Settings, character_class: str) -> bool:
    flag = CLASS_FLAGS.get(character_class.upper())
    return True if flag is None else is_enabled(settings, flag)
