#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"

# 9개 언어 존재·순서
assert_eq "go php rust dotnet python node ruby java kotlin" "$DEPLOY_LANGS" "DEPLOY_LANGS 순서"
assert_ok df_known python; assert_fails df_known perl
# 태그 포맷(버전 주입)
assert_eq "py-v0.1.0" "$(printf "$(df_tag python)" 0.1.0)" "python 태그"
assert_eq "go/v0.1.0" "$(printf "$(df_tag go)" 0.1.0)" "go 태그"
assert_eq "v0.1.0" "$(printf "$(df_tag java)" 0.1.0)" "java 태그"
assert_eq "kotlin-v0.1.0" "$(printf "$(df_tag kotlin)" 0.1.0)" "kotlin 태그"
# 시크릿(정확 이름·개수)
assert_eq "MAVEN_GPG_PRIVATE_KEY MAVEN_GPG_PASSPHRASE CENTRAL_TOKEN_USER CENTRAL_TOKEN_PW" "$(df_secrets java)" "java 시크릿"
assert_eq "MAVEN_CENTRAL_USERNAME MAVEN_CENTRAL_PASSWORD SIGNING_IN_MEMORY_KEY SIGNING_IN_MEMORY_KEY_PASSWORD" "$(df_secrets kotlin)" "kotlin 시크릿"
assert_eq "NUGET_API_KEY" "$(df_secrets dotnet)" "dotnet 시크릿"
assert_eq "CARGO_REGISTRY_TOKEN" "$(df_secrets rust)" "rust 시크릿"
assert_eq "" "$(df_secrets python)" "python 시크릿 없음"
assert_eq "" "$(df_secrets go)" "go 시크릿 없음"
# auth 모델
assert_eq "none" "$(df_auth go)" "go auth"
assert_eq "webhook" "$(df_auth php)" "php auth"
assert_eq "api-token" "$(df_auth rust)" "rust auth"
assert_eq "OIDC" "$(df_auth python)" "python auth"
assert_eq "maven-gpg" "$(df_auth java)" "java auth"
# 설치 좌표(go는 버전 주입)
assert_eq "go get github.com/xzawed/KeyCloakSDK/go@v0.1.0" "$(printf "$(df_install go)" 0.1.0)" "go 설치"
assert_eq "pip install keycloak-sdk" "$(df_install python)" "python 설치"
# 워크플로 힌트(Task 2 소비 예정)
assert_eq "python-release.yml" "$(df_workflow_hint python)" "python 워크플로 힌트"
assert_eq "" "$(df_workflow_hint go)" "go 워크플로 힌트 없음"
# 모든 언어가 전 필드에 비어있지 않은 값을 반환하는지(check_url 제외 — go는 특수)
for L in $DEPLOY_LANGS; do
  for F in registry auth tag versionbump dryrun install coordinate; do
    v="$(df_$F "$L")"; assert_ok test -n "$v"
  done
done
assert_report
