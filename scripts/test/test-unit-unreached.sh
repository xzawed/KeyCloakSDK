#!/usr/bin/env sh
# 단위 미도달 장부(`scripts/integration-coverage.mjs` 의 `unit-report` · `check` — kotlin · php, 등록부
# coverage-exclusion-hides-untested-branches) 자가테스트 — **종료코드**를 단언한다(0 측정 = 장부 · 1 DRIFT · 2 FAIL — 뜻은 그 도구 머리가
# 소유한다). 문구는 무엇을 잡았는지 가리는 데만 쓴다.
#
# ⚠️ **커밋된 픽스처만 쓴다** — Docker · JDK · Gradle · PHP 가 필요 없다(`unit-report` 는 데이터를 읽기만 한다). 데이터는 실제 도구가
# 낸 것이다(2026-11-18):
#   fixtures/unit-unreached/data/kotlin.unit.xml · kotlin.unit.javap.txt   도구의 `unit kotlin`(JDK 21.0.8 · kotlin 2.4.21 · Kover 0.9.11 ·
#       JaCoCo 0.8.16) — 임시 루트에 tree 사본 + 실제 kotlin/ 의 Gradle 래퍼 + java/pom.xml(JaCoCo 판을 거기서 읽는다). 세션 id 를
#       HOST-00000000 으로, javap 의 줄끝을 LF 로 · `Classfile` 의 생성 루트를 지워 `kotlin/` 부터로만 바꿨다
#   fixtures/unit-unreached/data/php.unit/   도구의 `unit php`(PHP 8.3.36 · PHPUnit 12.5.33 · php-code-coverage 12.5.7 · Xdebug 3.5.3) —
#       임시 루트에 tree 사본 + 실제 php/vendor 사본. index.xml 의 `<project source>` 생성 루트만 `@ROOT@` 로 바꿨다
# 단위 구동(tree/kotlin/src/test · tree/php/tests/Unit)은 빈 code · null · 빈 user · 빈 문자열을 안 보내고 unused · logoutUrl 을 안
# 부른다. 숫자를 바꾸려면 구동을 고쳐 **도구로 재생성**할 것 — 데이터를 손으로 고치지 않는다(아래 음성 대조군만 고친다).
# `check` 의 장부 판정(데이터 없이 — 꼴 · 경계 · why)은 통합 커버리지 픽스처 트리(`ic-fixture.sh` 의 fresh)에서 잰다 — check 는 아홉
# 언어를 다 보므로 kotlin · php 뿐인 이 트리로는 못 잰다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/integration-coverage"
UFIX="$DIR/fixtures/unit-unreached"
TOOL="$DIR/../integration-coverage.mjs"
BOUNDARY="$DIR/../coverage-boundary.mjs"
# 준비 함수(fresh · run · assert_line · TMP/T/D)는 통합 커버리지 자가테스트와 함께 쓴다. ⚠️ 도구 경로는 여기 둔다 — 변이 스윕이 M1 짝을
# 시험 파일의 글자에서 파생한다(ic-fixture.sh 머리).
. "$DIR/ic-fixture.sh"

K=kotlin/src/main/kotlin/kc/auth/AuthClient.kt
P=php/src/AuthClient.php
L="$T/scripts/unit-unreached.json"

# 단위 픽스처 트리 + 그 트리의 파생 도구 + 데이터와 그 기록(run 이 쓰는 꼴).
ufresh() {
  rm -rf "$T" "$D"
  mkdir -p "$T" "$D"
  cp -r "$UFIX/tree/." "$T/"
  cp "$BOUNDARY" "$T/scripts/coverage-boundary.mjs"
  cp "$UFIX/data/kotlin.unit.xml" "$UFIX/data/kotlin.unit.javap.txt" "$D/"
  cp -r "$UFIX/data/php.unit" "$D/php.unit"
  _r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
  sed -i "s#@ROOT@#$_r#g" "$D/php.unit/index.xml"
  kmark 0
  pmark 0
  git -C "$T" init -q
  git -C "$T" config core.autocrlf false
  git -C "$T" add -A
}
# `unit kotlin` 의 기록 — 데이터 · javap 출력 · 경계 파일의 지금 sha1. 인자: 종료코드 [시험 수] [실패 수] [통합 보고 수].
kmark() { # exit [completed] [failures] [integration]
  printf '{"run":"kotlin","suite":"unit","exit":%s,"jacoco":"0.8.16","module":"kc-unit","data_sha1":"%s","javap_sha1":"%s","exec_sha1":"0","tests":{"completed":%s,"failures":%s,"errors":0,"skipped":0},"integration":%s,"files":{"%s":"%s"}}\n' \
    "$1" "$(sha1sum "$D/kotlin.unit.xml" | cut -d' ' -f1)" "$(sha1sum "$D/kotlin.unit.javap.txt" | cut -d' ' -f1)" \
    "${2:-1}" "${3:-0}" "${4:-0}" "$K" "$(sha1sum "$T/$K" | cut -d' ' -f1)" > "$D/kotlin.unit.run.json"
}
# `unit php` 의 기록 — 종료코드 · 지금 index.xml 의 sha1.
pmark() { # exit
  printf '{"run":"php","suite":"unit","exit":%s,"index_sha1":"%s"}\n' "$1" "$(sha1sum "$D/php.unit/index.xml" | cut -d' ' -f1)" > "$D/php.unit.run.json"
}

# ── (1) 양성 — 측정 = 장부 → 0 ───────────────────────────────────────────────────────────────────
ufresh
run unit-report kotlin "$T" --out "$D"
assert_eq 0 "$RC" "[kotlin] 측정이 장부와 같으면 exit 0 — 출력: $OUT"
assert_line "$OUT" "  UNREACHED $K:12 AuthClient.exchange · 1 line · 1 branch · defensive: the drive never sends a blank code" "[kotlin] 제 줄의 실패 갈래 — 놓친 줄 · 놓친 가지"
assert_line "$OUT" "  UNREACHED $K:19 AuthClient.elvis · 0 lines · 1 branch · open-gap" "[kotlin] 행복 경로가 도는 줄의 실패 갈래(elvis)도 가지로 센다 · why 가 열린 항목 id"
assert_line "$OUT" "  UNREACHED $K:22 AuthClient.pick · 0 lines · 1 branch · unreachable: the branch sits in pick's lambda — the key is the source function" "[kotlin] 람다 안의 놓친 가지는 소스 함수 pick 의 수다"
assert_not_contains "$OUT" 'lambda$' "[kotlin] 합성 이름(pick\$lambda\$0)이 키로 새지 않는다"
assert_line "$OUT" "  UNREACHED $K:26 AuthClient.token · 0 lines · 2 branches · integration: the require branch inside an inline function" "[kotlin] 인라인 require 의 가지도 센다"
assert_line "$OUT" "  UNREACHED $K:31 AuthClient.unused · 1 line · 0 branches · integration: the drive never calls it" "[kotlin] 안 부른 함수"
assert_not_contains "$OUT" "AuthClient.realm" "[kotlin] 다 닿는 함수는 목록에 없다"
assert_not_contains "$OUT" "Config" "[kotlin] 경계 밖 파일은 목록에 없다"
assert_line "$OUT" "unit-unreached [kotlin]: OK — 5 functions with code the unit suite never reaches (2 lines · 5 branches), each recorded in scripts/unit-unreached.json" "[kotlin] 요약"

run unit-report php "$T" --out "$D"
assert_eq 0 "$RC" "[php] 측정이 장부와 같으면 exit 0 — 출력: $OUT"
assert_line "$OUT" "  UNREACHED $P:23 AuthClient::exchange · 1 line · defensive: the drive never sends an empty code" "[php] 제 줄의 실패 갈래"
assert_line "$OUT" "  UNREACHED $P:33 AuthClient::apply · 1 line · open-gap" "[php] 클로저의 안 돈 줄은 감싼 메서드의 것"
assert_line "$OUT" "  UNREACHED $P:53 AuthClient::logoutUrl · 1 line · integration: the drive never calls it" "[php] 안 부른 메서드"
# ⚠️ 알려진 틈을 고정한다 — 행복 경로가 도는 줄의 `?? throw` 는 줄 수를 안 바꿔 장부가 못 본다(도구 머리 주석). 이 단언이 깨지면 도구가
# 가지를 보게 된 것이다 — 머리 주석과 장부를 함께 고칠 때다.
assert_not_contains "$OUT" "AuthClient::pick" "[php] 같은 줄의 실패 갈래(?? throw)는 줄 수로 안 보인다 — 알려진 틈"
assert_line "$OUT" "unit-unreached [php]: OK — 3 functions with code the unit suite never reaches (3 lines), each recorded in scripts/unit-unreached.json" "[php] 요약"

# ── (2) 음성 — 장부와 다르면 DRIFT(1) ────────────────────────────────────────────────────────────
# 새로 생긴 미도달 — 데이터에서 다 닿던 realm 을 안 닿게 바꾼다(장부에 없다).
ufresh
sed -i 's#<method name="realm" desc="()Ljava/lang/String;" line="8"><counter type="INSTRUCTION" missed="0" covered="3"/><counter type="LINE" missed="0" covered="1"/>#<method name="realm" desc="()Ljava/lang/String;" line="8"><counter type="INSTRUCTION" missed="3" covered="0"/><counter type="LINE" missed="1" covered="0"/>#' "$D/kotlin.unit.xml"
kmark 0
run unit-report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[kotlin] 장부에 없는 미도달 함수는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [kotlin] unrecorded unreached code $K:AuthClient.realm — the unit suite never reaches 1 line · 0 branches of it: test that code, or record why in scripts/unit-unreached.json" "[kotlin] 새 미도달"
ufresh
sed -i 's#<method name="realm" signature="realm(): string" start="17" end="20" crap="1" executable="1" executed="1"#<method name="realm" signature="realm(): string" start="17" end="20" crap="1" executable="1" executed="0"#' "$D/php.unit/AuthClient.php.xml"
sed -i 's#executable="13" executed="10"#executable="13" executed="9"#g' "$D/php.unit/AuthClient.php.xml" "$D/php.unit/index.xml"
pmark 0
run unit-report php "$T" --out "$D"
assert_eq 1 "$RC" "[php] 장부에 없는 미도달 함수는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [php] unrecorded unreached code $P:AuthClient::realm — the unit suite never reaches 1 line of it" "[php] 새 미도달"

# 람다 안의 놓친 가지 — 장부에서 pick 을 지우면 소스 함수 이름으로 DRIFT 다(합성 메서드로 새지 않는다 — 브리프 보정 1).
ufresh
sed -i '/AuthClient\.pick"/,/},/d' "$L"
run unit-report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[kotlin] 람다 안의 놓친 가지가 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [kotlin] unrecorded unreached code $K:AuthClient.pick — the unit suite never reaches 0 lines · 1 branch of it" "[kotlin] 람다의 가지 — 소스 함수 키"
ufresh
sed -i '/AuthClient::apply"/,/},/d' "$L"
run unit-report php "$T" --out "$D"
assert_eq 1 "$RC" "[php] 클로저 안의 안 돈 줄이 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [php] unrecorded unreached code $P:AuthClient::apply — the unit suite never reaches 1 line of it" "[php] 클로저의 줄 — 감싼 메서드 키"

# 수가 바뀌었다 — 장부의 수와 측정이 다르다(가지 하나가 새로 생긴 꼴).
ufresh
sed -i '/AuthClient\.exchange"/,/}/ s#"branches": 1,#"branches": 2,#' "$L"
run unit-report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[kotlin] 수가 다르면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [kotlin] $K:AuthClient.exchange: the unit run leaves 1 line · 1 branch unreached, scripts/unit-unreached.json records 1 line · 2 branches — the unit suite reaches more of it now: lower the counts" "[kotlin] 바뀐 수 — 장부보다 덜 놓쳤다"
ufresh
sed -i '/AuthClient\.exchange"/,/}/ s#"lines": 1,#"lines": 0,#' "$L"
run unit-report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[kotlin] 장부보다 더 놓쳐도 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [kotlin] $K:AuthClient.exchange: the unit run leaves 1 line · 1 branch unreached, scripts/unit-unreached.json records 0 lines · 1 branch — test what the unit suite does not reach, or record why and correct the counts" "[kotlin] 바뀐 수 — 장부보다 더 놓쳤다"
ufresh
sed -i '/AuthClient::exchange"/,/}/ s#"lines": 1,#"lines": 2,#' "$L"
run unit-report php "$T" --out "$D"
assert_eq 1 "$RC" "[php] 수가 다르면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [php] $P:AuthClient::exchange: the unit run leaves 1 line unreached, scripts/unit-unreached.json records 2 lines" "[php] 바뀐 수"

# 낡은 항목 — 다 닿는 함수 · 데이터에 없는 함수 · 경계 밖 파일을 가리킨다.
ufresh
sed -i "s#\"kotlin\": {#\"kotlin\": {\n    \"$K:AuthClient.realm\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: stale\" },\n    \"$K:AuthClient.gone\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: renamed\" },\n    \"kotlin/src/main/kotlin/kc/auth/Config.kt:Config.valid\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: outside\" },#" "$L"
run unit-report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[kotlin] 낡은 항목은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [kotlin] stale entry $K:AuthClient.realm — the unit run reaches all of it now; drop the entry" "[kotlin] 다 닿는 함수의 항목"
assert_contains "$OUT" "DRIFT [kotlin] stale entry $K:AuthClient.gone — the data of $K has no such function (renamed or removed?)" "[kotlin] 없는 함수의 항목"
assert_contains "$OUT" "DRIFT [kotlin] scripts/unit-unreached.json: entry kotlin/src/main/kotlin/kc/auth/Config.kt:Config.valid names a file outside the boundary derived from kotlin/build.gradle.kts:32" "[kotlin] 경계 밖 파일의 항목"
ufresh
sed -i "s#\"php\": {#\"php\": {\n    \"$P:AuthClient::realm\": { \"lines\": 1, \"why\": \"integration: stale\" },\n    \"php/src/Config.php:Config::valid\": { \"lines\": 1, \"why\": \"integration: outside\" },#" "$L"
run unit-report php "$T" --out "$D"
assert_eq 1 "$RC" "[php] 낡은 항목은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [php] stale entry $P:AuthClient::realm — the unit run reaches all of it now" "[php] 다 닿는 메서드의 항목"
assert_contains "$OUT" "DRIFT [php] scripts/unit-unreached.json: entry php/src/Config.php:Config::valid names a file outside the boundary" "[php] 경계 밖 파일의 항목"

# why — 닫힌 항목 · 들여쓴 하위 불릿(항목이 아니다) · 모르는 id · 까닭 머리만 있고 말이 없다.
ufresh
sed -i 's#"why": "open-gap"#"why": "closed-gap"#' "$L"
run unit-report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[kotlin] 닫힌 등록부 항목은 why 가 아니다 — exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [kotlin] $K:AuthClient.elvis: why \"closed-gap\" is neither unreachable: · defensive: · integration: with a reason nor an open item of docs/superpowers/plans/remaining-work.md" "[kotlin] 닫힌 id"
run unit-report php "$T" --out "$D"
assert_eq 1 "$RC" "[php] 닫힌 등록부 항목은 why 가 아니다 — exit 1"
assert_contains "$OUT" "DRIFT [php] $P:AuthClient::apply: why \"closed-gap\"" "[php] 닫힌 id"
ufresh
sed -i 's#"why": "open-gap"#"why": "nested-open"#' "$L"
run unit-report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[kotlin] 들여쓴 하위 불릿의 id 는 항목이 아니다 — exit 1"
ufresh
sed -i 's#"why": "open-gap"#"why": "because I said so"#' "$L"
run unit-report php "$T" --out "$D"
assert_eq 1 "$RC" "[php] 까닭 머리도 열린 id 도 아닌 why 는 exit 1"
ufresh
sed -i 's#"why": "defensive: the drive never sends a blank code"#"why": "defensive:  "#' "$L"
run unit-report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[kotlin] 까닭 머리 뒤에 말이 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "names a kind but not the reason" "[kotlin] 빈 까닭"

# ── (3) 무결성 — FAIL(2): 수치 대조를 하지 않는다 ─────────────────────────────────────────────────
ufresh
rm "$D/kotlin.unit.xml"
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 데이터가 없으면 exit 2"
assert_contains "$OUT" "FAIL [kotlin] no coverage data at" "[kotlin] 데이터 없음"
assert_contains "$OUT" "run the unit suite first (node scripts/integration-coverage.mjs unit kotlin)" "[kotlin] 다시 돌릴 명령"
ufresh
rm -r "$D/php.unit"
run unit-report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 데이터가 없으면 exit 2"
# 다른 바이트 — 실행 뒤 경계 파일이 바뀌었다(기록 · 데이터의 해시와 트리가 다르다).
ufresh
printf '\n// changed after the run\n' >> "$T/$K"
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 다른 바이트의 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [kotlin] $K: the data was taken from other bytes" "[kotlin] 다른 바이트"
ufresh
printf '\n// changed after the run\n' >> "$T/$P"
run unit-report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 다른 바이트의 데이터는 exit 2"
assert_contains "$OUT" "FAIL [php] $P: the data was taken from other bytes" "[php] 다른 바이트"
# 단위 실행이 아니다 — 통합 실행의 기록(suite 없음) · 통합 시험이 섞인 실행 · 단위 스위트 밖 시험이 실린 데이터.
ufresh
sed -i 's#"suite":"unit",##' "$D/kotlin.unit.run.json"
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 통합 실행의 기록은 exit 2"
assert_contains "$OUT" "FAIL [kotlin] no record that \`unit kotlin\` wrote this data" "[kotlin] 단위 기록 아님"
ufresh
kmark 0 1 0 1
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 통합 시험 보고가 섞인 실행은 exit 2"
assert_contains "$OUT" "FAIL [kotlin] the run included 1 integration test report — the data would not be unit-only (unit kotlin runs test only)" "[kotlin] 통합 섞임"
ufresh
sed -i 's#"suite":"unit",##' "$D/php.unit.run.json"
run unit-report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 통합 실행의 기록은 exit 2"
assert_contains "$OUT" "FAIL [php] no record that \`unit php\` wrote this data" "[php] 단위 기록 아님"
ufresh
sed -i 's#name="DriveTest::testDrive"#name="DriveIT::testDrive"#' "$D/php.unit/index.xml"
pmark 0
run unit-report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 단위 스위트 밖 시험이 실린 데이터는 exit 2"
assert_contains "$OUT" "FAIL [php] the run included tests outside the unit suite (DriveIT) — the report would not be unit-only" "[php] 스위트 밖"
# 실패한 실행 — 종료코드 · 실패한 시험.
ufresh
kmark 1
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 실패한 실행의 데이터는 exit 2"
assert_contains "$OUT" "FAIL [kotlin] the run that wrote this data exited 1" "[kotlin] 실패한 실행"
ufresh
kmark 0 1 1
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 실패한 단위 시험이 있으면 exit 2"
assert_contains "$OUT" "FAIL [kotlin] 1 of 1 unit tests failed" "[kotlin] 실패한 시험"
ufresh
kmark 0 0
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 단위 시험 0 개의 실행은 exit 2"
assert_contains "$OUT" "FAIL [kotlin] the run recorded no unit tests" "[kotlin] 공허한 실행"
ufresh
pmark 2
run unit-report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 실패한 실행의 데이터는 exit 2"
assert_contains "$OUT" "FAIL [php] the run that wrote this data exited 2" "[php] 실패한 실행"
# 경계 파일이 데이터에 없다.
ufresh
sed -i 's#<sourcefile name="AuthClient.kt">#<sourcefile name="Other.kt">#' "$D/kotlin.unit.xml"
kmark 0
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 경계 파일이 데이터에 없으면 exit 2"
assert_contains "$OUT" "FAIL [kotlin] $K is not in the coverage data" "[kotlin] 데이터에 없는 경계 파일"
ufresh
sed -i 's#href="AuthClient.php.xml"#href="Gone.php.xml"#; s#<file name="AuthClient.php"#<file name="Gone.php"#' "$D/php.unit/index.xml"
pmark 0
run unit-report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 경계 파일이 데이터에 없으면 exit 2"
assert_contains "$OUT" "FAIL [php] $P is not in the coverage data" "[php] 데이터에 없는 경계 파일"
# 파생이 핀과 다르다(같은 오라클 — 파생이 조용히 좁아지면 미도달도 조용히 준다).
ufresh
sed -i "s#\"$K\"#\"$K\", \"kotlin/src/main/kotlin/kc/auth/Config.kt\"#" "$T/scripts/integration-coverage.json"
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 파생이 핀과 다르면 exit 2"
assert_contains "$OUT" "FAIL [kotlin] the derived boundary differs from the pin in scripts/integration-coverage.json" "[kotlin] 파생 ≠ 핀"
# 장부의 꼴을 모른다 — JSON 아님 · 없음 · 모르는 언어 · 언어 객체 없음 · kotlin 항목에 branches 없음 · php 항목에 branches.
ufresh
printf 'not json\n' > "$L"
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] JSON 이 아니면 exit 2"
assert_contains "$OUT" "FAIL [-] scripts/unit-unreached.json is missing or not JSON" "[ledger] JSON 아님"
ufresh
rm "$L"
run unit-report php "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] 장부가 없으면 exit 2"
ufresh
printf '{ "kotlin": {}, "php": {}, "scala": {} }\n' > "$L"
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] 재지 않는 언어는 exit 2"
assert_contains "$OUT" "FAIL [-] scripts/unit-unreached.json names scala, which the unit-unreached ledger does not measure" "[ledger] 모르는 언어"
ufresh
printf '{ "kotlin": {} }\n' > "$L"
run unit-report php "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] 언어 객체가 없으면 exit 2(빈 장부는 {} 다)"
assert_contains "$OUT" "FAIL [php] scripts/unit-unreached.json has no php object" "[ledger] php 객체 없음"
ufresh
sed -i '/AuthClient\.exchange"/,/}/ { /"branches": 1,/d }' "$L"
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] kotlin 항목에 branches 가 없으면 exit 2"
assert_contains "$OUT" "must be { branches, lines, why }" "[ledger] kotlin 꼴"
ufresh
sed -i '/AuthClient::exchange"/,/}/ s#"lines": 1,#"lines": 1, "branches": 0,#' "$L"
run unit-report php "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] php 항목에 branches 가 있으면 exit 2(php 는 줄만 센다)"
assert_contains "$OUT" "must be { lines, why }" "[ledger] php 꼴"
ufresh
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[cli] 재지 않는 언어는 usage(exit 2)"
assert_contains "$OUT" "the unit-unreached ledger measures kotlin · php — got java" "[cli] usage 문구"

# ── (4) check — 데이터 없이 꼴 · 경계 · why(통합 픽스처 트리 — 아홉 언어) ──────────────────────────────
fresh
run check "$T"
assert_eq 0 "$RC" "[check] 건강한 장부는 exit 0 — 출력: $OUT"
assert_line "$OUT" "[kotlin] unit-unreached: 1 entry (integration 1)" "[check] kotlin 장부"
assert_line "$OUT" "[php] unit-unreached: 1 entry (open-admin 1)" "[check] php 장부"
fresh
sed -i 's#"why": "open-admin"#"why": "closed-item"#' "$T/scripts/unit-unreached.json"
run check "$T"
assert_eq 1 "$RC" "[check] 닫힌 항목 id 는 데이터 없이도 잡힌다 — exit 1"
assert_contains "$OUT" "DRIFT [php] php/src/AuthClient.php:AuthClient::logoutUrl: why \"closed-item\" is neither" "[check] 닫힌 id"
fresh
sed -i 's#kc/auth/AuthClient.kt:AuthClient.unused#kc/auth/Config.kt:Config.unused#' "$T/scripts/unit-unreached.json"
run check "$T"
assert_eq 1 "$RC" "[check] 경계 밖 파일의 항목은 exit 1"
assert_contains "$OUT" "DRIFT [kotlin] scripts/unit-unreached.json: entry kotlin/src/main/kotlin/kc/auth/Config.kt:Config.unused names a file outside the boundary" "[check] 경계 밖"
fresh
printf '{ "kotlin": {} }\n' > "$T/scripts/unit-unreached.json"
run check "$T"
assert_eq 2 "$RC" "[check] 언어 객체가 없으면 exit 2"
fresh
rm "$T/scripts/unit-unreached.json"
run check "$T"
assert_eq 2 "$RC" "[check] 장부가 없으면 exit 2"
assert_contains "$OUT" "FAIL [-] scripts/unit-unreached.json is missing or not JSON" "[check] 장부 없음"

assert_report
