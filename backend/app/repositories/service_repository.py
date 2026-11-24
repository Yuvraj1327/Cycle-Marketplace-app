from postgrest.types import CountMethod

from app.repositories.base import BaseRepository, Row


class ServiceCategoryRepository(BaseRepository):
    table = "service_categories"

    def __init__(self, client):
        super().__init__(client)

    def list_all(self, *, active_only: bool) -> list[Row]:
        q = self.client.table(self.table).select("*")
        if active_only:
            q = q.eq("is_active", True)
        return self._run(q.order("sort_order").order("name")).data

    def find(self, category_id: str) -> Row | None:
        res = self._run(self.client.table(self.table).select("*").eq("id", category_id).limit(1))
        return res.data[0] if res.data else None

    def slugs_like(self, base: str) -> set[str]:
        return {r["slug"] for r in self._run(self.client.table(self.table).select("slug").ilike("slug", f"{base}*")).data}

    def service_count(self, category_id: str, *, public_only: bool) -> int:
        q = self.client.table("vendor_services").select("id", count=CountMethod.exact, head=True).eq("service_category_id", category_id)
        if public_only:
            q = q.eq("is_active", True).eq("is_available", True)
        return self._run(q).count or 0

    def booking_count(self, category_id: str) -> int:
        return self._run(self.client.table("service_bookings").select("id", count=CountMethod.exact, head=True).eq("service_category_id", category_id)).count or 0


class VendorServiceRepository(BaseRepository):
    table = "vendor_services"

    def __init__(self, client):
        super().__init__(client)

    def search(self, *, category_id=None, vendor_id=None, active_only=False, is_active=None, q_name=None, page=1, limit=20) -> tuple[list[Row], int]:
        q = self.client.table(self.table).select("*", count=CountMethod.exact)
        if active_only:
            q = q.eq("is_active", True).eq("is_available", True)
        if is_active is not None:
            q = q.eq("is_active", is_active)
        if category_id:
            q = q.eq("service_category_id", category_id)
        if vendor_id:
            q = q.eq("vendor_id", vendor_id)
        if q_name:
            q = q.ilike("name", f"*{q_name}*")
        offset = (page - 1) * limit
        res = self._run(q.order("price").order("name").order("id").range(offset, offset + limit - 1))
        return res.data, res.count or 0

    def find(self, service_id: str, *, vendor_id: str | None = None) -> Row | None:
        q = self.client.table(self.table).select("*").eq("id", service_id)
        if vendor_id:
            q = q.eq("vendor_id", vendor_id)
        res = self._run(q.limit(1))
        return res.data[0] if res.data else None

    def modify(self, service_id: str, values: Row, *, vendor_id: str) -> Row | None:
        res = self._run(self.client.table(self.table).update(values).eq("id", service_id).eq("vendor_id", vendor_id))
        return res.data[0] if res.data else None

    def remove(self, service_id: str, *, vendor_id: str) -> None:
        self._run(self.client.table(self.table).delete().eq("id", service_id).eq("vendor_id", vendor_id))

    def has_bookings(self, service_id: str) -> bool:
        return bool(self._run(self.client.table("service_bookings").select("id").eq("vendor_service_id", service_id).limit(1)).data)

    def categories_by_ids(self, ids: list[str]) -> list[Row]:
        return self._run(self.client.table("service_categories").select("*").in_("id", ids)).data if ids else []

    def vendors_public(self, vendor_ids: list[str]) -> list[Row]:
        cols = "id,business_name,city,state,business_types,pickup_available,service_area_postal_codes,service_radius_km,operating_hours"
        return self._run(self.client.table("vendor_public_profiles").select(cols).in_("id", vendor_ids)).data if vendor_ids else []

    def booked_counts(self, service_id: str, day: str) -> list[Row]:
        """ACCEPTED bookings of this service on a date (slot start only: nothing private). Needs the service client: customers cannot read others' bookings."""
        q = self.client.table("service_bookings").select("confirmed_slot_start").eq("vendor_service_id", service_id).eq("confirmed_date", day).eq("status", "accepted")
        return self._run(q).data
