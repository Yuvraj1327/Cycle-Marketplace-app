"""Provision an administrator. This is the ONLY supported way to create admins (there is no API for it).

Usage (from backend/, with SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in the environment / .env):
    1. The person signs up normally through Supabase Auth (or you invite them in the Supabase dashboard).
    2. python -m scripts.promote_admin person@example.com

Runs server-side with the service-role key; never expose that key to any app.
"""
import sys

from app.core.exceptions import NotFoundError
from app.integrations.supabase import get_admin_client
from app.repositories.base import BaseRepository


class _Profiles(BaseRepository):
    table = "profiles"


def promote_to_admin(client, email: str) -> dict:
    repo = _Profiles(client)
    rows = repo._run(client.table("profiles").select("id,email,role,status").eq("email", email.strip().lower())).data
    if not rows:
        raise NotFoundError(f"No account with email {email!r}. Ask the person to sign up first.")
    if rows[0]["role"] == "admin":
        return rows[0]
    # service role => auth.uid() is null => the profiles guard trigger permits the role change
    return repo.update(rows[0]["id"], {"role": "admin", "status": "active"})


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    email = argv[1]
    if input(f"Grant ADMIN rights to {email}? Type 'yes' to continue: ").strip() != "yes":
        print("Aborted.")
        return 1
    row = promote_to_admin(get_admin_client(), email)
    print(f"{row['email']} is now an admin.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
