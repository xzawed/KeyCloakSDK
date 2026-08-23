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

# ---- 버전 인지 모드(4번째 인자) ----
#
# ⚠️ **이 갈래가 없으면 도구가 영구 무신호였다.** 단락 둘(tag·registry)은 "첫 게시인가?"를
# 묻는데, 아홉 전부 게시된 뒤로는 tag(글롭)도 registry(좌표)도 항상 참이라 `rr_verdict`가
# 첫 줄에서 반환했다 — 시크릿 판정에 영영 도달하지 못한다. 0.1.0 게시 직후 실측으로 아홉
# 언어 전부가 `ℹ️ 태그 이미 존재`만 찍었다. 릴리스 직전에 보라는 도구가 0.2.0에서 아무것도
# 말하지 않는 상태였다.
#
# 버전이 주어지면 registry 단락을 건너뛴다 — 이미 있는 좌표에 **새 버전**을 올리는 것이
# 정상이므로 "이미 게시됨"은 정보가 아니다. tag는 호출부가 정확한 태그로 좁혀 넘긴다.
assert_eq "✅ 저장소측 OK" "$(rr_verdict set published none 0.2.0)" \
  "버전 지정 + 그 버전 태그 없음 → 좌표가 이미 게시돼 있어도 시크릿 판정에 도달해야 한다"
assert_eq "⚠️ 설정필요: 시크릿" "$(rr_verdict unset published none 0.2.0)" \
  "버전 지정 + 시크릿 미설정 → 설정필요(registry 단락이 삼키면 안 된다)"
assert_eq "ℹ️ 태그 이미 존재" "$(rr_verdict set published present 0.2.0)" \
  "버전 지정 + 그 버전 태그 존재 → 태그 단락은 버전 모드에서도 유효하다"
assert_eq "ℹ️ 이미 게시됨" "$(rr_verdict set published none)" \
  "버전 미지정(좌표 모드)은 예전 동작 그대로 — 하위호환"

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
# xzawed/keycloak-sdk-php다. ⚠️ **이 주석은 오래 「API로 확인 불가한 사람 확인 사항」이라
# 적혀 있었고 그 문장이 거짓이었다** — 미러 태그와 Packagist source 는 둘 다 공개 조회된다
# (실측 2026-08-23). 이제 판정은 측정에서 나오고, 아래는 그 계약을 고정한다:
# 시크릿만으로 "저장소측 OK"에 머물지 않으며, 결과가 무엇이든 **미러를 언급**한다.
php_row="$(rr_row php)"
assert_contains "$php_row" "secrets=set" "stub: php 시크릿 존재 상태 재현"
assert_not_contains "$php_row" "✅ 저장소측 OK" "php는 시크릿만으로 저장소측 OK에 머물지 않음"
assert_contains "$php_row" "미러" "php split-token → 판정이 미러를 언급한다"
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

# ⚠️ 모든 curl 호출에 시간 상한이 붙어 있어야 한다. 위 _probe가 curl을 **함수로 스텁**하므로
# 판정 로직 테스트는 플래그가 사라져도 전부 통과한다 — 이 부류는 소스 대조로만 잡힌다.
# 이유: 이 스크립트는 아래 라이브 스모크를 통해 **required 체크 `doc-facts` 안에서** 돌고,
# PRIMARY는 `bypass_actors: []`라 그 잡이 매달리면 아무도 머지를 풀 수 없다.
assert_contains "$(grep -E '^RR_TIMEOUT=' "$SH")" "--max-time" "curl 시간 상한이 선언돼 있다"
assert_contains "$(grep -E '^RR_TIMEOUT=' "$SH")" "--connect-timeout" "curl 연결 상한이 선언돼 있다"
assert_eq "0" "$(grep -cE '^[[:space:]]*(if[[:space:]]+)?curl[[:space:]]+(-|-A)' "$SH" || true)" \
  "상한 없이 곧바로 플래그로 시작하는 curl 호출이 없다(전부 \$RR_TIMEOUT 경유)"

# ⚠️ gh 도 같다 — 다만 등급이 다르다(required 경로에서 도달 불가). gh 에는 타임아웃 플래그가
# 없어 `timeout` 래퍼가 유일한 수단이고, 그 래퍼를 우회한 직접 호출이 하나라도 생기면 무의미해진다.
# ⚠️ 이 묶음은 **세 번 공허했다**(전부 변이검증·Grok 반증에서 발현). 남기는 이유는 같은 함정을
# 세 번 다시 파지 않기 위해서다:
#   1. `"timeout"` 부분문자열   → 가드절 `command -v timeout` 이 만족시켜 실호출의 상한을 떼도 통과
#   2. `(^|\|[[:space:]]*)gh`   → 들여쓴 `  gh secret list` 를 못 잡음(공백이 파이프 안쪽에만 허용)
#   3. rr_secret_set 안만 검사  → **다른 함수에 gh 를 새로 추가하면 무통과**. 그리고
#      `timeout "$RR_GH_TIMEOUT" gh` 부분문자열은 `gtimeout …` 도 통과시킨다.
# 그래서 (a) 파일 전체에서 직접 gh 호출 수를 세고, (b) 상한 호출을 **행머리로** 겨누고,
# (c) 기본값이 양의 정수인지 본다 — ⚠️ `timeout 0` 은 GNU coreutils 에서 상한을 **해제**한다(실측: sleep 3 이 3초 걸림).
_gh_all="$(grep -cE '(^|\|)[[:space:]]*gh[[:space:]]' "$SH" || true)"
_gh_wrap="$(sed -n '/^rr_gh()/,/^}/p' "$SH" | grep -cE '(^|\|)[[:space:]]*gh[[:space:]]' || true)"
assert_eq "1" "$_gh_all"  "직접 gh 호출은 파일 전체에 하나뿐(rr_gh 의 timeout 부재 폴백)"
assert_eq "1" "$_gh_wrap" "그 하나가 rr_gh 안에 있다 — 다른 함수가 gh 를 직접 부르면 여기서 2가 된다"
assert_eq "1" "$(sed -n '/^rr_gh()/,/^}/p' "$SH" | grep -cE '^[[:space:]]*timeout[[:space:]]+"\$RR_GH_TIMEOUT"[[:space:]]+gh[[:space:]]' || true)" \
  "상한 호출이 행머리의 timeout 이다(gtimeout 같은 다른 명령이 아니다)"
_gt="$(grep -E '^RR_GH_TIMEOUT=' "$SH" | grep -oE ':-[0-9]+' | grep -oE '[0-9]+' || true)"
assert_ok test -n "$_gt"
assert_ok test "${_gt:-0}" -ge 1

# df_check_url 검증(Task 1 리뷰 Minor — readiness가 df_check_url 소비)
# ⚠️ 여기서 go만 빈값을 **요구**하던 시절이 있었다. 그 어서션은 "프록시 온디맨드"라는 설명을
# 계약으로 굳혀, rr_registry_state가 조회 없이 exists(미게시)를 지어내는 것을 고정했다 —
# go 첫 게시 뒤 readiness가 이미 게시된 좌표를 "✅ 저장소측 OK"로 보고한 경로다. 이제 아홉
# 전부 좌표 단위 URL을 갖는다. 목록을 손으로 늘어놓지 않고 DEPLOY_LANGS를 도는 이유는 열 번째
# 언어가 추가될 때 이 어서션이 **자동으로** 그 언어를 요구하게 하기 위해서다.
for L in $DEPLOY_LANGS; do assert_ok test -n "$(df_check_url "$L")"; done
# go URL은 반드시 `/go` 서브모듈 경로다. 저장소 루트 경로는 java의 `v*` 태그를 주워 200을
# 돌려주므로(실측 `v0.1.0-RC1`) go가 미게시여도 "게시됨"으로 오판한다.
assert_contains "$(df_check_url go)" "proxy.golang.org" "go check_url은 모듈 프록시를 본다"
assert_contains "$(df_check_url go)" "/go/@v/list" "go check_url은 /go 서브모듈의 버전 목록"
# 좌표 단위 불변식: 어떤 언어의 조회 URL에도 게시 버전 문자열이 박혀 있으면 안 된다
# (df_published_version과 두 번째 정의 자리가 생겨 다음 릴리스에 조용히 갈린다).
# ⚠️ 빈 버전(미게시 언어)은 건너뛴다 — `case`의 `*""*`는 **모든 문자열에 매치**하므로 그대로
# 두면 열 번째 언어를 미게시 상태로 추가하는 순간 이 어서션이 거짓으로 빨개진다.
for L in $DEPLOY_LANGS; do
  v="$(df_published_version "$L")"
  [ -z "$v" ] && continue
  case "$(df_check_url "$L")" in
    *"$v"*) assert_ok false "$L check_url에 게시 버전이 박혀 있다" ;;
    *) assert_ok true "$L check_url은 버전을 박지 않는다(좌표 단위)" ;;
  esac
done
# 빈 URL 폴백은 exists가 아니라 unknown이어야 한다 — 조회한 적 없는 좌표에 판정을 지어내지 않는다.
# ⚠️ df_check_url을 여기서 덮어쓰므로 이 블록은 반드시 위 어서션들보다 뒤에 온다.
df_check_url() { echo ""; }
assert_eq "unknown" "$(rr_registry_state go)" "check_url이 비면 미게시가 아니라 unknown"

# ---- PHP 미러·Packagist 판정 (네트워크 없이 스텁으로, **실제 코드 경로**를 태운다) ----
# ⚠️ 이 자리는 오래 「조회 API가 없어 사람이 확인한다」였는데 **거짓이었다** — 둘 다 공개
# 엔드포인트다(실측 2026-08-23: 미러 v0.2.0 존재 · Packagist source.url 이 그 미러).
# ⚠️ **첫 판은 판정 if/elif 를 이 파일에 베껴 검사했고, 그건 스크립트가 아니라 사본을 본 것이라
# 실제 분기를 지워도 통과했다**(변이검증에서 발현). 지금은 프로브만 스텁하고 `rr_row` 를 부른다.
_php_verdict() { # <mirror_rc> <packagist_rc> → rr_row php 의 판정 부분
  eval "rr_mirror_tag() { return $1; }"
  eval "rr_packagist_source() { return $2; }"
  RR_VERSION=9.9.9 rr_row php
}
assert_contains "$(_php_verdict 0 0)" "✅ 미러 v9.9.9" 'php: 미러 태그·Packagist 소스 둘 다 확인되면 초록'
assert_contains "$(_php_verdict 1 0)" "미러에 v9.9.9 태그가 없다" 'php: 미러에 태그가 없으면 split 실패를 말한다'
assert_contains "$(_php_verdict 0 1)" "Packagist" 'php: Packagist 가 다른 소스면 그렇게 말한다'
# ⚠️ 이 둘이 이 묶음의 요지다 — **확인 불가를 「없음」으로 반올림하지 않는다.**
assert_contains "$(_php_verdict 2 0)" "수동 확인" 'php: 미러 조회 실패는 「없음」이 아니라 「확인불가」다'
assert_contains "$(_php_verdict 0 2)" "수동 확인" 'php: Packagist 조회 실패도 확인불가다'
assert_not_contains "$(_php_verdict 2 0)" "태그가 없다" 'php: 조회 실패를 「태그 없음」으로 지어내지 않는다'
unset -f rr_mirror_tag rr_packagist_source 2>/dev/null || true

# 소스 대조 — 두 프로브가 상한을 거치는가(git·curl 둘 다 타임아웃 플래그 사정이 다르다).
# ⚠️ `(^|\|)…git` 로 쓰면 `$(git …)` 를 놓친다(실측: 변이가 통과했다). 앞 문자가 식별자
# 구성문자가 아닌 모든 자리를 본다 — `rr_git` 의 `_git` 은 그래서 걸리지 않는다.
assert_eq "1" "$(sed -n '/^rr_git()/,/^}/p' "$SH" | grep -cE '^[[:space:]]*timeout[[:space:]]+"\$RR_GH_TIMEOUT"[[:space:]]+git[[:space:]]' || true)" \
  'rr_git 의 실호출이 행머리의 timeout 이다'
assert_eq "0" "$(sed -n '/^rr_mirror_tag()/,/^}/p' "$SH" | grep -cE '(^|[^_[:alnum:]])git[[:space:]]+ls-remote' || true)" \
  'rr_mirror_tag 이 git 을 직접 부르지 않는다(rr_git 경유)'
assert_eq "1" "$(sed -n '/^rr_packagist_source()/,/^}/p' "$SH" | grep -cE 'curl \$RR_TIMEOUT' || true)" \
  'rr_packagist_source 의 curl 이 시간 상한을 쓴다'
assert_contains "$(grep -E '^RR_PHP_MIRROR=' "$SH")" 'keycloak-sdk-php' 'RR_PHP_MIRROR 이 미러 저장소다'

assert_report