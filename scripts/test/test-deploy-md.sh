#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"
DOC="$DIR/../../DEPLOY.md"
body="$(cat "$DOC")"

# 9개 언어 섹션·태그·시크릿·설치좌표가 모두 문서에 존재
for L in $DEPLOY_LANGS; do
  assert_contains "$body" "$(printf "$(df_tag "$L")" X.Y.Z | sed 's/X.Y.Z/*/')" "태그포맷 $L"
  for s in $(df_secrets "$L"); do assert_contains "$body" "$s" "시크릿 $s"; done
done
# 두 도우미 스크립트 참조
assert_contains "$body" "scripts/release-readiness.sh" "readiness 참조"
assert_contains "$body" "scripts/release-trigger.sh" "trigger 참조"
# 인증모델 그룹 헤딩 존재
# ⚠️ DEPLOY.md는 사용자 대상 문서라 영문이다(문서 언어 규칙). 예전 이 어서션은 한글 "준비상태
# 매트릭스"를 찾고 있었는데 문서가 영문으로 번역되면서 계속 실패하고 있었다(이 테스트는 어떤 CI
# 워크플로에도 연결돼 있지 않아 드리프트가 드러나지 않았다). 헤딩 텍스트 기준으로 맞춘다.
assert_contains "$body" "Readiness Matrix" "매트릭스 섹션"
assert_contains "$body" "human-gate" "human-gate 원칙"

# 권장 순서는 복구가능성 축이다(deploy-facts.sh의 DEPLOY_LANGS와 같은 순서를 문서도 말해야 한다).
order="$(echo "$DEPLOY_LANGS" | sed 's/ / → /g')"
assert_contains "$body" "$order" "권장 배포 순서(복구가능성) = DEPLOY_LANGS"

# PHP는 웹훅이 아니라 subtree split 미러다 — 미러 저장소·시크릿·1회 사람 설정이 문서에 있어야 한다.
assert_contains "$body" "xzawed/keycloak-sdk-php" "PHP 미러 저장소"
assert_contains "$body" "git subtree split --prefix=php" "PHP split 방식"

# 시크릿 미설정이 "조용한 스킵"이라는 옛 서술이 남아 있으면 안 된다(dotnet·kotlin 둘 다 fail-closed).
assert_not_contains "$body" "silently skipped" "조용한 스킵 서술 잔존"
assert_not_contains "$body" "silently skips" "조용한 스킵 서술 잔존(2)"

# 게시 이력에 대한 정직성: 공개 레지스트리 게시·태그가 0인 사실이 문서에 남아 있어야 한다.
assert_contains "$body" "zero tags" "미게시·무태그 사실 명시"
assert_report
