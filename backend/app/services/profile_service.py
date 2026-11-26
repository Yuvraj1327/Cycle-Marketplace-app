from app.core.dependencies import CurrentUser
from app.core.exceptions import PermissionDeniedError, ValidationFailedError
from app.repositories.base import Row
from app.repositories.profile_repository import ProfileRepository
from app.schemas.profile import ProfileUpdate
from app.services._updates import changes


class ProfileService:
    def __init__(self, repo: ProfileRepository):
        self.repo = repo

    def get_own(self, user: CurrentUser) -> Row:
        return self.repo.get(user.id)

    def update_own(self, user: CurrentUser, data: ProfileUpdate) -> Row:
        values = changes(data, nullable={"phone", "avatar_path"})

        if "phone" in values and values["phone"] != user.profile.get("phone") and user.auth_phone:
            # The phone is a verified Supabase Auth identifier; changing it must go through Supabase Auth.
            raise PermissionDeniedError("Your phone number is managed by your sign-in account and cannot be edited here.")

        avatar = values.get("avatar_path")
        if avatar is not None and not avatar.startswith(f"{user.id}/"):
            raise ValidationFailedError("avatar_path must be inside your own storage folder.")

        if "preferences" in values:
            # a partial update changes only the keys that were sent; the stored ones are kept
            sent = {k: v for k, v in (values["preferences"] or {}).items() if v is not None}
            if not sent:
                raise ValidationFailedError("No preferences supplied.")
            values["preferences"] = {**(user.profile.get("preferences") or {}), **sent}

        # role / status / email are not accepted by the schema; the DB guard trigger enforces the same rule.
        return self.repo.update_own(user.id, values)
