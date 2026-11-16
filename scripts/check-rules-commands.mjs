#!/usr/bin/env node
// check-rules-commands.mjs — `.claude/rules/*.md` 의 펜스 블록이 부르는 대상이 매니페스트에 실재하는가(등록부
// rules-command-reference-existence-guard). 명령을 실행하지 않는다 — 참조만 대조한다(툴체인이 필요 없다).
//
// 왜: rules 파일은 에이전트가 그 언어 경로에서 자동으로 싣고 그대로 치는 명령이다. 그 명령이 가리키는 것(npm 스크립트 ·
// Gradle 태스크 · `-m` 모듈 · Maven 모듈 · cargo 시험 대상 · bundle 실행 파일 …)이 매니페스트에서 사라지거나 이름이
// 바뀌면 명령은 조용히 죽고, 에이전트는 그 실패를 제 환경 탓으로 돌린다. #423 이 사람 눈으로 잡은 python 의
// `"$PY" -m build`(build 는 [dev] 에 없었다)가 그 부류다 — 그 트리(4af51563^)에서 이 검사는 그것 하나를 낸다.
//
// ⚠️ required 밖에서 돈다(repo-hygiene 의 비-required 잡 `rules-commands`). 아홉 문법을 읽는 파서의 오탐 하나가
// required 안이면 모든 PR 이 멈춘다(PRIMARY 는 bypass_actors: [] — 등록부의 보류 사유). 자가테스트는 픽스처로
// doc-facts 에서 돈다(`scripts/test/test-check-rules-commands.sh`).
//
// 읽는 것: 펜스(```) 안의 줄. 줄 끝 `\` 는 다음 줄과 잇고, 따옴표 밖 `#` 뒤 주석은 벗기며, `&&` · `||` · `;` 로
// 단순 명령을 가른다. 앞의 `NAME=값` 은 환경 대입이다. 작업 디렉터리 — 줄이 `cd <dir>` 로 시작하면 그 cd 는 루트
// 기준이다(node 처럼 줄마다 루트에서 치는 꼴). 줄 안의 cd 는 그 블록에서 `cd` 로 시작하지 않는 다음 줄들에도 남는다
// (셸이 그렇다 — kotlin 의 `cd kotlin` 한 줄 · dotnet 커버리지 블록의 `cd dotnet && …` 뒤 `node ../scripts/…`).
// 대조하는 참조 — 그 밖의 꼴의 명령은 UNCHECKED 로 찍고 **실패**다(손 표가 조용히 좁아지지 않게 — 오늘 트리는 0):
//   cd <dir>                       → 디렉터리
//   npm ci · npm <그 밖>           → <cwd>/package-lock.json · package.json(manifest)
//   cargo · bundle install · composer · 경로 없는 dotnet → <cwd> 의 Cargo.toml · Gemfile · composer.json · .sln/.csproj
//   node <스크립트>.mjs            → 그 파일
//   npm test · npm run <s>         → <cwd>/package.json 의 scripts
//   ./gradlew <task…>              → <cwd>/build.gradle.kts 가 등록한 태스크 · jvm-test-suite 스위트 · 적용한 플러그인이
//                                    주는 태스크(GRADLE_PLUGINS — 플러그인이 빠지면 그 태스크도 없다)
//   "$PY" -m <mod>                 → <cwd>/pyproject.toml [project.optional-dependencies] 의 배포가 주는 모듈 · 표준
//                                    라이브러리(PY_STDLIB) · 같은 줄에서 먼저 `-m pip install <dist>` 한 것
//   mvn -f <pom> · -pl <m,…>       → 파일 · 그 pom 의 <modules>
//   cargo test --test <t>          → <cwd>/tests/<t>.rs · Cargo.toml 의 [[test]] name
//   bundle exec <exe> [<path>…]    → Gemfile · gemspec 의 gem 이 그 실행 파일을 준다(GEM_EXES) · 경로 인자
//   vendor/bin/<bin>               → composer.json 의 패키지(COMPOSER_BINS) · `--testsuite <s>` → phpunit.xml
//   go -C <dir> … [-run <TestX>]   → <dir>/go.mod · 그 시험 함수
//   gofmt -l <dir> · dotnet <…sln|…csproj> · gem build <gemspec> → 경로
//
// 사용: node scripts/check-rules-commands.mjs [ROOT] [--list]
//   exit 0 참조 전부 있음 · 1 없는 참조 또는 읽지 못한 명령 · 2 입력 문제(rules 디렉터리 · 펜스 줄이 없다 — 대조할 것이
//   0 이면 초록이 아니다). 못 보는 것: 참조가 있는 명령의 **인자 값**(플래그 · 필터 · 마커) — 실재가 아니라 의미라 범위 밖이다.
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { join, resolve, dirname, posix } from 'node:path'
import { fileURLToPath } from 'node:url'

export const RULES_DIR = '.claude/rules'
// 플러그인 → 그것이 주는 태스크. 손 표다 — rules 가 이 밖의 태스크를 부르면 MISSING 으로 드러난다(그때 표를 넓힌다).
export const GRADLE_PLUGINS = {
  java: ['build', 'assemble', 'check', 'clean', 'classes', 'test', 'jar', 'javadoc'],
  'java-library': ['build', 'assemble', 'check', 'clean', 'classes', 'test', 'jar', 'javadoc'],
  'kotlin(jvm)': ['build', 'assemble', 'check', 'clean', 'classes', 'test', 'jar'],
  'org.jetbrains.kotlinx.kover': ['koverVerify', 'koverHtmlReport', 'koverXmlReport', 'koverBinaryReport', 'koverLog'],
  'org.jlleitschuh.gradle.ktlint': ['ktlintCheck', 'ktlintFormat'],
  'com.vanniktech.maven.publish': ['publish', 'publishToMavenLocal', 'publishToMavenCentral', 'publishAndReleaseToMavenCentral'],
  'maven-publish': ['publish', 'publishToMavenLocal'],
  'org.jetbrains.dokka': ['dokkaGenerate', 'dokkaGenerateHtml'],
}
const GRADLE_BUILTIN = ['help', 'tasks', 'dependencies', 'properties', 'projects', 'wrapper', 'buildEnvironment']
// venv 에 늘 있는 모듈과 표준 라이브러리 중 `-m` 으로 부르는 것.
export const PY_STDLIB = ['pip', 'venv', 'ensurepip', 'json.tool', 'http.server', 'unittest', 'pydoc', 'timeit', 'cProfile', 'compileall', 'zipfile']
// 실행 파일 → 그것을 주는 gem.
export const GEM_EXES = { rspec: 'rspec', rubocop: 'rubocop', 'bundler-audit': 'bundler-audit', rake: 'rake' }
// vendor/bin 의 이름 → 그것을 주는 composer 패키지.
export const COMPOSER_BINS = { phpunit: 'phpunit/phpunit', phpstan: 'phpstan/phpstan', 'php-cs-fixer': 'friendsofphp/php-cs-fixer' }

// ── 셸 꼴 읽기 ─────────────────────────────────────────────────────────────────────────────────────
// 따옴표 밖 `#`(단어 머리)부터 끝까지를 벗긴다.
export function stripComment(s) {
  let q = null
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (q) {
      if (c === '\\' && q !== "'") i++
      else if (c === q) q = null
    } else if (c === '\\') i++
    else if (c === '"' || c === "'" || c === '`') q = c
    else if (c === '#' && (i === 0 || /\s/.test(s[i - 1]))) return s.slice(0, i)
  }
  return s
}
// 따옴표 밖 `&&` · `||` · `;` 로 단순 명령들을 가른다.
export function splitCommands(s) {
  const out = []
  let q = null
  let cur = ''
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (q) {
      if (c === '\\' && q !== "'") {
        cur += c + (s[i + 1] ?? '')
        i++
        continue
      }
      if (c === q) q = null
      cur += c
    } else if (c === '"' || c === "'" || c === '`') {
      q = c
      cur += c
    } else if ((c === '&' && s[i + 1] === '&') || (c === '|' && s[i + 1] === '|')) {
      out.push(cur)
      cur = ''
      i++
    } else if (c === ';') {
      out.push(cur)
      cur = ''
    } else cur += c
  }
  out.push(cur)
  return out.map((x) => x.trim()).filter(Boolean)
}
// 단어로 — 따옴표를 벗긴다(`"$PY"` → `$PY`). 따옴표 안의 공백은 단어를 가르지 않는다.
export function words(s) {
  const out = []
  let cur = null
  let q = null
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (q) {
      if (c === '\\' && q === '"' && i + 1 < s.length) {
        cur += s[++i]
      } else if (c === q) q = null
      else cur += c
    } else if (c === '"' || c === "'") {
      q = c
      cur ??= ''
    } else if (/\s/.test(c)) {
      if (cur !== null) out.push(cur)
      cur = null
    } else if (c === '\\' && i + 1 < s.length) {
      cur = (cur ?? '') + s[++i]
    } else cur = (cur ?? '') + c
  }
  if (cur !== null) out.push(cur)
  return out
}
// 펜스 안의 줄 — { file, line, text }. 줄 끝 `\` 이음을 합친다(첫 줄의 번호를 쓴다).
export function fencedLines(file, text) {
  const out = []
  let inFence = false
  let pending = null
  let block = 0
  text.split(/\r?\n/).forEach((raw, idx) => {
    if (/^\s*```/.test(raw)) {
      inFence = !inFence
      if (inFence) block++
      pending = null
      return
    }
    if (!inFence) return
    const body = stripComment(raw).replace(/\s+$/, '')
    if (pending) {
      pending.text += ' ' + body.replace(/\\$/, '').trim()
      if (!body.endsWith('\\')) {
        out.push(pending)
        pending = null
      }
      return
    }
    if (!body.trim()) return
    if (body.endsWith('\\')) pending = { file, block, line: idx + 1, text: body.replace(/\\$/, '').trim() }
    else out.push({ file, block, line: idx + 1, text: body.trim() })
  })
  if (pending) out.push(pending)
  return out
}

// ── 매니페스트 읽기 ───────────────────────────────────────────────────────────────────────────────
const readIf = (p) => (existsSync(p) && statSync(p).isFile() ? readFileSync(p, 'utf8') : null)
const isDir = (p) => existsSync(p) && statSync(p).isDirectory()

export function gradleTasks(kts) {
  const tasks = new Set(GRADLE_BUILTIN)
  const plugins = []
  const block = kts.match(/^plugins\s*\{([\s\S]*?)^\}/m)?.[1] ?? ''
  for (const l of block.split(/\r?\n/).map((x) => x.replace(/\/\/.*$/, '').trim()).filter(Boolean)) {
    let m
    if ((m = l.match(/^kotlin\("([^"]+)"\)/))) plugins.push(`kotlin(${m[1]})`)
    else if ((m = l.match(/^id\("([^"]+)"\)/))) plugins.push(m[1])
    else if ((m = l.match(/^`([^`]+)`/))) plugins.push(m[1])
    else if ((m = l.match(/^([A-Za-z][\w-]*)$/))) plugins.push(m[1])
  }
  for (const p of plugins) for (const t of GRADLE_PLUGINS[p] ?? []) tasks.add(t)
  // jvm-test-suite 스위트 · 직접 등록한 태스크.
  for (const m of kts.matchAll(/\bval\s+(\w+)\s+by\s+(?:tasks\.)?registering\b/g)) tasks.add(m[1])
  for (const m of kts.matchAll(/\bregister(?:<[^>]+>)?\(\s*"([\w-]+)"/g)) tasks.add(m[1])
  return { tasks, plugins }
}
// [project.optional-dependencies] 의 배포 이름(정규화) — 모듈 이름은 `-` → `_`.
export function pyDevModules(toml) {
  const mods = new Set()
  // 절은 다음 `[` 머리나 파일 끝까지다. 주석 줄을 벗긴 뒤 따옴표 안의 배포 이름을 모은다(한 줄 배열도 읽는다).
  const sec = toml.match(/^\[project\.optional-dependencies\]\s*$([\s\S]*?)(?=^\[|(?![\s\S]))/m)?.[1] ?? ''
  const body = sec.split(/\r?\n/).map((l) => l.replace(/#.*$/, '')).join('\n')
  for (const m of body.matchAll(/"([A-Za-z0-9][A-Za-z0-9._-]*)/g)) mods.add(m[1].toLowerCase().replace(/[-.]/g, '_'))
  return mods
}
const pyMod = (dist) => dist.replace(/\[.*$/, '').replace(/[<>=!~;].*$/, '').trim().toLowerCase().replace(/[-.]/g, '_')
// 파이썬 인터프리터로 읽는 머리 — `$PY` · `${PY}` · `${KCSDK_PY:-.venv/Scripts/python.exe}`(기본값 펼침 — 옛 python.md
// 의 꼴이다) · `python` · `python3.12` · `…/python.exe` · `py`. 앞 판은 앞의 셋째를 못 읽어 rules 역사 220 줄을 거짓으로
// 「읽지 못한 명령」이라 했다(되살릴 조건 실측).
export const isPython = (h) => /^\$\{?[A-Z_]*PY\}?$/.test(h) || /^\$\{[A-Z_]*PY:-[^}]+\}$/.test(h) || /(^|[\\/])python[0-9.]*(\.exe)?$/i.test(h) || h === 'py'

// ── 판정 ──────────────────────────────────────────────────────────────────────────────────────────
export function check(root) {
  const dir = join(root, RULES_DIR)
  if (!isDir(dir)) return { problems: [`${RULES_DIR} is missing under ${root}`] }
  const files = readdirSync(dir).filter((f) => f.endsWith('.md')).sort()
  const lines = files.flatMap((f) => fencedLines(posix.join(RULES_DIR, f), readFileSync(join(dir, f), 'utf8')))
  if (!lines.length) return { problems: [`no fenced command lines in ${RULES_DIR}/*.md — nothing was checked`] }
  const missing = []
  const checked = {}
  const unchecked = []
  let persisted = { key: null, cwd: '' }
  for (const { file, block, line, text } of lines) {
    // 블록마다 새 셸이다 — 앞 블록의 cd 는 남지 않는다.
    if (persisted.key !== `${file}#${block}`) persisted = { key: `${file}#${block}`, cwd: '' }
    const at = `${file}:${line}`
    const cmds = splitCommands(text)
    let cwd = /^cd\s/.test(cmds[0] ?? '') ? '' : persisted.cwd
    let moved = false
    const installed = new Set()
    const ok = (kind) => (checked[kind] = (checked[kind] ?? 0) + 1)
    const miss = (kind, why) => {
      ok(kind)
      missing.push(`MISSING ${at} ${kind} — ${why}`)
    }
    const rel = (p) => posix.normalize(posix.join(cwd, p))
    for (const cmd of cmds) {
      let w = words(cmd)
      while (w.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(w[0])) w = w.slice(1)
      if (!w.length || w[0] === 'export') continue
      const [head, ...args] = w
      if (head === 'cd') {
        const d = rel(args[0] ?? '')
        cwd = d
        moved = true
        if (isDir(join(root, d))) ok('cd')
        else {
          // `cd X && …` — cd 가 실패하면 셸은 그 뒤를 돌리지 않는다. 나머지를 따로 대지 않는다(같은 원인이다).
          miss('cd', `${d} is not a directory`)
          break
        }
      } else if (head === 'npm') {
        const sub = args[0]
        const script = sub === 'test' || sub === 't' ? 'test' : sub === 'run' || sub === 'run-script' ? args[1] : null
        if (!script) {
          // `npm ci` 는 잠금 파일을, 나머지 하위 명령은 package.json 을 읽는다.
          const need = sub === 'ci' ? 'package-lock.json' : 'package.json'
          if (existsSync(join(root, cwd, need))) ok('manifest')
          else miss('manifest', `npm ${sub ?? ''} needs ${rel(need)}`)
          continue
        }
        const pj = readIf(join(root, cwd, 'package.json'))
        if (!pj) miss('npm', `${rel('package.json')} is missing`)
        else if (!Object.hasOwn(JSON.parse(pj).scripts ?? {}, script)) miss('npm', `${rel('package.json')} has no script "${script}"`)
        else ok('npm')
      } else if (/(^|\/)gradlew(\.bat)?$/.test(head)) {
        const kts = readIf(join(root, cwd, 'build.gradle.kts'))
        if (!kts) {
          miss('gradle', `${rel('build.gradle.kts')} is missing`)
          continue
        }
        const { tasks } = gradleTasks(kts)
        for (const t of args.filter((a) => !a.startsWith('-'))) {
          if (tasks.has(t)) ok('gradle')
          else miss('gradle', `task ${t}: not registered in ${rel('build.gradle.kts')}, not a jvm-test-suite, and no applied plugin gives it`)
        }
      } else if (isPython(head)) {
        const m = args.indexOf('-m')
        if (m < 0) {
          unchecked.push({ at, cmd: `${head} ${args[0] ?? ''}`.trim() })
          continue
        }
        const mod = args[m + 1]
        const toml = readIf(join(root, cwd, 'pyproject.toml'))
        const dev = toml ? pyDevModules(toml) : new Set()
        const top = (mod ?? '').split('.')[0].toLowerCase().replace(/-/g, '_')
        if (PY_STDLIB.includes(mod) || dev.has(top) || installed.has(top)) ok('python -m')
        else miss('python -m', `module ${mod}: not in ${rel('pyproject.toml')} [project.optional-dependencies], not stdlib, not installed earlier on the line`)
        if (mod === 'pip' && args[m + 2] === 'install') for (const d of args.slice(m + 3).filter((a) => !a.startsWith('-'))) installed.add(pyMod(d))
      } else if (head === 'mvn') {
        const f = args.indexOf('-f')
        const pomRel = f >= 0 ? rel(args[f + 1] ?? '') : rel('pom.xml')
        const pom = readIf(join(root, pomRel))
        if (!pom) {
          miss('mvn', `${pomRel} is missing`)
          continue
        }
        ok('mvn')
        const pl = args.indexOf('-pl')
        if (pl >= 0) {
          const mods = new Set([...pom.matchAll(/<module>([^<]+)<\/module>/g)].map((x) => x[1].trim()))
          for (const m of (args[pl + 1] ?? '').split(',').map((x) => x.replace(/^:/, ''))) {
            if (mods.has(m)) ok('mvn -pl')
            else miss('mvn -pl', `module ${m} is not in ${pomRel} <modules>`)
          }
        }
      } else if (head === 'cargo') {
        const t = args.indexOf('--test')
        if (!existsSync(join(root, cwd, 'Cargo.toml'))) {
          miss('manifest', `cargo ${args[0] ?? ''} needs ${rel('Cargo.toml')}`)
          continue
        }
        if (args[0] !== 'test' || t < 0) {
          ok('manifest')
          continue
        }
        const name = args[t + 1]
        const toml = readIf(join(root, cwd, 'Cargo.toml')) ?? ''
        const declared = [...toml.matchAll(/^\[\[test\]\][^[]*?^name\s*=\s*"([^"]+)"/gm)].map((x) => x[1])
        if (existsSync(join(root, cwd, 'tests', `${name}.rs`)) || declared.includes(name)) ok('cargo --test')
        else miss('cargo --test', `${rel(`tests/${name}.rs`)} is missing and ${rel('Cargo.toml')} declares no [[test]] ${name}`)
      } else if (head === 'bundle') {
        if (args[0] !== 'exec') {
          if (existsSync(join(root, cwd, 'Gemfile'))) ok('manifest')
          else miss('manifest', `bundle ${args[0] ?? ''} needs ${rel('Gemfile')}`)
          continue
        }
        const exe = args[1]
        const gem = GEM_EXES[exe]
        const deps = `${readIf(join(root, cwd, 'Gemfile')) ?? ''}\n${readdirSafe(join(root, cwd)).filter((x) => x.endsWith('.gemspec')).map((x) => readFileSync(join(root, cwd, x), 'utf8')).join('\n')}`
        if (!gem) miss('bundle exec', `executable ${exe}: no gem is known to provide it (GEM_EXES)`)
        else if (!new RegExp(`(^|\\n)\\s*(gem|spec\\.add_(development_)?dependency)\\s*\\(?\\s*["']${esc(gem)}["']`).test(deps)) miss('bundle exec', `gem ${gem} (for ${exe}) is not in ${rel('Gemfile')} or a gemspec`)
        else ok('bundle exec')
        for (const p of args.slice(2).filter((a) => a.includes('/') && !a.startsWith('-'))) {
          if (existsSync(join(root, cwd, p))) ok('path')
          else miss('path', `${rel(p)} does not exist`)
        }
      } else if (/^vendor\/bin\//.test(head)) {
        const bin = head.slice('vendor/bin/'.length)
        const pkg = COMPOSER_BINS[bin]
        const cj = readIf(join(root, cwd, 'composer.json'))
        const deps = cj ? { ...(JSON.parse(cj).require ?? {}), ...(JSON.parse(cj)['require-dev'] ?? {}) } : {}
        if (!pkg) miss('vendor/bin', `${bin}: no composer package is known to provide it (COMPOSER_BINS)`)
        else if (!cj) miss('vendor/bin', `${rel('composer.json')} is missing`)
        else if (!Object.hasOwn(deps, pkg)) miss('vendor/bin', `${pkg} (for ${bin}) is not in ${rel('composer.json')}`)
        else ok('vendor/bin')
        const s = args.indexOf('--testsuite')
        if (s >= 0) {
          const xml = readIf(join(root, cwd, 'phpunit.xml')) ?? readIf(join(root, cwd, 'phpunit.xml.dist')) ?? ''
          if (new RegExp(`<testsuite\\s+name="${esc(args[s + 1] ?? '')}"`).test(xml)) ok('phpunit --testsuite')
          else miss('phpunit --testsuite', `${rel('phpunit.xml')} has no <testsuite name="${args[s + 1]}">`)
        }
      } else if (head === 'go') {
        const c = args.indexOf('-C')
        const d = c >= 0 ? rel(args[c + 1] ?? '') : cwd
        if (!existsSync(join(root, d, 'go.mod'))) {
          miss('go -C', `${posix.join(d, 'go.mod')} is missing`)
          continue
        }
        ok('go -C')
        const r = args.indexOf('-run')
        const fn = r >= 0 ? args[r + 1] : null
        if (fn && /^Test\w+$/.test(fn)) {
          const has = walk(join(root, d)).some((p) => p.endsWith('_test.go') && new RegExp(`^func ${fn}\\(`, 'm').test(readFileSync(p, 'utf8')))
          if (has) ok('go -run')
          else miss('go -run', `no func ${fn}( in a _test.go under ${d}`)
        }
      } else if (head === 'composer') {
        if (existsSync(join(root, cwd, 'composer.json'))) ok('manifest')
        else miss('manifest', `composer ${args[0] ?? ''} needs ${rel('composer.json')}`)
      } else if (head === 'node' && /\.(mjs|cjs|js)$/.test(args[0] ?? '')) {
        if (existsSync(join(root, cwd, args[0]))) ok('path')
        else miss('path', `${rel(args[0])} does not exist`)
      } else if (head === 'gofmt' || head === 'dotnet' || head === 'gem') {
        const paths =
          head === 'gofmt'
            ? args.filter((a) => !a.startsWith('-'))
            : head === 'gem'
              ? args[0] === 'build'
                ? args.slice(1, 2)
                : []
              : args.filter((a) => /\.(sln|slnx|csproj)$/.test(a))
        if (!paths.length && head === 'dotnet') {
          // 경로 없는 dotnet 하위 명령은 그 디렉터리의 솔루션 · 프로젝트를 쓴다.
          if (readdirSafe(join(root, cwd)).some((x) => /\.(sln|slnx|csproj)$/.test(x))) ok('manifest')
          else miss('manifest', `dotnet ${args[0] ?? ''} needs a .sln or .csproj in ${cwd || '.'}`)
        } else if (!paths.length) unchecked.push({ at, cmd: `${head} ${args[0] ?? ''}`.trim() })
        for (const p of paths) {
          if (existsSync(join(root, cwd, p))) ok('path')
          else miss('path', `${rel(p)} does not exist`)
        }
      } else if (head === 'gradle') {
        // 체크아웃이 주는 것은 래퍼다 — 맨 `gradle` 은 그 PC 의 PATH 에 기대고 판이 핀되지 않는다(kotlin 규칙).
        const p = args.indexOf('-p')
        const wrapper = posix.join(p >= 0 ? rel(args[p + 1] ?? '') : cwd, 'gradlew')
        miss('gradle', existsSync(join(root, wrapper)) ? `bare gradle is not in the checkout — the repository ships ${wrapper} (use ./gradlew)` : `bare gradle is not in the checkout, and ${wrapper} is missing`)
      } else unchecked.push({ at, cmd: head })
    }
    if (moved) persisted.cwd = cwd
  }
  return { files, lines: lines.length, missing, checked, unchecked }
}
function readdirSafe(d) {
  try {
    return readdirSync(d)
  } catch {
    return []
  }
}
function walk(d) {
  const out = []
  for (const e of readdirSafe(d)) {
    if (e === 'vendor' || e === 'node_modules' || e.startsWith('.')) continue
    const p = join(d, e)
    if (isDir(p)) out.push(...walk(p))
    else out.push(p)
  }
  return out
}
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

// ── CLI ───────────────────────────────────────────────────────────────────────────────────────────
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2)
  const list = argv.includes('--list')
  const pos = argv.filter((a) => a !== '--list')
  for (const a of pos) if (a.startsWith('-')) {
    console.error(`unknown option: ${a}\nusage: node scripts/check-rules-commands.mjs [ROOT] [--list]`)
    process.exit(2)
  }
  const root = resolve(pos[0] ?? join(dirname(fileURLToPath(import.meta.url)), '..'))
  const r = check(root)
  if (r.problems) {
    for (const p of r.problems) console.log(`rules-commands: FAIL — ${p}`)
    process.exit(2)
  }
  if (list) for (const f of r.files) console.log(`rules-commands: read ${RULES_DIR}/${f}`)
  for (const m of r.missing) console.log(m)
  // 읽지 못한 꼴의 명령도 실패다 — 「확인하지 않음」이 조용히 쌓이면 손 표가 좁아지는 것을 아무도 모른다(Grok 레그).
  for (const u of r.unchecked) console.log(`UNCHECKED ${u.at} ${u.cmd} — no resolver reads this command; teach scripts/check-rules-commands.mjs its reference or write the line in a shape it reads`)
  const kinds = Object.entries(r.checked).sort(([a], [b]) => a.localeCompare(b)).map(([k, n]) => `${k} ${n}`).join(' · ')
  const total = Object.values(r.checked).reduce((a, b) => a + b, 0)
  const tail = `${r.lines} fenced lines in ${r.files.length} files · ${total} references checked (${kinds}) · ${r.unchecked.length} commands not checked`
  if (r.missing.length || r.unchecked.length) {
    console.log(`rules-commands: FAIL — ${r.missing.length} missing · ${tail}`)
    process.exit(1)
  }
  console.log(`rules-commands: OK — ${tail}`)
}
