"""Migration 0012 (pledges, letters, rides.local_date): up, down and up again,
guarded so a second run changes nothing. The PostGIS job (scripts/test_postgis.sh)
runs every migration on Postgres as well."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import sqlalchemy as sa
from alembic.migration import MigrationContext
from alembic.operations import Operations

from app.between.models import Letter, Pledge

VERSIONS = Path(__file__).parent.parent / "alembic" / "versions"


def migration():
    spec = importlib.util.spec_from_file_location("m0012", VERSIONS / "0012_pledges_and_letters.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(conn, step) -> None:
    with Operations.context(MigrationContext.configure(conn)):
        step()


def widths(inspector, table: str) -> dict[str, int]:
    # Strings only: SQLite reflects a uuid as CHAR(32).
    return {c["name"]: c["type"].length for c in inspector.get_columns(table) if isinstance(c["type"], sa.VARCHAR)}


def test_0012_goes_up_down_and_up_again(tmp_path):
    m = migration()
    assert (m.revision, m.down_revision) == ("0012", "0011")
    engine = sa.create_engine(f"sqlite:///{tmp_path / 'm.db'}")
    with engine.begin() as conn:
        # The tables 0012 touches, as 0011 left them.
        for ddl in (
            "CREATE TABLE users (id CHAR(32) PRIMARY KEY)",
            "CREATE TABLE rides (id CHAR(32) PRIMARY KEY, started_at DATETIME)",
            "INSERT INTO rides (id) VALUES ('r')",
        ):
            conn.exec_driver_sql(ddl)
    with engine.begin() as conn:
        run(conn, m.upgrade)
        run(conn, m.upgrade)  # guarded: a second run changes nothing
    inspector = sa.inspect(engine)
    # The migration's widths are the models': Postgres holds a string to them.
    model = {c.name: c.type.length for c in Pledge.__table__.c if getattr(c.type, "length", None)}
    assert (
        widths(inspector, "pledges") == model == {"target_kind": 12, "target_name": 160, "remind_at": 5, "status": 10}
    )
    model = {c.name: c.type.length for c in Letter.__table__.c if getattr(c.type, "length", None)}
    assert widths(inspector, "letters") == model == {"text": 140, "place_name": 160}
    assert {u["name"] for u in inspector.get_unique_constraints("pledges")} == {"uq_pledges_user_id_day"}
    assert "local_date" in {c["name"] for c in inspector.get_columns("rides")}
    with engine.begin() as conn:
        assert conn.exec_driver_sql("SELECT local_date FROM rides").one() == (None,)
        run(conn, m.downgrade)
    inspector = sa.inspect(engine)
    assert not {"pledges", "letters"} & set(inspector.get_table_names())
    assert "local_date" not in {c["name"] for c in inspector.get_columns("rides")}
    with engine.begin() as conn:
        run(conn, m.upgrade)
    assert {"pledges", "letters"} <= set(sa.inspect(engine).get_table_names())
