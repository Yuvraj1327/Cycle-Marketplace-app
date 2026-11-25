"""Firebase Cloud Messaging (HTTP v1) adapter.

Authenticates with a service-account key the way Google's libraries do - a signed JWT exchanged for a short-lived OAuth access token - using only
PyJWT and httpx (both already dependencies), so no extra SDK is needed. The service-account key is read from the server environment only and is never
logged, returned by an endpoint or sent to a client.

NOT VERIFIED AGAINST LIVE FIREBASE: no Firebase project is available in this environment. The request/response handling follows Google's FCM v1 documentation
and is covered by tests that use a mocked HTTP transport."""
import json
import logging
import threading
import time
from pathlib import Path

import httpx
import jwt

from app.core.config import Settings
from app.integrations.push.base import PushMessage, PushProvider, PushResult

logger = logging.getLogger(__name__)

SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
TOKEN_URI = "https://oauth2.googleapis.com/token"
SEND_URL = "https://fcm.googleapis.com/v1/projects/{project}/messages:send"
RETRYABLE_CODES = {"UNAVAILABLE", "INTERNAL", "QUOTA_EXCEEDED"}


class FcmProvider:
    name = "fcm"

    def __init__(self, *, project_id: str, client_email: str, private_key: str, token_uri: str = TOKEN_URI,
                 http: httpx.Client | None = None, clock=time.time, channel_id: str = "cycle_default"):
        self.project_id, self._email, self._key, self._token_uri = project_id, client_email, private_key, token_uri
        self._http = http or httpx.Client(timeout=10.0)
        self._clock, self._channel = clock, channel_id
        self._token: str | None = None
        self._expires = 0.0
        self._lock = threading.Lock()

    def is_configured(self) -> bool:
        return True

    # ---------------------------------------------------------------- OAuth
    def _access_token(self, force: bool = False) -> str:
        with self._lock:
            now = self._clock()
            if not force and self._token and now < self._expires - 60:
                return self._token
            assertion = jwt.encode({"iss": self._email, "scope": SCOPE, "aud": self._token_uri, "iat": int(now), "exp": int(now) + 3600}, self._key, algorithm="RS256")
            res = self._http.post(self._token_uri, data={"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion})
            res.raise_for_status()
            body = res.json()
            self._token, self._expires = body["access_token"], now + int(body.get("expires_in", 3600))
            return self._token

    # ---------------------------------------------------------------- send
    def send(self, token: str, message: PushMessage) -> PushResult:
        payload = {"message": {"token": token, "notification": {"title": message.title, "body": message.body}, "data": message.data,
                               "android": {"priority": "HIGH", "notification": {"channel_id": self._channel}}}}
        try:
            res = self._post(payload)
            if res.status_code == 401:                       # the cached OAuth token was refused: get a new one once
                res = self._post(payload, force_token=True)
        except (httpx.HTTPError, KeyError, ValueError, jwt.PyJWTError) as exc:
            logger.warning("FCM request failed (%s)", type(exc).__name__)
            return PushResult("retry", f"could not reach FCM ({type(exc).__name__})")
        return self._interpret(res)

    def _post(self, payload: dict, force_token: bool = False) -> httpx.Response:
        return self._http.post(SEND_URL.format(project=self.project_id), json=payload, headers={"Authorization": f"Bearer {self._access_token(force_token)}"})

    @staticmethod
    def _interpret(res: httpx.Response) -> PushResult:
        if res.status_code == 200:
            return PushResult("sent")
        try:
            err = res.json().get("error", {})
        except ValueError:
            err = {}
        status = str(err.get("status", ""))
        codes = {str(d.get("errorCode", "")) for d in err.get("details", []) if isinstance(d, dict)}
        text = str(err.get("message", ""))[:200]
        if "UNREGISTERED" in codes or res.status_code == 404:
            return PushResult("invalid_token", "token is no longer registered")
        if "SENDER_ID_MISMATCH" in codes or res.status_code == 403 and "SENDER_ID_MISMATCH" in text:
            return PushResult("invalid_token", "token belongs to a different Firebase project")
        if res.status_code == 400 and ("INVALID_ARGUMENT" in codes or status == "INVALID_ARGUMENT") and "registration token" in text.lower():
            return PushResult("invalid_token", "token is not a valid registration token")
        if res.status_code in (429, 500, 502, 503, 504) or codes & RETRYABLE_CODES or status in RETRYABLE_CODES:
            return PushResult("retry", f"FCM temporarily unavailable ({res.status_code})")
        return PushResult("failed", f"FCM refused the message ({res.status_code} {status or 'error'})")


def load_service_account(settings: Settings) -> dict | None:
    """Read the service-account key from FCM_SERVICE_ACCOUNT_JSON or FCM_SERVICE_ACCOUNT_FILE. Returns None when absent or unusable (never raises with key content)."""
    raw = settings.fcm_service_account_json.strip()
    try:
        if not raw and settings.fcm_service_account_file.strip():
            raw = Path(settings.fcm_service_account_file.strip()).read_text()
        data = json.loads(raw) if raw else None
    except (OSError, ValueError):
        logger.error("FCM service-account credentials could not be read; push is disabled")
        return None
    if data is None:
        return None
    if not isinstance(data, dict) or not data.get("client_email") or not data.get("private_key"):
        logger.error("FCM service-account credentials are incomplete (client_email / private_key missing); push is disabled")
        return None
    return data


def build_fcm(settings: Settings) -> PushProvider | None:
    account = load_service_account(settings)
    project = settings.fcm_project_id.strip() or (account or {}).get("project_id", "")
    if not account or not project:
        return None
    return FcmProvider(project_id=project, client_email=account["client_email"], private_key=account["private_key"], token_uri=account.get("token_uri") or TOKEN_URI,
                       channel_id=settings.fcm_android_channel_id)
