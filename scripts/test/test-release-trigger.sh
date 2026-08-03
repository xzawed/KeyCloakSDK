#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
SH="$DIR/../release-trigger.sh"

out="$(sh "$SH" python 0.1.0)"
assert_contains "$out" "git tag py-v0.1.0 && git push origin py-v0.1.0" "python 태그 명령"
assert_contains "$out" "python/pyproject.toml" "python 버전범프 파일"
assert_contains "$out" "python -m build" "python dry-run"
assert_contains "$out" "pending-publisher" "python OIDC 주의(사전등록)"

out="$(sh "$SH" go 0.1.0)"
assert_contains "$out" "git tag go/v0.1.0 && git push origin go/v0.1.0" "go 태그 명령(go/ 접두)"
assert_contains "$out" "버전 파일 수정 불필요" "go 자동버전 안내"

out="$(sh "$SH" java 2.0.0)"
assert_contains "$out" "git tag v2.0.0 && git push origin v2.0.0" "java 태그 명령"
assert_contains "$out" "Portal" "java Maven 수동 release 주의"

# 입력 검증
assert_fails sh "$SH" perl 0.1.0       # 알 수 없는 언어
assert_fails sh "$SH" python 1.2         # 비-semver
assert_fails sh "$SH" python             # 인자 부족
# ⚠️ dash 전용 회귀(bash에서는 재현되지 않는다): 버전 검사가 `echo "$VER" | grep`이면 dash의
# echo가 `\c`를 확장해 문자열을 잘라내고, 잘린 앞부분만 정규식을 만족해도 통과한다 — 그러면
# 이 스크립트가 사람에게 **주입 문자열이 붙은 태그 명령을 복사하라고 안내**한다.
assert_fails sh "$SH" python '0.1.0\c; touch /tmp/pwned'
assert_fails sh "$SH" python '0.1.0\nnode-v9.9.9'

# human-gate 불변식: 스크립트가 실제로 git을 변경하는 라인이 없어야 함(주석/echo 안의 문자열은 허용)
# 실행 라인만 검사: 줄 시작(공백 후)이 git tag/push로 시작하는 라인이 없어야 한다.
assert_eq "0" "$(grep -cE '^[[:space:]]*(git[[:space:]]+(tag|push)|"\$GIT")' "$SH" || true)" "trigger는 git 변경 라인 없음"
assert_report
