from datetime import datetime, timezone

from app.core.dependencies import CurrentUser
from app.integrations.supabase import revoke_session
from app.repositories.vendor_repository import VendorRepository
from app.schemas.auth import MeResponse, SessionInfo


class AuthService:
    def __init__(self, vendor_repo: VendorRepository):
        self.vendor_repo = vendor_repo

    def me(self, user: CurrentUser) -> MeResponse:
        vendor_status = None
        if user.role == "vendor":
            vendor = self.vendor_repo.find_by_user(user.id)
            vendor_status = vendor["verification_status"] if vendor else None
        return MeResponse(
            id=user.id,
            email=user.email,
            phone=user.auth_phone or user.profile.get("phone"),
            role=user.role,
            status=user.status,
            vendor_verification_status=vendor_status,
            session=SessionInfo(
                session_id=user.claims.session_id,
                assurance_level=user.claims.aal,
                token_expires_at=datetime.fromtimestamp(user.claims.exp, tz=timezone.utc),
            ),
            profile=user.profile,
        )

    @staticmethod
    def logout(access_token: str, scope: str) -> None:
        revoke_session(access_token, scope)
