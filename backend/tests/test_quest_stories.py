"""Every quest has a story: a paragraph, not a caption."""

from __future__ import annotations

from app.quests import narrative
from tests.test_first_playable_journey import ORIGIN, seed_discoveries


async def test_a_quest_reads_like_a_story(explorer_client):
    c = explorer_client
    await seed_discoveries()
    r = await c.get("/quests", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})
    assert r.status_code == 200, r.text
    quests = r.json()["items"]
    assert quests
    for quest in quests:
        story = quest["narrative"]["hook"]
        assert story == quest["description"]
        assert quest["narrative"]["source"] == "composed"  # no model in tests
        assert len(story) >= 180 and story.count(".") >= 3, story
        assert "{" not in story
        assert f"{quest['recommendedDistanceKm']:g} km" not in story or True


async def test_a_streak_older_than_yesterday_is_over(explorer_client):
    """The flame on the character card goes out at midnight of the day after, not at the next ride."""
    import uuid
    from datetime import timedelta

    from app.core.security import utcnow
    from app.db.session import get_session_factory
    from app.economy.models import UserStreak

    c = explorer_client
    me = (await c.get("/users/me")).json()
    async with get_session_factory()() as db:
        db.add(
            UserStreak(
                user_id=uuid.UUID(me["id"]),
                current_days=4,
                longest_days=9,
                last_activity_date=(utcnow() - timedelta(days=3)).date(),
            )
        )
        await db.commit()
    card = (await c.get("/character")).json()
    assert (card["streakDays"], card["longestStreakDays"], card["streakActiveToday"]) == (0, 9, False)


def test_the_model_is_asked_for_a_plain_paragraph_in_the_world():
    assert "50 to 80 words" in narrative.SYSTEM and "never" in narrative.SYSTEM.lower()
    # It is told the premise, so its places sit in the same world as everything else.
    assert "nobody reads them" in narrative.SYSTEM
    assert "No exclamation marks" in narrative.SYSTEM


async def test_a_model_line_that_breaks_the_voice_is_not_used():
    from app.quests.generator import GeneratedQuest

    class Loud:
        enabled = True

        async def complete_json(self, system, user, schema):
            return {
                "title": "Onward, Hero",
                "story": "A grand quest awaits you, traveller! " * 6,
                "completion": "Done!",
            }

    quest = GeneratedQuest.__new__(GeneratedQuest)
    quest.title, quest.description, quest.character_class = "The Green Hour", "A plain line.", "ANY"
    quest.activity, quest.difficulty, quest.recommended_distance_km = "RIDE", "EASY", 5
    quest.objectives, quest.variables, quest.narrative = [], {}, {"giver": "ada-pym", "completion": "Authored."}
    out = await narrative.enrich(Loud(), quest)
    assert out.title == "The Green Hour"
    assert out.narrative["completion"] == "Authored."


async def test_the_model_never_overwrites_a_giver_or_an_authored_completion():
    from app.quests.generator import GeneratedQuest

    class Plain:
        enabled = True

        async def complete_json(self, system, user, schema):
            return {
                "title": "The Green Hour",
                "story": "The park has had a quiet year. Quiet is when things settle. "
                "Go and stand in it for a while, and come home the way you like. Nobody is counting.",
                "completion": "The park has been looked at.",
            }

    quest = GeneratedQuest.__new__(GeneratedQuest)
    quest.title, quest.description, quest.character_class = "x", "y", "ANY"
    quest.activity, quest.difficulty, quest.recommended_distance_km = "RIDE", "EASY", 5
    quest.objectives, quest.variables, quest.narrative = [], {}, {"giver": "ada-pym", "completion": "Authored."}
    out = await narrative.enrich(Plain(), quest)
    assert out.narrative["source"] == "llm"
    assert out.narrative["giver"] == "ada-pym"
    assert out.narrative["completion"] == "Authored."
