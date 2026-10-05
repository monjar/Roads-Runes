"""Migration 0011 (inventory items, gear and consumables on the loadout): up, down
and up again, guarded so a second run changes nothing. The PostGIS job
(scripts/test_postgis.sh) runs every migration on Postgres as well."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import sqlalchemy as sa
from alembic.migration import MigrationContext
from alembic.operations import Operations

VERSIONS = Path(__file__).parent.parent / "alembic" / "versions"


def migration():
    spec = importlib.util.spec_from_file_location("m0011", VERSIONS / "0011_inventory_items.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(conn, step) -> None:
    with Operations.context(MigrationContext.configure(conn)):
        step()


def test_0011_goes_up_down_and_up_again(tmp_path):
    m = migration()
    assert (m.revision, m.down_revision) == ("0011", "0010")
    engine = sa.create_engine(f"sqlite:///{tmp_path / 'm.db'}")
    with engine.begin() as conn:
        # The tables 0011 touches, as 0010 left them.
        for ddl in (
            "CREATE TABLE users (id CHAR(32) PRIMARY KEY)",
            "CREATE TABLE characters (id CHAR(32) PRIMARY KEY)",
            "CREATE TABLE rides (id CHAR(32) PRIMARY KEY)",
            "CREATE TABLE loadouts (id CHAR(32) PRIMARY KEY, user_id CHAR(32), character_id CHAR(32), "
            "inscriptions JSON NOT NULL DEFAULT '[]', repeats INTEGER NOT NULL DEFAULT 0)",
            "INSERT INTO loadouts (id, user_id, character_id) VALUES ('a', 'u', 'c')",
        ):
            conn.exec_driver_sql(ddl)
    with engine.begin() as conn:
        run(conn, m.upgrade)
        run(conn, m.upgrade)  # guarded: a second run changes nothing
    inspector = sa.inspect(engine)
    columns = {c["name"]: c for c in inspector.get_columns("inventory_items")}
    assert columns["item_id"]["type"].length == 40 and columns["source_key"]["type"].length == 160
    assert {"gear", "consumables", "finishes_since_rare"} <= {c["name"] for c in inspector.get_columns("loadouts")}
    with engine.begin() as conn:
        assert conn.exec_driver_sql("SELECT gear, consumables, finishes_since_rare FROM loadouts").one() == (
            "{}",
            "{}",
            0,
        )
        run(conn, m.downgrade)
    inspector = sa.inspect(engine)
    assert "inventory_items" not in inspector.get_table_names()
    assert "gear" not in {c["name"] for c in inspector.get_columns("loadouts")}
    with engine.begin() as conn:
        run(conn, m.upgrade)
    assert "inventory_items" in sa.inspect(engine).get_table_names()
