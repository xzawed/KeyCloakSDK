# 문서 지도 (Documentation Map)

> **Looking for user documentation?** It is in English and lives in [`guides/`](guides/) — start with
> [Getting Started](guides/getting-started.md). The rest of this directory is the project's internal
> record (design specs, implementation plans, verification logs) and is written in Korean.

이 저장소의 `docs/` 아래 문서 **전부**를 한 곳에서 본다. 각 줄의 마지막 칸이 이 지도의 존재 이유다 —
**"여기서만 알 수 있는 것"**, 즉 그 문서를 열지 않으면 어디서도 얻을 수 없는 정보다. 다른 문서에도
있는 내용이라면 그 칸은 비어 있어야 하고, 비어 있어야 할 줄이 많아지면 문서를 합쳐야 한다는 신호다.

**상태 표기**

| 표기 | 뜻 |
|---|---|
| 운영 | 지금도 갱신되는 살아있는 문서. 낡으면 고친다. |
| 완료 | 끝난 작업의 **기록**. 갱신하지 않는다 — 지금 상태는 [CLAUDE.md](../CLAUDE.md)와 [history.md](governance/history.md)에 있다. |
| 진행 | 아직 열려 있는 작업. 체크박스가 실제 할 일이다. |

⚠️ **완료 문서의 체크박스는 할 일이 아니다.** 계획서(WBS)들은 실행 당시 체크박스가 갱신되지 않아
**전부 미체크로 남아 있다**. 각 파일 상단의 완료 배너가 이를 명시하며, `scripts/check-docs.mjs`가
배너 누락을 잡는다. 계획서를 열었을 때 배너부터 읽어라.

---

## 1. 사용자 문서 (영문)

SDK를 **쓰는** 사람을 위한 문서다. 영문으로 유지하며 한글 미러를 두지 않는다.

| 문서 | 상태 | 여기서만 알 수 있는 것 |
|---|---|---|
| [Getting Started](guides/getting-started.md) | 운영 | 언어마다의 설치 → 토큰 발급 → JWT 검증 → Admin 호출 30줄 퀵스타트. **stock realm에서 2단계 `validate()`가 왜 실패하는지**(`aud`에 client id가 없다)와 두 가지 해법. |
| [Development environment setup](guides/development-setup.md) | 운영 | 새 PC에서 언어별 툴체인을 세우는 절차와 `KCSDK_TOOLS`·`KCSDK_JDK21`·`KCSDK_PY` 환경변수 규약 — 저장소에 특정 PC 경로를 못박지 않기 위한 간접층. `node scripts/doctor.mjs`의 사용법. |
| [Deploying a Keycloak server](guides/deploying-keycloak-server.md) | 운영 | SDK가 아니라 **상대편 서버**를 세우는 법 — 단일 VM + Docker Compose + Caddy 자동 TLS 프로덕션 구성. |
| [Add-a-language playbook](guides/add-a-language-playbook.md) | 운영 | 10번째 언어를 추가할 때 밟는 순서. **코드 생성기도 저품질 티어도 두지 않는다**는 depth-first 원칙과 그 이유. |
| [Language support roadmap](roadmap/language-support.md) | 운영 | 다음에 어떤 언어를, 왜 그 순서로 하는지. 채택/기각된 후보와 판단 근거. |

## 2. 거버넌스 · 검증 기록

무엇을 어떻게 검증했는지의 **감사 추적**이다. 언어별 로그는 append-only로, 과거 항목을 고치지 않는다.

| 문서 | 상태 | 여기서만 알 수 있는 것 |
|---|---|---|
| [AI 거버넌스 프레임워크](governance/ai-governance-framework.md) | 운영 | 이 프로젝트의 작업 규약 — 정량 품질 게이트, 이중검증, 미달 시 루프 엔지니어링. **모든 검증 로그가 이 문서의 기준을 참조한다.** |
| [구현 이력](governance/history.md) | 운영 | 각 언어가 어떤 PR로 어떤 순서로 들어왔는지. `CLAUDE.md`에서 분리해 나온 서사(삭제가 아니라 이관). |
| [감사 재판정 로그 (2026-07-16)](governance/audit-readjudication-2026-07-16.md) | 완료 | 감사에서 **미판정으로 남았던 24건**을 하드닝 완료 후 24-에이전트로 재판정한 결과. 어떤 findings가 왜 기각됐는지. |
| [검증 로그 — Java](governance/verification-log.md) | 운영 | Java SDK 태스크별 정량 검증 기록 + **jackson-databind 핀 이력**(2.21.2→2.21.4→2.21.5→2.22.1)과 각 CVE 대응 근거. |
| [검증 로그 — Python](governance/verification-log-python.md) | 운영 | Python SDK 태스크별 검증 + async 미러 추가 경위. |
| [검증 로그 — Node](governance/verification-log-node.md) | 운영 | Node SDK 태스크별 검증 — admin-client 버전을 `^26`에서 `~26.6.4`로 좁혔다가 provider 배선으로 근본 차단한 뒤 되돌린 경위. |
| [검증 로그 — Go](governance/verification-log-go.md) | 운영 | Go SDK 태스크별 검증 — 단일 패키지 결정과 gocloak 오류 분류(`Code==0`)를 확정하기까지의 기록. |
| [검증 로그 — .NET](governance/verification-log-dotnet.md) | 운영 | .NET SDK 태스크별 검증 — coverlet msbuild 통합이 히트 flush 유실로 `0%`를 만들어 컬렉터+자체 가드로 전환한 경위. |
| [검증 로그 — PHP](governance/verification-log-php.md) | 운영 | PHP SDK 태스크별 검증 — Testcontainers 대신 docker CLI 셸아웃으로 간 이유(Windows native PHP의 `unix://` 미지원). |
| [검증 로그 — Rust](governance/verification-log-rust.md) | 운영 | Rust SDK 태스크별 검증 — typestate 제네릭·reqwest 메이저 정렬·MSRV 판단이 확정되기까지의 과정. |
| [검증 로그 — Ruby](governance/verification-log-ruby.md) | 운영 | Ruby SDK 태스크별 검증 — admin gem 부재를 확인하고 faraday 직접 래핑으로 전환하기까지의 판단. |
| [검증 로그 — Kotlin](governance/verification-log-kotlin.md) | 운영 | Kotlin SDK 태스크별 검증 — MockK가 JAX-RS 추상클래스에서 JDK21 무한 hang을 일으킨 진단과 우회. |

## 3. 설계 스펙 (`superpowers/specs/`)

**무엇을 왜 그렇게 만들기로 했는가.** 대안을 어떤 근거로 기각했는지가 여기에만 있다.

| 문서 | 날짜 | 상태 | 여기서만 알 수 있는 것 |
|---|---|---|---|
| [다국어 SDK 설계](superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md) | 07-02 | 완료 | **§4 언어 중립 계약의 원본.** 아홉 언어가 전부 이 문서를 진실 원천으로 삼는다 — 계층·오류 계급·`TokenSet`/`ValidatedToken` 개념이 여기서 정의됐다. |
| [Python SDK 설계](superpowers/specs/2026-07-03-keycloak-python-sdk-design.md) | 07-03 | 완료 | `python-keycloak` 래핑 + `joserfc` 자체 검증을 고른 이유. |
| [Python async 변형 설계](superpowers/specs/2026-07-03-keycloak-python-async-design.md) | 07-03 | 완료 | sync API를 **건드리지 않고** `aio/` 미러를 순수 추가하기로 한 근거와 `a_*` 짝 활용. |
| [문서 & 언어 확장 전략](superpowers/specs/2026-07-03-keycloak-docs-and-language-expansion-design.md) | 07-03 | 완료 | 설치 경로 문서화와 언어 확장을 **한 스펙으로 묶은** 이유. |
| [Node SDK 설계](superpowers/specs/2026-07-04-keycloak-node-sdk-design.md) | 07-04 | 완료 | `openid-client` v6 함수형 API + 공식 admin-client 조합 선택 근거. |
| [Go SDK 설계](superpowers/specs/2026-07-04-keycloak-go-sdk-design.md) | 07-04 | 완료 | **전체를 단일 `package keycloak`으로 둔 이유** — admin을 서브패키지로 하면 `Client.Admin`이 import 순환을 만든다. `go-oidc`를 제외한 근거. |
| [.NET SDK 설계](superpowers/specs/2026-07-04-keycloak-dotnet-sdk-design.md) | 07-04 | 완료 | `Keycloak.AuthServices.Sdk` + `Duende.IdentityModel` 조합과 `IHttpClientFactory` **미채택** 근거. |
| [가상사용자 테스트 하네스 설계](superpowers/specs/2026-07-05-virtual-user-test-harness-design.md) | 07-05 | 완료 | 실배포가 사람 게이트로 막혀 있을 때 **대신 무엇을 검증할 것인가** — 프로덕션-유사 환경 실측이라는 답. |
| [하네스 5개 언어 확장 설계](superpowers/specs/2026-07-05-harness-language-expansion-design.md) | 07-05 | 완료 | MVP(Go 앱 하나)에서 5개 언어로 넓힐 때의 구조 결정. |
| [PHP SDK 설계](superpowers/specs/2026-07-06-keycloak-php-sdk-design.md) | 07-06 | 완료 | `jumbojett/openid-connect-php`를 **기각한 이유**(세션 슈퍼글로벌·`header()` 리다이렉트 자체 소유). |
| [Rust SDK 설계](superpowers/specs/2026-07-06-keycloak-rust-sdk-design.md) | 07-06 | 완료 | `keycloak` crate와 `openidconnect`의 **reqwest 메이저 정렬** 문제와 typestate 제네릭 대응. |
| [Ruby SDK 설계](superpowers/specs/2026-07-06-keycloak-ruby-sdk-design.md) | 07-06 | 완료 | admin gem 후보 **셋을 전부 기각한 근거**(공유 `TokenProvider` 주입 미지원 = §4 캐싱 불변식 위반) — 그래서 faraday 직접 래핑. |
| [Kotlin SDK 설계](superpowers/specs/2026-07-07-keycloak-kotlin-sdk-design.md) | 07-07 | 완료 | "언어마다 가장 좋은 기반"의 JVM 사례 — 새 클라이언트가 아니라 **자매 Java SDK와 동일 라이브러리** 재사용. |
| [Kotlin 리서치 부록](superpowers/specs/2026-07-07-keycloak-kotlin-sdk-research.md) | 07-07 | 완료 | Gradle/KGP 설정의 권위 소스 원문 — 설계 결정의 근거 인용 모음. |
| [교차언어 검증·점수 하네스 설계](superpowers/specs/2026-07-07-cross-language-verification-scoring-harness-design.md) | 07-07 | 완료 | 기존 하네스가 **5개 언어·얇은 계약**만 커버한다는 진단과 8개 언어로 넓히는 설계. |
| [설치·동작 검증 하네스 설계](superpowers/specs/2026-07-07-install-operate-harness-design.md) | 07-07 | 완료 | **소스 경로 소비 ≠ 설치 소비.** 레지스트리 게시 없이 "설치해서 쓴다"를 검증하는 방법(로컬 레지스트리). |
| [설치 레시피 리서치 부록](superpowers/specs/2026-07-07-install-recipes-research.md) | 07-07 | 완료 | 언어별 로컬 레지스트리(Verdaccio·devpi·BaGet·Athens 등)를 무엇으로 세울지 고른 조사 원문 — 채택·기각 근거가 여기에만 있다. |
| [통합 배포 가이드 설계](superpowers/specs/2026-07-09-unified-deploy-guide-design.md) | 07-09 | 완료 | 언어별 배포를 **한 문서**로 묶는 구조와 릴리스 도우미 스크립트의 역할 분담. |
| [최종 종합 감사 보고서](superpowers/specs/2026-07-10-audit-report.md) | 07-10 | 완료 | **확정 결함 48건**(HIGH 9·MEDIUM 28·LOW 11)의 원본 목록 + 오탐 15건. 지금 코드의 하드닝 대부분이 여기서 나왔다. |
| [배포 전 하드닝 설계](superpowers/specs/2026-07-10-pre-release-hardening-design.md) | 07-10 | 완료 | 감사 결과를 PR 단위로 쪼갠 설계 — "CI가 초록인데도 드러난 두 가지". |
| [문서 구조 재편 설계](superpowers/specs/2026-07-23-docs-restructure-design.md) | 07-23 | 완료 | `CLAUDE.md`를 왜 쪼갰는지 + **doc-guard 앵커 기법의 원본 설계**. 순수 서사와 툴체인 블록을 분리해 센 측정 방법. |
| [배포 전 감사 잔여분 해소 설계](superpowers/specs/2026-07-31-pre-release-audit-remediation.md) | 07-31 | 완료 | PR #115가 **다루지 않은** 잔여분의 범위 정의 — 무엇이 남았고 왜 남았는지. |
| [릴리스 자동화 설계](superpowers/specs/2026-08-03-release-automation-design.md) | 08-03 | 완료 | 사람 승인을 **없애지 않고 옮기는** 설계 — 태그 push가 아니라 릴리스 PR 머지가 게이트가 된다. Go가 자동화에서 빠지는 이유. |

## 4. 구현 계획 / WBS (`superpowers/plans/`)

**어떤 순서로 무엇을 했는가.** 태스크 단위 실행 기록이다.

⚠️ 아래 문서의 체크박스는 **전부 미체크지만 할 일이 아니다** — 위 상태 표기 설명을 보라.

| 문서 | 날짜 | 상태 | 여기서만 알 수 있는 것 |
|---|---|---|---|
| [Java SDK WBS](superpowers/plans/2026-07-02-keycloak-java-sdk-wbs.md) | 07-02 | 완료 | 첫 언어의 태스크 분해 — 이후 모든 언어의 WBS가 전부 이 형식을 따랐다. Java 17 기준 시점의 스택(이후 21로 상향). |
| [Python SDK WBS](superpowers/plans/2026-07-03-keycloak-python-sdk-wbs.md) | 07-03 | 완료 | 23개 태스크 — 두 번째 언어라 "동형이란 무엇인가"를 처음으로 실제 코드에 맞춰 정의해야 했던 분해다. |
| [Python async WBS](superpowers/plans/2026-07-03-keycloak-python-async-wbs.md) | 07-03 | 완료 | sync API를 한 줄도 건드리지 않고 `keycloak_sdk.aio`를 **완전 대칭**으로 덧붙이는 분해(python-keycloak `a_*` 짝 활용). |
| [문서 & 언어 확장 WBS](superpowers/plans/2026-07-03-keycloak-docs-and-language-expansion-wbs.md) | 07-03 | 완료 | 5개 태스크 — 설치 가이드와 언어 확장 **플레이북·로드맵**을 한 묶음으로 만든 분해(지금의 add-a-language-playbook이 여기서 나왔다). |
| [Node SDK WBS](superpowers/plans/2026-07-04-keycloak-node-sdk-wbs.md) | 07-04 | 완료 | 12개 태스크 — ESM-only·async-only를 전제로 잡고 시작한 첫 언어의 분해. |
| [Go SDK WBS](superpowers/plans/2026-07-04-keycloak-go-sdk-wbs.md) | 07-04 | 완료 | 12개 태스크 — 예외가 없는 언어에서 §4 오류 계층을 어떻게 표현할지(센티넬 + `errors.As`)를 정한 분해. |
| [.NET SDK WBS](superpowers/plans/2026-07-04-keycloak-dotnet-sdk-wbs.md) | 07-04 | 완료 | .NET 구현 태스크 분해 — `docs/` 아래 최대 `.md`(118 KB). 타입드 admin 커버리지 공백을 raw REST로 메우는 결정이 여기서 나왔다. |
| [하네스 MVP WBS](superpowers/plans/2026-07-05-virtual-user-test-harness-mvp.md) | 07-05 | 완료 | Go 앱 하나로 전체 파이프라인(Keycloak→앱→k6→리포트→CI)을 실증한 태스크 분해. |
| [하네스 언어 확장 WBS](superpowers/plans/2026-07-05-harness-language-expansion.md) | 07-05 | 완료 | 샘플 앱 4종을 **동일 HTTP 계약**으로 맞춰 `./run.sh` 한 줄로 기능 정확성(checks==1.00)을 강제하게 만든 분해. |
| [PHP SDK WBS](superpowers/plans/2026-07-06-keycloak-php-sdk-wbs.md) | 07-06 | 완료 | 12개 태스크 — PHPStan level max를 처음부터 게이트로 걸고 간 분해. |
| [Rust SDK WBS](superpowers/plans/2026-07-06-keycloak-rust-sdk-wbs.md) | 07-06 | 완료 | 12개 태스크 — `clippy -D warnings`·`cargo-llvm-cov`를 게이트로 건 분해. admin 캐싱 provider 결정은 최종리뷰에서야 나왔다. |
| [Ruby SDK WBS](superpowers/plans/2026-07-06-keycloak-ruby-sdk-wbs.md) | 07-06 | 완료 | Ruby 구현 태스크 분해 + **말미의 2026-08-05 정정 블록** — RubyGems Trusted Publisher는 npm과 달리 gem이 없어도 pending으로 먼저 등록된다(원래 지시가 틀렸다). |
| [Kotlin SDK WBS](superpowers/plans/2026-07-07-keycloak-kotlin-sdk-wbs.md) | 07-07 | 완료 | 새 라이브러리를 하나도 들이지 않고(자매 Java SDK 스택 재사용) 코루틴 경계만 새로 만드는 분해 — 신규 리스크 0을 설계로 확보했다. |
| [설치·동작 하네스 WBS](superpowers/plans/2026-07-07-install-operate-harness-wbs.md) | 07-07 | 완료 | 언어별 로컬 레지스트리 + 설치 소비 검증 태스크 분해 — **소스 경로 소비 ≠ 설치 소비**를 실증한다. |
| [검증·점수 하네스 WBS](superpowers/plans/2026-07-07-verification-scoring-harness-wbs.md) | 07-07 | 완료 | 12개 태스크 — **4차원 가중 스코어링**(기능30/보안30/커버리지20/성능·동형성20)의 가중치가 정해진 곳. |
| [통합 배포 가이드 WBS](superpowers/plans/2026-07-09-unified-deploy-guide-wbs.md) | 07-09 | 완료 | `DEPLOY.md`와 릴리스 도우미 두 스크립트를 만든 태스크 분해. |
| [PR 0 검증 게이트 계획](superpowers/plans/2026-07-10-pr0-verification-gates.md) | 07-10 | 완료 | **"게이트를 진짜로 만들기"** — 통과만 하던 게이트를 실제로 거부하게 무장한 작업. |
| [PR 0 기준선 관측](superpowers/plans/2026-07-10-pr0-baseline-observation.md) | 07-10 | 완료 | 게이트 무장 **직후** 하네스가 실제로 무엇을 보고했는지의 실행 기록(잡별 결과). |
| [PR 0 변이 증명](superpowers/plans/2026-07-10-pr0-mutation-proof.md) | 07-10 | 완료 | **각 게이트를 고의로 깨뜨려 거부를 확인한 기록.** 이 저장소의 변이검증 규율이 시작된 지점. |
| [문서 구조 재편 WBS](superpowers/plans/2026-07-23-docs-restructure-wbs.md) | 07-23 | 완료 | `.claude/rules/<lang>.md` 분리와 `check-docs.mjs` 도입 태스크 분해. |
| [감사 잔여분 해소 WBS](superpowers/plans/2026-07-31-pre-release-audit-remediation-wbs.md) | 07-31 | 완료 | 언어별 공격 프로브·리다이렉트 차단·버전 SSOT의 태스크 분해 + **"해소됨"이라 썼다가 사실이 아님을 확인하고 정정한 기록**(2026-08-04) — 한 커밋에 담겼다는 이유만으로 별개 문제(admin 능력 갭 ↔ 리다이렉트 시임)를 함께 해소된 것처럼 적었고, 그 줄이 인계 메모를 3일간 덮었다. **문서의 자기보고를 믿지 말고 산출물을 대조하라**는 이 저장소의 규율이 여기서 나왔다. |
| [릴리스 자동화 계획](superpowers/plans/2026-08-03-release-automation.md) | 08-03 | 완료 | 디스패처·ref 가드·룰셋 3종 태스크 분해. 자동화를 **켜는** 절차는 여기가 아니라 [DEPLOY.md](../DEPLOY.md) §2-F에 있다(계획서의 미체크 항목으로만 남아 있던 것을 옮겼다). |
| [하네스 판정·출처 완결 계획](superpowers/plans/2026-08-12-harness-judgment-and-provenance-completion.md) | 08-12 | 진행 | 판정 층(`install-matrix.mjs`)·관측 층(`consume/*-run.sh`)·가드 층(`scripts/test/*`) 3계층을 순서대로 고치는 분해 — Phase A만 반영됐고 Phase B~E는 아직이다. ⚠️ S-B1(dotnet 레그 실패)은 git-ignored 로컬 산출물을 CI 상태로 오독한 것이라 **틀렸다**(문서 감사 후속 계획 참고). |
| [문서 전수 감사 후속](superpowers/plans/2026-08-12-doc-audit-remediation.md) | 08-12 | 진행 | 95개 문서 감사(확정 138·반증 9)의 로트별 점수와 후속 조치. **확정 결함의 대부분은 "아무도 안 본 자리"가 아니라 "가드가 있는데 그 자리를 안 겨눈" 자리**였다는 것과, 다른 PC에서 이어받을 때 필요한 환경 게차(로컬 스크래치를 CI 상태로 오독하는 함정 등)가 여기에만 있다. |

---

## 이 지도의 유지

`scripts/check-docs.mjs`(검사 9)가 **양방향**으로 대조한다:

- `docs/**/*.md` 중 이 지도에 링크되지 않은 파일이 있으면 실패 — 문서를 추가하고 지도에 안 넣는 것을 막는다.
- 이 지도의 링크가 존재하지 않는 파일을 가리키면 실패 — 문서를 지우거나 옮기고 지도를 안 고치는 것을 막는다.

한쪽만 검사하면 반대 방향 드리프트가 그대로 통과한다. 새 문서를 넣을 때는 **마지막 칸을 반드시
채워라** — 채울 말이 없다면 그 문서는 기존 문서에 합쳐야 한다는 뜻이다.
