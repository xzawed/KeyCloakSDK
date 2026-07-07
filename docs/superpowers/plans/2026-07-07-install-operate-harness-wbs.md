# 설치·동작 검증 하네스 (Install-&-Operate Harness) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 실배포 없이 Docker에서 8개 언어 SDK를 "게시된 패키지처럼" 로컬 레지스트리에서 설치하고 실 Keycloak에 대해 동작(quickstart 스모크 + conformance + security)까지 검증하는 하네스를 `harness/install/`에 구축한다.

**Architecture:** 언어별 4단계 파이프라인(Publish→Install→Operate→Report). 기존 `harness/apps/<lang>` 앱 코드·`conformance.mjs`·`security/probe.mjs`·Keycloak realm을 재사용하고, **의존성 해석 소스만** 소스경로→로컬 레지스트리로 바꾼다. 한 언어의 실패는 격리하고 나머지는 계속(기존 `verify.sh` 패턴). node를 참조 구현으로 먼저 완성한 뒤 7개 언어가 그 패턴을 복제.

**Tech Stack:** Docker/compose, Alpine/musl 컨테이너, 언어별 로컬 레지스트리(Verdaccio·pypiserver·file-GOPROXY·BaGetter·nginx-정적-.m2·rubygems-generate_index·Satis·cargo-local-registry), Node로 리포트 집계(기존 score.mjs 관용).

## Global Constraints

- **정확한 명령의 권위 소스**: [docs/superpowers/specs/2026-07-07-install-recipes-research.md](../specs/2026-07-07-install-recipes-research.md)(리서치 부록). 각 언어 태스크는 이 부록의 해당 절을 진실로 삼는다. 설계: [install-operate-harness-design.md](../specs/2026-07-07-install-operate-harness-design.md).
- **전 컨테이너 Alpine/musl 베이스**(Windows Docker Desktop glibc-DNS 게차 회피). 공유 compose에 하드코딩 IP/`extra_hosts` 금지.
- **최대 재사용·단일 변수**: 앱 소스(`harness/apps/<lang>`)·`conformance.mjs`·`security/probe.mjs`·`harness/keycloak/harness-realm.json`은 변경 없이 재사용. 바꾸는 것은 의존성 해석 소스뿐.
- **부분실패 격리**: 한 언어의 build/publish/install/boot 실패는 `report/signals/<lang>.install.json`의 해당 필드 false + `error`로 격리, 나머지 언어 계속. verify.sh 미러.
- **소비자 설치 명령은 실제와 동일**, 소스 URL만 로컬 override(§2 동형성).
- **버전 좌표 전부 0.1.0**(go는 태그 `go/v0.1.0`, java는 `versions:set`로 SNAPSHOT→0.1.0).
- **신호 스키마(고정)**: `{ lang, artifactBuilt, published, installed, quickstartOk, appBoot, conformance:{passed,failed}, security:{defended,total}, error? }`(bool 필드·error는 optional string).
- **Docker 빌드 실행 주체**: 구현자(subagent)는 스크립트·Dockerfile·compose·매니페스트를 **작성**하고, 느린 Docker 빌드·스모크·커밋은 **컨트롤러가 이어받는다**(기존 하네스 교훈 — 구현자가 장시간 빌드 대기 중 미커밋 반환하는 패턴 회피).
- **로컬 검증 범위**: Windows 로컬은 가벼운 Alpine 순수언어 플로(node/go/python)를 spot-check, **8개 전체 install-all은 CI(야간/수동) 1차**(기존 score-all 동형). 무거운 언어(java/rust/ruby/php/dotnet)는 CI 첫 실행 대상.
- **커밋**: 각 태스크 끝. 브랜치 `feature/install-operate-harness`. 메시지 `feat(install-harness):`/`chore(install-harness):`/`ci(install-harness):`.

---

## File Structure

```
harness/install/
├─ README.md                     # T3.1: 목적·실행법·리포트 해석
├─ install-verify.sh             # T0.2: 오케스트레이터(언어 인자·부분실패 격리)
├─ compose.install.yml           # T0.2: Keycloak + 공유 network(+ 언어별 레지스트리는 각 언어 태스크가 append/override)
├─ lib.sh                        # T0.2: 공통 셸 헬퍼(로그·신호 emit·wait-healthy)
├─ registries/                   # 언어별 레지스트리 설정(verdaccio.yaml·nuget.config·satis.json·.cargo/config.toml 등)
├─ publish/<lang>.sh             # 각 언어: 산출물 빌드 → 로컬 레지스트리 게시
├─ consume/<lang>.Dockerfile     # 각 언어: 소스없는 클린 설치(quickstart + 앱 재빌드)
├─ quickstart/
│  ├─ dotnet/                    # T2.3: 소형 콘솔 quickstart(예제 부재 보충)
│  └─ go/                        # T2.2: 러너블 main.go(example_test.go는 러너블 아님)
└─ report/
   ├─ install-matrix.mjs         # T0.1: signals/*.install.json → INSTALL-MATRIX.md
   ├─ install-matrix.test.mjs    # T0.1: 합성 픽스처 TDD
   ├─ .gitignore                 # signals/·INSTALL-MATRIX.md(생성물)
   └─ signals/<lang>.install.json
```

---

## Task 0.1: 신호 스키마 + 리포트 집계기 (TDD)

**Files:**
- Create: `harness/install/report/install-matrix.mjs`
- Create: `harness/install/report/install-matrix.test.mjs`
- Create: `harness/install/report/.gitignore`

**Interfaces:**
- Produces: `buildMatrix(signals: Signal[]): string`(Markdown 표), `main()`(signals/ 디렉터리 읽어 INSTALL-MATRIX.md 쓰기). Signal 스키마는 Global Constraints 참조.
- Consumes: 없음(node 내장만, score.mjs 관용 — 외부 의존성 없음).

- [ ] **Step 1: 실패 테스트 작성** — `install-matrix.test.mjs`에 합성 신호 3종(all-green go, 부분실패 rust[installed:false,error], 결측 필드) 픽스처로 `buildMatrix`가 (a) 언어당 1행, (b) 각 단계 ✓/✗, (c) conformance `26/26`·security `9/9` 렌더, (d) error 있는 행에 사유 표기, (e) 결측 신호 무크래시를 assert. score.test.mjs의 `pathToFileURL` 엔트리포인트 가드 관용을 따른다.

```js
// install-matrix.test.mjs (요지)
import { buildMatrix } from "./install-matrix.mjs";
import assert from "node:assert";
const md = buildMatrix([
  { lang: "go", artifactBuilt: true, published: true, installed: true, quickstartOk: true, appBoot: true, conformance: { passed: 26, failed: 0 }, security: { defended: 9, total: 9 } },
  { lang: "rust", artifactBuilt: true, published: true, installed: false, quickstartOk: false, appBoot: false, conformance: { passed: 0, failed: 0 }, security: { defended: 0, total: 0 }, error: "cargo build --offline: unresolved source" },
]);
assert.match(md, /\|\s*go\s*\|.*26\/26.*9\/9/);
assert.match(md, /\|\s*rust\s*\|.*✗.*unresolved source/);
console.log("install-matrix.test OK");
```

- [ ] **Step 2: 테스트 실패 확인** — Run: `node harness/install/report/install-matrix.test.mjs` → FAIL(`buildMatrix` 미정의).
- [ ] **Step 3: 최소 구현** — `install-matrix.mjs`에 `buildMatrix(signals)`(각 신호를 행으로: bool→✓/✗, conformance/security→`p/n`, error→마지막 열) + `main()`(`report/signals/*.install.json` glob read → `INSTALL-MATRIX.md` write, 결측/파싱오류는 스킵+경고). 엔트리포인트는 `if (import.meta.url === pathToFileURL(process.argv[1]).href) main()`.
- [ ] **Step 4: 테스트 통과 확인** — Run: `node harness/install/report/install-matrix.test.mjs` → `install-matrix.test OK`.
- [ ] **Step 5: .gitignore** — `harness/install/report/.gitignore`에 `signals/`·`INSTALL-MATRIX.md`(생성물, 기존 report/.gitignore 관용).
- [ ] **Step 6: 커밋** — `git add harness/install/report && git commit -m "feat(install-harness): 신호 스키마 + INSTALL-MATRIX 집계기(TDD)"`.

---

## Task 0.2: 오케스트레이터 + 공유 compose

**Files:**
- Create: `harness/install/install-verify.sh`
- Create: `harness/install/lib.sh`
- Create: `harness/install/compose.install.yml`

**Interfaces:**
- Consumes: `report/install-matrix.mjs`(T0.1).
- Produces: `./install-verify.sh <lang...>`가 언어별로 `publish/<lang>.sh`→`consume/<lang>.Dockerfile` 빌드·실행→conformance/security→`emit_signal`을 호출하고, 전 언어 후 `node report/install-matrix.mjs`로 매트릭스 생성. `lib.sh`: `log()`·`emit_signal(lang, field=val…)`·`wait_healthy(url)`·`fail_lang(lang, stage, msg)`(신호에 error 기록 후 계속).

- [ ] **Step 1: `lib.sh` 작성** — `log`(타임스탬프 stderr)·`emit_signal`(jq 없이 node로 JSON 병합·`report/signals/<lang>.install.json` 갱신)·`wait_healthy`(curl 폴링 타임아웃)·`fail_lang`(신호 error 세팅 + `return 1`). 기존 `harness/verify.sh`의 셸 관용 참고(재구현, 소싱 아님).
- [ ] **Step 2: `compose.install.yml` 작성** — Keycloak 26.6(기존 `harness/keycloak/harness-realm.json` import·기존 compose와 동일 설정) + 공유 network `install-net`. 언어별 레지스트리 서비스는 각 언어 태스크가 이 파일에 append 하거나 `compose.<lang>.yml` override로 둔다(태스크에서 결정). Keycloak만으로 `docker compose -f compose.install.yml config` 유효.
- [ ] **Step 3: `install-verify.sh` 작성** — 인자 파싱(언어 목록)·Keycloak 기동·`wait_healthy`·언어 루프{ `publish/<lang>.sh`(실패→`fail_lang`·continue) → `consume/<lang>.Dockerfile` build+run(실패→`fail_lang`·continue) → 컨테이너 내부 네트워크에서 `conformance.mjs`·`probe.mjs` 실행(기존 러너 재사용, BASE=설치된-패키지 앱) → `emit_signal` } · 루프 후 `node report/install-matrix.mjs` · 항상 exit 0(신호가 결과 담체, verify.sh 관용). `set -uo pipefail`(언어 격리 위해 `-e` 없이 명시 처리).
- [ ] **Step 4: 스텁 스모크** — 임시 스텁 언어(`publish/_stub.sh`가 signal all-true emit)로 `./install-verify.sh _stub` 실행 → `INSTALL-MATRIX.md`에 stub 행 생성·exit 0 확인. (스텁은 커밋 전 삭제.)
- [ ] **Step 5: compose config 검증** — Run: `docker compose -f harness/install/compose.install.yml config >/dev/null && echo OK`.
- [ ] **Step 6: 커밋** — `git add harness/install/install-verify.sh harness/install/lib.sh harness/install/compose.install.yml && git commit -m "chore(install-harness): 오케스트레이터 + Keycloak compose + 공유 헬퍼"`.

---

## Task 1.1: node 참조 구현 (Verdaccio, end-to-end)

> 참조 구현 — 이후 7개 언어가 이 패턴(레지스트리 서비스 + publish 스크립트 + consume Dockerfile + 오케스트레이터 배선 + 신호)을 복제한다. 부록 §node.

**Files:**
- Create: `harness/install/registries/verdaccio.yaml`
- Create: `harness/install/publish/node.sh`
- Create: `harness/install/consume/node.Dockerfile`
- Modify: `harness/install/compose.install.yml`(verdaccio 서비스 추가)

**Interfaces:**
- Consumes: `harness/apps/node`(앱 소스·변경 없음), `harness/node`(SDK 소스), `conformance.mjs`·`probe.mjs`.
- Produces: node 신호 all-green.

- [ ] **Step 1: verdaccio.yaml** — 부록 §node의 config(`packages.'@*/*'`·`'**'`에 `publish: $all`·`proxy: npmjs`·uplink npmjs).
- [ ] **Step 2: compose에 verdaccio 서비스** — `verdaccio/verdaccio:6.7.4`·`install-net`·config 볼륨(ro)·healthcheck(`/-/ping`).
- [ ] **Step 3: publish/node.sh** — Alpine node 컨테이너에서 `npm ci && npm run build && npm pack`(⚠️ build 먼저) → tgz를 verdaccio에 `npm publish <tgz> --registry http://verdaccio:4873 --access public`(더미 `_authToken`). 부록 §node 명령 그대로. 멱등성: 재실행 시 409면 unpublish --force 후 재게시(또는 스킵).
- [ ] **Step 4: consume/node.Dockerfile** — 소스 트리 없는 `node:20-alpine`에서 `npm install @xzawed/keycloak-sdk@0.1.0 --registry http://verdaccio:4873` → (b1) 앱과 함께 `examples/quickstart.ts` 상당을 설치된 패키지로 실행(설치 스모크) → (b2) `harness/apps/node/server.js`를 설치된 패키지 의존으로 부팅(package.json의 `file:*.tgz`를 `@xzawed/keycloak-sdk@0.1.0` 레지스트리 설치로 교체). APP_PORT 8090.
- [ ] **Step 5: 오케스트레이터 배선** — `install-verify.sh`의 언어 케이스에 node 경로(publish→consume build→run→conformance/security→emit). (컨트롤러가 실제 빌드/스모크 수행.)
- [ ] **Step 6: end-to-end 검증(컨트롤러)** — Run: `cd harness/install && ./install-verify.sh node` → `report/signals/node.install.json`이 artifactBuilt/published/installed/quickstartOk/appBoot=true·conformance 26/26·security 9/9. `INSTALL-MATRIX.md`에 node 행 green.
- [ ] **Step 7: 커밋** — `git add harness/install && git commit -m "feat(install-harness): node 참조 구현 — Verdaccio 게시+클린설치+동작검증 end-to-end"`.

---

## Task 2.1: python (pypiserver)

**Files:** Create `harness/install/publish/python.sh`, `harness/install/consume/python.Dockerfile`; Modify `compose.install.yml`(pypiserver 서비스). 부록 §python.

**Interfaces:** Consumes `harness/apps/python`·`harness/python`. Produces python 신호. Node(T1.1) 패턴 복제.

- [ ] **Step 1: compose에 pypiserver** — `pypiserver/pypiserver:latest`·`install-net`·`run -a . -P . /data/packages`·볼륨.
- [ ] **Step 2: publish/python.sh** — 정상 DNS Alpine 컨테이너에서 `python -m build`(python/) → `TWINE_USERNAME=x TWINE_PASSWORD=x twine upload --repository-url http://pypiserver:8080/ python/dist/*`. 부록 §python.
- [ ] **Step 3: consume/python.Dockerfile** — `python:3.12-alpine`에서 `pip install "keycloak-sdk==0.1.0"`(env `PIP_EXTRA_INDEX_URL=http://pypiserver:8080/simple/`·`PIP_TRUSTED_HOST=pypiserver`[포트 없음]) → quickstart(`examples/quickstart.py`) 스모크 → `harness/apps/python/main.py`(FastAPI) 부팅(requirements.txt에서 SDK를 설치된 패키지로). APP_PORT 8090.
- [ ] **Step 4: 오케스트레이터 배선** — python 케이스 추가.
- [ ] **Step 5: 검증(컨트롤러)** — `./install-verify.sh python` → 신호 green·conf 26/sec 9.
- [ ] **Step 6: 커밋** — `feat(install-harness): python(pypiserver) 설치+동작 검증`.

---

## Task 2.2: go (file GOPROXY, + 러너블 quickstart)

**Files:** Create `harness/install/publish/go.sh`, `harness/install/consume/go.Dockerfile`, `harness/install/quickstart/go/main.go`. 부록 §go.

**Interfaces:** Consumes `harness/apps/go`·`go/`(모듈). Produces go 신호.

- [ ] **Step 1: quickstart/go/main.go** — SDK를 설치된 모듈로 소비하는 러너블 main(client-credentials→validate→admin user 생성 등 — `example_test.go`를 러너블화). `go get github.com/xzawed/KeyCloakSDK/go@v0.1.0` 후 빌드·실행.
- [ ] **Step 2: publish/go.sh** — `golang:1.26-alpine`에서 격리 HOME에 `git config --global url."file:///src".insteadOf …` → `git tag go/v0.1.0`(리포 루트) → `GOSUMDB=off GOPROXY=direct go mod download -x …/go@v0.1.0` → `cp -R $GOMODCACHE/cache/download/. /proxy/`. 부록 §go. (레지스트리 서비스 아님 — /proxy 디렉터리 볼륨.)
- [ ] **Step 3: consume/go.Dockerfile** — `golang:1.26-alpine`에서 `/proxy` 마운트 + `GOPROXY='file:///proxy,https://proxy.golang.org,direct' GOSUMDB=off go get …/go@v0.1.0` → quickstart 스모크 → `harness/apps/go/main.go` 부팅(go.mod의 `replace => /sdk`를 `require …@v0.1.0` + 로컬 GOPROXY로 교체). APP_PORT 8090.
- [ ] **Step 4: 오케스트레이터 배선** — go 케이스(레지스트리 서비스 없이 /proxy 준비 단계).
- [ ] **Step 5: 검증(컨트롤러)** — `./install-verify.sh go` → 신호 green.
- [ ] **Step 6: 커밋** — `feat(install-harness): go(file GOPROXY) 설치+동작 검증 + 러너블 quickstart`.

---

## Task 2.3: dotnet (BaGetter, + 콘솔 quickstart)

**Files:** Create `harness/install/publish/dotnet.sh`, `harness/install/consume/dotnet.Dockerfile`, `harness/install/registries/nuget.config`, `harness/install/quickstart/dotnet/`(콘솔 프로젝트); Modify `compose.install.yml`(bagetter). 부록 §dotnet.

**Interfaces:** Consumes `harness/apps/dotnet`·`dotnet/src`. Produces dotnet 신호.

- [ ] **Step 1: quickstart/dotnet 콘솔 프로젝트** — 설치된 `Xzawed.Keycloak.Sdk` 소비하는 소형 `Program.cs`(예제 부재 보충 — client-credentials→validate→admin).
- [ ] **Step 2: compose에 bagetter** — `bagetter/bagetter:latest`·`install-net`·미러링 off·env(ApiKey·FileSystem·Sqlite).
- [ ] **Step 3: nuget.config** — 부록 §dotnet(nuget.org + local 소스 추가·`packageSourceMapping`으로 Xzawed.Keycloak.Sdk만 local·`allowInsecureConnections=true`).
- [ ] **Step 4: publish/dotnet.sh** — `mcr.microsoft.com/dotnet/sdk:8.0-alpine`에서 `dotnet pack … -c Release -o artifacts -p:Version=0.1.0` → `dotnet nuget push artifacts/*.nupkg --source http://bagetter:8080/v3/index.json --api-key LOCALKEY --skip-duplicate`.
- [ ] **Step 5: consume/dotnet.Dockerfile** — sdk:8.0-alpine에서 nuget.config 배치 후 `dotnet add package Xzawed.Keycloak.Sdk --version 0.1.0`(⚠️ `-s` 단일소스 금지) → quickstart 스모크 → `harness/apps/dotnet`(ASP.NET) 부팅(`<ProjectReference>`를 `<PackageReference>`로 교체). APP_PORT 8090.
- [ ] **Step 6: 오케스트레이터 배선 + 검증(컨트롤러)** — `./install-verify.sh dotnet` → 신호 green.
- [ ] **Step 7: 커밋** — `feat(install-harness): dotnet(BaGetter) 설치+동작 검증 + 콘솔 quickstart`.

---

## Task 2.4: java (nginx 정적 staged .m2)

**Files:** Create `harness/install/publish/java.sh`, `harness/install/consume/java.Dockerfile`, `harness/install/registries/settings.xml`; Modify `compose.install.yml`(mvn-repo nginx). 부록 §java.

**Interfaces:** Consumes `harness/apps/java`·`java/`(reactor). Produces java 신호.

- [ ] **Step 1: publish/java.sh** — `maven:3.9-eclipse-temurin-21-alpine`에서 `versions:set -DnewVersion=0.1.0` → `mvn -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true -Dmaven.repo.local=/work/staging-m2 install`(⚠️ install — deploy 아님). staging-m2에 parent+BOM+4 jar+sources+javadoc.
- [ ] **Step 2: compose에 mvn-repo** — `nginx:1.27-alpine`가 staging-m2 볼륨을 `http://mvn-repo/`로 서빙.
- [ ] **Step 3: settings.xml** — 부록 §java(`<repository> http://mvn-repo/` 1개 추가·Central 유지·`<mirror>*` 금지).
- [ ] **Step 4: consume/java.Dockerfile** — maven:3.9-…-21-alpine에서 settings.xml로 `mvn -s settings.xml dependency:get -Dartifact=io.github.xzawed:keycloak-sdk:0.1.0`(설치 확인) → quickstart(`keycloak-sdk-examples` 상당) 스모크 → `harness/apps/java`(Spring Boot) 부팅(pom의 SDK 의존을 reactor 아닌 `io.github.xzawed:keycloak-sdk:0.1.0`+BOM으로, settings.xml 주입). APP_PORT 8090.
- [ ] **Step 5: 오케스트레이터 배선 + 검증(컨트롤러)** — `./install-verify.sh java` → 신호 green(⚠️ checksum WARNING 무해).
- [ ] **Step 6: 커밋** — `feat(install-harness): java(정적 .m2 nginx) 설치+동작 검증`.

---

## Task 2.5: ruby (rubygems-generate_index 정적 repo)

**Files:** Create `harness/install/publish/ruby.sh`, `harness/install/consume/ruby.Dockerfile`; Modify `compose.install.yml`(정적 gem 서버). 부록 §ruby.

**Interfaces:** Consumes `harness/apps/ruby`·`ruby/`(gem). Produces ruby 신호.

- [ ] **Step 1: publish/ruby.sh** — `ruby:3.4-alpine`에서 `gem build keycloak-sdk.gemspec`(⚠️ LICENSE·README.md가 ruby/에 필요) → `cp *.gem /repo/gems/` → `gem install rubygems-generate_index && gem generate_index --directory /repo`.
- [ ] **Step 2: compose에 gem 서버** — `ruby:3.4-alpine`에 `gem install webrick && ruby -run -e httpd /repo -p 8808 --bind-address=0.0.0.0`(또는 nginx:alpine)로 **repo 루트** 서빙.
- [ ] **Step 3: consume/ruby.Dockerfile** — `ruby:3.4-alpine`에서 `gem install keycloak-sdk --version 0.1.0 --source http://gemserver:8808` → quickstart(`examples/quickstart.rb`, `require "keycloak_sdk"`) 스모크 → `harness/apps/ruby/app.rb`(Sinatra) 부팅(Gemfile의 `path: /src/ruby`를 `gem "keycloak-sdk", "0.1.0", source: "http://gemserver:8808"`로 교체). APP_PORT 8090.
- [ ] **Step 4: 오케스트레이터 배선 + 검증(컨트롤러)** — `./install-verify.sh ruby` → 신호 green.
- [ ] **Step 5: 커밋** — `feat(install-harness): ruby(정적 gem repo) 설치+동작 검증`.

---

## Task 2.6: php (Satis)

**Files:** Create `harness/install/publish/php.sh`, `harness/install/consume/php.Dockerfile`, `harness/install/registries/satis.json`; Modify `compose.install.yml`(satis-web nginx). 부록 §php.

**Interfaces:** Consumes `harness/apps/php`·`php/`. Produces php 신호.

- [ ] **Step 1: satis.json** — 부록 §php(`repositories:[{type:vcs,url:/work/php-src}]`·`require:{xzawed/keycloak-sdk:*}`·`require-dependencies:false`·`archive:{format:zip}`·homepage=`http://satis-web`).
- [ ] **Step 2: publish/php.sh** — `php/`를 subtree-split(rsync --exclude vendor/.git → git init/commit/`git tag v0.1.0`) → `composer/satis:latest build satis.json output` → output/을 준비. 부록 §php.
- [ ] **Step 3: compose에 satis-web** — `nginx:alpine`가 satis output/을 `http://satis-web`로 서빙.
- [ ] **Step 4: consume/php.Dockerfile** — `composer:2`(Alpine)에서 `composer config repositories.local composer http://satis-web` + `composer config secure-http false` + `composer require xzawed/keycloak-sdk:^0.1` → quickstart(`examples/quickstart.php`) 스모크 → `harness/apps/php`(Slim) 부팅(composer.json의 `type:path` repo를 satis-web composer repo로 교체·런타임 확장 `apk add php83-openssl php83-curl php83-mbstring php83-sodium`). APP_PORT 8090.
- [ ] **Step 5: 오케스트레이터 배선 + 검증(컨트롤러)** — `./install-verify.sh php` → 신호 green.
- [ ] **Step 6: 커밋** — `feat(install-harness): php(Satis) 설치+동작 검증`.

---

## Task 2.7: rust (cargo-local-registry)

**Files:** Create `harness/install/publish/rust.sh`, `harness/install/consume/rust.Dockerfile`, `harness/install/registries/cargo-config.toml`. 부록 §rust(confidence medium — 게차 주의).

**Interfaces:** Consumes `harness/apps/rust`·`rust/`. Produces rust 신호.

- [ ] **Step 1: publish/rust.sh** — `rust:1.88-alpine`(툴 `apk add build-base openssl-dev openssl-libs-static perl cmake pkgconfig git`·`OPENSSL_STATIC=1`)에서 `cargo install cargo-local-registry --version 0.2.8 --locked`(⚠️ 0.2.12는 내부 cargo crate 0.95.0→rustc 1.92 요구로 rustc 1.88 비호환 — 0.2.8로 고정, 실측) → `cargo package --locked`(rust/) → `cargo generate-lockfile` → `cargo local-registry sync --no-delete Cargo.lock /opt/local-registry` → keycloak-sdk **수동 주입**(.crate 복사 + `index/ke/yc/keycloak-sdk` v2 JSON 라인·cksum=sha256, 부록 §rust의 deps 배열 그대로).
- [ ] **Step 2: registries/cargo-config.toml** — `[source.crates-io] replace-with="local"` + `[source.local] local-registry="/opt/local-registry"`.
- [ ] **Step 3: consume/rust.Dockerfile** — `rust:1.88-alpine`에서 /opt/local-registry + cargo-config.toml 배치 → Cargo.toml에 `keycloak-sdk = "0.1.0"` 직접 기입(⚠️ `cargo add`는 #10926로 실패 가능) → `cargo build --offline` → quickstart(`examples/quickstart.rs`) 스모크 → `harness/apps/rust`(axum) 부팅(Cargo.toml의 `path=/src/rust`를 `keycloak-sdk="0.1.0"`+source replace로 교체). APP_PORT 8090.
- [ ] **Step 4: 오케스트레이터 배선 + 검증(컨트롤러)** — `./install-verify.sh rust` → 신호 green(수동 index 라인·cksum 정합 주의).
- [ ] **Step 5: 커밋** — `feat(install-harness): rust(cargo-local-registry) 설치+동작 검증`.

---

## Task 3.1: CI + README

**Files:** Modify `.github/workflows/harness.yml`(install-all 잡); Create `harness/install/README.md`.

**Interfaces:** 기존 `mvp-go`/`all-langs`/`score-all` 잡 불변. install-all 추가.

- [ ] **Step 1: install-all 잡** — `workflow_dispatch` + `schedule`(야간·기존 03:00 UTC와 분리된 시각 권장) · `timeout-minutes`(넉넉히, 60~90) · 8언어 `install-verify.sh` 실행 · `INSTALL-MATRIX.md`+`report/signals/` 아티팩트 업로드 · setup-node(리포트 집계 호스트 실행). 부분실패 격리라 잡 자체는 green이되 매트릭스가 결과 담체.
- [ ] **Step 2: YAML 검증** — Run: `docker run --rm -v "$PWD:/w" -w /w rhysd/actionlint:latest -color .github/workflows/harness.yml` 또는 `python -c "import yaml;yaml.safe_load(open('.github/workflows/harness.yml'))"`.
- [ ] **Step 3: README.md** — 목적·`cd harness/install && ./install-verify.sh <langs>`·리포트(INSTALL-MATRIX.md) 해석·언어별 로컬 레지스트리 요약·부록 링크·Alpine/CI 주의.
- [ ] **Step 4: 커밋** — `git add .github/workflows/harness.yml harness/install/README.md && git commit -m "ci(install-harness): install-all 잡(야간/수동·매트릭스 아티팩트) + README"`.

---

## Self-Review (작성자 체크)

- **스펙 커버리지**: 설계 §3(4단계)→T0.1(Report)·T0.2(orchestrator)·T1.1+T2.x(Publish/Install/Operate)·T3.1(CI). §4 언어 8개→T1.1+T2.1~2.7. §6 리포트→T0.1. §7 CI→T3.1. §8 난점→각 언어 태스크에 인라인. 커버 완료.
- **placeholder**: 각 태스크에 부록 절 링크 + 핵심 명령 인라인. 부록이 정확 명령 전문 담체.
- **타입 정합**: 신호 스키마는 Global Constraints·T0.1에서 고정, 전 언어 태스크가 동일 필드 emit.
- **의존 순서**: T0.1→T0.2→T1.1(참조)→T2.x(복제, 상호 독립)→T3.1. T2.x는 서로 독립(언어별 격리)이라 순서 무관.
