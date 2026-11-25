"""Step 12: the backend's real database usage vs the REAL schema.

The in-memory test double accepts a misspelled column, a missing NOT NULL value or a wrong RPC argument name; PostgreSQL would reject each. While the whole test
suite ran (this file sorts last), every table/column the repositories filtered, ordered, selected, inserted or updated, every insert payload, every string written to
an enum column and every RPC call was recorded. Here they are checked against a throwaway PostgreSQL cluster with all migrations applied.
It cannot prove PostgREST's own query semantics (that needs a real PostgREST); it does catch the 'column / function / enum does not exist' class of bug."""
import json

import pytest

from tests.conftest import RECORDED
from tests.test_sql_integrity import MIGRATIONS, SEED, SQL_DIR, TOOLS, Cluster

pytestmark = pytest.mark.skipif(not all(TOOLS.values()), reason="PostgreSQL tools not installed")

# Columns the DATABASE fills in for an insert even though the backend does not send them (defaults are handled by information_schema; these are trigger-filled).
TRIGGER_FILLED = {("vendor_profiles", "verification_status"), ("audit_log", "created_at")}


@pytest.fixture(scope="module")
def schema():
    if len(RECORDED["columns"]) < 150:
        pytest.skip("run the whole suite: this check reads what the other tests recorded")
    c = Cluster()
    c.start()
    try:
        name = "t" + "conformance"
        c.psql("postgres", "-c", f"create database {name}")
        c.psql(name, "-v", "ON_ERROR_STOP=1", "-f", str(SQL_DIR / "supabase_stub.sql"))
        for f in [*MIGRATIONS, SEED]:
            c.psql(name, "-v", "ON_ERROR_STOP=1", "-f", str(f))
        q = lambda sql: c.psql(name, "-c", sql).stdout.strip()  # noqa: E731
        cols = json.loads(q("select json_agg(json_build_object('t', table_name, 'c', column_name, 'nullable', is_nullable, 'default', column_default, 'identity', is_identity, "
                            "'generated', is_generated, 'udt', udt_name)) from information_schema.columns where table_schema = 'public'"))
        enums = json.loads(q("select json_object_agg(t, labels) from (select t.typname t, json_agg(e.enumlabel) labels from pg_type t join pg_enum e on e.enumtypid = t.oid group by t.typname) x"))
        funcs = json.loads(q("select json_object_agg(p.proname, p.proargnames) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proargnames is not null"))
        allf = json.loads(q("select json_agg(p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'"))
        yield {"cols": cols, "enums": enums, "funcs": funcs, "allfuncs": set(allf)}
    finally:
        c.stop()


def test_enough_was_recorded_to_make_this_check_meaningful(schema):
    assert len(RECORDED["columns"]) > 250 and len(RECORDED["rpcs"]) > 20 and len(RECORDED["inserts"]) > 15


def test_every_table_and_column_the_backend_touches_exists(schema):
    have = {(r["t"], r["c"]) for r in schema["cols"]}
    tables = {t for t, _ in have}
    missing = sorted((t, c) for t, c in RECORDED["columns"] if (t, c) not in have)
    assert not missing, f"the backend uses columns the schema does not have: {missing}"
    assert not sorted(t for t, _ in RECORDED["columns"] if t not in tables)


def test_every_insert_supplies_every_required_column(schema):
    required: dict[str, set[str]] = {}
    for r in schema["cols"]:
        if r["nullable"] == "NO" and r["default"] is None and r["identity"] == "NO" and r["generated"] == "NEVER" and (r["t"], r["c"]) not in TRIGGER_FILLED:
            required.setdefault(r["t"], set()).add(r["c"])
    problems = []
    for table, payloads in RECORDED["inserts"].items():
        for need in required.get(table, set()):
            short = [p for p in payloads if need not in p]
            if short:
                problems.append((table, need, f"{len(short)} insert(s) without it"))
    assert not problems, problems


def test_strings_written_to_enum_columns_are_valid_labels(schema):
    enum_cols = {(r["t"], r["c"]): r["udt"] for r in schema["cols"] if r["udt"] in schema["enums"]}
    bad = sorted({(t, c, v) for t, c, v in RECORDED["values"] if (t, c) in enum_cols and v not in schema["enums"][enum_cols[(t, c)]]})
    assert not bad, f"values the database enum would reject: {bad}"


def test_every_rpc_exists_with_the_argument_names_the_backend_sends(schema):
    problems = []
    for fn, variants in RECORDED["rpcs"].items():
        if fn not in schema["allfuncs"]:
            problems.append((fn, "no such function"))
            continue
        declared = set(schema["funcs"].get(fn) or [])
        for sent in variants:
            if sent - declared:
                problems.append((fn, f"unknown arguments {sorted(sent - declared)}"))
    assert not problems, problems
