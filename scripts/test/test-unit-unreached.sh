#!/usr/bin/env sh
# 단위 미도달 장부(`scripts/integration-coverage.mjs` 의 `unit-report` · `check` — kotlin · php · dotnet, 등록부
# coverage-exclusion-hides-untested-branches · coverage-omit-hides-security-paths) 자가테스트 — **종료코드**를 단언한다(0 측정 = 장부 ·
# 1 DRIFT · 2 FAIL — 뜻은 그 도구 머리가 소유한다). 문구는 무엇을 잡았는지 가리는 데만 쓴다.
#
# ⚠️ **커밋된 픽스처만 쓴다** — Docker · JDK · Gradle · PHP · .NET 이 필요 없다(`unit-report` 는 데이터를 읽기만 한다). 데이터는 실제
# 도구가 낸 것이다(kotlin · php 2026-11-18 · dotnet 2026-11-19):
#   fixtures/unit-unreached/data/kotlin.unit.xml · kotlin.unit.javap.txt   도구의 `unit kotlin`(JDK 21.0.8 · kotlin 2.4.21 · Kover 0.9.11 ·
#       JaCoCo 0.8.16) — 임시 루트에 tree 사본 + 실제 kotlin/ 의 Gradle 래퍼 + java/pom.xml(JaCoCo 판을 거기서 읽는다). 세션 id 를
#       HOST-00000000 으로, javap 의 줄끝을 LF 로 · `Classfile` 의 생성 루트를 지워 `kotlin/` 부터로만 바꿨다
#   fixtures/unit-unreached/data/php.unit/   도구의 `unit php`(PHP 8.3.36 · PHPUnit 12.5.33 · php-code-coverage 12.5.7 · Xdebug 3.5.3) —
#       임시 루트에 tree 사본 + 실제 php/vendor 사본. index.xml 의 `<project source>` 생성 루트만 `@ROOT@` 로 바꿨다
#   fixtures/unit-unreached/data/dotnet.unit.json · dotnet.unit.trx   도구의 `unit dotnet`(.NET SDK 10.0.102 → net8.0 · coverlet.collector
#       10.1.0) — 임시 루트에 tree 사본. 생성 루트를 `@ROOT@`(trx 의 소문자 `storage` 는 `@root@`)로, 기계 · 사용자 이름을 HOST · USER 로,
#       trx 의 줄끝을 LF 로 바꿨다(치환마다 되돌린 바이트가 원본과 같다)
# 단위 구동(tree/kotlin/src/test · tree/php/tests/Unit · tree/dotnet/tests/Kc.Tests)은 빈 code · null · 빈 user · 빈 문자열을 안 보내고
# unused · logoutUrl · LogoutUrl · Describe() 를 안 부른다. dotnet 의 Guarded 는 필터가 거절하는 예외만 받고 Describe(int) 는 양수로만
# 불린다 — 통합 시험(DriveIT)은 단위 실행의 필터(Category!=Integration)가 거른다. 숫자를 바꾸려면 구동을 고쳐 **도구로 재생성**할 것 —
# 데이터를 손으로 고치지 않는다(아래 음성 대조군만 고친다).
# `check` 의 장부 판정(데이터 없이 — 꼴 · 경계 · why)은 통합 커버리지 픽스처 트리(`ic-fixture.sh` 의 fresh)에서 잰다 — check 는 아홉
# 언어를 다 보므로 kotlin · php · dotnet 뿐인 이 트리로는 못 잰다.
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
N=dotnet/src/Kc/AuthClient.cs
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
  # coverlet 의 문서 키 · trx 의 테스트 어셈블리 경로도 절대 경로다(통합 픽스처의 dotnet_data 와 같은 치환).
  sed "s#@ROOT@#$_r#g" "$UFIX/data/dotnet.unit.json" > "$D/dotnet.unit.json"
  sed "s#@ROOT@#$_r#g; s#@root@#$_r#g" "$UFIX/data/dotnet.unit.trx" > "$D/dotnet.unit.trx"
  kmark 0
  pmark 0
  dmark 0
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
# `unit dotnet` 의 기록 — 종료코드 · 데이터와 trx 의 sha1 · 경계 파일의 지금 sha1(coverlet 데이터에는 소스 해시가 없다).
dmark() { # exit
  printf '{"run":"dotnet","suite":"unit","exit":%s,"data_sha1":"%s","trx_sha1":"%s","files":{"%s":"%s"}}\n' "$1" \
    "$(sha1sum "$D/dotnet.unit.json" | cut -d' ' -f1)" "$(sha1sum "$D/dotnet.unit.trx" | cut -d' ' -f1)" "$N" "$(sha1sum "$T/$N" | cut -d' ' -f1)" > "$D/dotnet.unit.run.json"
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

run unit-report dotnet "$T" --out "$D"
assert_eq 0 "$RC" "[dotnet] 측정이 장부와 같으면 exit 0 — 출력: $OUT"
assert_contains "$OUT" "/dotnet.unit.json (.NET 8.0.23 · coverlet json · 1 unit test)" "[dotnet] 데이터 · 런타임 · 단위 시험 수를 찍는다"
assert_line "$OUT" "  UNREACHED $N:20 AuthClient.Exchange · 1 line · 1 branch · defensive: the drive never sends an empty code" "[dotnet] 제 줄의 실패 갈래 — 놓친 줄 · 놓친 가지"
assert_line "$OUT" "  UNREACHED $N:28 AuthClient.Pick · 0 lines · 1 branch · open-gap" "[dotnet] 행복 경로가 도는 줄의 실패 갈래(?? throw)는 가지로 보인다(php 의 알려진 틈과 달리) · why 가 열린 항목 id"
assert_line "$OUT" "  UNREACHED $N:31 AuthClient.Lengths · 0 lines · 1 branch · unreachable: the branch sits in Lengths' lambda — the key is the source member" "[dotnet] 람다 안의 놓친 가지는 소스 멤버의 수다"
assert_not_contains "$OUT" "b__" "[dotnet] 람다의 합성 이름(<Lengths>b__…)이 키로 새지 않는다"
# 멈추지 않는 await(완료된 Task)의 IsCompleted 검사가 가지였다면 멈추는 쪽이 안 돌아 2 branches 다 — coverlet 은 Task · ValueTask 의 그
# 검사를 싣지 않는다(도구 머리). 이 줄이 깨지면 coverlet 이 그 검사를 싣게 된 것이다 — 머리 주석과 장부를 함께 고칠 때다.
assert_line "$OUT" "  UNREACHED $N:38 AuthClient.TokenAsync · 1 line · 1 branch · integration: the state machine's line and branch fold into the method" "[dotnet] 상태 기계의 줄 · 가지는 메서드의 것 — 멈추지 않는 await 는 가지를 더하지 않는다"
assert_not_contains "$OUT" "MoveNext" "[dotnet] 상태 기계의 이름을 내지 않는다"
# ⚠️ 알려진 틈을 고정한다 — catch 필터(`when`)의 결정은 가지로 안 실린다: 필터가 거절한 쪽은 catch 몸통의 줄로만 보인다(도구 머리 주석).
assert_line "$OUT" "  UNREACHED $N:52 AuthClient.Guarded · 1 line · 0 branches · integration: the catch filter declined — only the body's line shows" "[dotnet] 필터의 결정은 가지가 아니다 — 알려진 틈"
assert_line "$OUT" "  UNREACHED $N:61 AuthClient.Describe() · 1 line · 0 branches · integration: the drive never calls this overload" "[dotnet] 오버로드는 시그니처로 가른다"
assert_line "$OUT" "  UNREACHED $N:63 AuthClient.Describe(System.Int32) · 0 lines · 1 branch · defensive: the drive passes a positive depth only" "[dotnet] 가지도 그 시그니처의 것이다"
assert_line "$OUT" "  UNREACHED $N:66 AuthClient.LogoutUrl · 1 line · 0 branches · integration: the drive never calls it — DriveIT does, outside the unit run" "[dotnet] 통합 시험(DriveIT)만 부르는 메서드 — 단위 실행의 필터가 그 시험을 거른다"
assert_not_contains "$OUT" "get_Realm" "[dotnet] 다 닿는 멤버는 목록에 없다"
assert_not_contains "$OUT" "Config" "[dotnet] 경계 밖 파일은 목록에 없다"
assert_line "$OUT" "unit-unreached [dotnet]: OK — 8 functions with code the unit suite never reaches (5 lines · 5 branches), each recorded in scripts/unit-unreached.json" "[dotnet] 요약"

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
ufresh
sed -i '/Kc.AuthClient::get_Realm()/,/"15": 1/ s#"15": 1#"15": 0#' "$D/dotnet.unit.json"
dmark 0
run unit-report dotnet "$T" --out "$D"
assert_eq 1 "$RC" "[dotnet] 장부에 없는 미도달 함수는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [dotnet] unrecorded unreached code $N:AuthClient.get_Realm — the unit suite never reaches 1 line · 0 branches of it: test that code, or record why in scripts/unit-unreached.json" "[dotnet] 새 미도달(속성 접근자는 get_ 이름이다 — 통합 소유자와 같은 키)"
# 줄은 그대로인데 가지 하나가 새로 안 돈다 — 행복 경로가 도는 줄의 실패 갈래가 생긴 꼴(줄만 세면 못 본다). Exchange 의 도는 쪽을 0 으로.
ufresh
sed -i '/"EndOffset": 19,/,/"Hits": 1/ s#"Hits": 1#"Hits": 0#' "$D/dotnet.unit.json"
dmark 0
run unit-report dotnet "$T" --out "$D"
assert_eq 1 "$RC" "[dotnet] 줄 수가 같아도 놓친 가지가 늘면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [dotnet] $N:AuthClient.Exchange: the unit run leaves 1 line · 2 branches unreached, scripts/unit-unreached.json records 1 line · 1 branch — test what the unit suite does not reach, or record why and correct the counts" "[dotnet] 가지만 바뀐 수"

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
ufresh
sed -i '/AuthClient\.Lengths"/,/},/d' "$L"
run unit-report dotnet "$T" --out "$D"
assert_eq 1 "$RC" "[dotnet] 람다 안의 놓친 가지가 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [dotnet] unrecorded unreached code $N:AuthClient.Lengths — the unit suite never reaches 0 lines · 1 branch of it" "[dotnet] 람다의 가지 — 소스 멤버 키"

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
ufresh
sed -i '/AuthClient\.Exchange"/,/}/ s#"branches": 1,#"branches": 2,#' "$L"
run unit-report dotnet "$T" --out "$D"
assert_eq 1 "$RC" "[dotnet] 수가 다르면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [dotnet] $N:AuthClient.Exchange: the unit run leaves 1 line · 1 branch unreached, scripts/unit-unreached.json records 1 line · 2 branches — the unit suite reaches more of it now: lower the counts" "[dotnet] 바뀐 수 — 장부보다 덜 놓쳤다"

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
ufresh
sed -i "s#\"dotnet\": {#\"dotnet\": {\n    \"$N:AuthClient.Gone\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: renamed\" },\n    \"dotnet/src/Kc/Config.cs:Config.Valid\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: outside\" },#" "$L"
run unit-report dotnet "$T" --out "$D"
assert_eq 1 "$RC" "[dotnet] 낡은 항목은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [dotnet] stale entry $N:AuthClient.Gone — the data of $N has no such function (renamed or removed?)" "[dotnet] 없는 함수의 항목"
assert_contains "$OUT" "DRIFT [dotnet] scripts/unit-unreached.json: entry dotnet/src/Kc/Config.cs:Config.Valid names a file outside the boundary derived from dotnet/coverlet.runsettings:10" "[dotnet] 경계 밖 파일의 항목"
# 다 닿게 된 함수 — Describe(int) 의 안 돈 가지를 돈 것으로(가지만 놓친 함수도 가지가 다 돌면 낡은 항목이다).
ufresh
sed -i '/Describe(System.Int32)/,/"Hits": 0/ s#"Hits": 0#"Hits": 1#' "$D/dotnet.unit.json"
dmark 0
run unit-report dotnet "$T" --out "$D"
assert_eq 1 "$RC" "[dotnet] 다 닿는 함수의 항목은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [dotnet] stale entry $N:AuthClient.Describe(System.Int32) — the unit run reaches all of it now; drop the entry" "[dotnet] 다 닿는 함수의 항목"

# why — 닫힌 항목 · 들여쓴 하위 불릿(항목이 아니다) · 모르는 id · 까닭 머리만 있고 말이 없다.
ufresh
sed -i 's#"why": "open-gap"#"why": "closed-gap"#' "$L"
run unit-report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[kotlin] 닫힌 등록부 항목은 why 가 아니다 — exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [kotlin] $K:AuthClient.elvis: why \"closed-gap\" is neither unreachable: · defensive: · integration: with a reason nor an open item of docs/superpowers/plans/remaining-work.md" "[kotlin] 닫힌 id"
run unit-report php "$T" --out "$D"
assert_eq 1 "$RC" "[php] 닫힌 등록부 항목은 why 가 아니다 — exit 1"
assert_contains "$OUT" "DRIFT [php] $P:AuthClient::apply: why \"closed-gap\"" "[php] 닫힌 id"
run unit-report dotnet "$T" --out "$D"
assert_eq 1 "$RC" "[dotnet] 닫힌 등록부 항목은 why 가 아니다 — exit 1"
assert_contains "$OUT" "DRIFT [dotnet] $N:AuthClient.Pick: why \"closed-gap\"" "[dotnet] 닫힌 id"
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
# dotnet — 같은 무결성 판정(데이터 · 다른 바이트 · 단위 기록 · 단위 스위트 · 실패한 실행 · 데이터에 없는 경계 파일)과 가지의 꼴.
ufresh
rm "$D/dotnet.unit.json"
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 데이터가 없으면 exit 2"
assert_contains "$OUT" "run the unit suite first (node scripts/integration-coverage.mjs unit dotnet)" "[dotnet] 다시 돌릴 명령"
ufresh
printf '\n// changed after the run\n' >> "$T/$N"
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 다른 바이트의 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] $N: the data was taken from other bytes" "[dotnet] 다른 바이트"
ufresh
sed -i 's#"suite":"unit",##' "$D/dotnet.unit.run.json"
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 통합 실행의 기록은 exit 2"
assert_contains "$OUT" "FAIL [dotnet] no record that \`unit dotnet\` wrote this data" "[dotnet] 단위 기록 아님"
# 단위 실행에 통합 스위트의 시험이 섞였다 · 정의에 잇지 못하는 결과(어느 스위트인지 모른다 — 섞인 것으로 본다).
ufresh
sed -i 's#className="Kc.Tests.DriveTests"#className="Kc.Tests.Integration.DriveIT"#' "$D/dotnet.unit.trx"
dmark 0
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 통합 스위트의 시험이 든 단위 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] the run included tests of the integration suite or tests it cannot place (Kc.Tests.DriveTests.Drive) — the data would not be unit-only" "[dotnet] 통합 섞임"
ufresh
sed -i '/<TestMethod /d' "$D/dotnet.unit.trx"
dmark 0
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 정의에 잇지 못하는 결과는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] the run included tests of the integration suite or tests it cannot place (Kc.Tests.DriveTests.Drive)" "[dotnet] 못 잇는 결과"
ufresh
dmark 1
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 실패한 실행의 데이터는 exit 2"
assert_contains "$OUT" "FAIL [dotnet] the run that wrote this data exited 1" "[dotnet] 실패한 실행"
ufresh
sed -i 's#outcome="Passed"#outcome="Failed"#' "$D/dotnet.unit.trx"
dmark 0
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 실패한 단위 시험이 있으면 exit 2"
assert_contains "$OUT" "FAIL [dotnet] 1 of 1 tests in the run did not pass" "[dotnet] 실패한 시험"
ufresh
sed -i 's#AuthClient\.cs": {#Gone.cs": {#' "$D/dotnet.unit.json"
dmark 0
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 경계 파일이 데이터에 없으면 exit 2"
assert_contains "$OUT" "FAIL [dotnet] $N is not in the coverage data" "[dotnet] 데이터에 없는 경계 파일"
# 가지의 꼴 — 배열이 아니다 · 음수 횟수 · 파일 밖 줄(줄의 꼴 판정과 같은 까닭: 못 읽는 수로 대조하지 않는다).
ufresh
sed -i 's#"Branches": \[\]#"Branches": {}#' "$D/dotnet.unit.json"
dmark 0
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 배열 아닌 Branches 는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] $N: cannot read the branch counts of System.String Kc.AuthClient::get_Realm()" "[dotnet] Branches 꼴"
ufresh
sed -i 's#"Hits": 0#"Hits": -1#' "$D/dotnet.unit.json"
dmark 0
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 음수 가지 횟수는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] $N: cannot read the branch counts of System.String Kc.AuthClient::Exchange(System.String)" "[dotnet] 못 읽는 가지 횟수"
ufresh
sed -i 's#"Line": 28,#"Line": 9999,#' "$D/dotnet.unit.json"
dmark 0
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 파일 밖 줄의 가지는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] $N: AuthClient.Pick counts a branch on line 9999, past the" "[dotnet] 파일 밖 가지"
ufresh
sed -i '/AuthClient\.Exchange"/,/}/ { /"branches": 1,/d }' "$L"
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] dotnet 항목에 branches 가 없으면 exit 2"
assert_contains "$OUT" "FAIL [dotnet] scripts/unit-unreached.json: dotnet[\"$N:AuthClient.Exchange\"] must be { branches, lines, why }" "[ledger] dotnet 꼴"
ufresh
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[cli] 재지 않는 언어는 usage(exit 2)"
assert_contains "$OUT" "the unit-unreached ledger measures kotlin · php · dotnet — got java" "[cli] usage 문구"

# ── (4) check — 데이터 없이 꼴 · 경계 · why(통합 픽스처 트리 — 아홉 언어) ──────────────────────────────
fresh
run check "$T"
assert_eq 0 "$RC" "[check] 건강한 장부는 exit 0 — 출력: $OUT"
assert_line "$OUT" "[kotlin] unit-unreached: 1 entry (integration 1)" "[check] kotlin 장부"
assert_line "$OUT" "[php] unit-unreached: 1 entry (open-admin 1)" "[check] php 장부"
assert_line "$OUT" "[dotnet] unit-unreached: 1 entry (defensive 1)" "[check] dotnet 장부"
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
