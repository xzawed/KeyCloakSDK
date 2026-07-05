# 공통 HTTP 계약 (모든 언어 샘플 앱 동일 노출)

Base: `http://<host>:<APP_PORT>`. 모든 body는 JSON. admin 엔드포인트는 앱이 SDK client-credentials로 자체 인증(호출자 토큰 불요).

| 메서드·경로 | 요청 body | 성공 | 실패 |
|---|---|---|---|
| `GET /healthz` | — | 200 `{"status":"ok"}` | 503 |
| `POST /token` | — | 200 `{"tokenType":"Bearer","expiresIn":<int>}` | 500 `{"error":".."}` |
| `POST /validate` | `{"token":"<jwt>"}` | 200 `{"subject":"..","audience":[".."],"issuer":"..","expiresAt":<int>}` | 401 `{"error":".."}` |
| `POST /introspect` | `{"token":"<jwt>"}` | 200 `{"active":<bool>,"username":"..","clientId":".."}` | 500 |
| `POST /admin/users` | `{"username":"..","email":".."}` | 201 `{"id":".."}` | 409/500 |
| `GET /admin/users/{id}` | — | 200 `{"id":"..","username":".."}` | 404 |
| `GET /admin/users?username=<u>` | — | 200 `[{"id":"..","username":".."}]` | 500 |
| `DELETE /admin/users/{id}` | — | 204 | 404 |

**오류 매핑 규약(동형성)**: SDK NotFound류 → 404 · SDK Conflict류(중복 username 등) → 409 · JWT 검증 실패 → 401 · 기타 → 500 `{"error":"<message>"}`. 토큰/시크릿은 응답·로그에 노출 금지(`/token`은 메타만).
