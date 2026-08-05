# 설치·동작 검증 하네스 — 로컬 설치 레시피 리서치 부록

> <!-- doc-status: complete -->
> **✅ 완료 — 이 설계는 구현됐다. 기록으로 읽어라.** 여기 적힌 "할 것"은 이미 한 것이고, 결정의
> *근거*가 이 문서의 가치다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [문서 지도](../../README.md)에 있다.

> 8개 언어의 "충실한 로컬 패키지 설치" 레시피를 병렬 딥리서치(2026-07-07, 8 에이전트·web 검증)로 확정. WBS 태스크·구현자가 참조하는 **권위 명령 소스**. 설계는 [install-operate-harness-design.md](2026-07-07-install-operate-harness-design.md).
>
> 공통 원칙: 모든 빌더·레지스트리·소비자 컨테이너는 **Alpine/musl** 베이스(Windows Docker Desktop glibc-DNS 게차 회피). 소비자는 격리 docker network에서 레지스트리를 **서비스명**으로 해석(임베디드 DNS). 소비자 설치 명령은 실제와 동일하고 **소스 URL만 로컬로 override**한다.

---

## node — Verdaccio (실 npm 프로토콜, 충실도 매우 높음)

- **빌드**: `npm ci && npm run build && npm pack` → `node/xzawed-keycloak-sdk-0.1.0.tgz`. ⚠️ **build가 pack보다 먼저**(prepack 훅 없음 — 생략 시 빈 dist/ 게시).
- **레지스트리**: `verdaccio/verdaccio:6.7.4`(node:24-alpine 베이스). config `packages.'**'.publish: $all`(익명 게시 허용).
- **게시**: Alpine node 컨테이너에서 `echo "//verdaccio:4873/:_authToken=local-anon" > ~/.npmrc && npm publish ./xzawed-keycloak-sdk-0.1.0.tgz --registry http://verdaccio:4873 --access public`(tgz 직접 게시 = 바이트 동일).
- **소비**: `npm install @xzawed/keycloak-sdk@0.1.0 --registry http://verdaccio:4873`(단일 --registry로 deps까지 uplink 프록시 → 소비자는 `verdaccio`만 DNS 해석).
- **게차**: ENEEDAUTH는 클라이언트측 → 더미 토큰 필수(Verdaccio가 익명 처리). 재게시 409 EPUBLISHCONFLICT → unpublish --force 또는 storage 볼륨 초기화. `--provenance`는 로컬 불가(설치 무영향). SDK·deps 전부 순수 JS(네이티브 없음).

## python — pypiserver (PEP 503 simple index, 충실도 높음)

- **빌드**: `python -m build` → `python/dist/keycloak_sdk-0.1.0-py3-none-any.whl` + `.tar.gz`(순수 파이썬 → OS 무관 동일). ⚠️ build는 격리 venv에 hatchling을 PyPI에서 받음 → **정상 DNS 환경(호스트/Alpine)에서만**.
- **레지스트리**: `pypiserver/pypiserver:latest`(python:3.14-alpine 베이스, 내부 8080). 기동 인자 `run -a . -P . /data/packages`(인증 비활성).
- **게시**: `TWINE_USERNAME=x TWINE_PASSWORD=x twine upload --repository-url http://localhost:8080/ python/dist/*`(더미 자격증명 필수 — 없으면 대화형 멈춤).
- **소비**: `pip install "keycloak-sdk==0.1.0"` + env `PIP_EXTRA_INDEX_URL=http://pypiserver:8080/simple/` + `PIP_TRUSTED_HOST=pypiserver`. ⚠️ **trusted-host는 포트 없는 호스트명**(`pypiserver:8080`이면 pip 무시).
- **게차**: wheel 파일명은 언더스코어(`keycloak_sdk`), 배포명/simple 경로는 하이픈(`keycloak-sdk`/`/simple/keycloak-sdk/`). 트랜지티브 `cryptography`(Rust 확장)는 x86_64/aarch64 Alpine musllinux prebuilt 있음(미지원 아키텍처만 `apk add build-base rust cargo`). 재업로드 기본 거부(--overwrite 또는 파일 삭제).

## go — file GOPROXY (충실도 매우 높음)

- **아티팩트**: 빌드 단계 없음(태그=릴리스). 서브디렉토리 모듈이라 태그 **`go/v0.1.0`**(프리픽스 필수 — bare `v0.1.0`은 무시). `git tag go/v0.1.0` 후 `GOSUMDB=off GOPROXY=direct go mod download -x github.com/xzawed/KeyCloakSDK/go@v0.1.0`가 `$GOMODCACHE/cache/download/.../@v/v0.1.0.{info,mod,zip,ziphash}` 합성(git-archive→zip, 공개 프록시와 동일 알고리즘).
- **레지스트리**: 데몬 불요 — `cache/download` 서브트리를 `/proxy`로 복사(이미 GOPROXY 레이아웃). 프로듀서는 `git config --global url."file:///src".insteadOf "https://github.com/xzawed/KeyCloakSDK"`(격리 HOME에 스코프).
- **소비**: `GOPROXY='file:///proxy,https://proxy.golang.org,direct' GOSUMDB=off go get github.com/xzawed/KeyCloakSDK/go@v0.1.0`(로컬은 SDK만, deps는 공개 프록시로 폴스루). 완전 격리는 `go mod download all` 후 전 deps를 /proxy에 시드.
- **게차**: 경로 케이스 인코딩 `github.com/xzawed/!key!cloak!s!d!k/go/@v/`(대문자→`!`+소문자) — `go mod download`가 생성하게 둘 것. 소비자에 **GOPRIVATE 설정 금지**(→GONOPROXY→direct VCS 폴백으로 프록시 우회). GONOSUMCHECK는 폐기(1.12 이후) — GOSUMDB=off 사용. 태그 부재 시 pseudo-version(Java SNAPSHOT 대응 함정). SDK·deps 순수 Go(CGO_ENABLED=0).

## dotnet — BaGetter (NuGet V3 HTTP, 충실도 높음)

- **빌드**: `dotnet pack dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -c Release -o artifacts -p:Version=0.1.0 -p:ContinuousIntegrationBuild=true` → `artifacts/Xzawed.Keycloak.Sdk.0.1.0.nupkg`.
- **레지스트리**: `bagetter/bagetter:latest`(내부 8080, V3 index `http://nuget-server:8080/v3/index.json`). 미러링은 끈 채 로컬 전용(바깥 DNS 불요). env `ApiKey`/`Storage__Type=FileSystem`/`Database__Type=Sqlite`.
- **게시**: `dotnet nuget push artifacts/Xzawed.Keycloak.Sdk.0.1.0.nupkg --source http://localhost:8080/v3/index.json --api-key LOCALKEY --skip-duplicate`.
- **소비**: `dotnet add package Xzawed.Keycloak.Sdk --version 0.1.0`(명령 문자열 실제와 동일). 옆의 `nuget.config`에 local 소스 **추가**(치환 아님) + `packageSourceMapping`(Xzawed.Keycloak.Sdk만 local, `*`→nuget.org) + `<config> allowInsecureConnections=true`(http).
- **게차**: ⚠️ `dotnet add package -s <url>`(단일 소스 치환) 금지 → 전이 의존성(Duende.IdentityModel 등) 해석 실패. `packageSourceMapping`이 정답. 재푸시 409(`--skip-duplicate`). 소비자/빌드 이미지 `mcr.microsoft.com/dotnet/sdk:8.0-alpine`. 로컬 .nupkg 미서명(서명검증 정책 강제 시 거부). 폴더 피드(방법 B)는 HTTP V3 미검증 → BaGetter 권장.

## java — 정적 nginx가 서빙하는 staged .m2 (충실도 매우 높음)

- **빌드**(Alpine `maven:3.9-eclipse-temurin-21-alpine`): `mvn versions:set -DnewVersion=0.1.0 -DgenerateBackupPoms=false` → `mvn -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true -Dmaven.repo.local=/work/staging-m2 install`. staging-m2에 릴리스 좌표 0.1.0 전체(parent+BOM+core/auth/admin/keycloak-sdk, jar+pom+sources+javadoc).
- **레지스트리**: `nginx:1.27-alpine`가 staging-m2를 서빙(`http://mvn-repo/`). Central=repo1.maven.org도 정적 파일 호스트라 프로토콜 동일. 데몬 불요(대안 file:// repo).
- **소비**(Alpine maven): settings.xml에 `<repository> http://mvn-repo/` 한 개 추가. 소비자 POM은 `keycloak-sdk-bom:0.1.0`(import) + `keycloak-sdk`(무버전). 해석 확인 `mvn -s settings.xml dependency:get -Dartifact=io.github.xzawed:keycloak-sdk:0.1.0`.
- **게차**: ⚠️ central-publishing-maven-plugin(release 프로파일, extensions=true)이 `deploy` phase 하이재킹 → **`install` 사용**(deploy는 Portal로 감). SNAPSHOT→0.1.0 `versions:set` 필수(Central은 SNAPSHOT 거부). **parent POM + BOM POM도 서빙**(6 아티팩트 — jar 4개만으론 부모/BOM 해석 실패). 정적 레이아웃은 .sha1/.md5·maven-metadata 없어 checksum WARNING(무해). `<mirror>*` 금지(전이 의존성 Central 유지). enforcer Maven≥3.9·JDK≥21.

## ruby — 정적 gem repo (rubygems-generate_index, 충실도 높음)

- **빌드**: `gem build keycloak-sdk.gemspec` → `keycloak-sdk-0.1.0.gem`(순수 Ruby). LICENSE·README.md가 `ruby/`에 있어야 함(gemspec `spec.files`).
- **레지스트리**: `ruby:3.4-alpine`에서 `gem install rubygems-generate_index`(코어에서 3.5.0 제거됨) → `gem generate_index --directory /repo`(레거시 Marshal 인덱스). 서빙은 `gem install webrick && ruby -run -e httpd /repo -p 8808`(webrick 3.0부터 un-bundle) 또는 nginx:alpine. **repo 루트를 서빙**(gems/ 하위 아님).
- **게시**: `cp keycloak-sdk-0.1.0.gem /repo/gems/ && gem generate_index --directory /repo`.
- **소비**: `gem install keycloak-sdk --version 0.1.0 --source http://localhost:8808`(--source는 APPEND — deps는 rubygems.org). 검증 `ruby -e 'require "keycloak_sdk"; puts KeycloakSdk::VERSION'`.
- **게차**: `gem server` 제거(3.3.0). 레거시 인덱스라 Bundler는 compact index 선호 → 경고/폴백(gem install은 투명). require명 `keycloak_sdk`(언더스코어)≠gem명 `keycloak-sdk`. 더 높은 충실도는 Gemstash(실 `gem push` + compact index, `/private` 경로).

## php — Satis (type:composer, 충실도 높음)

- **아티팩트**: 빌드 없음(태그=버전, Packagist가 git archive zip 서빙). monorepo `php/`를 격리 repo로 subtree-split 후 `git tag v0.1.0`(실 배포 태그 `php-v0.1.0`는 Composer 미파싱·서브디렉토리 미지원 → split 전제).
- **레지스트리**: `composer/satis:latest`(php:8.4-cli-alpine) `build satis.json output`. satis.json: `repositories:[{type:vcs, url:/work/php-src}]` + `require:{xzawed/keycloak-sdk:*}` + `require-dependencies:false` + `archive:{format:zip}`. output/을 `nginx:alpine`로 서빙(`http://satis-web`). ⚠️ satis `homepage`가 dist 서빙 URL과 일치해야 함.
- **소비**: `composer config repositories.local composer http://satis-web` + `composer require xzawed/keycloak-sdk:^0.1`. http라 테스트 한정 `composer config secure-http false`.
- **게차**: composer.json에 version 필드 없음(정석 — 태그에서 도출). `composer archive`는 .gitignore 무시(vendor/ 딸려올 수 있음 → git archive 사용). `type:artifact` 폴백은 zip 내 composer.json에 version 주입 필요(저충실). 런타임 이미지엔 `apk add php83-openssl php83-curl php83-mbstring php83-sodium`(설치엔 불요).

## rust — cargo local-registry (충실도 높음·confidence medium)

- **빌드**: `cargo package --locked` → `rust/target/package/keycloak-sdk-0.1.0.crate`(`cargo publish`와 동일 tarball).
- **레지스트리**(Alpine `rust:1.88-alpine`, 툴에 `apk add build-base openssl-dev openssl-libs-static perl cmake pkgconfig git` + `OPENSSL_STATIC=1`): `cargo install cargo-local-registry --version 0.2.8 --locked` → `cargo generate-lockfile` → `cargo local-registry sync --no-delete Cargo.lock /opt/local-registry`(전 트랜지티브 클로저 미러). keycloak-sdk 본체는 **수동 주입**: `.crate` 복사 + `index/ke/yc/keycloak-sdk`에 v2 JSON 한 줄(deps는 Cargo.toml 미러, `cksum`=`.crate`의 sha256).
  ⚠️ 0.2.12는 내부 cargo crate 0.95.0→rustc 1.92 요구로 rustc 1.88 비호환 — 0.2.8로 고정(실측).
- **소비**(오프라인): `.cargo/config.toml`에 `[source.crates-io] replace-with="local"` + `[source.local] local-registry="/opt/local-registry"`. `cargo add keycloak-sdk`(#10926로 실패 가능 → 폴백 `keycloak-sdk = "0.1.0"`를 Cargo.toml에 직접) → `cargo build --offline`(전 클로저 로컬 해석·동일 cksum 검증·컴파일).
- **게차**: ⚠️ `cargo add`가 source-replaced local-registry에서 `no index found`(cargo #10926, open) → Cargo.toml 직접 기입 폴백(build/verify 경로 동일). cargo-local-registry `add`는 crates.io에서만 fetch(로컬 .crate 주입 불가 → 수동). 소스 치환은 **전 트랜지티브 클로저** 필요(하나라도 누락 시 build 실패 — sync가 보장). index deps 배열 수동 유지(`=26.6.2`/`=4.0.1`/`=10.4.0` 핀 드리프트 주의). SDK 본체는 rustls(OpenSSL 불요).
