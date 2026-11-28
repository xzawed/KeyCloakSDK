#!/usr/bin/env node
// CHANGELOG 조각 도구 — `changelog.d/` 의 조각을 읽고 검사한다(이어서 preview · release · migrate · covered).
//
// 사용: node scripts/changelog.mjs <check> [--root=<디렉터리>]
//
// 종료 코드: 0 성공 · 1 거부(트리 상태 · 검사 실패 — 아무것도 쓰지 않는다) · 2 사용법.
// ⚠️ 인자 규칙은 changelog-rotate.mjs 를 따른다 — `--root=` 만 받고, 모르는 인자 · 모르는 하위명령 · 빈/겹친
// `--root=` 는 사용법 오류다. 오타가 기본 동작으로 떨어지면 「검사가 비었다」가 통과로 읽힌다.
import { readDeployLangs, readFragmentDir, FRAGMENT_DIR } from './lib/changelog-fragments.mjs'

const USAGE = 'node scripts/changelog.mjs <check> [--root=<디렉터리>]'
const usage = (msg) => {
  console.error(`changelog: ${msg}\n사용: ${USAGE} — 아무것도 쓰지 않았다`)
  process.exit(2)
}
const reject = (lines) => {
  for (const l of lines) console.error(l)
  process.exit(1)
}

// 하위명령 표 — 과제마다 한 줄씩 늘린다. 각 함수는 { root } 를 받아 종료 코드를 정한다.
const COMMANDS = {
  check({ root }) {
    let order
    try {
      order = readDeployLangs(root)
    } catch (e) {
      reject([`changelog: ${e.message}`])
    }
    const { fragments, errors } = readFragmentDir(root, order)
    if (errors.length) reject(errors)
    console.log(fragments.length
      ? `ok   ${FRAGMENT_DIR}/ ${fragments.length}개 조각`
      : `ok   ${FRAGMENT_DIR}/ — 대기 중인 조각이 없다`)
  },
}

const argv = process.argv.slice(2)
const [cmd, ...rest] = argv
if (!cmd || cmd.startsWith('--') || !Object.hasOwn(COMMANDS, cmd)) usage(`모르는 하위명령 — ${cmd ?? '(없음)'}`)
const unknown = rest.filter((a) => !a.startsWith('--root='))
if (unknown.length) usage(`모르는 인자 — ${unknown.join(' ')}`)
const roots = rest.filter((a) => a.startsWith('--root='))
if (roots.length > 1 || roots.includes('--root=')) usage(`--root= 는 값과 함께 한 번만 준다 — ${roots.join(' ')}`)
COMMANDS[cmd]({ root: roots.length ? roots[0].slice('--root='.length) : '.' })
