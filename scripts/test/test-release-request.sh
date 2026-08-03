#!/usr/bin/env sh
# 릴리스 요청 검증 자가테스트.
#
# 이 스크립트가 잘못 통과하면 승인되지 않은 태그가 밀린다 — 그래서 "거부해야 하는 것"을
# 통과 케이스보다 많이 고정한다. 특히 go 거부와 태그 파생은 회귀하면 조용히 위험해진다.
#
# ⚠️ 환경 의존 어서션을 쓰지 않는다. 이 저장소는 test-deploy-md.sh·test-release-readiness.sh가
# 각각 실제 태그·게시 상태에 기대다가 사실이 바뀌자 뒤집힌 이력이 있다. 여기서는 임시 파일만 쓴다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
SH="$DIR/../release-request.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

. "$SH" --lib

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

# ── 상태 불변식: 이 스크립트는 아무것도 바꾸지 않는다 ─────────────────────────
assert_eq "0" "$(grep -cE '^[[:space:]]*(git[[:space:]]+(tag|push|commit)|rm[[:space:]]|mv[[:space:]])' "$SH" || true)" "요청 검증은 상태를 변경하지 않는다"

assert_report
