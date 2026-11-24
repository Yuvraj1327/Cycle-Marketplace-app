from uuid import UUID

from fastapi import APIRouter, Depends, Query, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E400, E404, E409, E422, PROTECTED
from app.core.dependencies import ApprovedVendor, get_user_db, require_approved_vendor
from app.schemas.common import Page
from app.schemas.service import DeleteResult, ServiceCreate, ServicePatch, ServiceReplace, VendorServiceOut
from app.services.service_offering_service import ServiceOfferingService

router = APIRouter(prefix="/vendor/services", tags=["Vendor services"], responses=PROTECTED)
_NOTE = "**Protected - approved vendors only** (pending/rejected/suspended vendors get 403). Your own services only."


def get_service(db: SyncPostgrestClient = Depends(get_user_db)) -> ServiceOfferingService:
    return ServiceOfferingService(db)


@router.post("", response_model=VendorServiceOut, status_code=status.HTTP_201_CREATED, summary="Add a service",
             description=_NOTE + " Pick an existing platform category (vendors cannot create categories). You do not have to offer every category. `available_days` limits "
             "weekdays; `slot_minutes` and `max_bookings_per_slot` define scheduling. 409 if you already have a service with that name in the category.",
             responses={**E409, **E422})
def create_service(body: ServiceCreate, vendor: ApprovedVendor = Depends(require_approved_vendor), service: ServiceOfferingService = Depends(get_service)):
    return service.create(vendor, body)


@router.get("", response_model=Page[VendorServiceOut], summary="My services", description=_NOTE, responses=E422)
def list_services(is_active: bool | None = None, category_id: UUID | None = None, q: str | None = Query(None, max_length=60), page: int = Query(1, ge=1, le=10_000),
                  limit: int = Query(20, ge=1, le=100), vendor: ApprovedVendor = Depends(require_approved_vendor), service: ServiceOfferingService = Depends(get_service)):
    return service.list(vendor, is_active=is_active, category_id=category_id, q=q, page=page, limit=limit)


@router.get("/{service_id}", response_model=VendorServiceOut, summary="One of my services", description=_NOTE + " Another vendor's service is a 404.", responses={**E404, **E422})
def get_one(service_id: UUID, vendor: ApprovedVendor = Depends(require_approved_vendor), service: ServiceOfferingService = Depends(get_service)):
    return service.get(vendor, service_id)


@router.put("/{service_id}", response_model=VendorServiceOut, summary="Replace a service", description=_NOTE + " Replaces every editable field.", responses={**E404, **E409, **E422})
def replace(service_id: UUID, body: ServiceReplace, vendor: ApprovedVendor = Depends(require_approved_vendor), service: ServiceOfferingService = Depends(get_service)):
    return service.replace(vendor, service_id, body)


@router.patch("/{service_id}", response_model=VendorServiceOut, summary="Update part of a service",
              description=_NOTE + " Change price, duration, `is_available` (pause bookings) or `is_active` (hide). Existing bookings keep the price and name they were made with.",
              responses={**E400, **E404, **E409, **E422})
def patch(service_id: UUID, body: ServicePatch, vendor: ApprovedVendor = Depends(require_approved_vendor), service: ServiceOfferingService = Depends(get_service)):
    return service.patch(vendor, service_id, body)


@router.delete("/{service_id}", response_model=DeleteResult, summary="Remove a service",
               description=_NOTE + " Deleted only if it never received a booking; otherwise deactivated so booking history stays intact (`result` says which).", responses={**E404, **E422})
def delete(service_id: UUID, vendor: ApprovedVendor = Depends(require_approved_vendor), service: ServiceOfferingService = Depends(get_service)):
    return service.delete(vendor, service_id)
