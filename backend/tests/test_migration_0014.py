"""Migration 0014 (regions, user_regions, loadouts.look): up, down and up again, guarded
so a second run changes nothing, with the models' string widths (Postgres holds a
string to them; SQLite does not). The PostGIS job runs every migration on Postgres
as well."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import sqlalchemy as sa

from app.districts.models import Region, UserRegion
from tests.test_migration_0012 import run, widths

VERSIONS = Path(__file__).parent.parent / "alembic" / "versions"


def migration():
    spec = importlib.util.spec_from_file_location("m0014", VERSIONS / "0014_districts.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def model_widths(model) -> dict[str, int]:
    return {c.name: c.type.length for c in model.__table__.c if getattr(c.type, "length", None)}


def test_0014_goes_up_down_and_up_again(tmp_path):
    m = migration()
    assert (m.revision, m.down_revision) == ("0014", "0013")
    engine = sa.create_engine(f"sqlite:///{tmp_path / 'm.db'}")
    with engine.begin() as conn:
        for ddl in (
            "CREATE TABLE users (id CHAR(32) PRIMARY KEY)",
            "CREATE TABLE loadouts (id CHAR(32) PRIMARY KEY, gear JSON)",
            "INSERT INTO loadouts (id, gear) VALUES ('l', '{}')",
        ):
            conn.exec_driver_sql(ddl)
    with engine.begin() as conn:
        run(conn, m.upgrade)
        run(conn, m.upgrade)  # guarded: a second run changes nothing
    inspector = sa.inspect(engine)
    assert (
        widths(inspector, "regions")
        == model_widths(Region)
        == {
            "osm_id": 32,
            "name": 120,
            "kind": 20,
            "tile": 32,
            "epithet": 40,
        }
    )
    assert widths(inspector, "user_regions") == model_widths(UserRegion) == {"last_paid_week": 10}
    assert {c["name"] for c in inspector.get_columns("regions")} == {c.name for c in Region.__table__.c}
    assert {c["name"] for c in inspector.get_columns("user_regions")} == {c.name for c in UserRegion.__table__.c}
    assert "look" in {c["name"] for c in inspector.get_columns("loadouts")}
    assert "ix_regions_tile" in {i["name"] for i in inspector.get_indexes("regions")}
    assert {"ix_user_regions_user_id", "ix_user_regions_region_id"} <= {
        i["name"] for i in inspector.get_indexes("user_regions")
    }
    with engine.begin() as conn:
        conn.exec_driver_sql(
            "INSERT INTO regions (id, osm_id, name, kind, latitude, longitude, tile) "
            "VALUES ('r', 'n101', 'Rotherhithe', 'suburb', 51.5, -0.05, '514:-1')"
        )
        assert conn.exec_driver_sql("SELECT place_counts, way_cells FROM regions").one() == ("{}", None)
        conn.exec_driver_sql(
            "INSERT INTO user_regions (id, user_id, region_id, first_passed_at, last_passed_at) "
            "VALUES ('x', 'u', 'r', '2026-10-05', '2026-10-05')"
        )
        row = conn.exec_driver_sql("SELECT explored_cells, way_cells_explored, completed_at FROM user_regions").one()
        assert tuple(row) == (0, 0, None)
        assert conn.exec_driver_sql("SELECT look FROM loadouts").scalar() is None
        run(conn, m.downgrade)
    after = sa.inspect(engine)
    assert not {"regions", "user_regions"} & set(after.get_table_names())
    assert "look" not in {c["name"] for c in after.get_columns("loadouts")}
    assert after.get_table_names().count("loadouts") == 1
    with engine.begin() as conn:
        assert conn.exec_driver_sql("SELECT gear FROM loadouts").scalar() == "{}", "the rest of the row kept"
        run(conn, m.upgrade)
    assert {"regions", "user_regions"} <= set(sa.inspect(engine).get_table_names())
