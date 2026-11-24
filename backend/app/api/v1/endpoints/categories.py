from uuid import UUID

from fastapi import APIRouter, Depends, Response
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E404, E422
from app.core.dependencies import get_public_db
from app.repositories.category_repository import CategoryRepository
from app.schemas.category import CategoryKind, CategoryOut
from app.services.category_service import CategoryService

router = APIRouter(prefix="/categories", tags=["Categories"])


def get_service(db: SyncPostgrestClient = Depends(get_public_db)) -> CategoryService:
    return CategoryService(CategoryRepository(db))


@router.get(
    "", response_model=list[CategoryOut], summary="List active categories",
    description="**Public.** Active categories ordered by `sort_order` then name, with the number of publicly visible "
    "products in each. Filter by `kind` (new_cycle, used_cycle, spare_part, accessory) or `parent_id`; `root_only` "
    "returns top-level categories. Vendors use this list to pick a valid `category_id` for a product.",
    responses=E422,
)
def list_categories(
    response: Response,
    kind: CategoryKind | None = None,
    parent_id: UUID | None = None,
    root_only: bool = False,
    include_counts: bool = True,
    service: CategoryService = Depends(get_service),
):
    response.headers["Cache-Control"] = "public, max-age=60"
    return service.list(kind=kind.value if kind else None, parent_id=str(parent_id) if parent_id else None,
                        root_only=root_only, include_counts=include_counts)


@router.get("/{category_id}", response_model=CategoryOut, summary="Get one category", description="**Public.** Inactive categories return 404.",
            responses={**E404, **E422})
def get_category(category_id: UUID, service: CategoryService = Depends(get_service)):
    return service.get(str(category_id))
