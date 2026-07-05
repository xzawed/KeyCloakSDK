# 가상사용자 실측 테스트 하네스 (MVP) — 구현 계획 (WBS)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development(권장) 또는 superpowers:executing-plans로 태스크 단위 구현. 스텝은 `- [ ]` 체크박스. 실행: WBS → 서브에이전트 구현→리뷰→수정 루프.

**Goal:** [설계 스펙](../specs/2026-07-05-virtual-user-test-harness-design.md)의 MVP — Docker Compose 프로덕션-유사 환경(실제 Keycloak 26.6)에 **Go 샘플 앱**(SDK 빌드 패키지 소비)을 배포하고, **k6 가상사용자 드라이버**가 공통 HTTP 계약을 동시 호출해 **기능 정확성 PASS/FAIL 게이트 + 성능 실측 리포트**를 산출하는 완결 하네스를 `harness/`에 구축한다. (C#/Node/Python/Java 앱 확장은 후속 계획.)

**Architecture:** `harness/`에 (1) `docker-compose.yml`(Keycloak + Go 앱), (2) `keycloak/harness-realm.json`(기존 it-realm 재사용), (3) `contract/CONTRACT.md`(공통 HTTP 계약), (4) `apps/go/`(net/http + Go SDK `replace` 소비 + multistage Dockerfile), (5) `driver/scenarios.js`(k6), (6) `report/aggregate.mjs`, (7) `run.sh`. 앱은 계약만 지키고 SDK를 빌드 산출물로 소비 → 드라이버/리포트/인프라는 언어-불가지로 재사용.

**Tech Stack:** Docker Compose · Keycloak 26.6(quay.io) · Go 1.25(net/http) · `github.com/xzawed/KeyCloakSDK/go`(replace 로컬 소비) · gocloak/v13(admin representation) · k6(Grafana, 가상사용자·지연 백분위·checks 임계값) · Node(report 취합, `.mjs`) · bash(run.sh) · GitHub Actions.

## Global Constraints

[설계 스펙](../specs/2026-07-05-virtual-user-test-harness-design.md)에서 그대로 옮김. 모든 태스크에 암묵 적용.

- **배치**: `harness/`(java/·python/·node/·go/·dotnet/와 나란히). SDK 코드는 **수정하지 않음**(소비자 관점).
- **인프라**: Docker Compose. Keycloak `quay.io/keycloak/keycloak:26.6`, `start-dev --import-realm`(H2 — SDK 검증은 DB 백엔드 불의존).
- **realm 재사용**: 기존 `go/testdata/it-realm-realm.json`(realm `it-realm`, client `it-client`/secret `it-secret`, serviceAccounts + manage-users + `it-client` audience 매퍼, user `alice`)를 `harness/keycloak/harness-realm.json`로 복사. 드라이버는 client-credentials(`it-client`/`it-secret`) 사용(토큰 aud에 `it-client` 포함 → validate 통과), admin user CRUD는 서비스계정 권한.
- **공통 HTTP 계약**(진실 원천, `contract/CONTRACT.md`): `GET /healthz` · `POST /token` · `POST /validate` · `POST /introspect` · `POST /admin/users` · `GET /admin/users/{id}` · `GET /admin/users?username=` · `DELETE /admin/users/{id}`. 오류 매핑: NotFound→404, 검증실패→401, 기타→500. 응답 JSON 형태 고정(§계약표).
- **빌드 패키지 소비**(배포가능성 검증): Go 앱은 `replace github.com/xzawed/KeyCloakSDK/go => /sdk`로 로컬 모듈을 소비(소스 참조 아님 — 모듈 임포트가능성 검증). Dockerfile 멀티스테이지.
- **드라이버 = k6**: `import http from 'k6/http'`, `check`, `Trend`, `export const options`, `handleSummary(data)`. 기능 게이트 = `thresholds:{ checks:['rate==1.00'] }`(체크 100% 아니면 k6 종료코드 비0). 대상 URL은 `__ENV.BASE_URL`, 언어 태그는 `__ENV.LANG`.
- **측정**: 엔드포인트별 커스텀 `Trend`(예: `validate_duration`)로 p95 산출 + 내장 `http_reqs`(RPS)·`http_req_failed`(오류율). `handleSummary`가 `report/<lang>.json` 기록.
- **성공**: `./harness/run.sh` 단일 명령 → Keycloak+Go앱 기동 → k6 정확성 전부 PASS → `report/RESULTS.md` 생성 → compose down. 어느 체크든 실패 시 비0.
- **툴체인(하네스)**: Docker Desktop(daemon RUNNING 확인됨) · Go 포터블 `C:\Users\dirtc\tools\go`(호스트 빌드 불요 — 앱 빌드는 Dockerfile 내부) · Node(시스템, report 취합) · k6는 컨테이너(`grafana/k6`)로 실행(호스트 설치 불요).
- **커밋**: `git add -A && git commit`. 브랜치는 새 `feature/test-harness`(생성). 커밋 co-author `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **⚠️ 착수 시(Task 1) 확인**: `it-realm-realm.json`의 `it-client` 서비스계정이 `manage-users`를 실제로 보유(SDK E2E가 client-credentials로 user CRUD 성공 → 보유), Keycloak 26.6 `start-dev --import-realm`이 volume-mount된 realm json을 임포트하는지 확인.

## File Structure

- `harness/docker-compose.yml` — `keycloak` 서비스(+`app-go`). healthcheck·의존성.
- `harness/keycloak/harness-realm.json` — 복사본(realm import).
- `harness/contract/CONTRACT.md` — 공통 HTTP 계약(표 + 오류매핑 + 예시). 진실 원천.
- `harness/apps/go/main.go` — net/http 서버, 8 엔드포인트, SDK 호출 + 오류→HTTP.
- `harness/apps/go/go.mod` — 모듈 + `replace ... => /sdk`.
- `harness/apps/go/Dockerfile` — multistage(SDK 소스 복사 + 앱 빌드 + 런타임).
- `harness/driver/scenarios.js` — k6 스크립트.
- `harness/report/aggregate.mjs` — 요약 JSON 취합 → RESULTS.md.
- `harness/run.sh` — 오케스트레이터.
- `harness/README.md` — 사용법.
- `.github/workflows/harness.yml` — CI.

## 태스크 순서/의존

1 스캐폴딩+realm+Keycloak → 2 Go 앱 → 3 k6 드라이버 → 4 리포트+run.sh → 5 CI+문서. (2는 1 의존; 3은 2 의존; 4는 2·3 의존.)

---

### Task 1: 스캐폴딩 + realm + Keycloak Compose

**Files:** Create `harness/docker-compose.yml`, `harness/keycloak/harness-realm.json`, `harness/contract/CONTRACT.md`, `harness/README.md`

**Interfaces:** Produces: Keycloak 서비스(realm `it-realm` 임포트, 8080 노출) + 계약 문서. Consumes: 없음.

- [ ] **Step 1: 브랜치 + realm 복사**

```bash
cd /d/Source/KeyCloakSDK && git checkout -b feature/test-harness
mkdir -p harness/keycloak harness/contract harness/apps/go harness/driver harness/report
cp go/testdata/it-realm-realm.json harness/keycloak/harness-realm.json
```

- [ ] **Step 2: `harness/docker-compose.yml` 작성**

```yaml
services:
  keycloak:
    image: quay.io/keycloak/keycloak:26.6
    command: ["start-dev", "--import-realm"]
    environment:
      KC_BOOTSTRAP_ADMIN_USERNAME: admin
      KC_BOOTSTRAP_ADMIN_PASSWORD: admin
      KC_HEALTH_ENABLED: "true"
    volumes:
      - ./keycloak/harness-realm.json:/opt/keycloak/data/import/harness-realm.json:ro
    ports:
      - "8080:8080"
    healthcheck:
      # 26.6은 관리 포트 9000의 /health/ready 제공; curl 미포함 이미지라 bash TCP로 대체
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/localhost/9000 && echo -e 'GET /health/ready HTTP/1.1\\r\\nhost: localhost\\r\\nConnection: close\\r\\n\\r\\n' >&3 && cat <&3 | grep -q '\"status\": \"UP\"'"]
      interval: 5s
      timeout: 5s
      retries: 40
      start_period: 30s

  app-go:
    build:
      context: ..            # 리포지토리 루트(go/ SDK 소스 접근 위해)
      dockerfile: harness/apps/go/Dockerfile
    environment:
      KC_SERVER_URL: http://keycloak:8080
      KC_REALM: it-realm
      KC_CLIENT_ID: it-client
      KC_CLIENT_SECRET: it-secret
      APP_PORT: "8090"
    ports:
      - "8090:8090"
    depends_on:
      keycloak:
        condition: service_healthy
    profiles: ["apps"]        # 기본 up에는 keycloak만; 앱은 --profile apps 또는 개별 up
```

- [ ] **Step 3: `harness/contract/CONTRACT.md` 작성**(공통 HTTP 계약 — 5개 언어 앱이 지킬 진실 원천)

````markdown
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

**오류 매핑 규약(동형성)**: SDK NotFound류 → 404 · JWT 검증 실패 → 401 · 기타 → 500 `{"error":"<message>"}`. 토큰/시크릿은 응답·로그에 노출 금지(`/token`은 메타만).
````

`harness/README.md`: 하네스 목적·`./run.sh` 사용법·계약 링크(간단히).

- [ ] **Step 4: 검증** — Keycloak 단독 기동 + realm 임포트 확인

```bash
cd harness && docker compose up -d keycloak
# healthy 대기(최대 ~3분)
timeout 200 bash -c 'until [ "$(docker inspect -f {{.State.Health.Status}} $(docker compose ps -q keycloak))" = healthy ]; do sleep 3; done'
curl -fsS http://localhost:8080/realms/it-realm/.well-known/openid-configuration | grep -q it-realm && echo "REALM OK"
docker compose down
```
Expected: `REALM OK`(realm 임포트됨).

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(harness): 스캐폴딩 — Keycloak compose(realm import) + 공통 HTTP 계약 (WBS 1)"`

---

### Task 2: Go MVP 앱 (계약 구현 + 빌드 패키지 소비)

**Files:** Create `harness/apps/go/main.go`, `harness/apps/go/go.mod`, `harness/apps/go/Dockerfile`

**Interfaces:** Consumes: Go SDK `keycloak.New(keycloak.Config{ServerURL,Realm,ClientID,ClientSecret,Scopes})→(*Client,error)` · `c.Auth.ClientCredentialsToken(ctx)→(*TokenSet{TokenType,ExpiresIn})` · `c.Auth.Validate(ctx,token)→(*ValidatedToken{Subject,Audience[],Issuer,ExpiresAt})` · `c.Auth.Introspect(ctx,token)→(*IntrospectionResult{Active,Username,ClientID})` · `c.Admin(ctx)→(*AdminClient,error)` · `admin.Users.Create(ctx,gocloak.User)→(string,error)` · `admin.Users.Get(ctx,id)→(*gocloak.User,error)` · `admin.Users.Search(ctx,username,first,max)→([]*gocloak.User,error)` · `admin.Users.Delete(ctx,id)→error` · `keycloak.ErrNotFound`. gocloak helpers `gocloak.StringP`/`gocloak.BoolP`. Produces: 계약(§Task1)을 노출하는 HTTP 서버.

- [ ] **Step 1: `harness/apps/go/go.mod`**(로컬 SDK 소비 — `replace`)

```
module harness-app-go

go 1.25

require (
	github.com/xzawed/KeyCloakSDK/go v0.0.0
	github.com/Nerzal/gocloak/v13 v13.9.0
)

replace github.com/xzawed/KeyCloakSDK/go => /sdk
```
(빌드 시 `/sdk`에 go SDK 소스가 마운트/복사됨 — Dockerfile 참고. `go mod tidy`가 나머지 전이 의존을 채운다.)

- [ ] **Step 2: `harness/apps/go/main.go`** — 8 엔드포인트

```go
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/Nerzal/gocloak/v13"
	keycloak "github.com/xzawed/KeyCloakSDK/go"
)

var kc *keycloak.Client

func main() {
	cfg := keycloak.Config{
		ServerURL:    env("KC_SERVER_URL", "http://localhost:8080"),
		Realm:        env("KC_REALM", "it-realm"),
		ClientID:     env("KC_CLIENT_ID", "it-client"),
		ClientSecret: env("KC_CLIENT_SECRET", "it-secret"),
	}
	var err error
	if kc, err = keycloak.New(cfg); err != nil {
		log.Fatalf("keycloak.New: %v", err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthz)
	mux.HandleFunc("POST /token", tokenH)
	mux.HandleFunc("POST /validate", validateH)
	mux.HandleFunc("POST /introspect", introspectH)
	mux.HandleFunc("POST /admin/users", adminCreateH)
	mux.HandleFunc("GET /admin/users/{id}", adminGetH)
	mux.HandleFunc("GET /admin/users", adminSearchH)
	mux.HandleFunc("DELETE /admin/users/{id}", adminDeleteH)
	addr := ":" + env("APP_PORT", "8090")
	log.Printf("listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func env(k, d string) string { if v := os.Getenv(k); v != "" { return v }; return d }

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if v != nil { _ = json.NewEncoder(w).Encode(v) }
}
func fail(w http.ResponseWriter, code int, msg string) { writeJSON(w, code, map[string]string{"error": msg}) }

func ctx(r *http.Request) (context.Context, context.CancelFunc) {
	return context.WithTimeout(r.Context(), 15*time.Second)
}

func healthz(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"status": "ok"}) }

func tokenH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	ts, err := kc.Auth.ClientCredentialsToken(c)
	if err != nil { fail(w, 500, err.Error()); return }
	writeJSON(w, 200, map[string]any{"tokenType": ts.TokenType, "expiresIn": ts.ExpiresIn})
}

type tokenReq struct { Token string `json:"token"` }

func validateH(w http.ResponseWriter, r *http.Request) {
	var body tokenReq
	if json.NewDecoder(r.Body).Decode(&body) != nil || body.Token == "" { fail(w, 400, "token required"); return }
	c, cancel := ctx(r); defer cancel()
	vt, err := kc.Auth.Validate(c, body.Token)
	if err != nil { fail(w, 401, err.Error()); return }
	writeJSON(w, 200, map[string]any{"subject": vt.Subject, "audience": vt.Audience, "issuer": vt.Issuer, "expiresAt": vt.ExpiresAt})
}

func introspectH(w http.ResponseWriter, r *http.Request) {
	var body tokenReq
	if json.NewDecoder(r.Body).Decode(&body) != nil || body.Token == "" { fail(w, 400, "token required"); return }
	c, cancel := ctx(r); defer cancel()
	ir, err := kc.Auth.Introspect(c, body.Token)
	if err != nil { fail(w, 500, err.Error()); return }
	writeJSON(w, 200, map[string]any{"active": ir.Active, "username": ir.Username, "clientId": ir.ClientID})
}

type createReq struct { Username string `json:"username"`; Email string `json:"email"` }

func adminCreateH(w http.ResponseWriter, r *http.Request) {
	var body createReq
	if json.NewDecoder(r.Body).Decode(&body) != nil || body.Username == "" { fail(w, 400, "username required"); return }
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	id, err := admin.Users.Create(c, gocloak.User{Username: gocloak.StringP(body.Username), Email: gocloak.StringP(body.Email), Enabled: gocloak.BoolP(true)})
	if err != nil { writeErr(w, err); return }
	writeJSON(w, 201, map[string]string{"id": id})
}

func adminGetH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	u, err := admin.Users.Get(c, r.PathValue("id"))
	if err != nil { writeErr(w, err); return }
	writeJSON(w, 200, map[string]string{"id": strOr(u.ID), "username": strOr(u.Username)})
}

func adminSearchH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	us, err := admin.Users.Search(c, r.URL.Query().Get("username"), 0, 20)
	if err != nil { writeErr(w, err); return }
	out := make([]map[string]string, 0, len(us))
	for _, u := range us { out = append(out, map[string]string{"id": strOr(u.ID), "username": strOr(u.Username)}) }
	writeJSON(w, 200, out)
}

func adminDeleteH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	if err := admin.Users.Delete(c, r.PathValue("id")); err != nil { writeErr(w, err); return }
	w.WriteHeader(204)
}

// writeErr maps SDK errors to HTTP per the contract (NotFound→404, else 500).
func writeErr(w http.ResponseWriter, err error) {
	if errors.Is(err, keycloak.ErrNotFound) { fail(w, 404, err.Error()); return }
	if errors.Is(err, keycloak.ErrConflict) { fail(w, 409, err.Error()); return }
	fail(w, 500, err.Error())
}

func strOr(p *string) string { if p != nil { return *p }; return "" }
var _ = strings.TrimSpace
```

- [ ] **Step 3: `harness/apps/go/Dockerfile`**(multistage — SDK 소스 복사 + `replace` 소비 + 빌드)

```dockerfile
# build context = repo root (docker-compose.yml의 context: ..)
FROM golang:1.25-alpine AS build
WORKDIR /app
# SDK 소스를 /sdk로 복사(go.mod의 replace 대상)
COPY go/ /sdk/
# 앱 소스
COPY harness/apps/go/go.mod ./go.mod
COPY harness/apps/go/main.go ./main.go
RUN go mod tidy && go build -o /out/app .

FROM alpine:3.20
RUN adduser -D -u 10001 app
COPY --from=build /out/app /usr/local/bin/app
USER app
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/app"]
```
> `replace => /sdk` + `COPY go/ /sdk/`로 **빌드 산출물(로컬 모듈)** 소비 — 모듈 임포트가능성 검증. `go mod tidy`가 gocloak 등 전이 의존을 lock.

- [ ] **Step 4: 검증** — Go 앱 이미지 빌드 + keycloak 붙여 기동 + 계약 스모크

```bash
cd harness
docker compose up -d keycloak && timeout 200 bash -c 'until [ "$(docker inspect -f {{.State.Health.Status}} $(docker compose ps -q keycloak))" = healthy ]; do sleep 3; done'
docker compose --profile apps up -d --build app-go
timeout 60 bash -c 'until curl -fsS http://localhost:8090/healthz >/dev/null 2>&1; do sleep 2; done'
curl -fsS http://localhost:8090/healthz            # {"status":"ok"}
curl -fsS -XPOST http://localhost:8090/token       # {"tokenType":"Bearer","expiresIn":...}
UID_=$(curl -fsS -XPOST http://localhost:8090/admin/users -d '{"username":"vu-smoke","email":"s@e.com"}' | python -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -fsS http://localhost:8090/admin/users/$UID_  # {"id":..,"username":"vu-smoke"}
curl -fsS -XDELETE http://localhost:8090/admin/users/$UID_ -o /dev/null -w "%{http_code}\n"  # 204
curl -s http://localhost:8090/admin/users/$UID_ -o /dev/null -w "%{http_code}\n"             # 404
docker compose --profile apps down
```
Expected: healthz ok · token 발급 · user 생성/조회/삭제/삭제후404.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(harness): Go MVP 앱 — 계약 8엔드포인트 + Go SDK replace 소비 + multistage Dockerfile (WBS 2)"`

---

### Task 3: k6 가상사용자 드라이버

**Files:** Create `harness/driver/scenarios.js`

**Interfaces:** Consumes: `__ENV.BASE_URL`(앱), `__ENV.KC_URL`(Keycloak), `__ENV.LANG`. Produces: `report/<LANG>.json`(k6 summary) + 종료코드(체크 실패 시 비0). 참조: [k6 handleSummary](https://grafana.com/docs/k6/latest/results-output/end-of-test/custom-summary/).

- [ ] **Step 1: `harness/driver/scenarios.js`**

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://localhost:8090';
const KC = __ENV.KC_URL || 'http://localhost:8080';
const LANG = __ENV.LANG || 'go';
const REALM = __ENV.KC_REALM || 'it-realm';
const CLIENT = __ENV.KC_CLIENT_ID || 'it-client';
const SECRET = __ENV.KC_CLIENT_SECRET || 'it-secret';

const validateDur = new Trend('validate_duration', true);
const introspectDur = new Trend('introspect_duration', true);
const tokenDur = new Trend('token_duration', true);
const adminDur = new Trend('admin_crud_duration', true);

export const options = {
  vus: Number(__ENV.VUS || 10),
  duration: __ENV.DURATION || '30s',
  thresholds: { checks: ['rate==1.00'] },   // 기능 정확성 게이트: 100% 아니면 비0 종료
};

const JSON_H = { headers: { 'Content-Type': 'application/json' } };

// 각 VU가 자체 토큰을 1회 획득(반복 내 재사용). client-credentials → aud에 it-client 포함(realm aud 매퍼).
function getToken() {
  const res = http.post(`${KC}/realms/${REALM}/protocol/openid-connect/token`,
    { grant_type: 'client_credentials', client_id: CLIENT, client_secret: SECRET });
  check(res, { 'kc token 200': (r) => r.status === 200 });
  return res.json('access_token');
}

let token;
export default function () {
  if (!token) token = getToken();

  const v = http.post(`${BASE}/validate`, JSON.stringify({ token }), JSON_H);
  validateDur.add(v.timings.duration);
  check(v, {
    'validate 200': (r) => r.status === 200,
    'validate subject': (r) => !!r.json('subject'),
    'validate aud has client': (r) => (r.json('audience') || []).includes(CLIENT),
    'validate issuer': (r) => String(r.json('issuer') || '').endsWith(`/realms/${REALM}`),
  });

  const i = http.post(`${BASE}/introspect`, JSON.stringify({ token }), JSON_H);
  introspectDur.add(i.timings.duration);
  check(i, { 'introspect 200': (r) => r.status === 200, 'introspect active': (r) => r.json('active') === true });

  const t = http.post(`${BASE}/token`, null);
  tokenDur.add(t.timings.duration);
  check(t, { 'token 200': (r) => r.status === 200, 'token expiresIn>0': (r) => Number(r.json('expiresIn')) > 0 });

  // admin 여정: create → get → delete → get=404
  const uname = `vu-${LANG}-${__VU}-${__ITER}`;
  const c = http.post(`${BASE}/admin/users`, JSON.stringify({ username: uname, email: `${uname}@e.com` }), JSON_H);
  const adminStart = Date.now();
  const created = check(c, { 'create 201': (r) => r.status === 201, 'create id': (r) => !!r.json('id') });
  if (created) {
    const id = c.json('id');
    const g = http.get(`${BASE}/admin/users/${id}`);
    check(g, { 'get 200': (r) => r.status === 200, 'get username': (r) => r.json('username') === uname });
    const d = http.del(`${BASE}/admin/users/${id}`);
    check(d, { 'delete 204': (r) => r.status === 204 });
    const g2 = http.get(`${BASE}/admin/users/${id}`);
    check(g2, { 'get-after-delete 404': (r) => r.status === 404 });
  }
  adminDur.add(Date.now() - adminStart);
}

export function handleSummary(data) {
  return { [`/report/${LANG}.json`]: JSON.stringify(data) };
}
```
> 기능 게이트는 `thresholds.checks==1.00`(전부 통과 아니면 k6 exit≠0). 엔드포인트별 `Trend`로 p95 산출. `handleSummary`가 `/report/<LANG>.json` 기록(k6 컨테이너가 `report/`를 `/report`로 마운트).

- [ ] **Step 2: 검증** — k6 컨테이너로 Go 앱 대상 실행

```bash
cd harness && docker compose up -d keycloak && timeout 200 bash -c 'until [ "$(docker inspect -f {{.State.Health.Status}} $(docker compose ps -q keycloak))" = healthy ]; do sleep 3; done'
docker compose --profile apps up -d --build app-go && timeout 60 bash -c 'until curl -fsS http://localhost:8090/healthz>/dev/null 2>&1; do sleep 2; done'
docker run --rm --network harness_default -v "$PWD/driver:/scripts" -v "$PWD/report:/report" \
  -e BASE_URL=http://app-go:8090 -e KC_URL=http://keycloak:8080 -e LANG=go -e DURATION=15s \
  grafana/k6 run /scripts/scenarios.js
echo "exit=$?"; test -f report/go.json && echo "SUMMARY OK"
docker compose --profile apps down
```
Expected: k6 요약에 `checks........: 100.00%`, exit 0, `report/go.json` 생성. (네트워크명은 `harness_default` — `docker network ls`로 확인.)

- [ ] **Step 3: Commit** — `git add -A && git commit -m "feat(harness): k6 가상사용자 드라이버 — 인증→validate/introspect/token/admin CRUD + 기능게이트 + p95 Trend (WBS 3)"`

---

### Task 4: 리포트 취합 + run.sh 오케스트레이션

**Files:** Create `harness/report/aggregate.mjs`, `harness/run.sh`

**Interfaces:** Consumes: `report/<lang>.json`(k6 summary — `data.metrics.checks.values.rate`, `data.metrics.<x>_duration.values['p(95)']`, `data.metrics.http_reqs.values.rate`, `data.metrics.http_req_failed.values.rate`). Produces: `report/RESULTS.md`. run.sh: 전체 파이프라인 + 종료코드.

- [ ] **Step 1: `harness/report/aggregate.mjs`**

```javascript
// Usage: node aggregate.mjs go [dotnet node python java] → report/RESULTS.md
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const langs = process.argv.slice(2);
const rows = [];
let anyFail = false;

for (const lang of langs) {
  const f = new URL(`./${lang}.json`, import.meta.url);
  if (!existsSync(f)) { rows.push({ lang, missing: true }); anyFail = true; continue; }
  const d = JSON.parse(readFileSync(f, 'utf8'));
  const m = d.metrics || {};
  const val = (n, k) => (m[n]?.values?.[k] ?? null);
  const checksRate = val('checks', 'rate');
  const pass = checksRate === 1;
  if (!pass) anyFail = true;
  rows.push({
    lang, pass, checksRate,
    validateP95: val('validate_duration', 'p(95)'),
    adminP95: val('admin_crud_duration', 'p(95)'),
    rps: val('http_reqs', 'rate'),
    errRate: val('http_req_failed', 'rate'),
  });
}

const n = (x, d = 2) => (x == null ? '—' : Number(x).toFixed(d));
let md = `# 하네스 실측 결과 (RESULTS)\n\n## 기능 정확성 게이트\n\n| 언어 | checks PASS율 | 게이트 |\n|---|---|---|\n`;
for (const r of rows) md += `| ${r.lang} | ${r.missing ? 'MISSING' : (100 * r.checksRate).toFixed(0) + '%'} | ${r.pass ? '✅' : '❌'} |\n`;
md += `\n## 성능 실측 (언어간 비교)\n\n| 언어 | validate p95(ms) | admin CRUD p95(ms) | RPS | 오류율 |\n|---|---|---|---|---|\n`;
for (const r of rows) if (!r.missing) md += `| ${r.lang} | ${n(r.validateP95)} | ${n(r.adminP95)} | ${n(r.rps)} | ${n(100 * r.errRate)}% |\n`;
md += `\n> 성능은 실측·비교용(임계값 강제 아님). 기능 게이트만 PASS/FAIL.\n`;

writeFileSync(new URL('./RESULTS.md', import.meta.url), md);
console.log(md);
process.exit(anyFail ? 1 : 0);
```

- [ ] **Step 2: `harness/run.sh`**

```bash
#!/usr/bin/env bash
# 전체 하네스 파이프라인. Usage: ./run.sh [go dotnet node python java]  (기본 go)
set -euo pipefail
cd "$(dirname "$0")"
LANGS=("${@:-go}")
NET=harness_default

cleanup() { docker compose --profile apps down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== Keycloak 기동 =="
docker compose up -d keycloak
timeout 220 bash -c 'until [ "$(docker inspect -f "{{.State.Health.Status}}" "$(docker compose ps -q keycloak)")" = healthy ]; do sleep 3; done'

rc=0
for LANG in "${LANGS[@]}"; do
  echo "== [$LANG] 앱 빌드·기동 =="
  docker compose --profile apps up -d --build "app-$LANG"
  PORT=$(docker compose port "app-$LANG" "$(app_port "$LANG")" 2>/dev/null | sed 's/.*://')
  timeout 90 bash -c "until curl -fsS http://localhost:$PORT/healthz >/dev/null 2>&1; do sleep 2; done"
  echo "== [$LANG] k6 실행 =="
  docker run --rm --network "$NET" -v "$PWD/driver:/scripts" -v "$PWD/report:/report" \
    -e "BASE_URL=http://app-$LANG:$(app_port "$LANG")" -e KC_URL=http://keycloak:8080 -e "LANG=$LANG" \
    grafana/k6 run /scripts/scenarios.js || rc=1
  docker compose --profile apps stop "app-$LANG" >/dev/null
done

echo "== 리포트 취합 =="
node report/aggregate.mjs "${LANGS[@]}" || rc=1
echo "== 완료 (rc=$rc) — report/RESULTS.md =="
exit $rc

# 앱별 컨테이너 내부 포트(계약: 모두 8090 사용 권장 → 단순화). 언어별 상이하면 여기 매핑.
app_port() { echo 8090; }
```
> ⚠️ bash 함수 `app_port`는 사용 전 정의돼야 하므로 실제 파일에선 스크립트 상단(첫 사용 전)에 배치한다. 모든 앱이 컨테이너 내부 8090을 쓰도록 통일(계약 단순화) — 호스트 포트는 compose가 매핑.

- [ ] **Step 3: 검증** — 전체 파이프라인(Go)

```bash
cd harness && chmod +x run.sh && ./run.sh go
echo "rc=$?"; cat report/RESULTS.md
```
Expected: `rc=0`, RESULTS.md에 Go ✅ + validate/admin p95·RPS·오류율.

- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat(harness): 리포트 취합(aggregate.mjs) + run.sh 오케스트레이션(build→up→k6→report→down) (WBS 4)"`

---

### Task 5: CI 워크플로 + 문서

**Files:** Create `.github/workflows/harness.yml`; Modify `README.md`(하네스 섹션), `docs/roadmap/language-support.md`(하네스 언급)

- [ ] **Step 1: `.github/workflows/harness.yml`**

```yaml
name: harness
on:
  push:
    paths: ['harness/**', 'go/**', '.github/workflows/harness.yml']
  pull_request:
    paths: ['harness/**', 'go/**', '.github/workflows/harness.yml']
permissions:
  contents: read
jobs:
  mvp-go:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - name: 하네스 실행(Go MVP)
        run: cd harness && ./run.sh go
      - name: 결과 업로드
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: harness-results
          path: harness/report/RESULTS.md
```
(GitHub 러너는 Docker + compose v2 내장. k6는 컨테이너로 실행하므로 별도 설치 불요.)

- [ ] **Step 2: 문서** — `README.md`에 하네스 섹션(목적·`cd harness && ./run.sh go`·기능게이트+성능실측·확장 예정), `docs/roadmap/language-support.md`에 하네스 딜리버러블 한 줄 추가(5개 언어 실측 검증 하네스, MVP=Go 완료·확장 예정).

- [ ] **Step 3: 검증** — YAML 파싱(`python -c "import yaml;yaml.safe_load(open('.github/workflows/harness.yml'))"`) + 로컬 `./run.sh go` 재확인.

- [ ] **Step 4: Commit** — `git add -A && git commit -m "ci(harness): harness.yml(Go MVP 게이트 + RESULTS 아티팩트) + README/roadmap 문서 (WBS 5)"`

---

## 확장 로드맵 (후속 계획 — 이 MVP 완료·검증 후)

MVP(Task 1~5)가 GREEN이면 동일 계약으로 앱을 증분 추가한다(드라이버/리포트/인프라 재사용). 언어당 1태스크:
- **C# 앱**: `harness/apps/dotnet/`(ASP.NET minimal API + `dotnet pack`→로컬 NuGet 폴더피드 소비 + multistage Dockerfile) → compose `app-dotnet`(내부 8090) → `run.sh dotnet` → k6 PASS.
- **Node 앱**: `harness/apps/node/`(`http`/express-min + `npm pack`→tarball 설치).
- **Python 앱**: `harness/apps/python/`(`http.server`/Flask-min + wheel `pip install`).
- **Java 앱**: `harness/apps/java/`(내장 `com.sun.net.httpserver` + `mvn install`→로컬 repo 소비).
- 각 태스크: 앱 구현(계약) → Dockerfile(패키지 소비) → compose 서비스 → `run.sh`/CI 매트릭스에 추가 → k6 정확성 PASS + RESULTS 비교표에 행 추가.
- 완료 시: `./run.sh go dotnet node python java` → 5개 언어 정확성 게이트 + 성능 비교표. 이때 언어간 동작 불일치(있다면)가 드러남 = 하네스의 핵심 가치.

---

## Self-Review (계획 ↔ 스펙 대조)

- **스펙 커버리지**: §3 아키텍처(5유닛)→T1(infra/contract)·T2(app)·T3(driver)·T4(report/run)·T5(CI) · §4 계약→T1(CONTRACT.md)+T2(구현) · §5 패키지소비→T2(Go replace/Dockerfile) · §6 드라이버→T3 · §7 리포트→T4 · §8 오케스트레이션→T4 · §9 MVP=Go→T1~5, 확장→로드맵 섹션 · §10 성공기준→T4/T5 검증. 누락 없음(확장 4개 앱은 의도적 후속).
- **플레이스홀더**: Go SDK API·k6 handleSummary·Keycloak compose import·gocloak helper는 실검증(go/ 소스·k6 문서·기존 E2E). 실코드/실명령/기대값 명시. "착수 시 확정"(VUS/DURATION 수치·네트워크명)은 검증 스텝에서 실측 확인하도록 명시.
- **타입/명칭 일관**: `it-realm`/`it-client`/`it-secret`·계약 8엔드포인트·`report/<lang>.json`·`checks==1.00` 게이트·`app_port=8090`(전 앱 내부 통일)·env 변수명(`KC_SERVER_URL`/`BASE_URL`/`LANG`)이 T1~T5·드라이버·run.sh·CI에서 일치. Go SDK 심볼(`keycloak.New`/`Config`/`Auth.ClientCredentialsToken`/`Auth.Validate`/`Admin`/`Users.Create·Get·Search·Delete`/`ErrNotFound`)이 실제 go/ 공개 API와 일치(실측).
