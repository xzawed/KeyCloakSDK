#!/usr/bin/env sh
# 통합 전용 커버리지 장부의 **단위 장부 소유** 자가테스트(`unit:ledger` — 등록부 coverage-omit-hides-security-paths).
#
# 통합 실행이 한 번도 안 도는 함수라도 단위 스위트가 단위 장부가 재는 만큼(언어마다 줄 · 문장 · 가지) 다 닿으면 `unit:ledger` 가
# 소유한다 — 그 언어의 단위 장부(`scripts/unit-unreached.json`)가 서 있고, admin 표면 파일이 아니며, 장부에 그 함수의 항목이
# **없을** 때만이다. 항목이 있으면 까닭이 무엇이든(`defensive:` · `unreachable:` · `integration:` · 열린 id) 거부한다 — 규칙은
# `scripts/integration-coverage.mjs` 의 머리 주석.
#
# 왜 따로인가: 변이 레코드가 프로브마다 이 시험을 두 번(기준선 · 변이) 돈다 — 하네스 소유 시험을 떼어 낸 것과 같은 까닭이다(그 머리).
# 픽스처 · 데이터의 출처는 `test-integration-coverage.sh` 의 머리가, 준비 함수는 셋이 함께 소싱하는 `ic-fixture.sh` 가 소유한다.
# ⚠️ 도구 경로(`TOOL` · `BOUNDARY`)는 이 파일에 둔다 — 변이 스윕이 M1 짝을 시험 파일의 글자에서 파생한다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/integration-coverage"
TOOL="$DIR/../integration-coverage.mjs"
BOUNDARY="$DIR/../coverage-boundary.mjs"
. "$DIR/ic-fixture.sh"

PINS="$T/scripts/integration-coverage.json"
UNIT="$T/scripts/unit-unreached.json"
REG="docs/superpowers/plans/remaining-work.md"
# 픽스처의 go 함수 — 통합 실행이 안 돌고(go.cover 0 회) 단위 장부에 항목이 없는 것 · 통합 실행이 도는 것.
GS="go/admin.go:AdminClient.String"
GT="go/auth.go:AuthClient.Token"
# 소유자 하나를 바꾼다(착지를 먼저 본다).
own() { # <key> <owner>
  sed -i "s#\"$1\": \"[^\"]*\"#\"$1\": \"$2\"#" "$PINS"
  assert_contains "$(cat "$PINS")" "\"$1\": \"$2\"" "(소유자가 $2 로 바뀌었는지 먼저 본다 — $1)"
}
# 단위 장부의 go 객체 맨 앞에 항목 하나를 더한다(go 는 문장만 센다 — 꼴은 { statements, why }).
unit_entry() { # <key> <why>
  sed -i "s#^  \"go\": {\$#  \"go\": {\n    \"$1\": { \"statements\": 1, \"why\": \"$2\" },#" "$UNIT"
  assert_contains "$(cat "$UNIT")" "\"$1\": { \"statements\": 1, \"why\": \"$2\" }," "(단위 항목이 착지했는지 먼저 본다 — $2)"
}

# ── 양성 — 단위 장부에 항목이 없으면 소유가 선다. check 는 따로 세고, report 는 미실행 목록에 그대로 남긴다(숨기지 않는다).
fresh; own "$GS" unit:ledger
run check "$T"
assert_eq 0 "$RC" "unit-owner: no unit entry → check exit 0 — 출력: $OUT"
assert_contains "$OUT" "accounted by the unit ledger" "unit-owner: no unit entry → check 가 단위 장부 소유를 센다"
assert_line "$OUT" "integration-coverage check: OK — go 3 · python 3 · node 2 · rust 3 · php 2 · ruby 3 · dotnet 2 · java 2 · kotlin 2 files pinned · 94 owner entries, 93 open · 1 accounted by the unit ledger" "unit-owner: no unit entry → check 의 요약 줄"
run report go "$T" --out "$D"
assert_eq 0 "$RC" "unit-owner: report on a never-executed function → exit 0 — 출력: $OUT"
assert_not_contains "$OUT" "DRIFT" "unit-owner: report on a never-executed function → no DRIFT for it"
assert_line "$OUT" "  NEVER go/admin.go:10 AdminClient.String · 1 stmt · owner unit:ledger" "unit-owner: report on a never-executed function → 미실행 목록에 단위 장부 소유로 남는다"
assert_line "$OUT" "integration-coverage [go]: OK — 10/22 statements (45.5%) · 4 never-executed functions, all owned by open registry items or the unit ledger" "unit-owner: report on a never-executed function → 통과 요약"

# ── 음성 — 항목이 있으면 까닭이 무엇이든 거부한다. 단위 시험의 갈래를 지우고 `defensive:` 로 적으면 두 검사가 다 초록인 채 아무
# 스위트도 안 도는 갈래에 열린 소유자가 없다 — 그래서 열린 id 가 다시 소유해야 한다(까닭마다 한 칸).
for cls in defensive unreachable integration; do
  fresh; own "$GS" unit:ledger; unit_entry "$GS" "$cls: a branch the unit suite does not reach"
  run check "$T"
  assert_eq 1 "$RC" "unit-owner: $cls unit entry → check exit 1 — 출력: $OUT"
  assert_line "$OUT" "DRIFT [go] $GS is owned by unit:ledger, but scripts/unit-unreached.json records $cls: for it — name an open item of $REG" "unit-owner: $cls unit entry → 그 까닭을 댄다"
done
# 열린 id 를 why 로 적은 항목도 같다(픽스처의 AdminClient.Close — why open-masking).
fresh; own "go/admin.go:AdminClient.Close" unit:ledger
run check "$T"
assert_eq 1 "$RC" "unit-owner: registry-id unit entry → check exit 1 — 출력: $OUT"
assert_line "$OUT" "DRIFT [go] go/admin.go:AdminClient.Close is owned by unit:ledger, but scripts/unit-unreached.json records open-masking for it — name an open item of $REG" "unit-owner: registry-id unit entry → 그 id 를 댄다"

# ── 무결성 — 그 언어의 장부가 없으면 소유로 치지 않고 FAIL(2)이다. report 로 잰다: check 는 제 단위 장부 고리에서 이미 FAIL 을 내므로
# unitLedgerFor 를 건너뛰는 판정을 check 로는 못 가른다. 소유자 둘이 같은 장부를 물어도 FAIL 은 한 번이다.
fresh; own "$GS" unit:ledger; own "go/admin.go:AdminClient.Close" unit:ledger
sed -i '/^  "go": {$/,/^  },$/d' "$UNIT"
assert_not_contains "$(cat "$UNIT")" '"go"' "(go 객체가 지워졌는지 먼저 본다)"
run report go "$T" --out "$D"
assert_eq 2 "$RC" "unit-owner: language object missing → report go exit 2 — 출력: $OUT"
assert_line "$OUT" "FAIL [go] scripts/unit-unreached.json has no go object — an empty ledger is {}, not a missing one" "unit-owner: language object missing → 무엇이 없는지 댄다"
assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c 'has no go object' || true)" "unit-owner: language object missing → FAIL 은 한 번이다(언어마다 한 번 잰다)"

# ── 오타 — 단위 소유로 읽지 않고 등록부 판정으로 떨어져 「열린 항목이 아니다」 DRIFT 다(대소문자 · 맨 단어).
for typo in unit:Ledger unit; do
  fresh; own "$GS" "$typo"
  run check "$T"
  assert_eq 1 "$RC" "unit-owner: typo variants — $typo → check exit 1 — 출력: $OUT"
  assert_line "$OUT" "DRIFT [go] $GS is owned by $typo, which is not an open item of $REG" "unit-owner: typo variants — $typo 는 열린 항목이 아니다"
done

# ── admin 표면 — 표면 파일의 함수는 통합 실행에서 돌거나 열린 항목이 소유해야 한다(exit 4 관문). 단위 장부가 다 닿아도 그 관문을
# 대신하지 않는다 — 핀 안(go 의 admin_users.go — 여섯 언어의 꼴)이든 핀 밖(node 의 other.ts — node · python · java 의 꼴)이든 거부한다.
# 표면 주입은 test-integration-coverage.sh 절 (5) 와 같은 꼴이다.
SURF="is admin surface — the integration run must execute it, or an open item of $REG must own it"
surface() { # <lang> <json array body>
  sed -i "s|^  \"$1\": {\$|  \"$1\": {\n    \"surface\": [$2],|" "$PINS"
  assert_contains "$(cat "$PINS")" "\"surface\": [$2]" "(표면 주입이 착지했는지 먼저 본다)"
}
GD="go/admin_users.go:UsersResource.Delete"
fresh; surface go '"go/admin_users.go"'; own "$GD" unit:ledger
run check "$T"
assert_eq 1 "$RC" "unit-owner: pinned surface file → check exit 1 — 출력: $OUT"
assert_line "$OUT" "DRIFT [go] $GD is owned by unit:ledger, but go/admin_users.go $SURF" "unit-owner: pinned surface file → 표면이라 댄다"
# 리뷰가 지목한 우회 — 표면 연산의 통합 시험을 지우고(픽스처의 Delete 는 통합 데이터에서 0 회다) unit:ledger 를 적으면 report 가 0 이 아니라 1 이다.
run report go "$T" --out "$D"
assert_eq 1 "$RC" "unit-owner: report on a never-executed pinned surface function → exit 1 — 출력: $OUT"
assert_line "$OUT" "DRIFT [go] $GD is owned by unit:ledger, but go/admin_users.go $SURF" "unit-owner: report on a never-executed pinned surface function → 표면이라 댄다"
fresh; surface node '"node/src/other.ts"'
sed -i '/^  "node": {$/,/^  },$/ s|^    "owners": {$|    "owners": {\n      "node/src/other.ts:other": "unit:ledger",|' "$PINS"
assert_contains "$(cat "$PINS")" '"node/src/other.ts:other": "unit:ledger"' "(핀 밖 표면 파일의 단위 소유가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 1 "$RC" "unit-owner: surface file outside the pin → check exit 1 — 출력: $OUT"
assert_line "$OUT" "DRIFT [node] node/src/other.ts:other is owned by unit:ledger, but node/src/other.ts $SURF" "unit-owner: surface file outside the pin → 표면이라 댄다"
# 콜론 없는 키 — check 의 핀 판정(「names a file outside the pin」)만 낸다. 소유자 판정으로 넘기면 키에서 깎은 이름이 표면 파일과
# 맞아떨어질 때(`go/admin_users.gox` → `go/admin_users.go`) 엉뚱한 표면 DRIFT 가 하나 더 찍힌다.
fresh; surface go '"go/admin_users.go"'
sed -i 's#^      "go/admin.go:AdminClient.Close": "open-admin",$#      "go/admin.go:AdminClient.Close": "open-admin",\n      "go/admin_users.gox": "unit:ledger",#' "$PINS"
assert_contains "$(cat "$PINS")" '"go/admin_users.gox": "unit:ledger",' "(콜론 없는 키가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 1 "$RC" "unit-owner: colon-less key → check exit 1 — 출력: $OUT"
assert_line "$OUT" "DRIFT [go] owner entry go/admin_users.gox names a file outside the pin and the admin surface" "unit-owner: colon-less key → 핀 판정만 낸다"
assert_not_contains "$OUT" "go/admin_users.gox is owned by unit:ledger" "unit-owner: colon-less key → 소유자 판정으로 넘기지 않는다"

# ── 낡은 소유자 — 통합 실행이 그 함수를 돌면 단위 장부 소유도 지우라고 한다(소유자의 종류와 무관한 규칙).
fresh
sed -i "s#^      \"go/auth.go:AuthClient.String\": \"open-masking\"\$#      \"go/auth.go:AuthClient.String\": \"open-masking\",\n      \"$GT\": \"unit:ledger\"#" "$PINS"
assert_contains "$(cat "$PINS")" "\"$GT\": \"unit:ledger\"" "(실행되는 함수의 단위 소유가 착지했는지 먼저 본다)"
run report go "$T" --out "$D"
assert_eq 1 "$RC" "unit-owner: report on an executed function → exit 1 — 출력: $OUT"
assert_contains "$OUT" "stale owner" "unit-owner: report on an executed function → stale owner"
assert_line "$OUT" "DRIFT [go] stale owner $GT — the integration run executes it now (or it no longer exists); drop the entry" "unit-owner: report on an executed function → 그 항목을 지우라고 한다"

assert_report
