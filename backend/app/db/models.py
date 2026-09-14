"""Import every model so `Base.metadata` is complete for Alembic and tests."""

from app.auth.models import RefreshToken  # noqa: F401
from app.characters.models import (  # noqa: F401
    Bike,
    Character,
    CharacterAbility,
    RiderProfile,
)
from app.db.base import Base
from app.discoveries.models import Discovery, PoiImportArea, UserDiscovery  # noqa: F401
from app.economy.models import Wallet, WalletTransaction  # noqa: F401
from app.exploration.models import UserExplorationCell  # noqa: F401
from app.integrations.models import StravaConnection  # noqa: F401
from app.notifications.models import DeviceToken  # noqa: F401
from app.progression.models import RewardEvent, XPEvent  # noqa: F401
from app.quests.models import (  # noqa: F401
    QuestInstance,
    QuestObjective,
    QuestProgressEvent,
    StoryArc,
    StoryQuest,
)
from app.rides.models import Ride, RidePoint, RideRoute  # noqa: F401
from app.routing.models import Route  # noqa: F401
from app.social.models import FeedEvent, Friendship, Party, PartyMember  # noqa: F401
from app.users.models import User  # noqa: F401
from app.world_objects.models import WorldObject  # noqa: F401

__all__ = ["Base"]
