from app.repositories.base import BaseRepository, Row


class ProfileRepository(BaseRepository):
    table = "profiles"

    def __init__(self, client):  # a user-scoped client is mandatory: no silent service-role fallback
        super().__init__(client)

    def get(self, user_id: str) -> Row:
        return self.get_by_id(user_id)

    def update_own(self, user_id: str, values: Row) -> Row:
        return self.update(user_id, values)
