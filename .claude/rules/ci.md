---
paths:
  - ".github/**"
  - "scripts/**"
  - "harness/**"
  - "DEPLOY.md"
---

# CI · 릴리스 · 하네스 규칙

루트 `CLAUDE.md`의 CI 게차 스텁이 가리키는 상세다. 언어별 CI 게차는 `.claude/rules/<lang>.md`에 있다.

## 저장소 룰셋 (서버 상태)

- ⚠️ **`main`은 룰셋 `PRIMARY`가 지킨다 — 정의는 `.github/rulesets/main.json`, 대조는 `node scripts/repo-config.mjs check`.** required 체크는 `doc-facts`·`shell-exec-bits` **둘뿐**이고 앞으로도 여기에 언어 CI를 넣으면 안 된다 — 언어 CI 9종은 워크플로 레벨 `paths:` 필터라 해당 경로를 안 건드리는 PR에서 체크가 **생성조차 되지 않아** required면 Pending 영구 차단이다(`bypass_actors: []`라 소유자도 못 푼다). 잡 레벨 `if:` skip은 반대로 체크가 생성돼 성공으로 인정된다 — 이 둘을 혼동하면 저장소가 잠긴다. 컨텍스트명 충돌 3쌍(`integration`=dotnet+php 등)과 `merge_group:` 트리거 부재(머지 큐 켜면 전부 데드락)도 함께 주의. 상세·해소 방안: [CONTRIBUTING.md §4](../../CONTRIBUTING.md)
- ⚠️ **태그 룰셋 3종도 2026-08-04부터 적용됐다 — `PRIMARY`와 달리 이쪽은 소유자 bypass가 있다.** `RELEASE-TAGS-CREATE`(비-Go 8개 접두 creation)·`RELEASE-TAGS-CREATE-GO`(`go/v*` creation)·`RELEASE-TAGS-IMMUTABLE`(9개 전부 update+deletion)이 전부 `enforcement: active`이고 셋 다 bypass가 `{"actor_id":5,"actor_type":"RepositoryRole"}`(admin)라 **사람이 손으로 태그를 미는 경로는 그대로 살아 있다**(적용 후 라이브 API로 확인). 막히는 것은 그 밖의 주체 — `contents: write` 자격증명이 임의로 릴리스 태그를 만드는 경로다. ⚠️ **`tags-create.json`의 bypass에 GitHub App(Integration)을 추가하는 것은 아직 남았다**(App이 없어 `actor_id`를 모른다) — 그때까지 `dispatch-release.yml`은 태그를 만들지 못하고 fail-closed다. 추가는 **`tags-create.json`에만** 한다(나머지 둘에 넣으면 Go 예외와 태그 불변성의 유일한 서버측 집행 지점이 무너진다). ⚠️ 웹 UI로 룰셋을 비활성화해도 **CI에서는 아무도 보고하지 않는다**(CI는 `check`가 아니라 가드 자가테스트를 돌린다 — admin 토큰 미보관). 웹 UI로 저장소 규칙을 건드렸다면 로컬에서 `check`를 다시 돌릴 것.

## 릴리스 워크플로

- ⚠️ **배포 시크릿 미설정은 "스킵"이 아니라 실패여야 한다.** 아무것도 게시하지 않고 green으로 끝난 실행은 성공한 실행과 구분되지 않아, 태그가 밀리고 GitHub Release까지 만들어졌는데 레지스트리에는 아무것도 없는 상태가 조용히 성립한다. 두 곳이 그랬다 — `dotnet-release.yml`은 `NUGET_API_KEY` 미설정 시 `exit 0`(Release는 그대로 생성), `kotlin-release.yml`은 4개 시크릿 중 **username 하나만** 검사해 서명키 없이도 통과 → **서명 없는 아티팩트가 Central Portal에 업로드될 수 있었다**. 지금은 둘 다 `::error::`+`exit 1`이고 kotlin은 누락된 시크릿 이름을 전부 나열한다. 같은 원칙으로 `dotnet nuget push`의 `--skip-duplicate`도 제거했다(이미 태워버린 버전을 성공으로 위장하므로). ⚠️ GitHub Actions는 job-level `if:`에 secrets 컨텍스트를 노출하지 않으므로 이 가드는 반드시 **스텝 안에서 env-매핑된 값**으로 해야 실제로 동작한다.

## Dependabot

- ⚠️ **Dependabot 트리거 run에는 Actions 시크릿이 노출 안 됨**(별도 스토어, 이 저장소는 비어있음) — `SONAR_TOKEN`이 빈 문자열로 보간돼 SonarCloud가 반드시 실패(코드 신호 아님). `sonarcloud.yml`은 Dependabot PR만 skip(push는 항상 통과, main 스캔 스킵 불가 — PR0 fail-closed 불변). 토큰 복제안은 기각(미검토 패키지 코드가 토큰과 같은 잡에서 실행됨 우려).
- ⚠️ **dependabot이 자동으로 올려서는 안 되는 핀이 두 종류 있다 — `.github/dependabot.yml`의 `ignore`가 근거와 함께 막는다.** (1) **ref 이름이 곧 의미인 액션**: `dtolnay/rust-toolchain`의 핀은 `stable` **브랜치** 헤드 SHA인데 dependabot은 `# stable` 주석을 semver 태그로만 읽어 기본 브랜치(master) 헤드로 갈아끼운다 — master 커밋에는 toolchain을 고를 ref 이름이 없어 액션이 `'toolchain' is a required input`으로 즉사한다(PR #111에서 rust 잡 3종 동시 실패). 올릴 때는 `gh api repos/dtolnay/rust-toolchain/branches/stable --jq .commit.sha`로 브랜치 헤드를 직접 확인한다. `taiki-e/install-action`은 ref가 **태그**(`cargo-llvm-cov`)라 dependabot이 손대지 않아 ignore 대상이 아니다. (2) **소비자 하한을 나타내는 버전**: `kotlin-stdlib`는 게시 아티팩트의 소비자 하한이라 `languageVersion`/`apiVersion`(=KOTLIN_2_2)과 **함께** 움직여야 하며, 마이너/메이저만 올라가면 메타데이터와 전이 요구가 조용히 갈라진다(PR #110 — `d6f1729`가 고친 상태로 회귀). 패치는 허용, 마이너/메이저는 차단.

## 로컬 ↔ CI 발산

- ⚠️ **하드닝 CI 게차**: Go `gofmt`·Node `prettier`·PHP `cs-fixer`는 Windows CRLF 워킹트리를 전부 flag(변경파일 LF-정규화 후 재확인) · 전역상태 테스트(Ruby rack-oauth2)는 flaky라 config 훅 mock 검증 · pip-audit는 editable skip에도 exit1(→ `pip freeze --exclude-editable`+`-r`) · SonarCloud "0% Coverage on New Code"는 Kotlin kover만 피드해 비-Kotlin PR마다 fail(비차단·UNSTABLE).
- ⚠️ **java jacoco:check는 `verify` 페이즈 바인딩 — 로컬 `mvn test`로는 커버리지 게이트 미검증**(반드시 `mvn -pl … -am verify -DskipITs`). PR #71에서 `forRealm`에 `.rateLimited()` 1줄이 auth번들을 0.90→0.89로 떨어뜨려 CI 3잡 동시실패 — `JWKSourceBuilder` 지연특성 이용한 네트워크-프리 `forRealm` 단위테스트로 복원.

## 하네스 컨테이너

- ⚠️ **앱/레지스트리 전 컨테이너가 Alpine(musl) 베이스다.** Debian/glibc는 Docker Desktop(Windows) 내장 DNS프록시가 레지스트리 CNAME체인을 glibc 리졸버에 실패로 돌려줘 `dotnet restore`/`pip install`/Maven·npm 다운로드가 막힌다(musl은 정상, CI 네이티브 Docker 무해). install harness에서 재확인된 같은 근거다.
- ⚠️ **잔여 follow-up(marginal·미착수)**: go 공개프록시 폴스루(현 file-first 체인 정상동작). **해소된 항목 둘은 목록에서 뺐다** — (a) rust closure의 `Cargo.lock` 커밋은 라이브러리 핀 완화의 재현성 근거로 `rust/Cargo.lock`이 저장소에 커밋됐고, (b) wait_healthy 크래시 조기감지는 `967d1ce`가 구현했다(`harness/install/lib.sh`의 `wait_healthy`가 `docker inspect`로 컨테이너 종료를 감지하면 남은 타임아웃을 태우지 않고 exit code + 마지막 로그 40줄과 함께 즉시 실패한다 — 단 컨테이너가 아직 안 생긴 경합은 판단 보류로 계속 대기한다).
