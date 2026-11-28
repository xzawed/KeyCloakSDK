#!/usr/bin/env sh
# CHANGELOG 조각 파일 — scripts/lib/changelog-fragments.mjs · scripts/changelog.mjs 의 자가테스트.
# 절 하나가 과제 하나다: F(문법 · check) · 이어서 W · M · R · K · V 가 같은 파일에 붙는다.
# POSIX sh 만 쓴다 — 로컬 sh 는 bash 여도 CI 의 /bin/sh 는 dash 다([[ · 배열 · $'…' · echo -e 금지).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
CLI="$DIR/../changelog.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fresh() { # 픽스처 뿌리 — DEPLOY_LANGS stub 한 줄을 쓴다(readDeployLangs 가 읽는 자리)
  rm -rf "$TMP"; mkdir -p "$TMP/scripts/lib"
  printf 'DEPLOY_LANGS="python dotnet ruby node rust java kotlin go php"\n' > "$TMP/scripts/lib/deploy-facts.sh"
}
# 출력 끝에 종료 코드를 `__rc=N` 으로 붙인다(test-changelog-ledger.sh 와 같은 꼴).
run() { node "$CLI" "$@" 2>&1 && echo '__rc=0' || echo "__rc=$?"; }
assert_rejects() { # <run 의 출력> <바늘> <메시지>
  assert_contains "$1" "$2" "$3"
  assert_contains "$1" '__rc=1' "$3 — exit 1"
}
frag() { # <이름> <내용(printf 형식 아님, 그대로)>
  mkdir -p "$TMP/changelog.d"; printf '%s' "$2" > "$TMP/changelog.d/$1"
}
repeat() { printf '%*s' "$1" '' | tr ' ' 'x'; }
snap() { (cd "$TMP" && find . -type f | LC_ALL=C sort | xargs cksum 2>/dev/null | cksum); }
chk() { run check --root="$TMP"; }

# ---- F. 조각 문법 · check ----
# F1 정상.
fresh; frag 2026-11-25-a.txt 'langs: python go
section: Fixed
---
A 고침
'
_out="$(chk)"; assert_contains "$_out" 'ok' "F1 정상 조각은 ok"; assert_contains "$_out" '__rc=0' "F1 rc 0"

# F2 윈도 편집기가 저장한 꼴 — BOM + CRLF + 끝 빈 줄 둘.
fresh; mkdir -p "$TMP/changelog.d"
printf '\357\273\277langs: python go\r\nsection: Fixed\r\n---\r\nA 고침\r\n\r\n\r\n' > "$TMP/changelog.d/2026-11-25-a.txt"
_out="$(chk)"; assert_contains "$_out" '__rc=0' "F2 BOM · CRLF · 끝 빈 줄을 받는다"

# F3 거부 — 파일 이름 바늘 + rc 1.
bad() { # <이름> <내용> <메시지>
  fresh; frag "$1" "$2"; _out="$(chk)"
  assert_rejects "$_out" "changelog.d/$1" "$3"
}
bad 2026-11-25-a.txt 'langs: go
section: Fixed
kind: x
---
b
' "F3 모르는 키"
bad 2026-11-25-a.txt 'langs: go
---
b
' "F3 section 없음"
bad 2026-11-25-a.txt 'langs:
section: Fixed
---
b
' "F3 langs 비었음"
bad 2026-11-25-a.txt 'langs: swift
section: Fixed
---
b
' "F3 모르는 언어 swift"
bad 2026-11-25-a.txt 'langs: python python
section: Fixed
---
b
' "F3 겹친 언어"
bad 2026-11-25-a.txt 'langs: go
section: Fix
---
b
' "F3 모르는 section"
bad 2026-11-25-a.txt 'langs: go
section: Fixed
b
' "F3 --- 없음"
bad 2026-11-25-a.txt 'langs: go
section: Fixed
---
' "F3 빈 본문"
bad 2026-11-25-a.txt 'langs: go
section: Fixed
---
b
c
' "F3 두 줄 본문"
bad notes.txt 'langs: go
section: Fixed
---
b
' "F3 이름이 규칙 밖"
bad 2026-11-25-a.txt 'langs: go
langs: python
section: Fixed
---
b
' "F3 겹친 키"
bad 2026-11-25-a.txt 'langs: go

section: Fixed
---
b
' "F3 머리의 빈 줄"
bad 2026-11-25-a.txt 'langs: go
section: Fixed
---
 앞 공백
' "F3 본문 앞 공백"
fresh; mkdir -p "$TMP/changelog.d/sub"
_out="$(chk)"; assert_rejects "$_out" 'changelog.d/sub' "F3 디렉터리"

# F4 경계 — `- **(Go)** ` 11 B + 본문 1,012 B + `\n` = 1,024 B.
fresh; frag 2026-11-25-a.txt "langs: go
section: Fixed
---
$(repeat 1012)
"
_out="$(chk)"; assert_contains "$_out" '__rc=0' "F4 1,012 B 본문은 상한 안(1024B)"
fresh; frag 2026-11-25-a.txt "langs: go
section: Fixed
---
$(repeat 1013)
"
_out="$(chk)"; assert_rejects "$_out" '1025B > 1024B' "F4 1,013 B 본문은 1025B > 1024B"
# 상한은 langs 전부로 컴파일한 줄에 건다 — 같은 본문도 언어가 많으면 넘는다.
fresh; frag 2026-11-25-a.txt "langs: python dotnet ruby node rust java kotlin go php
section: Fixed
---
$(repeat 1000)
"
_out="$(chk)"; assert_rejects "$_out" 'changelog.d/2026-11-25-a.txt' "F4 태그가 긴 줄도 상한을 본다"

# F5 디렉터리 없음.
fresh; _out="$(chk)"
assert_contains "$_out" '대기 중인 조각이 없다' "F5 changelog.d/ 없음"; assert_contains "$_out" '__rc=0' "F5 rc 0"

# F6 stub 의 DEPLOY_LANGS 가 표시명 표와 다르면 거부.
fresh; printf 'DEPLOY_LANGS="python dotnet ruby node rust java kotlin go php swift"\n' > "$TMP/scripts/lib/deploy-facts.sh"
_out="$(chk)"; assert_rejects "$_out" '표시명' "F6 DEPLOY_LANGS 와 표시명 표가 어긋나면 거부"

# F7 사용법 — rc 2 · 아무것도 안 쓴다.
fresh; frag 2026-11-25-a.txt 'langs: go
section: Fixed
---
b
'
_before="$(snap)"
_out="$(run chek --root="$TMP")";   assert_contains "$_out" '__rc=2' "F7 모르는 하위명령 chek"
_out="$(run --rot=x)";              assert_contains "$_out" '__rc=2' "F7 하위명령 없이 모르는 인자"
_out="$(run check --rot=x --root="$TMP")"; assert_contains "$_out" '__rc=2' "F7 check 의 모르는 인자"
_out="$(run check --root=)";        assert_contains "$_out" '__rc=2' "F7 빈 --root="
_out="$(run check --root="$TMP" --root="$TMP")"; assert_contains "$_out" '__rc=2' "F7 겹친 --root="
_out="$(run)";                      assert_contains "$_out" '__rc=2' "F7 인자 없음"
assert_eq "$_before" "$(snap)" "F7 사용법 오류는 아무것도 쓰지 않는다"

assert_report
