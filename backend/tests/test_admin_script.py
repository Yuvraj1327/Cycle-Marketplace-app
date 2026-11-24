import pytest

from app.core.exceptions import NotFoundError
from scripts.promote_admin import promote_to_admin


def test_promote_existing_user(db):
    uid = db.add_profile(email="boss@example.com")
    row = promote_to_admin(db, "  Boss@Example.com ")  # email lookup is case/space-insensitive
    assert row["role"] == "admin" and db.tables["profiles"][0]["id"] == uid
    assert promote_to_admin(db, "boss@example.com")["role"] == "admin"   # idempotent


def test_unknown_email_refused(db):
    with pytest.raises(NotFoundError):
        promote_to_admin(db, "ghost@example.com")
