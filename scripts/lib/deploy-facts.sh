#!/usr/bin/env sh
# 9언어 배포 사실 — 단일 진실원천(SSOT). release-readiness.sh·release-trigger.sh·DEPLOY.md가 소비.
# 값은 이 파일이 SSOT다. 추측 금지. 근거 스냅샷은 태그 archive/docs-history-2026-08.
# 권장 배포 순서 = **복구가능성(recoverability)** 순. 첫 게시는 되돌릴 수 없으므로 "인증 설정이
# 쉬운 순"이 아니라 "사고가 났을 때 되돌릴 수 있는 순"으로 간다:
#   1) yank/unlist가 되는 레지스트리(PyPI·NuGet·RubyGems·npm·crates.io)
#   2) Central Portal 2단계 사람 게이트가 있는 Maven Central(java·kotlin) — 스테이징에서 되돌릴 수 있다
#   3) 프록시가 캐시하면 불변인 go(후속 버전의 `retract` 지시자 외에 회수수단 없음)
#   4) 미러 저장소 신설(xzawed/keycloak-sdk-php)이 선행돼야 하는 php
# ⚠️ go가 인증설정은 가장 쉽지만 복구는 가장 약하다 — 옛 순서(쉬운 인증순)는 이 축을 반대로 봤다.
DEPLOY_LANGS="python dotnet ruby node rust java kotlin go php"

# 첫 게시(RC 포함)를 실제로 마친 언어. **문서가 게시 현황을 말할 때의 유일 원천이다.**
#
# 왜 SSOT가 필요한가: 이 사실은 매니페스트 같은 기계가독 원천이 없어 손으로 N곳에 복제돼 있었고,
# Rust RC 게시 한 번이 최소 6곳(README×2·CLAUDE.md·DEPLOY.md·SECURITY.md·getting-started·roadmap)을
# 동시에 낡게 만들었다. 정정 커밋이 7개 파일을 고치고도 3곳을 놓쳤고, `SECURITY.md`는 4개가
# 게시된 뒤에도 "아무것도 게시되지 않았다"고 말하고 있었다(보안 문서라 특히 나빴다 — 신고자가
# "영향받는 사용자 없음"으로 오판한다).
#
# ⚠️ **네트워크로 파생하려는 유혹을 거부할 것.** `test-deploy-md.sh`가 한때 `git tag -l`에 기댔다가
# CI의 `actions/checkout`이 태그를 안 가져와 **항상 0이라 공허하게 통과**한 이력이 있다. 이 값은
# 손으로 갱신하되 **한 곳**이고, 낡으면 가드가 CI를 빨갛게 만든다.
#
# 언어를 게시하면 여기에 추가한다. 그것이 문서 갱신의 트리거다.
DF_PUBLISHED="php python dotnet rust ruby node java kotlin go"

df_known() { case " $DEPLOY_LANGS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# <lang> → 0 if 이미 첫 게시를 마쳤다
df_is_published() { case " $DF_PUBLISHED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# 미게시 언어 목록(DEPLOY_LANGS − DF_PUBLISHED). 문서의 "나머지 N개" 주장을 대조하는 데 쓴다.
# ⚠️ POSIX sh에는 이식 가능한 `local`이 없어 루프 변수가 전역이다. 호출자가 자기 루프를 돌던
# 중에 이 함수를 부르면 이터레이터를 덮어쓰므로 이름을 충분히 특이하게 둔다(`_l` 같은 흔한
# 이름은 실제로 이 저장소의 다른 스크립트 루프와 겹칠 수 있다). `printf`를 쓰는 이유는 dash의
# `echo`가 백슬래시 이스케이프를 해석하기 때문(아래 df_is_prerelease 주석과 같은 이유).
df_unpublished() {
  for _df_unpub_l in $DEPLOY_LANGS; do
    df_is_published "$_df_unpub_l" || printf '%s ' "$_df_unpub_l"
  done
}

df_registry() { case "$1" in
  go) echo "Go module proxy (proxy.golang.org)" ;; php) echo "Packagist" ;;
  rust) echo "crates.io" ;; dotnet) echo "NuGet" ;; python) echo "PyPI" ;;
  node) echo "npm" ;; ruby) echo "RubyGems" ;; java) echo "Maven Central" ;;
  kotlin) echo "Maven Central" ;; esac; }

# php는 "webhook"이 아니다 — Composer VCS 드라이버가 저장소 루트의 composer.json만 읽는데 이
# 모노레포 루트엔 없어서 Packagist가 이 저장소를 추적할 수 없다. php-release.yml의 split 잡이
# PHP_SPLIT_TOKEN으로 php/ 하위트리를 미러 저장소 xzawed/keycloak-sdk-php에 push한다.
df_auth() { case "$1" in
  go) echo "none" ;; php) echo "split-token" ;; rust|dotnet) echo "api-token" ;;
  python|node|ruby) echo "OIDC" ;; java|kotlin) echo "maven-gpg" ;; esac; }

df_tag() { case "$1" in   # printf 포맷; %s=버전
  go) echo "go/v%s" ;; php) echo "php-v%s" ;; rust) echo "rust-v%s" ;;
  dotnet) echo "dotnet-v%s" ;; python) echo "py-v%s" ;; node) echo "node-v%s" ;;
  ruby) echo "ruby-v%s" ;; java) echo "v%s" ;; kotlin) echo "kotlin-v%s" ;; esac; }

df_secrets() { case "$1" in   # 공백구분 GitHub secret 이름; OIDC/none은 빈 문자열
  java) echo "MAVEN_GPG_PRIVATE_KEY MAVEN_GPG_PASSPHRASE CENTRAL_TOKEN_USER CENTRAL_TOKEN_PW" ;;
  kotlin) echo "MAVEN_CENTRAL_USERNAME MAVEN_CENTRAL_PASSWORD SIGNING_IN_MEMORY_KEY SIGNING_IN_MEMORY_KEY_PASSWORD" ;;
  dotnet) echo "NUGET_API_KEY" ;; rust) echo "CARGO_REGISTRY_TOKEN" ;;
  php) echo "PHP_SPLIT_TOKEN" ;; *) echo "" ;; esac; }

df_versionbump() { case "$1" in
  go) echo "none (태그가 버전 SSOT)" ;; php) echo "none (태그가 버전 SSOT)" ;;
  dotnet) echo "none (태그가 -p:Version 주입)" ;;
  java) echo "auto (versions-maven-plugin이 태그값 주입; java/pom.xml은 -SNAPSHOT 유지)" ;;
  rust) echo "rust/Cargo.toml [package].version" ;;
  python) echo "python/pyproject.toml [project].version" ;;
  node) echo "node/package.json version" ;;
  ruby) echo "ruby/lib/keycloak_sdk/version.rb VERSION" ;;
  kotlin) echo "kotlin/build.gradle.kts version" ;; esac; }

# 버전범프 **모드** — 기계가독 분류(auto|manual). DEPLOY.md §1의 분류표와 같은 사실이다.
#   auto   = 태그가 버전 SSOT다. 매니페스트에는 대조할 값이 아예 없거나(go·php·dotnet),
#            의도적으로 다른 값이 들어 있다(java의 `-SNAPSHOT` — versions-maven-plugin이
#            배포 시점에 태그값을 주입하고 POM은 SNAPSHOT을 유지한다).
#   manual = 사람이 매니페스트를 올려야 한다. 태그↔매니페스트 정확비교의 대상이다.
#
# ⚠️ 이 함수가 df_versionbump와 별도로 존재하는 이유: df_versionbump는 사람이 읽는 **산문**
# (파일 경로·설명)이다. 소비자가 그걸 `case "$BUMP" in none*|auto*)` 로 긁으면 문구를 한 번
# 다듬는 것만으로 분류가 조용히 뒤집힌다. 실제로 dispatch-release.yml은 산문 대신 `php`를
# 하드코딩하고 있었고, 그 결과 **java는 모든 릴리스가**(POM이 설계대로 `-SNAPSHOT`이라
# 어떤 값도 대조를 만족할 수 없다) **dotnet은 `0.1.0` 외 모든 버전이** "버전 범프가 반쯤
# 적용됐다"는 거짓 진단으로 중단됐다.
df_bump_mode() { case "$1" in
  go|php|dotnet|java) echo "auto" ;;
  rust|python|node|ruby|kotlin) echo "manual" ;;
esac; }

df_dryrun() { case "$1" in
  go) echo "go -C go build ./... && go -C go vet ./... && go -C go test ./..." ;;
  php) echo "cd php && composer install && composer audit && vendor/bin/phpstan analyse && vendor/bin/phpunit --testsuite unit" ;;
  # rust: Cargo.lock이 커밋돼 있으므로 `--locked`로 잠긴 그래프 그대로 검증한다. `cargo publish
  # --dry-run`은 crates.io에 올라갈 파일목록(`exclude`)·필수 메타데이터를 실제 업로드 없이 확인하는
  # 유일한 수단이라 dry-run에 포함한다(빌드만으로는 패키징 메타데이터가 검증되지 않는다).
  rust) echo "cd rust && cargo build --locked --all-targets && cargo test --locked && cargo clippy --all-targets -- -D warnings && cargo fmt --all --check && cargo publish --dry-run --locked" ;;
  dotnet) echo "dotnet pack dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -c Release" ;;
  python) echo "cd python && python -m build" ;;
  node) echo "cd node && npm run build && npm pack --dry-run" ;;
  ruby) echo "cd ruby && gem build keycloak-sdk.gemspec" ;;
  java) echo "mvn -f java/pom.xml -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true package" ;;
  kotlin) echo "cd kotlin && ./gradlew publishToMavenLocal" ;; esac; }

df_install() { case "$1" in   # go/java/kotlin은 %s=버전
  go) echo "go get github.com/xzawed/KeyCloakSDK/go@v%s" ;;
  php) echo "composer require xzawed/keycloak-sdk" ;;
  rust) echo "cargo add keycloak-sdk" ;;
  dotnet) echo "dotnet add package Xzawed.Keycloak.Sdk" ;;
  python) echo "pip install keycloak-sdk" ;;
  node) echo "npm install @xzawed/keycloak-sdk" ;;
  ruby) echo "gem install keycloak-sdk" ;;
  java) echo "io.github.xzawed:keycloak-sdk:%s" ;;
  kotlin) echo "io.github.xzawed:keycloak-sdk-kotlin:%s" ;; esac; }

df_coordinate() { case "$1" in   # 레지스트리상 패키지 식별자(사람용 표시)
  go) echo "github.com/xzawed/KeyCloakSDK/go" ;; php) echo "xzawed/keycloak-sdk" ;;
  rust) echo "keycloak-sdk" ;; dotnet) echo "Xzawed.Keycloak.Sdk" ;;
  python) echo "keycloak-sdk" ;; node) echo "@xzawed/keycloak-sdk" ;;
  ruby) echo "keycloak-sdk" ;; java) echo "io.github.xzawed:keycloak-sdk" ;;
  kotlin) echo "io.github.xzawed:keycloak-sdk-kotlin" ;; esac; }

# 각 언어가 **실제로 레지스트리에 올린** 버전. 미게시 언어는 빈 문자열.
#
# ⚠️ 이것은 매니페스트 버전이 아니다 — 둘은 갈릴 수 있고 실제로 갈려 있다. `dotnet`은 매니페스트가
# `0.1.0`인 채로 `0.1.0-rc.1`이 게시됐고(릴리스가 태그값을 주입하는 auto-bump 언어), `java`도
# 매니페스트는 `0.1.0-SNAPSHOT`이다. 매니페스트 쪽 SSOT는 `scripts/check-versions.mjs`가 따로 본다.
#
# ⚠️ **왜 이 사실이 필요했나**: 이 값들은 문서 곳곳에 문자열로 복제돼 있는데(랜딩 README 좌표
# 목록·SECURITY·DEPLOY 라이브 목록·docs/reference/compatibility.md) **어디에도 기계 대조가 없었다.**
# 실제로 호환성 표는 아홉 행 중 일곱이 `0.1.0`에 멈춘 채 게시가 여섯 번 지나갔다. 게시 **개수**는
# `DF_PUBLISHED`가 지켰지만 **버전 문자열은 아무도 지키지 않았다** — 같은 사실의 다른 축이고,
# 소비자가 실제로 복사해 가는 쪽은 버전이다.
df_published_version() { case "$1" in
  php) echo "0.2.0" ;; python) echo "0.2.1" ;; dotnet) echo "0.1.0" ;;
  rust) echo "0.1.0" ;; ruby) echo "0.1.0" ;; node) echo "0.2.1" ;;
  java) echo "0.1.0" ;; kotlin) echo "0.1.0" ;; go) echo "0.1.0" ;;
  *) echo "" ;; esac; }

# 200이면 이미 게시됨(readiness). 아홉 전부 **좌표 단위**(버전이 아니라 패키지) 엔드포인트다 —
# 묻는 것은 "이 좌표에 버전이 하나라도 올라가 있는가"이고, 버전 문자열은 df_published_version이
# 따로 소유한다. 여기에 버전을 박으면 같은 사실의 두 번째 정의 자리가 생긴다.
#
# ⚠️ go가 오래 빈 문자열이었던 것은 "프록시는 온디맨드라 게시 이벤트가 없다"는 이유였는데, 그
# 특수처리는 rr_registry_state가 **조회 없이 `exists`(확인됨·미게시)를 지어내게** 만들었다.
# go 첫 게시 뒤에도 readiness는 계속 미게시로 보고했고, 태그를 안 가져오는 CI 체크아웃에서는
# `tag=none`까지 겹쳐 **이미 게시된 좌표에 "✅ 저장소측 OK"(=밀어도 된다)** 가 찍힌다.
# 프록시는 게시 이벤트를 갖지 않을 뿐 **좌표 질의에는 나머지 여덟과 같은 방식으로 답한다**(실측):
#   /go/@v/list      → 200 `v0.1.0-rc.1`
#   /java/@v/list    → 404 `no matching versions for query "latest"` (curl rc=22 → exists=미게시)
# 즉 "버전 없음"이 200-빈본문이 아니라 404라, 상태코드만 보는 rr_url_exists와 정합한다.
#
# ⚠️ 경로는 반드시 `/go` 서브모듈까지 적는다. 저장소 **루트** 경로는 java의 `v*` 태그를 주워
# 200 `v0.1.0-RC1`을 돌려주므로(실측) go가 미게시여도 게시로 오판한다.
# ⚠️ 대문자는 `!` 이스케이프다(KeyCloakSDK → `!key!cloak!s!d!k`). `!`는 셸 history expansion
# 문자지만 확장은 **대화형 bash에서만** 일어난다 — 스크립트는 비대화형이고 dash엔 기능 자체가 없다.
df_check_url() { case "$1" in
  python) echo "https://pypi.org/pypi/keycloak-sdk/json" ;;
  node) echo "https://registry.npmjs.org/@xzawed%2Fkeycloak-sdk" ;;
  rust) echo "https://crates.io/api/v1/crates/keycloak-sdk" ;;
  ruby) echo "https://rubygems.org/api/v1/gems/keycloak-sdk.json" ;;
  dotnet) echo "https://api.nuget.org/v3-flatcontainer/xzawed.keycloak.sdk/index.json" ;;
  php) echo "https://repo.packagist.org/p2/xzawed/keycloak-sdk.json" ;;
  java) echo "https://repo1.maven.org/maven2/io/github/xzawed/keycloak-sdk/maven-metadata.xml" ;;
  kotlin) echo "https://repo1.maven.org/maven2/io/github/xzawed/keycloak-sdk-kotlin/maven-metadata.xml" ;;
  go) echo "https://proxy.golang.org/github.com/xzawed/!key!cloak!s!d!k/go/@v/list" ;; esac; }

# 프리릴리스 표기는 레지스트리마다 다르다. 태그↔매니페스트 가드가 **문자열 정확비교**라 표기가
# 틀리면 CI가 막는다(의도된 동작) — 그래서 검증을 언어별로 나눈다. 첫 게시는 RC로 하라는
# DEPLOY.md §7 권고를 헬퍼가 실제로 지원하려면 이 정규식이 필요하다.
df_version_re() { case "$1" in
  python) echo '^[0-9]+\.[0-9]+\.[0-9]+((a|b|rc)[0-9]+)?$' ;;          # PEP 440: 0.1.0rc1
  ruby) echo '^[0-9]+\.[0-9]+\.[0-9]+(\.(alpha|beta|rc)[0-9]+)?$' ;;   # RubyGems: 0.1.0.rc1
  java|kotlin) echo '^[0-9]+\.[0-9]+\.[0-9]+(-(RC|M|alpha|beta)[0-9]+)?$' ;; # Maven: 0.1.0-RC1
  *) echo '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' ;;               # SemVer: 0.1.0-rc.1
esac; }

df_version_hint() { case "$1" in
  python) echo 'X.Y.Z 또는 PEP 440 프리릴리스 X.Y.ZrcN (예: 0.1.0rc1 — 하이픈·점 없음)' ;;
  ruby) echo 'X.Y.Z 또는 RubyGems 프리릴리스 X.Y.Z.rcN (예: 0.1.0.rc1 — 점 구분)' ;;
  java|kotlin) echo 'X.Y.Z 또는 Maven 프리릴리스 X.Y.Z-RCN (예: 0.1.0-RC1 — 대문자 RC)' ;;
  *) echo 'X.Y.Z 또는 SemVer 프리릴리스 X.Y.Z-rc.N (예: 0.1.0-rc.1)' ;;
esac; }

# 프리릴리스 여부(표기 무관) — 정식 X.Y.Z가 아니면 프리릴리스로 본다.
# ⚠️ `echo`가 아니라 `printf '%s\n'`이다. dash(우분투 러너의 /bin/sh)의 `echo`는 `-e` 없이도
# 백슬래시 이스케이프를 확장하므로 '0.1.0\c-rc.1'이 '0.1.0'으로 잘려 **프리릴리스가 정식
# 릴리스로 오판**된다(RC가 Latest release로 걸리는 사고와 같은 경로). bash·busybox ash는
# 확장하지 않아 로컬에서는 재현되지 않는다.
df_is_prerelease() { ! printf '%s\n' "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; }

df_workflow_hint() { case "$1" in
  python) echo "python-release.yml" ;; node) echo "node-release.yml" ;; ruby) echo "ruby-release.yml" ;;
  *) echo "" ;; esac; }
