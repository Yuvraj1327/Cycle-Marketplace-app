from uuid import UUID

from fastapi import APIRouter, Depends, Query
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E404, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_current_active_user, get_user_db
from app.schemas.notification import NotificationOut, NotificationPage, ReadAllResult
from app.services.notification_service import NotificationService

router = APIRouter(prefix="/notifications", tags=["Notifications"], responses=PROTECTED)
_NOTE = "**Protected - any signed-in user.** Your own in-app notifications only. (Push delivery is a later step.)"


def get_service(db: SyncPostgrestClient = Depends(get_user_db)) -> NotificationService:
    return NotificationService(db)


@router.get("", response_model=NotificationPage, summary="My notifications",
            description=_NOTE + " Newest first. `unread_count` counts all unread, regardless of paging/filter.", responses=E422)
def list_notifications(unread_only: bool = False, page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
                       user: CurrentUser = Depends(get_current_active_user), service: NotificationService = Depends(get_service)):
    return service.list(user, unread_only=unread_only, page=page, limit=limit)


@router.post("/read-all", response_model=ReadAllResult, summary="Mark all as read", description=_NOTE)
def read_all(user: CurrentUser = Depends(get_current_active_user), service: NotificationService = Depends(get_service)):
    return service.mark_all_read(user)


@router.post("/{notification_id}/read", response_model=NotificationOut, summary="Mark one as read", description=_NOTE + " Someone else's notification is a 404.",
             responses={**E404, **E422})
def read_one(notification_id: UUID, user: CurrentUser = Depends(get_current_active_user), service: NotificationService = Depends(get_service)):
    return service.mark_read(user, notification_id)
