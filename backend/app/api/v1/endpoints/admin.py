from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E400, E404, E409, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_admin_db, get_user_db, require_admin
from app.repositories.banner_repository import BannerRepository
from app.repositories.category_repository import CategoryRepository
from app.schemas.banner import AdminBannerOut, BannerCreate, BannerUpdate
from app.schemas.category import AdminCategoryOut, CategoryCreate, CategoryKind, CategoryUpdate
from app.schemas.common import Page
from app.schemas.product import ActiveUpdate, AdminProductOut, ApprovalStatus, ApprovalUpdate, Condition, FeaturedUpdate
from app.services.admin_product_service import AdminProductService
from app.services.banner_service import BannerService
from app.services.category_service import CategoryService

ADMIN = "**Protected - admin role only.**"
categories = APIRouter(prefix="/admin/categories", tags=["Admin - Categories"], responses=PROTECTED)
products = APIRouter(prefix="/admin/products", tags=["Admin - Products"], responses=PROTECTED)
banners = APIRouter(prefix="/admin/banners", tags=["Admin - Banners"], responses=PROTECTED)


# ---------------- categories ----------------
def cat_service(db: SyncPostgrestClient = Depends(get_user_db)) -> CategoryService:
    return CategoryService(CategoryRepository(db), admin=True)


@categories.get("", response_model=list[AdminCategoryOut], summary="List all categories (incl. inactive)",
                description=ADMIN + " `product_count` counts products in every moderation state.")
def list_categories(kind: CategoryKind | None = None, _a: CurrentUser = Depends(require_admin), service: CategoryService = Depends(cat_service)):
    return service.list(kind=kind.value if kind else None)


@categories.post("", response_model=AdminCategoryOut, status_code=status.HTTP_201_CREATED, summary="Create a category",
                 description=ADMIN + " `slug` is generated from the name when omitted. A sub-category must share its parent's kind. "
                 "`image_path` is an object in the public `banners` bucket (e.g. `categories/tyres.jpg`).", responses={**E409, **E422})
def create_category(body: CategoryCreate, _a: CurrentUser = Depends(require_admin), service: CategoryService = Depends(cat_service)):
    return service.create(body)


@categories.put("/{category_id}", response_model=AdminCategoryOut, summary="Edit / activate / deactivate a category",
                description=ADMIN + " Partial update. Set `is_active` false to hide a category. The kind of a category that has products "
                "or sub-categories cannot change.", responses={**E400, **E404, **E409, **E422})
def update_category(category_id: UUID, body: CategoryUpdate, _a: CurrentUser = Depends(require_admin), service: CategoryService = Depends(cat_service)):
    return service.update(str(category_id), body)


@categories.delete("/{category_id}", status_code=status.HTTP_204_NO_CONTENT, summary="Delete an unused category",
                   description=ADMIN + " Refused with 409 while any product (any status) or sub-category uses it; deactivate instead.",
                   responses={**E404, **E409, **E422})
def delete_category(category_id: UUID, _a: CurrentUser = Depends(require_admin), service: CategoryService = Depends(cat_service)):
    service.delete(str(category_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# ---------------- products ----------------
def prod_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> AdminProductService:
    return AdminProductService(db, admin_db)


@products.get("", response_model=Page[AdminProductOut], summary="Review all products",
              description=ADMIN + " Filter by vendor, category, condition, `approval_status`, `moderation_status` "
              "(pending|approved|rejected|inactive), `is_active`, `is_featured` (this lists featured products), `in_stock`; `sort`: newest|oldest|name|price_*. Includes vendor details.",
              responses=E422)
def list_products(
    q: str | None = Query(None, max_length=100), vendor_id: UUID | None = None, category_id: UUID | None = None,
    condition: Condition | None = None, approval_status: ApprovalStatus | None = None,
    moderation_status: str | None = Query(None, pattern="^(pending|approved|rejected|inactive)$"),
    is_active: bool | None = None, is_featured: bool | None = None, in_stock: bool | None = None,
    sort: str = Query("newest", pattern="^(newest|oldest|name|price_low_to_high|price_high_to_low)$"),
    page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
    _a: CurrentUser = Depends(require_admin), service: AdminProductService = Depends(prod_service),
):
    return service.list(q=q, vendor_id=vendor_id, category_id=category_id, condition=condition.value if condition else None,
                        approval_status=approval_status.value if approval_status else None, moderation_status=moderation_status,
                        is_active=is_active, is_featured=is_featured, in_stock=in_stock, sort=sort, page=page, limit=limit)


@products.get("/{product_id}", response_model=AdminProductOut, summary="Product with vendor details", description=ADMIN, responses={**E404, **E422})
def get_product(product_id: UUID, _a: CurrentUser = Depends(require_admin), service: AdminProductService = Depends(prod_service)):
    return service.get(product_id)


@products.patch("/{product_id}/approval", response_model=AdminProductOut, summary="Approve / reject / reset a listing",
                description=ADMIN + " Rejection requires `review_notes` (shown to the vendor). The reviewer and time are recorded by the database.",
                responses={**E404, **E422})
def set_approval(product_id: UUID, body: ApprovalUpdate, admin: CurrentUser = Depends(require_admin), service: AdminProductService = Depends(prod_service)):
    return service.set_approval(product_id, body, admin)


@products.patch("/{product_id}/status", response_model=AdminProductOut, summary="Activate / deactivate a listing",
                description=ADMIN + " Deactivating also removes the featured flag. Note: a vendor can re-activate their own listing; to enforce a "
                "takedown of an invalid listing use the approval endpoint to reject it.", responses={**E404, **E422})
def set_status(product_id: UUID, body: ActiveUpdate, admin: CurrentUser = Depends(require_admin), service: AdminProductService = Depends(prod_service)):
    return service.set_active(product_id, body.is_active, admin)


@products.patch("/{product_id}/featured", response_model=AdminProductOut, summary="Feature / unfeature a product",
                description=ADMIN + " Only approved, active listings can be featured (409 otherwise).", responses={**E404, **E409, **E422})
def set_featured(product_id: UUID, body: FeaturedUpdate, admin: CurrentUser = Depends(require_admin), service: AdminProductService = Depends(prod_service)):
    return service.set_featured(product_id, body.is_featured, admin)


# ---------------- banners ----------------
def banner_service(db: SyncPostgrestClient = Depends(get_user_db)) -> BannerService:
    return BannerService(BannerRepository(db))


@banners.get("", response_model=list[AdminBannerOut], summary="List all banners (incl. inactive)", description=ADMIN)
def list_banners(_a: CurrentUser = Depends(require_admin), service: BannerService = Depends(banner_service)):
    return service.admin_list()


@banners.post("", response_model=AdminBannerOut, status_code=status.HTTP_201_CREATED, summary="Create a banner",
              description=ADMIN + " `image_path` is an object the admin uploaded to the public `banners` bucket. `action_type`: none | product | "
              "category | service (value = that record's UUID) | url (value = https URL).", responses=E422)
def create_banner(body: BannerCreate, admin: CurrentUser = Depends(require_admin), service: BannerService = Depends(banner_service)):
    return service.create(body, admin.id)


@banners.put("/{banner_id}", response_model=AdminBannerOut, summary="Edit / activate / deactivate a banner", description=ADMIN + " Partial update.",
             responses={**E400, **E404, **E422})
def update_banner(banner_id: UUID, body: BannerUpdate, _a: CurrentUser = Depends(require_admin), service: BannerService = Depends(banner_service)):
    return service.update(str(banner_id), body)


@banners.delete("/{banner_id}", status_code=status.HTTP_204_NO_CONTENT, summary="Delete a banner", description=ADMIN, responses={**E404, **E422})
def delete_banner(banner_id: UUID, _a: CurrentUser = Depends(require_admin), service: BannerService = Depends(banner_service)):
    service.delete(str(banner_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)
