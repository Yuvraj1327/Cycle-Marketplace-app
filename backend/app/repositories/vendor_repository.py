from app.repositories.base import BaseRepository, Row


class VendorRepository(BaseRepository):
    table = "vendor_profiles"

    def __init__(self, client):
        super().__init__(client)

    def find_by_user(self, user_id: str) -> Row | None:
        res = self._run(self.client.table(self.table).select("*").eq("user_id", user_id).limit(1))
        return res.data[0] if res.data else None

    def create_for_user(self, values: Row) -> Row:
        return self.create(values)

    def update_for_user(self, user_id: str, values: Row) -> Row:
        return self.update(user_id, values, id_column="user_id")
