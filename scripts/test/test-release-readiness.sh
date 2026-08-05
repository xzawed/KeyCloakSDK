#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
SH="$DIR/../release-readiness.sh"

# 순수 판정 함수 단위테스트(외부호출 stub — 소싱해 override)
# ⚠️ 소싱 전에 위치인자를 설정한다 — `. "$SH" --lib`로 쓰면 안 된다. POSIX의 `.`(dot)은 파일명 외의
# 인자를 정의하지 않아 dash(우분투 러너의 /bin/sh)가 그것을 무시한다. 그러면 `--lib` 가드가 거짓이
# 되어 rr_main이 실행되는데, rr_main은 0으로 끝나므로 테스트가 죽지도 않고 **매 CI 실행마다 아홉
# 레지스트리를 실제로 조회**해 왔다(아래 N1 주석이 경고하는 바로 그 부류의 환경 의존이 소싱
# 한 줄에 숨어 있었다). 로컬 Git Bash는 위치인자를 설정하므로 이 결함은 CI 로그에서만 보였다.
set -- --lib
. "$SH"   # 라이브러리 모드: 함수만 로드하고 main 실행 안 함
# ⚠️ 판정 문자열은 "저장소측 OK"이지 "준비완료"가 아니다. 이 스크립트는 시크릿 **이름**·공개
# 레지스트리 URL·로컬 태그만 본다 — 토큰 뒤의 레지스트리 계정 상태는 볼 수 없다. 옛 문구
# `✅ 준비완료`를 믿고 rust 태그를 밀었다가 게이트를 다 통과한 뒤 crates.io가 400으로 거부했다
# ("A verified email address is required to publish"). 문구를 되돌리지 말 것.
assert_eq "✅ 저장소측 OK" "$(rr_verdict set exists none)" "시크릿O·미게시·태그無 → 저장소측 OK"
assert_eq "⚠️ 설정필요: 시크릿" "$(rr_verdict unset exists none)" "시크릿X → 설정필요"
assert_eq "ℹ️ 이미 게시됨" "$(rr_verdict set published none)" "이미 게시 → 안내"
assert_eq "✅ 저장소측 OK" "$(rr_verdict na exists none)" "OIDC(시크릿 na) → 저장소측 OK"
assert_eq "ℹ️ 태그 이미 존재" "$(rr_verdict set exists present)" "태그존재 우선"

# 회귀 가드: `if cmd; then …; fi` **뒤**의 `$?`는 cmd가 아니라 if 문 자체의 코드(조건 거짓 +
# else 없음 → POSIX가 0으로 정의)다. rr_url_exists가 그 실수를 갖고 있어 4xx에서 rc=0을 보고
# `-eq 22` 분기를 못 타, **"미게시(exists)" 판정이 죽고** 모든 미게시 좌표가 unknown으로 나왔다.
# curl 없는 환경에서도 돌도록 curl 자체를 stub해 세 종료코드를 직접 주입한다.
_probe() { # <curl 종료코드> → rr_url_exists의 반환값을 출력
  eval "curl() { return $1; }"
  # ⚠️ `set -e` 아래서는 비영 반환이 곧바로 서브셸을 죽여 echo에 도달하지 못한다 —
  # `|| rc=$?`로 복합명령을 만들어야 종료코드를 잡을 수 있다.
  rc=0
  rr_url_exists "http://example.invalid" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
assert_eq "0" "$(_probe 0)"  "curl 성공(2xx) → 게시됨(0)"
assert_eq "1" "$(_probe 22)" "curl 22(4xx/5xx) → 확인된 미게시(1) — if 뒤 \$? 버그가 되살아나면 2가 된다"
assert_eq "2" "$(_probe 7)"  "curl 7(연결 실패) → unknown(2)"
unset -f curl 2>/dev/null || true

# 스모크: 실제 실행(읽기전용, gh/curl 없어도 크래시 없이 ?로 격리). 행 존재만 본다 —
# 판정값은 실제 게시·태그 상태에 따라 달라지므로 여기서 걸면 안 된다(아래 N1 주석 참고).
out="$(sh "$SH" go python 2>/dev/null || true)"
assert_contains "$out" "go" "go 행 존재"
assert_contains "$out" "python" "python 행 존재"

# ⚠️ N1·N2 어서션은 환경 비의존이어야 한다 — 실제 레지스트리/태그 상태에 기대면 안 된다.
# N1은 원래 위 라이브 스모크 출력($out)에 걸려 있었는데, py-v0.1.0rc1이 실제로 게시되자
# python 행이 "registry=published tag=present"로 바뀌어 어서션이 낡은 주장(미게시)을 강제하는
# 쪽으로 뒤집혔다(로컬은 태그가 있어 실패, CI main push는 checkout이 태그를 안 가져와 통과 —
# test-deploy-md.sh가 두 번 겪은 것과 정확히 같은 부류의 설계 실수다. 그 파일의 이력 주석 참고).
# 판정 함수에 외부호출 stub을 물려 "시크릿 존재·확인된 미게시·무태그" 상태를 재현해 고정한다 —
# 게시/태그 판정이 우선하는 것은 위 rr_verdict 단위테스트(9~13행)가 이미 고정한다.
rr_secret_set() { return 0; }   # 모든 시크릿 존재
rr_url_exists()  { return 1; }  # 확인된 미게시(4xx)
rr_tag_exists()  { return 1; }  # 태그 없음

# N1(스펙§4 갭): OIDC 언어(python)는 secrets=na라도 pending-publisher 사전등록을 API로
# 확인할 수 없으므로 "준비완료"를 자동표시하지 않는다.
py_line="$(rr_row python)"
assert_contains "$py_line" "ℹ️ 수동 확인" "python OIDC → pending-publisher 수동확인 안내"
assert_contains "$py_line" "pending-publisher" "python OIDC → pending-publisher 문구 포함"

# N2: split-token 언어(php)는 PHP_SPLIT_TOKEN이 있어도 실제 게시 주체가 미러 저장소
# xzawed/keycloak-sdk-php이고, 미러·Packagist 등록 상태는 API로 확인 불가한 사람 확인 사항이라
# "준비완료"를 자동표시하지 않는다. 시크릿이 있는 상태를 stub으로 재현해 다운그레이드를 고정한다.
php_row="$(rr_row php)"
assert_contains "$php_row" "secrets=set" "stub: php 시크릿 존재 상태 재현"
assert_not_contains "$php_row" "✅ 저장소측 OK" "php는 시크릿만으로 저장소측 OK에 머물지 않음"
assert_contains "$php_row" "ℹ️ 수동 확인" "php split-token → 수동확인 안내"
assert_contains "$php_row" "xzawed/keycloak-sdk-php" "php split-token → 미러 저장소 명시"
assert_contains "$php_row" "Packagist" "php split-token → Packagist 등록 명시"
# api-token(rust/dotnet)도 다운그레이드된다 — 시크릿 **이름**만 확인했을 뿐 토큰 유효성·스코프·
# 계정 상태는 값 없이 볼 수 없다. rust가 실제로 여기서 걸렸다(crates.io 이메일 미인증, 400).
assert_contains "$(rr_row rust)" "ℹ️ 수동 확인" "api-token(rust)도 수동확인으로 다운그레이드"
assert_contains "$(rr_row rust)" "이메일 인증" "api-token → 계정 이메일 인증을 명시"
assert_contains "$(rr_row node)" "pending-publisher" "OIDC(node)는 pending-publisher 유지"
assert_contains "$(rr_row java)" "Portal" "maven-gpg(java)는 Portal 수동 Publish를 명시"
# ⚠️ 대조군 — 없으면 "전 언어 무조건 다운그레이드" 회귀를 못 잡는다. go는 계정도 시크릿도 없어
# 태그가 곧 게시이므로 저장소측 확인이 실제로 전부다. 이 행만 초록으로 남아야 한다.
assert_contains "$(rr_row go)" "✅ 저장소측 OK" "none(go)은 다운그레이드 대상이 아니다"

# 상태 불변식: readiness는 git/파일을 변경하는 라인이 없어야 함
assert_eq "0" "$(grep -cE '^[[:space:]]*(git[[:space:]]+(tag|push|commit|add|checkout)|rm|mv|>[^&])' "$SH" || true)" "readiness는 상태변경 없음"
# 시크릿 값 출력 금지: gh secret list는 --json 없이 이름만; 값 echo 패턴 부재
assert_eq "0" "$(grep -cE 'secret (view|get)|gh api.*secrets' "$SH" || true)" "시크릿 값 미조회"

# df_check_url 검증(Task 1 리뷰 Minor — readiness가 df_check_url 소비)
assert_eq "" "$(df_check_url go)" "go check_url 빈값(프록시 온디맨드)"
for L in php rust dotnet python node ruby java kotlin; do assert_ok test -n "$(df_check_url "$L")"; done
assert_report
