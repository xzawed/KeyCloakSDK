#!/usr/bin/env sh
# 통합 전용 커버리지 리포트(`scripts/integration-coverage.mjs`) 자가테스트 — go · python · node · rust 의 무결성 판정과 하한.
#
# ⚠️ **커밋된 픽스처만 쓴다** — Docker 도 Go·Python·node·rust 툴체인도 필요 없다. 실제 Keycloak 에 대고 도는 것은
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
#   data/rust.lcov         cargo-llvm-cov 0.8.7(rustc 1.89.0)의 `--test drive --lcov`(2026-11-05) — 임시 크레이트에
#                          tree/rust/src 사본 + 구동 테스트. **SF 의 생성 루트만 `@ROOT@\rust\` 로 바꿨다**(윈도의 `\` 그대로)
#   data/rust-zero.lcov    같은 명령, 구동기가 경계 함수의 포인터만 잡고(링크는 되고) 아무것도 안 부른다 — 포인터가 없으면
#                          경계 세 파일이 데이터에서 **통째로 빠진다**(참조 안 된 모듈의 오브젝트는 링크되지 않는다)
#   data/rust-unit.lcov    `--lib --test drive` — 단위 테스트가 같은 빌드에서 돌아 `#[cfg(test)]` 와 `#[cfg(all(test,
#                          debug_assertions))]` 함수의 레코드가 든다
# 구동기는 「String·Close·Delete·AuthClient.String·hook 리터럴」과 「__repr__·logout·clients·aio 전체」를, node 는
# 「describe·toString·[SYM]·inc·cb·set count·overload·longSignature·close」를, rust 는 「transport·supply·describe·noop·close·
# Display::fmt·Wrapper<u16>::get·admin·unused_count」를 일부러 안 부르고 `delete_user` 의 퓨처는 만들기만 하고 버린다(rust 의
# `unused_helper` · 제네릭 `From::from` 은 아무도 참조하지 않아, `platform` 의 `not(windows)` 쌍둥이는 생성한 윈도에서 컴파일되지
# 않아 데이터에 레코드가 없다). 숫자를 바꾸려면 구동기를 다시 써서 **도구로 재생성**할 것 — 데이터를 손으로 고치지 않는다.
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
assert_line "$OUT" "integration-coverage check: OK — go 3 · python 3 · node 2 · rust 3 files pinned · 33 owner entries, all open" "[check] 요약"

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
# 같은 데이터의 LF 합 142 는 async fn 의 바깥 함수·몸통이 같은 줄을 두 번 센 것이다. 각 줄이 재는 것: 중첩 블록 주석 ·
# 원시 문자열 · 여러 줄 문자열 속 `fn …{`·`    }` 가 항목을 열고 닫지 않는다 · 문자 리터럴 `'"'`·`'{'` 와 수명 `'a` ·
# 빈 몸통 한 줄 fn · 같은 타입의 `Debug::fmt`/`Display::fmt` 와 `Wrapper<u8>`/`Wrapper<u16>` 이 갈린다 · 레코드 없는 함수
# (아무도 참조 안 한 fn · 인스턴스화 안 된 제네릭 · 이 빌드에서 cfg 로 빠진 쌍둥이)도 미실행이다 · 퓨처만 만들고 버린 async fn
# 은 미실행이다(바깥 함수는 돌았다) · static 의 클로저는 그 static 의 범위다(GREETING 은 돌았다) · 비ASCII 이름(`größe`) ·
# `#[cfg(test)]` 와 `#[cfg(all(test, debug_assertions))]` 모듈은 읽지 않는다(읽으면 그 함수들이 레코드 없는 미실행으로 든다).
run report rust "$T" --out "$D"
assert_eq 0 "$RC" "[rust] 건강한 리포트는 exit 0 — 출력: $OUT"
assert_line "$OUT" "  rust/src/admin.rs 34/39 87.2%" "[rust] admin.rs — 열 4 의 } 를 품은 최상위 fn · async 메서드 · 트레이트 impl 의 async fn"
assert_line "$OUT" "  rust/src/auth.rs 51/69 73.9%" "[rust] auth.rs — 범위 밖 줄이 없다(module-level 이 안 찍힌다)"
assert_line "$OUT" "  rust/src/client.rs 21/28 75.0%" "[rust] client.rs — static 클로저 줄은 그 static 의 범위다(모듈 수준이 아니다)"
assert_line "$OUT" "  total 106/136 77.9%" "[rust] 합계는 경계 파일만(config.rs · lib.rs 제외) — LF 합(142)이 아니라 고유 줄"
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
assert_line "$OUT" "  NEVER rust/src/client.rs:47 platform #[cfg(not(windows))] · no record in the data · owner open-admin" "[rust] cfg 쌍둥이는 이름에 cfg 가 붙어 갈린다 — 컴파일 안 된 쪽은 레코드가 없다"
for _x in hidden doc_fake raw_fake string_fake tests:: "platform #[cfg(windows)]" exchange_rejects_empty AuthClient::new AuthClient::realm AuthClient::exchange AuthClient::apply "AuthClient::token ·" fmt::Debug token_twice token_now "Wrapper<u8>" " helper ·" inner:: nested_level encode AdminClient::send get_user search_users KeycloakClient::new KeycloakClient::auth config.rs lib.rs module-level debug_tests "static GREETING" "static UNUSED" "const BANNER" größe; do
  assert_not_contains "$OUT" "$_x" "[rust] 실행된 함수 · 경계 밖 · 주석·문자열 속 이름 · cfg(test) · 코드 없는 상수는 목록에 없다: $_x"
done
assert_line "$OUT" "integration-coverage [rust]: OK — 106/136 lines (77.9%) · 13 never-executed functions, all owned by open registry items" "[rust] 요약"

# Linux 의 llvm-cov 는 SF 를 `/` 로 쓴다 — 윈도에서 만든 `\` 와 같은 리포트여야 한다.
fresh
sed -i '/^SF:/s#\\#/#g' "$D/rust.lcov"
assert_contains "$(cat "$D/rust.lcov")" "/rust/src/auth.rs" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 0 "$RC" "[rust] / 경로도 같은 파일이다 — 출력: $OUT"
assert_line "$OUT" "  total 106/136 77.9%" "[rust] / 경로에서도 같은 합계"
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

# 다른 언어의 파생 실패가 이 언어의 리포트를 막지 않는다(픽스처에는 여섯 언어가 없어 그쪽은 늘 FAIL 이다).
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
assert_contains "$OUT" "FAIL [rust] rust/src/client.rs: the data counts line 400, past the end of the file (62 lines)" "[rust] 다른 체크아웃"
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
assert_contains "$OUT" "FAIL [rust] rust/src/client.rs:58: the data has a function inside an item compiled only with cfg(test) (" "[rust] all(test, …) 자리도 댄다"
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
sed -i '/^SF:.*auth\.rs$/a FN:116,_RNvfake_macro_generated' "$D/rust.lcov"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] macro_rules! 안의 함수 레코드는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "FAIL [rust] rust/src/auth.rs:116: the data has a function (_RNvfake_macro_generated) inside macro_rules! twice" "[rust] 매크로를 댄다"
# 함수 레코드 없이 낸 데이터(`cargo llvm-cov --skip-functions`) — 줄은 돌았는데 모든 함수가 「레코드 없음」이 된다(독립 레그 실측).
fresh
sed -i '/^FN:/d' "$D/rust.lcov"
assert_not_contains "$(cat "$D/rust.lcov")" "FN:" "(변이가 착지했는지 먼저 본다)"
run report rust "$T" --out "$D"
assert_eq 2 "$RC" "[rust] 함수 레코드 없는 데이터는 exit 2 — 출력: $OUT"
assert_contains "$OUT" "but has no function record there — a report without function records" "[rust] 레코드 없는 줄을 댄다"
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

# ── (2) 음성: 소유자(exit 1 — 경고, 게이트가 아니다) ─────────────────────────────────────────
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
assert_contains "$OUT" "FAIL [rust] the run executed 0 of 116 boundary lines — a measurement failure, not a low number" "[rust] 측정 실패 문구"
assert_not_contains "$OUT" "0.0%" "[rust] 측정 실패에서 0% 를 내지 않는다"
# 빈 파생 + 빈 핀 — 집합은 같으므로(∅ = ∅) 빈 집합 판정만이 잡는다. 파생 도구를 가짜로 바꿔 그 갈래만 태운다.
# ⚠️ 두 언어 다 「있되 비었다」여야 한다 — 한 언어를 빼 두면 check 의 exit 2 가 그 「없는 파생」에서 와서 빈 집합
# 갈래를 지워도 초록이었다(변이 실측: 빈 집합 통과 변이에 check 단언이 침묵했다).
fresh
printf '%s\n' 'const e = (d) => ({ dir: d, site: "fake:1", label: "fake", universe: 3, files: [] })' 'console.log(JSON.stringify({ langs: { go: e("go"), python: e("python"), node: e("node"), rust: e("rust") }, findings: [] }))' > "$T/scripts/coverage-boundary.mjs"
printf '%s\n' '{ "go": { "pinned": [], "owners": {} }, "python": { "pinned": [], "owners": {} }, "node": { "pinned": [], "owners": {} }, "rust": { "pinned": [], "owners": {} } }' > "$T/scripts/integration-coverage.json"
run check "$T"
assert_eq 2 "$RC" "[check] 빈 파생은 exit 2(빈 핀과 같아도) — 출력: $OUT"
assert_contains "$OUT" "FAIL [python] the derived boundary is empty" "[check] python 도 빈 파생"
assert_contains "$OUT" "FAIL [node] the derived boundary is empty" "[check] node 도 빈 파생"
assert_contains "$OUT" "FAIL [rust] the derived boundary is empty" "[check] rust 도 빈 파생"
assert_not_contains "$OUT" "returned no derivation" "[check] 넷 다 있되 비었다 — 「없는 파생」이 빈 집합 갈래를 가리지 않는다"
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
printf '%s\n' '{ "go": { "pinned": ["go/admin.go"], "owners": {} }, "java": { "pinned": [], "owners": {} } }' > "$T/scripts/integration-coverage.json"
run check "$T"
assert_eq 2 "$RC" "파일럿이 안 재는 언어를 핀에 넣으면 exit 2"
assert_contains "$OUT" "FAIL [-] scripts/integration-coverage.json names java, which this pilot does not measure" "모르는 언어"
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
run report java "$T" --out "$D"
assert_eq 2 "$RC" "파일럿이 안 재는 언어는 usage(exit 2)"
assert_contains "$OUT" "this pilot measures go · python · node · rust — got java" "usage 문구"

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

# rust 의 지표는 lines(고유 줄 — 픽스처 106/136 = 77.941%).
fresh; floor rust lines 77.94
run report rust "$T" --out "$D"
assert_eq 0 "$RC" "[floor] rust 77.941% ≥ 77.94 — 출력: $OUT"
assert_line "$OUT" "integration-coverage [rust]: OK — 106/136 lines (77.9%) · floor lines ≥ 77.94% · 13 never-executed functions, all owned by open registry items" "[floor] rust 통과 요약"
fresh; floor rust lines 77.95
run report rust "$T" --out "$D"
assert_eq 3 "$RC" "[floor] rust 77.941% < 77.95 — 출력: $OUT"
fresh; floor rust statements 50
run check "$T"
assert_eq 2 "$RC" "[floor] rust 에 statements 는 없다(지표는 lines) — 출력: $OUT"
assert_contains "$OUT" "rust.floor.metric" "[floor] rust 지표 오류를 지목한다"

# 소유 문제와 하한 미달이 겹치면 게이트(3)가 경고(1)를 이긴다 — 경고는 그대로 찍는다.
fresh; floor go statements 46
sed -i '/AdminClient.Close/d' "$T/scripts/integration-coverage.json"
run report go "$T" --out "$D"
assert_eq 3 "$RC" "[floor] DRIFT + BELOW 는 3 — 출력: $OUT"
assert_contains "$OUT" "unowned never-executed function go/admin.go:AdminClient.Close" "[floor] 소유 문제도 함께 찍는다"

assert_report
