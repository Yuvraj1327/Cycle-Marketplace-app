"""Slot generation from the vendor's own operating hours. No staff calendars, no shifts: a slot is a fixed-length window inside opening
hours, with a per-service capacity of simultaneously ACCEPTED bookings."""
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from typing import Any

DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")


@dataclass(frozen=True)
class Slot:
    start: time
    end: time

    @property
    def label(self) -> str:
        return f"{self.start:%H:%M}-{self.end:%H:%M}"


def weekday_key(d: date) -> str:
    return DAYS[d.weekday()]


def parse_hhmm(value: str) -> time:
    return datetime.strptime(value, "%H:%M").time()


def opening_window(operating_hours: Any, d: date) -> tuple[time, time] | None:
    """(open, close) for that weekday, or None if closed / not configured."""
    if not isinstance(operating_hours, dict):
        return None
    day = operating_hours.get(weekday_key(d))
    if not isinstance(day, dict) or day.get("closed") or not day.get("open") or not day.get("close"):
        return None
    try:
        start, end = parse_hhmm(day["open"]), parse_hhmm(day["close"])
    except ValueError:
        return None
    return (start, end) if end > start else None


def build_slots(window: tuple[time, time], slot_minutes: int) -> list[Slot]:
    """Back-to-back slots starting at opening time; a slot must END by closing time."""
    start, close = window
    base = datetime.combine(date(2000, 1, 1), start)
    limit = datetime.combine(date(2000, 1, 1), close)
    slots, cur = [], base
    while cur + timedelta(minutes=slot_minutes) <= limit:
        slots.append(Slot(cur.time(), (cur + timedelta(minutes=slot_minutes)).time()))
        cur += timedelta(minutes=slot_minutes)
    return slots


def slot_is_bookable_time(d: date, slot: Slot, now_local: datetime, min_notice_hours: int) -> bool:
    earliest = now_local.replace(tzinfo=None) + timedelta(hours=min_notice_hours)
    return datetime.combine(d, slot.start) >= earliest
