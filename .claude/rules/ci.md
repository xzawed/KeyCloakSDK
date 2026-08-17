---
paths:
  - ".github/**"
  - "scripts/**"
  - "harness/**"
  - "DEPLOY.md"
---

# CI · 릴리스 · 하네스 규칙

언어별 CI 게차는 `.claude/rules/<lang>.md`에 있다.

## 저장소 룰셋

정의는 `.github/rulesets/*.json`(커밋된 JSON이 SSOT), 대조는 `node scripts/repo-config.mjs check`.

- ⚠️ **`main`의 required 체크는 `doc-facts`·`shell-exec-bits` 둘뿐이고 여기에 언어 CI를 넣으면 저장소가 잠긴다.** 언어 CI 9종은 워크플로 레벨 `paths:` 필터라 해당 경로를 안 건드리는 PR에서는 체크가 **생성조차 되지 않아** Pending으로 영구 차단된다(`bypass_actors: []`라 소유자도 못 푼다). 잡 레벨 `if:` skip은 반대로 체크가 생성돼 성공으로 인정된다 — **이 둘을 혼동하지 말 것.**
- 함께 주의: 컨텍스트명 충돌 3쌍(`integration` = dotnet + php 등), `merge_group:` 트리거 부재(머지 큐를 켜면 전부 데드락). 해소 방안은 [CONTRIBUTING.md §4](../../CONTRIBUTING.md).
- **태그 룰셋 3종**(`RELEASE-TAGS-CREATE` · `-CREATE-GO` · `-IMMUTABLE`)은 active이되 admin bypass가 있어 **사람이 손으로 태그를 미는 경로는 살아 있다**. 막는 대상은 `contents: write` 자격증명이 임의로 릴리스 태그를 만드는 경로다.
- ⚠️ **태그 커팅 App은 `tags-create.json`에만 둔다.** 나머지 둘에 넣으면 Go 예외와 태그 불변성의 유일한 서버측 집행 지점이 무너진다. `scripts/test/test-repo-config.sh`가 세 파일의 Integration bypass 개수를 **1/0/0**으로 고정한다.
- ⚠️ 웹 UI로 룰셋을 바꾸면 **CI는 아무것도 보고하지 않는다**(CI는 가드 자가테스트만 돌린다 — admin 토큰 미보관). 웹 UI를 건드렸으면 로컬에서 `repo-config.mjs check`를 다시 돌린다.

## 릴리스

- ⚠️ **배포 시크릿 미설정은 스킵이 아니라 실패다.** 아무것도 게시하지 않고 green으로 끝난 실행은 성공한 실행과 구분되지 않아, 태그·Release는 있는데 레지스트리는 빈 상태가 조용히 성립한다. 같은 이유로 `dotnet nuget push --skip-duplicate`도 쓰지 않는다(이미 태워버린 버전을 성공으로 위장한다).
- ⚠️ **이 가드는 스텝 안에서 env-매핑된 값으로 해야 동작한다** — job-level `if:`는 secrets 컨텍스트를 읽지 못한다.

## Dependabot

- ⚠️ **Dependabot 트리거 run에는 Actions 시크릿이 없다** — `SONAR_TOKEN`이 빈 문자열이 되어 SonarCloud가 반드시 실패한다(코드 신호가 아니다). `sonarcloud.yml`은 Dependabot PR만 skip한다. 토큰 복제안은 기각됐다(미검토 패키지 코드가 토큰과 같은 잡에서 돈다).
- ⚠️ **dependabot이 올려서는 안 되는 핀 두 종류** — `.github/dependabot.yml`의 `ignore`가 근거와 함께 막는다.
  1. **ref 이름이 곧 의미인 액션.** `dtolnay/rust-toolchain`의 핀은 `stable` **브랜치** 헤드 SHA인데 dependabot은 기본 브랜치 헤드로 갈아끼워 `'toolchain' is a required input`으로 즉사한다. `pypa/gh-action-pypi-publish`는 더 나쁘다 — 기본 브랜치가 `unstable/v1`이라 죽는 대신 **PyPI 게시가 unstable 채널로 조용히 넘어간다**. 올릴 때는 `gh api repos/<owner>/<repo>/branches/<branch> --jq .commit.sha`로 브랜치 헤드를 직접 확인한다.
  2. **소비자 하한을 나타내는 버전.** `kotlin-stdlib`는 게시 아티팩트의 소비자 하한이라 `languageVersion`/`apiVersion`과 **함께** 움직여야 한다. 패치는 받고 마이너/메이저는 차단한다.

## 로컬 ↔ CI 발산

- 포매터가 Windows CRLF 워킹트리를 전부 flag한다(Go `gofmt` · Node `prettier` · PHP `cs-fixer`) — 변경 파일을 LF로 정규화한 뒤 재확인한다.
- `pip-audit`는 editable skip에도 exit 1 → `pip freeze --exclude-editable` + `-r`.
- **java `jacoco:check`는 `verify` 페이즈 바인딩이라 `mvn test`로는 커버리지 게이트가 검증되지 않는다** — 반드시 `mvn -pl … -am verify -DskipITs`.
- SonarCloud "0% Coverage on New Code"는 Kotlin kover만 피드해 비-Kotlin PR마다 실패한다(비차단).

## 하네스

- ⚠️ **앱·레지스트리 컨테이너는 전부 Alpine(musl) 베이스다.** Debian/glibc는 Windows Docker Desktop 내장 DNS 프록시가 레지스트리 CNAME 체인을 glibc 리졸버에 실패로 돌려줘 `dotnet restore`/`pip install`/Maven·npm 다운로드가 막힌다(CI 네이티브 Docker는 무해).
- ⚠️ **격리 모델과 출처 단언은 다른 축이다.** 격리는 6/3(소스-추가 6 / 구조 격리 3)이지만 **출처 기록·단언은 9개 언어 전부**다(`grep -l PROVENANCE_OK harness/install/consume/*-run.sh | wc -l` → 9). 이 부류는 설정이 아니라 **실제 다운로드 출처**를 본다 — 로컬 레지스트리가 아니면 `installed.ok`를 쓰지 않는다. 가드는 `scripts/test/test-harness-registries.sh`.
- ⚠️ **`install-verify.sh`의 언어별 버전 파생은 전역 변수를 공유하지 않는다**(`PKG_VER_DEFAULT`로 분리). 이 부류의 순서 의존 버그는 **부분집합 실행에서만** 나타나 야간 CI는 초록이었다 — 테스트에 기본 순서와 사고 재현 순서를 **둘 다** 둔다.
