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
assert_contains "$_out" '> 1024B' "F4 태그가 긴 줄 — 사유(상한 초과)"

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
# W 픽스처 — 조각 넷(과제 4 의 R 절도 쓴다). wfrags 는 조각만 쓴다(R 절은 migrate 로 뿌리를 만든 뒤에 둔다).
wfix() { fresh; mkdir -p "$W"; wfrags; }
wfrags() {
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

# ---- R. release ----
# 뿌리 — 옛 꼴(빈 `[Unreleased]` + `[1.0.7]` 절 하나)로 쓰고 migrate 로 포인터 꼴로 바꾼다(과제 3). 이 절도 포인터 문단을 다시
# 쓰지 않는다 — 뿌리의 `[Unreleased]` 는 migrate 가 쓴 것이다. 조각은 그 뒤에 둔다(비지 않은 changelog.d/ 는 migrate 가 거부한다).
# 거부 사례는 바늘 · rc · 뿌리 전체(CHANGELOG.md · changelog.d/ 를 담는다)의 cksum 을 본다.
rold() { printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.7] - 2026-11-03 (Python)\n\n### Fixed\n- **(Python)** 옛 고침\n' > "$CL"; }
rfix() { fresh; mkdir -p "$W"; rold; mig > /dev/null; wfrags; } # 포인터 꼴 뿌리 + W 조각 넷
rel() { run release --root="$TMP" "$@"; }
r1() { rel --date=2026-12-01 python=1.0.8 dotnet=1.0.8 go=1.2.6; } # R1 의 물결(W1 과 같다)
dsnap() { (cd "$TMP" && find changelog.d -type f 2>/dev/null | LC_ALL=C sort | xargs cksum 2>/dev/null | cksum); } # changelog.d/ 만
# <뿌리 파일> 을 <제목 접두> 로 시작하는 첫 줄 앞에서 갈라 그 사이에 <끼울 파일> 을 넣는다 — 「[Unreleased] 블록 바로 뒤에 끼운 것」.
splice() { # <뿌리 파일> <제목 접두> <끼울 파일>
  awk -v h="$2" 'index($0, h) == 1 { exit } { print }' "$1"; cat "$3"; awk -v h="$2" 'index($0, h) == 1 { p = 1 } p' "$1"
}

# R1 W 픽스처 → 물결 하나: rc 0 · 루트 = 릴리스 전 루트의 `[Unreleased]` 블록 바로 뒤에 W1 골든을 끼운 것(바이트) · a · b · c 는
# 지워지고 d 는 renderFragment 꼴의 `langs: ruby` 로 다시 쓰인다.
rfix; cp "$CL" "$MS/r1.pre"; printf '%s\n' "$W1_GOLD" > "$MS/w1.gold"; splice "$CL" '## [1.0.7] ' "$MS/w1.gold" > "$MS/r1.gold"
_out="$(r1)"
assert_contains "$_out" '__rc=0' "R1 rc 0"
assert_contains "$_out" 'ok   release 2026-12-01: 절 3개 · 항목 4개 · 조각 갱신 1 · 삭제 3' "R1 출력 — 절 · 항목 · 갱신 · 삭제 수"
assert_not_contains "$_out" '대기 노트가 없다' "R1 세 언어 모두 대기 노트가 있다 — 알림이 없다"
same_bytes "$MS/r1.gold" "$CL" "R1 루트 = [Unreleased] 블록 바로 뒤에 W1 골든을 끼운 것"
assert_eq '2026-11-26-d.txt' "$(ls "$TMP/changelog.d")" "R1 a · b · c 는 지워지고 d 만 남는다"
printf 'langs: ruby\nsection: Security\n---\nD 보안\n' > "$MS/r1.d"
same_bytes "$MS/r1.d" "$TMP/changelog.d/2026-11-26-d.txt" "R1 d 는 renderFragment 꼴의 langs: ruby"
cp "$CL" "$MS/r1.out"

# R2(검토 초점 4) 두 물결에 걸친 조각 d — 둘째 물결(ruby)에서 남은 언어 태그로 정확히 한 번 나오고, 그 뒤 지워진다.
R2_GOLD='## [1.4.2] - 2026-12-02 (Ruby)

TODO(release-notes) 물결 머리말 — 이 물결이 내보내는 언어 · 판과 그 근거를 쓴다.

### Security
- **(Ruby)** D 보안
'
printf '%s\n' "$R2_GOLD" > "$MS/r2.block"; splice "$CL" '## [물결] ' "$MS/r2.block" > "$MS/r2.gold"
_out="$(rel --date=2026-12-02 ruby=1.4.2)"
assert_contains "$_out" '__rc=0' "R2 rc 0"
assert_contains "$_out" 'ok   release 2026-12-02: 절 1개 · 항목 1개 · 조각 갱신 0 · 삭제 1' "R2 출력"
assert_eq 1 "$(grep -c -xF -- '- **(Ruby)** D 보안' "$CL" || true)" "R2 - **(Ruby)** D 보안 은 정확히 한 번"
assert_eq no "$([ -e "$TMP/changelog.d/2026-11-26-d.txt" ] && echo yes || echo no)" "R2 d 는 지워진다"
same_bytes "$MS/r2.gold" "$CL" "R2 루트 = R1 의 루트에서 [Unreleased] 블록 바로 뒤에 [1.4.2] 절을 끼운 것"

# R3(검토 초점 2) R1 직후 같은 물결을 다시 · 이미 나간 판(같은 날 go=1.2.6)으로 — 쓰기 전에 거부하고 원장 · 조각을 한 바이트도
# 바꾸지 않는다. 확인 5 는 물결의 (언어, 판)을 루트 · 보관본의 날짜 절 제목에서 찾고, 그 판이 있는 제목과 파일을 짚는다.
rfix; _out="$(r1)"; assert_contains "$_out" '__rc=0' "R3 첫 물결 rc 0"
_before="$(snap)"; _out="$(r1)"
assert_rejects "$_out" '이미 있는 판' "R3 같은 물결을 다시"
assert_contains "$_out" '「## [1.0.8] - 2026-12-01 (Python · .NET)」' "R3 같은 물결 — 그 판이 있는 제목을 짚는다"
assert_eq "$_before" "$(snap)" "R3 같은 물결 — 아무것도 안 쓴다"
_out="$(rel --date=2026-12-01 go=1.2.6)"
assert_rejects "$_out" '이미 있는 판 — Go 1.2.6: 「## [1.2.6] - 2026-12-01 (Go)」(CHANGELOG.md)' "R3 이미 나간 판"
assert_eq "$_before" "$(snap)" "R3 이미 나간 판 — 아무것도 안 쓴다"

# R3b 보관본의 제목도 본다 — 날짜 절이 없는 루트와 그 보관본 changelog/2026-10.md. 찾는 언어(PHP)는 괄호 안의 둘째 표시명이다
# (첫 표시명만 읽으면 놓친다). 물결의 날짜가 그 절과 달라도 거부한다 — (언어, 판)은 날짜를 보지 않는다.
fresh; printf '# Changelog\n\n## [Unreleased]\n\n' > "$CL"; mig > /dev/null
mkdir -p "$TMP/changelog"; printf '# Changelog — 2026-10\n\n보관본.\n\n## [1.0.0] - 2026-10-01 (Go · PHP)\n\n- x\n' > "$TMP/changelog/2026-10.md"
_before="$(snap)"; _out="$(rel --date=2026-12-01 php=1.0.0)"
assert_rejects "$_out" '이미 있는 판 — PHP 1.0.0: 「## [1.0.0] - 2026-10-01 (Go · PHP)」(changelog/2026-10.md)' "R3b 보관본 제목의 둘째 표시명"
assert_eq "$_before" "$(snap)" "R3b 아무것도 안 쓴다"

# R3c 이미 나간 판을 다른 날에 — 루트의 `## [1.0.7] - 2026-11-03 (Python)` 이 python=1.0.7 을 막는다(새 제목은 달라도).
rfix; _before="$(snap)"; _out="$(rel --date=2026-12-01 python=1.0.7)"
assert_rejects "$_out" '이미 있는 판 — Python 1.0.7: 「## [1.0.7] - 2026-11-03 (Python)」(CHANGELOG.md)' "R3c 다른 날의 이미 나간 판"
assert_eq "$_before" "$(snap)" "R3c 아무것도 안 쓴다"

# R3d 대조군 — 같은 번호의 다른 언어(node=1.0.7)는 받는다(§5.3 「같은 번호 경고」). 판만 보는 검사면 여기서 운다.
rfix; _out="$(rel --date=2026-12-01 node=1.0.7)"
assert_contains "$_out" '__rc=0' "R3d 다른 언어의 같은 번호는 받는다"
assert_eq 1 "$(grep -c -xF -- '## [1.0.7] - 2026-12-01 (Node)' "$CL" || true)" "R3d [1.0.7] (Node) 절이 생긴다"

# R4(검토 초점 3) 대기 노트가 없는 언어(의존성만 올린 판)는 실패가 아니다 — 제목과 손글 자리(판 하나짜리 물결이라 물결 머리말
# 자리)만 있는 절을 만들고, stdout 의 ok 줄 뒤에 알린다. 조각은 그대로다.
rfix; printf '## [1.5.3] - 2026-12-01 (PHP)\n\nTODO(release-notes) 물결 머리말 — 이 물결이 내보내는 언어 · 판과 그 근거를 쓴다.\n\n' > "$MS/r4.block"
splice "$CL" '## [1.0.7] ' "$MS/r4.block" > "$MS/r4.gold"; _fs="$(dsnap)"
to_file "$MS/r4.out" node "$CLI" release --root="$TMP" --date=2026-12-01 php=1.5.3
assert_eq 0 "$_rc" "R4 rc 0"
printf 'ok   release 2026-12-01: 절 1개 · 항목 0개 · 조각 갱신 0 · 삭제 0\n⚠️  php: 대기 노트가 없다 — 절에는 손글 자리만 있다\n' > "$MS/r4.stdout"
same_bytes "$MS/r4.stdout" "$MS/r4.out" "R4 stdout — ok 줄 뒤에 대기 노트가 없다 알림"
same_bytes "$MS/r4.gold" "$CL" "R4 루트 — [1.5.3] (PHP) 절에 손글 자리만"
assert_eq "$_fs" "$(dsnap)" "R4 조각은 그대로"

# R4b 노트가 있는 언어와 없는 언어가 섞인 물결 — 알림은 없는 언어마다 DEPLOY_LANGS 순서(java · php)로, 조각은 물결이 닿은 것만
# 남은 langs 로 다시 쓴다(b 는 물결 밖이다).
rfix; to_file "$MS/r4b.out" node "$CLI" release --root="$TMP" --date=2026-12-01 php=1.5.3 python=1.0.8 java=1.2.5
assert_eq 0 "$_rc" "R4b rc 0"
printf 'ok   release 2026-12-01: 절 4개 · 항목 3개 · 조각 갱신 3 · 삭제 0\n⚠️  java: 대기 노트가 없다 — 절에는 손글 자리만 있다\n⚠️  php: 대기 노트가 없다 — 절에는 손글 자리만 있다\n' > "$MS/r4b.stdout"
same_bytes "$MS/r4b.stdout" "$MS/r4b.out" "R4b stdout — 알림은 DEPLOY_LANGS 순서(java · php)"
assert_eq 'langs: go' "$(sed -n 1p "$TMP/changelog.d/2026-11-25-a.txt")" "R4b a 는 go 가 남는다"
assert_eq 'langs: dotnet' "$(sed -n 1p "$TMP/changelog.d/2026-11-26-c.txt")" "R4b c 는 dotnet 이 남는다"
assert_eq 'langs: ruby' "$(sed -n 1p "$TMP/changelog.d/2026-11-26-d.txt")" "R4b d 는 ruby 가 남는다"

# R5(검토 초점 5) 원장의 최신 날짜(2026-11-03)보다 이른 --date= 는 최신순을 깬다 — 거부 · 아무것도 안 쓴다. 같은 날은 받는다.
rfix; _before="$(snap)"; _out="$(rel --date=2026-11-01 python=1.0.8)"
assert_rejects "$_out" '최신 날짜(2026-11-03)보다 이르다' "R5 이른 날짜 2026-11-01"
assert_eq "$_before" "$(snap)" "R5 이른 날짜 — 아무것도 안 쓴다"
_out="$(rel --date=2026-11-03 python=1.0.8)"; assert_contains "$_out" '__rc=0' "R5 최신 날짜와 같은 날(2026-11-03)은 받는다"

# R6 옛 꼴 루트 — `[Unreleased]` 가 고정 문단이 아니면(항목이 있어도 · 비어 있어도) 먼저 migrate. 조각이 있어도 아무것도 안 쓴다.
fresh; printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n- **(Go)** 옛 항목\n\n## [1.0.7] - 2026-11-03 (Python)\n\n### Fixed\n- **(Python)** 옛 고침\n' > "$CL"; wfrags
_before="$(snap)"; _out="$(rel --date=2026-12-01 go=1.2.6)"
assert_rejects "$_out" '먼저 migrate' "R6 항목이 있는 옛 꼴 [Unreleased]"
assert_eq "$_before" "$(snap)" "R6 항목이 있는 옛 꼴 — 아무것도 안 쓴다"
fresh; rold; wfrags; _before="$(snap)"; _out="$(rel --date=2026-12-01 go=1.2.6)"
assert_rejects "$_out" '먼저 migrate' "R6 빈 옛 꼴 [Unreleased]"
assert_eq "$_before" "$(snap)" "R6 빈 옛 꼴 — 아무것도 안 쓴다"

# R7 문법이 깨진 조각이 있으면 거부(파일 이름 · 사유) · 아무것도 안 쓴다.
rfix; frag 2026-11-27-x.txt 'langs: go
section: Fix
---
x
'
_before="$(snap)"; _out="$(rel --date=2026-12-01 go=1.2.6)"
assert_rejects "$_out" 'changelog.d/2026-11-27-x.txt' "R7 깨진 조각"
assert_contains "$_out" '중 하나다 — Fix' "R7 깨진 조각 — 사유"
assert_eq "$_before" "$(snap)" "R7 아무것도 안 쓴다"

# R8 R1 의 결과에서 TODO(release-notes) 줄을 손글로 바꾸면 검사 8d 가 받는다. 대조군 — 같은 뿌리에 8d 결함(모르는 `## ` 제목)
# 하나를 심으면 `검사 8d` · rc 1 이다(8d 에 닿지 않아 빈 출력을 「받는다」로 읽지 않게).
DOCS="$DIR/../check-docs.mjs"
docs() { node "$DOCS" "$TMP" 2>&1 && echo '__rc=0' || echo "__rc=$?"; }
rfix; _out="$(r1)"; assert_contains "$_out" '__rc=0' "R8 물결 rc 0"
assert_eq 3 "$(grep -c '^TODO(release-notes) ' "$CL" || true)" "R8 손글 자리 셋(물결 머리말 · 언어 절 둘)"
awk 'index($0, "TODO(release-notes) ") == 1 { print "판 종류 patch — 공개 API 변경 0 · 같은 번호 경고 없음."; next } { print }' "$CL" > "$MS/r8.txt"
cp "$MS/r8.txt" "$CL"
assert_eq 0 "$(grep -c 'TODO(release-notes)' "$CL" || true)" "R8 손글로 다 바꿨다"
_out="$(docs)"
assert_not_contains "$_out" '검사 8d' "R8 손글로 바꾼 물결을 8d 가 받는다"
assert_contains "$_out" '__rc=0' "R8 check-docs rc 0"
printf '## 메모\n\n본문.\n' >> "$CL"; _out="$(docs)"
assert_rejects "$_out" '검사 8d' "R8 대조군 — 모르는 ## 제목 하나면 8d 가 운다"

# R9 판 꼴은 맞지만 긴 판 — 제목 줄이 1,024 B 를 넘는다(verifyWave 3) · 거부 · 아무것도 안 쓴다.
rfix; _before="$(snap)"; _out="$(rel --date=2026-12-01 "go=1.2.6-$(repeat 1100)")"
assert_rejects "$_out" '1024B' "R9 긴 판 문자열"
assert_contains "$_out" '물결 대조 3: ' "R9 verifyWave 3 이 잡는다"
assert_eq "$_before" "$(snap)" "R9 아무것도 안 쓴다"

# R10 사용법 — rc 2 와 그 사유 · 아무것도 안 쓴다(위치 인자 · `<lang>=<판>` 꼴 · 판 꼴 · 겹침 · 모르는 언어 · 날짜 · 인자).
rfix; _before="$(snap)"
w5 "R10 위치 인자 없음" 'release 의 위치 인자는 1개 이상이다' release --date=2026-12-01 --root="$TMP"
w5 "R10 = 이 없다" '`<lang>=<판>` 꼴이 아니다 — python' release python --root="$TMP"
w5 "R10 언어가 비었다" '`<lang>=<판>` 꼴이 아니다 — =1.0.8' release =1.0.8 --root="$TMP"
w5 "R10 판이 비었다" '`<lang>=<판>` 꼴이 아니다 — python=' release python= --root="$TMP"
w5 "R10 판 꼴 1.0" '판 꼴이 아니다 — python=1.0' release python=1.0 --root="$TMP"
w5 "R10 판 꼴 v1.0.8" '판 꼴이 아니다 — python=v1.0.8' release python=v1.0.8 --root="$TMP"
w5 "R10 판 꼴 1.0.8-" '판 꼴이 아니다 — python=1.0.8-' release python=1.0.8- --root="$TMP"
w5 "R10 판 꼴 물결" '판 꼴이 아니다 — python=물결' release python=물결 --root="$TMP"
w5 "R10 겹친 언어" '언어가 겹친다 — python' release python=1.0.8 python=1.0.9 --root="$TMP"
w5 "R10 모르는 언어" '모르는 언어 — swift' release swift=1.0.0 --root="$TMP"
w5 "R10 없는 날짜" '있는 날짜의 YYYY-MM-DD 다 — 2026-02-30' release --date=2026-02-30 python=1.0.8 --root="$TMP"
w5 "R10 모르는 인자" '모르는 인자 — --dat=2026-12-01' release --dat=2026-12-01 python=1.0.8 --root="$TMP"
assert_eq "$_before" "$(snap)" "R10 사용법 오류는 아무것도 쓰지 않는다"

# R11 루트에 모르는 `## ` 제목 — 새 루트를 다시 읽어 거부한다 · 아무것도 안 쓴다.
rfix; printf '## 메모\n\n본문.\n' >> "$CL"; _before="$(snap)"; _out="$(rel --date=2026-12-01 go=1.2.6)"
assert_rejects "$_out" '「## 메모」' "R11 모르는 ## 제목"
assert_eq "$_before" "$(snap)" "R11 아무것도 안 쓴다"

# R12 뿌리 — CHANGELOG.md 가 없거나 deploy-facts.sh 가 없으면 거부(rc 1) · 조각이 있어도 아무것도 안 쓴다.
rfix; rm -f "$CL"; _before="$(snap)"; _out="$(rel --date=2026-12-01 go=1.2.6)"
assert_rejects "$_out" 'CHANGELOG.md 가 없다' "R12 CHANGELOG.md 없음"
assert_eq "$_before" "$(snap)" "R12 CHANGELOG.md 없음 — 아무것도 안 쓴다"
rfix; rm -f "$TMP/scripts/lib/deploy-facts.sh"; _before="$(snap)"; _out="$(rel --date=2026-12-01 go=1.2.6)"
assert_rejects "$_out" 'deploy-facts.sh' "R12 deploy-facts.sh 없음"
assert_eq "$_before" "$(snap)" "R12 deploy-facts.sh 없음 — 아무것도 안 쓴다"

# R13 CRLF 뿌리 — 읽을 때 LF 로 맞추고 쓰는 것은 LF 다: 결과가 R1(LF 뿌리)의 결과와 바이트까지 같다.
rfix; awk '{ printf "%s\r\n", $0 }' "$CL" > "$MS/crlf"; cp "$MS/crlf" "$CL"
assert_eq "$(( $(wc -c < "$MS/r1.pre") + $(wc -l < "$MS/r1.pre") ))" "$(wc -c < "$CL" | tr -d ' ')" "R13 픽스처 — 줄마다 CR 이 붙었다"
_out="$(r1)"; assert_contains "$_out" '__rc=0' "R13 CRLF 뿌리 rc 0"
same_bytes "$MS/r1.out" "$CL" "R13 CRLF 입력의 결과는 LF 입력(R1)의 결과와 바이트까지 같다"

# R14 날짜 기본은 오늘(이 기계의 지역 날짜) — 실행이 자정을 넘어도 거짓 빨강이 나지 않게 앞뒤 날짜 중 하나면 된다.
rfix; _d1="$(date +%Y-%m-%d)"; _out="$(rel go=1.2.6)"; _d2="$(date +%Y-%m-%d)"
assert_contains "$_out" '__rc=0' "R14 --date= 없이 rc 0"
_cl="$(cat "$CL")"
case "$_cl" in *"## [1.2.6] - $_d1 (Go)"*|*"## [1.2.6] - $_d2 (Go)"*) _today=ok ;; *) _today="$_cl" ;; esac
assert_eq ok "$_today" "R14 날짜 기본은 오늘"

# ---- K. check 시험 컴파일 · 75 % 경고 · preview --stats ----
# 상한은 lib/doc-tripwire.mjs 의 상수 하나다 — 여기서 다시 적지 않고 그 파일의 정의 줄에서 읽는다(check-docs 8c 와 같은 수).
_T="$(( $(sed -n 's/^export const DOC_TRIPWIRE_BYTES = //p' "$DIR/../lib/doc-tripwire.mjs" | tr -d '\r') ))"
WARN='대기 노트를 아홉 언어 물결로 내면'
kfix() { fresh; mkdir -p "$W"; rold; mig > /dev/null; } # 포인터 꼴 뿌리 — 조각 없음(many 가 채운다)
many() { # <개수> <langs> — 본문 1,000 B 의 조각 <개수> 개(이름은 n001…)
  _body="$(repeat 1000)"; _i=1
  while [ "$_i" -le "$1" ]; do
    frag "2026-11-25-n$(printf '%03d' "$_i").txt" "langs: $2
section: Fixed
---
$_body
"
    _i=$((_i + 1))
  done
}

# K1 세 절(Fixed · Added · Security)에 걸친 조각 넷 + 포인터 꼴 루트 → rc 0 · 조각 수 · 경고 없음 · 아무것도 안 쓴다.
rfix; _before="$(snap)"; _out="$(chk)"
assert_contains "$_out" 'ok   changelog.d/ 4개 조각' "K1 조각 넷"
assert_contains "$_out" '__rc=0' "K1 rc 0"
assert_not_contains "$_out" '⚠️' "K1 작은 트리에는 경고가 없다"
assert_eq "$_before" "$(snap)" "K1 check 는 아무것도 쓰지 않는다"
# K1b 루트가 없어도 check 는 거부하지 않는다(루트가 있을 때만 포인터를 본다) · CRLF 루트는 LF 로 맞춰 읽는다.
rfix; rm -f "$CL"; _out="$(chk)"; assert_contains "$_out" '__rc=0' "K1b CHANGELOG.md 없음 — rc 0"
rfix; awk '{ printf "%s\r\n", $0 }' "$CL" > "$MS/k1.crlf"; cp "$MS/k1.crlf" "$CL"; _out="$(chk)"
assert_contains "$_out" '__rc=0' "K1b CRLF 루트의 포인터를 받는다"

# K2 langs: go · 본문 1,000 B 조각 210 개 → rc 0 + 경고(≈82 %) · 같은 꼴 100 개(≈40 %)는 경고 없음(대조군).
kfix; many 210 go; _before="$(snap)"; _out="$(chk)"
assert_contains "$_out" '__rc=0' "K2 경고는 실패가 아니다 — rc 0"
assert_contains "$_out" 'ok   changelog.d/ 210개 조각' "K2 ok 줄이 먼저 나온다"
assert_contains "$_out" "⚠️  $WARN 루트가 " "K2 경고 — 접두 · 바늘"
assert_contains "$_out" "B — 전역 상한 ${_T}B 의 " "K2 경고 — 전역 상한은 doc-tripwire 의 수"
_N="$(printf '%s\n' "$_out" | sed -n 's/.*루트가 \([0-9][0-9]*\)B .*/\1/p')"
assert_contains "$_out" "의 $(( _N * 100 / _T ))%" "K2 경고 — P 는 N 에서 내림한 정수"
case "$(( _N * 100 / _T ))" in 8[0-4]) _p=ok ;; *) _p="$_N B" ;; esac
assert_eq ok "$_p" "K2 210 개는 약 82 % 다(80–84)"
assert_eq "$_before" "$(snap)" "K2 경고 — 아무것도 쓰지 않는다"
kfix; many 100 go; _out="$(chk)"
assert_contains "$_out" 'ok   changelog.d/ 100개 조각' "K2 대조군 — 100 개 ok"
assert_contains "$_out" '__rc=0' "K2 대조군 — rc 0"
assert_not_contains "$_out" "$WARN" "K2 대조군(≈40 %) — 경고가 없다"

# K3 preview --stats — 통계 줄만(미리보기 글 없음) · 언어마다 `<lang> 대기 <n>개 · <b>B` · 끝에 아홉 언어 물결 예상.
rfix; _out="$(run preview --stats --root="$TMP")"
assert_contains "$_out" '__rc=0' "K3 rc 0"
assert_contains "$_out" '아홉 언어 물결 예상' "K3 아홉 언어 물결 예상"
assert_contains "$_out" "B / 8c 상한 ${_T}B (" "K3 8c 상한은 doc-tripwire 의 수"
assert_not_contains "$_out" '### ' "K3 미리보기 글은 찍지 않는다"
assert_contains "$_out" 'python 대기 3개 · ' "K3 python — 조각 a · c · d"
assert_contains "$_out" 'ruby 대기 1개 · ' "K3 ruby — 조각 d"
assert_contains "$_out" 'php 대기 0개 · ' "K3 대기가 없는 언어도 한 줄"
# b = 그 언어 한 언어 물결의 바이트 — `preview python --date=…`(판 자리 `?`)의 글 크기 + 판 `0.0.1` 과 `?` 의 4 B.
to_file "$MS/k3.py" node "$CLI" preview python --date=2000-01-01 --root="$TMP"
_b="$(( $(wc -c < "$MS/k3.py") + 4 ))"
assert_contains "$_out" "python 대기 3개 · ${_b}B" "K3 python 의 B = 한 언어 물결 글의 바이트"

# K3b --stats 의 인자 규칙 — 불리언 플래그(정확히 `--stats`, 한 번) · <lang> · --date= 와 같이 못 쓴다 · 다른 하위명령은 모른다. 모두 rc 2 · 아무것도 안 쓴다.
rfix; _before="$(snap)"
w5 "K3b --stats 와 <lang>" '--stats 는 <lang> · --date= 와 함께 쓰지 않는다' preview --stats go --root="$TMP"
w5 "K3b --stats 와 --date=" '--stats 는 <lang> · --date= 와 함께 쓰지 않는다' preview --stats --date=2026-12-01 --root="$TMP"
w5 "K3b --stats 두 번" '--stats 는 한 번만 준다' preview --stats --stats --root="$TMP"
w5 "K3b --stats=x" '모르는 인자 — --stats=x' preview --stats=x --root="$TMP"
w5 "K3b 모르는 플래그" '모르는 인자 — --stat' preview --stat --root="$TMP"
w5 "K3b check 는 --stats 를 모른다" '모르는 인자 — --stats' check --stats --root="$TMP"
w5 "K3b release 는 --stats 를 모른다" '모르는 인자 — --stats' release --stats go=1.2.6 --root="$TMP"
assert_eq "$_before" "$(snap)" "K3b 사용법 오류는 아무것도 쓰지 않는다"

# K3c changelog.d/ 가 없다 — (i) deploy-facts.sh 가 있으면 --stats 는 언어마다 0 · 0B 와 아홉 언어 0B, rc 0.
# (ii) 라이브러리는 deploy-facts.sh 도 없는 뿌리(CHANGELOG.md 만)에서 던지지 않고 빈 결과를 낸다 — DEPLOY_LANGS 를 읽기 전에 디렉터리부터 본다.
rfix; rm -rf "${TMP:?}/changelog.d"; _out="$(run preview --stats --root="$TMP")"
assert_contains "$_out" '__rc=0' "K3c(i) changelog.d/ 없음 — rc 0"
for _l in python dotnet ruby node rust java kotlin go php; do assert_contains "$_out" "$_l 대기 0개 · 0B" "K3c(i) $_l 대기 0개 · 0B"; done
assert_contains "$_out" '아홉 언어 물결 예상 0B / 8c 상한' "K3c(i) 아홉 언어 물결 0B"
rfix; rm -rf "${TMP:?}/changelog.d"; rm -f "$TMP/scripts/lib/deploy-facts.sh"; _before="$(snap)"
to_file "$MS/k3c.out" node "$PROBE" --tree "$TMP"
assert_eq 0 "$_rc" "K3c(ii) CHANGELOG.md 만 있는 뿌리 — 던지지 않는다(rc 0)"
assert_eq '{"errors":[],"warnings":[],"stats":{"perLang":{},"projected":0,"tripwire":'"${_T}"'}}' "$(cat "$MS/k3c.out")" "K3c(ii) 빈 결과 — errors · warnings 비고 언어 없음"
assert_eq "$_before" "$(snap)" "K3c(ii) 아무것도 안 쓴다"

# K4 [Unreleased] 에 항목이 있는 옛 꼴 루트 → rc 1 · 고정 문단 · 아무것도 안 쓴다. 대조군은 K1(포인터 꼴 → rc 0).
mroot "$M_OLD"; _before="$(snap)"; _out="$(chk)"
assert_rejects "$_out" '고정 문단' "K4 옛 꼴 루트"
assert_contains "$_out" 'CHANGELOG.md' "K4 — 파일 이름"
assert_eq "$_before" "$(snap)" "K4 아무것도 안 쓴다"
# K4b 같은 거부 — 조각이 있어도 · 루트에 `[Unreleased]` 가 없어도(둘 다 고정 문단이 아니다).
rfix; printf '# Changelog\n\n## [1.0.7] - 2026-11-03 (Python)\n\n### Fixed\n- **(Python)** 옛 고침\n' > "$CL"; _before="$(snap)"; _out="$(chk)"
assert_rejects "$_out" '고정 문단' "K4b [Unreleased] 가 없는 루트"
assert_eq "$_before" "$(snap)" "K4b 아무것도 안 쓴다"
# K4c 포인터 뒤에 손으로 한 줄을 더하면(고정 문단이 아니다) 거부한다.
rfix; awk 'index($0, "## [1.0.7] ") == 1 { print "- **(Go)** 손으로 쓴 항목\n" } { print }' "$CL" > "$MS/k4c"; cp "$MS/k4c" "$CL"
assert_contains "$(cat "$CL")" '- **(Go)** 손으로 쓴 항목' "K4c 픽스처 — 포인터 뒤에 항목이 붙었다"
_before="$(snap)"; _out="$(chk)"
assert_rejects "$_out" '고정 문단' "K4c 포인터 뒤의 손글 항목"
assert_eq "$_before" "$(snap)" "K4c 아무것도 안 쓴다"

# ---- V. covered — 범위가 조각으로 얻은 언어 ----
# 픽스처는 git 저장소다(커밋자는 가짜 · autocrlf 는 끈다). 기준은 브랜치 이름이 아니라 sha 로 부른다.
VGIT() { git -C "$TMP" -c user.email=t@example.invalid -c user.name=t "$@" >/dev/null 2>&1; }
vfix() { fresh; git init -q -b main "$TMP" >/dev/null 2>&1; VGIT config core.autocrlf false; }
vbase() { VGIT add -A; VGIT commit -qm base; VBASE="$(git -C "$TMP" rev-parse HEAD)"; }
vf() { # <이름> <langs> <본문> — 조각 하나
  frag "$1" "langs: $2
section: Fixed
---
$3
"
}
cov() { run covered --root="$TMP" --base="$VBASE" "$@"; }
LF='
'

# V1 기준 = a(python) · b(go), 작업 = c(ruby) 추가 · a 를 `python node` 로 · b 를 같은 내용으로 이름만 바꿈 → `ruby node`.
# 이름순으로는 a(node) 가 c(ruby) 보다 앞이라, 출력 순서가 DEPLOY_LANGS 가 아니면 `node ruby` 가 된다.
vfix; vf 2026-11-20-a.txt python 'A 본문'; vf 2026-11-20-b.txt go 'B 본문'; vbase
vf 2026-11-20-a.txt 'python node' 'A 본문'; rm "$TMP/changelog.d/2026-11-20-b.txt"; vf 2026-11-26-b-renamed.txt go 'B 본문'; vf 2026-11-26-c.txt ruby 'C 본문'
_before="$(snap)"; _out="$(cov)"
assert_eq "$_out" "ruby node${LF}__rc=0" "V1 얻은 언어 = ruby node (DEPLOY_LANGS 순 · 이름만 바꾼 조각은 새 노트가 아니다)"
assert_eq "$_before" "$(snap)" "V1 아무것도 안 쓴다"

# V1b 이름만 바꾸고 언어를 더하면 더한 언어만 얻는다 — 같은 본문의 기준 조각(둘 이상이면 합집합)이 기준 langs 다.
vfix; vf 2026-11-20-x.txt python 'X 본문'; vf 2026-11-20-y.txt go 'X 본문'; vbase
rm "$TMP/changelog.d/2026-11-20-x.txt" "$TMP/changelog.d/2026-11-20-y.txt"; vf 2026-11-26-z.txt 'python go php' 'X 본문'
assert_eq "$(cov)" "php${LF}__rc=0" "V1b 같은 본문의 기준 조각들의 합집합을 뺀다"
# V1c 같은 경로가 있으면 본문이 바뀌어도 그 경로의 기준 langs 를 쓴다(같은 본문의 다른 조각은 보지 않는다).
vfix; vf 2026-11-20-a.txt python 'A 본문'; vf 2026-11-20-b.txt go 'B 본문'; vbase
vf 2026-11-20-a.txt 'python go' 'B 본문'
assert_eq "$(cov)" "go${LF}__rc=0" "V1c 같은 경로 우선 — 본문이 같은 b 의 go 가 아니라 a 의 python 을 뺀다"
# V1e 이름을 바꾸고 본문도 바꾸면 같은 경로도 같은 본문도 없다 — 기준 langs 는 ∅ 라 langs 전부가 얻은 것이다(다른 기준 조각을 물려받지 않는다).
vfix; vf 2026-11-20-a.txt go 'G'; vbase
rm "$TMP/changelog.d/2026-11-20-a.txt"; vf 2026-11-26-a2.txt go 'G changed'
assert_eq "$(cov)" "go${LF}__rc=0" "V1e 이름 바꿈 + 본문 바뀜 — go"
# V1f 이미 노트가 있는 언어의 새 노트 — 기준의 다른 조각(python)을 물려받지 않아 python 을 얻는다.
vfix; vf 2026-11-20-a.txt python 'A'; vbase
vf 2026-11-26-n.txt python 'N'
assert_eq "$(cov)" "python${LF}__rc=0" "V1f 이미 노트가 있는 언어의 새 노트 — python"
# V1d 기준에 조각 디렉터리가 없으면 작업 트리의 langs 전부가 얻은 것이다.
vfix; printf 'x\n' > "$TMP/f"; vbase; vf 2026-11-26-a.txt 'go ruby' 'A 본문'
assert_eq "$(cov)" "ruby go${LF}__rc=0" "V1d 기준에 changelog.d/ 가 없다 — langs 전부"

# V2 변화 없음 → 빈 줄 · rc 0. 조각이 줄어도(지워져도) 얻은 것은 없다.
vfix; vf 2026-11-20-a.txt python 'A 본문'; vf 2026-11-20-b.txt go 'B 본문'; vbase
assert_eq "$(cov)" "${LF}__rc=0" "V2 변화 없음 — 빈 줄"
rm "$TMP/changelog.d/2026-11-20-b.txt"
assert_eq "$(cov)" "${LF}__rc=0" "V2 조각을 지워도 얻은 것은 없다 — 빈 줄"
vf 2026-11-20-a.txt go 'A 본문'
assert_eq "$(cov)" "go${LF}__rc=0" "V2 langs 를 바꾸면 새 토큰만 얻는다(python 은 기준에 있었다)"

# V3 기준을 못 읽는다 — 이름 없는 · 옵션처럼 생긴 · git 저장소가 아닌 뿌리 · rc 1 · 기준 이름이 바늘이다.
vfix; vf 2026-11-20-a.txt python 'A 본문'; vbase; _before="$(snap)"
_out="$(run covered --root="$TMP" --base=nope)"
assert_rejects "$_out" '기준 리비전을 읽지 못했다 — nope' "V3 없는 리비전"
_out="$(run covered --root="$TMP" --base=--all)"
assert_rejects "$_out" '기준 리비전을 읽지 못했다 — --all' "V3 옵션처럼 생긴 값은 리비전으로만 읽힌다"
fresh; vf 2026-11-20-a.txt python 'A 본문'
_out="$(run covered --root="$TMP" --base=HEAD)"
assert_rejects "$_out" '기준 리비전을 읽지 못했다 — HEAD' "V3 git 저장소가 아닌 뿌리"
vfix; vf 2026-11-20-a.txt python 'A 본문'; vbase; _before="$(snap)"
# V3b 사용법 — --base= 가 없거나 비었거나 겹치면 rc 2.
_out="$(run covered --root="$TMP")"
assert_contains "$_out" '__rc=2' "V3b --base= 없음 — rc 2"
assert_contains "$_out" '--base=' "V3b --base= 없음 — 사용법에 --base= 가 있다"
_out="$(run covered --root="$TMP" --base=)"
assert_contains "$_out" '__rc=2' "V3b 빈 --base= — rc 2"
_out="$(run covered --root="$TMP" --base="$VBASE" --base="$VBASE")"
assert_contains "$_out" '__rc=2' "V3b 겹친 --base= — rc 2"
_out="$(run covered --root="$TMP" --base="$VBASE" extra)"
assert_contains "$_out" '__rc=2' "V3b 위치 인자 — rc 2"
assert_eq "$_before" "$(snap)" "V3 · V3b 아무것도 안 쓴다"

# V4 작업 트리에 문법이 깨진 조각 → rc 1 · 파일 이름.
vfix; vf 2026-11-20-a.txt python 'A 본문'; vbase
frag 2026-11-26-bad.txt 'langs: go
section: Fixed
kind: x
---
본문
'
_before="$(snap)"; _out="$(cov)"
assert_rejects "$_out" 'changelog.d/2026-11-26-bad.txt' "V4 작업 트리의 문법 오류"
assert_contains "$_out" '모르는 키' "V4 — 사유"
assert_eq "$_before" "$(snap)" "V4 아무것도 안 쓴다"

# V5 기준의 조각이 깨졌다 · 기준에 하위 경로가 있다 → rc 1 · 기준 sha 와 조각 이름. 작업 트리는 멀쩡하다(고쳐 둔 경우를 닫는다).
vfix; vf 2026-11-20-a.txt python 'A 본문'
frag 2026-11-20-old.txt 'langs: nope
section: Fixed
---
본문
'; vbase
rm "$TMP/changelog.d/2026-11-20-old.txt"; _before="$(snap)"; _out="$(cov)"
assert_rejects "$_out" 'changelog.d/2026-11-20-old.txt' "V5 기준 조각의 문법 오류 — 조각 이름"
assert_contains "$_out" "$(printf '%s' "$VBASE" | cut -c1-12)" "V5 — 기준 sha"
assert_contains "$_out" 'DEPLOY_LANGS 밖의 토큰' "V5 — 사유"
assert_eq "$_before" "$(snap)" "V5 아무것도 안 쓴다"
vfix; vf 2026-11-20-a.txt python 'A 본문'; mkdir -p "$TMP/changelog.d/sub"; vf sub/2026-11-20-n.txt go 'N 본문'; vbase
rm -rf "${TMP:?}/changelog.d/sub"
_out="$(cov)"
assert_rejects "$_out" 'changelog.d/sub/2026-11-20-n.txt' "V5 기준의 하위 경로(이름 꼴이 거부한다)"
assert_contains "$_out" "$(printf '%s' "$VBASE" | cut -c1-12)" "V5 하위 경로 — 기준 sha"

assert_report
