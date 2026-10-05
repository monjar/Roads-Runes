"""Migration 0013 (old_ones, the legends): up, down and up again, guarded so a second
run changes nothing, with the model's string widths (Postgres holds a string to
them; SQLite does not). The PostGIS job runs every migration on Postgres as well."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import sqlalchemy as sa

from app.legends import catalog
from app.legends.models import OldOne
from tests.test_migration_0012 import run, widths

VERSIONS = Path(__file__).parent.parent / "alembic" / "versions"


def migration():
    spec = importlib.util.spec_from_file_location("m0013", VERSIONS / "0013_old_ones.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_0013_goes_up_down_and_up_again(tmp_path):
    m = migration()
    assert (m.revision, m.down_revision) == ("0013", "0012")
    engine = sa.create_engine(f"sqlite:///{tmp_path / 'm.db'}")
    with engine.begin() as conn:
        for ddl in (
            "CREATE TABLE users (id CHAR(32) PRIMARY KEY)",
            "CREATE TABLE characters (id CHAR(32) PRIMARY KEY)",
        ):
            conn.exec_driver_sql(ddl)
    with engine.begin() as conn:
        run(conn, m.upgrade)
        run(conn, m.upgrade)  # guarded: a second run changes nothing
    inspector = sa.inspect(engine)
    model = {c.name: c.type.length for c in OldOne.__table__.c if getattr(c.type, "length", None)}
    assert (
        widths(inspector, "old_ones")
        == model
        == {
            "species_id": 30,
            "name": 80,
            "anchor_name": 160,
            "status": 10,
        }
    )
    assert {c["name"] for c in inspector.get_columns("old_ones")} == {c.name for c in OldOne.__table__.c}
    assert "ix_old_ones_user_id" in {i["name"] for i in inspector.get_indexes("old_ones")}
    with engine.begin() as conn:
        conn.exec_driver_sql(
            "INSERT INTO old_ones (id, user_id, character_id, species_id, name, latitude, longitude, status, "
            "woke_at) VALUES ('a', 'u', 'c', 'fog-dragon', 'The Fog Dragon', 51.5, -0.1, 'AWAKE', '2026-10-05')"
        )
        row = conn.exec_driver_sql("SELECT phase, phase_hold_max, phase_hold_left, moved, wounds FROM old_ones").one()
        assert tuple(row)[:4] == (1, 500, 500, 0) and row[4] == "{}"
        run(conn, m.downgrade)
    assert "old_ones" not in sa.inspect(engine).get_table_names()
    with engine.begin() as conn:
        run(conn, m.upgrade)
    assert "old_ones" in sa.inspect(engine).get_table_names()


def test_every_legend_name_and_id_fits_its_column():
    for legend in catalog.book()["legends"]:
        assert len(legend["id"]) <= OldOne.__table__.c.species_id.type.length
        for round_ in (1, 2, 3, 8):
            assert len(catalog.round_name(legend["id"], round_)) <= OldOne.__table__.c.name.type.length
    from app.world_objects.models import WorldObject

    assert len("LAIR") <= WorldObject.__table__.c.kind.type.length
    assert len("HIDDEN") <= WorldObject.__table__.c.status.type.length
    seeds = [f"lair:{10**6}", f"treasure:{10**6}"]
    assert all(len(s) <= WorldObject.__table__.c.seed.type.length for s in seeds)
    from app.inventory.models import ItemEvent

    key = "legend:00000000-0000-0000-0000-000000000000:phase:3"
    assert len(key) <= ItemEvent.__table__.c.key.type.length and len("LEGEND") <= ItemEvent.__table__.c.kind.type.length
    from app.progression.models import XPEvent

    assert len("LEGEND_DEFEATED") <= XPEvent.__table__.c.event_type.type.length
    from app.quests.models import QuestObjective

    assert max(len("LAIR_VISIT"), len("WOUND_BOSS")) <= QuestObjective.__table__.c.objective_type.type.length
