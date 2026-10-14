"""A card is named for what came back, not for the preset it asked the engine for: a
gravel costing over tarmac is not "Gravel", and a loop is direct to nowhere."""

from __future__ import annotations

from app.core.geo import destination_point
from app.routing import service, shapes
from app.routing.models import Route

HOME = (51.4906, -0.0316)


def line(*bearings_m: tuple[float, float]) -> list[list[float]]:
    """From home through each (bearing, metres) point and back home: a loop."""
    points = [HOME, *(destination_point(*HOME, bearing, metres) for bearing, metres in bearings_m), HOME]
    return [[lon, lat, 0.0] for lat, lon in points]


def card(label: str, km: float = 10.0, *, gravel=0.0, traffic=0.2, cycleways=0.3, gain=40.0, new=0.0, **kw) -> Route:
    return Route(
        label=label,
        distance_meters=km * 1000,
        surface={"paved": 1 - gravel, "gravel": gravel, "trail": 0.0},
        traffic_exposure=traffic,
        cycleway_fraction=cycleways,
        elevation_gain_meters=gain,
        new_territory_fraction=new,
        coordinates=kw.pop("coordinates", line((90, 10.0), (0, 10.0))),  # keeps to no side worth naming
        request=kw.pop("request", {}),
        **kw,
    )


def names(*cards: Route, to_a_place: bool = False) -> list[str]:
    service._name_presets([(c, {}) for c in cards], to_a_place)
    return [c.label for c in cards]


def test_gravel_over_tarmac_is_not_called_gravel():
    assert names(card("Relaxed"), card("Adventure", 10.2), card("Gravel", 10.1)) == [
        "Another way",
        "One more way",
        "Yet another way",
    ]


def test_each_card_is_named_for_what_sets_it_apart():
    relaxed, adventure, gravel = card("Relaxed", traffic=0.1), card("Adventure", new=0.6), card("Gravel", gravel=0.4)
    assert names(relaxed, adventure, gravel) == ["Quietest", "Most new ground", "Most gravel"]
    assert names(card("Challenge", gain=140), card("Relaxed", gain=40), card("Scenic", 13, gain=90)) == [
        "Hilliest",
        "Flattest",
        "The long way",
    ]


def test_a_small_difference_names_nothing():
    """Two per cent more gravel, or two metres less climbing, is not a reason to choose."""
    assert names(card("Gravel", gravel=0.12), card("Relaxed", gravel=0.10, gain=38)) == ["Another way", "One more way"]


def test_without_the_surface_details_only_what_was_measured_names_a_card():
    missing = {"detailsMissing": True}
    gravel = card("Gravel", gravel=0.5, traffic=0.05, cycleways=0.9, request=missing)
    assert names(gravel, card("Relaxed", 9.3)) == ["Another way", "Shortest"]


def test_direct_stays_direct_on_the_way_to_a_place_only_while_it_is():
    assert names(card("As asked", 10.4), card("Direct", 10.1), to_a_place=True) == ["As asked", "Direct"]
    # Nothing is shorter than it by more than three per cent...
    assert names(card("As asked", 9.9), card("Direct", 10.1), to_a_place=True) == ["As asked", "Direct"]
    # ...but a "Direct" 600 m longer than another card is not direct.
    assert names(card("As asked", 9.5), card("Direct", 10.1), to_a_place=True) == ["As asked", "Another way"]
    # And a loop goes nowhere directly: the plain card is named for being shorter.
    assert names(card("As asked", 12.0), card("Direct", 9.0), card(shapes.OTHER_STOPS, 11.5)) == [
        "As asked",
        "Shortest",
        "Other stops",
    ]


def test_the_long_way_must_be_longer():
    assert names(card("As asked", 10.0), card(shapes.LONG_WAY, 11.0)) == ["As asked", "The long way"]
    assert names(card("As asked", 10.0), card(shapes.LONG_WAY, 9.9)) == ["As asked", "Another way"]


def test_a_card_alike_in_its_numbers_is_named_for_the_side_it_keeps_to():
    north = card("Scenic", coordinates=line((340, 2500), (20, 2500)))
    east = card("Adventure", coordinates=line((70, 2500), (110, 2500)))
    assert names(card("As asked"), north, east) == ["As asked", "Via the north", "Via the east"]
    # Two cards on the same side: the second says only that it is another way.
    also_north = card("Gravel", coordinates=line((350, 2000), (10, 2000)))
    assert names(card("As asked"), north, also_north)[1:] == ["Via the north", "Another way"]


def test_one_card_has_nothing_to_be_compared_with():
    assert names(card("Relaxed")) == ["Round trip"]
    assert names(card("Gravel"), to_a_place=True) == ["The way there"]
    assert names(card("Direct"), to_a_place=True) == ["Direct"]
    assert names(card("As asked")) == ["As asked"]


def test_cards_that_already_say_something_true_keep_it():
    labels = ["As asked", "More gravel", "Quieter", "Other stops"]
    cards = [card(label, 10 + i) for i, label in enumerate(labels)]
    assert service._name_presets([(c, {}) for c in cards], True) == {}
    assert [c.label for c in cards] == labels


def test_a_renamed_card_carries_its_name_into_its_request():
    gravel = card("Gravel", gravel=0.4, request={"label": "Gravel", "scoreComponents": {}})
    names(gravel, card("Relaxed"))
    assert gravel.request == {"label": "Most gravel", "scoreComponents": {}}


def test_notes_name_the_cards_the_rider_sees():
    renames = {"Relaxed": "Quietest", "Gravel": "Most gravel"}
    notes = [
        "Direct and Relaxed are the same road here",
        "Adventure and Gravel are the same road here",  # Adventure was dropped: never seen
        "only two different ways here",
        "hardly any gravel around here",
    ]
    assert service._renamed_notes(notes, renames, 2) == [
        "Direct and Quietest are the same road here",
        "only two different ways here",
        "hardly any gravel around here",
    ]


def test_every_name_fits_the_label_column():
    width = Route.__table__.c.label.type.length
    sides = [f"Via the {direction}" for direction in service.COMPASS]
    every = [*service.EARNED, *service.FALLBACK_LABELS, *sides, "The way there", "Round trip"]
    assert max(len(name) for name in every) <= width
