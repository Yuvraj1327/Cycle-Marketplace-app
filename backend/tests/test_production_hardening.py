"""APP_ENV=production switches the public API documentation off; development keeps it."""
import importlib

import pytest
from fastapi.testclient import TestClient


def _load(monkeypatch, env: str):
    monkeypatch.setenv("APP_ENV", env)
    from app.core import config

    config.get_settings.cache_clear()
    import app.main as main

    return importlib.reload(main)


@pytest.fixture(autouse=True)
def _restore(monkeypatch):
    yield
    monkeypatch.undo()
    from app.core import config

    config.get_settings.cache_clear()
    import app.main as main

    importlib.reload(main)


def test_docs_and_openapi_are_off_in_production(monkeypatch):
    main = _load(monkeypatch, "production")
    c = TestClient(main.app)
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert c.get(path).status_code == 404, path
    assert c.get("/health").status_code == 200


def test_docs_stay_available_in_development(monkeypatch):
    main = _load(monkeypatch, "development")
    c = TestClient(main.app)
    assert c.get("/openapi.json").status_code == 200
