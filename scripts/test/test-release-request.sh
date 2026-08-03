#!/usr/bin/env sh
# 릴리스 요청 검증 자가테스트.
#
# 이 스크립트가 잘못 통과하면 승인되지 않은 태그가 밀린다 — 그래서 "거부해야 하는 것"을
# 통과 케이스보다 많이 고정한다. 특히 go 거부와 태그 파생은 회귀하면 조용히 위험해진다.
#
# ⚠️ 환경 의존 어서션을 쓰지 않는다. 이 저장소는 test-deploy-md.sh·test-release-readiness.sh가
# 각각 실제 태그·게시 상태에 기대다가 사실이 바뀌자 뒤집힌 이력이 있다. 여기서는 임시 파일만 쓴다.
#
# ⚠️ **이 파일의 일부 케이스는 bash에서 재현되지 않는다 — dash 전용이다.** 아래 "리터럴 백슬래시"
# 절이 그것이다. POSIX 셸의 `echo`는 백슬래시 이스케이프를 확장해도 되고(dash는 `-e` 없이도
# 확장한다) 안 해도 된다(bash·busybox ash는 확장하지 않는다). 우분투 러너의 `/bin/sh`가 dash라
# **로컬 Git Bash 전건 통과가 CI 통과를 보증하지 않는다.** 이 파일을 고칠 때는 반드시 실제 dash로
# 한 번 돌릴 것:
#   docker run --rm -v "$PWD:/repo:ro" -w /repo alpine:3 \
#     sh -c 'apk add --no-cache dash nodejs >/dev/null; dash scripts/test/test-release-request.sh'
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
SH="$DIR/../release-request.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ⚠️ 소싱 전에 위치인자를 설정한다 — `. "$SH" --lib`로 쓰면 안 된다. POSIX의 `.`(dot)은 파일명 외의
# 인자를 정의하지 않아 dash(우분투 러너의 /bin/sh)가 그것을 무시하고, 그러면 스크립트의 `--lib`
# 가드가 거짓이 되어 rq_main이 실행된다(요청 파일 부재 → return 3 → `set -e`가 이 테스트를 죽인다).
# 로컬 Git Bash는 위치인자를 설정하므로 통과한다 — 이 결함은 CI에서만 보였다.
set -- --lib
. "$SH"

# ── 태그 파생: 요청이 태그를 말하지 않고 lang+version에서 나온다 ──────────────
# 태그를 데이터로 받으면 "싼 언어를 선언하고 비싼 태그를 민다"가 성립한다.
assert_eq "py-v0.1.0rc2"   "$(rq_derive_tag python 0.1.0rc2)"   "python 태그 파생"
assert_eq "dotnet-v0.1.0"  "$(rq_derive_tag dotnet 0.1.0)"      "dotnet 태그 파생"
assert_eq "v0.1.0"         "$(rq_derive_tag java 0.1.0)"        "java 태그 파생(접두 없음)"
assert_eq "ruby-v0.1.0.rc1" "$(rq_derive_tag ruby 0.1.0.rc1)"   "ruby 태그 파생(RubyGems 표기)"

# ── 정상 요청 ────────────────────────────────────────────────────────────────
printf '{"lang":"python","version":"0.1.0rc2"}\n' > "$TMP/ok.json"
assert_eq "python 0.1.0rc2 py-v0.1.0rc2" "$(rq_validate_file "$TMP/ok.json")" "정상 요청은 lang/version/tag를 낸다"
assert_ok rq_validate_file "$TMP/ok.json"
# 다운스트림은 이 출력을 위치 인자로 파싱한다(`set -- $(rq_validate_file "$f"); tag=$3`) —
# 그러니 출력이 한 줄이라는 계약 자체를 고정한다(아래 개행주입 케이스가 이걸 깨려 한다).
assert_eq "1" "$(rq_validate_file "$TMP/ok.json" | wc -l | tr -d ' ')" "정상 출력은 한 줄이다(다운스트림이 위치 인자로 파싱한다)"

# ── go 거부 ──────────────────────────────────────────────────────────────────
# 태그가 곧 게시라 머지 이후 게이트가 불가능하다. 거부는 조용하면 안 된다 — 왜인지 말해야 한다.
printf '{"lang":"go","version":"0.1.0"}\n' > "$TMP/go.json"
assert_fails rq_validate_file "$TMP/go.json"
go_err="$(rq_validate_file "$TMP/go.json" 2>&1 || true)"
assert_contains "$go_err" "go" "go 거부 메시지에 언어가 있다"
assert_contains "$go_err" "git tag go/v0.1.0" "go 거부 시 사람이 실행할 명령을 안내한다"

# ── 요청 없음 = 깨끗한 no-op (리버트로 파일이 사라진 경우) ─────────────────────
rq_validate_file "$TMP/absent.json" >/dev/null 2>&1 || rc=$?
assert_eq "3" "${rc:-0}" "요청 파일 부재는 거부(1)가 아니라 no-op(3)이다"

# ── 거부해야 하는 것들 ───────────────────────────────────────────────────────
printf '{"lang":"klingon","version":"0.1.0"}\n' > "$TMP/unknown.json"
assert_fails rq_validate_file "$TMP/unknown.json"

printf '{"lang":"python","version":"0.1.0-rc.1"}\n' > "$TMP/badver.json"
assert_fails rq_validate_file "$TMP/badver.json"   # python은 PEP 440(0.1.0rc1)이라 SemVer 표기를 거부

printf '{"lang":"python"}\n' > "$TMP/noversion.json"
assert_fails rq_validate_file "$TMP/noversion.json"

printf 'not json at all\n' > "$TMP/broken.json"
assert_fails rq_validate_file "$TMP/broken.json"

# 태그를 데이터로 넣으려는 시도 — 무시되어야 한다(파생값이 이긴다).
printf '{"lang":"python","version":"0.1.0rc2","tag":"node-v9.9.9"}\n' > "$TMP/inject.json"
inject_out="$(rq_validate_file "$TMP/inject.json" 2>/dev/null || true)"
assert_contains "$inject_out" "py-v0.1.0rc2" "요청의 tag 필드가 파생을 덮어쓰지 못한다"
assert_not_contains "$inject_out" "node-v9.9.9" "요청의 tag 필드가 무시된다"

# 셸 주입 시도 — 버전 정규식이 막아야 한다.
printf '{"lang":"python","version":"0.1.0rc2; touch /tmp/pwned"}\n' > "$TMP/shell.json"
assert_fails rq_validate_file "$TMP/shell.json"

# 개행 주입 시도 — `grep -qE "^...$"`는 문자열 전체가 아니라 줄 단위라, version에 실제
# 개행이 섞이면 "한 줄은 유효한 버전 + 다른 줄은 임의 문자열"로 정규식 검사를 우회하고
# 그 임의 문자열이 stdout의 두 번째 줄로 새어나갈 수 있었다(코드리뷰 발견 — tag 필드가
# 아니라 version을 통한 같은 권한상승). node로 실제 개행을 담은 JSON을 생성해 고정한다.
node -e 'process.stdout.write(JSON.stringify({lang:"python",version:"0.1.0\nnode-v9.9.9"}))' > "$TMP/newline.json"
assert_fails rq_validate_file "$TMP/newline.json"

# ── 리터럴 백슬래시 주입 (⚠️ dash 전용 — bash에서는 재현되지 않는다) ──────────
# 개행 주입을 닫은 제어문자 필터(`[\x00-\x1f\x7f]`)는 **리터럴 백슬래시(0x5C)를 통과시킨다** —
# 백슬래시는 제어문자가 아니기 때문이다. 그리고 dash의 `echo`는 `-e` 없이도 이스케이프를
# 확장하므로 `echo "$ver" | grep -qE '^…$'` 형태의 검사에서
#   ver='0.1.0\c go/v9.9.9'  →  echo 출력 '0.1.0'  →  정규식 통과(우회 성립)
# 가 된다. `$ver` 자체에는 전체 문자열이 남으므로 stdout의 "<lang> <version> <tag>" 3필드
# 계약이 깨지고, 워크플로의 `cut -d' ' -f3`가 **공격자가 고른 문자열을 태그로** 집는다.
# 방어는 둘 다 필요하다: (1) 검사 파이프를 `printf '%s\n'`으로 바꿔 확장 자체를 없애고,
# (2) 값이 통과하는 유일한 관문(rq_field)에서 백슬래시를 거부한다 — 아홉 레지스트리의 어떤
# 버전 표기에도 백슬래시는 없다.
# ⚠️ JSON 안의 리터럴 백슬래시는 `\\`로 적어야 하는데 printf/heredoc을 거치면 접히거나
# 유효하지 않은 JSON 이스케이프가 되어 **거짓 음성**이 난다 — node로 생성한다.
node -e 'process.stdout.write(JSON.stringify({lang:"python",version:"0.1.0"+String.fromCharCode(92)+"c go/v9.9.9"}))' > "$TMP/backslash.json"
assert_fails rq_validate_file "$TMP/backslash.json"
bs_out="$(rq_validate_file "$TMP/backslash.json" 2>/dev/null || true)"
assert_not_contains "$bs_out" "go/v9.9.9" "백슬래시 우회로 go 태그가 stdout에 새지 않는다"

# `\n`(백슬래시+n)도 같은 부류다 — dash의 echo가 실제 개행으로 확장하면 grep의 줄 단위
# `^…$`가 다시 우회된다(제어문자 필터는 이 시점에 이미 지나갔다).
node -e 'process.stdout.write(JSON.stringify({lang:"python",version:"0.1.0"+String.fromCharCode(92)+"nnode-v9.9.9"}))' > "$TMP/backslash-n.json"
assert_fails rq_validate_file "$TMP/backslash-n.json"

# 정상 출력의 필드 수 계약(다운스트림이 위치 인자/`cut -d' '`로 파싱한다) — 위 케이스들이
# 깨뜨리려는 것이 바로 이 계약이므로 계약 자체도 못박는다.
assert_eq "3" "$(rq_validate_file "$TMP/ok.json" | wc -w | tr -d ' ')" "정상 출력은 공백 3필드다"

# ── 상태 불변식: 이 스크립트는 아무것도 바꾸지 않는다 ─────────────────────────
assert_eq "0" "$(grep -cE '^[[:space:]]*(git[[:space:]]+(tag|push|commit)|rm[[:space:]]|mv[[:space:]])' "$SH" || true)" "요청 검증은 상태를 변경하지 않는다"

# ── 소싱 방식 드리프트 가드 ───────────────────────────────────────────────────
# POSIX의 `.`(dot)은 파일명 외의 인자를 정의하지 않는다 — bash는 위치인자를 설정하지만 dash는
# 무시한다. 그래서 `. "$SH" --lib`는 **로컬 bash에서만** 라이브러리 모드가 되고 CI(dash)에서는
# main이 실행된다. request 쪽은 exit 3으로 즉사했고, readiness 쪽은 조용히 라이브 레지스트리를
# 조회해 왔다. 어느 쪽이든 로컬 통과가 CI를 보증하지 못했다 — 그러니 idiom 자체를 고정한다.
# (이 테스트 자체가 dash에서 돌아야 의미가 있으므로 CI가 곧 실행 증거다.)
for t in test-release-request.sh test-release-readiness.sh; do
  assert_eq "0" "$(grep -cE '^\.[[:space:]].*--lib' "$DIR/$t" || true)" "$t: dot에 인자를 직접 넘기지 않는다(dash가 무시한다)"
  assert_eq "1" "$(grep -cE '^set -- --lib$' "$DIR/$t" || true)" "$t: 소싱 전에 위치인자를 설정한다"
done

assert_report
