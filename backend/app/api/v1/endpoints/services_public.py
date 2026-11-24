from datetime import date
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E404, E422
from app.core.dependencies import get_admin_db, get_public_db
from app.repositories.commerce_config_repository import SettingsStore
from app.schemas.common import Page
from app.schemas.service import AvailabilityOut, ServiceCategoryDetail, ServiceCategoryOut, ServiceOut
from app.services.service_catalog_service import ServiceCatalogService
from app.services.service_category_service import ServiceCategoryService
from app.services.service_settings import KEYS, load_service_settings

categories = APIRouter(prefix="/service-categories", tags=["Service categories"])
services = APIRouter(tags=["Services"])


@categories.get("", response_model=list[ServiceCategoryOut], summary="List service categories",
                description="**Public.** Active categories in display order (General Servicing, Puncture Repair, Brake Repair, Gear Adjustment, Parts Replacement ...) "
                "with the number of bookable services in each.")
def list_categories(response: Response, db: SyncPostgrestClient = Depends(get_public_db)):
    response.headers["Cache-Control"] = "public, max-age=60"
    return ServiceCategoryService(db).list()


@categories.get("/{category_id}", response_model=ServiceCategoryDetail, summary="Service category with its services",
                description="**Public.** Inactive categories return 404. `services` lists the first 50 bookable services.", responses={**E404, **E422})
def get_category(category_id: UUID, db: SyncPostgrestClient = Depends(get_public_db)):
    return ServiceCategoryService(db).get(str(category_id), with_services=True)


def catalog(db: SyncPostgrestClient = Depends(get_public_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> ServiceCatalogService:
    return ServiceCatalogService(db, admin_db, load_service_settings(SettingsStore(admin_db).get_many(KEYS)))


@services.get("/services", response_model=Page[ServiceOut], summary="Browse services",
              description="**Public.** Only active, available services of approved providers. Filter by `category_id`, `vendor_id` or name (`q`). Each result carries the "
              "provider's public summary: business name, city, pickup availability, service area (postal codes) and opening hours - no street address, phone or e-mail.",
              responses=E422)
def list_services(category_id: UUID | None = None, vendor_id: UUID | None = None, q: str | None = Query(None, max_length=60), page: int = Query(1, ge=1, le=10_000),
                  limit: int = Query(20, ge=1, le=100), service: ServiceCatalogService = Depends(catalog)):
    return service.list(category_id=category_id, vendor_id=vendor_id, q=q, page=page, limit=limit)


@services.get("/services/{service_id}", response_model=ServiceOut, summary="Service details", description="**Public.**", responses={**E404, **E422})
def get_service(service_id: UUID, service: ServiceCatalogService = Depends(catalog)):
    return service.get(service_id)


@services.get("/vendors/{vendor_id}/services", response_model=Page[ServiceOut], summary="A provider's services", description="**Public.** Only if the provider is approved.",
              responses=E422)
def vendor_services(vendor_id: UUID, page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100), service: ServiceCatalogService = Depends(catalog)):
    return service.list(category_id=None, vendor_id=vendor_id, q=None, page=page, limit=limit)


@services.get("/services/{service_id}/availability", response_model=AvailabilityOut, summary="Bookable slots for a date",
              description="**Public.** Slots are generated from the provider's own opening hours and the service's slot length, minus slots already filled by ACCEPTED bookings "
              "(capacity per slot). `reason` explains an empty list: service_unavailable, vendor_unavailable, date_in_past, too_far_ahead, service_not_offered_that_day, "
              "vendor_hours_not_configured, vendor_closed, no_slots_left. Use a returned `start` as `slot_start` when booking. The slot you choose is your PREFERRED time; "
              "the provider confirms the appointment when accepting.", responses=E422)
def availability(service_id: UUID, day: date = Query(..., alias="date"), service: ServiceCatalogService = Depends(catalog)):
    return service.availability(service_id, day)
