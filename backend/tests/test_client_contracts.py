"""Every API call written in the three client applications must exist in the backend's OpenAPI contract (same method, same path shape).
This is a static check of OUR clients against OUR backend: it catches renamed / removed / mistyped endpoints before they reach a device. It does not replace the
contract tests that exercise request and response bodies over HTTP (see apps/*/test/contract and apps/admin_web/src/test/contract)."""
import re
from pathlib import Path

import pytest

from app.main import app

ROOT = Path(__file__).resolve().parents[2]
PREFIX = "/api/v1"
PARAM = re.compile(r"\$\{[^}]+\}|\$[A-Za-z_]\w*|\{[^}]+\}")


def norm(path: str) -> str:
    return PARAM.sub("{}", path.split("?")[0]).rstrip("/") or "/"


@pytest.fixture(scope="module")
def contract() -> set[tuple[str, str]]:
    ops = set()
    for path, item in app.openapi()["paths"].items():
        for method in item:
            if method in ("get", "post", "put", "patch", "delete"):
                ops.add((method.upper(), norm(path.removeprefix(PREFIX))))
    return ops


def dart_calls(app_dir: str) -> set[tuple[str, str]]:
    found = set()
    for f in (ROOT / "apps" / app_dir / "lib").rglob("*.dart"):
        text = f.read_text()
        for m in re.finditer(r"\.(get|post|put|patch|delete)\(\s*(['\"])(/[^'\"]*)\2", text):
            found.add((m.group(1).upper(), norm(m.group(3))))
        for m in re.finditer(r"_send\(\s*'(GET|POST|PUT|PATCH|DELETE)'\s*,\s*(['\"])(/[^'\"]*)\2", text):
            found.add((m.group(1), norm(m.group(3))))
    return found


def ts_calls() -> set[tuple[str, str]]:
    found = set()
    text = (ROOT / "apps" / "admin_web" / "src" / "services" / "api" / "services.ts").read_text()
    for m in re.finditer(r"\bapi\.(get|post|put|patch|delete)\b[^(`'\"]*\(\s*([`'\"])(/[^`'\"]*)\2", text):
        found.add((m.group(1).upper(), norm(m.group(3))))
    return found


@pytest.mark.parametrize("name,calls,minimum", [("customer_app", lambda: dart_calls("customer_app"), 40), ("vendor_app", lambda: dart_calls("vendor_app"), 40), ("admin_web", ts_calls, 60)])
def test_every_client_call_exists_in_the_backend_contract(contract, name, calls, minimum):
    used = calls()
    assert len(used) >= minimum, f"only {len(used)} calls were found in {name}: the scanner probably broke"
    missing = sorted(c for c in used if c not in contract)
    assert not missing, f"{name} calls endpoints the backend does not define: {missing}"


def test_clients_only_use_their_own_api_surface(contract):
    """A customer app must not call vendor/admin endpoints and vice versa (the backend would answer 403 anyway; this catches the mistake at build time)."""
    for path in (p for _, p in dart_calls("customer_app")):
        assert not path.startswith(("/admin", "/vendor/")), path
    for path in (p for _, p in dart_calls("vendor_app")):
        assert not path.startswith(("/admin", "/cart", "/checkout", "/wishlist")), path
    for path in (p for _, p in ts_calls()):
        assert not path.startswith(("/vendor/", "/cart", "/checkout", "/wishlist")), path


def test_no_client_talks_to_the_development_harness_or_a_hardcoded_host():
    for f in list((ROOT / "apps" / "customer_app" / "lib").rglob("*.dart")) + list((ROOT / "apps" / "vendor_app" / "lib").rglob("*.dart")) + list((ROOT / "apps" / "admin_web" / "src").rglob("*.ts*")):
        if ".test." in f.name or "/test/" in str(f):
            continue
        text = f.read_text()
        assert "__dev" not in text, f
        for m in re.finditer(r"https?://[A-Za-z0-9.\-:]+", text):
            host = m.group(0)
            # allowed: documentation links, the emulator alias used as a build-time DEFAULT, the Supabase placeholder in comments and local dev defaults
            assert re.search(r"10\.0\.2\.2|localhost|127\.0\.0\.1|example\.|supabase\.co|w3\.org|schema|googleapis|flutter\.dev|pub\.dev|github\.com|firebase|apple\.com|developer\.", host) or "placeholder" in text, (f, host)
