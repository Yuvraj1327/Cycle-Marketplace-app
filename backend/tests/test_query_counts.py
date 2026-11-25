"""Step 12 performance guard: list endpoints must not run a database query per row (N+1). Each endpoint is called with 3 rows and again with 15; the number
of database round trips must be identical."""
import pytest

import tests.conftest as c

API = "/api/v1"


@pytest.fixture
def counter(monkeypatch):
    calls = {"n": 0}
    original = c.FakeQuery.execute

    def counting(self):
        calls["n"] += 1
        return original(self)
    monkeypatch.setattr(c.FakeQuery, "execute", counting)
    return calls


def measure(client, counter, url, headers):
    counter["n"] = 0
    r = client.get(url, headers=headers)
    assert r.status_code == 200, (url, r.status_code, r.text[:200])
    return counter["n"], r.json()


def test_commerce_list_endpoints_have_a_constant_number_of_queries(client, world, counter):
    world.bike["stock_quantity"] = world.pads["stock_quantity"] = 1000

    def place(n):
        for _ in range(n):
            world.add(world.bike)
            assert world.checkout({"vendor_id": world.va["id"]}).status_code == 201
            world.add(world.pads)
            assert world.checkout({"vendor_id": world.vb["id"]}).status_code == 201
    urls = [(f"{API}/orders", world.h), (f"{API}/vendor/orders", world.hva), (f"{API}/admin/orders", world.ha), (f"{API}/admin/payments", world.ha), (f"{API}/admin/vendor-orders", world.ha),
            (f"{API}/admin/settlements", world.ha), (f"{API}/admin/refunds", world.ha), (f"{API}/notifications", world.h), (f"{API}/admin/notifications", world.ha),
            (f"{API}/admin/customers", world.ha), (f"{API}/admin/vendors", world.ha), (f"{API}/admin/products", world.ha), (f"{API}/products", world.h), (f"{API}/vendor/products", world.hva),
            (f"{API}/admin/audit-log", world.ha), (f"{API}/admin/orders?q=Alpha", world.ha), (f"{API}/admin/payments?q=ORD", world.ha)]
    place(2)
    few = {u: measure(client, counter, u, h)[0] for u, h in urls}
    place(8)
    for u, h in urls:
        n, body = measure(client, counter, u, h)
        assert n == few[u], f"{u}: {few[u]} queries for few rows but {n} for many: a query per row (N+1)"
    assert measure(client, counter, f"{API}/admin/orders", world.ha)[1]["total"] == 20


def test_service_list_endpoints_have_a_constant_number_of_queries(client, swd, counter):
    def book(n):
        for i in range(n):
            assert swd.book(headers=swd.h, preferred_date=swd.day(3 + (i % 20)), slot_start=f"{9 + i % 8:02d}:00").status_code in (201, 409)
    urls = [(f"{API}/service-bookings", swd.h), (f"{API}/vendor/service-bookings", swd.hva), (f"{API}/admin/service-bookings", swd.ha), (f"{API}/admin/pickup-requests", swd.ha),
            (f"{API}/vendor/pickup-requests", swd.hva), (f"{API}/admin/services", swd.ha), (f"{API}/services", swd.h), (f"{API}/admin/reports/services", swd.ha)]
    book(3)
    few = {u: measure(client, counter, u, h)[0] for u, h in urls}
    book(12)
    for u, h in urls:
        n, _ = measure(client, counter, u, h)
        assert n == few[u], f"{u}: {few[u]} queries for few rows but {n} for many (N+1)"
