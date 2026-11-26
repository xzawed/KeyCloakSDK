#!/usr/bin/env sh
# 단위 미도달 장부(`scripts/integration-coverage.mjs` 의 `unit-report` · `check` — kotlin · php · dotnet · java · ruby · go · python · node · rust,
# 등록부 coverage-exclusion-hides-untested-branches · coverage-omit-hides-security-paths · coverage-ignore-markers-unguarded) 자가테스트 —
# **종료코드**를 단언한다(0 측정 = 장부 · 1 DRIFT · 2 FAIL — 뜻은 그 도구 머리가 소유한다). 문구는 무엇을 잡았는지 가리는 데만 쓴다.
#
# ⚠️ **커밋된 픽스처만 쓴다** — Docker · JDK · Gradle · Maven · PHP · .NET · Ruby · Go · Python · vitest(node_modules) · Rust 가 필요 없다(`unit-report`
# 는 데이터를 읽기만 한다). 데이터는 실제 도구가 낸 것이다(php 2026-11-18 · dotnet 2026-11-19 · java 2026-11-19 · ruby · kotlin · go 2026-11-21 ·
# python 2026-11-23 · node · rust 2026-11-24):
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
#       임시 루트에 tree/go 사본. 프로필의 경로는 모듈 경로(example.com/fixture/go/…)라 치환이 없다. 도구의 `unit go`(임시 루트에 tree 사본)로
#       다시 내도 바이트가 같았다
#   fixtures/unit-unreached/data/python.unit.json   `unit python` 이 도는 명령 — 생성 설정(`[run] source = src/keycloak_sdk` · `branch = true` ·
#       omit 없음)으로 `coverage run -m pytest -m "not integration"` 뒤 `coverage json`(coverage.py 7.15.0 · Python 3.13.11 — CTracer) — 임시
#       루트에 tree 사본. 파일 키는 python/ 기준 상대 경로라(윈도의 `\\` 그대로) 치환이 없다. 도구의 `unit python`(임시 루트에 tree 사본)으로
#       다시 내도 timestamp 말고 바이트가 같았고, Python 3.14.7 · coverage 7.17.4(SysMonitor — 레인 잡의 3.14 가 그날 받은 최신 판)로 같은 명령을
#       돌린 것도 영역마다 안 돈 줄 · 안 탄 호가 같았다
#   fixtures/unit-unreached/data/python-zero.unit.json   같은 명령, 구동이 경계 밖 Config 만 부르고 통합 구동 파일이 없다 — 경계 파일을 한 번도
#       import 하지 않는다(모듈 수준 줄까지 전부 0)
#   fixtures/unit-unreached/data/node.unit.json   `unit node` 가 도는 명령 — 레인 설정(tree/node/vitest.config.ts — include 는 test/unit 뿐)에
#       CLI 로 v8 · `--coverage.include=src/**/*.ts` · 이름 없는 exclude 하나 · 하한 넷 0 · reportOnFailure · json(vitest 5.1.0 · @vitest/coverage-v8
#       5.1.0 · ast-v8-to-istanbul 1.0.7 · Node 22.18.0) — 임시 루트에 tree 사본 + 레인의 node_modules 사본. istanbul 의 파일 키 · path 는 절대
#       경로라 생성 루트만 `@ROOT@` 로 바꿨다(되돌린 바이트가 원본과 같다 — 뒤의 `\\node\\src\\…` 는 윈도의 `\\` 그대로다). 도구의 `unit node`(임시
#       루트에 tree 사본 + node_modules 사본)로 다시 내도 같은 치환 뒤 바이트가 같았다
#   fixtures/unit-unreached/data/node-zero.unit.json   같은 명령, 구동이 경계 밖 Config 만 부른다 — 경계 파일을 한 번도 불러오지 않는다(include 가
#       싣는 0 회 파일 — 모듈 수준 문장까지 전부 0). 도구의 `unit node` 로 다시 내도 바이트가 같았다
#   fixtures/unit-unreached/data/rust.unit.lcov   도구의 `unit rust`(rustc 1.100.0 (0ef1bc386 2026-11-09) · cargo-llvm-cov 0.8.7 — 레인 CI 의
#       stable 과 같은 판) — 임시 루트에 tree 사본(의존 없는 크레이트 kc-fixture · Cargo.lock 은 tree 의 것). SF 는 절대 경로다 — 생성 루트만
#       `@ROOT@` 로 바꿨다(윈도의 `\` · 마지막 줄바꿈 없음 그대로 — 되돌린 바이트가 원본과 같다)
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
# python 의 구동(tree/python/tests/test_drive.py)은 빈 code · 빈 scope · apply 의 항목을 안 보내고 fallback 의 한 줄 조건식을 첫 쪽으로만 타며
# describe · logout_url 을 안 부른다 — logout_url 을 부르는 통합 구동(test_drive_integration.py)은 `integration` 표지라 레인의 단위 명령
# (`-m "not integration"`)이 거른다(수집 때 import 는 돼 경계 모듈의 모듈 수준 줄은 돈다).
# node 의 구동(tree/node/test/unit/drive.test.ts)은 빈 code · 빈 realm · 빈 scope 를 안 보내고 pick 에 빈 항목을 안 주며 kind 를 1 · 2 로만,
# load 를 한 번만 부르고 fallback 의 조건식 · pick 의 `??` 를 한 쪽으로만 타며 describe · logoutUrl 을 안 부른다 — logoutUrl 을 부르는 통합
# 구동(test/integration/drive.it.test.ts)은 레인 설정의 include(test/unit)가 싣지 않는다. 그 설정의 하한(100)은 경계가 못 넘는다 — 장부 실행은
# 그것을 물려받지 않는다(물려받으면 exit 1 — 실측).
# rust 의 구동(tree/rust/tests/drive.rs)은 빈 code 를 안 보내고 port · fallback 에 숫자만 주며(port 의 제 줄 map_err 클로저 · fallback 의 같은
# 줄 클로저가 안 돈다) pick 에 늘 찾는 값만 주고 refresh 의 퓨처를 만들고 버리며 logout_url · convert · Display · DEFAULT_SCOPE 를 안 부른다 —
# logout_url 을 부르는 통합 시험(tests/integration_test.rs)은 `#[ignore]` 라 단위 실행이 컴파일만 한다. 경계 파일 안의 cfg(test) 모듈은 안
# 타는 갈래(panic!)를 하나 갖는다 — 단위 장부가 빼는 줄이다.
# 숫자를 바꾸려면 구동을 고쳐 **도구로 재생성**할 것 — 데이터를 손으로 고치지 않는다(아래 음성 대조군만 고친다).
# `check` 의 장부 판정(데이터 없이 — 꼴 · 경계 · why)은 통합 커버리지 픽스처 트리(`ic-fixture.sh` 의 fresh)에서 잰다 — check 는 아홉
# 언어를 다 보므로 kotlin · php · dotnet · java · ruby · go · python · node · rust 뿐인 이 트리로는 못 잰다.
# ⚠️ 예외 하나 — (7) 의 마지막 칸은 **실제 트리**의 출하 소스를 읽는다(커버리지 제외 표지가 0 인지 — 데이터 없이 그 스캔 줄만 본다).
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
Y=python/src/keycloak_sdk/auth_client.py
E=node/src/auth_client.ts
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
  # coverage.py 의 JSON 키도 절대 경로가 아니다(python/ 기준 상대 경로다).
  cp "$UFIX/data/python.unit.json" "$D/"
  # istanbul 의 파일 키 · path 는 절대 경로다(통합 픽스처의 node_data 와 같은 치환 — 뒤의 `\\node\\src\\…` 는 리더가 `/` 로 읽는다).
  mkdir -p "$D/node.unit"
  sed "s#@ROOT@#$_r#g" "$UFIX/data/node.unit.json" > "$D/node.unit/coverage-final.json"
  kmark 0
  pmark 0
  dmark 0
  jmark 0
  rmark 0
  gmark 0
  ymark 0
  emark 0
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
# `unit python` 의 기록 — 종료코드 · 지금 JSON 의 sha1 · 경계 파일의 지금 sha1(coverage.py 의 JSON 에는 소스 해시가 없다 — gmark 와 같은 꼴).
ymark() { # exit
  printf '{"run":"python","suite":"unit","exit":%s,"data_sha1":"%s","files":{"%s":"%s"}}\n' "$1" \
    "$(sha1sum "$D/python.unit.json" | cut -d' ' -f1)" "$Y" "$(sha1sum "$T/$Y" | cut -d' ' -f1)" > "$D/python.unit.run.json"
}
# `unit node` 의 기록 — 종료코드 · coverage-v8 판 · 지금 데이터의 sha1 · 경계 파일의 지금 sha1(istanbul JSON 에는 소스 해시가 없다 — ymark 와
# 같은 꼴).
emark() { # exit
  printf '{"run":"node","suite":"unit","exit":%s,"coverage_v8":"5.1.0","data_sha1":"%s","files":{"%s":"%s"}}\n' "$1" \
    "$(sha1sum "$D/node.unit/coverage-final.json" | cut -d' ' -f1)" "$E" "$(sha1sum "$T/$E" | cut -d' ' -f1)" > "$D/node.unit.run.json"
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

run unit-report python "$T" --out "$D"
assert_eq 0 "$RC" "[python] 측정이 장부와 같으면 exit 0 — 출력: $OUT"
assert_contains "$OUT" "/python.unit.json (coverage.py 7.15.0 · lines · branch arcs)" "[python] 데이터 · coverage.py 판 · 가지 측정을 찍는다"
assert_line "$OUT" "  UNREACHED $Y:17 AuthClient.exchange · 1 line · 1 branch · defensive: the drive never sends an empty code" "[python] 제 줄의 실패 갈래 — 놓친 줄 · 놓친 가지"
assert_line "$OUT" "  UNREACHED $Y:22 AuthClient.scope · 0 lines · 1 branch · open-gap" "[python] 줄이 다 돌아도 else 없는 if 의 안 탄 거짓 쪽은 가지로 센다 · why 가 열린 항목 id"
assert_line "$OUT" "  UNREACHED $Y:31 AuthClient.apply.one · 3 lines · 2 branches · unreachable: the lines and arms sit in apply's nested def — coverage.py keys it as its own region" "[python] 중첩 def 는 제 영역이다(감싼 함수.제 이름)"
assert_not_contains "$OUT" "AuthClient.apply ·" "[python] 중첩 def 의 줄 · 가지는 감싼 함수의 것이 아니다 — 제 줄이 다 돈 apply 는 목록에 없다"
assert_line "$OUT" "  UNREACHED $Y:38 AuthClient.token · 1 line · 1 branch · integration: an async def is a function region like any other — the drive never sends an empty code" "[python] async def 도 같은 함수 영역이다"
assert_line "$OUT" "  UNREACHED $Y:43 AuthClient.describe · 1 line · 0 branches · integration: the drive never calls it" "[python] 안 부른 메서드"
assert_line "$OUT" "  UNREACHED $Y:46 AuthClient.logout_url · 1 line · 0 branches · integration: the drive never calls it — the integration test does, outside the unit run" "[python] 통합 구동만 부르는 메서드 — 레인의 단위 명령(-m \"not integration\")이 그 시험을 거른다"
# ⚠️ 알려진 틈을 고정한다 — coverage.py 의 가지는 줄 사이의 호(arc)다: 한 줄 조건식(`a if c else b`) · `and` · `or` 의 안 탄 쪽은 호가 아니라
# 줄로도 가지로도 안 보인다(도구 머리 주석). 이 단언이 깨지면 coverage.py 가 그것을 재게 된 것이다 — 머리 주석과 장부를 함께 고칠 때다.
assert_not_contains "$OUT" "AuthClient.fallback" "[python] 한 줄 조건식의 안 탄 쪽은 가지가 아니다 — 알려진 틈"
assert_not_contains "$OUT" "AuthClient.__init__" "[python] 다 닿는 메서드는 목록에 없다"
assert_not_contains "$OUT" "Config" "[python] 경계 밖 파일은 목록에 없다"
assert_line "$OUT" "unit-unreached [python]: OK — 6 functions with code the unit suite never reaches (7 lines · 5 branches), each recorded in scripts/unit-unreached.json" "[python] 요약"

run unit-report node "$T" --out "$D"
assert_eq 0 "$RC" "[node] 측정이 장부와 같으면 exit 0 — 출력: $OUT"
assert_contains "$OUT" "/node.unit/coverage-final.json (@vitest/coverage-v8 5.1.0 · istanbul statements · if and switch arms)" "[node] 데이터 · coverage-v8 판 · 세는 것을 찍는다"
assert_line "$OUT" "  UNREACHED $E:10 AuthClient.token · 1 statement · 1 branch · integration: a function-valued property is a range like a method — the drive never sends an empty code" "[node] 함수를 값으로 받는 속성도 제 범위다 — 머리 줄의 대입은 그 함수의 문장이 아니다"
assert_line "$OUT" "  UNREACHED $E:19 AuthClient.static from · 1 statement · 1 branch · defensive: the drive never sends an empty realm — a static member keys with the static prefix" "[node] static 멤버의 키는 static 이 붙는다(통합 소유자와 같은 이름)"
assert_line "$OUT" "  UNREACHED $E:26 AuthClient.exchange · 1 statement · 1 branch · defensive: the drive never sends an empty code" "[node] 제 문장의 실패 갈래 — 놓친 문장 · 놓친 가지"
assert_line "$OUT" "  UNREACHED $E:33 AuthClient.scope · 0 statements · 1 branch · open-gap" "[node] 문장이 다 돌아도 else 없는 if 의 안 탄 거짓 쪽은 가지로 센다 · why 가 열린 항목 id"
assert_line "$OUT" "  UNREACHED $E:44 AuthClient.pick · 1 statement · 1 branch · unreachable: the statement and arm sit in pick's callback — the key is the member" "[node] 콜백의 안 돈 문장 · 안 탄 갈래는 감싼 멤버의 수다 — 그 줄의 ?? 의 안 탄 쪽은 더하지 않는다"
assert_line "$OUT" "  UNREACHED $E:54 AuthClient.kind · 1 statement · 1 branch · defensive: the drive passes 1 and 2 only — each switch case is an arm" "[node] switch 의 안 탄 case 도 가지다"
assert_line "$OUT" "  UNREACHED $E:69 AuthClient.#load · 1 statement · 1 branch · defensive: the drive loads once — a private member keys with #" "[node] private 멤버의 키는 # 이름이다"
assert_line "$OUT" "  UNREACHED $E:77 AuthClient.describe · 1 statement · 0 branches · integration: the drive never calls it" "[node] 안 부른 메서드"
assert_line "$OUT" "  UNREACHED $E:81 AuthClient.logoutUrl · 1 statement · 0 branches · integration: the drive never calls it — the integration test does, outside the unit run" "[node] 통합 구동만 부르는 메서드 — 레인 설정의 include(test/unit)가 그 구동을 싣지 않는다"
# ⚠️ 알려진 틈을 고정한다 — 식 안의 결정(조건식 `?:` · `&&` · `||` · `??` · 기본 인자)은 세지 않는다: 문장이 다 도는 함수의 그 안 탄 쪽은 목록에
# 안 보인다(도구 머리 주석). 이 단언이 깨지면 리더가 그 갈래를 세게 된 것이다 — 머리 주석과 장부를 함께 고칠 때다.
assert_not_contains "$OUT" "AuthClient.fallback" "[node] 조건식의 안 탄 쪽은 가지로 세지 않는다 — 알려진 틈"
assert_not_contains "$OUT" "AuthClient.load ·" "[node] 다 닿는 멤버는 목록에 없다"
assert_not_contains "$OUT" "AuthClient.constructor" "[node] 다 닿는 매개변수 속성 생성자는 목록에 없다"
assert_not_contains "$OUT" " helper ·" "[node] 다 닿는 최상위 함수는 목록에 없다"
assert_not_contains "$OUT" "Config" "[node] 경계 밖 파일은 목록에 없다"
assert_line "$OUT" "unit-unreached [node]: OK — 9 functions with code the unit suite never reaches (8 statements · 7 branches), each recorded in scripts/unit-unreached.json" "[node] 요약 — 문장과 가지로 센다"

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
# python — 다 닿던 __init__ 의 줄을 안 돈 것으로(장부에 없다).
ufresh
sed -i 's#"AuthClient.__init__": {"executed_lines": \[15\], "summary": {"covered_lines": 1, "num_statements": 1, "percent_covered": 100.0, "percent_covered_display": "100", "missing_lines": 0,#"AuthClient.__init__": {"executed_lines": [], "summary": {"covered_lines": 0, "num_statements": 1, "percent_covered": 0.0, "percent_covered_display": "0", "missing_lines": 1,#' "$D/python.unit.json"
ymark 0
assert_contains "$(cat "$D/python.unit.json")" '"AuthClient.__init__": {"executed_lines": [], "summary": {"covered_lines": 0, "num_statements": 1,' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 1 "$RC" "[python] 장부에 없는 미도달 함수는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [python] unrecorded unreached code $Y:AuthClient.__init__ — the unit suite never reaches 1 line · 0 branches of it: test that code, or record why in scripts/unit-unreached.json" "[python] 새 미도달"
# 줄은 그대로인데 가지 하나가 새로 안 돈다 — exchange 의 탄 거짓 쪽(18 → 20)을 안 탄 것으로(줄만 세면 못 본다).
ufresh
sed -i 's#\("AuthClient.exchange": {[^}]*"covered_branches": \)1, "missing_branches": 1,#\10, "missing_branches": 2,#' "$D/python.unit.json"
ymark 0
assert_contains "$(grep -o '"AuthClient.exchange": {[^}]*}' "$D/python.unit.json")" '"covered_branches": 0, "missing_branches": 2,' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 1 "$RC" "[python] 줄 수가 같아도 놓친 가지가 늘면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [python] $Y:AuthClient.exchange: the unit run leaves 1 line · 2 branches unreached, scripts/unit-unreached.json records 1 line · 1 branch — test what the unit suite does not reach, or record why and correct the counts" "[python] 가지만 바뀐 수"
# node — 다 닿던 load 의 문장(66 — 문장 26)을 0 회로(장부에 없다).
ufresh
sed -i 's#"26":1,"27":1#"26":0,"27":1#' "$D/node.unit/coverage-final.json"
emark 0
assert_contains "$(cat "$D/node.unit/coverage-final.json")" '"26":0,"27":1' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 1 "$RC" "[node] 장부에 없는 미도달 함수는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [node] unrecorded unreached code $E:AuthClient.load — the unit suite never reaches 1 statement · 0 branches of it: test that code, or record why in scripts/unit-unreached.json" "[node] 새 미도달"
# 문장은 그대로인데 갈래 하나가 새로 안 탄다 — exchange 의 if(가지 2)의 탄 거짓 쪽을 0 회로(문장만 세면 못 본다).
ufresh
sed -i 's#"2":\[0,2\]#"2":[0,0]#' "$D/node.unit/coverage-final.json"
emark 0
assert_contains "$(cat "$D/node.unit/coverage-final.json")" '"2":[0,0]' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 1 "$RC" "[node] 문장 수가 같아도 놓친 가지가 늘면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [node] $E:AuthClient.exchange: the unit run leaves 1 statement · 2 branches unreached, scripts/unit-unreached.json records 1 statement · 1 branch — test what the unit suite does not reach, or record why and correct the counts" "[node] 가지만 바뀐 수"

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
# python — 중첩 def 의 줄 · 가지는 제 영역의 수다: 장부에서 지우면 그 이름(감싼 함수.제 이름)으로 DRIFT 다(감싼 apply 로 새지 않는다).
ufresh
sed -i '/auth_client\.py:AuthClient\.apply\.one"/,/},/d' "$L"
assert_not_contains "$(cat "$L")" "auth_client.py:AuthClient.apply.one" "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 1 "$RC" "[python] 중첩 def 의 놓친 줄 · 가지가 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [python] unrecorded unreached code $Y:AuthClient.apply.one — the unit suite never reaches 3 lines · 2 branches of it" "[python] 중첩 def — 제 영역의 키"
# 줄이 다 도는 함수의 안 탄 갈래(else 없는 if 의 거짓 쪽)만 있는 함수 — 장부에서 지우면 DRIFT 다(줄만 세는 장부는 이것을 못 본다).
ufresh
sed -i '/auth_client\.py:AuthClient\.scope"/,/},/d' "$L"
assert_not_contains "$(cat "$L")" "auth_client.py:AuthClient.scope" "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 1 "$RC" "[python] 다 도는 줄의 안 탄 갈래가 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [python] unrecorded unreached code $Y:AuthClient.scope — the unit suite never reaches 0 lines · 1 branch of it" "[python] 거짓 쪽의 호"
# node — 콜백 안의 안 돈 문장 · 안 탄 갈래(pick 의 find 콜백)는 장부에서 지우면 감싼 멤버 이름으로 DRIFT 다(fnMap 의 (anonymous_N) 으로 새지 않는다).
ufresh
sed -i '/auth_client\.ts:AuthClient\.pick"/,/},/d' "$L"
assert_not_contains "$(cat "$L")" "auth_client.ts:AuthClient.pick" "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 1 "$RC" "[node] 콜백 안의 놓친 문장 · 가지가 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [node] unrecorded unreached code $E:AuthClient.pick — the unit suite never reaches 1 statement · 1 branch of it" "[node] 콜백 — 감싼 멤버의 키"
assert_not_contains "$OUT" "anonymous" "[node] istanbul 의 순번 이름((anonymous_N))이 키로 새지 않는다"
# 문장이 다 도는 함수의 안 탄 갈래(else 없는 if 의 거짓 쪽)만 있는 함수 — 장부에서 지우면 DRIFT 다(문장만 세는 장부는 이것을 못 본다).
ufresh
sed -i '/auth_client\.ts:AuthClient\.scope"/,/},/d' "$L"
assert_not_contains "$(cat "$L")" "auth_client.ts:AuthClient.scope" "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 1 "$RC" "[node] 다 도는 문장의 안 탄 갈래가 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [node] unrecorded unreached code $E:AuthClient.scope — the unit suite never reaches 0 statements · 1 branch of it" "[node] 거짓 쪽의 갈래"
# switch 의 안 탄 case — 장부에서 지우면 DRIFT 다.
ufresh
sed -i '/auth_client\.ts:AuthClient\.kind"/,/},/d' "$L"
assert_not_contains "$(cat "$L")" "auth_client.ts:AuthClient.kind" "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 1 "$RC" "[node] switch 의 안 탄 case 가 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [node] unrecorded unreached code $E:AuthClient.kind — the unit suite never reaches 1 statement · 1 branch of it" "[node] switch 의 case"

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
# python — 줄 수와 가지 수를 따로 대조한다(장부의 줄 수만 · 가지 수만 바꾼다).
ufresh
sed -i '/auth_client\.py:AuthClient\.exchange"/,/}/ s#"lines": 1,#"lines": 2,#' "$L"
assert_contains "$(grep -A1 'auth_client.py:AuthClient.exchange"' "$L")" '"lines": 2,' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 1 "$RC" "[python] 줄 수가 다르면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [python] $Y:AuthClient.exchange: the unit run leaves 1 line · 1 branch unreached, scripts/unit-unreached.json records 2 lines · 1 branch — the unit suite reaches more of it now: lower the counts" "[python] 바뀐 줄 수 — 장부보다 덜 놓쳤다"
ufresh
sed -i '/auth_client\.py:AuthClient\.apply\.one"/,/}/ s#"branches": 2,#"branches": 1,#' "$L"
assert_contains "$(grep -A2 'auth_client.py:AuthClient.apply.one"' "$L")" '"branches": 1,' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 1 "$RC" "[python] 가지 수만 달라도 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [python] $Y:AuthClient.apply.one: the unit run leaves 3 lines · 2 branches unreached, scripts/unit-unreached.json records 3 lines · 1 branch — test what the unit suite does not reach, or record why and correct the counts" "[python] 바뀐 가지 수 — 장부보다 더 놓쳤다"
# node — 문장 수와 가지 수를 따로 대조한다(장부의 문장 수만 · 가지 수만 바꾼다).
ufresh
sed -i '/auth_client\.ts:AuthClient\.token"/,/}/ s#"statements": 1,#"statements": 2,#' "$L"
assert_contains "$(grep -A1 'auth_client.ts:AuthClient.token"' "$L")" '"statements": 2,' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 1 "$RC" "[node] 문장 수가 다르면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [node] $E:AuthClient.token: the unit run leaves 1 statement · 1 branch unreached, scripts/unit-unreached.json records 2 statements · 1 branch — the unit suite reaches more of it now: lower the counts and check the why" "[node] 바뀐 문장 수 — 장부보다 덜 놓쳤다"
ufresh
sed -i '/auth_client\.ts:AuthClient\.kind"/,/}/ s#"branches": 1,#"branches": 0,#' "$L"
assert_contains "$(grep -A2 'auth_client.ts:AuthClient.kind"' "$L")" '"branches": 0,' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 1 "$RC" "[node] 가지 수만 달라도 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [node] $E:AuthClient.kind: the unit run leaves 1 statement · 1 branch unreached, scripts/unit-unreached.json records 1 statement · 0 branches — test what the unit suite does not reach, or record why and correct the counts" "[node] 바뀐 가지 수 — 장부보다 더 놓쳤다"

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
# python — 모듈 수준 영역(이름 "")은 함수가 아니다: 그것을 가리키는 항목도 데이터에 없는 함수의 항목이다.
ufresh
sed -i "s#\"python\": {#\"python\": {\n    \"$Y:AuthClient.__init__\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: stale\" },\n    \"$Y:AuthClient.gone\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: renamed\" },\n    \"$Y:\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: module level\" },\n    \"python/src/keycloak_sdk/config.py:Config.valid\": { \"lines\": 1, \"branches\": 0, \"why\": \"integration: outside\" },#" "$L"
assert_contains "$(cat "$L")" "\"$Y:AuthClient.gone\": { \"lines\": 1, \"branches\": 0," "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 1 "$RC" "[python] 낡은 항목은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [python] stale entry $Y:AuthClient.__init__ — the unit run reaches all of it now; drop the entry" "[python] 다 닿는 메서드의 항목"
assert_contains "$OUT" "DRIFT [python] stale entry $Y:AuthClient.gone — the data of $Y has no such function (renamed or removed?)" "[python] 없는 함수의 항목"
assert_contains "$OUT" "DRIFT [python] stale entry $Y: — the data of $Y has no such function" "[python] 모듈 수준 영역은 함수가 아니다"
assert_contains "$OUT" "DRIFT [python] scripts/unit-unreached.json: entry python/src/keycloak_sdk/config.py:Config.valid names a file outside the boundary derived from python/pyproject.toml:12" "[python] 경계 밖 파일의 항목"
# node — 클래스 자신은 함수가 아니다: 그것을 가리키는 항목도 데이터에 없는 함수의 항목이다(클래스 필드의 초기값은 어느 함수의 것도 아니다).
ufresh
sed -i "s#\"node\": {#\"node\": {\n    \"$E:AuthClient.load\": { \"statements\": 1, \"branches\": 0, \"why\": \"integration: stale\" },\n    \"$E:AuthClient.gone\": { \"statements\": 1, \"branches\": 0, \"why\": \"integration: renamed\" },\n    \"$E:AuthClient\": { \"statements\": 1, \"branches\": 0, \"why\": \"integration: the class itself\" },\n    \"node/src/config.ts:Config.valid\": { \"statements\": 1, \"branches\": 0, \"why\": \"integration: outside\" },#" "$L"
assert_contains "$(cat "$L")" "\"$E:AuthClient.gone\": { \"statements\": 1, \"branches\": 0," "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 1 "$RC" "[node] 낡은 항목은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [node] stale entry $E:AuthClient.load — the unit run reaches all of it now; drop the entry" "[node] 다 닿는 멤버의 항목"
assert_contains "$OUT" "DRIFT [node] stale entry $E:AuthClient.gone — the data of $E has no such function (renamed or removed?)" "[node] 없는 함수의 항목"
assert_contains "$OUT" "DRIFT [node] stale entry $E:AuthClient — the data of $E has no such function" "[node] 클래스는 함수가 아니다"
assert_contains "$OUT" "DRIFT [node] scripts/unit-unreached.json: entry node/src/config.ts:Config.valid names a file outside the boundary derived from node/vitest.config.ts:11" "[node] 경계 밖 파일의 항목"

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
run unit-report python "$T" --out "$D"
assert_eq 1 "$RC" "[python] 닫힌 등록부 항목은 why 가 아니다 — exit 1"
assert_contains "$OUT" "DRIFT [python] $Y:AuthClient.scope: why \"closed-gap\"" "[python] 닫힌 id"
run unit-report node "$T" --out "$D"
assert_eq 1 "$RC" "[node] 닫힌 등록부 항목은 why 가 아니다 — exit 1"
assert_contains "$OUT" "DRIFT [node] $E:AuthClient.scope: why \"closed-gap\"" "[node] 닫힌 id"
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
# python — 같은 무결성 판정(데이터 · 다른 바이트 · 단위 기록 · 기록 없음 · 기록 뒤 바뀐 데이터 · 경계 해시 없는 기록 · 실패한 실행 · 데이터에 없는
# 경계 파일 · 가지 없는 데이터 · 못 읽는 수 · 같은 이름 영역의 덮어쓰기 · 어느 함수에도 못 붙이는 안 돈 줄 · 안 탄 호 · 공허한 실행)과 장부의 꼴.
ufresh
rm "$D/python.unit.json"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 데이터가 없으면 exit 2"
assert_contains "$OUT" "FAIL [python] no coverage data at" "[python] 데이터 없음"
assert_contains "$OUT" "run the unit suite first (node scripts/integration-coverage.mjs unit python)" "[python] 다시 돌릴 명령"
ufresh
printf '# changed after the run\n' >> "$T/$Y"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 다른 바이트의 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [python] $Y: the data was taken from other bytes" "[python] 다른 바이트"
ufresh
sed -i 's#"suite":"unit",##' "$D/python.unit.run.json"
assert_not_contains "$(cat "$D/python.unit.run.json")" '"suite"' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 단위 실행의 것이 아닌 기록(suite 없음)은 exit 2"
assert_contains "$OUT" "FAIL [python] no record that \`unit python\` wrote this data" "[python] 단위 기록 아님"
ufresh
rm "$D/python.unit.run.json"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 기록이 없는 데이터(손으로 돌린 coverage)는 exit 2"
assert_contains "$OUT" "FAIL [python] no record that \`unit python\` wrote this data" "[python] 기록 없음"
ufresh
printf ' ' >> "$D/python.unit.json"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 기록 뒤 바뀐 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/python.unit.json is not the data \`unit python\` recorded" "[python] 데이터의 sha1"
ufresh
sed -i 's#"files":{[^}]*}#"files":null#' "$D/python.unit.run.json"
assert_contains "$(cat "$D/python.unit.run.json")" '"files":null' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 경계 해시가 없는 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [python] the record has no boundary hashes" "[python] 실행 중에 바뀐 경계 파일"
ufresh
ymark 1
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 실패한 실행의 데이터는 exit 2"
assert_contains "$OUT" "FAIL [python] the run that wrote this data exited 1 — the data of a failed run is partial" "[python] 실패한 실행"
ufresh
sed -i 's#"src\\\\keycloak_sdk\\\\auth_client\.py": {#"src\\\\keycloak_sdk\\\\gone.py": {#' "$D/python.unit.json"
ymark 0
assert_contains "$(cat "$D/python.unit.json")" 'keycloak_sdk\\gone.py": {' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 경계 파일이 데이터에 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [python] $Y is not in the coverage data" "[python] 데이터에 없는 경계 파일"
# 가지 — 가지 없이 잰 데이터(branch = true 가 없는 실행)는 가지 0 개가 아니다 · 못 읽는 수는 0 으로 세지 않는다.
ufresh
sed -i 's#"branch_coverage": true#"branch_coverage": false#' "$D/python.unit.json"
ymark 0
assert_contains "$(cat "$D/python.unit.json")" '"branch_coverage": false' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 가지 없이 잰 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/python.unit.json has no branch arcs (meta.branch_coverage is not true) — the run measured lines only" "[python] 가지 없는 데이터"
ufresh
sed -i 's#\("AuthClient.exchange": {[^}]*"covered_branches": 1, \)"missing_branches": 1,#\1"missing_branches": -1,#' "$D/python.unit.json"
ymark 0
assert_contains "$(grep -o '"AuthClient.exchange": {[^}]*}' "$D/python.unit.json")" '"missing_branches": -1,' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 못 읽는 가지 수는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [python] $Y: cannot read the line and branch counts of AuthClient.exchange" "[python] 못 읽는 수"
# 같은 이름의 영역 — coverage.py 는 영역을 이름으로 묶어 뒤의 것이 앞의 것을 덮는다(JSON 의 중복 키도 뒤의 것이 이긴다). describe 를
# 뒤에 오는 logout_url 의 이름으로 바꾸면 describe 의 문장이 영역에서 사라진다.
ufresh
sed -i 's#"AuthClient.describe": {#"AuthClient.logout_url": {#' "$D/python.unit.json"
ymark 0
assert_not_contains "$(cat "$D/python.unit.json")" '"AuthClient.describe": {' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 같은 이름의 영역이 덮어쓰이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [python] $Y: function regions add up to 29 of 30 statements — coverage.py keys regions by name, so a same-named function overwrote another" "[python] 덮어써진 영역을 회계로 잡는다"
# 모듈 수준(어느 함수에도 안 드는 영역 "" — 모듈 · 클래스 몸통)의 안 돈 줄 · 안 탄 호는 어느 함수에도 못 붙인다 — FAIL 이다(go 의 패키지
# 수준 함수 리터럴 · ruby 의 메서드 밖 갈래와 같은 판정). import 때 도는 줄이다 — 경계 파일을 import 한 실행에서 안 돌았으면 조건이 있다.
ufresh
sed -i 's#"": {"executed_lines": \[3, 5, 10, 13, 14, 17, 22, 27, 30, 38, 43, 46\], "summary": {"covered_lines": 12, "num_statements": 12, "percent_covered": 100.0, "percent_covered_display": "100", "missing_lines": 0,#"": {"executed_lines": [3, 5, 13, 14, 17, 22, 27, 30, 38, 43, 46], "summary": {"covered_lines": 11, "num_statements": 12, "percent_covered": 91.66666666666667, "percent_covered_display": "92", "missing_lines": 1,#' "$D/python.unit.json"
ymark 0
assert_contains "$(cat "$D/python.unit.json")" '"": {"executed_lines": [3, 5, 13, 14, 17, 22, 27, 30, 38, 43, 46], "summary": {"covered_lines": 11, "num_statements": 12,' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 모듈 수준의 안 돈 줄은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [python] $Y: 1 of 12 module-level statements (outside every function — module and class bodies) never ran — no function can be credited with them" "[python] 모듈 수준 줄"
ufresh
sed -i 's#\("": {"executed_lines": \[3, 5, 10, 13, 14, 17, 22, 27, 30, 38, 43, 46\], "summary": {[^}]*"num_branches": \)0, "num_partial_branches": 0, "covered_branches": 0, "missing_branches": 0#\12, "num_partial_branches": 1, "covered_branches": 1, "missing_branches": 1#' "$D/python.unit.json"
ymark 0
assert_contains "$(cat "$D/python.unit.json")" '"num_branches": 2, "num_partial_branches": 1, "covered_branches": 1, "missing_branches": 1, "percent_branches_covered": 100.0' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 모듈 수준의 안 탄 호는 줄이 다 돌았어도 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [python] $Y: 1 of 2 module-level branch arcs (outside every function — module and class bodies) were never taken — no function can be credited with them" "[python] 모듈 수준 호"
# 경계 파일을 한 번도 import 하지 않은 실행 — 측정 실패가 모듈 수준 판정보다 먼저다(모듈 수준 줄이 전부 안 돈 것으로 읽지 않는다).
ufresh
cp "$UFIX/data/python-zero.unit.json" "$D/python.unit.json"
ymark 0
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[python] 경계 함수의 몸통을 하나도 안 돈 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [python] the run executed 0 of 18 boundary statements inside functions — a measurement failure, not a low number (did the unit tests run against this tree?)" "[python] 공허한 실행 — 모듈 수준 판정보다 먼저다"
assert_not_contains "$OUT" "module-level" "[python] 공허한 실행은 모듈 수준의 안 돈 줄로 읽지 않는다"
# 장부의 꼴 — python 항목은 { branches, lines, why } 다: 가지를 빼거나 문장으로 적으면 exit 2.
ufresh
sed -i '/auth_client\.py:AuthClient\.exchange"/,/}/ { /"branches": 1,/d }' "$L"
assert_not_contains "$(grep -A3 'auth_client.py:AuthClient.exchange"' "$L")" '"branches"' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] python 항목에 branches 가 없으면 exit 2"
assert_contains "$OUT" "FAIL [python] scripts/unit-unreached.json: python[\"$Y:AuthClient.exchange\"] must be { branches, lines, why }" "[ledger] python 꼴 — 가지"
ufresh
sed -i '/auth_client\.py:AuthClient\.exchange"/,/}/ s#"lines": 1,#"statements": 1,#' "$L"
assert_contains "$(grep -A1 'auth_client.py:AuthClient.exchange"' "$L")" '"statements": 1,' "(변이가 착지했는지 먼저 본다)"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] python 항목을 문장으로 적으면 exit 2(문장은 go 의 것이다)"
assert_contains "$OUT" "FAIL [python] scripts/unit-unreached.json: python[\"$Y:AuthClient.exchange\"] must be { branches, lines, why }" "[ledger] python 꼴 — 줄"
# node — 같은 무결성 판정(데이터 · 다른 바이트 · 단위 기록 · 기록 없음 · 기록 뒤 바뀐 데이터 · 경계 해시 없는 기록 · 실패한 실행 · 데이터에 없는
# 경계 파일 · 못 읽는 수 · 모르는 가지 종류 · 어느 함수에도 못 붙이는 안 돈 문장 · 안 탄 갈래 · 공허한 실행)과 장부의 꼴(문장 · 가지).
ufresh
rm "$D/node.unit/coverage-final.json"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 데이터가 없으면 exit 2"
assert_contains "$OUT" "FAIL [node] no coverage data at" "[node] 데이터 없음"
assert_contains "$OUT" "run the unit suite first (node scripts/integration-coverage.mjs unit node)" "[node] 다시 돌릴 명령"
ufresh
printf '// changed after the run\n' >> "$T/$E"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 다른 바이트의 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] $E: the data was taken from other bytes" "[node] 다른 바이트"
ufresh
sed -i 's#"suite":"unit",##' "$D/node.unit.run.json"
assert_not_contains "$(cat "$D/node.unit.run.json")" '"suite"' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 단위 실행의 것이 아닌 기록(suite 없음)은 exit 2"
assert_contains "$OUT" "FAIL [node] no record that \`unit node\` wrote this data" "[node] 단위 기록 아님"
ufresh
rm "$D/node.unit.run.json"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 기록이 없는 데이터(손으로 돌린 vitest)는 exit 2"
assert_contains "$OUT" "FAIL [node] no record that \`unit node\` wrote this data" "[node] 기록 없음"
ufresh
printf ' ' >> "$D/node.unit/coverage-final.json"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 기록 뒤 바뀐 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/node.unit/coverage-final.json is not the data \`unit node\` recorded" "[node] 데이터의 sha1"
ufresh
sed -i 's#"files":{[^}]*}#"files":null#' "$D/node.unit.run.json"
assert_contains "$(cat "$D/node.unit.run.json")" '"files":null' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 경계 해시가 없는 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] the record has no boundary hashes" "[node] 실행 중에 바뀐 경계 파일"
ufresh
emark 1
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 실패한 실행의 데이터는 exit 2"
assert_contains "$OUT" "FAIL [node] the run that wrote this data exited 1 — the data of a failed run is partial" "[node] 실패한 실행"
ufresh
sed -i 's#auth_client\.ts"#gone.ts"#g' "$D/node.unit/coverage-final.json"
emark 0
assert_not_contains "$(cat "$D/node.unit/coverage-final.json")" 'auth_client.ts"' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 경계 파일이 데이터에 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] $E is not in the coverage data" "[node] 데이터에 없는 경계 파일"
# 못 읽는 수는 0 으로 세지 않는다 — 음수 갈래 횟수 · 음수 문장 횟수.
ufresh
sed -i 's#"2":\[0,2\]#"2":[-1,2]#' "$D/node.unit/coverage-final.json"
emark 0
assert_contains "$(cat "$D/node.unit/coverage-final.json")" '"2":[-1,2]' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 못 읽는 갈래 횟수는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] $E: cannot read the arm counts of the if branch at line 27" "[node] 못 읽는 갈래 횟수"
ufresh
sed -i 's#"s":{"0":1,"1":1#"s":{"0":-1,"1":1#' "$D/node.unit/coverage-final.json"
emark 0
assert_contains "$(cat "$D/node.unit/coverage-final.json")" '"s":{"0":-1,"1":1' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 못 읽는 문장 횟수는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] $E: cannot read the count of statement 0" "[node] 못 읽는 문장 횟수"
# 모르는 가지 종류 — 세지 않는 종류인지 셀 종류인지 모르는 갈래를 조용히 버리지 않는다(새 판의 도구가 새 결정을 실으면 여기서 멈춘다).
ufresh
sed -i 's#"type":"switch"#"type":"try"#' "$D/node.unit/coverage-final.json"
emark 0
assert_contains "$(cat "$D/node.unit/coverage-final.json")" '"type":"try"' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 모르는 가지 종류는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] $E: the branch at line 55 is of kind try, which this reader does not know" "[node] 모르는 가지 종류"
# 어느 함수에도 안 드는 문장(모듈 코드 · 클래스 필드의 초기값 · 함수 값의 대입) · 갈래의 안 돈 쪽은 어느 함수에도 못 붙인다 — FAIL 이다(go 의
# 패키지 수준 함수 리터럴 · python 의 모듈 수준 · ruby 의 메서드 밖 갈래와 같은 판정). 바깥 문장은 둘이다 — 2 행 LIMIT · 10 행 token 의 대입.
ufresh
sed -i 's#"s":{"0":1,"1":1#"s":{"0":0,"1":1#' "$D/node.unit/coverage-final.json"
emark 0
assert_contains "$(cat "$D/node.unit/coverage-final.json")" '"s":{"0":0,"1":1' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 어느 함수에도 안 드는 안 돈 문장은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] $E: 1 of 2 module-level statements (outside every function — module code, class fields, the assignment of a function value) never ran — no function can be credited with them" "[node] 모듈 수준 문장"
ufresh
sed -i 's#"branchMap":{"0":{"loc":{"start":{"line":11,"column":4}#"branchMap":{"0":{"loc":{"start":{"line":2,"column":4}#' "$D/node.unit/coverage-final.json"
emark 0
assert_contains "$(cat "$D/node.unit/coverage-final.json")" '"branchMap":{"0":{"loc":{"start":{"line":2,"column":4}' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 어느 함수에도 안 드는 안 탄 갈래는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] $E:2: the if branch there sits outside every function and has an arm the run never took — no function can be credited with it" "[node] 모듈 수준 갈래"
# 경계 파일을 한 번도 불러오지 않은 실행 — 측정 실패가 모듈 수준 판정보다 먼저다(모듈 수준 문장이 전부 안 돈 것으로 읽지 않는다).
ufresh
sed "s#@ROOT@#$_r#g" "$UFIX/data/node-zero.unit.json" > "$D/node.unit/coverage-final.json"
emark 0
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 경계 문장을 하나도 안 돈 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] the run executed 0 of 33 boundary statements — a measurement failure, not a low number (did the unit tests run against this tree?)" "[node] 공허한 실행 — 모듈 수준 판정보다 먼저다"
assert_not_contains "$OUT" "module-level" "[node] 공허한 실행은 모듈 수준의 안 돈 문장으로 읽지 않는다"
# 장부의 꼴 — node 항목은 { branches, statements, why } 다: 줄로 적거나 가지를 빼면 exit 2.
ufresh
sed -i '/auth_client\.ts:AuthClient\.exchange"/,/}/ s#"statements": 1,#"lines": 1,#' "$L"
assert_contains "$(grep -A1 'auth_client.ts:AuthClient.exchange"' "$L")" '"lines": 1,' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] node 항목을 줄로 적으면 exit 2(node 는 문장을 센다) — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] scripts/unit-unreached.json: node[\"$E:AuthClient.exchange\"] must be { branches, statements, why } — whole-number counts and a non-empty why" "[ledger] node 꼴 — 문장"
ufresh
sed -i '/auth_client\.ts:AuthClient\.exchange"/,/}/ { /"branches": 1,/d }' "$L"
assert_not_contains "$(grep -A3 'auth_client.ts:AuthClient.exchange"' "$L")" '"branches"' "(변이가 착지했는지 먼저 본다)"
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] node 항목에 branches 가 없으면 exit 2"
assert_contains "$OUT" "FAIL [node] scripts/unit-unreached.json: node[\"$E:AuthClient.exchange\"] must be { branches, statements, why }" "[ledger] node 꼴 — 가지"
ufresh
run unit-report scala "$T" --out "$D"
assert_eq 2 "$RC" "[cli] 재지 않는 언어는 usage(exit 2)"
assert_contains "$OUT" "the unit-unreached ledger measures kotlin · php · dotnet · java · ruby · go · python · node · rust — got scala" "[cli] usage 문구"

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
assert_line "$OUT" "[python] unit-unreached: 1 entry (open-masking 1)" "[check] python 장부"
assert_line "$OUT" "[node] unit-unreached: 1 entry (defensive 1)" "[check] node 장부"
fresh
sed -i '/auth\.ts:Masked\.describe"/,/}/ s#"statements": 1,#"lines": 1,#' "$T/scripts/unit-unreached.json"
assert_contains "$(grep -A1 'auth.ts:Masked.describe"' "$T/scripts/unit-unreached.json")" '"lines": 1,' "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 2 "$RC" "[check] node 항목을 줄로 적으면 데이터 없이도 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] scripts/unit-unreached.json: node[\"node/src/auth.ts:Masked.describe\"] must be { branches, statements, why }" "[check] node 꼴"
fresh
sed -i 's#"statements": 2,#"lines": 2,#' "$T/scripts/unit-unreached.json"
assert_contains "$(grep -A1 'go/admin.go:AdminClient.Close"' "$T/scripts/unit-unreached.json")" '"lines": 2,' "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 2 "$RC" "[check] go 항목을 줄로 적으면 데이터 없이도 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [go] scripts/unit-unreached.json: go[\"go/admin.go:AdminClient.Close\"] must be { statements, why }" "[check] go 꼴"
fresh
sed -i '/auth\.py:AuthClient\.token"/,/}/ { /"branches": 1,/d }' "$T/scripts/unit-unreached.json"
assert_not_contains "$(grep -A3 'auth.py:AuthClient.token"' "$T/scripts/unit-unreached.json")" '"branches"' "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 2 "$RC" "[check] python 항목에 branches 가 없으면 데이터 없이도 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [python] scripts/unit-unreached.json: python[\"python/src/keycloak_sdk/auth.py:AuthClient.token\"] must be { branches, lines, why }" "[check] python 꼴"
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

# ── (6) rust — llvm-cov lcov 의 줄(DA)을 소스의 이름 범위로 함수마다 센다(통합 리포트와 같은 리더 rustReport) ─────────────────────────
# 이 절은 rust 픽스처만 쓴다(데이터 · 구동의 출처는 머리). 단위 실행은 경계 파일 안의 cfg(test) 모듈을 싣는다 — 시험이지 경계 코드가
# 아니라 장부가 그 줄을 뺀다(통합 리포트는 같은 데이터에 FAIL 이다 — 아래). 단위 전용 판정 하나: 레코드가 없는 fn 은 줄을 셀 수 없어 FAIL.
RS=rust/src/auth_client.rs
# `unit rust` 의 기록 — 종료코드 · 지금 lcov 의 sha1 · 그 실행의 rustc(리포트가 찍기만 한다) · 경계 파일의 지금 sha1(lcov 에는 소스
# 해시가 없다 — gmark · ymark 와 같은 꼴).
rsmark() { # exit
  printf '{"run":"rust","suite":"unit","exit":%s,"data_sha1":"%s","rustc":"rustc 1.100.0 (0ef1bc386 2026-11-09)","files":{"%s":"%s"}}\n' "$1" \
    "$(sha1sum "$D/rust.unit.lcov" | cut -d' ' -f1)" "$RS" "$(sha1sum "$T/$RS" | cut -d' ' -f1)" > "$D/rust.unit.run.json"
}
# 단위 픽스처 트리 + rust 데이터 — lcov 의 SF 는 절대 경로다(통합 픽스처의 rust_data 와 같은 치환 · 뒤의 `\rust\src\…` 는 리더가 `/` 로
# 읽는다).
rsfresh() {
  ufresh
  _r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
  sed "s#@ROOT@#$_r#g" "$UFIX/data/rust.unit.lcov" > "$D/rust.unit.lcov"
  rsmark 0
}

# (가) 양성 — 측정 = 장부 → 0.
rsfresh
run unit-report rust "$T" --out "$D"
assert_eq 0 "$RC" "[rust] 측정이 장부와 같으면 exit 0 — 출력: $OUT"
assert_contains "$OUT" "/rust.unit.lcov (rustc 1.100.0 (0ef1bc386 2026-11-09) · lines (DA))" "[rust] 데이터 · 그 실행의 rustc 판(줄의 귀속을 바꾼다)을 찍는다"
assert_line "$OUT" "  UNREACHED $RS:28 AuthClient::exchange · 1 line · defensive: the drive never sends an empty code" "[rust] 제 줄의 실패 갈래 — 안 돈 줄(가지가 아니다)"
assert_line "$OUT" "  UNREACHED $RS:36 AuthClient::port · 1 line · open-gap" "[rust] rustfmt 가 끊은 사슬의 제 줄 map_err 클로저는 감싼 fn 의 안 돈 줄이다 · why 가 열린 항목 id"
assert_line "$OUT" "  UNREACHED $RS:49 AuthClient::pick · 4 lines · unreachable: the lines sit in pick's closure — the key is the enclosing fn" "[rust] 여러 줄 클로저의 안 돈 줄은 감싼 fn 의 수다"
assert_line "$OUT" "  UNREACHED $RS:60 AuthClient::token · 1 line · integration: an async fn's body is a record of its own inside the fn's range — the drive never sends an empty code" "[rust] poll 한 async fn — 몸통 레코드의 줄도 그 fn 의 것이다"
assert_line "$OUT" "  UNREACHED $RS:69 AuthClient::refresh · 2 lines · integration: the drive drops the future unpolled — the library's unit-test binary keeps the body's zero-count record" "[rust] 버린 퓨처의 async 몸통도 센다 — 라이브러리 단위 시험 바이너리의 0 회 레코드"
assert_line "$OUT" "  UNREACHED $RS:74 AuthClient::logout_url · 3 lines · integration: the drive never calls it — the integration test does, outside the unit run" "[rust] 통합 시험만 부르는 fn — #[ignore] 라 단위 실행은 컴파일만 한다"
assert_line "$OUT" "  UNREACHED $RS:79 AuthClient::convert · 3 lines · integration: nothing instantiates the generic — the library's unit-test binary keeps a zero-count record of it" "[rust] 인스턴스화 안 된 제네릭도 센다"
assert_line "$OUT" "  UNREACHED $RS:85 <AuthClient as fmt::Display>::fmt · 3 lines · integration: the drive never formats the client — a trait method keys as <Type as Trait>::name" "[rust] 트레이트 impl 의 메서드 — <타입 as 트레이트>::"
assert_line "$OUT" "  UNREACHED $RS:91 static DEFAULT_SCOPE · 4 lines · integration: nothing forces the static's closure — its lines are the static's" "[rust] static 의 클로저는 그 static 의 범위다"
# ⚠️ 알려진 틈을 고정한다 — 줄만 센다: 돈 호출과 같은 줄의 실패 클로저(fallback 의 `parse().map_err(…)`)는 그 줄이 돌아 안 보인다(port 의
# 제 줄 클로저와 갈린다 — 도구 머리 주석). 이 단언이 깨지면 툴체인이 그 줄을 클로저의 것으로 세게 된 것이다 — 머리 주석과 장부를 함께 고칠 때다.
assert_not_contains "$OUT" "AuthClient::fallback" "[rust] 돈 호출과 같은 줄의 실패 클로저는 줄로 안 보인다 — 알려진 틈"
# cfg(test) 모듈(realm_is_kept)은 단위 시험 자신이다 — 안 탄 갈래(panic! 줄 106)가 데이터에 0 회로 있어도 목록 · 모듈 수준 어디에도 없다.
assert_contains "$(cat "$D/rust.unit.lcov")" "DA:106,0" "[rust] (데이터에 cfg(test) 의 안 돈 줄이 있다 — 아래 둘이 공허하지 않다)"
assert_not_contains "$OUT" "realm_is_kept" "[rust] cfg(test) 모듈의 함수는 목록에 없다"
assert_not_contains "$OUT" "module level" "[rust] cfg(test) 의 안 돈 줄을 항목 밖 줄로 세지 않는다"
for _x in "AuthClient::new" "AuthClient::realm" "config.rs" "owned ·"; do
  assert_not_contains "$OUT" "$_x" "[rust] 다 닿는 fn · 경계 밖 파일 · macro_rules 는 목록에 없다: $_x"
done
assert_line "$OUT" "unit-unreached [rust]: OK — 9 functions with code the unit suite never reaches (22 lines), each recorded in scripts/unit-unreached.json" "[rust] 요약"
# cfg(test) 를 빼는 것이 하중을 진다 — 그 속성을 지우면 모듈이 보통 항목이 되어 그 안 탄 갈래가 장부에 없는 미도달로 든다(exit 1).
rsfresh
sed -i 's/^#\[cfg(test)\]$//' "$T/$RS"
assert_not_contains "$(cat "$T/$RS")" "#[cfg(test)]" "(변이가 착지했는지 먼저 본다)"
rsmark 0
run unit-report rust "$T" --out "$D"
assert_eq 1 "$RC" "[rust] cfg(test) 를 안 읽으면 그 모듈의 안 탄 갈래가 장부에 없는 미도달이다 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [rust] unrecorded unreached code $RS:tests::realm_is_kept — the unit suite never reaches 1 line of it" "[rust] cfg(test) 의 줄이 시험 함수의 것으로 샌다"
# 대조군 — 통합 리포트는 같은 단위 데이터에 FAIL 이다(cfg(test) 레코드는 단위 시험이 같은 빌드에서 돈 것이다 — 통합 판정은 그대로다).
rsfresh
mkdir -p "$D/it"
cp "$D/rust.unit.lcov" "$D/it/rust.lcov"
run report rust "$T" --out "$D/it"
assert_eq 2 "$RC" "[rust] 통합 리포트는 cfg(test) 레코드가 든 데이터에 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] $RS:103: the data has a function inside an item compiled only with cfg(test) (" "[rust] 통합의 cfg(test) 판정은 그대로다"

# (나) 음성 — 장부와 다르면 DRIFT(1).
# 새로 생긴 미도달 — 다 닿던 realm 의 줄을 0 회로(장부에 없다).
rsfresh
sed -i 's/^DA:2\([345]\),2$/DA:2\1,0/' "$D/rust.unit.lcov"
rsmark 0
assert_contains "$(cat "$D/rust.unit.lcov")" "DA:25,0" "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 1 "$RC" "[rust] 장부에 없는 미도달 fn 은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [rust] unrecorded unreached code $RS:AuthClient::realm — the unit suite never reaches 3 lines of it: test that code, or record why in scripts/unit-unreached.json" "[rust] 새 미도달"
# 적힌 fn 안에서 줄 하나가 더 안 돈다 — exchange 의 행복 경로 줄을 0 회로(fn 은 그대로 목록에 있고 수가 바뀐다).
rsfresh
sed -i 's/^DA:32,1$/DA:32,0/' "$D/rust.unit.lcov"
rsmark 0
assert_contains "$(cat "$D/rust.unit.lcov")" "DA:32,0" "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 1 "$RC" "[rust] 적힌 fn 의 줄 하나가 더 안 돌면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [rust] $RS:AuthClient::exchange: the unit run leaves 2 lines unreached, scripts/unit-unreached.json records 1 line — test what the unit suite does not reach, or record why and correct the counts" "[rust] 더 놓친 줄 수"
# 클로저의 줄 · 버린 퓨처의 몸통 — 장부에서 지우면 감싼 fn 이름으로 DRIFT 다(클로저 · 몸통 레코드의 이름으로 새지 않는다).
rsfresh
sed -i '/auth_client\.rs:AuthClient::pick"/,/},/d' "$L"
assert_not_contains "$(cat "$L")" "auth_client.rs:AuthClient::pick" "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 1 "$RC" "[rust] 클로저 안의 안 돈 줄이 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [rust] unrecorded unreached code $RS:AuthClient::pick — the unit suite never reaches 4 lines of it" "[rust] 클로저의 줄 — 감싼 fn 키"
rsfresh
sed -i '/auth_client\.rs:AuthClient::refresh"/,/},/d' "$L"
assert_not_contains "$(cat "$L")" "auth_client.rs:AuthClient::refresh" "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 1 "$RC" "[rust] 버린 퓨처의 몸통이 장부에 없으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [rust] unrecorded unreached code $RS:AuthClient::refresh — the unit suite never reaches 2 lines of it" "[rust] poll 안 된 몸통의 줄 — async fn 키"
# 장부의 수가 다르다 — 장부가 측정보다 많이 적었다.
rsfresh
sed -i '/auth_client\.rs:AuthClient::logout_url"/,/}/ s#"lines": 3,#"lines": 4,#' "$L"
assert_contains "$(grep -A1 'auth_client.rs:AuthClient::logout_url"' "$L")" '"lines": 4,' "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 1 "$RC" "[rust] 수가 다르면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [rust] $RS:AuthClient::logout_url: the unit run leaves 3 lines unreached, scripts/unit-unreached.json records 4 lines — the unit suite reaches more of it now: lower the counts" "[rust] 바뀐 줄 수 — 장부보다 덜 놓쳤다"
# 낡은 항목 — 다 닿는 fn · 데이터에 없는 fn · 알려진 틈의 fn(그 줄은 돈다) · 경계 밖 파일을 가리킨다.
rsfresh
sed -i "s#\"rust\": {#\"rust\": {\n    \"$RS:AuthClient::realm\": { \"lines\": 1, \"why\": \"integration: stale\" },\n    \"$RS:AuthClient::gone\": { \"lines\": 1, \"why\": \"integration: renamed\" },\n    \"$RS:AuthClient::fallback\": { \"lines\": 1, \"why\": \"integration: the known gap\" },\n    \"rust/src/config.rs:Config::valid\": { \"lines\": 1, \"why\": \"integration: outside\" },#" "$L"
assert_contains "$(cat "$L")" "\"$RS:AuthClient::gone\": { \"lines\": 1," "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 1 "$RC" "[rust] 낡은 항목은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [rust] stale entry $RS:AuthClient::realm — the unit run reaches all of it now; drop the entry" "[rust] 다 닿는 fn 의 항목"
assert_contains "$OUT" "DRIFT [rust] stale entry $RS:AuthClient::gone — the data of $RS has no such function (renamed or removed?)" "[rust] 없는 fn 의 항목"
assert_contains "$OUT" "DRIFT [rust] stale entry $RS:AuthClient::fallback — the unit run reaches all of it now" "[rust] 알려진 틈의 fn 은 장부에 적을 수 없다 — 그 줄은 돈다"
assert_contains "$OUT" "DRIFT [rust] scripts/unit-unreached.json: entry rust/src/config.rs:Config::valid names a file outside the boundary derived from .github/workflows/rust-ci.yml:7" "[rust] 경계 밖 파일의 항목"
# why — 닫힌 등록부 항목.
rsfresh
sed -i 's#"why": "open-gap"#"why": "closed-gap"#' "$L"
run unit-report rust "$T" --out "$D"
assert_eq 1 "$RC" "[rust] 닫힌 등록부 항목은 why 가 아니다 — exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [rust] $RS:AuthClient::port: why \"closed-gap\" is neither unreachable: · defensive: · integration: with a reason nor an open item of docs/superpowers/plans/remaining-work.md" "[rust] 닫힌 id"

# (다) 무결성 — FAIL(2): 데이터 · 다른 바이트 · 단위 기록 · 기록 없음 · 기록 뒤 바뀐 데이터 · 경계 해시 없는 기록 · 실패한 실행 · 데이터에
# 없는 경계 파일 · 공허한 실행 · 항목 밖 줄 · 레코드 없는 fn(단위 전용) · 통합 리포트가 내는 셋(macro_rules · 삼킨 범위 · FNDA 없음) · 장부의 꼴.
rsfresh
rm "$D/rust.unit.lcov"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 데이터가 없으면 exit 2"
assert_contains "$OUT" "FAIL [rust] no coverage data at" "[rust] 데이터 없음"
assert_contains "$OUT" "run the unit suite first (node scripts/integration-coverage.mjs unit rust)" "[rust] 다시 돌릴 명령"
rsfresh
printf '// changed after the run\n' >> "$T/$RS"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 다른 바이트의 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] $RS: the data was taken from other bytes" "[rust] 다른 바이트"
rsfresh
sed -i 's#"suite":"unit",##' "$D/rust.unit.run.json"
assert_not_contains "$(cat "$D/rust.unit.run.json")" '"suite"' "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 단위 실행의 것이 아닌 기록(suite 없음)은 exit 2"
assert_contains "$OUT" "FAIL [rust] no record that \`unit rust\` wrote this data" "[rust] 단위 기록 아님"
rsfresh
rm "$D/rust.unit.run.json"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 기록이 없는 데이터(손으로 돌린 cargo llvm-cov)는 exit 2"
assert_contains "$OUT" "FAIL [rust] no record that \`unit rust\` wrote this data" "[rust] 기록 없음"
rsfresh
printf '\nTN:\n' >> "$D/rust.unit.lcov"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 기록 뒤 바뀐 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/rust.unit.lcov is not the data \`unit rust\` recorded" "[rust] 데이터의 sha1"
rsfresh
sed -i 's#"files":{[^}]*}#"files":null#' "$D/rust.unit.run.json"
assert_contains "$(cat "$D/rust.unit.run.json")" '"files":null' "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 경계 해시가 없는 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] the record has no boundary hashes" "[rust] 실행 중에 바뀐 경계 파일"
rsfresh
rsmark 1
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 실패한 실행의 데이터는 exit 2"
assert_contains "$OUT" "FAIL [rust] the run that wrote this data exited 1 — the data of a failed run is partial" "[rust] 실패한 실행"
rsfresh
sed -i '/^SF:.*auth_client\.rs$/,/^end_of_record$/d' "$D/rust.unit.lcov"
rsmark 0
assert_not_contains "$(cat "$D/rust.unit.lcov")" "auth_client.rs" "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 경계 파일이 데이터에 없으면 exit 2"
assert_contains "$OUT" "FAIL [rust] $RS is not in the coverage data" "[rust] 데이터에 없는 경계 파일"
# 경계 줄을 하나도 안 돈 실행 — 측정 실패다. 항목 밖의 안 돈 줄(13 을 심는다)이 있어도 그 판정보다 먼저다(분모는 cfg(test) 줄을 뺀 55 줄).
rsfresh
sed -i '/^SF:.*auth_client\.rs$/,/^end_of_record$/ s/^DA:\([0-9]*\),[1-9][0-9]*$/DA:\1,0/' "$D/rust.unit.lcov"
sed -i 's/^DA:17,0$/DA:13,0\nDA:17,0/' "$D/rust.unit.lcov"
rsmark 0
assert_eq 0 "$(sed -n '/^SF:.*auth_client\.rs$/,/^end_of_record$/p' "$D/rust.unit.lcov" | grep -c '^DA:[0-9]*,[1-9]' || true)" "(변이가 착지했는지 먼저 본다 — 경계 줄 전부 0 회)"
assert_contains "$(cat "$D/rust.unit.lcov")" "DA:13,0" "(변이가 착지했는지 먼저 본다 — 항목 밖 줄)"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 경계 줄을 하나도 안 돈 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] the run executed 0 of 55 boundary lines — a measurement failure, not a low number (did the unit tests run against this tree?)" "[rust] 공허한 실행"
assert_not_contains "$OUT" "module level" "[rust] 공허한 실행은 항목 밖 줄로 읽지 않는다"
# 항목 밖 줄(어느 이름 범위에도 안 드는 — 매크로가 펼친 코드가 그 자리를 가리킬 때)의 안 돈 줄은 어느 fn 에도 못 붙인다 — FAIL.
# 구조체 필드 줄(13)에 줄을 심는다. 대조군: 돈 항목 밖 줄은 FAIL 이 아니다.
rsfresh
sed -i 's/^DA:17,2$/DA:13,0\nDA:17,2/' "$D/rust.unit.lcov"
rsmark 0
assert_contains "$(cat "$D/rust.unit.lcov")" "DA:13,0" "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 항목 밖의 안 돈 줄은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] $RS: 1 of 1 lines outside every item (module level — code a macro placed there) never ran — no function can be credited with them" "[rust] 항목 밖 줄"
rsfresh
sed -i 's/^DA:17,2$/DA:13,1\nDA:17,2/' "$D/rust.unit.lcov"
rsmark 0
assert_contains "$(cat "$D/rust.unit.lcov")" "DA:13,1" "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 0 "$RC" "[rust] 대조군 — 돈 항목 밖 줄은 FAIL 이 아니다 — 출력: $OUT"
# 레코드가 없는 fn(단위 전용 판정) — 라이브러리 단위 시험 바이너리가 안 부른 것에도 0 회 레코드를 남기므로 없다면 이 빌드가 컴파일하지 않은
# 코드다(그 줄을 셀 수 없다). logout_url 의 레코드 · 줄을 지운다. 통합 리포트는 같은 꼴을 「no record」 미실행으로 낸다(판정이 다르다).
rsfresh
sed -i '/10logout_url$/d; /^DA:7[456],0$/d' "$D/rust.unit.lcov"
rsmark 0
assert_not_contains "$(cat "$D/rust.unit.lcov")" "logout_url" "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 레코드가 없는 fn 은 단위 장부에서 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] $RS:74: the data has no record of AuthClient::logout_url — the unit build compiled no code for it" "[rust] 레코드 없는 fn"
# 통합 리포트가 내는 무결성 판정 셋은 단위에서도 FAIL 이다 — macro_rules 안의 레코드 · 다음 fn 머리를 삼킨 범위 · FNDA 없는 레코드.
rsfresh
sed -i '/^SF:.*auth_client\.rs$/a FN:8,_RNvfake_macro_generated\nFNDA:1,_RNvfake_macro_generated' "$D/rust.unit.lcov"
rsmark 0
assert_contains "$(cat "$D/rust.unit.lcov")" "FN:8,_RNvfake_macro_generated" "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] macro_rules! 안의 함수 레코드는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] $RS:8: the data has a function (_RNvfake_macro_generated) inside macro_rules! owned" "[rust] 매크로를 댄다"
rsfresh
sed -i '25s#^    }$#    }}#' "$T/$RS"
assert_contains "$(sed -n '25p' "$T/$RS")" "    }}" "(변이가 착지했는지 먼저 본다)"
rsmark 0
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 다음 fn 머리를 삼킨 범위는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] $RS:28: the data has a function (" "[rust] 삼켜진 fn 의 자리"
assert_contains "$OUT" "that starts at a function head inside AuthClient::realm's range (23–33) — the range ran past its end" "[rust] 삼킨 범위를 댄다"
rsfresh
sed -i '/^FNDA:.*10logout_url$/d' "$D/rust.unit.lcov"
rsmark 0
assert_not_contains "$(grep '^FNDA:' "$D/rust.unit.lcov")" "logout_url" "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] FNDA 없는 레코드는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] $RS:74: the data has a function record (" "[rust] 그 레코드를 댄다"
# 장부의 꼴 — rust 항목은 { lines, why } 다: 가지를 더하거나 문장으로 적으면 exit 2(안정판 툴체인의 llvm-cov 에는 가지가 없다).
rsfresh
sed -i '/auth_client\.rs:AuthClient::exchange"/,/}/ s#"lines": 1,#"lines": 1, "branches": 0,#' "$L"
assert_contains "$(grep -A1 'auth_client.rs:AuthClient::exchange"' "$L")" '"lines": 1, "branches": 0,' "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] rust 항목에 branches 가 있으면 exit 2"
assert_contains "$OUT" "FAIL [rust] scripts/unit-unreached.json: rust[\"$RS:AuthClient::exchange\"] must be { lines, why } — whole-number counts and a non-empty why" "[ledger] rust 꼴 — 가지 없음"
rsfresh
sed -i '/auth_client\.rs:AuthClient::exchange"/,/}/ s#"lines": 1,#"statements": 1,#' "$L"
assert_contains "$(grep -A1 'auth_client.rs:AuthClient::exchange"' "$L")" '"statements": 1,' "(변이가 착지했는지 먼저 본다)"
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[ledger] rust 항목을 문장으로 적으면 exit 2(문장은 go 의 것이다)"
assert_contains "$OUT" "FAIL [rust] scripts/unit-unreached.json: rust[\"$RS:AuthClient::exchange\"] must be { lines, why }" "[ledger] rust 꼴 — 줄"

# (라) check — 데이터 없이 꼴 · 경계 · why(통합 픽스처 트리).
fresh
run check "$T"
assert_eq 0 "$RC" "[check] rust 장부가 든 건강한 장부는 exit 0 — 출력: $OUT"
assert_line "$OUT" "[rust] unit-unreached: 1 entry (open-admin 1)" "[check] rust 장부"
fresh
sed -i '/auth\.rs:AuthClient::describe"/,/}/ s#"lines": 7,#"lines": 7, "branches": 0,#' "$T/scripts/unit-unreached.json"
assert_contains "$(grep -A1 'auth.rs:AuthClient::describe"' "$T/scripts/unit-unreached.json")" '"branches": 0,' "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 2 "$RC" "[check] rust 항목에 branches 가 있으면 데이터 없이도 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] scripts/unit-unreached.json: rust[\"rust/src/auth.rs:AuthClient::describe\"] must be { lines, why }" "[check] rust 꼴"

# ── (7) 커버리지 제외 표지(등록부 coverage-ignore-markers-unguarded) — 표지 2 · 오표기와 표지 아닌 이름 0 · 공허 · 못 읽는 자리 2 · 실제 트리 0 ──
# 어느 표기를 왜 막고 무엇을 쟀는지는 도구 머리가 소유한다. 표지는 경계 밖 파일(Config — 어느 리더도 그 바이트를 대조하지 않는다)에 넣는다:
# 같은 자리에 오표기를 넣은 대조군이 리더까지 가 exit 0 이어야 FAIL 을 낸 것이 「줄을 넣은 것」이 아니라 「표기」다. 표지가 있으면 리더를
# 부르지 않는다(UNREACHED 가 없다 — 장부를 대조하지 않는다). 표지 k 는 줄 2k 에 선다(줄 2k-1 뒤에 넣어 앞의 표지가 뒤의 자리를 민다).
# 넣기는 awk 의 ENVIRON 으로 한다 — sed 의 a 는 `\` 를 먹는다(php 속성의 이름).
mark_after() { # file line text — text 는 line+1 에 선다
  MARK="$3" awk -v n="$2" '{ print } NR == n { print ENVIRON["MARK"] }' "$T/$1" > "$T/$1.new" && mv "$T/$1.new" "$T/$1"
  assert_eq "$3" "$(sed -n "$(($2 + 1))p" "$T/$1")" "(변이가 착지했는지 먼저 본다 — $1:$(($2 + 1)))"
}
MREM="in shipped source — the ledger cannot be trusted while one is there: remove it, then test that code or record why in scripts/unit-unreached.json"
MVERDICT="integrity failures; the ledger is not compared against a run that failed one"

# (가) node — ast-v8-to-istanbul 의 두 규칙(주석의 if · else · next · file · 줄의 start · stop)과 node:coverage · 낱말 사이 공백 여럿.
XE=node/src/config.ts
ufresh
mark_after "$XE" 1 '/* v8 ignore next */'
mark_after "$XE" 3 '// c8 ignore start'
mark_after "$XE" 5 '/* istanbul ignore if */'
mark_after "$XE" 7 '/*  node:coverage   ignore  next  */'
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[markers] node 의 표지 넷이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[node] coverage-exclusion markers: 4 in 2 tracked files under node/src — each is a FAIL below" "[markers] node — 읽은 추적 파일 수 · 표지 수"
assert_line "$OUT" "FAIL [node] $XE:2: coverage-exclusion marker \`v8 ignore next\` $MREM" "[markers] v8 — 파일:줄 · 표기 · 할 일"
assert_contains "$OUT" "FAIL [node] $XE:4: coverage-exclusion marker \`c8 ignore start\` in" "[markers] c8 · 줄의 start"
assert_contains "$OUT" "FAIL [node] $XE:6: coverage-exclusion marker \`istanbul ignore if\` in" "[markers] istanbul · 주석의 if"
assert_contains "$OUT" "FAIL [node] $XE:8: coverage-exclusion marker \`node:coverage ignore next\` in" "[markers] node:coverage · 낱말 사이 공백 여럿(표기는 한 칸으로 찍는다)"
assert_line "$OUT" "unit-unreached [node]: FAIL — 4 $MVERDICT" "[markers] node — 표지마다 FAIL 하나 · 다른 FAIL 은 없다"
assert_not_contains "$OUT" "UNREACHED" "[markers] 표지가 있으면 장부를 대조하지 않는다"
# 남은 낱말 셋 — 주석의 else · file, 줄의 stop.
ufresh
mark_after "$XE" 1 '/* istanbul ignore else */'
mark_after "$XE" 3 '/* c8 ignore file */'
mark_after "$XE" 5 '// v8 ignore stop'
run unit-report node "$T" --out "$D"
assert_eq 2 "$RC" "[markers] node 의 남은 낱말 셋이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] $XE:2: coverage-exclusion marker \`istanbul ignore else\` in" "[markers] istanbul · 주석의 else"
assert_contains "$OUT" "FAIL [node] $XE:4: coverage-exclusion marker \`c8 ignore file\` in" "[markers] c8 · 주석의 file"
assert_contains "$OUT" "FAIL [node] $XE:6: coverage-exclusion marker \`v8 ignore stop\` in" "[markers] v8 · 줄의 stop"
assert_line "$OUT" "unit-unreached [node]: FAIL — 3 $MVERDICT" "[markers] node 남은 낱말 — 다른 FAIL 은 없다"
ufresh
mark_after "$XE" 1 '/* v8 ignroe next */'
run unit-report node "$T" --out "$D"
assert_eq 0 "$RC" "[markers] node 대조군 — 같은 자리의 오표기는 표지가 아니다(리더까지 가 exit 0) — 출력: $OUT"
assert_line "$OUT" "[node] coverage-exclusion markers: none in 2 tracked files under node/src" "[markers] node 대조군 — 표지 0"

# (나) python — coverage.py 의 두 정규식 그대로(붙여 쓴 꼴 · 낱말마다의 대문자 · no branch · 파이썬의 \s 만 아는 공백 U+0085 — 표기는 그
# 바이트 그대로 찍힌다). pragma 뒤의 U+0085 는 `[:\s…]?` 자리다 — 그 뒤 `\s*` 도 같은 글자를 먹어(coverage.py 의 `[:\s]?\s*` 와 같다) 그 칸의
# U+0085 만 빼는 변이는 어느 시험으로도 못 가른다(동치 변이).
XY=python/src/keycloak_sdk/config.py
YNEL="$(printf '#\302\205pragma: no cover')"
YNEL2="$(printf '#pragma\302\205no cover')"
ufresh
mark_after "$XY" 1 '# pragma: no cover'
mark_after "$XY" 3 '#pragma:nocover'
mark_after "$XY" 5 'x = 1  # PRAGMA no BRANCH'
mark_after "$XY" 7 "$YNEL"
mark_after "$XY" 9 '# PRAGMA: NO COVER'
mark_after "$XY" 11 "$YNEL2"
run unit-report python "$T" --out "$D"
assert_eq 2 "$RC" "[markers] python 의 표지 여섯이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[python] coverage-exclusion markers: 6 in 3 tracked files under python/src — each is a FAIL below" "[markers] python — 읽은 추적 파일 수 · 표지 수"
assert_contains "$OUT" "FAIL [python] $XY:2: coverage-exclusion marker \`# pragma: no cover\` in" "[markers] pragma: no cover"
assert_contains "$OUT" "FAIL [python] $XY:4: coverage-exclusion marker \`#pragma:nocover\` in" "[markers] 붙여 쓴 꼴(도구의 [:\\s]? · \\s*)"
assert_contains "$OUT" "FAIL [python] $XY:6: coverage-exclusion marker \`# PRAGMA no BRANCH\` in" "[markers] 코드 뒤 · 대문자 · no branch(DEFAULT_PARTIAL)"
assert_contains "$OUT" "FAIL [python] $XY:8: coverage-exclusion marker \`$YNEL\` in" "[markers] # 와 pragma 사이의 U+0085 — 파이썬의 \\s 라 coverage.py 가 맞춘다(JS 의 \\s 가 아니다)"
assert_contains "$OUT" "FAIL [python] $XY:10: coverage-exclusion marker \`# PRAGMA: NO COVER\` in" "[markers] 낱말마다 대문자(PRAGMA · NO · COVER)"
assert_contains "$OUT" "FAIL [python] $XY:12: coverage-exclusion marker \`$YNEL2\` in" "[markers] pragma 뒤 [:\\s…]? 자리의 U+0085"
assert_line "$OUT" "unit-unreached [python]: FAIL — 6 $MVERDICT" "[markers] python — 다른 FAIL 은 없다"
ufresh
mark_after "$XY" 1 '# pragma: no cvoer'
run unit-report python "$T" --out "$D"
assert_eq 0 "$RC" "[markers] python 대조군 — exit 0 — 출력: $OUT"
assert_line "$OUT" "[python] coverage-exclusion markers: none in 3 tracked files under python/src" "[markers] python 대조군 — 표지 0"

# (다) php — 한 줄 주석의 Start · End · 문서 주석 · 이름이 풀린 속성.
XP=php/src/Config.php
ufresh
mark_after "$XP" 1 '// @codeCoverageIgnoreStart'
mark_after "$XP" 3 '/** @codeCoverageIgnore */'
mark_after "$XP" 5 '#[\PHPUnit\Framework\Attributes\CodeCoverageIgnore]'
mark_after "$XP" 7 '//@codeCoverageIgnoreEnd'
run unit-report php "$T" --out "$D"
assert_eq 2 "$RC" "[markers] php 의 표지 넷이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[php] coverage-exclusion markers: 4 in 2 tracked files under php/src — each is a FAIL below" "[markers] php — 읽은 추적 파일 수 · 표지 수"
assert_contains "$OUT" "FAIL [php] $XP:2: coverage-exclusion marker \`@codeCoverageIgnoreStart\` in" "[markers] Start"
assert_contains "$OUT" "FAIL [php] $XP:4: coverage-exclusion marker \`@codeCoverageIgnore\` in" "[markers] 문서 주석"
assert_contains "$OUT" "FAIL [php] $XP:6: coverage-exclusion marker \`CodeCoverageIgnore\` in" "[markers] 속성"
assert_contains "$OUT" "FAIL [php] $XP:8: coverage-exclusion marker \`@codeCoverageIgnoreEnd\` in" "[markers] End"
assert_line "$OUT" "unit-unreached [php]: FAIL — 4 $MVERDICT" "[markers] php — 다른 FAIL 은 없다"
ufresh
mark_after "$XP" 1 '// @codeCoverageIgnroeStart'
run unit-report php "$T" --out "$D"
assert_eq 0 "$RC" "[markers] php 대조군 — exit 0 — 출력: $OUT"
assert_line "$OUT" "[php] coverage-exclusion markers: none in 2 tracked files under php/src" "[markers] php 대조군 — 표지 0"

# (라) dotnet — coverlet 이 이름으로 아는 특성 둘.
XN=dotnet/src/Kc/Config.cs
ufresh
mark_after "$XN" 1 '[System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverage]'
mark_after "$XN" 3 '[ExcludeFromCoverage]'
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[markers] dotnet 의 표지 둘이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[dotnet] coverage-exclusion markers: 2 in 3 tracked files under dotnet/src — each is a FAIL below" "[markers] dotnet — 읽은 추적 파일 수 · 표지 수"
assert_contains "$OUT" "FAIL [dotnet] $XN:2: coverage-exclusion marker \`ExcludeFromCodeCoverage\` in" "[markers] ExcludeFromCodeCoverage"
assert_contains "$OUT" "FAIL [dotnet] $XN:4: coverage-exclusion marker \`ExcludeFromCoverage\` in" "[markers] ExcludeFromCoverage"
assert_line "$OUT" "unit-unreached [dotnet]: FAIL — 2 $MVERDICT" "[markers] dotnet — 다른 FAIL 은 없다"
ufresh
mark_after "$XN" 1 '[ExcludeFromCodeCoverge]'
run unit-report dotnet "$T" --out "$D"
assert_eq 0 "$RC" "[markers] dotnet 대조군 — exit 0 — 출력: $OUT"
assert_line "$OUT" "[dotnet] coverage-exclusion markers: none in 3 tracked files under dotnet/src" "[markers] dotnet 대조군 — 표지 0"
# MSBuild 가 프로젝트마다 싣는 dotnet/Directory.Build.props 의 전역 using 별칭 — dotnet/src 의 `[Skip]` 이 그 특성이 된다(roots 밖 · also).
ufresh
printf '%s\n' '<Project>' '  <ItemGroup><Using Include="System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverageAttribute" Alias="Skip" /></ItemGroup>' '</Project>' > "$T/dotnet/Directory.Build.props"
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[markers] dotnet/Directory.Build.props 의 별칭이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[dotnet] coverage-exclusion markers: 1 in 4 tracked files under dotnet/src · dotnet/Directory.Build.props — each is a FAIL below" "[markers] dotnet — also 를 읽은 수에 넣고 찍는다"
assert_contains "$OUT" "FAIL [dotnet] dotnet/Directory.Build.props:2: coverage-exclusion marker \`ExcludeFromCodeCoverageAttribute\` in" "[markers] Directory.Build.props 의 Using 별칭"
assert_line "$OUT" "unit-unreached [dotnet]: FAIL — 1 integrity failure; the ledger is not compared against a run that failed one" "[markers] dotnet props — 다른 FAIL 은 없다"
ufresh
printf '%s\n' '<Project>' '  <ItemGroup><Using Include="System.Diagnostics.CodeAnalysis.ExcludeFromCodeCovergeAttribute" Alias="Skip" /></ItemGroup>' '</Project>' > "$T/dotnet/Directory.Build.props"
run unit-report dotnet "$T" --out "$D"
assert_eq 0 "$RC" "[markers] dotnet props 대조군 — exit 0 — 출력: $OUT"
assert_line "$OUT" "[dotnet] coverage-exclusion markers: none in 4 tracked files under dotnet/src · dotnet/Directory.Build.props" "[markers] dotnet props 대조군 — 표지 0"
# MSBuild 는 위로 올라가며 처음 만난 Directory.Build.props 와 .targets 를 따로 싣는다 — 지금의 배치(dotnet/ 에 props 만)에서 저장소 뿌리의 targets
# 가 실리고, 뿌리의 props 는 dotnet/ 의 것이 없어지면 실린다. 그 배치를 그대로 짓고 뿌리의 둘에 별칭을 넣는다(also — 하나씩 빼는 변이가 저마다 운다).
ufresh
printf '%s\n' '<Project>' '  <PropertyGroup><Nullable>enable</Nullable></PropertyGroup>' '</Project>' > "$T/dotnet/Directory.Build.props"
for _f in Directory.Build.props Directory.Build.targets; do
  printf '%s\n' '<Project>' '  <ItemGroup><Using Include="System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverageAttribute" Alias="Skip" /></ItemGroup>' '</Project>' > "$T/$_f"
done
run unit-report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[markers] 저장소 뿌리 Directory.Build.{props,targets} 의 별칭이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[dotnet] coverage-exclusion markers: 2 in 6 tracked files under dotnet/src · Directory.Build.props · Directory.Build.targets · dotnet/Directory.Build.props — each is a FAIL below" "[markers] dotnet — 뿌리의 also 둘"
assert_contains "$OUT" "FAIL [dotnet] Directory.Build.props:2: coverage-exclusion marker \`ExcludeFromCodeCoverageAttribute\` in" "[markers] 뿌리 Directory.Build.props 의 Using 별칭"
assert_contains "$OUT" "FAIL [dotnet] Directory.Build.targets:2: coverage-exclusion marker \`ExcludeFromCodeCoverageAttribute\` in" "[markers] 뿌리 Directory.Build.targets 의 Using 별칭(dotnet/ 에 props 만 있으면 실린다)"
assert_line "$OUT" "unit-unreached [dotnet]: FAIL — 2 $MVERDICT" "[markers] 뿌리 props · targets — 다른 FAIL 은 없다"

# (마) java — 마지막 이름 조각에 Generated 를 담은 주석(맨 이름 · 한정 이름 · @ 뒤 공백 · Generated 뒤 글자) · 어휘기가 먼저 푸는 \uXXXX ·
# 그 이름의 주석 타입 선언(되풀이 주석의 컨테이너는 붙인 자리에 이름이 없다). java 에는 별칭이 없어 import 는 표지가 아니다 — 대조군의 import 셋 ·
# 앞 조각에만 Generated 가 있는 한정 이름 · 보통 클래스 · `\\` 뒤의 u(이스케이프가 아니다)는 조용해야 한다.
XJ=java/kc-auth/src/main/java/kc/auth/Config.java
# `\` 하나 + `u` + 16진 넷은 printf 로 짓는다 — printf 의 `\\` 가 `\` 하나다(이 파일을 고치는 도구가 그 이스케이프를 미리 풀지 않게). JU3 은
# 푼 글자(이스케이프 u005c 가 내는 `\`)가 다시 이스케이프를 열지 않는다는 JLS 3.3 의 대조군이다.
JU1="$(printf '@\\u0047enerated')"
JU3="$(printf 'String t = "\\u005cu0040Generated";')"
ufresh
mark_after "$XJ" 1 '@Generated'
mark_after "$XJ" 3 '@ kc.marks.NoCoverageGenerated'
mark_after "$XJ" 5 '@GeneratedCode'
mark_after "$XJ" 7 "$JU1"
mark_after "$XJ" 9 '@Gen\uu0065rated'
mark_after "$XJ" 11 '@interface NoCoverageGenerated {}'
mark_after "$XJ" 13 'public @interface GeneratedList { Marker[] value(); }'
run unit-report java "$T" --out "$D"
assert_eq 2 "$RC" "[markers] java 의 표지 일곱이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[java] coverage-exclusion markers: 7 in 3 tracked files under java/*/src/main/java — each is a FAIL below" "[markers] java — 읽은 추적 파일 수(모듈마다) · 표지 수"
assert_contains "$OUT" "FAIL [java] $XJ:2: coverage-exclusion marker \`@Generated\` in" "[markers] @Generated"
assert_contains "$OUT" "FAIL [java] $XJ:4: coverage-exclusion marker \`@ kc.marks.NoCoverageGenerated\` in" "[markers] 한정 이름 · 이름 안의 Generated"
assert_contains "$OUT" "FAIL [java] $XJ:6: coverage-exclusion marker \`@GeneratedCode\` in" "[markers] Generated 뒤에 글자가 이어져도 담는다(JaCoCo 의 contains)"
assert_contains "$OUT" "FAIL [java] $XJ:8: coverage-exclusion marker \`$JU1\` in" "[markers] \\uXXXX — 푼 이름으로 맞추고 원문 표기 · 줄을 댄다"
assert_contains "$OUT" "FAIL [java] $XJ:10: coverage-exclusion marker \`@Gen\\uu0065rated\` in" "[markers] \\uu… — u 여럿"
assert_contains "$OUT" "FAIL [java] $XJ:12: coverage-exclusion marker \`@interface NoCoverageGenerated\` in" "[markers] 주석 타입 선언"
assert_contains "$OUT" "FAIL [java] $XJ:14: coverage-exclusion marker \`@interface GeneratedList\` in" "[markers] 한정자 뒤의 주석 타입 선언(되풀이 주석의 컨테이너)"
assert_line "$OUT" "unit-unreached [java]: FAIL — 7 $MVERDICT" "[markers] java — 다른 FAIL 은 없다"
ufresh
mark_after "$XJ" 1 '@Generatde'
mark_after "$XJ" 3 'import kc.auth.GeneratedToken;'
mark_after "$XJ" 5 'import static kc.Keys.isGenerated;'
mark_after "$XJ" 7 'import kc.GeneratedModels.User;'
mark_after "$XJ" 9 '@kc.GeneratedModels.User'
mark_after "$XJ" 11 'class GeneratedToken {}'
mark_after "$XJ" 13 'String s = "\\u0040Generated";'
mark_after "$XJ" 15 "$JU3"
run unit-report java "$T" --out "$D"
assert_eq 0 "$RC" "[markers] java 대조군 — 오표기 · import 셋 · 앞 조각만의 Generated · 보통 클래스 · 홀수 번째 \\ 의 u · 푼 글자의 u 는 표지가 아니다(exit 0) — 출력: $OUT"
assert_line "$OUT" "[java] coverage-exclusion markers: none in 3 tracked files under java/*/src/main/java" "[markers] java 대조군 — 표지 0"

# (바) kotlin — 별칭 import · 쓰임 자리 표적 · 여러 주석 꼴(인자 속 `]` 를 넘어 이름 자리만) · typealias, 그리고 백틱 이름. 대조군: 별칭 없는
# import · 마지막 조각이 아닌 Generated · 인자 문자열 속 Generated · 레이블(`this@…`)은 표지가 아니다.
XK=kotlin/src/main/kotlin/kc/auth/Config.kt
ufresh
mark_after "$XK" 1 'import kc.marks.Generated as Skip'
mark_after "$XK" 3 '@get:Generated'
mark_after "$XK" 5 '@field:[Volatile LedgerGenerated]'
mark_after "$XK" 7 'typealias Hidden = kc.marks.Generated'
mark_after "$XK" 9 '@[Suppress(names = ["UNUSED"]) Generated]'
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[markers] kotlin 의 표지 다섯이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[kotlin] coverage-exclusion markers: 5 in 2 tracked files under kotlin/src/main/kotlin — each is a FAIL below" "[markers] kotlin — 읽은 추적 파일 수 · 표지 수"
assert_contains "$OUT" "FAIL [kotlin] $XK:2: coverage-exclusion marker \`import kc.marks.Generated\` in" "[markers] 별칭 import — 쓰는 자리(@Skip)에는 이름이 없다"
assert_contains "$OUT" "FAIL [kotlin] $XK:4: coverage-exclusion marker \`@get:Generated\` in" "[markers] 쓰임 자리 표적"
assert_contains "$OUT" "FAIL [kotlin] $XK:6: coverage-exclusion marker \`@field:[Volatile LedgerGenerated]\` in" "[markers] 대괄호 꼴"
assert_contains "$OUT" "FAIL [kotlin] $XK:8: coverage-exclusion marker \`typealias Hidden = kc.marks.Generated\` in" "[markers] typealias"
assert_contains "$OUT" "FAIL [kotlin] $XK:10: coverage-exclusion marker \`@[Suppress(names = [\"UNUSED\"]) Generated]\` in" "[markers] 대괄호 꼴 — 앞 주석 인자 속 ] 를 넘어 이름 자리를 읽는다"
assert_line "$OUT" "unit-unreached [kotlin]: FAIL — 5 $MVERDICT" "[markers] kotlin — 다른 FAIL 은 없다"
ufresh
mark_after "$XK" 1 '@`Generated`'
mark_after "$XK" 3 '@get:`Generated`'
mark_after "$XK" 5 '@kc.marks.`Generated`'
mark_after "$XK" 7 'import kc.marks.`Generated` as Skip'
mark_after "$XK" 9 'typealias Skip = kc.marks.`Generated`'
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[markers] kotlin 의 백틱 이름 다섯이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[kotlin] coverage-exclusion markers: 5 in 2 tracked files under kotlin/src/main/kotlin — each is a FAIL below" "[markers] kotlin 백틱 — 표지 수"
assert_contains "$OUT" "FAIL [kotlin] $XK:2: coverage-exclusion marker \`@\`Generated\`\` in" "[markers] 백틱 이름"
assert_contains "$OUT" "FAIL [kotlin] $XK:4: coverage-exclusion marker \`@get:\`Generated\`\` in" "[markers] 쓰임 자리 표적 + 백틱"
assert_contains "$OUT" "FAIL [kotlin] $XK:6: coverage-exclusion marker \`@kc.marks.\`Generated\`\` in" "[markers] 한정 이름의 백틱 조각"
assert_contains "$OUT" "FAIL [kotlin] $XK:8: coverage-exclusion marker \`import kc.marks.\`Generated\`\` in" "[markers] 별칭 import 의 백틱 조각"
assert_contains "$OUT" "FAIL [kotlin] $XK:10: coverage-exclusion marker \`typealias Skip = kc.marks.\`Generated\`\` in" "[markers] typealias 의 백틱 조각"
assert_line "$OUT" "unit-unreached [kotlin]: FAIL — 5 $MVERDICT" "[markers] kotlin 백틱 — 다른 FAIL 은 없다"
# 목록 읽기가 인자 속에서 건너뛰는 것 — 템플릿 속 문자열의 `)`(템플릿을 모르면 인자가 거기서 닫힌다) · 원문 문자열 속 `"]` · 문자 `'"'` · 겹친
# 주석 속 `]` · 여러 줄 목록(이름의 줄을 댄다).
ufresh
mark_after "$XK" 1 '@[A("${")"}") Generated]'
mark_after "$XK" 3 '@[A("""x"]""") Generated]'
mark_after "$XK" 5 "@[A('\"') Generated]"
mark_after "$XK" 7 '@[A /* /* ] */ ] */ Generated]'
mark_after "$XK" 9 '@file:[A'
mark_after "$XK" 10 '  Generated]'
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[markers] kotlin 목록 읽기의 건너뛰기 다섯이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [kotlin] $XK:2: coverage-exclusion marker \`@[A(\"\${\")\"}\") Generated]\` in" "[markers] 템플릿 속 문자열의 )"
assert_contains "$OUT" "FAIL [kotlin] $XK:4: coverage-exclusion marker \`@[A(\"\"\"x\"]\"\"\") Generated]\` in" "[markers] 원문 문자열 속 \"]"
assert_contains "$OUT" "FAIL [kotlin] $XK:6: coverage-exclusion marker \`@[A('\"') Generated]\` in" "[markers] 문자 '\"'"
assert_contains "$OUT" "FAIL [kotlin] $XK:8: coverage-exclusion marker \`@[A /* /* ] */ ] */ Generated]\` in" "[markers] 겹친 주석 속 ]"
assert_contains "$OUT" "FAIL [kotlin] $XK:11: coverage-exclusion marker \`@file:[A Generated]\` in" "[markers] 여러 줄 목록 — 이름의 줄"
assert_line "$OUT" "unit-unreached [kotlin]: FAIL — 5 $MVERDICT" "[markers] kotlin 목록 읽기 — 다른 FAIL 은 없다"
# 한정자 · 다른 주석에 붙은 `@`(레이블 참조가 아니다)와 이름에 Generated 를 담은 주석 타입 선언(되풀이 주석의 컨테이너는 붙인 자리에 이름이 없다).
ufresh
mark_after "$XK" 1 'private@Generated fun f() {}'
mark_after "$XK" 3 'override@Generated fun f() {}'
mark_after "$XK" 5 '@JvmStatic@Generated fun f() {}'
mark_after "$XK" 7 'private@[Generated] fun f() {}'
mark_after "$XK" 9 '@JvmStatic@[Generated] fun f() {}'
mark_after "$XK" 11 'annotation class LedgerGenerated'
mark_after "$XK" 13 'internal annotation class GeneratedList(val value: Array<Marker>)'
mark_after "$XK" 15 'annotation @Target(allowedTargets = arrayOf(AnnotationTarget.CLASS)) class GeneratedSkip'
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[markers] kotlin 의 붙은 @ 다섯 · 선언 셋이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[kotlin] coverage-exclusion markers: 8 in 2 tracked files under kotlin/src/main/kotlin — each is a FAIL below" "[markers] kotlin 붙은 @ · 선언 — 표지 수"
assert_contains "$OUT" "FAIL [kotlin] $XK:2: coverage-exclusion marker \`@Generated\` in" "[markers] private@"
assert_contains "$OUT" "FAIL [kotlin] $XK:4: coverage-exclusion marker \`@Generated\` in" "[markers] override@"
assert_contains "$OUT" "FAIL [kotlin] $XK:6: coverage-exclusion marker \`@Generated\` in" "[markers] @JvmStatic@"
assert_contains "$OUT" "FAIL [kotlin] $XK:8: coverage-exclusion marker \`@[Generated]\` in" "[markers] private@[…]"
assert_contains "$OUT" "FAIL [kotlin] $XK:10: coverage-exclusion marker \`@[Generated]\` in" "[markers] @JvmStatic@[…]"
assert_contains "$OUT" "FAIL [kotlin] $XK:12: coverage-exclusion marker \`annotation class LedgerGenerated\` in" "[markers] 주석 타입 선언"
assert_contains "$OUT" "FAIL [kotlin] $XK:14: coverage-exclusion marker \`annotation class GeneratedList\` in" "[markers] 한정자 뒤의 주석 타입 선언(되풀이 주석의 컨테이너)"
assert_contains "$OUT" "FAIL [kotlin] $XK:16: coverage-exclusion marker \`annotation @Target(allowedTargets = arrayOf(AnnotationTarget.CLASS)) class GeneratedSkip\` in" "[markers] annotation 과 class 사이의 주석(인자 속 괄호 두 겹)"
assert_line "$OUT" "unit-unreached [kotlin]: FAIL — 8 $MVERDICT" "[markers] kotlin 붙은 @ · 선언 — 다른 FAIL 은 없다"
# typealias 의 타입 매개변수 속 함수 타입(`->` 의 `>` 는 `<…>` 를 닫지 않는다) · annotation 과 class 사이의 여러 주석 꼴.
ufresh
mark_after "$XK" 1 'typealias Skip<T : () -> Unit> = kc.marks.Generated'
mark_after "$XK" 3 'annotation @[Retention(AnnotationRetention.SOURCE)] class GeneratedSkip'
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[markers] kotlin 의 화살표 매개변수 · 여러 주석 꼴 선언이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[kotlin] coverage-exclusion markers: 2 in 2 tracked files under kotlin/src/main/kotlin — each is a FAIL below" "[markers] kotlin 화살표 매개변수 — 표지 수"
assert_contains "$OUT" "FAIL [kotlin] $XK:2: coverage-exclusion marker \`typealias Skip<T : () -> Unit> = kc.marks.Generated\` in" "[markers] 타입 매개변수 속 ->"
assert_contains "$OUT" "FAIL [kotlin] $XK:4: coverage-exclusion marker \`annotation @[Retention(AnnotationRetention.SOURCE)] class GeneratedSkip\` in" "[markers] annotation 과 class 사이의 @[…]"
assert_line "$OUT" "unit-unreached [kotlin]: FAIL — 2 $MVERDICT" "[markers] kotlin 화살표 매개변수 — 다른 FAIL 은 없다"
# 여러 달러 문자열(접두만큼의 `$` 뒤 `{` 만 템플릿) · `<…>` 속 함수 타입의 `->` · 인자 속 백틱 이름 · 백틱 바로 뒤의 `as` · 괄호 친 / 겹친 제네릭
# typealias.
ufresh
mark_after "$XK" 1 '@[Suppress($$"${") Generated]'
mark_after "$XK" 3 '@[Suppress($$"""${""") Generated]'
mark_after "$XK" 5 '@[Alias<() -> Unit>("X") Generated]'
mark_after "$XK" 7 '@[A(`x)`) Generated]'
mark_after "$XK" 9 '@[A(`x"`) Generated]'
mark_after "$XK" 11 'import kc.marks.`Generated`as Skip'
mark_after "$XK" 13 'typealias Skip = (kc.marks.Generated)'
mark_after "$XK" 15 'typealias Skip<T : List<Int>> = kc.marks.Generated'
run unit-report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[markers] kotlin 의 문법 꼴 여덟이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[kotlin] coverage-exclusion markers: 8 in 2 tracked files under kotlin/src/main/kotlin — each is a FAIL below" "[markers] kotlin 문법 꼴 — 표지 수"
assert_contains "$OUT" "FAIL [kotlin] $XK:2: coverage-exclusion marker \`@[Suppress(\$\$\"\${\") Generated]\` in" "[markers] 여러 달러 문자열의 \${ 는 글자다"
assert_contains "$OUT" "FAIL [kotlin] $XK:4: coverage-exclusion marker \`@[Suppress(\$\$\"\"\"\${\"\"\") Generated]\` in" "[markers] 여러 달러 원문 문자열"
assert_contains "$OUT" "FAIL [kotlin] $XK:6: coverage-exclusion marker \`@[Alias<() -> Unit>(\"X\") Generated]\` in" "[markers] <…> 속 ->"
assert_contains "$OUT" "FAIL [kotlin] $XK:8: coverage-exclusion marker \`@[A(\`x)\`) Generated]\` in" "[markers] 인자 속 백틱 이름의 )"
assert_contains "$OUT" "FAIL [kotlin] $XK:10: coverage-exclusion marker \`@[A(\`x\"\`) Generated]\` in" "[markers] 인자 속 백틱 이름의 \""
assert_contains "$OUT" "FAIL [kotlin] $XK:12: coverage-exclusion marker \`import kc.marks.\`Generated\`\` in" "[markers] 백틱 바로 뒤의 as"
assert_contains "$OUT" "FAIL [kotlin] $XK:14: coverage-exclusion marker \`typealias Skip = (kc.marks.Generated)\` in" "[markers] 괄호 친 typealias"
assert_contains "$OUT" "FAIL [kotlin] $XK:16: coverage-exclusion marker \`typealias Skip<T : List<Int>> = kc.marks.Generated\` in" "[markers] 겹친 제네릭 매개변수의 typealias"
assert_line "$OUT" "unit-unreached [kotlin]: FAIL — 8 $MVERDICT" "[markers] kotlin 문법 꼴 — 다른 FAIL 은 없다"
# 대조군 둘째 — 레이블 참조(이름에 Generated 를 담아야 그 판정을 잰다) · 문자열 템플릿의 `$`(맨 이름 글자가 아니다) · 보통 클래스 · 함수 타입 별칭
# 셋(매개변수 하나 · 여럿 · 괄호 두 겹 — 괄호 친 오른쪽은 이름 바로 뒤에서 닫히고 그 뒤가 `)` · `->` 가 아니어야 한다) · 이름 annotation 다음 줄의 클래스.
ufresh
mark_after "$XK" 1 'val o = this@GeneratedOuter'
mark_after "$XK" 2 'return@GeneratedLoop'
mark_after "$XK" 3 'break@GeneratedLoop'
mark_after "$XK" 4 'continue@GeneratedLoop'
mark_after "$XK" 5 'super@GeneratedBase.f()'
mark_after "$XK" 6 'super<Base>@GeneratedOuter.f()'
mark_after "$XK" 7 'val s = " @$GeneratedId"'
mark_after "$XK" 8 'val t = "${user}@$GeneratedHost"'
mark_after "$XK" 9 'class GeneratedToken'
mark_after "$XK" 10 'typealias Handler = (GeneratedEvent) -> Unit'
mark_after "$XK" 11 'typealias Pair2 = (GeneratedEvent, Int) -> Unit'
mark_after "$XK" 12 'typealias Nested = ((GeneratedEvent)) -> Unit'
mark_after "$XK" 13 'val annotation = 1'
mark_after "$XK" 14 'class GeneratedModel'
run unit-report kotlin "$T" --out "$D"
assert_eq 0 "$RC" "[markers] kotlin 대조군 둘째 — 레이블 여섯 · \$ 템플릿 둘 · 보통 클래스 둘 · 함수 타입 별칭 셋 · 이름 annotation 은 조용하다(exit 0) — 출력: $OUT"
assert_line "$OUT" "[kotlin] coverage-exclusion markers: none in 2 tracked files under kotlin/src/main/kotlin" "[markers] kotlin 대조군 둘째 — 표지 0"
ufresh
mark_after "$XK" 1 '@get:Generatde'
mark_after "$XK" 3 'import kc.auth.GeneratedToken'
mark_after "$XK" 5 'import kc.GeneratedModels.User as U'
mark_after "$XK" 7 '@[JvmName("getGeneratedValue")]'
mark_after "$XK" 9 '@[Deprecated("Generated externally")]'
mark_after "$XK" 11 'val x = this@GeneratedClient'
mark_after "$XK" 13 '@[A("${"Generated"}")]'
mark_after "$XK" 15 '@[A(x = """Generated""")]'
run unit-report kotlin "$T" --out "$D"
assert_eq 0 "$RC" "[markers] kotlin 대조군 — 오표기 · 표지 아닌 이름 일곱(인자의 템플릿 · 원문 문자열 포함)은 조용하다(exit 0) — 출력: $OUT"
assert_line "$OUT" "[kotlin] coverage-exclusion markers: none in 2 tracked files under kotlin/src/main/kotlin" "[markers] kotlin 대조군 — 표지 0"

# (사) ruby — :nocov: 쌍(들여쓴 꼴도)과 그 대체 # simplecov:disable(코드 뒤 한 줄 꼴).
XR=ruby/lib/kc/config.rb
ufresh
mark_after "$XR" 1 '# :nocov:'
mark_after "$XR" 3 '  #   :nocov:'
mark_after "$XR" 5 'x = 1 # simplecov:disable line'
run unit-report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[markers] ruby 의 표지 셋이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[ruby] coverage-exclusion markers: 3 in 3 tracked files under ruby/lib — each is a FAIL below" "[markers] ruby — 읽은 추적 파일 수 · 표지 수"
assert_contains "$OUT" "FAIL [ruby] $XR:2: coverage-exclusion marker \`# :nocov:\` in" "[markers] :nocov:"
assert_contains "$OUT" "FAIL [ruby] $XR:4: coverage-exclusion marker \`# :nocov:\` in" "[markers] 들여쓴 :nocov:(표기는 한 칸으로 찍는다)"
assert_contains "$OUT" "FAIL [ruby] $XR:6: coverage-exclusion marker \`# simplecov:disable\` in" "[markers] simplecov:disable"
assert_line "$OUT" "unit-unreached [ruby]: FAIL — 3 $MVERDICT" "[markers] ruby — 다른 FAIL 은 없다"
ufresh
mark_after "$XR" 1 '# :nocvo:'
run unit-report ruby "$T" --out "$D"
assert_eq 0 "$RC" "[markers] ruby 대조군 — exit 0 — 출력: $OUT"
assert_line "$OUT" "[ruby] coverage-exclusion markers: none in 3 tracked files under ruby/lib" "[markers] ruby 대조군 — 표지 0"

# (아) rust — cfg_attr 안의 coverage(off) · 괄호 안 공백.
XS=rust/src/config.rs
rsfresh
mark_after "$XS" 1 '#[cfg_attr(coverage_nightly, coverage(off))]'
mark_after "$XS" 3 '#[coverage( off )]'
run unit-report rust "$T" --out "$D"
assert_eq 2 "$RC" "[markers] rust 의 표지 둘이면 exit 2 — 출력: $OUT"
assert_line "$OUT" "[rust] coverage-exclusion markers: 2 in 3 tracked files under rust/src — each is a FAIL below" "[markers] rust — 읽은 추적 파일 수 · 표지 수"
assert_contains "$OUT" "FAIL [rust] $XS:2: coverage-exclusion marker \`coverage(off)\` in" "[markers] cfg_attr 안의 coverage(off)"
assert_contains "$OUT" "FAIL [rust] $XS:4: coverage-exclusion marker \`coverage( off )\` in" "[markers] 괄호 안 공백"
assert_line "$OUT" "unit-unreached [rust]: FAIL — 2 $MVERDICT" "[markers] rust — 다른 FAIL 은 없다"
rsfresh
mark_after "$XS" 1 '#[coverage(of)]'
run unit-report rust "$T" --out "$D"
assert_eq 0 "$RC" "[markers] rust 대조군 — exit 0 — 출력: $OUT"
assert_line "$OUT" "[rust] coverage-exclusion markers: none in 3 tracked files under rust/src" "[markers] rust 대조군 — 표지 0"

# (자) go — go tool cover 에는 표지가 없다: 읽지 않는다고 말한다.
ufresh
run unit-report go "$T" --out "$D"
assert_eq 0 "$RC" "[markers] go — exit 0 — 출력: $OUT"
assert_line "$OUT" "[go] coverage-exclusion markers: not scanned — go tool cover has no exclusion marker" "[markers] go — 읽지 않는다"

# (차) 공허 — 추적된 출하 파일이 0 이면(자리가 낡았다 · git 이 추적 파일을 못 낸다) 표지 0 이 아니라 FAIL 이다. `run` 은 git add 를 하므로
# 도구를 곧바로 부른다(파생도 같은 추적 파일을 읽어 함께 FAIL 이다 — 여기서 보는 것은 표지 스캔의 줄이다).
ufresh
git -C "$T" rm -r -q --cached node/src
OUT="$(node "$TOOL" unit-report node "$T" --out "$D" 2>&1)" && RC=0 || RC=$?
assert_eq 2 "$RC" "[markers] 추적된 출하 파일이 0 이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] no tracked files under node/src in " "[markers] 공허는 FAIL 이다 — 자리를 댄다"
assert_contains "$OUT" " — the coverage-exclusion marker scan would read nothing" "[markers] 공허 — 까닭"
assert_not_contains "$OUT" "coverage-exclusion markers: none" "[markers] 공허는 「표지 0」으로 읽히지 않는다"
ufresh
rm -rf "$T/.git"
OUT="$(node "$TOOL" unit-report node "$T" --out "$D" 2>&1)" && RC=0 || RC=$?
assert_eq 2 "$RC" "[markers] git 이 추적 파일을 못 내면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] no tracked files under node/src in " "[markers] git 실패도 공허다"
assert_contains "$OUT" "(git ls-files: " "[markers] git 의 까닭을 단다"
# 공허는 roots 로만 판정한다 — also(dotnet/Directory.Build.props)가 추적돼 있어도 dotnet/src 가 비면 FAIL 이다.
ufresh
printf '%s\n' '<Project />' > "$T/dotnet/Directory.Build.props"
git -C "$T" add -A
git -C "$T" rm -r -q --cached dotnet/src
OUT="$(node "$TOOL" unit-report dotnet "$T" --out "$D" 2>&1)" && RC=0 || RC=$?
assert_eq 2 "$RC" "[markers] roots 가 비면 also 가 있어도 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] no tracked files under dotnet/src in " "[markers] 공허는 roots 의 이름으로 댄다"
# 추적됐는데 못 읽는 자리(하위 모듈 · 디렉터리)는 FAIL 이다 — 그 안의 표지를 볼 수 없다(던지면 종료코드 1, 곧 DRIFT 의 뜻이 됐다).
ufresh
mkdir -p "$T/node/src/sub"
git -C "$T" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,node/src/sub
OUT="$(node "$TOOL" unit-report node "$T" --out "$D" 2>&1)" && RC=0 || RC=$?
assert_eq 2 "$RC" "[markers] 추적된 하위 모듈 자리는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] node/src/sub: tracked but not a regular file (a submodule or a directory?) — the coverage-exclusion marker scan cannot read it" "[markers] 못 읽는 추적 자리는 FAIL"
assert_line "$OUT" "unit-unreached [node]: FAIL — 1 integrity failure; the ledger is not compared against a run that failed one" "[markers] 하위 모듈 자리 — 다른 FAIL 은 없다(파생은 .ts 만 본다)"

# (카) 실제 트리 — 여덟 출하 소스에 표지가 없다(데이터 없이 표지 스캔의 줄만 본다 — 리더는 데이터가 없어 FAIL 이다).
REAL="$(cd "$DIR/../.." && pwd)"
for _l in kotlin php dotnet java ruby python node rust; do
  OUT="$(node "$TOOL" unit-report "$_l" "$REAL" --out "$TMP/no-data" 2>&1)" && RC=0 || RC=$?
  assert_contains "$OUT" "[$_l] coverage-exclusion markers: none in " "[markers] 실제 트리 — $_l 의 출하 소스에 표지가 없다 — 출력: $OUT"
done

assert_report
