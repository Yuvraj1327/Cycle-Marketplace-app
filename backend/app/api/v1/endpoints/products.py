from decimal import Decimal
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E400, E404, E422
from app.core.dependencies import get_public_db
from app.schemas.category import CategoryKind
from app.schemas.common import Page
from app.schemas.product import Condition, ProductDetail, ProductSummary, SortBy
from app.services.catalog_service import CatalogService

router = APIRouter(prefix="/products", tags=["Products"])


def get_service(db: SyncPostgrestClient = Depends(get_public_db)) -> CatalogService:
    return CatalogService(db)


@router.get(
    "", response_model=Page[ProductSummary], summary="Browse / search products",
    description="**Public.** Only approved, active listings of approved vendors are returned. All filters combine (AND). "
    "`q` searches name, brand, model, description and category name (case-insensitive, literal text). `category_id` "
    "includes its sub-categories. `in_stock=true` keeps products that are available with stock > 0. Sorting: "
    "`relevance` (default: featured first, then newest), `price_low_to_high`, `price_high_to_low`, `newest`. "
    "Pagination: `page` >= 1, `limit` 1-100; the response carries `total` and `pages`.",
    responses={**E400, **E422},
)
def list_products(
    q: str | None = Query(None, max_length=100),
    category_id: UUID | None = None,
    product_type: CategoryKind | None = None,
    min_price: Decimal | None = Query(None, ge=0, le=10_000_000),
    max_price: Decimal | None = Query(None, ge=0, le=10_000_000),
    brand: str | None = Query(None, max_length=100),
    condition: Condition | None = None,
    in_stock: bool | None = None,
    sort_by: SortBy = SortBy.relevance,
    page: int = Query(1, ge=1, le=10_000),
    limit: int = Query(20, ge=1, le=100),
    service: CatalogService = Depends(get_service),
):
    return service.list(q=q, category_id=category_id, product_type=product_type.value if product_type else None,
                        min_price=min_price, max_price=max_price, brand=brand, condition=condition.value if condition else None,
                        in_stock=in_stock, sort_by=sort_by.value, page=page, limit=limit)


@router.get(
    "/featured", response_model=list[ProductSummary], summary="Featured products",
    description="**Public.** Admin-selected products; they obey the same visibility rules as every listing.", responses=E422,
)
def featured_products(limit: int = Query(10, ge=1, le=50), service: CatalogService = Depends(get_service)):
    return service.featured(limit)


@router.get(
    "/{product_id}", response_model=ProductDetail, summary="Product details",
    description="**Public.** Full description, specifications, ordered images, category, availability and a seller summary "
    "(business name, city, state, types, pickup availability - no address, phone or e-mail).",
    responses={**E404, **E422},
)
def product_detail(product_id: UUID, service: CatalogService = Depends(get_service)):
    return service.detail(product_id)
