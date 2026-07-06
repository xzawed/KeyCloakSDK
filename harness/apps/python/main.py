import os
import time
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import (
    KeycloakConflictError,
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
