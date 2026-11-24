from uuid import UUID

from fastapi import APIRouter, Depends, Response, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E400, E404, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_user_db, require_customer
from app.repositories.address_repository import AddressRepository
from app.schemas.address import AddressCreate, AddressResponse, AddressUpdate
from app.services.address_service import AddressService

router = APIRouter(
    prefix="/addresses",
    tags=["Addresses"],
    responses=PROTECTED,
)


def get_address_service(db: SyncPostgrestClient = Depends(get_user_db)) -> AddressService:
    return AddressService(AddressRepository(db))


@router.post(
    "", response_model=AddressResponse, status_code=status.HTTP_201_CREATED, summary="Create address",
    description="**Protected - customer role.** The first address becomes the default automatically.",
    responses=E422,
)
def create_address(body: AddressCreate, user: CurrentUser = Depends(require_customer), service: AddressService = Depends(get_address_service)):
    return service.create(user, body)


@router.get(
    "", response_model=list[AddressResponse], summary="List own addresses",
    description="**Protected - customer role.** Default address first.",
)
def list_addresses(user: CurrentUser = Depends(require_customer), service: AddressService = Depends(get_address_service)):
    return service.list(user)


@router.get(
    "/{address_id}", response_model=AddressResponse, summary="Get one address",
    description="**Protected - customer role.** Another customer's address returns 404.",
    responses={**E404, **E422},
)
def get_address(address_id: UUID, user: CurrentUser = Depends(require_customer), service: AddressService = Depends(get_address_service)):
    return service.get(user, address_id)


@router.put(
    "/{address_id}", response_model=AddressResponse, summary="Update address",
    description="**Protected - customer role.** Partial update of the supplied fields.",
    responses={**E400, **E404, **E422},
)
def update_address(address_id: UUID, body: AddressUpdate, user: CurrentUser = Depends(require_customer), service: AddressService = Depends(get_address_service)):
    return service.update(user, address_id, body)


@router.delete(
    "/{address_id}", status_code=status.HTTP_204_NO_CONTENT, summary="Delete address",
    description="**Protected - customer role.** Past orders keep their own address snapshot. "
    "Deleting the default address leaves the customer with no default until one is chosen.",
    responses={**E404, **E422},
)
def delete_address(address_id: UUID, user: CurrentUser = Depends(require_customer), service: AddressService = Depends(get_address_service)):
    service.delete(user, address_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.patch(
    "/{address_id}/default", response_model=AddressResponse, summary="Set default address",
    description="**Protected - customer role.**", responses={**E404, **E422},
)
def set_default_address(address_id: UUID, user: CurrentUser = Depends(require_customer), service: AddressService = Depends(get_address_service)):
    return service.set_default(user, address_id)
