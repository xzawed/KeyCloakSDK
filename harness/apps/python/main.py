import os
import time
from contextlib import asynccontextmanager
from typing import Any

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import (
    KeycloakConflictError,
    KeycloakForbiddenError,
    KeycloakNotFoundError,
    TokenValidationError,
)


def env(k: str, d: str) -> str:
    v = os.environ.get(k)
    return v if v else d


@asynccontextmanager
async def lifespan(app: FastAPI):
    config = KeycloakConfig(
        server_url=env("KC_SERVER_URL", "http://localhost:8080"),
        realm=env("KC_REALM", "it-realm"),
        client_id=env("KC_CLIENT_ID", "it-client"),
        client_secret=env("KC_CLIENT_SECRET", "it-secret"),
    )
    app.state.kc = AsyncKeycloakClient.create(config)  # 동기·무 I/O
    # ROPC(password-grant)로 얻은 refresh 토큰의 서버측 보관소(단일 프로세스 데모
    # 하네스 전용 — /refresh, /logout이 이를 재사용한다). harness/apps/ruby/app.rb의
    # SESS[:refresh]와 동일 패턴.
    app.state.last_refresh = None
    try:
        yield
    finally:
        await app.state.kc.aclose()  # 종료 시 소켓/FD 정리


app = FastAPI(lifespan=lifespan)


class TokenBody(BaseModel):
    token: str | None = None


class CreateBody(BaseModel):
    username: str | None = None
    email: str | None = None


class PasswordTokenBody(BaseModel):
    username: str | None = None
    password: str | None = None


class ClientBody(BaseModel):
    clientId: str | None = None


class RoleBody(BaseModel):
    name: str | None = None


class GroupBody(BaseModel):
    name: str | None = None


class RealmBody(BaseModel):
    realm: str | None = None


def fail(code: int, msg: str) -> JSONResponse:
    return JSONResponse(status_code=code, content={"error": msg})


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/token")
async def token(request: Request) -> Any:
    kc = request.app.state.kc
    try:
        ts = await kc.auth.client_credentials_token()
        # Python TokenSet은 절대 expires_at만 보유 → expiresIn 파생
        expires_in = int(ts.expires_at - time.time()) if ts.expires_at else 0
        return {"tokenType": ts.token_type, "expiresIn": expires_in}
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.post("/token/password")
async def token_password(request: Request, body: PasswordTokenBody) -> Any:
    # ROPC(Resource Owner Password Credentials)는 SDK 표면에 없다(SDK 표면 불변
    # 원칙 — 8개 하네스 앱 공통 패턴, harness/apps/ruby/app.rb 참고). Keycloak 토큰
    # 엔드포인트로 직접 POST한다.
    server_url = env("KC_SERVER_URL", "http://localhost:8080")
    realm = env("KC_REALM", "it-realm")
    client_id = env("KC_CLIENT_ID", "it-client")
    client_secret = env("KC_CLIENT_SECRET", "it-secret")
    url = f"{server_url}/realms/{realm}/protocol/openid-connect/token"
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.post(
                url,
                data={
                    "grant_type": "password",
                    "client_id": client_id,
                    "client_secret": client_secret,
                    "username": body.username,
                    "password": body.password,
                },
            )
            resp.raise_for_status()
            data = resp.json()
    except Exception as e:  # noqa: BLE001
        return fail(401, str(e))
    request.app.state.last_refresh = data.get("refresh_token")
    return {
        "tokenType": data["token_type"],
        "expiresIn": data["expires_in"],
        "hasRefresh": bool(data.get("refresh_token")),
    }


@app.post("/refresh")
async def refresh(request: Request) -> Any:
    kc = request.app.state.kc
    try:
        ts = await kc.auth.refresh(request.app.state.last_refresh)
        expires_in = int(ts.expires_at - time.time()) if ts.expires_at else 0
        if ts.refresh_token:
            request.app.state.last_refresh = ts.refresh_token
        return {"tokenType": ts.token_type, "expiresIn": expires_in}
    except Exception as e:  # noqa: BLE001
        return fail(401, str(e))


@app.post("/logout")
async def logout(request: Request) -> Response:
    kc = request.app.state.kc
    try:
        await kc.auth.logout(request.app.state.last_refresh)
        return Response(status_code=204)
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.get("/authz-url")
async def authz_url(request: Request, redirect_uri: str | None = None) -> Any:
    kc = request.app.state.kc
    # 네트워크 없이 오프라인으로 URL을 조립한다(async가 아님) — code_verifier/nonce는
    # 응답에 노출하지 않는다.
    ar = kc.auth.authorization_url(redirect_uri or "http://x/cb")
    return {"url": ar.url, "state": ar.state}


@app.post("/validate")
async def validate(request: Request, body: TokenBody) -> Any:
    if not body.token:
        return fail(400, "token required")
    kc = request.app.state.kc
    try:
        vt = await kc.auth.validate(body.token)
        return {
            "subject": vt.subject,
            "audience": list(vt.audience),
            "issuer": vt.issuer,
            "expiresAt": int(vt.expires_at) if vt.expires_at else None,
        }
    except TokenValidationError as e:
        return fail(401, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.post("/introspect")
async def introspect(request: Request, body: TokenBody) -> Any:
    if not body.token:
        return fail(400, "token required")
    kc = request.app.state.kc
    try:
        ir = await kc.auth.introspect(body.token)
        return {"active": ir.active, "username": ir.username, "clientId": ir.client_id}
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.post("/admin/users")
async def admin_create(request: Request, body: CreateBody) -> Any:
    if not body.username:
        return fail(400, "username required")
    kc = request.app.state.kc
    try:
        uid = await kc.admin.users.create(
            {"username": body.username, "email": body.email, "enabled": True}
        )
        return JSONResponse(status_code=201, content={"id": uid})
    except KeycloakConflictError as e:
        return fail(409, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.get("/admin/users/{user_id}")
async def admin_get(request: Request, user_id: str) -> Any:
    kc = request.app.state.kc
    try:
        u = await kc.admin.users.get(user_id)
        return {"id": u.get("id"), "username": u.get("username")}
    except KeycloakNotFoundError as e:
        return fail(404, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.get("/admin/users")
async def admin_search(request: Request, username: str | None = None) -> Any:
    kc = request.app.state.kc
    try:
        us = await kc.admin.users.search(username, 0, 20)
        return [{"id": u.get("id"), "username": u.get("username")} for u in us]
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.delete("/admin/users/{user_id}")
async def admin_delete(request: Request, user_id: str) -> Response:
    kc = request.app.state.kc
    try:
        await kc.admin.users.delete(user_id)
        return Response(status_code=204)
    except KeycloakNotFoundError as e:
        return fail(404, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


# ---- admin: clients ----
@app.post("/admin/clients")
async def admin_clients_create(request: Request, body: ClientBody) -> Any:
    kc = request.app.state.kc
    try:
        cid = await kc.admin.clients.create({"clientId": body.clientId, "enabled": True})
        return JSONResponse(status_code=201, content={"id": cid})
    except KeycloakConflictError as e:
        return fail(409, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.get("/admin/clients/{client_id}")
async def admin_clients_get(request: Request, client_id: str) -> Any:
    kc = request.app.state.kc
    try:
        c = await kc.admin.clients.get(client_id)
        return {"id": c.get("id"), "clientId": c.get("clientId")}
    except KeycloakNotFoundError as e:
        return fail(404, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.delete("/admin/clients/{client_id}")
async def admin_clients_delete(request: Request, client_id: str) -> Response:
    kc = request.app.state.kc
    try:
        await kc.admin.clients.delete(client_id)
        return Response(status_code=204)
    except KeycloakNotFoundError as e:
        return fail(404, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


# ---- admin: roles (realm role — client role 아님·name 키) ----
@app.post("/admin/roles")
async def admin_roles_create(request: Request, body: RoleBody) -> Any:
    kc = request.app.state.kc
    try:
        await kc.admin.roles.create({"name": body.name})
        return JSONResponse(status_code=201, content={"name": body.name})
    except KeycloakConflictError as e:
        return fail(409, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.get("/admin/roles/{name}")
async def admin_roles_get(request: Request, name: str) -> Any:
    kc = request.app.state.kc
    try:
        r = await kc.admin.roles.get(name)
        return {"name": r.get("name")}
    except KeycloakNotFoundError as e:
        return fail(404, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.delete("/admin/roles/{name}")
async def admin_roles_delete(request: Request, name: str) -> Response:
    kc = request.app.state.kc
    try:
        await kc.admin.roles.delete(name)
        return Response(status_code=204)
    except KeycloakNotFoundError as e:
        return fail(404, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


# ---- admin: groups ----
@app.post("/admin/groups")
async def admin_groups_create(request: Request, body: GroupBody) -> Any:
    kc = request.app.state.kc
    try:
        gid = await kc.admin.groups.create({"name": body.name})
        return JSONResponse(status_code=201, content={"id": gid})
    except KeycloakConflictError as e:
        return fail(409, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.get("/admin/groups/{group_id}")
async def admin_groups_get(request: Request, group_id: str) -> Any:
    kc = request.app.state.kc
    try:
        g = await kc.admin.groups.get(group_id)
        return {"id": g.get("id"), "name": g.get("name")}
    except KeycloakNotFoundError as e:
        return fail(404, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.delete("/admin/groups/{group_id}")
async def admin_groups_delete(request: Request, group_id: str) -> Response:
    kc = request.app.state.kc
    try:
        await kc.admin.groups.delete(group_id)
        return Response(status_code=204)
    except KeycloakNotFoundError as e:
        return fail(404, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


# ---- admin: realms (master 전용 — 하네스는 realm SA라 항상 403, CONTRACT.md 참고) ----
@app.post("/admin/realms")
async def admin_realms_create(request: Request, body: RealmBody) -> Any:
    kc = request.app.state.kc
    try:
        await kc.admin.realms.create({"realm": body.realm, "enabled": True})
        return JSONResponse(status_code=201, content={"realm": body.realm})
    except KeycloakForbiddenError as e:
        return fail(403, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))
