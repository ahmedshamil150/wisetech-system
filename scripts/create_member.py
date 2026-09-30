"""Create a team member (auth account + profile) in Supabase.

Usage:
  set SUPABASE_URL=https://xxxx.supabase.co
  set SUPABASE_SERVICE_ROLE_KEY=eyJ...
  python scripts/create_member.py <username> <password> ["Display Name"]

The member signs in to the app with the username and password given here.
"""
import json
import os
import sys
import urllib.error
import urllib.request

DOMAIN = "wisetech.app"


def api_call(url, api_key, method, payload=None):
    body = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={
            "apikey": api_key,
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request) as response:
        raw = response.read().decode()
        return json.loads(raw) if raw else None


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    base = os.environ.get("SUPABASE_URL", "").rstrip("/")
    service_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not base or not service_key:
        print("ERROR: set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first.")
        sys.exit(1)

    username = sys.argv[1].strip().lower()
    password = sys.argv[2]
    display_name = sys.argv[3].strip() if len(sys.argv) > 3 else username
    email = f"{username}@{DOMAIN}"

    if not username.replace("_", "").replace(".", "").isalnum():
        print("ERROR: username may only contain letters, numbers, dot, underscore.")
        sys.exit(1)
    if len(password) < 6:
        print("ERROR: password must be at least 6 characters.")
        sys.exit(1)

    try:
        user = api_call(
            f"{base}/auth/v1/admin/users",
            service_key,
            "POST",
            {
                "email": email,
                "password": password,
                "email_confirm": True,
                "user_metadata": {
                    "username": username,
                    "display_name": display_name,
                },
            },
        )
    except urllib.error.HTTPError as e:
        detail = e.read().decode()
        print(f"ERROR creating auth user: {detail}")
        sys.exit(1)

    uid = user.get("id")
    print(f"auth user created: {email} (id {uid})")

    try:
        profile = api_call(
            f"{base}/rest/v1/profiles?id=eq.{uid}&select=id",
            service_key,
            "GET",
        )
        if not profile:
            api_call(
                f"{base}/rest/v1/profiles",
                service_key,
                "POST",
                {"id": uid, "username": username, "display_name": display_name},
            )
            print("profile row created")
        else:
            print("profile row already exists (auto-created by trigger)")
    except urllib.error.HTTPError as e:
        print(f"WARNING profile check failed: {e.read().decode()}")

    print()
    print("Done. The member signs in with:")
    print(f"  username: {username}")
    print(f"  password: {password}")


if __name__ == "__main__":
    main()
