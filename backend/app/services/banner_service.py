from app.core.exceptions import NotFoundError, unprocessable
from app.integrations.supabase import public_storage_url
from app.repositories.banner_repository import BannerRepository
from app.schemas.banner import BannerCreate, BannerUpdate, _check_action
from app.services._updates import changes


def banner_out(row: dict, admin: bool = False) -> dict:
    out = {"id": row["id"], "title": row["title"], "subtitle": row.get("subtitle"), "image_url": public_storage_url("banners", row["image_path"]),
           "action_type": row["action_type"], "action_value": row.get("action_value"), "sort_order": row["sort_order"]}
    if admin:
        out.update(image_path=row["image_path"], is_active=row["is_active"], starts_at=row.get("starts_at"), ends_at=row.get("ends_at"),
                   created_at=row["created_at"], updated_at=row["updated_at"])
    return out


class BannerService:
    def __init__(self, repo: BannerRepository):
        self.repo = repo

    def public_list(self) -> list[dict]:
        return [banner_out(r) for r in self.repo.list_all(active_only=True)]

    def admin_list(self) -> list[dict]:
        return [banner_out(r, True) for r in self.repo.list_all(active_only=False)]

    def create(self, data: BannerCreate, admin_id: str) -> dict:
        values = data.model_dump(mode="json")
        return banner_out(self.repo.create({**values, "created_by": admin_id}), True)

    def update(self, banner_id: str, data: BannerUpdate) -> dict:
        current = self.repo.find(banner_id)
        if current is None:
            raise NotFoundError("Banner not found.")
        values = changes(data, nullable={"subtitle", "action_value", "starts_at", "ends_at"})
        if "action_type" in values or "action_value" in values:
            try:
                _check_action(values.get("action_type", current["action_type"]), values["action_value"] if "action_value" in values else (None if "action_type" in values else current.get("action_value")))
            except ValueError as exc:
                raise unprocessable("invalid_action", str(exc)) from exc
        return banner_out(self.repo.update(banner_id, values), True)

    def delete(self, banner_id: str) -> None:
        if self.repo.find(banner_id) is None:
            raise NotFoundError("Banner not found.")
        self.repo.delete(banner_id)
