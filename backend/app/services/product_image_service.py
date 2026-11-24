"""Product image management.

Upload flow (files never pass through FastAPI or PostgreSQL):
  1. The vendor app uploads the file DIRECTLY to Supabase Storage bucket `product-images` using the vendor's own
     Supabase session, at path  <vendor_user_id>/<product_id>/<file name>.(jpg|jpeg|png|webp)  (max 5 MB).
     Storage RLS (migration 09) allows this only for approved vendors inside their own folder.
  2. The app then calls POST /vendor/products/{id}/images with that path. This service re-validates the path,
     confirms the object exists, checks type and size, and stores the reference in `product_images`.
"""
from __future__ import annotations

import logging
import re
from uuid import UUID

from app.core.config import get_settings
from app.core.dependencies import ApprovedVendor
from app.core.exceptions import NotFoundError, conflict, unprocessable
from app.integrations.supabase import delete_storage_object, head_public_object
from app.repositories.product_image_repository import ProductImageRepository
from app.repositories.product_repository import ProductRepository
from app.schemas.product import ImageOrder, ImagePatch, ImageRegister
from app.services import _catalog
from app.services._updates import changes

logger = logging.getLogger(__name__)
BUCKET = "product-images"
ALLOWED_TYPES = {"image/jpeg", "image/png", "image/webp"}
_FILE = re.compile(r"^[A-Za-z0-9_\-. ]{1,120}\.(jpg|jpeg|png|webp)$", re.IGNORECASE)


class ProductImageService:
    def __init__(self, db):
        self.products = ProductRepository(db)
        self.images = ProductImageRepository(db)

    def list(self, vendor: ApprovedVendor, product_id: UUID) -> list[dict]:
        product = self._product(vendor, product_id)
        return [_catalog.image_out(i) for i in self.images.for_product(product["id"])]

    def register(self, vendor: ApprovedVendor, product_id: UUID, data: ImageRegister) -> dict:
        product = self._product(vendor, product_id)
        self._validate_path(vendor, product["id"], data.storage_path)
        existing = self.images.for_product(product["id"])
        if len(existing) >= get_settings().max_product_images:
            raise conflict("image_limit", f"A product can have at most {get_settings().max_product_images} images.")
        self._check_object(data.storage_path)
        make_primary = data.is_primary or not existing
        if make_primary:
            self.images.clear_primary(product["id"])
        row = self.images.add({"product_id": product["id"], "storage_path": data.storage_path, "alt_text": data.alt_text,
                               "sort_order": max((i["sort_order"] for i in existing), default=-1) + 1, "is_primary": make_primary})
        return _catalog.image_out(row)

    def patch(self, vendor: ApprovedVendor, product_id: UUID, image_id: UUID, data: ImagePatch) -> dict:
        product = self._product(vendor, product_id)
        image = self._image(product["id"], image_id)
        values = changes(data, nullable={"alt_text"})
        if values.get("is_primary") is False and image["is_primary"]:
            raise conflict("primary_required", "Choose another image as primary instead.")
        if values.get("is_primary") is True and not image["is_primary"]:
            self.images.clear_primary(product["id"])
        return _catalog.image_out(self.images.modify(image["id"], values))

    def reorder(self, vendor: ApprovedVendor, product_id: UUID, data: ImageOrder) -> list[dict]:
        product = self._product(vendor, product_id)
        current = {i["id"] for i in self.images.for_product(product["id"])}
        wanted = [str(i) for i in data.image_ids]
        if set(wanted) != current or len(wanted) != len(current):
            raise unprocessable("invalid_order", "image_ids must list every image of this product exactly once.")
        for position, image_id in enumerate(wanted):
            self.images.modify(image_id, {"sort_order": position})
        return [_catalog.image_out(i) for i in self.images.for_product(product["id"])]

    def delete(self, vendor: ApprovedVendor, product_id: UUID, image_id: UUID) -> None:
        product = self._product(vendor, product_id)
        image = self._image(product["id"], image_id)
        delete_storage_object(vendor.user.access_token, BUCKET, image["storage_path"])  # as the vendor: storage RLS applies
        self.images.remove(image["id"])
        if image["is_primary"]:
            rest = self.images.for_product(product["id"])
            if rest:
                self.images.modify(rest[0]["id"], {"is_primary": True})

    # ---------------- helpers ----------------
    def _product(self, vendor: ApprovedVendor, product_id: UUID) -> dict:
        row = self.products.find(str(product_id), vendor_id=vendor.vendor["id"])
        if row is None:
            raise NotFoundError("Product not found.")
        return row

    def _image(self, product_id: str, image_id: UUID) -> dict:
        row = self.images.find(product_id, str(image_id))
        if row is None:
            raise NotFoundError("Image not found.")
        return row

    @staticmethod
    def _validate_path(vendor: ApprovedVendor, product_id: str, path: str) -> None:
        parts = path.split("/")
        ok = (len(parts) == 3 and parts[0] == vendor.user.id and parts[1] == product_id and _FILE.match(parts[2]) and ".." not in path)
        if not ok:
            raise unprocessable("invalid_image_path", f"storage_path must look like '{vendor.user.id}/{product_id}/<file>.jpg|png|webp'.")

    @staticmethod
    def _check_object(path: str) -> None:
        info = head_public_object(BUCKET, path)
        if info is None:
            raise unprocessable("image_not_uploaded", "No file was found at that path. Upload it to Storage first.")
        _, content_type, size = info
        if content_type not in ALLOWED_TYPES:
            raise unprocessable("unsupported_image_type", "Only JPEG, PNG or WebP images are allowed.")
        if size > get_settings().max_image_bytes:
            raise unprocessable("image_too_large", f"Images must be at most {get_settings().max_image_bytes // (1024 * 1024)} MB.")
