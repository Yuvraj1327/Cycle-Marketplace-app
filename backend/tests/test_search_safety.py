import pytest

from app.core.search import contains_pattern, like_escape, sanitize_term, slugify

P = "/api/v1/products"

ATTACKS = [
    "x),is_active.eq.false,name.ilike.*(", "a,approval_status.eq.pending", "foo)&select=*", "'; DROP TABLE products;--", "x\"y\\z",
    "100%", "under_score", "*", "%%", "a.b.c", "(((", "))), or", "name.ilike.*", "\x00\x1f", "ünïcode ✓ 自転車", "   ",
]


@pytest.mark.parametrize("raw", ATTACKS)
def test_sanitized_terms_cannot_inject_postgrest_syntax(raw):
    t = sanitize_term(raw)
    assert not any(c in t for c in ',()"\\*%:;=<>&|\x00')
    assert len(t) <= 100


def test_wildcards_are_escaped_so_input_matches_literally():
    assert like_escape("100%_off") == "100\\%\\_off"
    assert contains_pattern("a_b") == "*a\\_b*"


def test_slugify():
    assert slugify("Tyres & Tubes!") == "tyres-tubes" and slugify("  ") == ""


@pytest.mark.parametrize("raw", ATTACKS)
def test_attack_strings_do_not_change_the_query_shape_or_leak_hidden_rows(client, db, raw):
    _, v = db.add_approved_vendor(); c = db.add_category("accessory", "Acc")
    db.add_product(v["id"], c, name="Visible Helmet")
    db.add_product(v["id"], c, name="Hidden Pending", approval_status="pending")
    db.add_product(v["id"], c, name="Hidden Inactive", is_active=False)
    r = client.get(P, params={"q": raw, "brand": raw})
    assert r.status_code == 200
    assert all(i["name"] == "Visible Helmet" for i in r.json()["items"])        # never leaks pending/inactive rows
    for expr in db.or_calls:                                                      # the or=(...) filter has exactly our 4-5 clauses
        clauses = expr.split(",")
        assert all(cl.split(".")[0] in ("name", "brand", "model", "description", "category_id") for cl in clauses), expr
        assert len(clauses) in (4, 5)


def test_percent_and_underscore_do_not_act_as_wildcards(client, db):
    _, v = db.add_approved_vendor(); c = db.add_category("accessory", "Acc")
    db.add_product(v["id"], c, name="Bike Light"); db.add_product(v["id"], c, name="Bike_Light")
    assert [i["name"] for i in client.get(P, params={"q": "e_L"}).json()["items"]] == ["Bike_Light"]
    assert client.get(P, params={"q": "%"}).json()["items"] == []
