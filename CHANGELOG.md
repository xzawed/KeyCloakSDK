# Changelog

이 프로젝트의 주요 변경사항을 기록합니다. 형식은 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/)를 따르며, 버전은 [SemVer](https://semver.org/lang/ko/)를 지향합니다.

> 이 리포지토리는 **폴리글랏 SDK**입니다. Java(`io.github.xzawed:keycloak-sdk`)와 Python(`keycloak-sdk`)이 독립 배포되며, 아래 항목은 언어 태그로 구분합니다. 아직 어떤 언어도 정식 배포(태그 릴리스)되지 않았습니다 — 모든 항목은 `[Unreleased]`입니다.

## [Unreleased]

### Added
- **(Docs) Keycloak *서버* 배포 가이드 신설** — `docs/guides/deploying-keycloak-server.md`(단일 VM + Docker Compose 프로덕션: Keycloak 26.x + PostgreSQL + Caddy 자동 TLS, hostname/proxy-headers/health, 백업·업그레이드·SDK 연결). SDK는 클라이언트 라이브러리라 별도 Keycloak 서버가 필요하다는 흔한 혼란을 해소. getting-started·README에 링크. (2026-07-03)
- **(Docs) 설치/시작 가이드·언어 확장 로드맵·add-a-language 플레이북 신설 + README front door 재구성.** `docs/guides/getting-started.md`(언어별 요구 런타임·로컬/배포후 설치·최소 사용 예), `docs/roadmap/language-support.md`(depth-first 전략·step-0 실배포 체크리스트·우선순위 TS/Node→Go→C#→PHP→Rust→Ruby·현황 매트릭스), `docs/guides/add-a-language-playbook.md`(새 언어를 Java/Python 품질로 추가하는 6단계 표준 절차 + G1~G6 매핑). README는 상세 QuickStart를 시작 가이드로 이관하고 요약+딥링크만 남김. (2026-07-03)

### Changed
- **(Java) ⚠️ BREAKING — 요구 런타임을 JDK 17 → 21 LTS로 상향.** `maven.compiler.release=21` + enforcer `requireJavaVersion=[21,)`. 아티팩트는 `--release 21`로 컴파일되므로 **소비자도 JDK 21+에서 실행**해야 하며, 이전 JDK에서는 `UnsupportedClassVersionError`가 발생합니다. `maven-compiler-plugin`을 `3.11.0`으로 명시 고정(기본값 드리프트 방지). CI·릴리스 워크플로도 JDK 21 단일 사용. 소스·공개 API 무변경. (2026-07-03)

### Security
- **(Java) jackson-databind 계열 6종 `2.21.2` → `2.21.4`.** Dependabot 경보 7건(전부 jackson-databind, HIGH 2·MEDIUM 5) 대응. CVE-2026-54512/54513/54514/54516/54517/54518 **6건 해소**. CVE-2026-54515는 fix(2.21.5) 미출시로 버전 해결 불가이나, 다중에이전트 적대적 트리아지로 **7건 전부 이 SDK 사용맥락에서 악용 불가**로 판정(전이 전용·default typing 없음·신뢰된 Keycloak 응답만 고정 POJO로 역직렬화·JWT는 Nimbus) → `not_used`로 dismiss + 2.21.5 상향 트래킹([이슈 #8](https://github.com/xzawed/KeyCloakSDK/issues/8)). `jackson-annotations`는 별도 트랙·비취약이라 `2.21` 유지. 전체 근거: [`docs/governance/verification-log.md`](docs/governance/verification-log.md). (2026-07-03)
- **(Java) CI 보안 불변식 가드 추가.** SDK 소스가 Jackson default/polymorphic typing 활성화나 커스텀 JAX-RS Jackson provider 등록을 도입하지 못하도록 CI(`ci.yml` `invariant` 잡)에서 소스 스캔으로 강제 — 위 jackson-databind CVE 무위험 판정의 전제(불변식)를 회귀로부터 보호. (2026-07-03)

---

<!-- 릴리스 시: [Unreleased] 아래에 `## [x.y.z] - YYYY-MM-DD` 섹션을 만들고 해당 항목을 이동한다.
     Java 태그는 `v*`, Python 태그는 `py-v*`. -->
