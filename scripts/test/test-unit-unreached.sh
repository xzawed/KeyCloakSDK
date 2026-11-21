#!/usr/bin/env sh
# 단위 미도달 장부(`scripts/integration-coverage.mjs` 의 `unit-report` · `check` — kotlin · php · dotnet · java · ruby · go, 등록부
# coverage-exclusion-hides-untested-branches · coverage-omit-hides-security-paths) 자가테스트 — **종료코드**를 단언한다(0 측정 = 장부 ·
# 1 DRIFT · 2 FAIL — 뜻은 그 도구 머리가 소유한다). 문구는 무엇을 잡았는지 가리는 데만 쓴다.
#
# ⚠️ **커밋된 픽스처만 쓴다** — Docker · JDK · Gradle · Maven · PHP · .NET · Ruby · Go 가 필요 없다(`unit-report` 는 데이터를 읽기만 한다). 데이터는
# 실제 도구가 낸 것이다(php 2026-11-18 · dotnet 2026-11-19 · java 2026-11-19 · ruby · kotlin · go 2026-11-21):
#   fixtures/unit-unreached/data/kotlin.unit.xml · kotlin.unit.javap.txt   도구의 `unit kotlin`(JDK 21.0.8 · kotlin 2.4.21 · Kover 0.9.11 ·
#       JaCoCo 0.8.16) — 임시 루트에 tree 사본 + 실제 kotlin/ 의 Gradle 래퍼(JaCoCo 판은 tree 의 java/pom.xml 에서 읽는다). 세션 id 를
#       HOST-00000000 으로, javap 의 줄끝을 LF 로 · `Classfile` 의 생성 루트를 지워 `kotlin/` 부터로만 바꿨다(치환마다 되돌린 바이트가
#       원본과 같다). 2026-11-21 에 꼬리 호출 AuthClientTail(파일 끝)을 더해 다시 냈다 — AuthClient · Config 의 메서드와 34 줄까지의 줄
#       데이터는 바이트째 같았다
#   fixtures/unit-unreached/data/php.unit/   도구의 `unit php`(PHP 8.3.36 · PHPUnit 12.5.33 · php-code-coverage 12.5.7 · Xdebug 3.5.3) —
#       임시 루트에 tree 사본 + 실제 php/vendor 사본. index.xml 의 `<project source>` 생성 루트만 `@ROOT@` 로 바꿨다
#   fixtures/unit-unreached/data/dotnet.unit.json · dotnet.unit.trx   도구의 `unit dotnet`(.NET SDK 10.0.102 → net8.0 · coverlet.collector
#       10.1.0) — 임시 루트에 tree 사본. 생성 루트를 `@ROOT@`(trx 의 소문자 `storage` 는 `@root@`)로, 기계 · 사용자 이름을 HOST · USER 로,
#       trx 의 줄끝을 LF 로 바꿨다(치환마다 되돌린 바이트가 원본과 같다)
#   fixtures/unit-unreached/data/java.unit.xml · java.unit.javap.txt   도구의 `unit java`(JDK 21.0.8 · Maven 3.9.9 · JaCoCo 0.8.16) — 임시
#       루트에 tree 사본. 세션 id 를 HOST-00000000 으로, javap 의 줄끝을 LF 로 · `Classfile` 의 생성 루트를 지워 `java/` 부터로만 바꿨다
#       (치환마다 되돌린 바이트가 원본과 같다)
#   fixtures/unit-unreached/data/ruby.unit.json   도구의 `unit ruby`(ruby 3.4.10 · SimpleCov 1.2.0 · 덤프 형식 /2 — 가지 포함) — 임시
#       루트에 tree 사본, 번들은 실제 레인의 것(`BUNDLE_GEMFILE=ruby/Gemfile`). 덤프의 root 와 파일 키는 절대 경로다 — 생성 루트만 `@ROOT@` 로
#       바꿨다(되돌린 바이트가 원본과 같다)
#   fixtures/unit-unreached/data/go.unit.cover   `unit go` 가 도는 명령 `go test -count=1 -coverprofile=… ./...`(go1.26.4 · 태그 없음) —
#       임시 루트에 tree/go 사본. 프로필의 경로는 모듈 경로(example.com/fixture/go/…)라 치환이 없다
# 단위 구동(tree/kotlin/src/test · tree/php/tests/Unit · tree/dotnet/tests/Kc.Tests · tree/java/kc-auth/src/test · tree/ruby/spec/unit)은
# 빈 code · null · 빈 user · 빈 문자열 · 빈 값 · nil 을 안 보내고 unused · logoutUrl · LogoutUrl · logout_url · Describe() · describe ·
# token(String, int) 를 안 부른다. dotnet 의 Guarded 는 필터가 거절하는 예외만 받고 Describe(int) 는 양수로만 불린다 — 통합 시험(DriveIT)은
# 단위 실행의 필터(Category!=Integration)가 거른다. java 의 DriveIT 는 failsafe 의 것이라 단위 실행(test 단계)이 안 돌고, QuickStart 는
# jacoco.skip 모듈(단위 시험이 없다)의 것이다. ruby 의 구동은 없는 키 · 거짓 fallback · nil claims 를 안 보내고 apply 를 빈 배열로만 불러
# 블록 몸통이 안 돌며(token 은 삼항 두 쪽을 다 탄다), 통합 스펙(spec/integration · `:integration`)은 단위 실행의 spec_helper 필터가 거른다.
# kotlin 의 구동은 꼬리 호출 AuthClientTail.update 를 멈추지 않는 adminCall 로 불러 닫는 중괄호 줄까지 돈다(아래 (5)).
# go 의 구동(tree/go/drive_test.go)은 빈 code 를 안 보내고 Pick 에 늘 찾는 값만 주며 Valid 의 && 두 쪽을 다 참으로 지나고 String ·
# LogoutURL 을 안 부른다 — LogoutURL 을 부르는 통합 시험(drive_integration_test.go)은 `//go:build integration` 뒤라 태그 없는 단위
# 실행이 컴파일하지 않는다. 패키지 수준 함수 리터럴 hook 은 구동이 부른다.
# 숫자를 바꾸려면 구동을 고쳐 **도구로 재생성**할 것 — 데이터를 손으로 고치지 않는다(아래 음성 대조군만 고친다).
# `check` 의 장부 판정(데이터 없이 — 꼴 · 경계 · why)은 통합 커버리지 픽스처 트리(`ic-fixture.sh` 의 fresh)에서 잰다 — check 는 아홉
# 언어를 다 보므로 kotlin · php · dotnet · java · ruby · go 뿐인 이 트리로는 못 잰다.
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
J=java/kc-auth/src/main/java/kc/auth/AuthClient.java
Q=java/kc-examples/src/main/java/kc/examples/QuickStart.java
R=ruby/lib/kc/auth_client.rb
G=go/auth_client.go
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
  # JaCoCo XML · javap 출력에는 절대 경로가 없다(javap 의 `Classfile` 은 생성 때 `java/` 부터로 바꿨다 — 리더는 그 줄의 경로를 안 읽는다).
  cp "$UFIX/data/java.unit.xml" "$UFIX/data/java.unit.javap.txt" "$D/"
  # ruby 덤프의 root 와 파일 키도 절대 경로다(통합 픽스처의 ruby_data 와 같은 치환).
  sed "s#@ROOT@#$_r#g" "$UFIX/data/ruby.unit.json" > "$D/ruby.unit.json"
  # go 의 커버 프로필에는 절대 경로가 없다(모듈 경로다).
  cp "$UFIX/data/go.unit.cover" "$D/"
  kmark 0
  pmark 0
  dmark 0
  jmark 0
  rmark 0
  gmark 0
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
# `unit java` 의 기록 — 데이터 · javap 출력 · 경계 파일 둘(jacoco.skip 예제 포함)의 지금 sha1. 인자: 종료코드 [시험 수] [실패 수]
# [failsafe 보고 수](kmark 와 같은 꼴 — 통합 보고 수가 failsafe 의 TEST-*.xml 이다).
jmark() { # exit [completed] [failures] [integration]
  printf '{"run":"java","suite":"unit","exit":%s,"jacoco":"0.8.16","data_sha1":"%s","javap_sha1":"%s","exec_sha1":"0","tests":{"completed":%s,"failures":%s,"errors":0,"skipped":0},"integration":%s,"files":{"%s":"%s","%s":"%s"}}\n' \
    "$1" "$(sha1sum "$D/java.unit.xml" | cut -d' ' -f1)" "$(sha1sum "$D/java.unit.javap.txt" | cut -d' ' -f1)" \
    "${2:-1}" "${3:-0}" "${4:-0}" "$J" "$(sha1sum "$T/$J" | cut -d' ' -f1)" "$Q" "$(sha1sum "$T/$Q" | cut -d' ' -f1)" > "$D/java.unit.run.json"
}
# `unit ruby` 의 기록 — 종료코드 · 지금 덤프의 sha1(경계 파일의 sha1 은 덤프 안에 있다 — 통합 픽스처의 ruby_mark 와 같은 꼴에 suite).
rmark() { # exit
  printf '{"run":"ruby","suite":"unit","exit":%s,"dump_sha1":"%s"}\n' "$1" "$(sha1sum "$D/ruby.unit.json" | cut -d' ' -f1)" > "$D/ruby.unit.run.json"
}
# `unit go` 의 기록 — 종료코드 · 지금 프로필의 sha1 · 경계 파일의 지금 sha1(커버 프로필에는 소스 해시가 없다 — dmark 와 같은 꼴).
gmark() { # exit
  printf '{"run":"go","suite":"unit","exit":%s,"profile_sha1":"%s","files":{"%s":"%s"}}\n' "$1" \
    "$(sha1sum "$D/go.unit.cover" | cut -d' ' -f1)" "$G" "$(sha1sum "$T/$G" | cut -d' ' -f1)" > "$D/go.unit.run.json"
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

run unit-report java "$T" --out "$D"
assert_eq 0 "$RC" "[java] 측정이 장부와 같으면 exit 0 — 출력: $OUT"
assert_contains "$OUT" "/java.unit.xml (JaCoCo 0.8.16 · 1 session · 1 unit test)" "[java] 데이터 · JaCoCo 판 · 세션 · 단위 시험 수를 찍는다"
assert_line "$OUT" "  UNREACHED $J:23 AuthClient.exchange · 1 line · 1 branch · defensive: the drive never sends a blank code" "[java] 제 줄의 실패 갈래 — 놓친 줄 · 놓친 가지"
assert_line "$OUT" "  UNREACHED $J:31 AuthClient.pick · 0 lines · 1 branch · open-gap" "[java] 행복 경로가 도는 줄의 실패 갈래(조건식)도 가지로 센다 · why 가 열린 항목 id"
assert_line "$OUT" "  UNREACHED $J:36 AuthClient.later · 0 lines · 1 branch · unreachable: the branch sits in later's lambda — the key is the source method" "[java] 람다 안의 놓친 가지는 소스 메서드 later 의 수다"
assert_not_contains "$OUT" 'lambda$' "[java] 람다의 합성 이름(lambda\$later\$0)이 키로 새지 않는다"
assert_line "$OUT" "  UNREACHED $J:41 AuthClient.sorted · 1 line · 1 branch · unreachable: the line and branch sit in the anonymous Comparator — they fold into sorted" "[java] 익명 클래스의 놓친 줄 · 가지는 감싼 메서드 sorted 의 수다"
assert_not_contains "$OUT" 'AuthClient$1' "[java] 익명 클래스의 이름(AuthClient\$1)이 키로 새지 않는다"
assert_line "$OUT" "  UNREACHED $J:61 AuthClient.token(String, int) · 1 line · 0 branches · integration: the drive never calls this overload" "[java] 오버로드는 매개변수로 가른다"
assert_not_contains "$OUT" "AuthClient.token(String) ·" "[java] 다 닿는 오버로드는 목록에 없다"
assert_line "$OUT" "  UNREACHED $J:66 AuthClient.logoutUrl · 1 line · 0 branches · integration: the drive never calls it — DriveIT does, outside the unit run" "[java] 통합 시험(DriveIT)만 부르는 메서드 — 단위 실행의 test 단계는 failsafe 앞에서 멈춘다"
assert_line "$OUT" "  UNREACHED $J:82 AuthClient.Token.value · 0 lines · 1 branch · defensive: the drive never asks for an empty value — a named nested class keys as its own type" "[java] 이름 붙은 중첩 클래스는 제 타입이다"
assert_line "$OUT" "  UNREACHED $Q:8 QuickStart.main · 2 lines · 0 branches · integration: a jacoco.skip module — no unit test and no agent there" "[java] jacoco.skip 모듈의 파일(파생의 forced)은 줄 전부를 놓친다"
assert_line "$OUT" "  UNREACHED $Q:12 QuickStart.env · 2 lines · 2 branches · integration: main's helper — the same as main" "[java] 그 파일의 가지도 센다"
assert_not_contains "$OUT" "AuthClient.realm" "[java] 다 닿는 메서드는 목록에 없다"
assert_not_contains "$OUT" "Config" "[java] 경계 밖 파일은 목록에 없다"
assert_line "$OUT" "unit-unreached [java]: OK — 9 functions with code the unit suite never reaches (8 lines · 7 branches), each recorded in scripts/unit-unreached.json" "[java] 요약"

run unit-report ruby "$T" --out "$D"
assert_eq 0 "$RC" "[ruby] 측정이 장부와 같으면 exit 0 — 출력: $OUT"
assert_contains "$OUT" "/ruby.unit.json (ruby 3.4.10 · Coverage lines · methods · branches · 1 unit example)" "[ruby] 덤프 · ruby 판 · 단위 예제 수를 찍는다"
assert_line "$OUT" "  UNREACHED $R:19 AuthClient#exchange · 1 line · 1 branch · defensive: the drive never sends an empty code" "[ruby] 제 줄의 실패 갈래 — 놓친 줄 · 놓친 가지"
assert_line "$OUT" "  UNREACHED $R:28 AuthClient#pick · 0 lines · 1 branch · open-gap" "[ruby] 행복 경로가 도는 줄의 실패 갈래(후치 unless)도 가지로 센다 · why 가 열린 항목 id"
assert_line "$OUT" "  UNREACHED $R:40 AuthClient#apply · 1 line · 2 branches · unreachable: the line and both arms sit in apply's block — the key is the source method" "[ruby] 블록의 안 돈 줄 · 안 탄 갈래는 감싼 메서드의 수다"
assert_line "$OUT" "  UNREACHED $R:47 AuthClient#realm_of · 0 lines · 1 branch · defensive: the drive never passes nil claims — the &. nil arm" "[ruby] &. 의 nil 쪽도 갈래다 — 한 줄 메서드의 def 줄 위 자리도 그 메서드의 것"
assert_line "$OUT" "  UNREACHED $R:50 AuthClient#describe · 1 line · 0 branches · integration: a one-line method the drive never calls — its line ran at require, its call count is 0" "[ruby] 한 줄 메서드 — 적재 때 돈 줄이 아니라 호출 횟수로 센다"
assert_line "$OUT" "  UNREACHED $R:53 AuthClient#logout_url · 1 line · 0 branches · integration: the drive never calls it — the integration spec does, outside the unit run" "[ruby] 통합 스펙만 부르는 메서드 — 단위 실행의 spec_helper 필터가 그 스펙을 거른다"
assert_line "$OUT" "  UNREACHED $R:58 AuthClient.parse · 1 line · 1 branch · defensive: the drive never sends nil — a singleton method keys with a dot" "[ruby] 특이 메서드는 「.」"
# ⚠️ 알려진 틈을 고정한다 — `||` · `&&` 는 Ruby 의 Coverage 가 가지로 안 싣는다: 행복 경로가 도는 줄의 `|| raise` 는 줄로도 가지로도 안
# 보인다(도구 머리 주석). 이 단언이 깨지면 VM 이 그것을 가지로 싣게 된 것이다 — 머리 주석과 장부를 함께 고칠 때다.
assert_not_contains "$OUT" "AuthClient#fallback" "[ruby] 같은 줄의 || raise 는 가지가 아니다 — 알려진 틈"
assert_not_contains "$OUT" "AuthClient#realm ·" "[ruby] 불린 한 줄 메서드는 목록에 없다"
assert_not_contains "$OUT" "AuthClient#token ·" "[ruby] 삼항 두 쪽을 다 탄 메서드는 목록에 없다"
assert_not_contains "$OUT" "Config" "[ruby] 경계 밖 파일은 목록에 없다"
assert_line "$OUT" "unit-unreached [ruby]: OK — 7 functions with code the unit suite never reaches (5 lines · 6 branches), each recorded in scripts/unit-unreached.json" "[ruby] 요약"

run unit-report go "$T" --out "$D"
assert_eq 0 "$RC" "[go] 측정이 장부와 같으면 exit 0 — 출력: $OUT"
assert_contains "$OUT" "/go.unit.cover (mode set)" "[go] 프로필 · 모드를 찍는다"
assert_line "$OUT" "  UNREACHED $G:15 AuthClient.Exchange · 1 statement · defensive: the drive never sends an empty code" "[go] 제 블록의 실패 갈래 — 안 돈 문장(줄 · 가지가 아니다)"
assert_line "$OUT" "  UNREACHED $G:23 AuthClient.Pick · 1 statement · unreachable: the miss sits in Pick's function literal — the key is the declared function" "[go] 함수 리터럴의 안 돈 문장은 감싼 함수의 수다"
assert_line "$OUT" "  UNREACHED $G:41 AuthClient.String · 1 statement · open-gap" "[go] 안 부른 값 수신자 한 줄 함수 · why 가 열린 항목 id"
assert_line "$OUT" "  UNREACHED $G:44 AuthClient.LogoutURL · 2 statements · integration: the drive never calls it — the integration test does, outside the unit run" "[go] 통합 시험만 부르는 함수 — 태그 없는 단위 실행은 그 시험을 컴파일하지 않는다"
# ⚠️ 알려진 틈을 고정한다 — 커버 프로필에는 가지가 없다: `&&` · `||` 의 피연산자는 블록이 아니라 실패 쪽을 안 탄 실행도 문장이 다 돈다(도구
# 머리 주석). 이 단언이 깨지면 리더가 조건을 보게 된 것이다 — 머리 주석과 장부를 함께 고칠 때다.
assert_not_contains "$OUT" "AuthClient.Valid" "[go] && 의 실패 쪽은 블록이 아니다 — 알려진 틈"
assert_not_contains "$OUT" "AuthClient.Realm" "[go] 다 닿는 함수는 목록에 없다"
assert_not_contains "$OUT" "Config" "[go] 경계 밖 파일은 목록에 없다"
assert_line "$OUT" "unit-unreached [go]: OK — 4 functions with code the unit suite never reaches (5 statements), each recorded in scripts/unit-unreached.json" "[go] 요약 — 문장으로 센다"

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
ufresh
sed -i 's#<method name="realm" desc="()Ljava/lang/String;" line="18"><counter type="INSTRUCTION" missed="0" covered="3"/><counter type="LINE" missed="0" covered="1"/>#<method name="realm" desc="()Ljava/lang/String;" line="18"><counter type="INSTRUCTION" missed="3" covered="0"/><counter type="LINE" missed="1" covered="0"/>#' "$D/java.unit.xml"
jmark 0
assert_contains "$(cat "$D/java.unit.xml")" '<method name="realm" desc="()Ljava/lang/String;" line="18"><counter type="INSTRUCTION" missed="3" covered="0"/>' "(변이가 착지했는지 먼저 본다)"
run unit-report java "$T" --out "$D"
assert_eq 1 "$RC" "[java] 장부에 없는 미도달 함수는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [java] unrecorded unreached code $J:AuthClient.realm — the unit suite never reaches 1 line · 0 branches of it: test that code, or record why in scripts/unit-unreached.json" "[java] 새 미도달"
# 줄은 그대로인데 가지 하나가 새로 안 돈다 — 익명 Comparator 의 compare 에서(그 수는 감싼 메서드 sorted 의 것이다).
ufresh
sed -i 's#<method name="compare" desc="(Ljava/lang/String;Ljava/lang/String;)I" line="45"><counter type="INSTRUCTION" missed="2" covered="6"/><counter type="BRANCH" missed="1" covered="1"/>#<method name="compare" desc="(Ljava/lang/String;Ljava/lang/String;)I" line="45"><counter type="INSTRUCTION" missed="2" covered="6"/><counter type="BRANCH" missed="2" covered="0"/>#' "$D/java.unit.xml"
jmark 0
assert_contains "$(cat "$D/java.unit.xml")" '<counter type="BRANCH" missed="2" covered="0"/>' "(변이가 착지했는지 먼저 본다)"
run unit-report java "$T" --out "$D"
assert_eq 1 "$RC" "[java] 줄 수가 같아도 놓친 가지가 늘면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [java] $J:AuthClient.sorted: the unit run leaves 1 line · 2 branches unreached, scripts/unit-unreached.json records 1 line · 1 branch — test what the unit suite does not reach, or record why and correct the counts" "[java] 익명 클래스의 가지가 감싼 메서드의 수를 바꾼다"
# 불린 메서드의 몸통 줄 하나가 새로 안 돈다 — token 의 L15 를 0 회로(호출 횟수는 그대로다).
ufresh
sed -i 's#"lines":\[null,null,1,null,1,1,1,null,null,null,1,null,null,1,2,#"lines":[null,null,1,null,1,1,1,null,null,null,1,null,null,1,0,#' "$D/ruby.unit.json"
rmark 0
assert_contains "$(cat "$D/ruby.unit.json")" '"lines":[null,null,1,null,1,1,1,null,null,null,1,null,null,1,0,' "(변이가 착지했는지 먼저 본다)"
run unit-report ruby "$T" --out "$D"
assert_eq 1 "$RC" "[ruby] 장부에 없는 미도달 메서드는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [ruby] unrecorded unreached code $R:AuthClient#token — the unit suite never reaches 1 line · 0 branches of it: test that code, or record why in scripts/unit-unreached.json" "[ruby] 새 미도달"
# 줄은 그대로인데 갈래 하나가 새로 안 탄다 — 행복 경로가 도는 줄의 실패 갈래가 생긴 꼴(줄만 세면 못 본다). token 삼항의 then 쪽을 0 으로.
ufresh
sed -i 's#{"type":"then","start":\[15,18\],"end":\[15,44\],"count":1}#{"type":"then","start":[15,18],"end":[15,44],"count":0}#' "$D/ruby.unit.json"
rmark 0
assert_contains "$(cat "$D/ruby.unit.json")" '{"type":"then","start":[15,18],"end":[15,44],"count":0}' "(변이가 착지했는지 먼저 본다)"
run unit-report ruby "$T" --out "$D"
assert_eq 1 "$RC" "[ruby] 돈 줄 위의 안 탄 갈래는 장부에 적을 때까지 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [ruby] unrecorded unreached code $R:AuthClient#token — the unit suite never reaches 0 lines · 1 branch of it" "[ruby] 돈 줄의 안 탄 갈래"
# 한 줄 메서드는 호출 횟수로 센다 — realm 의 횟수를 0 으로(그 줄은 적재 때 돌아 1 회 그대로다).
ufresh
sed -i 's#"name":"realm","start":\[11,4\],"end":\[11,29\],"count":1#"name":"realm","start":[11,4],"end":[11,29],"count":0#' "$D/ruby.unit.json"
rmark 0
assert_contains "$(cat "$D/ruby.unit.json")" '"name":"realm","start":[11,4],"end":[11,29],"count":0' "(변이가 착지했는지 먼저 본다)"
run unit-report ruby "$T" --out "$D"
assert_eq 1 "$RC" "[ruby] 안 불린 한 줄 메서드는 그 줄이 돌았어도 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [ruby] unrecorded unreached code $R:AuthClient#realm — the unit suite never reaches 1 line · 0 branches of it" "[ruby] 한 줄 메서드 — 호출 횟수"
# go — 다 닿던 Realm 의 블록을 0 회로(장부에 없다).
ufresh
sed -i 's#^example\.com/fixture/go/auth_client\.go:12\.37,12\.55 1 1$#example.com/fixture/go/auth_client.go:12.37,12.55 1 0#' "$D/go.unit.cover"
gmark 0
assert_contains "$(cat "$D/go.unit.cover")" 'example.com/fixture/go/auth_client.go:12.37,12.55 1 0' "(변이가 착지했는지 먼저 본다)"
run unit-report go "$T" --out "$D"
assert_eq 1 "$RC" "[go] 장부에 없는 미도달 함수는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [go] unrecorded unreached code $G:AuthClient.Realm — the unit suite never reaches 1 statement of it: test that code, or record why in scripts/unit-unreached.json" "[go] 새 미도달"
# 이미 적힌 함수 안에서 블록 하나가 더 안 돈다 — Exchange 의 행복 경로 블록을 0 회로(함수는 그대로 목록에 있고 수가 바뀐다).
ufresh
sed -i 's#^example\.com/fixture/go/auth_client\.go:19\.2,19\.27 1 1$#example.com/fixture/go/auth_client.go:19.2,19.27 1 0#' "$D/go.unit.cover"
gmark 0
assert_contains "$(cat "$D/go.unit.cover")" 'example.com/fixture/go/auth_client.go:19.2,19.27 1 0' "(변이가 착지했는지 먼저 본다)"
run unit-report go "$T" --out "$D"
assert_eq 1 "$RC" "[go] 적힌 함수의 블록 하나가 더 안 돌면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [go] $G:AuthClient.Exchange: the unit run leaves 2 statements unreached, scripts/unit-unreached.json records 1 statement — test what the unit suite does not reach, or record why and correct the counts" "[go] 더 놓친 문장 수"

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
ufresh
sed -i '/AuthClient\.java:AuthClient\.later"/,/},/d' "$L"
run unit-report java "$T" --out "$D"
assert_eq 1 "$RC" "[java] 람다 안의 놓친 가지가 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [java] unrecorded unreached code $J:AuthClient.later — the unit suite never reaches 0 lines · 1 branch of it" "[java] 람다의 가지 — 소스 메서드 키"
ufresh
sed -i '/AuthClient\.java:AuthClient\.sorted"/,/},/d' "$L"
run unit-report java "$T" --out "$D"
assert_eq 1 "$RC" "[java] 익명 클래스 안의 놓친 줄 · 가지가 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [java] unrecorded unreached code $J:AuthClient.sorted — the unit suite never reaches 1 line · 1 branch of it" "[java] 익명 클래스 — 감싼 메서드 키"
ufresh
sed -i '/AuthClient#apply"/,/},/d' "$L"
run unit-report ruby "$T" --out "$D"
assert_eq 1 "$RC" "[ruby] 블록 안의 안 돈 줄 · 안 탄 갈래가 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [ruby] unrecorded unreached code $R:AuthClient#apply — the unit suite never reaches 1 line · 2 branches of it" "[ruby] 블록의 줄 · 갈래 — 감싼 메서드 키"
# 돈 줄 위의 안 탄 갈래(후치 unless)만 있는 메서드 — 장부에서 지우면 DRIFT 다(줄만 세던 장부는 이것을 못 봤다).
ufresh
sed -i '/AuthClient#pick"/,/},/d' "$L"
run unit-report ruby "$T" --out "$D"
assert_eq 1 "$RC" "[ruby] 돈 줄 위의 안 탄 갈래가 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [ruby] unrecorded unreached code $R:AuthClient#pick — the unit suite never reaches 0 lines · 1 branch of it" "[ruby] 후치 unless 의 갈래"
# go — 함수 리터럴 안의 안 돈 문장(Pick 의 find 의 `return ""`)도 장부에서 지우면 감싼 함수 이름으로 DRIFT 다.
ufresh
sed -i '/auth_client\.go:AuthClient\.Pick"/,/},/d' "$L"
assert_not_contains "$(cat "$L")" "auth_client.go:AuthClient.Pick" "(변이가 착지했는지 먼저 본다)"
run unit-report go "$T" --out "$D"
assert_eq 1 "$RC" "[go] 함수 리터럴 안의 안 돈 문장이 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [go] unrecorded unreached code $G:AuthClient.Pick — the unit suite never reaches 1 statement of it" "[go] 함수 리터럴의 문장 — 감싼 함수 키"

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
ufresh
sed -i '/AuthClient\.java:AuthClient\.exchange"/,/}/ s#"branches": 1,#"branches": 2,#' "$L"
run unit-report java "$T" --out "$D"
assert_eq 1 "$RC" "[java] 수가 다르면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [java] $J:AuthClient.exchange: the unit run leaves 1 line · 1 branch unreached, scripts/unit-unreached.json records 1 line · 2 branches — the unit suite reaches more of it now: lower the counts" "[java] 바뀐 수 — 장부보다 덜 놓쳤다"
ufresh
sed -i '/AuthClient#exchange"/,/}/ s#"lines": 1,#"lines": 2,#' "$L"
run unit-report ruby "$T" --out "$D"
assert_eq 1 "$RC" "[ruby] 수가 다르면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [ruby] $R:AuthClient#exchange: the unit run leaves 1 line · 1 branch unreached, scripts/unit-unreached.json records 2 lines · 1 branch — the unit suite reaches more of it now: lower the counts" "[ruby] 바뀐 줄 수"
# 낡은 가지 수 — 장부가 측정보다 적은 갈래를 적었다(가지 하나가 새로 안 타는 꼴).
ufresh
sed -i '/AuthClient#apply"/,/}/ s#"branches": 2,#"branches": 1,#' "$L"
run unit-report ruby "$T" --out "$D"
assert_eq 1 "$RC" "[ruby] 가지 수만 달라도 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [ruby] $R:AuthClient#apply: the unit run leaves 1 line · 2 branches unreached, scripts/unit-unreached.json records 1 line · 1 branch — test what the unit suite does not reach, or record why and correct the counts" "[ruby] 바뀐 가지 수"
ufresh
sed -i '/auth_client\.go:AuthClient\.LogoutURL"/,/}/ s#"statements": 2,#"statements": 3,#' "$L"
assert_contains "$(grep -A1 'auth_client.go:AuthClient.LogoutURL"' "$L")" '"statements": 3,' "(변이가 착지했는지 먼저 본다)"
run unit-report go "$T" --out "$D"
assert_eq 1 "$RC" "[go] 수가 다르면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [go] $G:AuthClient.LogoutURL: the unit run leaves 2 statements unreached, scripts/unit-unreached.json records 3 statements — the unit suite reaches more of it now: lower the counts" "[go] 바뀐 문장 수 — 장부보다 덜 놓쳤다"

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
ufresh
sed -i "s#\"java\": {#\"java\": {\n    \"$J:AuthClient.realm\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: stale\" },\n    \"$J:AuthClient.gone\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: renamed\" },\n    \"java/kc-auth/src/main/java/kc/auth/Config.java:Config.valid\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: outside\" },#" "$L"
run unit-report java "$T" --out "$D"
assert_eq 1 "$RC" "[java] 낡은 항목은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [java] stale entry $J:AuthClient.realm — the unit run reaches all of it now; drop the entry" "[java] 다 닿는 메서드의 항목"
assert_contains "$OUT" "DRIFT [java] stale entry $J:AuthClient.gone — the data of $J has no such function (renamed or removed?)" "[java] 없는 메서드의 항목"
assert_contains "$OUT" "DRIFT [java] scripts/unit-unreached.json: entry java/kc-auth/src/main/java/kc/auth/Config.java:Config.valid names a file outside the boundary derived from java/pom.xml:53" "[java] 경계 밖 파일의 항목"
ufresh
sed -i "s#\"ruby\": {#\"ruby\": {\n    \"$R:AuthClient\#token\": { \"lines\": 0, \"branches\": 1, \"why\": \"integration: stale\" },\n    \"$R:AuthClient\#gone\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: renamed\" },\n    \"ruby/lib/kc/config.rb:Config\#valid?\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: outside\" },#" "$L"
assert_contains "$(cat "$L")" "\"$R:AuthClient#gone\": { \"lines\": 1, \"branches\": 0," "(변이가 착지했는지 먼저 본다)"
run unit-report ruby "$T" --out "$D"
assert_eq 1 "$RC" "[ruby] 낡은 항목은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [ruby] stale entry $R:AuthClient#token — the unit run reaches all of it now; drop the entry" "[ruby] 다 닿는 메서드의 항목"
assert_contains "$OUT" "DRIFT [ruby] stale entry $R:AuthClient#gone — the data of $R has no such function (renamed or removed?)" "[ruby] 없는 메서드의 항목"
assert_contains "$OUT" "DRIFT [ruby] scripts/unit-unreached.json: entry ruby/lib/kc/config.rb:Config#valid? names a file outside the boundary derived from ruby/spec/spec_helper.rb:9" "[ruby] 경계 밖 파일의 항목"
ufresh
sed -i "s#\"go\": {#\"go\": {\n    \"$G:AuthClient.Realm\": { \"statements\": 1, \"why\": \"integration: stale\" },\n    \"$G:AuthClient.Gone\": { \"statements\": 1, \"why\": \"integration: renamed\" },\n    \"go/config.go:Config.Valid\": { \"statements\": 1, \"why\": \"integration: outside\" },#" "$L"
assert_contains "$(cat "$L")" "\"$G:AuthClient.Gone\": { \"statements\": 1," "(변이가 착지했는지 먼저 본다)"
run unit-report go "$T" --out "$D"
assert_eq 1 "$RC" "[go] 낡은 항목은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [go] stale entry $G:AuthClient.Realm — the unit run reaches all of it now; drop the entry" "[go] 다 닿는 함수의 항목"
assert_contains "$OUT" "DRIFT [go] stale entry $G:AuthClient.Gone — the data of $G has no such function (renamed or removed?)" "[go] 없는 함수의 항목"
assert_contains "$OUT" "DRIFT [go] scripts/unit-unreached.json: entry go/config.go:Config.Valid names a file outside the boundary derived from .github/workflows/go-ci.yml:10" "[go] 경계 밖 파일의 항목"

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
run unit-report java "$T" --out "$D"
assert_eq 1 "$RC" "[java] 닫힌 등록부 항목은 why 가 아니다 — exit 1"
assert_contains "$OUT" "DRIFT [java] $J:AuthClient.pick: why \"closed-gap\"" "[java] 닫힌 id"
run unit-report ruby "$T" --out "$D"
assert_eq 1 "$RC" "[ruby] 닫힌 등록부 항목은 why 가 아니다 — exit 1"
assert_contains "$OUT" "DRIFT [ruby] $R:AuthClient#pick: why \"closed-gap\"" "[ruby] 닫힌 id"
run unit-report go "$T" --out "$D"
assert_eq 1 "$RC" "[go] 닫힌 등록부 항목은 why 가 아니다 — exit 1"
assert_contains "$OUT" "DRIFT [go] $G:AuthClient.String: why \"closed-gap\"" "[go] 닫힌 id"
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
# java — 같은 무결성 판정(데이터 · 다른 바이트 · 단위 기록 · failsafe 보고 · 기록 뒤 바뀐 데이터와 javap 출력 · 실패한 실행 · 데이터에 없는
# 경계 파일)과 장부의 꼴.
ufresh
rm "$D/java.unit.xml"
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 데이터가 없으면 exit 2"
assert_contains "$OUT" "run the unit suite first (node scripts/integration-coverage.mjs unit java)" "[java] 다시 돌릴 명령"
ufresh
printf '\n// changed after the run\n' >> "$T/$J"
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 다른 바이트의 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [java] $J: the data was taken from other bytes" "[java] 다른 바이트"
ufresh
sed -i 's#"suite":"unit",##' "$D/java.unit.run.json"
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 통합 실행의 기록(suite 없음)은 exit 2"
assert_contains "$OUT" "FAIL [java] no record that \`unit java\` wrote this data" "[java] 단위 기록 아님"
ufresh
jmark 0 1 0 1
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] failsafe 보고가 섞인 실행은 exit 2"
assert_contains "$OUT" "FAIL [java] the run included 1 integration test report — the data would not be unit-only (unit java runs the test phase only — failsafe binds after it)" "[java] 통합 섞임"
ufresh
sed -i 's#<sessioninfo id="HOST-00000000"#<sessioninfo id="HOST-00000001"#' "$D/java.unit.xml"
assert_contains "$(cat "$D/java.unit.xml")" '<sessioninfo id="HOST-00000001"' "(변이가 착지했는지 먼저 본다)"
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 기록 뒤 바뀐 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/java.unit.xml is not the data \`unit java\` recorded" "[java] 데이터의 sha1"
ufresh
printf '\n' >> "$D/java.unit.javap.txt"
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 기록 뒤 바뀐 javap 출력은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/java.unit.javap.txt is not the javap output \`unit java\` recorded" "[java] javap 출력의 sha1"
ufresh
jmark 1
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 실패한 실행의 데이터는 exit 2"
assert_contains "$OUT" "FAIL [java] the run that wrote this data exited 1" "[java] 실패한 실행"
ufresh
jmark 0 1 1
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 실패한 단위 시험이 있으면 exit 2"
assert_contains "$OUT" "FAIL [java] 1 of 1 unit tests failed" "[java] 실패한 시험"
ufresh
jmark 0 0
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 단위 시험 0 개의 실행은 exit 2"
assert_contains "$OUT" "FAIL [java] the run recorded no unit tests" "[java] 공허한 실행"
ufresh
sed -i 's#<sourcefile name="QuickStart.java">#<sourcefile name="Other.java">#' "$D/java.unit.xml"
jmark 0
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 경계 파일이 데이터에 없으면 exit 2"
assert_contains "$OUT" "FAIL [java] $Q is not in the coverage data" "[java] 데이터에 없는 경계 파일"
ufresh
sed -i '/AuthClient\.java:AuthClient\.exchange"/,/}/ { /"branches": 1,/d }' "$L"
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] java 항목에 branches 가 없으면 exit 2"
assert_contains "$OUT" "FAIL [java] scripts/unit-unreached.json: java[\"$J:AuthClient.exchange\"] must be { branches, lines, why }" "[ledger] java 꼴"
# ruby — 같은 무결성 판정(데이터 · 다른 바이트 · 단위 기록 · 기록 뒤 바뀐 덤프 · 단위 스위트 · 실패한 실행 · 실패한 예제 · 데이터에 없는
# 경계 파일)과 장부의 꼴.
ufresh
rm "$D/ruby.unit.json"
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 데이터가 없으면 exit 2"
assert_contains "$OUT" "run the unit suite first (node scripts/integration-coverage.mjs unit ruby)" "[ruby] 다시 돌릴 명령"
ufresh
printf '# changed after the run\n' >> "$T/$R"
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 다른 바이트의 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] $R: the data was taken from other bytes" "[ruby] 다른 바이트"
ufresh
sed -i 's#"suite":"unit",##' "$D/ruby.unit.run.json"
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 통합 실행의 기록(suite 없음)은 exit 2"
assert_contains "$OUT" "FAIL [ruby] no record that \`unit ruby\` wrote this data" "[ruby] 단위 기록 아님"
ufresh
printf ' ' >> "$D/ruby.unit.json"
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 기록 뒤 바뀐 덤프는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/ruby.unit.json is not the data \`unit ruby\` recorded" "[ruby] 덤프의 sha1"
# 단위 실행에 통합 스위트의 예제가 섞였다 · 태그와 자리가 갈리는 예제(어느 스위트인지 모른다 — 섞인 것으로 본다).
ufresh
sed -i 's#"integration":false#"integration":true#' "$D/ruby.unit.json"
rmark 0
assert_contains "$(cat "$D/ruby.unit.json")" '"integration":true' "(변이가 착지했는지 먼저 본다)"
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 통합 태그가 실린 단위 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] the run included examples of the integration suite or examples it cannot place (./spec/unit/drive_spec.rb[1:1]) — the data would not be unit-only" "[ruby] 통합 섞임"
ufresh
sed -i 's#"file":"./spec/unit/drive_spec.rb"#"file":"./spec/integration/drive_spec.rb"#' "$D/ruby.unit.json"
rmark 0
assert_contains "$(cat "$D/ruby.unit.json")" '"file":"./spec/integration/drive_spec.rb"' "(변이가 착지했는지 먼저 본다)"
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 태그 없이 spec/integration 에 있는 예제는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] the run included examples of the integration suite or examples it cannot place (./spec/unit/drive_spec.rb[1:1])" "[ruby] 못 가르는 예제"
ufresh
rmark 1
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 실패한 실행의 데이터는 exit 2"
assert_contains "$OUT" "FAIL [ruby] the run that wrote this data exited 1" "[ruby] 실패한 실행"
ufresh
sed -i 's#"status":"passed"#"status":"failed"#' "$D/ruby.unit.json"
rmark 0
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 실패한 단위 예제가 있으면 exit 2"
assert_contains "$OUT" "FAIL [ruby] 1 of 1 examples in the run did not pass — the data of a failed run is partial: ./spec/unit/drive_spec.rb[1:1] (failed)" "[ruby] 실패한 예제"
ufresh
sed -i 's#/ruby/lib/kc/auth_client\.rb"#/ruby/spec/spec_helper.rb"#' "$D/ruby.unit.json"
rmark 0
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 경계 파일이 데이터에 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] $R is not in the coverage data" "[ruby] 데이터에 없는 경계 파일"
# 가지의 꼴 · 판 — 가지 없는 옛 덤프(/1) · 가지가 null(branches 없이 켠 Coverage) · 못 읽는 갈래 횟수 · 파일 밖 자리 · 메서드 밖 자리의
# 안 탄 갈래(어느 메서드에도 못 붙인다). 못 읽는 가지를 0 개로 세지 않는다.
ufresh
sed -i 's#kcsdk-ruby-coverage/2#kcsdk-ruby-coverage/1#' "$D/ruby.unit.json"
rmark 0
assert_contains "$(cat "$D/ruby.unit.json")" '"format":"kcsdk-ruby-coverage/1"' "(변이가 착지했는지 먼저 본다)"
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 가지 없는 옛 형식(/1)의 덤프는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "is not the dump \`unit ruby\` writes (format kcsdk-ruby-coverage/2)" "[ruby] 옛 형식"
ufresh
sed -i 's#"branches":\[{"type":"if","start":\[15,6\]#"branches":null,"x":[{"type":"if","start":[15,6]#' "$D/ruby.unit.json"
rmark 0
assert_contains "$(cat "$D/ruby.unit.json")" '"branches":null,"x":[' "(변이가 착지했는지 먼저 본다)"
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] null 인 branches 는 exit 2(가지 0 개가 아니다) — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] $R: cannot read the branch counts in" "[ruby] null 가지"
ufresh
sed -i 's#{"type":"else","start":\[47,27\],"end":\[47,48\],"count":0}#{"type":"else","start":[47,27],"end":[47,48],"count":-1}#' "$D/ruby.unit.json"
rmark 0
assert_contains "$(cat "$D/ruby.unit.json")" '"end":[47,48],"count":-1}' "(변이가 착지했는지 먼저 본다)"
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 음수 갈래 횟수는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] $R: cannot read the branch counts in" "[ruby] 못 읽는 갈래 횟수"
ufresh
sed -i 's#{"type":"if","start":\[59,6\],"end":\[61,9\]#{"type":"if","start":[59,6],"end":[99,9]#' "$D/ruby.unit.json"
rmark 0
assert_contains "$(cat "$D/ruby.unit.json")" '{"type":"if","start":[59,6],"end":[99,9]' "(변이가 착지했는지 먼저 본다)"
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 파일 밖까지 가는 자리는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] $R: the if branch at lines 59–99 lies outside the" "[ruby] 파일 밖 자리"
ufresh
sed -i 's#{"type":"&.","start":\[47,27\]#{"type":"\&.","start":[5,27]#' "$D/ruby.unit.json"
rmark 0
assert_contains "$(cat "$D/ruby.unit.json")" '{"type":"&.","start":[5,27]' "(변이가 착지했는지 먼저 본다)"
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 메서드 밖 자리의 안 탄 갈래는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] $R:5: the &. branch there sits outside every method and has an arm the run never took — no method can be credited with it" "[ruby] 메서드 밖 갈래"
ufresh
sed -i '/AuthClient#exchange"/,/}/ { /"branches": 1,/d }' "$L"
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] ruby 항목에 branches 가 없으면 exit 2"
assert_contains "$OUT" "FAIL [ruby] scripts/unit-unreached.json: ruby[\"$R:AuthClient#exchange\"] must be { branches, lines, why }" "[ledger] ruby 꼴"
# go — 같은 무결성 판정(데이터 · 다른 바이트 · 단위 기록 · 기록 없음 · 기록 뒤 바뀐 프로필 · 경계 해시 없는 기록 · 실패한 실행 · 데이터에 없는
# 경계 파일 · 공허한 실행 · 어느 함수에도 못 붙이는 안 돈 문장)과 장부의 꼴(문장 — 줄 · 가지가 아니다).
ufresh
rm "$D/go.unit.cover"
run unit-report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 데이터가 없으면 exit 2"
assert_contains "$OUT" "FAIL [go] no coverage data at" "[go] 데이터 없음"
assert_contains "$OUT" "run the unit suite first (node scripts/integration-coverage.mjs unit go)" "[go] 다시 돌릴 명령"
ufresh
printf '\n// changed after the run\n' >> "$T/$G"
run unit-report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 다른 바이트의 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [go] $G: the data was taken from other bytes" "[go] 다른 바이트"
ufresh
sed -i 's#"suite":"unit",##' "$D/go.unit.run.json"
assert_not_contains "$(cat "$D/go.unit.run.json")" '"suite"' "(변이가 착지했는지 먼저 본다)"
run unit-report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 단위 실행의 것이 아닌 기록(suite 없음)은 exit 2"
assert_contains "$OUT" "FAIL [go] no record that \`unit go\` wrote this data" "[go] 단위 기록 아님"
ufresh
rm "$D/go.unit.run.json"
run unit-report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 기록이 없는 프로필(손으로 돌린 go test)은 exit 2"
assert_contains "$OUT" "FAIL [go] no record that \`unit go\` wrote this data" "[go] 기록 없음"
ufresh
printf 'example.com/fixture/go/auth_client.go:12.37,12.55 1 1\n' >> "$D/go.unit.cover"
run unit-report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 기록 뒤 바뀐 프로필은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/go.unit.cover is not the data \`unit go\` recorded" "[go] 프로필의 sha1"
ufresh
sed -i 's#"files":{[^}]*}#"files":null#' "$D/go.unit.run.json"
assert_contains "$(cat "$D/go.unit.run.json")" '"files":null' "(변이가 착지했는지 먼저 본다)"
run unit-report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 경계 해시가 없는 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [go] the record has no boundary hashes" "[go] 실행 중에 바뀐 경계 파일"
ufresh
gmark 1
run unit-report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 실패한 실행의 데이터는 exit 2"
assert_contains "$OUT" "FAIL [go] the run that wrote this data exited 1 — the data of a failed run is partial" "[go] 실패한 실행"
ufresh
sed -i '/\/auth_client\.go:/d' "$D/go.unit.cover"
gmark 0
assert_not_contains "$(cat "$D/go.unit.cover")" "auth_client.go" "(변이가 착지했는지 먼저 본다)"
run unit-report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 경계 파일이 데이터에 없으면 exit 2"
assert_contains "$OUT" "FAIL [go] $G is not in the coverage data" "[go] 데이터에 없는 경계 파일"
ufresh
sed -i '/\/auth_client\.go:/ s# 1$# 0#' "$D/go.unit.cover"
gmark 0
assert_eq 0 "$(grep -c '/auth_client\.go:.* 1$' "$D/go.unit.cover" || true)" "(변이가 착지했는지 먼저 본다)"
run unit-report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 경계 문장을 하나도 안 돈 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [go] the run executed 0 of 15 boundary statements — a measurement failure, not a low number (did the unit tests run against this tree?)" "[go] 공허한 실행 — 패키지 수준 판정보다 먼저다"
assert_not_contains "$OUT" "package-level" "[go] 공허한 실행은 패키지 수준의 안 돈 문장으로 읽지 않는다"
# 패키지 수준 함수 리터럴(hook)의 안 돈 문장 — 어느 함수 선언에도 안 든다(통합 리포트는 그것을 파일 표의 package-level 로 보인다).
ufresh
sed -i 's#^example\.com/fixture/go/auth_client\.go:50\.23,52\.2 1 1$#example.com/fixture/go/auth_client.go:50.23,52.2 1 0#' "$D/go.unit.cover"
gmark 0
assert_contains "$(cat "$D/go.unit.cover")" 'example.com/fixture/go/auth_client.go:50.23,52.2 1 0' "(변이가 착지했는지 먼저 본다)"
run unit-report go "$T" --out "$D"
assert_eq 2 "$RC" "[go] 어느 함수에도 못 붙이는 안 돈 문장은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [go] $G: 1 of 1 package-level statements (a function literal outside every function declaration) never ran — no function can be credited with them" "[go] 패키지 수준 함수 리터럴"
# 장부의 꼴 — go 항목은 { statements, why } 다: 줄로 적거나 가지를 더하면 exit 2 이고, 줄을 세는 언어의 항목이 문장으로 적어도 exit 2 다.
ufresh
sed -i '/auth_client\.go:AuthClient\.Exchange"/,/}/ s#"statements": 1,#"lines": 1,#' "$L"
assert_contains "$(grep -A1 'auth_client.go:AuthClient.Exchange"' "$L")" '"lines": 1,' "(변이가 착지했는지 먼저 본다)"
run unit-report go "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] go 항목을 줄로 적으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [go] scripts/unit-unreached.json: go[\"$G:AuthClient.Exchange\"] must be { statements, why } — whole-number counts and a non-empty why" "[ledger] go 꼴 — 문장"
ufresh
sed -i '/auth_client\.go:AuthClient\.Exchange"/,/}/ s#"statements": 1,#"statements": 1, "branches": 0,#' "$L"
assert_contains "$(grep -A1 'auth_client.go:AuthClient.Exchange"' "$L")" '"statements": 1, "branches": 0,' "(변이가 착지했는지 먼저 본다)"
run unit-report go "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] go 항목에 branches 가 있으면 exit 2(커버 프로필에는 가지가 없다)"
assert_contains "$OUT" "FAIL [go] scripts/unit-unreached.json: go[\"$G:AuthClient.Exchange\"] must be { statements, why }" "[ledger] go 꼴 — 가지 없음"
ufresh
sed -i '/AuthClient::exchange"/,/}/ s#"lines": 1,#"statements": 1,#' "$L"
assert_contains "$(grep -A1 'AuthClient::exchange"' "$L")" '"statements": 1,' "(변이가 착지했는지 먼저 본다)"
run unit-report php "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] php 항목을 문장으로 적으면 exit 2(문장은 go 의 것이다)"
assert_contains "$OUT" "FAIL [php] scripts/unit-unreached.json: php[\"$P:AuthClient::exchange\"] must be { lines, why }" "[ledger] php 꼴 — 줄"
ufresh
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[cli] 재지 않는 언어는 usage(exit 2)"
assert_contains "$OUT" "the unit-unreached ledger measures kotlin · php · dotnet · java · ruby · go — got python" "[cli] usage 문구"

# ── (4) check — 데이터 없이 꼴 · 경계 · why(통합 픽스처 트리 — 아홉 언어) ──────────────────────────────
fresh
run check "$T"
assert_eq 0 "$RC" "[check] 건강한 장부는 exit 0 — 출력: $OUT"
assert_line "$OUT" "[kotlin] unit-unreached: 1 entry (integration 1)" "[check] kotlin 장부"
assert_line "$OUT" "[php] unit-unreached: 1 entry (open-admin 1)" "[check] php 장부"
assert_line "$OUT" "[dotnet] unit-unreached: 1 entry (defensive 1)" "[check] dotnet 장부"
assert_line "$OUT" "[java] unit-unreached: 1 entry (unreachable 1)" "[check] java 장부"
assert_line "$OUT" "[ruby] unit-unreached: 1 entry (open-masking 1)" "[check] ruby 장부"
assert_line "$OUT" "[go] unit-unreached: 1 entry (open-masking 1)" "[check] go 장부"
fresh
sed -i 's#"statements": 2,#"lines": 2,#' "$T/scripts/unit-unreached.json"
assert_contains "$(grep -A1 'go/admin.go:AdminClient.Close"' "$T/scripts/unit-unreached.json")" '"lines": 2,' "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 2 "$RC" "[check] go 항목을 줄로 적으면 데이터 없이도 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [go] scripts/unit-unreached.json: go[\"go/admin.go:AdminClient.Close\"] must be { statements, why }" "[check] go 꼴"
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

# ── (5) kotlin 꼬리 호출의 닫는 줄(등록부 kotlin-tail-call-return-line-flips) ─────────────────────────────────
# Unit 을 돌려주는 suspend 함수의 마지막 문장이 Unit 을 돌려주는 suspend 호출이면 kotlinc 는 꼬리 호출로 내고, 닫는 중괄호 줄에는 마지막
# areturn 하나만 매긴다 — 그 줄은 호출이 멈추지 않고 돌아왔을 때만 돈다(같은 트리의 CI 실행이 「stale entry」 DRIFT 와 OK 로 갈렸다).
# 리더는 그 줄을 재지 않는다(단위 · 통합이 같은 리더다). 픽스처의 AuthClientTail.update 는 49 · 꼬리 호출 50 · 닫는 줄 51(`line 51: 33`
# — 마지막 areturn)이고, 구동의 adminCall 이 멈추지 않아 51 이 돈 데이터다. 멈춘 실행의 데이터는 그 자리만 바꿔 만든다 — 멈춘 실행의
# 실측(RealmsResource.update: 꼬리 호출 줄 mi 1 · 닫는 줄 mi 1 · 메서드의 줄 1 놓침)과 같은 꼴로, 50 의 getstatic Unit 하나와 51 의
# areturn 하나가 안 돌았다.
tail_suspended() {
  sed -i 's#<method name="update" desc="(Ljava/lang/String;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;" line="49"><counter type="INSTRUCTION" missed="0" covered="11"/><counter type="LINE" missed="0" covered="3"/>#<method name="update" desc="(Ljava/lang/String;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;" line="49"><counter type="INSTRUCTION" missed="2" covered="9"/><counter type="LINE" missed="1" covered="2"/>#; s#<line nr="50" mi="0" ci="10" #<line nr="50" mi="1" ci="9" #; s#<line nr="51" mi="0" ci="1" #<line nr="51" mi="1" ci="0" #' "$D/kotlin.unit.xml"
  kmark 0
  assert_contains "$(cat "$D/kotlin.unit.xml")" '<method name="update" desc="(Ljava/lang/String;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;" line="49"><counter type="INSTRUCTION" missed="2" covered="9"/><counter type="LINE" missed="1" covered="2"/>' "(변이가 착지했는지 먼저 본다 — 메서드 계수기)"
  assert_contains "$(cat "$D/kotlin.unit.xml")" '<line nr="50" mi="1" ci="9" ' "(변이가 착지했는지 먼저 본다 — 꼬리 호출 줄)"
  assert_contains "$(cat "$D/kotlin.unit.xml")" '<line nr="51" mi="1" ci="0" ' "(변이가 착지했는지 먼저 본다 — 닫는 줄)"
}
# 통합 모드 — 같은 리더(jvmReport)다: 단위 데이터를 통합 실행의 이름으로 `$D/it` 에 두고 통합 기록(suite 없음 · unit 0)을 쓴다.
tail_it() {
  rm -rf "$D/it"
  mkdir -p "$D/it"
  cp "$D/kotlin.unit.xml" "$D/it/kotlin.xml"
  cp "$D/kotlin.unit.javap.txt" "$D/it/kotlin.javap.txt"
  printf '{"run":"kotlin","exit":0,"jacoco":"0.8.16","module":"kc-unit","data_sha1":"%s","javap_sha1":"%s","exec_sha1":"0","tests":{"completed":1,"failures":0,"errors":0,"skipped":0},"unit":0,"files":{"%s":"%s"}}\n' \
    "$(sha1sum "$D/it/kotlin.xml" | cut -d' ' -f1)" "$(sha1sum "$D/it/kotlin.javap.txt" | cut -d' ' -f1)" "$K" "$(sha1sum "$T/$K" | cut -d' ' -f1)" > "$D/it/kotlin.run.json"
}
# 통합 리포트는 안 돈 함수마다 열린 소유자를 요구한다 — 안 돈 unused 에 단다(이 대조가 재는 것이 아니다). ufresh 마다 한 번.
tail_owner() {
  sed -i "/\"kotlin\": {/,/\"owners\": {}/ s#\"owners\": {}#\"owners\": { \"$K:AuthClient.unused\": \"open-gap\" }#" "$T/scripts/integration-coverage.json"
  assert_contains "$(cat "$T/scripts/integration-coverage.json")" "\"owners\": { \"$K:AuthClient.unused\": \"open-gap\" }" "(소유자가 착지했는지 먼저 본다)"
}
# (가) 닫는 줄이 돌았든 안 돌았든 단위 장부의 출력 · 종료코드가 같다 — 다른 줄이 다 돈 꼬리 호출 함수는 목록에 없다.
ufresh
run unit-report kotlin "$T" --out "$D"
ran_rc="$RC"
ran_out="$OUT"
assert_eq 0 "$ran_rc" "[tail] 닫는 줄까지 돈 실행은 exit 0 — 출력: $ran_out"
assert_not_contains "$ran_out" "AuthClientTail" "[tail] 닫는 줄까지 돈 꼬리 호출 함수는 목록에 없다"
tail_suspended
run unit-report kotlin "$T" --out "$D"
assert_eq 0 "$RC" "[tail] 닫는 줄만 안 돈 실행(멈춘 호출)도 exit 0 — 그 줄은 재지 않는다 — 출력: $OUT"
assert_not_contains "$OUT" "AuthClientTail" "[tail] 다른 줄이 다 돈 꼬리 호출 함수는 닫는 줄이 안 돌아도 목록에 없다"
assert_eq "$ran_rc" "$RC" "[tail] 단위 장부의 종료코드는 닫는 줄이 돌았든 안 돌았든 같다"
assert_eq "$ran_out" "$OUT" "[tail] 단위 장부의 출력은 닫는 줄이 돌았든 안 돌았든 같다"
# 통합 합계도 같다 — 닫는 줄은 분모에서도 빠진다(돈 줄이어도 센 줄이 아니다).
ufresh
tail_owner
tail_it
run report kotlin "$T" --out "$D/it"
ran_rc="$RC"
ran_out="$OUT"
assert_eq 0 "$ran_rc" "[tail] 통합 — 닫는 줄까지 돈 실행은 exit 0 — 출력: $ran_out"
assert_line "$ran_out" "  total lines 15/17 88.2% · bodies 15/17 88.2%" "[tail] 통합 합계 — 돈 닫는 줄도 분모에 없다"
tail_suspended
tail_it
run report kotlin "$T" --out "$D/it"
assert_eq 0 "$RC" "[tail] 통합 — 닫는 줄만 안 돈 실행도 exit 0 — 출력: $OUT"
assert_line "$OUT" "  total lines 15/17 88.2% · bodies 15/17 88.2%" "[tail] 통합 합계 — 안 돈 닫는 줄도 분모에 없다"
assert_eq "$ran_rc" "$RC" "[tail] 통합 리포트의 종료코드는 닫는 줄이 돌았든 안 돌았든 같다"
assert_eq "$ran_out" "$OUT" "[tail] 통합 리포트(파일 · 합계 · 미실행)는 닫는 줄이 돌았든 안 돌았든 같다"
# (나) 대조군 — 데이터의 닫는 줄에 명령이 둘이면(mi + ci = 2) 그 areturn 하나뿐인 줄이 아니다: 그 줄을 센다(1 줄로 목록에 든다).
ufresh
tail_suspended
sed -i 's#<line nr="51" mi="1" ci="0" #<line nr="51" mi="2" ci="0" #' "$D/kotlin.unit.xml"
kmark 0
assert_contains "$(cat "$D/kotlin.unit.xml")" '<line nr="51" mi="2" ci="0" ' "(변이가 착지했는지 먼저 본다)"
run unit-report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[tail] 대조군 — 명령이 둘인 닫는 줄은 센다: exit 1 — 출력: $OUT"
assert_line "$OUT" "  UNREACHED $K:49 AuthClientTail.update · 1 line · 0 branches · NONE" "[tail] 대조군 — 명령이 둘인 닫는 줄은 1 줄로 든다"
assert_contains "$OUT" "DRIFT [kotlin] unrecorded unreached code $K:AuthClientTail.update — the unit suite never reaches 1 line · 0 branches of it" "[tail] 대조군 — 장부에 없는 미도달"
# 통합 분모에도 남는다 — 단위 장부만으로는 이 판정을 못 가른다(「mi + ci ≥ 1」로 느슨해져도 그 줄을 지우며 covered 를 내려 1 줄로 남는다).
tail_owner
tail_it
run report kotlin "$T" --out "$D/it"
assert_eq 0 "$RC" "[tail] 대조군 — 통합 리포트는 exit 0 — 출력: $OUT"
assert_line "$OUT" "  total lines 15/18 83.3% · bodies 15/18 83.3%" "[tail] 대조군 — 명령이 둘인 닫는 줄은 통합 분모에 남는다"
# (다) 대조군 — 끝 명령 하나가 다르면 꼬리 호출의 꼴이 아니다: 그 줄을 센다. 마지막 getstatic 이 Unit.INSTANCE 가 아니다 · 닫는 줄의
# 줄표 항목이 마지막 areturn 앞(getstatic)에서 시작한다.
ufresh
tail_suspended
sed -i '/^  public final java.lang.Object update(java.lang.String, kotlin.coroutines.Continuation/,/^      LineNumberTable:$/ s#// Field kotlin/Unit.INSTANCE:Lkotlin/Unit;$#// Field kotlin/Unit.OTHER:Lkotlin/Unit;#' "$D/kotlin.unit.javap.txt"
kmark 0
assert_contains "$(sed -n '/^  public final java.lang.Object update(java.lang.String, kotlin.coroutines.Continuation/,/^      LineNumberTable:$/p' "$D/kotlin.unit.javap.txt")" '30: getstatic     #71                 // Field kotlin/Unit.OTHER:Lkotlin/Unit;' "(변이가 착지했는지 먼저 본다)"
run unit-report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[tail] 대조군 — 마지막 getstatic 이 Unit.INSTANCE 가 아니면 그 줄을 센다: exit 1 — 출력: $OUT"
assert_line "$OUT" "  UNREACHED $K:49 AuthClientTail.update · 1 line · 0 branches · NONE" "[tail] 대조군 — 다른 필드의 getstatic"
ufresh
tail_suspended
sed -i '/^  public final java.lang.Object update(java.lang.String, kotlin.coroutines.Continuation/,/^      LocalVariableTable:$/ s#^        line 51: 33$#        line 51: 30#' "$D/kotlin.unit.javap.txt"
kmark 0
assert_contains "$(sed -n '/^  public final java.lang.Object update(java.lang.String, kotlin.coroutines.Continuation/,/^      LocalVariableTable:$/p' "$D/kotlin.unit.javap.txt")" '        line 51: 30' "(변이가 착지했는지 먼저 본다)"
run unit-report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[tail] 대조군 — 닫는 줄의 줄표 항목이 마지막 areturn 앞에서 시작하면 그 줄을 센다: exit 1 — 출력: $OUT"
assert_line "$OUT" "  UNREACHED $K:49 AuthClientTail.update · 1 line · 0 branches · NONE" "[tail] 대조군 — 마지막 줄표 항목이 areturn 앞"
# (라) 대조군 — 닫는 줄이 돌았으면 그 줄을 빼며 내리는 것은 covered 다: 같은 메서드의 다른 놓친 줄은 그대로 센다(missed 를 내리면 그
# 줄이 장부에서 사라진다). 49 만 안 돈 데이터다 — 실행 차례로는 없는 꼴이고, 줄 데이터와 메서드 계수기의 대조만 잰다.
ufresh
sed -i 's#<method name="update" desc="(Ljava/lang/String;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;" line="49"><counter type="INSTRUCTION" missed="0" covered="11"/><counter type="LINE" missed="0" covered="3"/>#<method name="update" desc="(Ljava/lang/String;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;" line="49"><counter type="INSTRUCTION" missed="5" covered="6"/><counter type="LINE" missed="1" covered="2"/>#; s#<line nr="49" mi="0" ci="5" #<line nr="49" mi="5" ci="0" #' "$D/kotlin.unit.xml"
kmark 0
assert_contains "$(cat "$D/kotlin.unit.xml")" '<method name="update" desc="(Ljava/lang/String;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;" line="49"><counter type="INSTRUCTION" missed="5" covered="6"/><counter type="LINE" missed="1" covered="2"/>' "(변이가 착지했는지 먼저 본다 — 메서드 계수기)"
assert_contains "$(cat "$D/kotlin.unit.xml")" '<line nr="49" mi="5" ci="0" ' "(변이가 착지했는지 먼저 본다 — 49)"
run unit-report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[tail] 대조군 — 닫는 줄이 돌았어도 다른 놓친 줄은 센다: exit 1 — 출력: $OUT"
assert_line "$OUT" "  UNREACHED $K:49 AuthClientTail.update · 1 line · 0 branches · NONE" "[tail] 대조군 — 돈 닫는 줄을 빼며 내리는 것은 covered 다"

assert_report
