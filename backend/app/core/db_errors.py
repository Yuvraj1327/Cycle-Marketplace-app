"""Translate Supabase/PostgREST/Postgres errors into AppError subclasses without leaking internals to clients."""
import logging

import httpx

from postgrest.exceptions import APIError

from app.core.exceptions import (
    AppError,
    ConflictError,
    DatabaseError,
    ServiceUnavailableError,
    NotFoundError,
    PermissionDeniedError,
    ValidationFailedError,
)

logger = logging.getLogger(__name__)

_SQLSTATE_MAP: dict[str, type[AppError]] = {
    "23505": ConflictError,            # unique_violation
    "23503": ValidationFailedError,    # foreign_key_violation
    "23502": ValidationFailedError,    # not_null_violation
    "23514": ValidationFailedError,    # check_violation
    "22P02": ValidationFailedError,    # invalid_text_representation
    "42501": PermissionDeniedError,    # insufficient_privilege (RLS / guard triggers)
    "PGRST116": NotFoundError,         # .single() matched no rows
    "PGRST301": PermissionDeniedError, # JWT problems
}


# Business errors raised by the order/payment SQL functions as  'CM:<code>:<detail>'  ->  (HTTP status, message)
CM_ERRORS: dict[str, tuple[int, str]] = {
    "insufficient_stock": (409, "There is not enough stock for one of the items."),
    "product_unavailable": (409, "One of the items is no longer available."),
    "vendor_unavailable": (409, "One of the sellers can no longer fulfil orders."),
    "price_changed": (409, "The price of an item changed. Review your cart and try again."),
    "coupon_unavailable": (409, "This coupon can no longer be used."),
    "idempotency_key_reuse": (409, "This Idempotency-Key was already used for a different request."),
    "idempotency_key_required": (400, "An Idempotency-Key of at least 8 characters is required."),
    "empty_cart": (409, "There is nothing to check out."),
    "invalid_total": (422, "The order total must be greater than zero."),
    "invalid_vendor": (422, "An item does not belong to the stated seller."),
    "invalid_quantity": (422, "Invalid quantity."),
    "duplicate_product": (422, "The same product appears twice."),
    "totals_mismatch": (500, "The order totals could not be verified."),
    "not_found": (404, "The record was not found."),
    "not_cancellable": (409, "This order can no longer be cancelled."),
    "invalid_transition": (409, "This status change is not allowed."),
    "order_not_active": (409, "This order is not active."),
    "not_collectable": (409, "This payment cannot be collected."),
    "not_dispatched": (409, "Cash can only be recorded once the order is out for delivery."),
    "refund_exceeds": (409, "The refund would exceed the amount paid."),
    "payment_not_refundable": (409, "This payment cannot be refunded."),
    "invalid_amount": (422, "Invalid amount."),
    "not_online_order": (409, "Only online orders can be paid online."),
    "order_not_payable": (409, "This order can no longer be paid."),
    "payment_window_expired": (409, "The payment window for this order has expired."),
    # servicing
    "duplicate_booking": (409, "You already have an open booking for this service in that time slot."),
    "service_unavailable": (409, "This service is not available for booking right now."),
    "account_inactive": (403, "Your account cannot create bookings."),
    "pickup_not_offered": (422, "This provider does not offer doorstep pickup."),
    "slot_full": (409, "That time slot is already fully booked."),
    "use_accept": (422, "Use the accept endpoint to accept a booking."),
    "reason_required": (422, "A reason is required."),
    "charge_not_allowed": (409, "Charges can only be recorded while the booking is being worked on."),
    "final_negative": (422, "That adjustment would make the final price negative."),
    "use_booking_status": (422, "Pickup and delivery completion are recorded by updating the booking status."),
    "schedule_required": (422, "A scheduled time is required to mark this step as scheduled."),
    # admin operations
    "no_recipients": (409, "There is nobody to send this to: no active accounts match the chosen audience."),
    "invalid_audience": (422, "Choose customers, vendors or specific recipients."),
    "invalid_report": (422, "Unknown report."),
}


def _business_error(message: str) -> AppError | None:
    if not message.startswith("CM:"):
        return None
    _, _, rest = message.partition("CM:")
    code, _, detail = rest.partition(":")
    status, text = CM_ERRORS.get(code, (409, "The operation was refused."))
    err = AppError(text, [{"detail": detail}] if detail else None)
    err.status_code, err.code = status, code
    return err


def translate_db_error(exc: Exception) -> AppError:
    if isinstance(exc, AppError):
        return exc
    if isinstance(exc, APIError):
        business = _business_error(str(getattr(exc, "message", "") or ""))
        if business:
            return business
        code = str(getattr(exc, "code", "") or "")
        logger.warning("Database error code=%s message=%s", code, getattr(exc, "message", exc))
        return _SQLSTATE_MAP.get(code, DatabaseError)()
    if isinstance(exc, httpx.TransportError):       # connection refused / DNS / timeout: Supabase is unreachable, which is temporary
        logger.error("Database service unreachable: %s", type(exc).__name__)
        return ServiceUnavailableError("The service is temporarily unreachable. Please try again in a moment.")
    logger.exception("Unexpected database failure")
    return DatabaseError()
