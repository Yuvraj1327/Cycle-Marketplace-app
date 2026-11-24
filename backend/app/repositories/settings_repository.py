from app.repositories.base import BaseRepository


class SettingsRepository(BaseRepository):
    """platform_settings. Non-public keys are readable only by admins/service role, so this uses the service client."""

    table = "platform_settings"

    def __init__(self, client):
        super().__init__(client)

    def get_value(self, key: str, default=None):
        res = self._run(self.client.table(self.table).select("value").eq("key", key).limit(1))
        return res.data[0]["value"] if res.data else default
