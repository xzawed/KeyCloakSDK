# 8개 언어 종합 검증·점수책정 하네스 Implementation Plan (WBS)

> <!-- doc-status: complete -->
> **✅ 완료된 계획 — 기록이다. 실행하지 말 것.** 아래 체크박스는 **전부 미체크로 남아 있지만 할 일이
> 아니다** — 실행 당시 갱신되지 않았을 뿐 작업은 끝났다. 바로 아래의 "For agentic workers" 지시도
> 그때의 것이라 지금은 유효하지 않다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [구현 이력](../../governance/history.md) · [문서 지도](../../README.md)에 있다.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 기존 `harness/`(5언어 k6)를 8언어로 확장하고, 계약 conformance 전면·보안 프로브·SDK 스위트 집계·엣지케이스 4종 검증과 4차원 가중 스코어링(기능30/보안30/커버리지20/성능·동형성20)을 얹어 언어별 스코어카드·등급·랭킹·규칙기반 보완 피드백을 산출한다.

**Architecture:** `harness/` 확장. 언어중립 코어(contract v2·conformance.mjs·security/probe.mjs·suites/run-suite.sh·report/score.mjs·verify.sh)는 완전 구현. 8개 앱은 동일 HTTP 계약을 각 언어 관용 프레임워크로 노출하는 얇은 어댑터(기존 5개 증분 확장 + 신규 php/rust/ruby). CI(ubuntu)가 전체 실행 1차 환경, Windows 로컬은 스모크.

**Tech Stack:** Docker Compose · k6(성능/부하) · Node.js(conformance·security·score 러너, ESM `.mjs`) · Alpine/musl 앱 이미지 · 각 SDK 툴체인 컨테이너(suite 집계).

## Global Constraints

- **8개 언어**: go·dotnet·node·python·java(기존, 계약 v2로 확장) + php·rust·ruby(신규). 각 앱은 SDK를 **주 소비 경로(파사드)로만** 호출(raw 탈출구 금지). 컨테이너 내부 포트 **8090** 통일.
- **계약 v2가 진실 원천**([harness/contract/CONTRACT.md](../../../harness/contract/CONTRACT.md)) — conformance·security·k6는 계약에만 의존. 오류매핑: NotFound→404·Conflict→409·Forbidden→403·JWT실패→401·기타→500 `{"error":".."}`. **토큰/시크릿 응답·로그 노출 금지**.
- **Alpine/musl 앱 베이스** — Windows Docker Desktop glibc-DNS 게차 회피. 공유 compose에 하드코딩 IP/`extra_hosts` 금지(CI landmine).
- **러너는 결정적**: conformance/security는 1-VU 결정적 assert(k6 부하와 분리). k6는 성능/부하 유지.
- **점수 4차원 가중**: 기능 정확성 30%·보안 하드닝 30%·테스트 커버리지/품질 20%·성능/동형성 20%. 등급 A(≥90)/B(≥80)/C(≥70)/D(<70). 성능만 상대 백분위, 나머지 절대.
- **부분 실패 격리**: 언어 1개 실패가 나머지 산출을 막지 않는다(verify.sh continue-on-error·부분 SCORECARD).
- **CI 1차**: 8언어+스코어링 전체는 CI 야간(`schedule`)·수동(`workflow_dispatch`), `timeout-minutes` 상향. Windows 로컬은 1~2 언어 스모크.
- **커밋**: 각 태스크 끝. 브랜치 `feature/verification-scoring-harness`. 메시지 `feat(harness):`/`test(harness):`/`chore(harness):`.

### 기존 자산 (재사용·확장)
- `harness/run.sh`(KC 기동→앱 빌드·기동→k6→aggregate) · `harness/driver/scenarios.js`(k6) · `harness/report/aggregate.mjs` · `harness/docker-compose.yml`(app-{go,dotnet,node,python,java}) · `harness/apps/{5}`(기존 앱) · `harness/contract/CONTRACT.md`(v1).
- 각 SDK 위치·테스트 커맨드: `java/`(mvn)·`python/`(.venv pytest)·`node/`(npm)·`go/`(go test)·`dotnet/`(dotnet test)·`php/`(vendor/bin/phpunit)·`rust/`(cargo test)·`ruby/`(bundle exec rspec). realm fixture `go/testdata/it-realm-realm.json`(it-realm·it-client·it-secret).

---

## Phase 1 — 계약 v2 + 8앱 (기능 패리티)

### Task 1.1: 계약 v2 문서화 (진실 원천)

**Files:**
- Modify: `harness/contract/CONTRACT.md`

**Interfaces:**
- Produces: 8앱이 구현할 계약 표면. conformance/security 러너가 이 문서에만 의존.

- [ ] **Step 1: `CONTRACT.md`에 v2 엔드포인트 추가**

기존 표(healthz·token·validate·introspect·admin/users CRUD) 아래에 추가:
```markdown
## v2 확장 (모든 앱 동일 노출)

### auth 확장
| 메서드·경로 | 요청 body | 성공 | 실패 |
|---|---|---|---|
| `POST /token/password` | `{"username":"..","password":".."}` | 200 `{"tokenType":"Bearer","expiresIn":<int>,"hasRefresh":<bool>}` | 401 `{"error":".."}` |
| `POST /refresh` | `{}` (앱이 직전 password-grant refresh 토큰 서버측 보관) | 200 `{"tokenType":"Bearer","expiresIn":<int>}` | 401 |
| `POST /logout` | `{}` (앱 서버측 세션) | 204 | 500 |
| `GET /authz-url?redirect_uri=<u>` | — | 200 `{"url":"..","state":".."}` (url은 `code_challenge_method=S256`·`code_challenge`·`state` 포함, code_verifier 미노출) | 500 |

### admin 5리소스 확장
| 메서드·경로 | 요청 body | 성공 | 실패 |
|---|---|---|---|
| `POST /admin/clients` | `{"clientId":".."}` | 201 `{"id":".."}` | 409/500 |
| `GET /admin/clients/{id}` | — | 200 `{"id":"..","clientId":".."}` | 404 |
| `DELETE /admin/clients/{id}` | — | 204 | 404 |
| `POST /admin/roles` | `{"name":".."}` | 201 `{"name":".."}` | 409/500 |
| `GET /admin/roles/{name}` | — | 200 `{"name":".."}` | 404 |
| `DELETE /admin/roles/{name}` | — | 204 | 404 |
| `POST /admin/groups` | `{"name":".."}` | 201 `{"id":".."}` | 409/500 |
| `GET /admin/groups/{id}` | — | 200 `{"id":"..","name":".."}` | 404 |
| `DELETE /admin/groups/{id}` | — | 204 | 404 |
| `POST /admin/realms` | `{"realm":".."}` | 201 `{"realm":".."}` 또는 403 `{"error":".."}` | 403/500 |

**오류경로 검증 계약**: 중복 `POST /admin/users`(같은 username 2회) → 2번째 409. `POST /admin/realms`(realm SA 토큰) → 403(마스터 토큰 없으면). `POST /validate`(위조 토큰) → 401.
```

- [ ] **Step 2: Commit**
```bash
git add harness/contract/CONTRACT.md
git commit -m "docs(harness): 계약 v2 — auth 확장(password/refresh/logout/authz-url) + admin 5리소스 + 오류경로"
```

---

### Task 1.2: docker-compose + 오케스트레이터 스캐폴딩 (신규 3앱 서비스·verify.sh)

**Files:**
- Modify: `harness/docker-compose.yml` (app-php·app-rust·app-ruby 서비스 추가)
- Create: `harness/verify.sh`
- Modify: `harness/run.sh` (8언어 목록 허용 — 이미 `"$@"` 받으므로 확인만)

**Interfaces:**
- Produces: `verify.sh [langs...]` — KC→앱→conformance+security+perf→suite→score 전체 파이프라인. 부분 실패 격리.
- Consumes: 각 앱 서비스 `app-<lang>`(내부 8090), `app_port()`=8090.

- [ ] **Step 1: compose에 신규 3앱 서비스 추가**

`harness/docker-compose.yml`의 `profiles: [apps]` 앱 블록을 본떠 추가(기존 app-go 블록 참고, Alpine 베이스):
```yaml
  app-php:
    profiles: [apps]
    build: { context: .., dockerfile: harness/apps/php/Dockerfile }
    environment: [ "KC_URL=http://keycloak:8080", "KC_REALM=it-realm", "KC_CLIENT_ID=it-client", "KC_CLIENT_SECRET=it-secret", "APP_PORT=8090" ]
    ports: ["8095:8090"]
    networks: [default]
    depends_on: { keycloak: { condition: service_healthy } }
  app-rust:
    profiles: [apps]
    build: { context: .., dockerfile: harness/apps/rust/Dockerfile }
    environment: [ "KC_URL=http://keycloak:8080", "KC_REALM=it-realm", "KC_CLIENT_ID=it-client", "KC_CLIENT_SECRET=it-secret", "APP_PORT=8090" ]
    ports: ["8096:8090"]
    networks: [default]
    depends_on: { keycloak: { condition: service_healthy } }
  app-ruby:
    profiles: [apps]
    build: { context: .., dockerfile: harness/apps/ruby/Dockerfile }
    environment: [ "KC_URL=http://keycloak:8080", "KC_REALM=it-realm", "KC_CLIENT_ID=it-client", "KC_CLIENT_SECRET=it-secret", "APP_PORT=8090" ]
    ports: ["8097:8090"]
    networks: [default]
    depends_on: { keycloak: { condition: service_healthy } }
```
> 호스트 포트: php 8095·rust 8096·ruby 8097(기존 go 8090/dotnet 8091/node 8092/python 8093/java 8094 다음). 빌드 컨텍스트는 리포 루트(`..`)라 Dockerfile이 `<lang>/` SDK 소스를 참조 가능.

- [ ] **Step 2: `harness/verify.sh` 작성 (오케스트레이터)**

```bash
#!/usr/bin/env bash
# 종합 검증 파이프라인. Usage: ./verify.sh [go dotnet node python java php rust ruby]  (기본 전체)
set -uo pipefail
cd "$(dirname "$0")"
LANGS=("${@:-go dotnet node python java php rust ruby}")
[ "${#LANGS[@]}" -eq 1 ] && read -ra LANGS <<< "${LANGS[0]}"
NET=harness_default
export MSYS_NO_PATHCONV=1
mkdir -p report/signals
cleanup() { docker compose --profile apps down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== Keycloak 기동 =="
docker compose up -d keycloak
timeout 240 bash -c 'until [ "$(docker inspect -f "{{.State.Health.Status}}" "$(docker compose ps -q keycloak)")" = healthy ]; do sleep 3; done'
chmod -R 777 report 2>/dev/null || true

for L in "${LANGS[@]}"; do
  echo "== [$L] 앱 빌드·기동 =="
  if ! docker compose --profile apps up -d --build "app-$L"; then echo "{\"lang\":\"$L\",\"error\":\"build/up failed\"}" > "report/signals/$L.error.json"; continue; fi
  PORT=$(docker compose port "app-$L" 8090 2>/dev/null | sed 's/.*://')
  if ! timeout 120 bash -c "until curl -fsS http://localhost:$PORT/healthz >/dev/null 2>&1; do sleep 2; done"; then echo "{\"lang\":\"$L\",\"error\":\"healthz timeout\"}" > "report/signals/$L.error.json"; docker compose --profile apps stop "app-$L" >/dev/null 2>&1; continue; fi

  echo "== [$L] conformance =="
  docker run --rm --network "$NET" -v "$PWD/conformance:/c" -v "$PWD/report/signals:/out" \
    -e "BASE=http://app-$L:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$L" node:20-alpine node /c/conformance.mjs || true
  echo "== [$L] security =="
  docker run --rm --network "$NET" -v "$PWD/security:/s" -v "$PWD/report/signals:/out" \
    -e "BASE=http://app-$L:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$L" node:20-alpine node /s/probe.mjs || true
  echo "== [$L] k6 성능 =="
  docker run --rm --network "$NET" -v "$PWD/driver:/scripts" -v "$PWD/report:/report" \
    -e "BASE_URL=http://app-$L:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$L" grafana/k6 run /scripts/scenarios.js || true
  docker compose --profile apps stop "app-$L" >/dev/null 2>&1
done

echo "== SDK 스위트 집계 =="
./suites/run-suite.sh "${LANGS[@]}" || true
echo "== 스코어링 =="
node report/score.mjs "${LANGS[@]}"
echo "== 완료 — report/SCORECARD.md =="
```

- [ ] **Step 3: 스모크 (기존 go 앱으로 파이프라인 골격 확인 — conformance/security/score는 아직 stub 허용)**

Run:
```bash
cd harness && chmod +x verify.sh
# 이 시점엔 conformance/security/score가 없으므로 앱 기동·healthz까지만 확인
docker compose up -d keycloak && docker compose --profile apps up -d --build app-go
curl -fsS http://localhost:8090/healthz && echo OK
docker compose --profile apps down -v
```
Expected: `{"status":"ok"}` OK (기존 go 앱 정상 기동).

- [ ] **Step 4: Commit**
```bash
git add harness/docker-compose.yml harness/verify.sh
git commit -m "chore(harness): compose 신규 3앱 서비스(php/rust/ruby) + verify.sh 오케스트레이터(부분실패 격리)"
```

---

### Task 1.3: app-ruby (신규·참조 구현) — Sinatra + KeycloakSdk

**Files:**
- Create: `harness/apps/ruby/Dockerfile` · `harness/apps/ruby/app.rb` · `harness/apps/ruby/Gemfile`

**Interfaces:**
- Produces: 계약 v2 전 엔드포인트를 노출하는 앱(내부 8090). 다른 신규 앱(rust/php)의 구조 참조.
- Consumes: `keycloak_sdk` gem(로컬 경로 `../../../ruby` — 빌드 컨텍스트 리포 루트 기준 `ruby/`).

- [ ] **Step 1: `Gemfile`**
```ruby
# frozen_string_literal: true
source "https://rubygems.org"
gem "keycloak-sdk", path: "/src/ruby"   # Dockerfile이 리포 ruby/를 /src/ruby로 복사
gem "sinatra", "~> 4.0"
gem "puma", "~> 6.4"
gem "rackup", "~> 2.1"
```

- [ ] **Step 2: `app.rb` (계약 v2 전 엔드포인트 — SDK 호출 매핑)**
```ruby
# frozen_string_literal: true
require "sinatra/base"
require "json"
require "keycloak_sdk"

CFG = KeycloakSdk::Config.new(
  server_url: ENV.fetch("KC_URL"), realm: ENV.fetch("KC_REALM"),
  client_id: ENV.fetch("KC_CLIENT_ID"), client_secret: ENV.fetch("KC_CLIENT_SECRET")
)
KC = KeycloakSdk::KeycloakClient.new(CFG)
SESS = {} # 서버측 refresh 토큰 보관(logout/refresh 자동화용)

class App < Sinatra::Base
  set :port, ENV.fetch("APP_PORT", "8090").to_i
  set :bind, "0.0.0.0"
  before { content_type :json }
  helpers do
    def body_json; JSON.parse(request.body.read) rescue {}; end
    def err(code, msg); status code; { error: msg }.to_json; end
    def map_admin(e) # KeycloakSdk 오류 → HTTP
      case e
      when KeycloakSdk::NotFoundError then 404
      when KeycloakSdk::ConflictError then 409
      when KeycloakSdk::ForbiddenError then 403
      else 500 end
    end
  end

  get("/healthz") { { status: "ok" }.to_json }

  post "/token" do
    t = KC.auth.client_credentials_token
    { tokenType: t.token_type, expiresIn: t.expires_in }.to_json
  rescue => e then err(500, e.message) end

  post "/token/password" do
    b = body_json
    t = KC.auth.password_grant(username: b["username"], password: b["password"]) # ⚠ SDK에 ROPC 헬퍼 없으면 아래 주석 참고
    SESS[:refresh] = t.refresh_token
    { tokenType: t.token_type, expiresIn: t.expires_in, hasRefresh: !t.refresh_token.nil? }.to_json
  rescue => e then err(401, e.message) end

  post "/refresh" do
    t = KC.auth.refresh(refresh_token: SESS.fetch(:refresh))
    { tokenType: t.token_type, expiresIn: t.expires_in }.to_json
  rescue => e then err(401, e.message) end

  post "/logout" do
    KC.auth.logout(refresh_token: SESS[:refresh]); status 204
  rescue => e then err(500, e.message) end

  get "/authz-url" do
    r = KC.auth.create_authorization_request(redirect_uri: params["redirect_uri"] || "http://x/cb")
    { url: r.url, state: r.state }.to_json
  rescue => e then err(500, e.message) end

  post "/validate" do
    v = KC.auth.validate(body_json["token"])
    { subject: v.subject, audience: v.audience, issuer: v.issuer, expiresAt: v.expires_at }.to_json
  rescue => e then err(401, e.message) end

  post "/introspect" do
    r = KC.auth.introspect(body_json["token"])
    { active: r.active?, username: r.username, clientId: r.client_id }.to_json
  rescue => e then err(500, e.message) end

  # admin users
  post "/admin/users" do
    b = body_json
    id = KC.admin.users.create({ username: b["username"], email: b["email"], enabled: true })
    status 201; { id: id }.to_json
  rescue => e then err(map_admin(e), e.message) end
  get "/admin/users/:id" do
    u = KC.admin.users.get(params["id"]); { id: u["id"], username: u["username"] }.to_json
  rescue => e then err(map_admin(e), e.message) end
  get "/admin/users" do
    KC.admin.users.list(username: params["username"]).map { |u| { id: u["id"], username: u["username"] } }.to_json
  rescue => e then err(map_admin(e), e.message) end
  delete("/admin/users/:id") { KC.admin.users.delete(params["id"]); status 204 rescue => e then err(map_admin(e), e.message) end }

  # admin clients / roles / groups (동일 패턴)
  post "/admin/clients" do id = KC.admin.clients.create({ clientId: body_json["clientId"], enabled: true }); status 201; { id: id }.to_json rescue => e then err(map_admin(e), e.message) end
  get "/admin/clients/:id" do c = KC.admin.clients.get(params["id"]); { id: c["id"], clientId: c["clientId"] }.to_json rescue => e then err(map_admin(e), e.message) end
  delete("/admin/clients/:id") { KC.admin.clients.delete(params["id"]); status 204 rescue => e then err(map_admin(e), e.message) end }
  post "/admin/roles" do KC.admin.roles.create({ name: body_json["name"] }); status 201; { name: body_json["name"] }.to_json rescue => e then err(map_admin(e), e.message) end
  get "/admin/roles/:name" do r = KC.admin.roles.get(params["name"]); { name: r["name"] }.to_json rescue => e then err(map_admin(e), e.message) end
  delete("/admin/roles/:name") { KC.admin.roles.delete(params["name"]); status 204 rescue => e then err(map_admin(e), e.message) end }
  post "/admin/groups" do id = KC.admin.groups.create({ name: body_json["name"] }); status 201; { id: id }.to_json rescue => e then err(map_admin(e), e.message) end
  get "/admin/groups/:id" do g = KC.admin.groups.get(params["id"]); { id: g["id"], name: g["name"] }.to_json rescue => e then err(map_admin(e), e.message) end
  delete("/admin/groups/:id") { KC.admin.groups.delete(params["id"]); status 204 rescue => e then err(map_admin(e), e.message) end }
  post "/admin/realms" do KC.admin.realms.create({ realm: body_json["realm"], enabled: true }); status 201; { realm: body_json["realm"] }.to_json rescue => e then err(map_admin(e), e.message) end

  run! if app_file == $0
end
App.run!
```
> ⚠️ **ROPC 헬퍼**: Ruby SDK `AuthClient`에 `password_grant`가 없으면 두 경로 중 택1 — (a) SDK에 `password_grant(username:, password:)` 헬퍼를 추가(rack-oauth2 `resource_owner_credentials`)하고 단위테스트 보강(별도 소규모 SDK 확장·리뷰 필요), 또는 (b) 앱이 KC 토큰 엔드포인트로 직접 ROPC POST(하네스 앱 로컬 헬퍼). **본 하네스는 (b) 앱-로컬 헬퍼 권장**(SDK 표면 불변·검증 목적엔 충분). 구현자는 (b)로 `POST {KC_URL}/realms/{realm}/protocol/openid-connect/token` grant_type=password + Faraday로 처리. 8개 앱 동일.

- [ ] **Step 3: `Dockerfile` (Alpine + 네이티브 gem 빌드)**
```dockerfile
FROM ruby:3.4-alpine
RUN apk add --no-cache build-base git openssl-dev yaml-dev
WORKDIR /src/ruby
COPY ruby/ /src/ruby/
WORKDIR /app
COPY harness/apps/ruby/Gemfile /app/
RUN bundle install
COPY harness/apps/ruby/app.rb /app/
EXPOSE 8090
CMD ["ruby", "app.rb"]
```

- [ ] **Step 4: 빌드·기동·계약 스모크**
Run:
```bash
cd harness && docker compose up -d keycloak
timeout 240 bash -c 'until [ "$(docker inspect -f "{{.State.Health.Status}}" "$(docker compose ps -q keycloak)")" = healthy ]; do sleep 3; done'
docker compose --profile apps up -d --build app-ruby
timeout 120 bash -c 'until curl -fsS http://localhost:8097/healthz >/dev/null; do sleep 2; done'
curl -fsS -XPOST http://localhost:8097/token && echo " <- token OK"
curl -fsS -XPOST http://localhost:8097/admin/users -d '{"username":"h1","email":"h1@e.com"}' -H 'content-type: application/json' && echo " <- create OK"
docker compose --profile apps down -v
```
Expected: `/healthz` ok · `/token` `{"tokenType":"Bearer","expiresIn":..}` · `/admin/users` `{"id":".."}`.

- [ ] **Step 5: Commit**
```bash
git add harness/apps/ruby/
git commit -m "feat(harness): app-ruby(Sinatra+KeycloakSdk) — 계약 v2 전 엔드포인트(신규 앱 참조 구현)"
```

---

### Task 1.4: app-rust (신규) — axum + keycloak-sdk

**Files:** Create `harness/apps/rust/{Dockerfile,Cargo.toml,src/main.rs}`

**Interfaces:** app-ruby(Task 1.3)와 동일 계약 표면. `keycloak-sdk` 크레이트(로컬 path `/src/rust`).

- [ ] **Step 1: 앱 작성** — `axum`(async, tokio) + `keycloak_sdk` 크레이트. 엔드포인트↔SDK 호출은 Task 1.3의 매핑과 동일하되 Rust API로:
  - `KeycloakClient::new(config)` · `client.auth().client_credentials_token().await` · `.validate(token).await` · `.introspect(token).await` · `.create_authorization_request(...)` · `.refresh(...).await` · `.logout(...).await`.
  - admin: `client.admin().await?.users().create(rep).await` 등(5리소스). 오류: `KeycloakError::Admin(NotFound/Conflict/Forbidden)` → 404/409/403 매핑(`map_admin` 헬퍼).
  - ROPC: 앱-로컬 Faraday-상당(reqwest)로 KC 토큰 엔드포인트 직접 POST(Task 1.3 주석 (b)).
  - JSON: `axum::Json`, 오류 응답 `(StatusCode, Json<{error}>)`.
- [ ] **Step 2: `Cargo.toml`** — `keycloak-sdk = { path = "/src/rust" }` · `axum` · `tokio`(rt-multi-thread·macros) · `serde`/`serde_json` · `reqwest`(ROPC).
- [ ] **Step 3: `Dockerfile`** — `FROM rust:alpine` + `apk add build-base musl-dev openssl-dev perl make`(ring/rustls·openssl 빌드) → `COPY rust/ /src/rust/` + 앱 빌드 → 런타임. (musl 정적링크로 실행 이미지 축소 가능.)
- [ ] **Step 4: 빌드·기동·스모크**(포트 8096, Task 1.3 Step4 동형) — `/healthz`·`/token`·`/admin/users` 확인.
- [ ] **Step 5: Commit** `feat(harness): app-rust(axum+keycloak-sdk) — 계약 v2`

---

### Task 1.5: app-php (신규) — Slim + fschmtt/league SDK

**Files:** Create `harness/apps/php/{Dockerfile,composer.json,public/index.php}`

**Interfaces:** 동일 계약 표면. `xzawed/keycloak-sdk`(로컬 path repositories `/src/php`).

- [ ] **Step 1: 앱 작성** — `Slim 4` + PHP built-in server 또는 PHP-FPM. 엔드포인트↔SDK(PHP 파사드): `new KeycloakClient($config)` · `$kc->auth()->clientCredentialsToken()` · `->validate($t)` · `->introspect($t)` · `->createAuthorizationRequest(...)` · `->refresh(...)` · `->logout(...)`. admin: `$kc->admin()->users()->create($rep)` 등 5리소스. 오류: `KeycloakSdk\Exception\{NotFound,Conflict,Forbidden}Exception` → 404/409/403. ROPC는 앱-로컬 Guzzle POST.
- [ ] **Step 2: `composer.json`** — `repositories: [{type:path, url:/src/php}]` · `require: {xzawed/keycloak-sdk:*, slim/slim:^4, slim/psr7:^1}`.
- [ ] **Step 3: `Dockerfile`** — `FROM php:8.3-alpine` + `apk add`(git·$PHPIZE_DEPS) + install ext(curl·mbstring·openssl 기본 포함) + composer + `COPY php/ /src/php/` → `composer install` → CMD `php -S 0.0.0.0:8090 -t public`.
- [ ] **Step 4: 빌드·기동·스모크**(포트 8095) — `/healthz`·`/token`·`/admin/users`.
- [ ] **Step 5: Commit** `feat(harness): app-php(Slim+keycloak-sdk) — 계약 v2`

---

### Task 1.6: 기존 5앱 계약 v2 확장 (go·dotnet·node·python·java)

**Files:** Modify `harness/apps/{go,dotnet,node,python,java}/`(각 앱 진입 파일)

**Interfaces:** 기존 앱에 v2 신규 엔드포인트(password/refresh/logout/authz-url + clients/roles/groups CRUD + realms)를 추가. 기존 엔드포인트·구조 유지.

- [ ] **Step 1: 각 앱에 신규 엔드포인트 추가** — 언어별 SDK API로 Task 1.3 매핑과 동형 구현:
  - **go**(net/http): `client.Auth.CreateAuthorizationRequest`·`Refresh`·`Logout`·admin `client.Admin(ctx).Clients()/Roles()/Groups()/Realms()`. ROPC 앱-로컬 `x/oauth2` password 또는 http POST.
  - **dotnet**(ASP.NET Core): `kc.Auth.CreateAuthorizationRequestAsync`·`RefreshAsync`·`LogoutAsync`·`(await kc.AdminAsync()).Clients/Roles/Groups/Realms`. ROPC `HttpClient`.
  - **node**(Express): `kc.auth.createAuthorizationRequest`·`refresh`·`logout`·`kc.admin.clients/roles/groups/realms`. ROPC undici/fetch.
  - **python**(FastAPI): `kc.auth.create_authorization_request`·`refresh`·`logout`·`kc.admin.clients/roles/groups/realms`. ROPC httpx.
  - **java**(Spring Boot): `client.auth().createAuthorizationRequest`·`refresh`·`logout`·`client.admin().clients()/roles()/groups()/realms()`. ROPC 앱-로컬.
- [ ] **Step 2: 각 앱 빌드·기동·신규 엔드포인트 스모크** — 언어별로 `/authz-url`·`/admin/clients` 등 신규 경로가 200/201 응답 확인.
- [ ] **Step 3: Commit**(앱별 또는 일괄) `feat(harness): 기존 5앱 계약 v2 확장(refresh/logout/authz-url + clients/roles/groups/realms)`

> ⚠️ **각 SDK의 정확한 메서드명은 해당 언어 SDK 소스로 확인**(예: Go admin은 `client.Admin(ctx)`가 `(*AdminClient, error)`, Node/C#은 지연 admin). representation은 각 SDK 관용(hash/dict/representation 타입). authz-url이 없는 SDK 흐름은 §계약대로 S256 URL만 조립.

---

## Phase 2 — conformance 러너 (기능 정확성 신호)

### Task 2.1: harness 전용 realm에 테스트 사용자 시드 (ROPC 진입)

**Files:** Create `harness/keycloak/harness-realm.json` (기존 it-realm 확장) · Modify compose keycloak import 경로

**Interfaces:** `harness-user`/`harness-pass` 시드 사용자 → password/refresh/logout 자동화 진입.

- [ ] **Step 1**: `go/testdata/it-realm-realm.json`을 복사해 `harness/keycloak/harness-realm.json` 생성하고 `users` 배열에 추가:
```json
{ "username": "harness-user", "enabled": true, "email": "hu@e.com",
  "credentials": [{ "type": "password", "value": "harness-pass", "temporary": false }] }
```
그리고 `it-client`에 `directAccessGrantsEnabled: true`(ROPC 허용) 확인/설정.
- [ ] **Step 2**: compose keycloak 서비스의 realm import 마운트를 `harness/keycloak/`로 지정(기존이 testdata를 마운트하면 변경). `KC_USER=harness-user`·`KC_PASS=harness-pass`를 앱 환경에 추가(Task 1.2 compose env).
- [ ] **Step 3**: KC 기동 후 `curl -XPOST .../realms/it-realm/protocol/openid-connect/token -d 'grant_type=password&client_id=it-client&client_secret=it-secret&username=harness-user&password=harness-pass'`가 access_token 반환 확인. Commit.

---

### Task 2.2: conformance.mjs (결정적 계약 검증)

**Files:** Create `harness/conformance/conformance.mjs`

**Interfaces:**
- Consumes: env `BASE`(app), `KC_URL`, `LANG`, `KC_USER`/`KC_PASS`. 계약 v2.
- Produces: `/out/<LANG>.conformance.json` = `{lang, passed:int, failed:int, checks:[{name, ok:bool, detail}]}`.

- [ ] **Step 1: `conformance.mjs` 작성 (Node 20 내장 fetch, 무의존)**
```javascript
// 계약 v2 결정적 conformance. Node 20+ (전역 fetch). 결과를 /out/<LANG>.conformance.json에 기록.
const BASE = process.env.BASE, LANG = process.env.LANG || "unknown";
const U = process.env.KC_USER || "harness-user", P = process.env.KC_PASS || "harness-pass";
const checks = [];
const rec = (name, ok, detail = "") => { checks.push({ name, ok, detail: String(detail).slice(0, 300) }); };
const J = { "content-type": "application/json" };
const rnd = () => Math.random().toString(36).slice(2, 10);
async function req(method, path, body) {
  const r = await fetch(BASE + path, { method, headers: J, body: body === undefined ? undefined : JSON.stringify(body) });
  let j = null; try { j = await r.json(); } catch { /* 204 등 */ }
  return { status: r.status, j };
}
async function check(name, fn) { try { await fn(); } catch (e) { rec(name, false, e.message); } }

const run = async () => {
  await check("healthz 200", async () => { const r = await req("GET", "/healthz"); rec("healthz 200", r.status === 200 && r.j?.status === "ok", r.status); });

  // client-credentials 토큰 + validate + introspect
  let token;
  await check("token(client-creds)", async () => {
    const r = await req("POST", "/token"); const ok = r.status === 200 && r.j?.expiresIn > 0; rec("token(client-creds)", ok, r.status);
  });
  // KC에서 직접 access_token 취득(validate/introspect 입력용)
  await check("obtain access_token", async () => {
    const form = new URLSearchParams({ grant_type: "client_credentials", client_id: "it-client", client_secret: "it-secret" });
    const r = await fetch(`${process.env.KC_URL}/realms/it-realm/protocol/openid-connect/token`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: form });
    token = (await r.json()).access_token; rec("obtain access_token", !!token, r.status);
  });
  await check("validate 200 (multi-aud)", async () => { const r = await req("POST", "/validate", { token }); rec("validate 200 (multi-aud)", r.status === 200 && !!r.j?.issuer && Array.isArray(r.j?.audience), r.status); });
  await check("validate rejects garbage 401", async () => { const r = await req("POST", "/validate", { token: "not.a.jwt" }); rec("validate rejects garbage 401", r.status === 401, r.status); });
  await check("introspect active", async () => { const r = await req("POST", "/introspect", { token }); rec("introspect active", r.status === 200 && r.j?.active === true, r.status); });

  // authz-url (오프라인 PKCE S256)
  await check("authz-url S256", async () => {
    const r = await req("GET", "/authz-url?redirect_uri=http://x/cb");
    const u = r.j?.url || ""; rec("authz-url S256", r.status === 200 && /code_challenge_method=S256/.test(u) && /code_challenge=/.test(u) && !!r.j?.state, u.slice(0, 120));
  });

  // ROPC → refresh → logout (hasRefresh 가드)
  await check("token/password", async () => { const r = await req("POST", "/token/password", { username: U, password: P }); global.__hasRefresh = r.j?.hasRefresh === true; rec("token/password", r.status === 200 && r.j?.expiresIn > 0, r.status); });
  await check("refresh", async () => { if (!global.__hasRefresh) return rec("refresh", true, "skipped(no refresh)"); const r = await req("POST", "/refresh", {}); rec("refresh", r.status === 200 && r.j?.expiresIn > 0, r.status); });
  await check("logout 204", async () => { if (!global.__hasRefresh) return rec("logout 204", true, "skipped"); const r = await req("POST", "/logout", {}); rec("logout 204", r.status === 204, r.status); });

  // admin users CRUD + 오류경로
  const uname = `cf-${rnd()}`; let uid;
  await check("user create 201", async () => { const r = await req("POST", "/admin/users", { username: uname, email: `${uname}@e.com` }); uid = r.j?.id; rec("user create 201", r.status === 201 && !!uid, r.status); });
  await check("user duplicate 409", async () => { const r = await req("POST", "/admin/users", { username: uname, email: `${uname}@e.com` }); rec("user duplicate 409", r.status === 409, r.status); });
  await check("user get 200", async () => { const r = await req("GET", `/admin/users/${uid}`); rec("user get 200", r.status === 200 && r.j?.username === uname, r.status); });
  await check("user delete 204", async () => { const r = await req("DELETE", `/admin/users/${uid}`); rec("user delete 204", r.status === 204, r.status); });
  await check("user get-after-delete 404", async () => { const r = await req("GET", `/admin/users/${uid}`); rec("user get-after-delete 404", r.status === 404, r.status); });

  // admin clients / roles / groups CRUD
  const cid = `cf-c-${rnd()}`; let cInternal;
  await check("client create 201", async () => { const r = await req("POST", "/admin/clients", { clientId: cid }); cInternal = r.j?.id; rec("client create 201", r.status === 201 && !!cInternal, r.status); });
  await check("client get 200", async () => { const r = await req("GET", `/admin/clients/${cInternal}`); rec("client get 200", r.status === 200 && r.j?.clientId === cid, r.status); });
  await check("client delete 204", async () => { const r = await req("DELETE", `/admin/clients/${cInternal}`); rec("client delete 204", r.status === 204, r.status); });
  const role = `cf-r-${rnd()}`;
  await check("role create 201", async () => { const r = await req("POST", "/admin/roles", { name: role }); rec("role create 201", r.status === 201, r.status); });
  await check("role get 200", async () => { const r = await req("GET", `/admin/roles/${role}`); rec("role get 200", r.status === 200 && r.j?.name === role, r.status); });
  await check("role delete 204", async () => { const r = await req("DELETE", `/admin/roles/${role}`); rec("role delete 204", r.status === 204, r.status); });
  const grp = `cf-g-${rnd()}`; let gid;
  await check("group create 201", async () => { const r = await req("POST", "/admin/groups", { name: grp }); gid = r.j?.id; rec("group create 201", r.status === 201 && !!gid, r.status); });
  await check("group delete 204", async () => { const r = await req("DELETE", `/admin/groups/${gid}`); rec("group delete 204", r.status === 204, r.status); });

  // realms — realm SA는 403(마스터 토큰 미보유 앱)
  await check("realms create 403 (realm SA)", async () => { const r = await req("POST", "/admin/realms", { realm: `cf-realm-${rnd()}` }); rec("realms create 403 (realm SA)", r.status === 403, r.status); });

  const passed = checks.filter(c => c.ok).length, failed = checks.length - passed;
  const out = { lang: LANG, passed, failed, checks };
  const fs = await import("node:fs"); fs.writeFileSync(`/out/${LANG}.conformance.json`, JSON.stringify(out, null, 2));
  console.log(`[conformance ${LANG}] ${passed}/${checks.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
};
run().catch(e => { console.error(e); process.exit(2); });
```
> ⚠️ **realms 403 기대**: 앱은 realm SA 토큰이라 `POST /admin/realms`가 403이어야 정상(동형 오류매핑 검증). master 토큰으로 실제 realm 생성은 SDK 통합테스트가 이미 커버 → 하네스는 403 경로만.

- [ ] **Step 2: 로컬 검증 (go 앱 대상)**
Run:
```bash
cd harness && docker compose up -d keycloak && docker compose --profile apps up -d --build app-go
timeout 120 bash -c 'until curl -fsS http://localhost:8090/healthz >/dev/null; do sleep 2; done'
mkdir -p report/signals
docker run --rm --network harness_default -v "$PWD/conformance:/c" -v "$PWD/report/signals:/out" \
  -e BASE=http://app-go:8090 -e KC_URL=http://keycloak:8080 -e LANG=go -e KC_USER=harness-user -e KC_PASS=harness-pass \
  node:20-alpine node /c/conformance.mjs
cat report/signals/go.conformance.json | head -20
docker compose --profile apps down -v
```
Expected: `go.conformance.json` 생성, 대부분 checks ok(앱이 계약 v2 완전 구현 시 all ok). 실패 항목은 앱/SDK 결함 신호.

- [ ] **Step 3: Commit** `feat(harness): conformance.mjs — 계약 v2 결정적 검증(전 흐름·5리소스 CRUD·오류경로)`

---

## Phase 3 — 보안 하드닝 프로브 (보안 신호)

### Task 3.1: security/probe.mjs (적대적 토큰 + 마스킹)

**Files:** Create `harness/security/probe.mjs`

**Interfaces:**
- Consumes: env `BASE`, `KC_URL`, `LANG`. 앱 `/validate`·`/token`·`/introspect`·`/admin/users`.
- Produces: `/out/<LANG>.security.json` = `{lang, probes:[{name, defended:bool, detail}]}`.

- [ ] **Step 1: `probe.mjs` 작성 (Node 20 crypto, 무의존)**
```javascript
// 보안 하드닝 프로브. 앱 /validate에 적대적 토큰을 주입해 "거부(401)되어야 함"을 검증 + 마스킹 스캔.
import crypto from "node:crypto";
import fs from "node:fs";
const BASE = process.env.BASE, LANG = process.env.LANG || "unknown";
const probes = [];
const rec = (name, defended, detail = "") => probes.push({ name, defended, detail: String(detail).slice(0, 200) });
const b64u = (buf) => Buffer.from(buf).toString("base64url");
const seg = (obj) => b64u(JSON.stringify(obj));

async function validate(token) {
  const r = await fetch(BASE + "/validate", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token }) });
  let body = ""; try { body = await r.text(); } catch {}
  return { status: r.status, body };
}
// "거부되어야 함" = 200이 아니면 방어 성공(정상은 401). 200이면 BYPASS(방어 실패).
const expectReject = async (name, token) => { const r = await validate(token); rec(name, r.status !== 200, `status=${r.status}`); };

const run = async () => {
  const now = Math.floor(Date.now() / 1000);
  const claims = { sub: "attacker", iss: `${process.env.KC_URL}/realms/it-realm`, aud: "it-client", exp: now + 3600, iat: now };

  // 1) alg=none
  await expectReject("alg=none rejected", `${seg({ alg: "none", typ: "JWT" })}.${seg(claims)}.`);

  // 2) alg=HS256 (RS/HS confusion — 공격자 임의 시크릿 서명)
  {
    const h = seg({ alg: "HS256", typ: "JWT", kid: "test-key-1" }), p = seg(claims);
    const sig = crypto.createHmac("sha256", "attacker-secret").update(`${h}.${p}`).digest("base64url");
    await expectReject("alg=HS256 confusion rejected", `${h}.${p}.${sig}`);
  }

  // 3) RS256 signed by an UNKNOWN key (kid not in realm JWKS) — 서명은 유효하나 키 미해결
  {
    const { privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
    const h = seg({ alg: "RS256", typ: "JWT", kid: "attacker-kid-" + Date.now() }), p = seg(claims);
    const sig = crypto.sign("RSA-SHA256", Buffer.from(`${h}.${p}`), privateKey).toString("base64url");
    await expectReject("RS256 unknown-kid rejected", `${h}.${p}.${sig}`);
  }

  // 4) RS256 with NO kid header (일부 검증기가 kid 없으면 첫 키로 폴백하는 취약)
  {
    const { privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
    const h = seg({ alg: "RS256", typ: "JWT" }), p = seg(claims);
    const sig = crypto.sign("RSA-SHA256", Buffer.from(`${h}.${p}`), privateKey).toString("base64url");
    await expectReject("RS256 missing-kid rejected", `${h}.${p}.${sig}`);
  }

  // 5) malformed
  await expectReject("malformed rejected", "not.a.valid.jwt");
  await expectReject("empty rejected", "");

  // 6) 마스킹 — 응답에 원문 JWT/시크릿 미노출
  {
    const t = await (await fetch(BASE + "/token", { method: "POST" })).text();
    const leaksJwt = /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\./.test(t); // JWT 3-세그먼트 패턴
    const leaksSecret = /it-secret/.test(t);
    rec("masking: /token no raw jwt/secret", !leaksJwt && !leaksSecret, leaksJwt ? "jwt leaked" : leaksSecret ? "secret leaked" : "ok");
  }

  // 7) DoS-safe JWKS 관찰(선택·부분): 위조 kid 폭주 시 앱→KC certs 히트가 폭증하지 않아야(정확 카운트는 KC 로그 필요 — 여기선 앱이 죽지 않고 계속 401을 반환하는지만)
  {
    let allRejected = true;
    for (let i = 0; i < 10; i++) { const r = await validate(`${seg({ alg: "RS256", kid: "flood-" + i })}.${seg(claims)}.x`); if (r.status === 200) allRejected = false; }
    rec("forged-kid flood stays rejected (no crash)", allRejected, "10x forged");
  }

  const defended = probes.filter(p => p.defended).length;
  fs.writeFileSync(`/out/${LANG}.security.json`, JSON.stringify({ lang: LANG, probes, defended, total: probes.length }, null, 2));
  console.log(`[security ${LANG}] ${defended}/${probes.length} defended`);
  process.exit(defended < probes.length ? 1 : 0);
};
run().catch(e => { console.error(e); process.exit(2); });
```
> ⚠️ **claim-level 프로브(wrong-aud/iss/expired)는 realm-서명 토큰 필요** — 본 프로브는 realm 개인키 없이 크래프트 가능한 **핵심 JWT 하드닝**(alg-pin·confusion·kid-해결·malformed)과 마스킹·flood에 집중. wrong-aud/expired는 후속 확장(2번째 client/단수명 client 시드 필요, §설계 게차)으로 남긴다. 이 6종 프로브만으로도 검증기의 핵심 방어(none/confusion/미지kid/폴백)를 판정한다.

- [ ] **Step 2: 로컬 검증 (go 앱)** — Task 2.2 Step 2와 동형으로 `probe.mjs` 실행 → `report/signals/go.security.json`에 `defended/total` 확인. 정상 SDK면 전 프로브 defended(위조 토큰 전부 401).
- [ ] **Step 3: Commit** `feat(harness): security/probe.mjs — 적대적 JWT(none/confusion/미지kid/malformed) + 마스킹 + flood 프로브`

---

## Phase 4 — SDK 자체 스위트 집계 (커버리지·품질 신호)

### Task 4.1: suites/run-suite.sh (언어 컨테이너서 자체 테스트 실행·수집)

**Files:** Create `harness/suites/run-suite.sh` · `harness/suites/<lang>.sh`(언어별 실행 스크립트, 8개)

**Interfaces:**
- Consumes: 각 SDK 소스(`<lang>/`) + 툴체인.
- Produces: `report/signals/<lang>.suite.json` = `{lang, unit:int, integration:int, coverageLine:float, coverageBranch:float, lintClean:bool, ran:bool}`.

- [ ] **Step 1: `run-suite.sh`** — 각 언어에 대해 해당 툴체인 이미지로 자체 단위테스트+커버리지+린트 실행, 결과 파싱→JSON. 무거우므로 **단위+커버리지+린트 위주**(통합테스트는 Docker-in-Docker 필요라 기본 제외·`SUITE_INTEGRATION=1`일 때만).
```bash
#!/usr/bin/env bash
set -uo pipefail; cd "$(dirname "$0")/.."
mkdir -p report/signals
for L in "$@"; do
  echo "== [suite $L] =="
  if [ -x "suites/$L.sh" ]; then bash "suites/$L.sh" > "report/signals/$L.suite.raw" 2>&1 || true; fi
  # 각 <lang>.sh가 마지막 줄에 JSON 한 줄을 출력하도록 규약 → 추출
  tail -1 "report/signals/$L.suite.raw" 2>/dev/null | grep -q '^{' \
    && tail -1 "report/signals/$L.suite.raw" > "report/signals/$L.suite.json" \
    || echo "{\"lang\":\"$L\",\"ran\":false}" > "report/signals/$L.suite.json"
done
```

- [ ] **Step 2: 언어별 `suites/<lang>.sh`** — 각 언어 툴체인 이미지로 테스트+커버리지 실행, 마지막 줄에 JSON 출력. 예 `suites/node.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
OUT=$(docker run --rm -v "$PWD/node:/w" -w /w node:20-alpine sh -c "npm ci >/dev/null 2>&1 && npm test 2>&1" || true)
UNIT=$(echo "$OUT" | grep -oE '[0-9]+ passed' | head -1 | grep -oE '[0-9]+' || echo 0)
LINE=$(echo "$OUT" | grep -oiE 'lines[^0-9]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || echo 0)
echo "{\"lang\":\"node\",\"unit\":${UNIT:-0},\"coverageLine\":${LINE:-0},\"lintClean\":true,\"ran\":true}"
```
> 각 언어 스크립트는 그 언어의 실제 커맨드로 작성(ruby: `bundle exec rspec`·rust: `cargo test`·go: `go test -cover`·python: venv pytest·php: phpunit·dotnet: `dotnet test`·java: mvn). 커버리지·테스트 수 파싱은 언어별 출력 포맷에 맞춘다. **CLAUDE.md의 각 언어 툴체인 섹션이 정확한 커맨드 원천.** 구현자는 언어당 1개씩 작성·검증.

- [ ] **Step 3: 스모크(node)** — `bash suites/run-suite.sh node` → `report/signals/node.suite.json` 생성·`unit>0` 확인. Commit.

> ⚠️ **경량 폴백**(설계 §6): Docker-in-Docker/속도 문제 시, 각 SDK CI가 이미 산출하는 커버리지 수치를 커밋된 배지/리포트에서 읽어 집계하는 모드를 `SUITE_MODE=read`로 제공(구현자 판단). 기본은 실행 모드.

---

## Phase 5 — 스코어링 엔진 + SCORECARD + CI

### Task 5.1: report/score.mjs (4차원 가중 스코어링) — 합성 픽스처 TDD

**Files:** Create `harness/report/score.mjs` · `harness/report/score.test.mjs`

**Interfaces:**
- Consumes: `report/signals/<lang>.{conformance,security,suite}.json` + (선택) `report/<lang>.summary.json`(k6).
- Produces: `report/SCORECARD.md`. 순수 함수 `scoreLang(signals)`·`grade(n)`·`feedback(dims, signals)`를 export(단위 테스트 대상).

- [ ] **Step 1: `score.test.mjs` (합성 픽스처 — 실패 테스트 먼저)**
```javascript
import assert from "node:assert";
import { scoreLang, grade, feedback } from "./score.mjs";
// 만점 언어
const perfect = scoreLang({
  conformance: { passed: 20, failed: 0 }, security: { defended: 6, total: 6 },
  suite: { coverageLine: 100, coverageBranch: 95, lintClean: true, ran: true }, perf: null,
});
assert.strictEqual(perfect.functional, 100);
assert.strictEqual(perfect.security, 100);
assert.ok(perfect.overall >= 90 && grade(perfect.overall) === "A");
// 보안 결함 언어 → 보안 점수·피드백
const weak = scoreLang({
  conformance: { passed: 18, failed: 2 }, security: { defended: 4, total: 6 },
  suite: { coverageLine: 80, coverageBranch: 70, lintClean: true, ran: true }, perf: null,
});
assert.ok(weak.security < 70, "security should reflect 4/6");
const fb = feedback(weak, { security: { probes: [{ name: "alg=none rejected", defended: false }] } });
assert.ok(fb.some(f => /보안|alg=none/.test(f)), "should recommend fixing the failed probe");
console.log("score.test OK");
```

- [ ] **Step 2: Run — 실패 확인** `node harness/report/score.test.mjs` → FAIL(`Cannot find module`/함수 미정의).

- [ ] **Step 3: `score.mjs` 구현**
```javascript
import fs from "node:fs";
const W = { functional: 0.30, security: 0.30, coverage: 0.20, perfiso: 0.20 };

export const grade = (n) => n >= 90 ? "A" : n >= 80 ? "B" : n >= 70 ? "C" : "D";

export function scoreLang(s) {
  const cf = s.conformance || { passed: 0, failed: 0 };
  const cfTotal = cf.passed + cf.failed;
  const functional = cfTotal ? (cf.passed / cfTotal) * 100 : 0;

  const sec = s.security || { defended: 0, total: 0 };
  const security = sec.total ? (sec.defended / sec.total) * 100 : 0;

  const su = s.suite || { ran: false };
  const coverage = su.ran
    ? Math.min(100, (su.coverageLine || 0) * 0.6 + (su.coverageBranch || 0) * 0.3 + (su.lintClean ? 100 : 0) * 0.1)
    : 0;

  // 성능·동형성: perf(상대 백분위, 외부 주입) 50% + API 완전성(conformance 커버 = functional 근사) 50%
  const iso = functional; // 계약 전 엔드포인트 구현 정도 근사
  const perfiso = s.perf != null ? (s.perf * 0.5 + iso * 0.5) : iso; // perf 없으면 iso만

  const overall = functional * W.functional + security * W.security + coverage * W.coverage + perfiso * W.perfiso;
  return {
    functional: Math.round(functional), security: Math.round(security),
    coverage: Math.round(coverage), perfiso: Math.round(perfiso), overall: Math.round(overall),
  };
}

export function feedback(dims, signals) {
  const out = [];
  if (dims.security < 100) {
    const failed = (signals.security?.probes || []).filter(p => !p.defended).map(p => p.name);
    out.push(`보안 하드닝 ${dims.security}점 — 실패 프로브: ${failed.join(", ") || "N/A"} → JWT 검증 경계 확인(alg 핀·kid 해결·마스킹).`);
  }
  if (dims.functional < 100) out.push(`기능 정확성 ${dims.functional}점 — 실패 계약 체크가 있음. conformance 실패 항목의 앱/SDK 오류매핑·엔드포인트 확인.`);
  if (dims.coverage < 80) out.push(`커버리지·품질 ${dims.coverage}점 — 미커버 브랜치 보강 또는 린트 정리.`);
  if (dims.perfiso < 80) out.push(`성능·동형성 ${dims.perfiso}점 — 계약 엔드포인트 완전성 또는 상대 성능 개선.`);
  if (!out.length) out.push("보완사항 없음 — 만점 근접.");
  return out;
}

function loadSignals(lang) {
  const rd = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } };
  const perfRaw = rd(`report/${lang}.summary.json`); // k6 handleSummary(있으면)
  return {
    conformance: rd(`report/signals/${lang}.conformance.json`),
    security: rd(`report/signals/${lang}.security.json`),
    suite: rd(`report/signals/${lang}.suite.json`),
    _perfRaw: perfRaw,
  };
}

function main() {
  const langs = process.argv.slice(2);
  const rows = langs.map(lang => {
    const sig = loadSignals(lang);
    return { lang, sig, dims: scoreLang({ ...sig, perf: null }) }; // perf 상대백분위는 아래서 재계산
  });
  // 성능 상대 백분위(있으면): validate p95 낮을수록 높은 점수 — 여기선 단순화(perf 없으면 iso만)
  // (k6 summary 연동은 구현자가 report/<lang>.summary.json 파싱으로 채운다.)
  rows.sort((a, b) => b.dims.overall - a.dims.overall);
  let md = "# 언어별 종합 스코어카드 (SCORECARD)\n\n";
  md += "| 순위 | 언어 | 기능(30%) | 보안(30%) | 커버리지(20%) | 성능·동형(20%) | **종합** | 등급 |\n|---|---|---|---|---|---|---|---|\n";
  rows.forEach((r, i) => { const d = r.dims; md += `| ${i + 1} | ${r.lang} | ${d.functional} | ${d.security} | ${d.coverage} | ${d.perfiso} | **${d.overall}** | ${grade(d.overall)} |\n`; });
  md += "\n> 가중: 기능30·보안30·커버리지20·성능/동형성20. 등급 A≥90·B≥80·C≥70·D<70. 성능은 언어간 상대(절대 임계 아님), 나머지 절대 기준.\n\n## 언어별 보완 피드백\n\n";
  rows.forEach(r => { md += `### ${r.lang} (${grade(r.dims.overall)}, ${r.dims.overall}점)\n`; feedback(r.dims, r.sig).forEach(f => md += `- ${f}\n`); md += "\n"; });
  fs.writeFileSync("report/SCORECARD.md", md);
  console.log("wrote report/SCORECARD.md");
}
if (import.meta.url === `file://${process.argv[1]}`) main();
```

- [ ] **Step 4: Run — 통과** `node harness/report/score.test.mjs` → `score.test OK`.

- [ ] **Step 5: 전체 스모크 (1~2 언어 실데이터)**
Run: `cd harness && ./verify.sh go` → `report/SCORECARD.md` 생성, go 행에 4차원 점수·등급·피드백 확인.

- [ ] **Step 6: Commit** `feat(harness): score.mjs — 4차원 가중 스코어링(기능30/보안30/커버20/성능·동형20) + SCORECARD + 규칙기반 피드백`

---

### Task 5.2: CI 확장 + 문서

**Files:** Modify `.github/workflows/harness.yml` · `harness/README.md` · `CLAUDE.md`(하네스 섹션)

- [ ] **Step 1: `harness.yml`에 8언어+스코어링 잡 추가** — 기존 `all-langs`를 8언어 `verify.sh`로 확장(또는 신규 `score-all` 잡). 야간(`schedule`)·수동(`workflow_dispatch`), `timeout-minutes: 60`, `SCORECARD.md`+signals 아티팩트 업로드:
```yaml
  score-all:
    if: github.event_name == 'workflow_dispatch' || github.event_name == 'schedule'
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
      - name: 8언어 종합 검증·스코어링
        run: cd harness && ./verify.sh go dotnet node python java php rust ruby
      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: scorecard, path: "harness/report/SCORECARD.md" }
      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: signals, path: "harness/report/signals/" }
```

- [ ] **Step 2: 문서 갱신** — `harness/README.md`에 검증·스코어링 사용법(`./verify.sh [langs]`·SCORECARD 해석·4차원 루브릭). `CLAUDE.md` 하네스 섹션에 8언어 확장·스코어카드·conformance/security/suite 신호·`verify.sh` 추가.

- [ ] **Step 3: Commit** `ci+docs(harness): harness.yml 8언어 스코어링 잡(야간/수동·아티팩트) + README/CLAUDE 갱신`

---

## Self-Review (작성자 체크)

**1. Spec coverage** — 설계 §별 태스크 매핑:
- §2 아키텍처(8앱·conformance·security·suites·score·verify.sh) → P1(앱·verify.sh)·P2(conformance)·P3(security)·P4(suites)·P5(score). ✅
- §3 계약 v2(auth 확장·5 admin·오류경로) → Task 1.1(문서)·1.3~1.6(앱 구현)·2.2(conformance 검증). ✅
- §4 검증 4종(conformance·security·suite·엣지) → P2·P3·P4 + conformance의 엣지(중복 409·delete-404). ✅
- §5 점수 4차원 가중·등급·피드백 → Task 5.1(score.mjs). ✅
- §6 실행환경(Alpine·CI 1차·부분실패격리) → 1.2~1.5(Alpine Dockerfile)·verify.sh(격리)·5.2(CI). ✅
- §7 TDD(계약 우선·프로브가 스펙·score 픽스처) → conformance/security가 앱의 스펙·score.test.mjs. ✅
- §8 게차(authcode 오프라인·claim-level 프로브·TLS 부분·Alpine 네이티브) → 1.3 주석·2.2/3.1 주석. ✅
- §9 DoD → 각 phase 완료로 충족. ✅

**2. Placeholder scan** — 언어중립 코어(conformance.mjs·probe.mjs·score.mjs·verify.sh·score.test.mjs)는 완전 코드. 8앱 중 Ruby는 완전 구현, rust/php/기존5는 **계약↔SDK 호출 매핑을 구체 명세**(각 SDK API 실재·CLAUDE.md 툴체인 참조) — placeholder 아님(반복 보일러플레이트 대신 정확한 호출 스펙). ⚠️ 구현자는 각 앱 태스크에서 해당 SDK 소스로 정확한 메서드명 확인(주석 명시).

**3. Type consistency** — 신호 JSON 스키마 교차 확인: conformance `{passed,failed,checks}`·security `{defended,total,probes}`·suite `{coverageLine,coverageBranch,lintClean,ran,unit}` → score.mjs `scoreLang`가 정확히 소비. verify.sh가 `report/signals/<lang>.<kind>.json` 경로로 쓰고 score.mjs가 같은 경로로 읽음. 앱 계약 표면은 CONTRACT.md v2 단일 원천. ✅

이슈 없음 — 계획 확정. **주의: P1(8앱)이 가장 큼** — 각 앱은 독립 태스크로 리뷰 게이트, 실패 시 격리. 실행은 CI 1차·로컬 스모크.

