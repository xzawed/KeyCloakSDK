# 통합 배포 가이드 + 릴리스 도우미 설계 (9언어)

> **상태**: 설계(브레인스토밍 산출물). 승인 후 `writing-plans`로 구현 계획(WBS) 작성.

**목표(Goal):** 9개 언어 SDK의 실배포(로드맵 항목 A)를 "한 문서로 안내되는 체크리스트 + 2개 도우미"로 통합해, 배포자가 언어마다 흩어진 인증·태그·1회 설정을 헤매지 않고 정확한 명령을 따라가게 한다.

**아키텍처(Architecture):** (1) 단일 `DEPLOY.md` — 준비상태 매트릭스(대시보드) + 인증 모델별 그룹 + 9개 언어별 상세. (2) `scripts/release-readiness.sh` — 언어별 배포 준비상태(시크릿·레지스트리 존재·태그)를 실시간 리포트하는 읽기 전용 도우미. (3) `scripts/release-trigger.sh` — 언어·버전 입력 시 정확한 태그 push 명령 + 사전 점검 체크리스트를 **출력만** 하는 도우미(human-gate 유지, 자동 push 없음).

**기술 스택(Tech Stack):** Markdown(DEPLOY.md) · POSIX sh(도우미 2종, git-bash/Linux 공통) · `gh`(secret 조회) · `curl`(레지스트리 존재 확인) · `git`(태그 조회).

## 전역 제약(Global Constraints)

- **실배포는 사람 게이트**: 도우미는 태그를 **절대 push하지 않는다**(명령 출력만). 실제 배포 트리거는 사람이 수동으로 태그를 push해야 한다.
- **추측 금지**: DEPLOY.md의 모든 명령·시크릿명·태그포맷은 9개 release 워크플로 + 빌드설정에서 추출한 실측 사실(본 스펙 §2)만 사용한다.
- **되돌릴 수 없음**: 모든 레지스트리는 동일 버전 재배포 불가 — dry-run(무배포 로컬 검증)을 배포 전 필수 단계로 명시한다.
- **비밀 노출 금지**: 도우미는 시크릿 **존재 여부(set/unset)만** 보고하고 값은 절대 출력하지 않는다(`gh secret list`는 이름·갱신일만 반환).
- **문서 문체**: 기존 DEPLOY.md·CLAUDE.md의 한국어 기술문서 톤 유지.

---

## §1. 문제 정의 — 왜 A(실배포)가 복잡한가

- **7개 언어 배포 절차 미문서화**: 현재 `DEPLOY.md`(79줄)는 Java·Python 2개만 문서화. Node·Go·.NET·PHP·Rust·Ruby·Kotlin은 워크플로·CLAUDE.md에 흩어져 있다.
- **9가지 서로 다른 인증 모델**: maven-gpg(2) · OIDC(3) · api-token(2) · webhook(1) · none(1). 심지어 같은 maven-gpg인 Java·Kotlin도 **시크릿 이름이 다르다**.
- **9가지 태그 포맷 + 제각각 버전 범프**: 4개는 태그가 버전 SSOT(자동), 5개는 파일 수동 범프.
- **흩어진 1회성 설정**: 네임스페이스 검증·GPG키·pending-publisher 선등록·토큰 등록·저장소 등록 — 어디까지 했는지 추적 수단이 없다.

## §2. 9언어 배포 사실 레퍼런스 (실측 — DEPLOY.md의 진실 원천)

> 2026-07-09 병렬 추출(9 release 워크플로 + 빌드설정 + CLAUDE.md). DEPLOY.md 구현 시 이 표를 권위 소스로 채운다.

| 언어 | 레지스트리 | 인증 | 태그 | 버전 범프 | 시크릿(개수) | 배포 후 설치 |
|---|---|---|---|---|---|---|
| **Go** | 프록시(proxy.golang.org) | none | `go/v*` | 없음(태그=SSOT) | 0 | `go get github.com/xzawed/KeyCloakSDK/go@vX.Y.Z` |
| **PHP** | Packagist | webhook | `php-v*` | 없음(태그=SSOT) | 0(웹훅) | `composer require xzawed/keycloak-sdk` |
| **Rust** | crates.io | api-token | `rust-v*` | `rust/Cargo.toml` `[package].version` | 1(`CARGO_REGISTRY_TOKEN`·등록됨) | `cargo add keycloak-sdk` |
| **.NET** | NuGet | api-token | `dotnet-v*` | 없음(태그 `-p:Version` 주입) | 1(`NUGET_API_KEY`·미설정 시 조용히 스킵) | `dotnet add package Xzawed.Keycloak.Sdk` |
| **Python** | PyPI | OIDC | `py-v*` | `python/pyproject.toml` `[project].version` | 0(OIDC) | `pip install keycloak-sdk` |
| **Node** | npm | OIDC | `node-v*` | `node/package.json` `version` | 0(OIDC+provenance) | `npm install @xzawed/keycloak-sdk` |
| **Ruby** | RubyGems | OIDC | `ruby-v*` | `ruby/lib/keycloak_sdk/version.rb` `VERSION` | 0(OIDC+`release` 환경) | `gem install keycloak-sdk` |
| **Java** | Maven Central | maven-gpg | `v*` | 자동(versions-maven-plugin, 태그값) | 4(GPG 2 + Portal토큰 2) | `io.github.xzawed:keycloak-sdk` |
| **Kotlin** | Maven Central | maven-gpg | `kotlin-v*` | `kotlin/build.gradle.kts` `version`(수동) | 4(vanniktech 이름) | `io.github.xzawed:keycloak-sdk-kotlin` |

**시크릿 이름(정확)**:
- Java: `MAVEN_GPG_PRIVATE_KEY` · `MAVEN_GPG_PASSPHRASE` · `CENTRAL_TOKEN_USER` · `CENTRAL_TOKEN_PW`
- Kotlin: `MAVEN_CENTRAL_USERNAME` · `MAVEN_CENTRAL_PASSWORD` · `SIGNING_IN_MEMORY_KEY` · `SIGNING_IN_MEMORY_KEY_PASSWORD`
- .NET: `NUGET_API_KEY` · Rust: `CARGO_REGISTRY_TOKEN` · 나머지(Go/PHP/Python/Node/Ruby): 저장 시크릿 없음

**dry-run 명령(무배포 로컬 검증)** — 각 언어 툴체인 섹션(CLAUDE.md)의 명령을 그대로 사용:
- Go: `go -C go build/vet/test ./...` · PHP: `composer install && composer audit && phpstan && phpunit --testsuite unit` · Rust: `cargo build --all-targets && cargo test && clippy && fmt --check`(+ `cargo publish --dry-run`) · .NET: `dotnet pack src/...csproj -c Release` · Python: `python -m build` · Node: `npm run build && npm pack --dry-run` · Ruby: `gem build keycloak-sdk.gemspec` · Java: `mvn -f java/pom.xml -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true package` · Kotlin: `gradle -p kotlin publishToMavenLocal`

**핵심 게차(배포 특유)**:
- **Java·Kotlin**: Central Portal 스테이징까지만 자동 → **Portal 콘솔에서 사람이 수동 Publish**(2단계 승인). GPG 공개키를 키서버에 **먼저 배포**해야 서명 검증 통과. Java는 태그값→버전 자동치환(SNAPSHOT), Kotlin은 `build.gradle.kts` 버전 **수동** 커밋 필요.
- **OIDC 3종(Python·Node·Ruby)**: **pending-publisher 선등록 필수**(owner=xzawed/repo=KeyCloakSDK/workflow파일명/environment). Ruby는 gem이 존재해야 등록 가능한 **닭달걀**(최초 1회 API키 수동 게시 또는 UI 생성) + `release` GitHub Environment 필요. Node는 release 잡이 `npm install -g npm@latest`(OIDC는 npm≥11.5.1).
- **api-token 2종**: .NET은 `NUGET_API_KEY` 미설정 시 **조용히 스킵**(Release는 생성 — 부분실패 놓치기 쉬움). Rust는 미설정 시 **하드 실패**.
- **webhook(PHP)**: 워크플로는 게시 안 함 → Packagist가 웹훅으로 자동감지. **저장소 1회 등록** 선행(등록 전엔 태그 push해도 아무 일 없음).
- **none(Go)**: 무설정. 태그 `go/` 접두 필수(모노레포 서브모듈), 소비자는 전체 경로 `.../go@vX.Y.Z`.
- **공통**: 모든 release 워크플로는 `needs: verify` 게이트(태그 커밋이 lint/test green이 아니면 배포 안 됨). 5개 언어(Python/Node/Rust/Ruby/Kotlin)는 태그 push 전 **버전 파일 수동 범프** 필요.

## §3. `DEPLOY.md` 구조 (통합 문서)

```
# 배포 가이드 (DEPLOY)

§0 개요 + 준비상태 매트릭스
  - 위 §2 표(언어×레지스트리·인증·태그·버전범프·시크릿·설치좌표)
  - 권장 배포 순서(쉬운 것→어려운 것): Go → PHP → Rust → .NET → Python·Node·Ruby → Java·Kotlin
  - "지금 상태 확인: `./scripts/release-readiness.sh`" 안내

§1 공통 원칙
  - 태그 드리븐 · needs:verify 게이트 · human-gate · 되돌릴 수 없음 · dry-run 필수
  - 버전 범프 규칙(자동 4 vs 수동 5) 표

§2 인증 모델별 1회 설정 (반복 축소 — 같은 모델은 한 번만 설명)
  A. Maven Central + GPG (Java·Kotlin) — 네임스페이스 검증·GPG키 생성/키서버 배포·Portal 토큰·시크릿(이름은 언어별)·2단계 수동 release
  B. OIDC / Trusted Publisher (Python·Node·Ruby) — pending-publisher 선등록(값)·Ruby 닭달걀·release 환경
  C. API 토큰 (.NET·Rust) — 레지스트리 토큰 발급·GitHub Secret 등록
  D. 웹훅 (PHP) — Packagist 저장소 등록
  E. 무설정 (Go) — 없음

§3 언어별 상세 (9개, §0 권장순서로 정렬)
  각 언어: [1회 설정 참조(§2 그룹)] → [버전 범프 위치] → [dry-run] → [태그·트리거] → [배포 확인] → [설치 좌표]

§4 릴리스 절차(요약 플로우)
  1. 버전 범프(해당 언어) → 2. dry-run → 3. `release-readiness.sh <lang>` 확인 → 4. `release-trigger.sh <lang> <ver>`로 명령 확인 → 5. 사람이 태그 push → 6. Actions 확인 → 7. (Maven) Portal 수동 release

§5 공통 주의 (기존 유지·확장)
```

## §4. 도우미 1 — `scripts/release-readiness.sh`

**목적:** 언어별 배포 준비상태를 읽기 전용으로 리포트(무엇이 남았는지 한눈에).

**사용:** `./scripts/release-readiness.sh [lang ...]`(인자 없으면 9개 전부).

**언어별 점검 항목:**
1. **시크릿**: `gh secret list`로 그 언어의 필수 시크릿(§2)이 등록됐는지(이름 존재만 — 값 미출력). OIDC/none/webhook은 "시크릿 불필요" 표기 + OIDC는 "pending-publisher 등록은 수동 확인 필요"(API로 확인 불가) 안내.
2. **레지스트리 존재**: `curl -sfI`로 배포 후 좌표가 이미 게시됐는지(예: PyPI `https://pypi.org/pypi/keycloak-sdk/json`, npm `https://registry.npmjs.org/@xzawed%2Fkeycloak-sdk`, crates.io, RubyGems, NuGet, Packagist, Maven Central, Go 프록시). "미게시(첫 배포 대기)" / "게시됨 vX.Y.Z" 표기.
3. **태그**: `git tag -l '<fmt>'`로 그 언어의 릴리스 태그가 이미 있는지.
4. **종합 판정**: `✅ 준비완료(태그 push만)` / `⚠️ 설정 필요: <항목>` / `ℹ️ 수동 확인: <OIDC 등록>`.

**출력:** 언어별 1행 요약 표 + 상세. `gh` 미인증/`curl` 실패는 `?(확인불가)`로 격리(전체 중단 없음).

**멱등·안전:** 읽기 전용(어떤 상태도 변경 안 함). 시크릿 값 미노출.

## §5. 도우미 2 — `scripts/release-trigger.sh`

**목적:** 언어·버전 입력 시 **정확한 태그 push 명령 + 사전 점검 체크리스트**를 출력(자동 push 없음 — human-gate).

**사용:** `./scripts/release-trigger.sh <lang> <version>`(예: `./scripts/release-trigger.sh python 0.1.0`).

**동작(출력만, 실행 안 함):**
1. **입력 검증**: lang이 9개 중 하나인지, version이 semver(`X.Y.Z`)인지.
2. **버전 범프 안내**: 수동 범프 언어면 정확한 파일·필드(§2) + "현재 값 → 목표 값" 확인 안내. 자동 언어면 "태그가 버전 결정 — 파일 수정 불필요".
3. **dry-run 명령 출력**(§2).
4. **사전 점검 체크리스트**: `release-readiness.sh <lang>` 실행 권유 + 인증모델별 주의(예: OIDC "pending-publisher 등록 확인", Maven "Portal 수동 release 2단계 남음").
5. **정확한 태그 명령 출력**: `git tag <fmt-with-version> && git push origin <fmt-with-version>`(예: `git tag py-v0.1.0 && git push origin py-v0.1.0`). Go는 `go/vX.Y.Z` 접두 반영.
6. **배포 후 확인 안내**: Actions 워크플로 링크 + (해당 시) Portal 수동 release.

**절대 하지 않음:** `git tag`/`git push` **실행**. 출력은 사람이 복사해 실행할 명령 텍스트뿐.

## §6. 검증(테스트) 방법

실배포 없이 도우미를 검증한다:
- **release-trigger.sh**: 9개 언어 × 샘플 버전에 대해 출력이 §2의 정확한 태그·명령과 일치하는지(문자열 assert). 잘못된 lang/version 입력 시 에러+usage. **`git tag`/`push`가 호출되지 않음**을 보장(스크립트에 실제 실행 라인 부재 — grep으로 확인).
- **release-readiness.sh**: `gh`/`curl`/`git`을 모킹하거나 실제 호출로 스모크(읽기 전용이라 안전). 각 언어 행이 시크릿·레지스트리·태그 3필드를 출력하는지. `gh` 미인증 시 `?(확인불가)` 격리 확인.
- **DEPLOY.md**: 9개 언어 섹션 존재 + §2 표의 태그·시크릿·설치좌표가 실측과 일치(링크·명령 오탈자 검토).

## §7. 비목표(Non-goals)

- 실제 배포 실행·태그 push 자동화(사람 게이트 유지).
- release 워크플로(`.github/workflows/*-release.yml`) 수정(현 워크플로는 검증됨 — 문서·도우미만 추가).
- 9개 태그포맷/워크플로를 하나로 통합(별개 옵션 "배포 메커니즘 단순화"로 기각됨 — 언어별 인증 차이가 본질적).
- 최종 사용자 설치 안내 통합(별개 옵션 — 이번 범위 아님. 단 §2의 "배포 후 설치" 열이 최소 안내 제공).
