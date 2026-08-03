#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"

# 9개 언어 존재·순서 — 순서축은 "쉬운 인증"이 아니라 **복구가능성**이다(yank 가능 → Central Portal
# 2단계 게이트 → 프록시 캐시 후 불변인 go → 미러 저장소 신설이 선행되는 php).
assert_eq "python dotnet ruby node rust java kotlin go php" "$DEPLOY_LANGS" "DEPLOY_LANGS 순서(복구가능성)"
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
# php는 subtree split 미러 push에 write 토큰이 필요하다 — 예전처럼 시크릿 0개가 아니다.
# (0개면 rr_verdict가 "✅ 준비완료"로 오탐한다 — 미러/토큰 미설정 상태에서 false green.)
assert_eq "PHP_SPLIT_TOKEN" "$(df_secrets php)" "php 시크릿"
assert_eq "" "$(df_secrets python)" "python 시크릿 없음"
assert_eq "" "$(df_secrets go)" "go 시크릿 없음"
# auth 모델
assert_eq "none" "$(df_auth go)" "go auth"
# php는 webhook이 아니다 — Packagist는 이 모노레포를 추적할 수 없어(루트 composer.json 부재)
# php/ 하위트리를 미러 저장소로 split-push하는 것이 유일한 게시 경로다.
assert_eq "split-token" "$(df_auth php)" "php auth(split-token)"
assert_eq "api-token" "$(df_auth rust)" "rust auth"
assert_eq "OIDC" "$(df_auth python)" "python auth"
assert_eq "maven-gpg" "$(df_auth java)" "java auth"
# 설치 좌표(go는 버전 주입)
assert_eq "go get github.com/xzawed/KeyCloakSDK/go@v0.1.0" "$(printf "$(df_install go)" 0.1.0)" "go 설치"
assert_eq "pip install keycloak-sdk" "$(df_install python)" "python 설치"
# 워크플로 힌트(Task 2 소비 예정)
assert_eq "python-release.yml" "$(df_workflow_hint python)" "python 워크플로 힌트"
assert_eq "" "$(df_workflow_hint go)" "go 워크플로 힌트 없음"
# 프리릴리스 판정
assert_ok   df_is_prerelease 0.1.0rc1
assert_fails df_is_prerelease 0.1.0
# ⚠️ dash 전용 회귀(bash에서는 재현되지 않는다): 판정이 `echo "$1" | grep`이면 dash의 echo가
# `\c`를 이스케이프로 확장해 '0.1.0\c-rc.1'을 '0.1.0'으로 잘라내고 **프리릴리스를 정식
# 릴리스로 오판**한다(RC가 저장소의 Latest release로 걸리는 사고와 같은 경로). 단따옴표는
# 모든 POSIX 셸에서 백슬래시를 리터럴로 보존하므로 여기서 node가 필요하지 않다.
assert_ok df_is_prerelease '0.1.0\c-rc.1'
assert_ok df_is_prerelease '0.1.0\n0.1.0'

# 버전범프 모드 — 산문(df_versionbump)이 아니라 기계가독 값으로 분류한다.
# 이 분류가 틀리면 dispatch-release.yml의 매니페스트 대조가 자동범프 언어를 영구 차단한다
# (java는 POM이 설계대로 `-SNAPSHOT`이라 어떤 버전으로도 대조를 통과할 수 없었다).
for L in go php dotnet java; do assert_eq "auto" "$(df_bump_mode "$L")" "$L: 자동범프(태그가 버전 SSOT)"; done
for L in rust python node ruby kotlin; do assert_eq "manual" "$(df_bump_mode "$L")" "$L: 수동범프(매니페스트 대조 대상)"; done
# 빈 값은 "대조 안 함"으로 조용히 흡수되므로 아홉이 빠짐없이 분류되는지 개수로 못박는다
# (DEPLOY.md §1의 "Automatic (4) / Manual (5)"와 같은 사실이다).
assert_eq "4" "$(for L in $DEPLOY_LANGS; do df_bump_mode "$L"; done | grep -c '^auto$')" "자동범프 4개"
assert_eq "5" "$(for L in $DEPLOY_LANGS; do df_bump_mode "$L"; done | grep -c '^manual$')" "수동범프 5개"

# 모든 언어가 전 필드에 비어있지 않은 값을 반환하는지(check_url 제외 — go는 특수)
for L in $DEPLOY_LANGS; do
  for F in registry auth tag versionbump bump_mode dryrun install coordinate; do
    v="$(df_$F "$L")"; assert_ok test -n "$v"
  done
done
assert_report
