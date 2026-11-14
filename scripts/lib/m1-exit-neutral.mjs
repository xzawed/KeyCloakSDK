#!/usr/bin/env node
// M1 변이 — 판정기가 **종료 코드로는** 더는 실패하지 못하게 만든다(scripts/mutation-sweep.mjs 가 쓴다).
//
//   .mjs · .js → 첫 줄(셔뱅 뒤)에 'exit' 리스너를 넣어 process.exitCode 를 0 으로 되돌린다. process.exit(n) ·
//                exitCode = n · 잡히지 않은 throw · 거부된 최상위 await 가 전부 0 이 된다(실측 2026-11-14, node 22).
//   .sh        → 셔뱅 뒤에 `trap 'exit 0' EXIT` 를 넣고, 판정기 자신의 EXIT 트랩은 처리기 끝에 `; exit 0` 을 붙인다
//                (덮어쓰면 그 정리가 사라지고, 안 붙이면 나중 트랩이 우리 것을 지운다).
// 출력은 그대로다 — 그래서 이 변이를 잡는 것은 **종료 코드를 단언하는** 시험뿐이다. 메시지만 보는 시험은 놓친다.
//
// 사용: node scripts/lib/m1-exit-neutral.mjs <판정기 경로>   (넣은 줄마다 표식 PROBE-M1)
import { readFileSync, writeFileSync } from 'node:fs'

const file = process.argv[2]
if (!file) {
  console.error('usage: m1-exit-neutral.mjs <judge file>')
  process.exit(2)
}
const src = readFileSync(file, 'utf8')
const eol = src.includes('\r\n') ? '\r\n' : '\n'
const lines = src.split(/\r?\n/)
const at = lines[0].startsWith('#!') ? 1 : 0

if (/\.(mjs|js)$/.test(file)) {
  lines.splice(at, 0, "process.on('exit', () => { process.exitCode = 0 }) // PROBE-M1")
} else if (/\.sh$/.test(file)) {
  const trap = /^(\s*)trap\s+(?:'([^']*)'|"([^"]*)"|(\S+))\s+(.*\bEXIT\b.*)$/
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(trap)
    if (m) lines[i] = `${m[1]}trap '${m[2] ?? m[3] ?? m[4]}; exit 0' ${m[5]} # PROBE-M1`
  }
  lines.splice(at, 0, "trap 'exit 0' EXIT # PROBE-M1")
} else {
  console.error(`m1-exit-neutral: 모르는 판정기 형식 — ${file}`)
  process.exit(2)
}
writeFileSync(file, lines.join(eol))
