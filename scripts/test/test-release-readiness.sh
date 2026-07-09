#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
SH="$DIR/../release-readiness.sh"

# 순수 판정 함수 단위테스트(외부호출 stub — 소싱해 override)
. "$SH" --lib   # --lib: 함수만 로드하고 main 실행 안 함
assert_eq "✅ 준비완료" "$(rr_verdict set exists none)" "시크릿O·미게시·태그無 → 준비완료"
assert_eq "⚠️ 설정필요: 시크릿" "$(rr_verdict unset exists none)" "시크릿X → 설정필요"
assert_eq "ℹ️ 이미 게시됨" "$(rr_verdict set published none)" "이미 게시 → 안내"
assert_eq "✅ 준비완료" "$(rr_verdict na exists none)" "OIDC(시크릿 na) → 준비완료"

# 스모크: 실제 실행(읽기전용, gh/curl 없어도 크래시 없이 ?로 격리)
out="$(sh "$SH" go python 2>/dev/null || true)"
assert_contains "$out" "go" "go 행 존재"
assert_contains "$out" "python" "python 행 존재"

# 상태 불변식: readiness는 git/파일을 변경하는 라인이 없어야 함
assert_eq "0" "$(grep -cE '^[[:space:]]*(git[[:space:]]+(tag|push|commit|add|checkout)|rm|mv|>[^&])' "$SH" || true)" "readiness는 상태변경 없음"
# 시크릿 값 출력 금지: gh secret list는 --json 없이 이름만; 값 echo 패턴 부재
assert_eq "0" "$(grep -cE 'secret (view|get)|gh api.*secrets' "$SH" || true)" "시크릿 값 미조회"

# df_check_url 검증(Task 1 리뷰 Minor — readiness가 df_check_url 소비)
assert_eq "" "$(df_check_url go)" "go check_url 빈값(프록시 온디맨드)"
for L in php rust dotnet python node ruby java kotlin; do assert_ok test -n "$(df_check_url "$L")"; done
assert_report
