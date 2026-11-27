#!/usr/bin/env node
// integration-coverage.mjs — 통합 실행만의 「네트워크 경계」 커버리지 리포트. go · python(2026-11-02) · node · rust
// (2026-11-05) · php · ruby(2026-11-06) · dotnet · java(2026-11-07) · kotlin(2026-11-08)은 **하한 무장**. 새로 붙는 언어는 보고
// 모드에서 시작한다(3 걸음째 — 하한은 CI 관측 셋(PR 실행 포함 · main ≥ 1) 뒤).
//
// 왜: 아홉 언어가 「경계는 통합으로 검증한다」며 그 파일을 단위 커버리지 게이트에서 빼는데, 통합 실행에서
// 커버리지를 재는 언어가 0 이었다(등록부 `integration-coverage-never-measured`). 이 스크립트가 그 3 걸음째다 —
// 레인 통합 잡에 리포트를 붙인다. 하한(4 걸음째)은 `integration-coverage.json` 의 `floor` 다(값은 거기에만 둔다) — CI 관측
// 셋 뒤 무장했다. 지표는 go 문장 · python 함수 몸통(lines 는 import 때 도는 줄로 부푼다 — 아래) · node 문장 · rust 줄
// (lcov `DA` — 아래) · php 줄(PHPUnit XML — 아래) · ruby 메서드 몸통(python 과 같은 까닭 — 아래) · dotnet 줄(coverlet
// JSON — 아래) · java · kotlin 몸통(정적 초기화만 가진 줄을 뺀 JaCoCo 줄 — 아래). 값은 관측값을 소수 한 자리로 내린 것이라 여유가 없다 — 여유는 다음 변경이 무심사로 채운다(문서 예산
// 검사 8e 와 같은 이유). 내리려면 그 JSON 의 diff 가 판정이다. 하한이 없는 언어는 보고 모드 그대로다(**낮은 수치는
// 실패가 아니다**).
//
// 등록부가 붙인 세 조건:
//  · 리포트할 파일 집합은 단위 omit SSOT 에서 **파생**한다 — 측정 트리의 `scripts/coverage-boundary.mjs list --json`.
//    목록 사본을 측정에 쓰지 않는다.
//  · 그 집합을 **고정**한다 — `scripts/integration-coverage.json` 의 `pinned` 와 다르면 FAIL. 파생이 너무 적게 고르면
//    %가 오른다(실측 2026-09-27: coverlet `<Include>` 를 뒤집자 중첩 async 타입이 빠져 211/312). 핀은 측정 대상이 아니라
//    **오라클**이다 — SSOT 를 바꾸는 PR 이 「리포트의 분모가 바뀐다」를 같은 diff 에서 보이게 한다.
//  · 통합이 한 번도 실행하지 않는 함수 목록 — 항목마다 **열린** 등록부 id 가 소유자다(같은 JSON 의 `owners`). 갭이 아닌
//    파일 — 설치 하네스가 실서버에 대고 돌리는 예제 — 의 함수는 `harness:install` 이 소유한다. 그 연결을 트리에서 확인할
//    때만이다(아래 「하네스 소유」). 단위 미도달 장부(아래)가 재는 줄 · 문장 · 가지에 단위 스위트가 다 닿는 함수는 `unit:ledger` 가
//    소유한다 — 그 언어의 장부가 서 있고 admin 표면(아래) 파일이 아니며 장부에 그 함수의 항목이 **없을** 때만이다(어느 까닭의 항목이든
//    거부한다).
//
// ⚠️ 「파생 = 핀」만으로는 부족하다 — **도구가 데이터에서 파일을 떨어뜨리는** 길이 따로 있다. 그래서 파생한 파일마다
// 데이터에 실제로 있는지 본다(없으면 FAIL). 실측(2026-10-09, coverage.py 7.15): `[run] include` 만 쓰면 한 번도
// import 안 된 경계 파일이 리포트에서 **조용히 사라져** 75.0% 가 84.0% 가 된다 — 그래서 run 은 `source` 를 디렉터리로
// 준다(안 불린 파일도 0% 로 든다). go 는 빌드 태그로 빠진 파일이 같은 꼴이다.
// ⚠️ coverage.py 의 JSON 은 함수 영역을 **이름으로** 묶는다(`jsonreport.py` 의 `region_data[region.name]`). 같은 이름
// (property getter/setter · 재정의)이면 앞 영역이 덮여 미실행 목록에서 빠진다 — 영역 문장 수의 합이 파일 문장 수와
// 같아야 한다(실측: setter 를 더하자 9 문장 중 8 만 영역에 남았다). 다르면 FAIL.
// ⚠️ python 의 `lines` 는 import 때 도는 모듈·클래스 수준 줄을 덮인 것으로 센다 — 실제 트리에서 경계 395 문장 중
// 160 이 그렇다(실측 2026-10-09, 전부 100%). 그래서 함수 몸통만 센 `bodies` 를 함께 내고, 측정 실패 판정도 몸통으로 한다.
// go 의 문장은 전부 함수(리터럴) 몸통이다.
// ⚠️ go 의 미실행 함수는 소스를 직접 읽어 판정한다 — `go tool cover -func` 은 수신자 타입을 안 내고(같은 파일의
// `String` 둘을 못 가른다) 패키지 수준 함수 리터럴의 문장을 합계에서 뺀다(실측: 픽스처 9/20 vs 9/19).
// ⚠️ node 도 이름을 소스에서 읽는다 — vitest(v8)의 istanbul `fnMap` 이름은 클래스를 안 붙이고(두 클래스의 `constructor`
// 가 `constructor`·`constructor_2`), 익명·private 메서드를 **순번** `(anonymous_N)` 으로 낸다(실측 2026-11-05: `#masked` 가
// `(anonymous_1)`) — 위에 함수 하나가 늘면 소유자 키가 바뀐다. 그래서 prettier 가 보장하는 모양(최상위 선언은 열 0,
// 클래스 멤버는 열 2, 여러 줄 몸통은 같은 들여쓰기의 `}` 줄로 닫힌다)으로 이름 범위를 잡고 문장을 그 범위에 붙인다 —
// 콜백 같은 중첩 함수는 감싼 멤버에 접힌다(go 의 함수 리터럴과 같다). `typescript` 컴파일러에 기대지 않는다 — 자가테스트
// (doc-facts)에는 node_modules 가 없다.
// ⚠️ rust 의 수치는 `cargo llvm-cov --lcov` 의 `DA`(줄마다 llvm-cov 자신이 낸 판정)다. 같은 기록의 `LF`·`LH` 와 텍스트
// 요약의 Lines 는 쓰지 않는다 — 함수 레코드마다 줄을 더해(async fn 은 바깥 함수와 몸통 둘이다) 고유 줄보다 크다(실측
// 2026-11-05 실제 트리: admin.rs LF 279 · 고유 DA 246). 이름은 소스(rustfmt 모양)에서 읽고 도구의 함수 레코드(`FN`)와
// **양쪽으로** 대조한다. 레코드가 어느 이름 범위에도 없으면 파서가 항목을 놓친 것이다(FAIL — 그 함수의 줄이 모듈 수준에
// 섞이면 미실행 목록에서 조용히 빠진다). 이름 범위에 레코드가 없으면 그 함수는 이 실행의 데이터에 **없다** — 크레이트 밖에
// 안 보이고 아무도 참조 안 한 fn · 인스턴스화 안 된 제네릭 · 한 번도 poll 안 된 async 몸통은 줄째 빠진다(분모에서도 — 실측:
// 픽스처의 `unused_helper` · 제네릭 `From::from`. `pub` fn 은 모듈이 링크되면 0 회 레코드가 남는다). 그래서 미실행 목록에
// `no record` 로 든다. 참조 안 된 모듈은 파일째 빠진다(→ 「데이터에 없음」 FAIL — 그 모듈의 오브젝트가 링크되지 않는다). 부른
// async fn 의 몸통 레코드가 한 번도 안 돌았으면(퓨처를 만들고 버렸다) 그것도 미실행이다 — 줄이 아니라 FNDA 로 잰다(rustReport).
// ⚠️ **툴체인이 줄의 귀속을 바꾼다 — 코드가 그대로여도 줄 수치가 움직인다.** rustc 1.99.1 → 1.100.0 에서 같은 소스 · 같은 시험이
// 527/594 → 511/588 이 됐다(실측 2026-11-13, 한 실행의 두 레그): 호출과 오류 클로저가 한 줄에 있는 `.map_err(|e| …)?` ·
// `.ok_or_else(|| {` 줄을 1.99.1 은 호출이 돌았으니 친 줄로, 1.100.0 은 돌지 않은 클로저의 줄로 센다(클로저는 두 판 다 0 회).
// 하한을 내리기 전에 같은 커밋을 두 판으로 재고, 모든 함수의 실행/미실행 판정(FNDA)이 같고 잃은 줄이 전부 두 판에서 0 회인
// 클로저의 줄일 때만 내린다 — 하나라도 실행이 갈렸으면 그것은 귀속이 아니라 회귀다.
// `test` 없이는 컴파일되지 않는 항목(`#[cfg(test)]` · 접힌 `#[cfg(all(test, …))]` 도)은 통합 빌드에 없으므로 읽지 않는다 — 그
// 안에 레코드가 있으면 단위 테스트가 같은 빌드에서 돈 것이라(통합 전용이 아니다) FAIL 이다. 레코드 없이 줄만 있는 범위
// (`--skip-functions` 로 낸 데이터) · 매크로가 만든 함수(레코드가 `macro_rules!` 몸통을 가리킨다 — 줄을 나눠 써 안 돈 것을
// 못 가른다)도 FAIL 이다. ⚠️ cfg 쌍둥이 중 「no record」 쪽은 플랫폼마다 다르다 — 소유자는 CI(리눅스) 실행을 기준으로 단다.
// ⚠️ php 는 이름 · 범위 · 실행 가능 줄을 **도구에서** 받는다 — php-code-coverage 는 nikic/php-parser 로 클래스 · 트레이트 ·
// 함수와 실행 가능 줄을 정하고(정적 분석 — 파일을 싣기만 해서는 줄이 안 덮인다), 드라이버(pcov · Xdebug)는 돈 줄만 댄다.
// 형식은 PHPUnit XML(`--coverage-xml`)이다: clover 는 메서드 줄이 시작 줄의 문장을 덮어쓰고(`isset($lines[$line])`)
// 횟수가 덮은 **테스트 수**다 · cobertura 에는 선언 줄 · 파일별 줄 수 · 소스 해시가 없다(php-code-coverage 12.5.7 소스).
// 도구를 액면가로 받지 않고 셋을 대조한다 — 파일 해시(sha1, 데이터가 이 트리의 그 바이트에서 났다) · index.xml 합 = 파일 XML
// 합 · 메서드와 함수의 줄 합 = 파일 합(메서드 밖 줄은 어느 함수에도 못 붙인다). 익명 클래스와 클로저의 줄은 감싼 메서드의 것
// 이다(실측 — 익명 클래스는 따로 실리지 않는다). 단위 설정의 `<source><exclude>` 가 경계를 빼므로 run 은 그 설정 옆에
// `<source>` 만 경계 파일로 바꾼 사본을 만들어 돌리고 지운다 — 상대 경로(bootstrap · 테스트 디렉터리)가 그대로 풀린다
// (`--coverage-filter` 는 include 를 **더할** 뿐 exclude 를 못 이긴다 — PHPUnit 12 `Merger.php`).
// ⚠️ ruby 는 이름 · 범위 · 실행 가능 줄 · **호출 횟수**를 VM 에서 받는다 — `Coverage.start(lines:, methods:)` 의 메서드 키
// `[소유자, 이름, 시작 줄 · 열, 끝 줄 · 열]` 과 그 횟수다(미실행 = 횟수 0 — 줄로 추정하지 않는다). SimpleCov 의 JSON 은 쓸 수
// 없다 — 경계를 `skip` 해 경계 파일이 없고 메서드도 안 싣는다. 그래서 run 이 부트 파일 둘을 `<out>/ruby-boot/`(단위 장부는
// `ruby.unit-boot/`)에 쓴다:
// start.rb 는 bundler/setup **보다 먼저** Coverage 를 켜고(SimpleCov 1.2.0 은 `Coverage.running?` 이면 제 start 를 건너뛴다 —
// `simplecov.rb:120`), dump.rb 는 `rspec --require` 로 실려 스위트가 끝난 뒤(SimpleCov 의 at_exit 가 `Coverage.result` 로
// 측정을 멈추기 전) 이 트리 lib 의 파일마다 sha1 · 줄 · 메서드 · 가지(형식 /2 — 가지는 단위 미도달 장부만 센다)와 예제 결과를
// 쓴다. ⚠️ `bundle exec` 를 거치지 않는다 — 윈도에서
// 새 프로세스를 띄우며 RUBYOPT 맨 앞에 `-rbundler/setup` 을 붙여, gemspec 이 싣는 version.rb 가 측정 전에 실렸다(실측: 그
// 프로세스의 RUBYOPT 순서 · pid). 순서를 명시한다: `ruby -r<start> -rbundler/setup -e 'load Gem.bin_path("rspec-core", "rspec")'`.
// 적재 때 도는 클래스 · def 줄이 lines 를 부풀리므로(python 의 import 와 같다) bodies(메서드 범위 안 줄)를 함께 낸다. 메서드
// 밖 줄은 적재 때 돌았어야 한다 — 0 이면 블록이나 람다의 몸통이라 어느 메서드에도 못 붙인다(FAIL).
//
// ── 단위 미도달 장부(`unit` · `unit-report` — kotlin · php · dotnet · java · ruby · go · python · node · rust, 등록부 coverage-exclusion-hides-untested-branches ·
// coverage-omit-hides-security-paths) ──
// 왜: 위 소유 판정은 **함수 단위**다 — 통합이 한 번이라도 도는 경계 함수 안에 새로 생긴 · 바뀐 손으로 쓴 실패 갈래는 어느 게이트도
// 못 본다(단위 게이트는 그 파일을 빼고, 이 장부는 함수가 돌았는지만 본다 — #1125). 그래서 같은 경계 파일을 **단위** 스위트로 계측해
// 함수마다 단위 시험이 닿지 않는 코드를 센다 — kotlin · java 는 JaCoCo 메서드 계수기의 놓친 줄 · 놓친 가지, php 는 PHPUnit XML 의 놓친
// 실행 가능 줄, dotnet 은 coverlet 메서드마다 0 회인 줄 · 0 회인 가지, ruby 는 VM `Coverage` 의 메서드마다 0 회인 줄(한 줄 메서드는
// 호출 횟수) · 0 회인 가지 갈래, go 는 커버 프로필에서 함수마다 0 회인 블록의 문장(통합 리포트의 지표와 같다 — 프로필에는 줄 · 가지가
// 없다), python 은 coverage.py JSON(형식 3)의 함수 영역마다 안 돈 문장 · 안 탄 가지 호(`branch = true`), node 는 istanbul JSON(vitest 의 v8)의
// 이름 범위마다 안 돈 문장 · 안 탄 if · switch 갈래, rust 는 llvm-cov lcov 의 줄(DA — 통합 리포트의 지표와 같다)을 소스의 이름 범위로
// 함수마다 센 안 돈 줄. 이름 · 접기 · 무결성은 위의 같은
// 리더(jvmReport · phpReport · dotnetReport · rubyReport · goReport · pyReport · nodeReport · rustReport)가 낸다: kotlin 의
// 람다 · 로컬 함수 · 기본 인자 다리 · 익명 객체는 ktFold 가, java 의 람다(`lambda$…`) · 익명 · 지역 클래스는 javaFold 가, dotnet 의 상태
// 기계 · 람다 · 로컬 함수는 dotnetFold 가 소스 함수로 접으므로 그 안의 놓친 가지도 그 소스 함수의 수다(키가 합성 이름이 되지 않는다 —
// java 의 이름 붙은 중첩 클래스는 제 타입이고 오버로드는 매개변수로 가른다). ruby 의 블록 · 람다는 이름을 접을 것이 없다 — 감싼 메서드의
// 줄 범위 안이라 그 메서드의 줄 · 가지다(메서드 밖 블록의 안 돈 줄 · 안 탄 갈래는 리더가 FAIL 로 낸다). go 의 함수 리터럴도 같다 — 감싼
// 함수 선언의 줄 범위 안이라 그 함수의 문장이다(goFuncs — 패키지 수준 함수 리터럴의 안 돈 문장은 리더가 FAIL 로 낸다). python 의 중첩
// def 는 제 영역이다(`<감싼 함수>.<이름>` — coverage.py 가 감싼 함수의 영역에서 그 몸통을 뺀다) · 람다 · 컴프리헨션은 감싼 함수의 줄이다(영역
// 이름 "" — 모듈 · 클래스 몸통 — 의 안 돈 줄 · 안 탄 호는 리더가 FAIL 로 낸다). node 의 콜백 · 중첩 함수는 감싼 멤버(nodeFuncs 의 이름
// 범위)의 줄 범위 안이라 그 멤버의 문장 · 갈래다(이름 범위 밖의 안 돈 문장 · 안 탄 갈래는 리더가 FAIL 로 낸다). rust 의 클로저 · async 몸통 ·
// static 의 클로저 값은 감싼 항목의 이름 범위 안이라 그 항목의 줄이다(rustFuncs — 항목 밖 줄의 안 돈 것은 리더가 FAIL 로 낸다). 정적 초기화는
// kotlin · java `<타입>.<clinit>` · dotnet `<타입>.#cctor` 다. 장부는 `scripts/unit-unreached.json`(언어 → `"<파일>:<함수>"` → { lines(go · node 는
// statements), branches(kotlin · dotnet · java · ruby · python · node), why }) — why 는 `unreachable:` · `defensive:` · `integration:` 로 시작하는
// 까닭이거나 **열린** 등록부 id 다(위 소유자와 같은 판정).
// run 은 위 run 의 것 그대로다(php 는 생성한 설정의 `--testsuite unit`, kotlin 은 같은 초기화 스크립트로 `test` 태스크, dotnet 은 같은
// 생성 설정 · 같은 대상 하나로 `--filter "Category!=Integration"`, java 는 같은 리액터 · 같은 exec 자리로 레인의 단위 골 `test
// -DskipITs=true` — failsafe 는 그 뒤 단계라 안 돈다, ruby 는 같은 부트 파일 · 같은 순서로 레인의 단위 명령 `bundle exec rspec` — 태그
// 없이 그 기본 경로 `spec` 을, `RUN_INTEGRATION` 을 지운 환경이라 spec_helper 가 `:integration` 을 거르고 SimpleCov 게이트를 건다, go 는
// 같은 프로필 자리로 레인의 단위 명령 `go test -count=1 ./...` — 태그가 없어 `//go:build integration` 뒤의 통합 시험은 컴파일되지 않는다,
// python 은 같은 생성 설정(`source` 디렉터리 · 이 트리를 PYTHONPATH 맨 앞에)에 `branch = true` 를 더해(omit 없음) 레인의 단위 명령
// `pytest -m "not integration"` 을 `coverage run` 밑에서 — 그 표지의 통합 시험은 거르되 수집 때 그 모듈의 import 는 돈다, node 는 레인의 단위
// 명령(`npm test` = `vitest run --coverage` — 설정의 include 가 test/unit 뿐이라 통합 시험은 안 실린다)을 같은 v8 · 같은 include 로 돌되 설정의
// coverage 값을 CLI 로 덮는다: exclude 는 경계 자신이라 아무것도 빼지 않고(NODE_EXCLUDE_NOTHING), 하한 넷은 0 이다(설정의 하한은 경계를 넣은
// 합계에 걸려 exit 1 을 낸다 — 실측) · reportOnFailure(실패한 실행도 JSON 을 내 기록이 그 종료코드를 싣는다), rust 는 레인
// coverage 잡의 `cargo llvm-cov`(레인의 `cargo test` 를 계측해 돈다)를 경계를 빼는 정규식 없이 `--locked --lcov` 로 — lib 의 cfg(test)
// 단위 시험과 tests/ 의 대상이 돌고, 통합 E2E 는 `#[ignore]` 라 컴파일만 된다) —
// kotlin 은 그 태스크의 Kover 에이전트를 Kover 의 DSL(`instrumentation.disabledForTestTasks` — 빌드가 integrationTest 에 쓰는 그
// 손잡이)로 꺼서 한 클래스를 에이전트 둘이 고쳐 쓰지 않게 한다. 데이터 · 기록은 `.unit` 이 붙은 이름이라 통합의 것과 섞이지 않는다.
// ⚠️ java 의 jacoco.skip 모듈(예제 — 파생이 forced 로 넣는다)에는 에이전트가 안 붙고 단위 시험도 없다: 그 파일은 데이터에 줄 · 가지 전부를
// 놓친 것으로 든다(설치 하네스만 돌린다 — why 는 `integration:`).
// ⚠️ php 는 줄만 센다 — 행복 경로가 이미 도는 줄에 붙은 실패 갈래(`$x = $y ?? throw …` · 한 줄 `?:` · 삼항 · `match`)는 줄 수를 안
// 바꿔 이 장부가 못 본다. `--path-coverage`(Xdebug)로도 `--coverage-xml` 에는 가지 · 경로 수가 없다(실측 2026-11-18 — PHPUnit 12.5.33 ·
// php-code-coverage 12.5.7 · Xdebug 3.5.3: `<method>` 는 줄 수뿐이고 Report/Xml/Method.php 가 그것만 쓴다 · clover 는 클래스 단위
// conditionals · cobertura 는 메서드의 branch-rate 비율뿐이다). kotlin 은 한 줄의 실패 갈래도 가지로 센다.
// ⚠️ ruby 는 줄과 가지를 센다 — 덤프(형식 /2)가 VM `Coverage` 의 branches 를 싣는다(start.rb 가 `branches: true` 로 켠 것 — SimpleCov 의
// 가지 게이트도 같은 데이터를 읽는다). 가지는 if · unless · case · while · until · 삼항 · `&.` 의 갈래마다 하나다(한 줄의 후치 `if` ·
// `unless` · 삼항 · `&.` 의 안 탄 쪽도 센다). 갈래는 자리의 첫 줄로 메서드에 붙인다 — def 줄까지가 메서드의 것이다(기본 인자). 못 보는 것:
// `||` · `&&` · `or` · `and` 는 VM 이 가지로 싣지 않는다 — `x || raise …` 의 실패 갈래는 행복 경로가 도는 줄에 있으면 안 보인다(실측
// 2026-11-21 — 픽스처의 fallback). 한 줄 메서드(`def x = …` · `def x; …; end`)의 줄은 적재 때 돌므로 호출 횟수로 센다 — 안 불렸으면 1 줄이다.
// 몸통에 줄이 없는 메서드(`def x` 다음 줄이 `end`)는 안 불려도 0 줄이다(통합 리포트는 호출 횟수로 그것을 empty body 로 낸다).
// ⚠️ go 는 문장을 센다 — 커버 프로필은 블록마다 문장 수와 횟수뿐이다. if · else · switch · select 의 갈래는 제 블록이라 안 돈 실패 갈래는
// 그 블록의 문장으로 보인다. 못 보는 것: `&&` · `||` 의 피연산자(블록이 아니다 — 조건 커버리지는 gobco 를 손으로 돌린다,
// .claude/rules/go.md) · else 없는 if 의 거짓 쪽(제 블록이 없다) · 문장 없는 블록. 패키지 수준 함수 리터럴(어느 함수 선언에도 안 든다)의 안
// 돈 문장은 어느 함수에도 못 붙여 FAIL 이다 — 경계가 한 문장도 안 돈 실행이면 그 측정 실패가 먼저다. 커버 프로필에는 소스 해시도 시험
// 결과도 없어 run 이 기록에 종료코드 · 프로필의 sha1 · 경계 파일의 sha1(실행 앞뒤가 같을 때만 — dotnet 과 같다)을 싣는다. 통합 run 은
// 기록을 쓰지 않는다(그 판정은 그대로다).
// ⚠️ python 은 줄과 가지를 센다 — 가지는 coverage.py 의 호(arc)다: 한 줄에서 갈라 다른 줄로 가는 갈래마다 하나다(if · elif · else 없는 if 의
// 거짓 쪽 · while · for 의 들어감과 빠짐 · match 의 case). 못 보는 것: 한 줄 안의 결정은 호가 아니다 — 조건식(`a if c else b`) · `and` · `or`
// 의 피연산자 · 컴프리헨션의 `if` 의 안 탄 쪽은 줄로도 가지로도 안 보이고, `except` 도 가지가 아니라 안 탄 처리기는 그 줄로만 보인다(실측
// 2026-11-23 — 3.13 CTracer · 3.14 SysMonitor 가 같았다 · 픽스처의 fallback). 함수 영역은 몸통의 줄이다 — def 줄 · 데코레이터 · 기본 인자는
// import 때 도는 모듈 수준이다. 그 안 돈 줄 · 안 탄 호는 어느 함수에도 못 붙여 FAIL 이다 — 경계 함수의 몸통이 한 줄도 안 돈 실행이면 그
// 측정 실패(ranNothing)가 먼저다. coverage.py 의 JSON 에도 소스 해시 · 시험 결과가 없어 run 이 기록에 종료코드 · JSON 의 sha1 · 경계 파일의
// sha1(실행 앞뒤가 같을 때만)을 싣는다 — go 와 같다(통합 run 은 기록을 쓰지 않는다). ⚠️ 레인은 coverage.py 판을 고정하지 않는다(pytest-cov 가
// 끄는 최신) — 판이 호 분석을 바꾸면 코드가 그대로여도 수가 움직인다(그때 DRIFT 가 그것을 말한다).
// ⚠️ node 는 문장과 가지를 센다 — istanbul 의 문장(`s` — 통합 리포트의 지표와 같다)과, 가지는 if · switch 의 갈래(`b` — 안 탄 갈래마다 하나, else
// 없는 if 의 거짓 쪽 · 안 탄 case 도)뿐이다. 자리는 그 문장의 머리(`loc.start`)로 이름 범위에 붙인다 — 문장과 같은 규칙이다(함수 값의 머리 줄
// 대입은 그 함수의 것이 아니다). @vitest/coverage-v8 5.1.0 이 v8 범위를 옮기는 ast-v8-to-istanbul 1.0.7 은 가지 다섯 종류를 싣는다(if · switch ·
// cond-expr · binary-expr · default-arg — dist/index.mjs 의 onBranch). 못 보는 것: 식 안의 결정 — 조건식(`?:`) · `&&` · `||` · `??` · 기본 인자의
// 안 탄 쪽은 세지 않는다(python 의 한 줄 결정과 같은 경계 — 픽스처의 fallback · pick 의 `??`). 그리고 `/* v8 ignore … */` 가 가린 노드는 데이터에
// 아예 없다(실측 2026-11-24 — exchange 앞의 `next` 하나로 그 if 와 두 문장이 사라졌다). 모르는 종류가 실리면 FAIL 이다(새 판이 새 결정을 실으면
// 셀지 말지를 사람이 정한다). 어느 이름 범위에도 안 드는 문장(모듈 코드 · 클래스 필드의 초기값 · 함수 값의 대입)의 안 돈 것 · 갈래의 안 탄 쪽은
// 어느 함수에도 못 붙여 FAIL 이다 — 경계 파일을 한 번도 안 불러온 실행이면 그 측정 실패(ranNothing)가 먼저다. istanbul JSON 에도 소스 해시 ·
// 시험 결과가 없어 run 이 기록에 종료코드 · coverage-v8 판 · JSON 의 sha1 · 경계 파일의 sha1(실행 앞뒤가 같을 때만)을 싣는다 — python 과 같다.
// 실제 트리의 두 실행이 경계 파일의 문장 · 함수 · 가지 지도와 횟수까지 같았다(실측 2026-11-24).
// ⚠️ rust 는 줄만 센다 — 안정판 툴체인의 llvm-cov 에는 가지가 없다(`--branch` 는 nightly — .claude/rules/rust.md). 단위 빌드는 `test` 로만
// 컴파일되는 항목(경계 파일 안의 cfg(test) 시험 모듈)을 싣는다 — 시험이지 경계 코드가 아니라 장부가 그 레코드와 줄을 뺀다(통합 리포트는 그
// 레코드에 FAIL 이다 — 위). 라이브러리의 단위 시험 바이너리는 아무도 안 부른 함수 · 인스턴스화 안 된 제네릭 · poll 안 된 async 몸통에도
// 0 회 레코드를 남겨(실측 2026-11-24 rustc 1.100.0 — 픽스처의 refresh · convert) 그 줄도 센다. 그래서 레코드가 아예 없는 fn 은 이 빌드가
// 컴파일하지 않은 코드다(이 플랫폼이 빼는 cfg 쌍둥이) — 줄을 셀 수 없어 FAIL 이다. 위 통합의 async 판정(돈 레코드 수)은 단위 데이터에서
// 뜻이 없다 — 바이너리마다 레코드가 따로다(실제 트리: 한 fn 에 레코드 110). 못 보는 것: 줄만 세므로 코드가 돈 줄에 함께 있는 실패 클로저
// (한 줄의 `parse().map_err(…)` — 픽스처의 fallback)는 안 보인다 — rustfmt 가 사슬을 끊어 제 줄에 둔 `.map_err(…)?` 는 보인다(rustc
// 1.100.0 · 위 귀속의 판 차이). 항목 밖 줄의 안 돈 것은 어느 fn 에도 못 붙여 FAIL 이다. lcov 에는 소스 해시가 없어 run 이 기록에 종료코드 ·
// lcov 의 sha1 · 경계 파일의 sha1(실행 앞뒤가 같을 때만)을 싣고 rustc 판을 더한다(리포트가 찍기만 한다 — 판이 귀속을 바꾼다) — go 와 같다.
// ⚠️ 윈도 로컬: cargo 1.100 은 의존마다 `-L` 경로를 따로 넘겨 대상 디렉터리 경로가 길면 rustc 명령줄이 32,767 자를 넘는다 — cargo 가
// @argfile 로 넘기면 cargo-llvm-cov 0.8.7 의 RUSTC_WRAPPER 는 `--crate-name` 을 못 읽어 계측을 안 건다(실측 2026-11-24: `-L` 252 개 · 53,114 자
// → 「not found *.profraw」 exit 1 → FAIL). 짧은 CARGO_TARGET_DIR 로 돈다. CI(리눅스)는 해당이 없다.
// ⚠️ dotnet 도 가지를 센다 — coverlet(10.1.0)은 컴파일러가 만든 갈래 대부분을 싣지 않는다: 상태 기계의 분기 · finally 의 가드 · using 의
// null 검사 · 람다 · 메서드 그룹 캐시, 그리고 Task · ValueTask(ConfigureAwait 여부와 무관)를 await 할 때의 IsCompleted 검사(실측 2026-11-19,
// 실제 트리 · net8.0 Release: 경계의 상태 기계 31 개에 await 40 개 — 그중 18 개는 실린 가지가 0 개다 · AdminAsync 의 IL 조건 점프 10 개 중
// 실린 것은 소스의 결정 넷이다). 실린 가지 182 개는 전부 소스의 결정(if · ?: · ?? · ?. · 패턴 · && · || · switch · 반복)이 있는 문장의 것이고,
// 같은 트리의 net8.0 세 실행 · net10.0 한 실행이 경계 메서드 97 개의 줄 · 가지 수와 놓친 가지의 자리(오프셋 · 경로)까지 같았다.
// 싣는 것 하나: 다른 awaiter 의 IsCompleted 검사(측정: `Task.Yield()` 의 YieldAwaiter 는 싣고 Task · 완료된 Task · ValueTask · 설정한 둘 ·
// SemaphoreSlim.WaitAsync 는 안 싣는다) — 그 가지의 멈추는 쪽은 그 await 가 한 번이라도 멈춘 실행에서만 돈다(실행마다 갈릴 수 있다). 경계
// 파일의 await 40 개는 전부 Task · ValueTask 다(실린 가지 0). 못 보는 것 둘: `catch … when (…)` 필터 안의 결정은 가지로 안 실린다(IL 의
// endfilter 블록 — GetJsonAsync 의 두 필터에 조건 점프 넷, 데이터에 0) — 필터가 거른 쪽은 그 catch 몸통의 줄로만 보인다. 그리고 async
// 메서드(상태 기계) 안에서는 갈래의 횟수를 도착한 자리로 센다 — 한 갈래가 다른 갈래의 도착 자리로 흘러 들어가면(else 없는 if · ??=) 안
// 탄 그 갈래도 돈 것으로 센다(측정: 그 꼴의 async 메서드 셋은 안 탄 쪽이 1 회 · 같은 꼴의 동기 메서드 둘은 바르게 0 · 실제 트리의
// AdminAsync L64 `??=` 는 두 쪽 합 3078(1531 + 1547)이 그 줄에 온 1547 회보다 크다). 그래서 async 메서드의 놓친 가지 수는 하한이다(늘지는
// 않는다).
// ⚠️ 수로 대조하는 장부의 한계(모든 언어 공통) — 한 함수 안에서 시험이 옛 미도달 하나를 덮고 새 미도달 하나가 생기면 수가 같아 통과한다.
// 장부는 함수마다 「얼마나」를 대조할 뿐 「어느 줄 · 가지」인지는 대조하지 않는다.
// ⚠️ 커버리지 제외 표지(등록부 coverage-ignore-markers-unguarded) — 출하 소스의 표지는 그 코드를 이 장부의 데이터에서 지울 수 있는데 막는 것이
// 없었다. 그래서 `unit` · `unit-report` 는 리더보다 먼저 그 언어의 출하 소스(`git ls-files` 의 추적 파일 — 자리는 UNIT_MARKS)를 읽어 표지마다
// 파일:줄을 FAIL 로 낸다(무결성 — 장부를 대조하지 않는다). 읽은 추적 파일 수를 한 줄로 찍는다 — 0 이면 공허라 FAIL 이고, 추적됐는데 못 읽는 자리
// (하위 모듈 · 디렉터리)도, 스캔이 실패한 파일도 FAIL 이다. 표기는 도구 자신의 일치 규칙을 옮긴다(읽은 자리는 UNIT_MARKS 의 줄마다 — 그 규칙보다
// 좁지 않다). java · kotlin 은 주석 · 문자열 · 문자 리터럴을 빈칸으로 가린 뒤에 맞춘다 — 주석은 거기 설 수 없어 그 안의 Generated 는 표지가 아니다
// (가리기가 끝을 못 찾은 자리부터는 가리지 않는다 · kotlin 문자열 템플릿 `${…}` 의 몸통은 코드라 가리지 않는다). 나머지 언어의 표지는 주석
// 자체라 가리지 않는다. 스캔은 어떤 입력에도 그 크기에 선형이다(필수 체크 안에서 돈다 — 걸리면 모든 PR 이 막힌다).
// 실측(2026-11-26 · main 544eec69 · 칸마다 scripts/probe.sh — 장부가
// 이미 미도달로 적은 줄에 표지를 두고 `unit <언어>` 의 DRIFT 문구와 같은 시험 수로 읽었다 · 가린 칸마다 같은 자리의 오표기 대조군은 조용했다):
// 장부를 가린다 — node(@vitest/coverage-v8 5.1.0)의 `/* v8 ignore next */` · `/* c8 ignore next */` · `/* istanbul ignore next */`, python
// (coverage.py 7.15.2)의 `# pragma: no cover`, php(php-code-coverage 12.5.7 · pcov 1.0.12)의 `// @codeCoverageIgnoreStart` …
// `// @codeCoverageIgnoreEnd`, dotnet(coverlet json · .NET 8.0.34)의 메서드에 붙인 `[System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverage]`
// (메서드가 데이터에 없다), java(JaCoCo 0.8.16)의 메서드에 붙인 최상위 `@interface Generated`(CLASS 보존 — 메서드가 없다), kotlin(같은
// JaCoCo)의 메서드에 붙인 중첩 `annotation class Generated`(BINARY 보존). 가리지 않는다 — ruby 3.4.10 의 `# :nocov:` 쌍(돈 줄을 감싸도 · 안
// 부른 새 private 메서드를 감싸도 — 장부는 VM 의 Coverage 를 그대로 읽는다. SimpleCov 의 레인 게이트는 재지 않았다), rust(rustc 1.100.0 ·
// cargo-llvm-cov 0.8.7)의 `#[cfg_attr(coverage_nightly, coverage(off))]`(안정판에서 꺼져 있다) — 맨 `#[coverage(off)]` 는 안정판에서
// error[E0658] 이라 출하되지 못한다. go 의 `go tool cover` 에는 표지가 없다(읽지 않는다). 가린다고 잰 것은 위 칸뿐이다 — 같은 규칙의 다른 꼴
// (낱말 · 공백 · 대소문자)과 재지 않은 표기(`pragma: no branch` · ruby 의 `:nocov:` 와 `# simplecov:disable` · rust 의 `coverage(off)` · dotnet 의
// `ExcludeFromCoverage` · node 의 `node:coverage` · php 의 한 줄 · 문서 주석 · 속성 꼴 · java · kotlin 의 다른 Generated 이름과 별칭)는 행동
// 주장 없이(without a behaviour claim) 금지한다. coverage.py 의 DEFAULT_EXCLUDE 나머지 둘(`...` 만인 줄 · `if (typing\.)?TYPE_CHECKING:` —
// config.py:152–153)은 표지가 아니라 보지 않는다(숨길 런타임 논리가 없다).
// 종료코드(`unit` · `unit-report`): 0 측정 = 장부 · 1 DRIFT — 장부에 없는 미도달 · 수가 다르다 · 낡았거나 경계 밖 · 데이터에 없는 함수를
// 가리키는 항목 · 까닭이 아니거나 열린 항목이 아닌 why(그 줄이 할 일을 말한다 — 시험을 쓰거나 까닭을 적는다) · 2 FAIL — 아래 표의
// 무결성과 같다(데이터가 없다 · 다른 트리나 바이트의 것이다 · **단위 스위트의 성공한 실행이 아니다** · 경계 파일이 데이터에 없다 ·
// 장부 · 기록의 꼴을 모른다 · 출하 소스에 커버리지 제외 표지가 있거나 읽은 추적 파일이 0 이거나 추적된 자리를 못 읽거나 스캔이 실패한다 — 위). `check` 는 데이터
// 없이 장부의 꼴 · 경계 · why 를 본다(등록부만 바꾼 PR 도 — 레인은 `paths:` 뒤다).
//
// 종료코드 — 넷을 가른다. 「낮은 수치」는 하한이 무장된 언어에서만 실패다(3):
//   0 OK     리포트가 섰고, 하한 이상이며, 미실행 함수가 전부 소유자를 가졌다(열린 항목 · 트리에서 확인된 하네스 연결 · `unit:ledger`)
//   1 DRIFT  소유 문제(소유자 없음 · 열린 항목이 아님 · 낡거나 핀 밖을 가리키는 항목 · 트리에서 확인되지 않는 하네스 연결 ·
//            단위 장부에 항목이 있거나 admin 표면 파일의 `unit:ledger`) —
//            수치는 유효하다. CI 는 실패로 본다 — 레인은 이 종료코드를 그대로 받는다(0 만 통과 · 배선은
//            `scripts/test/test-integration-coverage-gate.sh`). 경고였던 동안 main 이 DRIFT 인 채 초록이었다(등록부
//            `integration-coverage-drift-is-warning-only` — 소유자 없는 go 함수 둘이 이틀 갔다)
//   2 FAIL   무결성 실패 — 수치를 믿을 수 없게 하는 것 전부. 넷으로 묶인다:
//            입력 — 핀 · 등록부 · 트리(소스의 이름 범위 · go.mod · 통합 스위트 정의) · 데이터가 없거나, 못 읽거나, 이
//              리더가 모르는 꼴이다(잘못 적은 하한 포함).
//            파생 — 실패 · 비었다(경계 파일이나 통합 테스트 파일이 0) · 핀과 다르다.
//            데이터 — 경계 파일이 빠졌다 · 아무것도 안 돌았다 · 스스로 모순이다 · 다른 체크아웃이나 다른 바이트의 것이다 ·
//              통합 스위트의 성공한 실행이 아니다(단위 테스트가 섞인 빌드 · 스위트 밖이거나 실패한 테스트 · run 기록이
//              없거나 실패했거나 다르다).
//            함수 회계 — 줄을 함수에 못 붙인다(함수 레코드 없음 · 이름 범위 밖 · 메서드 합 ≠ 파일 합) · 함수를 서로 못
//              가른다(매크로가 만든 함수 · 겹친 이름 · 같은 이름 영역의 덮어쓰기).
//            **이때는 수치를 내지 않는다**(인용될 숫자를 만들지 않는다). ⚠️ 레인 CI 주석은 이 표를 옮겨 적지 않고 여기를
//            가리킨다 — 다섯 레인의 사본이 다 그 리더의 fail() 보다 좁았다(실측 2026-11-06).
//   3 BELOW  하한 아래 — 수치는 유효하다. CI 는 실패로 본다. 비교는 정수식(covered × 100 < percent × 분모)이고 같으면 통과다.
//   4 UNEXERCISED  admin 표면(`integration-coverage.json` 의 `surface`)의 함수가 통합 실행에서 한 번도 안 돌았고 소유자도 없다 —
//            수치는 유효하다. CI 는 실패로 본다. 25 연산 하나를 스위트에서 지우면 여기로 온다
//            (등록부 `integration-admin-surface-regression-unguarded`). 하한 아래이기도 하면 둘 다 말하고 4 다.
//
// 사용(LANG = go · python · node · rust · php · ruby · dotnet · java · kotlin):
//   node scripts/integration-coverage.mjs <LANG> [--out DIR]                 로컬 — 통합 테스트(Docker) 후 리포트
//   node scripts/integration-coverage.mjs run    <LANG> [ROOT] [--out DIR]   CI 테스트 스텝 — 종료코드는 테스트의 것
//   node scripts/integration-coverage.mjs report <LANG> [ROOT] [--out DIR]   CI 리포트 스텝(하한이 있으면 게이트)
//   node scripts/integration-coverage.mjs check  [ROOT]                      파생 ↔ 핀 ↔ 소유자 · 단위 장부(데이터·Docker 불필요)
//   node scripts/integration-coverage.mjs unit        <kotlin|php|dotnet|java|ruby|go|python|node|rust> [ROOT] [--out DIR]   단위 스위트를 경계 계측과
//                                                                                                                            함께 돌리고 단위 미도달 장부와
//                                                                                                                            대조한다(Docker 불필요 — 레인 게이트)
//   node scripts/integration-coverage.mjs unit-report <kotlin|php|dotnet|java|ruby|go|python|node|rust> [ROOT] [--out DIR]   같은 대조만 — 앞선 `unit` 의 데이터로
// python 인터프리터는 `KCSDK_PY` → `python/.venv` → PATH 의 `python` 순이다. node 는 `node/node_modules` 의 vitest 를
// 이 node 로 직접 띄운다(npm 을 거치지 않는다 — 윈도의 `npm.cmd` 는 셸 없이 못 띄운다). rust 는 PATH 의 `cargo` 에
// `cargo-llvm-cov`(+ `llvm-tools-preview`)가 있어야 한다. php 는 PATH 의 `php` 에 커버리지 드라이버(pcov 또는 Xdebug —
// `XDEBUG_MODE=coverage` 는 run 이 준다)와 `php/vendor`(composer install)가 있어야 한다. ruby 는 PATH 의 `ruby` 와 설치된
// 번들(bundle install — `BUNDLE_GEMFILE` 이 없으면 `ruby/Gemfile`)이 있어야 한다. dotnet 은 PATH 의 `dotnet` 과, 테스트 프로젝트가
// 참조하는 `coverlet.collector`(컬렉터가 거기서 온다)가 있어야 한다. java 는 PATH 의 `mvn`(윈도는 `mvn.cmd` — 셸로 띄운다)과
// `JAVA_HOME`(없으면 PATH)의 `java` · `javap` 이 있어야 하고, run 이 JaCoCo CLI(레인 pom 의 판)를 Maven 으로 받는다. kotlin 은
// 레인의 Gradle 래퍼(`kotlin/gradlew`)와 같은 `java` · `javap` 이 있어야 하고, run 이 JaCoCo 에이전트 · CLI(판은 java 레인
// pom 의 것 — kotlin 빌드는 Kover 라 JaCoCo 판을 안 갖는다)를 초기화 스크립트로 받는다(빌드 파일은 안 고친다).
// DIR 기본값은 OS 임시 디렉터리 아래다.
import { readFileSync, existsSync, writeFileSync, mkdirSync, rmSync, readdirSync, copyFileSync, statSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { join, dirname, resolve, posix, basename } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'
import { dotnetTfms } from './lib/dotnet-tfm.mjs'

const PINS = 'scripts/integration-coverage.json'
const REGISTRY = 'docs/superpowers/plans/remaining-work.md'
const BOUNDARY = 'scripts/coverage-boundary.mjs'
const LANGS = ['go', 'python', 'node', 'rust', 'php', 'ruby', 'dotnet', 'java', 'kotlin']
// 하한 지표 — go 의 문장은 전부 함수 몸통이고, python 은 lines(import 때 도는 줄 포함)와 bodies(함수 안 문장)가 갈린다.
// node 는 istanbul 문장이다(모듈 수준 문장은 import 때 돌지만 경계 파일은 거의 전부 클래스 멤버다 — 표가 따로 보인다).
// rust 는 llvm-cov 의 고유 줄(DA)이다 — import 때 도는 코드가 없다. php 는 php-code-coverage 의 실행 가능 줄이다(정적 분석이
// 정한다 — 파일을 싣는 것만으로는 줄이 안 덮인다). ruby 는 python 처럼 lines(require 때 도는 클래스 · def 줄 포함)와
// bodies(메서드 범위 안 줄)가 갈린다. dotnet 은 coverlet 의 줄(시퀀스 포인트가 있는 줄)이다 — 적재 때 도는 것은 정적 생성자
// · 필드 초기화뿐이다. java 는 JaCoCo 의 줄이고, ruby 처럼 bodies(정적 초기화 `<clinit>` 만 가진 줄을 뺀 것)가 갈린다 — 클래스가
// 실리기만 해도 정적 초기화는 돈다. kotlin 은 java 와 같은 리더다(JaCoCo · javap — Companion · 파일 파사드의 정적 초기화도 같다).
const FLOOR_METRICS = { go: ['statements'], python: ['lines', 'bodies'], node: ['statements'], rust: ['lines'], php: ['lines'], ruby: ['lines', 'bodies'], dotnet: ['lines'], java: ['lines', 'bodies'], kotlin: ['lines', 'bodies'] }
const LINE_LANGS = new Set(['rust', 'php', 'ruby', 'dotnet', 'java', 'kotlin'])
// 함수 몸통을 따로 세는 언어 — 적재 때 도는 모듈 · 클래스 수준 줄이 lines 를 부풀린다(python 은 import · ruby 는 require · java ·
// kotlin 은 클래스 적재의 정적 초기화). 「아무것도 안 돈 실행」 판정도 몸통으로 한다.
const BODY_LANGS = new Set(['python', 'ruby', 'java', 'kotlin'])
// JaCoCo · javap 를 읽는 언어(같은 리더 — 이름 접기의 언어별 꼴만 다르다).
const JVM_LANGS = new Set(['java', 'kotlin'])
// 단위 미도달 장부(머리 주석) — 재는 언어와 why 의 까닭 머리. 등록부 id 가 아닌 why 는 이 셋 중 하나로 시작해야 한다.
const UNIT = 'scripts/unit-unreached.json'
const UNIT_LANGS = ['kotlin', 'php', 'dotnet', 'java', 'ruby', 'go', 'python', 'node', 'rust']
const UNIT_WHY = ['unreachable:', 'defensive:', 'integration:']
// 놓친 가지도 세는 언어 — php 의 데이터 · go 의 커버 프로필에는 가지가 없다(머리 주석). node 는 if · switch 의 갈래만 센다.
const UNIT_BRANCHES = new Set(['kotlin', 'dotnet', 'java', 'ruby', 'python', 'node'])
// 줄이 아니라 문장을 세는 언어 — go 의 커버 프로필은 블록마다 문장 수와 횟수뿐이고, node 는 istanbul 의 문장이다(머리 주석 · 두 통합 리포트의
// 지표와 같다). 장부 항목의 키도 그 이름이다(`statements` — 줄로 적으면 꼴이 틀린 것이다).
const UNIT_STATEMENTS = new Set(['go', 'node'])
const unitKey = (l) => (UNIT_STATEMENTS.has(l) ? 'statements' : 'lines')
// 커버리지 제외 표지(머리 주석) — 언어마다 출하 소스의 자리(`git ls-files` 의 경로 지정)와 표기. 표기는 그 언어의 도구가 쓰는 일치 규칙을 옮긴
// 정규식이다(읽은 자리는 줄마다 — 그 규칙보다 좁지 않다). 도구 규칙이 모두 대소문자를 가리므로 이 정규식들도 가린다. 표지가 없는 언어는 roots
// 대신 까닭을 적는다.
// python 은 coverage.py 7.15.2 config.py:151(DEFAULT_EXCLUDE) · :158(DEFAULT_PARTIAL) 그대로다 — parser.py:154 가 원문 전체에 re.MULTILINE 만으로
// 건다. 파이썬 str 의 \s 는 JS 의 \s 에 U+001C–001F · U+0085 를 더한다(실측 3.12.10) — 그만큼 넓힌다.
const PY_WS = '[\\s\\x1c-\\x1f\\x85]'
const pyMark = (w) => new RegExp(`#${PY_WS}*(?:pragma|PRAGMA)[:\\s\\x1c-\\x1f\\x85]?${PY_WS}*(?:no|NO)${PY_WS}*(?:${w}|${w.toUpperCase()})`, 'g')
// java · kotlin 은 JaCoCo 0.8.16 AnnotationGeneratedFilter.matches(javap -c)다 — 주석 서술자의 마지막 `/` · `$` 뒤 이름이 "Generated" 를 담으면
// 그 클래스의 메서드 전부 · 그 메서드를 거른다(CLASS · RUNTIME 보존만 클래스 파일에 남는다 — 소스에서는 못 가려 가리지 않는다). 그래서 붙인 자리의
// **마지막 이름 조각**을 본다(`@GeneratedCode` 는 담는다 · `@a.GeneratedX.User` 는 User 다). 붙인 자리에 그 이름이 안 보이는 길도 막는다 — 되풀이
// 주석(@Repeatable)을 두 번 붙이면 클래스 파일에는 그 **컨테이너**가 실리므로(JLS 9.7.5) 이름에 Generated 를 담은 주석 타입의 선언(java
// `@interface …` · kotlin `annotation class …`)도 표지다. 둘 다 주석 · 문자열 · 문자 리터럴을 빈칸으로 가린 원문(javaMask · kotlinMask — 자리 ·
// 줄바꿈은 그대로)에서 맞춘다 — 주석은 거기 설 수 없고, java 의 토큰 사이 블록 주석(`@/**/Generated` — javac 21 이 받아 클래스 파일에 싣는다,
// 실측)은 빈칸이 된다(kotlin 은 그 꼴을 거부한다). 가리기가 리터럴 · 주석의 끝을
// 못 찾으면 그 자리부터는 가리지 않는다(잘못 읽어도 숨기지 않고 더 낸다). java 에는 별칭이 없어 import 는 표지가 아니고(`import
// a.GeneratedToken;`), 어휘기가 토큰보다 먼저 푸는 \uXXXX 를 가리기 전에 푼다(javaUnicode — 이스케이프로 쓴 이름 글자도, 한 줄 주석을 끝내는
// 이스케이프한 줄바꿈도 javac 처럼 읽힌다). kotlin 은 백틱 이름 · 쓰임 자리 표적(`@get:` — 표적 낱말 열 개만) · 여러 주석 꼴(`@[A B(…)]` —
// 이름 자리만, kotlinLists) · 별칭(`import … as` · typealias — kotlinAliases) · 주석 타입 선언(kotlinAnnotationClasses)까지 보고, 레이블
// 참조(`this@X` · `super@X` · `super<T>@X` · `return@x` · `break@x` · `continue@x`)의 `@` 만 건너뛴다 — 한정자나 다른 주석에 붙은 `@`
// (`private@Generated` · `@JvmStatic@Generated`)도 주석으로 읽는다. kotlin 의 맨 이름에는 `$` 가 없다(문자열 템플릿의 시작이다). kotlin 의
// 문자열은 글자 조각만 가린다 — 템플릿 `${…}` 의 몸통은 코드다(ktString). 입력에 선형이다 — 가리기는 한 번 앞으로 읽고, 묶음의 짝은 한 번의 스택
// 훑기로 미리 내고(ktPairs), 스캐너 셋은 그 표로 묶음을 넘으며, 정규식에는 겹친 반복도 두 반복 사이의 낱말도 없다. 범위 밖 — 스캔하는 파일 밖에서
// 선언한 별칭 · 컨테이너는 읽지 않는다. 일부러 숨기는 꼴도 범위 밖이다(PM 판정) — java 이름 · `interface` 안의 무시되는 식별자 글자(소프트
// 하이픈 · ZWJ · U+FEFF · C0 제어 글자 — 원문이든 이스케이프든) · `[\p{L}\p{N}_$]` 밖의 java 식별자 글자(통화 기호 · U+203F · 결합 부호) ·
// 이스케이프가 만든 `\` 뒤의 유니코드 이스케이프 짝수 규칙 · `/*` 나 `"""` 를 담은 .kt 첫 줄의 `#!` · 따옴표를 담은 백틱 이름이 붙은 짧은 템플릿
// `$`. JaCoCo 가 안 읽는 자리도 보지 않는다(0.8.16 은 최상위 클래스 · 메서드 주석 서술자만 읽는다 — javap -c) — 타입 주석 · 주석의 원소 값으로
// 겹친 주석. 받아들인 더 내기 — 글자로 `@Generated` 를 담은 백틱 이름 · 이름 안의 `$`(`Generated$X` — JaCoCo 는 `X` 를 본다). 가리기가 멈춘 뒤의 원문은
// 따옴표 · 주석을 모르고 읽는다 — 거기서는 두 언어 다 Generated 를 담은 이름을 전부 낸다(javaRawTail · kotlinRawTail — 더 내고 숨기지 않는다:
// java 의 멈춘 뒤 `@/**/Generated` 도, kotlin 의 멈춤이 자른 목록 `@[Generated A("x` 도 이름으로 낸다). java 의 꼬리는 멈춘 자리부터다 — 멈춤이
// `.` 바로 뒤에서 자른 한정 이름(`@Generated."abc`)의 앞 조각은 내지 않는다(표지가 아니다 — JaCoCo 는 마지막 조각만 본다 · 그 조각은 꼬리가 낸다).
const J_ID = '[\\p{L}\\p{N}_$]'
// 조각의 끝 — 이름 글자나 `.` 가 이어지면 마지막 조각이 아니다(뒤 글자를 덜 먹어 맞추는 되돌림도 막는다).
const J_END = `(?!${J_ID}|\\s*\\.)`
// 「Generated 를 담은 조각」은 미리 보기 하나(`(?=…Generated)`)와 조각 전체로 맞춘다 — `…*Generated…*` 처럼 두 반복 사이에 두면 `@` +
// `Generated` × k + `.` 에서 Generated 마다 뒤를 다시 훑어 k 의 제곱이 된다(실측 7154f16c: k = 16000 에 4.4 초).
const JAVA_MARK = new RegExp(
  `@\\s*(?:${J_ID}+\\s*\\.\\s*)*(?=${J_ID}*Generated)${J_ID}+${J_END}|@\\s*interface\\s+(?=${J_ID}*Generated)${J_ID}+`,
  'gu',
)
// java 의 \uXXXX(`u` 여럿도 — `\uu0047`)를 푼다(JLS 3.3: 앞에 이어진 원문 `\` 가 짝수 개인 `\` 만 시작하고, 푼 글자는 다시 풀리지 않는다). 푼 원문과
// 푼 글자마다의 원문 자리(at — 끝에 원문 길이 하나를 더 둔다)를 낸다.
const J_UESC = /\\u+([0-9A-Fa-f]{4})/y
function javaUnicode(t) {
  const parts = []
  const at = []
  let run = 0
  for (let i = 0; i < t.length; ) {
    if (t[i] === '\\' && run % 2 === 0) {
      J_UESC.lastIndex = i
      const m = J_UESC.exec(t)
      if (m) {
        parts.push(String.fromCharCode(parseInt(m[1], 16)))
        at.push(i)
        i += m[0].length
        run = 0
        continue
      }
    }
    run = t[i] === '\\' ? run + 1 : 0
    parts.push(t[i])
    at.push(i)
    i++
  }
  at.push(t.length)
  return { text: parts.join(''), at }
}
// 가리기의 결과 — out 의 [0, stop) 은 가렸고 그 뒤는 원문이다(stop -1 은 끝까지 읽었다). 주석 · 리터럴 [a, b) 는 빈칸이 되고 줄바꿈(`\n` · `\r`)은
// 남는다 — 자리 · 줄 수가 원문과 같다.
function masked(out, t, stop) {
  return { text: stop < 0 ? out.join('') : out.slice(0, stop).join('') + t.slice(stop), stop }
}
function blank(out, a, b) {
  for (let k = a; k < b; k++) if (out[k] !== '\n' && out[k] !== '\r') out[k] = ' '
}
// java(푼 원문) — `//` · `/* */` · 텍스트 블록 `"""…"""` · 문자열 · 문자(`\x` 는 두 글자 — `"\""` · `'\''`). 끝을 못 찾으면(닫히지 않은 주석 ·
// 텍스트 블록, 줄을 넘는 문자열 · 문자) 그 자리부터 가리지 않는다. javac 가 거부하는 두 꼴도 끝을 못 찾은 것이다(먼 따옴표와 짝지으면 그 사이의
// 표지가 숨는다) — 문자 리터럴은 가장 긴 `'\377'` 이 여섯 글자라 닫는 따옴표가 그 안에 없으면 멈추고(J_CHAR), 텍스트 블록은 여는 `"""` 뒤가
// 공백 · 탭 · 폼피드와 줄 끝이 아니면 멈춘다(JLS 3.10.6).
const J_CHAR = 6
function javaMask(t) {
  const out = t.split('')
  for (let i = 0; i < t.length; ) {
    let e = -1
    if (t.startsWith('//', i)) {
      e = i + 2
      while (e < t.length && t[e] !== '\n' && t[e] !== '\r') e++
    } else if (t.startsWith('/*', i)) {
      e = t.indexOf('*/', i + 2)
      if (e >= 0) e += 2
    } else if (t.startsWith('"""', i)) {
      let j = i + 3
      while (t[j] === ' ' || t[j] === '\t' || t[j] === '\f') j++
      for (j = t[j] === '\n' || t[j] === '\r' ? j : t.length; j < t.length; ) {
        if (t[j] === '\\') j += 2
        else if (t.startsWith('"""', j)) {
          e = j + 3
          break
        } else j++
      }
    } else if (t[i] === '"' || t[i] === "'") {
      for (let j = i + 1; j < t.length && t[j] !== '\n' && t[j] !== '\r' && (t[i] === '"' || j - i < J_CHAR); ) {
        if (t[j] === '\\') {
          if (t[j + 1] === '\n' || t[j + 1] === '\r') break
          j += 2
        } else if (t[j] === t[i]) {
          e = j + 1
          break
        } else j++
      }
    } else {
      i++
      continue
    }
    if (e < 0) return masked(out, t, i)
    blank(out, i, e)
    i = e
  }
  return masked(out, t, -1)
}
const K_ID = '[\\p{L}\\p{N}_]'
const K_SEG = `(?:${K_ID}+|\`[^\`\\r\\n]+\`)`
// 마지막 조각 — 맨 이름은 이름 글자가 더 오면 안 되고(되돌림 방지), 백틱 이름은 닫는 백틱이 끝이다(바로 뒤에 `as` 가 붙어도 된다).
// Generated 는 미리 보기로 본다(JAVA_MARK 와 같은 까닭 — 두 반복 사이에 두면 제곱이다).
const K_LAST = `(?:(?=${K_ID}*Generated)${K_ID}+(?!${K_ID})|\`(?=[^\`\\r\\n]*Generated)[^\`\\r\\n]+\`)`
const K_NAME = `(?:${K_SEG}\\s*\\.\\s*)*${K_LAST}(?!\\s*\\.)`
// 쓰임 자리 표적 — 문법의 annotationUseSiteTarget 낱말만이다(`@realm:X` 는 주석이 아니다). kotlin 의 `@` 는 이름(또는 표적)에 붙는다 — `@ X` ·
// `@⏎X` · `@/**/X` 는 kotlinc 2.4.10 이 "Expected annotation identifier after '@'" 로 거부한다(실측). 그래서 `@` 뒤 공백을 넘지 않는다 — 레이블
// 정의 뒤의 이름(`lbl@ GeneratedX` — 컴파일된다)은 주석이 아니다.
const K_TARGET = '(?:file|property|field|get|set|receiver|param|setparam|delegate|all)\\s*:\\s*'
const K_AT = `(?<!\\b(?:this|super|return|break|continue)|\\bsuper\\s*<[^<>\\n]*>)@(?:${K_TARGET})?`
// 붙인 자리와 별칭 import. typealias · 주석 타입 선언은 정규식이 아니라 앞으로만 읽는 스캐너다(kotlinAliases · kotlinAnnotationClasses).
const KOTLIN_MARK = new RegExp(`${K_AT}${K_NAME}|\\bimport\\s+${K_NAME}(?=\\s*as\\b)`, 'gu')
// kotlin 의 여러 주석 꼴 `@[A B(…) C]` · `@get:[…]` — 목록의 이름 자리만 읽는다. 이름 뒤의 `<…>` · `(…)` 는 통째로 건너뛴다(가린 원문이라 인자 속
// `]` · `"Generated…"` 는 이미 빈칸이다). 목록으로 읽히지 않으면 아무것도 내지 않는다(컴파일되는 목록은 늘 읽힌다). 이름의 마지막 조각은
// K_ENTRY 의 묶음 1 이다(끝에서 거꾸로 찾는 정규식은 긴 조각 하나에 제곱이다).
const K_OPEN = new RegExp(`${K_AT}\\[`, 'gu')
const K_ENTRY = new RegExp(`(?:${K_SEG}\\s*\\.\\s*)*(${K_SEG})`, 'uy')
// 토큰 사이의 공백을 넘는다 — 가린 원문에서 주석은 이미 빈칸이다. 가리기가 멈춘 뒤의 원문(kotlinMask)에서는 주석을 넘지 않는다: 닫히지 않은 `/*` 를
// 스캐너의 시작마다 파일 끝까지 다시 읽으면 제곱이다(실측 7154f16c: 멈춘 뒤 `typealias /*` × 16000 에 7.7 초).
const K_WS = /\s/
function ktWs(t, i) {
  while (i < t.length && K_WS.test(t[i])) i++
  return i
}
// t[i] 가 `/*` 인 블록 주석의 끝 다음 자리 — kotlin 의 블록 주석은 겹친다(닫히지 않으면 -1).
function ktBlock(t, i) {
  for (let d = 0; i < t.length; )
    if (t.startsWith('/*', i)) {
      d++
      i += 2
    } else if (t.startsWith('*/', i)) {
      i += 2
      if (--d === 0) return i
    } else i++
  return -1
}
// t[i] 가 `'` 인 문자 리터럴의 끝 다음 자리(`'"'` · `'\''` · `'\uXXXX'` — 비었거나 줄을 넘거나 닫히지 않으면 -1). `\` 뒤가 줄 끝이어도 -1 이다 —
// 그 줄바꿈을 이스케이프로 넘으면 다음 줄의 `'` 에서 닫혀 그 뒤의 따옴표가 어긋나고 표지가 숨는다.
function ktChar(t, i) {
  for (let j = i + 1; j < t.length && j - i < 12 && t[j] !== '\n' && t[j] !== '\r'; )
    if (t[j] === '\\') {
      if (t[j + 1] === '\n' || t[j + 1] === '\r') return -1
      j += 2
    } else if (t[j] === "'") return j > i + 1 ? j + 1 : -1
    else j++
  return -1
}
// t[i] 가 백틱인 이름의 끝 다음 자리 — 그 안의 따옴표 · 괄호는 이름의 글자다(줄을 넘거나 닫히지 않으면 -1).
function ktTick(t, i) {
  for (let j = i + 1; j < t.length && t[j] !== '\n' && t[j] !== '\r'; j++) if (t[j] === '`') return j + 1
  return -1
}
// 묶음의 짝(가린 원문) — 여는 `(` `[` `{` `<` 의 자리마다 닫는 자리를 한 번의 스택 훑기로 미리 낸다(닫히지 않으면 -1). 스캐너는 묶음을 이 표로
// 넘는다 — 시작마다 닫는 자리를 다시 찾으면 닫히지 않은 묶음(`typealias A<` · `@A(⏎` · `@[A(` 의 되풀이)에서 저마다 파일 끝까지 읽어 제곱이었다
// (실측 7154f16c: k = 16000 에 11.6 · 4.2 · 3.9 초). `(…)` `[…]` `{…}` 는 저마다 한 칸이다 — 닫히면 그 안의 짝 없는 `<` 를 버리고, `>` 는 같은 칸의
// `<` 만 닫는다(`<@Ann(1 > 0) T>` 의 `>` 는 비교다 — kotlinc 2.4.10 이 받는다, 실측). 함수 타입의 화살표 `->` 의 `>` 는 닫지 않고, 백틱 이름 속의
// 글자는 이름이다. 가리기가 멈춘 뒤의 원문에서는 따옴표 · 주석을 모른다(그 안의 괄호도 센다 — 한 번만 훑어야 선형이다).
const K_OPENER = { ')': '(', ']': '[', '}': '{' }
let K_PAIRED = { t: '', to: new Int32Array(0) }
function ktPairs(t) {
  if (K_PAIRED.t === t) return K_PAIRED.to
  const to = new Int32Array(t.length).fill(-1)
  const open = []
  const live = { '(': 0, '[': 0, '{': 0 }
  for (let i = 0; i < t.length; i++) {
    const c = t[i]
    if (c === '`') {
      const e = ktTick(t, i)
      if (e > 0) i = e - 1
    } else if (c === '-' && t[i + 1] === '>') i++
    else if (c === '(' || c === '[' || c === '{') {
      open.push(i)
      live[c]++
    } else if (c === '<') open.push(i)
    else if (c === '>') {
      if (open.length > 0 && t[open[open.length - 1]] === '<') to[open.pop()] = i
    } else if ((c === ')' || c === ']' || c === '}') && live[K_OPENER[c]] > 0) {
      // 짝이 스택에 있을 때만 내려간다(없는 짝을 닫는 글자마다 찾으면 제곱이다) — 그 위의 닫히지 않은 묶음은 버린다. 스택이 비면 멈춘다(수와
      // 스택이 어긋나도 걸리지 않는다 — 걸린 스캔은 모든 PR 을 막는다).
      while (open.length > 0) {
        const p = open.pop()
        if (t[p] !== '<') live[t[p]]--
        if (t[p] === K_OPENER[c]) {
          to[p] = i
          break
        }
      }
    }
  }
  K_PAIRED = { t, to }
  return to
}
// t[i] 가 `"` 인 문자열을 가리고 그 끝 다음 자리를 낸다 — 글자 조각만 빈칸이 되고(닫는 따옴표 하나는 남는다 — 리터럴이 거기서 끝났다는
// 자취다, ktContinues. 문자 리터럴도 같다), 템플릿 `${…}` 의 몸통은 **코드라 남는다**(ktTemplate — 그 안의 `object { @Generated fun … }` 은 컴파일되어 클래스 파일에
// 실린다, kotlinc 2.4.10 실측). 여러 달러 문자열(`$$"…"` · `$$"""…"""`)은 여는 따옴표 앞 `$` 의 수 이상 이어진 `$` 뒤의 `{` 만 템플릿이다(그보다
// 적은 `${` 는 글자다). 원문 문자열은 따옴표 셋 앞의 따옴표가 내용이다. 보통 문자열은 줄을 넘지 못한다(줄바꿈 · `\` 뒤 줄바꿈이면 -1). `$` 는
// 이어진 만큼 한 번에 센다(자리마다 접두를 다시 대면 `$` × k 에 제곱이다). 겹침이 K_DEEP 을 넘으면 던진다 — 그 파일은 FAIL 이다(unitMarks).
const K_DEEP = 100
function ktString(t, i, out, depth) {
  if (depth > K_DEEP) throw new Error(`string templates nested deeper than ${K_DEEP}`)
  let n = 0
  while (t[i - 1 - n] === '$') n++
  if (n === 0) n = 1
  const raw = t.startsWith('"""', i)
  let from = i
  for (let j = i + (raw ? 3 : 1); j < t.length; ) {
    const c = t[j]
    if (c === '$') {
      let r = j
      while (t[r] === '$') r++
      if (r - j >= n && t[r] === '{') {
        blank(out, from, r)
        j = ktTemplate(t, r, out, depth + 1)
        if (j < 0) return -1
        from = j
      } else j = r
    } else if (raw) {
      if (t.startsWith('"""', j)) {
        for (j += 3; t[j] === '"'; j++);
        blank(out, from, j - 1)
        return j
      }
      j++
    } else if (c === '"') {
      blank(out, from, j)
      return j + 1
    } else if (c === '\n' || c === '\r') return -1
    else if (c === '\\') {
      if (t[j + 1] === '\n' || t[j + 1] === '\r') return -1
      j += 2
    } else j++
  }
  return -1
}
// t[i] 가 템플릿 몸통을 여는 `{` 다 — 짝 맞는 `}` 다음 자리(닫히지 않으면 -1). 몸통은 코드다: 그 안의 주석 · 문자열 · 문자만 가린다.
function ktTemplate(t, i, out, depth) {
  for (let d = 0; i < t.length; ) {
    const e = ktLexeme(t, i, out, depth)
    if (e < 0) return -1
    if (e > i) i = e
    else {
      if (t[i] === '{') d++
      else if (t[i] === '}' && --d === 0) return i + 1
      i++
    }
  }
  return -1
}
// t[i] 에서 시작하는 주석 · 문자열 · 문자를 가리고(백틱 이름은 이름이라 가리지 않고 넘는다 — 그 안의 `"` 는 문자열이 아니다) 그 끝 다음 자리를
// 낸다. 그런 것이 아니면 i, 끝을 못 찾으면 -1.
function ktLexeme(t, i, out, depth) {
  const c = t[i]
  if (c === '"') return ktString(t, i, out, depth)
  if (c === '`') return ktTick(t, i)
  let e = i
  if (c === "'") {
    e = ktChar(t, i)
    if (e > 0) blank(out, i, e - 1)
  } else if (c === '/' && t[i + 1] === '/') {
    for (e = i + 2; e < t.length && t[e] !== '\n' && t[e] !== '\r'; e++);
    blank(out, i, e)
  } else if (c === '/' && t[i + 1] === '*') {
    e = ktBlock(t, i)
    if (e > 0) blank(out, i, e)
  }
  return e
}
// kotlin — `//` · 겹치는 `/* */` · 문자열의 글자 조각(원문 · 여러 달러 — 템플릿의 코드는 남긴다) · 문자를 가린다. 끝을 못 찾으면 그 자리(가장
// 바깥 리터럴의 처음)부터 가리지 않는다. 한 번만 앞으로 읽는다(멈추면 거기서 끝이다) — 입력에 선형이다.
function kotlinMask(t) {
  const out = t.split('')
  for (let i = 0; i < t.length; ) {
    const e = ktLexeme(t, i, out, 0)
    if (e < 0) return masked(out, t, i)
    i = e > i ? e : i + 1
  }
  return masked(out, t, -1)
}
// 가린 원문의 자리 p(공백이 아닌 글자)에서 문장이 끝날 수 없으면 참이다 — 그 뒤 줄의 `annotation` 은 한정자가 아니라 이어지는 식이다(`fun get() =⏎
// annotation⏎class GeneratedModel` 은 컴파일되고 그 클래스는 주석 타입이 아니다 — kotlinc 2.4.10 · javap 실측). 문장을 끝낼 수 있는 글자는 넣지
// 않는다(모르면 낸다): `import a.*` 의 `*` · `x++` · `x--` · `x!!` · 제네릭을 닫는 `>`(람다의 `->` 뒤는 문장의 처음이다) · 널 허용의 `?` · 리터럴의
// 따옴표(가리기가 남긴다). 넣은 글자는 저마다 그 뒤 줄의 `annotation⏎class X` 가 보통 클래스로 컴파일되는 것을 쟀다(같은 실측).
function ktContinues(t, p) {
  const c = p < 0 ? '' : t[p]
  if (c === '+' || c === '-' || c === '!') return t[p - 1] !== c
  return c !== '' && '=/%<.:&|'.includes(c)
}
// t[i] 가 `@` 인 주석 하나(가린 원문)의 끝 다음 자리 — 쓰임 자리 표적 · 목록 `@[…]` · 이름 · 타입 인자 `<…>` · 인자 `(…)`. 이름 뒤 공백 너머의
// 괄호도 인자다(선언의 `@Target (…)` — kotlinc 2.4.10 이 받는다, 실측). 타입 자리의 `@A (X)` 는 `->` 가 없으면 컴파일되지 않고 있으면 함수
// 타입이라(같은 실측) 어느 쪽으로 읽든 별칭이 아니다. `@` 뒤 공백은 넘는다(컴파일되지 않는 꼴이라 넘어도 숨기지 않는다 — 낱말에 붙은 `@` 뒤의
// 공백은 레이블 정의라 부르는 쪽이 먼저 거른다, kotlinAnnotationClasses). 묶음은 짝 표(to — ktPairs)로 넘는다. 읽히지 않으면 -1.
const K_USE = new RegExp(K_TARGET, 'y')
function ktAnnotation(t, i, to) {
  i = ktWs(t, i + 1)
  K_USE.lastIndex = i
  const u = K_USE.exec(t)
  if (u) i = ktWs(t, i + u[0].length)
  if (t[i] === '[') return to[i] < 0 ? -1 : to[i] + 1
  K_ENTRY.lastIndex = i
  const n = K_ENTRY.exec(t)
  if (!n) return -1
  i += n[0].length
  let j = ktWs(t, i)
  if (t[j] === '<') {
    if (to[j] < 0) return -1
    i = to[j] + 1
    j = ktWs(t, i)
  }
  if (t[j] === '(') {
    if (to[j] < 0) return -1
    i = to[j] + 1
  }
  return i
}
// kotlin 의 typealias(가린 원문) — 이름 · 타입 매개변수 `<…>`(짝 표 — 여러 줄 · `->` · 주석 인자 속 비교도) · `=` 뒤의 타입 주석 · 여는 괄호를
// 넘어, 오른쪽의 머리가 마지막 조각에 Generated 를 담은 이름(K_NAME)이면 표지다 — 이름 뒤에 타입 인자 `<…>` 나 `?` 가 와도, 괄호로 싸여도
// 그렇다: kotlinc 2.4.10 은 `= Generated?` · `= (Generated)?` 의 별칭을 주석으로 받아 클래스 파일에 Generated 를 싣고, 주석 클래스는 타입
// 매개변수를 가질 수 있다(`annotation class GenG<T>` 의 별칭 `= GenG<Int>` 가 GenG 를 싣는다 — 셋 다 javap 실측). 조용한 꼴은 둘이다 — 이름
// 앞에서 연 괄호가 이름(· `<…>` · `?`) 바로 뒤에서 다 닫히지 않거나(함수 타입의 매개변수 목록 — `(GeneratedA, Int) -> …` · 이름 붙인 매개변수
// `(isGenerated: Boolean) -> …`), 그 뒤에 `.` · `->` 가 온다(받는 쪽 `X?.() -> …` · 안쪽 타입 `X<…>.Inner` · 함수 타입). 값을 치른다 —
// `typealias X = GeneratedEvent?` 같은 보통 타입의 별칭도 낸다(이름이 주석인지는 이 스캔이 풀 수 없다 — `= GeneratedEvent` 와 같은 부류다).
const K_TYPEALIAS = /\btypealias\b/g
const K_ALIAS = new RegExp(K_SEG, 'uy')
const K_TNAME = new RegExp(K_NAME, 'uy')
function kotlinAliases(t) {
  const to = ktPairs(t)
  const hits = []
  for (const a of t.matchAll(K_TYPEALIAS)) {
    let i = ktWs(t, a.index + a[0].length)
    K_ALIAS.lastIndex = i
    const s = K_ALIAS.exec(t)
    if (!s) continue
    i = ktWs(t, i + s[0].length)
    if (t[i] === '<') {
      if (to[i] < 0) continue
      i = ktWs(t, to[i] + 1)
    }
    if (t[i] !== '=') continue
    let opens = 0
    for (i = ktWs(t, i + 1); i >= 0 && (t[i] === '@' || t[i] === '('); ) {
      if (t[i] === '(') {
        opens++
        i++
      } else i = ktAnnotation(t, i, to)
      if (i >= 0) i = ktWs(t, i)
    }
    if (i < 0) continue
    K_TNAME.lastIndex = i
    const n = K_TNAME.exec(t)
    if (!n) continue
    let end = i + n[0].length
    let k = ktWs(t, end)
    if (t[k] === '<' && to[k] >= 0) {
      end = to[k] + 1
      k = ktWs(t, end)
    }
    let closed = 0
    while (t[k] === '?' || (t[k] === ')' && closed < opens)) {
      if (t[k] === ')') closed++
      end = k + 1
      k = ktWs(t, end)
    }
    if (closed < opens || t[k] === '.' || t.startsWith('->', k)) continue
    hits.push({ at: a.index, start: a.index, end })
  }
  return hits
}
// kotlin 의 주석 타입 선언(가린 원문) — 선언의 머리(파일 처음 · 줄 머리 · `{` `}` `;` 뒤)에서 한정자 · 주석의 목록을 앞으로 읽어(줄을 넘어도) 그
// 안에 `annotation` 이 있고 `class 이름` 으로 끝나면 그 이름을 본다. `annotation` 은 한정자 자리에서만 한정자다 — `val x = annotation⏎class …` 는
// 아니고 `annotation⏎class …` 는 그렇다. 이미 읽은 목록 안의 머리는 다시 읽지 않는다(선형). 머리가 아닌 자리 둘을 거른다 — 앞 줄이 문장을
// 끝낼 수 없는 글자로 끝났거나(ktContinues — 이어지는 식이다), 낱말에 `@` 가 붙고 그 뒤가 공백이다(`annotation@ foo()` 는 레이블 정의다 —
// 그 다음 줄의 클래스는 보통 클래스다, kotlinc 2.4.10 실측. 붙여 쓴 `annotation@foo()` 는 한정자 + 주석으로 읽히므로 그대로 낸다 — 같은 실측).
const K_MODIFIERS = new Set([
  ...['public', 'private', 'internal', 'protected', 'expect', 'actual', 'final', 'open', 'abstract', 'sealed', 'annotation', 'data', 'enum'],
  ...['inner', 'value', 'override', 'lateinit', 'tailrec', 'operator', 'infix', 'inline', 'external', 'suspend', 'const', 'vararg'],
  ...['noinline', 'crossinline'],
])
const K_WORD = /[\p{L}_][\p{L}\p{N}_]*/uy
const K_CLASSNAME = new RegExp(K_LAST, 'uy')
function kotlinAnnotationClasses(t, stop) {
  const to = ktPairs(t)
  const hits = []
  // prev — s 앞의 마지막 공백 아닌 글자의 자리(머리마다 거꾸로 찾으면 빈 줄의 되풀이에 제곱이다). 가리기가 멈춘 자리(stop) 뒤의 글자로는 이어짐을
  // 판정하지 않는다 — 거기서는 주석이 가려지지 않아 앞 줄의 끝이 주석의 글자일 수 있다(`// note:⏎annotation class …` 을 숨기지 않는다).
  for (let s = 0, done = 0, prev = -1; s < t.length; s++) {
    if (s > 0 && !K_WS.test(t[s - 1])) prev = s - 1
    if ((s > 0 && !'\n\r{};'.includes(t[s - 1])) || s < done || ((stop < 0 || prev < stop) && ktContinues(t, prev))) continue
    let i = s
    // 파일 머리의 BOM(U+FEFF)도 머리의 공백이다 — 편집기가 쓴 BOM 뒤 첫 줄의 선언을 kotlinc 2.4.10 이 받는다(실측).
    while (t[i] === ' ' || t[i] === '\t' || t[i] === '\f' || t.charCodeAt(i) === 0xfeff) i++
    let ann = -1
    for (;;) {
      if (t[i] === '@') {
        const j = ktAnnotation(t, i, to)
        if (j < 0) break
        i = j
      } else {
        K_WORD.lastIndex = i
        const w = K_WORD.exec(t)
        if (!w || !K_MODIFIERS.has(w[0])) break
        const e = i + w[0].length
        if (t[e] === '@' && (e + 1 >= t.length || K_WS.test(t[e + 1]))) break
        if (w[0] === 'annotation' && ann < 0) ann = i
        i = e
      }
      i = ktWs(t, i)
    }
    done = i
    if (ann < 0) continue
    K_WORD.lastIndex = i
    const c = K_WORD.exec(t)
    if (!c || c[0] !== 'class') continue
    const j = ktWs(t, i + c[0].length)
    K_CLASSNAME.lastIndex = j
    const n = K_CLASSNAME.exec(t)
    if (n) hits.push({ at: ann, start: ann, end: j + n[0].length })
  }
  return hits
}
function kotlinLists(t) {
  const to = ktPairs(t)
  const hits = []
  for (const o of t.matchAll(K_OPEN)) {
    const names = []
    for (let i = o.index + o[0].length; ; ) {
      i = ktWs(t, i)
      if (t[i] === ']') {
        for (const at of names) hits.push({ at, start: o.index, end: i + 1 })
        break
      }
      K_ENTRY.lastIndex = i
      const e = i < t.length ? K_ENTRY.exec(t) : null
      if (!e) break
      if (e[1].includes('Generated')) names.push(i)
      i = ktWs(t, i + e[0].length)
      if (t[i] === '<') {
        if (to[i] < 0) break
        i = ktWs(t, to[i] + 1)
      }
      if (t[i] === '(') {
        if (to[i] < 0) break
        i = to[i] + 1
      }
    }
  }
  return hits
}
// 가리기가 멈춘 뒤의 원문(stop 부터) — 거기서는 따옴표 · 주석을 모르므로 그 안의 괄호가 먼 괄호와 짝지어져 스캐너가 뒤의 선언을 넘거나
// 목록을 못 읽는다(`@A("(")⏎annotation class GeneratedX⏎… ")"` · `@[A("]") Generated]`). 그래서 그 구간에서는 Generated 를 담은 **이름 전부**를
// 낸다 — `$` 에 붙은 이름도 낸다(백틱 이름은 `$` 를 담을 수 있다: ``annotation class `x$Generated` `` 가 컴파일되고 JaCoCo 는 마지막 `$` 뒤를
// 본다 — kotlinc 2.4.10 · javap 실측. 템플릿 `"$GeneratedName"` 도 함께 내는 값을 치른다). 더 내는 것은 받아들이고 숨기지 않는다(멈춘 파일은
// 컴파일되지 않는다). 다른 스캐너가 이미 낸 표기 안의 이름은 markHits 가 뺀다(fallback). 정규식은 이름마다 한 번 미리 본다(선형).
// 멈춘 자리 앞에서 열려 그 뒤에서 닫힌 묶음도 같은 까닭으로 믿지 못한다 — 가린 쪽의 `@Target(` 가 뒤쪽 주석의 `)` 와 짝지어지면 스캐너가 그
// 사이(멈춘 자리 **앞**)의 선언을 넘는다. 그래서 그런 묶음이 있으면 가장 앞의 여는 자리부터 낸다(짝은 그대로 둔다 — 그 짝으로 읽히던 표지는
// 계속 읽힌다). 멈춘 자리 앞에서 열려 **끝내 안 닫힌** 묶음도 같다 — 멈춤이 자른 목록 `@[Generated A("x` 는 `[` 가 안 닫혀 목록으로 읽히지
// 않고, 이름은 멈춘 자리 앞이라 꼬리에도 들지 않았다. 그래서 그 여는 자리도 시작 후보다(비교의 `<` 도 안 닫힌 여는 자리로 센다 — 더 낸다).
const K_RAW = new RegExp(`(?<![\\p{L}\\p{N}_])(?=${K_ID}*Generated)${K_ID}+`, 'gu')
function kotlinRawTail(t, stop) {
  const hits = []
  if (stop < 0) return hits
  const to = ktPairs(t)
  let from = stop
  for (let p = 0; p < stop; p++)
    if (to[p] >= stop || (to[p] < 0 && '([{<'.includes(t[p]))) {
      from = p
      break
    }
  K_RAW.lastIndex = from
  for (let m; (m = K_RAW.exec(t)); ) hits.push({ at: m.index, start: m.index, end: m.index + m[0].length, fallback: true })
  return hits
}
// java 의 같은 꼬리 — 멈춘 뒤의 원문에서는 주석이 가려지지 않아 JAVA_MARK 가 `@` 와 이름 사이의 주석(`@/**/Generated` · `@a./**/Generated` ·
// `@/**/interface GeneratedX`)을 못 넘는다. 멈춘 자리부터 Generated 를 담은 이름을 전부 낸다(java 이름은 `$` 를 담는다 — 이름의 글자다). 시작은
// 멈춘 자리다 — 그 앞은 JAVA_MARK 가 가린 글을 JaCoCo 의 규칙(마지막 조각)으로 읽는다. 멈춤이 `.` 바로 뒤에서 자른 한정 이름(`@Generated."abc` ·
// `@a."abc⏎.Generated`)은 멈춘 자리 앞에 앞 조각만 남긴다 — 표지가 아니고(JaCoCo 는 마지막 `/` · `$` 뒤만 본다), 마지막 조각은 멈춘 자리 뒤라
// 이 꼬리가 낸다. kotlin 이 같은 꼴의 앞 조각까지 내는 것은 묶음을 넘는 스캐너 때문에 시작을 앞으로 옮겨서다(java 에는 그런 스캐너가 없다).
const J_RAW = new RegExp(`(?<!${J_ID})(?=${J_ID}*Generated)${J_ID}+`, 'gu')
function javaRawTail(t, stop) {
  const hits = []
  if (stop < 0) return hits
  J_RAW.lastIndex = stop
  for (let m; (m = J_RAW.exec(t)); ) hits.push({ at: m.index, start: m.index, end: m.index + m[0].length, fallback: true })
  return hits
}
// 한 파일의 표지 — decode(java 의 \uXXXX)가 있으면 푼 원문에서, mask 가 있으면 주석 · 리터럴을 빈칸으로 가린 원문에서 맞추고, 자리 · 표기는
// 원문으로 돌려 댄다. 표기는 전역 정규식이거나 (원문, 가리기가 멈춘 자리) → [{ at, start, end }] 함수다(at 은 줄을 댈 자리 · [start, end) 는 표기). 찍는 표기는
// MARK_SHOWN 글자에서 자른다 — 한 목록의 이름마다 그 목록 전체를 찍으면(`@[Generated × k]`) 출력이 k 의 제곱이다.
const MARK_SHOWN = 200
function markHits(m, text) {
  const dec = m.decode ? m.decode(text) : null
  const src = dec ? dec.text : text
  const { text: scan, stop } = m.mask ? m.mask(src) : { text: src, stop: -1 }
  const back = (k) => (dec ? dec.at[k] : k)
  const found = []
  for (const mk of m.marks)
    for (const h of mk instanceof RegExp ? [...scan.matchAll(mk)].map((x) => ({ at: x.index, start: x.index, end: x.index + x[0].length })) : mk(scan, stop))
      found.push(h)
  // fallback 표기는 다른 표기 [start, end) 안에 서면 뺀다 — 시작 순으로 한 번 훑는다(같은 자리면 fallback 이 뒤다).
  found.sort((x, y) => x.start - y.start || (x.fallback ? 1 : 0) - (y.fallback ? 1 : 0))
  const hits = []
  let covered = -1
  for (const h of found) {
    if (h.fallback && h.at < covered) continue
    if (!h.fallback && h.end > covered) covered = h.end
    const a = back(h.start)
    const b = back(h.end)
    const tok = text.slice(a, Math.min(b, a + MARK_SHOWN)).trim().replace(/\s+/g, ' ')
    hits.push({ at: back(h.at), tok: b - a > MARK_SHOWN ? `${tok} …` : tok })
  }
  return hits
}
const UNIT_MARKS = {
  // ast-v8-to-istanbul 1.0.7(@vitest/coverage-v8 5.1.0 이 v8 범위를 옮기는 것) dist/index.mjs:192 의 두 규칙 — 주석의 `if · else · next · file` 와
  // 줄 어디든의 `start · stop` — 을 합쳤다(주석 머리의 `^\s*` 는 뗐다).
  node: { roots: ['node/src'], marks: [/(?:istanbul|[cv]8|node:coverage)\s+ignore\s+(?:if|else|next|file|start|stop)(?=\W|$)/g] },
  python: { roots: ['python/src'], marks: [pyMark('cover'), pyMark('branch')] },
  // php-code-coverage 12.5.7 — 한 줄 주석 `// @codeCoverageIgnore[Start|End]`(ParsingSourceAnalyser.php:134–149) · 문서 주석의 `@codeCoverageIgnore`
  // (IgnoredLinesFindingVisitor.php:111) · 이름이 `PHPUnit\Framework\Attributes\CodeCoverageIgnore` 로 풀리는 속성(같은 파일 :78–79 — 별칭 import 도
  // NameResolver 가 먼저 푼다). 두 꼴(`@codeCoverageIgnore…` · `CodeCoverageIgnore`)을 본다.
  php: { roots: ['php/src'], marks: [/@?[cC]odeCoverageIgnore\w*/g] },
  // coverlet.collector 10.1.1 의 coverlet.core.dll(net8.0 · net10.0 · netstandard2.0)에 사용자 문자열로 나란히 든 특성 이름 둘 —
  // `ExcludeFromCoverageAttribute` · `ExcludeFromCodeCoverageAttribute`. 별칭(`using X = …Attribute;`)도 그 이름을 쓴다. MSBuild 가 프로젝트마다
  // Directory.Build.{props,targets} 도 읽는다(also — 추적되지 않으면 목록에 없다) — 그 `<Using Include="…" Alias="…" />` 는 dotnet/src 의 소스에 그
  // 특성을 다른 이름으로 들인다. MSBuild 는 위로 올라가며 처음 만난 props 와 targets 를 따로 싣는다(dotnet/ 에 props 만 있으면 뿌리의 targets 가 실린다
  // — 실측 SDK 8.0.428) — 그래서 dotnet/ 과 저장소 뿌리의 넷을 다 읽는다. 공허 판정은 roots(dotnet/src)로만 한다.
  dotnet: {
    roots: ['dotnet/src'],
    also: ['dotnet/Directory.Build.props', 'dotnet/Directory.Build.targets', 'Directory.Build.props', 'Directory.Build.targets'],
    marks: [/ExcludeFrom(?:Code)?Coverage\w*/g],
  },
  java: { roots: [':(glob)java/*/src/main/java/**'], shown: 'java/*/src/main/java', decode: javaUnicode, mask: javaMask, marks: [JAVA_MARK, javaRawTail] },
  kotlin: { roots: ['kotlin/src/main/kotlin'], mask: kotlinMask, marks: [KOTLIN_MARK, kotlinLists, kotlinAliases, kotlinAnnotationClasses, kotlinRawTail] },
  // SimpleCov 1.2.0 — `:nocov:` 토글(lines_classifier.rb:27 `/^(\s*)#(\s*)(:nocov:)/` — 토큰은 기본값이다, spec_helper 가 안 바꾼다)과 그 대체
  // `# simplecov:disable`(directive.rb 의 PATTERN — 코드 뒤에 붙은 한 줄 꼴도).
  ruby: { roots: ['ruby/lib'], marks: [/^[^\S\n]*#[^\S\n]*:nocov:/gm, /#[^\S\n]*simplecov[^\S\n]*:[^\S\n]*disable\b/g] },
  rust: { roots: ['rust/src'], marks: [/\bcoverage\s*\(\s*off\s*\)/g] },
  go: { why: 'go tool cover has no exclusion marker' },
}

// ── CLI ──────────────────────────────────────────────────────────────────────────────────
function usage(msg) {
  if (msg) console.error(msg)
  console.error(`usage: node scripts/integration-coverage.mjs <${LANGS.join('|')}> [--out DIR]`)
  console.error(`       node scripts/integration-coverage.mjs run|report <${LANGS.join('|')}> [ROOT] [--out DIR]`)
  console.error('       node scripts/integration-coverage.mjs check [ROOT]')
  console.error(`       node scripts/integration-coverage.mjs unit|unit-report <${UNIT_LANGS.join('|')}> [ROOT] [--out DIR]`)
  process.exit(2)
}
const argv = process.argv.slice(2)
let cmd = argv[0]
let rest = argv.slice(1)
// `langs` — 이 장부가 재는 언어 집합을 내보낸다(`covered <언어>`). `scripts/test/test-lang-universe.sh` 가 트리의 언어 집합과
// 분할로 대조한다 — 열 번째 언어가 이 손 목록을 조용히 건너뛰지 못하게(등록부 symmetry-guards-cover-a-subset).
if (cmd === 'langs' && rest.length === 0) {
  for (const l of LANGS) console.log(`covered ${l}`)
  process.exit(0)
}
// `unit-langs` — 단위 미도달 장부가 재는 언어(같은 꼴). 레인 배선 시험(`test-integration-coverage-gate.sh`)이 언어마다 게이트 줄을 찾는다.
if (cmd === 'unit-langs' && rest.length === 0) {
  for (const l of UNIT_LANGS) console.log(`covered ${l}`)
  process.exit(0)
}
if (cmd !== undefined && !['run', 'report', 'check', 'unit', 'unit-report'].includes(cmd) && !cmd.startsWith('-')) {
  rest = argv
  cmd = 'local'
}
let out = null
const pos = []
for (let i = 0; i < rest.length; i++) {
  const a = rest[i]
  if (a === '--out') {
    out = rest[++i]
    if (!out) usage('--out needs a directory')
  } else if (a.startsWith('--out=')) out = a.slice(6)
  else if (a.startsWith('-')) usage(`unknown option: ${a}`)
  else pos.push(a)
}
let lang = null
let root = null
if (cmd === 'check') {
  if (pos.length > 1) usage(`too many arguments: ${pos.join(' ')}`)
  root = pos[0] ?? null
} else if (['local', 'run', 'report'].includes(cmd)) {
  lang = pos[0]
  if (!LANGS.includes(lang)) usage(`this pilot measures ${LANGS.join(' · ')} — got ${lang ?? 'nothing'}`)
  if (pos.length > (cmd === 'local' ? 1 : 2)) usage(`too many arguments: ${pos.join(' ')}`)
  root = pos[1] ?? null
} else if (cmd === 'unit' || cmd === 'unit-report') {
  lang = pos[0]
  if (!UNIT_LANGS.includes(lang)) usage(`the unit-unreached ledger measures ${UNIT_LANGS.join(' · ')} — got ${lang ?? 'nothing'}`)
  if (pos.length > 2) usage(`too many arguments: ${pos.join(' ')}`)
  root = pos[1] ?? null
} else usage(cmd ? `unknown command: ${cmd}` : '')
root = resolve(root ?? join(dirname(fileURLToPath(import.meta.url)), '..'))
const rootPosix = root.replace(/\\/g, '/')
// 어느 스위트의 데이터인가 — 단위 미도달 장부(`unit` · `unit-report`)는 단위, 그 밖은 통합이다. 단위의 데이터 · 기록 · 생성물은 `.unit`
// 이 붙은 이름이라 같은 --out 을 줘도 통합의 것을 덮거나 읽지 않는다(기록의 `suite` 가 한 번 더 가른다 — 리더).
const SUITE = cmd === 'unit' || cmd === 'unit-report' ? 'unit' : 'integration'
const TAG = SUITE === 'unit' ? '.unit' : ''
// 그 데이터를 쓰는 명령 — 판정 문구가 「무엇을 다시 돌릴지」로 댄다(`run <언어>` · `unit <언어>`).
const RUN_CMD = SUITE === 'unit' ? 'unit' : 'run'
out = resolve(out ?? join(tmpdir(), SUITE === 'unit' ? 'kcsdk-unit-unreached' : 'kcsdk-integration-coverage', lang ?? ''))

// ── 판정 기록 ─────────────────────────────────────────────────────────────────────────────
const findings = []
const fail = (l, msg) => void findings.push({ kind: 'FAIL', lang: l, msg })
const drift = (l, msg) => void findings.push({ kind: 'DRIFT', lang: l, msg })
// admin 표면의 함수가 통합 실행에서 한 번도 안 돌았고 소유자도 없다 — 경고(DRIFT)가 아니라 게이트(exit 4)다.
const unexercised = (l, msg) => void findings.push({ kind: 'UNEXERCISED', lang: l, msg })
const fails = (l) => findings.some((f) => f.kind === 'FAIL' && (f.lang === l || f.lang === null))
const pct = (c, t) => (t ? `${((100 * c) / t).toFixed(1)}%` : 'n/a')
const sortU = (xs) => [...new Set(xs)].sort()

// ── 파생 — 측정 트리 자신의 coverage-boundary 로 ──────────────────────────────────────────
// ⚠️ 그 도구는 **어느** 언어든 FAIL 이면 exit 2 다. 다른 언어의 파생 실패가 이 언어를 막지 않도록 종료코드가 아니라
// JSON 의 `findings` 를 언어별로 본다. 이 언어의 전개가 없으면(FAIL 이든 아니든) 리포트하지 않는다.
let derivation
function derive() {
  if (derivation !== undefined) return derivation
  derivation = null
  const tool = join(root, BOUNDARY)
  if (!existsSync(tool)) {
    fail(null, `${BOUNDARY} is missing from ${rootPosix} — the boundary cannot be derived`)
    return null
  }
  const r = spawnSync(process.execPath, [tool, 'list', root, '--json'], { encoding: 'utf8', maxBuffer: 64 << 20 })
  let j
  try {
    j = JSON.parse(r.stdout)
  } catch {
    const first = `${r.stderr || ''}${r.stdout || ''}`.trim().split('\n')[0] ?? ''
    fail(null, `${BOUNDARY} list --json did not return JSON (exit ${r.status ?? r.signal}): ${first}`)
    return null
  }
  if (!j || typeof j.langs !== 'object' || j.langs === null || !Array.isArray(j.findings)) {
    fail(null, `${BOUNDARY} list --json returned an unexpected shape (want { langs, findings })`)
    return null
  }
  derivation = j
  return j
}
function derivedFor(l) {
  const j = derive()
  if (!j) return null
  const mine = j.findings.filter((f) => f.lang === l)
  for (const f of mine) fail(l, `coverage-boundary could not derive the boundary — ${f.site}: ${f.msg}`)
  if (mine.length) return null
  const d = j.langs[l]
  if (!d) {
    fail(l, `coverage-boundary returned no derivation for ${l}`)
    return null
  }
  if (!Array.isArray(d.files) || d.files.length === 0) {
    fail(l, 'the derived boundary is empty — a report over no files is vacuous')
    return null
  }
  return d
}

// ── 핀 · 소유자 · 등록부 ──────────────────────────────────────────────────────────────────
let pins
function loadPins() {
  if (pins !== undefined) return pins
  pins = null
  let p
  try {
    p = JSON.parse(readFileSync(join(root, PINS), 'utf8'))
  } catch {
    fail(null, `${PINS} is missing or not JSON`)
    return null
  }
  if (!p || typeof p !== 'object' || Array.isArray(p)) {
    fail(null, `${PINS} must be an object keyed by language`)
    return null
  }
  for (const k of Object.keys(p)) if (!LANGS.includes(k)) fail(null, `${PINS} names ${k}, which this pilot does not measure (${LANGS.join(' · ')})`)
  pins = p
  return p
}
function pinFor(l) {
  const p = loadPins()
  if (!p) return null
  const e = p[l]
  if (!e) {
    fail(l, `${PINS} has no pin for ${l}`)
    return null
  }
  if (!Array.isArray(e.pinned) || !e.pinned.every((x) => typeof x === 'string')) {
    fail(l, `${PINS}: ${l}.pinned must be an array of repository paths`)
    return null
  }
  const owners = e.owners ?? {}
  if (typeof owners !== 'object' || owners === null || Array.isArray(owners) || !Object.values(owners).every((v) => typeof v === 'string')) {
    fail(l, `${PINS}: ${l}.owners must map "<file>:<function>" to a registry id`)
    return null
  }
  // 하한 — 없으면 보고 모드. 잘못 적은 하한을 무시하면 하한이 꺼진 줄 모르므로 무결성 실패다.
  let floor = null
  if (e.floor !== undefined) {
    const f = e.floor
    if (typeof f !== 'object' || f === null || Array.isArray(f) || !FLOOR_METRICS[l].includes(f.metric)) {
      fail(l, `${PINS}: ${l}.floor.metric must be one of ${FLOOR_METRICS[l].join(' · ')}`)
      return null
    }
    if (typeof f.percent !== 'number' || !(f.percent > 0 && f.percent <= 100)) {
      fail(l, `${PINS}: ${l}.floor.percent must be a number in (0, 100]`)
      return null
    }
    floor = { metric: f.metric, percent: f.percent }
  }
  // admin 표면 — 이 파일들의 함수는 통합 실행에서 돌거나 열린 항목이 소유해야 한다(아니면 exit 4). 25 연산(users · clients ·
  // realms · roles · groups × 다섯) 하나를 통합 스위트에서 지우면 그 함수가 미실행이 된다. 핀(경계) 안이면 같은 판정을 쓰고,
  // 핀 밖이면(단위로 재는 리소스 파일 — node · python · java) 같은 실행의 데이터를 그 파일로 한 번 더 읽는다. 수치 · 하한에는
  // 섞지 않는다. 없으면 이 판정이 꺼진다 — 목록을 비우는 것은 그 diff 가 판정이다. `unit:ledger` 는 받지 않는다(DRIFT — ownerProblem).
  let surface = []
  if (e.surface !== undefined) {
    if (!Array.isArray(e.surface) || e.surface.length === 0 || !e.surface.every((x) => typeof x === 'string')) {
      fail(l, `${PINS}: ${l}.surface must be a non-empty array of repository paths`)
      return null
    }
    const sorted = sortU(e.surface)
    if (sorted.length !== e.surface.length || sorted.some((x, i) => x !== e.surface[i])) {
      fail(l, `${PINS}: ${l}.surface must be sorted and free of duplicates`)
      return null
    }
    for (const f of e.surface) if (!existsSync(join(root, f))) fail(l, `${PINS}: ${l}.surface names ${f}, which is not in the tree`)
    surface = e.surface
  }
  // 하네스 소유의 연결(아래 「하네스 소유」) — 꼴이 틀리면 무결성 실패다(무시하면 소유가 꺼진 줄 모른다). 연결이 서는지는
  // 소유 판정(DRIFT)이 본다.
  const harness = e.harness ?? {}
  const recOk = (r) => typeof r === 'object' && r !== null && !Array.isArray(r) && sortU(Object.keys(r)).join() === HARNESS_KEYS.join() && HARNESS_KEYS.every((k) => typeof r[k] === 'string' && r[k] !== '')
  if (typeof harness !== 'object' || harness === null || Array.isArray(harness) || !Object.values(harness).every(recOk)) {
    fail(l, `${PINS}: ${l}.harness must map a pinned file to { ${HARNESS_KEYS.join(', ')} } (repository paths)`)
    return null
  }
  return { pinned: e.pinned, owners, floor, surface, harness }
}
const floorText = (pin) => (pin?.floor ? `floor ${pin.floor.metric} ≥ ${pin.floor.percent}%` : null)
// run 이 바이트를 기록할 admin 표면 파일 — 판정은 report 가 한다. 여기서는 핀이 깨져 있어도 실패하지 않고 빈 목록이다
// (run 의 종료코드는 테스트의 것이다).
function surfaceOf(l) {
  try {
    const s = JSON.parse(readFileSync(join(root, PINS), 'utf8'))?.[l]?.surface
    return Array.isArray(s) ? s.filter((x) => typeof x === 'string') : []
  } catch {
    return []
  }
}
// 파생 = 핀. 다르면 어느 쪽에만 있는지 이름으로 댄다.
function matchesPin(l, d, pin) {
  const D = new Set(d.files)
  const P = new Set(pin.pinned)
  const extra = sortU(d.files.filter((f) => !P.has(f)))
  const missing = sortU(pin.pinned.filter((f) => !D.has(f)))
  if (!extra.length && !missing.length) return true
  const parts = []
  if (extra.length) parts.push(`derived, not pinned: ${extra.join(', ')}`)
  if (missing.length) parts.push(`pinned, not derived: ${missing.join(', ')}`)
  fail(l, `the derived boundary differs from the pin in ${PINS} — ${parts.join(' · ')}`)
  return false
}
// 등록부의 항목은 **열 0** 의 체크박스 줄이다(`test-remaining-work-shape.sh` 와 같은 정의). 들여쓴 하위 불릿은 항목이 아니다.
let registry
function loadRegistry() {
  if (registry !== undefined) return registry
  registry = null
  const f = join(root, REGISTRY)
  if (!existsSync(f)) {
    fail(null, `${REGISTRY} is missing — owners cannot be checked against open items`)
    return null
  }
  const open = new Set()
  let items = 0
  for (const l of readFileSync(f, 'utf8').replace(/\r\n/g, '\n').split('\n')) {
    const m = l.match(/^- \[([ x])\] `([a-z0-9][a-z0-9-]*)`/)
    if (!m) continue
    items++
    if (m[1] === ' ') open.add(m[2])
  }
  // 공허 방지 — 표기가 바뀌어 0 건을 읽으면 모든 소유자가 「열린 항목 아님」이 되어 원인이 가려진다.
  if (!items) {
    fail(null, `${REGISTRY} has no items — the item format changed or the file is empty`)
    return null
  }
  registry = { open }
  return registry
}

// ── 하네스 소유 — 통합 스위트가 아니라 설치 하네스가 실행하는 파일 ───────────────────────────────
// 단위 omit 집합에는 경계가 아닌 파일도 든다 — java 의 jacoco.skip 모듈(예제)은 coverage-boundary 가 일부러 넣는다(모듈 하나를
// 통째로 건너뛰는 변이가 조용히 지나가지 않게). 그 함수는 통합 스위트가 안 돌리지만 갭이 아니다 — 설치 하네스(harness.yml 의
// install-all · 릴리스의 install-smoke)가 실서버에 대고 돌린다. `owners` 의 값 `harness:install` 이 그것이고, 같은 JSON 의
// `harness` 가 그 파일을 돌리는 세 파일을 댄다. 이 리더는 그 연결을 트리에서 확인할 때만 소유로 친다(아니면 DRIFT):
//   image      마지막 단계의 주석 아닌 `COPY` 가 그 파일(이나 조상 디렉터리)을 넣고, 뒤의 COPY 가 그 자리(나 조상)로 오지 않으며
//              뒤에 `RUN` 도 없다(그 파일을 고칠 수 있다) — project · entrypoint 도 같다. CMD/ENTRYPOINT 가 entrypoint 를 돌린다.
//   project    그 파일이 project 옆 `src/main/java/` 아래에 떨어지고, project(pom)의 `<exec.mainClass>` 가 하나이고 그 클래스다.
//              `<skip>` · `<exec.skip>` · 플러그인 설정의 `<mainClass>`(속성을 이긴다)가 없다.
//   entrypoint `if <… -f <project> … exec:java …>; then` 바로 다음 줄이 `: > "$STATUS/quickstart.ok"` 다. 조건에 `!` · `|` · `;` ·
//              단독 `&` 가 없고(있으면 실행이 실패해도 표지가 선다) `-Dexec.*` · `-Dskip` · `--file` · 두 번째 `-f` 도 없다. 표지를
//              쓰는 줄은 그 한 줄이다(`rm` 은 된다). 표지에서 판정까지(quickstartOk → install-matrix --strict)는 하네스 자신의 시험이
//              소유한다.
// ⚠️ 연결은 파일 단위지만 소유는 함수 단위다 — 파일에 함수가 늘면 그 함수도 소유자 항목을 받아야 한다(main 이 그 함수를 부르는지는
//    이 리더가 보지 않는다 — 검토자의 판정이다). 실행 스크립트가 돌리기 전에 그 파일을 고치는 것 · 변수로 만든 표지 이름도 보지
//    않는다.
// ⚠️ java(Maven exec:java)만 읽는다 — 다른 언어의 기록은 확인할 수 없으므로 DRIFT 다.
const HARNESS_OWNER = 'harness:install'
const HARNESS_KEYS = ['entrypoint', 'image', 'project']
// 단위 소유 — 단위 장부가 재는 만큼 단위 스위트가 다 닿는 함수(머리 주석 · 판정은 ownerProblem). 등록부 id 는 `:` 를 담지 않아 이 값과 겹치지 않는다.
const UNIT_OWNER = 'unit:ledger'
// Dockerfile 의 명령 — 주석 줄(첫 비공백이 `#`)을 먼저 버리고 줄 이음(`\` + 줄끝)을 잇는다(Docker 와 같은 순서 — 이어진 명령 속의
// 주석 줄은 명령을 끊지 않는다). 줄 중간의 `#` 는 주석이 아니다.
function dockerInstructions(text) {
  const kept = text.replace(/\r\n/g, '\n').split('\n').filter((x) => !/^\s*#/.test(x)).join('\n')
  const res = []
  for (const line of kept.replace(/\\[ \t]*\n/g, ' ').split('\n')) {
    const m = /^\s*([A-Za-z]+)\s+(.*?)\s*$/.exec(line)
    if (m) res.push({ op: m[1].toUpperCase(), args: m[2] })
  }
  return res
}
// 명령의 인자 — JSON 꼴(`["a", "b"]`)이면 그 배열, 아니면 공백으로 나눈 것. 못 읽는 JSON 꼴은 null(인정하지 않는다).
function dockerArgs(args) {
  if (!args.startsWith('[')) return args.split(/\s+/).filter(Boolean)
  try {
    const a = JSON.parse(args)
    return Array.isArray(a) && a.every((x) => typeof x === 'string') ? a : null
  } catch {
    return null
  }
}
// 최종 이미지(마지막 단계)가 빌드 맥락에서 받는 COPY 와 실행 명령. 대상은 WORKDIR 를 따라 절대 경로로 푼다(못 풀면 그 COPY 는
// 인정하지 않는다). `--from` 은 다른 단계에서 오고 `--parents` 는 경로 규칙이 달라 건너뛴다. 와일드카드는 읽지 않는다.
function dockerImage(text) {
  let wd = null
  let copies = []
  let runs = []
  let cmd = []
  let entry = []
  for (const { op, args } of dockerInstructions(text)) {
    if (op === 'FROM') {
      wd = null
      copies = []
      runs = []
      cmd = []
      entry = []
    } else if (op === 'RUN') {
      // 그때까지의 COPY 수 — 이 RUN 은 그 앞의 COPY 가 넣은 파일을 고칠 수 있다.
      runs.push(copies.length)
    } else if (op === 'WORKDIR') {
      const w = dockerArgs(args)?.[0] ?? ''
      wd = w.startsWith('/') ? posix.normalize(w) : wd && w ? posix.join(wd, w) : null
    } else if (op === 'COPY') {
      const a = dockerArgs(args)
      if (!a || a.some((x) => /^--(from|parents)(=|$)/.test(x))) continue
      const rest = a.filter((x) => !x.startsWith('--'))
      if (rest.length < 2) continue
      const raw = rest[rest.length - 1]
      const dest = raw.startsWith('/') ? posix.normalize(raw) : wd ? posix.join(wd, raw) : null
      if (dest) copies.push({ srcs: rest.slice(0, -1), dest: dest.length > 1 ? dest.replace(/\/+$/, '') : dest, dir: rest.length > 2 || raw.endsWith('/') })
    } else if (op === 'CMD' || op === 'ENTRYPOINT') {
      const a = dockerArgs(args) ?? []
      if (op === 'CMD') cmd = a
      else entry = a
    }
  }
  return { copies, runs, start: [...entry, ...cmd] }
}
// 빌드 맥락의 `file` 이 이 COPY 로 이미지의 어디에 떨어지는가(안 떨어지면 null). 디렉터리 소스는 그 **내용**이 대상 아래로 간다
// (디렉터리 자신이 아니다 — Docker 의 COPY). 소스가 여럿이거나 대상이 `/` 로 끝나면 대상은 디렉터리다.
function landing(copy, file) {
  for (const src of copy.srcs) {
    const s = posix.normalize(src).replace(/^\/+/, '').replace(/\/+$/, '') || '.'
    if (s === '.') return posix.join(copy.dest, file)
    if (s === file) return copy.dir ? posix.join(copy.dest, posix.basename(file)) : copy.dest
    if (file.startsWith(`${s}/`)) return posix.join(copy.dest, file.slice(s.length + 1))
  }
  return null
}
// 그 파일을 넣는 마지막 COPY 의 자리. 뒤의 COPY 가 그 자리나 조상 디렉터리로 오면 덮였을 수 있고(보수적이다 — 덮는 쪽에 그
// 파일이 없어도), 뒤에 RUN 이 있으면 고쳐졌을 수 있다 — 둘 다 인정하지 않는다.
function placed(img, file) {
  let at = -1
  img.copies.forEach((c, i) => {
    if (landing(c, file)) at = i
  })
  if (at < 0) return {}
  const to = landing(img.copies[at], file)
  const by = img.copies.slice(at + 1).find((c) => c.dest === '/' || c.dest === to || to.startsWith(`${c.dest}/`))
  return { to, by, rewritten: img.runs.some((n) => n > at) }
}
const harnessMemo = new Map()
// 연결이 서면 null, 아니면 그 까닭(파일마다 한 번 잰다).
function harnessWhy(l, file, rec) {
  const k = `${l}\0${file}`
  if (!harnessMemo.has(k)) harnessMemo.set(k, harnessLink(l, file, rec))
  return harnessMemo.get(k)
}
function harnessLink(l, file, rec) {
  if (l !== 'java') return `this reader checks the java link only (Maven exec:java) — a ${l} record cannot be verified`
  const text = {}
  for (const k of HARNESS_KEYS) {
    if (!existsSync(join(root, rec[k]))) return `${k} ${rec[k]} is not in the tree`
    text[k] = readFileSync(join(root, rec[k]), 'utf8').replace(/\r\n/g, '\n')
  }
  const img = dockerImage(text.image)
  const at = {}
  for (const [k, f] of [['file', file], ['project', rec.project], ['entrypoint', rec.entrypoint]]) {
    const p = placed(img, f)
    if (!p.to) return `${rec.image} does not COPY ${f} into the final image`
    if (p.by) return `${rec.image}: a later COPY to ${p.by.dest} may overwrite ${f} at ${p.to}`
    if (p.rewritten) return `${rec.image}: a RUN after the COPY of ${f} may rewrite it at ${p.to}`
    at[k] = p.to
  }
  if (!img.start.includes(at.entrypoint)) return `${rec.image}: CMD/ENTRYPOINT does not run ${at.entrypoint} (${rec.entrypoint})`
  const src = `${posix.dirname(at.project)}/src/main/java/`
  if (!at.file.startsWith(src) || !at.file.endsWith('.java')) return `${file} lands at ${at.file}, outside the source root ${src} of ${at.project}`
  const cls = at.file.slice(src.length, -'.java'.length).replace(/\//g, '.')
  // 주석은 같은 길이의 공백으로 지운다(java run 의 pom 과 같은 이유 — 지워 붙이면 새 `<!--` 가 생길 수 있다).
  const pom = text.project.replace(/<!--[\s\S]*?-->/g, (m) => m.replace(/[^\n]/g, ' '))
  const mains = [...pom.matchAll(/<exec\.mainClass>\s*([^<]*?)\s*<\/exec\.mainClass>/g)].map((m) => m[1])
  if (mains.length !== 1 || mains[0] !== cls) return `${rec.project} must name ${cls} as its one <exec.mainClass> (found ${mains.join(', ') || 'none'})`
  // 실행을 끄거나(`<skip>` · `<exec.skip>`) 플러그인 설정의 `<mainClass>` 가 속성을 이기면 그 클래스가 안 돈다(독립 레그 지목).
  if (/<skip>|<exec\.skip>|<mainClass>/.test(pom)) return `${rec.project} overrides the run — <skip>, <exec.skip> or a plugin <mainClass>`
  const lines = text.entrypoint.split('\n').filter((x) => !/^\s*#/.test(x)).join('\n').replace(/\\[ \t]*\n/g, ' ').split('\n').map((x) => x.trim()).filter(Boolean)
  // 실행이 실패해도 조건이 참일 수 있는 꼴 — 부정 · 파이프 · `||` · `;` · 배경 실행(`2>&1` · `&&` · `&>` 는 아니다).
  const unsafe = (c) => /^!/.test(c) || /[|;]/.test(c) || /(^|[^>&])&(?![&>])/.test(c)
  // 프로젝트를 그대로 돌리지 않는 꼴 — 실행을 끄거나(-Dexec.skip · -Dskip) 진입점을 바꾸거나(-Dexec.mainClass) 다른 pom 을 준다.
  const overrides = (t) => t.some((w) => /^-D(exec\.|skip\b)/.test(w) || /^--file\b/.test(w)) || t.filter((w) => w === '-f').length !== 1
  const i = lines.findIndex((x) => {
    const m = /^if\s+(.*?)\s*;\s*then$/.exec(x)
    if (!m || unsafe(m[1])) return false
    const t = m[1].split(/\s+/)
    return !overrides(t) && t.includes('exec:java') && t.some((w, j) => w === '-f' && t[j + 1] === at.project)
  })
  if (i < 0) return `${rec.entrypoint} has no \`if … -f ${at.project} … exec:java …; then\` whose condition fails when the run fails (no !, |, ; or lone &) and runs the project as it is (no -Dexec.*, -Dskip, --file or second -f)`
  if (!/^:\s*>\s*"?\$\{?STATUS\}?\/quickstart\.ok"?$/.test(lines[i + 1] ?? '')) return `${rec.entrypoint}: the line after that if is not : > "$STATUS/quickstart.ok"`
  // 표지는 그 한 줄만 쓴다 — else 갈래나 다른 자리에서도 쓰면 실행이 실패해도 표지가 선다(독립 레그 지목). 지우는 줄(rm)은 된다.
  const stray = lines.find((x, j) => j !== i + 1 && x.includes('quickstart.ok') && !/^rm\s/.test(x))
  if (stray) return `${rec.entrypoint}: quickstart.ok is written outside that if too — ${stray}`
  return null
}
// 소유자 판정 — 열린 등록부 항목이거나, 트리에서 확인되는 하네스 연결이거나, 단위 장부가 다 닿는다고 보이는 함수다. 문제가 없으면 null.
function ownerProblem(l, pin, reg, key, id) {
  if (id === HARNESS_OWNER) {
    const file = key.slice(0, key.indexOf(':'))
    const rec = pin.harness[file]
    if (!rec) return `${key} is owned by ${HARNESS_OWNER}, but ${PINS} has no ${l}.harness record for ${file}`
    const why = harnessWhy(l, file, rec)
    return why ? `${key} is owned by ${HARNESS_OWNER}, but the link does not hold — ${why}` : null
  }
  if (id === UNIT_OWNER) {
    // 그 언어의 장부가 없거나 꼴이 틀리면 unitLedgerFor 가 이미 FAIL 이다 — 소유로 치지 않는다.
    const ledger = unitLedgerFor(l)
    if (!ledger) return null
    // admin 표면 파일은 받지 않는다 — 그 함수는 통합 실행에서 돌거나 열린 항목이 소유해야 한다(exit 4 관문 · pinFor 의 「admin 표면」).
    // 단위 장부가 다 닿아도 그 관문을 대신하지 않는다. 표면 밖 소유자 파일은 핀 안이다(check 가 둘 다 밖인 키를 DRIFT 로 낸다).
    const file = key.slice(0, key.indexOf(':'))
    if (pin.surface.includes(file)) return `${key} is owned by ${UNIT_OWNER}, but ${file} is admin surface — the integration run must execute it, or an open item of ${REGISTRY} must own it`
    // 항목이 있으면 까닭이 무엇이든 거부한다 — `defensive:` 를 받으면 단위 시험의 갈래를 지우고 그렇게 적은 PR 이 두 검사를 다 지나,
    // 아무 스위트도 안 도는 갈래에 열린 소유자가 없다(Grok 레그 2026-11-28). 열린 id 가 다시 소유해야 한다.
    const e = ledger[key]
    return e ? `${key} is owned by ${UNIT_OWNER}, but ${UNIT} records ${UNIT_WHY.find((p) => e.why.startsWith(p)) ?? e.why} for it — name an open item of ${REGISTRY}` : null
  }
  return reg && !reg.open.has(id) ? `${key} is owned by ${id}, which is not an open item of ${REGISTRY}` : null
}

// ── go: 커버 프로필 + 소스의 함수 범위 ────────────────────────────────────────────────────
// 주석·문자열·룬·원시 문자열을 같은 길이의 공백으로 지운다(줄 번호 보존) — 그 안의 `{`·`}`·`func` 가 구조로 읽히면 안 된다.
function blankGo(src) {
  let res = ''
  for (let i = 0; i < src.length; ) {
    let j
    if (src.startsWith('//', i)) {
      j = src.indexOf('\n', i)
      if (j < 0) j = src.length
    } else if (src.startsWith('/*', i)) {
      j = src.indexOf('*/', i + 2)
      j = j < 0 ? src.length : j + 2
    } else if (src[i] === '`') {
      j = src.indexOf('`', i + 1)
      j = j < 0 ? src.length : j + 1
    } else if (src[i] === '"' || src[i] === "'") {
      const q = src[i]
      j = i + 1
      while (j < src.length && src[j] !== q && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1
      j = Math.min(src.length, j + 1)
    } else {
      res += src[i++]
      continue
    }
    res += src.slice(i, j).replace(/[^\n]/g, ' ')
    i = j
  }
  return res
}
// 최상위 함수 선언의 범위. gofmt 가 보장하는 모양에 기댄다: 최상위 `func` 는 열 0 에서 시작하고, 여러 줄 몸통은
// 열 0 의 `}` 한 글자 줄로 끝난다. 첫 줄에서 중괄호가 짝이 맞으면 한 줄 함수다(지운 뒤에 센다).
function goFuncs(file) {
  const L = blankGo(readFileSync(join(root, file), 'utf8').replace(/\r\n/g, '\n')).split('\n')
  const funcs = []
  for (let k = 0; k < L.length; k++) {
    if (!/^func\b/.test(L[k])) continue
    const m = L[k].match(/^func\s*(?:\(([^)]*)\)\s*)?([A-Za-z_]\w*)/)
    if (!m) {
      fail('go', `${file}:${k + 1}: cannot read the function name`)
      return null
    }
    let name = m[2]
    if (m[1] !== undefined) {
      // 수신자의 마지막 식별자가 타입이다(`a *AdminClient` · `*AdminClient` · `r *Store[K, V]`).
      const r = m[1].trim().match(/([A-Za-z_]\w*)(?:\[[^\]]*\])?$/)
      if (!r) {
        fail('go', `${file}:${k + 1}: cannot read the receiver type of ${name}`)
        return null
      }
      name = `${r[1]}.${name}`
    }
    const opens = (L[k].match(/\{/g) ?? []).length
    const closes = (L[k].match(/\}/g) ?? []).length
    let end = k
    if (!(opens > 0 && opens === closes)) {
      end = L.findIndex((l, x) => x > k && l.replace(/\s+$/, '') === '}')
      if (end < 0) {
        fail('go', `${file}:${k + 1}: cannot find the end of ${name} (gofmt closes a top-level body with "}" at column 0)`)
        return null
      }
    }
    if (funcs.some((f) => f.name === name)) {
      fail('go', `${file}: two functions are both named ${name} — the never-executed list cannot tell them apart`)
      return null
    }
    funcs.push({ name, start: k + 1, end: end + 1, stmts: 0, covered: 0 })
  }
  return funcs
}
// 커버 프로필 — 통합(`run go`)은 `go.cover`, 단위 미도달 장부(`unit go`)는 `.unit` 이 붙은 이름과 그 실행의 기록이다(SUITE). 통합 run 은
// 기록을 쓰지 않는다(머리 주석).
const GO_DATA = () => join(out, `go${TAG}.cover`)
const GO_RUN = () => join(out, `go${TAG}.run.json`)
function goReport(d) {
  const path = GO_DATA()
  const shown = path.replace(/\\/g, '/')
  if (!existsSync(path)) {
    fail('go', `no coverage data at ${shown} — run the ${SUITE} suite first (node scripts/integration-coverage.mjs ${RUN_CMD} go)`)
    return null
  }
  const modFile = join(root, d.dir, 'go.mod')
  const mod = existsSync(modFile) ? readFileSync(modFile, 'utf8').match(/^module\s+(\S+)/m)?.[1] : null
  if (!mod) {
    fail('go', `${d.dir}/go.mod has no module line — profile paths cannot be mapped to files`)
    return null
  }
  const bytes = readFileSync(path)
  const lines = bytes.toString('utf8').replace(/\r\n/g, '\n').split('\n').filter(Boolean)
  const mode = /^mode: (set|count|atomic)$/.exec(lines[0] ?? '')?.[1]
  if (!mode) {
    fail('go', `${shown} is not a Go cover profile (first line: ${lines[0] ?? 'empty'})`)
    return null
  }
  // 같은 블록이 여러 번 나올 수 있다(여러 테스트 바이너리의 프로필을 합친 꼴) — 문장은 한 번, 덮임은 어느 쪽이든.
  const blocks = new Map()
  for (const l of lines.slice(1)) {
    const m = l.match(/^(.+):(\d+)\.(\d+),(\d+)\.(\d+) (\d+) (\d+)$/)
    if (!m) {
      fail('go', `cannot read the profile line: ${l}`)
      return null
    }
    if (!m[1].startsWith(`${mod}/`)) continue
    const file = `${d.dir}/${m[1].slice(mod.length + 1)}`
    const key = `${file}:${m[2]}.${m[3]},${m[4]}.${m[5]}`
    const n = Number(m[6])
    const c = Number(m[7])
    const b = blocks.get(key)
    if (!b) blocks.set(key, { file, line: Number(m[2]), n, c })
    else if (b.n !== n) {
      fail('go', `${key} appears with ${b.n} and ${n} statements — the profile contradicts itself`)
      return null
    } else b.c += c
  }
  const files = []
  const never = []
  // 함수마다 안 돈 문장 — 단위 미도달 장부(unitReport)가 쓴다(통합 리포트는 never 만 쓴다).
  const units = []
  for (const f of sortU(d.files)) {
    const bs = [...blocks.values()].filter((b) => b.file === f)
    if (!bs.length) {
      fail('go', `${f} is not in the coverage data — a boundary file the run never instrumented would silently leave the denominator`)
      continue
    }
    if (!existsSync(join(root, f))) {
      fail('go', `${f} is in the profile but not in the tree — the data belongs to another checkout`)
      continue
    }
    const funcs = goFuncs(f)
    if (!funcs) continue
    const outside = { stmts: 0, covered: 0 }
    let stmts = 0
    let covered = 0
    for (const b of bs) {
      stmts += b.n
      if (b.c > 0) covered += b.n
      const fn = funcs.find((x) => b.line >= x.start && b.line <= x.end) ?? outside
      fn.stmts += b.n
      if (b.c > 0) fn.covered += b.n
    }
    files.push({ file: f, stmts, covered, outside })
    for (const fn of funcs) if (fn.stmts > 0 && fn.covered === 0) never.push({ file: f, line: fn.start, name: fn.name, stmts: fn.stmts })
    for (const fn of funcs) units.push({ file: f, line: fn.start, name: fn.name, statements: fn.stmts - fn.covered })
  }
  if (SUITE !== 'unit') return { path, files, never }
  // ── 여기부터 단위 미도달 장부만 ──
  // 패키지 수준 함수 리터럴의 안 돈 문장은 어느 함수 선언에도 못 붙인다 — FAIL 이다(ruby 의 메서드 밖 갈래와 같은 판정 · 통합 리포트는 그
  // 문장을 파일 표의 package-level 로 보인다). 경계가 한 문장도 안 돈 실행이면 그 판정(ranNothing — 측정 실패)이 먼저다.
  if (files.some((x) => x.covered > 0)) {
    for (const x of files) if (x.outside.covered < x.outside.stmts) fail('go', `${x.file}: ${x.outside.stmts - x.outside.covered} of ${x.outside.stmts} package-level statements (a function literal outside every function declaration) never ran — no function can be credited with them`)
  }
  // run 기록 — php · ruby 와 같은 이유(손으로 돌린 실행 · 실패한 실행 · 다른 실행이 덮어쓴 프로필). 커버 프로필에는 소스 해시가 없어(블록은
  // 줄 · 열뿐이다) 경계 파일의 바이트도 기록과 대조한다(dotnet 과 같다). 다른 판정 뒤에 두되 앞의 실패가 있어도 낸다(두 까닭이 한 번에 보인다).
  const runRec = GO_RUN()
  let rec = null
  try {
    rec = JSON.parse(readFileSync(runRec, 'utf8'))
  } catch {
    rec = null
  }
  const isObj = (x) => x !== null && typeof x === 'object' && !Array.isArray(x)
  const sha = (b) => createHash('sha1').update(b).digest('hex')
  if (!isObj(rec) || rec.run !== 'go' || (rec.suite ?? 'integration') !== SUITE) {
    fail('go', `no record that \`${RUN_CMD} go\` wrote this data (${runRec.replace(/\\/g, '/')}) — run the suite through the script (node scripts/integration-coverage.mjs ${RUN_CMD} go) so the report can tell a complete, successful run`)
    return null
  }
  if (rec.exit !== 0) {
    fail('go', `the run that wrote this data exited ${rec.exit} — the data of a failed run is partial`)
    return null
  }
  if (rec.profile_sha1 !== sha(bytes)) {
    fail('go', `${shown} is not the data \`${RUN_CMD} go\` recorded (sha1 ${String(rec.profile_sha1).slice(0, 12)}… recorded, ${sha(bytes).slice(0, 12)}… now) — another run wrote over it`)
    return null
  }
  if (!isObj(rec.files)) {
    fail('go', 'the record has no boundary hashes — the boundary files changed while the suite ran, so the data may come from other bytes')
    return null
  }
  for (const f of d.files) {
    const now = existsSync(join(root, f)) ? sha(readFileSync(join(root, f))) : null
    if (rec.files[f] !== now) fail('go', `${f}: the data was taken from other bytes (sha1 ${String(rec.files[f]).slice(0, 12)}… recorded, ${String(now).slice(0, 12)}… in the tree) — rerun the suite on this tree`)
  }
  return { path, note: `mode ${mode}`, files, never, units }
}

// ── python: coverage.py JSON(format 3 — 함수 영역) ────────────────────────────────────────
function toRepoPath(key, dir) {
  const n = key.replace(/\\/g, '/')
  if (/^([A-Za-z]:)?\//.test(n)) {
    const pre = `${rootPosix}/`
    const win = /^[A-Za-z]:/.test(n)
    const hit = win ? n.toLowerCase().startsWith(pre.toLowerCase()) : n.startsWith(pre)
    return hit ? posix.normalize(n.slice(pre.length)) : n
  }
  return posix.normalize(`${dir}/${n}`)
}
// coverage.py 의 JSON — 통합(`run python`)은 `python.json`, 단위 미도달 장부(`unit python`)는 `.unit` 이 붙은 이름과 그 실행의 기록이다(SUITE).
// 통합 run 은 기록을 쓰지 않는다(머리 주석).
const PY_DATA = () => join(out, `python${TAG}.json`)
const PY_RUN = () => join(out, `python${TAG}.run.json`)
// 단위 장부가 영역마다 읽는 수 — 다 정수여야 한다(못 읽는 수를 0 으로 세지 않는다).
const PY_COUNTS = ['num_statements', 'covered_lines', 'missing_lines', 'num_branches', 'missing_branches']
function pyReport(d) {
  const path = PY_DATA()
  const shown = path.replace(/\\/g, '/')
  if (!existsSync(path)) {
    fail('python', `no coverage data at ${shown} — run the ${SUITE} suite first (node scripts/integration-coverage.mjs ${RUN_CMD} python)`)
    return null
  }
  const bytes = readFileSync(path)
  let j
  try {
    j = JSON.parse(bytes.toString('utf8'))
  } catch {
    fail('python', `${shown} is not JSON`)
    return null
  }
  if (j?.meta?.format !== 3 || typeof j.files !== 'object' || j.files === null) {
    fail('python', `${shown} is not a coverage.py JSON report of format 3 (function regions are required)`)
    return null
  }
  // 단위 미도달 장부는 가지도 센다 — 가지 없이 잰 데이터(branch = true 가 없는 실행)의 가지를 0 개로 세지 않는다.
  if (SUITE === 'unit' && j.meta.branch_coverage !== true) {
    fail('python', `${shown} has no branch arcs (meta.branch_coverage is not true) — the run measured lines only; unit python's generated configuration sets branch = true`)
    return null
  }
  const byPath = new Map()
  for (const [k, v] of Object.entries(j.files)) byPath.set(toRepoPath(k, d.dir), v)
  const files = []
  const never = []
  // 함수 영역마다 안 돈 문장 · 안 탄 가지 호 — 단위 미도달 장부(unitReport)가 쓴다(통합 리포트는 never 만 쓴다).
  const units = []
  for (const f of sortU(d.files)) {
    const v = byPath.get(f)
    if (!v) {
      fail('python', `${f} is not in the coverage data — a boundary file the run never instrumented would silently leave the denominator`)
      continue
    }
    if (!v.summary || typeof v.functions !== 'object' || v.functions === null) {
      fail('python', `${f}: the report has no function regions`)
      continue
    }
    const lines = { stmts: v.summary.num_statements, covered: v.summary.covered_lines }
    const bodies = { stmts: 0, covered: 0 }
    let sum = 0
    let unread = null
    const mine = []
    for (const [q, r] of Object.entries(v.functions)) {
      const s = r?.summary
      if (SUITE === 'unit' && !(s !== null && typeof s === 'object' && PY_COUNTS.every((k) => isCount(s[k])))) {
        unread = q
        break
      }
      sum += r.summary.num_statements
      if (q === '') continue
      bodies.stmts += r.summary.num_statements
      bodies.covered += r.summary.covered_lines
      if (r.summary.num_statements > 0 && r.summary.covered_lines === 0) never.push({ file: f, line: r.start_line, name: q, stmts: r.summary.num_statements })
      // 단위 장부의 수 — 영역 요약의 안 돈 문장 수 · 안 탄 호 수(안 돈 줄에서 나가는 호도 센다 — coverage.py 의 missing_branches).
      if (SUITE === 'unit') mine.push({ file: f, line: r.start_line, name: q, lines: s.missing_lines, branches: s.missing_branches })
    }
    if (unread !== null) {
      fail('python', `${f}: cannot read the line and branch counts of ${unread || 'the module-level region'} in ${shown}`)
      continue
    }
    if (sum !== lines.stmts) {
      fail('python', `${f}: function regions add up to ${sum} of ${lines.stmts} statements — coverage.py keys regions by name, so a same-named function overwrote another and the ${SUITE === 'unit' ? 'ledger' : 'never-executed list'} could miss it`)
      continue
    }
    files.push({ file: f, stmts: lines.stmts, covered: lines.covered, bodies, module: v.functions['']?.summary ?? null })
    units.push(...mine)
  }
  if (SUITE !== 'unit') return { path, files, never }
  // ── 여기부터 단위 미도달 장부만 ──
  // 모듈 수준 영역(이름 "" — 어느 함수에도 안 드는 모듈 · 클래스 몸통)의 안 돈 줄 · 안 탄 호는 어느 함수에도 못 붙인다 — FAIL 이다(go 의 패키지
  // 수준 함수 리터럴 · ruby 의 메서드 밖 갈래와 같은 판정). 그 코드는 import 때 돈다 — 경계 함수의 몸통이 한 줄도 안 돈 실행이면 그 판정
  // (ranNothing — 측정 실패)이 먼저다.
  if (files.some((x) => x.bodies.covered > 0)) {
    for (const x of files) {
      const m = x.module
      if (!m) continue
      if (m.missing_lines > 0) fail('python', `${x.file}: ${m.missing_lines} of ${m.num_statements} module-level statements (outside every function — module and class bodies) never ran — no function can be credited with them`)
      if (m.missing_branches > 0) fail('python', `${x.file}: ${m.missing_branches} of ${m.num_branches} module-level branch arcs (outside every function — module and class bodies) were never taken — no function can be credited with them`)
    }
  }
  // run 기록 — go 와 같은 이유(손으로 돌린 실행 · 실패한 실행 · 다른 실행이 덮어쓴 데이터). coverage.py 의 JSON 에는 소스 해시가 없어(줄
  // 번호뿐이다) 경계 파일의 바이트도 기록과 대조한다. 다른 판정 뒤에 두되 앞의 실패가 있어도 낸다(두 까닭이 한 번에 보인다).
  const runRec = PY_RUN()
  let rec = null
  try {
    rec = JSON.parse(readFileSync(runRec, 'utf8'))
  } catch {
    rec = null
  }
  const isObj = (x) => x !== null && typeof x === 'object' && !Array.isArray(x)
  const sha = (b) => createHash('sha1').update(b).digest('hex')
  if (!isObj(rec) || rec.run !== 'python' || (rec.suite ?? 'integration') !== SUITE) {
    fail('python', `no record that \`${RUN_CMD} python\` wrote this data (${runRec.replace(/\\/g, '/')}) — run the suite through the script (node scripts/integration-coverage.mjs ${RUN_CMD} python) so the report can tell a complete, successful run`)
    return null
  }
  if (rec.exit !== 0) {
    fail('python', `the run that wrote this data exited ${rec.exit} — the data of a failed run is partial`)
    return null
  }
  if (rec.data_sha1 !== sha(bytes)) {
    fail('python', `${shown} is not the data \`${RUN_CMD} python\` recorded (sha1 ${String(rec.data_sha1).slice(0, 12)}… recorded, ${sha(bytes).slice(0, 12)}… now) — another run wrote over it`)
    return null
  }
  if (!isObj(rec.files)) {
    fail('python', 'the record has no boundary hashes — the boundary files changed while the suite ran, so the data may come from other bytes')
    return null
  }
  for (const f of d.files) {
    const now = existsSync(join(root, f)) ? sha(readFileSync(join(root, f))) : null
    if (rec.files[f] !== now) fail('python', `${f}: the data was taken from other bytes (sha1 ${String(rec.files[f]).slice(0, 12)}… recorded, ${String(now).slice(0, 12)}… in the tree) — rerun the suite on this tree`)
  }
  return { path, note: `coverage.py ${typeof j.meta.version === 'string' ? j.meta.version : '?'} · lines · branch arcs`, files, never, units }
}

// ── node: vitest(v8) 의 istanbul JSON + 소스의 이름 범위 ──────────────────────────────────
// 주석·문자열·템플릿 리터럴의 글자를 공백으로 지운다(줄 번호 보존). 템플릿의 `${…}` 안은 코드다 — 그 안의 문자열·템플릿도
// 같은 규칙으로 지운다(중첩은 `${` 마다 중괄호 깊이를 하나 쌓는다). 정규식 리터럴은 가리지 않는다 — 그 안의 백틱은 템플릿을
// 열어 파일 끝까지 지운다. 그래서 파일이 열린 템플릿·`${…}` 안에서 끝나면 nodeFuncs 가 FAIL 한다(실측: 정규식 `` /`/ `` 하나로
// 세 함수가 지워진 채 「OK · 미실행 0」이었다 — #953 독립 레그). 따옴표는 줄 끝에서 닫혀 한 줄만 어긋난다.
function blankTs(src) {
  let res = ''
  const subs = [] // 열린 `${…}` 마다 그 안의 중괄호 깊이
  let inTemplate = false
  for (let i = 0; i < src.length; ) {
    const c = src[i]
    if (inTemplate) {
      if (c === '\\') {
        res += src.slice(i, i + 2).replace(/[^\n]/g, ' ')
        i += 2
      } else if (c === '`') {
        res += ' '
        i++
        inTemplate = false
      } else if (src.startsWith('${', i)) {
        res += '  '
        i += 2
        subs.push(0)
        inTemplate = false
      } else {
        res += c === '\n' ? '\n' : ' '
        i++
      }
      continue
    }
    let j
    if (src.startsWith('//', i)) {
      j = src.indexOf('\n', i)
      if (j < 0) j = src.length
    } else if (src.startsWith('/*', i)) {
      j = src.indexOf('*/', i + 2)
      j = j < 0 ? src.length : j + 2
    } else if (c === '"' || c === "'") {
      j = i + 1
      while (j < src.length && src[j] !== c && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1
      j = Math.min(src.length, j + 1)
    } else if (c === '`') {
      res += ' '
      i++
      inTemplate = true
      continue
    } else {
      if (subs.length && c === '{') subs[subs.length - 1]++
      else if (subs.length && c === '}') {
        if (subs[subs.length - 1] === 0) {
          subs.pop()
          res += ' '
          i++
          inTemplate = true
          continue
        }
        subs[subs.length - 1]--
      }
      res += src[i++]
      continue
    }
    res += src.slice(i, j).replace(/[^\n]/g, ' ')
    i = j
  }
  return { text: res, open: inTemplate || subs.length > 0 }
}
// 이름 범위 — 열 0 의 함수 선언 · 함수를 받는 const/let · 클래스의 열 2 멤버(메서드 · 생성자 · 접근자 · 화살표 함수
// 속성). interface·type·객체 리터럴의 멤버는 함수가 아니라 세지 않는다. 최상위 범위는 머리 줄부터 다음 최상위 머리 줄
// 직전까지다(열 0 의 `}`·`)`·`]` 는 머리가 아니다 — 닫는 줄은 앞 범위의 것). 멤버 범위는 머리 줄부터, 한 줄이면 그 줄, 아니면
// 열 2 에서 `}` 로 시작하는 첫 줄까지다(`}` · `})` · `};`). 그 줄이 다음 멤버 전에 없으면 몸통 없는 선언(오버로드 · abstract ·
// 함수 타입 속성)이라 범위가 아니다 — 중괄호 없는 한 줄 화살표만 그 줄이 범위다. 멤버 이름은 `클래스.멤버`(접근자는
// `클래스.get x` — 짝인 setter 와 갈린다).
const TS_MODS = '(?:(?:public|private|protected|static|readonly|override|abstract|declare|async)\\s+)*'
const TS_TOP_FN = /^(?:export\s+)?(?:default\s+)?(?:async\s+)?function\*?\s*([A-Za-z_$][\w$]*)/
const TS_TOP_CLASS = /^(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)/
const TS_TOP_CONST = /^(?:export\s+)?(?:const|let)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]*)?=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*(?::[^=]*)?=>|\(\s*$|[A-Za-z_$][\w$]*\s*=>)/
// 그룹: 1 수식어(static 이면 이름에 붙인다 — `static from()` 과 `from()` 이 갈린다) · 2 get/set · 3 이름. 제네릭은 `>`·`=>` 를
// 품을 수 있어(`<T extends Record<string, unknown>>` · `<T extends (a: string) => void>`) 탐욕 `<.*>` 로 받고 `(` 까지 되돌아간다.
// `d` — 계산된 이름(`[Symbol.for('x')]`)은 지우기 전 원문의 같은 자리에서 읽는다(지운 글자로는 이름이 불안정하다).
const TS_MEMBER = new RegExp(`^ {2}(${TS_MODS})(?:(get|set)\\s+)?(?:\\*\\s*)?(#?[A-Za-z_$][\\w$]*|\\[[^\\]]+\\])\\s*(?:<.*>)?\\s*\\(`, 'd')
// 화살표·함수식을 받는 속성만 — 값이 식별자뿐인 필드(`#closed = false`)는 함수가 아니다(그 분기가 가짜 범위를 만들었다).
const TS_PROP_FN = new RegExp(`^ {2}(${TS_MODS})(#?[A-Za-z_$][\\w$]*)\\s*(?:[?!]?\\s*:[^=]*)?=\\s*(?:async\\s+)?(?:function\\b|\\([^)]*\\)\\s*(?::[^=]*)?=>|\\(\\s*$|<.*>\\s*\\(|[A-Za-z_$][\\w$]*\\s*=>)`)
function nodeFuncs(file) {
  const raw = readFileSync(join(root, file), 'utf8').replace(/\r\n/g, '\n')
  const blanked = blankTs(raw)
  if (blanked.open) {
    fail('node', `${file}: a template literal or \${…} runs to the end of the file — the name ranges cannot be read (a regex literal with a backtick?)`)
    return null
  }
  const L = blanked.text.split('\n')
  const R = raw.split('\n')
  const count = (k, ch) => L[k].split(ch).length - 1
  const oneLine = (k) => count(k, '{') > 0 && count(k, '{') === count(k, '}')
  // 중괄호 없이 그 줄에서 끝나는 화살표(`x = (a) => a + 1`) — 줄 끝이 여는 글자나 `=>` 가 아니다.
  const exprArrow = (k) => /=>/.test(L[k]) && count(k, '{') === 0 && !/(?:[{([]|=>)\s*$/.test(L[k])
  const isTopHead = (x) => /^[^\s})\]]/.test(L[x])
  const nextTop = (k) => {
    for (let x = k + 1; x < L.length; x++) if (isTopHead(x)) return x
    return L.length
  }
  const lastFilled = (from, before) => {
    let e = before - 1
    while (e > from && !L[e].trim()) e--
    return e
  }
  // 멤버의 닫는 줄 — 열 2 의 `}`, 또는 여러 줄 시그니처를 닫으며 그 줄에서 몸통도 닫는 `) {}` · `): void {}`(실측: 실제
  // auth.ts 의 매개변수 속성 생성자가 `  ) {}` 로 닫혀 「몸통 없는 선언」으로 빠졌고 그 문장이 모듈 수준에 섞였다 — #953 독립 레그).
  const memberClose = (x, limit) => {
    for (let y = x + 1; y < limit; y++) if (/^ {2}\}/.test(L[y]) || (/^ {2}\)/.test(L[y]) && oneLine(y))) return y
    return -1
  }
  const funcs = []
  // kind: 'decl'(함수 선언 · 메서드 · 생성자 · 접근자) 또는 'value'(함수를 값으로 받는 const · 속성 — 머리 줄의 대입 문장은
  // 함수가 아니다, nodeReport).
  const add = (name, start, end, kind) => {
    if (funcs.some((f) => f.name === name)) {
      fail('node', `${file}: two functions are both named ${name} — the never-executed list cannot tell them apart`)
      return false
    }
    funcs.push({ name, start: start + 1, end: end + 1, kind, stmts: 0, covered: 0 })
    return true
  }
  for (let k = 0; k < L.length; k++) {
    if (!isTopHead(k)) continue
    const top = nextTop(k)
    const cls = L[k].match(TS_TOP_CLASS)
    if (cls) {
      const heads = []
      const isStatic = (mods) => /(?:^|\s)static\s/.test(` ${mods}`)
      for (let x = k + 1; x < top; x++) {
        const m = TS_MEMBER.exec(L[x])
        const p = m ? null : L[x].match(TS_PROP_FN)
        if (m) {
          const [s, e] = m.indices[3]
          const name = m[3].startsWith('[') ? R[x].slice(s, e) : m[3]
          heads.push({ x, name: `${isStatic(m[1]) ? 'static ' : ''}${m[2] ? `${m[2]} ` : ''}${name}`, kind: 'decl' })
        } else if (p) heads.push({ x, name: `${isStatic(p[1]) ? 'static ' : ''}${p[2]}`, kind: 'value' })
      }
      for (let h = 0; h < heads.length; h++) {
        const { x, name, kind } = heads[h]
        const limit = h + 1 < heads.length ? heads[h + 1].x : top
        const end = oneLine(x) || exprArrow(x) ? x : memberClose(x, limit)
        if (end < 0) continue // 몸통 없는 선언(오버로드 · abstract · 함수 타입 속성)
        if (!add(`${cls[1]}.${name}`, x, end, kind)) return null
      }
    } else {
      const fn = L[k].match(TS_TOP_FN)
      const val = fn ? null : L[k].match(TS_TOP_CONST)
      if ((fn || val) && !add((fn ?? val)[1], k, lastFilled(k, top), fn ? 'decl' : 'value')) return null
    }
    k = top - 1
  }
  return funcs
}
// istanbul JSON — 통합(`run node`)은 `node/coverage-final.json`, 단위 미도달 장부(`unit node`)는 `.unit` 이 붙은 디렉터리와 그 실행의
// 기록이다(SUITE). 통합 run 은 기록을 쓰지 않는다(머리 주석).
const NODE_DATA = () => join(out, `node${TAG}`, 'coverage-final.json')
const NODE_RUN = () => join(out, `node${TAG}.run.json`)
// istanbul 의 가지 종류 — ast-v8-to-istanbul 1.0.7 이 싣는 다섯(머리 주석). 단위 장부는 문장의 갈래(if · switch)만 세고, 모르는 종류는 FAIL 이다
// (세는지 버리는지 모르는 갈래를 조용히 버리지 않는다).
const NODE_ARMS = new Set(['if', 'switch'])
const NODE_KINDS = new Set([...NODE_ARMS, 'cond-expr', 'binary-expr', 'default-arg'])
// 단위 실행의 coverage.exclude — 레인 설정의 exclude 는 경계 자신이라(coverage-boundary 가 그것으로 경계를 파생한다) 장부의 실행은 아무것도
// 빼지 않는다. CLI 의 배열은 설정의 배열을 대신하지만(더하지 않는다) 빈 패턴은 못 준다 — picomatch(4.0.7)가 「Expected pattern to be a
// non-empty string」으로 던진다(실측 2026-11-24). 그래서 어느 파일에도 안 맞는 이름 하나를 준다.
const NODE_EXCLUDE_NOTHING = 'kcsdk-unit-unreached-excludes-nothing'
function nodeReport(d) {
  const path = NODE_DATA()
  const shown = path.replace(/\\/g, '/')
  if (!existsSync(path)) {
    fail('node', `no coverage data at ${shown} — run the ${SUITE} suite first (node scripts/integration-coverage.mjs ${RUN_CMD} node)`)
    return null
  }
  const bytes = readFileSync(path)
  let j
  try {
    j = JSON.parse(bytes.toString('utf8'))
  } catch {
    fail('node', `${shown} is not JSON`)
    return null
  }
  if (!j || typeof j !== 'object' || Array.isArray(j)) {
    fail('node', `${shown} is not an istanbul coverage map (an object keyed by file)`)
    return null
  }
  const byPath = new Map()
  for (const [k, v] of Object.entries(j)) byPath.set(toRepoPath(k, d.dir), v)
  const files = []
  const never = []
  // 이름 범위마다 안 돈 문장 · 안 탄 if · switch 갈래 — 단위 미도달 장부(unitReport)가 쓴다(통합 리포트는 never 만 쓴다).
  const units = []
  for (const f of sortU(d.files)) {
    const v = byPath.get(f)
    if (!v) {
      fail('node', `${f} is not in the coverage data — a boundary file the run never instrumented would silently leave the denominator`)
      continue
    }
    if (typeof v.statementMap !== 'object' || v.statementMap === null || typeof v.s !== 'object' || v.s === null) {
      fail('node', `${f}: the entry has no statementMap and s — not an istanbul file coverage`)
      continue
    }
    if (!existsSync(join(root, f))) {
      fail('node', `${f} is in the data but not in the tree — the data belongs to another checkout`)
      continue
    }
    const funcs = nodeFuncs(f)
    if (!funcs) continue
    // 'value' 범위(`const f = (…) => …` · 속성 `f = (…) => …`)의 머리 줄에는 대입 문장이 따로 있다 — 그것은 import 나 생성 때
    // 돌므로 함수의 것이 아니다(실측: `inc` 의 선언 41:13 은 1, 본문 41:42 는 0 — 줄로만 붙이면 한 번도 안 불린 `inc` 가
    // 미실행 목록에서 빠졌다). 그래서 그 줄에서 fnMap 이 잡은 함수 본문(`loc.start`)보다 앞에서 시작하는 문장은 바깥이다.
    // 'decl'(메서드 · 생성자)은 줄로 붙인다 — 생성자의 매개변수 속성(`constructor(readonly name)`)은 몸통 앞이지만 그 생성자의 것이다.
    const bodyAt = new Map()
    for (const fn of Object.values(v.fnMap ?? {})) {
      const decl = fn?.decl?.start?.line
      const at = fn?.loc?.start
      if (typeof decl === 'number' && typeof at?.line === 'number' && !bodyAt.has(decl)) bodyAt.set(decl, at)
    }
    const outside = { stmts: 0, covered: 0 }
    // 자리(줄 · 열)의 이름 범위 — 문장과 단위 장부의 갈래가 같은 규칙을 쓴다(위 'value' 머리 줄의 규칙 포함).
    const ownerOf = (line, col) => {
      let fn = funcs.find((x) => line >= x.start && line <= x.end) ?? outside
      if (fn !== outside && fn.kind === 'value' && line === fn.start) {
        const body = bodyAt.get(fn.start)
        if (body && (line < body.line || col < body.column)) fn = outside
      }
      return fn
    }
    let stmts = 0
    let covered = 0
    for (const [id, loc] of Object.entries(v.statementMap)) {
      const line = loc?.start?.line
      const col = loc?.start?.column
      const c = v.s[id]
      if (typeof line !== 'number' || typeof col !== 'number' || typeof c !== 'number') {
        fail('node', `${f}: statement ${id} has no start position or count`)
        return null
      }
      // 단위 장부는 못 읽는 수를 0 으로 세지 않는다(음수 · 정수가 아닌 횟수).
      if (SUITE === 'unit' && !isCount(c)) {
        fail('node', `${f}: cannot read the count of statement ${id} (${c}) in ${shown}`)
        return null
      }
      stmts++
      if (c > 0) covered++
      const fn = ownerOf(line, col)
      fn.stmts++
      if (c > 0) fn.covered++
    }
    // 단위 장부만 — if · switch 의 안 탄 갈래를 그 문장의 머리 자리로 이름 범위에 붙인다. 이름 범위 밖의 안 탄 갈래는 아래에서 FAIL 이다.
    const strays = []
    if (SUITE === 'unit') {
      if (typeof v.branchMap !== 'object' || v.branchMap === null || typeof v.b !== 'object' || v.b === null) {
        fail('node', `${f}: the entry has no branchMap and b — the unit ledger counts if and switch arms`)
        continue
      }
      for (const [id, br] of Object.entries(v.branchMap)) {
        const line = br?.loc?.start?.line
        const col = br?.loc?.start?.column
        const arms = v.b[id]
        if (!NODE_KINDS.has(br?.type)) {
          fail('node', `${f}: the branch at line ${line} is of kind ${br?.type}, which this reader does not know (${[...NODE_KINDS].join(' · ')}) — its arms would go uncounted`)
          return null
        }
        if (!NODE_ARMS.has(br.type)) continue
        if (typeof line !== 'number' || typeof col !== 'number' || !Array.isArray(arms) || !arms.length || !arms.every(isCount)) {
          fail('node', `${f}: cannot read the arm counts of the ${br.type} branch at line ${line} in ${shown}`)
          return null
        }
        const missed = arms.filter((c) => c === 0).length
        const fn = ownerOf(line, col)
        if (fn !== outside) fn.arms = (fn.arms ?? 0) + missed
        else if (missed) strays.push({ line, type: br.type, missed })
      }
    }
    files.push({ file: f, stmts, covered, outside, strays })
    for (const fn of funcs) if (fn.stmts > 0 && fn.covered === 0) never.push({ file: f, line: fn.start, name: fn.name, stmts: fn.stmts })
    if (SUITE === 'unit') for (const fn of funcs) units.push({ file: f, line: fn.start, name: fn.name, statements: fn.stmts - fn.covered, branches: fn.arms ?? 0 })
  }
  if (SUITE !== 'unit') return { path, files, never }
  // ── 여기부터 단위 미도달 장부만 ──
  // 이름 범위 밖(모듈 코드 · 클래스 필드의 초기값 · 함수 값의 대입)의 안 돈 문장 · 안 탄 갈래는 어느 함수에도 못 붙인다 — FAIL 이다(go 의 패키지
  // 수준 함수 리터럴 · python 의 모듈 수준 · ruby 의 메서드 밖 갈래와 같은 판정). 경계 파일을 한 번도 안 불러온 실행이면 그 판정(ranNothing —
  // 측정 실패)이 먼저다.
  const loadedAny = files.some((x) => x.covered > 0)
  if (loadedAny) {
    for (const x of files) {
      if (x.outside.covered < x.outside.stmts) fail('node', `${x.file}: ${x.outside.stmts - x.outside.covered} of ${x.outside.stmts} module-level statements (outside every function — module code, class fields, the assignment of a function value) never ran — no function can be credited with them`)
      for (const s of x.strays) fail('node', `${x.file}:${s.line}: the ${s.type} branch there sits outside every function and has ${s.missed === 1 ? 'an arm' : `${s.missed} arms`} the run never took — no function can be credited with ${s.missed === 1 ? 'it' : 'them'}`)
    }
  }
  // run 기록 — python 과 같은 이유(손으로 돌린 실행 · 실패한 실행 · 다른 실행이 덮어쓴 데이터). istanbul JSON 에는 소스 해시가 없어(자리뿐이다)
  // 경계 파일의 바이트도 기록과 대조한다. 다른 판정 뒤에 두되 앞의 실패가 있어도 낸다(두 까닭이 한 번에 보인다).
  const runRec = NODE_RUN()
  let rec = null
  try {
    rec = JSON.parse(readFileSync(runRec, 'utf8'))
  } catch {
    rec = null
  }
  const isObj = (x) => x !== null && typeof x === 'object' && !Array.isArray(x)
  const sha = (b) => createHash('sha1').update(b).digest('hex')
  if (!isObj(rec) || rec.run !== 'node' || (rec.suite ?? 'integration') !== SUITE) {
    fail('node', `no record that \`${RUN_CMD} node\` wrote this data (${runRec.replace(/\\/g, '/')}) — run the suite through the script (node scripts/integration-coverage.mjs ${RUN_CMD} node) so the report can tell a complete, successful run`)
    return null
  }
  if (rec.exit !== 0) {
    fail('node', `the run that wrote this data exited ${rec.exit} — the data of a failed run is partial`)
    return null
  }
  if (rec.data_sha1 !== sha(bytes)) {
    fail('node', `${shown} is not the data \`${RUN_CMD} node\` recorded (sha1 ${String(rec.data_sha1).slice(0, 12)}… recorded, ${sha(bytes).slice(0, 12)}… now) — another run wrote over it`)
    return null
  }
  if (!isObj(rec.files)) {
    fail('node', 'the record has no boundary hashes — the boundary files changed while the suite ran, so the data may come from other bytes')
    return null
  }
  for (const f of d.files) {
    const now = existsSync(join(root, f)) ? sha(readFileSync(join(root, f))) : null
    if (rec.files[f] !== now) fail('node', `${f}: the data was taken from other bytes (sha1 ${String(rec.files[f]).slice(0, 12)}… recorded, ${String(now).slice(0, 12)}… in the tree) — rerun the suite on this tree`)
  }
  return { path, note: `@vitest/coverage-v8 ${typeof rec.coverage_v8 === 'string' ? rec.coverage_v8 : '?'} · istanbul statements · if and switch arms`, files, never, units }
}

// ── rust: cargo llvm-cov 의 lcov + 소스의 이름 범위 ───────────────────────────────────────────
// 주석·문자열·문자 리터럴의 글자를 공백으로 지운다(줄 번호 보존). 블록 주석은 중첩되고(`/* /* */ */`), 문자열은 줄을 넘고,
// 원시 문자열(`r#"…"#` · `br"…"`)은 같은 수의 `#` 로만 닫힌다(이스케이프 없음). `'` 는 문자 리터럴(`'"'` · `'\''` ·
// `'\u{7f}'`)과 수명·라벨(`'a` · `'static` · `'outer:`)이 나눠 쓴다 — 닫는 `'` 가 한 글자 뒤에 있을 때만 리터럴이다(`'"'`
// 를 수명으로 읽으면 그 `"` 가 문자열을 열어 다음 `"` 까지 코드를 지운다). 파일이 열린 문자열·주석 안에서 끝나면 FAIL 이다.
// `kept` 는 같은 길이의 둘째 사본 — 주석만 지우고 리터럴은 남긴다(cfg 이름 꼬리의 `feature = "x"` 를 원문대로 쓰되, 줄 끝
// 주석이 소유자 키에 들어가지 않게 한다 — 독립 레그 실측).
function blankRust(src) {
  let res = ''
  let kept = ''
  let open = false
  const n = src.length
  for (let i = 0; i < n; ) {
    const c = src[i]
    let j = -1
    let comment = false
    if (c === '/' && src[i + 1] === '/') {
      comment = true
      j = src.indexOf('\n', i)
      if (j < 0) j = n
    } else if (c === '/' && src[i + 1] === '*') {
      comment = true
      let depth = 1
      j = i + 2
      while (j < n && depth > 0) {
        if (src[j] === '/' && src[j + 1] === '*') {
          depth++
          j += 2
        } else if (src[j] === '*' && src[j + 1] === '/') {
          depth--
          j += 2
        } else j++
      }
      if (depth > 0) open = true
    } else if ((c === 'r' || c === 'b' || c === 'c') && !/\w/.test(src[i - 1] ?? '')) {
      const m = /^[bc]?r(#*)"/.exec(src.slice(i, i + 300))
      if (m) {
        const close = `"${m[1]}`
        const k = src.indexOf(close, i + m[0].length)
        if (k < 0) {
          open = true
          j = n
        } else j = k + close.length
      }
    } else if (c === '"') {
      j = i + 1
      while (j < n && src[j] !== '"') j += src[j] === '\\' ? 2 : 1
      if (j >= n) open = true
      j = Math.min(n, j + 1)
    } else if (c === "'") {
      if (src[i + 1] === '\\') {
        j = i + 3 // 이스케이프된 글자(`\'` 의 `'` 포함)를 건너 닫는 `'` 를 찾는다
        while (j < n && src[j] !== "'" && src[j] !== '\n') j++
        j = Math.min(n, j + 1)
      } else if (i + 1 < n && src[i + 1] !== '\n') {
        const w = src.codePointAt(i + 1) > 0xffff ? 2 : 1
        if (src[i + 1 + w] === "'") j = i + 2 + w
      }
    }
    if (j < 0) {
      res += src[i]
      kept += src[i++]
      continue
    }
    const blank = src.slice(i, j).replace(/[^\n]/g, ' ')
    res += blank
    kept += comment ? blank : src.slice(i, j)
    i = j
  }
  return { text: res, kept, open }
}
// 이름 범위 — rustfmt 가 보장하는 모양: 항목은 감싼 것보다 네 칸 깊고, 여러 줄 몸통은 항목의 들여쓰기에서 `}` 한 글자
// 줄로 닫힌다(빈 몸통만 한 줄 `fn x() {}`). 머리의 끝은 `{` · `;` · `}` 로 끝나는 첫 줄이다(여러 줄 시그니처와 where 절의
// 줄은 `(` · `,` 로 끝난다) — `;` 이면 몸통 없는 선언(트레이트의 필수 메서드 · extern fn · `mod x;`)이라 범위가 아니다.
// `fn` 은 범위, `impl` · `trait` · 인라인 `mod` 는 네 칸 안쪽을 다시 읽는다. 함수 안의 클로저 · 중첩 fn · async 몸통은 감싼
// 함수에 접힌다. `static` · `const` 도 범위다 — 값의 클로저(`LazyLock::new(|| …)`)가 그 줄에 함수 레코드를 낳는다(독립 레그
// 실측: 범위가 아니면 「범위 밖 레코드」 FAIL). 이름은 rust 의 경로 꼴이다 — `Type::m` · `<Type as Trait>::m`(머리 그대로,
// 공백만 접는다 — 같은 타입의 `Debug::fmt` 와 `Display::fmt`, `Wrapper<u8>::get` 과 `Wrapper<u16>::get` 이 갈린다) · `mod::f` ·
// `static NAME`. `#[cfg(…)]` 는 `test` 가 꺼진 빌드(통합 테스트가 링크하는 라이브러리)로 평가한다 — 거짓이면(`test` ·
// `all(test, …)`) 그 항목은 통합 빌드에 없으므로 읽지 않고, 모르면(`windows` · `feature = …`) 이름 뒤에 붙인다(플랫폼 쌍둥이가
// 갈린다 — 이 실행에서 컴파일되지 않은 쪽은 `no record` 로 남는다). `macro_rules!` 몸통은 범위가 아니다 — 매크로가 만든
// 함수의 레코드는 몸통을 가리키고 같은 줄을 나눠 쓰므로, 그중 안 돈 것을 줄로는 가를 수 없다(→ FAIL, rustReport).
const RS_ID = String.raw`(?:r#)?[\p{XID_Start}_]\p{XID_Continue}*`
const RS_VIS = String.raw`(?:pub(?:\s*\([^)]*\))?\s+)?`
// 한정자(그룹 1 — `async` 를 본다) 뒤의 `fn 이름`(그룹 2) — `extern "C"` 의 ABI 문자열은 지운 뒤라 공백이다.
const RS_FN = new RegExp(String.raw`^(${RS_VIS}(?:(?:default|const|async|unsafe|safe|extern)\s+)*)fn\s+(${RS_ID})`, 'u')
const RS_IMPL = /^(?:(?:default|unsafe)\s+)*impl\b/
const RS_TRAIT = new RegExp(String.raw`^${RS_VIS}(?:(?:unsafe|auto)\s+)*trait\s+(${RS_ID})`, 'u')
const RS_MOD = new RegExp(String.raw`^${RS_VIS}mod\s+(${RS_ID})\s*\{$`, 'u')
const RS_VALUE = new RegExp(String.raw`^${RS_VIS}(static|const)\s+(?:mut\s+)?(${RS_ID})\s*:`, 'u')
const RS_MACRO = new RegExp(String.raw`^macro_rules!\s*(${RS_ID})\s*\{$`, 'u')
// 속성의 경로(`#[a::b(…)]` → `a::b`) — 이 목록과 도구 속성(rustfmt:: · clippy:: · diagnostic::) 밖은 속성 매크로로 본다.
const RS_ATTR_PATH = new RegExp(String.raw`^#!?\[\s*((?:::\s*)?${RS_ID}(?:\s*::\s*${RS_ID})*)`, 'u')
const RS_BUILTIN_ATTRS = new Set(
  ('cfg cfg_attr doc allow warn deny forbid expect must_use inline cold track_caller deprecated non_exhaustive repr derive ' +
    'automatically_derived no_mangle export_name link_section link_name used target_feature test ignore should_panic ' +
    'macro_export macro_use path coverage optimize naked instruction_set debugger_visualizer collapse_debuginfo unsafe').split(' '),
)
// 속성 하나(`#[…]`, 공백 접은 텍스트)가 속성 매크로인가. `cfg_attr(술어, 속성…)` 은 안쪽 속성들로 가린다 — 경로만 보면 내장이라
// `#[cfg_attr(…, async_trait::async_trait)]` 이 매크로가 아닌 것으로 읽혔다(독립 레그 5차 실측: poll 한 메서드가 「안 돌았다」).
function rsMacroAttr(text) {
  const path = RS_ATTR_PATH.exec(text)?.[1].replace(/\s+/g, '').replace(/^::/, '')
  if (!path) return false
  if (path !== 'cfg_attr') return !RS_BUILTIN_ATTRS.has(path) && !/^(?:rustfmt|clippy|diagnostic)::/.test(path)
  const inner = /^#!?\[\s*cfg_attr\s*\((.*)\)\s*\]$/.exec(text)?.[1] ?? ''
  const parts = [] // 괄호 깊이 0 의 쉼표로 가른다 — 첫째는 술어다
  let d = 0
  let cur = ''
  for (const c of inner) {
    if (c === '(' || c === '[' || c === '{') d++
    else if (c === ')' || c === ']' || c === '}') d--
    if (c === ',' && d === 0) {
      parts.push(cur)
      cur = ''
    } else cur += c
  }
  parts.push(cur)
  return parts.slice(1).some((p) => p.trim() && rsMacroAttr(`#[${p.trim()}]`))
}
// `#[cfg(…)]` 술어를 `test` 가 꺼진 빌드에서 평가한다 — true · false · null(모름: target · feature …). 못 읽는 꼴도 null.
function cfgEval(expr) {
  const toks = expr.match(/[\p{XID_Start}_]\p{XID_Continue}*|[(),=]/gu) ?? []
  let i = 0
  const pred = () => {
    const t = toks[i++]
    if (t === undefined || '(),='.includes(t)) throw new Error('shape')
    if (toks[i] === '(' && (t === 'all' || t === 'any' || t === 'not')) {
      i++
      const vs = []
      while (toks[i] !== ')') {
        vs.push(pred())
        if (toks[i] === ',') i++
        else if (toks[i] !== ')') throw new Error('shape')
      }
      i++
      if (t === 'not') return vs.length !== 1 || vs[0] === null ? null : !vs[0]
      if (t === 'all') return vs.includes(false) ? false : vs.every((v) => v === true) ? true : null
      return vs.includes(true) ? true : vs.every((v) => v === false) ? false : null
    }
    if (toks[i] === '=') {
      i++ // `key = "value"` — 값(문자열)은 지운 뒤라 토큰이 없다
      return null
    }
    return t === 'test' ? false : null
  }
  try {
    const v = pred()
    return i === toks.length ? v : null
  } catch {
    return null
  }
}
// 글자마다 괄호 깊이(`<>` · `()` · `[]`) — `->` · `=>` 의 `>` 는 괄호가 아니다.
function rsDepths(s) {
  const at = []
  let d = 0
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    const arrow = c === '>' && (s[i - 1] === '-' || s[i - 1] === '=')
    if (!arrow && (c === '>' || c === ')' || c === ']')) d--
    at.push(d)
    if (c === '<' || c === '(' || c === '[') d++
  }
  return at
}
// impl 머리(지운 텍스트, 여러 줄이면 이은 것) → 멤버 이름의 접두. 읽지 못하면 null.
function rsImplPrefix(head) {
  let s = head.replace(/\s+/g, ' ').trim().replace(/\s*\{$/, '').replace(/^(?:(?:default|unsafe) )*impl ?/, '')
  if (s.startsWith('<')) {
    const at = rsDepths(s)
    const k = at.findIndex((d, x) => x > 0 && d === 0 && s[x] === '>' && s[x - 1] !== '-' && s[x - 1] !== '=')
    if (k < 0) return null
    s = s.slice(k + 1).trim()
  }
  const firstAtTop = (re) => {
    const at = rsDepths(s)
    for (const m of s.matchAll(re)) if (at[m.index] === 0) return m.index
    return -1
  }
  const w = firstAtTop(/\bwhere\b/g)
  if (w >= 0) s = s.slice(0, w).trim()
  if (!s) return null
  const norm = (x) => x.trim().replace(/<\s+/g, '<').replace(/,?\s*>/g, '>').replace(/\s*::\s*/g, '::')
  const f = firstAtTop(/ for /g)
  return f >= 0 ? `<${norm(s.slice(f + 5))} as ${norm(s.slice(0, f))}>::` : `${norm(s)}::`
}
function rustFuncs(file) {
  const raw = readFileSync(join(root, file), 'utf8').replace(/\r\n/g, '\n')
  const blanked = blankRust(raw)
  if (blanked.open) {
    fail('rust', `${file}: a string or block comment runs to the end of the file — the name ranges cannot be read`)
    return null
  }
  const L = blanked.text.split('\n').map((l) => l.replace(/\s+$/, ''))
  const K = blanked.kept.split('\n') // 주석만 지운 사본 — L 과 글자 자리가 같다
  const funcs = []
  const tests = [] // `test` 없이는 컴파일되지 않는 항목의 줄 범위 — 통합 빌드에는 없다
  const macros = [] // `macro_rules!` 몸통의 줄 범위
  let ok = true
  const bad = (k, msg) => {
    fail('rust', `${file}:${k + 1}: ${msg}`)
    ok = false
  }
  const count = (s, ch) => s.split(ch).length - 1
  // 속성 하나 — `#[` 에서 짝 맞는 `]` 까지(rustfmt 는 긴 cfg 술어를 여러 줄로 접는다 — 독립 레그 실측: 한 줄만 읽으면 접힌
  // `all(test, …)` 모듈의 단위 테스트 줄이 통합 커버리지로 셌다). 이름 꼬리(`shown`)는 같은 구간의 K — `]` 뒤 주석은 안 든다.
  const attrAt = (x, pad) => {
    let d = 0
    const text = []
    const shown = []
    for (let y = x; y < L.length; y++) {
      const from = y === x ? pad.length : 0
      for (let c = from; c < L[y].length; c++) {
        if (L[y][c] === '[') d++
        else if (L[y][c] === ']' && --d === 0) {
          text.push(L[y].slice(from, c + 1))
          shown.push(K[y].slice(from, c + 1))
          return { text: text.join(' '), shown: shown.join(' ') }
        }
      }
      text.push(L[y].slice(from))
      shown.push(K[y].slice(from))
    }
    return null
  }
  // 항목 위의 속성들(빈 줄 · 같은 들여쓰기의 `#` 줄 · 그보다 깊은 이어진 줄 — 접힌 속성의 몸 · 닫는 `))]` — 을 건넌다).
  // cfgs — `#[cfg(…)]` 의 값과 이름 꼬리. rewritten — 속성 매크로가 있다(내장 · 도구 속성 밖의 경로). 속성 매크로는 몸통을 다시
  // 쓸 수 있다 — `#[async_trait]` 은 async 몸통을 블록으로 옮겨 그 레코드가 사라진다(rustReport). 철자가 여럿이라(`::async_trait::
  // async_trait` · `use … as at; #[at]` — 독립 레그 4차 실측) 이름이 아니라 「내장이 아니다」로 가른다.
  const attrsOf = (k, pad) => {
    const cfgs = []
    let rewritten = false
    for (let x = k - 1; x >= 0; x--) {
      if (!L[x]) continue
      if (L[x].startsWith(`${pad}#`)) {
        const a = attrAt(x, pad)
        const text = a ? a.text.replace(/\s+/g, ' ') : ''
        const m = /^#\[\s*cfg\s*\((.*)\)\s*\]$/.exec(text)
        if (m) {
          const shown = a.shown.replace(/\s+/g, ' ').replace(/\(\s+/g, '(').replace(/,?\s+\)/g, ')').replace(/,\)/g, ')')
          cfgs.push({ value: cfgEval(m[1]), text: shown })
        }
        if (rsMacroAttr(text)) rewritten = true
      } else if (!(L[x].startsWith(`${pad} `) || L[x].startsWith(`${pad})`) || L[x].startsWith(`${pad}]`))) break
    }
    return { cfgs, rewritten }
  }
  const add = (entry) => {
    if (funcs.some((f) => f.name === entry.name)) {
      fail('rust', `${file}: two functions are both named ${entry.name} — the never-executed list cannot tell them apart`)
      ok = false
      return false
    }
    funcs.push({ records: 0, hit: 0, stmts: 0, covered: 0, ...entry })
    return true
  }
  // static · const 의 끝 — 괄호(`()` · `[]` · `{}`) 깊이 0 의 `;`(rustfmt 는 긴 값을 `=` 뒤에서 더 깊이 접는다).
  const statementEnd = (k, to) => {
    let d = 0
    for (let y = k; y < to; y++)
      for (const c of L[y]) {
        if (c === '(' || c === '[' || c === '{') d++
        else if (c === ')' || c === ']' || c === '}') d--
        else if (c === ';' && d === 0) return y
      }
    return -1
  }
  // ctx — prefix(자유 항목 이름 앞) · typePrefix(impl · trait 이름 앞 — `const _` 블록 안에서도 타입 경로는 그대로다) ·
  // suffix(감싼 컨테이너의 cfg(모름) 꼬리 — 멤버 이름 뒤) · rewritten(감싼 impl · trait 에 속성 매크로).
  let unnamed = 0
  const walk = (from, to, ind, ctx) => {
    const pad = ' '.repeat(ind)
    for (let k = from; k < to && ok; k++) {
      const line = L[k]
      if (line.length <= ind || !line.startsWith(pad) || line[ind] === ' ') continue
      const t = line.slice(ind)
      const fn = RS_FN.exec(t)
      const impl = !fn && RS_IMPL.test(t)
      const tr = fn || impl ? null : RS_TRAIT.exec(t)
      const md = fn || impl || tr ? null : RS_MOD.exec(t)
      const val = fn || impl || tr || md ? null : RS_VALUE.exec(t)
      const mac = fn || impl || tr || md || val ? null : RS_MACRO.exec(t)
      if (!fn && !impl && !tr && !md && !val && !mac) continue
      const { cfgs, rewritten: own } = attrsOf(k, pad)
      const testOnly = cfgs.some((c) => c.value === false)
      const tail = `${cfgs
        .filter((c) => c.value === null)
        .reverse()
        .map((c) => ` ${c.text}`)
        .join('')}${ctx.suffix}`
      if (val) {
        const e = statementEnd(k, to)
        if (e < 0) return bad(k, `cannot find the end of the ${val[1]} item (a ";" outside brackets)`)
        // `const _` 는 이름이 없다 — 컴파일 때 단언(`const _: () = assert!(…)`)이 보통이라 한 파일에 여럿이어도 정당하다(독립
        // 레그 실측: 이름으로 두면 「같은 이름 둘」 FAIL). 블록 값(`const _: () = { impl … }`)은 안쪽 항목을 읽는다(레그 3차) — 자유
        // 항목은 `const _::` 로 가른다(바깥의 같은 이름 fn 과 겹치지 않게 — 레그 4차), impl 의 멤버는 타입에 속하니 타입 경로 그대로다.
        // 블록이 아닌 값(클로저 · 단언)은 파일 안 순번 `const _#N` 의 범위다(클로저 값은 레코드를 낳는다 — 레그 4차).
        if (val[2] === '_' && /=\s*\{$/.test(L[k]) && e > k) {
          if (!testOnly) walk(k + 1, e, ind + 4, { ...ctx, prefix: `${ctx.prefix}const _::`, suffix: tail })
          k = e
          continue
        }
        const name = val[2] === '_' ? `const ${ctx.prefix}_#${++unnamed}${tail}` : `${val[1]} ${ctx.prefix}${val[2]}${tail}`
        if (testOnly) tests.push({ start: k + 1, end: e + 1 })
        else if (!add({ name, start: k + 1, end: e + 1, ind, kind: 'value' })) return
        k = e
        continue
      }
      let h = k
      while (h < to && !/[{;}]$/.test(L[h])) h++
      if (h >= to) return bad(k, 'cannot find the end of the item head')
      if (L[h].endsWith(';')) {
        k = h
        continue
      }
      let end = h
      if (L[h].endsWith('{')) {
        end = -1
        for (let y = h + 1; y < to; y++)
          if (L[y] === `${pad}}`) {
            end = y
            break
          }
        if (end < 0) return bad(k, `cannot find the end of the item (rustfmt closes a body with "}" at the item's indent)`)
      } else if (count(L[h], '{') !== count(L[h], '}')) return bad(h, 'a one-line item whose braces do not pair')
      if (testOnly) tests.push({ start: k + 1, end: end + 1 })
      else if (mac) macros.push({ name: mac[1], start: k + 1, end: end + 1 })
      else if (fn) {
        // async 판정(rustReport)은 몸통이 따로 남는 평범한 async fn 에만 건다 — 자기나 감싼 impl · trait 에 속성 매크로가 있으면
        // (`#[async_trait]` · `#[tracing::instrument]` …) 보통 fn 처럼 읽는다.
        const isAsync = /\basync\s/.test(fn[1]) && !own && !ctx.rewritten
        if (!add({ name: `${ctx.prefix}${fn[2]}${tail}`, start: k + 1, end: end + 1, ind, kind: 'fn', async: isAsync })) return
      } else if (end > h) {
        if (md) {
          const p = `${md[1]}::`
          walk(h + 1, end, ind + 4, { prefix: `${ctx.prefix}${p}`, typePrefix: `${ctx.typePrefix}${p}`, suffix: tail, rewritten: false })
        } else {
          const p = tr ? `${tr[1]}::` : rsImplPrefix(L.slice(k, h + 1).join(' '))
          if (p === null) return bad(k, 'cannot read the type this impl is for')
          const base = `${ctx.typePrefix}${p}`
          walk(h + 1, end, ind + 4, { prefix: base, typePrefix: base, suffix: tail, rewritten: own })
        }
      }
      k = end
    }
  }
  walk(0, L.length, 0, { prefix: '', typePrefix: '', suffix: '', rewritten: false })
  // 범위 안에서 그 함수와 같은 들여쓰기의 `fn` 머리 — 범위가 닫는 줄을 지나쳐 다음 함수를 삼켰다는 뜻이다.
  const swallows = (fn, line) => {
    const pad = ' '.repeat(fn.ind)
    const t = L[line - 1] ?? ''
    return line !== fn.start && t.startsWith(pad) && t[fn.ind] !== ' ' && RS_FN.test(t.slice(fn.ind))
  }
  return ok ? { funcs, tests, macros, swallows, lines: L.length - (L.at(-1) === '' ? 1 : 0) } : null
}
// lcov — 통합(`run rust`)은 `rust.lcov`, 단위 미도달 장부(`unit rust`)는 `.unit` 이 붙은 이름과 그 실행의 기록이다(SUITE). 통합 run 은
// 기록을 쓰지 않는다(머리 주석).
const RUST_DATA = () => join(out, `rust${TAG}.lcov`)
const RUST_RUN = () => join(out, `rust${TAG}.run.json`)
function rustReport(d) {
  const path = RUST_DATA()
  const shown = path.replace(/\\/g, '/')
  if (!existsSync(path)) {
    fail('rust', `no coverage data at ${shown} — run the ${SUITE} suite first (node scripts/integration-coverage.mjs ${RUN_CMD} rust)`)
    return null
  }
  const bytes = readFileSync(path)
  const recs = new Map()
  let cur = null
  for (const l of bytes.toString('utf8').replace(/\r\n/g, '\n').split('\n')) {
    if (l === '') continue
    if (l === 'end_of_record') {
      cur = null
      continue
    }
    // 기록의 줄은 전부 `TAG:` 꼴이다. ⚠️ llvm-cov 의 lcov 는 마지막 줄바꿈 없이 끝난다 — 두 보고서를 `cat` 으로 이으면
    // `end_of_recordSF:…` 한 줄이 되어 뒤 기록의 줄이 앞 파일에 섞인다(실측). 그런 줄은 못 읽는 줄이다.
    if (!/^[A-Z]+:/.test(l)) {
      fail('rust', `cannot read the lcov line: ${l.slice(0, 160)}`)
      return null
    }
    if (l.startsWith('SF:')) {
      const f = toRepoPath(l.slice(3), d.dir)
      if (recs.has(f)) {
        fail('rust', `${f} has two records in ${shown} — the data contradicts itself`)
        return null
      }
      cur = { file: f, da: new Map(), fns: [], fnda: new Map() }
      recs.set(f, cur)
      continue
    }
    if (!cur || !/^(?:DA|FN|FNDA):/.test(l)) continue
    const da = /^DA:(\d+),(\d+)(?:,.*)?$/.exec(l)
    const fnr = da ? null : /^FN:(\d+),(.+)$/.exec(l)
    const fnda = da || fnr ? null : /^FNDA:(\d+),(.+)$/.exec(l)
    if (!da && !fnr && !fnda) {
      fail('rust', `cannot read the lcov line: ${l}`)
      return null
    }
    if (fnda) cur.fnda.set(fnda[2], Number(fnda[1]))
    else if (fnr) cur.fns.push({ line: Number(fnr[1]), name: fnr[2] })
    else if (cur.da.has(Number(da[1]))) {
      fail('rust', `${cur.file}: line ${da[1]} is counted twice in one record — the data contradicts itself`)
      return null
    } else cur.da.set(Number(da[1]), Number(da[2]))
  }
  if (!recs.size) {
    fail('rust', `${shown} has no SF records — not an lcov report`)
    return null
  }
  const files = []
  const never = []
  const units = []
  for (const f of sortU(d.files)) {
    const r = recs.get(f)
    if (!r) {
      fail('rust', `${f} is not in the coverage data — a boundary file the run never linked would silently leave the denominator (an unreferenced module's object is not linked)`)
      continue
    }
    if (!existsSync(join(root, f))) {
      fail('rust', `${f} is in the data but not in the tree — the data belongs to another checkout`)
      continue
    }
    const src = rustFuncs(f)
    if (!src) continue
    const rangeOf = (x) => src.funcs.find((fn) => x >= fn.start && x <= fn.end)
    const within = (list, x) => list.find((t) => x >= t.start && x <= t.end)
    // 레코드의 호출 횟수(FNDA) — async 판정이 쓴다. 횟수 없는 레코드가 하나라도 있으면 그 판정을 할 수 없다(0 으로 읽으면
    // 돈 몸통을 「안 돌았다」로 낸다). llvm-cov 는 FN 마다 FNDA 를 쓴다.
    const uncounted = r.fns.find((rec) => !r.fnda.has(rec.name))
    if (uncounted) {
      fail('rust', `${f}:${uncounted.line}: the data has a function record (${uncounted.name}) without an FNDA count — whether an async body ran cannot be read`)
      continue
    }
    let broken = false
    for (const rec of r.fns) {
      if (within(src.tests, rec.line)) {
        // 단위 빌드는 `test` 로만 컴파일되는 항목(그 파일의 단위 시험 모듈)을 싣는다 — 경계 코드가 아니라 시험이다: 단위 장부는 그 레코드와
        // 줄을 세지 않는다(아래 DA). 통합 리포트에서는 단위 시험이 같은 빌드에서 돈 것이라 FAIL 이다.
        if (SUITE === 'unit') continue
        fail('rust', `${f}:${rec.line}: the data has a function inside an item compiled only with cfg(test) (${rec.name}) — unit tests ran in this build, so the report would not be integration-only`)
        broken = true
        break
      }
      const mac = within(src.macros, rec.line)
      if (mac) {
        fail('rust', `${f}:${rec.line}: the data has a function (${rec.name}) inside macro_rules! ${mac.name} — the functions a macro generates share its lines, so one that never ran cannot be told apart from one that did; keep boundary functions out of macro_rules`)
        broken = true
        break
      }
      const fn = rangeOf(rec.line)
      if (!fn || src.swallows(fn, rec.line)) {
        const where = fn ? `starts at a function head inside ${fn.name}'s range (${fn.start}–${fn.end}) — the range ran past its end` : 'starts outside every name range — the parser missed an item, or code runs at module level'
        fail('rust', `${f}:${rec.line}: the data has a function (${rec.name}) that ${where}; the never-executed list cannot be trusted`)
        broken = true
        break
      }
      fn.records++
      if ((r.fnda.get(rec.name) ?? 0) > 0) fn.hit++
    }
    if (broken) continue
    const outside = { stmts: 0, covered: 0 }
    let stmts = 0
    let covered = 0
    for (const [line, c] of r.da) {
      if (line < 1 || line > src.lines) {
        fail('rust', `${f}: the data counts line ${line}, past the end of the file (${src.lines} lines) — the data belongs to another checkout`)
        broken = true
        break
      }
      // 단위 시험 모듈(cfg(test))의 줄 — 시험이지 경계 코드가 아니다(분모 · 미도달 어디에도 안 든다 — 위 레코드와 같다).
      if (SUITE === 'unit' && within(src.tests, line)) continue
      stmts++
      if (c > 0) covered++
      const fn = rangeOf(line) ?? outside
      fn.stmts++
      if (c > 0) fn.covered++
    }
    if (broken) continue
    const mine = []
    for (const fn of src.funcs) {
      const at = { file: f, line: fn.start, name: fn.name, stmts: fn.stmts }
      if (!fn.records) {
        // 줄은 함수 레코드의 영역에서만 나온다 — 레코드 없이 줄이 있으면 데이터가 함수 레코드를 뺐다(`--skip-functions`).
        if (fn.stmts) {
          fail('rust', `${f}:${fn.start}: the data counts ${fn.stmts} line(s) inside ${fn.name} but has no function record there — a report without function records (cargo llvm-cov --skip-functions?) cannot name never-executed functions`)
          broken = true
          break
        }
        // 레코드가 없는 fn — 크레이트 밖에 안 보이고 아무도 참조 안 한 fn · 인스턴스화 안 된 제네릭 · 이 빌드에서 cfg 로 빠진 쌍둥이.
        // static · const 는 코드가 없는 것이 보통이라(문자열 상수) 레코드가 없어도 목록에 올리지 않는다.
        // ⚠️ 단위 장부는 그 함수의 줄을 셀 수 없다 — FAIL 이다(조용히 0 줄이면 아무것도 안 닿는 함수가 장부에서 사라진다). 단위 실행의
        // 라이브러리 단위 시험 바이너리는 아무도 안 부른 함수 · 인스턴스화 안 된 제네릭 · poll 안 된 async 몸통에도 0 회 레코드를 남기므로
        // (머리 주석의 실측) 레코드가 없으면 이 빌드가 컴파일하지 않은 코드다.
        if (fn.kind === 'fn' && SUITE === 'unit') {
          fail('rust', `${f}:${fn.start}: the data has no record of ${fn.name} — the unit build compiled no code for it (a cfg twin this platform leaves out, or a run without the library's unit-test binary, which keeps zero-count records of what nothing calls), so the lines the unit suite misses there cannot be counted`)
          broken = true
          continue
        }
        if (fn.kind === 'fn') mine.push({ ...at, label: 'no record in the data' })
      } else if (fn.stmts > 0 && fn.covered === 0) mine.push(at)
      // 부른 async fn 은 퓨처만 만든다 — 몸통은 poll 될 때 도는 별도 레코드다. 범위 안에서 횟수 > 0 인 레코드가 바깥 함수 하나뿐이면
      // 몸통은 안 돌았다(퓨처를 만들고 버렸다 — 독립 레그 실측: 바깥 `FNDA:1`). 줄로는 못 잰다 — 주석뿐인 몸통을 poll 하면 DA 는
      // 머리·닫는 줄뿐이다(실측). ⚠️ 속성 매크로가 붙은 async fn(자기나 감싼 impl · trait 에 — rustFuncs)은 이 판정에서 뺀다 —
      // `#[async_trait]` 의 몸통(async 블록)은 레코드도 DA 도 안 남는다(실측, async-trait 0.1.92 · rustc 1.89: poll 한 메서드도 버린
      // 메서드도 머리·닫는 줄에 바깥 횟수뿐). 이 판정을 걸면 돈 메서드가 전부 「안 돌았다」가 된다(독립 레그 3차) — 그래서 보통 fn
      // 처럼 「부르면 실행」이다. 한계 둘: 속성 매크로 async fn 의 버린 퓨처 · 제네릭 · 기본 메서드 async fn 을 두 타입으로 부르고
      // 하나도 poll 안 한 것은 실행으로 읽힌다(바깥 레코드 둘).
      else if (fn.async && fn.hit < 2) mine.push({ ...at, label: 'called, but its async body never ran' })
    }
    if (broken) continue
    files.push({ file: f, stmts, covered, outside })
    never.push(...mine)
    // 함수마다 안 돈 줄 — 단위 미도달 장부(unitReport)가 쓴다(통합 리포트는 never 만 쓴다). 데이터의 줄(DA)만 센다 — 위 async 판정(돈
    // 레코드 수)은 단위 데이터에서 뜻이 없다: 바이너리마다 레코드가 따로라 바깥 레코드가 여럿이고, poll 안 된 몸통의 줄은 라이브러리 단위
    // 시험 바이너리의 0 회 레코드로 이미 든다(머리 주석).
    if (SUITE === 'unit') for (const fn of src.funcs) units.push({ file: f, line: fn.start, name: fn.name, lines: fn.stmts - fn.covered })
  }
  if (SUITE !== 'unit') return { path, files, never }
  // ── 여기부터 단위 미도달 장부만 ──
  // 항목 밖 줄(어느 이름 범위에도 안 드는 — 매크로가 펼친 코드가 항목 밖 자리를 가리킬 때)의 안 돈 줄은 어느 함수에도 못 붙인다 — FAIL 이다
  // (go 의 패키지 수준 함수 리터럴 · python 의 모듈 수준과 같은 판정). 경계가 한 줄도 안 돈 실행이면 그 판정(ranNothing — 측정 실패)이 먼저다.
  const ranSome = files.some((x) => x.covered > 0)
  for (const x of files) if (ranSome && x.outside.covered < x.outside.stmts) fail('rust', `${x.file}: ${x.outside.stmts - x.outside.covered} of ${x.outside.stmts} lines outside every item (module level — code a macro placed there) never ran — no function can be credited with them`)
  // run 기록 — go · python 과 같은 이유(손으로 돌린 실행 · 실패한 실행 · 다른 실행이 덮어쓴 데이터). lcov 에는 소스 해시가 없어(줄 번호뿐이다)
  // 경계 파일의 바이트도 기록과 대조한다. 다른 판정 뒤에 두되 앞의 실패가 있어도 낸다(두 까닭이 한 번에 보인다).
  const runRec = RUST_RUN()
  let rec = null
  try {
    rec = JSON.parse(readFileSync(runRec, 'utf8'))
  } catch {
    rec = null
  }
  const isObj = (x) => x !== null && typeof x === 'object' && !Array.isArray(x)
  const sha = (b) => createHash('sha1').update(b).digest('hex')
  if (!isObj(rec) || rec.run !== 'rust' || (rec.suite ?? 'integration') !== SUITE) {
    fail('rust', `no record that \`${RUN_CMD} rust\` wrote this data (${runRec.replace(/\\/g, '/')}) — run the suite through the script (node scripts/integration-coverage.mjs ${RUN_CMD} rust) so the report can tell a complete, successful run`)
    return null
  }
  if (rec.exit !== 0) {
    fail('rust', `the run that wrote this data exited ${rec.exit} — the data of a failed run is partial`)
    return null
  }
  if (rec.data_sha1 !== sha(bytes)) {
    fail('rust', `${shown} is not the data \`${RUN_CMD} rust\` recorded (sha1 ${String(rec.data_sha1).slice(0, 12)}… recorded, ${sha(bytes).slice(0, 12)}… now) — another run wrote over it`)
    return null
  }
  if (!isObj(rec.files)) {
    fail('rust', 'the record has no boundary hashes — the boundary files changed while the suite ran, so the data may come from other bytes')
    return null
  }
  for (const f of d.files) {
    const now = existsSync(join(root, f)) ? sha(readFileSync(join(root, f))) : null
    if (rec.files[f] !== now) fail('rust', `${f}: the data was taken from other bytes (sha1 ${String(rec.files[f]).slice(0, 12)}… recorded, ${String(now).slice(0, 12)}… in the tree) — rerun the suite on this tree`)
  }
  // 툴체인이 줄의 귀속을 바꾼다(머리 주석) — 판을 찍어 수가 바뀐 DRIFT 가 코드 때문인지 판 때문인지 보이게 한다(판정하지 않는다).
  return { path, note: `${typeof rec.rustc === 'string' && rec.rustc ? rec.rustc : 'rustc ?'} · lines (DA)`, files, never, units }
}

// ── php: PHPUnit XML 커버리지(`--coverage-xml` — index.xml + 파일마다 `<경로>.xml`) ──────────────────
// 태그를 차례로 읽는다 — php-code-coverage 가 DOMDocument 로 쓴 기계의 XML 이다(속성은 큰따옴표). 주석 · 처리 지시 · DOCTYPE ·
// CDATA 는 건너뛴다. 속성 값 속의 `>`(시그니처의 `=>`)는 따옴표 안이라 태그를 끊지 않는다.
const XML_ENT = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" }
const xmlText = (s) =>
  s.replace(/&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);/g, (_, e) =>
    e[0] === '#' ? String.fromCodePoint(e[1] === 'x' ? parseInt(e.slice(2), 16) : Number(e.slice(1))) : XML_ENT[e],
  )
function xmlTags(src) {
  const tags = []
  const re = /<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!\[CDATA\[[\s\S]*?\]\]>|<!DOCTYPE[^>]*>|<(\/?)([A-Za-z_][\w.:-]*)((?:\s+[\w.:-]+\s*=\s*"[^"]*")*)\s*(\/?)>/g
  for (const m of src.matchAll(re)) {
    if (!m[2]) continue
    const attrs = {}
    for (const a of m[3].matchAll(/([\w.:-]+)\s*=\s*"([^"]*)"/g)) attrs[a[1]] = xmlText(a[2])
    tags.push({ close: m[1] === '/', name: m[2], attrs, empty: m[4] === '/' })
  }
  return tags
}
const xmlCount = (v) => (/^\d+$/.test(v ?? '') ? Number(v) : NaN)
// `run php` 의 기록(종료코드 · index.xml 의 sha1) — 데이터 디렉터리 옆에 둔다(그 디렉터리는 run 이 매번 지우고 PHPUnit 이 쓴다).
// 단위(`unit php`)는 `.unit` 이 붙은 이름이다(SUITE).
const PHP_RUN = () => join(out, `php${TAG}.run.json`)
const PHP_DATA = () => join(out, `php${TAG}`)
// 짧은 이름 — `Xzawed\Keycloak\Admin\AdminClient` → `AdminClient`, 함수 `Fixture\…\adminHelper` → `adminHelper`.
const phpShort = (n) => n.slice(n.lastIndexOf('\\') + 1)
// 그 스위트(SUITE — 통합이나 단위)의 테스트 클래스 — 단위 설정 `<testsuite name="…">` 의 `<directory>`(suffix · prefix — 기본
// `Test.php`)와 `<file>` 로 디스크에서 찾은 파일 이름이다(PSR-4: 클래스 이름 = 파일 이름). 다른 고르기(`<exclude>` 등)는 이 리더가
// 모르므로 FAIL 이다 — 무엇이 스위트인지 모르면 데이터가 그 스위트의 것인지 가를 수 없다.
function phpSuiteClasses(d) {
  const site = `${d.dir}/phpunit.xml`
  if (!existsSync(join(root, site))) {
    fail('php', `${site} is missing — the ${SUITE} testsuite cannot be read`)
    return null
  }
  // 주석은 같은 길이의 공백으로 덮는다 — 지우면(`''`) 겹친 꼴(`<!<!---->--`)이 한 번 지운 뒤 `<!--` 로 남는다(CodeQL
  // js/incomplete-multi-character-sanitization — 이 PR 의 첫 판이 그 경보를 냈다).
  const x = readFileSync(join(root, site), 'utf8').replace(/<!--[\s\S]*?-->/g, (m) => m.replace(/[^\n]/g, ' '))
  const suites = [...x.matchAll(new RegExp(`<testsuite\\s+name="${SUITE}"\\s*>([\\s\\S]*?)<\\/testsuite>`, 'g'))]
  if (suites.length !== 1) {
    fail('php', `${site} must define exactly one <testsuite name="${SUITE}"> (found ${suites.length}) — the report checks the data against it`)
    return null
  }
  const body = suites[0][1]
  const known = /<(directory|file)((?:\s+[\w-]+="[^"]*")*)\s*>\s*([^<]+?)\s*<\/\1>/g
  if (body.replace(known, '').trim() !== '') {
    fail('php', `${site}: the ${SUITE} testsuite selects tests with something other than <directory> and <file> — this reader does not know which tests it runs`)
    return null
  }
  const classes = new Set()
  for (const m of body.matchAll(known)) {
    const path = join(root, d.dir, m[3])
    if (m[1] === 'file') {
      classes.add(basename(m[3]).replace(/\.php$/, ''))
      continue
    }
    if (!existsSync(path)) {
      fail('php', `${site}: the ${SUITE} testsuite directory ${m[3]} does not exist`)
      return null
    }
    const suffix = m[2].match(/suffix="([^"]*)"/)?.[1] ?? 'Test.php'
    const prefix = m[2].match(/prefix="([^"]*)"/)?.[1] ?? ''
    for (const f of readdirSync(path, { recursive: true })) {
      const b = basename(String(f))
      if (b.endsWith(suffix) && b.startsWith(prefix) && b.endsWith('.php')) classes.add(b.slice(0, -4))
    }
  }
  if (!classes.size) {
    fail('php', `${site}: the ${SUITE} testsuite finds no test files — a report over no tests is vacuous`)
    return null
  }
  return classes
}
function phpReport(d) {
  const dir = PHP_DATA()
  const shown = dir.replace(/\\/g, '/')
  const index = join(dir, 'index.xml')
  if (!existsSync(index)) {
    fail('php', `no coverage data at ${shown}/index.xml — run the ${SUITE} suite first (node scripts/integration-coverage.mjs ${RUN_CMD} php)`)
    return null
  }
  const tags = xmlTags(readFileSync(index, 'utf8'))
  const project = tags.find((t) => !t.close && t.name === 'project')
  if (!tags.some((t) => !t.close && t.name === 'phpunit') || !project?.attrs.source) {
    fail('php', `${shown}/index.xml is not a PHPUnit code-coverage XML report (no <phpunit><project source>) — run writes --coverage-xml`)
    return null
  }
  // 데이터가 통합 스위트의 실행에서 났는가 — index.xml 의 <tests> 는 그 테스트 동안 경계 파일이 **실린**(컴파일된) 테스트와 그
  // 결과다: php-code-coverage `CodeCoverage::append` 는 걸러 낸 파일 맵이 비면(`lineCoverage() === []`) 등록 전에 돌아가고,
  // Xdebug 는 실린 파일의 안 돈 줄도 넘긴다(`XDEBUG_CC_UNUSED` — 독립 레그 2차 실측: `class_exists` 만 한 테스트도 실린다).
  // 실측: 경계 파일을 안 싣는 ZeroIT 는 안 실린다. 단위 테스트가 섞였거나(통합 전용이 아니다) 실린 테스트가 실패했으면 FAIL —
  // 독립 레그 1차 실측: 생성 설정에 `--testsuite unit --filter …`(단위 26 개)로 돌린 데이터를 이 리더가 수치로 냈다(소유 문제
  // exit 1 — 그때 레인은 1 을 경고로 지났다). 경계에 닿기 전에 실패한 테스트 · 일부 클래스만 거른 실행은 이 목록으로 못
  // 가른다 — 그것은 끝의 run 기록(종료코드 · index.xml 해시)이 막는다.
  const suite = phpSuiteClasses(d)
  if (!suite) return null
  const tests = tags.filter((t) => !t.close && t.name === 'test')
  const bad = tests.filter((t) => t.attrs.status !== 'success')
  if (bad.length) {
    const eg = bad.slice(0, 3).map((t) => `${t.attrs.name} (${t.attrs.status ?? 'no status'})`).join(' · ')
    fail('php', `${bad.length} of ${tests.length} tests in the run did not succeed — the data of a failed run is partial: ${eg}`)
    return null
  }
  const ran = new Set(tests.map((t) => phpShort(String(t.attrs.name ?? '').split('::')[0])))
  const foreign = [...ran].filter((c) => !suite.has(c)).sort()
  if (foreign.length) {
    fail('php', `the run included tests outside the ${SUITE} suite (${foreign.join(' · ')}) — the report would not be ${SUITE}-only`)
    return null
  }
  const driver = tags.find((t) => t.name === 'driver')?.attrs ?? {}
  const build = tags.find((t) => t.name === 'build')?.attrs ?? {}
  const src = project.attrs.source.replace(/\\/g, '/').replace(/\/+$/, '')
  const srcRel = toRepoPath(src, d.dir)
  if (/^([A-Za-z]:)?\//.test(srcRel)) {
    fail('php', `the data's project source ${src} is outside this tree — the data belongs to another checkout`)
    return null
  }
  // index 의 파일 — `href` 는 프로젝트 원천 아래 상대 경로 + `.xml` 이다. 합은 그 <file> 안의 첫 <lines>(<totals>)다.
  const entries = new Map()
  for (let i = 0; i < tags.length; i++) {
    const t = tags[i]
    if (t.close || t.name !== 'file') continue
    const { href, hash } = t.attrs
    let lines = null
    for (let j = i + 1; j < tags.length && !(tags[j].close && tags[j].name === 'file'); j++)
      if (tags[j].name === 'lines') {
        lines = tags[j].attrs
        break
      }
    if (!href?.endsWith('.xml') || !/^[0-9a-f]{40}$/.test(hash ?? '') || !lines) {
      fail('php', `${shown}/index.xml has a <file> without href · sha1 hash · line totals (${href ?? '?'}) — not the report this reader knows`)
      return null
    }
    const rel = posix.normalize(`${srcRel}/${href.slice(0, -4)}`)
    if (entries.has(rel)) {
      fail('php', `${rel} has two entries in ${shown}/index.xml — the data contradicts itself`)
      return null
    }
    entries.set(rel, { href, hash, exec: xmlCount(lines.executable), done: xmlCount(lines.executed) })
  }
  const files = []
  const never = []
  // 함수마다의 실행 가능 줄 · 안 돈 줄 — 단위 미도달 장부(unitReport)가 쓴다(통합 리포트는 never 만 쓴다).
  const units = []
  for (const f of sortU(d.files)) {
    const e = entries.get(f)
    if (!e) {
      fail('php', `${f} is not in the coverage data — a boundary file the run did not report would silently leave the denominator`)
      continue
    }
    if (!existsSync(join(root, f))) {
      fail('php', `${f} is in the data but not in the tree — the data belongs to another checkout`)
      continue
    }
    // 데이터의 해시는 그 실행이 읽은 바이트의 sha1 이다 — 실행 뒤 소스가 바뀌었거나 다른 체크아웃의 데이터면 줄 번호가 어긋난다.
    const sha = createHash('sha1').update(readFileSync(join(root, f))).digest('hex')
    if (sha !== e.hash) {
      fail('php', `${f}: the data was taken from other bytes (sha1 ${e.hash.slice(0, 12)}… in the data, ${sha.slice(0, 12)}… in the tree) — run and report on the same tree`)
      continue
    }
    const fx = join(dir, ...e.href.split('/'))
    if (!existsSync(fx)) {
      fail('php', `cannot read ${shown}/${e.href} — index.xml names it for ${f}`)
      continue
    }
    const ft = xmlTags(readFileSync(fx, 'utf8'))
    const tot = ft.find((t) => t.name === 'lines')?.attrs ?? {}
    const exec = xmlCount(tot.executable)
    const done = xmlCount(tot.executed)
    const base = e.href.slice(e.href.lastIndexOf('/') + 1)
    if (Number.isNaN(exec) || Number.isNaN(done) || Number.isNaN(e.exec) || Number.isNaN(e.done)) {
      fail('php', `${f}: cannot read the line totals in ${base} or index.xml`)
      continue
    }
    if (exec !== e.exec || done !== e.done) {
      fail('php', `${f}: index.xml says ${e.exec}/${e.done} executable/executed lines, ${base} says ${exec}/${done} — the data contradicts itself`)
      continue
    }
    // 메서드(클래스 · 트레이트 안)와 함수. 메서드는 `짧은 클래스::이름`, 파일 수준 함수는 짧은 이름이다.
    const fileUnits = []
    let owner = null
    let broken = false
    for (const t of ft) {
      if ((t.name === 'class' || t.name === 'trait') && !t.empty) owner = t.close ? null : phpShort(t.attrs.name ?? '')
      else if (!t.close && (t.name === 'method' || t.name === 'function')) {
        if (t.name === 'method' && !owner) {
          fail('php', `${f}: the data has a method (${t.attrs.name}) outside any class or trait — not a container this reader knows`)
          broken = true
          break
        }
        const u = {
          name: t.name === 'method' ? `${owner}::${t.attrs.name}` : phpShort(t.attrs.name ?? ''),
          line: xmlCount(t.attrs.start),
          exec: xmlCount(t.attrs.executable),
          done: xmlCount(t.attrs.executed),
        }
        if ([u.line, u.exec, u.done].some(Number.isNaN) || u.done > u.exec) {
          fail('php', `${f}: cannot read the counts of ${u.name} in ${base}`)
          broken = true
          break
        }
        fileUnits.push(u)
      }
    }
    if (broken) continue
    const dup = fileUnits.find((u, i) => fileUnits.findIndex((v) => v.name === u.name) !== i)
    if (dup) {
      fail('php', `${f}: two functions are both named ${dup.name} — the owner keys would collide`)
      continue
    }
    const sum = fileUnits.reduce((a, u) => ({ exec: a.exec + u.exec, done: a.done + u.done }), { exec: 0, done: 0 })
    if (sum.exec !== exec || sum.done !== done) {
      fail('php', `${f}: its methods and functions account for ${sum.exec} of ${exec} executable lines (${sum.done} of ${done} executed) — lines outside any method cannot be attributed to a function`)
      continue
    }
    files.push({ file: f, stmts: exec, covered: done, outside: { stmts: 0, covered: 0 } })
    for (const u of fileUnits) if (u.exec > 0 && u.done === 0) never.push({ file: f, line: u.line, name: u.name, stmts: u.exec })
    for (const u of fileUnits) units.push({ file: f, line: u.line, name: u.name, lines: u.exec - u.done })
  }
  // 줄이 돌았는데 그 줄을 돈 테스트가 하나도 안 실렸다 — 위 판정(스위트 · 결과)을 건너뛴 데이터다.
  if (!tests.length && files.some((f) => f.covered > 0)) {
    fail('php', `${shown}/index.xml counts executed lines but lists no tests — the data contradicts itself`)
    return null
  }
  // run 기록 — 이 데이터를 `run php`(거르지 않은 통합 스위트)가 썼고 그 실행이 성공했는가. 손으로 돌린 실행 · 거른 실행 ·
  // 실패한 실행(경계에 닿기 전에 실패한 테스트는 위 목록에 안 실린다)의 데이터는 수치를 내지 않는다. 다른 판정 뒤에 둔다 —
  // 데이터가 스스로 모순이면 그 문구가 먼저다. 기록의 `suite` 는 단위 실행만 쓴다(`unit` — 없으면 통합이다).
  const runRec = PHP_RUN()
  let rec = null
  try {
    rec = JSON.parse(readFileSync(runRec, 'utf8'))
  } catch {
    rec = null
  }
  if (!rec || rec.run !== 'php' || (rec.suite ?? 'integration') !== SUITE) {
    fail('php', `no record that \`${RUN_CMD} php\` wrote this data (${runRec.replace(/\\/g, '/')}) — run the suite through the script (node scripts/integration-coverage.mjs ${RUN_CMD} php) so the report can tell a complete, successful run`)
    return null
  }
  if (rec.exit !== 0) {
    fail('php', `the run that wrote this data exited ${rec.exit} — the data of a failed run is partial (a test that fails before it reaches the boundary is not in the data at all)`)
    return null
  }
  const indexSha = createHash('sha1').update(readFileSync(index)).digest('hex')
  if (rec.index_sha1 !== indexSha) {
    fail('php', `${shown}/index.xml is not the data \`${RUN_CMD} php\` recorded (sha1 ${String(rec.index_sha1).slice(0, 12)}… recorded, ${indexSha.slice(0, 12)}… now) — another run wrote over it`)
    return null
  }
  const note = `driver ${driver.name ?? '?'} ${driver.version ?? '?'} · php-code-coverage ${build.coverage ?? '?'}`
  return { path: dir, note, files, never, units }
}

// ── ruby: run 이 쓰는 덤프(Ruby `Coverage` 의 lines · methods + 예제 결과 — 머리 주석) ───────────────
// 형식 /2 = /1(lines · methods)에 파일마다 branches 를 더한 것이다 — 두 리더 다 이 판만 받는다(/1 덤프에는 가지가 없어 단위 장부가
// 가지를 0 으로 셀 뻔했다).
const RUBY_FORMAT = 'kcsdk-ruby-coverage/2'
// 단위(`unit ruby`)는 `.unit` 이 붙은 이름이다(SUITE).
const RUBY_DATA = () => join(out, `ruby${TAG}.json`)
const RUBY_RUN = () => join(out, `ruby${TAG}.run.json`)
// 부트 파일 — run 이 `<out>/ruby-boot/`(단위는 `ruby.unit-boot/`)에 쓴다(저장소에 두지 않는다 · 픽스처도 이 run 으로 만든다).
const RUBY_START = `# frozen_string_literal: true

# Written by scripts/integration-coverage.mjs \`${RUN_CMD} ruby\`. Loaded BEFORE bundler/setup, so Coverage sees every lib file
# (the gemspec require_relative's version.rb during bundler setup). No gem may load here: one activated outside the
# bundle would clash with it.
require "coverage"
Coverage.start(lines: true, branches: true, methods: true)
`
const RUBY_DUMP = `# frozen_string_literal: true

# Written by scripts/integration-coverage.mjs \`${RUN_CMD} ruby\`. Loaded by \`rspec --require\`: after the suite, before
# SimpleCov's at_exit stops Coverage, it dumps this tree's lib files and the example results.
require "json"
require "digest"

RSpec.configure do |config|
  config.after(:suite) do
    root = File.expand_path(ENV.fetch("KCSDK_ITCOV_ROOT"))
    lib = "#{root}/lib/"
    fold = Gem.win_platform? ? :downcase.to_proc : :itself.to_proc
    files = {}
    Coverage.peek_result.each do |path, cov|
      abs = File.expand_path(path)
      next unless fold.call(abs).start_with?(fold.call(lib))

      methods = (cov[:methods] || {}).map do |(owner, name, sl, sc, el, ec), count|
        { "owner" => owner.inspect, "name" => name.to_s, "start" => [sl, sc], "end" => [el, ec], "count" => count }
      end
      # Branch sites (if, unless, case, while, until, ternary, &.) with each arm's count. Coverage without branches gives nil,
      # written as null so the reader fails instead of counting no branches.
      branches = cov[:branches]&.map do |(type, _id, sl, sc, el, ec), arms|
        { "type" => type.to_s, "start" => [sl, sc], "end" => [el, ec],
          "arms" => arms.map do |(arm, _aid, asl, asc, ael, aec), count|
            { "type" => arm.to_s, "start" => [asl, asc], "end" => [ael, aec], "count" => count }
          end }
      end
      files[abs] = { "sha1" => Digest::SHA1.file(abs).hexdigest, "lines" => cov[:lines], "methods" => methods,
                     "branches" => branches }
    end
    examples = RSpec.configuration.reporter.examples.map do |e|
      { "id" => e.id, "file" => e.metadata[:file_path], "integration" => e.metadata[:integration] ? true : false,
        "status" => e.execution_result.status.to_s }
    end
    File.write(ENV.fetch("KCSDK_ITCOV_OUT"),
               JSON.generate({ "format" => "${RUBY_FORMAT}", "root" => root, "ruby" => RUBY_VERSION,
                               "examples" => examples, "files" => files }))
  end
end
`
// VM 의 소유자 문자열(`Module#inspect`)에서 짧은 이름 — 인스턴스 메서드 `Clients#list` · 특이 메서드 `Http.get`.
// 익명 클래스(`#<Class:0x…>`) 같은 다른 꼴은 이름을 못 단다(null → FAIL).
function rubyName(owner, name) {
  const short = (q) => q.slice(q.lastIndexOf(':') + 1)
  const single = /^#<Class:([A-Z]\w*(?:::[A-Z]\w*)*)>$/.exec(owner)
  if (single) return `${short(single[1])}.${name}`
  if (/^[A-Z]\w*(?:::[A-Z]\w*)*$/.test(owner)) return `${short(owner)}#${name}`
  return null
}
const isCount = (x) => Number.isInteger(x) && x >= 0
function rubyReport(d) {
  const path = RUBY_DATA()
  const shown = path.replace(/\\/g, '/')
  if (!existsSync(path)) {
    fail('ruby', `no coverage data at ${shown} — run the ${SUITE} suite first (node scripts/integration-coverage.mjs ${RUN_CMD} ruby)`)
    return null
  }
  const bytes = readFileSync(path)
  let j
  try {
    j = JSON.parse(bytes.toString('utf8'))
  } catch {
    fail('ruby', `${shown} is not JSON`)
    return null
  }
  if (j === null || typeof j !== 'object' || j.format !== RUBY_FORMAT || typeof j.root !== 'string' || !Array.isArray(j.examples) ||
    typeof j.files !== 'object' || j.files === null || Array.isArray(j.files)) {
    fail('ruby', `${shown} is not the dump \`${RUN_CMD} ruby\` writes (format ${RUBY_FORMAT})`)
    return null
  }
  if (toRepoPath(j.root, d.dir) !== d.dir) {
    fail('ruby', `the dump's root ${j.root.replace(/\\/g, '/')} is not ${d.dir}/ of this tree — the data belongs to another checkout`)
    return null
  }
  // 예제 — 그 스위트(SUITE)의 것만, 전부 통과. 통합 스위트는 `spec/integration` 의 `:integration` 이다. 덤프는 스위트가 끝난 뒤
  // 쓰이므로 실패한 예제도 실린다.
  const ex = j.examples
  if (!ex.every((e) => e && typeof e.id === 'string' && typeof e.file === 'string' && typeof e.status === 'string')) {
    fail('ruby', `${shown} has an example without id · file · status — not the dump this reader knows`)
    return null
  }
  if (!ex.length) fail('ruby', 'the run recorded no examples — a report over no tests is vacuous')
  const bad = ex.filter((e) => e.status !== 'passed')
  if (bad.length) {
    const eg = bad.slice(0, 3).map((e) => `${e.id} (${e.status})`).join(' · ')
    fail('ruby', `${bad.length} of ${ex.length} examples in the run did not pass — the data of a failed run is partial: ${eg}`)
  }
  const underIt = (e) => posix.normalize(e.file.replace(/\\/g, '/')).startsWith('spec/integration/')
  if (SUITE === 'unit') {
    // 단위 스위트는 통합 스위트 밖의 예제다 — 레인의 단위 명령(경로 · 태그 없는 `bundle exec rspec`)은 spec/integration 의 파일도 싣고
    // spec_helper 가 `:integration` 예제를 거른다. 태그와 자리가 갈리는 예제(태그 없이 spec/integration 에 있다 · 태그를 달고 그 밖에
    // 있다)는 어느 쪽인지 모르므로 섞인 것으로 본다(dotnet 의 단위 판정과 같은 쪽 — 모르면 수치를 내지 않는다).
    const mixed = ex.filter((e) => e.integration !== false || underIt(e))
    if (mixed.length) {
      const eg = sortU(mixed.map((e) => e.id)).slice(0, 3).join(' · ')
      fail('ruby', `the run included examples of the integration suite or examples it cannot place (${eg}) — the data would not be unit-only (unit ruby runs the lane's bundle exec rspec without RUN_INTEGRATION, so spec_helper leaves out :integration; the integration suite = :integration examples under spec/integration)`)
    }
  } else {
    const foreign = ex.filter((e) => e.integration !== true || !underIt(e))
    if (foreign.length) {
      const eg = sortU(foreign.map((e) => e.id)).slice(0, 3).join(' · ')
      fail('ruby', `the run included examples outside the integration suite (${eg}) — the report would not be integration-only`)
    }
  }
  const entries = new Map()
  for (const [abs, v] of Object.entries(j.files)) {
    const rel = toRepoPath(abs, d.dir)
    if (!rel.startsWith(`${d.dir}/`)) {
      fail('ruby', `the data has ${abs.replace(/\\/g, '/')}, outside this tree — the data belongs to another checkout`)
      return null
    }
    if (entries.has(rel)) fail('ruby', `${rel} has two entries in ${shown} — the data contradicts itself`)
    entries.set(rel, v)
  }
  for (const rel of entries.keys()) if (!existsSync(join(root, rel))) fail('ruby', `${rel} is in the data but not in the tree — the data belongs to another checkout`)
  const files = []
  const never = []
  // 메서드마다 안 돈 몸통 줄 — 단위 미도달 장부(unitReport)가 쓴다(통합 리포트는 never 만 쓴다).
  const units = []
  for (const f of d.files) {
    const e = entries.get(f)
    if (!e) {
      fail('ruby', `${f} is not in the coverage data — a boundary file the run never loaded would silently leave the denominator`)
      continue
    }
    if (typeof e !== 'object' || typeof e.sha1 !== 'string' || !Array.isArray(e.lines) || !Array.isArray(e.methods)) {
      fail('ruby', `${f}: the entry has no sha1 · lines · methods — not the dump this reader knows`)
      continue
    }
    const src = readFileSync(join(root, f))
    const sha = createHash('sha1').update(src).digest('hex')
    if (sha !== e.sha1) {
      fail('ruby', `${f}: the data was taken from other bytes (sha1 ${e.sha1.slice(0, 12)}… in the data, ${sha.slice(0, 12)}… in the tree) — rerun the suite on this tree`)
      continue
    }
    if (!e.lines.every((c) => c === null || isCount(c))) {
      fail('ruby', `${f}: cannot read the line counts in ${shown}`)
      continue
    }
    // 가지 — 형식 /2 의 VM branches: 자리(if · unless · case · while · until · 삼항 · &.)마다 갈래와 그 횟수다. 단위 미도달 장부만
    // 세지만(통합 리포트는 쓰지 않는다) 꼴은 두 스위트가 다 본다 — 못 읽는 가지를 0 개로 세지 않는다.
    const span = (p) => Array.isArray(p) && p.length === 2 && p.every(isCount)
    const site = (b) => b !== null && typeof b === 'object' && typeof b.type === 'string' && span(b.start) && span(b.end) && Array.isArray(b.arms) &&
      b.arms.length > 0 && b.arms.every((a) => a !== null && typeof a === 'object' && typeof a.type === 'string' && span(a.start) && span(a.end) && isCount(a.count))
    if (!Array.isArray(e.branches) || !e.branches.every(site)) {
      fail('ruby', `${f}: cannot read the branch counts in ${shown}`)
      continue
    }
    const far = e.branches.find((b) => b.start[0] < 1 || b.end[0] < b.start[0] || b.end[0] > e.lines.length)
    if (far) {
      fail('ruby', `${f}: the ${far.type} branch at lines ${far.start[0]}–${far.end[0]} lies outside the ${e.lines.length} lines the data counts — the data contradicts itself`)
      continue
    }
    const ms = []
    let broken = false
    for (const m of e.methods) {
      const ok = m && typeof m.owner === 'string' && typeof m.name === 'string' && Array.isArray(m.start) && Array.isArray(m.end) &&
        m.start.length === 2 && m.end.length === 2 && [...m.start, ...m.end, m.count].every(isCount)
      if (!ok) {
        fail('ruby', `${f}: cannot read a method record (${m?.owner ?? '?'} ${m?.name ?? '?'}) in ${shown}`)
        broken = true
        break
      }
      const name = rubyName(m.owner, m.name)
      if (!name) {
        fail('ruby', `${f}:${m.start[0]}: cannot name the method ${m.name} of ${m.owner} — not an owner this reader knows (anonymous class?)`)
        broken = true
        break
      }
      const [sl] = m.start
      const [el] = m.end
      if (sl < 1 || el < sl || el > e.lines.length) {
        fail('ruby', `${f}: ${name} spans lines ${sl}–${el}, outside the ${e.lines.length} lines the data counts — the data contradicts itself`)
        broken = true
        break
      }
      ms.push({ name, sl, el, count: m.count })
    }
    if (broken) continue
    const seen = new Set()
    const dup = ms.find((m) => (seen.has(m.name) ? true : (seen.add(m.name), false)))
    if (dup) {
      fail('ruby', `${f}: two methods are both named ${dup.name} — the owner keys would collide`)
      continue
    }
    ms.sort((a, b) => a.sl - b.sl || b.el - a.el)
    const lap = ms.findIndex((m, k) => k > 0 && m.sl <= ms[k - 1].el)
    if (lap > 0) {
      const [a, b] = [ms[lap - 1], ms[lap]]
      // `module_function` 은 인스턴스 메서드와 그 특이 사본을 **같은 범위**로 싣는다(독립 레그 실측: 경계 밖 masking.rb 의
      // `Masking#mask` · `Masking.mask` 둘 다 8–10). 합치지 않는다(어느 쪽 호출인지 따로 센다) — 그 경우를 문구로 짚는다.
      const twin = a.sl === b.sl && a.el === b.el && a.name.replace('.', '#') === b.name.replace('.', '#')
      const why = twin ? ' (module_function? it records the instance method and its singleton copy on the same lines — this reader does not merge them)' : ''
      fail('ruby', `${f}: ${b.name} (${b.sl}–${b.el}) lies inside or across ${a.name} (${a.sl}–${a.el}) — a line cannot be given to one method${why}`)
      continue
    }
    // 메서드 범위 = def 다음 줄부터 end 까지(def 줄은 정의할 때 — 적재 때 — 돈다). 한 줄 메서드는 그 줄이 정의이자 몸통이라
    // 줄 횟수로는 못 가른다 — 호출 횟수로 센다.
    const at = new Array(e.lines.length + 1).fill(-1)
    ms.forEach((m, k) => {
      if (m.sl === m.el) at[m.sl] = k
      else for (let ln = m.sl + 1; ln <= m.el; ln++) at[ln] = k
    })
    const lines = { stmts: 0, covered: 0 }
    const bodies = { stmts: 0, covered: 0 }
    const per = ms.map(() => ({ stmts: 0, covered: 0 }))
    let orphan = 0
    e.lines.forEach((c, i) => {
      if (c === null) return
      const ln = i + 1
      lines.stmts++
      if (c > 0) lines.covered++
      const k = at[ln]
      if (k < 0) {
        if (c === 0 && !orphan) orphan = ln
        return
      }
      const hit = ms[k].sl === ms[k].el ? ms[k].count > 0 : c > 0
      bodies.stmts++
      per[k].stmts++
      if (hit) {
        bodies.covered++
        per[k].covered++
      }
    })
    if (orphan) {
      fail('ruby', `${f}:${orphan}: a line outside every method never ran although the file was loaded — a block or lambda body no method can be credited with`)
      continue
    }
    const contra = ms.find((m, k) => m.count === 0 && per[k].covered > 0)
    if (contra) {
      fail('ruby', `${f}: ${contra.name} was called 0 times but a line of its body ran — the data contradicts itself`)
      continue
    }
    // 안 탄 갈래는 자리의 첫 줄로 메서드에 붙인다 — 가지는 def 줄까지가 메서드의 것이다(기본 인자의 결정은 호출 때 돈다). 블록 · 람다의
    // 자리는 감싼 메서드의 범위 안이라 그 메서드의 수다. 범위는 서로 겹치지 않는다(위 판정) — 한 줄은 많아야 한 메서드의 것이다.
    const missed = ms.map(() => 0)
    let stray = null
    for (const b of e.branches) {
      const k = ms.findIndex((m) => m.sl <= b.start[0] && b.start[0] <= m.el)
      const n = b.arms.filter((a) => a.count === 0).length
      if (k >= 0) missed[k] += n
      else if (n && !stray) stray = b
    }
    // 메서드 밖 자리의 안 탄 갈래(클래스 수준 삼항 · 클래스 수준 람다 안의 결정)는 어느 메서드에도 못 붙인다 — 단위 장부는 FAIL 이다(위
    // 메서드 밖 0 회 줄과 같은 판정). 통합 리포트는 가지를 안 세므로 묻지 않는다.
    if (stray && SUITE === 'unit') {
      fail('ruby', `${f}:${stray.start[0]}: the ${stray.type} branch there sits outside every method and has an arm the run never took — no method can be credited with it`)
      continue
    }
    files.push({ file: f, stmts: lines.stmts, covered: lines.covered, bodies })
    ms.forEach((m, k) => {
      if (m.count === 0) never.push({ file: f, line: m.sl, name: m.name, stmts: per[k].stmts, label: per[k].stmts ? undefined : 'empty body' })
      // 한 줄 메서드의 줄은 위 hit 처럼 호출 횟수로 센다 — 몸통에 줄이 없는 메서드는 0 줄이다(머리 주석).
      units.push({ file: f, line: m.sl, name: m.name, lines: per[k].stmts - per[k].covered, branches: missed[k] })
    })
  }
  // run 기록 — php 와 같은 이유(손으로 돌린 실행 · 실패한 실행 · 다른 실행이 덮어쓴 데이터). 다른 판정 뒤에 둔다 — 데이터가
  // 스스로 모순이면 그 문구가 먼저고, 앞의 실패가 있어도 기록 판정은 함께 낸다(php 와 같다 — 두 까닭이 한 번에 보인다).
  const runRec = RUBY_RUN()
  let rec = null
  try {
    rec = JSON.parse(readFileSync(runRec, 'utf8'))
  } catch {
    rec = null
  }
  // 기록의 `suite` 는 단위 실행만 쓴다(`unit` — 없으면 통합이다). 다른 스위트의 기록이면 기록이 없는 것과 같다.
  if (!rec || rec.run !== 'ruby' || (rec.suite ?? 'integration') !== SUITE) {
    fail('ruby', `no record that \`${RUN_CMD} ruby\` wrote this data (${runRec.replace(/\\/g, '/')}) — run the suite through the script (node scripts/integration-coverage.mjs ${RUN_CMD} ruby) so the report can tell a complete, successful run`)
    return null
  }
  if (rec.exit !== 0) {
    fail('ruby', `the run that wrote this data exited ${rec.exit} — the data of a failed run is partial`)
    return null
  }
  const dumpSha = createHash('sha1').update(bytes).digest('hex')
  if (rec.dump_sha1 !== dumpSha) {
    fail('ruby', `${shown} is not the data \`${RUN_CMD} ruby\` recorded (sha1 ${String(rec.dump_sha1).slice(0, 12)}… recorded, ${dumpSha.slice(0, 12)}… now) — another run wrote over it`)
    return null
  }
  const runs = SUITE === 'unit' ? ` · branches · ${ex.length} unit example${ex.length === 1 ? '' : 's'}` : ''
  return { path, note: `ruby ${typeof j.ruby === 'string' ? j.ruby : '?'} · Coverage lines · methods${runs}`, files, never, units }
}

// ── dotnet — coverlet 컬렉터의 고유 JSON ──────────────────────────────────────────────────
// 단위(`unit dotnet`)는 `.unit` 이 붙은 이름이다(SUITE).
const DOTNET_DATA = () => join(out, `dotnet${TAG}.json`)
const DOTNET_TRX = () => join(out, `dotnet${TAG}.trx`)
const DOTNET_RUN = () => join(out, `dotnet${TAG}.run.json`)
// run 이 쓰는 컬렉터 설정 — 형식만 json 이고 **거르지 않는다**(경계는 리포트가 파일 경로로 고른다). 단위 설정의 `<Exclude>` 를
// 뒤집은 `<Include>` 는 컴파일러가 만든 중첩 타입(async 상태 기계 · 람다 클래스)을 떨어뜨린다 — 실측(2026-11-06, 실제 트리):
// 경계 10 파일의 428 줄 중 바깥 타입의 것은 175 뿐이다(머리 주석의 211/312 와 같은 꼴).
const DOTNET_SETTINGS = `<?xml version="1.0" encoding="utf-8" ?>
<RunSettings>
  <DataCollectionRunSettings>
    <DataCollectors>
      <DataCollector friendlyName="XPlat code coverage">
        <Configuration>
          <Format>json</Format>
        </Configuration>
      </DataCollector>
    </DataCollectors>
  </DataCollectionRunSettings>
</RunSettings>
`
// 컴파일러가 만든 이름 하나를 벗긴다 — `<M>d__N`(async · 이터레이터 상태 기계 — 제네릭 메서드면 `<M>d__N`1`) · `<<M>b__N_K>d`
// (async 람다의 상태 기계) · `<M>b__N_K`(람다) · `<M>g__L|N_K`(로컬 함수) → 감싼 소스 멤버 M. 모르는 `<…>` 꼴이면 null.
function csPeel(s) {
  let x = s
  for (;;) {
    if (!x.startsWith('<')) return x
    const m = /^<(.+)>(?:d__\d+(?:`\d+)?|d|b__\d+(?:_\d+)?|g__.+)$/.exec(x)
    if (!m) return null
    x = m[1]
  }
}
// coverlet 의 클래스 · 메서드 하나 → { type, member, kind, params } — kind 는 plain(소스 메서드 그대로) · sm(상태 기계) ·
// lambda(람다 · 로컬 함수). 이름을 못 붙이면 null.
function dotnetFold(cls, sig) {
  const sm = /^(.*?)::([^(]+)\((.*)\)$/.exec(sig)
  if (!sm) return null
  const [, , name, params] = sm
  const segs = cls.split('/')
  const user = []
  let gen = null
  for (const seg of segs) {
    if (!seg.startsWith('<')) {
      if (gen !== null) return null
      user.push(seg)
      continue
    }
    if (gen === null) gen = []
    gen.push(seg)
  }
  if (!user.length) return null
  const type = [user[0].slice(user[0].lastIndexOf('.') + 1), ...user.slice(1)].join('.')
  const display = (m) => (m === '.ctor' ? '#ctor' : m === '.cctor' ? '#cctor' : m)
  if (gen === null) {
    // 바깥 타입의 메서드 — 이름이 생성 꼴이면 람다(this 만 잡는)나 로컬 함수다.
    if (!name.startsWith('<')) return { type, member: display(name), kind: 'plain', params }
    const m = csPeel(name)
    return m === null ? null : { type, member: display(m), kind: 'lambda', params }
  }
  // 생성 타입 안 — 상태 기계면 그 이름이, 람다 캐시(`<>c`)면 메서드 이름이 멤버를 댄다. 클로저 클래스(`<>c__DisplayClassN_K`)는
  // 데이터에 따로 안 나온다 — coverlet 이 그 람다의 줄을 감싼 메서드 아래 싣는다(실측: 픽스처 `Prefixed`). 그 꼴이 나오면 모르는
  // 꼴이다(상태 기계로 읽혀 MoveNext 가 아니면 FAIL).
  const machine = gen.find((g) => g !== '<>c')
  if (machine !== undefined) {
    if (name !== 'MoveNext') return null
    const m = csPeel(machine)
    return m === null ? null : { type, member: display(m), kind: machine.endsWith('>d') ? 'lambda' : 'sm', params: null, machine }
  }
  if (!name.startsWith('<')) return null
  const m = csPeel(name)
  return m === null ? null : { type, member: display(m), kind: 'lambda', params }
}
// 통합 스위트의 기대 클래스 — trx 에는 범주가 없다. **클래스 선언에 붙은** `[Trait("Category", "Integration")]`(사이에 다른 특성 ·
// 한정자가 올 수 있다)이 고른 클래스다(네임스페이스째). 같은 파일의 다른 클래스는 기대 집합이 아니다. 메서드에 붙은 것처럼 클래스에
// 안 붙은 그 특성은 이 리더가 모르는 꼴이다 — 그 파일들을 `stray` 로 돌려준다(FAIL — 독립 레그 지적: 파일 단위로 고르면 특성 없는
// 테스트가 섞인 실행이 통과했다).
function dotnetSuite(dir) {
  const files = []
  const walk = (p) => {
    for (const e of readdirSync(p, { withFileTypes: true })) {
      if (e.isDirectory()) {
        if (!['bin', 'obj', '.git', 'node_modules'].includes(e.name)) walk(join(p, e.name))
      } else if (e.name.endsWith('.cs')) files.push(join(p, e.name))
    }
  }
  walk(dir)
  const set = new Set()
  const stray = []
  for (const f of files) {
    const src = readFileSync(f, 'utf8').replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ')
    const ns = /(?:^|[;{}\s])namespace\s+([\w.]+)\s*[;{]/.exec(src)?.[1]
    for (const m of src.matchAll(/\[\s*Trait\s*\(\s*"Category"\s*,\s*"Integration"\s*\)\s*\]/g)) {
      // 사이의 특성은 괄호 한 겹까지 받는다(`[Foo(typeof(int[]))]` — 독립 레그 2차 지적: `]` 에서 끊겨 진짜 특성이 stray 가 됐다).
      // record 는 한정자로도(`record class X`) 선언 낱말로도(`record X` — 레그 3차 지적) 온다.
      const decl = /^(?:\s*\[(?:[^[\]]|\[[^[\]]*\])*\])*\s*(?:(?:public|internal|private|protected|sealed|static|partial|abstract|unsafe|new|file|record)\s+)*(?:class|record)\s+(\w+)/.exec(src.slice(m.index + m[0].length))
      if (!decl) stray.push(f)
      else set.add(ns ? `${ns}.${decl[1]}` : decl[1])
    }
  }
  return { set, stray }
}
// ⚠️ dotnet 은 줄 · 횟수를 coverlet 컬렉터의 고유 JSON(`모듈 → 문서(절대 경로) → 클래스 → 메서드(전체 시그니처) → Lines`)에서,
// 이름을 컴파일러가 만든 이름에서 받는다. async · 이터레이터 메서드는 바깥 클래스에 **없고** 중첩 상태 기계 `T/<M>d__N` 의
// `MoveNext` 가 몸통 줄을 든다(실측 — 킥오프 스텁은 실리지 않는다). 람다(`T/<>c` 의 `<M>b__…` — 클로저 클래스의 람다는 coverlet 이
// 감싼 메서드 아래 싣는다) · 로컬 함수(`<M>g__…`) · async 람다(`<<M>b__N_K>d`)는 감싼 메서드 M 에 접는다(go 의 함수 리터럴 · node 의 콜백과 같다). 모르는
// `<…>` 꼴은 FAIL 이다. 오버로드는 시그니처로 가르되, 상태 기계나 람다가 붙은 오버로드는 어느 쪽 것인지 못 가르므로 FAIL 이다.
// ⚠️ coverlet 은 **줄** 단위로 잰다 — 한 줄의 횟수는 그 줄의 모든 코드의 합이고 그 줄은 메서드 하나 아래에만 실린다(실측:
// 픽스처 `Joined` 32 행 = return 1 + 람다 2). 그래서 자기 줄이 없는 메서드(같은 줄의 auto-property setter · 같은 줄의 람다)는
// 데이터에 따로 없다 — 그 줄의 다른 코드가 돌면 덮인 것으로 센다(미실행 목록에서 빠진다 — 줄 단위 계측의 한계). opencover 형식도
// 같은 모델이다(열이 모두 1–2 · visited 가 모두 true — 실측).
// 데이터에 소스 해시가 없다 — run 이 경계 파일의 sha1 을 실행 앞뒤로 재 기록에 싣고(같을 때만), report 가 트리의 바이트와 대조한다.
// 문서 키는 절대 경로다 — CI 의 결정적 빌드(`ContinuousIntegrationBuild` — PDB 에는 `/_/`)에서도 컬렉터가 실제 경로로 되돌린다(실측).
// 가지는 메서드마다의 `Branches`(가지 점마다 경로 둘 — `Line` · `Hits`)다 — 줄과 같이 접고 오버로드로 가른다. 단위 미도달 장부만 쓴다
// (`units` — 머리 주석의 「dotnet 도 가지를 센다」).
function dotnetReport(d) {
  const path = DOTNET_DATA()
  const shown = path.replace(/\\/g, '/')
  if (!existsSync(path)) {
    fail('dotnet', `no coverage data at ${shown} — run the ${SUITE} suite first (node scripts/integration-coverage.mjs ${RUN_CMD} dotnet)`)
    return null
  }
  const bytes = readFileSync(path)
  let j
  try {
    j = JSON.parse(bytes.toString('utf8'))
  } catch {
    fail('dotnet', `${shown} is not JSON`)
    return null
  }
  const isObj = (x) => x !== null && typeof x === 'object' && !Array.isArray(x)
  if (!isObj(j) || !Object.values(j).every(isObj)) {
    fail('dotnet', `${shown} is not coverlet's JSON (module → document → class → method)`)
    return null
  }
  // 문서 — 전부 이 트리 안이어야 한다(다른 체크아웃의 데이터가 아니다).
  const docs = new Map()
  for (const [mod, ds] of Object.entries(j)) {
    for (const [abs, classes] of Object.entries(ds)) {
      const rel = toRepoPath(abs, d.dir)
      if (!rel.startsWith(`${d.dir}/`)) {
        fail('dotnet', `the data has ${abs.replace(/\\/g, '/')} (${mod}), outside this tree — the data belongs to another checkout`)
        return null
      }
      if (docs.has(rel)) fail('dotnet', `${rel} is in two modules of ${shown} (${docs.get(rel).mod} · ${mod}) — the data contradicts itself`)
      docs.set(rel, { mod, classes })
    }
  }
  for (const rel of docs.keys()) if (!existsSync(join(root, rel))) fail('dotnet', `${rel} is in the data but not in the tree — the data belongs to another checkout`)
  // trx — 이 실행의 테스트 결과. 그 스위트(SUITE)만 · 전부 통과.
  const trxPath = DOTNET_TRX()
  const trxShown = trxPath.replace(/\\/g, '/')
  let trx = null
  try {
    trx = readFileSync(trxPath, 'utf8')
  } catch {
    trx = null
  }
  let note = 'coverlet json'
  if (trx === null) fail('dotnet', `no test results at ${trxShown} — run the ${SUITE} suite through the script (node scripts/integration-coverage.mjs ${RUN_CMD} dotnet)`)
  else {
    const attr = (tag, a) => new RegExp(`\\b${a}="([^"]*)"`).exec(tag)?.[1]
    // 테스트 어셈블리도 이 트리의 것이어야 한다(다른 체크아웃의 결과가 아니다).
    for (const m of trx.matchAll(/<TestMethod\b[^>]*>/g)) {
      const cb = attr(m[0], 'codeBase')
      const rel = cb === undefined ? null : toRepoPath(cb, d.dir)
      if (rel === null || !rel.startsWith(`${d.dir}/`)) {
        fail('dotnet', `the test results ran ${cb === undefined ? 'an assembly with no codeBase' : cb.replace(/\\/g, '/')}, outside this tree — they belong to another checkout`)
        break
      }
    }
    const results = [...trx.matchAll(/<UnitTestResult\b[^>]*>/g)].map((m) => ({ id: attr(m[0], 'testId'), name: attr(m[0], 'testName'), outcome: attr(m[0], 'outcome') }))
    const classOf = new Map()
    for (const m of trx.matchAll(/<UnitTest\b([^>]*)>([\s\S]*?)<\/UnitTest>/g)) {
      const id = attr(m[1], 'id')
      const tm = /<TestMethod\b[^>]*>/.exec(m[2])
      if (id && tm) classOf.set(id, attr(tm[0], 'className'))
    }
    if (!results.length) fail('dotnet', 'the run recorded no tests — a report over no tests is vacuous')
    const bad = results.filter((r) => r.outcome !== 'Passed')
    if (bad.length) {
      const eg = bad.slice(0, 3).map((r) => `${r.name} (${r.outcome ?? '?'})`).join(' · ')
      fail('dotnet', `${bad.length} of ${results.length} tests in the run did not pass — the data of a failed run is partial: ${eg}`)
    }
    const { set: suite, stray } = dotnetSuite(join(root, d.dir))
    for (const f of sortU(stray)) fail('dotnet', `${toRepoPath(f, d.dir)} has a [Trait("Category", "Integration")] that is not on a class declaration — this reader reads the suite from class-level traits only`)
    if (SUITE === 'unit') {
      // 단위 스위트는 통합 스위트 밖의 시험이다(레인의 `--filter "Category!=Integration"`). 정의에 잇지 못하는 결과는 어느 쪽인지 모르므로
      // 섞인 것으로 본다(통합 판정이 그것을 스위트 밖으로 보는 것과 같은 쪽 — 모르면 수치를 내지 않는다).
      const mixed = results.filter((r) => {
        const c = classOf.get(r.id)
        return c === undefined || suite.has(c)
      })
      if (mixed.length) {
        const eg = sortU(mixed.map((r) => r.name ?? '?')).slice(0, 3).join(' · ')
        fail('dotnet', `the run included tests of the integration suite or tests it cannot place (${eg}) — the data would not be unit-only (unit dotnet runs --filter "Category!=Integration"; the integration suite = classes whose declaration carries [Trait("Category", "Integration")])`)
      }
    } else {
      const foreign = results.filter((r) => !suite.has(classOf.get(r.id)))
      if (foreign.length) {
        const eg = sortU(foreign.map((r) => r.name ?? '?')).slice(0, 3).join(' · ')
        fail('dotnet', `the run included tests outside the integration suite (${eg}) — the report would not be integration-only (the suite = classes whose declaration carries [Trait("Category", "Integration")])`)
      }
    }
    const rt = /\(64-bit \.NET ([\d.]+)\)/.exec(trx)?.[1]
    note = `.NET ${rt ?? '?'} · coverlet json · ${results.length} ${SUITE === 'unit' ? 'unit ' : ''}test${results.length === 1 ? '' : 's'}`
  }
  const files = []
  const never = []
  // 함수마다 0 회인 줄 · 0 회인 가지 — 단위 미도달 장부(unitReport)가 쓴다(통합 리포트는 never 만 쓴다).
  const units = []
  for (const f of d.files) {
    const e = docs.get(f)
    if (!e) {
      fail('dotnet', `${f} is not in the coverage data — a boundary file the run never compiled into a measured module would silently leave the denominator`)
      continue
    }
    if (!isObj(e.classes) || !Object.values(e.classes).every(isObj)) {
      fail('dotnet', `${f}: the entry is not class → method in ${shown}`)
      continue
    }
    // 파생과 디스크가 갈렸다(파생 도구가 읽은 뒤 지워진 파일) — 독립 레그 지적: 여기서 예외로 죽었다.
    if (!existsSync(join(root, f))) {
      fail('dotnet', `${f} is derived but missing on disk — the data cannot be checked against it`)
      continue
    }
    const src = readFileSync(join(root, f), 'utf8')
    const nlines = src.split('\n').length
    const methods = new Map()
    let broken = false
    for (const [cls, ms] of Object.entries(e.classes)) {
      for (const [sig, v] of Object.entries(ms)) {
        const lines = v?.Lines
        if (!isObj(lines) || !Object.entries(lines).every(([k, c]) => /^[1-9]\d*$/.test(k) && isCount(c))) {
          fail('dotnet', `${f}: cannot read the line counts of ${sig} in ${shown}`)
          broken = true
          break
        }
        // 가지 — coverlet 은 가지가 없는 메서드에도 빈 배열을 싣는다(실측). 없거나 꼴이 다르면 가지 수를 셀 수 없다.
        const branches = v?.Branches
        if (!Array.isArray(branches) || !branches.every((b) => isObj(b) && Number.isInteger(b.Line) && b.Line >= 1 && isCount(b.Hits))) {
          fail('dotnet', `${f}: cannot read the branch counts of ${sig} in ${shown}`)
          broken = true
          break
        }
        const fo = dotnetFold(cls, sig)
        if (!fo) {
          fail('dotnet', `${f}: cannot name ${cls}::${sig.replace(/^.*?::/, '')} — not a generated name this reader knows`)
          broken = true
          break
        }
        const key = `${fo.type}.${fo.member}`
        const m = methods.get(key) ?? { plain: new Map(), machines: new Set(), lambdas: 0, lines: new Map(), branches: [] }
        if (fo.kind === 'sm') m.machines.add(fo.machine)
        else if (fo.kind === 'lambda') m.lambdas++
        // 시그니처마다 따로 든다 — 오버로드면 그것으로 가른다(아래). 가지도 줄과 같이 그 시그니처의 것이다.
        const own = fo.kind === 'plain' ? (m.plain.get(fo.params) ?? { lines: new Map(), branches: [] }) : null
        for (const [k, c] of Object.entries(lines)) {
          const ln = Number(k)
          if (ln > nlines) {
            fail('dotnet', `${f}: ${key} counts line ${ln}, past the ${nlines} lines of the file — the data contradicts the tree`)
            broken = true
            break
          }
          m.lines.set(ln, (m.lines.get(ln) ?? 0) + c)
          if (own) own.lines.set(ln, (own.lines.get(ln) ?? 0) + c)
        }
        if (broken) break
        const past = branches.find((b) => b.Line > nlines)
        if (past) {
          fail('dotnet', `${f}: ${key} counts a branch on line ${past.Line}, past the ${nlines} lines of the file — the data contradicts the tree`)
          broken = true
          break
        }
        m.branches.push(...branches)
        if (own) {
          own.branches.push(...branches)
          m.plain.set(fo.params, own)
        }
        methods.set(key, m)
      }
      if (broken) break
    }
    if (broken) continue
    // 오버로드 — 몸통(시그니처 · 상태 기계)이 둘 이상이면 갈라야 한다. 상태 기계나 람다가 붙으면 어느 오버로드의 것인지 모른다.
    const per = new Map()
    let amb = null
    for (const [key, m] of methods) {
      if (m.plain.size + m.machines.size <= 1) per.set(key, m)
      else if (m.machines.size || m.lambdas) amb ??= key
      else for (const [p, own] of m.plain) per.set(`${key}(${p})`, own)
    }
    if (amb) {
      fail('dotnet', `${f}: ${amb} has overloads and a state machine or lambda folds into one of them — this reader cannot tell which`)
      continue
    }
    const fileLines = new Map()
    for (const [key, { lines: ls, branches: bs }] of per) {
      for (const [ln, c] of ls) fileLines.set(ln, (fileLines.get(ln) ?? 0) + c)
      if (ls.size && [...ls.values()].every((c) => c === 0)) never.push({ file: f, line: Math.min(...ls.keys()), name: key, stmts: ls.size })
      // 자리는 첫 줄이다 — 줄 없이 가지만 실린 이름(같은 줄의 람다)은 첫 가지의 줄.
      const at = ls.size ? Math.min(...ls.keys()) : bs.length ? Math.min(...bs.map((b) => b.Line)) : 0
      units.push({ file: f, line: at, name: key, lines: [...ls.values()].filter((c) => c === 0).length, branches: bs.filter((b) => b.Hits === 0).length })
    }
    const covered = [...fileLines.values()].filter((c) => c > 0).length
    // coverlet 은 메서드 밖 줄을 싣지 않는다(필드 초기화는 생성자 · 정적 생성자의 줄이다).
    files.push({ file: f, stmts: fileLines.size, covered, outside: { stmts: 0, covered: 0 } })
  }
  // run 기록 — php · ruby 와 같은 이유. 다른 판정 뒤에 두되 앞의 실패가 있어도 낸다(두 까닭이 한 번에 보인다).
  const runRec = DOTNET_RUN()
  let rec = null
  try {
    rec = JSON.parse(readFileSync(runRec, 'utf8'))
  } catch {
    rec = null
  }
  const sha = (b) => createHash('sha1').update(b).digest('hex')
  // 기록의 `suite` 는 단위 실행만 쓴다(`unit` — 없으면 통합이다). 다른 스위트의 기록이면 기록이 없는 것과 같다.
  if (!rec || rec.run !== 'dotnet' || (rec.suite ?? 'integration') !== SUITE) {
    fail('dotnet', `no record that \`${RUN_CMD} dotnet\` wrote this data (${runRec.replace(/\\/g, '/')}) — run the suite through the script (node scripts/integration-coverage.mjs ${RUN_CMD} dotnet) so the report can tell a complete, successful run`)
    return null
  }
  if (rec.exit !== 0) {
    fail('dotnet', `the run that wrote this data exited ${rec.exit} — the data of a failed run is partial`)
    return null
  }
  if (rec.data_sha1 !== sha(bytes)) {
    fail('dotnet', `${shown} is not the data \`${RUN_CMD} dotnet\` recorded (sha1 ${String(rec.data_sha1).slice(0, 12)}… recorded, ${sha(bytes).slice(0, 12)}… now) — another run wrote over it`)
    return null
  }
  if (trx !== null && rec.trx_sha1 !== sha(readFileSync(trxPath))) {
    fail('dotnet', `${trxShown} is not the test result \`${RUN_CMD} dotnet\` recorded — another run wrote over it`)
    return null
  }
  if (!isObj(rec.files)) {
    fail('dotnet', 'the record has no boundary hashes — the boundary files changed while the suite ran, so the data may come from other bytes')
    return null
  }
  for (const f of d.files) {
    const now = existsSync(join(root, f)) ? sha(readFileSync(join(root, f))) : null
    if (rec.files[f] !== now) fail('dotnet', `${f}: the data was taken from other bytes (sha1 ${String(rec.files[f]).slice(0, 12)}… recorded, ${String(now).slice(0, 12)}… in the tree) — rerun the suite on this tree`)
  }
  return { path, note, files, never, units }
}

// ── java ─────────────────────────────────────────────────────────────────────────────────
// ⚠️ java 는 줄 · 횟수를 JaCoCo 에서 받는다 — failsafe IT 만 돈 실행의 exec 를 JaCoCo CLI 가 XML 로 쓴다(pom 의 `report` 골은
// 플러그인 단위 `<excludes>` = 경계를 리포트에서 빼므로 못 쓴다 · 에이전트 계측은 그 파일 꼴 패턴에 안 걸린다 — 실측). 이름과
// 메서드마다의 줄은 클래스 파일에서 받는다(javap — LineNumberTable · EnclosingMethod): XML 에는 메서드의 첫 줄과 줄 수뿐이다.
// run 은 javap 의 출력을 **그대로** 두고 리포트가 읽어 푼다 — 푼 사실을 따로 두면 그 파서는 run 에서만 돈다(자가테스트는 데이터를
// 주고 report 만 부른다 — 파서의 판정을 하나도 못 지난다).
// 람다(`lambda$m$N` — `static` · `new` 는 정적 초기화 · 생성자)는 감싼 메서드에, 익명 · 지역 클래스(`T$1` · `T$1Local`)의 메서드는
// javap 가 댄 감싼 메서드에 접는다. 오버로드는 서술자로 가르고, 람다는 LineNumberTable 로 그것을 만든 오버로드를 찾는다(못 가르면
// FAIL — jvmReport). 모르는 `$` · `<…>` 꼴은 FAIL 이다(fail-closed).
// ⚠️ 줄은 소스 파일 단위 합집합이다(`<sourcefile><line>`) — 바깥 클래스와 익명 클래스가 한 줄을 함께 가질 수 있어 클래스별 합은 그
// 줄을 두 번 센다(실측: AdminClient.java 61 = 54 + 8 − 1). 정적 초기화(`<clinit>`)만 가진 줄은 클래스가 실릴 때 돈다 —
// 「아무것도 안 돈 실행」 판정과 bodies 는 그 줄을 뺀다(python · ruby 와 같은 까닭 — JVM 의 static init, #774 가 짚은 함정).
// ⚠️ kotlin 도 이 리더다 — 클래스 파일 · JaCoCo 는 같고 접기만 다르다(ktFold — 합성 메서드는 이름이 아니라 코드로 접는다:
// 람다는 만드는 메서드, 다리는 부르는 대상, 로컬 함수는 부르는 메서드). `internal` 멤버는 모듈 이름 접미를 벗긴다(`name$<모듈>` —
// 모듈 이름의 식별자 밖 글자는 `_` · 실측 `applyTimeouts$io_github_xzawed_keycloak_sdk_kotlin`). suspend 함수의 이어받기
// 클래스(`AuthClient$authSend$1`)는 줄표가 없어 JaCoCo 가 빈 클래스로 싣는다(실측 — 사실과 데이터 둘 다에 있다).
// run kotlin 의 Gradle 초기화 스크립트 — 빌드 파일을 안 바꾸고 재는 태스크 하나(`kcsdkItcovTask` — 통합은 `integrationTest`, 단위
// 미도달 장부는 `test`)에만 JaCoCo 에이전트를 붙인다. 그 태스크의 Kover 에이전트는 Kover 의 DSL(`instrumentation.disabledForTestTasks` —
// build.gradle.kts 가 integrationTest 에 쓰는 그 손잡이)로 끈다 — 두 에이전트가 한 클래스를 고쳐 쓰면 JaCoCo 의 클래스 id 가 디스크의
// 클래스와 어긋날 수 있다(실측: 끈 실행은 Kover 의 bin-reports 가 비었다). 그 DSL 을 못 찾으면 빌드가 실패한다(fail-closed). 에이전트와
// CLI 는 Gradle 이 그 빌드의 저장소에서 받는다(kotlin 레인은 Maven 을 안 쓴다). kotlin 의 `$` 보간이 JS 에 안 먹히게 문자열 배열로 쓴다.
const KOTLIN_INIT = [
  '// integration-coverage.mjs (run kotlin · unit kotlin) — attaches a JaCoCo agent to the measured test task only and switches',
  "// Kover's own agent off for that task; the build files stay as they are.",
  'allprojects {',
  '    val ver = findProperty("kcsdkItcovJacoco") as String? ?: return@allprojects',
  '    val task = findProperty("kcsdkItcovTask") as String? ?: "integrationTest"',
  '    pluginManager.withPlugin("org.jetbrains.kotlinx.kover") {',
  '        val kover = extensions.getByName("kover")',
  '        val dsl = { n: String -> Class.forName("kotlinx.kover.gradle.plugin.dsl.$n", true, kover.javaClass.classLoader) }',
  '        val current = dsl("KoverProjectExtension").getMethod("getCurrentProject").invoke(kover)',
  '        val instrumentation = dsl("KoverCurrentProjectVariantsConfig").getMethod("getInstrumentation").invoke(current)',
  '        @Suppress("UNCHECKED_CAST")',
  '        val off = dsl("KoverProjectInstrumentation").getMethod("getDisabledForTestTasks").invoke(instrumentation) as org.gradle.api.provider.SetProperty<String>',
  '        off.add(task)',
  '    }',
  '    val agent = configurations.detachedConfiguration(dependencies.create("org.jacoco:org.jacoco.agent:$ver:runtime"))',
  '    val cli = configurations.detachedConfiguration(dependencies.create("org.jacoco:org.jacoco.cli:$ver:nodeps"))',
  '    tasks.withType<Test>().matching { it.name == task }.configureEach {',
  '        val exec = findProperty("kcsdkItcovExec") as String',
  '        doFirst { jvmArgs("-javaagent:" + agent.singleFile.absolutePath + "=destfile=" + exec) }',
  '        outputs.upToDateWhen { false }',
  '    }',
  '    tasks.register<Copy>("kcsdkItcovCli") {',
  '        from(cli)',
  '        into(findProperty("kcsdkItcovCli") as String)',
  '    }',
  '}',
  '',
].join('\n')
const JVM_DATA = (l) => join(out, `${l}${TAG}.xml`)
const JVM_JAVAP = (l) => join(out, `${l}${TAG}.javap.txt`)
const JVM_RUN = (l) => join(out, `${l}${TAG}.run.json`)
const JVM_EXEC = (l) => join(out, `${l}${TAG}.exec`)
// `javap -l -p -v <클래스 파일…>` 의 출력 → { 내부 이름: { source, enclosing: { class, method, desc } | null, methods: [{ name, desc,
// lines, calls, news, lambdas, tail }] } }. `this_class` 는 상수 풀보다 앞이라 그 주석(내부 이름)을 읽고, EnclosingMethod 는 상수 풀(Class ·
// NameAndType)로 푼다. 코드에서는 부르는 메서드(`invoke*` 의 주석 — `owner.name:desc`) · 만드는 클래스(`new`) · 만드는 람다 몸통
// (`invokedynamic` → BootstrapMethods 의 LambdaMetafactory 구현 핸들)을 읽는다 — kotlin 의 접기가 쓴다(ktFold).
function javapFacts(text) {
  const facts = {}
  let cur = null
  let meth = null
  let inLnt = false
  let inLvt = false
  let inBody = false
  let bsm = null
  const finish = () => {
    if (!cur?.name) return
    let enclosing = null
    if (cur.encRef) {
      const c = cur.pool.get(cur.encRef[0])
      const nt = cur.encRef[1] === '0' ? null : cur.pool.get(cur.encRef[1])
      const nd = nt?.note && /^"?([^":]+)"?:(\S+)$/.exec(nt.note)
      enclosing = { class: c?.kind === 'Class' ? (c.note ?? null) : null, method: nd ? nd[1] : null, desc: nd ? nd[2] : null }
    }
    // 람다 몸통 — LambdaMetafactory 부트스트랩의 구현 핸들뿐이다(문자열 연결 같은 다른 부트스트랩은 메서드를 안 만든다).
    for (const x of cur.methods) x.lambdas = x.indy.map((i) => cur.bootstraps.get(i)).filter((h) => h !== undefined)
    facts[cur.name] = { source: cur.source, enclosing, methods: cur.methods, kmeta: cur.kmeta }
  }
  for (const raw of text.split(/\r?\n/)) {
    if (raw.startsWith('Classfile ')) {
      finish()
      cur = { name: null, source: null, encRef: null, pool: new Map(), methods: [], bootstraps: new Map(), meta: false, kmeta: null }
      meth = null
      inLnt = false
      inLvt = false
      inBody = false
      bsm = null
      continue
    }
    if (!cur) continue
    let m
    // BootstrapMethods — 클래스 몸통 뒤의 첫 칸 구역(항목은 두 칸 · 인자는 여섯 칸). 다음 첫 칸 줄에서 끝난다.
    if (raw === 'BootstrapMethods:') {
      bsm = { index: null, lambda: false }
      continue
    }
    if (bsm && /^\S/.test(raw)) bsm = null
    if (bsm) {
      if ((m = /^  (\d+): #\d+ REF_\w+ (\S+)/.exec(raw))) bsm = { index: m[1], lambda: /^java\/lang\/invoke\/LambdaMetafactory\.(?:metafactory|altMetafactory):/.test(m[2]) }
      else if (bsm.lambda && (m = /^      #\d+ REF_\w+ (\S+)\s*$/.exec(raw))) {
        // 첫 메서드 핸들 인자가 구현 메서드다(그 뒤의 인자는 메서드 타입 · altMetafactory 의 표지).
        const h = jvmRef(m[1], cur.name)
        if (h) cur.bootstraps.set(bsm.index, h)
        bsm = { index: bsm.index, lambda: false }
      }
      continue
    }
    if ((m = /^\s+#(\d+) = (\w+)\s+\S+(?:\s+\/\/\s*(.*?))?\s*$/.exec(raw))) {
      cur.pool.set(m[1], { kind: m[2], note: m[3] ?? null })
      continue
    }
    // 상수 풀의 다른 줄(공백이 든 Utf8 등) — 멤버 머리로 읽지 않는다.
    if (/^\s+#\d+ = /.test(raw)) continue
    // 멤버 구역은 첫 칸의 `{` … `}` 다 — 그 밖의 두 칸 줄(InnerClasses · BootstrapMethods 항목)은 멤버가 아니다.
    if (raw === '{') {
      inBody = true
      continue
    }
    if (raw === '}') {
      inBody = false
      meth = null
      inLnt = false
      inLvt = false
      continue
    }
    if ((m = /^\s+this_class: #\d+\s+\/\/\s*(\S+)\s*$/.exec(raw))) {
      cur.name = m[1]
      continue
    }
    if ((m = /^SourceFile: "(.+)"$/.exec(raw))) {
      cur.source = m[1]
      continue
    }
    if ((m = /^EnclosingMethod: #(\d+)\.#(\d+)/.exec(raw))) {
      cur.encRef = [m[1], m[2]]
      continue
    }
    // kotlin 메타데이터의 종류 `k=` — 클래스 몸통 뒤 RuntimeVisibleAnnotations 의 `kotlin.Metadata(` … `)`(네 칸 · 여섯 칸 — 실측
    // javap 21; 메서드의 주석은 여덟 칸이다). 다른 주석의 `k` 요소는 종류가 아니다. 4 · 5 는 `@file:JvmMultifileClass` 의 파사드 ·
    // 부분이다(jvmReport 가 FAIL 한다).
    if (/^    kotlin\.Metadata\(\s*$/.test(raw)) {
      cur.meta = true
      continue
    }
    if (cur.meta && (m = /^      k=(\d+)\s*$/.exec(raw))) {
      cur.kmeta = Number(m[1])
      continue
    }
    if (cur.meta && /^    \)\s*$/.test(raw)) {
      cur.meta = false
      continue
    }
    // 멤버 머리 — 구역 안의 두 칸 들여쓰기. 메서드는 `(` 가 있고 `;` 로 끝난다(필드는 아니다). 생성자는 점 표기 전체 이름이다.
    if (inBody && /^  \S/.test(raw)) {
      const h = raw.slice(2)
      inLnt = false
      inLvt = false
      meth = null
      if (h === 'static {};') meth = { name: '<clinit>', desc: '()V', lines: [], calls: [], news: [], indy: [], lnt: [], code: [] }
      else {
        const p = h.indexOf('(')
        if (p > 0 && h.endsWith(';')) {
          // 이름에는 `-` 도 든다 — kotlin 의 값 클래스 매개변수 맹글(`f-imocxh4` — 실측, 독립 레그).
          const id = /([\w$.<>-]+)$/.exec(h.slice(0, p))?.[1] ?? ''
          meth = { name: id.includes('.') ? '<init>' : id, desc: null, lines: [], calls: [], news: [], indy: [], lnt: [], code: [] }
        }
      }
      if (meth) cur.methods.push(meth)
      continue
    }
    if (meth && (m = /^    descriptor: (\S+)\s*$/.exec(raw))) {
      meth.desc = m[1]
      continue
    }
    // 접근 플래그 — ktFold 가 가른다: 로컬 함수 · 람다 · SAM 참조 어댑터는 private static 이고, 컴패니언 `@JvmStatic` 다리가 부르는
    // 쪽은 인스턴스 메서드다(object 의 `@JvmStatic` 은 정적 메서드다).
    if (meth && (m = /^    flags: \(0x[0-9a-f]+\) (.*)$/.exec(raw))) {
      meth.static = /\bACC_STATIC\b/.test(m[1])
      meth.private = /\bACC_PRIVATE\b/.test(m[1])
      continue
    }
    // 명령 — 메서드마다 끝 일곱만 둔다(ktTail 이 꼬리 호출의 닫는 줄을 가른다). op 는 소문자로 시작한다 — tableswitch 의 갈래 줄
    // (`0: 28` · `default: 37`)은 명령이 아니다. 같은 줄을 아래 호출 · 생성 판정도 읽는다(여기서 continue 하지 않는다).
    if (meth && (m = /^\s+(\d+): ([a-z]\w*)(?:\s+(.*?))?\s*$/.exec(raw))) {
      meth.code.push({ at: Number(m[1]), op: m[2], arg: m[3] ?? '' })
      if (meth.code.length > 7) meth.code.shift()
    }
    // 코드 — `N: invoke… #K // Method owner.name:desc` · `N: new #K // class X` · `N: invokedynamic #K, 0 // InvokeDynamic #B:…` ·
    // `N: getstatic #K // Field X.INSTANCE:…`(싱글턴 클래스는 제 정적 초기화에서 만들고 쓰는 쪽은 INSTANCE 를 읽는다 — 그 자리가
    // 만드는 자리다, 독립 레그 2 실측: 컴패니언 init 의 suspend fun interface 변환).
    if (meth && (m = /^\s+\d+: (invoke\w+|new|getstatic)\s+#\d+.*?\/\/ (.+?)\s*$/.exec(raw))) {
      let k
      if (m[1] === 'invokedynamic') {
        if ((k = /^InvokeDynamic #(\d+):/.exec(m[2]))) meth.indy.push(k[1])
      } else if (m[1] === 'new') {
        if ((k = /^class (\S+)$/.exec(m[2]))) meth.news.push(k[1])
      } else if (m[1] === 'getstatic') {
        if ((k = /^Field ([^.\s]+)\.INSTANCE:/.exec(m[2]))) meth.news.push(k[1])
      } else if ((k = /^(?:Interface)?Method (\S+)$/.exec(m[2]))) {
        const r = jvmRef(k[1], cur.name)
        if (r) meth.calls.push(r)
      }
      continue
    }
    if (meth && /^      LineNumberTable:\s*$/.test(raw)) {
      inLnt = true
      continue
    }
    if (inLnt && (m = /^        line (\d+): (\d+)\s*$/.exec(raw))) {
      meth.lines.push(Number(m[1]))
      meth.lnt.push({ line: Number(m[1]), at: Number(m[2]) })
      continue
    }
    // 지역 변수표 — 기본 인자 다리의 대상을 가른다(ktFold): 인라인 함수의 다리만 표를 가지고, 처음부터 사는 변수가 대상의 매개변수다
    // (마스크 · 표지는 표에 없다 — 실측).
    if (meth && /^      LocalVariableTable:\s*$/.test(raw)) {
      inLvt = true
      meth.lvt = []
      continue
    }
    if (inLvt && (m = /^\s+(\d+)\s+\d+\s+(\d+)\s+(\S+)\s+\S+\s*$/.exec(raw))) {
      meth.lvt.push({ start: Number(m[1]), slot: Number(m[2]), name: m[3] })
      continue
    }
    if (inLvt && /^\s+Start\s+Length\s+Slot\s+Name\s+Signature\s*$/.test(raw)) continue
    inLvt = false
    // 메서드의 `@JvmStatic` 표지(RuntimeVisibleAnnotations 항목) — 컴패니언 `@JvmStatic` 의 바깥 정적 다리를 가른다(ktFold).
    if (meth && /^\s+kotlin\.jvm\.JvmStatic\s*$/.test(raw)) meth.jvmStatic = true
    inLnt = false
  }
  finish()
  for (const c of Object.values(facts)) {
    for (const x of c.methods) {
      // 첫 · 끝 항목(javap 가 낸 차례 = 바이트코드 차례) — 생성자의 몸통은 그 둘 사이다: 첫 항목은 super · this 호출, 끝은 닫는
      // 중괄호의 return 이고, 필드 초기화의 줄은 그 사이 바이트코드에 끼어도 몸통 밖이다(jvmReport).
      x.ends = x.lines.length ? [x.lines[0], x.lines[x.lines.length - 1]] : null
      x.lines = [...new Set(x.lines)].sort((a, b) => a - b)
      // 꼬리 호출의 닫는 줄(ktTail — 없으면 null). 빼는 것은 jvmReport 다(kotlin 만).
      x.tail = ktTail(x)
    }
  }
  return facts
}
// kotlin 꼬리 호출의 닫는 줄(등록부 kotlin-tail-call-return-line-flips) — Unit 을 돌려주는 suspend 함수의 마지막 문장이 Unit 을 돌려주는
// suspend 호출이면 kotlinc 는 그것을 꼬리 호출로 낸다: 호출 뒤 `dup · getCOROUTINE_SUSPENDED · if_acmpne X · areturn · X: pop ·
// getstatic Unit.INSTANCE · areturn` 이고, 닫는 중괄호 줄에는 마지막 areturn 하나만 매긴다(실측 javap: RealmsResource.update
// `line 37: 28`). 그 줄은 호출이 멈추지 않고 돌아왔을 때만 돈다 — 코드가 아니라 스케줄링의 경주다(onIo 가 호출자보다 먼저 끝난 실행 —
// 같은 트리의 단위 장부가 실행마다 갈렸다). JaCoCo 0.8.16 은 멈춤 검사는 거르지만(가지 0) 그 줄은 안 거른다. 끝 일곱 명령이 정확히 이
// 꼴이고, 그 areturn 에서 시작하는 줄표 항목이 하나이며 그 뒤에 시작하는 항목이 없을 때만 그 항목의 줄을 낸다(아니면 null).
const KT_TAIL_SUSPENDED = /^#\d+\s+\/\/ Method kotlin\/coroutines\/intrinsics\/IntrinsicsKt\.getCOROUTINE_SUSPENDED:\(\)Ljava\/lang\/Object;$/
const KT_TAIL_UNIT = /^#\d+\s+\/\/ Field kotlin\/Unit\.INSTANCE:Lkotlin\/Unit;$/
function ktTail(x) {
  const c = x.code
  if (c.length !== 7 || c.map((i) => i.op).join(' ') !== 'dup invokestatic if_acmpne areturn pop getstatic areturn') return null
  if (!KT_TAIL_SUSPENDED.test(c[1].arg) || c[2].arg !== String(c[4].at) || !KT_TAIL_UNIT.test(c[5].arg)) return null
  const end = c[6].at
  const at = x.lnt.filter((e) => e.at === end)
  return at.length === 1 && !x.lnt.some((e) => e.at > end) ? at[0].line : null
}
// 서술자의 매개변수 → 읽을 수 있는 목록(`(Ljava/lang/String;I[B)V` → `String, int, byte[]`). 오버로드 이름에만 쓴다.
function javaParams(desc) {
  const body = /^\(([^)]*)\)/.exec(desc ?? '')?.[1]
  if (body === undefined) return null
  const prim = { B: 'byte', C: 'char', D: 'double', F: 'float', I: 'int', J: 'long', S: 'short', Z: 'boolean' }
  const out = []
  for (let i = 0; i < body.length; ) {
    let dims = 0
    while (body[i] === '[') {
      dims++
      i++
    }
    let t
    if (body[i] === 'L') {
      const e = body.indexOf(';', i)
      if (e < 0) return null
      t = body.slice(i + 1, e)
      t = t.slice(t.lastIndexOf('/') + 1).replace(/\$/g, '.')
      i = e + 1
    } else if (prim[body[i]]) t = prim[body[i++]]
    else return null
    out.push(t + '[]'.repeat(dims))
  }
  return out.join(', ')
}
// javap 가 주석으로 낸 메서드 참조(`owner.name:desc` — 같은 클래스면 `name:desc`, 생성자는 `"<init>"`) → `owner.name:desc`.
function jvmRef(ref, self) {
  const m = /^(?:([^".:]+)\.)?"?([^".:]+)"?:(\(.*)$/.exec(ref)
  return m ? `${m[1] ?? self}.${m[2]}:${m[3]}` : null
}
// JaCoCo 의 메서드 하나(클래스 내부 이름 · 이름 · 서술자) → { type, member, kind, desc, via } — kind 는 plain(소스 메서드 그대로 ·
// 생성자) · static(정적 초기화) · lambda(람다 · 익명/지역 클래스의 메서드). 이름을 못 붙이면 null. 익명 · 지역 클래스는 javap 의
// EnclosingMethod 를 따라 바깥으로 올라간다(그 클래스가 또 익명이면 한 번 더).
function javaFold(cname, name, desc, facts, depth = 0) {
  const slash = cname.lastIndexOf('/')
  const segs = cname.slice(slash + 1).split('$')
  if (segs.some((s) => s === '')) return null
  const local = segs.findIndex((s, i) => i > 0 && /^\d/.test(s))
  if (local > 0) {
    const enc = facts[cname]?.enclosing
    if (!enc || typeof enc.class !== 'string' || depth > 8) return null
    // 필드 초기화 · 초기화 블록 안의 익명 클래스 — 감싼 메서드가 없다(정적인지 인스턴스인지 서술자로 못 가른다).
    if (enc.method === null) return null
    const up = javaFold(enc.class, enc.method, enc.desc, facts, depth + 1)
    return up && { ...up, kind: up.kind === 'static' ? 'static' : 'lambda', via: cname }
  }
  const type = segs.join('.')
  if (name === '<clinit>') return { type, member: '<clinit>', kind: 'static', desc }
  if (name === '<init>') return { type, member: '<init>', kind: 'plain', desc }
  const lm = /^lambda\$(.+)\$\d+$/.exec(name)
  if (lm) {
    const host = lm[1] === 'static' ? '<clinit>' : lm[1] === 'new' ? '<init>' : lm[1]
    if (host.includes('$')) return null
    return { type, member: host, kind: host === '<clinit>' ? 'static' : 'lambda', desc: null, lambdaDesc: desc }
  }
  if (name.includes('$') || name.startsWith('<')) return null
  return { type, member: name, kind: 'plain', desc }
}
// kotlin 의 접기 — 합성 메서드는 이름이 아니라 **클래스 파일의 코드**로 접는다. kotlinc 의 이름은 감싼 것을 다 말하지 않는다
// (실측 2.4.21 — 독립 레그가 컴파일해 보였다): `@JvmName("joinInts")` 함수의 람다는 원래 이름 `join$lambda$1` 이다 · 컴패니언 ·
// object · enum 항목의 `_init_$lambda$N` 은 정적 초기화가 만든다 · 람다 안의 람다는 `…$lambda$0$0` 이다 · object 의 `@JvmStatic`
// 다리는 받는 쪽이 없다 · 로컬 클래스는 이름에 숫자가 없다. 그래서:
//   람다(`…$lambda$N…` · invokedynamic 의 구현인 private static — SAM 참조 어댑터) → 그것을 만드는 invokedynamic 이 든 메서드
//   기본 인자 다리(`…$default`) · 기본 인자 생성자(`<init>(…, int, DefaultConstructorMarker)`) → 그것이 마지막에 부르는 같은 이름(인라인 함수의 다리는 지역 변수표의 매개변수만큼의 서술자 · DefaultImpls 는 인터페이스의 같은 이름 다리) — 다리와 다리가 만든 것(dflt)은 그 함수가 돌았다는 근거가 아니다(jvmReport)
//   suspend inline fun 의 사본 `f$$forInline` → 같은 서술자의 f
//   컴패니언 `@JvmStatic` 바깥 다리 → 그것이 부르는 바로 아래 컴패니언의 같은 이름 · 서술자 인스턴스 멤버(표지가 있을 때만 — 속성은 게터의 표지)
//   로컬 함수(private static `outer$inner`) · 합성 접근자 `access$…` · open suspend fun 의 몸통 `fn$suspendImpl` → 그것을 부르는 메서드
//   익명 · 로컬 클래스(EnclosingMethod 가 있다 — 인라인된 호출부의 `…$$inlined$…` 도)  → 그 메서드(생성자이거나 없으면 — 속성 초기화 · init 블록 — 그 클래스를 `new` 하는 메서드)
// 그 밖의 `$` 든 이름은 모른다(null — FAIL). 그 메서드가 여럿이면 모두 같은 멤버 · 서술자로 접혀야 한다. 못 찾거나 갈리면 null(FAIL). `internal` 은 모듈 접미를 벗긴다
// (kt.mangle). `$suspendImpl` 은 그 fun 자체로 둔다(plain — 그 fun 은 부르기만 해 JaCoCo 가 안 싣는다, 실측).
const KT_INDEX = new WeakMap()
function ktIndex(facts) {
  let ix = KT_INDEX.get(facts)
  if (ix) return ix
  ix = { made: new Map(), called: new Map(), built: new Map() }
  const add = (map, k, site) => map.set(k, [...(map.get(k) ?? []), site])
  for (const [cls, c] of Object.entries(facts)) {
    for (const m of c.methods) {
      for (const h of new Set(m.lambdas)) add(ix.made, h, [cls, m])
      for (const r of new Set(m.calls)) add(ix.called, r, [cls, m])
      for (const n of new Set(m.news)) add(ix.built, n, [cls, m])
    }
  }
  KT_INDEX.set(facts, ix)
  return ix
}
// 접기가 자기에게 돌아온 자리 — 정보가 없다(실패가 아니다): 기본 인자 로컬 함수(`outer$inner` ↔ `outer$inner$default`) · 서로
// 부르는 로컬 함수 · 자기가 만든 람다가 다시 부르는 로컬 함수는 서로를 부른다(독립 레그 2 실측). 그 자리를 빼고 남은 자리로 접는다.
const KT_CYCLE = Symbol('cycle')
function ktFold(cname, name, desc, facts, kt, seen = new Set()) {
  const c = facts[cname]
  const self = `${cname}.${name}:${desc}`
  if (seen.has(self)) return KT_CYCLE
  if (!c || seen.size > 16) return null
  const segs = cname.slice(cname.lastIndexOf('/') + 1).split('$')
  // 빈 마디 — kotlinc 는 인라인된 호출부에서 다시 만든 클래스를 `<바깥>$<함수>$$inlined$<인라인 함수>$N` 으로 낸다(EnclosingMethod 가
  // 있다 — 독립 레그 4 실측: crossinline 람다 · Flow.map 안에서 부른 로컬 함수의 호출자). 그 밖의 빈 마디는 모르는 꼴이다(java 와 같다).
  if (segs.some((s) => s === '') && !(c.enclosing && /\$\$inlined\$/.test(cname))) return null
  const ix = ktIndex(facts)
  const next = new Set(seen).add(self)
  const fold = (cls, n, d) => ktFold(cls, n, d, facts, kt, next)
  // 여러 자리(만드는 · 부르는 · `new` 하는 메서드)를 접어 하나여야 한다. 같은 클래스의 생성자 여럿이면(본 생성자 없는 클래스의
  // 속성 초기화 — 생성자마다 그 코드가 든다, 독립 레그 2 실측) 그 생성자들이 함께 가진다(shared — 어느 하나의 실행 근거가 아니다).
  const one = (sites) => {
    const all = sites.map(([cls, m]) => fold(cls, m.name, m.desc))
    const ups = all.filter((u) => u !== KT_CYCLE)
    if (!ups.length) return all.length ? KT_CYCLE : null
    if (ups.some((u) => !u)) return null
    const key = (u) => `${u.kind === 'static'} ${u.type} ${u.member} ${u.desc} ${u.shared ?? ''}`
    // 한 자리라도 다리를 거쳤으면 다리의 것이다(dflt — 아래 nest): 근거가 아닌 쪽으로 기운다(근거로 세면 안 돈 몸통이 숨는다).
    if (ups.every((u) => key(u) === key(ups[0]))) return ups.some((u) => u.dflt) ? { ...ups[0], dflt: true } : ups[0]
    if (ups.every((u) => u.kind === 'plain' && u.member === '<init>' && u.type === ups[0].type && !u.shared)) {
      return { type: ups[0].type, member: '<init>', kind: 'plain', desc: null, shared: sortU(ups.map((u) => u.desc)) }
    }
    return null
  }
  // dflt — 기본 인자 다리를 거쳐 접혔다: 다리 자신과 다리가 만든 것(기본값 식의 람다 · 익명 객체 · suspend 람다 · 그 안의 로컬 함수)은
  // 그 함수의 몸통이 돌았다는 근거가 아니다(jvmReport). via 는 마지막 걸음만 말하므로 표지는 따로 끝까지 싣는다 — via 로만 가르면
  // 다리가 만든 람다가 몸통의 근거로 남아 재정의된 · 기본값이 던지는 함수의 안 돈 몸통이 숨었다(독립 레그 7 실측 — 여덟 꼴).
  const nest = (up, via) => (up === KT_CYCLE ? up : up && { type: up.type, member: up.member, kind: up.kind === 'static' ? 'static' : 'lambda', desc: up.desc, shared: up.shared, via, dflt: Boolean(up.dflt) || via === 'default' })
  // 그 클래스를 만드는 자리 — 자기 안의 자리는 뺀다: suspend 람다의 `create()` 는 제 클래스를 다시 만드는데, 그 자리의 접기는 바깥
  // 자리들을 다시 모은 것이라(생성자 여럿이면 「함께 가진」 꼴) 바깥 자리와 갈린다(실측 — 레그 2 의 NoPrimarySusp$h$1).
  const builders = () => (ix.built.get(cname) ?? []).filter(([cls]) => cls !== cname)
  // 그 메서드를 부르는 자리 — 자기 자신(재귀) · 자기 안의 이어받기 클래스(suspend 는 그 함수를 다시 부른다)는 접기가 자기에게 돌아와
  // KT_CYCLE 로 빠진다.
  const callers = () => ix.called.get(self) ?? []
  if (c.enclosing) {
    // 익명 · 로컬 클래스 — EnclosingMethod 는 그것을 감싼 함수다(어휘 — 인라인 함수의 객체는 인라인된 호출부에서도 `new` 된다).
    // 단 생성자 · 클래스 수준(속성 초기화 · init 블록)이면 처음 선언된 생성자를 대거나(그것이 안 만들어도) 비어 있다(독립 레그 2
    // 실측) — 그때는 그 클래스를 만드는 메서드로 접는다.
    const enc = c.enclosing
    if (typeof enc.class !== 'string') return null
    if (enc.method !== null && enc.method !== '<init>') return nest(fold(enc.class, enc.method, enc.desc), cname)
    return nest(one(builders()), cname)
  }
  const type = segs.join('.')
  if (name === '<clinit>') return { type, member: '<clinit>', kind: 'static', desc }
  const own = c.methods.find((x) => x.name === name && x.desc === desc)
  if (!own) return null
  // 이 메서드가 부르는 것 가운데 `owner` 의 `to` 하나(같은 이름의 다른 클래스 메서드 — `List.size` · 기본값이 만드는 `ArrayList.<init>`
  // — 는 대상이 아니다, 독립 레그 2 실측).
  const callee = (owner, to) => {
    const rs = [...new Set(own.calls)].filter((r) => r !== self && r.startsWith(`${owner}.${to}:`))
    return rs.length === 1 ? /^([^.]+)\.([^:]+):(.*)$/.exec(rs[0]) : null
  }
  // 다리의 대상. 인라인 함수가 아닌 다리는 기본값을 다 계산한 뒤 끝에 대상을 부른다: 그 마지막 같은 이름 호출이 대상이다(기본값이 같은
  // 이름의 오버로드 · 다른 생성자를 불러도 앞에 온다 — 독립 레그 4 · 6 실측). 인라인 함수의 다리는 몸통을 품어 대상을 안 부르고 그 몸통이
  // 다른 오버로드를 부른다(레그 5 실측 — 지연 로그 `inline fun debug(t = null, msg)` 의 다리가 debug(String) 을 불러 그것을 숨겼다) —
  // 그 다리만 지역 변수표에 처음(0)부터 사는 변수(대상의 매개변수 — 슬롯 0 이 `$this` 면 받는 쪽)를 가져(실측 — 인라인이 아닌 다리도
  // 기본값 식이 인라인 함수를 쓰면 표를 갖지만 그 변수는 0 에서 시작하지 않는다: 실제 트리의 forRealm$default) 다리 서술자의 앞쪽 그만큼이
  // 대상의 서술자다. 마스크 수를 셈하지 않는다 — kotlinc 는 값 매개변수만 세어 확장 받는 쪽 · inner 의 바깥 · enum 의 이름과 순서 ·
  // Continuation 이 끼면 JVM 매개변수로 센 마스크가 틀려 엉뚱한 생성자에 접혔다(레그 6). 생성자는 인라인이 안 되므로 늘 부르는 쪽이다.
  // ⚠️ 정적 인라인 함수의 첫 매개변수 이름이 `$this`(백틱)면 받는 쪽과 못 가른다(레그 6 — 클래스 파일만으로는 같은 꼴이다).
  const target = (to) => {
    const vs = to === '<init>' ? [] : (own.lvt ?? []).filter((v) => v.start === 0).sort((a, b) => a.slot - b.slot)
    if (!vs.length) {
      const rs = own.calls.filter((r) => r !== self && r.startsWith(`${cname}.${to}:`))
      return rs.length ? /^([^.]+)\.([^:]+):(.*)$/.exec(rs[rs.length - 1]) : null
    }
    const m = /^\((.*)\)(.+)$/.exec(desc)
    const ps = m?.[1].match(/\[*(?:L[^;]+;|[BCDFIJSZ])/g) ?? []
    if (!m || vs.length > ps.length) return null
    const r = vs[0].name === '$this' ? 1 : 0
    const d = `(${ps.slice(r, vs.length).join('')})${m[2]}`
    const x = c.methods.find((y) => y.name === to && y.desc === d && Boolean(y.static) === (r === 0))
    return x ? [null, cname, to, d] : null
  }
  // 다리의 접기 — 대상이 자기에게 돌아오면(로컬 함수의 다리) 다리를 부르는 쪽으로 접는다.
  const bridge = (r) => {
    if (!r) return null
    const t = fold(r[1], r[2], r[3])
    return nest(t === KT_CYCLE ? one(callers()) : t, 'default')
  }
  // 끝이 DefaultConstructorMarker 인 생성자 — 기본 인자 생성자 · sealed 와 private 생성자의 합성 접근 생성자(그 끝 매개변수가 int 면
  // 기본 인자 생성자와 같은 꼴이다 — 레그 6 실측)는 다 마지막에 부르는 생성자의 것이다.
  if (name === '<init>') {
    if (!desc.endsWith('Lkotlin/jvm/internal/DefaultConstructorMarker;)V')) return { type, member: '<init>', kind: 'plain', desc }
    return bridge(target('<init>'))
  }
  // 람다 몸통 — `…$lambda$N…` 이거나, invokedynamic 의 구현 핸들인 private static 메서드(Java SAM 참조의 어댑터 — 로컬 함수의 참조는
  // `outer$loc$0`(독립 레그 3 실측) · 최상위 함수의 참조는 `makeOps$privTwice`(실측 — 참조된 함수 자체는 구현이 아니다))다: 그것을
  // 만드는 메서드로 접는다. private static 이 아닌 구현(그 함수 자체가 핸들인 꼴)은 접지 않는다 — 접으면 안 돈 함수가 숨는다.
  if (/\$lambda\$\d+(?:\$\d+)*$/.test(name) || (own.private && own.static && ix.made.has(self))) return nest(one(ix.made.get(self) ?? []), name)
  // suspend inline fun 의 인라인용 사본 `f$$forInline`(부르는 쪽이 없다 — 독립 레그 4 실측) — 같은 클래스 · 서술자의 f 다(없으면 접기가
  // null — FAIL).
  const fi = /^(.+)\$\$forInline$/.exec(name)
  if (fi) return nest(fold(cname, fi[1], desc), name)
  const dm = /^(.+)\$default$/.exec(name)
  // `Iface$DefaultImpls.g$default` 는 인터페이스의 같은 이름 다리를 부른다(호환 다리 — 실측) — 그 다리를 따라간다(DefaultImpls 에는
  // 같은 서술자의 정적 호환 메서드 `g(Iface, …)` 도 있다 — 그것은 대상이 아니다).
  if (dm) return bridge((cname.endsWith('$DefaultImpls') ? callee(cname.slice(0, -'$DefaultImpls'.length), name) : null) ?? target(dm[1]))
  // 컴패니언 `@JvmStatic` 의 바깥 정적 다리 — 정적 메서드가 바로 아래 중첩 클래스(`<이 클래스>$<이름>`)의 같은 이름 · 서술자
  // **인스턴스** 메서드 하나를 부르고 그것에 `@JvmStatic` 표지가 있다(함수 · `@set:JvmStatic` · `@JvmOverloads` 가 만든 오버로드 — 실측):
  // 그 멤버다(kotlin 호출은 컴패니언으로 가 다리는 안 돈다 — 따로 두면 실행된 함수가 미실행에 뜬다, 독립 레그 2 실측). 속성의 표지는
  // 게터 이름의 `<게터>$annotations` 에만 있다(실측 — `getV$annotations` · `isOn$annotations`; 게터 · 세터에는 없다): 게터 다리는 자기
  // 이름의 것을, 세터 다리 `setX` 는 그 클래스의 인스턴스 게터 `getX` · `isX` 의 것을 본다. 표지 있는 인스턴스 메서드 · 인스턴스 게터는
  // 컴패니언에만 있고(object 의 `@JvmStatic` 은 정적이다) 바로 아래 컴패니언은 이 클래스의 것이라, 이 클래스의 정적 메서드가 그것을 같은
  // 이름 · 서술자로 부르면 그 다리다(한 클래스에 같은 이름 · 서술자는 하나다). 조건마다 반례가 있다 — 받는 쪽 표지(`AuthClientTokens`
  // — 레그 3 실측) · 정적인 받는 쪽(`AuthClientNest`) · 바로 아래가 아닌 컴패니언(`AuthClientRelay`) · 인스턴스인 부르는 쪽 · 정적인 게터
  // (뒤 둘은 플래그만 바꾼 음성).
  if (own.static) {
    const to = [...new Set(own.calls)].filter((r) => r.endsWith(`.${name}:${desc}`) && r.slice(0, r.lastIndexOf('$', r.indexOf('.'))) === cname)
    if (to.length === 1) {
      const o = to[0].slice(0, to[0].indexOf('.'))
      const ms = facts[o]?.methods ?? []
      const m = ms.find((x) => x.name === name && x.desc === desc)
      const getters = /^set./.test(name) ? [`get${name.slice(3)}`, `is${name.slice(3)}`] : [name]
      const prop = (g) => ms.some((x) => x.name === g && !x.static) && ms.some((x) => x.jvmStatic && x.name === `${g}$annotations`)
      if (m && !m.static && (m.jvmStatic || getters.some(prop))) return nest(fold(o, name, desc), 'jvmstatic')
    }
  }
  const bare = name.endsWith(`$${kt.mangle}`) ? name.slice(0, -kt.mangle.length - 1) : name
  if (!bare.includes('$') && !bare.startsWith('<')) return { type, member: bare, kind: 'plain', desc }
  // 부르는 쪽으로 접는 것은 로컬 함수(private static — kotlinc 가 `<감싼 함수>$<이름>` 으로 낸다; 게터 · `@JvmName` · 값 클래스 함수
  // 안이면 접두가 JVM 이름과 다르다 — 레그 3 실측) · 합성 접근자 `access$…`(함수 참조가 거친다) · open suspend fun 의 몸통
  // `$suspendImpl` 뿐이다. 그 밖의 `$` 든 이름(모듈 이름이 틀려 접미가 안 벗겨진 public `internal` 함수 등)은 모른다 — 호출자로
  // 접으면 조용히 틀린다(자가테스트가 잡았다).
  const suspendImpl = /\$suspendImpl$/.test(name)
  if (!(own.private && own.static) && !name.startsWith('access$') && !suspendImpl) return null
  const up = one(callers())
  if (suspendImpl) return up === KT_CYCLE || !up || up.kind !== 'plain' || up.shared ? null : up
  return nest(up, name)
}
function jvmReport(l, d) {
  const path = JVM_DATA(l)
  const shown = path.replace(/\\/g, '/')
  const isObj = (x) => x !== null && typeof x === 'object' && !Array.isArray(x)
  const sha = (b) => createHash('sha1').update(b).digest('hex')
  const runRec = JVM_RUN(l)
  const noRecord = () =>
    fail(l, `no record that \`${RUN_CMD} ${l}\` wrote this data (${runRec.replace(/\\/g, '/')}) — run the suite through the script (node scripts/integration-coverage.mjs ${RUN_CMD} ${l}) so the report can tell a passing run from a failed one`)
  // 기록의 종류 — 단위 실행의 기록만 `suite: "unit"` 을 갖는다(없으면 통합이다). 다른 스위트의 기록이면 기록이 없는 것과 같다.
  const ofSuite = (r) => isObj(r) && r.run === l && (r.suite ?? 'integration') === SUITE
  if (!existsSync(path)) {
    fail(l, `no coverage data at ${shown} — run the ${SUITE} suite first (node scripts/integration-coverage.mjs ${RUN_CMD} ${l})`)
    return null
  }
  const bytes = readFileSync(path)
  const src = bytes.toString('utf8')
  if (!/^\s*<\?xml[^>]*\?>\s*<!DOCTYPE report PUBLIC "-\/\/JACOCO\/\/DTD Report 1\.1\/\/EN"/.test(src)) {
    fail(l, `${shown} is not a JaCoCo XML report (no JaCoCo report DOCTYPE) — run writes it with the JaCoCo CLI`)
    return null
  }
  const tags = xmlTags(src)
  const sessions = tags.filter((t) => !t.close && t.name === 'sessioninfo')
  if (!sessions.length) {
    fail(l, `${shown} records no session — the agent wrote no execution data`)
    return null
  }
  // 패키지 → { classes[{ name, source, methods[{ name, desc, line, missed, covered }] }], sources: 파일 이름 → Map(줄 → { mi, ci }) }
  const pkgs = new Map()
  let pkg = null
  let cls = null
  let meth = null
  let sf = null
  for (const t of tags) {
    if (t.close) {
      if (t.name === 'package') pkg = null
      else if (t.name === 'class') cls = null
      else if (t.name === 'method') meth = null
      else if (t.name === 'sourcefile') sf = null
      continue
    }
    if (t.name === 'package') {
      pkg = pkgs.get(t.attrs.name) ?? { classes: [], sources: new Map() }
      pkgs.set(t.attrs.name, pkg)
    } else if (!pkg) continue
    else if (t.name === 'class') {
      cls = { name: t.attrs.name, source: t.attrs.sourcefilename, methods: [] }
      pkg.classes.push(cls)
      if (t.empty) cls = null
    } else if (t.name === 'method' && cls) {
      // 가지 계수기는 가지가 있는 메서드에만 있다(없으면 0) — 단위 미도달 장부가 놓친 가지를 센다.
      meth = { name: t.attrs.name, desc: t.attrs.desc, line: t.attrs.line, missed: 0, covered: 0, bmissed: 0 }
      cls.methods.push(meth)
      if (t.empty) meth = null
    } else if (t.name === 'counter' && meth && t.attrs.type === 'LINE') {
      meth.missed = xmlCount(t.attrs.missed)
      meth.covered = xmlCount(t.attrs.covered)
    } else if (t.name === 'counter' && meth && t.attrs.type === 'BRANCH') {
      meth.bmissed = xmlCount(t.attrs.missed)
    } else if (t.name === 'sourcefile') {
      sf = new Map()
      pkg.sources.set(t.attrs.name, sf)
      if (t.empty) sf = null
    } else if (t.name === 'line' && sf) sf.set(t.attrs.nr, { mi: t.attrs.mi, ci: t.attrs.ci })
  }
  // 클래스 사실 — javap 의 출력을 푼다. 풀린 것이 데이터와 맞는지는 아래 대조(클래스 집합 · 메서드의 첫 줄 · 줄의 주인)가 본다.
  const javapPath = JVM_JAVAP(l)
  const javapShown = javapPath.replace(/\\/g, '/')
  let javapBytes = null
  try {
    javapBytes = readFileSync(javapPath)
  } catch {
    javapBytes = null
  }
  const facts = javapBytes && javapFacts(javapBytes.toString('utf8'))
  if (!facts || !Object.keys(facts).length) {
    fail(l, `no class facts at ${javapShown} — ${RUN_CMD} ${l} writes javap's output there (line tables · enclosing methods of nested classes)`)
    return null
  }
  // kotlin — `internal` 멤버 이름의 모듈 접미는 run 이 기록에 남긴 모듈 이름(`META-INF/<모듈>.kotlin_module`)에서 온다. 그래서
  // kotlin 은 기록이 없으면(다른 레인의 것이어도) 데이터를 못 읽는다 — 아래 기록 판정과 같은 까닭으로 여기서 멈춘다(java 는 데이터
  // 판정과 기록 판정을 함께 낸다).
  let kt = null
  if (l === 'kotlin') {
    let rec0 = null
    try {
      rec0 = JSON.parse(readFileSync(runRec, 'utf8'))
    } catch {
      rec0 = null
    }
    if (!ofSuite(rec0)) {
      noRecord()
      return null
    }
    if (typeof rec0.module !== 'string' || !/^[\w.-]+$/.test(rec0.module)) {
      fail(l, `no Kotlin module name in ${runRec.replace(/\\/g, '/')} — ${RUN_CMD} kotlin records it from build/classes/kotlin/main/META-INF/*.kotlin_module (internal members carry it as a name suffix)`)
      return null
    }
    kt = { mangle: rec0.module.replace(/[^A-Za-z0-9_]/g, '_') }
  }
  const files = []
  const never = []
  // 함수마다의 놓친 줄 · 놓친 가지 — 단위 미도달 장부(unitReport)가 쓴다(통합 리포트는 never 만 쓴다).
  const units = []
  for (const f of d.files) {
    // java 는 모듈마다 디렉터리(`<lane>/<module>/src/main/java`), kotlin 은 레인이 한 모듈이다(`kotlin/src/main/kotlin`).
    const fm = (l === 'kotlin' ? /^[^/]+\/src\/main\/kotlin\/(.+)\/([^/]+\.kt)$/ : /^[^/]+\/[^/]+\/src\/main\/java\/(.+)\/([^/]+\.java)$/).exec(f)
    if (!fm) {
      fail(l, `${f} is not under ${l === 'kotlin' ? 'kotlin/src/main/kotlin' : '<module>/src/main/java'}/<package>/ — this reader knows packaged sources only`)
      continue
    }
    const [, pk, file] = fm
    const lines = pkgs.get(pk)?.sources.get(file)
    if (!lines) {
      fail(l, `${f} is not in the coverage data — a boundary file whose classes the report never analyzed would silently leave the denominator`)
      continue
    }
    if (!existsSync(join(root, f))) {
      fail(l, `${f} is derived but missing on disk — the data cannot be checked against it`)
      continue
    }
    const nlines = readFileSync(join(root, f), 'utf8').split('\n').length
    const inPkg = (n) => n.startsWith(`${pk}/`) && !n.slice(pk.length + 1).includes('/')
    const xmlClasses = pkgs.get(pk).classes.filter((c) => c.source === file)
    const factNames = Object.keys(facts).filter((n) => inPkg(n) && facts[n].source === file)
    const xmlNames = xmlClasses.map((c) => c.name)
    const onlyXml = sortU(xmlNames.filter((n) => !factNames.includes(n)))
    const onlyFacts = sortU(factNames.filter((n) => !xmlNames.includes(n)))
    if (onlyXml.length || onlyFacts.length) {
      fail(l, `${f}: the class facts and the data name different classes (${[...onlyXml.map((n) => `data only: ${n}`), ...onlyFacts.map((n) => `facts only: ${n}`)].join(' · ')}) — ${RUN_CMD} ${l} writes both from one build`)
      continue
    }
    // `@file:JvmMultifileClass` — 파사드(메타데이터 k=4)에는 첫 줄로 매긴 전달 메서드만 있고 코드는 부분 클래스(k=5 · JVM 합성)에 있는데,
    // JaCoCo 는 합성 클래스의 메서드를 안 싣는다(실측 0.8.16 — 클래스 계수기만): 그 파일의 줄이 데이터에 없어 분모가 조용히 줄고
    // 함수마다 1 줄로 뜬다(독립 레그 7 실측). 이 리더가 셀 수 없는 꼴이다.
    const multi = kt ? factNames.filter((n) => facts[n].kmeta === 4 || facts[n].kmeta === 5) : []
    if (multi.length) {
      fail(l, `${f}: ${sortU(multi).join(' · ')} — a @file:JvmMultifileClass facade only forwards to its synthetic part class, whose methods JaCoCo does not report: the file's lines are not in the data`)
      continue
    }
    let broken = false
    // 메서드마다 — 데이터(첫 줄 · 줄 수)와 클래스 파일의 LineNumberTable 이 같은 메서드인지 대조하고 이름을 접는다.
    const parts = []
    for (const c of xmlClasses) {
      for (const x of c.methods) {
        const fx = facts[c.name].methods.find((y) => y.name === x.name && y.desc === x.desc)
        // 첫 줄 — java 는 줄표의 가장 앞 줄이다. kotlin 의 suspend 함수는 상태 기계의 분기가 선언 줄에 붙고 JaCoCo 가 그 분기를
        // 걸러, 데이터의 첫 줄이 줄표의 가장 앞 줄보다 뒤일 수 있다(실측: clientCredentialsToken 줄표 {117, 118, 119, 120} · 데이터
        // 118) — 그 메서드의 줄이기만 하면 된다.
        const firstOk = fx && (fx.lines.length ? (kt ? fx.lines.includes(Number(x.line)) : String(fx.lines[0]) === x.line) : x.line === undefined)
        if (!fx || !isCount(x.missed) || !isCount(x.covered) || !isCount(x.bmissed) || !firstOk) {
          fail(l, `${f}: ${c.name}.${x.name}${x.desc} — the data and the class facts disagree (first line ${x.line ?? 'none'} vs ${fx?.lines[0] ?? 'no method'}) — ${RUN_CMD} ${l} writes both from one build`)
          broken = true
          break
        }
        // 꼬리 호출의 닫는 줄은 재지 않는다 — kotlin 만이고, 통합 · 단위가 함께 지나는 자리다(등록부 kotlin-tail-call-return-line-flips).
        // 그 줄은 마지막 areturn 하나라 호출이 멈추지 않고 돌아온 실행에서만 돌고, JaCoCo 는 멈춤 검사만 거른다(ktTail · 실측
        // RealmsResource.update `line 37: 28`). 데이터의 그 줄이 그 명령 하나뿐이면(mi + ci = 1) 줄 데이터에서 지우고 이 메서드의 줄
        // 계수기를 하나 내린다(놓쳤으면 missed, 돌았으면 covered) — 아래의 부분 · 합계 · 몸통 · 미실행 · 장부가 그 값을 읽기 전이다. 그 밖이면
        // (명령이 더 있다 · 그 줄이 없다 · 내릴 계수기가 0 이다) 아무것도 안 바꾼다 — 실패가 아니다.
        if (kt && fx.tail !== null) {
          const v = lines.get(String(fx.tail))
          const mi = xmlCount(v?.mi)
          const ci = xmlCount(v?.ci)
          if (mi + ci === 1 && (mi === 1 ? x.missed : x.covered) > 0) {
            lines.delete(String(fx.tail))
            if (mi === 1) x.missed -= 1
            else x.covered -= 1
          }
        }
        const fo = kt ? ktFold(c.name, x.name, x.desc, facts, kt) : javaFold(c.name, x.name, x.desc, facts)
        if (!fo || fo === KT_CYCLE) {
          fail(l, `${f}: cannot name ${c.name}.${x.name}${x.desc} — ${kt ? 'the class files show no single method that creates, calls or encloses it' : 'not a generated name this reader knows'}`)
          broken = true
          break
        }
        // missed · bmissed — 이 메서드(JaCoCo 메서드 계수기)의 놓친 줄 · 놓친 가지. 접힌 함수의 수는 그 부분들의 합이다(units — 아래).
        parts.push({ ...fo, cls: c.name, name: x.name, lines: fx.lines, ends: fx.ends, covered: x.covered, missed: x.missed, bmissed: x.bmissed })
      }
      if (broken) break
    }
    if (broken) continue
    // 오버로드 — plain 서술자가 둘 이상인 멤버. 람다는 그것을 만든 오버로드에 붙인다(LineNumberTable 로 찾는다 — 아래).
    const byMember = new Map()
    for (const p of parts) {
      const k = `${p.type}.${p.member}`
      const g = byMember.get(k) ?? []
      g.push(p)
      byMember.set(k, g)
    }
    const fns = new Map()
    let amb = null
    for (const [k, g] of byMember) {
      const plains = g.filter((p) => p.kind === 'plain')
      const descs = sortU(plains.map((p) => p.desc))
      if (descs.length <= 1) {
        fns.set(k, g)
        continue
      }
      // 람다가 든 몸통 — 줄 범위로 가른다(람다 몸통의 줄은 감싼 메서드의 LineNumberTable 에 없다). 생성자의 몸통은 바이트코드의 첫 ·
      // 끝 줄(super · this 호출 · 닫는 중괄호) 사이다: javac 는 필드 초기화 · 초기화 블록을 `this(…)` 를 안 부르는 생성자마다 끼워
      // 넣어, 그 줄로 범위를 잡으면 한 생성자의 범위가 다른 생성자의 몸통까지 늘어난다 — 여럿이 함께 가졌든(독립 레그 2차 지적 —
      // 픽스처 Token(char) 의 62–72 가 Token(String) 의 몸통 65–67 을 덮었다) 하나만 가졌든(6차 지적 — `T(String) { this(1); … }` 위의
      // 필드 줄이 `T(int)` 의 범위를 그 몸통까지 늘렸다). 메서드는 함께 가진 줄(한 줄에 선언된 오버로드)을 뺀 줄의 범위다.
      const seen = new Map()
      for (const q of plains) for (const n of q.lines) seen.set(n, (seen.get(n) ?? 0) + 1)
      const span = (ls) => (ls.length ? [ls[0], ls[ls.length - 1]] : null)
      const within = (s, n) => s !== null && n >= s[0] && n <= s[1]
      const ctor = g[0].member === '<init>'
      const body = new Map(plains.map((q) => [q, ctor && q.ends ? [Math.min(...q.ends), Math.max(...q.ends)] : span(q.lines.filter((n) => seen.get(n) === 1))]))
      // 매개변수는 짧은 이름으로 쓴다 — 두 오버로드가 짧은 이름으로 겹치면(`foo(a.T)` · `foo(b.T)` — 독립 레그 1차 지적) 그 멤버는
      // 서술자 전체로 쓴다(겹친 키는 한 함수로 합쳐져 안 돈 쪽이 목록에서 사라진다).
      const label = new Map(descs.map((x) => [x, javaParams(x) ?? x]))
      const clash = new Set(label.values()).size !== label.size
      const keyOf = (x) => (clash ? `${k}${x}` : `${k}(${label.get(x)})`)
      const put = (key, p) => fns.set(key, [...(fns.get(key) ?? []), p])
      for (const p of g) {
        let dsc = p.desc
        // kotlin — 생성자 여럿이 함께 만든 부분(ktFold 의 shared 목록): 그 생성자마다 싣되 실행 근거로 안 센다(java 의 (가) 와 같다).
        if (Array.isArray(p.shared)) {
          if (p.shared.every((x) => label.has(x))) for (const x of p.shared) put(keyOf(x), { ...p, shared: true })
          else amb ??= { k, by: 'desc' }
          continue
        }
        if (p.kind !== 'plain' && !p.via) {
          // 람다를 만든 오버로드 — 람다 몸통은 그것을 만든 줄 뒤에 온다. (가) 함께 가진 줄에만 있는 람다: 생성자면 필드 초기화 ·
          // 초기화 블록의 것이라 그 줄을 다 가진 생성자들(둘 이상)이 함께 가진다(한 생성자의 범위가 그 줄을 덮어도 몸통이 아니다 —
          // 독립 레그 3차 지적). 메서드면 한 줄에 선언된 오버로드라 못 가른다. (나) 한 몸통 범위에 다 드는 람다: 그 오버로드의 것.
          // (다) 어느 몸통 범위에도 다 안 드는 람다: 람다의 첫 줄에서 가장 가까운 앞의 줄을 가진 오버로드가 만들었다 — 그 줄에서 람다의
          // 끝 줄까지 어느 몸통 범위도 걸치지 않아야 한다(걸치면 못 가른다 — FAIL). 값을 돌려주는 메서드는 마지막 문장의 여러 줄 람다가
          // 그 메서드의 LineNumberTable 범위 밖에 놓인다(실측 javac 21: `token(String, int)` {7} · 그 람다 {8, 9} — 범위만 보면 FAIL
          // 했다). 생성자의 필드 람다는 그 줄이 필드 줄이고 — 두 생성자 사이의 필드도(독립 레그 5차 지적) · `this(…)` 를 안 부르는
          // 생성자가 하나뿐인 필드도 — 그 줄을 가진 생성자들의 것이다(둘 이상이면 함께 가진다). 그 밖은 FAIL(독립 레그 1 · 3 · 4차 지적).
          const onShared = p.lines.length > 0 && p.lines.every((n) => seen.get(n) > 1)
          if (onShared) {
            const runs = plains.filter((q) => p.lines.every((n) => q.lines.includes(n)))
            if (p.member !== '<init>' || runs.length < 2) {
              amb ??= { k, by: 'lines' }
              continue
            }
            // 함께 가진 람다가 돌았다는 것은 **어느** 생성자가 돌았다는 뜻일 뿐이다 — 미실행 판정의 근거로 쓰지 않는다(아래 `shared`).
            for (const h of runs) put(keyOf(h.desc), { ...p, shared: true })
            continue
          }
          const hits = p.lines.length ? plains.filter((q) => p.lines.every((n) => within(body.get(q), n))) : []
          if (hits.length === 1) dsc = hits[0].desc
          else {
            let runs = []
            if (!hits.length && p.lines.length) {
              const lo = Math.min(...p.lines)
              const hi = Math.max(...p.lines)
              const f = Math.max(0, ...plains.flatMap((q) => q.lines).filter((n) => n <= lo))
              if (f > 0 && plains.every((q) => body.get(q) === null || body.get(q)[1] <= f || body.get(q)[0] > hi)) runs = plains.filter((q) => q.lines.includes(f))
            }
            if (runs.length === 1) dsc = runs[0].desc
            else if (runs.length > 1 && p.member === '<init>') {
              for (const h of runs) put(keyOf(h.desc), { ...p, shared: true })
              continue
            } else {
              amb ??= { k, by: 'lines' }
              continue
            }
          }
        }
        // 서술자로 붙는 것(익명 클래스의 감싼 메서드 · kotlin 의 접힌 부분 전부)은 그 서술자가 오버로드 하나여야 한다 — java 의 람다
        // 안 익명 클래스(감싼 것이 람다라 서술자가 없다) · kotlin 에서 접힌 곳이 데이터에 없는 메서드(JaCoCo 가 거른 것)면 못 가른다
        // (FAIL — 없는 키에 조용히 붙지 않는다).
        if (!label.has(dsc)) {
          amb ??= { k, by: 'desc' }
          continue
        }
        put(keyOf(dsc), p)
      }
    }
    if (amb) {
      const what = amb.by === 'lines' ? 'a lambda whose lines fall in none or several of them' : 'a part attached by a descriptor (enclosing, creating or called method) that is none of theirs'
      fail(l, `${f}: ${amb.k} has overloads and ${what} — this reader cannot tell which`)
      continue
    }
    // 줄 — 소스 파일 단위. 데이터의 줄은 1..파일 길이 · 어느 메서드의 LineNumberTable 에 든다(아니면 데이터가 다른 빌드의 것이다).
    // 줄의 주인은 데이터에 실린 메서드만이다 — JaCoCo 가 거른 메서드(enum 의 values() · valueOf() · 합성 $values() · 브리지)는 javap
    // 사실에는 있어도 그 명령이 줄 수에 안 든다(실측: 픽스처 Mode 의 선언 줄을 정적 초기화와 values() · valueOf() 가 함께 가졌다 —
    // 사실 전체로 세면 그 줄이 몸통이 됐다).
    const owned = new Map()
    for (const p of parts) for (const n of p.lines) owned.set(n, (owned.get(n) ?? 0) | (p.name === '<clinit>' ? 1 : 2))
    // 몸통 줄이 덮였는가는 줄의 횟수만으로 못 가른다 — 정적 람다(`F = s -> …`)의 줄은 정적 초기화와 람다가 함께 갖는다: 실릴 때
    // 정적 초기화가 그 줄을 돌면 람다가 한 번도 안 불려도 그 줄이 덮인다(실측: 픽스처 0 실행의 UPPER 줄). 그래서 그 줄을 가진
    // 정적 초기화 밖의 메서드 가운데 JaCoCo 가 돈 것으로 센 것(메서드의 LINE covered > 0)이 있어야 몸통으로 덮인 것이다.
    const ran = new Set(parts.filter((p) => p.name !== '<clinit>' && p.covered > 0).flatMap((p) => p.lines))
    let stmts = 0
    let covered = 0
    const bodies = { stmts: 0, covered: 0 }
    for (const [nr, v] of lines) {
      const n = Number(nr)
      const mi = xmlCount(v.mi)
      const ci = xmlCount(v.ci)
      if (!/^[1-9]\d*$/.test(nr ?? '') || !isCount(mi) || !isCount(ci)) {
        fail(l, `${f}: cannot read line ${nr ?? '?'} of ${file} in ${shown}`)
        broken = true
        break
      }
      if (n > nlines) {
        fail(l, `${f}: the data counts line ${n}, past the ${nlines} lines of the file — the data contradicts the tree`)
        broken = true
        break
      }
      if (!owned.has(n)) {
        fail(l, `${f}: the data counts line ${n}, which no method of the class facts owns — the data and the class files come from different builds`)
        broken = true
        break
      }
      stmts++
      if (ci > 0) covered++
      if (owned.get(n) & 2) {
        bodies.stmts++
        if (ci > 0 && ran.has(n)) bodies.covered++
      }
    }
    if (broken) continue
    for (const [key, ps] of fns) {
      if (ps.every((p) => p.kind === 'static')) continue
      const inData = (qs) => new Set(qs.flatMap((p) => p.lines).filter((n) => lines.has(String(n))))
      const ls = inData(ps)
      const own = ps.filter((p) => !p.shared)
      // kotlin 의 기본 인자 다리와 다리가 만든 것(ktFold 의 dflt)은 그 함수가 돌았다는 근거가 아니다 — 다리는 기본값을 계산하고 가상
      // 호출로 넘긴다: 재정의된 open fun · 인터페이스 기본 메서드의 다리는 재정의를 불러 그 몸통은 안 돈다(독립 레그 6 실측 — 다리의
      // 줄이 몸통의 실행으로 셈해져 안 돈 몸통이 숨었다). 몸통 부분이 데이터에 있으면 그것만 본다 — 없으면(추상 멤버 — 다리와 기본값의
      // 람다뿐이다, 레그 7) 다리가 돈 것이 그 함수가 불린 근거다.
      const body = own.filter((p) => !p.dflt)
      const ev = body.length ? body : own
      if (!ls.size || !ev.length || !ev.every((p) => p.covered === 0)) continue
      // 목록의 줄 — 그 함수의 안 돈 줄이다. 그 함수의 근거가 아닌 부분 — 다리 쪽(dflt) · 다른 생성자와 함께 가진 것(shared) — 의 줄은
      // 줄 단위로 가른다: 그 줄의 명령이 하나도 안 돌았을 때만 센다. 재정의된 함수의 다리 · 다른 생성자가 만든 초기화 람다는 돌았다 —
      // 그 줄을 세면 「none of its lines ran」 이 거짓이 된다(독립 레그 7 · 9; 안 돈 DefaultImpls 다리가 같은 선언 줄을 가져도 그 줄은
      // 돌았다). 돈 다리 안에서도 명령이 하나도 안 돈 기본값 분기의 줄은 센다 — 부분 단위로 빼면 그 줄이 사라졌다(레그 8). 마지막 분기의
      // 줄은 kotlinc 가 when · if 의 값을 담는 명령을 매겨 다른 분기가 지나가므로 그 분기가 안 돌았어도 일부 돈 줄이다(레그 9 실측 — JaCoCo
      // 의 줄 계수와 같은 정의다). 제 부분의 줄은 그대로다(메서드 단위의 판정 — 한 줄짜리 함수의 그 줄이 돈 다리와 같은 줄이어도 몸통의
      // 그 줄 명령은 안 돌았다).
      const idle = (n) => xmlCount(lines.get(String(n)).ci) === 0
      const mine = (p) => !p.dflt && !p.shared
      const sh = new Set([...inData(ps.filter(mine)), ...[...inData(ps.filter((p) => !mine(p)))].filter(idle)])
      const at = sh.size ? sh : ls
      never.push({ file: f, line: Math.min(...at), name: key, stmts: at.size })
    }
    // 단위 미도달 장부 — 함수마다 그 부분들의 놓친 줄 · 놓친 가지(JaCoCo 메서드 계수기)의 합이다. 람다 · 로컬 함수 · 기본 인자 다리 ·
    // 익명 객체 · 접근자는 ktFold 가 그 소스 함수의 부분으로 접었다 — 그 안의 놓친 가지가 합성 이름으로 새지 않는다. 여러 생성자가
    // 함께 가진 부분(shared)은 그 생성자마다 센다. 정적 초기화는 `<타입>.<clinit>` 이다. 한 줄에 람다와 그것을 만든 호출이 있으면 그 줄은
    // 부분마다 따로 센다(메서드 계수기 — 호출이 돌아도 람다가 안 돌았으면 람다의 줄은 놓쳤다).
    for (const [key, ps] of fns) {
      const ls = ps.flatMap((p) => p.lines)
      units.push({ file: f, name: key, line: ls.length ? Math.min(...ls) : 0, lines: ps.reduce((a, p) => a + p.missed, 0), branches: ps.reduce((a, p) => a + p.bmissed, 0) })
    }
    files.push({ file: f, stmts, covered, bodies, outside: { stmts: 0, covered: 0 } })
  }
  // run 기록 — dotnet 과 같은 이유. 다른 판정 뒤에 두되 앞의 실패가 있어도 낸다(두 까닭이 한 번에 보인다).
  let rec = null
  try {
    rec = JSON.parse(readFileSync(runRec, 'utf8'))
  } catch {
    rec = null
  }
  if (!ofSuite(rec)) {
    noRecord()
    return null
  }
  if (rec.exit !== 0) {
    fail(l, `the run that wrote this data exited ${rec.exit} — the data of a failed run is partial`)
    return null
  }
  if (rec.data_sha1 !== sha(bytes)) {
    fail(l, `${shown} is not the data \`${RUN_CMD} ${l}\` recorded (sha1 ${String(rec.data_sha1).slice(0, 12)}… recorded, ${sha(bytes).slice(0, 12)}… now) — another run wrote over it`)
    return null
  }
  if (rec.javap_sha1 !== sha(javapBytes)) {
    fail(l, `${javapShown} is not the javap output \`${RUN_CMD} ${l}\` recorded — another run wrote over it`)
    return null
  }
  // 시험 수 — 그 스위트의 것(tests)과 다른 스위트의 보고 수(통합 기록은 `unit` · 단위 기록은 `integration`). 다른 스위트가 섞이면 그
  // 데이터는 이 스위트만의 것이 아니다.
  const t = rec.tests
  const other = SUITE === 'unit' ? rec.integration : rec.unit
  if (!isObj(t) || !isCount(t.completed) || !isCount(t.failures) || !isCount(t.errors) || !isCount(other)) {
    const unitFrom = l === 'kotlin' ? 'the JUnit XML of test and integrationTest' : 'the surefire and failsafe reports (TEST-*.xml)'
    const from = SUITE === 'unit' ? unitFrom : l === 'kotlin' ? 'the JUnit XML of integrationTest and test' : 'failsafe-summary.xml and the surefire reports'
    fail(l, `the record has no test counts — ${RUN_CMD} ${l} reads them from ${from}`)
    return null
  }
  if (t.completed === 0) fail(l, `the run recorded no ${SUITE} tests — a report over no tests is vacuous`)
  if (t.failures + t.errors) fail(l, `${t.failures + t.errors} of ${t.completed} ${SUITE} tests failed — the data of a failed run is partial`)
  // 단위 실행에 통합 시험의 보고가 있다 — kotlin 은 integrationTest 의 결과, java 는 failsafe 의 보고다(단위 골 `test` 는 failsafe 앞에서 멈춘다).
  const unitOnly = l === 'kotlin' ? 'unit kotlin runs test only' : 'unit java runs the test phase only — failsafe binds after it'
  if (other && SUITE === 'unit') fail(l, `the run included ${other} integration test report${other > 1 ? 's' : ''} — the data would not be unit-only (${unitOnly})`)
  else if (other) fail(l, `the run included ${rec.unit} unit test report${rec.unit > 1 ? 's' : ''} — the report would not be integration-only (${l === 'kotlin' ? 'run runs integrationTest only' : 'run skips surefire: -Dtest=NONE'})`)
  if (!isObj(rec.files)) {
    fail(l, 'the record has no boundary hashes — the boundary files changed while the suite ran, so the data may come from other bytes')
    return null
  }
  for (const f of d.files) {
    const now = existsSync(join(root, f)) ? sha(readFileSync(join(root, f))) : null
    if (rec.files[f] !== now) fail(l, `${f}: the data was taken from other bytes (sha1 ${String(rec.files[f]).slice(0, 12)}… recorded, ${String(now).slice(0, 12)}… in the tree) — rerun the suite on this tree`)
  }
  const note = `JaCoCo ${typeof rec.jacoco === 'string' ? rec.jacoco : '?'} · ${sessions.length} session${sessions.length === 1 ? '' : 's'} · ${t.completed} ${SUITE} test${t.completed === 1 ? '' : 's'}`
  return { path, note, files, never, units }
}

// ── report ───────────────────────────────────────────────────────────────────────────────
function emitFindings(l) {
  for (const f of findings) if (f.lang === l || f.lang === null) console.log(`${f.kind} [${f.lang ?? '-'}] ${f.msg}`)
}
// 아무 경계 문장도 안 돈 실행은 「낮은 수치」가 아니라 측정 실패다(테스트가 경계를 한 줄도 안 지나고 통과할 수 없다) — FAIL 을 남기고
// true. 통합 리포트와 단위 미도달 장부가 함께 쓴다(그 스위트의 이름으로 묻는다).
// ⚠️ python 은 **함수 몸통**으로 판정한다 — import 만으로 모듈·클래스 수준 줄이 덮인다. conftest 가 패키지를 import
// 하므로 통합 테스트가 전부 skip 돼 pytest 가 exit 0 으로 끝나도 lines 는 0 이 아니다(실측: 실제 트리 import 만으로
// 160/395 = 40.5% · 몸통 0/235). lines 로 판정하면 그 실행이 「40.5%」로 보고된다. ruby 도 같다(require 가 클래스 · def 줄을 돈다).
function ranNothing(l, data, tot) {
  const ran = BODY_LANGS.has(l)
    ? data.files.reduce((a, f) => ({ stmts: a.stmts + f.bodies.stmts, covered: a.covered + f.bodies.covered }), { stmts: 0, covered: 0 })
    : tot
  if (ran.covered !== 0) return false
  const scope =
    l === 'python'
      ? 'boundary statements inside functions'
      : l === 'ruby'
        ? 'boundary lines inside methods'
        : JVM_LANGS.has(l)
          ? 'boundary lines outside static initializers'
          : LINE_LANGS.has(l)
            ? 'boundary lines'
            : 'boundary statements'
  const load = l === 'ruby' ? 'require' : JVM_LANGS.has(l) ? 'class loading' : 'import'
  const level = JVM_LANGS.has(l) ? 'static-initializer' : 'module-level'
  const why = BODY_LANGS.has(l) && tot.covered ? `${load} alone credits ${tot.covered} ${level} lines` : `did the ${SUITE} tests run against this tree?`
  fail(l, `the run executed 0 of ${ran.stmts} ${scope} — a measurement failure, not a low number (${why})`)
  return true
}
function report(l) {
  const d = derivedFor(l)
  const pin = pinFor(l)
  const reg = loadRegistry()
  if (d && pin) matchesPin(l, d, pin)
  const reader = { go: goReport, python: pyReport, node: nodeReport, rust: rustReport, php: phpReport, ruby: rubyReport, dotnet: dotnetReport, java: (x) => jvmReport('java', x), kotlin: (x) => jvmReport('kotlin', x) }[l]
  const data = fails(l) ? null : reader(d)
  if (data && !fails(l)) {
    const tot = data.files.reduce((a, f) => ({ stmts: a.stmts + f.stmts, covered: a.covered + f.covered }), { stmts: 0, covered: 0 })
    if (!ranNothing(l, data, tot)) {
      const neverKeys = new Set()
      for (const x of data.never) {
        const key = `${x.file}:${x.name}`
        neverKeys.add(key)
        x.owner = pin.owners[key] ?? 'NONE'
        const why = pin.owners[key] ? ownerProblem(l, pin, reg, key, x.owner) : `unowned never-executed function ${key} — name an open item of ${REGISTRY} for it in ${PINS}`
        if (why) drift(l, why)
      }
      // admin 표면 — 핀 밖 파일은 같은 실행의 데이터를 그 파일들로 한 번 더 읽는다(미실행 함수만 쓴다 — 수치 · 하한에 섞지
      // 않는다). 그 파일이 데이터에 없거나 다른 바이트의 것이면 리더가 FAIL 을 낸다(재지 않은 표면은 초록이 아니다).
      const S = new Set(pin.surface)
      const P = new Set(d.files)
      const extra = pin.surface.filter((f) => !P.has(f))
      const extraNever = extra.length ? (reader({ ...d, files: extra })?.never ?? []) : []
      for (const x of extraNever) {
        const key = `${x.file}:${x.name}`
        neverKeys.add(key)
        x.owner = pin.owners[key] ?? 'NONE'
        const why = pin.owners[key] ? ownerProblem(l, pin, reg, key, x.owner) : null
        if (why) drift(l, why)
      }
      for (const x of [...data.never, ...extraNever]) {
        if (S.has(x.file) && x.owner === 'NONE') {
          unexercised(l, `admin surface function ${x.file}:${x.name} never ran in the integration run — exercise it in the suite, or name an open item of ${REGISTRY} for it in ${PINS}`)
        }
      }
      for (const key of Object.keys(pin.owners)) if (!neverKeys.has(key)) drift(l, `stale owner ${key} — the integration run executes it now (or it no longer exists); drop the entry`)
      printReport(l, d, data, tot, pin, extraNever)
    }
  }
  emitFindings(l)
  const nf = findings.filter((f) => f.kind === 'FAIL' && (f.lang === l || f.lang === null)).length
  const nd = findings.filter((f) => f.kind === 'DRIFT' && f.lang === l).length
  const nu = findings.filter((f) => f.kind === 'UNEXERCISED' && f.lang === l).length
  if (nf) {
    console.log(`integration-coverage [${l}]: FAIL — ${nf} integrity failure${nf > 1 ? 's' : ''}; no numbers are reported from a run that failed one`)
    return 2
  }
  const t = data.files.reduce((a, f) => ({ stmts: a.stmts + f.stmts, covered: a.covered + f.covered }), { stmts: 0, covered: 0 })
  const b = data.files.reduce((a, f) => ({ stmts: a.stmts + (f.bodies?.stmts ?? 0), covered: a.covered + (f.bodies?.covered ?? 0) }), { stmts: 0, covered: 0 })
  let head = `${t.covered}/${t.stmts} ${LINE_LANGS.has(l) ? 'lines' : 'statements'} (${pct(t.covered, t.stmts)})`
  if (BODY_LANGS.has(l)) head = `lines ${t.covered}/${t.stmts} (${pct(t.covered, t.stmts)}) · bodies ${b.covered}/${b.stmts} (${pct(b.covered, b.stmts)})`
  const n = data.never.length
  const fns = n ? `${n} never-executed function${n > 1 ? 's' : ''}` : 'no never-executed functions'
  // 열린 항목 밖의 소유가 있으면 그것도 댄다(check 의 요약과 같은 갈래 — 셋이면 「a, b or c」).
  const by = ['open registry items', ...[[HARNESS_OWNER, 'the install harness'], [UNIT_OWNER, 'the unit ledger']].filter(([o]) => data.never.some((x) => x.owner === o)).map(([, w]) => w)]
  const owned = n && !nd ? `, all owned by ${by.slice(0, -1).join(', ')}${by.length > 1 ? ' or ' : ''}${by[by.length - 1]}` : ''
  const problems = nd ? ` · ${nd} ownership problem${nd > 1 ? 's' : ''}` : ''
  const fl = floorText(pin) ? ` · ${floorText(pin)}` : ''
  // 하한 — 분모가 0 이면 위 「아무것도 안 돈 실행」이 이미 FAIL 이다. 정수식으로 비교한다(같으면 통과).
  const m = pin.floor && { statements: t, lines: t, bodies: b }[pin.floor.metric]
  const below = m && m.covered * 100 < pin.floor.percent * m.stmts
  // 표면 미실행이 하한보다 먼저다 — 둘 다면 둘 다 말하고 4 를 낸다(무엇을 고칠지가 더 구체적인 쪽).
  if (nu) {
    console.log(`integration-coverage [${l}]: UNEXERCISED — ${head}${fl}${below ? ' (also below the floor)' : ''} · ${nu} admin surface function${nu > 1 ? 's' : ''} never ran${problems}`)
    return 4
  }
  if (below) {
    console.log(`integration-coverage [${l}]: BELOW — ${head}${fl} · ${fns}${owned}${problems}`)
    return 3
  }
  if (nd) {
    console.log(`integration-coverage [${l}]: DRIFT — ${head}${fl} · ${fns}${problems} (the lane fails on it — each DRIFT line says what to change in ${PINS})`)
    return 1
  }
  console.log(`integration-coverage [${l}]: OK — ${head}${fl} · ${fns}${owned}`)
  return 0
}
function printReport(l, d, data, tot, pin, extraNever = []) {
  const unit = LINE_LANGS.has(l) ? 'line' : 'stmt'
  const stmt = (k) => `${k} ${unit}${k > 1 ? 's' : ''}`
  console.log(`[${l}] integration-only coverage — ${floorText(pin) ?? 'report mode, no floor'}`)
  console.log(`  boundary: ${d.files.length} files derived from ${d.site} (${d.label}) — equal to the pin in ${PINS}`)
  console.log(`  data: ${data.path.replace(/\\/g, '/')}${data.note ? ` (${data.note})` : ''}`)
  if (!BODY_LANGS.has(l)) {
    // 어느 이름 범위에도 속하지 않는 문장 — go 의 패키지 수준 함수 리터럴, node 의 모듈·클래스 수준 문장, rust 의 항목 밖 줄
    // (매크로가 펼친 코드가 항목 밖 자리를 가리킬 때 — 함수 레코드가 범위 밖이면 그 전에 FAIL 이다).
    const level = l === 'go' ? 'package-level' : 'module-level'
    for (const f of data.files) {
      const pkg = f.outside.stmts ? ` (${level} ${f.outside.covered}/${f.outside.stmts})` : ''
      console.log(`  ${f.file} ${f.covered}/${f.stmts} ${pct(f.covered, f.stmts)}${pkg}`)
    }
    console.log(`  total ${tot.covered}/${tot.stmts} ${pct(tot.covered, tot.stmts)}`)
  } else {
    const b = { stmts: 0, covered: 0 }
    for (const f of data.files) {
      b.stmts += f.bodies.stmts
      b.covered += f.bodies.covered
      console.log(`  ${f.file} lines ${f.covered}/${f.stmts} ${pct(f.covered, f.stmts)} · bodies ${f.bodies.covered}/${f.bodies.stmts} ${pct(f.bodies.covered, f.bodies.stmts)}`)
    }
    console.log(`  total lines ${tot.covered}/${tot.stmts} ${pct(tot.covered, tot.stmts)} · bodies ${b.covered}/${b.stmts} ${pct(b.covered, b.stmts)}`)
    console.log(
      l === 'ruby'
        ? '  (bodies = lines inside methods; class-level and def lines run at require, so "lines" also credits what the run merely loaded)'
        : JVM_LANGS.has(l)
          ? '  (bodies = lines outside static initializers; a class runs its static initializer when it loads, so "lines" also credits what the run merely loaded)'
          : '  (bodies = statements inside functions; module- and class-level lines run at import, so "lines" also credits what the run merely imported)',
    )
  }
  // 표와 같은 순서(코드 단위) — localeCompare 는 `admin_users.go` 를 `admin.go` 앞에 둔다.
  const never = [...data.never].sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line))
  const what =
    l === 'rust'
      ? 'none of its lines ran, its async body never ran, or the data has no record of it'
      : l === 'php' || l === 'dotnet' || JVM_LANGS.has(l)
        ? 'none of its lines ran'
        : l === 'ruby'
          ? 'Ruby counted no call to it'
          : 'none of its statements ran'
  console.log(`  never executed by the integration run — ${never.length} function${never.length === 1 ? '' : 's'} (${what}):`)
  for (const x of never) console.log(`  NEVER ${x.file}:${x.line} ${x.name} · ${x.label ?? stmt(x.stmts)} · owner ${x.owner}`)
  if (pin.surface.length) {
    const P = new Set(d.files)
    const outsideN = pin.surface.filter((f) => !P.has(f)).length
    const S = new Set(pin.surface)
    const surfNever = [...data.never.filter((x) => S.has(x.file)), ...extraNever]
    console.log(`  admin surface: ${pin.surface.length} files (${outsideN} outside the boundary — read from the same run, not counted above) · ${surfNever.length} never-executed function${surfNever.length === 1 ? '' : 's'}`)
    for (const x of extraNever) console.log(`  NEVER ${x.file}:${x.line} ${x.name} · ${x.label ?? stmt(x.stmts)} · owner ${x.owner} (surface, outside the boundary)`)
  }
}

// ── 단위 미도달 장부(머리 주석) — 장부 · why · 대조 ─────────────────────────────────────────────
// 장부의 꼴 — 틀리면 무결성 실패다(무시하면 장부가 꺼진 줄 모른다). 항목의 키는 통합 소유자와 같은 `"<파일>:<함수>"` 다.
let unitLedger
function loadUnitLedger() {
  if (unitLedger !== undefined) return unitLedger
  unitLedger = null
  let j
  try {
    j = JSON.parse(readFileSync(join(root, UNIT), 'utf8'))
  } catch {
    fail(null, `${UNIT} is missing or not JSON`)
    return null
  }
  if (!j || typeof j !== 'object' || Array.isArray(j)) {
    fail(null, `${UNIT} must be an object keyed by language`)
    return null
  }
  for (const k of Object.keys(j)) if (!UNIT_LANGS.includes(k)) fail(null, `${UNIT} names ${k}, which the unit-unreached ledger does not measure (${UNIT_LANGS.join(' · ')})`)
  unitLedger = j
  return j
}
// 언어마다 한 번 잰다 — 소유자 판정(`unit:ledger`)이 항목마다 묻는다. 안 그러면 없거나 꼴이 틀린 장부의 FAIL 이 그 수만큼 찍힌다.
const unitLedgers = new Map()
function unitLedgerFor(l) {
  if (!unitLedgers.has(l)) unitLedgers.set(l, unitLedgerRead(l))
  return unitLedgers.get(l)
}
function unitLedgerRead(l) {
  const j = loadUnitLedger()
  if (!j) return null
  const e = j[l]
  if (!e || typeof e !== 'object' || Array.isArray(e)) {
    fail(l, `${UNIT} has no ${l} object — an empty ledger is {}, not a missing one`)
    return null
  }
  // kotlin · dotnet · java · ruby · python 은 놓친 줄 · 놓친 가지, node 는 놓친 문장 · 놓친 가지, php 는 놓친 줄만, go 는 놓친 문장만 센다(머리
  // 주석 — php 의 XML · go 의 커버 프로필에는 가지가 없다).
  const want = UNIT_BRANCHES.has(l) ? ['branches', unitKey(l), 'why'] : [unitKey(l), 'why']
  for (const [k, v] of Object.entries(e)) {
    const ok = v !== null && typeof v === 'object' && !Array.isArray(v) && sortU(Object.keys(v)).join() === want.join() && want.every((x) => (x === 'why' ? typeof v.why === 'string' && v.why !== '' : isCount(v[x])))
    if (!ok) {
      fail(l, `${UNIT}: ${l}["${k}"] must be { ${want.join(', ')} } — whole-number counts and a non-empty why`)
      return null
    }
  }
  return e
}
// why 의 판정 — 까닭 머리(`unreachable:` · `defensive:` · `integration:`)와 그 뒤의 말, 아니면 열린 등록부 항목의 id. 문제가 없으면 null.
// 등록부를 못 읽었으면(그것은 이미 FAIL 이다) id 를 판정하지 않는다 — ownerProblem 과 같다.
function whyProblem(reg, key, why) {
  const head = UNIT_WHY.find((p) => why.startsWith(p))
  if (head) return why.slice(head.length).trim() ? null : `${key}: why "${why}" names a kind but not the reason — say why after "${head}"`
  return reg && !reg.open.has(why) ? `${key}: why "${why}" is neither ${UNIT_WHY.join(' · ')} with a reason nor an open item of ${REGISTRY}` : null
}
const unitCounts = (l, x) => {
  const k = unitKey(l)
  const head = `${x[k]} ${k === 'statements' ? 'statement' : 'line'}${x[k] === 1 ? '' : 's'}`
  return UNIT_BRANCHES.has(l) ? `${head} · ${x.branches} branch${x.branches === 1 ? '' : 'es'}` : head
}
const unitMissed = (u) => (u.lines ?? 0) > 0 || (u.statements ?? 0) > 0 || (u.branches ?? 0) > 0
// 출하 소스의 커버리지 제외 표지(머리 주석) — 표지마다 FAIL 이다(리더를 부르지 않는다). 읽은 추적 파일 수를 한 줄로 찍는다 — roots 의 추적된
// 파일이 0 이면(자리가 낡았다 · git 이 못 낸다) 「표지 0」이 아니라 공허라 FAIL 이다. 추적됐는데 못 읽는 것(하위 모듈 · 디렉터리 · 권한)도 FAIL 이다
// — 그 자리의 표지를 볼 수 없다. 파일마다의 표지는 markHits 가 낸다(스캔이 던지면 그 파일도 FAIL 이다).
function unitMarks(l) {
  const m = UNIT_MARKS[l]
  if (!m.roots) {
    console.log(`[${l}] coverage-exclusion markers: not scanned — ${m.why}`)
    return
  }
  const also = new Set(m.also ?? [])
  const r = spawnSync('git', ['ls-files', '-z', '--', ...m.roots, ...also], { cwd: root, encoding: 'utf8', maxBuffer: 64 << 20 })
  // 지운(아직 안 올린) 추적 파일은 도구도 못 읽는다.
  const files = r.status === 0 ? r.stdout.split('\0').filter((f) => f && existsSync(join(root, f))) : []
  const rootsShown = m.shown ?? m.roots.join(' · ')
  if (!files.some((f) => !also.has(f))) {
    // 신호로 죽은 git 은 stderr 가 비어 있다 — 까닭이 빈 칸이 되지 않게 신호나 종료코드를 댄다.
    const why = r.status === 0 ? '' : ` (git ls-files: ${r.error?.message ?? (`${r.stderr ?? ''}`.trim().split('\n')[0] || (r.signal ? `killed by ${r.signal}` : `exit ${r.status}`))})`
    fail(l, `no tracked files under ${rootsShown} in ${rootPosix}${why} — the coverage-exclusion marker scan would read nothing`)
    return
  }
  const shown = [rootsShown, ...files.filter((f) => also.has(f))].join(' · ')
  const hits = []
  let read = 0
  for (const f of files) {
    const p = join(root, f)
    let text
    try {
      if (!statSync(p).isFile()) {
        fail(l, `${f}: tracked but not a regular file (a submodule or a directory?) — the coverage-exclusion marker scan cannot read it`)
        continue
      }
      text = readFileSync(p, 'utf8')
    } catch (e) {
      fail(l, `${f}: the coverage-exclusion marker scan cannot read it (${e.code ?? e.message})`)
      continue
    }
    // 스캔이 던지면(K_DEEP 을 넘게 겹친 템플릿 따위) 그 파일의 표지를 배제할 수 없다 — 건너뛰지 않고 FAIL 이다(읽은 수에 넣지 않는다).
    let found
    try {
      found = markHits(m, text)
    } catch (e) {
      fail(l, `${f}: the coverage-exclusion marker scan failed on it (${e.message}) — its markers cannot be ruled out`)
      continue
    }
    read++
    // 줄은 자리 순으로 한 번만 센다(표지마다 파일 머리부터 다시 세면 표지 수 × 파일 크기다).
    found.sort((a, b) => a.at - b.at)
    let line = 1
    let pos = 0
    for (const h of found) {
      for (; pos < h.at; pos++) if (text[pos] === '\n') line++
      hits.push({ f, at: h.at, line, tok: h.tok })
    }
  }
  hits.sort((a, b) => (a.f < b.f ? -1 : a.f > b.f ? 1 : a.at - b.at))
  const n = `${read} tracked file${read === 1 ? '' : 's'} under ${shown}`
  console.log(`[${l}] coverage-exclusion markers: ${hits.length ? `${hits.length} in ${n} — each is a FAIL below` : `none in ${n}`}`)
  for (const h of hits)
    fail(l, `${h.f}:${h.line}: coverage-exclusion marker \`${h.tok}\` in shipped source — the ledger cannot be trusted while one is there: remove it, then test that code or record why in ${UNIT}`)
}
// `unit` · `unit-report` — 측정(단위 실행의 데이터)과 장부를 함수마다 대조한다. 종료코드는 머리 주석의 단위 표다.
function unitReport(l) {
  const d = derivedFor(l)
  const pin = pinFor(l)
  const reg = loadRegistry()
  const led = unitLedgerFor(l)
  // 놓친 줄(go 는 문장)의 키 — 장부 항목과 측정이 같은 이름을 쓴다.
  const k = unitKey(l)
  // 경계 파생은 통합 장부의 핀과 같아야 한다 — 파생이 조용히 좁아지면 미도달도 조용히 줄어든다(같은 오라클이다).
  if (d && pin) matchesPin(l, d, pin)
  // 출하 소스의 커버리지 제외 표지 — 하나라도 있으면 아래 리더를 부르지 않는다(장부를 대조하지 않는다 — 머리 주석).
  unitMarks(l)
  const reader = { php: phpReport, kotlin: (x) => jvmReport('kotlin', x), dotnet: dotnetReport, java: (x) => jvmReport('java', x), ruby: rubyReport, go: goReport, python: pyReport, node: nodeReport, rust: rustReport }[l]
  const data = fails(l) ? null : reader(d)
  const rows = []
  if (data && !fails(l)) {
    const tot = data.files.reduce((a, f) => ({ stmts: a.stmts + f.stmts, covered: a.covered + f.covered }), { stmts: 0, covered: 0 })
    if (!ranNothing(l, data, tot)) {
      const byKey = new Map(data.units.map((u) => [`${u.file}:${u.name}`, u]))
      const D = new Set(d.files)
      for (const u of data.units) {
        if (!unitMissed(u)) continue
        const key = `${u.file}:${u.name}`
        const e = led[key]
        rows.push({ ...u, key, why: e ? e.why : 'NONE' })
        if (!e) drift(l, `unrecorded unreached code ${key} — the unit suite never reaches ${unitCounts(l, u)} of it: test that code, or record why in ${UNIT}`)
        else if (e[k] !== u[k] || (UNIT_BRANCHES.has(l) && e.branches !== u.branches))
          drift(l, `${key}: the unit run leaves ${unitCounts(l, u)} unreached, ${UNIT} records ${unitCounts(l, e)} — ${u[k] > e[k] || (u.branches ?? 0) > (e.branches ?? 0) ? 'test what the unit suite does not reach, or record why and correct the counts' : 'the unit suite reaches more of it now: lower the counts and check the why'}`)
      }
      for (const [key, e] of Object.entries(led)) {
        const at = key.indexOf(':')
        const file = at < 0 ? key : key.slice(0, at)
        const u = byKey.get(key)
        if (at < 0 || !D.has(file)) drift(l, `${UNIT}: entry ${key} names a file outside the boundary derived from ${d.site} — drop the entry`)
        else if (!u) drift(l, `stale entry ${key} — the data of ${file} has no such function (renamed or removed?); drop or rename the entry`)
        else if (!unitMissed(u)) drift(l, `stale entry ${key} — the unit run reaches all of it now; drop the entry`)
        const why = whyProblem(reg, key, e.why)
        if (why) drift(l, why)
      }
      printUnit(l, d, data, rows)
    }
  }
  emitFindings(l)
  const nf = findings.filter((f) => f.kind === 'FAIL' && (f.lang === l || f.lang === null)).length
  const nd = findings.filter((f) => f.kind === 'DRIFT' && f.lang === l).length
  if (nf) {
    console.log(`unit-unreached [${l}]: FAIL — ${nf} integrity failure${nf > 1 ? 's' : ''}; the ledger is not compared against a run that failed one`)
    return 2
  }
  const sum = rows.reduce((a, r) => ({ [k]: a[k] + r[k], branches: a.branches + (r.branches ?? 0) }), { [k]: 0, branches: 0 })
  const head = `${rows.length} function${rows.length === 1 ? '' : 's'} with code the unit suite never reaches (${unitCounts(l, sum)})`
  if (nd) {
    console.log(`unit-unreached [${l}]: DRIFT — ${head} · ${nd} ledger problem${nd > 1 ? 's' : ''} (the lane fails on it — each DRIFT line says what to change: a test, or ${UNIT}, whose why is ${UNIT_WHY.join(' · ')} with the reason or an open item of ${REGISTRY})`)
    return 1
  }
  console.log(`unit-unreached [${l}]: OK — ${head}, each recorded in ${UNIT}`)
  return 0
}
function printUnit(l, d, data, rows) {
  console.log(`[${l}] unit-unreached — boundary code the unit suite never reaches, against ${UNIT}`)
  console.log(`  boundary: ${d.files.length} files derived from ${d.site} (${d.label}) — equal to the pin in ${PINS}`)
  console.log(`  data: ${data.path.replace(/\\/g, '/')}${data.note ? ` (${data.note})` : ''}`)
  console.log(
    l === 'kotlin'
      ? '  (counts = JaCoCo method counters — missed lines · missed branches — summed over the methods folded into each source function: lambdas, local functions, default-argument bridges, anonymous objects)'
      : l === 'java'
        ? '  (counts = JaCoCo method counters — missed lines · missed branches — summed over the methods folded into each source method: lambdas, anonymous and local classes; a named nested class is its own type, overloads are told apart by their parameters)'
        : l === 'dotnet'
          ? '  (counts = coverlet per method — lines and branch arms no unit test ran — summed over what folds into each source member: state machines, lambdas, local functions; a decision inside a catch filter is not a branch, and in an async method an arm that flows into the other arm\'s target counts as run)'
          : l === 'ruby'
            ? '  (counts = Ruby Coverage per method — lines inside it and branch arms (if, unless, case, while, until, ternary, &.) the unit run never executed; a block\'s lines and arms are its method\'s, a one-line method\'s line counts by its calls; || and && are not branches to Ruby, so a failure arm behind them on a line that ran is not seen)'
            : l === 'go'
              ? '  (counts = Go cover profile per function — statements in blocks the unit run never executed; a function literal\'s blocks are its enclosing function\'s; the profile has no branches, so a path with no block of its own — an operand of && or ||, the false side of an if without else — is not seen)'
              : l === 'python'
                ? '  (counts = coverage.py function regions — statements the unit run never executed and branch arcs (branch = true) it never took; a nested def is its own region (outer.inner), a lambda\'s or comprehension\'s lines are its enclosing function\'s; a decision inside one line — a conditional expression, and/or, a comprehension filter — is not an arc, so its untaken side is not seen)'
                : l === 'node'
                  ? '  (counts = istanbul (vitest v8) per name range — statements the unit run never executed and if or switch arms it never took; a callback\'s statements and arms are its enclosing member\'s, a function-valued const or property is a range of its own; a decision inside an expression — ?:, &&, ||, ??, a default argument — is not counted, so its untaken side is not seen)'
                  : l === 'rust'
                    ? '  (counts = llvm-cov lcov lines (DA) the unit run never executed, per name range from the source — a closure\'s or async body\'s lines are its function\'s, a #[cfg(test)] item is the unit tests\' own and is left out; the library\'s unit-test binary keeps zero-count records of what nothing calls — an unpolled async body, an uninstantiated generic — so those lines count too; lines only: a failure closure on a line where code ran is not seen)'
                    : '  (counts = executable lines the unit run never executed — lines only: a failure branch on a line the happy path already runs is not seen)',
  )
  const sorted = [...rows].sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line))
  for (const r of sorted) console.log(`  UNREACHED ${r.file}:${r.line} ${r.name} · ${unitCounts(l, r)} · ${r.why}`)
}

// ── check — 데이터 없이: 파생 ↔ 핀 ↔ 소유자 ───────────────────────────────────────────────
function check() {
  const reg = loadRegistry()
  const p = loadPins()
  const counts = []
  let owners = 0
  let linked = 0
  let accounted = 0
  const derived = new Map()
  for (const l of LANGS) {
    const d = derivedFor(l)
    derived.set(l, d)
    const pin = p ? pinFor(l) : null
    if (d && pin && matchesPin(l, d, pin)) console.log(`[${l}] pin OK — ${d.files.length} files equal the derivation from ${d.site} (${d.label})`)
    if (!pin) continue
    counts.push(`${l} ${pin.pinned.length}`)
    const P = new Set(pin.pinned)
    const S = new Set(pin.surface)
    for (const [key, id] of Object.entries(pin.owners)) {
      owners++
      if (id === HARNESS_OWNER) linked++
      else if (id === UNIT_OWNER) accounted++
      const at = key.indexOf(':')
      if (at < 0 || !(P.has(key.slice(0, at)) || S.has(key.slice(0, at)))) drift(l, `owner entry ${key} names a file outside the pin${S.size ? ' and the admin surface' : ''}`)
      // 콜론 없는 키는 위 줄이 이미 DRIFT 로 낸다 — 하네스 · 단위 소유 판정은 키에서 파일 이름을 깎으므로 넘기지 않는다.
      const why = (id === HARNESS_OWNER || id === UNIT_OWNER) && at < 0 ? null : ownerProblem(l, pin, reg, key, id)
      if (why) drift(l, why)
    }
    console.log(`[${l}] owners: ${Object.keys(pin.owners).length} entries (${sortU(Object.values(pin.owners)).join(' · ') || 'none'})`)
    // 하네스 기록 — 핀 안의 파일이고, 그 파일의 함수를 하네스가 소유한다고 적은 항목이 있어야 한다(쓰이지 않는 기록은 낡았다).
    const used = new Set(Object.entries(pin.owners).filter(([k, id]) => id === HARNESS_OWNER && k.includes(':')).map(([k]) => k.slice(0, k.indexOf(':'))))
    for (const [f, rec] of Object.entries(pin.harness)) {
      if (!P.has(f)) drift(l, `harness record ${f} names a file outside the pin`)
      else if (!used.has(f)) drift(l, `harness record ${f} is not used by any owner entry — drop it`)
      else console.log(`[${l}] harness: ${f} ← ${rec.image} (${harnessWhy(l, f, rec) ? 'the link does not hold' : 'linked'})`)
    }
    if (S.size) console.log(`[${l}] admin surface: ${S.size} files (${pin.surface.filter((f) => !P.has(f)).length} outside the pin)`)
    console.log(`[${l}] ${floorText(pin)?.replace(/^floor /, 'floor: ') ?? 'floor: none (report mode)'}`)
  }
  // 단위 미도달 장부 — 데이터 없이 꼴 · 경계 · why 만(수는 레인의 `unit` 이 잰다). 등록부만 바꾼 PR 에서도 닫힌 id 가 여기서 걸린다 —
  // 레인은 `paths:` 뒤라 그 PR 에서 안 돈다(위 소유자와 같은 까닭).
  if (loadUnitLedger()) {
    for (const l of UNIT_LANGS) {
      const e = unitLedgerFor(l)
      if (!e) continue
      const D = derived.get(l)?.files ? new Set(derived.get(l).files) : null
      for (const [key, v] of Object.entries(e)) {
        const at = key.indexOf(':')
        if (D && (at < 0 || !D.has(key.slice(0, at)))) drift(l, `${UNIT}: entry ${key} names a file outside the boundary derived from ${derived.get(l).site} — drop the entry`)
        const why = whyProblem(reg, key, v.why)
        if (why) drift(l, why)
      }
      const kinds = Object.values(e).map((v) => UNIT_WHY.find((x) => v.why.startsWith(x))?.slice(0, -1) ?? v.why)
      const n = Object.keys(e).length
      console.log(`[${l}] unit-unreached: ${n} entr${n === 1 ? 'y' : 'ies'} (${sortU(kinds).map((k) => `${k} ${kinds.filter((x) => x === k).length}`).join(' · ') || 'none'})`)
    }
  }
  for (const f of findings) console.log(`${f.kind} [${f.lang ?? '-'}] ${f.msg}`)
  const nf = findings.filter((f) => f.kind === 'FAIL').length
  const nd = findings.length - nf
  if (nf || nd) {
    console.log(`integration-coverage check: ${nf ? 'FAIL' : 'DRIFT'} — ${nf} fail · ${nd} drift`)
    return nf ? 2 : 1
  }
  // 따로 세는 소유 — 0 인 것은 빼고, 둘 다 0 이면 「all open」이다.
  const special = [linked && `${linked} linked to the install harness`, accounted && `${accounted} accounted by the unit ledger`].filter(Boolean)
  console.log(`integration-coverage check: OK — ${counts.join(' · ')} files pinned · ${owners} owner entries, ${special.length ? [`${owners - linked - accounted} open`, ...special].join(' · ') : 'all open'}`)
  return 0
}

// ── run — 통합 테스트를 커버리지와 함께(종료코드는 테스트의 것) ────────────────────────────
function spawnStep(file, args, cwd, env = process.env) {
  console.log(`$ ${[file, ...args].join(' ')}   (in ${cwd.replace(/\\/g, '/')})`)
  const r = spawnSync(file, args, { cwd, env, stdio: 'inherit' })
  if (r.error) {
    console.log(`FAIL [${lang}] could not start ${file}: ${r.error.message}`)
    return 2
  }
  if (r.signal) {
    console.log(`FAIL [${lang}] ${file} was killed by ${r.signal}`)
    return 2
  }
  return r.status
}
// mvn — 리눅스 · 맥은 PATH 의 `mvn`. 윈도는 `mvn.cmd` 라 셸 없이 못 띄운다(npm.cmd 와 같다 — 위 사용 주석) — cmd 로 띄우되, 인자는
// 이 스크립트가 만든 플래그 · 경로뿐이니 따옴표로 감싸고 cmd 가 다르게 읽는 글자(`"` · `%` · `!` · 줄바꿈)가 든 인자는 받지 않는다.
function spawnMaven(args, cwd) {
  if (process.platform !== 'win32') return spawnStep('mvn', args, cwd)
  const bad = args.find((a) => /["%!\r\n]/.test(a))
  if (bad !== undefined) {
    console.log(`FAIL [${lang}] cannot hand ${bad} to mvn.cmd through cmd.exe`)
    return 2
  }
  console.log(`$ mvn ${args.join(' ')}   (in ${cwd.replace(/\\/g, '/')})`)
  const r = spawnSync(['mvn', ...args.map((a) => (/[\s&|<>^()]/.test(a) ? `"${a}"` : a))].join(' '), { cwd, stdio: 'inherit', shell: true })
  if (r.error) {
    console.log(`FAIL [${lang}] could not start mvn: ${r.error.message}`)
    return 2
  }
  return r.status ?? 2
}
// Gradle 래퍼 — 윈도의 `gradlew.bat` 은 mvn.cmd 처럼 셸 없이 못 띄운다(spawnMaven 과 같은 따옴표 규칙).
function spawnGradle(args, cwd) {
  if (process.platform !== 'win32') return spawnStep('./gradlew', args, cwd)
  const bad = args.find((a) => /["%!\r\n]/.test(a))
  if (bad !== undefined) {
    console.log(`FAIL [${lang}] cannot hand ${bad} to gradlew.bat through cmd.exe`)
    return 2
  }
  console.log(`$ gradlew ${args.join(' ')}   (in ${cwd.replace(/\\/g, '/')})`)
  // 전체 경로로 — cmd.exe 는 현재 디렉터리의 실행 파일을 경로 없이 찾지 않을 수 있다(실측: 이 기계에서 「인식되지 않는 명령」).
  const r = spawnSync([`"${join(cwd, 'gradlew.bat')}"`, ...args.map((a) => (/[\s&|<>^()]/.test(a) ? `"${a}"` : a))].join(' '), { cwd, stdio: 'inherit', shell: true })
  if (r.error) {
    console.log(`FAIL [${lang}] could not start gradlew.bat: ${r.error.message}`)
    return 2
  }
  return r.status ?? 2
}
// 파생 파일들의 공통 디렉터리(언어 디렉터리 기준). coverage.py `source` 를 **디렉터리로** 주면 한 번도 import 안 된
// 파일도 0% 로 보고된다 — 이름(`include`)으로 주면 사라진다(위 머리 주석의 실측).
function commonDir(files) {
  const parts = files.map((f) => f.split('/').slice(0, -1))
  const out = []
  for (let i = 0; parts.every((p) => i < p.length && p[i] === parts[0][i]); i++) out.push(parts[0][i])
  return out.join('/')
}
function run(l) {
  const d = derivedFor(l)
  if (!d) {
    emitFindings(l)
    return 2
  }
  mkdirSync(out, { recursive: true })
  const cwd = join(root, d.dir)
  if (l === 'go') {
    // 옛 프로필(단위는 그 기록도)을 먼저 지운다(php 와 같은 이유 — 일찍 멈춘 run 뒤에 지난 실행의 것이 남지 않게). 통합은 레인의 E2E
    // (`-tags=integration -run TestE2E`)다. 단위 미도달 장부(`unit go`)는 레인의 단위 명령 `go test -count=1 ./...` 에 같은 프로필 자리를
    // 더한다 — 태그가 없어 `//go:build integration` 뒤의 통합 시험은 컴파일되지 않는다. 이름은 `.unit` 이 붙는다(SUITE).
    const prof = GO_DATA()
    rmSync(prof, { force: true })
    if (SUITE !== 'unit') return spawnStep('go', ['test', '-tags=integration', '-run', 'TestE2E', '-count=1', `-coverprofile=${prof}`, './...'], cwd)
    rmSync(GO_RUN(), { force: true })
    // 경계 파일의 바이트 — 커버 프로필에는 소스 해시가 없다. 실행 앞뒤로 재서 같을 때만 기록에 싣는다(dotnet 과 같다 — 빌드가 그 바이트를
    // 컴파일했다). unit-report 가 그것을 트리의 바이트와 대조한다.
    const shas = () => Object.fromEntries(d.files.map((f) => [f, existsSync(join(root, f)) ? createHash('sha1').update(readFileSync(join(root, f))).digest('hex') : null]))
    const before = shas()
    const rc = spawnStep('go', ['test', '-count=1', `-coverprofile=${prof}`, './...'], cwd)
    const after = shas()
    // 이 실행의 기록 — 종료코드 · 프로필의 sha1 · 경계 파일의 sha1(통합 run 은 기록을 쓰지 않는다 — 단위 실행의 기록만 `suite` 를 갖는다).
    if (existsSync(prof)) {
      const same = d.files.every((f) => before[f] !== null && before[f] === after[f])
      const sha = createHash('sha1').update(readFileSync(prof)).digest('hex')
      writeFileSync(GO_RUN(), `${JSON.stringify({ run: 'go', suite: 'unit', exit: rc, profile_sha1: sha, files: same ? before : null })}\n`)
    }
    return rc
  }
  if (l === 'rust') {
    const lcov = RUST_DATA()
    rmSync(lcov, { force: true })
    // 통합 대상 하나만 — 라이브러리가 cfg(test) 없이 링크된다(단위 테스트가 같은 빌드에서 돌면 리포트가 FAIL 한다).
    // `--locked` 는 레인의 다른 빌드와 같은 이유다(커밋된 Cargo.lock 그대로).
    if (SUITE !== 'unit') return spawnStep('cargo', ['llvm-cov', '--locked', '--test', 'integration_test', '--lcov', '--output-path', lcov, '--', '--ignored'], cwd)
    // 단위 미도달 장부(`unit rust`) — 레인의 단위 커버리지 명령(coverage 잡의 `cargo llvm-cov` — 레인의 `cargo test` 를 계측해 돈다)을 경계를
    // 빼는 정규식 없이 lcov 로 돈다: 단위 시험(lib 의 cfg(test) · tests/ 의 대상)이 돌고, 통합 E2E 는 `#[ignore]` 라 컴파일만 된다. 옛 기록을
    // 먼저 지운다(go 와 같다). 경계 파일의 바이트는 실행 앞뒤로 재서 같을 때만 기록에 싣는다(lcov 에는 소스 해시가 없다 — go 와 같다).
    rmSync(RUST_RUN(), { force: true })
    const shas = () => Object.fromEntries(d.files.map((f) => [f, existsSync(join(root, f)) ? createHash('sha1').update(readFileSync(join(root, f))).digest('hex') : null]))
    const before = shas()
    const rc = spawnStep('cargo', ['llvm-cov', '--locked', '--lcov', '--output-path', lcov], cwd)
    const after = shas()
    if (existsSync(lcov)) {
      const same = d.files.every((f) => before[f] !== null && before[f] === after[f])
      const sha = createHash('sha1').update(readFileSync(lcov)).digest('hex')
      // 그 실행의 rustc — 판이 줄의 귀속을 바꾼다(머리 주석). 기록에 싣고 리포트가 찍기만 한다.
      const rustc = spawnSync('rustc', ['--version'], { cwd, encoding: 'utf8' }).stdout?.trim() || null
      writeFileSync(RUST_RUN(), `${JSON.stringify({ run: 'rust', suite: 'unit', exit: rc, data_sha1: sha, rustc, files: same ? before : null })}\n`)
    }
    return rc
  }
  if (l === 'php') {
    // 단위 설정의 `<source>` 만 경계 파일로 바꾼 사본을 **그 옆에** 만든다 — bootstrap · 테스트 디렉터리 · cacheDirectory 의
    // 상대 경로가 같은 디렉터리를 기준으로 그대로 풀린다(테스트 스위트 정의를 옮겨 적지 않는다). `--coverage-filter` 로는 못
    // 한다 — include 를 더할 뿐이라 `<exclude>` 의 경계 파일이 그대로 빠진다(PHPUnit 12 Merger.php). 실행 뒤 지운다.
    const cfg = join(cwd, 'phpunit.xml')
    const phpunit = join(cwd, 'vendor', 'bin', 'phpunit')
    // 옛 데이터와 그 기록은 **먼저** 지운다 — 아래에서 일찍 멈추면 지난 성공한 실행의 데이터 · 기록이 남아, 다음 report 가 낡은
    // 수치를 OK 로 냈다(독립 레그 3차 실측: vendor/bin/phpunit 을 치운 run → rc 2 · 옛 기록 그대로 → report OK 141/235).
    // 단위 미도달 장부(`unit php`)는 같은 길로 `--testsuite unit` 을 돈다 — 이름은 `.unit` 이 붙는다(SUITE).
    const xdir = PHP_DATA()
    rmSync(xdir, { recursive: true, force: true })
    rmSync(PHP_RUN(), { force: true })
    const stop = (msg) => {
      fail(l, msg)
      emitFindings(l)
      return 2
    }
    if (!existsSync(cfg)) return stop(`${d.dir}/phpunit.xml is missing`)
    if (!existsSync(phpunit)) return stop(`${d.dir}/vendor/bin/phpunit is missing — install the lane's dependencies first (composer install)`)
    const xml = readFileSync(cfg, 'utf8')
    // 주석을 같은 길이의 공백으로 지운 사본에서 `<source>` 를 찾고, 원문의 같은 자리를 바꾼다(주석 속 `</source>` 에 안 걸린다).
    const blank = xml.replace(/<!--[\s\S]*?-->/g, (m) => m.replace(/[^\n]/g, ' '))
    const blocks = [...blank.matchAll(/<source[\s>][\s\S]*?<\/source>/g)]
    if (blocks.length !== 1) return stop(`${d.dir}/phpunit.xml must have exactly one <source> (found ${blocks.length})`)
    const rel = (p) => p.slice(d.dir.length + 1)
    const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;')
    const source = ['<source>', '    <include>', ...d.files.map((f) => `      <file>${esc(rel(f))}</file>`), '    </include>', '  </source>'].join('\n')
    const at = blocks[0].index
    const gen = join(cwd, `.integration-coverage${TAG}.phpunit.xml`)
    writeFileSync(gen, xml.slice(0, at) + source + xml.slice(at + blocks[0][0].length))
    let rc
    try {
      // 같은 `--testsuite integration` 이다(레인의 명령 — 단위 장부는 `unit`). Xdebug 는 `XDEBUG_MODE=coverage` 없이는 아무것도 안 잰다 —
      // pcov 는 무시한다.
      rc = spawnStep('php', [phpunit, '--configuration', gen, '--testsuite', SUITE, '--coverage-xml', xdir], cwd, {
        ...process.env,
        XDEBUG_MODE: 'coverage',
      })
    } finally {
      rmSync(gen, { force: true })
    }
    // 이 실행의 기록 — report 가 데이터를 이 실행에 묶는다(종료코드 · 그 index.xml 의 sha1). PHPUnit 은 실패한 실행에도 XML 을
    // 쓰고, 경계에 닿기 전에 실패한 테스트(`setUpBeforeClass` 가 던진 클래스 전체)는 데이터의 <tests> 에 아예 안 실린다 — 독립
    // 레그 2차 실측: 그런 실행을 따로 report 하면 77/235 · exit 1 로 지나갔다. 단위 실행의 기록만 `suite` 를 갖는다.
    const index = join(xdir, 'index.xml')
    if (existsSync(index)) {
      const sha = createHash('sha1').update(readFileSync(index)).digest('hex')
      const rec = SUITE === 'unit' ? { run: 'php', suite: 'unit', exit: rc, index_sha1: sha } : { run: 'php', exit: rc, index_sha1: sha }
      writeFileSync(PHP_RUN(), `${JSON.stringify(rec)}\n`)
    }
    return rc
  }
  if (l === 'ruby') {
    // 옛 데이터 · 기록 · 부트 파일을 먼저 지운다(php 와 같은 이유 — 일찍 멈춘 run 뒤에 지난 실행의 것이 남지 않게). 단위 미도달
    // 장부(`unit ruby`)는 같은 길로 단위 스위트를 돈다 — 이름은 `.unit` 이 붙는다(SUITE).
    const data = RUBY_DATA()
    const boot = join(out, `ruby${TAG}-boot`)
    rmSync(data, { force: true })
    rmSync(RUBY_RUN(), { force: true })
    rmSync(boot, { recursive: true, force: true })
    if (!process.env.BUNDLE_GEMFILE && !existsSync(join(cwd, 'Gemfile'))) {
      fail(l, `${d.dir}/Gemfile is missing — the run needs the lane's bundle (bundle install)`)
      emitFindings(l)
      return 2
    }
    mkdirSync(boot, { recursive: true })
    const start = join(boot, 'start.rb')
    const dump = join(boot, 'dump.rb')
    writeFileSync(start, RUBY_START)
    writeFileSync(dump, RUBY_DUMP)
    // 레인의 명령과 같은 스펙 · 태그 · 환경이다 — 통합은 `RUN_INTEGRATION=1 bundle exec rspec spec/integration --tag integration`,
    // 단위는 `bundle exec rspec`(경로 · 태그 없이 — RUN_INTEGRATION 이 없으면 spec_helper 가 `:integration` 을 거르고 SimpleCov 게이트를
    // 건다). 단위는 RUN_INTEGRATION 을 **지운** 환경에서 돈다 — 셸에 남은 값이 통합 예제를 싣고 게이트를 끄지 않게(윈도의 환경 이름은
    // 대소문자를 안 가린다). `bundle exec` 대신 순서를 명시한다(머리 주석: start → bundler/setup → 번들의 rspec).
    // ⚠️ 단위의 경로 `spec` 은 레인의 인자 없는 `rspec` 이 도는 기본 경로다 — rspec-core 는 `$0` 이 `rspec` 일 때만 default_path 를 더한다
    // (configuration.rb `files_or_directories_to_run=`). `-e` 로 실린 여기서는 더하지 않아 예제 0 개로 끝났다(실측 2026-11-20 — 리더가
    // 공허한 실행으로 FAIL 했다).
    const env = SUITE === 'unit'
      ? Object.fromEntries(Object.entries(process.env).filter(([k]) => k.toUpperCase() !== 'RUN_INTEGRATION'))
      : { ...process.env, RUN_INTEGRATION: '1' }
    const select = SUITE === 'unit' ? ['spec'] : ['spec/integration', '--tag', 'integration']
    const rc = spawnStep(
      'ruby',
      [`-r${start}`, '-rbundler/setup', '-e', 'load Gem.bin_path("rspec-core", "rspec")', '--', '--require', dump, ...select],
      cwd,
      { ...env, KCSDK_ITCOV_OUT: data, KCSDK_ITCOV_ROOT: cwd },
    )
    // 이 실행의 기록 — 단위 실행의 기록만 `suite` 를 갖는다(php 와 같다).
    if (existsSync(data)) {
      const sha = createHash('sha1').update(readFileSync(data)).digest('hex')
      const rec = SUITE === 'unit' ? { run: 'ruby', suite: 'unit', exit: rc, dump_sha1: sha } : { run: 'ruby', exit: rc, dump_sha1: sha }
      writeFileSync(RUBY_RUN(), `${JSON.stringify(rec)}\n`)
    }
    return rc
  }
  if (l === 'java') {
    // 옛 데이터 · exec · javap 출력 · 기록 · CLI 를 먼저 지운다(php 와 같은 이유 — 일찍 멈춘 run 뒤에 지난 실행의 것이 남지 않게). 단위
    // 미도달 장부(`unit java`)는 같은 길로 단위 스위트(surefire)를 돈다 — 이름은 `.unit` 이 붙는다(SUITE).
    const data = JVM_DATA(l)
    const exec = JVM_EXEC(l)
    const javap = JVM_JAVAP(l)
    const cli = join(out, `java${TAG}-cli`)
    for (const f of [data, exec, javap, JVM_RUN(l)]) rmSync(f, { force: true })
    rmSync(cli, { recursive: true, force: true })
    const stop = (msg) => {
      fail(l, msg)
      emitFindings(l)
      return 2
    }
    const pomPath = join(cwd, 'pom.xml')
    if (!existsSync(pomPath)) return stop(`${d.dir}/pom.xml is missing — the lane builds one reactor`)
    // 리포트의 JaCoCo 는 에이전트와 같은 판이어야 한다 — 판은 레인의 pom 이 댄다(플러그인 설정은 거기 하나다 — coverage-boundary).
    // 주석은 같은 길이의 공백으로 지운다(지워 붙이면 새 `<!--` 가 생길 수 있다 — CodeQL js/incomplete-multi-character-sanitization ·
    // php 의 두 자리와 같다).
    const pomX = readFileSync(pomPath, 'utf8').replace(/<!--[\s\S]*?-->/g, (m) => m.replace(/[^\n]/g, ' '))
    const vers = [...pomX.matchAll(/<plugin>([\s\S]*?)<\/plugin>/g)]
      .map((m) => m[1])
      .filter((b) => /<artifactId>\s*jacoco-maven-plugin\s*<\/artifactId>/.test(b))
      .map((b) => /<version>\s*([^<\s]+)\s*<\/version>/.exec(b)?.[1])
    if (vers.length !== 1 || !/^\d+(?:\.\d+)+$/.test(vers[0] ?? '')) return stop(`${d.dir}/pom.xml must pin one jacoco-maven-plugin <version> — the report's JaCoCo has to match the agent (found ${vers.length})`)
    const ver = vers[0]
    // 경계 파일 + admin 표면 파일 — report 가 표면 파일도 같은 실행의 바이트인지 대조한다.
    const recorded = sortU([...d.files, ...surfaceOf(l)])
    const shas = () => Object.fromEntries(recorded.map((f) => [f, existsSync(join(root, f)) ? createHash('sha1').update(readFileSync(join(root, f))).digest('hex') : null]))
    const before = shas()
    // 레인의 명령(`mvn -B -f java/pom.xml verify`)과 같은 리액터 · 골이다. 더하는 것: `clean`(지난 실행의 클래스 · 테스트 보고가 남지
    // 않게) · 단위 테스트 끄기(`-Dtest=NONE` — surefire 와 failsafe 가 같은 에이전트 인자를 써 단위와 IT 가 한 exec 에 합쳐진다 — 실측) ·
    // exec 를 <out> 으로(`-Djacoco.destFile` — 모듈의 report · check 는 그 모듈에 데이터가 없어 건너뛴다).
    // 단위 미도달 장부는 레인의 단위 명령(`mvn -f java/pom.xml test -DskipITs=true` — .claude/rules/java.md)에 같은 `clean` · exec 자리를
    // 더한다: `test` 단계는 failsafe(integration-test · verify)와 report · check · japicmp(verify) 앞에서 멈춘다 — 모듈마다 surefire 가
    // 같은 exec 에 세션을 덧붙인다.
    const goals = SUITE === 'unit' ? ['clean', 'test', '-DskipITs=true'] : ['clean', 'verify', '-Dtest=NONE', '-Dsurefire.failIfNoSpecifiedTests=false']
    const rc = spawnMaven(['-B', '-f', 'pom.xml', ...goals, `-Djacoco.destFile=${exec}`], cwd)
    const after = shas()
    if (!existsSync(exec)) return rc
    const rcCli = spawnMaven(['-B', '-q', 'dependency:copy', `-Dartifact=org.jacoco:org.jacoco.cli:${ver}:jar:nodeps`, `-DoutputDirectory=${cli}`], cwd)
    const jar = join(cli, `org.jacoco.cli-${ver}-nodeps.jar`)
    if (rcCli !== 0 || !existsSync(jar)) return stop(`could not fetch the JaCoCo CLI ${ver} (org.jacoco:org.jacoco.cli:${ver}:jar:nodeps) — the report has to use the agent's version`)
    const jbin = (t) => (process.env.JAVA_HOME ? join(process.env.JAVA_HOME, 'bin', t) : t)
    // 경계 파일이 든 모듈의 클래스 디렉터리만 분석한다(exec 에는 의존 라이브러리 · 테스트 러너의 클래스도 든다).
    const classDirs = sortU(d.files.map((f) => f.split('/')[1])).map((m) => join(cwd, m, 'target', 'classes'))
    const gone = classDirs.filter((c) => !existsSync(c))
    if (gone.length) return stop(`the build left no classes at ${gone.map((c) => c.replace(/\\/g, '/')).join(' · ')} — the report analyzes the boundary modules' class files`)
    const rcRep = spawnStep(jbin('java'), ['-jar', jar, 'report', exec, ...classDirs.flatMap((c) => ['--classfiles', c]), '--xml', data], cwd)
    if (rcRep !== 0 || !existsSync(data)) return stop(`the JaCoCo CLI wrote no XML report (exit ${rcRep})`)
    // 클래스 파일의 사실 — 경계 파일의 패키지 디렉터리의 클래스 파일 전부(같은 소스 파일의 중첩 · 익명 · 최상위 보조 타입은 리포트가
    // SourceFile 로 고른다).
    const classFiles = []
    for (const f of d.files) {
      const fm = /^[^/]+\/([^/]+)\/src\/main\/java\/(.+)\/[^/]+\.java$/.exec(f)
      if (!fm) continue
      const dir = join(cwd, fm[1], 'target', 'classes', ...fm[2].split('/'))
      if (existsSync(dir)) for (const e of readdirSync(dir)) if (e.endsWith('.class')) classFiles.push(join(dir, e))
    }
    // 64 개씩 — 한 번에 넘기면 윈도의 명령줄 길이(32,767 자)에 걸릴 수 있다(독립 레그 1차 지적).
    const all = sortU(classFiles)
    console.log(`$ javap -l -p -v <${all.length} class files of the boundary packages>`)
    let text = ''
    for (let i = 0; i < all.length; i += 64) {
      const jp = spawnSync(jbin('javap'), ['-l', '-p', '-v', ...all.slice(i, i + 64)], { cwd, encoding: 'utf8', maxBuffer: 256 << 20 })
      if (jp.error || jp.status !== 0) return stop(`javap failed (${jp.error?.message ?? `exit ${jp.status}`}) — the report needs the class files' line tables`)
      text += jp.stdout
    }
    writeFileSync(javap, text)
    const sha = (p) => createHash('sha1').update(readFileSync(p)).digest('hex')
    const same = recorded.every((f) => before[f] !== null && before[f] === after[f])
    const tests = { completed: 0, failures: 0, errors: 0, skipped: 0 }
    const reportsOf = (dir) => (existsSync(dir) ? readdirSync(dir).filter((n) => /^TEST-.*\.xml$/.test(n)) : [])
    if (SUITE === 'unit') {
      // 테스트 — surefire 의 보고(모듈마다 TEST-*.xml — 머리 `<testsuite>` 의 tests · failures · errors · skipped)를 합치고, failsafe 의
      // 보고가 없는지 센다(통합 시험은 돌지 않았어야 한다 — clean 뒤라 이 실행이 쓴 것만 있다). kotlin 의 단위 기록과 같은 꼴이다.
      let integration = 0
      for (const e of readdirSync(cwd, { withFileTypes: true })) {
        if (!e.isDirectory()) continue
        const rep = join(cwd, e.name, 'target', 'surefire-reports')
        for (const n of reportsOf(rep)) {
          const head = /<testsuite\b[^>]*>/.exec(readFileSync(join(rep, n), 'utf8'))?.[0] ?? ''
          const attr = (k) => Number(new RegExp(`\\b${k}="(\\d+)"`).exec(head)?.[1] ?? NaN)
          tests.completed += attr('tests')
          tests.failures += attr('failures')
          tests.errors += attr('errors')
          tests.skipped += attr('skipped')
        }
        integration += reportsOf(join(cwd, e.name, 'target', 'failsafe-reports')).length
      }
      const facts = { jacoco: ver, data_sha1: sha(data), javap_sha1: sha(javap), exec_sha1: sha(exec), tests }
      writeFileSync(JVM_RUN(l), `${JSON.stringify({ run: 'java', suite: 'unit', exit: rc, ...facts, integration, files: same ? before : null })}\n`)
      return rc
    }
    // 테스트 — failsafe 의 요약(모듈마다)을 합치고, surefire 의 보고가 없는지 센다(단위 테스트는 돌지 않았어야 한다).
    let unit = 0
    for (const e of readdirSync(cwd, { withFileTypes: true })) {
      if (!e.isDirectory()) continue
      const sum = join(cwd, e.name, 'target', 'failsafe-reports', 'failsafe-summary.xml')
      if (existsSync(sum)) {
        const x = readFileSync(sum, 'utf8')
        for (const k of Object.keys(tests)) tests[k] += Number(new RegExp(`<${k}>(\\d+)</${k}>`).exec(x)?.[1] ?? NaN)
      }
      const rep = join(cwd, e.name, 'target', 'surefire-reports')
      if (existsSync(rep)) unit += readdirSync(rep).filter((n) => /^TEST-.*\.xml$/.test(n)).length
    }
    writeFileSync(JVM_RUN(l), `${JSON.stringify({ run: 'java', exit: rc, jacoco: ver, data_sha1: sha(data), javap_sha1: sha(javap), exec_sha1: sha(exec), tests, unit, files: same ? before : null })}\n`)
    return rc
  }
  if (l === 'kotlin') {
    // 옛 데이터 · exec · javap 출력 · 기록 · CLI · 초기화 스크립트를 먼저 지운다(java 와 같은 이유). 재는 태스크는 통합이면
    // `integrationTest`, 단위 미도달 장부(`unit kotlin`)면 `test` 다 — 이름은 `.unit` 이 붙는다(SUITE).
    const task = SUITE === 'unit' ? 'test' : 'integrationTest'
    const otherTask = SUITE === 'unit' ? 'integrationTest' : 'test'
    const data = JVM_DATA(l)
    const exec = JVM_EXEC(l)
    const javap = JVM_JAVAP(l)
    const cli = join(out, `kotlin${TAG}-cli`)
    const init = join(out, `kotlin${TAG}.itcov.init.gradle.kts`)
    for (const f of [data, exec, javap, JVM_RUN(l), init]) rmSync(f, { force: true })
    rmSync(cli, { recursive: true, force: true })
    const stop = (msg) => {
      fail(l, msg)
      emitFindings(l)
      return 2
    }
    if (!existsSync(join(cwd, process.platform === 'win32' ? 'gradlew.bat' : 'gradlew'))) return stop(`${d.dir}/gradlew is missing — the lane runs its Gradle wrapper`)
    // JaCoCo 판 — kotlin 빌드는 Kover 를 쓰고 JaCoCo 판을 안 갖는다. 저장소의 JVM JaCoCo 판은 java 레인의 pom 하나다(거기서
    // 올린다) — 판을 여기 다시 적지 않는다.
    const pomPath = join(root, 'java', 'pom.xml')
    if (!existsSync(pomPath)) return stop('java/pom.xml is missing — the JaCoCo version of the JVM lanes lives there')
    const pomX = readFileSync(pomPath, 'utf8').replace(/<!--[\s\S]*?-->/g, (m) => m.replace(/[^\n]/g, ' '))
    const vers = [...pomX.matchAll(/<plugin>([\s\S]*?)<\/plugin>/g)]
      .map((m) => m[1])
      .filter((b) => /<artifactId>\s*jacoco-maven-plugin\s*<\/artifactId>/.test(b))
      .map((b) => /<version>\s*([^<\s]+)\s*<\/version>/.exec(b)?.[1])
    if (vers.length !== 1 || !/^\d+(?:\.\d+)+$/.test(vers[0] ?? '')) return stop(`java/pom.xml must pin one jacoco-maven-plugin <version> — the JVM lanes share it (found ${vers.length})`)
    const ver = vers[0]
    writeFileSync(init, KOTLIN_INIT)
    // 경계 파일 + admin 표면 파일 — report 가 표면 파일도 같은 실행의 바이트인지 대조한다.
    const recorded = sortU([...d.files, ...surfaceOf(l)])
    const shas = () => Object.fromEntries(recorded.map((f) => [f, existsSync(join(root, f)) ? createHash('sha1').update(readFileSync(join(root, f))).digest('hex') : null]))
    const before = shas()
    // 레인의 명령(`./gradlew integrationTest` · 단위는 `./gradlew test`)과 같은 태스크다. 더하는 것: `clean`(지난 실행의 클래스 · 테스트
    // 결과가 남지 않게 — 다른 스위트의 결과가 남으면 「섞였다」로 못 가른다) · 초기화 스크립트 · CLI 받기.
    const rc = spawnGradle(['-I', init, `-PkcsdkItcovJacoco=${ver}`, `-PkcsdkItcovTask=${task}`, `-PkcsdkItcovExec=${exec}`, `-PkcsdkItcovCli=${cli}`, 'clean', task, 'kcsdkItcovCli'], cwd)
    const after = shas()
    if (!existsSync(exec)) return rc
    const jar = join(cli, `org.jacoco.cli-${ver}-nodeps.jar`)
    if (!existsSync(jar)) return stop(`could not fetch the JaCoCo CLI ${ver} (org.jacoco:org.jacoco.cli:${ver}:nodeps) — the report has to use the agent's version`)
    const jbin = (t) => (process.env.JAVA_HOME ? join(process.env.JAVA_HOME, 'bin', t) : t)
    const classDir = join(cwd, 'build', 'classes', 'kotlin', 'main')
    if (!existsSync(classDir)) return stop(`the build left no classes at ${classDir.replace(/\\/g, '/')} — the report analyzes the lane's class files`)
    const rcRep = spawnStep(jbin('java'), ['-jar', jar, 'report', exec, '--classfiles', classDir, '--xml', data], cwd)
    if (rcRep !== 0 || !existsSync(data)) return stop(`the JaCoCo CLI wrote no XML report (exit ${rcRep})`)
    // 모듈 이름 — `internal` 멤버 이름의 접미가 이것이다(META-INF/<모듈>.kotlin_module 하나).
    const metaDir = join(classDir, 'META-INF')
    const mods = existsSync(metaDir) ? readdirSync(metaDir).filter((n) => n.endsWith('.kotlin_module')) : []
    if (mods.length !== 1) return stop(`the build has ${mods.length} META-INF/*.kotlin_module files — the report needs the one module name (internal members carry it as a name suffix)`)
    const module = mods[0].slice(0, -'.kotlin_module'.length)
    // 클래스 파일의 사실 — 경계 파일의 패키지 디렉터리의 클래스 파일 전부(java 와 같다 — 리포트가 SourceFile 로 고른다).
    const classFiles = []
    for (const f of d.files) {
      const fm = /^[^/]+\/src\/main\/kotlin\/(.+)\/[^/]+\.kt$/.exec(f)
      if (!fm) continue
      const dir = join(classDir, ...fm[1].split('/'))
      if (existsSync(dir)) for (const e of readdirSync(dir)) if (e.endsWith('.class')) classFiles.push(join(dir, e))
    }
    const all = sortU(classFiles)
    console.log(`$ javap -l -p -v <${all.length} class files of the boundary packages>`)
    let text = ''
    for (let i = 0; i < all.length; i += 64) {
      const jp = spawnSync(jbin('javap'), ['-l', '-p', '-v', ...all.slice(i, i + 64)], { cwd, encoding: 'utf8', maxBuffer: 256 << 20 })
      if (jp.error || jp.status !== 0) return stop(`javap failed (${jp.error?.message ?? `exit ${jp.status}`}) — the report needs the class files' line tables`)
      text += jp.stdout
    }
    writeFileSync(javap, text)
    // 테스트 — 잰 태스크의 JUnit XML 을 합치고, 다른 스위트의 결과가 없는지 센다(clean 뒤라 이 실행이 쓴 것만 있다).
    const tests = { completed: 0, failures: 0, errors: 0, skipped: 0 }
    const itDir = join(cwd, 'build', 'test-results', task)
    if (existsSync(itDir)) {
      for (const n of readdirSync(itDir).filter((x) => /^TEST-.*\.xml$/.test(x))) {
        const head = /<testsuite\b[^>]*>/.exec(readFileSync(join(itDir, n), 'utf8'))?.[0] ?? ''
        const attr = (k) => Number(new RegExp(`\\b${k}="(\\d+)"`).exec(head)?.[1] ?? NaN)
        tests.completed += attr('tests')
        tests.failures += attr('failures')
        tests.errors += attr('errors')
        tests.skipped += attr('skipped')
      }
    }
    const otherDir = join(cwd, 'build', 'test-results', otherTask)
    const other = existsSync(otherDir) ? readdirSync(otherDir).filter((x) => /^TEST-.*\.xml$/.test(x)).length : 0
    const sha = (p) => createHash('sha1').update(readFileSync(p)).digest('hex')
    const same = recorded.every((f) => before[f] !== null && before[f] === after[f])
    const facts = { jacoco: ver, module, data_sha1: sha(data), javap_sha1: sha(javap), exec_sha1: sha(exec), tests }
    const rec = SUITE === 'unit' ? { run: 'kotlin', suite: 'unit', exit: rc, ...facts, integration: other } : { run: 'kotlin', exit: rc, ...facts, unit: other }
    writeFileSync(JVM_RUN(l), `${JSON.stringify({ ...rec, files: same ? before : null })}\n`)
    return rc
  }
  if (l === 'dotnet') {
    // 옛 데이터 · trx · 기록 · 결과 디렉터리를 먼저 지운다(php 와 같은 이유 — 일찍 멈춘 run 뒤에 지난 실행의 것이 남지 않게). 단위 미도달
    // 장부(`unit dotnet`)는 같은 길로 단위 스위트를 돈다 — 이름은 `.unit` 이 붙는다(SUITE).
    const data = DOTNET_DATA()
    const trx = DOTNET_TRX()
    const results = join(out, `dotnet${TAG}-results`)
    const settings = join(out, `dotnet${TAG}.runsettings`)
    for (const f of [data, trx, DOTNET_RUN(), settings]) rmSync(f, { force: true })
    rmSync(results, { recursive: true, force: true })
    const stop = (msg) => {
      fail(l, msg)
      emitFindings(l)
      return 2
    }
    const slns = readdirSync(cwd).filter((f) => f.endsWith('.sln')).sort()
    if (slns.length !== 1) return stop(`${d.dir}/ must hold exactly one .sln — the lane tests one solution (found ${slns.length ? slns.join(' · ') : 'none'})`)
    writeFileSync(settings, DOTNET_SETTINGS)
    // 경계 파일의 바이트 — coverlet 의 데이터에는 소스 해시가 없다. 실행 앞뒤로 재서 같을 때만 기록에 싣는다(빌드가 그 바이트를
    // 컴파일했다). report 가 그것을 트리의 바이트와 대조한다.
    // 경계 파일 + admin 표면 파일 — report 가 표면 파일도 같은 실행의 바이트인지 대조한다.
    const recorded = sortU([...d.files, ...surfaceOf(l)])
    const shas = () => Object.fromEntries(recorded.map((f) => [f, existsSync(join(root, f)) ? createHash('sha1').update(readFileSync(join(root, f))).digest('hex') : null]))
    const before = shas()
    // 레인의 명령(통합 `dotnet test dotnet/Keycloak.Sdk.sln -c Release --filter "Category=Integration"` · 단위는 같은 해 · 구성에
    // `--filter "Category!=Integration"`)과 같은 해 · 구성 · 필터다.
    // ⚠️ 대상이 여럿(`<TargetFrameworks>` — 읽는 규칙은 scripts/lib/dotnet-tfm.mjs)이면 **가장 낮은 대상 하나**만 돈다 —
    // 대상마다 첨부가 하나씩 생겨 아래 「첨부 하나」 불변식이 멈추고, 두 대상의 데이터를 합치면 같은 경계 파일을 두 번 센다.
    // 하한(소비자가 받는 가장 낮은 자산)이 재는 대상이다. 나머지 대상의 통합은 레인 잡이 커버리지 없이 돈다. 단위 장부도 같은 대상이다 —
    // 두 장부가 같은 컴파일 결과의 이름 · 줄을 읽는다(실측 2026-11-19: net10.0 의 단위 실행도 경계 메서드마다 줄 · 가지 수가 같았다).
    const props = join(cwd, 'Directory.Build.props')
    const tfms = existsSync(props) ? dotnetTfms(readFileSync(props, 'utf8')) : []
    const framework = tfms.length > 1 ? ['--framework', tfms[0]] : []
    const filter = SUITE === 'unit' ? 'Category!=Integration' : 'Category=Integration'
    const rc = spawnStep(
      'dotnet',
      ['test', slns[0], '-c', 'Release', ...framework, '--filter', filter, '--collect:XPlat Code Coverage', '--settings', settings,
        '--results-directory', results, '--logger', `trx;LogFileName=${basename(trx)}`],
      cwd,
    )
    const after = shas()
    // 첨부는 결과 디렉터리 바로 아래(실행마다 GUID)의 coverage.json 하나다 — trx 의 `In/<기계>/` 사본은 한 층 더 깊다.
    const att = existsSync(results)
      ? readdirSync(results, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => join(results, e.name, 'coverage.json')).filter((p) => existsSync(p))
      : []
    if (att.length > 1) return stop(`the run left ${att.length} coverage attachments — this reader knows one test project per solution`)
    if (att.length === 1) {
      copyFileSync(att[0], data)
      if (existsSync(join(results, basename(trx)))) copyFileSync(join(results, basename(trx)), trx)
      const sha = (p) => (existsSync(p) ? createHash('sha1').update(readFileSync(p)).digest('hex') : null)
      const same = recorded.every((f) => before[f] !== null && before[f] === after[f])
      const facts = { data_sha1: sha(data), trx_sha1: sha(trx), files: same ? before : null }
      writeFileSync(DOTNET_RUN(), `${JSON.stringify(SUITE === 'unit' ? { run: 'dotnet', suite: 'unit', exit: rc, ...facts } : { run: 'dotnet', exit: rc, ...facts })}\n`)
    }
    return rc
  }
  const common = commonDir(d.files)
  if (l === 'node') {
    const vitest = join(cwd, 'node_modules', 'vitest', 'vitest.mjs')
    if (!existsSync(vitest)) {
      fail(l, `${d.dir}/node_modules/vitest is missing — install the lane's dependencies first (npm ci)`)
      emitFindings(l)
      return 2
    }
    if (!common.startsWith(`${d.dir}/`)) {
      fail(l, `the derived files share no directory under ${d.dir}/ — cannot choose a coverage include`)
      emitFindings(l)
      return 2
    }
    // 옛 데이터(단위는 그 기록도)를 먼저 지운다(일찍 멈춘 run 뒤에 지난 실행의 것이 남지 않게). 단위 미도달 장부(`unit node`)의 이름은 `.unit` 이
    // 붙는다(SUITE).
    const dir = dirname(NODE_DATA())
    rmSync(dir, { recursive: true, force: true })
    // include 는 경계 파일들의 공통 디렉터리 전부다 — v8 은 include 에 맞는 파일을 한 번도 import 안 됐어도 0% 로 싣는다
    // (실측: 20 파일 전부). 이름으로 좁히지 않는다(python 의 `source` 와 같은 이유).
    const include = `--coverage.include=${common.slice(d.dir.length + 1)}/**/*.ts`
    if (SUITE !== 'unit') {
      return spawnStep(
        process.execPath,
        [vitest, 'run', '--config', 'vitest.integration.config.ts', '--coverage.enabled', '--coverage.provider=v8',
          include, '--coverage.reporter=json', `--coverage.reportsDirectory=${dir}`],
        cwd,
      )
    }
    // 단위 미도달 장부 — 레인의 단위 명령(`npm test` = `vitest run --coverage`, 기본 설정 vitest.config.ts — 그 include 가 test/unit 뿐이다)을
    // 같은 v8 · 같은 include 로 돈다. 설정의 coverage 값 중 셋을 CLI 로 덮는다(CLI 의 배열 · 값이 설정의 것을 대신한다 — 실측 vitest 5.1.0): exclude
    // (경계 자신 — NODE_EXCLUDE_NOTHING) · 하한(경계를 넣은 합계는 레인의 하한에 걸려 exit 1 이 된다 — 그 게이트는 이 장부의 것이 아니다) ·
    // autoUpdate(하한을 설정 파일에 다시 쓰지 않게). reportOnFailure 로 실패한 실행도 JSON 을 내고 그 종료코드를 기록에 싣는다(python 과 같다 —
    // 실패한 실행은 리더가 FAIL 로 낸다). 경계 파일의 바이트는 실행 앞뒤에 재서 같을 때만 기록에 싣는다.
    rmSync(NODE_RUN(), { force: true })
    const shas = () => Object.fromEntries(d.files.map((f) => [f, existsSync(join(root, f)) ? createHash('sha1').update(readFileSync(join(root, f))).digest('hex') : null]))
    const before = shas()
    const rc = spawnStep(
      process.execPath,
      [vitest, 'run', '--coverage.enabled', '--coverage.provider=v8', include, `--coverage.exclude=${NODE_EXCLUDE_NOTHING}`,
        ...['lines', 'functions', 'branches', 'statements'].map((k) => `--coverage.thresholds.${k}=0`), '--coverage.thresholds.autoUpdate=false',
        '--coverage.reportOnFailure', '--coverage.reporter=json', `--coverage.reportsDirectory=${dir}`],
      cwd,
    )
    const after = shas()
    if (existsSync(NODE_DATA())) {
      const same = d.files.every((f) => before[f] !== null && before[f] === after[f])
      const sha = createHash('sha1').update(readFileSync(NODE_DATA())).digest('hex')
      let cov = null
      try {
        cov = JSON.parse(readFileSync(join(cwd, 'node_modules', '@vitest', 'coverage-v8', 'package.json'), 'utf8')).version ?? null
      } catch {
        cov = null
      }
      writeFileSync(NODE_RUN(), `${JSON.stringify({ run: 'node', suite: 'unit', exit: rc, coverage_v8: cov, data_sha1: sha, files: same ? before : null })}\n`)
    }
    return rc
  }
  if (!common.startsWith(`${d.dir}/`)) {
    fail(l, `the derived files share no directory under ${d.dir}/ — cannot choose a coverage source`)
    emitFindings(l)
    return 2
  }
  // import 루트 = 공통 디렉터리에서 위로 올라가 처음 만나는 「__init__.py 없는」 디렉터리. 측정할 것이 이 트리이고
  // 설치된 다른 사본이 아니도록 PYTHONPATH 맨 앞에 둔다(다른 워크트리의 editable 설치가 이기지 못하게).
  let imp = common
  while (imp.includes('/') && existsSync(join(root, imp, '__init__.py'))) imp = imp.slice(0, imp.lastIndexOf('/'))
  const rel = (p) => p.slice(d.dir.length + 1)
  // `KCSDK_PY` 의 관례는 python/ 기준 상대 경로다(.claude/rules/python.md) — 경로면 거기서 풀고, 명령 이름이면 PATH 에 맡긴다.
  const envPy = process.env.KCSDK_PY
  const py = envPy
    ? /[\\/]/.test(envPy)
      ? resolve(cwd, envPy)
      : envPy
    : ['.venv/Scripts/python.exe', '.venv/bin/python'].map((p) => join(cwd, p)).find((p) => existsSync(p)) || 'python'
  // 생성 설정 · JSON · 데이터 — 단위 미도달 장부(`unit python`)는 `.unit` 이 붙은 이름이고(SUITE) 같은 설정에 `branch = true` 를 더한다(omit 은
  // 어느 쪽에도 없다 — 경계가 측정 대상이다). 옛 JSON · 데이터(단위는 그 기록도)를 먼저 지운다(일찍 멈춘 run 뒤에 지난 실행의 것이 남지 않게).
  const rc = join(out, `python${TAG}.coveragerc`)
  const json = PY_DATA()
  const data = join(out, `python${TAG}.coverage`)
  for (const f of [json, data]) rmSync(f, { force: true })
  writeFileSync(rc, `[run]\nsource = ${rel(common)}\ndata_file = ${data}\n${SUITE === 'unit' ? 'branch = true\n' : ''}`)
  const sep = process.platform === 'win32' ? ';' : ':'
  // 절대 경로 — 상대 항목은 cwd 가 다른 하위 프로세스에서 다른 곳을 가리킨다.
  const env = { ...process.env, PYTHONPATH: [join(root, imp), process.env.PYTHONPATH].filter(Boolean).join(sep) }
  if (SUITE !== 'unit') {
    const t = spawnStep(py, ['-m', 'coverage', 'run', `--rcfile=${rc}`, '-m', 'pytest', '-m', 'integration'], cwd, env)
    if (t !== 0) return t
    const j = spawnStep(py, ['-m', 'coverage', 'json', `--rcfile=${rc}`, '-o', json], cwd, env)
    return j === 0 ? 0 : 2
  }
  // 단위 미도달 장부 — 레인의 단위 명령(`pytest -m "not integration"`)을 같은 설정 밑에서 돈다. 스위트가 실패해도 JSON 을 내고 그 종료코드를
  // 기록에 싣는다(go 와 같다 — 실패한 실행은 리더가 FAIL 로 낸다). 경계 파일의 바이트는 실행 앞과 JSON 뒤(coverage json 이 그 소스를 다시
  // 읽는다)에 재서 같을 때만 기록에 싣는다. 통합 run 은 기록을 쓰지 않는다 — 단위 실행의 기록만 `suite` 를 갖는다.
  rmSync(PY_RUN(), { force: true })
  const shas = () => Object.fromEntries(d.files.map((f) => [f, existsSync(join(root, f)) ? createHash('sha1').update(readFileSync(join(root, f))).digest('hex') : null]))
  const before = shas()
  const t = spawnStep(py, ['-m', 'coverage', 'run', `--rcfile=${rc}`, '-m', 'pytest', '-m', 'not integration'], cwd, env)
  const j = existsSync(data) ? spawnStep(py, ['-m', 'coverage', 'json', `--rcfile=${rc}`, '-o', json], cwd, env) : 2
  const after = shas()
  if (j === 0 && existsSync(json)) {
    const same = d.files.every((f) => before[f] !== null && before[f] === after[f])
    const sha = createHash('sha1').update(readFileSync(json)).digest('hex')
    writeFileSync(PY_RUN(), `${JSON.stringify({ run: 'python', suite: 'unit', exit: t, data_sha1: sha, files: same ? before : null })}\n`)
  }
  return t !== 0 ? t : j === 0 ? 0 : 2
}

// 레인은 report 의 종료코드를 그대로 받는다 — 그것을 해석하던 레인 사본(`[ "$rc" -le 1 ]` — 소유 문제를 경고로 넘겼다)을
// 지웠으니 실패 주석도 여기서 낸다. 무엇을 고칠지는 위에 찍힌 판정 줄이 말한다.
const VERDICTS = { 1: 'DRIFT — ownership problem', 2: 'FAIL — integrity failure', 3: 'BELOW — under the floor', 4: 'UNEXERCISED — an admin surface function never ran' }
const UNIT_VERDICTS = { 1: 'DRIFT — unreached code the ledger does not record as measured', 2: 'FAIL — integrity failure' }
let code
if (cmd === 'check') code = check()
else if (cmd === 'report') {
  code = report(lang)
  if (code && process.env.GITHUB_ACTIONS === 'true') console.log(`::error::integration-coverage [${lang}]: ${VERDICTS[code] ?? `exit ${code}`} — the lines above say what to change`)
} else if (cmd === 'unit' || cmd === 'unit-report') {
  // `unit` 은 단위 스위트를 돌린 뒤 **그 종료코드와 상관없이** 대조한다 — 실패한 실행은 기록의 종료코드 · 시험 결과로 FAIL(2)이 되고,
  // 테스트의 종료코드(1 일 수 있다)가 DRIFT(1)로 읽히지 않는다. run 자신이 멈췄으면(FAIL 을 이미 찍었다) 대조하지 않는다.
  if (cmd === 'unit') run(lang)
  code = fails(lang) ? 2 : unitReport(lang)
  if (code && process.env.GITHUB_ACTIONS === 'true') console.log(`::error::unit-unreached [${lang}]: ${UNIT_VERDICTS[code] ?? `exit ${code}`} — the lines above say what to change`)
} else if (cmd === 'run') code = run(lang)
else {
  code = run(lang)
  if (code === 0) code = report(lang)
}
process.exit(code)
