#!/usr/bin/env sh
# 9언어 배포 사실 — 단일 진실원천(SSOT). release-readiness.sh·release-trigger.sh·DEPLOY.md가 소비.
# 값은 스펙 §2(docs/superpowers/specs/2026-07-09-unified-deploy-guide-design.md) 실측. 추측 금지.
# 권장 배포 순서 = **복구가능성(recoverability)** 순. 첫 게시는 되돌릴 수 없으므로 "인증 설정이
# 쉬운 순"이 아니라 "사고가 났을 때 되돌릴 수 있는 순"으로 간다:
#   1) yank/unlist가 되는 레지스트리(PyPI·NuGet·RubyGems·npm·crates.io)
#   2) Central Portal 2단계 사람 게이트가 있는 Maven Central(java·kotlin) — 스테이징에서 되돌릴 수 있다
#   3) 프록시가 캐시하면 불변인 go(후속 버전의 `retract` 지시자 외에 회수수단 없음)
#   4) 미러 저장소 신설(xzawed/keycloak-sdk-php)이 선행돼야 하는 php
# ⚠️ go가 인증설정은 가장 쉽지만 복구는 가장 약하다 — 옛 순서(쉬운 인증순)는 이 축을 반대로 봤다.
DEPLOY_LANGS="python dotnet ruby node rust java kotlin go php"

df_known() { case " $DEPLOY_LANGS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

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
  kotlin) echo "gradle -p kotlin publishToMavenLocal" ;; esac; }

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

df_check_url() { case "$1" in   # 200이면 이미 게시됨(readiness). go는 빈 문자열(프록시 온디맨드 — 특수처리)
  python) echo "https://pypi.org/pypi/keycloak-sdk/json" ;;
  node) echo "https://registry.npmjs.org/@xzawed%2Fkeycloak-sdk" ;;
  rust) echo "https://crates.io/api/v1/crates/keycloak-sdk" ;;
  ruby) echo "https://rubygems.org/api/v1/gems/keycloak-sdk.json" ;;
  dotnet) echo "https://api.nuget.org/v3-flatcontainer/xzawed.keycloak.sdk/index.json" ;;
  php) echo "https://repo.packagist.org/p2/xzawed/keycloak-sdk.json" ;;
  java) echo "https://repo1.maven.org/maven2/io/github/xzawed/keycloak-sdk/maven-metadata.xml" ;;
  kotlin) echo "https://repo1.maven.org/maven2/io/github/xzawed/keycloak-sdk-kotlin/maven-metadata.xml" ;;
  go) echo "" ;; esac; }

df_workflow_hint() { case "$1" in
  python) echo "python-release.yml" ;; node) echo "node-release.yml" ;; ruby) echo "ruby-release.yml" ;;
  *) echo "" ;; esac; }
