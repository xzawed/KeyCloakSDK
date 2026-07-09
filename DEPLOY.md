# 배포 가이드 (DEPLOY)

9개 언어 SDK 모두 **태그 드리븐 릴리스 CI**가 준비돼 있다. 실제 배포는 **사람이 태그를 push**해야만 트리거되는 승인 게이트(human-gate)이며, 아래 사전 준비(계정·키·토큰)는 리포지토리 소유자만 수행할 수 있다.

> ⚠️ 배포는 되돌릴 수 없다(같은 좌표/버전 재배포 불가). dry-run으로 산출물을 먼저 검증하라(각 절 마지막).
>
> ✅ **실배포 전 최종 검증**: [`harness/install/`](harness/install/README.md)의 설치·동작 검증 하네스가 각 SDK를 **게시 패키지처럼 로컬 레지스트리에서 설치**하고 실 Keycloak에 대해 동작(quickstart+conformance+security)까지 검증한다 — 실배포와 동형인 설치 경로를 사전 확인. `cd harness/install && ./install-verify.sh <lang>`(9/9 언어 로컬 실측 GREEN). 실배포 태그를 push하기 전에 해당 언어를 여기서 통과시키는 것을 권장.
>
> 🛠️ **도우미 스크립트**: 이 문서의 표·명령은 `scripts/lib/deploy-facts.sh`(단일 진실원천)에서 나온다. 직접 표를 훑는 대신 아래 두 도우미로 상태를 확인하고 명령을 얻어라.
> - `./scripts/release-readiness.sh [lang ...]` — 언어별 시크릿·레지스트리·태그 준비상태를 읽기전용으로 리포트(값 노출 없음, 인자 없으면 9개 전부).
> - `./scripts/release-trigger.sh <lang> <version>` — 버전 범프 안내 + dry-run 명령 + 정확한 태그 push 명령을 **출력만** 한다(human-gate — `git tag`/`push`를 절대 실행하지 않는다).

---

## §0. 개요 + 준비상태 매트릭스

| 언어 | 레지스트리 | 인증 | 태그 | 버전 범프 | 시크릿(개수) | 배포 후 설치 |
|---|---|---|---|---|---|---|
| **Go** | Go module proxy (proxy.golang.org) | none | `go/v*` | 없음(태그=SSOT) | 0 | `go get github.com/xzawed/KeyCloakSDK/go@vX.Y.Z` |
| **PHP** | Packagist | webhook | `php-v*` | 없음(태그=SSOT) | 0(웹훅) | `composer require xzawed/keycloak-sdk` |
| **Rust** | crates.io | api-token | `rust-v*` | `rust/Cargo.toml` `[package].version` | 1(`CARGO_REGISTRY_TOKEN`) | `cargo add keycloak-sdk` |
| **.NET** | NuGet | api-token | `dotnet-v*` | 없음(태그 `-p:Version` 주입) | 1(`NUGET_API_KEY`·미설정 시 조용히 스킵) | `dotnet add package Xzawed.Keycloak.Sdk` |
| **Python** | PyPI | OIDC | `py-v*` | `python/pyproject.toml` `[project].version` | 0(OIDC) | `pip install keycloak-sdk` |
| **Node** | npm | OIDC | `node-v*` | `node/package.json` `version` | 0(OIDC+provenance) | `npm install @xzawed/keycloak-sdk` |
| **Ruby** | RubyGems | OIDC | `ruby-v*` | `ruby/lib/keycloak_sdk/version.rb` `VERSION` | 0(OIDC+`release` 환경) | `gem install keycloak-sdk` |
| **Java** | Maven Central | maven-gpg | `v*` | 자동(versions-maven-plugin, 태그값 주입) | 4(GPG 2 + Portal 토큰 2) | `io.github.xzawed:keycloak-sdk` |
| **Kotlin** | Maven Central | maven-gpg | `kotlin-v*` | `kotlin/build.gradle.kts` `version`(수동) | 4(vanniktech 이름) | `io.github.xzawed:keycloak-sdk-kotlin` |

**권장 배포 순서(쉬운 인증 → 어려운 인증)**:

```
go → php → rust → dotnet → python → node → ruby → java → kotlin
```

**지금 상태 확인**: `./scripts/release-readiness.sh` (인자 없으면 9개 언어 전부 한 번에 리포트).

---

## §1. 공통 원칙

- **태그 드리븐**: 9개 release 워크플로 모두 특정 포맷의 태그 push로만 트리거된다(§0 표의 "태그" 열).
- **`needs: verify` 게이트**: 모든 release 워크플로는 태그가 가리키는 커밋이 lint/test green이 아니면 배포하지 않는다 — 태그 push 전에 해당 언어의 통상 검증(단위테스트·린트)이 통과해 있어야 한다.
- **human-gate**: 실제 배포 트리거(태그 push)는 반드시 **사람이 직접** 실행한다. `release-trigger.sh`는 명령을 출력만 하며 `git tag`/`git push`를 스스로 실행하지 않는다.
- **되돌릴 수 없음**: 모든 레지스트리는 동일 버전 재배포를 허용하지 않는다 — 잘못된 태그를 push하면 그 버전 번호는 사실상 소각된다.
- **dry-run 필수**: 태그 push 전에 반드시 로컬 dry-run(배포 없이 산출물만 빌드)으로 산출물이 정상 생성되는지 확인한다(§0 표 각 언어, `release-trigger.sh` 출력에도 포함).

**버전 범프 규칙**:

| 유형 | 언어 | 설명 |
|---|---|---|
| 자동(4) | go · php · dotnet · java | 태그 자체가 버전 SSOT — 워크플로가 태그값을 빌드에 주입한다(파일 수정 불필요). Java만 예외적으로 `versions-maven-plugin`이 POM의 `-SNAPSHOT`을 태그값으로 치환 후 배포한다(main POM은 계속 `-SNAPSHOT` 유지). |
| 수동(5) | rust · python · node · ruby · kotlin | 태그 push **전에** 소스의 버전 필드를 사람이 직접 올려 커밋해야 한다(§0 표 "버전 범프" 열의 정확한 위치). |

---

## §2. 인증 모델별 1회 설정

같은 인증 모델은 설정 절차가 동일하므로 그룹으로 한 번만 설명한다. 시크릿 **이름**만 언어별로 다르다.

### A. Maven Central + GPG (Java · Kotlin)

1. **네임스페이스 검증(1회)**: https://central.sonatype.com 에 **GitHub 계정(`xzawed`)으로 로그인** → `io.github.xzawed` 네임스페이스가 자동 검증/프로비저닝된다(안 되면 View Namespaces에서 `io.github.xzawed` 추가 → 표시된 키 이름의 **공개 임시 리포지토리**를 GitHub에 생성해 소유 확인).
2. **Central Portal 토큰 발급(1회)**: Central Portal → Account → **Generate User Token** → username/password 확보.
3. **GPG 서명키 생성·키서버 배포(1회)**:
   ```bash
   gpg --gen-key                          # 이름/이메일(xzawed31@gmail.com)/패스프레이즈 입력
   gpg --list-secret-keys --keyid-format=long   # KEYID 확인
   gpg --keyserver keyserver.ubuntu.com --send-keys <KEYID>   # 공개키 배포(필수 — 먼저 안 하면 서명 검증 실패)
   gpg --armor --export-secret-keys <KEYID> > private.asc     # 개인키 armored 내보내기
   ```
4. **GitHub Secrets 등록**(Settings → Secrets and variables → Actions) — **이름이 언어별로 다르다**:

   | Secret | Java | Kotlin | 값 |
   |---|---|---|---|
   | GPG/서명 개인키 | `MAVEN_GPG_PRIVATE_KEY` | `SIGNING_IN_MEMORY_KEY` | `private.asc` 전체 내용(armored) |
   | GPG/서명 패스프레이즈 | `MAVEN_GPG_PASSPHRASE` | `SIGNING_IN_MEMORY_KEY_PASSWORD` | GPG 패스프레이즈 |
   | Portal 토큰 username | `CENTRAL_TOKEN_USER` | `MAVEN_CENTRAL_USERNAME` | 2번의 토큰 username |
   | Portal 토큰 password | `CENTRAL_TOKEN_PW` | `MAVEN_CENTRAL_PASSWORD` | 2번의 토큰 password |

5. **2단계 수동 release**: 워크플로는 Central Portal **스테이징까지만** 자동 업로드한다. 실제 공개(Publish)는 [Central Portal](https://central.sonatype.com) Deployments 화면에서 **사람이 수동으로 Publish**해야 완료된다(autoPublish 미설정 시).

### B. OIDC / Trusted Publisher (Python · Node · Ruby)

1. **Pending Publisher 선등록(1회, 시크릿 불필요)**: 각 레지스트리의 Publishing 설정 화면에서 **배포 전에 미리** 등록해야 한다(패키지가 아직 존재하지 않아 프로젝트별 등록 화면이 없으므로 계정 레벨의 "pending publisher" 등록을 쓴다). 등록 값은 공통으로 **owner=`xzawed`** · **repo=`KeyCloakSDK`**, 워크플로 파일명은 언어별로 다르다:
   - Python: `python-release.yml`
   - Node: `node-release.yml`
   - Ruby: `ruby-release.yml` · **environment는 `release`**(다른 두 언어는 비움)
2. **Ruby 닭달걀(chicken-and-egg) 주의**: RubyGems의 Trusted Publisher는 **gem이 이미 존재해야** UI에서 등록할 수 있다 — 즉 최초 1회는 API 키로 수동 게시하거나, rubygems.org의 신규 프로젝트용 사전등록 절차를 밟아야 이후 태그 기반 OIDC 배포로 전환된다.
3. OIDC이므로 저장 시크릿은 필요 없다(워크플로가 GitHub Actions OIDC 토큰으로 레지스트리와 직접 교환).

### C. API 토큰 (.NET · Rust)

1. 레지스트리에서 API 토큰을 발급한다(NuGet: nuget.org → API Keys, crates.io: Account Settings → API Tokens).
2. GitHub Secrets에 등록한다:
   - .NET: `NUGET_API_KEY`
   - Rust: `CARGO_REGISTRY_TOKEN`
3. **미설정 시 동작이 다르다** — 사고 방지를 위해 반드시 숙지:
   - .NET: 시크릿이 없으면 push 스텝이 **조용히 스킵**된다(워크플로 자체는 성공하고 GitHub Release도 생성되므로, 실제로 NuGet에 올라갔는지 놓치기 쉽다 — Actions 로그를 반드시 확인).
   - Rust: 시크릿이 없으면 `cargo publish`가 **하드 실패**한다(워크플로 자체가 실패로 끝난다).

### D. 웹훅 (PHP)

1. **Packagist 저장소 1회 등록**: https://packagist.org 에 로그인 후 `xzawed/keycloak-sdk` GitHub 리포지토리를 Submit으로 등록한다.
2. release 워크플로 자체는 어디에도 게시하지 않는다 — Packagist가 GitHub 웹훅으로 새 태그를 자동 감지해 게시한다. **저장소 등록 전에는 태그를 push해도 Packagist에 아무 일도 일어나지 않는다.**

### E. 무설정 (Go)

1. 아무 사전 설정도 필요 없다. `go/v*` 태그를 push하면 `proxy.golang.org`가 최초 `go get`/`go install` 요청 시 온디맨드로 모듈을 캐시한다. 모노레포 서브모듈이므로 태그에 `go/` 접두가 반드시 필요하다.

---

## §3. 언어별 상세 (권장 순서)

각 언어: 1회 설정(§2 참조) → 버전 범프 위치 → dry-run → 태그/트리거 → 배포 확인 → 설치 좌표.

### 1. Go

- 1회 설정: §2-E(없음).
- 버전 범프: 없음(태그가 SSOT).
- dry-run: `go -C go build ./... && go -C go vet ./... && go -C go test ./...`
- 태그: `go/vX.Y.Z` — 안내 명령: `./scripts/release-trigger.sh go 0.1.0`
  ```bash
  git tag go/v0.1.0 && git push origin go/v0.1.0
  ```
- 배포 확인: GitHub Actions `go-release.yml` 성공 확인. 프록시 캐시는 최초 `go get` 요청 시 발생하므로 즉시 조회되지 않을 수 있다.
- 설치: `go get github.com/xzawed/KeyCloakSDK/go@v0.1.0`

### 2. PHP

- 1회 설정: §2-D(Packagist 저장소 등록).
- 버전 범프: 없음(태그가 SSOT).
- dry-run: `cd php && composer install && composer audit && vendor/bin/phpstan analyse && vendor/bin/phpunit --testsuite unit`
- 태그: `php-vX.Y.Z` — 안내 명령: `./scripts/release-trigger.sh php 0.1.0`
  ```bash
  git tag php-v0.1.0 && git push origin php-v0.1.0
  ```
- 배포 확인: GitHub Actions `php-release.yml`(verify + GitHub Release 생성) 성공 확인 → Packagist 페이지(`xzawed/keycloak-sdk`)에 새 버전이 반영됐는지 확인.
- 설치: `composer require xzawed/keycloak-sdk`

### 3. Rust

- 1회 설정: §2-C(`CARGO_REGISTRY_TOKEN`).
- 버전 범프: `rust/Cargo.toml` `[package].version`.
- dry-run: `cd rust && cargo build --all-targets && cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt --all --check`(선택: `cargo publish --dry-run`으로 crates.io 업로드 사전검증)
- 태그: `rust-vX.Y.Z` — 안내 명령: `./scripts/release-trigger.sh rust 0.1.0`
  ```bash
  git tag rust-v0.1.0 && git push origin rust-v0.1.0
  ```
- 배포 확인: GitHub Actions `rust-release.yml`(`cargo publish`) 성공 확인. 시크릿 미설정 시 **하드 실패**로 즉시 드러난다.
- 설치: `cargo add keycloak-sdk`

### 4. .NET

- 1회 설정: §2-C(`NUGET_API_KEY`).
- 버전 범프: 없음(태그가 `-p:Version`으로 주입됨).
- dry-run: `dotnet pack dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -c Release`
- 태그: `dotnet-vX.Y.Z` — 안내 명령: `./scripts/release-trigger.sh dotnet 0.1.0`
  ```bash
  git tag dotnet-v0.1.0 && git push origin dotnet-v0.1.0
  ```
- 배포 확인: GitHub Actions `dotnet-release.yml` 성공 확인 **후 반드시 NuGet 페이지도 직접 확인**(시크릿 미설정 시 워크플로는 성공하지만 push는 조용히 스킵됨 — §2-C 참조).
- 설치: `dotnet add package Xzawed.Keycloak.Sdk`

### 5. Python

- 1회 설정: §2-B(Pending Publisher, workflow=`python-release.yml`).
- 버전 범프: `python/pyproject.toml` `[project].version`.
- dry-run: `cd python && python -m build` (로컬 venv 사용 시 `/d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m build`)
- 태그: `py-vX.Y.Z` — 안내 명령: `./scripts/release-trigger.sh python 0.1.0`
  ```bash
  git tag py-v0.1.0 && git push origin py-v0.1.0
  ```
- 배포 확인: GitHub Actions `python-release.yml` 성공 확인 → https://pypi.org/project/keycloak-sdk/
- 설치: `pip install keycloak-sdk`

### 6. Node

- 1회 설정: §2-B(Pending Publisher, workflow=`node-release.yml`).
- 버전 범프: `node/package.json` `version`.
- dry-run: `cd node && npm run build && npm pack --dry-run`
- 태그: `node-vX.Y.Z` — 안내 명령: `./scripts/release-trigger.sh node 0.1.0`
  ```bash
  git tag node-v0.1.0 && git push origin node-v0.1.0
  ```
- 배포 확인: GitHub Actions `node-release.yml`(OIDC + provenance, `npm install -g npm@latest` 포함) 성공 확인 → https://www.npmjs.com/package/@xzawed/keycloak-sdk
- 설치: `npm install @xzawed/keycloak-sdk`

### 7. Ruby

- 1회 설정: §2-B(Pending Publisher, workflow=`ruby-release.yml`, environment=`release`, 닭달걀 주의).
- 버전 범프: `ruby/lib/keycloak_sdk/version.rb` `VERSION`.
- dry-run: `cd ruby && gem build keycloak-sdk.gemspec`
- 태그: `ruby-vX.Y.Z` — 안내 명령: `./scripts/release-trigger.sh ruby 0.1.0`
  ```bash
  git tag ruby-v0.1.0 && git push origin ruby-v0.1.0
  ```
- 배포 확인: GitHub Actions `ruby-release.yml` 성공 확인 → https://rubygems.org/gems/keycloak-sdk
- 설치: `gem install keycloak-sdk`

### 8. Java

- 1회 설정: §2-A(시크릿 `MAVEN_GPG_PRIVATE_KEY`/`MAVEN_GPG_PASSPHRASE`/`CENTRAL_TOKEN_USER`/`CENTRAL_TOKEN_PW`).
- 버전 범프: 자동(`versions-maven-plugin`이 태그값을 주입 — `java/pom.xml`은 계속 `-SNAPSHOT` 유지, 파일 수정 불필요).
- dry-run:
  ```bash
  JAVA_HOME='/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot' PATH="/c/Users/dirtc/tools/apache-maven-3.9.9/bin:$PATH" \
    mvn -f java/pom.xml -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true package
  # → core/auth/admin/keycloak-sdk 각 target/에 *-sources.jar / *-javadoc.jar 생성 확인
  ```
- 태그: `vX.Y.Z` — 안내 명령: `./scripts/release-trigger.sh java 0.1.0`
  ```bash
  git tag v0.1.0 && git push origin v0.1.0
  ```
  > ℹ️ 태그값이 **릴리스 버전을 결정**한다 — 원하는 릴리스 버전과 태그를 정확히 일치시킬 것.
- 배포 확인: GitHub Actions `release.yml` 성공(스테이징 업로드까지) 확인 → [Central Portal](https://central.sonatype.com) Deployments에서 검증 후 **사람이 수동 Publish**.
- 설치: `io.github.xzawed:keycloak-sdk:0.1.0` (+ BOM)

### 9. Kotlin

- 1회 설정: §2-A(시크릿 `SIGNING_IN_MEMORY_KEY`/`SIGNING_IN_MEMORY_KEY_PASSWORD`/`MAVEN_CENTRAL_USERNAME`/`MAVEN_CENTRAL_PASSWORD`).
- 버전 범프: `kotlin/build.gradle.kts` `version`(**수동** — Java와 달리 태그가 자동 주입하지 않는다. 태그값과 반드시 일치시켜 커밋).
- dry-run:
  ```bash
  export JAVA_HOME='/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot' PATH="/c/Users/dirtc/tools/gradle-9.6.1/bin:$PATH" GRADLE_USER_HOME="/c/Users/dirtc/.gradle"
  gradle -p kotlin publishToMavenLocal
  # → 로컬 ~/.m2에 keycloak-sdk-kotlin-0.1.0.jar(+sources/javadoc) 생성 확인
  ```
- 태그: `kotlin-vX.Y.Z` — 안내 명령: `./scripts/release-trigger.sh kotlin 0.1.0`
  ```bash
  git tag kotlin-v0.1.0 && git push origin kotlin-v0.1.0
  ```
- 배포 확인: GitHub Actions `kotlin-release.yml`(vanniktech `publishToMavenCentral`, Central Portal 스테이징) 성공 확인 → [Central Portal](https://central.sonatype.com) Deployments에서 **사람이 수동 Publish**(Java와 동일 2단계).
- 설치: `io.github.xzawed:keycloak-sdk-kotlin:0.1.0`

---

## §4. 릴리스 절차 요약

1. **버전 범프**(해당 언어가 수동 범프 대상이면 — §1 표 참조) — 커밋.
2. **dry-run** — 로컬에서 배포 없이 산출물 생성 확인(§3 해당 언어).
3. **`./scripts/release-readiness.sh <lang>`** — 시크릿·레지스트리·태그 준비상태 확인.
4. **`./scripts/release-trigger.sh <lang> <ver>`** — 버전 범프 안내·dry-run 명령·사전 점검·정확한 태그 명령을 출력(실행은 안 함).
5. **사람이 태그 push** — 출력된 `git tag ... && git push origin ...`를 그대로 복사해 실행.
6. **GitHub Actions 확인** — 해당 release 워크플로가 green으로 끝났는지 확인(§2-C의 .NET처럼 조용한 스킵에 주의).
7. **(Maven Central 계열만) Portal 수동 release** — Java·Kotlin은 Central Portal Deployments에서 사람이 Publish를 눌러야 최종 공개된다.

---

## §5. 공통 주의

- **버전 올릴 때**: §0 표 "버전 범프" 열의 정확한 파일·필드를 함께 올리고, 태그(§0 표 "태그" 열)를 그 버전에 맞춘다. 자동 범프 언어(go/php/dotnet/java)는 파일 수정이 필요 없다.
- **배포 후 좌표**: §0 표 "배포 후 설치" 열 참조. SemVer는 SDK 자체 API 기준이며 Keycloak/의존 라이브러리 버전과 분리한다(호환은 README 매트릭스로 안내).
- **release 워크플로는 이 문서의 대상이 아니다**: `.github/workflows/*-release.yml` 9개는 이미 검증된 상태이며, 이 문서와 `scripts/release-readiness.sh`/`scripts/release-trigger.sh`는 그 워크플로를 안내만 할 뿐 수정하지 않는다.
- **⚠️ 이름 충돌 주의**: `release-readiness.sh`가 `registry=published`(이미 게시됨)로 표시하더라도, 그것이 **타인이 먼저 등록한 동명 패키지**일 가능성을 배제하지 않는다(레지스트리 존재 확인은 HTTP 200 여부만 보는 것이지 소유권을 확인하지 않는다). 각 언어의 **첫 배포 전에는** 반드시 사람이 해당 레지스트리(PyPI `keycloak-sdk`, npm `@xzawed/keycloak-sdk`, crates.io `keycloak-sdk`, RubyGems `keycloak-sdk`, NuGet `Xzawed.Keycloak.Sdk`, Packagist `xzawed/keycloak-sdk` 등)에서 배포명이 **미점유 상태이거나 본인(`xzawed`) 소유**인지 직접 확인한다 — scoped 패키지(`@xzawed/keycloak-sdk`)나 groupId가 GitHub 계정에 귀속되는 Maven Central(`io.github.xzawed`)은 이름 충돌 위험이 낮지만, 짧고 일반적인 이름(`keycloak-sdk`)을 쓰는 PyPI/crates.io/RubyGems는 타인이 선점했을 가능성이 상대적으로 높다.
- **시크릿 값은 절대 조회/기록하지 않는다**: `release-readiness.sh`는 `gh secret list`로 이름·존재 여부만 확인하고 값은 절대 출력하지 않는다. 이 문서에도 실제 토큰·키 값을 기록하지 않는다.
