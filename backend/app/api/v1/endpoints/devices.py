"""Device registration for push notifications (customer and vendor apps) and the admin view of push delivery."""
from fastapi import APIRouter, Depends, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E403, E422, PROTECTED
from app.core.config import get_settings
from app.core.dependencies import CurrentUser, get_admin_db, get_current_active_user, require_admin
from app.core.exceptions import PermissionDeniedError
from app.integrations.push.base import PushProvider
from app.integrations.push.registry import get_push_provider
from app.repositories.push_repository import PushGateway
from app.schemas.devices import DeviceOut, DeviceRegister, DeviceUnregister, DispatchResult, PushStatus, UnregisterOut
from app.services.push_dispatch_service import PushDispatcher

devices = APIRouter(prefix="/devices", tags=["Devices"], responses=PROTECTED)
admin_push = APIRouter(prefix="/admin/push", tags=["Admin - Notifications"], responses=PROTECTED)


def get_provider_dep() -> PushProvider:
    return get_push_provider()


@devices.put("", response_model=DeviceOut, status_code=status.HTTP_200_OK, summary="Register / refresh this device for push notifications",
             description="**Protected - customer or vendor account.** Idempotent: call it after every sign-in and whenever the FCM token changes. A token is owned by one "
             "user at a time: if the same phone signs in as another account the token moves to that account. A user keeps at most 10 active devices. The app type must "
             "match the account role. Tokens can never be read back.", responses={**E403, **E422})
def register_device(body: DeviceRegister, user: CurrentUser = Depends(get_current_active_user), admin_db: SyncPostgrestClient = Depends(get_admin_db)):
    if user.role not in ("customer", "vendor") or body.app != user.role:
        raise PermissionDeniedError("This account cannot register a device for that app.")
    PushGateway(admin_db).register(user.id, body.token, body.platform, body.app, body.device_label, body.app_version)
    return {"registered": True}


@devices.post("/unregister", response_model=UnregisterOut, summary="Stop push notifications on this device",
              description="**Protected.** Call on sign-out, before discarding the session. Only the account that owns the token can unregister it; anything else is a no-op.",
              responses=E422)
def unregister_device(body: DeviceUnregister, user: CurrentUser = Depends(get_current_active_user), admin_db: SyncPostgrestClient = Depends(get_admin_db)):
    return {"unregistered": PushGateway(admin_db).unregister(user.id, body.token) > 0}


@admin_push.get("/status", response_model=PushStatus, summary="Push delivery status", description="**Protected - admin only.** Is a provider configured, how many devices are registered, outbox counts (7 days), recent failures.")
def push_status(_a: CurrentUser = Depends(require_admin), admin_db: SyncPostgrestClient = Depends(get_admin_db), provider: PushProvider = Depends(get_provider_dep)):
    s = get_settings()
    summary = PushGateway(admin_db).status()
    return {"configured": bool(provider.is_configured()), "provider": (provider.name or None) if provider.is_configured() else None, "dispatcher_enabled": s.push_dispatch_interval_seconds > 0 and provider.is_configured(),
            "by_status": summary.get("by_status") or {}, "active_devices": summary.get("active_devices") or {}, "oldest_pending": summary.get("oldest_pending"), "recent_failures": summary.get("recent_failures") or []}


@admin_push.post("/dispatch", response_model=DispatchResult, summary="Send pending push notifications now",
                 description="**Protected - admin only.** Runs one dispatch cycle (the same code as the background worker; rows are leased so nothing is sent twice). Returns `configured: false` and sends nothing while no provider is configured.")
def dispatch_now(_a: CurrentUser = Depends(require_admin), admin_db: SyncPostgrestClient = Depends(get_admin_db), provider: PushProvider = Depends(get_provider_dep)):
    return PushDispatcher(PushGateway(admin_db), provider, get_settings()).run_once()
