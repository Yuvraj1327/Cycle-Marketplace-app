import pytest

from app.core.exceptions import ConflictError, PermissionDeniedError, ValidationFailedError
from app.services.inventory_service import InventoryService
from tests.conftest import SERVICE, FakeClient


@pytest.fixture
def stocked(db):
    _, v = db.add_approved_vendor(); c = db.add_category("accessory")
    return db.add_product(v["id"], c, stock_quantity=5)


def test_atomic_adjust_never_goes_negative(db, stocked):
    inv = InventoryService(FakeClient(db, SERVICE))
    assert inv.adjust(stocked["id"], -3) == 2
    assert inv.adjust(stocked["id"], 10) == 12
    with pytest.raises(ConflictError) as e:
        inv.adjust(stocked["id"], -13)
    assert e.value.code == "insufficient_stock" and stocked["stock_quantity"] == 12
    with pytest.raises(ConflictError):
        inv.adjust("00000000-0000-0000-0000-000000000000", -1)


@pytest.mark.parametrize("delta", [0, 1.5, "3", True, None])
def test_invalid_deltas_rejected(db, stocked, delta):
    with pytest.raises(ValidationFailedError):
        InventoryService(FakeClient(db, SERVICE)).adjust(stocked["id"], delta)


def test_only_service_role_may_call_the_stock_function(db, stocked):
    for actor in (None, db.add_profile(role="vendor"), db.add_profile()):
        with pytest.raises(PermissionDeniedError):
            InventoryService(FakeClient(db, actor)).adjust(stocked["id"], -1)
    assert stocked["stock_quantity"] == 5


def test_no_http_route_exposes_stock_adjustment(client):
    paths = " ".join(client.get("/openapi.json").json()["paths"])
    assert "adjust" not in paths and "stock" not in paths
