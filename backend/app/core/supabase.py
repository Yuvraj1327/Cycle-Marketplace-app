"""Backward-compatible import path (Step 2). Implementation lives in app.integrations.supabase."""
from app.integrations.supabase import (  # noqa: F401
    create_user_db_client,
    get_admin_client,
    get_anon_client,
    revoke_session,
    with_user_token,
)
