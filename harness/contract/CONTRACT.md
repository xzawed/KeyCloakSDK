# 공통 HTTP 계약 (모든 언어 샘플 앱 동일 노출)

Base: `http://<host>:<APP_PORT>`. 모든 body는 JSON. admin 엔드포인트는 앱이 SDK client-credentials로 자체 인증(호출자 토큰 불요).

| 메서드·경로 | 요청 body | 성공 | 실패 |
|---|---|---|---|
| `GET /healthz` | — | 200 `{"status":"ok"}` | — (⚠️ 아홉 앱 모두 **무조건 200** 이다. 실패 상태를 내는 앱은 없으므로 계약도 약속하지 않는다 — 의존성 검사를 붙이려면 여기에 그 상태를 먼저 적는다) |
| `POST /token` | — | 200 `{"tokenType":"Bearer","expiresIn":<int>}` | 500 `{"error":".."}` |
| `POST /validate` | `{"token":"<jwt>"}` | 200 `{"subject":"..","audience":[".."],"issuer":"..","expiresAt":<int>}` | 401 `{"error":".."}` |
| `POST /introspect` | `{"token":"<jwt>"}` | 200 `{"active":<bool>,"username":"..","clientId":".."}` | 500 |
| `POST /admin/users` | `{"username":"..","email":".."}` | 201 `{"id":".."}` | 409/500 |
| `GET /admin/users/{id}` | — | 200 `{"id":"..","username":".."}` | 404 |
| `GET /admin/users?username=<u>` | — | 200 `[{"id":"..","username":".."}]` | 500 |
| `DELETE /admin/users/{id}` | — | 204 | 404 |

**오류 매핑 규약(동형성)**: SDK NotFound류 → 404 · SDK Conflict류(중복 username 등) → 409 · SDK Forbidden류 → 403 · **요청 모양이 틀림(필수 필드 누락·빈 값) → 400** · JWT 검증 실패 → 401 · 기타 → 500 `{"error":"<message>"}`. 토큰/시크릿은 응답·로그에 노출 금지(`/token`은 메타만).

⚠️ **400 은 오래 이 표에 없었고, 그래서 아홉이 갈렸다**(실측 2026-09-06): `token` 이 비었을 때 **여섯**(go·node·python·dotnet·java·kotlin)은 `400 {"error":"token required"}` 를, **셋**(php·ruby·rust)은 빈 문자열을 그대로 검증에 넣어 `401` 을 낸다. **보안 프로브는 둘 다 거부로 받으므로**(`verdict.mjs` 의 `REJECT_STATUSES = [400, 401]`) 어느 쪽도 실패가 아니다 — 다만 **계약이 400 을 적지 않은 채 「기타 → 500」만 두면, 계약대로 구현한 앱은 프로브에서 `crashed`(≥500)로 떨어진다.** 새 언어는 400 을 택하라.

## v2 확장 (모든 앱 동일 노출)

### auth 확장
| 메서드·경로 | 요청 body | 성공 | 실패 |
|---|---|---|---|
| `POST /token/password` | `{"username":"..","password":".."}` | 200 `{"tokenType":"Bearer","expiresIn":<int>,"hasRefresh":<bool>}` | 401 `{"error":".."}` |
| `POST /refresh` | `{}` (앱이 직전 password-grant refresh 토큰 서버측 보관) | 200 `{"tokenType":"Bearer","expiresIn":<int>}` | 401 |
| `POST /logout` | `{}` (앱 서버측 세션) | 204 | 500 |
| `GET /authz-url?redirect_uri=<u>` | — | 200 `{"url":"..","state":".."}` (url은 `code_challenge_method=S256`·`code_challenge`·`state` 포함, code_verifier 미노출) — **오프라인 URL 조립만**(브라우저 왕복·code 교환 없음) | 500 |

### admin 5리소스 확장
| 메서드·경로 | 요청 body | 성공 | 실패 |
|---|---|---|---|
| `POST /admin/clients` | `{"clientId":".."}` | 201 `{"id":".."}` | 409/500 |
| `GET /admin/clients/{id}` | — | 200 `{"id":"..","clientId":".."}` | 404 |
| `DELETE /admin/clients/{id}` | — | 204 | 404 |
| `POST /admin/roles`(realm role — client role 아님·name 키) | `{"name":".."}` | 201 `{"name":".."}` | 409/500 |
| `GET /admin/roles/{name}`(realm role) | — | 200 `{"name":".."}` | 404 |
| `DELETE /admin/roles/{name}`(realm role) | — | 204 | 404 |
| `POST /admin/groups` | `{"name":".."}` | 201 `{"id":".."}` | 409/500 |
| `GET /admin/groups/{id}` | — | 200 `{"id":"..","name":".."}` | 404 |
| `DELETE /admin/groups/{id}` | — | 204 | 404 |
| `POST /admin/realms` | `{"realm":".."}` | — (realm 생성은 master 전용; 하네스 앱은 realm SA라 도달 불가) | 403 `{"error":".."}`(realm SA 권한 부족) |

> ⚠️ `POST /admin/realms`: 하네스 앱은 realm 서비스계정이라 항상 403(동형 Forbidden 매핑 검증용). master 토큰으로의 실제 realm 생성(201)은 SDK 통합테스트가 커버 — 하네스는 403 경로만.

**오류경로 검증 계약**: 중복 `POST /admin/users`(같은 username 2회) → 2번째 409. `POST /admin/realms`(realm SA 토큰) → 항상 403. `POST /validate`(위조 토큰) → 401.
