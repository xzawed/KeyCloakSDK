#!/usr/bin/env sh
# 통합 전용 커버리지 리포트(`scripts/integration-coverage.mjs`) 자가테스트 — 보고 모드 파일럿(go · python).
#
# ⚠️ **커밋된 픽스처만 쓴다** — Docker 도 Go·Python 툴체인도 필요 없다. 실제 Keycloak 에 대고 도는 것은
# 레인 CI 의 integration 잡이다. 여기서 재는 것은 리포트의 **무결성 판정** 셋이다:
#   (1) 양성 — 건강한 픽스처에서 파일별·합계 수치와 미실행 함수 목록이 **정확히** 나온다.
#   (2) 음성 — 파생이 좁아지거나(그러면 %가 오른다), 핀과 갈리거나, 데이터에서 파일이 빠지거나,
#       함수 영역이 덮어써지면 exit 2 · 미실행 함수에 열린 소유자가 없으면 exit 1.
#   (3) 공허 — 빈 파생 · 아무것도 안 돈 실행은 「낮은 수치」가 아니라 측정 실패(exit 2)다.
#
# ⚠️ **픽스처의 커버 데이터는 실제 도구가 낸 것이다** — 손으로 지은 모양이 아니다(실측 2026-10-09):
#   data/go.cover          `go test -count=1 -coverprofile` (go1.26.4, tree/go + 기록 안 한 구동 테스트)
#   data/go-zero.cover     같은 명령에 `-run '^$'` — 「no tests to run」인데 exit 0 인 실행
#   data/python.json       `coverage run` + `coverage json`(7.15) · `[run] source = src/keycloak_sdk`(도구의 run 과 같은 꼴)
#   data/python-dup.json   admin/__init__.py 에 같은 이름의 property setter 를 더한 변형 — getter 영역이 사라진다
#   data/python-include.json `[run] include = */keycloak_sdk/*`(source 없음) — 한 번도 import 안 된 aio/auth.py 가 빠진다
#   data/python-zero.json  트리를 하나도 import 하지 않는 구동 — 전부 0
#   data/python-import.json 경계 모듈을 import 만 하고 아무것도 안 부르는 구동 — 몸통 0, 모듈 수준 줄만 덮인다
# 구동기는 「String·Close·Delete·AuthClient.String·hook 리터럴」과 「__repr__·logout·clients·aio 전체」를 일부러
# 안 부른다. 숫자를 바꾸려면 구동기를 다시 써서 **도구로 재생성**할 것 — JSON 을 손으로 고치지 않는다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/integration-coverage"
TOOL="$DIR/../integration-coverage.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
T="$TMP/t"
D="$TMP/data"

# 픽스처 트리 + **그 트리의** 파생 도구(실제 `coverage-boundary.mjs` 사본 — 변이가 그대로 전파된다).
fresh() {
  rm -rf "$T" "$D"
  mkdir -p "$T" "$D"
  cp -r "$FIX/tree/." "$T/"
  cp "$DIR/../coverage-boundary.mjs" "$T/scripts/coverage-boundary.mjs"
  cp "$FIX/data/go.cover" "$FIX/data/python.json" "$D/"
  git -C "$T" init -q
  git -C "$T" config core.autocrlf false
  git -C "$T" add -A
}
run() {
  git -C "$T" add -A
  OUT="$(node "$TOOL" "$@" 2>&1)" && RC=0 || RC=$?
}
# 줄 **전체**가 있는가 — 부분문자열 일치는 접미사가 붙은 오판(예: `(package-level …)`)을 통과시킨다.
assert_line() { # output line msg
  if printf '%s\n' "$1" | grep -qxF -- "$2"; then _l=yes; else _l=no; fi
  assert_eq yes "$_l" "$3 — 기대한 줄: [$2]"
}

# ── (1) 양성 대조군 ───────────────────────────────────────────────────────────────────────────
fresh
run check "$T"
assert_eq 0 "$RC" "건강한 픽스처의 check 는 exit 0 — 출력: $OUT"
assert_line "$OUT" "[go] pin OK — 3 files equal the derivation from .github/workflows/go-ci.yml:10 (grep -vE on cover.out)" "[check] go 핀 = 파생"
assert_line "$OUT" "[python] pin OK — 3 files equal the derivation from python/pyproject.toml:8 ([tool.coverage] omit)" "[check] python 핀 = 파생"
assert_line "$OUT" "integration-coverage check: OK — go 3 · python 3 files pinned · 8 owner entries, all open" "[check] 요약"

run report go "$T" --out "$D"
assert_eq 0 "$RC" "[go] 건강한 리포트는 exit 0 — 출력: $OUT"
assert_line "$OUT" "  go/admin.go 5/10 50.0%" "[go] admin.go — 한 줄 함수의 짝 안 맞는 { 와 원시 문자열 속 열 0 의 } 를 건너뛴다"
assert_line "$OUT" "  go/admin_users.go 3/7 42.9%" "[go] admin_users.go — 여러 줄 시그니처의 제네릭 함수"
assert_line "$OUT" "  go/auth.go 2/5 40.0% (package-level 0/1)" "[go] 패키지 수준 함수 리터럴은 어느 함수에도 속하지 않는다 — 분모에는 든다"
assert_line "$OUT" "  total 10/22 45.5%" "[go] 합계는 경계 파일만(config.go 제외)"
assert_line "$OUT" "  NEVER go/admin.go:10 AdminClient.String · 1 stmt · owner open-masking" "[go] 값 수신자 한 줄 함수"
assert_line "$OUT" "  NEVER go/admin.go:33 AdminClient.Close · 2 stmts · owner open-admin" "[go] 포인터 수신자"
assert_line "$OUT" "  NEVER go/admin_users.go:13 UsersResource.Delete · 4 stmts · owner open-admin" "[go] 블록 셋으로 된 미실행 함수"
assert_line "$OUT" "  NEVER go/auth.go:6 AuthClient.String · 1 stmt · owner open-masking" "[go] auth.go 의 Stringer"
assert_not_contains "$OUT" "Banner" "[go] 실행된 함수는 목록에 없다(원시 문자열 뒤 블록까지 Banner 의 것이다)"
assert_not_contains "$OUT" "config.go" "[go] 경계 밖 파일은 리포트에 없다"
assert_line "$OUT" "integration-coverage [go]: OK — 10/22 statements (45.5%) · 4 never-executed functions, all owned by open registry items" "[go] 요약"

run report python "$T" --out "$D"
assert_eq 0 "$RC" "[python] 건강한 리포트는 exit 0 — 출력: $OUT"
assert_line "$OUT" "  python/src/keycloak_sdk/admin/__init__.py lines 5/6 83.3% · bodies 1/2 50.0%" "[python] admin"
assert_line "$OUT" "  python/src/keycloak_sdk/aio/auth.py lines 0/3 0.0% · bodies 0/1 0.0%" "[python] 한 번도 import 안 된 경계 파일도 0% 로 분모에 든다"
assert_line "$OUT" "  python/src/keycloak_sdk/auth.py lines 16/19 84.2% · bodies 7/10 70.0%" "[python] auth — 중첩 함수 영역(helper.inner)을 이중으로 세지 않는다"
assert_line "$OUT" "  total lines 21/28 75.0% · bodies 8/13 61.5%" "[python] 합계 — import 때 도는 줄을 뺀 bodies 를 함께 낸다"
assert_line "$OUT" "  NEVER python/src/keycloak_sdk/admin/__init__.py:9 AdminClient.clients · 1 stmt · owner open-admin" "[python] property"
assert_line "$OUT" "  NEVER python/src/keycloak_sdk/aio/auth.py:5 AsyncAuthClient.token · 1 stmt · owner open-admin" "[python] async"
assert_line "$OUT" "  NEVER python/src/keycloak_sdk/auth.py:10 AuthorizationUrl.__repr__ · 1 stmt · owner open-masking" "[python] __repr__"
assert_line "$OUT" "  NEVER python/src/keycloak_sdk/auth.py:23 AuthClient.logout · 1 stmt · owner open-admin" "[python] 메서드"
assert_not_contains "$OUT" "helper" "[python] 실행된 함수·중첩 함수는 목록에 없다"
assert_not_contains "$OUT" "config.py" "[python] 경계 밖 파일은 리포트에 없다"
assert_line "$OUT" "integration-coverage [python]: OK — lines 21/28 (75.0%) · bodies 8/13 (61.5%) · 4 never-executed functions, all owned by open registry items" "[python] 요약"

# Linux 의 coverage.py 는 키를 `/` 로 쓴다 — Windows 에서 만든 `\` 키와 같은 리포트여야 한다.
fresh
sed -i -f "$FIX/slashes.sed" "$D/python.json"
assert_contains "$(cat "$D/python.json")" '"src/keycloak_sdk/auth.py"' "(변이가 착지했는지 먼저 본다)"
run report python "$T" --out "$D"
assert_eq 0 "$RC" "[python] / 키도 같은 파일이다 — 출력: $OUT"
assert_line "$OUT" "  total lines 21/28 75.0% · bodies 8/13 61.5%" "[python] / 키에서도 같은 합계"

# 다른 언어의 파생 실패가 이 언어의 리포트를 막지 않는다(픽스처에는 일곱 언어가 없어 그쪽은 늘 FAIL 이다).
fresh
sed -i 's#grep -vE .*#true#' "$T/.github/workflows/go-ci.yml"
run report python "$T" --out "$D"
assert_eq 0 "$RC" "[python] go 의 파생 실패는 python 리포트와 무관하다 — 출력: $OUT"

# ── (2) 음성: 파생 ↔ 핀 ───────────────────────────────────────────────────────────────────────
# 파생이 좁아진다 — 이것이 등록부가 실측한 함정의 꼴이다(파일이 빠지면 %가 오른다).
fresh
sed -i 's#(auth|admin|admin_users)#(auth|admin)#' "$T/.github/workflows/go-ci.yml"
assert_contains "$(cat "$T/.github/workflows/go-ci.yml")" "(auth|admin)\\.go" "(변이가 착지했는지 먼저 본다)"
run report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 파생이 핀보다 좁으면 exit 2"
assert_contains "$OUT" "FAIL [go] the derived boundary differs from the pin in scripts/integration-coverage.json — pinned, not derived: go/admin_users.go" "[go] 빠진 파일을 이름으로 댄다"
assert_not_contains "$OUT" "  total " "[go] 핀과 갈린 리포트는 수치를 내지 않는다(인용될 수 있는 숫자를 만들지 않는다)"
run check "$T"
assert_eq 2 "$RC" "[check] 파생이 핀보다 좁으면 exit 2"
assert_contains "$OUT" "pinned, not derived: go/admin_users.go" "[check] 같은 판정"

# 핀이 파생보다 좁다(누가 핀에서 줄을 지웠다).
fresh
sed -i '/^      "go\/admin_users.go",$/d' "$T/scripts/integration-coverage.json"
assert_not_contains "$(cat "$T/scripts/integration-coverage.json")" '"go/admin_users.go",' "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 2 "$RC" "[check] 핀에서 파일이 빠지면 exit 2"
assert_contains "$OUT" "FAIL [go] the derived boundary differs from the pin in scripts/integration-coverage.json — derived, not pinned: go/admin_users.go" "[check] 핀 밖 파일을 댄다"
run report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 리포트도 같은 판정"

# 파생 도구가 이 언어를 못 편다.
fresh
sed -i 's#grep -vE .*#true#' "$T/.github/workflows/go-ci.yml"
run report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] coverage-boundary 가 go 를 FAIL 하면 exit 2"
assert_contains "$OUT" "FAIL [go] coverage-boundary could not derive the boundary — .github/workflows/go-ci.yml:" "[go] 파생 실패 자리를 댄다"

# ── (2) 음성: 데이터 ───────────────────────────────────────────────────────────────────────────
# 빌드 태그 등으로 한 경계 파일이 계측되지 않았다 — 프로필에 그 파일이 없다.
fresh
sed -i '/\/auth\.go:/d' "$D/go.cover"
run report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 경계 파일이 데이터에 없으면 exit 2"
assert_contains "$OUT" "FAIL [go] go/auth.go is not in the coverage data" "[go] 빠진 파일을 댄다"
# 다른 패키지만 든 프로필 — 경계 셋 전부가 없다.
fresh
sed -i '/\/config\.go:/!{/^mode:/!d}' "$D/go.cover"
run report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 경계 파일이 하나도 없는 프로필은 exit 2"
assert_contains "$OUT" "FAIL [go] go/admin.go is not in the coverage data" "[go] admin.go 도 없다"
# include 만 쓴 coverage.py 설정 — 한 번도 import 안 된 경계 파일이 리포트에서 **조용히** 빠진다(84.0% 로 오른다).
fresh
cp "$FIX/data/python-include.json" "$D/python.json"
run report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] import 안 된 경계 파일이 데이터에 없으면 exit 2"
assert_contains "$OUT" "FAIL [python] python/src/keycloak_sdk/aio/auth.py is not in the coverage data" "[python] 빠진 파일을 댄다"
assert_not_contains "$OUT" "84.0" "[python] 좁아진 분모의 수치를 내지 않는다"
# coverage.py 는 함수 영역을 이름으로 묶는다 — 같은 이름(getter/setter)이면 하나가 사라진다.
fresh
cp "$FIX/data/python-dup.json" "$D/python.json"
run report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 함수 영역이 문장 수와 안 맞으면 exit 2"
assert_contains "$OUT" "FAIL [python] python/src/keycloak_sdk/admin/__init__.py: function regions add up to 8 of 9 statements" "[python] 덮어써진 영역을 회계로 잡는다"
# 같은 블록이 두 번(여러 테스트 바이너리의 프로필을 합친 꼴) — 문장은 한 번, 덮임은 어느 쪽이든.
fresh
printf 'example.com/fixture/go/admin.go:33.37,36.2 2 1\n' >> "$D/go.cover"
run report go "$T" --out "$D"
assert_eq 1 "$RC" "[go] 중복 블록이 Close 를 덮으면 그 소유자는 낡았다(exit 1) — 출력: $OUT"
assert_line "$OUT" "  go/admin.go 7/10 70.0%" "[go] 중복 블록의 문장을 두 번 세지 않는다"
assert_line "$OUT" "  total 12/22 54.5%" "[go] 합계 분모가 그대로다"
assert_contains "$OUT" "DRIFT [go] stale owner go/admin.go:AdminClient.Close — the integration run executes it now (or it no longer exists); drop the entry" "[go] 낡은 소유자"
fresh
printf 'example.com/fixture/go/admin.go:33.37,36.2 3 1\n' >> "$D/go.cover"
run report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 같은 블록의 문장 수가 다르면 exit 2"
assert_contains "$OUT" "FAIL [go] go/admin.go:33.37,36.2 appears with 2 and 3 statements" "[go] 모순 블록을 댄다"

# ── (2) 음성: 소유자(보고 모드 — exit 1, 게이트가 아니다) ─────────────────────────────────────
fresh
sed -i '/"go\/admin.go:AdminClient.Close"/d' "$T/scripts/integration-coverage.json"
run report go "$T" --out "$D"
assert_eq 1 "$RC" "[go] 소유자 없는 미실행 함수는 exit 1"
assert_contains "$OUT" "DRIFT [go] unowned never-executed function go/admin.go:AdminClient.Close — name an open item of docs/superpowers/plans/remaining-work.md for it in scripts/integration-coverage.json" "[go] 소유자 없음"
assert_line "$OUT" "  NEVER go/admin.go:33 AdminClient.Close · 2 stmts · owner NONE" "[go] 목록에도 NONE 으로 남는다"
assert_line "$OUT" "  total 10/22 45.5%" "[go] 소유 문제는 수치를 지우지 않는다"
fresh
sed -i 's#"go/admin.go:AdminClient.String": "open-masking"#"go/admin.go:AdminClient.String": "closed-item"#' "$T/scripts/integration-coverage.json"
run report go "$T" --out "$D"
assert_eq 1 "$RC" "[go] 닫힌 항목은 소유자가 아니다"
assert_contains "$OUT" "DRIFT [go] go/admin.go:AdminClient.String is owned by closed-item, which is not an open item of docs/superpowers/plans/remaining-work.md" "[go] 닫힌 소유자"
run check "$T"
assert_eq 1 "$RC" "[check] 닫힌 소유자는 데이터 없이도 잡힌다"
fresh
sed -i 's#"go/admin.go:AdminClient.String": "open-masking"#"go/admin.go:AdminClient.String": "nested-open"#' "$T/scripts/integration-coverage.json"
run check "$T"
assert_eq 1 "$RC" "[check] 들여쓴 하위 항목은 등록부의 항목이 아니다"
assert_contains "$OUT" "is owned by nested-open, which is not an open item" "[check] 하위 불릿"
fresh
sed -i 's#"go/auth.go:AuthClient.String": "open-masking"#"go/auth.go:AuthClient.String": "open-masking",\n      "go/auth.go:AuthClient.Token": "open-admin"#' "$T/scripts/integration-coverage.json"
run report go "$T" --out "$D"
assert_eq 1 "$RC" "[go] 실행되는 함수의 소유자는 낡았다"
assert_contains "$OUT" "DRIFT [go] stale owner go/auth.go:AuthClient.Token" "[go] 낡은 소유자"
fresh
sed -i 's#"go/auth.go:AuthClient.String": "open-masking"#"go/auth.go:AuthClient.String": "open-masking",\n      "go/config.go:Config.Valid": "open-admin"#' "$T/scripts/integration-coverage.json"
run check "$T"
assert_eq 1 "$RC" "[check] 핀 밖 파일의 소유자 항목"
assert_contains "$OUT" "DRIFT [go] owner entry go/config.go:Config.Valid names a file outside the pin" "[check] 핀 밖"

# ── (3) 공허 대조군 ─────────────────────────────────────────────────────────────────────────
# 아무 테스트도 안 돌았다(`-run` 이 아무것도 못 고름) — go 는 exit 0 으로 끝나고 0% 를 낸다.
fresh
cp "$FIX/data/go-zero.cover" "$D/go.cover"
run report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 경계 문장을 하나도 안 돈 실행은 exit 2"
assert_contains "$OUT" "FAIL [go] the run executed 0 of 22 boundary statements — a measurement failure, not a low number" "[go] 측정 실패 문구"
assert_not_contains "$OUT" "0.0%" "[go] 측정 실패에서 0% 를 내지 않는다"
fresh
cp "$FIX/data/python-zero.json" "$D/python.json"
run report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 트리를 하나도 안 돈 실행은 exit 2"
assert_contains "$OUT" "FAIL [python] the run executed 0 of 13 boundary statements inside functions" "[python] 측정 실패 문구"
# import 만 하고 아무 함수도 안 부른 실행 — conftest 가 패키지를 import 하므로, 통합 테스트가 **전부 skip** 돼
# pytest 가 exit 0 으로 끝나도 lines 는 0 이 아니다(픽스처 15/28 = 53.6% · 실제 트리 160/395 = 40.5%, 실측).
# 그래서 python 의 측정 실패 판정은 lines 가 아니라 **함수 몸통**(bodies)으로 한다(Grok 레그 주장 1 의 측정에서 나왔다).
fresh
cp "$FIX/data/python-import.json" "$D/python.json"
run report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] import 만 된 실행(함수 몸통 0)은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [python] the run executed 0 of 13 boundary statements inside functions — a measurement failure, not a low number (import alone credits 15 module-level lines)" "[python] import 크레딧을 수치로 내지 않는다"
assert_not_contains "$OUT" "53.6" "[python] import 크레딧뿐인 lines % 를 내지 않는다"
# 빈 파생 + 빈 핀 — 집합은 같으므로(∅ = ∅) 빈 집합 판정만이 잡는다. 파생 도구를 가짜로 바꿔 그 갈래만 태운다.
# ⚠️ 두 언어 다 「있되 비었다」여야 한다 — 한 언어를 빼 두면 check 의 exit 2 가 그 「없는 파생」에서 와서 빈 집합
# 갈래를 지워도 초록이었다(변이 실측: 빈 집합 통과 변이에 check 단언이 침묵했다).
fresh
printf '%s\n' 'const e = (d) => ({ dir: d, site: "fake:1", label: "fake", universe: 3, files: [] })' 'console.log(JSON.stringify({ langs: { go: e("go"), python: e("python") }, findings: [] }))' > "$T/scripts/coverage-boundary.mjs"
printf '%s\n' '{ "go": { "pinned": [], "owners": {} }, "python": { "pinned": [], "owners": {} } }' > "$T/scripts/integration-coverage.json"
run check "$T"
assert_eq 2 "$RC" "[check] 빈 파생은 exit 2(빈 핀과 같아도) — 출력: $OUT"
assert_contains "$OUT" "FAIL [python] the derived boundary is empty" "[check] python 도 빈 파생"
assert_not_contains "$OUT" "pin OK" "[check] 빈 집합끼리의 일치를 「핀 OK」로 찍지 않는다"
run report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 빈 파생은 exit 2"
assert_contains "$OUT" "FAIL [go] the derived boundary is empty — a report over no files is vacuous" "[go] 빈 파생 문구"
# 파생 결과에 언어가 아예 없다(FAIL 도 아닌데) — 빈 집합과 다른 갈래다.
fresh
printf '%s\n' 'console.log(JSON.stringify({ langs: { go: { dir: "go", site: "fake:1", label: "fake", universe: 3, files: ["go/admin.go"] } }, findings: [] }))' > "$T/scripts/coverage-boundary.mjs"
run report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 파생 결과에 언어가 없으면 exit 2"
assert_contains "$OUT" "FAIL [python] coverage-boundary returned no derivation for python" "[python] 없는 파생"

# ── 못 읽는 것을 통과로 넘기지 않는다 ─────────────────────────────────────────────────────────
fresh
rm "$D/go.cover"
run report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 데이터가 없으면 exit 2"
assert_contains "$OUT" "FAIL [go] no coverage data at" "[go] 데이터 없음"
fresh
rm "$T/scripts/integration-coverage.json"
run check "$T"
assert_eq 2 "$RC" "핀 파일이 없으면 exit 2"
assert_contains "$OUT" "FAIL [-] scripts/integration-coverage.json is missing or not JSON" "핀 파일 없음"
fresh
printf '%s\n' '{ "go": { "pinned": ["go/admin.go"], "owners": {} }, "rust": { "pinned": [], "owners": {} } }' > "$T/scripts/integration-coverage.json"
run check "$T"
assert_eq 2 "$RC" "파일럿이 안 재는 언어를 핀에 넣으면 exit 2"
assert_contains "$OUT" "FAIL [-] scripts/integration-coverage.json names rust, which this pilot does not measure" "모르는 언어"
assert_contains "$OUT" "FAIL [python] scripts/integration-coverage.json has no pin for python" "빠진 언어"
fresh
rm "$T/docs/superpowers/plans/remaining-work.md"
run check "$T"
assert_eq 2 "$RC" "등록부가 없으면 exit 2"
assert_contains "$OUT" "FAIL [-] docs/superpowers/plans/remaining-work.md is missing" "등록부 없음"
fresh
rm "$T/scripts/coverage-boundary.mjs"
run check "$T"
assert_eq 2 "$RC" "파생 도구가 없으면 exit 2"
assert_contains "$OUT" "FAIL [-] scripts/coverage-boundary.mjs is missing" "파생 도구 없음"
fresh
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "파일럿이 안 재는 언어는 usage(exit 2)"
assert_contains "$OUT" "this pilot measures go · python" "usage 문구"

assert_report
