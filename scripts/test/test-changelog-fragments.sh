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

# F3 거부 — 파일 이름 바늘 + **사유 바늘**(그 규칙의 메시지) + rc 1. 픽스처마다 결함은 하나다.
bad() { # <이름> <내용> <사유 바늘> <메시지>
  fresh; frag "$1" "$2"; _out="$(chk)"
  assert_rejects "$_out" "changelog.d/$1" "$4 — 파일 이름"
  assert_contains "$_out" "$3" "$4 — 사유"
}
bad 2026-11-25-a.txt 'langs: go
section: Fixed
kind: x
---
b
' '모르는 키 `kind`' "F3 모르는 키"
bad 2026-11-25-a.txt 'langs: go
---
b
' '`section:` 이 없다' "F3 section 없음"
bad 2026-11-25-a.txt 'langs:
section: Fixed
---
b
' '`langs` 가 비었다' "F3 langs 비었음"
bad 2026-11-25-a.txt 'langs: swift
section: Fixed
---
b
' 'DEPLOY_LANGS 밖의 토큰 — swift' "F3 모르는 언어 swift"
bad 2026-11-25-a.txt 'langs: python python
section: Fixed
---
b
' '같은 토큰이 겹친다' "F3 겹친 언어"
bad 2026-11-25-a.txt 'langs: go
section: Fix
---
b
' '중 하나다 — Fix' "F3 모르는 section"
bad 2026-11-25-a.txt 'langs: go
section: Fixed
b
' '`---` 줄이 없다' "F3 --- 없음"
bad 2026-11-25-a.txt 'langs: go
section: Fixed
---
' '본문이 없다' "F3 빈 본문"
bad 2026-11-25-a.txt 'langs: go
section: Fixed
---
b
c
' '정확히 한 줄이다' "F3 두 줄 본문"
bad notes.txt 'langs: go
section: Fixed
---
b
' '이름이 `<YYYY-MM-DD>-<slug>.txt`' "F3 이름이 규칙 밖"
bad 2026-11-25-a.txt 'langs: go
langs: python
section: Fixed
---
b
' '키 `langs` 가 겹친다' "F3 겹친 키 langs"
bad 2026-11-25-a.txt 'langs: go
section: Fixed
section: Added
---
b
' '키 `section` 가 겹친다' "F3 겹친 키 section"
bad 2026-11-25-a.txt 'langs: go

section: Fixed
---
b
' '머리에 빈 줄이 있다' "F3 머리의 빈 줄"
bad 2026-11-25-a.txt 'langs: go
section: Fixed
foo
---
b
' '`<키>: <값>` 꼴이 아니다 — foo' "F3 머리 줄에 : 없음"
bad 2026-11-25-a.txt 'langs: go  python
section: Fixed
---
b
' '공백 하나로 구분한다' "F3 langs 공백 둘"
# 끝 공백은 편집기가 지우므로 SP 변수로 넣는다.
SP=' '
bad 2026-11-25-a.txt "langs: go${SP}
section: Fixed
---
b
" '공백 하나로 구분한다' "F3 langs 끝 공백"
bad 2026-11-25-a.txt 'langs: go
section: Fixed
---
 앞 공백
' '본문의 앞뒤에 공백' "F3 본문 앞 공백"
bad 2026-11-25-a.txt "langs: go
section: Fixed
---
b${SP}
" '본문의 앞뒤에 공백' "F3 본문 끝 공백"
fresh; mkdir -p "$TMP/changelog.d/sub"
_out="$(chk)"; assert_rejects "$_out" 'changelog.d/sub' "F3 디렉터리"
assert_contains "$_out" '조각은 파일이다' "F3 디렉터리 — 사유"
# 심볼릭 링크 거부는 sh 에서 이식 가능하게 만들 수 없어 시험하지 않는다(Git Bash 의 ln -s 는 복사로 떨어질 수 있다).

# F3b check 가 rc 1 로 거부해도 changelog.d/ 는 바이트까지 그대로다.
fresh; frag 2026-11-25-a.txt 'langs: go
section: Fixed
---
b
'
frag 2026-11-25-b.txt 'langs: go
section: Fix
---
b
'
_before="$(snap)"; _out="$(chk)"
assert_contains "$_out" '__rc=1' "F3b 거부 사례"
assert_eq "$_before" "$(snap)" "F3b 거부는 아무것도 쓰지 않는다"

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

# ---- W. 물결 컴파일 · 독립 대조 · preview ----
# compileWave · verifyWave(scripts/lib/changelog-wave.mjs)는 release 전이라 시험 도우미로 잰다 —
#   node changelog-wave-probe.mjs <root> <날짜> <lang=ver,…> <글 파일>   verifyWave: rc 0 오류 없음 · 1 오류 · 2 인자/뿌리
#   node changelog-wave-probe.mjs --compile <root> <날짜> <lang=ver,…>   compileWave: 글은 stdout · updates 는 stderr
# 바이트 대조는 파일끼리 cmp 로 한다 — $( ) 는 끝 줄바꿈을 먹는다.
PROBE="$DIR/changelog-wave-probe.mjs"
W="$TMP/_w" # 골든 · 출력 · 변형 — changelog.d/ 밖이라 조각으로 읽히지 않는다(fresh 가 함께 지운다)
probe() { node "$PROBE" "$@" 2>&1 && echo '__rc=0' || echo "__rc=$?"; }
to_file() { # <출력 파일> <명령…> — stdout 은 파일로, stderr 는 <출력 파일>.err 로, 종료 코드는 _rc 로
  _tf="$1"; shift; _rc=0; "$@" > "$_tf" 2> "$_tf.err" || _rc=$?
}
same_bytes() { # <기대 파일> <실제 파일> <메시지> — 판정은 cmp, 다르면 diff 를 찍는다
  if cmp -s "$1" "$2"; then _sb=same; else _sb=differ; diff "$1" "$2" >&2 || true; fi
  assert_eq same "$_sb" "$3"
}
# W 픽스처 — 조각 넷(과제 4 의 R 절도 쓴다).
wfix() {
  fresh; mkdir -p "$W"
  frag 2026-11-25-a.txt 'langs: python go
section: Fixed
---
A 고침
'
  frag 2026-11-25-b.txt 'langs: dotnet
section: Added
---
B 추가
'
  frag 2026-11-26-c.txt 'langs: python dotnet
section: Fixed
---
C 고침
'
  frag 2026-11-26-d.txt 'langs: ruby python
section: Security
---
D 보안
'
}
W1_WAVE='python=1.0.8,dotnet=1.0.8,go=1.2.6'
# 골든 셋 — 계획(§8.5 과제 2)의 글 그대로. 파일로 쓸 때 printf 가 붙이는 \n 이 마지막 빈 줄이다.
W1_GOLD='## [물결] - 2026-12-01 (Python 1.0.8 · .NET 1.0.8 · Go 1.2.6)

TODO(release-notes) 물결 머리말 — 이 물결이 내보내는 언어 · 판과 그 근거를 쓴다.

### Fixed
- **(Python · Go)** A 고침

## [1.0.8] - 2026-12-01 (Python · .NET)

같은 물결의 머리말과 여러 절에 걸친 항목은 위 `[물결] - 2026-12-01` 절에 있습니다.

TODO(release-notes) 이 절의 판 종류 · 공개 API 변경 수 · 같은 번호 경고를 쓴다.

### Added
- **(.NET)** B 추가

### Fixed
- **(Python · .NET)** C 고침

### Security
- **(Python)** D 보안

## [1.2.6] - 2026-12-01 (Go)

같은 물결의 머리말과 여러 절에 걸친 항목은 위 `[물결] - 2026-12-01` 절에 있습니다.

TODO(release-notes) 이 절의 판 종류 · 공개 API 변경 수 · 같은 번호 경고를 쓴다.
'
W2_GOLD='## [Unreleased]

### Added
- **(.NET)** B 추가

### Fixed
- **(Python · Go)** A 고침
- **(Python · .NET)** C 고침

### Security
- **(Python · Ruby)** D 보안
'
W3_GOLD='## [?] - 2026-12-01 (Go)

TODO(release-notes) 물결 머리말 — 이 물결이 내보내는 언어 · 판과 그 근거를 쓴다.

### Fixed
- **(Go)** A 고침
'

# W1 compileWave — 글은 골든과 바이트까지 같고, updates 는 a · b · c 가 빈 langs(지울 조각) · d 는 ruby 가 남는다.
wfix; printf '%s\n' "$W1_GOLD" > "$W/w1.gold"
to_file "$W/w1.out" node "$PROBE" --compile "$TMP" 2026-12-01 "$W1_WAVE"
assert_eq 0 "$_rc" "W1 compileWave rc 0"
same_bytes "$W/w1.gold" "$W/w1.out" "W1 물결 글은 골든과 바이트까지 같다"
assert_eq 'updates: [{"name":"2026-11-25-a.txt","langs":[]},{"name":"2026-11-25-b.txt","langs":[]},{"name":"2026-11-26-c.txt","langs":[]},{"name":"2026-11-26-d.txt","langs":["ruby"]}]' \
  "$(cat "$W/w1.out.err")" "W1 updates — a · b · c 는 지울 조각, d 는 ruby 가 남는다"

# W2 preview — 모든 언어, 지금의 [Unreleased] 꼴(태그는 langs 전부).
printf '%s\n' "$W2_GOLD" > "$W/w2.gold"
to_file "$W/w2.out" node "$CLI" preview --root="$TMP"
assert_eq 0 "$_rc" "W2 preview rc 0"
same_bytes "$W/w2.gold" "$W/w2.out" "W2 preview 는 골든과 바이트까지 같다"

# W3 preview <lang> --date= — 그 언어 하나의 물결(판 자리 ?), 태그는 내보내는 언어뿐.
printf '%s\n' "$W3_GOLD" > "$W/w3.gold"
to_file "$W/w3.out" node "$CLI" preview go --date=2026-12-01 --root="$TMP"
assert_eq 0 "$_rc" "W3 preview go rc 0"
same_bytes "$W/w3.gold" "$W/w3.out" "W3 preview go --date=2026-12-01 은 골든과 바이트까지 같다"
# 날짜 기본은 오늘(이 기계의 지역 날짜) — 실행이 자정을 넘어도 거짓 빨강이 나지 않게 앞뒤 날짜 중 하나면 된다.
_d1="$(date +%Y-%m-%d)"; _out="$(run preview go --root="$TMP")"; _d2="$(date +%Y-%m-%d)"
case "$_out" in *"## [?] - $_d1 (Go)"*|*"## [?] - $_d2 (Go)"*) _today=ok ;; *) _today="$_out" ;; esac
assert_eq ok "$_today" "W3 preview 의 날짜 기본은 오늘"

# W4 verifyWave — 독립 대조. W1 골든은 오류 0(대조군), 변형은 저마다 rc 1 과 그것을 잡는 검사의 바늘.
_out="$(probe "$TMP" 2026-12-01 "$W1_WAVE" "$W/w1.gold")"
assert_contains "$_out" '__rc=0' "W4 대조군 — W1 골든은 verifyWave 오류가 없다"
assert_not_contains "$_out" '물결 대조' "W4 대조군 — 오류 줄이 없다"
mut() { # <메시지> <awk 프로그램> — 골든을 고쳐 $W/m.txt 로. 무동작 변형은 그 자체로 실패다.
  awk "$2" "$W/w1.gold" > "$W/m.txt"
  if cmp -s "$W/w1.gold" "$W/m.txt"; then _mu=same; else _mu=changed; fi
  assert_eq changed "$_mu" "$1 — 변형이 글을 바꿨다"
}
w4() { # <바늘> <메시지> — $W/m.txt 를 W1 물결로 대조한다
  _out="$(probe "$TMP" 2026-12-01 "$W1_WAVE" "$W/m.txt")"
  assert_rejects "$_out" "$1" "$2"
}
mut "W4 항목 하나 지움" '$0 != "- **(.NET)** B 추가"'
w4 '물결 대조 6: 빠진 항목 — 1.0.8 | Added | dotnet | B 추가' "W4 항목 하나 지움"
mut "W4 항목 하나 겹침" '{ print } $0 == "- **(.NET)** B 추가" { print }'
w4 '물결 대조 6: 남는 항목 — 1.0.8 | Added | dotnet | B 추가' "W4 항목 하나 겹침"
mut "W4 같은 항목을 ### 앞에 한 번 더" '$0 == "### Added" { print "- **(.NET)** B 추가"; print "" } { print }'
w4 '물결 대조 2: 「## [1.0.8] - 2026-12-01 (Python · .NET)」 — `###` 앞의 목록 항목' "W4 같은 항목을 ### 앞에 한 번 더"
mut "W4 A 고침을 ### Added 아래로" '!d && $0 == "### Fixed" { print "### Added"; d = 1; next } { print }'
w4 '물결 대조 6: 빠진 항목 — 물결 | Fixed | python go | A 고침' "W4 A 고침을 ### Added 아래로"
assert_contains "$_out" '물결 대조 6: 남는 항목 — 물결 | Added | python go | A 고침' "W4 A 고침을 ### Added 아래로 — 남는 쪽"
mut "W4 A 고침을 [1.2.6] 절로" '!d && $0 == "### Fixed" { d = 1; s = 3 } s > 0 { s--; next } { print } END { print "### Fixed"; print "- **(Python · Go)** A 고침"; print "" }'
w4 '물결 대조 6: 빠진 항목 — 물결 | Fixed | python go | A 고침' "W4 A 고침을 [1.2.6] 절로"
assert_contains "$_out" '물결 대조 6: 남는 항목 — 1.2.6 | Fixed | python go | A 고침' "W4 A 고침을 [1.2.6] 절로 — 남는 쪽"
mut "W4 [1.2.6] (Go) 절을 통째로 뺌" '$0 == "## [1.2.6] - 2026-12-01 (Go)" { exit } { print }'
w4 '물결 대조 4: 물결 언어 Go(1.2.6) 의 언어 절이 없다' "W4 [1.2.6] (Go) 절을 통째로 뺌"
mut "W4 공통 절 제목에서 · Go 1.2.6 을 뺌" 'NR == 1 { print "## [물결] - 2026-12-01 (Python 1.0.8 · .NET 1.0.8)"; next } { print }'
w4 '물결 대조 5: 「## [물결] - 2026-12-01 (Python 1.0.8 · .NET 1.0.8)」 — 공통 절의 괄호 안은' "W4 공통 절 제목에서 · Go 1.2.6 을 뺌"
mut "W4 모르는 문단 하나" '$0 == "### Added" { print "아무도 모르는 문단."; print "" } { print }'
w4 '물결 대조 2: 「## [1.0.8] - 2026-12-01 (Python · .NET)」 — 모르는 문단' "W4 모르는 문단 하나"
# 세 변형 더 — 계획의 목록 밖이지만 검사 1 · 2 의 갈래(날짜 · 머리말 · 생성 문단의 자리)를 하나씩 짚는다.
mut "W4 언어 절의 날짜가 물결과 다름" '$0 == "## [1.2.6] - 2026-12-01 (Go)" { print "## [1.2.6] - 2026-12-02 (Go)"; next } { print }'
w4 '물결 대조 1: 「## [1.2.6] - 2026-12-02 (Go)」 — 날짜가 물결의 날짜(2026-12-01)가 아니다' "W4 언어 절의 날짜가 물결과 다름"
mut "W4 물결 글의 머리말" 'NR == 1 { print "머리말."; print "" } { print }'
w4 '물결 대조 1: 물결 글에 머리말이 있다' "W4 물결 글의 머리말"
mut "W4 언어 절의 손글 자리 빠짐" '!d && $0 == "TODO(release-notes) 이 절의 판 종류 · 공개 API 변경 수 · 같은 번호 경고를 쓴다." { d = 1; getline; next } { print }'
w4 '물결 대조 2: 「## [1.0.8] - 2026-12-01 (Python · .NET)」 — 생성 문단이 이 절의 자리와 다르다' "W4 언어 절의 손글 자리 빠짐"
# 1,025 B 제목 줄 — 판이 긴 한 언어 물결(판 꼴은 release 가 본다). 제목 줄 = `## [` 4 + 판 + `] - 2026-12-01 (Go)` 19 + \n 1.
_v1000="1.2.6-$(repeat 994)"; _v1001="1.2.6-$(repeat 995)"
to_file "$W/v1000.txt" node "$PROBE" --compile "$TMP" 2026-12-01 "go=$_v1000"
assert_eq 1024 "$(head -n 1 "$W/v1000.txt" | wc -c | tr -d ' ')" "W4 경계 픽스처 — 제목 줄 1,024 B"
_out="$(probe "$TMP" 2026-12-01 "go=$_v1000" "$W/v1000.txt")"
assert_contains "$_out" '__rc=0' "W4 1,024 B 제목 줄은 상한 안(대조군)"
to_file "$W/v1001.txt" node "$PROBE" --compile "$TMP" 2026-12-01 "go=$_v1001"
assert_eq 1025 "$(head -n 1 "$W/v1001.txt" | wc -c | tr -d ' ')" "W4 경계 픽스처 — 제목 줄 1,025 B"
_out="$(probe "$TMP" 2026-12-01 "go=$_v1001" "$W/v1001.txt")"
assert_rejects "$_out" '항목 1025B > 1024B' "W4 1,025 B 제목 줄"
assert_contains "$_out" '물결 대조 3: ' "W4 1,025 B 제목 줄 — 검사 3 이 잡는다"
# 판 하나짜리 물결(Python · .NET 1.0.8)의 글은 대조군이고, 그 앞에 공통 절을 덧붙이면 rc 1.
to_file "$W/one.txt" node "$PROBE" --compile "$TMP" 2026-12-01 python=1.0.8,dotnet=1.0.8
_out="$(probe "$TMP" 2026-12-01 python=1.0.8,dotnet=1.0.8 "$W/one.txt")"
assert_contains "$_out" '__rc=0' "W4 판 하나짜리 물결의 글은 오류가 없다(대조군)"
{ printf '## [물결] - 2026-12-01 (Python 1.0.8 · .NET 1.0.8)\n\nTODO(release-notes) 물결 머리말 — 이 물결이 내보내는 언어 · 판과 그 근거를 쓴다.\n\n'; cat "$W/one.txt"; } > "$W/m.txt"
_out="$(probe "$TMP" 2026-12-01 python=1.0.8,dotnet=1.0.8 "$W/m.txt")"
assert_rejects "$_out" '물결 대조 5: 「## [물결] - 2026-12-01 (Python 1.0.8 · .NET 1.0.8)」 — 판이 하나인 물결에는 공통 절이 없다' "W4 판 하나짜리 물결에 공통 절 덧붙임"
# 도우미의 인자 오류는 rc 2 — 판정(rc 1)과 섞이면 위의 rc 1 단언이 공허해진다.
_out="$(probe "$TMP" 2026-02-30 "$W1_WAVE" "$W/w1.gold")"; assert_contains "$_out" '__rc=2' "W4 도우미 — 없는 날짜는 rc 2"
_out="$(probe "$TMP" 2026-12-01 swift=1.0.0 "$W/w1.gold")"; assert_contains "$_out" '__rc=2' "W4 도우미 — 모르는 언어는 rc 2"
_out="$(probe "$TMP" 2026-12-01 "$W1_WAVE" "$W/no-such.txt")"; assert_contains "$_out" '__rc=2' "W4 도우미 — 글 파일이 없으면 rc 2"

# W5 preview 사용법 — rc 2 와 그 사유 · 아무것도 안 쓴다. 사유 바늘이 없으면 「preview 를 모른다」(rc 2)도 통과한다.
w5() { # <메시지> <사유 바늘> <인자…>
  _m="$1"; _n="$2"; shift 2
  _out="$(run "$@")"
  assert_contains "$_out" '__rc=2' "$_m"
  assert_contains "$_out" "$_n" "$_m — 사유"
}
_before="$(snap)"
w5 "W5 모르는 언어 swift" '모르는 언어 — swift' preview swift --root="$TMP"
w5 "W5 언어 둘" 'preview 의 위치 인자는' preview go python --root="$TMP"
w5 "W5 언어 없이 --date=" '--date= 는 <lang> 과 함께 준다' preview --date=2026-12-01 --root="$TMP"
w5 "W5 없는 날짜" '있는 날짜의 YYYY-MM-DD 다 — 2026-02-30' preview go --date=2026-02-30 --root="$TMP"
w5 "W5 날짜 꼴" '있는 날짜의 YYYY-MM-DD 다 — 12/01/2026' preview go --date=12/01/2026 --root="$TMP"
w5 "W5 빈 --date=" '--date= 는 값과 함께 한 번만 준다' preview go --date= --root="$TMP"
w5 "W5 겹친 --date=" '--date= 는 값과 함께 한 번만 준다' preview go --date=2026-12-01 --date=2026-12-02 --root="$TMP"
w5 "W5 모르는 인자 --dat=" '모르는 인자 — --dat=2026-12-01' preview go --dat=2026-12-01 --root="$TMP"
w5 "W5 check 는 위치 인자를 받지 않는다" 'check 의 위치 인자는' check go --root="$TMP"
w5 "W5 check 는 --date= 를 받지 않는다" '모르는 인자 — --date=2026-12-01' check --date=2026-12-01 --root="$TMP"
assert_eq "$_before" "$(snap)" "W5 사용법 오류는 아무것도 쓰지 않는다"

# W6 조각 문법 오류 — preview 는 rc 1(파일 이름), 도우미는 rc 2(판정이 아니다).
frag 2026-11-27-x.txt 'langs: go
section: Fix
---
x
'
_out="$(run preview --root="$TMP")"; assert_rejects "$_out" 'changelog.d/2026-11-27-x.txt' "W6 preview — 깨진 조각"
_out="$(run preview go --date=2026-12-01 --root="$TMP")"; assert_rejects "$_out" 'changelog.d/2026-11-27-x.txt' "W6 preview go — 깨진 조각"
_out="$(probe "$TMP" 2026-12-01 "$W1_WAVE" "$W/w1.gold")"; assert_contains "$_out" '__rc=2' "W6 도우미 — 뿌리의 조각이 깨지면 rc 2"

# W7 대기 조각이 없으면 — preview 는 [Unreleased] 제목뿐, preview <lang> 은 제목과 물결 머리말 자리뿐.
fresh; mkdir -p "$W"
printf '## [Unreleased]\n\n' > "$W/e.gold"
to_file "$W/e.out" node "$CLI" preview --root="$TMP"
assert_eq 0 "$_rc" "W7 preview rc 0"
same_bytes "$W/e.gold" "$W/e.out" "W7 preview — [Unreleased] 제목과 빈 줄뿐"
printf '## [?] - 2026-12-01 (PHP)\n\nTODO(release-notes) 물결 머리말 — 이 물결이 내보내는 언어 · 판과 그 근거를 쓴다.\n\n' > "$W/e2.gold"
to_file "$W/e2.out" node "$CLI" preview php --date=2026-12-01 --root="$TMP"
assert_eq 0 "$_rc" "W7 preview php rc 0"
same_bytes "$W/e2.gold" "$W/e2.out" "W7 preview php — 제목과 물결 머리말 자리뿐"

# ---- M. migrate (픽스처 생성기 겸) ----
# ⚠️ 이 절은 `[Unreleased]` 의 고정 문단을 다시 쓰지 않는다 — 문구를 소유하는 것은 changelog-ledger.mjs 의 UNRELEASED_POINTER 다.
# migrate 가 쓴 문단이 그 상수와 같다는 증거는 M3(둘째 실행이 「이미 전환됐다」 — isUnreleasedPointer 가 migrate 자신의 출력을 받는다)다.
CL="$TMP/CHANGELOG.md"
MS="$(mktemp -d)" # fresh 가 TMP 를 지우므로 실행 사이에 남길 비교 파일은 여기 둔다
trap 'rm -rf "$TMP" "${MS:?}"' EXIT
# 루트 — 머리 · `[Unreleased]`(<본문>) · 릴리스 절 하나. 본문은 `[Unreleased]` 제목 아래 빈 줄 뒤에 그대로 놓인다.
mroot() { # <[Unreleased] 본문>
  fresh; printf '# Changelog\n\n## [Unreleased]\n\n%s\n## [1.0.0] - 2026-11-01\n\n### Fixed\n\n- **(Go)** old\n' "$1" > "$CL"
}
M_OLD='### Fixed

- **(Java · Kotlin)** J 고침
- **(Go · Python)** G 고침

### Security

- **(전 언어)** S 보안
'
unrel() { awk '/^## /{p=($0=="## [Unreleased]")} p' "$1"; } # 파일의 `[Unreleased]` 블록
mig() { run migrate --date=2026-11-28 --root="$TMP" "$@"; }

# M1 옛 꼴 항목 셋 → 조각 셋(이름순 = 블록 순서) · 루트는 포인터 · preview 의 항목은 원래 줄과 태그만 다르다.
mroot "$M_OLD"; sed -n '/^## \[1.0.0\]/,$p' "$CL" > "$TMP/_tail.gold"
_out="$(mig)"
assert_contains "$_out" 'ok   migrate: 항목 3개 → 조각 3개' "M1 출력"; assert_contains "$_out" '__rc=0' "M1 rc 0"
assert_eq '2026-11-28-unreleased-001.txt 2026-11-28-unreleased-002.txt 2026-11-28-unreleased-003.txt' "$(ls "$TMP/changelog.d" | tr '\n' ' ' | sed 's/ $//')" "M1 조각 이름 — 날짜-unreleased-NNN"
assert_eq 'langs: java kotlin' "$(sed -n 1p "$TMP/changelog.d/2026-11-28-unreleased-001.txt")" "M1 001 의 langs"
assert_eq 'section: Fixed' "$(sed -n 2p "$TMP/changelog.d/2026-11-28-unreleased-001.txt")" "M1 001 의 section"
assert_eq 'J 고침' "$(sed -n 4p "$TMP/changelog.d/2026-11-28-unreleased-001.txt")" "M1 001 의 본문"
assert_eq 'langs: python go' "$(sed -n 1p "$TMP/changelog.d/2026-11-28-unreleased-002.txt")" "M1 002 의 langs — DEPLOY_LANGS 순서"
assert_eq 'langs: python dotnet ruby node rust java kotlin go php' "$(sed -n 1p "$TMP/changelog.d/2026-11-28-unreleased-003.txt")" "M1 003 의 langs — 전 언어는 아홉"
assert_eq 'section: Security' "$(sed -n 2p "$TMP/changelog.d/2026-11-28-unreleased-003.txt")" "M1 003 의 section"
assert_eq '# Changelog' "$(sed -n 1p "$CL")" "M1 머리말은 그대로"
sed -n '/^## \[1.0.0\]/,$p' "$CL" > "$TMP/_tail.out"
same_bytes "$TMP/_tail.gold" "$TMP/_tail.out" "M1 [Unreleased] 밖의 블록은 바이트까지 그대로"
assert_eq 0 "$(grep -c 'J 고침' "$CL" || true)" "M1 루트에 옛 항목이 남지 않는다"
unrel "$CL" > "$MS/ptr1"
_out="$(run preview --root="$TMP")"
assert_contains "$_out" '- **(Java · Kotlin)** J 고침' "M1 preview — 첫째 줄(태그 순서만 정규)"
assert_contains "$_out" '- **(Python · Go)** G 고침' "M1 preview — 둘째 줄(Go · Python → Python · Go)"
assert_contains "$_out" '- **(Python · .NET · Ruby · Node · Rust · Java · Kotlin · Go · PHP)** S 보안' "M1 preview — 전 언어는 아홉 표시명"

# M3 둘째 실행 — 이미 포인터면 안 쓴다(조각이 셋 있어도 포인터 검사가 먼저다). migrate 가 쓴 문단을 isUnreleasedPointer 가 받는다는 증거다.
_before="$(snap)"
_out="$(mig)"
assert_contains "$_out" '이미 전환됐다' "M3 둘째 실행"; assert_contains "$_out" '__rc=0' "M3 rc 0"
assert_eq "$_before" "$(snap)" "M3 아무것도 안 쓴다"

# M5 deploy-facts.sh 없는 뿌리의 빈 [Unreleased] → 포인터(DEPLOY_LANGS 는 항목이 있을 때만 읽는다) — 픽스처 생성기의 꼴이다.
mroot ''; rm -f "$TMP/scripts/lib/deploy-facts.sh"
_out="$(mig)"
assert_contains "$_out" 'ok   migrate: 항목 0개 → 조각 0개' "M5 출력"; assert_contains "$_out" '__rc=0' "M5 rc 0"
assert_eq 0 "$(ls "$TMP/changelog.d" 2>/dev/null | wc -l | tr -d ' ')" "M5 조각 없음"
unrel "$CL" > "$MS/ptr5"
same_bytes "$MS/ptr1" "$MS/ptr5" "M5 [Unreleased] 블록 = M1 의 것(둘 다 migrate 가 썼다)"
_out="$(mig)"; assert_contains "$_out" '이미 전환됐다' "M5 둘째 실행도 이미 전환됐다(migrate 의 출력을 포인터로 읽는다)"

# M2 거부 — 사유 바늘 + rc 1 · 루트와 changelog.d/ 의 cksum 이 그대로. 픽스처마다 결함은 하나다.
mbad() { # <[Unreleased] 본문> <사유 바늘> <메시지>
  mroot "$1"; _before="$(snap)"; _out="$(mig)"
  assert_rejects "$_out" "$2" "$3"
  assert_eq "$_before" "$(snap)" "$3 — 아무것도 안 쓴다"
}
mbad '### Fixed

- 태그 없는 항목
' '태그가 없다' "M2 태그 없음"
mbad '### Fixed

- **(Swift)** S 고침
' '모르는 언어 이름 — Swift' "M2 모르는 이름 (Swift)"
mbad '### Fixed

- **(Java · )** S 고침
' '빈 언어 이름' "M2 빈 이름"
mbad '### Fixed

- **(전 언어 · Java)** S 고침
' '`전 언어` 는 혼자 쓴다' "M2 전 언어 + 다른 이름"
mbad '### Fixed

- **(Java · Java)** S 고침
' '언어 이름이 겹친다 — Java' "M2 겹친 이름"
mbad '- **(Java)** 절 밖 항목

### Fixed

- **(Go)** 고침
' '`### <절>` 밖의 항목' "M2 ### 밖 항목"
mbad '### Fixed

문단입니다.
' '항목이 아니다' "M2 문단"
mbad '### Notes

- **(Java)** 고침
' '모르는 `###` 제목 — Notes' "M2 ### Notes"
mbad '### Fixed

- **(Java)** 첫 줄
  이어지는 줄
' '여러 줄' "M2 여러 줄 항목"
# 조각 문법(공백 · 상한)은 parseFragment 의 규칙이다 — migrate 는 그 거부를 원래 항목 줄과 함께 relay 한다. 조각은 쓰이지 않았다(디렉터리도 없다).
mrelay() { # <[Unreleased] 본문> <사유 바늘> <항목 줄 바늘> <메시지>
  mbad "$1" "$2" "$4"
  assert_contains "$_out" "$3" "$4 — 원래 항목 줄을 가리킨다"
  assert_not_contains "$_out" 'unreleased-001' "$4 — 쓰이지 않은 조각 이름을 말하지 않는다"
  assert_eq no "$([ -e "$TMP/changelog.d" ] && echo yes || echo no)" "$4 — changelog.d/ 가 없다"
}
mrelay "### Fixed

- **(Go)** x$SP
" '본문의 앞뒤에 공백이 있다' "— - **(Go)** x$SP" "M2 본문 끝 공백"
mrelay '### Fixed

- **(Go)**  x
' '본문의 앞뒤에 공백이 있다' '— - **(Go)**  x' "M2 본문 앞 공백"
mrelay "### Security

- **(전 언어)** $(repeat 960)
" '컴파일한 줄이 1039B > 1024B 다' '— - **(전 언어)** xxxx' "M2 컴파일한 줄 상한 초과"
# 한 번에 모아서 — 결함이 둘이면 둘 다 보인다.
mroot '### Fixed

- **(Swift)** a
- 태그 없음
'; _out="$(mig)"
assert_contains "$_out" '모르는 언어 이름 — Swift' "M2 모음 — 첫째 결함"; assert_contains "$_out" '태그가 없다' "M2 모음 — 둘째 결함"
# 루트 모양 — `[Unreleased]` 가 없거나 둘이거나 CHANGELOG.md 가 없다.
fresh; printf '# Changelog\n\n## [1.0.0] - 2026-11-01\n\n### Fixed\n\n- **(Go)** old\n' > "$CL"; _before="$(snap)"; _out="$(mig)"
assert_rejects "$_out" '`## [Unreleased]` 가 없다' "M2 [Unreleased] 없음"; assert_eq "$_before" "$(snap)" "M2 [Unreleased] 없음 — 아무것도 안 쓴다"
fresh; printf '# Changelog\n\n## [Unreleased]\n\n## [Unreleased]\n' > "$CL"; _before="$(snap)"; _out="$(mig)"
assert_rejects "$_out" '`## [Unreleased]` 가 둘이다' "M2 [Unreleased] 둘"; assert_eq "$_before" "$(snap)" "M2 [Unreleased] 둘 — 아무것도 안 쓴다"
fresh; _before="$(snap)"; _out="$(mig)"
assert_rejects "$_out" 'CHANGELOG.md 가 없다' "M2 CHANGELOG.md 없음"; assert_eq "$_before" "$(snap)" "M2 CHANGELOG.md 없음 — 아무것도 안 쓴다"
# DEPLOY_LANGS 를 못 읽으면 항목이 있어도 거부 — 쓰기 전이다.
mroot "$M_OLD"; rm -f "$TMP/scripts/lib/deploy-facts.sh"; _before="$(snap)"; _out="$(mig)"
assert_rejects "$_out" 'deploy-facts.sh' "M2 항목이 있는데 deploy-facts.sh 가 없다"; assert_eq "$_before" "$(snap)" "M2 deploy-facts.sh 없음 — 아무것도 안 쓴다"

# M4 changelog.d/ 에 파일이 있으면 거부(섞지 않는다) — 항목이 있어도 비어 있어도.
mroot "$M_OLD"; frag 2026-11-20-x.txt 'langs: go
section: Fixed
---
x
'; _before="$(snap)"; _out="$(mig)"
assert_rejects "$_out" '`changelog.d/` 에 파일이 있다' "M4 항목 + 조각"; assert_eq "$_before" "$(snap)" "M4 아무것도 안 쓴다"
mroot ''; frag 2026-11-20-x.txt 'langs: go
section: Fixed
---
x
'; _before="$(snap)"; _out="$(mig)"
assert_rejects "$_out" '`changelog.d/` 에 파일이 있다' "M4 빈 [Unreleased] + 조각"; assert_eq "$_before" "$(snap)" "M4 빈 [Unreleased] — 아무것도 안 쓴다"

# M6 CRLF 뿌리 — 읽을 때 LF 로 맞추고 쓰는 것은 LF 다: 결과가 LF 뿌리의 결과와 바이트까지 같다(그 밖은 다르지 않다).
mroot "$M_OLD"; mig > /dev/null; cp "$CL" "$MS/lf.out"
mroot "$M_OLD"; awk '{ printf "%s\r\n", $0 }' "$CL" > "$TMP/_crlf.in"; cp "$TMP/_crlf.in" "$CL"
_out="$(mig)"; assert_contains "$_out" '__rc=0' "M6 CRLF 뿌리 rc 0"
same_bytes "$MS/lf.out" "$CL" "M6 CRLF 입력의 결과는 LF 입력의 결과와 바이트까지 같다"

# M7 사용법 — rc 2 · 아무것도 안 쓴다. 날짜 꼴 · 위치 인자 · 빈 --root=.
mroot "$M_OLD"; _before="$(snap)"
_out="$(run migrate --date=2026-02-30 --root="$TMP")"; assert_contains "$_out" '__rc=2' "M7 없는 날짜 rc 2"; assert_contains "$_out" '--date= 는' "M7 없는 날짜 사유"
_out="$(run migrate extra --root="$TMP")"; assert_contains "$_out" '__rc=2' "M7 위치 인자 rc 2"; assert_contains "$_out" 'migrate 의 위치 인자는 0개다' "M7 위치 인자 사유"
_out="$(run migrate --root=)"; assert_contains "$_out" '__rc=2' "M7 빈 --root= rc 2"
assert_eq "$_before" "$(snap)" "M7 사용법 오류는 아무것도 쓰지 않는다"
# --date 를 안 주면 오늘 — 이름은 `<YYYY-MM-DD>-unreleased-NNN.txt` 꼴이다.
_out="$(run migrate --root="$TMP")"; assert_contains "$_out" '__rc=0' "M7 --date 생략 rc 0"
assert_eq 3 "$(ls "$TMP/changelog.d" 2>/dev/null | grep -c '^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-unreleased-00[123]\.txt$' || true)" "M7 --date 생략 — 오늘 날짜의 이름 셋"

assert_report
