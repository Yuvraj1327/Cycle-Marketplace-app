"""Generic table repository. Keeps all PostgREST calls out of API routes/services.

Concrete repositories (added in later steps) subclass this per table, e.g.
    class ProductRepository(BaseRepository): table = "products"
"""
from typing import Any

from supabase import Client

from app.core.db_errors import translate_db_error
from app.core.exceptions import NotFoundError
from app.core.supabase import get_admin_client

Row = dict[str, Any]


class BaseRepository:
    table: str = ""

    def __init__(self, client: Client | None = None):
        if not self.table:
            raise TypeError(f"{type(self).__name__} must define `table`")
        self._client = client  # None => resolved lazily to the admin client

    @property
    def client(self) -> Client:
        return self._client or get_admin_client()

    def _run(self, builder: Any) -> Any:
        try:
            return builder.execute()
        except Exception as exc:  # noqa: BLE001 - every failure is mapped to an AppError
            raise translate_db_error(exc) from exc

    def get_by_id(self, record_id: str, id_column: str = "id") -> Row:
        res = self._run(self.client.table(self.table).select("*").eq(id_column, record_id).limit(1))
        if not res.data:
            raise NotFoundError()
        return res.data[0]

    def list(self, *, limit: int = 50, offset: int = 0, order_by: str = "created_at", desc: bool = True, **filters: Any) -> list[Row]:
        query = self.client.table(self.table).select("*")
        for column, value in filters.items():
            query = query.eq(column, value)
        res = self._run(query.order(order_by, desc=desc).range(offset, offset + limit - 1))
        return res.data

    def create(self, values: Row) -> Row:
        res = self._run(self.client.table(self.table).insert(values))
        return res.data[0]

    def update(self, record_id: str, values: Row, id_column: str = "id") -> Row:
        res = self._run(self.client.table(self.table).update(values).eq(id_column, record_id))
        if not res.data:
            raise NotFoundError()
        return res.data[0]

    def delete(self, record_id: str, id_column: str = "id") -> None:
        self._run(self.client.table(self.table).delete().eq(id_column, record_id))
