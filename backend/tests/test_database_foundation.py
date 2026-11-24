import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.core import supabase as sb
from app.core.config import get_settings
from app.core.db_errors import translate_db_error
from app.core.exceptions import ConfigurationError, ConflictError, DatabaseError, PermissionDeniedError
from app.main import app
from app.repositories.base import BaseRepository


@pytest.fixture(autouse=True)
def clean(monkeypatch):
    for k in ("SUPABASE_URL", "SUPABASE_ANON_KEY", "SUPABASE_SERVICE_ROLE_KEY"):
        monkeypatch.delenv(k, raising=False)
    get_settings.cache_clear(); sb.get_admin_client.cache_clear(); sb.get_anon_client.cache_clear()
    yield
    get_settings.cache_clear(); sb.get_admin_client.cache_clear(); sb.get_anon_client.cache_clear()


def test_health_still_works_without_supabase():
    c = TestClient(app)
    assert c.get("/health").json()["status"] == "ok"
    assert c.get("/health/config").json() == {"supabase_configured": False}


def test_client_requires_configuration():
    with pytest.raises(ConfigurationError):
        sb.get_admin_client()


def test_clients_initialise_when_configured(monkeypatch):
    # Initialisation only: supabase-py does not open a connection at construction. No real project is contacted.
    monkeypatch.setenv("SUPABASE_URL", "https://example-project.supabase.co")
    monkeypatch.setenv("SUPABASE_ANON_KEY", "anon-placeholder")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "service-placeholder")
    get_settings.cache_clear()
    assert sb.get_admin_client() is sb.get_admin_client()  # cached
    assert sb.get_anon_client() is not sb.get_admin_client()
    assert TestClient(app).get("/health/config").json() == {"supabase_configured": True}


@pytest.mark.parametrize("code,exc", [("23505", ConflictError), ("42501", PermissionDeniedError), ("XX000", DatabaseError)])
def test_db_error_translation(code, exc):
    err = APIError({"message": "boom", "code": code, "details": None, "hint": None})
    assert type(translate_db_error(err)) is exc


def test_repository_requires_table_and_maps_errors():
    with pytest.raises(TypeError):
        BaseRepository()

    class Repo(BaseRepository):
        table = "products"

    with pytest.raises(ConfigurationError):
        Repo().get_by_id("x")  # no client configured -> clean configuration error, not a crash
