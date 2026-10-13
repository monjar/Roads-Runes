"""Migration 0015 (feature_flag_overrides): up, down and up again, guarded so a second
run changes nothing, with the model's string widths."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import sqlalchemy as sa

from app.admin.models import FeatureFlagOverride
from tests.test_migration_0012 import run, widths
from tests.test_migration_0014 import model_widths

VERSIONS = Path(__file__).parent.parent / "alembic" / "versions"


def migration():
    spec = importlib.util.spec_from_file_location("m0015", VERSIONS / "0015_feature_flag_overrides.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_0015_goes_up_down_and_up_again(tmp_path):
    m = migration()
    assert (m.revision, m.down_revision) == ("0015", "0014")
    engine = sa.create_engine(f"sqlite:///{tmp_path / 'm.db'}")
    with engine.begin() as conn:
        run(conn, m.upgrade)
        run(conn, m.upgrade)  # guarded: a second run changes nothing
    inspector = sa.inspect(engine)
    table = "feature_flag_overrides"
    assert widths(inspector, table) == model_widths(FeatureFlagOverride) == {"name": 64, "note": 200}
    assert {c["name"] for c in inspector.get_columns(table)} == {c.name for c in FeatureFlagOverride.__table__.c}
    assert {u["name"] for u in inspector.get_unique_constraints(table)} == {"uq_feature_flag_overrides_name"}
    assert {u.name for u in FeatureFlagOverride.__table__.constraints if isinstance(u, sa.UniqueConstraint)} == {
        "uq_feature_flag_overrides_name"
    }
    with engine.begin() as conn:
        run(conn, m.downgrade)
    assert table not in sa.inspect(engine).get_table_names()
    with engine.begin() as conn:
        run(conn, m.upgrade)
    assert table in sa.inspect(engine).get_table_names()
