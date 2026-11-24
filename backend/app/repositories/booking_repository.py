from postgrest.types import CountMethod

from app.repositories.base import BaseRepository, Row


class BookingRepository(BaseRepository):
    """READ access to bookings and their children (user-scoped client => RLS). Writes go through ServiceGateway (SQL functions),
    except customer image rows, which the policy 'booking_images_customer_*' allows for the owner's pending booking."""

    table = "service_bookings"

    def __init__(self, client):
        super().__init__(client)

    def search(self, *, customer_id=None, vendor_id=None, status=None, date_from=None, date_to=None, number_like=None, page=1, limit=20) -> tuple[list[Row], int]:
        q = self.client.table(self.table).select("*", count=CountMethod.exact)
        if customer_id:
            q = q.eq("customer_id", customer_id)
        if vendor_id:
            q = q.eq("vendor_id", vendor_id)
        if status:
            q = q.eq("status", status)
        if date_from:
            q = q.gte("preferred_date", date_from)
        if date_to:
            q = q.lte("preferred_date", date_to)
        if number_like:
            q = q.ilike("booking_number", f"*{number_like}*")
        offset = (page - 1) * limit
        res = self._run(q.order("created_at", desc=True).order("id").range(offset, offset + limit - 1))
        return res.data, res.count or 0

    def find(self, booking_id: str, *, customer_id: str | None = None, vendor_id: str | None = None) -> Row | None:
        q = self.client.table(self.table).select("*").eq("id", booking_id)
        if customer_id:
            q = q.eq("customer_id", customer_id)
        if vendor_id:
            q = q.eq("vendor_id", vendor_id)
        res = self._run(q.limit(1))
        return res.data[0] if res.data else None

    def history(self, booking_id: str) -> list[Row]:
        return self._run(self.client.table("booking_status_history").select("*").eq("booking_id", booking_id).order("created_at").order("id")).data

    def charges(self, booking_id: str) -> list[Row]:
        return self._run(self.client.table("service_charges").select("*").eq("booking_id", booking_id).order("created_at").order("id")).data

    def notes(self, booking_id: str) -> list[Row]:
        return self._run(self.client.table("service_booking_notes").select("*").eq("booking_id", booking_id).order("created_at").order("id")).data

    def images(self, booking_id: str) -> list[Row]:
        return self._run(self.client.table("service_booking_images").select("*").eq("booking_id", booking_id).order("created_at").order("id")).data

    def add_image(self, values: Row) -> Row:
        return self._run(self.client.table("service_booking_images").insert(values)).data[0]

    def find_image(self, booking_id: str, image_id: str) -> Row | None:
        res = self._run(self.client.table("service_booking_images").select("*").eq("booking_id", booking_id).eq("id", image_id).limit(1))
        return res.data[0] if res.data else None

    def delete_image(self, image_id: str) -> None:
        self._run(self.client.table("service_booking_images").delete().eq("id", image_id))

    # ---- pickup / drop-off
    def pickups_for(self, booking_ids: list[str]) -> list[Row]:
        if not booking_ids:
            return []
        return self._run(self.client.table("pickup_dropoff_requests").select("*").in_("booking_id", booking_ids)).data

    def find_pickup(self, request_id: str) -> Row | None:
        res = self._run(self.client.table("pickup_dropoff_requests").select("*").eq("id", request_id).limit(1))
        return res.data[0] if res.data else None

    def list_pickups(self, *, booking_ids: list[str] | None = None, pickup_status=None, delivery_status=None, page=1, limit=20) -> tuple[list[Row], int]:
        q = self.client.table("pickup_dropoff_requests").select("*", count=CountMethod.exact)
        if booking_ids is not None:
            q = q.in_("booking_id", booking_ids or ["00000000-0000-0000-0000-000000000000"])
        if pickup_status:
            q = q.eq("pickup_status", pickup_status)
        if delivery_status:
            q = q.eq("delivery_status", delivery_status)
        offset = (page - 1) * limit
        res = self._run(q.order("created_at", desc=True).order("id").range(offset, offset + limit - 1))
        return res.data, res.count or 0

    def bookings_by_ids(self, ids: list[str]) -> list[Row]:
        return self._run(self.client.table(self.table).select("*").in_("id", ids)).data if ids else []

    def profiles(self, ids: list[str], cols: str = "id,full_name,phone") -> list[Row]:
        return self._run(self.client.table("profiles").select(cols).in_("id", ids)).data if ids else []

    def vendor_profiles(self, ids: list[str]) -> list[Row]:
        cols = "id,business_name,city,state,contact_phone,verification_status"
        return self._run(self.client.table("vendor_profiles").select(cols).in_("id", ids)).data if ids else []


class ServiceGateway(BaseRepository):
    """Typed access to the Step 6 SQL functions (service role). Authorisation is done by the caller; the actor is recorded."""

    table = "service_bookings"

    def __init__(self, admin_client):
        super().__init__(admin_client)

    def _call(self, fn: str, params: dict):
        return self._run(self.client.rpc(fn, params)).data

    def create_booking(self, payload: dict) -> dict:
        return self._call("create_service_booking", {"p": payload})

    def accept(self, booking_id, vendor_id, actor_id, date, start, end, note) -> dict:
        return self._call("accept_service_booking", {"p_booking": booking_id, "p_vendor": vendor_id, "p_actor": actor_id, "p_date": date, "p_start": start, "p_end": end, "p_note": note})

    def reschedule(self, booking_id, vendor_id, actor_id, role, date, start, end, note) -> dict:
        return self._call("reschedule_service_booking", {"p_booking": booking_id, "p_vendor": vendor_id, "p_actor": actor_id, "p_role": role, "p_date": date, "p_start": start, "p_end": end, "p_note": note})

    def transition(self, booking_id, vendor_id, status, actor_id, role, note) -> dict:
        return self._call("transition_service_booking", {"p_booking": booking_id, "p_vendor": vendor_id, "p_status": status, "p_actor": actor_id, "p_role": role, "p_note": note})

    def add_charge(self, booking_id, vendor_id, actor_id, role, amount, reason) -> dict:
        return self._call("add_service_charge", {"p_booking": booking_id, "p_vendor": vendor_id, "p_actor": actor_id, "p_role": role, "p_amount": str(amount), "p_reason": reason})

    def add_note(self, booking_id, vendor_id, actor_id, role, note) -> str:
        return self._call("add_service_note", {"p_booking": booking_id, "p_vendor": vendor_id, "p_actor": actor_id, "p_role": role, "p_note": note})

    def set_logistics(self, request_id, vendor_id, actor_id, role, changes: dict) -> dict:
        return self._call("set_service_logistics", {"p_request": request_id, "p_vendor": vendor_id, "p_actor": actor_id, "p_role": role, "p": changes})
