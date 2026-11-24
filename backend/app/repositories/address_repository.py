from app.core.exceptions import NotFoundError
from app.repositories.base import BaseRepository, Row


class AddressRepository(BaseRepository):
    """Every query is filtered by user_id in addition to the RLS policy (defence in depth)."""

    table = "user_addresses"

    def __init__(self, client):
        super().__init__(client)

    def list_for_user(self, user_id: str) -> list[Row]:
        q = (
            self.client.table(self.table).select("*").eq("user_id", user_id)
            .order("is_default", desc=True).order("created_at", desc=True)
        )
        return self._run(q).data

    def find_for_user(self, address_id: str, user_id: str) -> Row | None:
        res = self._run(self.client.table(self.table).select("*").eq("id", address_id).eq("user_id", user_id).limit(1))
        return res.data[0] if res.data else None

    def get_for_user(self, address_id: str, user_id: str) -> Row:
        row = self.find_for_user(address_id, user_id)
        if row is None:
            raise NotFoundError("Address not found.")
        return row

    def count_for_user(self, user_id: str) -> int:
        return len(self._run(self.client.table(self.table).select("id").eq("user_id", user_id)).data)

    def default_for_user(self, user_id: str) -> Row | None:
        res = self._run(self.client.table(self.table).select("*").eq("user_id", user_id).eq("is_default", True).limit(1))
        return res.data[0] if res.data else None

    def create_for_user(self, values: Row) -> Row:
        return self.create(values)

    def update_for_user(self, address_id: str, user_id: str, values: Row) -> Row:
        res = self._run(self.client.table(self.table).update(values).eq("id", address_id).eq("user_id", user_id))
        if not res.data:
            raise NotFoundError("Address not found.")
        return res.data[0]

    def delete_for_user(self, address_id: str, user_id: str) -> None:
        self._run(self.client.table(self.table).delete().eq("id", address_id).eq("user_id", user_id))

    def clear_default(self, user_id: str) -> None:
        self._run(self.client.table(self.table).update({"is_default": False}).eq("user_id", user_id).eq("is_default", True))
