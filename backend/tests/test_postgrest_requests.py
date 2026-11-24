"""Runs the REAL postgrest-py client against a mock HTTP transport and checks the exact PostgREST requests our
repositories produce. (Proves request syntax; it does not prove a live PostgREST/Supabase accepts them.)"""
from decimal import Decimal
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from postgrest import SyncPostgrestClient

from app.repositories.cart_repository import CartRepository
from app.repositories.category_repository import CategoryRepository
from app.repositories.product_repository import ProductFilters, ProductRepository


@pytest.fixture
def wire():
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=[], headers={"content-range": "*/0"})

    client = SyncPostgrestClient("https://x.supabase.co/rest/v1", headers={"apikey": "k", "Authorization": "Bearer t"},
                                 http_client=httpx.Client(transport=httpx.MockTransport(handler)))
    return client, seen


def q(request):
    return {k: v for k, v in parse_qs(urlparse(str(request.url)).query, keep_blank_values=True).items()}


def test_full_search_request_shape(wire):
    client, seen = wire
    f = ProductFilters(q="road bike", q_category_ids=["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"],
                       category_ids=["33333333-3333-3333-3333-333333333333"], product_type="new_cycle", min_price=Decimal("1000"),
                       max_price=Decimal("9999.50"), brand="Trek", condition="new", in_stock=True, public_only=True)
    ProductRepository(client).search(f, sort="price_low_to_high", page=3, limit=20)
    r = seen[0]
    params = q(r)
    assert r.method == "GET" and urlparse(str(r.url)).path == "/rest/v1/products"
    assert params["is_active"] == ["eq.true"] and params["approval_status"] == ["eq.approved"]
    assert params["category_id"] == ["in.(33333333-3333-3333-3333-333333333333)"]
    assert params["product_type"] == ["eq.new_cycle"] and params["condition"] == ["eq.new"]
    assert sorted(params["price"]) == ["gte.1000.0", "lte.9999.5"]
    assert params["brand"] == ["ilike.Trek"] and params["is_available"] == ["eq.true"] and params["stock_quantity"] == ["gt.0"]
    assert params["or"] == ["(name.ilike.*road bike*,brand.ilike.*road bike*,model.ilike.*road bike*,description.ilike.*road bike*,"
                            "category_id.in.(11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222))"]
    assert params["order"] == ["price.asc,created_at.desc,id.asc"]
    assert r.headers["prefer"].find("count=exact") >= 0
    assert params["offset"] == ["40"] and params["limit"] == ["20"]                          # page 3, limit 20
    assert r.headers["authorization"] == "Bearer t"                                         # the caller's token travels with it


def test_out_of_stock_filter_and_default_sort(wire):
    client, seen = wire
    ProductRepository(client).search(ProductFilters(in_stock=False), sort="relevance", page=1, limit=5)
    p = q(seen[0])
    assert p["or"] == ["(is_available.eq.false,stock_quantity.eq.0)"]
    assert p["order"] == ["is_featured.desc,created_at.desc,id.asc"] and p["offset"] == ["0"] and p["limit"] == ["5"]


def test_wildcards_in_brand_are_escaped_on_the_wire(wire):
    client, seen = wire
    ProductRepository(client).search(ProductFilters(brand="a_b%c"), sort="newest", page=1, limit=5)
    assert q(seen[0])["brand"] == ["ilike.a\\_b\\%c"]


def test_category_count_is_a_head_request_with_exact_count(wire):
    client, seen = wire
    CategoryRepository(client).product_count(["c1"], public_only=True)
    r = seen[0]
    assert r.method == "HEAD" and "count=exact" in r.headers["prefer"]
    assert q(r)["category_id"] == ["in.(c1)"] and q(r)["approval_status"] == ["eq.approved"]


def test_rpc_stock_adjustment_request(wire):
    client, seen = wire
    ProductRepository(client).adjust_stock("pid", -2)
    r = seen[0]
    assert r.method == "POST" and urlparse(str(r.url)).path == "/rest/v1/rpc/adjust_product_stock"
    assert r.read() == b'{"p_product_id":"pid","p_delta":-2}'


def test_cart_item_queries_are_scoped_by_cart_id(wire):
    client, seen = wire
    CartRepository(client).find_item("cart-1", "item-1")
    p = q(seen[0])
    assert p["cart_id"] == ["eq.cart-1"] and p["id"] == ["eq.item-1"]
