#!/usr/bin/env node
// integration-coverage.mjs — 통합 실행만의 「네트워크 경계」 커버리지 리포트. go · python(2026-11-02) · node · rust
// (2026-11-05) · php · ruby(2026-11-06) · dotnet · java(2026-11-07)는 **하한 무장**, kotlin(2026-11-07)은 보고 모드다. 새로 붙는
// 언어는 보고 모드에서 시작한다(3 걸음째 — 하한은 CI 관측 셋 뒤).
//
// 왜: 아홉 언어가 「경계는 통합으로 검증한다」며 그 파일을 단위 커버리지 게이트에서 빼는데, 통합 실행에서
// 커버리지를 재는 언어가 0 이었다(등록부 `integration-coverage-never-measured`). 이 스크립트가 그 3 걸음째다 —
// 레인 통합 잡에 리포트를 붙인다. 하한(4 걸음째)은 `integration-coverage.json` 의 `floor` 다(값은 거기에만 둔다) — CI 관측
// 셋 뒤 무장했다. 지표는 go 문장 · python 함수 몸통(lines 는 import 때 도는 줄로 부푼다 — 아래) · node 문장 · rust 줄
// (lcov `DA` — 아래) · php 줄(PHPUnit XML — 아래) · ruby 메서드 몸통(python 과 같은 까닭 — 아래) · dotnet 줄(coverlet
// JSON — 아래) · java 몸통(정적 초기화만 가진 줄을 뺀 JaCoCo 줄 — 아래). 값은 관측값을 소수 한 자리로 내린 것이라 여유가 없다 — 여유는 다음 변경이 무심사로 채운다(문서 예산
// 검사 8e 와 같은 이유). 내리려면 그 JSON 의 diff 가 판정이다. 하한이 없는 언어는 보고 모드 그대로다(**낮은 수치는
// 실패가 아니다**).
//
// 등록부가 붙인 세 조건:
//  · 리포트할 파일 집합은 단위 omit SSOT 에서 **파생**한다 — 측정 트리의 `scripts/coverage-boundary.mjs list --json`.
//    목록 사본을 측정에 쓰지 않는다.
//  · 그 집합을 **고정**한다 — `scripts/integration-coverage.json` 의 `pinned` 와 다르면 FAIL. 파생이 너무 적게 고르면
//    %가 오른다(등록부 실측: coverlet `<Include>` 를 뒤집자 중첩 async 타입이 빠져 211/312). 핀은 측정 대상이 아니라
//    **오라클**이다 — SSOT 를 바꾸는 PR 이 「리포트의 분모가 바뀐다」를 같은 diff 에서 보이게 한다.
//  · 통합이 한 번도 실행하지 않는 함수 목록 — 항목마다 **열린** 등록부 id 가 소유자다(같은 JSON 의 `owners`).
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
// 없다 — 경계를 `skip` 해 경계 파일이 없고 메서드도 안 싣는다. 그래서 run 이 부트 파일 둘을 `<out>/ruby-boot/` 에 쓴다:
// start.rb 는 bundler/setup **보다 먼저** Coverage 를 켜고(SimpleCov 1.2.0 은 `Coverage.running?` 이면 제 start 를 건너뛴다 —
// `simplecov.rb:120`), dump.rb 는 `rspec --require` 로 실려 스위트가 끝난 뒤(SimpleCov 의 at_exit 가 `Coverage.result` 로
// 측정을 멈추기 전) 이 트리 lib 의 파일마다 sha1 · 줄 · 메서드와 예제 결과를 쓴다. ⚠️ `bundle exec` 를 거치지 않는다 — 윈도에서
// 새 프로세스를 띄우며 RUBYOPT 맨 앞에 `-rbundler/setup` 을 붙여, gemspec 이 싣는 version.rb 가 측정 전에 실렸다(실측: 그
// 프로세스의 RUBYOPT 순서 · pid). 순서를 명시한다: `ruby -r<start> -rbundler/setup -e 'load Gem.bin_path("rspec-core", "rspec")'`.
// 적재 때 도는 클래스 · def 줄이 lines 를 부풀리므로(python 의 import 와 같다) bodies(메서드 범위 안 줄)를 함께 낸다. 메서드
// 밖 줄은 적재 때 돌았어야 한다 — 0 이면 블록이나 람다의 몸통이라 어느 메서드에도 못 붙인다(FAIL).
//
// 종료코드 — 넷을 가른다. 「낮은 수치」는 하한이 무장된 언어에서만 실패다(3):
//   0 OK     리포트가 섰고, 하한 이상이며, 미실행 함수가 전부 열린 항목 소유다
//   1 DRIFT  소유 문제(소유자 없음 · 열린 항목이 아님 · 낡거나 핀 밖을 가리키는 항목) — 수치는 유효하다. CI 는 경고로만 본다
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
//
// 사용(LANG = go · python · node · rust · php · ruby · dotnet · java · kotlin):
//   node scripts/integration-coverage.mjs <LANG> [--out DIR]                 로컬 — 통합 테스트(Docker) 후 리포트
//   node scripts/integration-coverage.mjs run    <LANG> [ROOT] [--out DIR]   CI 테스트 스텝 — 종료코드는 테스트의 것
//   node scripts/integration-coverage.mjs report <LANG> [ROOT] [--out DIR]   CI 리포트 스텝(하한이 있으면 게이트)
//   node scripts/integration-coverage.mjs check  [ROOT]                      파생 ↔ 핀 ↔ 소유자(데이터·Docker 불필요)
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
import { readFileSync, existsSync, writeFileSync, mkdirSync, rmSync, readdirSync, copyFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { join, dirname, resolve, posix, basename } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'

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

// ── CLI ──────────────────────────────────────────────────────────────────────────────────
function usage(msg) {
  if (msg) console.error(msg)
  console.error(`usage: node scripts/integration-coverage.mjs <${LANGS.join('|')}> [--out DIR]`)
  console.error(`       node scripts/integration-coverage.mjs run|report <${LANGS.join('|')}> [ROOT] [--out DIR]`)
  console.error('       node scripts/integration-coverage.mjs check [ROOT]')
  process.exit(2)
}
const argv = process.argv.slice(2)
let cmd = argv[0]
let rest = argv.slice(1)
if (cmd !== undefined && !['run', 'report', 'check'].includes(cmd) && !cmd.startsWith('-')) {
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
} else usage(cmd ? `unknown command: ${cmd}` : '')
root = resolve(root ?? join(dirname(fileURLToPath(import.meta.url)), '..'))
const rootPosix = root.replace(/\\/g, '/')
out = resolve(out ?? join(tmpdir(), 'kcsdk-integration-coverage', lang ?? ''))

// ── 판정 기록 ─────────────────────────────────────────────────────────────────────────────
const findings = []
const fail = (l, msg) => void findings.push({ kind: 'FAIL', lang: l, msg })
const drift = (l, msg) => void findings.push({ kind: 'DRIFT', lang: l, msg })
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
  return { pinned: e.pinned, owners, floor }
}
const floorText = (pin) => (pin?.floor ? `floor ${pin.floor.metric} ≥ ${pin.floor.percent}%` : null)
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
function goReport(d) {
  const path = join(out, 'go.cover')
  if (!existsSync(path)) {
    fail('go', `no coverage data at ${path.replace(/\\/g, '/')} — run the integration suite first (node scripts/integration-coverage.mjs run go)`)
    return null
  }
  const modFile = join(root, d.dir, 'go.mod')
  const mod = existsSync(modFile) ? readFileSync(modFile, 'utf8').match(/^module\s+(\S+)/m)?.[1] : null
  if (!mod) {
    fail('go', `${d.dir}/go.mod has no module line — profile paths cannot be mapped to files`)
    return null
  }
  const lines = readFileSync(path, 'utf8').replace(/\r\n/g, '\n').split('\n').filter(Boolean)
  if (!/^mode: (set|count|atomic)$/.test(lines[0] ?? '')) {
    fail('go', `${path.replace(/\\/g, '/')} is not a Go cover profile (first line: ${lines[0] ?? 'empty'})`)
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
  }
  return { path, files, never }
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
function pyReport(d) {
  const path = join(out, 'python.json')
  if (!existsSync(path)) {
    fail('python', `no coverage data at ${path.replace(/\\/g, '/')} — run the integration suite first (node scripts/integration-coverage.mjs run python)`)
    return null
  }
  let j
  try {
    j = JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    fail('python', `${path.replace(/\\/g, '/')} is not JSON`)
    return null
  }
  if (j?.meta?.format !== 3 || typeof j.files !== 'object' || j.files === null) {
    fail('python', `${path.replace(/\\/g, '/')} is not a coverage.py JSON report of format 3 (function regions are required)`)
    return null
  }
  const byPath = new Map()
  for (const [k, v] of Object.entries(j.files)) byPath.set(toRepoPath(k, d.dir), v)
  const files = []
  const never = []
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
    for (const [q, r] of Object.entries(v.functions)) {
      sum += r.summary.num_statements
      if (q === '') continue
      bodies.stmts += r.summary.num_statements
      bodies.covered += r.summary.covered_lines
      if (r.summary.num_statements > 0 && r.summary.covered_lines === 0) never.push({ file: f, line: r.start_line, name: q, stmts: r.summary.num_statements })
    }
    if (sum !== lines.stmts) {
      fail('python', `${f}: function regions add up to ${sum} of ${lines.stmts} statements — coverage.py keys regions by name, so a same-named function overwrote another and the never-executed list could miss it`)
      continue
    }
    files.push({ file: f, stmts: lines.stmts, covered: lines.covered, bodies })
  }
  return { path, files, never }
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
function nodeReport(d) {
  const path = join(out, 'node', 'coverage-final.json')
  if (!existsSync(path)) {
    fail('node', `no coverage data at ${path.replace(/\\/g, '/')} — run the integration suite first (node scripts/integration-coverage.mjs run node)`)
    return null
  }
  let j
  try {
    j = JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    fail('node', `${path.replace(/\\/g, '/')} is not JSON`)
    return null
  }
  if (!j || typeof j !== 'object' || Array.isArray(j)) {
    fail('node', `${path.replace(/\\/g, '/')} is not an istanbul coverage map (an object keyed by file)`)
    return null
  }
  const byPath = new Map()
  for (const [k, v] of Object.entries(j)) byPath.set(toRepoPath(k, d.dir), v)
  const files = []
  const never = []
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
      stmts++
      if (c > 0) covered++
      let fn = funcs.find((x) => line >= x.start && line <= x.end) ?? outside
      if (fn !== outside && fn.kind === 'value' && line === fn.start) {
        const body = bodyAt.get(fn.start)
        if (body && (line < body.line || col < body.column)) fn = outside
      }
      fn.stmts++
      if (c > 0) fn.covered++
    }
    files.push({ file: f, stmts, covered, outside })
    for (const fn of funcs) if (fn.stmts > 0 && fn.covered === 0) never.push({ file: f, line: fn.start, name: fn.name, stmts: fn.stmts })
  }
  return { path, files, never }
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
function rustReport(d) {
  const path = join(out, 'rust.lcov')
  const shown = path.replace(/\\/g, '/')
  if (!existsSync(path)) {
    fail('rust', `no coverage data at ${shown} — run the integration suite first (node scripts/integration-coverage.mjs run rust)`)
    return null
  }
  const recs = new Map()
  let cur = null
  for (const l of readFileSync(path, 'utf8').replace(/\r\n/g, '\n').split('\n')) {
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
  }
  return { path, files, never }
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
const PHP_RUN = () => join(out, 'php.run.json')
// 짧은 이름 — `Xzawed\Keycloak\Admin\AdminClient` → `AdminClient`, 함수 `Fixture\…\adminHelper` → `adminHelper`.
const phpShort = (n) => n.slice(n.lastIndexOf('\\') + 1)
// 통합 스위트의 테스트 클래스 — 단위 설정 `<testsuite name="integration">` 의 `<directory>`(suffix · prefix — 기본 `Test.php`)
// 와 `<file>` 로 디스크에서 찾은 파일 이름이다(PSR-4: 클래스 이름 = 파일 이름). 다른 고르기(`<exclude>` 등)는 이 리더가 모르므로
// FAIL 이다 — 무엇이 스위트인지 모르면 데이터가 그 스위트의 것인지 가를 수 없다.
function phpIntegrationClasses(d) {
  const site = `${d.dir}/phpunit.xml`
  if (!existsSync(join(root, site))) {
    fail('php', `${site} is missing — the integration testsuite cannot be read`)
    return null
  }
  // 주석은 같은 길이의 공백으로 덮는다 — 지우면(`''`) 겹친 꼴(`<!<!---->--`)이 한 번 지운 뒤 `<!--` 로 남는다(CodeQL
  // js/incomplete-multi-character-sanitization — 이 PR 의 첫 판이 그 경보를 냈다).
  const x = readFileSync(join(root, site), 'utf8').replace(/<!--[\s\S]*?-->/g, (m) => m.replace(/[^\n]/g, ' '))
  const suites = [...x.matchAll(/<testsuite\s+name="integration"\s*>([\s\S]*?)<\/testsuite>/g)]
  if (suites.length !== 1) {
    fail('php', `${site} must define exactly one <testsuite name="integration"> (found ${suites.length}) — the report checks the data against it`)
    return null
  }
  const body = suites[0][1]
  const known = /<(directory|file)((?:\s+[\w-]+="[^"]*")*)\s*>\s*([^<]+?)\s*<\/\1>/g
  if (body.replace(known, '').trim() !== '') {
    fail('php', `${site}: the integration testsuite selects tests with something other than <directory> and <file> — this reader does not know which tests it runs`)
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
      fail('php', `${site}: the integration testsuite directory ${m[3]} does not exist`)
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
    fail('php', `${site}: the integration testsuite finds no test files — a report over no tests is vacuous`)
    return null
  }
  return classes
}
function phpReport(d) {
  const dir = join(out, 'php')
  const shown = dir.replace(/\\/g, '/')
  const index = join(dir, 'index.xml')
  if (!existsSync(index)) {
    fail('php', `no coverage data at ${shown}/index.xml — run the integration suite first (node scripts/integration-coverage.mjs run php)`)
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
  // exit 1 — CI 의 `[ "$rc" -le 1 ]` 를 지난다). 경계에 닿기 전에 실패한 테스트 · 일부 클래스만 거른 실행은 이 목록으로 못
  // 가른다 — 그것은 끝의 run 기록(종료코드 · index.xml 해시)이 막는다.
  const suite = phpIntegrationClasses(d)
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
    fail('php', `the run included tests outside the integration suite (${foreign.join(' · ')}) — the report would not be integration-only`)
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
    const units = []
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
        units.push(u)
      }
    }
    if (broken) continue
    const dup = units.find((u, i) => units.findIndex((v) => v.name === u.name) !== i)
    if (dup) {
      fail('php', `${f}: two functions are both named ${dup.name} — the owner keys would collide`)
      continue
    }
    const sum = units.reduce((a, u) => ({ exec: a.exec + u.exec, done: a.done + u.done }), { exec: 0, done: 0 })
    if (sum.exec !== exec || sum.done !== done) {
      fail('php', `${f}: its methods and functions account for ${sum.exec} of ${exec} executable lines (${sum.done} of ${done} executed) — lines outside any method cannot be attributed to a function`)
      continue
    }
    files.push({ file: f, stmts: exec, covered: done, outside: { stmts: 0, covered: 0 } })
    for (const u of units) if (u.exec > 0 && u.done === 0) never.push({ file: f, line: u.line, name: u.name, stmts: u.exec })
  }
  // 줄이 돌았는데 그 줄을 돈 테스트가 하나도 안 실렸다 — 위 판정(스위트 · 결과)을 건너뛴 데이터다.
  if (!tests.length && files.some((f) => f.covered > 0)) {
    fail('php', `${shown}/index.xml counts executed lines but lists no tests — the data contradicts itself`)
    return null
  }
  // run 기록 — 이 데이터를 `run php`(거르지 않은 통합 스위트)가 썼고 그 실행이 성공했는가. 손으로 돌린 실행 · 거른 실행 ·
  // 실패한 실행(경계에 닿기 전에 실패한 테스트는 위 목록에 안 실린다)의 데이터는 수치를 내지 않는다. 다른 판정 뒤에 둔다 —
  // 데이터가 스스로 모순이면 그 문구가 먼저다.
  const runRec = PHP_RUN()
  let rec = null
  try {
    rec = JSON.parse(readFileSync(runRec, 'utf8'))
  } catch {
    rec = null
  }
  if (!rec || rec.run !== 'php') {
    fail('php', `no record that \`run php\` wrote this data (${runRec.replace(/\\/g, '/')}) — run the suite through the script (node scripts/integration-coverage.mjs run php) so the report can tell a complete, successful run`)
    return null
  }
  if (rec.exit !== 0) {
    fail('php', `the run that wrote this data exited ${rec.exit} — the data of a failed run is partial (a test that fails before it reaches the boundary is not in the data at all)`)
    return null
  }
  const indexSha = createHash('sha1').update(readFileSync(index)).digest('hex')
  if (rec.index_sha1 !== indexSha) {
    fail('php', `${shown}/index.xml is not the data \`run php\` recorded (sha1 ${String(rec.index_sha1).slice(0, 12)}… recorded, ${indexSha.slice(0, 12)}… now) — another run wrote over it`)
    return null
  }
  const note = `driver ${driver.name ?? '?'} ${driver.version ?? '?'} · php-code-coverage ${build.coverage ?? '?'}`
  return { path: dir, note, files, never }
}

// ── ruby: run 이 쓰는 덤프(Ruby `Coverage` 의 lines · methods + 예제 결과 — 머리 주석) ───────────────
const RUBY_FORMAT = 'kcsdk-ruby-coverage/1'
const RUBY_DATA = () => join(out, 'ruby.json')
const RUBY_RUN = () => join(out, 'ruby.run.json')
// 부트 파일 — run 이 `<out>/ruby-boot/` 에 쓴다(저장소에 두지 않는다 · 픽스처도 이 run 으로 만든다).
const RUBY_START = `# frozen_string_literal: true

# Written by scripts/integration-coverage.mjs \`run ruby\`. Loaded BEFORE bundler/setup, so Coverage sees every lib file
# (the gemspec require_relative's version.rb during bundler setup). No gem may load here: one activated outside the
# bundle would clash with it.
require "coverage"
Coverage.start(lines: true, branches: true, methods: true)
`
const RUBY_DUMP = `# frozen_string_literal: true

# Written by scripts/integration-coverage.mjs \`run ruby\`. Loaded by \`rspec --require\`: after the suite, before
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
      files[abs] = { "sha1" => Digest::SHA1.file(abs).hexdigest, "lines" => cov[:lines], "methods" => methods }
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
    fail('ruby', `no coverage data at ${shown} — run the integration suite first (node scripts/integration-coverage.mjs run ruby)`)
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
    fail('ruby', `${shown} is not the dump \`run ruby\` writes (format ${RUBY_FORMAT})`)
    return null
  }
  if (toRepoPath(j.root, d.dir) !== d.dir) {
    fail('ruby', `the dump's root ${j.root.replace(/\\/g, '/')} is not ${d.dir}/ of this tree — the data belongs to another checkout`)
    return null
  }
  // 예제 — 통합 스위트(`spec/integration` 의 `:integration`)만, 전부 통과. 덤프는 스위트가 끝난 뒤 쓰이므로 실패한 예제도 실린다.
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
  const foreign = ex.filter((e) => e.integration !== true || !posix.normalize(e.file.replace(/\\/g, '/')).startsWith('spec/integration/'))
  if (foreign.length) {
    const eg = sortU(foreign.map((e) => e.id)).slice(0, 3).join(' · ')
    fail('ruby', `the run included examples outside the integration suite (${eg}) — the report would not be integration-only`)
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
    files.push({ file: f, stmts: lines.stmts, covered: lines.covered, bodies })
    ms.forEach((m, k) => {
      if (m.count === 0) never.push({ file: f, line: m.sl, name: m.name, stmts: per[k].stmts, label: per[k].stmts ? undefined : 'empty body' })
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
  if (!rec || rec.run !== 'ruby') {
    fail('ruby', `no record that \`run ruby\` wrote this data (${runRec.replace(/\\/g, '/')}) — run the suite through the script (node scripts/integration-coverage.mjs run ruby) so the report can tell a complete, successful run`)
    return null
  }
  if (rec.exit !== 0) {
    fail('ruby', `the run that wrote this data exited ${rec.exit} — the data of a failed run is partial`)
    return null
  }
  const dumpSha = createHash('sha1').update(bytes).digest('hex')
  if (rec.dump_sha1 !== dumpSha) {
    fail('ruby', `${shown} is not the data \`run ruby\` recorded (sha1 ${String(rec.dump_sha1).slice(0, 12)}… recorded, ${dumpSha.slice(0, 12)}… now) — another run wrote over it`)
    return null
  }
  return { path, note: `ruby ${typeof j.ruby === 'string' ? j.ruby : '?'} · Coverage lines · methods`, files, never }
}

// ── dotnet — coverlet 컬렉터의 고유 JSON ──────────────────────────────────────────────────
const DOTNET_DATA = () => join(out, 'dotnet.json')
const DOTNET_TRX = () => join(out, 'dotnet.trx')
const DOTNET_RUN = () => join(out, 'dotnet.run.json')
// run 이 쓰는 컬렉터 설정 — 형식만 json 이고 **거르지 않는다**(경계는 리포트가 파일 경로로 고른다). 단위 설정의 `<Exclude>` 를
// 뒤집은 `<Include>` 는 컴파일러가 만든 중첩 타입(async 상태 기계 · 람다 클래스)을 떨어뜨린다 — 실측(2026-11-06, 실제 트리):
// 경계 10 파일의 428 줄 중 바깥 타입의 것은 175 뿐이다(등록부가 짚은 211/312 와 같은 꼴).
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
function dotnetReport(d) {
  const path = DOTNET_DATA()
  const shown = path.replace(/\\/g, '/')
  if (!existsSync(path)) {
    fail('dotnet', `no coverage data at ${shown} — run the integration suite first (node scripts/integration-coverage.mjs run dotnet)`)
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
  // trx — 이 실행의 테스트 결과. 통합 스위트만 · 전부 통과.
  const trxPath = DOTNET_TRX()
  const trxShown = trxPath.replace(/\\/g, '/')
  let trx = null
  try {
    trx = readFileSync(trxPath, 'utf8')
  } catch {
    trx = null
  }
  let note = 'coverlet json'
  if (trx === null) fail('dotnet', `no test results at ${trxShown} — run the integration suite through the script (node scripts/integration-coverage.mjs run dotnet)`)
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
    const foreign = results.filter((r) => !suite.has(classOf.get(r.id)))
    if (foreign.length) {
      const eg = sortU(foreign.map((r) => r.name ?? '?')).slice(0, 3).join(' · ')
      fail('dotnet', `the run included tests outside the integration suite (${eg}) — the report would not be integration-only (the suite = classes whose declaration carries [Trait("Category", "Integration")])`)
    }
    const rt = /\(64-bit \.NET ([\d.]+)\)/.exec(trx)?.[1]
    note = `.NET ${rt ?? '?'} · coverlet json · ${results.length} test${results.length === 1 ? '' : 's'}`
  }
  const files = []
  const never = []
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
        const fo = dotnetFold(cls, sig)
        if (!fo) {
          fail('dotnet', `${f}: cannot name ${cls}::${sig.replace(/^.*?::/, '')} — not a generated name this reader knows`)
          broken = true
          break
        }
        const key = `${fo.type}.${fo.member}`
        const m = methods.get(key) ?? { plain: new Map(), machines: new Set(), lambdas: 0, lines: new Map() }
        if (fo.kind === 'sm') m.machines.add(fo.machine)
        else if (fo.kind === 'lambda') m.lambdas++
        // 시그니처마다 따로 든다 — 오버로드면 그것으로 가른다(아래).
        const own = fo.kind === 'plain' ? (m.plain.get(fo.params) ?? new Map()) : null
        for (const [k, c] of Object.entries(lines)) {
          const ln = Number(k)
          if (ln > nlines) {
            fail('dotnet', `${f}: ${key} counts line ${ln}, past the ${nlines} lines of the file — the data contradicts the tree`)
            broken = true
            break
          }
          m.lines.set(ln, (m.lines.get(ln) ?? 0) + c)
          if (own) own.set(ln, (own.get(ln) ?? 0) + c)
        }
        if (broken) break
        if (own) m.plain.set(fo.params, own)
        methods.set(key, m)
      }
      if (broken) break
    }
    if (broken) continue
    // 오버로드 — 몸통(시그니처 · 상태 기계)이 둘 이상이면 갈라야 한다. 상태 기계나 람다가 붙으면 어느 오버로드의 것인지 모른다.
    const per = new Map()
    let amb = null
    for (const [key, m] of methods) {
      if (m.plain.size + m.machines.size <= 1) per.set(key, m.lines)
      else if (m.machines.size || m.lambdas) amb ??= key
      else for (const [p, ls] of m.plain) per.set(`${key}(${p})`, ls)
    }
    if (amb) {
      fail('dotnet', `${f}: ${amb} has overloads and a state machine or lambda folds into one of them — this reader cannot tell which`)
      continue
    }
    const fileLines = new Map()
    for (const [key, ls] of per) {
      for (const [ln, c] of ls) fileLines.set(ln, (fileLines.get(ln) ?? 0) + c)
      if (ls.size && [...ls.values()].every((c) => c === 0)) never.push({ file: f, line: Math.min(...ls.keys()), name: key, stmts: ls.size })
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
  if (!rec || rec.run !== 'dotnet') {
    fail('dotnet', `no record that \`run dotnet\` wrote this data (${runRec.replace(/\\/g, '/')}) — run the suite through the script (node scripts/integration-coverage.mjs run dotnet) so the report can tell a complete, successful run`)
    return null
  }
  if (rec.exit !== 0) {
    fail('dotnet', `the run that wrote this data exited ${rec.exit} — the data of a failed run is partial`)
    return null
  }
  if (rec.data_sha1 !== sha(bytes)) {
    fail('dotnet', `${shown} is not the data \`run dotnet\` recorded (sha1 ${String(rec.data_sha1).slice(0, 12)}… recorded, ${sha(bytes).slice(0, 12)}… now) — another run wrote over it`)
    return null
  }
  if (trx !== null && rec.trx_sha1 !== sha(readFileSync(trxPath))) {
    fail('dotnet', `${trxShown} is not the test result \`run dotnet\` recorded — another run wrote over it`)
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
  return { path, note, files, never }
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
// 「아무것도 안 돈 실행」 판정과 bodies 는 그 줄을 뺀다(python · ruby 와 같은 까닭 — 등록부의 함정: JVM static init).
// ⚠️ kotlin 도 이 리더다 — 클래스 파일 · JaCoCo 는 같고 접기만 다르다(ktFold — 합성 메서드는 이름이 아니라 코드로 접는다:
// 람다는 만드는 메서드, 다리는 부르는 대상, 로컬 함수는 부르는 메서드). `internal` 멤버는 모듈 이름 접미를 벗긴다(`name$<모듈>` —
// 모듈 이름의 식별자 밖 글자는 `_` · 실측 `applyTimeouts$io_github_xzawed_keycloak_sdk_kotlin`). suspend 함수의 이어받기
// 클래스(`AuthClient$authSend$1`)는 줄표가 없어 JaCoCo 가 빈 클래스로 싣는다(실측 — 사실과 데이터 둘 다에 있다).
// run kotlin 의 Gradle 초기화 스크립트 — 빌드 파일을 안 바꾸고 `integrationTest` 에만 JaCoCo 에이전트를 붙인다(Kover 는 그 태스크를
// 일부러 계측하지 않는다 — build.gradle.kts 의 disabledForTestTasks). 에이전트와 CLI 는 Gradle 이 그 빌드의 저장소에서 받는다(kotlin
// 레인은 Maven 을 안 쓴다). kotlin 의 `$` 보간이 JS 에 안 먹히게 문자열 배열로 쓴다.
const KOTLIN_INIT = [
  '// integration-coverage.mjs (run kotlin) — attaches a JaCoCo agent to integrationTest only; the build files stay as they are.',
  'allprojects {',
  '    val ver = findProperty("kcsdkItcovJacoco") as String? ?: return@allprojects',
  '    val agent = configurations.detachedConfiguration(dependencies.create("org.jacoco:org.jacoco.agent:$ver:runtime"))',
  '    val cli = configurations.detachedConfiguration(dependencies.create("org.jacoco:org.jacoco.cli:$ver:nodeps"))',
  '    tasks.withType<Test>().matching { it.name == "integrationTest" }.configureEach {',
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
const JVM_DATA = (l) => join(out, `${l}.xml`)
const JVM_JAVAP = (l) => join(out, `${l}.javap.txt`)
const JVM_RUN = (l) => join(out, `${l}.run.json`)
const JVM_EXEC = (l) => join(out, `${l}.exec`)
// `javap -l -p -v <클래스 파일…>` 의 출력 → { 내부 이름: { source, enclosing: { class, method, desc } | null, methods: [{ name, desc,
// lines, calls, news, lambdas }] } }. `this_class` 는 상수 풀보다 앞이라 그 주석(내부 이름)을 읽고, EnclosingMethod 는 상수 풀(Class ·
// NameAndType)로 푼다. 코드에서는 부르는 메서드(`invoke*` 의 주석 — `owner.name:desc`) · 만드는 클래스(`new`) · 만드는 람다 몸통
// (`invokedynamic` → BootstrapMethods 의 LambdaMetafactory 구현 핸들)을 읽는다 — kotlin 의 접기가 쓴다(ktFold).
function javapFacts(text) {
  const facts = {}
  let cur = null
  let meth = null
  let inLnt = false
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
    facts[cur.name] = { source: cur.source, enclosing, methods: cur.methods }
  }
  for (const raw of text.split(/\r?\n/)) {
    if (raw.startsWith('Classfile ')) {
      finish()
      cur = { name: null, source: null, encRef: null, pool: new Map(), methods: [], bootstraps: new Map() }
      meth = null
      inLnt = false
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
    // 멤버 머리 — 구역 안의 두 칸 들여쓰기. 메서드는 `(` 가 있고 `;` 로 끝난다(필드는 아니다). 생성자는 점 표기 전체 이름이다.
    if (inBody && /^  \S/.test(raw)) {
      const h = raw.slice(2)
      inLnt = false
      meth = null
      if (h === 'static {};') meth = { name: '<clinit>', desc: '()V', lines: [], calls: [], news: [], indy: [] }
      else {
        const p = h.indexOf('(')
        if (p > 0 && h.endsWith(';')) {
          // 이름에는 `-` 도 든다 — kotlin 의 값 클래스 매개변수 맹글(`f-imocxh4` — 실측, 독립 레그).
          const id = /([\w$.<>-]+)$/.exec(h.slice(0, p))?.[1] ?? ''
          meth = { name: id.includes('.') ? '<init>' : id, desc: null, lines: [], calls: [], news: [], indy: [] }
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
    if (inLnt && (m = /^        line (\d+): \d+\s*$/.exec(raw))) {
      meth.lines.push(Number(m[1]))
      continue
    }
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
    }
  }
  return facts
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
//   기본 인자 다리(`…$default`) · 기본 인자 생성자(`<init>(…, int, DefaultConstructorMarker)`) → 그것이 부르는 같은 이름의 하나(없거나 둘이면 다리 서술자에서 표지를 뗀 서술자의 것)
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
    if (ups.every((u) => key(u) === key(ups[0]))) return ups[0]
    if (ups.every((u) => u.kind === 'plain' && u.member === '<init>' && u.type === ups[0].type && !u.shared)) {
      return { type: ups[0].type, member: '<init>', kind: 'plain', desc: null, shared: sortU(ups.map((u) => u.desc)) }
    }
    return null
  }
  const nest = (up, via) => (up === KT_CYCLE ? up : up && { type: up.type, member: up.member, kind: up.kind === 'static' ? 'static' : 'lambda', desc: up.desc, shared: up.shared, via })
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
  // 부르는 대상이 없거나 둘이면(인라인 함수의 다리는 몸통을 품어 대상을 안 부른다 · 기본값이 같은 이름의 오버로드 · 다른 생성자를
  // 부른다 — 독립 레그 4 실측) 다리 서술자에서 표지(int 마스크 하나 · 끝의 Object 또는 DefaultConstructorMarker)를 뗀 서술자의 같은
  // 이름 메서드가 같은 클래스에 하나 있을 때만 그것이다. 다리의 첫 매개변수가 이 클래스면 받는 쪽일 수 있다 — 떼고 찾은 것은
  // 인스턴스여야, 안 떼고 찾은 것은 정적이어야 한다(object 의 `@JvmStatic pick(o: Self?, n: Int = 0)` 은 첫 매개변수가 그 object 다).
  const derived = (to, marker, recv) => {
    const m = new RegExp(`^\\((.*)I${marker}\\)(.+)$`).exec(desc)
    if (!m) return null
    const me = `L${cname};`
    const want = [[`(${m[1]})${m[2]}`, true]]
    if (recv && m[1].startsWith(me)) want.push([`(${m[1].slice(me.length)})${m[2]}`, false])
    const hit = want.flatMap(([d, st]) => c.methods.filter((x) => x.name === to && x.desc === d && (!recv || Boolean(x.static) === st)))
    return hit.length === 1 ? [null, cname, to, hit[0].desc] : null
  }
  // 다리의 접기 — 대상이 자기에게 돌아오면(로컬 함수의 다리) 다리를 부르는 쪽으로 접는다.
  const bridge = (r) => {
    if (!r) return null
    const t = fold(r[1], r[2], r[3])
    return nest(t === KT_CYCLE ? one(callers()) : t, 'default')
  }
  if (name === '<init>') {
    if (!desc.endsWith('ILkotlin/jvm/internal/DefaultConstructorMarker;)V')) return { type, member: '<init>', kind: 'plain', desc }
    return bridge(callee(cname, '<init>') ?? derived('<init>', 'Lkotlin/jvm/internal/DefaultConstructorMarker;', false))
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
  // `Iface$DefaultImpls.g$default` 는 인터페이스의 같은 이름 다리를 부른다(호환 다리 — 실측) — 그 다리를 따라간다.
  if (dm) {
    const r = callee(cname, dm[1]) ?? (cname.endsWith('$DefaultImpls') ? callee(cname.slice(0, -'$DefaultImpls'.length), name) : null)
    return bridge(r ?? derived(dm[1], 'Ljava/lang/Object;', true))
  }
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
    fail(l, `no record that \`run ${l}\` wrote this data (${runRec.replace(/\\/g, '/')}) — run the suite through the script (node scripts/integration-coverage.mjs run ${l}) so the report can tell a passing run from a failed one`)
  if (!existsSync(path)) {
    fail(l, `no coverage data at ${shown} — run the integration suite first (node scripts/integration-coverage.mjs run ${l})`)
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
      meth = { name: t.attrs.name, desc: t.attrs.desc, line: t.attrs.line, missed: 0, covered: 0 }
      cls.methods.push(meth)
      if (t.empty) meth = null
    } else if (t.name === 'counter' && meth && t.attrs.type === 'LINE') {
      meth.missed = xmlCount(t.attrs.missed)
      meth.covered = xmlCount(t.attrs.covered)
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
    fail(l, `no class facts at ${javapShown} — run ${l} writes javap's output there (line tables · enclosing methods of nested classes)`)
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
    if (!isObj(rec0) || rec0.run !== l) {
      noRecord()
      return null
    }
    if (typeof rec0.module !== 'string' || !/^[\w.-]+$/.test(rec0.module)) {
      fail(l, `no Kotlin module name in ${runRec.replace(/\\/g, '/')} — run kotlin records it from build/classes/kotlin/main/META-INF/*.kotlin_module (internal members carry it as a name suffix)`)
      return null
    }
    kt = { mangle: rec0.module.replace(/[^A-Za-z0-9_]/g, '_') }
  }
  const files = []
  const never = []
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
      fail(l, `${f}: the class facts and the data name different classes (${[...onlyXml.map((n) => `data only: ${n}`), ...onlyFacts.map((n) => `facts only: ${n}`)].join(' · ')}) — run ${l} writes both from one build`)
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
        if (!fx || !isCount(x.missed) || !isCount(x.covered) || !firstOk) {
          fail(l, `${f}: ${c.name}.${x.name}${x.desc} — the data and the class facts disagree (first line ${x.line ?? 'none'} vs ${fx?.lines[0] ?? 'no method'}) — run ${l} writes both from one build`)
          broken = true
          break
        }
        const fo = kt ? ktFold(c.name, x.name, x.desc, facts, kt) : javaFold(c.name, x.name, x.desc, facts)
        if (!fo || fo === KT_CYCLE) {
          fail(l, `${f}: cannot name ${c.name}.${x.name}${x.desc} — ${kt ? 'the class files show no single method that creates, calls or encloses it' : 'not a generated name this reader knows'}`)
          broken = true
          break
        }
        parts.push({ ...fo, cls: c.name, name: x.name, lines: fx.lines, ends: fx.ends, covered: x.covered })
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
      const ls = new Set(ps.flatMap((p) => p.lines).filter((n) => lines.has(String(n))))
      const own = ps.filter((p) => !p.shared)
      if (ls.size && own.length && own.every((p) => p.covered === 0)) never.push({ file: f, line: Math.min(...ls), name: key, stmts: ls.size })
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
  if (!rec || rec.run !== l) {
    noRecord()
    return null
  }
  if (rec.exit !== 0) {
    fail(l, `the run that wrote this data exited ${rec.exit} — the data of a failed run is partial`)
    return null
  }
  if (rec.data_sha1 !== sha(bytes)) {
    fail(l, `${shown} is not the data \`run ${l}\` recorded (sha1 ${String(rec.data_sha1).slice(0, 12)}… recorded, ${sha(bytes).slice(0, 12)}… now) — another run wrote over it`)
    return null
  }
  if (rec.javap_sha1 !== sha(javapBytes)) {
    fail(l, `${javapShown} is not the javap output \`run ${l}\` recorded — another run wrote over it`)
    return null
  }
  const t = rec.tests
  if (!isObj(t) || !isCount(t.completed) || !isCount(t.failures) || !isCount(t.errors) || !isCount(rec.unit)) {
    fail(l, `the record has no test counts — run ${l} reads them from ${l === 'kotlin' ? 'the JUnit XML of integrationTest and test' : 'failsafe-summary.xml and the surefire reports'}`)
    return null
  }
  if (t.completed === 0) fail(l, 'the run recorded no integration tests — a report over no tests is vacuous')
  if (t.failures + t.errors) fail(l, `${t.failures + t.errors} of ${t.completed} integration tests failed — the data of a failed run is partial`)
  if (rec.unit) fail(l, `the run included ${rec.unit} unit test report${rec.unit > 1 ? 's' : ''} — the report would not be integration-only (${l === 'kotlin' ? 'run runs integrationTest only' : 'run skips surefire: -Dtest=NONE'})`)
  if (!isObj(rec.files)) {
    fail(l, 'the record has no boundary hashes — the boundary files changed while the suite ran, so the data may come from other bytes')
    return null
  }
  for (const f of d.files) {
    const now = existsSync(join(root, f)) ? sha(readFileSync(join(root, f))) : null
    if (rec.files[f] !== now) fail(l, `${f}: the data was taken from other bytes (sha1 ${String(rec.files[f]).slice(0, 12)}… recorded, ${String(now).slice(0, 12)}… in the tree) — rerun the suite on this tree`)
  }
  const note = `JaCoCo ${typeof rec.jacoco === 'string' ? rec.jacoco : '?'} · ${sessions.length} session${sessions.length === 1 ? '' : 's'} · ${t.completed} integration test${t.completed === 1 ? '' : 's'}`
  return { path, note, files, never }
}

// ── report ───────────────────────────────────────────────────────────────────────────────
function emitFindings(l) {
  for (const f of findings) if (f.lang === l || f.lang === null) console.log(`${f.kind} [${f.lang ?? '-'}] ${f.msg}`)
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
    // 아무 경계 문장도 안 돈 실행은 「낮은 수치」가 아니라 측정 실패다(테스트가 경계를 한 줄도 안 지나고 통과할 수 없다).
    // ⚠️ python 은 **함수 몸통**으로 판정한다 — import 만으로 모듈·클래스 수준 줄이 덮인다. conftest 가 패키지를 import
    // 하므로 통합 테스트가 전부 skip 돼 pytest 가 exit 0 으로 끝나도 lines 는 0 이 아니다(실측: 실제 트리 import 만으로
    // 160/395 = 40.5% · 몸통 0/235). lines 로 판정하면 그 실행이 「40.5%」로 보고된다. ruby 도 같다(require 가 클래스 · def 줄을 돈다).
    const ran = BODY_LANGS.has(l)
      ? data.files.reduce((a, f) => ({ stmts: a.stmts + f.bodies.stmts, covered: a.covered + f.bodies.covered }), { stmts: 0, covered: 0 })
      : tot
    if (ran.covered === 0) {
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
      const why = BODY_LANGS.has(l) && tot.covered ? `${load} alone credits ${tot.covered} ${level} lines` : 'did the integration tests run against this tree?'
      fail(l, `the run executed 0 of ${ran.stmts} ${scope} — a measurement failure, not a low number (${why})`)
    } else {
      const neverKeys = new Set()
      for (const x of data.never) {
        const key = `${x.file}:${x.name}`
        neverKeys.add(key)
        x.owner = pin.owners[key] ?? 'NONE'
        if (!pin.owners[key]) drift(l, `unowned never-executed function ${key} — name an open item of ${REGISTRY} for it in ${PINS}`)
        else if (reg && !reg.open.has(x.owner)) drift(l, `${key} is owned by ${x.owner}, which is not an open item of ${REGISTRY}`)
      }
      for (const key of Object.keys(pin.owners)) if (!neverKeys.has(key)) drift(l, `stale owner ${key} — the integration run executes it now (or it no longer exists); drop the entry`)
      printReport(l, d, data, tot, pin)
    }
  }
  emitFindings(l)
  const nf = findings.filter((f) => f.kind === 'FAIL' && (f.lang === l || f.lang === null)).length
  const nd = findings.filter((f) => f.kind === 'DRIFT' && f.lang === l).length
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
  const owned = n && !nd ? ', all owned by open registry items' : ''
  const problems = nd ? ` · ${nd} ownership problem${nd > 1 ? 's' : ''}` : ''
  const fl = floorText(pin) ? ` · ${floorText(pin)}` : ''
  // 하한 — 분모가 0 이면 위 「아무것도 안 돈 실행」이 이미 FAIL 이다. 정수식으로 비교한다(같으면 통과).
  const m = pin.floor && { statements: t, lines: t, bodies: b }[pin.floor.metric]
  if (m && m.covered * 100 < pin.floor.percent * m.stmts) {
    console.log(`integration-coverage [${l}]: BELOW — ${head}${fl} · ${fns}${owned}${problems}`)
    return 3
  }
  if (nd) {
    console.log(`integration-coverage [${l}]: DRIFT — ${head}${fl} · ${fns}${problems} (ownership is a warning, not a gate)`)
    return 1
  }
  console.log(`integration-coverage [${l}]: OK — ${head}${fl} · ${fns}${owned}`)
  return 0
}
function printReport(l, d, data, tot, pin) {
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
}

// ── check — 데이터 없이: 파생 ↔ 핀 ↔ 소유자 ───────────────────────────────────────────────
function check() {
  const reg = loadRegistry()
  const p = loadPins()
  const counts = []
  let owners = 0
  for (const l of LANGS) {
    const d = derivedFor(l)
    const pin = p ? pinFor(l) : null
    if (d && pin && matchesPin(l, d, pin)) console.log(`[${l}] pin OK — ${d.files.length} files equal the derivation from ${d.site} (${d.label})`)
    if (!pin) continue
    counts.push(`${l} ${pin.pinned.length}`)
    const P = new Set(pin.pinned)
    for (const [key, id] of Object.entries(pin.owners)) {
      owners++
      const at = key.indexOf(':')
      if (at < 0 || !P.has(key.slice(0, at))) drift(l, `owner entry ${key} names a file outside the pin`)
      if (reg && !reg.open.has(id)) drift(l, `${key} is owned by ${id}, which is not an open item of ${REGISTRY}`)
    }
    console.log(`[${l}] owners: ${Object.keys(pin.owners).length} entries (${sortU(Object.values(pin.owners)).join(' · ') || 'none'})`)
    console.log(`[${l}] ${floorText(pin)?.replace(/^floor /, 'floor: ') ?? 'floor: none (report mode)'}`)
  }
  for (const f of findings) console.log(`${f.kind} [${f.lang ?? '-'}] ${f.msg}`)
  const nf = findings.filter((f) => f.kind === 'FAIL').length
  const nd = findings.length - nf
  if (nf || nd) {
    console.log(`integration-coverage check: ${nf ? 'FAIL' : 'DRIFT'} — ${nf} fail · ${nd} drift`)
    return nf ? 2 : 1
  }
  console.log(`integration-coverage check: OK — ${counts.join(' · ')} files pinned · ${owners} owner entries, all open`)
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
    const prof = join(out, 'go.cover')
    rmSync(prof, { force: true })
    return spawnStep('go', ['test', '-tags=integration', '-run', 'TestE2E', '-count=1', `-coverprofile=${prof}`, './...'], cwd)
  }
  if (l === 'rust') {
    const lcov = join(out, 'rust.lcov')
    rmSync(lcov, { force: true })
    // 통합 대상 하나만 — 라이브러리가 cfg(test) 없이 링크된다(단위 테스트가 같은 빌드에서 돌면 리포트가 FAIL 한다).
    // `--locked` 는 레인의 다른 빌드와 같은 이유다(커밋된 Cargo.lock 그대로).
    return spawnStep('cargo', ['llvm-cov', '--locked', '--test', 'integration_test', '--lcov', '--output-path', lcov, '--', '--ignored'], cwd)
  }
  if (l === 'php') {
    // 단위 설정의 `<source>` 만 경계 파일로 바꾼 사본을 **그 옆에** 만든다 — bootstrap · 테스트 디렉터리 · cacheDirectory 의
    // 상대 경로가 같은 디렉터리를 기준으로 그대로 풀린다(테스트 스위트 정의를 옮겨 적지 않는다). `--coverage-filter` 로는 못
    // 한다 — include 를 더할 뿐이라 `<exclude>` 의 경계 파일이 그대로 빠진다(PHPUnit 12 Merger.php). 실행 뒤 지운다.
    const cfg = join(cwd, 'phpunit.xml')
    const phpunit = join(cwd, 'vendor', 'bin', 'phpunit')
    // 옛 데이터와 그 기록은 **먼저** 지운다 — 아래에서 일찍 멈추면 지난 성공한 실행의 데이터 · 기록이 남아, 다음 report 가 낡은
    // 수치를 OK 로 냈다(독립 레그 3차 실측: vendor/bin/phpunit 을 치운 run → rc 2 · 옛 기록 그대로 → report OK 141/235).
    const xdir = join(out, 'php')
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
    const gen = join(cwd, '.integration-coverage.phpunit.xml')
    writeFileSync(gen, xml.slice(0, at) + source + xml.slice(at + blocks[0][0].length))
    let rc
    try {
      // 같은 `--testsuite integration` 이다(레인의 명령). Xdebug 는 `XDEBUG_MODE=coverage` 없이는 아무것도 안 잰다 — pcov 는 무시한다.
      rc = spawnStep('php', [phpunit, '--configuration', gen, '--testsuite', 'integration', '--coverage-xml', xdir], cwd, {
        ...process.env,
        XDEBUG_MODE: 'coverage',
      })
    } finally {
      rmSync(gen, { force: true })
    }
    // 이 실행의 기록 — report 가 데이터를 이 실행에 묶는다(종료코드 · 그 index.xml 의 sha1). PHPUnit 은 실패한 실행에도 XML 을
    // 쓰고, 경계에 닿기 전에 실패한 테스트(`setUpBeforeClass` 가 던진 클래스 전체)는 데이터의 <tests> 에 아예 안 실린다 — 독립
    // 레그 2차 실측: 그런 실행을 따로 report 하면 77/235 · exit 1 로 지나갔다.
    const index = join(xdir, 'index.xml')
    if (existsSync(index)) {
      const sha = createHash('sha1').update(readFileSync(index)).digest('hex')
      writeFileSync(PHP_RUN(), `${JSON.stringify({ run: 'php', exit: rc, index_sha1: sha })}\n`)
    }
    return rc
  }
  if (l === 'ruby') {
    // 옛 데이터 · 기록 · 부트 파일을 먼저 지운다(php 와 같은 이유 — 일찍 멈춘 run 뒤에 지난 실행의 것이 남지 않게).
    const data = RUBY_DATA()
    const boot = join(out, 'ruby-boot')
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
    // 레인의 명령(`RUN_INTEGRATION=1 bundle exec rspec spec/integration --tag integration`)과 같은 스펙 · 태그 · 환경이다 —
    // `bundle exec` 대신 순서를 명시한다(머리 주석: start → bundler/setup → 번들의 rspec).
    const rc = spawnStep(
      'ruby',
      [`-r${start}`, '-rbundler/setup', '-e', 'load Gem.bin_path("rspec-core", "rspec")', '--', '--require', dump, 'spec/integration', '--tag', 'integration'],
      cwd,
      { ...process.env, RUN_INTEGRATION: '1', KCSDK_ITCOV_OUT: data, KCSDK_ITCOV_ROOT: cwd },
    )
    if (existsSync(data)) {
      const sha = createHash('sha1').update(readFileSync(data)).digest('hex')
      writeFileSync(RUBY_RUN(), `${JSON.stringify({ run: 'ruby', exit: rc, dump_sha1: sha })}\n`)
    }
    return rc
  }
  if (l === 'java') {
    // 옛 데이터 · exec · javap 출력 · 기록 · CLI 를 먼저 지운다(php 와 같은 이유 — 일찍 멈춘 run 뒤에 지난 실행의 것이 남지 않게).
    const data = JVM_DATA(l)
    const exec = JVM_EXEC(l)
    const javap = JVM_JAVAP(l)
    const cli = join(out, 'java-cli')
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
    const shas = () => Object.fromEntries(d.files.map((f) => [f, existsSync(join(root, f)) ? createHash('sha1').update(readFileSync(join(root, f))).digest('hex') : null]))
    const before = shas()
    // 레인의 명령(`mvn -B -f java/pom.xml verify`)과 같은 리액터 · 골이다. 더하는 것: `clean`(지난 실행의 클래스 · 테스트 보고가 남지
    // 않게) · 단위 테스트 끄기(`-Dtest=NONE` — surefire 와 failsafe 가 같은 에이전트 인자를 써 단위와 IT 가 한 exec 에 합쳐진다 — 실측) ·
    // exec 를 <out> 으로(`-Djacoco.destFile` — 모듈의 report · check 는 그 모듈에 데이터가 없어 건너뛴다).
    const rc = spawnMaven(['-B', '-f', 'pom.xml', 'clean', 'verify', '-Dtest=NONE', '-Dsurefire.failIfNoSpecifiedTests=false', `-Djacoco.destFile=${exec}`], cwd)
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
    // 테스트 — failsafe 의 요약(모듈마다)을 합치고, surefire 의 보고가 없는지 센다(단위 테스트는 돌지 않았어야 한다).
    const tests = { completed: 0, failures: 0, errors: 0, skipped: 0 }
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
    const sha = (p) => createHash('sha1').update(readFileSync(p)).digest('hex')
    const same = d.files.every((f) => before[f] !== null && before[f] === after[f])
    writeFileSync(JVM_RUN(l), `${JSON.stringify({ run: 'java', exit: rc, jacoco: ver, data_sha1: sha(data), javap_sha1: sha(javap), exec_sha1: sha(exec), tests, unit, files: same ? before : null })}\n`)
    return rc
  }
  if (l === 'kotlin') {
    // 옛 데이터 · exec · javap 출력 · 기록 · CLI · 초기화 스크립트를 먼저 지운다(java 와 같은 이유).
    const data = JVM_DATA(l)
    const exec = JVM_EXEC(l)
    const javap = JVM_JAVAP(l)
    const cli = join(out, 'kotlin-cli')
    const init = join(out, 'kotlin.itcov.init.gradle.kts')
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
    const shas = () => Object.fromEntries(d.files.map((f) => [f, existsSync(join(root, f)) ? createHash('sha1').update(readFileSync(join(root, f))).digest('hex') : null]))
    const before = shas()
    // 레인의 명령(`./gradlew integrationTest`)과 같은 태스크다. 더하는 것: `clean`(지난 실행의 클래스 · 테스트 결과가 남지 않게 —
    // 단위 결과가 남으면 「단위가 섞였다」로 못 가른다) · 초기화 스크립트 · CLI 받기.
    const rc = spawnGradle(['-I', init, `-PkcsdkItcovJacoco=${ver}`, `-PkcsdkItcovExec=${exec}`, `-PkcsdkItcovCli=${cli}`, 'clean', 'integrationTest', 'kcsdkItcovCli'], cwd)
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
    // 테스트 — integrationTest 의 JUnit XML 을 합치고, 단위(test)의 결과가 없는지 센다(clean 뒤라 이 실행이 쓴 것만 있다).
    const tests = { completed: 0, failures: 0, errors: 0, skipped: 0 }
    const itDir = join(cwd, 'build', 'test-results', 'integrationTest')
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
    const unitDir = join(cwd, 'build', 'test-results', 'test')
    const unit = existsSync(unitDir) ? readdirSync(unitDir).filter((x) => /^TEST-.*\.xml$/.test(x)).length : 0
    const sha = (p) => createHash('sha1').update(readFileSync(p)).digest('hex')
    const same = d.files.every((f) => before[f] !== null && before[f] === after[f])
    writeFileSync(JVM_RUN(l), `${JSON.stringify({ run: 'kotlin', exit: rc, jacoco: ver, module, data_sha1: sha(data), javap_sha1: sha(javap), exec_sha1: sha(exec), tests, unit, files: same ? before : null })}\n`)
    return rc
  }
  if (l === 'dotnet') {
    // 옛 데이터 · trx · 기록 · 결과 디렉터리를 먼저 지운다(php 와 같은 이유 — 일찍 멈춘 run 뒤에 지난 실행의 것이 남지 않게).
    const data = DOTNET_DATA()
    const trx = DOTNET_TRX()
    const results = join(out, 'dotnet-results')
    const settings = join(out, 'dotnet.runsettings')
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
    const shas = () => Object.fromEntries(d.files.map((f) => [f, existsSync(join(root, f)) ? createHash('sha1').update(readFileSync(join(root, f))).digest('hex') : null]))
    const before = shas()
    // 레인의 명령(`dotnet test dotnet/Keycloak.Sdk.sln -c Release --filter "Category=Integration"`)과 같은 해 · 구성 · 필터다.
    const rc = spawnStep(
      'dotnet',
      ['test', slns[0], '-c', 'Release', '--filter', 'Category=Integration', '--collect:XPlat Code Coverage', '--settings', settings,
        '--results-directory', results, '--logger', 'trx;LogFileName=dotnet.trx'],
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
      if (existsSync(join(results, 'dotnet.trx'))) copyFileSync(join(results, 'dotnet.trx'), trx)
      const sha = (p) => (existsSync(p) ? createHash('sha1').update(readFileSync(p)).digest('hex') : null)
      const same = d.files.every((f) => before[f] !== null && before[f] === after[f])
      writeFileSync(DOTNET_RUN(), `${JSON.stringify({ run: 'dotnet', exit: rc, data_sha1: sha(data), trx_sha1: sha(trx), files: same ? before : null })}\n`)
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
    const dir = join(out, 'node')
    rmSync(dir, { recursive: true, force: true })
    // include 는 경계 파일들의 공통 디렉터리 전부다 — v8 은 include 에 맞는 파일을 한 번도 import 안 됐어도 0% 로 싣는다
    // (실측: 20 파일 전부). 이름으로 좁히지 않는다(python 의 `source` 와 같은 이유).
    return spawnStep(
      process.execPath,
      [vitest, 'run', '--config', 'vitest.integration.config.ts', '--coverage.enabled', '--coverage.provider=v8',
        `--coverage.include=${common.slice(d.dir.length + 1)}/**/*.ts`, '--coverage.reporter=json', `--coverage.reportsDirectory=${dir}`],
      cwd,
    )
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
  const rc = join(out, 'python.coveragerc')
  const json = join(out, 'python.json')
  for (const f of [json, join(out, 'python.coverage')]) rmSync(f, { force: true })
  writeFileSync(rc, `[run]\nsource = ${rel(common)}\ndata_file = ${join(out, 'python.coverage')}\n`)
  const sep = process.platform === 'win32' ? ';' : ':'
  // 절대 경로 — 상대 항목은 cwd 가 다른 하위 프로세스에서 다른 곳을 가리킨다.
  const env = { ...process.env, PYTHONPATH: [join(root, imp), process.env.PYTHONPATH].filter(Boolean).join(sep) }
  const t = spawnStep(py, ['-m', 'coverage', 'run', `--rcfile=${rc}`, '-m', 'pytest', '-m', 'integration'], cwd, env)
  if (t !== 0) return t
  const j = spawnStep(py, ['-m', 'coverage', 'json', `--rcfile=${rc}`, '-o', json], cwd, env)
  return j === 0 ? 0 : 2
}

let code
if (cmd === 'check') code = check()
else if (cmd === 'report') code = report(lang)
else if (cmd === 'run') code = run(lang)
else {
  code = run(lang)
  if (code === 0) code = report(lang)
}
process.exit(code)
