from uuid import UUID

from app.core.dependencies import CurrentUser
from app.core.exceptions import AppError, ValidationFailedError
from app.repositories.address_repository import AddressRepository
from app.repositories.base import Row
from app.schemas.address import AddressCreate, AddressUpdate, _check_postal
from app.services._updates import changes


class AddressService:
    def __init__(self, repo: AddressRepository):
        self.repo = repo

    def list(self, user: CurrentUser) -> list[Row]:
        return self.repo.list_for_user(user.id)

    def get(self, user: CurrentUser, address_id: UUID) -> Row:
        return self.repo.get_for_user(str(address_id), user.id)

    def create(self, user: CurrentUser, data: AddressCreate) -> Row:
        is_first = self.repo.count_for_user(user.id) == 0
        values = data.model_dump(mode="json", exclude={"is_default"})
        row = self.repo.create_for_user({**values, "user_id": user.id, "is_default": False})
        if data.is_default or is_first:  # a customer's first address becomes the default
            row = self._make_default(user.id, row["id"])
        return row

    def update(self, user: CurrentUser, address_id: UUID, data: AddressUpdate) -> Row:
        values = changes(data, nullable={"label", "address_line2", "landmark"})
        current = self.repo.get_for_user(str(address_id), user.id)
        if "postal_code" in values or "country" in values:
            try:
                _check_postal(values.get("country", current["country"]), values.get("postal_code", current["postal_code"]))
            except ValueError as exc:
                raise ValidationFailedError(str(exc)) from exc
        return self.repo.update_for_user(str(address_id), user.id, values)

    def delete(self, user: CurrentUser, address_id: UUID) -> None:
        self.repo.get_for_user(str(address_id), user.id)  # 404 if missing or not yours
        self.repo.delete_for_user(str(address_id), user.id)

    def set_default(self, user: CurrentUser, address_id: UUID) -> Row:
        row = self.repo.get_for_user(str(address_id), user.id)
        if row["is_default"]:
            return row
        return self._make_default(user.id, str(address_id))

    def _make_default(self, user_id: str, address_id: str) -> Row:
        """Two steps (clear, then set) because only one default per user is allowed by a partial unique index.
        If the second step fails the previous default is restored."""
        previous = self.repo.default_for_user(user_id)
        self.repo.clear_default(user_id)
        try:
            return self.repo.update_for_user(address_id, user_id, {"is_default": True})
        except AppError:
            if previous:
                self.repo.update_for_user(previous["id"], user_id, {"is_default": True})
            raise
