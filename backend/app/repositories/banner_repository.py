from app.repositories.base import BaseRepository, Row


class BannerRepository(BaseRepository):
    table = "banners"

    def __init__(self, client):
        super().__init__(client)

    def list_all(self, *, active_only: bool) -> list[Row]:
        q = self.client.table(self.table).select("*")
        if active_only:
            q = q.eq("is_active", True)  # RLS additionally enforces the starts_at/ends_at window for non-admins
        return self._run(q.order("sort_order").order("created_at", desc=True)).data

    def find(self, banner_id: str) -> Row | None:
        res = self._run(self.client.table(self.table).select("*").eq("id", banner_id).limit(1))
        return res.data[0] if res.data else None
