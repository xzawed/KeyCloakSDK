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
# 권장 순서·인증모델 그룹 헤딩 존재
assert_contains "$body" "준비상태 매트릭스" "매트릭스 섹션"
assert_contains "$body" "human-gate" "human-gate 원칙"
assert_report
