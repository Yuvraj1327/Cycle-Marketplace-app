from postgrest.types import CountMethod

from app.repositories.base import BaseRepository, Row


class SupportRepository(BaseRepository):
    table = "support_tickets"

    def __init__(self, client):
        super().__init__(client)

    def search(self, *, requester_id=None, status=None, ticket_type=None, booking_id=None, order_id=None, page=1, limit=20) -> tuple[list[Row], int]:
        q = self.client.table(self.table).select("*", count=CountMethod.exact)
        for col, val in (("requester_id", requester_id), ("status", status), ("type", ticket_type), ("service_booking_id", booking_id), ("order_id", order_id)):
            if val:
                q = q.eq(col, val)
        offset = (page - 1) * limit
        res = self._run(q.order("created_at", desc=True).order("id").range(offset, offset + limit - 1))
        return res.data, res.count or 0

    def find(self, ticket_id: str, *, requester_id: str | None = None) -> Row | None:
        q = self.client.table(self.table).select("*").eq("id", ticket_id)
        if requester_id:
            q = q.eq("requester_id", requester_id)
        res = self._run(q.limit(1))
        return res.data[0] if res.data else None

    def modify(self, ticket_id: str, values: Row) -> Row | None:
        res = self._run(self.client.table(self.table).update(values).eq("id", ticket_id))
        return res.data[0] if res.data else None
