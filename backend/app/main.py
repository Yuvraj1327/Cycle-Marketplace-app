import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.api.v1.router import api_router
from app.core.config import get_settings
from app.core.exceptions import AppError

logger = logging.getLogger(__name__)
settings = get_settings()

TAGS = [
    {"name": "health", "description": "**Public.** Liveness and configuration checks."},
    {"name": "Auth", "description": "**Protected.** Identity verification and logout. Sign-in itself happens in Supabase Auth."},
    {"name": "Profiles", "description": "**Protected.** The caller's own profile."},
    {"name": "Addresses", "description": "**Protected - customer role.** Delivery/pickup addresses."},
    {"name": "Vendors", "description": "**Protected - vendor role.** Vendor onboarding and own business profile."},
    {"name": "Categories", "description": "**Public.** Marketplace categories."},
    {"name": "Products", "description": "**Public.** Browse, search, filter and view products."},
    {"name": "Banners", "description": "**Public.** Active promotional banners."},
    {"name": "Vendor products", "description": "**Protected - approved vendors.** Own listings, inventory and images."},
    {"name": "Cart", "description": "**Protected - customer role.** Shopping cart (no checkout yet)."},
    {"name": "Wishlist", "description": "**Protected - customer role.** Saved products."},
    {"name": "Admin - Categories", "description": "**Protected - admin only.**"},
    {"name": "Admin - Products", "description": "**Protected - admin only.** Moderation, status and featured products."},
    {"name": "Admin - Banners", "description": "**Protected - admin only.**"},
    {"name": "Checkout", "description": "**Protected - customer role.** Places an order from the cart (idempotent, server-priced, stock reserved atomically)."},
    {"name": "Orders", "description": "**Protected - customer role.** Order history, tracking, cancellation."},
    {"name": "Payments", "description": "Customer payment status/retry (protected) and the provider **webhook** (public, signature-verified)."},
    {"name": "Vendor orders", "description": "**Protected - approved vendors.** Fulfilment and settlement records."},
    {"name": "Admin - Orders", "description": "**Protected - admin only.**"},
    {"name": "Admin - Payments", "description": "**Protected - admin only.**"},
    {"name": "Admin - Refunds", "description": "**Protected - admin only.**"},
    {"name": "Admin - Settlements", "description": "**Protected - admin only.** Records only; no payouts are executed."},
    {"name": "Admin - Settings", "description": "**Protected - admin only.** Checkout/payment settings and commission rules."},
    {"name": "Service categories", "description": "**Public.** Servicing categories (General Servicing, Puncture Repair, ...)."},
    {"name": "Services", "description": "**Public.** Browse vendor services, provider details and bookable slots."},
    {"name": "Service bookings", "description": "**Protected - customer role.** Book, track and cancel cycle servicing; attach photos."},
    {"name": "Support", "description": "**Protected - customer role.** Complaints and support requests (no chat)."},
    {"name": "Vendor services", "description": "**Protected - approved vendors.** Manage the services you offer."},
    {"name": "Vendor service bookings", "description": "**Protected - approved vendors.** Accept/reject bookings, repair progress, charges, notes, pickup/drop-off coordination."},
    {"name": "Admin - Service categories", "description": "**Protected - admin only.**"},
    {"name": "Admin - Services", "description": "**Protected - admin only.**"},
    {"name": "Admin - Service bookings", "description": "**Protected - admin only.**"},
    {"name": "Admin - Pickup/drop-off", "description": "**Protected - admin only.** Coordination, not GPS tracking."},
    {"name": "Admin - Support", "description": "**Protected - admin only.** Complaints and disputes."},
]

app = FastAPI(
    title=settings.app_name,
    version="0.6.0",
    description=(
        "Cycle Marketplace backend.\n\n"
        "**Authentication:** sign in with Supabase Auth (email or phone) in the client, then send "
        "`Authorization: Bearer <access_token>`. Tokens are signature-, expiry-, issuer- and audience-verified here. "
        "Roles (`customer`, `vendor`, `admin`) are read from the database, never from the client.\n\n"
        "**Errors** always look like `{\"error\": {\"code\": \"...\", \"message\": \"...\"}}`."
    ),
    openapi_tags=TAGS,
    debug=settings.debug,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _error(status_code: int, code: str, message: str, headers: dict | None = None, details: list | None = None) -> JSONResponse:
    body: dict = {"code": code, "message": message}
    if details:
        body["details"] = details
    return JSONResponse(status_code=status_code, content={"error": body}, headers=headers)


@app.exception_handler(AppError)
async def app_error_handler(_: Request, exc: AppError) -> JSONResponse:
    return _error(exc.status_code, exc.code, exc.message, exc.headers, exc.details)


@app.exception_handler(RequestValidationError)
async def validation_handler(_: Request, exc: RequestValidationError) -> JSONResponse:
    # only location + message: never echo submitted values back
    details = [{"field": ".".join(str(p) for p in e["loc"] if p != "body"), "message": e["msg"]} for e in exc.errors()]
    return _error(422, "validation_error", "The request data is invalid.", details=details)


@app.exception_handler(StarletteHTTPException)
async def http_exception_handler(_: Request, exc: StarletteHTTPException) -> JSONResponse:
    code = {404: "not_found", 405: "method_not_allowed"}.get(exc.status_code, "http_error")
    return _error(exc.status_code, code, str(exc.detail), getattr(exc, "headers", None))


@app.exception_handler(Exception)
async def unhandled_handler(_: Request, exc: Exception) -> JSONResponse:
    logger.exception("Unhandled error")  # details go to the log only
    return _error(500, "internal_error", "An unexpected error occurred.")


app.include_router(api_router, prefix=settings.api_v1_prefix)


@app.get("/health", tags=["health"], summary="Liveness check (public)")
def health() -> dict[str, str]:
    return {"status": "ok", "message": "Backend is running"}


@app.get("/health/config", tags=["health"], summary="Is Supabase configured? (public)")
def health_config() -> dict[str, bool]:
    """Reports only whether Supabase settings are present - never their values and never a live DB probe."""
    return {"supabase_configured": get_settings().supabase_configured}
