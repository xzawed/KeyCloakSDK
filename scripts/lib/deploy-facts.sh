#!/usr/bin/env sh
# 9언어 배포 사실 — 단일 진실원천(SSOT). release-readiness.sh·release-trigger.sh·DEPLOY.md가 소비.
# 값은 스펙 §2(docs/superpowers/specs/2026-07-09-unified-deploy-guide-design.md) 실측. 추측 금지.
# 권장 배포 순서(쉬운 인증→어려운 인증).
DEPLOY_LANGS="go php rust dotnet python node ruby java kotlin"

df_known() { case " $DEPLOY_LANGS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

df_registry() { case "$1" in
  go) echo "Go module proxy (proxy.golang.org)" ;; php) echo "Packagist" ;;
  rust) echo "crates.io" ;; dotnet) echo "NuGet" ;; python) echo "PyPI" ;;
  node) echo "npm" ;; ruby) echo "RubyGems" ;; java) echo "Maven Central" ;;
  kotlin) echo "Maven Central" ;; esac; }

df_auth() { case "$1" in
  go) echo "none" ;; php) echo "webhook" ;; rust|dotnet) echo "api-token" ;;
  python|node|ruby) echo "OIDC" ;; java|kotlin) echo "maven-gpg" ;; esac; }

df_tag() { case "$1" in   # printf 포맷; %s=버전
  go) echo "go/v%s" ;; php) echo "php-v%s" ;; rust) echo "rust-v%s" ;;
  dotnet) echo "dotnet-v%s" ;; python) echo "py-v%s" ;; node) echo "node-v%s" ;;
  ruby) echo "ruby-v%s" ;; java) echo "v%s" ;; kotlin) echo "kotlin-v%s" ;; esac; }

df_secrets() { case "$1" in   # 공백구분 GitHub secret 이름; OIDC/none/webhook은 빈 문자열
  java) echo "MAVEN_GPG_PRIVATE_KEY MAVEN_GPG_PASSPHRASE CENTRAL_TOKEN_USER CENTRAL_TOKEN_PW" ;;
  kotlin) echo "MAVEN_CENTRAL_USERNAME MAVEN_CENTRAL_PASSWORD SIGNING_IN_MEMORY_KEY SIGNING_IN_MEMORY_KEY_PASSWORD" ;;
  dotnet) echo "NUGET_API_KEY" ;; rust) echo "CARGO_REGISTRY_TOKEN" ;; *) echo "" ;; esac; }

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
  rust) echo "cd rust && cargo build --all-targets && cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt --all --check" ;;
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
