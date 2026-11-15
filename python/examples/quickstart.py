"""QuickStart — a minimal usage example of `keycloak-sdk`.

This file aims only to be importable/type-checkable statically (even without a real Keycloak
server, `python -c "import ast; ast.parse(...)"` and `mypy` must pass). The logic that needs
network calls is in `main()` and runs only behind the `if __name__ == "__main__":` guard, so
merely importing the module sends no request.

To run it, set `KC_SERVER_URL` · `KC_REALM` · `KC_CLIENT_ID` · `KC_CLIENT_SECRET` to a real
Keycloak server's details and run `python examples/quickstart.py` (the service account needs the
required permission roles).
"""

from __future__ import annotations

import os

from keycloak_sdk import KeycloakClient, KeycloakConfig, mask


def main() -> None:
    # Settings come from the environment; the defaults are placeholders. Never hard-code a secret.
    config = KeycloakConfig(
        server_url=os.environ.get("KC_SERVER_URL", "https://keycloak.example.com"),
        realm=os.environ.get("KC_REALM", "my-realm"),
        client_id=os.environ.get("KC_CLIENT_ID", "my-client"),
        client_secret=os.environ.get("KC_CLIENT_SECRET", "my-client-secret"),
    )

    # KeycloakClient.create() assembles auth (AuthClient) eagerly. admin is created lazily on the
    # first `.admin` access (needs client_secret — client-credentials grant).
    with KeycloakClient.create(config) as kc:
        # 1) Get a client-credentials token — never write the raw token to a log.
        #    `mask()` returns only "***" (when there is a value), exposing no prefix — it reveals
        #    only whether the value exists.
        token = kc.auth.client_credentials_token()
        print(f"access_token={mask(token.access_token)} token_type={token.token_type}")

        # 2) List users through the admin API (admin is created lazily at this point).
        users = kc.admin.users.search(first=0, max=10)
        print(f"users={[u.get('username') for u in users]}")


if __name__ == "__main__":
    main()
