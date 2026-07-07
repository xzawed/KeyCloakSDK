# 설치·동작 검증 하네스 (Install-&-Operate Harness) — 설계 (Design)

- **작성일**: 2026-07-07
- **브랜치**: `feature/install-operate-harness` (main 기준)
- **대상**: 크로스커팅 딜리버러블 — `harness/install/` (8개 언어 SDK 공통)
- **관련**: 8개 언어 SDK 전부 `main` 병합 완료 · 종합 검증·스코어링 하네스(PR #20) 병합 완료

---

## 1. 배경 / 문제

8개 언어 Keycloak SDK는 전부 완료·`main` 병합됐으나 **실레지스트리 배포는 사람 게이트(계정 없음)** 로 미실행이다. 기존 하네스(`harness/`)는 각 언어 SDK를 **소스 경로**로 소비한다:

| 언어 | 현재 하네스 소비 방식 | 설치 경로 검증 |
|---|---|---|
| node | `file:*.tgz`(`npm pack` 산출물) | 부분(파일) |
| java | `.m2` 로컬 저장소 의존 | 부분(로컬 repo) |
| go | `replace => /sdk`(소스) | ✗ |
| php | `type:path` repo(소스) | ✗ |
| dotnet | `<ProjectReference>`(소스) | ✗ |
| ruby | `path: /src/ruby`(소스) | ✗ |
| python | Dockerfile 직접(소스/wheel) | ⚠️ |

따라서 **배포 산출물을 실제 사용자가 설치·소비하는 경로**는 검증되지 않는다. 이 하네스는 실배포 대신 **프로덕션-유사 로컬 레지스트리에서 게시된 패키지를 설치하고 실동작을 검증**한다.

### 잡아내는 결함(기존 하네스가 못 잡는 것)
- 배포 산출물의 **매니페스트·파일목록·엔트리포인트·메타데이터**: npm `files:["dist"]`/`exports`, Python `py.typed`/wheel 레이아웃, Node `.d.ts`, `.nupkg` 의존성 그래프, gemspec `spec.files`(누락 파일), crate 포함목록, Maven POM 좌표·`-sources`/`-javadoc` jar.
- **의존성 해석(resolve)** 이 실제 레지스트리 프로토콜에서 성립하는지(전이 의존성 버전 범위·플랫폼 태그).
- 소스 트리 **없이** 클린 설치 후 **부팅·동작**.

---

## 2. 핵심 원칙 — 최대 재사용, 단일 변수

바꾸는 것은 **의존성 해석 소스 하나뿐**(소스 경로 → 로컬 레지스트리/피드/프록시). 앱 코드·conformance 러너·security 프로브·Keycloak realm·계약 v2는 **그대로 재사용**한다. 이로써 검증 대상(패키징/설치 경로)만 격리되고, 통과/실패가 곧 "게시된 패키지가 실제로 설치·동작하는가"를 뜻한다.

**동형성(하이브리드)**: "실환경 동일"은 각 생태계의 **네이티브 로컬 설치 경로**로 달성한다 — 레지스트리 서버가 가벼운 생태계는 실 레지스트리 서버(Verdaccio·pypiserver 등), 무거운 생태계는 표준 로컬 저장소(Maven `.m2`/file repo·cargo local registry·Composer artifact/Satis). 어느 경우든 **소비자 설치 명령은 실제와 동일**하고 소스 URL만 로컬로 지정한다. Maven `.m2`/cargo local registry는 "덜 충실한" 우회가 아니라 **공개 레지스트리가 소비자 측에서 해석되는 바로 그 경로**다.

---

## 3. 파이프라인 (언어별, 부분실패 격리)

각 언어에 대해 4단계를 순차 실행하고, 한 언어의 실패는 격리해 나머지 언어를 계속 진행한다(기존 `verify.sh` 패턴).

```
A. Publish   빌더 컨테이너가 실 배포 산출물을 빌드 → 로컬 레지스트리/피드/프록시에 게시.
             (릴리스 CI의 빌드 스텝을 재현하되 실 시크릿·업로드 없음.)
B. Install   소스 트리 없는 클린 소비자 컨테이너가 실제 설치 명령으로 패키지를 설치. consume/<lang>.Dockerfile은
             파일만 담고(BuildKit이 build-time custom --network을 지원하지 않아 빌드타임 네트워크 없음), 실제
             install→quickstart→app-boot는 런타임 엔트리포인트 consume/<lang>-run.sh가 install-net에서 수행하며
             진행 상태는 /status 마커 파일로 오케스트레이터에 노출한다.
             b1) quickstart 예제 실행           = 설치 스모크("신규 사용자 첫 프로그램")
             b2) 하네스 앱을 '설치된 패키지' 소비로 재빌드·부팅
C. Operate   설치된-패키지 앱에 대해 기존 conformance(계약 26체크) + security(JWT 하드닝 9프로브) 재실행.
D. Report    INSTALL-MATRIX.md 집계 — 언어별 빌드/게시/설치/quickstart/부팅/conf N·N/sec N·N.
             신호는 report/signals/<lang>.install.json.
```

**공유 인프라**: 실제 Keycloak 26.6(기존 `harness/keycloak/harness-realm.json` 재사용) + 언어별 로컬 레지스트리 서비스. compose 오케스트레이션.

---

## 4. 언어별 설치 메커니즘 (하이브리드)

병렬 딥리서치(2026-07-07, 8 에이전트·web 검증)로 확정. **정확한 명령 전문은 [설치 레시피 리서치 부록](2026-07-07-install-recipes-research.md)** — WBS 태스크와 구현자가 참조하는 권위 소스. 아래는 요약.

| 언어 | 산출물 | 로컬 소스(메커니즘) | 소비자 실명령(요약) | 충실도 |
|---|---|---|---|---|
| **node** | `npm pack` tgz | **Verdaccio 6.7.4**(실 npm 프로토콜) | `npm i @xzawed/keycloak-sdk@0.1.0 --registry http://verdaccio:4873` | 매우 높음 |
| **python** | `python -m build` whl+sdist | **pypiserver**(PEP 503 simple) | `pip install keycloak-sdk==0.1.0`(+`PIP_EXTRA_INDEX_URL`·`PIP_TRUSTED_HOST`) | 높음 |
| **go** | module zip(태그=릴리스) | **file GOPROXY**(`@v` 레이아웃) | `GOPROXY=file:///proxy,… GOSUMDB=off go get …/go@v0.1.0` | 매우 높음 |
| **dotnet** | `dotnet pack` .nupkg | **BaGetter**(NuGet V3 HTTP) | `dotnet add package Xzawed.Keycloak.Sdk --version 0.1.0`(+nuget.config local 소스) | 높음 |
| **java** | `-Prelease` jar+sources+javadoc | **nginx 정적 staged .m2** | POM: `keycloak-sdk-bom:0.1.0`(import)+`keycloak-sdk`(settings.xml `<repository>` 1개) | 매우 높음 |
| **ruby** | `gem build` .gem | **정적 gem repo**(`rubygems-generate_index`) | `gem install keycloak-sdk --version 0.1.0 --source http://…:8808` | 높음 |
| **php** | git archive zip(태그=버전) | **Satis**(정적 type:composer) | `composer require xzawed/keycloak-sdk:^0.1`(+repositories.local) | 높음 |
| **rust** | `cargo package` .crate | **cargo-local-registry**(소스 치환) | Cargo.toml `keycloak-sdk="0.1.0"`(+`.cargo/config.toml` source replace)→`cargo build --offline` | 높음(confidence medium) |

각 소비자 명령은 실제와 **바이트 동일**하되 소스 URL만 로컬로 지정한다. Maven `.m2`/cargo local-registry는 "덜 충실한" 우회가 아니라 공개 레지스트리가 소비자 측에서 해석되는 바로 그 경로다(§2).

---

## 5. 파일 구조 (`harness/install/`, 기존 하네스 하위)

```
harness/install/
├─ README.md                     # 목적·실행법·리포트 해석
├─ install-verify.sh             # 오케스트레이터(verify.sh 미러 — 언어 인자·부분실패 격리·부분 진행)
├─ compose.install.yml           # Keycloak + 언어별 로컬 레지스트리 서비스
├─ registries/                   # 로컬 레지스트리 구성(Verdaccio conf·pypiserver·Satis·cargo config 등)
├─ publish/<lang>.sh             # A: 산출물 빌드 → 로컬 레지스트리 게시(언어별)
├─ consume/<lang>.Dockerfile     # B: 파일만 담는 설치 컨테이너 이미지(빌드타임 네트워크 없음)
├─ consume/<lang>-run.sh         # B: 런타임 엔트리포인트 — install-net에서 install→quickstart→app-boot 수행(/status 마커)
├─ quickstart/                   # 누락 예제 보충: dotnet 콘솔 quickstart(+ go 러너블 main)
└─ report/
   ├─ install-matrix.mjs         # D: signals/*.install.json → INSTALL-MATRIX.md
   └─ INSTALL-MATRIX.md          # 산출(git-ignored 또는 커밋 — CI 아티팩트)
```

**앱 재사용 전략**: 기존 `harness/apps/<lang>` 코드는 그대로 두고, `consume/<lang>.Dockerfile`이 **의존성 선언만** 로컬 레지스트리 설치로 바꾼 매니페스트로 앱을 빌드한다(소스 경로 제거). 앱 소스 코드 변경 없음.

---

## 6. 리포트 — INSTALL-MATRIX.md

언어별 한 행, 단계별 상태:

| lang | artifact | publish | install | quickstart | app-boot | conformance | security |
|---|---|---|---|---|---|---|---|
| go | ✓ | ✓ | ✓ | ✓ | ✓ | 26/26 | 9/9 |
| … | | | | | | | |

- 신호 스키마 `report/signals/<lang>.install.json`: `{ lang, artifactBuilt, published, installed, quickstartOk, appBoot, conformance:{passed,failed}, security:{defended,total}, error? }`.
- 한 언어의 임의 단계 실패는 `<lang>.install.json`의 해당 필드 false + `error`로 격리, 나머지 언어 계속 진행.
- **스코어링과 분리**: 설치 검증은 `SCORECARD.md`(기능·보안·커버·성능)와 별개 관심사이므로 독립 `INSTALL-MATRIX.md`로 산출한다(혼동 방지).

---

## 7. CI

`.github/workflows/harness.yml`에 **`install-all`** 잡 추가:
- 트리거: `workflow_dispatch` + `schedule`(야간). PR/푸시엔 미실행(빌드+레지스트리 8종으로 무겁다).
- 부분실패 격리, `INSTALL-MATRIX.md` + `signals/` 아티팩트 업로드.
- 기존 `mvp-go`(PR 게이트)·`all-langs`·`score-all` 잡은 불변.

---

## 8. 알려진 난점 (선제 대응)

- **Windows Docker glibc-DNS 게차(기존)**: 레지스트리·빌더·소비자 컨테이너 전부 **Alpine/musl** 베이스. Debian/glibc 빌드 이미지는 Docker Desktop(Windows) 내장 DNS 프록시가 레지스트리 CNAME 체인을 glibc 리졸버에 실패로 돌려줘 패키지 다운로드가 막힌다. 소비자를 로컬 레지스트리 단일 소스로 라우팅하면 소비자는 서비스명(단일 A레코드)만 해석해 이슈를 우회한다.
- **언어별 난점(리서치 확정 — 상세는 [부록](2026-07-07-install-recipes-research.md))**:
  - **java**: `versions:set`로 SNAPSHOT→0.1.0(Central은 SNAPSHOT 거부) · release 프로파일의 central-publishing-plugin이 `deploy` 하이재킹 → **`install` 사용** · parent+BOM POM까지 서빙(6 아티팩트).
  - **go**: 서브디렉토리 모듈이라 태그 **`go/v0.1.0`**(프리픽스) · 경로 케이스 인코딩(`!key!cloak!s!d!k`)은 `go mod download`가 생성 · 소비자 **GOPRIVATE 금지**(프록시 우회).
  - **rust**: `cargo add`가 source-replaced local-registry에서 실패 가능(cargo #10926) → Cargo.toml 직접 기입 폴백 · keycloak-sdk 본체는 `.crate`+index 라인 **수동 주입**(cksum=sha256) · 전 트랜지티브 클로저 필요(confidence medium).
  - **php**: monorepo `php/`를 subtree-split repo로 `v0.1.0` 태그(실 태그 `php-v0.1.0`는 Composer 미파싱) · satis `homepage`=dist 서빙 URL 일치.
  - **dotnet**: `dotnet add package -s <url>` 단일 소스 치환 금지(전이 의존성 실패) → nuget.config에 **추가**+`packageSourceMapping` · 예제 부재 → 소형 콘솔 quickstart 신설.
  - **ruby**: `gem generate_index`는 코어에서 제거(3.5.0) → `gem install rubygems-generate_index` 선행 · repo **루트** 서빙 · require명 `keycloak_sdk`.
  - **python**: `PIP_TRUSTED_HOST`는 **포트 없는** 호스트명 · twine 더미 자격증명 필수 · `python -m build`·소비 설치는 정상 DNS(Alpine) 필요.
  - **공통 재게시 함정**: 대부분 생태계가 동일 버전 0.1.0 재게시를 거부(409) → 반복 시 storage/볼륨 초기화(`--skip-duplicate`/`--overwrite`/unpublish).
- **go/dotnet 예제 처리**: go의 `example_test.go`는 러너블 아님 → 소형 `main.go` quickstart 필요. dotnet은 예제 부재 → 소형 콘솔 quickstart 신설.
- **실행 시간**: 8개 레지스트리 + 빌드로 길다 → 언어별 격리·CI 야간 1차·로컬은 언어 부분집합 실행 가능.

---

## 9. 범위 밖 (YAGNI)

- 실 공개 레지스트리 배포(사람 게이트 — 이 하네스의 목적이 그 대체).
- 크로스버전 호환 매트릭스(여러 Keycloak/런타임 버전) — 단일 26.6 + 각 언어 대표 런타임만.
- 성능 회귀(k6는 기존 하네스 소관).
