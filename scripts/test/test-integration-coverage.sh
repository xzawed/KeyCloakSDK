#!/usr/bin/env sh
# 통합 전용 커버리지 리포트(`scripts/integration-coverage.mjs`) 자가테스트 — go · python · node · rust · php · ruby · dotnet · java · kotlin
# 의 무결성 판정과 하한.
#
# ⚠️ **커밋된 픽스처만 쓴다** — Docker 도 Go·Python·node·rust·php·ruby·dotnet·JDK·Gradle 툴체인도 필요 없다. 실제 Keycloak 에 대고 도는 것은
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
#   data/node.json         vitest 5.0.1 + @vitest/coverage-v8 의 `coverage-final.json`(2026-11-05) — `node/` 아래 임시 루트에
#                          tree/node/src 사본 + 구동 테스트를 두고 `--coverage.include=src/**/*.ts --coverage.reporter=json`.
#                          **생성 루트만 `@ROOT@` 로 바꿨다**(istanbul 키는 절대 경로다 — fresh 가 임시 트리 경로로 되돌린다)
#   data/node-zero.json    같은 명령, 구동기가 경계 밖 other.ts 만 부른다 — auth.ts 전부 0
#   data/rust.lcov         cargo-llvm-cov 0.8.7(rustc 1.89.0)의 `--offline --test drive --lcov`(2026-11-05) — 임시 크레이트에
#                          tree/rust/src 사본 + 구동 테스트, 의존은 `async-trait = "=0.1.92"`(rust/Cargo.lock 의 판) 하나.
#                          **SF 의 생성 루트만 `@ROOT@\rust\` 로 바꿨다**(윈도의 `\` 그대로)
#   data/rust-zero.lcov    같은 명령, 구동기가 경계 함수의 포인터만 잡고(링크는 되고) 아무것도 안 부른다 — 포인터가 없으면
#                          경계 세 파일이 데이터에서 **통째로 빠진다**(참조 안 된 모듈의 오브젝트는 링크되지 않는다)
#   data/rust-unit.lcov    `--lib --test drive` — 단위 테스트가 같은 빌드에서 돌아 `#[cfg(test)]` 와 `#[cfg(all(test,
#                          debug_assertions))]` 함수의 레코드가 든다
#   data/php/              PHPUnit 12.5.33 + php-code-coverage 12.5.7 + Xdebug 3.5.3 의 `--coverage-xml`(2026-11-05) — 임시
#                          루트에 tree/php 사본 + 구동 테스트, 설정은 도구의 run 이 만드는 꼴(`<source><include>` = 경계 두 파일).
#                          **index.xml 의 `<project source>` 생성 루트만 `@ROOT@` 로 바꿨다**(파일 XML 은 상대 경로뿐이다)
#   data/php-zero/         같은 명령, 구동기가 경계를 하나도 안 부른다 — 전부 0
#   data/ruby.json         **도구의 `run ruby` 그대로**(ruby 3.4.10 · 2026-11-06) — 임시 루트에 tree 사본, 번들은 실제 레인의 것
#                          (`BUNDLE_GEMFILE=ruby/Gemfile`). **덤프의 생성 루트만 `@ROOT@` 로 바꿨다**(root 와 파일 키는 절대 경로다)
#   data/ruby-zero.json    같은 명령, 구동 스펙이 경계 밖 `Config` 만 만든다 — 메서드 몸통 전부 0
#   data/dotnet.json       **도구의 `run dotnet` 그대로**(.NET SDK 10.0.102 → net8.0 · coverlet.collector 10.1.0 · 2026-11-06) — 임시
#                          루트에 tree 사본. 문서 키는 절대 경로다 — **생성 루트만 `@ROOT@` 로 바꿨다**(JSON 의 `\\` 그대로)
#   data/dotnet.trx        같은 실행의 trx — 생성 루트(`@ROOT@` · 소문자 `@root@`)와 기계 · 사용자 이름(HOST · USER)만 바꿨다
#                          (치환마다 되돌린 바이트가 원본과 같다)
#   data/dotnet-zero.*     같은 명령, 구동 테스트가 경계 밖 `Config` 만 만든다 — 경계 줄 전부 0
#   data/java.xml          **도구의 `run java` 그대로**(JDK 21.0.8 · Maven 3.9.9 · JaCoCo 0.8.16 · 2026-11-07) — 임시 루트에 tree 사본.
#                          경로는 없다 — 세션 id 의 기계 이름만 `HOST-00000000` 으로 바꿨다
#   data/java.javap.txt    같은 빌드의 `javap -l -p -v` 출력(run java 가 남긴 것) — 줄끝을 LF 로, `Classfile` 의 생성 루트를 지워
#                          `java/` 부터로만 바꿨다(0 실행과 클래스 사실이 같다 — 실측: 그 둘에서 푼 사실이 바이트째 같았다)
#   data/java-zero.xml     같은 명령, `KC_FIXTURE_ZERO=1` 로 구동 테스트가 경계 클래스를 싣기만 한다 — 정적 초기화만 돈다
#   data/kotlin.xml        **도구의 `run kotlin` 그대로**(JDK 21.0.8 · kotlin 2.4.21 · JaCoCo 0.8.16 · 2026-11-07) — 임시 루트에 tree 사본
#                          (Gradle 래퍼는 생성 때만 실제 kotlin/ 에서 넣었다). 세션 id 의 기계 이름만 `HOST-00000000` 으로 바꿨다
#   data/kotlin.javap.txt  같은 빌드의 `javap -l -p -v` 출력 — 줄끝을 LF 로, `Classfile` 의 생성 루트를 지워 `kotlin/` 부터로만 바꿨다
#   data/kotlin-zero.xml   같은 명령, `KC_FIXTURE_ZERO=1` 로 구동 테스트가 경계 클래스를 싣기만 한다(javap 출력은 바이트째 같았다)
# ruby 구동 스펙은 「logout_url · AuthClient.build · introspect · close · flush」를 안 부르고 `token` 의 nil 갈래를 안 탄다.
# dotnet 구동 테스트는 「두 번째 생성자 · Describe(int) · LogoutAsync · Build · Unused · Later · Lower · NamesAsync · Retries 의
# setter · Close · Dispose · Defaults · DeleteAsync」를 안 부르고 `TokenAsync` 의 빈 code 갈래 · `RetryAsync` 의 fail 갈래(그 안의
# async 람다)를 안 탄다(`UnitTests` 는 Trait 이 없는 통합 밖 테스트다 — 레인의 필터가 거른다).
# java 구동 테스트(`DriveIT`)는 「token(String, int) · unused · QuickStart 전체」를 안 부르고 정적 람다 `UPPER` 는 `names` 를 거쳐 부른다.
# kotlin 구동 테스트(`DriveIT`)는 「token(String, Int) · unused · Companion 의 REALM 읽기 · 속성 greet 와 초기화 블록 ready 의 람다 ·
# withLocalClass · join(List<String>) · AuthClientStatus 의 생성자 · AuthClientDefaults.pick(Int) · AuthClientIdle · QuickStart
# 전체」를 안 부르고, internal `mask` · `pick(AuthClientDefaults?, Int)` · `ping()` 은 기본 인자 다리로 · `join(List<Int>)` 는 JVM
# 이름 joinInts 로 · 컴패니언 init 은 `AuthClientStatus.ok()` 로 부른다.
# php 구동기는 「groups·adminHelper·logoutUrl·__debugInfo」를 안 부르고 `exchange` 의 throw 갈래를 안 탄다.
# 구동기는 「String·Close·Delete·AuthClient.String·hook 리터럴」과 「__repr__·logout·clients·aio 전체」를, node 는
# 「describe·toString·[SYM]·inc·cb·set count·overload·longSignature·close」를, rust 는 「transport·supply·describe·noop·close·
# Display::fmt·Wrapper<u16>::get·admin·unused_count」를 일부러 안 부르고 `delete_user` · `never_polled` 의 퓨처는 만들기만 하고 버리며, 주석뿐인
# async `warm_up` 은 poll 한다(rust 의 `unused_helper` · 제네릭 `From::from` 은 아무도 참조하지 않아, `platform` 의 `not(windows)` ·
# `family` 의 `any(linux …)` 쌍둥이는 생성한 윈도에서 컴파일되지 않아 데이터에 레코드가 없다). 숫자를 바꾸려면 구동기를 다시 써서
# **도구로 재생성**할 것 — 데이터를 손으로 고치지 않는다.
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
  node_data "$FIX/data/node.json"
  rust_data "$FIX/data/rust.lcov"
  php_data "$FIX/data/php"
  ruby_data "$FIX/data/ruby.json"
  dotnet_data "$FIX/data/dotnet.json" "$FIX/data/dotnet.trx"
  java_data "$FIX/data/java.xml"
  kotlin_data "$FIX/data/kotlin.xml"
  git -C "$T" init -q
  git -C "$T" config core.autocrlf false
  git -C "$T" add -A
}
# istanbul 키는 절대 경로다 — 픽스처의 `@ROOT@` 를 이 트리의 경로로(윈도는 `pwd -W` 의 `C:/…` 꼴이 node 가 보는 경로다).
node_data() { # fixture-json
  mkdir -p "$D/node"
  _r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
  sed "s#@ROOT@#$_r#g" "$1" > "$D/node/coverage-final.json"
}
# lcov 의 SF 도 절대 경로다 — 같은 치환(뒤의 `\rust\src\…` 는 리포트가 `/` 로 읽는다).
rust_data() { # fixture-lcov
  _r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
  sed "s#@ROOT@#$_r#g" "$1" > "$D/rust.lcov"
}
# PHPUnit 의 XML 커버리지는 디렉터리다 — 절대 경로는 index.xml 의 `<project source>` 하나다(같은 치환).
php_data() { # fixture-dir
  _r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
  rm -rf "$D/php"
  cp -r "$1" "$D/php"
  sed -i "s#@ROOT@#$_r#g" "$D/php/index.xml"
  php_mark 0
}
# `run php` 의 기록(종료코드 · 지금 index.xml 의 sha1)을 쓴다 — run 이 쓰는 것과 같은 꼴. 데이터를 고친 뒤 OK 를 기대하는
# 단언은 이것을 다시 불러야 한다(기록 뒤 바뀐 데이터는 FAIL 이다).
php_mark() { # exit
  printf '{"run":"php","exit":%s,"index_sha1":"%s"}\n' "$1" "$(sha1sum "$D/php/index.xml" | cut -d' ' -f1)" > "$D/php.run.json"
}
# `run ruby` 의 덤프 — 루트와 파일 키가 절대 경로다(Ruby 의 `File.expand_path` — 윈도도 `C:/…`, `/` 구분). 같은 치환 뒤 기록을 쓴다.
ruby_data() { # fixture-json
  _r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
  sed "s#@ROOT@#$_r#g" "$1" > "$D/ruby.json"
  ruby_mark 0
}
# `run ruby` 의 기록(종료코드 · 지금 덤프의 sha1) — php_mark 와 같은 쓰임.
ruby_mark() { # exit
  printf '{"run":"ruby","exit":%s,"dump_sha1":"%s"}\n' "$1" "$(sha1sum "$D/ruby.json" | cut -d' ' -f1)" > "$D/ruby.run.json"
}
# `run dotnet` 의 데이터(coverlet JSON — 문서 키가 절대 경로)와 trx(테스트 어셈블리 경로가 절대 경로) — 같은 치환 뒤 기록을 쓴다.
dotnet_data() { # fixture-json fixture-trx
  _r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
  sed "s#@ROOT@#$_r#g" "$1" > "$D/dotnet.json"
  sed "s#@ROOT@#$_r#g; s#@root@#$_r#g" "$2" > "$D/dotnet.trx"
  dotnet_mark 0
}
# `run dotnet` 의 기록(종료코드 · 데이터와 trx 의 sha1 · 경계 파일의 sha1 — coverlet 데이터에는 해시가 없다) — php_mark 와 같은 쓰임.
dotnet_mark() { # exit
  printf '{"run":"dotnet","exit":%s,"data_sha1":"%s","trx_sha1":"%s","files":{"dotnet/src/Kc/Admin/Client.cs":"%s","dotnet/src/Kc/AuthClient.cs":"%s"}}\n' "$1" \
    "$(sha1sum "$D/dotnet.json" | cut -d' ' -f1)" "$(sha1sum "$D/dotnet.trx" | cut -d' ' -f1)" \
    "$(sha1sum "$T/dotnet/src/Kc/Admin/Client.cs" | cut -d' ' -f1)" "$(sha1sum "$T/dotnet/src/Kc/AuthClient.cs" | cut -d' ' -f1)" > "$D/dotnet.run.json"
}
# `run java` 의 데이터(JaCoCo XML — 경로가 없다)와 javap 의 출력(리포트가 LineNumberTable · EnclosingMethod 를 푼다) — 기록을 쓴다.
java_data() { # fixture-xml
  cp "$1" "$D/java.xml"
  cp "$FIX/data/java.javap.txt" "$D/java.javap.txt"
  java_mark 0
}
# `run java` 의 기록(종료코드 · 데이터와 javap 출력의 sha1 · failsafe 의 테스트 수 · surefire 보고 수 · 경계 파일의 sha1) — php_mark 와 같은 쓰임.
java_mark() { # exit
  printf '{"run":"java","exit":%s,"jacoco":"0.8.16","data_sha1":"%s","javap_sha1":"%s","tests":{"completed":1,"failures":0,"errors":0,"skipped":0},"unit":0,"files":{"java/kc-auth/src/main/java/kc/auth/AuthClient.java":"%s","java/kc-examples/src/main/java/kc/examples/QuickStart.java":"%s"}}\n' "$1" \
    "$(sha1sum "$D/java.xml" | cut -d' ' -f1)" "$(sha1sum "$D/java.javap.txt" | cut -d' ' -f1)" \
    "$(sha1sum "$T/java/kc-auth/src/main/java/kc/auth/AuthClient.java" | cut -d' ' -f1)" "$(sha1sum "$T/java/kc-examples/src/main/java/kc/examples/QuickStart.java" | cut -d' ' -f1)" > "$D/java.run.json"
}
# `run kotlin` 의 데이터(JaCoCo XML)와 javap 의 출력 — 기록을 쓴다(java 와 같은 리더).
kotlin_data() { # fixture-xml
  cp "$1" "$D/kotlin.xml"
  cp "$FIX/data/kotlin.javap.txt" "$D/kotlin.javap.txt"
  kotlin_mark 0
}
# `run kotlin` 의 기록 — java 의 것에 모듈 이름(META-INF/<모듈>.kotlin_module — `internal` 멤버 이름의 접미)이 더해진다.
kotlin_mark() { # exit
  printf '{"run":"kotlin","exit":%s,"jacoco":"0.8.16","module":"kc-kotlin","data_sha1":"%s","javap_sha1":"%s","tests":{"completed":1,"failures":0,"errors":0,"skipped":0},"unit":0,"files":{"kotlin/src/main/kotlin/kc/auth/AuthClient.kt":"%s","kotlin/src/main/kotlin/kc/examples/QuickStart.kt":"%s"}}\n' "$1" \
    "$(sha1sum "$D/kotlin.xml" | cut -d' ' -f1)" "$(sha1sum "$D/kotlin.javap.txt" | cut -d' ' -f1)" \
    "$(sha1sum "$T/kotlin/src/main/kotlin/kc/auth/AuthClient.kt" | cut -d' ' -f1)" "$(sha1sum "$T/kotlin/src/main/kotlin/kc/examples/QuickStart.kt" | cut -d' ' -f1)" > "$D/kotlin.run.json"
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
assert_line "$OUT" "[node] pin OK — 2 files equal the derivation from node/vitest.config.ts:9 (vitest coverage.exclude)" "[check] node 핀 = 파생"
assert_line "$OUT" "[rust] pin OK — 3 files equal the derivation from .github/workflows/rust-ci.yml:7 (cargo llvm-cov --ignore-filename-regex)" "[check] rust 핀 = 파생"
assert_line "$OUT" "[php] pin OK — 2 files equal the derivation from php/phpunit.xml:11 (phpunit <source><exclude>)" "[check] php 핀 = 파생"
assert_line "$OUT" "[ruby] pin OK — 3 files equal the derivation from ruby/spec/spec_helper.rb:8 (SimpleCov skip)" "[check] ruby 핀 = 파생"
assert_line "$OUT" "[dotnet] pin OK — 2 files equal the derivation from dotnet/coverlet.runsettings:9 (coverlet <Exclude>)" "[check] dotnet 핀 = 파생"
assert_line "$OUT" "[kotlin] pin OK — 2 files equal the derivation from kotlin/build.gradle.kts:46 (kover excludes.classes)" "[check] kotlin 핀 = 파생"
assert_line "$OUT" "integration-coverage check: OK — go 3 · python 3 · node 2 · rust 3 · php 2 · ruby 3 · dotnet 2 · java 2 · kotlin 2 files pinned · 75 owner entries, all open" "[check] 요약"

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

# node — 이름은 소스(prettier 모양)에서 읽는다. v8 의 fnMap 이름은 `(anonymous_1)` · `count_2` · `SYM` 이다(실측) — 그것을
# 쓰면 아래 이름이 나오지 않는다. 각 줄이 재는 것: 클래스 한정 · private · 계산된 이름 · getter/setter 갈림 · 한 줄 멤버
# (문자열 속 `{` 를 세지 않는다) · 템플릿 속 `  }`·열 0 `function` · 블록 주석 속 열 0 `function` · 오버로드(몸통 없는 선언은
# 범위가 아니다) · 여러 줄 시그니처 · 'value' 범위의 대입 문장은 함수가 아니다(`inc` · `cb`) · `Pair` 의 다섯(#953 독립 레그):
# `) {}` 로 닫는 매개변수 속성 생성자 · `static from` 과 `from` · 문자열이 든 계산된 이름(원문으로) · 값이 식별자뿐인 필드
# (`#closed = false`)는 함수가 아니다 · 중첩 `=>` 제네릭 머리. 모듈 수준 7/8 = 대입 둘 + 필드 둘 + 위의 셋 — 생성자·`apply` 를
# 놓치거나 `#closed` 를 함수로 읽으면 이 수가 바뀐다.
run report node "$T" --out "$D"
assert_eq 0 "$RC" "[node] 건강한 리포트는 exit 0 — 출력: $OUT"
assert_line "$OUT" "  node/src/auth.ts 21/34 61.8% (module-level 7/8)" "[node] auth.ts — 대입·필드 문장은 모듈·클래스 수준, 생성자·제네릭 멤버는 범위다"
assert_line "$OUT" "  node/src/index.ts 0/0 n/a" "[node] 재수출만 있는 경계 파일은 0/0 으로 든다(데이터에는 있다)"
assert_line "$OUT" "  total 21/34 61.8%" "[node] 합계는 경계 파일만(other.ts 제외)"
assert_line "$OUT" "  NEVER node/src/auth.ts:26 Masked.describe · 1 stmt · owner open-masking" "[node] 템플릿 속 줄이 멤버를 닫지 않는다"
assert_line "$OUT" "  NEVER node/src/auth.ts:33 Masked.toString · 1 stmt · owner open-masking" "[node] 문자열 속 { 가 든 한 줄 멤버"
assert_line "$OUT" "  NEVER node/src/auth.ts:35 Masked.[SYM] · 1 stmt · owner open-masking" "[node] 계산된 이름"
assert_line "$OUT" "  NEVER node/src/auth.ts:48 inc · 1 stmt · owner open-admin" "[node] 한 줄 화살표 const — 선언은 돌았고 본문은 안 돌았다"
assert_line "$OUT" "  NEVER node/src/auth.ts:52 Client.cb · 1 stmt · owner open-admin" "[node] 화살표 함수 속성"
assert_line "$OUT" "  NEVER node/src/auth.ts:58 Client.set count · 1 stmt · owner open-admin" "[node] setter 는 getter 와 갈린다"
assert_line "$OUT" "  NEVER node/src/auth.ts:71 Client.overload · 1 stmt · owner open-admin" "[node] 오버로드의 구현만 범위다"
assert_line "$OUT" "  NEVER node/src/auth.ts:75 Client.longSignature · 1 stmt · owner open-admin" "[node] 여러 줄 시그니처"
assert_line "$OUT" "  NEVER node/src/auth.ts:85 Client.close · 1 stmt · owner open-admin" "[node] 블록 주석 속 열 0 function 뒤의 멤버"
assert_line "$OUT" "  NEVER node/src/auth.ts:106 Pair.from · 1 stmt · owner open-admin" "[node] 인스턴스 from — static from 과 갈린다"
assert_line "$OUT" "  NEVER node/src/auth.ts:110 Pair.[Symbol.for('pair.inspect')] · 1 stmt · owner open-masking" "[node] 계산된 이름은 원문 그대로(문자열이 지워지지 않는다)"
assert_line "$OUT" "  NEVER node/src/auth.ts:118 Pair.closed · 1 stmt · owner open-admin" "[node] 필드 뒤의 메서드"
for _x in other.ts fake hidden NotAClass helper twice Client.run "get count" Masked.render "#secret" constructor "static from" Pair.apply "#closed"; do
  assert_not_contains "$OUT" "$_x" "[node] 실행된 함수 · 경계 밖 · 주석·문자열 속 이름 · 필드는 목록에 없다: $_x"
done
assert_line "$OUT" "integration-coverage [node]: OK — 21/34 statements (61.8%) · 12 never-executed functions, all owned by open registry items" "[node] 요약"

# rust — 이름은 소스(rustfmt 모양)에서 읽고 llvm-cov 의 함수 레코드(FN)와 양쪽으로 대조한다. 수치는 고유 줄(DA)이다 —
# 같은 데이터의 LF 합 166 은 async fn 의 바깥 함수·몸통이 같은 줄을 두 번 센 것이다. 각 줄이 재는 것: 중첩 블록 주석 ·
# 원시 문자열 · 여러 줄 문자열 속 `fn …{`·`    }` 가 항목을 열고 닫지 않는다 · 문자 리터럴 `'"'`·`'{'` 와 수명 `'a` ·
# 빈 몸통 한 줄 fn · 같은 타입의 `Debug::fmt`/`Display::fmt` 와 `Wrapper<u8>`/`Wrapper<u16>` 이 갈린다 · 레코드 없는 함수
# (아무도 참조 안 한 fn · 인스턴스화 안 된 제네릭 · 이 빌드에서 cfg 로 빠진 쌍둥이)도 미실행이다 · 퓨처만 만들고 버린 async fn
# 은 미실행이다(바깥 함수는 돌았다) · static 의 클로저는 그 static 의 범위다(GREETING 은 돌았다) · 비ASCII 이름(`größe`) ·
# `#[cfg(test)]` 와 `#[cfg(all(test, debug_assertions))]` 모듈은 읽지 않는다(읽으면 그 함수들이 레코드 없는 미실행으로 든다).
run report rust "$T" --out "$D"
assert_eq 0 "$RC" "[rust] 건강한 리포트는 exit 0 — 출력: $OUT"
assert_line "$OUT" "  rust/src/admin.rs 38/43 88.4%" "[rust] admin.rs — 열 4 의 } 를 품은 최상위 fn · async 메서드 · 트레이트 impl 의 async fn"
assert_line "$OUT" "  rust/src/auth.rs 51/69 73.9%" "[rust] auth.rs — 범위 밖 줄이 없다(module-level 이 안 찍힌다)"
assert_line "$OUT" "  rust/src/client.rs 27/47 57.4%" "[rust] client.rs — static 클로저 줄은 그 static 의 범위다(모듈 수준이 아니다)"
assert_line "$OUT" "  total 116/159 73.0%" "[rust] 합계는 경계 파일만(config.rs · lib.rs 제외) — LF 합(166)이 아니라 고유 줄"
assert_line "$OUT" "  NEVER rust/src/admin.rs:21 transport · 3 lines · owner open-admin" "[rust] 안 탄 오류 갈래에서만 불리는 최상위 fn"
assert_line "$OUT" "  NEVER rust/src/admin.rs:54 AdminClient::delete_user · called, but its async body never ran · owner open-admin" "[rust] 퓨처를 만들고 버린 async fn — 바깥 함수는 돌았고(FNDA 1) 몸통 줄은 데이터에 없다"
assert_line "$OUT" "  NEVER rust/src/admin.rs:64 <AdminClient as Supplier>::supply · 1 line · owner open-admin" "[rust] 트레이트 impl 의 async fn — <타입 as 트레이트>::"
assert_line "$OUT" "  NEVER rust/src/auth.rs:42 AuthClient::describe · 7 lines · owner open-masking" "[rust] 여러 줄 문자열 속 \`    }\` 가 메서드를 닫지 않는다"
assert_line "$OUT" "  NEVER rust/src/auth.rs:61 AuthClient::noop · 1 line · owner open-admin" "[rust] 빈 몸통 한 줄 fn"
assert_line "$OUT" "  NEVER rust/src/auth.rs:63 AuthClient::close · 3 lines · owner open-admin" "[rust] 한 줄 fn 뒤의 메서드"
assert_line "$OUT" "  NEVER rust/src/auth.rs:75 <AuthClient as fmt::Display>::fmt · 3 lines · owner open-masking" "[rust] Display::fmt 는 Debug::fmt 와 갈린다"
assert_line "$OUT" "  NEVER rust/src/auth.rs:103 Wrapper<u16>::get · 3 lines · owner open-admin" "[rust] Wrapper<u16> 은 Wrapper<u8> 과 갈린다"
assert_line "$OUT" "  NEVER rust/src/auth.rs:109 <Wrapper<usize> as From<&'a [T]>>::from · no record in the data · owner open-admin" "[rust] 인스턴스화 안 된 제네릭은 레코드가 없다 — 그래도 미실행이다"
assert_line "$OUT" "  NEVER rust/src/auth.rs:129 unused_helper · no record in the data · owner open-admin" "[rust] 아무도 참조 안 한 fn 도 레코드가 없다"
assert_line "$OUT" "  NEVER rust/src/client.rs:25 KeycloakClient::admin · 3 lines · owner open-admin" "[rust] client.rs"
assert_line "$OUT" "  NEVER rust/src/client.rs:37 unused_count · 3 lines · owner open-admin" "[rust] pub fn 은 안 불려도 0 회 레코드가 남는다"
assert_line "$OUT" "  NEVER rust/src/client.rs:47 platform #[cfg(not(windows))] · no record in the data · owner open-admin" "[rust] cfg 쌍둥이는 이름에 cfg 가 붙어 갈린다 — 컴파일 안 된 쪽은 레코드가 없다 · 속성 뒤 주석은 이름에 안 든다"
assert_line "$OUT" "  NEVER rust/src/client.rs:81 family #[cfg(any(target_os = \"linux\", target_os = \"macos\", target_os = \"freebsd\", target_os = \"openbsd\"))] · no record in the data · owner open-admin" "[rust] rustfmt 가 접은 cfg 는 이어 읽어 한 줄 이름이 된다"
assert_line "$OUT" "  NEVER rust/src/client.rs:100 never_polled · called, but its async body never ran · owner open-admin" "[rust] 최상위 async fn 의 퓨처를 버렸다"
assert_line "$OUT" "  NEVER rust/src/client.rs:108 KeycloakClient::scoped · 3 lines · owner open-admin" "[rust] 이름 없는 const 블록 안의 impl 은 타입 경로 그대로 읽는다"
assert_line "$OUT" "  NEVER rust/src/client.rs:113 const _::block_local · 3 lines · owner open-admin" "[rust] const 블록 안의 자유 fn 은 const _:: 로 갈려 바깥 같은 이름과 안 겹친다"
assert_line "$OUT" "  NEVER rust/src/client.rs:118 block_local · 3 lines · owner open-admin" "[rust] 바깥의 같은 이름 fn"
assert_line "$OUT" "  NEVER rust/src/client.rs:123 const _#3 · 4 lines · owner open-admin" "[rust] 클로저 값 const _ 는 순번 범위다(단언 둘이 #1 · #2)"
# `#[async_trait]` 멤버는 async 판정에서 빠진다 — 그 몸통은 레코드도 DA 도 안 남아(async-trait 0.1.92 실제 출력: poll 한 Polled ·
# 버린 Dropped 둘 다 머리·닫는 줄에 바깥 횟수뿐) poll 여부를 못 가른다. 걸면 poll 한 Polled 가 「안 돌았다」가 된다(독립 레그 3차).
# 버린 Dropped 가 실행으로 읽히는 것은 머리 주석에 적은 한계다.
for _x in hidden doc_fake raw_fake string_fake tests:: "platform #[cfg(windows)]" exchange_rejects_empty AuthClient::new AuthClient::realm AuthClient::exchange AuthClient::apply "AuthClient::token ·" fmt::Debug token_twice token_now "Wrapper<u8>" " helper ·" inner:: nested_level encode AdminClient::send get_user search_users KeycloakClient::new KeycloakClient::auth config.rs lib.rs module-level debug_tests "static GREETING" "static UNUSED" "const BANNER" größe "every other platform" "const _#1" "const _#2" warm_up "family #[cfg(not(" "Polled as Fetch" "Dropped as Fetch" "Fetch::fetch"; do
  assert_not_contains "$OUT" "$_x" "[rust] 실행된 함수 · 경계 밖 · 주석·문자열 속 이름 · cfg(test) · 코드 없는 상수 · async_trait 멤버는 목록에 없다: $_x"
done
assert_line "$OUT" "integration-coverage [rust]: OK — 116/159 lines (73.0%) · 19 never-executed functions, all owned by open registry items" "[rust] 요약"

# php — 이름 · 범위 · 실행 줄은 php-code-coverage(PHPUnit XML 형식)가 낸다: 그 파서(nikic/php-parser)가 잡은 클래스 · 트레이트
# · 함수와 각각의 실행 가능 줄 수. 리포트가 대조하는 셋 — 파일 해시(데이터가 이 트리의 그 바이트에서 났다) · 메서드 합 = 파일
# 합(메서드 밖 줄이 없다) · index.xml 합 = 파일 XML 합. 각 줄이 재는 것: 일부만 돈 메서드는 미실행이 아니다(`exchange`) ·
# 클로저와 익명 클래스의 줄은 감싼 메서드의 것이다(`apply` · `withAnon` 은 돌았다 — 익명 클래스는 별도 클래스가 아니다, 실측) ·
# 트레이트 메서드는 트레이트 이름으로(`Masked::masked` — 돌았다) · 파일 수준 함수는 짧은 이름으로(`adminHelper`) · 빈 몸통
# 승격 생성자도 줄 하나(닫는 `}`) · 줄 번호는 선언 줄(`start`)이다.
run report php "$T" --out "$D"
assert_eq 0 "$RC" "[php] 건강한 리포트는 exit 0 — 출력: $OUT"
assert_contains "$OUT" "(driver xdebug 3.5.3 · php-code-coverage 12.5.7)" "[php] 드라이버를 찍는다 — CI 는 pcov, 로컬은 Xdebug"
assert_line "$OUT" "  php/src/Admin/AdminClient.php 3/5 60.0%" "[php] AdminClient.php — 클래스 · 트레이트 · 파일 함수"
assert_line "$OUT" "  php/src/AuthClient.php 13/17 76.5%" "[php] AuthClient.php — 클로저 · 익명 클래스는 감싼 메서드의 줄"
assert_line "$OUT" "  total 16/22 72.7%" "[php] 합계는 경계 파일만(Config.php 제외)"
assert_line "$OUT" "  NEVER php/src/Admin/AdminClient.php:31 AdminClient::groups · 1 line · owner open-admin" "[php] 메서드 — 줄은 선언 줄"
assert_line "$OUT" "  NEVER php/src/Admin/AdminClient.php:38 adminHelper · 1 line · owner open-admin" "[php] 파일 수준 함수는 짧은 이름"
assert_line "$OUT" "  NEVER php/src/AuthClient.php:62 AuthClient::logoutUrl · 2 lines · owner open-admin" "[php] 두 줄 메서드"
assert_line "$OUT" "  NEVER php/src/AuthClient.php:70 AuthClient::__debugInfo · 1 line · owner open-masking" "[php] __debugInfo"
for _x in Config.php exchange apply withAnon hello Masked::masked "::__construct" "::users" "::realm" "::helper" module-level; do
  assert_not_contains "$OUT" "$_x" "[php] 실행된 · 일부만 돈 · 익명 클래스 · 경계 밖은 목록에 없다: $_x"
done
assert_line "$OUT" "integration-coverage [php]: OK — 16/22 lines (72.7%) · 4 never-executed functions, all owned by open registry items" "[php] 요약"
# Linux 의 PHPUnit 은 `<project source>` 를 `/` 로 쓴다 — 윈도에서 만든 `\` 와 같은 리포트여야 한다.
fresh
sed -i 's#\\php\\src"#/php/src"#' "$D/php/index.xml"
assert_contains "$(cat "$D/php/index.xml")" '/php/src"' "(변이가 착지했는지 먼저 본다)"
php_mark 0
run report php "$T" --out "$D"
assert_eq 0 "$RC" "[php] / 경로도 같은 트리다 — 출력: $OUT"
assert_line "$OUT" "  total 16/22 72.7%" "[php] / 경로에서도 같은 합계"

# Linux 의 llvm-cov 는 SF 를 `/` 로 쓴다 — 윈도에서 만든 `\` 와 같은 리포트여야 한다.
fresh
sed -i '/^SF:/s#\\#/#g' "$D/rust.lcov"
assert_contains "$(cat "$D/rust.lcov")" "/rust/src/auth.rs" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 0 "$RC" "[rust] / 경로도 같은 파일이다 — 출력: $OUT"
assert_line "$OUT" "  total 116/159 73.0%" "[rust] / 경로에서도 같은 합계"
# static 의 클로저가 안 돌았다(데이터의 그 줄들을 0 으로) — 그 static 이 미실행으로 든다. 클로저 몸통의 `;` 는 static 을 끝내지
# 않는다(괄호 깊이 0 의 `;` 만 끝이다 — 아니면 몸통 줄이 모듈 수준으로 샌다). 코드 없는 상수는 그래도 안 든다.
fresh
sed -i '/^SF:.*client\.rs$/,/^end_of_record$/s/^DA:\(30\|31\|32\|33\),1$/DA:\1,0/' "$D/rust.lcov"
assert_contains "$(cat "$D/rust.lcov")" "DA:33,0" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 1 "$RC" "[rust] 안 돈 static 클로저는 소유자 없는 미실행(exit 1) — 출력: $OUT"
assert_line "$OUT" "  NEVER rust/src/client.rs:30 static GREETING · 4 lines · owner NONE" "[rust] static 이름으로 든다 — 네 줄 전부"
assert_not_contains "$OUT" "const BANNER" "[rust] 코드 없는 상수는 목록에 없다"
# 비ASCII 이름 — 이름 전체가 읽힌다(`[A-Za-z_]\w*` 는 `gr` 에서 끊는다).
fresh
sed -i '/^SF:.*client\.rs$/,/^end_of_record$/s/^DA:\(51\|52\|53\),1$/DA:\1,0/' "$D/rust.lcov"
assert_contains "$(cat "$D/rust.lcov")" "DA:53,0" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_line "$OUT" "  NEVER rust/src/client.rs:51 größe · 3 lines · owner NONE" "[rust] 비ASCII 함수 이름"
# 닫는 줄 뒤의 주석은 닫는 줄을 가리지 않는다(지운 뒤 줄 끝 공백을 걷는다).
fresh
sed -i '48s#^    }$#    } // end of describe#' "$T/rust/src/auth.rs"
assert_contains "$(sed -n '48p' "$T/rust/src/auth.rs")" "} // end of describe" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 0 "$RC" "[rust] 닫는 줄 뒤 주석 — 출력: $OUT"
assert_line "$OUT" "  NEVER rust/src/auth.rs:42 AuthClient::describe · 7 lines · owner open-masking" "[rust] 주석 달린 닫는 줄에서도 같은 범위"

# Linux 의 coverage.py 는 키를 `/` 로 쓴다 — Windows 에서 만든 `\` 키와 같은 리포트여야 한다.
fresh
sed -i -f "$FIX/slashes.sed" "$D/python.json"
assert_contains "$(cat "$D/python.json")" '"src/keycloak_sdk/auth.py"' "(변이가 착지했는지 먼저 본다)"
run report python "$T" --out "$D"
assert_eq 0 "$RC" "[python] / 키도 같은 파일이다 — 출력: $OUT"
assert_line "$OUT" "  total lines 21/28 75.0% · bodies 8/13 61.5%" "[python] / 키에서도 같은 합계"

# 다른 언어의 파생 실패가 이 언어의 리포트를 막지 않는다(픽스처에 없는 언어의 파생은 늘 FAIL 이다).
fresh
sed -i 's#grep -vE .*#true#' "$T/.github/workflows/go-ci.yml"
run report python "$T" --out "$D"
assert_eq 0 "$RC" "[python] go 의 파생 실패는 python 리포트와 무관하다 — 출력: $OUT"

# ruby — 이름 · 범위 · 실행 가능 줄 · **호출 횟수**는 VM 이 낸다(`Coverage` 의 methods — 미실행 = 횟수 0). 덤프는 run 이 쓴
# 부트 파일의 것이다(픽스처도 도구의 run 으로 만들었다 — 머리 주석). 적재 때 도는 클래스 · def 줄이 lines 를 부풀리므로
# bodies 를 함께 낸다 — 한 줄 메서드(`logout_url`)는 정의 줄이 곧 몸통이라 호출 횟수로 센다(적재 때 1, 호출 0).
fresh
run report ruby "$T" --out "$D"
assert_eq 0 "$RC" "[ruby] 건강한 리포트는 exit 0 — 출력: $OUT"
assert_line "$OUT" "[ruby] integration-only coverage — report mode, no floor" "[ruby] 머리줄"
assert_line "$OUT" "  boundary: 3 files derived from ruby/spec/spec_helper.rb:8 (SimpleCov skip) — equal to the pin in scripts/integration-coverage.json" "[ruby] 파생 출처"
assert_contains "$OUT" "/ruby.json (ruby 3.4.10 · Coverage lines · methods)" "[ruby] 덤프와 그것을 낸 ruby 를 찍는다"
assert_line "$OUT" "  ruby/lib/kc/admin/client.rb lines 9/9 100.0% · bodies 2/3 66.7%" "[ruby] admin/client.rb — 빈 몸통 · 한 줄 메서드"
assert_line "$OUT" "  ruby/lib/kc/auth_client.rb lines 13/17 76.5% · bodies 4/9 44.4%" "[ruby] auth_client.rb — 람다 줄은 적재 때 돈다"
assert_line "$OUT" "  ruby/lib/kc/version.rb lines 2/2 100.0% · bodies 0/0 n/a" "[ruby] 메서드 없는 파일도 데이터에 있다"
assert_line "$OUT" "  total lines 24/28 85.7% · bodies 6/12 50.0%" "[ruby] 합계"
assert_line "$OUT" "  never executed by the integration run — 5 functions (Ruby counted no call to it):" "[ruby] 미실행 머리줄"
assert_line "$OUT" "  NEVER ruby/lib/kc/admin/client.rb:15 Client#close · 1 line · owner open-admin" "[ruby] 한 줄 메서드 — 적재 때 돈 줄을 호출로 세지 않는다"
assert_line "$OUT" "  NEVER ruby/lib/kc/admin/client.rb:17 Client#flush · empty body · owner open-admin" "[ruby] 빈 몸통 — 실행 가능 줄 없이도 호출 횟수로 잡는다"
assert_line "$OUT" "  NEVER ruby/lib/kc/auth_client.rb:20 AuthClient#logout_url · 1 line · owner open-admin" "[ruby] endless 메서드"
assert_line "$OUT" "  NEVER ruby/lib/kc/auth_client.rb:26 AuthClient.build · 1 line · owner open-masking" "[ruby] 특이 메서드는 「.」"
assert_line "$OUT" "  NEVER ruby/lib/kc/auth_client.rb:30 AuthClient#introspect · 2 lines · owner open-admin" "[ruby] 인스턴스 메서드는 「#」"
assert_not_contains "$OUT" "AuthClient.parse ·" "[ruby] 부른 특이 메서드는 목록에 없다"
assert_line "$OUT" "integration-coverage [ruby]: OK — lines 24/28 (85.7%) · bodies 6/12 (50.0%) · 5 never-executed functions, all owned by open registry items" "[ruby] 통과 요약"

# dotnet — 줄 · 횟수는 coverlet 컬렉터의 고유 JSON 이, 이름은 컴파일러가 만든 이름이 낸다. async · 이터레이터 메서드는 중첩 상태
# 기계(제네릭 메서드면 항수가 붙는다)의 MoveNext 에만 줄이 있고, 람다 · 로컬 함수 · async 람다는 감싼 메서드에 접힌다. 오버로드는
# 시그니처로 가른다. 한 줄의 횟수는 그 줄의 모든 코드의 합이다(같은 줄의 람다 · auto-property setter 는 따로 안 실린다). 클로저
# 클래스의 람다(`Prefixed` 의 여러 줄 람다)는 coverlet 이 감싼 메서드 아래 싣는다. 생성자는 `#ctor` · 정적 생성자는 `#cctor`.
fresh
run report dotnet "$T" --out "$D"
assert_eq 0 "$RC" "[dotnet] 건강한 리포트는 exit 0 — 출력: $OUT"
assert_line "$OUT" "[dotnet] integration-only coverage — report mode, no floor" "[dotnet] 머리줄"
assert_line "$OUT" "  boundary: 2 files derived from dotnet/coverlet.runsettings:9 (coverlet <Exclude>) — equal to the pin in scripts/integration-coverage.json" "[dotnet] 파생 출처"
assert_contains "$OUT" "/dotnet.json (.NET 8.0.23 · coverlet json · 1 test)" "[dotnet] 데이터 · 런타임 · 테스트 수를 찍는다"
assert_line "$OUT" "  dotnet/src/Kc/Admin/Client.cs 5/10 50.0%" "[dotnet] Admin/Client.cs — 중첩 타입 · 빈 몸통 · 정적 초기화"
assert_line "$OUT" "  dotnet/src/Kc/AuthClient.cs 40/74 54.1%" "[dotnet] AuthClient.cs — 상태 기계 · 람다 · 로컬 함수의 줄이 든다"
assert_line "$OUT" "  total 45/84 53.6%" "[dotnet] 합계는 경계 파일만(Config.cs 제외)"
assert_line "$OUT" "  never executed by the integration run — 13 functions (none of its lines ran):" "[dotnet] 미실행 머리줄"
assert_line "$OUT" "  NEVER dotnet/src/Kc/Admin/Client.cs:11 Client.Close · 1 line · owner open-admin" "[dotnet] 빈 몸통도 닫는 중괄호 줄이 있다"
assert_line "$OUT" "  NEVER dotnet/src/Kc/Admin/Client.cs:13 Client.Dispose · 1 line · owner open-admin" "[dotnet] 식 본문 메서드"
assert_line "$OUT" "  NEVER dotnet/src/Kc/Admin/Client.cs:17 Client.Defaults.#cctor · 1 line · owner open-admin" "[dotnet] 정적 생성자는 「#cctor」 — 필드 초기화 줄"
assert_line "$OUT" "  NEVER dotnet/src/Kc/Admin/Client.cs:19 Client.Defaults.First · 1 line · owner open-admin" "[dotnet] 정적 중첩 타입의 메서드"
assert_line "$OUT" "  NEVER dotnet/src/Kc/Admin/Client.cs:30 Client.UsersResource.DeleteAsync · 1 line · owner open-admin" "[dotnet] 중첩 사용자 타입은 「.」으로 잇는다 — async 아닌 Task 반환"
assert_line "$OUT" "  NEVER dotnet/src/Kc/AuthClient.cs:14 AuthClient.#ctor(System.String,System.String) · 2 lines · owner open-masking" "[dotnet] 생성자 오버로드는 「#ctor」 + 시그니처"
assert_line "$OUT" "  NEVER dotnet/src/Kc/AuthClient.cs:60 AuthClient.Describe(System.Int32) · 1 line · owner open-admin" "[dotnet] 오버로드는 시그니처로 가른다"
assert_line "$OUT" "  NEVER dotnet/src/Kc/AuthClient.cs:86 AuthClient.LogoutAsync · 2 lines · owner open-admin" "[dotnet] async 메서드 — 상태 기계의 줄"
assert_line "$OUT" "  NEVER dotnet/src/Kc/AuthClient.cs:89 AuthClient.Build · 1 line · owner open-masking" "[dotnet] 정적 메서드"
assert_line "$OUT" "  NEVER dotnet/src/Kc/AuthClient.cs:93 AuthClient.Unused · 2 lines · owner open-admin" "[dotnet] 로컬 함수의 줄은 감싼 메서드의 것이다"
assert_line "$OUT" "  NEVER dotnet/src/Kc/AuthClient.cs:100 AuthClient.Later · 5 lines · owner open-admin" "[dotnet] 동기 메서드가 돌려주는 async 람다 — coverlet 이 그 줄을 감싼 메서드 아래 싣는다(상태 기계는 빈 줄)"
assert_line "$OUT" "  NEVER dotnet/src/Kc/AuthClient.cs:109 AuthClient.Lower · 6 lines · owner open-admin" "[dotnet] 동기 메서드의 람다 줄은 coverlet 이 그 메서드 아래 싣는다"
assert_line "$OUT" "  NEVER dotnet/src/Kc/AuthClient.cs:119 AuthClient.NamesAsync · 8 lines · owner open-admin" "[dotnet] async 메서드의 람다는 람다 캐시에 따로 실린다 — 감싼 메서드에 접는다"
assert_not_contains "$OUT" "Describe() ·" "[dotnet] 부른 오버로드는 목록에 없다"
assert_not_contains "$OUT" "#ctor(Kc.Config)" "[dotnet] 부른 생성자 오버로드는 목록에 없다"
assert_not_contains "$OUT" "EchoAsync" "[dotnet] 부른 제네릭 async 메서드는 목록에 없다"
assert_not_contains "$OUT" "Prefixed" "[dotnet] 클로저 람다의 줄은 감싼 메서드의 것이다 — 부른 메서드는 목록에 없다"
assert_not_contains "$OUT" "MoveNext" "[dotnet] 상태 기계의 이름을 내지 않는다"
assert_not_contains "$OUT" "RetryAsync" "[dotnet] 돈 메서드 안의 안 돈 async 람다(상태 기계의 줄 전부 0)는 두 겹을 벗겨 그 메서드에 접는다 — 목록에 없다"
assert_line "$OUT" "integration-coverage [dotnet]: OK — 45/84 lines (53.6%) · 13 never-executed functions, all owned by open registry items" "[dotnet] 통과 요약"
# java — 줄 · 횟수는 JaCoCo(IT 만 돈 실행의 exec → CLI 의 XML)가, 이름과 메서드마다의 줄은 클래스 파일(javap 의 LineNumberTable ·
# EnclosingMethod)이 낸다. 람다는 감싼 메서드에(오버로드면 줄 범위로), 익명 클래스는 EnclosingMethod 로 접는다. 정적 초기화(<clinit>)만
# 가진 줄은 bodies 에서 뺀다(정적 람다의 줄은 람다 몸통이기도 하다 — 몸통으로 센다).
fresh
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[java] 건강한 리포트는 exit 0 — 출력: $OUT"
assert_line "$OUT" "[java] integration-only coverage — report mode, no floor" "[java] 머리줄"
assert_line "$OUT" "  boundary: 2 files derived from java/pom.xml:52 (jacoco <excludes>) — equal to the pin in scripts/integration-coverage.json" "[java] 파생 출처"
assert_contains "$OUT" "/java.xml (JaCoCo 0.8.16 · 1 session · 1 integration test)" "[java] 데이터 · JaCoCo 판 · 세션 · 테스트 수를 찍는다"
assert_line "$OUT" "  java/kc-auth/src/main/java/kc/auth/AuthClient.java lines 22/27 81.5% · bodies 18/23 78.3%" "[java] AuthClient.java — 정적 초기화만 가진 줄(REALM · enum Mode 의 선언 · 상수) 넷이 bodies 에서 빠진다"
assert_line "$OUT" "  java/kc-examples/src/main/java/kc/examples/QuickStart.java lines 0/4 0.0% · bodies 0/4 0.0%" "[java] jacoco.skip 모듈의 파일도 든다(파생의 forced)"
assert_line "$OUT" "  total lines 22/31 71.0% · bodies 18/27 66.7%" "[java] 합계는 경계 파일만(Config.java 제외)"
assert_line "$OUT" "  never executed by the integration run — 5 functions (none of its lines ran):" "[java] 미실행 머리줄"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:36 AuthClient.token(String, int) · 1 line · owner open-admin" "[java] 오버로드는 서술자로 가른다 — 그 람다는 줄 범위로 그 오버로드에 붙는다"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:53 AuthClient.unused · 1 line · owner open-admin" "[java] 안 부른 메서드"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:62 AuthClient.Token.<init>(char) · 4 lines · owner open-admin" "[java] 두 생성자가 함께 가진 필드 람다가 돌아도 안 부른 생성자는 미실행이다(독립 레그 1차)"
assert_not_contains "$OUT" "Mode" "[java] enum 의 생성 메서드(values · valueOf · \$values)는 JaCoCo 가 거른다 — 정적 초기화뿐이라 목록에 없다"
assert_line "$OUT" "  NEVER java/kc-examples/src/main/java/kc/examples/QuickStart.java:8 QuickStart.main · 2 lines · owner open-masking" "[java] 예제의 main"
assert_line "$OUT" "  NEVER java/kc-examples/src/main/java/kc/examples/QuickStart.java:12 QuickStart.env · 2 lines · owner open-masking" "[java] 예제의 패키지 전용 메서드"
assert_not_contains "$OUT" "token(String) ·" "[java] 부른 오버로드는 목록에 없다"
assert_not_contains "$OUT" "lambda\$" "[java] 람다의 이름을 내지 않는다"
assert_not_contains "$OUT" "AuthClient\$1" "[java] 익명 클래스는 감싼 메서드(sorted)에 접힌다 — 이름을 내지 않는다"
assert_not_contains "$OUT" "<clinit>" "[java] 정적 초기화는 미실행 목록에 들지 않는다"
assert_not_contains "$OUT" "Config" "[java] 경계 밖 파일은 리포트에 없다"
assert_line "$OUT" "integration-coverage [java]: OK — lines 22/31 (71.0%) · bodies 18/27 (66.7%) · 5 never-executed functions, all owned by open registry items" "[java] 통과 요약"
# kotlin — java 와 같은 리더(JaCoCo XML + javap)이되, 합성 메서드는 이름이 아니라 클래스 파일의 코드로 접는다(ktFold): 람다는 그것을
# 만드는 invokedynamic 이 든 메서드 · 기본 인자 다리와 기본 인자 생성자는 그것이 부르는 대상 · 로컬 함수와 `$suspendImpl` 은 그것을
# 부르는 메서드 · 익명 · 로컬 클래스는 EnclosingMethod(없으면 그 클래스를 `new` 하는 메서드). 픽스처의 꼴(kotlinc 2.4.21 이 낸 것):
# `internal` 의 모듈 접미(`mask$kc_kotlin` · 그 다리 `mask$kc_kotlin$default`) · 다리 `label$default` · 오버로드의 람다
# (`token$lambda$0/1`) · 속성 초기화의 람다(Companion `UPPER$lambda$0` → 정적 초기화 · 인스턴스 `greet$lambda$0` → 생성자) · 초기화
# 블록의 람다(`_init_$lambda$0`) · 람다 안의 람다(`nested$lambda$0$0`) · 로컬 함수(`withLocal$inner`)와 그 람다 · 로컬 클래스
# (`AuthClient$withLocalClass$Local` — 이름에 숫자가 없다) · `@JvmName("joinInts")` 쪽 람다(`join$lambda$1` — 만드는 것은 joinInts) ·
# 기본 인자 생성자와 그 기본값 람다 · 컴패니언 init 람다(둘 다 `_init_$lambda$N` — 만드는 것이 생성자 · 정적 초기화로 갈린다) ·
# object 의 `@JvmStatic` 다리(받는 쪽이 없다 — `pick(AuthClientDefaults, int)` 의 것) · `load$suspendImpl` · 인터페이스 다리
# (`AuthClientApi$DefaultImpls.ping$default` 는 인터페이스의 같은 이름 다리를 부른다) · 값 클래스 맹글(`byId-tzrl3XM` — 이름에 `-`) ·
# 안 실린 object 의 정적 초기화와 그 람다(`AuthClientIdle`) · suspend 의 이어받기 클래스(줄이 없다) · 파일 파사드(`QuickStartKt` ·
# `AuthClientKt`). suspend 함수의 데이터 첫 줄(29)은 줄표의 가장 앞 줄(28)이 아니다(JaCoCo 가 선언 줄의 상태 기계 분기를 거른다) —
# 그 메서드의 줄이기만 하면 된다.
fresh
run report kotlin "$T" --out "$D"
assert_eq 0 "$RC" "[kotlin] 건강한 리포트는 exit 0 — 출력: $OUT"
assert_line "$OUT" "[kotlin] integration-only coverage — report mode, no floor" "[kotlin] 머리줄"
assert_line "$OUT" "  boundary: 2 files derived from kotlin/build.gradle.kts:46 (kover excludes.classes) — equal to the pin in scripts/integration-coverage.json" "[kotlin] 파생 출처"
assert_contains "$OUT" "/kotlin.xml (JaCoCo 0.8.16 · 1 session · 1 integration test)" "[kotlin] 데이터 · JaCoCo 판 · 세션 · 테스트 수를 찍는다"
assert_line "$OUT" "  kotlin/src/main/kotlin/kc/auth/AuthClient.kt lines 37/50 74.0% · bodies 34/48 70.8%" "[kotlin] AuthClient.kt — 정적 초기화만 돈 줄(REALM 등)은 몸통으로 안 덮였다"
assert_line "$OUT" "  kotlin/src/main/kotlin/kc/examples/QuickStart.kt lines 0/3 0.0% · bodies 0/3 0.0%" "[kotlin] 최상위 함수의 파일"
assert_line "$OUT" "  total lines 37/53 69.8% · bodies 34/51 66.7%" "[kotlin] 합계는 경계 파일만(Config.kt 제외)"
assert_line "$OUT" "  never executed by the integration run — 9 functions (none of its lines ran):" "[kotlin] 미실행 머리줄"
assert_line "$OUT" "  NEVER kotlin/src/main/kotlin/kc/auth/AuthClient.kt:9 AuthClient.Companion.getREALM · 1 line · owner open-admin" "[kotlin] 안 읽은 Companion 속성의 getter — 그 줄을 정적 초기화가 돌아도 미실행이다"
assert_line "$OUT" "  NEVER kotlin/src/main/kotlin/kc/auth/AuthClient.kt:25 AuthClient.token(String, int) · 1 line · owner open-admin" "[kotlin] 오버로드는 서술자로 가른다 — 그 람다는 만든 오버로드에 붙는다"
assert_line "$OUT" "  NEVER kotlin/src/main/kotlin/kc/auth/AuthClient.kt:51 AuthClient.unused · 1 line · owner open-admin" "[kotlin] 안 부른 메서드"
assert_line "$OUT" "  NEVER kotlin/src/main/kotlin/kc/auth/AuthClient.kt:78 AuthClient.withLocalClass · 4 lines · owner open-admin" "[kotlin] 로컬 클래스(이름에 숫자 없음)의 줄은 감싼 메서드의 것이다"
assert_line "$OUT" "  NEVER kotlin/src/main/kotlin/kc/auth/AuthClient.kt:87 AuthClient.join · 1 line · owner open-admin" "[kotlin] joinInts 만 돈 실행 — join\$lambda\$1 은 joinInts 의 것이라 join 은 미실행이다(이름으로 접으면 숨었다)"
assert_line "$OUT" "  NEVER kotlin/src/main/kotlin/kc/auth/AuthClient.kt:95 AuthClientStatus.<init> · 4 lines · owner open-admin" "[kotlin] 정적 초기화가 만든 컴패니언 init 람다는 안 돈 생성자를 실행된 것으로 만들지 않는다 — 기본 인자 생성자 · 기본값 람다는 그 생성자의 것"
assert_line "$OUT" "  NEVER kotlin/src/main/kotlin/kc/auth/AuthClient.kt:117 AuthClientDefaults.pick(int) · 1 line · owner open-admin" "[kotlin] @JvmStatic 다리는 그것이 부르는 pick(AuthClientDefaults, int) 의 것 — 안 부른 pick(int) 는 미실행이다"
assert_line "$OUT" "  NEVER kotlin/src/main/kotlin/kc/examples/QuickStart.kt:7 QuickStartKt.main · 2 lines · owner open-masking" "[kotlin] 최상위 함수는 파일 파사드의 이름이다"
assert_line "$OUT" "  NEVER kotlin/src/main/kotlin/kc/examples/QuickStart.kt:13 QuickStartKt.env · 1 line · owner open-masking" "[kotlin] internal 최상위 함수 — 모듈 접미를 벗긴 이름"
assert_not_contains "$OUT" "_init_" "[kotlin] 초기화 블록의 람다는 만든 생성자 · 정적 초기화에 접힌다"
assert_not_contains "$OUT" "AuthClient.greet" "[kotlin] 인스턴스 속성의 람다는 그것을 만든 생성자에 접힌다(생성자가 돌았다)"
assert_not_contains "$OUT" "AuthClient.mask" "[kotlin] 다리(mask\$kc_kotlin\$default)로 부른 internal 함수는 목록에 없다"
assert_not_contains "$OUT" "AuthClient.nested" "[kotlin] 람다 안의 람다(nested\$lambda\$0\$0)는 바깥 람다를 거쳐 nested 에 접힌다"
assert_not_contains "$OUT" "AuthClient.withLocal ·" "[kotlin] 로컬 함수와 그 람다는 부른 · 만든 메서드에 접힌다"
assert_not_contains "$OUT" "AuthClientLoader" "[kotlin] load\$suspendImpl 은 open suspend fun load 다(돌았다)"
assert_not_contains "$OUT" "AuthClientApi" "[kotlin] DefaultImpls 다리(안 돌았다)는 인터페이스의 ping 에 접힌다(돌았다)"
assert_not_contains "$OUT" "AuthClientIdle" "[kotlin] 안 실린 object 의 정적 초기화 · 그 람다는 미실행 목록에 들지 않는다"
assert_not_contains "$OUT" "byId" "[kotlin] 값 클래스 맹글 이름(byId-tzrl3XM)의 함수와 그 람다(byId_tzrl3XM\$lambda\$0)는 돌았다"
assert_not_contains "$OUT" "\$kc_kotlin" "[kotlin] internal 의 모듈 접미를 내지 않는다"
assert_not_contains "$OUT" "\$default" "[kotlin] 기본 인자 다리는 그 함수에 접힌다"
assert_not_contains "$OUT" "lambda\$" "[kotlin] 람다의 이름을 내지 않는다"
assert_not_contains "$OUT" "AuthClient\$" "[kotlin] 익명 객체 · 로컬 클래스 · 이어받기 클래스의 이름을 내지 않는다"
assert_not_contains "$OUT" "token(String) ·" "[kotlin] 부른 오버로드는 목록에 없다"
assert_not_contains "$OUT" "AuthClient.fetch" "[kotlin] 부른 suspend 함수는 목록에 없다"
assert_not_contains "$OUT" "<clinit>" "[kotlin] 정적 초기화는 미실행 목록에 들지 않는다"
assert_not_contains "$OUT" "Config" "[kotlin] 경계 밖 파일은 리포트에 없다"
assert_line "$OUT" "integration-coverage [kotlin]: OK — lines 37/53 (69.8%) · bodies 34/51 (66.7%) · 9 never-executed functions, all owned by open registry items" "[kotlin] 통과 요약"

# ── (2) 음성: 파생 ↔ 핀───────────────────────────────────────────────────────────────────────
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
# node — 경계 파일 하나가 데이터에 없다(include 를 이름으로 좁히면 이렇게 된다 — 그래서 run 은 디렉터리로 준다).
fresh
sed -i 's#/node/src/index\.ts"#/node/src/index-gone.ts"#g' "$D/node/coverage-final.json"
assert_contains "$(cat "$D/node/coverage-final.json")" 'index-gone.ts' "(변이가 착지했는지 먼저 본다)"
run report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 경계 파일이 데이터에 없으면 exit 2"
assert_contains "$OUT" "FAIL [node] node/src/index.ts is not in the coverage data" "[node] 빠진 파일을 댄다"
assert_not_contains "$OUT" "  total " "[node] 수치를 내지 않는다"
# 핀에서 파일이 빠졌다.
fresh
sed -i '/^      "node\/src\/index.ts"$/d; s#^      "node/src/auth.ts",$#      "node/src/auth.ts"#' "$T/scripts/integration-coverage.json"
assert_not_contains "$(cat "$T/scripts/integration-coverage.json")" '"node/src/index.ts"' "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 2 "$RC" "[check] node 핀에서 파일이 빠지면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] the derived boundary differs from the pin in scripts/integration-coverage.json — derived, not pinned: node/src/index.ts" "[check] node 핀 밖 파일을 댄다"
# 같은 클래스에 같은 이름이 둘 — 미실행 목록이 둘을 못 가른다.
fresh
sed -i 's#^  async longSignature($#  async close(#' "$T/node/src/auth.ts"
assert_contains "$(cat "$T/node/src/auth.ts")" "  async close(" "(변이가 착지했는지 먼저 본다)"
run report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 같은 이름의 함수가 둘이면 exit 2"
assert_contains "$OUT" "FAIL [node] node/src/auth.ts: two functions are both named Client.close" "[node] 겹친 이름을 댄다"
# 정규식 속 백틱이 템플릿을 열어 파일 끝까지 지운다 — 조용히 「미실행 0」이 되지 않고 FAIL 이다(#953 독립 레그 실측).
fresh
sed -i '2a const TICK = /`/' "$T/node/src/auth.ts"
assert_contains "$(sed -n '3p' "$T/node/src/auth.ts")" 'const TICK = /`/' "(변이가 착지했는지 먼저 본다)"
run report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 끝나지 않는 템플릿은 exit 2 — 출력: $OUT"
assert_contains "$OUT" 'FAIL [node] node/src/auth.ts: a template literal or ${…} runs to the end of the file' "[node] 이름 범위를 못 읽는다고 댄다"
# 소유자 없는 미실행 함수(exit 1 — 경고).
fresh
sed -i '/"node\/src\/auth.ts:Client.cb"/d' "$T/scripts/integration-coverage.json"
run report node "$T" --out "$D"
assert_eq 1 "$RC" "[node] 소유자 없는 미실행 함수는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [node] unowned never-executed function node/src/auth.ts:Client.cb" "[node] 소유자 없음"
# 데이터가 없다.
fresh
rm "$D/node/coverage-final.json"
run report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 데이터가 없으면 exit 2"
assert_contains "$OUT" "FAIL [node] no coverage data at" "[node] 데이터 없음"
# rust — 경계 파일 하나가 데이터에 없다(그 모듈을 아무도 참조하지 않으면 오브젝트가 링크되지 않아 이렇게 된다).
fresh
sed -i '/^SF:.*client\.rs$/,/^end_of_record$/d' "$D/rust.lcov"
assert_not_contains "$(cat "$D/rust.lcov")" "client.rs" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 경계 파일이 데이터에 없으면 exit 2"
assert_contains "$OUT" "FAIL [rust] rust/src/client.rs is not in the coverage data" "[rust] 빠진 파일을 댄다"
assert_not_contains "$OUT" "  total " "[rust] 수치를 내지 않는다"
# 한 파일의 기록이 둘(두 보고서를 이어 붙인 꼴) — 어느 쪽이 맞는지 모른다.
fresh
sed -n '/^SF:.*client\.rs$/,/^end_of_record$/p' "$D/rust.lcov" > "$TMP/client.rec"
{ printf '\n'; cat "$TMP/client.rec"; } >> "$D/rust.lcov"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 같은 파일의 기록이 둘이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] rust/src/client.rs has two records in" "[rust] 모순 데이터를 댄다"
# ⚠️ llvm-cov 의 lcov 는 마지막 줄바꿈 없이 끝난다(픽스처도 그대로다) — `cat` 으로 이으면 `end_of_recordSF:…` 한 줄이 되고,
# 그 줄을 건너뛰면 뒤 기록의 줄이 앞 파일의 것으로 섞인다. 못 읽는 줄이다.
fresh
sed -n '/^SF:.*client\.rs$/,/^end_of_record$/p' "$D/rust.lcov" > "$TMP/client.rec"
cat "$TMP/client.rec" >> "$D/rust.lcov"
assert_contains "$(cat "$D/rust.lcov")" "end_of_recordSF:" "(변이가 착지했는지 먼저 본다 — 줄바꿈 없는 끝)"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 줄바꿈 없이 이어 붙인 보고서는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] cannot read the lcov line: end_of_recordSF:" "[rust] 붙은 줄을 댄다"
fresh
sed -i '/^SF:.*client\.rs$/,/^end_of_record$/s/^DA:25,0$/DA:25,0\nDA:25,1/' "$D/rust.lcov"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 한 기록에서 같은 줄이 두 번이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] rust/src/client.rs: line 25 is counted twice in one record" "[rust] 겹친 줄을 댄다"
# 데이터가 다른 체크아웃의 것이다 — 파일보다 긴 줄을 센다.
fresh
sed -i '/^SF:.*client\.rs$/,/^end_of_record$/s/^DA:27,0$/DA:400,0/' "$D/rust.lcov"
assert_contains "$(cat "$D/rust.lcov")" "DA:400,0" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 파일 끝 뒤의 줄은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] rust/src/client.rs: the data counts line 400, past the end of the file (126 lines)" "[rust] 다른 체크아웃"
fresh
sed -i '/^SF:.*client\.rs$/a DA:oops' "$D/rust.lcov"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 못 읽는 lcov 줄은 exit 2"
assert_contains "$OUT" "FAIL [rust] cannot read the lcov line: DA:oops" "[rust] 못 읽는 줄을 댄다"
fresh
printf 'TN:\n' > "$D/rust.lcov"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] SF 가 없는 파일은 exit 2"
assert_contains "$OUT" "has no SF records — not an lcov report" "[rust] lcov 가 아니다"
fresh
rm "$D/rust.lcov"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 데이터가 없으면 exit 2"
assert_contains "$OUT" "FAIL [rust] no coverage data at" "[rust] 데이터 없음"
# 파서가 항목을 놓쳤다(rustfmt 가 아닌 들여쓰기) — 그 함수의 레코드가 어느 범위에도 없다. 조용히 모듈 수준에 섞이면
# 미실행 목록에서 빠진다(node 독립 레그가 실측한 부류 — 생성자가 「몸통 없는 선언」으로 빠졌다).
fresh
sed -i 's#^    pub fn noop(&self) {}$#     pub fn noop(\&self) {}#' "$T/rust/src/auth.rs"
assert_contains "$(sed -n '61p' "$T/rust/src/auth.rs")" "     pub fn noop" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 범위 밖 함수 레코드는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] rust/src/auth.rs:61: the data has a function (" "[rust] 놓친 자리를 댄다"
assert_contains "$OUT" "starts outside every name range — the parser missed an item" "[rust] 파서가 놓쳤다고 댄다"
# 범위가 닫는 줄을 지나쳐 다음 함수를 삼켰다 — 레코드는 범위 안이지만 그 범위와 같은 들여쓰기의 fn 머리에 있다.
fresh
sed -i '48s#^    }$#    }}#' "$T/rust/src/auth.rs"
assert_contains "$(sed -n '48p' "$T/rust/src/auth.rs")" "    }}" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 다음 함수를 삼킨 범위는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] rust/src/auth.rs:50: the data has a function (" "[rust] 삼켜진 함수의 자리"
assert_contains "$OUT" "that starts at a function head inside AuthClient::describe's range (42–55) — the range ran past its end" "[rust] 삼킨 범위를 댄다"
# 단위 테스트가 같은 빌드에서 돌았다(`--lib --test drive`) — 통합 전용이 아니다. 실제 도구 출력이다. `#[cfg(test)]` 와 같은
# 뜻의 다른 철자(`all(test, debug_assertions)`)도 test 없이는 거짓이라 같은 판정이다(독립 레그 실측: 철자만 맞추던 판정은
# `all(test)` 의 단위 테스트 줄을 통합 커버리지로 셌다 — exit 1, 103/140).
fresh
rust_data "$FIX/data/rust-unit.lcov"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] cfg(test) 함수의 레코드가 있으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] rust/src/auth.rs:161: the data has a function inside an item compiled only with cfg(test) (" "[rust] cfg(test) 자리를 댄다"
assert_contains "$OUT" "FAIL [rust] rust/src/client.rs:66: the data has a function inside an item compiled only with cfg(test) (" "[rust] all(test, …) 자리도 댄다"
assert_contains "$OUT" "unit tests ran in this build, so the report would not be integration-only" "[rust] 통합 전용이 아니라고 댄다"
# cfg(test) 를 건너뛰는 것이 하중을 진다 — 지우면 그 모듈의 테스트 함수들이 레코드 없는 미실행으로 든다(cfg 쌍둥이
# `platform` 둘은 cfg 가 이름에 붙어 겹치지 않는다).
fresh
sed -i 's/^#\[cfg(test)\]$//' "$T/rust/src/auth.rs"
assert_not_contains "$(cat "$T/rust/src/auth.rs")" "#[cfg(test)]" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 1 "$RC" "[rust] cfg(test) 모듈을 읽으면 그 함수들이 소유자 없는 미실행이다(exit 1) — 출력: $OUT"
assert_line "$OUT" "  NEVER rust/src/auth.rs:156 tests::platform #[cfg(unix)] · no record in the data · owner NONE" "[rust] 쌍둥이 하나"
assert_line "$OUT" "  NEVER rust/src/auth.rs:161 tests::platform #[cfg(not(unix))] · no record in the data · owner NONE" "[rust] 쌍둥이 둘"
assert_contains "$OUT" "DRIFT [rust] unowned never-executed function rust/src/auth.rs:tests::exchange_rejects_empty" "[rust] 테스트 함수가 목록에 샌다"
# 매크로가 만든 함수 — 레코드가 macro_rules! 몸통을 가리킨다. 같은 줄을 나눠 써 안 돈 것을 못 가른다(독립 레그 실측: 두
# 생성 함수의 레코드가 같은 줄). 그 자리에 레코드를 심는다(`twice!` 는 식 매크로라 실제 데이터에는 없다).
fresh
sed -i '/^SF:.*auth\.rs$/a FN:116,_RNvfake_macro_generated\nFNDA:1,_RNvfake_macro_generated' "$D/rust.lcov"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] macro_rules! 안의 함수 레코드는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] rust/src/auth.rs:116: the data has a function (_RNvfake_macro_generated) inside macro_rules! twice" "[rust] 매크로를 댄다"
# 함수 레코드 없이 낸 데이터(`cargo llvm-cov --skip-functions`) — 줄은 돌았는데 모든 함수가 「레코드 없음」이 된다(독립 레그 실측).
fresh
sed -i '/^FN:/d; /^FNDA:/d' "$D/rust.lcov"
assert_not_contains "$(cat "$D/rust.lcov")" "FN:" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 함수 레코드 없는 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "but has no function record there — a report without function records" "[rust] 레코드 없는 줄을 댄다"
# 함수 레코드는 있는데 호출 횟수(FNDA)가 없다 — async 몸통이 돌았는지 못 읽는다(0 으로 읽으면 돈 몸통을 「안 돌았다」로 낸다).
# 전부 없을 때와 하나만 없을 때 둘 다.
fresh
sed -i '/^FNDA:/d' "$D/rust.lcov"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] FNDA 없는 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] rust/src/admin.rs:" "[rust] FNDA 없는 자리를 댄다"
assert_contains "$OUT" "without an FNDA count — whether an async body ran cannot be read" "[rust] FNDA 없음을 댄다"
fresh
sed -i '/^FNDA:.*warm_up0/d' "$D/rust.lcov"
assert_not_contains "$(grep '^FNDA:' "$D/rust.lcov")" "warm_up0" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 레코드 하나의 FNDA 만 빠져도 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] rust/src/client.rs:95: the data has a function record (" "[rust] 그 레코드를 댄다"
# `#[async_trait]` 꼴 — 안 poll 해도 닫는 줄에 바깥 함수의 횟수가 실린다(독립 레그 실측: DA:49,1 · DA:52,1). 줄로 재면
# 「실행됨」이 된다 — 그래서 FNDA 로 잰다(범위 안에서 돈 레코드가 바깥 함수 하나뿐). 반대 꼴(주석뿐인 몸통을 poll — 머리·닫는
# 줄에만 DA)은 건강한 픽스처의 `warm_up` 이 맡는다(목록에 없어야 한다).
fresh
sed -i '/^SF:.*admin\.rs$/,/^end_of_record$/s/^DA:54,1$/DA:54,1\nDA:56,1/' "$D/rust.lcov"
assert_contains "$(cat "$D/rust.lcov")" "DA:56,1" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_line "$OUT" "  NEVER rust/src/admin.rs:54 AdminClient::delete_user · called, but its async body never ran · owner open-admin" "[rust] 닫는 줄이 돌아도 몸통 레코드가 안 돌았으면 미실행"
# 라이브러리가 몸통 레코드를 0 회로 따로 남기는 꼴(실측 — scratchpad exp-async2 의 `never_polled0B3_` · FNDA 0; 이 픽스처
# 크레이트의 링크에서는 안 남았다) — 레코드 「개수」가 아니라 「돈 레코드」를 센다. 그 자리에 0 회 몸통 레코드를 심는다.
fresh
sed -i '/^SF:.*client\.rs$/a FN:100,_RNCfake_never_polled_body\nFNDA:0,_RNCfake_never_polled_body' "$D/rust.lcov"
assert_contains "$(cat "$D/rust.lcov")" "FNDA:0,_RNCfake_never_polled_body" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 0 "$RC" "[rust] 0 회 몸통 레코드가 있어도 — 출력: $OUT"
assert_line "$OUT" "  NEVER rust/src/client.rs:100 never_polled · called, but its async body never ran · owner open-admin" "[rust] 돈 레코드가 바깥 함수 하나뿐이면 미실행"
# 속성 매크로는 철자가 아니라 「내장이 아니다」로 가린다(독립 레그 4차: `#[::async_trait::async_trait]` · 별칭 `#[at]` 이 정규식을
# 비켜 poll 한 메서드가 「안 돌았다」로 들었다). 대조군: 내장 속성만 남기면 면제가 풀려 poll 한 Polled 가 든다 — 데이터만으로는
# 가를 수 없다는 증거다(돈 레코드 하나 · 몸통 줄 없음).
for _attr in '#[::async_trait::async_trait]' '#[at]' '#[cfg_attr(not(feature = "plain"), async_trait::async_trait)]'; do
  fresh
  sed -i "80s/^#\[async_trait::async_trait\]\$/$_attr/" "$T/rust/src/admin.rs"
  assert_contains "$(sed -n '80p' "$T/rust/src/admin.rs")" "$_attr" "(변이가 착지했는지 먼저 본다)"
  run report rust "$T" --out "$D"
  assert_eq 0 "$RC" "[rust] $_attr 도 속성 매크로다 — 출력: $OUT"
  assert_not_contains "$OUT" "Polled as Fetch" "[rust] $_attr — poll 한 메서드는 목록에 없다"
done
fresh
sed -i '80s/^#\[async_trait::async_trait\]$/#[allow(dead_code)]/' "$T/rust/src/admin.rs"
assert_contains "$(sed -n '80p' "$T/rust/src/admin.rs")" "#[allow(dead_code)]" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 1 "$RC" "[rust] 내장 속성만이면 async 판정이 걸린다 — 출력: $OUT"
assert_line "$OUT" "  NEVER rust/src/admin.rs:82 <Polled as Fetch>::fetch · called, but its async body never ran · owner NONE" "[rust] 대조군 — poll 했는데도 데이터는 「안 돌았다」로 읽힌다"
# cfg_attr 는 안쪽 속성으로 가린다 — 안쪽이 내장뿐이면 면제가 아니다(cfg_attr 를 통째로 매크로로 읽지 않는다).
fresh
sed -i '80s/^#\[async_trait::async_trait\]$/#[cfg_attr(not(feature = "plain"), allow(dead_code))]/' "$T/rust/src/admin.rs"
assert_contains "$(sed -n '80p' "$T/rust/src/admin.rs")" "allow(dead_code))]" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 1 "$RC" "[rust] cfg_attr 안이 내장뿐이면 async 판정이 걸린다 — 출력: $OUT"
assert_contains "$OUT" "<Polled as Fetch>::fetch · called, but its async body never ran" "[rust] cfg_attr 대조군"
# 같은 이름이 둘 — 미실행 목록이 둘을 못 가른다.
fresh
sed -i 's#^impl Wrapper<u16> {$#impl Wrapper<u8> {#' "$T/rust/src/auth.rs"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 같은 이름의 함수가 둘이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] rust/src/auth.rs: two functions are both named Wrapper<u8>::get" "[rust] 겹친 이름을 댄다"
# 끝나지 않는 원시 문자열 — 이름 범위를 못 읽는다(조용히 「미실행 0」이 되지 않는다).
fresh
printf '%s\n' 'const OPEN: &str = r#"' >> "$T/rust/src/auth.rs"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 열린 원시 문자열은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] rust/src/auth.rs: a string or block comment runs to the end of the file" "[rust] 못 읽는다고 댄다"
# 소유자 없는 미실행 함수(exit 1 — 경고). 레코드 없는 함수도 소유자가 있어야 한다.
fresh
sed -i '/"rust\/src\/auth.rs:unused_helper"/d' "$T/scripts/integration-coverage.json"
run report rust "$T" --out "$D"
assert_eq 1 "$RC" "[rust] 소유자 없는 미실행 함수는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [rust] unowned never-executed function rust/src/auth.rs:unused_helper" "[rust] 소유자 없음"
assert_line "$OUT" "  NEVER rust/src/auth.rs:129 unused_helper · no record in the data · owner NONE" "[rust] 목록에도 NONE 으로 남는다"

# php — 데이터의 무결성. 도구가 낸 이름 · 범위를 믿는 대신 세 가지를 대조한다(해시 · index ↔ 파일 XML · 메서드 합 = 파일 합).
fresh
rm -rf "$D/php"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 데이터가 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] no coverage data at" "[php] 데이터 없음"
assert_contains "$OUT" "node scripts/integration-coverage.mjs run php" "[php] 무엇을 돌릴지 댄다"
fresh
printf '%s\n' '<?xml version="1.0"?>' '<coverage line-rate="1"/>' > "$D/php/index.xml"
php_mark 0
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] PHPUnit XML 이 아니면 exit 2(다른 형식을 통과로 읽지 않는다) — 출력: $OUT"
assert_contains "$OUT" "is not a PHPUnit code-coverage XML report" "[php] 형식이 다르다"
fresh
sed -i 's#<project source="[^"]*"#<project source="/elsewhere/php/src"#' "$D/php/index.xml"
php_mark 0
assert_contains "$(cat "$D/php/index.xml")" '<project source="/elsewhere/php/src"' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 다른 체크아웃의 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] the data's project source /elsewhere/php/src is outside this tree — the data belongs to another checkout" "[php] 다른 체크아웃"
fresh
sed -i '/<file name="AuthClient.php"/,/<\/file>/d' "$D/php/index.xml"
php_mark 0
assert_not_contains "$(cat "$D/php/index.xml")" 'name="AuthClient.php"' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 데이터에서 경계 파일이 빠지면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] php/src/AuthClient.php is not in the coverage data" "[php] 빠진 파일을 댄다"
assert_not_contains "$OUT" "  total " "[php] 빠진 파일이 있으면 수치를 내지 않는다"
# 실행 뒤 소스가 바뀌었다 — 데이터의 해시(sha1)는 그 실행이 읽은 바이트의 것이다.
fresh
printf '%s\n' '// edited after the run' >> "$T/php/src/AuthClient.php"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 다른 바이트에서 난 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] php/src/AuthClient.php: the data was taken from other bytes (sha1 cdd9b2f0f71a" "[php] 해시 불일치"
fresh
rm "$D/php/Admin/AdminClient.php.xml"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] index.xml 이 댄 파일 XML 이 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "Admin/AdminClient.php.xml" "[php] 없는 파일 XML 을 댄다"
fresh
sed -i 's#executable="17" executed="13"#executable="18" executed="13"#' "$D/php/index.xml"
php_mark 0
assert_contains "$(cat "$D/php/index.xml")" 'executable="18" executed="13"' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] index.xml 과 파일 XML 의 합이 갈리면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] php/src/AuthClient.php: index.xml says 18/13 executable/executed lines, AuthClient.php.xml says 17/13 — the data contradicts itself" "[php] 두 합이 갈린다"
# 메서드 밖에 실행 가능 줄이 있다(파일 합이 메서드 합보다 크다) — 그 줄은 어느 함수에도 못 붙인다.
fresh
sed -i 's#executable="17" executed="13"#executable="18" executed="13"#' "$D/php/index.xml" "$D/php/AuthClient.php.xml"
php_mark 0
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 메서드 밖 줄은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] php/src/AuthClient.php: its methods and functions account for 17 of 18 executable lines (13 of 13 executed) — lines outside any method cannot be attributed to a function" "[php] 메서드 합 ≠ 파일 합"
fresh
printf '%s\n' '<?xml version="1.0"?>' '<coverage><project source="/x/php/src"/></coverage>' > "$D/php/index.xml"
php_mark 0
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] <phpunit> 루트가 아닌 문서는 project source 가 있어도 exit 2 — 출력: $OUT"
assert_contains "$OUT" "is not a PHPUnit code-coverage XML report" "[php] 루트가 다르다"
fresh
sed -i 's# hash="a64b10a0b0d866b06c61cdf8644560503a083c06"##' "$D/php/index.xml"
php_mark 0
assert_not_contains "$(cat "$D/php/index.xml")" 'a64b10a0b0d866b06c61cdf8644560503a083c06' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 해시 없는 <file> 은 exit 2(대조를 건너뛰지 않는다) — 출력: $OUT"
assert_contains "$OUT" "has a <file> without href · sha1 hash · line totals" "[php] 해시 없음"
fresh
sed -i '/<file name="AuthClient.php"/,/<\/file>/{/<\/file>/s#$#\n<file name="AuthClient.php" href="AuthClient.php.xml" hash="cdd9b2f0f71af9144f80421d68e74b7ed719af44"><totals><lines executable="17" executed="13"/></totals></file>#}' "$D/php/index.xml"
php_mark 0
assert_eq 2 "$(grep -c '<file name="AuthClient.php"' "$D/php/index.xml")" "(변이가 착지했는지 먼저 본다 — 완전한 항목이 둘)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] index 에 같은 파일이 두 번이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] php/src/AuthClient.php has two entries in" "[php] 겹친 항목"
fresh
sed -i 's#\(<method name="helper" [^>]*\) executable="1" executed="1"#\1 executed="1"#' "$D/php/AuthClient.php.xml"
assert_not_contains "$(grep 'name="helper"' "$D/php/AuthClient.php.xml")" 'executable=' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 횟수 없는 메서드는 0 으로 읽지 않는다(exit 2) — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] php/src/AuthClient.php: cannot read the counts of AuthClient::helper" "[php] 못 읽는 횟수"
# 못 읽는 횟수를 0 으로 읽지 않는다 — 안 돈 메서드의 `executed="0"` 을 망가뜨리면, 0 으로 읽을 때 합 · 크기 판정을 다 지나
# OK 가 된다(변이 q11 이 SILENT 였다: 위 단언은 `executed="1" > 0` 판정이 같은 문구로 먼저 잡아 이 갈래를 재지 못했다).
fresh
sed -i 's#\(<method name="logoutUrl" [^>]*\) executed="0"#\1 executed="none"#' "$D/php/AuthClient.php.xml"
assert_contains "$(grep 'name="logoutUrl"' "$D/php/AuthClient.php.xml")" 'executed="none"' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 숫자가 아닌 횟수는 0 으로 읽지 않는다(exit 2) — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] php/src/AuthClient.php: cannot read the counts of AuthClient::logoutUrl" "[php] 숫자가 아닌 횟수"
fresh
sed -i 's#\(<method name="logoutUrl" [^>]*\) executable="2" executed="0"#\1 executable="2" executed="3"#' "$D/php/AuthClient.php.xml"
assert_contains "$(grep 'name="logoutUrl"' "$D/php/AuthClient.php.xml")" 'executed="3"' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 실행이 실행 가능보다 많으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] php/src/AuthClient.php: cannot read the counts of AuthClient::logoutUrl" "[php] 모순된 횟수"
fresh
sed -i 's#^\(\s*\)<function name="Fixture#\1<method name="loose" signature="loose()" start="1" end="1" crap="1" executable="0" executed="0" coverage="0"/>\n\1<function name="Fixture#' "$D/php/Admin/AdminClient.php.xml"
assert_contains "$(cat "$D/php/Admin/AdminClient.php.xml")" '<method name="loose"' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 클래스·트레이트 밖의 메서드는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] php/src/Admin/AdminClient.php: the data has a method (loose) outside any class or trait" "[php] 모르는 컨테이너"
# 데이터가 통합 스위트의 성공한 실행에서 났는가 — <tests> 는 경계 줄을 하나라도 돈 테스트와 결과다(경계를 안 지나는 ZeroIT 는
# 실리지 않는다 — 그래서 「스위트의 클래스가 다 돌았나」는 재지 않는다). 기대 집합은 tree/php/phpunit.xml 의 통합 스위트로
# 디스크에서 찾은 {DriveIT, ZeroIT} 다.
fresh
sed -i 's#\(<test name="DriveIT::testDrive" [^>]*\)status="success"#\1status="failure"#' "$D/php/index.xml"
php_mark 0
assert_contains "$(cat "$D/php/index.xml")" 'status="failure"' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 실패한 실행의 데이터는 exit 2(PHPUnit 은 실패해도 XML 을 쓴다) — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] 1 of 1 tests in the run did not succeed — the data of a failed run is partial: DriveIT::testDrive (failure)" "[php] 실패한 테스트"
# 단위 스위트를 같은 설정으로 돌린 꼴(독립 레그 실측의 꼴) — 경계를 지난 단위 테스트가 목록에 든다.
fresh
sed -i 's#\(<test name="DriveIT::testDrive" [^>]*/>\)#\1\n      <test name="Fixture\\Keycloak\\Tests\\Unit\\ConfigTest::testRealm" size="unknown" status="success" time="0.001"/>#' "$D/php/index.xml"
php_mark 0
assert_contains "$(cat "$D/php/index.xml")" 'ConfigTest::testRealm' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 스위트 밖 테스트가 섞이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] the run included tests outside the integration suite (ConfigTest) — the report would not be integration-only" "[php] 스위트 밖"
fresh
sed -i '/<test name="DriveIT::testDrive"/d' "$D/php/index.xml"
php_mark 0
assert_not_contains "$(cat "$D/php/index.xml")" 'DriveIT::testDrive' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 줄은 돌았는데 테스트가 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "counts executed lines but lists no tests — the data contradicts itself" "[php] 모순"
fresh
sed -i '/<testsuite name="integration">/d' "$T/php/phpunit.xml"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 통합 스위트 정의가 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" 'php/phpunit.xml must define exactly one <testsuite name="integration"> (found 0)' "[php] 스위트 없음"
# run 기록 — 이 데이터를 `run php` 가 썼고 그 실행이 성공했는가(독립 레그 2차: 경계에 닿기 전에 실패한 테스트는 <tests> 에
# 아예 안 실려, 실패한 실행을 따로 report 하면 77/235 · exit 1 로 지나갔다).
fresh
rm "$D/php.run.json"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] run 기록이 없으면 exit 2(손으로 돌린 실행) — 출력: $OUT"
assert_contains "$OUT" "no record that \`run php\` wrote this data" "[php] 기록 없음"
fresh
sed -i 's#"run":"php"#"run":"ruby"#' "$D/php.run.json"
assert_contains "$(cat "$D/php.run.json")" '"run":"ruby"' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 다른 레인이 쓴 꼴의 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "no record that \`run php\` wrote this data" "[php] 다른 레인의 기록"
fresh
php_mark 2
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 실패한 실행의 기록이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] the run that wrote this data exited 2 — the data of a failed run is partial" "[php] 실패 종료"
assert_not_contains "$OUT" "  total " "[php] 실패한 실행은 수치를 내지 않는다"
fresh
printf '%s\n' '<!-- another run wrote over the data -->' >> "$D/php/index.xml"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 기록 뒤 바뀐 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "is not the data \`run php\` recorded" "[php] 기록과 다른 데이터"
# suffix 를 안 적은 <directory> 는 PHPUnit 기본(`Test.php`)으로 고른다 — `*IT.php` 는 하나도 안 든다.
fresh
sed -i 's#<directory suffix="IT.php">tests/Integration</directory>#<directory>tests/Integration</directory>#' "$T/php/phpunit.xml"
assert_contains "$(cat "$T/php/phpunit.xml")" '<testsuite name="integration"><directory>tests/Integration</directory>' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 기본 suffix 로 고르면 IT 파일이 없다 — exit 2 — 출력: $OUT"
assert_contains "$OUT" "the integration testsuite finds no test files — a report over no tests is vacuous" "[php] 빈 스위트"
fresh
sed -i 's#\(<testsuite name="integration"><directory suffix="IT.php">tests/Integration</directory>\)#\1<exclude>tests/Integration/ZeroIT.php</exclude>#' "$T/php/phpunit.xml"
assert_contains "$(cat "$T/php/phpunit.xml")" '<exclude>tests/Integration/ZeroIT.php</exclude>' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 모르는 고르기(<exclude>)는 exit 2 — 무엇이 스위트인지 모르면 가를 수 없다 — 출력: $OUT"
assert_contains "$OUT" "selects tests with something other than <directory> and <file>" "[php] 모르는 고르기"
fresh
sed -i 's#<method name="realm" #<method name="__construct" #' "$D/php/AuthClient.php.xml"
assert_contains "$(cat "$D/php/AuthClient.php.xml")" 'signature="realm(): string"' "(변이가 착지했는지 먼저 본다)"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 이름이 겹치면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] php/src/AuthClient.php: two functions are both named AuthClient::__construct" "[php] 겹친 이름"
fresh
sed -i '/"php\/src\/AuthClient.php:AuthClient::__debugInfo"/d' "$T/scripts/integration-coverage.json"
assert_not_contains "$(cat "$T/scripts/integration-coverage.json")" 'AuthClient::__debugInfo' "(변이가 착지했는지 먼저 본다 — 마지막이 아닌 항목이라 JSON 이 그대로 맞다)"
run report php "$T" --out "$D"
assert_eq 1 "$RC" "[php] 소유자 없는 미실행 함수는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [php] unowned never-executed function php/src/AuthClient.php:AuthClient::__debugInfo" "[php] 소유자 없음"
assert_line "$OUT" "  NEVER php/src/AuthClient.php:70 AuthClient::__debugInfo · 1 line · owner NONE" "[php] 목록에도 NONE 으로 남는다"

# ruby — 덤프의 무결성. VM 이 낸 이름 · 범위 · 횟수를 받되, 덤프가 이 트리 · 이 실행 · 이 바이트의 것인지와 스스로 맞는지를 본다.
fresh
rm "$D/ruby.json"
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 덤프가 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] no coverage data at" "[ruby] 데이터 없음"
fresh
printf 'not json' > "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] JSON 이 아니면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/ruby.json is not JSON" "[ruby] JSON 아님"
fresh
sed -i 's|kcsdk-ruby-coverage/1|kcsdk-ruby-coverage/2|' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 다른 형식이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "is not the dump \`run ruby\` writes (format kcsdk-ruby-coverage/1)" "[ruby] 형식"
fresh
sed -i 's|"root":"[^"]*"|"root":"/elsewhere/ruby"|' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 다른 루트의 덤프는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] the dump's root /elsewhere/ruby is not ruby/ of this tree — the data belongs to another checkout" "[ruby] 다른 체크아웃의 루트"
# 예제 — 통합 스위트만, 전부 통과(덤프는 스위트 뒤에 쓰이므로 실패한 예제도 실린다).
fresh
sed -i 's|"status":"passed"|"status":"failed"|' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 실패한 예제가 있으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] 1 of 1 examples in the run did not pass — the data of a failed run is partial: ./spec/integration/drive_spec.rb[1:1] (failed)" "[ruby] 실패한 예제"
fresh
sed -i 's|"integration":true|"integration":false|' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 통합 태그 없는 예제는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] the run included examples outside the integration suite (./spec/integration/drive_spec.rb[1:1]) — the report would not be integration-only" "[ruby] 태그 밖"
fresh
sed -i 's|"file":"./spec/integration/drive_spec.rb"|"file":"./spec/unit/drive_spec.rb"|' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] spec/integration 밖의 예제는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "outside the integration suite" "[ruby] 디렉터리 밖"
fresh
sed -i 's|"examples":\[{[^}]*}\]|"examples":[]|' "$D/ruby.json"
ruby_mark 0
assert_contains "$(cat "$D/ruby.json")" '"examples":[]' "(변이가 착지했는지 먼저 본다)"
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 예제가 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] the run recorded no examples — a report over no tests is vacuous" "[ruby] 예제 없음"
fresh
sed -i 's|,"status":"passed"||' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] status 없는 예제는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "has an example without id · file · status — not the dump this reader knows" "[ruby] 모르는 예제"
# 파일
fresh
sed -i 's|"[^"]*/ruby/lib/kc/version\.rb":{[^}]*},||' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 경계 파일이 덤프에 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc/version.rb is not in the coverage data — a boundary file the run never loaded would silently leave the denominator" "[ruby] 덤프에 없는 경계 파일"
fresh
sed -i 's|/ruby/lib/kc\.rb"|/ruby/lib/kc_gone.rb"|' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 트리에 없는 파일이 덤프에 있으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc_gone.rb is in the data but not in the tree — the data belongs to another checkout" "[ruby] 트리에 없는 파일"
fresh
sed -i 's|"[^"]*/ruby/lib/kc\.rb"|"/elsewhere/ruby/lib/kc.rb"|' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 트리 밖 경로는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] the data has /elsewhere/ruby/lib/kc.rb, outside this tree — the data belongs to another checkout" "[ruby] 트리 밖"
fresh
sed -i 's|/ruby/lib/kc\.rb"|/ruby/lib/./kc/version.rb"|' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 같은 파일이 두 번이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc/version.rb has two entries in" "[ruby] 겹친 항목"
fresh
printf '# changed after the run\n' >> "$T/ruby/lib/kc/auth_client.rb"
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 다른 바이트에서 난 덤프는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc/auth_client.rb: the data was taken from other bytes (sha1 420f81939737… in the data," "[ruby] 해시 불일치"
fresh
sed -i 's|"sha1":"420f819397379003fbb5ebe25d556d527d049801",||' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] sha1 없는 항목은 exit 2(대조를 건너뛰지 않는다) — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc/auth_client.rb: the entry has no sha1 · lines · methods — not the dump this reader knows" "[ruby] sha1 없음"
fresh
sed -i 's|"lines":\[null,null,1,1,null\]|"lines":[null,null,1,"x",null]|' "$D/ruby.json"
ruby_mark 0
assert_contains "$(cat "$D/ruby.json")" '[null,null,1,"x",null]' "(변이가 착지했는지 먼저 본다)"
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 숫자가 아닌 줄 횟수는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc/version.rb: cannot read the line counts in" "[ruby] 못 읽는 줄 횟수"
# 메서드
fresh
sed -i 's|"name":"token","start":\[12,4\],"end":\[18,7\],"count":2|"name":"token","start":[12,4],"end":[18,7],"count":-1|' "$D/ruby.json"
ruby_mark 0
assert_contains "$(cat "$D/ruby.json")" '"count":-1' "(변이가 착지했는지 먼저 본다)"
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 못 읽는 메서드 레코드는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc/auth_client.rb: cannot read a method record (Kc::AuthClient token) in" "[ruby] 못 읽는 메서드"
fresh
sed -i 's|"owner":"Kc::AuthClient","name":"introspect"|"owner":"#<Class:0x000055d5>","name":"introspect"|' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 이름을 못 다는 소유자는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc/auth_client.rb:30: cannot name the method introspect of #<Class:0x000055d5> — not an owner this reader knows (anonymous class?)" "[ruby] 익명 소유자"
fresh
sed -i 's|"start":\[30,4\],"end":\[34,7\]|"start":[30,4],"end":[99,7]|' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 파일 밖까지 가는 범위는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc/auth_client.rb: AuthClient#introspect spans lines 30–99, outside the 36 lines the data counts — the data contradicts itself" "[ruby] 범위 밖"
fresh
sed -i 's|"name":"build"|"name":"parse"|' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 이름이 겹치면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc/auth_client.rb: two methods are both named AuthClient.parse — the owner keys would collide" "[ruby] 겹친 이름"
fresh
sed -i 's|"start":\[26,4\],"end":\[28,7\]|"start":[26,4],"end":[31,7]|' "$D/ruby.json"
ruby_mark 0
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 겹친 범위는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc/auth_client.rb: AuthClient#introspect (30–34) lies inside or across AuthClient.build (26–31) — a line cannot be given to one method" "[ruby] 겹친 범위"
assert_not_contains "$OUT" "module_function?" "[ruby] 다른 이름의 겹침에 module_function 을 짚지 않는다"
# module_function 꼴 — 같은 범위에 `#` 와 `.` 의 같은 이름(독립 레그 실측: 경계 밖 masking.rb). 합치지 않고 FAIL 하되 까닭을 짚는다.
fresh
sed -i 's|"name":"build","start":\[26,4\],"end":\[28,7\]|"name":"introspect","start":[30,4],"end":[34,7]|' "$D/ruby.json"
ruby_mark 0
assert_contains "$(cat "$D/ruby.json")" '"owner":"#<Class:Kc::AuthClient>","name":"introspect","start":[30,4]' "(변이가 착지했는지 먼저 본다)"
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 같은 범위의 인스턴스 · 특이 쌍은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "lies inside or across AuthClient#introspect (30–34) — a line cannot be given to one method (module_function? it records the instance method and its singleton copy on the same lines — this reader does not merge them)" "[ruby] module_function 을 짚는다"
fresh
sed -i 's|"lines":\[null,null,1,null,1,1,null,1,1,|"lines":[null,null,1,null,1,0,null,1,1,|' "$D/ruby.json"
ruby_mark 0
assert_contains "$(cat "$D/ruby.json")" '"lines":[null,null,1,null,1,0,null,1,1,' "(변이가 착지했는지 먼저 본다)"
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 메서드 밖인데 적재 때 안 돈 줄은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc/auth_client.rb:6: a line outside every method never ran although the file was loaded — a block or lambda body no method can be credited with" "[ruby] 어느 메서드에도 못 붙는 줄"
fresh
sed -i 's|1,0,null,0,null,null,null\]|1,1,null,0,null,null,null]|' "$D/ruby.json"
ruby_mark 0
assert_contains "$(cat "$D/ruby.json")" '1,1,null,0,null,null,null]' "(변이가 착지했는지 먼저 본다)"
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 호출 0 인데 몸통 줄이 돌면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc/auth_client.rb: AuthClient#introspect was called 0 times but a line of its body ran — the data contradicts itself" "[ruby] 모순"
# run 기록 — 이 덤프를 `run ruby` 가 썼고 그 실행이 성공했는가(php 와 같은 이유).
fresh
rm "$D/ruby.run.json"
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] run 기록이 없으면 exit 2(손으로 돌린 실행) — 출력: $OUT"
assert_contains "$OUT" "no record that \`run ruby\` wrote this data" "[ruby] 기록 없음"
fresh
sed -i 's#"run":"ruby"#"run":"php"#' "$D/ruby.run.json"
assert_contains "$(cat "$D/ruby.run.json")" '"run":"php"' "(변이가 착지했는지 먼저 본다)"
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 다른 레인이 쓴 꼴의 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "no record that \`run ruby\` wrote this data" "[ruby] 다른 레인의 기록"
fresh
ruby_mark 1
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 실패한 실행의 기록이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] the run that wrote this data exited 1 — the data of a failed run is partial" "[ruby] 실패 종료"
assert_not_contains "$OUT" "OK —" "[ruby] 실패한 실행은 수치를 내지 않는다"
fresh
sed -i 's|"ruby":"3.4.10"|"ruby":"3.4.11"|' "$D/ruby.json"
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 기록 뒤 바뀐 덤프는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "is not the data \`run ruby\` recorded" "[ruby] 기록과 다른 데이터"
# 기록 판정은 다른 판정 **뒤**에 둘 뿐 앞의 실패에 가려지지 않는다(php 와 같다) — 손으로 돌린 실행의 낡은 데이터면 두
# 까닭이 함께 보여야 한 번에 고친다.
fresh
printf '# changed after the run\n' >> "$T/ruby/lib/kc/auth_client.rb"
rm "$D/ruby.run.json"
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 해시 불일치와 기록 없음이 겹치면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] ruby/lib/kc/auth_client.rb: the data was taken from other bytes" "[ruby] 겹친 결함 — 해시"
assert_contains "$OUT" "no record that \`run ruby\` wrote this data" "[ruby] 겹친 결함 — 기록 판정도 낸다(php 와 같다)"
assert_contains "$OUT" "FAIL — 2 integrity failures" "[ruby] 겹친 결함 — 둘을 센다"
# 소유자 키는 「파일:짧은 이름」이다(인스턴스 `#` · 특이 `.`).
fresh
sed -i '/Client#flush/d' "$T/scripts/integration-coverage.json"
run report ruby "$T" --out "$D"
assert_eq 1 "$RC" "[ruby] 소유자 없는 미실행 메서드는 exit 1(경고) — 출력: $OUT"
assert_contains "$OUT" "DRIFT [ruby] unowned never-executed function ruby/lib/kc/admin/client.rb:Client#flush" "[ruby] 소유자 키"

# dotnet — coverlet 데이터 · trx · 기록의 무결성. 줄 · 횟수 · 이름을 받되, 데이터가 이 트리 · 이 실행 · 이 바이트의 것인지와
# 스스로 맞는지를 본다.
fresh
rm "$D/dotnet.json"
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 데이터가 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] no coverage data at" "[dotnet] 데이터 없음"
fresh
printf 'not json\n' > "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] JSON 이 아니면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/dotnet.json is not JSON" "[dotnet] JSON 아님"
fresh
printf '{"Kc.dll": []}\n' > "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] coverlet 의 꼴이 아니면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "is not coverlet's JSON (module → document → class → method)" "[dotnet] 꼴"
# 같은 판정의 앞 항 — 루트가 객체가 아니다(위는 루트가 객체이고 모듈 값만 배열이다 — 독립 레그 5차 지적).
fresh
printf '[]\n' > "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 객체 아닌 루트는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "is not coverlet's JSON (module → document → class → method)" "[dotnet] 루트 꼴"
fresh
_r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
sed -i "s#$_r#/elsewhere/checkout#g" "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 다른 체크아웃의 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "outside this tree — the data belongs to another checkout" "[dotnet] 다른 체크아웃의 문서"
fresh
_r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
printf '{"A.dll": {"%s/dotnet/src/Kc/AuthClient.cs": {}}, "B.dll": {"%s/dotnet/src/Kc/AuthClient.cs": {}}}\n' "$_r" "$_r" > "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 두 모듈에 같은 문서가 있으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] dotnet/src/Kc/AuthClient.cs is in two modules of" "[dotnet] 두 모듈"
fresh
sed -i 's#Config\.cs": {#Gone.cs": {#' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 트리에 없는 문서가 데이터에 있으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] dotnet/src/Kc/Gone.cs is in the data but not in the tree" "[dotnet] 트리에 없는 문서"
fresh
sed -i 's#AuthClient\.cs": {#AuthClientOld.cs": {#' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 데이터에 없는 경계 파일은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] dotnet/src/Kc/AuthClient.cs is not in the coverage data" "[dotnet] 데이터에 없는 경계 파일"
fresh
_r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
printf '{"Kc.dll": {"%s/dotnet/src/Kc/AuthClient.cs": [], "%s/dotnet/src/Kc/Admin/Client.cs": {}}}\n' "$_r" "$_r" > "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 클래스 → 메서드가 아닌 항목은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] dotnet/src/Kc/AuthClient.cs: the entry is not class → method" "[dotnet] 항목 꼴"
# 같은 판정의 뒤 항 — 문서 값은 객체인데 클래스 값이 아니다(위는 문서 값이 배열이라 이 항에 안 닿는다). 고친 데이터는 그것만으로
# 기록 대조가 FAIL 하므로 기록을 다시 써서 exit 2 가 이 결함에서만 오게 한다(아래 「다시 쓴다」 음성도 같다).
fresh
_r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
printf '{"Kc.dll": {"%s/dotnet/src/Kc/AuthClient.cs": {"Kc.AuthClient": []}, "%s/dotnet/src/Kc/Admin/Client.cs": {}}}\n' "$_r" "$_r" > "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 메서드 맵이 아닌 클래스는 exit 2(기록을 다시 쓴다) — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] dotnet/src/Kc/AuthClient.cs: the entry is not class → method" "[dotnet] 클래스 값 꼴"
fresh
sed -i 's#"60": 0#"60": -1#' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 음수 횟수는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot read the line counts of System.String Kc.AuthClient::Describe(System.Int32)" "[dotnet] 못 읽는 횟수"
fresh
sed -i 's#"60": 0#"0": 0#' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 0 번 줄은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot read the line counts of System.String Kc.AuthClient::Describe(System.Int32)" "[dotnet] 줄 번호는 1 부터"
# 같은 판정의 앞 항 — Lines 가 객체가 아니다(위 둘은 객체 안의 키 · 값만 틀렸다). 빈 배열이면 every 가 참이라 빈 메서드로 지나간다.
fresh
sed -i '/Kc.AuthClient::Build(Kc.Config)/,/"Lines"/s#"Lines": {#"Lines": [], "Was": {#' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 객체 아닌 Lines 는 exit 2(기록을 다시 쓴다) — 출력: $OUT"
assert_contains "$OUT" "cannot read the line counts of Kc.AuthClient Kc.AuthClient::Build(Kc.Config)" "[dotnet] Lines 꼴"
fresh
sed -i 's#"60": 0#"9999": 0#' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 파일 밖 줄은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "AuthClient.Describe counts line 9999, past the" "[dotnet] 파일 밖 줄"
fresh
sed -i 's#<GetAsync>d__0#<GetAsync>x__0#' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 모르는 생성 이름은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name Kc.Admin.Client/UsersResource/<GetAsync>x__0::MoveNext() — not a generated name this reader knows" "[dotnet] 모르는 꼴"
# 모르는 생성 꼴은 자리마다 따로 FAIL 이다 — 위는 상태 기계 자리다. 바깥 타입의 메서드 자리 · 람다 캐시의 메서드 자리도 같다(그
# 판정을 지우면 그 줄이 이름 null 인 가짜 멤버로 접힌다 — 기록을 다시 쓴다).
fresh
sed -i 's#<Count>g__Twice|14_0#<Count>q__Twice|14_0#' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 바깥 타입의 모르는 생성 이름은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name Kc.AuthClient::<Count>q__Twice|14_0(System.Int32) — not a generated name this reader knows" "[dotnet] 바깥 타입 자리의 모르는 꼴"
fresh
sed -i 's#<>c::<NamesAsync>b__25_0(#<>c::<NamesAsync>q__25_0(#' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 람다 캐시의 모르는 생성 이름은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name Kc.AuthClient/<>c::<NamesAsync>q__25_0(System.String) — not a generated name this reader knows" "[dotnet] 람다 캐시 자리의 모르는 꼴"
fresh
sed -i 's#<LogoutAsync>d__20#<Describe>d__20#g' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 상태 기계가 붙은 오버로드는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "AuthClient.Describe has overloads and a state machine or lambda folds into one of them" "[dotnet] 못 가르는 오버로드"
# 몸통은 시그니처와 상태 기계를 함께 센다 — 위는 동기 오버로드가 이미 둘이라 상태 기계를 안 세도 걸린다(변이 n19 SILENT). 아래
# 셋이 조건의 나머지 항을 하나씩 지난다: 상태 기계 둘 · 시그니처 하나와 상태 기계 하나 · 상태 기계 없이 람다(기록을 다시 쓴다).
fresh
sed -i 's#<LogoutAsync>d__20#<TokenAsync>d__20#g' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] async 오버로드 둘(상태 기계 둘)은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "AuthClient.TokenAsync has overloads and a state machine or lambda folds into one of them" "[dotnet] 상태 기계 둘인 오버로드"
fresh
sed -i 's#<LogoutAsync>d__20#<Build>d__20#g' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 동기 오버로드 하나와 async 오버로드 하나는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "AuthClient.Build has overloads and a state machine or lambda folds into one of them" "[dotnet] 시그니처 하나 · 상태 기계 하나인 오버로드"
fresh
sed -i 's#<Count>g__Twice|14_0#<Describe>g__Twice|14_0#' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 로컬 함수가 붙은 동기 오버로드는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "AuthClient.Describe has overloads and a state machine or lambda folds into one of them" "[dotnet] 람다가 붙은 오버로드"
# 빈 Lines 만 남은 이름 — coverlet 은 async 람다의 줄을 감싼 메서드 아래 싣고 그 상태 기계를 빈 Lines 로 낸다(Later). 그것만 남은
# 이름은 미실행이 아니고 보탤 줄도 없다(기록을 다시 쓴다).
fresh
sed -i 's#<<Later>b__23_0>d#<<Ghost>b__23_0>d#g' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 0 "$RC" "[dotnet] 빈 Lines 만 남은 이름은 exit 0 — 출력: $OUT"
assert_line "$OUT" "integration-coverage [dotnet]: OK — 45/84 lines (53.6%) · 13 never-executed functions, all owned by open registry items" "[dotnet] 줄 없는 이름은 미실행 목록에 안 든다"
assert_not_contains "$OUT" "Ghost" "[dotnet] 줄 없는 이름은 내지 않는다"
fresh
sed -i 's#<GetAsync>d__0::MoveNext()#<GetAsync>d__0::SetStateMachine()#' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 상태 기계의 MoveNext 아닌 메서드는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name Kc.Admin.Client/UsersResource/<GetAsync>d__0::SetStateMachine()" "[dotnet] 상태 기계는 MoveNext 만 안다"
fresh
sed -i 's#<TokenAsync>d__10#<TokenAsync>d__10/Inner#g' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 생성 타입 안의 사용자 타입은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name Kc.AuthClient/<TokenAsync>d__10/Inner::MoveNext()" "[dotnet] 생성 세그먼트 뒤 사용자 세그먼트"
fresh
sed -i 's#Kc.Admin.Client/UsersResource/<GetAsync>d__0#<GetAsync>d__0#g' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 사용자 타입이 없는 클래스는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name <GetAsync>d__0::MoveNext()" "[dotnet] 사용자 세그먼트 없음"
fresh
sed -i 's#Kc.AuthClient::Describe(System.Int32)#Kc.AuthClient:Describe(System.Int32)#' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 못 읽는 시그니처는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name Kc.AuthClient::System.String Kc.AuthClient:Describe(System.Int32)" "[dotnet] 시그니처에 「::」 가 없다"
fresh
sed -i 's#Kc.AuthClient/<>c/<<SumAsync>#Kc.AuthClient/<>c__DisplayClass5_0/<<SumAsync>#g' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 클로저 클래스 꼴은 exit 2(coverlet 이 안 내는 꼴 — 접지 않는다) — 출력: $OUT"
assert_contains "$OUT" "cannot name Kc.AuthClient/<>c__DisplayClass5_0/<<SumAsync>b__18_0>d::MoveNext()" "[dotnet] 모르는 클로저 꼴"
fresh
sed -i 's#<>c::<NamesAsync>b__25_0(#<>c::NamesAsync(#' "$D/dotnet.json"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 람다 캐시 안의 생성 이름 아닌 메서드는 exit 2(접지 않는다) — 출력: $OUT"
assert_contains "$OUT" "cannot name Kc.AuthClient/<>c::NamesAsync(System.String) — not a generated name this reader knows" "[dotnet] 람다 캐시의 모르는 꼴"
# 파생과 디스크가 갈렸다(파생 도구가 읽은 뒤 지워진 파일) — 가짜 파생 도구로 그 상태만 만든다.
fresh
printf '%s\n' 'console.log(JSON.stringify({ langs: { dotnet: { dir: "dotnet", site: "fake:1", label: "fake", universe: 3, files: ["dotnet/src/Kc/Admin/Client.cs", "dotnet/src/Kc/AuthClient.cs"] } }, findings: [] }))' > "$T/scripts/coverage-boundary.mjs"
rm "$T/dotnet/src/Kc/Admin/Client.cs"
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 파생에 있되 디스크에 없는 경계 파일은 exit 2(예외가 아니다) — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] dotnet/src/Kc/Admin/Client.cs is derived but missing on disk — the data cannot be checked against it" "[dotnet] 디스크에 없는 경계 파일"
# trx — 이 실행의 테스트 결과(범주가 없다 — 기대 집합은 Trait 을 단 소스의 클래스).
fresh
rm "$D/dotnet.trx"
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] trx 가 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] no test results at" "[dotnet] trx 없음"
fresh
sed -i 's#outcome="Passed"#outcome="Failed"#' "$D/dotnet.trx"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 실패한 테스트가 있으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] 1 of 1 tests in the run did not pass — the data of a failed run is partial: Kc.Tests.Integration.DriveTests.Drive (Failed)" "[dotnet] 실패한 테스트"
fresh
sed -i '/<UnitTestResult /d' "$D/dotnet.trx"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 테스트가 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] the run recorded no tests — a report over no tests is vacuous" "[dotnet] 테스트 없음"
fresh
sed -i 's#className="Kc.Tests.Integration.DriveTests"#className="Kc.Tests.UnitTests"#' "$D/dotnet.trx"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 스위트 밖 테스트는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] the run included tests outside the integration suite (Kc.Tests.Integration.DriveTests.Drive)" "[dotnet] 스위트 밖"
# 결과를 정의에 잇는 id · 정의의 TestMethod 가 없는 trx — 이을 수 없는 결과는 스위트 밖이다(독립 레그 5차 지적: 어느 음성도 이 둘을
# 따로 안 지났다). id 없는 정의가 있어도 id 없는 결과를 거기 잇지 않는다(기록을 다시 쓴다).
fresh
sed -i 's# testId="995e07f8-c482-520f-2c06-7d7bfea06a94"##; s# id="995e07f8-c482-520f-2c06-7d7bfea06a94">#>#' "$D/dotnet.trx"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] id 없는 결과 · 정의는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] the run included tests outside the integration suite (Kc.Tests.Integration.DriveTests.Drive)" "[dotnet] id 없는 결과는 잇지 않는다"
fresh
sed -i '/<TestMethod /d' "$D/dotnet.trx"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] TestMethod 없는 정의는 exit 2(예외가 아니다) — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] the run included tests outside the integration suite (Kc.Tests.Integration.DriveTests.Drive)" "[dotnet] TestMethod 없는 정의"
fresh
sed -i 's#\[Trait("Category", "Integration")\]##' "$T/dotnet/tests/Kc.Tests/integration/DriveTests.cs"
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] Trait 을 뗀 클래스는 스위트가 아니다 — 출력: $OUT"
assert_contains "$OUT" "the run included tests outside the integration suite" "[dotnet] 기대 집합은 소스의 Trait 이 정한다"
fresh
_r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
sed -i "s#codeBase=\"$_r#codeBase=\"/elsewhere/checkout#" "$D/dotnet.trx"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 다른 체크아웃의 테스트 결과는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "outside this tree — they belong to another checkout" "[dotnet] 다른 체크아웃의 trx"
fresh
sed -i 's# codeBase="[^"]*"##' "$D/dotnet.trx"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 테스트 어셈블리 경로가 없는 trx 는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "the test results ran an assembly with no codeBase, outside this tree" "[dotnet] codeBase 없음"
# 기대 집합은 특성이 **붙은** 클래스다 — 같은 파일의 다른 클래스 · 메서드에 붙은 특성은 아니다(독립 레그 지적: 파일 단위로 고르면
# 특성 없는 테스트가 섞인 실행이 통과했다).
fresh
printf '\npublic class Other\n{\n}\n' >> "$T/dotnet/tests/Kc.Tests/integration/DriveTests.cs"
sed -i 's#className="Kc.Tests.Integration.DriveTests"#className="Kc.Tests.Integration.Other"#' "$D/dotnet.trx"
dotnet_mark 0
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 특성 파일의 다른 클래스는 스위트가 아니다 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] the run included tests outside the integration suite (Kc.Tests.Integration.DriveTests.Drive)" "[dotnet] 같은 파일의 다른 클래스"
fresh
sed -i 's#^\[Collection("kc")\]#[Collection("kc")]\n[Shape(typeof(int[]))]#' "$T/dotnet/tests/Kc.Tests/integration/DriveTests.cs"
run report dotnet "$T" --out "$D"
assert_eq 0 "$RC" "[dotnet] 사이의 특성 인자에 「]」 가 있어도 클래스 특성이다 — 출력: $OUT"
assert_contains "$(cat "$T/dotnet/tests/Kc.Tests/integration/DriveTests.cs")" "[Shape(typeof(int[]))]" "(특성 주입이 착지했는지 먼저 본다)"
fresh
sed -i 's#^public sealed class DriveTests#public sealed record class DriveTests#' "$T/dotnet/tests/Kc.Tests/integration/DriveTests.cs"
run report dotnet "$T" --out "$D"
assert_eq 0 "$RC" "[dotnet] record class 도 클래스 특성이다 — 출력: $OUT"
assert_contains "$(cat "$T/dotnet/tests/Kc.Tests/integration/DriveTests.cs")" "public sealed record class DriveTests" "(한정자 주입이 착지했는지 먼저 본다)"
fresh
sed -i 's#^public sealed class DriveTests#public sealed record DriveTests#' "$T/dotnet/tests/Kc.Tests/integration/DriveTests.cs"
run report dotnet "$T" --out "$D"
assert_eq 0 "$RC" "[dotnet] class 낱말 없는 record 도 클래스 특성이다 — 출력: $OUT"
assert_contains "$(cat "$T/dotnet/tests/Kc.Tests/integration/DriveTests.cs")" "public sealed record DriveTests" "(선언 낱말 주입이 착지했는지 먼저 본다)"
fresh
sed -i 's#    public async Task Logout()#    [Trait("Category", "Integration")]\n    public async Task Logout()#' "$T/dotnet/tests/Kc.Tests/UnitTests.cs"
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 메서드에 붙은 특성은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] dotnet/tests/Kc.Tests/UnitTests.cs has a [Trait(\"Category\", \"Integration\")] that is not on a class declaration" "[dotnet] 클래스에 안 붙은 특성"
# run 기록 — 이 데이터를 `run dotnet` 이 썼고 그 실행이 성공했는가 · 경계 파일이 그 실행의 바이트인가(php · ruby 와 같은 이유).
fresh
rm "$D/dotnet.run.json"
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] run 기록이 없으면 exit 2(손으로 돌린 실행) — 출력: $OUT"
assert_contains "$OUT" "no record that \`run dotnet\` wrote this data" "[dotnet] 기록 없음"
fresh
sed -i 's#"run":"dotnet"#"run":"ruby"#' "$D/dotnet.run.json"
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 다른 레인이 쓴 꼴의 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "no record that \`run dotnet\` wrote this data" "[dotnet] 다른 레인의 기록"
fresh
dotnet_mark 1
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 실패한 실행의 기록이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] the run that wrote this data exited 1 — the data of a failed run is partial" "[dotnet] 실패 종료"
assert_not_contains "$OUT" "OK —" "[dotnet] 실패한 실행은 수치를 내지 않는다"
fresh
sed -i 's#"60": 0#"60": 0 #' "$D/dotnet.json"
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 기록 뒤 바뀐 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "is not the data \`run dotnet\` recorded" "[dotnet] 기록과 다른 데이터"
fresh
sed -i 's#computerName="HOST"#computerName="HOST2"#' "$D/dotnet.trx"
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 기록 뒤 바뀐 trx 는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "is not the test result \`run dotnet\` recorded" "[dotnet] 기록과 다른 trx"
fresh
sed -i 's#"files":{.*}}$#"files":null}#' "$D/dotnet.run.json"
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 경계 해시 없는 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "the record has no boundary hashes — the boundary files changed while the suite ran" "[dotnet] 실행 중 바뀐 경계"
fresh
printf '// changed after the run\n' >> "$T/dotnet/src/Kc/AuthClient.cs"
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 다른 바이트에서 난 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] dotnet/src/Kc/AuthClient.cs: the data was taken from other bytes" "[dotnet] 해시 불일치"
# 겹친 결함 — 기록 판정은 다른 판정 뒤에 둘 뿐 그것에 가려지지 않는다(php · ruby 와 같다).
fresh
sed -i 's#Config\.cs": {#Gone.cs": {#' "$D/dotnet.json"
rm "$D/dotnet.run.json"
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 트리에 없는 문서와 기록 없음이 겹치면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "is in the data but not in the tree" "[dotnet] 겹친 결함 — 데이터"
assert_contains "$OUT" "no record that \`run dotnet\` wrote this data" "[dotnet] 겹친 결함 — 기록 판정도 낸다"
assert_contains "$OUT" "FAIL — 2 integrity failures" "[dotnet] 겹친 결함 — 둘을 센다"
# 소유자 키는 「파일:타입.멤버」다(중첩 타입은 「.」으로 잇는다 · 오버로드는 시그니처를 붙인다).
fresh
sed -i '/Client.UsersResource.DeleteAsync/d' "$T/scripts/integration-coverage.json"
run report dotnet "$T" --out "$D"
assert_eq 1 "$RC" "[dotnet] 소유자 없는 미실행 함수는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [dotnet] unowned never-executed function dotnet/src/Kc/Admin/Client.cs:Client.UsersResource.DeleteAsync" "[dotnet] 소유자 키"
# java — JaCoCo XML · 클래스 사실(javap) · 기록의 무결성. 줄 · 횟수 · 이름을 받되, 데이터와 클래스 사실이 이 트리 · 한 빌드 · 이 실행의
# 것인지와 스스로 맞는지를 본다. 기록을 겨누지 않는 음성은 고친 뒤 기록을 다시 쓴다(java_mark 0 — 기록 판정이 exit 2 를 떠받치지 않게).
fresh
rm "$D/java.xml"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 데이터가 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [java] no coverage data at" "[java] 데이터 없음"
fresh
printf '<report name="x"/>\n' > "$D/java.xml"
java_mark 0
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] JaCoCo XML 이 아니면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/java.xml is not a JaCoCo XML report (no JaCoCo report DOCTYPE)" "[java] 형식이 다르다"
fresh
sed -i 's#<sessioninfo [^>]*/>##' "$D/java.xml"
java_mark 0
assert_not_contains "$(cat "$D/java.xml")" '<sessioninfo' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 세션 없는 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/java.xml records no session — the agent wrote no execution data" "[java] 세션 없음"
fresh
sed -i 's#<sourcefile name="AuthClient.java">#<sourcefile name="AuthClientOld.java">#' "$D/java.xml"
java_mark 0
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 데이터에서 경계 파일이 빠지면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [java] java/kc-auth/src/main/java/kc/auth/AuthClient.java is not in the coverage data" "[java] 빠진 경계 파일"
fresh
rm "$D/java.javap.txt"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] javap 출력이 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/java.javap.txt — run java writes javap's output there (line tables · enclosing methods of nested classes)" "[java] 클래스 사실 없음"
fresh
printf 'Error: class not found: kc.auth.AuthClient\n' > "$D/java.javap.txt"
java_mark 0
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 클래스를 하나도 안 담은 javap 출력은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [java] no class facts at" "[java] 클래스 없는 javap 출력"
fresh
sed -i 's|^\(  this_class: #[0-9]* *// kc/auth/AuthClient\)\$Token$|\1$Tokens|' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.javap.txt")" '// kc/auth/AuthClient$Tokens' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 클래스 사실과 데이터가 다른 클래스를 대면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "the class facts and the data name different classes (data only: kc/auth/AuthClient\$Token · facts only: kc/auth/AuthClient\$Tokens)" "[java] 클래스 집합이 갈린다"
fresh
sed -i 's#<method name="unused" desc="()Ljava/lang/String;" line="53">#<method name="unused" desc="()Ljava/lang/String;" line="52">#' "$D/java.xml"
java_mark 0
assert_contains "$(cat "$D/java.xml")" '<method name="unused" desc="()Ljava/lang/String;" line="52">' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 데이터와 클래스 사실의 첫 줄이 갈리면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "kc/auth/AuthClient.unused()Ljava/lang/String; — the data and the class facts disagree (first line 52 vs 53)" "[java] 첫 줄이 갈린다"
fresh
sed -i 's#name="unused"#name="access$000"#' "$D/java.xml"
sed -i 's#^  public java.lang.String unused();$#  public java.lang.String access$000();#' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.javap.txt")" '  public java.lang.String access$000();' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 모르는 생성 이름은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name kc/auth/AuthClient.access\$000()Ljava/lang/String; — not a generated name this reader knows" "[java] 모르는 생성 이름"
fresh
# 필드 초기화 · 초기화 블록 안의 익명 클래스는 EnclosingMethod 의 메서드 색인이 0 이다(JVMS 4.7.7) — 감싼 메서드가 없다.
sed -i 's|^EnclosingMethod: #41\.#43 |EnclosingMethod: #41.#0  |' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.javap.txt")" 'EnclosingMethod: #41.#0 ' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 감싼 메서드가 없는 익명 클래스는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name kc/auth/AuthClient\$1." "[java] 익명 클래스를 접지 못한다"
# 값을 돌려주는 오버로드의 마지막 문장에 든 여러 줄 람다 — 그 몸통 줄은 메서드의 LineNumberTable 범위 밖이다(실측 javac 21:
# `token(String, int)` {7} · 그 람다 {8, 9}). 람다의 첫 줄에서 가장 가까운 앞의 줄(36)을 가진 오버로드가 만들었다 — 범위만 보면 FAIL 했다.
fresh
sed -i 's#<method name="lambda$token$3" desc="(Ljava/lang/String;I)Ljava/lang/String;" line="36">#<method name="lambda$token$3" desc="(Ljava/lang/String;I)Ljava/lang/String;" line="37">#' "$D/java.xml"
sed -i '/^  private java.lang.String lambda\$token\$3(java.lang.String, int);$/,/^        line [0-9]*: / s/^        line 36: 0$/        line 37: 0\n        line 38: 6/' "$D/java.javap.txt"
java_mark 0
assert_contains "$(sed -n '/lambda\$token\$3(java.lang.String, int);$/,/^      LocalVariableTable/p' "$D/java.javap.txt")" '        line 38: 6' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[java] 오버로드의 범위 밖 여러 줄 람다는 그것을 만든 오버로드의 것 — exit 0 — 출력: $OUT"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:36 AuthClient.token(String, int) · 1 line · owner open-admin" "[java] 가장 가까운 앞의 줄을 가진 오버로드"
# 람다의 줄이 다른 오버로드의 몸통에 걸친다({35, 37} — 앞의 줄 31 은 token(String) 의 것인데 사이에 token(String, int) 의 36 이 있다) — 못 가른다.
fresh
sed -i 's#<method name="lambda$token$3" desc="(Ljava/lang/String;I)Ljava/lang/String;" line="36">#<method name="lambda$token$3" desc="(Ljava/lang/String;I)Ljava/lang/String;" line="35">#' "$D/java.xml"
sed -i '/^  private java.lang.String lambda\$token\$3(java.lang.String, int);$/,/^        line [0-9]*: / s/^        line 36: 0$/        line 35: 0\n        line 37: 6/' "$D/java.javap.txt"
java_mark 0
assert_contains "$(sed -n '/lambda\$token\$3(java.lang.String, int);$/,/^      LocalVariableTable/p' "$D/java.javap.txt")" '        line 37: 6' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 다른 오버로드의 몸통에 걸친 람다는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "AuthClient.token has overloads and a lambda whose lines fall in none or several of them" "[java] 람다를 못 붙이는 오버로드"
# 람다를 만든 줄에서 시작하는 여러 줄 람다({36, 38} — `return describe(() -> base +` · … · `ttl);`) — 그 첫 줄 자체가 만든 줄이다(그 줄을
# 빼고 앞 줄을 찾으면 31 의 token(String) 으로 가서 사이의 36 에 걸려 FAIL 한다).
fresh
sed -i '/^  private java.lang.String lambda\$token\$3(java.lang.String, int);$/,/^        line [0-9]*: / s/^        line 36: 0$/        line 36: 0\n        line 38: 6/' "$D/java.javap.txt"
java_mark 0
assert_contains "$(sed -n '/lambda\$token\$3(java.lang.String, int);$/,/^      LocalVariableTable/p' "$D/java.javap.txt")" '        line 38: 6' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[java] 만든 줄에서 시작하는 여러 줄 람다는 그 오버로드의 것 — exit 0 — 출력: $OUT"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:36 AuthClient.token(String, int) · 1 line · owner open-admin" "[java] 만든 줄이 람다의 첫 줄이다"
# 람다가 오버로드의 줄표 사이에 든다(token(String, int) {35, 37} · 람다 {36}) — 그 오버로드의 것이다. 데이터의 36 은 그 람다만 가져,
# 다른 오버로드에 붙이면 안 부른 이 오버로드의 줄이 데이터에서 사라진다(목록에서 빠진다).
fresh
sed -i 's#<method name="token" desc="(Ljava/lang/String;I)Ljava/lang/String;" line="36">#<method name="token" desc="(Ljava/lang/String;I)Ljava/lang/String;" line="35">#' "$D/java.xml"
sed -i '/^  public java.lang.String token(java.lang.String, int);$/,/^      LocalVariableTable:$/ s/^        line 36: 0$/        line 35: 0\n        line 37: 11/' "$D/java.javap.txt"
java_mark 0
assert_contains "$(sed -n '/^  public java.lang.String token(java.lang.String, int);$/,/^      LocalVariableTable:$/p' "$D/java.javap.txt")" '        line 37: 11' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[java] 줄표 사이에 든 람다는 그 오버로드의 것 — exit 0 — 출력: $OUT"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:36 AuthClient.token(String, int) · 1 line · owner open-admin" "[java] 몸통 범위로 그 오버로드에 붙는다"
# 한 줄에 선언된 두 메서드 오버로드와 그 줄의 람다(token(String, int) 의 줄표에 31 을 더했다 — `String a(int x) { return f(() -> x); }
# String a(String s) { return f(() -> s); }`) — 어느 오버로드가 만들었는지 못 가른다(생성자의 필드 람다와 다르다).
fresh
sed -i 's#<method name="token" desc="(Ljava/lang/String;I)Ljava/lang/String;" line="36">#<method name="token" desc="(Ljava/lang/String;I)Ljava/lang/String;" line="31">#' "$D/java.xml"
sed -i '/^  public java.lang.String token(java.lang.String, int);$/,/^      LocalVariableTable:$/ s/^        line 36: 0$/        line 31: 0\n        line 36: 3/' "$D/java.javap.txt"
java_mark 0
assert_contains "$(sed -n '/^  public java.lang.String token(java.lang.String, int);$/,/^      LocalVariableTable:$/p' "$D/java.javap.txt")" '        line 31: 0' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 한 줄의 메서드 오버로드가 함께 가진 줄 위의 람다는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "AuthClient.token has overloads and a lambda whose lines fall in none or several of them" "[java] 메서드 오버로드의 함께 가진 줄"
# 한 메서드의 줄표에 같은 줄이 두 번(javac 는 `a(); b();` 같은 한 줄에 항목을 여럿 낸다) — 오버로드 여럿이 함께 가진 줄이 아니다.
fresh
sed -i '/^  public java.lang.String token(java.lang.String, int);$/,/^      LocalVariableTable:$/ s/^        line 36: 0$/        line 36: 0\n        line 36: 3/' "$D/java.javap.txt"
java_mark 0
assert_eq 2 "$(sed -n '/^  public java.lang.String token(java.lang.String, int);$/,/^      LocalVariableTable:$/p' "$D/java.javap.txt" | grep -c '^        line 36: ')" "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[java] 한 메서드 안에서 거듭된 줄은 함께 가진 줄이 아니다 — exit 0 — 출력: $OUT"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:36 AuthClient.token(String, int) · 1 line · owner open-admin" "[java] 거듭된 줄"
# 생성자 몸통 안의 람다 — 두 생성자가 함께 가진 필드 초기화 줄(62)을 빼고 범위를 잡아야 Token(String) 의 몸통(65–67)이 Token(char) 의
# 범위(62–72)에 안 든다(독립 레그 2차 지적 — 그 줄을 넣고 재면 그 람다가 「함께 가진 람다」가 되어 Token(char) 의 줄로도 셌다).
fresh
sed -i 's#<method name="lambda$new$0" desc="()Ljava/lang/String;" line="62">#<method name="lambda$new$0" desc="()Ljava/lang/String;" line="66">#' "$D/java.xml"
sed -i '/^  private static java.lang.String lambda\$new\$0();$/,/^        line [0-9]*: / s/^        line 62: 0$/        line 66: 0/' "$D/java.javap.txt"
java_mark 0
assert_contains "$(sed -n '/lambda\$new\$0();$/,/^        line /p' "$D/java.javap.txt")" '        line 66: 0' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[java] 한 생성자의 몸통 안 람다는 그 생성자의 것 — exit 0 — 출력: $OUT"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:62 AuthClient.Token.<init>(char) · 4 lines · owner open-admin" "[java] 다른 생성자의 몸통 안 람다는 안 부른 생성자의 줄이 아니다"
# 모든 생성자의 줄보다 앞의 생성자 람다(50) — 그것을 만든 줄이 없다.
fresh
sed -i 's#<method name="lambda$new$0" desc="()Ljava/lang/String;" line="62">#<method name="lambda$new$0" desc="()Ljava/lang/String;" line="50">#' "$D/java.xml"
sed -i '/^  private static java.lang.String lambda\$new\$0();$/,/^        line [0-9]*: / s/^        line 62: 0$/        line 50: 0/' "$D/java.javap.txt"
java_mark 0
assert_contains "$(sed -n '/lambda\$new\$0();$/,/^        line /p' "$D/java.javap.txt")" '        line 50: 0' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 만든 줄이 없는 생성자 람다는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "AuthClient.Token.<init> has overloads and a lambda whose lines fall in none or several of them" "[java] 생성자에 못 붙이는 람다"
# 생성자 람다의 줄이 다음 생성자의 몸통에 걸친다({68, 71} — 앞의 줄 67 은 Token(String) 의 것인데 71 은 Token(char) 의 몸통이다)
# — 못 가른다(독립 레그 3차 지적의 꼴 — 몸통 밖 람다를 한 생성자에 조용히 붙였다).
fresh
sed -i 's#<method name="lambda$new$0" desc="()Ljava/lang/String;" line="62">#<method name="lambda$new$0" desc="()Ljava/lang/String;" line="68">#' "$D/java.xml"
sed -i '/^  private static java.lang.String lambda\$new\$0();$/,/^        line [0-9]*: / s/^        line 62: 0$/        line 68: 0\n        line 71: 1/' "$D/java.javap.txt"
java_mark 0
assert_contains "$(sed -n '/lambda\$new\$0();$/,/^}/p' "$D/java.javap.txt")" '        line 71: 1' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 다음 생성자의 몸통에 걸친 생성자 람다는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "AuthClient.Token.<init> has overloads and a lambda whose lines fall in none or several of them" "[java] 몸통에 걸친 람다"
# 함께 가진 줄(62 — 필드 초기화) 위의 람다는 한 생성자의 범위가 그 줄을 덮어도 그 생성자의 것이 아니다. 줄표는 손으로 만든 것이다 —
# Token(String) 에 60 줄을 더해 범위가 62 를 덮게 했다(javac 는 몸통이 필드 선언 줄을 감싸는 줄표를 못 낸다 — 리더는 줄표만 본다).
# Token(char) 가 돌아 필드 람다를 만들었고 Token(String) 은 안 돌았다 — 그 람다는 Token(String) 을 목록에서 빼는 근거가 아니다.
fresh
sed -i 's#<method name="&lt;init&gt;" desc="(Ljava/lang/String;)V" line="62"><counter type="INSTRUCTION" missed="0" covered="9"/><counter type="LINE" missed="0" covered="4"/>#<method name="\&lt;init\&gt;" desc="(Ljava/lang/String;)V" line="60"><counter type="INSTRUCTION" missed="9" covered="0"/><counter type="LINE" missed="4" covered="0"/>#; s#<method name="&lt;init&gt;" desc="(C)V" line="62"><counter type="INSTRUCTION" missed="10" covered="0"/><counter type="LINE" missed="4" covered="0"/>#<method name="\&lt;init\&gt;" desc="(C)V" line="62"><counter type="INSTRUCTION" missed="0" covered="10"/><counter type="LINE" missed="0" covered="4"/>#' "$D/java.xml"
sed -i '/^  public kc.auth.AuthClient\$Token(java.lang.String);$/,/^      LineNumberTable:$/ s/^      LineNumberTable:$/&\n        line 60: 0/' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.xml")" '<method name="&lt;init&gt;" desc="(C)V" line="62"><counter type="INSTRUCTION" missed="0" covered="10"/>' "(변이가 착지했는지 먼저 본다)"
assert_contains "$(sed -n '/^  public kc.auth.AuthClient\$Token(java.lang.String);$/,/^        line 65/p' "$D/java.javap.txt")" '        line 60: 0' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 1 "$RC" "[java] 안 돈 생성자는 소유자가 없어 exit 1 — 출력: $OUT"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:62 AuthClient.Token.<init>(String) · 4 lines · owner NONE" "[java] 함께 가진 줄 위의 람다는 범위가 덮은 생성자의 것이 아니다"
assert_not_contains "$OUT" "Token.<init>(char) ·" "[java] 돈 생성자는 목록에 없다"
# 몸통 밖 생성자 람다의 한 줄이 한 생성자의 몸통 범위에 든다({62, 66} — 66 은 Token(String) 의 몸통) — 어느 것인지 모른다(독립 레그
# 4차 지적 — 두 생성자의 「함께 가진 람다」가 되어 Token(char) 의 줄로 66 을 셌다). 손으로 만든 줄표다.
fresh
sed -i '/^  private static java.lang.String lambda\$new\$0();$/,/^        line [0-9]*: / s/^        line 62: 0$/&\n        line 66: 1/' "$D/java.javap.txt"
java_mark 0
assert_contains "$(sed -n '/lambda\$new\$0();$/,/^      LocalVariableTable/p' "$D/java.javap.txt")" '        line 66: 1' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 몸통에 한 줄이 든 몸통 밖 생성자 람다는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "AuthClient.Token.<init> has overloads and a lambda whose lines fall in none or several of them" "[java] 몸통에 걸친 생성자 람다"
# 한 줄에서 시작하는 두 생성자(Token(int) 의 줄표가 Token(String) 의 65 하나) — 그 줄도 「함께 가진 줄」이라 Token(int) 가 초기화를 끼워
# 넣은 생성자로 보이지만, 필드 람다(62)는 그 줄을 가진 두 생성자의 것이다(독립 레그 4차 지적 — FAIL 했다). 손으로 만든 줄표다.
fresh
sed -i 's#<method name="value" desc="()Ljava/lang/String;" line="75">#<method name="\&lt;init\&gt;" desc="(I)V" line="65"><counter type="LINE" missed="1" covered="0"/></method>&#' "$D/java.xml"
sed -i 's/^  public java.lang.String value();$/  public kc.auth.AuthClient$Token(int);\n    descriptor: (I)V\n      LineNumberTable:\n        line 65: 0\n\n&/' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.javap.txt")" '  public kc.auth.AuthClient$Token(int);' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 1 "$RC" "[java] 안 부른 셋째 생성자는 소유자가 없어 exit 1 — 출력: $OUT"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:65 AuthClient.Token.<init>(int) · 1 line · owner NONE" "[java] 한 줄에서 시작하는 생성자"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:62 AuthClient.Token.<init>(char) · 4 lines · owner open-admin" "[java] 필드 람다는 그 줄을 가진 생성자들의 것이다"
# 두 생성자 사이의 필드와 그 여러 줄 람다(필드 줄 68 · 람다 몸통 69 — javac 가 내는 꼴: `T(String s) {…}` · `final Supplier<String> x =
# () -> {` · `return …;` · `};` · `T(char c) {…}`). 위 생성자의 범위는 필드 줄에서 끝나 람다 몸통에 안 닿는다 — 필드 줄을 가진 두
# 생성자의 것이다(독립 레그 5차 지적 — FAIL 했다). 줄표는 픽스처의 62 를 68 로 · 람다를 69 로 옮겨 만들었다.
fresh
sed -i 's#<method name="&lt;init&gt;" desc="(Ljava/lang/String;)V" line="62">#<method name="\&lt;init\&gt;" desc="(Ljava/lang/String;)V" line="65">#; s#<method name="&lt;init&gt;" desc="(C)V" line="62">#<method name="\&lt;init\&gt;" desc="(C)V" line="68">#; s#<method name="lambda$new$0" desc="()Ljava/lang/String;" line="62">#<method name="lambda$new$0" desc="()Ljava/lang/String;" line="69">#; s#<line nr="62" mi="3" ci="5" mb="0" cb="0"/>#<line nr="68" mi="3" ci="5" mb="0" cb="0"/>#' "$D/java.xml"
sed -i '/^  public kc.auth.AuthClient\$Token(java.lang.String);$/,/^      LocalVariableTable:$/ s/^        line 62: 4$/        line 68: 4/; /^  public kc.auth.AuthClient\$Token(char);$/,/^      LocalVariableTable:$/ s/^        line 62: 4$/        line 68: 4/; /^  private static java.lang.String lambda\$new\$0();$/,/^        line [0-9]*: / s/^        line 62: 0$/        line 69: 0/' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.xml")" '<line nr="68" mi="3" ci="5" mb="0" cb="0"/>' "(변이가 착지했는지 먼저 본다)"
assert_eq 0 "$(grep -c '^        line 62: ' "$D/java.javap.txt")" "(변이가 착지했는지 먼저 본다 — 62 가 줄표에서 다 빠졌다)"
assert_eq 2 "$(grep -c '^        line 68: 4$' "$D/java.javap.txt")" "(변이가 착지했는지 먼저 본다 — 두 생성자의 68)"
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[java] 두 생성자 사이 필드의 여러 줄 람다는 두 생성자의 것 — exit 0 — 출력: $OUT"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:68 AuthClient.Token.<init>(char) · 4 lines · owner open-admin" "[java] 필드 줄을 가진 생성자들의 것이다"
# `this(…)` 를 안 부르는 생성자가 하나뿐일 때의 필드(필드 줄 68 이 Token(String) 의 줄표에만 있다 — Token(char) 는 `this(…)` 로 맡겨
# 필드 줄이 없다) 아래의 여러 줄 람다(69) — 필드 줄을 가진 그 생성자 하나의 것이다(4f84f539 는 함께 가진 줄이 없어 FAIL 했다).
fresh
sed -i 's#<method name="&lt;init&gt;" desc="(Ljava/lang/String;)V" line="62">#<method name="\&lt;init\&gt;" desc="(Ljava/lang/String;)V" line="65">#; s#<method name="&lt;init&gt;" desc="(C)V" line="62">#<method name="\&lt;init\&gt;" desc="(C)V" line="70">#; s#<method name="lambda$new$0" desc="()Ljava/lang/String;" line="62">#<method name="lambda$new$0" desc="()Ljava/lang/String;" line="69">#; s#<line nr="62" mi="3" ci="5" mb="0" cb="0"/>#<line nr="68" mi="3" ci="5" mb="0" cb="0"/>#' "$D/java.xml"
sed -i '/^  public kc.auth.AuthClient\$Token(java.lang.String);$/,/^      LocalVariableTable:$/ s/^        line 62: 4$/        line 68: 4/; /^  public kc.auth.AuthClient\$Token(char);$/,/^      LocalVariableTable:$/ { /^        line 62: 4$/d }; /^  private static java.lang.String lambda\$new\$0();$/,/^        line [0-9]*: / s/^        line 62: 0$/        line 69: 0/' "$D/java.javap.txt"
java_mark 0
assert_eq 0 "$(grep -c '^        line 62: ' "$D/java.javap.txt")" "(변이가 착지했는지 먼저 본다 — 62 가 줄표에서 다 빠졌다)"
assert_eq 1 "$(grep -c '^        line 68: 4$' "$D/java.javap.txt")" "(변이가 착지했는지 먼저 본다 — 필드 줄은 Token(String) 에만)"
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[java] 초기화를 끼워 넣는 생성자가 하나뿐인 필드의 여러 줄 람다는 그 생성자의 것 — exit 0 — 출력: $OUT"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:70 AuthClient.Token.<init>(char) · 3 lines · owner open-admin" "[java] this(…) 로 맡기는 생성자는 필드 람다를 안 가진다"
# `this(…)` 로 맡기는 생성자 몸통 안의 람다 — 필드 줄(62)을 혼자 가진 다른 생성자의 줄 범위(62–72)가 그 몸통을 덮어도, 생성자의
# 몸통은 바이트코드의 첫 · 끝 줄 사이다(독립 레그 6차 지적 — javac 가 내는 꼴: `int n = 1;` · `T(String s) { this(1); Runnable r = () -> {…}; }`
# · `T(int v) { n = v; }` — 두 범위에 들어 FAIL 했다). Token(String) 의 줄표에서 62 를 빼고 람다를 그 몸통(66)으로 옮겼다.
fresh
sed -i 's#<method name="&lt;init&gt;" desc="(Ljava/lang/String;)V" line="62">#<method name="\&lt;init\&gt;" desc="(Ljava/lang/String;)V" line="65">#; s#<method name="lambda$new$0" desc="()Ljava/lang/String;" line="62">#<method name="lambda$new$0" desc="()Ljava/lang/String;" line="66">#' "$D/java.xml"
sed -i '/^  public kc.auth.AuthClient\$Token(java.lang.String);$/,/^      LocalVariableTable:$/ { /^        line 62: 4$/d }; /^  private static java.lang.String lambda\$new\$0();$/,/^        line [0-9]*: / s/^        line 62: 0$/        line 66: 0/' "$D/java.javap.txt"
java_mark 0
assert_eq 1 "$(grep -c '^        line 62: ' "$D/java.javap.txt")" "(변이가 착지했는지 먼저 본다 — 62 는 Token(char) 에만)"
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[java] 맡기는 생성자 몸통 안 람다는 그 생성자의 것 — exit 0 — 출력: $OUT"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:62 AuthClient.Token.<init>(char) · 4 lines · owner open-admin" "[java] 혼자 가진 필드 줄은 그 생성자의 몸통 범위가 아니다"
# 짧은 매개변수 이름이 겹치는 오버로드(`token(java.lang.String)` · `token(kc.other.String)`) — 한 키로 합치면 안 돈 쪽이 사라진다(독립
# 레그 1차 지적). 그 멤버는 서술자 전체로 쓴다.
fresh
sed -i 's#<method name="token" desc="(Ljava/lang/String;I)Ljava/lang/String;" line="36">#<method name="token" desc="(Lkc/other/String;)Ljava/lang/String;" line="36">#' "$D/java.xml"
sed -i '/^  public java.lang.String token(java.lang.String, int);$/,/^    descriptor: / s|^    descriptor: (Ljava/lang/String;I)Ljava/lang/String;$|    descriptor: (Lkc/other/String;)Ljava/lang/String;|' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.javap.txt")" '    descriptor: (Lkc/other/String;)Ljava/lang/String;' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 1 "$RC" "[java] 짧은 이름이 겹치는 오버로드는 서술자 전체 키로 — 그 키에 소유자가 없어 exit 1 — 출력: $OUT"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:36 AuthClient.token(Lkc/other/String;)Ljava/lang/String; · 1 line · owner NONE" "[java] 짧은 이름이 겹치는 오버로드는 서술자 전체로 쓴다"
assert_not_contains "$OUT" "AuthClient.token(String) ·" "[java] 겹친 짧은 이름으로 한 함수로 합치지 않는다"
fresh
sed -i 's#<line nr="53" mi="5" ci="0" mb="0" cb="0"/>#<line nr="9999" mi="5" ci="0" mb="0" cb="0"/>#' "$D/java.xml"
java_mark 0
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 파일 밖 줄은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "the data counts line 9999, past the 85 lines of the file" "[java] 파일 밖 줄"
fresh
sed -i 's#<line nr="53" mi="5" ci="0" mb="0" cb="0"/>#<line nr="54" mi="5" ci="0" mb="0" cb="0"/>#' "$D/java.xml"
java_mark 0
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 어느 메서드도 안 가진 줄은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "the data counts line 54, which no method of the class facts owns" "[java] 메서드 밖 줄"
fresh
sed -i 's#<line nr="53" mi="5" ci="0" mb="0" cb="0"/>#<line nr="53" mi="5" ci="x" mb="0" cb="0"/>#' "$D/java.xml"
java_mark 0
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 숫자가 아닌 줄 횟수는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot read line 53 of AuthClient.java" "[java] 못 읽는 줄"
# 파생과 디스크가 갈렸다(파생 도구가 읽은 뒤 지워진 파일) — 가짜 파생 도구로 그 상태만 만든다(dotnet 과 같다).
fresh
printf '%s\n' 'console.log(JSON.stringify({ langs: { java: { dir: "java", site: "fake:1", label: "fake", universe: 3, files: ["java/kc-auth/src/main/java/kc/auth/AuthClient.java", "java/kc-examples/src/main/java/kc/examples/QuickStart.java"] } }, findings: [] }))' > "$T/scripts/coverage-boundary.mjs"
rm "$T/java/kc-auth/src/main/java/kc/auth/AuthClient.java"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 파생에 있되 디스크에 없는 경계 파일은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [java] java/kc-auth/src/main/java/kc/auth/AuthClient.java is derived but missing on disk — the data cannot be checked against it" "[java] 디스크에 없는 경계 파일"
# 메서드의 LINE 횟수가 수가 아니다.
fresh
sed -i 's#line="24"><counter type="INSTRUCTION" missed="0" covered="10"/><counter type="LINE" missed="0" covered="3"/>#line="24"><counter type="INSTRUCTION" missed="0" covered="10"/><counter type="LINE" missed="0" covered="x"/>#' "$D/java.xml"
java_mark 0
assert_contains "$(cat "$D/java.xml")" '<counter type="LINE" missed="0" covered="x"/>' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 못 읽는 메서드 LINE 횟수는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "kc/auth/AuthClient.names(Ljava/util/List;)Ljava/util/List; — the data and the class facts disagree" "[java] 메서드 횟수의 꼴"
# 데이터에 줄이 하나도 없는 함수(unused 의 53 을 데이터에서 뺐다)는 「한 줄도 안 돌았다」를 말할 수 없다 — 목록에 안 든다(그래서 그
# 소유자는 낡은 항목이 된다).
fresh
sed -i 's#<line nr="53" mi="5" ci="0" mb="0" cb="0"/>##' "$D/java.xml"
java_mark 0
assert_not_contains "$(cat "$D/java.xml")" '<line nr="53" ' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 1 "$RC" "[java] 데이터에 줄이 없는 함수의 소유자는 낡은 항목 — exit 1 — 출력: $OUT"
assert_not_contains "$OUT" "AuthClient.unused ·" "[java] 줄 없는 함수는 미실행 목록에 없다"
assert_contains "$OUT" "DRIFT [java] stale owner java/kc-auth/src/main/java/kc/auth/AuthClient.java:AuthClient.unused" "[java] 그 소유자는 낡았다"
# 빈 마디가 든 클래스 이름(`AuthClient$$1`) — 접지 않는다.
fresh
sed -i 's#<class name="kc/auth/AuthClient$1" sourcefilename="AuthClient.java">#<class name="kc/auth/AuthClient$$1" sourcefilename="AuthClient.java">#' "$D/java.xml"
sed -i 's|^\(  this_class: #[0-9]* *// kc/auth/AuthClient\)\$1$|\1$$1|' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.javap.txt")" '// kc/auth/AuthClient$$1' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 빈 마디가 든 클래스 이름은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name kc/auth/AuthClient\$\$1." "[java] 빈 마디"
# EnclosingMethod 의 클래스 색인이 Class 가 아니다(NameAndType #43) — 감싼 클래스를 못 푼다.
fresh
sed -i 's|^EnclosingMethod: #41\.#43 |EnclosingMethod: #43.#43 |' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.javap.txt")" 'EnclosingMethod: #43.#43 ' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 감싼 클래스를 못 푸는 익명 클래스는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name kc/auth/AuthClient\$1." "[java] 감싼 클래스 없음"
# EnclosingMethod 가 제 클래스를 가리킨다(#2 — 고리) — 따라 오르기를 멈춘다.
fresh
sed -i 's|^EnclosingMethod: #41\.#43 |EnclosingMethod: #2.#43  |' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.javap.txt")" 'EnclosingMethod: #2.#43 ' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 감싼 클래스가 고리를 이루면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name kc/auth/AuthClient\$1." "[java] 고리"
# 오버로드된 메서드 안의 익명 클래스 — EnclosingMethod 의 서술자로 그 오버로드에 접는다(줄로 가르면 가장 가까운 앞 줄 36 의
# token(String, int) 에 붙어 안 부른 그 오버로드가 목록에서 빠진다). 줄표의 EnclosingMethod 를 token(String) 으로 바꿨다.
fresh
sed -i 's|^  #43 = NameAndType        #44:#45        // sorted:(Ljava/util/List;)Ljava/util/List;$|&\n  #90 = NameAndType        #44:#45        // token:(Ljava/lang/String;)Ljava/lang/String;|; s|^EnclosingMethod: #41\.#43 |EnclosingMethod: #41.#90 |' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.javap.txt")" 'EnclosingMethod: #41.#90 ' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[java] 오버로드 안 익명 클래스는 서술자로 접힌다 — exit 0 — 출력: $OUT"
assert_line "$OUT" "  never executed by the integration run — 5 functions (none of its lines ran):" "[java] 익명 클래스가 다른 오버로드를 목록에서 안 뺀다"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:36 AuthClient.token(String, int) · 1 line · owner open-admin" "[java] 안 부른 오버로드는 그대로 목록에 있다"
# 오버로드된 메서드의 **람다 안** 익명 클래스 — 감싼 것이 람다라 서술자가 없다(EnclosingMethod 를 lambda$token$3 으로 바꿨다). 줄로
# 짐작하지 않는다 — 까닭은 서술자다(람다의 줄이 아니다).
fresh
sed -i 's|^  #43 = NameAndType        #44:#45        // sorted:(Ljava/util/List;)Ljava/util/List;$|&\n  #90 = NameAndType        #44:#45        // lambda$token$3:(Ljava/lang/String;I)Ljava/lang/String;|; s|^EnclosingMethod: #41\.#43 |EnclosingMethod: #41.#90 |' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.javap.txt")" '// lambda$token$3:(Ljava/lang/String;I)Ljava/lang/String;' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 오버로드의 람다 안 익명 클래스는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "AuthClient.token has overloads and a part attached by a descriptor (enclosing, creating or called method) that is none of theirs" "[java] 서술자로 못 붙는 부분"
# 안 부른 정적 람다 — 정적 초기화에 접혀 목록에 없고, 실릴 때 돈 그 줄(정적 초기화와 함께 가진 줄)은 몸통으로 안 덮였다.
fresh
sed -i 's#<method name="lambda$static$0" desc="(Ljava/lang/String;)Ljava/lang/String;" line="14"><counter type="INSTRUCTION" missed="0" covered="3"/><counter type="LINE" missed="0" covered="1"/>#<method name="lambda$static$0" desc="(Ljava/lang/String;)Ljava/lang/String;" line="14"><counter type="INSTRUCTION" missed="3" covered="0"/><counter type="LINE" missed="1" covered="0"/>#; s#<line nr="14" mi="0" ci="6" mb="0" cb="0"/>#<line nr="14" mi="3" ci="3" mb="0" cb="0"/>#' "$D/java.xml"
java_mark 0
assert_contains "$(cat "$D/java.xml")" '<line nr="14" mi="3" ci="3" mb="0" cb="0"/>' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[java] 안 부른 정적 람다는 정적 초기화에 접힌다 — exit 0 — 출력: $OUT"
assert_line "$OUT" "  java/kc-auth/src/main/java/kc/auth/AuthClient.java lines 22/27 81.5% · bodies 17/23 73.9%" "[java] 실릴 때 돈 정적 람다의 줄은 몸통으로 안 덮였다"
assert_line "$OUT" "  never executed by the integration run — 5 functions (none of its lines ran):" "[java] 정적 람다가 목록에 따로 들지 않는다"
# 이름에 `$` 가 든 메서드의 람다(`lambda$na$mes$1`) — 감싼 메서드를 이름으로 못 가른다.
fresh
sed -i 's#<method name="lambda$names$1" desc="(Ljava/util/List;Ljava/lang/String;)V" line="25">#<method name="lambda$na$mes$1" desc="(Ljava/util/List;Ljava/lang/String;)V" line="25">#' "$D/java.xml"
sed -i 's#^  private static void lambda\$names\$1(java.util.List, java.lang.String);$#  private static void lambda$na$mes$1(java.util.List, java.lang.String);#' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.javap.txt")" '  private static void lambda$na$mes$1(java.util.List, java.lang.String);' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 이름에 \$ 가 든 메서드의 람다는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name kc/auth/AuthClient.lambda\$na\$mes\$1(Ljava/util/List;Ljava/lang/String;)V" "[java] 감싼 메서드를 못 가르는 람다"
# 배열 · 중첩 타입 매개변수의 오버로드 이름 — `[]` 를 붙이고 `$` 를 `.` 으로 쓴다.
fresh
sed -i 's#<method name="token" desc="(Ljava/lang/String;I)Ljava/lang/String;" line="36">#<method name="token" desc="(Ljava/lang/String;[Lkc/auth/AuthClient$Mode;)Ljava/lang/String;" line="36">#' "$D/java.xml"
sed -i '/^  public java.lang.String token(java.lang.String, int);$/,/^    descriptor: / s|^    descriptor: (Ljava/lang/String;I)Ljava/lang/String;$|    descriptor: (Ljava/lang/String;[Lkc/auth/AuthClient$Mode;)Ljava/lang/String;|' "$D/java.javap.txt"
java_mark 0
assert_contains "$(cat "$D/java.javap.txt")" '    descriptor: (Ljava/lang/String;[Lkc/auth/AuthClient$Mode;)Ljava/lang/String;' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 1 "$RC" "[java] 이름이 바뀐 오버로드는 소유자가 없어 exit 1 — 출력: $OUT"
assert_line "$OUT" "  NEVER java/kc-auth/src/main/java/kc/auth/AuthClient.java:36 AuthClient.token(String, AuthClient.Mode[]) · 1 line · owner NONE" "[java] 배열은 [] · 중첩 타입은 점"
# 데이터가 클래스 사실에 없는 메서드를 댄다(unused 의 서술자를 데이터에서만 바꿨다) — 못 맞춘다(FAIL — 예외로 죽지 않는다).
fresh
sed -i 's#<method name="unused" desc="()Ljava/lang/String;" line="53">#<method name="unused" desc="()V" line="53">#' "$D/java.xml"
java_mark 0
assert_contains "$(cat "$D/java.xml")" '<method name="unused" desc="()V" line="53">' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 클래스 사실에 없는 데이터의 메서드는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "kc/auth/AuthClient.unused()V — the data and the class facts disagree (first line 53 vs no method)" "[java] 사실에 없는 메서드"
# 한 번도 안 실린 클래스(enum Mode)의 정적 초기화는 미실행 목록에 들지 않는다 — 실리지 않은 것은 「안 부른 함수」가 아니다.
fresh
sed -i 's#<method name="&lt;clinit&gt;" desc="()V" line="80"><counter type="INSTRUCTION" missed="0" covered="15"/><counter type="LINE" missed="0" covered="3"/>#<method name="\&lt;clinit\&gt;" desc="()V" line="80"><counter type="INSTRUCTION" missed="15" covered="0"/><counter type="LINE" missed="3" covered="0"/>#; s#<line nr="80" mi="0" ci="3" mb="0" cb="0"/>#<line nr="80" mi="3" ci="0" mb="0" cb="0"/>#; s#<line nr="81" mi="0" ci="6" mb="0" cb="0"/>#<line nr="81" mi="6" ci="0" mb="0" cb="0"/>#; s#<line nr="82" mi="0" ci="6" mb="0" cb="0"/>#<line nr="82" mi="6" ci="0" mb="0" cb="0"/>#' "$D/java.xml"
java_mark 0
assert_contains "$(cat "$D/java.xml")" '<line nr="82" mi="6" ci="0" mb="0" cb="0"/>' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[java] 안 실린 클래스의 정적 초기화는 미실행이 아니다 — exit 0 — 출력: $OUT"
assert_not_contains "$OUT" "Mode" "[java] 안 실린 enum 의 정적 초기화가 목록에 없다"
assert_line "$OUT" "  never executed by the integration run — 5 functions (none of its lines ran):" "[java] 미실행 수는 그대로"
# run 기록 — 이 데이터를 `run java` 가 썼고 그 실행이 성공했는가 · 그 실행이 IT 만 돌았는가 · 경계 파일이 그 실행의 바이트인가.
fresh
rm "$D/java.run.json"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] run 기록이 없으면 exit 2(손으로 돌린 실행) — 출력: $OUT"
assert_contains "$OUT" "no record that \`run java\` wrote this data" "[java] 기록 없음"
fresh
sed -i 's#"run":"java"#"run":"php"#' "$D/java.run.json"
assert_contains "$(cat "$D/java.run.json")" '"run":"php"' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 다른 레인이 쓴 꼴의 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "no record that \`run java\` wrote this data" "[java] 다른 레인의 기록"
fresh
java_mark 1
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 실패한 실행의 기록이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [java] the run that wrote this data exited 1 — the data of a failed run is partial" "[java] 실패 종료"
assert_not_contains "$OUT" "OK —" "[java] 실패한 실행은 수치를 내지 않는다"
fresh
sed -i 's#<sessioninfo id="HOST-00000000"#<sessioninfo id="HOST-00000001"#' "$D/java.xml"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 기록 뒤 바뀐 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/java.xml is not the data \`run java\` recorded" "[java] 기록과 다른 데이터"
fresh
sed -i 's#^  Last modified #  Last  modified #' "$D/java.javap.txt"
assert_contains "$(cat "$D/java.javap.txt")" '  Last  modified ' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 기록 뒤 바뀐 javap 출력은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "/java.javap.txt is not the javap output \`run java\` recorded" "[java] 기록과 다른 javap 출력"
fresh
sed -i 's#"tests":{[^}]*},##' "$D/java.run.json"
assert_not_contains "$(cat "$D/java.run.json")" '"tests"' "(변이가 착지했는지 먼저 본다)"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 테스트 수 없는 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "the record has no test counts" "[java] 테스트 수 없음"
fresh
sed -i 's#"completed":1#"completed":0#' "$D/java.run.json"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 통합 테스트가 0 이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [java] the run recorded no integration tests — a report over no tests is vacuous" "[java] 테스트 없음"
fresh
sed -i 's#"failures":0#"failures":1#' "$D/java.run.json"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 실패한 통합 테스트가 있으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [java] 1 of 1 integration tests failed — the data of a failed run is partial" "[java] 실패한 테스트"
# 오류(errors — 단언 밖 예외)로 끝난 테스트도 실패다(failsafe 는 둘을 따로 센다).
fresh
sed -i 's#"errors":0#"errors":1#' "$D/java.run.json"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 오류로 끝난 통합 테스트가 있으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [java] 1 of 1 integration tests failed — the data of a failed run is partial" "[java] 오류도 실패다"
# 단위 보고 수가 수가 아닌 기록 — 꼴부터 본다(`"0"` 은 참이라 「단위가 섞였다」로 새면 까닭이 틀린다).
fresh
sed -i 's#"unit":0#"unit":"0"#' "$D/java.run.json"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 단위 보고 수가 수가 아닌 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [java] the record has no test counts" "[java] 단위 보고 수의 꼴"
fresh
sed -i 's#"unit":0#"unit":2#' "$D/java.run.json"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 단위 테스트가 섞인 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [java] the run included 2 unit test reports — the report would not be integration-only" "[java] 단위 테스트가 섞였다"
fresh
sed -i 's#"files":{.*}}$#"files":null}#' "$D/java.run.json"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 경계 해시 없는 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "the record has no boundary hashes — the boundary files changed while the suite ran" "[java] 실행 중 바뀐 경계"
fresh
printf '// changed after the run\n' >> "$T/java/kc-auth/src/main/java/kc/auth/AuthClient.java"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 다른 바이트에서 난 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [java] java/kc-auth/src/main/java/kc/auth/AuthClient.java: the data was taken from other bytes" "[java] 해시 불일치"
# 겹친 결함 — 기록 판정은 다른 판정 뒤에 둘 뿐 그것에 가려지지 않는다(dotnet 과 같다).
fresh
sed -i 's#<line nr="53" mi="5" ci="0" mb="0" cb="0"/>#<line nr="54" mi="5" ci="0" mb="0" cb="0"/>#' "$D/java.xml"
rm "$D/java.run.json"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 데이터 결함과 기록 없음이 겹치면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "which no method of the class facts owns" "[java] 겹친 결함 — 데이터"
assert_contains "$OUT" "no record that \`run java\` wrote this data" "[java] 겹친 결함 — 기록 판정도 낸다"
assert_contains "$OUT" "FAIL — 2 integrity failures" "[java] 겹친 결함 — 둘을 센다"
fresh
sed -i '/AuthClient.java:AuthClient.unused/d' "$T/scripts/integration-coverage.json"
run report java "$T" --out "$D"
assert_eq 1 "$RC" "[java] 소유자 없는 미실행 함수는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [java] unowned never-executed function java/kc-auth/src/main/java/kc/auth/AuthClient.java:AuthClient.unused" "[java] 소유자 키"
# kotlin — 리더는 java 의 것이다(위 java 음성이 그 판정을 잰다). 여기서는 kotlin 에만 있는 갈래를 잰다: 기록의 모듈 이름 ·
# 코드로 접기(다리가 부르는 대상 · 람다를 만드는 메서드 · 로컬 함수를 부르는 메서드 · 익명 객체를 `new` 하는 메서드 — 못 찾거나
# 갈리면 FAIL) · 첫 줄의 소속 규칙 · kotlin 기록의 문구.
# 모듈 이름 — `internal` 의 접미를 벗기는 데 쓴다. 기록에 없거나 비었으면 데이터를 읽지 않는다.
fresh
sed -i 's#"module":"kc-kotlin",##' "$D/kotlin.run.json"
assert_not_contains "$(cat "$D/kotlin.run.json")" '"module"' "(변이가 착지했는지 먼저 본다)"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 모듈 이름 없는 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [kotlin] no Kotlin module name in " "[kotlin] 모듈 이름 없음"
fresh
sed -i 's#"module":"kc-kotlin"#"module":""#' "$D/kotlin.run.json"
assert_contains "$(cat "$D/kotlin.run.json")" '"module":""' "(변이가 착지했는지 먼저 본다)"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 빈 모듈 이름은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [kotlin] no Kotlin module name in " "[kotlin] 빈 모듈 이름"
# 다른 모듈 이름 — `mask$kc_kotlin` 의 접미가 안 벗겨져 이름을 못 붙인다(조용히 다른 이름으로 접지 않는다).
fresh
sed -i 's#"module":"kc-kotlin"#"module":"kc-other"#' "$D/kotlin.run.json"
assert_contains "$(cat "$D/kotlin.run.json")" '"module":"kc-other"' "(변이가 착지했는지 먼저 본다)"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 다른 모듈의 접미는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name kc/auth/AuthClient.mask\$kc_kotlin(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;" "[kotlin] 안 벗겨진 접미"
# 기록이 없거나 다른 레인의 것 — kotlin 은 모듈 이름 없이 데이터를 못 읽으므로 「기록 없음」만 낸다(java 는 데이터 판정도 함께 낸다).
fresh
rm "$D/kotlin.run.json"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] run 기록이 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "no record that \`run kotlin\` wrote this data" "[kotlin] 기록 없음 — 「모듈 이름 없음」이 아니다"
assert_not_contains "$OUT" "no Kotlin module name" "[kotlin] 기록 없음을 모듈 이름 탓으로 대지 않는다"
# java 가 쓴 꼴의 기록(모듈 이름이 없다) — 까닭은 「다른 레인의 기록」이지 「모듈 이름 없음」이 아니다.
fresh
sed -i 's#"run":"kotlin"#"run":"java"#; s#"module":"kc-kotlin",##' "$D/kotlin.run.json"
assert_contains "$(cat "$D/kotlin.run.json")" '"run":"java"' "(변이가 착지했는지 먼저 본다)"
assert_not_contains "$(cat "$D/kotlin.run.json")" '"module"' "(변이가 착지했는지 먼저 본다 — 모듈 이름)"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 다른 레인이 쓴 꼴의 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "no record that \`run kotlin\` wrote this data" "[kotlin] 다른 레인의 기록"
assert_not_contains "$OUT" "no Kotlin module name" "[kotlin] 다른 레인의 기록을 모듈 이름 탓으로 대지 않는다"
# 첫 줄 — kotlin 은 줄표의 가장 앞 줄이 아니라 줄표에 드는지를 본다(양성의 fetch: 데이터 29 · 줄표 {28, 29, 30}). 줄표 밖이면 FAIL.
fresh
sed -i 's#<method name="fetch" desc="(Ljava/lang/String;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;" line="29">#<method name="fetch" desc="(Ljava/lang/String;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;" line="31">#' "$D/kotlin.xml"
kotlin_mark 0
assert_contains "$(cat "$D/kotlin.xml")" 'Lkotlin/coroutines/Continuation;)Ljava/lang/Object;" line="31">' "(변이가 착지했는지 먼저 본다)"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 줄표 밖의 첫 줄은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "kc/auth/AuthClient.fetch(Ljava/lang/String;Lkotlin/coroutines/Continuation;)Ljava/lang/Object; — the data and the class facts disagree (first line 31 vs 28)" "[kotlin] 첫 줄 불일치"
# 기본 인자 다리는 **그것이 부르는 대상**의 것이다(서술자 셈이 아니다 — object 의 `@JvmStatic` 다리는 받는 쪽이 없어 셈이 틀린다,
# 양성의 pick). 다리를 `token$default` 로 바꾸고 그 코드가 token(String, int) 를 부르게 하면 그 오버로드의 것이다: 다리가 돌았으니
# (label() 을 불렀다) token(String, int) 는 미실행에서 빠지고 그 소유자는 낡는다.
fresh
sed -i 's#<method name="label\$default" #<method name="token$default" #' "$D/kotlin.xml"
sed -i 's#^  public static java.lang.String label\$default(#  public static java.lang.String token$default(#' "$D/kotlin.javap.txt"
sed -i '/^  public static java.lang.String token\$default(/,/^      LineNumberTable:$/ s#// Method label:(Ljava/lang/String;)Ljava/lang/String;$#// Method token:(Ljava/lang/String;I)Ljava/lang/String;#' "$D/kotlin.javap.txt"
kotlin_mark 0
assert_contains "$(sed -n '/^  public static java.lang.String token\$default(/,/^      LineNumberTable:$/p' "$D/kotlin.javap.txt")" '// Method token:(Ljava/lang/String;I)Ljava/lang/String;' "(변이가 착지했는지 먼저 본다)"
assert_contains "$(cat "$D/kotlin.xml")" '<method name="token$default" ' "(변이가 착지했는지 먼저 본다 — 데이터)"
run report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[kotlin] 다리가 돈 오버로드는 미실행이 아니다 — 낡은 소유자로 exit 1 — 출력: $OUT"
assert_line "$OUT" "  never executed by the integration run — 8 functions (none of its lines ran):" "[kotlin] 다리가 그 오버로드를 목록에서 뺀다"
assert_not_contains "$OUT" "NEVER kotlin/src/main/kotlin/kc/auth/AuthClient.kt:25 " "[kotlin] token(String, int) 가 목록에 없다"
assert_contains "$OUT" "DRIFT [kotlin] stale owner kotlin/src/main/kotlin/kc/auth/AuthClient.kt:AuthClient.token(String, int)" "[kotlin] 그 소유자는 낡았다"
# 이름이 같은 대상을 안 부르는 다리(`token$default` 가 label 을 부른다) — 접을 곳을 모른다(이름으로 짐작하지 않는다).
fresh
sed -i 's#<method name="label\$default" #<method name="token$default" #' "$D/kotlin.xml"
sed -i 's#^  public static java.lang.String label\$default(#  public static java.lang.String token$default(#' "$D/kotlin.javap.txt"
kotlin_mark 0
assert_contains "$(cat "$D/kotlin.javap.txt")" '  public static java.lang.String token$default(' "(변이가 착지했는지 먼저 본다)"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 대상을 안 부르는 다리는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name kc/auth/AuthClient.token\$default(Lkc/auth/AuthClient;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String; — the class files show no single method that creates, calls or encloses it" "[kotlin] 부르는 대상 없는 다리"
# 람다는 그것을 만드는 invokedynamic 의 메서드다 — 그런 메서드가 없으면(이름을 바꿔 부트스트랩 핸들과 어긋나게 했다) 접지 않는다.
fresh
sed -i 's#<method name="token\$lambda\$0" #<method name="tok$en$lambda$0" #' "$D/kotlin.xml"
sed -i 's#^  private static final java.lang.String token\$lambda\$0(kc.auth.AuthClient, java.lang.String);$#  private static final java.lang.String tok$en$lambda$0(kc.auth.AuthClient, java.lang.String);#' "$D/kotlin.javap.txt"
kotlin_mark 0
assert_contains "$(cat "$D/kotlin.javap.txt")" '  private static final java.lang.String tok$en$lambda$0(kc.auth.AuthClient, java.lang.String);' "(변이가 착지했는지 먼저 본다)"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 만드는 메서드가 없는 람다는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name kc/auth/AuthClient.tok\$en\$lambda\$0(" "[kotlin] 만드는 메서드 없음"
# 두 메서드가 같은 람다를 만들고 둘이 다른 멤버다(token(String) 의 invokedynamic 줄을 unused 에도 넣었다) — 한쪽을 고르지 않는다.
fresh
ind="$(sed -n '/^  public final java.lang.String token(java.lang.String);$/,/^      LineNumberTable:$/p' "$D/kotlin.javap.txt" | grep 'invokedynamic' | sed 's#^ *[0-9]*: #         0: #')"
sed -i "/^  public final java.lang.String unused();\$/,/^      LineNumberTable:\$/ s|^\(      stack=.*\)\$|\1\n$ind|" "$D/kotlin.javap.txt"
kotlin_mark 0
assert_eq 1 "$(sed -n '/^  public final java.lang.String unused();$/,/^      LineNumberTable:$/p' "$D/kotlin.javap.txt" | grep -c 'invokedynamic')" "(변이가 착지했는지 먼저 본다)"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 만드는 메서드 둘이 갈리는 람다는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name kc/auth/AuthClient.token\$lambda\$0(Lkc/auth/AuthClient;Ljava/lang/String;)Ljava/lang/String; — the class files show no single method that creates, calls or encloses it" "[kotlin] 갈리는 만드는 메서드"
# 로컬 함수는 그것을 부르는 메서드다 — 부르는 줄을 지우면 접을 곳이 없다.
fresh
sed -i '/^  public final java.lang.String withLocal();$/,/^      LineNumberTable:$/ { /invokestatic .*\/\/ Method withLocal\$inner:/d }' "$D/kotlin.javap.txt"
kotlin_mark 0
assert_not_contains "$(cat "$D/kotlin.javap.txt")" 'Method withLocal$inner:' "(변이가 착지했는지 먼저 본다)"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 부르는 메서드가 없는 로컬 함수는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name kc/auth/AuthClient.withLocal\$inner(Lkc/auth/AuthClient;Ljava/lang/String;)Ljava/lang/String;" "[kotlin] 부르는 메서드 없음"
# 감싼 메서드가 없는 익명 객체(EnclosingMethod 의 메서드 색인 0 — 속성 초기화 · init 블록의 꼴): 그것을 `new` 하는 메서드에 접는다.
# 픽스처의 `AuthClient$sorted$1` 을 그 꼴로 바꿨다 — `new` 는 sorted 안이라 sorted 에 접히고 목록은 그대로다.
fresh
sed -i 's|AuthClient\$sorted\$1|AuthClient$PLAIN$1|g' "$D/kotlin.xml" "$D/kotlin.javap.txt"
sed -i 's|^EnclosingMethod: #56\.#59 |EnclosingMethod: #56.#0  |' "$D/kotlin.javap.txt"
kotlin_mark 0
assert_contains "$(cat "$D/kotlin.javap.txt")" 'EnclosingMethod: #56.#0 ' "(변이가 착지했는지 먼저 본다)"
run report kotlin "$T" --out "$D"
assert_eq 0 "$RC" "[kotlin] 감싼 메서드 없는 익명 객체는 new 하는 메서드에 접힌다 — exit 0 — 출력: $OUT"
assert_line "$OUT" "  never executed by the integration run — 9 functions (none of its lines ran):" "[kotlin] 목록은 그대로"
assert_not_contains "$OUT" "PLAIN" "[kotlin] 익명 객체의 이름을 내지 않는다"
# 그 객체를 `new` 하는 메서드도 없다 — 접을 곳이 없다.
fresh
sed -i 's|AuthClient\$sorted\$1|AuthClient$1|g' "$D/kotlin.xml" "$D/kotlin.javap.txt"
sed -i 's|^EnclosingMethod: #56\.#59 |EnclosingMethod: #56.#0  |' "$D/kotlin.javap.txt"
sed -i '/^ *[0-9]*: new .*\/\/ class kc\/auth\/AuthClient\$1$/d' "$D/kotlin.javap.txt"
kotlin_mark 0
assert_contains "$(cat "$D/kotlin.javap.txt")" 'EnclosingMethod: #56.#0 ' "(변이가 착지했는지 먼저 본다)"
assert_eq 0 "$(grep -c ': new  *#[0-9]* .*// class kc/auth/AuthClient\$1$' "$D/kotlin.javap.txt")" "(변이가 착지했는지 먼저 본다 — new 줄)"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] new 하는 메서드도 없는 익명 클래스는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name kc/auth/AuthClient\$1.<init>()V" "[kotlin] 접을 곳 없음"
# 빈 마디가 든 클래스 이름(`AuthClient$$Local`) — 접지 않는다(java 와 같다).
fresh
sed -i 's|AuthClient\$withLocalClass\$Local|AuthClient$$Local|g' "$D/kotlin.xml" "$D/kotlin.javap.txt"
kotlin_mark 0
assert_contains "$(cat "$D/kotlin.javap.txt")" '// kc/auth/AuthClient$$Local' "(변이가 착지했는지 먼저 본다)"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 빈 마디가 든 클래스 이름은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "cannot name kc/auth/AuthClient\$\$Local." "[kotlin] 빈 마디"
# 이름에 `-` 가 든 메서드(값 클래스 맹글 `byId-tzrl3XM`)는 javap 머리에서 그대로 읽는다 — 양성이 그 이름을 지난다. 여기서는 그 함수를
# 안 부른 실행(데이터의 횟수를 0 으로)이 그 이름 그대로 미실행 목록에 드는지 본다.
fresh
sed -i 's#<method name="byId-tzrl3XM" desc="(Ljava/lang/String;)Ljava/lang/String;" line="131"><counter type="INSTRUCTION" missed="0" covered="\([0-9]*\)"/><counter type="LINE" missed="0" covered="1"/>#<method name="byId-tzrl3XM" desc="(Ljava/lang/String;)Ljava/lang/String;" line="131"><counter type="INSTRUCTION" missed="\1" covered="0"/><counter type="LINE" missed="1" covered="0"/>#; s#<method name="byId_tzrl3XM\$lambda\$0" desc="(Ljava/lang/String;)Ljava/lang/String;" line="131"><counter type="INSTRUCTION" missed="0" covered="\([0-9]*\)"/><counter type="LINE" missed="0" covered="1"/>#<method name="byId_tzrl3XM$lambda$0" desc="(Ljava/lang/String;)Ljava/lang/String;" line="131"><counter type="INSTRUCTION" missed="\1" covered="0"/><counter type="LINE" missed="1" covered="0"/>#' "$D/kotlin.xml"
kotlin_mark 0
assert_contains "$(cat "$D/kotlin.xml")" '<method name="byId-tzrl3XM" desc="(Ljava/lang/String;)Ljava/lang/String;" line="131"><counter type="INSTRUCTION" missed="' "(변이가 착지했는지 먼저 본다)"
assert_not_contains "$(cat "$D/kotlin.xml")" 'line="131"><counter type="INSTRUCTION" missed="0"' "(변이가 착지했는지 먼저 본다 — 둘 다 0 회)"
run report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[kotlin] 소유자 없는 값 클래스 함수는 exit 1 — 출력: $OUT"
assert_line "$OUT" "  NEVER kotlin/src/main/kotlin/kc/auth/AuthClient.kt:131 AuthClientKt.byId-tzrl3XM · 1 line · owner NONE" "[kotlin] 맹글된 이름 그대로 — 람다(byId_tzrl3XM\$lambda\$0)도 그 함수의 것"
# kotlin 기록의 문구 — 테스트 수는 JUnit XML 에서, 단위 테스트는 run 이 안 돌린다.
fresh
sed -i 's#"tests":{[^}]*},##' "$D/kotlin.run.json"
assert_not_contains "$(cat "$D/kotlin.run.json")" '"tests"' "(변이가 착지했는지 먼저 본다)"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 테스트 수 없는 기록은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [kotlin] the record has no test counts — run kotlin reads them from the JUnit XML of integrationTest and test" "[kotlin] 테스트 수의 출처"
fresh
sed -i 's#"unit":0#"unit":1#' "$D/kotlin.run.json"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 단위 테스트가 섞인 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [kotlin] the run included 1 unit test report — the report would not be integration-only (run runs integrationTest only)" "[kotlin] 단위 테스트가 섞였다"
fresh
printf '// changed after the run\n' >> "$T/kotlin/src/main/kotlin/kc/auth/AuthClient.kt"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 다른 바이트에서 난 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [kotlin] kotlin/src/main/kotlin/kc/auth/AuthClient.kt: the data was taken from other bytes" "[kotlin] 해시 불일치"
fresh
sed -i '/AuthClient.kt:AuthClient.unused/d' "$T/scripts/integration-coverage.json"
run report kotlin "$T" --out "$D"
assert_eq 1 "$RC" "[kotlin] 소유자 없는 미실행 함수는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [kotlin] unowned never-executed function kotlin/src/main/kotlin/kc/auth/AuthClient.kt:AuthClient.unused" "[kotlin] 소유자 키"

# ── (2) 음성: 소유자(exit 1 — 경고, 게이트가 아니다)─────────────────────────────────────────
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
# node — 구동기가 경계 밖만 불렀다(통합 테스트가 경계를 안 지나고 통과한 꼴).
fresh
node_data "$FIX/data/node-zero.json"
run report node "$T" --out "$D"
assert_eq 2 "$RC" "[node] 경계 문장을 하나도 안 돈 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [node] the run executed 0 of 34 boundary statements — a measurement failure, not a low number" "[node] 측정 실패 문구"
assert_not_contains "$OUT" "0.0%" "[node] 측정 실패에서 0% 를 내지 않는다"
# rust — 경계 모듈이 링크는 됐지만 아무것도 안 불렸다(링크조차 안 되면 위 「데이터에 없음」 FAIL 이다).
fresh
rust_data "$FIX/data/rust-zero.lcov"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 경계 줄을 하나도 안 돈 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] the run executed 0 of 138 boundary lines — a measurement failure, not a low number" "[rust] 측정 실패 문구"
assert_not_contains "$OUT" "0.0%" "[rust] 측정 실패에서 0% 를 내지 않는다"
# php — 구동기가 경계를 하나도 안 불렀다. 파일을 싣는 것만으로는 줄이 안 덮인다(실행 가능 줄은 정적 분석이 정한다).
fresh
php_data "$FIX/data/php-zero"
run report php "$T" --out "$D"
assert_eq 2 "$RC" "[php] 경계 줄을 하나도 안 돈 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [php] the run executed 0 of 22 boundary lines — a measurement failure, not a low number" "[php] 측정 실패 문구"
assert_not_contains "$OUT" "0.0%" "[php] 측정 실패에서 0% 를 내지 않는다"
# ruby — 구동 스펙이 경계를 하나도 안 불렀다. require 가 클래스 · def 줄을 돌아 lines 는 0 이 아니다 — 몸통으로 판정한다.
fresh
ruby_data "$FIX/data/ruby-zero.json"
run report ruby "$T" --out "$D"
assert_eq 2 "$RC" "[ruby] 경계 메서드를 하나도 안 돈 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [ruby] the run executed 0 of 12 boundary lines inside methods — a measurement failure, not a low number (require alone credits" "[ruby] require 크레딧을 수치로 내지 않는다"
assert_not_contains "$OUT" "0.0%" "[ruby] 측정 실패에서 0% 를 내지 않는다"
# dotnet — 구동 테스트가 경계를 하나도 안 불렀다(경계 밖 Config 만). coverlet 은 계측한 모듈의 메서드를 0 회로도 싣는다.
fresh
dotnet_data "$FIX/data/dotnet-zero.json" "$FIX/data/dotnet-zero.trx"
run report dotnet "$T" --out "$D"
assert_eq 2 "$RC" "[dotnet] 경계 줄을 하나도 안 돈 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [dotnet] the run executed 0 of 84 boundary lines — a measurement failure, not a low number" "[dotnet] 측정 실패 문구"
assert_not_contains "$OUT" "0.0%" "[dotnet] 측정 실패에서 0% 를 내지 않는다"
# java — 구동 테스트가 경계 클래스를 싣기만 했다(KC_FIXTURE_ZERO=1 — 정적 초기화만 돈다). lines 는 0 이 아니지만 몸통은 0 이다 — 정적
# 람다(UPPER)의 줄도 실릴 때 덮이지만 람다가 안 불렸으니 몸통으로는 안 덮였다(메서드의 LINE covered 로 가른다).
fresh
java_data "$FIX/data/java-zero.xml"
run report java "$T" --out "$D"
assert_eq 2 "$RC" "[java] 경계 클래스를 싣기만 한 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [java] the run executed 0 of 27 boundary lines outside static initializers — a measurement failure, not a low number (class loading alone credits 2 static-initializer lines)" "[java] 정적 초기화만 돈 실행"
assert_not_contains "$OUT" "OK —" "[java] 측정 실패에서 수치를 내지 않는다"
# kotlin — 같은 꼴(KC_FIXTURE_ZERO=1 — AuthClient 만 싣는다). Companion 속성 REALM · UPPER 의 초기화가 바깥 클래스의 정적 초기화에서 돈다.
fresh
kotlin_data "$FIX/data/kotlin-zero.xml"
run report kotlin "$T" --out "$D"
assert_eq 2 "$RC" "[kotlin] 경계 클래스를 싣기만 한 실행은 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [kotlin] the run executed 0 of 51 boundary lines outside static initializers — a measurement failure, not a low number (class loading alone credits 2 static-initializer lines)" "[kotlin] 정적 초기화만 돈 실행"
assert_not_contains "$OUT" "OK —" "[kotlin] 측정 실패에서 수치를 내지 않는다"
# 빈 파생 + 빈 핀 — 집합은 같으므로(∅ = ∅) 빈 집합 판정만이 잡는다. 파생 도구를 가짜로 바꿔 그 갈래만 태운다.
# ⚠️ 두 언어 다 「있되 비었다」여야 한다 — 한 언어를 빼 두면 check 의 exit 2 가 그 「없는 파생」에서 와서 빈 집합
# 갈래를 지워도 초록이었다(변이 실측: 빈 집합 통과 변이에 check 단언이 침묵했다).
fresh
printf '%s\n' 'const e = (d) => ({ dir: d, site: "fake:1", label: "fake", universe: 3, files: [] })' 'console.log(JSON.stringify({ langs: { go: e("go"), python: e("python"), node: e("node"), rust: e("rust"), php: e("php"), ruby: e("ruby"), dotnet: e("dotnet"), java: e("java"), kotlin: e("kotlin") }, findings: [] }))' > "$T/scripts/coverage-boundary.mjs"
printf '%s\n' '{ "go": { "pinned": [], "owners": {} }, "python": { "pinned": [], "owners": {} }, "node": { "pinned": [], "owners": {} }, "rust": { "pinned": [], "owners": {} }, "php": { "pinned": [], "owners": {} }, "ruby": { "pinned": [], "owners": {} }, "dotnet": { "pinned": [], "owners": {} }, "java": { "pinned": [], "owners": {} }, "kotlin": { "pinned": [], "owners": {} } }' > "$T/scripts/integration-coverage.json"
run check "$T"
assert_eq 2 "$RC" "[check] 빈 파생은 exit 2(빈 핀과 같아도) — 출력: $OUT"
assert_contains "$OUT" "FAIL [python] the derived boundary is empty" "[check] python 도 빈 파생"
assert_contains "$OUT" "FAIL [node] the derived boundary is empty" "[check] node 도 빈 파생"
assert_contains "$OUT" "FAIL [rust] the derived boundary is empty" "[check] rust 도 빈 파생"
assert_contains "$OUT" "FAIL [php] the derived boundary is empty" "[check] php 도 빈 파생"
assert_contains "$OUT" "FAIL [ruby] the derived boundary is empty" "[check] ruby 도 빈 파생"
assert_contains "$OUT" "FAIL [dotnet] the derived boundary is empty" "[check] dotnet 도 빈 파생"
assert_contains "$OUT" "FAIL [java] the derived boundary is empty" "[check] java 도 빈 파생"
assert_contains "$OUT" "FAIL [kotlin] the derived boundary is empty" "[check] kotlin 도 빈 파생"
assert_not_contains "$OUT" "returned no derivation" "[check] 언어마다 있되 비었다 — 「없는 파생」이 빈 집합 갈래를 가리지 않는다"
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
printf '%s\n' '{ "go": { "pinned": ["go/admin.go"], "owners": {} }, "scala": { "pinned": [], "owners": {} } }' > "$T/scripts/integration-coverage.json"
run check "$T"
assert_eq 2 "$RC" "파일럿이 안 재는 언어를 핀에 넣으면 exit 2"
assert_contains "$OUT" "FAIL [-] scripts/integration-coverage.json names scala, which this pilot does not measure" "모르는 언어"
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
run report scala "$T" --out "$D"
assert_eq 2 "$RC" "파일럿이 안 재는 언어는 usage(exit 2)"
assert_contains "$OUT" "this pilot measures go · python · node · rust · php · ruby · dotnet · java · kotlin — got scala" "usage 문구"

# ── (4) 하한(4 걸음째 — 2026-11-02 무장) ─────────────────────────────────────────────────────────
# 픽스처 핀에는 하한이 없다(위 단언들은 하한 없는 리포트다). 여기서만 주입한다.
# 픽스처 수치: go 10/22 = 45.45% · python lines 21/28 = 75.00% · bodies 8/13 = 61.54%.
floor() { # <lang> <metric> <percent>
  sed -i "s|^  \"$1\": {\$|  \"$1\": {\n    \"floor\": { \"metric\": \"$2\", \"percent\": $3 },|" "$T/scripts/integration-coverage.json"
  assert_contains "$(cat "$T/scripts/integration-coverage.json")" "\"metric\": \"$2\", \"percent\": $3" "(하한 주입이 착지했는지 먼저 본다)"
}
fresh; floor go statements 45
run report go "$T" --out "$D"
assert_eq 0 "$RC" "[floor] go 45.45% ≥ 45 — 출력: $OUT"
assert_line "$OUT" "integration-coverage [go]: OK — 10/22 statements (45.5%) · floor statements ≥ 45% · 4 never-executed functions, all owned by open registry items" "[floor] 통과 요약에 하한을 함께 적는다"
assert_contains "$OUT" "[go] integration-only coverage — floor statements ≥ 45%" "[floor] 머리줄"

fresh; floor go statements 46
run report go "$T" --out "$D"
assert_eq 3 "$RC" "[floor] go 45.45% < 46 은 BELOW(exit 3) — 출력: $OUT"
assert_line "$OUT" "integration-coverage [go]: BELOW — 10/22 statements (45.5%) · floor statements ≥ 46% · 4 never-executed functions, all owned by open registry items" "[floor] BELOW 요약"

# 같은 값은 통과다(≥) — 75% 를 정확히 가진 lines 로. 비교는 정수식이다(부동소수 반올림으로 갈리지 않는다).
fresh; floor python lines 75
run report python "$T" --out "$D"
assert_eq 0 "$RC" "[floor] python lines 75.00% ≥ 75 — 출력: $OUT"
fresh; floor python lines 75.01
run report python "$T" --out "$D"
assert_eq 3 "$RC" "[floor] python lines 75.00% < 75.01 — 출력: $OUT"

# 지표가 판정을 가른다 — bodies 61.54% 는 62 아래, 같은 실행의 lines 75% 는 위다.
fresh; floor python bodies 62
run report python "$T" --out "$D"
assert_eq 3 "$RC" "[floor] python bodies 61.54% < 62 — lines 가 아니라 bodies 로 잰다 — 출력: $OUT"
assert_contains "$OUT" "floor bodies ≥ 62%" "[floor] python 하한 지표 표기"

# 잘못 적은 하한은 무결성 실패(exit 2) — 조용히 무시하면 하한이 꺼진 줄 모른다.
fresh; floor go bodies 40
run check "$T"
assert_eq 2 "$RC" "[floor] go 에 bodies 는 없다 — 출력: $OUT"
assert_contains "$OUT" "go.floor.metric" "[floor] 지표 오류를 지목한다"
fresh; floor python bodies 0
run check "$T"
assert_eq 2 "$RC" "[floor] 0% 하한은 하한이 아니다 — 출력: $OUT"
fresh; floor python bodies 101
run check "$T"
assert_eq 2 "$RC" "[floor] 100% 초과 — 출력: $OUT"
fresh; floor go statements 40
run check "$T"
assert_eq 0 "$RC" "[floor] 올바른 하한은 check 를 통과한다 — 출력: $OUT"
assert_line "$OUT" "[go] floor: statements ≥ 40%" "[floor] check 가 하한을 보여 준다"

# node 도 같은 하한 판정을 탄다(지표는 statements — 픽스처 21/34 = 61.76%).
fresh; floor node statements 61.76
run report node "$T" --out "$D"
assert_eq 0 "$RC" "[floor] node 61.76% ≥ 61.76 — 출력: $OUT"
fresh; floor node statements 61.77
run report node "$T" --out "$D"
assert_eq 3 "$RC" "[floor] node 61.76% < 61.77 — 출력: $OUT"
fresh; floor node bodies 50
run check "$T"
assert_eq 2 "$RC" "[floor] node 에 bodies 는 없다 — 출력: $OUT"
assert_contains "$OUT" "node.floor.metric" "[floor] node 지표 오류를 지목한다"

# rust 의 지표는 lines(고유 줄 — 픽스처 116/159 = 72.956%).
fresh; floor rust lines 72.95
run report rust "$T" --out "$D"
assert_eq 0 "$RC" "[floor] rust 72.956% ≥ 72.95 — 출력: $OUT"
assert_line "$OUT" "integration-coverage [rust]: OK — 116/159 lines (73.0%) · floor lines ≥ 72.95% · 19 never-executed functions, all owned by open registry items" "[floor] rust 통과 요약"
fresh; floor rust lines 72.96
run report rust "$T" --out "$D"
assert_eq 3 "$RC" "[floor] rust 72.956% < 72.96 — 출력: $OUT"
fresh; floor rust statements 50
run check "$T"
assert_eq 2 "$RC" "[floor] rust 에 statements 는 없다(지표는 lines) — 출력: $OUT"
assert_contains "$OUT" "rust.floor.metric" "[floor] rust 지표 오류를 지목한다"

# php 의 지표도 lines(php-code-coverage 의 실행 가능 줄 — 픽스처 16/22 = 72.727%).
fresh; floor php lines 72.72
run report php "$T" --out "$D"
assert_eq 0 "$RC" "[floor] php 72.727% ≥ 72.72 — 출력: $OUT"
assert_line "$OUT" "integration-coverage [php]: OK — 16/22 lines (72.7%) · floor lines ≥ 72.72% · 4 never-executed functions, all owned by open registry items" "[floor] php 통과 요약"
fresh; floor php lines 72.73
run report php "$T" --out "$D"
assert_eq 3 "$RC" "[floor] php 72.727% < 72.73 — 출력: $OUT"
fresh; floor php statements 50
run check "$T"
assert_eq 2 "$RC" "[floor] php 에 statements 는 없다(지표는 lines) — 출력: $OUT"
assert_contains "$OUT" "php.floor.metric" "[floor] php 지표 오류를 지목한다"
# ruby 는 python 처럼 lines(픽스처 24/28 = 85.714%) · bodies(6/12 = 50%)를 갈라 건다.
fresh; floor ruby bodies 50
run report ruby "$T" --out "$D"
assert_eq 0 "$RC" "[floor] ruby bodies 50% ≥ 50 — 출력: $OUT"
assert_line "$OUT" "integration-coverage [ruby]: OK — lines 24/28 (85.7%) · bodies 6/12 (50.0%) · floor bodies ≥ 50% · 5 never-executed functions, all owned by open registry items" "[floor] ruby 통과 요약"
fresh; floor ruby bodies 50.01
run report ruby "$T" --out "$D"
assert_eq 3 "$RC" "[floor] ruby bodies 50% < 50.01 — 출력: $OUT"
fresh; floor ruby lines 85.71
run report ruby "$T" --out "$D"
assert_eq 0 "$RC" "[floor] ruby lines 85.714% ≥ 85.71 — 출력: $OUT"
fresh; floor ruby lines 85.72
run report ruby "$T" --out "$D"
assert_eq 3 "$RC" "[floor] ruby lines 85.714% < 85.72 — 지표가 bodies 로 새지 않는다 — 출력: $OUT"
fresh; floor ruby statements 50
run check "$T"
assert_eq 2 "$RC" "[floor] ruby 에 statements 는 없다(지표는 lines · bodies) — 출력: $OUT"
assert_contains "$OUT" "ruby.floor.metric" "[floor] ruby 지표 오류를 지목한다"
# dotnet 은 줄(픽스처 45/84 = 53.571%)이다.
fresh; floor dotnet lines 53.5
run report dotnet "$T" --out "$D"
assert_eq 0 "$RC" "[floor] dotnet lines 53.571% ≥ 53.5 — 출력: $OUT"
assert_line "$OUT" "integration-coverage [dotnet]: OK — 45/84 lines (53.6%) · floor lines ≥ 53.5% · 13 never-executed functions, all owned by open registry items" "[floor] dotnet 통과 요약"
fresh; floor dotnet lines 53.58
run report dotnet "$T" --out "$D"
assert_eq 3 "$RC" "[floor] dotnet lines 53.571% < 53.58 — 출력: $OUT"
fresh; floor dotnet bodies 50
run check "$T"
assert_eq 2 "$RC" "[floor] dotnet 에 bodies 는 없다(지표는 lines) — 출력: $OUT"
assert_contains "$OUT" "dotnet.floor.metric" "[floor] dotnet 지표 오류를 지목한다"
# java 는 lines(픽스처 22/31 = 70.968%) · bodies(18/27 = 66.667%)다.
fresh; floor java bodies 66.6
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[floor] java bodies 66.667% ≥ 66.6 — 출력: $OUT"
assert_line "$OUT" "integration-coverage [java]: OK — lines 22/31 (71.0%) · bodies 18/27 (66.7%) · floor bodies ≥ 66.6% · 5 never-executed functions, all owned by open registry items" "[floor] java 통과 요약"
fresh; floor java bodies 66.67
run report java "$T" --out "$D"
assert_eq 3 "$RC" "[floor] java bodies 66.667% < 66.67 — 출력: $OUT"
fresh; floor java lines 70.97
run report java "$T" --out "$D"
assert_eq 3 "$RC" "[floor] java lines 70.968% < 70.97 — 찍힌 71.0% 가 아니라 식이 가른다 — 출력: $OUT"
fresh; floor java statements 50
run check "$T"
assert_eq 2 "$RC" "[floor] java 에 statements 는 없다(지표는 lines · bodies) — 출력: $OUT"
assert_contains "$OUT" "java.floor.metric" "[floor] java 지표 오류를 지목한다"
# kotlin 도 lines(픽스처 37/53 = 69.811%) · bodies(34/51 = 66.667%)다.
fresh; floor kotlin bodies 66.66
run report kotlin "$T" --out "$D"
assert_eq 0 "$RC" "[floor] kotlin bodies 66.667% ≥ 66.66 — 출력: $OUT"
assert_line "$OUT" "integration-coverage [kotlin]: OK — lines 37/53 (69.8%) · bodies 34/51 (66.7%) · floor bodies ≥ 66.66% · 9 never-executed functions, all owned by open registry items" "[floor] kotlin 통과 요약"
fresh; floor kotlin bodies 66.67
run report kotlin "$T" --out "$D"
assert_eq 3 "$RC" "[floor] kotlin bodies 66.667% < 66.67 — 찍힌 66.7% 가 아니라 식이 가른다 — 출력: $OUT"
fresh; floor kotlin lines 69.81
run report kotlin "$T" --out "$D"
assert_eq 0 "$RC" "[floor] kotlin lines 69.811% ≥ 69.81 — 지표가 bodies(66.667%)로 새지 않는다 — 출력: $OUT"
fresh; floor kotlin lines 69.82
run report kotlin "$T" --out "$D"
assert_eq 3 "$RC" "[floor] kotlin lines 69.811% < 69.82 — 출력: $OUT"
fresh; floor kotlin statements 50
run check "$T"
assert_eq 2 "$RC" "[floor] kotlin 에 statements 는 없다(지표는 lines · bodies) — 출력: $OUT"
assert_contains "$OUT" "kotlin.floor.metric" "[floor] kotlin 지표 오류를 지목한다"

# 소유 문제와 하한 미달이 겹치면 게이트(3)가 경고(1)를 이긴다 — 경고는 그대로 찍는다.
fresh; floor go statements 46
sed -i '/AdminClient.Close/d' "$T/scripts/integration-coverage.json"
run report go "$T" --out "$D"
assert_eq 3 "$RC" "[floor] DRIFT + BELOW 는 3 — 출력: $OUT"
assert_contains "$OUT" "unowned never-executed function go/admin.go:AdminClient.Close" "[floor] 소유 문제도 함께 찍는다"

assert_report
