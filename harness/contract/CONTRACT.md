<!-- doc-budget: max-bytes=4561 -->
<!-- 4313 → 4561 (2026-09-22, +248B). 규약 (1) — **선언된 규칙을 실제로** 만든다.
     CLAUDE.md 의 언어 규칙이 `harness/` 를 **영문** 소비자 문서로 선언하는데 이 파일만
     한글이었다(46 줄 중 18). 형제 둘(`harness/README.md`·`harness/install/README.md`)은 이미
     영문이라 이 파일이 유일한 예외였고, 청중은 「새 언어의 하네스 앱을 구현하는 사람」으로
     영문인 add-a-language playbook 과 같다.
     ⚠️ **번역만 했다** — 엔드포인트 표 22 행, 오류 매핑, 400 관련 실측(2026-09-06 의 6:3
     분기와 `REJECT_STATUSES`), realm SA 403 단서까지 한 항목도 빼거나 더하지 않았다.
     +248B 는 같은 내용을 영어로 쓴 비용이다(한글이 바이트당 정보밀도가 높다) — 내용 추가가
     아니므로 교환할 거짓 문장이 없고, 그래서 이 기록이 판정이다.
     ⚠️ `CONTRIBUTING.md`(13 줄)·`DEPLOY.md`(44 줄)도 한글로 잡히지만 **규칙 위반이 아니다** —
     전부 이 파일과 같은 **예산 판정 HTML 주석**(적재되지 않는다)이거나, GitHub 체크명
     `Integration (testcontainers, 실제 Keycloak 26.6)` 의 **리터럴 인용**이다. 고치지 않았다. -->
# Common HTTP contract (every language's sample app exposes the same surface)

Base: `http://<host>:<APP_PORT>`. All bodies are JSON. The admin endpoints authenticate themselves with the SDK's client-credentials grant — the caller sends no token.

| Method · path | Request body | Success | Failure |
|---|---|---|---|
| `GET /healthz` | — | 200 `{"status":"ok"}` | — (⚠️ all nine apps return **200 unconditionally**. None of them reports a failure state, so the contract does not promise one — to add a dependency check, write its state here first) |
| `POST /token` | — | 200 `{"tokenType":"Bearer","expiresIn":<int>}` | 500 `{"error":".."}` |
| `POST /validate` | `{"token":"<jwt>"}` | 200 `{"subject":"..","audience":[".."],"issuer":"..","expiresAt":<int>}` | 401 `{"error":".."}` |
| `POST /introspect` | `{"token":"<jwt>"}` | 200 `{"active":<bool>,"username":"..","clientId":".."}` | 500 |
| `POST /admin/users` | `{"username":"..","email":".."}` | 201 `{"id":".."}` | 409/500 |
| `GET /admin/users/{id}` | — | 200 `{"id":"..","username":".."}` | 404 |
| `GET /admin/users?username=<u>` | — | 200 `[{"id":"..","username":".."}]` | 500 |
| `DELETE /admin/users/{id}` | — | 204 | 404 |

**Error-mapping rule (isomorphism)**: SDK NotFound-family → 404 · SDK Conflict-family (duplicate username and the like) → 409 · SDK Forbidden-family → 403 · **malformed request (missing required field, empty value) → 400** · JWT validation failure → 401 · anything else → 500 `{"error":"<message>"}`. Tokens and secrets must never appear in a response or a log (`/token` returns metadata only).

⚠️ **400 was missing from this table for a long time, and that is why the nine diverged** (measured 2026-09-06): with an empty `token`, **six** (go · node · python · dotnet · java · kotlin) answer `400 {"error":"token required"}` while **three** (php · ruby · rust) feed the empty string straight into validation and answer `401`. **The security probe accepts either as a rejection** (`REJECT_STATUSES = [400, 401]` in `verdict.mjs`), so neither is a failure — but **if the contract lists only "anything else → 500" and omits 400, an app that follows the contract literally is scored `crashed` (≥500) by the probe.** A new language should choose 400.

## v2 extensions (every app exposes these too)

### auth extensions
| Method · path | Request body | Success | Failure |
|---|---|---|---|
| `POST /token/password` | `{"username":"..","password":".."}` | 200 `{"tokenType":"Bearer","expiresIn":<int>,"hasRefresh":<bool>}` | 401 `{"error":".."}` |
| `POST /refresh` | `{}` (the app keeps the last password-grant refresh token server-side) | 200 `{"tokenType":"Bearer","expiresIn":<int>}` | 401 |
| `POST /logout` | `{}` (server-side session in the app) | 204 | 500 |
| `GET /authz-url?redirect_uri=<u>` | — | 200 `{"url":"..","state":".."}` (the url carries `code_challenge_method=S256`, `code_challenge` and `state`; the code_verifier is not exposed) — **offline URL assembly only** (no browser round trip, no code exchange) | 500 |

### admin five-resource extensions
| Method · path | Request body | Success | Failure |
|---|---|---|---|
| `POST /admin/clients` | `{"clientId":".."}` | 201 `{"id":".."}` | 409/500 |
| `GET /admin/clients/{id}` | — | 200 `{"id":"..","clientId":".."}` | 404 |
| `DELETE /admin/clients/{id}` | — | 204 | 404 |
| `POST /admin/roles` (realm role — not a client role · keyed by name) | `{"name":".."}` | 201 `{"name":".."}` | 409/500 |
| `GET /admin/roles/{name}` (realm role) | — | 200 `{"name":".."}` | 404 |
| `DELETE /admin/roles/{name}` (realm role) | — | 204 | 404 |
| `POST /admin/groups` | `{"name":".."}` | 201 `{"id":".."}` | 409/500 |
| `GET /admin/groups/{id}` | — | 200 `{"id":"..","name":".."}` | 404 |
| `DELETE /admin/groups/{id}` | — | 204 | 404 |
| `POST /admin/realms` | `{"realm":".."}` | — (realm creation is master-only; a harness app holds a realm SA, so it cannot get there) | 403 `{"error":".."}` (realm SA lacks the permission) |

> ⚠️ `POST /admin/realms`: a harness app runs as a realm service account, so this is **always** 403 — that is the point (it verifies the isomorphic Forbidden mapping). Real realm creation (201) with a master token is covered by the SDK integration tests; the harness covers only the 403 path.

**Error-path verification contract**: duplicate `POST /admin/users` (same username twice) → the second is 409. `POST /admin/realms` (realm SA token) → always 403. `POST /validate` (forged token) → 401.
