from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E400, E404, E409, E422, PROTECTED
from app.core.dependencies import ApprovedVendor, get_admin_db, get_user_db, require_approved_vendor
from app.schemas.category import CategoryKind
from app.schemas.common import Page
from app.schemas.product import (
    ApprovalStatus,
    DeleteResult,
    ImageOrder,
    ImageOut,
    ImagePatch,
    ImageRegister,
    ProductCreate,
    ProductPatch,
    ProductReplace,
    VendorProductOut,
)
from app.services.product_image_service import ProductImageService
from app.services.vendor_product_service import VendorProductService

router = APIRouter(prefix="/vendor/products", tags=["Vendor products"], responses=PROTECTED)
_APPROVED = "**Protected - approved vendors only** (pending/rejected/suspended vendors get 403)."


def get_service(
    vendor: ApprovedVendor = Depends(require_approved_vendor),
    db: SyncPostgrestClient = Depends(get_user_db),
    admin_db: SyncPostgrestClient = Depends(get_admin_db),
) -> VendorProductService:
    return VendorProductService(db, admin_db, vendor.user.access_token)


def get_image_service(db: SyncPostgrestClient = Depends(get_user_db)) -> ProductImageService:
    return ProductImageService(db)


@router.post(
    "", response_model=VendorProductOut, status_code=status.HTTP_201_CREATED, summary="Create a listing",
    description=_APPROVED + " The vendor comes from your session; `product_type` comes from the category. New listings "
    "enter moderation (`pending`) unless the platform setting `marketplace.require_listing_approval` is `false`. "
    "Condition must match the category: new_cycle => new, used_cycle => used.",
    responses={**E422},
)
def create_product(body: ProductCreate, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorProductService = Depends(get_service)):
    return service.create(vendor, body)


@router.get(
    "", response_model=Page[VendorProductOut], summary="List my products",
    description=_APPROVED + " Your own listings in every moderation state. `moderation_status` is one of "
    "pending | approved | rejected | inactive.", responses=E422,
)
def list_my_products(
    q: str | None = Query(None, max_length=100), approval_status: ApprovalStatus | None = None, is_active: bool | None = None,
    category_id: UUID | None = None, product_type: CategoryKind | None = None, in_stock: bool | None = None,
    page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
    vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorProductService = Depends(get_service),
):
    return service.list(vendor, q=q, approval_status=approval_status.value if approval_status else None, is_active=is_active,
                        category_id=category_id, product_type=product_type.value if product_type else None, in_stock=in_stock, page=page, limit=limit)


@router.get("/{product_id}", response_model=VendorProductOut, summary="Get my product", description=_APPROVED + " Another vendor's product returns 404.",
            responses={**E404, **E422})
def get_my_product(product_id: UUID, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorProductService = Depends(get_service)):
    return service.get(vendor, product_id)


@router.put(
    "/{product_id}", response_model=VendorProductOut, summary="Replace my product",
    description=_APPROVED + " Replaces every editable field (price, stock, description, specifications, availability, `is_active`). "
    "Approval and featured flags cannot be sent (422). Editing a *rejected* listing resubmits it for review.",
    responses={**E404, **E422},
)
def replace_product(product_id: UUID, body: ProductReplace, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorProductService = Depends(get_service)):
    return service.replace(vendor, product_id, body)


@router.patch(
    "/{product_id}", response_model=VendorProductOut, summary="Update part of my product",
    description=_APPROVED + " Partial update - the way to change only price, `stock_quantity` (>= 0), `is_available` or "
    "`is_active` (deactivate/reactivate). Stock is set absolutely; adding to a cart never changes it.",
    responses={**E400, **E404, **E422},
)
def patch_product(product_id: UUID, body: ProductPatch, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorProductService = Depends(get_service)):
    return service.patch(vendor, product_id, body)


@router.delete(
    "/{product_id}", response_model=DeleteResult, summary="Remove my product",
    description=_APPROVED + " Deletes the listing if it has never been ordered; otherwise it is deactivated so order history "
    "stays intact (`result` says which).", responses={**E404, **E422},
)
def delete_product(product_id: UUID, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorProductService = Depends(get_service)):
    return service.delete(vendor, product_id)


# ---------------- images ----------------
_UPLOAD = ("Upload flow: 1) the vendor app uploads the file straight to Supabase Storage bucket `product-images` with the vendor's own "
           "session at `<your_user_id>/<product_id>/<file>.jpg|png|webp` (max 5 MB); 2) it registers the path here.")


@router.get("/{product_id}/images", response_model=list[ImageOut], summary="List product images", description=_APPROVED, responses={**E404, **E422})
def list_images(product_id: UUID, vendor: ApprovedVendor = Depends(require_approved_vendor), service: ProductImageService = Depends(get_image_service)):
    return service.list(vendor, product_id)


@router.post("/{product_id}/images", response_model=ImageOut, status_code=status.HTTP_201_CREATED, summary="Register an uploaded image",
             description=_APPROVED + " " + _UPLOAD + " The path, file existence, type and size are verified; max 8 images; the first becomes primary.",
             responses={**E404, **E409, **E422})
def register_image(product_id: UUID, body: ImageRegister, vendor: ApprovedVendor = Depends(require_approved_vendor), service: ProductImageService = Depends(get_image_service)):
    return service.register(vendor, product_id, body)


@router.put("/{product_id}/images/order", response_model=list[ImageOut], summary="Reorder images",
            description=_APPROVED + " `image_ids` must list every image of the product exactly once, in the desired order.", responses={**E404, **E422})
def reorder_images(product_id: UUID, body: ImageOrder, vendor: ApprovedVendor = Depends(require_approved_vendor), service: ProductImageService = Depends(get_image_service)):
    return service.reorder(vendor, product_id, body)


@router.patch("/{product_id}/images/{image_id}", response_model=ImageOut, summary="Update image (alt text / primary)",
              description=_APPROVED, responses={**E400, **E404, **E409, **E422})
def patch_image(product_id: UUID, image_id: UUID, body: ImagePatch, vendor: ApprovedVendor = Depends(require_approved_vendor), service: ProductImageService = Depends(get_image_service)):
    return service.patch(vendor, product_id, image_id, body)


@router.delete("/{product_id}/images/{image_id}", status_code=status.HTTP_204_NO_CONTENT, summary="Remove an image",
               description=_APPROVED + " Also deletes the file from Storage as the vendor (storage RLS applies).", responses={**E404, **E422})
def delete_image(product_id: UUID, image_id: UUID, vendor: ApprovedVendor = Depends(require_approved_vendor), service: ProductImageService = Depends(get_image_service)):
    service.delete(vendor, product_id, image_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
