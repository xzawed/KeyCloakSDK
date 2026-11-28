#!/usr/bin/env node
// CHANGELOG 조각 도구 — `changelog.d/` 의 조각을 검사하고(check) 모아 보인다(preview). 이어서 release · migrate · covered.
//
// 사용: node scripts/changelog.mjs check [--root=<디렉터리>]
//       node scripts/changelog.mjs preview [<lang>] [--date=YYYY-MM-DD] [--root=<디렉터리>]
//
// 종료 코드: 0 성공 · 1 거부(트리 상태 · 검사 실패 — 아무것도 쓰지 않는다) · 2 사용법.
// ⚠️ 인자 규칙은 changelog-rotate.mjs 를 따른다 — 하위명령마다 받는 `--<이름>=<값>` 과 위치 인자 수가 아래 표에 있고, 그 밖의
// 인자 · 모르는 하위명령 · 빈/겹친 `--root=` · `--<이름>=` 은 사용법 오류다. 오타가 기본 동작으로 떨어지면 「검사가 비었다」가
// 통과로 읽힌다.
import { readDeployLangs, readFragmentDir, FRAGMENT_DIR } from './lib/changelog-fragments.mjs'
import { compileWave, verifyWave, renderPreview, isWaveDate } from './lib/changelog-wave.mjs'

const usage = (msg) => {
  console.error(`changelog: ${msg}\n사용: ${USAGE} — 아무것도 쓰지 않았다`)
  process.exit(2)
}
const reject = (lines) => {
  for (const l of lines) console.error(l)
  process.exit(1)
}
// 트리를 읽는다 — DEPLOY_LANGS 를 못 읽거나 조각 문법이 틀리면 거부(rc 1)다.
const deployLangs = (root) => {
  try {
    return readDeployLangs(root)
  } catch (e) {
    reject([`changelog: ${e.message}`])
  }
}
const pendingFragments = (root, order) => {
  const { fragments, errors } = readFragmentDir(root, order)
  if (errors.length) reject(errors)
  return fragments
}
// `--date=` — 없으면 오늘(이 기계의 지역 날짜). 꼴이 틀리거나 달력에 없는 날이면 사용법 오류다. release 도 이것으로 읽는다.
const today = () => {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}
const dateOf = (values) => {
  const date = values.date ?? today()
  if (!isWaveDate(date)) usage(`--date= 는 있는 날짜의 YYYY-MM-DD 다 — ${date}`)
  return date
}

// 하위명령 표 — 과제마다 한 줄씩 늘린다. args = 위치 인자 수 [최소, 최대] · values = 받는 `--<이름>=<값>` 의 이름 ·
// run({ root, args, values }) 이 종료 코드를 정한다(values 는 이름 → 값, 준 것만 있다).
const COMMANDS = {
  check: {
    usage: 'check [--root=<디렉터리>]',
    args: [0, 0],
    values: [],
    run({ root }) {
      const fragments = pendingFragments(root, deployLangs(root))
      console.log(fragments.length
        ? `ok   ${FRAGMENT_DIR}/ ${fragments.length}개 조각`
        : `ok   ${FRAGMENT_DIR}/ — 대기 중인 조각이 없다`)
    },
  },
  // 언어 없이 — 대기 조각 전부를 지금의 `[Unreleased]` 꼴로(태그는 langs 전부). 언어 하나 — 그 언어만 내보내는 물결의
  // 절(판 자리는 `?`, 태그는 그 언어뿐)이고, release 와 같은 컴파일 · 독립 대조를 거친다.
  preview: {
    usage: 'preview [<lang>] [--date=YYYY-MM-DD] [--root=<디렉터리>]',
    args: [0, 1],
    values: ['date'],
    run({ root, args: [lang], values }) {
      if (lang === undefined && values.date !== undefined) usage('--date= 는 <lang> 과 함께 준다 — 모든 언어의 미리보기는 날짜가 없는 [Unreleased] 꼴이다')
      const date = lang === undefined ? null : dateOf(values)
      const order = deployLangs(root)
      if (lang !== undefined && !order.includes(lang)) usage(`모르는 언어 — ${lang} (DEPLOY_LANGS: ${order.join(' ')})`)
      const fragments = pendingFragments(root, order)
      if (lang === undefined) {
        process.stdout.write(renderPreview(fragments, order))
        return
      }
      const wave = { date, versions: { [lang]: '?' } }
      const { text } = compileWave(fragments, wave, order)
      const errors = verifyWave(fragments, wave, text, order)
      if (errors.length) reject(errors)
      process.stdout.write(text)
    },
  },
}
const USAGE = Object.values(COMMANDS).map((c) => `node scripts/changelog.mjs ${c.usage}`).join(' | ')

const [cmd, ...rest] = process.argv.slice(2)
if (!cmd || cmd.startsWith('--') || !Object.hasOwn(COMMANDS, cmd)) usage(`모르는 하위명령 — ${cmd ?? '(없음)'}`)
const spec = COMMANDS[cmd]
const roots = []
const given = {} // 이름 → 받은 값들
const args = []
const unknown = []
for (const a of rest) {
  const m = /^--([a-z]+)=/.exec(a)
  if (a.startsWith('--root=')) roots.push(a)
  else if (m && spec.values.includes(m[1])) (given[m[1]] ??= []).push(a.slice(m[0].length))
  else if (a.startsWith('--')) unknown.push(a)
  else args.push(a)
}
if (unknown.length) usage(`모르는 인자 — ${unknown.join(' ')}`)
if (roots.length > 1 || roots.includes('--root=')) usage(`--root= 는 값과 함께 한 번만 준다 — ${roots.join(' ')}`)
for (const [name, vs] of Object.entries(given)) {
  if (vs.length > 1 || vs.includes('')) usage(`--${name}= 는 값과 함께 한 번만 준다 — ${vs.map((v) => `--${name}=${v}`).join(' ')}`)
}
const [min, max] = spec.args
if (args.length < min || args.length > max) usage(`${cmd} 의 위치 인자는 ${min === max ? `${min}개` : `${min}–${max}개`}다 — ${args.join(' ') || '(없음)'}`)
spec.run({
  root: roots.length ? roots[0].slice('--root='.length) : '.',
  args,
  values: Object.fromEntries(Object.entries(given).map(([name, [v]]) => [name, v])),
})
