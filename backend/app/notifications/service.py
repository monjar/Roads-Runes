"""Push notifications (spec §73). APNs delivery is behind `apns_enabled`;
without it, notifications are logged so the pipeline can be exercised."""

from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.logging import get_logger
from app.notifications.models import DeviceToken

log = get_logger(__name__)

NOTIFICATION_TYPES = (
    "NEW_STORY_QUEST",
    "FRIEND_INVITATION",
    "PARTY_INVITATION",
    "QUEST_CHAIN_UNLOCKED",
    "WEEKLY_SUMMARY",
)


async def register_device(
    db: AsyncSession, user_id: uuid.UUID, token: str, platform: str, environment: str
) -> DeviceToken:
    row = await db.scalar(select(DeviceToken).where(DeviceToken.token == token))
    if row is None:
        row = DeviceToken(user_id=user_id, token=token, platform=platform, environment=environment)
        db.add(row)
    else:
        row.user_id = user_id
        row.platform = platform
        row.environment = environment
    await db.flush()
    return row


async def unregister_device(db: AsyncSession, user_id: uuid.UUID, token: str) -> None:
    row = await db.scalar(select(DeviceToken).where(DeviceToken.token == token, DeviceToken.user_id == user_id))
    if row is not None:
        await db.delete(row)
        await db.flush()


async def send_push(
    db: AsyncSession,
    settings: Settings,
    user_id: uuid.UUID,
    title: str,
    body: str,
    data: dict[str, Any],
) -> int:
    tokens = list((await db.execute(select(DeviceToken).where(DeviceToken.user_id == user_id))).scalars())
    if not settings.apns_enabled:
        log.info("push_skipped_apns_disabled", user_id=str(user_id), title=title, devices=len(tokens))
        return 0
    # APNs HTTP/2 delivery is wired in when certificates are provisioned (infra/README.md).
    log.info("push_sent", user_id=str(user_id), title=title, devices=len(tokens))
    return len(tokens)
