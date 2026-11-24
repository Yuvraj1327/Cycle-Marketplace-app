from app.core.dependencies import CurrentUser
from app.core.exceptions import ConflictError, NotFoundError, PermissionDeniedError, ValidationFailedError
from app.repositories.base import Row
from app.repositories.vendor_repository import VendorRepository
from app.schemas.vendor import VendorRegister, VendorStatusResponse, VendorUpdate
from app.services._updates import changes

NULLABLE = {"description", "address_line2", "contact_email", "service_radius_km"}


def _check_image_paths(user: CurrentUser, paths: list[str]) -> None:
    if any(not p.startswith(f"{user.id}/") for p in paths):
        raise ValidationFailedError("shop_image_paths must be inside your own storage folder.")


class VendorService:
    def __init__(self, repo: VendorRepository):
        self.repo = repo

    def register(self, user: CurrentUser, data: VendorRegister) -> Row:
        if self.repo.find_by_user(user.id):
            raise ConflictError("A vendor application already exists for this account.")
        _check_image_paths(user, data.shop_image_paths)
        values = data.model_dump(mode="json")
        # verification_status is never sent: the database default ('pending') and guard trigger decide it.
        return self.repo.create_for_user({**values, "user_id": user.id})

    def get_own(self, user: CurrentUser) -> Row:
        row = self.repo.find_by_user(user.id)
        if row is None:
            raise NotFoundError("No vendor application found. Register your business first.")
        return row

    def update_own(self, user: CurrentUser, data: VendorUpdate) -> Row:
        current = self.get_own(user)
        if current["verification_status"] == "suspended":
            err = PermissionDeniedError("Your vendor account is suspended.")
            err.code = "vendor_suspended"
            raise err
        values = changes(data, nullable=NULLABLE)
        if "shop_image_paths" in values:
            _check_image_paths(user, values["shop_image_paths"])
        return self.repo.update_for_user(user.id, values)

    def status(self, user: CurrentUser) -> VendorStatusResponse:
        row = self.get_own(user)
        return VendorStatusResponse(
            verification_status=row["verification_status"],
            rejection_reason=row.get("rejection_reason"),
            reviewed_at=row.get("reviewed_at"),
            can_operate=row["verification_status"] == "approved",
        )
